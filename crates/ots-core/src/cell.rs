//! The [`SleeperCell`] — the atomic unit of the buffer — plus the TTL ladder
//! and the non-secret [`CellSummary`] that crosses the FFI.

use serde::{Deserialize, Serialize};

use crate::preview::redact;
use crate::secret::SecretBuffer;

/// Opaque handle to a cell. A `u64` is enough and travels trivially across the
/// C ABI; it identifies a cell, never its contents (docs/01 §3).
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Serialize, Deserialize)]
pub struct CellId(pub u64);

impl std::fmt::Display for CellId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// What kind of content a cell holds. Images cannot yet be promoted to a
/// one-time link (the `conceal` endpoint takes text — docs/00 §12).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CellKind {
    Text,
    Image,
}

/// The discrete, cyclable TTL ladder: `7d · 3d · 24h · 8h · 3h · 1h` (docs/00
/// §7). Clicking a cell's label steps **up** the ladder toward longer life and
/// wraps around — "keeping costs a click".
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TtlRung {
    OneHour,
    ThreeHours,
    EightHours,
    TwentyFourHours,
    ThreeDays,
    SevenDays,
}

impl TtlRung {
    /// The ladder in ascending order (shortest first). The cycle order.
    pub const LADDER: [TtlRung; 6] = [
        TtlRung::OneHour,
        TtlRung::ThreeHours,
        TtlRung::EightHours,
        TtlRung::TwentyFourHours,
        TtlRung::ThreeDays,
        TtlRung::SevenDays,
    ];

    /// The resting default. Short by design — hours, not days — so the honest
    /// common case evaporates on its own (docs/00 §7). Provisional pending the
    /// open question in docs/00 §13.3.
    pub const DEFAULT: TtlRung = TtlRung::ThreeHours;

    /// This rung's lifetime in seconds.
    #[must_use]
    pub const fn seconds(self) -> u64 {
        match self {
            TtlRung::OneHour => 3_600,
            TtlRung::ThreeHours => 3 * 3_600,
            TtlRung::EightHours => 8 * 3_600,
            TtlRung::TwentyFourHours => 24 * 3_600,
            TtlRung::ThreeDays => 3 * 24 * 3_600,
            TtlRung::SevenDays => 7 * 24 * 3_600,
        }
    }

    /// This rung's lifetime in milliseconds.
    #[must_use]
    pub const fn millis(self) -> u64 {
        self.seconds() * 1_000
    }

    /// The compact natural-time label shown on the cell (`1h`, `24h`, `7d`).
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            TtlRung::OneHour => "1h",
            TtlRung::ThreeHours => "3h",
            TtlRung::EightHours => "8h",
            TtlRung::TwentyFourHours => "24h",
            TtlRung::ThreeDays => "3d",
            TtlRung::SevenDays => "7d",
        }
    }

    /// Step one rung up the ladder toward longer life, wrapping `7d → 1h`.
    #[must_use]
    pub fn cycle(self) -> TtlRung {
        let idx = Self::LADDER
            .iter()
            .position(|&r| r == self)
            .expect("every rung is in LADDER");
        Self::LADDER[(idx + 1) % Self::LADDER.len()]
    }
}

/// Render a remaining lifetime as words, for VoiceOver and any text-equivalent
/// of the visual countdown (docs/00 §8). The countdown must never rely on
/// colour or motion alone.
#[must_use]
pub fn humanize_remaining(remaining_ms: u64) -> String {
    let secs = remaining_ms / 1_000;
    if secs == 0 {
        return "expired".to_string();
    }
    if secs < 60 {
        return "less than a minute remaining".to_string();
    }
    let mins = secs / 60;
    if mins < 60 {
        return format!("about {} remaining", plural(mins, "minute"));
    }
    let hours = mins / 60;
    if hours < 48 {
        return format!("about {} remaining", plural(hours, "hour"));
    }
    let days = hours / 24;
    format!("about {} remaining", plural(days, "day"))
}

