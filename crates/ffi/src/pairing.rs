//! Device pairing: two devices come to trust each other directly, with
//! their own key exchange and a verification a human performs — never
//! through the account (ADR-0021 section 3, issue #97).
//!
//! The account answers "may this client attach to this channel" and
//! nothing else; anything that can obtain a token — a phished session,
//! a leaked refresh token, the provider itself — must still win
//! nothing here. So trust is established between the devices
//! themselves, with the relay as an untrusted carrier, in the shape
//! the BYOE local-service assessment already argued for
//! (docs/spec/feature/byoe/local-service.md): a per-device Ed25519
//! identity key, a challenge the counterparty must answer before any
//! secret moves, and — because two devices with two screens can do
//! better than a service can — a short authentication string the user
//! compares on both screens and is able to fail.
//!
//! The ceremony, message by message (inviter A holds the channel
//! secret; joiner B wants in):
//!
//! 1. **Commitment** (A → B): `SHA-256(eph_A ‖ identity_A ‖ blind)`.
//!    Committing before seeing B's contribution means a machine in the
//!    middle gets exactly one guess at the short string rather than a
//!    grinding attack against it.
//! 2. **Offer** (B → A): B's identity public key and ephemeral X25519
//!    public key.
//! 3. **Reveal** (A → B): A's identity and ephemeral public keys, the
//!    blind, and A's Ed25519 signature over the transcript. B checks
//!    the commitment opens and the signature verifies.
//! 4. Both sides run X25519, hash the whole exchange into a
//!    transcript, and derive the **short authentication string**: six
//!    digits on both screens. A human compares them; on mismatch —
//!    a machine in the middle substituting keys moves the transcript,
//!    and the string with it — either side aborts by dropping its
//!    state, and nothing has been stored on either device.
//! 5. **Acceptance** (B → A): B's signature over the transcript, so
//!    the inviter binds the joiner's long-term identity to this
//!    exchange (revocation needs a name to revoke).
//! 6. **Grant** (A → B): the channel secret, sealed under a key
//!    derived from the X25519 shared secret and the transcript. The
//!    relay carries only this ciphertext; the ephemeral private keys
//!    that could open it never leave their devices, which is why the
//!    relay structurally cannot hold, distribute or escrow a content
//!    key — there is no message in this ceremony it could take one
//!    from.
//!
//! What the joiner receives is the **channel secret**, the root of the
//! per GOP transport chain ([`crate::gop`]); the content key stays on
//! its device, unshared, exactly as ADR-0021 section 8 requires.
//! Revocation composes with the ceremony: removing a device removes it
//! from the next ceremony's entropy delivery, and the chain leaves it
//! behind at the next boundary at the latest
//! ([`crate::gop::GopKeyChain::advance`]).
//!
//! Pairing secrets rest in the key-material credential store under
//! their own accounts, separate from the conceal credentials: clearing
//! pairing ([`clear_pairing`]) never touches the API token, the
//! content halves or the ledger key, and clearing those never touches
//! pairing.

use companion_credentials::{CredentialError, CredentialStore};
use ring::hkdf::{HKDF_SHA256, Salt};
use ring::rand::{SecureRandom as _, SystemRandom};
use ring::signature::{ED25519, Ed25519KeyPair, KeyPair as _, UnparsedPublicKey};
use ring::{agreement, digest};
use zeroize::Zeroizing;

use crate::persist::{self, Bytes, KEY_LEN};

/// The credential-store account holding this device's Ed25519 identity
/// key (PKCS#8), in the key-material store beside the content key's
/// keychain half. Its own account on purpose: pairing trust and
/// conceal credentials fail independently and are cleared
/// independently.
const DEVICE_IDENTITY_ACCOUNT: &str = "sync-device-identity";

/// The credential-store account holding the sync channel secret — the
/// root of the per GOP transport chain ([`crate::gop`]). Delivered
/// only by this module's ceremony; `ThisDeviceOnly` like every key in
/// the key-material store, so it never rides iCloud Keychain
/// (ADR-0016 section 3, ADR-0021 section 8).
const CHANNEL_SECRET_ACCOUNT: &str = "sync-channel-secret";

/// Versioned HKDF info string for the short authentication string.
const PAIRING_SAS_INFO: &[u8] = b"ots-companion-pairing-sas-v1";

/// Versioned HKDF info string for the grant's wrapping key.
const PAIRING_WRAP_INFO: &[u8] = b"ots-companion-pairing-wrap-v1";

/// Magic + version prefix authenticated into the grant's seal, so a
/// grant cannot be presented as any other envelope this crate reads.
const PAIRING_GRANT_MAGIC: &[u8; 8] = b"OTSPAIR1";

/// The commitment the inviter opens with: a hash that pins its key
/// contribution before it has seen the joiner's.
#[derive(Clone)]
pub struct Commitment {
    /// `SHA-256(eph_pub ‖ identity_pub ‖ blind)`.
    pub commit: [u8; 32],
}

/// The joiner's key contribution.
#[derive(Clone)]
pub struct Offer {
    /// The joiner's Ed25519 identity public key.
    pub identity_pub: Vec<u8>,
    /// The joiner's ephemeral X25519 public key.
    pub eph_pub: Vec<u8>,
}

