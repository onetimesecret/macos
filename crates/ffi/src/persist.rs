//! The sealed state file: JIT encryption at quit, decryption at launch.
//!
//! The core hands over its plaintext snapshot
//! ([`companion_core::persist`]) only ever inside a [`Zeroizing`]
//! buffer; this module seals it with ChaCha20-Poly1305 under a 32-byte
//! key that rests in the OS credential store (the same store, and the
//! same service scope, as the API token) and writes only ciphertext to
//! the path the shell chose. Restore is the mirror: read, authenticate,
//! decrypt in place, feed the core, and the plaintext wipes on drop.
//!
//! The file is useless without the keychain item, and the item names
//! nothing without the file — deleting either forgets everything.

use std::io::Write;
use std::path::Path;

use companion_credentials::{CredentialError, CredentialStore};
use ring::aead::{Aad, CHACHA20_POLY1305, LessSafeKey, NONCE_LEN, Nonce, UnboundKey};
use ring::rand::{SecureRandom, SystemRandom};
use zeroize::Zeroizing;

/// Magic + version prefix of the sealed file. A format change gets a
/// new final byte; the prefix doubles as the AEAD's associated data, so
/// a relabeled file fails authentication rather than misparsing.
const FILE_MAGIC: &[u8; 8] = b"OTSSEAL1";

/// The credential-store account holding the state key (scoped by the
/// store's service, `com.onetimesecret.companion`).
const STATE_KEY_ACCOUNT: &str = "state-key";

/// ChaCha20-Poly1305 key length.
const KEY_LEN: usize = 32;

/// The state key for saving: load it, or mint and store a fresh one on
/// first save. `None` when the backend refuses (locked keychain, denied
/// ACL) or a stored key has the wrong shape — refuse rather than guess.
pub(crate) fn ensure_state_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    match credentials.load(STATE_KEY_ACCOUNT) {
        Ok(key) if key.len() == KEY_LEN => Some(key),
        Err(CredentialError::NotFound) => {
            let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
            SystemRandom::new().fill(&mut key).ok()?;
            credentials.store(STATE_KEY_ACCOUNT, &key).ok()?;
            Some(key)
        }
        // A wrongly-shaped key or a refusing backend (locked keychain,
        // denied ACL): refuse rather than guess.
        Ok(_) | Err(CredentialError::Backend(_)) => None,
    }
}

/// The state key for restoring: load only, never mint — with no key
/// there is nothing decryptable, and a fresh key would only orphan the
/// file that exists.
pub(crate) fn load_state_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    match credentials.load(STATE_KEY_ACCOUNT) {
        Ok(key) if key.len() == KEY_LEN => Some(key),
        _ => None,
    }
}

/// Seal a plaintext snapshot into file bytes:
/// `magic ‖ nonce ‖ ciphertext ‖ tag`, nonce fresh per save. The
/// plaintext copy inside the work buffer is overwritten by the
/// ciphertext in place, so sealing strands nothing.
pub(crate) fn seal_state(key: &[u8], plaintext: &[u8]) -> Option<Vec<u8>> {
    let key = aead_key(key)?;
    let mut nonce_bytes = [0u8; NONCE_LEN];
    SystemRandom::new().fill(&mut nonce_bytes).ok()?;
    let mut body = Vec::with_capacity(plaintext.len() + CHACHA20_POLY1305.tag_len());
    body.extend_from_slice(plaintext);
    key.seal_in_place_append_tag(
        Nonce::assume_unique_for_key(nonce_bytes),
        Aad::from(FILE_MAGIC),
        &mut body,
    )
    .ok()?;
    let mut file = Vec::with_capacity(FILE_MAGIC.len() + NONCE_LEN + body.len());
    file.extend_from_slice(FILE_MAGIC);
    file.extend_from_slice(&nonce_bytes);
    file.extend_from_slice(&body);
    Some(file)
}

