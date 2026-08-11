//! Explicit persistence: the store's live content as one plaintext
//! snapshot buffer, and the ledger as a second, independent one, for the
//! seam above to encrypt and keep across launches.
//!
//! Rev C's founding law read "memory-only; exit is total amnesia".
//! Lived experience overruled the absolutism the same way it did for
//! the [`ledger`](crate::ledger): a companion that opens empty every
//! morning surprises the person who parked pages in it the night
//! before. The amendment stays narrow:
//!
//! - **Explicit.** Nothing here runs on its own. The shell asks for a
//!   [`SheetStore::snapshot`] on its own debounced write path and hands
//!   it back to [`SheetStore::restore`] at launch. This module starts no
//!   timer and keeps no shadow copy. Retention is explicit for the same
//!   reason: no timer sweeps the ledger, so the write path evicts
//!   ([`SheetStore::evict_ledger`]) before it snapshots, and the load
//!   path evicts as it reads.
//! - **Two snapshots, two lifetimes.** Content and ledger are separate
//!   buffers with separate magics, so the shell can seal them to
//!   separate files under separate keys: the content under the
//!   boot-bound key that dies with the machine's uptime, the ledger
//!   under a long-lived one, because a record of what happened is meant
//!   to outlive the thing it happened to (ADR-0012).
//! - **Never plaintext at rest.** Both buffers are *plaintext* and are
//!   only ever handed out in [`Zeroizing`]. The FFI seam encrypts before
//!   anything touches disk (`ChaCha20-Poly1305`, key in the OS keychain)
//!   and the plaintext wipes on drop either side. The ledger buffer
//!   holds no sealed bytes, but it does hold titles, and a title is
//!   derived from content: the single documented exception, treated here
//!   as content.
//! - **The clock keeps its promise.** Wall time that passed while the
//!   app was closed drains every countdown exactly as if it had been
//!   open; pages due by restore time expire into the ledger on the
//!   caller's next [`SheetStore::expire_due`].
//! - **No counter is ever written down.** [`SheetId`] and [`ChipId`] are
//!   in-process ordering handles, nothing more. The snapshot carries the
//!   random [`ItemId`] instead, and restore re-mints the counters densely
//!   in read order. That is safe precisely because a restore only ever
//!   runs before the shell has read anything out of the store, so no id
//!   has escaped to be reused.
//!
//! The format is a versioned, length-prefixed binary layout, written
//! into one exact-size buffer: growing a buffer reallocates, and
//! reallocation strands sealed bytes in freed, unwiped heap (the same
//! discipline as [`SheetStore::sheet_payload`]). A chip's mechanical
//! face (excerpt, size label, meta) is deliberately *not* stored — it
//! is recomputed from the bytes by the same functions that built it,
//! so the snapshot cannot smuggle a divergent rendering back in. Every
//! length read is bounds-checked against the bytes actually remaining,
//! so a truncated or hostile buffer errors instead of panicking or
//! allocating on a number it chose.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::blocks::{BlockIndex, MaterializedMeta, PersistedBlock};
use crate::clock::Clock;
use crate::document::{DocRun, SheetDocument};
use crate::ledger::{DestinationClass, LedgerEvent, LedgerRecord, SizeClass, evict_expired};
use crate::sheet::{
    ChipId, ChipMeta, ItemId, Promotion, SealedChip, Segment, Sheet, SheetClock, SheetId, TITLE_CAP,
};
use crate::store::SheetStore;
use crate::ttl::Ttl;

/// Magic + version prefix of a plaintext content snapshot. A format
/// change gets a new final byte; old builds refuse rather than misread.
/// `3` replaces the segments section with the sheet's full Loro
/// document blob (ADR-0013). There is no v2 reader and no downgrade
/// writer: v1 and v2 files refuse as unknown, deliberately.
const MAGIC: &[u8; 8] = b"OTSSNAP3";

/// Magic + version prefix of a plaintext ledger snapshot. Separate from
/// [`MAGIC`] so the two files can never be mistaken for each other.
const LEDGER_MAGIC: &[u8; 8] = b"OTSLEDR1";

/// Ceiling on any span read back from a snapshot (30 days — well past
/// the 7-day rung and the 24-hour hold). Keeps `Instant` arithmetic
/// safely away from overflow no matter what the buffer claims.
const MAX_SPAN_MS: u64 = 30 * 24 * 60 * 60 * 1000;

/// Slack above the wall clock allowed for a materialized stamp before
/// the clamp takes it: the document's recorder rounds to the nearest
/// second while the wall reading truncates, so an honest stamp can sit
/// one second ahead of the clock that judges it.
const STAMP_SLACK_S: i64 = 2;

/// Why a snapshot could not be restored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestoreError {
    /// Not a snapshot, or a version this build does not read.
    UnknownFormat,
    /// The layout is damaged: truncated, trailing bytes, invalid UTF-8,
    /// an off-ladder rung, a document blob that does not import, or a
    /// chip roster the document's marks do not match one to one. The
    /// store is left exactly as it was.
    Malformed,
}

impl std::fmt::Display for RestoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RestoreError::UnknownFormat => f.write_str("not a snapshot this build can read"),
            RestoreError::Malformed => f.write_str("snapshot is damaged"),
        }
    }
}

impl std::error::Error for RestoreError {}

impl<C: Clock> SheetStore<C> {
    /// Serialize the store's content, meaning sheets, chips (bytes
    /// included), titles and clocks, into one plaintext buffer, stamped
    /// with `wall_ms` (Unix epoch milliseconds at save) so restore can
    /// account for time away. The ledger is *not* here; it has its own
    /// snapshot, [`SheetStore::ledger_snapshot`]. The buffer wipes on
    /// drop; the caller encrypts it and lets it fall.
    #[must_use]
    pub fn snapshot(&self, wall_ms: u64) -> Zeroizing<Vec<u8>> {
        let now = self.clock.now();
        // Each document is exported exactly once, into a zeroizing
        // buffer both passes copy from. The sizing pass must never
        // trigger a second export: two exports could disagree in length
        // and the write would grow the buffer, stranding sealed bytes
        // in freed, unwiped heap.
        let blobs: Vec<Zeroizing<Vec<u8>>> = self
            .sheets
            .iter()
            .map(|sheet| sheet.document.export_snapshot())
            .collect();
        // The materialized sections are encoded once too, and zeroizing
        // for the same reason as the blobs: a frozen origin is content.
        let metas: Vec<Zeroizing<Vec<u8>>> = self
            .sheets
            .iter()
            .map(|sheet| encode_materialized(&sheet.blocks, &sheet.document))
            .collect();
        let mut sizer = Sizer(0);
        emit(self, &blobs, &metas, now, wall_ms, &mut sizer);
        let mut buffer = Zeroizing::new(Vec::with_capacity(sizer.0));
        emit(self, &blobs, &metas, now, wall_ms, &mut Writer(&mut buffer));
        debug_assert_eq!(buffer.len(), sizer.0, "sizing pass drifted from the write");
        buffer
    }

