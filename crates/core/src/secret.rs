//! [`SecretBuffer`] — the only owner of a cell's plaintext bytes.
//!
//! Harvested from the parallel skeleton prototype (PR #5) and adopted as
//! the core's memory discipline: `Zeroizing` guarantees the wipe, this
//! adds page locking and makes accidental duplication a compile error.
#![allow(unsafe_code)] // Page locking requires libc; every unsafe use below carries a SAFETY note.

use zeroize::Zeroize;

/// Owns a heap allocation of plaintext bytes, locks its pages against
/// swap, and zeroizes them on drop.
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
    /// Take ownership of `bytes`, locking its pages against swap. The
    /// allocation is never grown or shrunk afterwards, so the locked
    /// range stays valid for the buffer's whole life.
    #[must_use]
    pub fn new(bytes: Vec<u8>) -> Self {
        let locked = lock_pages(&bytes);
        Self { bytes, locked }
    }

    /// Build a buffer from UTF-8 text. The caller's `&str` is copied into
    /// an owned, locked allocation; the caller remains responsible for
    /// its own copy.
    #[must_use]
    pub fn from_text(text: &str) -> Self {
        Self::new(text.as_bytes().to_vec())
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
    /// bytes off this crate's exported surface except through
    /// [`crate::CellContent`]'s deliberate exits.
    pub(crate) fn expose(&self) -> &[u8] {
        &self.bytes
    }

    /// The exact zeroization the [`Drop`] path runs, factored out so a
    /// test can observe the result on a *still-allocated* buffer (no
    /// use-after-free).
    ///
    /// Bytes are zeroed in place via the slice `Zeroize` impl, which
    /// keeps the length unchanged — so the subsequent `munlock` covers
    /// the same range that was `mlock`ed. Idempotent: a second call is a
    /// harmless no-op.
    fn wipe(&mut self) {
        self.bytes.as_mut_slice().zeroize();
        if self.locked {
            unlock_pages(&self.bytes);
            self.locked = false;
        }
    }
}

impl Drop for SecretBuffer {
    fn drop(&mut self) {
        self.wipe();
    }
}

#[cfg(unix)]
fn lock_pages(bytes: &[u8]) -> bool {
    if bytes.is_empty() {
        return false;
    }
    // SAFETY: `mlock` over the exact byte range of a live allocation. The
    // pointer and length come from a borrowed, non-empty slice, so the
    // range is valid for the duration of the call.
    let ret = unsafe { libc::mlock(bytes.as_ptr().cast(), bytes.len()) };
    ret == 0
}

#[cfg(unix)]
fn unlock_pages(bytes: &[u8]) {
    if bytes.is_empty() {
        return;
    }
    // SAFETY: `munlock` over a range we previously `mlock`ed
    // successfully. The slice is still live here because `wipe` runs
    // before deallocation and does not change the buffer's length.
    unsafe {
        let _ = libc::munlock(bytes.as_ptr().cast(), bytes.len());
    }
}

#[cfg(not(unix))]
fn lock_pages(_bytes: &[u8]) -> bool {
    false
}

#[cfg(not(unix))]
fn unlock_pages(_bytes: &[u8]) {}

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
}
