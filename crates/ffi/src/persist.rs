//! The sealed files: encryption on every mutation, decryption at
//! launch.
//!
//! There are two of them, with two keys and two envelope magics, and
//! the split is the point (ADR-0012).
//!
//! - **The state file** holds staged content: sheets, sealed chips,
//!   clocks. It rests under `state-key` and survives every ordinary
//!   process and machine lifecycle event: what ends it is its TTL, an
//!   emptied pad, or an explicit Clear (ADR-0016).
//! - **The ledger file** holds metadata plus the capped, page-owned
//!   title, never content. It rests under `ledger-key`, a single
//!   long-lived keychain half that no rotation touches: an audit
//!   record that vanished with the content it describes would not be an
//!   audit record.
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
//! # The state envelope carries one stamp
//!
//! A state file is
//! `magic ‖ sealed_wall_ms[8] ‖ nonce[12] ‖ ciphertext ‖ tag`, and the
//! whole 16-byte header is the AEAD's associated data, so neither field
//! of it can be edited without failing authentication.
//!
//! `sealed_wall_ms` is the Unix-epoch stamp at the save, the same one
//! the plaintext snapshot carries inside itself. It measures one
//! interval and only one: the gap between the last save and the next
//! restore, which is the span no process of this app was running to
//! observe (ADR-0016 section 4). Every interval a running process does
//! observe stays on the sleep-inclusive monotonic clock, which is not
//! settable, so a clock step mid-session buys nothing. Across a restart
//! the calendar is the only witness there is, and the gap is charged
//! with `saturating_sub`, so a backward step reads as zero rather than
//! as a credit: it can freeze a countdown, never rewind one. That
//! freeze is accepted rather than defended, because a user who can set
//! the machine's clock already has the plaintext on screen.
//!
//! Being inside the associated data makes the stamp unforgeable and
//! leaves it replayable, since a stamp cannot detect the rollback of the
//! file that carries it; ADR-0016 section 8 prices that and accepts it.
//!
//! [`FILE_MAGIC`] is `OTSSEAL3`. [`SUPERSEDED_MAGICS`] holds the
//! versions this build has replaced and can therefore dispose of rather
//! than refuse; anything else, `OTSSEAL1` included, is refused outright
//! and left where it lies. There is no migration and none is possible:
//! the associated data changed, so the old bytes cannot authenticate
//! even in a session that still holds their key.
//!
//! # The content key is two halves, and neither one unwraps anything
//!
//! The content wrapping key is `HKDF(keychain_half, file_half)`,
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
//! - The **file half** is a random 32 bytes at mode 0600 in the state
//!   directory, beside the sealed file it keys, under a filename
//!   derived from the keychain half. It used to live in the per-user
//!   temp directory under a name that folded the boot session, which is
//!   what made the content die at every restart; ADR-0016 moved it here
//!   so that staged content survives a restart and its TTL is what ends
//!   it. In its new home it inherits the state directory's `.noindex`
//!   naming and its exclusion from Time Machine.
//!
//! Deriving the name from the keychain half is what keeps two form
//! factors out of each other's half: each form factor's credential
//! store is scoped to its own service, so each holds a different
//! keychain half and lands on a different filename.
//!
//! Neither half alone unwraps content, and **both halves are now
//! durable across boot sessions, so the split bounds nothing in time.**
//! ADR-0012 could say an extracted keychain item was useless once its
//! per-boot partner was gone; that sentence is retired rather than
//! quietly reworded (ADR-0016 section 3). What the split still buys is
//! two things and exactly two. The ACL gate: a process running as the
//! user that reads the 0600 file half derives nothing without also
//! passing the keychain. And separation of backup domains: the state
//! directory is excluded from Time Machine and the keychain database is
//! not, so neither a backup nor a copy of the state directory yields a
//! key on its own.
//!
//! [`rotate_key_halves`] is what forgets. It removes the keychain half,
//! which is the sufficient deletion because the file half's name and
//! its use are both derived from it, and it unlinks the file half on the
//! way past. It reports whether it actually removed anything: a rotation
//! that quietly did nothing must never be mistaken for one that erased.
//! Because rotation is no longer a scheduled event, it is the finishing
//! step of a deletion the user or the TTL already asked for, which is
//! the two triggers of ADR-0016 section 6.
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

