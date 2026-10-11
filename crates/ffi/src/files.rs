//! The C seam for open files: paths in, never bytes, on the conventions of
//! `lib.rs`. File ids carry `FILE_ID_TAG`, which every `companion_sheet_*`
//! entry point refuses. Drafts are sealed under the content key with their
//! own magic.

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

/// The drafts envelope magic, also its associated data.
const DRAFTS_MAGIC: &[u8; 8] = b"OTSDRFE1";

/// The drafts file's name beside the state file, for the rotation only; every
/// `companion_drafts_*` entry point takes its path from the shell.
pub(crate) const DRAFTS_FILE_NAME: &str = "drafts.sealed";

/// The drafts file that sits beside `state_path`.
pub(crate) fn drafts_path_beside(state_path: &Path) -> Option<PathBuf> {
    Some(persist::containing_dir(state_path)?.join(DRAFTS_FILE_NAME))
}

// ---------------------------------------------------------------------------
// The platform surface the core asked for
// ---------------------------------------------------------------------------

/// The core's file IO. A write keeps the target's mode (0644 when new) and
/// stages its temp file in `staging_dir`, or beside the target when `None`,
/// since a sandboxed shell cannot create beside a granted document.
pub(crate) struct RealFileIo<'a> {
    staging_dir: Option<&'a Path>,
}

impl RealFileIo<'static> {
    /// Writes stage beside their target.
    pub(crate) const fn new() -> Self {
        Self { staging_dir: None }
    }
}

impl<'a> RealFileIo<'a> {
    /// Writes stage in `staging_dir`, or beside their target when `None`.
    pub(crate) const fn staging_in(staging_dir: Option<&'a Path>) -> Self {
        Self { staging_dir }
    }
}

impl FileIo for RealFileIo<'_> {
    fn probe_readable(&self, path: &Path) -> io::Result<()> {
        use std::io::Read as _;
        let mut file = open_regular_file(path)?;
        let mut byte = Zeroizing::new([0u8; 1]);
        for _ in 0..3 {
            match file.read(&mut byte[..]) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                result => return result.map(|_| ()),
            }
        }
        Err(io::Error::from(io::ErrorKind::Interrupted))
    }

    fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
        // One byte past the limit, so the core's length check sees an oversize file.
        read_regular(path, companion_core::FILE_SIZE_LIMIT as u64 + 1)
    }

    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<FileWitness> {
        write_atomic_preserving_mode(path, bytes, self.staging_dir)
    }

    fn stat(&self, path: &Path) -> io::Result<FileWitness> {
        let metadata = std::fs::metadata(path)?;
        if !metadata.file_type().is_file() {
            // Not a text file; the core turns this into an `io` refusal.
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
        witness_of(&metadata)
    }

    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        std::fs::canonicalize(path)
    }
}

/// Read a whole regular file, following symlinks. Stats first and opens
/// `O_NONBLOCK`, so a FIFO never parks a caller holding the handle mutex.
pub(crate) fn read_regular_file(path: &Path) -> io::Result<Vec<u8>> {
    read_regular(path, u64::MAX)
}

