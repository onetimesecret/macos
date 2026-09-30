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
use companion_core::{
    EditIntent, FileId, FileIo, FileWitness, HydrationFate, OpenRefusal, PathRebind,
    RelocateRefusal, SaveError, file_persist,
};
use zeroize::Zeroizing;

use crate::diagnostics::diag_fault;
use crate::{
    Companion, CompanionHandle, cstr, edit_intent, edit_selection, into_c_string, parse_ops,
    persist, wall_now_ms,
};

/// Magic and version prefix of the sealed drafts file. Its own byte
/// string, and its own AEAD associated data, so the three sealed files
/// this app writes cannot be swapped for each other even by a caller
/// holding both keys.
const DRAFTS_MAGIC: &[u8; 8] = b"OTSDRFE1";

/// The drafts file's default name.
///
/// **The shell owns the name.** Every `companion_drafts_*` entry point
/// takes its path from the caller and never consults this, exactly as
/// `companion_persist_save` does, so `FormFactor` is free to put the
/// file where it likes. This constant exists for the one caller that
/// has no path to be given: a key rotation is handed the state file and
/// has to find the drafts file beside it. That is the same coupling
/// `persist::STATE_FILE_NAME` already carries, and if the shell renames
/// the file the rotation stops finding it.
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
///
/// **Where the temp file goes is the caller's to say.** Beside the
/// target is the ordinary answer and needs nothing from anyone. It is
/// also the one answer a sandboxed process cannot use: a grant on a
/// document covers that document and not the directory it sits in, so
/// creating anything beside it is refused. A shell that has been given
/// a directory on the target's volume which it may write in hands it
/// over as the staging directory, the temp file is made there instead,
/// and the rename onto the target is the one step that needs the grant.
pub(crate) struct RealFileIo<'a> {
    staging_dir: Option<&'a Path>,
}

impl RealFileIo<'static> {
    /// File IO whose writes stage beside their target. Every caller
    /// that only reads or stats takes this one too, since the staging
    /// directory means nothing to a read.
    pub(crate) const fn new() -> Self {
        Self { staging_dir: None }
    }
}

impl<'a> RealFileIo<'a> {
    /// File IO whose writes stage in `staging_dir` when one is given,
    /// and beside their target when it is `None`.
    pub(crate) const fn staging_in(staging_dir: Option<&'a Path>) -> Self {
        Self { staging_dir }
    }
}

impl FileIo for RealFileIo<'_> {
    fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
        read_regular_file(path)
    }

    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<()> {
        write_atomic_preserving_mode(path, bytes, self.staging_dir)
    }

    fn stat(&self, path: &Path) -> io::Result<FileWitness> {
        let metadata = std::fs::metadata(path)?;
        if !metadata.file_type().is_file() {
            // A directory, a pipe, a socket or a device is not a text
            // file, and answering a witness for one would let the store
            // go on to read it. The core turns this into an `io`
            // refusal the shell can name.
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
        witness_of(&metadata)
    }

    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        std::fs::canonicalize(path)
    }
}

/// Read a whole file, having first established that it is one.
///
/// **A bare `std::fs::read` is not safe here.** The path comes from a
/// person, or from a drafts record written before whatever is at the
/// path now. If it is a named pipe with no writer, the `open` inside
/// `std::fs::read` blocks and never returns, and both callers hold the
/// handle mutex across it, so the whole app stops answering with no
/// error and nothing to see. Two things prevent it, because either one
/// alone has a race in it:
///
///  - the stat first, which refuses everything that is not a regular
///    file, and
///  - `O_NONBLOCK` on the open, so a pipe that was substituted in the
///    window between the stat and the open fails `ENXIO` instead of
///    parking forever. On a regular file the flag is inert.
///
/// `O_NOFOLLOW` is deliberately not set: symlinks are followed on
/// purpose, once, at open, and the path held from then on is the
/// resolved one.
fn read_regular_file(path: &Path) -> io::Result<Vec<u8>> {
    use std::io::Read as _;

    let metadata = std::fs::metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(persist::O_NONBLOCK);
    }
    let mut file = options.open(path)?;
    // Asked again through the open file itself, which no substitution
    // at the name can change afterwards.
    if !file.metadata()?.file_type().is_file() {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    }
    let mut bytes = Vec::with_capacity(metadata.len().try_into().unwrap_or(0));
    file.read_to_end(&mut bytes)?;
    Ok(bytes)
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

/// A temp file, opened create-new so nothing planted at the name is
/// followed or truncated, written, fsynced, renamed onto the target,
/// then the target's directory fsynced. Either the whole new text is at
/// the path or the old one still is.
///
/// The temp file is made in `staging_dir` when there is one and beside
/// the target when there is not. Nothing else differs between the two:
/// the same name shape, the same mode, the same rename. A staging
/// directory that is missing, not writable, or on another volume fails
/// the save with the platform's own error, and there is deliberately no
/// falling back to the sibling from here. A caller that was given a
/// staging directory is one for whom the sibling is refused anyway, and
/// a save that quietly took a different route than the one it was told
/// to take is harder to reason about than one that says it failed.
fn write_atomic_preserving_mode(
    path: &Path,
    bytes: &[u8],
    staging_dir: Option<&Path>,
) -> io::Result<()> {
    use std::io::Write as _;

    let dir = persist::containing_dir(path)
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let tmp_dir = staging_dir.unwrap_or(dir);

    // What is already at the target, asked once. Its mode and its group
    // are what the new file has to end up with, because the rename
    // replaces the file and everything the old one carried goes with
    // it unless it is put back here.
    let existing = std::fs::metadata(path).ok();

    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
        // The mode of what is already there, so a save leaves the
        // file's own permissions where the user put them. Nothing yet
        // at the path takes 0644.
        let mode = existing.as_ref().map_or(0o644, |meta| meta.mode() & 0o777);
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
        let tmp = tmp_dir.join(tmp_name);
        let mut file = match options.open(&tmp) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                last = error;
                continue;
            }
            Err(error) => return Err(error),
        };
        let landed = carry_identity(&file, existing.as_ref(), dir)
            .and_then(|()| file.write_all(bytes))
            .and_then(|()| file.sync_all());
        drop(file);
        if let Err(error) = landed {
            let _ = std::fs::remove_file(&tmp);
            return Err(error);
        }
        // The one step that touches the target. A staging directory on
        // another volume fails here, as does a target the process holds
        // no grant on, and either way the temp file is taken back so
        // nothing of the person's text is left lying in a directory
        // they never look in.
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

/// Give the temp file the mode and the group of the file it is about to
/// replace, through the open descriptor so no name is consulted twice.
///
/// The mode asked for at open is cut down by the process umask, so a
/// file the user had made group writable would come back from a save
/// without the bit. Setting it again on the descriptor is not subject
/// to the umask, and a mode that will not set fails the save: writing a
/// person's file back more widely or more narrowly readable than they
/// left it is not a save they asked for.
///
/// The group is a different matter and is best effort. A new file takes
/// the group of the directory it was created in, which for a staged
/// write is the staging directory's and not the document's, so the
/// group is put back when it differs. A user who is not a member of the
/// group the file carried cannot give it back, and that is no reason to
/// refuse to save their text.
///
/// Nothing at the target yet means no mode to carry: the file keeps the
/// 0644, less the umask, that it was opened with. There is still a
/// group to get right. A file made beside its target would have taken
/// whatever group that directory hands a new file, and a staged one
/// took the staging directory's instead, so a first save into a shared
/// directory would land outside the group everything around it is in.
/// The target's directory is asked, and its answer is given to the temp
/// file on the same best effort terms.
#[cfg(unix)]
fn carry_identity(
    file: &std::fs::File,
    existing: Option<&std::fs::Metadata>,
    target_dir: &Path,
) -> io::Result<()> {
    use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

    let Some(existing) = existing else {
        let inherited = std::fs::metadata(target_dir)
            .ok()
            .and_then(|dir| group_a_new_file_takes(&dir));
        if let Some(gid) = inherited
            && file.metadata().is_ok_and(|meta| meta.gid() != gid)
        {
            let _ = std::os::unix::fs::fchown(file, None, Some(gid));
        }
        return Ok(());
    };
    file.set_permissions(std::fs::Permissions::from_mode(existing.mode() & 0o777))?;
    if file
        .metadata()
        .is_ok_and(|meta| meta.gid() != existing.gid())
    {
        let _ = std::os::unix::fs::fchown(file, None, Some(existing.gid()));
    }
    Ok(())
}

/// The group a file created in `dir` would be given, when that is the
/// directory's to decide.
///
/// On macOS and the other BSD descended systems a new file always takes
/// its directory's group. Linux gives it the creating process's group
/// unless the directory carries the set group id bit, so without the
/// bit there is nothing to restore and the answer is none.
#[cfg(unix)]
fn group_a_new_file_takes(dir: &std::fs::Metadata) -> Option<u32> {
    use std::os::unix::fs::MetadataExt as _;

    const SET_GROUP_ID: u32 = 0o2000;
    if cfg!(target_os = "linux") && dir.mode() & SET_GROUP_ID == 0 {
        return None;
    }
    Some(dir.gid())
}

#[cfg(not(unix))]
fn carry_identity(
    _file: &std::fs::File,
    _existing: Option<&std::fs::Metadata>,
    _target_dir: &Path,
) -> io::Result<()> {
    Ok(())
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
/// A path that is already open hands back the id it is open under. The
/// one exception is a row that is still `pendingHydration`: its buffer
/// is not the file's text yet, so the open refuses with an `io` error
/// rather than hand back an id the shell would then draw. The shell
/// hydrates such a row first and asks again.
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
    match guard.files.open(&RealFileIo::new(), Path::new(path)) {
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
        OpenRefusal::Binary => serde_json::json!({ "error": "binary" }),
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
/// never outlives its tab. Any dirty-close decision is settled in the
/// shell before this call.
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
    unsafe { apply(handle, file, ops_json, None) }
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
    unsafe { apply(handle, file, ops_json, Some((EditIntent::Automation, None))) }
}

/// Apply a file edit with the gesture supplied by the `TextKit` bridge.
///
/// # Safety
/// `handle` must be a valid handle; `ops_json` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_apply_ops_with_intent(
    handle: *mut CompanionHandle,
    file: u64,
    ops_json: *const c_char,
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
    unsafe { apply(handle, file, ops_json, Some((intent, selection))) }
}

/// # Safety
/// As the two callers above.
unsafe fn apply(
    handle: *mut CompanionHandle,
    file: u64,
    ops_json: *const c_char,
    intent: Option<(EditIntent, Option<companion_core::EditSelection>)>,
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
    match intent {
        Some((intent, Some(selection))) => guard
            .files
            .apply_ops_with_intent_and_selection(id, &ops, wall_ms, intent, selection),
        Some((intent, None)) => guard.files.apply_ops_with_intent(id, &ops, wall_ms, intent),
        None => guard.files.apply_ops(id, &ops, wall_ms),
    }
}

/// End a file's current typing/deletion run without creating an undo item.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_finish_editing_group(
    handle: *mut CompanionHandle,
    file: u64,
    location: u32,
    length: u32,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let id = FileId(file);
    if location == u32::MAX && length == u32::MAX {
        guard.files.finish_editing_group(id)
    } else if location == u32::MAX || length == u32::MAX {
        false
    } else {
        guard.files.finish_editing_group_at(
            id,
            companion_core::TextSelection {
                location_u16: location,
                length_u16: length,
            },
        )
    }
}

/// Whether the file has a step waiting to be taken back. False for an
/// unknown file, and false whenever the answer cannot be had, which is
/// what `companion_sheet_can_undo` answers for a page.
///
/// The pair exists because the page route refuses a tagged id by
/// design, so a shell asking it about a file is told no rather than
/// told the truth, and the undo menu item stays grey over a file with a
/// full stack.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_can_undo(handle: *mut CompanionHandle, file: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    guard.files.can_undo(FileId(file))
}