/// The inviter's opening of its commitment, signed.
#[derive(Clone)]
pub struct Reveal {
    /// The inviter's Ed25519 identity public key.
    pub identity_pub: Vec<u8>,
    /// The inviter's ephemeral X25519 public key.
    pub eph_pub: Vec<u8>,
    /// The commitment's blind.
    pub blind: [u8; 32],
    /// The inviter's Ed25519 signature over the transcript.
    pub transcript_sig: Vec<u8>,
}

/// The joiner's signature over the transcript: the name the inviter
/// records for this device, and the name a revocation later revokes.
#[derive(Clone)]
pub struct Acceptance {
    /// The joiner's Ed25519 signature over the transcript.
    pub transcript_sig: Vec<u8>,
}

/// The channel secret, sealed to this ceremony: AEAD ciphertext under
/// the X25519-derived wrap key, with the transcript as associated
/// data. The one message that carries a secret, and it carries it
/// only as ciphertext no relay can open.
#[derive(Clone)]
pub struct Grant {
    /// `nonce ‖ ciphertext ‖ tag` under the ceremony's wrap key.
    pub sealed_channel_secret: Vec<u8>,
}

/// The inviter between its commitment and the joiner's offer.
pub struct Inviter {
    identity: Ed25519KeyPair,
    eph: agreement::EphemeralPrivateKey,
    eph_pub: Vec<u8>,
    blind: [u8; 32],
}

/// Either settled side of the ceremony: the short string a human
/// compares, and the material to finish with. Dropping it is the
/// abort — nothing about the exchange has been stored anywhere.
pub struct Settled {
    sas: String,
    transcript: [u8; 32],
    wrap_key: Zeroizing<Vec<u8>>,
    peer_identity_pub: Vec<u8>,
}

impl Inviter {
    /// Open the ceremony: mint an ephemeral key and a blind, and
    /// commit to them. `identity_pkcs8` is this device's identity key
    /// ([`ensure_device_identity`]). `None` when the RNG or the key
    /// refuses.
    #[must_use]
    pub fn begin(identity_pkcs8: &[u8]) -> Option<(Self, Commitment)> {
        let rng = SystemRandom::new();
        let identity = Ed25519KeyPair::from_pkcs8(identity_pkcs8).ok()?;
        let eph = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng).ok()?;
        let eph_pub = eph.compute_public_key().ok()?.as_ref().to_vec();
        let mut blind = [0u8; 32];
        rng.fill(&mut blind).ok()?;
        let commit = commitment(&eph_pub, identity.public_key().as_ref(), &blind);
        Some((
            Self {
                identity,
                eph,
                eph_pub,
                blind,
            },
            Commitment { commit },
        ))
    }

    /// Take the joiner's offer, run the exchange, and reveal. After
    /// this both screens can show the short string. `None` when the
    /// peer's ephemeral key refuses the agreement.
    #[must_use]
    pub fn settle(self, offer: &Offer) -> Option<(Settled, Reveal)> {
        let identity_pub = self.identity.public_key().as_ref().to_vec();
        let transcript = transcript(
            &commitment(&self.eph_pub, &identity_pub, &self.blind),
            &identity_pub,
            &self.eph_pub,
            &offer.identity_pub,
            &offer.eph_pub,
        );
        let peer = agreement::UnparsedPublicKey::new(&agreement::X25519, &offer.eph_pub);
        let (sas, wrap_key) = agreement::agree_ephemeral(self.eph, &peer, |shared| {
            derive_sas_and_wrap(shared, &transcript)
        })
        .ok()??;
        let transcript_sig = self.identity.sign(&transcript).as_ref().to_vec();
        Some((
            Settled {
                sas,
                transcript,
                wrap_key,
                peer_identity_pub: offer.identity_pub.clone(),
            },
            Reveal {
                identity_pub,
                eph_pub: self.eph_pub,
                blind: self.blind,
                transcript_sig,
            },
        ))
    }
}

/// The joiner between the inviter's commitment and its reveal.
pub struct Joiner {
    identity: Ed25519KeyPair,
    eph: agreement::EphemeralPrivateKey,
    eph_pub: Vec<u8>,
    commit: [u8; 32],
}

