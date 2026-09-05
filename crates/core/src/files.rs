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
//! Dirtiness is answered by comparing the buffer against the text last
//! read from or written to disk, held here in full rather than as a
//! digest. The buffer is already bounded by [`FILE_SIZE_LIMIT`], so the
//! second copy is bounded too, and an exact comparison can never report
//! an edited file clean. Typing a word and deleting it again therefore
//! returns the file to clean, which a monotonic dirty flag would not.

use std::io;
use std::path::{Path, PathBuf};

use crate::document::{DocRun, SheetDocument};
use crate::store::EditOp;

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

/// The UTF-8 byte order mark, stripped at open and put back at save for
/// a file that arrived with one.
const UTF8_BOM: &[u8] = &[0xEF, 0xBB, 0xBF];

/// An open file's id: a `u64` with [`FILE_ID_TAG`] set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct FileId(pub u64);

impl FileId {
    /// Whether a raw id off the wire addresses a file rather than a
    /// page. The one question every `companion_sheet_*` guard asks.
    #[must_use]
    pub fn is_tagged(raw: u64) -> bool {
        raw & FILE_ID_TAG != 0
    }

    /// The raw id, as it crosses the C ABI.
    #[must_use]
    pub fn raw(self) -> u64 {
        self.0
    }
}

/// Which line ending the file arrived with, and therefore which one it
/// is written back with.
///
/// The first line ending in the file decides it, and the decision is
/// taken at open and never revisited until a reload. A file with mixed
/// endings is normalised to a single newline in the buffer and written
/// back entirely in the style the first line used, so saving such a
/// file makes it uniform. That is a visible change to a file the user
/// did not ask for, and it is the honest reading: the buffer holds one
/// style, so a save can only write one style.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineEnding {
    /// A single newline, the reading a file with no CRLF pair takes.
    Lf,
    /// A carriage return and a newline.
    Crlf,
}

impl LineEnding {
    /// The reading the text itself takes: whichever ending comes first.
    fn detect(text: &str) -> Self {
        match text.find('\n') {
            Some(0) | None => Self::Lf,
            Some(at) if text.as_bytes()[at - 1] == b'\r' => Self::Crlf,
            Some(_) => Self::Lf,
        }
    }

    /// The wire form of the enum, as the roster JSON spells it.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Lf => "lf",
            Self::Crlf => "crlf",
        }
    }

    /// The reading a persisted byte carried.
    fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::Lf),
            1 => Some(Self::Crlf),
            _ => None,
        }
    }

    /// The byte this reading persists as.
    fn code(self) -> u8 {
        match self {
            Self::Lf => 0,
            Self::Crlf => 1,
        }
    }
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

/// Where a file stands against the copy on disk, as the roster reports
/// it. Distinct from [`ExternalState`] because they answer different
/// questions: a clean file whose bytes changed on disk reloads without
/// asking and never enters a conflict at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum FileConflict {
    /// Nothing to resolve. Saving is allowed.
    #[default]
    None,
    /// Something else wrote the file while this buffer held edits.
    Changed,
    /// The file went away while this buffer held edits.
    Missing,
}

impl FileConflict {
    /// The wire form of the enum, as the roster JSON spells it.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Changed => "changed",
            Self::Missing => "missing",
        }
    }
}

/// The whole platform surface a file needs. Keeps this crate free of
/// platform IO and headless testable; the real implementation lives in
/// `crates/ffi`, modelled on `write_private` but preserving the target
/// file's mode rather than forcing 0600.
pub trait FileIo {
    /// Read the whole file.
    ///
    /// # Errors
    /// Whatever the platform said about the read.
    fn read(&self, path: &Path) -> io::Result<Vec<u8>>;
    /// Write the whole file at once, atomically, preserving the mode of
    /// the file already at the path when there is one.
    ///
    /// # Errors
    /// Whatever the platform said about the write.
    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<()>;
    /// Take a witness of whatever is at the path right now.
    ///
    /// # Errors
    /// Whatever the platform said about the stat.
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

impl ExternalState {
    /// The wire form of the enum, as the check JSON spells it.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unchanged => "unchanged",
            Self::Changed => "changed",
            Self::Missing => "missing",
        }
    }
}

/// What one undo or redo did: whether it moved anything, and where the
/// caret belongs afterwards in UTF-16 code units. The two answers the
/// page routes give in two calls, given here in one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StepOutcome {
    /// Whether the step moved anything.
    pub applied: bool,
    /// Where the caret belongs, or `None` for a step that carried no
    /// position.
    pub caret_u16: Option<u32>,
}

