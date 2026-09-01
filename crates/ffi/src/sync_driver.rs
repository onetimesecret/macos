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

use std::collections::BTreeMap;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use companion_core::{HoldRegister, ItemId, SheetId};
use companion_credentials::CredentialStore;
use companion_sync::TokenKeeper;
use companion_sync::loopback::OneShotListener;
use companion_sync::oauth::{AuthCeremony, SyncAuthError, TokenGrant, parse_token_response};
use companion_sync::relay::RelayRefusal;
use ots_client::{HttpResponse, Transport};
use ring::signature::Ed25519KeyPair;
use zeroize::Zeroizing;

use crate::diagnostics::diag_fault;
use crate::gop::GopKeyChain;
use crate::pairing::{self, MailboxMessage};
use crate::sync_gate::{GateFault, GateInputs, SyncGate, gate};
use crate::sync_session::{KeyPackageKeeper, SyncEvent, SyncSession, sheet_of};
use crate::{Companion, CompanionHandle};

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
pub(crate) struct SyncState {
    /// Endpoints and client id; `None` until the shell configures.
    pub config: Option<SyncConfig>,
    /// The token keeper, built at configure from the persisted refresh
    /// token — a relaunch resumes signed in without a browser. Moves
    /// into the session at attach and comes back at detach.
    pub keeper: Option<TokenKeeper>,
    /// A sign-in ceremony begun and not yet finished: the PKCE state
    /// and the bound listener, waiting for the finish call to take
    /// them off-lock and block on the redirect.
    pub pending_signin: Option<PendingSignin>,
    /// A finish call holding that ceremony off-lock, blocked on the
    /// browser's one redirect. The ceremony is out of the state above
    /// for as long as this stands, so without it the minutes a user
    /// spends on a consent screen would read as signed out, which is a
    /// state the app has already left (ADR-0027 §5).
    pub awaiting_redirect: bool,
    /// The attached engine: session, chain, and key packages. `None`
    /// while sync is off or detached.
    pub engine: Option<EngineState>,
    /// The pages the user shares to this channel, with the cursor and
    /// last-published policy state per page. Enrolment is per page and
    /// off by default (relay protocol §1).
    pub enrolled: BTreeMap<ItemId, PageTracking>,
    /// A pairing ceremony in flight over the relay mailbox.
    pub pairing: Option<PairingState>,
    /// What the last attempt to use the account credential met, which
    /// is what tells a server that said no from a server that said
    /// nothing (ADR-0027 §5). In memory only, and cleared by any round
    /// trip that succeeds.
    pub fault: Option<GateFault>,
    /// What the publish batch now in flight carries: each enrolled
    /// page's export cursor as it stood when the batch was sealed. The
    /// answer, whenever it comes, advances the acknowledged cursors to
    /// these and to nothing later.
    pub staged_batch: Option<StagedBatch>,
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
            awaiting_redirect: false,
            engine: None,
            enrolled: BTreeMap::new(),
            pairing: None,
            fault: None,
            staged_batch: None,
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
    /// The frontier the relay has acknowledged carrying. The export
    /// cursor above moves when ops are *queued*, which is before they
    /// are sent, so this is the position a dissolving engine rewinds
    /// to: an edit queued into a session that died before its publish
    /// would otherwise sit behind a cursor that moved without it, and
    /// no later export would ever reach it (ADR-0027 §7, tenet 1).
    pub acked: Vec<u8>,
    /// The deadline the last published expiry policy named.
    pub deadline_wall_ms: Option<u64>,
    /// The hold register as last published.
    pub hold: Option<HoldRegister>,
    /// Whether this device already published the page's terminal
    /// marker.
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

/// A publish batch in flight, and the cursors it carries: one entry
/// per page enrolled when the batch was sealed. Pages enrolled after
/// the seal are simply absent, which is right, since the batch carries
/// nothing of theirs.
pub(crate) struct StagedBatch {
    /// The session's own name for the batch
    /// ([`SyncSession::in_flight_batch`]), so a resend is recognized
    /// as the same one rather than recorded afresh.
    pub id: u64,
    pub cursors: BTreeMap<ItemId, Vec<u8>>,
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

// ---------------------------------------------------------------------
// The engine driver (issue #102): enrolment, attach, and the pump
// ---------------------------------------------------------------------

/// Tolerance under which a re-read expiry deadline counts as the one
/// already published: `anchor + remaining` is constant while nothing
/// touches the page, modulo the milliseconds the two clock reads
/// straddle.
const DEADLINE_JITTER_MS: u64 = 1_000;

/// Unix epoch milliseconds, for the wall stamps peers read (pairing
/// times, terminal markers). Never an input to expiry math — that
/// stays the store's clock discipline.
fn wall_now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| {
            u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
        })
}

