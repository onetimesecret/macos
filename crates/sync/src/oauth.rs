//! Account auth for the relay channel: OAuth 2.0 authorization code +
//! PKCE, the native-app BCP (RFC 8252) followed as written
//! (`docs/spec/feature/sync/account-auth.md`). Public client, no
//! secret, `S256` challenge, exact-match loopback redirect, `state`
//! checked on return.
//!
//! Sans-IO: [`AuthCeremony`] mints the material and builds the token
//! request; the browser open and the loopback accept happen elsewhere
//! ([`crate::loopback`]). [`TokenKeeper`] then owns the lifetimes the
//! spec chose for an app that sleeps for days — access token in memory
//! only, refresh token rotated on every use, and **the server's `401`
//! as the only expiry authority**: nothing here pre-judges expiry by
//! its own clock, so skew cannot invent an outage.

use ots_client::{HttpRequest, HttpResponse};
use ring::digest::{SHA256, digest};
use ring::rand::{SecureRandom as _, SystemRandom};
use zeroize::Zeroizing;

use crate::b64;

/// A refusal from the auth ceremony or the token machinery. Everything
/// here is user-visible state, never a panic: auth failing leaves the
/// pad untouched (the spec's degraded-state rule).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncAuthError {
    /// The redirect's `state` did not match the ceremony's — a stray
    /// or forged callback, dropped without redeeming anything.
    StateMismatch,
    /// The redirect carried no authorization code (the user denied, or
    /// the server answered with an error).
    NoCode,
    /// The token endpoint answered with something other than a grant.
    /// Carries the HTTP status; the body is not echoed (it can carry
    /// account identifiers).
    Refused(u16),
    /// The refresh was refused: revoked account-side, rotation reuse
    /// tripped, or the 90-day idle window ran out. Sync is signed out;
    /// the pad is unaffected. Re-enabling sync is the browser ceremony
    /// again.
    SignedOut,
    /// The system RNG declined; the ceremony was not started.
    NoEntropy,
}

impl std::fmt::Display for SyncAuthError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StateMismatch => write!(f, "auth callback state mismatch"),
            Self::NoCode => write!(f, "auth callback carried no code"),
            Self::Refused(status) => write!(f, "token endpoint refused ({status})"),
            Self::SignedOut => write!(f, "sync is signed out; the pad is unaffected"),
            Self::NoEntropy => write!(f, "system RNG unavailable"),
        }
    }
}

impl std::error::Error for SyncAuthError {}

/// One browser round of the §1 ceremony: verifier, challenge, `state`,
/// and the exact redirect URI, held together so the redeem step can
/// check what the begin step promised.
pub struct AuthCeremony {
    verifier: Zeroizing<String>,
    state: String,
    redirect_uri: String,
    client_id: String,
    token_endpoint: String,
}

impl AuthCeremony {
    /// Mint the ceremony material and the authorization URL to open in
    /// the system browser. `port` is the ephemeral loopback port the
    /// listener actually bound ([`crate::loopback::OneShotListener`]),
    /// so the redirect URI matches exactly (RFC 8252 §7.3).
    ///
    /// # Errors
    ///
    /// [`SyncAuthError::NoEntropy`] when the system RNG declines;
    /// nothing has been started.
    pub fn begin(
        authorize_endpoint: &str,
        token_endpoint: &str,
        client_id: &str,
        port: u16,
    ) -> Result<(Self, String), SyncAuthError> {
        let rng = SystemRandom::new();
        // 32 random octets → 43 base64url chars: RFC 7636 §4.1's
        // recommended construction, at its minimum allowed length.
        let mut seed = Zeroizing::new([0u8; 32]);
        rng.fill(seed.as_mut())
            .map_err(|_| SyncAuthError::NoEntropy)?;
        let verifier = Zeroizing::new(b64::encode_url_nopad(seed.as_ref()));
        let mut state_bytes = [0u8; 16];
        rng.fill(&mut state_bytes)
            .map_err(|_| SyncAuthError::NoEntropy)?;
        let state = b64::encode_url_nopad(&state_bytes);
        let challenge = b64::encode_url_nopad(digest(&SHA256, verifier.as_bytes()).as_ref());
        let redirect_uri = format!("http://127.0.0.1:{port}/callback");
        let url = format!(
            "{authorize_endpoint}?response_type=code&client_id={}&redirect_uri={}&code_challenge={challenge}&code_challenge_method=S256&state={state}",
            form_encode(client_id),
            form_encode(&redirect_uri),
        );
        Ok((
            Self {
                verifier,
                state,
                redirect_uri,
                client_id: client_id.into(),
                token_endpoint: token_endpoint.into(),
            },
            url,
        ))
    }

