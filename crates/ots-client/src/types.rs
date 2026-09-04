//! Wire types for the v3 API, grounded in the server's schemas
//! (`src/schemas/api/v3/` in the onetimesecret repo).
//!
//! Deserialization is deliberately liberal: only the fields the
//! companion needs are required; everything else is optional and unknown
//! fields are ignored, so server additions never break the client.

use serde::ser::SerializeStruct;
use serde::{Deserialize, Serialize, Serializer};
use zeroize::Zeroizing;

/// Payload for `POST /api/v3/secret/conceal`. On the wire it is nested
/// under a `secret` key (V2-inherited transport wrapper):
///
/// ```json
/// { "secret": { "kind": "conceal", "secret": "…", "share_domain": "…",
///               "ttl": 28800, "passphrase": "…", "recipient": "…" } }
/// ```
pub struct ConcealPayload {
    /// The secret plaintext; zeroized on drop.
    pub secret: Zeroizing<String>,
    /// Domain the share link should live on.
    pub share_domain: String,
    /// Requested TTL in seconds, sent as given. The server reports no
    /// allowed set today, and a caller must not snap this against a
    /// page's ladder: a link's lifetime is its own (ADR-0026).
    /// [`crate::snap_ttl`] waits for the day the server names a set.
    pub ttl: Option<u64>,
    /// Optional passphrase gate on the secret.
    pub passphrase: Option<Zeroizing<String>>,
    /// Optional recipient email.
    pub recipient: Option<String>,
}

impl ConcealPayload {
    /// A conceal payload for `secret`, shared on `share_domain`.
    #[must_use]
    pub fn new(secret: impl Into<String>, share_domain: impl Into<String>) -> Self {
        Self {
            secret: Zeroizing::new(secret.into()),
            share_domain: share_domain.into(),
            ttl: None,
            passphrase: None,
            recipient: None,
        }
    }

    /// Set the requested TTL (seconds).
    #[must_use]
    pub fn with_ttl(mut self, ttl_secs: u64) -> Self {
        self.ttl = Some(ttl_secs);
        self
    }

    /// Gate the secret behind a passphrase.
    #[must_use]
    pub fn with_passphrase(mut self, passphrase: impl Into<String>) -> Self {
        self.passphrase = Some(Zeroizing::new(passphrase.into()));
        self
    }
}

impl Serialize for ConcealPayload {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut n = 3;
        n += usize::from(self.ttl.is_some());
        n += usize::from(self.passphrase.is_some());
        n += usize::from(self.recipient.is_some());
        let mut s = serializer.serialize_struct("ConcealPayload", n)?;
        s.serialize_field("kind", "conceal")?;
        s.serialize_field("secret", self.secret.as_str())?;
        s.serialize_field("share_domain", &self.share_domain)?;
        if let Some(ttl) = self.ttl {
            s.serialize_field("ttl", &ttl)?;
        }
        if let Some(passphrase) = &self.passphrase {
            s.serialize_field("passphrase", passphrase.as_str())?;
        }
        if let Some(recipient) = &self.recipient {
            s.serialize_field("recipient", recipient)?;
        }
        s.end()
    }
}

/// The receipt half of a conceal response — the sender's handle. The
/// companion keeps only [`ReceiptStub::identifier`] on the live cell.
#[derive(Debug, Clone, Deserialize)]
pub struct ReceiptStub {
    /// Receipt identifier (enables burn-remote for this cell alone).
    pub identifier: String,
    /// Short display id.
    #[serde(default)]
    pub shortid: Option<String>,
    /// Receipt state.
    #[serde(default)]
    pub state: Option<String>,
    /// Secret TTL granted by the server, seconds.
    #[serde(default)]
    pub secret_ttl: Option<u64>,
}

/// The secret half of a conceal response — the recipient's handle.
#[derive(Debug, Clone, Deserialize)]
pub struct SecretStub {
    /// Secret identifier.
    pub identifier: String,
    /// Key used in the share URL path.
    pub key: String,
    /// Short display id.
    #[serde(default)]
    pub shortid: Option<String>,
    /// Secret state.
    #[serde(default)]
    pub state: Option<String>,
    /// Whether a passphrase gates the reveal.
    #[serde(default)]
    pub has_passphrase: bool,
}

/// `record` of a successful conceal: receipt + secret + share domain.
#[derive(Debug, Clone, Deserialize)]
pub struct ConcealData {
    /// The sender's receipt.
    pub receipt: ReceiptStub,
    /// The shareable secret.
    pub secret: SecretStub,
    /// Domain the link lives on (`null` → default domain).
    #[serde(default)]
    pub share_domain: Option<String>,
}

/// Response envelope: v3 wraps single records as `{ "record": …,
/// "details": … }`.
#[derive(Debug, Deserialize)]
pub(crate) struct RecordEnvelope<T> {
    pub record: T,
}

/// Client errors.
#[derive(Debug)]
pub enum Error {
    /// The request never completed (DNS, connect, TLS, timeout).
    Transport(crate::http::TransportError),
    /// The server answered with a non-success status. Surface `message`
    /// inline in the cell; content never leaves it on failure.
    Api {
        /// HTTP status code.
        status: u16,
        /// Server-provided message, when one was parseable.
        message: String,
    },
    /// A 2xx body that did not match the expected shape.
    Decode(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Transport(e) => write!(f, "{e}"),
            Error::Api { status, message } => write!(f, "server said {status}: {message}"),
            Error::Decode(msg) => write!(f, "unexpected response shape: {msg}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<crate::http::TransportError> for Error {
    fn from(e: crate::http::TransportError) -> Self {
        Error::Transport(e)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conceal_payload_serializes_to_v3_shape() {
        let payload = ConcealPayload::new("hunter2", "secrets.example.com").with_ttl(28_800);
        let json = serde_json::to_value(&payload).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "kind": "conceal",
                "secret": "hunter2",
                "share_domain": "secrets.example.com",
                "ttl": 28_800,
            })
        );
    }

    #[test]
    fn optional_fields_are_omitted_not_null() {
        let payload = ConcealPayload::new("s", "d");
        let json = serde_json::to_string(&payload).unwrap();
        assert!(!json.contains("passphrase"));
        assert!(!json.contains("recipient"));
        assert!(!json.contains("ttl"));
    }

    #[test]
    fn conceal_data_parses_liberal() {
        let body = serde_json::json!({
            "receipt": {
                "identifier": "9f2abc",
                "shortid": "9f2",
                "state": "pending",
                "secret_ttl": 7200,
                "some_future_field": true,
            },
            "secret": {
                "identifier": "sec123",
                "key": "abcdef123456",
                "shortid": "abc",
                "state": "pending",
            },
            "share_domain": null,
        });
        let data: ConcealData = serde_json::from_value(body).unwrap();
        assert_eq!(data.receipt.identifier, "9f2abc");
        assert_eq!(data.secret.key, "abcdef123456");
        assert_eq!(data.receipt.secret_ttl, Some(7200));
        assert!(!data.secret.has_passphrase);
        assert_eq!(data.share_domain, None);
    }
}