// Every property above is a macOS property, and the portable path keeps
// none of them: the keychain half rests in the data protection keychain
// only there, `sync_all` is `F_FULLFSYNC` only there, and the state
// directory's owner-only, Spotlight-excluded, Time-Machine-excluded
// shape is the shell's doing on that one platform. This path exists to
// keep the crate buildable and testable on a Linux CI host and for
// nothing else, so a build that could actually ship off macOS is a
// compile error rather than a documented gap. Shipping artifacts are
// release builds (`scripts/build-core.sh`), which is what
// `debug_assertions` separates here; the unit tests and the ubuntu
// clippy and test lanes are debug and keep compiling.
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

/// Magic + version prefix of the sealed state file. A format change
/// gets a new final byte; the prefix opens the AEAD's associated data,
/// so a relabeled file fails authentication rather than misparsing.
/// `3` is the durable envelope of ADR-0016: no boot session, no
/// monotonic stamp, one wall stamp.
const FILE_MAGIC: &[u8; 8] = b"OTSSEAL3";

/// The envelope versions this build has replaced. A file carrying one
/// of these is disposed of and the save licence granted, rather than
/// refused forever ([`Opened::Superseded`], ADR-0016 section 9), and the
/// list grows by one entry per format break.
///
/// Membership is a promise about *this app's own* past output, so it is
/// spelled out rather than computed from the version byte. `OTSSEAL1`
/// stays out of it: it was refused outright before this break and it is
/// refused outright after it.
const SUPERSEDED_MAGICS: [&[u8; 8]; 1] = [b"OTSSEAL2"];

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
/// the two-half HKDF the content key gets: its whole purpose is to
/// outlive the content it describes. Emptying the pad discards staged
/// content and rotates the content halves; the ledger key must survive
/// that untouched, so [`rotate_key_halves`] must never touch
/// `ledger-key`.
const LEDGER_KEY_ACCOUNT: &str = "ledger-key";

/// ChaCha20-Poly1305 key length, and the length of each key half.
const KEY_LEN: usize = 32;

/// Versioned HKDF info string for the content key. A change here
/// derives a different key from the same halves, which discards every
/// existing state file by construction.
const CONTENT_KEY_INFO: &[u8] = b"ots-companion-content-key-v1";

/// Versioned HKDF info string for the file half's filename tag. A
/// separate info string from [`CONTENT_KEY_INFO`], so the name and the
/// key are independent outputs of the same secret.
///
/// The bytes still spell "boot" and deliberately keep spelling it. What
/// ADR-0016 changed is where the half lives and what salts its name, not
/// this derivation, and rotating the string would move every form
/// factor's filename for no reason at all.
const FILE_HALF_NAME_INFO: &[u8] = b"ots-companion-boot-half-name-v1";

/// The salt for the filename tag. The file half cannot salt its own
/// name, so this derivation gets a constant. The current boot session
/// UUID used to be appended to it, which is what made the name
/// unreproducible in any later session; ADR-0016 section 3 takes that
/// appendix off and leaves the constant itself untouched. It is a naming
/// tag, not key material.
const FILE_HALF_NAME_SALT: &[u8] = b"ots-companion-boot-half-name-salt-v1";

/// Bytes of tag in the file half's filename. Sixteen is more than
/// enough to make a collision between two form factors impossible in
/// practice, and short enough to read in a directory listing.
const FILE_HALF_TAG_LEN: usize = 16;

/// Filename prefix of the file half inside the state directory. It
/// names what the file is now rather than when it dies, since nothing
/// about it is per-boot any more.
const FILE_HALF_PREFIX: &str = "ots-companion-key-half-";

/// The authenticated state header: `magic[8] ‖ sealed_wall_ms[8]`.
/// Fixed length, and every byte of it is associated data.
pub(crate) const STATE_HEADER_LEN: usize = 8 + 8;

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
        Ok(key) => {
            diag_fault!(
                "companion-ffi: the {account} item holds {} bytes, not {KEY_LEN}; refusing it.",
                key.len()
            );
            None
        }
        // Absence is ordinary on this path (a first run, a rotation that
        // already happened); a backend that refuses is not, and it is
        // the difference between a fresh start and a session that cannot
        // read what it wrote an hour ago.
        Err(CredentialError::NotFound) => None,
        Err(error) => {
            diag_fault!("companion-ffi: the {account} item would not load ({error}).");
            None
        }
    }
}

