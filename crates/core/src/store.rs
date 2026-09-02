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
use crate::document::{SheetDocument, UpdateRefusal};
use crate::ledger::{DestinationClass, LedgerEvent, LedgerRecord, SizeClass, evict_expired};
use crate::sheet::{
    CeremonyState, ChipId, ChipMeta, Conceal, ItemId, SealedChip, Segment, Sheet, SheetClock,
    SheetId, TITLE_CAP, Tab, TabId, derive_title,
};
use crate::sync::{ExpiryPolicy, HoldRegister};
use crate::ttl::Ttl;

/// The sheet cap: 9, the natural limit of the keyboard map (⌘1–⌘9;
/// ⌘0 belongs to the ledger). At the wall the store *refuses* the tenth
/// and says so — silent eviction of deliberately placed content would
/// break trust (doc 03 §5); eviction is by the countdown the user chose,
/// never LRU surprise. Whether 9 is too generous is open question №4;
/// the constant stays easy to lower.
pub const DEFAULT_SHEET_CAP: usize = 9;

/// The first double-click holds a page's clock for one hour…
///
/// The restore path reads it too: a hold is the one span the pause
/// gesture, and nothing else, gets to set, so a hold arriving out of a
/// file is bounded by the same ceiling the gesture would have applied
/// (ADR-0016 section 8).
pub(crate) const HOLD_FIRST: Duration = Duration::from_secs(60 * 60);
/// …and every further double-click tops the hold up to 24 hours from
/// now, never cumulative (doc 04). This is the ceiling the restore
/// path reads a topped-up hold against.
pub(crate) const HOLD_TOPUP: Duration = Duration::from_secs(24 * 60 * 60);

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

/// Why a sheet could not be assembled into a conceal payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PayloadError {
    /// No such sheet.
    UnknownSheet,
    /// The sheet holds an image chip; the v3 conceal payload is
    /// text-shaped (open question №3 — concealing an image is unresolved,
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

