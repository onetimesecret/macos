//! # companion-ffi — the only crate a non-Rust shell may call
//!
//! A thin C ABI over the core, speaking interaction-model rev C:
//! sheets of ink and sealed chips. It hands the shell **handles**
//! (sheet and chip ids as `u64`), **non-secret metadata** (summary
//! JSON with chip excerpts, and ledger JSON that is metadata only), and
//! **action results** (booleans,
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
//! carry excerpts and counts; sealing returns a chip id and its
//! excerpt; copy-out returns a boolean. Ledger records carry no
//! content at all beyond the page-owned title, which the core caps.
//! A test below seals a secret through every route and asserts the raw
//! bytes never appear in any output.
//!
//! ## Codegen
//!
//! Hand-written C ABI plus a committed header
//! (`include/companion_ffi.h`) — the stable substrate the
//! `.xcframework` wraps (`scripts/build-core.sh`). ADR-0003.
#![allow(unsafe_code)] // A C ABI requires raw pointers; every unsafe fn documents its contract.

mod diagnostics;
mod persist;
mod promotion;

use diagnostics::diag_fault;

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
    ChipId, ChipMeta, DestinationClass, EditOp, LedgerEvent, RestoreError, Segment, Sheet, SheetId,
    SheetStore, SizeClass, SystemClock, TTL_LADDER, Tab, TabId, Ttl,
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
    /// Seed content as another app would, so the tests below have
    /// something to seal. The real system clipboard has no unmarked
    /// "external put", so on macOS the seed rides the normal write
    /// (transient-marked); sealed paste reads text regardless of marks,
    /// so the core cannot tell the difference. An `origin` seeds the
    /// `public.url` flavor a browser copy carries; only the in-memory
    /// board can carry one here, and the tests that pass it build
    /// their handles over that board.
    #[cfg(test)]
    fn put_external(
        &mut self,
        content: PasteboardContent,
        concealed: bool,
        origin: Option<String>,
    ) {
        match self {
            Board::Memory(pb) => pb.put_external_with_origin(content, concealed, origin),
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

/// As [`companion_new_scoped`], but the credentials rest in ordinary
/// process memory ([`companion_credentials::InMemoryCredentialStore`])
/// rather than any OS keychain: keys minted through this handle never
/// reach the login Keychain and die with the process. Handles created
/// with the same `tag` share one store, which is what lets a file
/// sealed through one handle be opened through another in the same
/// process, the way the shell's persistence suite exercises a save and
/// the relaunch that restores it. A test seam, then, and only that:
/// the shipping form factors construct through [`companion_new_scoped`],
/// and a handle built here can reach no key but the ones it minted
/// itself. A null, empty, or non-UTF-8 `tag` falls back to one unnamed
/// scope rather than inventing a fresh scope per call, matching
/// [`companion_new_scoped`]'s fallback shape.
///
/// Compiled only under the `test-util` feature (ADR-0018): the release
/// artifact never exports this symbol, and the packaging path checks.
///
/// # Safety
/// `tag` must be null or a valid NUL-terminated C string.
#[cfg(feature = "test-util")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_new_ephemeral(tag: *const c_char) -> *mut CompanionHandle {
    use std::collections::HashMap;
    use std::sync::{OnceLock, PoisonError};

    static STORES: OnceLock<Mutex<HashMap<String, Arc<dyn CredentialStore>>>> = OnceLock::new();
    let tag = unsafe { cstr(tag) }.unwrap_or("").to_string();
    let credentials =
        {
            let mut stores = STORES
                .get_or_init(|| Mutex::new(HashMap::new()))
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            Arc::clone(stores.entry(tag).or_insert_with(|| {
                Arc::new(companion_credentials::InMemoryCredentialStore::default())
            }))
        };
    new_handle(credentials)
}

/// Age every staged page by `gap_ms` of wall time, the way a relaunch
/// after a night away ages them: the store is snapshotted at one wall
/// reading and restored at a later one, which is the same arithmetic
/// [`companion_persist_restore`] does and the only one that moves a
/// countdown without waiting for it. Returns whether the store read
/// back its own snapshot.
///
/// It exists because the states ADR-0017 is about — a tab standing
/// empty, a slot reused by a second page — are on the far side of a
/// countdown, and a suite that cannot cross that boundary can only
/// assert the code it can reach. Nothing is expired here: the caller
/// follows with [`companion_expire_due`], exactly as the shell's armed
/// timer does, so the path under test is the shipping one.
///
/// **The id counters are re-minted densely**, as they are at every
/// restore, so a caller reads ids back from the summaries afterwards
/// rather than keeping the ones it had.
///
/// Compiled only under the `test-util` feature (ADR-0018): the release
/// artifact never exports this symbol, and the packaging path checks.
///
/// # Safety
/// `handle` must be a valid handle.
#[cfg(feature = "test-util")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_test_age_ms(handle: *mut CompanionHandle, gap_ms: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    // A fixed reading rather than the host's: the gap is what matters,
    // and a store that has never been saved has no stamp of its own to
    // measure from.
    let sealed_wall_ms = 1_700_000_000_000;
    let snapshot = guard.store.snapshot(sealed_wall_ms);
    guard
        .store
        .restore(&snapshot, sealed_wall_ms.saturating_add(gap_ms))
        .is_ok()
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
/// byte it holds; exit is total amnesia for staged content. What the
/// ledger recorded about it survives on disk, by design, and carries no
/// content to wipe. Passing null is a no-op.
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

/// A new tab at the end of the strip, holding a new page on the
/// default rung with its countdown started. Returns the **tab** id, or
/// `0` when the store refused — the cap is 9, the keyboard wall, and at
/// the wall the app declines the tenth and says so (refuse-don't-evict,
/// doc 04). `0` is never a valid id.
///
/// The tab is what comes back because the tab is what the shell
/// selects and addresses afterwards (ADR-0017); the page inside it is
/// named by the summary's `page_id`, and the two ids are separate
/// counters that nothing may convert between.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_tab_new(handle: *mut CompanionHandle) -> u64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return 0;
    };
    match guard.store.new_tab() {
        Ok((tab, _)) => tab.raw(),
        Err(_) => 0,
    }
}

/// Mint a page into a tab that holds none, at **that tab's** rung.
/// Returns the new page's id, or `0` for an unknown tab and for one
/// that already holds a page — a tab holds at most one page, and
/// replacing a live one here would drop a page nobody closed.
///
/// This is the route every deliberate mint into an existing slot takes:
/// the three selection gestures and the Return grant (ADR-0017), and
/// nothing else. Expiry never calls it, which is what keeps a countdown
/// that ran out overnight from silently starting a fresh one on
/// nothing.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_tab_open_page(handle: *mut CompanionHandle, tab: u64) -> u64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return 0;
    };
    match guard.store.open_page(TabId::from_raw(tab)) {
        Some(page) => page.raw(),
        None => 0,
    }
}

/// Close a tab: whatever page it holds rests in the ledger like an
/// expired one, its sealed bytes zeroized, and the slot leaves the
/// strip. Returns whether the tab existed.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_tab_close(handle: *mut CompanionHandle, tab: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.close_tab(TabId::from_raw(tab))
}

/// Discard the page a slot holds and leave the slot standing: sealed
/// bytes zeroized, one `Discarded` record in the ledger, and the tab
/// keeps its name, its rung, its position and its number key. Returns
/// whether a page by that id was standing.
///
/// Page addressed on purpose. The burn offered after a promotion names
/// the content that travelled, not the slot it travelled from, and
/// closing the tab there would spend an arrangement the gesture never
/// asked about: only an explicit close and the cap end a tab
/// (ADR-0017).
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_page_discard(handle: *mut CompanionHandle, page: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.discard_page(SheetId::from_raw(page))
}

/// Move a tab to `index` in the visible order (drag-to-reorder; the
/// ⌘-number map follows). Out-of-range indices clamp to the end.
/// Returns whether the tab existed.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_tab_move(
    handle: *mut CompanionHandle,
    tab: u64,
    index: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let index = usize::try_from(index).unwrap_or(usize::MAX);
    guard.store.move_tab(TabId::from_raw(tab), index)
}

