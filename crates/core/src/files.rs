//! Open files: the second content class.
//!
//! A file on disk is the artifact. A file is never a page, never a Tab,
//! never counted against the nine page cap, never in the day roll and
//! never synced. Sync exclusion is structural rather than a rule:
//! [`crate::store::SheetStore::export_document_updates`] is the only
//! function that turns store state into relay payload, and nothing in
//! this module is reachable from it.
//!
//! Files live in their own [`FileStore`], addressed by a tagged
//! [`FileId`]. They reuse the same Loro backed document the pages use,
//! so undo, the operation vocabulary and the UTF-16 discipline come for
//! free. What does not come with it is provenance: a file's change
//! timestamps mean nothing, so the block stamp path is gated off for
//! file ids in the shell rather than left to produce dull values.
//!
//! Platform IO stays out of this crate. The whole platform surface is
//! the [`FileIo`] trait, implemented in `crates/ffi`. Paths cross the
//! FFI, bytes never do.
//!
//! This module is the seam commit. The types and the signatures are the
//! contract three lanes build against. The bodies are not written yet.

// Seam commit: the fields and the helpers below are the contract, and
// the lane that fills the bodies is what reads them. Without this the
// stub bodies alone would raise dead code warnings for every field.
#![allow(dead_code)]

use std::io;
use std::path::{Path, PathBuf};

use crate::document::SheetDocument;

/// The high bit, set on every [`FileId`] and on no page id.
///
/// Defined once here and mirrored once in Swift as
/// `CompanionClient.fileIDTag`, with a comment on both sides pointing
/// at the other. Two stores addressed by one `u64` is a correctness
/// hazard, so the tag is not a convention: every `companion_sheet_*`
/// entry point refuses a tagged id by returning its failure value, and
/// a test in `crates/ffi` passes one to each.
pub const FILE_ID_TAG: u64 = 1 << 63;

/// The largest file this build opens, in bytes. A refusal names the
/// limit so the notice can state it rather than guess it.
pub const FILE_SIZE_LIMIT: usize = 4 * 1024 * 1024;

/// An open file's id: a `u64` with [`FILE_ID_TAG`] set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct FileId(pub u64);

impl FileId {
    /// Whether a raw id off the wire addresses a file rather than a
    /// page. The one question every `companion_sheet_*` guard asks.
    pub fn is_tagged(raw: u64) -> bool {
        raw & FILE_ID_TAG != 0
    }

    /// The raw id, as it crosses the C ABI.
    pub fn raw(self) -> u64 {
        self.0
    }
}

/// Which line ending the file arrived with, and therefore which one it
/// is written back with. Mixed endings settle on whichever the file
/// held more of; the reading is decided at open and never after.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineEnding {
    /// A single newline, the reading a file with no CRLF pair takes.
    Lf,
    /// A carriage return and a newline.
    Crlf,
}

/// What the filesystem said about the file the last time this store
/// read it or wrote it. Compared against a fresh stat to answer
/// [`FileStore::check`]. Never leaves Rust.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileWitness {
    /// The device the file sits on.
    pub dev: u64,
    /// The inode. Together with `dev` it names the file itself rather
    /// than the path, so a replaced file reads as changed even when its
    /// size and its stamp match.
    pub ino: u64,
    /// Size in bytes.
    pub size: u64,
    /// Modification time, nanoseconds since the Unix epoch.
    pub mtime_ns: i128,
}

/// One open file.
pub struct OpenFile {
    id: FileId,
    path: PathBuf,
    /// The same document type a page uses, with one peer and no remote.
    document: SheetDocument,
    /// Hash of the bytes last read from or written to disk, so a round
    /// trip back to the saved text reads as clean.
    saved_bytes_hash: [u8; 32],
    witness: FileWitness,
    line_ending: LineEnding,
    has_bom: bool,
    dirty: bool,
}

/// The whole platform surface a file needs. Keeps this crate free of
/// platform IO and headless testable; the real implementation lives in
/// `crates/ffi`, modelled on `write_private` but preserving the target
/// file's mode rather than forcing 0600.
pub trait FileIo {
    /// Read the whole file.
    fn read(&self, path: &Path) -> io::Result<Vec<u8>>;
    /// Write the whole file at once, atomically, preserving the mode of
    /// the file already at the path when there is one.
    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<()>;
    /// Take a witness of whatever is at the path right now.
    fn stat(&self, path: &Path) -> io::Result<FileWitness>;
}

