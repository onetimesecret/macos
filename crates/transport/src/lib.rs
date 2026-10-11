//! The HTTP transport for `ots-client`, which is sans-IO (docs/spec/05).
//! Every response comes back as `Ok` whatever its status; `ots-client`
//! interprets status itself.

use std::io::Read as _;
use std::time::Duration;

use ots_client::{HttpRequest, HttpResponse, Transport, TransportError};
use ureq::Agent;
use zeroize::Zeroizing;

const RESOLVE_PATIENCE: Duration = Duration::from_secs(10);
/// Socket, TLS handshake, and the request line and headers.
const CONNECT_PATIENCE: Duration = Duration::from_secs(15);
/// Time to first byte. Must exceed the relay's 25-second long-poll
/// (relay-protocol.md, `wait=25`).
const RESPONSE_PATIENCE: Duration = Duration::from_secs(60);
/// A deadline for a whole body, either direction; sized for relay blobs
/// (relay-protocol.md §8), not for `BODY_LIMIT`.
const BODY_PATIENCE: Duration = Duration::from_secs(120);
/// At least the sum of the phases, so it only cuts a call stalled where
/// no phase timer sees it.
const CALL_PATIENCE: Duration = Duration::from_secs(360);

/// ureq's own `read_to_vec` default.
const BODY_LIMIT: u64 = 10 * 1024 * 1024;

/// Cap on what a declared `Content-Length` may reserve up front.
const PRESIZE_LIMIT: u64 = 64 * 1024;

/// A [`Transport`] over a pooled `ureq::Agent` (rustls). Cheap to clone;
/// build one per process.
#[derive(Debug, Clone)]
pub struct UreqTransport {
    agent: Agent,
    /// The doc 05 allowlist: the OTS server and the sync relay (ADR-0021).
    allowed_hosts: Option<[String; 2]>,
}

impl Default for UreqTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl UreqTransport {
    /// TLS only, no redirects (the boundary check sees only the first
    /// URL), and every phase bounded so a dead socket cannot park a sync
    /// pump or a conceal forever.
    #[must_use]
    pub fn new() -> Self {
        let config = Agent::config_builder()
            .http_status_as_error(false)
            .https_only(true)
            .max_redirects(0)
            .timeout_resolve(Some(RESOLVE_PATIENCE))
            .timeout_connect(Some(CONNECT_PATIENCE))
            .timeout_send_request(Some(CONNECT_PATIENCE))
            .timeout_send_body(Some(BODY_PATIENCE))
            .timeout_recv_response(Some(RESPONSE_PATIENCE))
            .timeout_recv_body(Some(BODY_PATIENCE))
            .timeout_global(Some(CALL_PATIENCE))
            .build();
        Self {
            agent: config.into(),
            allowed_hosts: None,
        }
    }

    /// Refuses every host but these two. Comparison is exact,
    /// case-insensitive, port included.
    #[must_use]
    pub fn bounded(server_host: &str, relay_host: &str) -> Self {
        let mut transport = Self::new();
        transport.allowed_hosts = Some([
            server_host.to_ascii_lowercase(),
            relay_host.to_ascii_lowercase(),
        ]);
        transport
    }
}

/// The `host[:port]` part of an `https://` URL, lowercased; `None` for
/// anything unparseable, which the caller refuses.
fn host_of(url: &str) -> Option<String> {
    let rest = url.strip_prefix("https://")?;
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let host = &rest[..end];
    (!host.is_empty()).then(|| host.to_ascii_lowercase())
}

impl Transport for UreqTransport {
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
        if !request.url.starts_with("https://") {
            return Err(TransportError(format!(
                "refusing a non-TLS request to {} (network boundary, docs/spec/05)",
                request.url
            )));
        }
        if let Some(allowed) = &self.allowed_hosts {
            let host = host_of(&request.url).ok_or_else(|| {
                TransportError(format!("unparseable request URL {}", request.url))
            })?;
            if !allowed.contains(&host) {
                return Err(TransportError(format!(
                    "refusing a request to {host}: not in the two-destination allowlist (network boundary, docs/spec/05)"
                )));
            }
        }

        let mut builder = ureq::http::Request::builder()
            .method(request.method)
            .uri(request.url.as_str());
        for (name, value) in &request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        let body: &[u8] = request.body.as_deref().map_or(&[] as &[u8], Vec::as_slice);
        let http_request = builder
            .body(body)
            .map_err(|e| TransportError(e.to_string()))?;

