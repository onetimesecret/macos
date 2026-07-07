//! Credential storage.
//!
//! The Onetime Secret **API token** (the password half of Basic auth) is a
//! secret and must live in the OS keychain, never in plaintext config
//! (docs/00 §10, §12). This module defines a portable [`CredentialStore`]
//! trait with two implementations:
//!
//! - [`KeychainStore`] — macOS Keychain via `security-framework` (`cfg`-gated).
//! - [`InMemoryCredentialStore`] — a **dev/test-only**, non-persistent fallback
//!   so the portable core builds and is testable off macOS (docs/01 D4).
//!
//! Loaded secrets come back wrapped in [`Zeroizing`] so they wipe on drop.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;

use zeroize::Zeroizing;

/// Keychain service name that scopes all of this app's credential items.
pub const SERVICE: &str = "com.onetimesecret.otscache";

/// Errors from a credential store. Messages never embed secret material.
#[derive(Debug, thiserror::Error)]
pub enum KeychainError {
    #[error("credential not found")]
    NotFound,
    #[error("keychain backend error: {0}")]
    Backend(String),
}

/// A place to keep credentials at rest. Implementations must be thread-safe.
pub trait CredentialStore: Send + Sync {
    /// Store (or replace) the secret for `account`.
    fn store(&self, account: &str, secret: &[u8]) -> Result<(), KeychainError>;
    /// Load the secret for `account`, or [`KeychainError::NotFound`].
    fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, KeychainError>;
    /// Delete the secret for `account`. Deleting a missing item is not an error.
    fn delete(&self, account: &str) -> Result<(), KeychainError>;
}

/// The platform default credential store: the macOS Keychain where available,
/// the in-memory dev fallback elsewhere.
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

/// Dev/test-only, process-lifetime credential store. **Not** persistent and
/// **not** for production: it holds tokens in ordinary process memory (wiped on
/// drop, but never written to an OS keychain). The portable build uses it so
/// the conceal path is exercisable off macOS.
#[derive(Default)]
pub struct InMemoryCredentialStore {
    inner: Mutex<HashMap<String, Zeroizing<Vec<u8>>>>,
}

impl CredentialStore for InMemoryCredentialStore {
    fn store(&self, account: &str, secret: &[u8]) -> Result<(), KeychainError> {
        let mut map = self.inner.lock().map_err(|_| poisoned())?;
        map.insert(account.to_string(), Zeroizing::new(secret.to_vec()));
        Ok(())
    }

    fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, KeychainError> {
        let map = self.inner.lock().map_err(|_| poisoned())?;
        map.get(account)
            .map(|v| Zeroizing::new(v.to_vec()))
            .ok_or(KeychainError::NotFound)
    }

    fn delete(&self, account: &str) -> Result<(), KeychainError> {
        let mut map = self.inner.lock().map_err(|_| poisoned())?;
        map.remove(account);
        Ok(())
    }
}

fn poisoned() -> KeychainError {
    KeychainError::Backend("credential store lock poisoned".to_string())
}

/// macOS Keychain-backed credential store (generic password items scoped to
/// [`SERVICE`]). Compiled only on macOS; validated in macOS CI.
#[cfg(target_os = "macos")]
pub struct KeychainStore {
    service: String,
}

#[cfg(target_os = "macos")]
impl KeychainStore {
    #[must_use]
    pub fn new(service: &str) -> Self {
        Self {
            service: service.to_string(),
        }
    }
}

#[cfg(target_os = "macos")]
impl CredentialStore for KeychainStore {
    fn store(&self, account: &str, secret: &[u8]) -> Result<(), KeychainError> {
        security_framework::passwords::set_generic_password(&self.service, account, secret)
            .map_err(|e| KeychainError::Backend(e.to_string()))
    }

    fn load(&self, account: &str) -> Result<Zeroizing<Vec<u8>>, KeychainError> {
        match security_framework::passwords::get_generic_password(&self.service, account) {
            Ok(bytes) => Ok(Zeroizing::new(bytes)),
            Err(e) => {
                // errSecItemNotFound (-25300) is the "no such credential" case.
                if e.code() == -25300 {
                    Err(KeychainError::NotFound)
                } else {
                    Err(KeychainError::Backend(e.to_string()))
                }
            }
        }
    }

    fn delete(&self, account: &str) -> Result<(), KeychainError> {
        match security_framework::passwords::delete_generic_password(&self.service, account) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == -25300 => Ok(()), // deleting a missing item is fine
            Err(e) => Err(KeychainError::Backend(e.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_round_trips_a_token() {
        let store = InMemoryCredentialStore::default();
        assert!(matches!(store.load("acct"), Err(KeychainError::NotFound)));

        store.store("acct", b"api-token-value").unwrap();
        let loaded = store.load("acct").unwrap();
        assert_eq!(&*loaded, b"api-token-value");

        store.delete("acct").unwrap();
        assert!(matches!(store.load("acct"), Err(KeychainError::NotFound)));
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
}
