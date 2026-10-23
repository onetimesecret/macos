//! Explicit persistence: the store's content and its ledger as two
//! independent plaintext snapshots, for the seam above to seal
//! (ADR-0012, ADR-0016). Both are handed out only in [`Zeroizing`].
//!
//! Every repeated record is length-prefixed, so a field a later build
//! appends is skipped; any other change takes a new magic (issue #54).

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::blocks::{BlockIndex, MaterializedMeta, PersistedBlock};
use crate::clock::Clock;
use crate::document::{DocRun, SheetDocument};
use crate::ledger::{DestinationClass, LedgerEvent, LedgerRecord, SizeClass, evict_expired};
use crate::note::Note;
use crate::sheet::{
    Availability, CeremonyState, ChipId, ChipMeta, Conceal, ItemId, PeerKind, SealedChip, Segment,
    Sheet, SheetClock, SheetId, Tab, TabId, capped_title, derive_title, judge_name,
};
use crate::store::{HOLD_FIRST, HOLD_TOPUP, SheetStore};
use crate::transfer::ActiveCut;
use crate::ttl::Ttl;

/// Magic and version of a plaintext content snapshot. Every earlier version
/// but [`MAGIC_V4`] refuses as unknown; there is no downgrade writer.
// Unshipped: later #257 units extend its chip record (ADR-0058 point 9).
const MAGIC: &[u8; 8] = b"OTSSNAP5";

/// The previous version, still read: every chip record in it has its value.
const MAGIC_V4: &[u8; 8] = b"OTSSNAP4";

/// Magic and version of a plaintext ledger snapshot.
const LEDGER_MAGIC: &[u8; 8] = b"OTSLEDR2";

/// Ledger magics this module once wrote, refused as
/// [`RestoreError::Superseded`] so the caller can dispose of the file
/// (persistence decision background section 9).
const SUPERSEDED_LEDGER_MAGICS: [&[u8; 8]; 1] = [b"OTSLEDR1"];

/// Ceiling on any span read back, keeping `Instant` arithmetic from
/// overflow.
const MAX_SPAN_MS: u64 = 30 * 24 * 60 * 60 * 1000;

/// Slack for a stamp ahead of the wall clock: the recorder rounds to the
/// second while the wall reading truncates.
const STAMP_SLACK_S: i64 = 2;

/// The same slack in milliseconds, for the ledger's wall stamps.
const STAMP_SLACK_MS: u64 = 2_000;

/// 2026-10-01T00:00:00Z; below it the ledger's stamp clamp stands aside (Law 0006).
const WALL_CLOCK_FLOOR_MS: u64 = 1_790_812_800_000;

/// A persisted Unix-second stamp, clamped to `1..=wall + STAMP_SLACK_S`.
fn clamp_stamp(claimed: u64, wall_ms: u64) -> i64 {
    let ceiling = i64::try_from(wall_ms / 1000)
        .unwrap_or(i64::MAX)
        .saturating_add(STAMP_SLACK_S)
        .max(1);
    i64::try_from(claimed).unwrap_or(i64::MAX).clamp(1, ceiling)
}

/// Why a snapshot could not be restored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestoreError {
    /// Not a snapshot, or a version this build does not read.
    UnknownFormat,
    /// A version this build once wrote and has replaced; the caller may
    /// dispose of the file (persistence decision background section 9).
    /// The store is untouched.
    Superseded,
    /// The layout is damaged. The store is left exactly as it was.
    Malformed,
}

impl std::fmt::Display for RestoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RestoreError::UnknownFormat => f.write_str("not a snapshot this build can read"),
            RestoreError::Superseded => {
                f.write_str("a snapshot from a format this build has replaced")
            }
            RestoreError::Malformed => f.write_str("snapshot is damaged"),
        }
    }
}

impl std::error::Error for RestoreError {}

impl<C: Clock> SheetStore<C> {
    /// Serialize the strip (tabs, pages, chips, clocks) into one plaintext
    /// buffer stamped with `wall_ms`. The ledger has its own snapshot.
    #[must_use]
    pub fn snapshot(&self, wall_ms: u64) -> Zeroizing<Vec<u8>> {
        let now = self.clock.now();
        // Exported once, so both passes see the same bytes (Law 0004).
        let pages: Vec<PageExport> = self.sheets().map(PageExport::of).collect();
        let mut sizer = Sizer(0);
        emit(self, &pages, now, wall_ms, &mut sizer);
        let mut buffer = Zeroizing::new(Vec::with_capacity(sizer.0));
        emit(self, &pages, now, wall_ms, &mut Writer(&mut buffer));
        debug_assert_eq!(buffer.len(), sizer.0, "sizing pass drifted from the write");
        buffer
    }

    /// Replace the strip with a snapshot's, draining countdowns by the wall
    /// time since it was taken. Run before the store has issued any id:
    /// ids are re-minted from 1. Pages already due are kept; call
    /// [`SheetStore::expire_due`] next. Returns the live page count, not
    /// the tab count.
    ///
    /// # Errors
    ///
    /// [`RestoreError::UnknownFormat`] or [`RestoreError::Malformed`]; the
    /// store is untouched on error.
    pub fn restore(&mut self, bytes: &[u8], wall_ms: u64) -> Result<usize, RestoreError> {
        let mut reader = Reader { buf: bytes, pos: 0 };
        let layout = match reader.raw(MAGIC.len()) {
            Some(magic) if magic == MAGIC.as_slice() => ChipLayout::Tagged,
            Some(magic) if magic == MAGIC_V4.as_slice() => ChipLayout::Valued,
            _ => return Err(RestoreError::UnknownFormat),
        };
        let saved_wall = reader.u64().ok_or(RestoreError::Malformed)?;
        // A wall clock that moved backwards grants no life.
        let away = span(wall_ms.saturating_sub(saved_wall));
        let now = self.clock.now();

        let tab_count = count(&mut reader)?;
        // No width cap (issue #158); `count` bounds the walk by the file.
        let mut tabs = Vec::new();
        let mut next_tab_id = 1;
        let mut next_sheet_id = 1;
        let mut chips = ChipReading { layout, next_id: 1 };
        let mut active_cut = None;
        for _ in 0..tab_count {
            let mut record = reader.framed().ok_or(RestoreError::Malformed)?;
            let (tab, cut) = read_tab(
                &mut record,
                now,
                away,
                wall_ms,
                &mut next_tab_id,
                &mut next_sheet_id,
                &mut chips,
            )?;
            tabs.push(tab);
            // One cut stands at a time; a second record of one is not believed.
            active_cut = active_cut.or(cut);
        }
        if !reader.done() {
            return Err(RestoreError::Malformed);
        }

        let restored = tabs.iter().filter(|tab| tab.page.is_some()).count();
        self.tabs = tabs;
        self.next_tab_id = next_tab_id;
        self.next_sheet_id = next_sheet_id;
        self.next_chip_id = chips.next_id;
        self.active_cut = active_cut;
        Ok(restored)
    }

    /// Serialize the ledger into its own plaintext buffer, with wall-clock
    /// stamps. Evicts nothing: call [`SheetStore::evict_ledger`] first.
    #[must_use]
    pub fn ledger_snapshot(&self) -> Zeroizing<Vec<u8>> {
        let mut sizer = Sizer(0);
        emit_ledger(self, &mut sizer);
        let mut buffer = Zeroizing::new(Vec::with_capacity(sizer.0));
        emit_ledger(self, &mut Writer(&mut buffer));
        debug_assert_eq!(buffer.len(), sizer.0, "sizing pass drifted from the write");
        buffer
    }

    /// Merge a ledger snapshot's records into this store's, then evict
    /// what is past retention at `wall_ms`. Merged, not replaced: the
    /// content restore may already have recorded overnight expiries.
    /// Returns the number of records held afterwards.
    ///
    /// # Errors
    ///
    /// [`RestoreError::Superseded`] for a magic in
    /// [`SUPERSEDED_LEDGER_MAGICS`], [`RestoreError::UnknownFormat`] for any
    /// other, [`RestoreError::Malformed`] for damage. The store is
    /// untouched on error.
    pub fn restore_ledger(&mut self, bytes: &[u8], wall_ms: u64) -> Result<usize, RestoreError> {
        let mut reader = Reader { buf: bytes, pos: 0 };
        let magic = reader.raw(LEDGER_MAGIC.len());
        if magic != Some(LEDGER_MAGIC.as_slice()) {
            let superseded = magic.is_some_and(|magic| {
                SUPERSEDED_LEDGER_MAGICS
                    .iter()
                    .any(|old| magic == old.as_slice())
            });
            return Err(if superseded {
                RestoreError::Superseded
            } else {
                RestoreError::UnknownFormat
            });
        }
        let record_count = count(&mut reader)?;
        // Future stamps clamp to the clock, above the floor only (Law 0006).
        let ceiling = if wall_ms < WALL_CLOCK_FLOOR_MS {
            u64::MAX
        } else {
            wall_ms.saturating_add(STAMP_SLACK_MS)
        };
        let mut loaded = Vec::new();
        for _ in 0..record_count {
            let mut record = reader.framed().ok_or(RestoreError::Malformed)?;
            let mut record = read_record(&mut record)?;
            record.at_wall_ms = record.at_wall_ms.min(ceiling);
            record.item_created_wall_ms = record.item_created_wall_ms.min(ceiling);
            loaded.push(record);
        }
        if !reader.done() {
            return Err(RestoreError::Malformed);
        }
        // Newest first: the file's records come from earlier sessions, so
        // they go after the live ones, unsorted.
        let mut merged: Vec<LedgerRecord> = self.ledger.drain(..).collect();
        // A multiset union, never deduplicated against itself (Law 0006).
        let mut held: HashMap<(u64, ItemId), Vec<usize>> = HashMap::new();
        for (index, record) in merged.iter().enumerate() {
            held.entry((record.at_wall_ms, record.item))
                .or_default()
                .push(index);
        }
        for record in loaded {
            let spent = held
                .get_mut(&(record.at_wall_ms, record.item))
                .and_then(|positions| {
                    positions
                        .iter()
                        .position(|&index| merged[index] == record)
                        .map(|slot| positions.remove(slot))
                })
                .is_some();
            if spent {
                continue;
            }
            merged.push(record);
        }
        let mut ledger: VecDeque<LedgerRecord> = merged.into();
        evict_expired(&mut ledger, wall_ms);
        let kept = ledger.len();
        self.ledger = ledger;
        Ok(kept)
    }
}

// Encoding: one walk, run as a sizing pass and then the write.

pub(crate) trait Sink {
    fn raw(&mut self, bytes: &[u8]);
    fn u8(&mut self, value: u8);
    fn u64(&mut self, value: u64);
    /// Length-prefixed bytes.
    fn bytes(&mut self, value: &[u8]);
}

pub(crate) struct Sizer(pub(crate) usize);

impl Sink for Sizer {
    fn raw(&mut self, bytes: &[u8]) {
        self.0 += bytes.len();
    }
    fn u8(&mut self, _: u8) {
        self.0 += 1;
    }
    fn u64(&mut self, _: u64) {
        self.0 += 8;
    }
    fn bytes(&mut self, value: &[u8]) {
        self.0 += 8 + value.len();
    }
}

pub(crate) struct Writer<'a>(pub(crate) &'a mut Vec<u8>);

impl Sink for Writer<'_> {
    fn raw(&mut self, bytes: &[u8]) {
        self.0.extend_from_slice(bytes);
    }
    fn u8(&mut self, value: u8) {
        self.0.push(value);
    }
    fn u64(&mut self, value: u64) {
        self.0.extend_from_slice(&value.to_le_bytes());
    }
    fn bytes(&mut self, value: &[u8]) {
        self.u64(value.len() as u64);
        self.0.extend_from_slice(value);
    }
}

/// Write a record as its byte length, then its fields. The body runs
/// twice (sized, then written) and must be pure.
pub(crate) fn framed(out: &mut dyn Sink, body: impl Fn(&mut dyn Sink)) {
    let mut sizer = Sizer(0);
    body(&mut sizer);
    out.u64(sizer.0 as u64);
    body(out);
}

/// What a live page writes that a walk must not produce twice (Law 0004).
struct PageExport {
    /// The whole document, history included.
    blob: Zeroizing<Vec<u8>>,
    /// The block section (ADR-0013).
    meta: Zeroizing<Vec<u8>>,
    /// Each chip's note text, in chip order; an empty note writes none.
    notes: Vec<Option<Zeroizing<String>>>,
    /// The same for the detached chips (ADR-0046 point 1).
    detached_notes: Vec<Option<Zeroizing<String>>>,
}

impl PageExport {
    fn of(sheet: &Sheet) -> Self {
        Self {
            blob: sheet.document.export_snapshot(),
            meta: encode_materialized(&sheet.blocks, &sheet.document),
            notes: notes_of(&sheet.chips),
            detached_notes: notes_of(&sheet.detached),
        }
    }
}

/// Each chip's note text, taken once at its exact size (Law 0004).
fn notes_of(chips: &[SealedChip]) -> Vec<Option<Zeroizing<String>>> {
    chips
        .iter()
        .map(|chip| {
            chip.note
                .as_ref()
                .map(Note::text)
                .filter(|text| !text.is_empty())
        })
        .collect()
}

fn emit<C: Clock>(
    store: &SheetStore<C>,
    pages: &[PageExport],
    now: Instant,
    wall_ms: u64,
    out: &mut dyn Sink,
) {
    out.raw(MAGIC);
    out.u64(wall_ms);
    out.u64(store.tabs.len() as u64);
    // Consumed out here because the framed body runs twice.
    let mut pages = pages.iter();
    for tab in &store.tabs {
        let page = tab.page.as_ref().map(|sheet| {
            let export = pages.next().expect("one export per live page");
            // The active cut rides with the page it came from (core interface, At rest).
            let cut = store
                .active_cut
                .as_ref()
                .filter(|cut| cut.page == sheet.id)
                .map(|cut| cut.envelope.as_slice());
            (sheet, export, cut)
        });
        framed(&mut *out, |out| emit_tab(tab, page, now, out));
    }
}

/// A live page, what it writes once, and the active cut's envelope if the
/// cut came from it.
type PageWrite<'a> = (&'a Sheet, &'a PageExport, Option<&'a [u8]>);

/// One tab record: identity, birthday, name, rung, then the framed page.
fn emit_tab(tab: &Tab, page: Option<PageWrite<'_>>, now: Instant, out: &mut dyn Sink) {
    // Identity, not the in-process counter (ADR-0012).
    out.raw(tab.uuid.as_bytes());
    out.u64(tab.created_wall_ms);
    match &tab.name {
        None => out.u8(0),
        Some(name) => {
            out.u8(1);
            out.bytes(name.as_bytes());
        }
    }
    out.u64(tab.rung.duration().as_secs());
    match page {
        None => out.u8(0),
        Some(page) => {
            out.u8(1);
            framed(&mut *out, |out| emit_sheet(page, now, out));
        }
    }
}

