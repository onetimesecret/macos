//! Conceal: the exit ramp, behind the seam (docs/spec/04).
//!
//! The one place an explicit user action sends content out. Sealed
//! bytes travel **core → `ots-client` → transport** inside this module;
//! the shell hands over ids and options, and gets back non-secret JSON.
//! On success the share link lands on the clipboard and only the
//! receipt identifier stays on the chip (doc 03 §5 — no link, no
//! history).
//!
//! This half is sans-network: it builds and interprets the conceal
//! call through any [`Transport`], so tests drive it with a mock and CI
//! never opens a socket. The extern fns in `lib.rs` pair it with the
//! handle's [`Wire`]: `UreqTransport`, the one real transport, in every
//! shipping build, and under `test-util` optionally a [`StubWire`] the
//! Swift suite installs so a conceal can be driven to the wire and
//! read back without a socket.

use companion_transport::UreqTransport;
use ots_client::{
    AuthStrategy, BasicAuth, Client, ConcealPayload, Error, HttpRequest, HttpResponse, NoAuth,
    Transport, TransportError, share_link,
};
use zeroize::Zeroizing;

/// Where a conceal goes: the conceal server plus the Basic-auth
/// username half. Non-secret — the API token never sits here; it
/// lives in the credential store and is loaded per call.
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

/// Options the confirmation step gathers. All optional: an unnamed TTL
/// is [`LINK_DEFAULT_TTL_SECS`], the link's own seven days (ADR-0011
/// section 5); the page's remaining time is not an input (ADR-0026).
pub(crate) struct ConcealOpts {
    pub ttl_secs: Option<u64>,
    pub passphrase: Option<Zeroizing<String>>,
    pub recipient: Option<String>,
}

