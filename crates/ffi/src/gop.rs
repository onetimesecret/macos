//! The per GOP transport key: derived at the key frame, rotated at the
//! ceremony, destroyed on rotation, so ciphertext the relay keeps past
//! a boundary opens for no one, its writers included (ADR-0007,
//! relay decision background section 2, issue #95). The chain descends from the pairing
//! ceremony's channel secret, never the content key (relay decision
//! background section 8); each step salts with the outgoing key and mixes in entropy sealed
//! to the named members, which keeps out a device that missed a
//! rotation or was not named, though not the proposer (client protocol
//! §7.9, §8). Formula, info string, salt and magic: Appendix A there.

use ring::hkdf::{HKDF_SHA256, Salt};
use zeroize::Zeroizing;

use crate::persist::{self, Bytes, GOP_KEY_INFO, GOP_MAGIC, GOP_ROOT_SALT, KEY_LEN};

/// Length of a sealed GOP payload's authenticated header:
/// `magic[8] ‖ epoch[8]`, big-endian like every other header in this
/// crate.
const GOP_HEADER_LEN: usize = 8 + 8;

/// One channel's transport key chain: the current GOP's key and its
/// epoch, nothing else. Not `Debug` and not `Clone`, so no caller keeps
/// an outgoing key alive by accident; the key wipes on drop.
pub struct GopKeyChain {
    /// How many ceremonies this chain has crossed: the GOP epoch,
    /// matching [`companion_core::PageChannel`]'s count.
    epoch: u64,
    key: Zeroizing<Vec<u8>>,
    /// A test's forced nonce refusal for the next seal.
    #[cfg(test)]
    refuse_seal: std::cell::Cell<bool>,
}

/// What was sealed under one epoch's key, a key frame or a publish batch:
/// it may go out only while the chain stands at that epoch (client
/// protocol §4.4, §4.6).
pub trait EpochSealed {
    /// The epoch whose key sealed it.
    fn sealed_epoch(&self) -> u64;
}

/// Take out of `slot` what was sealed at an epoch other than `chain`'s,
/// so it never goes out; the one check frames and batches share.
pub fn take_stale<T: EpochSealed>(slot: &mut Option<T>, chain: &GopKeyChain) -> Option<T> {
    if slot
        .as_ref()
        .is_some_and(|sealed| sealed.sealed_epoch() != chain.epoch())
    {
        slot.take()
    } else {
        None
    }
}

/// A ceremony's key frame and the epoch whose key sealed it, the one
/// epoch it may be published at (client protocol §4.6).
pub struct KeyFrame {
    epoch: u64,
    sealed: Vec<u8>,
}

impl KeyFrame {
    /// The epoch whose key sealed this frame.
    #[must_use]
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// The sealed bytes: `magic ‖ epoch ‖ nonce ‖ ciphertext ‖ tag`.
    #[must_use]
    pub fn sealed(&self) -> &[u8] {
        &self.sealed
    }
}

impl EpochSealed for KeyFrame {
    fn sealed_epoch(&self) -> u64 {
        self.epoch
    }
}

impl GopKeyChain {
    /// The chain at epoch zero, expanded from the pairing ceremony's
    /// channel secret, the same on every paired device. `None` only if
    /// the HKDF refuses, which a 32-byte expansion cannot make it do.
    #[must_use]
    pub fn root(channel_secret: &[u8]) -> Option<Self> {
        let prk = Salt::new(HKDF_SHA256, GOP_ROOT_SALT).extract(channel_secret);
        let okm = prk.expand(&[GOP_KEY_INFO], Bytes(KEY_LEN)).ok()?;
        let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
        okm.fill(&mut key).ok()?;
        Some(Self {
            epoch: 0,
            key,
            #[cfg(test)]
            refuse_seal: std::cell::Cell::new(false),
        })
    }

    /// Refuse the next seal, as the RNG declining a nonce would.
    #[cfg(test)]
    pub(crate) fn refuse_next_seal(&self) {
        self.refuse_seal.set(true);
    }

