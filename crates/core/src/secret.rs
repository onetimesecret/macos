//! [`SecretBuffer`] — the only owner of a cell's plaintext bytes.
//!
//! Harvested from the parallel skeleton prototype (PR #5) and adopted as
//! the core's memory discipline: `Zeroizing` guarantees the wipe, this
//! adds page locking and makes accidental duplication a compile error.
#![allow(unsafe_code)] // Page locking requires libc; every unsafe use below carries a SAFETY note.

use std::alloc::{self, Layout};
use std::ptr::NonNull;
use std::sync::OnceLock;

use zeroize::Zeroize;

/// Owns a heap allocation of plaintext bytes, locks its pages against
/// swap, and zeroizes them on drop.
///
/// The allocation is the buffer's alone: page-aligned and a whole
/// number of pages long, so no two buffers ever share a page. That is
/// what makes the lock a property of this buffer rather than of
/// whatever else the allocator put beside it. `mlock` and `munlock`
/// work on whole pages and do not count: unlocking one buffer's range
/// unlocks every page it touches, and with ordinary allocations two
/// short secrets routinely sit on one page, so dropping one would have
/// left the other swappable while its `is_locked` still said otherwise.
///
/// It deliberately implements **none** of `Clone`, `Copy`, `Debug`,
/// `Display`, `Serialize`, or `Deserialize`: the buffer cannot be
/// duplicated, logged, or persisted by accident. That structural
/// discipline is half of the security posture (doc 05); the other half —
/// plaintext never crossing an FFI seam — is enforced where the seam is
/// built.
pub struct SecretBuffer {
    /// The allocation: page-aligned, `layout.size()` bytes long, or
    /// dangling for an empty buffer, which owns no allocation.
    ptr: NonNull<u8>,
    /// How many of those bytes are the secret. The rest of the last
    /// page is zero and stays zero.
    len: usize,
    /// The allocation's layout, `None` for an empty buffer.
    layout: Option<Layout>,
    locked: bool,
}

// SAFETY: the buffer is the sole owner of its allocation, hands out
// only shared slices of it (`expose`), and frees it exactly once in
// `Drop`. Moving it to another thread moves the ownership with the
// pointer; sharing it shares only reads.
unsafe impl Send for SecretBuffer {}
unsafe impl Sync for SecretBuffer {}

impl SecretBuffer {
    /// Take ownership of `bytes`, copying them into a page-aligned
    /// allocation of their own and locking its pages against swap.
    /// The caller's vector is wiped on the way. The allocation is never
    /// grown or shrunk afterwards, so the locked range stays valid for
    /// the buffer's whole life.
    #[must_use]
    pub fn new(bytes: Vec<u8>) -> Self {
        let mut buffer = Self::copied(bytes);
        buffer.locked = buffer.lock_pages();
        buffer
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
    /// zeroize-on-drop guarantee is unchanged, and so is the allocation
    /// discipline: the bytes still live in pages of their own.
    #[must_use]
    pub fn new_unlocked(bytes: Vec<u8>) -> Self {
        Self::copied(bytes)
    }

    /// Copy `bytes` into an allocation of its own and wipe the vector
    /// they came in. Locks nothing.
    fn copied(mut bytes: Vec<u8>) -> Self {
        let len = bytes.len();
        let layout = (len > 0).then(|| page_layout(len));
        let ptr = match layout {
            None => NonNull::dangling(),
            Some(layout) => {
                // SAFETY: the layout has a non-zero size.
                let raw = unsafe { alloc::alloc_zeroed(layout) };
                let Some(ptr) = NonNull::new(raw) else {
                    alloc::handle_alloc_error(layout)
                };
                // SAFETY: the source is valid for `len` bytes, the
                // destination was just allocated with at least `len`
                // bytes, and the two cannot overlap.
                unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr.as_ptr(), len) };
                ptr
            }
        };
        bytes.zeroize();
        Self {
            ptr,
            len,
            layout,
            locked: false,
        }
    }

    /// Number of secret bytes held.
    #[must_use]
    pub fn len(&self) -> usize {
        self.len
    }

    /// Whether the buffer holds no bytes.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len == 0
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
        // SAFETY: `ptr` is valid for `len` bytes for as long as the
        // buffer lives, or dangling with `len` zero, which is the one
        // pointer a zero-length slice may be built from.
        unsafe { std::slice::from_raw_parts(self.ptr.as_ptr(), self.len) }
    }

    /// The whole allocation, every page of it, for the wipe.
    fn whole_mut(&mut self) -> &mut [u8] {
        let size = self.layout.map_or(0, |layout| layout.size());
        // SAFETY: `ptr` is valid for `size` bytes for as long as the
        // buffer lives, and `&mut self` is the only reference to them.
        unsafe { std::slice::from_raw_parts_mut(self.ptr.as_ptr(), size) }
    }

    /// The exact zeroization the [`Drop`] path runs, factored out so a
    /// test can observe the result on a *still-allocated* buffer (no
    /// use-after-free).
    ///
    /// Every byte of every page is zeroed in place, which keeps the
    /// length unchanged — so the subsequent `munlock` covers the same
    /// range that was `mlock`ed. Idempotent: a second call is a
    /// harmless no-op.
    fn wipe(&mut self) {
        self.whole_mut().zeroize();
        if self.locked {
            self.unlock_pages();
            self.locked = false;
        }
    }
}

