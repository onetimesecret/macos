//! The C seam for open files.
//!
//! Paths in, never bytes. That is not a preference: no byte buffer has
//! ever crossed this ABI, and the header says so deliberately. Doing
//! the IO in Swift would mean inventing a buffer convention for a plain
//! text file in a library that refused to invent one for sealed
//! secrets, so the file IO lives in Rust and Swift passes it paths.
//!
//! Everything else follows the conventions in `lib.rs`: strings in are
//! borrowed `*const c_char` read through `cstr`, strings out are owned
//! and freed with `companion_string_free`, structure travels as JSON in
//! a C string, `bool` is accept and reject, and null is the error value
//! for a string return. `FileWitness` never leaves Rust.
//!
//! Every id here is tagged with `FILE_ID_TAG`. The inverse guard lives
//! in `lib.rs`: every `companion_sheet_*` entry point refuses a tagged
//! id, so a file id can never address page zero.
//!
//! The one blob that has to cross is the shell's bookmark, and it
//! crosses as base64 in a C string rather than as a pointer and a
//! length, for the same reason everything else here does.
//!
//! Drafts are sealed under the same content key as the state file and
//! under an envelope magic of their own, so a drafts file presented as
//! a state file fails authentication rather than misparsing. Rotating
//! the content halves therefore discards drafts unless the rotation
//! rewrites them, which [`crate::companion_persist_rotate_and_save`]
//! does through [`reseal_drafts_beside`].

use std::ffi::c_char;
use std::io;
use std::path::{Path, PathBuf};
use std::ptr;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use companion_core::{FileId, FileIo, FileWitness, OpenRefusal, SaveError, file_persist};
use zeroize::Zeroizing;

use crate::diagnostics::diag_fault;
use crate::{Companion, CompanionHandle, cstr, into_c_string, parse_ops, persist, wall_now_ms};

/// Magic and version prefix of the sealed drafts file. Its own byte
/// string, and its own AEAD associated data, so the three sealed files
/// this app writes cannot be swapped for each other even by a caller
/// holding both keys.
const DRAFTS_MAGIC: &[u8; 8] = b"OTSDRFE1";

/// The drafts file's name, as the shell spells it. A copy of a name the
/// shell owns, the same coupling `persist::STATE_FILE_NAME` already
/// carries, and it is what lets a rotation find the drafts file from
/// the state path it was handed.
pub(crate) const DRAFTS_FILE_NAME: &str = "drafts.sealed";

/// The drafts file that sits beside `state_path`.
pub(crate) fn drafts_path_beside(state_path: &Path) -> Option<PathBuf> {
    Some(persist::containing_dir(state_path)?.join(DRAFTS_FILE_NAME))
}

// ---------------------------------------------------------------------------
// The platform surface the core asked for
// ---------------------------------------------------------------------------

/// The real file IO, and the whole of what `crates/core` knows about a
/// filesystem.
///
/// The write is modelled on [`persist::write_private`] and differs from
/// it in exactly one way: the temp file takes the mode of the file
/// already at the target rather than 0600, because this is the user's
/// own document and a save must not quietly make it owner only. A
/// target that is not there yet gets 0644, which is what an editor
/// creating a file is expected to leave behind.
pub(crate) struct RealFileIo;

impl FileIo for RealFileIo {
    fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
        std::fs::read(path)
    }

    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<()> {
        write_atomic_preserving_mode(path, bytes)
    }

    fn stat(&self, path: &Path) -> io::Result<FileWitness> {
        witness_of(&std::fs::metadata(path)?)
    }
}

#[cfg(unix)]
fn witness_of(metadata: &std::fs::Metadata) -> io::Result<FileWitness> {
    use std::os::unix::fs::MetadataExt as _;
    Ok(FileWitness {
        dev: metadata.dev(),
        ino: metadata.ino(),
        size: metadata.size(),
        // Seconds and nanoseconds separately, because the two together
        // are wider than the platform's own `mtime_nsec` field.
        mtime_ns: i128::from(metadata.mtime()) * 1_000_000_000 + i128::from(metadata.mtime_nsec()),
    })
}

#[cfg(not(unix))]
fn witness_of(metadata: &std::fs::Metadata) -> io::Result<FileWitness> {
    let modified = metadata
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
    Ok(FileWitness {
        dev: 0,
        ino: 0,
        size: metadata.len(),
        mtime_ns: i128::try_from(modified.as_nanos()).unwrap_or(i128::MAX),
    })
}

/// Temp file beside the target, opened create-new so nothing planted at
/// the name is followed or truncated, written, fsynced, renamed, then
/// the parent directory fsynced. Either the whole new text is at the
/// path or the old one still is.
fn write_atomic_preserving_mode(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write as _;

    let dir = persist::containing_dir(path)
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;

    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
        // The mode of what is already there, so a save leaves the
        // file's own permissions where the user put them. Nothing yet
        // at the path takes 0644.
        let mode = std::fs::metadata(path).map_or(0o644, |meta| meta.mode() & 0o777);
        options.mode(mode);
    }

    // Every attempt gets its own random suffix, so two savers never
    // meet at one temp name and a leftover from a crash is never
    // reopened. The shape matches `persist::write_private`'s, which is
    // what makes a stranded one sweepable at launch.
    let mut last = io::Error::from(io::ErrorKind::AlreadyExists);
    for _ in 0..8 {
        let mut suffix = [0u8; 8];
        if getrandom_bytes(&mut suffix).is_err() {
            return Err(io::Error::from(io::ErrorKind::Other));
        }
        let mut tmp_name = name.to_os_string();
        tmp_name.push(format!(".{:016x}.tmp", u64::from_be_bytes(suffix)));
        let tmp = dir.join(tmp_name);
        let mut file = match options.open(&tmp) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                last = error;
                continue;
            }
            Err(error) => return Err(error),
        };
        let landed = file.write_all(bytes).and_then(|()| file.sync_all());
        drop(file);
        if let Err(error) = landed {
            let _ = std::fs::remove_file(&tmp);
            return Err(error);
        }
        if let Err(error) = std::fs::rename(&tmp, path) {
            let _ = std::fs::remove_file(&tmp);
            return Err(error);
        }
        // Best effort, exactly as the sealed write treats it: the
        // bytes are durable either way, and a parent that will not sync
        // must never unwrite the save.
        if let Ok(handle) = std::fs::File::open(dir) {
            let _ = handle.sync_all();
        }
        return Ok(());
    }
    Err(last)
}

