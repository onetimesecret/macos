//! # companion-ffi — the only crate a non-Rust shell may call
//!
//! A thin C ABI over the core, speaking interaction-model rev C:
//! sheets of ink and sealed chips. It hands the shell **handles**
//! (sheet and chip ids as `u64`), **non-secret metadata** (summary and
//! ledger JSON, chip excerpts), and **action results** (booleans,
//! counts) — and never a sealed byte. The boundary law, hard form
//! (docs/spec/05, amended by rev C):
//!
//! > Sealed bytes never reach the UI layer. Sealed content has no
//! > display form at all — the UI receives only the mechanical excerpt
//! > and counts, so it can never draw the bytes, and no reveal
//! > affordance can exist.
//!
//! Every direction that moves sealed bytes stays inside the core:
//!
//! - **Sealed paste (⇧⌘V)**: the core reads the pasteboard itself
//!   ([`companion_sheet_seal_from_pasteboard`]); the shell asks, the
//!   core takes — and clears the board in the same operation, so the
//!   secret's pasteboard dwell ends the moment it is staged (ADR-0007
//!   Amendment 1).
//! - **Copy-out**: the core writes the pasteboard itself
//!   ([`companion_chip_copy_out`]), applying the hygiene contract
//!   (transient + concealed marks, change-count-guarded clear). The
//!   shell never sees the bytes it is copying.
//! - **The one deliberate ingest-direction entry** is
//!   [`companion_sheet_seal_text`], the ⌘↩ retrofit: its argument is
//!   visible ink the shell's editor already holds — not yet sealed,
//!   readable on screen by definition. The gesture moves it into core
//!   custody; from the moment this returns, the shell's obligation is
//!   to delete its copy from the view and forget it. Plaintext flows
//!   *in* here, never *out* anywhere.
//!
//! Visible ink crosses freely in both directions
//! ([`companion_sheet_sync_document`], the ledger) — it renders on
//! screen, so holding it shell-side breaks no law; the core keeps a
//! snapshot for tab titles, the ledger, and page promotion.
//!
//! ## Scheduling, not polling
//!
//! The shell arms **one** timer from [`companion_next_event_ms`] — the
//! earliest page expiry *or* hold lapse — and calls
//! [`companion_expire_due`] when it fires (doc 05 frugality budget).
//! There is deliberately no "tick" entry point.
//!
//! ## Auditing the boundary
//!
//! Scan the exported functions: none returns sealed bytes. Summaries
//! and ledger records carry excerpts and counts; sealing returns a chip
//! id and its excerpt; copy-out returns a boolean. A test below seals a
//! secret through every route and asserts the raw bytes never appear in
//! any output.
//!
//! ## Codegen
//!
//! Hand-written C ABI plus a committed header
//! (`include/companion_ffi.h`) — the stable substrate the
//! `.xcframework` wraps (`scripts/build-core.sh`). ADR-0003.
#![allow(unsafe_code)] // A C ABI requires raw pointers; every unsafe fn documents its contract.

mod persist;
mod promotion;

use std::ffi::CStr;
use std::ffi::{CString, c_char, c_int};
use std::path::Path;
use std::ptr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use companion_credentials::{CredentialStore, credential_store_for, default_credential_store};
use companion_transport::UreqTransport;
use ots_client::Transport as _;
use promotion::{Connection, PromoteOpts, Promoted, ladder_snapped_ttl, promote};

use companion_core::{
    Cause, ChipId, ChipMeta, LedgerSegment, Segment, Sheet, SheetId, SheetStore, SystemClock,
    TTL_LADDER, Ttl,
};
#[cfg(target_os = "macos")]
use companion_pasteboard::SystemPasteboard;
use companion_pasteboard::{
    ChangeCount, ContentKind, MemoryPasteboard, Pasteboard, PasteboardContent, PasteboardItem,
    WriteOptions,
};
use zeroize::{Zeroize, Zeroizing};

/// The pasteboard the core reads and writes through the seam.
///
/// On macOS this is the real system clipboard ([`SystemPasteboard`], the
/// `NSPasteboard` adapter that landed in issue #3). Off macOS — Linux CI,
/// and the unit tests below — it is the in-process [`MemoryPasteboard`],
/// so the seam stays exercisable without a window server and the tests
/// never touch (or depend on) a developer's real clipboard.
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
    /// [`companion_dev_seed_pasteboard`], so demo and test affordances
    /// have something to seal. The real system clipboard has no
    /// unmarked "external put", so on macOS the seed rides the normal
    /// write (transient-marked); sealed paste reads text regardless of
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

    /// Whether the current item carries the concealed mark (tests only,
    /// same reasoning as [`Board::current_is_transient`]).
    #[cfg(test)]
    fn current_is_concealed(&self) -> bool {
        match self {
            Board::Memory(pb) => pb.read().is_some_and(|item| item.concealed),
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

    fn holds_external_content(&self) -> bool {
        match self {
            Board::Memory(pb) => pb.holds_external_content(),
            #[cfg(target_os = "macos")]
            Board::System(pb) => pb.holds_external_content(),
        }
    }
}

/// The core state behind the seam: the sheet store, the pasteboard the
/// core reads and writes itself, and the receipt of our last outbound
/// write (for the guarded clear).
struct Companion {
    store: SheetStore<SystemClock>,
    pasteboard: Board,
    last_write: Option<ChangeCount>,
    /// Where promotion goes (non-secret). `None` until the shell
    /// configures a connection; promotion refuses until then.
    connection: Option<Connection>,
    /// Where the API token rests: the macOS Keychain in the app, the
    /// in-memory store in tests and off macOS. The token itself never
    /// sits in `connection`.
    credentials: Arc<dyn CredentialStore>,
}

/// The credential-store account holding the API token (scoped by the
/// store's service name, `com.onetimesecret.companion`).
const TOKEN_ACCOUNT: &str = "api-token";

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
    new_handle(default_credential_store())
}

/// Same, but with credentials scoped to `service` instead of the
/// default `com.onetimesecret.companion`. A second form factor passes
/// its own bundle id here so its state key is its own item, granted to
/// its own code identity: sharing one item across two signed binaries
/// would make each one's first read a Keychain confirmation prompt for
/// the other's key. A null or non-UTF-8 `service` falls back to the
/// default rather than inventing an unnamed scope.
///
/// # Safety
/// `service` must be null or a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_new_scoped(service: *const c_char) -> *mut CompanionHandle {
    let credentials = match unsafe { cstr(service) } {
        Some(service) if !service.is_empty() => credential_store_for(service),
        _ => default_credential_store(),
    };
    new_handle(credentials)
}

fn new_handle(credentials: Arc<dyn CredentialStore>) -> *mut CompanionHandle {
    companion_core::harden_process();
    // The one place the backend is chosen: the real system clipboard on
    // macOS, the in-process board elsewhere. Everything above this line is
    // identical on both.
    #[cfg(target_os = "macos")]
    let pasteboard = Board::System(SystemPasteboard::new());
    #[cfg(not(target_os = "macos"))]
    let pasteboard = Board::Memory(MemoryPasteboard::new());
    let companion = Companion {
        store: SheetStore::new(SystemClock),
        pasteboard,
        last_write: None,
        connection: None,
        credentials,
    };
    Box::into_raw(Box::new(CompanionHandle {
        inner: Mutex::new(companion),
    }))
}

