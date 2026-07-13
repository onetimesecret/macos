//! # companion-ffi — the only crate a non-Rust shell may call
//!
//! A thin C ABI over the core. It hands the shell **handles** (cell ids
//! as `u64`), **non-secret metadata** (summary JSON with masked
//! recognition lines), and **action results** (booleans, counts) — and
//! never a plaintext secret. The boundary law, adopted from the
//! prototype skeleton (PR #5):
//!
//! > Plaintext secret bytes live only in the Rust core, in memory that
//! > the core owns, locks, and wipes. They never cross this seam.
//!
//! Both directions honour it:
//!
//! - **Ingest**: the core reads the pasteboard itself
//!   ([`companion_ingest_pasteboard`]); the shell asks, the core takes.
//! - **Copy-out**: the core writes the pasteboard itself
//!   ([`companion_cell_copy_out`]), applying the hygiene contract
//!   (transient + concealed marks, change-count-guarded clear). The
//!   shell never sees the bytes it is copying.
//!
//! ## Scheduling, not polling
//!
//! The shell arms **one** timer from [`companion_next_deadline_ms`] and
//! calls [`companion_expire_due`] when it fires (doc 05 frugality
//! budget). There is deliberately no "tick" entry point.
//!
//! ## Auditing the boundary
//!
//! Scan the exported functions: none returns secret bytes. `list` emits
//! masked recognition lines only; ingest and copy-out return ids and
//! booleans. A test below asserts the raw secret never appears in list
//! output.
//!
//! ## Codegen
//!
//! Hand-written C ABI plus a committed header
//! (`include/companion_ffi.h`) — the stable substrate the
//! `.xcframework` wraps (`scripts/build-core.sh`). Whether a binding
//! generator earns its keep is an ergonomics question for the shell
//! spike; secrets never cross, so it is not a safety one.
#![allow(unsafe_code)] // A C ABI requires raw pointers; every unsafe fn documents its contract.

#[cfg(any(test, feature = "dev-scaffolding"))]
use std::ffi::CStr;
use std::ffi::{CString, c_char, c_int};
use std::ptr;
use std::sync::Mutex;
use std::time::Duration;

use companion_core::{
    Cell, CellId, CellKind, CellStore, LifecycleState, SystemClock, TTL_LADDER, Ttl,
};
use companion_pasteboard::{
    ChangeCount, ContentKind, MemoryPasteboard, Pasteboard, PasteboardContent, PasteboardItem,
    WriteOptions,
};
#[cfg(target_os = "macos")]
use companion_pasteboard::SystemPasteboard;
use zeroize::Zeroizing;

/// The pasteboard the core reads and writes through the seam.
///
/// On macOS this is the real system clipboard ([`SystemPasteboard`], the
/// `NSPasteboard` adapter that landed in issue #3). Off macOS — Linux CI,
/// and the unit tests below — it is the in-process [`MemoryPasteboard`],
/// so the seam stays exercisable without a window server and the tests
/// never touch (or depend on) a developer's real clipboard.
///
/// This is the swap issue #4 calls for: `companion_new` no longer wires a
/// stand-in on macOS; the core reads and writes the real board itself.
enum Board {
    // Constructed off-macOS (`companion_new`) and by the tests below. On a
    // macOS *library* build only the tests reach it, so silence the
    // never-constructed lint there rather than gate the whole variant out
    // (the `Pasteboard`/seed match arms need it in scope regardless).
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    Memory(MemoryPasteboard),
    #[cfg(target_os = "macos")]
    System(SystemPasteboard),
}

