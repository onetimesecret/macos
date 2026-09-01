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
//! - **No counter is ever written down.** [`TabId`], [`SheetId`] and
//!   [`ChipId`] are in-process ordering handles, nothing more. The
//!   snapshot carries the random [`ItemId`] instead, and restore
//!   re-mints the counters densely in read order. That is safe
//!   precisely because a restore only ever runs before the shell has
//!   read anything out of the store, so no id has escaped to be reused.
//! - **The durable half carries nothing the app derived.** A tab
//!   record holds a name the user typed or no name at all; the page's
//!   derived title is not written and is recomputed from the restored
//!   segments on the way back in (ADR-0017), the same discipline that
//!   already refuses to store a chip's excerpt.
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
//!
//! A page sits inside its tab's record, which is why an orphan page is
//! not a case this module checks: no byte sequence encodes one. The
//! layout refuses it rather than the reader.
//!
//! Every repeated record states its own byte length before its fields:
//! the tab record, the page record nested inside it, the chip records
//! inside that, the materialized block record, and the ledger record. A
//! reader takes the fields it knows
//! and then reaches the next record by that length rather than by
//! wherever its own field walk stopped, so a file written by a build
//! that added a trailing field still reads here, minus the field this
//! build has never heard of. That is the whole of what the rule buys
//! (issue #54). It does not survive a field that moved, changed width,
//! or changed meaning, and it does not cover what sits outside a
//! record: the magics, the counts, and the sections that trail a
//! record list. Those still take a new magic, and a new magic still
//! refuses every existing file.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::blocks::{BlockIndex, MaterializedMeta, PersistedBlock};
use crate::clock::Clock;
use crate::document::{DocRun, SheetDocument};
use crate::ledger::{DestinationClass, LedgerEvent, LedgerRecord, SizeClass, evict_expired};
use crate::sheet::{
    CeremonyState, ChipId, ChipMeta, Conceal, ItemId, SealedChip, Segment, Sheet, SheetClock,
    SheetId, TITLE_CAP, Tab, TabId, derive_title,
};
use crate::store::{HOLD_FIRST, HOLD_TOPUP, SheetStore};
use crate::ttl::Ttl;

/// Magic + version prefix of a plaintext content snapshot. A format
/// change gets a new final byte; old builds refuse rather than misread.
/// `3` replaced the segments section with the sheet's full Loro
/// document blob (ADR-0013). `4` gives every repeated record its own
/// length prefix (issue #54), which is why it is the last break a
/// trailing field will ever cost. It is the one break ADR-0016 section
/// 9 and ADR-0017 ride too, so a `4` file is readable only by a build
/// carrying all three. There is no reader and no downgrade writer for
/// any earlier version: `1`, `2` and `3` files refuse as unknown,
/// deliberately.
const MAGIC: &[u8; 8] = b"OTSSNAP4";

/// Magic + version prefix of a plaintext ledger snapshot. Separate from
/// [`MAGIC`] so the two files can never be mistaken for each other. `2`
/// takes the same per-record length prefix as the content snapshot,
/// because one encoding rule in this module is the point. The ledger
/// file survives on its own long-lived key and would otherwise have sat
/// out this break, so `1` refusing costs the retained history once, and
/// that is announced with the content loss rather than under it.
const LEDGER_MAGIC: &[u8; 8] = b"OTSLEDR2";

/// Ledger payload magics this module once wrote and has since replaced.
/// A file carrying one of these opens under the ledger envelope and the
/// long-lived ledger key exactly as a current one does, and only then
/// meets a reader that does not exist, so refusing it as unknown would
/// leave the file on disk and the ledger licence withheld on every
/// launch after the break (ADR-0016 section 9). [`restore_ledger`]
/// names the case as [`RestoreError::Superseded`] instead, so the caller
/// that owns the file can dispose of it. This set grows by one entry per
/// ledger break, and `OTSLEDR0` is not in it: it is no version this
/// module ever wrote. The content snapshot has no counterpart, because
/// a superseded snapshot magic never reaches [`SheetStore::restore`]: its
/// envelope is superseded with it and refuses first.
///
/// [`restore_ledger`]: SheetStore::restore_ledger
const SUPERSEDED_LEDGER_MAGICS: [&[u8; 8]; 1] = [b"OTSLEDR1"];

/// Ceiling on any span read back from a snapshot (30 days — well past
/// the 7-day rung and the 24-hour hold). Keeps `Instant` arithmetic
/// safely away from overflow no matter what the buffer claims.
const MAX_SPAN_MS: u64 = 30 * 24 * 60 * 60 * 1000;

/// Slack above the wall clock allowed for a materialized stamp before
/// the clamp takes it: the document's recorder rounds to the nearest
/// second while the wall reading truncates, so an honest stamp can sit
/// one second ahead of the clock that judges it.
const STAMP_SLACK_S: i64 = 2;

/// A persisted Unix-second stamp, clamped into the sane range on the
/// way in: positive, and no later than the wall clock plus
/// [`STAMP_SLACK_S`]. A stamp is trusted arithmetic downstream, so a
/// hand-edited file must not choose its value freely.
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
    /// A version this build once wrote and has since replaced. Nothing
    /// in it can be read and the store is left exactly as it was, the
    /// same as [`UnknownFormat`](Self::UnknownFormat); the difference is
    /// that the caller holding the file is told it may dispose of it
    /// (ADR-0016 section 9). Only the ledger reports this today, see
    /// [`SUPERSEDED_LEDGER_MAGICS`].
    Superseded,
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
            RestoreError::Superseded => {
                f.write_str("a snapshot from a format this build has replaced")
            }
            RestoreError::Malformed => f.write_str("snapshot is damaged"),
        }
    }
}

impl std::error::Error for RestoreError {}

