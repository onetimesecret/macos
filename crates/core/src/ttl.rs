//! The TTL ladder, longest to shortest: `7d → 3d → 24h → 8h → 3h → 1h`,
//! wrapping back to 7d.
//!
//! One affordance replaces a preferences pane and a date picker: clicking
//! a cell's TTL label steps to the next rung *and resets the clock* to
//! that value. There is deliberately no "forever" on the wheel — seven
//! days is the daily ladder's ceiling (ADR-0011 section 2).
//!
//! The click shortens. A **new durable tab** is created at the top of
//! the ladder (ADR-0011 section 3), and the rung is the tab's from then
//! on: a replacement page in an existing tab starts at whatever rung
//! that tab retained, never at this default again (ADR-0017). Every
//! click tapers one rung, so reaching the most precarious rung from a
//! fresh tab takes five deliberate clicks rather than one. The wrap
//! survives (the wheel is still one affordance), but it sits at the
//! safe end: the single-click cliff is `1h → 7d`, which loses nothing,
//! where an upward wrap would put a `7d → 1h` cliff under a stray click
//! on staged content.
//!
//! A rung names a nominal duration. Applying one may round the deadline
//! it produces up to a calendar boundary ([`graced_life`], ADR-0011
//! section 4): once, at application, never as a reprieve at expiry.

use std::fmt;
use std::time::Duration;

const HOUR: u64 = 60 * 60;
const DAY: u64 = 24 * HOUR;

/// The rungs of the ladder, shortest first. The click walks this the
/// other way (see [`Ttl::shorter`]); the array stays ordered by
/// duration so `MIN`, `MAX` and the wire codes read plainly.
pub const TTL_LADDER: [Duration; 6] = [
    Duration::from_secs(HOUR),
    Duration::from_secs(3 * HOUR),
    Duration::from_secs(8 * HOUR),
    Duration::from_secs(24 * HOUR),
    Duration::from_secs(3 * DAY),
    Duration::from_secs(7 * DAY),
];

/// Index of the default rung: the ceiling, 7d on the daily ladder. A
/// new durable tab is created here (ADR-0011 section 3), so every
/// shortening is a deliberate click and the wrap stays on the
/// non-destructive `1h → 7d` edge.
const DEFAULT_RUNG: usize = TTL_LADDER.len() - 1;

/// The daily paradigm's unit: 24 elapsed hours (ADR-0011 section 4).
/// It bounds how far a boundary snap may extend a nominal deadline,
/// and it decides which rungs snap to a clock hour and which to a
/// local midnight.
pub const DAILY_UNIT: Duration = Duration::from_secs(DAY);

/// One rung of the TTL ladder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ttl(usize);

impl Ttl {
    /// The 1-hour rung.
    pub const MIN: Ttl = Ttl(0);
    /// The 7-day rung — the ceiling; there is no "forever".
    pub const MAX: Ttl = Ttl(TTL_LADDER.len() - 1);

    /// The rung whose duration is `secs`, if it is on the ladder.
    #[must_use]
    pub fn from_secs(secs: u64) -> Option<Ttl> {
        TTL_LADDER.iter().position(|d| d.as_secs() == secs).map(Ttl)
    }

    /// This rung's nominal duration.
    #[must_use]
    pub fn duration(self) -> Duration {
        TTL_LADDER[self.0]
    }

    /// The most life a page on this rung can be born with: the nominal
    /// duration plus the largest boundary extension the snap may add
    /// (ADR-0011 section 4: the smaller of the paradigm unit and the
    /// rung itself). Restore bounds a claimed span by this rather than
    /// by [`Ttl::duration`], because a snapped deadline honestly
    /// exceeds the nominal one.
    #[must_use]
    pub fn longest_life(self) -> Duration {
        self.duration() + self.max_extension()
    }

    /// How far past nominal a boundary snap may reach on this rung.
    fn max_extension(self) -> Duration {
        self.duration().min(DAILY_UNIT)
    }

    /// The period, in seconds, of this rung's boundary schedule: whole
    /// local clock hours under a day, local midnight from a day up.
    fn boundary_period(self) -> u64 {
        if self.duration() < DAILY_UNIT {
            HOUR
        } else {
            DAY
        }
    }