fn getrandom_bytes(out: &mut [u8]) -> Result<(), ()> {
    use ring::rand::SecureRandom as _;
    ring::rand::SystemRandom::new().fill(out).map_err(|_| ())
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

/// Open the file at `path`, returning its tagged id, or 0 when the open
/// refused. Ask [`companion_file_open_error_json`] why.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_open(
    handle: *mut CompanionHandle,
    path: *const c_char,
) -> u64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    let Some(path) = (unsafe { cstr(path) }) else {
        return 0;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return 0;
    };
    match guard.files.open(&RealFileIo, Path::new(path)) {
        Ok(id) => {
            guard.last_open_refusal = None;
            id.raw()
        }
        Err(refusal) => {
            guard.last_open_refusal = Some(refusal);
            0
        }
    }
}

/// Why the last [`companion_file_open`] on this handle refused, as
/// JSON. Null when nothing has refused. Free with
/// `companion_string_free`.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_open_error_json(
    handle: *mut CompanionHandle,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let Some(refusal) = guard.last_open_refusal else {
        return ptr::null_mut();
    };
    let value = match refusal {
        OpenRefusal::NotUtf8 => serde_json::json!({ "error": "notUtf8" }),
        OpenRefusal::TooLarge { limit } => {
            serde_json::json!({ "error": "tooLarge", "limit": limit as u64 })
        }
        // The kind's own name, which is a fixed English label from the
        // standard library and carries no part of the path.
        OpenRefusal::Io(kind) => {
            serde_json::json!({ "error": "io", "detail": format!("{kind}") })
        }
    };
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Close the file and drop its buffer. The draft goes with it: a draft
/// never outlives its tab. The review prompt for a dirty file is the
/// shell's, and it happens before this call.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_close(handle: *mut CompanionHandle, file: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.files.close(FileId(file))
}

/// The file's body as document runs, the same JSON shape
/// `companion_sheet_document_json` returns. Null for an unknown file.
/// Free with `companion_string_free`.
///
/// A file holds no chips, so in practice the array is one ink run, or
/// none at all for an empty file.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_runs_json(
    handle: *mut CompanionHandle,
    file: u64,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let Some(text) = guard.files.text(FileId(file)) else {
        return ptr::null_mut();
    };
    let runs: Vec<serde_json::Value> = if text.is_empty() {
        Vec::new()
    } else {
        vec![serde_json::json!({ "ink": text })]
    };
    match serde_json::to_string(&runs) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Apply an ordered edit batch to the file's body. False means the
/// batch was rejected whole and nothing moved.
///
/// # Safety
/// `handle` must be a valid handle; `ops_json` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_apply_ops(
    handle: *mut CompanionHandle,
    file: u64,
    ops_json: *const c_char,
) -> bool {
    unsafe { apply(handle, file, ops_json, false) }
}

/// The same, for a batch the app produced on the writer's behalf: it
/// begins its own undo step.
///
/// # Safety
/// `handle` must be a valid handle; `ops_json` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_apply_ops_as_new_step(
    handle: *mut CompanionHandle,
    file: u64,
    ops_json: *const c_char,
) -> bool {
    unsafe { apply(handle, file, ops_json, true) }
}

/// # Safety
/// As the two callers above.
unsafe fn apply(
    handle: *mut CompanionHandle,
    file: u64,
    ops_json: *const c_char,
    new_step: bool,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(json) = (unsafe { cstr(ops_json) }) else {
        return false;
    };
    let Some(ops) = parse_ops(json) else {
        return false;
    };
    // A batch with no readable clock is still applied: the stamp is a
    // convenience for the restored draft's header, and refusing a
    // person's keystroke over it would be the wrong trade.
    let wall_ms = wall_now_ms().unwrap_or(0);
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let id = FileId(file);
    if new_step {
        guard.files.apply_ops_as_new_step(id, &ops, wall_ms)
    } else {
        guard.files.apply_ops(id, &ops, wall_ms)
    }
}

/// Take back the file's last local edit step. Returns the `StepOutcome`
/// JSON described in the header, or null for an unknown file. Free with
/// `companion_string_free`.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_undo(
    handle: *mut CompanionHandle,
    file: u64,
) -> *mut c_char {
    unsafe { step(handle, file, true) }
}

/// Put back the step [`companion_file_undo`] took, on the same terms.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_redo(
    handle: *mut CompanionHandle,
    file: u64,
) -> *mut c_char {
    unsafe { step(handle, file, false) }
}