    /// The exact redirect URI the ceremony registered, for the
    /// loopback listener to compare paths against.
    #[must_use]
    pub fn redirect_uri(&self) -> &str {
        &self.redirect_uri
    }

    /// Check the callback query against the ceremony and build the
    /// token request. Consumes the ceremony: one redirect, redeemed at
    /// most once.
    ///
    /// # Errors
    ///
    /// [`SyncAuthError::StateMismatch`] on a `state` that is absent or
    /// not this ceremony's; [`SyncAuthError::NoCode`] when no code came
    /// back.
    pub fn redeem(self, callback_query: &str) -> Result<HttpRequest, SyncAuthError> {
        let state = query_value(callback_query, "state").ok_or(SyncAuthError::StateMismatch)?;
        if state != self.state {
            return Err(SyncAuthError::StateMismatch);
        }
        let code = query_value(callback_query, "code").ok_or(SyncAuthError::NoCode)?;
        let body = format!(
            "grant_type=authorization_code&code={}&redirect_uri={}&client_id={}&code_verifier={}",
            form_encode(&code),
            form_encode(&self.redirect_uri),
            form_encode(&self.client_id),
            form_encode(&self.verifier),
        );
        Ok(token_request(&self.token_endpoint, body))
    }
}

/// A grant as the token endpoint issued it.
pub struct TokenGrant {
    /// Short-lived access token; held in memory, never persisted.
    pub access: Zeroizing<String>,
    /// Rotating refresh token; the caller persists it in the Keychain.
    pub refresh: Zeroizing<String>,
}

/// Parse a token endpoint response into a grant.
///
/// # Errors
///
/// [`SyncAuthError::Refused`] on any non-2xx status or a body missing
/// either token — a grant without a refresh token cannot serve an app
/// that sleeps for days, so it is refused rather than half-kept.
pub fn parse_token_response(response: &HttpResponse) -> Result<TokenGrant, SyncAuthError> {
    if !(200..300).contains(&response.status) {
        return Err(SyncAuthError::Refused(response.status));
    }
    let value: serde_json::Value = serde_json::from_slice(&response.body)
        .map_err(|_| SyncAuthError::Refused(response.status))?;
    let token = |key: &str| {
        value
            .get(key)
            .and_then(serde_json::Value::as_str)
            .map(|s| Zeroizing::new(s.to_owned()))
    };
    match (token("access_token"), token("refresh_token")) {
        (Some(access), Some(refresh)) => Ok(TokenGrant { access, refresh }),
        _ => Err(SyncAuthError::Refused(response.status)),
    }
}

/// The token lifetimes of §2, as a machine: access token in memory,
/// refresh token rotated on every use, and the `401` from the relay —
/// never a local clock — deciding when to refresh.
pub struct TokenKeeper {
    token_endpoint: String,
    client_id: String,
    access: Option<Zeroizing<String>>,
    refresh: Option<Zeroizing<String>>,
}