/// Release a handle created by [`companion_new`], wiping every sealed
/// byte it holds — sheets and ledger alike; exit is total amnesia.
/// Passing null is a no-op.
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
// Sheets: create, close, order
// ---------------------------------------------------------------------------

/// A new page at the end of the tab strip, on the default rung, its
/// countdown started. Returns the sheet id, or `0` when the store
/// refused — the cap is 9, the keyboard wall, and at the wall the app
/// declines the tenth and says so (refuse-don't-evict, doc 04). `0` is
/// never a valid id.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_new(handle: *mut CompanionHandle) -> u64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return 0;
    };
    match guard.store.new_sheet() {
        Ok(id) => id.raw(),
        Err(_) => 0,
    }
}

/// Close a page: it rests in the ledger like an expired one, its sealed
/// bytes zeroized. Returns whether the page existed.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_close(handle: *mut CompanionHandle, id: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.close_sheet(SheetId::from_raw(id))
}

/// Move a page to `index` in the visible order (drag-to-reorder; the
/// ⌘-number map follows). Out-of-range indices clamp to the end.
/// Returns whether the page existed.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_move(
    handle: *mut CompanionHandle,
    id: u64,
    index: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let index = usize::try_from(index).unwrap_or(usize::MAX);
    guard.store.move_sheet(SheetId::from_raw(id), index)
}

// ---------------------------------------------------------------------------
// Sealing — the gesture routes; bytes stay core-side
// ---------------------------------------------------------------------------

/// The sealed paste (⇧⌘V): the core reads the pasteboard itself, seals
/// whatever it holds onto the page — text or image, unread and
/// unclassified; consent is the gesture — and clears the board in the
/// same locked operation, so the secret's pasteboard dwell ends the
/// moment it is staged (ADR-0007 Amendment 1). Returns the new chip's
/// non-secret JSON (see the header; caller frees with
/// [`companion_string_free`]), or null when the board was empty, the
/// page unknown, or the content zero-length. A refused seal clears
/// nothing: the app did not take the content, so it does not destroy
/// it either.
///
/// `cleared_out` (nullable) reports the clear: true when the board was
/// wiped, false when the board's change count moved between the read
/// and the clear — another writer got in, the guarded clear stood
/// down, and the shell must say so, because a paste that leaves
/// content on the board is the failure this route exists to prevent.
///
/// # Safety
/// `handle` must be a valid handle. `cleared_out`, when non-null, must
/// point to writable memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_seal_from_pasteboard(
    handle: *mut CompanionHandle,
    sheet: u64,
    cleared_out: *mut bool,
) -> *mut c_char {
    if !cleared_out.is_null() {
        unsafe { cleared_out.write(false) };
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    // Observed before the read: if another writer lands after this
    // count is taken, the guarded clear below refuses — never wiping
    // content the read did not see.
    let count = guard.pasteboard.change_count();
    let Some(item) = guard.pasteboard.read() else {
        return ptr::null_mut();
    };
    let sheet = SheetId::from_raw(sheet);
    let sealed = match item.content {
        PasteboardContent::Text(mut text) => {
            // The board handed us an owned copy of what may now be a
            // secret; the core takes its own custody copy, so wipe this
            // transit copy instead of letting it drop unwiped.
            let sealed = guard.store.seal_text(sheet, &text);
            text.zeroize();
            sealed
        }
        PasteboardContent::Image(bytes) => guard.store.seal_image(sheet, bytes),
    };
    match sealed {
        Ok(chip) => {
            let cleared = guard.pasteboard.clear_if_unchanged(count);
            if !cleared_out.is_null() {
                unsafe { cleared_out.write(cleared) };
            }
            chip_json(&guard.store, sheet, chip)
        }
        Err(_) => ptr::null_mut(),
    }
}

/// Whether the system pasteboard currently holds content a sealed
/// paste could take: non-empty, representable (text or image), and not
/// the companion's own transient write — offering to re-ingest a
/// copy-out would be a loop, not a service. Answered from type
/// metadata alone; no content bytes cross into the process. Powers the
/// summon-time offer (ADR-0007 Amendment 1).
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_pasteboard_has_content(handle: *mut CompanionHandle) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    guard.pasteboard.holds_external_content()
}

/// The ⌘↩ retrofit: seal `text` — the selection, or the current line —
/// onto the page. This is the seam's one deliberate ingest-direction
/// plaintext entry: the argument is visible ink the shell's editor
/// already holds, readable on screen by definition; the gesture moves
/// it into core custody. From the moment this returns, the shell must
/// delete its copy from the view and forget it — undo never un-seals
/// (doc 06 №5). Returns the new chip's non-secret JSON (caller frees),
/// or null for an unknown page or empty text.
///
/// # Safety
/// `handle` must be a valid handle. `text` must be a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_seal_text(
    handle: *mut CompanionHandle,
    sheet: u64,
    text: *const c_char,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(text) = (unsafe { cstr(text) }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let sheet = SheetId::from_raw(sheet);
    match guard.store.seal_text(sheet, text) {
        Ok(chip) => chip_json(&guard.store, sheet, chip),
        Err(_) => ptr::null_mut(),
    }
}

/// Drop-to-seal: the core reads the **drag pasteboard** itself
/// (`NSPasteboardNameDrag` — the board an in-flight drag session's
/// content rides on) and seals it onto the page. This is the
/// boundary-lawful drag route (docs/hardware-verification.md): dropped
/// bytes never transit the shell; the drop gesture is the consent, and
/// the shell only names the page. Call it from the drop handler while
/// the drag session's data is still on the board. Returns chip JSON as
/// the other seal routes do (caller frees), or null — unknown page,
/// empty or unreadable drag content, or an off-macOS build (no drag
/// board exists there).
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_seal_from_drag(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (handle, sheet);
        ptr::null_mut()
    }
    #[cfg(target_os = "macos")]
    {
        let Ok(mut guard) = handle.inner.lock() else {
            return ptr::null_mut();
        };
        // Bound fresh per call: the drag board's content belongs to the
        // current drag session, not to this handle's lifetime.
        let Some(item) = SystemPasteboard::drag().read() else {
            return ptr::null_mut();
        };
        let sheet = SheetId::from_raw(sheet);
        let sealed = match item.content {
            PasteboardContent::Text(mut text) => {
                // Same custody rule as the sealed paste: wipe the owned
                // transit copy once the core has taken its own.
                let sealed = guard.store.seal_text(sheet, &text);
                text.zeroize();
                sealed
            }
            PasteboardContent::Image(bytes) => guard.store.seal_image(sheet, bytes),
        };
        match sealed {
            Ok(chip) => chip_json(&guard.store, sheet, chip),
            Err(_) => ptr::null_mut(),
        }
    }
}

// ---------------------------------------------------------------------------
// The synced document
// ---------------------------------------------------------------------------

/// Replace a page's document snapshot: a JSON array of runs, in
/// document order — `{"ink": "text"}` for visible ink, `{"chip": id}`
/// where a sealed chip sits. The shell owns the live document; this
/// mirror exists for tab titles, the ledger, and page promotion.
///
/// The snapshot is **authoritative for chip liveness**: a chip of this
/// sheet the snapshot no longer references was deleted in the editor,
/// and its bytes are zeroized here. A malformed snapshot (bad JSON, a
/// chip this sheet does not own, a duplicate reference) is rejected
/// whole. The shell must send a snapshot that reflects every chip
/// sealed before this call. Returns whether it was accepted.
///
/// # Safety
/// `handle` must be a valid handle. `json` must be a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_sync_document(
    handle: *mut CompanionHandle,
    sheet: u64,
    json: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(json) = (unsafe { cstr(json) }) else {
        return false;
    };
    let Some(segments) = parse_segments(json) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard
        .store
        .sync_document(SheetId::from_raw(sheet), segments)
}

