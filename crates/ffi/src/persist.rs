//! The sealed files: the state file (staged content, under the two-half
//! content key) and the ledger file (metadata, under the long-lived
//! `ledger-key`) (ADR-0012, ADR-0016).
//!
//! State envelope: `magic ‖ sealed_wall_ms[8] ‖ nonce[12] ‖ ciphertext ‖ tag`,
//! with the 16-byte header as associated data.

// The portable path exists for Linux CI only: off macOS there is no data
// protection keychain and no `F_FULLFSYNC`.
#[cfg(all(not(target_os = "macos"), not(test), not(debug_assertions)))]
compile_error!(
    "companion-ffi persistence ships on macOS only: the data protection keychain, F_FULLFSYNC \
     and the state directory the shell excludes from Spotlight and Time Machine have no \
     portable equivalent. The portable path is for tests and CI checks, never for a release \
     artifact (ADR-0012, ADR-0016)."
);

use std::fmt::Write as _;
use std::io::{Read as _, Write};
use std::path::{Path, PathBuf};

use companion_credentials::{CredentialError, CredentialStore};
use ring::aead::{Aad, CHACHA20_POLY1305, LessSafeKey, NONCE_LEN, Nonce, UnboundKey};
use ring::hkdf::{HKDF_SHA256, KeyType, Salt};
use ring::rand::{SecureRandom, SystemRandom};
use zeroize::Zeroizing;

use crate::diagnostics::diag_fault;

/// The state envelope magic, also part of its associated data.
const FILE_MAGIC: &[u8; 8] = b"OTSSEAL3";

/// Envelopes this build replaced: disposed of (ADR-0016), not rotated (Law 0005).
const SUPERSEDED_MAGICS: [&[u8; 8]; 1] = [b"OTSSEAL2"];

/// The ledger envelope magic, also its associated data.
const LEDGER_MAGIC: &[u8; 8] = b"OTSLEDG1";

/// The keychain half of the content key.
const STATE_KEY_ACCOUNT: &str = "state-key";

/// The ledger key: one keychain secret that rotation never touches.
const LEDGER_KEY_ACCOUNT: &str = "ledger-key";

/// ChaCha20-Poly1305 key length, and the length of each key half.
pub(crate) const KEY_LEN: usize = 32;

/// Versioned: changing it orphans every existing state file.
const CONTENT_KEY_INFO: &[u8] = b"ots-companion-content-key-v1";

/// Spells `boot` for history; changing it would rename every file half.
const FILE_HALF_NAME_INFO: &[u8] = b"ots-companion-boot-half-name-v1";

/// Constant salt for the filename tag; the file half cannot salt its own name.
const FILE_HALF_NAME_SALT: &[u8] = b"ots-companion-boot-half-name-salt-v1";

const FILE_HALF_TAG_LEN: usize = 16;

/// HKDF info for the per GOP transport key (ADR-0021, [`crate::gop`]).
pub(crate) const GOP_KEY_INFO: &[u8] = b"ots-companion-gop-transport-key-v1";

/// Salt for the root GOP derivation; rotations salt with the outgoing key.
pub(crate) const GOP_ROOT_SALT: &[u8] = b"ots-companion-gop-root-salt-v1";

/// Magic of a sealed GOP payload, also its associated data.
pub(crate) const GOP_MAGIC: &[u8; 8] = b"OTSGOPD1";

const FILE_HALF_PREFIX: &str = "ots-companion-key-half-";

/// `context ‖ payload`: each signing role has its own context, so a
/// signature cannot verify in another role.
pub(crate) fn signing_domain(context: &[u8], payload: &[u8]) -> Vec<u8> {
    let mut message = Vec::with_capacity(context.len() + payload.len());
    message.extend_from_slice(context);
    message.extend_from_slice(payload);
    message
}

/// Lowercase hex, for public material only.
pub(crate) fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `None` for odd lengths or non-hex bytes.
pub(crate) fn hex_decode(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    text.as_bytes()
        .chunks(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok())
        .collect()
}

/// `magic[8] ‖ sealed_wall_ms[8]`.
pub(crate) const STATE_HEADER_LEN: usize = 8 + 8;

/// Bytes of zeros pushed per pass in [`erase_state`].
const ERASE_CHUNK: usize = 4096;

/// Load the key, or mint and store one if absent. `None` for a refusing
/// backend or a wrongly sized item.
fn ensure_key_for(credentials: &dyn CredentialStore, account: &str) -> Option<Zeroizing<Vec<u8>>> {
    match credentials.load(account) {
        Ok(key) if key.len() == KEY_LEN => Some(key),
        Err(CredentialError::NotFound) => {
            let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
            SystemRandom::new().fill(&mut key).ok()?;
            credentials.store(account, &key).ok()?;
            Some(key)
        }
        Ok(_) | Err(CredentialError::Backend(_)) => None,
    }
}

/// Load only: a fresh key would orphan the existing file.
fn load_key_for(credentials: &dyn CredentialStore, account: &str) -> Option<Zeroizing<Vec<u8>>> {
    match credentials.load(account) {
        Ok(key) if key.len() == KEY_LEN => Some(key),
        Ok(key) => {
            diag_fault!(
                "companion-ffi: the {account} item holds {} bytes, not {KEY_LEN}; refusing it.",
                key.len()
            );
            None
        }
        // Absence is ordinary; a refusing backend deserves a fault.
        Err(CredentialError::NotFound) => None,
        Err(error) => {
            diag_fault!("companion-ffi: the {account} item would not load ({error}).");
            None
        }
    }
}

/// The content key for saving, minting either half if missing. The keychain
/// half lives in [`CredentialStore::key_material_store`], the file half
/// beside `state_path`.
pub(crate) fn ensure_state_key(
    credentials: &dyn CredentialStore,
    state_path: &Path,
) -> Option<Zeroizing<Vec<u8>>> {
    let keys = credentials.key_material_store();
    let keychain_half = ensure_key_for(&*keys, STATE_KEY_ACCOUNT)?;
    let file_half = ensure_file_half(&keychain_half, containing_dir(state_path)?)?;
    derive_content_key(&keychain_half, &file_half)
}

/// The content key for restoring; mints neither half.
pub(crate) fn load_state_key(
    credentials: &dyn CredentialStore,
    state_path: &Path,
) -> Option<Zeroizing<Vec<u8>>> {
    let keys = credentials.key_material_store();
    let keychain_half = load_key_for(&*keys, STATE_KEY_ACCOUNT)?;
    let file_half = read_half(&file_half_path(
        &keychain_half,
        containing_dir(state_path)?,
    )?)?;
    derive_content_key(&keychain_half, &file_half)
}

/// What an erasure left behind, best to worst so `max` keeps the worst.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub(crate) enum Erasure {
    /// Confirmed absent: nothing at the path, not even a dangling link.
    Gone,
    /// Zeroed, truncated and synced; only the unlink was refused.
    Neutralized,
    /// Not confirmed destroyed.
    Survived,
}

