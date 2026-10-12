//! The sync session: the sans-IO engine joining the delta seam, the
//! ballot machine ([`companion_core::PageChannel`]), the GOP chain
//! ([`crate::gop`]) and the key packages to `companion-sync`'s wire
//! shapes (issues #98 and #99). Every method builds an
//! [`ots_client::HttpRequest`] or absorbs an [`ots_client::HttpResponse`],
//! so every path runs offline in the tests. Rules: client protocol §3
//! to §7.

use std::collections::HashMap;

use companion_core::{
    Clock, DeltaAdmission, ExpiryPolicy, HoldRegister, ItemId, PageChannel, SheetId, SheetStore,
};
use companion_sync::relay::{FrameAnswer, PeerAttachment, RelayApi, RelayRefusal};
use companion_sync::{ByteBlob, ControlPayload, DeltaEnvelope, TokenKeeper, pad};
use ots_client::{BearerAuth, HttpRequest, HttpResponse};
use ring::hkdf::{HKDF_SHA256, Salt};
use ring::rand::{SecureRandom as _, SystemRandom};
use ring::signature::{ED25519, Ed25519KeyPair, UnparsedPublicKey};
use ring::{agreement, digest};
use zeroize::Zeroizing;

use crate::persist::{self, Bytes, KEY_LEN};

/// §8's publish clock: publish at most this often, coalescing
/// everything since the last publish. Batching on a clock, never on
/// commit boundaries, so the relay sees 2-second grain instead of
/// typing rhythm (ADR-0021 §4).
pub const PUBLISH_INTERVAL_MS: u64 = 2_000;

/// §8's long-poll patience, inside ordinary load-balancer idle
/// timeouts. Also the most a fetch asks for: the transport's first-byte
/// patience is sized past it, so a longer `wait` would time out every
/// quiet poll, and [`SyncSession::fetch_request`] holds it here.
pub const LONG_POLL_WAIT_S: u32 = 25;

/// §5's ballot patience: a ceremony not confirmed within this window
/// is abandoned, every device staying on the old GOP.
pub const BALLOT_PATIENCE_MS: u64 = 60_000;

/// Versioned signing context for key packages (client protocol
/// Appendix A): the identity key signs `context ‖ x25519_pub`, never
/// the bare 32 bytes, which share a pairing transcript hash's shape.
const KEY_PACKAGE_SIGN_CONTEXT: &[u8] = b"ots-companion-key-package-v1";

/// Versioned signing context for terminal markers: the identity key
/// signs `context ‖ page_id ‖ wall_ms`, one role among the several
/// the one key serves.
pub(crate) const TERMINAL_SIGN_CONTEXT: &[u8] = b"ots-companion-terminal-v1";

/// Versioned HKDF info string for entropy sealed to a key package.
const ENTROPY_WRAP_INFO: &[u8] = b"ots-companion-entropy-wrap-v1";

/// Magic + version authenticated into a sealed entropy envelope.
const ENTROPY_MAGIC: &[u8; 8] = b"OTSENTR1";

// ---------------------------------------------------------------------
// Key packages (relay-protocol.md §6)
// ---------------------------------------------------------------------

/// A device's key package: a one-shot X25519 public key signed by its
/// Ed25519 identity key. Public material. Wire form
/// `x25519_pub(32) ‖ signature(64)` (client protocol §5.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyPackage {
    x25519_pub: Vec<u8>,
    signature: Vec<u8>,
}

impl KeyPackage {
    /// Parse the wire form. `None` for anything the wrong size.
    #[must_use]
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        (bytes.len() == 32 + 64).then(|| Self {
            x25519_pub: bytes[..32].to_vec(),
            signature: bytes[32..].to_vec(),
        })
    }

    /// The wire form, for `POST /channel/attach`.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(32 + 64);
        out.extend_from_slice(&self.x25519_pub);
        out.extend_from_slice(&self.signature);
        out
    }

    /// Verify the signature against a peer's Ed25519 identity public
    /// key, taken from the pairing record — the check that makes a
    /// relay substituting a key package win only ciphertext nobody
    /// will open (§6).
    #[must_use]
    pub fn verify(&self, identity_pub: &[u8]) -> bool {
        UnparsedPublicKey::new(&ED25519, identity_pub)
            .verify(
                &persist::signing_domain(KEY_PACKAGE_SIGN_CONTEXT, &self.x25519_pub),
                &self.signature,
            )
            .is_ok()
    }

    /// Seal ceremony entropy to this package: ephemeral X25519 against
    /// its key, HKDF to an AEAD key, the versioned magic as associated
    /// data. Wire form `eph_pub(32) ‖ aead body` (client protocol §5.1).
    #[must_use]
    pub fn seal_entropy(&self, entropy: &[u8]) -> Option<Vec<u8>> {
        let rng = SystemRandom::new();
        let eph = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng).ok()?;
        let eph_pub = eph.compute_public_key().ok()?;
        let peer = agreement::UnparsedPublicKey::new(&agreement::X25519, &self.x25519_pub);
        let wrap_key = agreement::agree_ephemeral(eph, &peer, wrap_key_from).ok()??;
        let body = persist::seal_body(&wrap_key, ENTROPY_MAGIC, entropy)?;
        let mut sealed = Vec::with_capacity(32 + body.len());
        sealed.extend_from_slice(eph_pub.as_ref());
        sealed.extend_from_slice(&body);
        Some(sealed)
    }
}

fn wrap_key_from(shared: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let prk = Salt::new(HKDF_SHA256, ENTROPY_WRAP_INFO).extract(shared);
    let okm = prk.expand(&[ENTROPY_WRAP_INFO], Bytes(KEY_LEN)).ok()?;
    let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
    okm.fill(&mut key).ok()?;
    Some(key)
}

/// The private half of this device's current key package: one-shot
/// (ring's X25519 keys agree once and are consumed) and never
/// persisted. Lifecycle: client protocol §5.2.
pub struct KeyPackageKeeper {
    private: Option<agreement::EphemeralPrivateKey>,
    package: KeyPackage,
    /// Whether the relay accepted an attach carrying this package; a
    /// mint is not a publication (client protocol §5.2).
    published: bool,
}

impl KeyPackageKeeper {
    /// Mint a fresh one-shot X25519 key and sign it with the device
    /// identity (`pairing.rs`'s PKCS#8 Ed25519 key). `None` when the RNG
    /// or the identity key refuses.
    #[must_use]
    pub fn mint(identity_pkcs8: &[u8]) -> Option<Self> {
        let rng = SystemRandom::new();
        let private = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng).ok()?;
        let x25519_pub = private.compute_public_key().ok()?.as_ref().to_vec();
        let identity = Ed25519KeyPair::from_pkcs8(identity_pkcs8).ok()?;
        let signature = identity
            .sign(&persist::signing_domain(
                KEY_PACKAGE_SIGN_CONTEXT,
                &x25519_pub,
            ))
            .as_ref()
            .to_vec();
        Some(Self {
            private: Some(private),
            package: KeyPackage {
                x25519_pub,
                signature,
            },
            published: false,
        })
    }

    /// The public package to publish at attach.
    #[must_use]
    pub fn package(&self) -> &KeyPackage {
        &self.package
    }

    /// Whether the private half has been spent; a spent package is owed
    /// a replacement (client protocol §5.4).
    #[must_use]
    pub fn is_spent(&self) -> bool {
        self.private.is_none()
    }

    /// Record that the relay accepted an attach carrying this package.
    pub fn mark_published(&mut self) {
        self.published = true;
    }

    /// Whether the relay has accepted an attach carrying this package.
    #[must_use]
    pub fn is_published(&self) -> bool {
        self.published
    }

    /// Open entropy a proposer sealed to this package, spending the
    /// private half whether or not it opens. A payload too short to
    /// open is refused first and spends nothing (client protocol §5.3).
    #[must_use]
    pub fn open_entropy(&mut self, sealed: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        let eph_pub = sealed.get(..32)?;
        let body = sealed.get(32..)?;
        if body.len() < persist::sealed_body_floor() {
            return None;
        }
        let private = self.private.take()?;
        let peer = agreement::UnparsedPublicKey::new(&agreement::X25519, eph_pub);
        let wrap_key = agreement::agree_ephemeral(private, &peer, wrap_key_from).ok()??;
        persist::open_body(&wrap_key, ENTROPY_MAGIC, body)
    }
}

