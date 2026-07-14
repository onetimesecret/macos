//! Promotion: the exit ramp, behind the seam (docs/spec/04).
//!
//! The only network action in the app. Sealed bytes travel **core →
//! `ots-client` → transport** inside this module; the shell hands over
//! ids and options, and gets back non-secret JSON. On success the share
//! link lands on the clipboard and only the receipt identifier stays on
//! the chip (doc 03 §5 — no link, no history).
//!
//! This half is sans-network: it builds and interprets the conceal
//! call through any [`Transport`], so tests drive it with a mock and CI
//! never opens a socket. The extern fns in `lib.rs` pair it with
//! `UreqTransport`, the one real transport.

use std::time::Duration;

use companion_core::TTL_LADDER;
use ots_client::{
    AuthStrategy, BasicAuth, Client, ConcealPayload, Error, NoAuth, Transport, share_link, snap_ttl,
};
use zeroize::Zeroizing;

/// Where promotion goes: the app's one outbound destination plus the
/// Basic-auth username half. Non-secret — the API token never sits
/// here; it lives in the credential store and is loaded per call.
#[derive(Clone)]
pub(crate) struct Connection {
    /// Server base URL, `https://` only (the network boundary).
    pub server_url: String,
    /// Domain the share link should live on; empty means the server's
    /// host.
    pub share_domain: String,
    /// Organization `extid` — the Basic-auth username. Empty means
    /// guest-only.
    pub extid: String,
}

impl Connection {
    /// The share domain a payload should carry: the configured one, or
    /// the server's own host when none is set.
    fn effective_share_domain(&self) -> String {
        if !self.share_domain.is_empty() {
            return self.share_domain.clone();
        }
        self.server_url
            .trim_start_matches("https://")
            .trim_end_matches('/')
            .to_owned()
    }
}

/// Options the confirmation step gathers. All optional: TTL defaults to
/// the sheet's remaining time snapped to the ladder.
pub(crate) struct PromoteOpts {
    pub ttl_secs: Option<u64>,
    pub passphrase: Option<Zeroizing<String>>,
    pub recipient: Option<String>,
}

