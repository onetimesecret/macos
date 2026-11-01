//! The C ABI over the core, the only crate a non-Rust shell may call
//! (ADR-0003). Sealed bytes never cross it outward (docs/spec/05).
//! The shell arms one timer from [`companion_next_event_ms`]; there is no tick.
#![allow(unsafe_code)] // A C ABI needs raw pointers.

mod conceal;
mod content_json;
mod continuous;
mod diagnostics;
mod files;
// Public on purpose, unlike its siblings: the sync session layer that
// will drive it is not built yet (issues #97–#99), and the GOP key
// chain must meanwhile be reachable by the tests and callers that
// prove its contract rather than sitting dead in the crate.
pub mod gop;
// Public for the same reason as `gop`: the session layer that will
// drive the ceremony arrives with issues #98–#99, and until then the
// pairing contract lives here with the tests that prove it.
pub mod pairing;
mod persist;
mod sync_driver;
mod sync_gate;
pub mod sync_session;

use content_json::{chip_face, copied_json, origin_message, summary_json, to_c_json};
use diagnostics::diag_fault;

use std::ffi::CStr;
use std::ffi::{CString, c_char, c_int};
use std::path::Path;
use std::ptr;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use companion_credentials::{CredentialStore, credential_store_for, default_credential_store};
use companion_markdown::{Dialect, Document, Limits, ParseError};
use conceal::{ConcealOpts, Concealed, Connection, Wire, conceal};
use ots_client::Transport as _;

use companion_core::{
    ChipId, ChipMeta, Copied, CopyRefusal, DestinationClass, EditIntent, EditOp, EditSelection,
    EnvelopeCap, FILE_SIZE_LIMIT, FileId, NameRefusal, PayloadError, Placed, RestoreError,
    SealedChip, Segment, SheetId, SheetStore, StepOutcome, SystemClock, TTL_LADDER, TabId,
    TextSelection, Ttl, detect_source_language, judge_name,
};
#[cfg(target_os = "macos")]
use companion_pasteboard::SystemPasteboard;
use companion_pasteboard::{
    ChangeCount, ContentKind, DragItem, MemoryPasteboard, Pasteboard, PasteboardContent,
    PasteboardItem, WriteOptions,
};
use zeroize::{Zeroize, Zeroizing};

/// The system pasteboard on macOS; an in-memory board elsewhere.
enum Board {
    // Only tests construct it on a macOS library build.
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    Memory(MemoryPasteboard),
    #[cfg(target_os = "macos")]
    System(SystemPasteboard),
}

impl Board {
    /// Seed content as another app would. An `origin` needs the memory board.
    #[cfg(test)]
    fn put_external(
        &mut self,
        content: PasteboardContent,
        nspasteboard_concealed: bool,
        origin: Option<Zeroizing<String>>,
    ) {
        match self {
            Board::Memory(pb) => {
                pb.put_external_with_origin(content, nspasteboard_concealed, origin);
            }
            #[cfg(target_os = "macos")]
            Board::System(pb) => {
                let (bytes, kind) = match content {
                    PasteboardContent::Text(s) => (s.into_bytes(), ContentKind::Text),
                    PasteboardContent::Image(b) => (b, ContentKind::Image),
                };
                pb.write(
                    Zeroizing::new(bytes),
                    kind,
                    WriteOptions {
                        nspasteboard_concealed,
                    },
                );
            }
        }
    }

    /// Whether the current item is transient-marked; memory board only.
    #[cfg(test)]
    fn current_is_transient(&self) -> bool {
        match self {
            Board::Memory(pb) => pb.current_is_transient(),
            #[cfg(target_os = "macos")]
            Board::System(_) => false,
        }
    }

    /// Whether the current item carries the `ConcealedType` mark; memory board only.
    #[cfg(test)]
    fn current_is_nspasteboard_concealed(&self) -> bool {
        match self {
            Board::Memory(pb) => pb.read().is_some_and(|item| item.nspasteboard_concealed),
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

/// The core state behind the seam.
struct Companion {
    store: SheetStore<SystemClock>,
    pasteboard: Board,
    last_write: Option<ChangeCount>,
    concealed_link: Option<CachedConcealLink>,
    next_link_copy_token: u64,
    /// Where a conceal goes; `None` until the shell configures one.
    connection: Option<Connection>,
    /// Where the API token rests: the Keychain in the app, memory elsewhere.
    credentials: Arc<dyn CredentialStore>,
    /// The real transport, or a stub installed by a `test-util` seam.
    wire: Wire,
    /// Everything sync holds (issues #98 and #102). Default is
    /// all-off: a handle that never configures sync behaves
    /// bit-for-bit like one built before sync existed.
    sync: sync_driver::SyncState,
    /// Kept apart from `store` so nothing relay-bound can reach files (ADR-0028).
    files: companion_core::FileStore,
    /// Why the last file open refused, until the next open.
    last_open_refusal: Option<companion_core::OpenRefusal>,
    /// Why the last save or save-as refused, until the next save.
    last_save_refusal: Option<companion_core::SaveError>,
    /// Drafts notices, drained by `companion_drafts_notices_json`.
    drafts_notices: Vec<companion_core::FileNotice>,
}

/// The credential-store account holding the API token.
const TOKEN_ACCOUNT: &str = "api-token";

/// Opaque handle the shell holds; a mutex serializes calls.
pub struct CompanionHandle {
    inner: Mutex<Companion>,
}

// ---- Process init and lifecycle ----

/// Harden the process (disable core dumps) before any secret is held.
/// Idempotent; safe to call more than once.
#[unsafe(no_mangle)]
pub extern "C" fn companion_init() {
    companion_core::harden_process();
}

/// FFI crate version string (static; do **not** free).
#[unsafe(no_mangle)]
pub extern "C" fn companion_ffi_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

/// Compatibility alias for callers built against the original ambiguous name.
#[unsafe(no_mangle)]
pub extern "C" fn companion_version() -> *const c_char {
    companion_ffi_version()
}

/// Core crate version string (static; do **not** free).
#[unsafe(no_mangle)]
pub extern "C" fn companion_core_version() -> *const c_char {
    static VERSION: OnceLock<CString> = OnceLock::new();
    VERSION
        .get_or_init(|| CString::new(companion_core::VERSION).expect("crate version contains NUL"))
        .as_ptr()
}

/// Detect a source-language slug without a handle (ADR-0029; experimental,
/// not approved for shipping). Returns an owned C string freed with
/// [`companion_string_free`], or null. `(NULL, 0)` is empty input.
///
/// # Safety
/// When `len <= 4 MiB`, a non-null `bytes` must be readable for `len` bytes
/// until return.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_detect_source_language(
    bytes: *const u8,
    len: usize,
) -> *mut c_char {
    if len > FILE_SIZE_LIMIT {
        return ptr::null_mut();
    }
    let input = if len == 0 {
        &[]
    } else {
        if bytes.is_null() {
            return ptr::null_mut();
        }
        unsafe { std::slice::from_raw_parts(bytes, len) }
    };

    detect_source_language_owned(input, detect_source_language)
}

fn detect_source_language_owned<F>(input: &[u8], detector: F) -> *mut c_char
where
    F: FnOnce(&[u8]) -> Option<&'static str> + std::panic::UnwindSafe,
{
    std::panic::catch_unwind(|| {
        detector(input).map_or(ptr::null_mut(), |slug| into_c_string(slug.to_owned()))
    })
    .unwrap_or(ptr::null_mut())
}

/// The dialect code `companion_markdown_parse_json` reads: 0 `CommonMark`, 1 GFM.
fn markdown_dialect(code: c_int) -> Option<Dialect> {
    match code {
        0 => Some(Dialect::CommonMark),
        1 => Some(Dialect::Gfm),
        _ => None,
    }
}

/// Parse Markdown with UTF-16 object offsets and depth capped at 64; free JSON with [`companion_string_free`].
/// Invalid offset values return `objectOffset` JSON; rejected pointer/alignment arguments return null.
///
/// Non-null `inputLimit` JSON may precede UTF-8 validation; decode every non-null result and check `error`.
///
/// # Safety
/// `text` must be non-null and readable for `len` bytes until return, and a
/// non-null `objects` readable for `objects_len` offsets.
#[unsafe(no_mangle)]
// The preview's three limits cross as plain integers.
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn companion_markdown_parse_json(
    text: *const c_char,
    len: usize,
    objects: *const usize,
    objects_len: usize,
    dialect: c_int,
    maximum_input_scalars: usize,
    maximum_depth: usize,
    maximum_table_cells: u64,
) -> *mut c_char {
    let Some(dialect) = markdown_dialect(dialect) else {
        return ptr::null_mut();
    };
    if text.is_null()
        || len > isize::MAX.unsigned_abs()
        || objects_len > isize::MAX.unsigned_abs() / size_of::<usize>()
        || (objects_len != 0 && (objects.is_null() || !objects.is_aligned()))
    {
        return ptr::null_mut();
    }
    let limits = Limits {
        maximum_input_scalars,
        maximum_depth,
        maximum_table_cells,
    };
    // A scalar is at most four UTF-8 bytes, so a longer text is over the limit unread.
    if maximum_input_scalars
        .checked_mul(4)
        .is_some_and(|most| len > most)
    {
        return markdown_parse_owned(|| Err(ParseError::InputLimit));
    }
    let bytes = unsafe { std::slice::from_raw_parts(text.cast::<u8>(), len) };
    let Ok(text) = std::str::from_utf8(bytes) else {
        return ptr::null_mut();
    };
    let objects = if objects_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(objects, objects_len) }
    };
    markdown_parse_owned(|| companion_markdown::parse_with_objects(text, objects, dialect, limits))
}

fn markdown_parse_owned<F>(parse: F) -> *mut c_char
where
    F: FnOnce() -> Result<Document, ParseError> + std::panic::UnwindSafe,
{
    std::panic::catch_unwind(|| content_json::markdown_json(parse())).unwrap_or(ptr::null_mut())
}

/// Create a handle; the caller frees it with [`companion_free`].
#[unsafe(no_mangle)]
pub extern "C" fn companion_new() -> *mut CompanionHandle {
    new_handle(default_credential_store())
}

/// As [`companion_new`], with credentials scoped to `service` so each form
/// factor owns its Keychain item. Null, empty or non-UTF-8 means the default.
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

/// As [`companion_new_scoped`], but credentials live in process memory,
/// shared by handles with the same `tag`. `test-util` only (ADR-0018).
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

/// Age staged pages by `gap_ms` through a snapshot and restore; returns
/// whether the restore succeeded. Ids are re-minted, so re-read them.
/// `test-util` only (ADR-0018).
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
    // A fixed reading: only the gap matters.
    let sealed_wall_ms = 1_700_000_000_000;
    let snapshot = guard.store.snapshot(sealed_wall_ms);
    guard
        .store
        .restore(&snapshot, sealed_wall_ms.saturating_add(gap_ms))
        .is_ok()
}

/// Replace the transport with a stub answering `status` and `body` (status 0:
/// every send fails). Returns whether it was installed. `test-util` only (ADR-0018).
///
/// # Safety
/// `handle` must be a valid handle. `body` must be null or a valid,
/// NUL-terminated C string.
#[cfg(feature = "test-util")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_test_wire_stub(
    handle: *mut CompanionHandle,
    status: u16,
    body: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let body = unsafe { cstr(body) }.unwrap_or("");
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.wire = Wire::Stub(Arc::new(conceal::StubWire::answering(status, body)));
    true
}

/// The stub's last request as redacted JSON, or null. Free with
/// [`companion_string_free`]. `test-util` only (ADR-0018).
///
/// # Safety
/// `handle` must be a valid handle.
#[cfg(feature = "test-util")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_test_wire_last_json(
    handle: *mut CompanionHandle,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    match &guard.wire {
        Wire::Stub(stub) => stub.last_json().map_or(ptr::null_mut(), into_c_string),
        Wire::Real(_) => ptr::null_mut(),
    }
}

/// Replace the handle's pasteboard with one in process memory, after taking
/// back any write of ours on the old one, so a test's copies never reach the
/// general pasteboard. Returns whether it was installed. `test-util` only
/// (ADR-0018).
///
/// # Safety
/// `handle` must be null or a valid handle.
#[cfg(feature = "test-util")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_test_memory_pasteboard(handle: *mut CompanionHandle) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.retire_last_write();
    guard.pasteboard = Board::Memory(MemoryPasteboard::new());
    true
}

/// # Safety
/// `handle` must be null or a valid handle.
#[cfg(feature = "test-util")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_test_memory_pasteboard_text(
    handle: *mut CompanionHandle,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let board = match &guard.pasteboard {
        Board::Memory(board) => board,
        #[cfg(target_os = "macos")]
        Board::System(_) => return ptr::null_mut(),
    };
    let Some(PasteboardItem {
        content: PasteboardContent::Text(text),
        ..
    }) = board.read()
    else {
        return ptr::null_mut();
    };
    into_c_string(text)
}

/// Write `text` as ink at `pos_u16` of page `sheet`, below the guard that
/// refuses U+FFFC and outside the undo stack, as an earlier build's page or a
/// peer's batch lands it. Returns whether it landed. `test-util` only (ADR-0018).
///
/// # Safety
/// `handle` must be null or a valid handle. `text` must be null or a valid,
/// NUL-terminated UTF-8 C string.
#[cfg(feature = "test-util")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_test_ink_below_the_guard(
    handle: *mut CompanionHandle,
    sheet: u64,
    pos_u16: u32,
    text: *const c_char,
) -> bool {
    if is_file_id(sheet) {
        return false;
    }
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
        .store
        .ink_below_the_guard(SheetId::from_raw(sheet), pos_u16, text)
}

/// Stand a record with no value at `pos_u16` of page `sheet`, as a peer's
/// batch stands one (ADR-0058 point 1), of `kind` (`"text"`, `"image"`, or
/// null for unknown) and size class `size` (`"tiny"` to `"huge"`, or null),
/// under the identity of the chip `of_chip` stands on any page, or a fresh
/// one for 0 (ADR-0058 point 3). Returns its chip id, or 0 on refusal.
/// `test-util` only (ADR-0018).
///
/// # Safety
/// `handle` must be null or a valid handle. `kind` and `size` must each be
/// null or a valid, NUL-terminated UTF-8 C string.
#[cfg(feature = "test-util")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_test_stand_peer_record(
    handle: *mut CompanionHandle,
    sheet: u64,
    pos_u16: u32,
    kind: *const c_char,
    size: *const c_char,
    of_chip: u64,
) -> u64 {
    use companion_core::{PeerKind, SizeClass};
    if is_file_id(sheet) {
        return 0;
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    let kind = if kind.is_null() {
        None
    } else {
        match unsafe { cstr(kind) } {
            Some("text") => Some(PeerKind::Text),
            Some("image") => Some(PeerKind::Image),
            _ => return 0,
        }
    };
    let size = if size.is_null() {
        None
    } else {
        let word = unsafe { cstr(size) };
        let classes = [
            SizeClass::Tiny,
            SizeClass::Small,
            SizeClass::Medium,
            SizeClass::Large,
            SizeClass::Huge,
        ];
        let Some(class) = classes.into_iter().find(|c| Some(c.as_str()) == word) else {
            return 0;
        };
        Some(class)
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return 0;
    };
    let sheet = SheetId::from_raw(sheet);
    let stood = if of_chip == 0 {
        guard.store.stand_peer_record(sheet, pos_u16, kind, size)
    } else {
        let of_chip = ChipId::from_raw(of_chip);
        let Some(uuid) = guard
            .store
            .sheets()
            .find_map(|page| page.chip(of_chip).map(SealedChip::uuid))
        else {
            return 0;
        };
        guard
            .store
            .stand_peer_record_as(sheet, pos_u16, uuid, kind, size)
    };
    stood.map_or(0, ChipId::raw)
}

fn new_handle(credentials: Arc<dyn CredentialStore>) -> *mut CompanionHandle {
    companion_core::harden_process();
    #[cfg(target_os = "macos")]
    let pasteboard = Board::System(SystemPasteboard::new());
    #[cfg(not(target_os = "macos"))]
    let pasteboard = Board::Memory(MemoryPasteboard::new());
    let companion = Companion {
        store: SheetStore::new(SystemClock),
        pasteboard,
        last_write: None,
        concealed_link: None,
        next_link_copy_token: 0,
        connection: None,
        credentials,
        wire: Wire::real(),
        sync: sync_driver::SyncState::default(),
        files: companion_core::FileStore::new(),
        last_open_refusal: None,
        last_save_refusal: None,
        drafts_notices: Vec::new(),
    };
    Box::into_raw(Box::new(CompanionHandle {
        inner: Mutex::new(companion),
    }))
}

/// Release a handle, wiping the sealed bytes it holds. Null is a no-op.
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

// ---- Sheets: create, close, order ----

/// A new tab at the end of the strip with a fresh page. Returns the **tab**
/// id, or 0 for a null handle or poisoned lock. Tab and page ids are
/// separate counters (ADR-0017).
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
    guard.store.new_tab().0.raw()
}

/// Mint a page into an empty tab at that tab's rung (ADR-0017). Returns the
/// page id, or 0 for an unknown tab or one that already holds a page.
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

/// Discard a page and leave its tab standing (ADR-0017). Returns whether the
/// page existed.
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

/// Name a tab. Empty or whitespace clears it; otherwise it is trimmed, capped
/// at 80 characters, and sticky (ADR-0017). The name reaches the ledger.
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

// ---- Sealing: the gesture routes; bytes stay core-side ----

/// Sealed paste (⇧⌘V): the core reads the pasteboard, seals it over the UTF-16
/// range `at_utf16`/`len_utf16`, and clears the board (ADR-0007 Amendment 1).
/// Returns chip JSON (free with [`companion_string_free`]) or null; a refused
/// seal clears nothing. `cleared_out` (nullable) is false when another writer
/// beat the guarded clear.
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
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    // Taken before the read so the guarded clear never wipes unseen content.
    let count = guard.pasteboard.change_count();
    let Some(item) = guard.pasteboard.read() else {
        return ptr::null_mut();
    };
    let sheet = SheetId::from_raw(sheet);
    // The origin URL is content: it persists only in the encrypted commit.
    let message = item.origin_url.as_ref().and_then(|url| origin_message(url));
    let origin = message.as_ref().map(|message| message.as_str());
    let sealed = match item.content {
        PasteboardContent::Text(mut text) => {
            // Wipe the transit copy; the core holds its own.
            let sealed = guard
                .store
                .seal_text_at_with_origin(sheet, &text, at_utf16, len_utf16, origin);
            text.zeroize();
            sealed
        }
        PasteboardContent::Image(bytes) => guard
            .store
            .seal_image_at_with_origin(sheet, bytes, at_utf16, len_utf16, origin),
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

/// Whether the board holds content a sealed paste could take, other than our
/// own copy-out. Reads type metadata only (ADR-0007 Amendment 1).
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

/// The ⌘↩ retrofit: seal `text`, visible ink the shell already holds, over
/// the given UTF-16 range; the shell then forgets its copy. Returns chip JSON
/// (caller frees) or null.
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
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
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

/// Drop-to-seal: the core reads the drag pasteboard and seals it over the
/// UTF-16 range, so dropped bytes never transit the shell. Call from the drop
/// handler. Returns chip JSON (caller frees) or null; always null off macOS.
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
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
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
        // The drag board belongs to the current drag session.
        let Some(item) = SystemPasteboard::drag().read() else {
            return ptr::null_mut();
        };
        let sheet = SheetId::from_raw(sheet);
        let message = item.origin_url.as_ref().and_then(|url| origin_message(url));
        let origin = message.as_ref().map(|message| message.as_str());
        let sealed = match item.content {
            PasteboardContent::Text(mut text) => {
                let sealed = guard
                    .store
                    .seal_text_at_with_origin(sheet, &text, at_utf16, len_utf16, origin);
                text.zeroize();
                sealed
            }
            PasteboardContent::Image(bytes) => guard
                .store
                .seal_image_at_with_origin(sheet, bytes, at_utf16, len_utf16, origin),
        };
        match sealed {
            Ok(chip) => chip_json(&guard.store, sheet, chip),
            Err(_) => ptr::null_mut(),
        }
    }
}

// ---- The synced document ----

/// Replace a page's document with `{"ink": "text"}` and `{"chip": id}` runs:
/// chips it omits detach, those it names reattach; a malformed one refuses whole.
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
    if is_file_id(sheet) {
        return false;
    }
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

/// Take every U+FFFC out of a page's ink, a peer's or an earlier build's
/// (Law 0001), as an edit its peers receive and no undo puts back. Returns
/// whether any went; false for a file, an unknown page or a page with none.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_take_out_object_characters(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> bool {
    if is_file_id(sheet) {
        return false;
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard
        .store
        .take_out_unmarked_object_characters(SheetId::from_raw(sheet))
}

/// Apply an ordered batch of `{"ins": {"at", "text"}}`, `{"del": {"at",
/// "len"}}` and `{"chip": {"at", "id"}}` ops (UTF-16 positions), atomically
/// or not at all (ADR-0013). On false the shell restates the page through
/// [`companion_sheet_sync_document`].
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
    if is_file_id(sheet) {
        return false;
    }
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

/// [`companion_sheet_apply_ops`], but the batch starts its own undo step, as
/// automation such as a continued list marker should.
///
/// # Safety
/// `handle` must be a valid handle. `json` must be a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_apply_ops_as_new_step(
    handle: *mut CompanionHandle,
    sheet: u64,
    json: *const c_char,
) -> bool {
    if is_file_id(sheet) {
        return false;
    }
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
    guard
        .store
        .apply_ops_as_new_step(SheetId::from_raw(sheet), &ops)
}

/// [`companion_sheet_apply_ops`] with the editing gesture supplied by the
/// `TextKit` bridge. The core owns grouping and rejects unknown intent values.
///
/// # Safety
/// `handle` must be a valid handle. `json` must be a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_apply_ops_with_intent(
    handle: *mut CompanionHandle,
    sheet: u64,
    json: *const c_char,
    intent: u32,
    before_location: u32,
    before_length: u32,
    after_location: u32,
    after_length: u32,
) -> bool {
    if is_file_id(sheet) {
        return false;
    }
    let Some(intent) = edit_intent(intent) else {
        return false;
    };
    let Some(selection) =
        edit_selection(before_location, before_length, after_location, after_length)
    else {
        return false;
    };
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
    match selection {
        Some(selection) => guard.store.apply_ops_with_intent_and_selection(
            SheetId::from_raw(sheet),
            &ops,
            intent,
            selection,
        ),
        None => guard
            .store
            .apply_ops_with_intent(SheetId::from_raw(sheet), &ops, intent),
    }
}

/// End a page's current typing/deletion run without creating an undo item.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_finish_editing_group(
    handle: *mut CompanionHandle,
    sheet: u64,
    location: u32,
    length: u32,
) -> bool {
    if is_file_id(sheet) {
        return false;
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let id = SheetId::from_raw(sheet);
    if location == u32::MAX && length == u32::MAX {
        guard.store.finish_editing_group(id)
    } else if location == u32::MAX || length == u32::MAX {
        false
    } else {
        guard.store.finish_editing_group_at(
            id,
            TextSelection {
                location_u16: location,
                length_u16: length,
            },
        )
    }
}

pub(crate) fn edit_intent(raw: u32) -> Option<EditIntent> {
    match raw {
        0 => Some(EditIntent::Typing),
        1 => Some(EditIntent::Deletion),
        2 => Some(EditIntent::Paste),
        3 => Some(EditIntent::Cut),
        4 => Some(EditIntent::Replacement),
        5 => Some(EditIntent::Automation),
        6 => Some(EditIntent::Composition),
        _ => None,
    }
}

pub(crate) fn edit_selection(
    before_location: u32,
    before_length: u32,
    after_location: u32,
    after_length: u32,
) -> Option<Option<EditSelection>> {
    let values = [before_location, before_length, after_location, after_length];
    if values.iter().all(|value| *value == u32::MAX) {
        return Some(None);
    }
    if values.contains(&u32::MAX) {
        return None;
    }
    Some(Some(EditSelection {
        before: TextSelection {
            location_u16: before_location,
            length_u16: before_length,
        },
        after: TextSelection {
            location_u16: after_location,
            length_u16: after_length,
        },
    }))
}

// ---- Undo: the core's stack, not AppKit's (issue #132) ----

/// Undo the page's last local step; returns whether anything reverted. On
/// true the shell restates the page from [`companion_sheet_document_json`]
/// and places the caret per [`companion_sheet_undo_caret_u16`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_undo(handle: *mut CompanionHandle, sheet: u64) -> bool {
    if is_file_id(sheet) {
        return false;
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.undo(SheetId::from_raw(sheet))
}

/// Put back the step [`companion_sheet_undo`] took, on the same terms.
/// Returns whether anything was restored.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_redo(handle: *mut CompanionHandle, sheet: u64) -> bool {
    if is_file_id(sheet) {
        return false;
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.redo(SheetId::from_raw(sheet))
}

/// Whether the page has a step waiting to be taken back. False for an
/// unknown page, and false whenever the answer cannot be had.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_can_undo(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> bool {
    if is_file_id(sheet) {
        return false;
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.can_undo(SheetId::from_raw(sheet))
}

/// Whether the page has a step waiting to be restored.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_can_redo(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> bool {
    if is_file_id(sheet) {
        return false;
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.can_redo(SheetId::from_raw(sheet))
}

/// Content-free label for the next page Undo action. Null when there is no
/// labelled item. Free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_undo_action_name(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> *mut c_char {
    unsafe { sheet_action_name(handle, sheet, true) }
}

/// Content-free label for the next page Redo action.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_redo_action_name(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> *mut c_char {
    unsafe { sheet_action_name(handle, sheet, false) }
}

unsafe fn sheet_action_name(handle: *mut CompanionHandle, sheet: u64, undo: bool) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let id = SheetId::from_raw(sheet);
    let name = if undo {
        guard.store.undo_action_name(id)
    } else {
        guard.store.redo_action_name(id)
    };
    name.map_or(ptr::null_mut(), |value| into_c_string(value.to_string()))
}

/// Caret position after the last undo or redo step, in UTF-16 units; `-1`
/// when there is none or the page is unknown.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_undo_caret_u16(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> i64 {
    if is_file_id(sheet) {
        return -1;
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    let Ok(guard) = handle.inner.lock() else {
        return -1;
    };
    guard
        .store
        .restored_caret_u16(SheetId::from_raw(sheet))
        .map_or(-1, i64::from)
}

/// The location of the selection restored by the last accepted step.
/// Returns `-1` when that step carried no selection.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_undo_selection_location_u16(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> i64 {
    if is_file_id(sheet) {
        return -1;
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    let Ok(guard) = handle.inner.lock() else {
        return -1;
    };
    guard
        .store
        .restored_selection_u16(SheetId::from_raw(sheet))
        .map_or(-1, |selection| i64::from(selection.location_u16))
}

/// The length paired with [`companion_sheet_undo_selection_location_u16`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_undo_selection_length_u16(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> i64 {
    if is_file_id(sheet) {
        return -1;
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    let Ok(guard) = handle.inner.lock() else {
        return -1;
    };
    guard
        .store
        .restored_selection_u16(SheetId::from_raw(sheet))
        .map_or(-1, |selection| i64::from(selection.length_u16))
}

// ---- Chips: copy-out, delete ----

/// Copy a chip out: the core writes the pasteboard marked transient and
/// `ConcealedType`, keeps the receipt for [`companion_clear_clipboard_if_ours`],
/// and records one `sent` to `clipboard`. The chip survives. Returns whether
/// it existed; false, writing and recording nothing, past its page's deadline
/// (Law 0001, expiry row) or when its value is on another device (ADR-0058
/// point 4).
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
    let chip = ChipId::from_raw(chip);
    let Some((bytes, meta)) = guard.store.copy_out_chip(chip) else {
        return false;
    };
    guard.write_decrypted(chip, bytes, content_kind(meta));
    true
}

/// Copy `NAME=<plaintext>` by copy decrypted's route
/// (Law 0001; ADR-0047 point 2): the store composes it and this
/// writes it as [`companion_chip_copy_out`] does. False, writing and recording
/// nothing, for an unknown, unnamed or image chip, one whose value is on
/// another device (ADR-0058 point 4), or a page past its deadline
/// (Law 0001, expiry row).
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_copy_name_value(
    handle: *mut CompanionHandle,
    chip: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let chip = ChipId::from_raw(chip);
    let Some(bytes) = guard.store.copy_out_name_value(chip) else {
        return false;
    };
    guard.write_decrypted(chip, bytes, ContentKind::Text);
    true
}

/// Whether a chip stands on a live page, past its deadline or not, as the
/// chip conceal's error asks; the shell words a refusal by it. False for an
/// unknown chip or a null handle.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_stands(handle: *mut CompanionHandle, chip: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.chip_stands(ChipId::from_raw(chip))
}

/// Burn a chip, attached or detached, wiping its bytes and its page's undo
/// stack (ADR-0046 point 2). Returns whether it existed; false, changing
/// nothing, when its value is on another device (ADR-0058 point 8).
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

/// Judge a draft sealed name without a handle (ADR-0042 point 1):
/// 0 takes it, an empty draft clearing; 1 is too long; 2 is outside the
/// charset, as are null and non-UTF-8.
///
/// # Safety
/// `draft` must be null or a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_name_refusal(draft: *const c_char) -> u32 {
    let Some(draft) = (unsafe { cstr(draft) }) else {
        return 2;
    };
    match judge_name(draft) {
        Ok(_) => 0,
        Err(NameRefusal::TooLong) => 1,
        Err(
            NameRefusal::OutsideCharset | NameRefusal::UnknownChip | NameRefusal::VersionsSpent,
        ) => 2,
    }
}

/// Name a sealed object, or clear its name with a blank draft
/// (ADR-0042 point 1). False for an unknown chip, a page past its
/// deadline (Law 0001, expiry row) or a refused draft; the name is then
/// unchanged.
///
/// # Safety
/// `handle` must be a valid handle. `name` must be a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_set_name(
    handle: *mut CompanionHandle,
    chip: u64,
    name: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(name) = (unsafe { cstr(name) }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard
        .store
        .set_chip_name(ChipId::from_raw(chip), name)
        .is_ok()
}