/// The defended read, taking at most `limit` bytes.
fn read_regular(path: &Path, limit: u64) -> io::Result<Vec<u8>> {
    use std::io::Read as _;

    let file = open_regular_file(path)?;
    // Presized as a hint only; a failed stat or allocation just grows.
    let len = file
        .metadata()
        .ok()
        .and_then(|metadata| usize::try_from(metadata.len().min(limit)).ok())
        .unwrap_or(0);
    let mut bytes = Vec::new();
    let _ = bytes.try_reserve_exact(len);
    file.take(limit).read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// Shared checked, nonblocking open for full reads and bounded probes.
fn open_regular_file(path: &Path) -> io::Result<std::fs::File> {
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
    let file = options.open(path)?;
    // Asked again through the descriptor, which the name cannot change.
    if !file.metadata()?.file_type().is_file() {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    }
    Ok(file)
}

#[cfg(unix)]
fn witness_of(metadata: &std::fs::Metadata) -> io::Result<FileWitness> {
    use std::os::unix::fs::MetadataExt as _;
    Ok(FileWitness {
        dev: metadata.dev(),
        ino: metadata.ino(),
        size: metadata.size(),
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

/// Create-new temp, write, fsync, rename, fsync the directory. The witness is
/// the temp file's, read before the rename. A staging directory that will not
/// serve fails the save; there is no fallback to a sibling.
fn write_atomic_preserving_mode(
    path: &Path,
    bytes: &[u8],
    staging_dir: Option<&Path>,
) -> io::Result<FileWitness> {
    use std::io::Write as _;

    let dir = persist::containing_dir(path)
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let tmp_dir = staging_dir.unwrap_or(dir);
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        // Rename cannot cross filesystems; never turn this into a copying save.
        if std::fs::metadata(tmp_dir)?.dev() != std::fs::metadata(dir)?.dev() {
            return Err(io::Error::from(io::ErrorKind::CrossesDevices));
        }
    }

    // The rename drops the old file's mode and group unless they are carried.
    let existing = std::fs::metadata(path).ok();

    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
        let mode = existing.as_ref().map_or(0o644, |meta| meta.mode() & 0o777);
        options.mode(mode);
    }

    // The `persist::write_private` temp shape, so a stranded one is swept at launch.
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
            .and_then(|()| file.sync_all())
            .and_then(|()| file.metadata())
            .and_then(|metadata| witness_of(&metadata));
        drop(file);
        let witness = match landed {
            Ok(witness) => witness,
            Err(error) => {
                let _ = std::fs::remove_file(&tmp);
                return Err(error);
            }
        };
        // A failed rename takes the temp file back.
        if let Err(error) = std::fs::rename(&tmp, path) {
            let _ = std::fs::remove_file(&tmp);
            return Err(error);
        }
        // Best effort, as in `persist::write_private`.
        if let Ok(handle) = std::fs::File::open(dir) {
            let _ = handle.sync_all();
        }
        return Ok(witness);
    }
    Err(last)
}

/// Give the temp file the target's mode (set past the umask; a failure fails
/// the save) and, best effort, its group; a new file takes the group its
/// target directory would give. Write access was already checked at open.
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

/// The group a new file in `dir` takes: the directory's on macOS, and on
/// Linux only with the set group id bit.
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

/// Open `path` and return its tagged id, or 0 on refusal
/// ([`companion_file_open_error_json`] says why). An open path returns its
/// existing id unless it is still `pendingHydration`.
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
        // A fixed standard library label, carrying no part of the path.
        OpenRefusal::Io(kind) => {
            serde_json::json!({ "error": "io", "detail": format!("{kind}") })
        }
    };
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// Close the file and drop its buffer and its draft.
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

/// The file's body as document runs (one ink run, or none). Null for an
/// unknown file. Free with `companion_string_free`.
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
    // A missing clock stamps 0 rather than refuse a keystroke.
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

/// Whether the file has an undo step; false for an unknown file. The page
/// route refuses file ids, hence this pair.
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

/// Save the buffer to the file's path. False on refusal, including nothing at
/// the path unless keep mine licensed recreating it;
/// [`companion_file_save_error_json`] says which. `staging_dir` is null for
/// beside the target, else a writable directory on the target's volume.
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
    // Cleared first, so an unreadable argument never reports an older reason.
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

/// Why the last save refused, as JSON; null after a write, before any save,
/// or after an unreadable argument. Free with `companion_string_free`.
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
        // A fixed standard library label, carrying no part of the path.
        SaveError::Io(kind) => {
            serde_json::json!({ "error": "write", "detail": format!("{kind}") })
        }
    };
    match serde_json::to_string(&value) {
        Ok(json) => into_c_string(json),
        Err(_) => ptr::null_mut(),
    }
}

/// `Ok(None)` for null; `Err` for a pointer that is not a non-empty UTF-8
/// path, which the caller refuses rather than read as none.
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

/// Log a save refusal, so reports of one can be told from another.
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

/// Stat the file and report its conflict state as `{state, path}` JSON; this
/// is the call that moves a dirty file into a conflict. Null for an unknown
/// file. Free with `companion_string_free`.
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

/// Re-read from disk, discarding the buffer and its undo history.
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

/// Take theirs: adopt the disk copy as one undoable change.
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