/// Forget the content key: erase every file half beside `state_path`, then
/// delete the keychain half. Never reads the keychain (ADR-0004) and never
/// touches `ledger-key`. `Gone` and `Neutralized` both mean forgotten.
pub(crate) fn rotate_key_halves(credentials: &dyn CredentialStore, state_path: &Path) -> Erasure {
    let Some(dir) = containing_dir(state_path) else {
        return Erasure::Survived;
    };
    let erased = erase_file_halves(dir);
    if let Err(error) = credentials.key_material_store().delete(STATE_KEY_ACCOUNT) {
        diag_fault!(
            "companion-ffi: the rotation could not delete the {STATE_KEY_ACCOUNT} item \
             ({error}). The file half is the answer the caller acts on; once it is gone the \
             content is unreadable either way, and what is left behind is a keychain item \
             nothing will use again."
        );
    }
    erased
}

/// Erase every file half in `dir`, not just this store's: telling them apart
/// would need a keychain read. A missing `dir` is `Gone`, an unreadable one
/// `Survived`.
fn erase_file_halves(dir: &Path) -> Erasure {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Erasure::Gone,
        Err(_) => return Erasure::Survived,
    };
    let mut worst = Erasure::Gone;
    for entry in entries {
        let Ok(entry) = entry else {
            worst = Erasure::Survived;
            continue;
        };
        if entry
            .file_name()
            .to_str()
            .is_some_and(|name| name.starts_with(FILE_HALF_PREFIX))
        {
            worst = worst.max(erase_state_outcome(&entry.path()));
        }
    }
    worst
}

/// `HKDF-SHA256(salt = file_half, ikm = keychain_half)` under [`CONTENT_KEY_INFO`].
fn derive_content_key(keychain_half: &[u8], file_half: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let prk = Salt::new(HKDF_SHA256, file_half).extract(keychain_half);
    let okm = prk.expand(&[CONTENT_KEY_INFO], Bytes(KEY_LEN)).ok()?;
    let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
    okm.fill(&mut key).ok()?;
    Some(key)
}

/// An HKDF output length, as `ring`'s [`KeyType`].
#[derive(Clone, Copy)]
pub(crate) struct Bytes(pub(crate) usize);

impl KeyType for Bytes {
    fn len(&self) -> usize {
        self.0
    }
}

/// The file half's path in `dir`, named by an HKDF tag over the keychain half
/// so each form factor's store lands on its own file.
fn file_half_path(keychain_half: &[u8], dir: &Path) -> Option<PathBuf> {
    let prk = Salt::new(HKDF_SHA256, FILE_HALF_NAME_SALT).extract(keychain_half);
    let okm = prk
        .expand(&[FILE_HALF_NAME_INFO], Bytes(FILE_HALF_TAG_LEN))
        .ok()?;
    let mut tag = [0u8; FILE_HALF_TAG_LEN];
    okm.fill(&mut tag).ok()?;
    let mut name = String::with_capacity(FILE_HALF_PREFIX.len() + FILE_HALF_TAG_LEN * 2);
    name.push_str(FILE_HALF_PREFIX);
    for byte in tag {
        write!(name, "{byte:02x}").ok()?;
    }
    Some(dir.join(name))
}

/// The existing file half, or a fresh one. A racing mint costs a save, never
/// a misread.
fn ensure_file_half(keychain_half: &[u8], dir: &Path) -> Option<Zeroizing<Vec<u8>>> {
    let path = file_half_path(keychain_half, dir)?;
    if let Some(existing) = read_half(&path) {
        return Some(existing);
    }
    let mut half = Zeroizing::new(vec![0u8; KEY_LEN]);
    SystemRandom::new().fill(&mut half).ok()?;
    if !write_private(&path, &half) {
        return None;
    }
    Some(half)
}

/// A stored half; a wrong-length file counts as absent.
fn read_half(path: &Path) -> Option<Zeroizing<Vec<u8>>> {
    let bytes = Zeroizing::new(std::fs::read(path).ok()?);
    (bytes.len() == KEY_LEN).then_some(bytes)
}

/// The ledger key for saving, minted if absent.
pub(crate) fn ensure_ledger_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    ensure_key_for(&*credentials.key_material_store(), LEDGER_KEY_ACCOUNT)
}

/// The ledger key for restoring. Load only, never mint.
pub(crate) fn load_ledger_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    load_key_for(&*credentials.key_material_store(), LEDGER_KEY_ACCOUNT)
}

/// `nonce ‖ ciphertext ‖ tag` under a fresh nonce; `aad` is authenticated but
/// not included.
pub(crate) fn seal_body(key: &[u8], aad: &[u8], plaintext: &[u8]) -> Option<Vec<u8>> {
    let key = aead_key(key)?;
    let mut nonce_bytes = [0u8; NONCE_LEN];
    SystemRandom::new().fill(&mut nonce_bytes).ok()?;
    let mut sealed = work_buffer(plaintext);
    key.seal_in_place_append_tag(
        Nonce::assume_unique_for_key(nonce_bytes),
        Aad::from(aad),
        // `Extend` is on the `Vec`, not on the wrapper.
        &mut *sealed,
    )
    .ok()?;
    let mut body = Vec::with_capacity(NONCE_LEN + sealed.len());
    body.extend_from_slice(&nonce_bytes);
    body.extend_from_slice(&sealed);
    Some(body)
}

/// Exact capacity, so appending the tag never strands an unwiped copy.
fn work_buffer(plaintext: &[u8]) -> Zeroizing<Vec<u8>> {
    let mut buffer = Zeroizing::new(Vec::with_capacity(
        plaintext.len() + CHACHA20_POLY1305.tag_len(),
    ));
    buffer.extend_from_slice(plaintext);
    buffer
}

/// The shortest openable body: nonce plus tag.
#[must_use]
pub(crate) fn sealed_body_floor() -> usize {
    NONCE_LEN + CHACHA20_POLY1305.tag_len()
}

/// Open `nonce ‖ ciphertext ‖ tag` against `aad`; wiped on drop.
pub(crate) fn open_body(key: &[u8], aad: &[u8], body: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let key = aead_key(key)?;
    if body.len() < NONCE_LEN {
        return None;
    }
    let (nonce_bytes, ciphertext) = body.split_at(NONCE_LEN);
    let nonce = Nonce::try_assume_unique_for_key(nonce_bytes).ok()?;
    let mut buffer = Zeroizing::new(ciphertext.to_vec());
    let plaintext_len = key
        .open_in_place(nonce, Aad::from(aad), &mut buffer)
        .ok()?
        .len();
    buffer.truncate(plaintext_len);
    Some(buffer)
}

/// The authenticated head of a state file.
struct StateHeader {
    /// Unix epoch milliseconds at the save.
    sealed_wall_ms: u64,
}

impl StateHeader {
    /// The on-disk bytes, which are also the associated data.
    fn to_bytes(&self) -> [u8; STATE_HEADER_LEN] {
        let mut out = [0u8; STATE_HEADER_LEN];
        out[..8].copy_from_slice(FILE_MAGIC.as_slice());
        out[8..16].copy_from_slice(&self.sealed_wall_ms.to_be_bytes());
        out
    }

    /// `None` for a short file or any other magic.
    fn parse(file: &[u8]) -> Option<Self> {
        let head = file.get(..STATE_HEADER_LEN)?;
        if !head.starts_with(FILE_MAGIC.as_slice()) {
            return None;
        }
        Some(Self {
            sealed_wall_ms: u64::from_be_bytes(head[8..16].try_into().ok()?),
        })
    }
}

