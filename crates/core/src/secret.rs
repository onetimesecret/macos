//! [`SecretBuffer`] — the only owner of a cell's plaintext bytes.
//!
//! Harvested from the parallel skeleton prototype (PR #5) and adopted as
//! the core's memory discipline: `Zeroizing` guarantees the wipe, this
//! adds page locking and makes accidental duplication a compile error.
#![allow(unsafe_code)] // Page locking requires libc; every unsafe use below carries a SAFETY note.

#[cfg(unix)]
use std::collections::BTreeMap;
use std::ops::Range;
#[cfg(unix)]
use std::sync::{Mutex, OnceLock, PoisonError};

use zeroize::Zeroize;

/// Owns a heap allocation of plaintext bytes, locks its pages against
/// swap, and zeroizes them on drop.
///
/// `mlock` and `munlock` work on whole pages and do not count:
/// unlocking one buffer's range unlocks every page it touches. Two
/// short secrets routinely sit on one page, so a plain `munlock` on
/// drop would leave the survivor swappable while its `is_locked` still
/// said otherwise. The count the OS does not keep is kept here instead
/// (`LOCKED_PAGES`): a page is unlocked only when the last locked
/// buffer touching it goes, and buffers keep sharing pages, so a short
/// chip costs its own bytes and not a page. The table holds one entry
/// per locked page, and `mlock` runs while it is held, so locking or
/// dropping a buffer costs in proportion to its pages and waits on any
/// other in progress. Locked buffers are text chips, a page or two
/// each; images take [`SecretBuffer::new_unlocked`]. The lock covers a
/// vector's whole capacity, spare bytes included, since those are wiped
/// too; a vector handed in with slack wires that much more. A buffer
/// leaked rather than dropped keeps its pages counted and locked for
/// the life of the process. The count is this module's alone: it
/// assumes nothing else in the process calls `mlock`, since releasing a
/// page here would unlock another caller's lock on it too. Nothing does
/// today; a dependency that wires its own pages would have to share
/// this table.
///
/// It deliberately implements **none** of `Clone`, `Copy`, `Debug`,
/// `Display`, `Serialize`, or `Deserialize`: the buffer cannot be
/// duplicated, logged, or persisted by accident. That structural
/// discipline is half of the security posture (doc 05); the other half —
/// plaintext never crossing an FFI seam — is enforced where the seam is
/// built.
pub struct SecretBuffer {
    bytes: Vec<u8>,
    locked: bool,
}

impl SecretBuffer {
    /// Take ownership of `bytes`, locking the pages of its whole
    /// allocation against swap. The allocation is never grown or shrunk
    /// afterwards, so the locked range stays valid for the buffer's
    /// whole life.
    #[must_use]
    pub fn new(bytes: Vec<u8>) -> Self {
        let locked = !bytes.is_empty() && lock_pages(allocation(&bytes));
        Self { bytes, locked }
    }

    /// Build a buffer from UTF-8 text. The caller's `&str` is copied into
    /// an owned, locked allocation; the caller remains responsible for
    /// its own copy.
    #[must_use]
    pub fn from_text(text: &str) -> Self {
        Self::new(text.as_bytes().to_vec())
    }

    /// Take ownership of `bytes` **without** locking pages. This is the
    /// documented mlock exclusion for large image payloads (doc 05):
    /// wiring megabytes against swap routinely exceeds `RLIMIT_MEMLOCK`
    /// and starves the small text buffers that need the lock most. The
    /// zeroize-on-drop guarantee is unchanged.
    #[must_use]
    pub fn new_unlocked(bytes: Vec<u8>) -> Self {
        Self {
            bytes,
            locked: false,
        }
    }

    /// Number of secret bytes held.
    #[must_use]
    pub fn len(&self) -> usize {
        self.bytes.len()
    }

    /// Whether the buffer holds no bytes.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }

    /// Whether the OS honoured the page lock. `false` is **not** an
    /// error — containers and hardened kernels routinely cap
    /// `RLIMIT_MEMLOCK` — but a caller may surface it. The
    /// zeroize-on-drop guarantee holds regardless.
    #[must_use]
    pub fn is_locked(&self) -> bool {
        self.locked
    }