// ---- A sealed object's note: its own document, keyed by chip (ADR-0043 point 2) ----

/// The note as document runs: `[]` without one, else `[{"ink": text}]`. Null
/// for an unknown chip or a page past its deadline (Law 0001, expiry row).
/// Free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_note_runs_json(
    handle: *mut CompanionHandle,
    chip: u64,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let Some(text) = guard.store.note_text(ChipId::from_raw(chip)) else {
        return ptr::null_mut();
    };
    to_c_json(&content_json::InkRuns(text.as_str()))
}

/// Apply an edit batch to the note with its `TextKit` gesture, whole or not at
/// all, as [`companion_sheet_apply_ops_with_intent`] does a page's. A chip op is
/// refused, as are an unknown chip and a page past its deadline (Law 0001,
/// expiry row); the first accepted batch makes the note.
///
/// # Safety
/// `handle` must be a valid handle. `json` must be a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_note_apply_ops_with_intent(
    handle: *mut CompanionHandle,
    chip: u64,
    json: *const c_char,
    intent: u32,
    before_location: u32,
    before_length: u32,
    after_location: u32,
    after_length: u32,
) -> bool {
    let Some(intent) = edit_intent(intent) else {
        return false;
    };
    let Some(selection) =
        edit_selection(before_location, before_length, after_location, after_length)
    else {
        return false;
    };
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
    guard
        .store
        .apply_note_ops(ChipId::from_raw(chip), &ops, intent, selection)
}

/// End the note's typing run without an undo item; `u32::MAX` twice for no
/// selection. False for an unknown chip, a page past its deadline (Law 0001,
/// expiry row) or a half-given selection.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_note_finish_editing_group(
    handle: *mut CompanionHandle,
    chip: u64,
    location: u32,
    length: u32,
) -> bool {
    let selection = match (location, length) {
        (u32::MAX, u32::MAX) => None,
        (u32::MAX, _) | (_, u32::MAX) => return false,
        (location_u16, length_u16) => Some(TextSelection {
            location_u16,
            length_u16,
        }),
    };
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard
        .store
        .finish_note_editing_group(ChipId::from_raw(chip), selection)
}

/// Whether the note has a step of its own to take back; false for an
/// unknown chip. The page's stack is [`companion_sheet_can_undo`]'s.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_note_can_undo(
    handle: *mut CompanionHandle,
    chip: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.note_can_undo(ChipId::from_raw(chip))
}

/// Whether the note has a step of its own to put back.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_note_can_redo(
    handle: *mut CompanionHandle,
    chip: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.note_can_redo(ChipId::from_raw(chip))
}

/// Content-free label for the note's next Undo; null when none waits.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_note_undo_action_name(
    handle: *mut CompanionHandle,
    chip: u64,
) -> *mut c_char {
    unsafe { note_action_name(handle, chip, true) }
}

/// Content-free label for the note's next Redo; null when none waits.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_note_redo_action_name(
    handle: *mut CompanionHandle,
    chip: u64,
) -> *mut c_char {
    unsafe { note_action_name(handle, chip, false) }
}

/// # Safety
/// As the two callers above.
unsafe fn note_action_name(handle: *mut CompanionHandle, chip: u64, undo: bool) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let chip = ChipId::from_raw(chip);
    let name = if undo {
        guard.store.note_undo_action_name(chip)
    } else {
        guard.store.note_redo_action_name(chip)
    };
    name.map_or(ptr::null_mut(), |value| into_c_string(value.to_string()))
}

/// Take back the note's last step, never the page's. Returns a `StepOutcome`,
/// null for an unknown chip or a page past its deadline (Law 0001, expiry
/// row). Free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_note_undo(
    handle: *mut CompanionHandle,
    chip: u64,
) -> *mut c_char {
    unsafe { note_step(handle, chip, true) }
}

/// Put back the step [`companion_chip_note_undo`] took, on the same terms.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_note_redo(
    handle: *mut CompanionHandle,
    chip: u64,
) -> *mut c_char {
    unsafe { note_step(handle, chip, false) }
}

/// # Safety
/// As the two callers above.
unsafe fn note_step(handle: *mut CompanionHandle, chip: u64, back: bool) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let chip = ChipId::from_raw(chip);
    let outcome = if back {
        guard.store.undo_note(chip)
    } else {
        guard.store.redo_note(chip)
    };
    outcome.map_or(ptr::null_mut(), step_outcome_json)
}

// ---- The sealed fragment: copy, cut, paste, drags (ADR-0045 and ADR-0046) ----

/// Copy a UTF-16 range as `{"envelope": string|null, "plain": string}`, or
/// `{"error", "limit"}` past an envelope cap (Law 0001, copy row); null for a
/// file id, an unknown page, a page past its deadline (Law 0001, expiry row)
/// or a bad range.
/// Free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_copy_fragment(
    handle: *mut CompanionHandle,
    sheet: u64,
    at_utf16: u32,
    len_utf16: u32,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    copy_outcome_json(
        guard
            .store
            .copy_fragment(SheetId::from_raw(sheet), at_utf16, len_utf16),
    )
}

/// [`companion_sheet_copy_fragment`], then delete the range as one undo step,
/// its objects detaching as the active cut. It refuses as the copy does, or
/// for a body that refuses the edit, and a refusal changes nothing.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_cut_fragment(
    handle: *mut CompanionHandle,
    sheet: u64,
    at_utf16: u32,
    len_utf16: u32,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    copy_outcome_json(
        guard
            .store
            .cut_fragment(SheetId::from_raw(sheet), at_utf16, len_utf16),
    )
}

/// Compose runs the shell shows of a page, a preview's rendered text between
/// its objects and each object by chip id, as `[{"ink": "…"}, {"chip": 7}, …]`
/// (the synced document's shape), the way [`companion_sheet_copy_fragment`]
/// composes a range: the shown text is the ink (Law 0001, the preview's rows).
/// The same answer and the same refusals, and null also for an object off the
/// page or `shown` that does not parse.
/// Free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle. `shown` must be null or a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_compose_fragment(
    handle: *mut CompanionHandle,
    sheet: u64,
    shown: *const c_char,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(shown) = (unsafe { cstr(shown) }).and_then(parse_segments) else {
        return ptr::null_mut();
    };
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    copy_outcome_json(
        guard
            .store
            .compose_fragment(SheetId::from_raw(sheet), &shown),
    )
}

/// Paste envelope bytes over a range as one undo step, `plain` placed for one
/// the core cannot read. The placed JSON ([`placed_json`]), or null on refusal.
///
/// # Safety
/// `handle` must be a valid handle. `envelope` must be null or readable for
/// `envelope_len` bytes. `plain` must be null or a valid, NUL-terminated
/// UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_paste_fragment(
    handle: *mut CompanionHandle,
    sheet: u64,
    at_utf16: u32,
    len_utf16: u32,
    envelope: *const u8,
    envelope_len: usize,
    plain: *const c_char,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let envelope: &[u8] = if envelope.is_null() || envelope_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(envelope, envelope_len) }
    };
    let plain = unsafe { cstr(plain) };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .paste_fragment(
            SheetId::from_raw(sheet),
            at_utf16,
            len_utf16,
            envelope,
            plain,
        )
        .map_or(ptr::null_mut(), placed_json)
}

/// Place the active cut over a UTF-16 range, the clipboard slot's route; null
/// when no cut stands, or as [`companion_sheet_paste_fragment`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_paste_active_cut(
    handle: *mut CompanionHandle,
    sheet: u64,
    at_utf16: u32,
    len_utf16: u32,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .paste_active_cut(SheetId::from_raw(sheet), at_utf16, len_utf16)
        .map_or(ptr::null_mut(), placed_json)
}

/// A drag inside a page: move a range to `to_utf16`, measured before the move,
/// as one step. The placed JSON, or null for a `to` inside or at its edge or a
/// page past its deadline.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_move_range(
    handle: *mut CompanionHandle,
    sheet: u64,
    from_utf16: u32,
    len_utf16: u32,
    to_utf16: u32,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .move_range(SheetId::from_raw(sheet), from_utf16, len_utf16, to_utf16)
        .map_or(ptr::null_mut(), placed_json)
}

/// A drag between pages (Law 0001, drag row): move a range of `source` to
/// `at_utf16` on `dest` as one transaction keeping every object. The placed
/// JSON, its run on `dest`, or null with neither page changed.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_move_range_to(
    handle: *mut CompanionHandle,
    source: u64,
    from_utf16: u32,
    len_utf16: u32,
    dest: u64,
    at_utf16: u32,
) -> *mut c_char {
    if is_file_id(source) || is_file_id(dest) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .move_range_to(
            SheetId::from_raw(source),
            from_utf16,
            len_utf16,
            SheetId::from_raw(dest),
            at_utf16,
        )
        .map_or(ptr::null_mut(), placed_json)
}

/// The ⌥ drag inside a page: insert a copy of a UTF-16 range at `to_utf16`,
/// every object cloned, as one step. Returns the placed JSON or null.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_clone_range(
    handle: *mut CompanionHandle,
    sheet: u64,
    from_utf16: u32,
    len_utf16: u32,
    to_utf16: u32,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .clone_range(SheetId::from_raw(sheet), from_utf16, len_utf16, to_utf16)
        .map_or(ptr::null_mut(), placed_json)
}

/// The clipboard slot: `{"page_id": u64|null, "objects": [face]}`, null and
/// `[]` with no cut. Free with [`companion_string_free`]; null on error.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_active_cut_json(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let (page, objects) = guard.store.active_cut().unzip();
    to_c_json(&content_json::ActiveCut {
        objects: objects
            .unwrap_or_default()
            .into_iter()
            .map(chip_face)
            .collect(),
        page_id: page.map(SheetId::raw),
    })
}

/// Decrypted drag: write a chip's payload into the drag `item` on `pasteboard`
/// under its type and record one `sent` to `drag`; false, doing neither, on
/// refusal, which includes a removed chip, one whose value is on another
/// device (ADR-0058 point 4) and a page past its deadline (Law 0001, expiry row).
///
/// # Safety
/// `handle` must be a valid handle. `pasteboard` and `item` must each be null
/// or the live `NSPasteboard` and `NSPasteboardItem` the provider was handed,
/// for the call. `pasteboard_type` must be null or a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_provide_drag(
    handle: *mut CompanionHandle,
    chip: u64,
    pasteboard: *mut std::ffi::c_void,
    item: *mut std::ffi::c_void,
    pasteboard_type: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(requested) = (unsafe { cstr(pasteboard_type) }) else {
        return false;
    };
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (handle, chip, pasteboard, item, requested);
        false
    }
    #[cfg(target_os = "macos")]
    {
        // SAFETY: the caller vouches each pointer is null or a live object.
        let Some(mut drag) =
            (unsafe { companion_pasteboard::SystemDragItem::from_raw(pasteboard, item) })
        else {
            return false;
        };
        let Ok(mut guard) = handle.inner.lock() else {
            return false;
        };
        guard.provide_drag(ChipId::from_raw(chip), &mut drag, requested)
    }
}

/// Clear the pasteboard only if it still holds our last copy-out. Returns
/// whether a clear happened.
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

/// Seconds a copy-out may dwell before the shell's armed clear (D-29, D-32).
pub const CLIPBOARD_CLEAR_SECONDS: u32 = 60;

/// [`CLIPBOARD_CLEAR_SECONDS`], for the shell.
#[unsafe(no_mangle)]
pub extern "C" fn companion_clipboard_clear_seconds() -> u32 {
    CLIPBOARD_CLEAR_SECONDS
}

/// Availability interval for a completed link's copy-again session.
pub const LINK_RECOVERY_SECONDS: u32 = 60;

/// The link recovery access interval for the shell.
#[unsafe(no_mangle)]
pub extern "C" fn companion_conceal_link_recovery_seconds() -> u32 {
    LINK_RECOVERY_SECONDS
}

impl Companion {
    fn cached_link(&mut self, token: u64, now: Instant) -> Option<&CachedConcealLink> {
        let valid = self.concealed_link.as_ref().is_some_and(|link| {
            now < link.expires_at
                && match link.target {
                    Concealable::Chip(chip) => self
                        .store
                        .readable_sheets()
                        .any(|sheet| sheet.chip(chip).is_some()),
                    Concealable::Page(page) => {
                        self.store.readable_sheets().any(|sheet| sheet.id() == page)
                    }
                }
        });
        if !valid {
            self.concealed_link = None;
        }
        self.concealed_link
            .as_ref()
            .filter(|link| link.token == token)
    }

    /// Take back our previous write first, so a clear armed for it cannot
    /// fire against the new one.
    fn retire_last_write(&mut self) {
        if let Some(receipt) = self.last_write.take() {
            self.pasteboard.clear_if_unchanged(receipt);
        }
    }

    /// Copy decrypted's write, whatever composed the bytes: retire, write
    /// transient and concealed, keep the receipt, record one `sent`.
    fn write_decrypted(&mut self, chip: ChipId, bytes: Zeroizing<Vec<u8>>, kind: ContentKind) {
        self.retire_last_write();
        let receipt = self.pasteboard.write(
            bytes,
            kind,
            WriteOptions {
                nspasteboard_concealed: true,
            },
        );
        self.last_write = Some(receipt);
        self.store.record_sent(chip, DestinationClass::Clipboard);
    }

    /// Decrypted drag's write: the chip's own type only, never the general
    /// pasteboard, one `sent` to `drag` once the item took the bytes.
    // Only AppKit hands a drag item; off macOS only the tests call this.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    fn provide_drag(&mut self, chip: ChipId, item: &mut dyn DragItem, requested: &str) -> bool {
        if item.on_general_pasteboard() {
            return false;
        }
        // No meta when the value is on another device, so nothing is provided.
        let Some(meta) = self
            .store
            .readable_sheets()
            .find_map(|sheet| sheet.chip(chip))
            .and_then(SealedChip::meta)
        else {
            return false;
        };
        let kind = content_kind(meta);
        if kind.pasteboard_type() != requested {
            return false;
        }
        let Some((bytes, _)) = self.store.copy_out_chip(chip) else {
            return false;
        };
        if !item.provide(&bytes, kind) {
            return false;
        }
        self.store.record_sent(chip, DestinationClass::Drag)
    }
}

/// The pasteboard kind a chip's payload is written as.
fn content_kind(meta: ChipMeta) -> ContentKind {
    match meta {
        ChipMeta::Text { .. } => ContentKind::Text,
        ChipMeta::Image { .. } => ContentKind::Image,
    }
}

// ---- Reading state: non-secret metadata only ----

/// A JSON array of tab summaries in strip order, one per slot whether or not
/// it holds a page (ADR-0017). Free with [`companion_string_free`]; null on
/// error.
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
    let now_wall_ms = guard.store.wall_ms();
    let summaries: Vec<_> = guard
        .store
        .tabs()
        .map(|tab| summary_json(tab, now, offset, now_wall_ms))
        .collect();
    to_c_json(&summaries)
}

/// Whether no tab holds a page and whether no tabs remain (ADR-0017). The
/// first triggers key rotation, the second the file drop (ADR-0016); do not
/// swap them. On failure returns false with both outputs false.
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
    // Fail closed: false means no rotation and no drop.
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

/// The ledger as JSON, newest first, metadata only (ADR-0012): `title` is the
/// one page-owned text. Each record is an object:
///
/// - `event`: `created` | `sealed` | `sent` | `expired` | `discarded`
/// - `item`: the item's UUID, lowercase hyphenated, 36 characters
/// - `title`: the host page's title at the moment of the event
/// - `at_ms`: when it happened, Unix epoch milliseconds
/// - `created_at_ms`: when the item's page was created, epoch ms
/// - `size`: `tiny` | `small` | `medium` | `large` | `huge`
/// - `destination`: `none` | `clipboard` | `link` | `drag`
///
/// Free with [`companion_string_free`]; null on error.
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
    let records: Vec<_> = guard.store.ledger().map(content_json::ledger_row).collect();
    to_c_json(&records)
}

/// Clear the ledger in memory; the shell must save for it to reach the file.
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

/// A live page's document as `[{"ink": "…"}, {"chip": {…}}]`, each chip as its
/// non-secret face. Free with [`companion_string_free`]; null for an unknown
/// page.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_document_json(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let Some(sheet) = guard.store.sheet(SheetId::from_raw(sheet)) else {
        return ptr::null_mut();
    };
    to_c_json(&content_json::DocumentRuns(sheet))
}

/// A page's provenance (ADR-0013): `{"created_ms": u64, "modified_s":
/// i64|null}`, and no origin URL. Free with [`companion_string_free`]; null
/// for an unknown page.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_meta_json(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
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

/// A page's blocks in document order (ADR-0013): `{"id": uuid, "created_s":
/// i64|null, "modified_s": i64|null, "paragraphs": u32}`, identities and
/// stamps only. Free with [`companion_string_free`]; null for an unknown page.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_blocks_json(
    handle: *mut CompanionHandle,
    sheet: u64,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
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

/// Milliseconds until the earliest page expiry or hold lapse: the one timer
/// the shell arms. `-1` when nothing is scheduled, `0` when something is due.
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

/// Settle the clock when the armed timer fires, then re-arm from
/// [`companion_next_event_ms`]. Returns how many pages expired.
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

/// Drain the pages another page's edit, burn or end changed since the last
/// call, as a JSON array of page ids, for the shell to read again as it reads
/// a peer's batch (ADR-0058 points 3 and 8). Free with
/// [`companion_string_free`]; null on error.
///
/// # Safety
/// `handle` must be null or a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_take_restated_pages_json(
    handle: *mut CompanionHandle,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let pages: Vec<u64> = guard
        .store
        .take_restated_pages()
        .into_iter()
        .map(SheetId::raw)
        .collect();
    to_c_json(&pages)
}

// ---- Persistence: the sealed state file ----

/// Save the staged content to `path`, sealed under two key halves: one in the
/// keychain, one a 0600 file beside `path` (ADR-0012, ADR-0016). The ledger
/// has its own file ([`companion_ledger_save`]).
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

/// The body of [`companion_persist_save`], shared with
/// [`companion_persist_rotate_and_save`]. The caller holds the lock.
fn seal_state_to(state: &Companion, path: &Path) -> bool {
    let Some(wall_ms) = wall_now_ms() else {
        return false;
    };
    let Some(key) = persist::ensure_state_key(state.credentials.as_ref(), path) else {
        return false;
    };
    let snapshot = state.store.snapshot(wall_ms);
    // The wall stamp also goes in the authenticated header.
    let Some(sealed) = persist::seal_state(&key, &snapshot, wall_ms) else {
        return false;
    };
    persist::write_private(path, &sealed)
}

/// Rotate both content key halves and reseal the store under the new ones,
/// for when no tab holds a page (ADR-0016). Returns false for a path that is
/// not the content file, a half that survived erasure, or a failed write.
/// Erased before the reseal (persistence decision background section 6).
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
    // Also excludes an ordinary save at the same path.
    let Ok(mut guard) = handle.inner.lock() else {
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
    match persist::rotate_key_halves(guard.credentials.as_ref(), path) {
        persist::Erasure::Survived => {
            diag_fault!(
                "companion-ffi: the content file was left alone because its file half could not \
                 be erased. Resealing over it would seal the new generation under a key that \
                 may still open every old one, and would consume the retry."
            );
            return false;
        }
        persist::Erasure::Neutralized => {
            diag_fault!(
                "companion-ffi: a file half was zeroed but its name could not be unlinked. The \
                 content it keyed is already unreadable, so the reseal proceeds."
            );
        }
        persist::Erasure::Gone => {}
    }
    // Drafts before the strip (Law 0005).
    let drafts = files::reseal_drafts_beside(&mut guard, path);
    seal_state_to(&guard, path) && drafts
}

/// Wall-clock milliseconds between a file's seal stamp and now (ADR-0016).
/// A future stamp reads as zero, freezing a countdown rather than rewinding it.
fn wall_away_ms(now_ms: u64, sealed_wall_ms: u64) -> u64 {
    now_ms.saturating_sub(sealed_wall_ms)
}

/// Restore the store from a [`companion_persist_save`] file and drain each
/// countdown by the wall time away; pages due while away expire into the
/// ledger. A file it cannot open stays in place; a superseded format is
/// dropped (ADR-0016). Also sweeps stranded `*.tmp` files. Returns whether a
/// state was restored; false includes no file yet.
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
    // Before the read, so an early return still sweeps; under the lock, so
    // no save of ours is mid-write.
    if let Some(dir) = persist::containing_dir(Path::new(path)) {
        persist::sweep_stranded_temps(dir);
    }
    // Refuses a planted FIFO rather than blocking (see `persist::erase_state`).
    let Ok(file) = files::read_regular_file(Path::new(path)) else {
        return false;
    };
    // Load the key only for a readable envelope: a keychain read can prompt (ADR-0004).
    let opened = persist::open_state(&file, || {
        persist::load_state_key(guard.credentials.as_ref(), Path::new(path))
    });
    match opened {
        persist::Opened::Refused => false,
        persist::Opened::Superseded => {
            // Not rotated (Law 0005).
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
            // An unreadable wall clock is a refusal, not a guess; the file stays.
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

/// Drop the file at `path`; returns whether the path is confirmed empty.
/// For the content file the key halves are rotated first (ADR-0016), and a
/// half that survives keeps the file and returns false. On copy-on-write
/// storage the unlink is tidying, not erasure. For when no tabs remain;
/// [`companion_persist_rotate_and_save`] takes the other predicate.
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
    // Also excludes a save in flight at the same path.
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let path = Path::new(path);
    if persist::drop_takes_the_content_key(path)
        && persist::rotate_key_halves(guard.credentials.as_ref(), path)
            == persist::Erasure::Survived
    {
        // Keep the file so the shell's retry finds it.
        diag_fault!(
            "companion-ffi: the content file was left alone because its file half could not be \
             erased. Dropping the ciphertext while the half that opens it is still on disk \
             would forget nothing and would consume the retry."
        );
        return false;
    }
    // An open file's draft is not this call's to discard (ADR-0028): reseal
    // it while any file is open. A ledger clear never takes this branch.
    if persist::drop_takes_the_content_key(path) {
        if guard.files.files().is_empty() {
            if !files::erase_drafts_beside(path) {
                diag_fault!(
                    "companion-ffi: the drafts file could not be dropped. It is already \
                     unreadable, the rotation having taken its key, so what is left at the \
                     path is inert bytes."
                );
            }
        } else if !files::reseal_drafts_beside(&mut guard, path) {
            // The content file still goes; refusing would strand its ciphertext too.
            diag_fault!(
                "companion-ffi: open files were staged, but their drafts could not be \
                 rewritten under the rotated content key. Every unsaved file edit is \
                 unreadable from now on."
            );
        }
    }
    persist::erase_state(path)
}

/// Save the ledger to `path` under its own long-lived key, which content-key
/// rotation never touches. Sweeps the 90-day window first. Call beside
/// [`companion_persist_save`]. Returns success.
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
    // Sweep and snapshot under one lock, or a record appended between them
    // is persisted against a stale sweep.
    guard.store.evict_ledger(wall_ms);
    let snapshot = guard.store.ledger_snapshot();
    let Some(sealed) = persist::seal_ledger(&key, &snapshot) else {
        return false;
    };
    persist::write_private(Path::new(path), &sealed)
}

/// Restore the ledger from a [`companion_ledger_save`] file, dropping records
/// past the 90-day window; independent of [`companion_persist_restore`]. A
/// superseded payload is erased and returns false, without rotating the key
/// (ADR-0004, ADR-0016); every other refusal leaves the file in place.
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
    let Ok(file) = files::read_regular_file(Path::new(path)) else {
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

// ---- Time: the ladder and the pause ----

/// Step a tab one rung shorter (`7d → 3d → 24h → 8h → 3h → 1h`, wrapping) and
/// reset its page's clock to it; a hold is kept, and an empty tab keeps the
/// rung for its next page (ADR-0017). Returns the rung code, or `-1`.
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

/// Set a tab's rung (`CompanionRung` codes) and reset its page's clock.
/// Returns whether the tab existed and the code was valid.
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

/// Turn the boundary snap on or off (ADR-0011 §4). It applies to rungs set
/// afterwards, never to deadlines already set; the core starts with it on.
/// False only for a null handle or poisoned lock.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_set_grace_snap(handle: *mut CompanionHandle, on: bool) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.set_grace_snap(on);
    true
}

/// The pause gesture: hold for 1 hour, then top up to 24 hours from now, then
/// release. A lapse is folded into [`companion_next_event_ms`]; the summary's
/// `hold_topped_up` says which press is next. Returns false for an unknown
/// tab, an empty one, or a page already due.
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

// ---- Conceal: the exit ramp, an explicit user action ----

/// Configure where a conceal goes. `json` is the connection plus an optional
/// token:
///
/// ```json
/// { "server_url": "https://eu.onetimesecret.com",
///   "share_domain": "",           // empty → the server's host
///   "extid": "org_…",             // empty → guest-only
///   "token": "…" }                // absent: keep stored token;
///                                 // empty string: delete it
/// ```
///
/// The token goes to the credential store, never into config. Refuses a
/// malformed object or a non-`https` server URL.
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
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(json) else {
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
    // Take the token out of the tree so our only copy is the zeroizing one.
    match value.get_mut("token").map(serde_json::Value::take) {
        Some(serde_json::Value::String(token)) => {
            let token = Zeroizing::new(token);
            if token.is_empty() {
                guard.credentials.delete(TOKEN_ACCOUNT).is_ok()
            } else {
                guard
                    .credentials
                    .store(TOKEN_ACCOUNT, token.as_bytes())
                    .is_ok()
            }
        }
        _ => true,
    }
}

/// The connection for display, never the token: `{"configured", "server_url",
/// "share_domain", "extid", "has_token"}`, or null. Free with
/// [`companion_string_free`]. `has_token` checks existence only, so no prompt.
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
    // Fail to no token: rendering Settings must not wedge on the Keychain.
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

/// The Settings test: one `GET /api/v3/status`. Blocks for the round-trip
/// without holding the core lock; call off the main thread. Returns `{"ok"}`
/// or `{"ok": false, "error"}`; free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_connection_test(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let (conn, wire) = {
        let Ok(guard) = handle.inner.lock() else {
            return ptr::null_mut();
        };
        (guard.connection.clone(), guard.wire.clone())
    };
    let Some(conn) = conn else {
        return conceal_error("no connection configured");
    };
    let api = ots_client::Api::new(conn.server_url, Box::new(ots_client::NoAuth));
    let result = match wire.send(api.status_request()) {
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

/// Conceal one chip into a one-time link. `opts_json` is `{"ttl_secs"?,
/// "passphrase"?, "recipient"?}` or null; the TTL defaults to seven days
/// (ADR-0011 §5), not the page's clock (ADR-0026). Blocks for the round-trip
/// without holding the core lock; call off the main thread. On success the
/// link is on the clipboard. Returns `{"ok": true, "receipt_id"}` or
/// `{"ok": false, "error"}`, sending nothing for a page past its deadline
/// (Law 0001, expiry row) or a chip whose value is on another device
/// (ADR-0058 point 4); free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle. `opts_json`, when non-null, must be
/// a valid, NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_chip_conceal(
    handle: *mut CompanionHandle,
    chip: u64,
    opts_json: *const c_char,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(opts) = ConcealOpts::parse(unsafe { cstr(opts_json) }) else {
        return conceal_error("malformed conceal options");
    };
    let chip = ChipId::from_raw(chip);

    // Stage under the lock, then let go: a slow server must not block a summon.
    let staged = {
        let Ok(guard) = handle.inner.lock() else {
            return ptr::null_mut();
        };
        let Some(conn) = guard.connection.clone() else {
            return conceal_error("no connection configured");
        };
        let holder = guard
            .store
            .readable_sheets()
            .find(|sheet| sheet.chip(chip).is_some());
        let Some(sheet) = holder else {
            // A page past its deadline still stands until its sweep.
            if guard.store.chip_stands(chip) {
                return conceal_error(&PayloadError::Expired.to_string());
            }
            return conceal_error("that content is gone");
        };
        match sheet.chip(chip).map(SealedChip::meta) {
            Some(None) => return conceal_error("this chip's value is on another device"),
            Some(Some(ChipMeta::Image { .. })) => {
                return conceal_error(
                    "this chip holds an image, which cannot travel as a text secret yet",
                );
            }
            Some(Some(ChipMeta::Text { .. })) | None => {}
        }
        let Some(bytes) = guard.store.chip_payload(chip) else {
            return conceal_error("that content is gone");
        };
        let Ok(text) = std::str::from_utf8(&bytes) else {
            return conceal_error("this chip is not text");
        };
        let payload = Zeroizing::new(text.to_owned());
        (
            conn,
            load_token(&*guard.credentials),
            payload,
            guard.wire.clone(),
        )
    };
    let (conn, token, payload, wire) = staged;

    match conceal(&conn, token, payload, &opts, wire) {
        Ok(concealed) => finish_conceal(handle, concealed, Concealable::Chip(chip)),
        Err(message) => conceal_error(&message),
    }
}

