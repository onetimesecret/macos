//! Client for the [Onetime Secret](https://onetimesecret.com) v3 API.
//!
//! Built for the macOS companion's conceal flow — the exit ramp an
//! explicit user action opens — but general on purpose: a plain v3
//! client with no UI or platform dependencies.
//!
//! Sans-IO by design: [`Api`] builds [`HttpRequest`]s and parses
//! [`HttpResponse`]s without doing any networking, so the crate is fully
//! testable offline and the eventual transport (and TLS stack) is the
//! caller's choice. [`Client`] pairs an [`Api`] with any [`Transport`].
//!
//! Auth is a swappable strategy ([`AuthStrategy`]): HTTP Basic today,
//! PASETO bearer tokens when v3 auth ships — the swap is additive
//! (docs/spec/05).

pub mod auth;
pub mod http;
pub mod types;

mod api;
mod base64;

pub use api::{Api, Client, share_link, snap_ttl};
pub use auth::{AuthStrategy, BasicAuth, NoAuth};
pub use http::{HttpRequest, HttpResponse, Transport, TransportError};
pub use types::{ConcealData, ConcealPayload, Error, ReceiptStub, SecretStub};