/// Whether the file has a step waiting to be restored. The counterpart
/// of [`companion_file_can_undo`], on the same terms.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_can_redo(handle: *mut CompanionHandle, file: u64) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    guard.files.can_redo(FileId(file))
}

/// Content-free label for the next file Undo action.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_undo_action_name(
    handle: *mut CompanionHandle,
    file: u64,
) -> *mut c_char {
    unsafe { action_name(handle, file, true) }
}

/// Content-free label for the next file Redo action.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_redo_action_name(
    handle: *mut CompanionHandle,
    file: u64,
) -> *mut c_char {
    unsafe { action_name(handle, file, false) }
}

unsafe fn action_name(handle: *mut CompanionHandle, file: u64, undo: bool) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let id = FileId(file);
    let name = if undo {
        guard.files.undo_action_name(id)
    } else {
        guard.files.redo_action_name(id)
    };
    name.map_or(ptr::null_mut(), |value| into_c_string(value.to_string()))
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
        "selectionLocationUTF16": outcome.selection_u16.map_or(-1, |value| i64::from(value.location_u16)),
        "selectionLengthUTF16": outcome.selection_u16.map_or(-1, |value| i64::from(value.length_u16)),
    });
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Write the buffer back to the file's own path, preserving the BOM and
/// the line ending style it arrived with. False when the write refused,
/// which includes a file standing in a conflict nobody has resolved and
/// a restored file [`companion_file_hydrate`] has not settled yet. Ask
/// [`companion_file_save_error_json`] which refusal it was.
///
/// **A save never makes a file where there is none.** When nothing is
/// at the file's path the answer is false and nothing is written: the
/// person deleted or moved that file, and a save that put a new one
/// there would undo it for them. The path is looked at here, whether or
/// not [`companion_file_check`] was asked first. The row is left with
/// `notFound` set, and a row holding unsaved edits also enters the
/// `missing` conflict. The ways out are [`companion_file_relocate`] and
/// [`companion_file_save_as`]. The one save that does write to an empty
/// path is the one a [`companion_file_resolve_keep_mine`] licensed while
/// the path was already empty. A keep mine given while a copy was there
/// does not license it: that consent is withdrawn and the save refused
/// as above. Nor does one survive the buffer settling back to clean.
///
/// `staging_dir` is where the temp file is made before it is renamed
/// onto the target, or null to make it beside the target. It has to be
/// a directory on the target's volume that this process may create
/// files in. A sandboxed shell cannot create anything beside a granted
/// document, so it passes one; see [`RealFileIo`]. A staging directory
/// that will not serve fails the save rather than falling back.
///
/// # Safety
/// `handle` must be a valid handle; `staging_dir` a valid C string or
/// null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_save(
    handle: *mut CompanionHandle,
    file: u64,
    staging_dir: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    // Forgotten before anything can refuse, so an argument that could
    // not be read is never explained with the reason an earlier save
    // left behind.
    guard.last_save_refusal = None;
    let Ok(staging_dir) = (unsafe { optional_path(staging_dir) }) else {
        return false;
    };
    let outcome = guard
        .files
        .save(&RealFileIo::staging_in(staging_dir), FileId(file));
    guard.last_save_refusal = outcome.err();
    report_save(outcome)
}

/// Write the buffer to `path` and adopt it as the file's path.
/// `staging_dir` is as [`companion_file_save`] describes it, for the
/// new target's volume.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid C string;
/// `staging_dir` a valid C string or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_save_as(
    handle: *mut CompanionHandle,
    file: u64,
    path: *const c_char,
    staging_dir: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    // As the save above: no earlier reason outlives this call.
    guard.last_save_refusal = None;
    let Some(path) = (unsafe { cstr(path) }) else {
        return false;
    };
    let Ok(staging_dir) = (unsafe { optional_path(staging_dir) }) else {
        return false;
    };
    let outcome = guard.files.save_as(
        &RealFileIo::staging_in(staging_dir),
        FileId(file),
        Path::new(path),
    );
    guard.last_save_refusal = outcome.err();
    report_save(outcome)
}

/// Why the last [`companion_file_save`] or [`companion_file_save_as`]
/// on this handle refused, as the JSON described in the header. Null
/// when the last save wrote, when no save has been asked for, and when
/// the last one was refused for an argument that could not be read,
/// which never reached the file. Free with `companion_string_free`.
///
/// The bool a save answers cannot say which of its refusals it was, and
/// the roster row afterwards does not say either: a file marked not
/// found whose write the platform then refused looks exactly like one
/// refused for being not found. The shell owes the person the true
/// sentence, so the reason is kept and asked for here.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_save_error_json(
    handle: *mut CompanionHandle,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let Some(refusal) = guard.last_save_refusal else {
        return ptr::null_mut();
    };
    let value = match refusal {
        SaveError::PendingHydration => serde_json::json!({ "error": "pendingHydration" }),
        SaveError::Conflict => serde_json::json!({ "error": "conflict" }),
        SaveError::NotFound => serde_json::json!({ "error": "notFound" }),
        SaveError::PathInUse => serde_json::json!({ "error": "pathInUse" }),
        SaveError::UnknownFile => serde_json::json!({ "error": "unknownFile" }),
        // The kind's own name, which is a fixed English label from the
        // standard library and carries no part of the path.
        SaveError::Io(kind) => {
            serde_json::json!({ "error": "write", "detail": format!("{kind}") })
        }
    };
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// A path argument that may be null. `Ok(None)` is the null the caller
/// meant; `Err` is a pointer that was given and does not hold a path,
/// which is text that is not UTF-8 or is empty.
///
/// The two are kept apart because they must not be answered alike. A
/// caller that passed something unreadable asked for a particular
/// directory or a particular file, and quietly treating that as "none
/// given" would send a save or a hydration down the route it was trying
/// to avoid. So the entry point refuses instead.
///
/// # Safety
/// `p` must be null or a valid C string that outlives `'a`.
unsafe fn optional_path<'a>(p: *const c_char) -> Result<Option<&'a Path>, ()> {
    if p.is_null() {
        return Ok(None);
    }
    match unsafe { cstr(p) } {
        Some(text) if !text.is_empty() => Ok(Some(Path::new(text))),
        _ => Err(()),
    }
}

/// A refused save names itself in the diagnostic channel as well as to
/// the shell, which asks [`companion_file_save_error_json`]. The
/// refusals have one visible symptom, a file that did not write, and
/// the log is where a report of one can be told from another.
fn report_save(outcome: Result<(), SaveError>) -> bool {
    match outcome {
        Ok(()) => true,
        Err(SaveError::PendingHydration) => {
            diag_fault!(
                "companion-ffi: a file save named a restored file that has not been hydrated \
                 yet. Its buffer is not known to be the file's text, so nothing was written."
            );
            false
        }
        Err(SaveError::Conflict) => {
            diag_fault!(
                "companion-ffi: a file save was refused because the file changed on disk under \
                 unsaved edits and no resolution has been chosen. Nothing was written."
            );
            false
        }
        Err(SaveError::PathInUse) => {
            diag_fault!(
                "companion-ffi: a save as named a path another open file already holds. Two \
                 buffers over one file would race each other on save, so nothing was written."
            );
            false
        }
        Err(SaveError::UnknownFile) => {
            diag_fault!("companion-ffi: a file save named an id nothing is open under.");
            false
        }
        Err(SaveError::NotFound) => {
            diag_fault!(
                "companion-ffi: a file save was refused because nothing is at the file's path \
                 and no keep mine stands. A save does not make a file where one was deleted or \
                 moved, so nothing was written."
            );
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
/// shell asks it on activate and before every save. It also keeps the
/// row's `accessRefused` and `notFound` honest, and a dirty row whose disk
/// copy still cannot be read stays in the `changed` conflict whatever
/// the state answered, so the conflict a hydration set for a refused
/// read is not undone by a stat that happens to match.
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
    let state = guard.files.refresh_conflict(&RealFileIo::new(), id);
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

/// Re-read the file from disk, discarding whatever the buffer held and
/// its undo history. This is the non-interactive reload primitive; an
/// explicit Take theirs uses [`companion_file_resolve_take_theirs`].
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
    guard.files.reload(&RealFileIo::new(), FileId(file)).is_ok()
}

/// Take theirs: adopt the disk copy as one undoable structural change.
/// Undo restores the former draft as dirty against that adopted disk
/// baseline; Redo reapplies the disk copy.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_resolve_take_theirs(
    handle: *mut CompanionHandle,
    file: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard
        .files
        .take_theirs(&RealFileIo::new(), FileId(file))
        .is_ok()
}

/// Keep mine: the first of the three conflict resolutions, and the only
/// one with no other entry point. Take theirs is
/// [`companion_file_resolve_take_theirs`] and the third is
/// [`companion_file_save_as`]. Clears the conflict and lets the next
/// save overwrite whatever is on disk.
///
/// The consent answers the state the path was in when it was given: a
/// copy there, or nothing there. A check or a save that finds the path
/// in the other state withdraws it and raises the conflict for what is
/// true now, and the buffer settling clean withdraws it too. Asked on a
/// `missing` conflict whose file is back at its path, nothing is
/// consented to: the row is put in the state a check would find, and
/// the answer is false when that is a `changed` conflict the person has
/// not been shown.
///
/// Given over a copy that changed, the row reads `isDirty` from then
/// until the save the consent was given for, whatever the buffer is
/// edited or undone to: the text it was last saved as is the copy the
/// disk no longer holds.
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
    guard
        .files
        .resolve_keep_mine(&RealFileIo::new(), FileId(file))
}

/// Bind an open file to `path`, which is where a person has said the
/// file is now, read the disk copy there and settle the file around
/// it. True when the file now answers to that path.
///
/// This is the way back for a file whose roster row reads `missing`,
/// `notFound` or `accessRefused`, and the shell also calls it with no
/// panel when a check finds a file gone and its bookmark has followed
/// it somewhere else. The read settles as [`companion_file_hydrate`]
/// settles one:
///
///   - A file holding no draft adopts the disk copy. When that copy is
///     not the one the file was last measured against, its row carries
///     `externallyReloaded` until
///     [`companion_file_clear_reload_notice`] answers it. A live file
///     whose disk copy holds the text it already holds keeps its
///     buffer, and with it its undo history: a file that was only
///     moved is the same document somewhere else.
///   - A draft stands. When the disk copy is the generation the draft
///     was measured against, told by the file's identity and stamp or
///     by its text, there is no conflict and dirtiness is truthful from
///     here on. Otherwise the file stands in a `changed` conflict, and
///     the disk copy is now one [`companion_file_resolve_take_theirs`]
///     can take.
///   - A row that was still `pendingHydration` is settled and is
///     pending no longer. If its draft had been too large to stage,
///     that is named in [`companion_drafts_notices_json`].
///
/// False leaves the file exactly as it was: its path, its buffer, its
/// conflict and its `accessRefused` mark. It is false for an id nothing is
/// open under, for a path another open file already holds, and for a
/// file that will not open, which is anything an ordinary open refuses.
/// The last of those is explained by [`companion_file_open_error_json`]
/// in the same words an open uses; after the other two that call
/// answers null.
///
/// The shell calls this inside the access the person's choice granted,
/// so the read happens while that grant is open, and makes a fresh
/// bookmark before the grant closes.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_relocate(
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
    if path.is_empty() {
        return false;
    }
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let outcome = guard
        .files
        .relocate(&RealFileIo::new(), FileId(file), Path::new(path));
    guard.last_open_refusal = match outcome {
        Err(RelocateRefusal::Open(refusal)) => Some(refusal),
        _ => None,
    };
    match outcome {
        Ok(notice) => {
            guard.drafts_notices.extend(notice);
            true
        }
        Err(RelocateRefusal::PathInUse) => {
            diag_fault!(
                "companion-ffi: a file was relocated onto a path another open file already \
                 holds. The file kept the path it had, because two buffers over one file would \
                 race each other on save."
            );
            false
        }
        Err(RelocateRefusal::UnknownFile | RelocateRefusal::Open(_)) => false,
    }
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
                "externallyReloaded": file.externally_reloaded(),
                "pendingHydration": file.pending_hydration(),
                "accessRefused": file.access_refused(),
                "notFound": file.not_found(),
            })
        })
        .collect();
    match serde_json::to_string(&roster) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Say that the shell has posted the reload notice for a file, so the
