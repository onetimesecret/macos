//! Explicit persistence: the whole store as one plaintext snapshot
//! buffer, for the seam above to encrypt and keep across launches.
//!
//! Rev C's founding law read "memory-only; exit is total amnesia".
//! Lived experience overruled the absolutism the same way it did for
//! the [`ledger`](crate::ledger): a companion that opens empty every
//! morning surprises the person who parked pages in it the night
//! before. The amendment stays narrow:
//!
//! - **Explicit.** Nothing here runs on its own. The shell asks for a
//!   [`SheetStore::snapshot`] at quit and hands it back to
//!   [`SheetStore::restore`] at launch — no background writes, no
//!   shadow copies.
//! - **Never plaintext at rest.** This module produces and consumes
//!   *plaintext* snapshots and only ever hands them out in
//!   [`Zeroizing`] buffers. The FFI seam encrypts before anything
//!   touches disk (ChaCha20-Poly1305, key in the OS keychain) and the
//!   plaintext wipes on drop either side.
//! - **The clock keeps its promise.** Wall time that passed while the
//!   app was closed drains every countdown exactly as if it had been
//!   open; pages due by restore time expire into the ledger on the
//!   caller's next [`SheetStore::expire_due`].
//!
//! The format is a versioned, length-prefixed binary layout, written
//! into one exact-size buffer: growing a buffer reallocates, and
//! reallocation strands sealed bytes in freed, unwiped heap (the same
//! discipline as [`SheetStore::sheet_payload`]). A chip's mechanical
//! face (excerpt, size label, meta) is deliberately *not* stored — it
//! is recomputed from the bytes by the same functions that built it,
//! so the snapshot cannot smuggle a divergent rendering back in.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::clock::Clock;
use crate::ledger::{Cause, LedgerRecord, LedgerSegment};
use crate::sheet::{ChipId, ChipMeta, Promotion, SealedChip, Segment, Sheet, SheetClock, SheetId};
use crate::store::{LEDGER_CAP, SheetStore};
use crate::ttl::Ttl;

/// Magic + version prefix of a plaintext snapshot. A format change gets
/// a new final byte; old builds refuse rather than misread.
const MAGIC: &[u8; 8] = b"OTSSNAP1";

/// Ceiling on any span read back from a snapshot (30 days — well past
/// the 7-day rung and the 24-hour hold). Keeps `Instant` arithmetic
/// safely away from overflow no matter what the buffer claims.
const MAX_SPAN_MS: u64 = 30 * 24 * 60 * 60 * 1000;

/// Why a snapshot could not be restored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestoreError {
    /// Not a snapshot, or a version this build does not read.
    UnknownFormat,
    /// The layout is damaged: truncated, trailing bytes, invalid UTF-8,
    /// an off-ladder rung, or a document referencing a chip it does not
    /// own. The store is left exactly as it was.
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
    /// Serialize the whole store — sheets, chips (bytes included),
    /// clocks, ledger — into one plaintext buffer, stamped with
    /// `wall_ms` (Unix epoch milliseconds at save) so restore can
    /// account for time away. The buffer wipes on drop; the caller
    /// encrypts it and lets it fall.
    #[must_use]
    pub fn snapshot(&self, wall_ms: u64) -> Zeroizing<Vec<u8>> {
        let now = self.clock.now();
        let mut sizer = Sizer(0);
        emit(self, now, wall_ms, &mut sizer);
        let mut buffer = Zeroizing::new(Vec::with_capacity(sizer.0));
        emit(self, now, wall_ms, &mut Writer(&mut buffer));
        debug_assert_eq!(buffer.len(), sizer.0, "sizing pass drifted from the write");
        buffer
    }

    /// Replace this store's sheets and ledger with a snapshot's,
    /// draining every countdown by the wall time that passed since it
    /// was taken (`wall_ms` is Unix epoch milliseconds now). Meant for
    /// startup, before the store has issued anything. On error the
    /// store is untouched. Pages already due are *kept* — call
    /// [`SheetStore::expire_due`] right after to entomb them, so they
    /// leave ledger residue like any other death.
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
        let next_sheet_id = reader.u64().ok_or(RestoreError::Malformed)?;
        let next_chip_id = reader.u64().ok_or(RestoreError::Malformed)?;
        // A wall clock that moved backwards while away reads as no time
        // passed — the countdown never gains life from clock skew.
        let away = span(wall_ms.saturating_sub(saved_wall));
        let now = self.clock.now();

        let sheet_count = count(&mut reader)?;
        let mut sheets = Vec::new();
        for _ in 0..sheet_count {
            sheets.push(read_sheet(&mut reader, now, away)?);
        }
        let record_count = count(&mut reader)?;
        let mut ledger = VecDeque::new();
        for _ in 0..record_count {
            ledger.push_back(read_record(&mut reader, now, away)?);
        }
        if !reader.done() {
            return Err(RestoreError::Malformed);
        }

        // Never re-issue an id the snapshot already used.
        let max_sheet = sheets.iter().map(|s| s.id.raw()).max().unwrap_or(0);
        let max_chip = sheets
            .iter()
            .flat_map(|s| s.chips.iter().map(|c| c.id.raw()))
            .max()
            .unwrap_or(0);
        self.next_sheet_id = self.next_sheet_id.max(next_sheet_id).max(max_sheet + 1);
        self.next_chip_id = self.next_chip_id.max(next_chip_id).max(max_chip + 1);
        let restored = sheets.len();
        self.sheets = sheets;
        self.ledger = ledger;
        self.ledger.truncate(LEDGER_CAP);
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