/// The content key for saving: `HKDF(keychain_half, file_half)`, minting
/// either half if it is missing. `None` when a half cannot be obtained,
/// which is a refusal to save rather than a save under a guessed key.
///
/// The keychain half comes from the store's **key material** store
/// ([`CredentialStore::key_material_store`]), not from the store the
/// handle was built with: on macOS that is the data protection keychain
/// ADR-0012 requires. No key byte crosses the seam either way; the
/// accessor hands back a store, never a secret.
///
/// `state_path` is the sealed file being keyed; the file half is minted
/// and read in the directory that holds it, which is how the state
/// directory the shell chose reaches this module at all.
pub(crate) fn ensure_state_key(
    credentials: &dyn CredentialStore,
    state_path: &Path,
) -> Option<Zeroizing<Vec<u8>>> {
    let keys = credentials.key_material_store();
    let keychain_half = ensure_key_for(&*keys, STATE_KEY_ACCOUNT)?;
    let file_half = ensure_file_half(&keychain_half, containing_dir(state_path)?)?;
    derive_content_key(&keychain_half, &file_half)
}

/// The content key for restoring: both halves loaded, neither minted.
/// A missing file half means the key that sealed the file is gone for
/// good, which is exactly the case that must fail: minting one here
/// would only manufacture a key that opens nothing.
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

/// Kill the content key: unlink the file half beside `state_path`, then
/// delete the keychain half. Called when the content that key protects
/// is being discarded, so it is discarded for good.
///
/// **Returns whether the content key is gone afterwards**, meaning the
/// keychain half was removed or was never there. A locked keychain, a
/// dismissed ACL or any other refusing backend leaves it alive and
/// returns `false`, so a caller whose next step destroys the only
/// evidence that a rotation is owed can decline to take it.
///
/// **The keychain half is the sufficient deletion**, and the only one.
/// Every file half's *content* and its *filename* are both derived from
/// it, so once the item is gone no half on disk can be named or combined
/// into a key again. Unlinking the file half is ordered first only
/// because naming it needs the keychain half still readable. So the
/// return value tracks the keychain item and nothing else.
///
/// The ledger key is **never** touched here. Discarding staged content
/// must leave the audit record that describes it readable, which is the
/// entire reason [`LEDGER_KEY_ACCOUNT`] sits outside this derivation.
pub(crate) fn rotate_key_halves(credentials: &dyn CredentialStore, state_path: &Path) -> bool {
    let keys = credentials.key_material_store();
    if let Some(keychain_half) = load_key_for(&*keys, STATE_KEY_ACCOUNT)
        && let Some(dir) = containing_dir(state_path)
        && let Some(path) = file_half_path(&keychain_half, dir)
    {
        let _ = std::fs::remove_file(path);
    }
    // A backend that errors on delete, or one that reports the item
    // still present afterwards, has not rotated anything. An `exists`
    // that will not answer is treated the same way: unknown is not gone.
    //
    // Both refusals are announced, because both are otherwise invisible
    // and both are permanent: a rotation that reports failure leaves the
    // state file in place, and a state file that will not open is what
    // withholds the save licence for the session. Silent, that reads in
    // the interface as an app that has simply stopped remembering
    // anything, on every launch, with nothing anywhere naming a cause.
    // The message carries a backend string, never key material.
    if let Err(error) = keys.delete(STATE_KEY_ACCOUNT) {
        diag_fault!(
            "companion-ffi: the rotation could not delete the {STATE_KEY_ACCOUNT} item ({error}). \
             The half that opens every ciphertext generation on disk is therefore still in the \
             keychain, so the content this rotation was meant to forget is still readable by \
             anyone holding both halves. Every later rotation repeats this until the keychain \
             answers."
        );
        return false;
    }
    match keys.exists(STATE_KEY_ACCOUNT) {
        Ok(false) => true,
        Ok(true) => {
            diag_fault!(
                "companion-ffi: the {STATE_KEY_ACCOUNT} item is still present after a delete the \
                 keychain accepted; treating the rotation as refused."
            );
            false
        }
        Err(error) => {
            diag_fault!(
                "companion-ffi: the {STATE_KEY_ACCOUNT} item was deleted but the keychain will \
                 not say whether it is gone ({error}); unknown is not gone, so the rotation \
                 counts as refused."
            );
            false
        }
    }
}

