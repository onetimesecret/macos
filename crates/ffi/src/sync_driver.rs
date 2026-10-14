//! The driver behind the `companion_sync_*` routes: configuration, the
//! sign-in ceremony (account-auth.md §1), the engine and pairing, kept
//! out of `lib.rs` so its extern fns stay thin. Failures are machine
//! tokens; the engine is client protocol §2 to §9.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use companion_core::{HoldRegister, ItemId, SheetId};
use companion_credentials::CredentialStore;
use companion_sync::TokenKeeper;
use companion_sync::loopback::OneShotListener;
use companion_sync::oauth::{AuthCeremony, SyncAuthError, TokenGrant, parse_token_response};
use companion_sync::relay::RelayRefusal;
use ots_client::{HttpResponse, Transport};
use ring::signature::Ed25519KeyPair;
use zeroize::Zeroize as _;
use zeroize::Zeroizing;

use crate::diagnostics::diag_fault;
use crate::gop::GopKeyChain;
use crate::pairing::{self, MailboxMessage};
use crate::sync_gate::{GateFault, GateInputs, SyncGate, gate};
use crate::sync_session::{KeyPackage, KeyPackageKeeper, SyncEvent, SyncSession, sheet_of};
use crate::{Companion, CompanionHandle};

/// Where the sync refresh token rests: its own key-material account,
/// beside and never inside the rotating content-key derivation
/// (account-auth.md §3, ADR-0027).
pub(crate) const SYNC_REFRESH_ACCOUNT: &str = "sync-oauth-refresh";

/// Sync's endpoints and client identity, handed by the shell at launch;
/// never persisted core-side and never secret.
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
    /// URLs refused unless `https://`.
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

    /// The transport for every request this driver sends, bounded to
    /// the token endpoint's host and the relay (doc 05).
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

/// Everything sync holds behind the handle; the default is all-off, so
/// an unconfigured handle is the app without sync.
pub(crate) struct SyncState {
    /// Endpoints and client id; `None` until the shell configures.
    pub config: Option<SyncConfig>,
    /// The token keeper, built at configure from the persisted refresh
    /// token; it moves into the session at attach and back at detach.
    pub keeper: Option<TokenKeeper>,
    /// A sign-in ceremony begun and waiting for its finish.
    pub pending_signin: Option<PendingSignin>,
    /// The abandon flag of the ceremony a finish is holding off-lock on
    /// the browser: the gate reads `signing_in` while it stands, and a
    /// cancel or sign-out ends the trip through it.
    pub awaiting_redirect: Option<Arc<AtomicBool>>,
    /// The attached engine: session, chain, and key packages. `None`
    /// while sync is off or detached.
    pub engine: Option<EngineState>,
    /// The enrolled pages and their cursors (client protocol §2).
    pub enrolled: BTreeMap<ItemId, PageTracking>,
    /// A pairing ceremony in flight over the relay mailbox.
    pub pairing: Option<PairingState>,
    /// What the last use of the account credential met (ADR-0027 §5);
    /// in memory, cleared by any round trip that succeeds.
    pub fault: Option<GateFault>,
    /// Each page's export cursor when the in-flight batch was sealed:
    /// what its acceptance acknowledges (client protocol §4.4).
    pub staged_batch: Option<StagedBatch>,
    /// Whether an attach is in flight; attaches are single-flight
    /// (client protocol §3, §5.5).
    pub attaching: bool,
    /// Where the engine's relative clock starts: monotonic, so the
    /// publish and ballot windows cannot jump with the wall clock.
    origin: Instant,
}

impl Default for SyncState {
    fn default() -> Self {
        Self {
            config: None,
            keeper: None,
            pending_signin: None,
            awaiting_redirect: None,
            engine: None,
            enrolled: BTreeMap::new(),
            pairing: None,
            fault: None,
            staged_batch: None,
            attaching: false,
            origin: Instant::now(),
        }
    }
}

impl SyncState {
    /// Milliseconds on the engine's own monotonic clock.
    pub(crate) fn now_ms(&self) -> u64 {
        u64::try_from(self.origin.elapsed().as_millis()).unwrap_or(u64::MAX)
    }
}

/// The attached engine: what exists between an attach and a detach.
pub(crate) struct EngineState {
    pub session: SyncSession,
    pub chain: GopKeyChain,
    pub packages: KeyPackageKeeper,
    /// A fresh package minted for a re-attach and not yet accepted; it
    /// replaces `packages` only when the relay takes it (client
    /// protocol §5.2).
    pub pending_packages: Option<KeyPackageKeeper>,
    /// A committed ceremony's frame the relay has not yet accepted:
    /// kept until a 2xx or 409, so a dropped round retries.
    pub unpublished_frame: Option<Vec<u8>>,
}

/// Per enrolled page: the delta cursor and what was last published for
/// it, so the sweep queues changes and only changes.
pub(crate) struct PageTracking {
    /// The frontier the last export left; the pristine cursor at
    /// enrolment, so the first publish carries the whole page.
    pub frontier: Vec<u8>,
    /// The frontier the relay has acknowledged carrying: what a
    /// dissolving engine rewinds to, since the export cursor moves when
    /// ops are queued (client protocol §2; ADR-0027).
    pub acked: Vec<u8>,
    /// The deadline the last published expiry policy named.
    pub deadline_wall_ms: Option<u64>,
    /// The hold register as last published.
    pub hold: Option<HoldRegister>,
    /// Whether this device already queued the page's terminal marker.
    pub terminal_sent: bool,
}

impl PageTracking {
    fn at_enrolment() -> Self {
        let pristine =
            companion_core::SheetStore::<companion_core::SystemClock>::pristine_document_version();
        Self {
            frontier: pristine.clone(),
            acked: pristine,
            deadline_wall_ms: None,
            hold: None,
            terminal_sent: false,
        }
    }
}

/// A publish batch in flight and the cursors it carries, one per page
/// enrolled when it was sealed.
pub(crate) struct StagedBatch {
    /// [`SyncSession::in_flight_batch`], so a resend keeps this record.
    pub id: u64,
    pub cursors: BTreeMap<ItemId, Vec<u8>>,
}

/// A begun sign-in ceremony: consumed whole by the finish, dropped
/// whole by a cancel — either way at most one redeem can ever happen.
pub(crate) struct PendingSignin {
    pub ceremony: AuthCeremony,
    pub listener: OneShotListener,
    /// Raised by a cancel or sign-out; this ceremony's own, so it never
    /// ends a later trip.
    pub abandoned: Arc<AtomicBool>,
}

/// Begin the sign-in ceremony: bind the loopback listener, mint the
/// PKCE material, and return the authorize URL for the system browser.
pub(crate) fn signin_begin(state: &mut SyncState) -> Result<String, &'static str> {
    let Some(config) = &state.config else {
        return Err("not_configured");
    };
    // One ceremony at a time, a finish out on the browser included;
    // the way out is a cancel, never a rival listener whose redirect
    // could supersede the winner's.
    if signin_in_flight(state) {
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
    state.pending_signin = Some(PendingSignin {
        ceremony,
        listener,
        abandoned: Arc::new(AtomicBool::new(false)),
    });
    Ok(authorize_url)
}

/// End whichever sign-in ceremony stands, parked or out on the browser,
/// by raising its flag. True when there was something to end.
pub(crate) fn abandon_signin(state: &mut SyncState) -> bool {
    let mut ended = false;
    if let Some(pending) = state.pending_signin.take() {
        pending.abandoned.store(true, Ordering::Relaxed);
        ended = true;
    }
    if let Some(flag) = state.awaiting_redirect.take() {
        flag.store(true, Ordering::Relaxed);
        ended = true;
    }
    ended
}

/// Let go of the browser trip only if the state still names this
/// finish's ceremony, so a stale finish never clears a newer one.
pub(crate) fn release_redirect(state: &mut SyncState, mine: &Arc<AtomicBool>) {
    if state
        .awaiting_redirect
        .as_ref()
        .is_some_and(|held| Arc::ptr_eq(held, mine))
    {
        state.awaiting_redirect = None;
    }
}

/// Finish the ceremony with no lock held: wait for the redirect, redeem
/// the code and exchange it. Failures (`abandoned`, `state_mismatch`,
/// `no_code`, `unreachable`, `refused`) store nothing. The abandon flag
/// is read at each of the three waits, so a cancel or sign-out ends the
/// trip where it stands and a late grant is never parsed.
pub(crate) fn signin_finish<T: Transport>(
    pending: PendingSignin,
    patience: Duration,
    transport: &T,
) -> Result<TokenGrant, &'static str> {
    let abandoned = Arc::clone(&pending.abandoned);
    if abandoned.load(Ordering::Relaxed) {
        return Err("abandoned");
    }
    let Some(query) = pending.listener.accept_redirect(patience, &abandoned) else {
        return Err("abandoned");
    };
    if abandoned.load(Ordering::Relaxed) {
        return Err("abandoned");
    }
    let request = pending
        .ceremony
        .redeem(&query)
        .map_err(|error| match error {
            SyncAuthError::StateMismatch => "state_mismatch",
            SyncAuthError::NoCode => "no_code",
            _ => "refused",
        })?;
    let mut response = transport.send(request).map_err(|_| "unreachable")?;
    if abandoned.load(Ordering::Relaxed) {
        response.body.zeroize();
        return Err("abandoned");
    }
    // The body carried both tokens; the grant holds them now.
    let grant = parse_token_response(&response).map_err(|_| "refused");
    response.body.zeroize();
    grant
}

/// The keeper for a configuration, resuming from the persisted refresh
/// token if one rests.
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

// ---------------------------------------------------------------------
// The engine driver (issue #102): enrolment, attach, and the pump
// ---------------------------------------------------------------------

/// Tolerance under which a re-read expiry deadline counts as the one
/// already published, absorbing the clock reads' straddle.
const DEADLINE_JITTER_MS: u64 = 1_000;

/// Unix epoch milliseconds for wall stamps peers read; never an input
/// to expiry math.
fn wall_now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| {
            u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
        })
}

/// Enrol a page into the channel, or withdraw it, which performs any due
/// ceremony on the spot (client protocol §2). A page past its deadline
/// does not enrol (ADR-0052).
pub(crate) fn enrol_page(companion: &mut Companion, sheet: SheetId, enrolled: bool) -> bool {
    let Some(page) = companion
        .store
        .sheet(sheet)
        .map(companion_core::Sheet::uuid)
    else {
        return false;
    };
    if enrolled {
        if companion.store.is_due(sheet) {
            return false;
        }
        if !companion.store.set_compaction_deferred(sheet, true) {
            return false;
        }
        companion
            .sync
            .enrolled
            .entry(page)
            .or_insert_with(PageTracking::at_enrolment);
    } else {
        let _ = companion.store.set_compaction_deferred(sheet, false);
        companion.sync.enrolled.remove(&page);
    }
    true
}

/// The reasons an attach can refuse, as machine tokens.
type Refusal = &'static str;

/// Attach to the channel, building the engine if none stands. Blocking.
/// Answers and package rules: client protocol §4.3 and §5.
pub(crate) fn attach(handle: &CompanionHandle) -> serde_json::Value {
    let _flight = match AttachFlight::begin(handle) {
        Ok(flight) => flight,
        Err(reason) => return serde_json::json!({ "ok": false, "reason": reason }),
    };
    attach_in_flight(handle)
}

/// The attach itself, under an [`AttachFlight`]; its own function so
/// every guard here is released before the flight's drop re-locks.
fn attach_in_flight(handle: &CompanionHandle) -> serde_json::Value {
    if let Err(reason) = ensure_engine(handle) {
        return serde_json::json!({ "ok": false, "reason": reason });
    }
    if let Err(reason) = ensure_access(handle) {
        return serde_json::json!({ "ok": false, "reason": reason });
    }
    // Build the attach request under the lock, send it off-lock, and
    // absorb; one refresh-and-retry on a 401, per account-auth.md §2.
    for retry in [false, true] {
        let staged = {
            let Ok(mut guard) = handle.inner.lock() else {
                return serde_json::json!({ "ok": false, "reason": "poisoned" });
            };
            let transport = guard.sync.config.as_ref().map(SyncConfig::transport);
            let Some(engine) = guard.sync.engine.as_mut() else {
                return serde_json::json!({ "ok": false, "reason": "not_attached" });
            };
            // The pending package when one waits, else the standing one
            // (client protocol §5.5).
            let sent = engine
                .pending_packages
                .as_ref()
                .unwrap_or(&engine.packages)
                .package()
                .clone();
            engine
                .session
                .attach_request(&sent)
                .zip(transport)
                .map(|(request, transport)| (request, transport, sent))
        };
        let Some((request, transport, sent)) = staged else {
            return serde_json::json!({ "ok": false, "reason": "signed_out" });
        };
        let Ok(response) = transport.send(request) else {
            if let Ok(mut guard) = handle.inner.lock() {
                note_fault(&mut guard, GateFault::Unreachable);
            }
            return serde_json::json!({ "ok": false, "reason": "unreachable" });
        };
        let Ok(mut guard) = handle.inner.lock() else {
            return serde_json::json!({ "ok": false, "reason": "poisoned" });
        };
        let Some(engine) = guard.sync.engine.as_mut() else {
            return serde_json::json!({ "ok": false, "reason": "not_attached" });
        };
        match engine.session.absorb_attach(&response) {
            Ok(()) => {
                adopt_accepted(engine, &sent);
                let answer = serde_json::json!({
                    "ok": true,
                    "epoch": engine.session.attach_epoch(),
                    "frame_present": engine.session.frame_present(),
                    "peers": engine.session.attach_roster().len(),
                });
                note_reachable(&mut guard);
                return answer;
            }
            Err(RelayRefusal::Unauthorized) if !retry => {
                drop(guard);
                if let Err(reason) = ensure_access(handle) {
                    return serde_json::json!({ "ok": false, "reason": reason });
                }
            }
            Err(RelayRefusal::Unauthorized) => return attach_refused(&mut guard),
            Err(_) => return serde_json::json!({ "ok": false, "reason": "refused" }),
        }
    }
    serde_json::json!({ "ok": false, "reason": "refused" })
}