/// Name a tab explicitly (the rename gesture in the tab context menu).
///
/// An empty or all-whitespace `title` clears the name, and the label
/// falls back to the live page's derived title and then to the tab's
/// own creation stamp. Anything else is trimmed, capped at 80
/// characters, and from then on **sticky**: editing the page never
/// overwrites it, and neither does the page dying (ADR-0017).
///
/// The name is the one piece of user-owned text that reaches the
/// ledger, so a user who types a secret into the rename field has put
/// it into the audit record, and under a durable tab it stays on the
/// strip until the tab is closed. That is the documented exception, not
/// an accident; the cap bounds it and the app never derives one.
///
/// Returns whether the tab existed.
///
/// # Safety
/// `handle` must be a valid handle. `title` must be a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_tab_set_title(
    handle: *mut CompanionHandle,
    tab: u64,
    title: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(title) = (unsafe { cstr(title) }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.set_title(TabId::from_raw(tab), title)
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
/// `at_utf16` and `len_utf16` name the selection the gesture replaces,
/// as UTF-16 code units against the page's body (ADR-0013): the core
/// deletes that range, stands the chip's sentinel in its place, and
/// commits, all inside this one locked call, so the seal and the
/// deletion cannot come apart. A caret is a zero-length range. A range
/// the body does not have refuses the whole seal and takes nothing
/// from the board.
///
/// # Safety
/// `handle` must be a valid handle. `cleared_out`, when non-null, must
/// point to writable memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_seal_from_pasteboard(
    handle: *mut CompanionHandle,
    sheet: u64,
    at_utf16: u32,
    len_utf16: u32,
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
    // Provenance rode the same read as the content (ADR-0013): when
    // the board declared a `public.url`, it persists as the seal
    // commit's message, inside the encrypted snapshot and nowhere
    // else. It is content (a URL can carry a token), so it crosses
    // no JSON surface and reaches no ledger record.
    let origin = item.origin_url.as_deref().map(origin_message);
    let sealed = match item.content {
        PasteboardContent::Text(mut text) => {
            // The board handed us an owned copy of what may now be a
            // secret; the core takes its own custody copy, so wipe this
            // transit copy instead of letting it drop unwiped.
            let sealed = guard.store.seal_text_at_with_origin(
                sheet,
                &text,
                at_utf16,
                len_utf16,
                origin.as_deref(),
            );
            text.zeroize();
            sealed
        }
        PasteboardContent::Image(bytes) => guard.store.seal_image_at_with_origin(
            sheet,
            bytes,
            at_utf16,
            len_utf16,
            origin.as_deref(),
        ),
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
/// or null for an unknown page, empty text, or a range the body does
/// not have.
///
/// `at_utf16` and `len_utf16` name the sealed selection (or line) in
/// UTF-16 code units against the page's body (ADR-0013): the core
/// deletes that range, stands the sentinel in its place, and commits,
/// one atomic locked call, so the shell no longer deletes its copy by
/// an edit of its own.
///
/// # Safety
/// `handle` must be a valid handle. `text` must be a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_seal_text(
    handle: *mut CompanionHandle,
    sheet: u64,
    text: *const c_char,
    at_utf16: u32,
    len_utf16: u32,
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
    match guard.store.seal_text_at(sheet, text, at_utf16, len_utf16) {
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
/// empty or unreadable drag content, a range the body does not have,
/// or an off-macOS build (no drag board exists there).
///
/// `at_utf16` and `len_utf16` name the drop point as a UTF-16 range
/// against the page's body (ADR-0013), replaced by the sentinel in the
/// same locked call; a plain drop is a zero-length range at the
/// insertion index.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_seal_from_drag(
    handle: *mut CompanionHandle,
    sheet: u64,
    at_utf16: u32,
    len_utf16: u32,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (handle, sheet, at_utf16, len_utf16);
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
        // A dragged link declares `public.url` the same way a copied
        // one does; the origin persists as the seal commit's message,
        // under the same rules as the sealed paste above.
        let origin = item.origin_url.as_deref().map(origin_message);
        let sealed = match item.content {
            PasteboardContent::Text(mut text) => {
                // Same custody rule as the sealed paste: wipe the owned
                // transit copy once the core has taken its own.
                let sealed = guard.store.seal_text_at_with_origin(
                    sheet,
                    &text,
                    at_utf16,
                    len_utf16,
                    origin.as_deref(),
                );
                text.zeroize();
                sealed
            }
            PasteboardContent::Image(bytes) => guard.store.seal_image_at_with_origin(
                sheet,
                bytes,
                at_utf16,
                len_utf16,
                origin.as_deref(),
            ),
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

/// Apply an ordered batch of edits to a page's body (ADR-0013): the
/// operation path that replaces per-keystroke snapshots. `json` is an
/// ordered array, each element exactly one of
/// `{"ins": {"at": u32, "text": s}}`, `{"del": {"at": u32, "len": u32}}`
/// or `{"chip": {"at": u32, "id": u64}}`, positions and lengths in
/// UTF-16 code units against the body as the batch's earlier ops leave
/// it. Parsing is reject-whole, like the snapshot path's; a batch that
/// parses is then validated whole against the page and applied
/// atomically or not at all (see the store). Chip liveness follows the
/// document: a delete that swallows a sentinel zeroizes its chip.
/// Returns whether the batch applied; on false the shell restates the
/// page through [`companion_sheet_sync_document`], the recovery path.
///
/// # Safety
/// `handle` must be a valid handle. `json` must be a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_apply_ops(
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
    let Some(ops) = parse_ops(json) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.apply_ops(SheetId::from_raw(sheet), &ops)
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
/// A successful copy-out is an **auditable egress**: it leaves one
/// `sent` record with destination `clipboard` in the ledger. The
/// pasteboard is the boundary the app cannot follow the bytes past, so
/// crossing it is the single most useful line in the record.
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
    guard
        .store
        .record_sent(ChipId::from_raw(chip), DestinationClass::Clipboard);
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

/// A JSON array of non-secret tab summaries, in visible (strip) order:
/// one entry per slot, whether or not it holds a page. The caller owns
/// the returned string and must release it with
/// [`companion_string_free`]. Returns null on error.
///
/// The walk is over the slots and not over the live pages, because the
/// strip is the slots (ADR-0017). A tab whose page expired keeps its
/// place, its label and its rung here, with `has_page` false and every
/// clock field meaningless.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_tabs_json(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let now = guard.store.now();
    let offset = guard.store.local_offset_seconds();
    let summaries: Vec<serde_json::Value> = guard
        .store
        .tabs()
        .map(|tab| summary_json(tab, now, offset))
        .collect();
    match serde_json::to_string(&summaries) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// The two emptiness predicates, both of them, in one call: whether no
/// tab holds a page, and whether no tabs remain. Returns false and
/// writes nothing but the fail-closed `false` into both outputs when
/// the handle or the lock will not answer.
///
/// They are the core's and they cross together for a reason
/// (ADR-0017). The first is ADR-0016 section 6's key rotation trigger,
/// which makes it a security decision rather than a rendering
/// convenience: a predicate the shell recomputed from the summary array
/// could drift from the one the rotation fires on. The second is the
/// one condition under which the sealed file is dropped rather than
/// resealed, because a strip of empty tabs still has names, rungs and
/// an order to keep.
///
/// Wiring them backwards fails in both directions: the first fed to the
/// drop destroys the tabs an expiry was supposed to leave standing, and
/// the second fed to the rotation leaves the install on one content key
/// for as long as any tab exists.
///
/// # Safety
/// `handle` must be a valid handle. `holds_no_page_out` and
/// `has_no_tabs_out`, when non-null, must point to writable memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_store_emptiness(
    handle: *mut CompanionHandle,
    holds_no_page_out: *mut bool,
    has_no_tabs_out: *mut bool,
) -> bool {
    // Both answers start at the reading that changes nothing: no
    // rotation, no drop. A caller that ignores the return value still
    // gets the cautious answer rather than a stale one.
    if !holds_no_page_out.is_null() {
        unsafe { *holds_no_page_out = false };
    }
    if !has_no_tabs_out.is_null() {
        unsafe { *has_no_tabs_out = false };
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    if !holds_no_page_out.is_null() {
        unsafe { *holds_no_page_out = guard.store.holds_no_page() };
    }
    if !has_no_tabs_out.is_null() {
        unsafe { *has_no_tabs_out = guard.store.has_no_tabs() };
    }
    true
}

/// The ledger (⌘0): an audit trail of what the app did with items,
/// newest first, read-only, held to a rolling 90-day window on the
/// records' own wall-clock stamps.
///
/// **Metadata only.** A record names an item by its random
/// [`ItemId`](companion_core::ItemId), in the clear: no digest, no
/// salt, nothing to reverse and nothing to correlate against outside
/// this machine (ADR-0012). It carries no ink, no excerpts and no
/// tombstones: those are gone from this surface. The single piece of
/// page-owned text on a record is `title`, which the core derives from
/// the page's first line or the user set explicitly, capped at 80
/// characters. Sizes are coarse buckets, never byte counts.
///
/// Each record is an object:
///
/// - `event`: `created` | `sealed` | `sent` | `expired` | `discarded`
/// - `item`: the item's UUID, lowercase hyphenated, 36 characters
/// - `title`: the host page's title at the moment of the event
/// - `at_ms`: when it happened, Unix epoch milliseconds
/// - `created_at_ms`: when the item's page was created, epoch ms
/// - `size`: `tiny` | `small` | `medium` | `large` | `huge`
/// - `destination`: `none` | `clipboard` | `link`
///
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
    let records: Vec<serde_json::Value> = guard
        .store
        .ledger()
        .map(|record| {
            serde_json::json!({
                "event": match record.event() {
                    LedgerEvent::Created => "created",
                    LedgerEvent::Sealed => "sealed",
                    LedgerEvent::Sent => "sent",
                    LedgerEvent::Expired => "expired",
                    LedgerEvent::Discarded => "discarded",
                },
                "item": record.item().to_string(),
                "title": record.title(),
                "at_ms": record.at_wall_ms(),
                "created_at_ms": record.item_created_wall_ms(),
                "size": match record.size() {
                    SizeClass::Tiny => "tiny",
                    SizeClass::Small => "small",
                    SizeClass::Medium => "medium",
                    SizeClass::Large => "large",
                    SizeClass::Huge => "huge",
                },
                "destination": match record.destination() {
                    DestinationClass::None => "none",
                    DestinationClass::Clipboard => "clipboard",
                    DestinationClass::OneTimeLink => "link",
                },
            })
        })
        .collect();
    match serde_json::to_string(&records) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Throw the whole ledger away: the user-facing "clear the ledger"
/// affordance. The records outlive the pages they describe by design,
/// so a way to end them on demand is part of that bargain. In-memory only: the
/// shell must save afterwards for the empty ledger to reach the file.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_ledger_clear(handle: *mut CompanionHandle) {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return;
    };
    guard.store.clear_ledger();
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

/// A page's provenance, derived from its operation log (ADR-0013):
/// `{"created_ms": u64, "modified_s": i64|null}`. `created_ms` is the
/// page's creation stamp, Unix epoch milliseconds, the same figure the
/// summaries and ledger already carry. `modified_s` is the newest
/// change's commit timestamp in Unix seconds, derived rather than
/// maintained, and null for a page whose body was never touched.
/// Deliberately nothing else: origin URLs are content and appear on no
/// JSON surface. The caller owns the returned string and must release
/// it with [`companion_string_free`]. Returns null for an unknown page.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_meta_json(
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
    let value = serde_json::json!({
        "created_ms": sheet.created_wall_ms(),
        "modified_s": sheet.modified_s(),
    });
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// A page's blocks in document order, each an object
/// `{"id": uuid, "created_s": i64|null, "modified_s": i64|null,
/// "paragraphs": u32}` (ADR-0013). The id is the block's random
/// identity, stable across every edit that stays inside the block and
/// following Notion's split-and-merge convention across the ones that
/// do not. The stamps are Unix seconds derived from the operation log,
/// null for a block with no committed content. `paragraphs` is how many
/// paragraphs the block covers: one usually, more where a paste kept
/// its lines together, which is what lets the shell stand one stamp
/// above a pasted passage instead of one above each of its lines.
/// Identities, timestamps, and that reach ONLY: no text, no sizes, and
/// no origin, which is content and stays inside the sealed snapshot.
/// The caller owns the returned string and must release it with
/// [`companion_string_free`]. Returns null for an unknown page.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_blocks_json(
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
    let blocks: Vec<serde_json::Value> = sheet
        .blocks_meta()
        .into_iter()
        .map(|block| {
            serde_json::json!({
                "id": block.id.to_string(),
                "created_s": block.created_s,
                "modified_s": block.modified_s,
                "paragraphs": block.paragraphs,
            })
        })
        .collect();
    match serde_json::to_string(&blocks) {
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
// Persistence: the sealed state file, bounded by its TTL and by policy
// ---------------------------------------------------------------------------

/// Save the staged content (sheets, sealed chips, clocks) to `path`,
/// encrypted with ChaCha20-Poly1305 under `HKDF(keychain_half,
/// file_half)`. The keychain half rests in the data protection keychain
/// (lock gated, this device only, ADR-0012); the file half is a 0600
/// file in the same directory as `path`, which is how the state
/// directory the shell chose reaches the key derivation. Neither half
/// alone unwraps anything, and no key byte crosses this seam.
///
/// The envelope stamps itself with the wall clock at the save, inside
/// the authenticated header, so a file cannot be re-dated to buy the
/// pages in it more life. That stamp measures one thing only: the gap
/// until the next restore, which is the interval no process of this app
/// was running to observe (ADR-0016 section 4). The ledger is **not** in
/// this file; it has its own, under its own long-lived key
/// ([`companion_ledger_save`]), because the two have different
/// lifetimes and different keys.
///
/// Only ciphertext touches disk; the plaintext snapshot is wiped before
/// this returns. The write is atomic (temp file + rename) and
/// owner-only. The shell calls this on every mutation, debounced, and
/// again at quit to flush what is still pending (ADR-0012); the core
/// still saves nothing on its own.
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
    seal_state_to(&guard, Path::new(path))
}

/// Seal the store as it stands and write it to `path`, minting the
/// content key halves if this is the first save under them. The body of
/// [`companion_persist_save`], factored out because the rotate-and-
/// reseal route ([`companion_persist_rotate_and_save`]) has to do the
/// identical write after it has taken the old halves away, and two
/// copies of a seal is two chances for one of them to drift.
///
/// The caller holds the lock, which is what keeps the halves the write
/// mints from racing a second writer at the same path.
fn seal_state_to(state: &Companion, path: &Path) -> bool {
    let Some(wall_ms) = wall_now_ms() else {
        return false;
    };
    let Some(key) = persist::ensure_state_key(state.credentials.as_ref(), path) else {
        return false;
    };
    let snapshot = state.store.snapshot(wall_ms);
    // The same wall stamp the snapshot carries inside itself, repeated
    // in the header where the AEAD authenticates it.
    let Some(sealed) = persist::seal_state(&key, &snapshot, wall_ms) else {
        return false;
    };
    persist::write_private(path, &sealed)
}

/// Rotate both content key halves and reseal the store under the new
/// ones: the write for the moment no tab holds a page (ADR-0016
/// section 6's first rotation trigger, ADR-0017). Returns whether the
/// file at `path` now holds the store under halves nothing else has
/// ever sealed with.
///
/// **The rotation is the forgetting and the reseal is what keeps the
/// strip.** Erasing the file half makes every ciphertext generation
/// this key ever sealed undecryptable at once, including the ones an
/// atomic rename unlinked and nothing sweeps, so the pages that lived
/// in those generations are gone from the disk in the only sense a copy
/// on write filesystem allows. What the reseal then writes carries tab
/// names, rungs and strip order and no page content, because by the
/// time this is called there is none: an empty pad still has an
/// arrangement the user built, and dropping the file to forget the
/// pages would destroy it. [`companion_persist_erase`] is the other
/// half of this pair and takes the other predicate: no tabs remain at
/// all, so there is nothing left to reseal and the file goes.
///
/// **A rotation that could not erase the half cancels the write**, and
/// this returns false with the old generation still on disk under the
/// old halves. Writing a new generation anyway would seal it under the
/// key that still opens every earlier one, report a forgetting that did
/// not happen, and consume the trigger: the shell's retry
/// (`PageModel.saveState`) is armed by the false, and the state that
/// brings it back here is the same emptiness. The path is asked the
/// same question a drop asks it (`persist::drop_takes_the_content_key`)
/// and a path that is not the content file is refused outright rather
/// than rotated: the ledger rests under its own long-lived key, and
/// rotating on its behalf would destroy staged pages the user still
/// has.
///
/// **The residual, stated rather than engineered around.** The window
/// between the erase and the write is one where the strip exists only
/// in memory: a crash or a refused write inside it costs the tab names,
/// rungs and order, and costs nothing else, because there is no page
/// content left to lose. The reverse order would close that window and
/// open a worse one, since minting a second live key while the first is
/// still on disk is exactly the state the rotation exists to end.
///
/// The in-memory store is untouched: this rewrites a file, not a page.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid NUL-terminated
/// UTF-8 path whose parent directory exists.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_persist_rotate_and_save(
    handle: *mut CompanionHandle,
    path: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(path) = (unsafe { cstr(path) }) else {
        return false;
    };
    // Taken for its exclusion as much as for the credentials: an
    // ordinary save in flight owns the same path and the same halves.
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    let path = Path::new(path);
    if !persist::drop_takes_the_content_key(path) {
        diag_fault!(
            "companion-ffi: a rotation was asked for at a path that is not the content file. \
             Nothing was rotated and nothing was written: the ledger rests under its own \
             long-lived key, and rotating on its behalf would destroy staged pages."
        );
        return false;
    }
    if !persist::rotate_key_halves(guard.credentials.as_ref(), path) {
        diag_fault!(
            "companion-ffi: the content file was left alone because its file half could not be \
             erased. Resealing over it would seal the new generation under the key that still \
             opens every old one, and would consume the retry."
        );
        return false;
    }
    seal_state_to(&guard, path)
}

/// The milliseconds of wall-clock time between the stamp a file was
/// sealed with and now: the gap no process of this app was running to
/// observe, and the only interval this app measures by the calendar
/// (ADR-0016 section 4).
///
/// Everything a running session observes stays on the sleep-inclusive
/// monotonic clock, which is not settable. Two readings of that clock
/// are comparable only inside one boot session, so it cannot measure
/// this gap at all: after a restart the earlier reading is the larger
/// one, and the subtraction that used to live here turned that into
/// `u64::MAX` and drained every countdown the instant the app opened.
///
/// `saturating_sub` is what makes a stamp from the future read as zero
/// rather than as a credit. A clock stepped backwards can therefore
/// freeze a countdown across a restart, for exactly the length of the
/// gap, and never rewind one. That is accepted rather than defended: a
/// user who can set the machine's clock already has the plaintext on
/// screen.
fn wall_away_ms(now_ms: u64, sealed_wall_ms: u64) -> u64 {
    now_ms.saturating_sub(sealed_wall_ms)
}

/// Restore the store from a state file [`companion_persist_save`]
/// wrote: decrypt (both key halves are loaded, never minted here),
/// replace the store's sheets, and drain every countdown by the time
/// that passed while the app was closed. The ledger is untouched here;
/// it loads through [`companion_ledger_restore`], and either call may
/// succeed while the other fails. Pages that came due while away expire
/// into the ledger immediately. Meant for startup, before the first
/// page is created.
///
/// **A file this call cannot open is never destroyed by it.** A missing
/// key, a failed authentication and a snapshot the core rejects all
/// leave the file exactly where it is, which is what stops a restore
/// from replacing prior persisted state with empty state: the file is
/// still there when the shell probes, so the session withholds its own
/// save licence rather than writing over content it could not read
/// (ADR-0016 section 7). There is one exception and it is not a failure
/// to open: a file carrying an envelope this build has **replaced** is
/// disposed of and the licence granted, because nothing in it can ever
/// be read again and an install that refused it forever would present
/// as one that had permanently stopped saving (section 9).
///
/// Launch is also where stranded `*.tmp` generations are swept, since
/// nothing else ever clears the state directory.
///
/// Time away is the wall-clock gap between the file's sealed stamp and
/// now, which is the one interval this app measures by the calendar; see
/// [`wall_away_ms`] for why the monotonic clock cannot measure it and
/// what a stepped clock can and cannot buy.
///
/// Returns whether a state was restored. False covers "no file yet" (a
/// fresh start, not an error) and a superseded file just disposed of, as
/// well as a missing key, failed authentication, an unreadable wall
/// clock, or a damaged snapshot.
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
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    // Launch is the only moment a sweep is safe and the only moment it
    // is owed: a temp generation older than this process is one no
    // rename is ever going to claim. It runs under the handle lock, so
    // this app's own save cannot be mid-write beneath it, and it runs
    // before the read so that a file whose absence ends this call early
    // does not leave the litter behind.
    if let Some(dir) = persist::containing_dir(Path::new(path)) {
        persist::sweep_stranded_temps(dir);
    }
    let Ok(file) = std::fs::read(path) else {
        return false;
    };
    // The key is loaded only for a file whose envelope this build reads,
    // so a file it is about to refuse or dispose of costs no keychain
    // access, which on macOS can mean a prompt (ADR-0004).
    let opened = persist::open_state(&file, || {
        persist::load_state_key(guard.credentials.as_ref(), Path::new(path))
    });
    match opened {
        persist::Opened::Refused => false,
        persist::Opened::Superseded => {
            // The one destructive arm, and it fires only on a byte
            // string this app itself once shipped. Nothing is written to
            // the ledger for what is being dropped: the file was never
            // decrypted, so the identities inside it are unknowable.
            //
            // The halves are deliberately not rotated here, and the
            // reason belongs to the entries in the superseded set rather
            // than to this arm.
            //
            // State the residual exactly, because half of it survives.
            // The keychain half does not change across this break: the
            // account and the HKDF info string are the same strings they
            // were, so an OTSSEAL2 file's keychain half is sitting in
            // the keychain right now, durable, and this arm leaves it
            // there. What is presumed gone is the other half, which
            // lived in the per-boot temp directory macOS clears at boot
            // and this build never reads again. Presumed, not
            // guaranteed: ADR-0012:45 already conceded that those bytes
            // may still be on disk if the directory was not cleared. So
            // the honest residual is that a captured OTSSEAL2 ciphertext
            // stays readable to anyone who also kept that temp half, and
            // dropping the file here does not change that either way.
            //
            // What buys the decision is ADR-0004: a rotation is a
            // keychain write, this runs at launch before the user has
            // asked this app for anything, and a Keychain prompt there
            // is precisely what that ADR exists to prevent.
            //
            // A later entry in the set changes the arithmetic without
            // touching this code. Its file half will sit in the state
            // directory, durable and reachable, beside that same live
            // keychain half, so disposal without rotation would leave a
            // working key rather than half of one.
            // `the_superseded_set_predates_the_key_half_move` in
            // persist.rs is what makes that decision arrive with the
            // entry rather than years later.
            if !persist::erase_state(Path::new(path)) {
                diag_fault!(
                    "companion-ffi: a state file from a superseded format could not be dropped. \
                     It will keep this app from writing state until it is removed."
                );
            }
            false
        }
        persist::Opened::Plaintext {
            plaintext,
            sealed_wall_ms,
        } => {
            // The two clocks, kept apart: the core drains by the
            // difference between the snapshot's own wall stamp and the
            // "now" handed to it, and the only honest measure of the gap
            // this app was not running is the calendar. An unreadable
            // wall clock is a refusal rather than a guess, and it leaves
            // the file untouched like every other refusal here.
            let Some(now_ms) = wall_now_ms() else {
                diag_fault!(
                    "companion-ffi: the state file opened but the wall clock would not answer, \
                     so the time away cannot be measured. The file stays and this session will \
                     not write one."
                );
                return false;
            };
            let away_ms = wall_away_ms(now_ms, sealed_wall_ms);
            if guard
                .store
                .restore(&plaintext, sealed_wall_ms.saturating_add(away_ms))
                .is_err()
            {
                // The file opened and authenticated: this is the
                // snapshot itself the core would not take back, which is
                // a different fault from every other refusal here and
                // the only one that survives a fresh keychain.
                diag_fault!(
                    "companion-ffi: the state file authenticated but the core rejected the \
                     snapshot inside it."
                );
                return false;
            }
            // Deaths-while-away leave ledger residue like any other death.
            guard.store.expire_due();
            true
        }
    }
}

/// Drop the state file at `path`: rotate the content key halves, then
/// overwrite, truncate, sync, unlink. Returns whether nothing is left at
/// the path, including when there was nothing to begin with.
///
/// **The rotation is what forgets; the unlink is the tidy on top of
/// it.** Erasing the file half makes every ciphertext generation this
/// key ever sealed undecryptable, including the ones an atomic rename
/// unlinked and nothing sweeps, and it is the finishing step of a
/// deletion the user already asked for: emptying the pad, or clearing it
/// (ADR-0016 section 6's two triggers, which both arrive here). It runs
/// first, so the generation left behind is already undecryptable by the
/// time its name goes away.
///
/// **A rotation that could not erase the half cancels the drop**, and
/// this returns false with the file still on disk. Dropping it anyway
/// would forget nothing, since the half that opens every generation
/// would still be sitting there, and it would consume its own trigger:
/// this call fires when the pad goes empty, and an empty pad with no
/// file on disk is indistinguishable from an ordinary session with
/// nothing to do. The false is what arms the shell's retry
/// (`PageModel.saveState`), and the file it left behind is what the
/// retry comes back to.
///
/// **Only a content file takes the halves with it.** The same entry
/// point drops the ledger file when the user clears the ledger, and that
/// gesture asked nothing about pages, so the rotation is decided from
/// the path itself (`persist::drop_takes_the_content_key`): the state
/// file's name, or failing that the envelope magic actually at the
/// path, never the caller's intent. The name leads because it is
/// knowable when the file is absent or unreadable, and those are exactly
/// the cases where a magic-only gate skipped the rotation and dropped
/// the ciphertext anyway. ADR-0017 split the emptiness predicate in two
/// and this call takes the "no tabs remain" half; the "no tab holds a
/// page" half rotates through [`companion_persist_rotate_and_save`],
/// which keeps the file it reseals. Wiring them the other way round
/// destroys tabs an expiry was meant to leave standing.
///
/// **Not erasure, and it must not be described as erasure anywhere.**
/// The filesystem is copy on write, so the zeros are as likely to land
/// in fresh blocks as over the old ones. Call this when the store
/// empties, so the last ciphertext generation does not sit on disk for
/// the rest of the session describing nothing.
///
/// The in-memory store is untouched: this deletes a file, not a page.
///
/// `path` is not authenticated and is not trusted. The open refuses a
/// final symlink and refuses to block, and the writes refuse anything
/// that is not a regular file, but those checks are narrower than they
/// sound: a hard link at the path is a regular file and IS zeroed and
/// truncated, and a symlinked parent directory is never examined. The
/// containment is that the path lives in an owner-only, app-owned
/// directory. See `persist::erase_state`, which is the canonical
/// statement of this contract; do not restate it here.
///
/// Returns whether the path is confirmed empty. A stat that will not
/// answer counts as not empty.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid NUL-terminated
/// UTF-8 path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_persist_erase(
    handle: *mut CompanionHandle,
    path: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(path) = (unsafe { cstr(path) }) else {
        return false;
    };
    // Taken for its exclusion as much as for the credentials: a save in
    // flight owns the same path and the same halves.
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    let path = Path::new(path);
    if persist::drop_takes_the_content_key(path)
        && !persist::rotate_key_halves(guard.credentials.as_ref(), path)
    {
        // The file stays. Unlinking it here would leave every prior
        // ciphertext generation on disk still decryptable, hand the
        // shell a success, and destroy the one thing that brings this
        // call back: the drop fires when the pad is empty, and an empty
        // pad with no file on disk looks exactly like an ordinary
        // session with nothing to do. Reporting failure instead is what
        // arms the shell's retry, and every retry until the erase lands
        // finds the file still there.
        diag_fault!(
            "companion-ffi: the content file was left alone because its file half could not be \
             erased. Dropping the ciphertext while the half that opens it is still on disk \
             would forget nothing and would consume the retry."
        );
        return false;
    }
    persist::erase_state(path)
}

