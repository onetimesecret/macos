//! Request building and response interpretation, plus [`Client`].

use zeroize::{Zeroize as _, Zeroizing};

use crate::auth::AuthStrategy;
use crate::http::{HttpRequest, HttpResponse, Transport};
use crate::types::{ConcealData, ConcealPayload, Error, RecordEnvelope};

/// The v2-inherited wrapper: the payload nests under `secret`.
#[derive(serde::Serialize)]
struct ConcealEnvelope<'a> {
    secret: &'a ConcealPayload,
}

/// Counts bytes, to size a serialization before allocating its buffer.
/// Requires deterministic output: no unordered maps in `ConcealPayload`.
struct ByteCounter(usize);

impl std::io::Write for ByteCounter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0 += buf.len();
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Builds v3 API requests and interprets responses; does no networking.
pub struct Api {
    base_url: String,
    auth: Box<dyn AuthStrategy>,
}

impl Api {
    /// An API surface for the server at `base_url`
    /// (e.g. `https://eu.onetimesecret.com`), authenticating with `auth`.
    #[must_use]
    pub fn new(base_url: impl Into<String>, auth: Box<dyn AuthStrategy>) -> Self {
        let mut base_url = base_url.into();
        while base_url.ends_with('/') {
            base_url.pop();
        }
        Self { base_url, auth }
    }

    /// The server this client talks to.
    #[must_use]
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Build `POST /api/v3/secret/conceal` (authenticated).
    ///
    /// # Errors
    ///
    /// Returns [`Error::Decode`] if the payload fails to serialize
    /// (practically unreachable).
    pub fn conceal_request(&self, payload: &ConcealPayload) -> Result<HttpRequest, Error> {
        self.post_conceal("/api/v3/secret/conceal", payload, true)
    }

    /// Build `POST /api/v3/guest/secret/conceal`, without credentials.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Decode`] if the payload fails to serialize.
    pub fn guest_conceal_request(&self, payload: &ConcealPayload) -> Result<HttpRequest, Error> {
        self.post_conceal("/api/v3/guest/secret/conceal", payload, false)
    }

    /// Build `GET /api/v3/status`, the connection test.
    #[must_use]
    pub fn status_request(&self) -> HttpRequest {
        let mut req = HttpRequest::new("GET", format!("{}/api/v3/status", self.base_url));
        req.headers
            .push(("Accept".into(), "application/json".into()));
        req
    }

    fn post_conceal(
        &self,
        path: &str,
        payload: &ConcealPayload,
        authenticated: bool,
    ) -> Result<HttpRequest, Error> {
        // No intermediate `Value` (it would hold unwiped copies), and an
        // exact-size buffer so growth never strands a partial copy.
        let envelope = ConcealEnvelope { secret: payload };
        let mut counter = ByteCounter(0);
        serde_json::to_writer(&mut counter, &envelope).map_err(|e| Error::Decode(e.to_string()))?;
        let mut body = Zeroizing::new(Vec::with_capacity(counter.0));
        serde_json::to_writer(&mut *body, &envelope).map_err(|e| Error::Decode(e.to_string()))?;
        debug_assert_eq!(body.len(), counter.0, "sizing pass drifted from the write");
        let mut req = HttpRequest::new("POST", format!("{}{path}", self.base_url));
        req.headers
            .push(("Content-Type".into(), "application/json".into()));
        req.headers
            .push(("Accept".into(), "application/json".into()));
        if authenticated {
            self.auth.apply(&mut req);
        }
        req.body = Some(body);
        Ok(req)
    }

    /// Interpret a conceal response: 2xx parses into [`ConcealData`],
    /// anything else becomes [`Error::Api`] with the server's message.
    ///
    /// # Errors
    ///
    /// [`Error::Api`] on non-2xx status; [`Error::Decode`] when a 2xx
    /// body does not hold a conceal record.
    pub fn parse_conceal_response(&self, response: &HttpResponse) -> Result<ConcealData, Error> {
        if !(200..300).contains(&response.status) {
            return Err(Error::Api {
                status: response.status,
                message: extract_message(&response.body),
            });
        }
        let envelope: RecordEnvelope<ConcealData> =
            serde_json::from_slice(&response.body).map_err(|e| Error::Decode(e.to_string()))?;
        Ok(envelope.record)
    }
}

