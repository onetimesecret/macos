//! Open files, a content class peer to pages (ADR-0028): never a tab, never
//! synced. Platform IO is the [`FileIo`] trait; paths cross the FFI, bytes
//! do not. Dirty means the buffer differs from the last disk text.

use std::io;
use std::path::{Path, PathBuf};

use zeroize::Zeroizing;

use crate::document::{DocRun, EditIntent, EditSelection, SheetDocument, TextSelection};
use crate::ink::{self, StepOutcome, document_holding, text_of};
use crate::store::{EditOp, inferred_intent};

/// The high bit: set on every [`FileId`], on no page id. Mirrored in Swift as
/// `CompanionClient.fileIDTag`; every `companion_sheet_*` call refuses it.
pub const FILE_ID_TAG: u64 = 1 << 63;

/// The largest file this build opens, in bytes.
pub const FILE_SIZE_LIMIT: usize = 4 * 1024 * 1024;

/// The largest draft snapshot staged, in bytes. Reachable: a draft is the
/// op log, not the text; over it the record is identity only (ADR-0028).
pub const DRAFT_SNAPSHOT_LIMIT: usize = 4 * FILE_SIZE_LIMIT;

/// Stripped at open, restored at save.
const UTF8_BOM: &[u8] = &[0xEF, 0xBB, 0xBF];

/// UTF-16/32 BOMs, checked before the binary classifier sees their zeros.
const NON_UTF8_BOMS: &[&[u8]] = &[
    &[0xFF, 0xFE, 0x00, 0x00],
    &[0x00, 0x00, 0xFE, 0xFF],
    &[0xFF, 0xFE],
    &[0xFE, 0xFF],
];

/// Why a drafts record left the roster, or came back with less.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DroppedReason {
    /// Nothing at the path. Only a clean file is dropped; a dirty one stands
    /// in [`FileConflict::Missing`].
    Missing,
    /// Reached, but not UTF-8, binary-like or too large. Not the same as
    /// [`OpenFile::access_refused`].
    Unreadable,
    /// The draft exceeded [`DRAFT_SNAPSHOT_LIMIT`]; the file came back clean
    /// from disk, the unsaved edits did not.
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

/// Something to tell the user after a drafts save or restore.
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
    /// Whether a raw id addresses a file rather than a page.
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

/// The file's line ending, decided by its first line at open. A mixed
/// file is written back uniform.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineEnding {
    /// A single newline.
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

/// The filesystem's answer at the last read or write, for [`FileStore::check`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileWitness {
    /// The device the file sits on.
    pub dev: u64,
    /// The inode; with `dev`, catches a replaced file of equal size and stamp.
    pub ino: u64,
    /// Size in bytes.
    pub size: u64,
    /// Modification time, nanoseconds since the Unix epoch.
    pub mtime_ns: i128,
}

/// A buffer's conflict with the disk copy. A clean file never enters one.
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

/// The whole platform surface a file needs; implemented in `crates/ffi`.
pub trait FileIo {
    /// Read the file. May stop one byte past [`FILE_SIZE_LIMIT`], so callers
    /// check the length.
    ///
    /// # Errors
    /// Whatever the platform said about the read.
    fn read(&self, path: &Path) -> io::Result<Vec<u8>>;
    /// Probe readability, reading at most one byte.
    ///
    /// # Errors
    /// Whatever the platform said about opening or probing the file.
    fn probe_readable(&self, path: &Path) -> io::Result<()>;
    /// Write atomically, preserving the existing mode. The witness comes from
    /// the writing descriptor, never a later stat of the path.
    ///
    /// # Errors
    /// Whatever the platform said about the write.
    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<FileWitness>;
    /// Take a witness of whatever is at the path right now.
    ///
    /// # Errors
    /// Whatever the platform said about the stat.
    fn stat(&self, path: &Path) -> io::Result<FileWitness>;

    /// Resolve every symlink, once at open, so a save lands on the real file.
    /// Defaults to the identity.
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
    /// The bytes are not UTF-8.
    NotUtf8,
    /// The bytes decode as UTF-8 with binary-like control content.
    Binary,
    /// Larger than [`FILE_SIZE_LIMIT`].
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
    /// The file changed under a dirty buffer; refused until resolved.
    Conflict,
    /// No file with that id is open.
    UnknownFile,
    /// The target path is open under another id.
    PathInUse,
    /// Not yet hydrated; a write could put an empty buffer over the file.
    PendingHydration,
    /// Nothing at the path and no keep mine: a save never recreates a deleted
    /// file. The ways out are relocate, save as, or keep mine.
    NotFound,
    /// The write itself failed. The file on disk is untouched.
    Io(io::ErrorKind),
}

/// Where a hydrated file ended up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HydrationFate {
    /// No file is open under that id.
    UnknownFile,
    /// Not pending; nothing was read. Asking twice is harmless.
    NotPending,
    /// The file stands in the roster, ready to draw.
    Kept,
    /// Still pending: the resolved path is another pending file's recorded
    /// path, so ask again once that one settles.
    Deferred,
    /// Could not reopen and held no draft, so it left the roster.
    Dropped,
    /// Access refused and no draft: kept, pending and empty, so the person can
    /// relocate it. Asking again later is allowed.
    Held,
}

/// Why a relocation refused. The file is left exactly as it was.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelocateRefusal {
    /// No file with that id is open.
    UnknownFile,
    /// The chosen path is open under another id.
    PathInUse,
    /// The chosen file would not open.
    Open(OpenRefusal),
}

/// What became of the resolved path a hydration was handed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathRebind {
    /// No path was given, or the one given is the path already held.
    Unmoved,
    /// The file now answers to the resolved path.
    Rebound,
    /// Another settled file holds the resolved path; the recorded one stays.
    Refused,
}

/// Everything one [`FileStore::hydrate_one`] call settled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HydrationOutcome {
    /// Where the file ended up.
    pub fate: HydrationFate,
    /// What became of the resolved path, when one was given.
    pub rebind: PathRebind,
    /// What the shell owes the person: a drop, or a draft too large to stage.
    pub notice: Option<FileNotice>,
}

impl HydrationOutcome {
    fn untouched(fate: HydrationFate) -> Self {
        Self {
            fate,
            rebind: PathRebind::Unmoved,
            notice: None,
        }
    }
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

/// One open file.
pub struct OpenFile {
    id: FileId,
    path: PathBuf,
    /// The same document type a page uses, with one peer and no remote.
    document: SheetDocument,
    /// Last disk text, normalized as the buffer holds it: the one dirtiness
    /// baseline. `None` while the disk copy is unknown (ADR-0031).
    saved_text: Option<Zeroizing<String>>,
    witness: Option<FileWitness>,
    line_ending: LineEnding,
    has_bom: bool,
    dirty: bool,
    conflict: FileConflict,
    /// Unix ms of the last accepted batch; zero if never edited.
    last_edited_ms: u64,
    /// Whether this buffer came back from `drafts.sealed`.
    restored_from_draft: bool,
    /// Filled from a disk copy changed since the draft; sticky until
    /// [`FileStore::clear_reload_notice`].
    externally_reloaded: bool,
    /// A standing keep mine. Spent by one save; withdrawn when the buffer
    /// settles clean or the path changes state.
    overwrite_next_save: bool,
    /// Whether the keep mine was given over an empty path; it licenses only
    /// the state it was given over.
    keep_mine_over_absence: bool,
    /// The Take theirs generation that may govern dirty state; a save clears it.
    active_take_theirs_generation: Option<i64>,
    /// Last minted generation; monotonic while its markers live.
    next_take_theirs_generation: i64,
    /// The active Take theirs is undone, so the prior draft reads dirty.
    take_theirs_undone: bool,
    /// Dirty with no snapshot in the drafts file (over
    /// [`DRAFT_SNAPSHOT_LIMIT`]); hydration turns it into a notice.
    draft_dropped: bool,
    /// A drafts record not yet reconciled with disk. Edits, writes and
    /// re-reads refuse it; hydrate, relocate, bookmark and close accept it.
    pending_hydration: bool,
    /// The platform denied the last read or stat (not absence). Cleared by a
    /// successful read or a save; never persisted.
    access_refused: bool,
    /// The last look found nothing at the path; for a clean file, the only
    /// sign it is gone. Never persisted.
    not_found: bool,
    /// The shell's bookmark, opaque here.
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

