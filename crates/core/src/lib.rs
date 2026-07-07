//! The zeroizing heart of the companion: a small in-memory store of
//! [`Cell`]s (`SleeperCell`s in spec language), each with a visible,
//! limited time-to-live.
//!
//! Design contract (docs/spec/01–04):
//!
//! - **Memory-only.** Cells live in RAM; process exit is total amnesia.
//!   Content buffers are zeroized on expiry and discard.
//! - **Evicts by policy, never by surprise.** Every cell expires on the
//!   TTL the user chose; at the soft cap the store *refuses* new content
//!   rather than silently evicting deliberately placed cells.
//! - **No polling.** Expiry is scheduled: the shell asks
//!   [`CellStore::next_deadline`] and arms exactly one timer; on firing it
//!   calls [`CellStore::expire_due`]. Idle CPU stays at ~0%.
//! - **No UI dependencies.** This crate is testable headless and survives
//!   a shell swap (ADR-0001).

pub mod cell;
pub mod clock;
pub mod detect;
pub mod store;
pub mod ttl;

pub use cell::{Cell, CellContent, CellId, CellKind, LifecycleState, Promotion};
pub use clock::{Clock, ManualClock, SystemClock};
pub use detect::secret_shape;
pub use store::{CellStore, StageError};
pub use ttl::{TTL_LADDER, Ttl};
