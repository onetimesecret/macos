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
//! key and writes only ciphertext to the path the shell chose. A save
//! runs whenever the store changes, behind the shell's debounce, and
//! once more at quit to flush whatever the debounce still held; the
//! crash-loss window is that interval, not the whole process lifetime
//! (ADR-0012). Restore is the mirror: read, authenticate, decrypt in
//! place, feed the core, and the plaintext wipes on drop.
//!
//! # The state envelope carries its boot session and its two stamps
//!
//! A state file is
//! `magic ‖ boot_uuid[16] ‖ saved_wall_ms[8] ‖ saved_mono_ns[8] ‖
//! nonce[12] ‖ ciphertext ‖ tag`, and the whole 40-byte header is the
//! AEAD's associated data, so not one field of it can be edited without
//! failing authentication.
//!
//! - `boot_uuid` is `kern.bootsessionuuid`, the deterministic backstop
//!   under the crypto-erasure ADR-0012 relies on. A file whose header
//!   names another boot session is never decrypted at all: it is
//!   reported as [`Opened::BootMismatch`], and the caller rotates the
//!   halves and erases the file once the rotation has actually removed
//!   one. On macOS a kernel that refuses the query does **not** fall
//!   back to a fixed value: the session reads as a random sentinel
//!   minted once for this process ([`unreadable_boot_session`]), so
//!   every file any other process sealed reads as a mismatch and is
//!   discarded. A constant there would be a session identity every
//!   process on the machine agrees on, which is the one failure that
//!   hands a page back at its full pre-reboot TTL.
//! - `saved_wall_ms` is the same Unix-epoch stamp the plaintext
//!   snapshot carries, repeated in the clear so restore can reach it
//!   without trusting an unauthenticated field.
//! - `saved_mono_ns` is [`companion_core::clock::sleep_inclusive_ns`] at
//!   the save. Time away is measured from that reading, not from the
//!   calendar, so stepping the system clock backwards buys a page no
//!   extra life. Two readings of that clock are only comparable inside
//!   one boot session, which is exactly and only when a restore can
//!   happen: a file from any other session is discarded before the
//!   stamps are ever read. The comparison is direction-safe as well as
//!   monotonic: a saved stamp that reads *later* than now cannot have
//!   come from this session's clock, so the caller ages the snapshot to
//!   the ceiling rather than to zero. A bent stamp can only ever cost a
//!   page life.
//!
//! [`FILE_MAGIC`] is `OTSSEAL2`. A v1 file has no boot session in it,
//! so it fails the magic check and is refused rather than misparsed.
//! There is no migration: the format broke, the old files are dropped.
//!
//! # The content key is two halves, and neither one unwraps anything
//!
//! The content wrapping key is `HKDF(keychain_half, boot_half)`,
//! derived here and never anywhere else:
//!
//! - The **keychain half** is a random 32 bytes in the OS credential
//!   store under the `state-key` account, scoped by the store's
//!   service. Every account this module touches is read and written
//!   through [`CredentialStore::key_material_store`], which on macOS is
//!   the data protection keychain ADR-0012 asks for: lock gated, this
//!   device only, with the documented fallback to the login keychain on
//!   ad hoc signed builds. The API token is not key material and does
//!   not move; it stays on the store the handle was built with.
//! - The **boot half** is a random 32 bytes that exists only in the per
//!   user temp directory (`_CS_DARWIN_USER_TEMP_DIR`), mode 0600, under
//!   a filename derived from the keychain half **and the current boot
//!   session**. A new session cannot name, let alone read, the previous
//!   session's half: the lookup misses, a fresh half is minted, and the
//!   derived key is unrelated to the one before it. That happens with no
//!   keychain access and needs no leftover file to trigger it, so the
//!   bind is a property of the session rather than of whatever the temp
//!   directory happened to keep. The directory being cleared at boot is
//!   a second line under that, not the mechanism.
//!
//! Neither half alone unwraps content. A same session process running
//! as the user can read the 0600 temp file and still gets nothing
//! without passing the keychain ACL, and an extracted keychain item is
//! useless once its partner is gone. Be exact about when that is: the
//! partner is gone when the temp directory was actually cleared, or when
//! [`rotate_key_halves`] ran. The session-folded filename is a
//! different and weaker guarantee than the bytes being unreachable. What
//! it promises is that the **app** can never re-derive an earlier
//! session's key, because it can no longer name the file that half sits
//! in; a half a stale temp directory kept is still on disk, under a name
//! anyone reading the directory can see. Note the asymmetry precisely:
//! [`rotate_key_halves`] removes the keychain item and **this** session's
//! half, so the extracted-item adversary loses the current session's
//! content, while an earlier session's half stays on disk until the
//! directory is actually cleared.
//! [`rotate_key_halves`] kills both on demand, which is what a boot
//! session mismatch calls for, and reports whether it actually removed
//! anything: a rotation that quietly did nothing must never be mistaken
//! for one that erased.
//!
//! The ledger key is the deliberate exception: a single long-lived
//! keychain secret, never run through this derivation, because an audit
//! record that vanished on every restart would not be an audit record.
//! Rotation must never touch it.
//!
//! Each envelope's magic is its own AEAD associated data, so a ledger
//! file presented as a state file (or the reverse) fails authentication
//! rather than misparsing.
//!
//! A file is useless without its keys, and the keys name nothing
//! without their file: deleting either forgets everything on that side.

// Every property above is a macOS property, and the portable path drops
// all of them at once: it honours a `TMPDIR` the environment can point
// anywhere (the macOS path refuses exactly that), its boot session is a
// constant so the bind is inert, and its monotonic clock restarts at
// reboot so restore ages by nothing. That path exists to keep the crate
// buildable and testable on a Linux CI host and for nothing else, so a
// build that could actually ship off macOS is a compile error rather
// than a documented gap. Shipping artifacts are release builds
// (`scripts/build-core.sh`), which is what `debug_assertions` separates
// here; the unit tests and the ubuntu clippy and test lanes are debug
// and keep compiling.
#[cfg(all(not(target_os = "macos"), not(test), not(debug_assertions)))]
compile_error!(
    "companion-ffi persistence ships on macOS only: the boot-session bind, the boot-cleared \
     per-user temp directory and the sleep-inclusive clock have no portable equivalent. The \
     portable path is for tests and CI checks, never for a release artifact (ADR-0012)."
);

use std::fmt::Write as _;
use std::io::Write;
use std::path::{Path, PathBuf};

use companion_credentials::{CredentialError, CredentialStore};
use ring::aead::{Aad, CHACHA20_POLY1305, LessSafeKey, NONCE_LEN, Nonce, UnboundKey};
use ring::hkdf::{HKDF_SHA256, KeyType, Salt};
use ring::rand::{SecureRandom, SystemRandom};
use zeroize::Zeroizing;

/// Magic + version prefix of the sealed state file. A format change
/// gets a new final byte; the prefix opens the AEAD's associated data,
/// so a relabeled file fails authentication rather than misparsing.
/// `2` is the boot-bound envelope: a `1` file is refused outright.
const FILE_MAGIC: &[u8; 8] = b"OTSSEAL2";

/// Magic + version prefix of the sealed ledger file. Distinct from
/// [`FILE_MAGIC`] on purpose: it is the associated data too, so the two
/// envelopes cannot be swapped even by a caller holding both keys.
const LEDGER_MAGIC: &[u8; 8] = b"OTSLEDG1";

/// The credential-store account holding the **keychain half** of the
/// content key (scoped by the store's service,
/// `com.onetimesecret.companion`). Half a key: see the module doc.
const STATE_KEY_ACCOUNT: &str = "state-key";

/// The credential-store account holding the ledger key.
///
/// This is a SINGLE keychain half and is deliberately not run through
/// the two-half boot-session HKDF the content key gets: its whole
/// purpose is to outlive the boot session. A boot-session mismatch
/// discards staged content and rotates the content halves; the ledger
/// key must survive that untouched, so [`rotate_key_halves`] must never
/// touch `ledger-key`.
const LEDGER_KEY_ACCOUNT: &str = "ledger-key";