    /// Replace this store's sheets with a snapshot's, draining every
    /// countdown by the wall time that passed since it was taken
    /// (`wall_ms` is Unix epoch milliseconds now). Meant for startup,
    /// before the store has issued anything: the sequential ids are
    /// re-minted densely from 1 in read order, which is only sound
    /// because nothing has yet read an id out of this store. Page and
    /// chip identity across the relaunch is carried by the stored
    /// [`ItemId`], not by the counter.
    ///
    /// The ledger is untouched: restore it separately with
    /// [`SheetStore::restore_ledger`]. On error the store is untouched.
    /// Pages already due are *kept*: call [`SheetStore::expire_due`]
    /// right after to entomb them, so they leave ledger residue like any
    /// other death.
    ///
    /// Returns the number of live pages restored.
    ///
    /// # Errors
    ///
    /// [`RestoreError::UnknownFormat`] for a buffer that is not a
    /// snapshot this build reads; [`RestoreError::Malformed`] for one
    /// that is damaged.
    pub fn restore(&mut self, bytes: &[u8], wall_ms: u64) -> Result<usize, RestoreError> {
        let mut reader = Reader { buf: bytes, pos: 0 };
        if reader.raw(MAGIC.len()) != Some(MAGIC.as_slice()) {
            return Err(RestoreError::UnknownFormat);
        }
        let saved_wall = reader.u64().ok_or(RestoreError::Malformed)?;
        // A wall clock that moved backwards while away reads as no time
        // passed — the countdown never gains life from clock skew.
        let away = span(wall_ms.saturating_sub(saved_wall));
        let now = self.clock.now();

        let sheet_count = count(&mut reader)?;
        let mut sheets = Vec::new();
        let mut next_sheet_id = 1;
        let mut next_chip_id = 1;
        for _ in 0..sheet_count {
            sheets.push(read_sheet(
                &mut reader,
                now,
                away,
                wall_ms,
                &mut next_sheet_id,
                &mut next_chip_id,
            )?);
        }
        if !reader.done() {
            return Err(RestoreError::Malformed);
        }

        let restored = sheets.len();
        self.sheets = sheets;
        self.next_sheet_id = next_sheet_id;
        self.next_chip_id = next_chip_id;
        Ok(restored)
    }

    /// Serialize the ledger into its own plaintext buffer. Records carry
    /// absolute wall-clock time, not an age relative to any `Instant`,
    /// because a ledger outlives the reboot that makes an `Instant`
    /// meaningless. No sealed bytes are written; the titles are, and are
    /// treated as content.
    ///
    /// This is a `&self` read and evicts nothing: it writes down exactly
    /// the records the store is holding. The retention window is only a
    /// real bound on the write path if the caller sweeps first, so the
    /// seam above calls [`SheetStore::evict_ledger`] with the current
    /// wall time immediately before this, in the same critical section.
    /// Skip that and a session that never appends a record re-persists
    /// titles past 90 days under the long-lived key (ADR-0012).
    #[must_use]
    pub fn ledger_snapshot(&self) -> Zeroizing<Vec<u8>> {
        let mut sizer = Sizer(0);
        emit_ledger(self, &mut sizer);
        let mut buffer = Zeroizing::new(Vec::with_capacity(sizer.0));
        emit_ledger(self, &mut Writer(&mut buffer));
        debug_assert_eq!(buffer.len(), sizer.0, "sizing pass drifted from the write");
        buffer
    }

    /// Replace this store's ledger with a ledger snapshot's, dropping
    /// records that have aged out of the retention window by `wall_ms`
    /// (Unix epoch milliseconds now). Sheets are untouched. On error the
    /// store is untouched.
    ///
    /// Returns the number of records kept.
    ///
    /// # Errors
    ///
    /// [`RestoreError::UnknownFormat`] for a buffer that is not a ledger
    /// snapshot this build reads; [`RestoreError::Malformed`] for one
    /// that is damaged.
    pub fn restore_ledger(&mut self, bytes: &[u8], wall_ms: u64) -> Result<usize, RestoreError> {
        let mut reader = Reader { buf: bytes, pos: 0 };
        if reader.raw(LEDGER_MAGIC.len()) != Some(LEDGER_MAGIC.as_slice()) {
            return Err(RestoreError::UnknownFormat);
        }
        let record_count = count(&mut reader)?;
        let mut ledger = VecDeque::new();
        for _ in 0..record_count {
            ledger.push_back(read_record(&mut reader)?);
        }
        if !reader.done() {
            return Err(RestoreError::Malformed);
        }
        // Retention runs on load, where the ledger is already in hand: a
        // record sitting in a closed file is inert until someone reads it.
        evict_expired(&mut ledger, wall_ms);
        let restored = ledger.len();
        self.ledger = ledger;
        Ok(restored)
    }
}

// ---------------------------------------------------------------------------
// Encoding — one walk, two sinks (a sizing pass, then the write), so the
// exact-size preallocation cannot drift from what is written.
// ---------------------------------------------------------------------------

trait Sink {
    fn raw(&mut self, bytes: &[u8]);
    fn u8(&mut self, value: u8);
    fn u64(&mut self, value: u64);
    /// Length-prefixed bytes.
    fn bytes(&mut self, value: &[u8]);
}

struct Sizer(usize);

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

struct Writer<'a>(&'a mut Vec<u8>);

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