/// Enrol a page into the channel, or withdraw it. Enrolling defers
/// its compaction to the coordinated ceremony and starts its cursor
/// at the pristine frontier, so the first publish carries the whole
/// page; withdrawing returns it to solo behaviour, performing any due
/// ceremony on the spot (`SheetStore::set_compaction_deferred`).
pub(crate) fn enrol_page(companion: &mut Companion, sheet: SheetId, enrolled: bool) -> bool {
    let Some(page) = companion
        .store
        .sheet(sheet)
        .map(companion_core::Sheet::uuid)
    else {
        return false;
    };
    if enrolled {
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

/// Attach to the channel, building the engine if none stands:
/// identity and channel secret ensured (the first device to enable
/// sync founds the channel; a joiner's secret arrives by pairing and
/// overwrites), a fresh key package minted and published. Blocking —
/// the caller runs it off the main thread. Re-attaching with an
/// engine standing keeps the session and chain and republishes a
/// fresh package, which is the move after a ceremony spends one.
pub(crate) fn attach(handle: &CompanionHandle) -> serde_json::Value {
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
            engine
                .session
                .attach_request(&engine.packages.package().clone())
                .zip(transport)
        };
        let Some((request, transport)) = staged else {
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
            // A second 401 on the same attach, with a token refreshed
            // in between: the account is refusing this client rather
            // than the token merely having aged out.
            Err(RelayRefusal::Unauthorized) => {
                note_fault(&mut guard, GateFault::Refused);
                return serde_json::json!({ "ok": false, "reason": "signed_out" });
            }
            Err(_) => return serde_json::json!({ "ok": false, "reason": "refused" }),
        }
    }
    serde_json::json!({ "ok": false, "reason": "refused" })
}

/// Detach: tell the relay (best effort — attachments age out
/// regardless, §3) and dissolve the engine, handing the keeper back
/// so the sign-in survives. Blocking for the one round-trip.
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

/// Build the engine if none stands. Requires configuration and a
/// sign-in; mints what pairing has not delivered — the founder path.
fn ensure_engine(handle: &CompanionHandle) -> Result<(), Refusal> {
    let Ok(mut guard) = handle.inner.lock() else {
        return Err("poisoned");
    };
    let Some(config) = &guard.sync.config else {
        return Err("not_configured");
    };
    let relay_url = config.relay_url.clone();
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
        // Re-attach: fresh package, standing session and chain.
        engine.packages = packages;
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
        unpublished_frame: None,
    });
    Ok(())
}

/// Make sure an access token is held, refreshing over the wire if
/// not. `Err("signed_out")` performs the sign-out: the persisted
/// refresh token is deleted and the engine dissolved, because a
/// refused refresh means re-enrolment is the only way back
/// (account-auth.md §2).
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
    let Ok(response) = transport.send(request) else {
        if let Ok(mut guard) = handle.inner.lock() {
            note_fault(&mut guard, GateFault::Unreachable);
        }
        return Err("unreachable");
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return Err("poisoned");
    };
    let Some(engine) = guard.sync.engine.as_mut() else {
        return Err("not_attached");
    };
    match engine.session.absorb_refresh(&response) {
        // A rotation is a new durable secret and has to land before it
        // is used; a server that declined to rotate leaves the resting
        // token correct, so there is nothing to write and no reason to
        // touch the keychain (ADR-0027 §2).
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
        // The token endpoint being unwell (a 5xx, a mangled body) is
        // not the grant being revoked: the refresh token stands and
        // the next pump retries, exactly as an unreachable host would.
        Err(_) => {
            note_fault(&mut guard, GateFault::Unreachable);
            Err("unreachable")
        }
    }
}

