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
        }
    }
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
}