/// Open a proposal's entropy with the standing package, then the
/// pending one, adopting a pending package that opens and dropping one
/// spent on nothing. Rules and cost: client protocol §5.3 and §7.9.
pub fn open_proposal_entropy(
    standing: &mut KeyPackageKeeper,
    pending: &mut Option<KeyPackageKeeper>,
    sealed: &[u8],
) -> Option<Zeroizing<Vec<u8>>> {
    if let Some(entropy) = standing.open_entropy(sealed) {
        return Some(entropy);
    }
    let fresh = pending.as_mut()?;
    let Some(entropy) = fresh.open_entropy(sealed) else {
        if fresh.is_spent() {
            *pending = None;
        }
        return None;
    };
    let mut adopted = pending.take()?;
    adopted.mark_published();
    *standing = adopted;
    Some(entropy)
}

// ---------------------------------------------------------------------
// The session
// ---------------------------------------------------------------------

/// A device on a ballot, as [`PageChannel`] counts it: a stable token
/// derived from the identity fingerprint, so ballot membership is the
/// same computation on every device.
fn ballot_token(fingerprint: &str) -> ItemId {
    let hash = digest::digest(&digest::SHA256, fingerprint.as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&hash.as_ref()[..16]);
    ItemId::from_bytes(bytes)
}

/// The wire form of a page id: the [`ItemId`]'s bytes, lowercase hex.
pub(crate) fn page_wire_id(page: ItemId) -> String {
    page.as_bytes().iter().map(|b| format!("{b:02x}")).collect()
}

fn page_from_wire(wire: &str) -> Option<ItemId> {
    if wire.len() != 32 {
        return None;
    }
    let mut bytes = [0u8; 16];
    for (i, chunk) in wire.as_bytes().chunks(2).enumerate() {
        bytes[i] = u8::from_str_radix(std::str::from_utf8(chunk).ok()?, 16).ok()?;
    }
    Some(ItemId::from_bytes(bytes))
}

/// What a fetch or publish round tells the shell, beyond the store
/// mutations it already performed. Everything user-visible is a
/// sentence issue #102 owns; the engine hands up states, not strings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncEvent {
    /// Remote ops landed on a page.
    Applied(ItemId),
    /// A peer's expiry or hold moved a page's countdown.
    CountdownMoved(ItemId),
    /// A terminal marker landed: the page is dead everywhere.
    Terminal(ItemId),
    /// This device slept through a ceremony (or the relay's buffer
    /// outran it): drop the stale copy and adopt the current frame.
    RejoinRequired,
    /// A ceremony confirmed and this device committed it: compact,
    /// advance, reseal. The proposer's next move is
    /// [`SyncSession::publish_frame_request`].
    CeremonyCommitted(ItemId),
    /// The refresh was refused: sync is signed out; the pad is
    /// unaffected (account-auth.md §2).
    SignedOut,
}

/// A peer named by a ceremony proposal: its identity fingerprint and
/// its verified key package. The caller builds these from the attach
/// list and the pairing records — the engine refuses to seal to a
/// package it cannot tie to a paired identity.
pub struct CeremonyPeer {
    /// The peer's identity fingerprint (the attach `device` value).
    pub fingerprint: String,
    /// The peer's current key package, signature already verified
    /// against the pairing record's identity key.
    pub package: KeyPackage,
}

/// The engine, one per channel (one per account, ADR-0021 §1), driven
/// by whoever owns the runloop.
pub struct SyncSession {
    api: RelayApi,
    keeper: TokenKeeper,
    device_fingerprint: String,
    /// Where the next delta fetch resumes.
    next_seq: u64,
    /// Per-page channel state (epoch, ballot, terminal).
    channels: HashMap<ItemId, PageChannel>,
    /// Envelopes queued since the last publish tick.
    outbox: Vec<DeltaEnvelope>,
    /// A publish batch built and not yet acknowledged, kept so a `401`
    /// can retry the one request after a refresh.
    in_flight: Option<Vec<Vec<u8>>>,
    /// Which batch that is: bumped once per seal, so a caller tells a
    /// fresh batch from a resend (`sync_driver::stage_publish`).
    in_flight_id: u64,
    last_publish_ms: Option<u64>,
    /// The proposer's minted entropy while its ballot is in flight.
    proposed_entropy: Option<(String, Zeroizing<Vec<u8>>)>,
    /// Entropy received and opened from a peer's proposal, held until
    /// the ballot confirms.
    received_entropy: Option<(String, Zeroizing<Vec<u8>>)>,
    /// The page the in-flight ballot compacts, and when it opened.
    ballot_scope: Option<(ItemId, u64)>,
    /// The sealed key frame a committed ceremony produced, waiting for
    /// [`SyncSession::take_frame`] and the frame publish.
    pending_frame: Option<Vec<u8>>,
    /// The last absorbed attach answer: where the channel stands and
    /// who else is on it. `None` until an attach lands.
    attach: Option<AttachSnapshot>,
}

/// What an attach answer leaves behind: the channel position and the
/// roster of peers with their key packages.
struct AttachSnapshot {
    epoch: u64,
    frame_present: bool,
    peers: Vec<PeerAttachment>,
}

impl SyncSession {
    /// A session against `relay_url`, resuming auth from the persisted
    /// refresh token if one exists.
    #[must_use]
    pub fn new(relay_url: &str, keeper: TokenKeeper, device_fingerprint: &str) -> Self {
        Self {
            api: RelayApi::new(relay_url),
            keeper,
            device_fingerprint: device_fingerprint.into(),
            next_seq: 0,
            channels: HashMap::new(),
            outbox: Vec::new(),
            in_flight: None,
            in_flight_id: 0,
            last_publish_ms: None,
            proposed_entropy: None,
            received_entropy: None,
            ballot_scope: None,
            pending_frame: None,
            attach: None,
        }
    }

    /// The sealed key frame the last committed ceremony produced, once,
    /// for [`SyncSession::publish_frame_request`]. Every committing
    /// device holds one, and the driver publishes it whoever proposed
    /// (client protocol §7.8).
    #[must_use]
    pub fn take_frame(&mut self) -> Option<Vec<u8>> {
        self.pending_frame.take()
    }

    /// The auth keeper, for the shell's sign-in ceremony to feed
    /// grants into.
    pub fn keeper_mut(&mut self) -> &mut TokenKeeper {
        &mut self.keeper
    }

    /// Whether the keeper holds anything to authenticate with.
    #[must_use]
    pub fn signed_in(&self) -> bool {
        self.keeper.signed_in()
    }

    /// Whether a live access token is held; a `401` from any route
    /// drops it ([`SyncSession::note_refusal`]) until the refresh lands.
    #[must_use]
    pub fn has_access(&self) -> bool {
        self.keeper.access().is_some()
    }

    /// Dissolve the session, handing the keeper back — a detach keeps
    /// the sign-in it did not revoke.
    #[must_use]
    pub fn into_keeper(self) -> TokenKeeper {
        self.keeper
    }

    fn auth(&self) -> Option<BearerAuth> {
        self.keeper.access().map(BearerAuth::new)
    }

    /// The refresh request to run first when no access token is held.
    ///
    /// # Errors
    ///
    /// [`companion_sync::oauth::SyncAuthError::SignedOut`] when there
    /// is nothing to refresh with: sync stops and says so.
    pub fn refresh_request(&mut self) -> Result<HttpRequest, companion_sync::oauth::SyncAuthError> {
        self.keeper.refresh_request()
    }

    /// Absorb the refresh answer; a rotated refresh token comes back
    /// for the caller to persist, and `None` means the server declined
    /// to rotate and the resting token still stands. A refusal signs
    /// sync out.
    ///
    /// # Errors
    ///
    /// [`companion_sync::oauth::SyncAuthError::SignedOut`] on refusal.
    pub fn absorb_refresh(
        &mut self,
        response: &HttpResponse,
    ) -> Result<Option<Zeroizing<String>>, companion_sync::oauth::SyncAuthError> {
        self.keeper.absorb_refresh(response)
    }

    /// `POST /channel/attach` with this device's fingerprint and
    /// current key package. `None` when no access token is held —
    /// refresh first.
    #[must_use]
    pub fn attach_request(&self, package: &KeyPackage) -> Option<HttpRequest> {
        let auth = self.auth()?;
        Some(
            self.api
                .attach_request(&self.device_fingerprint, &package.encode(), &auth),
        )
    }

    /// Absorb the attach answer: the first attach adopts the relay's
    /// cursor, a re-attach keeps the live one so no published batch is
    /// skipped, and both replace the roster (client protocol §4.3).
    ///
    /// # Errors
    ///
    /// [`RelayRefusal`] passed through; `Unauthorized` means refresh
    /// and retry the one request.
    pub fn absorb_attach(&mut self, response: &HttpResponse) -> Result<(), RelayRefusal> {
        let answer = match RelayApi::parse_attach(response) {
            Ok(answer) => answer,
            Err(refusal) => return Err(self.note_refusal(refusal)),
        };
        if self.attach.is_none() {
            self.next_seq = answer.next_seq;
        }
        self.attach = Some(AttachSnapshot {
            epoch: answer.epoch,
            frame_present: answer.frame_present,
            peers: answer.peers,
        });
        Ok(())
    }