impl TokenKeeper {
    /// A keeper resuming from the persisted refresh token (`None` on
    /// first run: sync starts signed out until the ceremony runs).
    #[must_use]
    pub fn new(token_endpoint: &str, client_id: &str, refresh: Option<Zeroizing<String>>) -> Self {
        Self {
            token_endpoint: token_endpoint.into(),
            client_id: client_id.into(),
            access: None,
            refresh,
        }
    }

    /// Absorb a fresh grant (ceremony completion or refresh success).
    /// Returns the rotated refresh token for the caller to persist —
    /// the keeper never touches storage itself.
    pub fn absorb(&mut self, grant: TokenGrant) -> Zeroizing<String> {
        self.access = Some(grant.access);
        self.refresh = Some(grant.refresh.clone());
        grant.refresh
    }

    /// The access token to attach with, or `None` when a refresh (or
    /// the full ceremony) has to run first. Waking from days of sleep
    /// lands here with no access token, which is the intended path,
    /// not an error path.
    #[must_use]
    pub fn access(&self) -> Option<&str> {
        self.access.as_deref().map(String::as_str)
    }

    /// The relay answered `401`: drop the access token and build the
    /// one refresh request. `Err(SignedOut)` when no refresh token is
    /// held — sync stops and says so, the pad keeps working.
    ///
    /// # Errors
    ///
    /// [`SyncAuthError::SignedOut`] when there is nothing to refresh
    /// with.
    pub fn refresh_request(&mut self) -> Result<HttpRequest, SyncAuthError> {
        self.access = None;
        let refresh = self.refresh.as_ref().ok_or(SyncAuthError::SignedOut)?;
        let body = format!(
            "grant_type=refresh_token&refresh_token={}&client_id={}",
            form_encode(refresh),
            form_encode(&self.client_id),
        );
        Ok(token_request(&self.token_endpoint, body))
    }

    /// Absorb the refresh answer. On success the rotated refresh token
    /// is returned for persisting; on refusal the keeper signs out —
    /// both tokens dropped — and the caller surfaces issue #102's
    /// sentence: "Sync is signed out; the pad is unaffected."
    ///
    /// # Errors
    ///
    /// [`SyncAuthError::SignedOut`] on any refusal; the keeper holds no
    /// tokens afterwards.
    pub fn absorb_refresh(
        &mut self,
        response: &HttpResponse,
    ) -> Result<Zeroizing<String>, SyncAuthError> {
        match parse_token_response(response) {
            Ok(grant) => Ok(self.absorb(grant)),
            Err(_) => {
                self.access = None;
                self.refresh = None;
                Err(SyncAuthError::SignedOut)
            }
        }
    }

    /// Whether the keeper holds any credential at all. `false` is the
    /// signed-out state.
    #[must_use]
    pub fn signed_in(&self) -> bool {
        self.access.is_some() || self.refresh.is_some()
    }
}

fn token_request(endpoint: &str, body: String) -> HttpRequest {
    HttpRequest {
        method: "POST",
        url: endpoint.into(),
        headers: vec![(
            "Content-Type".into(),
            "application/x-www-form-urlencoded".into(),
        )],
        body: Some(Zeroizing::new(body.into_bytes())),
    }
}

/// Percent-encode for query/form components: unreserved characters
/// (RFC 3986 §2.3) pass, everything else is `%XX`.
fn form_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// The value for `key` in a query string, percent-decoded. `None` on
/// absence or malformed percent escapes.
fn query_value(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (k, v) = pair.split_once('=')?;
        (k == key).then(|| percent_decode(v))?
    })
}