/// A second `401` on one attach signs out as a refused refresh does
/// (client protocol §4.3; open as §10.2). Noting the fault alone would
/// leave a refused gate, which nothing retries, over a stored credential.
fn attach_refused(companion: &mut Companion) -> serde_json::Value {
    sign_out_locked(companion);
    serde_json::json!({ "ok": false, "reason": "signed_out" })
}

/// The one attach in flight; every other attach answers `busy` until
/// it drops. One attach can make up to four sequential bounded calls
/// (two refreshes, two attaches), so that is how long `busy` can last.
struct AttachFlight<'a>(&'a CompanionHandle);

impl<'a> AttachFlight<'a> {
    /// `busy` while another attach is in flight.
    fn begin(handle: &'a CompanionHandle) -> Result<Self, Refusal> {
        let Ok(mut guard) = handle.inner.lock() else {
            return Err("poisoned");
        };
        if guard.sync.attaching {
            return Err("busy");
        }
        guard.sync.attaching = true;
        Ok(Self(handle))
    }
}

impl Drop for AttachFlight<'_> {
    fn drop(&mut self) {
        // Cleared through a poisoned lock too, so the flag never
        // outlives the attach that raised it.
        let mut guard = self
            .0
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.sync.attaching = false;
    }
}

/// Detach: dissolve the engine, keep the sign-in, and tell the relay,
/// best effort (client protocol §4.8). Blocking for one round-trip.
pub(crate) fn detach(handle: &CompanionHandle) -> bool {
    let staged = {
        let Ok(mut guard) = handle.inner.lock() else {
            return false;
        };
        let Some(keeper) = dissolve_engine(&mut guard) else {
            return false;
        };
        let request = keeper.access().map(|access| {
            let relay_url = guard
                .sync
                .config
                .as_ref()
                .map_or(String::new(), |config| config.relay_url.clone());
            companion_sync::RelayApi::new(relay_url)
                .detach_request(&ots_client::BearerAuth::new(access))
        });
        let transport = guard.sync.config.as_ref().map(SyncConfig::transport);
        guard.sync.keeper = Some(keeper);
        request.zip(transport)
    };
    if let Some((request, transport)) = staged {
        let _ = transport.send(request);
    }
    true
}

/// What an accepted attach does to the packages, matched by value
/// against the package sent (client protocol §5.2).
fn adopt_accepted(engine: &mut EngineState, sent: &KeyPackage) {
    if engine
        .pending_packages
        .as_ref()
        .is_some_and(|pending| pending.package() == sent)
        && let Some(fresh) = engine.pending_packages.take()
    {
        engine.packages = fresh;
    }
    if engine.packages.package() == sent {
        engine.packages.mark_published();
    }
}

/// Whether this device owes the relay a fresh key package: the
/// standing one is spent or unpublished, or a pending one waits, and
/// no ballot is in flight (client protocol §5.4).
fn package_needs_republish(engine: &EngineState) -> bool {
    (engine.packages.is_spent()
        || !engine.packages.is_published()
        || engine.pending_packages.is_some())
        && !engine.session.ballot_in_flight()
}

/// Build the engine if none stands, minting what pairing has not
/// delivered (the founder path). Needs configuration and a sign-in.
fn ensure_engine(handle: &CompanionHandle) -> Result<(), Refusal> {
    let Ok(mut guard) = handle.inner.lock() else {
        return Err("poisoned");
    };
    let Some(relay_url) = guard.sync.config.as_ref().map(|c| c.relay_url.clone()) else {
        return Err("not_configured");
    };
    // A package already waiting is resent unchanged: no Keychain read
    // and no mint (client protocol §5.2).
    if guard
        .sync
        .engine
        .as_ref()
        .is_some_and(|engine| engine.pending_packages.is_some())
    {
        return Ok(());
    }
    let credentials = &*guard.credentials;
    let Some(pkcs8) = pairing::ensure_device_identity(credentials) else {
        return Err("keychain");
    };
    let Some(fingerprint) = pairing::device_fingerprint(credentials) else {
        return Err("keychain");
    };
    let Some(secret) = pairing::ensure_channel_secret(credentials, true) else {
        return Err("keychain");
    };
    let Some(packages) = KeyPackageKeeper::mint(&pkcs8) else {
        return Err("keychain");
    };
    if let Some(engine) = guard.sync.engine.as_mut() {
        // Re-attach: the fresh package waits as pending until the relay
        // takes it (client protocol §5.2).
        engine.pending_packages = Some(packages);
        return Ok(());
    }
    let Some(keeper) = guard.sync.keeper.take() else {
        return Err("not_configured");
    };
    if !keeper.signed_in() {
        guard.sync.keeper = Some(keeper);
        return Err("signed_out");
    }
    let Some(chain) = GopKeyChain::root(&secret) else {
        guard.sync.keeper = Some(keeper);
        return Err("keychain");
    };
    let session = SyncSession::new(&relay_url, keeper, &fingerprint);
    guard.sync.engine = Some(EngineState {
        session,
        chain,
        packages,
        pending_packages: None,
        unpublished_frame: None,
    });
    Ok(())
}

/// Make sure an access token is held, refreshing if not; a refused
/// refresh signs out (account-auth.md §2, client protocol §4.2).
fn ensure_access(handle: &CompanionHandle) -> Result<(), Refusal> {
    let staged = {
        let Ok(mut guard) = handle.inner.lock() else {
            return Err("poisoned");
        };
        let transport = guard.sync.config.as_ref().map(SyncConfig::transport);
        let Some(engine) = guard.sync.engine.as_mut() else {
            return Err("not_attached");
        };
        if engine.session.keeper_mut().access().is_some() {
            return Ok(());
        }
        match engine.session.refresh_request() {
            Ok(request) => {
                let Some(transport) = transport else {
                    return Err("not_configured");
                };
                (request, transport)
            }
            Err(_) => {
                sign_out_locked(&mut guard);
                return Err("signed_out");
            }
        }
    };
    let (request, transport) = staged;
    let Ok(mut response) = transport.send(request) else {
        if let Ok(mut guard) = handle.inner.lock() {
            note_fault(&mut guard, GateFault::Unreachable);
        }
        return Err("unreachable");
    };
    let Ok(mut guard) = handle.inner.lock() else {
        response.body.zeroize();
        return Err("poisoned");
    };
    let Some(engine) = guard.sync.engine.as_mut() else {
        response.body.zeroize();
        return Err("not_attached");
    };
    // The body carried the tokens; it is wiped whichever way this goes.
    let absorbed = engine.session.absorb_refresh(&response);
    response.body.zeroize();
    match absorbed {
        // A rotated token lands before use; none means nothing to
        // write (ADR-0027 §2).
        Ok(rotated) => {
            if let Some(rotated) = rotated
                && !store_refresh(&*guard.credentials, &rotated)
            {
                diag_fault!("the credential store refused the rotated sync refresh token");
            }
            note_reachable(&mut guard);
            Ok(())
        }
        Err(SyncAuthError::SignedOut) => {
            sign_out_locked(&mut guard);
            Err("signed_out")
        }
        // Only `invalid_grant` signs out; anything else keeps the token
        // under `unreachable` (client protocol §4.2).
        Err(_) => {
            note_fault(&mut guard, GateFault::Unreachable);
            Err("unreachable")
        }
    }
}

/// The sign-out a refused refresh performs: delete the persisted token,
/// dissolve the engine, leave a signed-out keeper. The pad is untouched.
fn sign_out_locked(companion: &mut Companion) {
    let _ = clear_refresh(&*companion.credentials);
    // The dissolve rewinds what the relay never acknowledged.
    let _ = dissolve_engine(companion);
    companion.sync.fault = Some(GateFault::Refused);
    if let Some(config) = &companion.sync.config {
        companion.sync.keeper = Some(TokenKeeper::new(&config.token_url, &config.client_id, None));
    }
}

/// One outbound sweep, under the lock and off the network: queue each
/// page's new ops, moved deadline or hold, or a dead page's marker, then
/// rotate when a page is due (client protocol §3 step 2, §7.1).
pub(crate) fn sweep_outbound(
    companion: &mut Companion,
    now_ms: u64,
    events: &mut Vec<serde_json::Value>,
) {
    let wall_ms = companion.store.wall_ms();
    let Companion {
        store,
        sync,
        credentials,
        ..
    } = companion;
    let SyncState {
        engine,
        enrolled,
        staged_batch,
        ..
    } = sync;
    let Some(engine) = engine.as_mut() else {
        return;
    };
    let mut rotate = false;
    let mut due_target: Option<ItemId> = None;
    for (page, tracking) in enrolled.iter_mut() {
        match sheet_of(store, *page) {
            Some(sheet) => {
                // ADR-0052: past its deadline a page gives the relay no ops,
                // and none queued earlier reach a seal.
                let past_deadline = store.is_due(sheet);
                if past_deadline {
                    engine.session.withdraw_ops(*page);
                } else if let Some(version) = store.document_version(sheet)
                    && version != tracking.frontier
                    && let Some(update) = store.export_document_updates(sheet, &tracking.frontier)
                {
                    engine.session.queue_ops(*page, &update);
                    tracking.frontier = version;
                }
                if let Some(policy) = store.expiry_policy(sheet) {
                    let deadline = policy.deadline_wall_ms();
                    let moved = tracking
                        .deadline_wall_ms
                        .is_none_or(|last| deadline.abs_diff(last) > DEADLINE_JITTER_MS);
                    if moved {
                        engine.session.queue_expiry(*page, policy);
                        tracking.deadline_wall_ms = Some(deadline);
                    }
                }
                if let Some(register) = store.hold_register(sheet)
                    && hold_moved(tracking.hold, register)
                {
                    engine.session.queue_hold(*page, register);
                    tracking.hold = Some(register);
                }
                // Client protocol §7.1: a due page is the target; a live
                // page only anchors the rotation a marker owes.
                if store.ceremony_due(sheet) {
                    rotate = true;
                    due_target = due_target.or(Some(*page));
                }
            }
            None => {
                engine.session.withdraw_ops(*page);
                // The page died here: sign its marker every sweep until
                // it queues, once per engine, then rotate (§6, §7.1).
                if !tracking.terminal_sent
                    && let Some(marker) = signed_terminal_marker(&**credentials, *page, wall_ms)
                    && engine.session.queue_terminal(*page, &marker)
                {
                    tracking.terminal_sent = true;
                    rotate = true;
                }
            }
        }
    }
    if rotate
        && let Some(target) = due_target.or_else(|| live_anchor(store, enrolled))
        && rotate_channel(store, engine, &**credentials, target, now_ms, events)
    {
        settle_frontier(store, enrolled, staged_batch, target);
    }
}

/// The first enrolled page held here before its deadline, the anchor of a
/// rotation no page is owed; a page past it would refuse (ADR-0052).
fn live_anchor(
    store: &companion_core::SheetStore<companion_core::SystemClock>,
    enrolled: &BTreeMap<ItemId, PageTracking>,
) -> Option<ItemId> {
    enrolled
        .keys()
        .copied()
        .find(|page| sheet_of(store, *page).is_some_and(|sheet| !store.is_due(sheet)))
}

/// Whether a re-read hold register is a new fact. `until_wall_ms` is
/// recomputed on every read, so it gets the deadline's jitter.
fn hold_moved(last: Option<HoldRegister>, next: HoldRegister) -> bool {
    match (last, next) {
        (Some(HoldRegister::Released), HoldRegister::Released) => false,
        (
            Some(HoldRegister::Held {
                until_wall_ms: last_until,
                frozen_ms: last_frozen,
                topped_up: last_topped,
            }),
            HoldRegister::Held {
                until_wall_ms,
                frozen_ms,
                topped_up,
            },
        ) => {
            last_frozen != frozen_ms
                || last_topped != topped_up
                || until_wall_ms.abs_diff(last_until) > DEADLINE_JITTER_MS
        }
        // Nothing published yet, or the register changed shape.
        _ => true,
    }
}

/// Move a page's export and acknowledged cursors to its rebuilt
/// version without exporting, and drop the page from any staged batch:
/// the rebuild travels only as the frame (client protocol §7.6).
fn settle_frontier(
    store: &companion_core::SheetStore<companion_core::SystemClock>,
    enrolled: &mut BTreeMap<ItemId, PageTracking>,
    staged: &mut Option<StagedBatch>,
    page: ItemId,
) {
    if let Some(tracking) = enrolled.get_mut(&page)
        && let Some(sheet) = sheet_of(store, page)
        && let Some(version) = store.document_version(sheet)
    {
        tracking.frontier = version.clone();
        tracking.acked = version;
        // A late acknowledgement must not lower a settled cursor.
        if let Some(staged) = staged.as_mut() {
            staged.cursors.remove(&page);
        }
    }
}

