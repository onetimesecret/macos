//! Time as an injected dependency. Local intervals use a sleep-inclusive
//! monotonic clock; wall time measures only the restart gap and the
//! replicated expiry policy, and either may shorten a life, never extend
//! it (ADR-0016, ADR-0021).
#![allow(unsafe_code)]

use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The clock the store reads instead of [`Instant::now`].
pub trait Clock {
    /// The current monotonic instant.
    fn now(&self) -> Instant;

    /// Unix epoch milliseconds: stamps, the restart gap and replicated
    /// expiry, never a locally observed interval.
    fn wall_ms(&self) -> u64;

    /// Seconds east of UTC now.
    fn local_offset_seconds(&self) -> i32;

    /// Seconds east of UTC at `wall_secs`, which may be in the future
    /// (ADR-0011 section 4 boundary snap).
    fn local_offset_seconds_at(&self, wall_secs: u64) -> i32 {
        let _ = wall_secs;
        self.local_offset_seconds()
    }
}

/// Monotonic, and keeps counting while the system sleeps.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        continuous_now()
    }

    fn wall_ms(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
    }

    fn local_offset_seconds(&self) -> i32 {
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        local_offset_seconds_at(secs)
    }

    fn local_offset_seconds_at(&self, wall_secs: u64) -> i32 {
        local_offset_seconds_at(wall_secs)
    }
}

/// Seconds east of UTC at `secs`, from the OS time zone database.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn local_offset_seconds_at(secs: u64) -> i32 {
    let time = libc::time_t::try_from(secs).unwrap_or(libc::time_t::MAX);
    // SAFETY: all-zero is a valid `tm`; `localtime_r` overwrites it.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are to live stack values for the call.
    unsafe {
        libc::localtime_r(&raw const time, &raw mut tm);
    }
    i32::try_from(tm.tm_gmtoff).unwrap_or(0)
}

/// No time zone query here: everything reads as UTC.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn local_offset_seconds_at(_secs: u64) -> i32 {
    0
}

/// An [`Instant`] that advances during system sleep: a process-wide
/// anchor plus the sleep-inclusive OS clock's progress since.
fn continuous_now() -> Instant {
    static ANCHOR: OnceLock<(Instant, u64)> = OnceLock::new();
    let (base, base_ns) = *ANCHOR.get_or_init(|| (Instant::now(), sleep_inclusive_ns()));
    base + Duration::from_nanos(sleep_inclusive_ns().saturating_sub(base_ns))
}

/// Nanoseconds of a monotonic clock that includes sleep: `CLOCK_MONOTONIC`
/// on Darwin (`Instant` uses `CLOCK_UPTIME_RAW`), `CLOCK_BOOTTIME` on Linux.
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
    // SAFETY: a valid clock id and a pointer to a live stack `timespec`.
    unsafe {
        libc::clock_gettime(SLEEP_INCLUSIVE, &raw mut ts);
    }
    u64::try_from(ts.tv_sec).unwrap_or(0) * 1_000_000_000 + u64::try_from(ts.tv_nsec).unwrap_or(0)
}

/// No sleep-inclusive clock here: falls back to process-monotonic time.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn sleep_inclusive_ns() -> u64 {
    static FALLBACK_BASE: OnceLock<Instant> = OnceLock::new();
    let base = *FALLBACK_BASE.get_or_init(Instant::now);
    u64::try_from(base.elapsed().as_nanos()).unwrap_or(u64::MAX)
}

/// A fixed November 2023 instant, so tests never read the host clock.
const MANUAL_CLOCK_BASE_WALL_MS: u64 = 1_700_000_000_000;

/// A [`ManualClock`]'s zone: a standing offset plus scheduled transitions.
#[derive(Debug, Default)]
struct ManualZone {
    offset_seconds: i32,
    /// `(from_secs, offset_seconds)`, ascending.
    transitions: Vec<(u64, i32)>,
}

impl ManualZone {
    fn offset_at(&self, secs: u64) -> i32 {
        self.transitions
            .iter()
            .rev()
            .find(|(from, _)| *from <= secs)
            .map_or(self.offset_seconds, |(_, offset)| *offset)
    }
}

/// A clock that only moves when told to — for tests and the demo.
#[derive(Debug, Clone)]
pub struct ManualClock {
    base: Instant,
    offset: Arc<Mutex<Duration>>,
    base_wall_ms: u64,
    /// Shared so clones see zone changes.
    zone: Arc<Mutex<ManualZone>>,
}

impl ManualClock {
    /// A manual clock whose wall time starts at a fixed 2023 instant, UTC.
    #[must_use]
    pub fn new() -> Self {
        Self {
            base: Instant::now(),
            offset: Arc::new(Mutex::new(Duration::ZERO)),
            base_wall_ms: MANUAL_CLOCK_BASE_WALL_MS,
            zone: Arc::new(Mutex::new(ManualZone::default())),
        }
    }

