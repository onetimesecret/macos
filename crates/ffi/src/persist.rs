//! The sealed files: encryption on every mutation, decryption at
//! launch.
//!
//! There are two of them, with two keys and two envelope magics, and
//! the split is the point (ADR-0012).
//!
//! - **The state file** holds staged content: sheets, sealed chips,
//!   clocks. It rests under `state-key` and is bound to the boot
//!   session, so a reboot discards it.
//! - **The ledger file** holds metadata plus the capped, page-owned
//!   title, never content. It rests under `ledger-key`, a single
//!   long-lived keychain half that is deliberately not boot-bound: an
//!   audit record that vanished on every restart would not be an audit
//!   record.
//!
//! The core hands over each plaintext snapshot
//! ([`companion_core::persist`]) only ever inside a [`Zeroizing`]
//! buffer; this module seals it with ChaCha20-Poly1305 under a 32-byte
//! key that rests in the OS credential store (the same store, and the
//! same service scope, as the API token) and writes only ciphertext to
//! the path the shell chose. A save runs whenever the store changes,
//! behind the shell's debounce, and once more at quit to flush whatever
//! the debounce still held; the crash-loss window is that interval, not
//! the whole process lifetime (ADR-0012). Restore is the mirror: read,
//! authenticate, decrypt in place, feed the core, and the plaintext
//! wipes on drop.
//!
//! Each envelope's magic is its own AEAD associated data, so a ledger
//! file presented as a state file (or the reverse) fails authentication
//! rather than misparsing.
//!
//! A file is useless without its keychain item, and an item names
//! nothing without its file: deleting either forgets everything on
//! that side.

use std::io::Write;
use std::path::Path;

use companion_credentials::{CredentialError, CredentialStore};
use ring::aead::{Aad, CHACHA20_POLY1305, LessSafeKey, NONCE_LEN, Nonce, UnboundKey};
use ring::rand::{SecureRandom, SystemRandom};
use zeroize::Zeroizing;

/// Magic + version prefix of the sealed state file. A format change
/// gets a new final byte; the prefix doubles as the AEAD's associated
/// data, so a relabeled file fails authentication rather than
/// misparsing.
const FILE_MAGIC: &[u8; 8] = b"OTSSEAL1";

/// Magic + version prefix of the sealed ledger file. Distinct from
/// [`FILE_MAGIC`] on purpose: it is the associated data too, so the two
/// envelopes cannot be swapped even by a caller holding both keys.
const LEDGER_MAGIC: &[u8; 8] = b"OTSLEDG1";

/// The credential-store account holding the state key (scoped by the
/// store's service, `com.onetimesecret.companion`).
const STATE_KEY_ACCOUNT: &str = "state-key";

/// The credential-store account holding the ledger key.
///
/// This is a SINGLE keychain half and is deliberately not run through
/// the two-half boot-session HKDF the content key gets: its whole
/// purpose is to outlive the boot session. A boot-session mismatch
/// discards staged content and rotates the content halves; the ledger
/// key must survive that untouched, so any future `rotate_key_halves`
/// must never touch `ledger-key`.
const LEDGER_KEY_ACCOUNT: &str = "ledger-key";

/// ChaCha20-Poly1305 key length.
const KEY_LEN: usize = 32;

/// A key for saving: load it, or mint and store a fresh one on first
/// save. `None` when the backend refuses (locked keychain, denied ACL)
/// or a stored key has the wrong shape: refuse rather than guess.
fn ensure_key_for(credentials: &dyn CredentialStore, account: &str) -> Option<Zeroizing<Vec<u8>>> {
    match credentials.load(account) {
        Ok(key) if key.len() == KEY_LEN => Some(key),
        Err(CredentialError::NotFound) => {
            let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
            SystemRandom::new().fill(&mut key).ok()?;
            credentials.store(account, &key).ok()?;
            Some(key)
        }
        // A wrongly-shaped key or a refusing backend (locked keychain,
        // denied ACL): refuse rather than guess.
        Ok(_) | Err(CredentialError::Backend(_)) => None,
    }
}

/// A key for restoring: load only, never mint. With no key there is
/// nothing decryptable, and a fresh key would only orphan the file that
/// exists.
fn load_key_for(credentials: &dyn CredentialStore, account: &str) -> Option<Zeroizing<Vec<u8>>> {
    match credentials.load(account) {
        Ok(key) if key.len() == KEY_LEN => Some(key),
        _ => None,
    }
}

