//! The working set: nine sheets, never a thousand rows of history.
//!
//! Rev C (doc 04): the unit is the sheet — ink plus sealed chips, one
//! pausable countdown per page. What a page did is recorded in the
//! [`ledger`] as metadata; the page itself, ink and sealed bytes alike,
//! is gone. The cap is the keyboard wall.
//!
//! [`ledger`]: crate::ledger

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::blocks::BlockIndex;
use crate::clock::Clock;
use crate::document::SheetDocument;
use crate::ledger::{DestinationClass, LedgerEvent, LedgerRecord, SizeClass, evict_expired};
use crate::sheet::{
    ChipId, ChipMeta, ItemId, Promotion, SealedChip, Segment, Sheet, SheetClock, SheetId,
    TITLE_CAP, derive_title,
};
use crate::ttl::Ttl;

/// The sheet cap: 9, the natural limit of the keyboard map (⌘1–⌘9;
/// ⌘0 belongs to the ledger). At the wall the store *refuses* the tenth
/// and says so — silent eviction of deliberately placed content would
/// break trust (doc 03 §5); eviction is by the countdown the user chose,
/// never LRU surprise. Whether 9 is too generous is open question №4;
/// the constant stays easy to lower.
pub const DEFAULT_SHEET_CAP: usize = 9;

/// The first double-click holds a page's clock for one hour…
const HOLD_FIRST: Duration = Duration::from_secs(60 * 60);
/// …and every further double-click tops the hold up to 24 hours from
/// now — never cumulative (doc 04).
const HOLD_TOPUP: Duration = Duration::from_secs(24 * 60 * 60);

/// Why the store refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// The working set is full; let a page expire, or close one.
    AtCapacity {
        /// The configured cap.
        cap: usize,
    },
    /// Nothing to seal (empty text or zero-byte image).
    EmptyContent,
    /// No such page.
    UnknownSheet,
    /// The seal gesture named a range the page's body does not have:
    /// out of bounds, or a boundary inside a surrogate pair. Nothing
    /// was sealed and nothing moved.
    InvalidRange,
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Refusal::AtCapacity { cap } => write!(
                f,
                "the window holds {cap} pages — let one expire, or close one"
            ),
            Refusal::EmptyContent => write!(f, "nothing to seal"),
            Refusal::UnknownSheet => write!(f, "no such page"),
            Refusal::InvalidRange => write!(f, "the selection no longer matches the page"),
        }
    }
}

impl std::error::Error for Refusal {}

/// Why a sheet could not be assembled into a promotion payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PayloadError {
    /// No such sheet.
    UnknownSheet,
    /// The sheet holds an image chip; the v3 conceal payload is
    /// text-shaped (open question №3 — image promotion is unresolved,
    /// so the core refuses rather than guesses).
    ImageChip,
}

impl std::fmt::Display for PayloadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PayloadError::UnknownSheet => write!(f, "no such page"),
            PayloadError::ImageChip => write!(
                f,
                "this page holds an image, which cannot travel as a text secret yet"
            ),
        }
    }
}

impl std::error::Error for PayloadError {}

/// One edit against a sheet's body (ADR-0013): the operation shape the
/// shell sends instead of a whole-document snapshot. Every position and
/// length is a count of UTF-16 code units, the only offset unit the
/// wire speaks, measured against the body as it stands when this op's
/// turn in the batch comes, so a later op legally describes the state
/// its predecessors made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditOp {
    /// Insert ink at a position.
    Insert {
        /// UTF-16 code unit offset of the insertion point.
        pos_u16: u32,
        /// The ink to insert.
        text: String,
    },
    /// Delete a range of the body, ink and chip sentinels alike.
    Delete {
        /// UTF-16 code unit offset where the deletion starts.
        pos_u16: u32,
        /// Length of the deletion in UTF-16 code units.
        len_u16: u32,
    },
    /// Place a sealed chip's sentinel at a position. The chip must be
    /// owned by the sheet, and its sentinel must not already stand in
    /// the simulated body when this op's turn comes.
    InsertChip {
        /// UTF-16 code unit offset of the sentinel.
        pos_u16: u32,
        /// The chip whose sentinel goes here.
        chip: ChipId,
    },
}

/// The in-memory sheet store. Everything in it — sheets, chips, and
/// the ledger — dies with the process, with one deliberate exception:
/// the shell may ask for the whole store as a plaintext snapshot at
/// quit and hand one back at launch ([`crate::persist`]), and the seam
/// above encrypts it before anything touches disk. Nothing here writes
/// a byte on its own.
pub struct SheetStore<C: Clock> {
    pub(crate) clock: C,
    pub(crate) sheets: Vec<Sheet>,
    /// The audit trail, newest first. Append-only from the store's side
    /// (the user may clear it whole), bounded by a rolling 90 day window
    /// on wall-clock time rather than by a record count: see
    /// [`evict_expired`]. The window is swept on append, on load
    /// ([`SheetStore::restore_ledger`]), and on the write path
    /// ([`SheetStore::evict_ledger`]). Append alone is not enough: a
    /// session can run for months without recording anything.
    pub(crate) ledger: VecDeque<LedgerRecord>,
    pub(crate) cap: usize,
    pub(crate) default_rung: Ttl,
    pub(crate) next_sheet_id: u64,
    pub(crate) next_chip_id: u64,
}

impl<C: Clock> SheetStore<C> {
    /// A store reading time from `clock`, with the default cap and rung.
    #[must_use]
    pub fn new(clock: C) -> Self {
        Self {
            clock,
            sheets: Vec::new(),
            ledger: VecDeque::new(),
            cap: DEFAULT_SHEET_CAP,
            default_rung: Ttl::default(),
            next_sheet_id: 1,
            next_chip_id: 1,
        }
    }

    /// Override the cap (still refuse-don't-evict).
    #[must_use]
    pub fn with_cap(mut self, cap: usize) -> Self {
        self.cap = cap;
        self
    }

    /// Override the default rung for new pages (settings surface).
    #[must_use]
    pub fn with_default_rung(mut self, rung: Ttl) -> Self {
        self.default_rung = rung;
        self
    }

    // -----------------------------------------------------------------
    // Sheets: create, close, order
    // -----------------------------------------------------------------

    /// A new page at the end of the tab strip, on the default rung, its
    /// countdown started. Refuses at the cap.
    pub fn new_sheet(&mut self) -> Result<SheetId, Refusal> {
        if self.sheets.len() >= self.cap {
            return Err(Refusal::AtCapacity { cap: self.cap });
        }
        let now = self.clock.now();
        // A page names itself the moment it exists, so no record can
        // ever reach the ledger without a title already on it.
        let created_wall_ms = self.clock.wall_ms();
        let offset = self.clock.local_offset_seconds();
        let id = SheetId(self.next_sheet_id);
        self.next_sheet_id += 1;
        let uuid = ItemId::random();
        let title = derive_title(&[], created_wall_ms, offset);
        let document = SheetDocument::new();
        let blocks = BlockIndex::for_document(&document);
        self.sheets.push(Sheet {
            id,
            uuid,
            title: title.clone(),
            title_is_user_set: false,
            created_wall_ms,
            document,
            segments: Vec::new(),
            blocks,
            chips: Vec::new(),
            rung: self.default_rung,
            clock: SheetClock::Running {
                deadline: now + self.default_rung.duration(),
            },
            total_held: Duration::ZERO,
        });
        self.record(
            LedgerEvent::Created,
            uuid,
            title,
            created_wall_ms,
            SizeClass::Tiny,
            DestinationClass::None,
        );
        Ok(id)
    }

    /// Close a page: its sealed bytes zeroize on the way out and the
    /// ledger keeps one `Discarded` record of the fact. Returns whether
    /// the page existed.
    pub fn close_sheet(&mut self, id: SheetId) -> bool {
        let Some(index) = self.sheets.iter().position(|s| s.id == id) else {
            return false;
        };
        let sheet = self.sheets.remove(index);
        self.entomb(sheet, LedgerEvent::Discarded);
        true
    }

    /// Move a page to `index` in the visible order (drag-to-reorder;
    /// the ⌘-number map follows). Out-of-range indices clamp to the
    /// end. Returns whether the page existed.
    pub fn move_sheet(&mut self, id: SheetId, index: usize) -> bool {
        let Some(from) = self.sheets.iter().position(|s| s.id == id) else {
            return false;
        };
        let sheet = self.sheets.remove(from);
        let to = index.min(self.sheets.len());
        self.sheets.insert(to, sheet);
        true
    }

    /// The pages, in visible (tab) order.
    pub fn sheets(&self) -> impl Iterator<Item = &Sheet> {
        self.sheets.iter()
    }

    /// A page by id.
    #[must_use]
    pub fn sheet(&self, id: SheetId) -> Option<&Sheet> {
        self.sheets.iter().find(|s| s.id == id)
    }

    fn sheet_mut(&mut self, id: SheetId) -> Option<&mut Sheet> {
        self.sheets.iter_mut().find(|s| s.id == id)
    }

    /// Number of live pages.
    #[must_use]
    pub fn len(&self) -> usize {
        self.sheets.len()
    }

