//! Conceal, the one user-initiated send (docs/spec/04). Sans-network:
//! `lib.rs` pairs it with the handle's [`Wire`].

use companion_transport::UreqTransport;
use ots_client::{
    AuthStrategy, BasicAuth, Client, ConcealPayload, Error, HttpRequest, HttpResponse, NoAuth,
    Transport, TransportError, share_link,
};
use zeroize::Zeroizing;

/// Where a conceal goes. Non-secret; the token is loaded per call.
#[derive(Clone)]
pub(crate) struct Connection {
    pub server_url: String,
    /// Empty means the server's host.
    pub share_domain: String,
    /// The Basic-auth username. Empty means guest-only.
    pub extid: String,
}

impl Connection {
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

/// Options the confirmation step gathers.
pub(crate) struct ConcealOpts {
    pub ttl_secs: Option<u64>,
    pub passphrase: Option<Zeroizing<String>>,
    pub recipient: Option<String>,
}

impl ConcealOpts {
    /// `None` or `{}` is all defaults; malformed JSON is `None`.
    pub fn parse(json: Option<&str>) -> Option<Self> {
        let Some(json) = json else {
            return Some(Self {
                ttl_secs: None,
                passphrase: None,
                recipient: None,
            });
        };
        let mut value: serde_json::Value = serde_json::from_str(json).ok()?;
        if !value.is_object() {
            return None;
        }
        // Taken, not copied, so the only copy is the zeroizing one.
        // An unescaped passphrase also passed through serde_json's
        // scratch buffer, which we cannot wipe.
        let passphrase = match value.get_mut("passphrase").map(serde_json::Value::take) {
            Some(serde_json::Value::String(passphrase)) if !passphrase.is_empty() => {
                Some(Zeroizing::new(passphrase))
            }
            _ => None,
        };
        Some(Self {
            ttl_secs: value.get("ttl_secs").and_then(serde_json::Value::as_u64),
            passphrase,
            recipient: value
                .get("recipient")
                .and_then(serde_json::Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
        })
    }
}

/// Seven days, independent of the page (ADR-0011 §5, ADR-0026).
pub(crate) const LINK_DEFAULT_TTL_SECS: u64 = 7 * 24 * 60 * 60;

/// The link goes to the clipboard; only `receipt_id` is retained.
#[derive(Debug)]
pub(crate) struct Concealed {
    pub link: String,
    pub receipt_id: String,
}

/// Authenticated when both a token and an `extid` are present, guest
/// otherwise.
// By value so the payload and token are wiped when this returns.
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
        Err(Error::Transport(e)) => Err(format!("could not reach the server: {e}")),
        Err(Error::Api { status, message }) => {
            Err(format!("the server refused ({status}): {message}"))
        }
        Err(Error::Decode(e)) => Err(format!("unreadable server response: {e}")),
    }
}

/// The transport a handle sends on, built once per handle. `Stub`
/// exists only under `test-util` (ADR-0018).
#[derive(Clone)]
pub(crate) enum Wire {
    Real(UreqTransport),
    #[cfg(feature = "test-util")]
    Stub(std::sync::Arc<StubWire>),
}

impl Wire {
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

/// Answers every request with one canned response and keeps only a
/// redacted summary of each, with no payload or passphrase.
#[cfg(feature = "test-util")]
pub(crate) struct StubWire {
    /// `Err` is an outage: no status at all.
    answer: Result<(u16, Vec<u8>), String>,
    seen: std::sync::Mutex<Vec<WireRecord>>,
}

/// What [`StubWire`] keeps of one request.
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
    /// A `status` of zero makes every send an outage.
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

    /// Reads four non-secret conceal fields by name; nothing else.
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
    fn guest_route_when_a_token_has_no_extid() {
        let transport = MockTransport::returning(200, OK_BODY);
        let guest = Connection {
            extid: String::new(),
            ..conn()
        };
        conceal(
            &guest,
            Some(Zeroizing::new("tok".into())),
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
