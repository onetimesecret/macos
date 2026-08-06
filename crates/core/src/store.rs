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

use crate::clock::Clock;
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
        self.sheets.push(Sheet {
            id,
            uuid,
            title: title.clone(),
            title_is_user_set: false,
            created_wall_ms,
            segments: Vec::new(),
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

    // -----------------------------------------------------------------
    // The synced document
    // -----------------------------------------------------------------

    /// Replace a page's document snapshot. The shell owns the live
    /// document; this mirror exists for the ledger, the tab title, and
    /// page promotion.
    ///
    /// The snapshot is **authoritative for chip liveness**: a chip of
    /// this sheet that the snapshot no longer references was deleted in
    /// the editor (⌫ removes it whole), and its bytes are zeroized here
    /// — undo never un-seals (open question №5). A snapshot referencing
    /// a chip this sheet does not own, or the same chip twice, is
    /// malformed and rejected whole. Returns whether the snapshot was
    /// accepted.
    pub fn sync_document(&mut self, id: SheetId, segments: Vec<Segment>) -> bool {
        // Read the clock before the mutable borrow of the sheet.
        let offset = self.clock.local_offset_seconds();
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
        sheet.segments = segments;
        // The title is re-derived here, on edit, and never later: by
        // the time a record reaches the ledger the page already knows
        // its name (ADR-0012).
        if !sheet.title_is_user_set {
            sheet.title = derive_title(&sheet.segments, sheet.created_wall_ms, offset);
        }
        // Chips the document no longer holds die now (zeroize on drop).
        // A chip removed with ⌫ is as gone as one removed by
        // `delete_chip`, so it leaves the same record.
        let mut dropped: Vec<(ItemId, usize)> = Vec::new();
        sheet.chips.retain(|chip| {
            let referenced = referenced.contains(&chip.id);
            if !referenced {
                dropped.push((chip.uuid, chip.bytes.len()));
            }
            referenced
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
        true
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
            removed = Some((
                chip.uuid,
                chip.bytes.len(),
                sheet.title.clone(),
                sheet.created_wall_ms,
            ));
            sheet.chips.remove(index); // zeroizes as it drops
            sheet.segments.retain(|s| *s != Segment::Chip(id));
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

    /// Every contiguous run of `TOKEN`, four characters or longer.
    /// Testing whole-token absence would be trivially satisfiable by a
    /// truncating excerpt; this is the assertion that is hard to weaken.
    fn token_fragments() -> Vec<String> {
        let chars: Vec<char> = TOKEN.chars().collect();
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
    /// may carry a fragment of what was sealed.
    fn assert_content_free(store: &SheetStore<ManualClock>) {
        let fragments = token_fragments();
        let mut checked = 0usize;
        for record in store.ledger() {
            let rendered = format!("{record:?}");
            for fragment in &fragments {
                assert!(
                    !rendered.contains(fragment.as_str()),
                    "ledger record leaked {fragment:?} of the sealed token: {rendered}"
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
}