    /// True when no pages exist — the system working, not failing.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.sheets.is_empty()
    }

    /// The cap.
    #[must_use]
    pub fn cap(&self) -> usize {
        self.cap
    }

    /// The store's clock reading, for rendering.
    #[must_use]
    pub fn now(&self) -> Instant {
        self.clock.now()
    }

    // -----------------------------------------------------------------
    // Sealing — the gesture routes land here
    // -----------------------------------------------------------------

    /// Seal text onto a page. The excerpt is computed here, once,
    /// mechanically; the bytes go into locked, zeroizing memory and
    /// never render. Returns the chip id.
    pub fn seal_text(&mut self, sheet: SheetId, text: &str) -> Result<ChipId, Refusal> {
        if text.is_empty() {
            return Err(Refusal::EmptyContent);
        }
        if self.sheet(sheet).is_none() {
            return Err(Refusal::UnknownSheet);
        }
        let id = ChipId(self.next_chip_id);
        self.next_chip_id += 1;
        let chip = SealedChip::text(id, text);
        let uuid = chip.uuid;
        let host = self.sheet_mut(sheet).expect("checked above");
        host.chips.push(chip);
        let (title, created) = (host.title.clone(), host.created_wall_ms);
        self.record(
            LedgerEvent::Sealed,
            uuid,
            title,
            created,
            SizeClass::of(text.len()),
            DestinationClass::None,
        );
        Ok(id)
    }

    /// Seal image bytes onto a page (encoded, as delivered). The chip's
    /// face is clipboard metadata only.
    pub fn seal_image(&mut self, sheet: SheetId, bytes: Vec<u8>) -> Result<ChipId, Refusal> {
        if bytes.is_empty() {
            return Err(Refusal::EmptyContent);
        }
        if self.sheet(sheet).is_none() {
            return Err(Refusal::UnknownSheet);
        }
        let id = ChipId(self.next_chip_id);
        self.next_chip_id += 1;
        let size = SizeClass::of(bytes.len());
        let chip = SealedChip::image(id, bytes);
        let uuid = chip.uuid;
        let host = self.sheet_mut(sheet).expect("checked above");
        host.chips.push(chip);
        let (title, created) = (host.title.clone(), host.created_wall_ms);
        self.record(
            LedgerEvent::Sealed,
            uuid,
            title,
            created,
            size,
            DestinationClass::None,
        );
        Ok(id)
    }

    /// Seal text onto a page and stand its chip in the body in one
    /// atomic call (ADR-0013): the given UTF-16 range is deleted from
    /// the document, the sentinel takes its place, and the change
    /// commits. A non-empty range is the selection the gesture replaced,
    /// deleted here rather than by a shell edit, so the seal and the
    /// deletion cannot come apart. The range validates before anything
    /// seals: a range the body does not have refuses whole with
    /// [`Refusal::InvalidRange`] and mints no chip.
    pub fn seal_text_at(
        &mut self,
        sheet: SheetId,
        text: &str,
        at_u16: u32,
        len_u16: u32,
    ) -> Result<ChipId, Refusal> {
        self.seal_text_at_with_origin(sheet, text, at_u16, len_u16, None)
    }

    /// [`SheetStore::seal_text_at`] carrying provenance: `origin`, when
    /// present, is stamped on the seal's own commit as its persisted
    /// message (ADR-0013), so it lives inside the encrypted snapshot
    /// and nowhere else — the seam's read surfaces never render commit
    /// messages, and the ledger records none of this. Riding the seal's
    /// commit rather than a staged next-commit message means a refused
    /// seal drops the origin by construction instead of leaving it to
    /// stamp whatever commits next.
    pub fn seal_text_at_with_origin(
        &mut self,
        sheet: SheetId,
        text: &str,
        at_u16: u32,
        len_u16: u32,
        origin: Option<&str>,
    ) -> Result<ChipId, Refusal> {
        self.check_seal_range(sheet, at_u16, len_u16)?;
        let chip = self.seal_text(sheet, text)?;
        self.place_chip(sheet, chip, at_u16, len_u16, origin)
    }

    /// [`SheetStore::seal_text_at`] for image bytes: same atomic
    /// replace, same refuse-whole range validation.
    pub fn seal_image_at(
        &mut self,
        sheet: SheetId,
        bytes: Vec<u8>,
        at_u16: u32,
        len_u16: u32,
    ) -> Result<ChipId, Refusal> {
        self.seal_image_at_with_origin(sheet, bytes, at_u16, len_u16, None)
    }

    /// [`SheetStore::seal_image_at`] carrying provenance, under the
    /// same rules as [`SheetStore::seal_text_at_with_origin`].
    pub fn seal_image_at_with_origin(
        &mut self,
        sheet: SheetId,
        bytes: Vec<u8>,
        at_u16: u32,
        len_u16: u32,
        origin: Option<&str>,
    ) -> Result<ChipId, Refusal> {
        self.check_seal_range(sheet, at_u16, len_u16)?;
        let chip = self.seal_image(sheet, bytes)?;
        self.place_chip(sheet, chip, at_u16, len_u16, origin)
    }

    /// Whether a seal gesture's range describes the page's body as it
    /// stands: in bounds, and neither boundary inside a surrogate pair.
    /// Judged against the cached projection in exact code units, the
    /// same discipline [`SheetStore::apply_ops`] validates with.
    fn check_seal_range(&self, id: SheetId, at_u16: u32, len_u16: u32) -> Result<(), Refusal> {
        let Some(sheet) = self.sheet(id) else {
            return Err(Refusal::UnknownSheet);
        };
        let units = sim_units(&sheet.segments);
        let at = at_u16 as usize;
        let Some(end) = at.checked_add(len_u16 as usize) else {
            return Err(Refusal::InvalidRange);
        };
        if end > units.len()
            || splits_surrogate_pair(&units, at)
            || splits_surrogate_pair(&units, end)
        {
            return Err(Refusal::InvalidRange);
        }
        Ok(())
    }

    /// The placement half of a range seal: delete the replaced range,
    /// stand the sentinel, commit, settle. The range was validated
    /// before the chip was minted, so the document cannot refuse here;
    /// should it refuse anyway, the settle reaps the placeless chip
    /// (zeroized, with its `Discarded` record) and the call fails
    /// closed instead of reporting a chip that is not on the page.
    fn place_chip(
        &mut self,
        id: SheetId,
        chip: ChipId,
        at_u16: u32,
        len_u16: u32,
        origin: Option<&str>,
    ) -> Result<ChipId, Refusal> {
        let Some(sheet) = self.sheet_mut(id) else {
            return Err(Refusal::UnknownSheet);
        };
        let uuid = sheet
            .chip(chip)
            .expect("the chip was sealed onto this sheet a moment ago")
            .uuid();
        let at = at_u16 as usize;
        let mut clean = sheet.document.delete(at, len_u16 as usize).is_ok();
        if clean {
            clean = sheet.document.insert_chip(at, uuid).is_ok();
        }
        // Narrate the replace to the block index: a selection that
        // swallowed a newline merges paragraphs exactly as typing over
        // it would, and the sentinel is one unit of ordinary width. On
        // a refusal the notes may misdescribe the body, and the settle
        // detects that and rebuilds rather than trusting them.
        sheet.blocks.note_delete(at, len_u16 as usize);
        sheet.blocks.note_sentinel(at);
        // The origin, when a paste carried one, persists as this
        // commit's message: provenance attaches to the event, where
        // editing cannot erode it, and travels only inside the sealed
        // snapshot.
        sheet.document.commit(origin);
        self.settle_document(id);
        if clean {
            Ok(chip)
        } else {
            Err(Refusal::InvalidRange)
        }
    }

    // -----------------------------------------------------------------
    // The document: operations, and the transitional snapshot adapter
    // -----------------------------------------------------------------

    /// Apply a batch of edits to a page's body. This is the operation
    /// path ADR-0013 replaces snapshot syncing with: the document
    /// mutates in place, and provenance rides on the ops instead of
    /// dying in a wholesale resync.
    ///
    /// The batch validates as a whole before the document is touched.
    /// Each op is checked against the simulated state its predecessors
    /// produce (a running body of code units and a live-chip set,
    /// updated op by op), because the shell coalesces edits: a delete
    /// and insert at one position, or a delete spanning a chip followed
    /// by that chip's re-insert, are routine batches and must validate.
    /// Any op that misses the simulated state, whether an out-of-range
    /// offset, a boundary inside a surrogate pair, a chip the sheet
    /// does not own, or a sentinel that would stand twice, rejects the
    /// whole batch and mutates nothing.
    ///
    /// A batch that applies commits as one change. The segments
    /// projection then rebuilds, the title re-derives unless the user
    /// named the page, and any chip whose sentinel is gone from the
    /// body is zeroized with the same `Discarded` record the snapshot
    /// path writes. Returns whether the batch applied.
    pub fn apply_ops(&mut self, id: SheetId, ops: &[EditOp]) -> bool {
        let Some(sheet) = self.sheet_mut(id) else {
            return false;
        };
        // Phase one: the whole batch against a simulation, so that
        // rejection is atomic. The simulation carries exact code units,
        // which is what lets it police surrogate-pair boundaries as
        // strictly as the document would.
        let mut sim = sim_units(&sheet.segments);
        for op in ops {
            if !sim_admit(&mut sim, &sheet.chips, op) {
                return false;
            }
        }
        // Phase two: the document. The simulation validated every
        // offset against exact post-op state, so these calls cannot
        // refuse; should one somehow refuse anyway, applying stops and
        // the settle below keeps the projection honest about whatever
        // did land, with the false return telling the shell to restate
        // the page through the recovery path.
        let mut clean = true;
        for op in ops {
            let outcome = match op {
                EditOp::Insert { pos_u16, text } => sheet.document.insert(*pos_u16 as usize, text),
                EditOp::Delete { pos_u16, len_u16 } => {
                    sheet.document.delete(*pos_u16 as usize, *len_u16 as usize)
                }
                EditOp::InsertChip { pos_u16, chip } => {
                    let uuid = sheet
                        .chip(*chip)
                        .expect("phase one admits only owned chips")
                        .uuid();
                    sheet.document.insert_chip(*pos_u16 as usize, uuid)
                }
            };
            if outcome.is_err() {
                clean = false;
                break;
            }
            // Narrate the op to the block index while its offsets are
            // still current: a newline in an insert splits a paragraph
            // and a delete across one merges, and identity survives
            // exactly the edits that stay inside a block (ADR-0013).
            match op {
                EditOp::Insert { pos_u16, text } => {
                    sheet.blocks.note_insert(*pos_u16 as usize, text);
                }
                EditOp::Delete { pos_u16, len_u16 } => {
                    sheet
                        .blocks
                        .note_delete(*pos_u16 as usize, *len_u16 as usize);
                }
                EditOp::InsertChip { pos_u16, .. } => {
                    sheet.blocks.note_sentinel(*pos_u16 as usize);
                }
            }
        }
        sheet.document.commit(None);
        self.settle_document(id);
        clean
    }

    /// Replace a page's body wholesale from a shell snapshot. A
    /// transitional adapter (ADR-0013): the document is wiped and
    /// retyped from the incoming segments, so every character's
    /// provenance collapses to this moment and means nothing. Edits
    /// travel as operations ([`SheetStore::apply_ops`]); once the shell
    /// speaks them (stage 3), this path remains only as the recovery
    /// route for restating a whole page.
    ///
    /// The snapshot is **authoritative for chip liveness**: a chip of
    /// this sheet that the snapshot no longer references was deleted in
    /// the editor (⌫ removes it whole), and its bytes are zeroized here
    /// — undo never un-seals (open question №5). A snapshot referencing
    /// a chip this sheet does not own, or the same chip twice, is
    /// malformed and rejected whole. Returns whether the snapshot was
    /// accepted.
    #[expect(
        clippy::needless_pass_by_value,
        reason = "the segments used to move into the sheet; the signature outlives that so callers of the recovery path stay untouched while stage 3 rebuilds the seam"
    )]
    pub fn sync_document(&mut self, id: SheetId, segments: Vec<Segment>) -> bool {
        let Some(sheet) = self.sheet_mut(id) else {
            return false;
        };
        let mut referenced: Vec<ChipId> = Vec::new();
        for segment in &segments {
            if let Segment::Chip(chip_id) = segment {
                if referenced.contains(chip_id) || sheet.chip(*chip_id).is_none() {
                    return false;
                }
                referenced.push(*chip_id);
            }
        }
        // Wipe and retype: the body becomes exactly the snapshot, chips
        // re-marked under their existing identities. A full-range
        // delete and appends at the running end cannot miss, so refusal
        // here is unreachable; fail closed anyway and let the settle
        // keep the projection honest.
        let len = sheet.document.utf16_len();
        let mut clean = sheet.document.delete(0, len).is_ok();
        if clean {
            let mut pos = 0usize;
            for segment in &segments {
                let outcome = match segment {
                    Segment::Ink(text) => {
                        let inserted = sheet.document.insert(pos, text);
                        pos += text.encode_utf16().count();
                        inserted
                    }
                    Segment::Chip(chip_id) => {
                        let uuid = sheet.chip(*chip_id).expect("validated above").uuid();
                        let inserted = sheet.document.insert_chip(pos, uuid);
                        pos += 1;
                        inserted
                    }
                };
                if outcome.is_err() {
                    clean = false;
                    break;
                }
            }
        }
        sheet.document.commit(None);
        self.settle_document(id);
        clean
    }

    /// The invariant every document mutation restores: the segments
    /// projection mirrors the document, the title is current, and no
    /// sealed chip outlives its sentinel.
    fn settle_document(&mut self, id: SheetId) {
        // Read the clock before the mutable borrow of the sheet.
        let offset = self.clock.local_offset_seconds();
        let Some(sheet) = self.sheet_mut(id) else {
            return;
        };
        sheet.rebuild_segments();
        // The block index settles against the document: anchors are
        // re-taken, and an index the mutation path failed to narrate —
        // a wholesale restate through `sync_document`, or a mid-batch
        // refusal — is rebuilt with fresh identities rather than served
        // stale (ADR-0013).
        sheet.settle_blocks();
        // The title is re-derived here, on edit, and never later: by
        // the time a record reaches the ledger the page already knows
        // its name (ADR-0012).
        if !sheet.title_is_user_set {
            sheet.title = derive_title(&sheet.segments, sheet.created_wall_ms, offset);
        }
        // Chips the document no longer holds die now (zeroize on drop).
        // A chip removed with ⌫ is as gone as one removed by
        // `delete_chip`, so it leaves the same record.
        let live = sheet.document.live_chips();
        let mut dropped: Vec<(ItemId, usize)> = Vec::new();
        sheet.chips.retain(|chip| {
            let alive = live.contains(&chip.uuid);
            if !alive {
                dropped.push((chip.uuid, chip.bytes.len()));
            }
            alive
        });
        let title = sheet.title.clone();
        let created = sheet.created_wall_ms;
        for (uuid, len) in dropped {
            self.record(
                LedgerEvent::Discarded,
                uuid,
                title.clone(),
                created,
                SizeClass::of(len),
                DestinationClass::None,
            );
        }
    }

    /// Set a page's title explicitly. An empty or all-whitespace title
    /// clears the override and re-derives from the page's content;
    /// anything else is capped at 80 characters and is never overwritten
    /// by re-derivation afterwards (ADR-0012). Returns whether the page
    /// existed.
    pub fn set_title(&mut self, id: SheetId, title: &str) -> bool {
        let offset = self.clock.local_offset_seconds();
        let Some(sheet) = self.sheet_mut(id) else {
            return false;
        };
        let trimmed = title.trim();
        if trimmed.is_empty() {
            sheet.title_is_user_set = false;
            sheet.title = derive_title(&sheet.segments, sheet.created_wall_ms, offset);
        } else {
            sheet.title_is_user_set = true;
            sheet.title = trimmed.chars().take(TITLE_CAP).collect();
        }
        true
    }

    // -----------------------------------------------------------------
    // Chips: copy-out, delete, promotion
    // -----------------------------------------------------------------

    fn chip_home(&self, id: ChipId) -> Option<(SheetId, &SealedChip)> {
        self.sheets
            .iter()
            .find_map(|s| s.chip(id).map(|c| (s.id, c)))
    }

    /// Copy a chip's bytes back out, with what they are. Copy-out does
    /// **not** consume the chip — multi-paste is a core moment (doc 01).
    /// The returned buffer zeroizes on drop; hand it to the pasteboard
    /// and let it fall.
    #[must_use]
    pub fn copy_out_chip(&self, id: ChipId) -> Option<(Zeroizing<Vec<u8>>, ChipMeta)> {
        let (_, chip) = self.chip_home(id)?;
        Some((Zeroizing::new(chip.bytes.expose().to_vec()), chip.meta))
    }

    /// Remove a chip now, wherever it sits; its bytes are wiped as it
    /// drops, and the document snapshot forgets its position. There is
    /// no resurrection path (open question №5: undo never un-seals).
    /// Returns whether the chip existed.
    pub fn delete_chip(&mut self, id: ChipId) -> bool {
        let mut removed: Option<(ItemId, usize, String, u64)> = None;
        for sheet in &mut self.sheets {
            let Some(index) = sheet.chips.iter().position(|c| c.id == id) else {
                continue;
            };
            let chip = &sheet.chips[index];
            let uuid = chip.uuid;
            removed = Some((
                uuid,
                chip.bytes.len(),
                sheet.title.clone(),
                sheet.created_wall_ms,
            ));
            // The sentinel leaves the document first, so the source of
            // truth forgets the position before the bytes die. A chip
            // sealed but never placed has no sentinel to remove. One
            // sentinel is one unit of block width and never a newline,
            // so the block index narrates it as an intra-block edit.
            if let Some(pos) = sheet.document.chip_position(uuid) {
                let _ = sheet.document.delete(pos, 1);
                sheet.document.commit(None);
                sheet.blocks.note_delete(pos, 1);
            }
            sheet.chips.remove(index); // zeroizes as it drops
            sheet.rebuild_segments();
            sheet.settle_blocks();
            break;
        }
        let Some((uuid, len, title, created)) = removed else {
            return false;
        };
        self.record(
            LedgerEvent::Discarded,
            uuid,
            title,
            created,
            SizeClass::of(len),
            DestinationClass::None,
        );
        true
    }

    /// Record that a chip's bytes left for `destination`. Copy-out
    /// itself is a `&self` read ([`SheetStore::copy_out_chip`]) and
    /// stays that way, so the caller that actually lands the bytes
    /// somewhere reports it here. Egress to the pasteboard is the single
    /// most useful line in the ledger (ADR-0012). Returns whether the
    /// chip existed.
    pub fn record_sent(&mut self, chip: ChipId, destination: DestinationClass) -> bool {
        let Some((sheet_id, sealed)) = self.chip_home(chip) else {
            return false;
        };
        let uuid = sealed.uuid;
        let size = SizeClass::of(sealed.bytes.len());
        let host = self.sheet(sheet_id).expect("chip_home found it");
        let title = host.title.clone();
        let created = host.created_wall_ms;
        self.record(LedgerEvent::Sent, uuid, title, created, size, destination);
        true
    }

    /// Record that a whole page's bytes left for `destination`. The
    /// page-level twin of [`SheetStore::record_sent`]: promoting a page
    /// ([`SheetStore::sheet_payload`]) is the largest egress this app
    /// performs, so it leaves the same kind of line the chip path and
    /// the pasteboard path leave. Without it the ledger's `sent` claim
    /// would be silently incomplete (ADR-0012).
    ///
    /// The record carries the page's own [`ItemId`] and the title the
    /// page already owned; nothing is derived from ink here. The size
    /// class is the page's sealed byte total, the same figure
    /// [`SheetStore::close_sheet`] and [`SheetStore::expire_due`] record,
    /// and the stamp is the wall clock, as for every other record.
    /// Returns whether the page existed.
    pub fn record_sheet_sent(&mut self, sheet: SheetId, destination: DestinationClass) -> bool {
        let Some(page) = self.sheet(sheet) else {
            return false;
        };
        let uuid = page.uuid;
        let title = page.title.clone();
        let created = page.created_wall_ms;
        let sealed_bytes: usize = page.chips.iter().map(|c| c.bytes.len()).sum();
        self.record(
            LedgerEvent::Sent,
            uuid,
            title,
            created,
            SizeClass::of(sealed_bytes),
            destination,
        );
        true
    }

    /// Record a successful promotion: only the receipt identifier stays
    /// on the live chip (no link, no history — doc 03 §5).
    pub fn mark_chip_promoted(&mut self, id: ChipId, receipt_id: String) -> bool {
        for sheet in &mut self.sheets {
            if let Some(chip) = sheet.chips.iter_mut().find(|c| c.id == id) {
                chip.promotion = Some(Promotion { receipt_id });
                return true;
            }
        }
        false
    }

    /// A chip's bytes for the promotion path (core → network client
    /// directly, never through the UI layer — the boundary law).
    #[must_use]
    pub fn chip_payload(&self, id: ChipId) -> Option<Zeroizing<Vec<u8>>> {
        self.copy_out_chip(id).map(|(bytes, _)| bytes)
    }

    /// The whole page as one promotion payload: ink verbatim, sealed
    /// bytes inlined where their chips sit, in document order. Refuses
    /// pages holding image chips — the v3 conceal payload is
    /// text-shaped.
    pub fn sheet_payload(&self, id: SheetId) -> Result<Zeroizing<String>, PayloadError> {
        let sheet = self.sheet(id).ok_or(PayloadError::UnknownSheet)?;
        if sheet
            .chips
            .iter()
            .any(|c| matches!(c.meta, ChipMeta::Image { .. }))
        {
            return Err(PayloadError::ImageChip);
        }
        // Preallocate the full payload: growing the string reallocates,
        // and reallocation strands sealed bytes in freed, unwiped heap.
        // One exact-size buffer means the one Zeroizing wipe covers
        // everything the payload ever touched.
        let total: usize = sheet
            .segments
            .iter()
            .map(|segment| match segment {
                Segment::Ink(text) => text.len(),
                Segment::Chip(chip_id) => sheet.chip(*chip_id).map_or(0, |c| c.bytes.len()),
            })
            .sum();
        let mut out = Zeroizing::new(String::with_capacity(total));
        for segment in &sheet.segments {
            match segment {
                Segment::Ink(text) => out.push_str(text),
                Segment::Chip(chip_id) => {
                    if let Some(chip) = sheet.chip(*chip_id)
                        && let Ok(text) = std::str::from_utf8(chip.bytes.expose())
                    {
                        out.push_str(text);
                    }
                }
            }
        }
        Ok(out)
    }

    // -----------------------------------------------------------------
    // Time: the ladder, the pause, the one armed timer
    // -----------------------------------------------------------------

    /// Cycle a page's countdown label: next rung on the ladder, clock
    /// *reset* to the full rung value (doc 04 — each click resets the
    /// clock to the shown rung). A held page keeps its hold; the frozen
    /// remaining life resets to the new rung — the pause is the tab's
    /// lever, the countdown the header's. A **due** page refuses, like
    /// [`SheetStore::pause_press`]: zero means zeroized, and a click in
    /// the sliver before the timer reaps must not resurrect it. Returns
    /// the new rung.
    pub fn cycle_rung(&mut self, id: SheetId) -> Option<Ttl> {
        let now = self.clock.now();
        let sheet = self.sheet_mut(id)?;
        normalize(sheet, now);
        if sheet.remaining(now).is_zero() {
            return None; // due; the timer will reap it
        }
        let rung = sheet.rung.next();
        set_clock(sheet, rung, now);
        Some(rung)
    }

    /// Set a page to a specific rung, resetting the clock to it. A due
    /// page refuses (see [`SheetStore::cycle_rung`]).
    pub fn set_rung(&mut self, id: SheetId, rung: Ttl) -> Option<Ttl> {
        let now = self.clock.now();
        let sheet = self.sheet_mut(id)?;
        normalize(sheet, now);
        if sheet.remaining(now).is_zero() {
            return None; // due; the timer will reap it
        }
        set_clock(sheet, rung, now);
        Some(rung)
    }

    /// The pause gesture (double-click a tab): the first press holds
    /// the page's clock for **1 hour**; a press while held tops the
    /// hold up to **24 hours from now** — never cumulative. While held,
    /// remaining life does not drain. A hold lapses on its own; the
    /// page is simply a regular page again. A pause holds the clock; it
    /// never extends the rung. Returns false for an unknown or
    /// already-expired page.
    pub fn pause_press(&mut self, id: SheetId) -> bool {
        let now = self.clock.now();
        let Some(sheet) = self.sheet_mut(id) else {
            return false;
        };
        normalize(sheet, now);
        match sheet.clock {
            SheetClock::Running { deadline } => {
                let remaining = deadline.saturating_duration_since(now);
                if remaining.is_zero() {
                    return false; // due; the timer will reap it
                }
                sheet.clock = SheetClock::Held {
                    until: now + HOLD_FIRST,
                    frozen_remaining: remaining,
                    started: now,
                };
            }
            SheetClock::Held {
                frozen_remaining,
                started,
                ..
            } => {
                sheet.clock = SheetClock::Held {
                    until: now + HOLD_TOPUP,
                    frozen_remaining,
                    started,
                };
            }
        }
        true
    }

    /// The earliest instant anything changes — a page expiring, or a
    /// hold lapsing (the ⏸ clears and the gauge resumes: a visible
    /// change). This is the **only** timer the shell ever arms. `None`
    /// means nothing to schedule: no timers ticking, no wakeups
    /// (doc 05 frugality budget).
    #[must_use]
    pub fn next_event(&self) -> Option<Instant> {
        let now = self.clock.now();
        self.sheets
            .iter()
            .map(|s| match s.clock {
                SheetClock::Running { deadline } => deadline,
                SheetClock::Held {
                    until,
                    frozen_remaining,
                    ..
                } => {
                    if now < until {
                        until
                    } else {
                        until + frozen_remaining
                    }
                }
            })
            .min()
    }

    /// Settle the clock: lapsed holds become regular pages again, and
    /// every page whose countdown has reached zero is moved to the
    /// ledger, its sealed bytes zeroized. Returns the expired ids (the
    /// shell drops them from view silently; the user set the clock).
    /// Call when the armed timer fires, then re-arm from
    /// [`SheetStore::next_event`].
    pub fn expire_due(&mut self) -> Vec<SheetId> {
        let now = self.clock.now();
        for sheet in &mut self.sheets {
            normalize(sheet, now);
        }
        let (dead, live): (Vec<Sheet>, Vec<Sheet>) = std::mem::take(&mut self.sheets)
            .into_iter()
            .partition(|s| s.remaining(now).is_zero());
        self.sheets = live;
        let ids: Vec<SheetId> = dead.iter().map(|s| s.id).collect();
        for sheet in dead {
            self.entomb(sheet, LedgerEvent::Expired);
        }
        ids
    }

    // -----------------------------------------------------------------
    // The ledger
    // -----------------------------------------------------------------

    /// The audit trail, newest first: metadata and the page-owned title,
    /// never content.
    pub fn ledger(&self) -> impl Iterator<Item = &LedgerRecord> {
        self.ledger.iter()
    }

    /// Take the retention window off the ledger as of `now_wall_ms`
    /// (Unix epoch milliseconds), dropping every record older than the
    /// 90 day bound ([`evict_expired`]). Returns how many records fell
    /// off.
    ///
    /// The append path already evicts while the ledger is in hand, but
    /// append is not a bound on its own: a menu-bar app stays up for
    /// weeks, and a user who staged a page on day 0 and since then only
    /// edits ink in existing pages never records another event, so
    /// nothing sweeps the tail. The title is the ledger's one residual
    /// exposure and the time window is the only thing that shrinks it,
    /// so the persistence seam calls this immediately before
    /// [`SheetStore::ledger_snapshot`] — which takes `&self` and so
    /// cannot evict on its own — and the debounced write then persists a
    /// ledger that is actually inside the window (ADR-0012).
    pub fn evict_ledger(&mut self, now_wall_ms: u64) -> usize {
        let before = self.ledger.len();
        evict_expired(&mut self.ledger, now_wall_ms);
        before - self.ledger.len()
    }

    /// Throw the whole ledger away. The user-facing "clear the ledger"
    /// affordance: the records are the only thing that outlives a boot
    /// session, so a way to end them on demand is part of the bargain.
    pub fn clear_ledger(&mut self) {
        self.ledger.clear();
    }

    /// Append one record, newest first, and take the retention window
    /// off the tail while the ledger is already in hand
    /// ([`evict_expired`]).
    fn record(
        &mut self,
        event: LedgerEvent,
        item: ItemId,
        title: String,
        item_created_wall_ms: u64,
        size: SizeClass,
        destination: DestinationClass,
    ) {
        let at_wall_ms = self.clock.wall_ms();
        self.ledger.push_front(LedgerRecord {
            event,
            item,
            title,
            at_wall_ms,
            item_created_wall_ms,
            size,
            destination,
        });
        evict_expired(&mut self.ledger, at_wall_ms);
    }

    /// Record the page's death and drop it. Every chip's bytes zeroize
    /// as it falls. One record for the page, whatever it was carrying:
    /// the chips on it already have records of their own, from the
    /// moment they were sealed. A page with nothing on it (no chips, no
    /// non-blank ink) records nothing: it did nothing worth auditing.
    #[expect(
        clippy::needless_pass_by_value,
        reason = "consuming is the point: the page dies here, and its SecretBuffers zeroize as it drops"
    )]
    fn entomb(&mut self, sheet: Sheet, event: LedgerEvent) {
        let has_ink = sheet.segments.iter().any(|s| match s {
            Segment::Ink(text) => !text.trim().is_empty(),
            Segment::Chip(_) => false,
        });
        if !has_ink && sheet.chips.is_empty() {
            return;
        }
        // The inversion (ADR-0012): the ledger copies a name the page
        // already owned. Nothing is derived from ink at death, and no
        // ink, excerpt or byte count crosses into the record.
        let sealed_bytes: usize = sheet.chips.iter().map(|c| c.bytes.len()).sum();
        self.record(
            event,
            sheet.uuid,
            sheet.title.clone(),
            sheet.created_wall_ms,
            SizeClass::of(sealed_bytes),
            DestinationClass::None,
        );
        // `sheet` drops here; every SecretBuffer zeroizes on the way down.
    }
}

