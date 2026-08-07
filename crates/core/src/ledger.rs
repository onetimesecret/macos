//! The ledger: what happened, never what was written (ADR-0012).
//!
//! Earlier revisions kept dead pages here as residue: verbatim ink and
//! chip tombstones carrying excerpts. ADR-0012 deletes that outright.
//! The ledger is now an audit trail, and the boundary is structural
//! rather than careful:
//!
//! - **No content.** A record carries an event, the item's random
//!   [`ItemId`](crate::ItemId) in the clear, timestamps, a
//!   [`SizeClass`], a [`DestinationClass`], and the page's title.
//!   There is no field a byte of ink or a chip excerpt could occupy.
//! - **The title is the one content-derived field**, and it is derived
//!   by the page, at edit time, capped at 80 characters, or set
//!   explicitly by the user. The ledger copies a name the page already
//!   owned; it never reads ink itself. The honest claim is
//!   "content-free by construction, except the capped title".
//! - **Long-lived, under its own key.** Unlike staged content, which
//!   dies with the boot session, the ledger persists across reboots
//!   under a separate long-lived keychain item. That is why records
//!   carry wall-clock stamps and why retention is a time window (see
//!   [`evict_expired`]).
//! - **Post-death recall of ink is gone on purpose.** If it is ever
//!   wanted as a feature it belongs in the content store, under the
//!   boot-bound key, with a TTL. It does not belong here.

use std::collections::VecDeque;

use crate::sheet::ItemId;

/// The retention window: 90 days of records, keyed on wall-clock time.
pub const LEDGER_RETENTION_MS: u64 = 90 * 24 * 60 * 60 * 1000;

/// What happened to an item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LedgerEvent {
    /// A page came into being.
    Created,
    /// Content was sealed into a chip.
    Sealed,
    /// Content left for a destination: the pasteboard, or a link.
    Sent,
    /// The countdown reached zero and the item was zeroized.
    Expired,
    /// The user removed the item before its countdown ran out.
    Discarded,
}

impl std::fmt::Display for LedgerEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            LedgerEvent::Created => "created",
            LedgerEvent::Sealed => "sealed",
            LedgerEvent::Sent => "sent",
            LedgerEvent::Expired => "expired",
            LedgerEvent::Discarded => "discarded",
        })
    }
}

/// How much content the event moved, bucketed so the exact byte count
/// (itself a weak fingerprint of the content) never reaches the record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SizeClass {
    /// Under 64 bytes.
    Tiny,
    /// Under 1 KiB.
    Small,
    /// Under 64 KiB.
    Medium,
    /// Under 1 MiB.
    Large,
    /// 1 MiB or more.
    Huge,
}

impl SizeClass {
    /// The bucket `bytes` falls in. Boundaries are exclusive upper
    /// bounds: 64 bytes is [`SizeClass::Small`], not [`SizeClass::Tiny`].
    #[must_use]
    pub fn of(bytes: usize) -> Self {
        match bytes {
            0..64 => SizeClass::Tiny,
            64..1024 => SizeClass::Small,
            1024..65536 => SizeClass::Medium,
            65536..1_048_576 => SizeClass::Large,
            _ => SizeClass::Huge,
        }
    }
}

impl std::fmt::Display for SizeClass {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            SizeClass::Tiny => "tiny",
            SizeClass::Small => "small",
            SizeClass::Medium => "medium",
            SizeClass::Large => "large",
            SizeClass::Huge => "huge",
        })
    }
}

/// Where content went, for the events that move it. The pasteboard is
/// this design's named existential risk, so egress to it is the single
/// most useful line in the ledger; recording it costs no content, only
/// the fact that it happened (ADR-0012).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DestinationClass {
    /// The event moved nothing out of the app.
    None,
    /// The system pasteboard.
    Clipboard,
    /// A one-time link.
    OneTimeLink,
}

impl std::fmt::Display for DestinationClass {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            DestinationClass::None => "none",
            DestinationClass::Clipboard => "clipboard",
            DestinationClass::OneTimeLink => "link",
        })
    }
}

/// One thing that happened, in metadata only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerRecord {
    pub(crate) event: LedgerEvent,
    pub(crate) item: ItemId,
    pub(crate) title: String,
    pub(crate) at_wall_ms: u64,
    pub(crate) item_created_wall_ms: u64,
    pub(crate) size: SizeClass,
    pub(crate) destination: DestinationClass,
}

impl LedgerRecord {
    /// What happened.
    #[must_use]
    pub fn event(&self) -> LedgerEvent {
        self.event
    }

    /// The item this record is about: a page's identity for page
    /// events, a chip's for chip events. The random UUID in the clear,
    /// with no digest and no salt, because it is already content-free.
    #[must_use]
    pub fn item(&self) -> ItemId {
        self.item
    }