/// The sign-out that a refused refresh performs: delete the persisted
/// token, dissolve the engine, and leave a signed-out keeper so
/// status tells the truth. The pad is unaffected.
fn sign_out_locked(companion: &mut Companion) {
    let _ = clear_refresh(&*companion.credentials);
    // The dissolve rewinds what the relay never acknowledged, so the
    // account's refusal costs the peers a delay and never an edit.
    let _ = dissolve_engine(companion);
    companion.sync.fault = Some(GateFault::Refused);
    if let Some(config) = &companion.sync.config {
        companion.sync.keeper = Some(TokenKeeper::new(&config.token_url, &config.client_id, None));
    }
}

/// One outbound sweep over the enrolled pages, under the lock and off
/// the network: queue fresh document deltas past each cursor, the
/// expiry policy when its deadline moved (the sum is constant while
/// nothing touches the page, so a move is a gesture), the hold
/// register when it changed, and the terminal marker once for a page
/// that died here. A due ceremony — a deferred rung transition, or
/// the proposal a terminal marker owes (§5) — rotates the channel:
/// a ballot to the verified attached peers, or solo when the room is
/// empty.
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
        engine, enrolled, ..
    } = sync;
    let Some(engine) = engine.as_mut() else {
        return;
    };
    let mut rotate = false;
    let mut due_target: Option<ItemId> = None;
    let mut fallback: Option<ItemId> = None;
    for (page, tracking) in enrolled.iter_mut() {
        match sheet_of(store, *page) {
            Some(sheet) => {
                if let Some(version) = store.document_version(sheet)
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
                // A page whose transition waits on its ceremony is
                // the rotation's target, whatever order the map walks
                // — a live page without one is only the fallback
                // anchor for the rotation a terminal marker owes.
                if store.ceremony_due(sheet) {
                    rotate = true;
                    due_target = due_target.or(Some(*page));
                } else {
                    fallback = fallback.or(Some(*page));
                }
            }
            None => {
                // The page died here. Publish its signed terminal
                // marker once — the gate refuses until this device's
                // view is current with the channel, and while a hold
                // stands elsewhere — then propose the ceremony §5 says
                // follows a marker, so the dead page's ciphertext
                // stops opening at the earliest boundary.
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
        && let Some(target) = due_target.or(fallback)
        && rotate_channel(store, engine, &**credentials, target, now_ms, events)
    {
        settle_frontier(store, enrolled, target);
    }
}

/// Whether a re-read hold register is a new fact rather than the one
/// already published. Any change of shape or substance counts, but
/// `until_wall_ms` — recomputed as wall-now-plus-remaining on every
/// read — is allowed the same clock-straddle jitter the expiry
/// deadline is, or a held page would republish its hold every sweep.
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

/// Move a page's export cursor to its document's own current version
/// without exporting anything: the move after a ceremony compacts the
/// page. The rebuilt body travels as the sealed key frame, never as a
/// delta — an export from the stale cursor would name peers the
/// rebuilt document has never heard of and so republish the whole
/// body, which a peer holding its own rebuild would merge as a second
/// copy of the text rather than recognize as its own.
fn settle_frontier(
    store: &companion_core::SheetStore<companion_core::SystemClock>,
    enrolled: &mut BTreeMap<ItemId, PageTracking>,
    page: ItemId,
) {
    if let Some(tracking) = enrolled.get_mut(&page)
        && let Some(sheet) = sheet_of(store, page)
        && let Some(version) = store.document_version(sheet)
    {
        tracking.frontier = version.clone();
        // The acknowledged cursor settles with it, or a later rewind
        // would land before the rebuild and republish the whole body
        // as the duplicate this settling exists to prevent.
        tracking.acked = version;
    }
}

/// Build the publish request and record what its batch carries, in one
/// act. The recording is the whole point: a batch sealed in one pump
/// and answered in a later one is resent verbatim
/// (`SyncSession::publish_request` borrows the outbox only when
/// nothing is already in flight), so by the time the relay accepts it
/// the live cursors may have run on past it. Advancing to the live
/// cursor would then mark ops acknowledged that the relay was never
/// offered, and the next dissolve would rewind to a position past
/// them, which is the loss the rewind exists to prevent.
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
        // A batch this call sealed: what it carries is each page's
        // cursor as it stands right now, before any later sweep.
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

/// Absorb a publish answer under the lock, and on acceptance advance
/// each enrolled page's acknowledged cursor to the position the batch
/// the relay just took actually carried, never to wherever the live
/// cursor has since reached. Acknowledgement and advance are one act
/// on purpose: two call sites doing it separately is two chances for a
/// cursor to move past ops nobody received.
///
/// A refusal that drops the batch drops the record with it, leaving
/// the acknowledged cursor where it was, so the ops the dropped batch
/// held are exported again after the next dissolve. Restating is
/// cheap and idempotent; losing is neither.
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

/// Dissolve the engine, handing back the keeper it held, and rewind
/// every enrolled page to what the relay actually acknowledged.
///
/// Whatever was queued into the dying session and never sent goes back
/// on the books: the document ops by way of the rewound cursor, and
/// the policy, hold and terminal facts by way of forgetting what was
/// last published, so the next sweep states them again. Restating a
/// fact a peer already holds is idempotent; dropping one is not, and
/// tenet 1 does not stop at the sync boundary.
pub(crate) fn dissolve_engine(companion: &mut Companion) -> Option<TokenKeeper> {
    // The batch dies with the session that sealed it, and so does the
    // record of what it carried.
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

/// Rotate the channel at `target`: a ballot to the verified attached
/// peers when any are in the room, the solo one-event otherwise. The
/// attach roster admits nobody without a pairing record
/// ([`SyncSession::ceremony_peers`]), so a revoked device is left
/// behind by construction. True when the ceremony committed on the
/// spot — the solo path, whose caller owes the page a settled cursor.
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
    if peers.is_empty() {
        if engine
            .session
            .solo_ceremony(target, store, &mut engine.chain)
        {
            events.push(serde_json::json!({ "kind": "ceremony_committed", "page": page }));
            return true;
        }
    } else {
        let own = engine.packages.package().clone();
        if engine
            .session
            .propose_ceremony(target, &peers, &own, now_ms)
        {
            events.push(serde_json::json!({ "kind": "ceremony_proposed", "page": page }));
        }
    }
    false
}

/// A terminal marker this device may publish: the page id and the
/// wall stamp, signed by the device identity — the seam owns the
/// signature, the core owns the claim (`companion_core::TerminalMarker`).
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

/// One pump: the engine loop's whole body, run from a background
/// queue on the shell's cadence. Sweeps the enrolled pages, publishes
/// what the 2-second clock owes, long-polls the delta stream for up
/// to `wait_seconds`, walks the ballot patience, and publishes a
/// committed ceremony's frame. Blocking for up to the whole
/// long-poll; the core mutex is held only between round-trips, so
/// the pad never waits on the network.
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
                // The relay answered, whatever it said: the gate's
                // account axis has nothing to report.
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
                        ..
                    } = engine;
                    match session.absorb_deltas(&response, store, chain, packages, &trusted, now) {
                        Ok(absorbed) => {
                            committed = absorbed
                                .iter()
                                .any(|event| matches!(event, SyncEvent::CeremonyCommitted(_)));
                            events.extend(absorbed.iter().map(event_json));
                            // A drained commit compacted the page here;
                            // its cursor settles so the rebuild travels
                            // only as the frame.
                            for event in &absorbed {
                                if let SyncEvent::CeremonyCommitted(page) = event {
                                    settle_frontier(store, &mut sync.enrolled, *page);
                                }
                            }
                        }
                        // A 401 here refreshes at the next pump's top.
                        Err(RelayRefusal::Unauthorized) => {}
                        Err(refusal) => events.push(refusal_json(&refusal)),
                    }
                }
            }
        }
    }

    // A committed ceremony spent the one-shot key package (on the
    // follower side) — republish a fresh one so the next proposal can
    // reach this device.
    if committed {
        let _ = attach(handle);
    }

    // A committed ceremony's frame supersedes at the relay: that
    // acceptance is the purge. Kept until a 2xx (or a 409 — a peer's
    // copy won, equally final) so a dropped round retries next pump.
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
            // The batch is still in flight; rebuild its request at the
            // now-refreshed auth and send the one retry §2 allows.
            let staged = {
                let Ok(mut guard) = handle.inner.lock() else {
                    return;
                };
                let now = guard.sync.now_ms();
                // The same batch, so the record of what it carries
                // stands: `stage_publish` recognizes the resend.
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
                // The §3 cap: nothing publishes until a ceremony
                // compacts, so rotate now rather than on the next
                // transition.
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
                    && let Some(target) = enrolled.keys().next().copied()
                {
                    rotate_channel(store, engine, &**credentials, target, now, events);
                }
            }
            events.push(refusal_json(&refusal));
        }
    }
}