/// One open file.
pub struct OpenFile {
    id: FileId,
    path: PathBuf,
    /// The same document type a page uses, with one peer and no remote.
    document: SheetDocument,
    /// The text last read from or written to disk, normalised the way
    /// the buffer holds it. `None` for a file whose buffer came back
    /// from a draft, where this store never saw the disk copy and the
    /// persisted dirty flag is the only answer there is.
    saved_text: Option<String>,
    witness: Option<FileWitness>,
    line_ending: LineEnding,
    has_bom: bool,
    dirty: bool,
    conflict: FileConflict,
    /// Wall clock of the last accepted op batch, Unix milliseconds, or
    /// zero for a file nothing has typed into.
    last_edited_ms: u64,
    /// Whether this buffer came back from `drafts.sealed`.
    restored_from_draft: bool,
    /// The shell's bookmark for this file, opaque here. Empty until the
    /// shell attaches one.
    bookmark: Vec<u8>,
}

impl OpenFile {
    /// The file's tagged id.
    #[must_use]
    pub fn id(&self) -> FileId {
        self.id
    }

    /// The display name: the last component of the path.
    #[must_use]
    pub fn name(&self) -> String {
        self.path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default()
    }

    /// The last known path.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Whether the buffer holds edits the file on disk does not.
    #[must_use]
    pub fn is_dirty(&self) -> bool {
        self.dirty
    }

    /// Where the file stands against the copy on disk.
    #[must_use]
    pub fn conflict(&self) -> FileConflict {
        self.conflict
    }

    /// The line ending the file arrived with and will be written with.
    #[must_use]
    pub fn line_ending(&self) -> LineEnding {
        self.line_ending
    }

    /// Whether the file carried a UTF-8 byte order mark.
    #[must_use]
    pub fn has_bom(&self) -> bool {
        self.has_bom
    }

    /// Wall clock of the last accepted op batch, Unix seconds, or zero
    /// for a file nothing has typed into. The header of a restored
    /// dirty file states this so a person can see the draft's age.
    #[must_use]
    pub fn last_edited_at(&self) -> u64 {
        self.last_edited_ms / 1000
    }

    /// Whether this buffer came back from `drafts.sealed`.
    #[must_use]
    pub fn restored_from_draft(&self) -> bool {
        self.restored_from_draft
    }

    /// The shell's bookmark for this file, opaque to this crate.
    #[must_use]
    pub fn bookmark(&self) -> &[u8] {
        &self.bookmark
    }

    /// The buffer as text: newlines only, no byte order mark. What the
    /// editor draws and what a draft's snapshot replays to.
    #[must_use]
    pub fn text(&self) -> String {
        text_of(&self.document)
    }

    /// The bytes a save would write: the buffer in the file's own line
    /// ending style, behind the byte order mark it arrived with.
    #[must_use]
    pub fn bytes_to_write(&self) -> Vec<u8> {
        let text = self.text();
        let body = match self.line_ending {
            LineEnding::Lf => text,
            LineEnding::Crlf => text.replace('\n', "\r\n"),
        };
        let mut bytes = Vec::with_capacity(body.len() + UTF8_BOM.len());
        if self.has_bom {
            bytes.extend_from_slice(UTF8_BOM);
        }
        bytes.extend_from_slice(body.as_bytes());
        bytes
    }

    /// Recompute the dirty flag from the buffer against the saved text.
    /// A file whose saved text is unknown keeps the flag it has, which
    /// is the persisted one.
    fn resettle_dirty(&mut self) {
        if let Some(saved) = &self.saved_text {
            self.dirty = *saved != text_of(&self.document);
        }
    }

    /// Adopt the text now on disk as both the buffer and the saved
    /// copy, discarding whatever the buffer held.
    fn adopt(&mut self, read: ReadFile) {
        self.document = document_holding(&read.text);
        self.saved_text = Some(read.text);
        self.witness = Some(read.witness);
        self.line_ending = read.line_ending;
        self.has_bom = read.has_bom;
        self.dirty = false;
        self.conflict = FileConflict::None;
        self.restored_from_draft = false;
    }
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
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Read the file at `path` and open a buffer over it.
    ///
    /// A file already open at the same path is handed back rather than
    /// opened twice: two buffers over one file would race each other on
    /// save, and the shell's answer to a second open is to raise the
    /// tab that is already there.
    ///
    /// # Errors
    ///
    /// [`OpenRefusal::NotUtf8`] for bytes that are not UTF-8,
    /// [`OpenRefusal::TooLarge`] above [`FILE_SIZE_LIMIT`], and
    /// [`OpenRefusal::Io`] for a read the platform refused.
    pub fn open(&mut self, io: &dyn FileIo, path: &Path) -> Result<FileId, OpenRefusal> {
        if let Some(open) = self.files.iter().find(|file| file.path == path) {
            return Ok(open.id);
        }
        let read = read_file(io, path)?;
        self.next_id += 1;
        let id = FileId(FILE_ID_TAG | self.next_id);
        self.files.push(OpenFile {
            id,
            path: path.to_path_buf(),
            document: document_holding(&read.text),
            saved_text: Some(read.text),
            witness: Some(read.witness),
            line_ending: read.line_ending,
            has_bom: read.has_bom,
            dirty: false,
            conflict: FileConflict::None,
            last_edited_ms: 0,
            restored_from_draft: false,
            bookmark: Vec::new(),
        });
        Ok(id)
    }