// ---------------------------------------------------------------------------
// Chips: copy-out, delete
// ---------------------------------------------------------------------------

/// Copy a chip's bytes back out: the core writes the pasteboard itself,
/// marked transient **and concealed** (a chip is sealed by definition),
/// and remembers the write for [`companion_clear_clipboard_if_ours`].
/// Copy-out does **not** consume the chip — multi-paste is a core
/// moment. Returns whether the chip existed.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_copy_out(handle: *mut CompanionHandle, chip: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let Some((bytes, meta)) = guard.store.copy_out_chip(ChipId::from_raw(chip)) else {
        return false;
    };
    let kind = match meta {
        ChipMeta::Text { .. } => ContentKind::Text,
        ChipMeta::Image { .. } => ContentKind::Image,
    };
    let receipt = guard
        .pasteboard
        .write(bytes, kind, WriteOptions { concealed: true });
    guard.last_write = Some(receipt);
    true
}

/// Remove a chip now, wherever it sits; its bytes are wiped as it
/// drops (⌫ removes it whole; there is no resurrection path). Returns
/// whether the chip existed.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_delete(handle: *mut CompanionHandle, chip: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.delete_chip(ChipId::from_raw(chip))
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

/// A JSON array of non-secret page summaries, in visible (tab) order.
/// The caller owns the returned string and must release it with
/// [`companion_string_free`]. Returns null on error.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheets_json(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let now = guard.store.now();
    let summaries: Vec<serde_json::Value> = guard
        .store
        .sheets()
        .map(|sheet| summary_json(sheet, now))
        .collect();
    match serde_json::to_string(&summaries) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// The ledger (⌘0): dead pages, newest first — dimmed ink and chip
/// tombstones, session-bound, read-only. Sealed bytes were zeroized at
/// death; a tombstone carries only the excerpt that always rendered.
/// The caller owns the returned string and must release it with
/// [`companion_string_free`]. Returns null on error.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_ledger_json(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let now = guard.store.now();
    let records: Vec<serde_json::Value> = guard
        .store
        .ledger()
        .map(|record| {
            let segments: Vec<serde_json::Value> = record
                .segments()
                .iter()
                .map(|segment| match segment {
                    LedgerSegment::Ink(text) => serde_json::json!({ "ink": text }),
                    LedgerSegment::Tombstone { excerpt } => {
                        serde_json::json!({ "tombstone": excerpt })
                    }
                })
                .collect();
            serde_json::json!({
                "cause": match record.cause() {
                    Cause::Expired => "expired",
                    Cause::Closed => "closed",
                },
                "title": record.title(),
                "age_ms": u64::try_from(
                    now.saturating_duration_since(record.died_at()).as_millis()
                ).unwrap_or(u64::MAX),
                "segments": segments,
            })
        })
        .collect();
    match serde_json::to_string(&records) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// A live page's document, replayed for a shell rebuilding its editor
/// after a restore: `[{"ink": "…"}, {"chip": {…}}, …]` in document
/// order, each chip as the same non-secret face the seal routes return
/// (id, kind, excerpt, size label, promoted) — the boundary law holds:
/// ink renders anyway, and a chip crosses as its face, never its bytes.
/// The caller owns the returned string and must release it with
/// [`companion_string_free`]. Returns null for an unknown page.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_document_json(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let Some(sheet) = guard.store.sheet(SheetId::from_raw(sheet)) else {
        return ptr::null_mut();
    };
    let runs: Vec<serde_json::Value> = sheet
        .segments()
        .iter()
        .filter_map(|segment| match segment {
            Segment::Ink(text) => Some(serde_json::json!({ "ink": text })),
            Segment::Chip(chip_id) => sheet.chip(*chip_id).map(|chip| {
                serde_json::json!({ "chip": {
                    "chip_id": chip.id().raw(),
                    "kind": match chip.meta() {
                        ChipMeta::Text { .. } => "text",
                        ChipMeta::Image { .. } => "image",
                    },
                    "excerpt": chip.excerpt(),
                    "size_label": chip.size_label(),
                    "promoted": chip.promotion().is_some(),
                }})
            }),
        })
        .collect();
    match serde_json::to_string(&runs) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Milliseconds until the next scheduled instant — the earliest page
/// expiry or hold lapse, whichever comes first. This is the **one**
/// timer the shell arms. Returns `-1` when there is nothing to
/// schedule (no timers ticking, no wakeups), `0` when something is
/// already due.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_next_event_ms(handle: *mut CompanionHandle) -> i64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    let Ok(guard) = handle.inner.lock() else {
        return -1;
    };
    let Some(at) = guard.store.next_event() else {
        return -1;
    };
    let remaining = at.saturating_duration_since(guard.store.now());
    i64::try_from(remaining.as_millis()).unwrap_or(i64::MAX)
}

/// Settle the clock — call when the armed timer fires, then re-arm from
/// [`companion_next_event_ms`]. Lapsed holds become regular pages
/// again; every page at zero moves to the ledger, its sealed bytes
/// zeroized. Returns how many pages expired (the shell drops them from
/// view silently; the user set the clock).
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
// Persistence — the sealed state file (JIT encryption at quit)
// ---------------------------------------------------------------------------

/// Save the whole store — sheets, sealed chips, clocks, the ledger — to
/// `path`, encrypted with ChaCha20-Poly1305 under a 32-byte key that
/// rests in the OS credential store (`state-key` account, minted on
/// first save). Only ciphertext touches disk; the plaintext snapshot is
/// wiped before this returns. The write is atomic (temp file + rename)
/// and owner-only. The shell calls this on every mutation, debounced,
/// and again at quit to flush what is still pending (ADR-0012); the
/// core still saves nothing on its own.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid NUL-terminated
/// UTF-8 path whose parent directory exists.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_persist_save(
    handle: *mut CompanionHandle,
    path: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(path) = (unsafe { cstr(path) }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    let Some(wall_ms) = wall_now_ms() else {
        return false;
    };
    let Some(key) = persist::ensure_state_key(guard.credentials.as_ref()) else {
        return false;
    };
    let snapshot = guard.store.snapshot(wall_ms);
    let Some(sealed) = persist::seal_state(&key, &snapshot) else {
        return false;
    };
    persist::write_private(Path::new(path), &sealed)
}

/// Restore the store from a state file [`companion_persist_save`]
/// wrote: decrypt (the key comes from the credential store — never
/// minted here), replace the store's sheets and ledger, and drain every
/// countdown by the wall time that passed while the app was closed.
/// Pages that came due while away expire into the ledger immediately.
/// Meant for startup, before the first page is created. Returns whether
/// a state was restored — false covers "no file yet" (a fresh start,
/// not an error) as well as a missing key, failed authentication, or a
/// damaged snapshot.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid NUL-terminated
/// UTF-8 path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_persist_restore(
    handle: *mut CompanionHandle,
    path: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(path) = (unsafe { cstr(path) }) else {
        return false;
    };
    let Ok(file) = std::fs::read(path) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let Some(key) = persist::load_state_key(guard.credentials.as_ref()) else {
        return false;
    };
    let Some(plaintext) = persist::open_state(&key, &file) else {
        return false;
    };
    let Some(wall_ms) = wall_now_ms() else {
        return false;
    };
    if guard.store.restore(&plaintext, wall_ms).is_err() {
        return false;
    }
    // Deaths-while-away leave ledger residue like any other death.
    guard.store.expire_due();
    true
}

