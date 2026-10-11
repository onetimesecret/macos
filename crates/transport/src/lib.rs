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

use std::io::Read as _;
use std::time::Duration;

use ots_client::{HttpRequest, HttpResponse, Transport, TransportError};
use ureq::Agent;
use zeroize::Zeroizing;

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
/// direction. A deadline for the whole body, not an idle timer, so it
/// is also how long a socket that stops delivering mid-body stalls the
/// call. Sized for the bodies the protocol sends rather than the cap:
/// `relay-protocol.md` §8 pads every sealed blob to "256 bytes minimum,
/// 64 KiB maximum bucket", so an answer of many blobs moves in two
/// minutes at any usable rate, and the 10 MiB `BODY_LIMIT` is the case
/// that loses on a slow link.
const BODY_PATIENCE: Duration = Duration::from_secs(120);
/// The whole call, end to end. Past the sum of the phases above
/// (340 seconds), so a slow call that keeps moving inside every phase is
/// never cut by this one; it binds only on a call stalled somewhere the
/// phases do not see.
const CALL_PATIENCE: Duration = Duration::from_secs(360);

/// The most of a response body read: ureq's own `read_to_vec` default
/// (10 MiB), the cap every call had before it was read here by hand.
const BODY_LIMIT: u64 = 10 * 1024 * 1024;

/// The most a declared `Content-Length` reserves ahead of the read.
/// Token answers, the bodies the presize is for, are a few hundred
/// bytes; relay frames above this are sealed blobs and grow as read.
const PRESIZE_LIMIT: u64 = 64 * 1024;

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
        // Sized from `Content-Length` where the server sent one, so a
        // token answer lands in one allocation instead of leaving a
        // freed, unwiped partial copy behind at every growth; the
        // caller wipes the one buffer. The reservation stops at
        // `PRESIZE_LIMIT`, so a declared length is never an allocation
        // the server chooses; a larger body grows as it is read, up to
        // `BODY_LIMIT`, and a length the allocator cannot meet falls
        // back to growth rather than aborting.
        // Wiped on every way out, a read that fails partway included:
        // a token answer cut off halfway is still most of a token.
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
        // Moved out whole, and the empty vector left behind holds
        // nothing. The allocation goes to the caller: the sync driver's
        // token answers and `ots-client`'s conceal answers wipe it once
        // read; relay frames, sealed blobs, are not wiped.
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
        // The global is the outer bound, not a tighter one: a call
        // within every phase's budget finishes.
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
}
