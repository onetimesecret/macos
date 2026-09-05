//! The drafts snapshot: `OTSDRFT1`.
//!
//! A dirty file's unsaved edits and the roster of open files go in a
//! third plaintext buffer, sealed in `crates/ffi` under the same content
//! key as the state file and under an envelope magic of its own. Not a
//! new section inside `OTSSNAP4`: that is a format break, and it would
//! cost every user their pages once. Not a trailing field on the tab
//! record either, cheap as that is: it would make a file's draft a
//! property of a Tab, and a Tab is the object the nine page cap counts.
//! One file keeps the two content classes structurally apart.
//!
//! Layout follows the content snapshot exactly: magic, wall stamp,
//! count, then one framed record per open file. Records are positional
//! and carry no kind tag, so a trailing field inside a record is
//! tolerated and anything past the record list is not. Same framed
//! helper, same strict envelope rule. `OTSSNAP4` is not touched.
//!
//! One record per open file: the bookmark blob, the last known path,
//! the witness, the dirty flag, and for a dirty file the Loro snapshot.
//! A clean file records only its identity, so its tab comes back with
//! nothing staged behind it.
//!
//! Drafts die on save, on discard, on `companion_persist_erase`, and
//! whenever the content key halves rotate without this file being
//! rewritten in the same operation. Rotation must rewrite it.
//!
//! This module is the seam commit. The bodies are not written yet.

use crate::files::FileStore;
use crate::persist::RestoreError;

/// Magic and version prefix of a plaintext drafts snapshot. Separate
/// from the content and ledger magics so no two of the three files can
/// ever be mistaken for each other.
pub const MAGIC: &[u8; 8] = b"OTSDRFT1";

/// Serialize the open file roster and every dirty file's draft.
pub fn emit(store: &FileStore, wall_ms: u64) -> Vec<u8> {
    let _ = (store, wall_ms);
    todo!("files lane: emit the OTSDRFT1 records")
}

/// Read a drafts snapshot back into an empty store, returning how many
/// files were restored.
///
/// # Errors
///
/// [`RestoreError::UnknownFormat`] for a buffer that is not a drafts
/// snapshot this build reads; [`RestoreError::Malformed`] for one that
/// is damaged.
pub fn restore(store: &mut FileStore, bytes: &[u8], wall_ms: u64) -> Result<usize, RestoreError> {
    let _ = (store, bytes, wall_ms);
    Err(RestoreError::UnknownFormat)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn magic_is_its_own() {
        assert_eq!(MAGIC, b"OTSDRFT1");
        assert_ne!(MAGIC.as_slice(), b"OTSSNAP4".as_slice());
        assert_ne!(MAGIC.as_slice(), b"OTSLEDR2".as_slice());
    }
}
