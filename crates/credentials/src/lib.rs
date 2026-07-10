//! Credential storage: the API token lives in the OS keychain, never in
//! plaintext config (doc 05).
//!
//! The Onetime Secret **API token** (the password half of Basic auth,
//! see `ots-client`) is itself a secret. This crate defines a portable
//! [`CredentialStore`] contract with two implementations:
//!
//! - [`KeychainStore`] — macOS Keychain via `security-framework`,
//!   compiled only on macOS (the platform CI lane validates it).
//! - [`InMemoryCredentialStore`] — a **dev/test-only**, non-persistent
//!   fallback so everything above this crate builds and tests off macOS.
//!
//! Loaded secrets come back wrapped in [`Zeroizing`] so they wipe on
//! drop. Error messages never embed secret material.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

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
}

/// The platform default: the macOS Keychain where available, the
/// in-memory dev fallback elsewhere.
#[must_use]
pub fn default_credential_store() -> Arc<dyn CredentialStore> {
    #[cfg(target_os = "macos")]
    {
        Arc::new(KeychainStore::new(SERVICE))
    }
    #[cfg(not(target_os = "macos"))]
    {
        Arc::new(InMemoryCredentialStore::default())
    }
}

/// Dev/test-only, process-lifetime credential store. **Not** persistent
/// and **not** for production: it holds tokens in ordinary process
/// memory (wiped on drop, but never written to an OS keychain). The
/// portable build uses it so credential-consuming paths are exercisable
/// off macOS.
#[derive(Default)]
pub struct InMemoryCredentialStore {
    inner: Mutex<HashMap<String, Zeroizing<Vec<u8>>>>,
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
}

/// `errSecItemNotFound` — the Keychain's "no such credential" code.
#[cfg(target_os = "macos")]
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;

#[cfg(target_os = "macos")]
impl CredentialStore for KeychainStore {
    fn store(&self, account: &str, secret: &[u8]) -> Result<(), CredentialError> {
        security_framework::passwords::set_generic_password(&self.service, account, secret)
            .map_err(|e| CredentialError::Backend(e.to_string()))
    }

    fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, CredentialError> {
        match security_framework::passwords::get_generic_password(&self.service, account) {
            Ok(bytes) => Ok(Zeroizing::new(bytes)),
            Err(e) if e.code() == ERR_SEC_ITEM_NOT_FOUND => Err(CredentialError::NotFound),
            Err(e) => Err(CredentialError::Backend(e.to_string())),
        }
    }

    fn delete(&self, account: &str) -> Result<(), CredentialError> {
        match security_framework::passwords::delete_generic_password(&self.service, account) {
            Ok(()) => Ok(()),
            // Deleting a missing item is fine.
            Err(e) if e.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(()),
            Err(e) => Err(CredentialError::Backend(e.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_round_trips_a_token() {
        let store = InMemoryCredentialStore::default();
        assert!(matches!(store.load("acct"), Err(CredentialError::NotFound)));

        store.store("acct", b"api-token-value").unwrap();
        let loaded = store.load("acct").unwrap();
        assert_eq!(&*loaded, b"api-token-value");

        store.delete("acct").unwrap();
        assert!(matches!(store.load("acct"), Err(CredentialError::NotFound)));
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
}