impl<C: Clock> SheetStore<C> {
    /// Serialize the store's content, meaning the strip of tabs with
    /// their names and rungs, and inside them the pages, chips (bytes
    /// included) and clocks, into one plaintext buffer, stamped with
    /// `wall_ms` (Unix epoch milliseconds at save) so restore can
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
            .sheets()
            .map(|sheet| sheet.document.export_snapshot())
            .collect();
        // The materialized sections are encoded once too, and zeroizing
        // for the same reason as the blobs: a frozen origin is content.
        let metas: Vec<Zeroizing<Vec<u8>>> = self
            .sheets()
            .map(|sheet| encode_materialized(&sheet.blocks, &sheet.document))
            .collect();
        let mut sizer = Sizer(0);
        emit(self, &blobs, &metas, now, wall_ms, &mut sizer);
        let mut buffer = Zeroizing::new(Vec::with_capacity(sizer.0));
        emit(self, &blobs, &metas, now, wall_ms, &mut Writer(&mut buffer));
        debug_assert_eq!(buffer.len(), sizer.0, "sizing pass drifted from the write");
        buffer
    }

    /// Replace this store's strip with a snapshot's, draining every
    /// countdown by the wall time that passed since it was taken
    /// (`wall_ms` is Unix epoch milliseconds now). Meant for startup,
    /// before the store has issued anything: the sequential ids are
    /// re-minted densely from 1 in read order, which is only sound
    /// because nothing has yet read an id out of this store. Tab, page
    /// and chip identity across the relaunch is carried by the stored
    /// [`ItemId`], not by the counter.
    ///
    /// The ledger is untouched: restore it separately with
    /// [`SheetStore::restore_ledger`]. On error the store is untouched.
    /// Pages already due are *kept*: call [`SheetStore::expire_due`]
    /// right after to entomb them, so they leave ledger residue like any
    /// other death, and so the tabs they were standing in are left
    /// empty rather than refilled.
    ///
    /// Returns the number of live **pages** restored, which is not the
    /// width of the strip. The two diverge the moment a tab outlives
    /// its page (ADR-0017): a file holding nine named tabs and no
    /// content restores nine slots and answers zero. Callers that want
    /// the strip read [`SheetStore::tabs`], and callers asking whether
    /// anything is left read [`SheetStore::holds_no_page`] or
    /// [`SheetStore::has_no_tabs`], which are different questions.
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

        let tab_count = count(&mut reader)?;
        // The cap is the tab's lifetime bound now, not only the
        // anti-eviction bound, so a file claiming a wider strip than
        // this store would ever write is damage or a hand edit and
        // refuses like any other.
        if tab_count > self.cap {
            return Err(RestoreError::Malformed);
        }
        let mut tabs = Vec::new();
        let mut next_tab_id = 1;
        let mut next_sheet_id = 1;
        let mut next_chip_id = 1;
        for _ in 0..tab_count {
            let mut record = reader.framed().ok_or(RestoreError::Malformed)?;
            tabs.push(read_tab(
                &mut record,
                now,
                away,
                wall_ms,
                &mut next_tab_id,
                &mut next_sheet_id,
                &mut next_chip_id,
            )?);
        }
        // The envelope stays strict even though the records do not: a
        // tail after the last record is outside every frame, so nothing
        // states how long it is or promises it was ever meant to be
        // here.
        if !reader.done() {
            return Err(RestoreError::Malformed);
        }

        let restored = tabs.iter().filter(|tab| tab.page.is_some()).count();
        self.tabs = tabs;
        self.next_tab_id = next_tab_id;
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

    /// Merge a ledger snapshot's records into this store's, dropping
    /// records that have aged out of the retention window by `wall_ms`
    /// (Unix epoch milliseconds now). Sheets are untouched. On error the
    /// store is untouched.
    ///
    /// **Merge, not replace, because the store may already know
    /// something the file cannot.** The shell's launch order is the
    /// content file first and the ledger file second, and the content
    /// restore entombs every death that fell due while the app was
    /// closed ([`SheetStore::expire_due`]). By the time this call
    /// arrives the deque can already be holding records written minutes
    /// ago that no file has ever seen — an overnight expiry, which is
    /// the one death the user never witnesses and therefore the one the
    /// trail owes them most. Replacing the deque dropped it before it
    /// could reach a reader or the next save.
    ///
    /// Returns the number of records the ledger holds afterwards.
    ///
    /// # Errors
    ///
    /// [`RestoreError::Superseded`] for a ledger snapshot in a version
    /// this module once wrote and no longer reads
    /// ([`SUPERSEDED_LEDGER_MAGICS`]); [`RestoreError::UnknownFormat`]
    /// for any other buffer that is not a ledger snapshot this build
    /// reads; [`RestoreError::Malformed`] for one that is damaged.
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
        let mut loaded = Vec::new();
        for _ in 0..record_count {
            let mut record = reader.framed().ok_or(RestoreError::Malformed)?;
            loaded.push(read_record(&mut record)?);
        }
        if !reader.done() {
            return Err(RestoreError::Malformed);
        }
        // Nothing above this line has touched the store, so a refusal
        // still leaves it exactly as it was.
        //
        // The order needs no sort. The ledger runs newest first (an
        // append is a `push_front`), what is already in hand was
        // recorded by this session, and the file's records were
        // recorded by earlier ones, so laying the file's list after the
        // live one is precisely what a `push_front` per record would
        // have produced. Sorting on the stamp instead would rearrange a
        // file written by a session whose wall clock stepped, which is
        // not this call's business to correct.
        let mut merged: Vec<LedgerRecord> = self.ledger.drain(..).collect();
        // The merge is a multiset union: every copy the file and the
        // deque both hold cancels one for one, and any copy only the
        // file holds is kept. So reading one file twice, or reading a
        // file saved after this same merge, reads back as one trail
        // rather than two, while a file that genuinely holds more copies
        // of an event than the deque does keeps the surplus. The deque's
        // records are indexed by the two fields any twin must agree on,
        // so the equality test only ever weighs the handful that could
        // be the same event; the test itself is the whole record, so a
        // field added later joins it for free. A match consumes the live
        // record it spent, removing its position, so a second identical
        // file record cannot cancel against the same deque record twice.
        // The file is never deduplicated against itself: two identical
        // records a session genuinely wrote down are two things that
        // happened, and the loaded list is never indexed here, only the
        // deque.
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
        // Retention runs on load, where the ledger is already in hand: a
        // record sitting in a closed file is inert until someone reads it.
        evict_expired(&mut ledger, wall_ms);
        let kept = ledger.len();
        self.ledger = ledger;
        Ok(kept)
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

/// Write one record as its own byte length followed by its fields, so a
/// reader holding fewer fields than the writer wrote can still find
/// where the next record starts.
///
/// The length comes from running the same body through a [`Sizer`]
/// first, which is exact for the same reason the outer two-pass write
/// is, and which costs no intermediate buffer. That matters here rather
/// than only being tidy: a page record carries sealed bytes, and a
/// second copy of those is a second allocation that has to be wiped.
/// The body is therefore called twice and must be a pure function of
/// what it captures.
fn framed(out: &mut dyn Sink, body: impl Fn(&mut dyn Sink)) {
    let mut sizer = Sizer(0);
    body(&mut sizer);
    out.u64(sizer.0 as u64);
    body(out);
}

fn emit<C: Clock>(
    store: &SheetStore<C>,
    blobs: &[Zeroizing<Vec<u8>>],
    metas: &[Zeroizing<Vec<u8>>],
    now: Instant,
    wall_ms: u64,
    out: &mut dyn Sink,
) {
    out.raw(MAGIC);
    out.u64(wall_ms);
    out.u64(store.tabs.len() as u64);
    // The blobs and the materialized sections were exported per live
    // page, in strip order, so one walk of the tabs consumes them in
    // the order they were made. The step happens out here rather than
    // inside the framed body, which is called twice and must stay a
    // pure function of what it captures.
    let mut pages = blobs.iter().zip(metas);
    for tab in &store.tabs {
        let page = tab.page.as_ref().map(|sheet| {
            let (blob, meta) = pages.next().expect("one export per live page");
            (sheet, blob.as_slice(), meta.as_slice())
        });
        framed(&mut *out, |out| emit_tab(tab, page, now, out));
    }
}

/// One tab record, framed by its caller: identity, the slot's birthday,
/// the name the user typed if they typed one, the rung, and then the
/// page it holds, framed again inside this frame.
///
/// The page-present flag is written even when it is `1`, so that a tab
/// with a page and a tab without one differ by a byte rather than by a
/// length the reader would have to infer.
fn emit_tab(tab: &Tab, page: Option<(&Sheet, &[u8], &[u8])>, now: Instant, out: &mut dyn Sink) {
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
        Some((sheet, blob, meta)) => {
            out.u8(1);
            framed(&mut *out, |out| emit_sheet(sheet, blob, meta, now, out));
        }
    }
}

