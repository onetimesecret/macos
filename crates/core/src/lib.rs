//! The zeroizing heart of the companion: a small in-memory store of
//! sheets — ink plus sealed chips, one pausable countdown per page
//! (interaction-model rev C, docs/spec/04).
//!
//! Design contract (docs/spec/01–05):
//!
//! - **Memory-only.** Sheets live in RAM; process exit is total amnesia
//!   — including the [`ledger`], which is session-bound by design.
//!   Sealed bytes live in a [`SecretBuffer`]: page-locked against swap
//!   while alive (images excluded, documented in doc 05), zeroized at
//!   death, impossible to `Clone`, `Debug`, or serialize.
//!   [`harden_process`] disables core dumps.
//! - **Masking is by gesture, never by content.** The core never
//!   parses, classifies, or scores what arrives — rev C deleted
//!   detection outright. A chip's excerpt is a fixed-budget substring;
//!   counts are counts.
//! - **Evicts by policy, never by surprise.** Every page expires on the
//!   countdown the user chose; at the cap (9 — the keyboard wall) the
//!   store *refuses* a tenth page rather than silently evicting.
//! - **No polling.** Expiry — and hold lapses — are scheduled: the
//!   shell asks [`SheetStore::next_event`] and arms exactly one timer;
//!   on firing it calls [`SheetStore::expire_due`]. Idle CPU stays
//!   at ~0%.
//! - **No UI dependencies.** This crate is testable headless and
//!   survives a shell swap (ADR-0001).

pub mod clock;
pub mod harden;
pub mod ledger;
pub mod secret;
pub mod sheet;
pub mod store;
pub mod ttl;

pub use clock::{Clock, ManualClock, SystemClock};
pub use harden::harden_process;
pub use ledger::{Cause, LedgerRecord, LedgerSegment};
pub use secret::SecretBuffer;
pub use sheet::{ChipId, ChipMeta, Promotion, SealedChip, Segment, Sheet, SheetId};
pub use store::{DEFAULT_SHEET_CAP, LEDGER_CAP, PayloadError, Refusal, SheetStore};
pub use ttl::{TTL_LADDER, Ttl};
