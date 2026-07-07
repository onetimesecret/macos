//! A small monotonic clock abstraction.
//!
//! TTL math must be testable without sleeping and free of wall-clock surprises
//! (docs/01 §4). All time is a monotonic count of milliseconds from an
//! arbitrary base; production uses [`SystemClock`] (backed by [`Instant`]),
//! tests drive [`ManualClock`] by hand.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

/// A monotonic millisecond clock. Never goes backwards.
pub trait Clock: Send + Sync {
    /// Milliseconds elapsed since this clock's arbitrary base.
    fn now_ms(&self) -> u64;
}

/// Production clock: monotonic milliseconds since the process captured its base
/// [`Instant`]. Immune to wall-clock adjustments (NTP, DST, manual changes).
pub struct SystemClock {
    base: Instant,
}

impl SystemClock {
    #[must_use]
    pub fn new() -> Self {
        Self {
            base: Instant::now(),
        }
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        // `Instant` cannot exceed ~584 million years in u64 ms; the cast is safe.
        self.base.elapsed().as_millis() as u64
    }
}

/// Test clock: advances only when told to, so TTL and eviction can be driven
/// deterministically. Interior mutability via an atomic lets the store hold an
/// `Arc<dyn Clock>` while the test still advances time through its own handle.
pub struct ManualClock {
    ms: AtomicU64,
}

impl ManualClock {
    #[must_use]
    pub fn new(start_ms: u64) -> Self {
        Self {
            ms: AtomicU64::new(start_ms),
        }
    }

    /// Move time forward by `delta` milliseconds.
    pub fn advance_ms(&self, delta: u64) {
        self.ms.fetch_add(delta, Ordering::SeqCst);
    }

    /// Move time forward by `delta` seconds.
    pub fn advance_secs(&self, delta: u64) {
        self.advance_ms(delta.saturating_mul(1000));
    }
}

impl Clock for ManualClock {
    fn now_ms(&self) -> u64 {
        self.ms.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manual_clock_advances_monotonically() {
        let c = ManualClock::new(1_000);
        assert_eq!(c.now_ms(), 1_000);
        c.advance_ms(500);
        assert_eq!(c.now_ms(), 1_500);
        c.advance_secs(2);
        assert_eq!(c.now_ms(), 3_500);
    }

    #[test]
    fn system_clock_is_nondecreasing() {
        let c = SystemClock::new();
        let a = c.now_ms();
        let b = c.now_ms();
        assert!(b >= a);
    }
}
