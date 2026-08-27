//! The sync channel's client half, sans-IO like `ots-client`: this
//! crate builds [`ots_client::HttpRequest`]s and parses
//! [`ots_client::HttpResponse`]s; something else moves the bytes.
//!
//! Two protocols live here, each specified before it was built:
//!
//! - **Account auth** ([`oauth`], issue #98): OAuth 2.0 authorization
//!   code + PKCE in the system browser, returning on a loopback
//!   redirect (`docs/spec/feature/sync/account-auth.md`, RFC 8252).
//!   [`loopback`] is the one-shot listener that redirect lands on —
//!   local-interface IO only, never the outbound boundary.
//! - **The relay message set** ([`relay`], issue #99):
//!   `docs/spec/feature/sync/relay-protocol.md` §4 as request builders
//!   and response parsers. Every payload that reaches a relay body is
//!   sealed before it gets here; [`pad`] gives sealed blobs their
//!   power-of-two wire size (§8), and [`envelope`] is the plaintext
//!   shape inside a sealed delta — encoded and decoded strictly on the
//!   client side of the seal.
//!
//! What this crate never holds: keys (the GOP chain and pairing live in
//! `companion-ffi`), plaintext page content, or a socket to the relay
//! (the transport is the integrator's, `crates/transport`).

pub mod envelope;
pub mod loopback;
pub mod oauth;
pub mod pad;
pub mod relay;

mod b64;

pub use envelope::{ByteBlob, ControlPayload, DeltaEnvelope};
pub use oauth::{AuthCeremony, SyncAuthError, TokenGrant, TokenKeeper};
pub use relay::{
    AttachAnswer, DeltaBatch, FrameAnswer, PeerAttachment, PublishAnswer, RelayApi, RelayRefusal,
};