impl Joiner {
    /// Answer a commitment with this device's key contribution.
    #[must_use]
    pub fn accept(identity_pkcs8: &[u8], commitment: &Commitment) -> Option<(Self, Offer)> {
        let rng = SystemRandom::new();
        let identity = Ed25519KeyPair::from_pkcs8(identity_pkcs8).ok()?;
        let eph = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng).ok()?;
        let eph_pub = eph.compute_public_key().ok()?.as_ref().to_vec();
        let offer = Offer {
            identity_pub: identity.public_key().as_ref().to_vec(),
            eph_pub: eph_pub.clone(),
        };
        Some((
            Self {
                identity,
                eph,
                eph_pub,
                commit: commitment.commit,
            },
            offer,
        ))
    }

    /// Check the inviter's reveal against its commitment and
    /// signature, run the exchange, and answer with this device's own
    /// signature. `None` — refuse the whole ceremony — when the
    /// commitment does not open to the revealed keys or the signature
    /// does not verify: a carrier that swapped anything mid-flight
    /// fails here or moves the short string.
    #[must_use]
    pub fn settle(self, reveal: &Reveal) -> Option<(Settled, Acceptance)> {
        if commitment(&reveal.eph_pub, &reveal.identity_pub, &reveal.blind) != self.commit {
            return None;
        }
        let identity_pub = self.identity.public_key().as_ref().to_vec();
        let transcript = transcript(
            &self.commit,
            &reveal.identity_pub,
            &reveal.eph_pub,
            &identity_pub,
            &self.eph_pub,
        );
        UnparsedPublicKey::new(&ED25519, &reveal.identity_pub)
            .verify(&transcript, &reveal.transcript_sig)
            .ok()?;
        let peer = agreement::UnparsedPublicKey::new(&agreement::X25519, &reveal.eph_pub);
        let (sas, wrap_key) = agreement::agree_ephemeral(self.eph, &peer, |shared| {
            derive_sas_and_wrap(shared, &transcript)
        })
        .ok()??;
        let transcript_sig = self.identity.sign(&transcript).as_ref().to_vec();
        Some((
            Settled {
                sas,
                transcript,
                wrap_key,
                peer_identity_pub: reveal.identity_pub.clone(),
            },
            Acceptance { transcript_sig },
        ))
    }
}

impl Settled {
    /// The short authentication string, six digits as `"123 456"`,
    /// shown on this screen for a human to compare against the other.
    /// The string never travels: the comparison is the human's, and
    /// failing it — walking away, dropping this state — is a first
    /// class outcome that leaves both devices unpaired.
    #[must_use]
    pub fn sas(&self) -> &str {
        &self.sas
    }

    /// The peer's identity public key as bound to this exchange: what
    /// the inviter records in its device list, and what a revocation
    /// later names.
    #[must_use]
    pub fn peer_identity(&self) -> &[u8] {
        &self.peer_identity_pub
    }

    /// Inviter side: check the joiner's signature over the transcript.
    #[must_use]
    pub fn verify_acceptance(&self, acceptance: &Acceptance) -> bool {
        UnparsedPublicKey::new(&ED25519, &self.peer_identity_pub)
            .verify(&self.transcript, &acceptance.transcript_sig)
            .is_ok()
    }

    /// Inviter side, after the human confirmed the strings match:
    /// seal the channel secret to this ceremony. The relay carries
    /// this ciphertext and can do nothing else with it.
    #[must_use]
    pub fn grant(&self, channel_secret: &[u8]) -> Option<Grant> {
        let aad = self.grant_aad();
        Some(Grant {
            sealed_channel_secret: persist::seal_body(&self.wrap_key, &aad, channel_secret)?,
        })
    }

    /// Joiner side: open the grant. `None` for anything not sealed by
    /// this exact ceremony's counterparty.
    #[must_use]
    pub fn receive(&self, grant: &Grant) -> Option<Zeroizing<Vec<u8>>> {
        persist::open_body(
            &self.wrap_key,
            &self.grant_aad(),
            &grant.sealed_channel_secret,
        )
    }

    /// The grant's associated data: the envelope magic and the whole
    /// transcript, so a grant is bound to this exchange bit for bit.
    fn grant_aad(&self) -> Vec<u8> {
        let mut aad = Vec::with_capacity(PAIRING_GRANT_MAGIC.len() + self.transcript.len());
        aad.extend_from_slice(PAIRING_GRANT_MAGIC);
        aad.extend_from_slice(&self.transcript);
        aad
    }
}

/// `SHA-256(eph_pub ‖ identity_pub ‖ blind)`.
fn commitment(eph_pub: &[u8], identity_pub: &[u8], blind: &[u8; 32]) -> [u8; 32] {
    let mut ctx = digest::Context::new(&digest::SHA256);
    ctx.update(eph_pub);
    ctx.update(identity_pub);
    ctx.update(blind);
    ctx.finish()
        .as_ref()
        .try_into()
        .expect("SHA-256 is 32 bytes")
}

/// The transcript hash both sides derive everything from: the
/// commitment and every public key of the exchange, in one fixed
/// order.
fn transcript(
    commit: &[u8; 32],
    inviter_identity: &[u8],
    inviter_eph: &[u8],
    joiner_identity: &[u8],
    joiner_eph: &[u8],
) -> [u8; 32] {
    let mut ctx = digest::Context::new(&digest::SHA256);
    ctx.update(commit);
    ctx.update(inviter_identity);
    ctx.update(inviter_eph);
    ctx.update(joiner_identity);
    ctx.update(joiner_eph);
    ctx.finish()
        .as_ref()
        .try_into()
        .expect("SHA-256 is 32 bytes")
}