    /// Unix seconds of the last accepted batch, or zero.
    #[must_use]
    pub fn last_edited_at(&self) -> u64 {
        self.last_edited_ms / 1000
    }

    /// Whether this buffer came back from `drafts.sealed`.
    #[must_use]
    pub fn restored_from_draft(&self) -> bool {
        self.restored_from_draft
    }

    /// Filled from a changed disk copy; true until the shell posts the notice.
    #[must_use]
    pub fn externally_reloaded(&self) -> bool {
        self.externally_reloaded
    }

    /// Waiting on [`FileStore::hydrate_one`]: in the roster, but not fit to
    /// draw, edit or save.
    #[must_use]
    pub fn pending_hydration(&self) -> bool {
        self.pending_hydration
    }

    /// The platform refused the last attempt to reach the disk copy.
    #[must_use]
    pub fn access_refused(&self) -> bool {
        self.access_refused
    }

    /// The last look at the path found nothing there.
    #[must_use]
    pub fn not_found(&self) -> bool {
        self.not_found
    }

    /// The shell's bookmark for this file, opaque to this crate.
    #[must_use]
    pub fn bookmark(&self) -> &[u8] {
        &self.bookmark
    }

    /// The buffer as text: newlines only, no BOM.
    #[must_use]
    pub fn text(&self) -> String {
        text_of(&self.document)
    }

    /// The bytes a save would write, in the file's own line endings and BOM.
    #[must_use]
    pub fn bytes_to_write(&self) -> Vec<u8> {
        self.bytes_to_write_zeroizing().to_vec()
    }

    /// The save bytes, zeroized after use.
    fn bytes_to_write_zeroizing(&self) -> Zeroizing<Vec<u8>> {
        let text = Zeroizing::new(text_of(&self.document));
        let extra_crs = usize::from(self.line_ending == LineEnding::Crlf)
            * text.bytes().filter(|byte| *byte == b'\n').count();
        let mut bytes = Zeroizing::new(Vec::with_capacity(
            text.len() + extra_crs + usize::from(self.has_bom) * UTF8_BOM.len(),
        ));
        if self.has_bom {
            bytes.extend_from_slice(UTF8_BOM);
        }
        for byte in text.bytes() {
            if byte == b'\n' && self.line_ending == LineEnding::Crlf {
                bytes.push(b'\r');
            }
            bytes.push(byte);
        }
        bytes
    }

    /// Recompute `dirty` against the baseline; an unknown baseline keeps the flag.
    fn resettle_dirty(&mut self) {
        if self.take_theirs_undone {
            self.dirty = true;
        } else if let Some(saved) = &self.saved_text {
            self.dirty = !document_matches_text(&self.document, saved);
        }
        // Nothing unsaved is left to win with, so the keep mine lapses.
        if !self.dirty {
            self.overwrite_next_save = false;
        }
    }

    /// Withdraw a keep mine whose path state (absent or present) has changed.
    /// A refused stat is no answer, so the consent stands.
    fn withdraw_stale_consent(&mut self, stat: &io::Result<FileWitness>) -> bool {
        if !self.overwrite_next_save {
            return false;
        }
        let absent = match stat {
            Ok(_) => false,
            Err(error) if error.kind() == io::ErrorKind::NotFound => true,
            Err(_) => return false,
        };
        if absent == self.keep_mine_over_absence {
            return false;
        }
        self.overwrite_next_save = false;
        true
    }

    /// Take the disk text as buffer and baseline. `restored_from_draft` is the
    /// caller's to set.
    fn adopt(&mut self, read: ReadFile) {
        self.document = document_holding(&read.text);
        self.saved_text = Some(read.text);
        self.witness = Some(read.witness);
        self.line_ending = read.line_ending;
        self.has_bom = read.has_bom;
        self.dirty = false;
        self.conflict = FileConflict::None;
        self.access_refused = false;
        self.not_found = false;
        self.active_take_theirs_generation = None;
        self.next_take_theirs_generation = 0;
        self.take_theirs_undone = false;
    }

    /// Settle after a successful read, for hydration and relocation alike. A
    /// live clean buffer over the same text keeps its document and undo; a
    /// draft over a changed copy conflicts. Returns any draft-too-large notice.
    fn settle_over(&mut self, read: ReadFile) -> Option<FileNotice> {
        let dropped_draft = self.draft_dropped;
        if dropped_draft {
            self.dirty = false;
            self.take_theirs_undone = false;
            self.draft_dropped = false;
        }
        let notice = dropped_draft.then(|| self.notice(DroppedReason::DraftTooLarge));
        let unchanged = self.witness == Some(read.witness)
            || self
                .saved_text
                .as_ref()
                .is_some_and(|saved| **saved == *read.text);
        // By text, not witness: the document is kept only if the words agree.
        let same_text_live = !self.dirty
            && !self.pending_hydration
            && self
                .saved_text
                .as_ref()
                .is_some_and(|saved| **saved == *read.text);
        if same_text_live {
            self.line_ending = read.line_ending;
            self.has_bom = read.has_bom;
            self.witness = Some(read.witness);
            self.saved_text = Some(read.text);
            self.conflict = FileConflict::None;
        } else if !self.dirty {
            self.adopt(read);
            self.externally_reloaded = !unchanged;
        } else if unchanged {
            self.line_ending = read.line_ending;
            self.has_bom = read.has_bom;
            self.witness = Some(read.witness);
            self.saved_text = Some(read.text);
            self.conflict = FileConflict::None;
            self.resettle_dirty();
        } else {
            // Witness and saved text stay on the draft's generation, so the next
            // check still reads changed.
            self.conflict = FileConflict::Changed;
        }
        self.pending_hydration = false;
        self.access_refused = false;
        self.not_found = false;
        // A keep mine answered one divergence; this settlement re-asked it.
        self.overwrite_next_save = false;
        notice
    }

    /// Record whether a refused read means unreachable, absent, or neither.
    fn note_refused_read(&mut self, refusal: OpenRefusal) {
        self.access_refused = refusal_is_unreachable(refusal);
        self.not_found = refusal == OpenRefusal::Io(io::ErrorKind::NotFound);
    }

    /// Mint a generation no live marker uses; at exhaustion, drop history
    /// rather than alias.
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

/// Every open file.
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

    /// Read `path` and open a buffer, or return the file already open there.
    ///
    /// # Errors
    ///
    /// [`OpenRefusal::NotUtf8`] for bytes that are not UTF-8,
    /// [`OpenRefusal::Binary`] for content that looks binary,
    /// [`OpenRefusal::TooLarge`] above [`FILE_SIZE_LIMIT`], and
    /// [`OpenRefusal::Io`] for a read the platform refused.
    pub fn open(&mut self, io: &dyn FileIo, path: &Path) -> Result<FileId, OpenRefusal> {
        // Resolved once; deduplication and every later IO use the resolved path.
        let path = &io
            .canonicalize(path)
            .map_err(|e| OpenRefusal::Io(e.kind()))?;
        if let Some(open) = self.files.iter().find(|file| file.path == *path) {
            // A pending row has no text read yet; the shell hydrates it first.
            if open.pending_hydration {
                return Err(OpenRefusal::Io(io::ErrorKind::ResourceBusy));
            }
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
            witness: Some(read.witness),
            line_ending: read.line_ending,
            has_bom: read.has_bom,
            dirty: false,
            conflict: FileConflict::None,
            last_edited_ms: 0,
            restored_from_draft: false,
            externally_reloaded: false,
            overwrite_next_save: false,
            keep_mine_over_absence: false,
            active_take_theirs_generation: None,
            next_take_theirs_generation: 0,
            take_theirs_undone: false,
            draft_dropped: false,
            pending_hydration: false,
            access_refused: false,
            not_found: false,
            bookmark: Vec::new(),
        });
        Ok(id)
    }

    /// Drop the buffer and its draft. Whether a dirty buffer may close is the
    /// shell's decision.
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