    /// Drop the buffer. The draft dies with it: a draft never outlives
    /// its tab, so reopening the file later never resurrects old edits.
    /// Whether a dirty buffer may be closed at all is the shell's
    /// review prompt, not this call.
    pub fn close(&mut self, id: FileId) -> bool {
        let Some(at) = self.files.iter().position(|file| file.id == id) else {
            return false;
        };
        self.files.remove(at);
        true
    }

    /// One open file, by id.
    #[must_use]
    pub fn file(&self, id: FileId) -> Option<&OpenFile> {
        self.files.iter().find(|file| file.id == id)
    }

    fn file_mut(&mut self, id: FileId) -> Option<&mut OpenFile> {
        self.files.iter_mut().find(|file| file.id == id)
    }

    /// The file's body as text, which is the whole of what a file's
    /// runs can be: a file holds no chips, so nothing here can be
    /// anything but ink.
    #[must_use]
    pub fn text(&self, id: FileId) -> Option<String> {
        self.file(id).map(OpenFile::text)
    }

    /// Whether the buffer holds edits the file on disk does not.
    #[must_use]
    pub fn is_dirty(&self, id: FileId) -> bool {
        self.file(id).is_some_and(OpenFile::is_dirty)
    }

    /// Attach the shell's bookmark for this file. The blob is opaque
    /// here: this crate never resolves it and never inspects it, it
    /// only carries it into `drafts.sealed` and back.
    pub fn set_bookmark(&mut self, id: FileId, bookmark: Vec<u8>) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        file.bookmark = bookmark;
        true
    }

    /// Apply an ordered edit batch to the file's body, or refuse it
    /// whole. `wall_ms` stamps the file's last edit when the batch is
    /// accepted.
    pub fn apply_ops(&mut self, id: FileId, ops: &[EditOp], wall_ms: u64) -> bool {
        self.apply_batch(id, ops, wall_ms, false)
    }

    /// [`FileStore::apply_ops`] for a batch the app produced on the
    /// writer's behalf, which must begin its own undo step.
    pub fn apply_ops_as_new_step(&mut self, id: FileId, ops: &[EditOp], wall_ms: u64) -> bool {
        self.apply_batch(id, ops, wall_ms, true)
    }

    fn apply_batch(&mut self, id: FileId, ops: &[EditOp], wall_ms: u64, new_step: bool) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        // Phase one: the whole batch against a simulation in exact code
        // units, so a refusal is atomic and a boundary inside a
        // surrogate pair is policed as strictly as the document would.
        let mut sim: Vec<u16> = file.text().encode_utf16().collect();
        for op in ops {
            if !sim_admit(&mut sim, op) {
                return false;
            }
        }
        // Phase two: the document. Every offset was validated against
        // exact post-op state, so these cannot refuse; a refusal anyway
        // stops the walk and returns false, which tells the shell to
        // restate the file from its runs.
        let mut clean = true;
        for op in ops {
            let outcome = match op {
                EditOp::Insert { pos_u16, text } => file.document.insert(*pos_u16 as usize, text),
                EditOp::Delete { pos_u16, len_u16 } => {
                    file.document.delete(*pos_u16 as usize, *len_u16 as usize)
                }
                // Phase one refuses every chip op, so this arm is
                // unreachable. It stays a refusal rather than a panic.
                EditOp::InsertChip { .. } => Err(crate::document::InvalidRange),
            };
            if outcome.is_err() {
                clean = false;
                break;
            }
        }
        if new_step {
            file.document.commit_as_new_step(None);
        } else {
            file.document.commit(None);
        }
        file.last_edited_ms = wall_ms;
        file.resettle_dirty();
        clean
    }

    /// Take back the file's last local edit step.
    pub fn undo(&mut self, id: FileId) -> Option<StepOutcome> {
        self.step(id, true)
    }

    /// Put back the step [`FileStore::undo`] took, on the same terms.
    pub fn redo(&mut self, id: FileId) -> Option<StepOutcome> {
        self.step(id, false)
    }

    fn step(&mut self, id: FileId, back: bool) -> Option<StepOutcome> {
        let file = self.file_mut(id)?;
        let applied = if back {
            file.document.undo()
        } else {
            file.document.redo()
        };
        let caret_u16 = if applied {
            file.document
                .restored_caret()
                .and_then(|c| u32::try_from(c).ok())
        } else {
            None
        };
        if applied {
            file.resettle_dirty();
        }
        Some(StepOutcome { applied, caret_u16 })
    }

    /// Write the buffer back to its own path, preserving the BOM and
    /// the line ending style the file arrived with.
    ///
    /// # Errors
    ///
    /// [`SaveError::Conflict`] while a conflict is unresolved,
    /// [`SaveError::UnknownFile`] for an id nothing is open under, and
    /// [`SaveError::Io`] for a write the platform refused, which leaves
    /// the file on disk untouched.
    pub fn save(&mut self, io: &dyn FileIo, id: FileId) -> Result<(), SaveError> {
        let file = self.file_mut(id).ok_or(SaveError::UnknownFile)?;
        if file.conflict != FileConflict::None {
            return Err(SaveError::Conflict);
        }
        let path = file.path.clone();
        write_and_settle(io, file, &path)
    }

    /// Write the buffer to a new path and adopt it. This is also one of
    /// the three conflict resolutions, so it is allowed while a
    /// conflict stands: writing somewhere else cannot overwrite the
    /// change that caused the conflict.
    ///
    /// # Errors
    ///
    /// [`SaveError::UnknownFile`] for an id nothing is open under, and
    /// [`SaveError::Io`] for a write the platform refused.
    pub fn save_as(&mut self, io: &dyn FileIo, id: FileId, path: &Path) -> Result<(), SaveError> {
        let file = self.file_mut(id).ok_or(SaveError::UnknownFile)?;
        write_and_settle(io, file, path)?;
        file.path = path.to_path_buf();
        Ok(())
    }

    /// Stat the path and compare it against the witness taken at the
    /// last read or write. Asks nothing of the buffer and changes
    /// nothing: [`FileStore::refresh_conflict`] is the call that acts
    /// on the answer.
    ///
    /// A stat that fails for any reason other than absence reads as
    /// [`ExternalState::Changed`]. That is the conservative direction:
    /// an unreadable path must not license a save over whatever is
    /// actually there.
    #[must_use]
    pub fn check(&self, io: &dyn FileIo, id: FileId) -> ExternalState {
        let Some(file) = self.file(id) else {
            return ExternalState::Missing;
        };
        match io.stat(&file.path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => ExternalState::Missing,
            Err(_) => ExternalState::Changed,
            Ok(fresh) => {
                if Some(fresh) == file.witness {
                    ExternalState::Unchanged
                } else {
                    ExternalState::Changed
                }
            }
        }
    }

    /// [`FileStore::check`], and then set the file's conflict from the
    /// answer. A clean buffer never enters a conflict: the shell
    /// reloads it without asking and posts a notice. A dirty buffer
    /// does, and stays there until one of the three resolutions is
    /// taken.
    pub fn refresh_conflict(&mut self, io: &dyn FileIo, id: FileId) -> ExternalState {
        let state = self.check(io, id);
        if let Some(file) = self.file_mut(id) {
            file.conflict = match (state, file.dirty) {
                (ExternalState::Unchanged, _) | (_, false) => FileConflict::None,
                (ExternalState::Changed, true) => FileConflict::Changed,
                (ExternalState::Missing, true) => FileConflict::Missing,
            };
        }
        state
    }

    /// Keep mine: the first of the three conflict resolutions. The
    /// buffer stands and the next save overwrites whatever is on disk,
    /// so the witness is dropped rather than refreshed. Take theirs is
    /// [`FileStore::reload`] and the third is [`FileStore::save_as`].
    pub fn resolve_keep_mine(&mut self, id: FileId) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        file.conflict = FileConflict::None;
        // The witness described a file this buffer is about to
        // overwrite on purpose. Dropping it means the next check
        // answers `Changed` until a save takes a fresh one, which is
        // the honest answer for a buffer that has diverged by consent.
        file.witness = None;
        true
    }

    /// Re-read the file from disk, discarding whatever the buffer held.
    /// Take theirs, and also the silent reload a clean file gets when
    /// something else wrote it.
    ///
    /// # Errors
    ///
    /// The same refusals [`FileStore::open`] gives. A refused reload
    /// leaves the buffer exactly as it was.
    pub fn reload(&mut self, io: &dyn FileIo, id: FileId) -> Result<(), OpenRefusal> {
        let path = self
            .file(id)
            .ok_or(OpenRefusal::Io(io::ErrorKind::NotFound))?
            .path
            .clone();
        let read = read_file(io, &path)?;
        if let Some(file) = self.file_mut(id) {
            file.adopt(read);
        }
        Ok(())
    }

    /// Every open file, in open order. The roster the strip draws and
    /// the roster the drafts file records.
    #[must_use]
    pub fn files(&self) -> &[OpenFile] {
        &self.files
    }

    /// Forget every open file. The drafts restore path calls this
    /// before it fills the store, so a restore is a replacement rather
    /// than an append.
    pub(crate) fn clear(&mut self) {
        self.files.clear();
        self.next_id = 0;
    }

    /// Put back one file from a drafts record. Everything a restore
    /// knows arrives here at once, because a half built buffer has no
    /// valid state to sit in.
    ///
    /// `snapshot` is the buffer's Loro snapshot for a dirty file and
    /// `None` for a clean one. A clean file comes back holding nothing:
    /// its text is on disk, and the shell fills it with a reload. That
    /// is why a clean record carries identity only.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn adopt_restored(
        &mut self,
        path: PathBuf,
        bookmark: Vec<u8>,
        witness: Option<FileWitness>,
        line_ending: LineEnding,
        has_bom: bool,
        dirty: bool,
        last_edited_ms: u64,
        snapshot: Option<&[u8]>,
    ) -> Result<FileId, crate::persist::RestoreError> {
        let document = SheetDocument::new();
        if let Some(snapshot) = snapshot {
            document.import_snapshot(snapshot)?;
            document.forget_undo();
        }
        self.next_id += 1;
        let id = FileId(FILE_ID_TAG | self.next_id);
        self.files.push(OpenFile {
            id,
            path,
            document,
            // The disk copy was never read in this process, so nothing
            // here can recompute dirtiness. The persisted flag is the
            // only answer there is until a save or a reload.
            saved_text: None,
            witness,
            line_ending,
            has_bom,
            dirty,
            conflict: FileConflict::None,
            last_edited_ms,
            restored_from_draft: true,
            bookmark,
        });
        Ok(id)
    }

    /// The Loro snapshot of a dirty file's buffer, for the drafts
    /// record. `None` for a clean file, which records identity only.
    pub(crate) fn draft_snapshot(&self, id: FileId) -> Option<zeroize::Zeroizing<Vec<u8>>> {
        let file = self.file(id)?;
        file.dirty.then(|| file.document.export_snapshot())
    }
}