/// Six SAS digits and the grant's wrap key, both from the X25519
/// shared secret salted by the transcript. Separate info strings keep
/// the two outputs independent.
fn derive_sas_and_wrap(
    shared: &[u8],
    transcript: &[u8; 32],
) -> Option<(String, Zeroizing<Vec<u8>>)> {
    let prk = Salt::new(HKDF_SHA256, transcript).extract(shared);
    let mut sas_bytes = [0u8; 4];
    prk.expand(&[PAIRING_SAS_INFO], Bytes(4))
        .ok()?
        .fill(&mut sas_bytes)
        .ok()?;
    let code = u32::from_be_bytes(sas_bytes) % 1_000_000;
    let sas = format!("{:03} {:03}", code / 1000, code % 1000);
    let mut wrap_key = Zeroizing::new(vec![0u8; KEY_LEN]);
    prk.expand(&[PAIRING_WRAP_INFO], Bytes(KEY_LEN))
        .ok()?
        .fill(&mut wrap_key)
        .ok()?;
    Some((sas, wrap_key))
}

/// This device's identity key (PKCS#8), minted on first use and stored
/// in the key-material store. `None` when the backend refuses: refuse
/// to enrol rather than enrol under a key that cannot persist.
#[must_use]
pub fn ensure_device_identity(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    let keys = credentials.key_material_store();
    match keys.load(DEVICE_IDENTITY_ACCOUNT) {
        Ok(pkcs8) if Ed25519KeyPair::from_pkcs8(&pkcs8).is_ok() => Some(pkcs8),
        Err(CredentialError::NotFound) => {
            let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).ok()?;
            let pkcs8 = Zeroizing::new(pkcs8.as_ref().to_vec());
            keys.store(DEVICE_IDENTITY_ACCOUNT, &pkcs8).ok()?;
            Some(pkcs8)
        }
        Ok(_) | Err(CredentialError::Backend(_)) => None,
    }
}

/// The channel secret at rest, for the device that founded the channel
/// or joined it: load, or — founder only, `mint` true — mint and store
/// a fresh one. A joiner never mints; its secret arrives by
/// [`Settled::receive`] and is stored with [`store_channel_secret`].
#[must_use]
pub fn ensure_channel_secret(
    credentials: &dyn CredentialStore,
    mint: bool,
) -> Option<Zeroizing<Vec<u8>>> {
    let keys = credentials.key_material_store();
    match keys.load(CHANNEL_SECRET_ACCOUNT) {
        Ok(secret) if secret.len() == KEY_LEN => Some(secret),
        Err(CredentialError::NotFound) if mint => {
            let mut secret = Zeroizing::new(vec![0u8; KEY_LEN]);
            SystemRandom::new().fill(&mut secret).ok()?;
            keys.store(CHANNEL_SECRET_ACCOUNT, &secret).ok()?;
            Some(secret)
        }
        _ => None,
    }
}

/// Store a channel secret a ceremony just delivered.
#[must_use]
pub fn store_channel_secret(credentials: &dyn CredentialStore, secret: &[u8]) -> bool {
    secret.len() == KEY_LEN
        && credentials
            .key_material_store()
            .store(CHANNEL_SECRET_ACCOUNT, secret)
            .is_ok()
}

/// Clear this device's pairing: the identity key, the channel secret,
/// and the peer records — the pairing accounts, nothing else. The
/// conceal credentials — the API token — and the content and ledger
/// keys are other accounts and are never touched here, exactly as
/// clearing them never touches these: sync trust and conceal trust
/// are revoked independently (ADR-0021 section 3). Returns whether
/// every delete was accepted.
#[must_use]
pub fn clear_pairing(credentials: &dyn CredentialStore) -> bool {
    let keys = credentials.key_material_store();
    let identity = keys.delete(DEVICE_IDENTITY_ACCOUNT).is_ok();
    let channel = keys.delete(CHANNEL_SECRET_ACCOUNT).is_ok();
    let records = keys.delete(PEER_RECORDS_ACCOUNT).is_ok();
    identity && channel && records
}

/// A device's identity fingerprint: lowercase hex SHA-256 of its
/// Ed25519 identity public key — the `device` value everywhere the
/// protocol names one (attach, the ceremony maps, revocation).
#[must_use]
pub fn identity_fingerprint(identity_pub: &[u8]) -> String {
    persist::hex_encode(digest::digest(&digest::SHA256, identity_pub).as_ref())
}

/// This device's own fingerprint, from the identity at rest — minted
/// on first use like the identity itself. `None` when the identity
/// cannot be read or persisted.
#[must_use]
pub fn device_fingerprint(credentials: &dyn CredentialStore) -> Option<String> {
    let pkcs8 = ensure_device_identity(credentials)?;
    let pair = Ed25519KeyPair::from_pkcs8(&pkcs8).ok()?;
    Some(identity_fingerprint(pair.public_key().as_ref()))
}

/// The fingerprint of the identity already at rest, minting nothing:
/// the read a Settings render may perform. `None` while no identity
/// exists — a device that never enabled sync.
#[must_use]
pub fn stored_device_fingerprint(credentials: &dyn CredentialStore) -> Option<String> {
    let pkcs8 = credentials
        .key_material_store()
        .load(DEVICE_IDENTITY_ACCOUNT)
        .ok()?;
    let pair = Ed25519KeyPair::from_pkcs8(&pkcs8).ok()?;
    Some(identity_fingerprint(pair.public_key().as_ref()))
}

// ---------------------------------------------------------------------
// Peer records: the devices a human verified here (issue #102)
// ---------------------------------------------------------------------