impl Board {
    /// Seed content as another app would — dev scaffolding behind
    /// [`companion_dev_seed_pasteboard`], so the spike's demo and drop
    /// affordances have something to ingest. The real system clipboard
    /// has no unmarked "external put", so on macOS the seed rides the
    /// normal write (transient-marked); ingest reads text regardless of
    /// marks, so the core cannot tell the difference.
    #[cfg(any(test, feature = "dev-scaffolding"))]
    fn put_external(&mut self, content: PasteboardContent, concealed: bool) {
        match self {
            Board::Memory(pb) => pb.put_external(content, concealed),
            #[cfg(target_os = "macos")]
            Board::System(pb) => {
                let (bytes, kind) = match content {
                    PasteboardContent::Text(s) => (s.into_bytes(), ContentKind::Text),
                    PasteboardContent::Image(b) => (b, ContentKind::Image),
                };
                pb.write(Zeroizing::new(bytes), kind, WriteOptions { concealed });
            }
        }
    }

    /// Whether the current item carries the transient mark. Only the
    /// in-memory board (which the tests below use) answers meaningfully;
    /// the real clipboard's marking is verified out of band (issue #4's
    /// `pbcopy` → ingest round-trip), so the macOS arm never needs to.
    #[cfg(test)]
    fn current_is_transient(&self) -> bool {
        match self {
            Board::Memory(pb) => pb.current_is_transient(),
            #[cfg(target_os = "macos")]
            Board::System(_) => false,
        }
    }
}

impl Pasteboard for Board {
    fn read(&self) -> Option<PasteboardItem> {
        match self {
            Board::Memory(pb) => pb.read(),
            #[cfg(target_os = "macos")]
            Board::System(pb) => pb.read(),
        }
    }

    fn write(
        &mut self,
        content: Zeroizing<Vec<u8>>,
        kind: ContentKind,
        options: WriteOptions,
    ) -> ChangeCount {
        match self {
            Board::Memory(pb) => pb.write(content, kind, options),
            #[cfg(target_os = "macos")]
            Board::System(pb) => pb.write(content, kind, options),
        }
    }

    fn change_count(&self) -> ChangeCount {
        match self {
            Board::Memory(pb) => pb.change_count(),
            #[cfg(target_os = "macos")]
            Board::System(pb) => pb.change_count(),
        }
    }

    fn clear_if_unchanged(&mut self, expected: ChangeCount) -> bool {
        match self {
            Board::Memory(pb) => pb.clear_if_unchanged(expected),
            #[cfg(target_os = "macos")]
            Board::System(pb) => pb.clear_if_unchanged(expected),
        }
    }
}

/// The core state behind the seam: the store, the pasteboard the core
/// reads and writes itself, and the receipt of our last outbound write
/// (for the guarded clear).
///
/// The pasteboard is the real [`SystemPasteboard`] on macOS and the
/// in-process [`MemoryPasteboard`] elsewhere — chosen once in
/// [`companion_new`], invisible above this seam (see [`Board`]).
struct Companion {
    store: CellStore<SystemClock>,
    pasteboard: Board,
    last_write: Option<ChangeCount>,
}

/// Opaque handle the shell holds. A mutex serializes calls from
/// different threads (a menu-bar app mostly calls from one).
pub struct CompanionHandle {
    inner: Mutex<Companion>,
}

// ---------------------------------------------------------------------------
// Process init and lifecycle
// ---------------------------------------------------------------------------

/// Harden the process (disable core dumps) before any secret is held.
/// Idempotent; safe to call more than once.
#[unsafe(no_mangle)]
pub extern "C" fn companion_init() {
    companion_core::harden_process();
}

