//! The per GOP transport key: derived at the key frame, rotated at the
//! ceremony, destroyed on rotation (ADR-0021 section 2, issue #95).
//!
//! Every delta and key frame a device publishes is sealed under the
//! channel's current GOP key. The compaction ceremony rotates the key
//! and every device destroys the outgoing one, so whatever ciphertext
//! the relay retains after the boundary — by bug, by backup or by
//! malice — is undecryptable by anyone, the devices that wrote it
//! included. The purge is that derivation, never a promise about a
//! server's disk (ADR-0007, ADR-0021 section 2).
//!
//! The key's lineage is deliberate, and it answers the question issue
//! #95 opens with. It descends from the **pairing ceremony's channel
//! secret** (issue #97), not from the content key: the content key
//! never leaves its device (ADR-0021 section 8) and rests half in a
//! `ThisDeviceOnly` keychain item precisely so that no durable key
//! rides iCloud Keychain (ADR-0016 section 3), while the transport key
//! must be computable by every paired device — including one that has
//! never held a page, which is exactly the enrolling laptop of
//! ADR-0021 section 5. So the root expands from the channel secret,
//! and the channel secret travels only through pairing.
//!
//! Rotation is a chain with fresh entropy mixed in:
//!
//! ```text
//! key[0]   = HKDF(salt: GOP_ROOT_SALT, ikm: channel_secret, info: GOP_KEY_INFO)
//! key[n+1] = HKDF(salt: key[n],        ikm: entropy[n],     info: GOP_KEY_INFO)
//! ```
//!
//! Both inputs are load-bearing. Salting with the outgoing key means a
//! device that never held this GOP's key cannot follow the chain into
//! the next one, so a joiner learns the epoch it joins and nothing
//! behind it — the external-commit property of ADR-0021 section 5.
//! Mixing ceremony-fresh entropy — minted by the proposer, delivered to
//! each surviving device sealed under its pairing secrets, never
//! plaintext through the relay — means a device excluded from the
//! ceremony (a revoked one, issue #97) cannot follow the chain forward
//! even though it holds the outgoing key. And HKDF's one-wayness means
//! the incoming key discloses neither input, so destroying the
//! outgoing key is final. A device that learns of a rotation it did
//! not perform — it slept through the ceremony and the entropy is gone
//! — is behind the boundary for good, and its recovery is the join
//! path: rejoin at the current key frame with a key delivered by
//! pairing, never a derivation from what it kept.
//!
//! The info string and salt live beside the other two versioned info
//! strings in [`crate::persist`], which is where the derivation
//! discipline for this crate is documented; the sealed payload
//! envelope carries its own magic ([`persist::GOP_MAGIC`]) and the
//! GOP epoch, both under the AEAD's associated data.

use companion_core::{Clock, SheetId, SheetStore};
use ring::hkdf::{HKDF_SHA256, Salt};
use zeroize::Zeroizing;

use crate::persist::{self, Bytes, GOP_KEY_INFO, GOP_MAGIC, GOP_ROOT_SALT, KEY_LEN};

/// Length of a sealed GOP payload's authenticated header:
/// `magic[8] ‖ epoch[8]`, big-endian like every other header in this
/// crate.
const GOP_HEADER_LEN: usize = 8 + 8;

/// One channel's transport key chain: the current GOP's key and its
/// epoch, nothing else — the outgoing key is destroyed by the rotation
/// that supersedes it, which is the whole point. Not `Debug`, and not
/// `Clone` for a caller to keep an outgoing key alive by accident; the
/// key material wipes on drop.
pub struct GopKeyChain {
    /// How many ceremonies this chain has crossed: the GOP epoch,
    /// matching [`companion_core::PageChannel`]'s count.
    epoch: u64,
    key: Zeroizing<Vec<u8>>,
}

impl GopKeyChain {
    /// The chain at epoch zero, expanded from the pairing ceremony's
    /// channel secret. Every paired device derives the same chain from
    /// the same secret, which is what lets them open each other's
    /// payloads without the relay ever holding a key. `None` only if
    /// the HKDF refuses, which a 32-byte expansion cannot make it do.
    #[must_use]
    pub fn root(channel_secret: &[u8]) -> Option<Self> {
        let prk = Salt::new(HKDF_SHA256, GOP_ROOT_SALT).extract(channel_secret);
        let okm = prk.expand(&[GOP_KEY_INFO], Bytes(KEY_LEN)).ok()?;
        let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
        okm.fill(&mut key).ok()?;
        Some(Self { epoch: 0, key })
    }