/// One page record. No title: it is derived and recomputed at restore
/// (ADR-0017).
fn emit_sheet((sheet, export, cut): PageWrite<'_>, now: Instant, out: &mut dyn Sink) {
    // Identity, not the in-process counter (ADR-0012).
    out.raw(sheet.uuid.as_bytes());
    out.u64(sheet.created_wall_ms);
    match sheet.clock {
        // Tag 2 is a topped-up hold; the tier decides the next pause press.
        SheetClock::Held {
            until,
            frozen_remaining,
            topped_up,
            ..
        } if now < until => {
            out.u8(if topped_up { 2 } else { 1 });
            out.u64(ms(until.saturating_duration_since(now)));
            out.u64(ms(frozen_remaining));
        }
        // A lapsed hold is written as a countdown: its drained life is spent.
        _ => {
            out.u8(0);
            out.u64(ms(sheet.remaining(now)));
        }
    }
    // total_held(now) folds a live hold's span in; restore restarts the
    // live hold's accounting from its own `now`.
    out.u64(ms(sheet.total_held(now)));
    // Chips first, so every identity is known before a mark resolves one.
    out.u64(sheet.chips.len() as u64);
    for (chip, note) in sheet.chips.iter().zip(&export.notes) {
        let note = note.as_ref().map(|text| text.as_str());
        framed(&mut *out, |out| emit_chip(chip, note, out));
    }
    // The whole document, history included; the projection derives from it.
    out.bytes(&export.blob);
    // Materialized metadata from the compaction ceremony (ADR-0013).
    out.bytes(&export.meta);
    // Trailing page-level floor: a deletion's stamp, which no block can
    // carry.
    match sheet.blocks.compaction_frontier() {
        None => out.u8(0),
        Some(frontier_s) => {
            out.u8(1);
            out.u64(frontier_s.max(0) as u64);
        }
    }
    // Trailing: the chips the body no longer shows, framed as attached ones are.
    out.u64(sheet.detached.len() as u64);
    for (chip, note) in sheet.detached.iter().zip(&export.detached_notes) {
        let note = note.as_ref().map(|text| text.as_str());
        framed(&mut *out, |out| emit_chip(chip, note, out));
    }
    // Then the active cut's envelope, on the page it came from.
    match cut {
        None => out.u8(0),
        Some(envelope) => {
            out.u8(1);
            out.bytes(envelope);
        }
    }
}

/// One chip record: its availability, then a value's kind, receipt and
/// bytes or a peer record's kind and size class. The face is recomputed on
/// the way back in.
fn emit_chip(chip: &SealedChip, note: Option<&str>, out: &mut dyn Sink) {
    out.raw(chip.uuid.as_bytes());
    match &chip.availability {
        Availability::Local(local) => {
            out.u8(0);
            out.u8(match local.meta {
                ChipMeta::Text { .. } => 0,
                ChipMeta::Image { .. } => 1,
            });
            match &local.conceal {
                None => out.u8(0),
                Some(conceal) => {
                    out.u8(1);
                    out.bytes(conceal.receipt_id.as_bytes());
                }
            }
            out.bytes(local.bytes.expose());
        }
        Availability::Peer { kind, size } => {
            out.u8(1);
            out.u8(match kind {
                None => 0,
                Some(PeerKind::Text) => 1,
                Some(PeerKind::Image) => 2,
            });
            out.u8(match size {
                None => 0,
                Some(SizeClass::Tiny) => 1,
                Some(SizeClass::Small) => 2,
                Some(SizeClass::Medium) => 3,
                Some(SizeClass::Large) => 4,
                Some(SizeClass::Huge) => 5,
            });
        }
    }
    // Trailing, so a build that predates them skips both (ADR-0043 point 4).
    match &chip.name {
        None => out.u8(0),
        Some(name) => {
            out.u8(1);
            out.bytes(name.as_bytes());
        }
    }
    match note {
        None => out.u8(0),
        Some(text) => {
            out.u8(1);
            out.bytes(text.as_bytes());
        }
    }
}

/// Encode a sheet's block section (frozen summaries, then grouping) into
/// an exact-size buffer. Nothing frozen or grouped encodes to empty.
fn encode_materialized(blocks: &BlockIndex, doc: &SheetDocument) -> Zeroizing<Vec<u8>> {
    let spans = blocks.spans(doc);
    let grouped = spans.iter().any(|span| *span > 1);
    if !grouped
        && blocks
            .records()
            .iter()
            .all(|record| record.materialized.is_none())
    {
        return Zeroizing::new(Vec::new());
    }
    let mut sizer = Sizer(0);
    emit_materialized(blocks, &spans, grouped, &mut sizer);
    let mut buffer = Zeroizing::new(Vec::with_capacity(sizer.0));
    emit_materialized(blocks, &spans, grouped, &mut Writer(&mut buffer));
    debug_assert_eq!(
        buffer.len(),
        sizer.0,
        "materialized sizing pass drifted from the write"
    );
    buffer
}

fn emit_materialized(blocks: &BlockIndex, spans: &[usize], grouped: bool, out: &mut dyn Sink) {
    let frozen: Vec<_> = blocks
        .records()
        .iter()
        .filter_map(|record| record.materialized.as_ref().map(|meta| (record, meta)))
        .collect();
    out.u64(frozen.len() as u64);
    for (record, meta) in frozen {
        framed(&mut *out, |out| {
            // Identity, then the anchor that must still resolve on restore.
            out.raw(record.id.as_bytes());
            out.bytes(&record.anchor);
            // Positive by construction, so the cast loses nothing.
            out.u64(meta.created_s.max(0) as u64);
            out.u64(meta.modified_s.max(0) as u64);
            match &meta.origin {
                None => out.u8(0),
                Some(origin) => {
                    out.u8(1);
                    out.bytes(origin.as_bytes());
                }
            }
        });
    }
    // Written only when grouped; absent means one block per paragraph.
    if grouped {
        out.u64(spans.len() as u64);
        for span in spans {
            out.u64(*span as u64);
        }
    }
}

fn emit_ledger<C: Clock>(store: &SheetStore<C>, out: &mut dyn Sink) {
    out.raw(LEDGER_MAGIC);
    out.u64(store.ledger.len() as u64);
    for record in &store.ledger {
        framed(&mut *out, |out| {
            out.u8(match record.event {
                LedgerEvent::Created => 0,
                LedgerEvent::Sealed => 1,
                LedgerEvent::Sent => 2,
                LedgerEvent::Expired => 3,
                LedgerEvent::Discarded => 4,
            });
            out.raw(record.item.as_bytes());
            out.bytes(record.title.as_bytes());
            out.u64(record.at_wall_ms);
            out.u64(record.item_created_wall_ms);
            out.u8(match record.size {
                SizeClass::Tiny => 0,
                SizeClass::Small => 1,
                SizeClass::Medium => 2,
                SizeClass::Large => 3,
                SizeClass::Huge => 4,
            });
            out.u8(match record.destination {
                DestinationClass::None => 0,
                DestinationClass::Clipboard => 1,
                DestinationClass::OneTimeLink => 2,
                DestinationClass::Drag => 3,
            });
        });
    }
}

fn ms(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

// Decoding: bounds-checked; damage rejects the whole snapshot before the
// store is touched.

pub(crate) struct Reader<'a> {
    pub(crate) buf: &'a [u8],
    pub(crate) pos: usize,
}

impl<'a> Reader<'a> {
    pub(crate) fn raw(&mut self, len: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(len)?;
        if end > self.buf.len() {
            return None;
        }
        let slice = &self.buf[self.pos..end];
        self.pos = end;
        Some(slice)
    }

    pub(crate) fn u8(&mut self) -> Option<u8> {
        self.raw(1).map(|s| s[0])
    }

    pub(crate) fn u64(&mut self) -> Option<u64> {
        self.raw(8)
            .map(|s| u64::from_le_bytes(s.try_into().expect("raw(8) is 8 bytes")))
    }

    pub(crate) fn bytes(&mut self) -> Option<&'a [u8]> {
        let len = usize::try_from(self.u64()?).ok()?;
        self.raw(len)
    }

    pub(crate) fn str(&mut self) -> Option<&'a str> {
        std::str::from_utf8(self.bytes()?).ok()
    }

    fn uuid(&mut self) -> Option<ItemId> {
        let raw: [u8; 16] = self.raw(16)?.try_into().ok()?;
        Some(ItemId::from_bytes(raw))
    }

    /// A reader bounded to the next length-prefixed record. Its unread
    /// tail is fields this build does not know, not damage.
    pub(crate) fn framed(&mut self) -> Option<Reader<'a>> {
        Some(Reader {
            buf: self.bytes()?,
            pos: 0,
        })
    }

    pub(crate) fn done(&self) -> bool {
        self.pos == self.buf.len()
    }
}

/// A count field. Each element is at least one byte, so a count beyond the
/// remainder is refused before allocating.
pub(crate) fn count(reader: &mut Reader<'_>) -> Result<usize, RestoreError> {
    let value = usize::try_from(reader.u64().ok_or(RestoreError::Malformed)?)
        .map_err(|_| RestoreError::Malformed)?;
    if value > reader.buf.len() - reader.pos {
        return Err(RestoreError::Malformed);
    }
    Ok(value)
}

/// A span read back from the snapshot, clamped to [`MAX_SPAN_MS`].
fn span(claimed_ms: u64) -> Duration {
    Duration::from_millis(claimed_ms.min(MAX_SPAN_MS))
}

/// One tab record, from its own framed sub-reader.
fn read_tab(
    reader: &mut Reader<'_>,
    now: Instant,
    away: Duration,
    wall_ms: u64,
    next_tab_id: &mut u64,
    next_sheet_id: &mut u64,
    reading: &mut ChipReading,
) -> Result<(Tab, Option<ActiveCut>), RestoreError> {
    use RestoreError::Malformed;
    let uuid = reader.uuid().ok_or(Malformed)?;
    let created_wall_ms = reader.u64().ok_or(Malformed)?;
    let name = match reader.u8().ok_or(Malformed)? {
        0 => None,
        // Re-capped: the name is durable and reaches the ledger.
        1 => Some(capped_title(reader.str().ok_or(Malformed)?)),
        _ => return Err(Malformed),
    };
    let rung = Ttl::from_secs(reader.u64().ok_or(Malformed)?).ok_or(Malformed)?;
    let (page, cut) = match reader.u8().ok_or(Malformed)? {
        0 => (None, None),
        1 => {
            let mut body = reader.framed().ok_or(Malformed)?;
            // A page flag over an empty frame is damage.
            if body.buf.is_empty() {
                return Err(Malformed);
            }
            let (page, cut) = read_page(
                &mut body,
                now,
                away,
                wall_ms,
                rung.longest_life(),
                next_sheet_id,
                reading,
            )?;
            (Some(page), cut)
        }
        _ => return Err(Malformed),
    };

    let id = TabId::from_raw(*next_tab_id);
    *next_tab_id += 1;

    let tab = Tab {
        id,
        uuid,
        created_wall_ms,
        name,
        rung,
        page,
    };
    Ok((tab, cut))
}

/// One page record. `ceiling` ([`Ttl::longest_life`]) bounds every life
/// span it records, whatever the bytes say (persistence decision
/// background sections 8, 10).
fn read_page(
    reader: &mut Reader<'_>,
    now: Instant,
    away: Duration,
    wall_ms: u64,
    ceiling: Duration,
    next_sheet_id: &mut u64,
    reading: &mut ChipReading,
) -> Result<(Sheet, Option<ActiveCut>), RestoreError> {
    use RestoreError::Malformed;
    let uuid = reader.uuid().ok_or(Malformed)?;
    let created_wall_ms = reader.u64().ok_or(Malformed)?;
    // Time away drains a hold first, then the countdown. A hold is bounded
    // by the pause gesture's ceiling, not the rung.
    let (clock, held_while_away) = match reader.u8().ok_or(Malformed)? {
        0 => {
            let remaining = span(reader.u64().ok_or(Malformed)?).min(ceiling);
            let deadline = now + remaining.saturating_sub(away);
            (SheetClock::Running { deadline }, Duration::ZERO)
        }
        tag @ (1 | 2) => {
            let hold_ceiling = if tag == 2 { HOLD_TOPUP } else { HOLD_FIRST };
            let hold = span(reader.u64().ok_or(Malformed)?).min(hold_ceiling);
            let frozen = span(reader.u64().ok_or(Malformed)?).min(ceiling);
            if away < hold {
                (
                    SheetClock::Held {
                        until: now + (hold - away),
                        frozen_remaining: frozen,
                        started: now,
                        topped_up: tag == 2,
                    },
                    away,
                )
            } else {
                (
                    SheetClock::Running {
                        deadline: now + frozen.saturating_sub(away - hold),
                    },
                    hold,
                )
            }
        }
        _ => return Err(Malformed),
    };
    let total_held = span(reader.u64().ok_or(Malformed)?) + held_while_away;

    let chips = read_chips(reader, reading)?;

    // The materialized slot is believed only against the imported document.
    let blob = reader.bytes().ok_or(Malformed)?;
    let metadata = reader.bytes().ok_or(Malformed)?;
    // Trailing field; a file written before it ends here.
    let frontier_s = if reader.done() {
        None
    } else {
        match reader.u8().ok_or(Malformed)? {
            0 => None,
            1 => Some(clamp_stamp(reader.u64().ok_or(Malformed)?, wall_ms)),
            // An unknown tag is damage, not a newer dialect.
            _ => return Err(Malformed),
        }
    };
    // And the detached chips (ADR-0046 point 1), which a file written
    // before them lacks.
    let detached = if reader.done() {
        Vec::new()
    } else {
        read_chips(reader, reading)?
    };
    let mut identities: Vec<ItemId> = chips.iter().chain(&detached).map(|c| c.uuid).collect();
    identities.sort_unstable();
    identities.dedup();
    if identities.len() != chips.len() + detached.len() {
        return Err(Malformed);
    }
    // And the active cut's envelope, on the page it came from.
    let cut = if reader.done() {
        None
    } else {
        match reader.u8().ok_or(Malformed)? {
            0 => None,
            1 => Some(reader.bytes().ok_or(Malformed)?),
            _ => return Err(Malformed),
        }
    };

    let document = SheetDocument::new();
    document.import_snapshot(blob)?;

    // Each chip mark resolves to exactly one record and every record is
    // claimed; anything else is damage.
    let mut segments = Vec::new();
    let mut referenced: Vec<ChipId> = Vec::new();
    for run in document.runs() {
        match run {
            DocRun::Ink(mut text) => {
                segments.push(Segment::Ink(std::mem::take(&mut *text)));
            }
            DocRun::Chip(wanted) => {
                let chip = chips.iter().find(|c| c.uuid() == wanted).ok_or(Malformed)?;
                if referenced.contains(&chip.id) {
                    return Err(Malformed);
                }
                referenced.push(chip.id);
                segments.push(Segment::Chip(chip.id));
            }
        }
    }
    if referenced.len() != chips.len() {
        return Err(Malformed);
    }

    // Fresh block identities; the recorded grouping and summaries are
    // validated against the document and dropped on failure (ADR-0013).
    let (frozen, spans) = read_materialized(metadata, wall_ms)?;
    let mut blocks = BlockIndex::for_document(&document);
    blocks.regroup(&document, &spans);
    blocks.adopt(&document, frozen);
    blocks.note_compaction(frontier_s);

    let id = SheetId::from_raw(*next_sheet_id);
    *next_sheet_id += 1;

    let derived_title = derive_title(&segments);

    let sheet = Sheet {
        id,
        uuid,
        derived_title,
        created_wall_ms,
        document,
        segments,
        blocks,
        chips,
        detached,
        clock,
        total_held,
        // Not persisted: no sync session survives a restart (issue #101).
        ceremony: CeremonyState::Immediate,
    };
    // A cut whose objects are not all detached here restores as no cut.
    let cut = cut.and_then(|envelope| ActiveCut::restored(&sheet, envelope));
    Ok((sheet, cut))
}

/// How a snapshot's chip records are laid out, by its magic.
#[derive(Clone, Copy)]
enum ChipLayout {
    /// [`MAGIC_V4`]: kind, receipt and bytes, always.
    Valued,
    /// [`MAGIC`]: an availability tag ahead of any payload bytes.
    Tagged,
}

/// What one snapshot's chip records are read by: their layout and the next
/// id to mint.
struct ChipReading {
    layout: ChipLayout,
    next_id: u64,
}

/// What a chip record says of its value, ahead of its name and note.
enum Written<'a> {
    Value {
        kind: u8,
        conceal: Option<Conceal>,
        bytes: &'a [u8],
    },
    Peer {
        kind: Option<PeerKind>,
        size: Option<SizeClass>,
    },
}