/// A lapsed hold becomes a regular page again — no notification, no
/// state to clean up (doc 04). The held span is added to the page's
/// total (open question №8 accounting).
fn normalize(sheet: &mut Sheet, now: Instant) {
    if let SheetClock::Held {
        until,
        frozen_remaining,
        started,
    } = sheet.clock
        && now >= until
    {
        sheet.total_held += until.saturating_duration_since(started);
        sheet.clock = SheetClock::Running {
            deadline: until + frozen_remaining,
        };
    }
}

/// One position of the simulated body [`SheetStore::apply_ops`]
/// validates against: a UTF-16 code unit of ink, or a chip's sentinel.
/// Carrying the actual code units is what lets the simulation refuse a
/// boundary inside a surrogate pair exactly where the document would.
#[derive(Clone, Copy, PartialEq, Eq)]
enum SimUnit {
    /// One UTF-16 code unit of ink.
    Code(u16),
    /// A sealed chip's sentinel, one code unit wide.
    Chip(ChipId),
}

/// The simulated body a batch starts from: the cached projection,
/// flattened to code units.
fn sim_units(segments: &[Segment]) -> Vec<SimUnit> {
    let mut units = Vec::new();
    for segment in segments {
        match segment {
            Segment::Ink(text) => units.extend(text.encode_utf16().map(SimUnit::Code)),
            Segment::Chip(id) => units.push(SimUnit::Chip(*id)),
        }
    }
    units
}