/// Unix epoch milliseconds, for stamping and aging snapshots.
fn wall_now_ms() -> Option<u64> {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .and_then(|d| u64::try_from(d.as_millis()).ok())
}

// ---------------------------------------------------------------------------
// Time: the ladder and the pause
// ---------------------------------------------------------------------------

/// Cycle a page's countdown label: next rung on the ladder, clock
/// *reset* to the full rung value (each click resets the clock to the
/// shown rung — doc 04). A held page keeps its hold. Returns the new
/// rung code, or `-1` if the page is gone.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_cycle_rung(
    handle: *mut CompanionHandle,
    id: u64,
) -> c_int {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return -1;
    };
    match guard.store.cycle_rung(SheetId::from_raw(id)) {
        Some(rung) => ttl_to_code(rung),
        None => -1,
    }
}

/// Set a page to an explicit rung (see the `CompanionRung` codes in the
/// header), resetting the clock to it. Returns `true` when the page
/// existed and the code was valid.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_set_rung(
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
    guard.store.set_rung(SheetId::from_raw(id), ttl).is_some()
}

/// The pause gesture (double-click a tab): the first press holds the
/// page's clock for **1 hour**; a press while held tops the hold up to
/// **24 hours from now** — never cumulative. A pause holds the clock;
/// it never extends the rung. The hold lapses on its own — the lapse
/// is folded into [`companion_next_event_ms`]. Returns false for an
/// unknown or already-due page.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_pause_press(
    handle: *mut CompanionHandle,
    id: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.pause_press(SheetId::from_raw(id))
}

// ---------------------------------------------------------------------------
// Promotion — the exit ramp, the app's only network action
// ---------------------------------------------------------------------------

/// Configure where promotion goes. `json` carries the non-secret
/// connection config plus, optionally, the API token in transit to the
/// credential store:
///
/// ```json
/// { "server_url": "https://eu.onetimesecret.com",
///   "share_domain": "",           // empty → the server's host
///   "extid": "org_…",             // empty → guest-only
///   "token": "…" }                // absent: keep stored token;
///                                 // empty string: delete it
/// ```
///
/// The token goes straight to the OS credential store (Keychain on
/// macOS) and is never retained in config — the shell should pass it
/// only when the user (re)enters it in Settings. Refuses (`false`) a
/// malformed JSON object or a non-`https` server URL: the network
/// boundary is TLS-only and enforcement starts here, not at the socket.
///
/// # Safety
/// `handle` must be a valid handle. `json` must be a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_connection_configure(
    handle: *mut CompanionHandle,
    json: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(json) = (unsafe { cstr(json) }) else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(json) else {
        return false;
    };
    let Some(server_url) = value.get("server_url").and_then(serde_json::Value::as_str) else {
        return false;
    };
    let server_url = server_url.trim_end_matches('/');
    if !server_url.starts_with("https://") || server_url.len() <= "https://".len() {
        return false;
    }
    let field = |key: &str| {
        value
            .get(key)
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .to_owned()
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.connection = Some(Connection {
        server_url: server_url.to_owned(),
        share_domain: field("share_domain"),
        extid: field("extid"),
    });
    match value.get("token").and_then(serde_json::Value::as_str) {
        Some("") => guard.credentials.delete(TOKEN_ACCOUNT).is_ok(),
        Some(token) => guard
            .credentials
            .store(TOKEN_ACCOUNT, token.as_bytes())
            .is_ok(),
        None => true,
    }
}

/// The connection as the shell may render it — configuration state
/// only, never the token itself. Returns
/// `{"configured", "server_url", "share_domain", "extid", "has_token"}`
/// (or null on an invalid handle); free with [`companion_string_free`].
///
/// `has_token` is an **existence** check — does the credential store
/// hold a token — decided without reading the secret. So calling this
/// at launch to render Settings never provokes the Keychain ACL prompt;
/// that prompt is reserved for the read a promotion actually needs.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_connection_json(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    // Existence, not a read: this must not decrypt the token (see the
    // CredentialStore::exists contract). On a backend hiccup, fail to
    // "no token" — rendering Settings must never wedge on the Keychain.
    let has_token = guard.credentials.exists(TOKEN_ACCOUNT).unwrap_or(false);
    let json = match &guard.connection {
        Some(conn) => serde_json::json!({
            "configured": true,
            "server_url": conn.server_url,
            "share_domain": conn.share_domain,
            "extid": conn.extid,
            "has_token": has_token,
        }),
        None => serde_json::json!({
            "configured": false,
            "server_url": "",
            "share_domain": "",
            "extid": "",
            "has_token": has_token,
        }),
    };
    into_c_string(json.to_string())
}

/// The Settings "test" button: one `GET /api/v3/status` against the
/// configured server. **Blocks for the round-trip** — call from a
/// background queue, never the main thread. The core mutex is held only
/// long enough to copy the connection config; a summon during a slow
/// test never waits on the network. Returns `{"ok"}` or
/// `{"ok": false, "error"}`; free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_connection_test(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let conn = {
        let Ok(guard) = handle.inner.lock() else {
            return ptr::null_mut();
        };
        guard.connection.clone()
    };
    let Some(conn) = conn else {
        return promotion_error("no connection configured");
    };
    let api = ots_client::Api::new(conn.server_url, Box::new(ots_client::NoAuth));
    let result = match companion_transport::UreqTransport::new().send(api.status_request()) {
        Ok(response) if (200..300).contains(&response.status) => {
            serde_json::json!({ "ok": true })
        }
        Ok(response) => serde_json::json!({
            "ok": false,
            "error": format!("the server answered {}", response.status),
        }),
        Err(e) => serde_json::json!({
            "ok": false,
            "error": format!("could not reach the server: {e}"),
        }),
    };
    into_c_string(result.to_string())
}

/// Promote one sealed chip into a one-time link: the ↗ on a chip's
/// hover actions. `opts_json` is `{"ttl_secs"?, "passphrase"?,
/// "recipient"?}` or null (all defaults; TTL defaults to the page's
/// remaining time snapped **down** the ladder). The sealed bytes travel
/// core → client → transport and never through the caller; on success
/// the share link is on the clipboard (transient-marked) and only the
/// receipt id stays on the chip. **Blocks for the round-trip** — call
/// from a background queue. The core mutex is released during the
/// network call; on failure nothing has left the sheet.
///
/// Returns `{"ok": true, "receipt_id"}` or `{"ok": false, "error"}`;
/// free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle. `opts_json`, when non-null, must be
/// a valid, NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_promote(
    handle: *mut CompanionHandle,
    chip: u64,
    opts_json: *const c_char,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(opts) = PromoteOpts::parse(unsafe { cstr(opts_json) }) else {
        return promotion_error("malformed promotion options");
    };
    let chip = ChipId::from_raw(chip);

    // Under the lock: assemble everything the network call needs, then
    // let go — a slow server must never block a summon.
    let staged = {
        let Ok(guard) = handle.inner.lock() else {
            return ptr::null_mut();
        };
        let Some(conn) = guard.connection.clone() else {
            return promotion_error("no connection configured");
        };
        let holder = guard
            .store
            .sheets()
            .find(|sheet| sheet.chip(chip).is_some());
        let Some(sheet) = holder else {
            return promotion_error("that content is gone");
        };
        if matches!(
            sheet.chip(chip).map(companion_core::SealedChip::meta),
            Some(ChipMeta::Image { .. })
        ) {
            return promotion_error(
                "this chip holds an image, which cannot travel as a text secret yet",
            );
        }
        let default_ttl = ladder_snapped_ttl(sheet.remaining(guard.store.now()));
        let Some(bytes) = guard.store.chip_payload(chip) else {
            return promotion_error("that content is gone");
        };
        let Ok(text) = std::str::from_utf8(&bytes) else {
            return promotion_error("this chip is not text");
        };
        let payload = Zeroizing::new(text.to_owned());
        (conn, load_token(&*guard.credentials), payload, default_ttl)
    };
    let (conn, token, payload, default_ttl) = staged;

    match promote(
        &conn,
        token,
        payload,
        &opts,
        default_ttl,
        UreqTransport::new(),
    ) {
        Ok(promoted) => finish_promotion(handle, promoted, Some(chip)),
        Err(message) => promotion_error(&message),
    }
}