fn plural(n: u64, unit: &str) -> String {
    if n == 1 {
        format!("1 {unit}")
    } else {
        format!("{n} {unit}s")
    }
}

/// A single dormant piece of content: it holds one thing for a bounded lifetime
/// and clears itself on expiry. Owns its [`SecretBuffer`]; exposes only
/// non-secret state.
pub struct SleeperCell {
    id: CellId,
    secret: SecretBuffer,
    kind: CellKind,
    rung: TtlRung,
    created_at_ms: u64,
    expires_at_ms: u64,
    preview: String,
    byte_len: usize,
}

impl SleeperCell {
    /// Build a cell whose life starts at `now_ms`. The redacted preview is
    /// computed here, in the core, from the plaintext (docs/01 §3).
    pub(crate) fn new(
        id: CellId,
        secret: SecretBuffer,
        kind: CellKind,
        rung: TtlRung,
        now_ms: u64,
    ) -> Self {
        let byte_len = secret.len();
        let preview = redact(secret.expose(), kind);
        Self {
            id,
            secret,
            kind,
            rung,
            created_at_ms: now_ms,
            expires_at_ms: now_ms.saturating_add(rung.millis()),
            preview,
            byte_len,
        }
    }

    #[must_use]
    pub fn id(&self) -> CellId {
        self.id
    }

    #[must_use]
    pub fn kind(&self) -> CellKind {
        self.kind
    }

    #[must_use]
    pub fn rung(&self) -> TtlRung {
        self.rung
    }

    #[must_use]
    pub fn byte_len(&self) -> usize {
        self.byte_len
    }

    #[must_use]
    pub fn preview(&self) -> &str {
        &self.preview
    }

    #[must_use]
    pub fn created_at_ms(&self) -> u64 {
        self.created_at_ms
    }

    #[must_use]
    pub fn expires_at_ms(&self) -> u64 {
        self.expires_at_ms
    }

    /// Milliseconds of life left at `now_ms` (saturating at zero).
    #[must_use]
    pub fn remaining_ms(&self, now_ms: u64) -> u64 {
        self.expires_at_ms.saturating_sub(now_ms)
    }

    /// Whether the cell has reached or passed its expiry.
    #[must_use]
    pub fn is_expired(&self, now_ms: u64) -> bool {
        now_ms >= self.expires_at_ms
    }

    /// In-core access to the owned secret, for the conceal path only.
    pub(crate) fn secret(&self) -> &SecretBuffer {
        &self.secret
    }

    /// Set the cell to `rung`, re-basing its expiry on `now_ms` (reset/extend).
    pub(crate) fn set_rung(&mut self, rung: TtlRung, now_ms: u64) {
        self.rung = rung;
        self.expires_at_ms = now_ms.saturating_add(rung.millis());
    }

    /// Step the cell up the TTL ladder and re-base its expiry, returning the new
    /// rung.
    pub(crate) fn cycle_rung(&mut self, now_ms: u64) -> TtlRung {
        let next = self.rung.cycle();
        self.set_rung(next, now_ms);
        next
    }

    /// A non-secret snapshot safe to hand across the FFI.
    #[must_use]
    pub fn summary(&self, now_ms: u64) -> CellSummary {
        let remaining_ms = self.remaining_ms(now_ms);
        CellSummary {
            id: self.id,
            kind: self.kind,
            rung: self.rung,
            rung_label: self.rung.label().to_string(),
            remaining_ms,
            remaining_label: humanize_remaining(remaining_ms),
            byte_len: self.byte_len,
            preview: self.preview.clone(),
        }
    }
}

