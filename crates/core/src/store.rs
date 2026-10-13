//! The working set: the strip of tabs, the live pages in them, and the
//! [`ledger`](crate::ledger) of what those pages did (doc 04). The strip
//! has no cap (issue #158).

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::blocks::BlockIndex;
use crate::clock::Clock;
use crate::document::{EditIntent, EditSelection, SheetDocument, TextSelection, UpdateRefusal};
use crate::ink::StepOutcome;
use crate::ledger::{DestinationClass, LedgerEvent, LedgerRecord, SizeClass, evict_expired};
use crate::note::Note;
use crate::sheet::{
    CeremonyState, ChipId, ChipMeta, Conceal, ItemId, NameRefusal, SealedChip, Segment, Sheet,
    SheetClock, SheetId, TITLE_CAP, Tab, TabId, derive_title, judge_name,
};
use crate::sync::{ExpiryPolicy, HoldRegister};
use crate::ttl::{self, Ttl};

/// The first double-click holds a page's clock for one hour. Also the
/// ceiling a restored first hold is read against (ADR-0016 section 8).
pub(crate) const HOLD_FIRST: Duration = Duration::from_secs(60 * 60);
/// Every further double-click tops the hold up to 24 hours from now,
/// never cumulative (doc 04).
pub(crate) const HOLD_TOPUP: Duration = Duration::from_secs(24 * 60 * 60);

/// Why the store refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// Nothing to seal (empty text or zero-byte image).
    EmptyContent,
    /// No such page.
    UnknownSheet,
    /// The seal range is out of bounds or splits a surrogate pair.
    InvalidRange,
    /// The seal range swallows a chip; a chip leaves only by an act aimed
    /// at it (D-08).
    AlreadySealed,
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Refusal::EmptyContent => write!(f, "nothing to seal"),
            Refusal::UnknownSheet => write!(f, "no such page"),
            Refusal::InvalidRange => write!(f, "the selection no longer matches the page"),
            Refusal::AlreadySealed => {
                write!(f, "already sealed · a chip has no plaintext to seal")
            }
        }
    }
}

impl std::error::Error for Refusal {}

/// Why a sheet could not be assembled into a conceal payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PayloadError {
    /// No such sheet.
    UnknownSheet,
    /// The sheet holds an image chip; the conceal payload is text-shaped
    /// (open question 3).
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

/// Why a remote update or key frame was refused. Every refusal leaves the
/// page exactly as it was (issue #96).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteRefusal {
    /// No such page.
    UnknownSheet,
    /// The bytes do not decode as an update batch or key frame.
    Malformed,
    /// The update depends on operations this document does not hold. The
    /// recovery is [`SheetStore::adopt_key_frame`] (ADR-0021 section 1).
    MissingHistory,
    /// The update would stand a chip sentinel this page does not own, or
    /// stand one twice.
    ChipRoster,
    /// A key frame was offered to a page whose document already holds
    /// history (ADR-0021 sections 1 and 5).
    NotFresh,
}

impl std::fmt::Display for RemoteRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RemoteRefusal::UnknownSheet => write!(f, "no such page"),
            RemoteRefusal::Malformed => write!(f, "the update does not decode"),
            RemoteRefusal::MissingHistory => {
                write!(f, "the update depends on history this page does not hold")
            }
            RemoteRefusal::ChipRoster => {
                write!(f, "the update references a chip this page does not own")
            }
            RemoteRefusal::NotFresh => {
                write!(f, "a key frame lands only on a fresh page")
            }
        }
    }
}

impl std::error::Error for RemoteRefusal {}

/// One edit against a sheet's body (ADR-0013). Positions and lengths are
/// UTF-16 code units, measured against the body as earlier ops in the
/// batch left it.
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
    /// Place a sealed chip's sentinel. The chip must be owned by the
    /// sheet and its sentinel not already standing.
    InsertChip {
        /// UTF-16 code unit offset of the sentinel.
        pos_u16: u32,
        /// The chip whose sentinel goes here.
        chip: ChipId,
    },
}

/// Editing intent inferred from a batch's shape, for callers that do not
/// supply one.
pub(crate) fn inferred_intent(ops: &[EditOp]) -> EditIntent {
    let has_insert = ops
        .iter()
        .any(|op| matches!(op, EditOp::Insert { .. } | EditOp::InsertChip { .. }));
    let has_delete = ops.iter().any(|op| matches!(op, EditOp::Delete { .. }));
    match (has_insert, has_delete) {
        (true, false) => EditIntent::Typing,
        (false, true) => EditIntent::Deletion,
        _ => EditIntent::Replacement,
    }
}

/// The in-memory sheet store. Nothing here writes a byte on its own; the
/// shell persists it through [`crate::persist`].
pub struct SheetStore<C: Clock> {
    pub(crate) clock: C,
    /// The strip, in visible order: durable slots, each holding at most
    /// one page (ADR-0017).
    pub(crate) tabs: Vec<Tab>,
    /// The audit trail, newest first, bounded by a 90-day window swept on
    /// append, on load and on the write path (see [`evict_expired`]).
    pub(crate) ledger: VecDeque<LedgerRecord>,
    pub(crate) default_rung: Ttl,
    /// Whether applying a rung snaps the deadline up to the next calendar
    /// boundary (ADR-0011 section 4).
    pub(crate) grace_snap: bool,
    pub(crate) next_tab_id: u64,
    pub(crate) next_sheet_id: u64,
    pub(crate) next_chip_id: u64,
}

impl<C: Clock> SheetStore<C> {
    /// A store reading time from `clock`, with the default rung.
    #[must_use]
    pub fn new(clock: C) -> Self {
        Self {
            clock,
            tabs: Vec::new(),
            ledger: VecDeque::new(),
            default_rung: Ttl::default(),
            grace_snap: true,
            next_tab_id: 1,
            next_sheet_id: 1,
            next_chip_id: 1,
        }
    }

    /// Override the default rung for new tabs (settings surface).
    #[must_use]
    pub fn with_default_rung(mut self, rung: Ttl) -> Self {
        self.default_rung = rung;
        self
    }

    /// Start with the boundary snap on or off (ADR-0011 section 4).
    #[must_use]
    pub fn with_grace_snap(mut self, on: bool) -> Self {
        self.grace_snap = on;
        self
    }

    /// Turn the boundary snap on or off for rungs applied from now on.
    /// Existing deadlines stand (ADR-0011 section 4).
    pub fn set_grace_snap(&mut self, on: bool) {
        self.grace_snap = on;
    }

    /// Whether the boundary snap is on.
    #[must_use]
    pub fn grace_snap(&self) -> bool {
        self.grace_snap
    }

    /// The life a page gets when `rung` is applied now, snapped to the
    /// calendar boundary in the device's current zone when the snap is on.
    fn life_for(&self, rung: Ttl) -> Duration {
        if !self.grace_snap {
            return rung.duration();
        }
        let clock = &self.clock;
        ttl::graced_life(rung, clock.wall_ms(), &|secs| {
            clock.local_offset_seconds_at(secs)
        })
    }

    /// A new tab at the end of the strip, holding a new page on the
    /// default rung. Both ids come back: slot and page are addressed
    /// separately (ADR-0017).
    pub fn new_tab(&mut self) -> (TabId, SheetId) {
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
        (tab_id, page)
    }