/// Conceal the whole page (ink plus inlined sealed bytes; refused with an
/// image chip, or an object in the body whose value is on another device)
/// into one link, recording one `sent` against the page.
/// Otherwise as [`companion_chip_conceal`].
///
/// # Safety
/// `handle` must be a valid handle. `opts_json`, when non-null, must be
/// a valid, NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_conceal(
    handle: *mut CompanionHandle,
    sheet: u64,
    opts_json: *const c_char,
) -> *mut c_char {
    if is_file_id(sheet) {
        return ptr::null_mut();
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(opts) = ConcealOpts::parse(unsafe { cstr(opts_json) }) else {
        return conceal_error("malformed conceal options");
    };
    let sheet = SheetId::from_raw(sheet);

    let staged = {
        let Ok(guard) = handle.inner.lock() else {
            return ptr::null_mut();
        };
        let Some(conn) = guard.connection.clone() else {
            return conceal_error("no connection configured");
        };
        let payload = match guard.store.sheet_payload(sheet) {
            Ok(payload) => payload,
            Err(e) => return conceal_error(&e.to_string()),
        };
        if payload.trim().is_empty() {
            return conceal_error("nothing to conceal");
        }
        (
            conn,
            load_token(&*guard.credentials),
            payload,
            guard.wire.clone(),
        )
    };
    let (conn, token, payload, wire) = staged;

    match conceal(&conn, token, payload, &opts, wire) {
        Ok(concealed) => finish_conceal(handle, concealed, Concealable::Page(sheet)),
        Err(message) => conceal_error(&message),
    }
}

/// The stored API token as a zeroizing string, if present and UTF-8.
fn load_token(credentials: &dyn CredentialStore) -> Option<Zeroizing<String>> {
    let bytes = credentials.load(TOKEN_ACCOUNT).ok()?;
    std::str::from_utf8(&bytes)
        .ok()
        .map(|s| Zeroizing::new(s.to_owned()))
}

/// What a conceal put on the wire: one chip, or a whole page.
#[derive(Clone, Copy)]
enum Concealable {
    /// The ↗ on a chip. The receipt id lands on that chip.
    Chip(ChipId),
    /// The ↗ page in the footer; nothing is marked.
    Page(SheetId),
}

struct CachedConcealLink {
    bytes: Zeroizing<Vec<u8>>,
    token: u64,
    expires_at: Instant,
    target: Concealable,
}

/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_conceal_link_can_copy(
    handle: *mut CompanionHandle,
    token: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let now = guard.store.now();
    guard.cached_link(token, now).is_some()
}

/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_conceal_link_remaining_ms(
    handle: *mut CompanionHandle,
    token: u64,
) -> u64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return 0;
    };
    let now = guard.store.now();
    guard.cached_link(token, now).map_or(0, |link| {
        u64::try_from(link.expires_at.saturating_duration_since(now).as_millis())
            .unwrap_or(u64::MAX)
    })
}

/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_conceal_link_copy(
    handle: *mut CompanionHandle,
    token: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let now = guard.store.now();
    let Some(link) = guard.cached_link(token, now) else {
        return false;
    };
    let bytes = link.bytes.clone();
    guard.retire_last_write();
    let receipt = guard.pasteboard.write(
        bytes,
        ContentKind::Text,
        WriteOptions {
            nspasteboard_concealed: false,
        },
    );
    guard.last_write = Some(receipt);
    true
}

/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_conceal_link_forget(handle: *mut CompanionHandle, token: u64) {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return;
    };
    if guard
        .concealed_link
        .as_ref()
        .is_some_and(|link| link.token == token)
    {
        guard.concealed_link = None;
    }
}

/// After a successful conceal: the link onto the clipboard (transient), the
/// receipt onto the chip if any, one `sent` to `link`, and the result JSON.
fn finish_conceal(
    handle: &CompanionHandle,
    concealed: Concealed,
    sent: Concealable,
) -> *mut c_char {
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard.retire_last_write();
    let link_bytes = Zeroizing::new(concealed.link.into_bytes());
    let copy_token = guard.next_link_copy_token.checked_add(1);
    let expires_at = guard.store.now() + Duration::from_secs(u64::from(LINK_RECOVERY_SECONDS));
    guard.concealed_link = copy_token.map(|token| CachedConcealLink {
        bytes: link_bytes.clone(),
        token,
        expires_at,
        target: sent,
    });
    if let Some(token) = copy_token {
        guard.next_link_copy_token = token;
    }
    let receipt = guard.pasteboard.write(
        link_bytes,
        ContentKind::Text,
        WriteOptions {
            nspasteboard_concealed: false,
        },
    );
    guard.last_write = Some(receipt);
    match sent {
        // The chip or page may have expired mid-flight; the link is on
        // the clipboard regardless, the record just has nowhere to land.
        Concealable::Chip(chip) => {
            guard
                .store
                .mark_chip_concealed(chip, concealed.receipt_id.clone());
            guard.store.record_sent(chip, DestinationClass::OneTimeLink);
        }
        Concealable::Page(sheet) => {
            guard
                .store
                .record_sheet_sent(sheet, DestinationClass::OneTimeLink);
        }
    }
    into_c_string(serde_json::json!({ "ok": true, "receipt_id": concealed.receipt_id, "copy_token": copy_token }).to_string())
}

/// A `{"ok": false, "error"}` result. Error strings are messages for
/// the inline failure state and never carry secret material.
fn conceal_error(message: &str) -> *mut c_char {
    into_c_string(serde_json::json!({ "ok": false, "error": message }).to_string())
}

// ---------------------------------------------------------------------------
// Sync sign-in (issue #98): account auth for the relay channel
// ---------------------------------------------------------------------------

/// A `{"ok": false, "reason"}` result: a machine token of
/// `account-auth.md` §5, never prose and never secret.
fn sync_refusal(reason: &str) -> *mut c_char {
    into_c_string(serde_json::json!({ "ok": false, "reason": reason }).to_string())
}

/// Configure sync's endpoints and client identity: JSON
/// `{"relay_url", "authorize_url", "token_url", "client_id"}`, all
/// required, the three URLs refused unless `https://`. Not persisted
/// core-side (the shell re-sends it at launch); configuring resumes the
/// persisted sign-in from its own Keychain account, and names the device
/// identity at rest, if any, as the writer of its name versions
/// (ADR-0058 point 5), minting none. Returns whether the configuration
/// was accepted.
///
/// # Safety
/// `handle` must be a valid handle; `json` a valid, NUL-terminated
/// UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_configure(
    handle: *mut CompanionHandle,
    json: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(config) = unsafe { cstr(json) }.and_then(sync_driver::SyncConfig::parse) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.sync.keeper = Some(sync_driver::keeper_for(&config, &*guard.credentials));
    let writer = pairing::stored_device_fingerprint(&*guard.credentials)
        .as_deref()
        .and_then(sync_driver::writer_of);
    if let Some(writer) = writer {
        guard.store.set_writer(writer);
    }
    guard.sync.config = Some(config);
    // A fresh configuration forgets the last one's faults.
    sync_driver::clear_fault(&mut guard);
    true
}

/// Sync's standing state for Settings: `{"configured", "signed_in",
/// "gate", "signin_pending", "attached", "epoch", "frame_present",
/// "enrolled", "pairing"}`, from existence checks and in-memory reads
/// only, so it never decrypts, wedges on the Keychain or waits on the
/// network. `"attached"` is the relay's last answer; the gate also asks
/// whether the next request can use it, so `{"attached": true, "gate":
/// "ready"}` is legal until a refresh lands. Switch on the gate. Free
/// with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_status_json(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    into_c_string(sync_driver::status_json(&guard).to_string())
}

/// Where the account gate stands, as one machine token (account-auth
/// decision background §5): `off`, `signed_out`, `signing_in`,
/// `refused`, `unreachable`, `ready` or `attached`, the status JSON's
/// `gate`. It says whether this client may attach and nothing about
/// content (relay decision background §3).
///
/// Null on a null handle or a poisoned lock: a gate that cannot be read
/// has not been passed, so null means may not attach. A status JSON
/// with no `gate` key is another core version and means no opinion.
/// Free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_gate(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    into_c_string(sync_driver::gate_of(&guard).token().to_owned())
}

/// Begin the sign-in ceremony (account-auth.md §1): bind the one-shot
/// loopback listener, mint the PKCE material, and return
/// `{"ok": true, "authorize_url"}` for the system browser, never a web
/// view; then [`companion_sync_signin_finish`]. `{"ok": false,
/// "reason"}`: `busy` while a ceremony waits or a finish is out on the
/// browser (a cancel is the way out), `not_configured`, `port` or
/// `no_entropy`. Free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_signin_begin(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    match sync_driver::signin_begin(&mut guard.sync) {
        Ok(authorize_url) => into_c_string(
            serde_json::json!({ "ok": true, "authorize_url": authorize_url }).to_string(),
        ),
        Err(reason) => sync_refusal(reason),
    }
}

/// Finish the sign-in ceremony: wait up to `patience_ms` for the
/// browser's redirect, redeem the code, exchange it, and persist the
/// refresh token in its own Keychain account. **Blocks for up to the
/// whole patience**: call from a background queue (account-auth.md §5
/// budgets five minutes). The core mutex is held only at the edges.
/// Returns `{"ok": true}` or `{"ok": false, "reason"}`: `abandoned` (no
/// redirect, or a cancel or sign-out while this call was out, even
/// after the redirect landed), `state_mismatch`, `no_code`,
/// `unreachable`, `refused`, `no_ceremony` (none begun, or one
/// cancelled before this call), `busy` (another finish is out; its
/// ceremony and the gate stand), `keychain`, `not_configured` (begun
/// while the engine held the sign-in). Every failure stores nothing on
/// this device; retry is a fresh begin. After a `not_configured` finish
/// the issuer still holds the redeemed refresh token until it expires.
/// Free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_signin_finish(
    handle: *mut CompanionHandle,
    patience_ms: u64,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    // Take the ceremony under the lock; the redirect wait runs off it,
    // so no summon waits minutes on the mutex.
    let staged = {
        let Ok(mut guard) = handle.inner.lock() else {
            return ptr::null_mut();
        };
        // A finish already out on the browser owns the ceremony and
        // the gate; a second call leaves both alone.
        if guard.sync.awaiting_redirect.is_some() {
            return sync_refusal("busy");
        }
        let transport = guard
            .sync
            .config
            .as_ref()
            .map(sync_driver::SyncConfig::transport);
        let staged = guard.sync.pending_signin.take().zip(transport);
        // Keeps the gate at `signing_in` for the trip, and lets a
        // cancel or sign-out reach the ceremony through its flag.
        if let Some((pending, _)) = staged.as_ref() {
            guard.sync.awaiting_redirect = Some(Arc::clone(&pending.abandoned));
        }
        staged
    };
    let Some((pending, transport)) = staged else {
        // Nothing to finish; never spelled as a refusal (account-auth
        // decision background §2).
        return sync_refusal("no_ceremony");
    };
    let abandoned = Arc::clone(&pending.abandoned);
    let grant =
        match sync_driver::signin_finish(pending, Duration::from_millis(patience_ms), &transport) {
            Ok(grant) => grant,
            Err(reason) => {
                if let Ok(mut guard) = handle.inner.lock() {
                    sync_driver::release_redirect(&mut guard.sync, &abandoned);
                }
                return sync_refusal(reason);
            }
        };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    sync_driver::release_redirect(&mut guard.sync, &abandoned);
    // The last read, under the lock that commits: a cancel or sign-out
    // during the exchange persists nothing.
    if abandoned.load(Ordering::Relaxed) {
        return sync_refusal("abandoned");
    }
    // Checked before the store: while an engine stands the keeper is
    // in its session and the grant has nowhere to go.
    if guard.sync.keeper.is_none() {
        return sync_refusal("not_configured");
    }
    // Persist first, absorb second, so a refused store signs nothing in.
    if !sync_driver::store_refresh(&*guard.credentials, &grant.refresh) {
        diag_fault!("the credential store refused the sync refresh token; sync stays signed out");
        return sync_refusal("keychain");
    }
    let Some(keeper) = guard.sync.keeper.as_mut() else {
        return sync_refusal("not_configured");
    };
    let _rotated = keeper.absorb(grant);
    // A grant retires every earlier refusal.
    sync_driver::clear_fault(&mut guard);
    into_c_string(serde_json::json!({ "ok": true }).to_string())
}

/// Give up on the sign-in ceremony, parked or out on the browser; the
/// finish reads the abandon flag at every wait and once more before it
/// persists. The gate stops saying `signing_in` at once; nothing is
/// deleted and no request is sent. True when there was a ceremony to
/// end.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_signin_cancel(handle: *mut CompanionHandle) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    sync_driver::abandon_signin(&mut guard.sync)
}

/// Sign sync out: drop the held tokens and delete the persisted refresh
/// token, exactly one Keychain account; the conceal token, content and
/// ledger keys, pairing accounts and the pad all stand (relay decision
/// background §3). A ceremony out on the browser ends with it. True
/// when the delete was accepted.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_signout(handle: *mut CompanionHandle) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    // A ceremony out on the browser ends with the sign-out.
    sync_driver::abandon_signin(&mut guard.sync);
    let _ = sync_driver::dissolve_engine(&mut guard);
    // The user's own sign-out is not a refusal: the gate reads `signed_out`.
    sync_driver::clear_fault(&mut guard);
    if let Some(config) = &guard.sync.config {
        guard.sync.keeper = Some(companion_sync::TokenKeeper::new(
            &config.token_url,
            &config.client_id,
            None,
        ));
    }
    sync_driver::clear_refresh(&*guard.credentials)
}

/// Enrol a page into the sync channel, or withdraw it; per page and off
/// by default (relay protocol §1). Enrolling defers its compaction to
/// the coordinated ceremony and starts its cursor at the beginning;
/// withdrawing performs any due ceremony on the spot. A page past its
/// deadline does not enrol (Law 0001, expiry row). `page` is the PAGE id.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_enrol_page(
    handle: *mut CompanionHandle,
    page: u64,
    enrolled: bool,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    sync_driver::enrol_page(&mut guard, SheetId::from_raw(page), enrolled)
}

/// Attach to the account's channel, building the engine on first use
/// (device identity, channel secret, key package; a joiner's secret
/// arrives by pairing). A re-attach mints a pending package unless one
/// already waits, which it resends (client protocol §4.3, §5.2).
/// **Blocks for the round-trips**: call from a background queue.
/// Returns `{"ok": true, "epoch", "frame_present", "peers"}` or
/// `{"ok": false, "reason"}`: `not_configured`, `signed_out`,
/// `keychain`, `unreachable`, `refused`, `busy` while another attach
/// is in flight, among others (`poisoned`, `not_attached`). Free with
/// [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_attach(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let answer = sync_driver::attach(handle);
    // Trace a refusal the shell may retry quietly; `unreachable` is in
    // the gate, `busy` is a flight, and the pump's attach is untraced.
    if let Some(reason) = answer.get("reason").and_then(serde_json::Value::as_str)
        && !matches!(reason, "unreachable" | "busy")
    {
        diag_fault!("companion-ffi: the shell's sync attach was refused: {reason}.");
    }
    into_c_string(answer.to_string())
}

/// Detach from the channel: dissolve the engine, keeping the sign-in,
/// and tell the relay, best effort (client protocol §4.8). **Blocks
/// briefly** for the one round-trip: call from a background queue.
/// True when there was an engine to dissolve.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_detach(handle: *mut CompanionHandle) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    sync_driver::detach(handle)
}

/// One turn of the engine loop, from a background queue while sync is
/// on: sweep, walk the ballot patience, publish, long-poll for up to
/// `wait_seconds` (held to 25), attach after a commit or when a package
/// is owed, publish a committed frame (client protocol §3). **Blocks
/// for the long-poll and the turn's other round trips**, each under its
/// own transport bound; the core mutex is held only between them. Returns `{"ok",
/// "reason"?, "events": [{"kind", "page"?, "page_id"?}, …], "state"}`:
/// `page` is the cross-device identity, `page_id` the local id (null
/// when no live page holds it here). Kinds: `applied`,
/// `countdown_moved`, `terminal`, `rejoin_required`,
/// `ceremony_proposed`, `ceremony_committed`, `ceremony_required`,
/// `epoch_conflict`, `unauthorized`, `unreachable`, `protocol`,
/// `signed_out`. States, never sentences. Free with
/// [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_pump(
    handle: *mut CompanionHandle,
    wait_seconds: u32,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    into_c_string(sync_driver::pump(handle, wait_seconds).to_string())
}

/// The device list for Settings: this device, every verified peer with
/// its attach time, and any attached but unverified stranger, labelled.
/// `{"devices": [{"fingerprint", "label", "this_device", "verified",
/// "paired_wall_ms", "attached_ms"}, …]}`. Free with
/// [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_devices_json(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    into_c_string(sync_driver::devices_json(&guard).to_string())
}

/// Revoke a paired peer by fingerprint: its record goes, so this
/// device seals nothing new to it and honours none of its markers. It
/// starts no ceremony, and the peer keeps the current key until a
/// ceremony that leaves it out commits (client protocol §7.9). True
/// when the fingerprint was recorded and the removal stored.
///
/// # Safety
/// `handle` must be a valid handle; `fingerprint` a valid,
/// NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_revoke_peer(
    handle: *mut CompanionHandle,
    fingerprint: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(fingerprint) = (unsafe { cstr(fingerprint) }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    pairing::revoke_peer(&*guard.credentials, fingerprint)
}

/// Begin inviting a new device into the channel (issue #97's
/// ceremony over §7's mailbox): this side holds the channel and will
/// grant it after the human comparison. Returns `{"ok": true}` or
/// `{"ok": false, "reason"}` (`not_attached`, `busy`, `keychain`,
/// `no_entropy`). Then poll. Free with [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_invite_begin(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    match sync_driver::invite_begin(&mut guard) {
        Ok(()) => into_c_string(serde_json::json!({ "ok": true }).to_string()),
        Err(reason) => sync_refusal(reason),
    }
}

/// Begin joining a channel from this new device: waits for an
/// inviter's ceremony. Same result shape as
/// [`companion_sync_invite_begin`]; then poll.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_join_begin(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    match sync_driver::join_begin(&mut guard) {
        Ok(()) => into_c_string(serde_json::json!({ "ok": true }).to_string()),
        Err(reason) => sync_refusal(reason),
    }
}

/// One mailbox round of the pairing ceremony: post what is queued,
/// fetch the tail, advance, and report. **Blocks for the round-trips**:
/// call from a background queue, on a timer while the sheet is open. Returns `{"stage", "sas"?, "reason"?}`:
/// `waiting` (keep polling), `sas` (show the six digits; call
/// confirm), `confirmed` (this human confirmed; waiting for the
/// peer), `done`, `failed`, `idle` (no ceremony). Free with
/// [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_pairing_poll(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    into_c_string(sync_driver::pairing_poll(handle).to_string())
}

/// The human's verdict on the short authentication string. A match
/// moves the ceremony forward; a mismatch drops it whole with nothing
/// stored on this device (relay decision background §3). Returns the stage as
/// [`companion_sync_pairing_poll`] does. Free with
/// [`companion_string_free`].
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_pairing_confirm(
    handle: *mut CompanionHandle,
    matched: bool,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    into_c_string(sync_driver::pairing_confirm(&mut guard, matched).to_string())
}

/// Forget the pairing ceremony in flight, at any stage, finished and
/// failed included. True when there was one.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sync_pairing_cancel(handle: *mut CompanionHandle) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.sync.pairing.take().is_some()
}

/// Wipe and free an owned string returned by this library. Null, a static
/// version string and a pointer this library never handed out are left alone.
///
/// # Safety
/// `s` must not be freed already, since its address may now belong to a newer
/// string; the caller must not read through `s` after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_string_free(s: *mut c_char) {
    unsafe { content_json::free(s) };
}

// ---- Helpers ----

/// A freshly sealed chip's non-secret face, as an owned C string.
fn chip_json(store: &SheetStore<SystemClock>, sheet: SheetId, chip: ChipId) -> *mut c_char {
    let Some(sealed) = store.sheet(sheet).and_then(|s| s.chip(chip)) else {
        return ptr::null_mut();
    };
    to_c_json(&chip_face(sealed))
}

/// A copy's or a cut's answer: [`copied_json`], `{"error": "tooLarge" |
/// "tooManyObjects", "limit"}` past a cap (Law 0001, copy row), else null.
fn copy_outcome_json(outcome: Result<Copied, CopyRefusal>) -> *mut c_char {
    let cap = match outcome {
        Ok(copied) => return copied_json(&copied),
        Err(CopyRefusal::Refused) => return ptr::null_mut(),
        Err(CopyRefusal::PastCap(cap)) => cap,
    };
    let error = match cap {
        EnvelopeCap::Length => "tooLarge",
        EnvelopeCap::References => "tooManyObjects",
    };
    let limit = cap.limit() as u64;
    into_c_string(serde_json::json!({ "error": error, "limit": limit }).to_string())
}

