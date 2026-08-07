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
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// A monotonic clock the store reads instead of calling
/// [`Instant::now`] directly.
pub trait Clock {
    /// The current monotonic instant.
    fn now(&self) -> Instant;

    /// Unix epoch milliseconds. Never used for expiry math (that stays
    /// monotonic, see the module doc); only for stamping records a human
    /// reads and for the creation-time title placeholder.
    fn wall_ms(&self) -> u64;

    /// Seconds east of UTC for the user's current locale, so a placeholder
    /// title reads as the local wall clock.
    fn local_offset_seconds(&self) -> i32;
}

/// The real thing: monotonic, and it keeps counting while the system
/// sleeps. Expiry is the promise (doc 03 §1) — in wall time.
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
        local_offset_seconds()
    }
}

/// Seconds east of UTC for the current locale. This is the one place the
/// crate reads calendar-aware state from the OS: `localtime_r` consults
/// the time zone database, which no monotonic clock can do.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn local_offset_seconds() -> i32 {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let time = libc::time_t::try_from(secs).unwrap_or(libc::time_t::MAX);
    // SAFETY: `tm` is a plain C struct of integers and one pointer, for
    // which all-zero is a valid bit pattern; `localtime_r` overwrites it
    // before anything reads it.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: `localtime_r` reads the `time_t` behind a valid pointer and
    // writes to a valid, stack-allocated `tm`; both live for the call, and
    // the reentrant form touches no shared buffer.
    unsafe {
        libc::localtime_r(&raw const time, &raw mut tm);
    }
    i32::try_from(tm.tm_gmtoff).unwrap_or(0)
}

/// Elsewhere: no portable time zone query worth an unsafe block, so a
/// placeholder title reads as UTC.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn local_offset_seconds() -> i32 {
    0
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
///
/// Public because the persistence seam stamps sealed files with this
/// exact reading and ages them by the difference on restore: the file
/// and the store must be measuring the same clock, or a page would
/// drain by one clock and be checked against another. The reading is
/// only comparable within a boot session, which is the same bound the
/// sealed file already carries.
#[must_use]
#[cfg(any(target_os = "macos", target_os = "linux"))]
pub fn sleep_inclusive_ns() -> u64 {
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
/// Public for the same reason as its Darwin and Linux siblings.
#[must_use]
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn sleep_inclusive_ns() -> u64 {
    static FALLBACK_BASE: OnceLock<Instant> = OnceLock::new();
    let base = *FALLBACK_BASE.get_or_init(Instant::now);
    u64::try_from(base.elapsed().as_nanos()).unwrap_or(u64::MAX)
}

/// Wall time a fresh [`ManualClock`] reports: a fixed instant in
/// November 2023, so title and timestamp tests never depend on the host
/// clock.
const MANUAL_CLOCK_BASE_WALL_MS: u64 = 1_700_000_000_000;

/// A clock that only moves when told to — for tests and the demo.
#[derive(Debug, Clone)]
pub struct ManualClock {
    base: Instant,
    offset: Arc<Mutex<Duration>>,
    base_wall_ms: u64,
    offset_seconds: i32,
}

impl ManualClock {
    /// A manual clock anchored at construction time. Its wall clock
    /// starts at a fixed 2023 instant in UTC, never at the host's.
    #[must_use]
    pub fn new() -> Self {
        Self {
            base: Instant::now(),
            offset: Arc::new(Mutex::new(Duration::ZERO)),
            base_wall_ms: MANUAL_CLOCK_BASE_WALL_MS,
            offset_seconds: 0,
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
    pub fn with_local_offset_seconds(mut self, seconds: i32) -> Self {
        self.offset_seconds = seconds;
        self
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

    /// Wall time moves with [`ManualClock::advance`], so a test that ages
    /// an item sees both clocks agree on how much time passed.
    fn wall_ms(&self) -> u64 {
        let offset = self.offset.lock().expect("clock lock poisoned");
        let advanced = u64::try_from(offset.as_millis()).unwrap_or(u64::MAX);
        self.base_wall_ms.saturating_add(advanced)
    }

    fn local_offset_seconds(&self) -> i32 {
        self.offset_seconds
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
        // Fails loudly if the epoch math is wrong: any sane host reads
        // later than November 2023.
        assert!(SystemClock.wall_ms() > 1_700_000_000_000);
    }

    /// The reading the sealed file stamps itself with. It must never
    /// run backwards, or time away would come out negative and a page
    /// would gain life across a relaunch.
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