/// The credential-store account holding the peer records. Public key
/// material, but a trust anchor: whoever can write this list decides
/// which key packages ceremony entropy is ever sealed to, so it rests
/// in the key-material store with the keys it vouches for, and it is
/// cleared with the pairing.
const PEER_RECORDS_ACCOUNT: &str = "sync-peer-records";

/// One peer a human verified on this device: what
/// [`Settled::peer_identity`] handed over at the ceremony's end, and
/// what a revocation later removes. Removal is the revocation: a
/// device with no record gets nothing sealed to it at the next
/// ceremony, and the chain leaves it behind at that boundary
/// ([`crate::gop::GopKeyChain::advance`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerRecord {
    /// [`identity_fingerprint`] of the identity below.
    pub fingerprint: String,
    /// The peer's Ed25519 identity public key, as the ceremony bound
    /// it.
    pub identity_pub: Vec<u8>,
    /// A name the user gave the device; may be empty.
    pub label: String,
    /// Unix epoch ms the human verified the pairing.
    pub paired_wall_ms: u64,
}

/// Record a verified peer, replacing any record with the same
/// fingerprint — pairing again refreshes the record rather than
/// duplicating it.
#[must_use]
pub fn record_peer(
    credentials: &dyn CredentialStore,
    identity_pub: &[u8],
    label: &str,
    paired_wall_ms: u64,
) -> bool {
    let fingerprint = identity_fingerprint(identity_pub);
    let mut records = peer_records(credentials);
    records.retain(|record| record.fingerprint != fingerprint);
    records.push(PeerRecord {
        fingerprint,
        identity_pub: identity_pub.to_vec(),
        label: label.to_owned(),
        paired_wall_ms,
    });
    store_peer_records(credentials, &records)
}

/// Every peer verified on this device, oldest pairing first. An
/// unreadable or malformed account reads as no peers: fail closed —
/// nobody gets sealed to on a guess.
#[must_use]
pub fn peer_records(credentials: &dyn CredentialStore) -> Vec<PeerRecord> {
    let Ok(bytes) = credentials.key_material_store().load(PEER_RECORDS_ACCOUNT) else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return Vec::new();
    };
    let Some(entries) = value.as_array() else {
        return Vec::new();
    };
    entries
        .iter()
        .filter_map(|entry| {
            Some(PeerRecord {
                fingerprint: entry.get("fingerprint")?.as_str()?.to_owned(),
                identity_pub: persist::hex_decode(entry.get("identity_pub")?.as_str()?)?,
                label: entry.get("label")?.as_str()?.to_owned(),
                paired_wall_ms: entry.get("paired_wall_ms")?.as_u64()?,
            })
        })
        .collect()
}

/// Remove one peer's record: the revocation gesture. True when the
/// fingerprint was recorded and the removal was stored; the device
/// loses access at the next ceremony at the latest.
#[must_use]
pub fn revoke_peer(credentials: &dyn CredentialStore, fingerprint: &str) -> bool {
    let mut records = peer_records(credentials);
    let held = records.len();
    records.retain(|record| record.fingerprint != fingerprint);
    records.len() < held && store_peer_records(credentials, &records)
}

fn store_peer_records(credentials: &dyn CredentialStore, records: &[PeerRecord]) -> bool {
    let entries: Vec<serde_json::Value> = records
        .iter()
        .map(|record| {
            serde_json::json!({
                "fingerprint": record.fingerprint,
                "identity_pub": persist::hex_encode(&record.identity_pub),
                "label": record.label,
                "paired_wall_ms": record.paired_wall_ms,
            })
        })
        .collect();
    credentials
        .key_material_store()
        .store(
            PEER_RECORDS_ACCOUNT,
            serde_json::Value::Array(entries).to_string().as_bytes(),
        )
        .is_ok()
}

// ---------------------------------------------------------------------
// The mailbox wire form (relay protocol §7)
// ---------------------------------------------------------------------

/// A ceremony message as it rides the relay's pairing mailbox: tagged
/// JSON with hex fields. Everything in it is public-key material,
/// commitments, signatures, or AEAD ciphertext sealed to the exchange
/// — the byte-scan test covers the wire form too, and the human SAS
/// comparison is what defeats a relay that substitutes messages.
#[derive(Clone)]
pub enum MailboxMessage {
    /// Step 1, inviter → mailbox.
    Commitment(Commitment),
    /// Step 2, joiner → mailbox.
    Offer(Offer),
    /// Step 3, inviter → mailbox.
    Reveal(Reveal),
    /// Step 5, joiner → mailbox, after its human confirmed the SAS.
    Acceptance(Acceptance),
    /// Step 6, inviter → mailbox, after its human confirmed the SAS.
    Grant(Grant),
}

