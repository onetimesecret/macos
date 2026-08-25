//! Credential storage: the API token lives in the OS keychain, never in
//! plaintext config (doc 05).
//!
//! The Onetime Secret **API token** (the password half of Basic auth,
//! see `ots-client`) is itself a secret. This crate defines a portable
//! [`CredentialStore`] contract with three implementations:
//!
//! - [`KeychainStore`] — macOS Keychain via `security-framework`,
//!   compiled only on macOS (the platform CI lane validates it). This is
//!   the legacy file based login keychain, and it stays the home of the
//!   API token: its ACL prompt path is the story the conceal action
//!   tells.
//! - [`DataProtectionKeychainStore`]: the modern data protection
//!   keychain (`kSecUseDataProtectionKeychain`,
//!   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), reached through
//!   raw `SecItem` calls, and home to the key material ADR-0012 puts
//!   behind a lock gated, this device only item. A build with no
//!   `keychain-access-groups` entitlement (any ad hoc signed dev build)
//!   cannot write to that keychain at all, so the store degrades to
//!   [`KeychainStore`] once, loudly, and then stays there. Only writes
//!   are refused outright, though: a read of a missing item answers
//!   "not found" either way, so the degradation cannot be decided from
//!   a read, and every read falls through to [`KeychainStore`] before
//!   it reports absence. An item is wherever it was written.
//! - [`InMemoryCredentialStore`] — a **dev/test-only**, non-persistent
//!   fallback so everything above this crate builds and tests off macOS.
//!
//! The two keychain tiers are not two unrelated stores a caller picks
//! between. A caller holding one store asks it for the other with
//! [`CredentialStore::key_material_store`], which is the only way a
//! consumer that sees the trait object (the FFI persistence module holds
//! a `&dyn CredentialStore` and nothing else) can reach a data
//! protection store scoped to the same service. Key material moves
//! there; the API token does not.
//!
//! Loaded secrets come back wrapped in [`Zeroizing`] so they wipe on
//! drop. Error messages never embed secret material.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, Once, OnceLock, PoisonError};

use zeroize::Zeroizing;

/// Keychain service name scoping all of this app's credential items.
pub const SERVICE: &str = "com.onetimesecret.companion";

/// Errors from a credential store. Messages never embed secret material.
#[derive(Debug)]
pub enum CredentialError {
    /// No credential stored for that account.
    NotFound,
    /// The platform backend failed; the message is backend text only.
    Backend(String),
}

impl std::fmt::Display for CredentialError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CredentialError::NotFound => f.write_str("credential not found"),
            CredentialError::Backend(msg) => write!(f, "credential backend error: {msg}"),
        }
    }
}

impl std::error::Error for CredentialError {}

/// A place to keep credentials at rest. Implementations must be
/// thread-safe.
pub trait CredentialStore: Send + Sync {
    /// Store (or replace) the secret for `account`.
    fn store(&self, account: &str, secret: &[u8]) -> Result<(), CredentialError>;
    /// Load the secret for `account`, or [`CredentialError::NotFound`].
    fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, CredentialError>;
    /// Delete the secret for `account`. Deleting a missing item is not
    /// an error.
    fn delete(&self, account: &str) -> Result<(), CredentialError>;
    /// Whether a credential is stored for `account`, decided **without
    /// reading the secret**. On macOS this is an attributes-only
    /// Keychain query, so it never provokes the ACL confirmation prompt
    /// that [`load`](Self::load) can. The distinction is deliberate:
    /// this returns `true` for an item that is present but that the
    /// process is not (yet) authorized to decrypt — the case where
    /// `load(...).is_ok()` would return `false`. It answers "is a token
    /// stored?", not "can we read it right now?".
    fn exists(&self, account: &str) -> Result<bool, CredentialError>;

    /// The store that **key material** for this store's service belongs
    /// in: on macOS the data protection keychain
    /// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, lock gated, this
    /// device only) that ADR-0012 requires for the content key's
    /// keychain half and for the ledger key.
    ///
    /// This exists because the trait object is all a consumer gets. The
    /// FFI persistence module is handed a `&dyn CredentialStore` and no
    /// service name, so without this method it cannot name the service
    /// it would have to construct a data protection store for, and the
    /// key halves silently stay in the login keychain. Asking the store
    /// itself keeps the scoping exact by construction: the returned
    /// store is always the same service as `self`, never the default
    /// [`SERVICE`] and never a service the caller had to spell again.
    ///
    /// **The API token does not move.** Only key material does. The
    /// token stays on `self`, which is the legacy login keychain path
    /// its ACL confirmation prompt depends on. A caller that stores the
    /// token through the returned store has changed the token's prompt
    /// behaviour, which is not what this method is for.
    ///
    /// Implementations must return a store that is stable for the life
    /// of the process rather than a freshly built one per call: the
    /// missing-entitlement fallback is decided once and announced once
    /// per store (see [`EntitlementGate`]), so a new store per call
    /// would re-probe the keychain on every credential access and repeat
    /// the degradation notice forever.
    fn key_material_store(&self) -> Arc<dyn CredentialStore>;
}

/// The platform default: the macOS Keychain where available, the
/// in-memory dev fallback elsewhere.
#[must_use]
pub fn default_credential_store() -> Arc<dyn CredentialStore> {
    credential_store_for(SERVICE)
}

/// A store scoped to `service` rather than [`SERVICE`]. Every form
/// factor gets its own service name so each owns its items outright:
/// Keychain ACLs are granted to the code identity that created an item,
/// so a second app reaching into the first's service would raise a
/// confirmation prompt for a key it has no business holding. Separate
/// services mean separate keys, separate prompts, and a state file that
/// only the app that wrote it can open.
#[must_use]
pub fn credential_store_for(service: &str) -> Arc<dyn CredentialStore> {
    #[cfg(target_os = "macos")]
    {
        Arc::new(KeychainStore::new(service))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = service;
        Arc::new(InMemoryCredentialStore::default())
    }
}

