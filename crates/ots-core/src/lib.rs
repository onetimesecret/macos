//! # ots-core — the trust core
//!
//! This crate owns everything that touches a plaintext secret: the
//! [`SecretBuffer`](secret::SecretBuffer) that locks and wipes memory, the
//! [`SleeperCell`](cell::SleeperCell) and its TTL ladder, the bounded
//! [`CellStore`](store::CellStore), credential storage, and the Onetime Secret
//! v3 conceal client.
//!
//! It carries **no Apple assumptions** (docs/01 decision D4): it compiles and
//! is fully unit-tested on any Unix host. The macOS-only pieces (Keychain via
//! `security-framework`, an `NSPasteboard`-backed reader) are `cfg`-gated with
//! portable fallbacks so the security-critical logic can be exercised anywhere.
//!
//! ## The boundary law (docs/01 §3)
//!
//! Plaintext secret bytes live *only* here, in memory this crate owns, locks,
//! and zeroes. Nothing above the FFI is ever handed a secret — only opaque
//! [`CellId`](cell::CellId)s, non-secret [`CellSummary`](cell::CellSummary)
//! metadata, and the *outputs* of an action (a [`ShareLink`](api::ShareLink)).
//! [`SecretBuffer`] deliberately implements none of `Clone`, `Copy`, `Debug`,
//! `Display`, `Serialize`, or `Deserialize`.

pub mod api;
pub mod cache;
pub mod cell;
pub mod clock;
pub mod crypto;
pub mod init;
pub mod keychain;
pub mod pasteboard;
pub mod preview;
pub mod secret;
pub mod store;

pub use api::{ConcealError, ConcealOpts, Credentials, ShareLink};
pub use cache::{ApiConfig, Cache, IngestError};
pub use cell::{CellId, CellKind, CellSummary, SleeperCell, TtlRung};
pub use clock::{Clock, ManualClock, SystemClock};
pub use keychain::{CredentialStore, InMemoryCredentialStore, KeychainError};
pub use secret::SecretBuffer;
pub use store::{CellStore, EvictionPolicy, DEFAULT_CAPACITY};
