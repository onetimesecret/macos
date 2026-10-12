//! Sans-IO client for the [Onetime Secret](https://onetimesecret.com) v3
//! API: [`Api`] builds requests and parses responses; [`Client`] pairs it
//! with a [`Transport`] (docs/spec/05).

pub mod auth;
pub mod http;
pub mod types;

mod api;
mod base64;

pub use api::{Api, Client, share_link, snap_ttl};
pub use auth::{AuthStrategy, BasicAuth, BearerAuth, NoAuth};
pub use http::{HttpRequest, HttpResponse, Transport, TransportError};
pub use types::{ConcealData, ConcealPayload, Error, ReceiptStub, SecretStub};