fn emit<C: Clock>(
    store: &SheetStore<C>,
    blobs: &[Zeroizing<Vec<u8>>],
    metas: &[Zeroizing<Vec<u8>>],
    now: Instant,
    wall_ms: u64,
    out: &mut impl Sink,
) {
    out.raw(MAGIC);
    out.u64(wall_ms);
    out.u64(store.sheets.len() as u64);
    for ((sheet, blob), meta) in store.sheets.iter().zip(blobs).zip(metas) {
        // Identity, not the in-process counter (ADR-0012).
        out.raw(sheet.uuid.as_bytes());
        out.u64(sheet.created_wall_ms);
        out.bytes(sheet.title.as_bytes());
        out.u8(u8::from(sheet.title_is_user_set));
        out.u64(sheet.rung.duration().as_secs());
        match sheet.clock {
            SheetClock::Running { deadline } => {
                out.u8(0);
                out.u64(ms(deadline.saturating_duration_since(now)));
            }
            SheetClock::Held {
                until,
                frozen_remaining,
                ..
            } => {
                out.u8(1);
                out.u64(ms(until.saturating_duration_since(now)));
                out.u64(ms(frozen_remaining));
            }
        }
        // total_held(now) folds a live hold's span in; restore restarts
        // the live hold's accounting from its own `now`.
        out.u64(ms(sheet.total_held(now)));
        // Chips before the document blob, so the reader has every chip
        // identity in hand before a mark asks it to resolve one.
        out.u64(sheet.chips.len() as u64);
        for chip in &sheet.chips {
            out.raw(chip.uuid.as_bytes());
            out.u8(match chip.meta {
                ChipMeta::Text { .. } => 0,
                ChipMeta::Image { .. } => 1,
            });
            match &chip.promotion {
                None => out.u8(0),
                Some(promotion) => {
                    out.u8(1);
                    out.bytes(promotion.receipt_id.as_bytes());
                }
            }
            out.bytes(chip.bytes.expose());
        }
        // The whole document, history included: the projection is not
        // written because the document is its source of truth, and a
        // snapshot that carried both could smuggle a divergent
        // projection back in.
        out.bytes(blob.as_slice());
        // The materialized-metadata section, filled by the compaction
        // ceremony (ADR-0013): each block that carries a frozen summary
        // writes its identity, its anchor, its stamps, and its origin.
        // The slot was reserved in stage 4, so a compacted file differs
        // from an uncompacted one only by this section's contents.
        out.bytes(meta.as_slice());
    }
}

/// Encode a sheet's block section into its own buffer, sized exactly
/// the same way as the outer snapshot: growing a buffer reallocates,
/// and a frozen origin is content that must not strand in unwiped heap.
/// The section carries the materialized summaries the compaction
/// ceremony froze, and after them the block grouping, so a pasted
/// passage comes back as the one block it was written as rather than
/// scattering into a line per paragraph. A sheet with nothing frozen
/// and nothing grouped encodes to the empty slice, byte for byte the
/// slot stage 4 wrote.
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

fn emit_materialized(blocks: &BlockIndex, spans: &[usize], grouped: bool, out: &mut impl Sink) {
    let frozen: Vec<_> = blocks
        .records()
        .iter()
        .filter_map(|record| record.materialized.as_ref().map(|meta| (record, meta)))
        .collect();
    out.u64(frozen.len() as u64);
    for (record, meta) in frozen {
        // The block's identity, then the anchor that must still resolve
        // for the record to be believed on the way back in.
        out.raw(record.id.as_bytes());
        out.bytes(&record.anchor);
        // Stamps are positive by construction (derivation skips the
        // epoch-stamped rebuild), so the sign bit never survives the
        // round trip through u64.
        out.u64(meta.created_s.max(0) as u64);
        out.u64(meta.modified_s.max(0) as u64);
        match &meta.origin {
            None => out.u8(0),
            Some(origin) => {
                out.u8(1);
                out.bytes(origin.as_bytes());
            }
        }
    }
    // The grouping, written only when there is grouping to write: a
    // page whose blocks are its paragraphs one for one restores the
    // same either way, and a file that says nothing here is exactly
    // what every build before this one wrote.
    if grouped {
        out.u64(spans.len() as u64);
        for span in spans {
            out.u64(*span as u64);
        }
    }
}

fn emit_ledger<C: Clock>(store: &SheetStore<C>, out: &mut impl Sink) {
    out.raw(LEDGER_MAGIC);
    out.u64(store.ledger.len() as u64);
    for record in &store.ledger {
        out.u8(match record.event {
            LedgerEvent::Created => 0,
            LedgerEvent::Sealed => 1,
            LedgerEvent::Sent => 2,
            LedgerEvent::Expired => 3,
            LedgerEvent::Discarded => 4,
        });
        out.raw(record.item.as_bytes());
        out.bytes(record.title.as_bytes());
        // Wall-clock, not an age relative to some `now`: a record
        // outlives the reboot that makes an `Instant` meaningless.
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
        });
    }
}

fn ms(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

// ---------------------------------------------------------------------------
// Decoding — bounds-checked throughout; any damage rejects the whole
// snapshot before the store is touched.
// ---------------------------------------------------------------------------

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn raw(&mut self, len: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(len)?;
        if end > self.buf.len() {
            return None;
        }
        let slice = &self.buf[self.pos..end];
        self.pos = end;
        Some(slice)
    }

    fn u8(&mut self) -> Option<u8> {
        self.raw(1).map(|s| s[0])
    }

    fn u64(&mut self) -> Option<u64> {
        self.raw(8)
            .map(|s| u64::from_le_bytes(s.try_into().expect("raw(8) is 8 bytes")))
    }

    fn bytes(&mut self) -> Option<&'a [u8]> {
        let len = usize::try_from(self.u64()?).ok()?;
        self.raw(len)
    }

    fn str(&mut self) -> Option<&'a str> {
        std::str::from_utf8(self.bytes()?).ok()
    }

    fn uuid(&mut self) -> Option<ItemId> {
        let raw: [u8; 16] = self.raw(16)?.try_into().ok()?;
        Some(ItemId::from_bytes(raw))
    }

    fn done(&self) -> bool {
        self.pos == self.buf.len()
    }
}