    /// Mint a page into an empty tab at that tab's rung, with one `Created`
    /// record. `None` for an unknown tab or one that holds a page.
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
        let life = self.life_for(self.tabs[index].rung);
        let slot = &mut self.tabs[index];
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
                deadline: now + life,
            },
            total_held: Duration::ZERO,
            ceremony: CeremonyState::Immediate,
        });
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

    /// Close a tab, empty or not: its page's sealed bytes are zeroized,
    /// one `Discarded` record is kept, and the slot leaves the strip.
    /// Returns whether the tab existed.
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

    /// Discard a page and leave its slot standing with its name, rung and
    /// position, as an expiry does (ADR-0017). Returns whether the page
    /// stood.
    pub fn discard_page(&mut self, id: SheetId) -> bool {
        let offset = self.clock.local_offset_seconds();
        // Label taken before the page goes, as `expire_due` does.
        let Some((page, label)) = self.tab_of_mut(id).and_then(|tab| {
            let label = tab.label(offset);
            tab.page.take().map(|page| (page, label))
        }) else {
            return false;
        };
        self.entomb(page, label, LedgerEvent::Discarded);
        true
    }

    /// Move a tab to `index` in the strip, clamped to the end. Returns
    /// whether the tab existed.
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

    /// The live pages, in strip order. Empty tabs contribute nothing.
    pub fn sheets(&self) -> impl Iterator<Item = &Sheet> {
        self.tabs.iter().filter_map(|tab| tab.page.as_ref())
    }

    /// A page by id.
    #[must_use]
    pub fn sheet(&self, id: SheetId) -> Option<&Sheet> {
        self.sheets().find(|s| s.id == id)
    }

    /// The local id of the page a cross-device `uuid` names, if it stands
    /// here.
    #[must_use]
    pub fn sheet_id_of(&self, page: ItemId) -> Option<SheetId> {
        self.sheets().find(|sheet| sheet.uuid == page).map(|s| s.id)
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

    /// The clock's offset from UTC in seconds, as [`Tab::label`] uses it.
    #[must_use]
    pub fn local_offset_seconds(&self) -> i32 {
        self.clock.local_offset_seconds()
    }

    /// Number of live pages, not tabs.
    #[must_use]
    #[expect(
        clippy::len_without_is_empty,
        reason = "the emptiness question split in two (ADR-0017): holds_no_page and has_no_tabs. An is_empty beside them would have to mean one of the two silently, which is the ambiguity the split exists to end"
    )]
    pub fn len(&self) -> usize {
        self.sheets().count()
    }

    /// True when no tab holds a page. ADR-0016 section 6's first key
    /// rotation trigger, so it lives here rather than above the seam.
    #[must_use]
    pub fn holds_no_page(&self) -> bool {
        self.tabs.iter().all(|tab| tab.page.is_none())
    }

    /// True when no tabs remain at all; the condition for dropping the
    /// sealed file. Not [`SheetStore::holds_no_page`] (ADR-0017).
    #[must_use]
    pub fn has_no_tabs(&self) -> bool {
        self.tabs.is_empty()
    }

    /// The store's clock reading, for rendering.
    #[must_use]
    pub fn now(&self) -> Instant {
        self.clock.now()
    }

    /// The store's wall-clock reading, Unix epoch milliseconds. Pair it
    /// with [`SheetStore::local_offset_seconds`] to bucket by day, as
    /// [`Tab::label`] does.
    #[must_use]
    pub fn wall_ms(&self) -> u64 {
        self.clock.wall_ms()
    }

    /// Seal text onto a page. Returns the chip id.
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

    /// Seal encoded image bytes onto a page.
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

    /// Seal text and stand its chip in place of a UTF-16 range, in one
    /// commit (ADR-0013). A bad range refuses before any chip is minted.
    pub fn seal_text_at(
        &mut self,
        sheet: SheetId,
        text: &str,
        at_u16: u32,
        len_u16: u32,
    ) -> Result<ChipId, Refusal> {
        self.seal_text_at_with_origin(sheet, text, at_u16, len_u16, None)
    }

    /// [`SheetStore::seal_text_at`], stamping `origin` as the seal
    /// commit's message (ADR-0013). It never reaches the ledger.
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

    /// [`SheetStore::seal_text_at`] for image bytes.
    pub fn seal_image_at(
        &mut self,
        sheet: SheetId,
        bytes: Vec<u8>,
        at_u16: u32,
        len_u16: u32,
    ) -> Result<ChipId, Refusal> {
        self.seal_image_at_with_origin(sheet, bytes, at_u16, len_u16, None)
    }

    /// [`SheetStore::seal_image_at`] carrying provenance.
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

    /// Whether a seal range is in bounds, splits no surrogate pair, and
    /// holds no chip (D-08).
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
        if units[at..end]
            .iter()
            .any(|unit| matches!(unit, SimUnit::Chip(_)))
        {
            return Err(Refusal::AlreadySealed);
        }
        Ok(())
    }

    /// Delete the range, stand the sentinel, commit, settle. A document
    /// refusal reaps the placeless chip and fails closed.
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
        // A refusal may leave these notes wrong; the settle rebuilds.
        sheet.blocks.note_delete(at, len_u16 as usize);
        sheet.blocks.note_sentinel(at);
        sheet.document.commit(origin);
        // Sealing is irreversible (ADR-0009): no step may pull the
        // sentinel back out.
        sheet.document.forget_undo();
        self.settle_document(id);
        if clean {
            Ok(chip)
        } else {
            Err(Refusal::InvalidRange)
        }
    }

    /// Apply a batch of edits to a page's body (ADR-0013). The batch is
    /// validated whole against a simulated body first, so one bad op
    /// mutates nothing; an applied batch commits as one change, and chips
    /// whose sentinels are gone are zeroized. Returns whether it applied.
    pub fn apply_ops(&mut self, id: SheetId, ops: &[EditOp]) -> bool {
        self.apply_batch(id, ops, inferred_intent(ops), None)
    }

    /// Apply one admitted batch with the editing gesture that produced it.
    pub fn apply_ops_with_intent(
        &mut self,
        id: SheetId,
        ops: &[EditOp],
        intent: EditIntent,
    ) -> bool {
        self.apply_batch(id, ops, intent, None)
    }

    /// Apply a batch with both the editing gesture and its selections.
    pub fn apply_ops_with_intent_and_selection(
        &mut self,
        id: SheetId,
        ops: &[EditOp],
        intent: EditIntent,
        selection: EditSelection,
    ) -> bool {
        self.apply_batch(id, ops, intent, Some(selection))
    }

    /// [`SheetStore::apply_ops`] as its own undo step, for edits the page
    /// made on the writer's behalf (a continued list marker, a nudge).
    pub fn apply_ops_as_new_step(&mut self, id: SheetId, ops: &[EditOp]) -> bool {
        self.apply_batch(id, ops, EditIntent::Automation, None)
    }

    fn apply_batch(
        &mut self,
        id: SheetId,
        ops: &[EditOp],
        intent: EditIntent,
        selection: Option<EditSelection>,
    ) -> bool {
        let Some(sheet) = self.sheet_mut(id) else {
            return false;
        };
        // Phase one: validate the whole batch in exact code units.
        let mut sim = sim_units(&sheet.segments);
        for op in ops {
            if !sim_admit(&mut sim, &sheet.chips, op) {
                return false;
            }
        }
        if ops.is_empty() {
            return true;
        }
        let before_selection =
            selection.and_then(|selection| sheet.document.snapshot_selection(selection.before));
        // Phase two: phase one makes these infallible; a refusal anyway
        // stops here and returns false.
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
            // Narrate while the offsets are current (ADR-0013).
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
        if let (Some(before), Some(selection)) = (before_selection, selection) {
            sheet
                .document
                .commit_edit_with_selection(intent, None, before, selection.after);
        } else {
            sheet.document.commit_edit(intent, None);
        }
        // After the commit, which pushes the step an undo would use to zeroize the chip.
        if ops.iter().any(|op| matches!(op, EditOp::InsertChip { .. })) {
            sheet.document.forget_undo();
        }
        self.settle_document(id);
        clean
    }

    /// Finish the current typing/deletion run without adding an undo item.
    pub fn finish_editing_group(&mut self, id: SheetId) -> bool {
        let Some(sheet) = self.sheet_mut(id) else {
            return false;
        };
        sheet.document.finish_editing_group(None);
        true
    }

    /// Finish a group and record the selection now shown by the editor.
    pub fn finish_editing_group_at(&mut self, id: SheetId, selection: TextSelection) -> bool {
        let Some(sheet) = self.sheet_mut(id) else {
            return false;
        };
        sheet.document.finish_editing_group(Some(selection));
        true
    }

    /// Take back the page's last local edit group. Returns whether
    /// anything was reverted. Only this device's own operations can be
    /// undone (ADR-0021 section 5); the block index rebuilds afterwards.
    pub fn undo(&mut self, id: SheetId) -> bool {
        let Some(sheet) = self.sheet_mut(id) else {
            return false;
        };
        if !sheet.document.undo() {
            return false;
        }
        self.settle_document(id);
        true
    }

    /// Put back the step [`SheetStore::undo`] took, on the same terms.
    /// Returns whether anything was restored.
    pub fn redo(&mut self, id: SheetId) -> bool {
        let Some(sheet) = self.sheet_mut(id) else {
            return false;
        };
        if !sheet.document.redo() {
            return false;
        }
        self.settle_document(id);
        true
    }

    /// Whether the page has a step waiting to be taken back.
    #[must_use]
    pub fn can_undo(&self, id: SheetId) -> bool {
        self.sheet(id)
            .is_some_and(|sheet| sheet.document.can_undo())
    }

    /// Whether the page has a step waiting to be restored.
    #[must_use]
    pub fn can_redo(&self, id: SheetId) -> bool {
        self.sheet(id)
            .is_some_and(|sheet| sheet.document.can_redo())
    }

    /// Content-free action label for the next Undo menu item.
    pub fn undo_action_name(&self, id: SheetId) -> Option<&'static str> {
        self.sheet(id)?.document.undo_action_name()
    }

    /// Content-free action label for the next Redo menu item.
    pub fn redo_action_name(&self, id: SheetId) -> Option<&'static str> {
        self.sheet(id)?.document.redo_action_name()
    }

    /// The caret after the last accepted step, in UTF-16 code units.
    #[must_use]
    pub fn restored_caret_u16(&self, id: SheetId) -> Option<u32> {
        let caret = self.sheet(id)?.document.restored_caret()?;
        u32::try_from(caret).ok()
    }

    /// The selection restored by the last accepted step.
    pub fn restored_selection_u16(&self, id: SheetId) -> Option<TextSelection> {
        self.sheet(id)?.document.restored_selection()
    }

    /// Replace a page's body wholesale; the recovery route (ADR-0013).
    /// Chips the segments no longer reference are zeroized; a foreign or
    /// repeated chip rejects the whole call. Returns whether it applied.
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
        // Wipe and retype, chips under their existing identities.
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
        // A restate leaves no step to undo: every older step describes a
        // body that no longer exists.
        sheet.document.forget_undo();
        self.settle_document(id);
        clean
    }

    /// Rebuild the projection and derived title, and reap chips whose
    /// sentinels are gone.
    fn settle_document(&mut self, id: SheetId) {
        // Read the clock before the mutable borrow of the tab.
        let offset = self.clock.local_offset_seconds();
        let Some(tab) = self.tab_of_mut(id) else {
            return;
        };
        let sheet = tab.page.as_mut().expect("the tab holds the page found");
        sheet.rebuild_segments();
        // Rebuilds with fresh identities if the mutation went unnarrated
        // (ADR-0013).
        sheet.settle_blocks();
        // Derived on edit, never later (ADR-0012); the user's name is on
        // the tab and out of reach here (ADR-0017).
        sheet.derived_title = derive_title(&sheet.segments);
        // A chip removed with ⌫ leaves the same record as `delete_chip`.
        let live = sheet.document.live_chips();
        let mut dropped: Vec<(ItemId, usize)> = Vec::new();
        sheet.chips.retain(|chip| {
            let alive = live.contains(&chip.uuid);
            if !alive {
                dropped.push((chip.uuid, chip.bytes.len()));
            }
            alive
        });
        // A dead chip takes the undo stack with it: undo would stand a
        // sentinel over zeroized bytes. Every chip death passes here.
        if !dropped.is_empty() {
            sheet.document.forget_undo();
        }
        let created = sheet.created_wall_ms;
        // Resolved after the re-derivation, so the record carries the
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

    /// A page's sync frontier, as opaque bytes (issue #96). `None` for an
    /// unknown page.
    #[must_use]
    pub fn document_version(&self, id: SheetId) -> Option<Vec<u8>> {
        Some(self.sheet(id)?.document.version())
    }

    /// The frontier before anything, which asks for a page's whole
    /// current GOP.
    #[must_use]
    pub fn pristine_document_version() -> Vec<u8> {
        crate::document::SheetDocument::pristine_version()
    }

    /// The operations a page's document holds beyond `since`, plaintext
    /// for the seam to seal (ADR-0021 section 2). `None` for an unknown
    /// page or an undecodable frontier.
    #[must_use]
    pub fn export_document_updates(&self, id: SheetId, since: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        self.sheet(id)?.document.export_updates_since(since)
    }

    /// Apply a peer's update batch, refused whole unless it decodes, has
    /// its dependencies, and resolves every chip sentinel one-to-one. An
    /// accepted batch settles like a local edit.
    pub fn apply_remote_update(&mut self, id: SheetId, bytes: &[u8]) -> Result<(), RemoteRefusal> {
        let Some(sheet) = self.sheet_mut(id) else {
            return Err(RemoteRefusal::UnknownSheet);
        };
        let owned: Vec<ItemId> = sheet.chips.iter().map(|chip| chip.uuid).collect();
        sheet
            .document
            .import_update(bytes, &owned)
            .map_err(refusal_from)?;
        self.settle_document(id);
        Ok(())
    }

    /// Join a fresh page to a channel's key frame (ADR-0021 section 5),
    /// taking over the cross-device identity `page` (ADR-0021 section 6).
    /// A page that already holds history is refused.
    pub fn adopt_key_frame(
        &mut self,
        id: SheetId,
        page: ItemId,
        frame: &[u8],
    ) -> Result<(), RemoteRefusal> {
        let Some(sheet) = self.sheet_mut(id) else {
            return Err(RemoteRefusal::UnknownSheet);
        };
        if !sheet.document.is_pristine() {
            return Err(RemoteRefusal::NotFresh);
        }
        let owned: Vec<ItemId> = sheet.chips.iter().map(|chip| chip.uuid).collect();
        sheet
            .document
            .import_update(frame, &owned)
            .map_err(refusal_from)?;
        sheet.uuid = page;
        self.settle_document(id);
        Ok(())
    }

    /// Defer a page's compaction to its sync channel, or return it to solo.
    /// Returning with a ceremony due compacts on the spot. Returns whether
    /// the page existed.
    pub fn set_compaction_deferred(&mut self, id: SheetId, deferred: bool) -> bool {
        let Some(sheet) = self.sheet_mut(id) else {
            return false;
        };
        match (deferred, sheet.ceremony) {
            (true, CeremonyState::Immediate) => {
                sheet.ceremony = CeremonyState::Deferred { due: false };
            }
            (false, CeremonyState::Deferred { due }) => {
                sheet.ceremony = CeremonyState::Immediate;
                if due {
                    sheet.compact();
                }
            }
            _ => {}
        }
        true
    }

    /// Whether a deferred page has a transition waiting on its ceremony.
    #[must_use]
    pub fn ceremony_due(&self, id: SheetId) -> bool {
        self.sheet(id)
            .is_some_and(|sheet| sheet.ceremony == CeremonyState::Deferred { due: true })
    }

    /// Perform a confirmed ceremony on a deferred page and return the new
    /// key frame (ADR-0021 sections 1 and 5). `None` unless deferred. The
    /// caller pairs it with the GOP key rotation.
    pub fn perform_ceremony(&mut self, id: SheetId) -> Option<Zeroizing<Vec<u8>>> {
        let sheet = self.sheet_mut(id)?;
        if !matches!(sheet.ceremony, CeremonyState::Deferred { .. }) {
            return None;
        }
        sheet.compact();
        sheet.ceremony = CeremonyState::Deferred { due: false };
        Some(sheet.document.export_snapshot())
    }

    /// The wall-clock expiry pair a device publishes for a page (ADR-0021
    /// section 6). `None` for an unknown page or one under a live hold.
    #[must_use]
    pub fn expiry_policy(&self, id: SheetId) -> Option<ExpiryPolicy> {
        let now = self.clock.now();
        let sheet = self.sheet(id)?;
        if sheet.is_held(now) {
            return None;
        }
        Some(ExpiryPolicy {
            anchor_wall_ms: self.clock.wall_ms(),
            ttl_ms: millis(sheet.remaining(now)),
        })
    }

    /// Apply a peer's published expiry: it can only shorten the local
    /// deadline, and a live hold ignores it (ADR-0021 section 6). Returns
    /// whether the deadline moved.
    pub fn observe_peer_expiry(&mut self, page: ItemId, policy: ExpiryPolicy) -> bool {
        let now = self.clock.now();
        let wall = self.clock.wall_ms();
        let Some(sheet) = self.sheet_mut_by_uuid(page) else {
            return false;
        };
        normalize(sheet, now);
        let SheetClock::Running { deadline } = sheet.clock else {
            return false; // held: the hold wins
        };
        let remaining = deadline.saturating_duration_since(now);
        let candidate_ms = policy.deadline_wall_ms().saturating_sub(wall);
        if u128::from(candidate_ms) >= remaining.as_millis() {
            return false; // a peer can never extend a life
        }
        sheet.clock = SheetClock::Running {
            deadline: now + Duration::from_millis(candidate_ms),
        };
        true
    }

    /// The hold register this device publishes for a page. A lapsed hold
    /// reads as released.
    #[must_use]
    pub fn hold_register(&self, id: SheetId) -> Option<HoldRegister> {
        let now = self.clock.now();
        let wall = self.clock.wall_ms();
        let sheet = self.sheet(id)?;
        Some(match sheet.clock {
            SheetClock::Held {
                until,
                frozen_remaining,
                topped_up,
                ..
            } if now < until => HoldRegister::Held {
                until_wall_ms: wall.saturating_add(millis(until.saturating_duration_since(now))),
                frozen_ms: millis(frozen_remaining),
                topped_up,
            },
            _ => HoldRegister::Released,
        })
    }

    /// Apply a peer's hold register (ADR-0021 section 6). It extends the
    /// hold under the gesture's ceiling, never the frozen life; a due page
    /// refuses. Returns whether the clock changed.
    pub fn observe_peer_hold(&mut self, page: ItemId, register: HoldRegister) -> bool {
        let now = self.clock.now();
        let wall = self.clock.wall_ms();
        let Some(sheet) = self.sheet_mut_by_uuid(page) else {
            return false;
        };
        normalize(sheet, now);
        let settled = match (register, sheet.clock) {
            (
                HoldRegister::Held {
                    until_wall_ms,
                    frozen_ms,
                    topped_up,
                },
                SheetClock::Running { deadline },
            ) => {
                let remaining = deadline.saturating_duration_since(now);
                if remaining.is_zero() {
                    return false; // due; the timer will reap it
                }
                let ceiling = if topped_up { HOLD_TOPUP } else { HOLD_FIRST };
                SheetClock::Held {
                    until: now
                        + Duration::from_millis(until_wall_ms.saturating_sub(wall)).min(ceiling),
                    frozen_remaining: Duration::from_millis(frozen_ms).min(remaining),
                    started: now,
                    topped_up,
                }
            }
            (
                HoldRegister::Held {
                    until_wall_ms,
                    frozen_ms,
                    topped_up,
                },
                SheetClock::Held {
                    frozen_remaining,
                    started,
                    ..
                },
            ) => {
                // A re-stated hold: adopt its span, keep the smaller life.
                let ceiling = if topped_up { HOLD_TOPUP } else { HOLD_FIRST };
                SheetClock::Held {
                    until: now
                        + Duration::from_millis(until_wall_ms.saturating_sub(wall)).min(ceiling),
                    frozen_remaining: Duration::from_millis(frozen_ms).min(frozen_remaining),
                    started,
                    topped_up,
                }
            }
            (
                HoldRegister::Released,
                SheetClock::Held {
                    frozen_remaining,
                    started,
                    ..
                },
            ) => {
                sheet.total_held += now.saturating_duration_since(started);
                SheetClock::Running {
                    deadline: now + frozen_remaining,
                }
            }
            (HoldRegister::Released, clock @ SheetClock::Running { .. }) => clock,
        };
        let changed = sheet.clock != settled;
        sheet.clock = settled;
        changed
    }

    /// A peer's terminal marker: entomb this device's copy now, as an
    /// expiry (ADR-0021 section 6). `None` when no such page stands.
    pub fn observe_terminal(&mut self, page: ItemId) -> Option<SheetId> {
        let offset = self.clock.local_offset_seconds();
        let (dead, label, id) = self.tabs.iter_mut().find_map(|tab| {
            if tab.page.as_ref().is_some_and(|held| held.uuid == page) {
                let label = tab.label(offset);
                let held = tab.page.take().expect("checked a line above");
                let id = held.id;
                Some((held, label, id))
            } else {
                None
            }
        })?;
        self.entomb(dead, label, LedgerEvent::Expired);
        Some(id)
    }

    /// A page by its cross-device identity, mutably.
    fn sheet_mut_by_uuid(&mut self, page: ItemId) -> Option<&mut Sheet> {
        self.tabs
            .iter_mut()
            .filter_map(|tab| tab.page.as_mut())
            .find(|sheet| sheet.uuid == page)
    }

    /// Name a tab. Blank clears it to `None`; anything else is capped at
    /// 80 characters (ADR-0017). Returns whether the tab existed.
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

    fn chip_home(&self, id: ChipId) -> Option<(SheetId, &SealedChip)> {
        self.sheets().find_map(|s| s.chip(id).map(|c| (s.id, c)))
    }

    fn chip_mut(&mut self, id: ChipId) -> Option<&mut SealedChip> {
        self.tabs
            .iter_mut()
            .filter_map(|tab| tab.page.as_mut())
            .find_map(|sheet| sheet.chips.iter_mut().find(|chip| chip.id == id))
    }

    /// Name a sealed object by [`judge_name`]'s rule; an empty draft clears
    /// the name. A refusal changes nothing, and no outcome is recorded.
    ///
    /// # Errors
    /// [`NameRefusal::UnknownChip`], or the rule's own refusal.
    pub fn set_chip_name(&mut self, id: ChipId, draft: &str) -> Result<(), NameRefusal> {
        let chip = self.chip_mut(id).ok_or(NameRefusal::UnknownChip)?;
        chip.name = judge_name(draft)?.map(str::to_owned);
        Ok(())
    }

    fn note(&self, id: ChipId) -> Option<&Note> {
        self.chip_home(id)?.1.note.as_ref()
    }

    /// A sealed object's note, empty when it has none; `None` for an unknown
    /// chip (ADR-0043).
    #[must_use]
    pub fn note_text(&self, id: ChipId) -> Option<Zeroizing<String>> {
        let (_, chip) = self.chip_home(id)?;
        Some(
            chip.note
                .as_ref()
                .map_or_else(|| Zeroizing::new(String::new()), Note::text),
        )
    }

    /// Apply a batch to a sealed object's note, whole or not at all; the first
    /// accepted batch makes the note. The page and the ledger are not touched.
    pub fn apply_note_ops(
        &mut self,
        id: ChipId,
        ops: &[EditOp],
        intent: EditIntent,
        selection: Option<EditSelection>,
    ) -> bool {
        let Some(chip) = self.chip_mut(id) else {
            return false;
        };
        if ops.is_empty() {
            return true;
        }
        let made = chip.note.is_none();
        let note = chip.note.get_or_insert_with(|| Note::holding(""));
        if let Some(clean) = note.apply(ops, intent, selection) {
            return clean;
        }
        // A refused first batch makes no note.
        if made {
            chip.note = None;
        }
        false
    }

    /// End the note's typing run without adding a step. False only for an
    /// unknown chip.
    pub fn finish_note_editing_group(
        &mut self,
        id: ChipId,
        selection: Option<TextSelection>,
    ) -> bool {
        let Some((_, chip)) = self.chip_home(id) else {
            return false;
        };
        if let Some(note) = &chip.note {
            note.finish_editing_group(selection);
        }
        true
    }

    /// Whether the note has a step of its own to take back.
    #[must_use]
    pub fn note_can_undo(&self, id: ChipId) -> bool {
        self.note(id).is_some_and(Note::can_undo)
    }

    /// Whether the note has a step of its own to put back.
    #[must_use]
    pub fn note_can_redo(&self, id: ChipId) -> bool {
        self.note(id).is_some_and(Note::can_redo)
    }

    /// Content-free label for the note's next Undo.
    pub fn note_undo_action_name(&self, id: ChipId) -> Option<&'static str> {
        self.note(id)?.undo_action_name()
    }

    /// Content-free label for the note's next Redo.
    pub fn note_redo_action_name(&self, id: ChipId) -> Option<&'static str> {
        self.note(id)?.redo_action_name()
    }

    /// Take back the note's last step; the page's stack is not touched.
    /// `None` for an unknown chip.
    pub fn undo_note(&mut self, id: ChipId) -> Option<StepOutcome> {
        self.step_note(id, true)
    }

    /// Put back the step [`SheetStore::undo_note`] took.
    pub fn redo_note(&mut self, id: ChipId) -> Option<StepOutcome> {
        self.step_note(id, false)
    }

    fn step_note(&mut self, id: ChipId, back: bool) -> Option<StepOutcome> {
        let chip = self.chip_mut(id)?;
        Some(
            chip.note
                .as_mut()
                .map_or(StepOutcome::NONE, |note| note.step(back)),
        )
    }

    /// Copy a chip's bytes back out, without consuming the chip (doc 01).
    #[must_use]
    pub fn copy_out_chip(&self, id: ChipId) -> Option<(Zeroizing<Vec<u8>>, ChipMeta)> {
        let (_, chip) = self.chip_home(id)?;
        Some((Zeroizing::new(chip.bytes.expose().to_vec()), chip.meta))
    }

    /// The name, `=` and a text chip's payload, raw, in one buffer at its
    /// final size (ADR-0042 point 4, ADR-0043). `None` for an unknown,
    /// unnamed or image chip. Consumes nothing and records nothing.
    #[must_use]
    pub fn copy_out_name_value(&self, id: ChipId) -> Option<Zeroizing<Vec<u8>>> {
        let (_, chip) = self.chip_home(id)?;
        if matches!(chip.meta, ChipMeta::Image { .. }) {
            return None;
        }
        let name = chip.name.as_deref()?;
        let value = chip.bytes.expose();
        // Exact size: a reallocation would strand sealed bytes unwiped (Law 0004).
        let mut out = Zeroizing::new(Vec::with_capacity(name.len() + 1 + value.len()));
        out.extend_from_slice(name.as_bytes());
        out.push(b'=');
        out.extend_from_slice(value);
        Some(out)
    }

    /// Remove a chip now; its bytes are wiped as it drops (open question
    /// 5). Returns whether the chip existed.
    pub fn delete_chip(&mut self, id: ChipId) -> bool {
        let offset = self.clock.local_offset_seconds();
        let mut removed: Option<(ItemId, usize, String, u64)> = None;
        for tab in &mut self.tabs {
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
            // The sentinel leaves the document before the bytes die.
            if let Some(pos) = sheet.document.chip_position(uuid) {
                let _ = sheet.document.delete(pos, 1);
                sheet.document.commit(None);
                sheet.blocks.note_delete(pos, 1);
            }
            // Undo never un-seals (ADR-0009).
            sheet.document.forget_undo();
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

    /// Record that a chip's bytes left for `destination` (ADR-0012).
    /// Returns whether the chip existed.
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

    /// Record that a whole page's bytes left for `destination`, the
    /// page-level twin of [`SheetStore::record_sent`] (ADR-0012). Returns
    /// whether the page existed.
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

    /// Record a successful conceal: only the receipt id stays on the chip
    /// (doc 03 §5).
    pub fn mark_chip_concealed(&mut self, id: ChipId, receipt_id: String) -> bool {
        for sheet in self.tabs.iter_mut().filter_map(|tab| tab.page.as_mut()) {
            if let Some(chip) = sheet.chips.iter_mut().find(|c| c.id == id) {
                chip.conceal = Some(Conceal { receipt_id });
                return true;
            }
        }
        false
    }

    /// A chip's bytes for the conceal path, which never passes through the
    /// UI layer.
    #[must_use]
    pub fn chip_payload(&self, id: ChipId) -> Option<Zeroizing<Vec<u8>>> {
        self.copy_out_chip(id).map(|(bytes, _)| bytes)
    }

    /// The whole page as one conceal payload, chips inlined in document
    /// order. Pages holding image chips are refused.
    pub fn sheet_payload(&self, id: SheetId) -> Result<Zeroizing<String>, PayloadError> {
        let sheet = self.sheet(id).ok_or(PayloadError::UnknownSheet)?;
        if sheet
            .chips
            .iter()
            .any(|c| matches!(c.meta, ChipMeta::Image { .. }))
        {
            return Err(PayloadError::ImageChip);
        }
        // Exact size: a reallocation would strand sealed bytes unwiped.
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

    /// Cycle a tab to the next shorter rung and reset its page's clock to
    /// it (doc 04); a held page keeps its hold. A due page refuses with
    /// `None`; an empty tab just stores the rung (ADR-0017).
    pub fn cycle_rung(&mut self, id: TabId) -> Option<Ttl> {
        let rung = self.tab(id)?.rung.shorter();
        self.apply_rung(id, rung)
    }

    /// Set a tab to a specific rung, on the same terms as
    /// [`SheetStore::cycle_rung`].
    pub fn set_rung(&mut self, id: TabId, rung: Ttl) -> Option<Ttl> {
        self.apply_rung(id, rung)
    }

    /// Store the rung on the tab and reset any live page's clock to the
    /// life it gives now.
    fn apply_rung(&mut self, id: TabId, rung: Ttl) -> Option<Ttl> {
        let now = self.clock.now();
        let life = self.life_for(rung);
        let tab = self.tab_mut(id)?;
        let Some(sheet) = tab.page.as_mut() else {
            tab.rung = rung;
            return Some(rung);
        };
        normalize(sheet, now);
        if sheet.remaining(now).is_zero() {
            return None; // due; the timer will reap it
        }
        set_clock(tab, rung, life, now);
        // A rung transition is the compaction boundary (ADR-0013), or a
        // ceremony proposal with peers attached (issue #101).
        tab.page
            .as_mut()
            .expect("the tab holds the page found")
            .compact_or_defer();
        Some(rung)
    }

    /// The pause gesture, a three-state cycle (doc 04): hold for one hour,
    /// top up to 24 hours from now, release. A hold never extends the
    /// rung. Returns false for an unknown, empty or due page.
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
                // The top-up is a compaction boundary too (ADR-0013).
                sheet.compact_or_defer();
            }
            SheetClock::Held {
                frozen_remaining,
                started,
                topped_up: true,
                ..
            } => {
                // Accounted exactly as a lapse is.
                sheet.total_held += now.saturating_duration_since(started);
                sheet.clock = SheetClock::Running {
                    deadline: now + frozen_remaining,
                };
                // A release is not a compaction boundary (ADR-0013).
            }
        }
        true
    }

    /// The earliest instant anything changes: a page expiring or a hold
    /// lapsing. The only timer the shell arms; `None` means nothing to
    /// schedule (doc 05). Empty tabs contribute nothing.
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

    /// Entomb every page whose countdown reached zero, leaving its tab
    /// standing and empty (ADR-0017). Returns the expired ids. Call when
    /// the armed timer fires, then re-arm from [`SheetStore::next_event`].
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
            // Label taken while the page still stands.
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

    /// The audit trail, newest first: metadata and titles, never content.
    pub fn ledger(&self) -> impl Iterator<Item = &LedgerRecord> {
        self.ledger.iter()
    }

    /// Drop records past the 90-day window as of `now_wall_ms`. The
    /// persistence seam calls this before [`SheetStore::ledger_snapshot`]
    /// (ADR-0012). Returns how many records fell off.
    pub fn evict_ledger(&mut self, now_wall_ms: u64) -> usize {
        let before = self.ledger.len();
        evict_expired(&mut self.ledger, now_wall_ms);
        before - self.ledger.len()
    }

    /// Throw the whole ledger away.
    pub fn clear_ledger(&mut self) {
        self.ledger.clear();
    }

    /// Append one record, newest first, and evict past the window.
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

    /// Record the page's death and drop it, zeroizing its chips. A page
    /// without [`Sheet::has_content`] records nothing.
    #[expect(
        clippy::needless_pass_by_value,
        reason = "consuming is the point: the page dies here, and its SecretBuffers zeroize as it drops"
    )]
    fn entomb(&mut self, sheet: Sheet, label: String, event: LedgerEvent) {
        if !sheet.has_content() {
            return;
        }
        // The label was resolved by the caller; nothing is derived from ink
        // at death (ADR-0012).
        let sealed_bytes: usize = sheet.chips.iter().map(|c| c.bytes.len()).sum();
        self.record(
            event,
            sheet.uuid,
            label,
            sheet.created_wall_ms,
            SizeClass::of(sealed_bytes),
            DestinationClass::None,
        );
    }
}