fn percent_decode(input: &str) -> Option<String> {
    let mut out = Vec::with_capacity(input.len());
    let mut bytes = input.bytes();
    while let Some(byte) = bytes.next() {
        match byte {
            b'%' => {
                let hex = [bytes.next()?, bytes.next()?];
                let hex = std::str::from_utf8(&hex).ok()?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
            }
            b'+' => out.push(b' '),
            _ => out.push(byte),
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ceremony() -> (AuthCeremony, String) {
        AuthCeremony::begin(
            "https://eu.onetimesecret.com/auth/authorize",
            "https://eu.onetimesecret.com/auth/token",
            "companion-macos",
            49152,
        )
        .unwrap()
    }

    #[test]
    fn authorize_url_carries_s256_and_exact_loopback_redirect() {
        let (ceremony, url) = ceremony();
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("response_type=code"));
        assert!(url.contains(&form_encode("http://127.0.0.1:49152/callback")));
        assert_eq!(ceremony.redirect_uri(), "http://127.0.0.1:49152/callback");
        // The challenge is derived, never the verifier itself.
        assert!(!url.contains("code_verifier"));
    }

    #[test]
    fn redeem_refuses_a_wrong_or_missing_state() {
        let (forged, _) = ceremony();
        let err = forged.redeem("code=abc&state=forged").unwrap_err();
        assert_eq!(err, SyncAuthError::StateMismatch);
        let (stateless, _) = ceremony();
        assert_eq!(
            stateless.redeem("code=abc").unwrap_err(),
            SyncAuthError::StateMismatch
        );
    }

    #[test]
    fn redeem_builds_the_pkce_token_request() {
        let (ceremony, url) = ceremony();
        let state = url.split("state=").nth(1).unwrap().to_owned();
        let request = ceremony.redeem(&format!("code=abc&state={state}")).unwrap();
        assert_eq!(request.method, "POST");
        let body = String::from_utf8(request.body.unwrap().to_vec()).unwrap();
        assert!(body.contains("grant_type=authorization_code"));
        assert!(body.contains("code=abc"));
        assert!(body.contains("code_verifier="));
    }

    fn grant_response() -> HttpResponse {
        HttpResponse {
            status: 200,
            body: br#"{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600}"#.to_vec(),
        }
    }

    #[test]
    fn keeper_rotates_the_refresh_token_on_every_use() {
        let mut keeper = TokenKeeper::new(
            "https://eu.onetimesecret.com/auth/token",
            "companion-macos",
            Some(Zeroizing::new("rt-0".into())),
        );
        assert!(keeper.access().is_none());
        let request = keeper.refresh_request().unwrap();
        let body = String::from_utf8(request.body.unwrap().to_vec()).unwrap();
        assert!(body.contains("refresh_token=rt-0"));
        let rotated = keeper.absorb_refresh(&grant_response()).unwrap();
        assert_eq!(&*rotated, "rt-1");
        assert_eq!(keeper.access(), Some("at-1"));
        // The next refresh uses the rotated token, not the original.
        let request = keeper.refresh_request().unwrap();
        let body = String::from_utf8(request.body.unwrap().to_vec()).unwrap();
        assert!(body.contains("refresh_token=rt-1"));
    }

    #[test]
    fn refresh_refused_signs_out_and_keeps_nothing() {
        let mut keeper = TokenKeeper::new(
            "https://eu.onetimesecret.com/auth/token",
            "companion-macos",
            Some(Zeroizing::new("rt-0".into())),
        );
        let _ = keeper.refresh_request().unwrap();
        let refusal = HttpResponse {
            status: 400,
            body: br#"{"error":"invalid_grant"}"#.to_vec(),
        };
        assert_eq!(
            keeper.absorb_refresh(&refusal).unwrap_err(),
            SyncAuthError::SignedOut
        );
        assert!(!keeper.signed_in());
        assert_eq!(
            keeper.refresh_request().unwrap_err(),
            SyncAuthError::SignedOut
        );
    }

    #[test]
    fn first_run_is_signed_out_until_the_ceremony_grants() {
        let mut keeper = TokenKeeper::new("https://example.com/token", "companion-macos", None);
        assert!(!keeper.signed_in());
        let rotated = keeper.absorb(parse_token_response(&grant_response()).unwrap());
        assert_eq!(&*rotated, "rt-1");
        assert!(keeper.signed_in());
    }
}
