//! [`SecretBuffer`], the only owner of a cell's plaintext bytes.
#![allow(unsafe_code)] // libc page locking.

#[cfg(unix)]
use std::collections::BTreeMap;
use std::ops::Range;
#[cfg(unix)]
use std::sync::{Mutex, OnceLock, PoisonError};

use zeroize::Zeroize;

/// Owns plaintext bytes, locks their pages against swap, and zeroizes
/// them, spare capacity included, on drop. Not `Clone`, `Debug` or
/// serializable (tests assert it).
///
/// `munlock` does not count, so `LOCKED_PAGES` does: a page shared by two
/// buffers is unlocked when the last goes. Assumes nothing else in the
/// process calls `mlock`.
pub struct SecretBuffer {
    bytes: Vec<u8>,
    locked: Option<Range<usize>>,
}

impl SecretBuffer {
    /// Take ownership of `bytes`, locking its whole allocation's pages. The
    /// allocation is never resized, so the locked range stays valid.
    #[must_use]
    pub fn new(bytes: Vec<u8>) -> Self {
        let range = allocation(&bytes);
        let locked = (!bytes.is_empty() && lock_pages(range.clone())).then_some(range);
        Self { bytes, locked }
    }

    /// Copy `text` into a new locked buffer.
    #[must_use]
    pub fn from_text(text: &str) -> Self {
        Self::new(text.as_bytes().to_vec())
    }

    /// Take ownership of `bytes` without locking: large images would exhaust
    /// `RLIMIT_MEMLOCK` (docs/spec/design/05). Still zeroized on drop.
    #[must_use]
    pub fn new_unlocked(bytes: Vec<u8>) -> Self {
        Self {
            bytes,
            locked: None,
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

    /// Whether the OS honoured the page lock; `false` is not an error.
    #[must_use]
    pub fn is_locked(&self) -> bool {
        self.locked.is_some()
    }

    /// The plaintext, for the store's deliberate exits only.
    pub(crate) fn expose(&self) -> &[u8] {
        &self.bytes
    }

    /// What [`Drop`] runs, separate so a test can observe a live buffer.
    /// Idempotent.
    fn wipe(&mut self) {
        self.bytes.as_mut_slice().zeroize();
        self.bytes.spare_capacity_mut().zeroize();
        if let Some(range) = self.locked.take() {
            unlock_pages(range);
        }
    }
}

impl Drop for SecretBuffer {
    fn drop(&mut self) {
        self.wipe();
    }
}

fn allocation(bytes: &Vec<u8>) -> Range<usize> {
    let start = bytes.as_ptr() as usize;
    start..start.saturating_add(bytes.capacity())
}

/// Live locked buffers per page number. Held across every lock and
/// unlock so a page's count and its lock never disagree.
#[cfg(unix)]
static LOCKED_PAGES: Mutex<BTreeMap<usize, usize>> = Mutex::new(BTreeMap::new());

/// The OS page size, or 4096 if `sysconf` answers nonsense.
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

#[cfg(unix)]
fn pages(range: &Range<usize>) -> Range<usize> {
    if range.is_empty() {
        return 0..0;
    }
    let page = page_size();
    range.start / page..(range.end - 1) / page + 1
}

/// Lock and count the pages under a live, non-empty allocation; `false`,
/// counting nothing, when the OS refuses.
#[cfg(unix)]
fn lock_pages(range: Range<usize>) -> bool {
    let mut counts = LOCKED_PAGES.lock().unwrap_or_else(PoisonError::into_inner);
    // SAFETY: `mlock` reads no memory; the range is a live allocation.
    let ret = unsafe { libc::mlock(std::ptr::without_provenance(range.start), range.len()) };
    if ret != 0 {
        // A refused lock may have wired part of the range: release pages no
        // other buffer holds.
        unlock_runs(pages(&range).filter(|page| !counts.contains_key(page)));
        return false;
    }
    for page in pages(&range) {
        *counts.entry(page).or_insert(0) += 1;
    }
    true
}

/// Uncount an allocation's pages and unlock those now held by no one.
#[cfg(unix)]
fn unlock_pages(range: Range<usize>) {
    let mut counts = LOCKED_PAGES.lock().unwrap_or_else(PoisonError::into_inner);
    let mut released = Vec::new();
    for page in pages(&range) {
        match counts.get_mut(&page) {
            Some(count) if *count > 1 => *count -= 1,
            counted => {
                debug_assert!(counted.is_some(), "unlocking a page never counted");
                counts.remove(&page);
                released.push(page);
            }
        }
    }
    unlock_runs(released.into_iter());
}

/// Unlock ascending page numbers, one `munlock` per contiguous run.
#[cfg(unix)]
fn unlock_runs(pages: impl Iterator<Item = usize>) {
    for run in runs(pages) {
        unlock_run(run);
    }
}

/// Ascending page numbers gathered into contiguous runs.
#[cfg(unix)]
fn runs(pages: impl Iterator<Item = usize>) -> Vec<Range<usize>> {
    let mut runs: Vec<Range<usize>> = Vec::new();
    for page in pages {
        match runs.last_mut() {
            Some(open) if open.end == page => open.end = page + 1,
            _ => runs.push(page..page + 1),
        }
    }
    runs
}

#[cfg(unix)]
fn unlock_run(pages: Range<usize>) {
    let size = page_size();
    // SAFETY: `munlock` reads no memory.
    unsafe {
        let _ = libc::munlock(
            std::ptr::without_provenance(pages.start * size),
            pages.len() * size,
        );
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

    assert_not_impl_any!(SecretBuffer: Clone, Copy, std::fmt::Debug, std::fmt::Display);
    assert_not_impl_any!(SecretBuffer: serde::Serialize, serde::de::DeserializeOwned);

    #[test]
    fn wipe_zeroes_every_byte() {
        let mut sb = SecretBuffer::from_text("sk-live_4f9c2a7e-super-secret-token");
        let len = sb.len();
        assert!(len > 0);

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
        sb.wipe();
        drop(sb);
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
        // Pages of an allocation this test owns, so no other buffer touches them.
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

    #[cfg(unix)]
    #[test]
    fn pages_are_given_back_a_contiguous_run_at_a_time() {
        assert_eq!(runs([1, 2, 3, 5, 7, 8].into_iter()), vec![1..4, 5..6, 7..9]);
        assert!(runs(std::iter::empty()).is_empty());
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
        // SAFETY: every spare byte was written, by `to_vec` and by the wipe.
        assert!(tail.iter().all(|b| unsafe { b.assume_init_read() } == 0));
    }
}
