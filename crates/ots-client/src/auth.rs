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
    fn no_auth_adds_nothing() {
        let mut req = HttpRequest::new("GET", "https://example.com".into());
        NoAuth.apply(&mut req);
        assert!(req.headers.is_empty());
    }
}
