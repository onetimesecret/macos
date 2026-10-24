//! The companion's in-memory sheet store: ink plus sealed chips, one
//! pausable countdown per page (docs/spec/design/04 and 05, ADR-0001).

mod blocks;
pub mod clock;
// Every Loro call stays behind this module; the store speaks UTF-16 to it.
mod document;
pub mod file_persist;
pub mod files;
// The sealed fragment's envelope; the shell carries its bytes unread
// (ADR-0045 point 1).
mod fragment;
pub mod harden;
mod ink;
mod language_detection;
pub mod ledger;
// What a peer learns of a sealed object beside the page's ops (ADR-0058 point 5).
mod metadata;
mod note;
pub mod persist;
pub mod secret;
pub mod sheet;
pub mod store;
pub mod sync;
// Copy, cut, paste and the drags (Law 0001: the copy, cut, paste and drag rows).
mod transfer;
pub mod ttl;

/// This crate's semantic version.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub use blocks::BlockMeta;
pub use clock::{Clock, ManualClock, SystemClock};
pub use document::{EditIntent, EditSelection, TextSelection};
pub use files::{
    DRAFT_SNAPSHOT_LIMIT, DroppedReason, ExternalState, FILE_ID_TAG, FILE_SIZE_LIMIT, FileConflict,
    FileId, FileIo, FileNotice, FileStore, FileWitness, HydrationFate, HydrationOutcome,
    LineEnding, OpenFile, OpenRefusal, PathRebind, RelocateRefusal, SaveError,
};
pub use fragment::{Copied, CopyRefusal, EnvelopeCap};
pub use harden::harden_process;
pub use ink::StepOutcome;
pub use language_detection::detect_source_language;
pub use ledger::{DestinationClass, LEDGER_RETENTION_MS, LedgerEvent, LedgerRecord, SizeClass};
pub use metadata::{NameVersion, ObjectMetadata};
pub use persist::RestoreError;
pub use secret::SecretBuffer;
pub use sheet::{
    Availability, ChipId, ChipMeta, Conceal, ItemId, LabelSource, LocalValue, NAME_CAP,
    NameRefusal, PeerKind, SealedChip, Segment, Sheet, SheetId, Tab, TabId, judge_name, local_day,
};
pub use store::{EditOp, PayloadError, Refusal, RemoteRefusal, SheetStore};
pub use sync::{
    CeremonyBallot, DeltaAdmission, ExpiryPolicy, HoldRegister, PageChannel, TerminalMarker,
};
pub use transfer::Placed;
pub use ttl::{TTL_LADDER, Ttl};
