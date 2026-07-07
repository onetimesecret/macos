//! # ots-ffi — the only crate exposed to Swift
//!
//! A thin C ABI over [`ots_core::Cache`]. It hands the UI **handles**
//! ([`CellId`](ots_core::CellId) as a `u64`), **non-secret metadata**
//! (`CellSummary` JSON), and **action outputs** (a `ShareLink` JSON) — and
//! never a plaintext secret (docs/01 §3, §5). The core reads the pasteboard
//! itself, so even ingest keeps plaintext in Rust from the first byte.
//!
//! ## Auditing the boundary
//!
//! Scan the exported functions below: none returns secret bytes. `list` emits
//! redacted previews only; `conceal` emits a share URL and receipt (outputs,
//! not the secret); ingest returns an opaque id. This is the review checklist
//! item from docs/01 §10 step 6.
//!
//! ## Codegen
//!
//! For the skeleton this is a hand-written C ABI plus a committed header
//! (`include/ots_ffi.h`) — the stable substrate an `.xcframework` wraps. The
//! binding choice between `swift-bridge` and UniFFI (docs/01 §5) is confirmed
//! in the vertical-slice spike; the secrets-never-cross property makes it an
//! ergonomics decision, not a safety one.
#![allow(unsafe_code)] // A C ABI requires raw pointers; every unsafe fn documents its contract.

use std::ffi::{c_char, c_int, CStr, CString};
use std::ptr;
use std::sync::{Arc, Mutex};

use ots_core::api::ConcealOpts;
use ots_core::cache::ApiConfig;
use ots_core::cell::{CellId, TtlRung};
use ots_core::clock::SystemClock;
use ots_core::keychain::default_credential_store;
use ots_core::pasteboard::{Pasteboard, StaticPasteboard};
use ots_core::Cache;

/// Opaque handle Swift holds. Wraps the core behind a mutex so calls from
/// different threads are serialized (a menu-bar app mostly calls from one, but
/// `conceal` should be called off the main thread since it blocks on I/O).
pub struct OtsCache {
    inner: Mutex<Cache>,
}

impl OtsCache {
    fn from_cache(cache: Cache) -> Self {
        Self {
            inner: Mutex::new(cache),
        }
    }
}

// ---------------------------------------------------------------------------
// Process init
// ---------------------------------------------------------------------------

/// Harden the process (disable core dumps) before any secret is held.
/// Idempotent; safe to call more than once.
#[no_mangle]
pub extern "C" fn otsc_init() {
    ots_core::init::harden_process();
}

/// Library version string (static; do **not** free).
#[no_mangle]
pub extern "C" fn otsc_version() -> *const c_char {
    // Safe: a NUL-terminated static byte string.
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

// ---------------------------------------------------------------------------
// Cache lifecycle
// ---------------------------------------------------------------------------

/// Create a new cache, returning an owned handle. The caller owns it and must
/// release it with [`otsc_cache_free`]. Also hardens the process.
///
/// The ingest source is currently an empty stand-in; the `NSPasteboard`-backed
/// reader lands in the vertical-slice spike (docs/01 §10 step 7). Credentials
/// use the platform store (macOS Keychain, in-memory dev fallback elsewhere).
#[no_mangle]
pub extern "C" fn otsc_cache_new() -> *mut OtsCache {
    ots_core::init::harden_process();
    let clock = Arc::new(SystemClock::new());
    let pasteboard: Box<dyn Pasteboard> = Box::new(StaticPasteboard::empty());
    let creds = default_credential_store();
    let cache = Cache::new(clock, pasteboard, creds);
    Box::into_raw(Box::new(OtsCache::from_cache(cache)))
}

/// Release a cache created by [`otsc_cache_new`], wiping every secret it holds.
/// Passing null is a no-op.
///
/// # Safety
/// `cache` must be a pointer returned by [`otsc_cache_new`] and not already
/// freed. After this call the pointer is dangling and must not be reused.
#[no_mangle]
pub unsafe extern "C" fn otsc_cache_free(cache: *mut OtsCache) {
    if !cache.is_null() {
        drop(unsafe { Box::from_raw(cache) });
    }
}

/// Configure the share bridge with an API base URL and external id (the
/// Basic-auth username). Both are non-secret; the token lives in the keychain.
/// Returns `true` on success, `false` on a null/invalid argument.
///
/// # Safety
/// `cache` must be a valid handle. `base_url` and `extid` must be valid,
/// NUL-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn otsc_cache_set_api(
    cache: *mut OtsCache,
    base_url: *const c_char,
    extid: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { cache.as_ref() }) else {
        return false;
    };
    let (Some(base_url), Some(extid)) = (unsafe { cstr(base_url) }, unsafe { cstr(extid) }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.set_api(ApiConfig {
        base_url: base_url.to_string(),
        extid: extid.to_string(),
    });
    true
}