/// What a paste, a move or a clone placed: its run in UTF-16 units, a count
/// per resolution, `unreadable` when the public text was placed instead, and
/// `pages_expired`, the due pages its sweep took (Law 0001, expiry row).
fn placed_json(placed: Placed) -> *mut c_char {
    let value = serde_json::json!({
        "location_utf16": placed.location_u16,
        "length_utf16": placed.length_u16,
        "reattached": placed.reattached,
        "cloned": placed.cloned,
        "expired": placed.expired,
        "burned": placed.burned,
        "unavailable": placed.unavailable,
        "elsewhere": placed.elsewhere,
        "unreadable": placed.unreadable,
        "pages_expired": placed.pages_expired,
    });
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// A step's outcome as the header's `StepOutcome`, an owned C string.
pub(crate) fn step_outcome_json(outcome: StepOutcome) -> *mut c_char {
    let value = serde_json::json!({
        "applied": outcome.applied,
        "caretUTF16": outcome.caret_u16.map_or(-1, i64::from),
        "selectionLocationUTF16": outcome.selection_u16.map_or(-1, |value| i64::from(value.location_u16)),
        "selectionLengthUTF16": outcome.selection_u16.map_or(-1, |value| i64::from(value.length_u16)),
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

/// Parse the edit-batch JSON for [`companion_sheet_apply_ops`]; an unknown
/// key, extra field or out-of-range offset refuses the whole batch.
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

/// A JSON number as `u32`, refused rather than truncated.
fn parse_u32(value: &serde_json::Value) -> Option<u32> {
    u32::try_from(value.as_u64()?).ok()
}

/// `VoiceOver` words for the draining gauge (docs/spec/05).
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

/// Whether a raw id addresses an open file rather than a page; every
/// `companion_sheet_*` route refuses one (`companion_core::FILE_ID_TAG`).
fn is_file_id(sheet: u64) -> bool {
    FileId::is_tagged(sheet)
}

/// Move a Rust `String` into an owned C string pointer (caller frees).
fn into_c_string(s: String) -> *mut c_char {
    content_json::from_string(s)
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

    #[test]
    fn content_routes_preserve_escaped_text_and_sorted_json_shapes() {
        fn old_face(chip: &SealedChip) -> serde_json::Value {
            serde_json::json!({
                "available": true,
                "chip_id": chip.id().raw(),
                "kind": match chip.meta().unwrap() {
                    ChipMeta::Text { .. } => "text",
                    ChipMeta::Image { .. } => "image",
                },
                "excerpt": chip.excerpt(),
                "size_label": chip.size_label(),
                "concealed": chip.conceal().is_some(),
                "name": chip.name(),
                "has_note": chip.has_note(),
            })
        }

        unsafe {
            let handle = handle();
            let (page, chip) = page_with_a_chip(handle, "a sealed secret");
            let text = "café 🦀\0\n\"\\";
            let ops = cstring(&serde_json::json!([{"ins": {"at": 0, "text": text}}]).to_string());
            assert!(companion_sheet_apply_ops(handle, page, ops.as_ptr()));
            assert!(companion_chip_set_name(
                handle,
                chip,
                cstring("CAFE_KEY").as_ptr()
            ));
            assert!(note_ops(
                handle,
                chip,
                &serde_json::json!([{"ins": {"at": 0, "text": text}}]).to_string(),
                0
            ));
            assert_eq!(
                take_json(companion_chip_note_runs_json(handle, chip)),
                serde_json::json!([{"ink": text}]).to_string(),
            );
            let (expected_doc, expected_chip) = {
                let guard = (*handle).inner.lock().unwrap();
                let sheet = guard.store.sheet(SheetId::from_raw(page)).unwrap();
                let runs: Vec<_> = sheet
                    .segments()
                    .iter()
                    .filter_map(|segment| match segment {
                        Segment::Ink(ink) => Some(serde_json::json!({"ink": ink})),
                        Segment::Chip(id) => sheet
                            .chip(*id)
                            .map(|chip| serde_json::json!({"chip": old_face(chip)})),
                    })
                    .collect();
                (
                    serde_json::to_string(&runs).unwrap(),
                    old_face(sheet.chip(ChipId::from_raw(chip)).unwrap()),
                )
            };
            assert_eq!(
                take_json(companion_sheet_document_json(handle, page)),
                expected_doc
            );
            {
                let guard = (*handle).inner.lock().unwrap();
                assert_eq!(
                    take_json(chip_json(
                        &guard.store,
                        SheetId::from_raw(page),
                        ChipId::from_raw(chip)
                    )),
                    expected_chip.to_string()
                );
            }
            let copied = json_of(companion_sheet_copy_fragment(
                handle,
                page,
                0,
                u32::try_from(text.encode_utf16().count() + 5).unwrap(),
            ));
            assert!(copied["envelope"].is_string());
            assert!(copied["plain"].as_str().unwrap().starts_with(text));
            assert!(companion_chip_copy_out(handle, chip));
            let cut = companion_sheet_cut_fragment(
                handle,
                page,
                u32::try_from(text.encode_utf16().count() + 2).unwrap(),
                1,
            );
            assert!(!cut.is_null());
            companion_string_free(cut);
            assert_eq!(
                take_json(companion_active_cut_json(handle)),
                serde_json::json!({"page_id": page, "objects": [expected_chip]}).to_string()
            );
            {
                let guard = (*handle).inner.lock().unwrap();
                let expected: Vec<_> = guard
                    .store
                    .ledger()
                    .map(|record| {
                        serde_json::json!({
                            "event": match record.event() {
                                companion_core::LedgerEvent::Created => "created",
                                companion_core::LedgerEvent::Sealed => "sealed",
                                companion_core::LedgerEvent::Sent => "sent",
                                companion_core::LedgerEvent::Expired => "expired",
                                companion_core::LedgerEvent::Discarded => "discarded",
                            },
                            "item": record.item().to_string(),
                            "title": record.title(),
                            "at_ms": record.at_wall_ms(),
                            "created_at_ms": record.item_created_wall_ms(),
                            "size": record.size().as_str(),
                            "destination": record.destination().to_string(),
                        })
                    })
                    .collect();
                assert!(expected.iter().any(|row| {
                    row["title"]
                        .as_str()
                        .is_some_and(|title| title.contains("café"))
                }));
                drop(guard);
                assert_eq!(
                    take_json(companion_ledger_json(handle)),
                    serde_json::to_string(&expected).unwrap()
                );
            }
            companion_free(handle);
        }
    }

    #[test]
    fn tab_projection_matches_the_previous_json_bytes_for_each_label_source() {
        unsafe {
            let handle = handle();
            let (tab_id, page) = new_page(handle);
            for label_source in ["placeholder", "derived", "name"] {
                if label_source == "derived" {
                    let text = "café 🦀\0\n\"\\";
                    let ops =
                        cstring(&serde_json::json!([{"ins": {"at": 0, "text": text}}]).to_string());
                    assert!(companion_sheet_apply_ops(handle, page, ops.as_ptr()));
                } else if label_source == "name" {
                    assert!(companion_tab_set_title(
                        handle,
                        tab_id,
                        cstring("café 🦀 \"\\").as_ptr()
                    ));
                }
                let guard = (*handle).inner.lock().unwrap();
                let tab = guard.store.tabs().next().unwrap();
                assert_eq!(tab.label_source().as_str(), label_source);
                let page = tab.page();
                let now = guard.store.now();
                let offset = guard.store.local_offset_seconds();
                let wall = guard.store.wall_ms();
                let remaining = page.map_or(Duration::ZERO, |sheet| sheet.remaining(now));
                let expected = serde_json::json!({
                    "id": tab.id().raw(),
                    "uuid": tab.uuid().to_string(),
                    "has_page": page.is_some(),
                    "page_id": page.map(|sheet| sheet.id().raw()),
                    "page_uuid": page.map(|sheet| sheet.uuid().to_string()),
                    "title": tab.label(offset).as_str(),
                    "title_source": tab.label_source().as_str(),
                    "rung_code": ttl_to_code(tab.rung()),
                    "rung_label": tab.rung().to_string(),
                    "remaining_ms": u64::try_from(remaining.as_millis()).unwrap_or(u64::MAX),
                    "remaining_label": page.map(|sheet| sheet.remaining_label(now)).unwrap_or_default(),
                    "spoken_remaining": page.map_or_else(|| "this tab holds no page".to_string(), |_| spoken_remaining(remaining)),
                    "fraction_remaining": page.map_or(0.0, |sheet| f64::from(sheet.fraction_remaining(tab.rung(), now))),
                    "paused": page.is_some_and(|sheet| sheet.is_held(now)),
                    "hold_topped_up": page.is_some_and(|sheet| sheet.hold_topped_up(now)),
                    "hold_remaining_ms": page.map_or(0, |sheet| u64::try_from(sheet.hold_remaining(now).as_millis()).unwrap_or(u64::MAX)),
                    "chip_count": page.map_or(0, companion_core::Sheet::chip_count),
                    "last_hour": page.is_some_and(|sheet| sheet.last_hour(now)),
                    "page_has_content": page.is_some_and(companion_core::Sheet::has_content),
                    "page_day_offset": page.map(|sheet| sheet.local_day(offset) - companion_core::local_day(wall, offset)),
                    "page_created_ms": page.map(companion_core::Sheet::created_wall_ms),
                });
                assert_eq!(
                    take_json(to_c_json(&summary_json(tab, now, offset, wall))),
                    expected.to_string()
                );
            }
            companion_free(handle);
        }
    }

    #[test]
    fn version_exports_name_the_crates_they_report() {
        let ffi = unsafe { CStr::from_ptr(companion_ffi_version()) };
        let compatibility = unsafe { CStr::from_ptr(companion_version()) };
        let core = unsafe { CStr::from_ptr(companion_core_version()) };

        assert_eq!(ffi.to_str().unwrap(), env!("CARGO_PKG_VERSION"));
        assert_eq!(compatibility, ffi);
        assert_eq!(core.to_str().unwrap(), companion_core::VERSION);
    }

    /// A handle over the in-memory board, so tests never touch the real clipboard.
    fn handle() -> *mut CompanionHandle {
        handle_with(Arc::new(
            companion_credentials::InMemoryCredentialStore::default(),
        ))
    }

    /// Handles sharing `credentials` model launches against one keychain.
    fn handle_with(credentials: Arc<dyn CredentialStore>) -> *mut CompanionHandle {
        let companion = Companion {
            store: SheetStore::new(SystemClock),
            pasteboard: Board::Memory(MemoryPasteboard::new()),
            last_write: None,
            concealed_link: None,
            next_link_copy_token: 0,
            connection: None,
            credentials,
            wire: Wire::real(),
            sync: sync_driver::SyncState::default(),
            files: companion_core::FileStore::new(),
            last_open_refusal: None,
            last_save_refusal: None,
            drafts_notices: Vec::new(),
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

    fn seed_with_origin(handle: *mut CompanionHandle, text: &str, origin: &str) {
        let guard = unsafe { &*handle };
        let mut guard = guard.inner.lock().unwrap();
        guard.pasteboard.put_external(
            PasteboardContent::Text(text.to_string()),
            false,
            Some(Zeroizing::new(origin.to_owned())),
        );
    }

    unsafe fn take_json(p: *mut c_char) -> String {
        assert!(!p.is_null(), "expected a JSON string, got null");
        assert!(
            content_json::is_live(p),
            "an owned return bypassed content_json"
        );
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
        unsafe { companion_string_free(p) };
        s
    }

    fn cstring(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    #[test]
    fn language_detection_returns_an_owned_canonical_slug() {
        let source = b"def total(values):\n    return sum(value for value in values if value > 0)\n\nprint(total([1, -2, 3]))";
        unsafe {
            let result = companion_detect_source_language(source.as_ptr(), source.len());
            assert_eq!(take_json(result), "python");
        }
    }

    #[test]
    fn language_detection_handles_null_and_length_rules() {
        unsafe {
            assert!(companion_detect_source_language(ptr::null(), 0).is_null());
            assert!(companion_detect_source_language(ptr::null(), 1).is_null());

            let byte = b'x';
            assert!(
                companion_detect_source_language(&byte, FILE_SIZE_LIMIT + 1).is_null(),
                "oversize must return before constructing a slice"
            );
        }
    }

    #[test]
    fn language_detection_rejects_ineligible_text_bytes() {
        let with_nul = b"fn main() {\0 println!(\"no\"); }";
        let invalid_utf8 = [0xff; 20];
        unsafe {
            assert!(companion_detect_source_language(with_nul.as_ptr(), with_nul.len()).is_null());
            assert!(
                companion_detect_source_language(invalid_utf8.as_ptr(), invalid_utf8.len())
                    .is_null()
            );
        }
    }

    #[test]
    fn language_detection_contains_panics() {
        let result = detect_source_language_owned(b"enough ASCII evidence for inference", |_| {
            panic!("synthetic detector panic")
        });
        assert!(result.is_null());
    }

    #[test]
    fn language_detection_supports_concurrent_stateless_calls() {
        let threads = (0..4)
            .map(|_| {
                std::thread::spawn(|| {
                    let source = b"def total(values):\n    return sum(value for value in values if value > 0)\n\nprint(total([1, -2, 3]))";
                    unsafe {
                        let result =
                            companion_detect_source_language(source.as_ptr(), source.len());
                        assert_eq!(take_json(result), "python");
                    }
                })
            })
            .collect::<Vec<_>>();

        for thread in threads {
            thread.join().expect("detection thread panicked");
        }
    }

    const COMMONMARK: c_int = 0;
    const GFM: c_int = 1;

    /// `text` read through the seam with `objects` at every U+FFFC, under `limits`.
    fn parse_markdown(text: &str, dialect: c_int, limits: Limits) -> *mut c_char {
        let objects = fffc_offsets(text);
        unsafe {
            companion_markdown_parse_json(
                text.as_ptr().cast(),
                text.len(),
                objects.as_ptr(),
                objects.len(),
                dialect,
                limits.maximum_input_scalars,
                limits.maximum_depth,
                limits.maximum_table_cells,
            )
        }
    }

    /// The UTF-16 offset of every U+FFFC in `text`.
    fn fffc_offsets(text: &str) -> Vec<usize> {
        let mut offset = 0;
        let mut objects = Vec::new();
        for scalar in text.chars() {
            if scalar == '\u{FFFC}' {
                objects.push(offset);
            }
            offset += scalar.len_utf16();
        }
        objects
    }

    #[test]
    fn markdown_parse_returns_the_crates_document_json_for_each_dialect() {
        for text in [
            "",
            "# Title\n\nsee \u{FFFC} and *more*\r\n",
            "| a | b |\n| - | - |\n| \u{FFFC} | d |\n",
            "- [x] done\n- \u{FFFC}\n\n<b>\0raw</b>",
        ] {
            let objects = fffc_offsets(text);
            for (code, dialect) in [(COMMONMARK, Dialect::CommonMark), (GFM, Dialect::Gfm)] {
                let expected = serde_json::to_string(
                    &companion_markdown::parse_with_objects(
                        text,
                        &objects,
                        dialect,
                        Limits::default(),
                    )
                    .unwrap(),
                )
                .unwrap();
                let json = unsafe { take_json(parse_markdown(text, code, Limits::default())) };
                assert_eq!(json, expected, "{text:?} {dialect:?}");
                let value: serde_json::Value = serde_json::from_str(&json).unwrap();
                assert_eq!(value["atoms"].as_array().unwrap().len(), objects.len());
            }
        }
        let table = "| a |\n| - |\n";
        let read = |code| unsafe { take_json(parse_markdown(table, code, Limits::default())) };
        assert!(read(GFM).contains("\"table\""));
        assert!(!read(COMMONMARK).contains("\"table\""));
    }

    #[test]
    fn markdown_parse_preserves_raw_html_without_tag_filtering() {
        let text = "<script>alert(1)</script>\n\ntext <iframe>value</iframe>";
        for dialect in [COMMONMARK, GFM] {
            let json = unsafe { take_json(parse_markdown(text, dialect, Limits::default())) };
            let document: serde_json::Value = serde_json::from_str(&json).unwrap();
            assert_eq!(
                document["blocks"][0]["html"]["_0"][0]["text"]["_0"],
                "<script>alert(1)</script>\n"
            );
            assert_eq!(
                document["blocks"][1]["paragraph"]["_0"][1]["rawHTML"]["_0"][0]["text"]["_0"],
                "<iframe>"
            );
        }
    }

    #[test]
    fn markdown_image_addresses_keep_object_parts_while_links_use_stand_ins() {
        let input =
            "![alt \u{FFFC}](/i\u{FFFC} \"t \u{FFFC}\") [label](/l\u{FFFC} \"title \u{FFFC}\")";
        let text = |value: &str| serde_json::json!({"text": {"_0": value}});
        let object = |identity: &str| serde_json::json!({"object": {"_0": identity}});
        let expected = serde_json::json!([
            {"markdownImage": {
                "alt": [text("alt "), object("0")],
                "destination": [text("/i"), object("1")],
                "title": [text("t "), object("2")],
            }},
            text(" "),
            {"enterLink": {
                "destination": [text("/l\u{FFFC}")],
                "title": [text("title \u{FFFC}")],
            }},
            text("label"),
            {"leaveLink": {}},
            object("3"),
            object("4"),
        ]);
        for dialect in [COMMONMARK, GFM] {
            let json = unsafe { take_json(parse_markdown(input, dialect, Limits::default())) };
            let document: serde_json::Value = serde_json::from_str(&json).unwrap();
            assert_eq!(document["blocks"][0]["paragraph"]["_0"], expected);
        }
    }

    #[test]
    fn markdown_parse_caps_depth_and_survives_adversarial_input_on_a_small_stack() {
        let ceiling = companion_markdown::MAXIMUM_DEPTH;
        let pages = [
            ("> text".to_owned(), Some(1)),
            (format!("{}text", "> ".repeat(ceiling)), Some(ceiling)),
            (format!("{}text", "> ".repeat(ceiling + 1)), None),
            (format!("{}text", "> ".repeat(50_000)), None),
            (
                format!("{}a{}", "![".repeat(20_000), "](/u)".repeat(20_000)),
                None,
            ),
            (format!("{}text", "> - ".repeat(20_000)), None),
        ];
        for (page, quote_count) in pages {
            std::thread::Builder::new()
                .stack_size(512 * 1024)
                .spawn(move || {
                    for dialect in [COMMONMARK, GFM] {
                        for maximum_depth in [0, 1, ceiling, usize::MAX] {
                            let limits = Limits {
                                maximum_depth,
                                ..Limits::default()
                            };
                            let json = unsafe { take_json(parse_markdown(&page, dialect, limits)) };
                            if let Some(expected) =
                                quote_count.filter(|&depth| depth <= maximum_depth)
                            {
                                assert!(json.starts_with(r#"{"blocks":"#));
                                assert_eq!(json.matches(r#""quote":"#).count(), expected);
                            } else {
                                assert_eq!(json, r#"{"error":{"depthLimit":{}}}"#);
                            }
                        }
                    }
                })
                .unwrap()
                .join()
                .unwrap();
        }
    }

    #[test]
    fn markdown_parse_names_each_refusal_the_page_can_reach() {
        let refusal = |text: &str, limits| unsafe { take_json(parse_markdown(text, GFM, limits)) };
        let ample = Limits::default();
        for (text, limits, expected) in [
            (
                "123456",
                Limits {
                    maximum_input_scalars: 5,
                    ..ample
                },
                r#"{"error":{"inputLimit":{}}}"#,
            ),
            (
                "**a *b***",
                Limits {
                    maximum_depth: 1,
                    ..ample
                },
                r#"{"error":{"depthLimit":{}}}"#,
            ),
            (
                "|a|b|\n|-|-|",
                Limits {
                    maximum_table_cells: 1,
                    ..ample
                },
                r#"{"error":{"tableCellLimit":{}}}"#,
            ),
        ] {
            assert_eq!(refusal(text, limits), expected, "{text:?}");
        }
        let crowded = format!("\u{108000}{}", "\u{FFFC}".repeat(40_000));
        assert_eq!(
            refusal(&crowded, ample),
            r#"{"error":{"noPlaceholderWindow":{}}}"#
        );
        let at = [1_usize];
        let off = unsafe {
            companion_markdown_parse_json(c"ab".as_ptr(), 2, at.as_ptr(), 1, GFM, 5, 1, 1)
        };
        assert_eq!(
            unsafe { take_json(off) },
            r#"{"error":{"objectOffset":{}}}"#
        );

        // Four bytes a scalar at most: a longer text is refused before it is read.
        let unread = ptr::NonNull::<c_char>::dangling().as_ptr();
        let over =
            unsafe { companion_markdown_parse_json(unread, 21, ptr::null(), 0, GFM, 5, 1, 1) };
        assert_eq!(unsafe { take_json(over) }, r#"{"error":{"inputLimit":{}}}"#);
    }

    #[test]
    fn markdown_parse_distinguishes_unvalidated_limit_refusals_from_invalid_utf8() {
        let parse = |bytes: &[u8]| unsafe {
            companion_markdown_parse_json(
                bytes.as_ptr().cast(),
                bytes.len(),
                ptr::null(),
                0,
                GFM,
                2,
                8,
                100,
            )
        };
        let invalid = [0xff; 9];
        for len in [7, 8] {
            assert!(
                parse(&invalid[..len]).is_null(),
                "invalid UTF-8 at {len} bytes"
            );
        }
        let over = parse(&invalid);
        let refusal: serde_json::Value = serde_json::from_str(&unsafe { take_json(over) }).unwrap();
        assert_eq!(refusal, serde_json::json!({"error": {"inputLimit": {}}}));

        let boundary = "🦀🦀";
        assert_eq!(boundary.len(), 8);
        let parsed = parse(boundary.as_bytes());
        let document: serde_json::Value =
            serde_json::from_str(&unsafe { take_json(parsed) }).unwrap();
        assert_eq!(
            document["blocks"][0]["paragraph"]["_0"],
            serde_json::json!([
                {"text": {"_0": boundary}},
            ])
        );
        assert!(document.get("error").is_none());
    }

    #[test]
    fn synthetic_markdown_refusals_keep_their_json_shape() {
        for (error, expected) in [
            (
                ParseError::ParserFailure,
                r#"{"error":{"parserFailure":{}}}"#,
            ),
            (
                ParseError::DuplicateObject("3".into()),
                r#"{"error":{"duplicateObject":{"_0":"3"}}}"#,
            ),
        ] {
            let json = unsafe { take_json(content_json::markdown_json(Err(error))) };
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn markdown_parse_keeps_a_definition_object_before_repeated_reference_uses() {
        let text = "[r]: /u\u{FFFC}\n| a |\n| - |\n\n[x][r] [y][r]";
        let json = unsafe { take_json(parse_markdown(text, COMMONMARK, Limits::default())) };
        let document: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            document,
            serde_json::json!({
                "atoms": [{"identity": "0", "offset": 7}],
                "blocks": [
                    {"objects": {"_0": ["0"]}},
                    {"paragraph": {"_0": [
                        {"text": {"_0": "| a |"}}, {"softBreak": {}},
                        {"text": {"_0": "| - |"}},
                    ]}},
                    {"paragraph": {"_0": [
                        {"enterLink": {"destination": [{"text": {"_0": "/u\u{FFFC}"}}], "title": []}},
                        {"text": {"_0": "x"}}, {"leaveLink": {}}, {"text": {"_0": " "}},
                        {"enterLink": {"destination": [{"text": {"_0": "/u\u{FFFC}"}}], "title": []}},
                        {"text": {"_0": "y"}}, {"leaveLink": {}},
                    ]}},
                ],
            })
        );
    }

    #[test]
    fn markdown_parse_requires_placeholders_at_declared_object_offsets() {
        let offsets = [2_usize];
        for dialect in [COMMONMARK, GFM] {
            let parse = |input: &str| unsafe {
                take_json(companion_markdown_parse_json(
                    input.as_ptr().cast(),
                    input.len(),
                    offsets.as_ptr(),
                    offsets.len(),
                    dialect,
                    100,
                    8,
                    100,
                ))
            };
            let document: serde_json::Value = serde_json::from_str(&parse("a \u{FFFC}")).unwrap();
            assert_eq!(
                document["atoms"],
                serde_json::json!([{"identity": "0", "offset": 2}])
            );
            assert_eq!(
                document["blocks"][0]["paragraph"]["_0"],
                serde_json::json!([{"text": {"_0": "a "}}, {"object": {"_0": "0"}}])
            );
            for input in ["a resolved value", "a 🦀"] {
                let refusal: serde_json::Value = serde_json::from_str(&parse(input)).unwrap();
                assert_eq!(refusal, serde_json::json!({"error": {"objectOffset": {}}}));
            }
        }
    }

    #[test]
    fn markdown_parse_refuses_more_objects_than_the_placeholder_plane_can_fit() {
        let text = "\u{FFFC}".repeat(65_535);
        for dialect in [COMMONMARK, GFM] {
            let json = unsafe { take_json(parse_markdown(&text, dialect, Limits::default())) };
            assert_eq!(json, r#"{"error":{"noPlaceholderWindow":{}}}"#);
        }
    }

    #[test]
    fn markdown_parse_refuses_bad_arguments_with_null() {
        let text = "a \u{FFFC}";
        let at = [2_usize];
        let parse = |text: *const c_char, len, objects: *const usize, count, dialect| unsafe {
            companion_markdown_parse_json(text, len, objects, count, dialect, 100, 8, 100)
        };
        let ok = text.as_ptr().cast::<c_char>();
        assert!(unsafe { take_json(parse(ok, text.len(), at.as_ptr(), 1, GFM)) }.contains("atoms"));

        assert!(parse(ptr::null(), 0, ptr::null(), 0, GFM).is_null());
        assert!(parse(ptr::null(), 1, ptr::null(), 0, GFM).is_null());
        let not_utf8 = [b'a', 0xff, b'b'];
        assert!(parse(not_utf8.as_ptr().cast(), 3, ptr::null(), 0, GFM).is_null());
        for dialect in [-1, 2, c_int::MAX] {
            assert!(parse(ok, text.len(), at.as_ptr(), 1, dialect).is_null());
        }
        assert!(parse(ok, text.len(), ptr::null(), 1, GFM).is_null());
        let misaligned = at.as_ptr().cast::<u8>().wrapping_add(1).cast::<usize>();
        assert!(parse(ok, text.len(), misaligned, 1, GFM).is_null());
        let none = unsafe { take_json(parse(ok, text.len(), misaligned, 0, GFM)) };
        assert!(none.contains(r#""atoms":[]"#), "no objects reads none");

        // Lengths no allocation can have are refused before either pointer is read.
        let unread = ptr::NonNull::<usize>::dangling().as_ptr();
        let unbounded = |len, count| unsafe {
            companion_markdown_parse_json(ok, len, unread, count, GFM, usize::MAX, 8, 100)
        };
        assert!(unbounded(usize::MAX, 0).is_null());
        assert!(unbounded(text.len(), usize::MAX / 2).is_null());
    }

    #[test]
    fn markdown_parse_contains_panics() {
        assert!(markdown_parse_owned(|| panic!("synthetic parser panic")).is_null());
    }

    /// A fresh tab and its page, as `(tab, page)`.
    unsafe fn new_page(handle: *mut CompanionHandle) -> (u64, u64) {
        let tab = unsafe { companion_tab_new(handle) };
        assert_ne!(tab, 0, "the store refused a tab");
        (
            tab,
            unsafe { page_of(handle, tab) }.expect("born holding one"),
        )
    }

    /// Age staged pages by `gap_ms` through snapshot and restore; ids are re-minted.
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

    #[test]
    fn tab_summary_uuid_survives_reorder_and_dense_restore_ids() {
        unsafe {
            let handle = handle();
            let first = companion_tab_new(handle);
            let second = companion_tab_new(handle);
            let third = companion_tab_new(handle);
            let before = strip(handle);
            let second_uuid = before[1]["uuid"].clone();
            let third_uuid = before[2]["uuid"].clone();
            assert!(second_uuid.as_str().is_some_and(|uuid| uuid.len() == 36));
            assert!(companion_tab_close(handle, first));
            assert!(companion_tab_move(handle, third, 0));
            age_by(handle, 0);
            let restored = strip(handle);
            assert_eq!(restored[0]["id"], 1);
            assert_eq!(restored[0]["uuid"], third_uuid);
            assert_eq!(restored[1]["id"], 2);
            assert_eq!(restored[1]["uuid"], second_uuid);
            assert_ne!(second, 0);
            companion_free(handle);
        }
    }

    #[test]
    fn page_summary_uuid_matches_the_sheet_not_the_tab() {
        unsafe {
            let handle = handle();
            let (_tab, page) = new_page(handle);
            let summary = &strip(handle)[0];
            let page_uuid = summary["page_uuid"].as_str().unwrap();
            assert_eq!(page_uuid.len(), 36);
            assert_ne!(summary["page_uuid"], summary["uuid"]);
            {
                let guard = (*handle).inner.lock().unwrap();
                let sheet = guard.store.sheet(SheetId::from_raw(page)).unwrap();
                assert_eq!(page_uuid, sheet.uuid().to_string());
            }
            companion_free(handle);
        }
    }

    #[test]
    fn page_summary_uuid_survives_reorder_and_dense_restore_ids() {
        unsafe {
            let handle = handle();
            let first = companion_tab_new(handle);
            let second = companion_tab_new(handle);
            let third = companion_tab_new(handle);
            let before = strip(handle);
            let second_uuid = before[1]["page_uuid"].as_str().unwrap().to_string();
            let third_uuid = before[2]["page_uuid"].as_str().unwrap().to_string();
            assert_ne!(second_uuid, third_uuid);
            assert!(companion_tab_close(handle, first));
            assert!(companion_tab_move(handle, third, 0));
            age_by(handle, 0);
            let restored = strip(handle);
            assert_eq!(restored[0]["page_id"], 1);
            assert_ne!(restored[0]["page_id"], before[2]["page_id"]);
            assert_eq!(restored[0]["page_uuid"], third_uuid);
            assert_eq!(restored[1]["page_id"], 2);
            assert_eq!(restored[1]["page_uuid"], second_uuid);
            assert_ne!(second, 0);
            companion_free(handle);
        }
    }

    #[test]
    fn page_summary_uuid_is_null_when_empty_and_changes_for_a_replacement() {
        unsafe {
            let handle = handle();
            let (tab, page) = new_page(handle);
            let before = strip(handle);
            let page_uuid = before[0]["page_uuid"].as_str().unwrap().to_string();
            let tab_uuid = before[0]["uuid"].as_str().unwrap().to_string();
            assert!(companion_page_discard(handle, page));
            let empty = strip(handle);
            assert_eq!(empty[0]["id"], tab);
            assert_eq!(empty[0]["uuid"], tab_uuid);
            assert!(empty[0].get("page_uuid").unwrap().is_null());
            let replacement = companion_tab_open_page(handle, tab);
            assert_ne!(replacement, 0);
            let after = strip(handle);
            assert_eq!(after[0]["id"], tab);
            assert_eq!(after[0]["uuid"], tab_uuid);
            assert_eq!(after[0]["page_id"], replacement);
            let replacement_uuid = after[0]["page_uuid"].as_str().unwrap();
            assert_ne!(replacement_uuid, page_uuid);
            assert_ne!(replacement_uuid, tab_uuid);
            companion_free(handle);
        }
    }

    /// The page a tab holds, or `None` for an empty slot.
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

    /// macOS only: the drag board exists only there.
    #[cfg(target_os = "macos")]
    #[test]
    fn drop_to_seal_reads_the_drag_board_core_side() {
        use companion_pasteboard::SystemPasteboard;
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            assert_ne!(sheet, 0);

            let mut drag = SystemPasteboard::drag();
            let receipt = drag.write(
                Zeroizing::new(Vec::new()),
                ContentKind::Text,
                WriteOptions {
                    nspasteboard_concealed: false,
                },
            );
            drag.clear_if_unchanged(receipt);
            assert!(companion_sheet_seal_from_drag(handle, sheet, 0, 0).is_null());

            let dragged = format!("xoxb-{}", "n0ts3cr3t".repeat(3));
            drag.write(
                Zeroizing::new(dragged.clone().into_bytes()),
                ContentKind::Text,
                WriteOptions {
                    nspasteboard_concealed: false,
                },
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

    #[test]
    fn persist_round_trips_over_the_seam() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        // Own directory: the key's file half is minted beside the state file.
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
            assert!(companion_chip_copy_out(second, chip));
            companion_free(second);

            // A handle over a different keychain cannot open the file.
            let stranger = handle();
            assert!(!companion_persist_restore(stranger, c_path.as_ptr()));
            companion_free(stranger);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

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

    #[cfg(feature = "test-util")]
    #[test]
    fn the_memory_pasteboard_seam_keeps_an_ephemeral_handles_copies_in_process() {
        let tag = cstring("memory-pasteboard-seam");
        unsafe {
            assert!(!companion_test_memory_pasteboard(ptr::null_mut()));
            let handle = companion_new_ephemeral(tag.as_ptr());
            assert!(companion_test_memory_pasteboard(handle));
            {
                let guard = (*handle).inner.lock().unwrap();
                assert!(matches!(guard.pasteboard, Board::Memory(_)));
            }
            let (_sheet, chip) = sealed_chip(handle, "hunter2");
            assert!(companion_chip_set_name(
                handle,
                chip,
                cstring("API_KEY").as_ptr()
            ));
            assert!(companion_chip_copy_name_value(handle, chip));
            assert_eq!(board_text(handle).as_deref(), Some("API_KEY=hunter2"));
            assert!(companion_clear_clipboard_if_ours(handle));
            assert!(board_text(handle).is_none());
            companion_free(handle);
        }
    }

    #[cfg(feature = "test-util")]
    #[test]
    fn a_pages_object_character_comes_out_and_every_route_fails_closed() {
        let tag = cstring("object-character-seam");
        let text = cstring("x\u{FFFC}y");
        unsafe {
            let handle = companion_new_ephemeral(tag.as_ptr());
            let (sheet, _chip) = sealed_chip(handle, "hunter2");
            assert!(!companion_test_ink_below_the_guard(
                ptr::null_mut(),
                sheet,
                0,
                text.as_ptr()
            ));
            assert!(!companion_test_ink_below_the_guard(
                handle,
                sheet,
                0,
                ptr::null()
            ));
            assert!(companion_test_ink_below_the_guard(
                handle,
                sheet,
                0,
                text.as_ptr()
            ));
            let document = take_json(companion_sheet_document_json(handle, sheet));
            assert!(document.contains('\u{FFFC}'), "the seam wrote no U+FFFC");

            assert!(!companion_sheet_take_out_object_characters(
                ptr::null_mut(),
                sheet
            ));
            assert!(!companion_sheet_take_out_object_characters(
                handle,
                companion_core::FILE_ID_TAG | sheet
            ));
            assert!(companion_sheet_take_out_object_characters(handle, sheet));
            let document = take_json(companion_sheet_document_json(handle, sheet));
            assert!(!document.contains('\u{FFFC}'));
            assert!(document.contains("\"chip\""), "the object went with it");
            assert!(!companion_sheet_take_out_object_characters(handle, sheet));
            companion_free(handle);
        }
    }

    #[cfg(feature = "test-util")]
    #[test]
    fn a_record_with_no_value_crosses_as_a_face_alone_and_every_value_route_refuses_it() {
        const MARKER: &str = "ghp_payload-marker-5c1e";
        let handle = handle();
        unsafe {
            assert!(companion_connection_configure(
                handle,
                cstring(r#"{"server_url": "https://eu.onetimesecret.com"}"#).as_ptr()
            ));
            let (sheet, local) = page_with_a_chip(handle, MARKER);
            let image = cstring("image");
            let peer =
                companion_test_stand_peer_record(handle, sheet, 0, image.as_ptr(), ptr::null(), 0);
            assert_ne!(peer, 0);
            assert!(companion_chip_set_name(
                handle,
                peer,
                cstring("PEER_KEY").as_ptr()
            ));

            let runs = json_of(companion_sheet_document_json(handle, sheet));
            let faces: Vec<&serde_json::Value> = runs
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|run| run.get("chip"))
                .collect();
            let face = faces.iter().find(|face| face["chip_id"] == peer).unwrap();
            assert_eq!(face["available"], false);
            assert_eq!(face["kind"], "image");
            assert_eq!(face["excerpt"], "");
            assert_eq!(face["size_label"], "");
            assert_eq!(face["concealed"], false);
            assert_eq!(face["name"], "PEER_KEY");
            let held = faces.iter().find(|face| face["chip_id"] == local).unwrap();
            assert_eq!(held["available"], true);
            assert!(
                held.to_string().contains("ghp_"),
                "the control: the local face shows its excerpt"
            );
            assert!(!face.to_string().contains("ghp_"), "{face}");

            let copied = json_of(companion_sheet_copy_fragment(handle, sheet, 0, 1));
            assert!(!copied.to_string().contains("ghp_"), "{copied}");
            assert_eq!(copied["plain"], "[sealed content \u{b7} unavailable]");

            assert!(!companion_chip_copy_out(handle, peer));
            assert!(!companion_chip_copy_name_value(handle, peer));
            assert!(!companion_chip_delete(handle, peer));
            let refusal = json_of(companion_chip_conceal(handle, peer, ptr::null()));
            assert_eq!(refusal["error"], "this chip's value is on another device");
            let refusal = json_of(companion_sheet_conceal(handle, sheet, ptr::null()));
            assert_eq!(
                refusal["error"],
                PayloadError::ValueElsewhere.to_string().as_str()
            );
            assert!(
                companion_test_wire_last_json(handle).is_null(),
                "nothing was sent"
            );
            {
                let guard = (*handle).inner.lock().unwrap();
                assert!(guard.last_write.is_none(), "nothing reached the board");
                assert!(
                    guard
                        .store
                        .ledger()
                        .all(|record| record.event() != companion_core::LedgerEvent::Sent),
                    "nothing was recorded as sent"
                );
            }
            companion_free(handle);
        }
    }

    #[cfg(feature = "test-util")]
    #[test]
    fn the_peer_record_seam_stands_a_face_with_no_value_and_refuses_off_a_point() {
        let handle = handle();
        let (text, small) = (cstring("text"), cstring("small"));
        let (file, gibberish) = (cstring("file"), cstring("enormous"));
        unsafe {
            let (_tab, sheet) = new_page(handle);
            let stand = |handle, sheet, at, kind: &CString, size: &CString| {
                companion_test_stand_peer_record(handle, sheet, at, kind.as_ptr(), size.as_ptr(), 0)
            };
            assert_eq!(stand(ptr::null_mut(), sheet, 0, &text, &small), 0);
            assert_eq!(
                stand(
                    handle,
                    companion_core::FILE_ID_TAG | sheet,
                    0,
                    &text,
                    &small
                ),
                0
            );
            assert_eq!(
                stand(handle, sheet + 4_242, 0, &text, &small),
                0,
                "an unknown page"
            );
            assert_eq!(
                stand(handle, sheet, 1, &text, &small),
                0,
                "past the body's end"
            );
            assert_eq!(
                stand(handle, sheet, 0, &file, &small),
                0,
                "a kind no face has"
            );
            assert_eq!(
                stand(handle, sheet, 0, &text, &gibberish),
                0,
                "not a size class"
            );
            let document = take_json(companion_sheet_document_json(handle, sheet));
            assert!(!document.contains("\"chip\""), "a refusal stood {document}");

            let peer = stand(handle, sheet, 0, &text, &small);
            assert_ne!(peer, 0);
            let unknown =
                companion_test_stand_peer_record(handle, sheet, 1, ptr::null(), ptr::null(), 0);
            assert_ne!(unknown, 0);
            let runs = json_of(companion_sheet_document_json(handle, sheet));
            let faces: Vec<&serde_json::Value> = runs
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|run| run.get("chip"))
                .collect();
            assert_eq!(faces.len(), 2, "{runs}");
            assert_eq!(faces[0]["chip_id"], peer);
            assert_eq!(faces[0]["available"], false);
            assert_eq!(faces[0]["kind"], "text");
            assert_eq!(faces[0]["size_label"], "small");
            assert_eq!(faces[1]["chip_id"], unknown);
            assert_eq!(faces[1]["available"], false);
            assert_eq!(faces[1]["kind"], "unknown");
            assert_eq!(faces[1]["size_label"], "");
            companion_free(handle);
        }
    }

    #[cfg(feature = "test-util")]
    #[test]
    fn a_page_another_page_s_edit_or_burn_restated_is_drained_once_over_the_seam() {
        const MARKER: &str = "ghp_payload-marker-7a2d";
        let restated = |handle| unsafe { json_of(companion_take_restated_pages_json(handle)) };
        assert!(unsafe { companion_take_restated_pages_json(ptr::null_mut()) }.is_null());
        let handle = handle();
        unsafe {
            for burn in [false, true] {
                let (home, chip) = page_with_a_chip(handle, MARKER);
                let (_, away) = new_page(handle);
                assert_eq!(
                    companion_test_stand_peer_record(
                        handle,
                        away,
                        0,
                        ptr::null(),
                        ptr::null(),
                        4_242
                    ),
                    0,
                    "an identity that stands nowhere"
                );
                let peer = companion_test_stand_peer_record(
                    handle,
                    away,
                    0,
                    ptr::null(),
                    ptr::null(),
                    chip,
                );
                assert_ne!(peer, 0);
                assert_eq!(
                    companion_test_stand_peer_record(
                        handle,
                        away,
                        0,
                        ptr::null(),
                        ptr::null(),
                        chip
                    ),
                    0,
                    "one record per identity on a page"
                );
                assert_eq!(restated(handle), serde_json::json!([]));

                if burn {
                    assert!(companion_chip_delete(handle, chip));
                } else {
                    let backspace = cstring(r#"[{"del": {"at": 2, "len": 1}}]"#);
                    assert!(companion_sheet_apply_ops(handle, home, backspace.as_ptr()));
                }
                assert_eq!(restated(handle), serde_json::json!([away]), "{burn}");
                assert_eq!(restated(handle), serde_json::json!([]));
                let runs = json_of(companion_sheet_document_json(handle, away));
                let faces: Vec<&serde_json::Value> = runs
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter_map(|run| run.get("chip"))
                    .collect();
                if burn {
                    assert!(faces.is_empty(), "the burn took out its standing {runs}");
                } else {
                    assert_eq!(faces.len(), 1, "{runs}");
                    assert_eq!(faces[0]["chip_id"], peer, "the id the page showed");
                    assert_eq!(faces[0]["available"], true);
                }
            }
            companion_free(handle);
        }
    }

    #[cfg(feature = "test-util")]
    #[test]
    fn wire_stub_records_the_conceal_without_its_secret() {
        const OK_BODY: &str = r#"{"record":{
            "receipt":{"identifier":"rcpt_9f2"},
            "secret":{"identifier":"scrt_1","key":"abcdef"},
            "share_domain":null}}"#;
        let handle = handle();
        unsafe {
            assert!(companion_test_wire_last_json(handle).is_null());
            assert!(companion_connection_configure(
                handle,
                cstring(r#"{"server_url": "https://eu.onetimesecret.com"}"#).as_ptr()
            ));
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
            assert!(companion_test_wire_stub(
                handle,
                200,
                cstring(OK_BODY).as_ptr()
            ));
            assert!(
                companion_test_wire_last_json(handle).is_null(),
                "nothing sent yet"
            );

            // Options naming nothing: the link's own seven days.
            let result = take_json(companion_chip_conceal(handle, chip_id, ptr::null()));
            let v: serde_json::Value = serde_json::from_str(&result).unwrap();
            assert_eq!(v["ok"], true);
            assert_eq!(v["receipt_id"], "rcpt_9f2");
            let record = take_json(companion_test_wire_last_json(handle));
            assert!(
                !record.contains("hunter2"),
                "the payload never crosses: {record}"
            );
            let r: serde_json::Value = serde_json::from_str(&record).unwrap();
            assert_eq!(r["method"], "POST");
            assert!(
                r["url"]
                    .as_str()
                    .unwrap()
                    .ends_with("/api/v3/guest/secret/conceal")
            );
            assert_eq!(r["authorized"], false);
            assert_eq!(r["ttl"], 604_800);
            assert_eq!(r["share_domain"], "eu.onetimesecret.com");
            assert_eq!(r["has_passphrase"], false);
            assert!(r["recipient"].is_null());

            let result = take_json(companion_chip_conceal(
                handle,
                chip_id,
                cstring(r#"{"ttl_secs": 3600, "passphrase": "swordfish"}"#).as_ptr(),
            ));
            assert!(result.contains(r#""ok":true"#));
            let record = take_json(companion_test_wire_last_json(handle));
            assert!(
                !record.contains("swordfish"),
                "the passphrase never crosses: {record}"
            );
            let r: serde_json::Value = serde_json::from_str(&record).unwrap();
            assert_eq!(r["ttl"], 3600);
            assert_eq!(r["has_passphrase"], true);

            // Status zero is an outage.
            assert!(companion_test_wire_stub(handle, 0, ptr::null()));
            let result = take_json(companion_chip_conceal(handle, chip_id, ptr::null()));
            let v: serde_json::Value = serde_json::from_str(&result).unwrap();
            assert_eq!(v["ok"], false);
            assert!(
                v["error"]
                    .as_str()
                    .unwrap()
                    .contains("could not reach the server")
            );
            let record = take_json(companion_test_wire_last_json(handle));
            let r: serde_json::Value = serde_json::from_str(&record).unwrap();
            assert_eq!(r["ttl"], 604_800);

            // The Settings test rides the same wire.
            assert!(companion_test_wire_stub(
                handle,
                200,
                cstring("{}").as_ptr()
            ));
            let result = take_json(companion_connection_test(handle));
            assert!(result.contains(r#""ok":true"#));
            let record = take_json(companion_test_wire_last_json(handle));
            let r: serde_json::Value = serde_json::from_str(&record).unwrap();
            assert_eq!(r["method"], "GET");
            assert!(r["url"].as_str().unwrap().ends_with("/api/v3/status"));
            assert!(r["ttl"].is_null());
            companion_free(handle);
        }
    }

    #[test]
    fn sealed_bytes_never_appear_in_any_output() {
        // Assembled at runtime so the secret scanner never sees the pattern.
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

            let sheets = take_json(companion_tabs_json(handle));
            assert!(!sheets.contains("n0ts3cr3t"), "{sheets}");
            assert!(sheets.contains("\"chip_count\":2"), "{sheets}");

            // A named chip's face carries the name and still not the bytes.
            let chip_id = serde_json::from_str::<serde_json::Value>(&chip).unwrap()["chip_id"]
                .as_u64()
                .unwrap();
            assert!(companion_chip_set_name(
                handle,
                chip_id,
                cstring("GH_TOKEN").as_ptr()
            ));
            let doc = take_json(companion_sheet_document_json(handle, sheet));
            assert!(doc.contains("\"name\":\"GH_TOKEN\""), "{doc}");
            assert!(!doc.contains("n0ts3cr3t"), "{doc}");

            // The fragment, its public text and the slot name objects, never bytes.
            let copied = take_json(companion_sheet_copy_fragment(handle, sheet, 0, 2));
            assert!(
                copied.contains("GH_TOKEN"),
                "the name rides along: {copied}"
            );
            assert!(!copied.contains("n0ts3cr3t"), "{copied}");
            let cut = take_json(companion_sheet_cut_fragment(handle, sheet, 0, 2));
            assert!(!cut.contains("n0ts3cr3t"), "{cut}");
            let slot = take_json(companion_active_cut_json(handle));
            assert!(!slot.contains("n0ts3cr3t"), "{slot}");

            // After death the ledger holds metadata only.
            assert!(companion_tab_close(handle, tab));
            let ledger = take_json(companion_ledger_json(handle));
            assert!(!ledger.contains("n0ts3cr3t"), "{ledger}");
            assert!(!ledger.contains("tombstone"), "{ledger}");
            assert!(!ledger.contains("excerpt"), "{ledger}");
            assert!(!ledger.contains("GH_TOKEN"), "{ledger}");

            companion_free(handle);
        }
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    /// Every run of `token` four characters or longer.
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

            // The plaintext content snapshot carries the origin.
            {
                let guard = (*handle).inner.lock().unwrap();
                let snapshot = guard.store.snapshot(0);
                assert!(
                    contains(&snapshot, origin.as_bytes()),
                    "the origin message must ride the content snapshot"
                );
                assert!(!contains(&guard.store.ledger_snapshot(), b"example.test"));
            }

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
            // Two ops, two blocks: a single op would be a paste, which is one block.
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

            // A paste is one op and one block.
            let paste = cstring(r#"[{"ins": {"at": 10, "text": "\nfrom\nelsewhere"}}]"#);
            assert!(companion_sheet_apply_ops(handle, sheet, paste.as_ptr()));
            let blocks: serde_json::Value =
                serde_json::from_str(&take_json(companion_sheet_blocks_json(handle, sheet)))
                    .unwrap();
            let blocks = blocks.as_array().unwrap();
            assert_eq!(blocks.len(), 2, "the paste joined the block it landed in");
            assert_eq!(blocks[1]["paragraphs"].as_u64(), Some(3));

            assert!(companion_sheet_meta_json(handle, 424242).is_null());
            assert!(companion_sheet_blocks_json(handle, 424242).is_null());
            companion_free(handle);
        }
    }

    #[test]
    fn sealed_outputs_have_no_detection_and_no_reveal_surface() {
        // Detection is a separate explicit call (ADR-0029).
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
            // The size bucket, never a count (D-29).
            assert!(chip.contains("\"size_label\":\"tiny\""), "{chip}");
            companion_free(handle);
        }
    }

    #[test]
    fn sealed_paste_drains_the_board_in_the_same_operation() {
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
    fn a_seal_over_a_range_the_page_does_not_have_takes_nothing_from_the_board() {
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            let chip = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("already sealed").as_ptr(),
                0,
                0,
            ));
            let chip_id = serde_json::from_str::<serde_json::Value>(&chip).unwrap()["chip_id"]
                .as_u64()
                .unwrap();
            let runs = format!(r#"[{{"ink": "ab"}}, {{"chip": {chip_id}}}]"#);
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(&runs).as_ptr()
            ));
            let before = take_json(companion_sheet_document_json(handle, sheet));
            seed(handle, "still theirs");
            // Past the end, then over the standing chip's sentinel.
            for (at, len) in [(0, 99), (1, 2)] {
                let mut cleared = true;
                let refused =
                    companion_sheet_seal_from_pasteboard(handle, sheet, at, len, &raw mut cleared);
                assert!(refused.is_null(), "sealed over {at}+{len}");
                assert!(!cleared);
                let guard = (*handle).inner.lock().unwrap();
                let item = guard.pasteboard.read().expect("the board was emptied");
                assert!(
                    matches!(item.content, PasteboardContent::Text(ref t) if t == "still theirs")
                );
            }
            assert_eq!(
                take_json(companion_sheet_document_json(handle, sheet)),
                before
            );
            companion_free(handle);
        }
    }

    #[test]
    fn the_settings_read_answers_has_token_without_reading_the_token() {
        #[derive(Default)]
        struct CountsReads {
            inner: Arc<companion_credentials::InMemoryCredentialStore>,
            loads: Arc<std::sync::atomic::AtomicUsize>,
        }
        impl CredentialStore for CountsReads {
            fn store(
                &self,
                a: &str,
                s: &[u8],
            ) -> Result<(), companion_credentials::CredentialError> {
                self.inner.store(a, s)
            }
            fn load(
                &self,
                a: &str,
            ) -> Result<Zeroizing<Vec<u8>>, companion_credentials::CredentialError> {
                self.loads.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                self.inner.load(a)
            }
            fn delete(&self, a: &str) -> Result<(), companion_credentials::CredentialError> {
                self.inner.delete(a)
            }
            fn exists(&self, a: &str) -> Result<bool, companion_credentials::CredentialError> {
                self.inner.exists(a)
            }
            fn key_material_store(&self) -> Arc<dyn CredentialStore> {
                self.inner.key_material_store()
            }
        }
        let store = CountsReads::default();
        let loads = Arc::clone(&store.loads);
        let handle = handle_with(Arc::new(store));
        unsafe {
            assert!(companion_connection_configure(
                handle,
                cstring(r#"{"server_url": "https://eu.onetimesecret.com", "token": "tok_abc"}"#)
                    .as_ptr()
            ));
            let shown = take_json(companion_connection_json(handle));
            let v: serde_json::Value = serde_json::from_str(&shown).unwrap();
            assert_eq!(v["has_token"], true);
            assert!(!shown.contains("tok_abc"));
            assert_eq!(loads.load(std::sync::atomic::Ordering::SeqCst), 0);
            companion_free(handle);
        }
    }

    #[cfg(feature = "test-util")]
    #[test]
    fn a_conceal_that_fails_leaves_the_chip_the_board_and_the_ledger_alone() {
        let handle = handle();
        unsafe {
            assert!(companion_connection_configure(
                handle,
                cstring(r#"{"server_url": "https://eu.onetimesecret.com"}"#).as_ptr()
            ));
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
            seed(handle, "still theirs");
            let ledger_before = take_json(companion_ledger_json(handle));

            for (status, body) in [(0, ""), (401, r#"{"message":"bad credentials"}"#)] {
                assert!(companion_test_wire_stub(
                    handle,
                    status,
                    cstring(body).as_ptr()
                ));
                for result in [
                    take_json(companion_chip_conceal(handle, chip_id, ptr::null())),
                    take_json(companion_sheet_conceal(handle, sheet, ptr::null())),
                ] {
                    let v: serde_json::Value = serde_json::from_str(&result).unwrap();
                    assert_eq!(v["ok"], false, "{result}");
                }
            }

            assert_eq!(take_json(companion_ledger_json(handle)), ledger_before);
            {
                let guard = (*handle).inner.lock().unwrap();
                let item = guard.pasteboard.read().expect("the board was emptied");
                assert!(
                    matches!(item.content, PasteboardContent::Text(ref t) if t == "still theirs")
                );
                assert!(guard.last_write.is_none());
            }
            let tabs = take_json(companion_tabs_json(handle));
            assert!(tabs.contains("\"chip_count\":1"), "{tabs}");
            assert!(companion_chip_copy_out(handle, chip_id));
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

            // Our own transient write is not offered back.
            assert!(companion_chip_copy_out(handle, chip_id));
            assert!(!companion_pasteboard_has_content(handle));

            seed(handle, "from elsewhere");
            assert!(companion_pasteboard_has_content(handle));

            companion_free(handle);
        }
    }

    #[test]
    fn an_image_on_the_board_seals_as_a_metadata_chip_and_copies_back_as_an_image() {
        let handle = handle();
        {
            // A pretend PNG, as a screenshot app would leave it.
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
    fn copy_out_writes_the_pasteboard_in_core_marked_nspasteboard_concealed() {
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

            assert!(companion_chip_copy_out(handle, chip_id));
            {
                let guard = (*handle).inner.lock().unwrap();
                assert!(
                    guard.pasteboard.current_is_transient(),
                    "outbound copies carry the transient mark"
                );
                assert!(
                    guard.pasteboard.current_is_nspasteboard_concealed(),
                    "chip copies carry the `ConcealedType` mark"
                );
            }

            // Copy-out does not consume the chip.
            let sheets = take_json(companion_tabs_json(handle));
            assert!(sheets.contains("\"chip_count\":1"), "{sheets}");

            // Guarded clear: succeeds once, then refuses.
            assert!(companion_clear_clipboard_if_ours(handle));
            assert!(
                !companion_clear_clipboard_if_ours(handle),
                "already cleared"
            );

            companion_free(handle);
        }
    }

    /// A chip sealed onto a fresh page, with its sentinel placed.
    unsafe fn sealed_chip(handle: *mut CompanionHandle, text: &str) -> (u64, u64) {
        let (_tab, sheet) = unsafe { new_page(handle) };
        let chip = unsafe {
            take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring(text).as_ptr(),
                0,
                0,
            ))
        };
        let chip: serde_json::Value = serde_json::from_str(&chip).unwrap();
        (sheet, chip["chip_id"].as_u64().unwrap())
    }

    #[test]
    fn chip_json_carries_the_name() {
        let handle = handle();
        unsafe {
            let (sheet, chip) = sealed_chip(handle, "hunter2");
            let face = |handle: *mut CompanionHandle| -> serde_json::Value {
                let guard = (*handle).inner.lock().unwrap();
                let json = take_json(chip_json(
                    &guard.store,
                    SheetId::from_raw(sheet),
                    ChipId::from_raw(chip),
                ));
                serde_json::from_str(&json).unwrap()
            };
            let document = |handle: *mut CompanionHandle| -> serde_json::Value {
                let runs: serde_json::Value =
                    serde_json::from_str(&take_json(companion_sheet_document_json(handle, sheet)))
                        .unwrap();
                runs[0]["chip"].clone()
            };
            assert_eq!(face(handle)["name"], serde_json::Value::Null);
            assert_eq!(document(handle)["name"], serde_json::Value::Null);

            assert!(companion_chip_set_name(
                handle,
                chip,
                cstring("  DB_PASSWORD ").as_ptr()
            ));
            assert_eq!(face(handle)["name"], "DB_PASSWORD");
            assert_eq!(document(handle)["name"], "DB_PASSWORD");
            assert_eq!(
                face(handle),
                document(handle),
                "the seal routes and the document send one face"
            );

            assert!(!companion_chip_set_name(
                handle,
                chip,
                cstring("db.password").as_ptr()
            ));
            assert_eq!(face(handle)["name"], "DB_PASSWORD", "a refusal kept it");
            assert!(companion_chip_set_name(handle, chip, cstring("").as_ptr()));
            assert_eq!(face(handle)["name"], serde_json::Value::Null);
            companion_free(handle);
        }
    }

    #[test]
    fn the_name_routes_judge_by_one_rule_and_fail_closed() {
        unsafe {
            for (draft, code) in [
                ("API_KEY", 0),
                ("  _x9  ", 0),
                ("", 0),
                ("   ", 0),
                (&"A".repeat(64)[..], 0),
                (&"A".repeat(65)[..], 1),
                ("my.key", 2),
                ("9lives", 2),
                ("two words", 2),
                (&format!("{}-", "A".repeat(70))[..], 2),
            ] {
                assert_eq!(
                    companion_chip_name_refusal(cstring(draft).as_ptr()),
                    code,
                    "{draft:?}"
                );
            }
            assert_eq!(companion_chip_name_refusal(ptr::null()), 2);
            let not_utf8 = [0xC3u8, 0x28, 0];
            assert_eq!(companion_chip_name_refusal(not_utf8.as_ptr().cast()), 2);

            let handle = handle();
            let (_sheet, chip) = sealed_chip(handle, "hunter2");
            let name = cstring("API_KEY");
            assert!(!companion_chip_set_name(
                ptr::null_mut(),
                chip,
                name.as_ptr()
            ));
            assert!(!companion_chip_set_name(handle, chip, ptr::null()));
            assert!(!companion_chip_set_name(handle, 4_242, name.as_ptr()));
            assert!(!companion_chip_set_name(
                handle,
                chip,
                cstring(&"A".repeat(65)).as_ptr()
            ));
            assert!(companion_chip_set_name(handle, chip, name.as_ptr()));
            companion_free(handle);
        }
    }

    #[test]
    fn a_name_reaches_no_ledger_record() {
        let handle = handle();
        unsafe {
            let (_sheet, chip) = sealed_chip(handle, "hunter2");
            let before = take_json(companion_ledger_json(handle));
            assert!(companion_chip_set_name(
                handle,
                chip,
                cstring("PAGER_ROTA_KEY").as_ptr()
            ));
            assert_eq!(
                take_json(companion_ledger_json(handle)),
                before,
                "naming recorded something"
            );
            assert!(companion_chip_copy_out(handle, chip));
            assert!(companion_chip_delete(handle, chip));
            let ledger = take_json(companion_ledger_json(handle));
            assert!(ledger.contains("\"sent\""), "the control: {ledger}");
            assert!(!ledger.contains("PAGER_ROTA_KEY"), "{ledger}");
            assert!(!ledger.contains("ROTA"), "{ledger}");
            companion_free(handle);
        }
    }

    unsafe fn note_runs(handle: *mut CompanionHandle, chip: u64) -> String {
        unsafe { take_json(companion_chip_note_runs_json(handle, chip)) }
    }

    unsafe fn note_ops(handle: *mut CompanionHandle, chip: u64, json: &str, intent: u32) -> bool {
        unsafe {
            companion_chip_note_apply_ops_with_intent(
                handle,
                chip,
                cstring(json).as_ptr(),
                intent,
                u32::MAX,
                u32::MAX,
                u32::MAX,
                u32::MAX,
            )
        }
    }

    unsafe fn note_step_json(p: *mut c_char) -> serde_json::Value {
        serde_json::from_str(&unsafe { take_json(p) }).unwrap()
    }

    #[test]
    fn note_routes_edit_the_note_and_leave_the_page_alone() {
        let handle = handle();
        unsafe {
            let (sheet, chip) = sealed_chip(handle, "hunter2");
            let page = take_json(companion_sheet_document_json(handle, sheet));
            assert_eq!(note_runs(handle, chip), "[]");
            assert!(page.contains("\"has_note\":false"), "{page}");
            assert!(!companion_chip_note_can_undo(handle, chip));

            assert!(note_ops(
                handle,
                chip,
                "[{\"ins\": {\"at\": 0, \"text\": \"rotate \u{1F511} on friday\"}}]",
                0
            ));
            assert_eq!(
                note_runs(handle, chip),
                "[{\"ink\":\"rotate \u{1F511} on friday\"}]"
            );
            let after = take_json(companion_sheet_document_json(handle, sheet));
            assert!(after.contains("\"has_note\":true"), "{after}");
            assert!(!after.contains("friday"), "the note rode the page: {after}");
            assert_eq!(
                after.replace("\"has_note\":true", "\"has_note\":false"),
                page,
                "a note edit moved the page"
            );

            assert!(companion_chip_note_can_undo(handle, chip));
            assert_eq!(
                take_json(companion_chip_note_undo_action_name(handle, chip)),
                "Typing"
            );
            assert!(companion_chip_note_redo_action_name(handle, chip).is_null());
            let step = note_step_json(companion_chip_note_undo(handle, chip));
            assert_eq!(step["applied"], true, "{step}");
            assert_eq!(note_runs(handle, chip), "[]");
            assert!(companion_chip_note_can_redo(handle, chip));
            let step = note_step_json(companion_chip_note_redo(handle, chip));
            assert_eq!(step["applied"], true, "{step}");
            assert!(note_runs(handle, chip).contains("friday"));
            assert!(companion_chip_note_finish_editing_group(
                handle,
                chip,
                u32::MAX,
                u32::MAX
            ));
            assert!(companion_chip_note_finish_editing_group(handle, chip, 2, 0));
            companion_free(handle);
        }
    }

    #[test]
    fn the_note_and_the_page_keep_separate_undo_stacks_across_the_seam() {
        let handle = handle();
        unsafe {
            let (sheet, chip) = sealed_chip(handle, "hunter2");
            let typed = r#"[{"ins": {"at": 1, "text": " page ink"}}]"#;
            assert!(companion_sheet_apply_ops(
                handle,
                sheet,
                cstring(typed).as_ptr()
            ));
            assert!(note_ops(
                handle,
                chip,
                r#"[{"ins": {"at": 0, "text": "note ink"}}]"#,
                0
            ));

            assert!(companion_sheet_undo(handle, sheet));
            let page = take_json(companion_sheet_document_json(handle, sheet));
            assert!(!page.contains("page ink"), "{page}");
            assert!(
                note_runs(handle, chip).contains("note ink"),
                "the page's undo reached the note"
            );
            assert!(companion_chip_note_can_undo(handle, chip));

            assert!(companion_sheet_redo(handle, sheet));
            let step = note_step_json(companion_chip_note_undo(handle, chip));
            assert_eq!(step["applied"], true);
            assert_eq!(note_runs(handle, chip), "[]");
            let page = take_json(companion_sheet_document_json(handle, sheet));
            assert!(
                page.contains("page ink"),
                "the note's undo reached the page: {page}"
            );
            assert!(companion_sheet_can_undo(handle, sheet));
            companion_free(handle);
        }
    }

    #[test]
    fn the_note_routes_fail_closed() {
        let handle = handle();
        unsafe {
            let (_sheet, chip) = sealed_chip(handle, "hunter2");
            let (_other_sheet, other) = sealed_chip(handle, "another");
            let ins = r#"[{"ins": {"at": 0, "text": "x"}}]"#;
            for bad in [
                format!(r#"[{{"chip": {{"at": 0, "id": {other}}}}}]"#),
                r#"[{"del": {"at": 3, "len": 1}}]"#.to_string(),
                "not json".to_string(),
            ] {
                assert!(!note_ops(handle, chip, &bad, 0), "{bad}");
            }
            assert!(!note_ops(handle, chip, ins, 99), "an unknown intent");
            assert!(!companion_chip_note_apply_ops_with_intent(
                handle,
                chip,
                cstring(ins).as_ptr(),
                0,
                0,
                u32::MAX,
                0,
                0
            ));
            assert!(!companion_chip_note_apply_ops_with_intent(
                handle,
                chip,
                ptr::null(),
                0,
                u32::MAX,
                u32::MAX,
                u32::MAX,
                u32::MAX
            ));
            assert_eq!(note_runs(handle, chip), "[]", "a refusal wrote the note");
            assert!(!companion_chip_note_finish_editing_group(
                handle,
                chip,
                u32::MAX,
                0
            ));

            assert!(!note_ops(handle, 4_242, ins, 0));
            assert!(companion_chip_note_runs_json(handle, 4_242).is_null());
            assert!(!companion_chip_note_finish_editing_group(
                handle,
                4_242,
                u32::MAX,
                u32::MAX
            ));
            assert!(!companion_chip_note_can_undo(handle, 4_242));
            assert!(!companion_chip_note_can_redo(handle, 4_242));
            assert!(companion_chip_note_undo_action_name(handle, 4_242).is_null());
            assert!(companion_chip_note_undo(handle, 4_242).is_null());
            assert!(companion_chip_note_redo(handle, 4_242).is_null());

            assert!(!note_ops(ptr::null_mut(), chip, ins, 0));
            assert!(companion_chip_note_runs_json(ptr::null_mut(), chip).is_null());
            assert!(companion_chip_note_undo(ptr::null_mut(), chip).is_null());
            companion_free(handle);
        }
    }

    #[test]
    fn a_name_and_a_note_reach_no_ledger_record_and_no_other_output() {
        let handle = handle();
        unsafe {
            let (sheet, chip) = sealed_chip(handle, "hunter2");
            let before = take_json(companion_ledger_json(handle));
            assert!(companion_chip_set_name(
                handle,
                chip,
                cstring("WHARF_LANTERN_KEY").as_ptr()
            ));
            let note = "Wq9Fj Zx7Kp Marmot Burrow";
            assert!(note_ops(
                handle,
                chip,
                &format!(r#"[{{"ins": {{"at": 0, "text": "{note}"}}}}]"#),
                2
            ));
            let _ = note_step_json(companion_chip_note_undo(handle, chip));
            let _ = note_step_json(companion_chip_note_redo(handle, chip));
            assert_eq!(
                take_json(companion_ledger_json(handle)),
                before,
                "a name or a note edit recorded something"
            );
            for (name, output) in [
                ("summaries", take_json(companion_tabs_json(handle))),
                ("meta", take_json(companion_sheet_meta_json(handle, sheet))),
                (
                    "blocks",
                    take_json(companion_sheet_blocks_json(handle, sheet)),
                ),
            ] {
                assert!(
                    !output.contains("Marmot") && !output.contains("LANTERN"),
                    "{name} carried the name or the note: {output}"
                );
            }
            let document = take_json(companion_sheet_document_json(handle, sheet));
            assert!(!document.contains("Marmot"), "{document}");
            assert!(
                document.contains("WHARF_LANTERN_KEY"),
                "the control: the face carries the name"
            );
            assert!(note_runs(handle, chip).contains("Marmot"), "the control");

            let tab = (*handle)
                .inner
                .lock()
                .unwrap()
                .store
                .tabs()
                .next()
                .unwrap()
                .id()
                .raw();
            assert!(companion_tab_close(handle, tab));
            let ledger = take_json(companion_ledger_json(handle));
            assert!(
                ledger.contains("\"expired\"") || ledger.contains("\"discarded\""),
                "{ledger}"
            );
            assert!(!ledger.contains("Marmot"), "{ledger}");
            assert!(!ledger.contains("LANTERN"), "{ledger}");
            assert!(
                companion_chip_note_runs_json(handle, chip).is_null(),
                "the note outlived its page"
            );
            companion_free(handle);
        }
    }

    #[test]
    fn the_clear_interval_is_the_core_constant() {
        assert_eq!(companion_clipboard_clear_seconds(), CLIPBOARD_CLEAR_SECONDS);
        assert_eq!(companion_clipboard_clear_seconds(), 60);
    }

    #[test]
    fn the_link_recovery_interval_is_its_own_core_constant() {
        assert_eq!(
            companion_conceal_link_recovery_seconds(),
            LINK_RECOVERY_SECONDS
        );
        assert_eq!(companion_conceal_link_recovery_seconds(), 60);
    }

    #[test]
    fn a_second_egress_retires_the_first_receipt() {
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            let chip_json = take_json(companion_sheet_seal_text(
                handle,
                sheet,
                cstring("copied twice").as_ptr(),
                0,
                0,
            ));
            let chip: serde_json::Value = serde_json::from_str(&chip_json).unwrap();
            let chip_id = chip["chip_id"].as_u64().unwrap();

            assert!(companion_chip_copy_out(handle, chip_id));
            let first = (*handle).inner.lock().unwrap().last_write;
            assert!(companion_chip_copy_out(handle, chip_id));
            let second = (*handle).inner.lock().unwrap().last_write;
            assert_ne!(first, second, "the second write is a new receipt");
            assert!(
                (*handle).inner.lock().unwrap().pasteboard.read().is_some(),
                "the retire took only the old write; the new one stands"
            );
            assert!(companion_clear_clipboard_if_ours(handle));
            assert!(
                (*handle).inner.lock().unwrap().pasteboard.read().is_none(),
                "the clear answered for the newest write"
            );
            companion_free(handle);
        }
    }

    fn board_text(handle: *mut CompanionHandle) -> Option<String> {
        let guard = unsafe { &*handle }.inner.lock().unwrap();
        match guard.pasteboard.read()?.content {
            PasteboardContent::Text(text) => Some(text),
            PasteboardContent::Image(_) => None,
        }
    }

    fn sent_records(handle: *mut CompanionHandle) -> Vec<serde_json::Value> {
        let ledger = unsafe { take_json(companion_ledger_json(handle)) };
        let records: Vec<serde_json::Value> = serde_json::from_str(&ledger).unwrap();
        records
            .into_iter()
            .filter(|record| record["event"] == "sent")
            .collect()
    }

    #[test]
    fn copy_name_value_writes_the_pasteboard_in_core_marked_nspasteboard_concealed() {
        let handle = handle();
        unsafe {
            let (_sheet, chip) = sealed_chip(handle, "multi-paste me");
            assert!(companion_chip_set_name(
                handle,
                chip,
                cstring("DEPLOY_TOKEN").as_ptr()
            ));

            assert!(companion_chip_copy_name_value(handle, chip));
            assert_eq!(
                board_text(handle).as_deref(),
                Some("DEPLOY_TOKEN=multi-paste me")
            );
            {
                let guard = (*handle).inner.lock().unwrap();
                assert!(guard.pasteboard.current_is_transient());
                assert!(guard.pasteboard.current_is_nspasteboard_concealed());
            }
            let sheets = take_json(companion_tabs_json(handle));
            assert!(sheets.contains("\"chip_count\":1"), "{sheets}");

            // The same guarded clear as copy decrypted: once, then refused.
            assert!(companion_clear_clipboard_if_ours(handle));
            assert!(board_text(handle).is_none());
            assert!(!companion_clear_clipboard_if_ours(handle));
            companion_free(handle);
        }
    }

    #[test]
    fn copy_name_value_refuses_unnamed_image_and_unknown_chips_and_writes_nothing() {
        let handle = handle();
        unsafe {
            let (sheet, unnamed) = sealed_chip(handle, "never on the board");
            seed(handle, "someone else's copy");
            assert!(!companion_chip_copy_name_value(handle, unnamed));
            assert!(!companion_chip_copy_name_value(handle, 4_242));
            assert!(!companion_chip_copy_name_value(ptr::null_mut(), unnamed));

            {
                let mut guard = (*handle).inner.lock().unwrap();
                let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
                png.resize(64, 7);
                let image = guard
                    .store
                    .seal_image_at(SheetId::from_raw(sheet), png, 0, 0)
                    .unwrap();
                guard.store.set_chip_name(image, "LOGO").unwrap();
                drop(guard);
                assert!(!companion_chip_copy_name_value(handle, image.raw()));
            }

            assert_eq!(
                board_text(handle).as_deref(),
                Some("someone else's copy"),
                "a refusal wrote the board"
            );
            assert!((*handle).inner.lock().unwrap().last_write.is_none());
            assert!(
                sent_records(handle).is_empty(),
                "a refusal recorded an egress"
            );
            companion_free(handle);
        }
    }

    #[test]
    fn a_name_value_copy_and_a_copy_out_retire_each_others_receipts() {
        let handle = handle();
        unsafe {
            let (_sheet, chip) = sealed_chip(handle, "copied both ways");
            assert!(companion_chip_set_name(
                handle,
                chip,
                cstring("BOTH_WAYS").as_ptr()
            ));

            assert!(companion_chip_copy_out(handle, chip));
            let first = (*handle).inner.lock().unwrap().last_write;
            assert!(companion_chip_copy_name_value(handle, chip));
            let second = (*handle).inner.lock().unwrap().last_write;
            assert_ne!(first, second, "the second write is a new receipt");
            assert_eq!(
                board_text(handle).as_deref(),
                Some("BOTH_WAYS=copied both ways")
            );

            assert!(companion_chip_copy_out(handle, chip));
            assert_eq!(board_text(handle).as_deref(), Some("copied both ways"));
            assert!(companion_clear_clipboard_if_ours(handle));
            assert!(
                board_text(handle).is_none(),
                "the clear answered for the newest write"
            );
            companion_free(handle);
        }
    }

    #[test]
    fn a_name_value_copy_records_one_sent_and_no_name() {
        let handle = handle();
        unsafe {
            let (_sheet, chip) = sealed_chip(handle, "hunter2");
            assert!(companion_chip_set_name(
                handle,
                chip,
                cstring("WHARF_LANTERN_KEY").as_ptr()
            ));
            assert!(companion_chip_copy_name_value(handle, chip));
            assert!(companion_chip_copy_name_value(handle, chip));

            let sent = sent_records(handle);
            assert_eq!(sent.len(), 2, "one per copy: {sent:?}");
            for record in &sent {
                assert_eq!(record["destination"], "clipboard");
                assert_eq!(record["size"], "tiny", "the payload's class");
            }
            let ledger = take_json(companion_ledger_json(handle));
            assert!(!ledger.contains("WHARF"), "{ledger}");
            assert!(!ledger.contains("LANTERN"), "{ledger}");
            assert!(!ledger.contains("hunter2"), "{ledger}");
            let saved = (*handle).inner.lock().unwrap().store.ledger_snapshot();
            assert!(!contains(&saved, b"WHARF_LANTERN_KEY"));
            companion_free(handle);
        }
    }

    #[test]
    fn sync_document_names_the_page_and_detaches_omitted_chips() {
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

            // A snapshot that omits the chip detaches it (ADR-0046 point 1).
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(r#"[{"ink": "just ink"}]"#).as_ptr()
            ));
            assert!(!companion_chip_copy_out(handle, chip_id), "off the page");
            let named = format!("[{{\"chip\": {chip_id}}}]");
            assert!(companion_sheet_sync_document(
                handle,
                sheet,
                cstring(&named).as_ptr()
            ));
            assert!(companion_chip_copy_out(handle, chip_id), "back on the page");

            companion_free(handle);
        }
    }

    #[test]
    fn apply_ops_moves_edits_over_the_seam() {
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            // Positions are UTF-16 code units, so the rocket spans two.
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
    fn undo_and_redo_cross_the_seam_with_the_caret() {
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            assert!(!companion_sheet_can_undo(handle, sheet));
            let batch = r#"[{"ins": {"at": 0, "text": "a whole thought"}}]"#;
            assert!(companion_sheet_apply_ops(
                handle,
                sheet,
                cstring(batch).as_ptr()
            ));
            assert!(companion_sheet_can_undo(handle, sheet));
            assert!(!companion_sheet_can_redo(handle, sheet));

            assert!(companion_sheet_undo(handle, sheet));
            let doc = take_json(companion_sheet_document_json(handle, sheet));
            assert!(!doc.contains("a whole thought"), "unexpected body: {doc}");
            assert_eq!(companion_sheet_undo_caret_u16(handle, sheet), 0);
            assert!(companion_sheet_can_redo(handle, sheet));

            assert!(companion_sheet_redo(handle, sheet));
            let doc = take_json(companion_sheet_document_json(handle, sheet));
            assert!(doc.contains("a whole thought"), "unexpected body: {doc}");

            assert!(!companion_sheet_redo(handle, sheet));
            companion_free(handle);
        }
    }

    /// Both batches land inside the merge interval; plain `apply_ops` would fold them.
    #[test]
    fn a_new_step_batch_comes_back_off_the_stack_alone() {
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            let typed = r#"[{"ins": {"at": 0, "text": "- milk"}}]"#;
            assert!(companion_sheet_apply_ops(
                handle,
                sheet,
                cstring(typed).as_ptr()
            ));
            let continued = r#"[{"ins": {"at": 6, "text": "\n- "}}]"#;
            assert!(companion_sheet_apply_ops_as_new_step(
                handle,
                sheet,
                cstring(continued).as_ptr()
            ));

            assert!(companion_sheet_undo(handle, sheet));
            let doc = take_json(companion_sheet_document_json(handle, sheet));
            assert_eq!(
                doc, r#"[{"ink":"- milk"}]"#,
                "one press took back more than the marker the page added"
            );
            // The typing is still a step of its own behind it.
            assert!(companion_sheet_can_undo(handle, sheet));
            companion_free(handle);
        }
    }

    #[test]
    fn explicit_edit_intent_and_group_boundaries_cross_the_seam() {
        let handle = handle();
        unsafe {
            let (_tab, sheet) = new_page(handle);
            let a = cstring(r#"[{"ins":{"at":0,"text":"a"}}]"#);
            let b = cstring(r#"[{"ins":{"at":1,"text":"b"}}]"#);
            let c = cstring(r#"[{"ins":{"at":2,"text":"c"}}]"#);
            assert!(companion_sheet_apply_ops_with_intent(
                handle,
                sheet,
                a.as_ptr(),
                0,
                u32::MAX,
                u32::MAX,
                u32::MAX,
                u32::MAX
            ));
            assert!(companion_sheet_apply_ops_with_intent(
                handle,
                sheet,
                b.as_ptr(),
                2,
                u32::MAX,
                u32::MAX,
                u32::MAX,
                u32::MAX
            ));
            assert!(companion_sheet_apply_ops_with_intent(
                handle,
                sheet,
                c.as_ptr(),
                0,
                u32::MAX,
                u32::MAX,
                u32::MAX,
                u32::MAX
            ));
            assert!(!companion_sheet_apply_ops_with_intent(
                handle,
                sheet,
                c.as_ptr(),
                99,
                u32::MAX,
                u32::MAX,
                u32::MAX,
                u32::MAX
            ));

            assert_eq!(
                take_json(companion_sheet_undo_action_name(handle, sheet)),
                "Typing"
            );
            assert!(companion_sheet_undo(handle, sheet));
            assert!(take_json(companion_sheet_document_json(handle, sheet)).contains("ab"));
            assert_eq!(
                take_json(companion_sheet_undo_action_name(handle, sheet)),
                "Paste"
            );
            assert_eq!(
                take_json(companion_sheet_redo_action_name(handle, sheet)),
                "Typing"
            );
            assert!(companion_sheet_undo(handle, sheet));
            assert!(take_json(companion_sheet_document_json(handle, sheet)).contains("a"));
            assert!(companion_sheet_finish_editing_group(
                handle,
                sheet,
                u32::MAX,
                u32::MAX
            ));
            companion_free(handle);
        }
    }

    #[test]
    fn the_new_step_seam_fails_closed_like_every_other_batch_route() {
        let handle = handle();
        unsafe {
            let batch = cstring(r#"[{"ins": {"at": 0, "text": "x"}}]"#);
            assert!(!companion_sheet_apply_ops_as_new_step(
                ptr::null_mut(),
                1,
                batch.as_ptr()
            ));
            let (_tab, sheet) = new_page(handle);
            assert!(!companion_sheet_apply_ops_as_new_step(
                handle,
                4_242,
                batch.as_ptr()
            ));
            assert!(!companion_sheet_apply_ops_as_new_step(
                handle,
                sheet,
                ptr::null()
            ));
            assert!(!companion_sheet_apply_ops_as_new_step(
                handle,
                sheet,
                cstring("not json").as_ptr()
            ));
            assert!(!companion_sheet_apply_ops_as_new_step(
                handle,
                sheet,
                cstring(r#"[{"del": {"at": 9, "len": 3}}]"#).as_ptr()
            ));
            let doc = take_json(companion_sheet_document_json(handle, sheet));
            assert!(!doc.contains('x'), "a refused batch left ink: {doc}");
            companion_free(handle);
        }
    }

    #[test]
    fn the_undo_seams_fail_closed_on_a_null_handle_and_an_unknown_page() {
        let handle = handle();
        unsafe {
            assert!(!companion_sheet_undo(ptr::null_mut(), 1));
            assert!(!companion_sheet_redo(ptr::null_mut(), 1));
            assert!(!companion_sheet_can_undo(ptr::null_mut(), 1));
            assert!(!companion_sheet_can_redo(ptr::null_mut(), 1));
            assert_eq!(companion_sheet_undo_caret_u16(ptr::null_mut(), 1), -1);

            assert!(!companion_sheet_undo(handle, 4_242));
            assert!(!companion_sheet_redo(handle, 4_242));
            assert!(!companion_sheet_can_undo(handle, 4_242));
            assert!(!companion_sheet_can_redo(handle, 4_242));
            assert_eq!(companion_sheet_undo_caret_u16(handle, 4_242), -1);
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

            // Parses, but misses the page mid-way: the valid first op must not land.
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
            // A boundary inside the astral pair seals nothing.
            assert!(
                companion_sheet_seal_text(handle, sheet, cstring("x").as_ptr(), 2, 1).is_null()
            );
            companion_free(handle);
        }
    }

    #[test]
    fn connection_config_and_offline_conceal_refusals() {
        let handle = handle();
        unsafe {
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
            let refusal = take_json(companion_chip_conceal(handle, chip_id, ptr::null()));
            let v: serde_json::Value = serde_json::from_str(&refusal).unwrap();
            assert_eq!(v["ok"], false);
            assert!(v["error"].as_str().unwrap().contains("no connection"));

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

            let refusal = take_json(companion_chip_conceal(
                handle,
                chip_id,
                cstring("[]").as_ptr(),
            ));
            let v: serde_json::Value = serde_json::from_str(&refusal).unwrap();
            assert_eq!(v["ok"], false);
            assert!(v["error"].as_str().unwrap().contains("malformed"));

            let refusal = take_json(companion_chip_conceal(handle, 424_242, ptr::null()));
            assert!(refusal.contains("gone"));
            let (_empty_tab, empty) = new_page(handle);
            let refusal = take_json(companion_sheet_conceal(handle, empty, ptr::null()));
            assert!(refusal.contains("nothing to conceal"));

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
    fn a_tenth_tab_opens_like_the_ninth() {
        // No keyboard wall at the seam (issue #158).
        let handle = handle();
        unsafe {
            let ids: Vec<u64> = (0..12).map(|_| companion_tab_new(handle)).collect();
            assert!(ids.iter().all(|&id| id != 0), "a slot was refused");
            let distinct: std::collections::HashSet<u64> = ids.iter().copied().collect();
            assert_eq!(distinct.len(), 12, "two asks answered with one slot");
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

            assert!(companion_set_grace_snap(handle, false));
            assert!(companion_tab_set_rung(handle, tab, 2)); // 8h
            let ms = companion_next_event_ms(handle);
            assert!(ms > 7 * 60 * 60 * 1000, "deadline ms: {ms}");
            assert!(ms <= 8 * 60 * 60 * 1000, "deadline ms: {ms}");

            // Paused: the next event is the 1h hold lapse.
            assert!(companion_tab_pause_press(handle, tab));
            let ms = companion_next_event_ms(handle);
            assert!(ms <= 60 * 60 * 1000, "hold lapse ms: {ms}");
            assert!(ms > 59 * 60 * 1000, "hold lapse ms: {ms}");

            let sheets = take_json(companion_tabs_json(handle));
            assert!(sheets.contains("\"paused\":true"), "{sheets}");
            assert!(sheets.contains("spoken_remaining"), "{sheets}");

            assert_eq!(companion_expire_due(handle), 0, "nothing due yet");
            companion_free(handle);
        }
    }

    /// ADR-0011 §3 and §4 at the seam.
    #[test]
    fn a_new_tab_opens_on_the_ceiling_and_the_snap_rounds_its_deadline_up() {
        const DAY_MS: i64 = 24 * 60 * 60 * 1000;
        let handle = handle();
        unsafe {
            let (tab, _) = new_page(handle);
            let sheets = take_json(companion_tabs_json(handle));
            assert!(sheets.contains("\"rung_label\":\"7d\""), "{sheets}");

            let snapped = companion_next_event_ms(handle);
            assert!(snapped >= 7 * DAY_MS, "deadline ms: {snapped}");
            assert!(snapped <= 8 * DAY_MS, "deadline ms: {snapped}");

            // Turning the snap off moves nothing that is already set…
            assert!(companion_set_grace_snap(handle, false));
            let unmoved = companion_next_event_ms(handle);
            assert!((snapped - unmoved).abs() < 1_000, "{snapped} vs {unmoved}");

            // …and the next application is exact.
            assert!(companion_tab_set_rung(handle, tab, 5)); // 7d
            let exact = companion_next_event_ms(handle);
            assert!(exact <= 7 * DAY_MS, "deadline ms: {exact}");
            assert!(exact > 7 * DAY_MS - 1_000, "deadline ms: {exact}");

            // Back on, an hour rung rounds up to the next clock hour.
            assert!(companion_set_grace_snap(handle, true));
            assert!(companion_tab_set_rung(handle, tab, 0)); // 1h
            let hour = companion_next_event_ms(handle);
            assert!(hour >= 60 * 60 * 1000 - 1_000, "deadline ms: {hour}");
            assert!(hour <= 2 * 60 * 60 * 1000, "deadline ms: {hour}");

            assert!(!companion_set_grace_snap(std::ptr::null_mut(), true));
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

    /// An expiry is where the two ids differ (ADR-0017).
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

            // The expiry takes the page and leaves the slot.
            age_by(handle, 2 * 60 * 60 * 1_000);
            assert_eq!(companion_expire_due(handle), 1);
            let summaries = strip(handle);
            assert_eq!(summaries.len(), 1, "the tab stayed on the strip");
            let tab = summaries[0]["id"].as_u64().unwrap();
            assert_eq!(summaries[0]["has_page"].as_bool(), Some(false));
            assert!(summaries[0]["page_id"].is_null(), "{:?}", summaries[0]);
            assert_eq!(summaries[0]["title"].as_str(), Some("payroll"));
            assert_eq!(summaries[0]["title_source"].as_str(), Some("name"));
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

    /// The day crosses as an offset from today (ADR-0020).
    #[test]
    fn the_summary_says_which_day_the_page_was_born_on() {
        let handle = handle();
        unsafe {
            let (_tab, page) = new_page(handle);
            assert_ne!(page, 0);

            assert_eq!(strip(handle)[0]["page_day_offset"].as_i64(), Some(0));
            {
                let guard = (*handle).inner.lock().unwrap();
                let born = guard
                    .store
                    .sheet(SheetId::from_raw(page))
                    .expect("the page is standing")
                    .created_wall_ms();
                drop(guard);
                assert_eq!(strip(handle)[0]["page_created_ms"].as_u64(), Some(born));
                assert!(born > 0, "a page born at the epoch is a clock nobody read");
            }

            // Against later readings of today the same page is yesterday's, then older.
            {
                let guard = (*handle).inner.lock().unwrap();
                let tab = guard.store.tabs().next().expect("the slot is standing");
                let now = guard.store.now();
                let offset = guard.store.local_offset_seconds();
                let today = guard.store.wall_ms();
                let day_ms = 24 * 60 * 60 * 1_000;
                for (days, expected) in [(1_u64, -1_i64), (2, -2), (6, -6)] {
                    let later =
                        serde_json::to_value(summary_json(tab, now, offset, today + days * day_ms))
                            .unwrap();
                    assert_eq!(
                        later["page_day_offset"].as_i64(),
                        Some(expected),
                        "a day of wall time is one day of bucket, wherever the clock stands"
                    );
                    assert_eq!(
                        later["page_has_content"].as_bool(),
                        Some(false),
                        "and the other field is not the clock's"
                    );
                }
            }
            companion_free(handle);
        }
    }

    /// The ledger's own content bar, crossing as a boolean (ADR-0020).
    #[test]
    fn the_summary_says_whether_anything_is_on_the_page() {
        let handle = handle();
        unsafe {
            let (_tab, page) = new_page(handle);

            assert_eq!(strip(handle)[0]["page_has_content"].as_bool(), Some(false));

            // Whitespace alone is not content.
            assert!(companion_sheet_sync_document(
                handle,
                page,
                cstring(r#"[{"ink": "  \n "}]"#).as_ptr()
            ));
            assert_eq!(strip(handle)[0]["page_has_content"].as_bool(), Some(false));

            assert!(companion_sheet_sync_document(
                handle,
                page,
                cstring(r#"[{"ink": "rotate the key"}]"#).as_ptr()
            ));
            assert_eq!(strip(handle)[0]["page_has_content"].as_bool(), Some(true));

            // A sealed chip alone is content.
            assert!(companion_sheet_sync_document(
                handle,
                page,
                cstring(r#"[{"ink": "  "}]"#).as_ptr()
            ));
            assert_eq!(strip(handle)[0]["page_has_content"].as_bool(), Some(false));
            let chip = take_json(companion_sheet_seal_text(
                handle,
                page,
                cstring("one secret").as_ptr(),
                0,
                0,
            ));
            assert!(chip.contains("excerpt"), "chip JSON: {chip}");
            let summaries = strip(handle);
            assert_eq!(summaries[0]["page_has_content"].as_bool(), Some(true));
            assert_eq!(summaries[0]["chip_count"].as_u64(), Some(1));

            let json = take_json(companion_tabs_json(handle));
            assert!(!json.contains("one secret"), "{json}");
            companion_free(handle);
        }
    }

    /// The offset is null for an empty slot: zero would claim a page made today.
    #[test]
    fn an_empty_slot_reports_no_day_and_no_content() {
        let handle = handle();
        unsafe {
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
                cstring(r#"[{"ink": "rotate the key"}]"#).as_ptr()
            ));
            let before = strip(handle);
            assert_eq!(before[0]["page_has_content"].as_bool(), Some(true));
            assert_eq!(before[0]["page_day_offset"].as_i64(), Some(0));

            // Overnight the page dies and the slot stands (ADR-0017).
            age_by(handle, 2 * 60 * 60 * 1_000);
            assert_eq!(companion_expire_due(handle), 1);
            let after = strip(handle);
            assert_eq!(after.len(), 1, "the tab stayed on the strip");
            assert_eq!(after[0]["has_page"].as_bool(), Some(false));
            assert_eq!(after[0]["title"].as_str(), Some("payroll"));
            assert!(after[0]["page_day_offset"].is_null(), "{:?}", after[0]);
            assert!(after[0].get("page_uuid").unwrap().is_null());
            assert_eq!(after[0]["page_has_content"].as_bool(), Some(false));
            companion_free(handle);
        }
    }

    /// Summaries are decoded by name on the far side, so a rename is a break.
    #[test]
    fn existing_summary_fields_and_additive_stable_uuid_are_preserved() {
        let handle = handle();
        unsafe {
            let (_tab, page) = new_page(handle);
            assert_ne!(page, 0);
            let summaries = strip(handle);
            let mut keys: Vec<&str> = summaries[0]
                .as_object()
                .expect("a summary is an object")
                .keys()
                .map(String::as_str)
                .collect();
            keys.sort_unstable();
            let mut expected = [
                "id",
                "uuid",
                "has_page",
                "page_id",
                "page_uuid",
                "title",
                "title_source",
                "rung_code",
                "rung_label",
                "remaining_ms",
                "remaining_label",
                "spoken_remaining",
                "fraction_remaining",
                "paused",
                "hold_topped_up",
                "hold_remaining_ms",
                "chip_count",
                "last_hour",
                "page_has_content",
                "page_day_offset",
                "page_created_ms",
            ];
            expected.sort_unstable();
            assert_eq!(keys, expected);
            companion_free(handle);
        }
    }

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

            assert!(!companion_page_discard(handle, page), "already gone");
            assert!(!companion_page_discard(handle, 424_242), "no such page");
            assert!(!companion_page_discard(ptr::null_mut(), page));
            companion_free(handle);
        }
    }

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

    #[test]
    fn ledger_json_reports_events_uuids_and_never_ink() {
        // The second line never becomes a title.
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
            // The title is the one documented content exception.
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
            assert_eq!(records[0]["item"], records[1]["item"]);

            companion_ledger_clear(handle);
            assert_eq!(take_json(companion_ledger_json(handle)), "[]");
            companion_free(handle);
        }
    }

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

    unsafe fn complete_page_link(handle: *mut CompanionHandle, page: u64, receipt: &str) -> u64 {
        let result = unsafe {
            take_json(finish_conceal(
                &*handle,
                Concealed {
                    link: format!("https://example.invalid/secret/{receipt}"),
                    receipt_id: receipt.into(),
                },
                Concealable::Page(SheetId::from_raw(page)),
            ))
        };
        let result: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(result["ok"], true);
        result["copy_token"].as_u64().unwrap()
    }

    #[test]
    fn link_recopy_recovers_after_an_external_copy_without_another_send() {
        let handle = handle();
        unsafe {
            let (_, page) = new_page(handle);
            let token = complete_page_link(handle, page, "latest");
            let deadline = (&*handle)
                .inner
                .lock()
                .unwrap()
                .concealed_link
                .as_ref()
                .unwrap()
                .expires_at;
            let ledger = take_json(companion_ledger_json(handle));
            seed(handle, "copied in another application");
            assert!(companion_conceal_link_can_copy(handle, token));
            assert!(companion_conceal_link_copy(handle, token));
            assert!(
                companion_conceal_link_remaining_ms(handle, token)
                    <= u64::from(LINK_RECOVERY_SECONDS) * 1_000
            );
            {
                let guard = (&*handle).inner.lock().unwrap();
                let item = guard.pasteboard.read().unwrap();
                let PasteboardContent::Text(text) = item.content else {
                    panic!("expected text");
                };
                assert_eq!(text, "https://example.invalid/secret/latest");
                assert!(guard.pasteboard.current_is_transient());
                assert_eq!(guard.concealed_link.as_ref().unwrap().expires_at, deadline);
            }
            assert_eq!(take_json(companion_ledger_json(handle)), ledger);
            assert!(companion_clear_clipboard_if_ours(handle));
            companion_free(handle);
        }
    }

    #[test]
    fn only_the_latest_link_token_can_copy_or_forget_even_when_receipts_repeat() {
        let handle = handle();
        unsafe {
            let (_, page) = new_page(handle);
            let earlier = complete_page_link(handle, page, "same-receipt");
            let latest = complete_page_link(handle, page, "same-receipt");
            assert_ne!(earlier, latest);
            companion_conceal_link_forget(handle, earlier);
            assert!(!companion_conceal_link_copy(handle, earlier));
            assert!(companion_conceal_link_can_copy(handle, latest));
            companion_conceal_link_forget(handle, latest);
            assert!(!companion_conceal_link_copy(handle, latest));
            assert!((&*handle).inner.lock().unwrap().concealed_link.is_none());
            companion_free(handle);
        }
    }

    #[test]
    fn link_recopy_refuses_at_its_deadline_and_after_its_page_expires() {
        let handle = handle();
        unsafe {
            let (_, page) = new_page(handle);
            let token = complete_page_link(handle, page, "window");
            {
                let mut guard = (&*handle).inner.lock().unwrap();
                let deadline = guard.store.now();
                guard.concealed_link.as_mut().unwrap().expires_at = deadline;
            }
            seed(handle, "leave this external copy alone");
            assert!(!companion_conceal_link_copy(handle, token));
            assert_eq!(companion_conceal_link_remaining_ms(handle, token), 0);
            assert!(!companion_conceal_link_can_copy(handle, token));
            {
                let guard = (&*handle).inner.lock().unwrap();
                assert_eq!(
                    guard.pasteboard.read().unwrap().content,
                    PasteboardContent::Text("leave this external copy alone".into())
                );
            }
            let token = complete_page_link(handle, page, "page");
            age_by(handle, 8 * 24 * 60 * 60 * 1_000);
            assert!(!companion_conceal_link_can_copy(handle, token));
            assert!(!companion_conceal_link_copy(handle, token));
            assert!((&*handle).inner.lock().unwrap().concealed_link.is_none());
            assert!(!companion_conceal_link_copy(ptr::null_mut(), token));
            assert!(!companion_conceal_link_can_copy(ptr::null_mut(), 0));
            companion_conceal_link_forget(ptr::null_mut(), 0);
            companion_free(handle);
        }
    }

    #[test]
    fn link_recopy_reports_its_store_clock_deadline_without_restarting_it() {
        let handle = handle();
        unsafe {
            let (_, page) = new_page(handle);
            let token = complete_page_link(handle, page, "remaining");
            let deadline = {
                let mut guard = (&*handle).inner.lock().unwrap();
                let deadline = guard.store.now() + Duration::from_secs(5);
                guard.concealed_link.as_mut().unwrap().expires_at = deadline;
                deadline
            };
            let remaining = companion_conceal_link_remaining_ms(handle, token);
            assert!(remaining > 0 && remaining <= 5_000);
            assert!(companion_conceal_link_can_copy(handle, token));
            assert!(companion_conceal_link_copy(handle, token));
            assert!(companion_conceal_link_remaining_ms(handle, token) <= remaining);
            {
                let mut guard = (&*handle).inner.lock().unwrap();
                assert_eq!(guard.concealed_link.as_ref().unwrap().expires_at, deadline);
                let now = guard.store.now();
                guard.concealed_link.as_mut().unwrap().expires_at = now;
            }
            assert_eq!(companion_conceal_link_remaining_ms(handle, token), 0);
            assert!(!companion_conceal_link_can_copy(handle, token));
            assert!(!companion_conceal_link_copy(handle, token));
            companion_free(handle);
        }
    }

    #[test]
    fn a_copy_out_and_a_conceal_each_leave_one_sent_record() {
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

            // The network half is exercised elsewhere.
            let result = take_json(finish_conceal(
                &*handle,
                Concealed {
                    link: "https://example.invalid/secret/abc".to_string(),
                    receipt_id: "rcpt-1".to_string(),
                },
                Concealable::Chip(ChipId::from_raw(chip_id)),
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

    #[test]
    fn concealing_a_whole_page_leaves_one_sent_record() {
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

            // The network half is exercised elsewhere.
            let result = take_json(finish_conceal(
                &*handle,
                Concealed {
                    link: "https://example.invalid/secret/abc".to_string(),
                    receipt_id: "rcpt-page".to_string(),
                },
                Concealable::Page(SheetId::from_raw(sheet)),
            ));
            assert!(result.contains("\"ok\":true"), "{result}");

            let ledger = take_json(companion_ledger_json(handle));
            assert!(!ledger.contains("n0ts3cr3t"), "{ledger}");
            let records: Vec<serde_json::Value> = serde_json::from_str(&ledger).unwrap();
            let sent: Vec<&serde_json::Value> =
                records.iter().filter(|r| r["event"] == "sent").collect();
            assert_eq!(sent.len(), 1, "one page conceal, one record: {ledger}");
            assert_eq!(sent[0]["destination"], "link");
            assert_eq!(sent[0]["title"], "rotate on friday");
            assert_eq!(sent[0]["size"], "tiny");
            // The page's identity, not the chip's.
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

    /// The first slot's remaining milliseconds, or `None` when it holds no page.
    unsafe fn first_remaining_ms(handle: *mut CompanionHandle) -> Option<u64> {
        let sheets: Vec<serde_json::Value> =
            serde_json::from_str(&unsafe { take_json(companion_tabs_json(handle)) }).unwrap();
        let first = sheets.first()?;
        if first["has_page"].as_bool() != Some(true) {
            return None;
        }
        first["remaining_ms"].as_u64()
    }

    /// Pinned as pure arithmetic, independent of the host clock.
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

    #[test]
    fn a_stamp_from_the_future_reads_as_no_time_away() {
        assert_eq!(wall_away_ms(41, 42), 0);
    }

    /// A restart must return live pages, drained by the wall gap, with their
    /// ink (issue #44).
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
            let doc = cstring(r##"[{"ink": "# the ink that outlives the boot\n"}]"##);
            assert!(companion_sheet_sync_document(first, sheet, doc.as_ptr()));
            let remaining_before = first_remaining_ms(first).unwrap();

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
            let document = take_json(companion_sheet_document_json(second, sheet));
            assert!(
                document.contains("the ink that outlives the boot"),
                "the restart brought the page back empty: {document}"
            );
            companion_free(second);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

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
            // An empty page dies without a ledger record, so give it ink.
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

    /// In the shell's launch order the content restore records overnight
    /// deaths before the ledger restore runs; those must survive it.
    #[test]
    fn a_death_while_away_survives_the_ledger_restore_that_follows_it() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let state_path = dir.join("state.sealed");
        let ledger_path = dir.join("ledger.sealed");
        let c_state = cstring(state_path.to_str().unwrap());
        let c_ledger = cstring(ledger_path.to_str().unwrap());
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            let (tab, sheet) = new_page(first);
            assert!(companion_sheet_sync_document(
                first,
                sheet,
                cstring(r##"[{"ink": "# perishable\n"}]"##).as_ptr()
            ));
            assert!(companion_tab_set_rung(first, tab, 0)); // the 1h rung
            assert!(companion_ledger_save(first, c_ledger.as_ptr()));
            let evening = take_json(companion_ledger_json(first));
            assert!(evening.contains("\"created\""), "{evening}");
            assert!(!evening.contains("\"expired\""), "{evening}");
            let sealed_wall_ms = wall_now_ms().unwrap() - 24 * 60 * 60 * 1_000;
            let snapshot = {
                let guard = (*first).inner.lock().unwrap();
                guard.store.snapshot(sealed_wall_ms)
            };
            let key = persist::ensure_state_key(&*credentials, &state_path).unwrap();
            let sealed = persist::seal_state(&key, &snapshot, sealed_wall_ms).unwrap();
            assert!(persist::write_private(&state_path, &sealed));
            companion_free(first);

            let second = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_restore(second, c_state.as_ptr()));
            assert!(companion_ledger_restore(second, c_ledger.as_ptr()));
            let morning = take_json(companion_ledger_json(second));
            assert!(
                morning.contains("\"expired\""),
                "the ledger file overwrote the death the restore had just recorded: {morning}"
            );
            assert!(
                morning.contains("\"created\""),
                "the merge lost the file's own history: {morning}"
            );
            assert!(companion_ledger_save(second, c_ledger.as_ptr()));
            companion_free(second);

            let third = handle_with(Arc::clone(&credentials));
            assert!(companion_ledger_restore(third, c_ledger.as_ptr()));
            assert_eq!(take_json(companion_ledger_json(third)), morning);
            // Reading the same file twice does not double the trail.
            assert!(companion_ledger_restore(third, c_ledger.as_ptr()));
            assert_eq!(take_json(companion_ledger_json(third)), morning);
            companion_free(third);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Issue #51: a restore that cannot open a file must not destroy it.
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
            // Skip the version digit: flipping it names a superseded format, tested apart.
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

    #[test]
    fn a_locked_keychain_refuses_the_restore_and_leaves_the_directory_alone() {
        let credentials = Arc::new(persist::test_stores::GoesSilent::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        let state_directory = || {
            let mut files: Vec<(std::ffi::OsString, Vec<u8>)> = std::fs::read_dir(&dir)
                .unwrap()
                .map(|entry| {
                    let entry = entry.unwrap();
                    (entry.file_name(), std::fs::read(entry.path()).unwrap())
                })
                .collect();
            files.sort();
            files
        };
        unsafe {
            let evening = handle_with(Arc::clone(&credentials) as Arc<dyn CredentialStore>);
            let (_tab, sheet) = new_page(evening);
            let _ = take_json(companion_sheet_seal_text(
                evening,
                sheet,
                cstring("hunter2-the-sealed-bytes").as_ptr(),
                0,
                0,
            ));
            assert!(companion_persist_save(evening, c_path.as_ptr()));
            companion_free(evening);
            let sealed = state_directory();
            assert!(sealed.len() >= 2, "a sealed file and a file half");

            credentials.lock();
            let morning = handle_with(Arc::clone(&credentials) as Arc<dyn CredentialStore>);
            assert!(
                !companion_persist_restore(morning, c_path.as_ptr()),
                "a locked keychain restored a file it could not have keyed"
            );
            companion_free(morning);
            assert_eq!(
                state_directory(),
                sealed,
                "the restore that could not read the state directory wrote to it anyway"
            );
            assert!(
                credentials.behind_the_lock().exists("state-key").unwrap(),
                "a restore that never read the keychain half deleted it"
            );

            // The refusal cost the content nothing.
            credentials.unlock();
            let after = handle_with(Arc::clone(&credentials) as Arc<dyn CredentialStore>);
            assert!(
                companion_persist_restore(after, c_path.as_ptr()),
                "the locked session left the file unreadable"
            );
            assert!(first_remaining_ms(after).is_some(), "the page came back");
            companion_free(after);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

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
            // The disposal leaves the keychain half; the superseded arm relies on it.
            assert!(
                credentials
                    .key_material_store()
                    .exists("state-key")
                    .unwrap(),
                "the disposal rotated the keychain half; the arm's reasoning and its ADR-0004 \
                 justification both assume it does not"
            );
            assert!(companion_persist_save(second, c_path.as_ptr()));
            companion_free(second);
            let third = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_restore(third, c_path.as_ptr()));
            companion_free(third);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_superseded_ledger_payload_is_dropped_so_the_session_can_record() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("ledger.sealed");
        let c_path = cstring(path.to_str().unwrap());
        // Re-sealed under the real key, so the envelope authenticates and the
        // refusal is the core's.
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

    /// Disposal covers only this app's own past output.
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

    /// Only key material moves to the key store; the API token stays (ADR-0012).
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

    #[test]
    fn the_ledger_save_path_evicts_before_it_snapshots() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let ledger_path = dir.join("ledger.sealed");
        let c_ledger = cstring(ledger_path.to_str().unwrap());

        // November 2023 (the manual clock's base), far outside the window.
        let stale = {
            let mut aged = SheetStore::new(companion_core::ManualClock::new());
            aged.new_tab();
            aged.ledger_snapshot()
        };
        let stale_wall_ms = 1_700_000_000_000;

        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            {
                let mut guard = (*handle).inner.lock().unwrap();
                // Loaded as of its writing, so the load path's own sweep keeps it.
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

            // The generation the pages lived in no longer opens.
            std::fs::write(&path, &generation_holding_the_pages).unwrap();
            let ghost = handle_with(Arc::clone(&credentials));
            assert!(
                !companion_persist_restore(ghost, c_path.as_ptr()),
                "a generation sealed before the rotation opened after it"
            );
            companion_free(ghost);

            // The reseal itself comes back whole.
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

    /// Rotation follows the state, not the transition (persistence
    /// decision background section 6).
    #[test]
    fn a_second_write_over_a_pad_that_is_still_empty_rotates_again() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            let (tab, _page) = new_page(handle);
            assert!(companion_tab_set_title(
                handle,
                tab,
                cstring("payroll").as_ptr()
            ));
            assert!(companion_tab_set_rung(handle, tab, 0)); // 1h
            assert!(companion_persist_save(handle, c_path.as_ptr()));

            age_by(handle, 2 * 60 * 60 * 1_000);
            assert_eq!(companion_expire_due(handle), 1);
            let empty_pad = |handle: *mut CompanionHandle| {
                let mut holds_no_page = false;
                let mut has_no_tabs = true;
                assert!(companion_store_emptiness(
                    handle,
                    &raw mut holds_no_page,
                    &raw mut has_no_tabs
                ));
                holds_no_page && !has_no_tabs
            };
            assert!(empty_pad(handle), "the trigger's own state");

            assert!(companion_persist_rotate_and_save(handle, c_path.as_ptr()));
            let key_of_the_first_strip = persist::load_state_key(&*credentials, &path)
                .expect("the reseal minted fresh halves")
                .to_vec();
            let first_strip = std::fs::read(&path).unwrap();

            assert!(empty_pad(handle), "the pad filled itself between writes");
            assert!(companion_persist_rotate_and_save(handle, c_path.as_ptr()));
            let key_of_the_second_strip = persist::load_state_key(&*credentials, &path)
                .expect("the second reseal minted fresh halves")
                .to_vec();
            let second_strip = std::fs::read(&path).unwrap();
            assert_ne!(
                key_of_the_first_strip, key_of_the_second_strip,
                "the second write over an empty pad kept the first one's halves"
            );

            // The first write's generation no longer opens either.
            std::fs::write(&path, &first_strip).unwrap();
            let ghost = handle_with(Arc::clone(&credentials));
            assert!(
                !companion_persist_restore(ghost, c_path.as_ptr()),
                "the generation the first reseal wrote opened after the second"
            );
            companion_free(ghost);

            // And the strip survives being rewritten twice.
            std::fs::write(&path, &second_strip).unwrap();
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

    /// A half zeroed but not unlinked has already forgotten, so the reseal
    /// proceeds; a false then means only that its write did not land.
    #[cfg(unix)]
    #[test]
    fn a_reseal_that_could_not_unlink_the_half_has_still_forgotten() {
        use std::os::unix::fs::PermissionsExt;
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let path = dir.join("state.sealed");
        let c_path = cstring(path.to_str().unwrap());
        let half_lens = |dir: &std::path::Path| -> Vec<u64> {
            let mut lens: Vec<u64> = std::fs::read_dir(dir)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|e| {
                    e.file_name()
                        .to_str()
                        .is_some_and(|n| n.starts_with("ots-companion-key-half-"))
                })
                .map(|e| e.metadata().unwrap().len())
                .collect();
            lens.sort_unstable();
            lens
        };
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            new_page(handle);
            assert!(companion_persist_save(handle, c_path.as_ptr()));
            let sealed_before = std::fs::read(&path).unwrap();
            let key_before = persist::load_state_key(&*credentials, &path)
                .expect("a saved file has a key")
                .to_vec();
            assert_eq!(half_lens(&dir), vec![32]);

            // Read and search, no write: the half zeroes but cannot unlink.
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
            let resealed = companion_persist_rotate_and_save(handle, c_path.as_ptr());
            let carcass = half_lens(&dir);
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();

            // As root, or where the mode is ignored, this branch is unreachable.
            if carcass == vec![0] {
                assert!(
                    !resealed,
                    "a reseal whose write could not land reported success"
                );
                assert!(
                    persist::load_state_key(&*credentials, &path).is_none(),
                    "the old content key survived a rotation that zeroed its half"
                );
                assert_eq!(std::fs::read(&path).unwrap(), sealed_before);

                // The retry lands on fresh halves.
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

    #[cfg(unix)]
    #[test]
    fn a_reseal_that_could_not_touch_the_half_leaves_the_old_generation_alone() {
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
            let halves: Vec<std::path::PathBuf> = std::fs::read_dir(&dir)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|e| {
                    e.file_name()
                        .to_str()
                        .is_some_and(|n| n.starts_with("ots-companion-key-half-"))
                })
                .map(|e| e.path())
                .collect();
            assert_eq!(halves.len(), 1);
            let half = &halves[0];

            // The half can be neither zeroed nor unlinked.
            std::fs::set_permissions(half, std::fs::Permissions::from_mode(0o400)).unwrap();
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
            let resealed = companion_persist_rotate_and_save(handle, c_path.as_ptr());
            // Absent counts as touched: root ignores the modes.
            let untouched = std::fs::metadata(half).is_ok_and(|m| m.len() == 32);
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
            let _ = std::fs::set_permissions(half, std::fs::Permissions::from_mode(0o600));

            // As root, or where the modes are ignored, this branch is unreachable.
            if untouched {
                assert!(!resealed, "a reseal that rotated nothing reported success");
                assert_eq!(std::fs::read(&path).unwrap(), sealed_before);

                // The retry lands on fresh halves.
                assert!(companion_persist_rotate_and_save(handle, c_path.as_ptr()));
                assert_ne!(std::fs::read(&path).unwrap(), sealed_before);
            }
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

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

            // Truncated below the magic: unreadable, and still the content file.
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

    #[cfg(unix)]
    #[test]
    fn a_drop_that_could_not_unlink_the_half_still_forgets_the_content() {
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

            // Read and search, no write: everything zeroes, nothing unlinks.
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
            let dropped = companion_persist_erase(handle, c_path.as_ptr());
            let still_there = path.exists();
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();

            // As root, or where the mode is ignored, this branch is unreachable.
            if still_there {
                assert!(
                    !dropped,
                    "the drop reported the path confirmed absent while the carcass remained"
                );
                // The half and the ciphertext were both zeroed.
                assert!(
                    persist::load_state_key(&*credentials, &path).is_none(),
                    "the content key survived a drop that zeroed its half"
                );
                assert_eq!(
                    std::fs::metadata(&path).unwrap().len(),
                    0,
                    "the kept file still holds the old generation's bytes"
                );

                // The retry finishes the unlink.
                assert!(companion_persist_erase(handle, c_path.as_ptr()));
                assert!(!path.exists());
            }
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_drop_that_could_not_touch_the_half_keeps_the_content_file() {
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
            let halves: Vec<std::path::PathBuf> = std::fs::read_dir(&dir)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|e| {
                    e.file_name()
                        .to_str()
                        .is_some_and(|n| n.starts_with("ots-companion-key-half-"))
                })
                .map(|e| e.path())
                .collect();
            assert_eq!(halves.len(), 1);
            let half = &halves[0];

            // The half can be neither zeroed nor unlinked.
            std::fs::set_permissions(half, std::fs::Permissions::from_mode(0o400)).unwrap();
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
            let dropped = companion_persist_erase(handle, c_path.as_ptr());
            // Absent counts as touched: root ignores the modes.
            let untouched = std::fs::metadata(half).is_ok_and(|m| m.len() == 32);
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
            let _ = std::fs::set_permissions(half, std::fs::Permissions::from_mode(0o600));

            // As root, or where the modes are ignored, this branch is unreachable.
            if untouched {
                assert!(
                    !dropped,
                    "the drop reported success while leaving the ciphertext on disk"
                );
                assert_eq!(
                    std::fs::read(&path).unwrap(),
                    sealed_before,
                    "the drop that refused still went and truncated the file it kept"
                );
                // The retry lands.
                assert!(companion_persist_erase(handle, c_path.as_ptr()));
                assert!(!path.exists());
                assert!(persist::load_state_key(&*credentials, &path).is_none());
            }
            companion_free(handle);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

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

            let second = handle_with(Arc::clone(&credentials));
            assert!(companion_persist_restore(second, c_state.as_ptr()));
            assert!(first_remaining_ms(second).unwrap() > 0);
            companion_free(second);

            // An unreadable ledger file is still not the content file.
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

    #[test]
    fn rotating_and_dropping_the_content_key_leave_the_ledger_key_alone() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let dir = scratch_dir();
        let state_path = dir.join("state.sealed");
        let ledger_path = dir.join("ledger.sealed");
        let c_state = cstring(state_path.to_str().unwrap());
        let c_ledger = cstring(ledger_path.to_str().unwrap());
        unsafe {
            let first = handle_with(Arc::clone(&credentials));
            new_page(first);
            assert!(companion_persist_save(first, c_state.as_ptr()));
            assert!(companion_ledger_save(first, c_ledger.as_ptr()));
            let written = take_json(companion_ledger_json(first));
            let ledger_key = persist::load_ledger_key(&*credentials)
                .expect("a saved ledger has a key")
                .to_vec();

            assert!(companion_persist_rotate_and_save(first, c_state.as_ptr()));
            assert!(companion_persist_erase(first, c_state.as_ptr()));
            companion_free(first);

            assert_eq!(
                *persist::load_ledger_key(&*credentials).expect("the ledger key survived"),
                ledger_key
            );
            let second = handle_with(Arc::clone(&credentials));
            assert!(companion_ledger_restore(second, c_ledger.as_ptr()));
            assert_eq!(take_json(companion_ledger_json(second)), written);
            companion_free(second);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A fresh temp directory; a failing test leaves it for inspection.
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
            // Different keys and associated data: neither opens as the other.
            assert!(!companion_persist_restore(second, c_ledger.as_ptr()));
            assert!(!companion_ledger_restore(second, c_state.as_ptr()));
            companion_free(second);

            // A different keychain opens nothing; a missing file is a fresh start.
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
            assert!(!companion_chip_set_name(
                ptr::null_mut(),
                1,
                cstring("API_KEY").as_ptr()
            ));
            assert!(!companion_chip_copy_name_value(ptr::null_mut(), 1));
            assert!(companion_chip_note_runs_json(ptr::null_mut(), 1).is_null());
            assert!(!companion_chip_note_can_undo(ptr::null_mut(), 1));
            assert!(!companion_chip_note_can_redo(ptr::null_mut(), 1));
            assert!(companion_chip_note_redo_action_name(ptr::null_mut(), 1).is_null());
            assert!(!companion_chip_note_finish_editing_group(
                ptr::null_mut(),
                1,
                u32::MAX,
                u32::MAX
            ));
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
            assert!(!companion_sync_configure(
                ptr::null_mut(),
                cstring("{}").as_ptr()
            ));
            assert!(companion_sync_status_json(ptr::null_mut()).is_null());
            assert!(companion_sync_gate(ptr::null_mut()).is_null());
            assert!(companion_sync_signin_begin(ptr::null_mut()).is_null());
            assert!(companion_sync_signin_finish(ptr::null_mut(), 0).is_null());
            assert!(!companion_sync_signin_cancel(ptr::null_mut()));
            assert!(!companion_sync_signout(ptr::null_mut()));
            assert!(!companion_sync_enrol_page(ptr::null_mut(), 1, true));
            assert!(companion_sync_attach(ptr::null_mut()).is_null());
            assert!(!companion_sync_detach(ptr::null_mut()));
            assert!(companion_sync_pump(ptr::null_mut(), 0).is_null());
            assert!(companion_sync_devices_json(ptr::null_mut()).is_null());
            assert!(!companion_sync_revoke_peer(
                ptr::null_mut(),
                cstring("fp").as_ptr()
            ));
            assert!(companion_sync_invite_begin(ptr::null_mut()).is_null());
            assert!(companion_sync_join_begin(ptr::null_mut()).is_null());
            assert!(companion_sync_pairing_poll(ptr::null_mut()).is_null());
            assert!(companion_sync_pairing_confirm(ptr::null_mut(), true).is_null());
            assert!(!companion_sync_pairing_cancel(ptr::null_mut()));
            companion_free(ptr::null_mut()); // no-op
            companion_string_free(ptr::null_mut()); // no-op
        }
    }

    #[test]
    fn a_second_attach_while_one_is_in_flight_is_refused_as_busy() {
        // Two attaches at once would each mint a package, and the relay
        // keeps whichever arrives last while this device could adopt
        // the other. The second is refused, and the first, done, lets
        // the next one through.
        let handle = handle();
        unsafe {
            (*handle).inner.lock().unwrap().sync.attaching = true;
            let busy: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_attach(handle))).unwrap();
            assert_eq!(busy["reason"], "busy");
            assert!((*handle).inner.lock().unwrap().sync.attaching);

            (*handle).inner.lock().unwrap().sync.attaching = false;
            let unconfigured: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_attach(handle))).unwrap();
            assert_eq!(unconfigured["reason"], "not_configured");
            assert!(
                !(*handle).inner.lock().unwrap().sync.attaching,
                "an attach that refused still lets the next one through"
            );
            companion_free(handle);
        }
    }

    /// The sign-in surface through the seam itself: configure resumes
    /// the persisted sign-in, begin parks a ceremony, cancel forgets
    /// it, and sign-out deletes the one account — status telling the
    /// truth at every step.
    #[test]
    fn the_sync_routes_report_configure_begin_cancel_and_signout() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        credentials
            .key_material_store()
            .store("sync-oauth-refresh", b"rt-persisted")
            .unwrap();
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            let status: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_status_json(handle))).unwrap();
            assert_eq!(status["configured"], false);
            assert_eq!(
                status["signed_in"], true,
                "existence check before configure"
            );
            assert_eq!(
                status["gate"], "off",
                "a resting token does not make an unconfigured handle anything but off"
            );
            assert_eq!(take_json(companion_sync_gate(handle)), "off");

            let unconfigured: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_begin(handle))).unwrap();
            assert_eq!(unconfigured["reason"], "not_configured");
            let config = cstring(
                r#"{"relay_url":"https://relay.example",
                    "authorize_url":"https://eu.example/oauth/authorize",
                    "token_url":"https://eu.example/oauth/token",
                    "client_id":"companion"}"#,
            );
            assert!(companion_sync_configure(handle, config.as_ptr()));
            let status: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_status_json(handle))).unwrap();
            assert_eq!(status["configured"], true);
            assert_eq!(status["signed_in"], true, "the keeper resumed the token");
            assert_eq!(
                status["gate"], "ready",
                "configured, credentialed, unattached"
            );

            let begun: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_begin(handle))).unwrap();
            assert_eq!(begun["ok"], true);
            let authorize_url = begun["authorize_url"].as_str().unwrap();
            assert!(authorize_url.starts_with("https://eu.example/oauth/authorize?"));
            assert!(authorize_url.contains("code_challenge_method=S256"));
            let busy: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_begin(handle))).unwrap();
            assert_eq!(busy["reason"], "busy");
            assert!(companion_sync_signin_cancel(handle));
            assert!(
                !companion_sync_signin_cancel(handle),
                "nothing left to forget"
            );

            // A finish behind a cancel finds nothing, and the flag the
            // cancel raised went with the ceremony it ended, so this
            // is the honest answer rather than a guess at which of the
            // two reasons it was. `no_ceremony` is never a server's
            // word and has a sentence of its own in the shell, which
            // is also where the give-up is remembered for exactly one
            // settling. (The gate through the whole ceremony is its
            // own test, `the_gate_says_signing_in_while_the_browser_is_out`.)
            let finished: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_finish(handle, 0))).unwrap();
            assert_eq!(finished["reason"], "no_ceremony");

            // A finish nobody began and nobody cancelled is a caller
            // out of order, and keeps the same name, because a flag
            // that lived on the last ceremony cannot colour this one.
            let begun: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_begin(handle))).unwrap();
            assert_eq!(begun["ok"], true, "a fresh begin clears the surrender");
            assert!(companion_sync_signin_cancel(handle));
            let _ = take_json(companion_sync_signin_finish(handle, 0));
            let begun: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_begin(handle))).unwrap();
            assert_eq!(begun["ok"], true);
            let taken = take_json(companion_sync_signin_finish(handle, 0));
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(&taken).unwrap()["reason"],
                "abandoned",
                "no redirect came in no patience at all"
            );
            let orphaned: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_finish(handle, 0))).unwrap();
            assert_eq!(orphaned["reason"], "no_ceremony");

            assert!(companion_sync_signout(handle));
            let status: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_status_json(handle))).unwrap();
            assert_eq!(status["signed_in"], false);
            assert_eq!(
                status["gate"], "signed_out",
                "the user's own sign-out is not a refusal"
            );
            assert!(
                matches!(
                    credentials
                        .key_material_store()
                        .exists("sync-oauth-refresh"),
                    Ok(false)
                ),
                "sign-out deleted the persisted token"
            );
            companion_free(handle);
        }
    }

    fn sync_configured(handle: *mut CompanionHandle) {
        let config = cstring(
            r#"{"relay_url":"https://relay.example",
                "authorize_url":"https://eu.example/oauth/authorize",
                "token_url":"https://eu.example/oauth/token",
                "client_id":"companion"}"#,
        );
        assert!(unsafe { companion_sync_configure(handle, config.as_ptr()) });
    }

    #[test]
    fn configuring_sync_names_the_identity_at_rest_as_the_name_writer_and_mints_none() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        let writer =
            |handle: *mut CompanionHandle| unsafe { &*handle }.inner.lock().unwrap().store.writer();
        let handle = handle_with(Arc::clone(&credentials));
        sync_configured(handle);
        assert_eq!(writer(handle), [0; 32], "no identity at rest, so no writer");
        assert!(
            pairing::stored_device_fingerprint(&*credentials).is_none(),
            "configuring minted an identity"
        );

        let fingerprint = pairing::device_fingerprint(&*credentials).unwrap();
        sync_configured(handle);
        assert_eq!(persist::hex_encode(&writer(handle)), fingerprint);
        unsafe { companion_free(handle) };
    }

    /// Wait until the finish call has actually taken the ceremony and
    /// is blocked on the redirect. Polling the gate is not enough: it
    /// reads `signing_in` from the moment the begin mints the
    /// ceremony, so the assertions below would otherwise race the
    /// thread they are about.
    fn wait_for_browser_trip(handle: *mut CompanionHandle) {
        for _ in 0..500 {
            let taken = unsafe { &*handle }
                .inner
                .lock()
                .is_ok_and(|guard| guard.sync.awaiting_redirect.is_some());
            if taken {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("the finish never took the ceremony");
    }

    #[test]
    fn signing_out_ends_a_browser_trip_that_is_still_out() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            sync_configured(handle);
            let begun: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_begin(handle))).unwrap();
            assert_eq!(begun["ok"], true);

            let address = handle as usize;
            let waiting = std::thread::spawn(move || {
                let handle = address as *mut CompanionHandle;
                take_json(companion_sync_signin_finish(handle, 10_000))
            });
            wait_for_browser_trip(handle);

            // The user signs sync out while the consent screen is open.
            companion_sync_signout(handle);
            assert_eq!(
                take_json(companion_sync_gate(handle)),
                "signed_out",
                "the gesture takes effect at once, not when the browser gets round to it"
            );

            // Sign-out raises this ceremony's abandon flag. The listener
            // reads it inside its poll and gives up, so the finish returns
            // abandoned rather than waiting out its patience. The redirect
            // arriving after that buys nothing; the driver test
            // a_give_up_during_the_exchange_stores_nothing holds that case
            // without the race this test used to carry.
            let late: serde_json::Value = serde_json::from_str(&waiting.join().unwrap()).unwrap();
            assert_eq!(
                late["reason"], "abandoned",
                "a redirect after the sign-out is not a state mismatch and not a network fault"
            );
            assert!(
                matches!(
                    credentials
                        .key_material_store()
                        .exists("sync-oauth-refresh"),
                    Ok(false)
                ),
                "no grant may land after the account was removed"
            );
            assert_eq!(take_json(companion_sync_gate(handle)), "signed_out");
            companion_free(handle);
        }
    }

    #[test]
    fn a_second_call_during_a_browser_trip_neither_begins_nor_stomps() {
        unsafe {
            let handle = handle();
            sync_configured(handle);
            assert!(
                serde_json::from_str::<serde_json::Value>(&take_json(companion_sync_signin_begin(
                    handle
                )))
                .unwrap()["ok"]
                    == true
            );

            let address = handle as usize;
            let waiting = std::thread::spawn(move || {
                let handle = address as *mut CompanionHandle;
                take_json(companion_sync_signin_finish(handle, 300))
            });
            wait_for_browser_trip(handle);

            // A second finish used to find no pending ceremony, clear
            // the state on its way out and answer `no_ceremony`, which
            // put the gate back to signed out mid consent screen.
            let second: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_finish(handle, 0))).unwrap();
            assert_eq!(second["reason"], "busy");
            assert_eq!(
                take_json(companion_sync_gate(handle)),
                "signing_in",
                "the second call answers for itself and leaves the first ceremony alone"
            );

            // And a begin may not bind a second listener behind the
            // first browser trip.
            let again: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_begin(handle))).unwrap();
            assert_eq!(again["reason"], "busy");

            let ended: serde_json::Value = serde_json::from_str(&waiting.join().unwrap()).unwrap();
            assert_eq!(ended["reason"], "abandoned");
            assert_eq!(take_json(companion_sync_gate(handle)), "signed_out");
            companion_free(handle);
        }
    }

    #[test]
    fn the_gate_says_signing_in_while_the_browser_is_out() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            let config = cstring(
                r#"{"relay_url":"https://relay.example",
                    "authorize_url":"https://eu.example/oauth/authorize",
                    "token_url":"https://eu.example/oauth/token",
                    "client_id":"companion"}"#,
            );
            assert!(companion_sync_configure(handle, config.as_ptr()));
            assert_eq!(take_json(companion_sync_gate(handle)), "signed_out");
            let begun: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_begin(handle))).unwrap();
            assert_eq!(begun["ok"], true);
            assert_eq!(
                take_json(companion_sync_gate(handle)),
                "signing_in",
                "the ceremony is minted and waiting for its finish"
            );

            // The finish takes the ceremony and blocks on the redirect
            // that never comes. Through the whole consent screen the
            // gate has to keep saying so: a browser is open on the
            // user's screen, and "signed out" would be a state the app
            // has already left.
            let address = handle as usize;
            let waiting = std::thread::spawn(move || {
                let handle = address as *mut CompanionHandle;
                take_json(companion_sync_signin_finish(handle, 1_000))
            });
            let mut seen = String::new();
            for _ in 0..40 {
                std::thread::sleep(Duration::from_millis(10));
                seen = take_json(companion_sync_gate(handle));
                if seen == "signing_in" {
                    break;
                }
            }
            assert_eq!(seen, "signing_in", "the browser step is a state of its own");

            let abandoned: serde_json::Value = serde_json::from_str(&waiting.join().unwrap())
                .expect("the finish answers even when the browser does not");
            assert_eq!(abandoned["reason"], "abandoned");
            assert_eq!(
                take_json(companion_sync_gate(handle)),
                "signed_out",
                "and the ceremony's end takes the state with it"
            );
            companion_free(handle);
        }
    }

    #[test]
    fn a_cancel_ends_a_browser_trip_that_is_still_out() {
        let credentials: Arc<dyn CredentialStore> =
            Arc::new(companion_credentials::InMemoryCredentialStore::default());
        unsafe {
            let handle = handle_with(Arc::clone(&credentials));
            let config = cstring(
                r#"{"relay_url":"https://relay.example",
                    "authorize_url":"https://eu.example/oauth/authorize",
                    "token_url":"https://eu.example/oauth/token",
                    "client_id":"companion"}"#,
            );
            assert!(companion_sync_configure(handle, config.as_ptr()));
            let begun: serde_json::Value =
                serde_json::from_str(&take_json(companion_sync_signin_begin(handle))).unwrap();
            assert_eq!(begun["ok"], true);

            // Five minutes of patience, the budget a consent screen
            // gets. The user closes the tab instead and comes back to
            // the app, and the way out has to be the ceremony ending
            // rather than a button that only looks like one
            // (account-auth decision background §5, `signing_in`).
            let address = handle as usize;
            let waiting = std::thread::spawn(move || {
                let handle = address as *mut CompanionHandle;
                take_json(companion_sync_signin_finish(handle, 300_000))
            });
            for _ in 0..200 {
                std::thread::sleep(Duration::from_millis(10));
                if take_json(companion_sync_gate(handle)) == "signing_in" {
                    break;
                }
            }
            assert_eq!(take_json(companion_sync_gate(handle)), "signing_in");
            let began = std::time::Instant::now();
            assert!(
                companion_sync_signin_cancel(handle),
                "a trip that is out is something to give up on"
            );
            let given_up: serde_json::Value =
                serde_json::from_str(&waiting.join().unwrap()).unwrap();
            assert_eq!(given_up["ok"], false);
            assert_eq!(given_up["reason"], "abandoned");
            assert!(
                began.elapsed() < Duration::from_secs(30),
                "the wait ends on the cancel, not on the patience"
            );
            assert_eq!(
                take_json(companion_sync_gate(handle)),
                "signed_out",
                "nothing was stored, so the gate reads what stands"
            );
            assert!(
                !companion_sync_signin_cancel(handle),
                "with nothing in flight there is nothing to give up, and the surface stops offering it"
            );
            companion_free(handle);
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

    /// Each route answers for the untagged id and refuses the tagged one, so
    /// the guard is not merely failing on unknown ids.
    #[test]
    fn page_routes_refuse_a_file_id() {
        unsafe {
            let handle = handle();
            let (_tab, page) = new_page(handle);
            let tagged = page | companion_core::FILE_ID_TAG;
            assert!(is_file_id(tagged));
            assert!(!is_file_id(page));

            let ops = cstring(r#"[{"ins": {"at": 0, "text": "hello"}}]"#);
            assert!(companion_sheet_apply_ops(handle, page, ops.as_ptr()));
            assert!(!companion_sheet_apply_ops(handle, tagged, ops.as_ptr()));
            assert!(!companion_sheet_apply_ops_as_new_step(
                handle,
                tagged,
                ops.as_ptr()
            ));
            assert!(!companion_sheet_apply_ops_with_intent(
                handle,
                tagged,
                ops.as_ptr(),
                0,
                u32::MAX,
                u32::MAX,
                u32::MAX,
                u32::MAX
            ));
            assert!(!companion_sheet_finish_editing_group(
                handle,
                tagged,
                u32::MAX,
                u32::MAX
            ));

            let runs = take_json(companion_sheet_document_json(handle, page));
            assert!(runs.contains("hello"));
            assert!(companion_sheet_document_json(handle, tagged).is_null());
            assert!(companion_sheet_meta_json(handle, tagged).is_null());
            assert!(companion_sheet_blocks_json(handle, tagged).is_null());

            assert!(companion_sheet_can_undo(handle, page));
            assert!(!companion_sheet_can_undo(handle, tagged));
            assert!(!companion_sheet_can_redo(handle, tagged));
            assert!(companion_sheet_undo_action_name(handle, tagged).is_null());
            assert!(companion_sheet_redo_action_name(handle, tagged).is_null());
            assert!(!companion_sheet_undo(handle, tagged));
            assert!(!companion_sheet_redo(handle, tagged));
            assert_eq!(companion_sheet_undo_caret_u16(handle, tagged), -1);

            let doc = cstring(r#"[{"ink": "hello"}]"#);
            assert!(companion_sheet_sync_document(handle, page, doc.as_ptr()));
            assert!(!companion_sheet_sync_document(handle, tagged, doc.as_ptr()));

            seed(handle, "a secret");
            let mut cleared = false;
            assert!(
                companion_sheet_seal_from_pasteboard(handle, tagged, 0, 0, &raw mut cleared)
                    .is_null()
            );
            assert!(!cleared);
            let text = cstring("a secret");
            assert!(companion_sheet_seal_text(handle, tagged, text.as_ptr(), 0, 0).is_null());
            assert!(companion_sheet_seal_from_drag(handle, tagged, 0, 0).is_null());

            let opts = cstring("{}");
            assert!(companion_sheet_conceal(handle, tagged, opts.as_ptr()).is_null());

            assert!(companion_sheet_copy_fragment(handle, tagged, 0, 1).is_null());
            assert!(companion_sheet_cut_fragment(handle, tagged, 0, 1).is_null());
            let plain = cstring("x");
            assert!(
                companion_sheet_paste_fragment(
                    handle,
                    tagged,
                    0,
                    0,
                    ptr::null(),
                    0,
                    plain.as_ptr()
                )
                .is_null()
            );
            assert!(companion_sheet_paste_active_cut(handle, tagged, 0, 0).is_null());
            assert!(companion_sheet_move_range(handle, tagged, 0, 1, 3).is_null());
            assert!(companion_sheet_clone_range(handle, tagged, 0, 1, 3).is_null());
            assert!(companion_sheet_move_range_to(handle, tagged, 0, 1, page, 0).is_null());
            assert!(companion_sheet_move_range_to(handle, page, 0, 1, tagged, 0).is_null());

            let after = take_json(companion_sheet_document_json(handle, page));
            assert!(after.contains("hello"));

            companion_free(handle);
        }
    }

    unsafe fn json_of(p: *mut c_char) -> serde_json::Value {
        serde_json::from_str(&unsafe { take_json(p) }).unwrap()
    }

    /// A page reading `ab`, a sealed chip, `cd`: five units.
    unsafe fn page_with_a_chip(handle: *mut CompanionHandle, secret: &str) -> (u64, u64) {
        let (_, sheet) = unsafe { new_page(handle) };
        let chip = unsafe {
            json_of(companion_sheet_seal_text(
                handle,
                sheet,
                cstring(secret).as_ptr(),
                0,
                0,
            ))
        }["chip_id"]
            .as_u64()
            .unwrap();
        let ops =
            cstring(r#"[{"ins": {"at": 0, "text": "ab"}}, {"ins": {"at": 3, "text": "cd"}}]"#);
        assert!(unsafe { companion_sheet_apply_ops(handle, sheet, ops.as_ptr()) });
        (sheet, chip)
    }

    unsafe fn paste(
        handle: *mut CompanionHandle,
        sheet: u64,
        at: u32,
        envelope: &str,
    ) -> serde_json::Value {
        unsafe {
            json_of(companion_sheet_paste_fragment(
                handle,
                sheet,
                at,
                0,
                envelope.as_ptr(),
                envelope.len(),
                ptr::null(),
            ))
        }
    }

    #[test]
    fn copy_cut_and_paste_carry_the_envelope_unread_over_the_seam() {
        let handle = handle();
        unsafe {
            let (sheet, chip) = page_with_a_chip(handle, "hunter2-secret");
            let (_, other) = new_page(handle);

            let copied = json_of(companion_sheet_copy_fragment(handle, sheet, 0, 5));
            assert_eq!(copied["plain"], "ab[sealed content \u{b7} tiny]cd");
            let envelope = copied["envelope"].as_str().unwrap().to_string();
            assert!(!envelope.contains("hunter2"), "{envelope}");
            let placed = paste(handle, other, 0, &envelope);
            assert_eq!(placed["cloned"], 1);
            assert_eq!(placed["length_utf16"], 5);
            assert_eq!(placed["unreadable"], false);

            let ink = json_of(companion_sheet_copy_fragment(handle, sheet, 0, 2));
            assert!(ink["envelope"].is_null(), "ink alone writes no envelope");

            let cut = json_of(companion_sheet_cut_fragment(handle, sheet, 2, 1));
            let slot = json_of(companion_active_cut_json(handle));
            assert_eq!(slot["page_id"], sheet);
            assert_eq!(slot["objects"][0]["chip_id"], chip);
            assert!(
                slot["objects"][0].get("excerpt").is_some(),
                "a face, never payload"
            );
            let placed = paste(handle, other, 5, cut["envelope"].as_str().unwrap());
            assert_eq!(placed["reattached"], 1);
            let slot = json_of(companion_active_cut_json(handle));
            assert!(slot["page_id"].is_null());
            assert_eq!(slot["objects"], serde_json::json!([]));

            companion_free(handle);
        }
    }

    #[test]
    fn a_shown_selection_composes_over_the_seam_as_the_pages_own_would() {
        let handle = handle();
        unsafe {
            let (sheet, chip) = page_with_a_chip(handle, "hunter2-secret");
            let shown = cstring(&format!(
                r#"[{{"ink":"Heading\n"}},{{"chip":{chip}}},{{"ink":" cd"}}]"#
            ));
            let copied = json_of(companion_sheet_compose_fragment(
                handle,
                sheet,
                shown.as_ptr(),
            ));
            assert_eq!(copied["plain"], "Heading\n[sealed content \u{b7} tiny] cd");
            let envelope = copied["envelope"].as_str().unwrap().to_string();
            assert!(!envelope.contains("hunter2"), "{envelope}");
            let composed: serde_json::Value = serde_json::from_str(&envelope).unwrap();
            assert_eq!(
                composed["nodes"][0]["ink"], "Heading\n",
                "the shown text is the ink"
            );
            let own = json_of(companion_sheet_copy_fragment(handle, sheet, 2, 1));
            let own: serde_json::Value =
                serde_json::from_str(own["envelope"].as_str().unwrap()).unwrap();
            assert_eq!(composed["nodes"][1], own["nodes"][0], "the same reference");

            let ink = cstring(r#"[{"ink":"ab"}]"#);
            let ink = json_of(companion_sheet_compose_fragment(
                handle,
                sheet,
                ink.as_ptr(),
            ));
            assert!(ink["envelope"].is_null(), "ink alone writes no envelope");
            assert_eq!(ink["plain"], "ab");

            let (_, other) = new_page(handle);
            let object = cstring(&format!(r#"[{{"chip":{chip}}}]"#));
            assert!(
                companion_sheet_compose_fragment(handle, other, object.as_ptr()).is_null(),
                "an object off the page"
            );
            let nonsense = cstring("nonsense");
            assert!(companion_sheet_compose_fragment(handle, sheet, nonsense.as_ptr()).is_null());
            assert!(companion_sheet_compose_fragment(handle, sheet, ptr::null()).is_null());
            let empty = cstring("[]");
            assert!(companion_sheet_compose_fragment(handle, sheet, empty.as_ptr()).is_null());
            companion_free(handle);
        }
    }

    #[test]
    fn a_copy_or_cut_past_an_envelope_cap_names_the_cap_over_the_seam() {
        let handle = handle();
        unsafe {
            let (long, _) = page_with_a_chip(handle, "hunter2-secret");
            let ink = "x".repeat(EnvelopeCap::Length.limit());
            let ops = cstring(&format!(r#"[{{"ins": {{"at": 0, "text": "{ink}"}}}}]"#));
            assert!(companion_sheet_apply_ops(handle, long, ops.as_ptr()));
            let whole = u32::try_from(ink.len() + 5).unwrap();
            let before = take_json(companion_sheet_document_json(handle, long));

            let refused = serde_json::json!({ "error": "tooLarge", "limit": 8_388_608 });
            let copied = json_of(companion_sheet_copy_fragment(handle, long, 0, whole));
            assert_eq!(copied, refused, "no plain to write either");
            let cut = json_of(companion_sheet_cut_fragment(handle, long, 0, whole));
            assert_eq!(cut, refused);
            let after = take_json(companion_sheet_document_json(handle, long));
            assert!(after == before, "the cut changed nothing");
            assert!(json_of(companion_active_cut_json(handle))["page_id"].is_null());
            let ink_alone = json_of(companion_sheet_copy_fragment(handle, long, 0, whole - 5));
            assert!(ink_alone["envelope"].is_null(), "ink alone meets no cap");

            companion_free(handle);
        }
    }

    #[test]
    fn each_cap_crosses_the_seam_as_its_own_token_and_limit() {
        unsafe {
            let length = copy_outcome_json(Err(CopyRefusal::PastCap(EnvelopeCap::Length)));
            assert_eq!(
                json_of(length),
                serde_json::json!({ "error": "tooLarge", "limit": 8_388_608 })
            );
            let objects = copy_outcome_json(Err(CopyRefusal::PastCap(EnvelopeCap::References)));
            assert_eq!(
                json_of(objects),
                serde_json::json!({ "error": "tooManyObjects", "limit": 1024 })
            );
            assert!(copy_outcome_json(Err(CopyRefusal::Refused)).is_null());
        }
    }

    #[test]
    fn a_paste_sweeps_a_due_page_and_says_how_many_over_the_seam() {
        let handle = handle();
        unsafe {
            let (sheet, _) = page_with_a_chip(handle, "hunter2-secret");
            assert!(companion_tab_set_rung(
                handle,
                strip(handle)[0]["id"].as_u64().unwrap(),
                0
            ));
            let copied = json_of(companion_sheet_copy_fragment(handle, sheet, 0, 5));
            let envelope = copied["envelope"].as_str().unwrap().to_string();
            age_by(handle, 2 * 60 * 60 * 1_000);
            let (_, fresh) = new_page(handle);

            let placed = paste(handle, fresh, 0, &envelope);
            assert_eq!(placed["pages_expired"], 1);
            assert_eq!(
                (placed["cloned"].as_u64(), placed["expired"].as_u64()),
                (Some(0), Some(1))
            );
            assert_eq!(strip(handle)[0]["has_page"].as_bool(), Some(false));
            assert_eq!(
                companion_expire_due(handle),
                0,
                "nothing left for the timer"
            );

            let again = paste(handle, fresh, 0, &envelope);
            assert_eq!(again["pages_expired"], 0);
            companion_free(handle);
        }
    }

    #[test]
    fn an_unreadable_envelope_pastes_its_public_text_over_the_seam() {
        let handle = handle();
        unsafe {
            let (_, sheet) = new_page(handle);
            let garbage = b"not an envelope";
            let plain = cstring("ink [sealed content \u{b7} small]");
            let placed = json_of(companion_sheet_paste_fragment(
                handle,
                sheet,
                0,
                0,
                garbage.as_ptr(),
                garbage.len(),
                plain.as_ptr(),
            ));
            assert_eq!(placed["unreadable"], true);
            let runs = take_json(companion_sheet_document_json(handle, sheet));
            assert!(runs.contains("ink [sealed content"), "{runs}");
            assert!(
                companion_sheet_paste_fragment(handle, sheet, 0, 0, ptr::null(), 0, ptr::null())
                    .is_null(),
                "nothing to place"
            );
            companion_free(handle);
        }
    }

    #[test]
    fn the_slot_move_and_clone_routes_cross_the_seam() {
        let handle = handle();
        unsafe {
            assert!(
                companion_sheet_paste_active_cut(handle, 1, 0, 0).is_null(),
                "no cut"
            );
            let (sheet, chip) = page_with_a_chip(handle, "hunter2-secret");
            assert!(!companion_sheet_cut_fragment(handle, sheet, 0, 3).is_null());
            let placed = json_of(companion_sheet_paste_active_cut(handle, sheet, 2, 0));
            assert_eq!(placed["reattached"], 1);

            // `cd` then `ab` and the chip; move the chip ahead of all.
            let moved = json_of(companion_sheet_move_range(handle, sheet, 4, 1, 0));
            assert_eq!(moved["location_utf16"], 0);
            assert!(companion_chip_copy_out(handle, chip), "the same object");
            assert!(
                companion_sheet_move_range(handle, sheet, 0, 1, 1).is_null(),
                "its own edge"
            );

            let cloned = json_of(companion_sheet_clone_range(handle, sheet, 0, 1, 5));
            assert_eq!(cloned["cloned"], 1);
            let runs = json_of(companion_sheet_document_json(handle, sheet));
            let chips = runs
                .as_array()
                .unwrap()
                .iter()
                .filter(|run| run.get("chip").is_some())
                .count();
            assert_eq!(chips, 2);
            companion_free(handle);
        }
    }

    /// The chip ids standing on a page, in order.
    unsafe fn standing_chips(handle: *mut CompanionHandle, sheet: u64) -> Vec<u64> {
        let runs = unsafe { json_of(companion_sheet_document_json(handle, sheet)) };
        runs.as_array()
            .unwrap()
            .iter()
            .filter_map(|run| run.get("chip")?["chip_id"].as_u64())
            .collect()
    }

    #[test]
    fn a_drag_between_pages_crosses_the_seam_keeping_its_object() {
        let handle = handle();
        unsafe {
            let (home, chip) = page_with_a_chip(handle, "hunter2-secret");
            let (_, away) = new_page(handle);
            assert!(
                companion_sheet_move_range_to(handle, home, 2, 1, home, 0).is_null(),
                "one page"
            );
            assert!(companion_sheet_move_range_to(handle, home, 2, 1, 4_242, 0).is_null());

            let moved = json_of(companion_sheet_move_range_to(handle, home, 1, 3, away, 0));
            assert_eq!(moved["location_utf16"], 0);
            assert_eq!(moved["length_utf16"], 3);
            assert_eq!(moved["reattached"], 1);
            assert_eq!(moved["cloned"], 0);
            assert_eq!(standing_chips(handle, away), [chip], "the same object");
            assert!(standing_chips(handle, home).is_empty());
            assert!(
                !companion_sheet_can_undo(handle, home),
                "no step there stands it again"
            );
            assert!(companion_chip_copy_out(handle, chip));
            companion_free(handle);
        }
    }

    #[test]
    fn a_drag_between_pages_refuses_a_page_past_its_deadline_over_the_seam() {
        let handle = handle();
        unsafe {
            let (due, chip) = a_due_page_with_a_chip(handle);
            let (_, fresh) = new_page(handle);
            assert!(companion_sheet_move_range_to(handle, due, 2, 1, fresh, 0).is_null());
            let ops = cstring(r#"[{"ins": {"at": 0, "text": "x"}}]"#);
            assert!(companion_sheet_apply_ops(handle, fresh, ops.as_ptr()));
            assert!(companion_sheet_move_range_to(handle, fresh, 0, 1, due, 0).is_null());
            assert_eq!(standing_chips(handle, due), [chip], "neither page changed");
            assert!(standing_chips(handle, fresh).is_empty());
            assert_eq!(companion_expire_due(handle), 1, "the sweep still takes it");
            companion_free(handle);
        }
    }

    #[test]
    fn the_fragment_routes_fail_closed() {
        unsafe {
            let null = ptr::null_mut();
            assert!(companion_sheet_copy_fragment(null, 1, 0, 1).is_null());
            assert!(companion_sheet_cut_fragment(null, 1, 0, 1).is_null());
            assert!(
                companion_sheet_paste_fragment(null, 1, 0, 0, ptr::null(), 0, ptr::null())
                    .is_null()
            );
            assert!(companion_sheet_paste_active_cut(null, 1, 0, 0).is_null());
            assert!(companion_sheet_move_range(null, 1, 0, 1, 3).is_null());
            assert!(companion_sheet_clone_range(null, 1, 0, 1, 3).is_null());
            assert!(companion_sheet_move_range_to(null, 1, 0, 1, 2, 0).is_null());
            assert!(companion_active_cut_json(null).is_null());
            let kind = cstring("public.utf8-plain-text");
            assert!(!companion_chip_provide_drag(
                null,
                1,
                null.cast(),
                null.cast(),
                kind.as_ptr()
            ));

            let handle = handle();
            let (sheet, chip) = page_with_a_chip(handle, "hunter2-secret");
            assert!(
                companion_sheet_copy_fragment(handle, 4_242, 0, 1).is_null(),
                "unknown page"
            );
            assert!(
                companion_sheet_copy_fragment(handle, sheet, 0, 99).is_null(),
                "past the body"
            );
            assert!(
                companion_sheet_copy_fragment(handle, sheet, 1, 0).is_null(),
                "empty"
            );
            assert!(companion_sheet_cut_fragment(handle, sheet, 3, 99).is_null());
            let runs = take_json(companion_sheet_document_json(handle, sheet));
            assert!(
                runs.contains("\"ab\"") && runs.contains("\"cd\""),
                "a refused cut cut nothing"
            );
            assert!(!companion_chip_provide_drag(
                handle,
                chip,
                null.cast(),
                null.cast(),
                kind.as_ptr()
            ));
            assert!(!companion_chip_provide_drag(
                handle,
                chip,
                null.cast(),
                null.cast(),
                ptr::null()
            ));
            companion_free(handle);
        }
    }

    fn sent_destinations(handle: *mut CompanionHandle) -> Vec<String> {
        let ledger = unsafe { take_json(companion_ledger_json(handle)) };
        serde_json::from_str::<Vec<serde_json::Value>>(&ledger)
            .unwrap()
            .into_iter()
            .filter(|record| record["event"] == "sent")
            .map(|record| record["destination"].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn a_decrypted_drag_writes_its_item_core_side_and_records_one_sent_to_drag() {
        let handle = handle();
        unsafe {
            let (_, chip) = page_with_a_chip(handle, "hunter2-secret");
            let mut item = companion_pasteboard::MemoryDragItem::new();
            {
                let mut guard = (*handle).inner.lock().unwrap();
                assert!(guard.provide_drag(
                    ChipId::from_raw(chip),
                    &mut item,
                    "public.utf8-plain-text"
                ));
            }
            assert_eq!(
                item.provided(),
                Some((&b"hunter2-secret"[..], ContentKind::Text))
            );
            assert_eq!(sent_destinations(handle), vec!["drag"]);
            assert!(
                !board_text(handle).is_some_and(|text| text.contains("hunter2")),
                "not the clipboard"
            );
            assert!(
                companion_chip_copy_out(handle, chip),
                "a drop deletes nothing"
            );
            companion_free(handle);
        }
    }

    #[test]
    fn a_decrypted_drag_refuses_the_general_pasteboard_a_foreign_type_and_an_unknown_chip() {
        let handle = handle();
        unsafe {
            let (_, chip) = page_with_a_chip(handle, "hunter2-secret");
            let mut guard = (*handle).inner.lock().unwrap();
            let chip = ChipId::from_raw(chip);
            let mut general = companion_pasteboard::MemoryDragItem::on_general();
            assert!(!guard.provide_drag(chip, &mut general, "public.utf8-plain-text"));
            assert!(general.provided().is_none());
            let mut item = companion_pasteboard::MemoryDragItem::new();
            assert!(!guard.provide_drag(chip, &mut item, "public.png"));
            assert!(!guard.provide_drag(
                ChipId::from_raw(4_242),
                &mut item,
                "public.utf8-plain-text"
            ));
            assert!(item.provided().is_none());
            drop(guard);
            assert!(
                sent_destinations(handle).is_empty(),
                "nothing provided, nothing recorded"
            );
            companion_free(handle);
        }
    }

    #[test]
    fn a_decrypted_drag_refuses_a_chip_removed_mid_drag() {
        let handle = handle();
        unsafe {
            let (sheet, chip) = page_with_a_chip(handle, "hunter2-secret");
            let removal = cstring(r#"[{"del": {"at": 2, "len": 1}}]"#);
            assert!(companion_sheet_apply_ops(handle, sheet, removal.as_ptr()));
            let mut guard = (*handle).inner.lock().unwrap();
            let chip = ChipId::from_raw(chip);
            let page = guard.store.sheet(SheetId::from_raw(sheet)).unwrap();
            assert!(
                page.detached().any(|owned| owned.id() == chip),
                "removed, not burned"
            );
            let mut item = companion_pasteboard::MemoryDragItem::new();
            assert!(!guard.provide_drag(chip, &mut item, "public.utf8-plain-text"));
            assert!(item.provided().is_none());
            drop(guard);
            assert!(sent_destinations(handle).is_empty());
            companion_free(handle);
        }
    }

    /// `ab`, an object named `TOKEN` with a note, `cd` on the hour rung, aged
    /// two hours with no sweep: its page and object as the restore numbered them.
    unsafe fn a_due_page_with_a_chip(handle: *mut CompanionHandle) -> (u64, u64) {
        let (_, chip) = unsafe { page_with_a_chip(handle, "hunter2-secret") };
        let tab = unsafe { strip(handle) }[0]["id"].as_u64().unwrap();
        assert!(unsafe { companion_tab_set_rung(handle, tab, 0) });
        let name = cstring("TOKEN");
        assert!(unsafe { companion_chip_set_name(handle, chip, name.as_ptr()) });
        let note = r#"[{"ins": {"at": 0, "text": "rotate monthly"}}]"#;
        assert!(unsafe { note_ops(handle, chip, note, 0) });
        unsafe { age_by(handle, 2 * 60 * 60 * 1_000) };
        let guard = unsafe { &*handle }.inner.lock().unwrap();
        let page = guard.store.sheets().next().expect("no sweep took it");
        let object = page.chips().next().expect("its object stands");
        assert_eq!(object.name(), Some("TOKEN"), "the name stands too");
        assert!(object.has_note(), "and its note");
        (page.id().raw(), object.id().raw())
    }

    #[test]
    fn a_page_past_its_deadline_gives_nothing_out_over_the_seam() {
        let handle = handle();
        unsafe {
            let (sheet, chip) = a_due_page_with_a_chip(handle);
            {
                let mut guard = (*handle).inner.lock().unwrap();
                let mut item = companion_pasteboard::MemoryDragItem::new();
                let text = "public.utf8-plain-text";
                assert!(!guard.provide_drag(ChipId::from_raw(chip), &mut item, text));
                assert!(item.provided().is_none());
            }
            assert!(!companion_chip_copy_out(handle, chip));
            assert!(!companion_chip_copy_name_value(handle, chip));
            assert!(companion_chip_note_runs_json(handle, chip).is_null());
            assert!(companion_sheet_copy_fragment(handle, sheet, 0, 5).is_null());
            assert!(companion_sheet_cut_fragment(handle, sheet, 0, 5).is_null());
            let shown = cstring(&format!(r#"[{{"ink":"ab"}},{{"chip":{chip}}}]"#));
            assert!(companion_sheet_compose_fragment(handle, sheet, shown.as_ptr()).is_null());
            assert!(board_text(handle).is_none(), "nothing written");
            assert!(sent_destinations(handle).is_empty(), "nothing recorded");
            assert_eq!(companion_expire_due(handle), 1, "the sweep still takes it");
            companion_free(handle);
        }
    }

    #[test]
    fn an_object_stands_over_the_seam_until_its_page_is_swept() {
        let handle = handle();
        unsafe {
            let (_, chip) = a_due_page_with_a_chip(handle);
            assert!(
                !companion_chip_copy_out(handle, chip),
                "the control: it is due"
            );
            assert!(companion_chip_stands(handle, chip));
            assert!(!companion_chip_stands(handle, 4_242), "an unknown object");
            assert!(!companion_chip_stands(ptr::null_mut(), chip));
            assert_eq!(companion_expire_due(handle), 1);
            assert!(!companion_chip_stands(handle, chip), "the sweep took it");
            companion_free(handle);
        }
    }

    #[test]
    fn a_page_past_its_deadline_takes_no_note_edit_step_or_rename_over_the_seam() {
        let handle = handle();
        unsafe {
            let (sheet, chip) = a_due_page_with_a_chip(handle);
            let page = take_json(companion_sheet_document_json(handle, sheet));
            let typed = r#"[{"ins": {"at": 0, "text": "x"}}]"#;
            assert!(!note_ops(handle, chip, typed, 0));
            assert!(!note_ops(handle, chip, "[]", 0), "an empty batch too");
            assert!(!companion_chip_note_finish_editing_group(
                handle,
                chip,
                u32::MAX,
                u32::MAX
            ));
            assert!(companion_chip_note_undo(handle, chip).is_null());
            assert!(companion_chip_note_redo(handle, chip).is_null());
            for draft in ["NEW_KEY", ""] {
                let name = cstring(draft);
                assert!(
                    !companion_chip_set_name(handle, chip, name.as_ptr()),
                    "{draft:?}"
                );
            }
            assert_eq!(
                take_json(companion_sheet_document_json(handle, sheet)),
                page,
                "the name or the doorway moved"
            );
            assert!(sent_destinations(handle).is_empty(), "nothing recorded");
            assert_eq!(companion_expire_due(handle), 1, "the sweep still takes it");
            companion_free(handle);
        }
    }

    #[cfg(feature = "test-util")]
    #[test]
    fn neither_conceal_sends_a_page_past_its_deadline() {
        let handle = handle();
        unsafe {
            let server = cstring(r#"{"server_url": "https://eu.onetimesecret.com"}"#);
            assert!(companion_connection_configure(handle, server.as_ptr()));
            assert!(companion_test_wire_stub(handle, 500, ptr::null()));
            let (sheet, chip) = a_due_page_with_a_chip(handle);
            for refusal in [
                json_of(companion_chip_conceal(handle, chip, ptr::null())),
                json_of(companion_sheet_conceal(handle, sheet, ptr::null())),
            ] {
                assert_eq!(refusal["ok"], false);
                assert_eq!(refusal["error"], "this page has expired");
            }
            assert!(
                companion_test_wire_last_json(handle).is_null(),
                "nothing sent"
            );
            assert!(sent_destinations(handle).is_empty());
            companion_free(handle);
        }
    }
}