/// Library version string (static; do **not** free).
#[unsafe(no_mangle)]
pub extern "C" fn companion_version() -> *const c_char {
    // A NUL-terminated static byte string.
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

/// Create the companion state, returning an owned handle. The caller
/// owns it and must release it with [`companion_free`]. Also hardens
/// the process.
#[unsafe(no_mangle)]
pub extern "C" fn companion_new() -> *mut CompanionHandle {
    companion_core::harden_process();
    // The one place the backend is chosen: the real system clipboard on
    // macOS, the in-process board elsewhere. Everything above this line is
    // identical on both.
    #[cfg(target_os = "macos")]
    let pasteboard = Board::System(SystemPasteboard::new());
    #[cfg(not(target_os = "macos"))]
    let pasteboard = Board::Memory(MemoryPasteboard::new());
    let companion = Companion {
        store: CellStore::new(SystemClock),
        pasteboard,
        last_write: None,
    };
    Box::into_raw(Box::new(CompanionHandle {
        inner: Mutex::new(companion),
    }))
}

/// Release a handle created by [`companion_new`], wiping every secret it
/// holds. Passing null is a no-op.
///
/// # Safety
/// `handle` must be a pointer returned by [`companion_new`] and not
/// already freed. After this call the pointer is dangling and must not
/// be reused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_free(handle: *mut CompanionHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

// ---------------------------------------------------------------------------
// Ingest and copy-out — the core touches the pasteboard, never the shell
// ---------------------------------------------------------------------------

/// Stage whatever is on the pasteboard as a new cell, returning its id.
/// Returns `0` when there was nothing to stage, the store refused (at
/// capacity — doc 04: refuse, don't evict), or on error. `0` is never a
/// valid cell id.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_ingest_pasteboard(handle: *mut CompanionHandle) -> u64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return 0;
    };
    let Some(item) = guard.pasteboard.read() else {
        return 0;
    };
    let hint = item.concealed.then_some(true);
    let staged = match item.content {
        PasteboardContent::Text(text) => guard.store.stage_text(&text, hint),
        PasteboardContent::Image(bytes) => guard.store.stage_image(bytes, hint),
    };
    match staged {
        Ok(id) => id.raw(),
        Err(_) => 0,
    }
}

/// Copy a cell's content back out: the core writes the pasteboard
/// itself, marked transient (and concealed when the cell is), and
/// remembers the write for [`companion_clear_clipboard_if_ours`].
/// Copy-out does **not** consume the cell. Returns whether the cell
/// existed.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_cell_copy_out(handle: *mut CompanionHandle, id: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let Some(cell) = guard.store.get(CellId::from_raw(id)) else {
        return false;
    };
    let (kind, concealed) = (cell.kind(), cell.concealed());
    let Some(bytes) = guard.store.copy_out(CellId::from_raw(id)) else {
        return false;
    };
    let kind = match kind {
        CellKind::Text => ContentKind::Text,
        CellKind::Image => ContentKind::Image,
    };
    let receipt = guard
        .pasteboard
        .write(bytes, kind, WriteOptions { concealed });
    guard.last_write = Some(receipt);
    true
}

/// Clear the pasteboard **iff** it still holds our last copy-out — the
/// change-count-guarded clear-after-copy. Never clobbers something the
/// user copied since. Returns whether a clear happened.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_clear_clipboard_if_ours(handle: *mut CompanionHandle) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let Some(receipt) = guard.last_write else {
        return false;
    };
    let cleared = guard.pasteboard.clear_if_unchanged(receipt);
    if cleared {
        guard.last_write = None;
    }
    cleared
}

// ---------------------------------------------------------------------------
// Reading state — non-secret metadata only
// ---------------------------------------------------------------------------

/// A JSON array of non-secret cell summaries, newest first. Recognition
/// lines are masked exactly as the core renders them. The caller owns
/// the returned string and must release it with
/// [`companion_string_free`]. Returns null on error.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_list_json(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let now = guard.store.now();
    let summaries: Vec<serde_json::Value> = guard
        .store
        .cells()
        .map(|cell| summary_json(cell, now))
        .collect();
    match serde_json::to_string(&summaries) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Milliseconds until the earliest cell deadline — the **one** timer the
/// shell arms. Returns `-1` when there is nothing to schedule (no
/// timers ticking, no wakeups), `0` when something is already due.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_next_deadline_ms(handle: *mut CompanionHandle) -> i64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    let Ok(guard) = handle.inner.lock() else {
        return -1;
    };
    let Some(deadline) = guard.store.next_deadline() else {
        return -1;
    };
    let remaining = deadline.saturating_duration_since(guard.store.now());
    i64::try_from(remaining.as_millis()).unwrap_or(i64::MAX)
}

