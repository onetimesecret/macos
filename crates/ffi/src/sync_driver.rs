//! The driver behind the `companion_sync_*` routes: what the sign-in
//! ceremony and (with issue #102's wiring) the sync engine need from
//! the process — configuration, the loopback listener's lifetime, and
//! where the refresh token rests — kept out of `lib.rs` so the extern
//! fns there stay the thin wrappers every other family is.
//!
//! Sign-in is account-auth.md §1 executed: the shell opens the system
//! browser on the authorize URL this module minted, the one-shot
//! loopback listener waits out the consent screen, and the code
//! redeems for a grant over the caller's transport. Every failure in
//! §5's table comes back as a stable machine token, never a sentence:
//! the engine hands up states, and issue #102's surface owns the
//! words.

use std::time::Duration;

use companion_credentials::CredentialStore;
use companion_sync::TokenKeeper;
use companion_sync::loopback::OneShotListener;
use companion_sync::oauth::{AuthCeremony, SyncAuthError, TokenGrant, parse_token_response};
use ots_client::Transport;
use zeroize::Zeroizing;

/// Where the sync refresh token rests: its own account in the
/// key-material store (account-auth.md §3, ADR-0021 §3), beside — and
/// never inside — the rotating content-key derivation. The
/// key-material tier rather than the handed store, because refresh is
/// a background act and the login keychain's ACL prompt belongs to
/// deliberate ones (ADR-0004; `api-token` keeps that path). Deleting
/// this account disables sync and only sync; `rotate_key_halves` and
/// `clear_pairing` never touch it, and clearing it touches nothing of
/// theirs.
pub(crate) const SYNC_REFRESH_ACCOUNT: &str = "sync-oauth-refresh";

/// Sync's endpoints and client identity, handed by the shell at launch
/// like the conceal connection — never persisted core-side, and never
/// secret. The authorize and token endpoints live on the account
/// server (OAuth is onetimesecret's capability, issue #98); the relay
/// is the allowlist's second and last entry.
pub(crate) struct SyncConfig {
    /// The relay's base URL, `https://` only.
    pub relay_url: String,
    /// The authorization endpoint the browser opens.
    pub authorize_url: String,
    /// The token endpoint codes and refresh tokens redeem against.
    pub token_url: String,
    /// The public client id (PKCE public client: no secret exists).
    pub client_id: String,
}

impl SyncConfig {
    /// Parse the configure JSON: all four fields required, the three
    /// URLs refused unless `https://` — the network boundary answered
    /// before a socket could open, as `companion_connection_configure`
    /// answers it for the conceal server.
    pub(crate) fn parse(json: &str) -> Option<Self> {
        let value: serde_json::Value = serde_json::from_str(json).ok()?;
        let field = |name: &str| Some(value.get(name)?.as_str()?.to_owned());
        let url = |name: &str| field(name).filter(|url| url.starts_with("https://"));
        let config = Self {
            relay_url: url("relay_url")?,
            authorize_url: url("authorize_url")?,
            token_url: url("token_url")?,
            client_id: field("client_id")?,
        };
        (!config.client_id.is_empty()).then_some(config)
    }

    /// The transport for every request this driver sends: bounded to
    /// the account server (the token endpoint's host) and the relay —
    /// doc 05's two destinations, structural rather than assumed.
    pub(crate) fn transport(&self) -> companion_transport::UreqTransport {
        companion_transport::UreqTransport::bounded(
            host_of(&self.token_url),
            host_of(&self.relay_url),
        )
    }
}

/// The `host[:port]` of an `https://` URL, for the transport's
/// allowlist. Parse failures yield an empty host, which matches
/// nothing: fail closed.
fn host_of(url: &str) -> &str {
    let rest = url.strip_prefix("https://").unwrap_or("");
    &rest[..rest.find(['/', '?', '#']).unwrap_or(rest.len())]
}

