//! The relay message set (relay-protocol.md §4) as request builders
//! and response parsers. Transport is HTTPS request/response against
//! the second — and last — entry in `crates/transport`'s allowlist;
//! the long-lived connection a relay wants is the long-poll on
//! [`RelayApi::fetch_deltas_request`], living inside that constraint.
//!
//! Every blob through here is already sealed; this module moves base64
//! and status codes, never keys and never plaintext.

use ots_client::{AuthStrategy, HttpRequest, HttpResponse};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::b64;

/// A refusal from the relay, each one a protocol answer with a client
/// move attached — none of them is an error to log and forget.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayRefusal {
    /// `401`: the access token no longer satisfies the relay. The one
    /// authority on expiry (account-auth.md §2) — refresh and retry
    /// the one request.
    Unauthorized,
    /// `409`: the epoch offered is not exactly current+1 (publish), or
    /// not current (deltas). Fetch, catch up, retry or rejoin.
    EpochConflict,
    /// `410 rejoin`: `since` predates the buffer. Drop the stale copy
    /// and adopt the current frame — the whole recovery story.
    Rejoin,
    /// `413 ceremony_required`: the §3 cap; nothing publishes until a
    /// ceremony compacts the channel.
    CeremonyRequired,
    /// Anything else the protocol does not name, status attached.
    Protocol(u16),
}

impl std::fmt::Display for RelayRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unauthorized => write!(f, "relay: unauthorized"),
            Self::EpochConflict => write!(f, "relay: epoch conflict"),
            Self::Rejoin => write!(f, "relay: rejoin required"),
            Self::CeremonyRequired => write!(f, "relay: ceremony required"),
            Self::Protocol(status) => write!(f, "relay: unexpected status {status}"),
        }
    }
}

impl std::error::Error for RelayRefusal {}

/// The attach answer: where the channel stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachAnswer {
    /// The channel's current epoch.
    pub epoch: u64,
    /// Whether a key frame exists to fetch.
    pub frame_present: bool,
    /// The sequence number the next delta fetch should ask from.
    pub next_seq: u64,
}

/// The frame fetch answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameAnswer {
    /// A frame stands at this epoch.
    Present {
        /// The epoch the frame seals.
        epoch: u64,
        /// The sealed frame bytes.
        frame: Vec<u8>,
    },
    /// No frame yet (`404`): the channel is younger than its first
    /// ceremony.
    Absent,
}

/// The delta publish answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublishAnswer {
    /// The sequence the relay assigned to the batch.
    pub seq: u64,
}

/// One long-poll's worth of deltas.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeltaBatch {
    /// The epoch the blobs belong to.
    pub epoch: u64,
    /// Sealed blobs, publish order.
    pub blobs: Vec<Vec<u8>>,
    /// Where the next fetch resumes.
    pub next_seq: u64,
}

/// Sans-IO builder/parser pairs for the §4 messages. Auth is applied
/// per request because the bearer token rotates underneath
/// ([`crate::oauth::TokenKeeper`]).
pub struct RelayApi {
    base_url: String,
}

impl RelayApi {
    /// A relay rooted at `base_url` (no trailing slash), e.g.
    /// `https://relay.onetimesecret.com`.
    #[must_use]
    pub fn new(base_url: impl Into<String>) -> Self {
        let mut base_url = base_url.into();
        while base_url.ends_with('/') {
            base_url.pop();
        }
        Self { base_url }
    }

    fn request(
        &self,
        method: &'static str,
        path: &str,
        body: Option<Value>,
        auth: &dyn AuthStrategy,
    ) -> HttpRequest {
        let mut request = HttpRequest {
            method,
            url: format!("{}{path}", self.base_url),
            headers: Vec::new(),
            body: None,
        };
        if let Some(value) = body {
            request
                .headers
                .push(("Content-Type".into(), "application/json".into()));
            request.body = Some(Zeroizing::new(value.to_string().into_bytes()));
        }
        auth.apply(&mut request);
        request
    }

    /// `POST /channel/attach` — gated by the account, granting exactly
    /// channel access. `device` is the Ed25519 identity fingerprint;
    /// `key_package` the signed static X25519 key of §6.
    #[must_use]
    pub fn attach_request(
        &self,
        device_fingerprint: &str,
        key_package: &[u8],
        auth: &dyn AuthStrategy,
    ) -> HttpRequest {
        self.request(
            "POST",
            "/channel/attach",
            Some(json!({
                "device": device_fingerprint,
                "key_package": b64::encode(key_package),
            })),
            auth,
        )
    }