        let mut response = self
            .agent
            .run(http_request)
            .map_err(|e| TransportError(e.to_string()))?;
        let status = response.status().as_u16();
        // Presized to avoid leaving unwiped partial copies on growth;
        // capped so the server cannot choose the allocation.
        let mut body = Zeroizing::new(Vec::new());
        let expected = response.body().content_length().unwrap_or(0);
        let _ = body.try_reserve_exact(usize::try_from(expected.min(PRESIZE_LIMIT)).unwrap_or(0));
        response
            .body_mut()
            .with_config()
            .limit(BODY_LIMIT)
            .reader()
            .read_to_end(&mut body)
            .map_err(|e| TransportError(e.to_string()))?;
        // Callers that hold secrets in the body wipe it (ots-client,
        // the sync driver's token answers).
        let body = std::mem::take(&mut *body);
        Ok(HttpResponse { status, body })
    }
}

#[cfg(test)]
mod tests {
    use ots_client::{Api, NoAuth};

    use super::*;

    #[test]
    fn refuses_a_plaintext_url_before_any_socket_opens() {
        let transport = UreqTransport::new();
        let request = Api::new("http://insecure.example", Box::new(NoAuth)).status_request();
        let err = transport.send(request).unwrap_err();
        assert!(err.0.contains("non-TLS"));
    }

    #[test]
    fn bounded_refuses_a_third_destination_before_any_socket_opens() {
        let transport = UreqTransport::bounded("eu.onetimesecret.com", "relay.onetimesecret.com");
        let request = Api::new("https://elsewhere.example", Box::new(NoAuth)).status_request();
        let err = transport.send(request).unwrap_err();
        assert!(err.0.contains("allowlist"), "{}", err.0);
    }

    #[test]
    fn the_agent_follows_no_redirect_and_speaks_only_tls() {
        let config = UreqTransport::new().agent.config().clone();
        assert!(config.https_only());
        assert!(!config.http_status_as_error());
        assert_eq!(config.max_redirects(), 0);
        let bounded = UreqTransport::bounded("a.example", "b.example");
        assert!(bounded.agent.config().https_only());
        assert_eq!(bounded.agent.config().max_redirects(), 0);
    }

    #[test]
    fn every_phase_of_a_call_is_bounded_and_the_long_poll_fits() {
        let timeouts = UreqTransport::new().agent.config().timeouts();
        assert!(timeouts.resolve.is_some());
        assert!(timeouts.connect.is_some());
        assert!(timeouts.send_request.is_some());
        assert!(timeouts.send_body.is_some());
        assert!(timeouts.recv_body.is_some());
        assert!(timeouts.global.is_some());
        // The relay holds a long-poll open for 25 seconds by design.
        let first_byte = timeouts
            .recv_response
            .expect("the response wait is bounded");
        assert!(
            first_byte > Duration::from_secs(25),
            "a quiet long-poll must be able to finish"
        );
        assert!(timeouts.global.unwrap() > first_byte);
        let phases = [
            timeouts.resolve,
            timeouts.connect,
            timeouts.send_request,
            timeouts.send_body,
            timeouts.recv_response,
            timeouts.recv_body,
        ]
        .into_iter()
        .map(Option::unwrap)
        .sum::<Duration>();
        assert!(timeouts.global.unwrap() >= phases);
    }

    #[test]
    fn bounded_compares_hosts_not_prefixes() {
        let transport = UreqTransport::bounded("eu.onetimesecret.com", "relay.onetimesecret.com");
        let request = Api::new(
            "https://eu.onetimesecret.com.evil.example",
            Box::new(NoAuth),
        )
        .status_request();
        assert!(transport.send(request).is_err());
    }

    #[test]
    fn bounded_compares_hosts_case_insensitively_with_the_port() {
        let transport = UreqTransport::bounded("EU.onetimesecret.com", "relay.example:8443");
        assert_eq!(
            transport.allowed_hosts.as_ref().unwrap(),
            &[
                "eu.onetimesecret.com".to_owned(),
                "relay.example:8443".to_owned()
            ]
        );
        assert_eq!(
            host_of("https://Relay.Example:8443/v1?x").as_deref(),
            Some("relay.example:8443")
        );
        let request = Api::new("https://relay.example", Box::new(NoAuth)).status_request();
        assert!(transport.send(request).unwrap_err().0.contains("allowlist"));
    }
}