/// `HKDF-SHA256`: salt from the file half, extract the keychain half,
/// expand under a versioned info string into a 32-byte AEAD key. Both
/// inputs are required and neither is recoverable from the output.
fn derive_content_key(keychain_half: &[u8], file_half: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    // The pseudorandom key is bound to a name because `Okm` borrows it.
    let prk = Salt::new(HKDF_SHA256, file_half).extract(keychain_half);
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

/// The file half's path in `dir`, named by a one-way tag over the
/// keychain half.
///
/// Deriving the name from the keychain half is what keeps two form
/// factors out of each other's half: each form factor's credential store
/// is scoped to its own service, so each holds a different keychain half
/// and therefore lands on a different filename. It is also what makes
/// deleting the keychain item a sufficient deletion, since a half whose
/// name cannot be recomputed can never be combined into a key again. The
/// tag is an HKDF output under its own info string, so the name
/// discloses nothing about either input.
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

/// The file half itself: the existing file, or a fresh 32 bytes written
/// through [`write_private`] so it inherits the atomic, owner-only path.
///
/// Two instances of the same form factor starting at once can both find
/// the file missing and both mint; the rename decides, exactly as it
/// does for the state file, and the loser's next save simply seals under
/// a key its own restore will refuse. That costs a state file, never a
/// misread one.
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

/// A stored half, wiped on drop. A file of the wrong length is treated
/// as absent: half a half derives nothing.
fn read_half(path: &Path) -> Option<Zeroizing<Vec<u8>>> {
    let bytes = Zeroizing::new(std::fs::read(path).ok()?);
    (bytes.len() == KEY_LEN).then_some(bytes)
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

/// The authenticated head of a state file: the one stamp that says
/// when it was sealed.
struct StateHeader {
    /// Unix epoch milliseconds at the save, the same stamp the
    /// plaintext snapshot carries inside itself.
    sealed_wall_ms: u64,
}

impl StateHeader {
    /// The header as it appears on disk, which is also the exact byte
    /// string the AEAD authenticates.
    fn to_bytes(&self) -> [u8; STATE_HEADER_LEN] {
        let mut out = [0u8; STATE_HEADER_LEN];
        out[..8].copy_from_slice(FILE_MAGIC.as_slice());
        out[8..16].copy_from_slice(&self.sealed_wall_ms.to_be_bytes());
        out
    }

    /// Read a header off the front of a file. `None` for a file that is
    /// too short or does not carry this magic, which covers every
    /// earlier envelope: their fields sit at different offsets and mean
    /// different things, so there is nothing to parse and nothing to
    /// salvage.
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
    /// A file this app wrote under an envelope it has since replaced.
    /// Nothing in it can be read, so the caller disposes of it and lets
    /// the session write: an install that refused this file forever
    /// would present as one that had permanently stopped saving
    /// (ADR-0016 section 9).
    Superseded,
    /// Not a state file this build reads, or not one this key opens.
    /// The caller leaves it exactly where it is.
    Refused,
}

/// Seal a content snapshot under the state envelope, stamped with the
/// wall clock at the save.
pub(crate) fn seal_state(key: &[u8], plaintext: &[u8], sealed_wall_ms: u64) -> Option<Vec<u8>> {
    let header = StateHeader { sealed_wall_ms }.to_bytes();
    let body = seal_body(key, &header, plaintext)?;
    let mut file = Vec::with_capacity(header.len() + body.len());
    file.extend_from_slice(&header);
    file.extend_from_slice(&body);
    Some(file)
}

/// Open a content snapshot from the state envelope.
///
/// The magic is read before `key` is ever called, so a file this build
/// cannot read at all costs no keychain access. `key` is a closure for
/// exactly that reason, and on macOS a keychain access is a prompt the
/// user may have to answer (ADR-0004), which is not a thing to spend on
/// a file that is about to be refused.
///
/// **Only the magic decides disposal, and only a magic this app itself
/// once wrote.** A header edit fails authentication and is refused, so
/// nothing an outsider can write to the file turns into a deletion; the
/// destructive answer is reserved for the two byte strings this app has
/// shipped and replaced.
pub(crate) fn open_state(file: &[u8], key: impl FnOnce() -> Option<Zeroizing<Vec<u8>>>) -> Opened {
    // Each refusal names itself. They are different failures with one
    // visible symptom (a session that will not write), and telling them
    // apart from the outside means reading ciphertext.
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

/// The superseded envelope `file` carries, as a name for the
/// diagnostic, or `None` for anything else. Every entry of
/// [`SUPERSEDED_MAGICS`] is an ASCII literal in this file, so naming it
/// discloses nothing and cannot fail.
fn superseded_magic(file: &[u8]) -> Option<&'static str> {
    SUPERSEDED_MAGICS
        .iter()
        .find(|magic| file.starts_with(magic.as_slice()))
        .and_then(|magic| std::str::from_utf8(magic.as_slice()).ok())
}

/// Seal a ledger snapshot under the ledger envelope.
///
/// Deliberately stamped with nothing at all: the audit record does not
/// age, is not drained, and has no gap to measure, so the one field the
/// content envelope carries would mean nothing here.
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
/// running as the same user, the exact adversary the 0600 file half and
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

/// Erase every stranded temp generation in `dir`, which is work for
/// launch and only launch.
///
/// [`write_private`] writes to `<path>.<16 hex>.tmp` and renames. A
/// death between the two, a power loss above all, leaves that temp file
/// behind holding a complete sealed generation of staged content or, now
/// that the file half is written through the same function into the same
/// directory, a complete copy of a key half. Nothing swept them: the
/// state directory, unlike the per-user temp directory this material
/// used to sit in, is never cleared by anything (ADR-0016 section 8).
///
/// The shape is matched exactly rather than by the `.tmp` suffix alone,
/// because [`erase_state`] zeroes and truncates what it is given and
/// this is the one caller that chooses its own paths. A stranded temp is
/// erased with the same discipline as the file it was going to become,
/// since that is what it holds.
///
/// A save in flight from a second instance of the same form factor owns
/// a path of this shape too, and a sweep can reach it between its write
/// and its rename. That costs that instance its save, which its own
/// return value reports, and it cannot corrupt anything: the rename
/// either lands whole or fails.
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

/// Whether `name` has the exact shape [`write_private`] gives a temp
/// file: some name, a dot, sixteen hex digits, `.tmp`.
fn is_write_private_temp(name: &str) -> bool {
    let Some(rest) = name.strip_suffix(".tmp") else {
        return false;
    };
    let Some((stem, tag)) = rest.rsplit_once('.') else {
        return false;
    };
    !stem.is_empty() && tag.len() == 16 && tag.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Whether the file at `path` is this app's **content** envelope, this
/// build's or one it has replaced.
///
/// The question is answered by reading the magic rather than by looking
/// at the name, because a name is the shell's to choose and this module
/// has no list of them. It exists because one entry point drops files
/// for two different reasons: the state file when the pad empties, and
/// the ledger file when the user clears the ledger
/// (`PageModel.clearLedger`). Only the first of those may take the
/// content key with it, and a ledger clear that rotated the content
/// halves would destroy every staged page the user still had.
///
/// A file that is absent, unreadable, shorter than a magic, or sealed
/// under any other envelope answers `false`, which costs a rotation that
/// would have been sound rather than performing one that would not be.
/// The open carries the same refusals [`open_for_erase`] does, for the
/// same reason: this runs against a path anyone running as the user
/// could have replaced.
pub(crate) fn holds_content_envelope(path: &Path) -> bool {
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
    if let Some(parent) = containing_dir(path) {
        let _ = sync_dir(parent);
    }
}

/// The directory that holds `path`'s entry: the one whose flush makes a
/// rename durable, and the one the file half is minted in. A path with
/// no directory component has parent `Some("")` rather than `None`, and
/// its entry lands in the working directory, so that case resolves to
/// `.` instead of skipping the sync. Only a root path has nothing above
/// it, and a key half has nowhere to live beside it.
fn containing_dir(path: &Path) -> Option<&Path> {
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
    /// would litter a scratch directory with key halves.
    fn key() -> Zeroizing<Vec<u8>> {
        let mut key = Zeroizing::new(vec![0u8; KEY_LEN]);
        SystemRandom::new().fill(&mut key).unwrap();
        key
    }

    /// Seal a state file with a stamp a test does not care about.
    fn seal(key: &[u8], plaintext: &[u8]) -> Vec<u8> {
        seal_state(key, plaintext, 1_700_000_000_000).unwrap()
    }

    /// The plaintext of an [`Opened::Plaintext`], or `None` for either
    /// of the other two answers.
    fn plaintext_of(opened: Opened) -> Option<Zeroizing<Vec<u8>>> {
        match opened {
            Opened::Plaintext { plaintext, .. } => Some(plaintext),
            Opened::Superseded | Opened::Refused => None,
        }
    }

    /// Open a state file under a key that is always available.
    fn open(key: &Zeroizing<Vec<u8>>, file: &[u8]) -> Opened {
        open_state(file, || Some(key.clone()))
    }

    /// A scratch state directory standing in for the app support
    /// directory the shell chooses: the sealed file's home, and since
    /// ADR-0016 the file half's home too. Removed when the test ends, so
    /// no test ever mints key material beside the running app's.
    struct StateDir(std::path::PathBuf);

    impl StateDir {
        fn new() -> Self {
            Self(scratch_dir())
        }

        /// The path the sealed state file would take, which is also the
        /// path every key call is scoped by.
        fn state_path(&self) -> std::path::PathBuf {
            self.0.join("state.sealed")
        }

        /// The key halves currently on disk, by filename.
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

        // Restore reads where the save wrote.
        assert_eq!(&*load_state_key(&store, &state_path).unwrap(), &*state);
        assert_eq!(&*load_ledger_key(&store).unwrap(), &*ledger);

        // And rotation deletes where the item actually is.
        assert!(rotate_key_halves(&store, &state_path));
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

    /// `OTSSEAL1` was refused outright before this break and stays
    /// refused: it is not in the superseded set, so it is left on disk
    /// rather than disposed of, and it is never parsed as though its
    /// first bytes meant something.
    #[test]
    fn a_v1_file_is_refused() {
        let key = key();
        let mut v1 = seal(&key, b"staged content from the oldest format");
        v1[..8].copy_from_slice(b"OTSSEAL1");
        assert!(
            matches!(open(&key, &v1), Opened::Refused),
            "a v1 file must be refused, not disposed of"
        );
        // And nothing shorter than a header is a state file either.
        assert!(matches!(open(&key, b"OTSSEAL3"), Opened::Refused));
        assert!(matches!(open(&key, b""), Opened::Refused));
        // Nor is a magic this app has never written, however close to
        // one it has.
        let mut stranger = seal(&key, b"staged content from nowhere");
        stranger[..8].copy_from_slice(b"OTSSEAL9");
        assert!(matches!(open(&key, &stranger), Opened::Refused));
    }

    /// The one superseded envelope is disposed of rather than refused,
    /// and the key is never asked for on the way: its bytes cannot be
    /// authenticated under any key this build can assemble, so a
    /// keychain access there would be a prompt spent on nothing
    /// (ADR-0016 section 9, ADR-0004).
    #[test]
    fn a_superseded_file_is_disposed_of_rather_than_refused() {
        let key = key();
        let mut v2 = seal(&key, b"staged content from the boot-bound format");
        v2[..8].copy_from_slice(b"OTSSEAL2");
        assert!(matches!(
            open_state(&v2, || panic!("a superseded file cost a keychain access")),
            Opened::Superseded
        ));
        // Truncated to nothing but the magic, it is still recognisably
        // this app's own past output.
        assert!(matches!(
            open_state(b"OTSSEAL2", || None),
            Opened::Superseded
        ));
    }

    /// Both fields of the header are associated data, so no edit to
    /// either one opens. The stamp matters most: one that could be
    /// edited would be a free extension of any page's life.
    ///
    /// The version digit is the one byte where an edit is destructive
    /// rather than merely refused, since `OTSSEAL3` and `OTSSEAL2` are
    /// one bit apart. That is stated rather than defended, because it
    /// costs nothing either way: the magic is inside the associated
    /// data, so a file whose magic was flipped can never authenticate
    /// again under any key, and refusing it forever would only withhold
    /// the licence over bytes nobody will ever read. Anyone who can
    /// write that byte could have deleted the file outright.
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

    /// The ledger keeps its own envelope and its own key, and neither
    /// one moved in this break. If this ever fails, the ledger has
    /// picked up the content file's lifetime and stopped being a ledger.
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

    /// A death between the write and the rename strands a whole sealed
    /// generation, or a whole key half, in the state directory, and
    /// nothing used to sweep them: the per-user temp directory these
    /// once landed in was cleared at boot and this one never is
    /// (ADR-0016 section 8). They go with the same discipline as the
    /// files they were going to become, because that is what they hold.
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

        // Everything that is not that exact shape stays: the sweep
        // chooses its own paths, and what it calls zeroes and truncates.
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

    /// A directory that cannot be read is not a failure worth a return
    /// value: the sweep is best effort at launch, and everything after
    /// it must still run.
    #[test]
    fn sweeping_a_directory_that_is_not_there_is_not_an_error() {
        sweep_stranded_temps(Path::new("/nowhere/at/all"));
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

    /// Stability across calls is the whole of ADR-0016 as the key
    /// derivation sees it. Nothing here reads the boot session any more,
    /// so a later launch is indistinguishable from a later call: it
    /// finds the half the earlier one wrote, joins it to the keychain
    /// half, and lands on the same key, which is what lets content
    /// outlive a restart. Under the previous design each boot session
    /// derived a key unrelated to the last.
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

    /// The derivation is over both halves, so replacing either one
    /// yields a different key. That is what makes deleting one of them a
    /// crypto-erasure of everything sealed under the pair.
    #[test]
    fn changing_either_half_changes_the_derived_key() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        let original = ensure_state_key(&store, &path).unwrap();

        // The file half is taken away and minted afresh; the keychain
        // half is untouched, and the derived key is different.
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

        // A different keychain half over the same directory: different
        // key again, and a file half of its own.
        let other = InMemoryCredentialStore::default();
        let stranger = ensure_state_key(&other, &path).unwrap();
        assert_ne!(&*after, &*stranger);
        assert_eq!(
            dir.halves().len(),
            2,
            "two credential stores must not share a file half"
        );

        // And the derivation itself is a pure function of the two.
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

    /// Restore loads both halves and mints neither. A file half that is
    /// gone means the content it keyed is gone, and the only correct
    /// answer is to refuse rather than to manufacture a key that opens
    /// nothing.
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

    /// The half is a whole key's worth of bytes, readable by nobody but
    /// the owner, and it sits in the state directory rather than in the
    /// per-user temp directory. That last clause is the ADR-0016 change:
    /// a half in a directory macOS clears at boot cannot key content
    /// that survives a restart.
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

    /// Rotation kills both halves, so every file sealed under the old
    /// derivation is unopenable afterwards, and the next save derives a
    /// key that shares nothing with it.
    #[test]
    fn rotate_key_halves_makes_a_sealed_file_unopenable() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        let key = ensure_state_key(&store, &path).unwrap();
        let sealed = seal(&key, b"staged content the user has discarded");

        assert!(
            rotate_key_halves(&store, &path),
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

    /// The ledger outlives the content on purpose, so a rotation must
    /// leave its key exactly where it was. If this ever fails, every
    /// audit record on disk is lost the first time the pad empties.
    #[test]
    fn rotation_leaves_the_ledger_key_intact() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        ensure_state_key(&store, &path).unwrap();
        let ledger = ensure_ledger_key(&store).unwrap();
        let record = seal_ledger(&ledger, b"created 0001, sent clipboard").unwrap();

        assert!(rotate_key_halves(&store, &path));

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
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = InMemoryCredentialStore::default();
        assert!(rotate_key_halves(&store, &path));
        assert!(rotate_key_halves(&store, &path));
        assert!(dir.halves().is_empty());
        assert!(load_state_key(&store, &path).is_none());
    }

    /// A rotation the backend refused must say so. A locked keychain
    /// leaves the keychain half alive, which leaves every ciphertext
    /// generation it can open readable, and the forgetting the user
    /// asked for has not happened.
    #[test]
    fn a_rotation_the_keychain_refused_reports_failure() {
        let dir = StateDir::new();
        let path = dir.state_path();
        let store = test_stores::RefusesToDelete::default();
        ensure_state_key(&store, &path).unwrap();
        let keychain_half = load_key_for(&store, STATE_KEY_ACCOUNT).unwrap();

        assert!(
            !rotate_key_halves(&store, &path),
            "a rotation that deleted nothing reported success"
        );
        assert!(
            dir.halves().is_empty(),
            "the file half survived a rotation that could still reach it"
        );
        // The surviving keychain half is the whole problem: it is the
        // sufficient deletion, and it did not happen.
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