    /// Parse the attach answer.
    ///
    /// # Errors
    ///
    /// [`RelayRefusal`] on any non-2xx status or a malformed body.
    pub fn parse_attach(response: &HttpResponse) -> Result<AttachAnswer, RelayRefusal> {
        let value = ok_json(response)?;
        Ok(AttachAnswer {
            epoch: field_u64(&value, "epoch")?,
            frame_present: value
                .get("frame_present")
                .and_then(Value::as_bool)
                .ok_or(RelayRefusal::Protocol(response.status))?,
            next_seq: field_u64(&value, "next_seq")?,
        })
    }

    /// `GET /channel/frame`.
    #[must_use]
    pub fn fetch_frame_request(&self, auth: &dyn AuthStrategy) -> HttpRequest {
        self.request("GET", "/channel/frame", None, auth)
    }

    /// Parse the frame answer; `404` is [`FrameAnswer::Absent`], not a
    /// refusal.
    ///
    /// # Errors
    ///
    /// [`RelayRefusal`] on any other non-2xx status or a malformed
    /// body.
    pub fn parse_frame(response: &HttpResponse) -> Result<FrameAnswer, RelayRefusal> {
        if response.status == 404 {
            return Ok(FrameAnswer::Absent);
        }
        let value = ok_json(response)?;
        Ok(FrameAnswer::Present {
            epoch: field_u64(&value, "epoch")?,
            frame: field_blob(&value, "frame").ok_or(RelayRefusal::Protocol(response.status))?,
        })
    }

    /// `PUT /channel/frame` at `epoch` — accepted only at current+1,
    /// atomically superseding the old frame and dropping every older
    /// delta: the supersession is the purge.
    #[must_use]
    pub fn publish_frame_request(
        &self,
        epoch: u64,
        frame: &[u8],
        auth: &dyn AuthStrategy,
    ) -> HttpRequest {
        self.request(
            "PUT",
            "/channel/frame",
            Some(json!({ "epoch": epoch, "frame": b64::encode(frame) })),
            auth,
        )
    }

    /// Parse the frame publish answer (`204`).
    ///
    /// # Errors
    ///
    /// [`RelayRefusal::EpochConflict`] on `409`; other refusals by
    /// status.
    pub fn parse_publish_frame(response: &HttpResponse) -> Result<(), RelayRefusal> {
        match response.status {
            200..=299 => Ok(()),
            status => Err(refusal(status)),
        }
    }

    /// `POST /channel/deltas` — one batch, everything since the last
    /// publish clock tick, each blob already sealed and padded.
    #[must_use]
    pub fn publish_deltas_request(
        &self,
        epoch: u64,
        blobs: &[Vec<u8>],
        auth: &dyn AuthStrategy,
    ) -> HttpRequest {
        let blobs: Vec<String> = blobs.iter().map(|blob| b64::encode(blob)).collect();
        self.request(
            "POST",
            "/channel/deltas",
            Some(json!({ "epoch": epoch, "blobs": blobs })),
            auth,
        )
    }

    /// Parse the delta publish answer.
    ///
    /// # Errors
    ///
    /// [`RelayRefusal::EpochConflict`] on `409`,
    /// [`RelayRefusal::CeremonyRequired`] on `413`; others by status.
    pub fn parse_publish_deltas(response: &HttpResponse) -> Result<PublishAnswer, RelayRefusal> {
        let value = ok_json(response)?;
        Ok(PublishAnswer {
            seq: field_u64(&value, "seq")?,
        })
    }

    /// `GET /channel/deltas?since=…&wait=…` — the long-poll. `wait` is
    /// §8's 25 seconds unless the caller is draining without waiting.
    #[must_use]
    pub fn fetch_deltas_request(
        &self,
        since: u64,
        wait_seconds: u32,
        auth: &dyn AuthStrategy,
    ) -> HttpRequest {
        self.request(
            "GET",
            &format!("/channel/deltas?since={since}&wait={wait_seconds}"),
            None,
            auth,
        )
    }

    /// Parse a delta batch.
    ///
    /// # Errors
    ///
    /// [`RelayRefusal::Rejoin`] on `410` — drop the stale copy, adopt
    /// the current frame; others by status.
    pub fn parse_deltas(response: &HttpResponse) -> Result<DeltaBatch, RelayRefusal> {
        let value = ok_json(response)?;
        let blobs = value
            .get("blobs")
            .and_then(Value::as_array)
            .ok_or(RelayRefusal::Protocol(response.status))?
            .iter()
            .map(|entry| entry.as_str().and_then(b64::decode))
            .collect::<Option<Vec<_>>>()
            .ok_or(RelayRefusal::Protocol(response.status))?;
        Ok(DeltaBatch {
            epoch: field_u64(&value, "epoch")?,
            blobs,
            next_seq: field_u64(&value, "next_seq")?,
        })
    }