impl ConcealOpts {
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

/// The link's own default TTL when the caller names none: exactly seven
/// days (ADR-0011 section 5). A link's lifetime is chosen as a link's
/// lifetime; the page it was cut from is not an input (ADR-0026), so no
/// page clock and no page ladder is consulted here. If the server ever
/// reports an allowed-TTL set that excludes this value, the selection
/// rule against that list is a separate decision (ADR-0011 eject
/// trigger), not a fallback to the page ladder.
pub(crate) const LINK_DEFAULT_TTL_SECS: u64 = 7 * 24 * 60 * 60;

/// The outcome the seam reports: the share link (for the clipboard,
/// core-side) and the receipt identifier (the only thing retained).
#[derive(Debug)]
pub(crate) struct Concealed {
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
pub(crate) fn conceal<T: Transport>(
    conn: &Connection,
    token: Option<Zeroizing<String>>,
    payload: Zeroizing<String>,
    opts: &ConcealOpts,
    transport: T,
) -> Result<Concealed, String> {
    let mut conceal_payload = ConcealPayload::new(payload.as_str(), conn.effective_share_domain())
        .with_ttl(opts.ttl_secs.unwrap_or(LINK_DEFAULT_TTL_SECS));
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
        Ok(data) => Ok(Concealed {
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

/// The transport a handle sends on. One per handle, built with it:
/// the real transport is cheap to clone (an `Arc`-shared agent), and
/// the transport crate asks for one agent reused over building a fresh
/// one per call. In a shipping build this is `UreqTransport` and
/// nothing else; the `Stub` arm exists only under `test-util`
/// (ADR-0018), installed by `companion_test_wire_stub`, so the release
/// artifact carries one arm and the match below is a plain call.
#[derive(Clone)]
pub(crate) enum Wire {
    /// The one real transport: TLS-only, the network boundary of doc 05.
    Real(UreqTransport),
    /// A canned answer and a redacted record of what was asked, for
    /// the shell suite. Never constructed outside the seam.
    #[cfg(feature = "test-util")]
    Stub(std::sync::Arc<StubWire>),
}

impl Wire {
    /// A handle's wire as every shipping constructor builds it.
    pub(crate) fn real() -> Self {
        Self::Real(UreqTransport::new())
    }
}

impl Transport for Wire {
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
        match self {
            Self::Real(transport) => transport.send(request),
            #[cfg(feature = "test-util")]
            Self::Stub(stub) => stub.send(request),
        }
    }
}

/// A transport that answers every request from one canned response
/// and keeps, per request, only a redacted summary: the method, the
/// URL, whether an `Authorization` header rode along, and the
/// non-secret fields of a conceal body. The body itself is read once
/// for those fields and dropped, zeroizing, before `send` returns, so
/// the record holds no payload and no passphrase and can cross the
/// seam like any other non-secret JSON. A test seam, compiled only
/// under `test-util` (ADR-0018).
#[cfg(feature = "test-util")]
pub(crate) struct StubWire {
    /// `Ok(status, body)` for an HTTP answer of any status; `Err` for
    /// a delivery failure before any status exists, the way an outage
    /// looks to the client.
    answer: Result<(u16, Vec<u8>), String>,
    /// Every request seen, oldest first.
    seen: std::sync::Mutex<Vec<WireRecord>>,
}

/// What [`StubWire`] keeps of one request. Rendered as JSON by
/// [`StubWire::last_json`]:
/// `{"method", "url", "authorized", "ttl", "share_domain",
///   "has_passphrase", "recipient"}`, the last four null or false when
/// the body carried no conceal payload.
#[cfg(feature = "test-util")]
#[derive(Clone, Debug)]
pub(crate) struct WireRecord {
    method: String,
    url: String,
    authorized: bool,
    ttl: Option<u64>,
    share_domain: Option<String>,
    has_passphrase: bool,
    recipient: Option<String>,
}

#[cfg(feature = "test-util")]
impl StubWire {
    /// A stub answering with `status` and `body`. A `status` of zero
    /// means no answer at all: every send fails as an outage.
    pub(crate) fn answering(status: u16, body: &str) -> Self {
        let answer = if status == 0 {
            Err("stubbed outage".to_owned())
        } else {
            Ok((status, body.as_bytes().to_vec()))
        };
        Self {
            answer,
            seen: std::sync::Mutex::new(Vec::new()),
        }
    }

    /// The most recent request's record as JSON, or `None` before the
    /// first send.
    pub(crate) fn last_json(&self) -> Option<String> {
        let seen = self
            .seen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        seen.last().map(|record| {
            serde_json::json!({
                "method": record.method,
                "url": record.url,
                "authorized": record.authorized,
                "ttl": record.ttl,
                "share_domain": record.share_domain,
                "has_passphrase": record.has_passphrase,
                "recipient": record.recipient,
            })
            .to_string()
        })
    }

    /// The redaction: the four non-secret fields of a conceal body,
    /// read by name, and nothing else of it. Anything unparseable is
    /// simply an absence, never an echo.
    fn summarize(request: &HttpRequest) -> WireRecord {
        let body = request
            .body
            .as_deref()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(bytes).ok());
        let secret = body.as_ref().and_then(|value| value.get("secret"));
        let field = |name: &str| secret.and_then(|value| value.get(name));
        WireRecord {
            method: request.method.to_owned(),
            url: request.url.clone(),
            authorized: request.header("Authorization").is_some(),
            ttl: field("ttl").and_then(serde_json::Value::as_u64),
            share_domain: field("share_domain")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned),
            has_passphrase: field("passphrase").is_some_and(|value| !value.is_null()),
            recipient: field("recipient")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned),
        }
    }
}

#[cfg(feature = "test-util")]
impl Transport for StubWire {
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
        let record = Self::summarize(&request);
        drop(request);
        self.seen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(record);
        match &self.answer {
            Ok((status, body)) => Ok(HttpResponse {
                status: *status,
                body: body.clone(),
            }),
            Err(message) => Err(TransportError(message.clone())),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

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

    fn defaults() -> ConcealOpts {
        ConcealOpts::parse(None).unwrap()
    }

    #[test]
    fn authenticated_when_token_and_extid_present() {
        let transport = MockTransport::returning(200, OK_BODY);
        let out = conceal(
            &conn(),
            Some(Zeroizing::new("tok".into())),
            Zeroizing::new("the payload".into()),
            &defaults(),
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
        conceal(
            &conn(),
            None,
            Zeroizing::new("p".into()),
            &defaults(),
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
        let opts = ConcealOpts::parse(Some(r#"{"ttl_secs": 3600}"#)).unwrap();
        conceal(&conn(), None, Zeroizing::new("p".into()), &opts, &transport).unwrap();
        let seen = transport.seen.borrow();
        let body = seen.as_ref().unwrap().body.as_ref().unwrap();
        let v: serde_json::Value = serde_json::from_slice(body).unwrap();
        assert_eq!(v["secret"]["ttl"], 3600);
        assert_eq!(v["secret"]["share_domain"], "eu.onetimesecret.com");
    }

    #[test]
    fn errors_are_messages_not_panics() {
        let transport = MockTransport::failing("dns");
        let err = conceal(
            &conn(),
            None,
            Zeroizing::new("p".into()),
            &defaults(),
            &transport,
        )
        .unwrap_err();
        assert!(err.contains("could not reach the server"));

        let transport = MockTransport::returning(401, r#"{"message":"bad credentials"}"#);
        let err = conceal(
            &conn(),
            Some(Zeroizing::new("tok".into())),
            Zeroizing::new("p".into()),
            &defaults(),
            &transport,
        )
        .unwrap_err();
        assert!(err.contains("401") && err.contains("bad credentials"));
    }

    #[test]
    fn ttl_defaults_to_seven_days_when_unnamed() {
        // ADR-0011 section 5: the link default is a fixed seven days and
        // takes no page clock as an input (ADR-0026).
        let transport = MockTransport::returning(200, OK_BODY);
        conceal(
            &conn(),
            None,
            Zeroizing::new("p".into()),
            &defaults(),
            &transport,
        )
        .unwrap();
        let seen = transport.seen.borrow();
        let body = seen.as_ref().unwrap().body.as_ref().unwrap();
        let v: serde_json::Value = serde_json::from_slice(body).unwrap();
        assert_eq!(v["secret"]["ttl"], 604_800);
    }

    #[test]
    fn opts_parse_rejects_malformed_json() {
        assert!(ConcealOpts::parse(Some("not json")).is_none());
        assert!(ConcealOpts::parse(Some("[1,2]")).is_none());
        let opts = ConcealOpts::parse(Some(
            r#"{"ttl_secs":60,"passphrase":"pw","recipient":"a@b.c"}"#,
        ))
        .unwrap();
        assert_eq!(opts.ttl_secs, Some(60));
        assert_eq!(opts.passphrase.as_deref().map(String::as_str), Some("pw"));
        assert_eq!(opts.recipient.as_deref(), Some("a@b.c"));
    }
}
