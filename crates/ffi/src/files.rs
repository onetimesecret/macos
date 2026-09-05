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
//! This module is the seam commit. The signatures are the contract the
//! Swift lanes build against; the bodies refuse.

use std::ffi::c_char;
use std::ptr;

use crate::{CompanionHandle, cstr};

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
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    let Some(_path) = (unsafe { cstr(path) }) else {
        return 0;
    };
    0
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
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    ptr::null_mut()
}

/// Close the file and drop its buffer. The draft goes with it: a draft
/// never outlives its tab. The review prompt for a dirty file is the
/// shell's, and it happens before this call.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_close(handle: *mut CompanionHandle, file: u64) -> bool {
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let _ = file;
    false
}

/// The file's body as document runs, the same JSON shape
/// `companion_sheet_document_json` returns. Null for an unknown file.
/// Free with `companion_string_free`.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_runs_json(
    handle: *mut CompanionHandle,
    file: u64,
) -> *mut c_char {
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let _ = file;
    ptr::null_mut()
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
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(_ops) = (unsafe { cstr(ops_json) }) else {
        return false;
    };
    let _ = file;
    false
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
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(_ops) = (unsafe { cstr(ops_json) }) else {
        return false;
    };
    let _ = file;
    false
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
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let _ = file;
    ptr::null_mut()
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
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let _ = file;
    ptr::null_mut()
}

/// Write the buffer back to the file's own path, preserving the BOM and
/// the line ending style it arrived with. False when the write refused,
/// which includes a file standing in a conflict nobody has resolved.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_save(handle: *mut CompanionHandle, file: u64) -> bool {
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let _ = file;
    false
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
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(_path) = (unsafe { cstr(path) }) else {
        return false;
    };
    let _ = file;
    false
}

/// Stat the file and say whether anything else has written it, as the
/// `{state, path}` JSON described in the header. Null for an unknown
/// file. Free with `companion_string_free`.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_check(
    handle: *mut CompanionHandle,
    file: u64,
) -> *mut c_char {
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let _ = file;
    ptr::null_mut()
}

/// Re-read the file from disk, discarding whatever the buffer held.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_reload(handle: *mut CompanionHandle, file: u64) -> bool {
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let _ = file;
    false
}

/// Every open file, in open order, as an array of `FileSummary`. Null
/// when the answer cannot be had. Free with `companion_string_free`.
///
/// # Safety
/// `handle` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_file_roster_json(handle: *mut CompanionHandle) -> *mut c_char {
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    ptr::null_mut()
}

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
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(_path) = (unsafe { cstr(path) }) else {
        return false;
    };
    false
}

/// Restore the roster and the drafts at launch. False covers a fresh
/// start with no file as much as a refused one.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_drafts_restore(
    handle: *mut CompanionHandle,
    path: *const c_char,
) -> bool {
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(_path) = (unsafe { cstr(path) }) else {
        return false;
    };
    false
}

/// Drop the drafts file at `path`. True when the path is confirmed
/// empty, including when there was nothing there to begin with.
///
/// # Safety
/// `handle` must be a valid handle; `path` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_drafts_erase(
    handle: *mut CompanionHandle,
    path: *const c_char,
) -> bool {
    let Some(_handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(_path) = (unsafe { cstr(path) }) else {
        return false;
    };
    false
}