    /// The file's body as text; a file holds no chips.
    #[must_use]
    pub fn text(&self, id: FileId) -> Option<String> {
        self.file(id).map(OpenFile::text)
    }

    /// Whether the buffer holds edits the file on disk does not.
    #[must_use]
    pub fn is_dirty(&self, id: FileId) -> bool {
        self.file(id).is_some_and(OpenFile::is_dirty)
    }

    /// Attach the shell's bookmark; carried, never inspected.
    pub fn set_bookmark(&mut self, id: FileId, bookmark: Vec<u8>) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        file.bookmark = bookmark;
        true
    }

    /// Apply an edit batch whole or refuse it; `wall_ms` stamps an accepted one.
    pub fn apply_ops(&mut self, id: FileId, ops: &[EditOp], wall_ms: u64) -> bool {
        self.apply_batch(id, ops, wall_ms, inferred_intent(ops), None)
    }

    /// Apply one admitted batch with the editing gesture that produced it.
    pub fn apply_ops_with_intent(
        &mut self,
        id: FileId,
        ops: &[EditOp],
        wall_ms: u64,
        intent: EditIntent,
    ) -> bool {
        self.apply_batch(id, ops, wall_ms, intent, None)
    }

    /// Apply a batch with both the editing gesture and its selections.
    pub fn apply_ops_with_intent_and_selection(
        &mut self,
        id: FileId,
        ops: &[EditOp],
        wall_ms: u64,
        intent: EditIntent,
        selection: EditSelection,
    ) -> bool {
        self.apply_batch(id, ops, wall_ms, intent, Some(selection))
    }

    /// [`FileStore::apply_ops`] for a batch the app produced on the
    /// writer's behalf, which must begin its own undo step.
    pub fn apply_ops_as_new_step(&mut self, id: FileId, ops: &[EditOp], wall_ms: u64) -> bool {
        self.apply_batch(id, ops, wall_ms, EditIntent::Automation, None)
    }

    fn apply_batch(
        &mut self,
        id: FileId,
        ops: &[EditOp],
        wall_ms: u64,
        intent: EditIntent,
        selection: Option<EditSelection>,
    ) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        // A pending buffer is not the file's text yet.
        if file.pending_hydration {
            return false;
        }
        if ops.is_empty() {
            return true;
        }
        // False from a validated batch tells the shell to restate the file.
        let Some(clean) = ink::apply_batch(&mut file.document, ops, intent, selection) else {
            return false;
        };
        if clean {
            file.last_edited_ms = wall_ms;
        }
        // A local commit drops redo, orphaning an undone Take theirs (ADR-0031).
        if file.take_theirs_undone && !file.document.can_redo() {
            file.take_theirs_undone = false;
            file.active_take_theirs_generation = None;
        }
        file.resettle_dirty();
        clean
    }

    /// Finish the current typing/deletion run without adding an undo item.
    pub fn finish_editing_group(&mut self, id: FileId) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        file.document.finish_editing_group(None);
        true
    }

    /// Finish a group and record the selection now shown by the editor.
    pub fn finish_editing_group_at(&mut self, id: FileId, selection: TextSelection) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        file.document.finish_editing_group(Some(selection));
        true
    }

    /// Whether the file has an undo step; false for an unknown file.
    #[must_use]
    pub fn can_undo(&self, id: FileId) -> bool {
        self.file(id).is_some_and(|file| file.document.can_undo())
    }

    /// Whether the file has a step waiting to be restored.
    #[must_use]
    pub fn can_redo(&self, id: FileId) -> bool {
        self.file(id).is_some_and(|file| file.document.can_redo())
    }

    /// Content-free action label for the next Undo menu item.
    pub fn undo_action_name(&self, id: FileId) -> Option<&'static str> {
        self.file(id)?.document.undo_action_name()
    }

    /// Content-free action label for the next Redo menu item.
    pub fn redo_action_name(&self, id: FileId) -> Option<&'static str> {
        self.file(id)?.document.redo_action_name()
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
        // A pending buffer must not move.
        let outcome = if file.pending_hydration {
            StepOutcome::NONE
        } else {
            ink::step(&mut file.document, back)
        };
        if outcome.applied {
            if let Some(generation) = file.document.popped_take_theirs()
                && file.active_take_theirs_generation == Some(generation)
            {
                // Only the marker bound to the current baseline governs dirtiness.
                file.take_theirs_undone = back;
            }
            file.resettle_dirty();
        }
        Some(outcome)
    }

    /// Write the buffer back to its own path, in its own BOM and line endings.
    ///
    /// # Errors
    /// [`SaveError::Conflict`], [`SaveError::UnknownFile`],
    /// [`SaveError::PendingHydration`], [`SaveError::NotFound`] (nothing at the
    /// path and no keep mine), or [`SaveError::Io`] (the file is untouched).
    pub fn save(&mut self, io: &dyn FileIo, id: FileId) -> Result<(), SaveError> {
        let file = self.file_mut(id).ok_or(SaveError::UnknownFile)?;
        if file.pending_hydration {
            return Err(SaveError::PendingHydration);
        }
        if file.conflict != FileConflict::None {
            return Err(SaveError::Conflict);
        }
        let path = file.path.clone();
        // Stat here too, so a caller that skipped the check cannot recreate a
        // deleted file. Only a keep mine given over the empty path licenses it.
        let stat = io.stat(&path);
        let withdrawn = file.withdraw_stale_consent(&stat);
        match &stat {
            Err(error) if error.kind() == io::ErrorKind::NotFound && !file.overwrite_next_save => {
                file.access_refused = false;
                file.not_found = true;
                // A draft enters the missing conflict, as a check would set it.
                if file.dirty {
                    file.conflict = FileConflict::Missing;
                }
                return Err(SaveError::NotFound);
            }
            // The consent was over an empty path; a file nobody was shown is there now.
            Ok(_) if withdrawn && file.dirty => {
                file.not_found = false;
                file.conflict = FileConflict::Changed;
                return Err(SaveError::Conflict);
            }
            _ => {}
        }
        write_and_settle(io, file, &path)
    }

    /// Write the buffer to a new path and adopt it. Allowed during a conflict,
    /// since it cannot overwrite the change that caused it.
    ///
    /// # Errors
    /// [`SaveError::PathInUse`] (another open file holds the target),
    /// [`SaveError::UnknownFile`], [`SaveError::PendingHydration`], or
    /// [`SaveError::Io`].
    pub fn save_as(&mut self, io: &dyn FileIo, id: FileId, path: &Path) -> Result<(), SaveError> {
        // A pending clean record's buffer is empty; refuse before the path.
        if self.file(id).is_some_and(|file| file.pending_hydration) {
            return Err(SaveError::PendingHydration);
        }
        // Resolved like an open; a target that does not exist yet resolves by its
        // directory.
        let path = &resolve_target(io, path);
        if self.files.iter().any(|f| f.id != id && f.path == *path) {
            return Err(SaveError::PathInUse);
        }
        let file = self.file_mut(id).ok_or(SaveError::UnknownFile)?;
        write_and_settle(io, file, path)?;
        file.path = path.clone();
        Ok(())
    }

    /// Stat and compare against the last witness; changes nothing. Any stat
    /// failure but absence reads as [`ExternalState::Changed`].
    #[must_use]
    pub fn check(&self, io: &dyn FileIo, id: FileId) -> ExternalState {
        let Some(file) = self.file(id) else {
            return ExternalState::Missing;
        };
        external_state(&io.stat(&file.path), file.witness)
    }

    /// [`FileStore::check`], then set the conflict and the access refused and
    /// not found marks. A keep mine holds the conflict off; a draft whose disk
    /// copy cannot be read stays in [`FileConflict::Changed`].
    pub fn refresh_conflict(&mut self, io: &dyn FileIo, id: FileId) -> ExternalState {
        let Some(file) = self.file_mut(id) else {
            return ExternalState::Missing;
        };
        let stat = io.stat(&file.path);
        let mut state = external_state(&stat, file.witness);
        // A pending file's conflict is the hydration's to decide.
        if !file.pending_hydration {
            match &stat {
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    file.access_refused = false;
                    file.not_found = true;
                }
                Err(_) => {
                    file.access_refused = true;
                    file.not_found = false;
                }
                Ok(_) => {
                    file.not_found = false;
                    match io.probe_readable(&file.path) {
                        Ok(()) => file.access_refused = false,
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => {
                            // Inconclusive: neither restores access nor licenses a save.
                            state = ExternalState::Changed;
                        }
                        Err(error) => {
                            file.note_refused_read(OpenRefusal::Io(error.kind()));
                            // Absence found after the stat is newer evidence.
                            if file.not_found {
                                state = ExternalState::Missing;
                            }
                        }
                    }
                }
            }
            // A keep mine over a path that has changed state is asked afresh.
            file.withdraw_stale_consent(&stat);
            file.conflict = match (state, file.dirty) {
                (_, false) => FileConflict::None,
                // Keep mine answered this; the shell checks before every save.
                _ if file.overwrite_next_save => FileConflict::None,
                // No saving a draft over a copy nothing here can read.
                (ExternalState::Unchanged, true) if file.access_refused => FileConflict::Changed,
                (ExternalState::Unchanged, true) => FileConflict::None,
                (ExternalState::Changed, true) => FileConflict::Changed,
                (ExternalState::Missing, true) => FileConflict::Missing,
            };
        }
        state
    }

    /// Keep mine: license exactly one save over the disk copy (ADR-0028). Over
    /// a changed copy the baseline is dropped, so the file stays dirty until
    /// then. Returns false when a missing file is back and changed.
    pub fn resolve_keep_mine(&mut self, io: &dyn FileIo, id: FileId) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        // Nobody has been shown a divergence on a pending file.
        if file.pending_hydration {
            return false;
        }
        let stat = io.stat(&file.path);
        if file.conflict == FileConflict::Missing && stat.is_ok() {
            file.not_found = false;
            let changed = external_state(&stat, file.witness) == ExternalState::Changed;
            file.conflict = if changed {
                FileConflict::Changed
            } else {
                FileConflict::None
            };
            return !changed;
        }
        // Asked while the witness still describes the measured generation.
        let diverged = external_state(&stat, file.witness) == ExternalState::Changed;
        file.conflict = FileConflict::None;
        file.overwrite_next_save = true;
        file.keep_mine_over_absence =
            matches!(&stat, Err(error) if error.kind() == io::ErrorKind::NotFound);
        file.witness = stat.ok();
        if diverged {
            // The saved generation is gone from disk and its replacement is unread,
            // so the baseline is unknown.
            file.saved_text = None;
            file.dirty = true;
        }
        true
    }

    /// Re-read the file, discarding the buffer and its undo history: the
    /// clean-file reload. Conflicts use [`FileStore::take_theirs`].
    ///
    /// # Errors
    /// As [`FileStore::open`], and busy for a pending file. A refused reload
    /// leaves the buffer as it was.
    pub fn reload(&mut self, io: &dyn FileIo, id: FileId) -> Result<(), OpenRefusal> {
        let path = self.path_for_reread(id)?;
        let read = self.read_for(io, id, &path)?;
        if let Some(file) = self.file_mut(id) {
            file.adopt(read);
            file.restored_from_draft = false;
            file.externally_reloaded = false;
            file.overwrite_next_save = false;
        }
        Ok(())
    }

    /// Adopt the disk copy as one undoable step: Undo restores the draft as
    /// dirty, Redo the disk text as clean (ADR-0028).
    ///
    /// # Errors
    /// As [`FileStore::reload`]. A refused read leaves buffer and history as
    /// they were.
    pub fn take_theirs(&mut self, io: &dyn FileIo, id: FileId) -> Result<(), OpenRefusal> {
        let path = self.path_for_reread(id)?;
        let read = self.read_for(io, id, &path)?;
        if let Some(file) = self.file_mut(id) {
            let generation = file.mint_take_theirs_generation();
            let len = file.document.utf16_len();
            // Empty over empty pushes no step, so Undo stays unavailable.
            file.document
                .delete(0, len)
                .expect("the document's full UTF-16 range is valid");
            file.document
                .insert(0, &read.text)
                .expect("zero is a valid insertion point");
            let stepped = file.document.commit_take_theirs_step(generation);
            file.saved_text = Some(read.text);
            file.witness = Some(read.witness);
            file.line_ending = read.line_ending;
            file.has_bom = read.has_bom;
            file.dirty = false;
            file.conflict = FileConflict::None;
            file.access_refused = false;
            file.not_found = false;
            // Armed only behind an undo item (ADR-0031).
            file.active_take_theirs_generation = stepped.then_some(generation);
            file.take_theirs_undone = false;
            file.restored_from_draft = false;
            file.externally_reloaded = false;
            file.overwrite_next_save = false;
        }
        Ok(())
    }

    /// Read the disk copy for an open file, noting whether it was reachable.
    fn read_for(
        &mut self,
        io: &dyn FileIo,
        id: FileId,
        path: &Path,
    ) -> Result<ReadFile, OpenRefusal> {
        let outcome = read_file(io, path);
        if let (Err(refusal), Some(file)) = (&outcome, self.file_mut(id)) {
            file.note_refused_read(*refusal);
        }
        outcome
    }

    /// The path a reload or take theirs reads; refused if unknown or pending.
    fn path_for_reread(&self, id: FileId) -> Result<PathBuf, OpenRefusal> {
        let file = self
            .file(id)
            .ok_or(OpenRefusal::Io(io::ErrorKind::NotFound))?;
        if file.pending_hydration {
            return Err(OpenRefusal::Io(io::ErrorKind::ResourceBusy));
        }
        Ok(file.path.clone())
    }

    /// The shell posted the reload notice. Roster reads never clear it, since
    /// the strip redraws.
    pub fn clear_reload_notice(&mut self, id: FileId) -> bool {
        let Some(file) = self.file_mut(id) else {
            return false;
        };
        file.externally_reloaded = false;
        true
    }

    /// Every open file, in open order.
    #[must_use]
    pub fn files(&self) -> &[OpenFile] {
        &self.files
    }

    /// Forget every open file, before a drafts restore fills the store.
    pub(crate) fn clear(&mut self) {
        self.files.clear();
        // The id counter is not reset, so a stale shell id never names a new buffer.
    }

    /// Put back one file from a drafts record, pending until
    /// [`FileStore::hydrate_one`]. Dirty with no snapshot means the draft was
    /// over [`DRAFT_SNAPSHOT_LIMIT`].
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
        document: SheetDocument,
        has_snapshot: bool,
    ) -> FileId {
        self.next_id += 1;
        let id = FileId(FILE_ID_TAG | self.next_id);
        self.files.push(OpenFile {
            id,
            path,
            document,
            // The disk copy is unread; the persisted flag is the only answer.
            saved_text: None,
            witness,
            line_ending,
            has_bom,
            dirty,
            conflict: FileConflict::None,
            last_edited_ms,
            restored_from_draft: true,
            externally_reloaded: false,
            overwrite_next_save: false,
            keep_mine_over_absence: false,
            active_take_theirs_generation: None,
            next_take_theirs_generation: 0,
            // Undo history does not cross launch, so no marker stands (ADR-0031).
            take_theirs_undone: false,
            draft_dropped: dirty && !has_snapshot,
            pending_hydration: true,
            access_refused: false,
            not_found: false,
            bookmark,
        });
        id
    }

    /// [`FileStore::hydrate_one`] for every pending file at its recorded path,
    /// gathering the notices. Shells with bookmarks hydrate per file instead.
    pub fn hydrate_restored(&mut self, io: &dyn FileIo) -> Vec<FileNotice> {
        let pending: Vec<FileId> = self
            .files
            .iter()
            .filter(|file| file.pending_hydration)
            .map(|file| file.id)
            .collect();
        pending
            .into_iter()
            .filter_map(|id| self.hydrate_one(io, id, None).notice)
            .collect()
    }

    /// Settle one restored file against the disk, touching no other.
    /// `resolved_path` rebinds it first: refused onto a settled holder's path,
    /// deferred onto a pending one's. Outcomes are ADR-0028's restore states;
    /// a clean record the platform refused to read is held (ADR-0035).
    pub fn hydrate_one(
        &mut self,
        io: &dyn FileIo,
        id: FileId,
        resolved_path: Option<&Path>,
    ) -> HydrationOutcome {
        let Some(at) = self.files.iter().position(|file| file.id == id) else {
            return HydrationOutcome::untouched(HydrationFate::UnknownFile);
        };
        if !self.files[at].pending_hydration {
            return HydrationOutcome::untouched(HydrationFate::NotPending);
        }

        let rebind = match resolved_path {
            None => PathRebind::Unmoved,
            Some(resolved) => {
                // Resolved like a save-as target; an unresolvable path is read as given.
                let target = resolve_target(io, resolved);
                if target == self.files[at].path {
                    PathRebind::Unmoved
                } else if let Some(holder) =
                    self.files.iter().find(|f| f.id != id && f.path == target)
                {
                    // A held file is staying put, so it holds its path like a settled one.
                    if holder.pending_hydration && !holder.access_refused {
                        return HydrationOutcome::untouched(HydrationFate::Deferred);
                    }
                    PathRebind::Refused
                } else {
                    self.files[at].path = target;
                    PathRebind::Rebound
                }
            }
        };

        let file = &mut self.files[at];
        // A dropped draft takes the clean path; its notice waits, so a missing
        // file gets one notice, not two.
        let staged = file.dirty && !file.draft_dropped;
        let mut notice = None;
        let fate = match read_file(io, &file.path) {
            Ok(read) => {
                notice = file.settle_over(read);
                HydrationFate::Kept
            }
            Err(refusal) if staged => {
                file.pending_hydration = false;
                if refusal == OpenRefusal::Io(io::ErrorKind::NotFound) {
                    // The witness stays, so a relocation can recognise the same file.
                    file.conflict = FileConflict::Missing;
                } else {
                    // Something unreadable is there; the conflict refuses the save.
                    file.conflict = FileConflict::Changed;
                    file.saved_text = None;
                }
                file.note_refused_read(refusal);
                HydrationFate::Kept
            }
            Err(refusal) if refusal_is_unreachable(refusal) => {
                // Still pending, so every edit or write route keeps refusing.
                file.access_refused = true;
                debug_assert_eq!(file.conflict, FileConflict::None);
                HydrationFate::Held
            }
            Err(refusal) => {
                // Reached but unopenable, or absent: relocating would not help, and no
                // draft is lost.
                let reason = if refusal == OpenRefusal::Io(io::ErrorKind::NotFound) {
                    DroppedReason::Missing
                } else {
                    DroppedReason::Unreadable
                };
                notice = Some(file.notice(reason));
                self.files.remove(at);
                HydrationFate::Dropped
            }
        };
        HydrationOutcome {
            fate,
            rebind,
            notice,
        }
    }

    /// Bind an open file to the path the person chose, read it there, and
    /// settle as a hydration does (ADR-0035). Returns any draft-too-large notice.
    ///
    /// # Errors
    /// [`RelocateRefusal::UnknownFile`], [`RelocateRefusal::PathInUse`], or
    /// [`RelocateRefusal::Open`]; every refusal leaves the file as it was.
    pub fn relocate(
        &mut self,
        io: &dyn FileIo,
        id: FileId,
        path: &Path,
    ) -> Result<Option<FileNotice>, RelocateRefusal> {
        let at = self
            .files
            .iter()
            .position(|file| file.id == id)
            .ok_or(RelocateRefusal::UnknownFile)?;
        // Resolved like an open.
        let target = resolve_target(io, path);
        if self.files.iter().any(|f| f.id != id && f.path == target) {
            return Err(RelocateRefusal::PathInUse);
        }
        // Read before anything moves, so a refusal costs nothing.
        let read = read_file(io, &target).map_err(RelocateRefusal::Open)?;
        let file = &mut self.files[at];
        file.path = target;
        Ok(file.settle_over(read))
    }

    /// The drafts record's snapshot slot, exported once so no second copy
    /// needs wiping.
    pub(crate) fn draft_body(&self, id: FileId) -> DraftBody {
        let Some(file) = self.file(id) else {
            return DraftBody::None;
        };
        if !file.dirty {
            return DraftBody::None;
        }
        // Dropped and not yet hydrated: the buffer is empty, so the record goes
        // back out as it came, not as an empty draft.
        if file.draft_dropped {
            return DraftBody::AlreadyDropped;
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
    /// Over [`DRAFT_SNAPSHOT_LIMIT`]; written without it.
    Oversized,
    /// Left out by an earlier save and not yet hydrated; no second notice.
    AlreadyDropped,
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

/// One settled read: normalized text and what a save needs back.
struct ReadFile {
    /// The saved baseline; zeroized when dropped.
    text: Zeroizing<String>,
    witness: FileWitness,
    line_ending: LineEnding,
    has_bom: bool,
}

/// Read, refuse, strip and normalize: where bytes become a buffer.
fn read_file(io: &dyn FileIo, path: &Path) -> Result<ReadFile, OpenRefusal> {
    for _ in 0..READ_ATTEMPTS {
        match read_once(io, path)? {
            Some(read) => return Ok(read),
            // Written mid-read: bytes and witness disagree, so read again.
            None => continue,
        }
    }
    // Rewritten faster than it reads: refuse rather than mismatch the witness.
    Err(OpenRefusal::Io(io::ErrorKind::Interrupted))
}

/// Reads tried against a file being rewritten before refusing.
const READ_ATTEMPTS: usize = 3;

/// One read between two stats; `None` when they disagree. The first stat
/// refuses oversize files before any read.
fn read_once(io: &dyn FileIo, path: &Path) -> Result<Option<ReadFile>, OpenRefusal> {
    let before = io.stat(path).map_err(|e| OpenRefusal::Io(e.kind()))?;
    if before.size > FILE_SIZE_LIMIT as u64 {
        return Err(OpenRefusal::TooLarge {
            limit: FILE_SIZE_LIMIT,
        });
    }
    let bytes = Zeroizing::new(io.read(path).map_err(|e| OpenRefusal::Io(e.kind()))?);
    let after = io.stat(path).map_err(|e| OpenRefusal::Io(e.kind()))?;
    if before != after {
        return Ok(None);
    }
    // A reader may return one byte past the limit.
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
    let text = Zeroizing::new(text.replace("\r\n", "\n"));
    Ok(Some(ReadFile {
        text,
        witness: after,
        line_ending,
        has_bom,
    }))
}

/// Any NUL, or two or more disallowed controls over ten percent of scalars.
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

/// A fresh stat against the witness. Any failure but absence is `Changed`,
/// so an unreadable path never licenses a save.
fn external_state(stat: &io::Result<FileWitness>, witness: Option<FileWitness>) -> ExternalState {
    match stat {
        Err(error) if error.kind() == io::ErrorKind::NotFound => ExternalState::Missing,
        Ok(fresh) if Some(*fresh) == witness => ExternalState::Unchanged,
        Err(_) | Ok(_) => ExternalState::Changed,
    }
}

/// Whether a refused read never reached the disk copy: any IO error but
/// `NotFound` (absent) and `Interrupted` (retries exhausted). Deliberately
/// broader than permission denial, so the record is held, not dropped.
fn refusal_is_unreachable(refusal: OpenRefusal) -> bool {
    matches!(
        refusal,
        OpenRefusal::Io(kind)
            if kind != io::ErrorKind::NotFound && kind != io::ErrorKind::Interrupted
    )
}

/// A save target resolved like any stored path. A missing file resolves by
/// its directory; an unresolvable path is used as given.
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

/// Whether the document holds exactly `expected`, without a full copy.
fn document_matches_text(document: &SheetDocument, expected: &str) -> bool {
    let mut remaining = expected;
    for run in document.runs() {
        match run {
            DocRun::Ink(ink) => {
                let Some(after) = remaining.strip_prefix(&ink) else {
                    return false;
                };
                remaining = after;
            }
            DocRun::Chip(_) => {
                let Some(after) = remaining.strip_prefix('\u{FFFC}') else {
                    return false;
                };
                remaining = after;
            }
        }
    }
    remaining.is_empty()
}

/// Write the buffer to `path` and settle the file around what landed.
fn write_and_settle(io: &dyn FileIo, file: &mut OpenFile, path: &Path) -> Result<(), SaveError> {
    let bytes = file.bytes_to_write_zeroizing();
    let witness = match io.write_atomic(path, &bytes) {
        Ok(witness) => witness,
        Err(error) => {
            // Only denial at the current path marks access refused.
            if path == file.path && error.kind() == io::ErrorKind::PermissionDenied {
                file.access_refused = true;
            }
            return Err(SaveError::Io(error.kind()));
        }
    };
    file.witness = Some(witness);
    file.saved_text = Some(Zeroizing::new(text_of(&file.document)));
    file.dirty = false;
    file.conflict = FileConflict::None;
    file.access_refused = false;
    file.not_found = false;
    file.restored_from_draft = false;
    file.active_take_theirs_generation = None;
    file.take_theirs_undone = false;
    file.overwrite_next_save = false;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::collections::HashMap;
    use std::sync::Mutex;

    /// An in-memory filesystem.
    #[derive(Default)]
    struct MemoryIo {
        files: Mutex<HashMap<PathBuf, Vec<u8>>>,
        /// Bumped per write, like a real mtime.
        tick: Mutex<i128>,
        stamps: Mutex<HashMap<PathBuf, i128>>,
        /// Symlinks, resolved by `canonicalize`.
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
        fn probe_readable(&self, path: &Path) -> io::Result<()> {
            self.stat(path).map(|_| ())
        }

        fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
            self.files
                .lock()
                .unwrap()
                .get(path)
                .cloned()
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
        }

        fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<FileWitness> {
            self.put(&path.to_string_lossy(), bytes);
            self.stat(path)
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

    /// Rewritten under every read, `shifts` times before it settles.
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
        fn probe_readable(&self, _path: &Path) -> io::Result<()> {
            Ok(())
        }

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

        fn write_atomic(&self, path: &Path, _bytes: &[u8]) -> io::Result<FileWitness> {
            self.stat(path)
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

    /// A non-regular path; records whether it was read anyway.
    #[derive(Default)]
    struct NonRegularIo {
        read_called: Cell<bool>,
    }

    impl FileIo for NonRegularIo {
        fn probe_readable(&self, path: &Path) -> io::Result<()> {
            self.stat(path).map(|_| ())
        }

        fn read(&self, _path: &Path) -> io::Result<Vec<u8>> {
            self.read_called.set(true);
            Ok(Vec::new())
        }

        fn write_atomic(&self, path: &Path, _bytes: &[u8]) -> io::Result<FileWitness> {
            self.stat(path)
        }

        fn stat(&self, _path: &Path) -> io::Result<FileWitness> {
            Err(io::Error::from(io::ErrorKind::InvalidInput))
        }
    }

    struct FaultIo {
        inner: MemoryIo,
        probe_error: Cell<Option<io::ErrorKind>>,
        write_error: Cell<Option<io::ErrorKind>>,
        reads: Cell<usize>,
        probes: Cell<usize>,
    }

    impl FaultIo {
        fn new() -> Self {
            Self {
                inner: MemoryIo::with("/note.txt", b"body"),
                probe_error: Cell::new(None),
                write_error: Cell::new(None),
                reads: Cell::new(0),
                probes: Cell::new(0),
            }
        }
    }

    impl FileIo for FaultIo {
        fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
            self.reads.set(self.reads.get() + 1);
            self.inner.read(path)
        }
        fn probe_readable(&self, path: &Path) -> io::Result<()> {
            self.probes.set(self.probes.get() + 1);
            match self.probe_error.get() {
                Some(kind) => Err(io::Error::from(kind)),
                None => self.inner.probe_readable(path),
            }
        }
        fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<FileWitness> {
            match self.write_error.get() {
                Some(kind) => Err(io::Error::from(kind)),
                None => self.inner.write_atomic(path, bytes),
            }
        }
        fn stat(&self, path: &Path) -> io::Result<FileWitness> {
            self.inner.stat(path)
        }
    }

    /// Stat claims more than the limit; records whether it was read anyway.
    #[derive(Default)]
    struct HugeIo {
        read_called: Cell<bool>,
    }

    impl FileIo for HugeIo {
        fn probe_readable(&self, _path: &Path) -> io::Result<()> {
            Ok(())
        }

        fn read(&self, _path: &Path) -> io::Result<Vec<u8>> {
            self.read_called.set(true);
            Ok(Vec::new())
        }

        fn write_atomic(&self, path: &Path, _bytes: &[u8]) -> io::Result<FileWitness> {
            self.stat(path)
        }

        fn stat(&self, _path: &Path) -> io::Result<FileWitness> {
            Ok(FileWitness {
                dev: 1,
                ino: 1,
                size: FILE_SIZE_LIMIT as u64 + 1,
                mtime_ns: 0,
            })
        }
    }

    #[test]
    fn an_oversized_file_is_refused_before_a_byte_of_it_is_read() {
        let io = HugeIo::default();
        let mut store = FileStore::new();
        assert_eq!(
            store.open(&io, Path::new("/huge.bin")),
            Err(OpenRefusal::TooLarge {
                limit: FILE_SIZE_LIMIT
            })
        );
        assert!(
            !io.read_called.get(),
            "the stat already knew the size, so nothing was read"
        );
    }

    /// Another writer renames over the file right after ours lands.
    struct ReplacedAfterWriteIo {
        inner: MemoryIo,
    }

    impl FileIo for ReplacedAfterWriteIo {
        fn probe_readable(&self, path: &Path) -> io::Result<()> {
            self.inner.probe_readable(path)
        }

        fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
            self.inner.read(path)
        }

        fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<FileWitness> {
            let ours = self.inner.write_atomic(path, bytes)?;
            self.inner
                .put(&path.to_string_lossy(), b"theirs, a moment later");
            Ok(ours)
        }

        fn stat(&self, path: &Path) -> io::Result<FileWitness> {
            self.inner.stat(path)
        }
    }

    #[test]
    fn a_save_takes_its_witness_from_the_write_and_not_from_the_path_afterwards() {
        let io = ReplacedAfterWriteIo {
            inner: MemoryIo::with("/note.txt", b"body"),
        };
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/note.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(0, "mine ")], 1));
        store.save(&io, id).unwrap();
        assert_eq!(
            store.refresh_conflict(&io, id),
            ExternalState::Changed,
            "the other writer's copy reads as a change"
        );
    }

    #[test]
    fn refresh_detects_new_read_denial_and_recovery_without_full_reads() {
        for dirty in [false, true] {
            let io = FaultIo::new();
            let mut store = FileStore::new();
            let id = store.open(&io, Path::new("/note.txt")).unwrap();
            if dirty {
                assert!(store.apply_ops(id, &[ins(0, "draft ")], 1));
            }
            let reads = io.reads.get();
            io.probe_error.set(Some(io::ErrorKind::PermissionDenied));
            assert_eq!(store.refresh_conflict(&io, id), ExternalState::Unchanged);
            let file = store.file(id).unwrap();
            assert!(file.access_refused());
            assert_eq!(
                file.conflict(),
                if dirty {
                    FileConflict::Changed
                } else {
                    FileConflict::None
                }
            );
            assert_eq!(store.refresh_conflict(&io, id), ExternalState::Unchanged);
            io.probe_error.set(None);
            assert_eq!(store.refresh_conflict(&io, id), ExternalState::Unchanged);
            assert!(!store.file(id).unwrap().access_refused());
            assert_eq!(store.file(id).unwrap().conflict(), FileConflict::None);
            assert_eq!(io.reads.get(), reads);
            assert_eq!(io.probes.get(), 3);
        }
    }

    #[test]
    fn an_interrupted_probe_is_inconclusive_and_does_not_clear_refused_access() {
        let io = FaultIo::new();
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/note.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(0, "draft ")], 1));
        io.probe_error.set(Some(io::ErrorKind::PermissionDenied));
        store.refresh_conflict(&io, id);
        io.probe_error.set(Some(io::ErrorKind::Interrupted));
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        assert!(store.file(id).unwrap().access_refused());
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::Changed);
    }

    #[test]
    fn probe_disappearance_sets_missing_not_access_refused() {
        let io = FaultIo::new();
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/note.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(0, "draft ")], 1));
        io.probe_error.set(Some(io::ErrorKind::NotFound));
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Missing);
        let file = store.file(id).unwrap();
        assert!(file.not_found());
        assert!(!file.access_refused());
        assert_eq!(file.conflict(), FileConflict::Missing);
    }

    #[test]
    fn only_write_access_denial_at_current_path_sets_access_refused() {
        for kind in [
            io::ErrorKind::PermissionDenied,
            io::ErrorKind::StorageFull,
            io::ErrorKind::CrossesDevices,
            io::ErrorKind::Other,
        ] {
            for save_as in [false, true] {
                let io = FaultIo::new();
                let mut store = FileStore::new();
                let id = store.open(&io, Path::new("/note.txt")).unwrap();
                assert!(store.apply_ops(id, &[ins(0, "draft ")], 1));
                io.write_error.set(Some(kind));
                let result = if save_as {
                    store.save_as(&io, id, Path::new("/elsewhere.txt"))
                } else {
                    store.save(&io, id)
                };
                assert_eq!(result, Err(SaveError::Io(kind)));
                let file = store.file(id).unwrap();
                assert_eq!(
                    file.access_refused(),
                    !save_as && kind == io::ErrorKind::PermissionDenied
                );
                assert!(file.is_dirty());
                assert_eq!(file.path(), Path::new("/note.txt"));
                assert_eq!(io.inner.bytes("/note.txt"), b"body");
            }
        }
    }

    #[test]
    fn read_unreachable_policy_is_deliberately_broader_than_access_denial() {
        for kind in [
            io::ErrorKind::PermissionDenied,
            io::ErrorKind::InvalidInput,
            io::ErrorKind::Other,
            io::ErrorKind::StorageFull,
        ] {
            assert!(refusal_is_unreachable(OpenRefusal::Io(kind)));
        }
        for refusal in [
            OpenRefusal::Io(io::ErrorKind::NotFound),
            OpenRefusal::Io(io::ErrorKind::Interrupted),
            OpenRefusal::NotUtf8,
            OpenRefusal::Binary,
            OpenRefusal::TooLarge {
                limit: FILE_SIZE_LIMIT,
            },
        ] {
            assert!(!refusal_is_unreachable(refusal));
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

        assert!(!store.can_undo(FileId(FILE_ID_TAG | 404)));
        assert!(!store.can_redo(FileId(FILE_ID_TAG | 404)));
        assert!(!store.can_undo(FileId(1)));
        assert!(!store.can_redo(FileId(1)));
    }

    #[test]
    fn a_file_paste_stands_between_typing_steps() {
        let io = MemoryIo::with("/paste.txt", b"");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/paste.txt")).unwrap();
        assert!(store.apply_ops_with_intent(id, &[ins(0, "a")], 1, EditIntent::Typing));
        assert!(store.apply_ops_with_intent(id, &[ins(1, "b")], 2, EditIntent::Paste));
        assert!(store.apply_ops_with_intent(id, &[ins(2, "c")], 3, EditIntent::Typing));

        assert_eq!(store.undo_action_name(id), Some("Typing"));
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "ab");
        assert_eq!(store.undo_action_name(id), Some("Paste"));
        assert_eq!(store.redo_action_name(id), Some("Typing"));
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "a");
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "");
    }

    #[test]
    fn a_file_step_restores_its_selection_in_both_directions() {
        let io = MemoryIo::with("/selection.txt", b"");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/selection.txt")).unwrap();
        assert!(store.apply_ops_with_intent_and_selection(
            id,
            &[ins(0, "word")],
            1,
            EditIntent::Typing,
            EditSelection {
                before: TextSelection {
                    location_u16: 0,
                    length_u16: 0,
                },
                after: TextSelection {
                    location_u16: 4,
                    length_u16: 0,
                },
            },
        ));

        let undone = store.undo(id).unwrap();
        assert_eq!(
            undone.selection_u16,
            Some(TextSelection {
                location_u16: 0,
                length_u16: 0,
            })
        );
        let redone = store.redo(id).unwrap();
        assert_eq!(
            redone.selection_u16,
            Some(TextSelection {
                location_u16: 4,
                length_u16: 0,
            })
        );
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

        // Typing after the undo retires the Take theirs marker.
        assert!(store.apply_ops(id, &[ins(4, "!")], 5_000));
        assert_eq!(store.text(id).unwrap(), "same!\n");
        assert!(store.is_dirty(id));
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "same\n");
        assert!(
            !store.is_dirty(id),
            "an unreachable generation marker stops pinning the file dirty"
        );

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

        assert!(store.apply_ops(id, &[ins(4, "!")], 2));
        assert!(!store.can_redo(id));
        assert!(store.is_dirty(id), "the typing itself is a real edit");

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

        assert!(!store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "");
        assert!(!store.is_dirty(id));

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
        // Check on activate, then again before the save.
        let io = MemoryIo::with("/k2.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k2.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/k2.txt", b"theirs");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        assert!(store.resolve_keep_mine(&io, id));

        let state = store.refresh_conflict(&io, id);
        assert_eq!(state, ExternalState::Unchanged, "the fresh witness matches");
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::None);
        store.save(&io, id).expect("keep mine then save must write");
        assert_eq!(io.bytes("/k2.txt"), b"one mine");
    }

    #[test]
    fn keep_mine_over_a_missing_file_still_saves() {
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

        assert!(store.apply_ops(id, &[ins(0, "more ")], 2));
        io.put("/k4.txt", b"and again");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::Changed);
        assert_eq!(store.save(&io, id), Err(SaveError::Conflict));
    }

    fn is_at(io: &MemoryIo, path: &str) -> bool {
        io.files.lock().unwrap().contains_key(Path::new(path))
    }

    #[test]
    fn keep_mine_over_a_changed_copy_does_not_license_recreating_a_file_deleted_afterwards() {
        let io = MemoryIo::with("/k5.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k5.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/k5.txt", b"theirs");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        assert!(store.resolve_keep_mine(&io, id));

        io.remove("/k5.txt");
        assert_eq!(store.save(&io, id), Err(SaveError::NotFound));
        assert!(!is_at(&io, "/k5.txt"), "nothing was recreated");
        let file = store.file(id).unwrap();
        assert!(file.not_found());
        assert!(file.is_dirty(), "the draft stands");
        assert_eq!(file.conflict(), FileConflict::Missing);
        assert_eq!(store.save(&io, id), Err(SaveError::Conflict));
        assert!(!is_at(&io, "/k5.txt"));

        assert!(store.resolve_keep_mine(&io, id));
        store
            .save(&io, id)
            .expect("this consent was for the deletion");
        assert_eq!(io.bytes("/k5.txt"), b"one mine");
    }

    #[test]
    fn a_check_withdraws_a_keep_mine_given_before_the_file_was_deleted() {
        let io = MemoryIo::with("/k6.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k6.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/k6.txt", b"theirs");
        store.refresh_conflict(&io, id);
        assert!(store.resolve_keep_mine(&io, id));

        io.remove("/k6.txt");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Missing);
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::Missing);
        assert_eq!(store.save(&io, id), Err(SaveError::Conflict));
        assert!(!is_at(&io, "/k6.txt"));
    }

    #[test]
    fn keep_mine_over_a_changed_copy_stays_dirty_when_undone_to_the_old_text() {
        let io = MemoryIo::with("/k7.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k7.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/k7.txt", b"theirs");
        store.refresh_conflict(&io, id);
        assert!(store.resolve_keep_mine(&io, id));

        assert!(store.undo(id).unwrap().applied);
        let file = store.file(id).unwrap();
        assert_eq!(file.text(), "one");
        assert!(file.is_dirty(), "the disk holds the other copy");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Unchanged);
        assert!(store.file(id).unwrap().is_dirty());
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::None);
        assert_eq!(io.bytes("/k7.txt"), b"theirs");

        // Typed back rather than undone.
        assert!(store.redo(id).unwrap().applied);
        assert!(store.apply_ops(id, &[del(3, 5)], 2));
        assert_eq!(store.file(id).unwrap().text(), "one");
        assert!(store.file(id).unwrap().is_dirty());
    }

    #[test]
    fn the_save_after_a_keep_mine_undone_to_the_old_text_writes_and_reads_clean() {
        let io = MemoryIo::with("/k13.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k13.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/k13.txt", b"theirs");
        store.refresh_conflict(&io, id);
        assert!(store.resolve_keep_mine(&io, id));
        assert!(store.undo(id).unwrap().applied);

        store.refresh_conflict(&io, id);
        store.save(&io, id).expect("the consent was for this save");
        assert_eq!(io.bytes("/k13.txt"), b"one");
        let file = store.file(id).unwrap();
        assert!(!file.is_dirty(), "the disk holds what the buffer holds");
        assert_eq!(file.conflict(), FileConflict::None);

        assert!(store.apply_ops(id, &[ins(3, "!")], 3));
        assert!(store.file(id).unwrap().is_dirty());
        assert!(store.undo(id).unwrap().applied);
        assert!(!store.file(id).unwrap().is_dirty());
    }

    #[test]
    fn a_keep_mine_undone_to_the_old_text_still_does_not_recreate_a_deleted_file() {
        let io = MemoryIo::with("/k14.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k14.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/k14.txt", b"theirs");
        store.refresh_conflict(&io, id);
        assert!(store.resolve_keep_mine(&io, id));
        assert!(store.undo(id).unwrap().applied);

        io.remove("/k14.txt");
        assert_eq!(store.save(&io, id), Err(SaveError::NotFound));
        assert!(!is_at(&io, "/k14.txt"), "nothing was recreated");
        let file = store.file(id).unwrap();
        assert!(file.not_found());
        assert!(file.is_dirty());
        assert_eq!(file.conflict(), FileConflict::Missing);
        assert_eq!(store.save(&io, id), Err(SaveError::Conflict));
        assert!(!is_at(&io, "/k14.txt"));
    }

    #[test]
    fn keep_mine_over_a_changed_copy_stays_dirty_across_a_take_theirs_marker() {
        // Redo lands on text the disk no longer holds.
        let io = MemoryIo::with("/k15.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k15.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.put("/k15.txt", b"theirs");
        store.refresh_conflict(&io, id);
        store.take_theirs(&io, id).unwrap();
        assert!(store.undo(id).unwrap().applied);
        assert!(store.file(id).unwrap().is_dirty());

        io.put("/k15.txt", b"a third copy");
        assert_eq!(store.refresh_conflict(&io, id), ExternalState::Changed);
        assert!(store.resolve_keep_mine(&io, id));
        assert!(store.redo(id).unwrap().applied);
        let file = store.file(id).unwrap();
        assert_eq!(file.text(), "theirs");
        assert!(file.is_dirty(), "the disk holds a third copy");

        store.save(&io, id).unwrap();
        assert_eq!(io.bytes("/k15.txt"), b"theirs");
        assert!(!store.file(id).unwrap().is_dirty());
    }

    #[test]
    fn keep_mine_with_the_witness_still_matching_keeps_the_saved_text() {
        let io = MemoryIo::with("/k16.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k16.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        assert!(store.resolve_keep_mine(&io, id));
        assert!(store.undo(id).unwrap().applied);
        assert!(!store.file(id).unwrap().is_dirty());
    }

    #[test]
    fn a_keep_mine_over_a_missing_file_is_withdrawn_when_the_buffer_is_undone_back_to_clean() {
        let io = MemoryIo::with("/k11.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k11.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.remove("/k11.txt");
        store.refresh_conflict(&io, id);
        assert!(store.resolve_keep_mine(&io, id));

        assert!(store.undo(id).unwrap().applied);
        assert!(!store.file(id).unwrap().is_dirty());
        assert_eq!(store.save(&io, id), Err(SaveError::NotFound));
        assert!(!is_at(&io, "/k11.txt"), "nothing was recreated");

        // Typed back rather than undone.
        let io = MemoryIo::with("/k12.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k12.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, "!")], 1));
        io.remove("/k12.txt");
        store.refresh_conflict(&io, id);
        assert!(store.resolve_keep_mine(&io, id));
        assert!(store.apply_ops(id, &[del(3, 1)], 2));
        assert!(!store.file(id).unwrap().is_dirty());
        assert_eq!(store.save(&io, id), Err(SaveError::NotFound));
        assert!(!is_at(&io, "/k12.txt"));
    }

    #[test]
    fn keep_mine_over_a_missing_file_does_not_license_overwriting_one_that_appears() {
        let io = MemoryIo::with("/k8.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k8.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.remove("/k8.txt");
        store.refresh_conflict(&io, id);
        assert!(store.resolve_keep_mine(&io, id));

        io.put("/k8.txt", b"somebody else's");
        assert_eq!(store.save(&io, id), Err(SaveError::Conflict));
        assert_eq!(io.bytes("/k8.txt"), b"somebody else's");
        let file = store.file(id).unwrap();
        assert!(!file.not_found());
        assert_eq!(file.conflict(), FileConflict::Changed);

        assert!(store.resolve_keep_mine(&io, id));
        store.save(&io, id).unwrap();
        assert_eq!(io.bytes("/k8.txt"), b"one mine");
    }

    #[test]
    fn keep_mine_on_a_missing_conflict_whose_file_is_back_asks_the_true_question() {
        let io = MemoryIo::with("/k9.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k9.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.remove("/k9.txt");
        store.refresh_conflict(&io, id);
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::Missing);

        io.put("/k9.txt", b"rewritten");
        assert!(
            !store.resolve_keep_mine(&io, id),
            "the banner answered was not the state of the disk"
        );
        let file = store.file(id).unwrap();
        assert_eq!(file.conflict(), FileConflict::Changed);
        assert!(!file.not_found());
        assert_eq!(store.save(&io, id), Err(SaveError::Conflict));
        assert_eq!(io.bytes("/k9.txt"), b"rewritten");

        let io = MemoryIo::with("/k10.txt", b"one");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/k10.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(3, " mine")], 1));
        io.remove("/k10.txt");
        store.refresh_conflict(&io, id);
        io.files
            .lock()
            .unwrap()
            .insert(PathBuf::from("/k10.txt"), b"one".to_vec());
        assert!(store.resolve_keep_mine(&io, id));
        assert_eq!(store.file(id).unwrap().conflict(), FileConflict::None);
        store.save(&io, id).unwrap();
        assert_eq!(io.bytes("/k10.txt"), b"one mine");
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
        let io = MemoryIo::with("/real.txt", b"body");
        io.link("/link.txt", "/real.txt");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/link.txt")).unwrap();
        assert_eq!(store.file(id).unwrap().path(), Path::new("/real.txt"));
        assert_eq!(store.file(id).unwrap().name(), "real.txt");

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
    fn a_closed_files_draft_does_not_come_back_when_it_is_reopened() {
        let io = MemoryIo::with("/c3.txt", b"body");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/c3.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(0, "draft ")], 1));
        assert!(store.close(id));
        let again = store.open(&io, Path::new("/c3.txt")).unwrap();
        let file = store.file(again).unwrap();
        assert_eq!(file.text(), "body");
        assert!(!file.is_dirty());
        assert_eq!(io.bytes("/c3.txt"), b"body");
    }

    #[test]
    fn a_refused_reload_keeps_a_dirty_buffers_draft() {
        let io = MemoryIo::with("/r3.txt", b"body");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/r3.txt")).unwrap();
        assert!(store.apply_ops(id, &[ins(0, "draft ")], 1));
        io.put("/r3.txt", &[0x66, 0xFF, 0xFE]);
        assert_eq!(store.reload(&io, id), Err(OpenRefusal::NotUtf8));
        io.remove("/r3.txt");
        assert!(store.reload(&io, id).is_err());
        let file = store.file(id).unwrap();
        assert_eq!(file.text(), "draft body");
        assert!(file.is_dirty());
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