/// ChaCha20-Poly1305 key length, and the length of each key half.
const KEY_LEN: usize = 32;

/// Versioned HKDF info string for the content key. A change here
/// derives a different key from the same halves, which discards every
/// existing state file by construction.
const CONTENT_KEY_INFO: &[u8] = b"ots-companion-content-key-v1";

/// Versioned HKDF info string for the boot half's filename tag. A
/// separate info string from [`CONTENT_KEY_INFO`], so the name and the
/// key are independent outputs of the same secret.
const BOOT_HALF_NAME_INFO: &[u8] = b"ots-companion-boot-half-name-v1";

/// Fixed part of the salt for the filename tag. The boot half cannot
/// salt its own name, so this derivation gets a constant prefix; the
/// current boot session UUID is appended to it ([`boot_half_path`]),
/// which is what makes the name unreproducible in any later session. It
/// is a naming tag, not key material.
const BOOT_HALF_NAME_SALT: &[u8] = b"ots-companion-boot-half-name-salt-v1";

/// Bytes of tag in the boot half's filename. Sixteen is more than
/// enough to make a collision between two form factors impossible in
/// practice, and short enough to read in a directory listing.
const BOOT_HALF_TAG_LEN: usize = 16;

/// Filename prefix of the boot half inside the per-user temp directory.
const BOOT_HALF_PREFIX: &str = "ots-companion-boot-";

/// Bytes of boot session identity in the state header. A UUID.
const BOOT_UUID_LEN: usize = 16;

/// The authenticated state header:
/// `magic[8] ‖ boot_uuid[16] ‖ saved_wall_ms[8] ‖ saved_mono_ns[8]`.
/// Fixed length, and every byte of it is associated data.
const STATE_HEADER_LEN: usize = 8 + BOOT_UUID_LEN + 8 + 8;

/// The boot session off macOS, where nothing ships, no boot-cleared
/// temp directory exists to bound anything to, and a fixed value keeps
/// the crate testable on a CI host.
///
/// **Not a fallback on macOS.** A kernel that refuses
/// `kern.bootsessionuuid` gets [`unreadable_boot_session`] instead: a
/// constant would be a session identity every process agrees on, so the
/// boot check would pass across a real restart and hand every page back
/// at its full pre-reboot TTL.
#[cfg(any(not(target_os = "macos"), test))]
const PORTABLE_BOOT_UUID: [u8; BOOT_UUID_LEN] = *b"ots-no-boot-uuid";

/// Bytes of zeros pushed per pass in [`erase_state`].
const ERASE_CHUNK: usize = 4096;

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

/// The content key for saving: `HKDF(keychain_half, boot_half)`, minting
/// either half if it is missing. `None` when a half cannot be obtained,
/// which is a refusal to save rather than a save under a guessed key.
///
/// The keychain half comes from the store's **key material** store
/// ([`CredentialStore::key_material_store`]), not from the store the
/// handle was built with: on macOS that is the data protection keychain
/// ADR-0012 requires. No key byte crosses the seam either way; the
/// accessor hands back a store, never a secret.
pub(crate) fn ensure_state_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    let keys = credentials.key_material_store();
    let keychain_half = ensure_key_for(&*keys, STATE_KEY_ACCOUNT)?;
    let boot_half = ensure_boot_half(&keychain_half)?;
    derive_content_key(&keychain_half, &boot_half)
}

/// The content key for restoring: both halves loaded, neither minted.
/// A missing boot half is the normal state after a reboot and is
/// exactly the case that must fail, so minting one here would only
/// manufacture a key that opens nothing.
pub(crate) fn load_state_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    let keys = credentials.key_material_store();
    let keychain_half = load_key_for(&*keys, STATE_KEY_ACCOUNT)?;
    let boot_half = read_half(&boot_half_path(&keychain_half)?)?;
    derive_content_key(&keychain_half, &boot_half)
}

/// Kill the content key: unlink this session's boot half, then delete
/// the keychain half. Called when a sealed file belongs to another boot
/// session, so the discarded content is discarded for good.
///
/// **Returns whether the content key is gone afterwards**, meaning the
/// keychain half was removed or was never there. A locked keychain, a
/// dismissed ACL or any other refusing backend leaves it alive and
/// returns `false`, and the caller must then leave the file that
/// triggered the rotation exactly where it is: erasing it first would
/// consume the only trigger there is and a rotation that accomplished
/// nothing would never be retried.
///
/// **The keychain half is the sufficient deletion**, and the only one.
/// Every boot half's *content* and its *filename* are both derived from
/// it, so once the item is gone no half on disk, this session's or any
/// earlier session's, can be named or combined into a key again.
/// Unlinking the boot half is ordered first only because naming it needs
/// the keychain half still readable; on its own it forces a fresh
/// derivation this session but says nothing about a file another session
/// sealed, which is precisely the file this arm is discarding. So the
/// return value tracks the keychain item and nothing else.
///
/// The ledger key is **never** touched here. A boot session mismatch
/// discards staged content; the audit record it wrote must survive
/// that, which is the entire reason [`LEDGER_KEY_ACCOUNT`] sits outside
/// this derivation.
pub(crate) fn rotate_key_halves(credentials: &dyn CredentialStore) -> bool {
    let keys = credentials.key_material_store();
    if let Some(keychain_half) = load_key_for(&*keys, STATE_KEY_ACCOUNT)
        && let Some(path) = boot_half_path(&keychain_half)
    {
        let _ = std::fs::remove_file(path);
    }
    // A backend that errors on delete, or one that reports the item
    // still present afterwards, has not rotated anything. An `exists`
    // that will not answer is treated the same way: unknown is not gone.
    keys.delete(STATE_KEY_ACCOUNT).is_ok() && !keys.exists(STATE_KEY_ACCOUNT).unwrap_or(true)
}

/// `HKDF-SHA256`: salt from the boot half, extract the keychain half,
/// expand under a versioned info string into a 32-byte AEAD key. Both
/// inputs are required and neither is recoverable from the output.
fn derive_content_key(keychain_half: &[u8], boot_half: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    // The pseudorandom key is bound to a name because `Okm` borrows it.
    let prk = Salt::new(HKDF_SHA256, boot_half).extract(keychain_half);
    let okm = prk.expand(&[CONTENT_KEY_INFO], Bytes(KEY_LEN)).ok()?;
    let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
    okm.fill(&mut key).ok()?;
    Some(key)
}

/// An HKDF output length. `ring` asks for a [`KeyType`] rather than a
/// number so the length is fixed before expansion; this is the plain
/// "give me n bytes" case.
#[derive(Clone, Copy)]
struct Bytes(usize);

impl KeyType for Bytes {
    fn len(&self) -> usize {
        self.0
    }
}

/// The boot half's file, named by a one-way tag over the keychain half
/// **and the current boot session**.
///
/// Folding the session UUID into the salt is what makes the boot bind
/// unconditional. Without it the bind depends on a state file surviving
/// to be found at launch: a session that staged pages, discarded them
/// all and so erased its own file leaves both halves alive, and a next
/// boot whose temp directory was not cleared would find the same half
/// under the same name and derive a byte-identical content key, with
/// unlinked ciphertext generations still on disk. With it there is
/// nothing to trigger and nothing to miss: a new session looks under a
/// name no earlier session ever wrote, finds nothing, and mints a half
/// whose derived key shares nothing with the old one.
///
/// Deriving the name from the keychain half as well is what keeps two
/// form factors out of each other's boot half: each form factor's
/// credential store is scoped to its own service, so each holds a
/// different keychain half and therefore lands on a different filename.
/// The tag is an HKDF output under its own info string, so the name
/// discloses nothing about either input.
fn boot_half_path(keychain_half: &[u8]) -> Option<PathBuf> {
    let mut salt = Vec::with_capacity(BOOT_HALF_NAME_SALT.len() + BOOT_UUID_LEN);
    salt.extend_from_slice(BOOT_HALF_NAME_SALT);
    salt.extend_from_slice(&current_boot_uuid());
    let prk = Salt::new(HKDF_SHA256, &salt).extract(keychain_half);
    let okm = prk
        .expand(&[BOOT_HALF_NAME_INFO], Bytes(BOOT_HALF_TAG_LEN))
        .ok()?;
    let mut tag = [0u8; BOOT_HALF_TAG_LEN];
    okm.fill(&mut tag).ok()?;
    let mut name = String::with_capacity(BOOT_HALF_PREFIX.len() + BOOT_HALF_TAG_LEN * 2);
    name.push_str(BOOT_HALF_PREFIX);
    for byte in tag {
        write!(name, "{byte:02x}").ok()?;
    }
    Some(boot_half_dir()?.join(name))
}

