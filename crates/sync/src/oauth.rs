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

/// The one scope the sync client asks for, and the only scope the
/// relay's client application is registered with server side
/// (ADR-0027 §3). The registration is the ceiling: a consent screen
/// offers the application's registered scopes rather than the
/// requested ones, so an application holding nothing but this is what
/// keeps a leaked sync token from concealing, reading account data, or
/// acting as the account anywhere else. It is sent explicitly on the
/// authorization request and never on a refresh: narrowing on refresh
/// is silently ignored and the refresh answer carries no scope back,
/// so the scope is fixed at authorization and asking again would be
/// theatre.
pub const SYNC_SCOPE: &str = "sync";

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
    /// so the redirect URI matches exactly (RFC 8252 §7.3). The URL
    /// names [`SYNC_SCOPE`] explicitly: a client that omits scope is
    /// offered the application's whole registered set, which is a
    /// width the client should not accept by silence even where the
    /// registration is narrow.
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
            "{authorize_endpoint}?response_type=code&client_id={}&redirect_uri={}&code_challenge={challenge}&code_challenge_method=S256&state={state}&scope={}",
            form_encode(client_id),
            form_encode(&redirect_uri),
            form_encode(SYNC_SCOPE),
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
/// that sleeps for days, so it is refused rather than half-kept. An
/// empty string is a missing token, the same reading
/// [`parse_refresh_response`] takes: an empty refresh token written to
/// the keychain would answer "signed in" forever while every refresh
/// failed.
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
            .filter(|token| !token.is_empty())
            .map(|token| Zeroizing::new(token.to_owned()))
    };
    match (token("access_token"), token("refresh_token")) {
        (Some(access), Some(refresh)) => Ok(TokenGrant { access, refresh }),
        _ => Err(SyncAuthError::Refused(response.status)),
    }
}

/// Parse a *refresh* answer, where the rotated token is optional.
///
/// RFC 6749 §6 makes the new refresh token optional in a refresh
/// response, and a server configured without rotation simply omits it.
/// A client that insisted on one would refuse every grant such a
/// server issues, and would refuse them behind a `2xx` it could not
/// even explain, so sync would be permanently unable to wake up
/// against a perfectly conformant server (ADR-0027 §2: rotation is
/// requested, never required). The access token is still mandatory:
/// a refresh answer without one has told us nothing we can attach
/// with.
///
/// # Errors
///
/// [`SyncAuthError::Refused`] with the status on a non-2xx answer, a
/// body that is not JSON, or a body with no access token.
fn parse_refresh_response(
    response: &HttpResponse,
) -> Result<(Zeroizing<String>, Option<Zeroizing<String>>), SyncAuthError> {
    if !(200..300).contains(&response.status) {
        return Err(SyncAuthError::Refused(response.status));
    }
    let value: serde_json::Value = serde_json::from_slice(&response.body)
        .map_err(|_| SyncAuthError::Refused(response.status))?;
    let token = |key: &str| {
        value
            .get(key)
            .and_then(serde_json::Value::as_str)
            .filter(|token| !token.is_empty())
            .map(|token| Zeroizing::new(token.to_owned()))
    };
    let access = token("access_token").ok_or(SyncAuthError::Refused(response.status))?;
    Ok((access, token("refresh_token")))
}

