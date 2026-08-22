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
    TITLE_CAP, Tab, TabId, derive_title,
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
    /// The strip, in visible order: durable slots, each holding at most
    /// one perishable page (ADR-0017). This vector is what the user
    /// arranged by dragging, and only the user shortens it.
    pub(crate) tabs: Vec<Tab>,
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
    pub(crate) next_tab_id: u64,
    pub(crate) next_sheet_id: u64,
    pub(crate) next_chip_id: u64,
}

impl<C: Clock> SheetStore<C> {
    /// A store reading time from `clock`, with the default cap and rung.
    #[must_use]
    pub fn new(clock: C) -> Self {
        Self {
            clock,
            tabs: Vec::new(),
            ledger: VecDeque::new(),
            cap: DEFAULT_SHEET_CAP,
            default_rung: Ttl::default(),
            next_tab_id: 1,
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
    // Tabs and sheets: create, close, order
    // -----------------------------------------------------------------

    /// A new tab at the end of the strip, holding a new page on the
    /// default rung with its countdown started. Refuses at the cap.
    ///
    /// Both ids come back, because the two halves are addressed
    /// separately from here (ADR-0017): the caller selects the slot and
    /// edits the page, and nothing at the seam can turn one id into the
    /// other by arithmetic.
    pub fn new_tab(&mut self) -> Result<(TabId, SheetId), Refusal> {
        if self.tabs.len() >= self.cap {
            return Err(Refusal::AtCapacity { cap: self.cap });
        }
        let tab_id = TabId(self.next_tab_id);
        self.next_tab_id += 1;
        self.tabs.push(Tab {
            id: tab_id,
            uuid: ItemId::random(),
            created_wall_ms: self.clock.wall_ms(),
            name: None,
            rung: self.default_rung,
            page: None,
        });
        let page = self
            .open_page(tab_id)
            .expect("a slot opened a moment ago holds no page");
        Ok((tab_id, page))
    }

    /// Mint a page into a tab that holds none, at **that tab's** rung
    /// rather than the store's default, with its countdown started and
    /// one `Created` record behind it. Returns the new page's id, or
    /// `None` for an unknown tab or one that already holds a page.
    ///
    /// The rung is the whole reason this is not [`new_tab`]: the slot
    /// carries the countdown length the user chose for it, so the
    /// replacement page starts where its predecessor did and the user
    /// does not re-set it after every expiry (ADR-0017).
    ///
    /// [`new_tab`]: SheetStore::new_tab
    pub fn open_page(&mut self, tab: TabId) -> Option<SheetId> {
        let now = self.clock.now();
        let created_wall_ms = self.clock.wall_ms();
        let offset = self.clock.local_offset_seconds();
        let index = self.tabs.iter().position(|slot| slot.id == tab)?;
        if self.tabs[index].page.is_some() {
            return None; // one page to a slot; the caller closes or waits
        }
        let id = SheetId(self.next_sheet_id);
        self.next_sheet_id += 1;
        let uuid = ItemId::random();
        let document = SheetDocument::new();
        let blocks = BlockIndex::for_document(&document);
        let slot = &mut self.tabs[index];
        let rung = slot.rung;
        slot.page = Some(Sheet {
            id,
            uuid,
            derived_title: None,
            created_wall_ms,
            document,
            segments: Vec::new(),
            blocks,
            chips: Vec::new(),
            clock: SheetClock::Running {
                deadline: now + rung.duration(),
            },
            total_held: Duration::ZERO,
        });
        // The slot names itself the moment it exists, so no record can
        // ever reach the ledger without a label already resolved.
        let label = self.tabs[index].label(offset);
        self.record(
            LedgerEvent::Created,
            uuid,
            label,
            created_wall_ms,
            SizeClass::Tiny,
            DestinationClass::None,
        );
        Some(id)
    }

    /// Close a tab: whatever page it holds has its sealed bytes
    /// zeroized on the way out, the ledger keeps one `Discarded` record
    /// of the fact, and the slot leaves the strip. Returns whether the
    /// tab existed.
    ///
    /// Tab addressed, because this is one of the two things that end a
    /// tab (ADR-0017) and the other one is the cap. An empty slot
    /// closes as readily as a full one: what the gesture dismisses is
    /// the slot, and a slot that holds nothing is still the user's to
    /// be rid of.
    pub fn close_tab(&mut self, id: TabId) -> bool {
        let offset = self.clock.local_offset_seconds();
        let Some(index) = self.tab_index(id) else {
            return false;
        };
        let tab = self.tabs.remove(index);
        let label = tab.label(offset);
        if let Some(page) = tab.page {
            self.entomb(page, label, LedgerEvent::Discarded);
        }
        true
    }

    /// Move a tab to `index` in the visible order (drag-to-reorder;
    /// the ⌘-number map follows). Out-of-range indices clamp to the
    /// end. Returns whether the tab existed.
    ///
    /// The order is the strip's, so this is the slot's gesture and not
    /// the page's: an empty tab is dragged like any other, and the
    /// arrangement the user built survives every page it held.
    pub fn move_tab(&mut self, id: TabId, index: usize) -> bool {
        let Some(from) = self.tab_index(id) else {
            return false;
        };
        let tab = self.tabs.remove(from);
        let to = index.min(self.tabs.len());
        self.tabs.insert(to, tab);
        true
    }

    /// The tabs, in visible (strip) order.
    pub fn tabs(&self) -> impl Iterator<Item = &Tab> {
        self.tabs.iter()
    }

    /// The live pages, in visible (tab) order. Tabs holding no page
    /// contribute nothing, so this is shorter than the strip.
    pub fn sheets(&self) -> impl Iterator<Item = &Sheet> {
        self.tabs.iter().filter_map(|tab| tab.page.as_ref())
    }

    /// A page by id.
    #[must_use]
    pub fn sheet(&self, id: SheetId) -> Option<&Sheet> {
        self.sheets().find(|s| s.id == id)
    }

    /// A tab by id.
    #[must_use]
    pub fn tab(&self, id: TabId) -> Option<&Tab> {
        self.tabs.iter().find(|tab| tab.id == id)
    }

    /// Where in the strip a tab sits.
    fn tab_index(&self, id: TabId) -> Option<usize> {
        self.tabs.iter().position(|tab| tab.id == id)
    }

    /// A tab by id, mutably.
    fn tab_mut(&mut self, id: TabId) -> Option<&mut Tab> {
        self.tabs.iter_mut().find(|tab| tab.id == id)
    }

    fn sheet_mut(&mut self, id: SheetId) -> Option<&mut Sheet> {
        self.tabs
            .iter_mut()
            .filter_map(|tab| tab.page.as_mut())
            .find(|s| s.id == id)
    }

    /// The tab a page stands in.
    fn tab_of(&self, page: SheetId) -> Option<&Tab> {
        self.tabs.iter().find(|tab| tab.holds(page))
    }

    /// The tab a page stands in, mutably.
    fn tab_of_mut(&mut self, page: SheetId) -> Option<&mut Tab> {
        self.tabs.iter_mut().find(|tab| tab.holds(page))
    }

    /// The clock's offset from UTC in seconds, which is everything a
    /// caller needs to render a [`Tab::label`] the same way the ledger
    /// records it.
    #[must_use]
    pub fn local_offset_seconds(&self) -> i32 {
        self.clock.local_offset_seconds()
    }

    /// Number of live pages. Not the width of the strip: a tab holding
    /// no page is still a tab.
    #[must_use]
    #[expect(
        clippy::len_without_is_empty,
        reason = "the emptiness question split in two (ADR-0017): holds_no_page and has_no_tabs. An is_empty beside them would have to mean one of the two silently, which is the ambiguity the split exists to end"
    )]
    pub fn len(&self) -> usize {
        self.sheets().count()
    }