/// A store that prefers the data protection keychain, degrading to the
/// file based login keychain when the entitlement is missing. Off macOS
/// this is the in-memory dev fallback, exactly like
/// [`credential_store_for`].
///
/// ADR-0012 puts the keychain half of the content wrapping key, and the
/// ledger key, in this store. The API token stays in
/// [`credential_store_for`] so its ACL prompt behaviour is untouched.
/// Callers holding only a trait object reach this through
/// [`CredentialStore::key_material_store`] rather than naming the
/// service a second time.
///
/// **One store per service, per process.** The instance is memoized on
/// the service name, so every caller for a service shares one
/// [`EntitlementGate`]: the missing-entitlement fallback is probed once
/// and announced once for the whole process, not once per call site and
/// not once per credential access. Building a fresh store per call would
/// make that guarantee false, which is precisely what the once-decided,
/// once-logged contract in [`EntitlementGate`] promises.
#[must_use]
pub fn data_protection_store_for(service: &str) -> Arc<dyn CredentialStore> {
    static STORES: OnceLock<Mutex<HashMap<String, Arc<dyn CredentialStore>>>> = OnceLock::new();
    let mut stores = STORES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    Arc::clone(
        stores
            .entry(service.to_string())
            .or_insert_with(|| new_data_protection_store(service)),
    )
}

/// The platform's data protection store, built fresh. Private because
/// an unshared instance carries its own [`EntitlementGate`]: only
/// [`data_protection_store_for`] may call this, and only once per
/// service.
fn new_data_protection_store(service: &str) -> Arc<dyn CredentialStore> {
    #[cfg(target_os = "macos")]
    {
        Arc::new(DataProtectionKeychainStore::new(service))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = service;
        Arc::new(InMemoryCredentialStore::default())
    }
}

/// `errSecMissingEntitlement`: what the data protection keychain
/// returns to a process that has no `keychain-access-groups`
/// entitlement. `keychain-access-groups` is not a restricted
/// entitlement, but it needs a Team ID backed signing identity, which an
/// ad hoc signed build does not have (ADR-0012).
pub const ERR_SEC_MISSING_ENTITLEMENT: i32 = -34018;

/// Which keychain a [`DataProtectionKeychainStore`] actually reaches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeychainTier {
    /// The data protection keychain: items are this device only and
    /// lock gated, which is what ADR-0012 asks for.
    DataProtection,
    /// The legacy file based login keychain. Reached only after a
    /// missing entitlement, and only for the affected service.
    FileFallback,
}

/// The tier a raw `SecItem` status implies. Only
/// [`ERR_SEC_MISSING_ENTITLEMENT`] means "this process may never use the
/// data protection keychain"; every other status (success, item not
/// found, a locked keychain, a denied ACL) is a per-call outcome and
/// says nothing about the tier.
#[must_use]
pub fn tier_for_status(status: i32) -> KeychainTier {
    if status == ERR_SEC_MISSING_ENTITLEMENT {
        KeychainTier::FileFallback
    } else {
        KeychainTier::DataProtection
    }
}

/// Where the degradation notice goes. Injectable so a test can read the
/// line without a keychain in sight.
type LogSink = Box<dyn Fn(&str) + Send + Sync>;

/// The same destination, shared: one host-installed sink serving every
/// gate in the process rather than one per store.
type SharedLogSink = dyn Fn(&str) + Send + Sync;

/// Where this crate's diagnostics go when a host has said. `None` means
/// stderr, which is right for `cargo test` and for a binary run from a
/// terminal, and wrong for the case these lines exist for: an installed
/// app launched by `launchd`, whose stderr is `/dev/null` before the
/// process starts.
static PROCESS_SINK: Mutex<Option<Arc<SharedLogSink>>> = Mutex::new(None);

/// Send this crate's diagnostics somewhere the host can read them.
///
/// The shell registers one destination through the FFI seam and it
/// covers both crates; nothing here knows or cares where the lines
/// land. Registering replaces whatever was registered before.
///
/// The sink is called with no lock held, so it may log from any thread,
/// and it is called at most once per event in any case: the degradation
/// notice is announced once per gate, for the life of the process.
pub fn set_diagnostic_sink<F>(sink: F)
where
    F: Fn(&str) + Send + Sync + 'static,
{
    *PROCESS_SINK.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::new(sink));
}

/// One line out: to the registered sink, or to stderr.
pub fn emit_diagnostic(line: &str) {
    // Cloned out, then the guard drops, so a sink that emits again (or
    // simply logs from another thread) cannot deadlock against itself.
    let sink = PROCESS_SINK
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    match sink {
        Some(sink) => sink(line),
        None => eprintln!("{line}"),
    }
}

/// Decides **once** whether this process can use the data protection
/// keychain, and announces a degradation **once**.
///
/// The decision is cached, not re-probed: the first operation resolves
/// the tier (via a probe, or via its own status when it comes back
/// [`ERR_SEC_MISSING_ENTITLEMENT`]) and every later call reads the
/// cached answer. Without the cache an unentitled build would pay a
/// failed keychain round trip on every single credential access and
/// would repeat the log line forever.
pub struct EntitlementGate {
    service: String,
    tier: Mutex<Option<KeychainTier>>,
    announced: Once,
    sink: LogSink,
}

impl EntitlementGate {
    /// A gate for `service`, announcing wherever [`set_diagnostic_sink`]
    /// points, and on stderr until something does.
    ///
    /// Resolved per call rather than captured at construction, because a
    /// store is built before the shell has finished starting: capturing
    /// the destination here would pin the default and the notice would
    /// keep going to the stderr nobody is reading.
    #[must_use]
    pub fn new(service: &str) -> Self {
        Self {
            service: service.to_string(),
            tier: Mutex::new(None),
            announced: Once::new(),
            sink: Box::new(emit_diagnostic),
        }
    }

    /// A gate whose notice goes somewhere a test can read.
    #[cfg(test)]
    fn with_sink(service: &str, sink: LogSink) -> Self {
        Self {
            service: service.to_string(),
            tier: Mutex::new(None),
            announced: Once::new(),
            sink,
        }
    }

    /// The resolved tier, running `probe` at most once per gate. `probe`
    /// returns a raw `SecItem` status.
    pub fn tier(&self, probe: impl FnOnce() -> i32) -> KeychainTier {
        let resolved = {
            let mut slot = self.tier.lock().unwrap_or_else(PoisonError::into_inner);
            match *slot {
                Some(tier) => return tier,
                None => {
                    let tier = tier_for_status(probe());
                    *slot = Some(tier);
                    tier
                }
            }
        };
        if resolved == KeychainTier::FileFallback {
            self.announce();
        }
        resolved
    }