/// What a state file turned out to be.
pub(crate) enum Opened {
    /// Authenticated and decrypted, with the stamp its header carried.
    Plaintext {
        /// The snapshot the core reads back, wiped on drop.
        plaintext: Zeroizing<Vec<u8>>,
        /// Unix epoch milliseconds at the save.
        sealed_wall_ms: u64,
    },
    /// An envelope this app replaced; the caller disposes of it (ADR-0016).
    Superseded,
    /// Unreadable or unopenable; the caller leaves it in place.
    Refused,
}

/// Seal under the state envelope, stamped `sealed_wall_ms`.
pub(crate) fn seal_state(key: &[u8], plaintext: &[u8], sealed_wall_ms: u64) -> Option<Vec<u8>> {
    let header = StateHeader { sealed_wall_ms }.to_bytes();
    let body = seal_body(key, &header, plaintext)?;
    let mut file = Vec::with_capacity(header.len() + body.len());
    file.extend_from_slice(&header);
    file.extend_from_slice(&body);
    Some(file)
}

/// Open the state envelope. `key` is called only for this build's magic, so
/// an unreadable file costs no keychain prompt (ADR-0004). Only
/// [`SUPERSEDED_MAGICS`] lead to disposal.
pub(crate) fn open_state(file: &[u8], key: impl FnOnce() -> Option<Zeroizing<Vec<u8>>>) -> Opened {
    let Some(header) = StateHeader::parse(file) else {
        if let Some(magic) = superseded_magic(file) {
            diag_fault!(
                "companion-ffi: the state file carries {magic}, an envelope this build has \
                 replaced. Nothing in it can be decrypted, so it is being dropped and this \
                 session will write a new one. Whatever was staged under it is gone."
            );
            return Opened::Superseded;
        }
        diag_fault!(
            "companion-ffi: the state file does not carry this build's envelope header; \
             refusing it and leaving it where it is."
        );
        return Opened::Refused;
    };
    let Some(key) = key() else {
        diag_fault!(
            "companion-ffi: the state file carries this build's envelope, but its content key \
             could not be assembled. Either the keychain half would not load or the file half \
             is missing from the state directory; the file stays and this session will not \
             write one."
        );
        return Opened::Refused;
    };
    let Some(plaintext) = open_body(&key, &file[..STATE_HEADER_LEN], &file[STATE_HEADER_LEN..])
    else {
        diag_fault!(
            "companion-ffi: the state file would not authenticate under the assembled content \
             key. The halves this session holds are not the halves that sealed it."
        );
        return Opened::Refused;
    };
    Opened::Plaintext {
        plaintext,
        sealed_wall_ms: header.sealed_wall_ms,
    }
}

/// The superseded magic `file` carries, as ASCII for the diagnostic.
fn superseded_magic(file: &[u8]) -> Option<&'static str> {
    SUPERSEDED_MAGICS
        .iter()
        .find(|magic| file.starts_with(magic.as_slice()))
        .and_then(|magic| std::str::from_utf8(magic.as_slice()).ok())
}

/// Seal under the ledger envelope, which carries no stamp.
pub(crate) fn seal_ledger(key: &[u8], plaintext: &[u8]) -> Option<Vec<u8>> {
    let body = seal_body(key, LEDGER_MAGIC, plaintext)?;
    let mut file = Vec::with_capacity(LEDGER_MAGIC.len() + body.len());
    file.extend_from_slice(LEDGER_MAGIC);
    file.extend_from_slice(&body);
    Some(file)
}

/// Open the ledger envelope.
pub(crate) fn open_ledger(key: &[u8], file: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let body = file.strip_prefix(LEDGER_MAGIC.as_slice())?;
    open_body(key, LEDGER_MAGIC, body)
}

/// Zero, truncate, sync and unlink a file this app wrote; `true` only when
/// the path is confirmed empty (a dangling link counts as present). Best
/// effort, not erasure: APFS is copy on write, so the forgetting is
/// [`rotate_key_halves`]. Never follows a final symlink or blocks on a FIFO;
/// a hard link still passes, so the owner-only state directory is the
/// containment.
pub(crate) fn erase_state(path: &Path) -> bool {
    erase_state_outcome(path) == Erasure::Gone
}

/// The tri-state behind [`erase_state`]; `Neutralized` only once the zeros
/// are synced.
pub(crate) fn erase_state_outcome(path: &Path) -> Erasure {
    let mut zeroed = false;
    if let Ok(mut file) = open_for_erase(path)
        && let Ok(metadata) = file.metadata()
        && metadata.file_type().is_file()
    {
        let zeros = [0u8; ERASE_CHUNK];
        let mut remaining = metadata.len();
        let mut wrote = true;
        while remaining > 0 {
            let chunk = usize::try_from(remaining)
                .unwrap_or(ERASE_CHUNK)
                .min(ERASE_CHUNK);
            if file.write_all(&zeros[..chunk]).is_err() {
                wrote = false;
                break;
            }
            remaining = remaining.saturating_sub(chunk as u64);
        }
        zeroed = wrote && file.set_len(0).is_ok() && file.sync_all().is_ok();
    }
    let _ = std::fs::remove_file(path);
    // A stat that cannot answer is not gone.
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Erasure::Gone,
        _ if zeroed => Erasure::Neutralized,
        _ => Erasure::Survived,
    }
}

/// Erase every stranded [`write_private`] temp in `dir`; launch only. Matches
/// the exact temp shape, since erasing zeroes whatever it is given.
pub(crate) fn sweep_stranded_temps(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        if entry
            .file_name()
            .to_str()
            .is_some_and(is_write_private_temp)
        {
            erase_state(&entry.path());
        }
    }
}

/// The [`write_private`] temp shape: `<name>.<16 hex>.tmp`.
fn is_write_private_temp(name: &str) -> bool {
    let Some(rest) = name.strip_suffix(".tmp") else {
        return false;
    };
    let Some((stem, tag)) = rest.rsplit_once('.') else {
        return false;
    };
    !stem.is_empty() && tag.len() == 16 && tag.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Whether dropping `path` rotates the content key: the state file's name
/// (asked first, since an unreadable file still has one) or a content magic.
/// A ledger clear must never rotate.
pub(crate) fn drop_takes_the_content_key(path: &Path) -> bool {
    names_the_content_file(path) || holds_content_envelope(path)
}

/// The name `FormFactor.stateFileURL` gives; a rename there falls back to the magic.
const STATE_FILE_NAME: &str = "state.sealed";

fn names_the_content_file(path: &Path) -> bool {
    path.file_name().and_then(|name| name.to_str()) == Some(STATE_FILE_NAME)
}

/// Whether `path` carries a content magic, current or superseded. Opens like
/// [`open_for_erase`].
fn holds_content_envelope(path: &Path) -> bool {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(O_NOFOLLOW | O_NONBLOCK);
    }
    let Ok(mut file) = options.open(path) else {
        return false;
    };
    let mut magic = [0u8; 8];
    file.read_exact(&mut magic).is_ok()
        && (magic == *FILE_MAGIC || SUPERSEDED_MAGICS.iter().any(|old| magic == **old))
}

/// Open for writing without following a final symlink (no stat-then-open
/// race) or blocking on a FIFO.
fn open_for_erase(path: &Path) -> std::io::Result<std::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true);
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(O_NOFOLLOW | O_NONBLOCK);
    }
    options.open(path)
}

/// `O_NOFOLLOW` on macOS.
#[cfg(target_os = "macos")]
const O_NOFOLLOW: i32 = libc::O_NOFOLLOW;

