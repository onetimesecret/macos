//! The zeroizing heart of the companion: a small in-memory store of
//! sheets — ink plus sealed chips, one pausable countdown per page
//! (interaction-model rev C, docs/spec/04).
//!
//! Design contract (docs/spec/01–05):
//!
//! - **Memory-first, with one deliberate exit.** Sheets live in RAM.
//!   Sealed bytes live in a [`SecretBuffer`]: page-locked against swap
//!   while alive (images excluded, documented in doc 05), zeroized at
//!   death, impossible to `Clone`, `Debug`, or serialize.
//!   [`harden_process`] disables core dumps. The one exit is
//!   [`persist`]: at the shell's explicit request the whole store
//!   crosses to disk *encrypted* at quit and comes back at launch —
//!   never in plaintext, never on its own (see the module docs).
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

// Crate-private on purpose: block identity is bookkeeping the store
// drives; only the read-shaped [`BlockMeta`] leaves the crate.
mod blocks;
pub mod clock;
// Crate-private on purpose: every Loro API call stays behind this one
// module's seam (ADR-0013), and the store speaks to it in UTF-16 code
// units only.
mod document;
pub mod harden;
pub mod ledger;
pub mod persist;
pub mod secret;
pub mod sheet;
pub mod store;
pub mod ttl;

pub use blocks::BlockMeta;
pub use clock::{Clock, ManualClock, SystemClock};
pub use harden::harden_process;
pub use ledger::{DestinationClass, LEDGER_RETENTION_MS, LedgerEvent, LedgerRecord, SizeClass};
pub use persist::RestoreError;
pub use secret::SecretBuffer;
pub use sheet::{
    ChipId, ChipMeta, ItemId, Promotion, SealedChip, Segment, Sheet, SheetId, Tab, TabId,
};
pub use store::{DEFAULT_SHEET_CAP, EditOp, PayloadError, Refusal, SheetStore};
pub use ttl::{TTL_LADDER, Ttl};