fn emit<C: Clock>(store: &SheetStore<C>, now: Instant, wall_ms: u64, out: &mut impl Sink) {
    out.raw(MAGIC);
    out.u64(wall_ms);
    out.u64(store.next_sheet_id);
    out.u64(store.next_chip_id);
    out.u64(store.sheets.len() as u64);
    for sheet in &store.sheets {
        out.u64(sheet.id.raw());
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
        out.u64(sheet.segments.len() as u64);
        for segment in &sheet.segments {
            match segment {
                Segment::Ink(text) => {
                    out.u8(0);
                    out.bytes(text.as_bytes());
                }
                Segment::Chip(chip_id) => {
                    out.u8(1);
                    out.u64(chip_id.raw());
                }
            }
        }
        out.u64(sheet.chips.len() as u64);
        for chip in &sheet.chips {
            out.u64(chip.id.raw());
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
    }
    out.u64(store.ledger.len() as u64);
    for record in &store.ledger {
        out.u8(match record.cause {
            Cause::Expired => 0,
            Cause::Closed => 1,
        });
        out.bytes(record.title.as_bytes());
        out.u64(ms(now.saturating_duration_since(record.died_at)));
        out.u64(record.segments.len() as u64);
        for segment in &record.segments {
            match segment {
                LedgerSegment::Ink(text) => {
                    out.u8(0);
                    out.bytes(text.as_bytes());
                }
                LedgerSegment::Tombstone { excerpt } => {
                    out.u8(1);
                    out.bytes(excerpt.as_bytes());
                }
            }
        }
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

fn read_sheet(reader: &mut Reader<'_>, now: Instant, away: Duration) -> Result<Sheet, RestoreError> {
    use RestoreError::Malformed;
    let id = SheetId::from_raw(reader.u64().ok_or(Malformed)?);
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

    let segment_count = count(reader)?;
    let mut segments = Vec::new();
    for _ in 0..segment_count {
        segments.push(match reader.u8().ok_or(Malformed)? {
            0 => Segment::Ink(reader.str().ok_or(Malformed)?.to_string()),
            1 => Segment::Chip(ChipId::from_raw(reader.u64().ok_or(Malformed)?)),
            _ => return Err(Malformed),
        });
    }

    let chip_count = count(reader)?;
    let mut chips = Vec::new();
    for _ in 0..chip_count {
        let chip_id = ChipId::from_raw(reader.u64().ok_or(Malformed)?);
        let kind = reader.u8().ok_or(Malformed)?;
        let promotion = match reader.u8().ok_or(Malformed)? {
            0 => None,
            1 => Some(Promotion {
                receipt_id: reader.str().ok_or(Malformed)?.to_string(),
            }),
            _ => return Err(Malformed),
        };
        let bytes = reader.bytes().ok_or(Malformed)?;
        // Rebuild through the same constructors that sealed it: the
        // face (excerpt, size label, meta) is recomputed, never trusted
        // from the snapshot.
        let mut chip = match kind {
            0 => SealedChip::text(chip_id, std::str::from_utf8(bytes).map_err(|_| Malformed)?),
            1 => SealedChip::image(chip_id, bytes.to_vec()),
            _ => return Err(Malformed),
        };
        chip.promotion = promotion;
        chips.push(chip);
    }

    // The sync_document invariant, re-checked at this trust boundary:
    // every referenced chip exists on the sheet, none referenced twice.
    let mut referenced: Vec<ChipId> = Vec::new();
    for segment in &segments {
        if let Segment::Chip(chip_id) = segment {
            if referenced.contains(chip_id) || !chips.iter().any(|c| c.id == *chip_id) {
                return Err(Malformed);
            }
            referenced.push(*chip_id);
        }
    }

    Ok(Sheet {
        id,
        segments,
        chips,
        rung,
        clock,
        total_held,
    })
}

fn read_record(
    reader: &mut Reader<'_>,
    now: Instant,
    away: Duration,
) -> Result<LedgerRecord, RestoreError> {
    use RestoreError::Malformed;
    let cause = match reader.u8().ok_or(Malformed)? {
        0 => Cause::Expired,
        1 => Cause::Closed,
        _ => return Err(Malformed),
    };
    let title = reader.str().ok_or(Malformed)?.to_string();
    let age = span(reader.u64().ok_or(Malformed)?) + away;
    // The monotonic clock may not reach back far enough to place an old
    // death; sitting it at `now` only makes the residue read younger.
    let died_at = now.checked_sub(age).unwrap_or(now);
    let segment_count = count(reader)?;
    let mut segments = Vec::new();
    for _ in 0..segment_count {
        segments.push(match reader.u8().ok_or(Malformed)? {
            0 => LedgerSegment::Ink(reader.str().ok_or(Malformed)?.to_string()),
            1 => LedgerSegment::Tombstone {
                excerpt: reader.str().ok_or(Malformed)?.to_string(),
            },
            _ => return Err(Malformed),
        });
    }
    Ok(LedgerRecord {
        cause,
        title,
        segments,
        died_at,
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
    /// the ledger.
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
                Segment::Ink("\ntrailing ink".into()),
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
    fn round_trip_preserves_pages_chips_and_ledger() {
        let (original, clock, first, second) = populated();
        let snapshot = original.snapshot(1_000_000);

        let mut revived = SheetStore::new(clock.clone());
        let restored = revived.restore(&snapshot, 1_000_000).unwrap();
        assert_eq!(restored, 2);

        let order: Vec<SheetId> = revived.sheets().map(Sheet::id).collect();
        assert_eq!(order, vec![first, second]);

        let sheet = revived.sheet(first).unwrap();
        assert_eq!(sheet.title(), "deploy notes");
        assert_eq!(sheet.segments(), original.sheet(first).unwrap().segments());
        assert_eq!(sheet.chip_count(), 2);
        let chips: Vec<&SealedChip> = sheet.chips().collect();
        assert_eq!(chips[0].excerpt(), original.sheet(first).unwrap().chips().next().unwrap().excerpt());
        assert_eq!(chips[0].promotion().unwrap().receipt_id, "receipt-42");
        assert_eq!(chips[1].excerpt(), "PNG image");
        assert!(chips[1].promotion().is_none());

        // The sealed bytes themselves made the trip.
        let (bytes, _) = revived.copy_out_chip(chips[0].id()).unwrap();
        assert_eq!(&*bytes, b"ghp_expected-to-survive");

        // The ledger came along: the closed page's residue.
        let records: Vec<&LedgerRecord> = revived.ledger().collect();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].title(), "old thoughts");
        assert_eq!(records[0].cause(), Cause::Closed);
    }

    #[test]
    fn restored_ids_never_collide_with_snapshot_ids() {
        let (original, clock, first, _) = populated();
        let snapshot = original.snapshot(0);
        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 0).unwrap();

        let new_sheet = revived.new_sheet().unwrap();
        let new_chip = revived.seal_text(new_sheet, "fresh").unwrap();
        let old_chips: Vec<ChipId> = revived
            .sheet(first)
            .unwrap()
            .chips()
            .map(SealedChip::id)
            .collect();
        assert!(!old_chips.contains(&new_chip));
        assert!(revived.sheets().all(|s| s.id() != new_sheet || s.id() == new_sheet));
        assert!(new_sheet.raw() > first.raw());
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
        assert_eq!(record.cause(), Cause::Expired);
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
    fn wrong_magic_is_unknown_format_and_damage_is_malformed() {
        let (original, clock, ..) = populated();
        let snapshot = original.snapshot(0);

        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(
            revived.restore(b"not a snapshot at all", 0),
            Err(RestoreError::UnknownFormat)
        );

        // Truncation anywhere must reject without touching the store.
        for cut in [MAGIC.len(), MAGIC.len() + 3, snapshot.len() / 2, snapshot.len() - 1] {
            assert_eq!(
                revived.restore(&snapshot[..cut], 0),
                Err(RestoreError::Malformed),
                "truncated at {cut}"
            );
        }
        // Trailing garbage is damage too.
        let mut padded = snapshot.to_vec();
        padded.push(0);
        assert_eq!(revived.restore(&padded, 0), Err(RestoreError::Malformed));

        assert!(revived.is_empty(), "a failed restore must leave nothing behind");
        assert_eq!(revived.ledger().count(), 0);

        // And the pristine snapshot still restores after all that.
        assert_eq!(revived.restore(&snapshot, 0).unwrap(), 2);
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
    }
}
