//! The per-GOP transport key (ADR-0021; relay-protocol.md §5). The root
//! expands from the pairing channel secret, not the content key, so every
//! paired device can derive it:
//!
//! ```text
//! key[0]   = HKDF(salt: GOP_ROOT_SALT, ikm: channel_secret, info: GOP_KEY_INFO)
//! key[n+1] = HKDF(salt: key[n],        ikm: entropy[n],     info: GOP_KEY_INFO)
//! ```

use companion_core::{Clock, SheetId, SheetStore};
use ring::hkdf::{HKDF_SHA256, Salt};
use zeroize::Zeroizing;

use crate::persist::{self, Bytes, GOP_KEY_INFO, GOP_MAGIC, GOP_ROOT_SALT, KEY_LEN};

/// `magic[8] ‖ epoch[8]`, big-endian.
const GOP_HEADER_LEN: usize = 8 + 8;

/// One channel's current GOP key and epoch. Deliberately neither `Debug`
/// nor `Clone`, so nothing keeps an outgoing key alive.
pub struct GopKeyChain {
    /// Matches [`companion_core::PageChannel`]'s ceremony count.
    epoch: u64,
    key: Zeroizing<Vec<u8>>,
}

impl GopKeyChain {
    /// The chain at epoch zero, from the pairing channel secret.
    #[must_use]
    pub fn root(channel_secret: &[u8]) -> Option<Self> {
        let prk = Salt::new(HKDF_SHA256, GOP_ROOT_SALT).extract(channel_secret);
        let okm = prk.expand(&[GOP_KEY_INFO], Bytes(KEY_LEN)).ok()?;
        let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
        okm.fill(&mut key).ok()?;
        Some(Self { epoch: 0, key })
    }

    /// The GOP epoch of the current key.
    #[must_use]
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// Rotate to the next epoch; the outgoing key is wiped as it drops.
    /// Infallible, so [`ceremony_commit`] has no half-done state.
    pub fn advance(&mut self, entropy: &[u8]) {
        let prk = Salt::new(HKDF_SHA256, &self.key).extract(entropy);
        let mut next = Zeroizing::new(vec![0u8; KEY_LEN]);
        let filled = prk
            .expand(&[GOP_KEY_INFO], Bytes(KEY_LEN))
            .and_then(|okm| okm.fill(&mut next))
            .is_ok();
        debug_assert!(filled, "a 32-byte HKDF expansion has no refusable input");
        self.key = next;
        self.epoch += 1;
    }

    /// `magic ‖ epoch ‖ nonce ‖ ciphertext ‖ tag`, header as associated
    /// data. `None` when the RNG refuses a nonce.
    #[must_use]
    pub fn seal(&self, plaintext: &[u8]) -> Option<Vec<u8>> {
        let header = self.header();
        let body = persist::seal_body(&self.key, &header, plaintext)?;
        let mut sealed = Vec::with_capacity(header.len() + body.len());
        sealed.extend_from_slice(&header);
        sealed.extend_from_slice(&body);
        Some(sealed)
    }

    /// `None` for anything not sealed under this key at this epoch.
    #[must_use]
    pub fn open(&self, sealed: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        let body = sealed.strip_prefix(self.header().as_slice())?;
        persist::open_body(&self.key, &self.header(), body)
    }

    fn header(&self) -> [u8; GOP_HEADER_LEN] {
        let mut header = [0u8; GOP_HEADER_LEN];
        header[..8].copy_from_slice(GOP_MAGIC);
        header[8..].copy_from_slice(&self.epoch.to_be_bytes());
        header
    }
}

/// Compact the page, rotate the key, and return the key frame sealed
/// under the incoming key (relay-protocol.md §5). A refused compaction
/// rotates nothing. Run only on a confirmed ceremony.
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

    const CHANNEL_SECRET: &[u8; 32] = b"0123456789abcdef0123456789abcdef";

    #[test]
    fn ciphertext_sealed_under_the_outgoing_key_does_not_open_under_the_incoming() {
        let mut chain = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let sealed = chain.seal(b"a delta the relay retained").unwrap();
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
        let mut surviving = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        let mut revoked = GopKeyChain::root(CHANNEL_SECRET).unwrap();
        surviving.advance(b"entropy the revoked device never received");
        revoked.advance(b"a guess");
        let sealed = surviving.seal(b"the survivors' traffic").unwrap();
        assert!(revoked.open(&sealed).is_none());
    }

    #[test]
    fn a_gop_rotation_never_touches_the_ledger_key_or_the_content_halves() {
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

        assert!(ceremony_commit(&mut store, page, &mut chain, b"entropy").is_none());
        assert_eq!(chain.epoch(), 0);

        assert!(store.set_compaction_deferred(page, true));
        let tab = store.tabs().next().unwrap().id();
        store.cycle_rung(tab).unwrap();
        let sealed = ceremony_commit(&mut store, page, &mut chain, b"entropy").unwrap();
        assert_eq!(chain.epoch(), 1);
        let frame = chain.open(&sealed).unwrap();
        let contains = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
        assert!(!contains(&frame, b"DOOMED"));

        let mut joiner = SheetStore::new(ManualClock::new());
        let j = joiner.new_tab().1;
        let uuid = store.sheet(page).unwrap().uuid();
        joiner.adopt_key_frame(j, uuid, &frame).unwrap();
        assert_eq!(
            joiner.sheet(j).unwrap().segments(),
            store.sheet(page).unwrap().segments()
        );
    }
}