/// Build the publish request and, for a newly sealed batch, record each
/// page's export cursor; a resend keeps the first record (client
/// protocol §4.4).
fn stage_publish(companion: &mut Companion, now_ms: u64) -> Option<ots_client::HttpRequest> {
    let engine = companion.sync.engine.as_mut()?;
    let EngineState { session, chain, .. } = engine;
    let request = session.publish_request(now_ms, chain)?;
    let batch = session.in_flight_batch();
    let known = companion
        .sync
        .staged_batch
        .as_ref()
        .is_some_and(|staged| Some(staged.id) == batch);
    if let Some(id) = batch
        && !known
    {
        // A batch this call sealed carries each cursor as it stands now.
        companion.sync.staged_batch = Some(StagedBatch {
            id,
            cursors: companion
                .sync
                .enrolled
                .iter()
                .map(|(page, tracking)| (*page, tracking.frontier.clone()))
                .collect(),
        });
    }
    Some(request)
}

/// Absorb a publish answer under the lock: acceptance advances each
/// acknowledged cursor to what the batch carried, and a refusal that
/// drops the batch drops its record (client protocol §4.4).
fn absorb_publish_locked(
    companion: &mut Companion,
    response: &HttpResponse,
) -> Option<Result<(), RelayRefusal>> {
    let engine = companion.sync.engine.as_mut()?;
    let absorbed = engine.session.absorb_publish(response);
    let still_in_flight = engine.session.in_flight_batch().is_some();
    if let Err(refusal) = absorbed {
        if !still_in_flight {
            companion.sync.staged_batch = None;
        }
        return Some(Err(refusal));
    }
    if let Some(staged) = companion.sync.staged_batch.take() {
        for (page, carried) in staged.cursors {
            if let Some(tracking) = companion.sync.enrolled.get_mut(&page) {
                tracking.acked = carried;
            }
        }
    }
    note_reachable(companion);
    Some(Ok(()))
}

/// Dissolve the engine, handing back its keeper, and rewind every page
/// to its acknowledged cursor (client protocol §2).
pub(crate) fn dissolve_engine(companion: &mut Companion) -> Option<TokenKeeper> {
    // The batch and its record die with the session that sealed it.
    companion.sync.staged_batch = None;
    for tracking in companion.sync.enrolled.values_mut() {
        tracking.frontier = tracking.acked.clone();
        tracking.deadline_wall_ms = None;
        tracking.hold = None;
        tracking.terminal_sent = false;
    }
    companion.sync.pairing = None;
    companion
        .sync
        .engine
        .take()
        .map(|engine| engine.session.into_keeper())
}

/// Rotate the channel at `target`: a ballot to the verified peers, or
/// solo when there are none (client protocol §7.2, §7.3, §7.9). True
/// when the solo path committed and the page owes a settled cursor.
fn rotate_channel(
    store: &mut companion_core::SheetStore<companion_core::SystemClock>,
    engine: &mut EngineState,
    credentials: &dyn CredentialStore,
    target: ItemId,
    now_ms: u64,
    events: &mut Vec<serde_json::Value>,
) -> bool {
    let identities: Vec<(String, Vec<u8>)> = pairing::peer_records(credentials)
        .into_iter()
        .map(|record| (record.fingerprint, record.identity_pub))
        .collect();
    let peers = engine.session.ceremony_peers(&identities);
    let page = crate::sync_session::page_wire_id(target);
    let page_id = sheet_of(store, target).map(SheetId::raw);
    if peers.is_empty() {
        if engine
            .session
            .solo_ceremony(target, store, &mut engine.chain)
        {
            events.push(serde_json::json!({
                "kind": "ceremony_committed", "page": page, "page_id": page_id
            }));
            return true;
        }
    } else {
        let own = engine.packages.package().clone();
        if engine
            .session
            .propose_ceremony(target, &peers, &own, now_ms)
        {
            events.push(serde_json::json!({
                "kind": "ceremony_proposed", "page": page, "page_id": page_id
            }));
        }
    }
    false
}

/// A terminal marker: the page id and wall stamp, signed by the device
/// identity (`companion_core::TerminalMarker`).
fn signed_terminal_marker(
    credentials: &dyn CredentialStore,
    page: ItemId,
    at_wall_ms: u64,
) -> Option<Vec<u8>> {
    let pkcs8 = pairing::ensure_device_identity(credentials)?;
    let identity = Ed25519KeyPair::from_pkcs8(&pkcs8).ok()?;
    let mut marker = page.as_bytes().to_vec();
    marker.extend_from_slice(&at_wall_ms.to_be_bytes());
    let signature = identity.sign(&crate::persist::signing_domain(
        crate::sync_session::TERMINAL_SIGN_CONTEXT,
        &marker,
    ));
    marker.extend_from_slice(signature.as_ref());
    Some(marker)
}

/// One pump in client protocol §3's order: refresh, sweep and publish,
/// the long-poll fetch, an owed attach, the frame PUT. Blocking; the
/// core mutex is held only between round trips.
pub(crate) fn pump(handle: &CompanionHandle, wait_seconds: u32) -> serde_json::Value {
    let mut events: Vec<serde_json::Value> = Vec::new();
    if let Err(reason) = ensure_access(handle) {
        return pump_result(handle, Some(reason), &events);
    }

    // Outbound: sweep, ballot patience, and the publish batch.
    let staged = {
        let Ok(mut guard) = handle.inner.lock() else {
            return pump_result(handle, Some("poisoned"), &events);
        };
        let now = guard.sync.now_ms();
        sweep_outbound(&mut guard, now, &mut events);
        let transport = guard.sync.config.as_ref().map(SyncConfig::transport);
        let Some(engine) = guard.sync.engine.as_mut() else {
            return pump_result(handle, Some("not_attached"), &events);
        };
        engine.session.tick(now);
        let due = engine.session.publish_due(now);
        let publish = due.then(|| stage_publish(&mut guard, now)).flatten();
        publish.zip(transport)
    };
    if let Some((request, transport)) = staged {
        publish_round(handle, &transport, request, &mut events);
    }

    // Inbound: the long poll.
    let staged = {
        let Ok(guard) = handle.inner.lock() else {
            return pump_result(handle, Some("poisoned"), &events);
        };
        let transport = guard.sync.config.as_ref().map(SyncConfig::transport);
        guard
            .sync
            .engine
            .as_ref()
            .and_then(|engine| engine.session.fetch_request(wait_seconds))
            .zip(transport)
    };
    let mut committed = false;
    if let Some((request, transport)) = staged {
        match transport.send(request) {
            Err(_) => {
                if let Ok(mut guard) = handle.inner.lock() {
                    note_fault(&mut guard, GateFault::Unreachable);
                }
                events.push(serde_json::json!({ "kind": "unreachable" }));
            }
            Ok(response) => {
                let Ok(mut guard) = handle.inner.lock() else {
                    return pump_result(handle, Some("poisoned"), &events);
                };
                // The relay answered, whatever it said.
                note_reachable(&mut guard);
                let now = guard.sync.now_ms();
                let Companion {
                    store,
                    sync,
                    credentials,
                    ..
                } = &mut *guard;
                let trusted = pairing::trusted_identities(&**credentials);
                if let Some(engine) = sync.engine.as_mut() {
                    let EngineState {
                        session,
                        chain,
                        packages,
                        pending_packages,
                        ..
                    } = engine;
                    match session.absorb_deltas(
                        &response,
                        store,
                        chain,
                        packages,
                        pending_packages,
                        &trusted,
                        now,
                    ) {
                        Ok(absorbed) => {
                            committed = absorbed
                                .iter()
                                .any(|event| matches!(event, SyncEvent::CeremonyCommitted(_)));
                            events.extend(absorbed.iter().map(|event| event_json(event, store)));
                            // A drained commit settles the page's cursor.
                            for event in &absorbed {
                                if let SyncEvent::CeremonyCommitted(page) = event {
                                    settle_frontier(
                                        store,
                                        &mut sync.enrolled,
                                        &mut sync.staged_batch,
                                        *page,
                                    );
                                }
                            }
                        }
                        // Client protocol §4.5: a 401 drops the access
                        // token and is reported; the next turn refreshes.
                        Err(refusal) => events.push(refusal_json(&refusal)),
                    }
                }
            }
        }
    }

    // Client protocol §5.4: attach when a ceremony committed this turn
    // or a key package is owed.
    let owes_package = {
        let Ok(guard) = handle.inner.lock() else {
            return pump_result(handle, Some("poisoned"), &events);
        };
        guard
            .sync
            .engine
            .as_ref()
            .is_some_and(package_needs_republish)
    };
    if committed || owes_package {
        let _ = attach(handle);
    }

    // Client protocol §7.8: the committed frame is kept until a 2xx or
    // a 409, so a dropped round retries next turn.
    let staged = {
        let Ok(mut guard) = handle.inner.lock() else {
            return pump_result(handle, Some("poisoned"), &events);
        };
        let transport = guard.sync.config.as_ref().map(SyncConfig::transport);
        guard
            .sync
            .engine
            .as_mut()
            .and_then(|engine| {
                if let Some(frame) = engine.session.take_frame() {
                    engine.unpublished_frame = Some(frame);
                }
                let frame = engine.unpublished_frame.as_deref()?;
                let EngineState { session, chain, .. } = engine;
                session.publish_frame_request(chain, frame)
            })
            .zip(transport)
    };
    if let Some((request, transport)) = staged
        && let Ok(response) = transport.send(request)
        && (response.status == 409 || (200..300).contains(&response.status))
    {
        let Ok(mut guard) = handle.inner.lock() else {
            return pump_result(handle, Some("poisoned"), &events);
        };
        if let Some(engine) = guard.sync.engine.as_mut() {
            engine.unpublished_frame = None;
        }
    }

    pump_result(handle, None, &events)
}

/// Send one publish batch, absorbing the answer; a `401` refreshes
/// and retries the one request, everything else is an event.
fn publish_round(
    handle: &CompanionHandle,
    transport: &companion_transport::UreqTransport,
    request: ots_client::HttpRequest,
    events: &mut Vec<serde_json::Value>,
) {
    let Ok(response) = transport.send(request) else {
        if let Ok(mut guard) = handle.inner.lock() {
            note_fault(&mut guard, GateFault::Unreachable);
        }
        events.push(serde_json::json!({ "kind": "unreachable" }));
        return;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return;
    };
    let Some(absorbed) = absorb_publish_locked(&mut guard, &response) else {
        return;
    };
    match absorbed {
        Ok(()) => {}
        Err(RelayRefusal::Unauthorized) => {
            drop(guard);
            if ensure_access(handle).is_err() {
                return;
            }
            // The one retry, the same batch at the refreshed auth.
            let staged = {
                let Ok(mut guard) = handle.inner.lock() else {
                    return;
                };
                let now = guard.sync.now_ms();
                stage_publish(&mut guard, now)
            };
            let Some(rebuilt) = staged else {
                return;
            };
            let Ok(response) = transport.send(rebuilt) else {
                events.push(serde_json::json!({ "kind": "unreachable" }));
                return;
            };
            let Ok(mut guard) = handle.inner.lock() else {
                return;
            };
            if let Some(Err(refusal)) = absorb_publish_locked(&mut guard, &response) {
                events.push(refusal_json(&refusal));
            }
        }
        Err(refusal) => {
            if matches!(refusal, RelayRefusal::CeremonyRequired) {
                // Client protocol §4.4: at the cap, rotate now.
                let now = guard.sync.now_ms();
                let Companion {
                    store,
                    sync,
                    credentials,
                    ..
                } = &mut *guard;
                let SyncState {
                    engine, enrolled, ..
                } = sync;
                if let Some(engine) = engine.as_mut()
                    && let Some(target) = live_anchor(store, enrolled)
                {
                    rotate_channel(store, engine, &**credentials, target, now, events);
                }
            }
            events.push(refusal_json(&refusal));
        }
    }
}

/// One event as the shell reads it: `page` is the cross-device identity,
/// `page_id` the local id (null for no page or one no longer kept here).
fn event_json(
    event: &SyncEvent,
    store: &companion_core::SheetStore<companion_core::SystemClock>,
) -> serde_json::Value {
    let page = |page: &ItemId| crate::sync_session::page_wire_id(*page);
    let local = |page: &ItemId| sheet_of(store, *page).map(SheetId::raw);
    match event {
        SyncEvent::Applied(id) => {
            serde_json::json!({ "kind": "applied", "page": page(id), "page_id": local(id) })
        }
        SyncEvent::CountdownMoved(id) => {
            serde_json::json!({ "kind": "countdown_moved", "page": page(id), "page_id": local(id) })
        }
        SyncEvent::Terminal(id) => {
            serde_json::json!({ "kind": "terminal", "page": page(id), "page_id": local(id) })
        }
        SyncEvent::RejoinRequired => serde_json::json!({ "kind": "rejoin_required" }),
        SyncEvent::CeremonyCommitted(id) => {
            serde_json::json!({
                "kind": "ceremony_committed", "page": page(id), "page_id": local(id)
            })
        }
        SyncEvent::SignedOut => serde_json::json!({ "kind": "signed_out" }),
    }
}

fn refusal_json(refusal: &RelayRefusal) -> serde_json::Value {
    let kind = match refusal {
        RelayRefusal::Unauthorized => "unauthorized",
        RelayRefusal::EpochConflict => "epoch_conflict",
        RelayRefusal::Rejoin => "rejoin_required",
        RelayRefusal::CeremonyRequired => "ceremony_required",
        RelayRefusal::Protocol(_) => "protocol",
    };
    serde_json::json!({ "kind": kind })
}

/// The pump's result: what happened and where sync now stands, one
/// JSON for the shell's status surface.
fn pump_result(
    handle: &CompanionHandle,
    reason: Option<&'static str>,
    events: &[serde_json::Value],
) -> serde_json::Value {
    let state = handle
        .inner
        .lock()
        .map_or(serde_json::Value::Null, |guard| status_json(&guard));
    serde_json::json!({
        "ok": reason.is_none(),
        "reason": reason,
        "events": events,
        "state": state,
    })
}