/// Save the ledger to `path`, sealed with ChaCha20-Poly1305 under its
/// **own** 32-byte key (`ledger-key` account, minted on first save) and
/// its own envelope magic. That key is deliberately long-lived: it is
/// not the two-half content key, so the audit record survives the
/// emptying that forgets the content it describes, and a state-key
/// rotation must never touch it. The write is atomic (temp file + rename) and
/// owner-only. Call it beside [`companion_persist_save`], behind the
/// same debounce.
///
/// The bytes are metadata plus capped titles, never content, so this
/// file resting on disk indefinitely is the intended outcome rather
/// than a leak. The 90-day retention window is swept off here, under the
/// same lock, immediately before the snapshot is taken: nothing sweeps
/// the ledger on a timer, so without this a session that never appends a
/// record would re-persist titles past the window on every save. Returns
/// success.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid NUL-terminated
/// UTF-8 path whose parent directory exists.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_ledger_save(
    handle: *mut CompanionHandle,
    path: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(path) = (unsafe { cstr(path) }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let Some(key) = persist::ensure_ledger_key(guard.credentials.as_ref()) else {
        return false;
    };
    let Some(wall_ms) = wall_now_ms() else {
        return false;
    };
    // Retention is explicit: no timer sweeps the ledger, so the write
    // path takes the window off before it writes. The sweep and the
    // snapshot share this one lock acquisition, or a record appended
    // between them is persisted against a stale sweep.
    guard.store.evict_ledger(wall_ms);
    let snapshot = guard.store.ledger_snapshot();
    let Some(sealed) = persist::seal_ledger(&key, &snapshot) else {
        return false;
    };
    persist::write_private(Path::new(path), &sealed)
}

/// Restore the ledger from a file [`companion_ledger_save`] wrote:
/// decrypt under `ledger-key` (loaded, never minted), replace the
/// in-memory records, and drop everything outside the rolling 90-day
/// retention window as it loads. Nothing here ages a countdown and
/// nothing expires a page: a ledger record is stamped absolutely and is
/// already dead history.
///
/// Meant for startup, beside [`companion_persist_restore`] and
/// independent of it. Returns whether a ledger was restored. False
/// covers "no file yet" (a fresh start, not an error) as well as a
/// missing key, failed authentication, a damaged snapshot, and a
/// superseded payload just disposed of.
///
/// **The one destructive arm here is the ledger's own superseded
/// payload**, the sibling of [`companion_persist_restore`]'s
/// `Superseded` arm one layer down (ADR-0016 section 9). The envelope
/// and the ledger key did not change at the break, so an `OTSLEDR1`
/// file authenticates and opens like a current one and is refused only
/// inside the core, which names it [`RestoreError::Superseded`] for
/// exactly this caller. Left on disk it would withhold the ledger
/// licence on this launch and every later one, with the user's Clear
/// the only way out. So it is erased with [`persist::erase_state`]'s
/// discipline and this returns false; the shell's probe then finds no
/// file and grants the licence. The ledger key is not rotated: the file
/// was authentic under it, Clear does not rotate it either, and a
/// rotation at launch is the Keychain prompt ADR-0004 forbids. Nothing
/// is written to the ledger about the records dropped: there is no
/// reader for them. Every other refusal leaves the file exactly where
/// it is.
///
/// This arm is narrower than the envelope's, not wider. The payload
/// magic sits inside the ciphertext, so there is no one-bit header flip
/// that turns a refusal into a disposal here: a file reaches this arm
/// only if it authenticates under the real ledger key, and anyone
/// holding that key could have unlinked the file instead.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid NUL-terminated
/// UTF-8 path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_ledger_restore(
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
    let Some(key) = persist::load_ledger_key(guard.credentials.as_ref()) else {
        return false;
    };
    let Some(plaintext) = persist::open_ledger(&key, &file) else {
        return false;
    };
    let Some(wall_ms) = wall_now_ms() else {
        return false;
    };
    match guard.store.restore_ledger(&plaintext, wall_ms) {
        Ok(_) => true,
        Err(RestoreError::Superseded) => {
            diag_fault!(
                "companion-ffi: the ledger file opened but carries a payload version this build                  has replaced. Nothing in it can be read, so it is being dropped and this                  session will start a new trail. The retained history under it is gone."
            );
            if !persist::erase_state(Path::new(path)) {
                diag_fault!(
                    "companion-ffi: a ledger file from a superseded format could not be dropped.                      It will keep this app from recording to the audit trail until it is                      removed."
                );
            }
            false
        }
        Err(_) => false,
    }
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

/// Cycle a tab's countdown label: one rung *shorter* on the ladder,
/// clock *reset* to the full rung value (each click resets the clock to
/// the shown rung — doc 04). The ladder tapers, `7d → 3d → 24h → 8h →
/// 3h → 1h`, and wraps back to `7d` at the bottom. A held page keeps
/// its hold. Returns the new rung code, or `-1` if the tab is gone.
///
/// Tab addressed, and a tab holding no page takes the shorter rung and
/// keeps it for its next page: the rung is the slot's property, not a
/// countdown of the slot's own (ADR-0017).
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_tab_cycle_rung(handle: *mut CompanionHandle, tab: u64) -> c_int {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return -1;
    };
    match guard.store.cycle_rung(TabId::from_raw(tab)) {
        Some(rung) => ttl_to_code(rung),
        None => -1,
    }
}

/// Set a tab to an explicit rung (see the `CompanionRung` codes in the
/// header), resetting its page's clock to it. Returns `true` when the
/// tab existed and the code was valid; a tab holding no page stores the
/// rung and answers true, having no clock to reset.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_tab_set_rung(
    handle: *mut CompanionHandle,
    tab: u64,
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
    guard.store.set_rung(TabId::from_raw(tab), ttl).is_some()
}

/// The pause gesture (double-click a tab), a three state cycle: the
/// first press holds the page's clock for **1 hour**; a press while
/// held tops the hold up to **24 hours from now** — never cumulative;
/// a press while topped up **releases** the hold and the countdown
/// resumes where it froze. A pause holds the clock; it never extends
/// the rung. An unreleased hold lapses on its own — the lapse is
/// folded into [`companion_next_event_ms`]. Returns false for an
/// unknown tab, one holding no page, and one whose page is already due.
///
/// The summary's `hold_topped_up` says which press comes next, so the
/// shell can label the gesture honestly.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_tab_pause_press(handle: *mut CompanionHandle, tab: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.pause_press(TabId::from_raw(tab))
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
        Ok(promoted) => finish_promotion(handle, promoted, Promotable::Chip(chip)),
        Err(message) => promotion_error(&message),
    }
}

/// Promote the whole page: the ↗ page in the footer. The payload is the
/// page in document order — ink verbatim, sealed bytes inlined where
/// their chips sit — refused when the page holds an image chip. Options,
/// blocking behaviour, locking, and the result shape match
/// [`companion_chip_promote`]; no per-chip promotion mark is set (the
/// link stands for the page — "burn local copy" on success is the
/// shell closing the sheet). The egress is recorded: one `sent` record
/// against the page's own identity, destination `link`, with a size
/// class and no content.
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
        Ok(promoted) => finish_promotion(handle, promoted, Promotable::Page(sheet)),
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

/// What a promotion put on the wire: one chip, or a whole page.
#[derive(Clone, Copy)]
enum Promotable {
    /// The ↗ on a chip. The receipt id lands on that chip.
    Chip(ChipId),
    /// The ↗ page in the footer. Nothing is marked, the link stands
    /// for the page, but the egress is still recorded.
    Page(SheetId),
}

/// After a successful conceal: the link onto the clipboard (transient —
/// the link is a capability, not the secret, but no pasteboard manager
/// should archive it), the receipt id onto the chip when a chip was
/// promoted, one `sent` record with destination `link` in the ledger,
/// and the result JSON out.
///
/// The record is written for both shapes of promotion. A page leaving
/// as one link is the largest egress this app performs, so it is the
/// last one that should be missing from the audit trail; the record
/// carries the page's own identity, its title and a size class, and no
/// content, exactly like the chip's.
fn finish_promotion(handle: &CompanionHandle, promoted: Promoted, sent: Promotable) -> *mut c_char {
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let receipt = guard.pasteboard.write(
        Zeroizing::new(promoted.link.into_bytes()),
        ContentKind::Text,
        WriteOptions { concealed: false },
    );
    guard.last_write = Some(receipt);
    match sent {
        // The chip or page may have expired mid-flight; the link is on
        // the clipboard regardless, the record just has nowhere to land.
        Promotable::Chip(chip) => {
            guard
                .store
                .mark_chip_promoted(chip, promoted.receipt_id.clone());
            guard.store.record_sent(chip, DestinationClass::OneTimeLink);
        }
        Promotable::Page(sheet) => {
            guard
                .store
                .record_sheet_sent(sheet, DestinationClass::OneTimeLink);
        }
    }
    into_c_string(serde_json::json!({ "ok": true, "receipt_id": promoted.receipt_id }).to_string())
}

