//! Open files: the content class that is a peer to pages.
//!
//! A file on disk is the artifact. A file is never a page, never a Tab,
//! never on the strip, never in the day roll and never synced. Sync
//! exclusion is structural rather than a rule:
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

use zeroize::Zeroizing;

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

/// The largest draft snapshot the drafts file will carry, in bytes.
///
/// A draft is an operation log, not the file's text, so it grows with
/// how much editing has happened rather than with how big the file is.
/// Four times [`FILE_SIZE_LIMIT`] is generous for any session a person
/// would recognise as one sitting, and it is what stops `drafts.sealed`
/// from growing without bound behind an app that is never quit.
///
/// **This bound can fire, and the file size limit does not prevent it.**
/// A 4 MiB file edited for long enough produces a snapshot larger than
/// 16 MiB, because every operation ever committed is in it until a
/// compaction, and files get no compaction ceremony. So the refusal is
/// a real path rather than a defensive constant: a draft over the bound
/// is left out of the drafts file, the file's record is written as
/// identity only, and the restore turns that into a
/// [`DroppedReason::DraftTooLarge`] notice naming the file. Losing one
/// oversized draft and saying so is the better answer than a sealed
/// file that grows until the disk complains.
pub const DRAFT_SNAPSHOT_LIMIT: usize = 4 * FILE_SIZE_LIMIT;

/// The UTF-8 byte order mark, stripped at open and put back at save for
/// a file that arrived with one.
const UTF8_BOM: &[u8] = &[0xEF, 0xBB, 0xBF];

/// UTF-16 and UTF-32 byte order marks. These identify non-UTF-8 encodings
/// before the content classifier can mistake their zero bytes for binary.
const NON_UTF8_BOMS: &[&[u8]] = &[
    &[0xFF, 0xFE, 0x00, 0x00],
    &[0x00, 0x00, 0xFE, 0xFF],
    &[0xFF, 0xFE],
    &[0xFE, 0xFF],
];

/// Why a file that was in the drafts file is not in the roster, or came
/// back with less than it was staged with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DroppedReason {
    /// Nothing is at the file's last known path any more. Only a clean
    /// file is dropped for this: a dirty one keeps its draft and stands
    /// in a [`FileConflict::Missing`] conflict instead.
    Missing,
    /// Something is at the path, but this build will not open it: not
    /// UTF-8, binary-like, past [`FILE_SIZE_LIMIT`], or a read the platform
    /// refused.
    Unreadable,
    /// The file's draft was larger than [`DRAFT_SNAPSHOT_LIMIT`] when
    /// the drafts file was written, so it was left out. The file itself
    /// came back, filled from disk and clean; what is gone is the
    /// unsaved editing that had been staged behind it.
    DraftTooLarge,
}

impl DroppedReason {
    /// The wire form of the enum, as the notices JSON spells it.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Missing => "missing",
            Self::Unreadable => "unreadable",
            Self::DraftTooLarge => "draftTooLarge",
        }
    }
}

/// One thing the shell has to tell the user about after a drafts save
/// or a drafts restore. Carries the file's name and path so a notice
/// can name it, and nothing else: this is not an error type and there
/// is nothing here to recover from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileNotice {
    /// The file's display name.
    pub name: String,
    /// The file's last known path.
    pub path: String,
    /// What happened to it.
    pub reason: DroppedReason,
}

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

    /// Resolve `path` to the real file it names, following every
    /// symlink on the way. Called once at open, so that a save lands on
    /// the file rather than on the link that pointed at it: a person
    /// who opens a dotfile that links into a repository expects the
    /// repository's copy to change and the link to stay a link.
    ///
    /// The default is the identity, which is what a headless test wants
    /// and what a platform with no such notion would answer.
    ///
    /// # Errors
    /// Whatever the platform said about the resolution.
    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        Ok(path.to_path_buf())
    }
}

/// Why an open, or a reload, refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenRefusal {
    /// The bytes are not UTF-8. A flat refusal: nothing opens read
    /// only, and nothing opens with replacement characters standing in
    /// for a person's text.
    NotUtf8,
    /// The bytes decode as UTF-8 with binary-like control content.
    Binary,
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
    /// The target path is already open under another id. Two buffers
    /// over one file race each other on save, which is the reason
    /// [`FileStore::open`] deduplicates by path, and a save as that
    /// adopted an open path would arrange exactly that.
    PathInUse,
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
    /// the buffer holds it. `None` only while this store has not seen
    /// the disk copy: a draft restored beside a file that changed under
    /// it, where the persisted dirty flag is the only answer there is.
    saved_text: Option<String>,
    /// Exact disk bytes learned while hydrating a restored dirty draft.
    /// They govern that draft until Save, Reload, or Take theirs because
    /// equal normalized text can still write different line endings.
    /// Zeroizing because they are the file's plaintext for as long as
    /// the draft stands.
    restored_disk_bytes: Option<Zeroizing<Vec<u8>>>,
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
    /// Whether the buffer was filled from a disk copy that had changed
    /// since the draft was written. A clean file reloads without
    /// asking, and this is what lets the shell post the notice for it
    /// afterwards. Sticky until [`FileStore::clear_reload_notice`].
    externally_reloaded: bool,
    /// Whether a keep mine is standing: the person has looked at a
    /// divergence and said their buffer wins. Set by
    /// [`FileStore::resolve_keep_mine`] and cleared by the save it
    /// licenses, so one choice buys one save.
    overwrite_next_save: bool,
    /// The Take theirs generation whose undo marker may currently govern
    /// dirty state. Cleared whenever a save establishes a newer baseline.
    active_take_theirs_generation: Option<i64>,
    /// The last file-local generation minted into undo metadata. It stays
    /// monotonic while this document and its historical markers live.
    next_take_theirs_generation: i64,
    /// Whether the active Take theirs structural action is currently
    /// undone. While it is, the pre-resolution draft generation remains
    /// dirty even when its normalized text equals `saved_text`.
    take_theirs_undone: bool,
    /// Whether the drafts file carried this record dirty but without a
    /// snapshot, which happens only when the snapshot was over
    /// [`DRAFT_SNAPSHOT_LIMIT`] at the save. Set at restore and read
    /// once by the hydration, which turns it into a notice.
    draft_dropped: bool,
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

    /// Whether the buffer was filled from a disk copy that had changed
    /// since the draft was written, which is the one reload a person
    /// gets without being asked. Stays true until the shell says it has
    /// posted the notice, so a roster read is a plain read and reading
    /// it twice loses nothing.
    #[must_use]
    pub fn externally_reloaded(&self) -> bool {
        self.externally_reloaded
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

    /// Recompute the dirty flag against the active saved baseline. A
    /// hydrated draft uses exact disk bytes; ordinary live editing uses
    /// normalized text so Redo can return to an adopted disk generation.
    /// A file whose baseline is unknown keeps its persisted flag.
    fn resettle_dirty(&mut self) {
        if self.take_theirs_undone {
            self.dirty = true;
        } else if let Some(saved) = &self.restored_disk_bytes {
            self.dirty = **saved != self.bytes_to_write();
        } else if let Some(saved) = &self.saved_text {
            self.dirty = *saved != text_of(&self.document);
        }
    }

    /// Adopt the text now on disk as both the buffer and the saved
    /// copy, discarding whatever the buffer held.
    ///
    /// Deliberately does not touch `restored_from_draft`: a reload
    /// clears it because the buffer is no longer a draft's, and the
    /// hydration keeps it because the tab still came back from one.
    /// The two callers say which they mean.
    fn adopt(&mut self, read: ReadFile) {
        self.document = document_holding(&read.text);
        self.saved_text = Some(read.text);
        self.restored_disk_bytes = None;
        self.witness = Some(read.witness);
        self.line_ending = read.line_ending;
        self.has_bom = read.has_bom;
        self.dirty = false;
        self.conflict = FileConflict::None;
        self.active_take_theirs_generation = None;
        self.next_take_theirs_generation = 0;
        self.take_theirs_undone = false;
    }

    /// Mint a marker that cannot alias another Take theirs item still in
    /// this document's undo history. Exhaustion is unreachable in
    /// practice; if reached, dropping history is safer than aliasing an
    /// old baseline marker.
    fn mint_take_theirs_generation(&mut self) -> i64 {
        if self.next_take_theirs_generation == i64::MAX {
            self.document.forget_undo();
            self.next_take_theirs_generation = 0;
            self.active_take_theirs_generation = None;
            self.take_theirs_undone = false;
        }
        self.next_take_theirs_generation += 1;
        self.next_take_theirs_generation
    }

    /// This file as a notice the shell can put in front of a person.
    fn notice(&self, reason: DroppedReason) -> FileNotice {
        FileNotice {
            name: self.name(),
            path: self.path.to_string_lossy().into_owned(),
            reason,
        }
    }
}