/// Why an open, or a reload, refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenRefusal {
    /// The bytes are not UTF-8. A flat refusal: nothing opens read
    /// only, and nothing opens with replacement characters standing in
    /// for a person's text.
    NotUtf8,
    /// The file is larger than [`FILE_SIZE_LIMIT`], which travels with
    /// the refusal so the notice can state it.
    TooLarge {
        /// The limit that was exceeded, in bytes.
        limit: usize,
    },
    /// The read itself failed.
    Io(io::ErrorKind),
}

/// Why a save refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SaveError {
    /// The file changed under a dirty buffer and no resolution has been
    /// chosen yet. Save stays refused until one is.
    Conflict,
    /// No file with that id is open.
    UnknownFile,
    /// The write itself failed. The file on disk is untouched.
    Io(io::ErrorKind),
}

/// What a fresh stat says about the file behind an open buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExternalState {
    /// The witness still matches.
    Unchanged,
    /// Something else wrote the file.
    Changed,
    /// Nothing is at the path any more.
    Missing,
}

/// Every open file. No cap, no clock, no TTL: none of the three means
/// anything to a file, and the store that holds pages is the one that
/// counts to nine.
#[derive(Default)]
pub struct FileStore {
    files: Vec<OpenFile>,
    next_id: u64,
}

impl FileStore {
    /// An empty store.
    pub fn new() -> Self {
        Self::default()
    }

    /// Read the file at `path` and open a buffer over it.
    pub fn open(&mut self, io: &dyn FileIo, path: &Path) -> Result<FileId, OpenRefusal> {
        let _ = (io, path);
        Err(OpenRefusal::Io(io::ErrorKind::Unsupported))
    }

    /// Drop the buffer. The draft dies with it: a draft never outlives
    /// its tab, so reopening the file later never resurrects old edits.
    /// Whether a dirty buffer may be closed at all is the shell's
    /// review prompt, not this call.
    pub fn close(&mut self, id: FileId) -> bool {
        let _ = id;
        false
    }

    /// The file's body. Crate private, like the document type itself:
    /// every Loro call stays behind that one module's seam, so the FFI
    /// reaches a file's text through methods on this store the way it
    /// reaches a page's through methods on [`crate::store::SheetStore`].
    pub(crate) fn document(&self, id: FileId) -> Option<&SheetDocument> {
        let _ = id;
        None
    }

    /// Whether the buffer holds edits the file on disk does not.
    pub fn is_dirty(&self, id: FileId) -> bool {
        let _ = id;
        false
    }

    /// Write the buffer back to its own path, preserving the BOM and
    /// the line ending style the file arrived with.
    pub fn save(&mut self, io: &dyn FileIo, id: FileId) -> Result<(), SaveError> {
        let _ = (io, id);
        Err(SaveError::UnknownFile)
    }

    /// Write the buffer to a new path and adopt it.
    pub fn save_as(&mut self, io: &dyn FileIo, id: FileId, path: &Path) -> Result<(), SaveError> {
        let _ = (io, id, path);
        Err(SaveError::UnknownFile)
    }

    /// Stat the path and compare it against the witness taken at the
    /// last read or write.
    pub fn check(&self, io: &dyn FileIo, id: FileId) -> ExternalState {
        let _ = (io, id);
        todo!("files lane: compare a fresh stat against the stored witness")
    }

    /// Re-read the file from disk, discarding whatever the buffer held.
    pub fn reload(&mut self, io: &dyn FileIo, id: FileId) -> Result<(), OpenRefusal> {
        let _ = (io, id);
        Err(OpenRefusal::Io(io::ErrorKind::Unsupported))
    }

    /// Every open file, in open order. The roster the strip draws and
    /// the roster the drafts file records.
    pub fn files(&self) -> &[OpenFile] {
        &self.files
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tag_is_the_high_bit() {
        assert_eq!(FILE_ID_TAG, 0x8000_0000_0000_0000);
    }

    #[test]
    fn untagged_ids_are_not_files() {
        assert!(!FileId::is_tagged(0));
        assert!(!FileId::is_tagged(1));
        assert!(!FileId::is_tagged(u64::MAX >> 1));
    }

    #[test]
    fn tagged_ids_are_files() {
        assert!(FileId::is_tagged(FILE_ID_TAG));
        assert!(FileId::is_tagged(FILE_ID_TAG | 7));
        assert!(FileId::is_tagged(u64::MAX));
    }

    #[test]
    fn a_fresh_store_holds_nothing() {
        assert!(FileStore::new().files().is_empty());
    }
}
