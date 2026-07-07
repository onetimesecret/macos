//! The [`Cache`] façade — the whole core behind one small, FFI-shaped API.
//!
//! This is what `ots-ffi` wraps. Every method takes or returns handles, non-
//! secret summaries, or action outputs — never a plaintext secret. The core
//! reads the pasteboard itself and owns the bytes from the first one (docs/01
//! §3).

use std::sync::Arc;

use zeroize::Zeroizing;

use crate::api::{ConcealClient, ConcealError, ConcealOpts, Credentials, ShareLink};
use crate::cell::{CellId, CellKind, CellSummary, TtlRung};
use crate::clock::Clock;
use crate::keychain::CredentialStore;
use crate::pasteboard::{Ingest, Pasteboard};
use crate::secret::SecretBuffer;
use crate::store::CellStore;

/// Non-secret configuration for the share bridge. The token is *not* here — it
/// lives in the credential store, keyed by `extid`.
#[derive(Clone, Debug)]
pub struct ApiConfig {
    /// API base URL, e.g. `https://onetimesecret.com`.
    pub base_url: String,
    /// The customer's external id — the Basic-auth username (docs/00 §12).
    pub extid: String,
}

/// Errors from ingesting content.
#[derive(Debug, thiserror::Error)]
pub enum IngestError {
    #[error("nothing to ingest: the source was empty")]
    Empty,
}

/// The core, assembled: a bounded store, an ingest source, a credential store,
/// and optional API configuration for the share bridge.
pub struct Cache {
    store: CellStore,
    pasteboard: Box<dyn Pasteboard>,
    creds: Arc<dyn CredentialStore>,
    api: Option<ApiConfig>,
}

impl Cache {
    /// Assemble a cache from its parts.
    #[must_use]
    pub fn new(
        clock: Arc<dyn Clock>,
        pasteboard: Box<dyn Pasteboard>,
        creds: Arc<dyn CredentialStore>,
    ) -> Self {
        Self {
            store: CellStore::with_clock(clock),
            pasteboard,
            creds,
            api: None,
        }
    }

    /// Set (or replace) the share-bridge configuration.
    pub fn set_api(&mut self, api: ApiConfig) {
        self.api = Some(api);
    }

    /// Read the ingest source into a new cell at the default TTL, returning its
    /// id. The bytes move straight into a locked [`SecretBuffer`]; no plaintext
    /// copy escapes the core.
    pub fn ingest_from_pasteboard(&mut self) -> Result<CellId, IngestError> {
        match self.pasteboard.read() {
            Ingest::Text(bytes) => {
                Ok(self
                    .store
                    .insert(SecretBuffer::new(bytes), CellKind::Text, TtlRung::DEFAULT))
            }
            Ingest::Image(bytes) => {
                Ok(self
                    .store
                    .insert(SecretBuffer::new(bytes), CellKind::Image, TtlRung::DEFAULT))
            }
            Ingest::Empty => Err(IngestError::Empty),
        }
    }

    /// Non-secret snapshot of all live cells, newest first.
    pub fn list(&mut self) -> Vec<CellSummary> {
        self.store.list()
    }

    /// Reset a cell to an explicit rung. Returns whether the cell existed.
    pub fn reset_ttl(&mut self, id: CellId, rung: TtlRung) -> bool {
        self.store.reset_ttl(id, rung)
    }

    /// Step a cell up the TTL ladder, returning the new rung.
    pub fn cycle_ttl(&mut self, id: CellId) -> Option<TtlRung> {
        self.store.cycle_ttl(id)
    }

    /// Evict a cell now, wiping its secret.
    pub fn evict(&mut self, id: CellId) -> bool {
        self.store.evict(id)
    }

    /// Remove all expired cells, returning their ids.
    pub fn sweep_expired(&mut self) -> Vec<CellId> {
        self.store.sweep_expired()
    }

    /// Number of live cells.
    pub fn len(&mut self) -> usize {
        self.store.len()
    }

    /// Whether the cache holds no live cells.
    pub fn is_empty(&mut self) -> bool {
        self.store.is_empty()
    }

    /// Drop every cell, wiping all secrets (the safe default on quit).
    pub fn clear(&mut self) {
        self.store.clear();
    }

