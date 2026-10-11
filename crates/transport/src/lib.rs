//! The one concrete HTTP transport this workspace ships for
//! `ots-client`. `ots-client` is sans-IO by design; the TLS stack and
//! HTTP client are the integrator's choice, made once, here
//! (docs/spec/05).
//!
//! `ots-client::Api` interprets HTTP status itself
//! (`parse_conceal_response` reads 4xx/5xx bodies for the server's
//! error message), so [`UreqTransport`] disables ureq's default
//! "status code is an error" behaviour and hands every response back as
//! `Ok`, whatever its status.

use std::time::Duration;

use ots_client::{HttpRequest, HttpResponse, Transport, TransportError};
use ureq::Agent;

/// How long a DNS lookup may take.
const RESOLVE_PATIENCE: Duration = Duration::from_secs(10);
/// How long opening the socket and the TLS handshake may take, and
/// how long sending the request line and headers may.
const CONNECT_PATIENCE: Duration = Duration::from_secs(15);
/// How long the server may take to start answering. The sync relay's
/// long-poll holds a request open for 25 seconds by design
/// (docs/spec/feature/sync/relay-protocol.md, `wait=25`), so this sits
/// well past it: a bound the long-poll could not fit inside would
/// turn every quiet channel into a timeout.
const RESPONSE_PATIENCE: Duration = Duration::from_secs(60);
/// How long a request or response body may take to move, in either
/// direction. A relay frame is at most a few megabytes.
const BODY_PATIENCE: Duration = Duration::from_secs(60);
/// The whole call, end to end, whatever the phases above add up to.
const CALL_PATIENCE: Duration = Duration::from_secs(180);

/// A [`Transport`] backed by a pooled `ureq::Agent` (rustls). Cheap to
/// clone (internally `Arc`-shared); construct one per process and reuse
/// it rather than building a fresh agent per call.
#[derive(Debug, Clone)]
pub struct UreqTransport {
    agent: Agent,
    /// The outbound allowlist (doc 05): when set, requests to any
    /// other host are refused before a socket opens. At most two
    /// entries — the configured OTS server and the sync relay — and
    /// the cap is structural: [`UreqTransport::bounded`] is the only
    /// way to set it.
    allowed_hosts: Option<[String; 2]>,
}

impl Default for UreqTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl UreqTransport {
    /// A transport with ureq's default (rustls) TLS configuration,
    /// which follows no redirect, speaks only TLS, and bounds every
    /// phase of a call.
    ///
    /// The boundary check in [`Transport::send`] looks at the URL a
    /// caller hands in. Left to its defaults, ureq would then follow
    /// up to ten redirects on its own, to any host and over plain
    /// `http://`, and hand back whatever a third host answered as if
    /// the relay had said it. No redirect is followed: a `3xx` comes
    /// back as the response it is, for the API layer to refuse by
    /// status like any other non-`2xx`.
    ///
    /// The timeouts are what keep a dead connection from becoming a
    /// dead feature. ureq's defaults bound nothing, and the shell
    /// marks a sync pump or a conceal as in flight until the call
    /// returns: a laptop that slept mid-long-poll, or a NAT that
    /// dropped the path without a reset, would otherwise park that
    /// thread for the life of the process and nothing would ever
    /// schedule the next one.
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

    /// A transport bounded to exactly the network boundary of doc 05:
    /// the configured OTS server and the sync relay, and no third
    /// destination — the allowlist widened from one entry to two
    /// rather than removed (ADR-0021). Hosts are compared exactly
    /// (case-insensitive), port included when the URL carries one.
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
        // The network boundary (doc 05): exactly one outbound
        // destination, TLS-only. Refuse before any socket opens.
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
        let body = response
            .body_mut()
            .read_to_vec()
            .map_err(|e| TransportError(e.to_string()))?;
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
        // The boundary is checked on the URL handed in; a redirect
        // would be a second URL nobody checked.
        let config = UreqTransport::new().agent.config().clone();
        assert!(config.https_only());
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
}
