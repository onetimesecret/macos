//! Time as an injected dependency, so TTL behaviour is testable without
//! sleeping and demoable at any speed.
//!
//! The real clock must keep counting **through system sleep**: the
//! countdown the user chose is wall time ("8h — a working day"), and a
//! page must not gain a weekend of life because the lid was closed.
//! `Instant::now()` reads a clock that freezes during sleep on Darwin
//! (`CLOCK_UPTIME_RAW`) and Linux (`CLOCK_MONOTONIC`), so
//! [`SystemClock`] anchors itself to a sleep-inclusive OS clock instead
//! — the `libc` calls below are the crate's one unsafe carve-out beyond
//! `secret.rs`/`harden.rs`, each a plain syscall with a SAFETY note.
#![allow(unsafe_code)]

use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// A monotonic clock the store reads instead of calling
/// [`Instant::now`] directly.
pub trait Clock {
    /// The current monotonic instant.
    fn now(&self) -> Instant;
}

/// The real thing: monotonic, and it keeps counting while the system
/// sleeps. Expiry is the promise (doc 03 §1) — in wall time.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        continuous_now()
    }
}

/// An [`Instant`] that advances during system sleep: a process-wide
/// anchor pairs one `Instant` with the sleep-inclusive OS clock, and
/// every reading is the anchor plus that clock's progress. `Instant`
/// stays the vocabulary everywhere else; only this function knows the
/// OS clock exists.
fn continuous_now() -> Instant {
    static ANCHOR: OnceLock<(Instant, u64)> = OnceLock::new();
    let (base, base_ns) = *ANCHOR.get_or_init(|| (Instant::now(), sleep_inclusive_ns()));
    base + Duration::from_nanos(sleep_inclusive_ns().saturating_sub(base_ns))
}

/// Nanoseconds of a monotonic clock that includes time asleep. On
/// Darwin `CLOCK_MONOTONIC` continues to increment while the system is
/// asleep (the frozen one is `CLOCK_UPTIME_RAW`, which `Instant` uses);
/// on Linux that role belongs to `CLOCK_BOOTTIME`.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn sleep_inclusive_ns() -> u64 {
    #[cfg(target_os = "macos")]
    const SLEEP_INCLUSIVE: libc::clockid_t = libc::CLOCK_MONOTONIC;
    #[cfg(target_os = "linux")]
    const SLEEP_INCLUSIVE: libc::clockid_t = libc::CLOCK_BOOTTIME;

    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `clock_gettime` writes to a valid, stack-allocated
    // timespec; the clock id is valid on its platform.
    unsafe {
        libc::clock_gettime(SLEEP_INCLUSIVE, &raw mut ts);
    }
    u64::try_from(ts.tv_sec).unwrap_or(0) * 1_000_000_000 + u64::try_from(ts.tv_nsec).unwrap_or(0)
}

/// Elsewhere: no portable sleep-inclusive clock — fall back to the
/// process-monotonic one (the pre-existing behaviour, status quo).
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn sleep_inclusive_ns() -> u64 {
    static FALLBACK_BASE: OnceLock<Instant> = OnceLock::new();
    let base = *FALLBACK_BASE.get_or_init(Instant::now);
    u64::try_from(base.elapsed().as_nanos()).unwrap_or(u64::MAX)
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

    #[test]
    fn system_clock_is_monotonic_and_tracks_real_elapsed_time() {
        // Sleep itself can't run in CI; what can be pinned is that the
        // synthesized instant never runs backwards and keeps pace with
        // the ordinary monotonic clock while awake.
        let clock = SystemClock;
        let (a, wall_a) = (clock.now(), Instant::now());
        let mut last = a;
        for _ in 0..1000 {
            let next = clock.now();
            assert!(next >= last, "the clock ran backwards");
            last = next;
        }
        let (b, wall_b) = (clock.now(), Instant::now());
        let skew = (b - a).abs_diff(wall_b - wall_a);
        assert!(
            skew < Duration::from_millis(50),
            "awake, the sleep-inclusive clock keeps pace: skew {skew:?}"
        );
    }
}
