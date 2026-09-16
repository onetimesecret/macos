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
//! - **Masking is by gesture, never by content.** Sealing never classifies
//!   what arrives. ADR-0029 separately permits experimental source-language
//!   detection for bytes explicitly submitted to [`detect_source_language`];
//!   it is not approved for shipping. A chip's excerpt is a fixed-budget
//!   substring; counts are counts.
//! - **Evicts by policy, never by surprise.** Every page expires on the
//!   countdown the user chose, and nothing else ends one: the strip
//!   has no cap, so there is no wall to evict at (issue #158).
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
pub mod file_persist;
pub mod files;
pub mod harden;
mod language_detection;
pub mod ledger;
pub mod persist;
pub mod secret;
pub mod sheet;
pub mod store;
pub mod sync;
pub mod ttl;

/// This crate's semantic version, independent of the FFI crate that links it.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub use blocks::BlockMeta;
pub use clock::{Clock, ManualClock, SystemClock};
pub use files::{
    DRAFT_SNAPSHOT_LIMIT, DroppedReason, ExternalState, FILE_ID_TAG, FILE_SIZE_LIMIT, FileConflict,
    FileId, FileIo, FileNotice, FileStore, FileWitness, LineEnding, OpenFile, OpenRefusal,
    SaveError, StepOutcome,
};
pub use harden::harden_process;
pub use language_detection::detect_source_language;
pub use ledger::{DestinationClass, LEDGER_RETENTION_MS, LedgerEvent, LedgerRecord, SizeClass};
pub use persist::RestoreError;
pub use secret::SecretBuffer;
pub use sheet::{
    ChipId, ChipMeta, Conceal, ItemId, LabelSource, SealedChip, Segment, Sheet, SheetId, Tab,
    TabId, local_day,
};
pub use store::{EditOp, PayloadError, Refusal, RemoteRefusal, SheetStore};
pub use sync::{
    CeremonyBallot, DeltaAdmission, ExpiryPolicy, HoldRegister, PageChannel, TerminalMarker,
};
pub use ttl::{TTL_LADDER, Ttl};