/// One page record, framed by its caller: identity, clock, the chip
/// roster, the document blob, and the materialized slot.
///
/// No title. The page's derived title is a string the app made from the
/// body, so it is recomputed at restore from the restored segments
/// rather than written down (ADR-0017), and the rung it used to carry
/// belongs to the tab above.
fn emit_sheet(sheet: &Sheet, blob: &[u8], meta: &[u8], now: Instant, out: &mut dyn Sink) {
    // Identity, not the in-process counter (ADR-0012).
    out.raw(sheet.uuid.as_bytes());
    out.u64(sheet.created_wall_ms);
    match sheet.clock {
        // Only a hold still standing at `now` is written as one. Two
        // tags, one payload: the tier is what decides whether the next
        // pause press tops the hold up or releases it, so it has to
        // survive a relaunch. A build that predates the release refuses
        // tag 2 outright rather than misreading it as a first hold.
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
        // Everything else is a countdown running down, and
        // [`Sheet::remaining`] is the whole of what it has left. A hold
        // that lapsed before this snapshot was taken belongs here and
        // not above: the life that drained since it lapsed is spent,
        // and writing the frozen span down verbatim would hand every
        // hour of it back at the next launch. `store::normalize` makes
        // the same conversion on the live clock, but only from the
        // paths that hold `&mut self`, and a snapshot is a `&self` read
        // that has to be honest without it.
        _ => {
            out.u8(0);
            out.u64(ms(sheet.remaining(now)));
        }
    }
    // total_held(now) folds a live hold's span in; restore restarts the
    // live hold's accounting from its own `now`.
    out.u64(ms(sheet.total_held(now)));
    // Chips before the document blob, so the reader has every chip
    // identity in hand before a mark asks it to resolve one.
    out.u64(sheet.chips.len() as u64);
    for chip in &sheet.chips {
        framed(&mut *out, |out| emit_chip(chip, out));
    }
    // The whole document, history included: the projection is not
    // written because the document is its source of truth, and a
    // snapshot that carried both could smuggle a divergent projection
    // back in.
    out.bytes(blob);
    // The materialized-metadata section, filled by the compaction
    // ceremony (ADR-0013): each block that carries a frozen summary
    // writes its identity, its anchor, its stamps, and its origin. The
    // slot was reserved in stage 4, so a compacted file differs from an
    // uncompacted one only by this section's contents.
    out.bytes(meta);
    // The page's own half of graduation, trailing every field above it
    // because that is what a trailing field costs here (issue #54): the
    // log frontier the last ceremony captured, which no block can carry
    // because the change it stamps may have been a deletion, and a
    // deletion leaves no character behind to vote for it. A reader that
    // has never heard of this field stops at the one before it and
    // reaches the next record by the page record's length, and a file
    // written before the field existed simply ends where the reader
    // learns to expect nothing.
    match sheet.blocks.compaction_frontier() {
        None => out.u8(0),
        Some(frontier_s) => {
            out.u8(1);
            // Positive by construction, the frontier being a committed
            // timestamp the derivation already refused to read at zero.
            out.u64(frontier_s.max(0) as u64);
        }
    }
}