    /// The GOP epoch this chain's key belongs to.
    #[must_use]
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// Rotate at the ceremony: the incoming key is expanded from the
    /// outgoing key and the ceremony's fresh entropy, the epoch
    /// advances, and the outgoing key is destroyed — its buffer wiped
    /// as it drops, so no copy remains to open what the relay
    /// retained. Pure derivation: it cannot fail, which is what lets
    /// the ceremony's two halves (this rotation and the document
    /// rebuild) run as one event with no half-done state between them
    /// ([`ceremony_commit`]).
    pub fn advance(&mut self, entropy: &[u8]) {
        let prk = Salt::new(HKDF_SHA256, &self.key).extract(entropy);
        let mut next = Zeroizing::new(vec![0u8; KEY_LEN]);
        let filled = prk
            .expand(&[GOP_KEY_INFO], Bytes(KEY_LEN))
            .and_then(|okm| okm.fill(&mut next))
            .is_ok();
        debug_assert!(filled, "a 32-byte HKDF expansion has no refusable input");
        // The swap is the destruction: the outgoing key's buffer wipes
        // as it drops.
        self.key = next;
        self.epoch += 1;
    }

    /// Seal a delta or key frame for the relay:
    /// `magic ‖ epoch ‖ nonce ‖ ciphertext ‖ tag`, the header
    /// authenticated as associated data so neither the version nor the
    /// epoch can be edited without failing authentication. `None` when
    /// the system's RNG refuses a nonce, which is a refusal to
    /// publish, never a publish under a reused one.
    #[must_use]
    pub fn seal(&self, plaintext: &[u8]) -> Option<Vec<u8>> {
        let header = self.header();
        let body = persist::seal_body(&self.key, &header, plaintext)?;
        let mut sealed = Vec::with_capacity(header.len() + body.len());
        sealed.extend_from_slice(&header);
        sealed.extend_from_slice(&body);
        Some(sealed)
    }

    /// Open a sealed payload from a peer. `None` for anything that was
    /// not sealed under this chain's current key at this chain's
    /// current epoch — a payload from behind a ceremony boundary is
    /// just ciphertext now, which is the purge working, not an error
    /// to recover from. The plaintext wipes on drop.
    #[must_use]
    pub fn open(&self, sealed: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        let body = sealed.strip_prefix(self.header().as_slice())?;
        persist::open_body(&self.key, &self.header(), body)
    }

    /// The authenticated header at this epoch.
    fn header(&self) -> [u8; GOP_HEADER_LEN] {
        let mut header = [0u8; GOP_HEADER_LEN];
        header[..8].copy_from_slice(GOP_MAGIC);
        header[8..].copy_from_slice(&self.epoch.to_be_bytes());
        header
    }
}

/// The ceremony's two halves as one event (ADR-0021 section 2, issues
/// #95 and #101): rebuild the document and rotate the transport key,
/// in an order that leaves no half-done state. The store's half runs
/// first and is the only fallible step — an unknown or undeferred page
/// returns `None` with the chain untouched, so a refused ceremony
/// rotates nothing. The rotation that follows is pure derivation and
/// cannot fail. The fresh key frame is sealed under the **incoming**
/// key and returned for publication to the relay, where it supersedes
/// its predecessor (ADR-0021 section 5); the outgoing key is already
/// gone by then, destroyed by the advance.
///
/// The caller runs this only on a ceremony every attached device
/// confirmed ([`companion_core::PageChannel::ceremony_confirmed`]),
/// with the entropy the proposer minted for it. Should the seal itself
/// refuse (the RNG declining a nonce), both halves have still
/// happened; the frame is re-sealable from the store
/// ([`SheetStore::export_document_updates`] from an empty frontier, or
/// the next publish), so the refusal costs a retry, never a split
/// state.
pub fn ceremony_commit<C: Clock>(
    store: &mut SheetStore<C>,
    page: SheetId,
    chain: &mut GopKeyChain,
    entropy: &[u8],
) -> Option<Vec<u8>> {
    let frame = store.perform_ceremony(page)?;
    chain.advance(entropy);
    chain.seal(&frame)
}

#[cfg(test)]
mod tests {
    use companion_core::{EditOp, ManualClock};
    use companion_credentials::InMemoryCredentialStore;

    use super::*;

    /// A channel secret as the pairing ceremony would mint it.
    const CHANNEL_SECRET: &[u8; 32] = b"0123456789abcdef0123456789abcdef";