/// Remove and wipe every cell whose deadline has passed — call when the
/// armed timer fires, then re-arm from [`companion_next_deadline_ms`].
/// Returns how many cells expired (the shell drops them from view
/// silently; the user set the clock).
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_expire_due(handle: *mut CompanionHandle) -> u64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return 0;
    };
    guard.store.expire_due().len() as u64
}

// ---------------------------------------------------------------------------
// TTL and discard
// ---------------------------------------------------------------------------

/// Cycle a cell's TTL: next rung on the ladder, clock reset to the full
/// rung value (one affordance for extend, shorten, and reset — doc 04).
/// Returns the new rung code, or `-1` if the cell is gone.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_cell_cycle_ttl(handle: *mut CompanionHandle, id: u64) -> c_int {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return -1;
    };
    match guard.store.cycle_ttl(CellId::from_raw(id)) {
        Some(ttl) => ttl_to_code(ttl),
        None => -1,
    }
}

/// Set a cell to an explicit rung (see the `CompanionRung` codes in the
/// header), resetting the clock to it. Returns `true` when the cell
/// existed and the code was valid.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_cell_set_ttl(
    handle: *mut CompanionHandle,
    id: u64,
    rung: c_int,
) -> bool {
    let Some(ttl) = ttl_from_code(rung) else {
        return false;
    };
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.set_ttl(CellId::from_raw(id), ttl).is_some()
}

/// Discard a cell now; its buffer is wiped as it drops. Returns whether
/// it existed.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_cell_discard(handle: *mut CompanionHandle, id: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.discard(CellId::from_raw(id))
}

// ---------------------------------------------------------------------------
// Dev scaffolding — a seed the spike's demo/drop affordances ingest
// ---------------------------------------------------------------------------

/// Seed the pasteboard with `text` as an external app would, so the
/// spike's "sample cell" button and drop zone have something for
/// [`companion_ingest_pasteboard`] to capture. On macOS this writes the
/// **real** system clipboard (so the button demonstrates a genuine
/// clipboard → core round-trip on device, and — like any capture — it
/// replaces what was on the clipboard); off macOS it seeds the in-process
/// board.
///
/// Demo scaffolding, not a data path: the text it carries is a caller-
/// supplied fixture (a fake sample token, or text a drop already handed
/// the shell), never a copy-out. Because it moves plaintext in the
/// ingest direction (shell → core), the symbol exists only behind the
/// off-by-default `dev-scaffolding` cargo feature
/// (`scripts/build-core.sh --dev-scaffolding`); a default build exports
/// no plaintext-ingest entry point. Returns `false` on a null/invalid
/// argument.
///
/// # Safety
/// `handle` must be a valid handle. `text` must be a valid,
/// NUL-terminated UTF-8 C string.
#[cfg(any(test, feature = "dev-scaffolding"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_dev_seed_pasteboard(
    handle: *mut CompanionHandle,
    text: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(text) = (unsafe { cstr(text) }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard
        .pasteboard
        .put_external(PasteboardContent::Text(text.to_string()), false);
    true
}

/// Free a string returned by this library. Passing null is a no-op.
///
/// # Safety
/// `s` must be a pointer returned by one of this library's `*_json`
/// functions (or null), not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// One cell's non-secret snapshot. The recognition line is the core's
/// masked rendering; there is deliberately no field that could carry
/// plaintext of a concealed cell.
fn summary_json(cell: &Cell, now: std::time::Instant) -> serde_json::Value {
    let remaining = cell.remaining(now);
    serde_json::json!({
        "id": cell.id().raw(),
        "kind": match cell.kind() {
            CellKind::Text => "text",
            CellKind::Image => "image",
        },
        "state": match cell.state(now) {
            LifecycleState::Staged => "staged",
            LifecycleState::Draining => "draining",
            LifecycleState::LastHour => "last_hour",
            LifecycleState::Expired => "expired",
        },
        "concealed": cell.concealed(),
        "detected_as": cell.detected_as(),
        "ttl_code": ttl_to_code(cell.ttl()),
        "ttl_label": cell.ttl().to_string(),
        "remaining_ms": u64::try_from(remaining.as_millis()).unwrap_or(u64::MAX),
        "remaining_label": cell.ttl_label(now),
        "spoken_remaining": spoken_remaining(remaining),
        "recognition": cell.recognition_line(),
        "display_size": cell.content().display_size(),
        "promoted": cell.promotion().is_some(),
    })
}