    /// Pin the gate to [`KeychainTier::FileFallback`] permanently. Call
    /// this when a real operation returns
    /// [`ERR_SEC_MISSING_ENTITLEMENT`] despite a probe that looked fine.
    pub fn demote(&self) {
        {
            let mut slot = self.tier.lock().unwrap_or_else(PoisonError::into_inner);
            *slot = Some(KeychainTier::FileFallback);
        }
        self.announce();
    }

    /// The tier decided so far, without deciding one. Diagnostics and
    /// tests only.
    #[must_use]
    pub fn decided(&self) -> Option<KeychainTier> {
        *self.tier.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// One line, ever, naming the entitlement and the consequence.
    fn announce(&self) {
        let service = &self.service;
        self.announced.call_once(|| {
            (self.sink)(&format!(
                "companion-credentials: the data protection keychain refused service {service} \
                 with errSecMissingEntitlement ({ERR_SEC_MISSING_ENTITLEMENT}); this build carries \
                 no keychain-access-groups entitlement, which an ad hoc signed build cannot have. \
                 Falling back to the file based login keychain for this service. Consequence: the \
                 keychain key half loses kSecAttrAccessibleWhenUnlockedThisDeviceOnly protection \
                 and is stored under login keychain protection instead; the boot half and the boot \
                 session check are unaffected."
            ));
        });
    }
}

/// Dev/test-only, process-lifetime credential store. **Not** persistent
/// and **not** for production: it holds tokens in ordinary process
/// memory (wiped on drop, but never written to an OS keychain). The
/// portable build uses it so credential-consuming paths are exercisable
/// off macOS.
///
/// The map is behind an [`Arc`] so
/// [`key_material_store`](CredentialStore::key_material_store) can hand
/// back a second handle onto the *same* map. Off macOS there is no
/// second keychain tier to move key material into, and a fresh empty
/// store would silently drop every key written through it: a save would
/// mint a key into a map the matching restore never sees.
#[derive(Default)]
pub struct InMemoryCredentialStore {
    inner: Arc<Mutex<HashMap<String, Zeroizing<Vec<u8>>>>>,
}

impl InMemoryCredentialStore {
    /// Another handle onto this store's map. Not a copy: writes through
    /// either handle are visible through both.
    #[must_use]
    fn sharing(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl CredentialStore for InMemoryCredentialStore {
    fn store(&self, account: &str, secret: &[u8]) -> Result<(), CredentialError> {
        let mut map = self.inner.lock().map_err(|_| poisoned())?;
        map.insert(account.to_string(), Zeroizing::new(secret.to_vec()));
        Ok(())
    }

    fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, CredentialError> {
        let map = self.inner.lock().map_err(|_| poisoned())?;
        map.get(account)
            .map(|v| Zeroizing::new(v.to_vec()))
            .ok_or(CredentialError::NotFound)
    }

    fn delete(&self, account: &str) -> Result<(), CredentialError> {
        let mut map = self.inner.lock().map_err(|_| poisoned())?;
        map.remove(account);
        Ok(())
    }

    fn exists(&self, account: &str) -> Result<bool, CredentialError> {
        let map = self.inner.lock().map_err(|_| poisoned())?;
        Ok(map.contains_key(account))
    }

    /// This same store, sharing one map. Deliberately not
    /// [`data_protection_store_for`]: that is keyed by service name and
    /// an in-memory store has no service, so two unrelated test stores
    /// would collide in one map and a store's key material would outlive
    /// the store itself.
    fn key_material_store(&self) -> Arc<dyn CredentialStore> {
        Arc::new(self.sharing())
    }
}

fn poisoned() -> CredentialError {
    CredentialError::Backend("credential store lock poisoned".to_string())
}

/// macOS Keychain-backed credential store (generic password items scoped
/// to a service name, [`SERVICE`] by default). Compiled only on macOS;
/// validated in the platform CI lane.
#[cfg(target_os = "macos")]
pub struct KeychainStore {
    service: String,
}

#[cfg(target_os = "macos")]
impl KeychainStore {
    /// A store scoped to `service`.
    #[must_use]
    pub fn new(service: &str) -> Self {
        Self {
            service: service.to_string(),
        }
    }

    /// The service every item of this store is scoped to. Readable so
    /// the scoping can be asserted without a Keychain round-trip.
    #[must_use]
    pub fn service(&self) -> &str {
        &self.service
    }

    /// Raw status to a crate error, with the framework's own message.
    fn backend(status: i32) -> CredentialError {
        CredentialError::Backend(security_framework::base::Error::from_code(status).to_string())
    }
}

/// Every call names the default keychain (see [`secitem`]). The
/// `security-framework` password helpers this used to call, and its
/// `ItemSearchOptions`, cannot name one: they leave the lookup to the
/// user's keychain search list, where a single entry on a backup volume
/// the app may not read is enough to fail an unrelated delete. That
/// failure is what wedged persistence, because a state key that will not
/// delete is a key rotation that reports refusal, and a refused rotation
/// withholds the save licence for the whole session, every session.
#[cfg(target_os = "macos")]
impl CredentialStore for KeychainStore {
    fn store(&self, account: &str, secret: &[u8]) -> Result<(), CredentialError> {
        secitem::add_or_update(
            secitem::Keychain::DefaultFile,
            &self.service,
            account,
            secret,
        )
        .map_err(Self::backend)
    }

    fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, CredentialError> {
        match secitem::copy_secret(secitem::Keychain::DefaultFile, &self.service, account) {
            Ok(Some(secret)) => Ok(secret),
            Ok(None) => Err(CredentialError::NotFound),
            Err(status) => Err(Self::backend(status)),
        }
    }

    fn delete(&self, account: &str) -> Result<(), CredentialError> {
        // Deleting a missing item is fine, and the call below already
        // folds that in.
        secitem::delete(secitem::Keychain::DefaultFile, &self.service, account)
            .map_err(Self::backend)
    }

    fn exists(&self, account: &str) -> Result<bool, CredentialError> {
        // Attributes only: the query matches the item but never asks the
        // Keychain to decrypt it, so it stays below the ACL prompt. A hit
        // means the token is stored; the read that actually needs it
        // (the conceal call) is where the prompt belongs.
        secitem::exists(secitem::Keychain::DefaultFile, &self.service, account)
            .map_err(Self::backend)
    }

    /// The data protection store for **this store's** service. This is
    /// the hop ADR-0012 requires: the API token stays here in the login
    /// keychain, where its ACL prompt path is, and the key material
    /// crosses to a lock gated, this device only item under the same
    /// service name.
    fn key_material_store(&self) -> Arc<dyn CredentialStore> {
        data_protection_store_for(&self.service)
    }
}

/// Raw `SecItem` access, to a named keychain in every call.
///
/// This is the one module in the crate that writes `unsafe`, so the FFI
/// surface stays auditable by module rather than by crate. Every
/// function here returns the raw `OSStatus` on failure and leaves the
/// interpretation (not found, missing entitlement, anything else) to the
/// store above.
///
/// Why raw calls at all: `security-framework` 2.11 builds its
/// generic-password dictionaries from `kSecClass`, `kSecAttrService` and
/// `kSecAttrAccount` alone. It never sets
/// `kSecUseDataProtectionKeychain`, so its items land in the login
/// keychain, and it silently ignores `kSecAttrAccessible`. Its search
/// options cannot name a keychain at all, so even a hand-added item
/// would be unreadable and undeletable through them.
///
/// Naming a keychain is not a nicety on either path. An unnamed legacy
/// query is resolved against the user's keychain **search list**, which
/// is user-editable, unbounded, and routinely holds keychains on backup
/// volumes and disks that are gone. A search-list entry the process
/// cannot open throws inside `SecItemDelete_osx`, and the error comes
/// back as the delete's own status: one unreachable keychain anywhere in
/// the list makes every delete fail, for an item sitting in the default
/// keychain the whole time. Sandboxing and TCC make that per process, so
/// the same call succeeds from a terminal with full disk access and
/// fails inside the app, which is how it stayed hidden.
#[cfg(target_os = "macos")]
mod secitem {
    #![allow(unsafe_code)]
    // The Security framework's own constant names, used as written so a
    // reader can grep them against Apple's headers.
    #![allow(non_upper_case_globals)]

    use core_foundation::array::CFArray;
    use core_foundation::base::{CFType, CFTypeRef, TCFType};
    use core_foundation::boolean::CFBoolean;
    use core_foundation::data::CFData;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::{CFString, CFStringRef};
    use security_framework::os::macos::keychain::SecKeychain;
    use security_framework_sys::base::{errSecDuplicateItem, errSecItemNotFound, errSecSuccess};
    use security_framework_sys::item::{
        kSecAttrAccount, kSecAttrService, kSecClass, kSecClassGenericPassword, kSecMatchLimit,
        kSecMatchSearchList, kSecReturnAttributes, kSecReturnData, kSecUseDataProtectionKeychain,
        kSecUseKeychain, kSecValueData,
    };
    use security_framework_sys::keychain_item::{
        SecItemAdd, SecItemCopyMatching, SecItemDelete, SecItemUpdate,
    };
    use zeroize::Zeroizing;

    // Constants the sys crate does not declare. They are immortal
    // `CFString` statics in the Security framework, which
    // security-framework-sys already links.
    unsafe extern "C" {
        static kSecAttrAccessible: CFStringRef;
        static kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFStringRef;
        static kSecMatchLimitOne: CFStringRef;
    }

    /// The account used by [`probe`]: never written, so a query for it
    /// answers "may this process talk to the data protection keychain at
    /// all" and nothing else.
    const PROBE_ACCOUNT: &str = "entitlement-probe";

    /// Wrap a framework string constant without taking ownership.
    macro_rules! sec_string {
        ($name:ident) => {
            // SAFETY: `$name` is a Security framework static that lives
            // for the process; get-rule wrapping retains it and the
            // `CFString` releases it on drop.
            unsafe { CFString::wrap_under_get_rule($name) }
        };
    }

    /// Which keychain a call is aimed at. Every call names one, and no
    /// call is left to the search list.
    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    pub enum Keychain {
        /// The data protection keychain ADR-0012 asks for: this device
        /// only, lock gated, and no search list anywhere in its design.
        /// Unreachable without a `keychain-access-groups` entitlement.
        DataProtection,
        /// The user's **default** file based keychain, named outright.
        /// The fallback tier, and the only tier an ad hoc signed build
        /// has. Named rather than searched for the reason in this
        /// module's header: one unreachable keychain in the search list
        /// is enough to fail a delete that had nothing to do with it.
        DefaultFile,
    }

    impl Keychain {
        /// The pair that scopes a **query** to this keychain: a lookup,
        /// an update, or a delete. Fallible only on the file path, where
        /// the default keychain has to be resolved before it can be
        /// named.
        fn query_scope(self) -> Result<(CFString, CFType), i32> {
            match self {
                Self::DataProtection => Ok((
                    sec_string!(kSecUseDataProtectionKeychain),
                    CFBoolean::true_value().as_CFType(),
                )),
                Self::DefaultFile => Ok((
                    sec_string!(kSecMatchSearchList),
                    CFArray::from_CFTypes(&[default_keychain()?]).as_CFType(),
                )),
            }
        }

        /// The pairs that put a **new** item in this keychain. A match
        /// key means nothing to `SecItemAdd`, so the file path names its
        /// keychain with `kSecUseKeychain` instead, and the data
        /// protection path carries its protection class here because an
        /// item's class is set once, at add time.
        fn add_scope(self) -> Result<Vec<(CFString, CFType)>, i32> {
            match self {
                Self::DataProtection => Ok(vec![
                    (
                        sec_string!(kSecUseDataProtectionKeychain),
                        CFBoolean::true_value().as_CFType(),
                    ),
                    (
                        sec_string!(kSecAttrAccessible),
                        sec_string!(kSecAttrAccessibleWhenUnlockedThisDeviceOnly).as_CFType(),
                    ),
                ]),
                Self::DefaultFile => Ok(vec![(
                    sec_string!(kSecUseKeychain),
                    default_keychain()?.as_CFType(),
                )]),
            }
        }
    }

    /// The user's default keychain, or the status that says why not.
    fn default_keychain() -> Result<SecKeychain, i32> {
        SecKeychain::default().map_err(security_framework::base::Error::code)
    }

    /// Class, service and account: the part every call shares, plus the
    /// pair that names the keychain it is aimed at.
    fn base_query(
        keychain: Keychain,
        service: &str,
        account: &str,
    ) -> Result<Vec<(CFString, CFType)>, i32> {
        Ok(vec![
            (
                sec_string!(kSecClass),
                sec_string!(kSecClassGenericPassword).as_CFType(),
            ),
            (
                sec_string!(kSecAttrService),
                CFString::new(service).as_CFType(),
            ),
            (
                sec_string!(kSecAttrAccount),
                CFString::new(account).as_CFType(),
            ),
            keychain.query_scope()?,
        ])
    }

    fn dictionary(pairs: &[(CFString, CFType)]) -> CFDictionary<CFString, CFType> {
        CFDictionary::from_CFType_pairs(pairs)
    }

    /// Add the item, or update it in place when it is already there, so
    /// key rotation can re-mint over an existing account.
    ///
    /// The secret is copied into a `CFData` on the way in. That copy is
    /// the framework's price of entry and cannot be zeroized; the caller
    /// keeps its own copy in a [`Zeroizing`] buffer.
    pub fn add_or_update(
        keychain: Keychain,
        service: &str,
        account: &str,
        secret: &[u8],
    ) -> Result<(), i32> {
        let mut attributes = vec![
            (
                sec_string!(kSecClass),
                sec_string!(kSecClassGenericPassword).as_CFType(),
            ),
            (
                sec_string!(kSecAttrService),
                CFString::new(service).as_CFType(),
            ),
            (
                sec_string!(kSecAttrAccount),
                CFString::new(account).as_CFType(),
            ),
        ];
        attributes.extend(keychain.add_scope()?);
        attributes.push((
            sec_string!(kSecValueData),
            CFData::from_buffer(secret).as_CFType(),
        ));

        // SAFETY: a well-formed attributes dictionary, and a null result
        // pointer, which SecItemAdd documents as "return nothing".
        let status = unsafe {
            SecItemAdd(
                dictionary(&attributes).as_concrete_TypeRef(),
                std::ptr::null_mut(),
            )
        };
        match status {
            errSecSuccess => Ok(()),
            errSecDuplicateItem => update(keychain, service, account, secret),
            other => Err(other),
        }
    }

    /// Replace the data of an existing item. Only `kSecValueData` moves:
    /// the protection class was set at add time and re-asserting it here
    /// would let a future edit disagree with itself.
    fn update(keychain: Keychain, service: &str, account: &str, secret: &[u8]) -> Result<(), i32> {
        let query = dictionary(&base_query(keychain, service, account)?);
        let changes = dictionary(&[(
            sec_string!(kSecValueData),
            CFData::from_buffer(secret).as_CFType(),
        )]);

        // SAFETY: two well-formed dictionaries, both alive across the call.
        let status =
            unsafe { SecItemUpdate(query.as_concrete_TypeRef(), changes.as_concrete_TypeRef()) };
        if status == errSecSuccess {
            Ok(())
        } else {
            Err(status)
        }
    }

    /// The secret, or `Ok(None)` when no such item exists.
    pub fn copy_secret(
        keychain: Keychain,
        service: &str,
        account: &str,
    ) -> Result<Option<Zeroizing<Vec<u8>>>, i32> {
        let mut query = base_query(keychain, service, account)?;
        query.push((
            sec_string!(kSecReturnData),
            CFBoolean::true_value().as_CFType(),
        ));
        query.push((
            sec_string!(kSecMatchLimit),
            sec_string!(kSecMatchLimitOne).as_CFType(),
        ));

        let mut result: CFTypeRef = std::ptr::null();
        // SAFETY: a well-formed query and a live out-parameter. On
        // success the framework hands back a +1 CFDataRef, taken below
        // under the create rule so it is released exactly once.
        let status = unsafe {
            SecItemCopyMatching(
                dictionary(&query).as_concrete_TypeRef(),
                std::ptr::from_mut(&mut result),
            )
        };
        match status {
            errSecSuccess if !result.is_null() => {
                // SAFETY: kSecReturnData means the result is a CFData.
                let data = unsafe { CFData::wrap_under_create_rule(result.cast()) };
                Ok(Some(Zeroizing::new(data.bytes().to_vec())))
            }
            // Absence, and the success-with-nothing-returned case the
            // framework is not documented to produce: report absence
            // rather than invent bytes.
            errSecItemNotFound | errSecSuccess => Ok(None),
            other => Err(other),
        }
    }

    /// Whether the item exists, decided from attributes only so the
    /// query never asks the keychain to decrypt anything.
    pub fn exists(keychain: Keychain, service: &str, account: &str) -> Result<bool, i32> {
        match attributes_status(keychain, service, account) {
            errSecSuccess => Ok(true),
            errSecItemNotFound => Ok(false),
            other => Err(other),
        }
    }

    /// Delete the item. A missing item is not an error.
    pub fn delete(keychain: Keychain, service: &str, account: &str) -> Result<(), i32> {
        let query = dictionary(&base_query(keychain, service, account)?);
        // SAFETY: a well-formed query dictionary, alive across the call.
        let status = unsafe { SecItemDelete(query.as_concrete_TypeRef()) };
        match status {
            errSecSuccess | errSecItemNotFound => Ok(()),
            other => Err(other),
        }
    }

    /// Ask the data protection keychain for an account that is never
    /// written. Returns the raw status: `errSecItemNotFound` when the
    /// keychain is reachable, `errSecMissingEntitlement` when it is not.
    /// Reads no secret and writes nothing.
    pub fn probe(service: &str) -> i32 {
        attributes_status(Keychain::DataProtection, service, PROBE_ACCOUNT)
    }

    /// An attributes-only `SecItemCopyMatching`, returning its raw
    /// status. Shared by [`exists`] and [`probe`] so both stay below the
    /// ACL prompt. A keychain that cannot even be named answers with the
    /// status that says so, which reads as any other refusal.
    fn attributes_status(keychain: Keychain, service: &str, account: &str) -> i32 {
        let mut query = match base_query(keychain, service, account) {
            Ok(query) => query,
            Err(status) => return status,
        };
        query.push((
            sec_string!(kSecReturnAttributes),
            CFBoolean::true_value().as_CFType(),
        ));
        query.push((
            sec_string!(kSecMatchLimit),
            sec_string!(kSecMatchLimitOne).as_CFType(),
        ));

        let mut result: CFTypeRef = std::ptr::null();
        // SAFETY: a well-formed query and a live out-parameter.
        let status = unsafe {
            SecItemCopyMatching(
                dictionary(&query).as_concrete_TypeRef(),
                std::ptr::from_mut(&mut result),
            )
        };
        if status == errSecSuccess && !result.is_null() {
            // SAFETY: a +1 attributes dictionary; taken under the create
            // rule purely so it is released.
            drop(unsafe { CFType::wrap_under_create_rule(result) });
        }
        status
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        /// The two tiers must aim at two keychains. A copy-paste that
        /// left the file path carrying the data protection flag would
        /// send the fallback back to the keychain the fallback exists
        /// because it cannot reach, and a file path carrying no scope at
        /// all would be back on the search list. Compares the keys the
        /// dictionaries are built from; no item is read or written.
        #[test]
        fn each_tier_names_a_different_keychain() {
            let protection = Keychain::DataProtection
                .query_scope()
                .expect("the data protection scope needs no lookup")
                .0
                .to_string();
            // Naming the default keychain is a lookup, and a host without
            // one (a headless runner) has nothing to assert against.
            let Ok((file_key, _)) = Keychain::DefaultFile.query_scope() else {
                return;
            };
            assert_ne!(protection, file_key.to_string());
        }

        /// Adding is not querying: a match key means nothing to
        /// `SecItemAdd`, so the file path has to name its keychain the
        /// other way, and the protection class rides along on the tier
        /// that has one.
        #[test]
        fn adding_names_the_keychain_a_second_way() {
            let protection = Keychain::DataProtection
                .add_scope()
                .expect("the data protection scope needs no lookup");
            assert_eq!(protection.len(), 2, "the flag and the protection class");

            let Ok(file) = Keychain::DefaultFile.add_scope() else {
                return;
            };
            assert_eq!(file.len(), 1, "the keychain, and no protection class");
            assert_ne!(
                file[0].0.to_string(),
                Keychain::DefaultFile
                    .query_scope()
                    .expect("already resolved once")
                    .0
                    .to_string(),
                "adding names a keychain; querying searches one"
            );
        }
    }
}

/// The data protection keychain store ADR-0012 asks for: generic
/// password items scoped to a service, written with
/// `kSecUseDataProtectionKeychain` and
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so they are this
/// device only and unreadable while the device is locked.
///
/// Ad hoc signed builds cannot reach that keychain: with no Team ID
/// there is no implicit `keychain-access-groups` entitlement, and every
/// call returns [`ERR_SEC_MISSING_ENTITLEMENT`]. Rather than fail, the
/// store decides once (see [`EntitlementGate`]), logs once, and serves
/// the rest of the process from [`KeychainStore`] on the same service
/// and account names. Signed installs get the modern store; dev builds
/// keep working with the weaker keychain half, which is exactly the
/// tradeoff the ADR records.
#[cfg(target_os = "macos")]
pub struct DataProtectionKeychainStore {
    service: String,
    gate: EntitlementGate,
    fallback: KeychainStore,
}

#[cfg(target_os = "macos")]
impl DataProtectionKeychainStore {
    /// A store scoped to `service`. Construction touches no keychain;
    /// the first operation resolves the tier.
    #[must_use]
    pub fn new(service: &str) -> Self {
        Self {
            service: service.to_string(),
            gate: EntitlementGate::new(service),
            fallback: KeychainStore::new(service),
        }
    }

    /// The service every item of this store is scoped to.
    #[must_use]
    pub fn service(&self) -> &str {
        &self.service
    }

    /// The keychain this store reaches, probing once and caching the
    /// answer for the life of the store.
    pub fn tier(&self) -> KeychainTier {
        self.gate.tier(|| secitem::probe(&self.service))
    }

    /// Raw status to a crate error, with the framework's own message.
    fn backend(status: i32) -> CredentialError {
        CredentialError::Backend(security_framework::base::Error::from_code(status).to_string())
    }
}

#[cfg(target_os = "macos")]
impl CredentialStore for DataProtectionKeychainStore {
    fn store(&self, account: &str, secret: &[u8]) -> Result<(), CredentialError> {
        if self.tier() == KeychainTier::FileFallback {
            return self.fallback.store(account, secret);
        }
        match secitem::add_or_update(
            secitem::Keychain::DataProtection,
            &self.service,
            account,
            secret,
        ) {
            Ok(()) => Ok(()),
            Err(ERR_SEC_MISSING_ENTITLEMENT) => {
                self.gate.demote();
                self.fallback.store(account, secret)
            }
            Err(status) => Err(Self::backend(status)),
        }
    }

    /// Reads fall through to the login keychain, and that is not
    /// belt-and-braces: it is what keeps an unentitled build able to read
    /// what it wrote.
    ///
    /// The probe cannot be trusted to answer the entitlement question.
    /// It reads an account that is never written, and a **read** of a
    /// missing item answers `errSecItemNotFound` whether or not this
    /// process may use the data protection keychain at all; only a write
    /// or a delete comes back [`ERR_SEC_MISSING_ENTITLEMENT`]. So a build
    /// with no entitlement resolves to [`KeychainTier::DataProtection`],
    /// writes demote and land in the login keychain, and reads keep
    /// asking the data protection keychain, where nothing was ever
    /// written. Absence there is not absence: every key half this app
    /// owns then reads as missing, the sealed file will not open, and the
    /// session that cannot read its own key withholds the save licence
    /// and stops persisting anything at all.
    ///
    /// Reading both tiers costs one extra miss on a healthy install and
    /// removes a failure whose only symptom is an app that has quietly
    /// stopped remembering.
    fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, CredentialError> {
        if self.tier() == KeychainTier::FileFallback {
            return self.fallback.load(account);
        }
        match secitem::copy_secret(secitem::Keychain::DataProtection, &self.service, account) {
            Ok(Some(secret)) => Ok(secret),
            Ok(None) => self.fallback.load(account),
            Err(ERR_SEC_MISSING_ENTITLEMENT) => {
                self.gate.demote();
                self.fallback.load(account)
            }
            Err(status) => Err(Self::backend(status)),
        }
    }

    /// Deletes reach both tiers, for the same reason reads do: an item
    /// this store must destroy can be in either keychain, and a rotation
    /// that removed one copy while another survived would report a
    /// forgetting it did not perform.
    fn delete(&self, account: &str) -> Result<(), CredentialError> {
        if self.tier() == KeychainTier::FileFallback {
            return self.fallback.delete(account);
        }
        match secitem::delete(secitem::Keychain::DataProtection, &self.service, account) {
            Ok(()) => self.fallback.delete(account),
            Err(ERR_SEC_MISSING_ENTITLEMENT) => {
                self.gate.demote();
                self.fallback.delete(account)
            }
            Err(status) => Err(Self::backend(status)),
        }
    }

    fn exists(&self, account: &str) -> Result<bool, CredentialError> {
        if self.tier() == KeychainTier::FileFallback {
            return self.fallback.exists(account);
        }
        match secitem::exists(secitem::Keychain::DataProtection, &self.service, account) {
            Ok(true) => Ok(true),
            // Same fall-through as `load`: absence in one keychain is
            // not absence, and this answer decides whether a rotation
            // counts as done.
            Ok(false) => self.fallback.exists(account),
            Err(ERR_SEC_MISSING_ENTITLEMENT) => {
                self.gate.demote();
                self.fallback.exists(account)
            }
            Err(status) => Err(Self::backend(status)),
        }
    }

    /// The shared store for this service, which is already a data
    /// protection store. Routed through [`data_protection_store_for`]
    /// rather than cloning `self` so the process keeps one gate per
    /// service: a store built directly with
    /// [`DataProtectionKeychainStore::new`] would otherwise hand out a
    /// second gate that probes and announces on its own.
    fn key_material_store(&self) -> Arc<dyn CredentialStore> {
        data_protection_store_for(&self.service)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_round_trips_a_token() {
        let store = InMemoryCredentialStore::default();
        assert!(matches!(store.load("acct"), Err(CredentialError::NotFound)));
        assert!(!store.exists("acct").unwrap());

        store.store("acct", b"api-token-value").unwrap();
        let loaded = store.load("acct").unwrap();
        assert_eq!(&*loaded, b"api-token-value");
        // exists() sees the item without reading it back.
        assert!(store.exists("acct").unwrap());

        store.delete("acct").unwrap();
        assert!(matches!(store.load("acct"), Err(CredentialError::NotFound)));
        assert!(!store.exists("acct").unwrap());
        // Deleting an absent account is not an error.
        store.delete("acct").unwrap();
    }

    #[test]
    fn accounts_are_isolated() {
        let store = InMemoryCredentialStore::default();
        store.store("a", b"token-a").unwrap();
        store.store("b", b"token-b").unwrap();
        assert_eq!(&*store.load("a").unwrap(), b"token-a");
        assert_eq!(&*store.load("b").unwrap(), b"token-b");
    }

    // The KeychainStore path is deliberately untested here: exercising
    // the real Keychain belongs to the on-device spike, not a CI runner's
    // default keychain. The platform lane still compiles it.

    /// Scoping is what keeps two form factors out of each other's
    /// items, so it is asserted on the store's own service name rather
    /// than by writing to the Keychain: constructing a store touches
    /// nothing, and this catches a scope silently collapsing to the
    /// default.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_scoped_store_keeps_the_service_it_was_given() {
        assert_eq!(KeychainStore::new(SERVICE).service(), SERVICE);
        let backdrop = "com.onetimesecret.companion.backdrop";
        assert_eq!(KeychainStore::new(backdrop).service(), backdrop);
        assert_ne!(KeychainStore::new(backdrop).service(), SERVICE);
    }

    // ---- reaching the key material store ------------------------------

    /// The whole point of the accessor: one store per service, so the
    /// entitlement decision and its notice happen once for the process.
    /// Asserted on pointer identity, which construction alone settles;
    /// no keychain is touched.
    #[test]
    fn one_data_protection_store_per_service() {
        let a = data_protection_store_for("svc.identity.a");
        let again = data_protection_store_for("svc.identity.a");
        let b = data_protection_store_for("svc.identity.b");
        assert!(Arc::ptr_eq(&a, &again), "one store per service");
        assert!(!Arc::ptr_eq(&a, &b), "services do not share a store");
    }

    /// A login-keychain store hands back the data protection store for
    /// its **own** service, never the default one. Pointer identity
    /// against the registry is what proves the service matched: the
    /// registry is keyed by service name, so a mismatch would be a
    /// different instance.
    #[cfg(target_os = "macos")]
    #[test]
    fn key_material_crosses_to_the_same_service() {
        let backdrop = "com.onetimesecret.companion.test.backdrop";
        let store = KeychainStore::new(backdrop);
        let keys = store.key_material_store();
        assert!(Arc::ptr_eq(&keys, &data_protection_store_for(backdrop)));
        assert!(!Arc::ptr_eq(&keys, &data_protection_store_for(SERVICE)));
    }

    /// Off macOS, and in every test that fakes a store, key material has
    /// to land somewhere a later read can find it. A fresh empty store
    /// here would break save-then-restore silently rather than loudly:
    /// the save would succeed and the restore would find no key.
    #[test]
    fn the_in_memory_key_store_shares_one_map() {
        let store = InMemoryCredentialStore::default();
        let keys = store.key_material_store();

        keys.store("state-key", b"thirty-two-bytes-in-real-life")
            .unwrap();
        assert_eq!(
            &*store.load("state-key").unwrap(),
            b"thirty-two-bytes-in-real-life"
        );
        // And a second reach finds the same map, not a new one.
        assert!(store.key_material_store().exists("state-key").unwrap());

        // Two unrelated stores stay unrelated: no global map keyed by a
        // service name an in-memory store does not have.
        let other = InMemoryCredentialStore::default();
        assert!(!other.key_material_store().exists("state-key").unwrap());

        store.delete("state-key").unwrap();
        assert!(!keys.exists("state-key").unwrap());
    }

    // ---- the degradation decision -------------------------------------
    //
    // The decision is deliberately keychain-free: a plain status code in,
    // a tier out. That is what lets CI cover the branch that only an ad
    // hoc signed macOS build would otherwise reach.

    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A sink that keeps every announcement, plus the count.
    fn recording_gate(service: &str) -> (EntitlementGate, Arc<Mutex<Vec<String>>>) {
        let lines = Arc::new(Mutex::new(Vec::new()));
        let sink_lines = Arc::clone(&lines);
        let gate = EntitlementGate::with_sink(
            service,
            Box::new(move |line: &str| sink_lines.lock().unwrap().push(line.to_string())),
        );
        (gate, lines)
    }

    #[test]
    fn only_a_missing_entitlement_means_fallback() {
        assert_eq!(
            tier_for_status(ERR_SEC_MISSING_ENTITLEMENT),
            KeychainTier::FileFallback
        );
        // Success, absence, a locked keychain and a denied ACL are all
        // per-call outcomes; none of them says the keychain is off limits.
        for status in [0, ERR_SEC_ITEM_NOT_FOUND_STATUS, -25308, -128] {
            assert_eq!(tier_for_status(status), KeychainTier::DataProtection);
        }
    }

    /// `errSecItemNotFound`, spelled out here so the portable test does
    /// not need the macOS-only constant.
    const ERR_SEC_ITEM_NOT_FOUND_STATUS: i32 = -25300;

    #[test]
    fn the_tier_is_probed_once_and_then_cached() {
        let (gate, _lines) = recording_gate("svc");
        let probes = AtomicUsize::new(0);
        let probe = || {
            probes.fetch_add(1, Ordering::SeqCst);
            ERR_SEC_ITEM_NOT_FOUND_STATUS
        };

        assert_eq!(gate.decided(), None);
        assert_eq!(gate.tier(probe), KeychainTier::DataProtection);
        assert_eq!(gate.tier(probe), KeychainTier::DataProtection);
        assert_eq!(gate.tier(probe), KeychainTier::DataProtection);
        assert_eq!(probes.load(Ordering::SeqCst), 1);
        assert_eq!(gate.decided(), Some(KeychainTier::DataProtection));
    }

    #[test]
    fn a_probe_that_lacks_the_entitlement_degrades_and_says_so_once() {
        let (gate, lines) = recording_gate("com.onetimesecret.companion");
        let probes = AtomicUsize::new(0);
        let probe = || {
            probes.fetch_add(1, Ordering::SeqCst);
            ERR_SEC_MISSING_ENTITLEMENT
        };

        assert_eq!(gate.tier(probe), KeychainTier::FileFallback);
        assert_eq!(gate.tier(probe), KeychainTier::FileFallback);
        // Decided once: no re-probing per call.
        assert_eq!(probes.load(Ordering::SeqCst), 1);

        let lines = lines.lock().unwrap();
        assert_eq!(lines.len(), 1, "the degradation is announced exactly once");
        let line = &lines[0];
        assert!(
            line.contains("keychain-access-groups"),
            "names the entitlement: {line}"
        );
        assert!(
            line.contains("errSecMissingEntitlement"),
            "names the code: {line}"
        );
        assert!(line.contains("-34018"), "names the numeric code: {line}");
        assert!(
            line.contains("login keychain"),
            "names the consequence: {line}"
        );
        assert!(
            line.contains("com.onetimesecret.companion"),
            "names the service: {line}"
        );
    }

    #[test]
    fn a_real_operation_can_demote_a_gate_that_probed_clean() {
        // The probe succeeds and a later call still comes back
        // unentitled: the store demotes, and stays demoted, without ever
        // probing again.
        let (gate, lines) = recording_gate("svc");
        let probes = AtomicUsize::new(0);
        let probe = || {
            probes.fetch_add(1, Ordering::SeqCst);
            ERR_SEC_ITEM_NOT_FOUND_STATUS
        };

        assert_eq!(gate.tier(probe), KeychainTier::DataProtection);
        gate.demote();
        assert_eq!(gate.tier(probe), KeychainTier::FileFallback);
        gate.demote();
        assert_eq!(gate.tier(probe), KeychainTier::FileFallback);
        assert_eq!(probes.load(Ordering::SeqCst), 1);
        assert_eq!(lines.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_healthy_gate_never_logs() {
        let (gate, lines) = recording_gate("svc");
        assert_eq!(gate.tier(|| 0), KeychainTier::DataProtection);
        assert!(lines.lock().unwrap().is_empty());
    }

    /// Hardware verification only (docs/hardware-verification.md §C):
    /// run by hand on a signed build with
    /// `cargo test -p companion-credentials -- --ignored --nocapture`.
    ///
    /// It proves the thing no CI runner can: that
    /// [`data_protection_store_for`] writes into a keychain the legacy
    /// file based [`KeychainStore`] cannot see. On an ad hoc build the
    /// store degrades to that same login keychain, both halves of the
    /// assertion collapse into one keychain, and the test reports the
    /// degradation instead of failing.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "touches the real keychain; run by hand per docs/hardware-verification.md"]
    fn data_protection_items_are_invisible_to_the_login_keychain() {
        let service = "com.onetimesecret.companion.test.dpk";
        let account = "hardware-verification";
        let secret = b"data-protection-round-trip";

        let store = DataProtectionKeychainStore::new(service);
        let legacy = KeychainStore::new(service);

        // Start clean in both keychains, whatever a previous run left.
        store.delete(account).unwrap();
        legacy.delete(account).unwrap();

        store.store(account, secret).unwrap();
        assert_eq!(&*store.load(account).unwrap(), secret);
        assert!(store.exists(account).unwrap());

        if store.tier() == KeychainTier::FileFallback {
            eprintln!(
                "degraded to the login keychain: this build has no \
                 keychain-access-groups entitlement, so keychain separation \
                 is not under test. Re-run from a signed install."
            );
        } else {
            // The point of the whole work item: same service, same
            // account, different keychain.
            assert!(
                matches!(legacy.load(account), Err(CredentialError::NotFound)),
                "the login keychain must not see a data protection item"
            );
            assert!(!legacy.exists(account).unwrap());
        }

        // Re-minting over a live item must update, not fail on duplicate.
        store.store(account, b"rotated").unwrap();
        assert_eq!(&*store.load(account).unwrap(), b"rotated");

        store.delete(account).unwrap();
        assert!(matches!(
            store.load(account),
            Err(CredentialError::NotFound)
        ));
        assert!(!store.exists(account).unwrap());
        // Deleting an absent item is not an error.
        store.delete(account).unwrap();

        // A half written to the login keychain must still be found when
        // the store believes it is on the data protection tier. This is
        // the shape of every unentitled build: the probe reads clean, so
        // the tier says data protection, while every write demoted and
        // landed here. A read that stopped at the first keychain would
        // call this absent, and a key half that reads as absent is a
        // sealed file that never opens again.
        legacy.store(account, b"written-by-the-fallback").unwrap();
        assert_eq!(&*store.load(account).unwrap(), b"written-by-the-fallback");
        assert!(store.exists(account).unwrap());

        // And a delete has to reach it there, or a rotation would report
        // a forgetting that left the key sitting in the other keychain.
        store.delete(account).unwrap();
        assert!(matches!(
            legacy.load(account),
            Err(CredentialError::NotFound)
        ));
        assert!(!store.exists(account).unwrap());
    }
}
