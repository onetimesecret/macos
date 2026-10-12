//! The ledger: what happened, never what was written (ADR-0012).
//! Metadata only: no field can hold ink or an excerpt; the page's capped
//! title is the one content-derived field.

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
/// never reaches the record.
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
    /// The bucket `bytes` falls in; boundaries belong to the bucket above.
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

    /// Stable JSON and shell-facing vocabulary for this class.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            SizeClass::Tiny => "tiny",
            SizeClass::Small => "small",
            SizeClass::Medium => "medium",
            SizeClass::Large => "large",
            SizeClass::Huge => "huge",
        }
    }
}

/// The Swift shell fails closed on labels outside this set
/// (`SealedBlockTests`), so a spelling change is a contract change.
impl std::fmt::Display for SizeClass {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Where content went, for the events that move it (ADR-0012).
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

    /// A page's identity for page events, a chip's for chip events.
    #[must_use]
    pub fn item(&self) -> ItemId {
        self.item
    }

    /// The owning page's title at the event, capped by the page.
    #[must_use]
    pub fn title(&self) -> &str {
        &self.title
    }

    /// When the event happened, in Unix epoch milliseconds.
    #[must_use]
    pub fn at_wall_ms(&self) -> u64 {
        self.at_wall_ms
    }

    /// When the owning page was created, in Unix epoch milliseconds; chip
    /// events report their page's stamp.
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

/// Drop every record older than the 90 day window before `now_wall_ms`.
/// Wall time because records outlive reboots (ADR-0012).
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
        for _ in 0..10_000 {
            ledger.push_front(record(now - day));
        }
        evict_expired(&mut ledger, now);
        assert_eq!(ledger.len(), 10_000);

        ledger.push_front(record(now - LEDGER_RETENTION_MS));
        ledger.push_front(record(now - LEDGER_RETENTION_MS - 1));
        evict_expired(&mut ledger, now);
        assert_eq!(ledger.len(), 10_001);
    }

    #[test]
    fn a_wall_clock_that_stepped_backwards_evicts_nothing() {
        let mut ledger: VecDeque<LedgerRecord> = VecDeque::new();
        ledger.push_front(record(1_800_000_000_000));
        evict_expired(&mut ledger, 0);
        assert_eq!(ledger.len(), 1);
    }
}