/// One chip record, framed by its caller. The face (excerpt, size
/// label) is absent on purpose: it is recomputed on the way back in.
fn emit_chip(chip: &SealedChip, out: &mut dyn Sink) {
    out.raw(chip.uuid.as_bytes());
    out.u8(match chip.meta {
        ChipMeta::Text { .. } => 0,
        ChipMeta::Image { .. } => 1,
    });
    match &chip.conceal {
        None => out.u8(0),
        Some(conceal) => {
            out.u8(1);
            out.bytes(conceal.receipt_id.as_bytes());
        }
    }
    out.bytes(chip.bytes.expose());
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

fn emit_materialized(blocks: &BlockIndex, spans: &[usize], grouped: bool, out: &mut dyn Sink) {
    let frozen: Vec<_> = blocks
        .records()
        .iter()
        .filter_map(|record| record.materialized.as_ref().map(|meta| (record, meta)))
        .collect();
    out.u64(frozen.len() as u64);
    for (record, meta) in frozen {
        framed(&mut *out, |out| {
            // The block's identity, then the anchor that must still
            // resolve for the record to be believed on the way back in.
            out.raw(record.id.as_bytes());
            out.bytes(&record.anchor);
            // Stamps are positive by construction (derivation skips the
            // epoch-stamped rebuild), so the sign bit never survives
            // the round trip through u64.
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

    /// A reader bounded to the next length-prefixed record. Fields this
    /// build does not know are left behind inside that bound, and this
    /// reader is already standing at the record after it: nothing has
    /// to seek, because the length was consumed to make the bound. The
    /// returned reader is deliberately never asked whether it is
    /// [`done`](Reader::done) — an unread tail is the rule working, not
    /// damage.
    fn framed(&mut self) -> Option<Reader<'a>> {
        Some(Reader {
            buf: self.bytes()?,
            pos: 0,
        })
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

/// One tab record, read from its own framed sub-reader: the durable
/// half of the object graph, and then the page it holds if it holds
/// one.
///
/// The rung is validated against the ladder here rather than in the
/// page arm, because it moved to the tab and its validation moved with
/// it: an off-ladder number is damage wherever it is written.
fn read_tab(
    reader: &mut Reader<'_>,
    now: Instant,
    away: Duration,
    wall_ms: u64,
    next_tab_id: &mut u64,
    next_sheet_id: &mut u64,
    next_chip_id: &mut u64,
) -> Result<Tab, RestoreError> {
    use RestoreError::Malformed;
    let uuid = reader.uuid().ok_or(Malformed)?;
    let created_wall_ms = reader.u64().ok_or(Malformed)?;
    let name = match reader.u8().ok_or(Malformed)? {
        0 => None,
        // Re-cap on the way in: a hand-edited file must not smuggle a
        // label longer than the strip and the ledger agreed to carry.
        // The cap matters more here than it did on the page's title,
        // because this string is durable and reaches the ledger through
        // every record the tab's pages produce.
        1 => Some(
            reader
                .str()
                .ok_or(Malformed)?
                .chars()
                .take(TITLE_CAP)
                .collect(),
        ),
        _ => return Err(Malformed),
    };
    let rung = Ttl::from_secs(reader.u64().ok_or(Malformed)?).ok_or(Malformed)?;
    let page = match reader.u8().ok_or(Malformed)? {
        0 => None,
        1 => {
            let mut body = reader.framed().ok_or(Malformed)?;
            // A flag that promises a page and a frame that carries no
            // bytes disagree, and the disagreement is the damage: an
            // empty body would otherwise fail field by field and read
            // as a truncation somewhere deeper.
            if body.buf.is_empty() {
                return Err(Malformed);
            }
            Some(read_page(
                &mut body,
                now,
                away,
                wall_ms,
                rung.duration(),
                next_sheet_id,
                next_chip_id,
            )?)
        }
        _ => return Err(Malformed),
    };

    let id = TabId::from_raw(*next_tab_id);
    *next_tab_id += 1;

    Ok(Tab {
        id,
        uuid,
        created_wall_ms,
        name,
        rung,
        page,
    })
}

/// One page record. `ceiling` is the duration of the rung its tab was
/// read at, and it bounds every life span this record can claim: seven
/// days is the top of the ladder, so seven days is the most life a
/// restored page may come back holding, whatever the bytes say
/// (ADR-0016 section 10, case 7). A hold is bounded too, but by the
/// ceiling the pause gesture sets rather than by the rung, since a
/// suspension is not life the ladder measures. On the honest write path the bound
/// holds by construction, since a rung click sets the deadline to the
/// rung's own duration and restore only ever subtracts. It is a file
/// nobody in this process wrote that the clamp is for: a stale or
/// hand-edited span is the one number a replayed generation can move
/// (ADR-0016 section 8), and the ladder's ceiling is what it must not
/// move past.
fn read_page(
    reader: &mut Reader<'_>,
    now: Instant,
    away: Duration,
    wall_ms: u64,
    ceiling: Duration,
    next_sheet_id: &mut u64,
    next_chip_id: &mut u64,
) -> Result<Sheet, RestoreError> {
    use RestoreError::Malformed;
    let uuid = reader.uuid().ok_or(Malformed)?;
    let created_wall_ms = reader.u64().ok_or(Malformed)?;
    // Time away drains the clock as if the app had stayed open: a hold
    // absorbs it first (that is what a hold is for), then the countdown.
    // Tag 1 is a first hold, tag 2 a hold already topped up to its 24
    // hour ceiling; the two carry the same payload and differ only in
    // what the next pause press does.
    //
    // The hold's own span is not the rung's to bound: a hold is a
    // suspension rather than life, and clamping it to the rung would
    // shorten an honest 24 hour hold on the 1h rung. It is bounded all
    // the same, against the ceiling the pause gesture itself would have
    // set, because a hold read at face value is a way past the rung
    // that costs nothing to write. A held page's countdown does not
    // run, so a file claiming a month of hold keeps its plaintext for a
    // month on the one hour rung.
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

    let chip_count = count(reader)?;
    let mut chips = Vec::new();
    for _ in 0..chip_count {
        let mut record = reader.framed().ok_or(Malformed)?;
        let chip_uuid = record.uuid().ok_or(Malformed)?;
        let kind = record.u8().ok_or(Malformed)?;
        let conceal = match record.u8().ok_or(Malformed)? {
            0 => None,
            1 => Some(Conceal {
                receipt_id: record.str().ok_or(Malformed)?.to_string(),
            }),
            _ => return Err(Malformed),
        };
        let bytes = record.bytes().ok_or(Malformed)?;
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
        chip.conceal = conceal;
        chips.push(chip);
    }

    // The document blob, history included, then the materialized
    // metadata slot the compaction ceremony fills (ADR-0013). The slot
    // is parsed after the document imports, because its records are
    // believed only against the document they claim to describe.
    let blob = reader.bytes().ok_or(Malformed)?;
    let metadata = reader.bytes().ok_or(Malformed)?;
    // The page-level modified floor, a trailing field on this record
    // (issue #54). A file written before it existed ends here, and its
    // absence is not damage: the page comes back resting on its block
    // summaries alone, exactly as it did before the field was written.
    let frontier_s = if reader.done() {
        None
    } else {
        match reader.u8().ok_or(Malformed)? {
            0 => None,
            1 => Some(clamp_stamp(reader.u64().ok_or(Malformed)?, wall_ms)),
            _ => return Err(Malformed),
        }
    };

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
    // The page-level floor rides back in beside the summaries: it is
    // the stamp of a change no surviving character can prove, so
    // nothing else in this file could reconstruct it.
    blocks.note_compaction(frontier_s);

    let id = SheetId::from_raw(*next_sheet_id);
    *next_sheet_id += 1;

    // The derived title is recomputed rather than read: it is never
    // written, so this is the only place it can come from, and it comes
    // from the segments the walk above just rebuilt (ADR-0017). No
    // clock reading is involved, because the placeholder is the tab's
    // business and this is the page's.
    let derived_title = derive_title(&segments);

    Ok(Sheet {
        id,
        uuid,
        derived_title,
        created_wall_ms,
        document,
        segments,
        blocks,
        chips,
        clock,
        total_held,
        // Never persisted: a sync session does not survive a restart,
        // so every restored page compacts inline until the engine
        // re-defers it on attach (issue #101).
        ceremony: CeremonyState::Immediate,
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
            1 => Some(record.str().ok_or(Malformed)?.to_string()),
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

    /// The slot a page stands in, for the tab-addressed routes.
    fn slot(store: &SheetStore<ManualClock>, page: SheetId) -> TabId {
        store
            .tabs()
            .find(|tab| tab.page().map(Sheet::id) == Some(page))
            .expect("the page is in a tab")
            .id()
    }

    /// A populated store: two pages — ink + text chip (concealed) + image
    /// chip on the first, plain ink on the second — and a closed page in
    /// the ledger. The trailing ink carries an astral character so every
    /// test over this fixture crosses a surrogate pair.
    ///
    /// The first line carries emphasis inside a word on purpose. The
    /// title it derives to, "deploy notes", is then a string the
    /// derivation produces and the ink does not contain, so a scan for
    /// it over the snapshot bytes answers exactly one question: whether
    /// the file wrote the derived title down.
    fn populated() -> (SheetStore<ManualClock>, ManualClock, SheetId, SheetId) {
        let (mut store, clock) = store();
        let first = store.new_tab().unwrap().1;
        let token = store.seal_text(first, "ghp_expected-to-survive").unwrap();
        let image = store
            .seal_image(first, vec![0x89, b'P', b'N', b'G', 0, 1, 2, 3])
            .unwrap();
        assert!(store.mark_chip_concealed(token, "receipt-42".into()));
        assert!(store.sync_document(
            first,
            vec![
                Segment::Ink("# dep**loy** notes\n".into()),
                Segment::Chip(token),
                Segment::Ink("\ntrailing \u{1F511} ink".into()),
                Segment::Chip(image),
            ],
        ));
        let second = store.new_tab().unwrap().1;
        assert!(store.sync_document(second, vec![Segment::Ink("errands".into())]));
        let doomed = store.new_tab().unwrap().1;
        assert!(store.sync_document(doomed, vec![Segment::Ink("old thoughts".into())]));
        assert!(store.close_tab(slot(&store, doomed)));
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

        // OTSSNAP4 stores no content-derived title at all: the string
        // is absent from the bytes and comes back recomputed from the
        // restored segments (ADR-0017).
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
            revived.tabs().next().unwrap().label(0),
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
        assert_eq!(chips[1].excerpt(), "PNG image");
        assert!(chips[1].conceal().is_none());

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
        let id = store.new_tab().unwrap().1;
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

    /// A page whose newest change was a deletion, past the ceremony:
    /// two lines written at 10:00, the second cut at 11:00, and the
    /// history discarded. The stamps are injected rather than raced off
    /// the wall clock, because the whole question is which of two hours
    /// the page comes back holding.
    fn page_cut_after_it_was_written() -> (SheetStore<ManualClock>, ManualClock, SheetId) {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
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

        // The ceremony destroyed the ops that proved the 11:00 cut and
        // no surviving character can vote for it, so the file is the
        // only place that stamp can live between launches.
        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(revived.restore(&snapshot, wall).unwrap(), 1);
        let sheet = revived.sheets().next().unwrap();
        assert_eq!(
            sheet.modified_s(),
            Some(39_600),
            "the page's newest change survived the relaunch"
        );

        // And it stayed the page's: no paragraph was made to claim a
        // change that never touched it (ADR-0013).
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

        // The trailing field cut away: what an installed build wrote,
        // and what this one now reads as absent. The file must open
        // rather than refuse — refusing costs the reader the page,
        // which is a far worse answer than costing them an hour on a
        // timestamp.
        let older = without_the_page_floor(&snapshot, floor_len(store.sheet(id).unwrap()));
        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(revived.restore(&older, wall).unwrap(), 1);
        let sheet = revived.sheets().next().unwrap();
        assert_eq!(sheet.segments(), [Segment::Ink("hello\n".into())]);
        let metas = sheet.blocks_meta();
        assert_eq!(
            metas[0], honest[0],
            "the frozen block's identity and stamps are the file's, floor or no floor"
        );
        // The trailing empty paragraph froze nothing, so it has no
        // record to be adopted from and comes back newly named, exactly
        // as it does from a file this build wrote.
        assert_eq!(metas.len(), honest.len());
        assert_eq!(metas[1].created_s, None);
        assert_eq!(
            sheet.modified_s(),
            Some(36_000),
            "with no floor in the file the page rests on its summaries, \
             which is exactly what the build that wrote it did"
        );
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
        let id = store.new_tab().unwrap().1;
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

        // The rung gesture runs the ceremony; everything after asserts
        // against the compacted page.
        store.cycle_rung(slot(&store, id)).unwrap();
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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

        // Tamper the way a hand-edited file would: stamps from the far
        // future and the deep past on block 0, and an anchor on block 1
        // that resolves nowhere.
        {
            let records = store.tabs[0].page.as_mut().unwrap().blocks.records_mut();
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
    fn a_tab_name_is_written_down_and_the_pages_own_title_is_not() {
        // The two strings the split separates, in one file. One is the
        // user's and is durable; the other is the app's and dies with
        // the page it was made from.
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
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

        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 0).unwrap();
        let tab = revived.tabs().next().unwrap();
        assert_eq!(tab.name(), Some("quarterly numbers"));
        assert_eq!(tab.label(0), "quarterly numbers");
        assert_eq!(
            tab.page().unwrap().derived_title(),
            Some("something else"),
            "recomputed from the restored segments, not read back"
        );
    }

    #[test]
    fn a_two_tab_strip_round_trips_with_its_names_rungs_and_order() {
        let (mut store, clock) = store();
        let named = store.new_tab().unwrap().1;
        let unnamed = store.new_tab().unwrap().1;
        assert!(store.set_title(slot(&store, named), "quarterly numbers"));
        store.set_rung(slot(&store, named), Ttl::MIN).unwrap();
        assert!(store.sync_document(unnamed, vec![Segment::Ink("errands".into())]));

        let snapshot = store.snapshot(0);
        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(revived.restore(&snapshot, 0).unwrap(), 2);

        let tabs: Vec<&Tab> = revived.tabs().collect();
        assert_eq!(tabs.len(), 2);
        assert_eq!(tabs[0].name(), Some("quarterly numbers"));
        assert_eq!(tabs[0].rung(), Ttl::MIN);
        assert_eq!(tabs[0].label(0), "quarterly numbers");
        assert_eq!(tabs[1].name(), None, "an unnamed tab stays unnamed");
        assert_eq!(tabs[1].rung(), Ttl::default());
        assert_eq!(tabs[1].label(0), "errands", "its page supplies the label");
        // Identity is what persists, for the slot as much as the page.
        let before: Vec<ItemId> = store.tabs().map(Tab::uuid).collect();
        assert_eq!(revived.tabs().map(Tab::uuid).collect::<Vec<_>>(), before);
    }

    #[test]
    fn an_emptied_strip_reseals_as_names_rungs_and_order_with_no_content() {
        // ADR-0016 section 6's first rotation trigger, from the file's
        // side: when the last page expires and tabs remain, emptying
        // the pad writes a file rather than removing one, and what it
        // writes is the strip and nothing else.
        let (mut store, clock) = store();
        let first = store.new_tab().unwrap().1;
        let second = store.new_tab().unwrap().1;
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

        let mut revived = SheetStore::new(clock.clone());
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
        // Nothing in this build writes an absent page yet, so the file
        // is assembled by hand: the flag is the whole of the difference
        // between a slot with a page and a slot without one.
        let (mut store, survivor) = occupied();
        let empty = empty_tab_snapshot(Some("payroll"));
        assert_eq!(store.restore(&empty, 0).unwrap(), 0, "no live page");
        let tabs: Vec<&Tab> = store.tabs().collect();
        assert_eq!(tabs.len(), 1, "the slot itself came back");
        assert!(tabs[0].page().is_none());
        assert_eq!(tabs[0].name(), Some("payroll"));
        assert_eq!(tabs[0].label(0), "payroll");
        assert_eq!(tabs[0].rung(), Ttl::from_secs(8 * 60 * 60).unwrap());
        assert!(
            store.sheet(survivor).is_none(),
            "the restore replaced the strip, as any restore does"
        );
        // A tab with no page schedules nothing.
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
        // The flag promises a page and the frame carries no bytes. The
        // two disagree, and the disagreement is the damage.
        let (mut store, survivor) = occupied();
        let mut hostile = empty_tab_snapshot(Some("payroll"));
        let flag = hostile.len() - 1;
        hostile[flag] = 1;
        hostile.extend_from_slice(&0u64.to_le_bytes()); // an empty frame
        // Both enclosing lengths have to admit the eight new bytes, or
        // the reject would be about the frame rather than the flag.
        widen_first_tab(&mut hostile, 8);
        assert_eq!(store.restore(&hostile, 0), Err(RestoreError::Malformed));
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");
    }

    #[test]
    fn a_hand_edited_tab_name_is_recapped_at_eighty_characters() {
        // The re-cap is load-bearing after the split: this string is
        // durable and reaches the ledger through every record the tab's
        // pages produce, so a file must not smuggle a longer one in.
        let (mut store, _survivor) = occupied();
        let long: String = "é".repeat(200);
        let snapshot = empty_tab_snapshot(Some(&long));
        assert_eq!(store.restore(&snapshot, 0).unwrap(), 0);
        let name = store.tabs().next().unwrap().name().unwrap();
        assert_eq!(name.chars().count(), TITLE_CAP);
        assert_eq!(name.len(), TITLE_CAP * 2, "counted in chars, not bytes");
    }

    #[test]
    fn a_strip_wider_than_the_cap_is_malformed() {
        // The writer never produces more than the cap, and the cap is
        // the tab's lifetime bound now, so a file that claims a wider
        // strip is damage or a hand edit.
        let (mut store, survivor) = occupied();
        let cap = store.cap();
        let mut hostile = Vec::new();
        hostile.extend_from_slice(MAGIC);
        hostile.extend_from_slice(&0u64.to_le_bytes());
        hostile.extend_from_slice(&((cap + 1) as u64).to_le_bytes());
        for _ in 0..=cap {
            hostile.extend_from_slice(&frame(&tab_record(None, None)));
        }
        assert_eq!(store.restore(&hostile, 0), Err(RestoreError::Malformed));
        let ids: Vec<SheetId> = store.sheets().map(Sheet::id).collect();
        assert_eq!(ids, vec![survivor], "the failed restore touched the store");

        // Exactly the cap is not damage: the boundary belongs to the
        // side that the writer can actually reach.
        let mut full = Vec::new();
        full.extend_from_slice(MAGIC);
        full.extend_from_slice(&0u64.to_le_bytes());
        full.extend_from_slice(&(cap as u64).to_le_bytes());
        for _ in 0..cap {
            full.extend_from_slice(&frame(&tab_record(None, None)));
        }
        assert_eq!(store.restore(&full, 0).unwrap(), 0);
        assert_eq!(store.tabs().count(), cap);
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

        // A ledger restore leaves the strip alone, in both directions.
        assert!(revived.has_no_tabs());
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

    /// A ledger file arrives second at launch, after the content
    /// restore has already entombed the deaths that fell due while the
    /// app was closed. Those records are in the deque and in no file,
    /// so the load has to join them rather than write over them.
    #[test]
    fn a_ledger_restore_keeps_the_records_the_store_already_holds() {
        let (original, clock, ..) = populated();
        let file = original.ledger_snapshot();
        let earlier: Vec<LedgerRecord> = original.ledger().cloned().collect();

        // A death recorded before the file lands, which is the shape of
        // what `expire_due` leaves behind on the way in.
        let mut revived = SheetStore::new(clock.clone());
        let doomed = revived.new_tab().unwrap().1;
        assert!(revived.sync_document(doomed, vec![Segment::Ink("overnight".into())]));
        assert!(revived.close_tab(slot(&revived, doomed)));
        let overnight: Vec<LedgerRecord> = revived.ledger().cloned().collect();
        assert_eq!(overnight.len(), 2, "the page was created, then it died");

        let kept = revived.restore_ledger(&file, 0).unwrap();
        assert_eq!(kept, overnight.len() + earlier.len());
        let records: Vec<LedgerRecord> = revived.ledger().cloned().collect();
        assert_eq!(
            records,
            [overnight.as_slice(), earlier.as_slice()].concat(),
            "the trail reads newest first, with the file's own order kept"
        );

        // The same file twice is the same trail: nothing already in
        // hand is taken from it a second time.
        assert_eq!(revived.restore_ledger(&file, 0).unwrap(), kept);
        assert_eq!(revived.ledger().cloned().collect::<Vec<_>>(), records);
    }

    /// One ledger record, every field pinned so two calls with the same
    /// arguments compare fully equal. The identity is passed in rather
    /// than minted so a caller can hand the same page's id to several.
    fn ledger_record(item: ItemId, at_wall_ms: u64) -> LedgerRecord {
        LedgerRecord {
            event: LedgerEvent::Sent,
            item,
            title: String::from("a page"),
            at_wall_ms,
            item_created_wall_ms: at_wall_ms,
            size: SizeClass::Tiny,
            destination: DestinationClass::Clipboard,
        }
    }

    /// A ledger file carrying exactly the given records, in order.
    fn ledger_file(records: &[LedgerRecord]) -> Zeroizing<Vec<u8>> {
        let (mut store, _) = store();
        store.ledger = records.iter().cloned().collect();
        store.ledger_snapshot()
    }

    #[test]
    fn a_ledger_restore_unions_duplicate_records_as_a_multiset() {
        // Two byte-identical records (same millisecond, same item,
        // equal in every field) are two things that happened, and a
        // merge must keep both rather than collapse them to one. The
        // deque starts holding one copy; a file of two then adds the
        // surplus, spending its single live twin and keeping the other,
        // the way a multiset union does.
        let item = ItemId::random();
        let r = ledger_record(item, 1_800_000_000_000);
        let one = ledger_file(std::slice::from_ref(&r));
        let two = ledger_file(&[r.clone(), r.clone()]);

        let (mut store, _) = store();
        assert_eq!(store.restore_ledger(&one, 0).unwrap(), 1);
        assert_eq!(
            store.restore_ledger(&two, 0).unwrap(),
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
        let id = store.new_tab().unwrap().1;
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
        store.new_tab().unwrap();
        clock.advance(Duration::from_millis(crate::LEDGER_RETENTION_MS));
        store.new_tab().unwrap();
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
        store.next_tab_id = 7_700;
        store.next_sheet_id = 4_242;
        store.next_chip_id = 9_100;
        let first = store.new_tab().unwrap().1;
        store.seal_text_at(first, "one", 0, 0).unwrap();
        store.seal_text_at(first, "two", 1, 0).unwrap();
        let second = store.new_tab().unwrap().1;
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
        let tab_ids: Vec<u64> = revived.tabs().map(|t| t.id().raw()).collect();
        assert_eq!(tab_ids, vec![1, 2], "the tab counter re-mints too");
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
        let fresh = revived.new_tab().unwrap().1;
        assert_eq!(fresh.raw(), 3);
        assert_eq!(revived.tabs().last().unwrap().id().raw(), 3);
        let fresh_chip = revived.seal_text(fresh, "four").unwrap();
        assert_eq!(fresh_chip.raw(), 4);
    }

    /// A record as the writer frames it: its own byte length, then its
    /// fields.
    fn frame(record: &[u8]) -> Vec<u8> {
        let mut out = (record.len() as u64).to_le_bytes().to_vec();
        out.extend_from_slice(record);
        out
    }

    /// The `u64` length at the front of `bytes`, as a usize.
    fn le_u64(bytes: &[u8]) -> usize {
        usize::try_from(u64::from_le_bytes(
            bytes[..8].try_into().expect("eight bytes"),
        ))
        .expect("a length this test wrote")
    }

    /// The same bytes, written the way a later build that appended one
    /// field to the first record would write them: `header` is the
    /// preamble before that record's length prefix, and the new field
    /// lands inside the record's own length, where this build's reader
    /// must step over it to reach the record after.
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

    /// The same, for the first page record, which sits inside its
    /// tab's frame: the field lands inside the page's own length, and
    /// the tab's length is re-stated to cover it.
    fn with_page_tail(snapshot: &[u8], extra: &[u8]) -> Vec<u8> {
        let tab = first_tab(snapshot);
        let mut rebuilt = tab[..UNNAMED_TAB_PREFIX].to_vec();
        rebuilt.extend_from_slice(&with_trailing_field(&tab[UNNAMED_TAB_PREFIX..], 0, extra));
        with_first_tab(snapshot, &rebuilt)
    }

    /// The same, for the first materialized record, which sits four
    /// lengths deep: its own, the metadata slot's, the page record's
    /// and the tab record's. The slot is located from the end of the
    /// page record, stepping back over the page-level floor field that
    /// trails it and then over `meta_len`, and the floor is put back
    /// where it was.
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
        // The slot's own preamble is a record count, then the records.
        let slot = with_trailing_field(&page[slot_at..page.len() - floor_len], 8, extra);
        let mut rebuilt_page = page[..slot_at - 8].to_vec();
        rebuilt_page.extend_from_slice(&frame(&slot));
        rebuilt_page.extend_from_slice(&page[page.len() - floor_len..]);
        let mut rebuilt_tab = tab[..UNNAMED_TAB_PREFIX].to_vec();
        rebuilt_tab.extend_from_slice(&frame(&rebuilt_page));
        with_first_tab(snapshot, &rebuilt_tab)
    }

    /// The same page record with its trailing floor field cut away:
    /// the file a build that never wrote that field would have left
    /// behind, which this build must still open.
    fn without_the_page_floor(snapshot: &[u8], floor_len: usize) -> Vec<u8> {
        let tab = first_tab(snapshot);
        let page_len = le_u64(&tab[UNNAMED_TAB_PREFIX..]);
        let page_at = UNNAMED_TAB_PREFIX + 8;
        let page = &tab[page_at..page_at + page_len];
        let mut rebuilt_tab = tab[..UNNAMED_TAB_PREFIX].to_vec();
        rebuilt_tab.extend_from_slice(&frame(&page[..page.len() - floor_len]));
        with_first_tab(snapshot, &rebuilt_tab)
    }

    /// How wide the page record's trailing floor field is as the writer
    /// just wrote it: one tag byte, and eight more behind it when the
    /// tag says a stamp follows.
    fn floor_len(sheet: &Sheet) -> usize {
        1 + usize::from(sheet.blocks.compaction_frontier().is_some()) * 8
    }

    /// The fixed span at the front of a tab record for a tab nobody
    /// named: identity, the slot's birthday, the absent-name flag, the
    /// rung, and the page-present flag. The page's own frame starts
    /// straight after it, which is how the tests below reach in.
    const UNNAMED_TAB_PREFIX: usize = 16 + 8 + 1 + 8 + 1;

    /// One hand-assembled tab record: a name when the user typed one,
    /// and a page body when the slot holds one. The writer cannot
    /// produce a roster that disagrees with its own document, nor (in
    /// this stage) a slot holding nothing, so the trust-boundary tests
    /// build their bytes by hand.
    fn tab_record(name: Option<&str>, page: Option<&[u8]>) -> Vec<u8> {
        tab_record_with_rung(name, 8 * 60 * 60, page)
    }

    /// The same, on a rung the test chooses: the rung is what bounds
    /// the life the page inside it may claim, so a test about that
    /// bound has to be able to write a short one.
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

    /// A whole v4 snapshot holding exactly one tab record.
    fn one_tab_snapshot(tab: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&0u64.to_le_bytes()); // saved wall stamp
        out.extend_from_slice(&1u64.to_le_bytes()); // one tab
        out.extend_from_slice(&frame(tab));
        out
    }

    /// A snapshot holding one tab that holds no page.
    fn empty_tab_snapshot(name: Option<&str>) -> Vec<u8> {
        one_tab_snapshot(&tab_record(name, None))
    }

    /// One hand-assembled page record carrying the clock bytes the test
    /// wrote: no chips, the given document blob, an empty metadata slot.
    /// The writer can only ever emit a clock it computed itself, so a
    /// test about a clock nobody in this process wrote builds its own.
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

    /// A hand-assembled v4 snapshot holding one unnamed tab and, inside
    /// it, one page: the given chip records, the given document blob,
    /// and an empty metadata slot.
    fn sheet_snapshot(chips: &[(ItemId, &str)], blob: &[u8]) -> Vec<u8> {
        sheet_snapshot_with_tails(chips, blob, &[])
    }

    /// The same, written the way a later build that added a field to
    /// the end of every chip record would write it.
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

    /// Grow the first tab record's stated length by `extra`, for a test
    /// that appended bytes inside it: the record's own frame is the one
    /// length that has to admit them.
    fn widen_first_tab(snapshot: &mut [u8], extra: usize) {
        let at = MAGIC.len() + 16;
        let len = le_u64(&snapshot[at..]) + extra;
        snapshot[at..at + 8].copy_from_slice(&(len as u64).to_le_bytes());
    }

    /// The first tab's record, without its length prefix.
    fn first_tab(snapshot: &[u8]) -> &[u8] {
        let at = MAGIC.len() + 16;
        let len = le_u64(&snapshot[at..]);
        &snapshot[at + 8..at + 8 + len]
    }

    /// The same snapshot with the first tab's record replaced, which
    /// re-states its length for whatever the replacement did inside it.
    fn with_first_tab(snapshot: &[u8], rebuilt: &[u8]) -> Vec<u8> {
        let at = MAGIC.len() + 16;
        let len = le_u64(&snapshot[at..]);
        let mut out = snapshot[..at].to_vec();
        out.extend_from_slice(&frame(rebuilt));
        out.extend_from_slice(&snapshot[at + 8 + len..]);
        out
    }

    /// A store holding one live page, and that page's id: the fixture
    /// every rejection test asserts survived the failed restore.
    fn occupied() -> (SheetStore<ManualClock>, SheetId) {
        let (mut store, _clock) = store();
        let survivor = store.new_tab().unwrap().1;
        (store, survivor)
    }

    // The skip rule, once per record kind (issue #54). Each test writes
    // the buffer a later build would write, with one field this build
    // has never heard of on the end of the first record, and asserts
    // that the record after it is still found. Refusing here is the
    // failure the rule exists to prevent: it would mean the next added
    // field costs everyone their staged content again.

    #[test]
    fn a_trailing_field_on_a_tab_record_is_skipped_not_refused() {
        let (original, clock, first, second) = populated();
        let snapshot = original.snapshot(1_000_000);
        let extended = with_trailing_field(&snapshot, MAGIC.len() + 16, b"a tab field from 2027");

        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(revived.restore(&extended, 1_000_000).unwrap(), 2);
        let order: Vec<SheetId> = revived.sheets().map(Sheet::id).collect();
        assert_eq!(
            order,
            vec![first, second],
            "the tab after the unknown field was not found"
        );
        assert_eq!(revived.tabs().next().unwrap().label(0), "deploy notes");
    }

    #[test]
    fn a_trailing_field_on_a_page_record_is_skipped_not_refused() {
        let (original, clock, first, second) = populated();
        let snapshot = original.snapshot(1_000_000);
        let extended = with_page_tail(&snapshot, b"a page field from 2027");

        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(revived.restore(&extended, 1_000_000).unwrap(), 2);
        let order: Vec<SheetId> = revived.sheets().map(Sheet::id).collect();
        assert_eq!(
            order,
            vec![first, second],
            "the tab after the extended page was not found"
        );

        // The known fields of the extended record read exactly as they
        // did, sealed bytes included: the tail is skipped, not absorbed.
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
        let snapshot = sheet_snapshot_with_tails(
            &[(uuid, "ghp_still-here")],
            &doc.export_snapshot(),
            b"a chip field from 2027",
        );

        assert_eq!(store.restore(&snapshot, 0).unwrap(), 1);
        let chip = store.sheets().next().unwrap().chips().next().unwrap();
        assert_eq!(chip.uuid(), uuid);
        // The document blob follows the chip roster, so a reader that
        // walked into the unknown field would have lost the blob too.
        let (bytes, _) = store.copy_out_chip(chip.id()).unwrap();
        assert_eq!(&*bytes, b"ghp_still-here");
    }

    #[test]
    fn a_trailing_field_on_a_materialized_record_is_skipped_not_refused() {
        use crate::store::EditOp;
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
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

        let mut revived = SheetStore::new(clock.clone());
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

        let mut revived = SheetStore::new(clock.clone());
        assert_eq!(
            revived.restore_ledger(&extended, 0).unwrap(),
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
        // ADR-0012 line 32: no sequential counter reaches a persisted
        // artifact. Ids chosen so their little-endian bytes cannot occur
        // by chance in a length, a span, or a wall stamp.
        const SHEET_RAW: u64 = 0x1234_5678_9ABC_DEF0;
        const CHIP_RAW: u64 = 0x0FED_CBA9_8765_4321;
        const TAB_RAW: u64 = 0x2143_6587_A9CB_ED0F;
        let (mut store, _clock) = store();
        store.next_tab_id = TAB_RAW;
        store.next_sheet_id = SHEET_RAW;
        store.next_chip_id = CHIP_RAW;
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1;
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
        let id = store.new_tab().unwrap().1; // 8h default rung
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
        let id = store.new_tab().unwrap().1;
        assert!(store.sync_document(id, vec![Segment::Ink("perishable".into())]));
        let snapshot = store.snapshot(0);

        let nine_hours_ms = 9 * 60 * 60 * 1000;
        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, nine_hours_ms).unwrap();
        let expired = revived.expire_due();
        assert_eq!(expired, vec![id]);
        // The page is gone and its slot is still standing, which is
        // what an overnight expiry looks like at the 09:00 relaunch.
        assert!(revived.holds_no_page());
        assert_eq!(revived.tabs().count(), 1);
        let record = revived.ledger().next().unwrap();
        assert_eq!(record.event(), LedgerEvent::Expired);
        assert_eq!(record.title(), "perishable");
    }

    #[test]
    fn a_hold_absorbs_time_away_before_the_countdown_drains() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        assert!(store.pause_press(slot(&store, id))); // 1h hold, 8h frozen
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

    /// A hold that lapsed while the app was still open is life the page
    /// has already spent, and the snapshot has to say so. Writing the
    /// held triple verbatim hands the frozen span back whole at the
    /// next launch: the page reads dead on screen all evening, is saved
    /// on quit like any other, and comes back in the morning with hours
    /// of life it finished spending days ago. The writer owes what
    /// every other reader of the clock already believes, which is
    /// [`Sheet::remaining`].
    #[test]
    fn a_snapshot_of_a_lapsed_hold_keeps_the_life_it_already_drained() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        clock.advance(2 * HOUR); // 6h left on the 8h rung
        assert!(store.pause_press(slot(&store, id))); // a 1h hold over 6h
        clock.advance(4 * HOUR); // the hold lapsed 3h ago, and 3h drained
        let left = store.sheet(id).unwrap().remaining(store.now());
        assert_eq!(left, 3 * HOUR, "the live reading is not the thing on trial");
        let snapshot = store.snapshot(0);

        // No time away at all, so what the page comes back holding is
        // what the writer wrote down rather than what a gap charged it.
        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 0).unwrap();
        let now = revived.now();
        let sheet = revived.sheet(id).unwrap();
        assert!(!sheet.is_held(now), "a hold that lapsed came back live");
        assert_eq!(sheet.remaining(now), left, "the overhang was handed back");

        // And a page whose frozen life ran out under the lapsed hold
        // comes back dead, rather than resurrected for a second span.
        clock.advance(3 * HOUR);
        assert_eq!(
            store.sheet(id).unwrap().remaining(store.now()),
            Duration::ZERO
        );
        let snapshot = store.snapshot(0);
        let mut revived = SheetStore::new(clock.clone());
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
        // The tier is the whole reason the gesture is reversible: a
        // topped-up hold that came back as a first hold would answer
        // the next double-click with another 24 hours instead of the
        // release the user asked for.
        let (mut store, clock) = store();
        let first = store.new_tab().unwrap().1;
        let topped = store.new_tab().unwrap().1;
        assert!(store.pause_press(slot(&store, first))); // 1h hold
        assert!(store.pause_press(slot(&store, topped))); // 1h hold
        assert!(store.pause_press(slot(&store, topped))); // topped up to 24h
        let snapshot = store.snapshot(0);

        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 30 * 60 * 1000).unwrap();
        let now = revived.now();
        assert!(revived.sheet(first).unwrap().is_held(now));
        assert!(!revived.sheet(first).unwrap().hold_topped_up(now));
        assert!(revived.sheet(topped).unwrap().hold_topped_up(now));

        // And the press that follows the restore does what the tier
        // promises: the first-hold page tops up, the topped-up one
        // releases.
        assert!(revived.pause_press(slot(&revived, first)));
        assert!(revived.pause_press(slot(&revived, topped)));
        let now = revived.now();
        assert!(revived.sheet(first).unwrap().hold_topped_up(now));
        assert!(!revived.sheet(topped).unwrap().is_held(now));
    }

    #[test]
    fn a_backwards_wall_clock_grants_no_extra_life() {
        let (mut store, clock) = store();
        let id = store.new_tab().unwrap().1;
        clock.advance(2 * HOUR); // 6h left on the 8h rung
        let snapshot = store.snapshot(1_000_000_000);

        let mut revived = SheetStore::new(clock.clone());
        revived.restore(&snapshot, 5).unwrap(); // wall clock moved back
        let remaining = revived.sheet(id).unwrap().remaining(revived.now());
        assert_eq!(remaining, 6 * HOUR);
    }

    /// Seven days is the top of the ladder, so seven days is the most
    /// life any restored page may hold, and a page on a shorter rung may
    /// hold no more than that rung (ADR-0016 section 10, case 7). The
    /// honest write path satisfies this by construction: every rung
    /// click sets the deadline to the rung's own duration and restore
    /// only ever subtracts. The file is where it can stop being true,
    /// because the span is the one number a stale or hand-edited
    /// generation can move (ADR-0016 section 8), so the span is read
    /// against the rung rather than at face value.
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

        // The ladder's own ceiling, asked for by a file claiming a month.
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
            Duration::from_secs(7 * 24 * 60 * 60),
            "a file claiming a month of life was believed"
        );

        // And the same page on the 1h rung is bounded by the rung it
        // was actually written on, not merely by the top of the ladder.
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
            HOUR,
            "an hour's page came back with more than an hour"
        );
    }

    /// The same ceiling on the held arm, which is the way past it that
    /// costs nothing to write: a hold freezes a remaining span, and a
    /// frozen span read at face value would hand a paused page a month
    /// of life the moment its hold lapsed.
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
            HOUR,
            "a hold froze more life than the rung ever held"
        );
    }

    /// A hold suspends the countdown, so a hold read at face value is
    /// the cheapest way past the ladder there is: the frozen span can
    /// be clamped to the rung and the plaintext still survives for as
    /// long as the hold claims, because a held page is never due
    /// (ADR-0016 section 8). The pause gesture is the only thing that
    /// sets a hold, so a hold out of a file is read against the same
    /// ceiling the gesture would have applied: one hour for a first
    /// hold, 24 for one already topped up.
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

        // A first hold claiming a month, on the one hour rung: the hold
        // comes back an hour long, and an hour after that the frozen
        // span (itself bounded by the rung) runs out and the page is
        // reaped rather than sitting on its plaintext for a month.
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
        clock.advance(HOUR);
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

        // Tag 2 is a hold already topped up, and its ceiling is the
        // top-up's 24 hours: the clamp must not shorten it to the first
        // hold's hour, which is the honest 24 hour hold the rung has no
        // business describing.
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
        // The format break is clean and deliberate (decided 2026-08-07,
        // taken again for v4): there is no reader for a superseded
        // version and no downgrade writer, so every earlier magic and
        // every unknown one refuses the same way, with the store
        // untouched. The skip rule changes nothing here. It buys a
        // trailing field inside a record and buys nothing across a
        // version byte. The ledger's own superseded version is the one
        // exception, and it is a different name for the same refusal,
        // see the test after this one.
        let (original, _clock, ..) = populated();
        let (mut revived, survivor) = occupied();
        for magic in [
            b"OTSSNAP1",
            b"OTSSNAP2",
            b"OTSSNAP3",
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

        // The ledger takes the same rule for a version this module never
        // wrote: `OTSLEDR0` refuses as unknown, store untouched.
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

    /// The one ledger version this module wrote and replaced is refused
    /// too, there being no reader for it and no downgrade writer, but it
    /// is refused by name, so the caller holding the file can dispose of
    /// it instead of leaving it to withhold the ledger licence on every
    /// launch after the break (ADR-0016 section 9). The store is as
    /// untouched as for any other refusal.
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
            // Superseded is a name for a refusal, not a reader: the
            // bytes are not taken positionally or any other way.
            let after: Vec<LedgerRecord> = revived.ledger().cloned().collect();
            assert_eq!(before, after, "the refused restore touched the ledger");
        }
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
            revived.has_no_tabs(),
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

        // Whole buffers still restore, so the loop proved rejection and
        // not merely that nothing ever restores.
        assert_eq!(revived.restore(&snapshot, 7_000).unwrap(), 2);
        assert!(revived.restore_ledger(&ledger, 7_000).unwrap() > 0);
    }

    #[test]
    fn a_hostile_length_is_rejected_before_it_allocates() {
        let (_, clock, ..) = populated();
        let mut revived = SheetStore::new(clock.clone());

        // A tab count of u64::MAX, with no tabs behind it.
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

        // A tab record that claims u64::MAX bytes for itself. The
        // frame is the first thing read per record and the first thing
        // that has to disbelieve what it is told.
        let mut hostile_frame = Vec::new();
        hostile_frame.extend_from_slice(MAGIC);
        hostile_frame.extend_from_slice(&0u64.to_le_bytes());
        hostile_frame.extend_from_slice(&1u64.to_le_bytes());
        hostile_frame.extend_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(
            revived.restore(&hostile_frame, 0),
            Err(RestoreError::Malformed)
        );

        // And the page's own frame, one level in, told the same lie:
        // the nesting must not turn a claim into an assumption.
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

        // A name length of u64::MAX inside an otherwise plausible tab
        // record, so the lie is one the record's own frame contains.
        let mut tab = Vec::new();
        tab.extend_from_slice(ItemId::random().as_bytes());
        tab.extend_from_slice(&0u64.to_le_bytes()); // created_wall_ms
        tab.push(1); // a name follows
        tab.extend_from_slice(&u64::MAX.to_le_bytes()); // its claimed length
        assert_eq!(
            revived.restore(&one_tab_snapshot(&tab), 0),
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
}
