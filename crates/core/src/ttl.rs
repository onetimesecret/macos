//! The TTL ladder, `7d → 3d → 24h → 8h → 3h → 1h`, and the boundary snap
//! computed once when a rung is applied (ADR-0011 sections 2 to 4, ADR-0017).

use std::fmt;
use std::time::Duration;

const HOUR: u64 = 60 * 60;
const DAY: u64 = 24 * HOUR;

/// The rungs, shortest first; the click walks them the other way.
pub const TTL_LADDER: [Duration; 6] = [
    Duration::from_secs(HOUR),
    Duration::from_secs(3 * HOUR),
    Duration::from_secs(8 * HOUR),
    Duration::from_secs(24 * HOUR),
    Duration::from_secs(3 * DAY),
    Duration::from_secs(7 * DAY),
];

/// New durable tabs start at the ceiling (ADR-0011 section 3).
const DEFAULT_RUNG: usize = TTL_LADDER.len() - 1;

/// The daily paradigm's unit (ADR-0011 section 4).
pub const DAILY_UNIT: Duration = Duration::from_secs(DAY);

/// One rung of the TTL ladder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ttl(usize);

impl Ttl {
    /// The 1-hour rung.
    pub const MIN: Ttl = Ttl(0);
    /// The ceiling; there is no "forever".
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

    /// Nominal duration plus the largest extension the snap may add, the
    /// bound restore applies to a claimed span.
    #[must_use]
    pub fn longest_life(self) -> Duration {
        self.duration() + self.max_extension()
    }

    fn max_extension(self) -> Duration {
        self.duration().min(DAILY_UNIT)
    }

    /// Whole local hours under a day, local midnight from a day up.
    fn boundary_period(self) -> u64 {
        if self.duration() < DAILY_UNIT {
            HOUR
        } else {
            DAY
        }
    }

    /// One rung shorter, wrapping `1h → 7d`: what a click does.
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
/// snapped to a local boundary (ADR-0011 section 4). `offset_at` gives
/// the zone's seconds east of UTC at a Unix second.
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

/// The first Unix millisecond at or after `at_ms` where the local clock
/// strikes a multiple of `period` seconds past midnight. A spring-forward
/// jump past the label counts as striking; a fall-back repeat counts once.
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

/// The TTL label's reading of a remaining duration ("3h 40m", "58s").
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

    const PST: i32 = -8 * 3600;
    const PDT: i32 = -7 * 3600;
    const SPRING_FORWARD: u64 = 1_772_964_000;
    const FALL_BACK: u64 = 1_793_523_600;

    /// `America/Los_Angeles` across 2026, as a table so tests are host-independent.
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
        let applied = at(2026, 6, 10, 16, 0);
        let life = graced_life(rung("24h"), ms(applied), &utc);
        assert_eq!(life, Duration::from_secs(32 * HOUR));
    }

    #[test]
    fn long_rungs_snap_to_local_midnight_in_the_device_zone() {
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
            assert_eq!(
                life,
                Duration::from_secs(hours * HOUR + 40 * 60),
                "{label} rounds up to the hour"
            );
        }
        let kolkata = |_: u64| 5 * 3600 + 1800;
        let life = graced_life(rung("1h"), ms(at(2026, 6, 10, 16, 20)), &kolkata);
        assert_eq!(life, Duration::from_secs(HOUR + 10 * 60));
    }

    #[test]
    fn an_exact_boundary_is_its_own_deadline() {
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
        assert_eq!(
            graced_life(rung("1h"), ms(applied) + 1, &los_angeles),
            Duration::from_millis(2 * HOUR * 1000 - 1)
        );
    }

    #[test]
    fn the_extension_is_bounded_by_the_rung_and_the_unit() {
        let applied = at(2026, 6, 10, 7, 0) + 1;
        let life = graced_life(rung("24h"), ms(applied), &los_angeles);
        assert_eq!(life, Duration::from_secs(2 * DAY - 1));
        assert!(life <= rung("24h").longest_life());
        assert_eq!(rung("1h").longest_life(), Duration::from_secs(2 * HOUR));
        assert_eq!(rung("8h").longest_life(), Duration::from_secs(16 * HOUR));
        assert_eq!(rung("24h").longest_life(), Duration::from_secs(2 * DAY));
        assert_eq!(rung("7d").longest_life(), Duration::from_secs(8 * DAY));
    }

    #[test]
    fn weekends_get_no_special_treatment() {
        let friday = at(2026, 6, 13, 0, 0); // Friday 17:00 PDT
        let life = graced_life(rung("24h"), ms(friday), &los_angeles);
        assert_eq!(friday + life.as_secs(), at(2026, 6, 14, 7, 0));
        assert_eq!(life, Duration::from_secs(31 * HOUR));
    }

    #[test]
    fn across_spring_forward_the_bound_is_elapsed_time() {
        let applied = at(2026, 3, 8, 0, 0); // Sat 16:00 PST
        let life = graced_life(rung("24h"), ms(applied), &los_angeles);
        assert_eq!(applied + life.as_secs(), at(2026, 3, 9, 7, 0));
        assert_eq!(life, Duration::from_secs(31 * HOUR));

        let applied = at(2026, 3, 8, 9, 30); // 01:30 PST
        let life = graced_life(rung("1h"), ms(applied), &los_angeles);
        assert_eq!(applied + life.as_secs(), at(2026, 3, 8, 11, 0)); // 04:00 PDT
        assert_eq!(life, Duration::from_secs(HOUR + 30 * 60));

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
        let change = at(2026, 4, 5, 3, 0); // midnight at UTC-3 becomes 01:00 at UTC-2
        let zone = move |secs: u64| if secs >= change { -2 * 3600 } else { -3 * 3600 };
        let applied = at(2026, 4, 3, 23, 0); // 20:00 local, the day before the eve
        let life = graced_life(rung("24h"), ms(applied), &zone);
        assert_eq!(applied + life.as_secs(), change);
        assert_eq!(life, Duration::from_secs(DAY + 4 * HOUR));
        let applied = at(2026, 4, 5, 3, 0) + 20 * HOUR; // 19:00 local, UTC-2
        let life = graced_life(rung("24h"), ms(applied), &zone);
        assert_eq!(applied + life.as_secs(), at(2026, 4, 7, 2, 0));
    }

    #[test]
    fn the_zone_at_application_time_is_the_one_that_counts() {
        let applied = at(2026, 6, 10, 16, 30);
        let here = graced_life(rung("24h"), ms(applied), &los_angeles);
        let there = graced_life(rung("24h"), ms(applied), &|_| 2 * 3600);
        assert_ne!(here, there);
    }
}