/// An [`Api`] paired with a [`Transport`].
pub struct Client<T: Transport> {
    api: Api,
    transport: T,
}

impl<T: Transport> Client<T> {
    /// A client for `base_url`, sending via `transport`.
    #[must_use]
    pub fn new(base_url: impl Into<String>, auth: Box<dyn AuthStrategy>, transport: T) -> Self {
        Self {
            api: Api::new(base_url, auth),
            transport,
        }
    }

    /// The sans-IO surface, for building requests without sending.
    #[must_use]
    pub fn api(&self) -> &Api {
        &self.api
    }

    /// Conceal a secret.
    ///
    /// # Errors
    ///
    /// [`Error::Transport`] when the request never completed;
    /// [`Error::Api`]/[`Error::Decode`] per
    /// [`Api::parse_conceal_response`].
    pub fn conceal(&self, payload: &ConcealPayload) -> Result<ConcealData, Error> {
        let request = self.api.conceal_request(payload)?;
        let mut response = self.transport.send(request)?;
        // The body carries the link key; the returned copy is not wiped.
        let parsed = self.api.parse_conceal_response(&response);
        response.body.zeroize();
        parsed
    }

    /// Conceal via the guest route (no credentials).
    ///
    /// # Errors
    ///
    /// Same as [`Client::conceal`].
    pub fn guest_conceal(&self, payload: &ConcealPayload) -> Result<ConcealData, Error> {
        let request = self.api.guest_conceal_request(payload)?;
        let mut response = self.transport.send(request)?;
        let parsed = self.api.parse_conceal_response(&response);
        response.body.zeroize();
        parsed
    }
}

/// The share link for a concealed secret: the response's `share_domain`
/// when present, otherwise the server the client is configured against.
#[must_use]
pub fn share_link(base_url: &str, data: &ConcealData) -> String {
    let base = base_url.trim_end_matches('/');
    match data.share_domain.as_deref() {
        Some(domain) if !domain.is_empty() => {
            format!("https://{domain}/secret/{}", data.secret.key)
        }
        _ => format!("{base}/secret/{}", data.secret.key),
    }
}

/// Snap a requested TTL down to a server-allowed value, else the smallest;
/// `None` when `allowed` is empty. Unused until the server reports a set
/// (ADR-0026).
#[must_use]
pub fn snap_ttl(remaining_secs: u64, allowed: &[u64]) -> Option<u64> {
    allowed
        .iter()
        .copied()
        .filter(|&a| a <= remaining_secs)
        .max()
        .or_else(|| allowed.iter().copied().min())
}