/// Whether `pos` falls between the two halves of a surrogate pair,
/// which is the one interior offset no valid edit may name.
fn splits_surrogate_pair(units: &[SimUnit], pos: usize) -> bool {
    if pos == 0 || pos >= units.len() {
        return false;
    }
    matches!(
        (units[pos - 1], units[pos]),
        (SimUnit::Code(high), SimUnit::Code(low))
            if (0xD800..=0xDBFF).contains(&high) && (0xDC00..=0xDFFF).contains(&low)
    )
}

/// Validate one op against the simulated body and, when it holds,
/// advance the simulation past it, so the next op is judged against the
/// state this one made. `chips` is the sheet's ownership roster: a chip
/// from elsewhere never validates.
fn sim_admit(units: &mut Vec<SimUnit>, chips: &[SealedChip], op: &EditOp) -> bool {
    match op {
        EditOp::Insert { pos_u16, text } => {
            let pos = *pos_u16 as usize;
            if pos > units.len() || splits_surrogate_pair(units, pos) {
                return false;
            }
            units.splice(pos..pos, text.encode_utf16().map(SimUnit::Code));
            true
        }
        EditOp::Delete { pos_u16, len_u16 } => {
            let pos = *pos_u16 as usize;
            let Some(end) = pos.checked_add(*len_u16 as usize) else {
                return false;
            };
            if end > units.len()
                || splits_surrogate_pair(units, pos)
                || splits_surrogate_pair(units, end)
            {
                return false;
            }
            units.drain(pos..end);
            true
        }
        EditOp::InsertChip { pos_u16, chip } => {
            let pos = *pos_u16 as usize;
            if pos > units.len() || splits_surrogate_pair(units, pos) {
                return false;
            }
            if chips.iter().all(|owned| owned.id() != *chip) {
                return false; // foreign: this sheet holds no such chip
            }
            if units.contains(&SimUnit::Chip(*chip)) {
                return false; // duplicate: the sentinel already stands
            }
            units.insert(pos, SimUnit::Chip(*chip));
            true
        }
    }
}

