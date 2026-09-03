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
//!
//! Amended 2026-08-26 (ADR-0021 section 6). The monotonic discipline
//! survives for every locally observed interval: nothing a running
//! session measures leaves this clock, and an `Instant` still never
//! crosses a boot session, let alone a machine. What changed is that
//! the restart gap (ADR-0016 section 4) is no longer the only
//! wall-clock reader of a deadline. The replicated expiry policy is
//! the second: a synced page publishes `(anchor_wall_ms, ttl_ms)` and
//! every device computes its own deadline from the pair on its own
//! wall clock, because the calendar is the one clock two machines
//! share. Both readers obey the same never-extend arithmetic — a
//! restore only ever subtracts, and a peer's candidate only ever
//! shortens ([`SheetStore::observe_peer_expiry`]) — so a stepped or
//! skewed wall clock can kill a page early, which is recoverable, and
//! can never grant one life, which would not be.
//!
//! [`SheetStore::observe_peer_expiry`]: crate::store::SheetStore::observe_peer_expiry
#![allow(unsafe_code)]

use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// A monotonic clock the store reads instead of calling
/// [`Instant::now`] directly.
pub trait Clock {
    /// The current monotonic instant.
    fn now(&self) -> Instant;

    /// Unix epoch milliseconds. Local expiry math stays monotonic (see
    /// the module doc); this reading stamps records a human reads,
    /// anchors the creation-time title placeholder, and — amended
    /// 2026-08-26, ADR-0021 section 6 — carries a deadline across
    /// machines as the replicated expiry policy, under the same
    /// never-extend arithmetic the restart gap uses.
    fn wall_ms(&self) -> u64;

    /// Seconds east of UTC for the user's current locale, so a placeholder
    /// title reads as the local wall clock.
    fn local_offset_seconds(&self) -> i32;

    /// Seconds east of UTC for the user's current locale at the Unix
    /// second `wall_secs`, which may lie in the future. The boundary
    /// snap (ADR-0011 section 4) asks this for the instants around a
    /// nominal deadline, so a daylight-saving change between now and
    /// then lands the deadline on the boundary the wall clock will
    /// actually strike. The zone consulted is the device's zone *now*;
    /// the answer is stored once and never revisited.
    fn local_offset_seconds_at(&self, wall_secs: u64) -> i32 {
        let _ = wall_secs;
        self.local_offset_seconds()
    }
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
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        local_offset_seconds_at(secs)
    }

    fn local_offset_seconds_at(&self, wall_secs: u64) -> i32 {
        local_offset_seconds_at(wall_secs)
    }
}

/// Seconds east of UTC for the current locale at the Unix second
/// `secs`. This is the one place the crate reads calendar-aware state
/// from the OS: `localtime_r` consults the time zone database, which no
/// monotonic clock can do, and it answers for any instant the database
/// covers, so a daylight-saving change ahead of now is read as the
/// database has it.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn local_offset_seconds_at(secs: u64) -> i32 {
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
/// placeholder title reads as UTC and the boundary snap rounds to UTC.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn local_offset_seconds_at(_secs: u64) -> i32 {
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
/// It was public because the persistence seam stamped sealed files
/// with this exact reading and aged them by the difference on restore.
/// It no longer does: two readings of this clock are comparable only
/// within one boot session, so it cannot measure the gap between a save
/// and the next launch at all, and ADR-0016 section 4 moved that one
/// interval onto the wall clock. Nothing outside this module reads it
/// now, and the visibility says so. What the seam kept is the half that
/// was always true: every interval a running session observes is still
/// charged on this clock, through the `Instant`s the store holds.
#[must_use]
#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(crate) fn sleep_inclusive_ns() -> u64 {
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
/// Scoped like its Darwin and Linux siblings.
#[must_use]
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(crate) fn sleep_inclusive_ns() -> u64 {
    static FALLBACK_BASE: OnceLock<Instant> = OnceLock::new();
    let base = *FALLBACK_BASE.get_or_init(Instant::now);
    u64::try_from(base.elapsed().as_nanos()).unwrap_or(u64::MAX)
}

/// Wall time a fresh [`ManualClock`] reports: a fixed instant in
/// November 2023, so title and timestamp tests never depend on the host
/// clock.
const MANUAL_CLOCK_BASE_WALL_MS: u64 = 1_700_000_000_000;

/// The zone a [`ManualClock`] reports: a standing offset, and the
/// transitions that override it from a given Unix second on, so a test
/// can put a daylight-saving change ahead of a deadline without
/// consulting the host's zone database.
#[derive(Debug, Default)]
struct ManualZone {
    offset_seconds: i32,
    /// `(from_secs, offset_seconds)`, ascending; the last entry at or
    /// before an instant is in force there.
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
    /// Shared like the offset, so a clone handed to a store sees the
    /// zone change a test makes on its own copy afterwards.
    zone: Arc<Mutex<ManualZone>>,
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

    /// Schedule zone transitions: from each Unix second on, the paired
    /// offset is in force, until the next entry. Ascending order.
    ///
    /// # Panics
    ///
    /// Panics if the internal lock is poisoned (a prior panic mid-update).
    #[must_use]
    pub fn with_zone_transitions(self, transitions: Vec<(u64, i32)>) -> Self {
        self.zone.lock().expect("zone lock poisoned").transitions = transitions;
        self
    }

    /// Move the device to a zone `seconds` east of UTC, dropping any
    /// scheduled transitions: what a test does after a deadline is set,
    /// to show the deadline does not move with the zone.
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

    /// Wall time moves with [`ManualClock::advance`], so a test that ages
    /// an item sees both clocks agree on how much time passed.
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
        // And for an instant a week out, which is as far as the daily
        // ladder ever asks.
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
        // Moving zones clears the schedule and the clone sees it too.
        let shared = clock.clone();
        clock.set_local_offset_seconds(3600);
        assert_eq!(shared.local_offset_seconds_at(1_500), 3600);
        assert_eq!(shared.local_offset_seconds(), 3600);
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