    /// Promote a text cell to a one-time Onetime Secret link.
    ///
    /// The plaintext is read from the cell's [`SecretBuffer`] and used to build
    /// the request wholly in-core; the returned [`ShareLink`] carries only
    /// outputs. Does not mutate the cell — its local TTL is a separate clock
    /// from the link's server-side lifespan (docs/00 §6.3).
    pub fn conceal(&self, id: CellId, opts: ConcealOpts) -> Result<ShareLink, ConcealError> {
        let cell = self.store.get(id).ok_or(ConcealError::UnknownCell)?;
        if cell.kind() != CellKind::Text {
            return Err(ConcealError::NotText);
        }

        let api = self.api.as_ref().ok_or(ConcealError::MissingConfig)?;

        let token_bytes = self
            .creds
            .load(&api.extid)
            .map_err(|_| ConcealError::MissingCredentials)?;
        let token_str =
            std::str::from_utf8(&token_bytes).map_err(|_| ConcealError::MissingCredentials)?;
        let creds = Credentials {
            extid: api.extid.clone(),
            token: Zeroizing::new(token_str.to_owned()),
        };

        let text =
            std::str::from_utf8(cell.secret().expose()).map_err(|_| ConcealError::NotText)?;

        let client = ConcealClient::new(api.base_url.clone());
        client.conceal(text, &opts, &creds)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;
    use crate::keychain::InMemoryCredentialStore;
    use crate::pasteboard::StaticPasteboard;

    fn cache_with_text(text: &str) -> Cache {
        let clock = Arc::new(ManualClock::new(0));
        let pb = Box::new(StaticPasteboard::with_text(text));
        let creds = Arc::new(InMemoryCredentialStore::default());
        Cache::new(clock, pb, creds)
    }

    #[test]
    fn ingest_then_list_yields_a_redacted_summary() {
        let mut cache = cache_with_text("sk-live_abcdef0123456789abcdef");
        let id = cache.ingest_from_pasteboard().unwrap();
        let list = cache.list();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, id);
        assert_eq!(list[0].kind, CellKind::Text);
        assert_eq!(
            list[0].preview, "sk-liv…",
            "preview is redacted, not the secret"
        );
        assert_eq!(list[0].rung, TtlRung::DEFAULT);
    }

    #[test]
    fn ingest_empty_pasteboard_errors() {
        let clock = Arc::new(ManualClock::new(0));
        let pb = Box::new(StaticPasteboard::empty());
        let creds = Arc::new(InMemoryCredentialStore::default());
        let mut cache = Cache::new(clock, pb, creds);
        assert!(matches!(
            cache.ingest_from_pasteboard(),
            Err(IngestError::Empty)
        ));
    }

    #[test]
    fn ttl_lifecycle_through_the_facade() {
        let mut cache = cache_with_text("value");
        let id = cache.ingest_from_pasteboard().unwrap();
        assert!(cache.reset_ttl(id, TtlRung::OneHour));
        assert_eq!(cache.cycle_ttl(id), Some(TtlRung::ThreeHours));
        assert!(cache.evict(id));
        assert!(cache.is_empty());
    }

    #[test]
    fn conceal_needs_api_config() {
        let cache = cache_with_text_ingested("value");
        let err = cache
            .cache
            .conceal(cache.id, ConcealOpts::new(3600))
            .unwrap_err();
        assert!(matches!(err, ConcealError::MissingConfig));
    }

    #[test]
    fn conceal_needs_credentials() {
        let mut cache = cache_with_text("value");
        let id = cache.ingest_from_pasteboard().unwrap();
        cache.set_api(ApiConfig {
            base_url: "https://example.com".to_string(),
            extid: "cust_1".to_string(),
        });
        let err = cache.conceal(id, ConcealOpts::new(3600)).unwrap_err();
        assert!(matches!(err, ConcealError::MissingCredentials));
    }

    #[test]
    fn conceal_rejects_unknown_cell() {
        let cache = cache_with_text("value");
        let err = cache
            .conceal(CellId(999), ConcealOpts::new(3600))
            .unwrap_err();
        assert!(matches!(err, ConcealError::UnknownCell));
    }

    // Small helper bundling a cache with one ingested cell and its id.
    struct Ingested {
        cache: Cache,
        id: CellId,
    }
    fn cache_with_text_ingested(text: &str) -> Ingested {
        let mut cache = cache_with_text(text);
        let id = cache.ingest_from_pasteboard().unwrap();
        Ingested { cache, id }
    }
}