    /// One rung shorter, wrapping `1h → 7d`. This is what a click on
    /// the countdown does (doc 04): the ladder tapers, so the most
    /// precarious rung is five clicks away, not one.
    #[must_use]
    pub fn shorter(self) -> Ttl {
        Ttl((self.0 + TTL_LADDER.len() - 1) % TTL_LADDER.len())
    }

    /// One rung longer, wrapping `7d → 1h`.
    #[must_use]
    pub fn longer(self) -> Ttl {
        Ttl((self.0 + 1) % TTL_LADDER.len())
    }
}

impl Default for Ttl {
    fn default() -> Self {
        Ttl(DEFAULT_RUNG)
    }
}

impl fmt::Display for Ttl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self.0 {
            0 => "1h",
            1 => "3h",
            2 => "8h",
            3 => "24h",
            4 => "3d",
            _ => "7d",
        })
    }
}

/// The life a page gets when `rung` is applied at `applied_wall_ms`,
/// with the daily paradigm's boundary snap (ADR-0011 section 4):
///
/// 1. `nominal = applied + rung`.
/// 2. Find the first boundary at or after `nominal`: a whole local
///    clock hour for rungs under a day, a local midnight from a day up.
/// 3. Use it only when it extends `nominal` by no more than the
///    smaller of the unit (24h) and the rung; otherwise use `nominal`.
///
/// `offset_at` reports the local zone's seconds east of UTC at a given
/// Unix second. The device's zone *at application time* supplies the
/// schedule, because this runs once and the result is stored; a later
/// zone change recalculates nothing. Every subtraction here is between
/// Unix instants, so across a daylight-saving change the extension
/// bound is elapsed time and never a difference of wall-clock labels.
///
/// The result is a duration from `applied`, which is what the store
/// adds to its monotonic `now`, so the deadline the label counts down
/// to and the deadline the timer reaps at are one number.
#[must_use]
pub fn graced_life(rung: Ttl, applied_wall_ms: u64, offset_at: &dyn Fn(u64) -> i32) -> Duration {
    let nominal_ms = applied_wall_ms.saturating_add(millis(rung.duration()));
    let Some(boundary_ms) = next_boundary_ms(nominal_ms, rung.boundary_period(), offset_at) else {
        return rung.duration();
    };
    let extension = Duration::from_millis(boundary_ms.saturating_sub(nominal_ms));
    if extension <= rung.max_extension() {
        Duration::from_millis(boundary_ms.saturating_sub(applied_wall_ms))
    } else {
        rung.duration()
    }
}