/// Whether the token endpoint said *this grant is dead* rather than
/// *not now*, or *you asked wrongly*. The status alone cannot say it:
/// RFC 6749 §5.2 answers `invalid_request`, `invalid_client`,
/// `unauthorized_client`, `unsupported_grant_type`, `invalid_scope`
/// and `invalid_grant` all with the same `400`, and only the last is
/// about the grant. The others are about the request or the
/// registration, and deleting a perfectly good refresh token would
/// not fix any of them. A `408` or a `429` is 4xx and unambiguously
/// transient, and a `403` from a captive portal or a WAF challenge is
/// not the authorization server speaking at all: neither carries an
/// `error` field, and an HTML body carries nothing this can read. So
/// the verdict is taken from the body, never off the status, and the
/// default is to keep the credential (ADR-0027 §2: a server that said
/// slow down is not a server that said no).
fn grant_is_dead(response: &HttpResponse) -> bool {
    if !(400..500).contains(&response.status) {
        return false;
    }
    serde_json::from_slice::<serde_json::Value>(&response.body)
        .ok()
        .as_ref()
        .and_then(|value| value.get("error"))
        .and_then(serde_json::Value::as_str)
        == Some("invalid_grant")
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

    /// The relay refused the held access token mid-session: drop it,
    /// whatever a local clock thinks — the `401` is the only expiry
    /// authority (§2). Dropping it is what makes the next
    /// [`TokenKeeper::refresh_request`] actually run; a kept stale
    /// token would answer "signed in" while every request loops on
    /// the same dead bearer.
    pub fn clear_access(&mut self) {
        self.access = None;
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

    /// Absorb the refresh answer. `Ok(Some(token))` is a rotated
    /// refresh token for the caller to persist; `Ok(None)` is a server
    /// that declined to rotate, whose grant stands unchanged and whose
    /// stored token is still the right one, so there is nothing to
    /// write (ADR-0027 §2). Only the token endpoint naming
    /// `invalid_grant` signs the keeper out with both tokens dropped,
    /// for the caller to surface issue #102's sentence: "Sync is
    /// signed out; the pad is unaffected." Anything else (a `5xx`, a
    /// rate limit, a gateway mangling the body, a `400` about the
    /// request rather than the grant) is the endpoint being unwell or
    /// misasked, not the grant being revoked: the refresh token is
    /// kept and the next pump retries.
    ///
    /// # Errors
    ///
    /// [`SyncAuthError::SignedOut`] on the endpoint's refusal (no
    /// tokens held afterwards); [`SyncAuthError::Refused`] with the
    /// status on a transient failure (the refresh token still held).
    pub fn absorb_refresh(
        &mut self,
        response: &HttpResponse,
    ) -> Result<Option<Zeroizing<String>>, SyncAuthError> {
        match parse_refresh_response(response) {
            Ok((access, rotated)) => {
                self.access = Some(access);
                if let Some(rotated) = rotated {
                    self.refresh = Some(rotated.clone());
                    return Ok(Some(rotated));
                }
                Ok(None)
            }
            Err(_) if grant_is_dead(response) => {
                self.access = None;
                self.refresh = None;
                Err(SyncAuthError::SignedOut)
            }
            Err(_) => Err(SyncAuthError::Refused(response.status)),
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
    fn the_authorize_url_asks_for_exactly_the_sync_scope() {
        let (_, url) = ceremony();
        assert!(url.contains("&scope=sync"), "{url}");
        assert_eq!(
            url.matches("scope=").count(),
            1,
            "code_challenge_method is not a scope and neither is anything else"
        );
    }

    #[test]
    fn no_scope_is_asked_for_or_expected_on_a_refresh() {
        let mut keeper = TokenKeeper::new(
            "https://eu.onetimesecret.com/auth/token",
            "companion-macos",
            Some(Zeroizing::new("rt-0".into())),
        );
        let request = keeper.refresh_request().unwrap();
        let body = String::from_utf8(request.body.unwrap().to_vec()).unwrap();
        assert!(
            !body.contains("scope"),
            "narrowing on refresh is ignored server side; the scope is fixed at authorization"
        );
        // And the answer carrying none back is an ordinary grant.
        let unscoped = HttpResponse {
            status: 200,
            body: br#"{"access_token":"at-1","refresh_token":"rt-1"}"#.to_vec(),
        };
        assert!(keeper.absorb_refresh(&unscoped).is_ok());
        assert_eq!(keeper.access(), Some("at-1"));
    }

    #[test]
    fn a_grant_that_names_no_scope_is_still_a_grant() {
        let response = HttpResponse {
            status: 200,
            body: br#"{"access_token":"at-1","refresh_token":"rt-1","token_type":"bearer"}"#
                .to_vec(),
        };
        assert!(
            parse_token_response(&response).is_ok(),
            "the server may omit scope from the token response, and does"
        );
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
        let rotated = keeper.absorb_refresh(&grant_response()).unwrap().unwrap();
        assert_eq!(&*rotated, "rt-1");
        assert_eq!(keeper.access(), Some("at-1"));
        // The next refresh uses the rotated token, not the original.
        let request = keeper.refresh_request().unwrap();
        let body = String::from_utf8(request.body.unwrap().to_vec()).unwrap();
        assert!(body.contains("refresh_token=rt-1"));
    }

    #[test]
    fn a_server_that_declines_to_rotate_keeps_the_grant_alive() {
        let mut keeper = TokenKeeper::new(
            "https://eu.onetimesecret.com/auth/token",
            "companion-macos",
            Some(Zeroizing::new("rt-0".into())),
        );
        let _ = keeper.refresh_request().unwrap();
        // RFC 6749 §6: the new refresh token is optional, and a server
        // configured without rotation omits it.
        let unrotated = HttpResponse {
            status: 200,
            body: br#"{"access_token":"at-9","expires_in":3600}"#.to_vec(),
        };
        assert_eq!(
            keeper.absorb_refresh(&unrotated).unwrap(),
            None,
            "nothing rotated, so there is nothing for the caller to persist"
        );
        assert_eq!(keeper.access(), Some("at-9"), "the grant did land");
        assert!(keeper.signed_in());
        // And the held token is still the one that refreshes, so the
        // next wake from sleep works rather than signing sync out.
        let request = keeper.refresh_request().unwrap();
        let body = String::from_utf8(request.body.unwrap().to_vec()).unwrap();
        assert!(body.contains("refresh_token=rt-0"));
    }

    #[test]
    fn a_refresh_answer_without_an_access_token_is_not_a_grant() {
        let mut keeper = TokenKeeper::new(
            "https://eu.onetimesecret.com/auth/token",
            "companion-macos",
            Some(Zeroizing::new("rt-0".into())),
        );
        let _ = keeper.refresh_request().unwrap();
        let empty = HttpResponse {
            status: 200,
            body: br#"{"refresh_token":"rt-1"}"#.to_vec(),
        };
        assert_eq!(
            keeper.absorb_refresh(&empty).unwrap_err(),
            SyncAuthError::Refused(200),
            "a 2xx with nothing to attach with is the endpoint being unwell"
        );
        // Unwell is not revoked: the grant stands and the next pump
        // retries with it.
        assert!(keeper.signed_in());
        assert!(keeper.access().is_none());
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
    fn an_empty_token_is_not_a_token_in_either_parser() {
        // An empty refresh token written to the keychain would answer
        // "signed in" forever while every refresh failed.
        let grant = HttpResponse {
            status: 200,
            body: br#"{"access_token":"","refresh_token":""}"#.to_vec(),
        };
        assert_eq!(
            parse_token_response(&grant).err(),
            Some(SyncAuthError::Refused(200))
        );
    }

    #[test]
    fn a_throttled_token_endpoint_is_not_a_dead_grant() {
        let mut keeper = TokenKeeper::new(
            "https://eu.onetimesecret.com/auth/token",
            "companion-macos",
            Some(Zeroizing::new("rt-0".into())),
        );
        let _ = keeper.refresh_request().unwrap();
        // A server that said slow down is not a server that said no.
        let throttled = HttpResponse {
            status: 429,
            body: br#"{"error":"slow_down"}"#.to_vec(),
        };
        assert_eq!(
            keeper.absorb_refresh(&throttled).unwrap_err(),
            SyncAuthError::Refused(429)
        );
        assert!(keeper.signed_in(), "a rate limit deletes nothing");
    }

    #[test]
    fn only_invalid_grant_pronounces_the_grant_dead() {
        // RFC 6749 §5.2 answers all of these with the same `400`, and
        // only the last of them is about the grant.
        for code in [
            "invalid_request",
            "invalid_client",
            "unauthorized_client",
            "unsupported_grant_type",
            "invalid_scope",
        ] {
            let mut keeper = TokenKeeper::new(
                "https://eu.onetimesecret.com/auth/token",
                "companion-macos",
                Some(Zeroizing::new("rt-0".into())),
            );
            let _ = keeper.refresh_request().unwrap();
            let refusal = HttpResponse {
                status: 400,
                body: format!(r#"{{"error":"{code}"}}"#).into_bytes(),
            };
            assert_eq!(
                keeper.absorb_refresh(&refusal).unwrap_err(),
                SyncAuthError::Refused(400),
                "{code} is a fault in the request or the registration, not a dead grant"
            );
            assert!(keeper.signed_in(), "{code} may not delete a good token");
        }
    }

    #[test]
    fn a_4xx_that_named_no_error_keeps_the_grant() {
        let mut keeper = TokenKeeper::new(
            "https://eu.onetimesecret.com/auth/token",
            "companion-macos",
            Some(Zeroizing::new("rt-0".into())),
        );
        let _ = keeper.refresh_request().unwrap();
        // A captive portal or a WAF challenge: 4xx, and not the
        // authorization server speaking at all.
        let challenge = HttpResponse {
            status: 403,
            body: b"<html><body>are you a robot</body></html>".to_vec(),
        };
        assert_eq!(
            keeper.absorb_refresh(&challenge).unwrap_err(),
            SyncAuthError::Refused(403)
        );
        assert!(keeper.signed_in());
    }

    #[test]
    fn an_unwell_token_endpoint_does_not_sign_the_keeper_out() {
        let mut keeper = TokenKeeper::new(
            "https://eu.onetimesecret.com/auth/token",
            "companion-macos",
            Some(Zeroizing::new("rt-0".into())),
        );
        let _ = keeper.refresh_request().unwrap();
        let outage = HttpResponse {
            status: 503,
            body: b"upstream unavailable".to_vec(),
        };
        assert_eq!(
            keeper.absorb_refresh(&outage).unwrap_err(),
            SyncAuthError::Refused(503)
        );
        // The grant was never pronounced dead: the refresh token
        // stands, and the next pump retries with it.
        assert!(keeper.signed_in());
        let request = keeper.refresh_request().unwrap();
        let body = String::from_utf8(request.body.unwrap().to_vec()).unwrap();
        assert!(body.contains("refresh_token=rt-0"));
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