/// roster stops reporting one.
///
/// The roster is a plain read and clears nothing: a shell redraws its
/// strip more than once, and a flag that vanished on the first read
/// would be a notice nobody ever saw. This is the acknowledgement, and
/// it is the only thing that turns `externallyReloaded` off short of a
/// reload.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_clear_reload_notice(
    handle: *mut CompanionHandle,
    file: u64,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.files.clear_reload_notice(FileId(file))
}

// ---------------------------------------------------------------------------
// Drafts: the third sealed file
// ---------------------------------------------------------------------------

/// Seal the open file roster and every dirty file's draft to `path`,
/// under the same content key as the state file and under an envelope
/// magic of its own.
///
/// A draft larger than `DRAFT_SNAPSHOT_LIMIT` is left out and the file
/// is recorded as identity only, which leaves a `draftTooLarge` entry
/// in [`companion_drafts_notices_json`]. The save still succeeds: one
/// oversized draft must not cost the person every other open file.
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
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    match seal_drafts_to(&guard, Path::new(path)) {
        Some(oversized) => {
            guard.drafts_notices.extend(oversized);
            true
        }
        None => false,
    }
}

/// Seal the roster as it stands and write it to `path`, minting the
/// content key halves if this is the first write under them. Shared
/// with the rotation, which has to do the identical write after it has
/// taken the old halves away.
///
/// `None` is a write that did not land. `Some` carries the drafts that
/// were too large to go in, which the caller turns into notices; an
/// empty vector is the ordinary answer.
///
/// The caller holds the lock.
pub(crate) fn seal_drafts_to(
    state: &Companion,
    path: &Path,
) -> Option<Vec<companion_core::FileNotice>> {
    let wall_ms = wall_now_ms()?;
    let key = persist::ensure_state_key(state.credentials.as_ref(), path)?;
    let emitted = file_persist::emit(&state.files, wall_ms);
    // The buffer holds a person's unsaved typing, so it is wiped on the
    // way out whatever happens to the write.
    let plaintext = Zeroizing::new(emitted.bytes);
    let sealed = persist::seal_body(&key, DRAFTS_MAGIC, &plaintext)?;
    let mut file = Vec::with_capacity(DRAFTS_MAGIC.len() + sealed.len());
    file.extend_from_slice(DRAFTS_MAGIC);
    file.extend_from_slice(&sealed);
    persist::write_private(path, &file).then_some(emitted.oversized)
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
/// **The roster this returns is not ready to draw.** This call opens
/// the drafts file and puts its records back, and it reads no file of
/// the person's. Every row comes back with `pendingHydration` set, and
/// the shell owes each one a [`companion_file_hydrate`] before it
/// draws, edits or saves it. The core refuses an edit, a save, a
/// reload and a conflict resolution on a pending file, so a shell that
/// forgets is told no rather than allowed to write an unfilled buffer
/// over somebody's document.
///
/// The read is a separate call because under a sandbox a file can only
/// be read while its own grant is open, and only the shell can open
/// one. Reading every file from here would read them all before any
/// bookmark had been resolved.
///
/// False here means the drafts file itself did not open.
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
    if let Err(error) = file_persist::restore(&mut guard.files, &plaintext, wall_ms) {
        diag_fault!(
            "companion-ffi: the drafts file authenticated but the core rejected the \
             snapshot inside it ({error})."
        );
        return false;
    }
    true
}

/// The second half of a drafts restore, for one file: look at the disk
/// and leave the file in a state the shell can draw. True when the file
/// stands in the roster afterwards; false when it was dropped from it,
/// when nothing is open under the id, and when `resolved_path` was
/// given and is not a path.
///
/// `resolved_path` is where the shell's bookmark resolved to, or null
/// when the file has no bookmark or it would not resolve. A file that
/// was moved while the app was closed is rebound to that path before
/// anything is read, and the roster reports the new path from then on.
/// The rebind is refused when another open file that has itself been
/// hydrated already holds the resolved path, for the reason
/// [`companion_file_save_as`] refuses the same thing: the file is then
/// hydrated at the path its record carried, and the roster still shows
/// that path afterwards, which is how the shell can tell. Null reads
/// the recorded path.
///
/// **A hydration can wait.** When the resolved path is the recorded
/// path of another file that is still pending, nothing is read and
/// nothing is decided: that file may have been moved off the path, and
/// its own hydration is what says so. The answer is true, because the
/// file stands in the roster, and its row still reads
/// `pendingHydration`, which is how the shell tells a wait from a
/// settlement. The shell hydrates the other files and asks again. Two
/// files that wait on each other are ended by hydrating one of them
/// with null, which never waits. A file left waiting stays pending, and
/// a pending file refuses every save and every edit, so a shell that
/// forgot to ask again loses nothing.
///
/// What the read decides, per file:
///
///   - A clean file is filled from disk. If the disk copy had changed
///     it is filled anyway, without asking, and its roster row carries
///     `externallyReloaded` until
///     [`companion_file_clear_reload_notice`] answers it.
///   - A dirty file keeps its draft. If the disk copy is unchanged the
///     draft is measured against it, so dirtiness is truthful from here
///     on and stepping back to the file's text reads as clean; the
///     persisted `lastEditedAt` survives, since the header states the
///     draft's age. If the disk copy changed or will not read, the file
///     stands in a `changed` conflict; if it is gone, a `missing` one.
///     Where the read was one the platform refused, the row also
///     carries `accessRefused`.
///   - A clean file that is gone, or that is there and will not open
///     as text, is dropped from the roster and named in
///     [`companion_drafts_notices_json`].
///
/// **A hydration can hold.** A clean file whose read the platform
/// refused, which is what a sandbox answers for a file whose grant is
/// gone, is neither filled nor dropped. Something is there, and the
/// person may know where the file is. The answer is true, the row
/// stays `pendingHydration` and gains `accessRefused`, and its buffer is
/// empty and refuses every edit and every save. The pair of flags is
/// how the shell tells a hold from a wait. The way out is
/// [`companion_file_relocate`], or this call again once the file can
/// be read, or a close.
///
/// **One file never costs another.** Nothing here touches any file but
/// the one named: a launch that lost every open tab because one of
/// them was on an unmounted volume would be the worse answer by a
/// distance.
///
/// A file that is not pending is left exactly as it is and answered
/// true, so asking twice is harmless and a second call never rebinds.
///
/// The shell calls this inside the file's access grant, so the read
/// happens while the grant is open.
///
/// # Safety
/// `handle` must be a valid handle; `resolved_path` a valid C string or
/// null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_hydrate(
    handle: *mut CompanionHandle,
    file: u64,
    resolved_path: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Ok(resolved_path) = (unsafe { optional_path(resolved_path) }) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    let outcome = guard
        .files
        .hydrate_one(&RealFileIo::new(), FileId(file), resolved_path);
    if outcome.rebind == PathRebind::Refused {
        diag_fault!(
            "companion-ffi: a restored file's bookmark resolved to a path another open file \
             already holds. The file kept the path its record carried, because two buffers \
             over one file would race each other on save."
        );
    }
    guard.drafts_notices.extend(outcome.notice);
    matches!(
        outcome.fate,
        HydrationFate::Kept
            | HydrationFate::NotPending
            | HydrationFate::Deferred
            | HydrationFate::Held
    )
}