/// The first Unix millisecond at or after `at_ms` at which the local
/// clock strikes a whole multiple of `period` seconds past midnight: a
/// whole hour for `period` 3600, midnight for 86400.
///
/// The label the clock should next strike is computed under the offset
/// in force at `at_ms`. Two instants can carry that label once a
/// daylight-saving change sits between the two: the one under the
/// offset at `at_ms` and the one under the offset at that first
/// candidate. Both are tried, earliest first, and a candidate counts
/// when the clock there reads a whole boundary (under its own offset),
/// or when a spring-forward jumped the clock past the label at exactly
/// that instant, which is how a day with no midnight still turns. A
/// label a fall-back repeats is taken on its first occurrence. When
/// neither instant strikes, the search steps one label forward and
/// gives up after a few, which only a zone with a transition of its
/// own period could reach.
fn next_boundary_ms(at_ms: u64, period: u64, offset_at: &dyn Fn(u64) -> i32) -> Option<u64> {
    let at_secs = at_ms / 1000;
    let period_signed = i64::try_from(period).ok()?;
    let offset = i64::from(offset_at(at_secs));
    let local = i64::try_from(at_secs).ok()? + offset;
    let rem = local.rem_euclid(period_signed);
    let mut label = if rem == 0 && at_ms.is_multiple_of(1000) {
        local
    } else {
        local - rem + period_signed
    };

    let strikes = |instant: u64, label: i64| -> bool {
        let Ok(signed) = i64::try_from(instant) else {
            return false;
        };
        let here = i64::from(offset_at(instant));
        let reading = signed + here;
        reading.rem_euclid(period_signed) == 0 || (here > offset && reading > label)
    };

    for _ in 0..4 {
        let first = u64::try_from(label - offset).ok()?;
        let shifted = u64::try_from(label - i64::from(offset_at(first))).ok()?;
        let mut candidates = [first, shifted];
        candidates.sort_unstable();
        if let Some(found) = candidates
            .into_iter()
            .find(|&instant| instant >= at_secs && strikes(instant, label))
        {
            return Some(found.saturating_mul(1000));
        }
        label += period_signed;
    }
    None
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// Render a remaining duration the way the TTL label reads it:
/// natural, coarse, honest ("8h", "3h 40m", "43m", "58s").
#[must_use]
pub fn human_remaining(remaining: Duration) -> String {
    let secs = remaining.as_secs();
    if secs == 0 {
        return "—".to_string();
    }
    let (d, h, m) = (secs / DAY, (secs % DAY) / HOUR, (secs % HOUR) / 60);
    match (d, h, m) {
        (0, 0, 0) => format!("{secs}s"),
        (0, 0, m) => format!("{m}m"),
        (0, h, 0) => format!("{h}h"),
        (0, h, m) => format!("{h}h {m}m"),
        // A full day reads in ladder vocabulary: "24h", not "1d".
        (1, 0, 0) => "24h".to_string(),
        (d, 0, _) => format!("{d}d"),
        (d, h, _) => format!("{d}d {h}h"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_tab_starts_at_the_ceiling() {
        // ADR-0011 section 3: the default is the top of the ladder.
        assert_eq!(Ttl::default(), Ttl::MAX);
        assert_eq!(Ttl::default().duration(), Duration::from_secs(7 * DAY));
        assert_eq!(Ttl::default().to_string(), "7d");
    }

    #[test]
    fn clicking_tapers_down_the_ladder_and_wraps_at_the_bottom() {
        let mut rung = Ttl::default();
        let seen: Vec<String> = (0..7)
            .map(|_| {
                let label = rung.to_string();
                rung = rung.shorter();
                label
            })
            .collect();
        assert_eq!(seen, ["7d", "3d", "24h", "8h", "3h", "1h", "7d"]);
    }

    #[test]
    fn the_shortest_rung_is_five_clicks_from_the_default() {
        let mut rung = Ttl::default();
        for _ in 0..5 {
            assert_ne!(rung, Ttl::MIN, "the cliff must not be one click");
            rung = rung.shorter();
        }
        assert_eq!(rung, Ttl::MIN);
        // The wrap sits on the non-destructive edge.
        assert_eq!(rung.shorter(), Ttl::MAX);
    }

    #[test]
    fn longer_reverses_shorter() {
        assert_eq!(Ttl::MIN.shorter(), Ttl::MAX);
        assert_eq!(Ttl::MAX.longer(), Ttl::MIN);
        assert_eq!(Ttl::default().shorter().longer(), Ttl::default());
    }

    #[test]
    fn from_secs_round_trips_the_ladder() {
        for rung in TTL_LADDER {
            assert_eq!(
                Ttl::from_secs(rung.as_secs()).map(Ttl::duration),
                Some(rung)
            );
        }
        assert_eq!(Ttl::from_secs(123), None);
    }

    #[test]
    fn human_remaining_reads_naturally() {
        assert_eq!(human_remaining(Duration::from_secs(8 * HOUR)), "8h");
        assert_eq!(
            human_remaining(Duration::from_secs(3 * HOUR + 40 * 60)),
            "3h 40m"
        );
        assert_eq!(human_remaining(Duration::from_secs(43 * 60)), "43m");
        assert_eq!(human_remaining(Duration::from_secs(58)), "58s");
        assert_eq!(human_remaining(Duration::from_secs(3 * DAY)), "3d");
        assert_eq!(human_remaining(Duration::from_secs(DAY)), "24h");
        assert_eq!(human_remaining(Duration::ZERO), "—");
    }

    // ---------------------------------------------------------------
    // The boundary snap (ADR-0011 section 4)
    // ---------------------------------------------------------------

    const PST: i32 = -8 * 3600;
    const PDT: i32 = -7 * 3600;
    /// 2026-03-08 02:00 PST: the clocks go forward to 03:00 PDT.
    const SPRING_FORWARD: u64 = 1_772_964_000;
    /// 2026-11-01 02:00 PDT: the clocks go back to 01:00 PST.
    const FALL_BACK: u64 = 1_793_523_600;

    /// `America/Los_Angeles` across 2026, as a table rather than the host
    /// zone database, so the assertions hold on any machine.
    fn los_angeles(secs: u64) -> i32 {
        if (SPRING_FORWARD..FALL_BACK).contains(&secs) {
            PDT
        } else {
            PST
        }
    }

    fn utc(_: u64) -> i32 {
        0
    }

    /// Unix seconds of a UTC calendar instant, via days since the epoch.
    fn at(year: i64, month: i64, day: i64, hour: u64, minute: u64) -> u64 {
        let (y, m) = if month <= 2 {
            (year - 1, month + 12)
        } else {
            (year, month)
        };
        let era = y.div_euclid(400);
        let yoe = y - era * 400;
        let doy = (153 * (m - 3) + 2) / 5 + day - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        let days = era * 146_097 + doe - 719_468;
        u64::try_from(days).unwrap() * DAY + hour * HOUR + minute * 60
    }

    fn ms(secs: u64) -> u64 {
        secs * 1000
    }

    fn rung(label: &str) -> Ttl {
        TTL_LADDER
            .iter()
            .position(|d| Ttl::from_secs(d.as_secs()).unwrap().to_string() == label)
            .map(Ttl)
            .expect("a ladder label")
    }

    #[test]
    fn the_transition_table_matches_the_calendar() {
        assert_eq!(SPRING_FORWARD, at(2026, 3, 8, 10, 0));
        assert_eq!(FALL_BACK, at(2026, 11, 1, 9, 0));
    }

    #[test]
    fn a_day_rung_applied_mid_afternoon_snaps_to_the_next_midnight() {
        // The ADR's own example: 24h at 4pm has a nominal deadline of
        // 4pm tomorrow and snaps to the midnight ending that day, an
        // eight hour extension inside the 24h bound.
        let applied = at(2026, 6, 10, 16, 0);
        let life = graced_life(rung("24h"), ms(applied), &utc);
        assert_eq!(life, Duration::from_secs(32 * HOUR));
    }

    #[test]
    fn long_rungs_snap_to_local_midnight_in_the_device_zone() {
        // 7d at 09:30 PDT on a Wednesday: nominal is 09:30 PDT the next
        // Wednesday, and midnight in Los Angeles is 07:00 UTC.
        let applied = at(2026, 6, 10, 16, 30); // 09:30 PDT
        let life = graced_life(rung("7d"), ms(applied), &los_angeles);
        let deadline = applied + life.as_secs();
        assert_eq!(
            deadline,
            at(2026, 6, 18, 7, 0),
            "midnight PDT after nominal"
        );
        assert_eq!(life, Duration::from_secs(7 * DAY + 14 * HOUR + 30 * 60));

        let life = graced_life(rung("3d"), ms(applied), &los_angeles);
        assert_eq!(applied + life.as_secs(), at(2026, 6, 14, 7, 0));
    }

    #[test]
    fn short_rungs_snap_to_the_next_whole_clock_hour() {
        let applied = at(2026, 6, 10, 16, 20); // 09:20 PDT
        for (label, hours) in [("1h", 1), ("3h", 3), ("8h", 8)] {
            let life = graced_life(rung(label), ms(applied), &los_angeles);
            // 09:20 plus the rung lands at :20, and the snap takes it to
            // the next whole hour, a forty minute extension.
            assert_eq!(
                life,
                Duration::from_secs(hours * HOUR + 40 * 60),
                "{label} rounds up to the hour"
            );
        }
        // A half-hour zone aligns to its own clock, not to UTC's.
        let kolkata = |_: u64| 5 * 3600 + 1800;
        let life = graced_life(rung("1h"), ms(at(2026, 6, 10, 16, 20)), &kolkata);
        // 21:50 IST + 1h = 22:50 IST, snaps to 23:00 IST.
        assert_eq!(life, Duration::from_secs(HOUR + 10 * 60));
    }

    #[test]
    fn an_exact_boundary_is_its_own_deadline() {
        // Nominal already on a boundary: no extension, and the snap
        // must not reach for the boundary after it.
        let applied = at(2026, 6, 10, 7, 0); // midnight PDT
        assert_eq!(
            graced_life(rung("24h"), ms(applied), &los_angeles),
            Duration::from_secs(DAY)
        );
        let applied = at(2026, 6, 10, 16, 0);
        assert_eq!(
            graced_life(rung("1h"), ms(applied), &los_angeles),
            Duration::from_secs(HOUR)
        );
        // A millisecond past the hour is not on it.
        assert_eq!(
            graced_life(rung("1h"), ms(applied) + 1, &los_angeles),
            Duration::from_millis(2 * HOUR * 1000 - 1)
        );
    }

    #[test]
    fn the_extension_is_bounded_by_the_rung_and_the_unit() {
        // On the short rungs the hour boundary is always within the
        // rung, so the bound never bites there; the bound is what
        // keeps a 24h rung from snapping more than a day and is
        // exercised by construction on every day rung: a day rung
        // applied one second after midnight has nominal one second
        // after the next midnight and snaps a whole day minus a second,
        // which the 24h bound admits.
        let applied = at(2026, 6, 10, 7, 0) + 1;
        let life = graced_life(rung("24h"), ms(applied), &los_angeles);
        assert_eq!(life, Duration::from_secs(2 * DAY - 1));
        assert!(life <= rung("24h").longest_life());
        // Every rung's longest life is nominal plus its own extension
        // bound: doubled under a day, plus one day from a day up.
        assert_eq!(rung("1h").longest_life(), Duration::from_secs(2 * HOUR));
        assert_eq!(rung("8h").longest_life(), Duration::from_secs(16 * HOUR));
        assert_eq!(rung("24h").longest_life(), Duration::from_secs(2 * DAY));
        assert_eq!(rung("7d").longest_life(), Duration::from_secs(8 * DAY));
    }

    #[test]
    fn weekends_get_no_special_treatment() {
        // Friday 17:00 PDT plus 24h is Saturday 17:00, and the snap is
        // to the midnight that ends Saturday, not to Monday morning.
        let friday = at(2026, 6, 13, 0, 0); // Friday 17:00 PDT
        let life = graced_life(rung("24h"), ms(friday), &los_angeles);
        assert_eq!(friday + life.as_secs(), at(2026, 6, 14, 7, 0));
        assert_eq!(life, Duration::from_secs(31 * HOUR));
    }

    #[test]
    fn across_spring_forward_the_bound_is_elapsed_time() {
        // 24h applied Saturday 16:00 PST. Nominal is Sunday 16:00 PDT,
        // which is 23 elapsed hours later on the wall but exactly 24h
        // by the clock. Midnight Monday is 08:00 UTC PDT: an eight hour
        // elapsed extension, within bounds, and the total life is the
        // elapsed time and not a difference of labels.
        let applied = at(2026, 3, 8, 0, 0); // Sat 16:00 PST
        let life = graced_life(rung("24h"), ms(applied), &los_angeles);
        assert_eq!(applied + life.as_secs(), at(2026, 3, 9, 7, 0));
        assert_eq!(life, Duration::from_secs(31 * HOUR));

        // An hour rung applied in the last hour before the change:
        // 01:30 PST plus 1h is 03:30 PDT by the clock, since the wall
        // skipped 02:xx, and the next whole clock hour is 04:00 PDT,
        // thirty elapsed minutes on. The extension is measured on the
        // wire, not by subtracting "04:00" from "01:30".
        let applied = at(2026, 3, 8, 9, 30); // 01:30 PST
        let life = graced_life(rung("1h"), ms(applied), &los_angeles);
        assert_eq!(applied + life.as_secs(), at(2026, 3, 8, 11, 0)); // 04:00 PDT
        assert_eq!(life, Duration::from_secs(HOUR + 30 * 60));

        // And one whose nominal is the skipped label itself: 01:00 PST
        // plus 1h is "02:00", the instant the clock jumps to 03:00
        // PDT. The boundary is that instant, no extension at all.
        let applied = at(2026, 3, 8, 9, 0); // 01:00 PST
        let life = graced_life(rung("1h"), ms(applied), &los_angeles);
        assert_eq!(applied + life.as_secs(), SPRING_FORWARD);
        assert_eq!(life, Duration::from_secs(HOUR));
    }

    #[test]
    fn across_fall_back_a_repeated_hour_counts_once() {
        // 8h applied Saturday 18:20 PDT. Nominal is 02:20 by elapsed
        // time, which the wall labels 01:20 PST (the repeated hour).
        // The next whole clock hour is 02:00 PST, forty elapsed minutes
        // on, and the snap does not stretch to the hour after it.
        let applied = at(2026, 11, 1, 1, 20); // Sat 18:20 PDT
        let life = graced_life(rung("8h"), ms(applied), &los_angeles);
        assert_eq!(applied + life.as_secs(), at(2026, 11, 1, 10, 0)); // 02:00 PST
        assert_eq!(life, Duration::from_secs(8 * HOUR + 40 * 60));

        // A day rung across the change: 24h applied Saturday 16:00 PDT
        // has nominal Sunday 15:00 PST (25 elapsed hours after the
        // previous 16:00 label, 24 after application), and snaps to
        // Monday's midnight PST, nine elapsed hours on.
        let applied = at(2026, 10, 31, 23, 0); // Sat 16:00 PDT
        let life = graced_life(rung("24h"), ms(applied), &los_angeles);
        assert_eq!(applied + life.as_secs(), at(2026, 11, 2, 8, 0)); // midnight PST
        assert_eq!(life, Duration::from_secs(33 * HOUR));
    }

    #[test]
    fn a_boundary_the_wall_clock_skips_is_never_chosen() {
        // A zone whose spring-forward happens at midnight has a day
        // with no 00:00. A day rung whose nominal falls late on the
        // eve must snap to the next real midnight, 01:00 by the new
        // label, and never to the label that was skipped.
        let change = at(2026, 4, 5, 3, 0); // midnight at UTC-3 becomes 01:00 at UTC-2
        let zone = move |secs: u64| if secs >= change { -2 * 3600 } else { -3 * 3600 };
        let applied = at(2026, 4, 3, 23, 0); // 20:00 local, the day before the eve
        let life = graced_life(rung("24h"), ms(applied), &zone);
        // Nominal is 20:00 local on the eve; the first boundary after
        // it is the transition instant itself, where the clock jumps
        // from 23:59:59 to 01:00 and the day has turned. Four elapsed
        // hours on, and never the label 00:00 that no clock showed.
        assert_eq!(applied + life.as_secs(), change);
        assert_eq!(life, Duration::from_secs(DAY + 4 * HOUR));
        // The day after, the zone has a real midnight again at 02:00
        // UTC, and the snap lands on it.
        let applied = at(2026, 4, 5, 3, 0) + 20 * HOUR; // 19:00 local, UTC-2
        let life = graced_life(rung("24h"), ms(applied), &zone);
        assert_eq!(applied + life.as_secs(), at(2026, 4, 7, 2, 0));
    }

    #[test]
    fn the_zone_at_application_time_is_the_one_that_counts() {
        // The function is pure in the zone it is handed: the caller
        // stores the result, and a later zone change never reaches it.
        // Two zones give two lives for the same instant, which is the
        // whole reason the calculation runs once.
        let applied = at(2026, 6, 10, 16, 30);
        let here = graced_life(rung("24h"), ms(applied), &los_angeles);
        let there = graced_life(rung("24h"), ms(applied), &|_| 2 * 3600);
        assert_ne!(here, there);
    }
}