/// Note that a round trip reached its host: clears `unreachable` only,
/// since a refusal stands until the user signs in again (ADR-0027 §2).
fn note_reachable(companion: &mut Companion) {
    if companion.sync.fault == Some(GateFault::Unreachable) {
        companion.sync.fault = None;
    }
}

/// Note what the last attempt met. A refusal outranks an unreachable
/// host, because the second is a retry and the first is a sign-out.
fn note_fault(companion: &mut Companion, fault: GateFault) {
    if companion.sync.fault != Some(GateFault::Refused) || fault == GateFault::Refused {
        companion.sync.fault = Some(fault);
    }
}

/// Forget every fault: a granted ceremony, a reconfigure, or a
/// deliberate sign-out starts fresh.
pub(crate) fn clear_fault(companion: &mut Companion) {
    companion.sync.fault = None;
}

/// Where the account gate stands (ADR-0027 §5), from existence checks
/// and in-memory reads only.
pub(crate) fn gate_of(companion: &Companion) -> SyncGate {
    let sync = &companion.sync;
    gate(GateInputs {
        configured: sync.config.is_some(),
        signin_pending: signin_in_flight(sync),
        credential: credential_rests(companion),
        fault: sync.fault,
        // A `401` drops the access token, so this reads `ready` until
        // the refresh lands.
        attached: sync
            .engine
            .as_ref()
            .is_some_and(|engine| engine.session.attached() && engine.session.has_access()),
    })
}

/// Whether a sign-in ceremony is in flight, parked or out on the
/// browser; one state outside this module.
pub(crate) fn signin_in_flight(sync: &SyncState) -> bool {
    sync.pending_signin.is_some() || sync.awaiting_redirect.is_some()
}

/// Whether any account credential rests here: the live keeper's if one
/// stands, the keychain account's otherwise.
fn credential_rests(companion: &Companion) -> bool {
    let sync = &companion.sync;
    sync.engine.as_ref().map_or_else(
        || {
            sync.keeper.as_ref().map_or_else(
                || signed_in(&*companion.credentials),
                TokenKeeper::signed_in,
            )
        },
        |engine| engine.session.signed_in(),
    )
}

/// Sync's standing state, from existence checks and in-memory reads
/// only, so rendering Settings never decrypts or waits.
pub(crate) fn status_json(companion: &Companion) -> serde_json::Value {
    let sync = &companion.sync;
    let signed_in = credential_rests(companion);
    serde_json::json!({
        "configured": sync.config.is_some(),
        "signed_in": signed_in,
        "gate": gate_of(companion).token(),
        "signin_pending": signin_in_flight(sync),
        "attached": sync.engine.as_ref().is_some_and(|engine| engine.session.attached()),
        "epoch": sync.engine.as_ref().map(|engine| engine.chain.epoch()),
        "frame_present": sync.engine.as_ref().and_then(|engine| engine.session.frame_present()),
        "enrolled": sync.enrolled.len(),
        "pairing": sync.pairing.as_ref().map(|flow| stage_word(&flow.step)),
    })
}

/// The device list: this device, every verified peer with its attach
/// time, and any attached but unverified stranger, each labelled.
pub(crate) fn devices_json(companion: &Companion) -> serde_json::Value {
    let records = pairing::peer_records(&*companion.credentials);
    let roster = companion
        .sync
        .engine
        .as_ref()
        .map_or(&[][..], |engine| engine.session.attach_roster());
    let own = pairing::stored_device_fingerprint(&*companion.credentials);
    let mut devices: Vec<serde_json::Value> = Vec::new();
    if let Some(fingerprint) = &own {
        devices.push(serde_json::json!({
            "fingerprint": fingerprint,
            "label": "",
            "this_device": true,
            "verified": true,
            "paired_wall_ms": null,
            "attached_ms": null,
        }));
    }
    for record in &records {
        let attached_ms = roster
            .iter()
            .find(|peer| peer.device == record.fingerprint)
            .map(|peer| peer.attached_ms);
        devices.push(serde_json::json!({
            "fingerprint": record.fingerprint,
            "label": record.label,
            "this_device": false,
            "verified": true,
            "paired_wall_ms": record.paired_wall_ms,
            "attached_ms": attached_ms,
        }));
    }
    for peer in roster {
        let known = Some(&peer.device) == own.as_ref()
            || records
                .iter()
                .any(|record| record.fingerprint == peer.device);
        if !known {
            devices.push(serde_json::json!({
                "fingerprint": peer.device,
                "label": "",
                "this_device": false,
                "verified": false,
                "paired_wall_ms": null,
                "attached_ms": peer.attached_ms,
            }));
        }
    }
    serde_json::json!({ "devices": devices })
}

// ---------------------------------------------------------------------
// Pairing over the mailbox (issue #97's ceremony, §7's rendezvous)
// ---------------------------------------------------------------------

/// A pairing ceremony in flight: the state machine between mailbox
/// polls, one at a time (client protocol §9).
pub(crate) struct PairingState {
    /// Mailbox cursor for the next fetch.
    since: u64,
    /// Wire messages queued for posting, drained by the poll and kept
    /// on a transport failure so the next poll retries.
    outgoing: Vec<serde_json::Value>,
    step: PairingStep,
}

enum PairingStep {
    /// Inviter: commitment posted, waiting for the joiner's offer.
    InviterWaitOffer(pairing::Inviter),
    /// Inviter settled: the SAS is on screen; the grant waits for the
    /// joiner's acceptance signature AND this human's confirmation,
    /// in either order.
    InviterWaitAcceptance {
        settled: pairing::Settled,
        acceptance_ok: bool,
        human_confirmed: bool,
    },
    /// Joiner: waiting for a commitment to answer.
    JoinerWaitCommitment { pkcs8: Zeroizing<Vec<u8>> },
    /// Joiner: offer posted, waiting for the reveal.
    JoinerWaitReveal(pairing::Joiner),
    /// Joiner settled: the SAS is on screen; the acceptance posts
    /// only after this human confirms.
    JoinerSasConfirm {
        settled: pairing::Settled,
        acceptance: pairing::Acceptance,
    },
    /// Joiner confirmed: waiting for the grant.
    JoinerWaitGrant { settled: pairing::Settled },
    /// The ceremony completed; the record is written.
    Done,
    /// The ceremony failed; nothing was stored.
    Failed(&'static str),
}

fn stage_word(step: &PairingStep) -> &'static str {
    match step {
        PairingStep::InviterWaitOffer(_)
        | PairingStep::JoinerWaitCommitment { .. }
        | PairingStep::JoinerWaitReveal(_) => "waiting",
        PairingStep::InviterWaitAcceptance {
            human_confirmed: false,
            ..
        }
        | PairingStep::JoinerSasConfirm { .. } => "sas",
        PairingStep::InviterWaitAcceptance { .. } | PairingStep::JoinerWaitGrant { .. } => {
            "confirmed"
        }
        PairingStep::Done => "done",
        PairingStep::Failed(_) => "failed",
    }
}

fn stage_json(flow: &PairingState) -> serde_json::Value {
    // A ceremony that still owes a post reads `confirmed`, not `done`:
    // the shell stops polling at `done`, and only the poll drains.
    let stage = if matches!(flow.step, PairingStep::Done) && !flow.outgoing.is_empty() {
        "confirmed"
    } else {
        stage_word(&flow.step)
    };
    let sas = match &flow.step {
        PairingStep::InviterWaitAcceptance {
            settled,
            human_confirmed: false,
            ..
        }
        | PairingStep::JoinerSasConfirm { settled, .. } => Some(settled.sas().to_owned()),
        _ => None,
    };
    let reason = match flow.step {
        PairingStep::Failed(reason) => Some(reason),
        _ => None,
    };
    serde_json::json!({
        "stage": stage,
        "sas": sas,
        "reason": reason,
    })
}

/// Begin inviting: this attached, paired-or-founding device offers
/// the channel to a new one. Posts the commitment on the next poll.
pub(crate) fn invite_begin(companion: &mut Companion) -> Result<(), Refusal> {
    pairing_begin(companion, true)
}

/// Begin joining: this signed-in, attached device waits for an
/// inviter's commitment.
pub(crate) fn join_begin(companion: &mut Companion) -> Result<(), Refusal> {
    pairing_begin(companion, false)
}

fn pairing_begin(companion: &mut Companion, inviter: bool) -> Result<(), Refusal> {
    if companion.sync.engine.is_none() {
        return Err("not_attached");
    }
    if companion.sync.pairing.is_some() {
        return Err("busy");
    }
    let Some(pkcs8) = pairing::ensure_device_identity(&*companion.credentials) else {
        return Err("keychain");
    };
    let (outgoing, step) = if inviter {
        let Some((state, commitment)) = pairing::Inviter::begin(&pkcs8) else {
            return Err("no_entropy");
        };
        (
            vec![MailboxMessage::Commitment(commitment).encode()],
            PairingStep::InviterWaitOffer(state),
        )
    } else {
        (Vec::new(), PairingStep::JoinerWaitCommitment { pkcs8 })
    };
    companion.sync.pairing = Some(PairingState {
        since: 0,
        outgoing,
        step,
    });
    Ok(())
}

/// Advance the machine with one mailbox message; unexpected kinds,
/// echoes included, change nothing. True when a grant just landed.
fn advance_pairing(
    flow: &mut PairingState,
    message: MailboxMessage,
    credentials: &dyn CredentialStore,
) -> bool {
    let step = std::mem::replace(&mut flow.step, PairingStep::Failed("torn"));
    let mut joined = false;
    flow.step = match (step, message) {
        (PairingStep::InviterWaitOffer(inviter), MailboxMessage::Offer(offer)) => {
            match inviter.settle(&offer) {
                Some((settled, reveal)) => {
                    flow.outgoing.push(MailboxMessage::Reveal(reveal).encode());
                    PairingStep::InviterWaitAcceptance {
                        settled,
                        acceptance_ok: false,
                        human_confirmed: false,
                    }
                }
                None => PairingStep::Failed("offer"),
            }
        }
        (
            PairingStep::InviterWaitAcceptance {
                settled,
                human_confirmed,
                ..
            },
            MailboxMessage::Acceptance(acceptance),
        ) => {
            if settled.verify_acceptance(&acceptance) {
                maybe_grant(
                    PairingStep::InviterWaitAcceptance {
                        settled,
                        acceptance_ok: true,
                        human_confirmed,
                    },
                    &mut flow.outgoing,
                    credentials,
                )
            } else {
                PairingStep::Failed("acceptance")
            }
        }
        (PairingStep::JoinerWaitCommitment { pkcs8 }, MailboxMessage::Commitment(commitment)) => {
            match pairing::Joiner::accept(&pkcs8, &commitment) {
                Some((joiner, offer)) => {
                    flow.outgoing.push(MailboxMessage::Offer(offer).encode());
                    PairingStep::JoinerWaitReveal(joiner)
                }
                None => PairingStep::Failed("commitment"),
            }
        }
        (PairingStep::JoinerWaitReveal(joiner), MailboxMessage::Reveal(reveal)) => {
            match joiner.settle(&reveal) {
                Some((settled, acceptance)) => PairingStep::JoinerSasConfirm {
                    settled,
                    acceptance,
                },
                None => PairingStep::Failed("reveal"),
            }
        }
        (PairingStep::JoinerWaitGrant { settled }, MailboxMessage::Grant(grant)) => {
            match settled.receive(&grant) {
                None => PairingStep::Failed("grant"),
                Some(secret) => {
                    // Client protocol §9: record the peer before storing
                    // the secret; either refusal fails the step.
                    let recorded = pairing::record_peer(
                        credentials,
                        settled.peer_identity(),
                        "",
                        wall_now_ms(),
                    );
                    if recorded && pairing::store_channel_secret(credentials, &secret) {
                        joined = true;
                        PairingStep::Done
                    } else {
                        PairingStep::Failed("keychain")
                    }
                }
            }
        }
        (step, _) => step,
    };
    joined
}

/// When the acceptance verified AND the human confirmed, the grant
/// goes out and the peer is recorded; until both, the step stands.
fn maybe_grant(
    step: PairingStep,
    outgoing: &mut Vec<serde_json::Value>,
    credentials: &dyn CredentialStore,
) -> PairingStep {
    let PairingStep::InviterWaitAcceptance {
        settled,
        acceptance_ok: true,
        human_confirmed: true,
    } = step
    else {
        return step;
    };
    let Some(secret) = pairing::ensure_channel_secret(credentials, true) else {
        return PairingStep::Failed("keychain");
    };
    // A grant that fails to seal shares the `keychain` token.
    let Some(grant) = settled.grant(&secret) else {
        return PairingStep::Failed("keychain");
    };
    // Client protocol §9: record the peer before queuing the grant; a
    // refused record fails the step.
    if !pairing::record_peer(credentials, settled.peer_identity(), "", wall_now_ms()) {
        return PairingStep::Failed("keychain");
    }
    outgoing.push(MailboxMessage::Grant(grant).encode());
    PairingStep::Done
}