    /// `POST /channel/pairing` — one §7 mailbox message, opaque here:
    /// the pairing structs (`crates/ffi/src/pairing.rs`) own their
    /// shape.
    #[must_use]
    pub fn post_pairing_request(&self, message: Value, auth: &dyn AuthStrategy) -> HttpRequest {
        self.request("POST", "/channel/pairing", Some(message), auth)
    }

    /// `GET /channel/pairing?since=…` — poll the mailbox.
    #[must_use]
    pub fn fetch_pairing_request(&self, since: u64, auth: &dyn AuthStrategy) -> HttpRequest {
        self.request(
            "GET",
            &format!("/channel/pairing?since={since}"),
            None,
            auth,
        )
    }

    /// `POST /channel/detach`.
    #[must_use]
    pub fn detach_request(&self, auth: &dyn AuthStrategy) -> HttpRequest {
        self.request("POST", "/channel/detach", None, auth)
    }
}

fn refusal(status: u16) -> RelayRefusal {
    match status {
        401 => RelayRefusal::Unauthorized,
        409 => RelayRefusal::EpochConflict,
        410 => RelayRefusal::Rejoin,
        413 => RelayRefusal::CeremonyRequired,
        status => RelayRefusal::Protocol(status),
    }
}

fn ok_json(response: &HttpResponse) -> Result<Value, RelayRefusal> {
    if !(200..300).contains(&response.status) {
        return Err(refusal(response.status));
    }
    serde_json::from_slice(&response.body).map_err(|_| RelayRefusal::Protocol(response.status))
}

fn field_u64(value: &Value, key: &str) -> Result<u64, RelayRefusal> {
    value
        .get(key)
        .and_then(Value::as_u64)
        .ok_or(RelayRefusal::Protocol(0))
}

fn field_blob(value: &Value, key: &str) -> Option<Vec<u8>> {
    value.get(key).and_then(Value::as_str).and_then(b64::decode)
}

#[cfg(test)]
mod tests {
    use ots_client::BearerAuth;

    use super::*;

    fn api() -> RelayApi {
        RelayApi::new("https://relay.onetimesecret.com/")
    }

    fn auth() -> BearerAuth {
        BearerAuth::new("at-1")
    }

    #[test]
    fn attach_carries_device_and_key_package_under_bearer_auth() {
        let request = api().attach_request("fp-1", b"kp-bytes", &auth());
        assert_eq!(
            request.url,
            "https://relay.onetimesecret.com/channel/attach"
        );
        assert_eq!(request.header("authorization"), Some("Bearer at-1"));
        let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
        assert_eq!(body["device"], "fp-1");
        assert_eq!(body["key_package"], b64::encode(b"kp-bytes"));
    }

    #[test]
    fn parse_attach_reads_the_channel_position() {
        let answer = RelayApi::parse_attach(&HttpResponse {
            status: 200,
            body: br#"{"epoch":3,"frame_present":true,"next_seq":17}"#.to_vec(),
        })
        .unwrap();
        assert_eq!(
            answer,
            AttachAnswer {
                epoch: 3,
                frame_present: true,
                next_seq: 17
            }
        );
    }

    #[test]
    fn the_protocol_statuses_map_to_their_moves() {
        let refusal_of = |status| {
            RelayApi::parse_deltas(&HttpResponse {
                status,
                body: Vec::new(),
            })
            .unwrap_err()
        };
        assert_eq!(refusal_of(401), RelayRefusal::Unauthorized);
        assert_eq!(refusal_of(409), RelayRefusal::EpochConflict);
        assert_eq!(refusal_of(410), RelayRefusal::Rejoin);
        assert_eq!(refusal_of(413), RelayRefusal::CeremonyRequired);
        assert_eq!(refusal_of(500), RelayRefusal::Protocol(500));
    }

    #[test]
    fn frame_404_is_absent_not_an_error() {
        let answer = RelayApi::parse_frame(&HttpResponse {
            status: 404,
            body: Vec::new(),
        })
        .unwrap();
        assert_eq!(answer, FrameAnswer::Absent);
    }

    #[test]
    fn delta_blobs_round_trip_through_base64() {
        let request = api().publish_deltas_request(2, &[b"sealed-1".to_vec()], &auth());
        let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
        let echoed = HttpResponse {
            status: 200,
            body: format!(r#"{{"epoch":2,"blobs":{},"next_seq":5}}"#, body["blobs"]).into_bytes(),
        };
        let batch = RelayApi::parse_deltas(&echoed).unwrap();
        assert_eq!(batch.blobs, vec![b"sealed-1".to_vec()]);
    }

    #[test]
    fn long_poll_carries_since_and_wait() {
        let request = api().fetch_deltas_request(17, 25, &auth());
        assert!(request.url.ends_with("/channel/deltas?since=17&wait=25"));
    }
}