/// The persisted view of one open file, read by `file_persist`.
impl OpenFile {
    pub(crate) fn witness_or_zero(&self) -> FileWitness {
        self.witness.unwrap_or(FileWitness {
            dev: 0,
            ino: 0,
            size: 0,
            mtime_ns: 0,
        })
    }

    pub(crate) fn has_witness(&self) -> bool {
        self.witness.is_some()
    }

    pub(crate) fn line_ending_code(&self) -> u8 {
        self.line_ending.code()
    }

    pub(crate) fn last_edited_ms(&self) -> u64 {
        self.last_edited_ms
    }
}

/// The reading of a line ending byte a drafts record carried.
pub(crate) fn line_ending_from_code(code: u8) -> Option<LineEnding> {
    LineEnding::from_code(code)
}

/// What one read of a file settled: the normalised text and everything
/// about the bytes the buffer has to remember to write them back.
struct ReadFile {
    text: String,
    witness: FileWitness,
    line_ending: LineEnding,
    has_bom: bool,
}

/// Read, refuse, strip and normalise. The one place bytes become a
/// buffer.
fn read_file(io: &dyn FileIo, path: &Path) -> Result<ReadFile, OpenRefusal> {
    let bytes = io.read(path).map_err(|e| OpenRefusal::Io(e.kind()))?;
    // The size is answered before the UTF-8 decode, so an enormous file
    // is refused for its size rather than after a decode of it.
    if bytes.len() > FILE_SIZE_LIMIT {
        return Err(OpenRefusal::TooLarge {
            limit: FILE_SIZE_LIMIT,
        });
    }
    let has_bom = bytes.starts_with(UTF8_BOM);
    let body = if has_bom {
        &bytes[UTF8_BOM.len()..]
    } else {
        &bytes[..]
    };
    let text = std::str::from_utf8(body).map_err(|_| OpenRefusal::NotUtf8)?;
    let line_ending = LineEnding::detect(text);
    let witness = io.stat(path).map_err(|e| OpenRefusal::Io(e.kind()))?;
    Ok(ReadFile {
        text: text.replace("\r\n", "\n"),
        witness,
        line_ending,
        has_bom,
    })
}