    /// In-crate access to the plaintext. `pub(crate)` keeps the raw
    /// bytes off this crate's exported surface except through the
    /// store's deliberate exits ([`crate::SheetStore::chip_payload`]
    /// and [`crate::SheetStore::sheet_payload`]).
    pub(crate) fn expose(&self) -> &[u8] {
        &self.bytes
    }

    /// The exact zeroization the [`Drop`] path runs, factored out so a
    /// test can observe the result on a *still-allocated* buffer (no
    /// use-after-free).
    ///
    /// Every byte of the allocation is zeroed in place, the spare
    /// capacity a vector may arrive with included, and the length is
    /// unchanged — so the subsequent unlock covers the same range that
    /// was locked. Idempotent: a second call is a harmless no-op.
    fn wipe(&mut self) {
        self.bytes.as_mut_slice().zeroize();
        self.bytes.spare_capacity_mut().zeroize();
        if self.locked {
            unlock_pages(allocation(&self.bytes));
            self.locked = false;
        }
    }
}

impl Drop for SecretBuffer {
    fn drop(&mut self) {
        self.wipe();
    }
}

/// The address range of a vector's whole allocation, spare capacity
/// included.
fn allocation(bytes: &Vec<u8>) -> Range<usize> {
    let start = bytes.as_ptr() as usize;
    start..start + bytes.capacity()
}

/// How many live locked buffers touch each page, by page number. Taken
/// for the whole of every lock and unlock, so a page's count and its
/// lock never disagree.
#[cfg(unix)]
static LOCKED_PAGES: Mutex<BTreeMap<usize, usize>> = Mutex::new(BTreeMap::new());

/// The page size the lock works in, asked of the OS once. 4096 should
/// `sysconf` answer something that is not a positive power of two.
#[cfg(unix)]
fn page_size() -> usize {
    static PAGE: OnceLock<usize> = OnceLock::new();
    *PAGE.get_or_init(|| {
        // SAFETY: `sysconf` is a plain libc query taking no pointer.
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        match usize::try_from(page) {
            Ok(page) if page.is_power_of_two() => page,
            _ => 4096,
        }
    })
}

/// The numbers of the pages an address range touches; none for an
/// empty one.
#[cfg(unix)]
fn pages(range: &Range<usize>) -> Range<usize> {
    if range.is_empty() {
        return 0..0;
    }
    let page = page_size();
    range.start / page..(range.end - 1) / page + 1
}

/// Lock the pages under a live, non-empty allocation and count them.
/// `false` when the OS refuses, with nothing counted.
#[cfg(unix)]
fn lock_pages(range: Range<usize>) -> bool {
    let mut counts = LOCKED_PAGES.lock().unwrap_or_else(PoisonError::into_inner);
    // SAFETY: `mlock` over the exact range of a live allocation, which
    // stays allocated for the duration of the call. It reads no memory,
    // so an address without provenance is all it needs; nothing in this
    // module ever reads through one.
    let ret = unsafe { libc::mlock(std::ptr::without_provenance(range.start), range.len()) };
    if ret != 0 {
        // Should a refused lock have wired any of the range, the pages
        // no other buffer holds are given back.
        for page in pages(&range).filter(|page| !counts.contains_key(page)) {
            unlock_page(page);
        }
        return false;
    }
    for page in pages(&range) {
        *counts.entry(page).or_insert(0) += 1;
    }
    true
}

/// Uncount the pages under an allocation [`lock_pages`] counted, and
/// unlock each one no other locked buffer still touches.
#[cfg(unix)]
fn unlock_pages(range: Range<usize>) {
    let mut counts = LOCKED_PAGES.lock().unwrap_or_else(PoisonError::into_inner);
    for page in pages(&range) {
        match counts.get_mut(&page) {
            Some(count) if *count > 1 => *count -= 1,
            // The last buffer on the page. A page another locked buffer
            // still touched would be counted above one, so this arm
            // never unlocks a page anyone else holds.
            counted => {
                debug_assert!(counted.is_some(), "unlocking a page never counted");
                counts.remove(&page);
                unlock_page(page);
            }
        }
    }
}