/// Open a sealed file back into its plaintext snapshot, authenticated
/// end to end. The returned buffer wipes on drop; `None` for anything
/// that is not our file sealed under this key, bit for bit.
pub(crate) fn open_state(key: &[u8], file: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let key = aead_key(key)?;
    let rest = file.strip_prefix(FILE_MAGIC.as_slice())?;
    if rest.len() < NONCE_LEN {
        return None;
    }
    let (nonce_bytes, ciphertext) = rest.split_at(NONCE_LEN);
    let nonce = Nonce::try_assume_unique_for_key(nonce_bytes).ok()?;
    // Decrypt in place inside a zeroizing buffer: the plaintext lands at
    // the front; truncate to its length and let the wipe cover the rest.
    let mut buffer = Zeroizing::new(ciphertext.to_vec());
    let plaintext_len = key
        .open_in_place(nonce, Aad::from(FILE_MAGIC), &mut buffer)
        .ok()?
        .len();
    buffer.truncate(plaintext_len);
    Some(buffer)
}

/// Write `bytes` to `path` atomically (temp file, fsync, rename) with
/// owner-only permissions. The content is ciphertext, but a state file
/// readable by other accounts would still be a needless gift.
pub(crate) fn write_private(path: &Path, bytes: &[u8]) -> bool {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = Path::new(&tmp);
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let Ok(mut file) = options.open(tmp) else {
        return false;
    };
    let written = file.write_all(bytes).is_ok() && file.sync_all().is_ok();
    drop(file);
    if !written {
        let _ = std::fs::remove_file(tmp);
        return false;
    }
    std::fs::rename(tmp, path).is_ok()
}

fn aead_key(key: &[u8]) -> Option<LessSafeKey> {
    UnboundKey::new(&CHACHA20_POLY1305, key)
        .ok()
        .map(LessSafeKey::new)
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_credentials::InMemoryCredentialStore;

    fn key() -> Zeroizing<Vec<u8>> {
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store).unwrap()
    }

    #[test]
    fn seal_and_open_round_trip() {
        let key = key();
        let sealed = seal_state(&key, b"the whole store, serialized").unwrap();
        let opened = open_state(&key, &sealed).unwrap();
        assert_eq!(&*opened, b"the whole store, serialized");
    }

    #[test]
    fn the_file_never_contains_the_plaintext() {
        let key = key();
        let secret = b"ghp_this-must-not-appear-on-disk";
        let sealed = seal_state(&key, secret).unwrap();
        assert!(
            !sealed.windows(secret.len()).any(|w| w == secret),
            "plaintext leaked into the sealed file"
        );
    }

    #[test]
    fn tampering_anywhere_fails_authentication() {
        let key = key();
        let sealed = seal_state(&key, b"payload").unwrap();
        for index in 0..sealed.len() {
            let mut bent = sealed.clone();
            bent[index] ^= 0x01;
            assert!(
                open_state(&key, &bent).is_none(),
                "a flipped bit at {index} still opened"
            );
        }
        assert!(open_state(&key, &sealed[..sealed.len() - 1]).is_none());
    }

    #[test]
    fn the_wrong_key_opens_nothing() {
        let sealed = seal_state(&key(), b"payload").unwrap();
        assert!(open_state(&key(), &sealed).is_none(), "keys are independent");
    }

    #[test]
    fn ensure_is_stable_and_load_never_mints() {
        let store = InMemoryCredentialStore::default();
        assert!(
            load_state_key(&store).is_none(),
            "restore must not mint a key for a file it cannot decrypt anyway"
        );
        let first = ensure_state_key(&store).unwrap();
        let second = ensure_state_key(&store).unwrap();
        assert_eq!(&*first, &*second, "the key survives across saves");
        assert_eq!(&*load_state_key(&store).unwrap(), &*first);
    }

    #[test]
    fn nonces_are_fresh_per_save() {
        let key = key();
        let a = seal_state(&key, b"same payload").unwrap();
        let b = seal_state(&key, b"same payload").unwrap();
        assert_ne!(a, b, "two saves of the same state must not repeat a nonce");
    }
}
