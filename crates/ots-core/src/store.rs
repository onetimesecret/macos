//! The bounded, in-memory set of cells — the "cache".
//!
//! Bounded capacity is a feature, not a limitation (docs/00 §2.3): a small,
//! fixed number of slots you never scroll. Entries expire on their own; the
//! resting state is empty. Most-recent-on-top matches temporal locality.

use std::collections::VecDeque;
use std::sync::Arc;

use crate::cell::{CellId, CellKind, CellSummary, SleeperCell, TtlRung};
use crate::clock::Clock;
use crate::secret::SecretBuffer;

/// Default number of slots. Small on purpose; the exact count is an open
/// question (docs/00 §13.4).
pub const DEFAULT_CAPACITY: usize = 8;

/// What to drop when a full store must make room for a new cell.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum EvictionPolicy {
    /// Evict the cell closest to its own expiry — the most cache-coherent
    /// choice, since it was going to die soonest anyway. The default.
    #[default]
    NearestExpiry,
    /// Evict the oldest cell by insertion order.
    Oldest,
}

/// A bounded set of [`SleeperCell`]s, newest at the front. Expired cells are
/// swept lazily on every read and before every insert, so callers never see a
/// dead cell.
pub struct CellStore {
    cells: VecDeque<SleeperCell>,
    capacity: usize,
    policy: EvictionPolicy,
    clock: Arc<dyn Clock>,
    next_id: u64,
}

impl CellStore {
    /// Create a store with an explicit capacity and eviction policy.
    ///
    /// # Panics
    /// Panics if `capacity` is zero — a zero-slot cache cannot hold anything.
    #[must_use]
    pub fn new(clock: Arc<dyn Clock>, capacity: usize, policy: EvictionPolicy) -> Self {
        assert!(capacity > 0, "capacity must be at least 1");
        Self {
            cells: VecDeque::with_capacity(capacity),
            capacity,
            policy,
            clock,
            next_id: 1,
        }
    }

    /// Create a store with the default capacity and policy.
    #[must_use]
    pub fn with_clock(clock: Arc<dyn Clock>) -> Self {
        Self::new(clock, DEFAULT_CAPACITY, EvictionPolicy::default())
    }

    #[must_use]
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    #[must_use]
    pub fn policy(&self) -> EvictionPolicy {
        self.policy
    }

    /// Number of live cells (after sweeping expired ones).
    #[must_use]
    pub fn len(&mut self) -> usize {
        self.sweep_expired();
        self.cells.len()
    }

    /// Whether the store holds no live cells.
    #[must_use]
    pub fn is_empty(&mut self) -> bool {
        self.len() == 0
    }

    /// Ingest `secret` as a new cell at the given `rung`, returning its id.
    /// Sweeps expired cells first, then evicts per policy if still full.
    pub fn insert(&mut self, secret: SecretBuffer, kind: CellKind, rung: TtlRung) -> CellId {
        self.sweep_expired();
        if self.cells.len() >= self.capacity {
            self.evict_one();
        }

        let now = self.clock.now_ms();
        let id = CellId(self.next_id);
        self.next_id += 1;

        let cell = SleeperCell::new(id, secret, kind, rung, now);
        self.cells.push_front(cell);
        id
    }

    /// Remove every expired cell, returning their ids (each dropped cell wipes
    /// its secret). Cheap to call often.
    pub fn sweep_expired(&mut self) -> Vec<CellId> {
        let now = self.clock.now_ms();
        let mut evicted = Vec::new();
        self.cells.retain(|c| {
            if c.is_expired(now) {
                evicted.push(c.id());
                false
            } else {
                true
            }
        });
        evicted
    }

    /// Non-secret snapshot of all live cells, newest first.
    #[must_use]
    pub fn list(&mut self) -> Vec<CellSummary> {
        self.sweep_expired();
        let now = self.clock.now_ms();
        self.cells.iter().map(|c| c.summary(now)).collect()
    }

    /// Reset a cell to an explicit rung (re-based on now). Returns whether the
    /// cell was found.
    pub fn reset_ttl(&mut self, id: CellId, rung: TtlRung) -> bool {
        let now = self.clock.now_ms();
        match self.cells.iter_mut().find(|c| c.id() == id) {
            Some(cell) => {
                cell.set_rung(rung, now);
                true
            }
            None => false,
        }
    }

    /// Step a cell up the TTL ladder, returning the new rung (or `None` if the
    /// cell is gone).
    pub fn cycle_ttl(&mut self, id: CellId) -> Option<TtlRung> {
        let now = self.clock.now_ms();
        self.cells
            .iter_mut()
            .find(|c| c.id() == id)
            .map(|cell| cell.cycle_rung(now))
    }

    /// Evict a specific cell now, wiping its secret. Returns whether it existed.
    pub fn evict(&mut self, id: CellId) -> bool {
        if let Some(pos) = self.cells.iter().position(|c| c.id() == id) {
            self.cells.remove(pos);
            true
        } else {
            false
        }
    }

    /// Drop every cell, wiping all secrets. The safe default on quit (docs/00
    /// §10 — no silent persistence).
    pub fn clear(&mut self) {
        self.cells.clear();
    }