/// Promote the whole page: the ↗ page in the footer. The payload is the
/// page in document order — ink verbatim, sealed bytes inlined where
/// their chips sit — refused when the page holds an image chip. Options,
/// blocking behaviour, locking, and the result shape match
/// [`companion_chip_promote`]; no per-chip promotion mark is set (the
/// link stands for the page — "burn local copy" on success is the
/// shell closing the sheet).
///
/// # Safety
/// `handle` must be a valid handle. `opts_json`, when non-null, must be
/// a valid, NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_promote(
    handle: *mut CompanionHandle,
    sheet: u64,
    opts_json: *const c_char,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(opts) = PromoteOpts::parse(unsafe { cstr(opts_json) }) else {
        return promotion_error("malformed promotion options");
    };
    let sheet = SheetId::from_raw(sheet);

    let staged = {
        let Ok(guard) = handle.inner.lock() else {
            return ptr::null_mut();
        };
        let Some(conn) = guard.connection.clone() else {
            return promotion_error("no connection configured");
        };
        let payload = match guard.store.sheet_payload(sheet) {
            Ok(payload) => payload,
            Err(e) => return promotion_error(&e.to_string()),
        };
        if payload.trim().is_empty() {
            return promotion_error("nothing to promote");
        }
        let default_ttl = guard
            .store
            .sheet(sheet)
            .map_or(TTL_LADDER[0].as_secs(), |s| {
                ladder_snapped_ttl(s.remaining(guard.store.now()))
            });
        (conn, load_token(&*guard.credentials), payload, default_ttl)
    };
    let (conn, token, payload, default_ttl) = staged;

    match promote(
        &conn,
        token,
        payload,
        &opts,
        default_ttl,
        UreqTransport::new(),
    ) {
        Ok(promoted) => finish_promotion(handle, promoted, None),
        Err(message) => promotion_error(&message),
    }
}

/// The stored API token as a zeroizing string, if present and UTF-8.
fn load_token(credentials: &dyn CredentialStore) -> Option<Zeroizing<String>> {
    let bytes = credentials.load(TOKEN_ACCOUNT).ok()?;
    std::str::from_utf8(&bytes)
        .ok()
        .map(|s| Zeroizing::new(s.to_owned()))
}

/// After a successful conceal: the link onto the clipboard (transient —
/// the link is a capability, not the secret, but no pasteboard manager
/// should archive it), the receipt id onto the chip when one was
/// promoted, and the result JSON out.
fn finish_promotion(
    handle: &CompanionHandle,
    promoted: Promoted,
    chip: Option<ChipId>,
) -> *mut c_char {
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let receipt = guard.pasteboard.write(
        Zeroizing::new(promoted.link.into_bytes()),
        ContentKind::Text,
        WriteOptions { concealed: false },
    );
    guard.last_write = Some(receipt);
    if let Some(chip) = chip {
        // The chip may have expired mid-flight; the link is on the
        // clipboard regardless, the mark just has nowhere to land.
        guard
            .store
            .mark_chip_promoted(chip, promoted.receipt_id.clone());
    }
    into_c_string(serde_json::json!({ "ok": true, "receipt_id": promoted.receipt_id }).to_string())
}

/// A `{"ok": false, "error"}` result. Error strings are messages for
/// the inline failure state and never carry secret material.
fn promotion_error(message: &str) -> *mut c_char {
    into_c_string(serde_json::json!({ "ok": false, "error": message }).to_string())
}

// ---------------------------------------------------------------------------
// Dev scaffolding — a seed for demo/test affordances
// ---------------------------------------------------------------------------

/// Seed the pasteboard with `text` as an external app would, so demo
/// affordances have something for
/// [`companion_sheet_seal_from_pasteboard`] to seal. On macOS this
/// writes the **real** system clipboard (so the button demonstrates a
/// genuine clipboard → core round-trip on device, and — like any
/// capture — it replaces what was on the clipboard); off macOS it
/// seeds the in-process board.
///
/// Demo scaffolding, not a data path: the text it carries is a caller-
/// supplied fixture, never a copy-out. The symbol exists only behind
/// the off-by-default `dev-scaffolding` cargo feature
/// (`scripts/build-core.sh --dev-scaffolding`). Returns `false` on a
/// null/invalid argument.
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
/// `s` must be a pointer returned by one of this library's `*_json` or
/// seal functions (or null), not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// One page's non-secret snapshot. There is deliberately no field that
/// could carry sealed content — excerpts live in the chip JSON returned
/// at seal time and in ledger tombstones, and those are the only
/// rendering sealed content ever gets.
fn summary_json(sheet: &Sheet, now: std::time::Instant) -> serde_json::Value {
    let remaining = sheet.remaining(now);
    serde_json::json!({
        "id": sheet.id().raw(),
        "title": sheet.title(),
        "rung_code": ttl_to_code(sheet.rung()),
        "rung_label": sheet.rung().to_string(),
        "remaining_ms": u64::try_from(remaining.as_millis()).unwrap_or(u64::MAX),
        "remaining_label": sheet.remaining_label(now),
        "spoken_remaining": spoken_remaining(remaining),
        "fraction_remaining": f64::from(sheet.fraction_remaining(now)),
        "paused": sheet.is_held(now),
        "hold_remaining_ms":
            u64::try_from(sheet.hold_remaining(now).as_millis()).unwrap_or(u64::MAX),
        "chip_count": sheet.chip_count(),
        "last_hour": sheet.last_hour(now),
    })
}

/// A freshly sealed chip's non-secret face, as an owned C string.
fn chip_json(store: &SheetStore<SystemClock>, sheet: SheetId, chip: ChipId) -> *mut c_char {
    let Some(sealed) = store.sheet(sheet).and_then(|s| s.chip(chip)) else {
        return ptr::null_mut();
    };
    let value = serde_json::json!({
        "chip_id": sealed.id().raw(),
        "kind": match sealed.meta() {
            ChipMeta::Text { .. } => "text",
            ChipMeta::Image { .. } => "image",
        },
        "excerpt": sealed.excerpt(),
        "size_label": sealed.size_label(),
        "promoted": sealed.promotion().is_some(),
    });
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Parse the synced-document JSON: `[{"ink": "…"}, {"chip": 7}, …]`.
fn parse_segments(json: &str) -> Option<Vec<Segment>> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let runs = value.as_array()?;
    let mut segments = Vec::with_capacity(runs.len());
    for run in runs {
        let object = run.as_object()?;
        if object.len() != 1 {
            return None;
        }
        if let Some(ink) = object.get("ink") {
            segments.push(Segment::Ink(ink.as_str()?.to_string()));
        } else if let Some(chip) = object.get("chip") {
            segments.push(Segment::Chip(ChipId::from_raw(chip.as_u64()?)));
        } else {
            return None;
        }
    }
    Some(segments)
}