/// Every open file. No clock, no TTL, no place on the strip: none of
/// the three means anything to a file.
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
    /// [`OpenRefusal::Binary`] for content that looks binary,
    /// [`OpenRefusal::TooLarge`] above [`FILE_SIZE_LIMIT`], and
    /// [`OpenRefusal::Io`] for a read the platform refused.
    pub fn open(&mut self, io: &dyn FileIo, path: &Path) -> Result<FileId, OpenRefusal> {
        // Resolved once, here, and every later stat, read and write
        // uses the answer. Two files that reach the same bytes through
        // different links are one file, so the deduplication below is
        // asked after the resolution rather than before it, and a save
        // lands on the file rather than replacing the link with a copy
        // of it. A path that will not resolve is refused before
        // anything else looks at it.
        let path = &io
            .canonicalize(path)
            .map_err(|e| OpenRefusal::Io(e.kind()))?;
        if let Some(open) = self.files.iter().find(|file| file.path == *path) {
            return Ok(open.id);
        }
        let read = read_file(io, path)?;
        self.next_id += 1;
        let id = FileId(FILE_ID_TAG | self.next_id);
        self.files.push(OpenFile {
            id,
            path: path.clone(),
            document: document_holding(&read.text),
            saved_text: Some(read.text),
            restored_disk_bytes: None,
            witness: Some(read.witness),
            line_ending: read.line_ending,
            has_bom: read.has_bom,
            dirty: false,
            conflict: FileConflict::None,
            last_edited_ms: 0,
            restored_from_draft: false,
            externally_reloaded: false,
            overwrite_next_save: false,
            active_take_theirs_generation: None,
            next_take_theirs_generation: 0,
            take_theirs_undone: false,
            draft_dropped: false,
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
        // The transaction closes either way: whatever did land is a
        // change, and leaving it open would fold it into the next one.
        if new_step {
            file.document.commit_as_new_step(None);
        } else {
            file.document.commit_file_edit(None);
        }
        // The stamp is only taken for a batch that applied whole. A
        // caller told its batch was refused must not then find the file
        // claiming an edit at that moment.
        if clean {
            file.last_edited_ms = wall_ms;
        }
        // A local commit drops the redo stack, so the Take theirs
        // generation an undone marker speaks for stops being reachable:
        // no Redo can return to the disk generation, and no Undo can
        // explain why the file still reads unsaved. ADR-0031 refuses the
        // same orphaned marker at the relaunch boundary, and the live
        // session owes the person the same honesty. The baseline
        // comparison below then answers on its own.
        if file.take_theirs_undone && !file.document.can_redo() {
            file.take_theirs_undone = false;
            file.active_take_theirs_generation = None;
        }
        file.resettle_dirty();
        clean
    }

    /// Whether the file has a step waiting to be taken back. False for
    /// an unknown file, the same answer
    /// [`crate::store::SheetStore::can_undo`] gives for an unknown
    /// page: this is what a menu item's enabled state reads, and a
    /// question that cannot be answered is not a step that exists.
    #[must_use]
    pub fn can_undo(&self, id: FileId) -> bool {
        self.file(id).is_some_and(|file| file.document.can_undo())
    }

    /// Whether the file has a step waiting to be restored.
    #[must_use]
    pub fn can_redo(&self, id: FileId) -> bool {
        self.file(id).is_some_and(|file| file.document.can_redo())
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
            if let Some(generation) = file.document.popped_take_theirs()
                && file.active_take_theirs_generation == Some(generation)
            {
                // Historical markers survive save and Redo, but only the
                // marker bound to the current saved baseline may govern
                // generation-level dirtiness.
                file.take_theirs_undone = back;
            }
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
    /// A target another file is already open on is refused rather than
    /// adopted. [`FileStore::open`] deduplicates by path because two
    /// buffers over one file race each other on save, and a save as is
    /// not entitled to arrange what an open is not allowed to. The
    /// shell's answer is to tell the person the file is already open,
    /// not to close their other tab for them.
    ///
    /// # Errors
    ///
    /// [`SaveError::PathInUse`] for a target another open file holds,
    /// [`SaveError::UnknownFile`] for an id nothing is open under, and
    /// [`SaveError::Io`] for a write the platform refused.
    pub fn save_as(&mut self, io: &dyn FileIo, id: FileId, path: &Path) -> Result<(), SaveError> {
        // Resolved the way an open resolves, so the comparison below
        // and the path adopted afterwards are in the same terms as
        // every other path in the store. The target need not exist yet,
        // so it is the directory that gets resolved and the name that
        // gets joined back on.
        let path = &resolve_target(io, path);
        if self.files.iter().any(|f| f.id != id && f.path == *path) {
            return Err(SaveError::PathInUse);
        }
        let file = self.file_mut(id).ok_or(SaveError::UnknownFile)?;
        write_and_settle(io, file, path)?;
        file.path = path.clone();
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
    /// Returns the state it found, which is the true answer either way:
    /// a caller that wants to know whether the file moved is told, even
    /// while a keep mine stands.
    pub fn refresh_conflict(&mut self, io: &dyn FileIo, id: FileId) -> ExternalState {
        let state = self.check(io, id);
        if let Some(file) = self.file_mut(id) {
            file.conflict = match (state, file.dirty) {
                (ExternalState::Unchanged, _) | (_, false) => FileConflict::None,
                // A person who chose keep mine has answered this
                // question already. Without this arm the shell's own
                // documented flow defeats the choice: it checks before
                // every save, the check re-enters the conflict, and the
                // save it was checking for is refused. Keep mine would
                // be a button that does nothing.
                _ if file.overwrite_next_save => FileConflict::None,
                (ExternalState::Changed, true) => FileConflict::Changed,
                (ExternalState::Missing, true) => FileConflict::Missing,
            };
        }
        state
    }

    /// Keep mine: the first of the three conflict resolutions. The
    /// buffer stands and the next save overwrites whatever is on disk.
    /// Take theirs is [`FileStore::take_theirs`] and the third is
    /// [`FileStore::save_as`].
    ///
    /// Two things happen, and both are needed. The witness is refreshed
    /// from the disk copy the person has just decided to overwrite, so
    /// it describes what is actually there rather than a generation
    /// that is gone. And a consent flag is set that survives until the
    /// save it was given for, because a file that is missing has no
    /// witness to take and because the disk copy may change again
    /// between the choice and the keystroke. Only the save clears it,
    /// so exactly one save is licensed by exactly one choice.
    pub fn resolve_keep_mine(&mut self, io: &dyn FileIo, id: FileId) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        file.conflict = FileConflict::None;
        file.overwrite_next_save = true;
        file.witness = io.stat(&file.path).ok();
        true
    }

    /// Re-read the file from disk, discarding whatever the buffer held
    /// and its undo history. This is the non-interactive reload primitive
    /// used when a clean file changes; an explicit conflict resolution
    /// uses [`FileStore::take_theirs`] so the discarded draft can be
    /// recovered with Undo.
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
            // The buffer is the file's own text now, not a draft's, and
            // the reload notice it may have been carrying is answered
            // by the reload itself.
            file.restored_from_draft = false;
            file.externally_reloaded = false;
            file.overwrite_next_save = false;
        }
        Ok(())
    }

    /// Adopt the disk copy as an explicit, undoable conflict resolution.
    /// The replacement is one structural edit step. Its disk text becomes
    /// the saved baseline immediately, so Undo restores the former draft
    /// as dirty and Redo returns to the adopted disk text as clean.
    ///
    /// The witness, line ending, and BOM all describe the adopted disk
    /// generation on both sides of the undo step. A refused read leaves
    /// the buffer and its history exactly as they were.
    ///
    /// # Errors
    ///
    /// The same refusals [`FileStore::open`] gives.
    pub fn take_theirs(&mut self, io: &dyn FileIo, id: FileId) -> Result<(), OpenRefusal> {
        let path = self
            .file(id)
            .ok_or(OpenRefusal::Io(io::ErrorKind::NotFound))?
            .path
            .clone();
        let read = read_file(io, &path)?;
        if let Some(file) = self.file_mut(id) {
            let generation = file.mint_take_theirs_generation();
            let len = file.document.utf16_len();
            // An empty buffer over an empty disk copy writes no
            // operations, so the undo manager gets no item and Undo
            // stays unavailable. That is the honest answer: an enabled
            // Undo that changes nothing when pressed is worse than a
            // step the person is told does not exist, and there is no
            // former generation here that any press could show them.
            file.document
                .delete(0, len)
                .expect("the document's full UTF-16 range is valid");
            file.document
                .insert(0, &read.text)
                .expect("zero is a valid insertion point");
            let stepped = file.document.commit_take_theirs_step(generation);
            file.saved_text = Some(read.text);
            file.restored_disk_bytes = None;
            file.witness = Some(read.witness);
            file.line_ending = read.line_ending;
            file.has_bom = read.has_bom;
            file.dirty = false;
            file.conflict = FileConflict::None;
            // Armed only behind an undo item: a generation no Undo can
            // reach is the orphaned marker ADR-0031 refuses elsewhere.
            file.active_take_theirs_generation = stepped.then_some(generation);
            file.take_theirs_undone = false;
            file.restored_from_draft = false;
            file.externally_reloaded = false;
            file.overwrite_next_save = false;
        }
        Ok(())
    }

    /// Say that the shell has posted the reload notice for this file,
    /// so the roster stops reporting one. The roster itself is a plain
    /// read: nothing there clears on being looked at, because a shell
    /// redraws its strip more than once and a notice that vanished on
    /// the first read would be a notice nobody ever saw.
    pub fn clear_reload_notice(&mut self, id: FileId) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        file.externally_reloaded = false;
        true
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
        // The counter is deliberately not reset. Only launch calls this
        // today, but a restore in a live session would otherwise hand
        // out an id the shell is still holding for a file it closed,
        // and a stale id that resolves to the wrong buffer is the one
        // failure this module's tagging exists to prevent.
    }

    /// Put back one file from a drafts record. Everything a restore
    /// knows arrives here at once, because a half built buffer has no
    /// valid state to sit in.
    ///
    /// `snapshot` is the buffer's Loro snapshot for a dirty file and
    /// `None` for a clean one, whose text is on disk. A record that is
    /// dirty and carries no snapshot is the one case that is neither:
    /// the draft was over [`DRAFT_SNAPSHOT_LIMIT`] when the file was
    /// written, so it was left out. That is remembered here and turned
    /// into a notice by [`FileStore::hydrate_restored`].
    ///
    /// The buffer this leaves is not yet ready to draw: nothing has
    /// looked at the disk. [`FileStore::hydrate_restored`] is the
    /// second half of a restore and every caller owes it.
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
            restored_disk_bytes: None,
            witness,
            line_ending,
            has_bom,
            dirty,
            conflict: FileConflict::None,
            last_edited_ms,
            restored_from_draft: true,
            externally_reloaded: false,
            overwrite_next_save: false,
            active_take_theirs_generation: None,
            next_take_theirs_generation: 0,
            // Undo history does not cross launch, so no restored boolean
            // can stand in for the absent Take theirs generation marker.
            // Hydration derives dirtiness from the draft and disk texts.
            take_theirs_undone: false,
            draft_dropped: dirty && snapshot.is_none(),
            bookmark,
        });
        Ok(id)
    }

    /// The second half of a drafts restore: look at the disk, and leave
    /// every restored file in a state the shell can draw without asking
    /// anything further.
    ///
    /// One record at a time, and never a whole-restore failure. A file
    /// that cannot be reopened is dropped from the roster or left
    /// standing in a conflict, and either way it leaves a
    /// [`FileNotice`]; the files beside it come back regardless. A
    /// launch that loses every open tab because one of them was on an
    /// unmounted volume would be the worse answer by a distance.
    ///
    /// The six cases, which are the whole of this function:
    ///
    /// | record | on disk | outcome |
    /// | --- | --- | --- |
    /// | clean | unchanged | filled from disk, clean |
    /// | clean | changed | filled from disk, clean, reload notice set |
    /// | clean | missing or unreadable | dropped, notice |
    /// | dirty | unchanged | draft kept, saved text learned from disk |
    /// | dirty | changed | draft kept, [`FileConflict::Changed`] |
    /// | dirty | missing | draft kept, [`FileConflict::Missing`] |
    ///
    /// A dirty record whose draft was over
    /// [`DRAFT_SNAPSHOT_LIMIT`] has no draft to keep, so it takes the
    /// clean path and leaves a [`DroppedReason::DraftTooLarge`] notice.
    ///
    /// The dirty and unchanged case is the one worth reading twice. The
    /// draft's own text stands, and the disk copy becomes the saved
    /// text, so dirtiness is computed truthfully from here on and
    /// stepping the draft back to what the file holds reads as clean.
    /// The persisted last edit stamp survives, because the header of a
    /// restored dirty file states the draft's age and re-stamping it at
    /// launch would make every draft look new.
    pub fn hydrate_restored(&mut self, io: &dyn FileIo) -> Vec<FileNotice> {
        let mut notices = Vec::new();
        let mut kept = Vec::with_capacity(self.files.len());
        for mut file in std::mem::take(&mut self.files) {
            if !file.restored_from_draft {
                kept.push(file);
                continue;
            }
            let staged = file.dirty && !file.draft_dropped;
            // A draft that was left out of the drafts file is not a
            // draft any more. The notice for it waits until the file is
            // known to be coming back: a file that is also gone from
            // disk gets one notice about that and not two about one
            // thing, since "your draft was too large" is no use to
            // somebody whose file is not there either.
            let dropped_draft = file.draft_dropped;
            if dropped_draft {
                file.dirty = false;
                file.take_theirs_undone = false;
                file.draft_dropped = false;
            }
            match read_file(io, &file.path) {
                Ok(read) => {
                    if dropped_draft {
                        notices.push(file.notice(DroppedReason::DraftTooLarge));
                    }
                    let unchanged = file.witness == Some(read.witness);
                    if !staged {
                        file.adopt(read);
                        file.externally_reloaded = !unchanged;
                    } else if unchanged {
                        // The draft stands. What it gains is the exact
                        // disk output to be measured against.
                        file.line_ending = read.line_ending;
                        file.has_bom = read.has_bom;
                        file.witness = Some(read.witness);
                        file.saved_text = Some(read.text);
                        file.restored_disk_bytes = Some(read.bytes);
                        file.conflict = FileConflict::None;
                        file.resettle_dirty();
                    } else {
                        // Two texts and no way to reconcile them. The
                        // draft stands and the person chooses.
                        file.conflict = FileConflict::Changed;
                        file.saved_text = None;
                        file.restored_disk_bytes = None;
                    }
                    kept.push(file);
                }
                Err(OpenRefusal::Io(io::ErrorKind::NotFound)) => {
                    if staged {
                        file.conflict = FileConflict::Missing;
                        file.witness = None;
                        kept.push(file);
                    } else {
                        notices.push(file.notice(DroppedReason::Missing));
                    }
                }
                Err(_) => {
                    if staged {
                        // Something is there and this build will not
                        // read it, so take theirs is not on offer. The
                        // conflict is what refuses the save until the
                        // person picks keep mine or save as.
                        file.conflict = FileConflict::Changed;
                        file.saved_text = None;
                        file.restored_disk_bytes = None;
                        kept.push(file);
                    } else {
                        notices.push(file.notice(DroppedReason::Unreadable));
                    }
                }
            }
        }
        self.files = kept;
        notices
    }

    /// What the drafts record for this file carries in its snapshot
    /// slot. Exported once, because a snapshot is the largest thing
    /// this module allocates and a second copy would have to be wiped.
    pub(crate) fn draft_body(&self, id: FileId) -> DraftBody {
        let Some(file) = self.file(id) else {
            return DraftBody::None;
        };
        if !file.dirty {
            return DraftBody::None;
        }
        let snapshot = file.document.export_snapshot();
        if snapshot.len() > DRAFT_SNAPSHOT_LIMIT {
            return DraftBody::Oversized;
        }
        DraftBody::Snapshot(snapshot)
    }

    /// The notice for a draft the drafts file would not carry.
    pub(crate) fn oversize_notice(&self, id: FileId) -> Option<FileNotice> {
        Some(self.file(id)?.notice(DroppedReason::DraftTooLarge))
    }
}