// ---------------------------------------------------------------------------
// Operations — handles and non-secret metadata only
// ---------------------------------------------------------------------------

/// Ingest whatever is on the pasteboard into a new cell, returning its id.
/// Returns `0` if there was nothing to ingest or on error (`0` is never a valid
/// cell id).
///
/// # Safety
/// `cache` must be a valid handle.
#[no_mangle]
pub unsafe extern "C" fn otsc_ingest_pasteboard(cache: *mut OtsCache) -> u64 {
    let Some(handle) = (unsafe { cache.as_ref() }) else {
        return 0;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return 0;
    };
    match guard.ingest_from_pasteboard() {
        Ok(id) => id.0,
        Err(_) => 0,
    }
}

/// A JSON array of non-secret cell summaries, newest first. The caller owns the
/// returned string and must release it with [`otsc_string_free`]. Returns null
/// on error.
///
/// # Safety
/// `cache` must be a valid handle.
#[no_mangle]
pub unsafe extern "C" fn otsc_list_json(cache: *mut OtsCache) -> *mut c_char {
    let Some(handle) = (unsafe { cache.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let summaries = guard.list();
    match serde_json::to_string(&summaries) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Reset a cell to an explicit rung (see the `OtsRung` codes in the header).
/// Returns `true` if the cell existed and the rung code was valid.
///
/// # Safety
/// `cache` must be a valid handle.
#[no_mangle]
pub unsafe extern "C" fn otsc_cell_reset_ttl(cache: *mut OtsCache, id: u64, rung: c_int) -> bool {
    let Some(rung) = rung_from_code(rung) else {
        return false;
    };
    let Some(handle) = (unsafe { cache.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.reset_ttl(CellId(id), rung)
}

/// Step a cell up the TTL ladder, returning the new rung code, or `-1` if the
/// cell is gone.
///
/// # Safety
/// `cache` must be a valid handle.
#[no_mangle]
pub unsafe extern "C" fn otsc_cell_cycle_ttl(cache: *mut OtsCache, id: u64) -> c_int {
    let Some(handle) = (unsafe { cache.as_ref() }) else {
        return -1;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return -1;
    };
    match guard.cycle_ttl(CellId(id)) {
        Some(rung) => rung_to_code(rung),
        None => -1,
    }
}

/// Evict a cell now, wiping its secret. Returns whether it existed.
///
/// # Safety
/// `cache` must be a valid handle.
#[no_mangle]
pub unsafe extern "C" fn otsc_cell_evict(cache: *mut OtsCache, id: u64) -> bool {
    let Some(handle) = (unsafe { cache.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.evict(CellId(id))
}

/// Promote a text cell to a one-time link. `ttl_secs` is the **link's**
/// server-side lifespan (a different clock from the cell's local TTL).
///
/// Returns a JSON object the caller must free with [`otsc_string_free`]:
/// - success: `{"ok":true,"share_url":...,"metadata_url":...,"secret_key":...,"metadata_key":...,"ttl_secs":...}`
/// - failure: `{"ok":false,"code":<int>,"message":<string>}`
///
/// Blocks on network I/O — call off the main thread.
///
/// # Safety
/// `cache` must be a valid handle.
#[no_mangle]
pub unsafe extern "C" fn otsc_cell_conceal_json(
    cache: *mut OtsCache,
    id: u64,
    ttl_secs: u64,
) -> *mut c_char {
    let Some(handle) = (unsafe { cache.as_ref() }) else {
        return into_c_string(conceal_error_json(-1, "invalid cache handle"));
    };
    let Ok(guard) = handle.inner.lock() else {
        return into_c_string(conceal_error_json(-2, "cache lock poisoned"));
    };
    let json = match guard.conceal(CellId(id), ConcealOpts::new(ttl_secs)) {
        Ok(link) => serde_json::json!({
            "ok": true,
            "share_url": link.share_url,
            "metadata_url": link.metadata_url,
            "secret_key": link.secret_key,
            "metadata_key": link.metadata_key,
            "ttl_secs": link.ttl_secs,
        })
        .to_string(),
        Err(e) => conceal_error_json(1, &e.to_string()),
    };
    into_c_string(json)
}

/// Free a string returned by this library. Passing null is a no-op.
///
/// # Safety
/// `s` must be a pointer returned by one of this library's `*_json` functions
/// (or null), not previously freed.
#[no_mangle]
pub unsafe extern "C" fn otsc_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Borrow a C string as `&str`, or `None` if null / not valid UTF-8.
///
/// # Safety
/// `p` must be null or a valid NUL-terminated C string.
unsafe fn cstr<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

/// Move a Rust `String` into an owned C string pointer (caller frees).
fn into_c_string(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

fn conceal_error_json(code: i64, message: &str) -> String {
    serde_json::json!({ "ok": false, "code": code, "message": message }).to_string()
}

/// Map a rung integer code (as used across the C ABI) to a [`TtlRung`].
/// Codes follow the ladder order: `0=1h, 1=3h, 2=8h, 3=24h, 4=3d, 5=7d`.
fn rung_from_code(code: c_int) -> Option<TtlRung> {
    usize::try_from(code)
        .ok()
        .and_then(|i| TtlRung::LADDER.get(i).copied())
}

fn rung_to_code(rung: TtlRung) -> c_int {
    TtlRung::LADDER
        .iter()
        .position(|&r| r == rung)
        .and_then(|i| c_int::try_from(i).ok())
        .unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ots_core::clock::ManualClock;
    use ots_core::keychain::InMemoryCredentialStore;

    /// Build a handle around a cache with injected pasteboard text, so the C ABI
    /// can be exercised without a plaintext-in path in the shipped surface.
    fn handle_with_text(text: &str) -> *mut OtsCache {
        let clock = Arc::new(ManualClock::new(0));
        let pb: Box<dyn Pasteboard> = Box::new(StaticPasteboard::with_text(text));
        let creds = Arc::new(InMemoryCredentialStore::default());
        let cache = Cache::new(clock, pb, creds);
        Box::into_raw(Box::new(OtsCache::from_cache(cache)))
    }

    unsafe fn take_json(p: *mut c_char) -> String {
        assert!(!p.is_null(), "expected a JSON string, got null");
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
        unsafe { otsc_string_free(p) };
        s
    }

    #[test]
    fn rung_codes_round_trip() {
        for (i, &rung) in TtlRung::LADDER.iter().enumerate() {
            let code = rung_to_code(rung);
            assert_eq!(code as usize, i);
            assert_eq!(rung_from_code(code), Some(rung));
        }
        assert_eq!(rung_from_code(-1), None);
        assert_eq!(rung_from_code(99), None);
    }

    #[test]
    fn ingest_list_shows_redacted_preview_never_the_secret() {
        let secret = "sk-live_4f9c2a7e9b1d3c5e7f9a1b3d5c7e9f";
        let cache = handle_with_text(secret);
        unsafe {
            let id = otsc_ingest_pasteboard(cache);
            assert_ne!(id, 0);

            let json = take_json(otsc_list_json(cache));
            assert!(json.contains("sk-liv…"), "preview should be present");
            assert!(
                !json.contains("4f9c2a7e"),
                "the raw secret must never appear in the FFI output: {json}"
            );

            otsc_cache_free(cache);
        }
    }

    #[test]
    fn ttl_and_evict_over_the_abi() {
        let cache = handle_with_text("value");
        unsafe {
            let id = otsc_ingest_pasteboard(cache);
            assert!(otsc_cell_reset_ttl(cache, id, 0)); // 1h
            let new_code = otsc_cell_cycle_ttl(cache, id); // -> 3h == code 1
            assert_eq!(new_code, 1);
            assert!(otsc_cell_evict(cache, id));
            assert!(!otsc_cell_evict(cache, id), "already gone");
            otsc_cache_free(cache);
        }
    }

    #[test]
    fn conceal_without_api_config_returns_error_json() {
        let cache = handle_with_text("value");
        unsafe {
            let id = otsc_ingest_pasteboard(cache);
            let json = take_json(otsc_cell_conceal_json(cache, id, 3600));
            assert!(json.contains("\"ok\":false"), "{json}");
            otsc_cache_free(cache);
        }
    }

    #[test]
    fn null_handles_are_handled_gracefully() {
        unsafe {
            assert_eq!(otsc_ingest_pasteboard(ptr::null_mut()), 0);
            assert!(otsc_list_json(ptr::null_mut()).is_null());
            assert!(!otsc_cell_evict(ptr::null_mut(), 1));
            otsc_cache_free(ptr::null_mut()); // no-op
            otsc_string_free(ptr::null_mut()); // no-op
        }
    }
}