/// Keep mine: clear the conflict and license the next save to overwrite. The
/// consent lapses when the path changes state or the buffer settles clean
/// (`companion_ffi.h`).
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

/// Rebind the file to `path` and settle it against the disk copy there, as
/// [`companion_file_hydrate`] does. False leaves the file unchanged; an open
/// refusal is explained by [`companion_file_open_error_json`].
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

/// Acknowledge the reload notice; reading the roster clears nothing.
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

/// Seal the roster and the dirty drafts to `path`. An oversized draft is left
/// out and noted in [`companion_drafts_notices_json`]; the save still succeeds.
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

/// Seal and write the roster, minting key halves if needed. `None` when the
/// write did not land, else the oversized drafts. The caller holds the lock.
pub(crate) fn seal_drafts_to(
    state: &Companion,
    path: &Path,
) -> Option<Vec<companion_core::FileNotice>> {
    let wall_ms = wall_now_ms()?;
    let key = persist::ensure_state_key(state.credentials.as_ref(), path)?;
    let emitted = file_persist::emit(&state.files, wall_ms);
    // Zeroizing from the core, so wiped whatever happens to the write.
    let plaintext = emitted.bytes;
    let sealed = persist::seal_body(&key, DRAFTS_MAGIC, &plaintext)?;
    let mut file = Vec::with_capacity(DRAFTS_MAGIC.len() + sealed.len());
    file.extend_from_slice(DRAFTS_MAGIC);
    file.extend_from_slice(&sealed);
    persist::write_private(path, &file).then_some(emitted.oversized)
}

/// Restore the roster and drafts without reading any of the person's files:
/// every row comes back `pendingHydration` and needs [`companion_file_hydrate`].
/// False when the drafts file did not open.
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
    // The defended read: a planted FIFO fails rather than blocks.
    let Ok(file) = read_regular_file(path) else {
        return false;
    };
    if !file.starts_with(DRAFTS_MAGIC) {
        diag_fault!(
            "companion-ffi: the drafts file does not carry this build's envelope header; \
             refusing it and leaving it where it is."
        );
        return false;
    }
    // The magic is checked before the key, so a foreign file costs no prompt.
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

/// Settle one restored file against the disk at `resolved_path` (the
/// bookmark's answer) or, when null, its recorded path. True when the file
/// still stands in the roster, including a wait or a hold that leaves it
/// `pendingHydration`. Touches no other file. Full contract in
/// `companion_ffi.h`.
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

/// The drafts notices as `[{name, path, reason}]` JSON, `reason` one of
/// `missing`, `unreadable` or `draftTooLarge`. Reading drains the list. Null
/// when the answer cannot be had. Free with `companion_string_free`.
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

/// Drop the drafts file; true when the path is confirmed empty. Never
/// rotates: the content key also keys every staged page.
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

/// Reseal the drafts beside `state_path` under the new key, before the state
/// file, so a crash mid-rotation costs the strip rather than unsaved typing.
/// Writes nothing when there is no drafts file and no open file.
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