/// A non-secret snapshot of a cell: everything the UI needs, nothing it must
/// not have. This is what crosses the FFI (serialized to JSON) — note the
/// absence of any secret field.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CellSummary {
    pub id: CellId,
    pub kind: CellKind,
    pub rung: TtlRung,
    /// Compact label, e.g. `"3h"`.
    pub rung_label: String,
    pub remaining_ms: u64,
    /// Spoken/text-equivalent of the countdown, e.g. `"about 3 hours remaining"`.
    pub remaining_label: String,
    pub byte_len: usize,
    /// Redacted, non-secret preview.
    pub preview: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ladder_seconds_are_correct() {
        assert_eq!(TtlRung::OneHour.seconds(), 3_600);
        assert_eq!(TtlRung::ThreeHours.seconds(), 10_800);
        assert_eq!(TtlRung::EightHours.seconds(), 28_800);
        assert_eq!(TtlRung::TwentyFourHours.seconds(), 86_400);
        assert_eq!(TtlRung::ThreeDays.seconds(), 259_200);
        assert_eq!(TtlRung::SevenDays.seconds(), 604_800);
    }

    #[test]
    fn cycle_walks_up_and_wraps() {
        assert_eq!(TtlRung::OneHour.cycle(), TtlRung::ThreeHours);
        assert_eq!(TtlRung::ThreeHours.cycle(), TtlRung::EightHours);
        assert_eq!(TtlRung::EightHours.cycle(), TtlRung::TwentyFourHours);
        assert_eq!(TtlRung::TwentyFourHours.cycle(), TtlRung::ThreeDays);
        assert_eq!(TtlRung::ThreeDays.cycle(), TtlRung::SevenDays);
        assert_eq!(
            TtlRung::SevenDays.cycle(),
            TtlRung::OneHour,
            "wraps back to 1h"
        );
    }

    #[test]
    fn default_rung_is_short() {
        assert!(TtlRung::DEFAULT.seconds() < TtlRung::TwentyFourHours.seconds());
    }

    #[test]
    fn remaining_and_expiry_track_the_clock() {
        let secret = SecretBuffer::from_text("value");
        let cell = SleeperCell::new(CellId(1), secret, CellKind::Text, TtlRung::OneHour, 0);
        assert_eq!(cell.remaining_ms(0), 3_600_000);
        assert!(!cell.is_expired(3_599_999));
        assert!(cell.is_expired(3_600_000));
        assert_eq!(
            cell.remaining_ms(3_600_001),
            0,
            "remaining saturates at zero"
        );
    }

    #[test]
    fn cycling_a_cell_rebases_expiry_on_now() {
        let secret = SecretBuffer::from_text("value");
        let mut cell = SleeperCell::new(CellId(1), secret, CellKind::Text, TtlRung::OneHour, 0);
        // 30 minutes later, cycle 1h -> 3h; expiry is measured from *now*.
        let now = 30 * 60 * 1_000;
        let new_rung = cell.cycle_rung(now);
        assert_eq!(new_rung, TtlRung::ThreeHours);
        assert_eq!(cell.remaining_ms(now), TtlRung::ThreeHours.millis());
    }

    #[test]
    fn summary_carries_no_secret_but_carries_state() {
        let secret = SecretBuffer::from_text("sk-live_abcdef0123456789abcdef");
        let cell = SleeperCell::new(CellId(7), secret, CellKind::Text, TtlRung::ThreeHours, 0);
        let s = cell.summary(0);
        assert_eq!(s.id, CellId(7));
        assert_eq!(s.rung_label, "3h");
        assert_eq!(s.remaining_label, "about 3 hours remaining");
        assert_eq!(s.preview, "sk-liv…");
        assert!(s.byte_len > 0);
    }

    #[test]
    fn humanize_covers_the_ladder() {
        assert_eq!(humanize_remaining(0), "expired");
        assert_eq!(humanize_remaining(30_000), "less than a minute remaining");
        assert_eq!(humanize_remaining(60_000), "about 1 minute remaining");
        assert_eq!(humanize_remaining(120_000), "about 2 minutes remaining");
        assert_eq!(humanize_remaining(3_600_000), "about 1 hour remaining");
        assert_eq!(humanize_remaining(3 * 3_600_000), "about 3 hours remaining");
        assert_eq!(
            humanize_remaining(3 * 24 * 3_600_000),
            "about 3 days remaining"
        );
    }
}