/// The `VoiceOver` text-equivalent of the draining ring: coarse, natural,
/// honest words — never colour or motion alone (doc 05 a11y).
fn spoken_remaining(remaining: Duration) -> String {
    let secs = remaining.as_secs();
    if secs == 0 {
        return "expired".to_string();
    }
    if secs < 60 {
        return "less than a minute remaining".to_string();
    }
    let (n, unit) = if secs < 60 * 60 {
        (secs / 60, "minute")
    } else if secs < 24 * 60 * 60 {
        (secs / (60 * 60), "hour")
    } else {
        (secs / (24 * 60 * 60), "day")
    };
    let plural = if n == 1 { "" } else { "s" };
    format!("about {n} {unit}{plural} remaining")
}

/// Borrow a C string as `&str`, or `None` if null / not valid UTF-8.
/// Only the dev-scaffolding entry point takes a string in; everything
/// else hands strings out.
///
/// # Safety
/// `p` must be null or a valid NUL-terminated C string.
#[cfg(any(test, feature = "dev-scaffolding"))]
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

/// Map a rung code (as used across the C ABI) to a [`Ttl`]. Codes follow
/// ladder order: `0=1h, 1=3h, 2=8h, 3=24h, 4=3d, 5=7d`.
fn ttl_from_code(code: c_int) -> Option<Ttl> {
    usize::try_from(code)
        .ok()
        .and_then(|i| TTL_LADDER.get(i))
        .and_then(|d| Ttl::from_secs(d.as_secs()))
}