/// A count field. Each counted element is at least one byte, so a count
/// beyond the buffer's remainder is damage — reject before allocating.
fn count(reader: &mut Reader<'_>) -> Result<usize, RestoreError> {
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

fn read_sheet(
    reader: &mut Reader<'_>,
    now: Instant,
    away: Duration,
    wall_ms: u64,
    next_sheet_id: &mut u64,
    next_chip_id: &mut u64,
) -> Result<Sheet, RestoreError> {
    use RestoreError::Malformed;
    let uuid = reader.uuid().ok_or(Malformed)?;
    let created_wall_ms = reader.u64().ok_or(Malformed)?;
    // Re-cap on the way in: a hand-edited file must not smuggle a title
    // longer than the tab strip and the ledger agreed to carry.
    let title: String = reader
        .str()
        .ok_or(Malformed)?
        .chars()
        .take(TITLE_CAP)
        .collect();
    let title_is_user_set = match reader.u8().ok_or(Malformed)? {
        0 => false,
        1 => true,
        _ => return Err(Malformed),
    };
    let rung = Ttl::from_secs(reader.u64().ok_or(Malformed)?).ok_or(Malformed)?;
    // Time away drains the clock as if the app had stayed open: a hold
    // absorbs it first (that is what a hold is for), then the countdown.
    let (clock, held_while_away) = match reader.u8().ok_or(Malformed)? {
        0 => {
            let remaining = span(reader.u64().ok_or(Malformed)?);
            let deadline = now + remaining.saturating_sub(away);
            (SheetClock::Running { deadline }, Duration::ZERO)
        }
        1 => {
            let hold = span(reader.u64().ok_or(Malformed)?);
            let frozen = span(reader.u64().ok_or(Malformed)?);
            if away < hold {
                (
                    SheetClock::Held {
                        until: now + (hold - away),
                        frozen_remaining: frozen,
                        started: now,
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

    let chip_count = count(reader)?;
    let mut chips = Vec::new();
    for _ in 0..chip_count {
        let chip_uuid = reader.uuid().ok_or(Malformed)?;
        let kind = reader.u8().ok_or(Malformed)?;
        let promotion = match reader.u8().ok_or(Malformed)? {
            0 => None,
            1 => Some(Promotion {
                receipt_id: reader.str().ok_or(Malformed)?.to_string(),
            }),
            _ => return Err(Malformed),
        };
        let bytes = reader.bytes().ok_or(Malformed)?;
        let chip_id = ChipId::from_raw(*next_chip_id);
        *next_chip_id += 1;
        // Rebuild through the same constructors that sealed it: the
        // face (excerpt, size label, meta) is recomputed, never trusted
        // from the snapshot. Only the identity is carried through.
        let mut chip = match kind {
            0 => SealedChip::text_with_uuid(
                chip_id,
                chip_uuid,
                std::str::from_utf8(bytes).map_err(|_| Malformed)?,
            ),
            1 => SealedChip::image_with_uuid(chip_id, chip_uuid, bytes.to_vec()),
            _ => return Err(Malformed),
        };
        chip.promotion = promotion;
        chips.push(chip);
    }

    // The document blob, history included, then the materialized
    // metadata slot the compaction ceremony fills (ADR-0013). The slot
    // is parsed after the document imports, because its records are
    // believed only against the document they claim to describe.
    let blob = reader.bytes().ok_or(Malformed)?;
    let metadata = reader.bytes().ok_or(Malformed)?;

    // The document is reborn whole, under a fresh peer identity that
    // never reaches any surface: the counters the store hands out are
    // re-minted below, exactly as before.
    let document = SheetDocument::new();
    document.import_snapshot(blob)?;

    // The sync_document invariant, re-checked at this trust boundary:
    // every chip mark in the document resolves to a chip record, no
    // record is claimed twice, and no record goes unclaimed. A dangling
    // mark, a duplicate, or an orphan record is damage, and damage
    // rejects the whole snapshot before the store is touched. The
    // projection is rebuilt from the same walk, so it cannot disagree
    // with the document it mirrors.
    let mut segments = Vec::new();
    let mut referenced: Vec<ChipId> = Vec::new();
    for run in document.runs() {
        match run {
            DocRun::Ink(text) => segments.push(Segment::Ink(text)),
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

    // The block index is rebuilt from the imported document with fresh
    // identities. The rebuild knows only paragraphs, so the recorded
    // grouping goes back over it first, refused whole unless it
    // accounts for exactly the paragraphs this document has, and the
    // materialized records are adopted onto the blocks that result:
    // validated rather than trusted, a record believed only when its
    // anchor still resolves to the start of a block, its stamps clamped
    // to sane values on the way in. Everything else is dropped, which
    // leaves the affected block on the fresh identity the rebuild
    // minted (ADR-0013).
    let (frozen, spans) = read_materialized(metadata, wall_ms)?;
    let mut blocks = BlockIndex::for_document(&document);
    blocks.regroup(&document, &spans);
    blocks.adopt(&document, frozen);

    let id = SheetId::from_raw(*next_sheet_id);
    *next_sheet_id += 1;

    Ok(Sheet {
        id,
        uuid,
        title,
        title_is_user_set,
        created_wall_ms,
        document,
        segments,
        blocks,
        chips,
        rung,
        clock,
        total_held,
    })
}

/// Decode a sheet's block slot into candidate records for
/// [`BlockIndex::adopt`] to judge and the block grouping for
/// [`BlockIndex::regroup`] to check. Structural damage rejects the
/// whole snapshot like damage anywhere else; semantic doubt is handled
/// by validation instead. Timestamps are clamped into the sane range
/// (positive, no later than the wall clock now, modified never before
/// created), because a stamp is trusted arithmetic downstream and a
/// hand-edited file must not choose its values freely. The grouping
/// trails the records and is optional: a file whose blocks were its
/// paragraphs writes none, and neither did any build before grouping
/// existed, so an empty slot and a records-only slot both decode
/// cleanly.
fn read_materialized(
    bytes: &[u8],
    wall_ms: u64,
) -> Result<(Vec<PersistedBlock>, Vec<usize>), RestoreError> {
    use RestoreError::Malformed;
    if bytes.is_empty() {
        return Ok((Vec::new(), Vec::new()));
    }
    let ceiling = i64::try_from(wall_ms / 1000)
        .unwrap_or(i64::MAX)
        .saturating_add(STAMP_SLACK_S)
        .max(1);
    let clamp = |claimed: u64| i64::try_from(claimed).unwrap_or(i64::MAX).clamp(1, ceiling);
    let mut reader = Reader { buf: bytes, pos: 0 };
    let record_count = count(&mut reader)?;
    let mut records = Vec::new();
    for _ in 0..record_count {
        let id = reader.uuid().ok_or(Malformed)?;
        let anchor = reader.bytes().ok_or(Malformed)?.to_vec();
        let created_s = clamp(reader.u64().ok_or(Malformed)?);
        let modified_s = clamp(reader.u64().ok_or(Malformed)?).max(created_s);
        let origin = match reader.u8().ok_or(Malformed)? {
            0 => None,
            1 => Some(reader.str().ok_or(Malformed)?.to_string()),
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
    // Grown as each span decodes rather than reserved from the claimed
    // count: eight bytes are read per block, so a count the buffer
    // cannot cover must not reserve for what it promises.
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
    let title: String = reader
        .str()
        .ok_or(Malformed)?
        .chars()
        .take(TITLE_CAP)
        .collect();
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

    const HOUR: Duration = Duration::from_secs(60 * 60);

    fn store() -> (SheetStore<ManualClock>, ManualClock) {
        let clock = ManualClock::new();
        (SheetStore::new(clock.clone()), clock)
    }

    /// A populated store: two pages — ink + text chip (promoted) + image
    /// chip on the first, plain ink on the second — and a closed page in
    /// the ledger. The trailing ink carries an astral character so every
    /// test over this fixture crosses a surrogate pair.
    fn populated() -> (SheetStore<ManualClock>, ManualClock, SheetId, SheetId) {
        let (mut store, clock) = store();
        let first = store.new_sheet().unwrap();
        let token = store.seal_text(first, "ghp_expected-to-survive").unwrap();
        let image = store
            .seal_image(first, vec![0x89, b'P', b'N', b'G', 0, 1, 2, 3])
            .unwrap();
        assert!(store.mark_chip_promoted(token, "receipt-42".into()));
        assert!(store.sync_document(
            first,
            vec![
                Segment::Ink("# deploy notes\n".into()),
                Segment::Chip(token),
                Segment::Ink("\ntrailing \u{1F511} ink".into()),
                Segment::Chip(image),
            ],
        ));
        let second = store.new_sheet().unwrap();
        assert!(store.sync_document(second, vec![Segment::Ink("errands".into())]));
        let doomed = store.new_sheet().unwrap();
        assert!(store.sync_document(doomed, vec![Segment::Ink("old thoughts".into())]));
        assert!(store.close_sheet(doomed));
        (store, clock, first, second)
    }

    #[test]
    fn round_trip_preserves_pages_chips_and_titles() {
        let (original, clock, first, second) = populated();
        let snapshot = original.snapshot(1_000_000);

        let mut revived = SheetStore::new(clock.clone());
        let restored = revived.restore(&snapshot, 1_000_000).unwrap();
        assert_eq!(restored, 2);

        let order: Vec<SheetId> = revived.sheets().map(Sheet::id).collect();
        assert_eq!(order, vec![first, second]);

        let sheet = revived.sheet(first).unwrap();
        assert_eq!(sheet.title(), "deploy notes");
        assert!(!sheet.title_is_user_set());
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
        assert_eq!(chips[0].promotion().unwrap().receipt_id, "receipt-42");
        assert_eq!(chips[1].excerpt(), "PNG image");
        assert!(chips[1].promotion().is_none());

        // The sealed bytes themselves made the trip.
        let (bytes, _) = revived.copy_out_chip(chips[0].id()).unwrap();
        assert_eq!(&*bytes, b"ghp_expected-to-survive");

        // Provenance made the trip too: the change that produced the
        // body's first character keeps its commit timestamp, because
        // the blob carries the document's history rather than a replay.
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

        // The content snapshot carries no ledger.
        assert_eq!(revived.ledger().count(), 0);
    }

    #[test]
    fn the_origin_message_survives_the_round_trip() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        // A URL-bearing paste, sealed at the caret: the origin persists
        // as the seal commit's message and nowhere else.
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

        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 0).unwrap();
        let sheet = revived.sheets().next().unwrap();
        assert_eq!(
            sheet.document.first_change_message().as_deref(),
            Some(origin),
            "the origin message rides the blob through the round trip"
        );

        // The ledger snapshot, by contrast, must not know the URL: the
        // origin is content and lives only in the sealed content file.
        let ledger = store.ledger_snapshot();
        let needle = b"origin.example.test";
        assert!(
            !ledger.windows(needle.len()).any(|w| w == needle),
            "the origin leaked into the ledger snapshot"
        );
    }

    /// Whether `needle` occurs anywhere in `haystack`: the byte scan
    /// the compaction ceremony's discard claims are audited with.
    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    /// Unix epoch milliseconds now, for tests over materialized stamps:
    /// the document's commits are stamped by the real wall clock, so the
    /// restore ceiling they are clamped against must be real too.
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
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
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
        let old_peer = store.sheets[0].document.peer_id();

        // The rung gesture runs the ceremony; everything after asserts
        // against the compacted page.
        store.cycle_rung(id).unwrap();
        let sheet = store.sheet(id).unwrap();
        let segments = sheet.segments().to_vec();
        let metas = sheet.blocks_meta();
        let modified = sheet.modified_s();
        assert!(modified.is_some(), "the frozen floor answers for the page");

        let wall = real_wall_ms();
        let snapshot = store.snapshot(wall);
        // The persisted content sheds the trail and keeps the summary:
        // no deleted fragment, no old actor id, and the origin standing
        // in the materialized slot, sealed file only.
        assert!(!contains(&snapshot, b"DOOMED"));
        assert!(!contains(&snapshot, &old_peer.to_le_bytes()));
        assert!(
            contains(&snapshot, b"origin.example.test"),
            "the graduated origin must survive into the sealed file"
        );

        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(revived.restore(&snapshot, wall).unwrap(), 1);
        let sheet = revived.sheets().next().unwrap();
        assert_eq!(sheet.segments(), segments.as_slice());
        assert_eq!(
            sheet.blocks_meta(),
            metas,
            "block identities and stamps are adopted from the slot, not re-minted"
        );
        assert_eq!(sheet.modified_s(), modified);
        assert_eq!(
            sheet.blocks.records()[0]
                .materialized
                .as_ref()
                .unwrap()
                .origin
                .as_deref(),
            Some(origin),
            "the origin rides the materialized record through the round trip"
        );
    }

    #[test]
    fn a_pasted_block_comes_back_from_the_file_as_one_block() {
        use crate::store::EditOp;
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
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
        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(revived.restore(&snapshot, wall).unwrap(), 1);

        // A rebuild knows only paragraphs; the recorded grouping is what
        // keeps the paste from scattering into a stamp per line.
        let after = revived.sheets().next().unwrap().blocks_meta();
        assert_eq!(after.len(), 1, "the grouping survived the round trip");
        assert_eq!(after[0].paragraphs, 3);
        assert_eq!(after[0].created_s, before[0].created_s);
    }

    #[test]
    fn hostile_materialized_stamps_are_clamped_and_dead_anchors_dropped() {
        use crate::store::EditOp;
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
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
        store.cycle_rung(id).unwrap();
        let honest = store.sheet(id).unwrap().blocks_meta();

        // Tamper the way a hand-edited file would: stamps from the far
        // future and the deep past on block 0, and an anchor on block 1
        // that resolves nowhere.
        {
            let records = store.sheets[0].blocks.records_mut();
            let frozen = records[0].materialized.as_mut().unwrap();
            frozen.created_s = i64::MAX;
            frozen.modified_s = -40;
            records[1].anchor = vec![0xde, 0xad, 0xbe, 0xef];
        }
        let wall = real_wall_ms();
        let snapshot = store.snapshot(wall);
        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(revived.restore(&snapshot, wall).unwrap(), 1);
        let metas = revived.sheets().next().unwrap().blocks_meta();

        // Block 0's record still adopts (identity and anchor are
        // honest) but its stamps are clamped into the sane range: never
        // later than the wall clock now (plus the rounding slack),
        // modified never before created.
        let ceiling = i64::try_from(wall / 1000).unwrap() + STAMP_SLACK_S;
        assert_eq!(metas[0].id, honest[0].id);
        assert_eq!(metas[0].created_s, Some(ceiling));
        assert_eq!(metas[0].modified_s, Some(ceiling));

        // Block 1's record cannot prove it names a block, so it drops
        // whole: a fresh identity and no inherited provenance, the same
        // answer a file with no records would get.
        assert_ne!(metas[1].id, honest[1].id);
        assert_eq!(metas[1].created_s, None);
        assert_eq!(metas[1].modified_s, None);
    }

    #[test]
    fn a_user_set_title_survives_the_round_trip_verbatim() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.set_title(id, "quarterly numbers"));
        assert!(store.sync_document(id, vec![Segment::Ink("# something else".into())]));
        let snapshot = store.snapshot(0);

        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 0).unwrap();
        let sheet = revived.sheets().next().unwrap();
        assert_eq!(sheet.title(), "quarterly numbers");
        assert!(sheet.title_is_user_set());
    }

    #[test]
    fn ledger_round_trips_in_its_own_snapshot() {
        let (original, clock, ..) = populated();
        let ledger = original.ledger_snapshot();
        let expected: Vec<LedgerRecord> = original.ledger().cloned().collect();

        let mut revived = SheetStore::new(clock.clone());
        let restored = revived.restore_ledger(&ledger, 0).unwrap();
        assert_eq!(restored, expected.len());
        let records: Vec<LedgerRecord> = revived.ledger().cloned().collect();
        assert_eq!(records, expected);
        assert_eq!(records[0].title(), "old thoughts");
        assert_eq!(records[0].event(), LedgerEvent::Discarded);

        // A ledger restore leaves the pages alone, in both directions.
        assert!(revived.is_empty());
        assert_eq!(
            revived.restore_ledger(&original.snapshot(0), 0),
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
    fn records_past_the_retention_window_drop_on_load() {
        let (original, clock, ..) = populated();
        let ledger = original.ledger_snapshot();
        assert!(original.ledger().count() > 0);

        let mut revived = SheetStore::new(clock.clone());
        let far_future =
            original.ledger().next().unwrap().at_wall_ms() + crate::LEDGER_RETENTION_MS + 1;
        assert_eq!(revived.restore_ledger(&ledger, far_future).unwrap(), 0);
        assert_eq!(revived.ledger().count(), 0);
    }

    #[test]
    fn the_write_path_evicts_an_aged_title_with_no_new_event_recorded() {
        // The scenario the append-only sweep never covered: a menu-bar
        // app up for months, a page staged on day 0, and nothing since
        // but ink edits, which record nothing. Without a sweep on the
        // write path the title keeps being re-persisted under the
        // long-lived key forever.
        const TITLE: &str = "prod DB credentials";
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
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

        // Ninety days and a millisecond pass with the app still up. The
        // user keeps typing; no record is ever appended, so nothing on
        // the append path can sweep.
        clock.advance(Duration::from_millis(crate::LEDGER_RETENTION_MS + 1));
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink(format!("# {TITLE}\nstill editing\n")),
                Segment::Chip(chip),
            ],
        ));
        assert_eq!(store.ledger().count(), 2, "nothing was recorded");

        // The write path sweeps, and only then does the snapshot stop
        // carrying the aged title.
        assert_eq!(store.evict_ledger(clock.wall_ms()), 2, "both fell off");
        assert_eq!(store.ledger().count(), 0);
        assert!(
            !held(&store.ledger_snapshot()),
            "an aged title was re-persisted past the retention window"
        );
        // The page itself is untouched: eviction is a ledger sweep, not
        // a death.
        assert_eq!(store.len(), 1);
        assert_eq!(store.sheet(id).unwrap().chip_count(), 1);
    }

    #[test]
    fn the_write_path_sweep_keeps_records_inside_the_window() {
        let (mut store, clock) = store();
        store.new_sheet().unwrap();
        clock.advance(Duration::from_millis(crate::LEDGER_RETENTION_MS));
        store.new_sheet().unwrap();
        // Exactly 90 days old is inside the window, as on load.
        assert_eq!(store.evict_ledger(clock.wall_ms()), 0);
        assert_eq!(store.ledger().count(), 2);
        clock.advance(Duration::from_millis(1));
        assert_eq!(store.evict_ledger(clock.wall_ms()), 1);
        assert_eq!(store.ledger().count(), 1);
        // A sweep on an empty ledger, or one wholly inside the window,
        // is a no-op rather than an error.
        assert_eq!(store.evict_ledger(clock.wall_ms()), 0);
    }

    #[test]
    fn restored_ids_are_reissued_densely_and_uuids_survive() {
        let (mut store, clock) = store();
        // Push the in-process counters far past dense, the way a long
        // session does, so a restore visibly re-mints rather than
        // carrying anything over.
        store.next_sheet_id = 4_242;
        store.next_chip_id = 9_100;
        let first = store.new_sheet().unwrap();
        store.seal_text_at(first, "one", 0, 0).unwrap();
        store.seal_text_at(first, "two", 1, 0).unwrap();
        let second = store.new_sheet().unwrap();
        store.seal_text_at(second, "three", 0, 0).unwrap();
        assert!(first.raw() > 1000);

        let sheet_uuids: Vec<ItemId> = store.sheets().map(Sheet::uuid).collect();
        let chip_uuids: Vec<ItemId> = store
            .sheets()
            .flat_map(|s| s.chips().map(SealedChip::uuid))
            .collect();

        let snapshot = store.snapshot(0);
        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 0).unwrap();

        let ids: Vec<u64> = revived.sheets().map(|s| s.id().raw()).collect();
        assert_eq!(ids, vec![1, 2]);
        let chip_ids: Vec<u64> = revived
            .sheets()
            .flat_map(|s| s.chips().map(|c| c.id().raw()))
            .collect();
        assert_eq!(chip_ids, vec![1, 2, 3]);

        // Identity is what actually persists.
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

        // And the next id issued does not collide with a restored one.
        let fresh = revived.new_sheet().unwrap();
        assert_eq!(fresh.raw(), 3);
        let fresh_chip = revived.seal_text(fresh, "four").unwrap();
        assert_eq!(fresh_chip.raw(), 4);
    }

    /// A hand-assembled v3 snapshot holding one sheet: the given chip
    /// records, the given document blob, and an empty metadata slot.
    /// The writer cannot produce a roster that disagrees with its own
    /// document, so the trust-boundary tests build their bytes by hand.
    fn sheet_snapshot(chips: &[(ItemId, &str)], blob: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&0u64.to_le_bytes()); // saved wall stamp
        out.extend_from_slice(&1u64.to_le_bytes()); // one sheet
        out.extend_from_slice(ItemId::random().as_bytes());
        out.extend_from_slice(&0u64.to_le_bytes()); // created_wall_ms
        out.extend_from_slice(&0u64.to_le_bytes()); // empty title
        out.push(0); // title not user set
        out.extend_from_slice(&(8 * 60 * 60u64).to_le_bytes()); // 8h rung
        out.push(0); // running
        out.extend_from_slice(&60_000u64.to_le_bytes()); // remaining ms
        out.extend_from_slice(&0u64.to_le_bytes()); // total_held
        out.extend_from_slice(&(chips.len() as u64).to_le_bytes());
        for (uuid, text) in chips {
            out.extend_from_slice(uuid.as_bytes());
            out.push(0); // a text chip
            out.push(0); // never promoted
            out.extend_from_slice(&(text.len() as u64).to_le_bytes());
            out.extend_from_slice(text.as_bytes());
        }
        out.extend_from_slice(&(blob.len() as u64).to_le_bytes());
        out.extend_from_slice(blob);
        out.extend_from_slice(&0u64.to_le_bytes()); // empty metadata slot
        out
    }

    /// A store holding one live page, and that page's id: the fixture
    /// every rejection test asserts survived the failed restore.
    fn occupied() -> (SheetStore<ManualClock>, SheetId) {
        let (mut store, _clock) = store();
        let survivor = store.new_sheet().unwrap();
        (store, survivor)
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
        // ADR-0012 line 32: no sequential counter reaches a persisted
        // artifact. Ids chosen so their little-endian bytes cannot occur
        // by chance in a length, a span, or a wall stamp.
        const SHEET_RAW: u64 = 0x1234_5678_9ABC_DEF0;
        const CHIP_RAW: u64 = 0x0FED_CBA9_8765_4321;
        let (mut store, _clock) = store();
        store.next_sheet_id = SHEET_RAW;
        store.next_chip_id = CHIP_RAW;
        let id = store.new_sheet().unwrap();
        let chip = store.seal_text(id, "counted").unwrap();
        assert!(store.sync_document(id, vec![Segment::Chip(chip)]));
        assert_eq!(id.raw(), SHEET_RAW);
        assert_eq!(chip.raw(), CHIP_RAW);
        assert!(store.record_sent(chip, DestinationClass::Clipboard));

        let content = store.snapshot(0);
        let ledger = store.ledger_snapshot();
        for needle in [SHEET_RAW.to_le_bytes(), CHIP_RAW.to_le_bytes()] {
            assert!(
                !content.windows(8).any(|w| w == needle),
                "a sequential id reached the content snapshot"
            );
            assert!(
                !ledger.windows(8).any(|w| w == needle),
                "a sequential id reached the ledger snapshot"
            );
        }

        // The document's peer identity is confined the same way
        // (ADR-0013): the content blob names its authoring peer by
        // construction, which is the control that makes the ledger
        // scan meaningful, and the ledger must never carry it.
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
        // The token sits on a later line on purpose: a title is derived
        // from the first line and does reach the ledger, which is the
        // ADR's single documented content exception. Everything else the
        // page holds must stay out.
        const TOKEN: &str = "ghp_never-in-the-ledger";
        const DELETED: &str = "ghp_typed-then-deleted";
        let (mut store, _clock) = store();
        let id = store.new_sheet().unwrap();
        let chip = store.seal_text(id, TOKEN).unwrap();
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink(format!("# deploy notes\npasted {TOKEN} then {DELETED}\n")),
                Segment::Chip(chip),
            ],
        ));
        // The second token is typed and then removed, so from here on it
        // exists only as tombstones in the document's history.
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink(format!("# deploy notes\npasted {TOKEN} here\n")),
                Segment::Chip(chip),
            ],
        ));
        assert!(store.record_sent(chip, DestinationClass::OneTimeLink));

        // The control: the live token is in the content snapshot, twice
        // over, which is exactly why the two files get different keys.
        // The deleted token is in there too, carried by the blob's
        // tombstones, which is why the blob must never approach the
        // ledger.
        let needle = TOKEN.as_bytes();
        let ghost = DELETED.as_bytes();
        let content = store.snapshot(0);
        assert!(content.windows(needle.len()).any(|w| w == needle));
        assert!(
            content.windows(ghost.len()).any(|w| w == ghost),
            "the control: deleted ink survives in the blob's history"
        );

        assert!(store.close_sheet(id));
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
        let id = store.new_sheet().unwrap(); // 8h default rung
        let snapshot = store.snapshot(0);

        // Two hours pass while the app is closed (wall time only — the
        // monotonic test clock stays put, as a reboot would leave it).
        let two_hours_ms = 2 * 60 * 60 * 1000;
        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, two_hours_ms).unwrap();

        let remaining = revived.sheet(id).unwrap().remaining(revived.now());
        assert_eq!(remaining, 6 * HOUR);
    }

    #[test]
    fn pages_due_while_away_expire_into_the_ledger_on_restore() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.sync_document(id, vec![Segment::Ink("perishable".into())]));
        let snapshot = store.snapshot(0);

        let nine_hours_ms = 9 * 60 * 60 * 1000;
        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, nine_hours_ms).unwrap();
        let expired = revived.expire_due();
        assert_eq!(expired, vec![id]);
        assert!(revived.is_empty());
        let record = revived.ledger().next().unwrap();
        assert_eq!(record.event(), LedgerEvent::Expired);
        assert_eq!(record.title(), "perishable");
    }

    #[test]
    fn a_hold_absorbs_time_away_before_the_countdown_drains() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        assert!(store.pause_press(id)); // 1h hold, 8h frozen
        let snapshot = store.snapshot(0);

        // Away 30 minutes: still held, hold shrunk, frozen life intact.
        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 30 * 60 * 1000).unwrap();
        let now = revived.now();
        let sheet = revived.sheet(id).unwrap();
        assert!(sheet.is_held(now));
        assert_eq!(sheet.hold_remaining(now), Duration::from_secs(30 * 60));
        assert_eq!(sheet.remaining(now), 8 * HOUR);

        // Away 3 hours: the hold lapsed 2h ago; the countdown drained
        // from where it froze.
        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 3 * 60 * 60 * 1000).unwrap();
        let now = revived.now();
        let sheet = revived.sheet(id).unwrap();
        assert!(!sheet.is_held(now));
        assert_eq!(sheet.remaining(now), 6 * HOUR);
    }

    #[test]
    fn a_backwards_wall_clock_grants_no_extra_life() {
        let (mut store, clock) = store();
        let id = store.new_sheet().unwrap();
        clock.advance(2 * HOUR); // 6h left on the 8h rung
        let snapshot = store.snapshot(1_000_000_000);

        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 5).unwrap(); // wall clock moved back
        let remaining = revived.sheet(id).unwrap().remaining(revived.now());
        assert_eq!(remaining, 6 * HOUR);
    }

    #[test]
    fn v1_v2_and_unknown_magics_all_refuse_as_unknown_format() {
        // The format break is clean and deliberate (decided 2026-08-07):
        // there is no v2 reader and no downgrade writer, so every
        // earlier magic and every unknown one refuses the same way,
        // with the store untouched.
        let (original, _clock, ..) = populated();
        let (mut revived, survivor) = occupied();
        for magic in [b"OTSSNAP1", b"OTSSNAP2", b"OTSSNAP9", b"NOTSNAPS"] {
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

        let mut v0_ledger = original.ledger_snapshot().to_vec();
        v0_ledger[..8].copy_from_slice(b"OTSLEDR0");
        assert_eq!(
            revived.restore_ledger(&v0_ledger, 0),
            Err(RestoreError::UnknownFormat)
        );
    }

    #[test]
    fn wrong_magic_is_unknown_format_and_damage_is_malformed() {
        let (original, clock, ..) = populated();
        let snapshot = original.snapshot(0);

        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(
            revived.restore(b"not a snapshot at all", 0),
            Err(RestoreError::UnknownFormat)
        );

        // Trailing garbage is damage.
        let mut padded = snapshot.to_vec();
        padded.push(0);
        assert_eq!(revived.restore(&padded, 0), Err(RestoreError::Malformed));

        assert!(
            revived.is_empty(),
            "a failed restore must leave nothing behind"
        );
        assert_eq!(revived.ledger().count(), 0);

        // And the pristine snapshot still restores after all that.
        assert_eq!(revived.restore(&snapshot, 0).unwrap(), 2);
    }

    #[test]
    fn truncation_at_every_offset_rejects_without_panicking() {
        let (original, clock, ..) = populated();
        let snapshot = original.snapshot(7_000);
        let ledger = original.ledger_snapshot();

        let mut revived = SheetStore::new(clock.clone());
        for cut in 0..snapshot.len() {
            assert!(
                revived.restore(&snapshot[..cut], 7_000).is_err(),
                "a snapshot truncated at {cut} must not restore"
            );
            assert!(revived.is_empty(), "a rejected restore left pages behind");
        }
        for cut in 0..ledger.len() {
            assert!(
                revived.restore_ledger(&ledger[..cut], 7_000).is_err(),
                "a ledger truncated at {cut} must not restore"
            );
            assert_eq!(revived.ledger().count(), 0);
        }

        // Whole buffers still restore, so the loop proved rejection and
        // not merely that nothing ever restores.
        assert_eq!(revived.restore(&snapshot, 7_000).unwrap(), 2);
        assert!(revived.restore_ledger(&ledger, 7_000).unwrap() > 0);
    }

    #[test]
    fn a_hostile_length_is_rejected_before_it_allocates() {
        let (_, clock, ..) = populated();
        let mut revived = SheetStore::new(clock.clone());

        // A page count of u64::MAX, with no pages behind it.
        let mut hostile = Vec::new();
        hostile.extend_from_slice(MAGIC);
        hostile.extend_from_slice(&0u64.to_le_bytes());
        hostile.extend_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(revived.restore(&hostile, 0), Err(RestoreError::Malformed));

        // A record count of u64::MAX in a ledger snapshot.
        let mut hostile_ledger = Vec::new();
        hostile_ledger.extend_from_slice(LEDGER_MAGIC);
        hostile_ledger.extend_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(
            revived.restore_ledger(&hostile_ledger, 0),
            Err(RestoreError::Malformed)
        );

        // A title length of u64::MAX inside an otherwise plausible page.
        let mut hostile_title = Vec::new();
        hostile_title.extend_from_slice(MAGIC);
        hostile_title.extend_from_slice(&0u64.to_le_bytes());
        hostile_title.extend_from_slice(&1u64.to_le_bytes());
        hostile_title.extend_from_slice(ItemId::random().as_bytes());
        hostile_title.extend_from_slice(&0u64.to_le_bytes());
        hostile_title.extend_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(
            revived.restore(&hostile_title, 0),
            Err(RestoreError::Malformed)
        );

        // A blob length of u64::MAX behind an otherwise plausible page.
        // The hand-built sheet ends with the two length prefixes, so
        // the lie is written straight over the blob's.
        let mut hostile_blob = sheet_snapshot(&[], b"");
        let len = hostile_blob.len();
        hostile_blob[len - 16..len - 8].copy_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(
            revived.restore(&hostile_blob, 0),
            Err(RestoreError::Malformed)
        );

        // And the same lie in the materialized-metadata slot.
        let mut hostile_metadata = sheet_snapshot(&[], b"");
        let len = hostile_metadata.len();
        hostile_metadata[len - 8..].copy_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(
            revived.restore(&hostile_metadata, 0),
            Err(RestoreError::Malformed)
        );
        assert!(revived.is_empty());
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
}