/// Everything sync holds behind the handle. Default is all-off: a
/// handle that never configures sync is bit-for-bit today's app
/// (issue #102's first criterion).
#[derive(Default)]
pub(crate) struct SyncState {
    /// Endpoints and client id; `None` until the shell configures.
    pub config: Option<SyncConfig>,
    /// The token keeper, built at configure from the persisted refresh
    /// token — a relaunch resumes signed in without a browser.
    pub keeper: Option<TokenKeeper>,
    /// A sign-in ceremony begun and not yet finished: the PKCE state
    /// and the bound listener, waiting for the finish call to take
    /// them off-lock and block on the redirect.
    pub pending_signin: Option<PendingSignin>,
}

/// A begun sign-in ceremony: consumed whole by the finish, dropped
/// whole by a cancel — either way at most one redeem can ever happen.
pub(crate) struct PendingSignin {
    pub ceremony: AuthCeremony,
    pub listener: OneShotListener,
}

/// Begin the sign-in ceremony: bind the loopback listener, mint the
/// PKCE material, and hand back the authorize URL for the shell to
/// open in the system browser. The pending ceremony parks in `state`
/// until the finish or a cancel.
pub(crate) fn signin_begin(state: &mut SyncState) -> Result<String, &'static str> {
    let Some(config) = &state.config else {
        return Err("not_configured");
    };
    if state.pending_signin.is_some() {
        return Err("busy");
    }
    let Some(listener) = OneShotListener::bind() else {
        return Err("port");
    };
    let (ceremony, authorize_url) = AuthCeremony::begin(
        &config.authorize_url,
        &config.token_url,
        &config.client_id,
        listener.port(),
    )
    .map_err(|_| "no_entropy")?;
    state.pending_signin = Some(PendingSignin { ceremony, listener });
    Ok(authorize_url)
}

/// Finish the ceremony: block on the one redirect (minutes of
/// patience — the user is reading a consent screen), redeem the code,
/// and exchange it for the grant. Runs with no lock held; the caller
/// took `pending` out first. Every failure is a §5 row as a machine
/// token: `abandoned` (the browser never returned), `state_mismatch`,
/// `no_code`, `unreachable`, `refused` — and all of them leave nothing
/// stored, with retry being a fresh begin.
pub(crate) fn signin_finish<T: Transport>(
    pending: PendingSignin,
    patience: Duration,
    transport: &T,
) -> Result<TokenGrant, &'static str> {
    let Some(query) = pending.listener.accept_redirect(patience) else {
        return Err("abandoned");
    };
    let request = pending
        .ceremony
        .redeem(&query)
        .map_err(|error| match error {
            SyncAuthError::StateMismatch => "state_mismatch",
            SyncAuthError::NoCode => "no_code",
            _ => "refused",
        })?;
    let response = transport.send(request).map_err(|_| "unreachable")?;
    parse_token_response(&response).map_err(|_| "refused")
}

/// The keeper for a configuration, resuming from the persisted
/// refresh token: `Some` inside means a relaunch signed in without a
/// browser, `None` means first-run signed-out until the ceremony
/// grants.
pub(crate) fn keeper_for(config: &SyncConfig, credentials: &dyn CredentialStore) -> TokenKeeper {
    TokenKeeper::new(
        &config.token_url,
        &config.client_id,
        load_refresh(credentials),
    )
}

/// Persist a rotated refresh token — called on every rotation, since
/// the server invalidates the predecessor on use.
pub(crate) fn store_refresh(
    credentials: &dyn CredentialStore,
    refresh: &Zeroizing<String>,
) -> bool {
    credentials
        .key_material_store()
        .store(SYNC_REFRESH_ACCOUNT, refresh.as_bytes())
        .is_ok()
}