    #[test]
    fn ciphertext_sealed_under_the_outgoing_key_does_not_open_under_the_incoming() {
        let mut chain = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let sealed = chain.seal(b"a delta the relay retained").unwrap();
        // Control: the epoch that sealed it opens it.
        assert_eq!(
            chain.open(&sealed).unwrap().as_slice(),
            b"a delta the relay retained"
        );

        chain.advance(b"ceremony-fresh entropy");
        assert_eq!(chain.epoch(), 1);
        assert!(
            chain.open(&sealed).is_none(),
            "the boundary must make retained ciphertext dead, not merely deleted"
        );

        // And the incoming epoch's traffic is ordinary under the
        // incoming key.
        let fresh = chain.seal(b"the next GOP's delta").unwrap();
        assert_eq!(
            chain.open(&fresh).unwrap().as_slice(),
            b"the next GOP's delta"
        );
    }

    #[test]
    fn every_paired_device_derives_the_same_chain() {
        let mut left = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut right = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let sealed = left.seal(b"hello from the laptop").unwrap();
        assert_eq!(
            right.open(&sealed).unwrap().as_slice(),
            b"hello from the laptop"
        );
        // Through a rotation too, given the same ceremony entropy.
        left.advance(b"entropy one");
        right.advance(b"entropy one");
        let sealed = right.seal(b"hello from the desktop").unwrap();
        assert_eq!(
            left.open(&sealed).unwrap().as_slice(),
            b"hello from the desktop"
        );
    }

    #[test]
    fn a_device_excluded_from_a_ceremony_cannot_follow_the_chain() {
        // The revocation shape (issue #97): the revoked device holds
        // the outgoing key and the root, and still cannot derive the
        // incoming key, because the ceremony's entropy was delivered
        // only to the surviving devices.
        let mut surviving = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut revoked = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        surviving.advance(b"entropy the revoked device never received");
        revoked.advance(b"a guess");
        let sealed = surviving.seal(b"the survivors' traffic").unwrap();
        assert!(revoked.open(&sealed).is_none());
    }

    #[test]
    fn a_gop_rotation_never_touches_the_ledger_key_or_the_content_halves() {
        // The chain's whole API takes explicit bytes and no credential
        // store; this pins that the seam stays that way. Mint the
        // long-lived keys first, run a rotation, and prove every
        // stored secret is bit-for-bit where it was.
        let credentials = InMemoryCredentialStore::default();
        let ledger_before = crate::persist::ensure_ledger_key(&credentials).unwrap();
        let dir = std::env::temp_dir().join(format!("gop-rotation-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let state_path = dir.join("state.sealed");
        let state_before = crate::persist::ensure_state_key(&credentials, &state_path).unwrap();

        let mut chain = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        chain.advance(b"a ceremony");

        let ledger_after = crate::persist::load_ledger_key(&credentials).unwrap();
        let state_after = crate::persist::load_state_key(&credentials, &state_path).unwrap();
        assert_eq!(*ledger_before, *ledger_after);
        assert_eq!(*state_before, *state_after);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_ceremony_rotates_and_rebuilds_as_one_event_or_not_at_all() {
        let mut store = SheetStore::new(ManualClock::new());
        let page = store.new_tab().unwrap().1;
        assert!(store.apply_ops(
            page,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "keep DOOMED".into(),
            }],
        ));
        assert!(store.apply_ops(
            page,
            &[EditOp::Delete {
                pos_u16: 4,
                len_u16: 7,
            }],
        ));
        let mut chain = GopKeyChain::root(CHANNEL_SECRET).unwrap();

        // A page not deferred to a channel refuses, and the refusal
        // rotates nothing: no half-done state.
        assert!(ceremony_commit(&mut store, page, &mut chain, b"entropy").is_none());
        assert_eq!(chain.epoch(), 0);

        // Deferred and confirmed, the one event runs both halves: the
        // epoch advances, and the sealed frame opens under the
        // incoming key with nothing from behind the boundary in it.
        assert!(store.set_compaction_deferred(page, true));
        let tab = store.tabs().next().unwrap().id();
        store.cycle_rung(tab).unwrap();
        let sealed = ceremony_commit(&mut store, page, &mut chain, b"entropy").unwrap();
        assert_eq!(chain.epoch(), 1);
        let frame = chain.open(&sealed).unwrap();
        let contains = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
        assert!(!contains(&frame, b"DOOMED"));

        // The frame is the joinable state: a fresh store adopts it.
        let mut joiner = SheetStore::new(ManualClock::new());
        let j = joiner.new_tab().unwrap().1;
        let uuid = store.sheet(page).unwrap().uuid();
        joiner.adopt_key_frame(j, uuid, &frame).unwrap();
        assert_eq!(
            joiner.sheet(j).unwrap().segments(),
            store.sheet(page).unwrap().segments()
        );
    }
}