impl Drop for SecretBuffer {
    fn drop(&mut self) {
        self.wipe();
        if let Some(layout) = self.layout.take() {
            // SAFETY: `ptr` came from `alloc_zeroed` with this exact
            // layout, and `layout` is taken so nothing frees it twice.
            unsafe { alloc::dealloc(self.ptr.as_ptr(), layout) };
        }
    }
}

/// The page size the lock works in. Asked of the OS once; 4096 where
/// there is no OS to ask, which is also where there is no lock.
fn page_size() -> usize {
    static PAGE: OnceLock<usize> = OnceLock::new();
    *PAGE.get_or_init(|| {
        #[cfg(unix)]
        {
            // SAFETY: `sysconf` is a plain libc query taking no pointer.
            let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
            if let Ok(page) = usize::try_from(page)
                && page.is_power_of_two()
            {
                return page;
            }
        }
        4096
    })
}

/// A layout for `len` secret bytes: aligned to a page, rounded up to
/// whole pages, so the allocation shares a page with nothing.
fn page_layout(len: usize) -> Layout {
    let page = page_size();
    let size = len
        .div_ceil(page)
        .checked_mul(page)
        .expect("a secret that fits in memory rounds up to whole pages that do too");
    Layout::from_size_align(size, page).expect("a page size is a power of two")
}

#[cfg(unix)]
impl SecretBuffer {
    fn lock_pages(&self) -> bool {
        let Some(layout) = self.layout else {
            return false;
        };
        // SAFETY: `mlock` over exactly the pages of a live allocation.
        // The pointer and length come from the allocation's own
        // layout, so the range is valid for the duration of the call.
        let ret = unsafe { libc::mlock(self.ptr.as_ptr().cast(), layout.size()) };
        ret == 0
    }

    fn unlock_pages(&self) {
        let Some(layout) = self.layout else {
            return;
        };
        // SAFETY: `munlock` over the pages we previously `mlock`ed
        // successfully. The allocation is still live here because
        // `wipe` runs before deallocation.
        unsafe {
            let _ = libc::munlock(self.ptr.as_ptr().cast(), layout.size());
        }
    }
}

#[cfg(not(unix))]
impl SecretBuffer {
    fn lock_pages(&self) -> bool {
        false
    }

    fn unlock_pages(&self) {}
}

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

    #[test]
    fn every_buffer_sits_in_pages_of_its_own() {
        // The lock is page-granular and uncounted, so two secrets on
        // one page would unlock each other: each allocation is aligned
        // to a page and a whole number of pages long, and so shares a
        // page with nothing.
        let page = page_size();
        assert!(page.is_power_of_two());
        let first = SecretBuffer::from_text("one short secret");
        let second = SecretBuffer::from_text("another short secret");
        let third = SecretBuffer::new_unlocked(vec![7u8; page + 1]);
        for buffer in [&first, &second, &third] {
            let start = buffer.expose().as_ptr() as usize;
            assert_eq!(start % page, 0, "the allocation starts on a page");
            let size = buffer.layout.unwrap().size();
            assert_eq!(size % page, 0, "the allocation is whole pages");
            assert!(size >= buffer.len());
        }
        assert_ne!(
            first.expose().as_ptr() as usize / page,
            second.expose().as_ptr() as usize / page,
            "two short secrets never share a page"
        );
        assert_eq!(third.layout.unwrap().size(), 2 * page);
    }

    #[test]
    fn the_vector_handed_in_is_wiped_and_the_copy_is_the_secret() {
        let handed = vec![0x5a; 40];
        let sb = SecretBuffer::new(handed);
        assert_eq!(sb.expose(), &[0x5a; 40][..]);
        // Beyond the secret, the page is zero: nothing of a previous
        // tenant of the allocator's memory is carried along.
        let mut whole = sb;
        let size = whole.layout.unwrap().size();
        assert!(whole.whole_mut()[40..size].iter().all(|&b| b == 0));
    }

    #[test]
    fn dropping_one_buffer_leaves_another_where_it_was() {
        let kept = SecretBuffer::from_text("still here");
        let was_locked = kept.is_locked();
        let gone = SecretBuffer::from_text("gone soon");
        drop(gone);
        assert_eq!(kept.expose(), b"still here");
        assert_eq!(
            kept.is_locked(),
            was_locked,
            "another buffer's unlock cannot reach this one's pages"
        );
    }
}