fn event_json(event: &SyncEvent) -> serde_json::Value {
    let page = |page: &ItemId| crate::sync_session::page_wire_id(*page);
    match event {
        SyncEvent::Applied(id) => serde_json::json!({ "kind": "applied", "page": page(id) }),
        SyncEvent::CountdownMoved(id) => {
            serde_json::json!({ "kind": "countdown_moved", "page": page(id) })
        }
        SyncEvent::Terminal(id) => serde_json::json!({ "kind": "terminal", "page": page(id) }),
        SyncEvent::RejoinRequired => serde_json::json!({ "kind": "rejoin_required" }),
        SyncEvent::CeremonyCommitted(id) => {
            serde_json::json!({ "kind": "ceremony_committed", "page": page(id) })
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

/// Note that a round trip reached its host. That answers the network
/// question and only the network question: a refusal stands until the
/// user signs in again, because re-enrolment is the only way back from
/// one (ADR-0027 §2) and a reachable server is not a server that
/// changed its mind.
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

/// Forget every fault: the ceremony granted, the shell reconfigured,
/// or the user signed out on purpose. Each is a fresh start the last
/// refusal has nothing to say about.
pub(crate) fn clear_fault(companion: &mut Companion) {
    companion.sync.fault = None;
}

/// Where the account gate stands, as the one value the shell reads
/// (ADR-0027 §5). Existence checks and in-memory reads only, like
/// every other field of the status.
pub(crate) fn gate_of(companion: &Companion) -> SyncGate {
    let sync = &companion.sync;
    gate(GateInputs {
        configured: sync.config.is_some(),
        signin_pending: signin_in_flight(sync),
        credential: credential_rests(companion),
        fault: sync.fault,
        attached: sync
            .engine
            .as_ref()
            .is_some_and(|engine| engine.session.attached()),
    })
}

/// Whether a sign-in ceremony is in flight at all: minted and waiting
/// for its finish, or taken by a finish that is blocked on the
/// browser. The two are one state to anyone outside this module.
pub(crate) fn signin_in_flight(sync: &SyncState) -> bool {
    sync.pending_signin.is_some() || sync.awaiting_redirect
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

/// Sync's standing state: existence checks and in-memory reads only,
/// so rendering Settings never decrypts a credential or waits on the
/// network.
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

/// The device list: every peer a human verified here, joined with the
/// attach roster's times, plus this device and any attached-but-
/// unverified stranger — attach-list truth and pairing truth, each
/// labelled as what it is.
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
/// polls. One at a time — the mailbox holds one pairing, and so does
/// this.
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
    // A ceremony that still owes a post is not done, whatever the step
    // says. The shell stops polling at `done`, and the poll is the only
    // thing that drains the queue, so a grant reported done here would
    // sit in the queue forever and the other device would wait for it
    // just as long. `confirmed` is the honest word for the interval:
    // settled on this side, waiting on the other.
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

/// Advance the machine with one mailbox message. Unexpected kinds —
/// this device's own posts echoed back included — change nothing.
/// Returns whether a grant just landed (the joiner's chain must then
/// re-root from the delivered secret).
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
                Some(secret) if pairing::store_channel_secret(credentials, &secret) => {
                    let _ = pairing::record_peer(
                        credentials,
                        settled.peer_identity(),
                        "",
                        wall_now_ms(),
                    );
                    joined = true;
                    PairingStep::Done
                }
                _ => PairingStep::Failed("grant"),
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
    let Some(grant) = settled.grant(&secret) else {
        return PairingStep::Failed("keychain");
    };
    outgoing.push(MailboxMessage::Grant(grant).encode());
    let _ = pairing::record_peer(credentials, settled.peer_identity(), "", wall_now_ms());
    PairingStep::Done
}

/// The human's verdict on the SAS. A mismatch aborts the whole
/// ceremony — both sides walk away with nothing stored, which is the
/// property the pairing tests pin.
pub(crate) fn pairing_confirm(companion: &mut Companion, matched: bool) -> serde_json::Value {
    let Some(mut flow) = companion.sync.pairing.take() else {
        return serde_json::json!({ "stage": "idle" });
    };
    if !matched {
        // Dropped whole: the ceremony state, the queued posts, all of
        // it. The peer times out on its own patience.
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

/// Post the queued messages, one at a time, until the queue empties or
/// the wire declines; a transport failure leaves the rest queued for
/// the next poll. `Err` carries the stage the round should report
/// instead of going on.
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
                    // The head is removed only if it is still the
                    // message this round posted: the lock was released
                    // for the send, and a cancel, a fresh ceremony, or
                    // a concurrent poll may have moved the queue —
                    // blind removal would drop someone else's message
                    // or panic on an emptied one.
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

/// One mailbox round: drain the queued posts, fetch the tail, advance
/// the machine, and report the stage. Blocking for the round-trips —
/// background queue only. The shell polls this while its enrolment
/// sheet is open.
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
    // Advancing may have queued a post of its own — the grant the
    // inviter owes the moment the acceptance lands. Drain again so it
    // goes out in this same round rather than waiting on a next poll
    // that the reported stage might well talk the shell out of.
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

/// Absorb one mailbox answer: `{"messages": […], "next_seq"}` (§7's
/// answer shape), each entry one wire message; unknown shapes are
/// skipped, never guessed at. A grant landing re-roots the chain from
/// the delivered secret.
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
        // The delivered secret replaces whatever this device founded
        // for itself: the chain re-roots at epoch zero. That is the
        // whole story today — catching a joiner up to a channel that
        // has already rotated is ADR-0021 Amendment 1's welcome, not
        // yet built on either side of the wire — so a joiner landing
        // on a rotated channel sees rejoin_required, honestly.
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

    fn store_companion(credentials: Arc<dyn CredentialStore>) -> Companion {
        Companion {
            store: companion_core::SheetStore::new(companion_core::SystemClock),
            pasteboard: crate::Board::Memory(companion_pasteboard::MemoryPasteboard::new()),
            last_write: None,
            connection: None,
            credentials,
            sync: SyncState::default(),
        }
    }

    fn attached_engine(credentials: &dyn CredentialStore) -> EngineState {
        let pkcs8 = pairing::ensure_device_identity(credentials).unwrap();
        let secret = pairing::ensure_channel_secret(credentials, true).unwrap();
        let mut keeper = TokenKeeper::new("https://eu.example/oauth/token", "companion", None);
        let _ = keeper.absorb(TokenGrant {
            access: Zeroizing::new("at".into()),
            refresh: Zeroizing::new("rt".into()),
        });
        EngineState {
            session: SyncSession::new(
                "https://relay.example",
                keeper,
                &pairing::device_fingerprint(credentials).unwrap(),
            ),
            chain: GopKeyChain::root(&secret).unwrap(),
            packages: KeyPackageKeeper::mint(&pkcs8).unwrap(),
            unpublished_frame: None,
        }
    }

    fn inked_page(companion: &mut Companion, text: &str) -> SheetId {
        let page = companion.store.new_tab().unwrap().1;
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

        // Signed in again and attached again: the edit that was queued
        // and never sent is owed again, rather than sitting behind a
        // cursor that moved without it (ADR-0027 §7).
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
        assert!(companion.store.new_tab().is_ok());
        assert_eq!(*credentials.load("api-token").unwrap(), b"conceal-token");
        assert_eq!(
            *crate::persist::load_ledger_key(&*credentials).unwrap(),
            *ledger
        );
        assert!(!signed_in(&*credentials), "the sync account alone is gone");
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

        // The snapshot is what the state file seals. A credential in it
        // would rest under the rotating content key, which ADR-0027 §4
        // refuses: a rotation would sign the user out, and a copied
        // state file would carry the account with it.
        let snapshot = companion.store.snapshot(1_700_000_000_000);
        let contains = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
        assert!(
            !contains(&snapshot, secret.as_bytes()),
            "the refresh token has no business in the content store"
        );
        // It rests in the key material tier instead, which is where
        // the ledger key and the keychain content half rest. The
        // in-memory store under test answers both tiers with one map,
        // so this pins the account the driver reads and writes, and the
        // tier split is the real store's own (`key_material_store`).
        assert!(load_refresh(&*credentials).is_some());
        assert!(
            credentials
                .key_material_store()
                .exists(SYNC_REFRESH_ACCOUNT)
                .unwrap_or(false)
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

        // Pump two: a second edit sweeps to V2 and queues behind the
        // batch, which is resent verbatim and accepted. Only V1 ever
        // reached the relay, so only V1 may count as acknowledged.
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

        // The refused refresh that follows dissolves the engine, and
        // the second edit has to survive it: it is in no batch the
        // relay ever answered.
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

        // The re-attached sweep restates the expiry and hold facts,
        // which are idempotent, and owes the peers no text: an
        // acknowledged body republished from a stale cursor is the
        // duplicate merge the settled cursor exists to prevent.
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

        // The rebuilt body travels only as that frame. The cursor
        // settled at the rebuilt document's own version, so once the
        // pre-ceremony batch drains, the next sweep owes nothing — an
        // unsettled cursor would republish the whole rebuild as a
        // delta, which a peer holding its own rebuild would merge as
        // a second copy of the text.
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
        let (tab_a, page_a) = companion.store.new_tab().unwrap();
        let (tab_b, page_b) = companion.store.new_tab().unwrap();
        for page in [page_a, page_b] {
            assert!(companion.store.apply_ops(
                page,
                &[companion_core::EditOp::Insert {
                    pos_u16: 0,
                    text: "ink".into(),
                }],
            ));
        }
        // Make the due page the one the enrolment map iterates last,
        // so an order-blind target would have settled on the calm
        // page and compacted the wrong one, looping the rotation.
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

        // The first sweep keeps quiet: the channel view is not
        // current, and a device that has drained nothing may not kill
        // a page for everyone.
        let mut events = Vec::new();
        sweep_outbound(&mut companion, 0, &mut events);
        let engine = companion.sync.engine.as_mut().unwrap();
        assert!(!engine.session.publish_due(0), "the gate held");

        // One drain — even empty — makes the view current; the next
        // sweep publishes the marker and asks for the ceremony §5
        // owes. With an empty room, that rotation has no live page to
        // compact, so the epoch stands until one exists.
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
                ..
            } = engine;
            session
                .absorb_deltas(&empty, store, chain, packages, &[], 0)
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

    /// The shell's poll loop in miniature: a round posts whatever the
    /// ceremony has queued, and the shell stops its timer for good
    /// once the stage reads `done` or `failed`
    /// (`SyncController.swift`). Tests that reach past the stage word
    /// and drain `outgoing` by hand cannot see a post stranded behind
    /// a premature `done`, which is the whole failure this models.
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

        // The joiner's acceptance arrives first, so the inviter's tap
        // on Match queues the grant in the same breath as it settles
        // the step.
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

        // This time the inviter's human confirms before the acceptance
        // travels, so it is the acceptance's arrival mid-round — not
        // the tap — that queues the grant.
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