impl PromoteOpts {
    /// Parse the options JSON. `None` (or `{}`) is a valid, all-default
    /// options object; malformed JSON is a refusal, not a guess.
    pub fn parse(json: Option<&str>) -> Option<Self> {
        let Some(json) = json else {
            return Some(Self {
                ttl_secs: None,
                passphrase: None,
                recipient: None,
            });
        };
        let value: serde_json::Value = serde_json::from_str(json).ok()?;
        if !value.is_object() {
            return None;
        }
        Some(Self {
            ttl_secs: value.get("ttl_secs").and_then(serde_json::Value::as_u64),
            passphrase: value
                .get("passphrase")
                .and_then(serde_json::Value::as_str)
                .filter(|s| !s.is_empty())
                .map(|s| Zeroizing::new(s.to_owned())),
            recipient: value
                .get("recipient")
                .and_then(serde_json::Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
        })
    }
}

/// The sheet's remaining time snapped **down** to a ladder value — the
/// promoted secret never outlives the local intent (open question №13).
pub(crate) fn ladder_snapped_ttl(remaining: Duration) -> u64 {
    let allowed: Vec<u64> = TTL_LADDER.iter().map(Duration::as_secs).collect();
    // The ladder is non-empty, so `snap_ttl` always finds a value.
    snap_ttl(remaining.as_secs(), &allowed).unwrap_or_else(|| TTL_LADDER[0].as_secs())
}

/// The outcome the seam reports: the share link (for the clipboard,
/// core-side) and the receipt identifier (the only thing retained).
#[derive(Debug)]
pub(crate) struct Promoted {
    pub link: String,
    pub receipt_id: String,
}

/// One conceal call: authenticated (Basic: `extid` + token) when a
/// token is present and an `extid` is configured, the guest route
/// otherwise. The payload is consumed and zeroized either way; on
/// failure nothing has left the sheet.
// By-value on purpose: the payload (and token) are consumed here and
// zeroize on drop when the call returns, success or failure — a
// reference would leave the caller holding live sealed bytes longer.
#[allow(clippy::needless_pass_by_value)]
pub(crate) fn promote<T: Transport>(
    conn: &Connection,
    token: Option<Zeroizing<String>>,
    payload: Zeroizing<String>,
    opts: &PromoteOpts,
    default_ttl_secs: u64,
    transport: T,
) -> Result<Promoted, String> {
    let mut conceal_payload = ConcealPayload::new(payload.as_str(), conn.effective_share_domain())
        .with_ttl(opts.ttl_secs.unwrap_or(default_ttl_secs));
    if let Some(passphrase) = &opts.passphrase {
        conceal_payload = conceal_payload.with_passphrase(passphrase.as_str());
    }
    conceal_payload.recipient.clone_from(&opts.recipient);

    let authenticated = token.is_some() && !conn.extid.is_empty();
    let auth: Box<dyn AuthStrategy> = match &token {
        Some(token) if authenticated => Box::new(BasicAuth::new(&conn.extid, token.as_str())),
        _ => Box::new(NoAuth),
    };
    let client = Client::new(conn.server_url.clone(), auth, transport);
    let result = if authenticated {
        client.conceal(&conceal_payload)
    } else {
        client.guest_conceal(&conceal_payload)
    };
    match result {
        Ok(data) => Ok(Promoted {
            link: share_link(conn.server_url.as_str(), &data),
            receipt_id: data.receipt.identifier,
        }),
        // Error strings carry no secret material: transport errors are
        // connection-level, API errors are the server's own message.
        Err(Error::Transport(e)) => Err(format!("could not reach the server: {e}")),
        Err(Error::Api { status, message }) => {
            Err(format!("the server refused ({status}): {message}"))
        }
        Err(Error::Decode(e)) => Err(format!("unreadable server response: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use ots_client::{HttpRequest, HttpResponse, TransportError};

    use super::*;

    /// Captures the one request and returns a canned response.
    struct MockTransport {
        seen: RefCell<Option<HttpRequest>>,
        response: RefCell<Option<Result<HttpResponse, TransportError>>>,
    }

    impl MockTransport {
        fn returning(status: u16, body: &str) -> Self {
            Self {
                seen: RefCell::new(None),
                response: RefCell::new(Some(Ok(HttpResponse {
                    status,
                    body: body.as_bytes().to_vec(),
                }))),
            }
        }

        fn failing(message: &str) -> Self {
            Self {
                seen: RefCell::new(None),
                response: RefCell::new(Some(Err(TransportError(message.into())))),
            }
        }
    }

    impl Transport for &MockTransport {
        fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
            *self.seen.borrow_mut() = Some(request);
            self.response.borrow_mut().take().expect("one send only")
        }
    }

    fn conn() -> Connection {
        Connection {
            server_url: "https://eu.onetimesecret.com".into(),
            share_domain: String::new(),
            extid: "org_123".into(),
        }
    }

    const OK_BODY: &str = r#"{"record":{
        "receipt":{"identifier":"rcpt_9f2"},
        "secret":{"identifier":"scrt_1","key":"abcdef"},
        "share_domain":null}}"#;

    fn defaults() -> PromoteOpts {
        PromoteOpts::parse(None).unwrap()
    }

    #[test]
    fn authenticated_when_token_and_extid_present() {
        let transport = MockTransport::returning(200, OK_BODY);
        let out = promote(
            &conn(),
            Some(Zeroizing::new("tok".into())),
            Zeroizing::new("the payload".into()),
            &defaults(),
            28_800,
            &transport,
        )
        .unwrap();
        let seen = transport.seen.borrow();
        let req = seen.as_ref().unwrap();
        assert!(req.url.ends_with("/api/v3/secret/conceal"));
        assert!(req.header("Authorization").is_some());
        assert_eq!(out.receipt_id, "rcpt_9f2");
        assert_eq!(out.link, "https://eu.onetimesecret.com/secret/abcdef");
    }

    #[test]
    fn guest_route_without_token_and_never_credentialed() {
        let transport = MockTransport::returning(200, OK_BODY);
        promote(
            &conn(),
            None,
            Zeroizing::new("p".into()),
            &defaults(),
            3_600,
            &transport,
        )
        .unwrap();
        let seen = transport.seen.borrow();
        let req = seen.as_ref().unwrap();
        assert!(req.url.ends_with("/api/v3/guest/secret/conceal"));
        assert!(req.header("Authorization").is_none());
    }

    #[test]
    fn payload_carries_ttl_and_derived_share_domain() {
        let transport = MockTransport::returning(200, OK_BODY);
        let opts = PromoteOpts::parse(Some(r#"{"ttl_secs": 3600}"#)).unwrap();
        promote(
            &conn(),
            None,
            Zeroizing::new("p".into()),
            &opts,
            28_800,
            &transport,
        )
        .unwrap();
        let seen = transport.seen.borrow();
        let body = seen.as_ref().unwrap().body.as_ref().unwrap();
        let v: serde_json::Value = serde_json::from_slice(body).unwrap();
        assert_eq!(v["secret"]["ttl"], 3600);
        assert_eq!(v["secret"]["share_domain"], "eu.onetimesecret.com");
    }

    #[test]
    fn errors_are_messages_not_panics() {
        let transport = MockTransport::failing("dns");
        let err = promote(
            &conn(),
            None,
            Zeroizing::new("p".into()),
            &defaults(),
            3_600,
            &transport,
        )
        .unwrap_err();
        assert!(err.contains("could not reach the server"));

        let transport = MockTransport::returning(401, r#"{"message":"bad credentials"}"#);
        let err = promote(
            &conn(),
            Some(Zeroizing::new("tok".into())),
            Zeroizing::new("p".into()),
            &defaults(),
            3_600,
            &transport,
        )
        .unwrap_err();
        assert!(err.contains("401") && err.contains("bad credentials"));
    }

    #[test]
    fn ttl_snaps_down_the_ladder() {
        // 5h remaining → 3h rung, never 8h.
        assert_eq!(ladder_snapped_ttl(Duration::from_secs(5 * 3600)), 3 * 3600);
        // Shorter than every rung → the smallest rung, not zero.
        assert_eq!(ladder_snapped_ttl(Duration::from_secs(60)), 3600);
    }

    #[test]
    fn opts_parse_rejects_malformed_json() {
        assert!(PromoteOpts::parse(Some("not json")).is_none());
        assert!(PromoteOpts::parse(Some("[1,2]")).is_none());
        let opts = PromoteOpts::parse(Some(
            r#"{"ttl_secs":60,"passphrase":"pw","recipient":"a@b.c"}"#,
        ))
        .unwrap();
        assert_eq!(opts.ttl_secs, Some(60));
        assert_eq!(opts.passphrase.as_deref().map(String::as_str), Some("pw"));
        assert_eq!(opts.recipient.as_deref(), Some("a@b.c"));
    }
}
