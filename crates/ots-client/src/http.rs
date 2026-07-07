//! Transport-agnostic HTTP types. The crate builds requests and parses
//! responses; something else moves the bytes.

use zeroize::Zeroizing;

/// An HTTP request, ready for any transport. The body is zeroizing —
/// for conceal calls it holds the secret plaintext.
#[derive(Debug)]
pub struct HttpRequest {
    /// HTTP method (`GET`, `POST`).
    pub method: &'static str,
    /// Absolute URL.
    pub url: String,
    /// Header name/value pairs, `Authorization` included when the auth
    /// strategy adds one.
    pub headers: Vec<(String, String)>,
    /// Request body; zeroized on drop.
    pub body: Option<Zeroizing<Vec<u8>>>,
}

impl HttpRequest {
    pub(crate) fn new(method: &'static str, url: String) -> Self {
        Self {
            method,
            url,
            headers: Vec::new(),
            body: None,
        }
    }

    /// Value of the first header matching `name` (case-insensitive).
    #[must_use]
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

/// A raw HTTP response for the API layer to interpret.
#[derive(Debug)]
pub struct HttpResponse {
    /// HTTP status code.
    pub status: u16,
    /// Response body bytes.
    pub body: Vec<u8>,
}

/// Anything that can carry an [`HttpRequest`] to a server. Implementations
/// must enforce TLS — the companion's network boundary is one outbound
/// destination, TLS-only (docs/spec/05).
pub trait Transport {
    /// Send the request and return the raw response.
    ///
    /// # Errors
    ///
    /// Returns [`TransportError`] when the request could not be
    /// delivered (DNS, connect, TLS, timeout).
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError>;
}

/// A delivery failure, before any HTTP status exists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportError(pub String);

impl std::fmt::Display for TransportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "transport: {}", self.0)
    }
}

impl std::error::Error for TransportError {}