/// The state key for saving ([`ensure_key_for`] on `state-key`).
pub(crate) fn ensure_state_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    ensure_key_for(credentials, STATE_KEY_ACCOUNT)
}

/// The state key for restoring ([`load_key_for`] on `state-key`).
pub(crate) fn load_state_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    load_key_for(credentials, STATE_KEY_ACCOUNT)
}

/// The ledger key for saving. Long-lived by design: see
/// [`LEDGER_KEY_ACCOUNT`].
pub(crate) fn ensure_ledger_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    ensure_key_for(credentials, LEDGER_KEY_ACCOUNT)
}

/// The ledger key for restoring. Load only, never mint.
pub(crate) fn load_ledger_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    load_key_for(credentials, LEDGER_KEY_ACCOUNT)
}

/// Seal a plaintext snapshot into file bytes:
/// `magic ‖ nonce ‖ ciphertext ‖ tag`, nonce fresh per save. The
/// plaintext copy inside the work buffer is overwritten by the
/// ciphertext in place, so sealing strands nothing. `magic` is the
/// associated data as well as the prefix.
fn seal_with(magic: &[u8; 8], key: &[u8], plaintext: &[u8]) -> Option<Vec<u8>> {
    let key = aead_key(key)?;
    let mut nonce_bytes = [0u8; NONCE_LEN];
    SystemRandom::new().fill(&mut nonce_bytes).ok()?;
    let mut body = Vec::with_capacity(plaintext.len() + CHACHA20_POLY1305.tag_len());
    body.extend_from_slice(plaintext);
    key.seal_in_place_append_tag(
        Nonce::assume_unique_for_key(nonce_bytes),
        Aad::from(magic),
        &mut body,
    )
    .ok()?;
    let mut file = Vec::with_capacity(magic.len() + NONCE_LEN + body.len());
    file.extend_from_slice(magic);
    file.extend_from_slice(&nonce_bytes);
    file.extend_from_slice(&body);
    Some(file)
}

/// Open a sealed file back into its plaintext snapshot, authenticated
/// end to end. The returned buffer wipes on drop; `None` for anything
/// that is not a file of this `magic` sealed under this key, bit for
/// bit.
fn open_with(magic: &[u8; 8], key: &[u8], file: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let key = aead_key(key)?;
    let rest = file.strip_prefix(magic.as_slice())?;
    if rest.len() < NONCE_LEN {
        return None;
    }
    let (nonce_bytes, ciphertext) = rest.split_at(NONCE_LEN);
    let nonce = Nonce::try_assume_unique_for_key(nonce_bytes).ok()?;
    // Decrypt in place inside a zeroizing buffer: the plaintext lands at
    // the front; truncate to its length and let the wipe cover the rest.
    let mut buffer = Zeroizing::new(ciphertext.to_vec());
    let plaintext_len = key
        .open_in_place(nonce, Aad::from(magic), &mut buffer)
        .ok()?
        .len();
    buffer.truncate(plaintext_len);
    Some(buffer)
}

/// Seal a content snapshot under the state envelope.
pub(crate) fn seal_state(key: &[u8], plaintext: &[u8]) -> Option<Vec<u8>> {
    seal_with(FILE_MAGIC, key, plaintext)
}

/// Open a content snapshot from the state envelope.
pub(crate) fn open_state(key: &[u8], file: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    open_with(FILE_MAGIC, key, file)
}

/// Seal a ledger snapshot under the ledger envelope.
pub(crate) fn seal_ledger(key: &[u8], plaintext: &[u8]) -> Option<Vec<u8>> {
    seal_with(LEDGER_MAGIC, key, plaintext)
}

/// Open a ledger snapshot from the ledger envelope.
pub(crate) fn open_ledger(key: &[u8], file: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    open_with(LEDGER_MAGIC, key, file)
}