/// The `VoiceOver` text-equivalent of the draining gauge: coarse,
/// natural, honest words — never colour or motion alone (doc 05 a11y).
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

    /// A handle over the in-process board — never `companion_new`, so
    /// the tests stay deterministic and never read or clobber a real
    /// clipboard on macOS, where `companion_new` binds
    /// `NSPasteboard.general`.
    fn handle() -> *mut CompanionHandle {
        handle_with(Arc::new(
            companion_credentials::InMemoryCredentialStore::default(),
        ))
    }

    /// Same, sharing `credentials` — two handles with one credential
    /// store model two launches of the app against one keychain.
    fn handle_with(credentials: Arc<dyn CredentialStore>) -> *mut CompanionHandle {
        let companion = Companion {
            store: SheetStore::new(SystemClock),
            pasteboard: Board::Memory(MemoryPasteboard::new()),
            last_write: None,
            connection: None,
            credentials,
        };
        Box::into_raw(Box::new(CompanionHandle {
            inner: Mutex::new(companion),
        }))
    }

    fn seed(handle: *mut CompanionHandle, text: &str) {
        let guard = unsafe { &*handle };
        let mut guard = guard.inner.lock().unwrap();
        guard
            .pasteboard
            .put_external(PasteboardContent::Text(text.to_string()), false);
    }

    unsafe fn take_json(p: *mut c_char) -> String {
        assert!(!p.is_null(), "expected a JSON string, got null");
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
        unsafe { companion_string_free(p) };
        s
    }

    fn cstring(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    /// The drag route reads the real drag pasteboard core-side. macOS
    /// only — the drag board exists only there; off macOS the entry
    /// returns null by construction. Seeding the shared drag board is
    /// safe: no drag session is in flight while tests run.
    #[cfg(target_os = "macos")]
    #[test]
    fn drop_to_seal_reads_the_drag_board_core_side() {
        use companion_pasteboard::SystemPasteboard;
        let handle = handle();
        unsafe {
            let sheet = companion_sheet_new(handle);
            assert_ne!(sheet, 0);

            // Nothing dragged → null, no chip.
            let mut drag = SystemPasteboard::drag();
            let receipt = drag.write(
                Zeroizing::new(Vec::new()),
                ContentKind::Text,
                WriteOptions { concealed: false },
            );
            drag.clear_if_unchanged(receipt);
            assert!(companion_sheet_seal_from_drag(handle, sheet).is_null());

            // A drag session's text on the board → sealed core-side.
            let dragged = format!("xoxb-{}", "n0ts3cr3t".repeat(3));
            drag.write(
                Zeroizing::new(dragged.clone().into_bytes()),
                ContentKind::Text,
                WriteOptions { concealed: false },
            );
            let chip = take_json(companion_sheet_seal_from_drag(handle, sheet));
            assert!(!chip.contains(&dragged), "drag bytes leaked into chip JSON");
            assert!(chip.contains("\"kind\":\"text\""));

            // Leave no residue on the shared board.
            let receipt = drag.change_count();
            drag.clear_if_unchanged(receipt);
            companion_free(handle);
        }
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

    /// Two launches against one keychain: save on the first handle,
    /// restore on a second, and the pages — ink, chips, titles — come
    /// back through the same non-secret routes, while the file on disk
    /// and every JSON output stay free of the sealed bytes.
    #[test]
    fn persist_round_trips_over_the_seam() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let path = std::env::temp_dir().join(format!(
            "companion-persist-seam-{}.sealed",
            std::process::id()
        ));
        let c_path = cstring(path.to_str().unwrap());
        let secret = "hunter2-the-sealed-bytes";
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            let sheet = companion_sheet_new(first);
            assert_ne!(sheet, 0);
            let chip_json: serde_json::Value = serde_json::from_str(&take_json(
                companion_sheet_seal_text(first, sheet, cstring(secret).as_ptr()),
            ))
            .unwrap();
            let chip = chip_json["chip_id"].as_u64().unwrap();
            let doc = cstring(&format!(
                r##"[{{"ink": "# deploy notes\n"}}, {{"chip": {chip}}}]"##
            ));
            assert!(companion_sheet_sync_document(first, sheet, doc.as_ptr()));
            assert!(companion_persist_save(first, c_path.as_ptr()));
            companion_free(first);

            let raw = std::fs::read(&path).unwrap();
            assert!(
                !raw.windows(secret.len()).any(|w| w == secret.as_bytes()),
                "sealed bytes visible in the state file"
            );

            let second = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_restore(second, c_path.as_ptr()));
            let sheets = take_json(companion_sheets_json(second));
            assert!(sheets.contains("\"title\":\"deploy notes\""), "{sheets}");
            let document = take_json(companion_sheet_document_json(second, sheet));
            assert!(document.contains("\"ink\""));
            assert!(document.contains(&format!("\"chip_id\":{chip}")));
            assert!(
                !document.contains(secret),
                "sealed bytes leaked into the replayed document"
            );
            // The restored chip still copies out core-side.
            assert!(companion_chip_copy_out(second, chip));
            companion_free(second);

            // A handle over a different keychain cannot open the file.
            let stranger = handle();
            assert!(!companion_persist_restore(stranger, c_path.as_ptr()));
            companion_free(stranger);
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn sealed_bytes_never_appear_in_any_output() {
        // PAT-shaped, assembled at runtime so the raw pattern never
        // appears in the repository text (the secret-scan CI job reads
        // the full history).
        let secret = format!("ghp_{}", "n0ts3cr3t".repeat(4));
        let handle = handle();
        unsafe {
            let sheet = companion_sheet_new(handle);
            assert_ne!(sheet, 0);

            // Route 1: the ⌘↩ ingest entry.
            let chip = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring(&secret).as_ptr(),
            ));
            assert!(
                !chip.contains("n0ts3cr3t"),
                "chip JSON must carry the excerpt, never the bytes: {chip}"
            );
            assert!(chip.contains("excerpt"), "chip JSON: {chip}");

            // Route 2: the sealed paste.
            seed(handle, &secret);
            let chip2 = take_json(companion_sheet_seal_from_pasteboard(
                handle,
                sheet,
                ptr::null_mut(),
            ));
            assert!(!chip2.contains("n0ts3cr3t"), "{chip2}");

            // Summaries carry counts and titles, never chip contents.
            let sheets = take_json(companion_sheets_json(handle));
            assert!(!sheets.contains("n0ts3cr3t"), "{sheets}");
            assert!(sheets.contains("\"chip_count\":2"), "{sheets}");

            // And after death, the ledger holds tombstones — excerpts,
            // struck through shell-side, never bytes.
            assert!(companion_sheet_close(handle, sheet));
            let ledger = take_json(companion_ledger_json(handle));
            assert!(!ledger.contains("n0ts3cr3t"), "{ledger}");
            assert!(ledger.contains("tombstone"), "{ledger}");

            companion_free(handle);
        }
    }

    #[test]
    fn there_is_no_detection_and_no_reveal_surface() {
        // Rev C deleted detection: nothing in the seam's output ever
        // claims to know what the content is. The vocabulary itself is
        // gone from the wire.
        let handle = handle();
        unsafe {
            let sheet = companion_sheet_new(handle);
            let _ = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("postgres://ops:hunter2@db-3.internal:5432/prod").as_ptr(),
            ));
            let sheets = take_json(companion_sheets_json(handle));
            assert!(!sheets.contains("detected_as"), "{sheets}");
            assert!(!sheets.contains("recognition"), "{sheets}");
            companion_free(handle);
        }
    }

    #[test]
    fn sealed_paste_reads_the_board_core_side() {
        let handle = handle();
        seed(handle, "on its way somewhere else");
        unsafe {
            let sheet = companion_sheet_new(handle);
            let chip = take_json(companion_sheet_seal_from_pasteboard(
                handle,
                sheet,
                ptr::null_mut(),
            ));
            assert!(chip.contains("\"kind\":\"text\""), "{chip}");
            assert!(chip.contains("size_label"), "{chip}");
            companion_free(handle);
        }
    }

    #[test]
    fn sealed_paste_drains_the_board_in_the_same_operation() {
        // ADR-0007 Amendment 1: taking the content ends its pasteboard
        // dwell, and the take reports the clear so the shell can
        // surface a board left un-drained.
        let handle = handle();
        seed(handle, "hunter2");
        unsafe {
            let sheet = companion_sheet_new(handle);
            assert!(companion_pasteboard_has_content(handle));

            let mut cleared = false;
            let chip = take_json(companion_sheet_seal_from_pasteboard(
                handle,
                sheet,
                &raw mut cleared,
            ));
            assert!(chip.contains("\"kind\":\"text\""), "{chip}");
            assert!(cleared, "the take must report the drain");

            // The board is empty now: nothing to offer, nothing to
            // seal a second time.
            assert!(!companion_pasteboard_has_content(handle));
            cleared = true;
            let again = companion_sheet_seal_from_pasteboard(handle, sheet, &raw mut cleared);
            assert!(again.is_null(), "an empty board seals nothing");
            assert!(!cleared, "an empty board reports no clear");

            companion_free(handle);
        }
    }

    #[test]
    fn a_refused_seal_leaves_the_board_alone() {
        // Sealing onto an unknown page takes nothing, so it must
        // destroy nothing: the user's content stays where it was.
        let handle = handle();
        seed(handle, "still theirs");
        unsafe {
            let mut cleared = true;
            let refused = companion_sheet_seal_from_pasteboard(handle, 424242, &raw mut cleared);
            assert!(refused.is_null());
            assert!(!cleared);
            assert!(companion_pasteboard_has_content(handle));
            companion_free(handle);
        }
    }

    #[test]
    fn the_offer_probe_skips_our_own_copy_out() {
        let handle = handle();
        unsafe {
            assert!(!companion_pasteboard_has_content(handle), "empty board");

            let sheet = companion_sheet_new(handle);
            let chip = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("hunter2").as_ptr(),
            ));
            let chip: serde_json::Value = serde_json::from_str(&chip).unwrap();
            let chip_id = chip["chip_id"].as_u64().unwrap();

            // Copy-out leaves our transient-marked write on the board;
            // offering to ingest it back would be a loop, not a
            // service.
            assert!(companion_chip_copy_out(handle, chip_id));
            assert!(!companion_pasteboard_has_content(handle));

            // External content, by contrast, is exactly what the offer
            // exists for.
            seed(handle, "from elsewhere");
            assert!(companion_pasteboard_has_content(handle));

            companion_free(handle);
        }
    }

    #[test]
    fn an_image_on_the_board_seals_as_a_metadata_chip_and_copies_back_as_an_image() {
        let handle = handle();
        {
            // A pretend PNG on the board, as a screenshot app would
            // leave it.
            let guard = unsafe { &*handle };
            let mut guard = guard.inner.lock().unwrap();
            let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
            png.resize(2048, 7);
            guard
                .pasteboard
                .put_external(PasteboardContent::Image(png), false);
        }
        unsafe {
            let sheet = companion_sheet_new(handle);
            let chip_json = take_json(companion_sheet_seal_from_pasteboard(
                handle,
                sheet,
                ptr::null_mut(),
            ));
            assert!(chip_json.contains("\"kind\":\"image\""), "{chip_json}");
            assert!(
                chip_json.contains("PNG image"),
                "metadata-only face: {chip_json}"
            );
            let chip: serde_json::Value = serde_json::from_str(&chip_json).unwrap();
            let chip_id = chip["chip_id"].as_u64().unwrap();

            // Copy-out routes the bytes back as an image, still inside
            // the core.
            assert!(companion_chip_copy_out(handle, chip_id));
            {
                let guard = (*handle).inner.lock().unwrap();
                let item = guard.pasteboard.read().expect("board holds our write");
                assert!(
                    matches!(item.content, PasteboardContent::Image(ref b) if b.len() == 2048),
                    "the write carries the image kind"
                );
            }
            companion_free(handle);
        }
    }

    #[test]
    fn copy_out_writes_the_pasteboard_in_core_marked_concealed() {
        let handle = handle();
        unsafe {
            let sheet = companion_sheet_new(handle);
            let chip_json = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("multi-paste me").as_ptr(),
            ));
            let chip: serde_json::Value = serde_json::from_str(&chip_json).unwrap();
            let chip_id = chip["chip_id"].as_u64().unwrap();

            // The core writes the pasteboard itself; the shell never
            // holds the bytes. Chips are sealed by definition, so the
            // write carries both hygiene marks.
            assert!(companion_chip_copy_out(handle, chip_id));
            {
                let guard = (*handle).inner.lock().unwrap();
                assert!(
                    guard.pasteboard.current_is_transient(),
                    "outbound copies carry the transient mark"
                );
                assert!(
                    guard.pasteboard.current_is_concealed(),
                    "chip copies carry the concealed mark"
                );
            }

            // Copy-out does not consume the chip.
            let sheets = take_json(companion_sheets_json(handle));
            assert!(sheets.contains("\"chip_count\":1"), "{sheets}");

            // Guarded clear: succeeds while the board still holds our
            // write, refuses after.
            assert!(companion_clear_clipboard_if_ours(handle));
            assert!(
                !companion_clear_clipboard_if_ours(handle),
                "already cleared"
            );

            companion_free(handle);
        }
    }

    #[test]
    fn sync_document_names_the_page_and_reaps_omitted_chips() {
        let handle = handle();
        unsafe {
            let sheet = companion_sheet_new(handle);
            let chip_json = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("dsn-goes-here").as_ptr(),
            ));
            let chip: serde_json::Value = serde_json::from_str(&chip_json).unwrap();
            let chip_id = chip["chip_id"].as_u64().unwrap();

            let doc = format!("[{{\"ink\": \"### deploy friday\\n\"}}, {{\"chip\": {chip_id}}}]");
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(&doc).as_ptr()
            ));
            let sheets = take_json(companion_sheets_json(handle));
            assert!(
                sheets.contains("\"title\":\"deploy friday\""),
                "markup-stripped title: {sheets}"
            );

            // Malformed snapshots are rejected whole.
            assert!(!companion_sheet_sync_document(
                handle,
                sheet,
                cstring("not json").as_ptr()
            ));
            assert!(!companion_sheet_sync_document(
                handle,
                sheet,
                cstring(r#"[{"chip": 424242}]"#).as_ptr()
            ));

            // A snapshot that omits the chip zeroizes it.
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(r#"[{"ink": "just ink"}]"#).as_ptr()
            ));
            assert!(!companion_chip_copy_out(handle, chip_id), "no resurrection");

            companion_free(handle);
        }
    }

    /// Every promotion path that can refuse **without** a socket, plus
    /// the connection-config contract: TLS-only, and the token goes to
    /// the credential store and never comes back out in any JSON.
    #[test]
    fn connection_config_and_offline_promotion_refusals() {
        let handle = handle();
        unsafe {
            // Promotion refuses before any network when unconfigured.
            let sheet = companion_sheet_new(handle);
            let chip = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("hunter2 hunter2").as_ptr(),
            ));
            let chip_id = serde_json::from_str::<serde_json::Value>(&chip).unwrap()["chip_id"]
                .as_u64()
                .unwrap();
            let refusal = take_json(companion_chip_promote(handle, chip_id, ptr::null()));
            let v: serde_json::Value = serde_json::from_str(&refusal).unwrap();
            assert_eq!(v["ok"], false);
            assert!(v["error"].as_str().unwrap().contains("no connection"));

            // The boundary is TLS-only from the config step.
            assert!(!companion_connection_configure(
                handle,
                cstring(r#"{"server_url": "http://example.com"}"#).as_ptr()
            ));
            assert!(!companion_connection_configure(
                handle,
                cstring("not json").as_ptr()
            ));

            // A good config lands; the token is stored, not echoed.
            assert!(companion_connection_configure(
                handle,
                cstring(
                    r#"{"server_url": "https://eu.onetimesecret.com/",
                        "extid": "org_1", "token": "sekrit-token"}"#
                )
                .as_ptr()
            ));
            let conn = take_json(companion_connection_json(handle));
            assert!(!conn.contains("sekrit-token"), "token never in JSON");
            let v: serde_json::Value = serde_json::from_str(&conn).unwrap();
            assert_eq!(v["configured"], true);
            assert_eq!(v["server_url"], "https://eu.onetimesecret.com");
            assert_eq!(v["extid"], "org_1");
            assert_eq!(v["has_token"], true);

            // Malformed options refuse before any network.
            let refusal = take_json(companion_chip_promote(
                handle,
                chip_id,
                cstring("[]").as_ptr(),
            ));
            let v: serde_json::Value = serde_json::from_str(&refusal).unwrap();
            assert_eq!(v["ok"], false);
            assert!(v["error"].as_str().unwrap().contains("malformed"));

            // A gone chip refuses; an empty page refuses.
            let refusal = take_json(companion_chip_promote(handle, 424_242, ptr::null()));
            assert!(refusal.contains("gone"));
            let empty = companion_sheet_new(handle);
            let refusal = take_json(companion_sheet_promote(handle, empty, ptr::null()));
            assert!(refusal.contains("nothing to promote"));

            // An empty token string deletes the stored one.
            assert!(companion_connection_configure(
                handle,
                cstring(r#"{"server_url": "https://eu.onetimesecret.com", "token": ""}"#).as_ptr()
            ));
            let conn = take_json(companion_connection_json(handle));
            let v: serde_json::Value = serde_json::from_str(&conn).unwrap();
            assert_eq!(v["has_token"], false);

            companion_free(handle);
        }
    }

    #[test]
    fn the_cap_refuses_the_tenth_page() {
        let handle = handle();
        unsafe {
            for _ in 0..9 {
                assert_ne!(companion_sheet_new(handle), 0);
            }
            assert_eq!(companion_sheet_new(handle), 0, "the keyboard wall");
            companion_free(handle);
        }
    }

    #[test]
    fn scheduling_surface_covers_expiry_and_hold_lapses() {
        let handle = handle();
        unsafe {
            assert_eq!(
                companion_next_event_ms(handle),
                -1,
                "empty store: nothing to arm"
            );
            let sheet = companion_sheet_new(handle);
            assert_ne!(sheet, 0);

            // Default rung is 8h; the one armed timer is under that and
            // far above zero.
            let ms = companion_next_event_ms(handle);
            assert!(ms > 7 * 60 * 60 * 1000, "deadline ms: {ms}");
            assert!(ms <= 8 * 60 * 60 * 1000, "deadline ms: {ms}");

            // Pause: the next event becomes the hold lapse (1h), not
            // the expiry.
            assert!(companion_sheet_pause_press(handle, sheet));
            let ms = companion_next_event_ms(handle);
            assert!(ms <= 60 * 60 * 1000, "hold lapse ms: {ms}");
            assert!(ms > 59 * 60 * 1000, "hold lapse ms: {ms}");

            // The summary says so, in a11y words too.
            let sheets = take_json(companion_sheets_json(handle));
            assert!(sheets.contains("\"paused\":true"), "{sheets}");
            assert!(sheets.contains("spoken_remaining"), "{sheets}");

            assert_eq!(companion_expire_due(handle), 0, "nothing due yet");
            companion_free(handle);
        }
    }

    #[test]
    fn rungs_pause_move_and_close_over_the_abi() {
        let handle = handle();
        unsafe {
            let a = companion_sheet_new(handle);
            let b = companion_sheet_new(handle);
            assert!(companion_sheet_set_rung(handle, a, 0)); // 1h
            assert_eq!(companion_sheet_cycle_rung(handle, a), 1); // -> 3h
            assert!(!companion_sheet_set_rung(handle, a, 99), "bad rung code");
            assert!(companion_sheet_move(handle, b, 0));
            assert!(companion_sheet_close(handle, a));
            assert!(!companion_sheet_close(handle, a), "already gone");
            assert_eq!(companion_sheet_cycle_rung(handle, a), -1, "gone");
            companion_free(handle);
        }
    }

    #[test]
    fn ledger_json_reports_cause_title_and_age() {
        let handle = handle();
        unsafe {
            let sheet = companion_sheet_new(handle);
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(r#"[{"ink": "errands\nmilk"}]"#).as_ptr()
            ));
            assert!(companion_sheet_close(handle, sheet));
            let ledger = take_json(companion_ledger_json(handle));
            assert!(ledger.contains("\"cause\":\"closed\""), "{ledger}");
            assert!(ledger.contains("\"title\":\"errands\""), "{ledger}");
            assert!(ledger.contains("age_ms"), "{ledger}");
            assert!(ledger.contains("milk"), "ink survives dimmed: {ledger}");
            companion_free(handle);
        }
    }

    #[test]
    fn null_handles_are_handled_gracefully() {
        unsafe {
            assert_eq!(companion_sheet_new(ptr::null_mut()), 0);
            assert!(companion_sheets_json(ptr::null_mut()).is_null());
            assert!(companion_ledger_json(ptr::null_mut()).is_null());
            assert!(!companion_sheet_close(ptr::null_mut(), 1));
            assert!(!companion_chip_copy_out(ptr::null_mut(), 1));
            assert!(!companion_chip_delete(ptr::null_mut(), 1));
            assert!(!companion_sheet_pause_press(ptr::null_mut(), 1));
            assert_eq!(companion_next_event_ms(ptr::null_mut()), -1);
            assert!(companion_sheet_seal_text(ptr::null_mut(), 1, cstring("x").as_ptr()).is_null());
            assert!(
                companion_sheet_seal_from_pasteboard(ptr::null_mut(), 1, ptr::null_mut()).is_null()
            );
            assert!(!companion_pasteboard_has_content(ptr::null_mut()));
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
