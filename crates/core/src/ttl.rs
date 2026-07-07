//! The TTL ladder: `1h → 3h → 8h → 24h → 3d → 7d`, wrapping back to 1h.
//!
//! One affordance replaces a preferences pane and a date picker: clicking
//! a cell's TTL label cycles to the next rung *and resets the clock* to
//! that value. There is deliberately no "forever" on the wheel — seven
//! days is the ceiling (docs/spec/02 §2). Whether the wrap survives
//! contact with real use is open question №2.

use std::fmt;
use std::time::Duration;

const HOUR: u64 = 60 * 60;
const DAY: u64 = 24 * HOUR;

/// The rungs of the ladder, in order.
pub const TTL_LADDER: [Duration; 6] = [
    Duration::from_secs(HOUR),
    Duration::from_secs(3 * HOUR),
    Duration::from_secs(8 * HOUR),
    Duration::from_secs(24 * HOUR),
    Duration::from_secs(3 * DAY),
    Duration::from_secs(7 * DAY),
];

/// Index of the default rung (8h — a working day; open question №1).
const DEFAULT_RUNG: usize = 2;

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

    /// This rung's duration.
    #[must_use]
    pub fn duration(self) -> Duration {
        TTL_LADDER[self.0]
    }

    /// The next rung up, wrapping `7d → 1h` (doc 04; open question №2).
    #[must_use]
    pub fn next(self) -> Ttl {
        Ttl((self.0 + 1) % TTL_LADDER.len())
    }

    /// The previous rung down, wrapping `1h → 7d`.
    #[must_use]
    pub fn prev(self) -> Ttl {
        Ttl((self.0 + TTL_LADDER.len() - 1) % TTL_LADDER.len())
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
    fn default_is_a_working_day() {
        assert_eq!(Ttl::default().duration(), Duration::from_secs(8 * HOUR));
        assert_eq!(Ttl::default().to_string(), "8h");
    }

    #[test]
    fn ladder_cycles_in_spec_order_and_wraps() {
        let mut rung = Ttl::MIN;
        let seen: Vec<String> = (0..7)
            .map(|_| {
                let label = rung.to_string();
                rung = rung.next();
                label
            })
            .collect();
        assert_eq!(seen, ["1h", "3h", "8h", "24h", "3d", "7d", "1h"]);
    }

    #[test]
    fn prev_reverses_next() {
        assert_eq!(Ttl::MIN.prev(), Ttl::MAX);
        assert_eq!(Ttl::MAX.next(), Ttl::MIN);
        assert_eq!(Ttl::default().next().prev(), Ttl::default());
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
}