/// What a file contributes to its drafts record's snapshot slot.
pub(crate) enum DraftBody {
    /// A clean file: identity only, since its text is on disk.
    None,
    /// A dirty file's buffer.
    Snapshot(Zeroizing<Vec<u8>>),
    /// A dirty file whose buffer is over [`DRAFT_SNAPSHOT_LIMIT`]. The
    /// record is written without it, and the restore says so.
    Oversized,
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

/// What one read of a file settled: the normalised text, the exact bytes,
/// and everything the buffer has to remember to write them back.
struct ReadFile {
    text: String,
    /// Zeroizing because they are plaintext and outlive the read when a
    /// hydration keeps them as the draft's baseline.
    bytes: Zeroizing<Vec<u8>>,
    witness: FileWitness,
    line_ending: LineEnding,
    has_bom: bool,
}

/// Read, refuse, strip and normalise. The one place bytes become a
/// buffer.
fn read_file(io: &dyn FileIo, path: &Path) -> Result<ReadFile, OpenRefusal> {
    for _ in 0..READ_ATTEMPTS {
        match read_once(io, path)? {
            Some(read) => return Ok(read),
            // Somebody wrote the file while this read was in progress,
            // so the bytes and the witness describe different
            // generations. Read it again rather than keep a pair that
            // does not go together.
            None => continue,
        }
    }
    // Something is rewriting the file faster than it can be read. The
    // one thing that must not happen is opening it anyway: the witness
    // would describe a generation the buffer does not hold, `check`
    // would answer `Unchanged` forever, and the next save would
    // overwrite the other writer without a word.
    Err(OpenRefusal::Io(io::ErrorKind::Interrupted))
}

/// How many times a read is retried against a file that is being
/// written underneath it before the open is refused.
const READ_ATTEMPTS: usize = 3;

/// One read bracketed by two stats. `None` means the two stats
/// disagreed, so the bytes and the witness are from different
/// generations and the pair must be thrown away.
///
/// The stat before matters as much as the stat after: it is what
/// answers a path that is not a regular file before any byte of it is
/// read, and on a real filesystem a read of a pipe or a device is not
/// something to start and then reconsider.
fn read_once(io: &dyn FileIo, path: &Path) -> Result<Option<ReadFile>, OpenRefusal> {
    let before = io.stat(path).map_err(|e| OpenRefusal::Io(e.kind()))?;
    let bytes = Zeroizing::new(io.read(path).map_err(|e| OpenRefusal::Io(e.kind()))?);
    let after = io.stat(path).map_err(|e| OpenRefusal::Io(e.kind()))?;
    if before != after {
        return Ok(None);
    }
    // The size is answered before the UTF-8 decode, so an enormous file
    // is refused for its size rather than after a decode of it.
    if bytes.len() > FILE_SIZE_LIMIT {
        return Err(OpenRefusal::TooLarge {
            limit: FILE_SIZE_LIMIT,
        });
    }
    if NON_UTF8_BOMS.iter().any(|bom| bytes.starts_with(bom)) {
        return Err(OpenRefusal::NotUtf8);
    }
    let has_bom = bytes.starts_with(UTF8_BOM);
    let body = if has_bom {
        &bytes[UTF8_BOM.len()..]
    } else {
        &bytes[..]
    };
    let text = std::str::from_utf8(body).map_err(|_| OpenRefusal::NotUtf8)?;
    if looks_binary(text) {
        return Err(OpenRefusal::Binary);
    }
    let line_ending = LineEnding::detect(text);
    let text = text.replace("\r\n", "\n");
    Ok(Some(ReadFile {
        text,
        bytes,
        witness: after,
        line_ending,
        has_bom,
    }))
}

/// Whether valid UTF-8 is conservatively binary-like.
///
/// Any NUL is binary. Otherwise, tab, line feed, carriage return and form
/// feed are accepted; other Unicode control scalars cause refusal only when
/// there are at least two and they exceed ten percent of all scalars.
fn looks_binary(text: &str) -> bool {
    let mut scalar_count = 0;
    let mut disallowed_controls = 0;

    for scalar in text.chars() {
        scalar_count += 1;
        if scalar == '\0' {
            return true;
        }
        if scalar.is_control() && !matches!(scalar, '\t' | '\n' | '\r' | '\u{000C}') {
            disallowed_controls += 1;
        }
    }

    disallowed_controls >= 2 && disallowed_controls * 10 > scalar_count
}

/// A save target, in the same terms as every path the store holds.
///
/// A file that does not exist yet cannot be resolved, so its directory
/// is resolved instead and the name joined back on. Anything that will
/// not resolve at all is used as it was given: a save that is going to
/// fail should fail on the write, where the reason is the platform's,
/// rather than here.
fn resolve_target(io: &dyn FileIo, path: &Path) -> PathBuf {
    if let Ok(resolved) = io.canonicalize(path) {
        return resolved;
    }
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => io
            .canonicalize(parent)
            .map_or_else(|_| path.to_path_buf(), |dir| dir.join(name)),
        _ => path.to_path_buf(),
    }
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
    file.restored_disk_bytes = None;
    file.dirty = false;
    file.conflict = FileConflict::None;
    file.restored_from_draft = false;
    file.active_take_theirs_generation = None;
    file.take_theirs_undone = false;
    // The consent was for this save. The next divergence asks again.
    file.overwrite_next_save = false;
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
    use std::cell::Cell;
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
        /// Link name to target, resolved by `canonicalize` the way the
        /// real implementation resolves a symlink.
        links: Mutex<HashMap<PathBuf, PathBuf>>,
    }

    impl MemoryIo {
        fn with(path: &str, bytes: &[u8]) -> Self {
            let io = Self::default();
            io.put(path, bytes);
            io
        }

        fn link(&self, from: &str, to: &str) {
            self.links
                .lock()
                .unwrap()
                .insert(PathBuf::from(from), PathBuf::from(to));
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

        fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
            Ok(self
                .links
                .lock()
                .unwrap()
                .get(path)
                .cloned()
                .unwrap_or_else(|| path.to_path_buf()))
        }
    }

    /// A filesystem whose file is rewritten underneath every read: the
    /// window between the read and the stat, made reliable. `shifts` is
    /// how many times it moves before it settles.
    struct ShiftingIo {
        settled: Vec<u8>,
        moving: Vec<u8>,
        left: Mutex<usize>,
        generation: Mutex<i128>,
    }

    impl ShiftingIo {
        fn new(moving: &[u8], shifts: usize) -> Self {
            Self {
                settled: b"settled".to_vec(),
                moving: moving.to_vec(),
                left: Mutex::new(shifts),
                generation: Mutex::new(0),
            }
        }
    }

    impl FileIo for ShiftingIo {
        fn read(&self, _path: &Path) -> io::Result<Vec<u8>> {
            let mut left = self.left.lock().unwrap();
            if *left == 0 {
                return Ok(self.settled.clone());
            }
            // The write lands here, between the caller's two stats.
            *left -= 1;
            *self.generation.lock().unwrap() += 1;
            Ok(self.moving.clone())
        }

        fn write_atomic(&self, _path: &Path, _bytes: &[u8]) -> io::Result<()> {
            Ok(())
        }

        fn stat(&self, _path: &Path) -> io::Result<FileWitness> {
            Ok(FileWitness {
                dev: 1,
                ino: 1,
                size: 0,
                mtime_ns: *self.generation.lock().unwrap(),
            })
        }
    }

    /// A path the platform reports as non-regular. Its read records whether
    /// the core incorrectly continued after the rejecting stat.
    #[derive(Default)]
    struct NonRegularIo {
        read_called: Cell<bool>,
    }

    impl FileIo for NonRegularIo {
        fn read(&self, _path: &Path) -> io::Result<Vec<u8>> {
            self.read_called.set(true);
            Ok(Vec::new())
        }

        fn write_atomic(&self, _path: &Path, _bytes: &[u8]) -> io::Result<()> {
            Ok(())
        }

        fn stat(&self, _path: &Path) -> io::Result<FileWitness> {
            Err(io::Error::from(io::ErrorKind::InvalidInput))
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
    fn valid_utf8_with_a_nul_is_refused_as_binary() {
        let io = MemoryIo::with("/nul.txt", b"alpha\0beta");
        let mut store = FileStore::new();
        assert_eq!(
            store.open(&io, Path::new("/nul.txt")),
            Err(OpenRefusal::Binary)
        );
        assert!(store.files().is_empty());
    }

    #[test]
    fn invalid_utf8_with_a_known_binary_signature_remains_not_utf8() {
        for (path, bytes) in [
            ("/image.png", b"\x89PNG\r\n\x1A\n\xFF".as_slice()),
            ("/image.jpg", b"\xFF\xD8\xFF".as_slice()),
        ] {
            let io = MemoryIo::with(path, bytes);
            let mut store = FileStore::new();
            assert_eq!(store.open(&io, Path::new(path)), Err(OpenRefusal::NotUtf8));
        }
    }

    #[test]
    fn valid_utf8_signature_text_is_not_rejected_for_its_prefix() {
        for (path, bytes) in [
            ("/paper.pdf", b"%PDF-1.7\n".as_slice()),
            ("/image.gif", b"GIF89a ordinary text\n".as_slice()),
            ("/data.plist", b"bplist00 ordinary text\n".as_slice()),
        ] {
            let io = MemoryIo::with(path, bytes);
            let mut store = FileStore::new();
            assert!(store.open(&io, Path::new(path)).is_ok());
        }
    }

    #[test]
    fn exactly_ten_percent_disallowed_controls_is_accepted() {
        let io = MemoryIo::with("/boundary.txt", b"\x01\x02abcdefghijklmnopqr");
        let mut store = FileStore::new();
        assert!(store.open(&io, Path::new("/boundary.txt")).is_ok());
    }

    #[test]
    fn just_over_ten_percent_disallowed_controls_is_refused_as_binary() {
        let io = MemoryIo::with("/boundary.txt", b"\x01\x02abcdefghijklmnopq");
        let mut store = FileStore::new();
        assert_eq!(
            store.open(&io, Path::new("/boundary.txt")),
            Err(OpenRefusal::Binary)
        );
        assert!(store.files().is_empty());
    }

    #[test]
    fn one_disallowed_control_is_accepted_even_above_ten_percent() {
        let io = MemoryIo::with("/one-control.txt", b"\x01a");
        let mut store = FileStore::new();
        assert!(store.open(&io, Path::new("/one-control.txt")).is_ok());
    }

    #[test]
    fn ansi_control_rich_utf8_is_an_acknowledged_false_rejection() {
        let io = MemoryIo::with("/terminal.txt", b"\x1B[31mred\x1B[0m");
        let mut store = FileStore::new();
        assert_eq!(
            store.open(&io, Path::new("/terminal.txt")),
            Err(OpenRefusal::Binary)
        );
    }

    #[test]
    fn normal_text_controls_are_accepted() {
        let io = MemoryIo::with("/controls.txt", b"\t\n\r\x0C");
        let mut store = FileStore::new();
        assert!(store.open(&io, Path::new("/controls.txt")).is_ok());
    }

    #[test]
    fn utf16_and_utf32_boms_remain_not_utf8() {
        for (path, bytes) in [
            ("/utf16le.txt", &[0xFF, 0xFE, b'a', 0x00][..]),
            ("/utf16be.txt", &[0xFE, 0xFF, 0x00, b'a'][..]),
            ("/utf32le.txt", &[0xFF, 0xFE, 0x00, 0x00][..]),
            ("/utf32be.txt", &[0x00, 0x00, 0xFE, 0xFF][..]),
        ] {
            let io = MemoryIo::with(path, bytes);
            let mut store = FileStore::new();
            assert_eq!(store.open(&io, Path::new(path)), Err(OpenRefusal::NotUtf8));
        }
    }

    #[test]
    fn text_with_an_unknown_extension_is_accepted() {
        let io = MemoryIo::with("/notes.unknown", b"ordinary UTF-8 text\n");
        let mut store = FileStore::new();
        assert!(store.open(&io, Path::new("/notes.unknown")).is_ok());
    }

    #[test]
    fn extensionless_text_is_accepted() {
        let io = MemoryIo::with("/Makefile", b"ordinary UTF-8 text\n");
        let mut store = FileStore::new();
        assert!(store.open(&io, Path::new("/Makefile")).is_ok());
    }

    #[test]
    fn a_file_exactly_at_the_limit_is_accepted() {
        let io = MemoryIo::with("/limit.txt", &vec![b'x'; FILE_SIZE_LIMIT]);
        let mut store = FileStore::new();
        assert!(store.open(&io, Path::new("/limit.txt")).is_ok());
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
    fn a_non_regular_path_is_refused_before_reading() {
        let io = NonRegularIo::default();
        let mut store = FileStore::new();
        assert_eq!(
            store.open(&io, Path::new("/named-pipe")),
            Err(OpenRefusal::Io(io::ErrorKind::InvalidInput))
        );
        assert!(!io.read_called.get());
        assert!(store.files().is_empty());
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
    fn the_stack_answers_for_a_file_the_way_it_does_for_a_page() {
        let io = MemoryIo::with("/u.txt", b"hello");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/u.txt")).unwrap();
        // The insert that filled the buffer is the file arriving, not a
        // step anyone may take back.
        assert!(!store.can_undo(id));
        assert!(!store.can_redo(id));

        assert!(store.apply_ops(id, &[ins(5, " there")], 1_000));
        assert!(store.can_undo(id));
        assert!(!store.can_redo(id));

        assert!(store.undo(id).unwrap().applied);
        assert!(!store.can_undo(id), "that was the only step");
        assert!(store.can_redo(id));

        assert!(store.redo(id).unwrap().applied);
        assert!(store.can_undo(id));
        assert!(!store.can_redo(id));

        // An id nothing is open under answers no, not a panic.
        assert!(!store.can_undo(FileId(FILE_ID_TAG | 404)));
        assert!(!store.can_redo(FileId(FILE_ID_TAG | 404)));
        assert!(!store.can_undo(FileId(1)));
        assert!(!store.can_redo(FileId(1)));
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
        assert!(!store.can_undo(id), "an automatic reload is not an edit");
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

        assert!(store.resolve_keep_mine(&io, id));
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
    fn take_theirs_is_one_undoable_structural_change() {
        let io = MemoryIo::with("/t.txt", b"one\n");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/t.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 7_000));
        io.put("/t.txt", &[UTF8_BOM, b"theirs\r\n"].concat());
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);

        store.take_theirs(&io, id).unwrap();
        let file = store.file(id).unwrap();
        assert_eq!(file.text(), "theirs\n");
        assert!(!file.is_dirty());
        assert_eq!(file.conflict(), FileConflict::None);
        assert_eq!(file.line_ending(), LineEnding::Crlf);
        assert!(file.has_bom());
        assert_eq!(file.last_edited_at(), 7);
        assert_eq!(store.check(&io, id), ExternalState::Unchanged);
        assert!(store.can_undo(id));

        assert!(store.undo(id).unwrap().applied);
        let file = store.file(id).unwrap();
        assert_eq!(file.text(), "one mine\n", "Undo restores the draft");
        assert!(file.is_dirty(), "the draft differs from the disk baseline");
        assert_eq!(file.conflict(), FileConflict::None);
        assert_eq!(file.line_ending(), LineEnding::Crlf);
        assert!(file.has_bom());
        assert_eq!(store.check(&io, id), ExternalState::Unchanged);
        assert_eq!(
            file.bytes_to_write(),
            [UTF8_BOM, b"one mine\r\n"].concat(),
            "an undone draft uses the adopted disk encoding"
        );

        assert!(store.redo(id).unwrap().applied);
        let file = store.file(id).unwrap();
        assert_eq!(file.text(), "theirs\n");
        assert!(!file.is_dirty());
        assert_eq!(file.conflict(), FileConflict::None);
        assert_eq!(store.check(&io, id), ExternalState::Unchanged);
    }

    #[test]
    fn redo_take_theirs_settles_a_mixed_line_ending_generation_clean() {
        let io = MemoryIo::with("/mixed-take.txt", b"mine\n");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/mixed-take.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(4, " draft")], 1_000));
        io.put("/mixed-take.txt", b"theirs\nsecond\r\n");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);

        store.take_theirs(&io, id).unwrap();
        assert_eq!(store.text(id).unwrap(), "theirs\nsecond\n");
        assert!(!store.is_dirty(id));
        assert!(store.undo(id).unwrap().applied);
        assert!(store.is_dirty(id));
        assert!(store.redo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "theirs\nsecond\n");
        assert!(
            !store.is_dirty(id),
            "Redo returns to the adopted disk generation even when its endings were mixed"
        );
    }

    #[test]
    fn equal_normalized_text_still_records_take_theirs_as_a_structural_step() {
        let io = MemoryIo::with("/equal.txt", b"old\n");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/equal.txt")).unwrap();
        assert!(store.apply_ops(id, &[del(0, 3), ins(0, "same")], 4_000));
        assert_eq!(store.text(id).unwrap(), "same\n");
        assert!(store.is_dirty(id));

        io.put("/equal.txt", &[UTF8_BOM, b"same\r\n"].concat());
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        store.take_theirs(&io, id).unwrap();
        let file = store.file(id).unwrap();
        assert_eq!(file.text(), "same\n");
        assert!(!file.is_dirty());
        assert_eq!(file.line_ending(), LineEnding::Crlf);
        assert!(file.has_bom());
        assert_eq!(store.check(&io, id), ExternalState::Unchanged);

        assert!(store.undo(id).unwrap().applied);
        let file = store.file(id).unwrap();
        assert_eq!(file.text(), "same\n");
        assert!(
            file.is_dirty(),
            "Undo restores the former draft generation even when text is equal"
        );
        assert_eq!(file.conflict(), FileConflict::None);
        assert_eq!(file.line_ending(), LineEnding::Crlf);
        assert!(file.has_bom());
        assert_eq!(store.check(&io, id), ExternalState::Unchanged);

        assert!(store.redo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "same\n");
        assert!(!store.is_dirty(id));
        assert_eq!(store.check(&io, id), ExternalState::Unchanged);

        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "same\n");
        assert!(
            store.is_dirty(id),
            "the structural marker survives a Redo/Undo cycle"
        );

        // Typing branches from the pre-resolution draft and invalidates
        // Redo of Take theirs, which retires the generation marker with
        // it. Undoing that typing reaches the saved output again, and
        // with nothing left to steer by the file reads saved.
        assert!(store.apply_ops(id, &[ins(4, "!")], 5_000));
        assert_eq!(store.text(id).unwrap(), "same!\n");
        assert!(store.is_dirty(id));
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "same\n");
        assert!(
            !store.is_dirty(id),
            "an unreachable generation marker stops pinning the file dirty"
        );

        // The only remaining redo is the branched typing step; the old
        // Take theirs redo was invalidated when that branch was authored.
        assert!(store.redo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "same!\n");
        assert!(store.is_dirty(id));
        assert!(!store.can_redo(id));
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "same\n");
        assert!(!store.is_dirty(id));

        store.save(&io, id).unwrap();
        assert!(!store.is_dirty(id), "a successful save settles the branch");
        assert_eq!(io.bytes("/equal.txt"), [UTF8_BOM, b"same\r\n"].concat());
    }

    #[test]
    fn take_theirs_generation_state_clears_only_on_successful_settlement() {
        let io = MemoryIo::with("/settle.txt", b"old\n");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/settle.txt")).unwrap();
        assert!(store.apply_ops(id, &[del(0, 3), ins(0, "same")], 1));
        io.put("/settle.txt", b"same\n");
        store.take_theirs(&io, id).unwrap();
        assert!(store.undo(id).unwrap().applied);
        assert!(store.is_dirty(id));

        io.remove("/settle.txt");
        assert_eq!(
            store.take_theirs(&io, id),
            Err(OpenRefusal::Io(io::ErrorKind::NotFound))
        );
        assert!(
            store.is_dirty(id),
            "a refused resolution leaves generation state unchanged"
        );

        io.put("/settle.txt", b"same\n");
        store.take_theirs(&io, id).unwrap();
        assert!(!store.is_dirty(id), "a new Take theirs settles the state");
        assert!(store.undo(id).unwrap().applied);
        assert!(store.is_dirty(id));

        store.reload(&io, id).unwrap();
        assert!(!store.is_dirty(id), "automatic adoption clears the state");
        assert!(
            !store.can_undo(id),
            "automatic reload keeps no undo history"
        );

        assert!(store.close(id));
        let reopened = store.open(&io, Path::new("/settle.txt")).unwrap();
        assert!(!store.is_dirty(reopened));
    }

    #[test]
    fn typing_past_an_undone_take_theirs_retires_the_orphaned_marker() {
        let io = MemoryIo::with("/orphan.txt", b"old\n");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/orphan.txt")).unwrap();
        assert!(store.apply_ops(id, &[del(0, 3), ins(0, "mine")], 1));
        io.put("/orphan.txt", b"theirs\n");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);

        store.take_theirs(&io, id).unwrap();
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "mine\n");
        assert!(store.is_dirty(id));
        assert!(store.can_redo(id));

        // The local commit drops the redo stack, so the disk generation
        // becomes unreachable and the marker loses its authority.
        assert!(store.apply_ops(id, &[ins(4, "!")], 2));
        assert!(!store.can_redo(id));
        assert!(store.is_dirty(id), "the typing itself is a real edit");

        // Editing back to the disk text now reads saved, because no Undo
        // or Redo remains that could explain an unsaved file.
        assert!(store.apply_ops_as_new_step(id, &[del(0, 5), ins(0, "theirs")], 3));
        assert_eq!(store.text(id).unwrap(), "theirs\n");
        assert!(
            !store.is_dirty(id),
            "an orphaned generation marker cannot pin the file dirty"
        );
        assert_eq!(
            store.file(id).unwrap().bytes_to_write(),
            b"theirs\n".to_vec()
        );
    }

    #[test]
    fn take_theirs_over_two_empty_copies_settles_without_a_step() {
        let io = MemoryIo::with("/empty.txt", b"");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/empty.txt")).unwrap();
        assert_eq!(store.text(id).unwrap(), "");
        assert!(!store.can_undo(id));

        store.take_theirs(&io, id).unwrap();
        assert_eq!(store.text(id).unwrap(), "");
        assert!(!store.is_dirty(id));
        assert_eq!(store.check(&io, id), ExternalState::Unchanged);
        assert!(
            !store.can_undo(id),
            "nothing changed, so there is no step to take back"
        );
        assert!(!store.can_redo(id));
        assert_eq!(
            store.file(id).unwrap().active_take_theirs_generation,
            None,
            "no undo item exists, so no generation may govern dirty state"
        );

        // Pressing Undo anyway is a step that did not happen, and the
        // file is left exactly where the adoption put it.
        assert!(!store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "");
        assert!(!store.is_dirty(id));

        // A later adoption over a disk copy with words in it is an
        // ordinary structural step again.
        io.put("/empty.txt", b"theirs\n");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        store.take_theirs(&io, id).unwrap();
        assert_eq!(store.text(id).unwrap(), "theirs\n");
        assert!(store.can_undo(id));
        assert!(
            store
                .file(id)
                .unwrap()
                .active_take_theirs_generation
                .is_some(),
            "an undo item exists, so its generation is armed"
        );
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "");
        assert!(store.is_dirty(id));
        assert!(store.redo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "theirs\n");
        assert!(!store.is_dirty(id));
    }

    #[test]
    fn save_invalidates_historical_take_theirs_markers() {
        let io = MemoryIo::with("/saved.txt", b"old");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/saved.txt")).unwrap();
        assert!(store.apply_ops(id, &[del(0, 3), ins(0, "mine")], 1));
        io.put("/saved.txt", b"theirs");
        store.take_theirs(&io, id).unwrap();
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "mine");
        assert!(store.is_dirty(id));

        store.save(&io, id).unwrap();
        assert!(!store.is_dirty(id));
        assert_eq!(io.bytes("/saved.txt"), b"mine");

        assert!(store.redo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "theirs");
        assert!(
            store.is_dirty(id),
            "the historical disk text differs from the newer saved baseline"
        );
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "mine");
        assert!(
            !store.is_dirty(id),
            "the stale marker cannot reactivate generation dirtiness"
        );
    }

    #[test]
    fn save_as_invalidates_historical_take_theirs_markers() {
        let io = MemoryIo::with("/from-take.txt", b"old");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/from-take.txt")).unwrap();
        assert!(store.apply_ops(id, &[del(0, 3), ins(0, "mine")], 1));
        io.put("/from-take.txt", b"theirs");
        store.take_theirs(&io, id).unwrap();
        assert!(store.undo(id).unwrap().applied);

        store.save_as(&io, id, Path::new("/saved-as.txt")).unwrap();
        assert_eq!(store.file(id).unwrap().path(), Path::new("/saved-as.txt"));
        assert!(!store.is_dirty(id));

        assert!(store.redo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "theirs");
        assert!(store.is_dirty(id));
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "mine");
        assert!(!store.is_dirty(id));
    }

    #[test]
    fn typing_after_take_theirs_is_a_later_undo_step() {
        let io = MemoryIo::with("/later.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/later.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1_000));
        io.put("/later.txt", b"theirs");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        store.take_theirs(&io, id).unwrap();

        assert!(store.apply_ops(id, &[ins(6, "!")], 2_000));
        assert_eq!(store.text(id).unwrap(), "theirs!");
        assert!(store.is_dirty(id));

        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "theirs");
        assert!(!store.is_dirty(id));
        assert!(
            store.can_undo(id),
            "Take theirs remains a distinct earlier step"
        );

        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "one mine");
        assert!(store.is_dirty(id));

        assert!(store.redo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "theirs");
        assert!(!store.is_dirty(id));
        assert!(store.redo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "theirs!");
        assert!(store.is_dirty(id));
    }

    #[test]
    fn a_refused_take_theirs_preserves_the_draft_and_undo_stack() {
        let io = MemoryIo::with("/gone.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/gone.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.remove("/gone.txt");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Missing);

        assert_eq!(
            store.take_theirs(&io, id),
            Err(OpenRefusal::Io(io::ErrorKind::NotFound))
        );
        assert_eq!(store.text(id).unwrap(), "one mine");
        assert!(store.is_dirty(id));
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::Missing);
        assert!(store.can_undo(id));
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
    fn keep_mine_survives_the_check_the_shell_makes_before_every_save() {
        // The documented flow: check on activate, check again before
        // the save. Without the standing consent the second check puts
        // the conflict back and keep mine never writes anything.
        let io = MemoryIo::with("/k2.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k2.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/k2.txt", b"theirs");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        assert!(store.resolve_keep_mine(&io, id));

        // The shell checks again, as the header tells it to.
        let state = store.refresh_conflict(&io, id);
        assert_eq!(state, ExternalState::Unchanged, "the fresh witness matches");
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::None);
        store.save(&io, id).expect("keep mine then save must write");
        assert_eq!(io.bytes("/k2.txt"), b"one mine");
    }

    #[test]
    fn keep_mine_over_a_missing_file_still_saves() {
        // There is no witness to take here, so the consent flag is the
        // only thing carrying the choice through the pre save check.
        let io = MemoryIo::with("/k3.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k3.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.remove("/k3.txt");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Missing);
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::Missing);
        assert!(store.resolve_keep_mine(&io, id));
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Missing);
        assert_eq!(
            store.file(id).unwrap().conflict(),
            FileConflict::None,
            "the person has answered this question"
        );
        store.save(&io, id).expect("keep mine recreates the file");
        assert_eq!(io.bytes("/k3.txt"), b"one mine");
    }

    #[test]
    fn the_consent_is_spent_by_the_save_it_was_given_for() {
        let io = MemoryIo::with("/k4.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k4.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/k4.txt", b"theirs");
        store.refresh_conflict(&io, id);
        assert!(store.resolve_keep_mine(&io, id));
        store.save(&io, id).unwrap();

        // A second divergence asks again rather than riding the first
        // answer.
        assert!(store.apply_ops(id, &[ins(0, "more ")], 2));
        io.put("/k4.txt", b"and again");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::Changed);
        assert_eq!(store.save(&io, id), Err(SaveError::Conflict));
    }

    #[test]
    fn save_as_onto_a_path_another_file_holds_is_refused() {
        let io = MemoryIo::with("/one.txt", b"first");
        io.put("/two.txt", b"second");
        let mut store = FileStore::new();
        let first = store.open(&io, Path::new("/one.txt")).unwrap();
        let second = store.open(&io, Path::new("/two.txt")).unwrap();
        assert_eq!(
            store.save_as(&io, first, Path::new("/two.txt")),
            Err(SaveError::PathInUse)
        );
        assert_eq!(io.bytes("/two.txt"), b"second", "nothing was written");
        assert_eq!(store.files().len(), 2);
        assert_eq!(store.file(first).unwrap().path(), Path::new("/one.txt"));

        // Saving as its own path is not another file's path.
        store.save_as(&io, second, Path::new("/two.txt")).unwrap();
    }

    #[test]
    fn a_write_between_the_read_and_the_stat_is_never_invisible() {
        // A filesystem that rewrites the file once, underneath the
        // read. The pair of stats disagree, so the read is taken again
        // rather than kept with a witness from the wrong generation.
        let io = ShiftingIo::new(b"one", 1);
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/s.txt")).unwrap();
        assert_eq!(
            store.text(id).unwrap(),
            "settled",
            "the buffer holds the generation its witness describes"
        );
        assert_eq!(
            store.check(&io, id),
            ExternalState::Unchanged,
            "and the check agrees, because the two go together"
        );
    }

    #[test]
    fn a_file_rewritten_faster_than_it_reads_is_refused_rather_than_opened() {
        // Never opened with a mismatched pair: that would make `check`
        // answer Unchanged forever and the next save would overwrite
        // the other writer without a word.
        let io = ShiftingIo::new(b"one", 99);
        let mut store = FileStore::new();
        assert_eq!(
            store.open(&io, Path::new("/s.txt")),
            Err(OpenRefusal::Io(io::ErrorKind::Interrupted))
        );
        assert!(store.files().is_empty());
    }

    #[test]
    fn a_symlink_is_resolved_once_at_open() {
        // The seam's own resolution, which the real one implements with
        // `std::fs::canonicalize`: the store keeps the resolved path,
        // so a save lands on the file rather than on the link.
        let io = MemoryIo::with("/real.txt", b"body");
        io.link("/link.txt", "/real.txt");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/link.txt")).unwrap();
        assert_eq!(store.file(id).unwrap().path(), Path::new("/real.txt"));
        assert_eq!(store.file(id).unwrap().name(), "real.txt");

        // And the two paths are one open file, not two buffers racing.
        assert_eq!(store.open(&io, Path::new("/real.txt")).unwrap(), id);
        assert_eq!(store.files().len(), 1);
    }

    #[test]
    fn a_refused_batch_stamps_no_edit_time() {
        let io = MemoryIo::with("/st.txt", b"abc");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/st.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, "d")], 7_000));
        assert_eq!(store.file(id).unwrap().last_edited_at(), 7);
        assert!(!store.apply_ops(id, &[ins(400, "x")], 9_000));
        assert_eq!(
            store.file(id).unwrap().last_edited_at(),
            7,
            "a batch the caller was told was refused claims no edit"
        );
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