/// The human's verdict on the SAS; a mismatch drops this side's
/// ceremony whole, with nothing stored.
pub(crate) fn pairing_confirm(companion: &mut Companion, matched: bool) -> serde_json::Value {
    let Some(mut flow) = companion.sync.pairing.take() else {
        return serde_json::json!({ "stage": "idle" });
    };
    if !matched {
        // The peer keeps polling until cancelled; there is no client
        // deadline (client protocol §10.22).
        return serde_json::json!({ "stage": "failed", "reason": "mismatch" });
    }
    let step = std::mem::replace(&mut flow.step, PairingStep::Failed("torn"));
    flow.step = match step {
        PairingStep::InviterWaitAcceptance {
            settled,
            acceptance_ok,
            ..
        } => maybe_grant(
            PairingStep::InviterWaitAcceptance {
                settled,
                acceptance_ok,
                human_confirmed: true,
            },
            &mut flow.outgoing,
            &*companion.credentials,
        ),
        PairingStep::JoinerSasConfirm {
            settled,
            acceptance,
        } => {
            flow.outgoing
                .push(MailboxMessage::Acceptance(acceptance).encode());
            PairingStep::JoinerWaitGrant { settled }
        }
        step => step,
    };
    let stage = stage_json(&flow);
    companion.sync.pairing = Some(flow);
    stage
}

/// Post the queued messages in order until the queue empties or the
/// wire declines, leaving the rest queued. `Err` carries the stage to
/// report instead, `signed_out` when no request can be built.
fn drain_outgoing(handle: &CompanionHandle) -> Result<(), serde_json::Value> {
    loop {
        let staged = {
            let Ok(guard) = handle.inner.lock() else {
                return Err(serde_json::json!({ "stage": "failed", "reason": "poisoned" }));
            };
            let Some(flow) = guard.sync.pairing.as_ref() else {
                return Err(serde_json::json!({ "stage": "idle" }));
            };
            let transport = guard.sync.config.as_ref().map(SyncConfig::transport);
            flow.outgoing.first().cloned().map(|message| {
                let sent = message.clone();
                guard
                    .sync
                    .engine
                    .as_ref()
                    .and_then(|engine| engine.session.post_pairing_request(message))
                    .zip(transport)
                    .map(|(request, transport)| (sent, request, transport))
            })
        };
        match staged {
            None => return Ok(()),
            Some(None) => {
                return Err(serde_json::json!({ "stage": "failed", "reason": "signed_out" }));
            }
            Some(Some((sent, request, transport))) => match transport.send(request) {
                Ok(response) if (200..300).contains(&response.status) => {
                    // Remove the head only if it is still this post;
                    // the queue may have moved while unlocked.
                    if let Ok(mut guard) = handle.inner.lock()
                        && let Some(flow) = guard.sync.pairing.as_mut()
                        && flow.outgoing.first() == Some(&sent)
                    {
                        flow.outgoing.remove(0);
                    }
                }
                _ => return Ok(()),
            },
        }
    }
}

/// One mailbox round: drain, fetch the tail, advance, drain again, and
/// report the stage. Blocking (client protocol §4.7).
pub(crate) fn pairing_poll(handle: &CompanionHandle) -> serde_json::Value {
    match ensure_access(handle) {
        Ok(()) => {}
        Err("unreachable") => return serde_json::json!({ "stage": "waiting" }),
        Err(reason) => return serde_json::json!({ "stage": "failed", "reason": reason }),
    }
    if let Err(stage) = drain_outgoing(handle) {
        return stage;
    }
    // Fetch the tail and advance.
    let staged = {
        let Ok(guard) = handle.inner.lock() else {
            return serde_json::json!({ "stage": "failed", "reason": "poisoned" });
        };
        let since = guard.sync.pairing.as_ref().map(|flow| flow.since);
        let transport = guard.sync.config.as_ref().map(SyncConfig::transport);
        since
            .and_then(|since| {
                guard
                    .sync
                    .engine
                    .as_ref()
                    .and_then(|engine| engine.session.fetch_pairing_request(since))
            })
            .zip(transport)
    };
    if let Some((request, transport)) = staged
        && let Ok(response) = transport.send(request)
        && (200..300).contains(&response.status)
        && let Ok(mut guard) = handle.inner.lock()
    {
        absorb_mailbox(&mut guard, &response);
    }
    // Advancing may have queued the grant; send it this round.
    if let Err(stage) = drain_outgoing(handle) {
        return stage;
    }
    let Ok(guard) = handle.inner.lock() else {
        return serde_json::json!({ "stage": "failed", "reason": "poisoned" });
    };
    guard
        .sync
        .pairing
        .as_ref()
        .map_or(serde_json::json!({ "stage": "idle" }), stage_json)
}