/// # Safety
/// As the two callers above.
unsafe fn step(handle: *mut CompanionHandle, file: u64, back: bool) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let id = FileId(file);
    let outcome = if back {
        guard.files.undo(id)
    } else {
        guard.files.redo(id)
    };
    let Some(outcome) = outcome else {
        return ptr::null_mut();
    };
    let value = serde_json::json!({
        "applied": outcome.applied,
        "caretUTF16": outcome.caret_u16.map_or(-1, i64::from),
    });
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Write the buffer back to the file's own path, preserving the BOM and
/// the line ending style it arrived with. False when the write refused,
/// which includes a file standing in a conflict nobody has resolved.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_save(handle: *mut CompanionHandle, file: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    report_save(guard.files.save(&RealFileIo, FileId(file)))
}

/// Write the buffer to `path` and adopt it as the file's path.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_save_as(
    handle: *mut CompanionHandle,
    file: u64,
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
    report_save(
        guard
            .files
            .save_as(&RealFileIo, FileId(file), Path::new(path)),
    )
}

/// A refused save names itself in the diagnostic channel. The three
/// refusals have one visible symptom, a file that did not write, and
/// the shell's notice is the same for two of them.
fn report_save(outcome: Result<(), SaveError>) -> bool {
    match outcome {
        Ok(()) => true,
        Err(SaveError::Conflict) => {
            diag_fault!(
                "companion-ffi: a file save was refused because the file changed on disk under \
                 unsaved edits and no resolution has been chosen. Nothing was written."
            );
            false
        }
        Err(SaveError::UnknownFile) => {
            diag_fault!("companion-ffi: a file save named an id nothing is open under.");
            false
        }
        Err(SaveError::Io(kind)) => {
            diag_fault!(
                "companion-ffi: a file save failed to write ({kind}). The file on disk is \
                 untouched."
            );
            false
        }
    }
}

/// Stat the file and say whether anything else has written it, as the
/// `{state, path}` JSON described in the header. Null for an unknown
/// file. Free with `companion_string_free`.
///
/// This is the call that puts a dirty file into a conflict, so the
/// shell asks it on activate and before every save.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_check(
    handle: *mut CompanionHandle,
    file: u64,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let id = FileId(file);
    if guard.files.file(id).is_none() {
        return ptr::null_mut();
    }
    let state = guard.files.refresh_conflict(&RealFileIo, id);
    let path = guard
        .files
        .file(id)
        .map(|f| f.path().to_string_lossy().into_owned())
        .unwrap_or_default();
    let value = serde_json::json!({ "state": state.as_str(), "path": path });
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Re-read the file from disk, discarding whatever the buffer held.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_reload(handle: *mut CompanionHandle, file: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.files.reload(&RealFileIo, FileId(file)).is_ok()
}

/// Keep mine: the first of the three conflict resolutions, and the only
/// one with no other entry point. Take theirs is
/// [`companion_file_reload`] and the third is
/// [`companion_file_save_as`]. Clears the conflict and lets the next
/// save overwrite whatever is on disk.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_resolve_keep_mine(
    handle: *mut CompanionHandle,
    file: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.files.resolve_keep_mine(FileId(file))
}

/// Attach the shell's bookmark for a file, as standard base64. Opaque
/// here: nothing in Rust resolves it or inspects it. An empty string
/// clears it.
///
/// # Safety
/// `handle` must be a valid handle; `bookmark_b64` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_set_bookmark(
    handle: *mut CompanionHandle,
    file: u64,
    bookmark_b64: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(text) = (unsafe { cstr(bookmark_b64) }) else {
        return false;
    };
    let Ok(blob) = BASE64.decode(text) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.files.set_bookmark(FileId(file), blob)
}

/// The bookmark last attached to a file, as standard base64, or an
/// empty string when none was. Null for an unknown file. Free with
/// `companion_string_free`.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_bookmark_b64(
    handle: *mut CompanionHandle,
    file: u64,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let Some(open) = guard.files.file(FileId(file)) else {
        return ptr::null_mut();
    };
    into_c_string(BASE64.encode(open.bookmark()))
}

/// Every open file, in open order, as an array of `FileSummary`. Null
/// when the answer cannot be had. Free with `companion_string_free`.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_roster_json(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let roster: Vec<serde_json::Value> = guard
        .files
        .files()
        .iter()
        .map(|file| {
            serde_json::json!({
                "id": file.id().raw(),
                "name": file.name(),
                "path": file.path().to_string_lossy(),
                "isDirty": file.is_dirty(),
                "conflict": file.conflict().as_str(),
                "lineEnding": file.line_ending().as_str(),
                "hasBOM": file.has_bom(),
                "lastEditedAt": file.last_edited_at(),
                "restoredFromDraft": file.restored_from_draft(),
            })
        })
        .collect();
    match serde_json::to_string(&roster) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

// ---------------------------------------------------------------------------
// Drafts: the third sealed file
// ---------------------------------------------------------------------------

/// Seal the open file roster and every dirty file's draft to `path`,
/// under the same content key as the state file and under an envelope
/// magic of its own.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_drafts_save(
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
    seal_drafts_to(&guard, Path::new(path))
}

/// Seal the roster as it stands and write it to `path`, minting the
/// content key halves if this is the first write under them. Shared
/// with the rotation, which has to do the identical write after it has
/// taken the old halves away.
///
/// The caller holds the lock.
pub(crate) fn seal_drafts_to(state: &Companion, path: &Path) -> bool {
    let Some(wall_ms) = wall_now_ms() else {
        return false;
    };
    let Some(key) = persist::ensure_state_key(state.credentials.as_ref(), path) else {
        return false;
    };
    // The buffer holds a person's unsaved typing, so it is wiped on the
    // way out whatever happens to the write.
    let plaintext = Zeroizing::new(file_persist::emit(&state.files, wall_ms));
    let Some(sealed) = persist::seal_body(&key, DRAFTS_MAGIC, &plaintext) else {
        return false;
    };
    let mut file = Vec::with_capacity(DRAFTS_MAGIC.len() + sealed.len());
    file.extend_from_slice(DRAFTS_MAGIC);
    file.extend_from_slice(&sealed);
    persist::write_private(path, &file)
}