    /// True when no tab holds a page: the pad is empty of content
    /// while the strip stands, which is the state an overnight expiry
    /// leaves behind. The system working, not failing.
    ///
    /// This is ADR-0016 section 6's first key rotation trigger, which
    /// is why it lives here rather than being recomputed above the
    /// seam: a predicate the shell derives is a predicate that can
    /// drift from the one the rotation fires on.
    #[must_use]
    pub fn holds_no_page(&self) -> bool {
        self.tabs.iter().all(|tab| tab.page.is_none())
    }

    /// True when no tabs remain at all: nothing left even to reseal.
    /// Distinct from [`holds_no_page`] on purpose, and wiring the two
    /// backwards fails in both directions (ADR-0017): this one is the
    /// condition for dropping the sealed file, and the other one would
    /// destroy the tabs an expiry was supposed to leave standing.
    ///
    /// [`holds_no_page`]: SheetStore::holds_no_page
    #[must_use]
    pub fn has_no_tabs(&self) -> bool {
        self.tabs.is_empty()
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
        let offset = self.clock.local_offset_seconds();
        let id = ChipId(self.next_chip_id);
        self.next_chip_id += 1;
        let chip = SealedChip::text(id, text);
        let uuid = chip.uuid;
        let host = self.tab_of_mut(sheet).expect("checked above");
        let page = host.page.as_mut().expect("the tab holds the checked page");
        page.chips.push(chip);
        let created = page.created_wall_ms;
        let label = host.label(offset);
        self.record(
            LedgerEvent::Sealed,
            uuid,
            label,
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
        let offset = self.clock.local_offset_seconds();
        let id = ChipId(self.next_chip_id);
        self.next_chip_id += 1;
        let size = SizeClass::of(bytes.len());
        let chip = SealedChip::image(id, bytes);
        let uuid = chip.uuid;
        let host = self.tab_of_mut(sheet).expect("checked above");
        let page = host.page.as_mut().expect("the tab holds the checked page");
        page.chips.push(chip);
        let created = page.created_wall_ms;
        let label = host.label(offset);
        self.record(
            LedgerEvent::Sealed,
            uuid,
            label,
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
    /// and nowhere else: the seam's read surfaces never render commit
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
    /// projection mirrors the document, the derived title is current,
    /// and no sealed chip outlives its sentinel.
    fn settle_document(&mut self, id: SheetId) {
        // Read the clock before the mutable borrow of the tab.
        let offset = self.clock.local_offset_seconds();
        let Some(tab) = self.tab_of_mut(id) else {
            return;
        };
        let sheet = tab.page.as_mut().expect("the tab holds the page found");
        sheet.rebuild_segments();
        // The block index settles against the document: anchors are
        // re-taken, and an index the mutation path failed to narrate
        // (a wholesale restate through `sync_document`, or a mid-batch
        // refusal) is rebuilt with fresh identities rather than served
        // stale (ADR-0013).
        sheet.settle_blocks();
        // The derived title is re-derived here, on edit, and never
        // later: by the time a record reaches the ledger the page
        // already knows what it would answer (ADR-0012). There is no
        // user-set guard any more, because the name the user typed sits
        // on the tab and this write cannot reach it (ADR-0017).
        sheet.derived_title = derive_title(&sheet.segments);
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
        let created = sheet.created_wall_ms;
        // The label resolves after the re-derivation above and after
        // the page's mutable borrow has fallen, so a chip that died in
        // the same edit that renamed the page is recorded under the
        // name the page ended up with.
        let label = tab.label(offset);
        for (uuid, len) in dropped {
            self.record(
                LedgerEvent::Discarded,
                uuid,
                label.clone(),
                created,
                SizeClass::of(len),
                DestinationClass::None,
            );
        }
    }

    /// Name a tab. An empty or all-whitespace submission clears the
    /// name; anything else is capped at 80 characters and outlives
    /// every later edit, and every page the slot goes on to hold.
    /// Returns whether the tab existed.
    ///
    /// Tab addressed, because the name is the durable half's and a slot
    /// holding no page is exactly the slot a user most wants to name.
    ///
    /// Clearing writes `None` and derives nothing. That is the whole of
    /// "a tab is named by the user or not at all" (ADR-0017): the label
    /// falls back to the live page's derived title, which is a read of
    /// the page rather than a write to the tab, so no string the app
    /// made up ever lands in the durable object.
    pub fn set_title(&mut self, id: TabId, title: &str) -> bool {
        let Some(tab) = self.tab_mut(id) else {
            return false;
        };
        let trimmed = title.trim();
        tab.name = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.chars().take(TITLE_CAP).collect())
        };
        true
    }

    // -----------------------------------------------------------------
    // Chips: copy-out, delete, promotion
    // -----------------------------------------------------------------

    fn chip_home(&self, id: ChipId) -> Option<(SheetId, &SealedChip)> {
        self.sheets().find_map(|s| s.chip(id).map(|c| (s.id, c)))
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
        let offset = self.clock.local_offset_seconds();
        let mut removed: Option<(ItemId, usize, String, u64)> = None;
        for tab in &mut self.tabs {
            // The label is resolved before the page is borrowed
            // mutably, and it cannot change under the deletion: a chip
            // leaving the body moves neither the tab's name nor the
            // page's first line.
            let label = tab.label(offset);
            let Some(sheet) = tab.page.as_mut() else {
                continue;
            };
            let Some(index) = sheet.chips.iter().position(|c| c.id == id) else {
                continue;
            };
            let chip = &sheet.chips[index];
            let uuid = chip.uuid;
            removed = Some((uuid, chip.bytes.len(), label, sheet.created_wall_ms));
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
        let Some((uuid, len, label, created)) = removed else {
            return false;
        };
        self.record(
            LedgerEvent::Discarded,
            uuid,
            label,
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
        let offset = self.clock.local_offset_seconds();
        let Some((sheet_id, sealed)) = self.chip_home(chip) else {
            return false;
        };
        let uuid = sealed.uuid;
        let size = SizeClass::of(sealed.bytes.len());
        let host = self.tab_of(sheet_id).expect("chip_home found it");
        let label = host.label(offset);
        let created = host
            .page
            .as_ref()
            .expect("chip_home found the page in it")
            .created_wall_ms;
        self.record(LedgerEvent::Sent, uuid, label, created, size, destination);
        true
    }

    /// Record that a whole page's bytes left for `destination`. The
    /// page-level twin of [`SheetStore::record_sent`]: promoting a page
    /// ([`SheetStore::sheet_payload`]) is the largest egress this app
    /// performs, so it leaves the same kind of line the chip path and
    /// the pasteboard path leave. Without it the ledger's `sent` claim
    /// would be silently incomplete (ADR-0012).
    ///
    /// The record carries the page's own [`ItemId`] and the label its
    /// tab already resolved; nothing is derived from ink here. The size
    /// class is the page's sealed byte total, the same figure
    /// [`SheetStore::close_tab`] and [`SheetStore::expire_due`] record,
    /// and the stamp is the wall clock, as for every other record.
    /// Returns whether the page existed.
    pub fn record_sheet_sent(&mut self, sheet: SheetId, destination: DestinationClass) -> bool {
        let offset = self.clock.local_offset_seconds();
        let Some(tab) = self.tab_of(sheet) else {
            return false;
        };
        let label = tab.label(offset);
        let page = tab.page.as_ref().expect("the tab holds the page found");
        let uuid = page.uuid;
        let created = page.created_wall_ms;
        let sealed_bytes: usize = page.chips.iter().map(|c| c.bytes.len()).sum();
        self.record(
            LedgerEvent::Sent,
            uuid,
            label,
            created,
            SizeClass::of(sealed_bytes),
            destination,
        );
        true
    }

    /// Record a successful promotion: only the receipt identifier stays
    /// on the live chip (no link, no history — doc 03 §5).
    pub fn mark_chip_promoted(&mut self, id: ChipId, receipt_id: String) -> bool {
        for sheet in self.tabs.iter_mut().filter_map(|tab| tab.page.as_mut()) {
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

    /// Cycle a page's countdown label: one rung *shorter*, clock
    /// *reset* to the full rung value (doc 04 — each click resets the
    /// clock to the shown rung). The ladder tapers rather than falling
    /// off its top: a page opens at the longest rung its form factor
    /// asks for, and shortening it to the precarious end takes five
    /// clicks. A held page keeps its hold; the frozen
    /// remaining life resets to the new rung — the pause is the tab's
    /// lever, the countdown the header's. A **due** page refuses, like
    /// [`SheetStore::pause_press`]: zero means zeroized, and a click in
    /// the sliver before the timer reaps must not resurrect it. Returns
    /// the new rung.
    ///
    /// Tab addressed, and on a slot holding no page the gesture stores
    /// the shorter rung and stops there (ADR-0017): an empty tab is not
    /// a due page, and the rung it keeps is the one its next page is
    /// born at.
    pub fn cycle_rung(&mut self, id: TabId) -> Option<Ttl> {
        let now = self.clock.now();
        let tab = self.tab_mut(id)?;
        let rung = tab.rung.shorter();
        let Some(sheet) = tab.page.as_mut() else {
            tab.rung = rung;
            return Some(rung);
        };
        normalize(sheet, now);
        if sheet.remaining(now).is_zero() {
            return None; // due; the timer will reap it
        }
        set_clock(tab, rung, now);
        // A rung transition is the compaction boundary (ADR-0013): the
        // ceremony runs on the same clockwork as everything else, after
        // the transition is accepted, so a due page's refusal above
        // means compaction can never race the reap.
        tab.page
            .as_mut()
            .expect("the tab holds the page found")
            .compact();
        Some(rung)
    }

    /// Set a tab to a specific rung, resetting its page's clock to it.
    /// A due page refuses (see [`SheetStore::cycle_rung`]); a tab
    /// holding no page stores the rung and returns it, because there is
    /// no clock to reset and no document to compact, and an empty tab
    /// is not a due page.
    pub fn set_rung(&mut self, id: TabId, rung: Ttl) -> Option<Ttl> {
        let now = self.clock.now();
        let tab = self.tab_mut(id)?;
        let Some(sheet) = tab.page.as_mut() else {
            tab.rung = rung;
            return Some(rung);
        };
        normalize(sheet, now);
        if sheet.remaining(now).is_zero() {
            return None; // due; the timer will reap it
        }
        set_clock(tab, rung, now);
        // The same boundary as [`SheetStore::cycle_rung`]: any accepted
        // rung transition sheds the history.
        tab.page
            .as_mut()
            .expect("the tab holds the page found")
            .compact();
        Some(rung)
    }

    /// The pause gesture (double-click a tab): a three state cycle.
    /// The first press holds the page's clock for **1 hour**; a press
    /// while held tops the hold up to **24 hours from now** — never
    /// cumulative; a press while topped up **releases** the hold, and
    /// the countdown resumes from exactly where it froze. While held,
    /// remaining life does not drain. An unreleased hold lapses on its
    /// own, to the same effect. A pause holds the clock; it never
    /// extends the rung. Returns false for an unknown or
    /// already-expired page.
    ///
    /// The release is what makes the gesture reversible: a stray
    /// double-click used to ratchet a page's life up by a day with no
    /// way back down (doc 04).
    ///
    /// Tab addressed, because the gesture is a double-click on the tab,
    /// but it is the page's clock it holds: a slot with no page in it
    /// refuses, having nothing to hold.
    pub fn pause_press(&mut self, id: TabId) -> bool {
        let now = self.clock.now();
        let Some(sheet) = self.tab_mut(id).and_then(|tab| tab.page.as_mut()) else {
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
                    topped_up: false,
                };
            }
            SheetClock::Held {
                frozen_remaining,
                started,
                topped_up: false,
                ..
            } => {
                sheet.clock = SheetClock::Held {
                    until: now + HOLD_TOPUP,
                    frozen_remaining,
                    started,
                    topped_up: true,
                };
                // The top-up is a compaction boundary too (ADR-0013):
                // repeated pauses are how a page outlives its rung
                // without ever transitioning, and a page kept alive
                // that way must still shed its history on the same
                // clockwork.
                sheet.compact();
            }
            SheetClock::Held {
                frozen_remaining,
                started,
                topped_up: true,
                ..
            } => {
                // The release. The held span closes into the running
                // total exactly as a lapse would close it — the two
                // ways a hold can end must account identically, or a
                // released page would read as never having been held.
                sheet.total_held += now.saturating_duration_since(started);
                sheet.clock = SheetClock::Running {
                    deadline: now + frozen_remaining,
                };
                // No compaction here: a release takes life away rather
                // than granting it, so it is not one of ADR-0013's
                // boundaries.
            }
        }
        true
    }

    /// The earliest instant anything changes — a page expiring, or a
    /// hold lapsing (the ⏸ clears and the gauge resumes: a visible
    /// change). This is the **only** timer the shell ever arms. `None`
    /// means nothing to schedule: no timers ticking, no wakeups
    /// (doc 05 frugality budget).
    ///
    /// The walk is over live pages, so a tab holding none contributes
    /// nothing. That skip is the mechanism that makes "nothing about a
    /// tab expires" true rather than merely stated: a stored rung is a
    /// number with no clock and no deadline, and there is nothing here
    /// for the timer path to read.
    #[must_use]
    pub fn next_event(&self) -> Option<Instant> {
        let now = self.clock.now();
        self.sheets()
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
    /// every page whose countdown has reached zero is taken out of its
    /// tab and moved to the ledger, its sealed bytes zeroized. Returns
    /// the expired ids (the shell drops them from view silently; the
    /// user set the clock). Call when the armed timer fires, then
    /// re-arm from [`SheetStore::next_event`].
    ///
    /// **The tab stays.** It keeps its slot, its position, its name and
    /// its rung, and it holds nothing (ADR-0017). The page drops whole,
    /// so ADR-0009's no-tombstone contract and the zeroize-on-drop path
    /// below are untouched: what changes is only who is left standing
    /// afterwards. No replacement page is minted here, because a
    /// countdown that ran out at 03:00 with the app closed must not
    /// silently start a fresh one on nothing.
    pub fn expire_due(&mut self) -> Vec<SheetId> {
        let now = self.clock.now();
        let offset = self.clock.local_offset_seconds();
        let mut dead: Vec<(Sheet, String)> = Vec::new();
        for tab in &mut self.tabs {
            let spent = tab.page.as_mut().is_some_and(|page| {
                normalize(page, now);
                page.remaining(now).is_zero()
            });
            if !spent {
                continue;
            }
            // The label is taken while the page is still standing, so
            // the death record carries the name the strip was showing
            // rather than the one it falls back to a line later.
            let label = tab.label(offset);
            let page = tab.page.take().expect("a spent page is a page");
            dead.push((page, label));
        }
        let ids: Vec<SheetId> = dead.iter().map(|(page, _)| page.id).collect();
        for (page, label) in dead {
            self.entomb(page, label, LedgerEvent::Expired);
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
    fn entomb(&mut self, sheet: Sheet, label: String, event: LedgerEvent) {
        let has_ink = sheet.segments.iter().any(|s| match s {
            Segment::Ink(text) => !text.trim().is_empty(),
            Segment::Chip(_) => false,
        });
        if !has_ink && sheet.chips.is_empty() {
            return;
        }
        // The inversion (ADR-0012): the ledger copies a name that was
        // already resolved, by the caller, from the same three steps
        // every other record took. Nothing is derived from ink at
        // death, and no ink, excerpt or byte count crosses into the
        // record.
        let sealed_bytes: usize = sheet.chips.iter().map(|c| c.bytes.len()).sum();
        self.record(
            event,
            sheet.uuid,
            label,
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
        ..
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

/// Store `rung` on the tab and reset its (normalized) page's clock to
/// the full value. The rung is the slot's from here on, so it stands
/// whether or not a page is there to take it.
fn set_clock(tab: &mut Tab, rung: Ttl, now: Instant) {
    tab.rung = rung;
    let Some(sheet) = tab.page.as_mut() else {
        return;
    };
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

    /// The label the strip shows for the tab a page stands in: the
    /// three step resolution, read the way the ledger reads it.
    fn label(store: &SheetStore<ManualClock>, page: SheetId) -> String {
        store
            .tab_of(page)
            .expect("the page is in a tab")
            .label(store.local_offset_seconds())
    }

    /// The slot a page stands in: the tab-addressed routes take this
    /// where a test has a page in hand, which is most of them.
    fn slot(store: &SheetStore<ManualClock>, page: SheetId) -> TabId {
        store.tab_of(page).expect("the page is in a tab").id()
    }

    /// The name the user typed on the tab a page stands in, or `None`.
    fn name(store: &SheetStore<ManualClock>, page: SheetId) -> Option<&str> {
        store.tab_of(page).expect("the page is in a tab").name()
    }

    /// Every recorded event, newest first.
    fn events(store: &SheetStore<ManualClock>) -> Vec<LedgerEvent> {
        store.ledger().map(LedgerRecord::event).collect()
    }

    #[test]
    fn new_sheets_append_in_tab_order_on_the_default_rung() {
        let (mut store, _) = store();
        let first = store.new_tab().unwrap().1;
        let second = store.new_tab().unwrap().1;
        let order: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(order, vec![first, second]);
        let tab = store.tabs().next().unwrap();
        assert_eq!(tab.rung(), Ttl::default());
        assert_eq!(tab.page().unwrap().remaining_label(store.now()), "8h");
    }

    #[test]
    fn refuses_the_tenth_page_instead_of_evicting() {
        let (mut store, _) = store();
        for _ in 0..DEFAULT_SHEET_CAP {
            store.new_tab().unwrap();
        }
        let err = store.new_tab().unwrap_err();
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let a = store.new_tab().unwrap().1;
        let b = store.new_tab().unwrap().1;
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
        assert_eq!(label(&store, a), "dsn for the migration");
    }

    #[test]
    fn a_fresh_tab_is_labelled_by_its_creation_stamp_and_holds_no_name() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        let tab = store.tabs().next().unwrap();
        assert_eq!(tab.label(0), PLACEHOLDER);
        assert_eq!(tab.name(), None, "a tab is born with no name at all");
        assert_eq!(tab.created_wall_ms(), 1_700_000_000_000);
        assert_eq!(tab.page().unwrap().created_wall_ms(), 1_700_000_000_000);
        assert_eq!(tab.page().unwrap().derived_title(), None);

        // The stamp is the tab's birthday, not the current time: an
        // hour later the placeholder still reads the same.
        clock.advance(HOUR);
        assert!(store.sync_document(id, vec![Segment::Ink("   ".into())]));
        assert_eq!(label(&store, id), PLACEHOLDER);
    }

    #[test]
    fn a_page_derives_its_own_title_from_the_first_typed_line() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.sync_document(
            id,
            vec![Segment::Ink("## prod DB credentials\nrotate after".into())]
        ));
        assert_eq!(
            store.sheet(id).unwrap().derived_title(),
            Some("prod DB credentials")
        );
        // The derivation reaches the label without ever reaching the
        // tab: the slot still holds no name of its own.
        assert_eq!(label(&store, id), "prod DB credentials");
        assert_eq!(name(&store, id), None);
    }

    #[test]
    fn a_tab_name_survives_every_re_derivation() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.set_title(slot(&store, id), "  the vault  "));
        assert_eq!(name(&store, id), Some("the vault"), "trimmed, not raw");
        assert_eq!(label(&store, id), "the vault");

        // Editing the page does not take the name back. The page's own
        // derived title moves underneath it and the label ignores it.
        assert!(store.sync_document(id, vec![Segment::Ink("something else\n".into())]));
        assert_eq!(
            store.sheet(id).unwrap().derived_title(),
            Some("something else")
        );
        assert_eq!(label(&store, id), "the vault");

        // Nor does closing it: the ledger copies the label the strip
        // was showing.
        assert!(store.close_tab(slot(&store, id)));
        assert_eq!(store.ledger().next().unwrap().title(), "the vault");
    }

    #[test]
    fn clearing_a_tab_name_writes_none_and_derives_nothing_onto_the_tab() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.sync_document(id, vec![Segment::Ink("derived name\n".into())]));
        assert!(store.set_title(slot(&store, id), "chosen name"));
        assert_eq!(label(&store, id), "chosen name");

        // The load-bearing assertion of "never derived": clearing the
        // name leaves the tab holding nothing, not holding the page's
        // derived title copied across. The label falls back by reading
        // the page, which is why it still reads the derived name.
        assert!(store.set_title(slot(&store, id), "   "));
        assert_eq!(name(&store, id), None);
        assert_eq!(label(&store, id), "derived name");

        // And with no ink at all, back to the tab's creation stamp,
        // still with nothing written on the tab.
        assert!(store.sync_document(id, Vec::new()));
        assert_eq!(name(&store, id), None);
        assert_eq!(label(&store, id), PLACEHOLDER);
        assert!(!store.set_title(TabId(999), "nowhere"));
    }

    #[test]
    fn a_tab_name_is_capped_like_a_derived_title() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.set_title(slot(&store, id), &"é".repeat(200)));
        assert_eq!(name(&store, id).unwrap().chars().count(), 80);
    }