/// Reset a (normalized) page's clock to the full value of `rung`.
fn set_clock(sheet: &mut Sheet, rung: Ttl, now: Instant) {
    sheet.rung = rung;
    match &mut sheet.clock {
        SheetClock::Running { deadline } => *deadline = now + rung.duration(),
        SheetClock::Held {
            frozen_remaining, ..
        } => *frozen_remaining = rung.duration(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;
    use crate::ledger::LEDGER_RETENTION_MS;

    fn store() -> (SheetStore<ManualClock>, ManualClock) {
        let clock = ManualClock::new();
        (SheetStore::new(clock.clone()), clock)
    }

    const HOUR: Duration = Duration::from_secs(60 * 60);

    /// The placeholder title a page created on a fresh [`ManualClock`]
    /// is born with: 2023-11-14 22:13:20, in the clock's UTC locale.
    const PLACEHOLDER: &str = "1114-2213";

    fn seal(store: &mut SheetStore<ManualClock>, sheet: SheetId, text: &str) -> ChipId {
        store.seal_text(sheet, text).unwrap()
    }

    /// Every recorded event, newest first.
    fn events(store: &SheetStore<ManualClock>) -> Vec<LedgerEvent> {
        store.ledger().map(LedgerRecord::event).collect()
    }

    #[test]
    fn new_sheets_append_in_tab_order_on_the_default_rung() {
        let (mut store, _) = store();
        let first = store.new_sheet().unwrap();
        let second = store.new_sheet().unwrap();
        let order: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(order, vec![first, second]);
        let sheet = store.sheet(first).unwrap();
        assert_eq!(sheet.rung(), Ttl::default());
        assert_eq!(sheet.remaining_label(store.now()), "8h");
    }

    #[test]
    fn refuses_the_tenth_page_instead_of_evicting() {
        let (mut store, _) = store();
        for _ in 0..DEFAULT_SHEET_CAP {
            store.new_sheet().unwrap();
        }
        let err = store.new_sheet().unwrap_err();
        assert_eq!(
            err,
            Refusal::AtCapacity {
                cap: DEFAULT_SHEET_CAP
            }
        );
        assert_eq!(store.len(), DEFAULT_SHEET_CAP);
        // The refusal says so, in words a tab strip can show.
        assert!(err.to_string().contains('9'));
    }

    #[test]
    fn sealing_refuses_empty_content_and_unknown_sheets() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert_eq!(store.seal_text(id, ""), Err(Refusal::EmptyContent));
        assert_eq!(store.seal_image(id, Vec::new()), Err(Refusal::EmptyContent));
        assert_eq!(
            store.seal_text(SheetId(999), "x"),
            Err(Refusal::UnknownSheet)
        );
    }

    #[test]
    fn sealed_chips_carry_the_mechanical_face() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, "correct horse battery staple!!");
        let sheet = store.sheet(id).unwrap();
        let sealed = sheet.chip(chip).unwrap();
        assert_eq!(sealed.size_label(), "30 ch");
        assert!(sealed.excerpt().contains('…'));
        assert_eq!(sheet.chip_count(), 1);
    }

    #[test]
    fn sync_rejects_foreign_and_duplicate_chips() {
        let (mut store, _) = store();
        let a = store.new_sheet().unwrap();
        let b = store.new_sheet().unwrap();
        let chip_a = seal(&mut store, a, "belongs to a");
        // Foreign chip: b may not claim a's chip.
        assert!(!store.sync_document(b, vec![Segment::Chip(chip_a)]));
        // Duplicate reference is malformed.
        assert!(!store.sync_document(a, vec![Segment::Chip(chip_a), Segment::Chip(chip_a)]));
        // The rejected syncs changed nothing.
        assert_eq!(store.sheet(a).unwrap().chip_count(), 1);
        // A well-formed snapshot is accepted.
        assert!(store.sync_document(
            a,
            vec![
                Segment::Ink("dsn for the migration\n".into()),
                Segment::Chip(chip_a)
            ]
        ));
        assert_eq!(store.sheet(a).unwrap().title(), "dsn for the migration");
    }

    #[test]
    fn a_fresh_page_is_titled_by_its_creation_stamp() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        let sheet = store.sheet(id).unwrap();
        assert_eq!(sheet.title(), PLACEHOLDER);
        assert!(!sheet.title_is_user_set());
        assert_eq!(sheet.created_wall_ms(), 1_700_000_000_000);

        // The stamp is the page's birthday, not the current time: an
        // hour later the placeholder still reads the same.
        clock.advance(HOUR);
        assert!(store.sync_document(id, vec![Segment::Ink("   ".into())]));
        assert_eq!(store.sheet(id).unwrap().title(), PLACEHOLDER);
    }

    #[test]
    fn a_page_renames_itself_from_the_first_typed_line() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.sync_document(
            id,
            vec![Segment::Ink("## prod DB credentials\nrotate after".into())]
        ));
        assert_eq!(store.sheet(id).unwrap().title(), "prod DB credentials");
        assert!(!store.sheet(id).unwrap().title_is_user_set());
    }

    #[test]
    fn a_user_title_survives_every_re_derivation() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.set_title(id, "  the vault  "));
        let sheet = store.sheet(id).unwrap();
        assert_eq!(sheet.title(), "the vault", "trimmed, not stored raw");
        assert!(sheet.title_is_user_set());

        // Editing the page does not take the name back.
        assert!(store.sync_document(id, vec![Segment::Ink("something else\n".into())]));
        assert_eq!(store.sheet(id).unwrap().title(), "the vault");

        // Nor does closing it: the ledger copies what the page owned.
        assert!(store.close_sheet(id));
        assert_eq!(store.ledger().next().unwrap().title(), "the vault");
    }

    #[test]
    fn an_empty_set_title_hands_the_name_back_to_derivation() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.sync_document(id, vec![Segment::Ink("derived name\n".into())]));
        assert!(store.set_title(id, "chosen name"));
        assert_eq!(store.sheet(id).unwrap().title(), "chosen name");

        assert!(store.set_title(id, "   "));
        let sheet = store.sheet(id).unwrap();
        assert!(!sheet.title_is_user_set());
        assert_eq!(sheet.title(), "derived name");

        // And with no ink at all, back to the creation stamp.
        assert!(store.sync_document(id, Vec::new()));
        assert_eq!(store.sheet(id).unwrap().title(), PLACEHOLDER);
        assert!(!store.set_title(SheetId(999), "nowhere"));
    }

    #[test]
    fn a_user_title_is_capped_like_a_derived_one() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.set_title(id, &"é".repeat(200)));
        assert_eq!(store.sheet(id).unwrap().title().chars().count(), 80);
    }

    #[test]
    fn a_sync_that_omits_a_chip_zeroizes_it() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, "deleted in the editor");
        assert!(store.sync_document(id, vec![Segment::Chip(chip)]));
        // ⌫ removed the chip; the next snapshot no longer references it.
        assert!(store.sync_document(id, vec![Segment::Ink("just ink now".into())]));
        assert_eq!(store.sheet(id).unwrap().chip_count(), 0);
        assert!(store.copy_out_chip(chip).is_none(), "no resurrection path");
    }

    #[test]
    fn delete_chip_removes_it_whole() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, "one ⌫ removes it whole");
        assert!(store.sync_document(id, vec![Segment::Chip(chip)]));
        assert!(store.delete_chip(chip));
        assert!(!store.delete_chip(chip), "already gone");
        assert!(store.sheet(id).unwrap().segments().is_empty());
    }

    #[test]
    fn copy_out_does_not_consume_the_chip() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, "multi-paste me");
        for _ in 0..3 {
            let (bytes, meta) = store.copy_out_chip(chip).unwrap();
            assert_eq!(&**bytes, b"multi-paste me");
            assert!(matches!(meta, ChipMeta::Text { .. }));
        }
        assert_eq!(store.sheet(id).unwrap().chip_count(), 1);
    }

    #[test]
    fn expiry_is_scheduled_not_polled() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        store.set_rung(id, Ttl::MIN).unwrap(); // 1h

        let deadline = store.next_event().unwrap();
        assert_eq!(deadline - store.now(), HOUR);

        clock.advance(HOUR - Duration::from_secs(1));
        assert!(store.expire_due().is_empty());

        clock.advance(Duration::from_secs(1));
        assert_eq!(store.expire_due(), vec![id]);
        assert!(store.is_empty());
        assert_eq!(store.next_event(), None, "nothing left to arm");
    }

    /// A token chosen so that no run of four or more of its characters
    /// can plausibly appear in a record's `Debug` rendering for an
    /// innocent reason: mixed case, no English words, and never four
    /// digits in a row (an `ItemId` prints its bytes as decimals).
    const TOKEN: &str = "Zq7Xv-Marmalade-Bt94kL-Wp2Rn";

    /// An origin URL shaped like the worst case: a reset link carrying
    /// a token in its query string. Origin URLs are content (ADR-0013),
    /// so the ledger's claim covers every fragment of this too.
    const ORIGIN_URL: &str = "https://origin.example.test/reset?tk=Vq9Zx-Chutney-Rt83mN";

    /// Every contiguous run of `token`, four characters or longer.
    /// Testing whole-token absence would be trivially satisfiable by a
    /// truncating excerpt; this is the assertion that is hard to weaken.
    fn fragments_of(token: &str) -> Vec<String> {
        let chars: Vec<char> = token.chars().collect();
        let mut out = Vec::new();
        for start in 0..chars.len() {
            for end in (start + 4)..=chars.len() {
                out.push(chars[start..end].iter().collect());
            }
        }
        assert!(out.len() > 300, "the fragment set must be exhaustive");
        out
    }

    /// The ledger's whole claim, mechanised: no record, in any field,
    /// may carry a fragment of what was sealed, and none of where it
    /// came from either.
    fn assert_content_free(store: &SheetStore<ManualClock>) {
        let mut fragments = fragments_of(TOKEN);
        fragments.extend(fragments_of(ORIGIN_URL));
        let mut checked = 0usize;
        for record in store.ledger() {
            let rendered = format!("{record:?}");
            for fragment in &fragments {
                assert!(
                    !rendered.contains(fragment.as_str()),
                    "ledger record leaked {fragment:?} of sealed content: {rendered}"
                );
            }
            checked += 1;
        }
        assert!(
            checked > 0,
            "nothing was checked; the walk found no records"
        );
    }

    #[test]
    fn a_dead_page_leaves_metadata_and_nothing_else() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, TOKEN);
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink("### deploy friday\nin order\n".into()),
                Segment::Chip(chip),
            ]
        ));
        // Drive the page through the whole lifecycle, so every kind of
        // record the store can write is in the ledger when we look.
        let (bytes, _) = store.copy_out_chip(chip).unwrap();
        assert_eq!(&**bytes, TOKEN.as_bytes());
        drop(bytes);
        assert!(store.record_sent(chip, DestinationClass::Clipboard));
        let uuid = store.sheet(id).unwrap().uuid();
        store.set_rung(id, Ttl::MIN).unwrap();
        clock.advance(HOUR);
        store.expire_due();

        let record = store.ledger().next().unwrap();
        assert_eq!(record.event(), LedgerEvent::Expired);
        assert_eq!(record.title(), "deploy friday");
        assert_eq!(record.item(), uuid, "the page's own identity");
        assert_ne!(record.item(), ItemId::from_bytes([0u8; 16]));
        assert_eq!(record.size(), SizeClass::of(TOKEN.len()));
        assert_eq!(record.destination(), DestinationClass::None);

        // The load-bearing assertion.
        assert_eq!(store.ledger().count(), 4, "created, sealed, sent, expired");
        assert_content_free(&store);
    }

    #[test]
    fn a_sealed_chip_is_content_free_in_the_ledger_from_the_moment_it_exists() {
        // Not only at death: the Sealed record is written while the
        // bytes are still live and reachable, which is exactly when a
        // convenience excerpt would be tempting.
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, TOKEN);
        assert_content_free(&store);
        assert!(store.delete_chip(chip));
        assert_content_free(&store);
    }

    #[test]
    fn closing_a_page_records_the_page_and_the_chip_separately() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let _chip = seal(&mut store, id, "sealed then never synced");
        assert!(store.close_sheet(id));
        assert!(!store.close_sheet(id), "already gone");

        assert_eq!(
            events(&store),
            vec![
                LedgerEvent::Discarded,
                LedgerEvent::Sealed,
                LedgerEvent::Created
            ]
        );
        let page = store.ledger().next().unwrap();
        // No ink was ever typed, so the page kept the name it was born
        // with: its creation stamp, in local time.
        assert_eq!(page.title(), PLACEHOLDER);
        // A chip sealed but never synced is still accounted for: its own
        // record was written at seal time and outlives the page.
        let chip_record = store.ledger().nth(1).unwrap();
        assert_ne!(chip_record.item(), page.item());
        assert_eq!(
            chip_record.size(),
            SizeClass::of("sealed then never synced".len())
        );
        assert_eq!(chip_record.title(), PLACEHOLDER, "the host page's name");
    }

    #[test]
    fn empty_pages_leave_no_death_record() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.sync_document(id, vec![Segment::Ink("   \n".into())]));
        store.close_sheet(id);
        // The page's birth is on the record; its death is not, because
        // a page that held nothing did nothing worth auditing.
        assert_eq!(events(&store), vec![LedgerEvent::Created]);
    }

    #[test]
    fn the_ledger_is_a_rolling_window_not_a_record_cap() {
        let (mut store, clock) = store();
        for i in 0..50 {
            let id = store.new_sheet().unwrap();
            assert!(store.sync_document(id, vec![Segment::Ink(format!("page {i}"))]));
            assert!(store.close_sheet(id));
        }
        // A hundred records, none of them old. A count cap would have
        // thrown most of these away; the window keeps every one.
        assert_eq!(store.ledger().count(), 100);
        let titles: Vec<&str> = store.ledger().map(LedgerRecord::title).collect();
        assert_eq!(titles.first(), Some(&"page 49"), "newest first");

        // Ninety days and one millisecond later the whole lot has aged
        // out, and the next write is what sweeps it: no timer runs.
        clock.advance(Duration::from_millis(LEDGER_RETENTION_MS + 1));
        assert_eq!(store.ledger().count(), 100, "nothing ran on its own");
        store.new_sheet().unwrap();
        assert_eq!(events(&store), vec![LedgerEvent::Created]);
    }

    #[test]
    fn the_window_boundary_keeps_a_record_exactly_ninety_days_old() {
        let (mut store, clock) = store();
        store.new_sheet().unwrap();
        clock.advance(Duration::from_millis(LEDGER_RETENTION_MS));
        store.new_sheet().unwrap();
        assert_eq!(store.ledger().count(), 2, "the boundary is inclusive");
        clock.advance(Duration::from_millis(1));
        store.new_sheet().unwrap();
        assert_eq!(store.ledger().count(), 2, "the oldest fell off");
    }

    #[test]
    fn every_lifecycle_step_lands_exactly_one_record() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert_eq!(events(&store), vec![LedgerEvent::Created]);

        let chip = seal(&mut store, id, "one secret");
        assert_eq!(
            events(&store),
            vec![LedgerEvent::Sealed, LedgerEvent::Created]
        );

        // Reading the bytes out is a `&self` call and records nothing on
        // its own; the caller that lands them somewhere reports it.
        let _ = store.copy_out_chip(chip).unwrap();
        assert_eq!(store.ledger().count(), 2);

        assert!(store.record_sent(chip, DestinationClass::Clipboard));
        let sent = store.ledger().next().unwrap();
        assert_eq!(sent.event(), LedgerEvent::Sent);
        assert_eq!(sent.destination(), DestinationClass::Clipboard);
        assert_eq!(sent.size(), SizeClass::of("one secret".len()));
        assert!(!store.record_sent(ChipId(999), DestinationClass::Clipboard));

        assert!(store.close_sheet(id));
        assert_eq!(
            events(&store),
            vec![
                LedgerEvent::Discarded,
                LedgerEvent::Sent,
                LedgerEvent::Sealed,
                LedgerEvent::Created
            ]
        );
    }

    #[test]
    fn promoting_a_whole_page_lands_one_content_free_sent_record() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, TOKEN);
        // The token sits in the ink as well as in the chip, and never on
        // the first line: the title is the one field allowed to be
        // content-derived, and this test is about the other six.
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink(format!("rotate on friday\n{TOKEN}\n")),
                Segment::Chip(chip),
            ]
        ));
        let page = store.sheet(id).unwrap();
        let uuid = page.uuid();
        // The payload that leaves is ink plus sealed bytes; the record's
        // size class is the sealed total, as at death.
        assert!(store.sheet_payload(id).unwrap().contains(TOKEN));

        assert!(store.record_sheet_sent(id, DestinationClass::OneTimeLink));
        let record = store.ledger().next().unwrap();
        assert_eq!(record.event(), LedgerEvent::Sent);
        assert_eq!(record.destination(), DestinationClass::OneTimeLink);
        assert_eq!(record.item(), uuid, "the page's own identity");
        assert_eq!(record.title(), "rotate on friday");
        assert_eq!(record.size(), SizeClass::of(TOKEN.len()));
        assert_eq!(record.item_created_wall_ms(), 1_700_000_000_000);
        assert_eq!(record.at_wall_ms(), 1_700_000_000_000);

        // The load-bearing assertion: the largest egress this app can
        // perform leaves no fragment of what it moved.
        assert_content_free(&store);

        // The page is still live; recording a send is not a death.
        assert_eq!(store.len(), 1);
        assert!(
            !store.record_sheet_sent(SheetId(999), DestinationClass::OneTimeLink),
            "no such page"
        );
    }

    #[test]
    fn a_chip_removed_in_the_editor_records_the_same_as_an_explicit_delete() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, "removed with a backspace");
        assert!(store.sync_document(id, vec![Segment::Chip(chip)]));
        assert!(store.sync_document(id, vec![Segment::Ink("just ink now".into())]));
        assert_eq!(
            events(&store),
            vec![
                LedgerEvent::Discarded,
                LedgerEvent::Sealed,
                LedgerEvent::Created
            ]
        );
    }

    #[test]
    fn clearing_the_ledger_leaves_nothing_behind() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        seal(&mut store, id, "something");
        assert!(store.ledger().count() > 0);
        store.clear_ledger();
        assert_eq!(store.ledger().count(), 0);
        // The live page is untouched: clearing the ledger is not closing
        // anything.
        assert_eq!(store.len(), 1);
        assert_eq!(store.sheet(id).unwrap().chip_count(), 1);
    }

    #[test]
    fn a_hold_freezes_the_clock_and_lapses_on_its_own() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap(); // 8h
        clock.advance(2 * HOUR); // 6h remain

        assert!(store.pause_press(id));
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(sheet.is_held(now));
        assert_eq!(sheet.remaining(now), 6 * HOUR);

        // While held, remaining life does not drain.
        clock.advance(HOUR / 2);
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(sheet.is_held(now));
        assert_eq!(sheet.remaining(now), 6 * HOUR);
        assert_eq!(sheet.hold_remaining(now), HOUR / 2);

        // The hold lapses; the page is a regular page again, draining
        // from where it froze.
        clock.advance(HOUR);
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(!sheet.is_held(now));
        assert_eq!(sheet.remaining(now), 6 * HOUR - HOUR / 2);
    }

    #[test]
    fn pause_presses_go_one_hour_then_topup_to_twentyfour_never_cumulative() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();

        assert!(store.pause_press(id)); // hold: 1h
        assert_eq!(store.sheet(id).unwrap().hold_remaining(store.now()), HOUR);

        assert!(store.pause_press(id)); // extend: 24h from now
        assert_eq!(
            store.sheet(id).unwrap().hold_remaining(store.now()),
            24 * HOUR
        );

        // 23 hours later, a third press tops back up to 24h from now —
        // not 47h. Never cumulative.
        clock.advance(23 * HOUR);
        assert!(store.pause_press(id));
        assert_eq!(
            store.sheet(id).unwrap().hold_remaining(store.now()),
            24 * HOUR
        );
    }

    #[test]
    fn a_lapsed_hold_restarts_the_ladder_at_one_hour() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.pause_press(id)); // 1h hold
        clock.advance(2 * HOUR); // lapses
        assert!(store.pause_press(id)); // a fresh first press again
        assert_eq!(store.sheet(id).unwrap().hold_remaining(store.now()), HOUR);
    }

    #[test]
    fn the_one_timer_covers_hold_lapses_too() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap(); // 8h
        assert!(store.pause_press(id)); // hold lapses in 1h; expiry at 1h+8h
        let now = store.now();
        assert_eq!(
            store.next_event().unwrap() - now,
            HOUR,
            "the lapse, not the expiry"
        );

        // The timer fires at the lapse; nothing expires, the hold
        // normalizes, and the next armed instant is the real deadline.
        clock.advance(HOUR);
        assert!(store.expire_due().is_empty());
        let now = store.now();
        assert_eq!(store.next_event().unwrap() - now, 8 * HOUR);
    }

    #[test]
    fn a_held_page_expires_only_after_hold_plus_frozen_life() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        store.set_rung(id, Ttl::MIN).unwrap(); // 1h
        clock.advance(HOUR / 2); // 30m remain
        assert!(store.pause_press(id)); // held 1h; expiry at lapse + 30m

        clock.advance(HOUR + Duration::from_secs(60)); // hold lapsed, 29m left
        assert!(store.expire_due().is_empty());
        clock.advance(Duration::from_secs(29 * 60));
        assert_eq!(store.expire_due(), vec![id]);
    }

    #[test]
    fn cycling_resets_the_clock_and_respects_a_hold() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        clock.advance(2 * HOUR);

        // Running: 8h → 24h, clock reset to the full rung.
        let rung = store.cycle_rung(id).unwrap();
        assert_eq!(rung.to_string(), "24h");
        assert_eq!(store.sheet(id).unwrap().remaining(store.now()), 24 * HOUR);

        // Held: the rung steps and the frozen life resets, but the hold
        // stays — the pause is the tab's lever, the countdown the
        // header's.
        assert!(store.pause_press(id));
        let rung = store.cycle_rung(id).unwrap();
        assert_eq!(rung.to_string(), "3d");
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(sheet.is_held(now));
        assert_eq!(sheet.remaining(now), Duration::from_secs(3 * 24 * 60 * 60));
    }

    #[test]
    fn pausing_a_due_page_refuses() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        store.set_rung(id, Ttl::MIN).unwrap();
        clock.advance(HOUR);
        assert!(!store.pause_press(id), "a due page cannot be held");
    }

    #[test]
    fn total_held_accumulates_across_lapses() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.pause_press(id)); // 1h hold
        clock.advance(2 * HOUR); // lapses after 1h of holding
        store.expire_due(); // normalizes
        assert_eq!(store.sheet(id).unwrap().total_held(store.now()), HOUR);

        assert!(store.pause_press(id));
        clock.advance(HOUR / 2); // live hold, 30m so far
        assert_eq!(
            store.sheet(id).unwrap().total_held(store.now()),
            HOUR + HOUR / 2
        );
    }

    #[test]
    fn reorder_moves_a_page_and_clamps() {
        let (mut store, _) = store();
        let a = store.new_sheet().unwrap();
        let b = store.new_sheet().unwrap();
        let c = store.new_sheet().unwrap();
        assert!(store.move_sheet(c, 0));
        let order: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(order, vec![c, a, b]);
        assert!(store.move_sheet(c, 99)); // clamps to the end
        let order: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(order, vec![a, b, c]);
        assert!(!store.move_sheet(SheetId(999), 0));
    }

    #[test]
    fn sheet_payload_inlines_chips_in_document_order() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, "s3cr3t-dsn");
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink("dsn for the migration:\n".into()),
                Segment::Chip(chip),
                Segment::Ink("\nrotate after".into()),
            ]
        ));
        let payload = store.sheet_payload(id).unwrap();
        assert_eq!(
            &**payload,
            "dsn for the migration:\ns3cr3t-dsn\nrotate after"
        );
    }

    #[test]
    fn sheet_payload_refuses_image_chips_and_unknown_sheets() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        store.seal_image(id, vec![0u8; 16]).unwrap();
        assert!(matches!(
            store.sheet_payload(id),
            Err(PayloadError::ImageChip)
        ));
        assert!(matches!(
            store.sheet_payload(SheetId(999)),
            Err(PayloadError::UnknownSheet)
        ));
    }

    #[test]
    fn promotion_marks_the_chip_and_keeps_only_the_receipt() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, "promote me");
        assert_eq!(&**store.chip_payload(chip).unwrap(), b"promote me");
        assert!(store.mark_chip_promoted(chip, "9f2abc".into()));
        let sheet = store.sheet(id).unwrap();
        assert_eq!(
            sheet.chip(chip).unwrap().promotion().unwrap().receipt_id,
            "9f2abc"
        );
        assert!(!store.mark_chip_promoted(ChipId(999), "x".into()));
    }

    #[test]
    fn the_gauge_drains_linearly_and_turns_last_hour_under_sixty_minutes() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap(); // 8h
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!((sheet.fraction_remaining(now) - 1.0).abs() < 0.001);
        assert!(!sheet.last_hour(now));

        clock.advance(4 * HOUR); // half of 8h
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!((sheet.fraction_remaining(now) - 0.5).abs() < 0.001);
        assert!(!sheet.last_hour(now), "3h59m over the line is not urgent");

        clock.advance(3 * HOUR); // 1h remains — the boundary is inclusive
        let now = store.now();
        assert!(store.sheet(id).unwrap().last_hour(now));

        clock.advance(HOUR); // zero: due is not "last hour", it is dead
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(!sheet.last_hour(now));
        assert!((sheet.fraction_remaining(now) - 0.0).abs() < 0.001);
    }

    #[test]
    fn cycling_or_setting_a_due_page_refuses_instead_of_resurrecting() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        store.set_rung(id, Ttl::MIN).unwrap(); // 1h
        clock.advance(HOUR);
        // The timer has not fired yet, but the page is due: a click in
        // that sliver must not resurrect it. Zero means zeroized.
        assert_eq!(store.cycle_rung(id), None);
        assert_eq!(store.set_rung(id, Ttl::MAX), None);
        assert_eq!(store.expire_due(), vec![id]);
    }

    #[test]
    fn an_empty_snapshot_is_select_all_delete_and_zeroizes_every_chip() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let a = seal(&mut store, id, "first secret");
        let b = seal(&mut store, id, "second secret");
        assert!(store.sync_document(id, vec![Segment::Chip(a), Segment::Chip(b)]));
        // ⌘A ⌫: the document is empty now, and so must the chips be.
        assert!(store.sync_document(id, Vec::new()));
        assert_eq!(store.sheet(id).unwrap().chip_count(), 0);
        assert!(store.copy_out_chip(a).is_none());
        assert!(store.copy_out_chip(b).is_none());
    }

    #[test]
    fn ops_and_a_legacy_snapshot_build_the_same_projection() {
        let (mut by_ops, _) = store();
        let (mut by_sync, _) = store();
        let ops_page = by_ops.new_sheet().unwrap();
        let sync_page = by_sync.new_sheet().unwrap();
        let ops_chip = seal(&mut by_ops, ops_page, "same secret");
        let sync_chip = seal(&mut by_sync, sync_page, "same secret");

        // Typed as three ops, astral ink included, the chip placed
        // mid-body. Positions are UTF-16 code units: the rocket is two,
        // so "plan \u{1F680}" ends at 7.
        assert!(by_ops.apply_ops(
            ops_page,
            &[
                EditOp::Insert {
                    pos_u16: 0,
                    text: "plan \u{1F680} launch".into()
                },
                EditOp::InsertChip {
                    pos_u16: 7,
                    chip: ops_chip
                },
                EditOp::Insert {
                    pos_u16: 15,
                    text: " done".into()
                },
            ]
        ));
        // The same page, restated the legacy way.
        assert!(by_sync.sync_document(
            sync_page,
            vec![
                Segment::Ink("plan \u{1F680}".into()),
                Segment::Chip(sync_chip),
                Segment::Ink(" launch done".into()),
            ]
        ));

        let ops_sheet = by_ops.sheet(ops_page).unwrap();
        let sync_sheet = by_sync.sheet(sync_page).unwrap();
        assert_eq!(ops_sheet.segments(), sync_sheet.segments());
        assert_eq!(ops_sheet.title(), sync_sheet.title());
        assert_eq!(ops_sheet.title(), "plan \u{1F680}");
    }

    #[test]
    fn a_range_seal_replaces_the_selection_atomically() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        // Body: a(0) 😀(1,2) S(3) E(4) C(5) 😀(6,7) b(8).
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "a\u{1F600}SEC\u{1F600}b".into()
            }]
        ));
        // Seal the middle, astral flanks included: the selection leaves
        // the body and the sentinel stands exactly where it began.
        let chip = store.seal_text_at(id, "SEC\u{1F600}", 3, 5).unwrap();
        assert_eq!(
            store.sheet(id).unwrap().segments(),
            &[
                Segment::Ink("a\u{1F600}".into()),
                Segment::Chip(chip),
                Segment::Ink("b".into()),
            ]
        );
        assert_eq!(store.sheet(id).unwrap().chip_count(), 1);
        // An empty range at the caret deletes nothing and still stands
        // a sentinel.
        let caret = store.seal_text_at(id, "more", 0, 0).unwrap();
        assert_eq!(
            store.sheet(id).unwrap().segments(),
            &[
                Segment::Chip(caret),
                Segment::Ink("a\u{1F600}".into()),
                Segment::Chip(chip),
                Segment::Ink("b".into()),
            ]
        );
    }

    #[test]
    fn a_range_seal_with_a_bad_range_seals_nothing() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "a\u{1F600}b".into()
            }]
        ));
        let before = store.sheet(id).unwrap().segments().to_vec();
        let records_before = store.ledger().count();
        // Out of bounds, and a boundary inside the surrogate pair: the
        // refusal is whole, so no chip is minted, the body stands, and
        // the ledger gains no Sealed record.
        assert_eq!(
            store.seal_text_at(id, "secret", 3, 5),
            Err(Refusal::InvalidRange)
        );
        assert_eq!(
            store.seal_text_at(id, "secret", 2, 1),
            Err(Refusal::InvalidRange)
        );
        assert_eq!(
            store.seal_text_at(id, "secret", 1, 1),
            Err(Refusal::InvalidRange)
        );
        assert_eq!(
            store.seal_text_at(SheetId(999), "secret", 0, 0),
            Err(Refusal::UnknownSheet)
        );
        assert_eq!(store.sheet(id).unwrap().segments(), before.as_slice());
        assert_eq!(store.sheet(id).unwrap().chip_count(), 0);
        assert_eq!(store.ledger().count(), records_before);
    }

    #[test]
    fn a_range_seal_over_a_selected_chip_reaps_it() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let old = seal(&mut store, id, "the earlier secret");
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Insert {
                    pos_u16: 0,
                    text: "ab".into()
                },
                EditOp::InsertChip {
                    pos_u16: 1,
                    chip: old
                },
            ]
        ));
        // The selection swallows the old chip's sentinel, so the seal
        // that replaces it kills the old chip the same way typing over
        // it would.
        let fresh = store.seal_image_at(id, vec![1, 2, 3], 0, 3).unwrap();
        assert_eq!(store.sheet(id).unwrap().segments(), &[Segment::Chip(fresh)]);
        assert!(store.copy_out_chip(old).is_none());
    }

    #[test]
    fn a_batch_with_one_bad_op_mutates_nothing() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, "held through every refusal");
        // Body: a(0) 😀(1,2) b(3) chip(4).
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Insert {
                    pos_u16: 0,
                    text: "a\u{1F600}b".into()
                },
                EditOp::InsertChip { pos_u16: 4, chip },
            ]
        ));
        let before = store.sheet(id).unwrap().segments().to_vec();
        let records_before = store.ledger().count();

        // An offset past the simulated end, behind an op that was valid
        // on its own: the whole batch must fall.
        assert!(!store.apply_ops(
            id,
            &[
                EditOp::Insert {
                    pos_u16: 0,
                    text: "x".into()
                },
                EditOp::Delete {
                    pos_u16: 99,
                    len_u16: 1
                },
            ]
        ));
        // A boundary inside the astral pair, on either kind of op.
        assert!(!store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 2,
                text: "x".into()
            }]
        ));
        assert!(!store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 1,
                len_u16: 1
            }]
        ));
        // A chip this sheet does not own.
        assert!(!store.apply_ops(
            id,
            &[EditOp::InsertChip {
                pos_u16: 0,
                chip: ChipId(999)
            }]
        ));
        // A sentinel that would stand twice.
        assert!(!store.apply_ops(id, &[EditOp::InsertChip { pos_u16: 0, chip }]));
        // No such page at all.
        assert!(!store.apply_ops(
            SheetId(999),
            &[EditOp::Insert {
                pos_u16: 0,
                text: "x".into()
            }]
        ));

        assert_eq!(store.sheet(id).unwrap().segments(), before.as_slice());
        assert_eq!(store.sheet(id).unwrap().chip_count(), 1);
        assert_eq!(store.ledger().count(), records_before);
    }

    #[test]
    fn coalesced_batches_validate_against_the_simulated_state() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, "survives the shuffle");
        // Body: 🔑(0,1) space(2) k(3) e(4) y(5) chip(6).
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Insert {
                    pos_u16: 0,
                    text: "\u{1F511} key".into()
                },
                EditOp::InsertChip { pos_u16: 6, chip },
            ]
        ));
        // A delete and insert at one position: the replacement a shell
        // coalesces a selection retype into.
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Delete {
                    pos_u16: 2,
                    len_u16: 4
                },
                EditOp::Insert {
                    pos_u16: 2,
                    text: " lock".into()
                },
            ]
        ));
        assert_eq!(
            store.sheet(id).unwrap().segments(),
            &[Segment::Ink("\u{1F511} lock".into()), Segment::Chip(chip)]
        );

        // A delete spanning the chip, followed by that chip's re-insert:
        // the shell restating a move of the sentinel. Eight units cover
        // the whole body.
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Delete {
                    pos_u16: 0,
                    len_u16: 8
                },
                EditOp::InsertChip { pos_u16: 0, chip },
                EditOp::Insert {
                    pos_u16: 1,
                    text: " moved".into()
                },
            ]
        ));
        assert_eq!(
            store.sheet(id).unwrap().segments(),
            &[Segment::Chip(chip), Segment::Ink(" moved".into())]
        );
        // The chip lived through its own delete: same bytes, and no
        // Discarded record for a sentinel that stood again by commit.
        let (bytes, _) = store.copy_out_chip(chip).unwrap();
        assert_eq!(&**bytes, b"survives the shuffle");
        assert!(
            events(&store)
                .iter()
                .all(|event| *event != LedgerEvent::Discarded)
        );
    }

    #[test]
    fn deleting_a_sentinel_by_op_zeroizes_the_chip() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let chip = seal(&mut store, id, "deleted in the editor");
        assert!(store.apply_ops(id, &[EditOp::InsertChip { pos_u16: 0, chip }]));
        // ⌫ on the sentinel travels as a one-unit delete.
        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 0,
                len_u16: 1
            }]
        ));
        assert_eq!(store.sheet(id).unwrap().chip_count(), 0);
        assert!(store.copy_out_chip(chip).is_none(), "no resurrection path");
        assert_eq!(
            events(&store),
            vec![
                LedgerEvent::Discarded,
                LedgerEvent::Sealed,
                LedgerEvent::Created
            ]
        );
    }

    #[test]
    fn a_select_all_delete_batch_zeroizes_every_chip() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let a = seal(&mut store, id, "first secret");
        let b = seal(&mut store, id, "second secret");
        // Body: chip a(0) space(1) 🗿(2,3) space(4) chip b(5).
        assert!(store.apply_ops(
            id,
            &[
                EditOp::InsertChip {
                    pos_u16: 0,
                    chip: a
                },
                EditOp::Insert {
                    pos_u16: 1,
                    text: " \u{1F5FF} ".into()
                },
                EditOp::InsertChip {
                    pos_u16: 5,
                    chip: b
                },
            ]
        ));
        // ⌘A ⌫ travels as one delete across the whole body.
        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 0,
                len_u16: 6
            }]
        ));
        assert!(store.sheet(id).unwrap().segments().is_empty());
        assert_eq!(store.sheet(id).unwrap().chip_count(), 0);
        assert!(store.copy_out_chip(a).is_none());
        assert!(store.copy_out_chip(b).is_none());
    }

    #[test]
    fn ops_re_derive_the_title_unless_the_user_named_the_page() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "## prod DB credentials\nrotate after".into()
            }]
        ));
        assert_eq!(store.sheet(id).unwrap().title(), "prod DB credentials");

        // A user-chosen name survives every later batch.
        assert!(store.set_title(id, "the vault"));
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "something else\n".into()
            }]
        ));
        assert_eq!(store.sheet(id).unwrap().title(), "the vault");

        // Handing the name back to derivation, then emptying the page
        // by ops, lands on the creation-stamp placeholder as the legacy
        // path does.
        assert!(store.set_title(id, ""));
        let len: u32 = store
            .sheet(id)
            .unwrap()
            .segments()
            .iter()
            .map(|segment| match segment {
                Segment::Ink(text) => text.encode_utf16().count() as u32,
                Segment::Chip(_) => 1,
            })
            .sum();
        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 0,
                len_u16: len
            }]
        ));
        assert_eq!(store.sheet(id).unwrap().title(), PLACEHOLDER);
    }

    #[test]
    fn block_identity_rides_the_op_path_and_a_restate_reissues_it() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "alpha beta".into()
            }]
        ));
        let whole = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(whole.len(), 1);
        assert!(whole[0].created_s.is_some(), "committed ink has a birthday");

        // Enter mid-paragraph, typed as an op: the first fragment keeps
        // the paragraph's identity, the remainder is minted fresh.
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 5,
                text: "\n".into()
            }]
        ));
        let split = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(split.len(), 2);
        assert_eq!(split[0].id, whole[0].id);
        assert_ne!(split[1].id, whole[0].id);

        // Backspace across the newline merges back: the absorbing
        // paragraph keeps its name and the absorbed one is gone.
        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 5,
                len_u16: 1
            }]
        ));
        let merged = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].id, whole[0].id);

        // A wholesale restate through the recovery path collapses
        // provenance, identity included: the reborn paragraphs answer
        // to fresh names.
        assert!(store.sync_document(id, vec![Segment::Ink("wholly\nrestated".into())]));
        let restated = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(restated.len(), 2);
        assert!(restated.iter().all(|block| block.id != whole[0].id));
    }

    #[test]
    fn a_range_seal_across_a_newline_merges_blocks_like_typing_over_it() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "top\nbottom".into()
            }]
        ));
        let before = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(before.len(), 2);

        // The selection swallows the separating newline; the sentinel
        // stands in its place, and the two paragraphs are one, under
        // the absorbing block's name.
        store.seal_text_at(id, "p\nbo", 2, 4).unwrap();
        let after = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(after.len(), 1);
        assert_eq!(after[0].id, before[0].id);
    }

    #[test]
    fn page_modified_derives_from_the_ops_and_created_stays_the_birth_stamp() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let sheet = store.sheet(id).unwrap();
        assert_eq!(sheet.created_wall_ms(), 1_700_000_000_000);
        assert!(
            sheet.modified_s().is_none(),
            "an untouched body has no newest change"
        );

        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "now it has one".into()
            }]
        ));
        let sheet = store.sheet(id).unwrap();
        assert!(sheet.modified_s().is_some_and(|stamp| stamp > 0));
        assert_eq!(
            sheet.created_wall_ms(),
            1_700_000_000_000,
            "created never re-derives"
        );
    }

    #[test]
    fn a_seal_carrying_an_origin_leaves_no_trace_in_the_ledger() {
        let (mut store, _) = store();
        let id = store.new_sheet().unwrap();
        let origin = format!("{{\"origin\":\"{ORIGIN_URL}\"}}");
        store
            .seal_text_at_with_origin(id, TOKEN, 0, 0, Some(&origin))
            .unwrap();
        assert_content_free(&store);

        // Through death too: the origin rides the document's commit,
        // and the record of the page's end carries none of it.
        assert!(store.close_sheet(id));
        assert_content_free(&store);
    }
}