/// The persisted refresh token, if any. Never mints; a missing or
/// unreadable account is simply signed-out.
pub(crate) fn load_refresh(credentials: &dyn CredentialStore) -> Option<Zeroizing<String>> {
    let bytes = credentials
        .key_material_store()
        .load(SYNC_REFRESH_ACCOUNT)
        .ok()?;
    String::from_utf8(bytes.to_vec()).ok().map(Zeroizing::new)
}

/// Delete the persisted refresh token: sign-out's durable half, and
/// exactly one account — conceal credentials, content and ledger keys,
/// and the pairing accounts all stand.
pub(crate) fn clear_refresh(credentials: &dyn CredentialStore) -> bool {
    credentials
        .key_material_store()
        .delete(SYNC_REFRESH_ACCOUNT)
        .is_ok()
}

/// Whether a refresh token rests on this device — existence only,
/// never a decrypting read, so rendering Settings cannot wedge on the
/// credential store (the `companion_connection_json` rule).
pub(crate) fn signed_in(credentials: &dyn CredentialStore) -> bool {
    credentials
        .key_material_store()
        .exists(SYNC_REFRESH_ACCOUNT)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::io::{Read as _, Write as _};
    use std::net::TcpStream;

    use companion_credentials::InMemoryCredentialStore;
    use ots_client::{HttpRequest, HttpResponse, TransportError};

    use super::*;

    /// A token endpoint in a box: hands back the canned response and
    /// keeps the request for assertions.
    struct MockTransport {
        seen: RefCell<Option<HttpRequest>>,
        response: HttpResponse,
    }

    impl MockTransport {
        fn granting() -> Self {
            Self {
                seen: RefCell::new(None),
                response: HttpResponse {
                    status: 200,
                    body: br#"{"access_token":"at-1","refresh_token":"rt-1"}"#.to_vec(),
                },
            }
        }
    }

    impl Transport for MockTransport {
        fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
            *self.seen.borrow_mut() = Some(request);
            Ok(HttpResponse {
                status: self.response.status,
                body: self.response.body.clone(),
            })
        }
    }

    fn configured() -> SyncState {
        SyncState {
            config: SyncConfig::parse(
                r#"{"relay_url":"https://relay.example",
                    "authorize_url":"https://eu.example/oauth/authorize",
                    "token_url":"https://eu.example/oauth/token",
                    "client_id":"companion"}"#,
            ),
            keeper: None,
            pending_signin: None,
        }
    }

    /// Play the browser: hit the pending ceremony's listener with the
    /// redirect, carrying the `state` the authorize URL asked for.
    fn browser_returns(authorize_url: &str, port: u16, state_value: Option<&str>) {
        let state_param = authorize_url
            .split('&')
            .find_map(|pair| pair.strip_prefix("state="))
            .unwrap()
            .to_owned();
        let state_value = state_value.map_or(state_param, str::to_owned);
        std::thread::spawn(move || {
            let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
            write!(
                stream,
                "GET /callback?code=abc&state={state_value} HTTP/1.1\r\n\r\n"
            )
            .unwrap();
            let mut answer = String::new();
            let _ = stream.read_to_string(&mut answer);
        });
    }

    #[test]
    fn the_ceremony_lands_the_rotated_refresh_token_in_its_own_account() {
        let credentials = InMemoryCredentialStore::default();
        let mut state = configured();
        let authorize_url = signin_begin(&mut state).unwrap();
        assert!(authorize_url.contains("code_challenge_method=S256"));
        let pending = state.pending_signin.take().unwrap();
        browser_returns(&authorize_url, pending.listener.port(), None);

        let transport = MockTransport::granting();
        let grant = signin_finish(pending, Duration::from_secs(5), &transport).unwrap();
        assert!(store_refresh(&credentials, &grant.refresh));
        assert_eq!(
            load_refresh(&credentials).unwrap().as_str(),
            "rt-1",
            "the grant's refresh token is the one that rests"
        );
        // The exchange went to the configured token endpoint with the
        // PKCE verifier, never the challenge.
        let request = transport.seen.borrow_mut().take().unwrap();
        assert_eq!(request.url, "https://eu.example/oauth/token");
        let body = String::from_utf8(request.body.unwrap().to_vec()).unwrap();
        assert!(body.contains("code_verifier="));
    }

    #[test]
    fn a_wrong_state_aborts_with_nothing_redeemed() {
        let mut state = configured();
        let authorize_url = signin_begin(&mut state).unwrap();
        let pending = state.pending_signin.take().unwrap();
        browser_returns(&authorize_url, pending.listener.port(), Some("forged"));
        let transport = MockTransport::granting();
        let refused = signin_finish(pending, Duration::from_secs(5), &transport);
        assert_eq!(refused.err(), Some("state_mismatch"));
        assert!(
            transport.seen.borrow().is_none(),
            "no token request may follow a forged state"
        );
    }

    #[test]
    fn an_abandoned_browser_times_out_with_nothing_stored() {
        let mut state = configured();
        let _ = signin_begin(&mut state).unwrap();
        let pending = state.pending_signin.take().unwrap();
        let transport = MockTransport::granting();
        let refused = signin_finish(pending, Duration::ZERO, &transport);
        assert_eq!(refused.err(), Some("abandoned"));
    }

    #[test]
    fn one_ceremony_at_a_time_and_a_cancel_clears_the_way() {
        let mut state = configured();
        let _ = signin_begin(&mut state).unwrap();
        assert_eq!(signin_begin(&mut state).unwrap_err(), "busy");
        state.pending_signin = None;
        assert!(signin_begin(&mut state).is_ok());
    }

    #[test]
    fn the_config_refuses_plaintext_urls_and_missing_fields() {
        assert!(
            SyncConfig::parse(
                r#"{"relay_url":"http://relay.example",
                    "authorize_url":"https://a.example",
                    "token_url":"https://t.example",
                    "client_id":"c"}"#,
            )
            .is_none(),
            "a plaintext relay must be refused before a socket exists"
        );
        assert!(SyncConfig::parse(r#"{"relay_url":"https://relay.example"}"#).is_none());
        assert!(SyncConfig::parse("not json").is_none());
    }

    #[test]
    fn signing_out_deletes_exactly_the_sync_refresh_account() {
        let credentials = InMemoryCredentialStore::default();
        // The neighbours: conceal token on the handed store, ledger key
        // and pairing accounts in the key-material store.
        credentials.store("api-token", b"conceal-token").unwrap();
        let ledger = crate::persist::ensure_ledger_key(&credentials).unwrap();
        let _ = crate::pairing::ensure_device_identity(&credentials).unwrap();
        let _ = crate::pairing::ensure_channel_secret(&credentials, true).unwrap();
        assert!(store_refresh(
            &credentials,
            &Zeroizing::new("rt-1".to_owned())
        ));
        assert!(signed_in(&credentials));

        assert!(clear_refresh(&credentials));
        assert!(!signed_in(&credentials));
        assert_eq!(*credentials.load("api-token").unwrap(), b"conceal-token");
        assert_eq!(
            *crate::persist::load_ledger_key(&credentials).unwrap(),
            *ledger,
            "sign-out must not touch the ledger key"
        );
        assert!(crate::pairing::ensure_device_identity(&credentials).is_some());

        // And the other direction: revoking the conceal token or the
        // pairing leaves sync signed in.
        store_refresh(&credentials, &Zeroizing::new("rt-2".to_owned()));
        credentials.delete("api-token").unwrap();
        assert!(crate::pairing::clear_pairing(&credentials));
        assert!(signed_in(&credentials));
    }

    #[test]
    fn the_transport_is_bounded_to_the_two_destinations() {
        let state = configured();
        let transport = state.config.as_ref().unwrap().transport();
        let elsewhere =
            ots_client::Api::new("https://elsewhere.example", Box::new(ots_client::NoAuth))
                .status_request();
        assert!(transport.send(elsewhere).is_err());
    }
}
