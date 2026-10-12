//! Credential storage in the OS keychain (doc 05): the API token in the
//! login keychain, key material in the data protection keychain (ADR-0012).

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
    /// Delete the secret for `account`; a missing item is not an error.
    fn delete(&self, account: &str) -> Result<(), CredentialError>;
    /// Whether a credential is stored for `account`, without reading it,
    /// so no ACL prompt; true even when `load` would be refused.
    fn exists(&self, account: &str) -> Result<bool, CredentialError>;

    /// The process-stable store for key material on this service
    /// (ADR-0012). Not for the API token, which stays on `self`.
    fn key_material_store(&self) -> Arc<dyn CredentialStore>;
}

/// The platform default: the macOS Keychain where available, the
/// in-memory dev fallback elsewhere.
#[must_use]
pub fn default_credential_store() -> Arc<dyn CredentialStore> {
    credential_store_for(SERVICE)
}

/// A store scoped to `service`. Each form factor has its own, since
/// keychain ACLs belong to the code identity that created an item.
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

/// The data protection store for `service` (ADR-0012), memoized so the
/// process shares one [`EntitlementGate`] per service.
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

/// Only [`data_protection_store_for`] may call this: each instance has
/// its own gate.
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

/// `errSecMissingEntitlement`, which ad hoc signed builds get from the
/// data protection keychain (ADR-0012).
pub const ERR_SEC_MISSING_ENTITLEMENT: i32 = -34018;

/// Which keychain a [`DataProtectionKeychainStore`] actually reaches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeychainTier {
    /// The data protection keychain.
    DataProtection,
    /// The file based login keychain, after a missing entitlement.
    FileFallback,
}

/// The tier a raw `SecItem` status implies; only
/// [`ERR_SEC_MISSING_ENTITLEMENT`] means fallback.
#[must_use]
pub fn tier_for_status(status: i32) -> KeychainTier {
    if status == ERR_SEC_MISSING_ENTITLEMENT {
        KeychainTier::FileFallback
    } else {
        KeychainTier::DataProtection
    }
}

type LogSink = Box<dyn Fn(&str) + Send + Sync>;

type SharedLogSink = dyn Fn(&str) + Send + Sync;

/// `None` means stderr, which a `launchd`-launched app discards.
static PROCESS_SINK: Mutex<Option<Arc<SharedLogSink>>> = Mutex::new(None);

/// Send this crate's diagnostics to `sink`, replacing any earlier one.
/// The sink is called with no lock held.
pub fn set_diagnostic_sink<F>(sink: F)
where
    F: Fn(&str) + Send + Sync + 'static,
{
    *PROCESS_SINK.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::new(sink));
}

/// One line out: to the registered sink, or to stderr.
pub fn emit_diagnostic(line: &str) {
    let sink = PROCESS_SINK
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    match sink {
        Some(sink) => sink(line),
        None => eprintln!("{line}"),
    }
}

/// Decides once whether this process can use the data protection
/// keychain, and announces a degradation once.
pub struct EntitlementGate {
    service: String,
    tier: Mutex<Option<KeychainTier>>,
    announced: Once,
    sink: LogSink,
}

impl EntitlementGate {
    /// A gate for `service`, announcing via [`emit_diagnostic`] (resolved
    /// per call: stores are built before the shell registers a sink).
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

    /// The resolved tier, running `probe` (a raw `SecItem` status) at most once.
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

    /// Pin the gate to [`KeychainTier::FileFallback`] permanently.
    pub fn demote(&self) {
        {
            let mut slot = self.tier.lock().unwrap_or_else(PoisonError::into_inner);
            *slot = Some(KeychainTier::FileFallback);
        }
        self.announce();
    }

    /// The tier decided so far, without deciding one.
    #[must_use]
    pub fn decided(&self) -> Option<KeychainTier> {
        *self.tier.lock().unwrap_or_else(PoisonError::into_inner)
    }

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

/// Dev/test-only, non-persistent credential store for non-macOS hosts.
#[derive(Default)]
pub struct InMemoryCredentialStore {
    inner: Arc<Mutex<HashMap<String, Zeroizing<Vec<u8>>>>>,
}

impl InMemoryCredentialStore {
    /// Another handle onto this store's map.
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

    /// This same map; not [`data_protection_store_for`], which is keyed
    /// by a service an in-memory store does not have.
    fn key_material_store(&self) -> Arc<dyn CredentialStore> {
        Arc::new(self.sharing())
    }
}

fn poisoned() -> CredentialError {
    CredentialError::Backend("credential store lock poisoned".to_string())
}

/// Login keychain store: generic password items scoped to a service.
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

    /// The service every item of this store is scoped to.
    #[must_use]
    pub fn service(&self) -> &str {
        &self.service
    }