fn extract_message(body: &[u8]) -> String {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|v| {
            ["message", "error", "detail"]
                .iter()
                .find_map(|k| v.get(k).and_then(|m| m.as_str()).map(str::to_owned))
        })
        .unwrap_or_else(|| String::from_utf8_lossy(body).chars().take(200).collect())
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;
    use crate::auth::{BasicAuth, NoAuth};

    fn fixture_body() -> Vec<u8> {
        serde_json::json!({
            "record": {
                "receipt": { "identifier": "9f2abc", "shortid": "9f2", "secret_ttl": 7200 },
                "secret": { "identifier": "sec1", "key": "k3y", "shortid": "k3" },
                "share_domain": "secrets.example.com",
            },
            "details": {},
        })
        .to_string()
        .into_bytes()
    }

    #[test]
    fn conceal_request_hits_the_authenticated_route() {
        let api = Api::new(
            "https://eu.onetimesecret.com/",
            Box::new(BasicAuth::new("key", "secret")),
        );
        let payload = ConcealPayload::new("hunter2", "secrets.example.com").with_ttl(3600);
        let req = api.conceal_request(&payload).unwrap();
        assert_eq!(req.method, "POST");
        assert_eq!(
            req.url,
            "https://eu.onetimesecret.com/api/v3/secret/conceal"
        );
        assert!(req.header("authorization").unwrap().starts_with("Basic "));
        let body: serde_json::Value = serde_json::from_slice(req.body.as_ref().unwrap()).unwrap();
        assert_eq!(body["secret"]["kind"], "conceal");
        assert_eq!(body["secret"]["ttl"], 3600);
    }

    #[test]
    fn guest_request_is_unauthenticated_on_the_guest_route() {
        let api = Api::new("https://selfhosted.example", Box::new(NoAuth));
        let payload = ConcealPayload::new("s", "selfhosted.example");
        let req = api.guest_conceal_request(&payload).unwrap();
        assert_eq!(
            req.url,
            "https://selfhosted.example/api/v3/guest/secret/conceal"
        );
        assert_eq!(req.header("authorization"), None);
    }

    #[test]
    fn the_conceal_body_is_written_at_its_exact_size() {
        let api = Api::new("https://x.example", Box::new(NoAuth));
        let secret = "line \"one\"\n\u{1F511} ".repeat(500);
        let payload = ConcealPayload::new(secret, "x.example")
            .with_ttl(3600)
            .with_passphrase("pass\\word");
        for req in [
            api.conceal_request(&payload).unwrap(),
            api.guest_conceal_request(&payload).unwrap(),
        ] {
            let body = req.body.as_ref().unwrap();
            assert_eq!(body.capacity(), body.len());
        }
    }

    #[test]
    fn success_response_parses_into_conceal_data() {
        let api = Api::new("https://x.example", Box::new(NoAuth));
        let response = HttpResponse {
            status: 201,
            body: fixture_body(),
        };
        let data = api.parse_conceal_response(&response).unwrap();
        assert_eq!(data.receipt.identifier, "9f2abc");
        assert_eq!(
            share_link("https://x.example", &data),
            "https://secrets.example.com/secret/k3y"
        );
    }

    #[test]
    fn share_link_falls_back_to_base_url() {
        let data = ConcealData {
            receipt: serde_json::from_str(r#"{"identifier":"r"}"#).unwrap(),
            secret: serde_json::from_str(r#"{"identifier":"s","key":"k3y"}"#).unwrap(),
            share_domain: None,
        };
        assert_eq!(
            share_link("https://eu.onetimesecret.com/", &data),
            "https://eu.onetimesecret.com/secret/k3y"
        );
    }

    #[test]
    fn error_response_surfaces_server_message() {
        let api = Api::new("https://x.example", Box::new(NoAuth));
        let response = HttpResponse {
            status: 422,
            body: br#"{"message":"TTL exceeds plan entitlement"}"#.to_vec(),
        };
        match api.parse_conceal_response(&response).unwrap_err() {
            Error::Api { status, message } => {
                assert_eq!(status, 422);
                assert_eq!(message, "TTL exceeds plan entitlement");
            }
            other => panic!("expected Api error, got {other:?}"),
        }
    }

    #[test]
    fn snap_ttl_snaps_down_never_up() {
        let allowed = [3600, 28_800, 86_400, 604_800];
        assert_eq!(snap_ttl(25_800, &allowed), Some(3600));
        assert_eq!(snap_ttl(28_800, &allowed), Some(28_800));
        assert_eq!(snap_ttl(1_000_000, &allowed), Some(604_800));
        assert_eq!(snap_ttl(120, &allowed), Some(3600));
        assert_eq!(snap_ttl(120, &[]), None);
    }

    struct MockTransport {
        seen: RefCell<Vec<String>>,
        respond: HttpResponse,
    }

    impl Transport for MockTransport {
        fn send(&self, request: HttpRequest) -> Result<HttpResponse, crate::TransportError> {
            self.seen.borrow_mut().push(request.url.clone());
            Ok(HttpResponse {
                status: self.respond.status,
                body: self.respond.body.clone(),
            })
        }
    }

    #[test]
    fn client_round_trips_through_a_transport() {
        let transport = MockTransport {
            seen: RefCell::new(Vec::new()),
            respond: HttpResponse {
                status: 201,
                body: fixture_body(),
            },
        };
        let client = Client::new(
            "https://eu.onetimesecret.com",
            Box::new(BasicAuth::new("key", "secret")),
            transport,
        );
        let data = client
            .conceal(&ConcealPayload::new("hunter2", "secrets.example.com"))
            .unwrap();
        assert_eq!(data.secret.key, "k3y");
    }
}