/// Erase the drafts file beside `state_path`.
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

    #[test]
    fn readability_probe_accepts_empty_and_large_regular_files_and_refuses_directories() {
        let root = scratch_dir("readability-probe");
        let path = root.join("sparse.txt");
        let file = std::fs::File::create(&path).unwrap();
        let io = RealFileIo::new();
        io.probe_readable(&path).unwrap();
        file.set_len(64 * 1024 * 1024).unwrap();
        io.probe_readable(&path).unwrap();
        assert_eq!(
            io.probe_readable(&root).unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            io.probe_readable(&root.join("absent")).unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
        drop(file);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn readability_probe_refuses_a_fifo_without_blocking() {
        let root = scratch_dir("probe-fifo");
        let fifo = root.join("pipe");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&fifo)
                .status()
                .unwrap()
                .success()
        );
        let (tx, rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            tx.send(RealFileIo::new().probe_readable(&fifo).unwrap_err().kind())
                .unwrap();
        });
        assert_eq!(
            rx.recv_timeout(std::time::Duration::from_secs(5))
                .expect("probe must not block on FIFO"),
            io::ErrorKind::InvalidInput
        );
        worker.join().unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn cross_filesystem_staging_is_rejected_before_creating_a_temp_file() {
        use std::os::unix::fs::MetadataExt as _;
        let (root, docs, staging) = target_and_staging("cross-filesystem");
        let target = docs.join("note.txt");
        std::fs::write(&target, b"original").unwrap();
        // /dev is its own filesystem on macOS and Linux.
        let other = Path::new("/dev");
        if std::fs::metadata(other).unwrap().dev() == std::fs::metadata(&docs).unwrap().dev() {
            eprintln!("cross-filesystem test skipped: /dev shares the scratch filesystem");
            std::fs::remove_dir_all(root).unwrap();
            return;
        }
        let error = write_atomic_preserving_mode(&target, b"replacement", Some(other)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::CrossesDevices);
        assert_eq!(std::fs::read(&target).unwrap(), b"original");
        assert_eq!(std::fs::read_dir(&docs).unwrap().count(), 1);
        assert_eq!(std::fs::read_dir(&staging).unwrap().count(), 0);
        let absent = docs.join("new.txt");
        assert_eq!(
            write_atomic_preserving_mode(&absent, b"new", Some(other))
                .unwrap_err()
                .kind(),
            io::ErrorKind::CrossesDevices
        );
        assert!(!absent.exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    fn cstring(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    unsafe fn take_json(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null(), "the route answered null");
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
        unsafe { crate::companion_string_free(ptr) };
        text
    }

    #[test]
    fn a_file_read_takes_no_more_than_one_byte_past_the_limit() {
        let dir = scratch_dir("capped-read");
        let path = dir.join("big.txt");
        std::fs::write(&path, vec![b'a'; companion_core::FILE_SIZE_LIMIT + 4096]).unwrap();
        let bytes = RealFileIo::new().read(&path).unwrap();
        assert_eq!(bytes.len(), companion_core::FILE_SIZE_LIMIT + 1);
        let small = dir.join("small.txt");
        std::fs::write(&small, b"short").unwrap();
        assert_eq!(RealFileIo::new().read(&small).unwrap(), b"short");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A temp directory of this test's own.
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
        // Resolved: the store resolves paths, and macOS reaches temp via a symlink.
        std::fs::canonicalize(&dir).unwrap()
    }

    /// A handle on in-memory credentials; two handles on one store are a relaunch.
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

    /// A relaunch with no bookmarks: restore, then hydrate every row in place.
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
            assert!(row.get("unreadable").is_none());
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_save_never_recreates_a_file_that_is_gone_from_its_path() {
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

            let staging = dir.join("staging");
            std::fs::create_dir(&staging).unwrap();
            let staging_c = cstring(&staging.to_string_lossy());
            assert!(!companion_file_save(handle, clean_id, staging_c.as_ptr()));
            assert!(!clean.exists());
            assert_eq!(std::fs::read_dir(&staging).unwrap().count(), 0);

            assert!(companion_file_resolve_keep_mine(handle, dirty_id));
            assert!(companion_file_save(handle, dirty_id, ptr::null()));
            assert_eq!(std::fs::read(&dirty).unwrap(), b"one mine");

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

            // An unreadable argument clears the previous reason.
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

            assert!(companion_file_resolve_keep_mine(handle, dirty_id));
            assert!(!companion_file_save(handle, clean_id, ptr::null()));
            assert!(companion_file_save(handle, dirty_id, ptr::null()));
            assert_eq!(save_error(handle), None);
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_write_the_platform_refuses_is_not_reported_as_a_file_not_found() {
        // Not found, licensed by keep mine, then the write itself fails.
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

    /// Target and staging directories on one volume.
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
        // A non-empty directory at the target fails the rename after the temp is written.
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
        // Group writable, which the umask would strip from an open-time mode.
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

    /// A group of this user's other than `not`, via `id`: no `libc` on Linux.
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
        // Set group id, so a new file takes the directory's group on Linux too.
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
        // An unwritable target directory: the sibling route cannot create there and
        // the staged route never tries.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&docs, std::fs::Permissions::from_mode(0o555)).unwrap();
            let refused = RealFileIo::new().write_atomic(&target, b"new");
            std::fs::set_permissions(&docs, std::fs::Permissions::from_mode(0o755)).unwrap();
            // Root writes anywhere.
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

            // Nothing on disk to take, so the reload refuses and the buffer stands.
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
        // A second handle over the same credentials is the relaunch.
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
            // A draft record never lands in the sheet store.
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

    /// A clean and a dirty file staged into drafts; the caller edits the disk.
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
            assert_eq!(row[0]["pendingHydration"], serde_json::json!(false));
            assert_eq!(row[0]["isDirty"], serde_json::json!(false));
            assert_eq!(row[0]["externallyReloaded"], serde_json::json!(false));
            let clean_id = row[0]["id"].as_u64().unwrap();
            assert_eq!(
                take_json(companion_file_runs_json(handle, clean_id)),
                r#"[{"ink":"clean body\n"}]"#
            );
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
            // Only the acknowledgement clears the flag.
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
        // Both files are gone; a restore that read them would drop the clean one.
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
            // The pending buffer is empty, so a save would have emptied the file.
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

            // The holder is still pending, so this waits: true, and still pending.
            assert!(companion_file_hydrate(handle, dirty_id, taken.as_ptr()));
            let row = roster(handle);
            assert_eq!(row[1]["pendingHydration"], serde_json::json!(true));
            assert_eq!(row[1]["path"], serde_json::json!(dirty.to_string_lossy()));
            assert_eq!(row[0]["pendingHydration"], serde_json::json!(true));
            assert!(!companion_file_save(handle, dirty_id, ptr::null()));

            let empty = cstring("");
            assert!(!companion_file_hydrate(handle, clean_id, empty.as_ptr()));
            assert_eq!(
                roster(handle)[0]["pendingHydration"],
                serde_json::json!(true)
            );

            // Once the holder settles, the same rebind is refused.
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
        // Stands in for a file with no grant: the stat answers, the read is refused.
        use std::os::unix::fs::PermissionsExt as _;

        let (keys, dir, clean, dirty, drafts_c) = staged("denied");
        let locked = std::fs::Permissions::from_mode(0o000);
        std::fs::set_permissions(&clean, locked.clone()).unwrap();
        std::fs::set_permissions(&dirty, locked).unwrap();
        if std::fs::read(&clean).is_ok() {
            // Root reads through any mode.
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

            // The stat matches but the read is still refused, so the conflict stands.
            let check: serde_json::Value =
                serde_json::from_str(&take_json(companion_file_check(handle, id))).unwrap();
            assert_eq!(check["state"], serde_json::json!("unchanged"));
            let row = roster(handle);
            assert_eq!(row[1]["conflict"], serde_json::json!("changed"));
            assert_eq!(row[1]["accessRefused"], serde_json::json!(true));
            assert!(!companion_file_save(handle, id, ptr::null()));

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
        // Both moved, no bookmark: the clean one drops as missing, the dirty one
        // stands in a missing conflict.
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

            let held_c = cstring(&held.to_string_lossy());
            assert!(!companion_file_relocate(handle, id, held_c.as_ptr()));
            assert!(companion_file_open_error_json(handle).is_null());

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

            let tab = crate::companion_tab_new(handle);
            assert_ne!(tab, 0);
            let page = tabs(handle)[0]["page_id"].as_u64().unwrap();
            assert!(!companion_file_can_undo(handle, page));
            assert!(!companion_file_can_redo(handle, page));

            assert!(companion_file_can_redo(handle, id));
        }
        cleanup(handle, &dir);
    }

    #[test]
    fn a_fifo_is_refused_rather_than_blocked_on() {
        // On a second thread, so a regression times out rather than hangs.
        let (handle, dir) = scratch("fifo");
        let fifo = dir.join("pipe");
        // `mkfifo` the command: this crate takes `libc` on macOS only.
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

        // The handle still answers: nothing kept the lock.
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
        // Every step over the seam, in the header's order.
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

            assert!(crate::companion_persist_erase(handle, state_c.as_ptr()));
            crate::companion_free(handle);
        }
        assert!(!state.exists(), "the content file went");
        assert!(drafts.exists(), "the draft did not");

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

        // No page left: the rotation the shell runs when the last page expires.
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