    #[test]
    fn a_sync_that_omits_a_chip_zeroizes_it() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
        let chip = seal(&mut store, id, "one ⌫ removes it whole");
        assert!(store.sync_document(id, vec![Segment::Chip(chip)]));
        assert!(store.delete_chip(chip));
        assert!(!store.delete_chip(chip), "already gone");
        assert!(store.sheet(id).unwrap().segments().is_empty());
    }

    #[test]
    fn copy_out_does_not_consume_the_chip() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap(); // 1h

        let deadline = store.next_event().unwrap();
        assert_eq!(deadline - store.now(), HOUR);

        clock.advance(HOUR - Duration::from_secs(1));
        assert!(store.expire_due().is_empty());

        clock.advance(Duration::from_secs(1));
        assert_eq!(store.expire_due(), vec![id]);
        // The page is gone and the slot it stood in is not: an expiry
        // is a death for the page and nothing at all for the tab.
        assert!(store.holds_no_page());
        assert_eq!(store.tabs().count(), 1);
        assert_eq!(store.next_event(), None, "nothing left to arm");
    }

    #[test]
    fn an_expiring_page_leaves_its_tab_standing_in_place() {
        let (mut store, clock) = store();
        let first = store.new_tab().unwrap().1;
        let doomed = store.new_tab().unwrap().1;
        let third = store.new_tab().unwrap().1;
        assert!(store.set_title(slot(&store, doomed), "payroll"));
        store.set_rung(slot(&store, doomed), Ttl::MIN).unwrap(); // 1h
        assert!(store.sync_document(doomed, vec![Segment::Ink("rotate the key".into())]));

        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![doomed]);

        // The strip keeps its width and its order; the slot in the
        // middle simply holds nothing now. ⌘2 still means the same slot.
        let tabs: Vec<&Tab> = store.tabs().collect();
        assert_eq!(tabs.len(), 3);
        assert_eq!(tabs[0].page().map(Sheet::id), Some(first));
        assert_eq!(tabs[2].page().map(Sheet::id), Some(third));
        assert!(tabs[1].page().is_none());
        assert_eq!(tabs[1].name(), Some("payroll"), "the name outlived it");
        assert_eq!(tabs[1].rung(), Ttl::MIN, "and so did the rung");
        assert_eq!(tabs[1].label(0), "payroll");
        assert_eq!(store.len(), 2, "two live pages across three tabs");

        // The death record carries the label the strip was showing at
        // the moment the page died.
        let record = store.ledger().next().unwrap();
        assert_eq!(record.event(), LedgerEvent::Expired);
        assert_eq!(record.title(), "payroll");
    }

    #[test]
    fn an_unnamed_tab_falls_back_to_its_own_stamp_when_its_page_expires() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap();
        assert!(store.sync_document(id, vec![Segment::Ink("deploy notes".into())]));
        assert_eq!(label(&store, id), "deploy notes", "the control");

        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![id]);
        // The label falls back one step, to the tab's creation stamp
        // and not to any stamp of the page that just died.
        assert_eq!(store.tabs().next().unwrap().label(0), PLACEHOLDER);
    }

    #[test]
    fn a_strip_of_empty_tabs_schedules_nothing() {
        let (mut store, clock) = store();
        for _ in 0..3 {
            let id = store.new_tab().unwrap().1;
            store.set_rung(slot(&store, id), Ttl::MIN).unwrap();
        }
        assert!(
            store.next_event().is_some(),
            "the control: live pages arm the one timer"
        );

        clock.advance(HOUR);
        assert_eq!(store.expire_due().len(), 3);
        assert_eq!(store.tabs().count(), 3, "the slots are all still here");
        assert!(store.holds_no_page());
        assert!(!store.has_no_tabs(), "the two predicates disagree here");
        assert_eq!(
            store.next_event(),
            None,
            "a rung is a number with no clock behind it"
        );
    }

    #[test]
    fn an_empty_tab_takes_a_rung_and_holds_it_for_its_next_page() {
        let (mut store, clock) = store();
        let page = store.new_tab().unwrap().1;
        let tab = slot(&store, page);
        store.set_rung(tab, Ttl::MIN).unwrap(); // 1h
        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![page]);

        // The gesture succeeds on a slot with no page in it: there is
        // no clock to reset and no document to compact, so the store is
        // all it does. An empty tab is not a due page.
        assert_eq!(store.set_rung(tab, Ttl::MAX), Some(Ttl::MAX));
        assert_eq!(store.tab(tab).unwrap().rung(), Ttl::MAX);
        assert_eq!(store.cycle_rung(tab), Some(Ttl::MAX.shorter()));
        assert_eq!(store.tab(tab).unwrap().rung(), Ttl::MAX.shorter());
        assert_eq!(store.next_event(), None, "and still nothing to arm");

        // What the stored rung is for: the next page born here starts
        // on it rather than on the store's default.
        let replacement = store.open_page(tab).expect("the slot is free");
        let now = store.now();
        assert_eq!(
            store.sheet(replacement).unwrap().remaining(now),
            Ttl::MAX.shorter().duration()
        );
    }

    #[test]
    fn an_empty_tab_has_no_clock_to_hold_and_closes_all_the_same() {
        let (mut store, clock) = store();
        let page = store.new_tab().unwrap().1;
        let tab = slot(&store, page);
        store.set_rung(tab, Ttl::MIN).unwrap();
        assert!(store.set_title(tab, "payroll"), "named while it lived");
        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![page]);

        assert!(!store.pause_press(tab), "no clock, nothing to hold");
        assert!(!store.pause_press(TabId::from_raw(999)), "no such tab");
        assert!(store.set_title(tab, "still mine"), "and still nameable");

        // Explicit close is one of the two things that end a tab, and
        // an empty slot goes as readily as a full one.
        assert!(store.close_tab(tab));
        assert!(store.has_no_tabs());
        assert!(!store.close_tab(tab), "already gone");
        assert_eq!(
            events(&store),
            vec![LedgerEvent::Created],
            "the page held nothing, so neither its death nor the close \
             was worth a record; the slot's own life is never recorded"
        );
    }

    #[test]
    fn open_page_mints_at_the_tabs_rung_and_refuses_an_occupied_tab() {
        let (mut store, clock) = store();
        let first = store.new_tab().unwrap().1;
        let slot = store.tabs().next().unwrap().id();
        store.set_rung(slot, Ttl::MIN).unwrap(); // 1h, the slot's rung
        let born = store.sheet(first).unwrap().uuid();

        assert_eq!(store.open_page(slot), None, "one page to a slot");
        assert_eq!(store.open_page(TabId::from_raw(999)), None, "no such tab");
        assert_eq!(store.ledger().count(), 1, "a refusal records nothing");

        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![first]);
        let replacement = store.open_page(slot).expect("the slot is free now");
        assert_ne!(replacement, first);

        // The replacement starts at the rung the user set on the slot,
        // not at the store's eight hour default: that is the whole
        // point of the rung being the tab's.
        let now = store.now();
        let page = store.sheet(replacement).unwrap();
        assert_eq!(page.remaining(now), HOUR);
        assert_eq!(store.tabs().next().unwrap().rung(), Ttl::MIN);
        assert_ne!(page.uuid(), born, "a reused slot holds a new item");
        assert_eq!(
            store.tabs().next().unwrap().label(0),
            PLACEHOLDER,
            "the label is the slot's stamp, an hour older than this page"
        );
        assert_eq!(
            events(&store)[0],
            LedgerEvent::Created,
            "one Created record, as a click through an empty tab costs"
        );
        assert_eq!(store.tabs().count(), 1, "and no new slot");
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

    /// Whether `needle` occurs anywhere in `haystack`: the byte scan
    /// the compaction ceremony's discard claims are audited with.
    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

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
        let id = store.new_tab().unwrap().1;
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
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap();
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
        let id = store.new_tab().unwrap().1;
        let chip = seal(&mut store, id, TOKEN);
        assert_content_free(&store);
        assert!(store.delete_chip(chip));
        assert_content_free(&store);
    }

    #[test]
    fn closing_a_page_records_the_page_and_the_chip_separately() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        let _chip = seal(&mut store, id, "sealed then never synced");
        let tab = slot(&store, id);
        assert!(store.close_tab(tab));
        assert!(!store.close_tab(tab), "already gone");

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
        let id = store.new_tab().unwrap().1;
        assert!(store.sync_document(id, vec![Segment::Ink("   \n".into())]));
        store.close_tab(slot(&store, id));
        // The page's birth is on the record; its death is not, because
        // a page that held nothing did nothing worth auditing.
        assert_eq!(events(&store), vec![LedgerEvent::Created]);
    }

    #[test]
    fn the_ledger_is_a_rolling_window_not_a_record_cap() {
        let (mut store, clock) = store();
        for i in 0..50 {
            let id = store.new_tab().unwrap().1;
            assert!(store.sync_document(id, vec![Segment::Ink(format!("page {i}"))]));
            assert!(store.close_tab(slot(&store, id)));
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
        store.new_tab().unwrap();
        assert_eq!(events(&store), vec![LedgerEvent::Created]);
    }

    #[test]
    fn the_window_boundary_keeps_a_record_exactly_ninety_days_old() {
        let (mut store, clock) = store();
        store.new_tab().unwrap();
        clock.advance(Duration::from_millis(LEDGER_RETENTION_MS));
        store.new_tab().unwrap();
        assert_eq!(store.ledger().count(), 2, "the boundary is inclusive");
        clock.advance(Duration::from_millis(1));
        store.new_tab().unwrap();
        assert_eq!(store.ledger().count(), 2, "the oldest fell off");
    }

    #[test]
    fn every_lifecycle_step_lands_exactly_one_record() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
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

        assert!(store.close_tab(slot(&store, id)));
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1; // 8h
        clock.advance(2 * HOUR); // 6h remain

        assert!(store.pause_press(slot(&store, id)));
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
        let id = store.new_tab().unwrap().1;

        assert!(store.pause_press(slot(&store, id))); // hold: 1h
        assert_eq!(store.sheet(id).unwrap().hold_remaining(store.now()), HOUR);
        assert!(!store.sheet(id).unwrap().hold_topped_up(store.now()));

        assert!(store.pause_press(slot(&store, id))); // extend: 24h from now
        assert_eq!(
            store.sheet(id).unwrap().hold_remaining(store.now()),
            24 * HOUR
        );
        assert!(store.sheet(id).unwrap().hold_topped_up(store.now()));

        // 23 hours later, a press releases and the next one holds for
        // an hour again: the top-up ceiling is 24h from a single press,
        // never cumulative, and re-topping-up costs two more presses.
        clock.advance(23 * HOUR);
        assert!(store.pause_press(slot(&store, id))); // release
        assert!(!store.sheet(id).unwrap().is_held(store.now()));
        assert!(store.pause_press(slot(&store, id))); // hold again: 1h
        assert_eq!(store.sheet(id).unwrap().hold_remaining(store.now()), HOUR);
        assert!(store.pause_press(slot(&store, id))); // top up: 24h, not 47h
        assert_eq!(
            store.sheet(id).unwrap().hold_remaining(store.now()),
            24 * HOUR
        );
    }

    #[test]
    fn a_third_pause_press_releases_the_hold_and_the_clock_resumes_where_it_froze() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1; // 8h
        clock.advance(2 * HOUR); // 6h remain

        assert!(store.pause_press(slot(&store, id))); // hold 1h
        assert!(store.pause_press(slot(&store, id))); // top up to 24h
        clock.advance(3 * HOUR); // held: nothing drains
        assert_eq!(store.sheet(id).unwrap().remaining(store.now()), 6 * HOUR);

        assert!(store.pause_press(slot(&store, id))); // release
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(!sheet.is_held(now), "the release ends the hold at once");
        assert!(!sheet.hold_topped_up(now));
        assert_eq!(sheet.hold_remaining(now), Duration::ZERO);
        // The countdown picks up from exactly where it froze, and the
        // held span is accounted exactly as a lapse would account it.
        assert_eq!(sheet.remaining(now), 6 * HOUR);
        assert_eq!(sheet.total_held(now), 3 * HOUR);

        clock.advance(HOUR);
        assert_eq!(store.sheet(id).unwrap().remaining(store.now()), 5 * HOUR);
        assert_eq!(store.sheet(id).unwrap().total_held(store.now()), 3 * HOUR);
    }

    #[test]
    fn a_released_page_expires_on_its_own_frozen_life() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap(); // 1h
        clock.advance(HOUR / 2); // 30m remain

        assert!(store.pause_press(slot(&store, id))); // hold
        assert!(store.pause_press(slot(&store, id))); // top up
        clock.advance(5 * HOUR); // still held, still 30m
        assert!(store.pause_press(slot(&store, id))); // release: 30m from here

        assert!(store.expire_due().is_empty());
        clock.advance(Duration::from_secs(29 * 60));
        assert!(store.expire_due().is_empty());
        clock.advance(Duration::from_secs(2 * 60));
        assert_eq!(store.expire_due(), vec![id]);
    }

    #[test]
    fn a_lapse_and_a_release_leave_the_page_in_the_same_state() {
        // The two ways a hold can end must be indistinguishable
        // afterwards, or the gesture would be a life extension in
        // disguise.
        let lapsed = {
            let (mut store, clock) = store();
            let id = store.new_tab().unwrap().1;
            assert!(store.pause_press(slot(&store, id))); // 1h hold
            clock.advance(HOUR); // lapses on its own
            let now = store.now();
            let sheet = store.sheet(id).unwrap();
            (
                sheet.remaining(now),
                sheet.total_held(now),
                sheet.is_held(now),
            )
        };
        let released = {
            let (mut store, clock) = store();
            let id = store.new_tab().unwrap().1;
            assert!(store.pause_press(slot(&store, id))); // 1h hold
            assert!(store.pause_press(slot(&store, id))); // top up, so the third can release
            clock.advance(HOUR);
            assert!(store.pause_press(slot(&store, id))); // release, one hour in
            let now = store.now();
            let sheet = store.sheet(id).unwrap();
            (
                sheet.remaining(now),
                sheet.total_held(now),
                sheet.is_held(now),
            )
        };
        assert_eq!(lapsed, released);
    }

    #[test]
    fn a_lapsed_hold_restarts_the_ladder_at_one_hour() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.pause_press(slot(&store, id))); // 1h hold
        clock.advance(2 * HOUR); // lapses
        assert!(store.pause_press(slot(&store, id))); // a fresh first press again
        assert_eq!(store.sheet(id).unwrap().hold_remaining(store.now()), HOUR);
    }

    #[test]
    fn the_one_timer_covers_hold_lapses_too() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1; // 8h
        assert!(store.pause_press(slot(&store, id))); // hold lapses in 1h; expiry at 1h+8h
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
        let id = store.new_tab().unwrap().1;
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap(); // 1h
        clock.advance(HOUR / 2); // 30m remain
        assert!(store.pause_press(slot(&store, id))); // held 1h; expiry at lapse + 30m

        clock.advance(HOUR + Duration::from_secs(60)); // hold lapsed, 29m left
        assert!(store.expire_due().is_empty());
        clock.advance(Duration::from_secs(29 * 60));
        assert_eq!(store.expire_due(), vec![id]);
    }

    #[test]
    fn cycling_resets_the_clock_and_respects_a_hold() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        clock.advance(2 * HOUR);

        // Running: 8h → 3h, one rung shorter, clock reset to the full
        // rung.
        let rung = store.cycle_rung(slot(&store, id)).unwrap();
        assert_eq!(rung.to_string(), "3h");
        assert_eq!(store.sheet(id).unwrap().remaining(store.now()), 3 * HOUR);

        // Held: the rung steps and the frozen life resets, but the hold
        // stays — the pause is the tab's lever, the countdown the
        // header's.
        assert!(store.pause_press(slot(&store, id)));
        let rung = store.cycle_rung(slot(&store, id)).unwrap();
        assert_eq!(rung.to_string(), "1h");
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(sheet.is_held(now));
        assert_eq!(sheet.remaining(now), HOUR);
    }

    #[test]
    fn pausing_a_due_page_refuses() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap();
        clock.advance(HOUR);
        assert!(
            !store.pause_press(slot(&store, id)),
            "a due page cannot be held"
        );
    }

    #[test]
    fn total_held_accumulates_across_lapses() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.pause_press(slot(&store, id))); // 1h hold
        clock.advance(2 * HOUR); // lapses after 1h of holding
        store.expire_due(); // normalizes
        assert_eq!(store.sheet(id).unwrap().total_held(store.now()), HOUR);

        assert!(store.pause_press(slot(&store, id)));
        clock.advance(HOUR / 2); // live hold, 30m so far
        assert_eq!(
            store.sheet(id).unwrap().total_held(store.now()),
            HOUR + HOUR / 2
        );
    }

    #[test]
    fn reorder_moves_a_page_and_clamps() {
        let (mut store, _) = store();
        let a = store.new_tab().unwrap().1;
        let b = store.new_tab().unwrap().1;
        let c = store.new_tab().unwrap().1;
        assert!(store.move_tab(slot(&store, c), 0));
        let order: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(order, vec![c, a, b]);
        assert!(store.move_tab(slot(&store, c), 99)); // clamps to the end
        let order: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(order, vec![a, b, c]);
        assert!(!store.move_tab(TabId(999), 0));
    }

    #[test]
    fn sheet_payload_inlines_chips_in_document_order() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1; // 8h
        let now = store.now();
        let rung = store.tabs().next().unwrap().rung();
        let sheet = store.sheet(id).unwrap();
        assert!((sheet.fraction_remaining(rung, now) - 1.0).abs() < 0.001);
        assert!(!sheet.last_hour(now));

        clock.advance(4 * HOUR); // half of 8h
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!((sheet.fraction_remaining(rung, now) - 0.5).abs() < 0.001);
        assert!(!sheet.last_hour(now), "3h59m over the line is not urgent");

        clock.advance(3 * HOUR); // 1h remains — the boundary is inclusive
        let now = store.now();
        assert!(store.sheet(id).unwrap().last_hour(now));

        clock.advance(HOUR); // zero: due is not "last hour", it is dead
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(!sheet.last_hour(now));
        assert!((sheet.fraction_remaining(rung, now) - 0.0).abs() < 0.001);
    }

    #[test]
    fn cycling_or_setting_a_due_page_refuses_instead_of_resurrecting() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap(); // 1h
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "keep DOOMED\u{1F511}".into()
            }]
        ));
        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 5,
                len_u16: 8
            }]
        ));
        clock.advance(HOUR);
        // The timer has not fired yet, but the page is due: a click in
        // that sliver must not resurrect it. Zero means zeroized.
        assert_eq!(store.cycle_rung(slot(&store, id)), None);
        assert_eq!(store.set_rung(slot(&store, id), Ttl::MAX), None);
        // A refused transition compacts nothing either: the ceremony
        // runs only after an accepted transition, so it cannot race the
        // reap that is about to take the whole document.
        assert!(contains(&store.snapshot(0), b"DOOMED"));
        assert_eq!(store.expire_due(), vec![id]);
    }

    #[test]
    fn a_rung_transition_compacts_the_history_and_the_body_survives() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        let chip = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 1,
                text: "alpha DOOMED\u{1F680} keep\nsecond".into()
            }]
        ));
        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 7,
                len_u16: 8
            }]
        ));
        let sheet = store.sheet(id).unwrap();
        let old_peer = sheet.document.peer_id();
        let derived = sheet.derived_title().map(str::to_string);
        let segments = sheet.segments().to_vec();
        let metas = sheet.blocks_meta();
        let modified = sheet.modified_s().unwrap();

        store.cycle_rung(slot(&store, id)).unwrap();

        // The page is intact: same projection, same title, same chip,
        // and provenance reads exactly as it did, now answered by the
        // materialized summaries instead of the destroyed ops.
        let sheet = store.sheet(id).unwrap();
        assert_eq!(sheet.segments(), segments.as_slice());
        assert_eq!(sheet.derived_title().map(str::to_string), derived);
        assert_eq!(sheet.blocks_meta(), metas);
        assert_eq!(sheet.modified_s(), Some(modified));
        assert_ne!(sheet.document.peer_id(), old_peer);
        let (bytes, _) = store.copy_out_chip(chip).unwrap();
        assert_eq!(&**bytes, TOKEN.as_bytes());

        // The history is not: the persisted content carries neither a
        // deleted fragment nor the old actor id.
        let snapshot = store.snapshot(0);
        assert!(contains(&snapshot, b"alpha  keep"), "the control: live ink");
        assert!(!contains(&snapshot, b"DOOMED"));
        assert!(!contains(&snapshot, &old_peer.to_le_bytes()));

        // A post-compaction edit bumps modified from the frozen floor,
        // and setting a rung directly sheds the new trail the same way.
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 1,
                text: "x".into()
            }]
        ));
        let sheet = store.sheet(id).unwrap();
        assert!(sheet.modified_s().unwrap() >= modified);
        let second_peer = sheet.document.peer_id();
        store.set_rung(slot(&store, id), Ttl::MAX).unwrap();
        assert!(!contains(&store.snapshot(0), &second_peer.to_le_bytes()));
        assert_ne!(store.sheet(id).unwrap().document.peer_id(), second_peer);
    }

    #[test]
    fn a_pause_topup_compacts_but_a_first_press_does_not() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "keep DOOMED\u{1F511}".into()
            }]
        ));
        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 5,
                len_u16: 8
            }]
        ));

        // The first press holds the clock for an hour and keeps the
        // trail: it is not the gesture that keeps a page alive.
        assert!(store.pause_press(slot(&store, id)));
        assert!(contains(&store.snapshot(0), b"DOOMED"));

        // The top-up is: a page kept alive by repeated pauses sheds
        // its history at the same gesture that extends its life, and
        // the hold semantics themselves are untouched.
        assert!(store.pause_press(slot(&store, id)));
        assert!(!contains(&store.snapshot(0), b"DOOMED"));
        assert_eq!(
            store.sheet(id).unwrap().hold_remaining(store.now()),
            24 * HOUR
        );
    }

    #[test]
    fn compaction_moves_no_clock_and_arms_no_timer() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "body\u{1F680}\nDOOMED".into()
            }]
        ));
        let before = store.next_event();
        // The ceremony alone, with no gesture around it: the one armed
        // timer must not move, because compaction is bookkeeping on the
        // document, never an event on the clock.
        store.sheet_mut(id).unwrap().compact();
        assert_eq!(store.next_event(), before);
    }

    #[test]
    fn an_empty_snapshot_is_select_all_delete_and_zeroizes_every_chip() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
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
        let ops_page = by_ops.new_tab().unwrap().1;
        let sync_page = by_sync.new_tab().unwrap().1;
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
        assert_eq!(ops_sheet.derived_title(), sync_sheet.derived_title());
        assert_eq!(ops_sheet.derived_title(), Some("plan \u{1F680}"));
    }

    #[test]
    fn a_range_seal_replaces_the_selection_atomically() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "## prod DB credentials\nrotate after".into()
            }]
        ));
        assert_eq!(label(&store, id), "prod DB credentials");

        // A user-chosen name survives every later batch.
        assert!(store.set_title(slot(&store, id), "the vault"));
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "something else\n".into()
            }]
        ));
        assert_eq!(label(&store, id), "the vault");

        // Handing the name back to derivation, then emptying the page
        // by ops, lands on the creation-stamp placeholder as the legacy
        // path does.
        assert!(store.set_title(slot(&store, id), ""));
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
        assert_eq!(label(&store, id), PLACEHOLDER);
    }

    #[test]
    fn block_identity_rides_the_op_path_and_a_restate_reissues_it() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
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
    fn a_multi_line_insert_lands_as_one_block_the_way_a_paste_arrives() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        // A paste crosses the seam whole, newlines and all: the shape
        // of the op is the whole difference from typing.
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "one\ntwo\nthree".into()
            }]
        ));
        let pasted = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(pasted.len(), 1, "one block, not one per line");
        assert_eq!(pasted[0].paragraphs, 3, "reaching across three of them");

        // Enter at the end closes the paste; what follows is the
        // reader's own block, with its own name and its own stamp.
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 13,
                text: "\n".into()
            }]
        ));
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 14,
                text: "mine".into()
            }]
        ));
        let after = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(after.len(), 2);
        assert_eq!(after[0].id, pasted[0].id, "the paste keeps its name");
        assert_eq!(after[0].paragraphs, 3);
        assert_eq!(after[1].paragraphs, 1);
    }

    #[test]
    fn a_range_seal_across_a_newline_merges_blocks_like_typing_over_it() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        // Typed, not pasted: the newline arrives on its own, so the two
        // lines are two blocks.
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Insert {
                    pos_u16: 0,
                    text: "top\n".into()
                },
                EditOp::Insert {
                    pos_u16: 4,
                    text: "bottom".into()
                }
            ]
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
        let origin = format!("{{\"origin\":\"{ORIGIN_URL}\"}}");
        store
            .seal_text_at_with_origin(id, TOKEN, 0, 0, Some(&origin))
            .unwrap();
        assert_content_free(&store);

        // Through the compaction ceremony too: graduation moves the
        // origin from the commit trail into the materialized summary,
        // and neither the live ledger nor its persisted snapshot may
        // learn it in transit.
        store.cycle_rung(slot(&store, id)).unwrap();
        assert_content_free(&store);
        let ledger = store.ledger_snapshot();
        for fragment in fragments_of(ORIGIN_URL) {
            assert!(
                !contains(&ledger, fragment.as_bytes()),
                "the ledger snapshot leaked {fragment:?}"
            );
        }

        // Through death too: the origin rides the document's commit,
        // and the record of the page's end carries none of it.
        assert!(store.close_tab(slot(&store, id)));
        assert_content_free(&store);
    }
}
