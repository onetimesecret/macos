//! The ledger — where dead pages rest (doc 03 amendment A, doc 04).
//!
//! Rev B's law read "no retention". Lived experience overruled the
//! absolutism: a page that expires mid-thought takes typed context with
//! it. The ledger is the narrow amendment, and the boundary holds where
//! it matters:
//!
//! - **Ink only.** Sealed bytes are zeroized at death exactly as before;
//!   a chip survives solely as its (never-secret) excerpt, struck
//!   through as "zeroized". Nothing sealed survives, ever, anywhere.
//! - **Read-only.** Records, not pages — no editing, no resurrection.
//! - **Store-bound.** In memory, dies with the store; it survives a
//!   relaunch only inside the store's encrypted snapshot
//!   ([`crate::persist`]), where a tombstone still carries nothing but
//!   its excerpt. Capacity is bounded (newest dozen); older records
//!   fall off silently.

use std::time::Instant;

/// How a page died.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cause {
    /// The countdown reached zero; removal was silent — the user set
    /// the clock.
    Expired,
    /// The user closed the tab.
    Closed,
}

/// One run of a dead page: dimmed ink, or the tombstone of a chip.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LedgerSegment {
    /// Visible ink, exactly as it was when the page died. It was never
    /// secret; copying it back out is allowed.
    Ink(String),
    /// A sealed chip stood here. Its bytes were zeroized at death; the
    /// excerpt is all that ever rendered, and all that remains.
    Tombstone {
        /// The chip's mechanical excerpt.
        excerpt: String,
    },
}

/// A dead page: residue, not storage.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerRecord {
    pub(crate) cause: Cause,
    pub(crate) title: String,
    pub(crate) segments: Vec<LedgerSegment>,
    /// When the page died — kept so a fixed age-out window within a
    /// session (open question №10) stays possible; none is enforced
    /// today.
    pub(crate) died_at: Instant,
}

impl LedgerRecord {
    /// How the page died.
    #[must_use]
    pub fn cause(&self) -> Cause {
        self.cause
    }

    /// The page's title at death (same derivation as a live tab).
    #[must_use]
    pub fn title(&self) -> &str {
        &self.title
    }

    /// The dead page's runs, in document order.
    #[must_use]
    pub fn segments(&self) -> &[LedgerSegment] {
        &self.segments
    }

    /// When the page died.
    #[must_use]
    pub fn died_at(&self) -> Instant {
        self.died_at
    }
}