/// Absorb one mailbox answer (relay protocol §7), skipping unknown
/// shapes; a landed grant re-roots the chain.
pub(crate) fn absorb_mailbox(companion: &mut Companion, response: &HttpResponse) {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&response.body) else {
        return;
    };
    let Some(flow) = companion.sync.pairing.as_mut() else {
        return;
    };
    if let Some(next) = value.get("next_seq").and_then(serde_json::Value::as_u64) {
        flow.since = next;
    }
    let mut joined = false;
    if let Some(messages) = value.get("messages").and_then(serde_json::Value::as_array) {
        for entry in messages {
            if let Some(message) = MailboxMessage::decode(entry) {
                joined |= advance_pairing(flow, message, &*companion.credentials);
            }
        }
    }
    if joined
        && let Some(secret) = pairing::ensure_channel_secret(&*companion.credentials, false)
        && let Some(chain) = GopKeyChain::root(&secret)
        && let Some(engine) = companion.sync.engine.as_mut()
    {
        // Client protocol §8: the delivered secret re-roots the chain at
        // epoch zero, which leaves a joiner behind on a rotated channel.
        engine.chain = chain;
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::io::{Read as _, Write as _};
    use std::net::TcpStream;
    use std::sync::Arc;

    use companion_credentials::InMemoryCredentialStore;
    use companion_sync::DeltaEnvelope;
    use ots_client::{HttpRequest, HttpResponse, TransportError};

    use super::*;

    /// A token endpoint in a box: hands back the canned response and
    /// keeps the request for assertions.
    struct MockTransport {
        seen: RefCell<Option<HttpRequest>>,
        response: HttpResponse,
        raises: Option<Arc<AtomicBool>>,
    }

    impl MockTransport {
        fn granting() -> Self {
            Self {
                seen: RefCell::new(None),
                response: HttpResponse {
                    status: 200,
                    body: br#"{"access_token":"at-1","refresh_token":"rt-1"}"#.to_vec(),
                },
                raises: None,
            }
        }

        /// A token endpoint that ends the ceremony while it answers.
        fn raising(mut self, flag: Arc<AtomicBool>) -> Self {
            self.raises = Some(flag);
            self
        }
    }

    impl Transport for MockTransport {
        fn send(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
            *self.seen.borrow_mut() = Some(request);
            if let Some(flag) = &self.raises {
                flag.store(true, Ordering::Relaxed);
            }
            Ok(HttpResponse {
                status: self.response.status,
                body: self.response.body.clone(),
            })
        }
    }

    /// A token endpoint that raises the abandon flag itself and then
    /// grants: the window between a landed redirect and the grant.
    struct SurrenderingTransport {
        abandoned: Arc<AtomicBool>,
    }

    impl Transport for SurrenderingTransport {
        fn send(&self, _request: HttpRequest) -> Result<HttpResponse, TransportError> {
            self.abandoned.store(true, Ordering::Relaxed);
            Ok(HttpResponse {
                status: 200,
                body: br#"{"access_token":"at-1","refresh_token":"rt-1"}"#.to_vec(),
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
            ..SyncState::default()
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
    fn a_spent_package_with_no_ballot_in_flight_is_owed_a_fresh_attach() {
        let credentials = InMemoryCredentialStore::default();
        let mut engine = attached_engine(&credentials);
        assert!(
            !package_needs_republish(&engine),
            "a published, unspent package owes nothing"
        );
        // The device opened its entry on a ballot, and the ballot has
        // since been abandoned: no scope, a spent package.
        assert!(engine.packages.open_entropy(&[0u8; 64]).is_none());
        assert!(!engine.session.ballot_in_flight());
        assert!(
            package_needs_republish(&engine),
            "the relay's roster names a package nobody can open"
        );
    }

    #[test]
    fn a_fresh_package_whose_attach_never_landed_is_owed_another() {
        // An attach that failed before sending leaves an unspent package
        // the relay has never seen.
        let credentials = InMemoryCredentialStore::default();
        let mut engine = attached_engine(&credentials);
        let pkcs8 = pairing::ensure_device_identity(&credentials).unwrap();
        engine.packages = KeyPackageKeeper::mint(&pkcs8).unwrap();
        assert!(!engine.packages.is_spent());
        assert!(
            package_needs_republish(&engine),
            "a mint the relay never accepted is not reachable"
        );
        engine.packages.mark_published();
        assert!(!package_needs_republish(&engine));
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
    fn an_invalidated_ceremony_never_exchanges_its_code() {
        let mut state = configured();
        let authorize_url = signin_begin(&mut state).unwrap();
        let pending = state.pending_signin.take().unwrap();
        browser_returns(&authorize_url, pending.listener.port(), None);
        // A sign-out (or a cancel) while the browser trip is out.
        pending.abandoned.store(true, Ordering::Relaxed);

        let transport = MockTransport::granting();
        let refused = signin_finish(pending, Duration::from_secs(5), &transport);
        assert_eq!(refused.err(), Some("abandoned"));
        assert!(
            transport.seen.borrow().is_none(),
            "a ceremony the user ended may not redeem its code"
        );
    }

    #[test]
    fn a_ceremony_ended_during_the_exchange_grants_nothing() {
        let mut state = configured();
        let authorize_url = signin_begin(&mut state).unwrap();
        let pending = state.pending_signin.take().unwrap();
        browser_returns(&authorize_url, pending.listener.port(), None);
        // A sign-out between the redirect and the grant persists nothing.
        let transport = MockTransport::granting().raising(Arc::clone(&pending.abandoned));

        let refused = signin_finish(pending, Duration::from_secs(5), &transport);
        assert_eq!(
            refused.err(),
            Some("abandoned"),
            "the grant arrived after the ceremony was ended, so it is not a grant"
        );
    }

    #[test]
    fn a_begin_is_busy_while_a_finish_holds_the_ceremony() {
        let mut state = configured();
        let _ = signin_begin(&mut state).unwrap();
        // The finish took the ceremony and is out on the browser trip.
        let pending = state.pending_signin.take().unwrap();
        state.awaiting_redirect = Some(Arc::clone(&pending.abandoned));
        assert_eq!(
            signin_begin(&mut state).unwrap_err(),
            "busy",
            "a second listener bound behind the first is not a retry"
        );
        // Giving up is the way out, and it ends the trip that is out.
        assert!(abandon_signin(&mut state));
        assert!(pending.abandoned.load(Ordering::Relaxed));
        assert!(signin_begin(&mut state).is_ok());
    }

    #[test]
    fn a_stale_finish_does_not_release_a_newer_ceremony() {
        let mut state = configured();
        let _ = signin_begin(&mut state).unwrap();
        let stale = state.pending_signin.take().unwrap();
        state.awaiting_redirect = Some(Arc::clone(&stale.abandoned));
        assert!(abandon_signin(&mut state));

        // A fresh ceremony, begun and taken while the stale finish is
        // still unwinding.
        let _ = signin_begin(&mut state).unwrap();
        let fresh = state.pending_signin.take().unwrap();
        state.awaiting_redirect = Some(Arc::clone(&fresh.abandoned));
        release_redirect(&mut state, &stale.abandoned);
        assert!(
            state.awaiting_redirect.is_some(),
            "the stale finish let go of a trip that was never its own"
        );
        assert!(!fresh.abandoned.load(Ordering::Relaxed));
        release_redirect(&mut state, &fresh.abandoned);
        assert!(state.awaiting_redirect.is_none());
    }

    #[test]
    fn one_ceremony_at_a_time_and_a_cancel_clears_the_way() {
        let mut state = configured();
        let _ = signin_begin(&mut state).unwrap();
        assert_eq!(signin_begin(&mut state).unwrap_err(), "busy");
        assert!(abandon_signin(&mut state));
        assert!(signin_begin(&mut state).is_ok());
    }

    #[test]
    fn an_event_names_the_page_in_both_the_languages_the_seam_speaks() {
        let mut store = companion_core::SheetStore::new(companion_core::SystemClock);
        let sheet = store.new_tab().1;
        let page = store.sheet(sheet).unwrap().uuid();

        let applied = event_json(&SyncEvent::Applied(page), &store);
        assert_eq!(applied["kind"], "applied");
        assert_eq!(
            applied["page"],
            crate::sync_session::page_wire_id(page),
            "the peers' name for it"
        );
        assert_eq!(
            applied["page_id"],
            serde_json::json!(sheet.raw()),
            "and this device's, which is the one a surface can point at"
        );

        // A page this device does not hold has no local id.
        let stranger = event_json(&SyncEvent::Applied(ItemId::random()), &store);
        assert_eq!(stranger["page_id"], serde_json::Value::Null);

        // An event about no page at all names neither.
        let signed_out = event_json(&SyncEvent::SignedOut, &store);
        assert_eq!(signed_out["kind"], "signed_out");
        assert_eq!(signed_out.get("page_id"), None);
    }

    #[test]
    fn giving_up_ends_the_browser_trip_rather_than_waiting_it_out() {
        let mut state = configured();
        let _ = signin_begin(&mut state).unwrap();
        let pending = state.pending_signin.take().unwrap();
        let abandoned = Arc::clone(&pending.abandoned);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(60));
            abandoned.store(true, Ordering::Relaxed);
        });
        let transport = MockTransport::granting();
        let began = Instant::now();
        // A consent screen's patience; only the give-up answers sooner.
        let refused = signin_finish(pending, Duration::from_secs(300), &transport);
        assert_eq!(refused.err(), Some("abandoned"));
        assert!(began.elapsed() < Duration::from_secs(10));
        assert!(
            transport.seen.borrow().is_none(),
            "a ceremony nobody finished redeems nothing"
        );
    }

    #[test]
    fn a_give_up_during_the_exchange_stores_nothing() {
        // The redirect lands and the give-up comes during the exchange.
        let credentials = InMemoryCredentialStore::default();
        let mut state = configured();
        let authorize_url = signin_begin(&mut state).unwrap();
        let pending = state.pending_signin.take().unwrap();
        browser_returns(&authorize_url, pending.listener.port(), None);
        let transport = SurrenderingTransport {
            abandoned: Arc::clone(&pending.abandoned),
        };

        let refused = signin_finish(pending, Duration::from_secs(5), &transport);
        assert_eq!(
            refused.err(),
            Some("abandoned"),
            "a grant nobody is waiting for any more is not a sign-in"
        );
        assert!(
            !store_refresh_was_called(&credentials),
            "and nothing of it may rest here"
        );
    }

    /// Whether anything ever landed in the sync refresh account.
    fn store_refresh_was_called(credentials: &InMemoryCredentialStore) -> bool {
        load_refresh(credentials).is_some()
    }

    #[test]
    fn a_fresh_ceremony_does_not_inherit_the_last_one_s_surrender() {
        let mut state = configured();
        let _ = signin_begin(&mut state).unwrap();
        assert!(abandon_signin(&mut state));
        let _ = signin_begin(&mut state).unwrap();
        let today = state.pending_signin.as_ref().unwrap();
        assert!(
            !today.abandoned.load(Ordering::Relaxed),
            "yesterday's surrender may not abandon today's browser trip"
        );
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

    fn store_companion(credentials: Arc<dyn CredentialStore>) -> Companion {
        Companion {
            store: companion_core::SheetStore::new(companion_core::SystemClock),
            pasteboard: crate::Board::Memory(companion_pasteboard::MemoryPasteboard::new()),
            last_write: None,
            connection: None,
            credentials,
            wire: crate::conceal::Wire::real(),
            sync: SyncState::default(),
            files: companion_core::FileStore::new(),
            last_open_refusal: None,
            last_save_refusal: None,
            drafts_notices: Vec::new(),
        }
    }

    #[test]
    fn a_re_attach_keeps_the_standing_package_until_the_relay_takes_its_replacement() {
        let credentials = InMemoryCredentialStore::default();
        let mut engine = attached_engine(&credentials);
        let standing = engine.packages.package().clone();
        let pkcs8 = pairing::ensure_device_identity(&credentials).unwrap();

        // A re-attach mints beside the standing package; the pump still
        // owes an attach, since the answer may have been lost.
        engine.pending_packages = Some(KeyPackageKeeper::mint(&pkcs8).unwrap());
        let sent = engine.pending_packages.as_ref().unwrap().package().clone();
        assert_eq!(engine.packages.package(), &standing);
        assert!(engine.packages.is_published());
        assert!(package_needs_republish(&engine));

        // A concurrent re-attach minted again while the first was in
        // flight: the first's acceptance is not the second's.
        let first = sent.clone();
        engine.pending_packages = Some(KeyPackageKeeper::mint(&pkcs8).unwrap());
        adopt_accepted(&mut engine, &first);
        assert_eq!(engine.packages.package(), &standing);
        assert!(engine.pending_packages.is_some());

        // The acceptance of the package that waits swaps it in.
        let sent = engine.pending_packages.as_ref().unwrap().package().clone();
        adopt_accepted(&mut engine, &sent);
        assert_eq!(engine.packages.package(), &sent);
        assert!(engine.packages.is_published());
        assert!(engine.pending_packages.is_none());
        assert!(!package_needs_republish(&engine));
    }

    fn attached_engine(credentials: &dyn CredentialStore) -> EngineState {
        let pkcs8 = pairing::ensure_device_identity(credentials).unwrap();
        let secret = pairing::ensure_channel_secret(credentials, true).unwrap();
        let mut keeper = TokenKeeper::new("https://eu.example/oauth/token", "companion", None);
        let _ = keeper.absorb(TokenGrant {
            access: Zeroizing::new("at".into()),
            refresh: Zeroizing::new("rt".into()),
        });
        // Attached, as the name says: the relay has accepted this
        // engine's package.
        let mut packages = KeyPackageKeeper::mint(&pkcs8).unwrap();
        packages.mark_published();
        EngineState {
            session: SyncSession::new(
                "https://relay.example",
                keeper,
                &pairing::device_fingerprint(credentials).unwrap(),
            ),
            chain: GopKeyChain::root(&secret).unwrap(),
            packages,
            pending_packages: None,
            unpublished_frame: None,
        }
    }

    fn inked_page(companion: &mut Companion, text: &str) -> SheetId {
        let page = companion.store.new_tab().1;
        assert!(companion.store.apply_ops(
            page,
            &[companion_core::EditOp::Insert {
                pos_u16: 0,
                text: text.into(),
            }],
        ));
        page
    }

    #[test]
    fn enrolment_sweeps_the_whole_page_once_and_then_only_changes() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        let page = inked_page(&mut companion, "shared ink");
        companion.sync.engine = Some(attached_engine(&*credentials));
        assert!(enrol_page(&mut companion, page, true));

        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        let engine = companion.sync.engine.as_mut().unwrap();
        assert!(engine.session.publish_due(0), "the whole page is owed");
        let EngineState { session, chain, .. } = engine;
        let _ = session.publish_request(0, chain).unwrap();
        session
            .absorb_publish(&HttpResponse {
                status: 200,
                body: br#"{"seq":1}"#.to_vec(),
            })
            .unwrap();

        // Nothing changed: the next sweep owes nothing.
        sweep_outbound(&mut companion, 2_000, &mut events);
        let engine = companion.sync.engine.as_mut().unwrap();
        assert!(!engine.session.publish_due(2_000));

        // An edit owes exactly the delta past the cursor.
        assert!(companion.store.apply_ops(
            page,
            &[companion_core::EditOp::Insert {
                pos_u16: 0,
                text: "more ".into(),
            }],
        ));
        sweep_outbound(&mut companion, 4_000, &mut events);
        let engine = companion.sync.engine.as_mut().unwrap();
        assert!(engine.session.publish_due(4_000));
    }

    /// Play the relay accepting a batch: the answer §4 gives a publish.
    fn accepted() -> HttpResponse {
        HttpResponse {
            status: 200,
            body: br#"{"seq":1}"#.to_vec(),
        }
    }

    #[test]
    fn a_sign_out_mid_session_keeps_the_unpublished_edits_for_the_next_attach() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        companion.sync.config = configured().config;
        let page = inked_page(&mut companion, "the line the peers never got");
        companion.sync.engine = Some(attached_engine(&*credentials));
        assert!(enrol_page(&mut companion, page, true));

        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        assert!(
            companion
                .sync
                .engine
                .as_ref()
                .unwrap()
                .session
                .publish_due(0),
            "the sweep queued the page"
        );
        // The relay never saw it: the access token expired mid session
        // and the refresh was refused, so the engine dissolves.
        let uuid = companion.store.sheet(page).unwrap().uuid();
        sign_out_locked(&mut companion);
        assert!(companion.sync.engine.is_none());
        assert!(
            companion.store.sheet(page).is_some(),
            "the pad keeps every character; the account failure cost nothing"
        );
        assert_eq!(
            companion.sync.enrolled[&uuid].frontier,
            companion_core::SheetStore::<companion_core::SystemClock>::pristine_document_version(),
            "nothing was acknowledged, so the cursor rewinds the whole way"
        );

        // Signed in and attached again, the unsent edit is owed again.
        companion.sync.engine = Some(attached_engine(&*credentials));
        sweep_outbound(&mut companion, 10_000, &mut events);
        assert_eq!(
            companion.sync.enrolled[&uuid].frontier,
            companion.store.document_version(page).unwrap(),
            "the re-attached sweep exported the page again"
        );
        let engine = companion.sync.engine.as_mut().unwrap();
        assert!(engine.session.publish_due(10_000));
        let EngineState { session, chain, .. } = engine;
        assert!(session.publish_request(10_000, chain).is_some());
    }

    #[test]
    fn a_refused_refresh_names_its_state_and_leaves_the_pad_whole() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        credentials.store("api-token", b"conceal-token").unwrap();
        let ledger = crate::persist::ensure_ledger_key(&*credentials).unwrap();
        let mut companion = store_companion(Arc::clone(&credentials));
        companion.sync.config = configured().config;
        assert!(store_refresh(
            &*credentials,
            &Zeroizing::new("rt-1".to_owned())
        ));
        companion.sync.keeper = Some(keeper_for(
            companion.sync.config.as_ref().unwrap(),
            &*credentials,
        ));
        let page = inked_page(&mut companion, "work in progress");
        assert_eq!(gate_of(&companion), SyncGate::Ready);

        // The refresh came back refused: the grant is dead and the
        // resting token goes with it.
        sign_out_locked(&mut companion);
        assert_eq!(
            gate_of(&companion),
            SyncGate::Refused,
            "a refusal is told apart from never having signed in"
        );
        assert_eq!(
            status_json(&companion)["gate"],
            "refused",
            "the seam reports the state, and the shell owns the words"
        );

        // The pad is untouched: the page stands, a new one opens, and
        // the neighbouring credentials are exactly where they were.
        assert!(companion.store.sheet(page).is_some());
        assert!(companion.store.apply_ops(
            page,
            &[companion_core::EditOp::Insert {
                pos_u16: 0,
                text: "still typing ".into(),
            }],
        ));
        companion.store.new_tab();
        assert_eq!(*credentials.load("api-token").unwrap(), b"conceal-token");
        assert_eq!(
            *crate::persist::load_ledger_key(&*credentials).unwrap(),
            *ledger
        );
        assert!(!signed_in(&*credentials), "the sync account alone is gone");
    }

    #[test]
    fn a_second_401_on_one_attach_deletes_the_grant() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        companion.sync.config = configured().config;
        assert!(store_refresh(
            &*credentials,
            &Zeroizing::new("rt-1".to_owned())
        ));
        companion.sync.keeper = Some(keeper_for(
            companion.sync.config.as_ref().unwrap(),
            &*credentials,
        ));
        assert_eq!(gate_of(&companion), SyncGate::Ready);

        let answer = attach_refused(&mut companion);
        assert_eq!(answer["reason"], "signed_out");
        assert_eq!(gate_of(&companion), SyncGate::Refused);
        assert!(
            !signed_in(&*credentials),
            "`refused` is the state whose whole meaning is that the credential is gone"
        );
        assert_eq!(
            status_json(&companion)["signed_in"],
            false,
            "the status may not say signed in over a refused gate"
        );
    }

    #[test]
    fn a_dead_bearer_is_not_reported_as_an_attachment() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        companion.sync.config = configured().config;
        let mut engine = attached_engine(&*credentials);
        engine
            .session
            .absorb_attach(&HttpResponse {
                status: 200,
                body: br#"{"epoch":0,"frame_present":false,"next_seq":0,"peers":[]}"#.to_vec(),
            })
            .unwrap();
        companion.sync.engine = Some(engine);
        assert_eq!(gate_of(&companion), SyncGate::Attached);

        // A refused bearer mid poll reads `ready` until the refresh.
        companion
            .sync
            .engine
            .as_mut()
            .unwrap()
            .session
            .keeper_mut()
            .clear_access();
        assert_eq!(gate_of(&companion), SyncGate::Ready);
    }

    #[test]
    fn a_relay_that_did_not_answer_never_reads_as_a_refusal() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        companion.sync.config = configured().config;
        assert!(store_refresh(
            &*credentials,
            &Zeroizing::new("rt-1".to_owned())
        ));
        companion.sync.keeper = Some(keeper_for(
            companion.sync.config.as_ref().unwrap(),
            &*credentials,
        ));

        note_fault(&mut companion, GateFault::Unreachable);
        assert_eq!(gate_of(&companion), SyncGate::Unreachable);
        assert!(
            signed_in(&*credentials),
            "an unanswered request deletes nothing"
        );
        // And the state clears itself the moment something answers.
        note_reachable(&mut companion);
        assert_eq!(gate_of(&companion), SyncGate::Ready);

        // A refusal, though, outlives a reachable host: only signing in
        // again is the way back from one.
        note_fault(&mut companion, GateFault::Refused);
        note_reachable(&mut companion);
        assert_eq!(gate_of(&companion), SyncGate::Refused);
        clear_fault(&mut companion);
        assert_eq!(gate_of(&companion), SyncGate::Ready);
    }

    #[test]
    fn an_unconfigured_handle_reports_off_and_touches_nothing() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let companion = store_companion(Arc::clone(&credentials));
        assert_eq!(gate_of(&companion), SyncGate::Off);
        assert_eq!(status_json(&companion)["gate"], "off");
    }

    #[test]
    fn the_sync_token_never_reaches_the_sealed_store() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        companion.sync.config = configured().config;
        let secret = "rt-a-secret-nobody-should-find-in-a-page";
        assert!(store_refresh(
            &*credentials,
            &Zeroizing::new(secret.to_owned())
        ));
        companion.sync.keeper = Some(keeper_for(
            companion.sync.config.as_ref().unwrap(),
            &*credentials,
        ));
        let page = inked_page(&mut companion, "an ordinary page");
        assert!(enrol_page(&mut companion, page, true));

        // The sealed snapshot carries no credential (ADR-0027 §4).
        let snapshot = companion.store.snapshot(1_700_000_000_000);
        let contains = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
        assert!(
            !contains(&snapshot, secret.as_bytes()),
            "the refresh token has no business in the content store"
        );
        // It rests in the key material account instead; the tier split
        // is the real store's own (`key_material_store`).
        assert!(load_refresh(&*credentials).is_some());
        assert!(
            credentials
                .key_material_store()
                .exists(SYNC_REFRESH_ACCOUNT)
                .unwrap_or(false)
        );
    }

    #[test]
    fn a_late_acceptance_never_moves_a_settled_cursor_back() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        companion.sync.config = configured().config;
        let page = inked_page(&mut companion, "keep DOOMED");
        assert!(companion.store.apply_ops(
            page,
            &[companion_core::EditOp::Delete {
                pos_u16: 4,
                len_u16: 7,
            }],
        ));
        companion.sync.engine = Some(attached_engine(&*credentials));
        assert!(enrol_page(&mut companion, page, true));
        let uuid = companion.store.sheet(page).unwrap().uuid();

        // A batch is sealed at V1 and its answer goes missing.
        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        assert!(stage_publish(&mut companion, 0).is_some());
        let before_rebuild = companion.sync.enrolled[&uuid].frontier.clone();

        // A rotation while that batch is out settles both cursors.
        let tab = companion.store.tabs().next().unwrap().id();
        companion.store.cycle_rung(tab).unwrap();
        sweep_outbound(&mut companion, 4_000, &mut events);
        let rebuilt = companion.store.document_version(page).unwrap();
        assert_ne!(rebuilt, before_rebuild, "the ceremony rebuilt the page");
        assert_eq!(companion.sync.enrolled[&uuid].acked, rebuilt);

        // The late answer may not restore the replaced cursor.
        assert_eq!(
            absorb_publish_locked(&mut companion, &accepted()),
            Some(Ok(()))
        );
        assert_eq!(
            companion.sync.enrolled[&uuid].acked, rebuilt,
            "an acknowledged cursor never moves backwards"
        );

        // So the dissolve rewinds to the rebuild and owes no text.
        sign_out_locked(&mut companion);
        companion.sync.engine = Some(attached_engine(&*credentials));
        sweep_outbound(&mut companion, 10_000, &mut events);
        assert_eq!(
            companion.sync.enrolled[&uuid].frontier, rebuilt,
            "the rebuilt body does not travel a second time as a delta"
        );
    }

    #[test]
    fn an_answer_to_a_resent_batch_acknowledges_only_what_that_batch_carried() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        companion.sync.config = configured().config;
        let page = inked_page(&mut companion, "the first line");
        companion.sync.engine = Some(attached_engine(&*credentials));
        assert!(enrol_page(&mut companion, page, true));
        let uuid = companion.store.sheet(page).unwrap().uuid();

        // Pump one: sweep to V1, seal the batch, and lose the answer to
        // a transport error. The batch stays in flight.
        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        assert!(stage_publish(&mut companion, 0).is_some());
        let carried = companion.sync.enrolled[&uuid].frontier.clone();

        // Pump two: V2 queues behind the resent batch; only V1 is
        // acknowledged.
        assert!(companion.store.apply_ops(
            page,
            &[companion_core::EditOp::Insert {
                pos_u16: 0,
                text: "the second line ".into(),
            }],
        ));
        sweep_outbound(&mut companion, 4_000, &mut events);
        assert!(stage_publish(&mut companion, 4_000).is_some());
        let live = companion.sync.enrolled[&uuid].frontier.clone();
        assert_ne!(live, carried, "the sweep moved the cursor past the batch");
        assert_eq!(
            absorb_publish_locked(&mut companion, &accepted()),
            Some(Ok(()))
        );
        assert_eq!(
            companion.sync.enrolled[&uuid].acked, carried,
            "the relay took the first batch, and only the first batch"
        );

        // The second edit survives the refused refresh's dissolve.
        sign_out_locked(&mut companion);
        assert_eq!(companion.sync.enrolled[&uuid].frontier, carried);
        companion.sync.engine = Some(attached_engine(&*credentials));
        sweep_outbound(&mut companion, 10_000, &mut events);
        assert_eq!(
            companion.sync.enrolled[&uuid].frontier, live,
            "the second line is exported again rather than lost"
        );
        assert!(stage_publish(&mut companion, 10_000).is_some());
    }

    #[test]
    fn an_acknowledged_batch_is_not_owed_again_after_a_sign_out() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        companion.sync.config = configured().config;
        let page = inked_page(&mut companion, "the line the peers did get");
        companion.sync.engine = Some(attached_engine(&*credentials));
        assert!(enrol_page(&mut companion, page, true));

        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        assert!(stage_publish(&mut companion, 0).is_some());
        assert_eq!(
            absorb_publish_locked(&mut companion, &accepted()),
            Some(Ok(()))
        );

        let uuid = companion.store.sheet(page).unwrap().uuid();
        let published = companion.store.document_version(page).unwrap();
        sign_out_locked(&mut companion);
        assert_eq!(
            companion.sync.enrolled[&uuid].frontier, published,
            "the rewind stops at the last acknowledgement"
        );

        // The re-attached sweep restates expiry and hold, and no text.
        companion.sync.engine = Some(attached_engine(&*credentials));
        sweep_outbound(&mut companion, 10_000, &mut events);
        assert_eq!(companion.sync.enrolled[&uuid].frontier, published);
    }

    #[test]
    fn a_due_transition_with_an_empty_room_rotates_the_channel_solo() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        let page = inked_page(&mut companion, "keep DOOMED");
        assert!(companion.store.apply_ops(
            page,
            &[companion_core::EditOp::Delete {
                pos_u16: 4,
                len_u16: 7,
            }],
        ));
        companion.sync.engine = Some(attached_engine(&*credentials));
        assert!(enrol_page(&mut companion, page, true));
        let tab = companion.store.tabs().next().unwrap().id();
        companion.store.cycle_rung(tab).unwrap();

        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        let engine = companion.sync.engine.as_mut().unwrap();
        assert_eq!(engine.chain.epoch(), 1, "the boundary did not wait");
        assert!(
            events
                .iter()
                .any(|event| event["kind"] == "ceremony_committed")
        );
        let frame = engine.session.take_frame().expect("a frame to publish");
        let opened = engine.chain.open(&frame).unwrap();
        let contains = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
        assert!(!contains(&opened, b"DOOMED"));

        // The rebuild travels only as that frame; once the earlier batch
        // drains, the next sweep owes nothing.
        let EngineState { session, chain, .. } = engine;
        let _ = session.publish_request(0, chain).unwrap();
        session
            .absorb_publish(&HttpResponse {
                status: 200,
                body: br#"{"seq":1}"#.to_vec(),
            })
            .unwrap();
        sweep_outbound(&mut companion, 4_000, &mut events);
        let engine = companion.sync.engine.as_mut().unwrap();
        assert!(
            !engine.session.publish_due(4_000),
            "the rebuild must not be republished as a delta"
        );
    }

    #[test]
    fn the_rotation_targets_the_page_whose_ceremony_is_due() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        let (tab_a, page_a) = companion.store.new_tab();
        let (tab_b, page_b) = companion.store.new_tab();
        for page in [page_a, page_b] {
            assert!(companion.store.apply_ops(
                page,
                &[companion_core::EditOp::Insert {
                    pos_u16: 0,
                    text: "ink".into(),
                }],
            ));
        }
        // The due page iterates last, so an order-blind target fails.
        let uuid =
            |companion: &Companion, sheet: SheetId| companion.store.sheet(sheet).unwrap().uuid();
        let (due_tab, due_page) = if uuid(&companion, page_a) > uuid(&companion, page_b) {
            (tab_a, page_a)
        } else {
            (tab_b, page_b)
        };
        companion.sync.engine = Some(attached_engine(&*credentials));
        assert!(enrol_page(&mut companion, page_a, true));
        assert!(enrol_page(&mut companion, page_b, true));
        companion.store.cycle_rung(due_tab).unwrap();
        assert!(companion.store.ceremony_due(due_page));

        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        assert!(
            !companion.store.ceremony_due(due_page),
            "the due page, not the first-iterated one, must compact"
        );
        let engine = companion.sync.engine.as_mut().unwrap();
        assert_eq!(engine.chain.epoch(), 1, "one boundary, at the due page");
    }

    #[test]
    fn a_page_that_died_here_publishes_its_marker_once_the_view_is_current() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        let page = inked_page(&mut companion, "short lived");
        companion.sync.engine = Some(attached_engine(&*credentials));
        assert!(enrol_page(&mut companion, page, true));
        assert!(companion.store.discard_page(page));

        // No marker before the channel view is current.
        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        let engine = companion.sync.engine.as_mut().unwrap();
        assert!(!engine.session.publish_due(0), "the gate held");

        // One drain makes the view current; the marker queues, and with
        // no live page to compact the epoch stands.
        let empty = HttpResponse {
            status: 200,
            body: br#"{"epoch":0,"blobs":[],"next_seq":0}"#.to_vec(),
        };
        {
            let Companion { store, sync, .. } = &mut companion;
            let engine = sync.engine.as_mut().unwrap();
            let EngineState {
                session,
                chain,
                packages,
                pending_packages,
                ..
            } = engine;
            session
                .absorb_deltas(&empty, store, chain, packages, pending_packages, &[], 0)
                .unwrap();
        }
        sweep_outbound(&mut companion, 2_000, &mut events);
        let engine = companion.sync.engine.as_mut().unwrap();
        assert!(engine.session.publish_due(2_000), "the marker is owed");

        // And once only.
        sweep_outbound(&mut companion, 4_000, &mut events);
        let tracking = companion.sync.enrolled.values().next().unwrap();
        assert!(tracking.terminal_sent);
    }

    /// Age every page by `gap_ms` through snapshot and restore, as a launch
    /// after a long sleep does. Local ids are re-minted; page uuids stand.
    fn age_by(companion: &mut Companion, gap_ms: u64) {
        let sealed_wall_ms = 1_700_000_000_000;
        let snapshot = companion.store.snapshot(sealed_wall_ms);
        companion
            .store
            .restore(&snapshot, sealed_wall_ms + gap_ms)
            .expect("a store reads back its own snapshot");
    }

    const THREE_HOURS_MS: u64 = 3 * 60 * 60 * 1_000;

    /// A page on the one hour rung, which [`THREE_HOURS_MS`] takes past its
    /// deadline, unswept.
    fn short_lived_page(companion: &mut Companion, text: &str) -> ItemId {
        let page = inked_page(companion, text);
        let tab = companion.store.tabs().last().unwrap().id();
        assert!(
            companion
                .store
                .set_rung(tab, companion_core::Ttl::MIN)
                .is_some()
        );
        companion.store.sheet(page).unwrap().uuid()
    }

    /// Make the channel view current, as one drain does (client protocol §6).
    fn drain_nothing(companion: &mut Companion) {
        let empty = HttpResponse {
            status: 200,
            body: br#"{"epoch":0,"blobs":[],"next_seq":0}"#.to_vec(),
        };
        let Companion { store, sync, .. } = companion;
        let EngineState {
            session,
            chain,
            packages,
            pending_packages,
            ..
        } = sync.engine.as_mut().unwrap();
        session
            .absorb_deltas(&empty, store, chain, packages, pending_packages, &[], 0)
            .unwrap();
    }

    #[test]
    fn a_page_past_its_deadline_gives_the_relay_no_ops_queued_or_new() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        let uuid = short_lived_page(&mut companion, "queued before the deadline");
        companion.sync.engine = Some(attached_engine(&*credentials));
        let page = companion.store.sheet_id_of(uuid).unwrap();
        assert!(enrol_page(&mut companion, page, true));
        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        let ops_for_it = |companion: &Companion| {
            let wire = crate::sync_session::page_wire_id(uuid);
            let session = &companion.sync.engine.as_ref().unwrap().session;
            session
                .queued()
                .iter()
                .any(|e| matches!(e, DeltaEnvelope::Ops { page, .. } if *page == wire))
        };
        assert!(ops_for_it(&companion), "queued while readable, not sealed");

        // Past its deadline before the publish seals the queue, and written
        // to since, as the seam's write routes still allow.
        age_by(&mut companion, THREE_HOURS_MS);
        let page = companion.store.sheet_id_of(uuid).expect("no sweep took it");
        assert!(companion.store.is_due(page));
        assert!(companion.store.apply_ops(
            page,
            &[companion_core::EditOp::Insert {
                pos_u16: 0,
                text: "after the deadline ".into(),
            }],
        ));
        let frontier = companion.sync.enrolled[&uuid].frontier.clone();
        sweep_outbound(&mut companion, 2_000, &mut events);
        assert!(!ops_for_it(&companion), "nothing of it reaches a seal");
        assert_eq!(companion.sync.enrolled[&uuid].frontier, frontier);
        let session = &companion.sync.engine.as_ref().unwrap().session;
        assert!(
            session
                .queued()
                .iter()
                .any(|e| matches!(e, DeltaEnvelope::Expiry { ttl_ms: 0, .. })),
            "its deadline still goes, so a peer's copy dies too"
        );
    }

    /// Stage the next publish and open what it seals, as a peer would.
    fn staged_envelopes(companion: &mut Companion, now_ms: u64) -> Vec<DeltaEnvelope> {
        let EngineState { session, chain, .. } = companion.sync.engine.as_mut().unwrap();
        let Some(request) = session.publish_request(now_ms, chain) else {
            return Vec::new();
        };
        let mut body: serde_json::Value =
            serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
        body["next_seq"] = 0.into();
        let batch = companion_sync::relay::RelayApi::parse_deltas(&HttpResponse {
            status: 200,
            body: body.to_string().into_bytes(),
        })
        .unwrap();
        batch
            .blobs
            .iter()
            .map(|blob| {
                let plaintext = chain.open(blob).unwrap();
                DeltaEnvelope::decode(companion_sync::pad::unpad(&plaintext).unwrap()).unwrap()
            })
            .collect()
    }

    #[test]
    fn a_page_past_its_deadline_does_not_enrol_and_gives_the_relay_nothing() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        let uuid = short_lived_page(&mut companion, "hunter2, typed before the deadline");
        age_by(&mut companion, THREE_HOURS_MS);
        let page = companion.store.sheet_id_of(uuid).expect("no sweep took it");
        assert!(companion.store.is_due(page));
        companion.sync.engine = Some(attached_engine(&*credentials));

        assert!(!enrol_page(&mut companion, page, true));
        assert!(companion.sync.enrolled.is_empty());
        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        assert!(
            staged_envelopes(&mut companion, 0).is_empty(),
            "no publish is staged"
        );
        assert!(events.is_empty(), "and no ceremony");
        assert!(
            enrol_page(&mut companion, page, false),
            "withdrawing answers"
        );
    }

    #[test]
    fn a_closed_page_seals_no_queued_ops_and_its_rotation_anchors_before_a_deadline() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        let (due, live) = loop {
            let short = short_lived_page(&mut companion, "past its deadline");
            let long = inked_page(&mut companion, "still readable");
            let long = companion.store.sheet(long).unwrap().uuid();
            // The page past its deadline iterates first, so a blind anchor fails.
            if short < long {
                break (short, long);
            }
        };
        let gone = inked_page(&mut companion, "closed here");
        let gone = companion.store.sheet(gone).unwrap().uuid();
        companion.sync.engine = Some(attached_engine(&*credentials));
        for page in [due, live, gone] {
            let sheet = companion.store.sheet_id_of(page).unwrap();
            assert!(enrol_page(&mut companion, sheet, true));
        }
        // A restore defers no ceremony, so enrol again; the due page refuses.
        age_by(&mut companion, THREE_HOURS_MS);
        for page in [due, live, gone] {
            let sheet = companion.store.sheet_id_of(page).unwrap();
            assert_eq!(enrol_page(&mut companion, sheet, true), page != due);
        }
        assert!(
            companion
                .store
                .is_due(companion.store.sheet_id_of(due).unwrap())
        );
        assert!(
            !companion
                .store
                .is_due(companion.store.sheet_id_of(live).unwrap())
        );

        // A page closed with its ops still queued owes its marker a rotation
        // once the view is current, and its ops never reach a seal.
        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        assert!(
            companion
                .store
                .discard_page(companion.store.sheet_id_of(gone).unwrap())
        );
        sweep_outbound(&mut companion, 2_000, &mut events);
        drain_nothing(&mut companion);
        sweep_outbound(&mut companion, 4_000, &mut events);

        let engine = companion.sync.engine.as_ref().unwrap();
        let gone = crate::sync_session::page_wire_id(gone);
        assert!(
            !engine
                .session
                .queued()
                .iter()
                .any(|e| matches!(e, DeltaEnvelope::Ops { page, .. } if *page == gone))
        );
        assert_eq!(engine.chain.epoch(), 1, "the marker's rotation happened");
        let wire = crate::sync_session::page_wire_id(live);
        assert!(
            events
                .iter()
                .any(|event| event["kind"] == "ceremony_committed" && event["page"] == wire)
        );
    }

    fn mailbox_response(messages: &[serde_json::Value], next_seq: u64) -> HttpResponse {
        HttpResponse {
            status: 200,
            body: serde_json::json!({ "messages": messages, "next_seq": next_seq })
                .to_string()
                .into_bytes(),
        }
    }

    fn take_outgoing(companion: &mut Companion) -> Vec<serde_json::Value> {
        std::mem::take(&mut companion.sync.pairing.as_mut().unwrap().outgoing)
    }

    fn stage_of(companion: &Companion) -> serde_json::Value {
        stage_json(companion.sync.pairing.as_ref().unwrap())
    }

    /// The shell's poll loop in miniature: post what is queued, and stop
    /// for good at `done` or `failed`, as `SyncController.swift` does.
    fn poll_round(companion: &mut Companion) -> Vec<serde_json::Value> {
        let stage = stage_of(companion);
        if stage["stage"] == "done" || stage["stage"] == "failed" {
            return Vec::new();
        }
        take_outgoing(companion)
    }

    #[test]
    fn two_devices_pair_over_the_mailbox_and_the_grant_lands() {
        let creds_a: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let creds_b: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut a = store_companion(Arc::clone(&creds_a));
        let mut b = store_companion(Arc::clone(&creds_b));
        a.sync.engine = Some(attached_engine(&*creds_a));
        // B attached before pairing and founded a secret of its own —
        // the grant must overwrite it and re-root B's chain.
        b.sync.engine = Some(attached_engine(&*creds_b));
        let founded_b = pairing::ensure_channel_secret(&*creds_b, false).unwrap();

        invite_begin(&mut a).unwrap();
        join_begin(&mut b).unwrap();

        // Commitment → offer → reveal, through the mailbox shapes.
        let posts = take_outgoing(&mut a);
        absorb_mailbox(&mut b, &mailbox_response(&posts, 1));
        let posts = take_outgoing(&mut b);
        absorb_mailbox(&mut a, &mailbox_response(&posts, 2));
        let posts = take_outgoing(&mut a);
        absorb_mailbox(&mut b, &mailbox_response(&posts, 3));

        // One string on both screens.
        let stage_a = stage_of(&a);
        let stage_b = stage_of(&b);
        assert_eq!(stage_a["stage"], "sas");
        assert_eq!(stage_b["stage"], "sas");
        assert_eq!(stage_a["sas"], stage_b["sas"]);

        // The joiner's human confirms; its acceptance crosses; the
        // inviter's human confirms; the grant crosses.
        pairing_confirm(&mut b, true);
        let posts = take_outgoing(&mut b);
        absorb_mailbox(&mut a, &mailbox_response(&posts, 4));
        pairing_confirm(&mut a, true);
        assert_eq!(
            stage_of(&a)["stage"],
            "confirmed",
            "the grant is queued but unposted; the ceremony is not over"
        );
        let posts = take_outgoing(&mut a);
        assert_eq!(stage_of(&a)["stage"], "done", "and once it is out, it is");
        absorb_mailbox(&mut b, &mailbox_response(&posts, 5));
        assert_eq!(stage_of(&b)["stage"], "done");

        // The grant delivered A's secret over B's founded one, and
        // both sides recorded each other.
        let secret_a = pairing::ensure_channel_secret(&*creds_a, false).unwrap();
        let secret_b = pairing::ensure_channel_secret(&*creds_b, false).unwrap();
        assert_eq!(*secret_a, *secret_b);
        assert_ne!(*secret_b, *founded_b);
        let fp_a = pairing::device_fingerprint(&*creds_a).unwrap();
        let fp_b = pairing::device_fingerprint(&*creds_b).unwrap();
        assert!(
            pairing::peer_records(&*creds_a)
                .iter()
                .any(|record| record.fingerprint == fp_b)
        );
        assert!(
            pairing::peer_records(&*creds_b)
                .iter()
                .any(|record| record.fingerprint == fp_a)
        );
        // B's chain re-rooted from the delivered secret: it opens what
        // A seals.
        let sealed = a
            .sync
            .engine
            .as_ref()
            .unwrap()
            .chain
            .seal(b"hello")
            .unwrap();
        let opened = b.sync.engine.as_ref().unwrap().chain.open(&sealed).unwrap();
        assert_eq!(opened.as_slice(), b"hello");
    }

    #[test]
    fn a_confirmation_that_queues_the_grant_does_not_report_done() {
        let creds_a: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let creds_b: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut a = store_companion(Arc::clone(&creds_a));
        let mut b = store_companion(Arc::clone(&creds_b));
        a.sync.engine = Some(attached_engine(&*creds_a));
        b.sync.engine = Some(attached_engine(&*creds_b));
        invite_begin(&mut a).unwrap();
        join_begin(&mut b).unwrap();
        let posts = poll_round(&mut a);
        absorb_mailbox(&mut b, &mailbox_response(&posts, 1));
        let posts = poll_round(&mut b);
        absorb_mailbox(&mut a, &mailbox_response(&posts, 2));
        let posts = poll_round(&mut a);
        absorb_mailbox(&mut b, &mailbox_response(&posts, 3));

        // The acceptance arrives first, so the inviter's tap queues the
        // grant.
        pairing_confirm(&mut b, true);
        let posts = poll_round(&mut b);
        absorb_mailbox(&mut a, &mailbox_response(&posts, 4));
        let stage = pairing_confirm(&mut a, true);
        assert!(
            !a.sync.pairing.as_ref().unwrap().outgoing.is_empty(),
            "the grant is queued"
        );
        assert_eq!(
            stage["stage"], "confirmed",
            "a queued grant is a post still owed, never a finished ceremony"
        );
    }

    #[test]
    fn the_grant_leaves_the_inviter_when_the_shell_polls_by_the_stage_word() {
        let creds_a: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let creds_b: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut a = store_companion(Arc::clone(&creds_a));
        let mut b = store_companion(Arc::clone(&creds_b));
        a.sync.engine = Some(attached_engine(&*creds_a));
        b.sync.engine = Some(attached_engine(&*creds_b));
        invite_begin(&mut a).unwrap();
        join_begin(&mut b).unwrap();

        // Every post rides a round the stage word had to permit.
        let posts = poll_round(&mut a);
        absorb_mailbox(&mut b, &mailbox_response(&posts, 1));
        let posts = poll_round(&mut b);
        absorb_mailbox(&mut a, &mailbox_response(&posts, 2));
        let posts = poll_round(&mut a);
        absorb_mailbox(&mut b, &mailbox_response(&posts, 3));

        // The tap comes first, so the acceptance's arrival queues it.
        pairing_confirm(&mut a, true);
        pairing_confirm(&mut b, true);
        let posts = poll_round(&mut b);
        absorb_mailbox(&mut a, &mailbox_response(&posts, 4));

        let posts = poll_round(&mut a);
        assert!(!posts.is_empty(), "the grant must still get a round");
        absorb_mailbox(&mut b, &mailbox_response(&posts, 5));
        assert_eq!(stage_of(&a)["stage"], "done");
        assert_eq!(stage_of(&b)["stage"], "done");
        let secret_a = pairing::ensure_channel_secret(&*creds_a, false).unwrap();
        let secret_b = pairing::ensure_channel_secret(&*creds_b, false).unwrap();
        assert_eq!(*secret_a, *secret_b, "both devices hold one channel");
    }

    #[test]
    fn a_failed_comparison_aborts_with_nothing_recorded() {
        let creds_a: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let creds_b: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut a = store_companion(Arc::clone(&creds_a));
        let mut b = store_companion(Arc::clone(&creds_b));
        a.sync.engine = Some(attached_engine(&*creds_a));
        b.sync.engine = Some(attached_engine(&*creds_b));
        invite_begin(&mut a).unwrap();
        join_begin(&mut b).unwrap();
        let posts = take_outgoing(&mut a);
        absorb_mailbox(&mut b, &mailbox_response(&posts, 1));
        let posts = take_outgoing(&mut b);
        absorb_mailbox(&mut a, &mailbox_response(&posts, 2));
        let posts = take_outgoing(&mut a);
        absorb_mailbox(&mut b, &mailbox_response(&posts, 3));

        let refused = pairing_confirm(&mut b, false);
        assert_eq!(refused["stage"], "failed");
        assert!(b.sync.pairing.is_none(), "the ceremony is gone whole");
        assert!(pairing::peer_records(&*creds_b).is_empty());
        assert!(pairing::peer_records(&*creds_a).is_empty());
    }

    #[test]
    fn the_device_list_tells_verified_from_attached() {
        let credentials: Arc<dyn CredentialStore> = Arc::new(InMemoryCredentialStore::default());
        let mut companion = store_companion(Arc::clone(&credentials));
        companion.sync.engine = Some(attached_engine(&*credentials));
        assert!(pairing::record_peer(
            &*credentials,
            b"peer identity",
            "laptop",
            1_000
        ));
        let paired_fp = pairing::identity_fingerprint(b"peer identity");
        // The roster reports the paired peer attached, plus a stranger
        // that attached with a token but never paired.
        let package = serde_json::to_value(companion_sync::ByteBlob(vec![1; 96])).unwrap();
        let body = serde_json::json!({
            "epoch": 0, "frame_present": false, "next_seq": 0,
            "peers": [
                {"device": paired_fp, "key_package": package, "attached_ms": 5_000},
                {"device": "stranger", "key_package": package, "attached_ms": 6_000},
            ],
        });
        companion
            .sync
            .engine
            .as_mut()
            .unwrap()
            .session
            .absorb_attach(&HttpResponse {
                status: 200,
                body: body.to_string().into_bytes(),
            })
            .unwrap();

        let devices = devices_json(&companion);
        let devices = devices["devices"].as_array().unwrap();
        let own = devices.iter().find(|d| d["this_device"] == true).unwrap();
        assert_eq!(own["verified"], true);
        let paired = devices
            .iter()
            .find(|d| d["fingerprint"] == paired_fp.as_str())
            .unwrap();
        assert_eq!(paired["verified"], true);
        assert_eq!(paired["label"], "laptop");
        assert_eq!(paired["attached_ms"], 5_000);
        let stranger = devices
            .iter()
            .find(|d| d["fingerprint"] == "stranger")
            .unwrap();
        assert_eq!(stranger["verified"], false);
        assert_eq!(stranger["attached_ms"], 6_000);
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