    /// Raw status to a crate error, with the framework's own message.
    fn backend(status: i32) -> CredentialError {
        CredentialError::Backend(security_framework::base::Error::from_code(status).to_string())
    }
}

/// Every call names the default keychain, never the search list (ADR-0046).
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
        secitem::delete(secitem::Keychain::DefaultFile, &self.service, account)
            .map_err(Self::backend)
    }

    fn exists(&self, account: &str) -> Result<bool, CredentialError> {
        secitem::exists(secitem::Keychain::DefaultFile, &self.service, account)
            .map_err(Self::backend)
    }

    /// The data protection store for this store's service (ADR-0012).
    fn key_material_store(&self) -> Arc<dyn CredentialStore> {
        data_protection_store_for(&self.service)
    }
}

/// Raw `SecItem` access to a named keychain, returning raw `OSStatus` (ADR-0046).
#[cfg(target_os = "macos")]
mod secitem {
    #![allow(unsafe_code)]
    // Apple's constant names, as written.
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

    // Immortal `CFString` statics the sys crate does not declare.
    unsafe extern "C" {
        static kSecAttrAccessible: CFStringRef;
        static kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFStringRef;
        static kSecMatchLimitOne: CFStringRef;
    }

    /// Never written; only [`probe`] queries it.
    const PROBE_ACCOUNT: &str = "entitlement-probe";

    /// Wrap a framework string constant without taking ownership.
    macro_rules! sec_string {
        ($name:ident) => {
            // SAFETY: `$name` is a process-lifetime framework static;
            // get-rule wrapping retains it and drop releases it.
            unsafe { CFString::wrap_under_get_rule($name) }
        };
    }

    /// Which keychain a call is aimed at.
    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    pub enum Keychain {
        /// The data protection keychain (ADR-0012).
        DataProtection,
        /// The user's default file based keychain, named, not searched.
        DefaultFile,
    }

    impl Keychain {
        /// The pair that scopes a lookup, update or delete to this keychain.
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

        /// The pairs that put a new item in this keychain; `SecItemAdd`
        /// ignores match keys, and the protection class is set only here.
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

    /// Class, service, account and keychain scope.
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

    /// Add the item, or update it in place. The `CFData` copy of the
    /// secret cannot be zeroized.
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

        // SAFETY: a well-formed dictionary and a null result pointer,
        // which SecItemAdd accepts.
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

    /// Replace the data of an existing item; the protection class stays.
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
        // SAFETY: a well-formed query and a live out-parameter; a +1
        // result is taken under the create rule below.
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
            errSecItemNotFound | errSecSuccess => Ok(None),
            other => Err(other),
        }
    }

    /// Whether the item exists, from attributes only.
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

    /// Query the data protection keychain for [`PROBE_ACCOUNT`]; an
    /// optimisation only (ADR-0012 amendment 2026-08-10).
    pub fn probe(service: &str) -> i32 {
        attributes_status(Keychain::DataProtection, service, PROBE_ACCOUNT)
    }

    /// An attributes-only `SecItemCopyMatching`, below the ACL prompt.
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
            // SAFETY: a +1 result, taken under the create rule to release it.
            drop(unsafe { CFType::wrap_under_create_rule(result) });
        }
        status
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn each_tier_names_a_different_keychain() {
            let protection = Keychain::DataProtection
                .query_scope()
                .expect("the data protection scope needs no lookup")
                .0
                .to_string();
            // A headless runner has no default keychain.
            let Ok((file_key, _)) = Keychain::DefaultFile.query_scope() else {
                return;
            };
            assert_ne!(protection, file_key.to_string());
        }

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

/// The data protection keychain store, falling back to [`KeychainStore`]
/// on a missing entitlement (ADR-0012).
#[cfg(target_os = "macos")]
pub struct DataProtectionKeychainStore {
    service: String,
    gate: EntitlementGate,
    fallback: KeychainStore,
}

#[cfg(target_os = "macos")]
impl DataProtectionKeychainStore {
    /// A store scoped to `service`; touches no keychain until used.
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

    /// The keychain this store reaches, probed once.
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

    /// Falls through to the login keychain before reporting absence
    /// (ADR-0012 amendment 2026-08-10).
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