/// A fresh document holding exactly `text`, with an empty undo stack:
/// the insert that filled it is the file arriving, not a step anyone
/// may take back.
fn document_holding(text: &str) -> SheetDocument {
    let document = SheetDocument::new();
    if !text.is_empty() {
        document
            .insert(0, text)
            .expect("an insert at zero into an empty body");
    }
    document.commit(None);
    document.forget_undo();
    document
}

/// The document's text. A file holds no chips, so a sentinel could only
/// arrive through a chip op, and phase one refuses every one of those.
/// A sentinel that somehow stood anyway would be written out as the
/// replacement character it is rather than silently dropped.
fn text_of(document: &SheetDocument) -> String {
    let mut text = String::new();
    for run in document.runs() {
        match run {
            DocRun::Ink(ink) => text.push_str(&ink),
            DocRun::Chip(_) => text.push('\u{FFFC}'),
        }
    }
    text
}

/// Write the buffer to `path` and settle the file around what landed.
fn write_and_settle(io: &dyn FileIo, file: &mut OpenFile, path: &Path) -> Result<(), SaveError> {
    let bytes = file.bytes_to_write();
    io.write_atomic(path, &bytes)
        .map_err(|e| SaveError::Io(e.kind()))?;
    // The witness has to describe what is on disk now, so it is taken
    // after the write rather than predicted from the bytes. A stat that
    // will not answer leaves the file with no witness, which reads as
    // changed on the next check: conservative, and it costs one prompt
    // rather than a silent overwrite.
    file.witness = io.stat(path).ok();
    file.saved_text = Some(file.text());
    file.dirty = false;
    file.conflict = FileConflict::None;
    file.restored_from_draft = false;
    Ok(())
}