/// `O_NOFOLLOW` on the Linux test host, which takes no `libc`.
#[cfg(target_os = "linux")]
const O_NOFOLLOW: i32 = 0x0002_0000;

/// `O_NONBLOCK` on macOS; shared with `files.rs`.
#[cfg(target_os = "macos")]
pub(crate) const O_NONBLOCK: i32 = libc::O_NONBLOCK;

/// `O_NONBLOCK` on the Linux test host.
#[cfg(target_os = "linux")]
pub(crate) const O_NONBLOCK: i32 = 0x0000_0800;

/// Credential stores that misbehave the way shipping backends can; shared
/// with the `lib.rs` tests.
#[cfg(test)]
pub(crate) mod test_stores {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    use companion_credentials::{CredentialError, CredentialStore, InMemoryCredentialStore};
    use zeroize::Zeroizing;

    /// An in-memory store whose `delete` always fails.
    #[derive(Clone, Default)]
    pub(crate) struct RefusesToDelete {
        inner: Arc<InMemoryCredentialStore>,
    }

    impl CredentialStore for RefusesToDelete {
        fn store(&self, account: &str, secret: &[u8]) -> Result<(), CredentialError> {
            self.inner.store(account, secret)
        }

        fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, CredentialError> {
            self.inner.load(account)
        }

        fn delete(&self, _account: &str) -> Result<(), CredentialError> {
            Err(CredentialError::Backend(
                "the keychain is locked; the item was not deleted".to_string(),
            ))
        }

        fn exists(&self, account: &str) -> Result<bool, CredentialError> {
            self.inner.exists(account)
        }

        fn key_material_store(&self) -> Arc<dyn CredentialStore> {
            Arc::new(self.clone())
        }
    }

    /// A store whose reads, deletes and existence checks all fail; `store`
    /// succeeds.
    #[derive(Clone, Default)]
    pub(crate) struct AnswersNothing {
        inner: Arc<InMemoryCredentialStore>,
    }

    impl AnswersNothing {
        /// The backing store, bypassing the refusals.
        pub(crate) fn behind_the_refusal(&self) -> &InMemoryCredentialStore {
            &self.inner
        }
    }

    impl CredentialStore for AnswersNothing {
        fn store(&self, account: &str, secret: &[u8]) -> Result<(), CredentialError> {
            self.inner.store(account, secret)
        }

        fn load(&self, _account: &str) -> Result<Zeroizing<Vec<u8>>, CredentialError> {
            Err(CredentialError::Backend(
                "the keychain is locked; nothing was read".to_string(),
            ))
        }

        fn delete(&self, _account: &str) -> Result<(), CredentialError> {
            Err(CredentialError::Backend(
                "the keychain is locked; the item was not deleted".to_string(),
            ))
        }

        fn exists(&self, _account: &str) -> Result<bool, CredentialError> {
            Err(CredentialError::Backend(
                "the keychain is locked; it will not say".to_string(),
            ))
        }

        fn key_material_store(&self) -> Arc<dyn CredentialStore> {
            Arc::new(self.clone())
        }
    }

    /// A store that answers until [`GoesSilent::lock`], like a keychain locked
    /// between a save and the next launch. Clones share the lock.
    #[derive(Clone, Default)]
    pub(crate) struct GoesSilent {
        inner: Arc<InMemoryCredentialStore>,
        locked: Arc<AtomicBool>,
    }

    impl GoesSilent {
        /// Fail every call from now on.
        pub(crate) fn lock(&self) {
            self.locked.store(true, Ordering::SeqCst);
        }

        /// Answer again.
        pub(crate) fn unlock(&self) {
            self.locked.store(false, Ordering::SeqCst);
        }

        /// The backing store, bypassing the lock.
        pub(crate) fn behind_the_lock(&self) -> &InMemoryCredentialStore {
            &self.inner
        }

        fn refusal<T>(&self) -> Option<Result<T, CredentialError>> {
            self.locked.load(Ordering::SeqCst).then(|| {
                Err(CredentialError::Backend(
                    "the keychain is locked; it will not answer".to_string(),
                ))
            })
        }
    }

    impl CredentialStore for GoesSilent {
        fn store(&self, account: &str, secret: &[u8]) -> Result<(), CredentialError> {
            self.refusal()
                .unwrap_or_else(|| self.inner.store(account, secret))
        }

        fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, CredentialError> {
            self.refusal().unwrap_or_else(|| self.inner.load(account))
        }

        fn delete(&self, account: &str) -> Result<(), CredentialError> {
            self.refusal().unwrap_or_else(|| self.inner.delete(account))
        }

        fn exists(&self, account: &str) -> Result<bool, CredentialError> {
            self.refusal().unwrap_or_else(|| self.inner.exists(account))
        }

        fn key_material_store(&self) -> Arc<dyn CredentialStore> {
            Arc::new(self.clone())
        }
    }

    /// A store whose key material store is a disjoint map, like the login and
    /// data protection keychains.
    #[derive(Clone, Default)]
    pub(crate) struct SplitKeyStore {
        handed: Arc<InMemoryCredentialStore>,
        keys: Arc<InMemoryCredentialStore>,
    }

    impl SplitKeyStore {
        /// The handle's own store, where no key material may appear.
        pub(crate) fn handed(&self) -> &InMemoryCredentialStore {
            &self.handed
        }

        /// The key material store.
        pub(crate) fn keys(&self) -> &InMemoryCredentialStore {
            &self.keys
        }
    }

    impl CredentialStore for SplitKeyStore {
        fn store(&self, account: &str, secret: &[u8]) -> Result<(), CredentialError> {
            self.handed.store(account, secret)
        }

        fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, CredentialError> {
            self.handed.load(account)
        }

        fn delete(&self, account: &str) -> Result<(), CredentialError> {
            self.handed.delete(account)
        }

        fn exists(&self, account: &str) -> Result<bool, CredentialError> {
            self.handed.exists(account)
        }

        fn key_material_store(&self) -> Arc<dyn CredentialStore> {
            self.keys.key_material_store()
        }
    }
}

/// Write atomically (create-new random temp, fsync, rename, fsync the
/// directory) at mode 0600.
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

/// Best effort: a failed directory sync never unwrites the save.
fn sync_parent_dir(path: &Path) {
    if let Some(parent) = containing_dir(path) {
        let _ = sync_dir(parent);
    }
}

/// The directory holding `path`'s entry; a bare filename gives `.`.
pub(crate) fn containing_dir(path: &Path) -> Option<&Path> {
    match path.parent() {
        None => None,
        Some(parent) if parent.as_os_str().is_empty() => Some(Path::new(".")),
        Some(parent) => Some(parent),
    }
}