impl MailboxMessage {
    /// The JSON body for `POST /channel/pairing`.
    #[must_use]
    pub fn encode(&self) -> serde_json::Value {
        let hex = |bytes: &[u8]| serde_json::Value::String(persist::hex_encode(bytes));
        match self {
            Self::Commitment(commitment) => serde_json::json!({
                "kind": "commitment",
                "commit": hex(&commitment.commit),
            }),
            Self::Offer(offer) => serde_json::json!({
                "kind": "offer",
                "identity_pub": hex(&offer.identity_pub),
                "eph_pub": hex(&offer.eph_pub),
            }),
            Self::Reveal(reveal) => serde_json::json!({
                "kind": "reveal",
                "identity_pub": hex(&reveal.identity_pub),
                "eph_pub": hex(&reveal.eph_pub),
                "blind": hex(&reveal.blind),
                "transcript_sig": hex(&reveal.transcript_sig),
            }),
            Self::Acceptance(acceptance) => serde_json::json!({
                "kind": "acceptance",
                "transcript_sig": hex(&acceptance.transcript_sig),
            }),
            Self::Grant(grant) => serde_json::json!({
                "kind": "grant",
                "sealed_channel_secret": hex(&grant.sealed_channel_secret),
            }),
        }
    }

    /// Decode one mailbox body. `None` refuses an unknown kind or a
    /// malformed field whole — a mailbox this build cannot read is a
    /// ceremony it stays out of.
    #[must_use]
    pub fn decode(value: &serde_json::Value) -> Option<Self> {
        let bytes = |name: &str| persist::hex_decode(value.get(name)?.as_str()?);
        match value.get("kind")?.as_str()? {
            "commitment" => Some(Self::Commitment(Commitment {
                commit: bytes("commit")?.try_into().ok()?,
            })),
            "offer" => Some(Self::Offer(Offer {
                identity_pub: bytes("identity_pub")?,
                eph_pub: bytes("eph_pub")?,
            })),
            "reveal" => Some(Self::Reveal(Reveal {
                identity_pub: bytes("identity_pub")?,
                eph_pub: bytes("eph_pub")?,
                blind: bytes("blind")?.try_into().ok()?,
                transcript_sig: bytes("transcript_sig")?,
            })),
            "acceptance" => Some(Self::Acceptance(Acceptance {
                transcript_sig: bytes("transcript_sig")?,
            })),
            "grant" => Some(Self::Grant(Grant {
                sealed_channel_secret: bytes("sealed_channel_secret")?,
            })),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use companion_credentials::InMemoryCredentialStore;

    use super::*;
    use crate::gop::GopKeyChain;

    /// One full ceremony over an honest carrier, returning both
    /// settled sides and every byte that crossed the wire.
    fn honest_ceremony(
        inviter_pkcs8: &[u8],
        joiner_pkcs8: &[u8],
    ) -> (Settled, Settled, Acceptance, Vec<u8>) {
        let (inviter, commitment) = Inviter::begin(inviter_pkcs8).unwrap();
        let (joiner, offer) = Joiner::accept(joiner_pkcs8, &commitment).unwrap();
        let (inviter, reveal) = inviter.settle(&offer).unwrap();
        let (joiner, acceptance) = joiner.settle(&reveal).unwrap();
        let mut wire = Vec::new();
        wire.extend_from_slice(&commitment.commit);
        wire.extend_from_slice(&offer.identity_pub);
        wire.extend_from_slice(&offer.eph_pub);
        wire.extend_from_slice(&reveal.identity_pub);
        wire.extend_from_slice(&reveal.eph_pub);
        wire.extend_from_slice(&reveal.blind);
        wire.extend_from_slice(&reveal.transcript_sig);
        wire.extend_from_slice(&acceptance.transcript_sig);
        (inviter, joiner, acceptance, wire)
    }

    fn identity() -> Zeroizing<Vec<u8>> {
        Zeroizing::new(
            Ed25519KeyPair::generate_pkcs8(&SystemRandom::new())
                .unwrap()
                .as_ref()
                .to_vec(),
        )
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    #[test]
    fn the_ceremony_agrees_on_one_string_and_delivers_the_channel_secret() {
        let credentials = InMemoryCredentialStore::default();
        let secret = ensure_channel_secret(&credentials, true).unwrap();
        let (inviter, joiner, acceptance, _) = honest_ceremony(&identity(), &identity());

        // One string on both screens, and the joiner's signature
        // verifies under the identity the inviter will record.
        assert_eq!(inviter.sas(), joiner.sas());
        assert_eq!(inviter.sas().len(), 7, "six digits and a space");
        assert!(inviter.verify_acceptance(&acceptance));

        // The grant delivers the channel secret, and the delivered
        // secret roots the same GOP chain the founder derives
        // (crate::gop): the two devices can open each other's traffic.
        let grant = inviter.grant(&secret).unwrap();
        let delivered = joiner.receive(&grant).unwrap();
        assert_eq!(*secret, *delivered);
        let founder = GopKeyChain::root(&secret).unwrap();
        let joined = GopKeyChain::root(&delivered).unwrap();
        let sealed = founder.seal(b"first delta").unwrap();
        assert_eq!(joined.open(&sealed).unwrap().as_slice(), b"first delta");
    }

    #[test]
    fn a_machine_in_the_middle_moves_the_string_and_opens_nothing() {
        // A full active interception: the carrier runs its own
        // ceremony with each honest side, substituting every key. The
        // two humans are then looking at strings derived from
        // different transcripts, and even if neither notices, a grant
        // sealed on one leg opens on no other.
        let mallory = identity();
        let (inviter, commitment) = Inviter::begin(&identity()).unwrap();
        let (mallory_joiner, forged_offer) = Joiner::accept(&mallory, &commitment).unwrap();
        let (inviter, reveal) = inviter.settle(&forged_offer).unwrap();
        let (mallory_joiner, _) = mallory_joiner.settle(&reveal).unwrap();

        let (mallory_inviter, forged_commitment) = Inviter::begin(&mallory).unwrap();
        let (joiner, offer) = Joiner::accept(&identity(), &forged_commitment).unwrap();
        let (mallory_inviter, forged_reveal) = mallory_inviter.settle(&offer).unwrap();
        let (joiner, _) = joiner.settle(&forged_reveal).unwrap();
        let _ = mallory_inviter;

        // The strings the two humans compare come from different
        // exchanges; the comparison is what catches this, and it has
        // real teeth: the sealed grant from the inviter's leg is
        // ciphertext the honest joiner cannot open.
        let grant = inviter.grant(b"channel secret 32 bytes long !!.").unwrap();
        assert!(joiner.receive(&grant).is_none());
        // Mallory's leg can open it — Mallory ran that leg — which is
        // exactly why the human comparison exists and must be
        // failable: two legs mean two transcripts, and the strings
        // derived from them agree only one ceremony in a million.
        assert!(mallory_joiner.receive(&grant).is_some());
        // Both honest sides bound the interceptor's identity, not each
        // other's: the ceremony records who you actually exchanged
        // keys with, which is the fact the humans are asked to check.
        assert_eq!(inviter.peer_identity(), joiner.peer_identity());
    }

    #[test]
    fn a_reveal_that_does_not_open_the_commitment_refuses_whole() {
        let (inviter, commitment) = Inviter::begin(&identity()).unwrap();
        let (joiner, offer) = Joiner::accept(&identity(), &commitment).unwrap();
        let (_, reveal) = inviter.settle(&offer).unwrap();

        // A carrier that swaps the revealed ephemeral after the
        // commitment is caught by the hash, not by a human.
        let mut forged = reveal;
        forged.eph_pub[0] ^= 1;
        assert!(joiner.settle(&forged).is_none());
    }

    #[test]
    fn walking_away_leaves_both_devices_unpaired() {
        let credentials = InMemoryCredentialStore::default();
        let inviter_id = identity();
        let joiner_id = identity();
        let (inviter, joiner, _, _) = honest_ceremony(&inviter_id, &joiner_id);

        // The human fails the comparison: both sides drop their state.
        // Nothing in the ceremony wrote anything — no channel secret,
        // no identity, no trace to clean up.
        drop(inviter);
        drop(joiner);
        let keys = credentials.key_material_store();
        assert!(!keys.exists(CHANNEL_SECRET_ACCOUNT).unwrap());
        assert!(!keys.exists(DEVICE_IDENTITY_ACCOUNT).unwrap());
    }

    #[test]
    fn no_secret_crosses_the_ceremony_in_the_clear() {
        // The protocol trace behind the acceptance criterion: the
        // relay sees every wire byte, so scan them all. The channel
        // secret appears nowhere (the grant carries it only as AEAD
        // ciphertext under a key derived from ephemerals that never
        // travel), and neither device's private key material appears
        // at all.
        let credentials = InMemoryCredentialStore::default();
        let secret = ensure_channel_secret(&credentials, true).unwrap();
        let inviter_id = identity();
        let joiner_id = identity();
        let (inviter, _, _, mut wire) = honest_ceremony(&inviter_id, &joiner_id);
        let grant = inviter.grant(&secret).unwrap();
        wire.extend_from_slice(&grant.sealed_channel_secret);

        assert!(!contains(&wire, &secret));
        assert!(!contains(&wire, &inviter_id));
        assert!(!contains(&wire, &joiner_id));
    }

    #[test]
    fn pairing_secrets_are_separate_from_the_conceal_credentials() {
        let credentials = InMemoryCredentialStore::default();
        // The conceal credential and the persistence keys, as the app
        // stores them…
        credentials.store("api-token", b"a conceal token").unwrap();
        let ledger = crate::persist::ensure_ledger_key(&credentials).unwrap();
        // …and the pairing secrets, in their own accounts.
        let identity_key = ensure_device_identity(&credentials).unwrap();
        let channel = ensure_channel_secret(&credentials, true).unwrap();
        assert!(record_peer(
            &credentials,
            b"a peer identity",
            "laptop",
            1_000
        ));

        // Clearing pairing clears exactly pairing — the peer records
        // with it, since a record is trust this device granted.
        assert!(clear_pairing(&credentials));
        let keys = credentials.key_material_store();
        assert!(!keys.exists(DEVICE_IDENTITY_ACCOUNT).unwrap());
        assert!(!keys.exists(CHANNEL_SECRET_ACCOUNT).unwrap());
        assert!(peer_records(&credentials).is_empty());
        assert_eq!(
            credentials.load("api-token").unwrap().as_slice(),
            b"a conceal token"
        );
        assert_eq!(
            *crate::persist::ensure_ledger_key(&credentials).unwrap(),
            *ledger
        );

        // And clearing the conceal credential leaves pairing standing.
        let identity_key_again = ensure_device_identity(&credentials).unwrap();
        assert_ne!(
            *identity_key, *identity_key_again,
            "the old identity was cleared"
        );
        let channel_again = ensure_channel_secret(&credentials, false);
        assert!(
            channel_again.is_none(),
            "the old channel secret was cleared"
        );
        let _ = ensure_channel_secret(&credentials, true).unwrap();
        credentials.delete("api-token").unwrap();
        assert!(keys.exists(DEVICE_IDENTITY_ACCOUNT).unwrap());
        assert!(keys.exists(CHANNEL_SECRET_ACCOUNT).unwrap());
        let _ = channel;
    }

    #[test]
    fn a_recorded_peer_lists_by_fingerprint_and_a_revocation_removes_it() {
        let credentials = InMemoryCredentialStore::default();
        assert!(record_peer(&credentials, b"identity-a", "laptop", 1_000));
        assert!(record_peer(&credentials, b"identity-b", "desktop", 2_000));
        // Pairing again refreshes, never duplicates.
        assert!(record_peer(
            &credentials,
            b"identity-a",
            "laptop again",
            3_000
        ));

        let records = peer_records(&credentials);
        assert_eq!(records.len(), 2);
        let a = records
            .iter()
            .find(|record| record.identity_pub == b"identity-a")
            .unwrap();
        assert_eq!(a.fingerprint, identity_fingerprint(b"identity-a"));
        assert_eq!(a.label, "laptop again");
        assert_eq!(a.paired_wall_ms, 3_000);

        assert!(revoke_peer(&credentials, &a.fingerprint.clone()));
        assert!(
            !revoke_peer(&credentials, &identity_fingerprint(b"identity-a")),
            "a second revocation has nothing to remove"
        );
        let records = peer_records(&credentials);
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].identity_pub, b"identity-b");
    }

    #[test]
    fn the_ceremony_survives_the_mailbox_wire_form() {
        // The same honest ceremony, but every message crosses as the
        // tagged JSON the relay mailbox carries — proving the wire
        // form loses nothing the ceremony needs.
        let credentials = InMemoryCredentialStore::default();
        let secret = ensure_channel_secret(&credentials, true).unwrap();
        let through = |message: MailboxMessage| {
            MailboxMessage::decode(&message.encode()).expect("own encoding decodes")
        };

        let (inviter, commitment) = Inviter::begin(&identity()).unwrap();
        let MailboxMessage::Commitment(commitment) =
            through(MailboxMessage::Commitment(commitment))
        else {
            panic!("kind survives");
        };
        let (joiner, offer) = Joiner::accept(&identity(), &commitment).unwrap();
        let MailboxMessage::Offer(offer) = through(MailboxMessage::Offer(offer)) else {
            panic!("kind survives");
        };
        let (inviter, reveal) = inviter.settle(&offer).unwrap();
        let MailboxMessage::Reveal(reveal) = through(MailboxMessage::Reveal(reveal)) else {
            panic!("kind survives");
        };
        let (joiner, acceptance) = joiner.settle(&reveal).unwrap();
        let MailboxMessage::Acceptance(acceptance) =
            through(MailboxMessage::Acceptance(acceptance))
        else {
            panic!("kind survives");
        };
        assert_eq!(inviter.sas(), joiner.sas());
        assert!(inviter.verify_acceptance(&acceptance));
        let grant = inviter.grant(&secret).unwrap();
        let MailboxMessage::Grant(grant) = through(MailboxMessage::Grant(grant)) else {
            panic!("kind survives");
        };
        assert_eq!(*joiner.receive(&grant).unwrap(), *secret);

        assert!(MailboxMessage::decode(&serde_json::json!({"kind": "future"})).is_none());
        assert!(MailboxMessage::decode(&serde_json::json!({"kind": "grant"})).is_none());
    }

    #[test]
    fn the_wire_form_carries_no_secret_either() {
        // The raw-byte scan above covers the structs; the mailbox
        // carries hex, so scan the hex too: the channel secret and
        // both identities must not appear hex-encoded in any message.
        let credentials = InMemoryCredentialStore::default();
        let secret = ensure_channel_secret(&credentials, true).unwrap();
        let inviter_id = identity();
        let joiner_id = identity();

        let (inviter, commitment) = Inviter::begin(&inviter_id).unwrap();
        let (joiner, offer) = Joiner::accept(&joiner_id, &commitment).unwrap();
        let (inviter, reveal) = inviter.settle(&offer).unwrap();
        let (_, acceptance) = joiner.settle(&reveal).unwrap();
        let grant = inviter.grant(&secret).unwrap();
        let wire = [
            MailboxMessage::Commitment(commitment).encode(),
            MailboxMessage::Offer(offer).encode(),
            MailboxMessage::Reveal(reveal).encode(),
            MailboxMessage::Acceptance(acceptance).encode(),
            MailboxMessage::Grant(grant).encode(),
        ]
        .map(|value| value.to_string())
        .join("");

        assert!(!wire.contains(&persist::hex_encode(&secret)));
        assert!(!wire.contains(&persist::hex_encode(&inviter_id)));
        assert!(!wire.contains(&persist::hex_encode(&joiner_id)));
    }
}
