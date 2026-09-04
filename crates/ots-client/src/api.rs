//! Request building and response interpretation — the sans-IO half —
//! plus [`Client`], which pairs it with a transport.

use zeroize::Zeroizing;

use crate::auth::AuthStrategy;
use crate::http::{HttpRequest, HttpResponse, Transport};
use crate::types::{ConcealData, ConcealPayload, Error, RecordEnvelope};

/// Builds v3 API requests and interprets responses. Does no networking:
/// pair with a [`Transport`] via [`Client`], or drive it by hand.
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

    /// The server this client talks to — the app's one outbound
    /// destination.
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

    /// Build `POST /api/v3/guest/secret/conceal` — concealing with zero
    /// configuration, where the server enables guest routes. Never
    /// carries credentials.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Decode`] if the payload fails to serialize.
    pub fn guest_conceal_request(&self, payload: &ConcealPayload) -> Result<HttpRequest, Error> {
        self.post_conceal("/api/v3/guest/secret/conceal", payload, false)
    }

    /// Build `GET /api/v3/status` — the connection test.
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
        // V2-inherited transport wrapper: params nest under "secret".
        let body = serde_json::to_vec(&serde_json::json!({ "secret": payload }))
            .map_err(|e| Error::Decode(e.to_string()))?;
        let mut req = HttpRequest::new("POST", format!("{}{path}", self.base_url));
        req.headers
            .push(("Content-Type".into(), "application/json".into()));
        req.headers
            .push(("Accept".into(), "application/json".into()));
        if authenticated {
            self.auth.apply(&mut req);
        }
        req.body = Some(Zeroizing::new(body));
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

/// A transport paired with the API surface: the whole conceal call in
/// one method.
pub struct Client<T: Transport> {
    api: Api,
    transport: T,
}

impl<T: Transport> Client<T> {
    /// A client for `base_url`, authenticating with `auth`, sending via
    /// `transport`.
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

    /// Conceal a secret: one `POST`, one one-time link.
    ///
    /// # Errors
    ///
    /// [`Error::Transport`] when the request never completed;
    /// [`Error::Api`]/[`Error::Decode`] per
    /// [`Api::parse_conceal_response`].
    pub fn conceal(&self, payload: &ConcealPayload) -> Result<ConcealData, Error> {
        let request = self.api.conceal_request(payload)?;
        let response = self.transport.send(request)?;
        self.api.parse_conceal_response(&response)
    }

    /// Conceal via the guest route (no credentials).
    ///
    /// # Errors
    ///
    /// Same as [`Client::conceal`].
    pub fn guest_conceal(&self, payload: &ConcealPayload) -> Result<ConcealData, Error> {
        let request = self.api.guest_conceal_request(payload)?;
        let response = self.transport.send(request)?;
        self.api.parse_conceal_response(&response)
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

/// Snap a requested TTL to a server-allowed value, **downward**. Falls
/// back to the smallest allowed value when the request is shorter than
/// all of them; `None` only when `allowed` is empty.
///
/// The request is the link's own: a page's remaining time is not an
/// input to a link's lifetime (ADR-0026), and the companion no longer
/// derives one from the other. This helper stays for the day the server
/// reports an allowed set per request (ADR-0026's second eject trigger).
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
        // 7h10m remaining → 1h, not 8h: never outlive intent.
        assert_eq!(snap_ttl(25_800, &allowed), Some(3600));
        assert_eq!(snap_ttl(28_800, &allowed), Some(28_800));
        assert_eq!(snap_ttl(1_000_000, &allowed), Some(604_800));
        // Shorter than every allowed value → the smallest allowed.
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