    /// Every refusal passes through here: a `401` drops the access
    /// token, the only expiry authority (account-auth.md §2).
    fn note_refusal(&mut self, refusal: RelayRefusal) -> RelayRefusal {
        if matches!(refusal, RelayRefusal::Unauthorized) {
            self.keeper.clear_access();
        }
        refusal
    }

    /// Whether an attach has landed this session.
    #[must_use]
    pub fn attached(&self) -> bool {
        self.attach.is_some()
    }

    /// Which publish batch is in flight, if any; the same id across two
    /// calls means the same sealed blobs went out twice.
    #[must_use]
    pub fn in_flight_batch(&self) -> Option<u64> {
        self.in_flight.is_some().then_some(self.in_flight_id)
    }

    /// The channel epoch the last attach reported; the chain, not this
    /// echo, opens anything.
    #[must_use]
    pub fn attach_epoch(&self) -> Option<u64> {
        self.attach.as_ref().map(|attach| attach.epoch)
    }

    /// Whether the relay held a key frame at the last attach.
    #[must_use]
    pub fn frame_present(&self) -> Option<bool> {
        self.attach.as_ref().map(|attach| attach.frame_present)
    }

    /// The peers the last attach reported, key packages included:
    /// attach-list truth, not device trust.
    #[must_use]
    pub fn attach_roster(&self) -> &[PeerAttachment] {
        self.attach
            .as_ref()
            .map_or(&[], |attach| attach.peers.as_slice())
    }

    /// The ceremony peers this device may seal entropy to: the attach
    /// roster filtered through the pairing records, `identities` mapping
    /// fingerprint to identity public key (client protocol §7.3).
    #[must_use]
    pub fn ceremony_peers(&self, identities: &[(String, Vec<u8>)]) -> Vec<CeremonyPeer> {
        self.attach_roster()
            .iter()
            .filter(|peer| peer.device != self.device_fingerprint)
            .filter_map(|peer| {
                let (_, identity) = identities.iter().find(|(fp, _)| *fp == peer.device)?;
                let package = KeyPackage::decode(&peer.key_package)?;
                package.verify(identity).then(|| CeremonyPeer {
                    fingerprint: peer.device.clone(),
                    package,
                })
            })
            .collect()
    }

    // -----------------------------------------------------------------
    // Outbound: the publish clock
    // -----------------------------------------------------------------

    /// Queue a page's fresh document ops for the next publish tick.
    pub fn queue_ops(&mut self, page: ItemId, ops: &[u8]) {
        self.outbox.push(DeltaEnvelope::Ops {
            page: page_wire_id(page),
            ops: ByteBlob(ops.to_vec()),
        });
    }

    /// Queue a page's expiry policy — the policy, never the deadline.
    pub fn queue_expiry(&mut self, page: ItemId, policy: ExpiryPolicy) {
        self.outbox.push(DeltaEnvelope::Expiry {
            page: page_wire_id(page),
            anchor_wall_ms: policy.anchor_wall_ms,
            ttl_ms: policy.ttl_ms,
        });
    }

    /// Queue the hold register's state — the state, never the press.
    pub fn queue_hold(&mut self, page: ItemId, register: HoldRegister) {
        let hold = match register {
            HoldRegister::Released => None,
            HoldRegister::Held {
                frozen_ms,
                until_wall_ms,
                topped_up,
            } => Some((frozen_ms, until_wall_ms, topped_up)),
        };
        self.outbox.push(DeltaEnvelope::Hold {
            page: page_wire_id(page),
            hold,
        });
    }

    /// Queue a signed terminal marker if
    /// [`PageChannel::may_publish_terminal`] allows (false otherwise,
    /// nothing queued); a queued marker notes the page terminal here.
    pub fn queue_terminal(&mut self, page: ItemId, marker: &[u8]) -> bool {
        let channel = self.channels.entry(page).or_default();
        if !channel.may_publish_terminal() {
            return false;
        }
        channel.note_terminal();
        self.outbox.push(DeltaEnvelope::Terminal {
            page: page_wire_id(page),
            marker: ByteBlob(marker.to_vec()),
        });
        true
    }

    /// Whether the publish clock permits a publish at `now_ms` and
    /// there is anything to publish.
    #[must_use]
    pub fn publish_due(&self, now_ms: u64) -> bool {
        (!self.outbox.is_empty() || self.in_flight.is_some())
            && self
                .last_publish_ms
                .is_none_or(|last| now_ms.saturating_sub(last) >= PUBLISH_INTERVAL_MS)
    }

    /// `POST /channel/deltas`: pad and seal everything queued under the
    /// current GOP key, one request. `None` when the clock says wait,
    /// nothing is queued, a seal refuses, or no access token is held.
    #[must_use]
    pub fn publish_request(
        &mut self,
        now_ms: u64,
        chain: &crate::gop::GopKeyChain,
    ) -> Option<HttpRequest> {
        self.publish_request_sealed_with(now_ms, chain.epoch(), |plaintext| chain.seal(plaintext))
    }

    /// [`SyncSession::publish_request`] with the seal handed in, so the
    /// tests can make it refuse.
    fn publish_request_sealed_with(
        &mut self,
        now_ms: u64,
        epoch: u64,
        seal: impl Fn(&[u8]) -> Option<Vec<u8>>,
    ) -> Option<HttpRequest> {
        if !self.publish_due(now_ms) {
            return None;
        }
        let auth = self.auth()?;
        if self.in_flight.is_none() {
            // Borrowed, never drained: a dropped `Drain` would take the
            // whole queue with one declined nonce.
            let blobs = self
                .outbox
                .iter()
                .map(|envelope| seal(&pad::pad(&envelope.encode())))
                .collect::<Option<Vec<_>>>()?;
            // Every seal succeeded; only now does the queue let go.
            self.outbox.clear();
            self.in_flight = Some(blobs);
            self.in_flight_id = self.in_flight_id.wrapping_add(1);
        }
        let blobs = self.in_flight.as_ref()?;
        self.last_publish_ms = Some(now_ms);
        Some(self.api.publish_deltas_request(epoch, blobs, &auth))
    }

    /// Absorb the publish answer: a 2xx clears the batch, a `401` keeps
    /// it and reopens the clock, a `409` or `410` drops it, anything else
    /// keeps it (client protocol §4.4).
    ///
    /// # Errors
    ///
    /// The [`RelayRefusal`] as received, for the caller's move.
    pub fn absorb_publish(&mut self, response: &HttpResponse) -> Result<(), RelayRefusal> {
        match RelayApi::parse_publish_deltas(response) {
            Ok(_) => {
                self.in_flight = None;
                Ok(())
            }
            Err(refusal) => {
                if matches!(refusal, RelayRefusal::EpochConflict | RelayRefusal::Rejoin) {
                    self.in_flight = None;
                }
                if matches!(refusal, RelayRefusal::Unauthorized) {
                    self.last_publish_ms = None;
                }
                Err(self.note_refusal(refusal))
            }
        }
    }

    // -----------------------------------------------------------------
    // Inbound: the long-poll
    // -----------------------------------------------------------------

    /// `GET /channel/deltas?since=…&wait=…` — the long-poll. `None`
    /// when no access token is held. A `wait` past
    /// [`LONG_POLL_WAIT_S`] is held to it.
    #[must_use]
    pub fn fetch_request(&self, wait_seconds: u32) -> Option<HttpRequest> {
        let auth = self.auth()?;
        Some(self.api.fetch_deltas_request(
            self.next_seq,
            wait_seconds.min(LONG_POLL_WAIT_S),
            &auth,
        ))
    }

    /// Absorb one long poll's worth of deltas, dispatching each blob
    /// that opens; `trusted` holds the identity keys whose terminal
    /// markers count, and a `410` comes back as
    /// [`SyncEvent::RejoinRequired`]. Client protocol §4.5 and §6.
    ///
    /// # Errors
    ///
    /// Other [`RelayRefusal`]s passed through (`Unauthorized`: refresh
    /// and retry).
    #[allow(clippy::too_many_arguments)]
    pub fn absorb_deltas<C: Clock>(
        &mut self,
        response: &HttpResponse,
        store: &mut SheetStore<C>,
        chain: &mut crate::gop::GopKeyChain,
        packages: &mut KeyPackageKeeper,
        pending: &mut Option<KeyPackageKeeper>,
        trusted: &[Vec<u8>],
        now_ms: u64,
    ) -> Result<Vec<SyncEvent>, RelayRefusal> {
        let batch = match RelayApi::parse_deltas(response) {
            Ok(batch) => batch,
            Err(RelayRefusal::Rejoin) => return Ok(vec![SyncEvent::RejoinRequired]),
            Err(refusal) => return Err(self.note_refusal(refusal)),
        };
        self.next_seq = batch.next_seq;
        let mut events = Vec::new();
        for blob in &batch.blobs {
            let Some(plaintext) = chain.open(blob) else {
                continue;
            };
            let Some(content) = pad::unpad(&plaintext) else {
                continue;
            };
            let Some(envelope) = DeltaEnvelope::decode(content) else {
                continue;
            };
            self.dispatch(
                envelope,
                batch.epoch,
                store,
                chain,
                packages,
                pending,
                trusted,
                now_ms,
                &mut events,
            );
        }
        // Client protocol §4.5: a batch epoch above the chain's, checked
        // after the loop so a commit in this batch counts, is a rejoin,
        // and the currency flags stay unset.
        if batch.epoch > chain.epoch() {
            events.push(SyncEvent::RejoinRequired);
            return Ok(events);
        }
        // Draining to the frontier is what makes this device's view
        // current — the register currency the terminal gate reads.
        for channel in self.channels.values_mut() {
            channel.set_current(true);
        }
        Ok(events)
    }

