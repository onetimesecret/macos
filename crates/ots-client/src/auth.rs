//! Authentication as a swappable strategy, so the HTTP-Basic-to-PASETO
//! migration is additive (docs/spec/05).

use zeroize::Zeroizing;

use crate::base64;
use crate::http::HttpRequest;

/// Applies credentials to an outgoing request.
pub trait AuthStrategy {
    /// Add whatever headers this strategy requires.
    fn apply(&self, request: &mut HttpRequest);
}

/// HTTP Basic: the v3 API's phase-1 scheme. Credentials are an API key
/// and secret pair, configured alongside the organization `extid`; the
/// caller keeps them in the macOS Keychain, never in config files.
pub struct BasicAuth {
    username: String,
    password: Zeroizing<String>,
}

impl BasicAuth {
    /// Basic credentials. `username` is the API key identifier;
    /// `password` is the API secret.
    #[must_use]
    pub fn new(username: impl Into<String>, password: impl Into<String>) -> Self {
        Self {
            username: username.into(),
            password: Zeroizing::new(password.into()),
        }
    }
}

impl AuthStrategy for BasicAuth {
    fn apply(&self, request: &mut HttpRequest) {
        let credentials = Zeroizing::new(format!("{}:{}", self.username, *self.password));
        let encoded = base64::encode(credentials.as_bytes());
        request
            .headers
            .push(("Authorization".into(), format!("Basic {encoded}")));
    }
}

/// Bearer tokens: the sync relay's scheme (docs/spec/feature/sync/
/// account-auth.md), and the shape phase-2 PASETO conceal auth will
/// reuse. The token is opaque here on purpose — the server owns its
/// encoding, this strategy only carries it.
pub struct BearerAuth {
    token: Zeroizing<String>,
}

impl BearerAuth {
    /// A bearer token as the server issued it, scheme not included.
    #[must_use]
    pub fn new(token: impl Into<String>) -> Self {
        Self {
            token: Zeroizing::new(token.into()),
        }
    }
}

impl AuthStrategy for BearerAuth {
    fn apply(&self, request: &mut HttpRequest) {
        request
            .headers
            .push(("Authorization".into(), format!("Bearer {}", *self.token)));
    }
}

/// No credentials — guest routes, where the server enables them.
pub struct NoAuth;

impl AuthStrategy for NoAuth {
    fn apply(&self, _request: &mut HttpRequest) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_auth_sets_rfc7617_header() {
        let mut req = HttpRequest::new("GET", "https://example.com".into());
        BasicAuth::new("Aladdin", "open sesame").apply(&mut req);
        assert_eq!(
            req.header("authorization"),
            Some("Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
        );
    }

    #[test]
    fn bearer_auth_sets_rfc6750_header() {
        let mut req = HttpRequest::new("GET", "https://example.com".into());
        BearerAuth::new("mF_9.B5f-4.1JqM").apply(&mut req);
        assert_eq!(req.header("authorization"), Some("Bearer mF_9.B5f-4.1JqM"));
    }

    #[test]
    fn no_auth_adds_nothing() {
        let mut req = HttpRequest::new("GET", "https://example.com".into());
        NoAuth.apply(&mut req);
        assert!(req.headers.is_empty());
    }
}