    /// The GOP epoch this chain's key belongs to.
    #[must_use]
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// Rotate at the ceremony: expand the incoming key from the outgoing
    /// key and the ceremony's entropy, advance the epoch, and wipe the
    /// outgoing key. Pure derivation; it cannot fail, and must not:
    /// [`ceremony_commit`] runs it after the store's irreversible rebuild.
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
    /// authenticated. `None` when the RNG refuses a nonce: a refusal to
    /// publish, never a publish under a reused one.
    #[must_use]
    pub fn seal(&self, plaintext: &[u8]) -> Option<Vec<u8>> {
        #[cfg(test)]
        if self.refuse_seal.take() {
            return None;
        }
        let header = self.header();
        let body = persist::seal_body(&self.key, &header, plaintext)?;
        let mut sealed = Vec::with_capacity(header.len() + body.len());
        sealed.extend_from_slice(&header);
        sealed.extend_from_slice(&body);
        Some(sealed)
    }

    /// Open a sealed payload from a peer. `None` for anything not sealed
    /// under this key at this epoch: a payload from behind a boundary is
    /// the purge working. The plaintext wipes on drop.
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

/// What keeps a device in step: advance the chain, then seal the
/// store's rebuild as the key frame, or an empty one (client protocol §7.6).
/// `None` when the seal refuses; the chain has advanced all the same.
pub fn ceremony_commit(
    chain: &mut GopKeyChain,
    entropy: &[u8],
    rebuild: Option<&[u8]>,
) -> Option<KeyFrame> {
    chain.advance(entropy);
    seal_frame(chain, rebuild)
}

/// Seal the store's rebuild, or an empty frame, as the key frame of the
/// chain's current epoch. `None` when the seal refuses.
pub fn seal_frame(chain: &GopKeyChain, rebuild: Option<&[u8]>) -> Option<KeyFrame> {
    let sealed = chain.seal(rebuild.unwrap_or_default())?;
    Some(KeyFrame {
        epoch: chain.epoch(),
        sealed,
    })
}

#[cfg(test)]
mod tests {
    use companion_core::{EditOp, ManualClock, SheetStore};
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
    fn the_commit_seals_the_rebuild_or_an_empty_frame_under_the_incoming_key() {
        let mut store = SheetStore::new(ManualClock::new());
        let page = store.new_tab().1;
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

        // The store's rebuild is sealed under the incoming key with
        // nothing from behind the boundary in it.
        assert!(store.set_compaction_deferred(page, true));
        let tab = store.tabs().next().unwrap().id();
        store.cycle_rung(tab).unwrap();
        let rebuild = store.perform_ceremony(page).unwrap();
        let sealed = ceremony_commit(&mut chain, b"entropy", Some(rebuild.as_slice())).unwrap();
        assert_eq!((chain.epoch(), sealed.epoch()), (1, 1));
        let frame = chain.open(sealed.sealed()).unwrap();
        let contains = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
        assert!(!contains(&frame, b"DOOMED"));

        // The frame is the joinable state: a fresh store adopts it.
        let mut joiner = SheetStore::new(ManualClock::new());
        let j = joiner.new_tab().1;
        let uuid = store.sheet(page).unwrap().uuid();
        joiner.adopt_key_frame(j, uuid, &frame).unwrap();
        assert_eq!(
            joiner.sheet(j).unwrap().segments(),
            store.sheet(page).unwrap().segments()
        );

        // With no rebuild the chain still advances, and its frame holds
        // nothing: a rejoining device lands no page and no identity from it.
        let empty = ceremony_commit(&mut chain, b"more entropy", None).unwrap();
        assert_eq!((chain.epoch(), empty.epoch()), (2, 2));
        let opened = chain.open(empty.sealed()).unwrap();
        assert!(opened.is_empty());
        let mut rejoiner = SheetStore::new(ManualClock::new());
        let r = rejoiner.new_tab().1;
        assert!(rejoiner.adopt_key_frame(r, uuid, &opened).is_err());
        assert!(rejoiner.sheet(r).unwrap().segments().is_empty());
        assert!(rejoiner.sheet_id_of(uuid).is_none());
    }

    #[test]
    fn a_refused_frame_seal_stages_nothing_and_the_chain_still_advances() {
        let mut chain = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        chain.refuse_next_seal();
        assert!(ceremony_commit(&mut chain, b"entropy", Some(b"a rebuild")).is_none());
        assert_eq!(chain.epoch(), 1);
        // The refusal is the one seal's; the next seals at the new epoch.
        let frame = ceremony_commit(&mut chain, b"more entropy", None).unwrap();
        assert_eq!(frame.epoch(), 2);
    }
}