/// Restore the roster and the drafts at launch. False covers a fresh
/// start with no file as much as a refused one.
///
/// **A draft record is never taken for a page.** The two files carry
/// different envelope magics, each of which is its own associated data,
/// and different plaintext magics inside them, so a drafts file handed
/// to the state restore fails authentication and a state file handed
/// here fails it too. Nothing about a record's shape decides which
/// store it lands in: `file_persist::restore` writes only into the file
/// store and cannot reach the sheet store at all.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_drafts_restore(
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
    let path = Path::new(path);
    let Ok(file) = std::fs::read(path) else {
        return false;
    };
    if !file.starts_with(DRAFTS_MAGIC) {
        diag_fault!(
            "companion-ffi: the drafts file does not carry this build's envelope header; \
             refusing it and leaving it where it is."
        );
        return false;
    }
    // The magic is read before the key is asked for, so a file this
    // build cannot read at all costs no keychain access.
    let Some(key) = persist::load_state_key(guard.credentials.as_ref(), path) else {
        diag_fault!(
            "companion-ffi: the drafts file carries this build's envelope, but the content key \
             could not be assembled. The drafts stay sealed and the open files do not come back."
        );
        return false;
    };
    let Some(plaintext) = persist::open_body(&key, DRAFTS_MAGIC, &file[DRAFTS_MAGIC.len()..])
    else {
        diag_fault!(
            "companion-ffi: the drafts file would not authenticate under the assembled content \
             key. The halves this session holds are not the halves that sealed it, which is \
             what a rotation between the two writes looks like."
        );
        return false;
    };
    let Some(wall_ms) = wall_now_ms() else {
        return false;
    };
    match file_persist::restore(&mut guard.files, &plaintext, wall_ms) {
        Ok(_) => true,
        Err(error) => {
            diag_fault!(
                "companion-ffi: the drafts file authenticated but the core rejected the \
                 snapshot inside it ({error})."
            );
            false
        }
    }
}

/// Drop the drafts file at `path`. True when the path is confirmed
/// empty, including when there was nothing there to begin with.
///
/// No rotation happens here, and none may: the drafts file rests under
/// the content key, and rotating on its behalf would destroy every
/// staged page the user still has.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_drafts_erase(
    handle: *mut CompanionHandle,
    path: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(path) = (unsafe { cstr(path) }) else {
        return false;
    };
    let Ok(_guard) = handle.inner.lock() else {
        return false;
    };
    persist::erase_state(Path::new(path))
}

/// Rewrite the drafts file that sits beside `state_path` under whatever
/// content key the halves now derive. Called by the rotation, under the
/// handle lock, immediately after the old halves are destroyed and
/// **before** the state file is resealed.
///
/// **Why drafts go first.** A rotation destroys the key, so everything
/// sealed under it is unreadable the moment the old file half is
/// erased. There is no ordering that keeps the drafts readable across
/// that instant: writing them under the new key requires the new key,
/// and the new key does not exist until the old halves are gone. What
/// the ordering can decide is which of the two files survives a crash
/// inside the window, and drafts win that. The rotation's own residual
/// is already stated in `companion_persist_rotate_and_save`: the window
/// costs the tab names, rungs and strip order, and costs no page
/// content, because the rotation fires only when no tab holds a page. A
/// draft is a person's unsaved typing and is the more valuable of the
/// two, so it is written first and the arrangement takes the risk.
///
/// A file that is not there is not written: an install with no drafts
/// file must not gain one from a rotation, because that would put an
/// empty roster on disk where the shell reads one at launch.
///
/// Returns whether the drafts are readable under the new key, which for
/// an install with no drafts file is trivially true.
pub(crate) fn reseal_drafts_beside(state: &Companion, state_path: &Path) -> bool {
    let Some(path) = drafts_path_beside(state_path) else {
        return true;
    };
    if !path.exists() && state.files.files().is_empty() {
        return true;
    }
    if seal_drafts_to(state, &path) {
        return true;
    }
    diag_fault!(
        "companion-ffi: the drafts file could not be rewritten under the rotated content key. \
         Every unsaved file edit staged in it is unreadable from now on."
    );
    false
}