/// A duration as whole milliseconds, saturating.
fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// The document's refusal in the store's vocabulary. Spelled out so a
/// new arm on either side fails to compile.
fn refusal_from(refusal: UpdateRefusal) -> RemoteRefusal {
    match refusal {
        UpdateRefusal::Malformed => RemoteRefusal::Malformed,
        UpdateRefusal::MissingHistory => RemoteRefusal::MissingHistory,
        UpdateRefusal::ChipRoster => RemoteRefusal::ChipRoster,
    }
}

/// A lapsed hold becomes a running countdown, its span added to the
/// page's total (doc 04).
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
/// validates against.
#[derive(Clone, Copy, PartialEq, Eq)]
enum SimUnit {
    /// One UTF-16 code unit of ink.
    Code(u16),
    /// A sealed chip's sentinel, one code unit wide.
    Chip(ChipId),
}

/// The simulated body a batch starts from.
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

/// Whether `pos` falls between the halves of a surrogate pair.
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

/// Validate one op against the simulated body and advance it. A chip not
/// in `chips` never validates.
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

/// Store `rung` on the tab and reset its page's clock to `life`; a held
/// page takes `life` as its frozen remainder.
fn set_clock(tab: &mut Tab, rung: Ttl, life: Duration, now: Instant) {
    tab.rung = rung;
    let Some(sheet) = tab.page.as_mut() else {
        return;
    };
    match &mut sheet.clock {
        SheetClock::Running { deadline } => *deadline = now + life,
        SheetClock::Held {
            frozen_remaining, ..
        } => *frozen_remaining = life,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;
    use crate::ledger::LEDGER_RETENTION_MS;
    use crate::sheet::NAME_CAP;
    use crate::sync::PageChannel;

    fn eight_hours() -> Ttl {
        Ttl::from_secs(8 * 60 * 60).unwrap()
    }

    fn store_on(clock: ManualClock) -> SheetStore<ManualClock> {
        SheetStore::new(clock)
            .with_grace_snap(false)
            .with_default_rung(eight_hours())
    }

    fn store() -> (SheetStore<ManualClock>, ManualClock) {
        let clock = ManualClock::new();
        (store_on(clock.clone()), clock)
    }

    const HOUR: Duration = Duration::from_secs(60 * 60);

    const PLACEHOLDER: &str = "1114-2213";

    fn seal(store: &mut SheetStore<ManualClock>, sheet: SheetId, text: &str) -> ChipId {
        store.seal_text(sheet, text).unwrap()
    }

    fn label(store: &SheetStore<ManualClock>, page: SheetId) -> String {
        store
            .tab_of(page)
            .expect("the page is in a tab")
            .label(store.local_offset_seconds())
    }

    fn slot(store: &SheetStore<ManualClock>, page: SheetId) -> TabId {
        store.tab_of(page).expect("the page is in a tab").id()
    }

    fn name(store: &SheetStore<ManualClock>, page: SheetId) -> Option<&str> {
        store.tab_of(page).expect("the page is in a tab").name()
    }

    fn events(store: &SheetStore<ManualClock>) -> Vec<LedgerEvent> {
        store.ledger().map(LedgerRecord::event).collect()
    }

    #[test]
    fn new_sheets_append_in_tab_order_on_the_default_rung() {
        let (mut store, _) = store();
        let first = store.new_tab().1;
        let second = store.new_tab().1;
        let order: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(order, vec![first, second]);
        let tab = store.tabs().next().unwrap();
        assert_eq!(
            tab.rung(),
            eight_hours(),
            "the rung this suite's store hands out"
        );
        assert_eq!(tab.page().unwrap().remaining_label(store.now()), "8h");
    }

    #[test]
    fn a_new_tab_opens_at_the_ceiling() {
        let clock = ManualClock::new();
        let mut store = SheetStore::new(clock.clone()).with_grace_snap(false);
        let id = store.new_tab().1;
        let tab = store.tabs().next().unwrap();
        assert_eq!(tab.rung(), Ttl::MAX);
        assert_eq!(tab.rung(), Ttl::default());
        assert_eq!(tab.page().unwrap().remaining_label(store.now()), "7d");
        assert_eq!(store.next_event().unwrap() - store.now(), 7 * 24 * HOUR);
        for expected in ["3d", "24h", "8h", "3h", "1h", "7d"] {
            assert_eq!(
                store.cycle_rung(slot(&store, id)).unwrap().to_string(),
                expected
            );
        }
    }

    const SNAP_WALL_MS: u64 = 1_781_108_400_000;
    const LOS_ANGELES: i32 = -7 * 3600;

    fn snapping_store() -> (SheetStore<ManualClock>, ManualClock) {
        let clock = ManualClock::new()
            .with_wall_ms(SNAP_WALL_MS)
            .with_local_offset_seconds(LOS_ANGELES);
        (SheetStore::new(clock.clone()), clock)
    }

    #[test]
    fn grace_snap_rounds_a_new_pages_deadline_up_to_the_boundary() {
        let (mut store, _clock) = snapping_store();
        assert!(store.grace_snap(), "on unless the shell turns it off");
        let id = store.new_tab().1; // 7d, midnight schedule
        let now = store.now();
        let remaining = store.sheet(id).unwrap().remaining(now);
        assert_eq!(
            remaining,
            7 * 24 * HOUR + 14 * HOUR + Duration::from_secs(40 * 60)
        );
        assert_eq!(store.next_event().unwrap() - now, remaining);
        assert_eq!(store.sheet(id).unwrap().remaining_label(now), "7d 14h");

        store.set_rung(slot(&store, id), Ttl::MIN).unwrap(); // 1h
        let remaining = store.sheet(id).unwrap().remaining(now);
        assert_eq!(remaining, HOUR + Duration::from_secs(40 * 60));
        assert_eq!(store.next_event().unwrap() - now, remaining);
        assert_eq!(store.cycle_rung(slot(&store, id)).unwrap(), Ttl::MAX);
        assert_eq!(
            store.sheet(id).unwrap().remaining(now),
            7 * 24 * HOUR + 14 * HOUR + Duration::from_secs(40 * 60),
            "the click gesture goes through the same calculation"
        );
    }

    #[test]
    fn grace_snap_off_makes_every_rung_exact() {
        let (mut store, _clock) = snapping_store();
        store.set_grace_snap(false);
        let id = store.new_tab().1;
        let now = store.now();
        assert_eq!(store.sheet(id).unwrap().remaining(now), 7 * 24 * HOUR);
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap();
        assert_eq!(store.sheet(id).unwrap().remaining(now), HOUR);
        assert_eq!(store.next_event().unwrap() - now, HOUR);
    }

    #[test]
    fn grace_snap_toggling_never_recalculates_an_existing_deadline() {
        let (mut store, _clock) = snapping_store();
        let id = store.new_tab().1;
        let now = store.now();
        let snapped = store.sheet(id).unwrap().remaining(now);
        store.set_grace_snap(false);
        assert_eq!(store.sheet(id).unwrap().remaining(now), snapped);
        assert_eq!(store.next_event().unwrap() - now, snapped);
        let exact = store.new_tab().1;
        store.set_grace_snap(true);
        assert_eq!(store.sheet(exact).unwrap().remaining(now), 7 * 24 * HOUR);
    }

    #[test]
    fn grace_snap_reads_the_zone_at_application_and_never_again() {
        let (mut store, clock) = snapping_store();
        let id = store.new_tab().1;
        let now = store.now();
        let here = store.sheet(id).unwrap().remaining(now);
        clock.set_local_offset_seconds(2 * 3600);
        assert_eq!(store.sheet(id).unwrap().remaining(now), here);
        assert_eq!(store.next_event().unwrap() - now, here);
        store.set_rung(slot(&store, id), Ttl::MAX).unwrap();
        let there = store.sheet(id).unwrap().remaining(now);
        assert_ne!(there, here);
        assert_eq!(
            there,
            7 * 24 * HOUR + 5 * HOUR + Duration::from_secs(40 * 60)
        );
    }

    #[test]
    fn grace_snap_on_a_held_page_sets_the_frozen_life() {
        let (mut store, clock) = snapping_store();
        let id = store.new_tab().1;
        assert!(store.pause_press(slot(&store, id)));
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap(); // 1h, snapped to 10:00
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(sheet.is_held(now));
        assert_eq!(sheet.remaining(now), HOUR + Duration::from_secs(40 * 60));
        clock.advance(HOUR / 2);
        assert!(store.pause_press(slot(&store, id))); // top up
        assert!(store.pause_press(slot(&store, id))); // release
        let now = store.now();
        assert_eq!(
            store.sheet(id).unwrap().remaining(now),
            HOUR + Duration::from_secs(40 * 60)
        );
    }

    #[test]
    fn grace_snap_replacement_pages_take_the_tabs_rung_through_the_snap() {
        let (mut store, clock) = snapping_store();
        let id = store.new_tab().1;
        let tab = slot(&store, id);
        store.set_rung(tab, Ttl::MIN).unwrap(); // 1h, snapped to 10:00 PDT
        clock.advance(2 * HOUR);
        assert_eq!(store.expire_due(), vec![id]);
        let next = store.open_page(tab).unwrap();
        let now = store.now();
        assert_eq!(store.tab(tab).unwrap().rung(), Ttl::MIN);
        assert_eq!(
            store.sheet(next).unwrap().remaining(now),
            HOUR + Duration::from_secs(40 * 60)
        );
    }

    #[test]
    fn a_cross_device_identity_names_the_local_page_it_stands_in() {
        let (mut store, _) = store();
        let first = store.new_tab().1;
        let second = store.new_tab().1;
        let identity = store.sheet(first).unwrap().uuid();
        assert_eq!(store.sheet_id_of(identity), Some(first));
        assert_ne!(store.sheet_id_of(identity), Some(second));
        assert_eq!(
            store.sheet_id_of(ItemId::random()),
            None,
            "an identity no page here holds is an ordinary answer"
        );
        store.close_tab(slot(&store, first));
        assert_eq!(store.sheet_id_of(identity), None);
    }

    #[test]
    fn a_tenth_page_opens_like_the_ninth() {
        let (mut store, _) = store();
        let ids: Vec<TabId> = (0..12).map(|_| store.new_tab().0).collect();
        assert_eq!(store.len(), 12);
        assert_eq!(store.tabs().map(Tab::id).collect::<Vec<_>>(), ids);
        assert!(store.tabs().all(|tab| tab.page().is_some()));
    }

    #[test]
    fn sealing_refuses_empty_content_and_unknown_sheets() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
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
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, "correct horse battery staple!!");
        let sheet = store.sheet(id).unwrap();
        let sealed = sheet.chip(chip).unwrap();
        assert_eq!(sealed.size_label(), "tiny");
        assert!(sealed.excerpt().contains('…'));
        assert_eq!(sheet.chip_count(), 1);
    }

    #[test]
    fn a_multi_line_chip_reports_a_size_class_not_lines() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let key = format!(
            "-----BEGIN OPENSSH PRIVATE KEY-----\n{}\n-----END OPENSSH PRIVATE KEY-----",
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n".repeat(3)
        );
        let chip = seal(&mut store, id, &key);
        let sealed = store.sheet(id).unwrap().chip(chip).unwrap();
        assert_eq!(sealed.size_label(), "small");
        let sealed_record = store
            .ledger()
            .find(|record| record.event() == LedgerEvent::Sealed)
            .expect("the seal left a record");
        assert_eq!(sealed_record.size, SizeClass::Small);
    }

    #[test]
    fn sync_rejects_foreign_and_duplicate_chips() {
        let (mut store, _) = store();
        let a = store.new_tab().1;
        let b = store.new_tab().1;
        let chip_a = seal(&mut store, a, "belongs to a");
        assert!(!store.sync_document(b, vec![Segment::Chip(chip_a)]));
        assert!(!store.sync_document(a, vec![Segment::Chip(chip_a), Segment::Chip(chip_a)]));
        assert_eq!(store.sheet(a).unwrap().chip_count(), 1);
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
        let id = store.new_tab().1;
        let tab = store.tabs().next().unwrap();
        assert_eq!(tab.label(0), PLACEHOLDER);
        assert_eq!(tab.name(), None, "a tab is born with no name at all");
        assert_eq!(tab.created_wall_ms(), 1_700_000_000_000);
        assert_eq!(tab.page().unwrap().created_wall_ms(), 1_700_000_000_000);
        assert_eq!(tab.page().unwrap().derived_title(), None);

        clock.advance(HOUR);
        assert!(store.sync_document(id, vec![Segment::Ink("   ".into())]));
        assert_eq!(label(&store, id), PLACEHOLDER);
    }

    #[test]
    fn a_page_derives_its_own_title_from_the_first_typed_line() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.sync_document(
            id,
            vec![Segment::Ink("## prod DB credentials\nrotate after".into())]
        ));
        assert_eq!(
            store.sheet(id).unwrap().derived_title(),
            Some("prod DB credentials")
        );
        assert_eq!(label(&store, id), "prod DB credentials");
        assert_eq!(name(&store, id), None);
    }

    #[test]
    fn a_tab_name_survives_every_re_derivation() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.set_title(slot(&store, id), "  the vault  "));
        assert_eq!(name(&store, id), Some("the vault"), "trimmed, not raw");
        assert_eq!(label(&store, id), "the vault");

        assert!(store.sync_document(id, vec![Segment::Ink("something else\n".into())]));
        assert_eq!(
            store.sheet(id).unwrap().derived_title(),
            Some("something else")
        );
        assert_eq!(label(&store, id), "the vault");

        assert!(store.close_tab(slot(&store, id)));
        assert_eq!(store.ledger().next().unwrap().title(), "the vault");
    }

    #[test]
    fn clearing_a_tab_name_writes_none_and_derives_nothing_onto_the_tab() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.sync_document(id, vec![Segment::Ink("derived name\n".into())]));
        assert!(store.set_title(slot(&store, id), "chosen name"));
        assert_eq!(label(&store, id), "chosen name");

        assert!(store.set_title(slot(&store, id), "   "));
        assert_eq!(name(&store, id), None);
        assert_eq!(label(&store, id), "derived name");

        assert!(store.sync_document(id, Vec::new()));
        assert_eq!(name(&store, id), None);
        assert_eq!(label(&store, id), PLACEHOLDER);
        assert!(!store.set_title(TabId(999), "nowhere"));
    }

    #[test]
    fn a_tab_name_is_capped_like_a_derived_title() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.set_title(slot(&store, id), &"é".repeat(200)));
        assert_eq!(name(&store, id).unwrap().chars().count(), 80);
    }

    #[test]
    fn a_sync_that_omits_a_chip_zeroizes_it() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, "deleted in the editor");
        assert!(store.sync_document(id, vec![Segment::Chip(chip)]));
        assert!(store.sync_document(id, vec![Segment::Ink("just ink now".into())]));
        assert_eq!(store.sheet(id).unwrap().chip_count(), 0);
        assert!(store.copy_out_chip(chip).is_none(), "no resurrection path");
    }

    #[test]
    fn delete_chip_removes_it_whole() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, "one ⌫ removes it whole");
        assert!(store.sync_document(id, vec![Segment::Chip(chip)]));
        assert!(store.delete_chip(chip));
        assert!(!store.delete_chip(chip), "already gone");
        assert!(store.sheet(id).unwrap().segments().is_empty());
    }

    #[test]
    fn copy_out_does_not_consume_the_chip() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
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
        let id = store.new_tab().1;
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap(); // 1h

        let deadline = store.next_event().unwrap();
        assert_eq!(deadline - store.now(), HOUR);

        clock.advance(HOUR - Duration::from_secs(1));
        assert!(store.expire_due().is_empty());

        clock.advance(Duration::from_secs(1));
        assert_eq!(store.expire_due(), vec![id]);
        assert!(store.holds_no_page());
        assert_eq!(store.tabs().count(), 1);
        assert_eq!(store.next_event(), None, "nothing left to arm");
    }

    #[test]
    fn an_expiring_page_leaves_its_tab_standing_in_place() {
        let (mut store, clock) = store();
        let first = store.new_tab().1;
        let doomed = store.new_tab().1;
        let third = store.new_tab().1;
        assert!(store.set_title(slot(&store, doomed), "payroll"));
        store.set_rung(slot(&store, doomed), Ttl::MIN).unwrap(); // 1h
        assert!(store.sync_document(doomed, vec![Segment::Ink("rotate the key".into())]));

        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![doomed]);

        let tabs: Vec<&Tab> = store.tabs().collect();
        assert_eq!(tabs.len(), 3);
        assert_eq!(tabs[0].page().map(Sheet::id), Some(first));
        assert_eq!(tabs[2].page().map(Sheet::id), Some(third));
        assert!(tabs[1].page().is_none());
        assert_eq!(tabs[1].name(), Some("payroll"), "the name outlived it");
        assert_eq!(tabs[1].rung(), Ttl::MIN, "and so did the rung");
        assert_eq!(tabs[1].label(0), "payroll");
        assert_eq!(store.len(), 2, "two live pages across three tabs");

        let record = store.ledger().next().unwrap();
        assert_eq!(record.event(), LedgerEvent::Expired);
        assert_eq!(record.title(), "payroll");
    }

    #[test]
    fn discarding_a_page_leaves_its_tab_the_way_an_expiry_would() {
        let (mut store, _) = store();
        let first = store.new_tab().1;
        let concealed = store.new_tab().1;
        let tab = slot(&store, concealed);
        assert!(store.set_title(tab, "payroll"));
        store.set_rung(tab, Ttl::MIN).unwrap();
        assert!(store.sync_document(concealed, vec![Segment::Ink("the link travelled".into())]));

        assert!(store.discard_page(concealed));

        let tabs: Vec<&Tab> = store.tabs().collect();
        assert_eq!(tabs.len(), 2, "the strip kept its width");
        assert_eq!(tabs[0].page().map(Sheet::id), Some(first), "and its order");
        assert!(tabs[1].page().is_none(), "the page is gone");
        assert_eq!(tabs[1].id(), tab, "the slot is the same slot");
        assert_eq!(tabs[1].name(), Some("payroll"), "with its name");
        assert_eq!(tabs[1].rung(), Ttl::MIN, "and its rung");
        assert!(store.sheet(concealed).is_none());

        let record = store.ledger().next().unwrap();
        assert_eq!(record.event(), LedgerEvent::Discarded);
        assert_eq!(record.title(), "payroll");

        assert!(!store.discard_page(concealed), "already gone");
        assert!(!store.discard_page(SheetId::from_raw(999)), "no such page");

        let replacement = store.open_page(tab).expect("the slot is free");
        let now = store.now();
        assert_eq!(
            store.sheet(replacement).unwrap().remaining(now),
            Ttl::MIN.duration()
        );
    }

    #[test]
    fn an_unnamed_tab_falls_back_to_its_own_stamp_when_its_page_expires() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap();
        assert!(store.sync_document(id, vec![Segment::Ink("deploy notes".into())]));
        assert_eq!(label(&store, id), "deploy notes", "the control");

        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![id]);
        assert_eq!(store.tabs().next().unwrap().label(0), PLACEHOLDER);
    }

    #[test]
    fn a_strip_of_empty_tabs_schedules_nothing() {
        let (mut store, clock) = store();
        for _ in 0..3 {
            let id = store.new_tab().1;
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
        let page = store.new_tab().1;
        let tab = slot(&store, page);
        store.set_rung(tab, Ttl::MIN).unwrap(); // 1h
        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![page]);

        assert_eq!(store.set_rung(tab, Ttl::MAX), Some(Ttl::MAX));
        assert_eq!(store.tab(tab).unwrap().rung(), Ttl::MAX);
        assert_eq!(store.cycle_rung(tab), Some(Ttl::MAX.shorter()));
        assert_eq!(store.tab(tab).unwrap().rung(), Ttl::MAX.shorter());
        assert_eq!(store.next_event(), None, "and still nothing to arm");

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
        let page = store.new_tab().1;
        let tab = slot(&store, page);
        store.set_rung(tab, Ttl::MIN).unwrap();
        assert!(store.set_title(tab, "payroll"), "named while it lived");
        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![page]);

        assert!(!store.pause_press(tab), "no clock, nothing to hold");
        assert!(!store.pause_press(TabId::from_raw(999)), "no such tab");
        assert!(store.set_title(tab, "still mine"), "and still nameable");

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
        let first = store.new_tab().1;
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

    const TOKEN: &str = "Zq7Xv-Marmalade-Bt94kL-Wp2Rn";

    const ORIGIN_URL: &str = "https://origin.example.test/reset?tk=Vq9Zx-Chutney-Rt83mN";

    /// Long enough for `fragments_of`, and in no ledger field by chance.
    const CHIP_NAME: &str = "QUINCE_MARMALADE_ROTATION_KEY_7ZX";

    /// The same, for a note.
    const CHIP_NOTE: &str = "Wq9Fj Zx7Kp Marmot Burrow Vq2Ld Gh5Ty";

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

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

    fn assert_content_free(store: &SheetStore<ManualClock>) {
        let mut fragments = fragments_of(TOKEN);
        fragments.extend(fragments_of(ORIGIN_URL));
        fragments.extend(fragments_of(CHIP_NAME));
        fragments.extend(fragments_of(CHIP_NOTE));
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
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, TOKEN);
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink("### deploy friday\nin order\n".into()),
                Segment::Chip(chip),
            ]
        ));
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

        assert_eq!(store.ledger().count(), 4, "created, sealed, sent, expired");
        assert_content_free(&store);
    }

    #[test]
    fn a_sealed_chip_is_content_free_in_the_ledger_from_the_moment_it_exists() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, TOKEN);
        assert_content_free(&store);
        assert!(store.delete_chip(chip));
        assert_content_free(&store);
    }

    fn chip_name(store: &SheetStore<ManualClock>, chip: ChipId) -> Option<String> {
        let (_, sealed) = store.chip_home(chip).expect("the chip stands");
        sealed.name().map(str::to_owned)
    }

    #[test]
    fn a_named_chip_is_content_free_in_the_ledger() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        let before = store.ledger().count();
        store.set_chip_name(chip, CHIP_NAME).unwrap();
        store.set_chip_name(chip, "").unwrap();
        store.set_chip_name(chip, CHIP_NAME).unwrap();
        assert_eq!(store.ledger().count(), before, "naming records nothing");
        assert_eq!(chip_name(&store, chip).as_deref(), Some(CHIP_NAME));

        assert!(store.record_sent(chip, DestinationClass::Clipboard));
        store.set_rung(slot(&store, id), Ttl::MIN).unwrap();
        clock.advance(HOUR);
        store.expire_due();
        assert_eq!(store.ledger().count(), 4, "created, sealed, sent, expired");
        assert_content_free(&store);
        assert!(!contains(&store.ledger_snapshot(), CHIP_NAME.as_bytes()));
    }

    #[test]
    fn a_name_survives_a_snapshot_round_trip() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let named = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        let unnamed = store.seal_text_at(id, "left unnamed", 1, 0).unwrap();
        store.set_chip_name(named, CHIP_NAME).unwrap();
        let uuids: Vec<ItemId> = [named, unnamed]
            .iter()
            .map(|chip| store.chip_home(*chip).unwrap().1.uuid())
            .collect();

        let snapshot = store.snapshot(1_000_000);
        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&snapshot, 1_000_000).unwrap(), 1);
        let sheet = revived.sheets().next().unwrap();
        let names: Vec<Option<&str>> = uuids
            .iter()
            .map(|uuid| {
                sheet
                    .chips()
                    .find(|chip| chip.uuid() == *uuid)
                    .unwrap()
                    .name()
            })
            .collect();
        assert_eq!(names, vec![Some(CHIP_NAME), None]);
    }

    #[test]
    fn after_the_page_expires_the_snapshot_holds_no_name() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        store.set_chip_name(chip, CHIP_NAME).unwrap();
        assert!(
            contains(&store.snapshot(1_000_000), CHIP_NAME.as_bytes()),
            "the control: a live page writes its chip's name"
        );

        store.set_rung(slot(&store, id), Ttl::MIN).unwrap();
        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![id]);
        assert!(!contains(&store.snapshot(1_000_000), CHIP_NAME.as_bytes()));
        assert!(!contains(&store.ledger_snapshot(), CHIP_NAME.as_bytes()));
    }

    fn typed(pos_u16: u32, text: &str) -> Vec<EditOp> {
        vec![EditOp::Insert {
            pos_u16,
            text: text.into(),
        }]
    }

    fn write_note(store: &mut SheetStore<ManualClock>, chip: ChipId, text: &str) {
        assert!(store.apply_note_ops(chip, &typed(0, text), EditIntent::Paste, None));
    }

    fn note_of(store: &SheetStore<ManualClock>, chip: ChipId) -> String {
        store.note_text(chip).expect("the chip stands").to_string()
    }

    #[test]
    fn a_note_survives_a_snapshot_round_trip() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let noted = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        let bare = store.seal_text_at(id, "no note here", 1, 0).unwrap();
        write_note(&mut store, noted, CHIP_NOTE);
        let uuids: Vec<ItemId> = [noted, bare]
            .iter()
            .map(|chip| store.chip_home(*chip).unwrap().1.uuid())
            .collect();

        let snapshot = store.snapshot(1_000_000);
        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&snapshot, 1_000_000).unwrap(), 1);
        let ids: Vec<ChipId> = uuids
            .iter()
            .map(|uuid| {
                let sheet = revived.sheets().next().unwrap();
                sheet
                    .chips()
                    .find(|chip| chip.uuid() == *uuid)
                    .unwrap()
                    .id()
            })
            .collect();
        assert_eq!(note_of(&revived, ids[0]), CHIP_NOTE);
        assert!(revived.chip_home(ids[0]).unwrap().1.has_note());
        assert_eq!(note_of(&revived, ids[1]), "");
        assert!(!revived.chip_home(ids[1]).unwrap().1.has_note());
        assert!(
            !revived.note_can_undo(ids[0]),
            "undo does not survive relaunch"
        );
    }

    #[test]
    fn after_the_page_expires_the_snapshot_holds_no_note() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        write_note(&mut store, chip, CHIP_NOTE);
        assert!(
            contains(&store.snapshot(1_000_000), CHIP_NOTE.as_bytes()),
            "the control: a live page writes its chip's note"
        );

        store.set_rung(slot(&store, id), Ttl::MIN).unwrap();
        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![id]);
        assert!(
            store.note_text(chip).is_none(),
            "the note went with its chip"
        );
        assert!(!contains(&store.snapshot(1_000_000), CHIP_NOTE.as_bytes()));
        assert!(!contains(&store.ledger_snapshot(), CHIP_NOTE.as_bytes()));
    }

    #[test]
    fn undo_inside_the_note_is_separate_from_the_pages_undo() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        assert!(store.apply_ops(id, &typed(1, " page ink")));
        assert!(store.apply_note_ops(chip, &typed(0, "note ink"), EditIntent::Typing, None));
        let page_ink =
            |store: &SheetStore<ManualClock>| {
                store.sheet(id).unwrap().segments().iter().any(
                    |segment| matches!(segment, Segment::Ink(text) if text.contains("page ink")),
                )
            };
        assert_eq!(store.note_undo_action_name(chip), Some("Typing"));

        assert!(store.undo_note(chip).unwrap().applied);
        assert_eq!(note_of(&store, chip), "", "the note's step came back");
        assert!(page_ink(&store), "the note's undo reached the page");
        assert!(store.can_undo(id), "the page's step still waits");
        assert!(!store.note_can_undo(chip));

        assert!(store.undo(id));
        assert!(!page_ink(&store));
        assert!(
            store.note_can_redo(chip),
            "the page's undo took the note's redo"
        );
        assert_eq!(note_of(&store, chip), "");

        assert!(store.redo_note(chip).unwrap().applied);
        assert_eq!(note_of(&store, chip), "note ink");
        assert!(store.can_redo(id), "the note's redo took the page's");
        assert!(store.redo(id));
        assert!(page_ink(&store));
        assert_eq!(note_of(&store, chip), "note ink");

        assert!(store.undo_note(chip).unwrap().applied, "its own step again");
        assert!(page_ink(&store));
        assert!(store.undo_note(ChipId::from_raw(4_242)).is_none());
    }

    #[test]
    fn note_edits_leave_the_ledger_unchanged() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        store.set_chip_name(chip, CHIP_NAME).unwrap();
        let before: Vec<LedgerRecord> = store.ledger().cloned().collect();

        write_note(&mut store, chip, CHIP_NOTE);
        assert!(store.apply_note_ops(
            chip,
            &[EditOp::Delete {
                pos_u16: 0,
                len_u16: 6
            }],
            EditIntent::Deletion,
            None
        ));
        assert!(store.undo_note(chip).unwrap().applied);
        assert!(store.finish_note_editing_group(chip, None));
        let after: Vec<LedgerRecord> = store.ledger().cloned().collect();
        assert_eq!(after, before, "a note edit recorded something");
        assert_content_free(&store);

        store.set_rung(slot(&store, id), Ttl::MIN).unwrap();
        clock.advance(HOUR);
        store.expire_due();
        assert_content_free(&store);
        assert!(!contains(&store.ledger_snapshot(), b"Marmot"));
    }

    #[test]
    fn a_note_takes_no_chip_and_a_refused_first_batch_makes_no_note() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        let other = store.seal_text_at(id, "another", 1, 0).unwrap();

        let refused = [
            vec![EditOp::InsertChip {
                pos_u16: 0,
                chip: other,
            }],
            vec![EditOp::Delete {
                pos_u16: 5,
                len_u16: 1,
            }],
            typed(5, "past the end"),
        ];
        for ops in &refused {
            assert!(!store.apply_note_ops(chip, ops, EditIntent::Typing, None));
            assert!(
                store.chip_home(chip).unwrap().1.note.is_none(),
                "a refused first batch made a note: {ops:?}"
            );
        }

        write_note(&mut store, chip, "kept");
        for ops in &refused {
            assert!(!store.apply_note_ops(chip, ops, EditIntent::Typing, None));
            assert_eq!(note_of(&store, chip), "kept", "{ops:?}");
        }
        assert!(store.apply_note_ops(chip, &[], EditIntent::Typing, None));
        assert!(!store.apply_note_ops(
            ChipId::from_raw(4_242),
            &typed(0, "x"),
            EditIntent::Typing,
            None
        ));
        assert_eq!(
            store.sheet(id).unwrap().chip_count(),
            2,
            "the page's chips stand"
        );
    }

    #[test]
    fn a_note_of_only_whitespace_opens_no_doorway() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        let doorway = |store: &SheetStore<ManualClock>| store.chip_home(chip).unwrap().1.has_note();
        assert!(!doorway(&store));
        write_note(&mut store, chip, "  \n\t");
        assert!(!doorway(&store));
        assert!(store.apply_note_ops(chip, &typed(4, "x"), EditIntent::Typing, None));
        assert!(doorway(&store));
    }

    #[test]
    fn a_name_and_a_note_are_never_payload() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, TOKEN, 0, 0).unwrap();
        store.set_chip_name(chip, CHIP_NAME).unwrap();
        write_note(&mut store, chip, CHIP_NOTE);

        let one = store.chip_payload(chip).unwrap();
        assert_eq!(
            &**one,
            TOKEN.as_bytes(),
            "a chip's conceal payload is its bytes"
        );
        let page = store.sheet_payload(id).unwrap();
        assert!(
            page.contains(TOKEN),
            "the control: the page inlines its chip"
        );
        for text in [CHIP_NAME, CHIP_NOTE] {
            assert!(!page.contains(text), "{text} rode the page's payload");
        }
        let (bytes, _) = store.copy_out_chip(chip).unwrap();
        assert_eq!(&**bytes, TOKEN.as_bytes());
    }

    #[test]
    fn name_value_is_composed_raw_at_its_exact_size() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        // 21 bytes, so a buffer grown by doubling would end with spare capacity.
        let value = "s3cr3t \"q\" $HOME\nline";
        let chip = seal(&mut store, id, value);
        store.set_chip_name(chip, "DB_PASSWORD").unwrap();
        let before = store.ledger().count();

        let composed = store.copy_out_name_value(chip).unwrap();
        assert_eq!(&**composed, format!("DB_PASSWORD={value}").as_bytes());
        assert_eq!(
            composed.capacity(),
            composed.len(),
            "a grown buffer strands sealed bytes"
        );
        assert_eq!(
            store.ledger().count(),
            before,
            "the seam records the egress"
        );
        let (bytes, _) = store.copy_out_chip(chip).unwrap();
        assert_eq!(&**bytes, value.as_bytes(), "the chip survives");
    }

    #[test]
    fn name_value_refuses_an_unnamed_an_image_and_an_unknown_chip() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let unnamed = seal(&mut store, id, TOKEN);
        assert!(store.copy_out_name_value(unnamed).is_none());

        let image = store
            .seal_image(id, vec![0x89, b'P', b'N', b'G', 0, 1, 2, 3])
            .unwrap();
        store.set_chip_name(image, "LOGO").unwrap();
        assert!(
            store.copy_out_name_value(image).is_none(),
            "an image has no text to stand after `=`"
        );
        assert!(store.copy_out_name_value(ChipId::from_raw(4_242)).is_none());

        store.set_chip_name(unnamed, "API_KEY").unwrap();
        store.set_chip_name(unnamed, "").unwrap();
        assert!(
            store.copy_out_name_value(unnamed).is_none(),
            "a cleared name refuses again"
        );
    }

    #[test]
    fn a_name_outside_the_charset_is_refused_and_an_empty_one_clears() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, TOKEN);
        store.set_chip_name(chip, "  API_KEY \n").unwrap();
        assert_eq!(
            chip_name(&store, chip).as_deref(),
            Some("API_KEY"),
            "trimmed"
        );

        for refused in [
            "my.key",
            "my-key",
            "9lives",
            "two words",
            "na\u{EF}ve",
            "API_KEY=x",
            "API\0KEY",
            "\u{FF21}PI_KEY",
        ] {
            assert_eq!(
                store.set_chip_name(chip, refused),
                Err(NameRefusal::OutsideCharset),
                "{refused:?}"
            );
            assert_eq!(
                chip_name(&store, chip).as_deref(),
                Some("API_KEY"),
                "a refusal moved the name"
            );
        }
        for taken in ["_", "a", "Z9", "_9_lives"] {
            store.set_chip_name(chip, taken).unwrap();
            assert_eq!(chip_name(&store, chip).as_deref(), Some(taken));
        }

        let longest = "A".repeat(NAME_CAP);
        store.set_chip_name(chip, &longest).unwrap();
        assert_eq!(chip_name(&store, chip), Some(longest.clone()));
        assert_eq!(
            store.set_chip_name(chip, &"A".repeat(NAME_CAP + 1)),
            Err(NameRefusal::TooLong)
        );
        assert_eq!(
            store.set_chip_name(chip, &format!("{}.", "A".repeat(NAME_CAP + 9))),
            Err(NameRefusal::OutsideCharset),
            "the charset is judged before the length"
        );
        assert_eq!(chip_name(&store, chip), Some(longest));

        store.set_chip_name(chip, "   ").unwrap();
        assert_eq!(chip_name(&store, chip), None, "an empty draft clears");
        store.set_chip_name(chip, "API_KEY").unwrap();
        store.set_chip_name(chip, "").unwrap();
        assert_eq!(chip_name(&store, chip), None);

        assert_eq!(
            store.set_chip_name(ChipId::from_raw(4_242), "API_KEY"),
            Err(NameRefusal::UnknownChip)
        );
    }

    #[test]
    fn closing_a_page_records_the_page_and_the_chip_separately() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
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
        assert_eq!(page.title(), PLACEHOLDER);
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
        let id = store.new_tab().1;
        assert!(store.sync_document(id, vec![Segment::Ink("   \n".into())]));
        store.close_tab(slot(&store, id));
        assert_eq!(events(&store), vec![LedgerEvent::Created]);
    }

    #[test]
    fn the_content_predicate_is_the_one_the_ledger_already_used() {
        let cases: [(&str, &[&str], bool, bool); 7] = [
            ("nothing at all", &[], false, false),
            ("one stray newline", &["\n"], false, false),
            ("spaces and tabs", &["  \t \n  "], false, false),
            (
                "blank lines in several runs",
                &["\n", "   ", "\t"],
                false,
                false,
            ),
            ("a typed line", &["rotate the key"], false, true),
            ("ink after blank lines", &["\n\n", " done "], false, true),
            ("a chip and no ink at all", &["   "], true, true),
        ];
        for (what, ink, chip, expected) in cases {
            let (mut store, _) = store();
            let page = store.new_tab().1;
            let segments = ink
                .iter()
                .map(|text| Segment::Ink((*text).to_string()))
                .collect();
            assert!(store.sync_document(page, segments));
            if chip {
                seal(&mut store, page, "one secret");
            }

            assert_eq!(
                store
                    .sheet(page)
                    .expect("the page is standing")
                    .has_content(),
                expected,
                "{what}: the predicate"
            );
            let before = store.ledger().count();
            assert!(store.close_tab(slot(&store, page)));
            assert_eq!(
                store.ledger().count() > before,
                expected,
                "{what}: the ledger disagreed with the predicate it is made of"
            );
        }
    }

    #[test]
    fn an_expiring_page_still_leaves_its_tab_standing_whatever_it_held() {
        let (mut store, clock) = store();
        let blank = store.new_tab().1;
        let written = store.new_tab().1;
        store.set_rung(slot(&store, blank), Ttl::MIN).unwrap(); // 1h
        store.set_rung(slot(&store, written), Ttl::MIN).unwrap();
        assert!(store.sync_document(blank, vec![Segment::Ink("  \n".into())]));
        assert!(store.sync_document(written, vec![Segment::Ink("rotate the key".into())]));
        assert!(!store.sheet(blank).unwrap().has_content());
        assert!(store.sheet(written).unwrap().has_content());

        clock.advance(HOUR);
        assert_eq!(store.expire_due().len(), 2, "both countdowns ran out");

        assert_eq!(store.tabs().count(), 2, "the strip kept its width");
        assert!(store.holds_no_page());
        assert!(!store.has_no_tabs());
        assert_eq!(
            events(&store),
            vec![
                LedgerEvent::Expired,
                LedgerEvent::Created,
                LedgerEvent::Created
            ],
            "one death worth recording, two births"
        );
    }

    #[test]
    fn the_ledger_is_a_rolling_window_not_a_record_cap() {
        let (mut store, clock) = store();
        for i in 0..50 {
            let id = store.new_tab().1;
            assert!(store.sync_document(id, vec![Segment::Ink(format!("page {i}"))]));
            assert!(store.close_tab(slot(&store, id)));
        }
        assert_eq!(store.ledger().count(), 100);
        let titles: Vec<&str> = store.ledger().map(LedgerRecord::title).collect();
        assert_eq!(titles.first(), Some(&"page 49"), "newest first");

        clock.advance(Duration::from_millis(LEDGER_RETENTION_MS + 1));
        assert_eq!(store.ledger().count(), 100, "nothing ran on its own");
        store.new_tab();
        assert_eq!(events(&store), vec![LedgerEvent::Created]);
    }

    #[test]
    fn the_window_boundary_keeps_a_record_exactly_ninety_days_old() {
        let (mut store, clock) = store();
        store.new_tab();
        clock.advance(Duration::from_millis(LEDGER_RETENTION_MS));
        store.new_tab();
        assert_eq!(store.ledger().count(), 2, "the boundary is inclusive");
        clock.advance(Duration::from_millis(1));
        store.new_tab();
        assert_eq!(store.ledger().count(), 2, "the oldest fell off");
    }

    #[test]
    fn every_lifecycle_step_lands_exactly_one_record() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert_eq!(events(&store), vec![LedgerEvent::Created]);

        let chip = seal(&mut store, id, "one secret");
        assert_eq!(
            events(&store),
            vec![LedgerEvent::Sealed, LedgerEvent::Created]
        );

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
    fn concealing_a_whole_page_lands_one_content_free_sent_record() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, TOKEN);
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink(format!("rotate on friday\n{TOKEN}\n")),
                Segment::Chip(chip),
            ]
        ));
        let page = store.sheet(id).unwrap();
        let uuid = page.uuid();
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

        assert_content_free(&store);

        assert_eq!(store.len(), 1);
        assert!(
            !store.record_sheet_sent(SheetId(999), DestinationClass::OneTimeLink),
            "no such page"
        );
    }

    #[test]
    fn a_chip_removed_in_the_editor_records_the_same_as_an_explicit_delete() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
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
        let id = store.new_tab().1;
        seal(&mut store, id, "something");
        assert!(store.ledger().count() > 0);
        store.clear_ledger();
        assert_eq!(store.ledger().count(), 0);
        assert_eq!(store.len(), 1);
        assert_eq!(store.sheet(id).unwrap().chip_count(), 1);
    }

    #[test]
    fn a_hold_freezes_the_clock_and_lapses_on_its_own() {
        let (mut store, clock) = store();
        let id = store.new_tab().1; // 8h
        clock.advance(2 * HOUR); // 6h remain

        assert!(store.pause_press(slot(&store, id)));
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(sheet.is_held(now));
        assert_eq!(sheet.remaining(now), 6 * HOUR);

        clock.advance(HOUR / 2);
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(sheet.is_held(now));
        assert_eq!(sheet.remaining(now), 6 * HOUR);
        assert_eq!(sheet.hold_remaining(now), HOUR / 2);

        clock.advance(HOUR);
        let now = store.now();
        let sheet = store.sheet(id).unwrap();
        assert!(!sheet.is_held(now));
        assert_eq!(sheet.remaining(now), 6 * HOUR - HOUR / 2);
    }

    #[test]
    fn pause_presses_go_one_hour_then_topup_to_twentyfour_never_cumulative() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;

        assert!(store.pause_press(slot(&store, id))); // hold: 1h
        assert_eq!(store.sheet(id).unwrap().hold_remaining(store.now()), HOUR);
        assert!(!store.sheet(id).unwrap().hold_topped_up(store.now()));

        assert!(store.pause_press(slot(&store, id))); // extend: 24h from now
        assert_eq!(
            store.sheet(id).unwrap().hold_remaining(store.now()),
            24 * HOUR
        );
        assert!(store.sheet(id).unwrap().hold_topped_up(store.now()));

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
        let id = store.new_tab().1; // 8h
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
        assert_eq!(sheet.remaining(now), 6 * HOUR);
        assert_eq!(sheet.total_held(now), 3 * HOUR);

        clock.advance(HOUR);
        assert_eq!(store.sheet(id).unwrap().remaining(store.now()), 5 * HOUR);
        assert_eq!(store.sheet(id).unwrap().total_held(store.now()), 3 * HOUR);
    }

    #[test]
    fn a_released_page_expires_on_its_own_frozen_life() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
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
        let lapsed = {
            let (mut store, clock) = store();
            let id = store.new_tab().1;
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
            let id = store.new_tab().1;
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
        let id = store.new_tab().1;
        assert!(store.pause_press(slot(&store, id))); // 1h hold
        clock.advance(2 * HOUR); // lapses
        assert!(store.pause_press(slot(&store, id))); // a fresh first press again
        assert_eq!(store.sheet(id).unwrap().hold_remaining(store.now()), HOUR);
    }

    #[test]
    fn the_one_timer_covers_hold_lapses_too() {
        let (mut store, clock) = store();
        let id = store.new_tab().1; // 8h
        assert!(store.pause_press(slot(&store, id))); // hold lapses in 1h; expiry at 1h+8h
        let now = store.now();
        assert_eq!(
            store.next_event().unwrap() - now,
            HOUR,
            "the lapse, not the expiry"
        );

        clock.advance(HOUR);
        assert!(store.expire_due().is_empty());
        let now = store.now();
        assert_eq!(store.next_event().unwrap() - now, 8 * HOUR);
    }

    #[test]
    fn a_held_page_expires_only_after_hold_plus_frozen_life() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
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
        let id = store.new_tab().1;
        clock.advance(2 * HOUR);

        let rung = store.cycle_rung(slot(&store, id)).unwrap();
        assert_eq!(rung.to_string(), "3h");
        assert_eq!(store.sheet(id).unwrap().remaining(store.now()), 3 * HOUR);

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
        let id = store.new_tab().1;
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
        let id = store.new_tab().1;
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
        let a = store.new_tab().1;
        let b = store.new_tab().1;
        let c = store.new_tab().1;
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
        let id = store.new_tab().1;
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
    fn the_conceal_payload_is_written_at_its_exact_size() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, &"s3cr3t \u{1F511} ".repeat(300));
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink("before\n".repeat(200)),
                Segment::Chip(chip),
                Segment::Ink("after".into()),
            ]
        ));
        let payload = store.sheet_payload(id).unwrap();
        assert!(payload.len() > 4000);
        assert_eq!(payload.capacity(), payload.len());
    }

    #[test]
    fn sheet_payload_refuses_image_chips_and_unknown_sheets() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
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
    fn a_conceal_marks_the_chip_and_keeps_only_the_receipt() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, "conceal me");
        assert_eq!(&**store.chip_payload(chip).unwrap(), b"conceal me");
        assert!(store.mark_chip_concealed(chip, "9f2abc".into()));
        let sheet = store.sheet(id).unwrap();
        assert_eq!(
            sheet.chip(chip).unwrap().conceal().unwrap().receipt_id,
            "9f2abc"
        );
        assert_eq!(&**store.chip_payload(chip).unwrap(), b"conceal me");
        assert!(!store.mark_chip_concealed(ChipId(999), "x".into()));
    }

    #[test]
    fn the_gauge_drains_linearly_and_turns_last_hour_under_sixty_minutes() {
        let (mut store, clock) = store();
        let id = store.new_tab().1; // 8h
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
        let id = store.new_tab().1;
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
        assert_eq!(store.cycle_rung(slot(&store, id)), None);
        assert_eq!(store.set_rung(slot(&store, id), Ttl::MAX), None);
        assert!(contains(&store.snapshot(0), b"DOOMED"));
        assert_eq!(store.expire_due(), vec![id]);
    }

    #[test]
    fn a_rung_transition_compacts_the_history_and_the_body_survives() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
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

        let sheet = store.sheet(id).unwrap();
        assert_eq!(sheet.segments(), segments.as_slice());
        assert_eq!(sheet.derived_title().map(str::to_string), derived);
        assert_eq!(sheet.blocks_meta(), metas);
        assert_eq!(sheet.modified_s(), Some(modified));
        assert_ne!(sheet.document.peer_id(), old_peer);
        let (bytes, _) = store.copy_out_chip(chip).unwrap();
        assert_eq!(&**bytes, TOKEN.as_bytes());

        let snapshot = store.snapshot(0);
        assert!(contains(&snapshot, b"alpha  keep"), "the control: live ink");
        assert!(!contains(&snapshot, b"DOOMED"));
        assert!(!contains(&snapshot, &old_peer.to_le_bytes()));

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
        let id = store.new_tab().1;
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

        assert!(store.pause_press(slot(&store, id)));
        assert!(contains(&store.snapshot(0), b"DOOMED"));

        assert!(store.pause_press(slot(&store, id)));
        assert!(!contains(&store.snapshot(0), b"DOOMED"));
        assert_eq!(
            store.sheet(id).unwrap().hold_remaining(store.now()),
            24 * HOUR
        );
    }

    #[test]
    fn a_delete_at_the_end_of_the_body_keeps_the_names_and_the_summaries() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "top\n".into()
            }]
        ));
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 4,
                text: "one\ntwo\nthree".into()
            }]
        ));
        store.cycle_rung(slot(&store, id)).unwrap();
        let before = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(before.len(), 2);
        assert!(before.iter().all(|meta| meta.created_s.is_some()));

        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 12,
                len_u16: 5
            }]
        ));
        let after = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(after.len(), 3, "the finished sentence opened a block");
        assert_eq!(
            after[0].id, before[0].id,
            "the untouched block is untouched"
        );
        assert_eq!(after[1].id, before[1].id, "and the paste keeps its name");
        assert_eq!(after[0].created_s, before[0].created_s);
        assert_eq!(
            after[1].created_s, before[1].created_s,
            "a re-minted block would have no created stamp at all, its \
             frozen summary being the only evidence left"
        );
        assert_eq!(after[1].paragraphs, 2);
    }

    #[test]
    fn compaction_moves_no_clock_and_arms_no_timer() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "body\u{1F680}\nDOOMED".into()
            }]
        ));
        let before = store.next_event();
        store.sheet_mut(id).unwrap().compact();
        assert_eq!(store.next_event(), before);
    }

    #[test]
    fn an_empty_snapshot_is_select_all_delete_and_zeroizes_every_chip() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let a = seal(&mut store, id, "first secret");
        let b = seal(&mut store, id, "second secret");
        assert!(store.sync_document(id, vec![Segment::Chip(a), Segment::Chip(b)]));
        assert!(store.sync_document(id, Vec::new()));
        assert_eq!(store.sheet(id).unwrap().chip_count(), 0);
        assert!(store.copy_out_chip(a).is_none());
        assert!(store.copy_out_chip(b).is_none());
    }

    #[test]
    fn ops_and_a_legacy_snapshot_build_the_same_projection() {
        let (mut by_ops, _) = store();
        let (mut by_sync, _) = store();
        let ops_page = by_ops.new_tab().1;
        let sync_page = by_sync.new_tab().1;
        let ops_chip = seal(&mut by_ops, ops_page, "same secret");
        let sync_chip = seal(&mut by_sync, sync_page, "same secret");

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
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "a\u{1F600}SEC\u{1F600}b".into()
            }]
        ));
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
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "a\u{1F600}b".into()
            }]
        ));
        let before = store.sheet(id).unwrap().segments().to_vec();
        let records_before = store.ledger().count();
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
    fn a_range_seal_over_a_selected_chip_is_refused() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
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
        let before: Vec<Segment> = store.sheet(id).unwrap().segments().to_vec();
        let records_before = store.ledger().count();
        assert_eq!(
            store.seal_image_at(id, vec![1, 2, 3], 0, 3),
            Err(Refusal::AlreadySealed)
        );
        assert_eq!(
            store.seal_text_at(id, "a fresh secret", 1, 1),
            Err(Refusal::AlreadySealed)
        );
        assert_eq!(store.sheet(id).unwrap().segments(), before.as_slice());
        assert_eq!(store.sheet(id).unwrap().chip_count(), 1);
        assert!(store.copy_out_chip(old).is_some());
        assert_eq!(store.ledger().count(), records_before);
        let fresh = store.seal_text_at(id, "a fresh secret", 2, 1).unwrap();
        assert_eq!(
            store.sheet(id).unwrap().segments(),
            &[
                Segment::Ink("a".into()),
                Segment::Chip(old),
                Segment::Chip(fresh)
            ]
        );
    }

    #[test]
    fn a_batch_with_one_bad_op_mutates_nothing() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, "held through every refusal");
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
        assert!(!store.apply_ops(
            id,
            &[EditOp::InsertChip {
                pos_u16: 0,
                chip: ChipId(999)
            }]
        ));
        assert!(!store.apply_ops(id, &[EditOp::InsertChip { pos_u16: 0, chip }]));
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
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, "survives the shuffle");
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
        let id = store.new_tab().1;
        let chip = seal(&mut store, id, "deleted in the editor");
        assert!(store.apply_ops(id, &[EditOp::InsertChip { pos_u16: 0, chip }]));
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
        let id = store.new_tab().1;
        let a = seal(&mut store, id, "first secret");
        let b = seal(&mut store, id, "second secret");
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
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "## prod DB credentials\nrotate after".into()
            }]
        ));
        assert_eq!(label(&store, id), "prod DB credentials");

        assert!(store.set_title(slot(&store, id), "the vault"));
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "something else\n".into()
            }]
        ));
        assert_eq!(label(&store, id), "the vault");

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
        let id = store.new_tab().1;
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

        assert!(store.sync_document(id, vec![Segment::Ink("wholly\nrestated".into())]));
        let restated = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(restated.len(), 2);
        assert!(restated.iter().all(|block| block.id != whole[0].id));
    }

    #[test]
    fn the_page_floor_outlives_a_wholesale_restate() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let floor = 4_000_000_000; // year 2096, comfortably past any real wall clock
        let written = floor - 3600;
        let sheet = store.tabs[0].page.as_mut().expect("the tab holds a page");
        sheet.document.insert(0, "hello\n").unwrap();
        sheet.blocks.note_insert(0, "hello\n");
        sheet.document.insert(6, "world").unwrap();
        sheet.blocks.note_insert(6, "world");
        sheet.document.commit_at(written);
        sheet.document.delete(6, 5).unwrap();
        sheet.blocks.note_delete(6, 5);
        sheet.document.commit_at(floor);
        sheet.rebuild_segments();
        sheet.settle_blocks();
        sheet.compact();
        assert_eq!(
            sheet.modified_s(),
            Some(floor),
            "the deletion is the page's newest change, and the floor holds it"
        );

        assert!(store.sync_document(id, vec![Segment::Ink("wholly restated".into())]));
        assert_eq!(
            store.sheet(id).unwrap().modified_s(),
            Some(floor),
            "the floor rode through the block-index rebuild"
        );
    }

    #[test]
    fn a_multi_line_insert_lands_as_one_block_the_way_a_paste_arrives() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
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
        let id = store.new_tab().1;
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

        store.seal_text_at(id, "p\nbo", 2, 4).unwrap();
        let after = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(after.len(), 1);
        assert_eq!(after[0].id, before[0].id);
    }

    #[test]
    fn page_modified_derives_from_the_ops_and_created_stays_the_birth_stamp() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
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
        let id = store.new_tab().1;
        let origin = format!("{{\"origin\":\"{ORIGIN_URL}\"}}");
        store
            .seal_text_at_with_origin(id, TOKEN, 0, 0, Some(&origin))
            .unwrap();
        assert_content_free(&store);

        store.cycle_rung(slot(&store, id)).unwrap();
        assert_content_free(&store);
        let ledger = store.ledger_snapshot();
        for fragment in fragments_of(ORIGIN_URL) {
            assert!(
                !contains(&ledger, fragment.as_bytes()),
                "the ledger snapshot leaked {fragment:?}"
            );
        }

        assert!(store.close_tab(slot(&store, id)));
        assert_content_free(&store);
    }

    fn ship(
        from: &SheetStore<ManualClock>,
        from_page: SheetId,
        mirror: &mut SheetStore<ManualClock>,
        mirror_page: SheetId,
    ) -> Result<(), RemoteRefusal> {
        let frontier = mirror.document_version(mirror_page).unwrap();
        let delta = from.export_document_updates(from_page, &frontier).unwrap();
        mirror.apply_remote_update(mirror_page, &delta)
    }

    #[test]
    fn a_peers_updates_land_and_settle_like_local_edits() {
        let (mut alpha, _) = store();
        let (mut beta, _) = store();
        let a = alpha.new_tab().1;
        let b = beta.new_tab().1;

        assert!(alpha.apply_ops(
            a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "Shared title\nand a body".into(),
            }],
        ));
        ship(&alpha, a, &mut beta, b).unwrap();
        assert_eq!(
            beta.sheet(b).unwrap().segments(),
            alpha.sheet(a).unwrap().segments()
        );
        assert_eq!(beta.sheet(b).unwrap().derived_title(), Some("Shared title"));

        assert!(alpha.apply_ops(
            a,
            &[EditOp::Delete {
                pos_u16: 0,
                len_u16: 7,
            }],
        ));
        ship(&alpha, a, &mut beta, b).unwrap();
        assert_eq!(
            beta.sheet(b).unwrap().segments(),
            alpha.sheet(a).unwrap().segments()
        );
        assert_eq!(beta.sheet(b).unwrap().derived_title(), Some("title"));
    }

    #[test]
    fn a_remote_chip_the_page_does_not_own_refuses_whole() {
        let (mut alpha, _) = store();
        let (mut beta, _) = store();
        let a = alpha.new_tab().1;
        let b = beta.new_tab().1;

        assert!(alpha.apply_ops(
            a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "ink".into(),
            }],
        ));
        alpha.seal_text_at(a, "sealed bytes", 0, 0).unwrap();

        let before = beta.sheet(b).unwrap().segments().to_vec();
        assert_eq!(
            ship(&alpha, a, &mut beta, b),
            Err(RemoteRefusal::ChipRoster)
        );
        assert_eq!(beta.sheet(b).unwrap().segments(), &before[..]);
    }

    #[test]
    fn a_chip_delivered_first_lets_its_sentinel_land_and_die() {
        let (mut alpha, _) = store();
        let (mut beta, _) = store();
        let a = alpha.new_tab().1;
        let b = beta.new_tab().1;

        assert!(alpha.apply_ops(
            a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "before after".into(),
            }],
        ));
        let chip = alpha.seal_text_at(a, "the secret", 7, 0).unwrap();
        let uuid = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();

        {
            let sheet = beta.sheet_mut(b).unwrap();
            let id = ChipId(9001);
            sheet
                .chips
                .push(SealedChip::text_with_uuid(id, uuid, "the secret"));
        }
        ship(&alpha, a, &mut beta, b).unwrap();
        assert_eq!(beta.sheet(b).unwrap().chip_count(), 1);
        let mirrored: Vec<Segment> = beta.sheet(b).unwrap().segments().to_vec();
        assert!(matches!(mirrored[1], Segment::Chip(_)));

        assert!(alpha.apply_ops(
            a,
            &[EditOp::Delete {
                pos_u16: 7,
                len_u16: 1,
            }],
        ));
        ship(&alpha, a, &mut beta, b).unwrap();
        assert_eq!(beta.sheet(b).unwrap().chip_count(), 0);
        assert!(
            beta.ledger()
                .any(|record| record.event == LedgerEvent::Discarded && record.item == uuid),
            "the remote deletion left no Discarded record"
        );
    }

    #[test]
    fn a_device_across_the_boundary_rejoins_at_the_key_frame() {
        let (mut alpha, _) = store();
        let (mut beta, _) = store();
        let a = alpha.new_tab().1;
        let b = beta.new_tab().1;

        assert!(alpha.apply_ops(
            a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "early DOOMED words".into(),
            }],
        ));
        ship(&alpha, a, &mut beta, b).unwrap();

        assert!(alpha.apply_ops(
            a,
            &[EditOp::Delete {
                pos_u16: 5,
                len_u16: 7,
            }],
        ));
        alpha.cycle_rung(slot(&alpha, a)).unwrap();

        let refusal = ship(&alpha, a, &mut beta, b);
        assert!(
            matches!(
                refusal,
                Err(RemoteRefusal::MissingHistory | RemoteRefusal::ChipRoster)
            ) || { beta.sheet(b).unwrap().segments() != alpha.sheet(a).unwrap().segments() },
            "a stale mirror must never silently agree across a ceremony"
        );

        let uuid = alpha.sheet(a).unwrap().uuid();
        let frame = alpha.sheet(a).unwrap().document.export_snapshot();
        let tab = slot(&beta, b);
        assert!(beta.discard_page(b));
        let fresh = beta.open_page(tab).unwrap();
        beta.adopt_key_frame(fresh, uuid, &frame).unwrap();
        assert_eq!(beta.sheet(fresh).unwrap().uuid(), uuid);
        assert_eq!(
            beta.sheet(fresh).unwrap().segments(),
            alpha.sheet(a).unwrap().segments()
        );

        assert!(!contains(&frame, b"DOOMED"));
    }

    #[test]
    fn a_key_frame_lands_only_on_a_fresh_page() {
        let (mut alpha, _) = store();
        let (mut beta, _) = store();
        let a = alpha.new_tab().1;
        let b = beta.new_tab().1;

        assert!(alpha.apply_ops(
            a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "the channel state".into(),
            }],
        ));
        let frame = alpha.sheet(a).unwrap().document.export_snapshot();

        assert!(beta.apply_ops(
            b,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "standing history".into(),
            }],
        ));
        assert_eq!(
            beta.adopt_key_frame(b, alpha.sheet(a).unwrap().uuid(), &frame),
            Err(RemoteRefusal::NotFresh)
        );
        assert_eq!(
            beta.sheet(b).unwrap().derived_title(),
            Some("standing history")
        );
    }

    const WALL: u64 = 1_600_000_000_000;

    fn shared_page(
        skew_ms: u64,
    ) -> (
        SheetStore<ManualClock>,
        SheetStore<ManualClock>,
        SheetId,
        SheetId,
        ItemId,
        ManualClock,
        ManualClock,
    ) {
        let alpha_clock = ManualClock::new().with_wall_ms(WALL);
        let beta_clock = ManualClock::new().with_wall_ms(WALL + skew_ms);
        let mut alpha = store_on(alpha_clock.clone());
        let mut beta = store_on(beta_clock.clone());
        let a = alpha.new_tab().1;
        let b = beta.new_tab().1;
        assert!(alpha.apply_ops(
            a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "the shared page".into(),
            }],
        ));
        let uuid = alpha.sheet(a).unwrap().uuid();
        let frame = alpha.sheet(a).unwrap().document.export_snapshot();
        beta.adopt_key_frame(b, uuid, &frame).unwrap();
        (alpha, beta, a, b, uuid, alpha_clock, beta_clock)
    }

    #[test]
    fn two_stores_share_an_expiry_and_the_earlier_deadline_fires() {
        const SKEW: Duration = Duration::from_secs(600);
        let (mut alpha, mut beta, a, b, uuid, alpha_clock, beta_clock) = shared_page(millis(SKEW));

        let from_alpha = alpha.expiry_policy(a).unwrap();
        let from_beta = beta.expiry_policy(b).unwrap();
        assert!(!alpha.observe_peer_expiry(uuid, from_beta));
        assert!(beta.observe_peer_expiry(uuid, from_alpha));

        let to_early_deadline = eight_hours().duration() - SKEW;
        alpha_clock.advance(to_early_deadline);
        beta_clock.advance(to_early_deadline);
        assert_eq!(beta.expire_due(), vec![b]);
        assert!(
            alpha.expire_due().is_empty(),
            "alpha still believes in ten more minutes"
        );

        assert_eq!(alpha.observe_terminal(uuid), Some(a));
        assert!(alpha.sheet(a).is_none());
        for store in [&alpha, &beta] {
            assert!(
                store
                    .ledger()
                    .any(|record| record.event == LedgerEvent::Expired && record.item == uuid),
                "each device writes its own record of the one death"
            );
        }
    }

    #[test]
    fn a_hold_survives_a_peers_offline_deadline_and_the_returner_rejoins() {
        let (mut alpha, mut beta, a, b, uuid, alpha_clock, beta_clock) = shared_page(0);
        let rung = eight_hours().duration();

        let to_last_hour = rung - HOUR;
        alpha_clock.advance(to_last_hour);
        beta_clock.advance(to_last_hour);
        assert!(alpha.pause_press(slot(&alpha, a)));
        assert_eq!(
            alpha.expiry_policy(a),
            None,
            "a held page publishes its register, not a countdown"
        );
        let mut beta_channel = PageChannel::new();

        alpha_clock.advance(HOUR + Duration::from_secs(60));
        beta_clock.advance(HOUR + Duration::from_secs(60));
        assert_eq!(beta.expire_due(), vec![b]);
        assert!(
            beta.ledger()
                .any(|record| record.event == LedgerEvent::Expired && record.item == uuid)
        );

        assert!(!beta_channel.may_publish_terminal());

        assert!(alpha.expire_due().is_empty(), "the hold wins");
        let held = alpha.sheet(a).unwrap();
        assert!(held.remaining(alpha.now()) > Duration::ZERO);

        beta_channel.set_current(true);
        beta_channel.note_hold(alpha.hold_register(a).unwrap());
        let frame = alpha.sheet(a).unwrap().document.export_snapshot();
        let tab = slot_of_empty_tab(&beta);
        let fresh = beta.open_page(tab).unwrap();
        beta.adopt_key_frame(fresh, uuid, &frame).unwrap();
        assert!(beta.observe_peer_expiry(uuid, alpha.expiry_policy(a).unwrap()));
        assert_eq!(
            beta.sheet(fresh).unwrap().segments(),
            alpha.sheet(a).unwrap().segments()
        );

        let to_extended_deadline = HOUR - Duration::from_secs(120);
        alpha_clock.advance(to_extended_deadline);
        beta_clock.advance(to_extended_deadline);
        assert!(alpha.expire_due().is_empty());
        assert!(beta.expire_due().is_empty());
        alpha_clock.advance(Duration::from_secs(180));
        beta_clock.advance(Duration::from_secs(180));
        assert_eq!(alpha.expire_due(), vec![a]);
        assert_eq!(beta.expire_due(), vec![fresh]);
    }

    fn slot_of_empty_tab(store: &SheetStore<ManualClock>) -> TabId {
        store
            .tabs()
            .find(|tab| tab.page().is_none())
            .expect("an entombed page leaves its tab standing")
            .id()
    }

    #[test]
    fn a_live_hold_suspends_the_countdown_on_every_device() {
        let (mut alpha, mut beta, a, _b, uuid, alpha_clock, beta_clock) = shared_page(0);
        let b = beta.sheets().next().unwrap().id();

        assert!(alpha.pause_press(slot(&alpha, a)));
        let register = alpha.hold_register(a).unwrap();
        assert!(matches!(register, HoldRegister::Held { .. }));
        assert!(beta.observe_peer_hold(uuid, register));
        let frozen = beta.sheet(b).unwrap().remaining(beta.now());
        beta_clock.advance(Duration::from_secs(30 * 60));
        alpha_clock.advance(Duration::from_secs(30 * 60));
        assert_eq!(
            beta.sheet(b).unwrap().remaining(beta.now()),
            frozen,
            "a live hold suspends the countdown here exactly as there"
        );

        assert!(beta.observe_peer_hold(uuid, HoldRegister::Released));
        assert_eq!(beta.sheet(b).unwrap().remaining(beta.now()), frozen);
        beta_clock.advance(Duration::from_secs(60));
        assert_eq!(
            beta.sheet(b).unwrap().remaining(beta.now()),
            frozen - Duration::from_secs(60)
        );
    }

    #[test]
    fn a_peer_register_extends_the_hold_never_the_life() {
        let (_, mut beta, _a, b, uuid, _, beta_clock) = shared_page(0);
        let remaining = beta.sheet(b).unwrap().remaining(beta.now());

        assert!(beta.observe_peer_hold(
            uuid,
            HoldRegister::Held {
                until_wall_ms: u64::MAX,
                frozen_ms: u64::MAX,
                topped_up: false,
            }
        ));
        let sheet = beta.sheet(b).unwrap();
        assert!(sheet.is_held(beta.now()));
        assert_eq!(
            sheet.hold_remaining(beta.now()),
            HOLD_FIRST,
            "an untopped hold is bounded by the first-press hour"
        );
        beta_clock.advance(HOLD_FIRST);
        assert_eq!(
            beta.sheet(b).unwrap().remaining(beta.now()),
            remaining,
            "the lapse resumes exactly the life this device already believed in"
        );
    }

    #[test]
    fn a_peer_expiry_can_only_shorten_and_the_hold_ignores_it() {
        let (mut alpha, _, a, _b, uuid, _, _) = shared_page(0);

        let later = ExpiryPolicy {
            anchor_wall_ms: WALL,
            ttl_ms: millis(Ttl::default().duration()) + 1_000_000,
        };
        assert!(!alpha.observe_peer_expiry(uuid, later));

        let earlier = ExpiryPolicy {
            anchor_wall_ms: WALL,
            ttl_ms: millis(HOUR),
        };
        assert!(alpha.observe_peer_expiry(uuid, earlier));
        assert_eq!(alpha.sheet(a).unwrap().remaining(alpha.now()), HOUR);

        assert!(alpha.pause_press(slot(&alpha, a)));
        assert!(!alpha.observe_peer_expiry(
            uuid,
            ExpiryPolicy {
                anchor_wall_ms: WALL,
                ttl_ms: 1,
            }
        ));
        assert!(alpha.sheet(a).unwrap().is_held(alpha.now()));
    }

    #[test]
    fn a_solo_page_compacts_at_the_transition_exactly_as_before() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "solo".into(),
            }],
        ));
        let before = store.sheet(id).unwrap().document.peer_id();
        assert!(!store.ceremony_due(id));
        store.cycle_rung(slot(&store, id)).unwrap();
        assert_ne!(
            store.sheet(id).unwrap().document.peer_id(),
            before,
            "with no peer attached the transition compacts inline, exactly as it always has"
        );
        assert!(!store.ceremony_due(id));
    }

    #[test]
    fn a_deferred_page_keeps_its_history_until_the_ceremony_performs() {
        let (mut alpha, _) = store();
        let (mut joiner, _) = store();
        let id = alpha.new_tab().1;
        assert!(alpha.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "keep DOOMED".into(),
            }],
        ));
        assert!(alpha.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 4,
                len_u16: 7,
            }],
        ));
        assert!(alpha.set_compaction_deferred(id, true));

        let before = alpha.sheet(id).unwrap().document.peer_id();
        alpha.cycle_rung(slot(&alpha, id)).unwrap();
        assert_eq!(alpha.sheet(id).unwrap().document.peer_id(), before);
        assert!(alpha.ceremony_due(id));
        assert!(contains(
            &alpha.sheet(id).unwrap().document.export_snapshot(),
            b"DOOMED"
        ));

        let solo = alpha.new_tab().1;
        assert!(alpha.perform_ceremony(solo).is_none());

        let frame = alpha.perform_ceremony(id).unwrap();
        assert!(!alpha.ceremony_due(id));
        assert_ne!(alpha.sheet(id).unwrap().document.peer_id(), before);
        assert!(!contains(&frame, b"DOOMED"));
        let j = joiner.new_tab().1;
        let uuid = alpha.sheet(id).unwrap().uuid();
        joiner.adopt_key_frame(j, uuid, &frame).unwrap();
        assert_eq!(
            joiner.sheet(j).unwrap().segments(),
            alpha.sheet(id).unwrap().segments()
        );
    }

    #[test]
    fn returning_to_solo_with_a_ceremony_due_compacts_on_the_spot() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "left behind".into(),
            }],
        ));
        assert!(store.set_compaction_deferred(id, true));
        let before = store.sheet(id).unwrap().document.peer_id();
        store.cycle_rung(slot(&store, id)).unwrap();
        assert!(store.ceremony_due(id));

        assert!(store.set_compaction_deferred(id, false));
        assert!(!store.ceremony_due(id));
        assert_ne!(store.sheet(id).unwrap().document.peer_id(), before);
    }

    fn body(store: &SheetStore<ManualClock>, id: SheetId) -> String {
        store
            .sheet(id)
            .unwrap()
            .segments()
            .iter()
            .map(|segment| match segment {
                Segment::Ink(text) => text.clone(),
                Segment::Chip(_) => "\u{FFFC}".to_string(),
            })
            .collect()
    }

    #[test]
    fn a_step_back_takes_the_projection_with_it_and_a_step_forward_returns_it() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "a first draft".into(),
            }],
        ));
        assert!(store.can_undo(id));
        assert!(!store.can_redo(id));

        assert!(store.undo(id));
        assert_eq!(body(&store, id), "");
        assert_eq!(store.restored_caret_u16(id), Some(0));
        assert!(store.can_redo(id));

        assert!(store.redo(id));
        assert_eq!(body(&store, id), "a first draft");
        assert!(!store.can_redo(id));
    }

    #[test]
    fn an_unknown_page_steps_nowhere() {
        let (mut store, _) = store();
        let absent = SheetId::from_raw(4_242);
        assert!(!store.undo(absent));
        assert!(!store.redo(absent));
        assert!(!store.can_undo(absent));
        assert!(!store.can_redo(absent));
        assert_eq!(store.restored_caret_u16(absent), None);
    }

    #[test]
    fn a_seal_cannot_be_stepped_back() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "secret words".into(),
            }],
        ));
        store.seal_text_at(id, "secret words", 0, 12).unwrap();
        assert_eq!(body(&store, id), "\u{FFFC}");
        assert!(!store.can_undo(id));
        assert!(!store.undo(id));
    }

    #[test]
    fn burning_a_chip_takes_the_stack_with_it() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, "sealed", 0, 0).unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 1,
                text: " after".into(),
            }],
        ));
        assert!(store.can_undo(id));

        assert!(store.delete_chip(chip));
        assert!(!store.can_undo(id));
        assert!(!store.can_redo(id));
    }

    #[test]
    fn an_edit_the_page_made_itself_comes_off_in_one_press() {
        let (mut bounded, _) = store();
        let (mut merged, _) = store();
        let id = bounded.new_tab().1;
        let other = merged.new_tab().1;
        let store = &mut bounded;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "- milk".into(),
            }],
        ));
        assert!(store.apply_ops_as_new_step(
            id,
            &[EditOp::Insert {
                pos_u16: 6,
                text: "\n- ".into(),
            }],
        ));
        assert_eq!(body(store, id), "- milk\n- ");

        assert!(store.undo(id));
        assert_eq!(body(store, id), "- milk");
        assert!(store.can_undo(id), "the writer's own words went with it");

        assert!(merged.apply_ops(
            other,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "- milk".into(),
            }],
        ));
        assert!(merged.apply_ops(
            other,
            &[EditOp::Insert {
                pos_u16: 6,
                text: "\n- ".into(),
            }],
        ));
        assert!(merged.undo(other));
        assert_eq!(body(&merged, other), "");
    }

    #[test]
    fn type_paste_type_is_three_undo_steps() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops_with_intent(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "typed".into(),
            }],
            EditIntent::Typing,
        ));
        assert!(store.apply_ops_with_intent(
            id,
            &[EditOp::Insert {
                pos_u16: 5,
                text: " pasted".into(),
            }],
            EditIntent::Paste,
        ));
        assert!(store.apply_ops_with_intent(
            id,
            &[EditOp::Insert {
                pos_u16: 12,
                text: " typed".into(),
            }],
            EditIntent::Typing,
        ));

        assert_eq!(store.undo_action_name(id), Some("Typing"));
        assert!(store.undo(id));
        assert_eq!(body(&store, id), "typed pasted");
        assert_eq!(store.undo_action_name(id), Some("Paste"));
        assert_eq!(store.redo_action_name(id), Some("Typing"));
        assert!(store.undo(id));
        assert_eq!(body(&store, id), "typed");
        assert_eq!(store.undo_action_name(id), Some("Typing"));
        assert_eq!(store.redo_action_name(id), Some("Paste"));
        assert!(store.undo(id));
        assert_eq!(body(&store, id), "");
    }

    #[test]
    fn moving_the_caret_finishes_the_typing_group_without_adding_a_step() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops_with_intent(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "right".into(),
            }],
            EditIntent::Typing,
        ));
        assert!(store.finish_editing_group(id));
        assert!(store.apply_ops_with_intent(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "left ".into(),
            }],
            EditIntent::Typing,
        ));

        assert!(store.undo(id));
        assert_eq!(body(&store, id), "right");
        assert!(store.undo(id));
        assert_eq!(body(&store, id), "");
    }

    #[test]
    fn replacement_is_one_isolated_step() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops_with_intent(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "before".into(),
            }],
            EditIntent::Typing,
        ));
        assert!(store.apply_ops_with_intent(
            id,
            &[
                EditOp::Delete {
                    pos_u16: 0,
                    len_u16: 6,
                },
                EditOp::Insert {
                    pos_u16: 0,
                    text: "after".into(),
                },
            ],
            EditIntent::Replacement,
        ));

        assert!(store.undo(id));
        assert_eq!(body(&store, id), "before");
        assert!(store.undo(id));
        assert_eq!(body(&store, id), "");
    }

    #[test]
    fn undo_and_redo_restore_the_selections_on_each_side_of_a_replacement() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops_with_intent_and_selection(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "before".into(),
            }],
            EditIntent::Typing,
            EditSelection {
                before: TextSelection {
                    location_u16: 0,
                    length_u16: 0,
                },
                after: TextSelection {
                    location_u16: 6,
                    length_u16: 0,
                },
            },
        ));
        assert!(store.apply_ops_with_intent_and_selection(
            id,
            &[
                EditOp::Delete {
                    pos_u16: 0,
                    len_u16: 6,
                },
                EditOp::Insert {
                    pos_u16: 0,
                    text: "after".into(),
                },
            ],
            EditIntent::Replacement,
            EditSelection {
                before: TextSelection {
                    location_u16: 0,
                    length_u16: 6,
                },
                after: TextSelection {
                    location_u16: 5,
                    length_u16: 0,
                },
            },
        ));

        assert!(store.undo(id));
        assert_eq!(body(&store, id), "before");
        assert_eq!(
            store.restored_selection_u16(id),
            Some(TextSelection {
                location_u16: 0,
                length_u16: 6,
            })
        );
        assert!(store.redo(id));
        assert_eq!(body(&store, id), "after");
        assert_eq!(
            store.restored_selection_u16(id),
            Some(TextSelection {
                location_u16: 5,
                length_u16: 0,
            })
        );
    }

    #[test]
    fn a_merged_typing_run_restores_its_first_and_last_carets() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        for (at, text) in [(0, "a"), (1, "b")] {
            assert!(store.apply_ops_with_intent_and_selection(
                id,
                &[EditOp::Insert {
                    pos_u16: at,
                    text: text.into(),
                }],
                EditIntent::Typing,
                EditSelection {
                    before: TextSelection {
                        location_u16: at,
                        length_u16: 0,
                    },
                    after: TextSelection {
                        location_u16: at + 1,
                        length_u16: 0,
                    },
                },
            ));
        }

        assert!(store.undo(id));
        assert_eq!(
            store.restored_selection_u16(id),
            Some(TextSelection {
                location_u16: 0,
                length_u16: 0,
            })
        );
        assert!(store.redo(id));
        assert_eq!(
            store.restored_selection_u16(id),
            Some(TextSelection {
                location_u16: 2,
                length_u16: 0,
            })
        );
    }

    #[test]
    fn a_refused_discrete_action_does_not_leak_an_undo_boundary() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops_with_intent(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "a".into(),
            }],
            EditIntent::Typing,
        ));
        assert!(!store.apply_ops_with_intent(
            id,
            &[EditOp::Insert {
                pos_u16: 99,
                text: "refused".into(),
            }],
            EditIntent::Paste,
        ));
        assert!(store.apply_ops_with_intent(
            id,
            &[EditOp::Insert {
                pos_u16: 1,
                text: "b".into(),
            }],
            EditIntent::Typing,
        ));

        assert!(store.undo(id));
        assert_eq!(body(&store, id), "");
        assert!(!store.can_undo(id));
    }

    #[test]
    fn standing_a_sentinel_through_the_op_path_takes_the_stack_with_it() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text(id, "sealed").unwrap();
        assert!(store.apply_ops(id, &[EditOp::InsertChip { pos_u16: 0, chip }],));
        assert_eq!(body(&store, id), "\u{FFFC}");
        assert_eq!(store.sheet(id).unwrap().chips().count(), 1);

        assert!(!store.can_undo(id));
        assert!(!store.undo(id));
        assert_eq!(body(&store, id), "\u{FFFC}");
        assert_eq!(store.sheet(id).unwrap().chips().count(), 1);
    }

    #[test]
    fn undo_after_a_drag_that_carries_a_chip_leaves_the_chip_standing() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "ab cd".into(),
            }],
        ));
        let chip = store.seal_text_at(id, "dragged", 3, 2).unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 4,
                text: " ef".into(),
            }],
        ));
        assert!(store.can_undo(id));

        assert!(store.apply_ops(
            id,
            &[
                EditOp::Delete {
                    pos_u16: 3,
                    len_u16: 1,
                },
                EditOp::InsertChip { pos_u16: 0, chip },
            ],
        ));
        assert_eq!(body(&store, id), "\u{FFFC}ab  ef");

        assert!(!store.undo(id));
        assert!(!store.redo(id));
        assert_eq!(body(&store, id), "\u{FFFC}ab  ef");
        assert_eq!(&**store.copy_out_chip(chip).unwrap().0, b"dragged");
        assert!(!events(&store).contains(&LedgerEvent::Discarded));
    }

    #[test]
    fn every_store_path_that_writes_a_chip_mark_stands_its_sentinel_in_the_same_change() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let mark_only = store
            .sheet(id)
            .unwrap()
            .document
            .count_mark_only_chip_writes();
        let orphans =
            |_: &SheetStore<ManualClock>| mark_only.load(std::sync::atomic::Ordering::SeqCst);
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "one two".into(),
            }],
        ));
        let sealed = store.seal_text_at(id, "sealed in place", 4, 3).unwrap();
        assert_eq!(orphans(&store), 0, "seal");
        assert!(!store.can_undo(id));

        let stood = store.seal_text(id, "stood by op").unwrap();
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Delete {
                    pos_u16: 4,
                    len_u16: 1,
                },
                EditOp::InsertChip {
                    pos_u16: 0,
                    chip: sealed,
                },
                EditOp::InsertChip {
                    pos_u16: 1,
                    chip: stood,
                },
            ],
        ));
        assert_eq!(orphans(&store), 0, "op path");
        assert!(!store.can_undo(id));

        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink("x".into()),
                Segment::Chip(stood),
                Segment::Chip(sealed),
            ],
        ));
        assert_eq!(orphans(&store), 0, "wholesale restate");
        assert!(!store.can_undo(id));

        assert!(store.set_compaction_deferred(id, true));
        // Compaction re-types every chip in a single commit on a fresh document.
        assert!(store.perform_ceremony(id).is_some());
        assert!(!store.can_undo(id));
        assert_eq!(
            store.sheet(id).unwrap().segments(),
            &[
                Segment::Ink("x".into()),
                Segment::Chip(stood),
                Segment::Chip(sealed),
            ]
        );
    }

    #[test]
    fn a_deleted_chip_leaves_no_step_that_would_stand_it_again() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        store.seal_text_at(id, "sealed", 0, 0).unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 1,
                text: "ink".into(),
            }],
        ));
        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 0,
                len_u16: 1,
            }],
        ));
        assert_eq!(body(&store, id), "ink");
        assert!(store.sheet(id).unwrap().chips().next().is_none());
        assert!(!store.can_undo(id));
    }

    #[test]
    fn a_wholesale_restate_leaves_nothing_to_step_back_through() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "typed".into(),
            }],
        ));
        assert!(store.sync_document(id, vec![Segment::Ink("restated".into())]));
        assert_eq!(body(&store, id), "restated");
        assert!(!store.can_undo(id));
        assert!(!store.can_redo(id));
    }

    #[test]
    fn the_ceremony_leaves_the_page_with_nothing_to_step_back_through() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "before the boundary".into(),
            }],
        ));
        assert!(store.can_undo(id));

        store.cycle_rung(slot(&store, id)).unwrap();
        assert!(!store.can_undo(id));
        assert!(!store.undo(id));
        assert_eq!(body(&store, id), "before the boundary");
    }

    #[test]
    fn a_peers_chip_deletion_forgets_this_devices_steps() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        store.seal_text_at(id, "sealed", 0, 0).unwrap();
        let chip = store.sheet(id).unwrap().chips().next().unwrap().uuid;

        let mirror = SheetDocument::new();
        let shared = store
            .export_document_updates(id, &mirror.version())
            .unwrap();
        mirror.import_update(&shared, &[chip]).unwrap();

        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 1,
                text: "ink".into(),
            }],
        ));
        assert!(store.can_undo(id));

        mirror.delete(0, 1).unwrap();
        mirror.commit(None);
        let away = mirror
            .export_updates_since(&store.document_version(id).unwrap())
            .unwrap();
        store.apply_remote_update(id, &away).unwrap();

        assert_eq!(body(&store, id), "ink");
        assert!(store.sheet(id).unwrap().chips().next().is_none());
        assert!(
            !store.can_undo(id),
            "a step survived the death of the chip it could stand again"
        );
    }

    #[test]
    fn a_step_back_leaves_a_peers_edits_standing() {
        let (mut alpha, _) = store();
        let (mut beta, _) = store();
        let a = alpha.new_tab().1;
        let b = beta.new_tab().1;

        assert!(alpha.apply_ops(
            a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "mine.".into(),
            }],
        ));
        assert!(beta.apply_ops(
            b,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "theirs.".into(),
            }],
        ));
        let delta = beta
            .export_document_updates(b, &alpha.document_version(a).unwrap())
            .unwrap();
        alpha.apply_remote_update(a, &delta).unwrap();
        assert_eq!(alpha.sheet(a).unwrap().segments().len(), 1);

        assert!(alpha.undo(a));
        assert_eq!(body(&alpha, a), "theirs.");
        assert!(!alpha.can_undo(a));
    }
}