#[cfg(unix)]
fn unlock_page(page: usize) {
    let size = page_size();
    // SAFETY: `munlock` reads no memory; it asks the kernel to stop
    // wiring one whole page that a live allocation touches.
    unsafe {
        let _ = libc::munlock(std::ptr::without_provenance(page * size), size);
    }
}

#[cfg(not(unix))]
fn lock_pages(_range: Range<usize>) -> bool {
    false
}

#[cfg(not(unix))]
fn unlock_pages(_range: Range<usize>) {}

#[cfg(test)]
mod tests {
    use super::*;
    use static_assertions::assert_not_impl_any;

    // The structural discipline, proven at compile time: a SecretBuffer
    // can never be duplicated, logged, or (de)serialized.
    assert_not_impl_any!(SecretBuffer: Clone, Copy, std::fmt::Debug, std::fmt::Display);
    assert_not_impl_any!(SecretBuffer: serde::Serialize, serde::de::DeserializeOwned);

    #[test]
    fn wipe_zeroes_every_byte() {
        let mut sb = SecretBuffer::from_text("sk-live_4f9c2a7e-super-secret-token");
        let len = sb.len();
        assert!(len > 0);

        // `wipe` is exactly what `Drop` runs. Observing it on the live
        // buffer proves the drop path zeroes memory, without reading
        // freed memory.
        sb.wipe();

        assert_eq!(sb.len(), len, "wipe must not change the length");
        assert!(
            sb.expose().iter().all(|&b| b == 0),
            "wipe left non-zero bytes behind"
        );
    }

    #[test]
    fn wipe_is_idempotent_and_drop_is_safe() {
        let mut sb = SecretBuffer::from_text("another-secret");
        sb.wipe();
        sb.wipe(); // second wipe must not double-munlock or panic
        drop(sb); // Drop calls wipe a third time; still safe
    }

    #[test]
    fn empty_buffer_never_claims_a_lock() {
        let sb = SecretBuffer::new(Vec::new());
        assert!(sb.is_empty());
        assert!(!sb.is_locked(), "an empty buffer locks nothing");
    }

    #[test]
    fn from_text_preserves_bytes_until_wiped() {
        let sb = SecretBuffer::from_text("hello");
        assert_eq!(sb.expose(), b"hello");
        assert_eq!(sb.len(), 5);
    }

    #[cfg(unix)]
    #[test]
    fn a_page_two_buffers_share_is_unlocked_only_when_the_last_goes() {
        // `munlock` does not count, so the count kept here decides. Two
        // ranges on one page of an allocation this test owns outright,
        // so no other test's buffer can touch that page.
        let page = page_size();
        let block = vec![0u8; 3 * page];
        let start = (block.as_ptr() as usize).div_ceil(page) * page;
        let first = start..start + 16;
        let second = start + 64..start + 80;
        let count = || {
            LOCKED_PAGES
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(&(start / page))
                .copied()
        };

        assert!(
            lock_pages(first.clone()),
            "the test needs RLIMIT_MEMLOCK to allow one page"
        );
        assert!(lock_pages(second.clone()));
        assert_eq!(count(), Some(2));
        unlock_pages(first);
        assert_eq!(
            count(),
            Some(1),
            "the page stays locked for the buffer still on it"
        );
        unlock_pages(second);
        assert_eq!(count(), None, "the last buffer off the page unlocks it");
        drop(block);
    }

    #[test]
    fn the_wipe_reaches_the_spare_capacity_a_vector_arrives_with() {
        let mut handed = b"sk-live_secret-and-its-tail".to_vec();
        handed.truncate(7);
        let capacity = handed.capacity();
        let mut sb = SecretBuffer::new(handed);
        sb.wipe();
        let tail = sb.bytes.spare_capacity_mut();
        assert_eq!(tail.len(), capacity - 7);
        // SAFETY: every byte of the spare capacity was written, by
        // `to_vec` before the truncation and by the wipe after it.
        assert!(tail.iter().all(|b| unsafe { b.assume_init_read() } == 0));
    }
}
