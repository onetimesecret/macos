//! The ingest source.
//!
//! The core reads content **itself**, so plaintext never originates in the UI
//! layer: Swift asks the core to "take what's on the pasteboard into a new
//! cell" and gets back a [`CellId`](crate::cell::CellId) — it never touches the
//! bytes (docs/01 §3).
//!
//! On macOS this trait is backed by `NSPasteboard`; that reader is part of the
//! vertical-slice spike on real hardware (docs/01 §10 step 7) and is not built
//! here. Everywhere else — and in every test — an injected [`StaticPasteboard`]
//! stands in so the ingest → store → conceal pipeline is fully exercisable.

use std::sync::Mutex;

use crate::cell::CellKind;

/// A snapshot of what the ingest source currently holds.
pub enum Ingest {
    /// UTF-8 (or otherwise textual) content.
    Text(Vec<u8>),
    /// Raw image bytes (e.g. PNG/TIFF from a screenshot).
    Image(Vec<u8>),
    /// Nothing to ingest.
    Empty,
}

impl Ingest {
    /// The cell kind this ingest maps to, if any.
    #[must_use]
    pub fn kind(&self) -> Option<CellKind> {
        match self {
            Ingest::Text(_) => Some(CellKind::Text),
            Ingest::Image(_) => Some(CellKind::Image),
            Ingest::Empty => None,
        }
    }
}

/// A source the core can read content from. Must be thread-safe.
pub trait Pasteboard: Send + Sync {
    /// Read the current content. Called by the core, never by the UI.
    fn read(&self) -> Ingest;
}

/// A test/dev pasteboard holding injected content. Reading it consumes the
/// content and leaves it [`Ingest::Empty`], mirroring a one-shot ingest.
pub struct StaticPasteboard {
    content: Mutex<Ingest>,
}

impl StaticPasteboard {
    /// A pasteboard preloaded with `content`.
    #[must_use]
    pub fn new(content: Ingest) -> Self {
        Self {
            content: Mutex::new(content),
        }
    }

    /// An empty pasteboard.
    #[must_use]
    pub fn empty() -> Self {
        Self::new(Ingest::Empty)
    }

    /// Preload textual content (dev/test convenience).
    #[must_use]
    pub fn with_text(text: &str) -> Self {
        Self::new(Ingest::Text(text.as_bytes().to_vec()))
    }

    /// Replace the pasteboard's content (dev/test convenience).
    pub fn set(&self, content: Ingest) {
        if let Ok(mut guard) = self.content.lock() {
            *guard = content;
        }
    }
}

impl Default for StaticPasteboard {
    fn default() -> Self {
        Self::empty()
    }
}

impl Pasteboard for StaticPasteboard {
    fn read(&self) -> Ingest {
        match self.content.lock() {
            Ok(mut guard) => std::mem::replace(&mut *guard, Ingest::Empty),
            Err(_) => Ingest::Empty,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn static_pasteboard_reads_then_empties() {
        let pb = StaticPasteboard::with_text("hello");
        match pb.read() {
            Ingest::Text(b) => assert_eq!(b, b"hello"),
            _ => panic!("expected text"),
        }
        assert!(
            matches!(pb.read(), Ingest::Empty),
            "consumed after first read"
        );
    }

    #[test]
    fn ingest_kind_mapping() {
        assert_eq!(Ingest::Text(vec![]).kind(), Some(CellKind::Text));
        assert_eq!(Ingest::Image(vec![]).kind(), Some(CellKind::Image));
        assert_eq!(Ingest::Empty.kind(), None);
    }
}