/// Why a remote update or key frame was refused. Every arm leaves the
/// page exactly as it was: refusal is whole, the same discipline the
/// restore path applies to a damaged file, because a remote edit does
/// not get a looser contract than a snapshot (issue #96).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteRefusal {
    /// No such page.
    UnknownSheet,
    /// The bytes do not decode as an update batch or key frame.
    Malformed,
    /// The update depends on operations this page's document does not
    /// hold: the sender is across a ceremony boundary, or this device
    /// was away for longer than one GOP. The recovery is to rejoin at
    /// the current key frame ([`SheetStore::adopt_key_frame`]), never
    /// to ask for history (ADR-0013, ADR-0021 section 1).
    MissingHistory,
    /// The update would stand a chip sentinel this page does not own,
    /// or stand one twice. The protocol delivers a chip's sealed bytes
    /// before the delta that references it, or the delta waits.
    ChipRoster,
    /// A key frame was offered to a page whose document already holds
    /// history. Joining is only ever from a fresh page: merging a key
    /// frame over standing ops would duplicate the body rather than
    /// replace it, and a device carrying pre-ceremony history drops it
    /// (a fresh page) before it rejoins (ADR-0021 sections 1 and 5).
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
            ceremony: CeremonyState::Immediate,
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

    /// Discard the page a slot holds and leave the slot standing: the
    /// sealed bytes are zeroized on the way out, the ledger keeps one
    /// `Discarded` record, and the tab keeps its name, its rung, its
    /// position and its place in the ⌘-number map. Returns whether a
    /// page by that id was standing.
    ///
    /// Page addressed, and that is the whole point of it. Closing is
    /// the slot's gesture and it is one of the two things that end a
    /// tab (ADR-0017); a gesture that names the content rather than
    /// the slot must not spend the arrangement the user built. The
    /// burn offered after a conceal is the caller this exists for:
    /// the content travelled, so the local copy may go, and the tab it
    /// travelled from is left the way an expiry leaves one.
    pub fn discard_page(&mut self, id: SheetId) -> bool {
        let offset = self.clock.local_offset_seconds();
        // The label is taken while the page is still standing, so the
        // record carries the name the strip was showing rather than the
        // one it falls back to a line later, exactly as `expire_due`
        // takes it.
        let Some((page, label)) = self.tab_of_mut(id).and_then(|tab| {
            let label = tab.label(offset);
            tab.page.take().map(|page| (page, label))
        }) else {
            return false;
        };
        self.entomb(page, label, LedgerEvent::Discarded);
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

    /// The local id of the page a cross-device identity names, if one
    /// stands here. Peers address a page only by its `uuid`, since
    /// local ids never leave the process, so this is the translation
    /// back: what arrived from another device, said in the ids the
    /// surface already holds. `None` for a page this device has
    /// expired, closed, or never had, which is an ordinary answer
    /// rather than an error.
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

    /// The store's wall-clock reading, Unix epoch milliseconds.
    ///
    /// It sits beside [`now`](SheetStore::now) because the two answer
    /// different questions and neither can be had from the other. A
    /// caller saying how much longer something has wants the monotonic
    /// reading, which survives a sleep and cannot be dragged about by
    /// the system clock. A caller saying *which day* something happened
    /// on wants this one, together with
    /// [`local_offset_seconds`](SheetStore::local_offset_seconds),
    /// the same pair a [`Tab::label`] placeholder is rendered from, so
    /// a caller reading both from here cannot bucket a page into a day
    /// its own label denies.
    #[must_use]
    pub fn wall_ms(&self) -> u64 {
        self.clock.wall_ms()
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
        // Sealing is the app's one irreversible gesture (ADR-0009), and
        // it has to be irreversible down here too. A step back over
        // this commit would pull the sentinel out and hand the settle
        // below a chip with nowhere to stand; a step forward again
        // would stand a sentinel for bytes already zeroized, which is a
        // document the restore path is right to call damage.
        sheet.document.forget_undo();
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
        self.apply_batch(id, ops, false)
    }

    /// [`SheetStore::apply_ops`] for a batch that must begin its own
    /// undo step: an edit the page made on the writer's behalf rather
    /// than at their dictation, such as a list marker it continued or
    /// an indent it nudged. One press takes the automation back and
    /// leaves the words typed before it standing, which the merge
    /// interval would otherwise refuse, the automation arriving a
    /// keystroke after the burst it should not join.
    pub fn apply_ops_as_new_step(&mut self, id: SheetId, ops: &[EditOp]) -> bool {
        self.apply_batch(id, ops, true)
    }

    fn apply_batch(&mut self, id: SheetId, ops: &[EditOp], new_step: bool) -> bool {
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
        if new_step {
            sheet.document.commit_as_new_step(None);
        } else {
            sheet.document.commit(None);
        }
        // A batch that stood a sentinel moved the chip roster, and the
        // roster is the one thing no step may walk backwards over. A
        // step back would pull the sentinel out, the settle below would
        // read the chip as deleted and zeroize it, and the redo that
        // should have put it back has been cleared by that same reap:
        // one ⌘Z would destroy a sealed chip. The seal path forgets for
        // this reason and so must this one, which is the route a drag
        // moving a selection that holds a chip arrives on.
        //
        // After the commit, not inside the loop: the operations become
        // an undo step when the transaction closes, so a stack cleared
        // while it was still open would simply be refilled here.
        if ops.iter().any(|op| matches!(op, EditOp::InsertChip { .. })) {
            sheet.document.forget_undo();
        }
        self.settle_document(id);
        clean
    }

    // -----------------------------------------------------------------
    // Undo, and why it is the core's (issue #132, ADR-0013)
    // -----------------------------------------------------------------

    /// Take back the page's last local edit, or the last couple of
    /// seconds of them. Returns whether anything was reverted; false
    /// means the stack was empty, the page unknown, or the library
    /// refused, and the seam above should leave the page alone.
    ///
    /// The stack is Loro's and it is bound to this document's own peer,
    /// so it can only ever revert operations this device authored. A
    /// neighbouring device's text is out of reach twice over: the
    /// library refuses it by design, and a device that joined at a key
    /// frame never held the operations an away-device undo would have
    /// to invert (ADR-0021 section 5).
    ///
    /// An accepted step settles exactly as an edit does. The block
    /// index was not narrated through it, so it rebuilds with fresh
    /// identities, which is the standing answer for any mutation that
    /// arrives without narration rather than a rule invented here.
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

    /// Where the caret belongs after the page's last accepted step, in
    /// UTF-16 code units. `None` for an unknown page, for a step that
    /// carried no position, or when nothing has been stepped at all.
    /// This is what stands in for `AppKit`'s selection restoration now
    /// that the stack lives down here.
    #[must_use]
    pub fn restored_caret_u16(&self, id: SheetId) -> Option<u32> {
        let caret = self.sheet(id)?.document.restored_caret()?;
        u32::try_from(caret).ok()
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
        // A wholesale restate is the one edit no step may reach behind.
        // The retype went in as ordinary local operations, so the stack
        // now holds a step that would put the whole superseded body
        // back, and every step under it describes offsets in a body
        // that no longer exists. The shell has always dropped its own
        // history here for the same reason; the core does it now
        // because the history is the core's.
        sheet.document.forget_undo();
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
        // A chip died in this edit, so the stack dies with it. Undoing
        // the delete that swallowed a sentinel would stand it again for
        // bytes that are already zeroized, and a sentinel with no chip
        // behind it is the one shape the restore path treats as damage.
        // This is the choke point for it: every ⌫ over a chip, every
        // peer's delete, and every settle reaches here.
        if !dropped.is_empty() {
            sheet.document.forget_undo();
        }
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

    // -----------------------------------------------------------------
    // The delta seam: what sync puts on a wire (issue #96, ADR-0021 §1)
    // -----------------------------------------------------------------

    /// A page's sync frontier, as opaque bytes: the cursor a peer hands
    /// back to [`SheetStore::export_document_updates`] to ask for what
    /// it has not seen. Opaque on purpose — nothing above the document
    /// module may read a peer identity out of it (issue #96). `None`
    /// for an unknown page.
    #[must_use]
    pub fn document_version(&self, id: SheetId) -> Option<Vec<u8>> {
        Some(self.sheet(id)?.document.version())
    }

    /// The frontier before anything: the cursor that asks
    /// [`SheetStore::export_document_updates`] for a page's whole
    /// current GOP — what the session layer starts from at enrolment.
    /// A constant of the encoding, page-independent.
    #[must_use]
    pub fn pristine_document_version() -> Vec<u8> {
        crate::document::SheetDocument::pristine_version()
    }

    /// The operations a page's document holds beyond `since`: the
    /// delta a peer at that frontier needs, ADR-0013's P-frames,
    /// plaintext here and sealed by the seam above before any wire
    /// (ADR-0021 section 2). `None` for an unknown page or a frontier
    /// that does not decode. A stale frontier from across a ceremony
    /// boundary is well-formed and yields the whole current GOP.
    #[must_use]
    pub fn export_document_updates(&self, id: SheetId, since: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        self.sheet(id)?.document.export_updates_since(since)
    }

    /// Apply a peer's update batch to a page, refusing it whole unless
    /// it lands cleanly: decodable, no missing dependencies, and every
    /// chip sentinel resolving one-to-one against the chips this page
    /// owns. An accepted batch then settles exactly as a local edit
    /// does ([`SheetStore::settle_document`]): the projection rebuilds,
    /// the title re-derives, and a chip whose sentinel a peer deleted
    /// dies here with the same `Discarded` record ⌫ writes. The block
    /// index was not narrated op by op, so it rebuilds with fresh
    /// identities, which is the standing fallback for any unnarrated
    /// mutation rather than a new rule.
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

    /// Join a page to a channel's current key frame: the whole sealed
    /// state a device adopts instead of the history it structurally
    /// never receives (ADR-0013, ADR-0021 section 5). Only a fresh
    /// page — one whose document holds no operations — may adopt, so a
    /// device carrying pre-ceremony history drops it first and rejoins
    /// empty; anything else is refused whole. The same chip-roster
    /// discipline applies: a key frame referencing chips this page does
    /// not own waits for the protocol to deliver them.
    ///
    /// `page` is the page's cross-device identity, and the adopting
    /// sheet takes it over its own minted one: two devices holding one
    /// page hold it under one [`ItemId`], which is what lets a peer's
    /// expiry, hold and terminal marker name it, and what makes two
    /// ledgers' records of one death describe the same page (ADR-0021
    /// section 6).
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

    // -----------------------------------------------------------------
    // The coordinated ceremony (issue #101, ADR-0021 §2)
    // -----------------------------------------------------------------

    /// Mark a page's compaction as deferred to its sync channel, or
    /// return it to solo behaviour. Deferred is what the session layer
    /// sets while peers are attached: a rung transition then marks the
    /// ceremony due instead of compacting, and the history stands
    /// until [`SheetStore::perform_ceremony`] runs on the channel's
    /// confirmation. Returning to solo with a ceremony still due — the
    /// last peer detached mid-proposal — performs the compaction on
    /// the spot, because a solo device answers to nobody and a due
    /// boundary must not be forgotten. Returns whether the page
    /// existed.
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

    /// Whether a deferred page has a transition waiting on its
    /// ceremony: the signal that this device should propose one to the
    /// channel.
    #[must_use]
    pub fn ceremony_due(&self, id: SheetId) -> bool {
        self.sheet(id)
            .is_some_and(|sheet| sheet.ceremony == CeremonyState::Deferred { due: true })
    }

    /// Perform a confirmed ceremony on a deferred page: graduate and
    /// compact exactly as a solo transition does, clear the due mark,
    /// and hand back the fresh key frame for the channel — the sealed
    /// state a joining device adopts and the frame that supersedes its
    /// predecessor on the relay (ADR-0021 sections 1 and 5). `None`
    /// for an unknown page or one that is not deferred: a solo page's
    /// ceremonies run inline at the transition, and this seam must
    /// not offer a second door to the same event.
    ///
    /// The caller runs this only on a confirmed ballot
    /// ([`crate::sync::PageChannel::ceremony_confirmed`]), and pairs
    /// it with the GOP key rotation: the rebuild here and the rotation
    /// above the seam are two halves of one event, sequenced by the
    /// caller so that neither is left half done — the frame this
    /// returns is sealed under the incoming key, and the outgoing key
    /// dies only after both halves landed.
    pub fn perform_ceremony(&mut self, id: SheetId) -> Option<Zeroizing<Vec<u8>>> {
        let sheet = self.sheet_mut(id)?;
        if !matches!(sheet.ceremony, CeremonyState::Deferred { .. }) {
            return None;
        }
        sheet.compact();
        sheet.ceremony = CeremonyState::Deferred { due: false };
        Some(sheet.document.export_snapshot())
    }

    // -----------------------------------------------------------------
    // Whose clock expires a page (issue #100, ADR-0021 §6)
    // -----------------------------------------------------------------

    /// The expiry policy a device publishes for a page: the wall-clock
    /// pair, never the deadline (ADR-0021 section 6). Read off the
    /// live countdown — anchor now, ttl the remaining life — so the
    /// sum names the same instant the local monotonic deadline does,
    /// translated onto the one clock two machines share. `None` for an
    /// unknown page or one under a live hold, whose countdown is
    /// suspended: the hold register speaks for it instead
    /// ([`SheetStore::hold_register`]).
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

    /// Apply a peer's published expiry to the page it names: the
    /// minimum rule. The candidate deadline is computed on this
    /// device's own wall clock and can only ever shorten the local
    /// one — the same never-extend arithmetic the restart gap follows,
    /// with skew accepted in the one direction that is recoverable. A
    /// candidate already in the past shortens the page to due, and the
    /// armed timer reaps it. A page under a live hold ignores every
    /// candidate: the hold is the user's instruction, not a clock, and
    /// it wins (ADR-0021 section 6). Returns whether the deadline
    /// moved.
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

    /// The pause machine's state as it replicates: what this device
    /// publishes for a page's hold register. `None` for an unknown
    /// page; a lapsed hold reads as released, exactly as it
    /// normalizes.
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

    /// Apply a peer's hold register to the page it names: a live hold
    /// suspends the countdown here exactly as it suspends it there,
    /// and a release resumes it (ADR-0021 section 6). The register
    /// extends the *hold*, never the *life*: the hold span is bounded
    /// by the same ceiling the gesture would have applied — one hour
    /// untopped, twenty-four topped up, the restore path's discipline
    /// (ADR-0016 section 8) — and the frozen remaining life can only
    /// come down, never up, from what this device already believes. A
    /// due page refuses, as the gesture would: zero means zeroized.
    /// Returns whether the clock changed.
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
                // The channel re-states the hold — a top-up pressed
                // elsewhere, usually. Adopt its span under the ceiling
                // and keep the smaller frozen life.
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
                // A release elsewhere releases here: the held span
                // closes into the running total exactly as the third
                // press closes it.
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

    /// A peer's terminal marker for a page: the death is agreed, so
    /// this device entombs its copy now — sealed bytes zeroized, one
    /// `Expired` record in its own ledger, the tab left standing —
    /// whatever its own clock still believed. Two wall-stamped ledgers
    /// describing one death is expected and correct (ADR-0021 section
    /// 6). Returns the dead page's local id, or `None` when no page by
    /// that identity stands, which is the ordinary case of a marker
    /// arriving after this device's own countdown already fired.
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

    /// A page by its cross-device identity, mutably: the only address
    /// a peer can name a page by, since local ids never leave the
    /// process.
    fn sheet_mut_by_uuid(&mut self, page: ItemId) -> Option<&mut Sheet> {
        self.tabs
            .iter_mut()
            .filter_map(|tab| tab.page.as_mut())
            .find(|sheet| sheet.uuid == page)
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
    // Chips: copy-out, delete, conceal
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
            // The bytes are about to die, so no step may reach the
            // sentinel that pointed at them: undo never un-seals, and
            // never resurrects (ADR-0009). The stack goes even when the
            // chip had no sentinel to remove, because a chip leaving
            // the roster is enough to make every step behind it a
            // description of a page that no longer exists.
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
    /// page-level twin of [`SheetStore::record_sent`]: concealing a page
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

    /// Record a successful conceal: only the receipt identifier stays
    /// on the live chip (no link, no history — doc 03 §5).
    pub fn mark_chip_concealed(&mut self, id: ChipId, receipt_id: String) -> bool {
        for sheet in self.tabs.iter_mut().filter_map(|tab| tab.page.as_mut()) {
            if let Some(chip) = sheet.chips.iter_mut().find(|c| c.id == id) {
                chip.conceal = Some(Conceal { receipt_id });
                return true;
            }
        }
        false
    }

    /// A chip's bytes for the conceal path (core → network client
    /// directly, never through the UI layer — the boundary law).
    #[must_use]
    pub fn chip_payload(&self, id: ChipId) -> Option<Zeroizing<Vec<u8>>> {
        self.copy_out_chip(id).map(|(bytes, _)| bytes)
    }

    /// The whole page as one conceal payload: ink verbatim, sealed
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
        // means compaction can never race the reap. With peers
        // attached the boundary becomes a proposal instead
        // (issue #101), and the gesture itself is not held up.
        tab.page
            .as_mut()
            .expect("the tab holds the page found")
            .compact_or_defer();
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
        // rung transition sheds the history, or proposes to, when
        // peers are attached.
        tab.page
            .as_mut()
            .expect("the tab holds the page found")
            .compact_or_defer();
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
                // clockwork — or propose to, when peers are attached.
                sheet.compact_or_defer();
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
    ///
    /// The bar is [`Sheet::has_content`] rather than a walk written out
    /// here, because it is also the answer anything else asking whether
    /// a page holds something gets. Two spellings of the same predicate
    /// would eventually disagree, and the disagreement would be between
    /// what a surface shows and what the ledger admits happened.
    #[expect(
        clippy::needless_pass_by_value,
        reason = "consuming is the point: the page dies here, and its SecretBuffers zeroize as it drops"
    )]
    fn entomb(&mut self, sheet: Sheet, label: String, event: LedgerEvent) {
        if !sheet.has_content() {
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

/// A duration as whole milliseconds, saturating at the top instead of
/// silently truncating: every span here is bounded by the ladder and
/// the hold ceilings, so the saturation is belt to those braces.
fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// The document module's refusal, restated in the store's vocabulary.
/// A plain `From` impl would do it, but the mapping is spelled out so
/// the two enums cannot drift apart silently: a new arm on either side
/// is a compile error here.
fn refusal_from(refusal: UpdateRefusal) -> RemoteRefusal {
    match refusal {
        UpdateRefusal::Malformed => RemoteRefusal::Malformed,
        UpdateRefusal::MissingHistory => RemoteRefusal::MissingHistory,
        UpdateRefusal::ChipRoster => RemoteRefusal::ChipRoster,
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
    use crate::sync::PageChannel;

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
    fn a_cross_device_identity_names_the_local_page_it_stands_in() {
        let (mut store, _) = store();
        let first = store.new_tab().unwrap().1;
        let second = store.new_tab().unwrap().1;
        let identity = store.sheet(first).unwrap().uuid();
        assert_eq!(store.sheet_id_of(identity), Some(first));
        assert_ne!(store.sheet_id_of(identity), Some(second));
        assert_eq!(
            store.sheet_id_of(ItemId::random()),
            None,
            "an identity no page here holds is an ordinary answer"
        );
        // A page this device has let go is one of those: what a peer
        // says about it can no longer be shown anywhere.
        store.close_tab(slot(&store, first));
        assert_eq!(store.sheet_id_of(identity), None);
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
    fn discarding_a_page_leaves_its_tab_the_way_an_expiry_would() {
        let (mut store, _) = store();
        let first = store.new_tab().unwrap().1;
        let concealed = store.new_tab().unwrap().1;
        let tab = slot(&store, concealed);
        assert!(store.set_title(tab, "payroll"));
        store.set_rung(tab, Ttl::MIN).unwrap();
        assert!(store.sync_document(concealed, vec![Segment::Ink("the link travelled".into())]));

        assert!(store.discard_page(concealed));

        // The slot survives the burn: this is the gesture that names
        // content, and only a close and the cap end a tab.
        let tabs: Vec<&Tab> = store.tabs().collect();
        assert_eq!(tabs.len(), 2, "the strip kept its width");
        assert_eq!(tabs[0].page().map(Sheet::id), Some(first), "and its order");
        assert!(tabs[1].page().is_none(), "the page is gone");
        assert_eq!(tabs[1].id(), tab, "the slot is the same slot");
        assert_eq!(tabs[1].name(), Some("payroll"), "with its name");
        assert_eq!(tabs[1].rung(), Ttl::MIN, "and its rung");
        assert!(store.sheet(concealed).is_none());

        // One death record, carrying the label the strip was showing.
        let record = store.ledger().next().unwrap();
        assert_eq!(record.event(), LedgerEvent::Discarded);
        assert_eq!(record.title(), "payroll");

        // A page that is no longer standing refuses, twice over: the
        // one just discarded, and one that never existed.
        assert!(!store.discard_page(concealed), "already gone");
        assert!(!store.discard_page(SheetId::from_raw(999)), "no such page");

        // The slot takes another page at the rung it kept.
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
    fn the_content_predicate_is_the_one_the_ledger_already_used() {
        // Whether a page holds something now has one definition and two
        // readers, so the matrix asks both about the same page: the
        // predicate before it dies, and the ledger after. They must
        // never differ, or a surface would show a page as having
        // something on it that the audit trail says did nothing.
        //
        // Each case: what the page holds, whether a chip is sealed onto
        // it, and whether that amounts to content.
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
            let page = store.new_tab().unwrap().1;
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
        let blank = store.new_tab().unwrap().1;
        let written = store.new_tab().unwrap().1;
        store.set_rung(slot(&store, blank), Ttl::MIN).unwrap(); // 1h
        store.set_rung(slot(&store, written), Ttl::MIN).unwrap();
        assert!(store.sync_document(blank, vec![Segment::Ink("  \n".into())]));
        assert!(store.sync_document(written, vec![Segment::Ink("rotate the key".into())]));
        assert!(!store.sheet(blank).unwrap().has_content());
        assert!(store.sheet(written).unwrap().has_content());

        clock.advance(HOUR);
        assert_eq!(store.expire_due().len(), 2, "both countdowns ran out");

        // Two slots before, two slots after. What a page held decides
        // what the ledger records and nothing else: it never decides
        // whether the tab the page stood in survives. A reader who
        // groups pages by anything at all is reading a projection, and
        // the strip underneath it did not move.
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
    fn concealing_a_whole_page_lands_one_content_free_sent_record() {
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
    fn a_conceal_marks_the_chip_and_keeps_only_the_receipt() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        let chip = seal(&mut store, id, "conceal me");
        assert_eq!(&**store.chip_payload(chip).unwrap(), b"conceal me");
        assert!(store.mark_chip_concealed(chip, "9f2abc".into()));
        let sheet = store.sheet(id).unwrap();
        assert_eq!(
            sheet.chip(chip).unwrap().conceal().unwrap().receipt_id,
            "9f2abc"
        );
        assert!(!store.mark_chip_concealed(ChipId(999), "x".into()));
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
    fn a_delete_at_the_end_of_the_body_keeps_the_names_and_the_summaries() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "top\n".into()
            }]
        ));
        // A paste under it, three lines under one name (ADR-0013).
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 4,
                text: "one\ntwo\nthree".into()
            }]
        ));
        // Past the ceremony the summaries are the page's whole memory
        // of itself: nothing else can say when either block appeared.
        store.cycle_rung(slot(&store, id)).unwrap();
        let before = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(before.len(), 2);
        assert!(before.iter().all(|meta| meta.created_s.is_some()));

        // Select the paste's last line and delete it. The body ends on
        // a newline now, which changes where the last block ends and
        // nothing else: an edit at the foot of the page is not grounds
        // for renaming the page.
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
    fn the_page_floor_outlives_a_wholesale_restate() {
        // A deletion is the page's newest change, and compaction freezes
        // it as the page floor (the stamp no surviving character can
        // carry). A wholesale restate then rebuilds the block index
        // through the settle mismatch branch, and the floor must ride
        // through that rebuild rather than die with the old identities.
        // Were it dropped, the page's modified stamp would step back
        // below its newest real change the moment a resync tripped the
        // rebuild.
        //
        // The stamps are injected into the far future, past the wall
        // clock the restate's own commit reads from the system, so a
        // dropped floor is observable: with it gone the page answers
        // with the restate's smaller stamp instead.
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
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

        // A wholly new body through the restate path, which trips the
        // settle mismatch and rebuilds the block index from scratch.
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

    // ------------------------------------------------------------------
    // The delta seam at the store (issue #96, ADR-0021 §1)
    // ------------------------------------------------------------------

    /// Ship every update `from` holds beyond `mirror`'s frontier into
    /// `mirror`: the round one publish-and-fetch cycle performs, minus
    /// the wire.
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
        let a = alpha.new_tab().unwrap().1;
        let b = beta.new_tab().unwrap().1;

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
        // The settle ran: the mirrored page derived the same title.
        assert_eq!(beta.sheet(b).unwrap().derived_title(), Some("Shared title"));

        // Deltas are incremental: a second edit ships alone and lands
        // on top of the first.
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
        let a = alpha.new_tab().unwrap().1;
        let b = beta.new_tab().unwrap().1;

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
        // Refused whole: not even the ink landed.
        assert_eq!(beta.sheet(b).unwrap().segments(), &before[..]);
    }

    #[test]
    fn a_chip_delivered_first_lets_its_sentinel_land_and_die() {
        let (mut alpha, _) = store();
        let (mut beta, _) = store();
        let a = alpha.new_tab().unwrap().1;
        let b = beta.new_tab().unwrap().1;

        assert!(alpha.apply_ops(
            a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "before after".into(),
            }],
        ));
        let chip = alpha.seal_text_at(a, "the secret", 7, 0).unwrap();
        let uuid = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();

        // Simulate the protocol delivering the chip's sealed bytes
        // ahead of the delta (the ChipRoster contract): the mirror owns
        // a chip under the same identity before the sentinel arrives.
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

        // A peer deleting the sentinel kills the mirror's chip through
        // the same settle a local ⌫ takes, Discarded record included.
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
        let a = alpha.new_tab().unwrap().1;
        let b = beta.new_tab().unwrap().1;

        // The mirror follows for a while…
        assert!(alpha.apply_ops(
            a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "early DOOMED words".into(),
            }],
        ));
        ship(&alpha, a, &mut beta, b).unwrap();

        // …then sleeps through a ceremony.
        assert!(alpha.apply_ops(
            a,
            &[EditOp::Delete {
                pos_u16: 5,
                len_u16: 7,
            }],
        ));
        alpha.cycle_rung(slot(&alpha, a)).unwrap();

        // Its stale frontier is answered with the whole current GOP,
        // which its pre-ceremony history cannot accept…
        let refusal = ship(&alpha, a, &mut beta, b);
        assert!(
            matches!(
                refusal,
                Err(RemoteRefusal::MissingHistory | RemoteRefusal::ChipRoster)
            ) || {
                // A post-ceremony full export has no dependency on the
                // old history, so the import may also land as a merge —
                // which would duplicate the body. Either way the mirror
                // must not end up agreeing silently; assert it did not.
                beta.sheet(b).unwrap().segments() != alpha.sheet(a).unwrap().segments()
            },
            "a stale mirror must never silently agree across a ceremony"
        );

        // …so it drops what it holds and rejoins at the key frame: a
        // fresh page adopting the channel's current state whole, under
        // the channel's page identity.
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

        // And the frame it adopted carries nothing from behind the
        // boundary.
        assert!(!contains(&frame, b"DOOMED"));
    }

    #[test]
    fn a_key_frame_lands_only_on_a_fresh_page() {
        let (mut alpha, _) = store();
        let (mut beta, _) = store();
        let a = alpha.new_tab().unwrap().1;
        let b = beta.new_tab().unwrap().1;

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

    // ------------------------------------------------------------------
    // Whose clock expires a page (issue #100, ADR-0021 §6)
    // ------------------------------------------------------------------

    /// A wall-clock anchor for the skew tests, distinct from the
    /// manual clock's default so nothing accidentally relies on it.
    const WALL: u64 = 1_600_000_000_000;

    /// Two stores holding one page: `beta` adopts `alpha`'s page whole
    /// — key frame and cross-device identity — with `skew_ms` added to
    /// beta's wall clock. Returns both stores, both page ids, and the
    /// shared identity.
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
        let mut alpha = SheetStore::new(alpha_clock.clone());
        let mut beta = SheetStore::new(beta_clock.clone());
        let a = alpha.new_tab().unwrap().1;
        let b = beta.new_tab().unwrap().1;
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

    // The first test ADR-0021 section 6 names: two stores driven
    // through a shared expiry, and the earlier deadline is the one
    // that fires — on both devices.
    #[test]
    fn two_stores_share_an_expiry_and_the_earlier_deadline_fires() {
        const SKEW: Duration = Duration::from_secs(600);
        let (mut alpha, mut beta, a, b, uuid, alpha_clock, beta_clock) = shared_page(millis(SKEW));

        // Each device publishes the policy pair and observes the
        // other's. Beta's clock runs ten minutes fast, so alpha reads
        // beta's candidate as later and ignores it, while beta reads
        // alpha's as earlier and shortens: the minimum rule, working
        // in the one direction failure is allowed to point.
        let from_alpha = alpha.expiry_policy(a).unwrap();
        let from_beta = beta.expiry_policy(b).unwrap();
        assert!(!alpha.observe_peer_expiry(uuid, from_beta));
        assert!(beta.observe_peer_expiry(uuid, from_alpha));

        // The earlier reading fires first: beta's page dies a skew
        // early by its own clock…
        let to_early_deadline = Ttl::default().duration() - SKEW;
        alpha_clock.advance(to_early_deadline);
        beta_clock.advance(to_early_deadline);
        assert_eq!(beta.expire_due(), vec![b]);
        assert!(
            alpha.expire_due().is_empty(),
            "alpha still believes in ten more minutes"
        );

        // …and its terminal marker carries the death to alpha, whose
        // own clock had life left. Dying early is recoverable; living
        // long is the failure this app exists to prevent.
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

    // The second test ADR-0021 section 6 names: a hold on one store
    // survives the other's offline deadline, and the returning store
    // rejoins the still-live page rather than killing it.
    #[test]
    fn a_hold_survives_a_peers_offline_deadline_and_the_returner_rejoins() {
        let (mut alpha, mut beta, a, b, uuid, alpha_clock, beta_clock) = shared_page(0);
        let rung = Ttl::default().duration();

        // One hour before the shared deadline, alpha holds the page.
        // Beta is offline: the register never reaches it, and its view
        // of the channel is not current.
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

        // Beta sits out the original deadline. It entombs its own copy
        // on its own clock — its plaintext does not outlive its own
        // belief — and writes its own Expired record…
        alpha_clock.advance(HOUR + Duration::from_secs(60));
        beta_clock.advance(HOUR + Duration::from_secs(60));
        assert_eq!(beta.expire_due(), vec![b]);
        assert!(
            beta.ledger()
                .any(|record| record.event == LedgerEvent::Expired && record.item == uuid)
        );

        // …but it may not publish the terminal marker: its view of the
        // hold register was not current with the channel, so it cannot
        // know whether a hold it never saw is keeping the page alive.
        assert!(!beta_channel.may_publish_terminal());

        // And one is: the holder's page survives its original
        // deadline. The hold lapsed after its hour and the frozen
        // remaining hour resumed, so the page is alive with life left.
        assert!(alpha.expire_due().is_empty(), "the hold wins");
        let held = alpha.sheet(a).unwrap();
        assert!(held.remaining(alpha.now()) > Duration::ZERO);

        // Beta reconnects, drains the channel, and finds the page
        // alive: it rejoins at the current key frame under the same
        // identity, and adopts the channel's earlier-of-all deadline.
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

        // The page's total life is its TTL plus the held hour, which
        // is what the pause gesture already means on one device: both
        // stores now expire it on the shared, hold-extended reading.
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

    /// The one tab in `store` holding no page — where the entombed
    /// page used to stand.
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

        // Alpha holds; the register replicates; beta freezes exactly
        // as alpha did.
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

        // A release elsewhere releases here, resuming from the frozen
        // remaining life.
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

        // A register claiming more frozen life than this device
        // believes in is capped at the local belief: a hold suspends a
        // countdown, it never refills one. The hold span itself is
        // bounded by the gesture's own ceiling.
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

        // A candidate later than the local deadline is ignored…
        let later = ExpiryPolicy {
            anchor_wall_ms: WALL,
            ttl_ms: millis(Ttl::default().duration()) + 1_000_000,
        };
        assert!(!alpha.observe_peer_expiry(uuid, later));

        // …an earlier one shortens…
        let earlier = ExpiryPolicy {
            anchor_wall_ms: WALL,
            ttl_ms: millis(HOUR),
        };
        assert!(alpha.observe_peer_expiry(uuid, earlier));
        assert_eq!(alpha.sheet(a).unwrap().remaining(alpha.now()), HOUR);

        // …and a held page ignores every candidate: the hold is the
        // user's instruction, not a clock.
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

    // ------------------------------------------------------------------
    // The coordinated ceremony at the store (issue #101)
    // ------------------------------------------------------------------

    #[test]
    fn a_solo_page_compacts_at_the_transition_exactly_as_before() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
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
        let id = alpha.new_tab().unwrap().1;
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

        // The transition applies — the rung moves — but the boundary
        // becomes a proposal: the history stands, and the due mark
        // tells the session layer to propose.
        let before = alpha.sheet(id).unwrap().document.peer_id();
        alpha.cycle_rung(slot(&alpha, id)).unwrap();
        assert_eq!(alpha.sheet(id).unwrap().document.peer_id(), before);
        assert!(alpha.ceremony_due(id));
        assert!(contains(
            &alpha.sheet(id).unwrap().document.export_snapshot(),
            b"DOOMED"
        ));

        // Solo pages have no door here: the ceremony seam refuses one.
        let solo = alpha.new_tab().unwrap().1;
        assert!(alpha.perform_ceremony(solo).is_none());

        // Confirmation performs both halves' store half: the rebuild
        // sheds the trail and the fresh key frame comes back for the
        // channel, adoptable by a joiner.
        let frame = alpha.perform_ceremony(id).unwrap();
        assert!(!alpha.ceremony_due(id));
        assert_ne!(alpha.sheet(id).unwrap().document.peer_id(), before);
        assert!(!contains(&frame, b"DOOMED"));
        let j = joiner.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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

        // The last peer detached: a solo device answers to nobody, and
        // the due boundary runs rather than being forgotten.
        assert!(store.set_compaction_deferred(id, false));
        assert!(!store.ceremony_due(id));
        assert_ne!(store.sheet(id).unwrap().document.peer_id(), before);
    }

    // ------------------------------------------------------------------
    // Undo at the store (issue #132)
    // ------------------------------------------------------------------

    /// The page's body as one string, chips counted as their sentinel.
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
        let id = store.new_tab().unwrap().1;
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
        // The caret comes back with the text: the edit began at the
        // start of an empty page, and that is where the writer is left.
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
        let id = store.new_tab().unwrap().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "secret words".into(),
            }],
        ));
        // The whole line goes into a chip. Sealing is the one gesture
        // that cannot be taken back (ADR-0009), so the stack the typing
        // built goes with it rather than leaving a step that would pull
        // the sentinel out from under sealed bytes.
        store.seal_text_at(id, "secret words", 0, 12).unwrap();
        assert_eq!(body(&store, id), "\u{FFFC}");
        assert!(!store.can_undo(id));
        assert!(!store.undo(id));
    }

    #[test]
    fn burning_a_chip_takes_the_stack_with_it() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
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
        // Undo never resurrects: the bytes are zeroized, so no step may
        // stand their sentinel again.
        assert!(!store.can_undo(id));
        assert!(!store.can_redo(id));
    }

    #[test]
    fn an_edit_the_page_made_itself_comes_off_in_one_press() {
        let (mut bounded, _) = store();
        let (mut merged, _) = store();
        let id = bounded.new_tab().unwrap().1;
        let other = merged.new_tab().unwrap().1;
        let store = &mut bounded;
        // The writer's own words, then the marker the page continued
        // for them a keystroke later, well inside the merge interval.
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

        // One press takes back the marker and nothing the writer typed.
        assert!(store.undo(id));
        assert_eq!(body(store, id), "- milk");
        assert!(store.can_undo(id), "the writer's own words went with it");

        // The contrast is the whole evidence that the boundary is real:
        // the same two batches without one take back both together.
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
    fn standing_a_sentinel_through_the_op_path_takes_the_stack_with_it() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        // A chip minted but not yet placed, then stood in the body by
        // the operation path. That is the shape a drag arrives in: the
        // editor emits a chip op for any storage edit whose range holds
        // an attachment, so moving a selection that contains a chip
        // re-inserts it rather than seals it.
        let chip = store.seal_text(id, "sealed").unwrap();
        assert!(store.apply_ops(id, &[EditOp::InsertChip { pos_u16: 0, chip }],));
        assert_eq!(body(&store, id), "\u{FFFC}");
        assert_eq!(store.sheet(id).unwrap().chips().count(), 1);

        // Without the stack going here, one step back pulls the
        // sentinel out, the settle reads the chip as deleted, and the
        // bytes are zeroized with a Discarded record: a single ⌘Z
        // destroys a sealed chip and no redo can bring it back. Every
        // other path that moves the roster forgets the stack; this one
        // must too.
        assert!(!store.can_undo(id));
        assert!(!store.undo(id));
        assert_eq!(body(&store, id), "\u{FFFC}");
        assert_eq!(store.sheet(id).unwrap().chips().count(), 1);
    }

    #[test]
    fn a_deleted_chip_leaves_no_step_that_would_stand_it_again() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        store.seal_text_at(id, "sealed", 0, 0).unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 1,
                text: "ink".into(),
            }],
        ));
        // A backspace over the sentinel, which is how a chip dies in the
        // editor. The settle reaps the chip, and the stack dies there.
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
        let id = store.new_tab().unwrap().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "typed".into(),
            }],
        ));
        assert!(store.sync_document(id, vec![Segment::Ink("restated".into())]));
        assert_eq!(body(&store, id), "restated");
        // Every step behind the restate describes offsets into a body
        // that is gone, and the restate itself would undo the recovery.
        assert!(!store.can_undo(id));
        assert!(!store.can_redo(id));
    }

    #[test]
    fn the_ceremony_leaves_the_page_with_nothing_to_step_back_through() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "before the boundary".into(),
            }],
        ));
        assert!(store.can_undo(id));

        // A rung transition on a solo page compacts inline: the peer id
        // is re-minted and the operations every step pointed into are
        // destroyed, so the stack must be empty on the far side.
        store.cycle_rung(slot(&store, id)).unwrap();
        assert!(!store.can_undo(id));
        assert!(!store.undo(id));
        assert_eq!(body(&store, id), "before the boundary");
    }

    /// The one place a remote event destroys local state, written down
    /// as a test so it is a decision rather than a surprise. Chip
    /// liveness follows the document, and the document is shared: a
    /// neighbouring device backspacing over a sentinel zeroizes the
    /// bytes here, and the steps standing on this device would then be
    /// steps that could stand the sentinel again over nothing. The
    /// stack goes rather than the guarantee (ADR-0009). What the writer
    /// loses is ⌘Z reaching back past the moment the chip died; what
    /// they keep is the page.
    #[test]
    fn a_peers_chip_deletion_forgets_this_devices_steps() {
        let (mut store, _) = store();
        let id = store.new_tab().unwrap().1;
        store.seal_text_at(id, "sealed", 0, 0).unwrap();
        let chip = store.sheet(id).unwrap().chips().next().unwrap().uuid;

        // The peer holds the same page, and is told it owns the chip so
        // the sentinel is not read as damage on the way in.
        let mirror = SheetDocument::new();
        let shared = store
            .export_document_updates(id, &mirror.version())
            .unwrap();
        mirror.import_update(&shared, &[chip]).unwrap();

        // This device types after the seal. That is the step at stake.
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 1,
                text: "ink".into(),
            }],
        ));
        assert!(store.can_undo(id));

        // The peer backspaces over the sentinel and the delete arrives
        // here as an ordinary update.
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
        let a = alpha.new_tab().unwrap().1;
        let b = beta.new_tab().unwrap().1;

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

        // One step back on this device takes this device's sentence.
        // The peer's is not a candidate: the stack is bound to the local
        // peer, and a joiner never holds the operations an away-device
        // undo would have to invert (ADR-0021 section 5).
        assert!(alpha.undo(a));
        assert_eq!(body(&alpha, a), "theirs.");
        assert!(!alpha.can_undo(a));
    }
}