    /// Borrow a cell by id, for the in-core conceal path.
    pub(crate) fn get(&self, id: CellId) -> Option<&SleeperCell> {
        self.cells.iter().find(|c| c.id() == id)
    }

    /// Choose and remove one victim per the eviction policy.
    fn evict_one(&mut self) {
        let victim = match self.policy {
            EvictionPolicy::Oldest => self.cells.len().checked_sub(1),
            EvictionPolicy::NearestExpiry => self
                .cells
                .iter()
                .enumerate()
                .min_by_key(|(_, c)| c.expires_at_ms())
                .map(|(i, _)| i),
        };
        if let Some(i) = victim {
            self.cells.remove(i);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;

    fn store_at(
        start_ms: u64,
        cap: usize,
        policy: EvictionPolicy,
    ) -> (Arc<ManualClock>, CellStore) {
        let clock = Arc::new(ManualClock::new(start_ms));
        let store = CellStore::new(clock.clone(), cap, policy);
        (clock, store)
    }

    fn text(s: &str) -> SecretBuffer {
        SecretBuffer::from_text(s)
    }

    #[test]
    fn insert_puts_newest_on_top() {
        let (_clock, mut store) = store_at(0, 8, EvictionPolicy::NearestExpiry);
        let a = store.insert(text("first"), CellKind::Text, TtlRung::OneHour);
        let b = store.insert(text("second"), CellKind::Text, TtlRung::OneHour);
        let list = store.list();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].id, b, "newest first");
        assert_eq!(list[1].id, a);
    }

    #[test]
    fn expired_cells_are_swept() {
        let (clock, mut store) = store_at(0, 8, EvictionPolicy::NearestExpiry);
        store.insert(text("short"), CellKind::Text, TtlRung::OneHour);
        store.insert(text("long"), CellKind::Text, TtlRung::SevenDays);
        assert_eq!(store.len(), 2);

        clock.advance_secs(TtlRung::OneHour.seconds() + 1);
        let evicted = store.sweep_expired();
        assert_eq!(evicted.len(), 1);
        assert_eq!(store.len(), 1, "only the 7d cell survives");
    }

    #[test]
    fn capacity_is_bounded_and_evicts_nearest_expiry() {
        let (_clock, mut store) = store_at(0, 2, EvictionPolicy::NearestExpiry);
        let short = store.insert(text("short"), CellKind::Text, TtlRung::OneHour);
        let long = store.insert(text("long"), CellKind::Text, TtlRung::SevenDays);
        // Third insert with a mid TTL: the 1h cell is nearest expiry -> evicted.
        let mid = store.insert(text("mid"), CellKind::Text, TtlRung::EightHours);

        let ids: Vec<_> = store.list().iter().map(|c| c.id).collect();
        assert_eq!(store.len(), 2, "never exceeds capacity");
        assert!(ids.contains(&long));
        assert!(ids.contains(&mid));
        assert!(!ids.contains(&short), "nearest-expiry victim was evicted");
    }

    #[test]
    fn capacity_oldest_policy_evicts_by_insertion_order() {
        let (_clock, mut store) = store_at(0, 2, EvictionPolicy::Oldest);
        let a = store.insert(text("a"), CellKind::Text, TtlRung::SevenDays);
        let b = store.insert(text("b"), CellKind::Text, TtlRung::OneHour);
        let c = store.insert(text("c"), CellKind::Text, TtlRung::OneHour);
        let ids: Vec<_> = store.list().iter().map(|x| x.id).collect();
        assert!(!ids.contains(&a), "oldest evicted");
        assert!(ids.contains(&b));
        assert!(ids.contains(&c));
    }

    #[test]
    fn reset_and_cycle_ttl() {
        let (_clock, mut store) = store_at(0, 8, EvictionPolicy::NearestExpiry);
        let id = store.insert(text("v"), CellKind::Text, TtlRung::OneHour);

        assert!(store.reset_ttl(id, TtlRung::EightHours));
        assert_eq!(store.list()[0].rung, TtlRung::EightHours);

        assert_eq!(store.cycle_ttl(id), Some(TtlRung::TwentyFourHours));
        assert_eq!(store.list()[0].rung, TtlRung::TwentyFourHours);

        assert!(!store.reset_ttl(CellId(9999), TtlRung::OneHour));
        assert_eq!(store.cycle_ttl(CellId(9999)), None);
    }

    #[test]
    fn evict_and_clear() {
        let (_clock, mut store) = store_at(0, 8, EvictionPolicy::NearestExpiry);
        let id = store.insert(text("v"), CellKind::Text, TtlRung::OneHour);
        store.insert(text("w"), CellKind::Text, TtlRung::OneHour);
        assert!(store.evict(id));
        assert!(!store.evict(id), "already gone");
        assert_eq!(store.len(), 1);
        store.clear();
        assert!(store.is_empty());
    }

    #[test]
    #[should_panic(expected = "capacity must be at least 1")]
    fn zero_capacity_is_rejected() {
        let clock = Arc::new(ManualClock::new(0));
        let _ = CellStore::new(clock, 0, EvictionPolicy::NearestExpiry);
    }
}