/// Everything the last drafts save and the hydrations after a drafts
/// restore have to tell the user about, as JSON:
///
/// ```text
/// [{"name": string, "path": string,
///   "reason": "missing" | "unreadable" | "draftTooLarge"}]
/// ```
///
/// `missing` and `unreadable` are files that were open at the last quit
/// and are not in the roster now: nothing is at the path any more, or
/// something is and this build will not open it, because it is not
/// UTF-8, looks binary or is past the size limit. `unreadable` here is
/// never the roster's `accessRefused`: a file the platform would not
/// let this process read is not dropped and is not in this list.
/// `draftTooLarge` is a
/// file that did come back, filled from disk and clean, whose unsaved
/// editing was over the drafts file's size bound and was not staged.
///
/// **Reading drains the list.** This is a call the shell makes once
/// after it has hydrated every restored file, not a view it polls, and
/// an entry that stayed would
/// be posted again on the next launch. The roster's own
/// `externallyReloaded` flag is the opposite and is deliberately so: it
/// is polled, so it is sticky and
/// [`companion_file_clear_reload_notice`] answers it.
///
/// An empty array is the ordinary answer. Null when the answer cannot
/// be had. Free with `companion_string_free`.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_drafts_notices_json(
    handle: *mut CompanionHandle,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let notices: Vec<serde_json::Value> = guard
        .drafts_notices
        .drain(..)
        .map(|notice| {
            serde_json::json!({
                "name": notice.name,
                "path": notice.path,
                "reason": notice.reason.as_str(),
            })
        })
        .collect();
    match serde_json::to_string(&notices) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
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
pub(crate) fn reseal_drafts_beside(state: &mut Companion, state_path: &Path) -> bool {
    let Some(path) = drafts_path_beside(state_path) else {
        return true;
    };
    if !path.exists() && state.files.files().is_empty() {
        return true;
    }
    match seal_drafts_to(state, &path) {
        Some(oversized) => {
            state.drafts_notices.extend(oversized);
            true
        }
        None => {
            diag_fault!(
                "companion-ffi: the drafts file could not be rewritten under the rotated \
                 content key. Every unsaved file edit staged in it is unreadable from now on."
            );
            false
        }
    }
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
        // Resolved, because the store resolves every path it is given
        // and the temp directory on macOS is reached through a symlink.
        // A test that compared an unresolved path against the roster
        // would be asserting the wrong thing.
        std::fs::canonicalize(&dir).unwrap()
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
            last_save_refusal: None,
            drafts_notices: Vec::new(),
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

    /// The whole of a relaunch as a shell with no bookmark to resolve
    /// performs it: restore the records, then hydrate every pending
    /// row at the path its record carried. Answers what the restore
    /// answered.
    unsafe fn restore_and_hydrate(handle: *mut CompanionHandle, drafts: &CString) -> bool {
        if !unsafe { companion_drafts_restore(handle, drafts.as_ptr()) } {
            return false;
        }
        for row in unsafe { roster(handle) }.as_array().unwrap() {
            assert_eq!(
                row["pendingHydration"],
                serde_json::json!(true),
                "every restored row waits on its hydration"
            );
            let id = row["id"].as_u64().unwrap();
            // The answer is whether the file still stands, which each
            // test reads off the roster for itself.
            let _ = unsafe { companion_file_hydrate(handle, id, ptr::null()) };
        }
        true
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

            assert!(companion_file_save(handle, id, ptr::null()));
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
            assert_eq!(row["externallyReloaded"], serde_json::json!(false));
            assert_eq!(row["pendingHydration"], serde_json::json!(false));
            assert_eq!(row["accessRefused"], serde_json::json!(false));
            assert_eq!(row["notFound"], serde_json::json!(false));
            // The mark was once spelled the way the notice reason
            // still is. The two are different things, and the row no
            // longer carries the old word.
            assert!(row.get("unreadable").is_none());
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_save_never_recreates_a_file_that_is_gone_from_its_path() {
        // Against the real filesystem and with no check asked first:
        // the save looks at the path itself.
        let (handle, dir) = scratch("no-recreate");
        let clean = dir.join("clean.txt");
        let dirty = dir.join("dirty.txt");
        std::fs::write(&clean, b"clean").unwrap();
        std::fs::write(&dirty, b"one").unwrap();
        unsafe {
            let clean_id = open(handle, &clean);
            let dirty_id = open(handle, &dirty);
            let ops = cstring(r#"[{"ins":{"at":3,"text":" mine"}}]"#);
            assert!(companion_file_apply_ops(handle, dirty_id, ops.as_ptr()));
            std::fs::remove_file(&clean).unwrap();
            std::fs::remove_file(&dirty).unwrap();

            assert!(!companion_file_save(handle, clean_id, ptr::null()));
            assert!(!clean.exists(), "a clean file is not written back");
            assert!(!companion_file_save(handle, dirty_id, ptr::null()));
            assert!(!dirty.exists(), "nor is a draft, without a keep mine");

            let row = roster(handle);
            assert_eq!(row[0]["notFound"], serde_json::json!(true));
            assert_eq!(row[0]["conflict"], serde_json::json!("none"));
            assert_eq!(row[1]["notFound"], serde_json::json!(true));
            assert_eq!(row[1]["conflict"], serde_json::json!("missing"));
            assert_eq!(row[1]["isDirty"], serde_json::json!(true));

            // A staging directory changes nothing about the refusal,
            // and nothing is left behind in it.
            let staging = dir.join("staging");
            std::fs::create_dir(&staging).unwrap();
            let staging_c = cstring(&staging.to_string_lossy());
            assert!(!companion_file_save(handle, clean_id, staging_c.as_ptr()));
            assert!(!clean.exists());
            assert_eq!(std::fs::read_dir(&staging).unwrap().count(), 0);

            // Keep mine is the consent that makes the file again.
            assert!(companion_file_resolve_keep_mine(handle, dirty_id));
            assert!(companion_file_save(handle, dirty_id, ptr::null()));
            assert_eq!(std::fs::read(&dirty).unwrap(), b"one mine");

            // And save as is the way out for the clean one, back at
            // the very path it left.
            let clean_c = cstring(&clean.to_string_lossy());
            assert!(companion_file_save_as(
                handle,
                clean_id,
                clean_c.as_ptr(),
                ptr::null()
            ));
            assert_eq!(std::fs::read(&clean).unwrap(), b"clean");
            assert_eq!(roster(handle)[0]["notFound"], serde_json::json!(false));
        }
        cleanup(handle, &dir);
    }

    /// Why the last save refused, or `None` when the seam answers null.
    unsafe fn save_error(handle: *mut CompanionHandle) -> Option<serde_json::Value> {
        let error = unsafe { companion_file_save_error_json(handle) };
        if error.is_null() {
            return None;
        }
        Some(serde_json::from_str(&unsafe { take_json(error) }).unwrap())
    }

    #[test]
    fn a_refused_save_says_which_refusal_it_was() {
        let (handle, dir) = scratch("save-error");
        let clean = dir.join("clean.txt");
        let dirty = dir.join("dirty.txt");
        std::fs::write(&clean, b"clean").unwrap();
        std::fs::write(&dirty, b"one").unwrap();
        unsafe {
            assert_eq!(save_error(handle), None, "no save has been asked for");
            let clean_id = open(handle, &clean);
            let dirty_id = open(handle, &dirty);
            let ops = cstring(r#"[{"ins":{"at":3,"text":" mine"}}]"#);
            assert!(companion_file_apply_ops(handle, dirty_id, ops.as_ptr()));

            // A draft over a copy somebody else wrote.
            std::fs::write(&dirty, b"theirs, and longer").unwrap();
            take_json(companion_file_check(handle, dirty_id));
            assert!(!companion_file_save(handle, dirty_id, ptr::null()));
            assert_eq!(
                save_error(handle),
                Some(serde_json::json!({ "error": "conflict" }))
            );
            // Asking is a plain read, so asking twice answers twice.
            assert_eq!(
                save_error(handle),
                Some(serde_json::json!({ "error": "conflict" }))
            );

            // A clean file whose path is empty.
            std::fs::remove_file(&clean).unwrap();
            assert!(!companion_file_save(handle, clean_id, ptr::null()));
            assert_eq!(
                save_error(handle),
                Some(serde_json::json!({ "error": "notFound" }))
            );

            // An id nothing is open under.
            assert!(!companion_file_save(handle, u64::MAX, ptr::null()));
            assert_eq!(
                save_error(handle),
                Some(serde_json::json!({ "error": "unknownFile" }))
            );

            // An argument that cannot be read never reaches the file,
            // and is not explained with the reason the save before it
            // left behind.
            let empty = cstring("");
            assert!(!companion_file_save(handle, clean_id, empty.as_ptr()));
            assert_eq!(save_error(handle), None);
            assert!(!companion_file_save(handle, clean_id, ptr::null()));
            assert!(save_error(handle).is_some());
            assert!(!companion_file_save_as(
                handle,
                clean_id,
                ptr::null(),
                ptr::null()
            ));
            assert_eq!(save_error(handle), None);

            // A save that writes leaves nothing to explain.
            assert!(companion_file_resolve_keep_mine(handle, dirty_id));
            assert!(!companion_file_save(handle, clean_id, ptr::null()));
            assert!(companion_file_save(handle, dirty_id, ptr::null()));
            assert_eq!(save_error(handle), None);
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_write_the_platform_refuses_is_not_reported_as_a_file_not_found() {
        // The corner the bool could not tell apart. The file is gone,
        // a keep mine over the empty path licenses making it again, and
        // then the write itself fails. The row still says not found,
        // and the true reason is the write.
        let (handle, dir) = scratch("save-error-write");
        let file = dir.join("gone.txt");
        std::fs::write(&file, b"one").unwrap();
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":3,"text":" mine"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            std::fs::remove_file(&file).unwrap();
            take_json(companion_file_check(handle, id));
            assert!(companion_file_resolve_keep_mine(handle, id));

            // A staging directory that is not there fails the write and
            // nothing else about the save.
            let absent = cstring(&dir.join("no-such-staging").to_string_lossy());
            assert!(!companion_file_save(handle, id, absent.as_ptr()));
            let error = save_error(handle).expect("the save refused");
            assert_eq!(error["error"], serde_json::json!("write"));
            assert!(
                error["detail"]
                    .as_str()
                    .is_some_and(|kind| !kind.is_empty()),
                "the kind of failure travels with it"
            );
            assert!(!file.exists());
            let row = roster(handle);
            assert_eq!(
                row[0]["notFound"],
                serde_json::json!(true),
                "which is all a shell reading the row would have had"
            );
            assert_eq!(row[0]["conflict"], serde_json::json!("none"));

            // The consent was not spent on a write that did not land.
            assert!(companion_file_save(handle, id, ptr::null()));
            assert_eq!(save_error(handle), None);
            assert_eq!(std::fs::read(&file).unwrap(), b"one mine");
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
            assert!(companion_file_save(handle, id, ptr::null()));
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
            assert!(companion_file_save(handle, id, ptr::null()));
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

    // -----------------------------------------------------------------
    // The staged write
    // -----------------------------------------------------------------

    /// Every name in a directory, so a test can say nothing was left.
    fn names_in(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    /// A target directory and a staging directory beside it, both
    /// inside one scratch directory and so on one volume.
    fn target_and_staging(tag: &str) -> (PathBuf, PathBuf, PathBuf) {
        let root = scratch_dir(tag);
        let docs = root.join("docs");
        let staging = root.join("staging");
        std::fs::create_dir(&docs).unwrap();
        std::fs::create_dir(&staging).unwrap();
        (root, docs, staging)
    }

    #[test]
    fn a_staged_write_lands_the_bytes_and_leaves_both_directories_clean() {
        let (root, docs, staging) = target_and_staging("staged");
        let target = docs.join("note.txt");
        std::fs::write(&target, b"old").unwrap();

        let io = RealFileIo::staging_in(Some(&staging));
        io.write_atomic(&target, b"new text").unwrap();

        assert_eq!(std::fs::read(&target).unwrap(), b"new text");
        assert_eq!(
            names_in(&docs),
            ["note.txt"],
            "nothing was made beside the file"
        );
        assert!(
            names_in(&staging).is_empty(),
            "the temp file left the staging directory with the rename"
        );

        // A target that is not there yet is created the same way.
        let fresh = docs.join("fresh.txt");
        io.write_atomic(&fresh, b"first").unwrap();
        assert_eq!(std::fs::read(&fresh).unwrap(), b"first");
        assert!(names_in(&staging).is_empty());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(&fresh).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode & !0o644, 0, "a new file takes 0644 at the most");
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_staged_write_whose_rename_fails_takes_its_temp_file_back() {
        let (root, docs, staging) = target_and_staging("staged-fail");
        // A directory with something in it can never be replaced by a
        // file, so the rename is refused after the temp file has been
        // written in full. That is the step a missing grant or a
        // staging directory on another volume refuses too.
        let target = docs.join("occupied");
        std::fs::create_dir(&target).unwrap();
        std::fs::write(target.join("inside.txt"), b"theirs").unwrap();

        let io = RealFileIo::staging_in(Some(&staging));
        assert!(io.write_atomic(&target, b"mine").is_err());

        assert!(
            names_in(&staging).is_empty(),
            "a failed save must not strand the text in the staging directory"
        );
        assert_eq!(names_in(&docs), ["occupied"]);
        assert_eq!(std::fs::read(target.join("inside.txt")).unwrap(), b"theirs");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_staging_directory_that_is_not_there_fails_the_save_without_falling_back() {
        let (root, docs, staging) = target_and_staging("staged-absent");
        let target = docs.join("note.txt");
        std::fs::write(&target, b"old").unwrap();
        std::fs::remove_dir(&staging).unwrap();

        let io = RealFileIo::staging_in(Some(&staging));
        assert!(io.write_atomic(&target, b"new").is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"old");
        assert_eq!(
            names_in(&docs),
            ["note.txt"],
            "the sibling route was not taken behind the caller's back"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn a_staged_write_keeps_the_mode_and_the_group_the_file_already_had() {
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

        let (root, docs, staging) = target_and_staging("staged-mode");
        let target = docs.join("m.txt");
        std::fs::write(&target, b"body").unwrap();
        // Group writable, which the usual umask would strip from a
        // mode that was only asked for at open.
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o664)).unwrap();
        let before = std::fs::metadata(&target).unwrap();

        RealFileIo::staging_in(Some(&staging))
            .write_atomic(&target, b"body!")
            .unwrap();

        let after = std::fs::metadata(&target).unwrap();
        assert_eq!(after.mode() & 0o777, 0o664);
        assert_eq!(after.gid(), before.gid());
        assert_ne!(after.ino(), before.ino(), "the write replaced the file");
        assert_eq!(std::fs::read(&target).unwrap(), b"body!");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A group this user belongs to other than `not`, asked of `id`
    /// rather than of libc, which this crate links on macOS only.
    #[cfg(unix)]
    fn another_group_of_mine(not: u32) -> Option<u32> {
        let output = std::process::Command::new("id").arg("-G").output().ok()?;
        String::from_utf8(output.stdout)
            .ok()?
            .split_whitespace()
            .filter_map(|word| word.parse::<u32>().ok())
            .find(|gid| *gid != not)
    }

    #[cfg(unix)]
    #[test]
    fn a_staged_write_of_a_new_file_takes_the_group_its_own_directory_gives() {
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

        let (root, docs, staging) = target_and_staging("staged-group");
        let staging_gid = std::fs::metadata(&staging).unwrap().gid();
        // The shared directory: in a group the staging directory is
        // not, and with the set group id bit, which is what makes a
        // new file take the directory's group on Linux and changes
        // nothing on macOS, where it always does.
        let Some(shared) = another_group_of_mine(staging_gid) else {
            // A user in one group has no second one to tell apart.
            let _ = std::fs::remove_dir_all(&root);
            return;
        };
        if std::os::unix::fs::chown(&docs, None, Some(shared)).is_err() {
            let _ = std::fs::remove_dir_all(&root);
            return;
        }
        std::fs::set_permissions(&docs, std::fs::Permissions::from_mode(0o2755)).unwrap();

        // What a file made beside its target gets, measured rather
        // than assumed.
        let sibling = docs.join("sibling.txt");
        RealFileIo::new().write_atomic(&sibling, b"beside").unwrap();
        let expected = std::fs::metadata(&sibling).unwrap().gid();
        assert_eq!(expected, shared);

        let fresh = docs.join("fresh.txt");
        RealFileIo::staging_in(Some(&staging))
            .write_atomic(&fresh, b"first")
            .unwrap();

        assert_eq!(
            std::fs::metadata(&fresh).unwrap().gid(),
            expected,
            "a staged first save lands in the group a sibling would have"
        );
        assert_eq!(std::fs::read(&fresh).unwrap(), b"first");
        assert!(names_in(&staging).is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn with_no_staging_directory_the_temp_file_is_a_sibling_as_before() {
        let (root, docs, staging) = target_and_staging("sibling");
        let target = docs.join("note.txt");
        std::fs::write(&target, b"old").unwrap();
        // The directory the target sits in is made unwritable for the
        // length of the write, which is the difference between the two
        // routes made visible: the sibling route has to create there
        // and cannot, and the staged route never tries.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&docs, std::fs::Permissions::from_mode(0o555)).unwrap();
            let refused = RealFileIo::new().write_atomic(&target, b"new");
            std::fs::set_permissions(&docs, std::fs::Permissions::from_mode(0o755)).unwrap();
            // Root writes anywhere, so a suite run as root learns
            // nothing from this half and is not failed for it.
            if let Err(error) = refused {
                assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
                assert_eq!(std::fs::read(&target).unwrap(), b"old");
            }
        }
        RealFileIo::new().write_atomic(&target, b"new").unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        assert_eq!(
            names_in(&docs),
            ["note.txt"],
            "the sibling temp was renamed"
        );
        assert!(
            names_in(&staging).is_empty(),
            "a directory nobody named was not used"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_save_and_a_save_as_stage_where_the_shell_says() {
        let (handle, root) = scratch("staged-seam");
        let docs = root.join("docs");
        let staging = root.join("staging");
        std::fs::create_dir(&docs).unwrap();
        std::fs::create_dir(&staging).unwrap();
        let file = docs.join("note.txt");
        let copy = docs.join("copy.txt");
        std::fs::write(&file, b"hello").unwrap();
        let staging_c = cstring(&staging.to_string_lossy());
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":5,"text":" world"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            assert!(companion_file_save(handle, id, staging_c.as_ptr()));
            assert_eq!(std::fs::read(&file).unwrap(), b"hello world");
            assert_eq!(roster(handle)[0]["isDirty"], serde_json::json!(false));

            let target = cstring(&copy.to_string_lossy());
            assert!(companion_file_save_as(
                handle,
                id,
                target.as_ptr(),
                staging_c.as_ptr()
            ));
            assert_eq!(std::fs::read(&copy).unwrap(), b"hello world");
            assert_eq!(
                roster(handle)[0]["path"],
                serde_json::json!(copy.to_string_lossy())
            );

            // A staging argument that was given and is not a path is
            // refused outright rather than read as "none given".
            let ops = cstring(r#"[{"ins":{"at":0,"text":"x"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            let empty = cstring("");
            assert!(!companion_file_save(handle, id, empty.as_ptr()));
            assert!(!companion_file_save_as(
                handle,
                id,
                target.as_ptr(),
                empty.as_ptr()
            ));
            assert_eq!(std::fs::read(&copy).unwrap(), b"hello world");
        }
        assert_eq!(names_in(&docs), ["copy.txt", "note.txt"]);
        assert!(names_in(&staging).is_empty());
        cleanup(handle, &root);
    }

    #[test]
    fn refusals_name_themselves() {
        let (handle, dir) = scratch("refuse");
        let bad = dir.join("bad.bin");
        std::fs::write(&bad, [0x66, 0xFF, 0xFE]).unwrap();
        let binary = dir.join("binary.txt");
        std::fs::write(&binary, b"alpha\0beta").unwrap();
        let big = dir.join("big.txt");
        std::fs::write(&big, vec![b'x'; LIMIT + 1]).unwrap();
        unsafe {
            assert_eq!(open(handle, &bad), 0);
            let error = take_json(companion_file_open_error_json(handle));
            assert_eq!(error, r#"{"error":"notUtf8"}"#);

            assert_eq!(open(handle, &binary), 0);
            let error = take_json(companion_file_open_error_json(handle));
            assert_eq!(error, r#"{"error":"binary"}"#);

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

            assert!(!companion_file_save(handle, id, ptr::null()));
            assert_eq!(std::fs::read(&file).unwrap(), b"theirs");

            assert!(companion_file_resolve_keep_mine(handle, id));
            assert_eq!(roster(handle)[0]["conflict"], serde_json::json!("none"));
            assert!(companion_file_save(handle, id, ptr::null()));
            assert_eq!(std::fs::read(&file).unwrap(), b"one mine");
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn take_theirs_crosses_the_ffi_as_an_undoable_resolution() {
        let (handle, dir) = scratch("take-theirs");
        let file = dir.join("take.txt");
        std::fs::write(&file, b"one\n").unwrap();
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":3,"text":" mine"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            std::fs::write(&file, [&[0xEF, 0xBB, 0xBFu8][..], b"theirs\r\n"].concat()).unwrap();
            let _ = take_json(companion_file_check(handle, id));

            assert!(companion_file_resolve_take_theirs(handle, id));
            assert_eq!(
                take_json(companion_file_runs_json(handle, id)),
                r#"[{"ink":"theirs\n"}]"#
            );
            let row = roster(handle);
            assert_eq!(row[0]["isDirty"], serde_json::json!(false));
            assert_eq!(row[0]["conflict"], serde_json::json!("none"));
            assert_eq!(row[0]["lineEnding"], serde_json::json!("crlf"));
            assert_eq!(row[0]["hasBOM"], serde_json::json!(true));

            let typing = cstring(r#"[{"ins":{"at":6,"text":"!"}}]"#);
            assert!(companion_file_apply_ops(handle, id, typing.as_ptr()));

            let undo_typing: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_undo(handle, id))).unwrap();
            assert_eq!(undo_typing["applied"], serde_json::json!(true));
            assert_eq!(
                take_json(companion_file_runs_json(handle, id)),
                r#"[{"ink":"theirs\n"}]"#
            );
            assert_eq!(roster(handle)[0]["isDirty"], serde_json::json!(false));
            assert!(companion_file_can_undo(handle, id));

            let undo_resolution: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_undo(handle, id))).unwrap();
            assert_eq!(undo_resolution["applied"], serde_json::json!(true));
            assert_eq!(
                take_json(companion_file_runs_json(handle, id)),
                r#"[{"ink":"one mine\n"}]"#
            );
            assert_eq!(roster(handle)[0]["isDirty"], serde_json::json!(true));

            let redo_resolution: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_redo(handle, id))).unwrap();
            assert_eq!(redo_resolution["applied"], serde_json::json!(true));
            assert_eq!(
                take_json(companion_file_runs_json(handle, id)),
                r#"[{"ink":"theirs\n"}]"#
            );
            assert_eq!(roster(handle)[0]["isDirty"], serde_json::json!(false));

            let redo_typing: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_redo(handle, id))).unwrap();
            assert_eq!(redo_typing["applied"], serde_json::json!(true));
            assert_eq!(
                take_json(companion_file_runs_json(handle, id)),
                r#"[{"ink":"theirs!\n"}]"#
            );
            assert_eq!(roster(handle)[0]["isDirty"], serde_json::json!(true));
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
            assert_eq!(roster(handle)[0]["notFound"], serde_json::json!(true));

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
            assert!(companion_file_save_as(
                handle,
                id,
                target.as_ptr(),
                ptr::null()
            ));
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
            assert!(restore_and_hydrate(relaunch, &drafts_c));
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

    unsafe fn notices(handle: *mut CompanionHandle) -> serde_json::Value {
        let json = unsafe { take_json(companion_drafts_notices_json(handle)) };
        serde_json::from_str(&json).unwrap()
    }

    /// One clean file and one dirty one staged into a drafts file, and
    /// the credential store that opens it again. The caller changes
    /// what is on disk before relaunching.
    fn staged(
        tag: &str,
    ) -> (
        std::sync::Arc<dyn companion_credentials::CredentialStore>,
        PathBuf,
        PathBuf,
        PathBuf,
        CString,
    ) {
        let keys = credentials();
        let handle = handle_with(keys.clone());
        let dir = scratch_dir(tag);
        let drafts = dir.join(DRAFTS_FILE_NAME);
        let clean = dir.join("clean.txt");
        let dirty = dir.join("dirty.txt");
        std::fs::write(&clean, b"clean body\n").unwrap();
        std::fs::write(&dirty, b"dirty body\n").unwrap();
        let drafts_c = cstring(&drafts.to_string_lossy());
        unsafe {
            open(handle, &clean);
            let id = open(handle, &dirty);
            let ops = cstring(r#"[{"ins":{"at":0,"text":"typed "}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            assert!(companion_drafts_save(handle, drafts_c.as_ptr()));
            // A save reports no notices when nothing was left out.
            assert_eq!(notices(handle), serde_json::json!([]));
            crate::companion_free(handle);
        }
        (keys, dir, clean, dirty, drafts_c)
    }

    #[test]
    fn a_restore_hands_back_a_roster_that_is_ready_to_draw() {
        let (keys, dir, _clean, _dirty, drafts_c) = staged("hydrate");
        let handle = handle_with(keys);
        unsafe {
            assert!(restore_and_hydrate(handle, &drafts_c));
            let row = roster(handle);
            // The clean file arrived filled from disk, with nothing to
            // say about it. The hydration was the read, so the shell
            // calls no reload of its own.
            assert_eq!(row[0]["pendingHydration"], serde_json::json!(false));
            assert_eq!(row[0]["isDirty"], serde_json::json!(false));
            assert_eq!(row[0]["externallyReloaded"], serde_json::json!(false));
            let clean_id = row[0]["id"].as_u64().unwrap();
            assert_eq!(
                take_json(companion_file_runs_json(handle, clean_id)),
                r#"[{"ink":"clean body\n"}]"#
            );
            // The dirty one kept its draft and knows the disk copy.
            assert_eq!(row[1]["isDirty"], serde_json::json!(true));
            assert_eq!(row[1]["conflict"], serde_json::json!("none"));
            let dirty_id = row[1]["id"].as_u64().unwrap();
            let ops = cstring(r#"[{"del":{"at":0,"len":6}}]"#);
            assert!(companion_file_apply_ops(handle, dirty_id, ops.as_ptr()));
            assert_eq!(
                roster(handle)[1]["isDirty"],
                serde_json::json!(false),
                "back at the file's own text is clean"
            );
            assert_eq!(notices(handle), serde_json::json!([]));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_clean_file_that_changed_comes_back_reloaded_with_a_sticky_flag() {
        let (keys, dir, clean, _dirty, drafts_c) = staged("reloaded");
        std::fs::write(&clean, b"somebody else wrote this\n").unwrap();
        let handle = handle_with(keys);
        unsafe {
            assert!(restore_and_hydrate(handle, &drafts_c));
            let row = roster(handle);
            let id = row[0]["id"].as_u64().unwrap();
            assert_eq!(row[0]["isDirty"], serde_json::json!(false));
            assert_eq!(row[0]["externallyReloaded"], serde_json::json!(true));
            assert_eq!(
                take_json(companion_file_runs_json(handle, id)),
                r#"[{"ink":"somebody else wrote this\n"}]"#
            );
            // Reading the roster again does not lose the flag; only the
            // acknowledgement clears it.
            assert_eq!(
                roster(handle)[0]["externallyReloaded"],
                serde_json::json!(true)
            );
            assert!(companion_file_clear_reload_notice(handle, id));
            assert_eq!(
                roster(handle)[0]["externallyReloaded"],
                serde_json::json!(false)
            );
            assert!(!companion_file_clear_reload_notice(handle, 0));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_dirty_file_whose_disk_copy_changed_comes_back_in_a_conflict() {
        let (keys, dir, _clean, dirty, drafts_c) = staged("conflicted");
        std::fs::write(&dirty, b"somebody else wrote this\n").unwrap();
        let handle = handle_with(keys);
        unsafe {
            assert!(restore_and_hydrate(handle, &drafts_c));
            let row = roster(handle);
            let id = row[1]["id"].as_u64().unwrap();
            assert_eq!(row[1]["isDirty"], serde_json::json!(true));
            assert_eq!(row[1]["conflict"], serde_json::json!("changed"));
            assert_eq!(
                take_json(companion_file_runs_json(handle, id)),
                r#"[{"ink":"typed dirty body\n"}]"#
            );
            assert!(!companion_file_save(handle, id, ptr::null()));
            assert!(companion_file_resolve_keep_mine(handle, id));
            assert!(companion_file_save(handle, id, ptr::null()));
        }
        assert_eq!(std::fs::read(&dirty).unwrap(), b"typed dirty body\n");
        cleanup(handle, &dir);
    }

    #[test]
    fn a_missing_file_drops_the_clean_one_and_keeps_the_dirty_one() {
        let (keys, dir, clean, dirty, drafts_c) = staged("gone");
        std::fs::remove_file(&clean).unwrap();
        std::fs::remove_file(&dirty).unwrap();
        let handle = handle_with(keys);
        unsafe {
            assert!(
                restore_and_hydrate(handle, &drafts_c),
                "one unreadable file must not fail the restore whole"
            );
            let row = roster(handle);
            assert_eq!(row.as_array().unwrap().len(), 1);
            assert_eq!(row[0]["path"], serde_json::json!(dirty.to_string_lossy()));
            assert_eq!(row[0]["conflict"], serde_json::json!("missing"));
            assert_eq!(row[0]["isDirty"], serde_json::json!(true));

            let posted = notices(handle);
            assert_eq!(posted.as_array().unwrap().len(), 1);
            assert_eq!(posted[0]["name"], serde_json::json!("clean.txt"));
            assert_eq!(
                posted[0]["path"],
                serde_json::json!(clean.to_string_lossy())
            );
            assert_eq!(posted[0]["reason"], serde_json::json!("missing"));
            // Reading drains: the notice is not posted twice.
            assert_eq!(notices(handle), serde_json::json!([]));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_clean_file_this_build_will_not_open_is_dropped_and_named() {
        let (keys, dir, clean, _dirty, drafts_c) = staged("unreadable");
        std::fs::write(&clean, [0x66, 0x6f, 0xFF, 0xFE]).unwrap();
        let handle = handle_with(keys);
        unsafe {
            assert!(restore_and_hydrate(handle, &drafts_c));
            assert_eq!(roster(handle).as_array().unwrap().len(), 1);
            let posted = notices(handle);
            assert_eq!(posted[0]["name"], serde_json::json!("clean.txt"));
            assert_eq!(posted[0]["reason"], serde_json::json!("unreadable"));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_restore_reads_no_file_and_leaves_every_row_pending() {
        let (keys, dir, clean, dirty, drafts_c) = staged("pending");
        // Both files are gone. A restore that read them would drop the
        // clean one and post a notice; this one must do neither.
        std::fs::remove_file(&clean).unwrap();
        std::fs::remove_file(&dirty).unwrap();
        let handle = handle_with(keys);
        unsafe {
            assert!(companion_drafts_restore(handle, drafts_c.as_ptr()));
            let row = roster(handle);
            assert_eq!(row.as_array().unwrap().len(), 2);
            assert_eq!(row[0]["pendingHydration"], serde_json::json!(true));
            assert_eq!(row[1]["pendingHydration"], serde_json::json!(true));
            assert_eq!(row[0]["path"], serde_json::json!(clean.to_string_lossy()));
            assert_eq!(notices(handle), serde_json::json!([]));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_pending_file_refuses_a_save_and_an_edit_until_it_is_hydrated() {
        let (keys, dir, clean, dirty, drafts_c) = staged("pending-refuses");
        let elsewhere = dir.join("elsewhere.txt");
        let handle = handle_with(keys);
        unsafe {
            assert!(companion_drafts_restore(handle, drafts_c.as_ptr()));
            let row = roster(handle);
            let clean_id = row[0]["id"].as_u64().unwrap();
            let dirty_id = row[1]["id"].as_u64().unwrap();
            let ops = cstring(r#"[{"ins":{"at":0,"text":"x"}}]"#);
            let target = cstring(&elsewhere.to_string_lossy());
            for id in [clean_id, dirty_id] {
                assert!(!companion_file_save(handle, id, ptr::null()));
                assert_eq!(
                    save_error(handle),
                    Some(serde_json::json!({ "error": "pendingHydration" }))
                );
                assert!(!companion_file_save_as(
                    handle,
                    id,
                    target.as_ptr(),
                    ptr::null()
                ));
                assert_eq!(
                    save_error(handle),
                    Some(serde_json::json!({ "error": "pendingHydration" }))
                );
                assert!(!companion_file_apply_ops(handle, id, ops.as_ptr()));
                assert!(!companion_file_reload(handle, id));
                assert!(!companion_file_resolve_take_theirs(handle, id));
                assert!(!companion_file_resolve_keep_mine(handle, id));
            }
            // The clean record's buffer is empty until it is hydrated,
            // so a save that got through would have emptied the file.
            assert_eq!(std::fs::read(&clean).unwrap(), b"clean body\n");
            assert_eq!(std::fs::read(&dirty).unwrap(), b"dirty body\n");
            assert!(!elsewhere.exists());

            assert!(companion_file_hydrate(handle, dirty_id, ptr::null()));
            assert_eq!(
                roster(handle)[1]["pendingHydration"],
                serde_json::json!(false)
            );
            assert!(companion_file_save(handle, dirty_id, ptr::null()));
            assert_eq!(std::fs::read(&dirty).unwrap(), b"typed dirty body\n");
            // The file beside it is still waiting and still refused.
            assert_eq!(
                roster(handle)[0]["pendingHydration"],
                serde_json::json!(true)
            );
            assert!(!companion_file_save(handle, clean_id, ptr::null()));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_hydration_given_the_resolved_path_follows_a_file_that_moved() {
        let (keys, dir, clean, dirty, drafts_c) = staged("moved");
        let shelf = dir.join("shelf");
        std::fs::create_dir(&shelf).unwrap();
        let moved_clean = shelf.join("clean.txt");
        let moved_dirty = shelf.join("renamed.txt");
        std::fs::rename(&clean, &moved_clean).unwrap();
        std::fs::rename(&dirty, &moved_dirty).unwrap();
        let handle = handle_with(keys);
        unsafe {
            assert!(companion_drafts_restore(handle, drafts_c.as_ptr()));
            let row = roster(handle);
            let clean_id = row[0]["id"].as_u64().unwrap();
            let dirty_id = row[1]["id"].as_u64().unwrap();

            let to = cstring(&moved_clean.to_string_lossy());
            assert!(companion_file_hydrate(handle, clean_id, to.as_ptr()));
            let to = cstring(&moved_dirty.to_string_lossy());
            assert!(companion_file_hydrate(handle, dirty_id, to.as_ptr()));

            let row = roster(handle);
            assert_eq!(
                row[0]["path"],
                serde_json::json!(moved_clean.to_string_lossy())
            );
            assert_eq!(
                row[0]["externallyReloaded"],
                serde_json::json!(false),
                "a move on one volume is not a change to the file"
            );
            assert_eq!(
                take_json(companion_file_runs_json(handle, clean_id)),
                r#"[{"ink":"clean body\n"}]"#
            );
            assert_eq!(row[1]["name"], serde_json::json!("renamed.txt"));
            assert_eq!(row[1]["isDirty"], serde_json::json!(true));
            assert_eq!(row[1]["conflict"], serde_json::json!("none"));
            assert_eq!(notices(handle), serde_json::json!([]));

            // The save lands where the file is, not where it was.
            assert!(companion_file_save(handle, dirty_id, ptr::null()));
        }
        assert_eq!(std::fs::read(&moved_dirty).unwrap(), b"typed dirty body\n");
        assert!(!dirty.exists());
        cleanup(handle, &dir);
    }

    #[test]
    fn a_hydration_will_not_rebind_onto_a_path_another_open_file_holds() {
        let (keys, dir, clean, dirty, drafts_c) = staged("rebind-refused");
        let handle = handle_with(keys);
        unsafe {
            assert!(companion_drafts_restore(handle, drafts_c.as_ptr()));
            let row = roster(handle);
            let clean_id = row[0]["id"].as_u64().unwrap();
            let dirty_id = row[1]["id"].as_u64().unwrap();
            let taken = cstring(&clean.to_string_lossy());

            // While the holder is still pending its claim on the path
            // is unchecked, so the question waits: true, and the row
            // still pending, with nothing read and nothing moved.
            assert!(companion_file_hydrate(handle, dirty_id, taken.as_ptr()));
            let row = roster(handle);
            assert_eq!(row[1]["pendingHydration"], serde_json::json!(true));
            assert_eq!(row[1]["path"], serde_json::json!(dirty.to_string_lossy()));
            assert_eq!(row[0]["pendingHydration"], serde_json::json!(true));
            assert!(!companion_file_save(handle, dirty_id, ptr::null()));

            // A resolved path that was given and is not a path is
            // refused, and the file is still waiting afterwards.
            let empty = cstring("");
            assert!(!companion_file_hydrate(handle, clean_id, empty.as_ptr()));
            assert_eq!(
                roster(handle)[0]["pendingHydration"],
                serde_json::json!(true)
            );

            // Once the holder has settled where its record said, the
            // same question is refused for good.
            assert!(companion_file_hydrate(handle, clean_id, ptr::null()));
            assert!(companion_file_hydrate(handle, dirty_id, taken.as_ptr()));
            let row = roster(handle);
            assert_eq!(row[1]["pendingHydration"], serde_json::json!(false));
            assert_eq!(
                row[1]["path"],
                serde_json::json!(dirty.to_string_lossy()),
                "the recorded path stands, which is how the shell can tell"
            );
            assert_eq!(row[0]["path"], serde_json::json!(clean.to_string_lossy()));
            assert_eq!(
                take_json(companion_file_runs_json(handle, dirty_id)),
                r#"[{"ink":"typed dirty body\n"}]"#
            );
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn one_file_that_will_not_hydrate_costs_no_other_file_anything() {
        let (keys, dir, clean, dirty, drafts_c) = staged("one-fails");
        std::fs::remove_file(&clean).unwrap();
        let handle = handle_with(keys);
        unsafe {
            assert!(companion_drafts_restore(handle, drafts_c.as_ptr()));
            let row = roster(handle);
            let clean_id = row[0]["id"].as_u64().unwrap();
            let dirty_id = row[1]["id"].as_u64().unwrap();

            assert!(
                !companion_file_hydrate(handle, clean_id, ptr::null()),
                "a dropped file answers false"
            );
            let row = roster(handle);
            assert_eq!(row.as_array().unwrap().len(), 1);
            assert_eq!(row[0]["id"], serde_json::json!(dirty_id));
            assert_eq!(row[0]["pendingHydration"], serde_json::json!(true));

            assert!(companion_file_hydrate(handle, dirty_id, ptr::null()));
            let row = roster(handle);
            assert_eq!(row[0]["path"], serde_json::json!(dirty.to_string_lossy()));
            assert_eq!(row[0]["isDirty"], serde_json::json!(true));
            assert_eq!(row[0]["conflict"], serde_json::json!("none"));
            // Asking again is harmless and changes nothing.
            assert!(companion_file_hydrate(handle, dirty_id, ptr::null()));
            assert!(!companion_file_hydrate(handle, clean_id, ptr::null()));

            let posted = notices(handle);
            assert_eq!(posted.as_array().unwrap().len(), 1);
            assert_eq!(posted[0]["name"], serde_json::json!("clean.txt"));
            assert_eq!(posted[0]["reason"], serde_json::json!("missing"));
        }
        cleanup(handle, &dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_read_the_platform_refuses_holds_a_clean_file_and_keeps_a_draft() {
        // The nearest an unsandboxed test can come to a file the
        // process holds no grant on: the stat answers and the read is
        // refused. A clean record is held in the roster, marked access
        // refused and unfilled, and a dirty one keeps its draft and stands in a
        // conflict. Nothing is dropped, so nothing is named.
        use std::os::unix::fs::PermissionsExt as _;

        let (keys, dir, clean, dirty, drafts_c) = staged("denied");
        let locked = std::fs::Permissions::from_mode(0o000);
        std::fs::set_permissions(&clean, locked.clone()).unwrap();
        std::fs::set_permissions(&dirty, locked).unwrap();
        if std::fs::read(&clean).is_ok() {
            // Root reads through any mode, so there is no refusal here
            // to test against.
            let _ = std::fs::remove_dir_all(&dir);
            return;
        }
        let handle = handle_with(keys);
        unsafe {
            assert!(restore_and_hydrate(handle, &drafts_c));
            let row = roster(handle);
            assert_eq!(row.as_array().unwrap().len(), 2);
            assert_eq!(notices(handle), serde_json::json!([]));

            assert_eq!(row[0]["path"], serde_json::json!(clean.to_string_lossy()));
            assert_eq!(row[0]["pendingHydration"], serde_json::json!(true));
            assert_eq!(row[0]["accessRefused"], serde_json::json!(true));
            assert_eq!(row[0]["isDirty"], serde_json::json!(false));
            let held = row[0]["id"].as_u64().unwrap();
            assert_eq!(take_json(companion_file_runs_json(handle, held)), "[]");
            let ops = cstring(r#"[{"ins":{"at":0,"text":"x"}}]"#);
            assert!(!companion_file_apply_ops(handle, held, ops.as_ptr()));
            assert!(!companion_file_save(handle, held, ptr::null()));
            // An open of the same path must not hand the held row back.
            assert_eq!(open(handle, &clean), 0);

            assert_eq!(row[1]["path"], serde_json::json!(dirty.to_string_lossy()));
            assert_eq!(row[1]["pendingHydration"], serde_json::json!(false));
            assert_eq!(row[1]["accessRefused"], serde_json::json!(true));
            assert_eq!(row[1]["isDirty"], serde_json::json!(true));
            assert_eq!(row[1]["conflict"], serde_json::json!("changed"));
            let id = row[1]["id"].as_u64().unwrap();
            assert_eq!(
                take_json(companion_file_runs_json(handle, id)),
                r#"[{"ink":"typed dirty body\n"}]"#
            );
            assert!(!companion_file_save(handle, id, ptr::null()));
            assert!(!companion_file_resolve_take_theirs(handle, id));

            // The check the first activation makes finds a stat that
            // matches the record and a read that is still refused. The
            // conflict the hydration set stands, and so does the
            // refusal to save over a copy nothing here has read.
            let check: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_check(handle, id))).unwrap();
            assert_eq!(check["state"], serde_json::json!("unchanged"));
            let row = roster(handle);
            assert_eq!(row[1]["conflict"], serde_json::json!("changed"));
            assert_eq!(row[1]["accessRefused"], serde_json::json!(true));
            assert!(!companion_file_save(handle, id, ptr::null()));

            // The read comes back. The held file settles on the same
            // call that held it, and the check clears the mark on the
            // file that was already settled.
            let readable = std::fs::Permissions::from_mode(0o644);
            std::fs::set_permissions(&clean, readable.clone()).unwrap();
            std::fs::set_permissions(&dirty, readable).unwrap();
            assert!(companion_file_hydrate(handle, held, ptr::null()));
            let _ = take_json(companion_file_check(handle, id));
            let row = roster(handle);
            assert_eq!(row[0]["pendingHydration"], serde_json::json!(false));
            assert_eq!(row[0]["accessRefused"], serde_json::json!(false));
            assert_eq!(
                take_json(companion_file_runs_json(handle, held)),
                r#"[{"ink":"clean body\n"}]"#
            );
            assert_eq!(row[1]["accessRefused"], serde_json::json!(false));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_relocation_follows_a_file_the_person_points_at() {
        // A dirty file and a clean one, both moved while the app was
        // away, with no bookmark handed to the hydration. The clean one
        // is dropped as missing, which is today's rule, and the dirty
        // one stands in a missing conflict until it is relocated.
        let (keys, dir, _clean, dirty, drafts_c) = staged("relocate");
        let moved = dir.join("moved.txt");
        std::fs::rename(&dirty, &moved).unwrap();
        let handle = handle_with(keys);
        unsafe {
            assert!(restore_and_hydrate(handle, &drafts_c));
            let row = roster(handle);
            let id = row[1]["id"].as_u64().unwrap();
            assert_eq!(row[1]["conflict"], serde_json::json!("missing"));

            let moved_c = cstring(&moved.to_string_lossy());
            assert!(companion_file_relocate(handle, id, moved_c.as_ptr()));
            assert!(companion_file_open_error_json(handle).is_null());
            let row = roster(handle);
            assert_eq!(row[1]["path"], serde_json::json!(moved.to_string_lossy()));
            assert_eq!(row[1]["name"], serde_json::json!("moved.txt"));
            assert_eq!(row[1]["conflict"], serde_json::json!("none"));
            assert_eq!(row[1]["isDirty"], serde_json::json!(true));
            assert_eq!(
                take_json(companion_file_runs_json(handle, id)),
                r#"[{"ink":"typed dirty body\n"}]"#
            );
            assert!(companion_file_save(handle, id, ptr::null()));
            assert_eq!(std::fs::read(&moved).unwrap(), b"typed dirty body\n");
            assert!(!dirty.exists(), "nothing was recreated at the old path");
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_relocation_onto_a_different_text_is_a_conflict_that_can_be_taken() {
        let (handle, dir) = scratch("relocate-changed");
        let file = dir.join("a.txt");
        let other = dir.join("b.txt");
        std::fs::write(&file, b"one\n").unwrap();
        std::fs::write(&other, b"two\n").unwrap();
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":0,"text":"typed "}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            let other_c = cstring(&other.to_string_lossy());
            assert!(companion_file_relocate(handle, id, other_c.as_ptr()));
            let row = roster(handle);
            assert_eq!(row[0]["path"], serde_json::json!(other.to_string_lossy()));
            assert_eq!(row[0]["conflict"], serde_json::json!("changed"));
            assert!(!companion_file_save(handle, id, ptr::null()));
            assert!(companion_file_resolve_take_theirs(handle, id));
            assert_eq!(
                take_json(companion_file_runs_json(handle, id)),
                r#"[{"ink":"two\n"}]"#
            );
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_refused_relocation_leaves_the_file_as_it_was_and_says_why() {
        let (handle, dir) = scratch("relocate-refused");
        let file = dir.join("a.txt");
        let held = dir.join("held.txt");
        let binary = dir.join("b.bin");
        std::fs::write(&file, b"one\n").unwrap();
        std::fs::write(&held, b"held\n").unwrap();
        std::fs::write(&binary, [0x66, 0x6f, 0xFF, 0xFE]).unwrap();
        std::fs::write(dir.join("huge.txt"), vec![b'a'; LIMIT + 1]).unwrap();
        unsafe {
            let id = open(handle, &file);
            let _other = open(handle, &held);
            let as_it_was = roster(handle);

            // A path another open file holds: refused, and the open
            // error has nothing to add.
            let held_c = cstring(&held.to_string_lossy());
            assert!(!companion_file_relocate(handle, id, held_c.as_ptr()));
            assert!(companion_file_open_error_json(handle).is_null());

            // A file that will not open: refused in an open's own words.
            let binary_c = cstring(&binary.to_string_lossy());
            assert!(!companion_file_relocate(handle, id, binary_c.as_ptr()));
            assert_eq!(
                take_json(companion_file_open_error_json(handle)),
                r#"{"error":"notUtf8"}"#
            );
            let huge_c = cstring(&dir.join("huge.txt").to_string_lossy());
            assert!(!companion_file_relocate(handle, id, huge_c.as_ptr()));
            let why: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_open_error_json(handle))).unwrap();
            assert_eq!(why["error"], serde_json::json!("tooLarge"));
            assert_eq!(why["limit"], serde_json::json!(LIMIT as u64));

            let empty = cstring("");
            assert!(!companion_file_relocate(handle, id, empty.as_ptr()));
            assert!(!companion_file_relocate(handle, id, ptr::null()));
            assert!(!companion_file_relocate(
                ptr::null_mut(),
                id,
                held_c.as_ptr()
            ));

            assert_eq!(roster(handle), as_it_was);
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn the_can_undo_pair_answers_for_a_file_and_refuses_a_page() {
        let (handle, dir) = scratch("canundo");
        let file = dir.join("u.txt");
        std::fs::write(&file, b"hello").unwrap();
        unsafe {
            let id = open(handle, &file);
            assert!(!companion_file_can_undo(handle, id));
            assert!(!companion_file_can_redo(handle, id));

            let ops = cstring(r#"[{"ins":{"at":5,"text":" there"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            assert!(companion_file_can_undo(handle, id));
            assert!(!companion_file_can_redo(handle, id));

            let undo: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_undo(handle, id))).unwrap();
            assert_eq!(undo["applied"], serde_json::json!(true));
            assert!(
                !companion_file_can_undo(handle, id),
                "that was the only step"
            );
            assert!(companion_file_can_redo(handle, id));

            // A live page's id, untagged, is refused here the way a
            // file id is refused by the page pair.
            let tab = crate::companion_tab_new(handle);
            assert_ne!(tab, 0);
            let page = tabs(handle)[0]["page_id"].as_u64().unwrap();
            assert!(!companion_file_can_undo(handle, page));
            assert!(!companion_file_can_redo(handle, page));

            // And the file still answers, so no refusal touched it.
            assert!(companion_file_can_redo(handle, id));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_fifo_is_refused_rather_than_blocked_on() {
        // A bare `std::fs::read` of a pipe with no writer parks in
        // `open(2)` forever with the handle mutex held, which stops the
        // whole app answering. The open must come back instead.
        //
        // The work runs on a second thread and the assertion waits on a
        // channel, so a regression is a test that fails on a timeout
        // rather than a suite that hangs.
        let (handle, dir) = scratch("fifo");
        let fifo = dir.join("pipe");
        // Planted through the command rather than `libc::mkfifo`, the
        // same way persist.rs plants its FIFO: this crate takes `libc`
        // on macOS only, and the Linux CI host compiles these tests.
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&fifo)
                .status()
                .unwrap()
                .success(),
            "the test could not plant a FIFO to check against"
        );

        let (tx, rx) = std::sync::mpsc::channel();
        let carried = handle as usize;
        let worker = std::thread::spawn(move || {
            let handle = carried as *mut CompanionHandle;
            let path = cstring(&fifo.to_string_lossy());
            let id = unsafe { companion_file_open(handle, path.as_ptr()) };
            let error = unsafe { companion_file_open_error_json(handle) };
            let error = if error.is_null() {
                String::new()
            } else {
                unsafe { take_json(error) }
            };
            let _ = tx.send((id, error));
        });
        let (id, error) = rx
            .recv_timeout(std::time::Duration::from_secs(10))
            .expect("opening a pipe must return rather than park forever");
        worker.join().unwrap();
        assert_eq!(id, 0, "a pipe is not a file this build opens");
        let error: serde_json::Value = serde_json::from_str(&error).unwrap();
        assert_eq!(error["error"], serde_json::json!("io"));

        // The handle still answers, which is the property that matters:
        // nothing walked off holding the lock.
        unsafe {
            assert_eq!(roster(handle), serde_json::json!([]));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_directory_at_the_path_is_refused() {
        let (handle, dir) = scratch("dir");
        let inner = dir.join("folder");
        std::fs::create_dir(&inner).unwrap();
        unsafe {
            assert_eq!(open(handle, &inner), 0);
            let error: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_open_error_json(handle))).unwrap();
            assert_eq!(error["error"], serde_json::json!("io"));
        }
        cleanup(handle, &dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_is_followed_at_open_and_the_save_lands_on_the_real_file() {
        let (handle, dir) = scratch("symlink");
        let real = dir.join("real.txt");
        let link = dir.join("link.txt");
        std::fs::write(&real, b"body").unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        unsafe {
            let id = open(handle, &link);
            assert_ne!(id, 0);
            let ops = cstring(r#"[{"ins":{"at":4,"text":"!"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            assert!(companion_file_save(handle, id, ptr::null()));

            // Opening the real path is the same file, not a second one.
            assert_eq!(open(handle, &real), id);
            assert_eq!(roster(handle).as_array().unwrap().len(), 1);
        }
        assert_eq!(std::fs::read(&real).unwrap(), b"body!");
        assert!(
            std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink(),
            "the link is still a link"
        );
        assert_eq!(std::fs::read(&link).unwrap(), b"body!");
        cleanup(handle, &dir);
    }

    #[test]
    fn keep_mine_then_save_writes_through_the_documented_flow() {
        // Check on activate, choose keep mine, check again before the
        // save because the header says to, then save. Every step over
        // the seam, because the bug this pins was invisible under it.
        let (handle, dir) = scratch("keepmine");
        let file = dir.join("k.txt");
        std::fs::write(&file, b"one").unwrap();
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":3,"text":" mine"}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            std::fs::write(&file, b"theirs").unwrap();

            let check: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_check(handle, id))).unwrap();
            assert_eq!(check["state"], serde_json::json!("changed"));
            assert!(companion_file_resolve_keep_mine(handle, id));

            let again: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_check(handle, id))).unwrap();
            assert_eq!(again["state"], serde_json::json!("unchanged"));
            assert_eq!(roster(handle)[0]["conflict"], serde_json::json!("none"));
            assert!(companion_file_save(handle, id, ptr::null()));
        }
        assert_eq!(std::fs::read(&file).unwrap(), b"one mine");
        cleanup(handle, &dir);
    }

    #[test]
    fn save_as_onto_another_open_file_is_refused() {
        let (handle, dir) = scratch("inuse");
        let one = dir.join("one.txt");
        let two = dir.join("two.txt");
        std::fs::write(&one, b"first").unwrap();
        std::fs::write(&two, b"second").unwrap();
        unsafe {
            let first = open(handle, &one);
            open(handle, &two);
            let target = cstring(&two.to_string_lossy());
            assert!(!companion_file_save_as(
                handle,
                first,
                target.as_ptr(),
                ptr::null()
            ));
            assert_eq!(
                save_error(handle),
                Some(serde_json::json!({ "error": "pathInUse" }))
            );
            let row = roster(handle);
            assert_eq!(row.as_array().unwrap().len(), 2);
            assert_eq!(row[0]["path"], serde_json::json!(one.to_string_lossy()));
        }
        assert_eq!(std::fs::read(&two).unwrap(), b"second");
        cleanup(handle, &dir);
    }

    #[test]
    fn dropping_the_content_file_keeps_an_open_file_s_draft() {
        // The last page tab going away is a page lifecycle event. A
        // person holding a dirty file tab at that moment did not ask
        // for their unsaved typing to go anywhere.
        let keys = credentials();
        let handle = handle_with(keys.clone());
        let dir = scratch_dir("erase-keeps");
        let state = dir.join("state.sealed");
        let drafts = dir.join(DRAFTS_FILE_NAME);
        let file = dir.join("live.txt");
        std::fs::write(&file, b"one").unwrap();
        let state_c = cstring(&state.to_string_lossy());
        let drafts_c = cstring(&drafts.to_string_lossy());
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":0,"text":"typed "}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            assert!(crate::companion_persist_save(handle, state_c.as_ptr()));
            assert!(companion_drafts_save(handle, drafts_c.as_ptr()));

            // The last page tab goes: the shell drops the content file.
            assert!(crate::companion_persist_erase(handle, state_c.as_ptr()));
            crate::companion_free(handle);
        }
        assert!(!state.exists(), "the content file went");
        assert!(drafts.exists(), "the draft did not");

        // And it opens under the halves the drop minted.
        let relaunch = handle_with(keys);
        unsafe {
            assert!(restore_and_hydrate(relaunch, &drafts_c));
            let row = roster(relaunch);
            assert_eq!(row.as_array().unwrap().len(), 1);
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
    fn dropping_the_content_file_with_no_file_open_takes_the_drafts() {
        let (handle, dir) = scratch("erase-empty");
        let state = dir.join("state.sealed");
        let drafts = dir.join(DRAFTS_FILE_NAME);
        let file = dir.join("gone.txt");
        std::fs::write(&file, b"one").unwrap();
        let state_c = cstring(&state.to_string_lossy());
        let drafts_c = cstring(&drafts.to_string_lossy());
        unsafe {
            let id = open(handle, &file);
            assert!(crate::companion_persist_save(handle, state_c.as_ptr()));
            assert!(companion_drafts_save(handle, drafts_c.as_ptr()));
            // The tab is closed, so nothing is staged any more.
            assert!(companion_file_close(handle, id));
            assert!(crate::companion_persist_erase(handle, state_c.as_ptr()));
        }
        assert!(!state.exists());
        assert!(!drafts.exists(), "an empty roster lets the file go");
        cleanup(handle, &dir);
    }

    #[test]
    fn the_draft_size_bound_is_four_times_the_file_size_limit() {
        assert_eq!(companion_core::DRAFT_SNAPSHOT_LIMIT, 4 * LIMIT);
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
                restore_and_hydrate(relaunch, &drafts_c),
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
    fn the_explicit_discard_always_takes_the_drafts() {
        // `companion_drafts_erase` is the door for a person who asked
        // to discard their unsaved file edits, and it takes them
        // whether or not the file is still open. That is what lets
        // `companion_persist_erase` be careful.
        let (handle, dir) = scratch("erase-pair");
        let drafts = dir.join(DRAFTS_FILE_NAME);
        let file = dir.join("x.txt");
        std::fs::write(&file, b"one").unwrap();
        let drafts_c = cstring(&drafts.to_string_lossy());
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":0,"text":"typed "}}]"#);
            assert!(companion_file_apply_ops(handle, id, ops.as_ptr()));
            assert!(companion_drafts_save(handle, drafts_c.as_ptr()));
            assert!(drafts.exists());
            assert!(companion_drafts_erase(handle, drafts_c.as_ptr()));
        }
        assert!(!drafts.exists(), "an explicit discard is not conditional");
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
            assert!(!companion_file_apply_ops_with_intent(
                handle,
                page,
                ops.as_ptr(),
                0,
                u32::MAX,
                u32::MAX,
                u32::MAX,
                u32::MAX
            ));
            assert!(!companion_file_finish_editing_group(
                handle,
                page,
                u32::MAX,
                u32::MAX
            ));
            assert!(companion_file_undo_action_name(handle, page).is_null());
            assert!(companion_file_redo_action_name(handle, page).is_null());
            assert!(companion_file_undo(handle, page).is_null());
            assert!(companion_file_redo(handle, page).is_null());
            assert!(!companion_file_save(handle, page, ptr::null()));
            let target = cstring(&dir.join("nope.txt").to_string_lossy());
            assert!(!companion_file_save_as(
                handle,
                page,
                target.as_ptr(),
                ptr::null()
            ));
            assert!(!companion_file_hydrate(handle, page, ptr::null()));
            assert!(!companion_file_relocate(handle, page, target.as_ptr()));
            assert!(companion_file_check(handle, page).is_null());
            assert!(!companion_file_reload(handle, page));
            assert!(!companion_file_resolve_take_theirs(handle, page));
            assert!(!companion_file_resolve_keep_mine(handle, page));
            let mark = cstring("");
            assert!(!companion_file_set_bookmark(handle, page, mark.as_ptr()));
            assert!(companion_file_bookmark_b64(handle, page).is_null());
            assert!(!companion_file_clear_reload_notice(handle, page));

            assert!(!dir.join("nope.txt").exists());
            // The page and the file both stood through all of it.
            assert_eq!(tabs(handle)[0]["page_id"].as_u64(), Some(page));
            assert_eq!(roster(handle).as_array().unwrap().len(), 1);
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn file_action_names_cross_the_seam() {
        let (handle, dir) = scratch("action-name");
        let file = dir.join("f.txt");
        std::fs::write(&file, b"").unwrap();
        unsafe {
            let id = open(handle, &file);
            let ops = cstring(r#"[{"ins":{"at":0,"text":"pasted"}}]"#);
            assert!(companion_file_apply_ops_with_intent(
                handle,
                id,
                ops.as_ptr(),
                EditIntent::Paste as u32,
                u32::MAX,
                u32::MAX,
                u32::MAX,
                u32::MAX
            ));
            assert_eq!(
                take_json(companion_file_undo_action_name(handle, id)),
                "Paste"
            );
            assert!(!companion_file_can_redo(handle, id));

            assert!(take_json(companion_file_undo(handle, id)).contains(r#""applied":true"#));
            assert_eq!(
                take_json(companion_file_redo_action_name(handle, id)),
                "Paste"
            );
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
            assert!(!companion_file_can_undo(null, 1));
            assert!(!companion_file_can_redo(null, 1));
            assert!(companion_file_undo_action_name(null, 1).is_null());
            assert!(companion_file_redo_action_name(null, 1).is_null());
            assert!(companion_file_undo(null, 1).is_null());
            assert!(companion_file_redo(null, 1).is_null());
            assert!(!companion_file_save(null, 1, ptr::null()));
            assert!(!companion_file_save_as(null, 1, ptr::null(), ptr::null()));
            assert!(companion_file_save_error_json(null).is_null());
            assert!(!companion_file_hydrate(null, 1, ptr::null()));
            assert!(companion_file_check(null, 1).is_null());
            assert!(!companion_file_reload(null, 1));
            assert!(!companion_file_resolve_take_theirs(null, 1));
            assert!(!companion_file_resolve_keep_mine(null, 1));
            assert!(!companion_file_set_bookmark(null, 1, ptr::null()));
            assert!(companion_file_bookmark_b64(null, 1).is_null());
            assert!(companion_file_roster_json(null).is_null());
            assert!(!companion_file_clear_reload_notice(null, 1));
            assert!(!companion_drafts_save(null, ptr::null()));
            assert!(!companion_drafts_restore(null, ptr::null()));
            assert!(!companion_drafts_erase(null, ptr::null()));
            assert!(companion_drafts_notices_json(null).is_null());
        }
    }
}