/// One op against the simulated body, in exact UTF-16 code units.
/// Returns whether it applied; a false leaves the batch refused whole.
fn sim_admit(sim: &mut Vec<u16>, op: &EditOp) -> bool {
    match op {
        EditOp::Insert { pos_u16, text } => {
            let at = *pos_u16 as usize;
            if !boundary(sim, at) {
                return false;
            }
            let units: Vec<u16> = text.encode_utf16().collect();
            sim.splice(at..at, units);
            true
        }
        EditOp::Delete { pos_u16, len_u16 } => {
            let at = *pos_u16 as usize;
            let Some(end) = at.checked_add(*len_u16 as usize) else {
                return false;
            };
            if end > sim.len() || !boundary(sim, at) || !boundary(sim, end) {
                return false;
            }
            sim.drain(at..end);
            true
        }
        // A file holds no chips. There is no roster to own one and no
        // sealed byte for it to stand for, so the op is refused rather
        // than given a meaning here.
        EditOp::InsertChip { .. } => false,
    }
}

/// Whether `at` names a position the body recognizes: in bounds, and
/// not between the two halves of a surrogate pair.
fn boundary(sim: &[u16], at: usize) -> bool {
    if at > sim.len() {
        return false;
    }
    if at == 0 || at == sim.len() {
        return true;
    }
    let before = sim[at - 1];
    let after = sim[at];
    !((0xD800..=0xDBFF).contains(&before) && (0xDC00..=0xDFFF).contains(&after))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    /// An in-memory filesystem: enough of one to exercise every path
    /// through this module without touching a real disk.
    #[derive(Default)]
    struct MemoryIo {
        files: Mutex<HashMap<PathBuf, Vec<u8>>>,
        /// Bumped on every write so two writes of the same bytes still
        /// produce different witnesses, the way a real mtime would.
        tick: Mutex<i128>,
        stamps: Mutex<HashMap<PathBuf, i128>>,
    }

    impl MemoryIo {
        fn with(path: &str, bytes: &[u8]) -> Self {
            let io = Self::default();
            io.put(path, bytes);
            io
        }

        fn put(&self, path: &str, bytes: &[u8]) {
            let path = PathBuf::from(path);
            let mut tick = self.tick.lock().unwrap();
            *tick += 1;
            self.stamps.lock().unwrap().insert(path.clone(), *tick);
            self.files.lock().unwrap().insert(path, bytes.to_vec());
        }

        fn remove(&self, path: &str) {
            self.files.lock().unwrap().remove(Path::new(path));
        }

        fn bytes(&self, path: &str) -> Vec<u8> {
            self.files
                .lock()
                .unwrap()
                .get(Path::new(path))
                .cloned()
                .expect("the file was written")
        }
    }

    impl FileIo for MemoryIo {
        fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
            self.files
                .lock()
                .unwrap()
                .get(path)
                .cloned()
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
        }

        fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<()> {
            self.put(&path.to_string_lossy(), bytes);
            Ok(())
        }

        fn stat(&self, path: &Path) -> io::Result<FileWitness> {
            let files = self.files.lock().unwrap();
            let bytes = files
                .get(path)
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
            Ok(FileWitness {
                dev: 1,
                ino: 1,
                size: bytes.len() as u64,
                mtime_ns: *self.stamps.lock().unwrap().get(path).unwrap_or(&0),
            })
        }
    }

    fn ins(at: u32, text: &str) -> EditOp {
        EditOp::Insert {
            pos_u16: at,
            text: text.to_string(),
        }
    }

    fn del(at: u32, len: u32) -> EditOp {
        EditOp::Delete {
            pos_u16: at,
            len_u16: len,
        }
    }

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

    #[test]
    fn every_minted_id_carries_the_tag() {
        let io = MemoryIo::with("/a.txt", b"one");
        io.put("/b.txt", b"two");
        let mut store = FileStore::new();
        let a = store.open(&io, Path::new("/a.txt")).unwrap();
        let b = store.open(&io, Path::new("/b.txt")).unwrap();
        assert!(FileId::is_tagged(a.raw()));
        assert!(FileId::is_tagged(b.raw()));
        assert_ne!(a, b);
    }

    #[test]
    fn a_bom_and_crlf_round_trip_byte_identically() {
        let original: Vec<u8> = [UTF8_BOM, b"alpha\r\nbeta\r\n"].concat();
        let io = MemoryIo::with("/w.txt", &original);
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/w.txt")).unwrap();
        let file = store.file(id).unwrap();
        assert!(file.has_bom());
        assert_eq!(file.line_ending(), LineEnding::Crlf);
        assert_eq!(file.text(), "alpha\nbeta\n");
        store.save(&io, id).unwrap();
        assert_eq!(io.bytes("/w.txt"), original);
    }

    #[test]
    fn a_plain_lf_file_gains_no_bom_and_no_carriage_return() {
        let io = MemoryIo::with("/p.txt", b"alpha\nbeta\n");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/p.txt")).unwrap();
        assert!(!store.file(id).unwrap().has_bom());
        assert_eq!(store.file(id).unwrap().line_ending(), LineEnding::Lf);
        store.save(&io, id).unwrap();
        assert_eq!(io.bytes("/p.txt"), b"alpha\nbeta\n");
    }

    #[test]
    fn the_first_line_ending_decides_a_mixed_file() {
        let io = MemoryIo::with("/m.txt", b"a\nb\r\nc");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/m.txt")).unwrap();
        assert_eq!(store.file(id).unwrap().line_ending(), LineEnding::Lf);
    }

    #[test]
    fn invalid_utf8_is_refused() {
        let io = MemoryIo::with("/bad.bin", &[0x66, 0x6f, 0xFF, 0xFE, 0x6f]);
        let mut store = FileStore::new();
        assert_eq!(
            store.open(&io, Path::new("/bad.bin")),
            Err(OpenRefusal::NotUtf8)
        );
        assert!(store.files().is_empty());
    }

    #[test]
    fn a_file_past_the_limit_is_refused_with_the_limit() {
        let io = MemoryIo::with("/big.txt", &vec![b'x'; FILE_SIZE_LIMIT + 1]);
        let mut store = FileStore::new();
        assert_eq!(
            store.open(&io, Path::new("/big.txt")),
            Err(OpenRefusal::TooLarge {
                limit: FILE_SIZE_LIMIT
            })
        );
    }

    #[test]
    fn a_missing_file_refuses_with_the_io_kind() {
        let io = MemoryIo::default();
        let mut store = FileStore::new();
        assert_eq!(
            store.open(&io, Path::new("/nowhere.txt")),
            Err(OpenRefusal::Io(io::ErrorKind::NotFound))
        );
    }

    #[test]
    fn typing_dirties_and_undo_makes_it_clean_again() {
        let io = MemoryIo::with("/d.txt", b"hello");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/d.txt")).unwrap();
        assert!(!store.is_dirty(id));
        assert!(store.apply_ops(id, &[ins(5, " there")], 1_000));
        assert!(store.is_dirty(id));
        let outcome = store.undo(id).unwrap();
        assert!(outcome.applied);
        assert_eq!(store.text(id).unwrap(), "hello");
        assert!(!store.is_dirty(id), "back at the saved text is clean");
    }

    #[test]
    fn typing_and_deleting_the_same_text_returns_to_clean() {
        let io = MemoryIo::with("/d.txt", b"hello");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/d.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(5, "xyz")], 1));
        assert!(store.is_dirty(id));
        assert!(store.apply_ops(id, &[del(5, 3)], 2));
        assert!(!store.is_dirty(id));
    }

    #[test]
    fn the_last_edit_stamp_is_the_last_accepted_batch() {
        let io = MemoryIo::with("/s.txt", b"a");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/s.txt")).unwrap();
        assert_eq!(store.file(id).unwrap().last_edited_at(), 0);
        assert!(store.apply_ops(id, &[ins(1, "b")], 7_000));
        assert_eq!(store.file(id).unwrap().last_edited_at(), 7);
        // A refused batch stamps nothing.
        assert!(!store.apply_ops(id, &[ins(99, "c")], 9_000));
        assert_eq!(store.file(id).unwrap().last_edited_at(), 7);
    }

    #[test]
    fn a_chip_op_is_refused_whole() {
        let io = MemoryIo::with("/c.txt", b"abc");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/c.txt")).unwrap();
        let ops = vec![
            ins(3, "d"),
            EditOp::InsertChip {
                pos_u16: 0,
                chip: crate::sheet::ChipId::from_raw(1),
            },
        ];
        assert!(!store.apply_ops(id, &ops, 1));
        assert_eq!(store.text(id).unwrap(), "abc", "the batch moved nothing");
    }

    #[test]
    fn an_offset_inside_a_surrogate_pair_is_refused() {
        // U+1F600 is one scalar and two UTF-16 code units.
        let io = MemoryIo::with("/e.txt", "a\u{1F600}b".as_bytes());
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/e.txt")).unwrap();
        assert!(!store.apply_ops(id, &[ins(2, "x")], 1));
        assert!(store.apply_ops(id, &[ins(3, "x")], 1));
    }

    #[test]
    fn save_as_moves_the_identity() {
        let io = MemoryIo::with("/from.txt", b"body");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/from.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(4, "!")], 1));
        store.save_as(&io, id, Path::new("/to.txt")).unwrap();
        assert_eq!(store.file(id).unwrap().path(), Path::new("/to.txt"));
        assert_eq!(store.file(id).unwrap().name(), "to.txt");
        assert!(!store.is_dirty(id));
        assert_eq!(io.bytes("/to.txt"), b"body!");
        assert_eq!(io.bytes("/from.txt"), b"body", "the original is untouched");
    }

    #[test]
    fn check_sees_a_change_and_an_absence() {
        let io = MemoryIo::with("/x.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/x.txt")).unwrap();
        assert_eq!(store.check(&io, id), ExternalState::Unchanged);
        io.put("/x.txt", b"two");
        assert_eq!(store.check(&io, id), ExternalState::Changed);
        io.remove("/x.txt");
        assert_eq!(store.check(&io, id), ExternalState::Missing);
    }

    #[test]
    fn reload_clears_dirty_and_takes_the_disk_copy() {
        let io = MemoryIo::with("/r.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/r.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/r.txt", b"theirs");
        assert!(store.is_dirty(id));
        store.reload(&io, id).unwrap();
        assert_eq!(store.text(id).unwrap(), "theirs");
        assert!(!store.is_dirty(id));
        assert_eq!(store.check(&io, id), ExternalState::Unchanged);
    }

    #[test]
    fn a_conflict_blocks_save_until_it_is_resolved() {
        let io = MemoryIo::with("/k.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/k.txt", b"theirs");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::Changed);
        assert_eq!(store.save(&io, id), Err(SaveError::Conflict));
        assert_eq!(io.bytes("/k.txt"), b"theirs", "nothing was written");

        assert!(store.resolve_keep_mine(id));
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::None);
        store.save(&io, id).unwrap();
        assert_eq!(io.bytes("/k.txt"), b"one mine");
    }

    #[test]
    fn a_clean_file_never_enters_a_conflict() {
        let io = MemoryIo::with("/q.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/q.txt")).unwrap();
        io.put("/q.txt", b"two");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::None);
        store
            .save(&io, id)
            .expect("a clean file may still be saved");
    }

    #[test]
    fn take_theirs_resolves_by_reloading() {
        let io = MemoryIo::with("/t.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/t.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/t.txt", b"theirs");
        store.refresh_conflict(&io, id);
        store.reload(&io, id).unwrap();
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::None);
        store.save(&io, id).unwrap();
    }

    #[test]
    fn save_as_resolves_a_conflict_without_touching_the_original() {
        let io = MemoryIo::with("/o.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/o.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/o.txt", b"theirs");
        store.refresh_conflict(&io, id);
        store.save_as(&io, id, Path::new("/copy.txt")).unwrap();
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::None);
        assert_eq!(io.bytes("/o.txt"), b"theirs");
        assert_eq!(io.bytes("/copy.txt"), b"one mine");
    }

    #[test]
    fn close_drops_the_buffer_and_the_second_close_says_so() {
        let io = MemoryIo::with("/c2.txt", b"body");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/c2.txt")).unwrap();
        assert!(store.close(id));
        assert!(!store.close(id));
        assert!(store.files().is_empty());
    }

    #[test]
    fn opening_the_same_path_twice_hands_back_the_same_file() {
        let io = MemoryIo::with("/same.txt", b"body");
        let mut store = FileStore::new();
        let first = store.open(&io, Path::new("/same.txt")).unwrap();
        let second = store.open(&io, Path::new("/same.txt")).unwrap();
        assert_eq!(first, second);
        assert_eq!(store.files().len(), 1);
    }

    #[test]
    fn a_bookmark_is_carried_and_never_inspected() {
        let io = MemoryIo::with("/b.txt", b"body");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/b.txt")).unwrap();
        assert!(store.file(id).unwrap().bookmark().is_empty());
        assert!(store.set_bookmark(id, vec![0, 1, 2, 255]));
        assert_eq!(store.file(id).unwrap().bookmark(), &[0, 1, 2, 255]);
    }

    #[test]
    fn an_unknown_id_answers_without_panicking() {
        let io = MemoryIo::default();
        let mut store = FileStore::new();
        let ghost = FileId(FILE_ID_TAG | 99);
        assert!(!store.is_dirty(ghost));
        assert!(store.text(ghost).is_none());
        assert!(store.undo(ghost).is_none());
        assert!(!store.apply_ops(ghost, &[ins(0, "x")], 1));
        assert_eq!(store.save(&io, ghost), Err(SaveError::UnknownFile));
        assert_eq!(store.check(&io, ghost), ExternalState::Missing);
    }
}
