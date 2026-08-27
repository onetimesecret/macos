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

use ots_client::{HttpRequest, HttpResponse, Transport, TransportError};
use ureq::Agent;

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
    /// A transport with ureq's default (rustls) TLS configuration.
    #[must_use]
    pub fn new() -> Self {
        let config = Agent::config_builder().http_status_as_error(false).build();
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