    /// Deletes reach both tiers (ADR-0012 amendment 2026-08-10).
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
            Ok(false) => self.fallback.exists(account),
            Err(ERR_SEC_MISSING_ENTITLEMENT) => {
                self.gate.demote();
                self.fallback.exists(account)
            }
            Err(status) => Err(Self::backend(status)),
        }
    }

    /// The shared store, so the process keeps one gate per service.
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
        assert!(store.exists("acct").unwrap());

        store.delete("acct").unwrap();
        assert!(matches!(store.load("acct"), Err(CredentialError::NotFound)));
        assert!(!store.exists("acct").unwrap());
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

    #[cfg(target_os = "macos")]
    #[test]
    fn a_scoped_store_keeps_the_service_it_was_given() {
        assert_eq!(KeychainStore::new(SERVICE).service(), SERVICE);
        let backdrop = "com.onetimesecret.companion.backdrop";
        assert_eq!(KeychainStore::new(backdrop).service(), backdrop);
        assert_ne!(KeychainStore::new(backdrop).service(), SERVICE);
    }

    #[test]
    fn one_data_protection_store_per_service() {
        let a = data_protection_store_for("svc.identity.a");
        let again = data_protection_store_for("svc.identity.a");
        let b = data_protection_store_for("svc.identity.b");
        assert!(Arc::ptr_eq(&a, &again), "one store per service");
        assert!(!Arc::ptr_eq(&a, &b), "services do not share a store");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn key_material_crosses_to_the_same_service() {
        let backdrop = "com.onetimesecret.companion.test.backdrop";
        let store = KeychainStore::new(backdrop);
        let keys = store.key_material_store();
        assert!(Arc::ptr_eq(&keys, &data_protection_store_for(backdrop)));
        assert!(!Arc::ptr_eq(&keys, &data_protection_store_for(SERVICE)));
    }

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
        assert!(store.key_material_store().exists("state-key").unwrap());

        let other = InMemoryCredentialStore::default();
        assert!(!other.key_material_store().exists("state-key").unwrap());

        store.delete("state-key").unwrap();
        assert!(!keys.exists("state-key").unwrap());
    }

    use std::sync::atomic::{AtomicUsize, Ordering};

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
        // Success, not found, locked keychain, denied ACL.
        for status in [0, ERR_SEC_ITEM_NOT_FOUND_STATUS, -25308, -128] {
            assert_eq!(tier_for_status(status), KeychainTier::DataProtection);
        }
    }

    /// `errSecItemNotFound`, without the macOS-only constant.
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
    fn the_diagnostic_sink_is_replaced_and_may_emit_again() {
        // The sink is process-wide; keychain tests may emit into it concurrently.
        let replaced = Arc::new(AtomicUsize::new(0));
        let first = Arc::clone(&replaced);
        set_diagnostic_sink(move |line: &str| {
            if line == "once" {
                first.fetch_add(1, Ordering::SeqCst);
            }
        });
        let lines = Arc::new(Mutex::new(Vec::new()));
        let sink_lines = Arc::clone(&lines);
        set_diagnostic_sink(move |line: &str| {
            sink_lines.lock().unwrap().push(line.to_string());
            if line == "once" {
                emit_diagnostic("again");
            }
        });
        emit_diagnostic("once");
        let lines = lines.lock().unwrap();
        let once = lines.iter().position(|l| l == "once").expect("delivered");
        assert!(lines[once..].iter().any(|l| l == "again"));
        assert_eq!(replaced.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_healthy_gate_never_logs() {
        let (gate, lines) = recording_gate("svc");
        assert_eq!(gate.tier(|| 0), KeychainTier::DataProtection);
        assert!(lines.lock().unwrap().is_empty());
    }

    /// Run by hand on a signed build (docs/qa/hardware-verification.md §C).
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "touches the real keychain; run by hand per docs/qa/hardware-verification.md"]
    fn data_protection_items_are_invisible_to_the_login_keychain() {
        let service = "com.onetimesecret.companion.test.dpk";
        let account = "hardware-verification";
        let secret = b"data-protection-round-trip";

        let store = DataProtectionKeychainStore::new(service);
        let legacy = KeychainStore::new(service);

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
            assert!(
                matches!(legacy.load(account), Err(CredentialError::NotFound)),
                "the login keychain must not see a data protection item"
            );
            assert!(!legacy.exists(account).unwrap());
        }

        store.store(account, b"rotated").unwrap();
        assert_eq!(&*store.load(account).unwrap(), b"rotated");

        store.delete(account).unwrap();
        assert!(matches!(
            store.load(account),
            Err(CredentialError::NotFound)
        ));
        assert!(!store.exists(account).unwrap());
        store.delete(account).unwrap();

        // An unentitled build's writes land here while the tier still
        // says data protection.
        legacy.store(account, b"written-by-the-fallback").unwrap();
        assert_eq!(&*store.load(account).unwrap(), b"written-by-the-fallback");
        assert!(store.exists(account).unwrap());

        store.delete(account).unwrap();
        assert!(matches!(
            legacy.load(account),
            Err(CredentialError::NotFound)
        ));
        assert!(!store.exists(account).unwrap());
    }
}