/// The boot half itself: the existing file, or a fresh 32 bytes written
/// through [`write_private`] so it inherits the atomic, owner-only path.
///
/// Two instances of the same form factor starting at once can both find
/// the file missing and both mint; the rename decides, exactly as it
/// does for the state file, and the loser's next save simply seals under
/// a key its own restore will refuse. That costs a state file, never a
/// misread one.
fn ensure_boot_half(keychain_half: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let path = boot_half_path(keychain_half)?;
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

/// A stored half, wiped on drop. A file of the wrong length is treated
/// as absent: half a half derives nothing.
fn read_half(path: &Path) -> Option<Zeroizing<Vec<u8>>> {
    let bytes = Zeroizing::new(std::fs::read(path).ok()?);
    (bytes.len() == KEY_LEN).then_some(bytes)
}

/// The directory the boot half lives in, and the whole reason the boot
/// half dies at reboot.
#[cfg(not(test))]
fn boot_half_dir() -> Option<PathBuf> {
    platform_temp_dir()
}

/// Under test the same directory, except that a test never writes key
/// material into the live per-user temp directory: an explicit override
/// if one is set, otherwise a per-process subdirectory. Tests over the
/// C seam mint halves too, and those halves must not sit beside the
/// running app's.
#[cfg(test)]
fn boot_half_dir() -> Option<PathBuf> {
    if let Some(dir) = boot_half_dir_override::get() {
        return Some(dir);
    }
    let dir = platform_temp_dir()?.join(format!("companion-ffi-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

/// `_CS_DARWIN_USER_TEMP_DIR`: the per-user, mode 0700 temp directory
/// that macOS clears at boot. Deliberately not `TMPDIR`, which the
/// environment can point anywhere, and not the shared `/tmp`.
#[cfg(target_os = "macos")]
fn platform_temp_dir() -> Option<PathBuf> {
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt;

    let mut buffer = vec![0u8; libc::PATH_MAX as usize];
    // SAFETY: `buffer` is a live allocation of exactly the length passed,
    // and confstr writes at most that many bytes including the NUL.
    let written = unsafe {
        libc::confstr(
            libc::_CS_DARWIN_USER_TEMP_DIR,
            buffer.as_mut_ptr().cast::<libc::c_char>(),
            buffer.len(),
        )
    };
    // Zero means the name is not defined; a length past the buffer means
    // the value was truncated. Neither is a path worth writing a key to.
    if written == 0 || written > buffer.len() {
        return None;
    }
    buffer.truncate(written - 1);
    Some(PathBuf::from(OsString::from_vec(buffer)))
}

/// Off macOS there is no `_CS_DARWIN_USER_TEMP_DIR`, so the crate stays
/// portable and testable on the ordinary temp directory. The boot bound
/// is a macOS property; nothing off macOS ships.
#[cfg(not(target_os = "macos"))]
fn platform_temp_dir() -> Option<PathBuf> {
    Some(std::env::temp_dir())
}

/// A per-thread redirect for [`boot_half_dir`], so a test can mint and
/// rotate real halves without writing into the live per-user temp
/// directory. Test-only: the shipping path has no override at all.
#[cfg(test)]
mod boot_half_dir_override {
    use std::cell::RefCell;
    use std::path::PathBuf;

    thread_local! {
        static DIR: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    }

    pub(super) fn get() -> Option<PathBuf> {
        DIR.with(|dir| dir.borrow().clone())
    }

    pub(super) fn set(path: PathBuf) {
        DIR.with(|dir| *dir.borrow_mut() = Some(path));
    }

    pub(super) fn clear() {
        DIR.with(|dir| *dir.borrow_mut() = None);
    }
}

/// The ledger key for saving. Long-lived by design: see
/// [`LEDGER_KEY_ACCOUNT`]. Key material, so it rests in the same data
/// protection store as the content key's keychain half.
pub(crate) fn ensure_ledger_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    ensure_key_for(&*credentials.key_material_store(), LEDGER_KEY_ACCOUNT)
}

/// The ledger key for restoring. Load only, never mint.
pub(crate) fn load_ledger_key(credentials: &dyn CredentialStore) -> Option<Zeroizing<Vec<u8>>> {
    load_key_for(&*credentials.key_material_store(), LEDGER_KEY_ACCOUNT)
}

/// Seal a plaintext snapshot into `nonce ‖ ciphertext ‖ tag`, nonce
/// fresh per save, with `aad` authenticated alongside it but not
/// carried here: the caller prefixes those bytes itself.
///
/// The work buffer holds a copy of the whole staged-content snapshot in
/// the clear until the AEAD overwrites it, so it is [`Zeroizing`] and
/// sized exactly: the encryption is fallible and can unwind, and a
/// plain `Vec` would be freed still holding that plaintext on either
/// path. The exact capacity matters for the same reason. A growth would
/// copy the plaintext into a new allocation and strand the old one
/// unwiped.
fn seal_body(key: &[u8], aad: &[u8], plaintext: &[u8]) -> Option<Vec<u8>> {
    let key = aead_key(key)?;
    let mut nonce_bytes = [0u8; NONCE_LEN];
    SystemRandom::new().fill(&mut nonce_bytes).ok()?;
    let mut sealed = work_buffer(plaintext);
    key.seal_in_place_append_tag(
        Nonce::assume_unique_for_key(nonce_bytes),
        Aad::from(aad),
        // The `Vec` behind the wipe: `Extend` is what the AEAD appends
        // the tag through, and the wrapper does not carry it.
        &mut *sealed,
    )
    .ok()?;
    let mut body = Vec::with_capacity(NONCE_LEN + sealed.len());
    body.extend_from_slice(&nonce_bytes);
    body.extend_from_slice(&sealed);
    Some(body)
}

/// The buffer [`seal_body`] encrypts in: a copy of the plaintext,
/// wiped on drop, with room for the tag reserved up front so the AEAD
/// appending it cannot grow the allocation. Growth would copy the
/// plaintext into a new allocation and leave the old one freed and
/// unwiped, which is the whole thing being avoided here.
fn work_buffer(plaintext: &[u8]) -> Zeroizing<Vec<u8>> {
    let mut buffer = Zeroizing::new(Vec::with_capacity(
        plaintext.len() + CHACHA20_POLY1305.tag_len(),
    ));
    buffer.extend_from_slice(plaintext);
    buffer
}

/// Open `nonce ‖ ciphertext ‖ tag` back into its plaintext snapshot,
/// authenticated against `aad`. The returned buffer wipes on drop;
/// `None` for anything that was not sealed under this key with these
/// associated bytes, bit for bit.
fn open_body(key: &[u8], aad: &[u8], body: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let key = aead_key(key)?;
    if body.len() < NONCE_LEN {
        return None;
    }
    let (nonce_bytes, ciphertext) = body.split_at(NONCE_LEN);
    let nonce = Nonce::try_assume_unique_for_key(nonce_bytes).ok()?;
    // Decrypt in place inside a zeroizing buffer: the plaintext lands at
    // the front; truncate to its length and let the wipe cover the rest.
    let mut buffer = Zeroizing::new(ciphertext.to_vec());
    let plaintext_len = key
        .open_in_place(nonce, Aad::from(aad), &mut buffer)
        .ok()?
        .len();
    buffer.truncate(plaintext_len);
    Some(buffer)
}

/// The authenticated head of a state file: which boot session sealed
/// it, and the two stamps that say when.
struct StateHeader {
    /// `kern.bootsessionuuid` as it read at the save.
    boot: [u8; BOOT_UUID_LEN],
    /// Unix epoch milliseconds at the save, the same stamp the
    /// plaintext snapshot carries inside itself.
    wall_ms: u64,
    /// [`companion_core::clock::sleep_inclusive_ns`] at the save. Time
    /// away is measured from this, never from the calendar.
    mono_ns: u64,
}

impl StateHeader {
    /// The header as it appears on disk, which is also the exact byte
    /// string the AEAD authenticates.
    fn to_bytes(&self) -> [u8; STATE_HEADER_LEN] {
        let mut out = [0u8; STATE_HEADER_LEN];
        out[..8].copy_from_slice(FILE_MAGIC.as_slice());
        out[8..8 + BOOT_UUID_LEN].copy_from_slice(&self.boot);
        out[24..32].copy_from_slice(&self.wall_ms.to_be_bytes());
        out[32..40].copy_from_slice(&self.mono_ns.to_be_bytes());
        out
    }

    /// Read a header off the front of a file. `None` for a file that is
    /// too short or does not carry this magic, which covers every v1
    /// file: they have no boot session in them, so there is nothing to
    /// check and nothing to salvage.
    fn parse(file: &[u8]) -> Option<Self> {
        let head = file.get(..STATE_HEADER_LEN)?;
        if !head.starts_with(FILE_MAGIC.as_slice()) {
            return None;
        }
        Some(Self {
            boot: head[8..8 + BOOT_UUID_LEN].try_into().ok()?,
            wall_ms: u64::from_be_bytes(head[24..32].try_into().ok()?),
            mono_ns: u64::from_be_bytes(head[32..40].try_into().ok()?),
        })
    }
}

/// What a state file turned out to be.
pub(crate) enum Opened {
    /// This boot session's file, authenticated and decrypted, with the
    /// stamps its header carried.
    Plaintext {
        /// The snapshot the core reads back, wiped on drop.
        plaintext: Zeroizing<Vec<u8>>,
        /// Unix epoch milliseconds at the save.
        saved_wall_ms: u64,
        /// Sleep-inclusive monotonic nanoseconds at the save.
        saved_mono_ns: u64,
    },
    /// A file some other boot session sealed. Its content key died with
    /// that session; the caller erases the file and rotates the halves.
    BootMismatch,
    /// Not a state file this build reads, or not one this key opens.
    Refused,
}

/// Seal a content snapshot under the state envelope, stamped with this
/// boot session and the two clock readings at the save.
pub(crate) fn seal_state(
    key: &[u8],
    plaintext: &[u8],
    wall_ms: u64,
    mono_ns: u64,
) -> Option<Vec<u8>> {
    let header = StateHeader {
        boot: current_boot_uuid(),
        wall_ms,
        mono_ns,
    }
    .to_bytes();
    let body = seal_body(key, &header, plaintext)?;
    let mut file = Vec::with_capacity(header.len() + body.len());
    file.extend_from_slice(&header);
    file.extend_from_slice(&body);
    Some(file)
}

/// Open a content snapshot from the state envelope.
///
/// The boot session is checked before `key` is ever called, so a file
/// from a dead session costs no keychain access and is never decrypted:
/// there is nothing to learn from content this app has already decided
/// to discard. `key` is a closure for exactly that reason.
///
/// A hostile edit to the header reads as a mismatch rather than as
/// tampering, which at worst provokes the erase-and-rotate the caller
/// would perform anyway. Anyone able to rewrite the header could have
/// deleted the file instead, so this trades nothing away.
pub(crate) fn open_state(file: &[u8], key: impl FnOnce() -> Option<Zeroizing<Vec<u8>>>) -> Opened {
    let Some(header) = StateHeader::parse(file) else {
        return Opened::Refused;
    };
    if header.boot != current_boot_uuid() {
        return Opened::BootMismatch;
    }
    let Some(key) = key() else {
        return Opened::Refused;
    };
    let Some(plaintext) = open_body(&key, &file[..STATE_HEADER_LEN], &file[STATE_HEADER_LEN..])
    else {
        return Opened::Refused;
    };
    Opened::Plaintext {
        plaintext,
        saved_wall_ms: header.wall_ms,
        saved_mono_ns: header.mono_ns,
    }
}

/// Seal a ledger snapshot under the ledger envelope.
///
/// Deliberately *not* boot-bound: no session id, no stamps, nothing
/// that a reboot invalidates. The audit record is long-lived by design,
/// and the boot binding belongs to the content envelope alone.
pub(crate) fn seal_ledger(key: &[u8], plaintext: &[u8]) -> Option<Vec<u8>> {
    let body = seal_body(key, LEDGER_MAGIC, plaintext)?;
    let mut file = Vec::with_capacity(LEDGER_MAGIC.len() + body.len());
    file.extend_from_slice(LEDGER_MAGIC);
    file.extend_from_slice(&body);
    Some(file)
}

/// Open a ledger snapshot from the ledger envelope. Two-way: a ledger
/// either authenticates under its own long-lived key or it does not,
/// with no boot session in the question.
pub(crate) fn open_ledger(key: &[u8], file: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let body = file.strip_prefix(LEDGER_MAGIC.as_slice())?;
    open_body(key, LEDGER_MAGIC, body)
}

/// Drop a state file: overwrite its length with zeros, truncate, sync,
/// unlink. Returns whether the path is **confirmed** empty, decided
/// without following a symlink. A stat that will not answer counts as
/// not empty, because the caller settles the sudden-termination hold on
/// this and an unknown must not read as success.
///
/// This doc comment is the canonical statement of the erase contract.
/// `companion_persist_erase` in lib.rs, its block in `companion_ffi.h`,
/// and `persistErase` in CompanionClient.swift all point here rather
/// than restating it: the contract was previously written out in four
/// places and only two of them were kept accurate.
///
/// **This is not erasure and must never be described as erasure.** APFS
/// is copy on write, so the zeros are as likely to land in fresh blocks
/// as over the old ones, and every prior generation the atomic rename
/// unlinked is out of reach here entirely. Crypto-erasure is the real
/// mechanism: the file is unreadable once the keychain half is gone,
/// which is why the caller pairs this with [`rotate_key_halves`]. The
/// overwrite is a cheap, best-effort courtesy on top of that, not a
/// guarantee anyone should rely on.
///
/// **This path is never handed a name it authenticated.** The shell
/// fires it on demand (`companion_persist_erase`, the erase-on-empty
/// path) with a path this module has no way to check, so another process
/// running as the same user, the exact adversary the 0600 boot half and
/// the keychain ACL exist to stop, could otherwise plant something at
/// that name and turn this into an arbitrary-file zero-and-truncate
/// primitive. Three narrow checks stand in the way, all of them before a
/// single byte moves: the open refuses to follow a **final** symlink,
/// the open refuses to block, so a FIFO planted at the name fails
/// `ENXIO` rather than parking this call and the handle mutex with it,
/// and the writes refuse anything that is not a regular file.
///
/// **Those checks are narrower than they sound, and are not the
/// containment.** A hard link at the path presents a genuine regular
/// file: it passes every check here and is zeroed and truncated like the
/// state file it impersonates. A symlinked parent directory is never
/// examined, because only the final component is. And the link and
/// blocking refusals are conditional on the platform carrying those open
/// flags ([`O_NOFOLLOW`], [`O_NONBLOCK`]), which here means macOS, the
/// one target that ships, and the Linux test host. What actually
/// contains this is that the path lives in an owner-only, app-owned
/// state directory; the checks only limit what a foothold there is
/// worth.
///
/// The unlink at the end does not follow either, so a planted link is
/// removed rather than dereferenced, and the final check reads the link
/// itself: a dangling symlink still sitting at the path is something
/// left there, not success.
pub(crate) fn erase_state(path: &Path) -> bool {
    if let Ok(mut file) = open_for_erase(path)
        && let Ok(metadata) = file.metadata()
        && metadata.file_type().is_file()
    {
        let zeros = [0u8; ERASE_CHUNK];
        let mut remaining = metadata.len();
        while remaining > 0 {
            let chunk = usize::try_from(remaining)
                .unwrap_or(ERASE_CHUNK)
                .min(ERASE_CHUNK);
            if file.write_all(&zeros[..chunk]).is_err() {
                break;
            }
            remaining = remaining.saturating_sub(chunk as u64);
        }
        let _ = file.set_len(0);
        let _ = file.sync_all();
    }
    let _ = std::fs::remove_file(path);
    // Only a confirmed absence counts. `is_err()` would fold "the path
    // is gone" together with "the stat could not be answered", and the
    // caller settles the sudden-termination hold on this answer, so a
    // permissions failure would report success over ciphertext still on
    // disk. Same standard as `rotate_key_halves`: an unknown is a no.
    matches!(std::fs::symlink_metadata(path), Err(e) if e.kind() == std::io::ErrorKind::NotFound)
}

/// Open `path` for writing without following a final symlink and
/// without ever blocking on the open itself.
///
/// `O_NOFOLLOW` is the only version of the link check that is not a
/// race: stat-then-open leaves a window in which the name can be swapped
/// for a link. See [`erase_state`] for why that window matters here.
///
/// `O_NONBLOCK` covers what `O_NOFOLLOW` does not. A FIFO is not a
/// symlink, so the link check lets it through, and an `O_WRONLY` open of
/// a FIFO with no reader parks until a reader arrives, which for this
/// caller means forever with the handle mutex held. With this flag that
/// open fails `ENXIO` and returns. On a regular file the flag is inert:
/// it does not affect the write, the truncate or the sync that follow.
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

/// `O_NOFOLLOW` on the one target that ships. Spelled through `libc`
/// because that is where the value belongs.
#[cfg(target_os = "macos")]
const O_NOFOLLOW: i32 = libc::O_NOFOLLOW;

/// `O_NOFOLLOW` on the Linux test host, which this crate does not take
/// `libc` on. The value is ABI, fixed by the kernel's `fcntl.h`; the
/// symlink test below fails loudly if it ever stops being the flag.
#[cfg(target_os = "linux")]
const O_NOFOLLOW: i32 = 0x0002_0000;

/// `O_NONBLOCK` on the one target that ships.
#[cfg(target_os = "macos")]
const O_NONBLOCK: i32 = libc::O_NONBLOCK;

/// `O_NONBLOCK` on the Linux test host, the same ABI constant story as
/// [`O_NOFOLLOW`] above (`04000` in the kernel's `fcntl.h`); the FIFO
/// test below fails loudly if it ever stops being the flag.
#[cfg(target_os = "linux")]
const O_NONBLOCK: i32 = 0x0000_0800;

/// This boot session, as the envelope stamps and checks it.
#[cfg(not(test))]
fn current_boot_uuid() -> [u8; BOOT_UUID_LEN] {
    boot_session_uuid()
}

/// Under test the same reading, unless a test has pinned one: that is
/// how a reboot is simulated without one.
#[cfg(test)]
fn current_boot_uuid() -> [u8; BOOT_UUID_LEN] {
    boot_uuid_override::get().unwrap_or_else(boot_session_uuid)
}

/// `kern.bootsessionuuid`: opaque, and stable for the whole boot
/// session.
///
/// Deliberately not `kern.boottime`, which the kernel re-derives
/// whenever the calendar clock steps (NTP, a manual change, a timezone
/// tool). Reading boot time would discard staged content in the middle
/// of a session for no reason at all; the session UUID only changes
/// when the machine actually restarts.
#[cfg(target_os = "macos")]
fn boot_session_uuid() -> [u8; BOOT_UUID_LEN] {
    // A 36-character UUID string and its NUL; the buffer is generous.
    let mut buffer = [0u8; 64];
    let mut len = buffer.len();
    // SAFETY: `buffer` is a live allocation of exactly the length in
    // `len`, which sysctlbyname reads and then overwrites with the
    // number of bytes it wrote; the name is a NUL-terminated literal and
    // the new-value pointer is null, so this is a pure read.
    let rc = unsafe {
        libc::sysctlbyname(
            c"kern.bootsessionuuid".as_ptr(),
            buffer.as_mut_ptr().cast::<libc::c_void>(),
            &raw mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 || len == 0 || len > buffer.len() {
        return unreadable_boot_session();
    }
    parse_uuid(&buffer[..len]).unwrap_or_else(unreadable_boot_session)
}

/// The boot session when the kernel will not name one: 16 random bytes
/// minted once for this process and never written anywhere.
///
/// This is the fail-closed direction, and it is not interchangeable with
/// a constant. A sandbox or a kernel that consistently refuses
/// `kern.bootsessionuuid` would, with a constant, make every process on
/// the machine agree on one session identity: the boot check would pass
/// across an actual restart, the previous boot's file would decrypt, and
/// the aging math would measure zero time away and hand every page back
/// at its full pre-reboot TTL. Extending an item's life past its TTL is
/// the one outcome that must be impossible.
///
/// With a per-process sentinel the check reports a mismatch instead, so
/// the file is erased and the halves rotated. Within one process the
/// value is stable, which costs nothing: a save and a restore in the
/// same process are the same session by definition.
#[cfg(target_os = "macos")]
fn unreadable_boot_session() -> [u8; BOOT_UUID_LEN] {
    static SENTINEL: std::sync::OnceLock<[u8; BOOT_UUID_LEN]> = std::sync::OnceLock::new();
    *SENTINEL.get_or_init(|| {
        let mut bytes = [0u8; BOOT_UUID_LEN];
        if SystemRandom::new().fill(&mut bytes).is_err() {
            // An RNG that refuses must still not collapse onto a value
            // another process can reproduce. The pid and the moment this
            // ran are not secret, and they do not need to be: all this
            // value has to do is differ between processes.
            bytes[..8].copy_from_slice(&u64::from(std::process::id()).to_be_bytes());
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .ok()
                .and_then(|since| u64::try_from(since.as_nanos()).ok())
                .unwrap_or(u64::MAX);
            bytes[8..].copy_from_slice(&stamp.to_be_bytes());
        }
        bytes
    })
}

/// Off macOS there is no boot session to read, and nothing off macOS
/// ships (the assertion at the top of this module makes that a build
/// error rather than a promise): a fixed value keeps the envelope's
/// shape identical so the tests cover the same code the app runs.
#[cfg(not(target_os = "macos"))]
fn boot_session_uuid() -> [u8; BOOT_UUID_LEN] {
    PORTABLE_BOOT_UUID
}

/// The 16 bytes behind a `8-4-4-4-12` UUID string, NUL-terminated or
/// not. `None` unless exactly 32 hex digits are present, so a truncated
/// or reshaped answer is never padded into a plausible-looking session.
fn parse_uuid(bytes: &[u8]) -> Option<[u8; BOOT_UUID_LEN]> {
    let mut nibbles = bytes
        .iter()
        .copied()
        .take_while(|byte| *byte != 0)
        .filter(|byte| *byte != b'-')
        .map(hex_value);
    let mut out = [0u8; BOOT_UUID_LEN];
    for byte in &mut out {
        let high = nibbles.next()??;
        let low = nibbles.next()??;
        *byte = (high << 4) | low;
    }
    nibbles.next().is_none().then_some(out)
}

/// One hexadecimal digit's value, either case.
fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// A per-thread redirect for [`current_boot_uuid`], so a test can stage
/// a reboot without one. Test-only: the shipping path reads the kernel
/// and nothing else.
#[cfg(test)]
pub(crate) mod boot_uuid_override {
    use std::cell::RefCell;

    thread_local! {
        static UUID: RefCell<Option<[u8; super::BOOT_UUID_LEN]>> = const { RefCell::new(None) };
    }

    pub(crate) fn get() -> Option<[u8; super::BOOT_UUID_LEN]> {
        UUID.with(|uuid| *uuid.borrow())
    }

    pub(crate) fn set(value: [u8; super::BOOT_UUID_LEN]) {
        UUID.with(|uuid| *uuid.borrow_mut() = Some(value));
    }

    pub(crate) fn clear() {
        UUID.with(|uuid| *uuid.borrow_mut() = None);
    }
}

/// Credential stores that behave in ways the in-memory one cannot, so
/// the tests can see behaviour the shipping backends have and it does
/// not. Test-only, and shared with the seam's tests in `lib.rs`, which
/// exercise the same cases one layer up.
#[cfg(test)]
pub(crate) mod test_stores {
    use std::sync::Arc;

    use companion_credentials::{CredentialError, CredentialStore, InMemoryCredentialStore};
    use zeroize::Zeroizing;

    /// An ordinary in-memory store with `delete` wired to fail: a
    /// keychain still locked at launch, an ACL confirmation the user
    /// dismissed, a backend that simply errored. That is the case where
    /// a rotation accomplishes nothing, and the case the caller must not
    /// mistake for a rotation that erased.
    #[derive(Clone, Default)]
    pub(crate) struct RefusesToDelete {
        /// Shared so [`CredentialStore::key_material_store`] can hand
        /// back a second handle onto the same map, exactly as the
        /// in-memory store it wraps does.
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

    /// A store whose key material store is a **different** store, the
    /// way the login keychain and the data protection keychain are
    /// different keychains on a signed macOS build. The in-memory store
    /// shares one map for both, which is right for a dev host and
    /// useless for proving where an item landed; here the two maps are
    /// disjoint, so every write is attributable.
    #[derive(Clone, Default)]
    pub(crate) struct SplitKeyStore {
        handed: Arc<InMemoryCredentialStore>,
        keys: Arc<InMemoryCredentialStore>,
    }

    impl SplitKeyStore {
        /// The store the handle itself holds: where the API token
        /// belongs and where no key material may appear.
        pub(crate) fn handed(&self) -> &InMemoryCredentialStore {
            &self.handed
        }

        /// The key material store, standing in for the data protection
        /// keychain.
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

    /// An envelope key for the tests that only care that sealing and
    /// opening are sound. Where the key came from is the derivation
    /// tests' business, and going through the credential store here
    /// would litter the real temp directory with boot halves.
    fn key() -> Zeroizing<Vec<u8>> {
        let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
        SystemRandom::new().fill(&mut key).unwrap();
        key
    }

    /// Seal a state file with the stamps a test does not care about.
    fn seal(key: &[u8], plaintext: &[u8]) -> Vec<u8> {
        seal_state(key, plaintext, 1_700_000_000_000, 42).unwrap()
    }

    /// The plaintext of an [`Opened::Plaintext`], or `None` for either
    /// of the other two answers.
    fn plaintext_of(opened: Opened) -> Option<Zeroizing<Vec<u8>>> {
        match opened {
            Opened::Plaintext { plaintext, .. } => Some(plaintext),
            Opened::BootMismatch | Opened::Refused => None,
        }
    }

    /// Open a state file under a key that is always available.
    fn open(key: &Zeroizing<Vec<u8>>, file: &[u8]) -> Opened {
        open_state(file, || Some(key.clone()))
    }

    /// A boot session other than this one, in force for the current
    /// test thread and released when the test ends.
    struct RebootedInto;

    impl RebootedInto {
        fn new(uuid: [u8; BOOT_UUID_LEN]) -> Self {
            boot_uuid_override::set(uuid);
            Self
        }
    }

    impl Drop for RebootedInto {
        fn drop(&mut self) {
            boot_uuid_override::clear();
        }
    }

    /// A scratch boot-half directory, in force for the current test
    /// thread and removed when the test ends. Every test that mints,
    /// loads or rotates a real half takes one first.
    struct BootHalfScratch(std::path::PathBuf);

    impl BootHalfScratch {
        fn new() -> Self {
            let dir = scratch_dir();
            boot_half_dir_override::set(dir.clone());
            Self(dir)
        }

        /// The halves currently on disk, by filename.
        fn files(&self) -> Vec<std::ffi::OsString> {
            let mut names: Vec<_> = std::fs::read_dir(&self.0)
                .unwrap()
                .map(|entry| entry.unwrap().file_name())
                .collect();
            names.sort();
            names
        }
    }

    impl Drop for BootHalfScratch {
        fn drop(&mut self) {
            boot_half_dir_override::clear();
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn seal_and_open_round_trip() {
        let key = key();
        let sealed = seal_state(&key, b"the whole store, serialized", 1_234, 5_678).unwrap();
        let Opened::Plaintext {
            plaintext,
            saved_wall_ms,
            saved_mono_ns,
        } = open(&key, &sealed)
        else {
            panic!("a file this session sealed did not open");
        };
        assert_eq!(&*plaintext, b"the whole store, serialized");
        assert_eq!(saved_wall_ms, 1_234, "the wall stamp came back changed");
        assert_eq!(
            saved_mono_ns, 5_678,
            "the monotonic stamp came back changed"
        );
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

    /// Every key account this module touches lives in the key material
    /// store, which on a signed macOS build is the data protection
    /// keychain: lock gated, this device only (ADR-0012). Reads, writes
    /// and the rotation's delete must all agree on that, or a save mints
    /// in one keychain while a restore looks in the other, or worse, a
    /// rotation deletes nothing and the old half survives.
    #[test]
    fn key_material_lives_in_the_key_store_and_rotation_deletes_it_there() {
        let _scratch = BootHalfScratch::new();
        let store = test_stores::SplitKeyStore::default();

        let state = ensure_state_key(&store).unwrap();
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

        // Restore reads where the save wrote.
        assert_eq!(&*load_state_key(&store).unwrap(), &*state);
        assert_eq!(&*load_ledger_key(&store).unwrap(), &*ledger);

        // And rotation deletes where the item actually is.
        assert!(rotate_key_halves(&store));
        assert!(
            !store.keys().exists(STATE_KEY_ACCOUNT).unwrap(),
            "rotation deleted nothing: the old keychain half survived"
        );
        assert!(
            store.keys().exists(LEDGER_KEY_ACCOUNT).unwrap(),
            "rotation took the long-lived ledger key with it"
        );
    }

    /// The ledger rests under its own long-lived credential, so a
    /// content key that is rotated or discarded leaves the audit record
    /// readable, and a store that has only ever saved content cannot
    /// pretend to hold a ledger key.
    #[test]
    fn the_ledger_key_is_a_separate_credential() {
        let _scratch = BootHalfScratch::new();
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

    /// The envelope that ships is `OTSSEAL2`. A file from the previous
    /// format carries no boot session at all, so there is nothing to
    /// check it against: it fails the magic and is refused outright,
    /// never parsed as though its first bytes meant something.
    #[test]
    fn a_v1_file_is_refused() {
        let key = key();
        let mut v1 = seal(&key, b"staged content from the old format");
        v1[..8].copy_from_slice(b"OTSSEAL1");
        assert!(
            matches!(open(&key, &v1), Opened::Refused),
            "a v1 file must be refused, not read as a boot mismatch"
        );
        // And nothing shorter than a header is a state file either.
        assert!(matches!(open(&key, b"OTSSEAL2"), Opened::Refused));
        assert!(matches!(open(&key, b""), Opened::Refused));
    }

    /// Every field of the header is associated data, so an edit to any
    /// of it fails: the boot session as a mismatch (the caller's cue to
    /// erase and rotate), the stamps as an authentication failure. A
    /// stamp that could be edited would be a free extension of any
    /// page's life.
    #[test]
    fn header_fields_are_authenticated() {
        let key = key();
        let sealed = seal_state(&key, b"payload", 1_700_000_000_000, 9_000_000_000).unwrap();

        for index in 8..8 + BOOT_UUID_LEN {
            let mut bent = sealed.clone();
            bent[index] ^= 0x01;
            assert!(
                matches!(open(&key, &bent), Opened::BootMismatch),
                "an edited boot session at {index} did not read as another session"
            );
        }
        for index in 24..STATE_HEADER_LEN {
            let mut bent = sealed.clone();
            bent[index] ^= 0x01;
            assert!(
                matches!(open(&key, &bent), Opened::Refused),
                "an edited stamp at {index} still opened"
            );
        }
    }

    /// The deterministic backstop. A file sealed in one boot session is
    /// never decrypted in another, whatever the keys say, and the key
    /// is not even asked for: there is nothing to learn from content
    /// this app has already decided to discard.
    #[test]
    fn a_file_from_another_boot_session_is_refused() {
        let key = key();
        let sealed = seal(&key, b"staged content from the last boot");
        assert!(plaintext_of(open(&key, &sealed)).is_some(), "same session");

        let _rebooted = RebootedInto::new([0x5A; BOOT_UUID_LEN]);
        assert!(matches!(
            open_state(&sealed, || panic!("the key was loaded for a dead session")),
            Opened::BootMismatch
        ));
    }

    /// The ledger is long-lived on purpose: same simulated reboot, and
    /// the audit record still opens. If this ever fails, the ledger has
    /// picked up the content file's lifetime and stopped being a ledger.
    #[test]
    fn the_ledger_envelope_is_not_boot_bound() {
        let key = key();
        let record = seal_ledger(&key, b"created 0001, sent link").unwrap();
        let _rebooted = RebootedInto::new([0x11; BOOT_UUID_LEN]);
        assert_eq!(
            &*open_ledger(&key, &record).unwrap(),
            b"created 0001, sent link"
        );
        assert!(
            !record.starts_with(FILE_MAGIC.as_slice()),
            "the ledger must not carry the state envelope's magic"
        );
    }

    /// Best effort, and never called erasure: what it must do is leave
    /// nothing at the path, including when there was nothing there to
    /// begin with (an expiry that empties an already-empty store).
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

    /// The erase path never authenticates the path it is handed, so a
    /// symlink planted at the state path by another process running as
    /// the same user must be a dead end. Before this was true, that was
    /// an arbitrary-file zero-and-truncate primitive available on demand
    /// through `companion_persist_erase`.
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

        // A dangling link is not "nothing left at the path" either: the
        // reachability check must read the link, not what it points at.
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

    /// `O_NOFOLLOW` has no effect on a FIFO, and an `O_WRONLY` open of a
    /// FIFO with no reader blocks until a reader arrives. The same-user
    /// process the erase path already assumes is out there can plant one
    /// at the state path, and without `O_NONBLOCK` the next erase parks
    /// inside the open with the handle mutex held: the app freezes for
    /// good, and the regular-file check never even runs because the open
    /// never returns. Hardening against the symlink turned the open
    /// itself into the target.
    ///
    /// The call runs on its own thread against a deadline, so a
    /// regression fails this test instead of hanging the suite forever.
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

    /// `O_NONBLOCK` is what keeps that FIFO from parking the erase, and
    /// it must cost the ordinary path nothing: on a regular file the flag
    /// does not reach the write, the truncate or the sync. Asserted here
    /// rather than assumed, because the erase itself truncates away the
    /// zeros it wrote and so cannot show whether they landed.
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

    /// The AEAD works over a copy of the whole staged-content snapshot.
    /// That copy wipes on drop (the type is the assertion) and is sized
    /// so appending the tag cannot reallocate it, since the buffer left
    /// behind by a growth is freed with the plaintext still in it.
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

    /// A kernel that will not name the boot session must not collapse
    /// onto a value every process agrees on. That would make the boot
    /// check pass across a real restart, decrypt the previous boot's
    /// file and, with zero time away, restore every page at its full
    /// pre-reboot TTL.
    #[cfg(target_os = "macos")]
    #[test]
    fn an_unreadable_boot_session_fails_closed() {
        let sentinel = unreadable_boot_session();
        assert_ne!(
            sentinel, PORTABLE_BOOT_UUID,
            "the refusal fell back to a value every process shares"
        );
        assert_ne!(sentinel, [0u8; BOOT_UUID_LEN]);
        assert_ne!(
            sentinel,
            boot_session_uuid(),
            "the sentinel collided with the real session"
        );
        assert_eq!(
            sentinel,
            unreadable_boot_session(),
            "the sentinel must be stable inside one process"
        );
    }

    /// The kernel hands back a `8-4-4-4-12` string; anything else is not
    /// a session identity and must not be padded into one.
    #[test]
    fn a_boot_session_string_parses_only_when_it_is_whole() {
        assert_eq!(
            parse_uuid(b"1B2C3D4E-5F60-7182-93A4-B5C6D7E8F901\0").unwrap(),
            [
                0x1B, 0x2C, 0x3D, 0x4E, 0x5F, 0x60, 0x71, 0x82, 0x93, 0xA4, 0xB5, 0xC6, 0xD7, 0xE8,
                0xF9, 0x01
            ]
        );
        assert_eq!(
            parse_uuid(b"1b2c3d4e-5f60-7182-93a4-b5c6d7e8f901").unwrap(),
            parse_uuid(b"1B2C3D4E-5F60-7182-93A4-B5C6D7E8F901").unwrap(),
            "case is not identity"
        );
        assert!(parse_uuid(b"1B2C3D4E-5F60-7182-93A4-B5C6D7E8F9").is_none());
        assert!(parse_uuid(b"1B2C3D4E-5F60-7182-93A4-B5C6D7E8F90123").is_none());
        assert!(parse_uuid(b"not-a-uuid-at-all").is_none());
        assert!(parse_uuid(b"").is_none());
    }

    /// On macOS the kernel must actually answer, or the boot bound is
    /// inert and every restart quietly keeps its content.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_boot_session_reads_from_the_kernel() {
        let uuid = boot_session_uuid();
        assert_ne!(
            uuid, PORTABLE_BOOT_UUID,
            "kern.bootsessionuuid did not answer"
        );
        assert_ne!(uuid, [0u8; BOOT_UUID_LEN]);
        assert_eq!(uuid, boot_session_uuid(), "the session is not stable");
    }

    #[test]
    fn ensure_is_stable_and_load_never_mints() {
        let scratch = BootHalfScratch::new();
        let store = InMemoryCredentialStore::default();
        assert!(
            load_state_key(&store).is_none(),
            "restore must not mint a key for a file it cannot decrypt anyway"
        );
        assert!(
            scratch.files().is_empty(),
            "a restore that found no keychain half still wrote a boot half"
        );
        let first = ensure_state_key(&store).unwrap();
        let second = ensure_state_key(&store).unwrap();
        assert_eq!(&*first, &*second, "the key survives across saves");
        assert_eq!(&*load_state_key(&store).unwrap(), &*first);
        assert_eq!(scratch.files().len(), 1, "one store, one boot half");
    }

    /// The derivation is over both halves, so replacing either one
    /// yields a different key. This is the property the whole
    /// boot-session bound rests on: the temp directory clearing at boot
    /// is what makes the derived key unrecoverable.
    #[test]
    fn changing_either_half_changes_the_derived_key() {
        let scratch = BootHalfScratch::new();
        let store = InMemoryCredentialStore::default();
        let original = ensure_state_key(&store).unwrap();

        // A new boot session: the temp directory is empty, the keychain
        // half is untouched, and the derived key is different.
        let keychain_half = load_key_for(&store, STATE_KEY_ACCOUNT).unwrap();
        std::fs::remove_file(boot_half_path(&keychain_half).unwrap()).unwrap();
        let after_reboot = ensure_state_key(&store).unwrap();
        assert_ne!(
            &*original, &*after_reboot,
            "a fresh boot half derived the same key"
        );
        assert_eq!(
            &*load_key_for(&store, STATE_KEY_ACCOUNT).unwrap(),
            &*keychain_half,
            "a fresh boot half must not disturb the keychain half"
        );

        // A different keychain half over the same directory: different
        // key again, and a boot half of its own.
        let other = InMemoryCredentialStore::default();
        let stranger = ensure_state_key(&other).unwrap();
        assert_ne!(&*after_reboot, &*stranger);
        assert_eq!(
            scratch.files().len(),
            2,
            "two credential stores must not share a boot half"
        );

        // And the derivation itself is a pure function of the two.
        let boot_half = read_half(&boot_half_path(&keychain_half).unwrap()).unwrap();
        assert_eq!(
            &*derive_content_key(&keychain_half, &boot_half).unwrap(),
            &*after_reboot
        );
        assert_ne!(
            &*derive_content_key(&boot_half, &keychain_half).unwrap(),
            &*after_reboot,
            "the halves are not interchangeable"
        );
    }

    /// Restore loads both halves and mints neither. A boot half that is
    /// gone is the ordinary post-reboot state, and the only correct
    /// answer is to refuse.
    #[test]
    fn a_missing_boot_half_is_never_minted_on_restore() {
        let scratch = BootHalfScratch::new();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store).unwrap();
        let keychain_half = load_key_for(&store, STATE_KEY_ACCOUNT).unwrap();
        std::fs::remove_file(boot_half_path(&keychain_half).unwrap()).unwrap();

        assert!(load_state_key(&store).is_none(), "restore minted a half");
        assert!(scratch.files().is_empty(), "restore wrote a boot half");
    }

    #[cfg(unix)]
    #[test]
    fn the_boot_half_is_owner_only_and_a_full_key_length() {
        use std::os::unix::fs::PermissionsExt;
        let _scratch = BootHalfScratch::new();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store).unwrap();
        let path = boot_half_path(&load_key_for(&store, STATE_KEY_ACCOUNT).unwrap()).unwrap();
        let metadata = std::fs::metadata(&path).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(metadata.len(), KEY_LEN as u64);
        assert!(
            path.file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with(BOOT_HALF_PREFIX)
        );
    }

    /// The boot bind is a property of the session, not of a file that
    /// happened to survive to be found. Nothing is deleted here, nothing
    /// is rotated, and no state file exists at all: only the session
    /// changes, and that alone must change the derived key. The path
    /// this closes is a session that staged pages, discarded them all
    /// (which erases the file, the only thing that can trigger a
    /// rotation) and rebooted into a temp directory that was not
    /// cleared.
    #[test]
    fn a_new_boot_session_derives_a_new_key_with_no_file_and_no_rotation() {
        let scratch = BootHalfScratch::new();
        let store = InMemoryCredentialStore::default();

        let first = {
            let _booted = RebootedInto::new([0xA1; BOOT_UUID_LEN]);
            ensure_state_key(&store).unwrap()
        };
        let keychain_half = load_key_for(&store, STATE_KEY_ACCOUNT).unwrap();

        let second = {
            let _rebooted = RebootedInto::new([0xB2; BOOT_UUID_LEN]);
            ensure_state_key(&store).unwrap()
        };
        assert_ne!(
            &*first, &*second,
            "a new boot session derived the previous session's content key"
        );
        assert_eq!(
            &*load_key_for(&store, STATE_KEY_ACCOUNT).unwrap(),
            &*keychain_half,
            "the keychain half must be untouched: the bind is not a rotation"
        );
        assert_eq!(
            scratch.files().len(),
            2,
            "the second session reused the first session's boot half"
        );

        // The old half is still on disk (an uncleared temp directory)
        // and is still unreachable from the new session: a restore in
        // that session finds nothing to load.
        {
            let _rebooted = RebootedInto::new([0xC3; BOOT_UUID_LEN]);
            assert!(
                load_state_key(&store).is_none(),
                "a third session found a half it never wrote"
            );
        }

        // And returning to a session does return its own key, which is
        // what makes a save and a restore inside one session work at all.
        let again = {
            let _booted = RebootedInto::new([0xA1; BOOT_UUID_LEN]);
            load_state_key(&store).unwrap()
        };
        assert_eq!(&*first, &*again, "the same session derived a different key");
    }

    /// Rotation kills both halves, so every file sealed under the old
    /// derivation is unopenable afterwards, and the next save derives a
    /// key that shares nothing with it.
    #[test]
    fn rotate_key_halves_makes_a_sealed_file_unopenable() {
        let scratch = BootHalfScratch::new();
        let store = InMemoryCredentialStore::default();
        let key = ensure_state_key(&store).unwrap();
        let sealed = seal(&key, b"staged content from another boot");

        assert!(
            rotate_key_halves(&store),
            "a rotation that removed both halves reported failure"
        );
        assert!(
            scratch.files().is_empty(),
            "the boot half survived rotation"
        );
        assert!(
            load_key_for(&store, STATE_KEY_ACCOUNT).is_none(),
            "the keychain half survived rotation"
        );
        assert!(
            load_state_key(&store).is_none(),
            "a rotated store still produced a content key"
        );

        let fresh = ensure_state_key(&store).unwrap();
        assert_ne!(&*fresh, &*key);
        assert!(
            plaintext_of(open(&fresh, &sealed)).is_none(),
            "the pre-rotation file opened under the post-rotation key"
        );
    }

    /// The ledger outlives the boot session on purpose, so the rotation
    /// a boot-session mismatch triggers must leave its key exactly where
    /// it was. If this ever fails, every audit record on disk is lost on
    /// the first reboot.
    #[test]
    fn rotation_leaves_the_ledger_key_intact() {
        let _scratch = BootHalfScratch::new();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store).unwrap();
        let ledger = ensure_ledger_key(&store).unwrap();
        let record = seal_ledger(&ledger, b"created 0001, sent clipboard").unwrap();

        assert!(rotate_key_halves(&store));

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

    /// Rotation is idempotent and survives a store that has nothing to
    /// rotate: it runs on the load path, where "already gone" is a
    /// perfectly ordinary state. Nothing left to remove is the erased
    /// state, so it reports success and the caller may drop the file.
    #[test]
    fn rotating_an_empty_store_is_not_an_error() {
        let scratch = BootHalfScratch::new();
        let store = InMemoryCredentialStore::default();
        assert!(rotate_key_halves(&store));
        assert!(rotate_key_halves(&store));
        assert!(scratch.files().is_empty());
        assert!(load_state_key(&store).is_none());
    }

    /// A rotation the backend refused must say so. A locked keychain at
    /// launch leaves the keychain half alive, which leaves every state
    /// file it can open readable: reporting success there would let the
    /// caller consume the only trigger that would ever retry it.
    #[test]
    fn a_rotation_the_keychain_refused_reports_failure() {
        let scratch = BootHalfScratch::new();
        let store = test_stores::RefusesToDelete::default();
        ensure_state_key(&store).unwrap();
        let keychain_half = load_key_for(&store, STATE_KEY_ACCOUNT).unwrap();

        assert!(
            !rotate_key_halves(&store),
            "a rotation that deleted nothing reported success"
        );
        assert!(
            scratch.files().is_empty(),
            "the boot half survived a rotation that could still reach it"
        );
        // The surviving keychain half is the whole problem, and the
        // reason the caller must keep the file that triggered this.
        assert_eq!(
            &*load_key_for(&store, STATE_KEY_ACCOUNT).unwrap(),
            &*keychain_half,
            "the refusing store lost the item it refused to delete"
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