/// A count, then that many framed chip records; ids are minted in order.
fn read_chips(
    reader: &mut Reader<'_>,
    reading: &mut ChipReading,
) -> Result<Vec<SealedChip>, RestoreError> {
    let chip_count = count(reader)?;
    let mut chips = Vec::new();
    for _ in 0..chip_count {
        let mut record = reader.framed().ok_or(RestoreError::Malformed)?;
        chips.push(read_chip(&mut record, reading)?);
    }
    Ok(chips)
}

/// A value's kind, receipt and bytes.
fn read_value<'a>(record: &mut Reader<'a>) -> Result<Written<'a>, RestoreError> {
    use RestoreError::Malformed;
    let kind = record.u8().ok_or(Malformed)?;
    let conceal = match record.u8().ok_or(Malformed)? {
        0 => None,
        1 => Some(Conceal {
            receipt_id: record.str().ok_or(Malformed)?.to_string(),
        }),
        _ => return Err(Malformed),
    };
    let bytes = record.bytes().ok_or(Malformed)?;
    Ok(Written::Value {
        kind,
        conceal,
        bytes,
    })
}

/// A peer record's kind and size class, either of them unknown.
fn read_peer<'a>(record: &mut Reader<'a>) -> Result<Written<'a>, RestoreError> {
    use RestoreError::Malformed;
    let kind = match record.u8().ok_or(Malformed)? {
        0 => None,
        1 => Some(PeerKind::Text),
        2 => Some(PeerKind::Image),
        _ => return Err(Malformed),
    };
    let size = match record.u8().ok_or(Malformed)? {
        0 => None,
        1 => Some(SizeClass::Tiny),
        2 => Some(SizeClass::Small),
        3 => Some(SizeClass::Medium),
        4 => Some(SizeClass::Large),
        5 => Some(SizeClass::Huge),
        _ => return Err(Malformed),
    };
    Ok(Written::Peer { kind, size })
}

/// One chip record. The face is rebuilt by the sealing constructors, never
/// trusted; a record with no value comes back by [`SealedChip::peer`].
fn read_chip(
    record: &mut Reader<'_>,
    reading: &mut ChipReading,
) -> Result<SealedChip, RestoreError> {
    use RestoreError::Malformed;
    let chip_uuid = record.uuid().ok_or(Malformed)?;
    let written = match reading.layout {
        ChipLayout::Valued => read_value(record)?,
        ChipLayout::Tagged => match record.u8().ok_or(Malformed)? {
            0 => read_value(record)?,
            1 => read_peer(record)?,
            _ => return Err(Malformed),
        },
    };
    // A record written before the name ends here (ADR-0043 point 4).
    let name = if record.done() {
        None
    } else {
        match record.u8().ok_or(Malformed)? {
            0 => None,
            // A name this build's rule refuses is dropped, not damage.
            1 => judge_name(record.str().ok_or(Malformed)?)
                .ok()
                .flatten()
                .map(|name| Zeroizing::new(name.to_owned())),
            _ => return Err(Malformed),
        }
    };
    // And one written before the note ends here; its undo starts empty.
    let note = if record.done() {
        None
    } else {
        match record.u8().ok_or(Malformed)? {
            0 => None,
            1 => Some(Note::holding(record.str().ok_or(Malformed)?)),
            _ => return Err(Malformed),
        }
    };
    let chip_id = ChipId::from_raw(reading.next_id);
    reading.next_id += 1;
    let mut chip = match written {
        Written::Value {
            kind,
            conceal,
            bytes,
        } => {
            let mut chip = match kind {
                0 => SealedChip::text_with_uuid(
                    chip_id,
                    chip_uuid,
                    std::str::from_utf8(bytes).map_err(|_| Malformed)?,
                ),
                1 => SealedChip::image_with_uuid(chip_id, chip_uuid, bytes.to_vec()),
                _ => return Err(Malformed),
            };
            if let Some(local) = chip.local_mut() {
                local.conceal = conceal;
            }
            chip
        }
        Written::Peer { kind, size } => {
            let mut chip = SealedChip::peer(chip_id, chip_uuid);
            chip.availability = Availability::Peer { kind, size };
            chip
        }
    };
    chip.name = name;
    chip.note = note;
    // A written chip stood when it was written; its seal is long past.
    chip.stood = true;
    Ok(chip)
}

/// Decode a sheet's block slot into candidates for [`BlockIndex::adopt`]
/// and a grouping for [`BlockIndex::regroup`]. Stamps are clamped; the
/// grouping is optional.
fn read_materialized(
    bytes: &[u8],
    wall_ms: u64,
) -> Result<(Vec<PersistedBlock>, Vec<usize>), RestoreError> {
    use RestoreError::Malformed;
    if bytes.is_empty() {
        return Ok((Vec::new(), Vec::new()));
    }
    let clamp = |claimed: u64| clamp_stamp(claimed, wall_ms);
    let mut reader = Reader { buf: bytes, pos: 0 };
    let record_count = count(&mut reader)?;
    let mut records = Vec::new();
    for _ in 0..record_count {
        let mut record = reader.framed().ok_or(Malformed)?;
        let id = record.uuid().ok_or(Malformed)?;
        let anchor = record.bytes().ok_or(Malformed)?.to_vec();
        let created_s = clamp(record.u64().ok_or(Malformed)?);
        let modified_s = clamp(record.u64().ok_or(Malformed)?).max(created_s);
        let origin = match record.u8().ok_or(Malformed)? {
            0 => None,
            1 => Some(Zeroizing::new(record.str().ok_or(Malformed)?.to_owned())),
            _ => return Err(Malformed),
        };
        records.push(PersistedBlock {
            id,
            anchor,
            meta: MaterializedMeta {
                created_s,
                modified_s,
                origin,
            },
        });
    }
    // Grown per span, not reserved from the claimed count.
    let mut spans = Vec::new();
    if !reader.done() {
        let block_count = count(&mut reader)?;
        for _ in 0..block_count {
            spans.push(usize::try_from(reader.u64().ok_or(Malformed)?).map_err(|_| Malformed)?);
        }
    }
    if !reader.done() {
        return Err(Malformed);
    }
    Ok((records, spans))
}