/// Map a [`Ttl`] to its C ABI rung code.
fn ttl_to_code(ttl: Ttl) -> c_int {
    TTL_LADDER
        .iter()
        .position(|d| *d == ttl.duration())
        .and_then(|i| c_int::try_from(i).ok())
        .unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A handle whose pasteboard holds `text`, exactly as the shell
    /// would meet it. Built on the in-process board directly — never
    /// `companion_new` — so the tests stay deterministic and never read
    /// or clobber a real clipboard on macOS, where `companion_new` now
    /// binds `NSPasteboard.general`.
    fn handle_with_text(text: &str) -> *mut CompanionHandle {
        let mut pasteboard = MemoryPasteboard::new();
        pasteboard.put_external(PasteboardContent::Text(text.to_string()), false);
        let companion = Companion {
            store: CellStore::new(SystemClock),
            pasteboard: Board::Memory(pasteboard),
            last_write: None,
        };
        Box::into_raw(Box::new(CompanionHandle {
            inner: Mutex::new(companion),
        }))
    }

    unsafe fn take_json(p: *mut c_char) -> String {
        assert!(!p.is_null(), "expected a JSON string, got null");
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
        unsafe { companion_string_free(p) };
        s
    }

    #[test]
    fn rung_codes_round_trip() {
        for (i, d) in TTL_LADDER.iter().enumerate() {
            let ttl = Ttl::from_secs(d.as_secs()).unwrap();
            let code = ttl_to_code(ttl);
            assert_eq!(usize::try_from(code).unwrap(), i);
            assert_eq!(ttl_from_code(code), Some(ttl));
        }
        assert_eq!(ttl_from_code(-1), None);
        assert_eq!(ttl_from_code(99), None);
    }

    #[test]
    fn ingest_list_shows_masked_recognition_never_the_secret() {
        // PAT-shaped, assembled at runtime so the raw pattern never
        // appears in the repository text (the secret-scan CI job reads
        // the full history).
        let secret = format!("ghp_{}", "n0ts3cr3t".repeat(4));
        let handle = handle_with_text(&secret);
        unsafe {
            let id = companion_ingest_pasteboard(handle);
            assert_ne!(id, 0);

            let json = take_json(companion_list_json(handle));
            assert!(json.contains("••••"), "recognition should be masked");
            assert!(json.contains("GitHub token"), "detection is reported");
            assert!(
                !json.contains("n0ts3cr3t"),
                "the raw secret must never appear in the FFI output: {json}"
            );

            companion_free(handle);
        }
    }

    #[test]
    fn copy_out_writes_the_pasteboard_in_core_and_guarded_clear_works() {
        let handle = handle_with_text("on its way somewhere else");
        unsafe {
            let id = companion_ingest_pasteboard(handle);
            assert_ne!(id, 0);

            // The core writes the pasteboard itself; the shell never
            // holds the bytes.
            assert!(companion_cell_copy_out(handle, id));
            {
                let guard = (*handle).inner.lock().unwrap();
                assert!(
                    guard.pasteboard.current_is_transient(),
                    "outbound copies carry the transient mark"
                );
            }

            // Copy-out does not consume the cell.
            let json = take_json(companion_list_json(handle));
            assert!(json.contains("\"id\":"));

            // Guarded clear: succeeds while the board still holds our
            // write, refuses after the user copies something else.
            assert!(companion_clear_clipboard_if_ours(handle));
            assert!(
                !companion_clear_clipboard_if_ours(handle),
                "already cleared"
            );

            companion_free(handle);
        }
    }

    #[test]
    fn scheduling_surface_reports_deadlines() {
        let handle = handle_with_text("tempus fugit");
        unsafe {
            assert_eq!(
                companion_next_deadline_ms(handle),
                -1,
                "empty store: nothing to arm"
            );
            let id = companion_ingest_pasteboard(handle);
            assert_ne!(id, 0);

            // Default rung is 8h; the one armed timer is under that and
            // far above zero.
            let ms = companion_next_deadline_ms(handle);
            assert!(ms > 7 * 60 * 60 * 1000, "deadline ms: {ms}");
            assert!(ms <= 8 * 60 * 60 * 1000, "deadline ms: {ms}");

            assert_eq!(companion_expire_due(handle), 0, "nothing due yet");
            companion_free(handle);
        }
    }

    #[test]
    fn ttl_and_discard_over_the_abi() {
        let handle = handle_with_text("value");
        unsafe {
            let id = companion_ingest_pasteboard(handle);
            assert!(companion_cell_set_ttl(handle, id, 0)); // 1h
            let new_code = companion_cell_cycle_ttl(handle, id); // -> 3h
            assert_eq!(new_code, 1);
            assert!(!companion_cell_set_ttl(handle, id, 99), "bad rung code");
            assert!(companion_cell_discard(handle, id));
            assert!(!companion_cell_discard(handle, id), "already gone");
            companion_free(handle);
        }
    }

    #[test]
    fn null_handles_are_handled_gracefully() {
        unsafe {
            assert_eq!(companion_ingest_pasteboard(ptr::null_mut()), 0);
            assert!(companion_list_json(ptr::null_mut()).is_null());
            assert!(!companion_cell_discard(ptr::null_mut(), 1));
            assert!(!companion_cell_copy_out(ptr::null_mut(), 1));
            assert_eq!(companion_next_deadline_ms(ptr::null_mut()), -1);
            companion_free(ptr::null_mut()); // no-op
            companion_string_free(ptr::null_mut()); // no-op
        }
    }

    #[test]
    fn spoken_remaining_reads_in_words() {
        assert_eq!(spoken_remaining(Duration::ZERO), "expired");
        assert_eq!(
            spoken_remaining(Duration::from_secs(30)),
            "less than a minute remaining"
        );
        assert_eq!(
            spoken_remaining(Duration::from_secs(60)),
            "about 1 minute remaining"
        );
        assert_eq!(
            spoken_remaining(Duration::from_secs(3 * 60 * 60)),
            "about 3 hours remaining"
        );
        assert_eq!(
            spoken_remaining(Duration::from_secs(3 * 24 * 60 * 60)),
            "about 3 days remaining"
        );
    }
}