/// Split out so a test can see it fail.
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
        let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
        SystemRandom::new().fill(&mut key).unwrap();
        key
    }

    fn seal(key: &[u8], plaintext: &[u8]) -> Vec<u8> {
        seal_state(key, plaintext, 1_700_000_000_000).unwrap()
    }

    fn plaintext_of(opened: Opened) -> Option<Zeroizing<Vec<u8>>> {
        match opened {
            Opened::Plaintext { plaintext, .. } => Some(plaintext),
            Opened::Superseded | Opened::Refused => None,
        }
    }

    fn open(key: &Zeroizing<Vec<u8>>, file: &[u8]) -> Opened {
        open_state(file, || Some(key.clone()))
    }

    /// A scratch state directory, removed on drop.
    struct StateDir(std::path::PathBuf);

    impl StateDir {
        fn new() -> Self {
            Self(scratch_dir())
        }

        fn state_path(&self) -> std::path::PathBuf {
            self.0.join("state.sealed")
        }

        fn halves(&self) -> Vec<std::ffi::OsString> {
            let mut names: Vec<_> = std::fs::read_dir(&self.0)
                .unwrap()
                .map(|entry| entry.unwrap().file_name())
                .filter(|name| {
                    name.to_str()
                        .is_some_and(|name| name.starts_with(FILE_HALF_PREFIX))
                })
                .collect();
            names.sort();
            names
        }
    }

    impl Drop for StateDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn seal_and_open_round_trip() {
        let key = key();
        let sealed = seal_state(&key, b"the whole store, serialized", 1_234).unwrap();
        let Opened::Plaintext {
            plaintext,
            sealed_wall_ms,
        } = open(&key, &sealed)
        else {
            panic!("a file sealed under this build's envelope did not open");
        };
        assert_eq!(&*plaintext, b"the whole store, serialized");
        assert_eq!(sealed_wall_ms, 1_234, "the wall stamp came back changed");
    }

    #[test]
    fn the_file_never_contains_the_plaintext() {
        let key = key();
        let secret = b"ghp_this-must-not-appear-on-disk";
        let sealed = seal(&key, secret);
        assert!(
            !sealed.windows(secret.len()).any(|w| w == secret),
            "plaintext leaked into the sealed file"
        );
    }

    #[test]
    fn tampering_anywhere_fails_authentication() {
        let key = key();
        let sealed = seal(&key, b"payload");
        for index in 0..sealed.len() {
            let mut bent = sealed.clone();
            bent[index] ^= 0x01;
            assert!(
                plaintext_of(open(&key, &bent)).is_none(),
                "a flipped bit at {index} still opened"
            );
        }
        assert!(plaintext_of(open(&key, &sealed[..sealed.len() - 1])).is_none());

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

    #[test]
    fn key_material_lives_in_the_key_store_and_rotation_deletes_it_there() {
        let dir = StateDir::new();
        let state_path = dir.state_path();
        let store = test_stores::SplitKeyStore::default();

        let state = ensure_state_key(&store, &state_path).unwrap();
        let ledger = ensure_ledger_key(&store).unwrap();
        assert!(store.keys().exists(STATE_KEY_ACCOUNT).unwrap());
        assert!(store.keys().exists(LEDGER_KEY_ACCOUNT).unwrap());
        assert!(
            !store.handed().exists(STATE_KEY_ACCOUNT).unwrap(),
            "the content key's keychain half stayed on the login keychain path"
        );
        assert!(
            !store.handed().exists(LEDGER_KEY_ACCOUNT).unwrap(),
            "the ledger key stayed on the login keychain path"
        );

        assert_eq!(&*load_state_key(&store, &state_path).unwrap(), &*state);
        assert_eq!(&*load_ledger_key(&store).unwrap(), &*ledger);

        assert_eq!(rotate_key_halves(&store, &state_path), Erasure::Gone);
        assert!(
            !store.keys().exists(STATE_KEY_ACCOUNT).unwrap(),
            "rotation deleted nothing: the old keychain half survived"
        );
        assert!(
            store.keys().exists(LEDGER_KEY_ACCOUNT).unwrap(),
            "rotation took the long-lived ledger key with it"
        );
    }

    #[test]
    fn the_ledger_key_is_a_separate_credential() {
        let dir = StateDir::new();
        let store = InMemoryCredentialStore::default();
        let state = ensure_state_key(&store, &dir.state_path()).unwrap();
        let ledger = ensure_ledger_key(&store).unwrap();
        assert_ne!(&*state, &*ledger, "one key sealing both files");
        assert_eq!(&*ensure_ledger_key(&store).unwrap(), &*ledger, "stable");

        let content_only = InMemoryCredentialStore::default();
        ensure_state_key(&content_only, &dir.state_path()).unwrap();
        assert!(
            load_ledger_key(&content_only).is_none(),
            "restore must never mint a ledger key"
        );
    }

    #[test]
    fn a_ledger_file_cannot_be_opened_as_a_state_file() {
        let key = key();
        let as_ledger = seal_ledger(&key, b"one audit record").unwrap();
        assert!(plaintext_of(open(&key, &as_ledger)).is_none());
        let as_state = seal(&key, b"staged content");
        assert!(open_ledger(&key, &as_state).is_none());
    }

    #[test]
    fn the_wrong_key_opens_nothing() {
        let sealed = seal(&key(), b"payload");
        assert!(
            plaintext_of(open(&key(), &sealed)).is_none(),
            "keys are independent"
        );
    }

    #[test]
    fn a_v1_file_is_refused() {
        let key = key();
        let mut v1 = seal(&key, b"staged content from the oldest format");
        v1[..8].copy_from_slice(b"OTSSEAL1");
        assert!(
            matches!(open(&key, &v1), Opened::Refused),
            "a v1 file must be refused, not disposed of"
        );
        assert!(matches!(open(&key, b"OTSSEAL3"), Opened::Refused));
        assert!(matches!(open(&key, b""), Opened::Refused));
        let mut stranger = seal(&key, b"staged content from nowhere");
        stranger[..8].copy_from_slice(b"OTSSEAL9");
        assert!(matches!(open(&key, &stranger), Opened::Refused));
    }

    #[test]
    fn a_superseded_file_is_disposed_of_rather_than_refused() {
        let key = key();
        let mut v2 = seal(&key, b"staged content from the boot-bound format");
        v2[..8].copy_from_slice(b"OTSSEAL2");
        assert!(matches!(
            open_state(&v2, || panic!("a superseded file cost a keychain access")),
            Opened::Superseded
        ));
        assert!(matches!(
            open_state(b"OTSSEAL2", || None),
            Opened::Superseded
        ));
    }

    #[test]
    fn the_superseded_set_predates_the_key_half_move() {
        assert_eq!(
            SUPERSEDED_MAGICS.as_slice(),
            [b"OTSSEAL2"].as_slice(),
            "the superseded set changed. Every entry it held predated ADR-0016's move of the \
             file half out of the per-boot temp directory, which is what lets the disposal arm \
             in companion_persist_restore drop a file without rotating: such a file's other \
             half is presumed cleared with that directory, so what stays reachable is the \
             keychain half alone, which opens nothing by itself. An entry sealed after the \
             move has its file half in the state directory, durable and reachable, beside that \
             same live keychain half, so disposing of the file alone would leave a whole \
             working key for whatever copy of that ciphertext already exists. Decide whether \
             that arm must now rotate before changing this line."
        );
    }

    /// Byte 7 is the version digit; `OTSSEAL3` and `OTSSEAL2` are one bit apart.
    #[test]
    fn header_fields_are_authenticated() {
        let key = key();
        let sealed = seal_state(&key, b"payload", 1_700_000_000_000).unwrap();

        for index in 0..STATE_HEADER_LEN {
            let mut bent = sealed.clone();
            bent[index] ^= 0x01;
            match open(&key, &bent) {
                Opened::Refused => {}
                Opened::Superseded => assert_eq!(
                    index, 7,
                    "an edited header byte at {index} read as one of this app's own past formats"
                ),
                Opened::Plaintext { .. } => {
                    panic!("an edited header byte at {index} still opened")
                }
            }
        }
    }

    #[test]
    fn the_ledger_envelope_is_its_own() {
        let key = key();
        let record = seal_ledger(&key, b"created 0001, sent link").unwrap();
        assert_eq!(
            &*open_ledger(&key, &record).unwrap(),
            b"created 0001, sent link"
        );
        assert!(
            !record.starts_with(FILE_MAGIC.as_slice()),
            "the ledger must not carry the state envelope's magic"
        );
        assert!(
            !SUPERSEDED_MAGICS
                .iter()
                .any(|magic| record.starts_with(magic.as_slice())),
            "a ledger file would be disposed of as a superseded state file"
        );
    }

    #[test]
    fn the_sweep_takes_stranded_temp_generations_and_nothing_else() {
        let dir = scratch_dir();
        let sealed = seal(&key(), b"a generation that never got its name");
        let stranded = dir.join("state.sealed.0123456789abcdef.tmp");
        std::fs::write(&stranded, &sealed).unwrap();
        std::fs::write(dir.join("ledger.sealed.fedcba9876543210.tmp"), b"audit").unwrap();
        std::fs::write(
            dir.join("ots-companion-key-half-00112233.00112233445566aa.tmp"),
            [0x5A; KEY_LEN],
        )
        .unwrap();

        let spared = [
            "state.sealed",
            "ledger.sealed",
            "notes.tmp",
            ".tmp",
            "state.sealed.notsixteenhex.tmp",
            "state.sealed.0123456789abcdefg.tmp",
            "state.sealed.0123456789abcdef.tmp.keep",
        ];
        for name in spared {
            std::fs::write(dir.join(name), b"not this app's to erase").unwrap();
        }

        sweep_stranded_temps(&dir);

        assert_eq!(
            temp_litter(&dir).len(),
            spared.len() - 1,
            "the sweep took a file that was not a stranded generation, or left one that was"
        );
        assert!(!stranded.exists(), "a stranded generation survived");
        for name in spared {
            assert!(dir.join(name).exists(), "the sweep took {name}");
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn sweeping_a_directory_with_nothing_to_sweep_changes_nothing() {
        let absent = Path::new("/nowhere/at/all");
        sweep_stranded_temps(absent);
        assert!(!absent.exists(), "the sweep created the path it was given");

        let dir = scratch_dir();
        let kept = ["state.sealed", "ledger.sealed", "notes.txt"];
        for name in kept {
            std::fs::write(dir.join(name), b"not a stranded generation").unwrap();
        }
        sweep_stranded_temps(&dir);
        for name in kept {
            assert!(dir.join(name).exists(), "the sweep took {name}");
        }
        assert_eq!(temp_litter(&dir).len(), kept.len() - 1);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn erase_state_leaves_no_file() {
        let dir = scratch_dir();
        let target = dir.join("state.sealed");
        assert!(write_private(&target, &seal(&key(), b"staged content")));
        assert!(target.exists());
        assert!(erase_state(&target));
        assert!(!target.exists());
        assert!(erase_state(&target), "erasing nothing is not a failure");
        assert_eq!(temp_litter(&dir), Vec::<std::ffi::OsString>::new());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn erase_never_follows_a_symlink_planted_at_the_state_path() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch_dir();
        let target = dir.join("state.sealed");
        let victim = dir.join("victim");
        let contents = b"a file this app has no business writing";
        std::fs::write(&victim, contents).unwrap();
        std::os::unix::fs::symlink(&victim, &target).unwrap();

        assert!(erase_state(&target), "the planted link was left behind");
        assert_eq!(
            std::fs::read(&victim).unwrap(),
            contents,
            "erase followed the symlink and zeroed another file"
        );
        assert_eq!(
            std::fs::metadata(&victim).unwrap().len(),
            contents.len() as u64,
            "erase followed the symlink and truncated another file"
        );
        assert!(
            std::fs::symlink_metadata(&target).is_err(),
            "the link itself is still at the state path"
        );

        // A dangling link still at the path is not erased.
        std::os::unix::fs::symlink(dir.join("absent"), &target).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
        let removable = std::fs::remove_file(&target).is_ok();
        if !removable {
            assert!(
                !erase_state(&target),
                "a dangling link still at the path was reported as erased"
            );
        }
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Runs against a deadline so a regression fails rather than hangs.
    #[cfg(unix)]
    #[test]
    fn erase_never_blocks_on_a_fifo_planted_at_the_state_path() {
        let dir = scratch_dir();
        let target = dir.join("state.sealed");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&target)
                .status()
                .unwrap()
                .success(),
            "the test could not plant a FIFO to check against"
        );

        let (answered, answer) = std::sync::mpsc::channel();
        let planted = target.clone();
        std::thread::spawn(move || {
            let _ = answered.send(erase_state(&planted));
        });
        let erased = answer
            .recv_timeout(std::time::Duration::from_secs(10))
            .expect("the erase blocked inside the open: a planted FIFO freezes the app");

        assert!(erased, "the planted FIFO was left at the state path");
        assert!(
            std::fs::symlink_metadata(&target).is_err(),
            "the FIFO itself is still at the state path"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The erase truncates its own zeros away, so the write is checked here.
    #[cfg(unix)]
    #[test]
    fn the_erase_open_still_writes_a_regular_file_whole() {
        let dir = scratch_dir();
        let target = dir.join("state.sealed");
        let original = vec![0xA5_u8; ERASE_CHUNK * 3 + 17];
        std::fs::write(&target, &original).unwrap();

        let mut file = open_for_erase(&target).unwrap();
        let zeros = vec![0u8; original.len()];
        file.write_all(&zeros)
            .expect("a non-blocking open cost the regular-file write");
        file.sync_all().unwrap();
        assert_eq!(
            std::fs::read(&target).unwrap(),
            zeros,
            "the overwrite did not land whole"
        );
        file.set_len(0).unwrap();
        file.sync_all().unwrap();
        assert_eq!(std::fs::metadata(&target).unwrap().len(), 0);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_seal_work_buffer_is_exact_and_self_wiping() {
        let plaintext = vec![0x5A_u8; 4096];
        let buffer: Zeroizing<Vec<u8>> = work_buffer(&plaintext);
        assert_eq!(&*buffer, &plaintext);
        assert_eq!(
            buffer.capacity(),
            plaintext.len() + CHACHA20_POLY1305.tag_len(),
            "a work buffer that grows strands a copy of the snapshot"
        );
        let body = seal_body(&key(), b"aad", &plaintext).unwrap();
        assert_eq!(
            body.len(),
            NONCE_LEN + plaintext.len() + CHACHA20_POLY1305.tag_len(),
            "sealing wrote past the reserved room"
        );
    }

    #[test]
    fn ensure_is_stable_and_load_never_mints() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        assert!(
            load_state_key(&store, &path).is_none(),
            "restore must not mint a key for a file it cannot decrypt anyway"
        );
        assert!(
            dir.halves().is_empty(),
            "a restore that found no keychain half still wrote a file half"
        );
        let first = ensure_state_key(&store, &path).unwrap();
        let second = ensure_state_key(&store, &path).unwrap();
        assert_eq!(&*first, &*second, "the key survives across saves");
        assert_eq!(&*load_state_key(&store, &path).unwrap(), &*first);
        assert_eq!(dir.halves().len(), 1, "one store, one file half");
    }

    #[test]
    fn changing_either_half_changes_the_derived_key() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        let original = ensure_state_key(&store, &path).unwrap();

        let keychain_half = load_key_for(&store, STATE_KEY_ACCOUNT).unwrap();
        let half_path = file_half_path(&keychain_half, containing_dir(&path).unwrap()).unwrap();
        std::fs::remove_file(&half_path).unwrap();
        let after = ensure_state_key(&store, &path).unwrap();
        assert_ne!(
            &*original, &*after,
            "a fresh file half derived the same key"
        );
        assert_eq!(
            &*load_key_for(&store, STATE_KEY_ACCOUNT).unwrap(),
            &*keychain_half,
            "a fresh file half must not disturb the keychain half"
        );

        let other = InMemoryCredentialStore::default();
        let stranger = ensure_state_key(&other, &path).unwrap();
        assert_ne!(&*after, &*stranger);
        assert_eq!(
            dir.halves().len(),
            2,
            "two credential stores must not share a file half"
        );

        let file_half = read_half(&half_path).unwrap();
        assert_eq!(
            &*derive_content_key(&keychain_half, &file_half).unwrap(),
            &*after
        );
        assert_ne!(
            &*derive_content_key(&file_half, &keychain_half).unwrap(),
            &*after,
            "the halves are not interchangeable"
        );
    }

    #[test]
    fn a_missing_file_half_is_never_minted_on_restore() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store, &path).unwrap();
        let keychain_half = load_key_for(&store, STATE_KEY_ACCOUNT).unwrap();
        std::fs::remove_file(
            file_half_path(&keychain_half, containing_dir(&path).unwrap()).unwrap(),
        )
        .unwrap();

        assert!(
            load_state_key(&store, &path).is_none(),
            "restore minted a half"
        );
        assert!(dir.halves().is_empty(), "restore wrote a file half");
    }

    #[cfg(unix)]
    #[test]
    fn the_file_half_is_owner_only_and_sits_in_the_state_directory() {
        use std::os::unix::fs::PermissionsExt;
        let dir = StateDir::new();
        let state_path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store, &state_path).unwrap();
        let path = file_half_path(
            &load_key_for(&store, STATE_KEY_ACCOUNT).unwrap(),
            containing_dir(&state_path).unwrap(),
        )
        .unwrap();
        let metadata = std::fs::metadata(&path).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(metadata.len(), KEY_LEN as u64);
        assert_eq!(
            path.parent(),
            state_path.parent(),
            "the file half did not land beside the file it keys"
        );
        assert!(
            path.file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with(FILE_HALF_PREFIX)
        );
    }

    #[test]
    fn rotate_key_halves_makes_a_sealed_file_unopenable() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        let key = ensure_state_key(&store, &path).unwrap();
        let sealed = seal(&key, b"staged content the user has discarded");

        assert_eq!(
            rotate_key_halves(&store, &path),
            Erasure::Gone,
            "a rotation that removed both halves reported failure"
        );
        assert!(dir.halves().is_empty(), "the file half survived rotation");
        assert!(
            load_key_for(&store, STATE_KEY_ACCOUNT).is_none(),
            "the keychain half survived rotation"
        );
        assert!(
            load_state_key(&store, &path).is_none(),
            "a rotated store still produced a content key"
        );

        let fresh = ensure_state_key(&store, &path).unwrap();
        assert_ne!(&*fresh, &*key);
        assert!(
            plaintext_of(open(&fresh, &sealed)).is_none(),
            "the pre-rotation file opened under the post-rotation key"
        );
    }

    #[test]
    fn rotation_leaves_the_ledger_key_intact() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store, &path).unwrap();
        let ledger = ensure_ledger_key(&store).unwrap();
        let record = seal_ledger(&ledger, b"created 0001, sent clipboard").unwrap();

        assert_eq!(rotate_key_halves(&store, &path), Erasure::Gone);

        assert_eq!(
            &*load_ledger_key(&store).unwrap(),
            &*ledger,
            "rotation moved the ledger key"
        );
        assert_eq!(
            &*open_ledger(&load_ledger_key(&store).unwrap(), &record).unwrap(),
            b"created 0001, sent clipboard",
            "the audit record did not survive a content rotation"
        );
    }

    #[test]
    fn rotating_an_empty_store_is_not_an_error() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        assert_eq!(rotate_key_halves(&store, &path), Erasure::Gone);
        assert_eq!(rotate_key_halves(&store, &path), Erasure::Gone);
        assert!(dir.halves().is_empty());
        assert!(load_state_key(&store, &path).is_none());
    }

    #[test]
    fn a_rotation_the_keychain_refused_still_forgot_the_content() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = test_stores::RefusesToDelete::default();
        let key = ensure_state_key(&store, &path).unwrap();
        let sealed = seal(&key, b"staged content the user has discarded");

        assert_eq!(
            rotate_key_halves(&store, &path),
            Erasure::Gone,
            "a rotation that erased the file half reported failure"
        );
        assert!(dir.halves().is_empty(), "the file half survived rotation");
        assert!(
            load_key_for(&store, STATE_KEY_ACCOUNT).is_some(),
            "the refusing store lost the item it refused to delete"
        );
        assert!(
            load_state_key(&store, &path).is_none(),
            "the content key was reassembled after a rotation"
        );
        let fresh = ensure_state_key(&store, &path).unwrap();
        assert!(
            plaintext_of(open(&fresh, &sealed)).is_none(),
            "the pre-rotation file opened after the rotation"
        );
    }

    #[test]
    fn a_rotation_against_a_keychain_that_answers_nothing_still_erases_the_half() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = test_stores::AnswersNothing::default();
        let keychain_half = Zeroizing::new(vec![0x5A_u8; KEY_LEN]);
        store.store(STATE_KEY_ACCOUNT, &keychain_half).unwrap();
        let half_path = file_half_path(&keychain_half, containing_dir(&path).unwrap()).unwrap();
        assert!(write_private(&half_path, &keychain_half));
        assert_eq!(dir.halves().len(), 1);

        assert_eq!(
            rotate_key_halves(&store, &path),
            Erasure::Gone,
            "a keychain that would not answer stopped the erase and reported it as a refusal"
        );
        assert!(
            dir.halves().is_empty(),
            "the file half outlived a rotation that could not read the keychain"
        );
        assert!(
            store
                .behind_the_refusal()
                .exists(STATE_KEY_ACCOUNT)
                .unwrap(),
            "the store under test lost an item it was supposed to refuse to delete"
        );
    }

    #[test]
    fn rotation_erases_the_half_rather_than_unlinking_it() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store, &path).unwrap();
        let half_path = file_half_path(
            &load_key_for(&store, STATE_KEY_ACCOUNT).unwrap(),
            containing_dir(&path).unwrap(),
        )
        .unwrap();

        // A hard link to the inode shows the zeroing an unlink alone would not.
        let witness = dir.0.join("witness");
        std::fs::hard_link(&half_path, &witness).unwrap();
        assert_eq!(std::fs::read(&witness).unwrap().len(), KEY_LEN);

        assert_eq!(rotate_key_halves(&store, &path), Erasure::Gone);

        assert!(dir.halves().is_empty());
        assert_eq!(
            std::fs::read(&witness).unwrap(),
            Vec::<u8>::new(),
            "the file half was unlinked with its key material still in it"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_half_that_cannot_be_unlinked_is_still_zeroed_and_says_so() {
        use std::os::unix::fs::PermissionsExt;
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store, &path).unwrap();
        let half_path = file_half_path(
            &load_key_for(&store, STATE_KEY_ACCOUNT).unwrap(),
            containing_dir(&path).unwrap(),
        )
        .unwrap();

        // No write on the directory: zeroable, not unlinkable.
        std::fs::set_permissions(&dir.0, std::fs::Permissions::from_mode(0o500)).unwrap();
        let outcome = rotate_key_halves(&store, &path);
        std::fs::set_permissions(&dir.0, std::fs::Permissions::from_mode(0o700)).unwrap();

        // As root the unlink lands and this branch is unreachable.
        if dir.halves().is_empty() {
            assert_eq!(outcome, Erasure::Gone);
        } else {
            assert_eq!(outcome, Erasure::Neutralized);
            assert_eq!(
                std::fs::metadata(&half_path).unwrap().len(),
                0,
                "the carcass still holds key bytes"
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_half_that_cannot_even_be_zeroed_reports_survival() {
        use std::os::unix::fs::PermissionsExt;
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store, &path).unwrap();
        let half_path = file_half_path(
            &load_key_for(&store, STATE_KEY_ACCOUNT).unwrap(),
            containing_dir(&path).unwrap(),
        )
        .unwrap();

        std::fs::set_permissions(&half_path, std::fs::Permissions::from_mode(0o400)).unwrap();
        std::fs::set_permissions(&dir.0, std::fs::Permissions::from_mode(0o500)).unwrap();
        let outcome = rotate_key_halves(&store, &path);
        std::fs::set_permissions(&dir.0, std::fs::Permissions::from_mode(0o700)).unwrap();
        let _ = std::fs::set_permissions(&half_path, std::fs::Permissions::from_mode(0o600));

        // As root this branch is unreachable.
        if dir.halves().is_empty() {
            assert_eq!(outcome, Erasure::Gone);
        } else {
            assert_eq!(outcome, Erasure::Survived);
            assert_eq!(
                std::fs::metadata(&half_path).unwrap().len(),
                KEY_LEN as u64,
                "survival was reported over a half that was actually destroyed"
            );
        }
    }

    #[test]
    fn a_state_directory_that_is_not_there_counts_as_erased() {
        assert_eq!(
            erase_file_halves(Path::new("/nowhere/at/all")),
            Erasure::Gone
        );
    }

    #[test]
    fn nonces_are_fresh_per_save() {
        let key = key();
        let a = seal(&key, b"same payload");
        let b = seal(&key, b"same payload");
        assert_ne!(a, b, "two saves of the same state must not repeat a nonce");
        assert_eq!(
            a[..STATE_HEADER_LEN],
            b[..STATE_HEADER_LEN],
            "only the nonce and the ciphertext may differ between the two"
        );
    }

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

    #[test]
    fn the_containing_directory_covers_the_bare_filename_case() {
        assert_eq!(containing_dir(Path::new("/a/b")), Some(Path::new("/a")));
        assert_eq!(
            containing_dir(Path::new("state.sealed")),
            Some(Path::new(".")),
            "a bare filename lands in the working directory, so sync that"
        );
        assert_eq!(
            containing_dir(Path::new("a/")),
            Some(Path::new(".")),
            "a trailing slash still leaves the empty parent"
        );
        assert_eq!(
            containing_dir(Path::new("/")),
            None,
            "the root has no directory above it to flush"
        );
    }

    #[cfg(unix)]
    #[test]
    fn an_unsyncable_parent_still_lands_the_write() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch_dir();
        let target = dir.join("state.sealed");
        assert!(write_private(&target, b"first save"));
        // Write and search, no read: the directory itself cannot be opened.
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

    #[test]
    fn a_wrongly_sized_keychain_item_is_refused_not_replaced() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        store.store(STATE_KEY_ACCOUNT, &[0x5A; 16]).unwrap();
        assert!(ensure_state_key(&store, &path).is_none());
        assert!(load_state_key(&store, &path).is_none());
        assert_eq!(&*store.load(STATE_KEY_ACCOUNT).unwrap(), &[0x5A; 16]);
        assert!(dir.halves().is_empty());
    }

    #[test]
    fn a_file_half_of_the_wrong_length_is_refused_on_restore_and_left_alone() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store, &path).unwrap();
        let keychain_half = load_key_for(&store, STATE_KEY_ACCOUNT).unwrap();
        let half_path = file_half_path(&keychain_half, containing_dir(&path).unwrap()).unwrap();
        std::fs::write(&half_path, [0xA5; KEY_LEN / 2]).unwrap();

        assert!(load_state_key(&store, &path).is_none());
        assert_eq!(std::fs::read(&half_path).unwrap(), [0xA5; KEY_LEN / 2]);
        assert_eq!(dir.halves().len(), 1);
    }

    #[test]
    fn a_keychain_that_will_not_answer_yields_no_save_key_and_no_half() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = test_stores::AnswersNothing::default();
        assert!(ensure_state_key(&store, &path).is_none());
        assert!(ensure_ledger_key(&store).is_none());
        assert!(dir.halves().is_empty());
        let behind = store.behind_the_refusal();
        assert!(!behind.exists(STATE_KEY_ACCOUNT).unwrap());
        assert!(!behind.exists(LEDGER_KEY_ACCOUNT).unwrap());
    }

    #[test]
    fn an_unreadable_envelope_costs_no_keychain_access() {
        let mut v1 = seal(&key(), b"staged content");
        v1[..8].copy_from_slice(b"OTSSEAL1");
        assert!(matches!(
            open_state(&v1, || panic!("a refused file cost a keychain access")),
            Opened::Refused
        ));
        assert!(matches!(
            open_state(b"short", || panic!("a refused file cost a keychain access")),
            Opened::Refused
        ));
    }

    #[test]
    fn the_content_drop_is_decided_by_name_then_magic() {
        let dir = scratch_dir();
        let absent_state = dir.join(STATE_FILE_NAME);
        assert!(drop_takes_the_content_key(&absent_state));

        let renamed = dir.join("renamed.sealed");
        std::fs::write(&renamed, seal(&key(), b"staged content")).unwrap();
        assert!(drop_takes_the_content_key(&renamed));

        let superseded = dir.join("old.sealed");
        std::fs::write(&superseded, b"OTSSEAL2 and the rest").unwrap();
        assert!(drop_takes_the_content_key(&superseded));

        let ledger = dir.join("ledger.sealed");
        std::fs::write(&ledger, seal_ledger(&key(), b"one audit record").unwrap()).unwrap();
        assert!(!drop_takes_the_content_key(&ledger));
        assert!(!drop_takes_the_content_key(&dir.join("absent.sealed")));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn hex_round_trips_and_refuses_odd_or_non_hex_input() {
        let bytes = [0x00, 0x0f, 0xa5, 0xff];
        assert_eq!(hex_encode(&bytes), "000fa5ff");
        assert_eq!(hex_decode("000fa5ff").unwrap(), bytes);
        assert_eq!(hex_decode("000FA5FF").unwrap(), bytes);
        assert!(hex_decode("abc").is_none());
        assert!(hex_decode("zz").is_none());
    }
}