fn read_record(reader: &mut Reader<'_>) -> Result<LedgerRecord, RestoreError> {
    use RestoreError::Malformed;
    let event = match reader.u8().ok_or(Malformed)? {
        0 => LedgerEvent::Created,
        1 => LedgerEvent::Sealed,
        2 => LedgerEvent::Sent,
        3 => LedgerEvent::Expired,
        4 => LedgerEvent::Discarded,
        _ => return Err(Malformed),
    };
    let item = reader.uuid().ok_or(Malformed)?;
    let title = capped_title(reader.str().ok_or(Malformed)?);
    let at_wall_ms = reader.u64().ok_or(Malformed)?;
    let item_created_wall_ms = reader.u64().ok_or(Malformed)?;
    let size = match reader.u8().ok_or(Malformed)? {
        0 => SizeClass::Tiny,
        1 => SizeClass::Small,
        2 => SizeClass::Medium,
        3 => SizeClass::Large,
        4 => SizeClass::Huge,
        _ => return Err(Malformed),
    };
    let destination = match reader.u8().ok_or(Malformed)? {
        0 => DestinationClass::None,
        1 => DestinationClass::Clipboard,
        2 => DestinationClass::OneTimeLink,
        3 => DestinationClass::Drag,
        _ => return Err(Malformed),
    };
    Ok(LedgerRecord {
        event,
        item,
        title,
        at_wall_ms,
        item_created_wall_ms,
        size,
        destination,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;
    use crate::sheet::TITLE_CAP;

    const HOUR: Duration = Duration::from_secs(60 * 60);

    fn store_on(clock: ManualClock) -> SheetStore<ManualClock> {
        SheetStore::new(clock)
            .with_grace_snap(false)
            .with_default_rung(Ttl::from_secs(8 * 60 * 60).unwrap())
    }

    fn store() -> (SheetStore<ManualClock>, ManualClock) {
        let clock = ManualClock::new();
        (store_on(clock.clone()), clock)
    }

    fn slot(store: &SheetStore<ManualClock>, page: SheetId) -> TabId {
        store
            .tabs()
            .find(|tab| tab.page().map(Sheet::id) == Some(page))
            .expect("the page is in a tab")
            .id()
    }

    fn populated() -> (SheetStore<ManualClock>, ManualClock, SheetId, SheetId) {
        let (mut store, clock) = store();
        let first = store.new_tab().1;
        let token = store.seal_text(first, "ghp_expected-to-survive").unwrap();
        let image = store
            .seal_image(first, vec![0x89, b'P', b'N', b'G', 0, 1, 2, 3])
            .unwrap();
        assert!(store.mark_chip_concealed(token, "receipt-42".into()));
        store.set_chip_name(token, "DEPLOY_TOKEN").unwrap();
        assert!(store.apply_note_ops(
            token,
            &[crate::store::EditOp::Insert {
                pos_u16: 0,
                text: "rotate after \u{1F511} the audit".into(),
            }],
            crate::document::EditIntent::Typing,
            None,
        ));
        let removed = store.seal_text(first, "removed but kept").unwrap();
        store.set_chip_name(removed, "KEPT").unwrap();
        assert!(store.apply_note_ops(
            removed,
            &[crate::store::EditOp::Insert {
                pos_u16: 0,
                text: "detached \u{1F511} note".into(),
            }],
            crate::document::EditIntent::Typing,
            None,
        ));
        assert!(store.sync_document(first, vec![Segment::Chip(removed)]));
        assert!(store.sync_document(
            first,
            vec![
                Segment::Ink("# dep**loy** notes\n".into()),
                Segment::Chip(token),
                Segment::Ink("\ntrailing \u{1F511} ink".into()),
                Segment::Chip(image),
            ],
        ));
        assert_eq!(store.sheet(first).unwrap().detached().count(), 1);
        let second = store.new_tab().1;
        assert!(store.sync_document(second, vec![Segment::Ink("errands".into())]));
        let doomed = store.new_tab().1;
        assert!(store.sync_document(doomed, vec![Segment::Ink("old thoughts".into())]));
        assert!(store.close_tab(slot(&store, doomed)));
        (store, clock, first, second)
    }

    #[test]
    fn round_trip_preserves_pages_chips_and_titles() {
        let (original, clock, first, second) = populated();
        let snapshot = original.snapshot(1_000_000);

        let mut revived = store_on(clock.clone());
        let restored = revived.restore(&snapshot, 1_000_000).unwrap();
        assert_eq!(restored, 2);

        let order: Vec<SheetId> = revived.sheets().map(Sheet::id).collect();
        assert_eq!(order, vec![first, second]);

        assert!(
            contains(&snapshot, b"dep**loy** notes"),
            "the control: the line it derives from is in the blob"
        );
        assert!(
            !contains(&snapshot, b"deploy notes"),
            "a content-derived title reached the sealed file"
        );
        let sheet = revived.sheet(first).unwrap();
        assert_eq!(sheet.derived_title(), Some("deploy notes"));
        assert_eq!(
            revived.tabs().next().unwrap().label(0).as_str(),
            "deploy notes",
            "the label falls through to it, this tab having no name"
        );
        assert_eq!(
            sheet.created_wall_ms(),
            original.sheet(first).unwrap().created_wall_ms()
        );
        assert_eq!(sheet.segments(), original.sheet(first).unwrap().segments());
        assert_eq!(sheet.chip_count(), 2);
        let chips: Vec<&SealedChip> = sheet.chips().collect();
        assert_eq!(
            chips[0].excerpt(),
            original
                .sheet(first)
                .unwrap()
                .chips()
                .next()
                .unwrap()
                .excerpt()
        );
        assert_eq!(chips[0].conceal().unwrap().receipt_id, "receipt-42");
        assert_eq!(chips[0].name(), Some("DEPLOY_TOKEN"));
        assert_eq!(
            &**revived.note_text(chips[0].id()).unwrap(),
            "rotate after \u{1F511} the audit"
        );
        assert!(
            !revived.note_can_undo(chips[0].id()),
            "a note's undo starts empty after a restore"
        );
        assert_eq!(chips[1].excerpt(), "PNG image");
        assert!(chips[1].conceal().is_none());
        assert_eq!(chips[1].name(), None);
        assert!(!chips[1].has_note());

        let (bytes, _) = revived.copy_out_chip(chips[0].id()).unwrap();
        assert_eq!(&*bytes, b"ghp_expected-to-survive");

        let stamped = original
            .sheet(first)
            .unwrap()
            .document
            .first_change_timestamp();
        assert!(
            stamped.is_some_and(|t| t > 0),
            "the control: the original body's first change is stamped"
        );
        assert_eq!(sheet.document.first_change_timestamp(), stamped);

        assert_eq!(revived.ledger().count(), 0);
    }

    #[test]
    fn a_detached_chip_comes_back_detached_with_its_name_and_note() {
        let (original, clock, first, _) = populated();
        let kept = original.sheet(first).unwrap().detached().next().unwrap();
        let uuid = kept.uuid();
        let snapshot = original.snapshot(1_000_000);

        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 1_000_000).unwrap();
        let sheet = revived.sheet(first).unwrap();
        let back: Vec<&SealedChip> = sheet.detached().collect();
        assert_eq!(back.len(), 1, "kept apart, on the page's clock");
        assert_eq!(back[0].uuid(), uuid);
        assert_eq!(back[0].name(), Some("KEPT"));
        let id = back[0].id();
        assert!(
            revived.note_text(id).is_none(),
            "the note's routes reach only a standing object"
        );
        assert!(sheet.chips().all(|chip| chip.uuid() != uuid));

        // A restate naming it stands it again, payload and note intact.
        assert!(revived.sync_document(first, vec![Segment::Chip(id)]));
        assert_eq!(&**revived.copy_out_chip(id).unwrap().0, b"removed but kept");
        assert_eq!(&**revived.note_text(id).unwrap(), "detached \u{1F511} note");
    }

    #[test]
    fn a_page_written_before_detached_chips_existed_restores_with_none() {
        let (store, clock, id) = page_cut_after_it_was_written();
        let wall = real_wall_ms();
        let snapshot = store.snapshot(wall);
        let tab = first_tab(&snapshot);
        let page_len = le_u64(&tab[UNNAMED_TAB_PREFIX..]);
        let page_at = UNNAMED_TAB_PREFIX + 8;
        let page = &tab[page_at..page_at + page_len];
        // An empty detached list, eight bytes, then a cut flag of one.
        for (older_by, what) in [(9, "both fields"), (1, "the cut flag")] {
            let mut rebuilt_tab = tab[..UNNAMED_TAB_PREFIX].to_vec();
            rebuilt_tab.extend_from_slice(&frame(&page[..page.len() - older_by]));
            let older = with_first_tab(&snapshot, &rebuilt_tab);

            let mut revived = store_on(clock.clone());
            assert_eq!(revived.restore(&older, wall).unwrap(), 1, "without {what}");
            let sheet = revived.sheets().next().unwrap();
            assert_eq!(sheet.detached().count(), 0);
            assert_eq!(sheet.segments(), store.sheet(id).unwrap().segments());
            assert!(revived.active_cut().is_none());
        }
    }

    #[test]
    fn a_detached_chip_repeating_an_identity_is_malformed() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, "standing", 0, 0).unwrap();
        let twin = store.seal_text_at(id, "its twin", 1, 0).unwrap();
        // The twin detaches, then takes the standing chip's identity.
        assert!(store.sync_document(id, vec![Segment::Chip(chip)]));
        let uuid = store.sheet(id).unwrap().chip(chip).unwrap().uuid();
        let sheet = store.tabs[0].page.as_mut().unwrap();
        let index = sheet.detached.iter().position(|c| c.id == twin).unwrap();
        sheet.detached[index].uuid = uuid;
        let snapshot = store.snapshot(0);

        let mut revived = store_on(clock);
        assert_eq!(revived.restore(&snapshot, 0), Err(RestoreError::Malformed));
        assert!(revived.has_no_tabs(), "the store is untouched");
    }

    #[test]
    fn the_origin_message_survives_the_round_trip() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let origin = r#"{"origin":"https://origin.example.test/reset?tk=Vq9Zx"}"#;
        store
            .seal_text_at_with_origin(id, "the pasted secret", 0, 0, Some(origin))
            .unwrap();
        assert_eq!(
            store
                .sheet(id)
                .unwrap()
                .document
                .first_change_message()
                .as_deref(),
            Some(origin),
            "the control: the seal commit carries the origin before the trip"
        );

        let snapshot = store.snapshot(0);

        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 0).unwrap();
        let sheet = revived.sheets().next().unwrap();
        assert_eq!(
            sheet.document.first_change_message().as_deref(),
            Some(origin),
            "the origin message rides the blob through the round trip"
        );

        let ledger = store.ledger_snapshot();
        let needle = b"origin.example.test";
        assert!(
            !ledger.windows(needle.len()).any(|w| w == needle),
            "the origin leaked into the ledger snapshot"
        );
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    fn page_cut_after_it_was_written() -> (SheetStore<ManualClock>, ManualClock, SheetId) {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let sheet = store.tabs[0].page.as_mut().expect("the tab holds a page");
        sheet.document.insert(0, "hello\n").unwrap();
        sheet.blocks.note_insert(0, "hello\n");
        sheet.document.insert(6, "world").unwrap();
        sheet.blocks.note_insert(6, "world");
        sheet.document.commit_at(36_000);
        sheet.document.delete(6, 5).unwrap();
        sheet.blocks.note_delete(6, 5);
        sheet.document.commit_at(39_600);
        sheet.rebuild_segments();
        sheet.settle_blocks();
        sheet.compact();
        assert_eq!(sheet.modified_s(), Some(39_600));
        (store, clock, id)
    }

    #[test]
    fn a_deletions_stamp_is_the_pages_floor_across_a_restore() {
        let (store, clock, _) = page_cut_after_it_was_written();
        let wall = real_wall_ms();
        let snapshot = store.snapshot(wall);

        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&snapshot, wall).unwrap(), 1);
        let sheet = revived.sheets().next().unwrap();
        assert_eq!(
            sheet.modified_s(),
            Some(39_600),
            "the page's newest change survived the relaunch"
        );

        let metas = sheet.blocks_meta();
        assert_eq!(metas[0].modified_s, Some(36_000));
        assert_eq!(metas[1].modified_s, None);
    }

    #[test]
    fn a_file_written_before_the_page_floor_existed_still_restores() {
        let (store, clock, id) = page_cut_after_it_was_written();
        let wall = real_wall_ms();
        let snapshot = store.snapshot(wall);
        let honest = store.sheet(id).unwrap().blocks_meta();

        let older = without_the_page_floor(&snapshot, floor_len(store.sheet(id).unwrap()));
        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&older, wall).unwrap(), 1);
        let sheet = revived.sheets().next().unwrap();
        assert_eq!(sheet.segments(), [Segment::Ink("hello\n".into())]);
        let metas = sheet.blocks_meta();
        assert_eq!(
            metas[0], honest[0],
            "the frozen block's identity and stamps are the file's, floor or no floor"
        );
        assert_eq!(metas.len(), honest.len());
        assert_eq!(metas[1].created_s, None);
        assert_eq!(
            sheet.modified_s(),
            Some(36_000),
            "with no floor in the file the page rests on its summaries, \
             which is exactly what the build that wrote it did"
        );
    }

    #[test]
    fn an_unknown_page_floor_tag_is_malformed() {
        let (store, clock, id) = page_cut_after_it_was_written();
        let wall = real_wall_ms();
        let snapshot = store.snapshot(wall);
        let tab = first_tab(&snapshot);
        let page_len = le_u64(&tab[UNNAMED_TAB_PREFIX..]);
        let page_at = UNNAMED_TAB_PREFIX + 8;
        let page = &tab[page_at..page_at + page_len];
        let mut body = page[..page.len() - floor_len(store.sheet(id).unwrap())].to_vec();
        body.push(9);
        let mut rebuilt_tab = tab[..UNNAMED_TAB_PREFIX].to_vec();
        rebuilt_tab.extend_from_slice(&frame(&body));
        let damaged = with_first_tab(&snapshot, &rebuilt_tab);
        let mut revived = store_on(clock);
        assert_eq!(
            revived.restore(&damaged, wall),
            Err(RestoreError::Malformed)
        );
        assert!(revived.has_no_tabs());
    }

    fn real_wall_ms() -> u64 {
        u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("the clock sits after the epoch")
                .as_millis(),
        )
        .expect("millisecond count fits u64")
    }

    #[test]
    fn a_compacted_store_round_trips_materialized_metadata_and_origin() {
        use crate::store::EditOp;
        fn wiping_owner<T: zeroize::ZeroizeOnDrop>(_: &T) {}
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let origin = r#"{"origin":"https://origin.example.test/reset?tk=Vq9Zx"}"#;
        store
            .seal_text_at_with_origin(id, "the pasted secret", 0, 0, Some(origin))
            .unwrap();
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
        let old_peer = store.tabs[0].page.as_ref().unwrap().document.peer_id();

        store.cycle_rung(slot(&store, id)).unwrap();
        let sheet = store.sheet(id).unwrap();
        let segments = sheet.segments().to_vec();
        let metas = sheet.blocks_meta();
        let modified = sheet.modified_s();
        assert!(modified.is_some(), "the frozen floor answers for the page");

        let wall = real_wall_ms();
        let snapshot = store.snapshot(wall);
        assert!(!contains(&snapshot, b"DOOMED"));
        assert!(!contains(&snapshot, &old_peer.to_le_bytes()));
        assert!(
            contains(&snapshot, b"origin.example.test"),
            "the graduated origin must survive into the sealed file"
        );

        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&snapshot, wall).unwrap(), 1);
        let sheet = revived.sheets().next().unwrap();
        assert_eq!(sheet.segments(), segments.as_slice());
        assert_eq!(
            sheet.blocks_meta(),
            metas,
            "block identities and stamps are adopted from the slot, not re-minted"
        );
        assert_eq!(sheet.modified_s(), modified);
        let restored = sheet.blocks.records()[0]
            .materialized
            .as_ref()
            .unwrap()
            .origin
            .as_ref()
            .unwrap();
        assert_eq!(
            restored.as_str(),
            origin,
            "the origin rides the materialized record through the round trip"
        );
        // A wiping owner whose capacity is its length (C17).
        wiping_owner(restored);
        assert_eq!(
            restored.capacity(),
            restored.len(),
            "the restored origin grew"
        );
    }

    #[test]
    fn a_pasted_block_comes_back_from_the_file_as_one_block() {
        use crate::store::EditOp;
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "one\ntwo\nthree".into()
            }]
        ));
        let before = store.sheet(id).unwrap().blocks_meta();
        assert_eq!(before.len(), 1);

        let wall = real_wall_ms();
        let snapshot = store.snapshot(wall);
        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&snapshot, wall).unwrap(), 1);

        let after = revived.sheets().next().unwrap().blocks_meta();
        assert_eq!(after.len(), 1, "the grouping survived the round trip");
        assert_eq!(after[0].paragraphs, 3);
        assert_eq!(after[0].created_s, before[0].created_s);
    }

    #[test]
    fn hostile_materialized_stamps_are_clamped_and_dead_anchors_dropped() {
        use crate::store::EditOp;
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Insert {
                    pos_u16: 0,
                    text: "first\u{1F600}\n".into()
                },
                EditOp::Insert {
                    pos_u16: 8,
                    text: "second".into()
                }
            ]
        ));
        store.cycle_rung(slot(&store, id)).unwrap();
        let honest = store.sheet(id).unwrap().blocks_meta();

        {
            let records = store.tabs[0].page.as_mut().unwrap().blocks.records_mut();
            let frozen = records[0].materialized.as_mut().unwrap();
            frozen.created_s = i64::MAX;
            frozen.modified_s = -40;
            records[1].anchor = vec![0xde, 0xad, 0xbe, 0xef];
        }
        let wall = real_wall_ms();
        let snapshot = store.snapshot(wall);
        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&snapshot, wall).unwrap(), 1);
        let metas = revived.sheets().next().unwrap().blocks_meta();

        let ceiling = i64::try_from(wall / 1000).unwrap() + STAMP_SLACK_S;
        assert_eq!(metas[0].id, honest[0].id);
        assert_eq!(metas[0].created_s, Some(ceiling));
        assert_eq!(metas[0].modified_s, Some(ceiling));

        assert_ne!(metas[1].id, honest[1].id);
        assert_eq!(metas[1].created_s, None);
        assert_eq!(metas[1].modified_s, None);
    }

    #[test]
    fn a_tab_name_is_written_down_and_the_pages_own_title_is_not() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        assert!(store.set_title(slot(&store, id), "quarterly numbers"));
        assert!(store.sync_document(id, vec![Segment::Ink("# some**thing** else".into())]));
        let snapshot = store.snapshot(0);

        assert!(
            contains(&snapshot, b"quarterly numbers"),
            "the name the user typed must survive verbatim"
        );
        assert!(
            contains(&snapshot, b"some**thing** else"),
            "the control: the line it derives from is in the blob"
        );
        assert!(
            !contains(&snapshot, b"something else"),
            "the page's derived title must not be in the file"
        );

        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 0).unwrap();
        let tab = revived.tabs().next().unwrap();
        assert_eq!(tab.name(), Some("quarterly numbers"));
        assert_eq!(tab.label(0).as_str(), "quarterly numbers");
        assert_eq!(
            tab.page().unwrap().derived_title(),
            Some("something else"),
            "recomputed from the restored segments, not read back"
        );
    }

    #[test]
    fn a_snapped_deadline_survives_the_round_trip() {
        let clock = ManualClock::new()
            .with_wall_ms(1_781_108_400_000)
            .with_local_offset_seconds(-7 * 3600);
        let mut store = SheetStore::new(clock.clone());
        let id = store.new_tab().1;
        let snapped = 7 * 24 * HOUR + 14 * HOUR + Duration::from_secs(40 * 60);
        assert_eq!(store.sheet(id).unwrap().remaining(store.now()), snapped);
        let snapshot = store.snapshot(0);

        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 3 * 60 * 60 * 1000).unwrap();
        assert_eq!(
            revived.sheet(id).unwrap().remaining(revived.now()),
            snapped - 3 * HOUR,
            "the snap was clamped away by a restore reading the nominal rung"
        );
    }

    #[test]
    fn a_two_tab_strip_round_trips_with_its_names_rungs_and_order() {
        let (mut store, clock) = store();
        let named = store.new_tab().1;
        let unnamed = store.new_tab().1;
        assert!(store.set_title(slot(&store, named), "quarterly numbers"));
        store.set_rung(slot(&store, named), Ttl::MIN).unwrap();
        assert!(store.sync_document(unnamed, vec![Segment::Ink("errands".into())]));

        let snapshot = store.snapshot(0);
        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&snapshot, 0).unwrap(), 2);

        let tabs: Vec<&Tab> = revived.tabs().collect();
        assert_eq!(tabs.len(), 2);
        assert_eq!(tabs[0].name(), Some("quarterly numbers"));
        assert_eq!(tabs[0].rung(), Ttl::MIN);
        assert_eq!(tabs[0].label(0).as_str(), "quarterly numbers");
        assert_eq!(tabs[1].name(), None, "an unnamed tab stays unnamed");
        assert_eq!(tabs[1].rung(), Ttl::from_secs(8 * 60 * 60).unwrap());
        assert_eq!(
            tabs[1].label(0).as_str(),
            "errands",
            "its page supplies the label"
        );
        let before: Vec<ItemId> = store.tabs().map(Tab::uuid).collect();
        assert_eq!(revived.tabs().map(Tab::uuid).collect::<Vec<_>>(), before);
    }

    #[test]
    fn an_emptied_strip_reseals_as_names_rungs_and_order_with_no_content() {
        let (mut store, clock) = store();
        let first = store.new_tab().1;
        let second = store.new_tab().1;
        assert!(store.set_title(slot(&store, second), "payroll"));
        store.set_rung(slot(&store, first), Ttl::MIN).unwrap();
        store.set_rung(slot(&store, second), Ttl::MIN).unwrap();
        assert!(store.sync_document(first, vec![Segment::Ink("rotate the key".into())]));
        let uuids: Vec<ItemId> = store.tabs().map(Tab::uuid).collect();

        clock.advance(Duration::from_secs(60 * 60));
        assert_eq!(store.expire_due().len(), 2);
        assert!(store.holds_no_page());
        assert!(!store.has_no_tabs());

        let snapshot = store.snapshot(0);
        assert!(
            !contains(&snapshot, b"rotate the key"),
            "a resealed empty strip must carry no page content"
        );

        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&snapshot, 0).unwrap(), 0, "no live page");
        let tabs: Vec<&Tab> = revived.tabs().collect();
        assert_eq!(tabs.len(), 2, "both slots came back");
        assert!(tabs.iter().all(|tab| tab.page().is_none()));
        assert_eq!(tabs[0].name(), None);
        assert_eq!(tabs[1].name(), Some("payroll"));
        assert_eq!(tabs[0].rung(), Ttl::MIN, "the rung outlived its page");
        assert_eq!(tabs[1].rung(), Ttl::MIN);
        assert_eq!(
            revived.tabs().map(Tab::uuid).collect::<Vec<_>>(),
            uuids,
            "identity and order both survive the emptying"
        );
        assert_eq!(revived.next_event(), None, "and nothing is scheduled");
    }

    #[test]
    fn a_tab_that_holds_no_page_restores_as_an_empty_slot() {
        let (mut store, survivor) = occupied();
        let empty = empty_tab_snapshot(Some("payroll"));
        assert_eq!(store.restore(&empty, 0).unwrap(), 0, "no live page");
        let tabs: Vec<&Tab> = store.tabs().collect();
        assert_eq!(tabs.len(), 1, "the slot itself came back");
        assert!(tabs[0].page().is_none());
        assert_eq!(tabs[0].name(), Some("payroll"));
        assert_eq!(tabs[0].label(0).as_str(), "payroll");
        assert_eq!(tabs[0].rung(), Ttl::from_secs(8 * 60 * 60).unwrap());
        assert!(
            store.sheet(survivor).is_none(),
            "the restore replaced the strip, as any restore does"
        );
        assert_eq!(store.next_event(), None);
    }

    #[test]
    fn a_page_present_flag_that_is_neither_zero_nor_one_is_malformed() {
        let (mut store, survivor) = occupied();
        let mut hostile = empty_tab_snapshot(Some("payroll"));
        let flag = hostile.len() - 1; // the record's last byte
        assert_eq!(hostile[flag], 0, "the control: an absent page");
        for claim in [2u8, 3, 0xFF] {
            hostile[flag] = claim;
            assert_eq!(
                store.restore(&hostile, 0),
                Err(RestoreError::Malformed),
                "page-present {claim} was not refused"
            );
        }
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");
    }

    #[test]
    fn a_page_present_flag_over_an_empty_body_is_malformed() {
        let (mut store, survivor) = occupied();
        let mut hostile = empty_tab_snapshot(Some("payroll"));
        let flag = hostile.len() - 1;
        hostile[flag] = 1;
        hostile.extend_from_slice(&0u64.to_le_bytes()); // an empty frame
        widen_first_tab(&mut hostile, 8);
        assert_eq!(store.restore(&hostile, 0), Err(RestoreError::Malformed));
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");
    }

    #[test]
    fn a_hand_edited_tab_name_is_recapped_at_eighty_characters() {
        let (mut store, _survivor) = occupied();
        let long: String = "é".repeat(200);
        let snapshot = empty_tab_snapshot(Some(&long));
        assert_eq!(store.restore(&snapshot, 0).unwrap(), 0);
        let name = store.tabs().next().unwrap().name().unwrap();
        assert_eq!(name.chars().count(), TITLE_CAP);
        assert_eq!(name.len(), TITLE_CAP * 2, "counted in chars, not bytes");
    }

    #[test]
    fn a_strip_of_any_width_restores_and_a_short_one_is_malformed() {
        let (mut store, survivor) = occupied();
        let mut short = Vec::new();
        short.extend_from_slice(MAGIC);
        short.extend_from_slice(&0u64.to_le_bytes());
        short.extend_from_slice(&13u64.to_le_bytes());
        for _ in 0..12 {
            short.extend_from_slice(&frame(&tab_record(None, None)));
        }
        assert_eq!(store.restore(&short, 0), Err(RestoreError::Malformed));
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");

        let mut wide = Vec::new();
        wide.extend_from_slice(MAGIC);
        wide.extend_from_slice(&0u64.to_le_bytes());
        wide.extend_from_slice(&12u64.to_le_bytes());
        for _ in 0..12 {
            wide.extend_from_slice(&frame(&tab_record(None, None)));
        }
        assert_eq!(store.restore(&wide, 0).unwrap(), 0);
        assert_eq!(store.tabs().count(), 12);
    }

    #[test]
    fn ledger_round_trips_in_its_own_snapshot() {
        let (original, clock, ..) = populated();
        let ledger = original.ledger_snapshot();
        let expected: Vec<LedgerRecord> = original.ledger().cloned().collect();

        let mut revived = store_on(clock.clone());
        let restored = revived.restore_ledger(&ledger, clock.wall_ms()).unwrap();
        assert_eq!(restored, expected.len());
        let records: Vec<LedgerRecord> = revived.ledger().cloned().collect();
        assert_eq!(records, expected);
        assert_eq!(records[0].title(), "old thoughts");
        assert_eq!(records[0].event(), LedgerEvent::Discarded);

        assert!(revived.has_no_tabs());
        assert_eq!(
            revived.restore_ledger(&original.snapshot(0), clock.wall_ms()),
            Err(RestoreError::UnknownFormat),
            "a content snapshot is not a ledger snapshot"
        );
        assert_eq!(
            revived.restore(&ledger, 0),
            Err(RestoreError::UnknownFormat),
            "a ledger snapshot is not a content snapshot"
        );
    }

    #[test]
    fn every_destination_class_round_trips_in_the_ledger() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, "sent three ways", 0, 0).unwrap();
        let classes = [
            DestinationClass::Clipboard,
            DestinationClass::OneTimeLink,
            DestinationClass::Drag,
        ];
        for class in classes {
            assert!(store.record_sent(chip, class));
        }
        let mut revived = store_on(clock.clone());
        revived
            .restore_ledger(&store.ledger_snapshot(), clock.wall_ms())
            .unwrap();
        let sent: Vec<DestinationClass> = revived
            .ledger()
            .filter(|record| record.event() == LedgerEvent::Sent)
            .map(LedgerRecord::destination)
            .collect();
        assert_eq!(sent, [classes[2], classes[1], classes[0]], "newest first");
    }

    #[test]
    fn a_ledger_restore_keeps_the_records_the_store_already_holds() {
        let (original, clock, ..) = populated();
        let file = original.ledger_snapshot();
        let earlier: Vec<LedgerRecord> = original.ledger().cloned().collect();

        let mut revived = store_on(clock.clone());
        let doomed = revived.new_tab().1;
        assert!(revived.sync_document(doomed, vec![Segment::Ink("overnight".into())]));
        assert!(revived.close_tab(slot(&revived, doomed)));
        let overnight: Vec<LedgerRecord> = revived.ledger().cloned().collect();
        assert_eq!(overnight.len(), 2, "the page was created, then it died");

        let kept = revived.restore_ledger(&file, clock.wall_ms()).unwrap();
        assert_eq!(kept, overnight.len() + earlier.len());
        let records: Vec<LedgerRecord> = revived.ledger().cloned().collect();
        assert_eq!(
            records,
            [overnight.as_slice(), earlier.as_slice()].concat(),
            "the trail reads newest first, with the file's own order kept"
        );

        assert_eq!(
            revived.restore_ledger(&file, clock.wall_ms()).unwrap(),
            kept
        );
        assert_eq!(revived.ledger().cloned().collect::<Vec<_>>(), records);
    }

    fn ledger_record(item: ItemId, at_wall_ms: u64) -> LedgerRecord {
        LedgerRecord {
            event: LedgerEvent::Sent,
            item,
            title: Zeroizing::new(String::from("a page")),
            at_wall_ms,
            item_created_wall_ms: at_wall_ms,
            size: SizeClass::Tiny,
            destination: DestinationClass::Clipboard,
        }
    }

    fn ledger_file(records: &[LedgerRecord]) -> Zeroizing<Vec<u8>> {
        let (mut store, _) = store();
        store.ledger = records.iter().cloned().collect();
        store.ledger_snapshot()
    }

    #[test]
    fn a_ledger_restore_unions_duplicate_records_as_a_multiset() {
        let item = ItemId::random();
        let now = 1_800_000_000_000;
        let r = ledger_record(item, now);
        let one = ledger_file(std::slice::from_ref(&r));
        let two = ledger_file(&[r.clone(), r.clone()]);

        let (mut store, _) = store();
        assert_eq!(store.restore_ledger(&one, now).unwrap(), 1);
        assert_eq!(
            store.restore_ledger(&two, now).unwrap(),
            2,
            "the surplus copy the deque lacked was kept, not deduplicated away"
        );
        let records: Vec<LedgerRecord> = store.ledger().cloned().collect();
        assert_eq!(
            records,
            vec![r.clone(), r],
            "both copies survived the union"
        );
    }

    #[test]
    fn a_future_stamped_ledger_record_is_clamped_to_the_clock_on_load() {
        let now = 1_800_000_000_000;
        let year = 365 * 24 * 60 * 60 * 1000;
        let ahead = ledger_record(ItemId::random(), now + year);
        let file = ledger_file(std::slice::from_ref(&ahead));

        let (mut revived, _) = store();
        assert_eq!(revived.restore_ledger(&file, now).unwrap(), 1);
        let record = revived.ledger().next().unwrap().clone();
        assert!(
            record.at_wall_ms() <= now + STAMP_SLACK_MS,
            "the stamp was clamped to the clock: {}",
            record.at_wall_ms()
        );
        assert!(record.item_created_wall_ms() <= now + STAMP_SLACK_MS);

        let clamped = ledger_file(std::slice::from_ref(&record));
        let (mut later, _) = store();
        let past_window = record.at_wall_ms() + crate::ledger::LEDGER_RETENTION_MS + 1;
        assert_eq!(later.restore_ledger(&clamped, past_window).unwrap(), 0);
    }

    #[test]
    fn a_clock_that_reads_before_the_floor_leaves_ledger_stamps_alone() {
        let stamped = 1_800_000_000_000;
        let record = ledger_record(ItemId::random(), stamped);
        let file = ledger_file(std::slice::from_ref(&record));

        let (mut revived, _) = store();
        assert_eq!(revived.restore_ledger(&file, 5_000).unwrap(), 1);
        let kept = revived.ledger().next().unwrap().clone();
        assert_eq!(kept.at_wall_ms(), stamped);

        let (mut corrected, _) = store();
        let rewritten = ledger_file(std::slice::from_ref(&kept));
        assert_eq!(
            corrected
                .restore_ledger(&rewritten, stamped + 1_000)
                .unwrap(),
            1,
            "the record survives the clock coming right"
        );
    }

    #[test]
    fn records_past_the_retention_window_drop_on_load() {
        let (original, clock, ..) = populated();
        let ledger = original.ledger_snapshot();
        assert!(original.ledger().count() > 0);

        let mut revived = store_on(clock.clone());
        let far_future =
            original.ledger().next().unwrap().at_wall_ms() + crate::LEDGER_RETENTION_MS + 1;
        assert_eq!(revived.restore_ledger(&ledger, far_future).unwrap(), 0);
        assert_eq!(revived.ledger().count(), 0);
    }

    #[test]
    fn the_write_path_evicts_an_aged_title_with_no_new_event_recorded() {
        const TITLE: &str = "prod DB credentials";
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        assert!(store.sync_document(id, vec![Segment::Ink(format!("# {TITLE}\n"))]));
        let chip = store.seal_text(id, "hunter2-rotate-me").unwrap();
        assert!(store.sync_document(
            id,
            vec![Segment::Ink(format!("# {TITLE}\n")), Segment::Chip(chip)],
        ));
        let needle = TITLE.as_bytes();
        let held = |bytes: &[u8]| bytes.windows(needle.len()).any(|w| w == needle);
        assert_eq!(store.ledger().count(), 2, "created, sealed");
        assert!(held(&store.ledger_snapshot()), "the control");

        clock.advance(Duration::from_millis(crate::LEDGER_RETENTION_MS + 1));
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink(format!("# {TITLE}\nstill editing\n")),
                Segment::Chip(chip),
            ],
        ));
        assert_eq!(store.ledger().count(), 2, "nothing was recorded");

        assert_eq!(store.evict_ledger(clock.wall_ms()), 2, "both fell off");
        assert_eq!(store.ledger().count(), 0);
        assert!(
            !held(&store.ledger_snapshot()),
            "an aged title was re-persisted past the retention window"
        );
        assert_eq!(store.len(), 1);
        assert_eq!(store.sheet(id).unwrap().chip_count(), 1);
    }

    #[test]
    fn the_write_path_sweep_keeps_records_inside_the_window() {
        let (mut store, clock) = store();
        store.new_tab();
        clock.advance(Duration::from_millis(crate::LEDGER_RETENTION_MS));
        store.new_tab();
        assert_eq!(store.evict_ledger(clock.wall_ms()), 0);
        assert_eq!(store.ledger().count(), 2);
        clock.advance(Duration::from_millis(1));
        assert_eq!(store.evict_ledger(clock.wall_ms()), 1);
        assert_eq!(store.ledger().count(), 1);
        assert_eq!(store.evict_ledger(clock.wall_ms()), 0);
    }

    #[test]
    fn restored_ids_are_reissued_densely_and_uuids_survive() {
        let (mut store, clock) = store();
        store.next_tab_id = 7_700;
        store.next_sheet_id = 4_242;
        store.next_chip_id = 9_100;
        let first = store.new_tab().1;
        store.seal_text_at(first, "one", 0, 0).unwrap();
        store.seal_text_at(first, "two", 1, 0).unwrap();
        let second = store.new_tab().1;
        store.seal_text_at(second, "three", 0, 0).unwrap();
        assert!(first.raw() > 1000);

        let sheet_uuids: Vec<ItemId> = store.sheets().map(Sheet::uuid).collect();
        let chip_uuids: Vec<ItemId> = store
            .sheets()
            .flat_map(|s| s.chips().map(SealedChip::uuid))
            .collect();

        let snapshot = store.snapshot(0);
        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 0).unwrap();

        let ids: Vec<u64> = revived.sheets().map(|s| s.id().raw()).collect();
        assert_eq!(ids, vec![1, 2]);
        let tab_ids: Vec<u64> = revived.tabs().map(|t| t.id().raw()).collect();
        assert_eq!(tab_ids, vec![1, 2], "the tab counter re-mints too");
        let chip_ids: Vec<u64> = revived
            .sheets()
            .flat_map(|s| s.chips().map(|c| c.id().raw()))
            .collect();
        assert_eq!(chip_ids, vec![1, 2, 3]);

        assert_eq!(
            revived.sheets().map(Sheet::uuid).collect::<Vec<_>>(),
            sheet_uuids
        );
        assert_eq!(
            revived
                .sheets()
                .flat_map(|s| s.chips().map(SealedChip::uuid))
                .collect::<Vec<_>>(),
            chip_uuids
        );

        let fresh = revived.new_tab().1;
        assert_eq!(fresh.raw(), 3);
        assert_eq!(revived.tabs().last().unwrap().id().raw(), 3);
        let fresh_chip = revived.seal_text(fresh, "four").unwrap();
        assert_eq!(fresh_chip.raw(), 4);
    }

    fn frame(record: &[u8]) -> Vec<u8> {
        let mut out = (record.len() as u64).to_le_bytes().to_vec();
        out.extend_from_slice(record);
        out
    }

    fn le_u64(bytes: &[u8]) -> usize {
        usize::try_from(u64::from_le_bytes(
            bytes[..8].try_into().expect("eight bytes"),
        ))
        .expect("a length this test wrote")
    }

    fn with_trailing_field(bytes: &[u8], header: usize, extra: &[u8]) -> Vec<u8> {
        let len = le_u64(&bytes[header..]);
        let start = header + 8;
        let mut out = bytes[..header].to_vec();
        out.extend_from_slice(&((len + extra.len()) as u64).to_le_bytes());
        out.extend_from_slice(&bytes[start..start + len]);
        out.extend_from_slice(extra);
        out.extend_from_slice(&bytes[start + len..]);
        out
    }

    fn with_page_tail(snapshot: &[u8], extra: &[u8]) -> Vec<u8> {
        let tab = first_tab(snapshot);
        let mut rebuilt = tab[..UNNAMED_TAB_PREFIX].to_vec();
        rebuilt.extend_from_slice(&with_trailing_field(&tab[UNNAMED_TAB_PREFIX..], 0, extra));
        with_first_tab(snapshot, &rebuilt)
    }

    fn with_materialized_tail(
        snapshot: &[u8],
        meta_len: usize,
        floor_len: usize,
        extra: &[u8],
    ) -> Vec<u8> {
        let tab = first_tab(snapshot);
        let page_len = le_u64(&tab[UNNAMED_TAB_PREFIX..]);
        let page_at = UNNAMED_TAB_PREFIX + 8;
        let page = &tab[page_at..page_at + page_len];
        let slot_at = page.len() - floor_len - meta_len;
        let slot = with_trailing_field(&page[slot_at..page.len() - floor_len], 8, extra);
        let mut rebuilt_page = page[..slot_at - 8].to_vec();
        rebuilt_page.extend_from_slice(&frame(&slot));
        rebuilt_page.extend_from_slice(&page[page.len() - floor_len..]);
        let mut rebuilt_tab = tab[..UNNAMED_TAB_PREFIX].to_vec();
        rebuilt_tab.extend_from_slice(&frame(&rebuilt_page));
        with_first_tab(snapshot, &rebuilt_tab)
    }

    fn without_the_page_floor(snapshot: &[u8], floor_len: usize) -> Vec<u8> {
        let tab = first_tab(snapshot);
        let page_len = le_u64(&tab[UNNAMED_TAB_PREFIX..]);
        let page_at = UNNAMED_TAB_PREFIX + 8;
        let page = &tab[page_at..page_at + page_len];
        let mut rebuilt_tab = tab[..UNNAMED_TAB_PREFIX].to_vec();
        rebuilt_tab.extend_from_slice(&frame(&page[..page.len() - floor_len]));
        with_first_tab(snapshot, &rebuilt_tab)
    }

    /// The floor and the fields after it, for a page holding no detached chip
    /// and no cut.
    fn floor_len(sheet: &Sheet) -> usize {
        assert!(sheet.detached.is_empty(), "the helper counts an empty list");
        1 + usize::from(sheet.blocks.compaction_frontier().is_some()) * 8 + 8 + 1
    }

    const UNNAMED_TAB_PREFIX: usize = 16 + 8 + 1 + 8 + 1;

    fn tab_record(name: Option<&str>, page: Option<&[u8]>) -> Vec<u8> {
        tab_record_with_rung(name, 8 * 60 * 60, page)
    }

    fn tab_record_with_rung(name: Option<&str>, rung_secs: u64, page: Option<&[u8]>) -> Vec<u8> {
        let mut tab = Vec::new();
        tab.extend_from_slice(ItemId::random().as_bytes());
        tab.extend_from_slice(&0u64.to_le_bytes()); // created_wall_ms
        match name {
            None => tab.push(0),
            Some(name) => {
                tab.push(1);
                tab.extend_from_slice(&(name.len() as u64).to_le_bytes());
                tab.extend_from_slice(name.as_bytes());
            }
        }
        tab.extend_from_slice(&rung_secs.to_le_bytes());
        match page {
            None => tab.push(0),
            Some(page) => {
                tab.push(1);
                tab.extend_from_slice(&frame(page));
            }
        }
        tab
    }

    fn one_tab_snapshot(tab: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&0u64.to_le_bytes()); // saved wall stamp
        out.extend_from_slice(&1u64.to_le_bytes()); // one tab
        out.extend_from_slice(&frame(tab));
        out
    }

    fn empty_tab_snapshot(name: Option<&str>) -> Vec<u8> {
        one_tab_snapshot(&tab_record(name, None))
    }

    fn page_record(clock: &[u8], blob: &[u8]) -> Vec<u8> {
        let mut page = Vec::new();
        page.extend_from_slice(ItemId::random().as_bytes());
        page.extend_from_slice(&0u64.to_le_bytes()); // created_wall_ms
        page.extend_from_slice(clock);
        page.extend_from_slice(&0u64.to_le_bytes()); // total_held
        page.extend_from_slice(&0u64.to_le_bytes()); // no chips
        page.extend_from_slice(&(blob.len() as u64).to_le_bytes());
        page.extend_from_slice(blob);
        page.extend_from_slice(&0u64.to_le_bytes()); // empty metadata slot
        page
    }

    fn sheet_snapshot(chips: &[(ItemId, &str)], blob: &[u8]) -> Vec<u8> {
        sheet_snapshot_with_tails(chips, blob, &[])
    }

    fn sheet_snapshot_with_tails(
        chips: &[(ItemId, &str)],
        blob: &[u8],
        chip_tail: &[u8],
    ) -> Vec<u8> {
        let mut page = Vec::new();
        page.extend_from_slice(ItemId::random().as_bytes());
        page.extend_from_slice(&0u64.to_le_bytes()); // created_wall_ms
        page.push(0); // running
        page.extend_from_slice(&60_000u64.to_le_bytes()); // remaining ms
        page.extend_from_slice(&0u64.to_le_bytes()); // total_held
        page.extend_from_slice(&(chips.len() as u64).to_le_bytes());
        for (uuid, text) in chips {
            let mut chip = Vec::new();
            chip.extend_from_slice(uuid.as_bytes());
            chip.push(0); // its value is here
            chip.push(0); // a text chip
            chip.push(0); // never concealed
            chip.extend_from_slice(&(text.len() as u64).to_le_bytes());
            chip.extend_from_slice(text.as_bytes());
            chip.extend_from_slice(chip_tail);
            page.extend_from_slice(&frame(&chip));
        }
        page.extend_from_slice(&(blob.len() as u64).to_le_bytes());
        page.extend_from_slice(blob);
        page.extend_from_slice(&0u64.to_le_bytes()); // empty metadata slot

        one_tab_snapshot(&tab_record(None, Some(&page)))
    }

    fn widen_first_tab(snapshot: &mut [u8], extra: usize) {
        let at = MAGIC.len() + 16;
        let len = le_u64(&snapshot[at..]) + extra;
        snapshot[at..at + 8].copy_from_slice(&(len as u64).to_le_bytes());
    }

    fn first_tab(snapshot: &[u8]) -> &[u8] {
        let at = MAGIC.len() + 16;
        let len = le_u64(&snapshot[at..]);
        &snapshot[at + 8..at + 8 + len]
    }

    fn with_first_tab(snapshot: &[u8], rebuilt: &[u8]) -> Vec<u8> {
        let at = MAGIC.len() + 16;
        let len = le_u64(&snapshot[at..]);
        let mut out = snapshot[..at].to_vec();
        out.extend_from_slice(&frame(rebuilt));
        out.extend_from_slice(&snapshot[at + 8 + len..]);
        out
    }

    fn occupied() -> (SheetStore<ManualClock>, SheetId) {
        let (mut store, _clock) = store();
        let survivor = store.new_tab().1;
        (store, survivor)
    }

    #[test]
    fn a_trailing_field_on_a_tab_record_is_skipped_not_refused() {
        let (original, clock, first, second) = populated();
        let snapshot = original.snapshot(1_000_000);
        let extended = with_trailing_field(&snapshot, MAGIC.len() + 16, b"a tab field from 2027");

        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&extended, 1_000_000).unwrap(), 2);
        let order: Vec<SheetId> = revived.sheets().map(Sheet::id).collect();
        assert_eq!(
            order,
            vec![first, second],
            "the tab after the unknown field was not found"
        );
        assert_eq!(
            revived.tabs().next().unwrap().label(0).as_str(),
            "deploy notes"
        );
    }

    #[test]
    fn a_trailing_field_on_a_page_record_is_skipped_not_refused() {
        let (original, clock, first, second) = populated();
        let snapshot = original.snapshot(1_000_000);
        let extended = with_page_tail(&snapshot, b"a page field from 2027");

        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&extended, 1_000_000).unwrap(), 2);
        let order: Vec<SheetId> = revived.sheets().map(Sheet::id).collect();
        assert_eq!(
            order,
            vec![first, second],
            "the tab after the extended page was not found"
        );

        let sheet = revived.sheet(first).unwrap();
        assert_eq!(sheet.derived_title(), Some("deploy notes"));
        assert_eq!(sheet.segments(), original.sheet(first).unwrap().segments());
        let chips: Vec<&SealedChip> = sheet.chips().collect();
        assert_eq!(chips.len(), 2);
        let (bytes, _) = revived.copy_out_chip(chips[0].id()).unwrap();
        assert_eq!(&*bytes, b"ghp_expected-to-survive");
    }

    #[test]
    fn a_trailing_field_on_a_chip_record_is_skipped_not_refused() {
        let (mut store, _clock) = store();
        let uuid = ItemId::random();
        let doc = SheetDocument::new();
        doc.insert_chip(0, uuid).unwrap();
        doc.insert(1, " and ink \u{1F600}").unwrap();
        doc.commit(None);
        // No name, no note, then the field this build does not know.
        let tail = [&[0u8, 0][..], b"a chip field from 2027"].concat();
        let snapshot =
            sheet_snapshot_with_tails(&[(uuid, "ghp_still-here")], &doc.export_snapshot(), &tail);

        assert_eq!(store.restore(&snapshot, 0).unwrap(), 1);
        let chip = store.sheets().next().unwrap().chips().next().unwrap();
        assert_eq!(chip.uuid(), uuid);
        let (bytes, _) = store.copy_out_chip(chip.id()).unwrap();
        assert_eq!(&*bytes, b"ghp_still-here");
    }

    fn one_chip_document(uuid: ItemId) -> Zeroizing<Vec<u8>> {
        let doc = SheetDocument::new();
        doc.insert_chip(0, uuid).unwrap();
        doc.commit(None);
        doc.export_snapshot()
    }

    /// A present name or note: flag 1, then the length prefixed text.
    fn text_field(text: &str) -> Vec<u8> {
        let mut field = vec![1u8];
        field.extend_from_slice(&(text.len() as u64).to_le_bytes());
        field.extend_from_slice(text.as_bytes());
        field
    }

    #[test]
    fn a_chip_written_before_names_existed_restores_unnamed() {
        let (mut store, _clock) = store();
        let uuid = ItemId::random();
        let snapshot = sheet_snapshot(&[(uuid, "ghp_older-build")], &one_chip_document(uuid));
        assert_eq!(store.restore(&snapshot, 0).unwrap(), 1);
        let chip = store.sheets().next().unwrap().chips().next().unwrap();
        assert_eq!(chip.name(), None);
        let (bytes, _) = store.copy_out_chip(chip.id()).unwrap();
        assert_eq!(&*bytes, b"ghp_older-build");
    }

    #[test]
    fn a_written_name_comes_back_and_one_the_rule_refuses_is_dropped() {
        let uuid = ItemId::random();
        let document = one_chip_document(uuid);
        for (written, expected) in [
            ("API_KEY", Some("API_KEY")),
            ("my.key", None),
            ("9lives", None),
            (&"A".repeat(65)[..], None),
        ] {
            let (mut store, _clock) = store();
            let snapshot = sheet_snapshot_with_tails(
                &[(uuid, "ghp_named-or-not")],
                &document,
                &text_field(written),
            );
            assert_eq!(store.restore(&snapshot, 0).unwrap(), 1, "{written}");
            let chip = store.sheets().next().unwrap().chips().next().unwrap();
            assert_eq!(chip.name(), expected, "{written}");
            let (bytes, _) = store.copy_out_chip(chip.id()).unwrap();
            assert_eq!(&*bytes, b"ghp_named-or-not", "the chip outlived its name");
        }
    }

    #[test]
    fn a_chip_written_before_notes_existed_keeps_its_name_and_has_no_note() {
        let (mut store, _clock) = store();
        let uuid = ItemId::random();
        let snapshot = sheet_snapshot_with_tails(
            &[(uuid, "ghp_named-only")],
            &one_chip_document(uuid),
            &text_field("API_KEY"),
        );
        assert_eq!(store.restore(&snapshot, 0).unwrap(), 1);
        let chip = store.sheets().next().unwrap().chips().next().unwrap();
        assert_eq!(chip.name(), Some("API_KEY"));
        assert!(!chip.has_note());
        assert_eq!(&**store.note_text(chip.id()).unwrap(), "");
    }

    #[test]
    fn a_written_note_comes_back_beside_its_name() {
        let (mut store, _clock) = store();
        let uuid = ItemId::random();
        let mut tail = vec![0u8]; // no name
        tail.extend_from_slice(&text_field("kept \u{1F600} beside it"));
        let snapshot =
            sheet_snapshot_with_tails(&[(uuid, "ghp_noted")], &one_chip_document(uuid), &tail);
        assert_eq!(store.restore(&snapshot, 0).unwrap(), 1);
        let chip = store.sheets().next().unwrap().chips().next().unwrap();
        assert_eq!(chip.name(), None);
        assert!(chip.has_note());
        assert_eq!(
            &**store.note_text(chip.id()).unwrap(),
            "kept \u{1F600} beside it"
        );
    }

    /// A chip record's name and note each come back as one wiping copy at its exact size,
    /// and the note makes no document until it is edited (Law 0004, C31).
    #[test]
    fn a_restored_name_and_note_rest_as_wiping_copies_until_the_note_is_edited() {
        fn wiping_owner<T: zeroize::ZeroizeOnDrop>(_: &T) {}

        let (mut store, _clock) = store();
        let uuid = ItemId::random();
        let mut tail = text_field("API_KEY");
        tail.extend_from_slice(&text_field("kept \u{1F600} beside it"));
        let snapshot =
            sheet_snapshot_with_tails(&[(uuid, "ghp_noted")], &one_chip_document(uuid), &tail);
        assert_eq!(store.restore(&snapshot, 0).unwrap(), 1);
        let chip = store.sheets().next().unwrap().chips().next().unwrap();
        let name = chip.name.as_ref().expect("the name came back");
        wiping_owner(name);
        assert_eq!(name.capacity(), name.len(), "the name grew past its size");
        let note = chip
            .note
            .as_ref()
            .and_then(Note::resting)
            .expect("the restore made the note a document");
        wiping_owner(note);
        assert_eq!(note.capacity(), note.len(), "the note grew past its size");
        assert_eq!(note.as_str(), "kept \u{1F600} beside it");

        let id = chip.id();
        let quoted = [crate::store::EditOp::Insert {
            pos_u16: 0,
            text: "> ".into(),
        }];
        assert!(store.apply_note_ops(id, &quoted, crate::document::EditIntent::Typing, None));
        let chip = store.sheets().next().unwrap().chips().next().unwrap();
        assert!(
            chip.note.as_ref().and_then(Note::resting).is_none(),
            "the edit never reached a document"
        );
        assert_eq!(
            &**store.note_text(id).unwrap(),
            "> kept \u{1F600} beside it"
        );
    }

    /// A note that rests is written back as the field it came from, and rests again after
    /// the next restore (Law 0004, C31).
    #[test]
    fn a_resting_note_is_written_back_as_it_came_and_rests_after_the_next_restore() {
        let (mut store, clock) = store();
        let uuid = ItemId::random();
        let note = "kept \u{1F600} beside it";
        let mut tail = vec![0u8]; // no name
        tail.extend_from_slice(&text_field(note));
        let snapshot =
            sheet_snapshot_with_tails(&[(uuid, "ghp_noted")], &one_chip_document(uuid), &tail);
        assert_eq!(store.restore(&snapshot, 1_000_000).unwrap(), 1);
        let written = store.snapshot(1_000_000);
        assert!(
            contains(&written, &tail),
            "the note's field changed on the way back"
        );

        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&written, 1_000_000).unwrap(), 1);
        let chip = revived.sheets().next().unwrap().chips().next().unwrap();
        let rests = chip.note.as_ref().and_then(Note::resting);
        assert_eq!(
            rests.map(|text| text.as_str()),
            Some(note),
            "it no longer rests"
        );
        assert_eq!(
            *revived.snapshot(1_000_000),
            *written,
            "a second round trip moved the bytes"
        );
    }

    #[test]
    fn an_unknown_note_flag_is_malformed_and_the_store_is_untouched() {
        let (mut store, survivor) = occupied();
        let uuid = ItemId::random();
        let snapshot =
            sheet_snapshot_with_tails(&[(uuid, "ghp_flagged")], &one_chip_document(uuid), &[0, 7]);
        assert_eq!(store.restore(&snapshot, 0), Err(RestoreError::Malformed));
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");
    }

    #[test]
    fn an_unknown_name_flag_is_malformed_and_the_store_is_untouched() {
        let (mut store, survivor) = occupied();
        let uuid = ItemId::random();
        let snapshot =
            sheet_snapshot_with_tails(&[(uuid, "ghp_flagged")], &one_chip_document(uuid), &[2]);
        assert_eq!(store.restore(&snapshot, 0), Err(RestoreError::Malformed));
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");
    }

    #[test]
    fn a_trailing_field_on_a_materialized_record_is_skipped_not_refused() {
        use crate::store::EditOp;
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Insert {
                    pos_u16: 0,
                    text: "first\u{1F600}\n".into()
                },
                EditOp::Insert {
                    pos_u16: 8,
                    text: "second".into()
                }
            ]
        ));
        store.cycle_rung(slot(&store, id)).unwrap();
        let honest = store.sheet(id).unwrap().blocks_meta();
        assert!(
            honest.len() == 2 && honest[1].created_s.is_some(),
            "the control: the ceremony froze a summary onto both blocks"
        );

        let page = store.tabs[0].page.as_ref().unwrap();
        let meta_len = encode_materialized(&page.blocks, &page.document).len();
        let wall = real_wall_ms();
        let snapshot = store.snapshot(wall);
        let extended = with_materialized_tail(
            &snapshot,
            meta_len,
            floor_len(page),
            b"a block field from 2027",
        );

        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&extended, wall).unwrap(), 1);
        assert_eq!(
            revived.sheets().next().unwrap().blocks_meta(),
            honest,
            "the record after the unknown field did not adopt onto its block"
        );
    }

    #[test]
    fn a_trailing_field_on_a_ledger_record_is_skipped_not_refused() {
        let (original, clock, ..) = populated();
        let ledger = original.ledger_snapshot();
        let expected: Vec<LedgerRecord> = original.ledger().cloned().collect();
        assert!(
            expected.len() > 1,
            "the control: a record follows the extended one"
        );
        let extended =
            with_trailing_field(&ledger, LEDGER_MAGIC.len() + 8, b"a ledger field from 2027");

        let mut revived = store_on(clock.clone());
        assert_eq!(
            revived.restore_ledger(&extended, clock.wall_ms()).unwrap(),
            expected.len()
        );
        assert_eq!(revived.ledger().cloned().collect::<Vec<_>>(), expected);
    }

    #[test]
    fn a_dangling_chip_mark_is_malformed_and_the_store_is_untouched() {
        let (mut store, survivor) = occupied();
        let doc = SheetDocument::new();
        doc.insert(0, "ink \u{1F600} ink").unwrap();
        doc.insert_chip(2, ItemId::random()).unwrap();
        doc.commit(None);
        let snapshot = sheet_snapshot(&[], &doc.export_snapshot());
        assert_eq!(
            store.restore(&snapshot, 0),
            Err(RestoreError::Malformed),
            "a chip mark with no record must reject the whole snapshot"
        );
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");
    }

    #[test]
    fn an_orphan_chip_record_is_malformed_and_the_store_is_untouched() {
        let (mut store, survivor) = occupied();
        let doc = SheetDocument::new();
        doc.insert(0, "just ink \u{1F980}").unwrap();
        doc.commit(None);
        let snapshot = sheet_snapshot(&[(ItemId::random(), "unclaimed")], &doc.export_snapshot());
        assert_eq!(
            store.restore(&snapshot, 0),
            Err(RestoreError::Malformed),
            "a chip record with no mark must reject the whole snapshot"
        );
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");
    }

    #[test]
    fn a_duplicate_chip_mark_is_malformed_and_the_store_is_untouched() {
        let (mut store, survivor) = occupied();
        let id = ItemId::random();
        let doc = SheetDocument::new();
        doc.insert_chip(0, id).unwrap();
        doc.insert(1, "\u{1F600}").unwrap();
        doc.insert_chip(3, id).unwrap();
        doc.commit(None);
        let snapshot = sheet_snapshot(&[(id, "claimed twice")], &doc.export_snapshot());
        assert_eq!(
            store.restore(&snapshot, 0),
            Err(RestoreError::Malformed),
            "one record claimed by two marks must reject the whole snapshot"
        );
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");
    }

    #[test]
    fn a_blob_that_does_not_import_is_malformed_and_the_store_is_untouched() {
        let (mut store, survivor) = occupied();
        let snapshot = sheet_snapshot(&[], b"not a loro blob");
        assert_eq!(
            store.restore(&snapshot, 0),
            Err(RestoreError::Malformed),
            "a blob the decoder refuses must reject the whole snapshot"
        );
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");
    }

    #[test]
    fn no_sequential_counter_appears_in_either_snapshot() {
        const SHEET_RAW: u64 = 0x1234_5678_9ABC_DEF0;
        const CHIP_RAW: u64 = 0x0FED_CBA9_8765_4321;
        const TAB_RAW: u64 = 0x2143_6587_A9CB_ED0F;
        let (mut store, _clock) = store();
        store.next_tab_id = TAB_RAW;
        store.next_sheet_id = SHEET_RAW;
        store.next_chip_id = CHIP_RAW;
        let id = store.new_tab().1;
        let chip = store.seal_text(id, "counted").unwrap();
        assert!(store.sync_document(id, vec![Segment::Chip(chip)]));
        assert_eq!(id.raw(), SHEET_RAW);
        assert_eq!(chip.raw(), CHIP_RAW);
        assert_eq!(store.tabs().next().unwrap().id().raw(), TAB_RAW);
        assert!(store.record_sent(chip, DestinationClass::Clipboard));

        let content = store.snapshot(0);
        let ledger = store.ledger_snapshot();
        for needle in [
            SHEET_RAW.to_le_bytes(),
            CHIP_RAW.to_le_bytes(),
            TAB_RAW.to_le_bytes(),
        ] {
            assert!(
                !content.windows(8).any(|w| w == needle),
                "a sequential id reached the content snapshot"
            );
            assert!(
                !ledger.windows(8).any(|w| w == needle),
                "a sequential id reached the ledger snapshot"
            );
        }

        let peer = store
            .sheets()
            .next()
            .unwrap()
            .document
            .peer_id()
            .to_le_bytes();
        assert!(
            content.windows(8).any(|w| w == peer),
            "the control: the sealed content blob names its peer"
        );
        assert!(
            !ledger.windows(8).any(|w| w == peer),
            "the document's peer id reached the ledger snapshot"
        );
    }

    #[test]
    fn the_ledger_snapshot_never_contains_page_ink() {
        const TOKEN: &str = "ghp_never-in-the-ledger";
        const DELETED: &str = "ghp_typed-then-deleted";
        let (mut store, _clock) = store();
        let id = store.new_tab().1;
        let chip = store.seal_text(id, TOKEN).unwrap();
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink(format!("# deploy notes\npasted {TOKEN} then {DELETED}\n")),
                Segment::Chip(chip),
            ],
        ));
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink(format!("# deploy notes\npasted {TOKEN} here\n")),
                Segment::Chip(chip),
            ],
        ));
        assert!(store.record_sent(chip, DestinationClass::OneTimeLink));

        let needle = TOKEN.as_bytes();
        let ghost = DELETED.as_bytes();
        let content = store.snapshot(0);
        assert!(content.windows(needle.len()).any(|w| w == needle));
        assert!(
            content.windows(ghost.len()).any(|w| w == ghost),
            "the control: deleted ink survives in the blob's history"
        );

        assert!(store.close_tab(slot(&store, id)));
        let ledger = store.ledger_snapshot();
        assert!(store.ledger().count() >= 4, "created, sealed, sent, died");
        assert!(
            !ledger.windows(needle.len()).any(|w| w == needle),
            "the ledger snapshot carried content out of the page"
        );
        assert!(
            !ledger.windows(ghost.len()).any(|w| w == ghost),
            "the ledger snapshot carried tombstoned content out of the page"
        );
        assert_eq!(store.ledger().next().unwrap().title(), "deploy notes");
    }

    #[test]
    fn time_away_drains_the_countdown() {
        let (mut store, clock) = store();
        let id = store.new_tab().1; // 8h default rung
        let snapshot = store.snapshot(0);

        let two_hours_ms = 2 * 60 * 60 * 1000;
        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, two_hours_ms).unwrap();

        let remaining = revived.sheet(id).unwrap().remaining(revived.now());
        assert_eq!(remaining, 6 * HOUR);
    }

    #[test]
    fn pages_due_while_away_expire_into_the_ledger_on_restore() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        assert!(store.sync_document(id, vec![Segment::Ink("perishable".into())]));
        let snapshot = store.snapshot(0);

        let nine_hours_ms = 9 * 60 * 60 * 1000;
        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, nine_hours_ms).unwrap();
        let expired = revived.expire_due();
        assert_eq!(expired, vec![id]);
        assert!(revived.holds_no_page());
        assert_eq!(revived.tabs().count(), 1);
        let record = revived.ledger().next().unwrap();
        assert_eq!(record.event(), LedgerEvent::Expired);
        assert_eq!(record.title(), "perishable");
    }

    #[test]
    fn a_hold_absorbs_time_away_before_the_countdown_drains() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        assert!(store.pause_press(slot(&store, id))); // 1h hold, 8h frozen
        let snapshot = store.snapshot(0);

        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 30 * 60 * 1000).unwrap();
        let now = revived.now();
        let sheet = revived.sheet(id).unwrap();
        assert!(sheet.is_held(now));
        assert_eq!(sheet.hold_remaining(now), Duration::from_secs(30 * 60));
        assert_eq!(sheet.remaining(now), 8 * HOUR);

        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 3 * 60 * 60 * 1000).unwrap();
        let now = revived.now();
        let sheet = revived.sheet(id).unwrap();
        assert!(!sheet.is_held(now));
        assert_eq!(sheet.remaining(now), 6 * HOUR);
    }

    #[test]
    fn a_snapshot_of_a_lapsed_hold_keeps_the_life_it_already_drained() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        clock.advance(2 * HOUR); // 6h left on the 8h rung
        assert!(store.pause_press(slot(&store, id))); // a 1h hold over 6h
        clock.advance(4 * HOUR); // the hold lapsed 3h ago, and 3h drained
        let left = store.sheet(id).unwrap().remaining(store.now());
        assert_eq!(left, 3 * HOUR, "the live reading is not the thing on trial");
        let snapshot = store.snapshot(0);

        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 0).unwrap();
        let now = revived.now();
        let sheet = revived.sheet(id).unwrap();
        assert!(!sheet.is_held(now), "a hold that lapsed came back live");
        assert_eq!(sheet.remaining(now), left, "the overhang was handed back");

        clock.advance(3 * HOUR);
        assert_eq!(
            store.sheet(id).unwrap().remaining(store.now()),
            Duration::ZERO
        );
        let snapshot = store.snapshot(0);
        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 0).unwrap();
        assert_eq!(
            revived.sheet(id).unwrap().remaining(revived.now()),
            Duration::ZERO
        );
        assert_eq!(revived.expire_due(), vec![id]);
        assert!(revived.holds_no_page());
    }

    #[test]
    fn a_restored_hold_remembers_which_press_comes_next() {
        let (mut store, clock) = store();
        let first = store.new_tab().1;
        let topped = store.new_tab().1;
        assert!(store.pause_press(slot(&store, first))); // 1h hold
        assert!(store.pause_press(slot(&store, topped))); // 1h hold
        assert!(store.pause_press(slot(&store, topped))); // topped up to 24h
        let snapshot = store.snapshot(0);

        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 30 * 60 * 1000).unwrap();
        let now = revived.now();
        assert!(revived.sheet(first).unwrap().is_held(now));
        assert!(!revived.sheet(first).unwrap().hold_topped_up(now));
        assert!(revived.sheet(topped).unwrap().hold_topped_up(now));

        assert!(revived.pause_press(slot(&revived, first)));
        assert!(revived.pause_press(slot(&revived, topped)));
        let now = revived.now();
        assert!(revived.sheet(first).unwrap().hold_topped_up(now));
        assert!(!revived.sheet(topped).unwrap().is_held(now));
    }

    #[test]
    fn a_backwards_wall_clock_grants_no_extra_life() {
        let (mut store, clock) = store();
        let id = store.new_tab().1;
        clock.advance(2 * HOUR); // 6h left on the 8h rung
        let snapshot = store.snapshot(1_000_000_000);

        let mut revived = store_on(clock.clone());
        revived.restore(&snapshot, 5).unwrap(); // wall clock moved back
        let remaining = revived.sheet(id).unwrap().remaining(revived.now());
        assert_eq!(remaining, 6 * HOUR);
    }

    #[test]
    fn no_restored_page_comes_back_holding_more_life_than_its_rung() {
        let doc = SheetDocument::new();
        doc.insert(0, "staged overnight").unwrap();
        doc.commit(None);
        let blob = doc.export_snapshot();
        let thirty_days_ms = 30 * 24 * 60 * 60 * 1000u64;

        let running = |remaining_ms: u64| {
            let mut clock = vec![0u8]; // running
            clock.extend_from_slice(&remaining_ms.to_le_bytes());
            clock
        };
        let on_rung = |rung_secs: u64, clock: &[u8]| {
            one_tab_snapshot(&tab_record_with_rung(
                None,
                rung_secs,
                Some(&page_record(clock, &blob)),
            ))
        };

        let (mut at_the_ceiling, _clock) = store();
        at_the_ceiling
            .restore(&on_rung(7 * 24 * 60 * 60, &running(thirty_days_ms)), 0)
            .unwrap();
        assert_eq!(
            at_the_ceiling
                .sheets()
                .next()
                .unwrap()
                .remaining(at_the_ceiling.now()),
            Ttl::MAX.longest_life(),
            "a file claiming a month of life was believed"
        );
        assert_eq!(
            Ttl::MAX.longest_life(),
            Duration::from_secs(8 * 24 * 60 * 60)
        );

        let (mut on_the_hour, _clock) = store();
        on_the_hour
            .restore(&on_rung(60 * 60, &running(thirty_days_ms)), 0)
            .unwrap();
        assert_eq!(
            on_the_hour
                .sheets()
                .next()
                .unwrap()
                .remaining(on_the_hour.now()),
            2 * HOUR,
            "an hour's page came back with more than its longest life"
        );
    }

    #[test]
    fn no_restored_hold_freezes_more_life_than_its_rung() {
        let doc = SheetDocument::new();
        doc.insert(0, "paused overnight").unwrap();
        doc.commit(None);
        let blob = doc.export_snapshot();

        let mut clock = vec![1u8]; // a first hold
        clock.extend_from_slice(&(10 * 60 * 1000u64).to_le_bytes()); // 10m of hold
        clock.extend_from_slice(&(30 * 24 * 60 * 60 * 1000u64).to_le_bytes()); // frozen: a month
        let snapshot = one_tab_snapshot(&tab_record_with_rung(
            None,
            60 * 60,
            Some(&page_record(&clock, &blob)),
        ));

        let (mut store, _clock) = store();
        store.restore(&snapshot, 0).unwrap();
        let now = store.now();
        let sheet = store.sheets().next().unwrap();
        assert!(sheet.is_held(now), "the hold itself did not survive");
        assert_eq!(
            sheet.remaining(now),
            2 * HOUR,
            "a hold froze more life than the rung ever held"
        );
    }

    #[test]
    fn no_restored_hold_outlasts_the_ceiling_the_pause_gesture_sets() {
        let doc = SheetDocument::new();
        doc.insert(0, "paused for a month").unwrap();
        doc.commit(None);
        let blob = doc.export_snapshot();
        let a_month_ms = 30 * 24 * 60 * 60 * 1000u64;

        let held = |tag: u8, hold_ms: u64, frozen_ms: u64| {
            let mut clock = vec![tag];
            clock.extend_from_slice(&hold_ms.to_le_bytes());
            clock.extend_from_slice(&frozen_ms.to_le_bytes());
            one_tab_snapshot(&tab_record_with_rung(
                None,
                60 * 60,
                Some(&page_record(&clock, &blob)),
            ))
        };

        let (mut first_hold, clock) = store();
        first_hold
            .restore(&held(1, a_month_ms, a_month_ms), 0)
            .unwrap();
        assert_eq!(
            first_hold
                .sheets()
                .next()
                .unwrap()
                .hold_remaining(first_hold.now()),
            HOLD_FIRST,
            "a file claiming a month of hold was believed"
        );
        clock.advance(HOLD_FIRST);
        assert!(
            !first_hold
                .sheets()
                .next()
                .unwrap()
                .is_held(first_hold.now()),
            "the hold outlasted the ceiling the pause gesture sets"
        );
        assert!(
            first_hold.expire_due().is_empty(),
            "the frozen hour was skipped"
        );
        clock.advance(2 * HOUR);
        assert_eq!(
            first_hold.expire_due().len(),
            1,
            "a page held out of a file never became due"
        );
        assert_eq!(
            first_hold.sheets().count(),
            0,
            "the plaintext outlived the rung"
        );

        let (mut topped_up, _clock) = store();
        topped_up
            .restore(&held(2, a_month_ms, a_month_ms), 0)
            .unwrap();
        assert_eq!(
            topped_up
                .sheets()
                .next()
                .unwrap()
                .hold_remaining(topped_up.now()),
            HOLD_TOPUP,
            "a topped-up hold was not read against the top-up ceiling"
        );
    }

    #[test]
    fn superseded_and_unknown_magics_all_refuse_as_unknown_format() {
        let (original, _clock, ..) = populated();
        let (mut revived, survivor) = occupied();
        for magic in [
            b"OTSSNAP1",
            b"OTSSNAP2",
            b"OTSSNAP3",
            b"OTSSNAP6",
            b"OTSSNAP9",
            b"NOTSNAPS",
        ] {
            let mut relabeled = original.snapshot(0).to_vec();
            relabeled[..8].copy_from_slice(magic.as_slice());
            assert_eq!(
                revived.restore(&relabeled, 0),
                Err(RestoreError::UnknownFormat),
                "magic {magic:?} did not refuse as unknown"
            );
            let ids: Vec<SheetId> = revived.sheets().map(Sheet::id).collect();
            assert_eq!(ids, vec![survivor], "the refused restore touched the store");
        }

        let before: Vec<LedgerRecord> = revived.ledger().cloned().collect();
        let mut relabeled = original.ledger_snapshot().to_vec();
        relabeled[..8].copy_from_slice(b"OTSLEDR0");
        assert_eq!(
            revived.restore_ledger(&relabeled, 0),
            Err(RestoreError::UnknownFormat),
            "an unknown ledger magic did not refuse as unknown"
        );
        let after: Vec<LedgerRecord> = revived.ledger().cloned().collect();
        assert_eq!(before, after, "the refused restore touched the ledger");
    }

    #[test]
    fn a_superseded_ledger_magic_refuses_as_superseded_with_the_ledger_untouched() {
        let (original, _clock, ..) = populated();
        let (mut revived, _survivor) = occupied();
        assert_eq!(SUPERSEDED_LEDGER_MAGICS, [b"OTSLEDR1"]);
        let before: Vec<LedgerRecord> = revived.ledger().cloned().collect();
        for magic in SUPERSEDED_LEDGER_MAGICS {
            let mut relabeled = original.ledger_snapshot().to_vec();
            relabeled[..8].copy_from_slice(magic.as_slice());
            assert_eq!(
                revived.restore_ledger(&relabeled, 0),
                Err(RestoreError::Superseded),
                "ledger magic {magic:?} did not refuse as superseded"
            );
            let after: Vec<LedgerRecord> = revived.ledger().cloned().collect();
            assert_eq!(before, after, "the refused restore touched the ledger");
        }
    }

    #[test]
    fn wrong_magic_is_unknown_format_and_damage_is_malformed() {
        let (original, clock, ..) = populated();
        let snapshot = original.snapshot(0);

        let mut revived = store_on(clock.clone());
        assert_eq!(
            revived.restore(b"not a snapshot at all", 0),
            Err(RestoreError::UnknownFormat)
        );

        let mut padded = snapshot.to_vec();
        padded.push(0);
        assert_eq!(revived.restore(&padded, 0), Err(RestoreError::Malformed));

        assert!(
            revived.has_no_tabs(),
            "a failed restore must leave nothing behind"
        );
        assert_eq!(revived.ledger().count(), 0);

        assert_eq!(revived.restore(&snapshot, 0).unwrap(), 2);
    }

    #[test]
    fn truncation_at_every_offset_rejects_without_panicking() {
        let (original, clock, ..) = populated();
        let snapshot = original.snapshot(7_000);
        let ledger = original.ledger_snapshot();

        let mut revived = store_on(clock.clone());
        for cut in 0..snapshot.len() {
            assert!(
                revived.restore(&snapshot[..cut], 7_000).is_err(),
                "a snapshot truncated at {cut} must not restore"
            );
            assert!(
                revived.has_no_tabs(),
                "a rejected restore left a strip behind"
            );
        }
        for cut in 0..ledger.len() {
            assert!(
                revived.restore_ledger(&ledger[..cut], 7_000).is_err(),
                "a ledger truncated at {cut} must not restore"
            );
            assert_eq!(revived.ledger().count(), 0);
        }

        assert_eq!(revived.restore(&snapshot, 7_000).unwrap(), 2);
        assert!(revived.restore_ledger(&ledger, 7_000).unwrap() > 0);
    }

    #[test]
    fn a_hostile_length_is_rejected_before_it_allocates() {
        let (_, clock, ..) = populated();
        let mut revived = store_on(clock.clone());

        let mut hostile = Vec::new();
        hostile.extend_from_slice(MAGIC);
        hostile.extend_from_slice(&0u64.to_le_bytes());
        hostile.extend_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(revived.restore(&hostile, 0), Err(RestoreError::Malformed));

        let mut hostile_ledger = Vec::new();
        hostile_ledger.extend_from_slice(LEDGER_MAGIC);
        hostile_ledger.extend_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(
            revived.restore_ledger(&hostile_ledger, 0),
            Err(RestoreError::Malformed)
        );

        let mut hostile_frame = Vec::new();
        hostile_frame.extend_from_slice(MAGIC);
        hostile_frame.extend_from_slice(&0u64.to_le_bytes());
        hostile_frame.extend_from_slice(&1u64.to_le_bytes());
        hostile_frame.extend_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(
            revived.restore(&hostile_frame, 0),
            Err(RestoreError::Malformed)
        );

        let mut inner = Vec::new();
        inner.extend_from_slice(ItemId::random().as_bytes());
        inner.extend_from_slice(&0u64.to_le_bytes()); // created_wall_ms
        inner.push(0); // no name
        inner.extend_from_slice(&(8 * 60 * 60u64).to_le_bytes()); // 8h rung
        inner.push(1); // a page follows
        inner.extend_from_slice(&u64::MAX.to_le_bytes()); // its claimed length
        assert_eq!(
            revived.restore(&one_tab_snapshot(&inner), 0),
            Err(RestoreError::Malformed)
        );

        let mut tab = Vec::new();
        tab.extend_from_slice(ItemId::random().as_bytes());
        tab.extend_from_slice(&0u64.to_le_bytes()); // created_wall_ms
        tab.push(1); // a name follows
        tab.extend_from_slice(&u64::MAX.to_le_bytes()); // its claimed length
        assert_eq!(
            revived.restore(&one_tab_snapshot(&tab), 0),
            Err(RestoreError::Malformed)
        );

        let mut hostile_blob = sheet_snapshot(&[], b"");
        let len = hostile_blob.len();
        hostile_blob[len - 16..len - 8].copy_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(
            revived.restore(&hostile_blob, 0),
            Err(RestoreError::Malformed)
        );

        let mut hostile_metadata = sheet_snapshot(&[], b"");
        let len = hostile_metadata.len();
        hostile_metadata[len - 8..].copy_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(
            revived.restore(&hostile_metadata, 0),
            Err(RestoreError::Malformed)
        );
        assert!(revived.has_no_tabs());
    }

    #[test]
    fn snapshot_size_is_exact() {
        let (original, ..) = populated();
        let snapshot = original.snapshot(123);
        assert_eq!(
            snapshot.capacity(),
            snapshot.len(),
            "the exact-size preallocation must not grow (a grow strands sealed bytes)"
        );
        let ledger = original.ledger_snapshot();
        assert_eq!(
            ledger.capacity(),
            ledger.len(),
            "the ledger preallocation must not grow either"
        );
    }

    #[test]
    fn the_block_section_is_written_at_its_exact_size() {
        use crate::store::EditOp;
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let page = store.tabs[0].page.as_ref().unwrap();
        assert!(encode_materialized(&page.blocks, &page.document).is_empty());

        assert!(store.apply_ops(
            id,
            &[
                EditOp::Insert {
                    pos_u16: 0,
                    text: "first\u{1F600}\n".into()
                },
                EditOp::Insert {
                    pos_u16: 8,
                    text: "second".into()
                }
            ]
        ));
        store.cycle_rung(slot(&store, id)).unwrap();
        let page = store.tabs[0].page.as_ref().unwrap();
        let section = encode_materialized(&page.blocks, &page.document);
        assert!(
            !section.is_empty(),
            "the control: the ceremony froze both blocks"
        );
        assert_eq!(section.capacity(), section.len());
    }

    #[test]
    fn a_record_with_no_value_round_trips_as_one() {
        use crate::document::EditIntent;
        use crate::store::EditOp;
        let (mut original, clock) = store();
        let id = original.new_tab().1;
        let ink = [EditOp::Insert {
            pos_u16: 0,
            text: "ink".into(),
        }];
        assert!(original.apply_ops(id, &ink));
        let local = original.seal_text_at(id, "ghp_sealed-here", 3, 0).unwrap();
        let peer = original.stand_peer_record(id, 0, Some(PeerKind::Text), Some(SizeClass::Small));
        original.set_chip_name(peer, "PEER_KEY").unwrap();
        assert!(original.apply_note_ops(peer, &ink, EditIntent::Paste, None));
        let gone = original.stand_peer_record(id, 0, None, None);
        let take_out = [EditOp::Delete {
            pos_u16: 0,
            len_u16: 1,
        }];
        assert!(original.apply_ops(id, &take_out));
        let sheet = original.sheet(id).unwrap();
        let uuid_of = |chip| sheet.owned_chip(chip).unwrap().uuid();
        let (local, peer, gone) = (uuid_of(local), uuid_of(peer), uuid_of(gone));
        let snapshot = original.snapshot(1_000);

        let mut revived = store_on(clock.clone());
        assert_eq!(revived.restore(&snapshot, 1_000), Ok(1));
        let sheet = revived.sheets().next().unwrap();
        let standing: Vec<ItemId> = sheet.chips().map(SealedChip::uuid).collect();
        assert_eq!(standing, vec![local, peer]);
        let record = sheet.chips().find(|chip| chip.uuid() == peer).unwrap();
        assert!(matches!(
            record.availability(),
            Availability::Peer {
                kind: Some(PeerKind::Text),
                size: Some(SizeClass::Small)
            }
        ));
        assert_eq!(record.name(), Some("PEER_KEY"));
        assert_eq!(&**revived.note_text(record.id()).unwrap(), "ink");
        assert!(revived.copy_out_chip(record.id()).is_none());
        let detached: Vec<&SealedChip> = sheet.detached().collect();
        assert_eq!(detached.len(), 1);
        assert_eq!(detached[0].uuid(), gone);
        assert!(matches!(
            detached[0].availability(),
            Availability::Peer {
                kind: None,
                size: None
            }
        ));
        let value = sheet.chips().find(|chip| chip.uuid() == local).unwrap();
        assert_eq!(
            &*revived.copy_out_chip(value.id()).unwrap().0,
            b"ghp_sealed-here"
        );
        assert_eq!(*revived.snapshot(1_000), *snapshot, "written back as read");
    }

    /// One chip record with its value, as `OTSSNAP4` wrote it or behind
    /// the tag `OTSSNAP5` puts first.
    fn value_record(
        tagged: bool,
        uuid: ItemId,
        kind: u8,
        receipt: Option<&str>,
        payload: &[u8],
        fields: [Option<&str>; 2],
    ) -> Vec<u8> {
        let mut chip = uuid.as_bytes().to_vec();
        if tagged {
            chip.push(0);
        }
        chip.push(kind);
        chip.extend(receipt.map_or_else(|| vec![0], text_field));
        chip.extend_from_slice(&(payload.len() as u64).to_le_bytes());
        chip.extend_from_slice(payload);
        for field in fields {
            chip.extend(field.map_or_else(|| vec![0], text_field));
        }
        chip
    }

    /// A one tab snapshot under `magic` whose page stands `standing` over
    /// `blob` and keeps `detached`.
    fn snapshot_of(
        magic: &[u8; 8],
        ids: (ItemId, ItemId),
        standing: &[Vec<u8>],
        blob: &[u8],
        detached: &[Vec<u8>],
    ) -> Vec<u8> {
        let mut page = ids.1.as_bytes().to_vec();
        page.extend_from_slice(&0u64.to_le_bytes()); // created_wall_ms
        page.push(0); // running
        page.extend_from_slice(&60_000u64.to_le_bytes()); // remaining ms
        page.extend_from_slice(&0u64.to_le_bytes()); // total_held
        page.extend_from_slice(&(standing.len() as u64).to_le_bytes());
        for record in standing {
            page.extend_from_slice(&frame(record));
        }
        page.extend_from_slice(&(blob.len() as u64).to_le_bytes());
        page.extend_from_slice(blob);
        page.extend_from_slice(&0u64.to_le_bytes()); // empty metadata slot
        page.push(0); // no page floor
        page.extend_from_slice(&(detached.len() as u64).to_le_bytes());
        for record in detached {
            page.extend_from_slice(&frame(record));
        }
        page.push(0); // no cut
        let mut tab = ids.0.as_bytes().to_vec();
        tab.extend_from_slice(&0u64.to_le_bytes()); // created_wall_ms
        tab.push(0); // unnamed
        tab.extend_from_slice(&(8u64 * 60 * 60).to_le_bytes());
        tab.push(1);
        tab.extend_from_slice(&frame(&page));
        let mut out = magic.to_vec();
        out.extend_from_slice(&0u64.to_le_bytes()); // saved wall stamp
        out.extend_from_slice(&1u64.to_le_bytes()); // one tab
        out.extend_from_slice(&frame(&tab));
        out
    }

    #[test]
    fn a_v4_snapshot_restores_as_it_did() {
        let ids = (ItemId::random(), ItemId::random());
        let (text, image) = (ItemId::random(), ItemId::random());
        let blob = one_chip_document(text);
        let png = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];
        let fixture = |magic, tagged| {
            snapshot_of(
                magic,
                ids,
                &[value_record(
                    tagged,
                    text,
                    0,
                    Some("receipt-v4"),
                    b"ghp_written-by-v4",
                    [Some("API_KEY"), Some("rotate monthly")],
                )],
                &blob,
                &[value_record(tagged, image, 1, None, &png, [None, None])],
            )
        };

        let (mut old, _) = store();
        assert_eq!(old.restore(&fixture(MAGIC_V4, false), 0), Ok(1));
        let sheet = old.sheets().next().unwrap();
        let chip = sheet.chips().next().unwrap();
        assert_eq!(chip.uuid(), text);
        assert!(chip.is_local());
        assert_eq!(chip.conceal().unwrap().receipt_id, "receipt-v4");
        assert_eq!(chip.name(), Some("API_KEY"));
        assert_eq!(&**old.note_text(chip.id()).unwrap(), "rotate monthly");
        assert_eq!(
            &*old.copy_out_chip(chip.id()).unwrap().0,
            b"ghp_written-by-v4"
        );
        let kept = sheet.detached().next().unwrap();
        assert_eq!((kept.uuid(), kept.excerpt()), (image, "PNG image"));
        assert_eq!(kept.local().unwrap().bytes.expose(), &png[..]);

        let (mut new, _) = store();
        assert_eq!(new.restore(&fixture(MAGIC, true), 0), Ok(1));
        assert_eq!(*old.snapshot(0), *new.snapshot(0), "one store from both");
        assert_eq!(
            &old.snapshot(0)[..8],
            MAGIC,
            "written back as the new version"
        );
    }

    /// A record with no value: its availability tag, kind and size class, no name, no note.
    fn peer_record(uuid: ItemId, tag: u8, kind: u8, size: u8) -> Vec<u8> {
        let mut chip = uuid.as_bytes().to_vec();
        chip.extend_from_slice(&[tag, kind, size, 0, 0]);
        chip
    }

    #[test]
    fn a_damaged_availability_record_refuses_the_whole_restore_and_leaves_the_store_untouched() {
        let uuid = ItemId::random();
        let blob = one_chip_document(uuid);
        let snapshot = |record: Vec<u8>, blob: &[u8]| {
            snapshot_of(
                MAGIC,
                (ItemId::random(), ItemId::random()),
                &[record],
                blob,
                &[],
            )
        };
        let (mut control, _) = store();
        assert_eq!(
            control.restore(&snapshot(peer_record(uuid, 1, 2, 5), &blob), 0),
            Ok(1),
            "the control: the layout is sound"
        );
        let chip = control.sheets().next().unwrap().chips().next().unwrap();
        assert!(matches!(
            chip.availability(),
            Availability::Peer {
                kind: Some(PeerKind::Image),
                size: Some(SizeClass::Huge)
            }
        ));

        let elsewhere = one_chip_document(ItemId::random());
        for (record, blob) in [
            (peer_record(uuid, 2, 1, 1), &blob[..]),
            (peer_record(uuid, u8::MAX, 0, 0), &blob[..]),
            (peer_record(uuid, 1, 3, 0), &blob[..]),
            (peer_record(uuid, 1, 0, 6), &blob[..]),
            // A record with no value still answers to exactly one mark.
            (peer_record(uuid, 1, 0, 0), &elsewhere[..]),
        ] {
            let (mut revived, survivor) = occupied();
            assert_eq!(
                revived.restore(&snapshot(record, blob), 0),
                Err(RestoreError::Malformed)
            );
            let ids: Vec<SheetId> = revived.sheets().map(Sheet::id).collect();
            assert_eq!(ids, vec![survivor], "the refused restore touched the store");
        }
    }
}