/// Write `bytes` to `path` atomically (temp file, fsync, rename, fsync
/// the directory) with owner-only permissions. The temp file carries a
/// fresh random suffix and is opened create-new, so concurrent savers
/// never truncate each other's half-written file and anything planted
/// at the name — a crash leftover, a symlink — is an open error, never
/// followed. Two writers still race on the final rename (last one wins
/// the state file), but every write lands whole or not at all. The
/// content is ciphertext, but a state file readable by other accounts
/// would still be a needless gift.
pub(crate) fn write_private(path: &Path, bytes: &[u8]) -> bool {
    let mut suffix = [0u8; 8];
    if SystemRandom::new().fill(&mut suffix).is_err() {
        return false;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(format!(".{:016x}.tmp", u64::from_be_bytes(suffix)));
    let tmp = Path::new(&tmp);
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
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
    if !written || std::fs::rename(tmp, path).is_err() {
        let _ = std::fs::remove_file(tmp);
        return false;
    }
    sync_parent_dir(path);
    true
}

/// Flush the directory entry the rename just created. The file's own
/// bytes are already durable, but a power loss before the directory is
/// written can still lose the name that points at them, leaving the
/// previous state file (or none). Best effort by design: a parent we
/// cannot open or sync leaves the bytes written either way, so a failure
/// here must never unwrite the save.
fn sync_parent_dir(path: &Path) {
    if let Some(parent) = parent_to_sync(path) {
        let _ = sync_dir(parent);
    }
}

/// The directory that holds `path`'s entry, the one whose flush makes
/// the rename durable. A path with no directory component has parent
/// `Some("")` rather than `None`, and its entry lands in the working
/// directory, so that case resolves to `.` instead of skipping the sync.
/// Only a root path has nothing above it.
fn parent_to_sync(path: &Path) -> Option<&Path> {
    match path.parent() {
        None => None,
        Some(parent) if parent.as_os_str().is_empty() => Some(Path::new(".")),
        Some(parent) => Some(parent),
    }
}

/// The fallible half of the flush, split out so a test can see it fail:
/// opening a directory read-only and syncing the fd is what commits the
/// entry (on APFS this is `fcntl(F_FULLFSYNC)`).
fn sync_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::File::open(dir)?.sync_all()
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

        // The ledger envelope is the same construction and must hold to
        // the same standard.
        let sealed = seal_ledger(&key, b"one audit record").unwrap();
        for index in 0..sealed.len() {
            let mut bent = sealed.clone();
            bent[index] ^= 0x01;
            assert!(
                open_ledger(&key, &bent).is_none(),
                "a flipped bit at {index} still opened the ledger"
            );
        }
        assert!(open_ledger(&key, &sealed[..sealed.len() - 1]).is_none());
    }

    /// The ledger rests under its own long-lived credential, so a
    /// content key that is rotated or discarded leaves the audit record
    /// readable, and a store that has only ever saved content cannot
    /// pretend to hold a ledger key.
    #[test]
    fn the_ledger_key_is_a_separate_credential() {
        let store = InMemoryCredentialStore::default();
        let state = ensure_state_key(&store).unwrap();
        let ledger = ensure_ledger_key(&store).unwrap();
        assert_ne!(&*state, &*ledger, "one key sealing both files");
        assert_eq!(&*ensure_ledger_key(&store).unwrap(), &*ledger, "stable");

        let content_only = InMemoryCredentialStore::default();
        ensure_state_key(&content_only).unwrap();
        assert!(
            load_ledger_key(&content_only).is_none(),
            "restore must never mint a ledger key"
        );
    }

    /// The magic is the associated data, so the envelopes cannot be
    /// swapped even by a caller holding the right key.
    #[test]
    fn a_ledger_file_cannot_be_opened_as_a_state_file() {
        let key = key();
        let as_ledger = seal_ledger(&key, b"one audit record").unwrap();
        assert!(open_state(&key, &as_ledger).is_none());
        let as_state = seal_state(&key, b"staged content").unwrap();
        assert!(open_ledger(&key, &as_state).is_none());
    }

    #[test]
    fn the_wrong_key_opens_nothing() {
        let sealed = seal_state(&key(), b"payload").unwrap();
        assert!(
            open_state(&key(), &sealed).is_none(),
            "keys are independent"
        );
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

    /// A fresh directory under the system temp dir, removed by each
    /// test on success; a failure leaves it behind for inspection.
    fn scratch_dir() -> std::path::PathBuf {
        let mut tag = [0u8; 8];
        SystemRandom::new().fill(&mut tag).unwrap();
        let dir = std::env::temp_dir().join(format!(
            "companion-persist-test-{:016x}",
            u64::from_be_bytes(tag)
        ));
        std::fs::create_dir(&dir).unwrap();
        dir
    }

    /// Everything in `dir` other than the state file itself — after any
    /// write, success or not, this must be empty.
    fn temp_litter(dir: &Path) -> Vec<std::ffi::OsString> {
        std::fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .filter(|name| name != "state.sealed")
            .collect()
    }

    #[test]
    fn write_private_replaces_whole_and_cleans_up() {
        let dir = scratch_dir();
        let target = dir.join("state.sealed");
        assert!(write_private(&target, b"first save"));
        assert_eq!(std::fs::read(&target).unwrap(), b"first save");
        assert!(write_private(
            &target,
            b"second save, longer than the first"
        ));
        assert_eq!(
            std::fs::read(&target).unwrap(),
            b"second save, longer than the first"
        );
        assert_eq!(temp_litter(&dir), Vec::<std::ffi::OsString>::new());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Which directory a given path's entry lives in, decided without a
    /// filesystem and without touching the process-wide working
    /// directory (which `cargo test` shares across every test thread).
    #[test]
    fn the_directory_to_sync_covers_the_bare_filename_case() {
        assert_eq!(parent_to_sync(Path::new("/a/b")), Some(Path::new("/a")));
        assert_eq!(
            parent_to_sync(Path::new("state.sealed")),
            Some(Path::new(".")),
            "a bare filename lands in the working directory, so sync that"
        );
        assert_eq!(
            parent_to_sync(Path::new("a/")),
            Some(Path::new(".")),
            "a trailing slash still leaves the empty parent"
        );
        assert_eq!(
            parent_to_sync(Path::new("/")),
            None,
            "the root has no directory above it to flush"
        );
    }

    /// The flush is best effort: an unopenable parent must leave the
    /// bytes written and the write reported as a success. Losing that
    /// property (an early `return false`, a `?`) is the regression this
    /// catches; the directory sync being a no-op is the other.
    #[cfg(unix)]
    #[test]
    fn an_unsyncable_parent_still_lands_the_write() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch_dir();
        let target = dir.join("state.sealed");
        assert!(write_private(&target, b"first save"));
        // Write plus search, no read: create, rename and lookup still
        // work, but opening the directory itself fails with EACCES.
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o300)).unwrap();
        let unopenable = sync_dir(&dir).is_err();
        if unopenable {
            assert!(
                write_private(&target, b"second save"),
                "a parent that cannot be synced must not unwrite the save"
            );
            assert_eq!(std::fs::read(&target).unwrap(), b"second save");
        }
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        // Running as root, or on a filesystem that ignores the mode, the
        // branch under test is simply unreachable here.
        if unopenable {
            assert_eq!(temp_litter(&dir), Vec::<std::ffi::OsString>::new());
        }
        assert!(sync_dir(&dir).is_ok(), "a readable parent syncs");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn the_state_file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch_dir();
        let target = dir.join("state.sealed");
        assert!(write_private(&target, b"sealed bytes"));
        let mode = std::fs::metadata(&target).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "the rename must keep the temp's mode");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_planted_symlink_beside_the_target_is_never_followed() {
        let dir = scratch_dir();
        let target = dir.join("state.sealed");
        let victim = dir.join("victim");
        std::fs::write(&victim, b"untouched").unwrap();
        // The writer once used the predictable sibling name
        // `<path>.tmp`; a symlink planted there must stay a dead end,
        // not a redirect for the write.
        std::os::unix::fs::symlink(&victim, dir.join("state.sealed.tmp")).unwrap();
        assert!(write_private(&target, b"sealed bytes"));
        assert_eq!(std::fs::read(&target).unwrap(), b"sealed bytes");
        assert_eq!(
            std::fs::read(&victim).unwrap(),
            b"untouched",
            "the write escaped through the planted symlink"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn concurrent_saves_never_land_a_torn_file() {
        let dir = scratch_dir();
        let target = dir.join("state.sealed");
        // Payloads big enough that a shared temp path would show as a
        // mixed or truncated file; the assertion never false-fails, it
        // only catches corruption when the interleaving produces one.
        let a = vec![0xAA_u8; 64 * 1024];
        let b = vec![0xBB_u8; 64 * 1024];
        std::thread::scope(|scope| {
            let target = &target;
            for payload in [&a, &b] {
                scope.spawn(move || {
                    for _ in 0..16 {
                        assert!(write_private(target, payload));
                    }
                });
            }
        });
        let last = std::fs::read(&target).unwrap();
        assert!(
            last == a || last == b,
            "the state file holds a torn write of {} bytes",
            last.len()
        );
        assert_eq!(temp_litter(&dir), Vec::<std::ffi::OsString>::new());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
