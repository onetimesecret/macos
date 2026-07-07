//! Time as an injected dependency, so TTL behaviour is testable without
//! sleeping and demoable at any speed.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A monotonic clock the store reads instead of calling
/// [`Instant::now`] directly.
pub trait Clock {
    /// The current monotonic instant.
    fn now(&self) -> Instant;
}

/// The real thing.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// A clock that only moves when told to — for tests and the demo.
#[derive(Debug, Clone)]
pub struct ManualClock {
    base: Instant,
    offset: Arc<Mutex<Duration>>,
}

impl ManualClock {
    /// A manual clock anchored at construction time.
    #[must_use]
    pub fn new() -> Self {
        Self {
            base: Instant::now(),
            offset: Arc::new(Mutex::new(Duration::ZERO)),
        }
    }

    /// Advance the clock by `delta`.
    ///
    /// # Panics
    ///
    /// Panics if the internal lock is poisoned (a prior panic mid-update).
    pub fn advance(&self, delta: Duration) {
        let mut offset = self.offset.lock().expect("clock lock poisoned");
        *offset += delta;
    }
}

impl Default for ManualClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for ManualClock {
    fn now(&self) -> Instant {
        let offset = self.offset.lock().expect("clock lock poisoned");
        self.base + *offset
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manual_clock_advances_only_when_told() {
        let clock = ManualClock::new();
        let t0 = clock.now();
        assert_eq!(clock.now(), t0);
        clock.advance(Duration::from_secs(90));
        assert_eq!(clock.now() - t0, Duration::from_secs(90));
    }

    #[test]
    fn manual_clock_clones_share_time() {
        let clock = ManualClock::new();
        let other = clock.clone();
        clock.advance(Duration::from_secs(5));
        assert_eq!(other.now(), clock.now());
    }
}