    /// The owning page's title at the moment of the event. The single
    /// content-derived field in the whole record, capped at 80
    /// characters by the page that owns it.
    #[must_use]
    pub fn title(&self) -> &str {
        &self.title
    }

    /// When the event happened, in Unix epoch milliseconds.
    #[must_use]
    pub fn at_wall_ms(&self) -> u64 {
        self.at_wall_ms
    }

    /// When the item's owning page was created, in Unix epoch
    /// milliseconds. Chips do not carry a creation stamp of their own,
    /// so a chip event reports the page it was sealed onto: always at or
    /// before the chip's own birth, and enough to group a page's events
    /// in a reader.
    #[must_use]
    pub fn item_created_wall_ms(&self) -> u64 {
        self.item_created_wall_ms
    }

    /// How much content the event moved, bucketed.
    #[must_use]
    pub fn size(&self) -> SizeClass {
        self.size
    }

    /// Where the content went, for events that move it.
    #[must_use]
    pub fn destination(&self) -> DestinationClass {
        self.destination
    }
}

/// Drop every record older than the 90 day window, measured from
/// `now_wall_ms`.
///
/// **Why wall-clock time here, when every expiry path in this crate is
/// forbidden from touching it.** The rule elsewhere is absolute: a
/// secret's lifetime is measured on the monotonic clock, so no clock
/// step can extend it. Ledger records are the one deliberate exception,
/// documented in ADR-0012. They are meant to survive reboots, and an
/// `Instant` cannot: it is meaningless across a restart. So a record
/// must carry wall-clock time anyway, and retention has nothing else to
/// key on. The failure mode is bounded and benign in both directions: a
/// stepped clock leaves a metadata record alive slightly too long, or
/// kills it slightly early. Neither outcome extends the lifetime of a
/// secret, because no secret is in reach of this function.
///
/// Eviction runs where the ledger is already being touched: on load,
/// and on the write path. No timer exists for it, and none is wanted:
/// expired records sitting in a closed file are inert until something
/// reads them, and the read evicts them first.
pub(crate) fn evict_expired(ledger: &mut VecDeque<LedgerRecord>, now_wall_ms: u64) {
    let cutoff = now_wall_ms.saturating_sub(LEDGER_RETENTION_MS);
    ledger.retain(|record| record.at_wall_ms >= cutoff);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(at_wall_ms: u64) -> LedgerRecord {
        LedgerRecord {
            event: LedgerEvent::Created,
            item: ItemId::random(),
            title: String::from("a page"),
            at_wall_ms,
            item_created_wall_ms: at_wall_ms,
            size: SizeClass::Tiny,
            destination: DestinationClass::None,
        }
    }

    #[test]
    fn size_class_buckets_are_exclusive() {
        // Every boundary belongs to the bucket above it.
        assert_eq!(SizeClass::of(0), SizeClass::Tiny);
        assert_eq!(SizeClass::of(63), SizeClass::Tiny);
        assert_eq!(SizeClass::of(64), SizeClass::Small);
        assert_eq!(SizeClass::of(1023), SizeClass::Small);
        assert_eq!(SizeClass::of(1024), SizeClass::Medium);
        assert_eq!(SizeClass::of(65_535), SizeClass::Medium);
        assert_eq!(SizeClass::of(65_536), SizeClass::Large);
        assert_eq!(SizeClass::of(1_048_575), SizeClass::Large);
        assert_eq!(SizeClass::of(1_048_576), SizeClass::Huge);
        assert_eq!(SizeClass::of(usize::MAX), SizeClass::Huge);
    }

    #[test]
    fn retention_is_a_ninety_day_window_not_a_count() {
        let now = 1_800_000_000_000;
        let day = 24 * 60 * 60 * 1000;
        let mut ledger: VecDeque<LedgerRecord> = VecDeque::new();
        // Ten thousand records, all recent: a count-based cap would have
        // thrown most of them away. The window keeps every one.
        for _ in 0..10_000 {
            ledger.push_front(record(now - day));
        }
        evict_expired(&mut ledger, now);
        assert_eq!(ledger.len(), 10_000);

        // The boundary is inclusive at exactly 90 days; one millisecond
        // older falls off.
        ledger.push_front(record(now - LEDGER_RETENTION_MS));
        ledger.push_front(record(now - LEDGER_RETENTION_MS - 1));
        evict_expired(&mut ledger, now);
        assert_eq!(ledger.len(), 10_001);
    }

    #[test]
    fn a_wall_clock_that_stepped_backwards_evicts_nothing() {
        let mut ledger: VecDeque<LedgerRecord> = VecDeque::new();
        ledger.push_front(record(1_800_000_000_000));
        // `now` before every record: the cutoff saturates at zero rather
        // than wrapping and reaping the whole ledger.
        evict_expired(&mut ledger, 0);
        assert_eq!(ledger.len(), 1);
    }
}