    #[allow(clippy::too_many_arguments)]
    fn dispatch<C: Clock>(
        &mut self,
        envelope: DeltaEnvelope,
        wire_epoch: u64,
        store: &mut SheetStore<C>,
        chain: &mut crate::gop::GopKeyChain,
        packages: &mut KeyPackageKeeper,
        pending: &mut Option<KeyPackageKeeper>,
        trusted: &[Vec<u8>],
        now_ms: u64,
        events: &mut Vec<SyncEvent>,
    ) {
        match envelope {
            DeltaEnvelope::Ops { page, ops } => {
                let Some(page) = page_from_wire(&page) else {
                    return;
                };
                let channel = self.channels.entry(page).or_default();
                match channel.admit_delta(wire_epoch) {
                    DeltaAdmission::Apply => {
                        let Some(sheet_id) = sheet_of(store, page) else {
                            return;
                        };
                        // An import that leaves the frontier unmoved is
                        // this device's own echo, not an arrival
                        // (surface.md §6; client protocol §6).
                        let before = store.document_version(sheet_id);
                        if store.apply_remote_update(sheet_id, &ops.0).is_ok()
                            && store.document_version(sheet_id) != before
                        {
                            events.push(SyncEvent::Applied(page));
                        }
                    }
                    DeltaAdmission::RejoinRequired => events.push(SyncEvent::RejoinRequired),
                    DeltaAdmission::Refused => {}
                }
            }
            DeltaEnvelope::Expiry {
                page,
                anchor_wall_ms,
                ttl_ms,
            } => {
                let Some(page) = page_from_wire(&page) else {
                    return;
                };
                if store.observe_peer_expiry(
                    page,
                    ExpiryPolicy {
                        anchor_wall_ms,
                        ttl_ms,
                    },
                ) {
                    events.push(SyncEvent::CountdownMoved(page));
                }
            }
            DeltaEnvelope::Hold { page, hold } => {
                let Some(page) = page_from_wire(&page) else {
                    return;
                };
                let register = match hold {
                    None => HoldRegister::Released,
                    Some((frozen_ms, until_wall_ms, topped_up)) => HoldRegister::Held {
                        frozen_ms,
                        until_wall_ms,
                        topped_up,
                    },
                };
                self.channels.entry(page).or_default().note_hold(register);
                if store.observe_peer_hold(page, register) {
                    events.push(SyncEvent::CountdownMoved(page));
                }
            }
            DeltaEnvelope::Terminal { page, marker } => {
                let Some(page) = page_from_wire(&page) else {
                    return;
                };
                // Client protocol §6: a marker counts only if it names
                // this page and verifies under a trusted identity.
                if !marker_trusted(&marker.0, page, trusted) {
                    return;
                }
                self.channels.entry(page).or_default().note_terminal();
                store.observe_terminal(page);
                events.push(SyncEvent::Terminal(page));
            }
            DeltaEnvelope::Control { payload } => {
                self.dispatch_control(payload, store, chain, packages, pending, now_ms, events);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn dispatch_control<C: Clock>(
        &mut self,
        payload: ControlPayload,
        store: &mut SheetStore<C>,
        chain: &mut crate::gop::GopKeyChain,
        packages: &mut KeyPackageKeeper,
        pending: &mut Option<KeyPackageKeeper>,
        now_ms: u64,
        events: &mut Vec<SyncEvent>,
    ) {
        match payload {
            ControlPayload::Propose {
                ballot_id,
                page,
                entropy_sealed,
            } => {
                // Client protocol §7.4: an own echo or a ballot already
                // held is not consumed twice, and spends no package.
                let already_held = |held: &Option<(String, Zeroizing<Vec<u8>>)>| {
                    held.as_ref().is_some_and(|(id, _)| *id == ballot_id)
                };
                if already_held(&self.proposed_entropy) || already_held(&self.received_entropy) {
                    return;
                }
                // One ballot at a time (client protocol §7.4): a second
                // proposal goes unanswered.
                if self.ballot_scope.is_some() {
                    return;
                }
                // Resolve everything before the one-shot key is spent:
                // a device that cannot join stays out at no cost.
                let Some(page) = page_from_wire(&page) else {
                    return;
                };
                if sheet_of(store, page).is_none()
                    || self
                        .channels
                        .get(&page)
                        .is_some_and(PageChannel::is_terminal)
                {
                    return;
                }
                // Open this device's entry; a proposal not naming it is
                // a ballot it cannot join.
                let Some(sealed) = entropy_sealed.get(&self.device_fingerprint) else {
                    return;
                };
                let Some(entropy) = open_proposal_entropy(packages, pending, &sealed.0) else {
                    crate::diagnostics::diag_fault!(
                        "companion-ffi: a ceremony proposal named this device and neither key package opened its entry; the device stays out of that ballot."
                    );
                    return;
                };
                // Members mirror the proposal's map (client protocol
                // §7.3); every named device must accept.
                let attached: Vec<ItemId> =
                    entropy_sealed.keys().map(|fp| ballot_token(fp)).collect();
                let channel = self.channels.entry(page).or_default();
                if !channel.propose_ceremony(&attached) {
                    return;
                }
                self.ballot_scope = Some((page, now_ms));
                self.received_entropy = Some((ballot_id.clone(), entropy));
                // Queue the acceptance; it counts only when it comes
                // back on the stream (client protocol §7.5).
                self.outbox.push(DeltaEnvelope::Control {
                    payload: ControlPayload::Accept {
                        ballot_id,
                        device_fingerprint: self.device_fingerprint.clone(),
                    },
                });
            }
            ControlPayload::Accept {
                ballot_id,
                device_fingerprint,
            } => {
                let Some((page, _)) = self.ballot_scope else {
                    return;
                };
                let held_ballot = self
                    .proposed_entropy
                    .as_ref()
                    .or(self.received_entropy.as_ref())
                    .map(|(id, _)| id.clone());
                if held_ballot.as_deref() != Some(ballot_id.as_str()) {
                    return;
                }
                let Some(channel) = self.channels.get_mut(&page) else {
                    return;
                };
                let _ = channel.accept_ceremony(ballot_token(&device_fingerprint));
                if channel.ceremony_confirmed() {
                    let entropy = self
                        .proposed_entropy
                        .take()
                        .or(self.received_entropy.take())
                        .map(|(_, entropy)| entropy);
                    let Some(entropy) = entropy else {
                        return;
                    };
                    let Some(sheet_id) = sheet_of(store, page) else {
                        return;
                    };
                    if let Some(frame) =
                        crate::gop::ceremony_commit(store, sheet_id, chain, &entropy)
                        && channel.complete_ceremony()
                    {
                        // Client protocol §7.6: the chain is
                        // channel-wide, so every existing page channel
                        // adopts the new epoch.
                        for other in self.channels.values_mut() {
                            other.rejoin_at_epoch(chain.epoch());
                        }
                        self.pending_frame = Some(frame);
                        self.ballot_scope = None;
                        events.push(SyncEvent::CeremonyCommitted(page));
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------
    // Ceremonies (relay-protocol.md §5)
    // -----------------------------------------------------------------

    /// Propose a ceremony for `page`: mint entropy, seal it to this
    /// device's package and each peer's, and queue the proposal with
    /// this device's accept (client protocol §7.3). False when a ballot
    /// is already in flight, the page is terminal, a seal refuses, or
    /// the peer list is empty.
    pub fn propose_ceremony(
        &mut self,
        page: ItemId,
        peers: &[CeremonyPeer],
        own_package: &KeyPackage,
        now_ms: u64,
    ) -> bool {
        if peers.is_empty() || self.ballot_scope.is_some() {
            return false;
        }
        let mut entropy = Zeroizing::new(vec![0u8; KEY_LEN]);
        if SystemRandom::new().fill(&mut entropy).is_err() {
            return false;
        }
        let mut attached: Vec<ItemId> = vec![ballot_token(&self.device_fingerprint)];
        let mut entropy_sealed = std::collections::BTreeMap::new();
        let Some(own_sealed) = own_package.seal_entropy(&entropy) else {
            return false;
        };
        entropy_sealed.insert(self.device_fingerprint.clone(), ByteBlob(own_sealed));
        for peer in peers {
            let Some(sealed) = peer.package.seal_entropy(&entropy) else {
                return false;
            };
            entropy_sealed.insert(peer.fingerprint.clone(), ByteBlob(sealed));
            attached.push(ballot_token(&peer.fingerprint));
        }
        let channel = self.channels.entry(page).or_default();
        if !channel.propose_ceremony(&attached) {
            return false;
        }
        let ballot_id = page_wire_id(ItemId::random());
        self.proposed_entropy = Some((ballot_id.clone(), entropy));
        self.ballot_scope = Some((page, now_ms));
        self.outbox.push(DeltaEnvelope::Control {
            payload: ControlPayload::Propose {
                ballot_id: ballot_id.clone(),
                page: page_wire_id(page),
                entropy_sealed,
            },
        });
        // Counted only off the stream, like anyone's (client protocol
        // §7.5).
        self.outbox.push(DeltaEnvelope::Control {
            payload: ControlPayload::Accept {
                ballot_id,
                device_fingerprint: self.device_fingerprint.clone(),
            },
        });
        true
    }

    /// A ceremony with no verified peer in the room: compact, advance
    /// and stage the frame at once, every page channel adopting the new
    /// epoch (client protocol §7.2). False when a ballot is in flight,
    /// the page is unknown or not deferred, or the RNG refuses.
    pub fn solo_ceremony<C: Clock>(
        &mut self,
        page: ItemId,
        store: &mut SheetStore<C>,
        chain: &mut crate::gop::GopKeyChain,
    ) -> bool {
        if self.ballot_scope.is_some() {
            return false;
        }
        let mut entropy = Zeroizing::new(vec![0u8; KEY_LEN]);
        if SystemRandom::new().fill(&mut entropy).is_err() {
            return false;
        }
        let Some(sheet) = sheet_of(store, page) else {
            return false;
        };
        let Some(frame) = crate::gop::ceremony_commit(store, sheet, chain, &entropy) else {
            return false;
        };
        for channel in self.channels.values_mut() {
            channel.rejoin_at_epoch(chain.epoch());
        }
        self.channels
            .entry(page)
            .or_default()
            .rejoin_at_epoch(chain.epoch());
        self.pending_frame = Some(frame);
        true
    }

    /// `POST /channel/pairing` — one §7 mailbox message, already in
    /// its wire form. `None` when no access token is held.
    #[must_use]
    pub fn post_pairing_request(&self, message: serde_json::Value) -> Option<HttpRequest> {
        let auth = self.auth()?;
        Some(self.api.post_pairing_request(message, &auth))
    }

    /// `GET /channel/pairing?since=` — the mailbox tail. `None` when
    /// no access token is held.
    #[must_use]
    pub fn fetch_pairing_request(&self, since: u64) -> Option<HttpRequest> {
        let auth = self.auth()?;
        Some(self.api.fetch_pairing_request(since, &auth))
    }

    /// Whether a ballot is in flight: proposed or joined, and neither
    /// confirmed nor abandoned yet.
    #[must_use]
    pub fn ballot_in_flight(&self) -> bool {
        self.ballot_scope.is_some()
    }

    /// Abandon a ballot that outlived its patience on this device's
    /// clock; a spent package stays spent (client protocol §7.7, §5.4).
    pub fn tick(&mut self, now_ms: u64) {
        let Some((page, opened_ms)) = self.ballot_scope else {
            return;
        };
        if now_ms.saturating_sub(opened_ms) < BALLOT_PATIENCE_MS {
            return;
        }
        if let Some(channel) = self.channels.get_mut(&page) {
            channel.abandon_ceremony();
        }
        self.ballot_scope = None;
        self.proposed_entropy = None;
        self.received_entropy = None;
    }

    /// `PUT /channel/frame` after a committed ceremony: the epoch the
    /// chain now stands at, superseding the old frame and purging every
    /// older delta. `None` when no access token is held.
    #[must_use]
    pub fn publish_frame_request(
        &self,
        chain: &crate::gop::GopKeyChain,
        frame: &[u8],
    ) -> Option<HttpRequest> {
        let auth = self.auth()?;
        Some(self.api.publish_frame_request(chain.epoch(), frame, &auth))
    }

    /// `GET /channel/frame`, the rejoin path's first move. `None` when
    /// no access token is held.
    #[must_use]
    pub fn fetch_frame_request(&self) -> Option<HttpRequest> {
        let auth = self.auth()?;
        Some(self.api.fetch_frame_request(&auth))
    }

    /// Absorb the frame on the rejoin path: open it under the current
    /// chain and adopt it onto the fresh page `sheet_id`. False when
    /// the chain cannot open it. Nothing calls this yet (client
    /// protocol §8).
    pub fn absorb_frame<C: Clock>(
        &mut self,
        response: &HttpResponse,
        store: &mut SheetStore<C>,
        sheet_id: SheetId,
        page: ItemId,
        chain: &crate::gop::GopKeyChain,
    ) -> bool {
        let Ok(FrameAnswer::Present { epoch, frame }) = RelayApi::parse_frame(response) else {
            return false;
        };
        let Some(plaintext) = chain.open(&frame) else {
            return false;
        };
        if store.adopt_key_frame(sheet_id, page, &plaintext).is_err() {
            return false;
        }
        self.channels
            .entry(page)
            .or_default()
            .rejoin_at_epoch(epoch);
        true
    }
}

/// The sheet currently holding `page`'s cross-device identity.
pub(crate) fn sheet_of<C: Clock>(store: &SheetStore<C>, page: ItemId) -> Option<SheetId> {
    store.sheet_id_of(page)
}

/// Whether `marker` is a well-formed terminal claim for `page` under one
/// of the `trusted` identity keys: `page_id(16) ‖ wall_ms(8)`, signed
/// under [`TERMINAL_SIGN_CONTEXT`]. Matching the signed id to the
/// envelope's page stops a real signature replaying against another.
fn marker_trusted(marker: &[u8], page: ItemId, trusted: &[Vec<u8>]) -> bool {
    const CLAIM_LEN: usize = 16 + 8;
    const SIG_LEN: usize = 64;
    if marker.len() != CLAIM_LEN + SIG_LEN || marker[..16] != page.as_bytes()[..] {
        return false;
    }
    let (claim, signature) = marker.split_at(CLAIM_LEN);
    let message = persist::signing_domain(TERMINAL_SIGN_CONTEXT, claim);
    trusted.iter().any(|key| {
        UnparsedPublicKey::new(&ED25519, key)
            .verify(&message, signature)
            .is_ok()
    })
}

#[cfg(test)]
mod tests {
    use companion_core::{EditOp, ManualClock};
    use serde_json::Value;

    use super::*;
    use crate::gop::GopKeyChain;

    const CHANNEL_SECRET: &[u8; 32] = b"0123456789abcdef0123456789abcdef";

    fn identity() -> (Vec<u8>, Vec<u8>) {
        use ring::signature::KeyPair as _;
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
        let pair = Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap();
        (pkcs8.as_ref().to_vec(), pair.public_key().as_ref().to_vec())
    }

    fn keeper() -> TokenKeeper {
        let mut keeper =
            TokenKeeper::new("https://eu.onetimesecret.com/auth/token", "companion", None);
        keeper.absorb(companion_sync::TokenGrant {
            access: Zeroizing::new("at".into()),
            refresh: Zeroizing::new("rt".into()),
        });
        keeper
    }

    fn session(fingerprint: &str) -> SyncSession {
        SyncSession::new("https://relay.onetimesecret.com", keeper(), fingerprint)
    }

    #[test]
    fn a_long_poll_never_asks_the_relay_to_wait_past_the_spec() {
        let session = session("fp");
        assert!(
            session
                .fetch_request(u32::MAX)
                .unwrap()
                .url
                .ends_with("wait=25")
        );
        assert!(session.fetch_request(5).unwrap().url.ends_with("wait=5"));
    }

    /// The relay as §9 describes it, at test scale: an ordered blob
    /// log it never reads. Blobs stay as the base64 the client sent.
    #[derive(Default)]
    struct FakeRelay {
        epoch: u64,
        blobs: Vec<Value>,
    }

    impl FakeRelay {
        fn accept_publish(&mut self, request: &HttpRequest) -> HttpResponse {
            let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
            assert_eq!(body["epoch"].as_u64().unwrap(), self.epoch, "epoch gate");
            self.blobs
                .extend(body["blobs"].as_array().unwrap().iter().cloned());
            HttpResponse {
                status: 200,
                body: format!(r#"{{"seq":{}}}"#, self.blobs.len()).into_bytes(),
            }
        }

        fn serve_fetch(&self, since: u64) -> HttpResponse {
            let slice: Vec<Value> = self.blobs[since as usize..].to_vec();
            HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "epoch": self.epoch,
                    "blobs": slice,
                    "next_seq": self.blobs.len(),
                })
                .to_string()
                .into_bytes(),
            }
        }
    }

    #[test]
    fn opening_entropy_spends_the_package_whether_or_not_it_opens() {
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
        let mut packages = KeyPackageKeeper::mint(pkcs8.as_ref()).unwrap();
        assert!(!packages.is_spent(), "a fresh mint is reachable");
        // A payload nobody sealed to this package refuses and still
        // spends the one-shot key.
        assert!(packages.open_entropy(&[0u8; 64]).is_none());
        assert!(
            packages.is_spent(),
            "a spent package is owed a fresh mint, however the ballot ends"
        );
    }

    #[test]
    fn a_mint_is_not_a_publication() {
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
        let mut packages = KeyPackageKeeper::mint(pkcs8.as_ref()).unwrap();
        assert!(
            !packages.is_published(),
            "nothing has reached the relay yet"
        );
        packages.mark_published();
        assert!(packages.is_published());
    }

    #[test]
    fn key_packages_verify_seal_and_spend_once() {
        let (pkcs8, identity_pub) = identity();
        let (_, other_pub) = identity();
        let mut keeper = KeyPackageKeeper::mint(&pkcs8).unwrap();
        let package = KeyPackage::decode(&keeper.package().encode()).unwrap();
        assert!(package.verify(&identity_pub));
        assert!(
            !package.verify(&other_pub),
            "a relay-substituted package must not verify"
        );

        let sealed = package.seal_entropy(b"ceremony entropy").unwrap();
        assert_eq!(
            keeper.open_entropy(&sealed).unwrap().as_slice(),
            b"ceremony entropy"
        );
        // The private half is spent: a second open refuses until a
        // fresh mint publishes a fresh package.
        assert!(keeper.open_entropy(&sealed).is_none());
    }

    #[test]
    fn a_proposal_sealed_to_the_pending_package_opens_and_adopts_it() {
        // The relay took the attach carrying the pending package and
        // its answer was lost: the roster names the pending one.
        let (pkcs8, _) = identity();
        let mut standing = KeyPackageKeeper::mint(&pkcs8).unwrap();
        let mut pending = Some(KeyPackageKeeper::mint(&pkcs8).unwrap());
        let named = pending.as_ref().unwrap().package().clone();
        let sealed = named.seal_entropy(b"to the pending one").unwrap();
        assert_eq!(
            open_proposal_entropy(&mut standing, &mut pending, &sealed)
                .unwrap()
                .as_slice(),
            b"to the pending one"
        );
        assert!(pending.is_none(), "adopted, not left waiting");
        assert_eq!(standing.package(), &named);
        assert!(standing.is_published() && standing.is_spent());
    }

    #[test]
    fn a_proposal_sealed_to_the_standing_package_leaves_the_pending_one_owed() {
        let (pkcs8, _) = identity();
        let mut standing = KeyPackageKeeper::mint(&pkcs8).unwrap();
        let mut pending = Some(KeyPackageKeeper::mint(&pkcs8).unwrap());
        let sealed = standing
            .package()
            .seal_entropy(b"to the standing one")
            .unwrap();
        assert_eq!(
            open_proposal_entropy(&mut standing, &mut pending, &sealed)
                .unwrap()
                .as_slice(),
            b"to the standing one"
        );
        assert!(standing.is_spent());
        let pending = pending.expect("still waiting for the relay to take it");
        assert!(!pending.is_spent(), "never tried, so still reachable");
    }

    #[test]
    fn a_payload_too_short_to_try_leaves_both_packages_where_they_were() {
        // Neither key is touched, so the pending one is still owed to
        // the relay and the pump still re-attaches for it.
        let (pkcs8, _) = identity();
        let mut standing = KeyPackageKeeper::mint(&pkcs8).unwrap();
        let mut pending = Some(KeyPackageKeeper::mint(&pkcs8).unwrap());
        assert!(open_proposal_entropy(&mut standing, &mut pending, b"short").is_none());
        // A key's worth and a body with no room for its nonce and tag:
        // it could never open, so it is refused before either try too.
        let keyed = [0u8; 32 + 27];
        assert!(open_proposal_entropy(&mut standing, &mut pending, &keyed).is_none());
        assert!(!standing.is_spent());
        let pending = pending.expect("never tried, so never dropped");
        assert!(!pending.is_spent());
    }

    #[test]
    fn a_proposal_neither_package_opens_drops_the_pending_one() {
        let (pkcs8, _) = identity();
        let mut standing = KeyPackageKeeper::mint(&pkcs8).unwrap();
        let mut pending = Some(KeyPackageKeeper::mint(&pkcs8).unwrap());
        assert!(open_proposal_entropy(&mut standing, &mut pending, &[0u8; 64]).is_none());
        assert!(standing.is_spent());
        assert!(
            pending.is_none(),
            "spent on nothing, so no attach may send it again"
        );
    }

    #[test]
    fn the_publish_clock_coalesces_to_two_second_grain() {
        let chain = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut session = session("fp-a");
        let page = ItemId::random();
        session.queue_ops(page, b"first");
        let request = session.publish_request(0, &chain).unwrap();
        let mut relay = FakeRelay::default();
        session
            .absorb_publish(&relay.accept_publish(&request))
            .unwrap();

        session.queue_ops(page, b"second");
        assert!(
            session.publish_request(1_500, &chain).is_none(),
            "inside the clock"
        );
        assert!(session.publish_request(2_000, &chain).is_some(), "the tick");
    }

    #[test]
    fn a_refused_seal_keeps_the_queue_for_the_next_tick() {
        let chain = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut session = session("fp-a");
        let page = ItemId::random();
        session.queue_ops(page, b"first");
        session.queue_ops(page, b"second");

        // The RNG declines a nonce: no request, and nothing lost.
        assert!(
            session
                .publish_request_sealed_with(0, chain.epoch(), |_| None)
                .is_none()
        );
        assert_eq!(session.outbox.len(), 2, "the queue survives a refusal");
        assert!(session.in_flight.is_none(), "nothing was staged");

        // The next tick seals cleanly, and both envelopes — the ones
        // queued before the refusal — reach the wire.
        let request = session.publish_request(0, &chain).unwrap();
        let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
        assert_eq!(body["blobs"].as_array().unwrap().len(), 2);
        assert!(session.outbox.is_empty(), "a sealed batch leaves the queue");
    }

    #[test]
    fn a_401_keeps_the_batch_for_one_retry_and_a_409_drops_it() {
        let chain = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut session = session("fp-a");
        session.queue_ops(ItemId::random(), b"ops");
        let _ = session.publish_request(0, &chain).unwrap();
        let unauthorized = HttpResponse {
            status: 401,
            body: Vec::new(),
        };
        assert_eq!(
            session.absorb_publish(&unauthorized).unwrap_err(),
            RelayRefusal::Unauthorized
        );
        // The 401 drops the access token; the batch survives, and the
        // retry does not wait out the publish clock.
        assert!(
            session.publish_request(1, &chain).is_none(),
            "no publish rides a token the relay refused"
        );
        session.keeper_mut().absorb(companion_sync::TokenGrant {
            access: Zeroizing::new("access-2".into()),
            refresh: Zeroizing::new("refresh-2".into()),
        });
        assert!(session.publish_request(1, &chain).is_some());
        let conflict = HttpResponse {
            status: 409,
            body: Vec::new(),
        };
        assert_eq!(
            session.absorb_publish(&conflict).unwrap_err(),
            RelayRefusal::EpochConflict
        );
        assert!(
            session.publish_request(4_000, &chain).is_none(),
            "the epoch moved; the batch is history"
        );
    }

    #[test]
    fn sealed_blobs_reach_the_wire_in_power_of_two_buckets() {
        let chain = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut session = session("fp-a");
        session.queue_ops(ItemId::random(), &[7u8; 10]);
        session.queue_ops(ItemId::random(), &[7u8; 60]);
        let request = session.publish_request(0, &chain).unwrap();
        let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
        let sizes: Vec<usize> = body["blobs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b.as_str().unwrap().len())
            .collect();
        assert_eq!(
            sizes[0], sizes[1],
            "two nearby lengths must share a bucket on the wire"
        );
    }

    #[test]
    fn deltas_round_trip_and_the_terminal_gate_needs_a_current_view() {
        let clock = ManualClock::new();
        let mut store_a = SheetStore::new(clock.clone());
        let page_a = store_a.new_tab().1;
        assert!(store_a.apply_ops(
            page_a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "shared text".into()
            }]
        ));
        let uuid = store_a.sheet(page_a).unwrap().uuid();

        let mut store_b = SheetStore::new(clock.clone());
        let page_b = store_b.new_tab().1;
        let pristine = store_b.document_version(page_b).unwrap();
        let full = store_a.export_document_updates(page_a, &pristine).unwrap();
        store_b.adopt_key_frame(page_b, uuid, &full).unwrap();

        let mut chain_a = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut chain_b = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut a = session("fp-a");
        let mut b = session("fp-b");
        let (pkcs8_b, identity_b) = identity();
        let mut packages_b = KeyPackageKeeper::mint(&pkcs8_b).unwrap();
        let mut relay = FakeRelay::default();

        // A writes on after B adopted the frame and publishes only what
        // B has not seen.
        let adopted = store_b.document_version(page_b).unwrap();
        assert!(store_a.apply_ops(
            page_a,
            &[EditOp::Insert {
                pos_u16: 11,
                text: ", written after the frame".into()
            }]
        ));
        let delta = store_a.export_document_updates(page_a, &adopted).unwrap();

        a.queue_ops(uuid, &delta);
        let request = a.publish_request(0, &chain_a).unwrap();
        a.absorb_publish(&relay.accept_publish(&request)).unwrap();

        let events = b
            .absorb_deltas(
                &relay.serve_fetch(0),
                &mut store_b,
                &mut chain_b,
                &mut packages_b,
                &mut None,
                &[],
                0,
            )
            .unwrap();
        assert!(events.contains(&SyncEvent::Applied(uuid)));

        // The same batch served again is an echo and reports nothing.
        let echo = b
            .absorb_deltas(
                &relay.serve_fetch(0),
                &mut store_b,
                &mut chain_b,
                &mut packages_b,
                &mut None,
                &[],
                0,
            )
            .unwrap();
        assert!(
            !echo
                .iter()
                .any(|event| matches!(event, SyncEvent::Applied(_))),
            "operations already held are not an arrival"
        );

        // Draining made B's view current, so the terminal gate opens; a
        // session that never drained stays quiet.
        let signer = Ed25519KeyPair::from_pkcs8(&pkcs8_b).unwrap();
        let mut marker = uuid.as_bytes().to_vec();
        marker.extend_from_slice(&7_000_u64.to_be_bytes());
        let message = persist::signing_domain(TERMINAL_SIGN_CONTEXT, &marker);
        marker.extend_from_slice(signer.sign(&message).as_ref());
        assert!(b.queue_terminal(uuid, &marker));
        let mut never_drained = session("fp-c");
        assert!(!never_drained.queue_terminal(uuid, &marker));

        // B's marker kills the page on A only under B's trusted identity.
        let request = b.publish_request(0, &chain_b).unwrap();
        b.absorb_publish(&relay.accept_publish(&request)).unwrap();
        let (pkcs8_a, _) = identity();
        let mut packages_a = KeyPackageKeeper::mint(&pkcs8_a).unwrap();
        let events = a
            .absorb_deltas(
                &relay.serve_fetch(1),
                &mut store_a,
                &mut chain_a,
                &mut packages_a,
                &mut None,
                &[],
                0,
            )
            .unwrap();
        assert!(
            !events.iter().any(|e| matches!(e, SyncEvent::Terminal(_))),
            "an untrusted marker must kill nothing"
        );
        let events = a
            .absorb_deltas(
                &relay.serve_fetch(1),
                &mut store_a,
                &mut chain_a,
                &mut packages_a,
                &mut None,
                std::slice::from_ref(&identity_b),
                0,
            )
            .unwrap();
        assert!(events.contains(&SyncEvent::Terminal(uuid)));
        // Absorbing: nothing lands on the page again.
        assert!(!a.queue_terminal(uuid, &marker));
    }

    #[test]
    fn a_peers_delete_only_batch_is_still_an_arrival() {
        // A deletion must advance `document_version` as an insert does,
        // so a peer erasing a line still reads as an arrival.
        let clock = ManualClock::new();
        let mut store_a = SheetStore::new(clock.clone());
        let page_a = store_a.new_tab().1;
        assert!(store_a.apply_ops(
            page_a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "a line that will be cut".into()
            }]
        ));
        let uuid = store_a.sheet(page_a).unwrap().uuid();

        let mut store_b = SheetStore::new(clock.clone());
        let page_b = store_b.new_tab().1;
        let pristine = store_b.document_version(page_b).unwrap();
        let full = store_a.export_document_updates(page_a, &pristine).unwrap();
        store_b.adopt_key_frame(page_b, uuid, &full).unwrap();

        let chain_a = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut chain_b = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut a = session("fp-a");
        let mut b = session("fp-b");
        let (pkcs8_b, _) = identity();
        let mut packages_b = KeyPackageKeeper::mint(&pkcs8_b).unwrap();
        let mut relay = FakeRelay::default();

        // B holds the whole line. A now removes part of it and
        // publishes nothing but that removal.
        let adopted = store_b.document_version(page_b).unwrap();
        assert!(store_a.apply_ops(
            page_a,
            &[EditOp::Delete {
                pos_u16: 0,
                len_u16: 7
            }]
        ));
        let delta = store_a.export_document_updates(page_a, &adopted).unwrap();
        a.queue_ops(uuid, &delta);
        let request = a.publish_request(0, &chain_a).unwrap();
        a.absorb_publish(&relay.accept_publish(&request)).unwrap();

        let before = store_b.document_version(page_b).unwrap();
        let events = b
            .absorb_deltas(
                &relay.serve_fetch(0),
                &mut store_b,
                &mut chain_b,
                &mut packages_b,
                &mut None,
                &[],
                0,
            )
            .unwrap();
        assert!(
            events.contains(&SyncEvent::Applied(uuid)),
            "a peer erasing text is another device writing on the page"
        );
        assert_ne!(
            store_b.document_version(page_b).unwrap(),
            before,
            "the frontier moves for a deletion, which is what the event rests on"
        );
        assert_eq!(
            store_b.sheet(page_b).unwrap().segments(),
            [companion_core::Segment::Ink("that will be cut".into())],
            "and the deletion is the one A made"
        );

        // The same batch again is the echo, and an echo removes
        // nothing a second time.
        let echo = b
            .absorb_deltas(
                &relay.serve_fetch(0),
                &mut store_b,
                &mut chain_b,
                &mut packages_b,
                &mut None,
                &[],
                0,
            )
            .unwrap();
        assert!(
            !echo
                .iter()
                .any(|event| matches!(event, SyncEvent::Applied(_))),
            "a deletion already held is not an arrival either"
        );
    }

    #[test]
    fn two_devices_confirm_a_ceremony_at_the_same_stream_position() {
        let clock = ManualClock::new();
        let mut store_a = SheetStore::new(clock.clone());
        let page_a = store_a.new_tab().1;
        assert!(store_a.apply_ops(
            page_a,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "keep DOOMED".into()
            }]
        ));
        assert!(store_a.apply_ops(
            page_a,
            &[EditOp::Delete {
                pos_u16: 4,
                len_u16: 7
            }]
        ));
        let uuid = store_a.sheet(page_a).unwrap().uuid();

        let mut store_b = SheetStore::new(clock.clone());
        let page_b = store_b.new_tab().1;
        let pristine = store_b.document_version(page_b).unwrap();
        let full = store_a.export_document_updates(page_a, &pristine).unwrap();
        store_b.adopt_key_frame(page_b, uuid, &full).unwrap();

        for (store, page) in [(&mut store_a, page_a), (&mut store_b, page_b)] {
            assert!(store.set_compaction_deferred(page, true));
            let tab = store.tabs().next().unwrap().id();
            store.cycle_rung(tab).unwrap();
        }

        let mut chain_a = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut chain_b = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut a = session("fp-a");
        let mut b = session("fp-b");
        let (pkcs8_a, _) = identity();
        let (pkcs8_b, _) = identity();
        let mut packages_a = KeyPackageKeeper::mint(&pkcs8_a).unwrap();
        let mut packages_b = KeyPackageKeeper::mint(&pkcs8_b).unwrap();
        let mut relay = FakeRelay::default();

        // Seed B's channel view of the page with one ops delta.
        a.queue_ops(uuid, &full);
        let request = a.publish_request(0, &chain_a).unwrap();
        a.absorb_publish(&relay.accept_publish(&request)).unwrap();
        b.absorb_deltas(
            &relay.serve_fetch(0),
            &mut store_b,
            &mut chain_b,
            &mut packages_b,
            &mut None,
            &[],
            0,
        )
        .unwrap();

        // A proposes to B, sealing the entropy to both key packages.
        assert!(a.propose_ceremony(
            uuid,
            &[CeremonyPeer {
                fingerprint: "fp-b".into(),
                package: packages_b.package().clone(),
            }],
            &packages_a.package().clone(),
            0,
        ));
        let request = a.publish_request(2_000, &chain_a).unwrap();
        a.absorb_publish(&relay.accept_publish(&request)).unwrap();

        // B drains: opens its entropy, queues its acceptance. Nothing
        // commits yet — B has seen only A's acceptance on the stream.
        let events = b
            .absorb_deltas(
                &relay.serve_fetch(1),
                &mut store_b,
                &mut chain_b,
                &mut packages_b,
                &mut None,
                &[],
                0,
            )
            .unwrap();
        assert!(events.is_empty());
        assert_eq!(chain_b.epoch(), 0);
        let request = b.publish_request(2_000, &chain_b).unwrap();
        b.absorb_publish(&relay.accept_publish(&request)).unwrap();

        // Both devices now drain to the same stream frontier and
        // commit at the same position: compact, advance, reseal.
        let events = a
            .absorb_deltas(
                &relay.serve_fetch(1),
                &mut store_a,
                &mut chain_a,
                &mut packages_a,
                &mut None,
                &[],
                0,
            )
            .unwrap();
        assert!(events.contains(&SyncEvent::CeremonyCommitted(uuid)));
        let events = b
            .absorb_deltas(
                &relay.serve_fetch(3),
                &mut store_b,
                &mut chain_b,
                &mut packages_b,
                &mut None,
                &[],
                0,
            )
            .unwrap();
        assert!(events.contains(&SyncEvent::CeremonyCommitted(uuid)));
        assert_eq!(chain_a.epoch(), 1);
        assert_eq!(chain_b.epoch(), 1);

        // The proposer's frame is sealed under the incoming key.
        let frame = a.take_frame().unwrap();
        let opened = chain_b.open(&frame).unwrap();
        let contains = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
        assert!(!contains(&opened, b"DOOMED"));
        relay.epoch = 1;
        let request = a.publish_frame_request(&chain_a, &frame).unwrap();
        assert!(request.url.ends_with("/channel/frame"));
    }

    #[test]
    fn the_attach_roster_becomes_ceremony_peers_only_through_the_pairing_records() {
        let mut session = session("fp-a");
        let (pkcs8_b, identity_b) = identity();
        let (_, wrong_identity) = identity();
        let keeper_b = KeyPackageKeeper::mint(&pkcs8_b).unwrap();
        let package_value = serde_json::to_value(ByteBlob(keeper_b.package().encode())).unwrap();
        let body = serde_json::json!({
            "epoch": 2,
            "frame_present": false,
            "next_seq": 0,
            "peers": [
                {"device": "fp-b", "key_package": package_value, "attached_ms": 1_000},
            ],
        });
        session
            .absorb_attach(&HttpResponse {
                status: 200,
                body: body.to_string().into_bytes(),
            })
            .unwrap();
        assert!(session.attached());
        assert_eq!(session.attach_epoch(), Some(2));
        assert_eq!(session.frame_present(), Some(false));
        assert_eq!(session.attach_roster().len(), 1);

        // The roster alone admits nobody: no pairing record, no peer.
        assert!(session.ceremony_peers(&[]).is_empty());
        // A package that fails its recorded identity is dropped — the
        // relay-substitution shape.
        assert!(
            session
                .ceremony_peers(&[("fp-b".into(), wrong_identity)])
                .is_empty()
        );
        // The recorded identity admits it.
        let peers = session.ceremony_peers(&[("fp-b".into(), identity_b)]);
        assert_eq!(peers.len(), 1);
        assert_eq!(peers[0].fingerprint, "fp-b");
    }

    #[test]
    fn a_proposal_for_a_page_this_device_does_not_hold_spends_nothing() {
        let clock = ManualClock::new();
        let mut store_a = SheetStore::new(clock.clone());
        let page_a = store_a.new_tab().1;
        let uuid = store_a.sheet(page_a).unwrap().uuid();
        // B never adopted A's page; its store holds only its own.
        let mut store_b = SheetStore::new(clock.clone());
        let _ = store_b.new_tab();

        let chain_a = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut chain_b = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut a = session("fp-a");
        let mut b = session("fp-b");
        let (pkcs8_a, _) = identity();
        let (pkcs8_b, _) = identity();
        let packages_a = KeyPackageKeeper::mint(&pkcs8_a).unwrap();
        let mut packages_b = KeyPackageKeeper::mint(&pkcs8_b).unwrap();
        let mut relay = FakeRelay::default();

        assert!(a.propose_ceremony(
            uuid,
            &[CeremonyPeer {
                fingerprint: "fp-b".into(),
                package: packages_b.package().clone(),
            }],
            &packages_a.package().clone(),
            0,
        ));
        let request = a.publish_request(0, &chain_a).unwrap();
        a.absorb_publish(&relay.accept_publish(&request)).unwrap();

        // B stays out of a proposal for a page it does not hold, and
        // its package is not spent.
        b.absorb_deltas(
            &relay.serve_fetch(0),
            &mut store_b,
            &mut chain_b,
            &mut packages_b,
            &mut None,
            &[],
            0,
        )
        .unwrap();
        assert!(
            b.publish_request(2_000, &chain_b).is_none(),
            "nothing to publish: no acceptance was queued"
        );
        let sealed = packages_b.package().seal_entropy(b"still mine").unwrap();
        assert_eq!(
            packages_b.open_entropy(&sealed).unwrap().as_slice(),
            b"still mine"
        );
    }

    #[test]
    fn a_device_joins_a_ballot_sealed_to_the_package_it_has_not_heard_accepted() {
        let clock = ManualClock::new();
        let mut store_a = SheetStore::new(clock.clone());
        let page_a = store_a.new_tab().1;
        let uuid = store_a.sheet(page_a).unwrap().uuid();
        let mut store_b = SheetStore::new(clock.clone());
        let page_b = store_b.new_tab().1;
        let pristine = store_b.document_version(page_b).unwrap();
        let full = store_a.export_document_updates(page_a, &pristine).unwrap();
        store_b.adopt_key_frame(page_b, uuid, &full).unwrap();

        let chain_a = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut chain_b = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut a = session("fp-a");
        let mut b = session("fp-b");
        let (pkcs8_a, _) = identity();
        let (pkcs8_b, _) = identity();
        let packages_a = KeyPackageKeeper::mint(&pkcs8_a).unwrap();
        // B's standing package is the one before; the roster names the
        // pending one, whose acceptance B never heard.
        let mut standing_b = KeyPackageKeeper::mint(&pkcs8_b).unwrap();
        let mut pending_b = Some(KeyPackageKeeper::mint(&pkcs8_b).unwrap());
        let named = pending_b.as_ref().unwrap().package().clone();
        let mut relay = FakeRelay::default();

        assert!(a.propose_ceremony(
            uuid,
            &[CeremonyPeer {
                fingerprint: "fp-b".into(),
                package: named.clone(),
            }],
            &packages_a.package().clone(),
            0,
        ));
        let request = a.publish_request(0, &chain_a).unwrap();
        a.absorb_publish(&relay.accept_publish(&request)).unwrap();

        b.absorb_deltas(
            &relay.serve_fetch(0),
            &mut store_b,
            &mut chain_b,
            &mut standing_b,
            &mut pending_b,
            &[],
            0,
        )
        .unwrap();
        assert!(
            b.publish_request(2_000, &chain_b).is_some(),
            "B opened its entry and queued its acceptance"
        );
        assert!(pending_b.is_none());
        assert_eq!(standing_b.package(), &named);
    }

    #[test]
    fn a_ballot_that_outlives_its_patience_abandons_onto_the_old_gop() {
        let mut a = session("fp-a");
        let (pkcs8, _) = identity();
        let packages = KeyPackageKeeper::mint(&pkcs8).unwrap();
        let page = ItemId::random();
        assert!(a.propose_ceremony(
            page,
            &[CeremonyPeer {
                fingerprint: "fp-b".into(),
                package: packages.package().clone(),
            }],
            &packages.package().clone(),
            0,
        ));
        a.tick(BALLOT_PATIENCE_MS - 1);
        assert!(
            !a.propose_ceremony(page, &[], &packages.package().clone(), 0),
            "one ballot at a time"
        );
        a.tick(BALLOT_PATIENCE_MS);
        // Abandoned: the next transition may propose again.
        assert!(a.propose_ceremony(
            page,
            &[CeremonyPeer {
                fingerprint: "fp-b".into(),
                package: packages.package().clone(),
            }],
            &packages.package().clone(),
            BALLOT_PATIENCE_MS,
        ));
    }
}