/// A `{"ok": false, "error"}` result. Error strings are messages for
/// the inline failure state and never carry secret material.
fn promotion_error(message: &str) -> *mut c_char {
    into_c_string(serde_json::json!({ "ok": false, "error": message }).to_string())
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

/// One tab's non-secret snapshot: the label and the rung are the
/// slot's, everything about the countdown is the page's, and
/// `has_page` says which half of the object is answering. There is
/// deliberately no field that could carry sealed content. The excerpt
/// lives in the chip JSON returned at seal time and in the replayed
/// document, and that is the only rendering sealed content ever gets.
/// The ledger has none of it.
///
/// Two ids, because neither one can do both jobs (ADR-0017). `id` is
/// the tab's and addresses the slot, since the keyboard gestures have
/// to land on a slot that may hold nothing. `page_id` is the page's and
/// addresses the content, since the shell's storage maps must be keyed
/// to something that dies with the page; it is null when the slot is
/// empty. Page identity here is the in-process `SheetId` and never the
/// item's UUID: the counter does not repeat inside a session, the maps
/// it keys are per session, and a 36 character string has no business
/// on the keystroke path.
///
/// The clock fields are present whatever `has_page` says, because a
/// missing key is harder to read on the far side than a zero, but they
/// mean nothing at all when it is false: an empty tab has no clock, so
/// there is nothing for them to describe and the strip draws the dashed
/// treatment instead of a gauge.
fn summary_json(tab: &Tab, now: std::time::Instant, utc_offset_seconds: i32) -> serde_json::Value {
    let page = tab.page();
    let remaining = page.map_or(std::time::Duration::ZERO, |sheet| sheet.remaining(now));
    serde_json::json!({
        "id": tab.id().raw(),
        "has_page": page.is_some(),
        "page_id": page.map(|sheet| sheet.id().raw()),
        "title": tab.label(utc_offset_seconds),
        "rung_code": ttl_to_code(tab.rung()),
        "rung_label": tab.rung().to_string(),
        "remaining_ms": u64::try_from(remaining.as_millis()).unwrap_or(u64::MAX),
        "remaining_label": page.map(|sheet| sheet.remaining_label(now)).unwrap_or_default(),
        "spoken_remaining": page.map_or_else(
            || "this tab holds no page".to_string(),
            |_| spoken_remaining(remaining),
        ),
        "fraction_remaining": page.map_or(0.0, |sheet| {
            f64::from(sheet.fraction_remaining(tab.rung(), now))
        }),
        "paused": page.is_some_and(|sheet| sheet.is_held(now)),
        "hold_topped_up": page.is_some_and(|sheet| sheet.hold_topped_up(now)),
        "hold_remaining_ms": page.map_or(0, |sheet| {
            u64::try_from(sheet.hold_remaining(now).as_millis()).unwrap_or(u64::MAX)
        }),
        "chip_count": page.map_or(0, Sheet::chip_count),
        "last_hour": page.is_some_and(|sheet| sheet.last_hour(now)),
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

/// The provenance message a URL-bearing seal persists on its commit:
/// `{"origin": url}`, JSON so the compaction ceremony (ADR-0013 stage
/// 6) can read it back mechanically when it materializes summaries.
fn origin_message(url: &str) -> String {
    serde_json::json!({ "origin": url }).to_string()
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

/// Parse the edit-batch JSON for [`companion_sheet_apply_ops`]:
/// `[{"ins": {"at", "text"}}, {"del": {"at", "len"}},
/// {"chip": {"at", "id"}}, …]`. The same reject-whole discipline as
/// [`parse_segments`]: one unknown key, one extra field, one offset
/// that does not fit `u32`, and the whole batch is refused as `None`,
/// because a batch the parser had to guess at is a batch the document
/// must never see.
fn parse_ops(json: &str) -> Option<Vec<EditOp>> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let entries = value.as_array()?;
    let mut ops = Vec::with_capacity(entries.len());
    for entry in entries {
        let object = entry.as_object()?;
        if object.len() != 1 {
            return None;
        }
        if let Some(ins) = object.get("ins") {
            let ins = ins.as_object()?;
            if ins.len() != 2 {
                return None;
            }
            ops.push(EditOp::Insert {
                pos_u16: parse_u32(ins.get("at")?)?,
                text: ins.get("text")?.as_str()?.to_string(),
            });
        } else if let Some(del) = object.get("del") {
            let del = del.as_object()?;
            if del.len() != 2 {
                return None;
            }
            ops.push(EditOp::Delete {
                pos_u16: parse_u32(del.get("at")?)?,
                len_u16: parse_u32(del.get("len")?)?,
            });
        } else if let Some(chip) = object.get("chip") {
            let chip = chip.as_object()?;
            if chip.len() != 2 {
                return None;
            }
            ops.push(EditOp::InsertChip {
                pos_u16: parse_u32(chip.get("at")?)?,
                chip: ChipId::from_raw(chip.get("id")?.as_u64()?),
            });
        } else {
            return None;
        }
    }
    Some(ops)
}

/// A JSON number as `u32`, refused rather than truncated when it does
/// not fit: an offset past `u32::MAX` is not an offset on any page.
fn parse_u32(value: &serde_json::Value) -> Option<u32> {
    u32::try_from(value.as_u64()?).ok()
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
            .put_external(PasteboardContent::Text(text.to_string()), false, None);
    }

    /// Seed the board as a browser copy would: text with a
    /// `public.url` origin flavor beside it.
    fn seed_with_origin(handle: *mut CompanionHandle, text: &str, origin: &str) {
        let guard = unsafe { &*handle };
        let mut guard = guard.inner.lock().unwrap();
        guard.pasteboard.put_external(
            PasteboardContent::Text(text.to_string()),
            false,
            Some(origin.to_string()),
        );
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

    /// A fresh tab and the page it was born holding, as the two ids the
    /// seam now hands out separately. Most tests want the page; the
    /// tab-addressed routes want the tab, and nothing may guess one
    /// from the other.
    unsafe fn new_page(handle: *mut CompanionHandle) -> (u64, u64) {
        let tab = unsafe { companion_tab_new(handle) };
        assert_ne!(tab, 0, "the store refused a tab");
        (
            tab,
            unsafe { page_of(handle, tab) }.expect("born holding one"),
        )
    }

    /// Age every staged page by `gap_ms` of wall time, the way a
    /// relaunch after a night away does: snapshot at one wall reading
    /// and restore at a later one. A `SystemClock` store has no other
    /// way to reach the far side of a countdown, and the restore
    /// re-mints both id counters densely, so a caller reads the ids
    /// back afterwards rather than keeping the ones it had.
    unsafe fn age_by(handle: *mut CompanionHandle, gap_ms: u64) {
        let handle = unsafe { &*handle };
        let mut guard = handle.inner.lock().unwrap();
        let sealed_wall_ms = 1_700_000_000_000;
        let snapshot = guard.store.snapshot(sealed_wall_ms);
        guard
            .store
            .restore(&snapshot, sealed_wall_ms + gap_ms)
            .expect("a store reads back its own snapshot");
    }

    /// The whole strip as summaries, in visible order.
    unsafe fn strip(handle: *mut CompanionHandle) -> Vec<serde_json::Value> {
        serde_json::from_str(&unsafe { take_json(companion_tabs_json(handle)) }).unwrap()
    }

    /// The page a tab holds, read back through the summaries, or `None`
    /// for an empty slot.
    unsafe fn page_of(handle: *mut CompanionHandle, tab: u64) -> Option<u64> {
        let json = unsafe { take_json(companion_tabs_json(handle)) };
        let summaries: serde_json::Value = serde_json::from_str(&json).unwrap();
        summaries
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["id"].as_u64() == Some(tab))
            .and_then(|entry| entry["page_id"].as_u64())
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
            let (_tab, sheet) = new_page(handle);
            assert_ne!(sheet, 0);

            // Nothing dragged → null, no chip.
            let mut drag = SystemPasteboard::drag();
            let receipt = drag.write(
                Zeroizing::new(Vec::new()),
                ContentKind::Text,
                WriteOptions { concealed: false },
            );
            drag.clear_if_unchanged(receipt);
            assert!(companion_sheet_seal_from_drag(handle, sheet, 0, 0).is_null());

            // A drag session's text on the board → sealed core-side.
            let dragged = format!("xoxb-{}", "n0ts3cr3t".repeat(3));
            drag.write(
                Zeroizing::new(dragged.clone().into_bytes()),
                ContentKind::Text,
                WriteOptions { concealed: false },
            );
            let chip = take_json(companion_sheet_seal_from_drag(handle, sheet, 0, 0));
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
        // A directory of its own, because the sealed file is no longer
        // the only thing this call writes: the file half of the content
        // key is minted beside it (ADR-0016 section 3), and key material
        // does not belong loose in the system temp directory.
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        let secret = "hunter2-the-sealed-bytes";
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            let (_tab, sheet) = new_page(first);
            assert_ne!(sheet, 0);
            let chip_json: serde_json::Value = serde_json::from_str(&take_json(
                companion_sheet_seal_text(first, sheet, cstring(secret).as_ptr(), 0, 0),
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
            let sheets = take_json(companion_tabs_json(second));
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
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The ephemeral constructor's whole contract in one place: a tag
    /// names one shared in-memory store, so two handles under the same
    /// tag see each other's keys and a handle under another tag sees
    /// none of them. The shell's persistence suite leans on exactly
    /// this to restore, through a second handle, what a first handle
    /// sealed. Gated with the seam it exercises (ADR-0018): run it
    /// with `cargo test -p companion-ffi --features test-util`.
    #[cfg(feature = "test-util")]
    #[test]
    fn ephemeral_handles_share_credentials_by_tag() {
        let tag = cstring("ephemeral-share-by-tag");
        let other = cstring("ephemeral-share-by-tag-other");
        unsafe {
            let first = companion_new_ephemeral(tag.as_ptr());
            {
                let guard = (*first).inner.lock().unwrap();
                guard.credentials.store("probe", b"half").unwrap();
            }
            let second = companion_new_ephemeral(tag.as_ptr());
            {
                let guard = (*second).inner.lock().unwrap();
                assert_eq!(guard.credentials.load("probe").unwrap().as_slice(), b"half");
            }
            let third = companion_new_ephemeral(other.as_ptr());
            {
                let guard = (*third).inner.lock().unwrap();
                assert!(guard.credentials.load("probe").is_err());
            }
            companion_free(first);
            companion_free(second);
            companion_free(third);
        }
    }

    #[test]
    fn sealed_bytes_never_appear_in_any_output() {
        // PAT-shaped, assembled at runtime so the raw pattern never
        // appears in the repository text (the secret-scan CI job reads
        // the full history).
        let secret = format!("ghp_{}", "n0ts3cr3t".repeat(4));
        let handle = handle();
        unsafe {
            let (tab, sheet) = new_page(handle);
            assert_ne!(sheet, 0);

            // Route 1: the ⌘↩ ingest entry.
            let chip = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring(&secret).as_ptr(),
                0,
                0,
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
                0,
                0,
                ptr::null_mut(),
            ));
            assert!(!chip2.contains("n0ts3cr3t"), "{chip2}");

            // Summaries carry counts and titles, never chip contents.
            let sheets = take_json(companion_tabs_json(handle));
            assert!(!sheets.contains("n0ts3cr3t"), "{sheets}");
            assert!(sheets.contains("\"chip_count\":2"), "{sheets}");

            // And after death, the ledger holds metadata only: no
            // bytes, and no excerpt of them either. The excerpt was the
            // last rendering of sealed content that reached this
            // surface, and it is gone.
            assert!(companion_tab_close(handle, tab));
            let ledger = take_json(companion_ledger_json(handle));
            assert!(!ledger.contains("n0ts3cr3t"), "{ledger}");
            assert!(!ledger.contains("tombstone"), "{ledger}");
            assert!(!ledger.contains("excerpt"), "{ledger}");

            companion_free(handle);
        }
    }

    /// Whether `needle` occurs anywhere in `haystack`.
    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    /// Every contiguous run of `token`, four characters or longer: the
    /// same hard-to-weaken absence assertion the core's ledger tests
    /// use, applied here to whole JSON surfaces.
    fn fragments_of(token: &str) -> Vec<String> {
        let chars: Vec<char> = token.chars().collect();
        let mut out = Vec::new();
        for start in 0..chars.len() {
            for end in (start + 4)..=chars.len() {
                out.push(chars[start..end].iter().collect());
            }
        }
        out
    }

    #[test]
    fn a_url_bearing_paste_persists_its_origin_and_shows_it_nowhere() {
        // Worst-case origin: a reset link with a token in the query.
        let origin = "https://origin.example.test/reset?tk=Vq9Zx-Chutney";
        let handle = handle();
        unsafe {
            let (tab, sheet) = new_page(handle);
            seed_with_origin(handle, "pasted out of a browser", origin);
            let chip = take_json(companion_sheet_seal_from_pasteboard(
                handle,
                sheet,
                0,
                0,
                ptr::null_mut(),
            ));
            assert!(
                !chip.contains("origin") && !chip.contains("example.test"),
                "chip JSON must not carry provenance: {chip}"
            );

            // The origin persisted: the plaintext content snapshot (the
            // buffer the sealed state file encrypts) carries the seal
            // commit's message, URL included.
            {
                let guard = (*handle).inner.lock().unwrap();
                let snapshot = guard.store.snapshot(0);
                assert!(
                    contains(&snapshot, origin.as_bytes()),
                    "the origin message must ride the content snapshot"
                );
                // And the same walk over the ledger snapshot finds
                // nothing: the audit record must not know the URL.
                assert!(!contains(&guard.store.ledger_snapshot(), b"example.test"));
            }

            // No fragment of the URL on any JSON read surface, before
            // or after the page's death.
            let fragments = fragments_of(origin);
            let clean = |surface: &str, name: &str| {
                for fragment in &fragments {
                    assert!(
                        !surface.contains(fragment.as_str()),
                        "{name} leaked {fragment:?} of the origin: {surface}"
                    );
                }
            };
            clean(&take_json(companion_tabs_json(handle)), "summaries");
            clean(&take_json(companion_sheet_meta_json(handle, sheet)), "meta");
            clean(
                &take_json(companion_sheet_blocks_json(handle, sheet)),
                "blocks",
            );
            assert!(companion_tab_close(handle, tab));
            clean(&take_json(companion_ledger_json(handle)), "ledger");

            companion_free(handle);
        }
    }

    #[test]
    fn meta_and_blocks_json_carry_identities_and_stamps_only() {
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            // Typed, so the two lines are two blocks: a single op
            // carrying both would be a paste, and a paste is one block.
            let ops = cstring(
                r#"[{"ins": {"at": 0, "text": "alpha\n"}}, {"ins": {"at": 6, "text": "beta"}}]"#,
            );
            assert!(companion_sheet_apply_ops(handle, sheet, ops.as_ptr()));

            let meta: serde_json::Value =
                serde_json::from_str(&take_json(companion_sheet_meta_json(handle, sheet))).unwrap();
            assert!(meta["created_ms"].as_u64().is_some_and(|ms| ms > 0));
            assert!(meta["modified_s"].as_i64().is_some_and(|s| s > 0));
            assert_eq!(
                meta.as_object().unwrap().len(),
                2,
                "identities and stamps only: {meta}"
            );

            let blocks: serde_json::Value =
                serde_json::from_str(&take_json(companion_sheet_blocks_json(handle, sheet)))
                    .unwrap();
            let blocks = blocks.as_array().unwrap();
            assert_eq!(blocks.len(), 2, "one entry per typed line");
            for block in blocks {
                assert_eq!(block["id"].as_str().unwrap().len(), 36);
                assert!(block["created_s"].as_i64().is_some_and(|s| s > 0));
                assert!(block["modified_s"].as_i64().is_some_and(|s| s > 0));
                assert_eq!(block["paragraphs"].as_u64(), Some(1));
                assert_eq!(
                    block.as_object().unwrap().len(),
                    4,
                    "no text, no sizes, no origin: {block}"
                );
            }

            // A paste arrives as one op and answers as one block, with
            // the reach that tells the shell where it ends.
            let paste = cstring(r#"[{"ins": {"at": 10, "text": "\nfrom\nelsewhere"}}]"#);
            assert!(companion_sheet_apply_ops(handle, sheet, paste.as_ptr()));
            let blocks: serde_json::Value =
                serde_json::from_str(&take_json(companion_sheet_blocks_json(handle, sheet)))
                    .unwrap();
            let blocks = blocks.as_array().unwrap();
            assert_eq!(blocks.len(), 2, "the paste joined the block it landed in");
            assert_eq!(blocks[1]["paragraphs"].as_u64(), Some(3));

            // Unknown pages answer null on both.
            assert!(companion_sheet_meta_json(handle, 424242).is_null());
            assert!(companion_sheet_blocks_json(handle, 424242).is_null());
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
            let (_tab, sheet) = new_page(handle);
            let _ = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("postgres://ops:hunter2@db-3.internal:5432/prod").as_ptr(),
                0,
                0,
            ));
            let sheets = take_json(companion_tabs_json(handle));
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
            let (_tab, sheet) = new_page(handle);
            let chip = take_json(companion_sheet_seal_from_pasteboard(
                handle,
                sheet,
                0,
                0,
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
            let (_tab, sheet) = new_page(handle);
            assert!(companion_pasteboard_has_content(handle));

            let mut cleared = false;
            let chip = take_json(companion_sheet_seal_from_pasteboard(
                handle,
                sheet,
                0,
                0,
                &raw mut cleared,
            ));
            assert!(chip.contains("\"kind\":\"text\""), "{chip}");
            assert!(cleared, "the take must report the drain");

            // The board is empty now: nothing to offer, nothing to
            // seal a second time.
            assert!(!companion_pasteboard_has_content(handle));
            cleared = true;
            let again = companion_sheet_seal_from_pasteboard(handle, sheet, 0, 0, &raw mut cleared);
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
            let refused =
                companion_sheet_seal_from_pasteboard(handle, 424242, 0, 0, &raw mut cleared);
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

            let (_tab, sheet) = new_page(handle);
            let chip = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("hunter2").as_ptr(),
                0,
                0,
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
                .put_external(PasteboardContent::Image(png), false, None);
        }
        unsafe {
            let (_tab, sheet) = new_page(handle);
            let chip_json = take_json(companion_sheet_seal_from_pasteboard(
                handle,
                sheet,
                0,
                0,
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
            let (_tab, sheet) = new_page(handle);
            let chip_json = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("multi-paste me").as_ptr(),
                0,
                0,
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
            let sheets = take_json(companion_tabs_json(handle));
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
            let (_tab, sheet) = new_page(handle);
            let chip_json = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("dsn-goes-here").as_ptr(),
                0,
                0,
            ));
            let chip: serde_json::Value = serde_json::from_str(&chip_json).unwrap();
            let chip_id = chip["chip_id"].as_u64().unwrap();

            let doc = format!("[{{\"ink\": \"### deploy friday\\n\"}}, {{\"chip\": {chip_id}}}]");
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(&doc).as_ptr()
            ));
            let sheets = take_json(companion_tabs_json(handle));
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

    #[test]
    fn apply_ops_moves_edits_over_the_seam() {
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            // Astral ink, then a replace described the way the shell
            // coalesces one: positions are UTF-16 code units, so the
            // rocket spans two.
            let batch = "[{\"ins\": {\"at\": 0, \"text\": \"plan \u{1F680} launch\"}}]";
            assert!(companion_sheet_apply_ops(
                handle,
                sheet,
                cstring(batch).as_ptr()
            ));
            let batch = r#"[{"del": {"at": 5, "len": 2}}, {"ins": {"at": 5, "text": "the"}}]"#;
            assert!(companion_sheet_apply_ops(
                handle,
                sheet,
                cstring(batch).as_ptr()
            ));
            let doc = take_json(companion_sheet_document_json(handle, sheet));
            assert!(doc.contains("plan the launch"), "unexpected body: {doc}");
            companion_free(handle);
        }
    }

    #[test]
    fn apply_ops_rejects_malformed_and_non_atomic_batches_whole() {
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            assert!(companion_sheet_apply_ops(
                handle,
                sheet,
                cstring(r#"[{"ins": {"at": 0, "text": "kept"}}]"#).as_ptr()
            ));
            let before = take_json(companion_sheet_document_json(handle, sheet));

            // Parsing is reject-whole: an unknown op key, a misspelled
            // field, an extra field, a wrong shape, and an offset that
            // does not fit u32 each refuse the batch outright.
            for bad in [
                r#"[{"insert": {"at": 0, "text": "x"}}]"#,
                r#"[{"ins": {"pos": 0, "text": "x"}}]"#,
                r#"[{"ins": {"at": 0, "text": "x", "extra": 1}}]"#,
                r#"[{"ins": {"at": 0, "text": "x"}, "del": {"at": 0, "len": 1}}]"#,
                r#"[{"del": {"at": 4294967296, "len": 1}}]"#,
                r#"[{"chip": {"at": 0, "id": -1}}]"#,
                r#"[{"chip": {"at": 0}}]"#,
                r#"{"ins": {"at": 0, "text": "x"}}"#,
                r#"[[]]"#,
                "not json",
            ] {
                assert!(
                    !companion_sheet_apply_ops(handle, sheet, cstring(bad).as_ptr()),
                    "accepted a malformed batch: {bad}"
                );
            }

            // A batch that parses but misses the page mid-way is
            // rejected whole by the store: the valid first op must not
            // land either.
            let batch = r#"[{"ins": {"at": 0, "text": "x"}}, {"del": {"at": 99, "len": 1}}]"#;
            assert!(!companion_sheet_apply_ops(
                handle,
                sheet,
                cstring(batch).as_ptr()
            ));
            let after = take_json(companion_sheet_document_json(handle, sheet));
            assert_eq!(before, after, "a rejected batch moved the document");
            companion_free(handle);
        }
    }

    #[test]
    fn a_range_seal_replaces_the_selection_in_one_call() {
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            let ink = "[{\"ins\": {\"at\": 0, \"text\": \"a\u{1F600}SECRET b\"}}]";
            assert!(companion_sheet_apply_ops(
                handle,
                sheet,
                cstring(ink).as_ptr()
            ));
            // Seal the selection: the range leaves the body and the
            // sentinel stands at its UTF-16 position, atomically.
            let chip = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("SECRET").as_ptr(),
                3,
                6,
            ));
            assert!(chip.contains("\"kind\":\"text\""));
            let doc = take_json(companion_sheet_document_json(handle, sheet));
            assert!(
                !doc.contains("SECRET"),
                "the sealed selection survived in the body: {doc}"
            );
            assert!(doc.contains("a\u{1F600}"), "the prefix moved: {doc}");
            // A range the body does not have refuses whole: a boundary
            // inside the astral pair seals nothing.
            assert!(
                companion_sheet_seal_text(handle, sheet, cstring("x").as_ptr(), 2, 1).is_null()
            );
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
            let (_tab, sheet) = new_page(handle);
            let chip = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("hunter2 hunter2").as_ptr(),
                0,
                0,
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
            let (_empty_tab, empty) = new_page(handle);
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
                assert_ne!(companion_tab_new(handle), 0);
            }
            assert_eq!(companion_tab_new(handle), 0, "the keyboard wall");
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
            let (tab, sheet) = new_page(handle);
            assert_ne!(sheet, 0);

            // Default rung is 8h; the one armed timer is under that and
            // far above zero.
            let ms = companion_next_event_ms(handle);
            assert!(ms > 7 * 60 * 60 * 1000, "deadline ms: {ms}");
            assert!(ms <= 8 * 60 * 60 * 1000, "deadline ms: {ms}");

            // Pause: the next event becomes the hold lapse (1h), not
            // the expiry.
            assert!(companion_tab_pause_press(handle, tab));
            let ms = companion_next_event_ms(handle);
            assert!(ms <= 60 * 60 * 1000, "hold lapse ms: {ms}");
            assert!(ms > 59 * 60 * 1000, "hold lapse ms: {ms}");

            // The summary says so, in a11y words too.
            let sheets = take_json(companion_tabs_json(handle));
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
            let (a, _) = new_page(handle);
            let (b, _) = new_page(handle);
            assert!(companion_tab_set_rung(handle, a, 5)); // 7d
            assert_eq!(companion_tab_cycle_rung(handle, a), 4); // -> 3d
            assert!(companion_tab_set_rung(handle, a, 0)); // 1h
            assert_eq!(companion_tab_cycle_rung(handle, a), 5); // wraps -> 7d
            assert!(!companion_tab_set_rung(handle, a, 99), "bad rung code");
            assert!(companion_tab_move(handle, b, 0));
            assert!(companion_tab_close(handle, a));
            assert!(!companion_tab_close(handle, a), "already gone");
            assert_eq!(companion_tab_cycle_rung(handle, a), -1, "gone");
            companion_free(handle);
        }
    }

    /// The summary is the tab's, and it carries the two ids separately
    /// because neither can do the other's job (ADR-0017): the slot is
    /// what a keystroke lands on, and the page is what a storage map is
    /// keyed by. An expiry is where the difference shows.
    #[test]
    fn a_tab_summary_carries_both_ids_and_says_whether_a_page_is_there() {
        let handle = handle();
        unsafe {
            let (tab, page) = new_page(handle);
            assert!(companion_tab_set_title(
                handle,
                tab,
                cstring("payroll").as_ptr()
            ));
            assert!(companion_tab_set_rung(handle, tab, 0)); // 1h

            let summaries: Vec<serde_json::Value> =
                serde_json::from_str(&take_json(companion_tabs_json(handle))).unwrap();
            assert_eq!(summaries.len(), 1);
            assert_eq!(summaries[0]["id"].as_u64(), Some(tab));
            assert_eq!(summaries[0]["page_id"].as_u64(), Some(page));
            assert_eq!(summaries[0]["has_page"].as_bool(), Some(true));

            // The expiry takes the page and leaves the slot: the strip
            // keeps its width, the label survives, and the second id
            // goes away because the thing it named did.
            age_by(handle, 2 * 60 * 60 * 1_000);
            assert_eq!(companion_expire_due(handle), 1);
            let summaries = strip(handle);
            assert_eq!(summaries.len(), 1, "the tab stayed on the strip");
            let tab = summaries[0]["id"].as_u64().unwrap();
            assert_eq!(summaries[0]["has_page"].as_bool(), Some(false));
            assert!(summaries[0]["page_id"].is_null(), "{:?}", summaries[0]);
            assert_eq!(summaries[0]["title"].as_str(), Some("payroll"));
            assert_eq!(summaries[0]["rung_code"].as_i64(), Some(0), "the rung too");
            assert_eq!(companion_next_event_ms(handle), -1, "nothing to arm");

            // And the slot takes a new page at the rung it kept.
            let replacement = companion_tab_open_page(handle, tab);
            assert_ne!(replacement, 0);
            assert_ne!(replacement, page, "a reused slot holds a new page");
            assert_eq!(
                companion_tab_open_page(handle, tab),
                0,
                "one page to a slot"
            );
            assert_eq!(companion_tab_open_page(handle, 424_242), 0, "no such tab");
            assert_eq!(companion_tab_open_page(ptr::null_mut(), tab), 0);
            companion_free(handle);
        }
    }

    /// The burn after a promotion, across the seam: it names the page
    /// and leaves the slot, which is the whole difference between it
    /// and a close (ADR-0017).
    #[test]
    fn discarding_a_page_over_the_abi_leaves_the_slot_on_the_strip() {
        let handle = handle();
        unsafe {
            let (tab, page) = new_page(handle);
            assert!(companion_tab_set_title(
                handle,
                tab,
                cstring("payroll").as_ptr()
            ));
            assert!(companion_sheet_sync_document(
                handle,
                page,
                cstring(r#"[{"ink": "the credentials"}]"#).as_ptr()
            ));

            assert!(companion_page_discard(handle, page));

            let summaries = strip(handle);
            assert_eq!(summaries.len(), 1, "the slot is still the user's");
            assert_eq!(summaries[0]["id"].as_u64(), Some(tab));
            assert_eq!(summaries[0]["has_page"].as_bool(), Some(false));
            assert_eq!(summaries[0]["title"].as_str(), Some("payroll"));

            let ledger = take_json(companion_ledger_json(handle));
            assert!(ledger.contains("\"event\":\"discarded\""), "{ledger}");
            assert!(!ledger.contains("credentials"), "page ink: {ledger}");

            // Fail closed on everything that is not a standing page.
            assert!(!companion_page_discard(handle, page), "already gone");
            assert!(!companion_page_discard(handle, 424_242), "no such page");
            assert!(!companion_page_discard(ptr::null_mut(), page));
            companion_free(handle);
        }
    }

    /// Both halves of the emptiness question, across the seam in one
    /// call, and they answer differently in exactly the state the split
    /// exists for: a strip of named slots holding nothing.
    #[test]
    fn the_two_emptiness_predicates_cross_together_and_disagree() {
        let handle = handle();
        unsafe {
            let mut holds_no_page = true;
            let mut has_no_tabs = true;
            assert!(companion_store_emptiness(
                handle,
                &raw mut holds_no_page,
                &raw mut has_no_tabs
            ));
            assert!(holds_no_page, "a store with no tabs holds no page");
            assert!(has_no_tabs);

            let (tab, _) = new_page(handle);
            assert!(companion_tab_set_rung(handle, tab, 0)); // 1h
            assert!(companion_store_emptiness(
                handle,
                &raw mut holds_no_page,
                &raw mut has_no_tabs
            ));
            assert!(!holds_no_page);
            assert!(!has_no_tabs);

            age_by(handle, 2 * 60 * 60 * 1_000);
            assert_eq!(companion_expire_due(handle), 1);
            let tab = strip(handle)[0]["id"].as_u64().unwrap();
            assert!(companion_store_emptiness(
                handle,
                &raw mut holds_no_page,
                &raw mut has_no_tabs
            ));
            assert!(holds_no_page, "the pad holds no content: rotate and reseal");
            assert!(!has_no_tabs, "but there is a named slot left to reseal");

            assert!(companion_tab_close(handle, tab));
            assert!(companion_store_emptiness(
                handle,
                &raw mut holds_no_page,
                &raw mut has_no_tabs
            ));
            assert!(has_no_tabs, "now the file has nothing to hold");

            // Fail closed: a refused call says so and leaves both
            // answers at the reading that changes nothing.
            holds_no_page = true;
            has_no_tabs = true;
            assert!(!companion_store_emptiness(
                ptr::null_mut(),
                &raw mut holds_no_page,
                &raw mut has_no_tabs
            ));
            assert!(!holds_no_page, "no rotation on a refused answer");
            assert!(!has_no_tabs, "and no drop either");
            assert!(!companion_store_emptiness(
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut()
            ));
            companion_free(handle);
        }
    }

    /// The ledger inverted at ADR-0012: it used to carry a dead page's
    /// ink verbatim, and now it carries none of it. What it does carry
    /// is the item's random UUID in the clear, with no digest and no
    /// salt, because an identifier that cannot be reversed is exactly
    /// what an auditor needs to line two records up.
    #[test]
    fn ledger_json_reports_events_uuids_and_never_ink() {
        // The second line never becomes a title, so nothing in the
        // ledger has any excuse to be carrying it.
        let token = "zzsentinelzz-second-line-of-ink";
        let handle = handle();
        unsafe {
            let (tab, sheet) = new_page(handle);
            let doc = format!(r#"[{{"ink": "errands\n{token}"}}]"#);
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(&doc).as_ptr()
            ));
            assert!(companion_tab_close(handle, tab));
            let ledger = take_json(companion_ledger_json(handle));

            assert!(
                !ledger.contains(token),
                "page ink reached the ledger: {ledger}"
            );
            assert!(!ledger.contains("segments"), "{ledger}");
            assert!(!ledger.contains("age_ms"), "{ledger}");
            assert!(ledger.contains("\"event\":\"discarded\""), "{ledger}");
            assert!(ledger.contains("\"event\":\"created\""), "{ledger}");
            // The title is the one documented content exception, and it
            // is the derived first line, capped core-side.
            assert!(ledger.contains("\"title\":\"errands\""), "{ledger}");

            let records: Vec<serde_json::Value> = serde_json::from_str(&ledger).unwrap();
            assert_eq!(records.len(), 2, "one birth, one death: {ledger}");
            for record in &records {
                let item = record["item"].as_str().unwrap();
                assert_eq!(item.len(), 36, "not a hyphenated UUID: {item}");
                assert_eq!(
                    item.split('-').map(str::len).collect::<Vec<_>>(),
                    vec![8, 4, 4, 4, 12],
                    "not a hyphenated UUID: {item}"
                );
                assert!(
                    item.chars().all(|c| c == '-' || c.is_ascii_hexdigit()),
                    "not a hyphenated UUID: {item}"
                );
                assert!(record["at_ms"].as_u64().unwrap() > 0, "{record}");
                assert_eq!(record["destination"], "none");
                assert!(record["size"].is_string());
            }
            // Both records name the same page.
            assert_eq!(records[0]["item"], records[1]["item"]);

            companion_ledger_clear(handle);
            assert_eq!(take_json(companion_ledger_json(handle)), "[]");
            companion_free(handle);
        }
    }

    /// The rename gesture: an explicit title outlives every later edit,
    /// and an empty one hands the page back to derivation.
    #[test]
    fn set_title_sticks_until_cleared() {
        let handle = handle();
        unsafe {
            let (tab, sheet) = new_page(handle);
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(r#"[{"ink": "first line"}]"#).as_ptr()
            ));
            let sheets = take_json(companion_tabs_json(handle));
            assert!(sheets.contains("\"title\":\"first line\""), "{sheets}");

            assert!(companion_tab_set_title(
                handle,
                tab,
                cstring("  Payroll Q3  ").as_ptr()
            ));
            let sheets = take_json(companion_tabs_json(handle));
            assert!(
                sheets.contains("\"title\":\"Payroll Q3\""),
                "trimmed: {sheets}"
            );

            // Editing the page no longer renames it.
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(r#"[{"ink": "a different first line"}]"#).as_ptr()
            ));
            let sheets = take_json(companion_tabs_json(handle));
            assert!(sheets.contains("\"title\":\"Payroll Q3\""), "{sheets}");

            // The empty submission clears the override and re-derives.
            assert!(companion_tab_set_title(
                handle,
                tab,
                cstring("   ").as_ptr()
            ));
            let sheets = take_json(companion_tabs_json(handle));
            assert!(
                sheets.contains("\"title\":\"a different first line\""),
                "{sheets}"
            );

            assert!(!companion_tab_set_title(
                handle,
                424_242,
                cstring("nobody").as_ptr()
            ));
            assert!(!companion_tab_set_title(handle, tab, ptr::null()));
            assert!(!companion_tab_set_title(
                ptr::null_mut(),
                tab,
                cstring("x").as_ptr()
            ));
            companion_free(handle);
        }
    }

    /// Both egress routes are auditable, and they are distinguishable:
    /// the pasteboard is a boundary the app cannot follow the bytes
    /// past, and a one-time link is a capability handed to someone else.
    #[test]
    fn a_copy_out_and_a_promotion_each_leave_one_sent_record() {
        let secret = format!("ghp_{}", "n0ts3cr3t".repeat(4));
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            let chip_json = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring(&secret).as_ptr(),
                0,
                0,
            ));
            let chip: serde_json::Value = serde_json::from_str(&chip_json).unwrap();
            let chip_id = chip["chip_id"].as_u64().unwrap();

            assert!(companion_chip_copy_out(handle, chip_id));

            // The promotion's network half is exercised elsewhere; what
            // this test owns is the record the successful finish leaves.
            let result = take_json(finish_promotion(
                &*handle,
                Promoted {
                    link: "https://example.invalid/secret/abc".to_string(),
                    receipt_id: "rcpt-1".to_string(),
                },
                Promotable::Chip(ChipId::from_raw(chip_id)),
            ));
            assert!(result.contains("\"ok\":true"), "{result}");

            let ledger = take_json(companion_ledger_json(handle));
            assert!(!ledger.contains("n0ts3cr3t"), "{ledger}");
            let records: Vec<serde_json::Value> = serde_json::from_str(&ledger).unwrap();
            let sent: Vec<&serde_json::Value> =
                records.iter().filter(|r| r["event"] == "sent").collect();
            assert_eq!(sent.len(), 2, "one per egress: {ledger}");
            // Newest first.
            assert_eq!(sent[0]["destination"], "link");
            assert_eq!(sent[1]["destination"], "clipboard");
            assert_eq!(sent[0]["item"], sent[1]["item"], "the same chip");
            // 40 bytes: a coarse bucket, never a byte count.
            assert_eq!(sent[0]["size"], "tiny");

            // A chip that is gone reports nothing.
            assert!(companion_chip_delete(handle, chip_id));
            assert!(!companion_chip_copy_out(handle, chip_id));
            let ledger = take_json(companion_ledger_json(handle));
            let records: Vec<serde_json::Value> = serde_json::from_str(&ledger).unwrap();
            assert_eq!(
                records.iter().filter(|r| r["event"] == "sent").count(),
                2,
                "a refused copy-out must not record an egress: {ledger}"
            );
            companion_free(handle);
        }
    }

    /// Promoting a whole page is the largest egress this app performs,
    /// and it leaves the same kind of line in the ledger a chip does:
    /// destination `link`, the page's own identity, a size class, and
    /// nothing of what was sent.
    #[test]
    fn promoting_a_whole_page_leaves_one_sent_record() {
        let secret = format!("ghp_{}", "n0ts3cr3t".repeat(4));
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            let chip_json = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring(&secret).as_ptr(),
                0,
                0,
            ));
            let chip: serde_json::Value = serde_json::from_str(&chip_json).unwrap();
            let chip_id = chip["chip_id"].as_u64().unwrap();
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(&format!(
                    r##"[{{"ink": "# rotate on friday\n"}}, {{"chip": {chip_id}}}]"##
                ))
                .as_ptr()
            ));

            // The network half is exercised elsewhere; what this test
            // owns is the record the successful finish leaves.
            let result = take_json(finish_promotion(
                &*handle,
                Promoted {
                    link: "https://example.invalid/secret/abc".to_string(),
                    receipt_id: "rcpt-page".to_string(),
                },
                Promotable::Page(SheetId::from_raw(sheet)),
            ));
            assert!(result.contains("\"ok\":true"), "{result}");

            let ledger = take_json(companion_ledger_json(handle));
            assert!(!ledger.contains("n0ts3cr3t"), "{ledger}");
            let records: Vec<serde_json::Value> = serde_json::from_str(&ledger).unwrap();
            let sent: Vec<&serde_json::Value> =
                records.iter().filter(|r| r["event"] == "sent").collect();
            assert_eq!(sent.len(), 1, "one page promotion, one record: {ledger}");
            assert_eq!(sent[0]["destination"], "link");
            assert_eq!(sent[0]["title"], "rotate on friday");
            assert_eq!(sent[0]["size"], "tiny");
            // The page's identity, not the chip's: the created record
            // for this page carries the same one.
            let created = records
                .iter()
                .find(|r| r["event"] == "created")
                .expect("a page creation is recorded");
            assert_eq!(sent[0]["item"], created["item"]);

            // The page is still live; a send is not a death.
            let sheets = take_json(companion_tabs_json(handle));
            assert!(
                sheets.contains("\"title\":\"rotate on friday\""),
                "{sheets}"
            );
            companion_free(handle);
        }
    }

    /// The first staged page's remaining milliseconds, or `None` when
    /// the first slot holds no page. A slot that lost its page still
    /// stands in the strip and still answers with a summary, so the
    /// question this asks is `has_page` and never the array's length
    /// (ADR-0017).
    unsafe fn first_remaining_ms(handle: *mut CompanionHandle) -> Option<u64> {
        let sheets: Vec<serde_json::Value> =
            serde_json::from_str(&unsafe { take_json(companion_tabs_json(handle)) }).unwrap();
        let first = sheets.first()?;
        if first["has_page"].as_bool() != Some(true) {
            return None;
        }
        first["remaining_ms"].as_u64()
    }

    /// The away computation is pure arithmetic, so it is pinned here
    /// rather than through a seam test whose numbers would depend on
    /// what the host's clock happens to say.
    #[test]
    fn hours_of_wall_time_away_drain_hours_of_life() {
        let two_hours_ms = 2 * 60 * 60 * 1_000;
        assert_eq!(
            wall_away_ms(1_700_000_000_000 + two_hours_ms, 1_700_000_000_000),
            two_hours_ms
        );
    }

    #[test]
    fn no_time_away_drains_nothing() {
        assert_eq!(wall_away_ms(42, 42), 0);
    }

    /// A stamp later than the current wall clock is a clock that moved
    /// backwards, and the answer is zero rather than a wrapped
    /// subtraction: the gap freezes the countdown for its length and
    /// never rewinds it (ADR-0016 section 4).
    #[test]
    fn a_stamp_from_the_future_reads_as_no_time_away() {
        assert_eq!(wall_away_ms(41, 42), 0);
    }

    /// Case 3 of ADR-0016 section 10, and the reason section 5 exists.
    /// A restart takes the monotonic clock back to nearly zero while the
    /// calendar keeps going, and the pages have to come back: the
    /// subtraction that used to measure this ran between two monotonic
    /// readings from different boot sessions, underflowed, charged
    /// `u64::MAX` milliseconds away, and drained every countdown the
    /// instant the surface opened. It presented as a success, since
    /// restore returned true and the ledger filled with expiries.
    ///
    /// Nothing simulates a reboot here because nothing needs to: the
    /// monotonic clock has left the file entirely, so a restart is
    /// indistinguishable from a relaunch and the gap is the wall stamp's
    /// to measure.
    #[test]
    fn a_restart_leaves_the_pages_alive_and_drains_them_by_the_gap() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        let five_minutes_ms = 5 * 60 * 1_000;
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            let (_tab, sheet) = new_page(first);
            let remaining_before = first_remaining_ms(first).unwrap();

            // Sealed five minutes ago, by the only clock that can
            // measure an interval across a restart.
            let sealed_wall_ms = wall_now_ms().unwrap() - five_minutes_ms;
            let snapshot = {
                let guard = (*first).inner.lock().unwrap();
                guard.store.snapshot(sealed_wall_ms)
            };
            let key = persist::ensure_state_key(&*credentials, &path).unwrap();
            let sealed = persist::seal_state(&key, &snapshot, sealed_wall_ms).unwrap();
            assert!(persist::write_private(&path, &sealed));
            companion_free(first);

            let second = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_restore(second, c_path.as_ptr()));
            let remaining_after =
                first_remaining_ms(second).expect("the restart drained the page outright");
            let drained = remaining_before.saturating_sub(remaining_after);
            assert!(
                drained.abs_diff(five_minutes_ms) < 60_000,
                "the gap was not charged as five minutes: {remaining_before} then {remaining_after}"
            );
            let _ = sheet;
            companion_free(second);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A gap longer than what the page had left still ends it, and the
    /// death leaves the ledger residue any other death would.
    #[test]
    fn a_gap_past_the_rung_expires_the_page_into_the_ledger() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            let (tab, sheet) = new_page(first);
            // The shortest rung on the ladder, and a gap of a full day.
            // The page carries ink, because an empty page dies without a
            // ledger record by design (nothing happened worth recording).
            assert!(companion_sheet_sync_document(
                first,
                sheet,
                cstring(r##"[{"ink": "# perishable\n"}]"##).as_ptr()
            ));
            assert!(companion_tab_set_rung(first, tab, 0));
            let sealed_wall_ms = wall_now_ms().unwrap() - 24 * 60 * 60 * 1_000;
            let snapshot = {
                let guard = (*first).inner.lock().unwrap();
                guard.store.snapshot(sealed_wall_ms)
            };
            let key = persist::ensure_state_key(&*credentials, &path).unwrap();
            let sealed = persist::seal_state(&key, &snapshot, sealed_wall_ms).unwrap();
            assert!(persist::write_private(&path, &sealed));
            companion_free(first);

            let second = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_restore(second, c_path.as_ptr()));
            assert_eq!(
                first_remaining_ms(second),
                None,
                "a page a day past its rung came back alive"
            );
            let ledger = take_json(companion_ledger_json(second));
            assert!(ledger.contains("\"expired\""), "{ledger}");
            companion_free(second);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The restore that cannot open a file must never be the thing that
    /// destroys it. This is issue #51's shape rather than its exact
    /// mechanism: "fail closed" had been implemented as "destroy the
    /// input", so an edit anywhere in the old header, or one transient
    /// `sysctl` failure, took the erase-and-rotate arm and the live
    /// session's own staged content went with it. There is no such arm
    /// now: every header edit fails authentication and the file is left
    /// exactly where it is, which is what withholds the save licence
    /// rather than overwriting content nobody could read.
    #[test]
    fn a_file_that_will_not_open_is_left_exactly_where_it_is() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            let (_tab, sheet) = new_page(first);
            let _ = take_json(companion_sheet_seal_text(
                first,
                sheet,
                cstring("hunter2-the-sealed-bytes").as_ptr(),
                0,
                0,
            ));
            assert!(companion_persist_save(first, c_path.as_ptr()));
            companion_free(first);

            let key_before = persist::load_state_key(&*credentials, &path)
                .unwrap()
                .to_vec();
            let sealed = std::fs::read(&path).unwrap();
            // Every header byte but the version digit, which is one bit
            // from a format this app has replaced and is therefore the
            // one edit that disposes rather than refuses. It has a test
            // of its own, and the persist module's header test states
            // why it costs nothing.
            for index in (0..persist::STATE_HEADER_LEN).filter(|index| *index != 7) {
                let mut bent = sealed.clone();
                bent[index] ^= 0x01;
                std::fs::write(&path, &bent).unwrap();
                let handle = handle_with(Arc::clone(&credentials));
                assert!(
                    !companion_persist_restore(handle, c_path.as_ptr()),
                    "a bent header at {index} was restored"
                );
                companion_free(handle);
                assert_eq!(
                    std::fs::read(&path).unwrap(),
                    bent,
                    "the restore destroyed the file it could not open, at {index}"
                );
                assert_eq!(
                    *persist::load_state_key(&*credentials, &path)
                        .expect("the halves were rotated away by a failed restore"),
                    key_before,
                    "a failed restore rotated the key of content it never read"
                );
            }
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The one-time format break, from the user's side: the file the
    /// previous build wrote cannot be read by any key this one can
    /// assemble, so refusing it forever would present as an install that
    /// had permanently stopped saving. It is dropped instead, and the
    /// probe the shell takes afterwards therefore grants the licence
    /// (ADR-0016 section 9).
    #[test]
    fn a_superseded_state_file_is_dropped_so_the_session_can_write() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            let (_tab, sheet) = new_page(first);
            let _ = take_json(companion_sheet_seal_text(
                first,
                sheet,
                cstring("hunter2-the-sealed-bytes").as_ptr(),
                0,
                0,
            ));
            assert!(companion_persist_save(first, c_path.as_ptr()));
            companion_free(first);

            // The same file as the previous format shipped it.
            let mut previous = std::fs::read(&path).unwrap();
            previous[..8].copy_from_slice(b"OTSSEAL2");
            std::fs::write(&path, &previous).unwrap();

            let second = handle_with(Arc::clone(&credentials));
            assert!(
                !companion_persist_restore(second, c_path.as_ptr()),
                "a superseded file cannot be restored, only disposed of"
            );
            assert!(
                !path.exists(),
                "the superseded file is still there, so the probe withholds the licence and \
                 this install never writes again"
            );
            // What the disposal does *not* do, pinned so the comment on
            // that arm cannot drift away from it: the keychain half is
            // untouched by the break and untouched by the disposal, so
            // it is still there afterwards. This is the residual ADR-0016
            // section 8 prices rather than a defect. The other half is
            // what is presumed gone, and the arm's comment says why that
            // is a presumption.
            assert!(
                credentials
                    .key_material_store()
                    .exists("state-key")
                    .unwrap(),
                "the disposal rotated the keychain half; the arm's reasoning and its ADR-0004 \
                 justification both assume it does not"
            );
            // And the session that follows can write and read its own.
            assert!(companion_persist_save(second, c_path.as_ptr()));
            companion_free(second);
            let third = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_restore(third, c_path.as_ptr()));
            companion_free(third);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The ledger's own superseded payload, one layer down from the
    /// envelope: `OTSLEDR1` opens under the unchanged ledger envelope and
    /// key and is refused only inside the core, so without this arm the
    /// file would sit there withholding the ledger licence on every
    /// launch (ADR-0016 section 9). It is disposed of, the key is left
    /// alone, and the session that follows records a fresh trail. A
    /// payload version this app never wrote is refused and left exactly
    /// where it is.
    #[test]
    fn a_superseded_ledger_payload_is_dropped_so_the_session_can_record() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("ledger.sealed");
        let c_path = cstring(path.to_str().unwrap());
        // Re-seal the ledger this session wrote with its payload magic
        // rewritten, under the real key, so the envelope authenticates
        // and the refusal is the core's.
        let resealed_with_payload_magic = |magic: &[u8; 8]| {
            let key = persist::load_ledger_key(credentials.as_ref()).unwrap();
            let file = std::fs::read(&path).unwrap();
            let mut plaintext = persist::open_ledger(&key, &file).unwrap().to_vec();
            plaintext[..8].copy_from_slice(magic);
            std::fs::write(&path, persist::seal_ledger(&key, &plaintext).unwrap()).unwrap();
        };
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            // A birth is a ledger record, so the file has something in it.
            let _ = new_page(first);
            assert!(companion_ledger_save(first, c_path.as_ptr()));
            companion_free(first);

            // A payload version this app never wrote: refused, file kept.
            resealed_with_payload_magic(b"OTSLEDR0");
            let second = handle_with(Arc::clone(&credentials));
            assert!(!companion_ledger_restore(second, c_path.as_ptr()));
            assert!(
                path.exists(),
                "an unknown ledger payload was dropped; only a superseded one may be"
            );
            assert_eq!(take_json(companion_ledger_json(second)), "[]");
            companion_free(second);

            // The version this app did write and has replaced: dropped.
            resealed_with_payload_magic(b"OTSLEDR1");
            let third = handle_with(Arc::clone(&credentials));
            assert!(
                !companion_ledger_restore(third, c_path.as_ptr()),
                "a superseded ledger cannot be restored, only disposed of"
            );
            assert!(
                !path.exists(),
                "the superseded ledger file is still there, so the probe withholds the ledger                  licence and this install never records again"
            );
            assert_eq!(
                take_json(companion_ledger_json(third)),
                "[]",
                "a superseded payload was read"
            );
            assert!(
                credentials
                    .key_material_store()
                    .exists("ledger-key")
                    .unwrap(),
                "the disposal rotated the ledger key; the arm's reasoning assumes it does not"
            );
            // And the session that follows records and reads its own.
            let _ = new_page(third);
            assert!(companion_ledger_save(third, c_path.as_ptr()));
            let written = take_json(companion_ledger_json(third));
            companion_free(third);
            let fourth = handle_with(Arc::clone(&credentials));
            assert!(companion_ledger_restore(fourth, c_path.as_ptr()));
            assert_eq!(take_json(companion_ledger_json(fourth)), written);
            companion_free(fourth);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// An envelope from no version this app ever shipped is refused and
    /// kept, not disposed of. Disposal is a promise about this app's own
    /// past output; anything else at that path is somebody else's file
    /// or a corrupted one, and destroying it is not this app's call.
    #[test]
    fn an_unknown_envelope_is_refused_and_kept() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            new_page(first);
            assert!(companion_persist_save(first, c_path.as_ptr()));
            companion_free(first);

            for magic in [b"OTSSEAL1", b"OTSSEAL9", b"NOTOURS0"] {
                let mut stranger = std::fs::read(&path).unwrap();
                stranger[..8].copy_from_slice(magic);
                std::fs::write(&path, &stranger).unwrap();
                let handle = handle_with(Arc::clone(&credentials));
                assert!(!companion_persist_restore(handle, c_path.as_ptr()));
                companion_free(handle);
                assert!(
                    path.exists(),
                    "a file this app never wrote was destroyed by a restore"
                );
            }
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Launch sweeps the temp generations a death mid-write stranded.
    /// They hold whole sealed generations and whole key halves, and
    /// nothing else in the app ever clears this directory (ADR-0016
    /// section 8).
    #[test]
    fn launch_sweeps_the_temp_generations_a_crash_stranded() {
        let handle = handle();
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        let stranded = dir.join("state.sealed.0f1e2d3c4b5a6978.tmp");
        unsafe {
            new_page(handle);
            assert!(companion_persist_save(handle, c_path.as_ptr()));
            std::fs::write(&stranded, std::fs::read(&path).unwrap()).unwrap();

            assert!(companion_persist_restore(handle, c_path.as_ptr()));
            assert!(
                !stranded.exists(),
                "a stranded ciphertext generation outlived the launch that found it"
            );
            assert!(path.exists(), "the sweep took the state file itself");
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Key material moves to the data protection keychain; the API
    /// token does not. The token's Keychain ACL prompt behaviour is the
    /// login keychain's, and moving it would change what the user is
    /// asked and when, for a secret ADR-0012 never asked to move.
    #[test]
    fn the_token_stays_on_the_handle_store_while_key_material_moves() {
        let credentials = Arc::new(persist::test_stores::SplitKeyStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials) as Arc<dyn CredentialStore>);
            assert!(companion_connection_configure(
                handle,
                cstring(
                    r#"{"server_url":"https://eu.onetimesecret.com","token":"tok_not-key-material"}"#
                )
                .as_ptr()
            ));
            let (_tab, sheet) = new_page(handle);
            let _ = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("hunter2-the-sealed-bytes").as_ptr(),
                0,
                0,
            ));
            assert!(companion_persist_save(handle, c_path.as_ptr()));

            assert!(
                credentials.handed().exists(TOKEN_ACCOUNT).unwrap(),
                "the token left the store the handle was built with"
            );
            assert!(
                !credentials.keys().exists(TOKEN_ACCOUNT).unwrap(),
                "the token followed the key material into the key store"
            );
            assert!(
                credentials.keys().exists("state-key").unwrap(),
                "the content key's keychain half never reached the key store"
            );
            assert!(!credentials.handed().exists("state-key").unwrap());
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A stamp ahead of the system clock is a clock that was stepped
    /// back, and the answer is a freeze rather than a drain or a
    /// credit: the page comes back holding exactly the life it held at
    /// that save, nothing charged and nothing granted. That case is
    /// accepted rather than defended (ADR-0016 section 4), because the
    /// adversary who can set the machine's clock is the machine's own
    /// operator, who already has the plaintext on screen. What must not
    /// happen is the subtraction wrapping, which would have drained
    /// every page on the spot.
    #[test]
    fn a_stamp_from_the_future_freezes_the_countdown_rather_than_draining_it() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            let (tab, sheet) = new_page(first);
            assert!(companion_tab_set_rung(first, tab, 0));
            let remaining_before = first_remaining_ms(first).unwrap();
            // A day ahead of the current wall clock.
            let ahead_ms = wall_now_ms().unwrap() + 24 * 60 * 60 * 1_000;
            let snapshot = {
                let guard = (*first).inner.lock().unwrap();
                guard.store.snapshot(ahead_ms)
            };
            let key = persist::ensure_state_key(&*credentials, &path).unwrap();
            let sealed = persist::seal_state(&key, &snapshot, ahead_ms).unwrap();
            assert!(persist::write_private(&path, &sealed));
            companion_free(first);

            let second = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_restore(second, c_path.as_ptr()));
            let remaining_after = first_remaining_ms(second)
                .expect("a stamp from the future drained the page outright");
            assert!(
                remaining_before.abs_diff(remaining_after) < 60_000,
                "the frozen countdown moved: {remaining_before} then {remaining_after}"
            );
            let _ = sheet;
            companion_free(second);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The ledger's retention window is only a real bound on the write
    /// path if the write path sweeps. Nothing sweeps on a timer, so a
    /// save that snapshots without evicting first re-persists titles
    /// past 90 days under the long-lived key, every save, forever.
    #[test]
    fn the_ledger_save_path_evicts_before_it_snapshots() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let ledger_path = dir.join("ledger.sealed");
        let c_ledger = cstring(ledger_path.to_str().unwrap());

        // A record stamped in November 2023 (the manual clock's fixed
        // base), which is far outside the window by any real "now".
        let stale = {
            let mut aged = SheetStore::new(companion_core::ManualClock::new());
            aged.new_tab().unwrap();
            aged.ledger_snapshot()
        };
        let stale_wall_ms = 1_700_000_000_000;

        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            {
                let mut guard = (*handle).inner.lock().unwrap();
                // Loaded as of the moment it was written, so the load
                // path's own sweep keeps it: the write path is what is
                // on trial here.
                assert_eq!(
                    guard.store.restore_ledger(&stale, stale_wall_ms).unwrap(),
                    1
                );
            }
            assert!(companion_ledger_save(handle, c_ledger.as_ptr()));

            let file = std::fs::read(&ledger_path).unwrap();
            let key = persist::load_ledger_key(&*credentials).unwrap();
            let plaintext = persist::open_ledger(&key, &file).unwrap();
            let mut probe = SheetStore::new(companion_core::ManualClock::new());
            assert_eq!(
                probe.restore_ledger(&plaintext, stale_wall_ms).unwrap(),
                0,
                "a record 90 days past the window was written back to disk"
            );
            assert_eq!(
                take_json(companion_ledger_json(handle)),
                "[]",
                "the sweep must take the record off the live ledger too"
            );
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Erasing is a file operation, not a store operation, and "nothing
    /// there" is a success rather than a failure.
    #[test]
    fn erase_removes_the_state_file_and_tolerates_its_absence() {
        let handle = handle();
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let (_tab, sheet) = new_page(handle);
            assert!(companion_persist_save(handle, c_path.as_ptr()));
            assert!(path.exists());
            assert!(companion_persist_erase(handle, c_path.as_ptr()));
            assert!(!path.exists());
            assert!(companion_persist_erase(handle, c_path.as_ptr()));
            // The page is still staged: this deletes a file, not a page.
            assert_ne!(sheet, 0);
            assert!(first_remaining_ms(handle).unwrap() > 0);
            assert!(!companion_persist_erase(ptr::null_mut(), c_path.as_ptr()));
            assert!(!companion_persist_erase(handle, ptr::null()));
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Dropping the content file is the moment its key dies with it
    /// (ADR-0016 section 6). Without the rotation both halves outlive
    /// every ciphertext generation the atomic rename unlinked, and
    /// nothing sweeps those, so an emptied pad would leave a decryptable
    /// trail behind it.
    #[test]
    fn dropping_the_content_file_rotates_the_halves_with_it() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            new_page(handle);
            assert!(companion_persist_save(handle, c_path.as_ptr()));
            let dropped_key = persist::load_state_key(&*credentials, &path)
                .expect("a saved file has a key")
                .to_vec();

            assert!(companion_persist_erase(handle, c_path.as_ptr()));
            assert!(
                persist::load_state_key(&*credentials, &path).is_none(),
                "the halves outlived the content file they sealed"
            );

            // And what the pad writes next shares nothing with what it
            // just dropped.
            assert!(companion_persist_save(handle, c_path.as_ptr()));
            assert_ne!(
                *persist::load_state_key(&*credentials, &path).unwrap(),
                dropped_key,
                "the pad came back on the very key it had just discarded"
            );
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The other half of ADR-0016 section 6's first trigger: the pad
    /// holds no page, so both halves go and the strip is resealed under
    /// new ones. Without the rotation the tab metadata would be written
    /// under the key that still opens every generation the pages lived
    /// in, and an overnight expiry would forget nothing at all.
    #[test]
    fn resealing_an_emptied_pad_rotates_the_halves_and_keeps_the_strip() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            let (tab, page) = new_page(handle);
            assert!(companion_tab_set_title(
                handle,
                tab,
                cstring("payroll").as_ptr()
            ));
            assert!(companion_tab_set_rung(handle, tab, 0)); // 1h
            assert!(companion_sheet_sync_document(
                handle,
                page,
                cstring(r#"[{"ink": "the credentials"}]"#).as_ptr()
            ));
            assert!(companion_persist_save(handle, c_path.as_ptr()));
            let key_of_the_pages = persist::load_state_key(&*credentials, &path)
                .expect("a saved file has a key")
                .to_vec();
            let generation_holding_the_pages = std::fs::read(&path).unwrap();

            // Overnight: the page dies and the tab stays, which is the
            // state the rotation fires on.
            age_by(handle, 2 * 60 * 60 * 1_000);
            assert_eq!(companion_expire_due(handle), 1);
            let mut holds_no_page = false;
            let mut has_no_tabs = true;
            assert!(companion_store_emptiness(
                handle,
                &raw mut holds_no_page,
                &raw mut has_no_tabs
            ));
            assert!(holds_no_page && !has_no_tabs, "the trigger's own state");

            assert!(companion_persist_rotate_and_save(handle, c_path.as_ptr()));
            assert!(path.exists(), "the strip has a file to live in");
            let key_of_the_strip = persist::load_state_key(&*credentials, &path)
                .expect("the reseal minted fresh halves")
                .to_vec();
            assert_ne!(
                key_of_the_strip, key_of_the_pages,
                "the strip was resealed under the very key the pages died under"
            );
            let generation_holding_the_strip = std::fs::read(&path).unwrap();

            // The generation the pages lived in is undecryptable now,
            // which is the whole of the forgetting: put those bytes back
            // at the path and a fresh session cannot open them.
            std::fs::write(&path, &generation_holding_the_pages).unwrap();
            let ghost = handle_with(Arc::clone(&credentials));
            assert!(
                !companion_persist_restore(ghost, c_path.as_ptr()),
                "a generation sealed before the rotation opened after it"
            );
            companion_free(ghost);

            // And what the reseal did write comes back whole: the slot,
            // its name and its rung, holding nothing.
            std::fs::write(&path, &generation_holding_the_strip).unwrap();
            let morning = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_restore(morning, c_path.as_ptr()));
            let summaries = strip(morning);
            assert_eq!(summaries.len(), 1, "the tab came back");
            assert_eq!(summaries[0]["title"].as_str(), Some("payroll"));
            assert_eq!(summaries[0]["has_page"].as_bool(), Some(false));
            assert_eq!(summaries[0]["rung_code"].as_i64(), Some(0));
            companion_free(morning);
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Fail closed at the seam: a refused handle or path rotates
    /// nothing, and a path that is not the content file is refused
    /// outright rather than rotated. The ledger is the caller that
    /// makes the last one matter: it rests under its own long-lived
    /// key, and rotating on its behalf would destroy staged pages the
    /// user still has.
    #[test]
    fn a_reseal_refuses_every_path_that_is_not_the_content_file() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let state_path = dir.join("state.sealed");
        let ledger_path = dir.join("ledger.sealed");
        let c_state = cstring(state_path.to_str().unwrap());
        let c_ledger = cstring(ledger_path.to_str().unwrap());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            new_page(handle);
            assert!(companion_persist_save(handle, c_state.as_ptr()));
            assert!(companion_ledger_save(handle, c_ledger.as_ptr()));
            let key_before = persist::load_state_key(&*credentials, &state_path)
                .expect("a saved file has a key")
                .to_vec();

            assert!(!companion_persist_rotate_and_save(
                handle,
                c_ledger.as_ptr()
            ));
            assert!(!companion_persist_rotate_and_save(
                ptr::null_mut(),
                c_state.as_ptr()
            ));
            assert!(!companion_persist_rotate_and_save(handle, ptr::null()));

            assert_eq!(
                *persist::load_state_key(&*credentials, &state_path).unwrap(),
                key_before,
                "a refused rotation took the content halves anyway"
            );
            assert!(ledger_path.exists(), "and left the audit trail standing");
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A reseal that could not erase the file half must not write a new
    /// generation. Sealing it under the key that still opens every
    /// earlier one would report a forgetting that did not happen, and
    /// would consume the retry: the trigger is the pad's emptiness, and
    /// the pad stays empty either way.
    #[cfg(unix)]
    #[test]
    fn a_reseal_that_could_not_rotate_leaves_the_old_generation_alone() {
        use std::os::unix::fs::PermissionsExt;
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            new_page(handle);
            assert!(companion_persist_save(handle, c_path.as_ptr()));
            let sealed_before = std::fs::read(&path).unwrap();
            let key_before = persist::load_state_key(&*credentials, &path)
                .expect("a saved file has a key")
                .to_vec();

            // Read and search but no write: the half cannot be unlinked.
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
            let resealed = companion_persist_rotate_and_save(handle, c_path.as_ptr());
            let unchanged = std::fs::read(&path).unwrap() == sealed_before;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();

            // Running as root, or on a filesystem that ignores the mode,
            // the branch under test is unreachable and the reseal simply
            // succeeded.
            if unchanged {
                assert!(!resealed, "a reseal that rotated nothing reported success");
                // The generation on disk is the one that was already
                // there, sealed under halves this call did not replace.
                // Whether the keychain half survived the attempt is the
                // rotation's business and not asserted here; what this
                // pins is that no second generation was written while
                // the first one's file half was still on disk.
                assert_eq!(std::fs::read(&path).unwrap(), sealed_before);

                // The retry the false arms finds the file where it was,
                // and this time the reseal lands on fresh halves.
                assert!(companion_persist_rotate_and_save(handle, c_path.as_ptr()));
                assert_ne!(
                    *persist::load_state_key(&*credentials, &path).expect("fresh halves"),
                    key_before
                );
                assert_ne!(std::fs::read(&path).unwrap(), sealed_before);
            }
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A content file the core cannot read is still a content file, and
    /// dropping it still takes the key. The gate used to read the
    /// envelope magic and nothing else, so a file truncated below eight
    /// bytes, or mode 000, or absent, or with a FIFO planted at the
    /// name, answered "not content" and the drop unlinked it with both
    /// halves alive. Every unlinked generation before it stayed
    /// decryptable, and the shell was told the write had succeeded.
    #[test]
    fn a_content_file_the_core_cannot_read_still_takes_the_key_with_it() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            new_page(handle);
            assert!(companion_persist_save(handle, c_path.as_ptr()));
            assert!(persist::load_state_key(&*credentials, &path).is_some());

            // Truncated below the magic: unreadable as an envelope, and
            // still the file the pad has just emptied.
            std::fs::write(&path, b"OTS").unwrap();

            assert!(companion_persist_erase(handle, c_path.as_ptr()));
            assert!(
                persist::load_state_key(&*credentials, &path).is_none(),
                "the halves outlived the content file because its magic could not be read"
            );
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A drop that could not erase the file half must not drop the
    /// ciphertext. Before this, the refusal was logged and the erase ran
    /// anyway: the content file was gone, both halves were alive, every
    /// unlinked generation stayed decryptable, the shell was told the
    /// write had succeeded, and nothing ever came back, because the drop
    /// fires on an empty pad and an empty pad with no file on disk is an
    /// ordinary session with nothing to do. The trigger consumed itself.
    #[cfg(unix)]
    #[test]
    fn a_drop_that_could_not_erase_the_half_keeps_the_content_file() {
        use std::os::unix::fs::PermissionsExt;
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            new_page(handle);
            assert!(companion_persist_save(handle, c_path.as_ptr()));
            assert!(persist::load_state_key(&*credentials, &path).is_some());
            let sealed_before = std::fs::read(&path).unwrap();

            // Read and search but no write: nothing in the directory can
            // be unlinked, the half included.
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
            let dropped = companion_persist_erase(handle, c_path.as_ptr());
            let still_there = path.exists();
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();

            // Running as root, or on a filesystem that ignores the mode,
            // the branch under test is unreachable and the erase simply
            // succeeded.
            if still_there {
                assert!(
                    !dropped,
                    "the drop reported success while leaving the ciphertext on disk"
                );
                assert_eq!(
                    std::fs::read(&path).unwrap(),
                    sealed_before,
                    "the drop that refused still went and truncated the file it kept"
                );
                // The zeros went into the half even though the unlink
                // could not, which is why this is a refusal and not a
                // success: on a copy-on-write filesystem the overwrite
                // is best effort and the unlink is the only observable
                // fact, so an erase that cannot finish is unknown, and
                // unknown is not gone.
                //
                // The retry the false arms finds the file where it was,
                // and this time the drop lands.
                assert!(companion_persist_erase(handle, c_path.as_ptr()));
                assert!(!path.exists());
                assert!(persist::load_state_key(&*credentials, &path).is_none());
            }
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Clearing the ledger drops a file through this same call, and that
    /// gesture asked nothing about pages. If the drop rotated on the
    /// caller's intent rather than on the envelope actually at the path,
    /// a user clearing their audit log would silently lose every staged
    /// page along with it.
    #[test]
    fn clearing_the_ledger_file_leaves_the_content_halves_alone() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let state_path = dir.join("state.sealed");
        let ledger_path = dir.join("ledger.sealed");
        let c_state = cstring(state_path.to_str().unwrap());
        let c_ledger = cstring(ledger_path.to_str().unwrap());
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            let (_tab, sheet) = new_page(first);
            let _ = take_json(companion_sheet_seal_text(
                first,
                sheet,
                cstring("hunter2-the-sealed-bytes").as_ptr(),
                0,
                0,
            ));
            assert!(companion_persist_save(first, c_state.as_ptr()));
            assert!(companion_ledger_save(first, c_ledger.as_ptr()));
            let key_before = persist::load_state_key(&*credentials, &state_path)
                .expect("a saved file has a key")
                .to_vec();
            companion_free(first);

            let clearing = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_erase(clearing, c_ledger.as_ptr()));
            companion_free(clearing);
            assert_eq!(
                *persist::load_state_key(&*credentials, &state_path).expect(
                    "clearing the ledger destroyed the content key: every staged page is gone"
                ),
                key_before
            );

            // The staged content itself still comes back, which is the
            // property the key comparison above is a proxy for.
            let second = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_restore(second, c_state.as_ptr()));
            assert!(first_remaining_ms(second).unwrap() > 0);
            companion_free(second);

            // And an *unreadable* ledger file is still not the content
            // file. Neither half of the decision may be talked into it:
            // the name is the ledger's and no magic can be read at all.
            std::fs::write(&ledger_path, b"OTS").unwrap();
            let clearing = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_erase(clearing, c_ledger.as_ptr()));
            companion_free(clearing);
            assert_eq!(
                *persist::load_state_key(&*credentials, &state_path)
                    .expect("a damaged ledger file took the content key with it"),
                key_before
            );
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A fresh directory under the system temp dir, removed on success;
    /// a failure leaves it behind for inspection.
    fn scratch_dir() -> std::path::PathBuf {
        let mut tag = [0u8; 8];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut tag).unwrap();
        let dir = std::env::temp_dir().join(format!(
            "companion-ledger-seam-{:016x}",
            u64::from_be_bytes(tag)
        ));
        std::fs::create_dir(&dir).unwrap();
        dir
    }

    /// The ledger is its own file under its own long-lived key, and it
    /// comes back across a relaunch on its own terms: neither file's
    /// restore can stand in for the other's, in either direction.
    #[test]
    fn ledger_save_and_restore_round_trip_through_a_scratch_file() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let ledger_path = dir.join("ledger.sealed");
        let state_path = dir.join("state.sealed");
        let c_ledger = cstring(ledger_path.to_str().unwrap());
        let c_state = cstring(state_path.to_str().unwrap());
        let secret = "hunter2-the-sealed-bytes";
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            let (_tab, sheet) = new_page(first);
            let _ = take_json(companion_sheet_seal_text(
                first,
                sheet,
                cstring(secret).as_ptr(),
                0,
                0,
            ));
            assert!(companion_sheet_sync_document(
                first,
                sheet,
                cstring(r##"[{"ink": "# deploy notes\n"}]"##).as_ptr()
            ));
            assert!(companion_persist_save(first, c_state.as_ptr()));
            assert!(companion_ledger_save(first, c_ledger.as_ptr()));
            let before = take_json(companion_ledger_json(first));
            companion_free(first);

            let raw = std::fs::read(&ledger_path).unwrap();
            assert!(
                !raw.windows(secret.len()).any(|w| w == secret.as_bytes()),
                "sealed bytes visible in the ledger file"
            );

            let second = handle_with(Arc::clone(&credentials));
            assert!(companion_ledger_restore(second, c_ledger.as_ptr()));
            assert_eq!(take_json(companion_ledger_json(second)), before);
            // The two files are sealed under different keys with
            // different associated data; neither opens as the other.
            assert!(!companion_persist_restore(second, c_ledger.as_ptr()));
            assert!(!companion_ledger_restore(second, c_state.as_ptr()));
            companion_free(second);

            // A different keychain opens nothing, and a path with no
            // file is a fresh start rather than an error.
            let stranger = handle();
            assert!(!companion_ledger_restore(stranger, c_ledger.as_ptr()));
            assert!(!companion_ledger_restore(
                stranger,
                cstring(dir.join("absent.sealed").to_str().unwrap()).as_ptr()
            ));
            assert!(!companion_ledger_restore(
                ptr::null_mut(),
                c_ledger.as_ptr()
            ));
            companion_free(stranger);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn null_handles_are_handled_gracefully() {
        unsafe {
            assert_eq!(companion_tab_new(ptr::null_mut()), 0);
            assert!(companion_tabs_json(ptr::null_mut()).is_null());
            assert!(companion_ledger_json(ptr::null_mut()).is_null());
            companion_ledger_clear(ptr::null_mut()); // no-op
            assert!(!companion_ledger_save(
                ptr::null_mut(),
                cstring("/nowhere").as_ptr()
            ));
            assert!(!companion_ledger_restore(
                ptr::null_mut(),
                cstring("/nowhere").as_ptr()
            ));
            assert!(!companion_tab_close(ptr::null_mut(), 1));
            assert!(!companion_chip_copy_out(ptr::null_mut(), 1));
            assert!(!companion_chip_delete(ptr::null_mut(), 1));
            assert!(!companion_tab_pause_press(ptr::null_mut(), 1));
            assert_eq!(companion_next_event_ms(ptr::null_mut()), -1);
            assert!(
                companion_sheet_seal_text(ptr::null_mut(), 1, cstring("x").as_ptr(), 0, 0)
                    .is_null()
            );
            assert!(
                companion_sheet_seal_from_pasteboard(ptr::null_mut(), 1, 0, 0, ptr::null_mut())
                    .is_null()
            );
            assert!(!companion_pasteboard_has_content(ptr::null_mut()));
            assert!(!companion_sheet_apply_ops(
                ptr::null_mut(),
                1,
                cstring("[]").as_ptr()
            ));
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