/// Erase the drafts file that sits beside `state_path`. The other half
/// of `companion_persist_erase`: the gesture that drops the content
/// file is the gesture that discards drafts.
pub(crate) fn erase_drafts_beside(state_path: &Path) -> bool {
    let Some(path) = drafts_path_beside(state_path) else {
        return true;
    };
    persist::erase_state(&path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_core::FILE_SIZE_LIMIT as LIMIT;
    use std::ffi::{CStr, CString};

    fn cstring(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    unsafe fn take_json(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null(), "the route answered null");
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
        unsafe { crate::companion_string_free(ptr) };
        text
    }

    /// A temp directory of this test's own, for the files it opens and
    /// the sealed state beside them. Never the installed state
    /// directory, and never a path any other test shares.
    fn scratch_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ots-files-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A handle over the in-process board with credentials that never
    /// reach any keychain, built the way `lib.rs`'s own tests build
    /// one. Two handles over one credential store model two launches
    /// of the app against one keychain.
    fn handle_with(
        credentials: std::sync::Arc<dyn companion_credentials::CredentialStore>,
    ) -> *mut CompanionHandle {
        let companion = Companion {
            store: companion_core::SheetStore::new(companion_core::SystemClock),
            pasteboard: crate::Board::Memory(companion_pasteboard::MemoryPasteboard::new()),
            last_write: None,
            connection: None,
            credentials,
            wire: crate::conceal::Wire::real(),
            sync: crate::sync_driver::SyncState::default(),
            files: companion_core::FileStore::new(),
            last_open_refusal: None,
        };
        Box::into_raw(Box::new(CompanionHandle {
            inner: std::sync::Mutex::new(companion),
        }))
    }

    fn credentials() -> std::sync::Arc<dyn companion_credentials::CredentialStore> {
        std::sync::Arc::new(companion_credentials::InMemoryCredentialStore::default())
    }

    fn scratch(tag: &str) -> (*mut CompanionHandle, PathBuf) {
        (handle_with(credentials()), scratch_dir(tag))
    }

    fn cleanup(handle: *mut CompanionHandle, dir: &Path) {
        unsafe { crate::companion_free(handle) };
        let _ = std::fs::remove_dir_all(dir);
    }

    unsafe fn open(handle: *mut CompanionHandle, path: &Path) -> u64 {
        let c = cstring(&path.to_string_lossy());
        unsafe { companion_file_open(handle, c.as_ptr()) }
    }

    unsafe fn roster(handle: *mut CompanionHandle) -> serde_json::Value {
        let json = unsafe { take_json(companion_file_roster_json(handle)) };
        serde_json::from_str(&json).unwrap()
    }

    #[test]
    fn a_file_opens_edits_and_saves_through_the_seam() {
        let (handle, dir) = scratch("roundtrip");
        let file = dir.join("note.txt");
        std::fs::write(&file, b"hello").unwrap();
        unsafe {
            let id = open(handle, &file);
            assert!(FileId::is_tagged(id));

            let runs = take_json(companion_file_runs_json(handle, id));
            assert_eq!(runs, r#"[{"ink":"hello"}]"#);

            let ops = cstring(r#"[{"ins":{"at":5,"text":" world"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            assert_eq!(roster(handle)[0]["isDirty"], serde_json::json!(true));

            assert!(companion_file_save(handle, id));
            assert_eq!(std::fs::read(&file).unwrap(), b"hello world");
            assert_eq!(roster(handle)[0]["isDirty"], serde_json::json!(false));

            let undo: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_undo(handle, id))).unwrap();
            assert_eq!(undo["applied"], serde_json::json!(true));
            assert!(undo["caretUTF16"].is_i64());
            assert_eq!(roster(handle)[0]["isDirty"], serde_json::json!(true));

            let redo: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_redo(handle, id))).unwrap();
            assert_eq!(redo["applied"], serde_json::json!(true));
            assert!(companion_file_close(handle, id));
            assert_eq!(roster(handle), serde_json::json!([]));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn the_roster_carries_every_field_the_header_promises() {
        let (handle, dir) = scratch("roster");
        let file = dir.join("crlf.txt");
        std::fs::write(&file, [&[0xEF, 0xBB, 0xBFu8][..], b"a\r\nb"].concat()).unwrap();
        unsafe {
            let id = open(handle, &file);
            let row = roster(handle);
            let row = &row[0];
            assert_eq!(row["id"], serde_json::json!(id));
            assert_eq!(row["name"], serde_json::json!("crlf.txt"));
            assert_eq!(row["path"], serde_json::json!(file.to_string_lossy()));
            assert_eq!(row["isDirty"], serde_json::json!(false));
            assert_eq!(row["conflict"], serde_json::json!("none"));
            assert_eq!(row["lineEnding"], serde_json::json!("crlf"));
            assert_eq!(row["hasBOM"], serde_json::json!(true));
            assert_eq!(row["lastEditedAt"], serde_json::json!(0));
            assert_eq!(row["restoredFromDraft"], serde_json::json!(false));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_bom_and_crlf_file_saves_back_byte_identically() {
        let (handle, dir) = scratch("bytes");
        let file = dir.join("w.txt");
        let original = [&[0xEF, 0xBB, 0xBFu8][..], b"alpha\r\nbeta\r\n"].concat();
        std::fs::write(&file, &original).unwrap();
        unsafe {
            let id = open(handle, &file);
            assert!(companion_file_save(handle, id));
        }
        assert_eq!(std::fs::read(&file).unwrap(), original);
        cleanup(handle, &dir);
    }

    #[test]
    fn a_save_keeps_the_mode_the_file_already_had() {
        let (handle, dir) = scratch("mode");
        let file = dir.join("m.txt");
        std::fs::write(&file, b"body").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o640)).unwrap();
        }
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":4,"text":"!"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            assert!(companion_file_save(handle, id));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(&file).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o640, "the save must not restyle the file's mode");
        }
        assert_eq!(std::fs::read(&file).unwrap(), b"body!");
        cleanup(handle, &dir);
    }

    #[test]
    fn refusals_name_themselves() {
        let (handle, dir) = scratch("refuse");
        let bad = dir.join("bad.bin");
        std::fs::write(&bad, [0x66, 0xFF, 0xFE]).unwrap();
        let big = dir.join("big.txt");
        std::fs::write(&big, vec![b'x'; LIMIT + 1]).unwrap();
        unsafe {
            assert_eq!(open(handle, &bad), 0);
            let error = take_json(companion_file_open_error_json(handle));
            assert_eq!(error, r#"{"error":"notUtf8"}"#);

            assert_eq!(open(handle, &big), 0);
            let error: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_open_error_json(handle))).unwrap();
            assert_eq!(error["error"], serde_json::json!("tooLarge"));
            assert_eq!(error["limit"], serde_json::json!(LIMIT as u64));

            assert_eq!(open(handle, &dir.join("nowhere.txt")), 0);
            let error: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_open_error_json(handle))).unwrap();
            assert_eq!(error["error"], serde_json::json!("io"));
            assert!(error["detail"].is_string());

            // A successful open clears the last refusal.
            let good = dir.join("good.txt");
            std::fs::write(&good, b"fine").unwrap();
            assert_ne!(open(handle, &good), 0);
            assert!(companion_file_open_error_json(handle).is_null());
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_conflict_blocks_the_save_until_a_resolution_is_taken() {
        let (handle, dir) = scratch("conflict");
        let file = dir.join("c.txt");
        std::fs::write(&file, b"one").unwrap();
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":3,"text":" mine"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            std::fs::write(&file, b"theirs").unwrap();

            let check: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_check(handle, id))).unwrap();
            assert_eq!(check["state"], serde_json::json!("changed"));
            assert_eq!(check["path"], serde_json::json!(file.to_string_lossy()));
            assert_eq!(roster(handle)[0]["conflict"], serde_json::json!("changed"));

            assert!(!companion_file_save(handle, id));
            assert_eq!(std::fs::read(&file).unwrap(), b"theirs");

            assert!(companion_file_resolve_keep_mine(handle, id));
            assert_eq!(roster(handle)[0]["conflict"], serde_json::json!("none"));
            assert!(companion_file_save(handle, id));
            assert_eq!(std::fs::read(&file).unwrap(), b"one mine");
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn check_reports_a_missing_file_and_reload_clears_dirty() {
        let (handle, dir) = scratch("missing");
        let file = dir.join("g.txt");
        std::fs::write(&file, b"one").unwrap();
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":3,"text":"x"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            std::fs::remove_file(&file).unwrap();
            let check: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_check(handle, id))).unwrap();
            assert_eq!(check["state"], serde_json::json!("missing"));
            assert_eq!(roster(handle)[0]["conflict"], serde_json::json!("missing"));

            // Take theirs is impossible with nothing there, so the
            // reload refuses and the buffer stands.
            assert!(!companion_file_reload(handle, id));
            std::fs::write(&file, b"back").unwrap();
            assert!(companion_file_reload(handle, id));
            assert_eq!(roster(handle)[0]["isDirty"], serde_json::json!(false));
            assert_eq!(roster(handle)[0]["conflict"], serde_json::json!("none"));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn save_as_moves_the_identity_and_leaves_the_original() {
        let (handle, dir) = scratch("saveas");
        let from = dir.join("from.txt");
        let to = dir.join("to.txt");
        std::fs::write(&from, b"body").unwrap();
        unsafe {
            let id = open(handle, &from);
            let ops = cstring(r#"[{"ins":{"at":4,"text":"!"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            let target = cstring(&to.to_string_lossy());
            assert!(companion_file_save_as(handle, id, target.as_ptr()));
            let row = roster(handle);
            assert_eq!(row[0]["path"], serde_json::json!(to.to_string_lossy()));
            assert_eq!(row[0]["name"], serde_json::json!("to.txt"));
        }
        assert_eq!(std::fs::read(&to).unwrap(), b"body!");
        assert_eq!(std::fs::read(&from).unwrap(), b"body");
        cleanup(handle, &dir);
    }

    #[test]
    fn a_bookmark_crosses_as_base64_and_comes_back_unchanged() {
        let (handle, dir) = scratch("bookmark");
        let file = dir.join("b.txt");
        std::fs::write(&file, b"body").unwrap();
        unsafe {
            let id = open(handle, &file);
            assert_eq!(take_json(companion_file_bookmark_b64(handle, id)), "");
            let blob = BASE64.encode([0u8, 1, 2, 250, 255]);
            let c = cstring(&blob);
            assert!(companion_file_set_bookmark(handle, id, c.as_ptr()));
            assert_eq!(take_json(companion_file_bookmark_b64(handle, id)), blob);

            let junk = cstring("not base64!!!");
            assert!(!companion_file_set_bookmark(handle, id, junk.as_ptr()));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn drafts_round_trip_through_the_seal() {
        let keys = credentials();
        let handle = handle_with(keys.clone());
        let dir = scratch_dir("drafts");
        let state = dir.join("state.sealed");
        let drafts = dir.join(DRAFTS_FILE_NAME);
        let file = dir.join("d.txt");
        std::fs::write(&file, b"one").unwrap();
        let drafts_c = cstring(&drafts.to_string_lossy());
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":0,"text":"typed "}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            let mark = cstring(&BASE64.encode(b"bookmark-blob"));
            assert!(companion_file_set_bookmark(handle, id, mark.as_ptr()));
            assert!(companion_drafts_save(handle, drafts_c.as_ptr()));
        }
        assert!(drafts.exists());
        let sealed = std::fs::read(&drafts).unwrap();
        assert!(sealed.starts_with(DRAFTS_MAGIC));
        assert!(
            !sealed.windows(5).any(|w| w == b"typed"),
            "the draft's plaintext must not be on disk"
        );
        unsafe { crate::companion_free(handle) };
        // A second handle sharing the same in-memory credential store
        // is the relaunch: the same halves, a fresh store.
        let relaunch = handle_with(keys);
        unsafe {
            assert!(companion_drafts_restore(relaunch, drafts_c.as_ptr()));
            let row = roster(relaunch);
            assert_eq!(row.as_array().unwrap().len(), 1);
            assert_eq!(row[0]["isDirty"], serde_json::json!(true));
            assert_eq!(row[0]["restoredFromDraft"], serde_json::json!(true));
            assert_eq!(row[0]["path"], serde_json::json!(file.to_string_lossy()));
            let id = row[0]["id"].as_u64().unwrap();
            assert!(FileId::is_tagged(id));
            assert_eq!(
                take_json(companion_file_runs_json(relaunch, id)),
                r#"[{"ink":"typed one"}]"#
            );
            assert_eq!(
                take_json(companion_file_bookmark_b64(relaunch, id)),
                BASE64.encode(b"bookmark-blob")
            );
            // The state file was never written, and the drafts file is
            // not one: a draft record never lands in the sheet store.
            let state_c = cstring(&state.to_string_lossy());
            assert!(!crate::companion_persist_restore(
                relaunch,
                state_c.as_ptr()
            ));
            let drafts_as_state = cstring(&drafts.to_string_lossy());
            assert!(!crate::companion_persist_restore(
                relaunch,
                drafts_as_state.as_ptr()
            ));
            assert_eq!(tabs(relaunch).as_array().unwrap().len(), 0);
            // The roster survived both refusals untouched.
            assert_eq!(roster(relaunch).as_array().unwrap().len(), 1);
        }
        cleanup(relaunch, &dir);
    }

    unsafe fn tabs(handle: *mut CompanionHandle) -> serde_json::Value {
        let json = unsafe { take_json(crate::companion_tabs_json(handle)) };
        serde_json::from_str(&json).unwrap()
    }

    #[test]
    fn erasing_the_drafts_file_leaves_nothing_at_the_path() {
        let (handle, dir) = scratch("drafts-erase");
        let drafts = dir.join(DRAFTS_FILE_NAME);
        let file = dir.join("e.txt");
        std::fs::write(&file, b"one").unwrap();
        let drafts_c = cstring(&drafts.to_string_lossy());
        unsafe {
            open(handle, &file);
            assert!(companion_drafts_save(handle, drafts_c.as_ptr()));
            assert!(drafts.exists());
            assert!(companion_drafts_erase(handle, drafts_c.as_ptr()));
            assert!(!drafts.exists());
            // Erasing what is not there is success, not a failure.
            assert!(companion_drafts_erase(handle, drafts_c.as_ptr()));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_rotation_leaves_the_drafts_readable_under_the_new_key() {
        let keys = credentials();
        let handle = handle_with(keys.clone());
        let dir = scratch_dir("rotate");
        let state = dir.join("state.sealed");
        let drafts = dir.join(DRAFTS_FILE_NAME);
        let file = dir.join("r.txt");
        std::fs::write(&file, b"one").unwrap();
        let state_c = cstring(&state.to_string_lossy());
        let drafts_c = cstring(&drafts.to_string_lossy());
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":0,"text":"typed "}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            assert!(crate::companion_persist_save(handle, state_c.as_ptr()));
            assert!(companion_drafts_save(handle, drafts_c.as_ptr()));
        }
        let before = std::fs::read(&drafts).unwrap();

        // The pad holds no page, so this is the rotation the shell
        // performs when the last page expires: new halves, the strip
        // resealed, and the drafts rewritten in the same operation.
        unsafe {
            assert!(crate::companion_persist_rotate_and_save(
                handle,
                state_c.as_ptr()
            ));
        }
        let after = std::fs::read(&drafts).unwrap();
        assert_ne!(before, after, "the drafts were resealed, not left alone");
        assert!(after.starts_with(DRAFTS_MAGIC));
        unsafe { crate::companion_free(handle) };

        let relaunch = handle_with(keys);
        unsafe {
            assert!(
                companion_drafts_restore(relaunch, drafts_c.as_ptr()),
                "the drafts must open under the halves the rotation minted"
            );
            let row = roster(relaunch);
            assert_eq!(row[0]["isDirty"], serde_json::json!(true));
            let id = row[0]["id"].as_u64().unwrap();
            assert_eq!(
                take_json(companion_file_runs_json(relaunch, id)),
                r#"[{"ink":"typed one"}]"#
            );
        }
        cleanup(relaunch, &dir);
    }

    #[test]
    fn erasing_the_content_file_takes_the_drafts_with_it() {
        let (handle, dir) = scratch("erase-pair");
        let state = dir.join("state.sealed");
        let drafts = dir.join(DRAFTS_FILE_NAME);
        let file = dir.join("x.txt");
        std::fs::write(&file, b"one").unwrap();
        let state_c = cstring(&state.to_string_lossy());
        let drafts_c = cstring(&drafts.to_string_lossy());
        unsafe {
            open(handle, &file);
            assert!(crate::companion_persist_save(handle, state_c.as_ptr()));
            assert!(companion_drafts_save(handle, drafts_c.as_ptr()));
            assert!(drafts.exists());
            assert!(crate::companion_persist_erase(handle, state_c.as_ptr()));
        }
        assert!(!state.exists());
        assert!(!drafts.exists(), "the content drop discards drafts too");
        cleanup(handle, &dir);
    }

    #[test]
    fn a_ledger_clear_leaves_the_drafts_alone() {
        // The same entry point drops the ledger file, and that gesture
        // asked nothing about files. Drafts must survive it.
        let (handle, dir) = scratch("ledger-clear");
        let ledger = dir.join("ledger.sealed");
        let drafts = dir.join(DRAFTS_FILE_NAME);
        let file = dir.join("y.txt");
        std::fs::write(&file, b"one").unwrap();
        let ledger_c = cstring(&ledger.to_string_lossy());
        let drafts_c = cstring(&drafts.to_string_lossy());
        unsafe {
            open(handle, &file);
            assert!(crate::companion_ledger_save(handle, ledger_c.as_ptr()));
            assert!(companion_drafts_save(handle, drafts_c.as_ptr()));
            assert!(crate::companion_persist_erase(handle, ledger_c.as_ptr()));
        }
        assert!(!ledger.exists());
        assert!(drafts.exists(), "a ledger clear must not discard drafts");
        cleanup(handle, &dir);
    }

    #[test]
    fn the_drafts_file_neither_triggers_nor_blocks_a_rotation() {
        // The rotation predicate reads the path's name and, failing
        // that, the envelope at it. The drafts file answers no to both,
        // so a rotation aimed at it is refused outright rather than
        // destroying the halves that key every staged page.
        let (handle, dir) = scratch("predicate");
        let state = dir.join("state.sealed");
        let drafts = dir.join(DRAFTS_FILE_NAME);
        let file = dir.join("z.txt");
        std::fs::write(&file, b"one").unwrap();
        let state_c = cstring(&state.to_string_lossy());
        let drafts_c = cstring(&drafts.to_string_lossy());
        unsafe {
            open(handle, &file);
            assert!(crate::companion_persist_save(handle, state_c.as_ptr()));
            assert!(companion_drafts_save(handle, drafts_c.as_ptr()));
        }
        assert!(!persist::drop_takes_the_content_key(&drafts));
        assert!(persist::drop_takes_the_content_key(&state));
        unsafe {
            assert!(
                !crate::companion_persist_rotate_and_save(handle, drafts_c.as_ptr()),
                "a rotation aimed at the drafts file is refused"
            );
        }
        // The state file still opens, so nothing was rotated on the
        // drafts file's behalf.
        unsafe {
            assert!(crate::companion_persist_restore(handle, state_c.as_ptr()));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_rotation_with_no_drafts_file_writes_none() {
        let (handle, dir) = scratch("no-drafts");
        let state = dir.join("state.sealed");
        let state_c = cstring(&state.to_string_lossy());
        unsafe {
            assert!(crate::companion_persist_save(handle, state_c.as_ptr()));
            assert!(crate::companion_persist_rotate_and_save(
                handle,
                state_c.as_ptr()
            ));
        }
        assert!(
            !dir.join(DRAFTS_FILE_NAME).exists(),
            "an install with no drafts must not gain an empty one"
        );
        cleanup(handle, &dir);
    }

    #[test]
    fn a_sheet_id_is_refused_by_every_file_route() {
        let (handle, dir) = scratch("guard");
        let file = dir.join("f.txt");
        std::fs::write(&file, b"one").unwrap();
        unsafe {
            open(handle, &file);
            // A live page's id, untagged, put to every file route.
            let tab = crate::companion_tab_new(handle);
            assert_ne!(tab, 0);
            let page = tabs(handle)[0]["page_id"].as_u64().unwrap();
            assert!(!FileId::is_tagged(page), "a page id never carries the tag");

            assert!(!companion_file_close(handle, page));
            assert!(companion_file_runs_json(handle, page).is_null());
            let ops = cstring(r#"[{"ins":{"at":0,"text":"x"}}]"#);
            assert!(!companion_file_apply_ops(handle, page, ops.as_ptr()));
            assert!(!companion_file_apply_ops_as_new_step(
                handle,
                page,
                ops.as_ptr()
            ));
            assert!(companion_file_undo(handle, page).is_null());
            assert!(companion_file_redo(handle, page).is_null());
            assert!(!companion_file_save(handle, page));
            let target = cstring(&dir.join("nope.txt").to_string_lossy());
            assert!(!companion_file_save_as(handle, page, target.as_ptr()));
            assert!(companion_file_check(handle, page).is_null());
            assert!(!companion_file_reload(handle, page));
            assert!(!companion_file_resolve_keep_mine(handle, page));
            let mark = cstring("");
            assert!(!companion_file_set_bookmark(handle, page, mark.as_ptr()));
            assert!(companion_file_bookmark_b64(handle, page).is_null());

            assert!(!dir.join("nope.txt").exists());
            // The page and the file both stood through all of it.
            assert_eq!(tabs(handle)[0]["page_id"].as_u64(), Some(page));
            assert_eq!(roster(handle).as_array().unwrap().len(), 1);
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn null_handles_and_null_strings_answer_rather_than_crash() {
        let null = ptr::null_mut();
        unsafe {
            assert_eq!(companion_file_open(null, ptr::null()), 0);
            assert!(companion_file_open_error_json(null).is_null());
            assert!(!companion_file_close(null, 1));
            assert!(companion_file_runs_json(null, 1).is_null());
            assert!(!companion_file_apply_ops(null, 1, ptr::null()));
            assert!(!companion_file_apply_ops_as_new_step(null, 1, ptr::null()));
            assert!(companion_file_undo(null, 1).is_null());
            assert!(companion_file_redo(null, 1).is_null());
            assert!(!companion_file_save(null, 1));
            assert!(!companion_file_save_as(null, 1, ptr::null()));
            assert!(companion_file_check(null, 1).is_null());
            assert!(!companion_file_reload(null, 1));
            assert!(!companion_file_resolve_keep_mine(null, 1));
            assert!(!companion_file_set_bookmark(null, 1, ptr::null()));
            assert!(companion_file_bookmark_b64(null, 1).is_null());
            assert!(companion_file_roster_json(null).is_null());
            assert!(!companion_drafts_save(null, ptr::null()));
            assert!(!companion_drafts_restore(null, ptr::null()));
            assert!(!companion_drafts_erase(null, ptr::null()));
        }
    }
}