    /// Anchor the wall clock at `ms` since the Unix epoch.
    #[must_use]
    pub fn with_wall_ms(mut self, ms: u64) -> Self {
        self.base_wall_ms = ms;
        self
    }

    /// Report `seconds` east of UTC as the local offset.
    #[must_use]
    pub fn with_local_offset_seconds(self, seconds: i32) -> Self {
        self.set_local_offset_seconds(seconds);
        self
    }

    /// From each Unix second on, the paired offset applies. Ascending order.
    ///
    /// # Panics
    ///
    /// Panics if the internal lock is poisoned (a prior panic mid-update).
    #[must_use]
    pub fn with_zone_transitions(self, transitions: Vec<(u64, i32)>) -> Self {
        self.zone.lock().expect("zone lock poisoned").transitions = transitions;
        self
    }

    /// Move to a zone `seconds` east of UTC, dropping scheduled transitions.
    ///
    /// # Panics
    ///
    /// Panics if the internal lock is poisoned (a prior panic mid-update).
    pub fn set_local_offset_seconds(&self, seconds: i32) {
        let mut zone = self.zone.lock().expect("zone lock poisoned");
        zone.offset_seconds = seconds;
        zone.transitions.clear();
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

    /// Advances with [`ManualClock::advance`].
    fn wall_ms(&self) -> u64 {
        let offset = self.offset.lock().expect("clock lock poisoned");
        let advanced = u64::try_from(offset.as_millis()).unwrap_or(u64::MAX);
        self.base_wall_ms.saturating_add(advanced)
    }

    fn local_offset_seconds(&self) -> i32 {
        self.local_offset_seconds_at(self.wall_ms() / 1000)
    }

    fn local_offset_seconds_at(&self, wall_secs: u64) -> i32 {
        self.zone
            .lock()
            .expect("zone lock poisoned")
            .offset_at(wall_secs)
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
    fn manual_clock_wall_time_advances_with_the_monotonic_one() {
        let clock = ManualClock::new();
        let before = clock.wall_ms();
        clock.advance(Duration::from_secs(90));
        assert_eq!(clock.wall_ms() - before, 90_000);
    }

    #[test]
    fn manual_clock_wall_time_is_fixed_not_the_host_clock() {
        assert_eq!(ManualClock::new().wall_ms(), MANUAL_CLOCK_BASE_WALL_MS);
        assert_eq!(ManualClock::new().local_offset_seconds(), 0);
    }

    #[test]
    fn manual_clock_builders_override_the_defaults() {
        let clock = ManualClock::new()
            .with_wall_ms(1_000)
            .with_local_offset_seconds(-8 * 3600);
        assert_eq!(clock.wall_ms(), 1_000);
        assert_eq!(clock.local_offset_seconds(), -8 * 3600);
        clock.advance(Duration::from_secs(1));
        assert_eq!(clock.wall_ms(), 2_000);
    }

    #[test]
    fn system_clock_wall_time_is_plausible() {
        assert!(SystemClock.wall_ms() > 1_700_000_000_000);
    }

    #[test]
    fn the_sleep_inclusive_reading_never_runs_backwards() {
        let first = sleep_inclusive_ns();
        let mut last = first;
        for _ in 0..1000 {
            let next = sleep_inclusive_ns();
            assert!(next >= last, "the sleep-inclusive clock ran backwards");
            last = next;
        }
        assert!(last >= first);
    }

    #[test]
    fn local_offset_is_within_a_day() {
        assert!(SystemClock.local_offset_seconds().abs() <= 14 * 3600);
        let ahead = SystemClock.wall_ms() / 1000 + 7 * 24 * 3600;
        assert!(SystemClock.local_offset_seconds_at(ahead).abs() <= 14 * 3600);
    }

    #[test]
    fn manual_zone_transitions_take_effect_from_their_instant() {
        let clock = ManualClock::new()
            .with_local_offset_seconds(-8 * 3600)
            .with_zone_transitions(vec![(1_000, -7 * 3600), (2_000, -8 * 3600)]);
        assert_eq!(clock.local_offset_seconds_at(999), -8 * 3600);
        assert_eq!(clock.local_offset_seconds_at(1_000), -7 * 3600);
        assert_eq!(clock.local_offset_seconds_at(1_999), -7 * 3600);
        assert_eq!(clock.local_offset_seconds_at(2_000), -8 * 3600);
        let shared = clock.clone();
        clock.set_local_offset_seconds(3600);
        assert_eq!(shared.local_offset_seconds_at(1_500), 3600);
        assert_eq!(shared.local_offset_seconds(), 3600);
    }

    #[test]
    fn system_clock_is_monotonic_and_tracks_real_elapsed_time() {
        // Sleep cannot run in CI; this pins monotonicity and awake pace.
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
