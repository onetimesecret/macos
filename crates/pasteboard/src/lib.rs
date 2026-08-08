//! Pasteboard adapter: the one crate that touches `NSPasteboard`.
//!
//! What lives here is the *contract* every implementation meets — the
//! hygiene rules from docs/spec/05 — plus two implementations:
//! [`MemoryPasteboard`] (tests, the demo, any non-macOS development
//! host) and [`SystemPasteboard`] (the real `NSPasteboard`, macOS-gated;
//! nothing else in the workspace may grow a platform dependency).
//!
//! Hygiene contract:
//!
//! - **Outbound copies are marked.** Every write carries
//!   [`CONCEALED_TYPE`] when the content is secret-shaped, and
//!   [`TRANSIENT_TYPE`] always — well-behaved clipboard managers skip
//!   both.
//! - **Inbound `ConcealedType` is respected**: reads report the flag so
//!   the cell arrives masked.
//! - **Clear-after-copy is change-count-guarded.** The clipboard is
//!   cleared N seconds after a copy-out *only if it still holds our
//!   write* — never clobbering something the user copied since.

use zeroize::Zeroizing;

#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "macos")]
pub use macos::SystemPasteboard;

/// The nspasteboard.org convention marking secret content; clipboard
/// managers that honour it (most do) will not record the item.
pub const CONCEALED_TYPE: &str = "org.nspasteboard.ConcealedType";

/// The nspasteboard.org convention marking short-lived content not worth
/// recording.
pub const TRANSIENT_TYPE: &str = "org.nspasteboard.TransientType";

/// Content moving through the pasteboard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PasteboardContent {
    /// Plain text (RTF flattens to this on the way in).
    Text(String),
    /// Encoded image bytes as the pasteboard delivered them.
    Image(Vec<u8>),
}

/// A read result: content plus the marks that arrived with it.
#[derive(Debug)]
pub struct PasteboardItem {
    /// The content.
    pub content: PasteboardContent,
    /// True when the writer marked it `org.nspasteboard.ConcealedType` —
    /// the cell must arrive masked.
    pub concealed: bool,
    /// Where the content came from, when the writer said so: the
    /// `public.url` flavor, read in the same pass as the content
    /// (ADR-0013). Treated as content by everything downstream — a URL
    /// can carry a token — so it may reach only the sealed document,
    /// never a ledger, a summary, or any JSON surface.
    pub origin_url: Option<String>,
}

/// How a write should be marked.
#[derive(Debug, Clone, Copy)]
pub struct WriteOptions {
    /// Mark with [`CONCEALED_TYPE`] so clipboard managers ignore it.
    pub concealed: bool,
}

/// A pasteboard change-count observation, used to guard clear-after-copy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChangeCount(pub u64);

/// The adapter contract. One implementation per platform; the core and
/// shell speak only this trait.
pub trait Pasteboard {
    /// Read the current item, if there is one we can represent.
    fn read(&self) -> Option<PasteboardItem>;

    /// Write content (always marked [`TRANSIENT_TYPE`]; additionally
    /// [`CONCEALED_TYPE`] per `options`). Returns the change count of
    /// the write, for a later guarded clear. The buffer is zeroizing:
    /// implementations consume it and let it scrub.
    fn write(
        &mut self,
        content: Zeroizing<Vec<u8>>,
        kind: ContentKind,
        options: WriteOptions,
    ) -> ChangeCount;

    /// The pasteboard's current change count.
    fn change_count(&self) -> ChangeCount;

    /// Clear the pasteboard **iff** it still holds the write identified
    /// by `expected` — the clear-after-copy guard. Returns true when a
    /// clear happened.
    fn clear_if_unchanged(&mut self, expected: ChangeCount) -> bool;

    /// Whether the board holds content a sealed paste could take:
    /// something representable (text or image) that is not the
    /// companion's own transient write. Implementations answer from
    /// type metadata alone — the content bytes are never copied into
    /// this process just to say yes or no. Powers the summon-time
    /// offer (ADR-0007 Amendment 1).
    fn holds_external_content(&self) -> bool;
}

/// What kind of bytes a write holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContentKind {
    /// UTF-8 text.
    Text,
    /// Encoded image bytes.
    Image,
}

/// In-process pasteboard: test double, demo prop, and development stand-in
/// on non-macOS hosts. Mirrors `NSPasteboard` semantics (single owner,
/// monotonically increasing change count).
#[derive(Debug, Default)]
pub struct MemoryPasteboard {
    item: Option<StoredItem>,
    change_count: u64,
}

#[derive(Debug)]
struct StoredItem {
    bytes: Zeroizing<Vec<u8>>,
    kind: ContentKind,
    concealed: bool,
    transient: bool,
    origin_url: Option<String>,
}

impl MemoryPasteboard {
    /// An empty pasteboard.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Place external (non-companion) content, as another app would —
    /// for exercising reads in tests and the demo.
    pub fn put_external(&mut self, content: PasteboardContent, concealed: bool) {
        self.put_external_with_origin(content, concealed, None);
    }

    /// [`MemoryPasteboard::put_external`] with a `public.url` origin
    /// riding beside the content, as a browser copy would carry one.
    pub fn put_external_with_origin(
        &mut self,
        content: PasteboardContent,
        concealed: bool,
        origin_url: Option<String>,
    ) {
        self.change_count += 1;
        let (bytes, kind) = match content {
            PasteboardContent::Text(s) => (s.into_bytes(), ContentKind::Text),
            PasteboardContent::Image(b) => (b, ContentKind::Image),
        };
        self.item = Some(StoredItem {
            bytes: Zeroizing::new(bytes),
            kind,
            concealed,
            transient: false,
            origin_url,
        });
    }

    /// True when the current item is marked transient (companion writes
    /// always are).
    #[must_use]
    pub fn current_is_transient(&self) -> bool {
        self.item.as_ref().is_some_and(|i| i.transient)
    }
}

impl Pasteboard for MemoryPasteboard {
    fn read(&self) -> Option<PasteboardItem> {
        self.item.as_ref().map(|item| PasteboardItem {
            content: match item.kind {
                ContentKind::Text => {
                    PasteboardContent::Text(String::from_utf8_lossy(&item.bytes).into_owned())
                }
                ContentKind::Image => PasteboardContent::Image(item.bytes.to_vec()),
            },
            concealed: item.concealed,
            origin_url: item.origin_url.clone(),
        })
    }

    fn write(
        &mut self,
        content: Zeroizing<Vec<u8>>,
        kind: ContentKind,
        options: WriteOptions,
    ) -> ChangeCount {
        self.change_count += 1;
        self.item = Some(StoredItem {
            bytes: content,
            kind,
            concealed: options.concealed,
            transient: true,
            // The companion's own writes carry no origin: provenance
            // belongs to content arriving, not content leaving.
            origin_url: None,
        });
        ChangeCount(self.change_count)
    }

    fn change_count(&self) -> ChangeCount {
        ChangeCount(self.change_count)
    }

    fn clear_if_unchanged(&mut self, expected: ChangeCount) -> bool {
        if self.change_count == expected.0 {
            self.item = None; // buffer zeroizes on drop
            self.change_count += 1;
            true
        } else {
            false
        }
    }

    fn holds_external_content(&self) -> bool {
        self.item.as_ref().is_some_and(|item| !item.transient)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_text(pb: &mut MemoryPasteboard, text: &str, concealed: bool) -> ChangeCount {
        pb.write(
            Zeroizing::new(text.as_bytes().to_vec()),
            ContentKind::Text,
            WriteOptions { concealed },
        )
    }

    #[test]
    fn writes_are_marked_and_read_back() {
        let mut pb = MemoryPasteboard::new();
        write_text(&mut pb, "hunter2", true);
        assert!(pb.current_is_transient());
        let item = pb.read().unwrap();
        assert!(item.concealed);
        assert_eq!(item.content, PasteboardContent::Text("hunter2".into()));
    }

    #[test]
    fn read_captures_the_origin_url_when_present_and_none_otherwise() {
        let mut pb = MemoryPasteboard::new();
        pb.put_external_with_origin(
            PasteboardContent::Text("quoted paragraph".into()),
            false,
            Some("https://example.test/article?token=q".into()),
        );
        assert_eq!(
            pb.read().unwrap().origin_url.as_deref(),
            Some("https://example.test/article?token=q")
        );

        // Content without a declared origin reads back with none, and
        // the companion's own write never invents one.
        pb.put_external(PasteboardContent::Text("plain".into()), false);
        assert!(pb.read().unwrap().origin_url.is_none());
        write_text(&mut pb, "our copy-out", true);
        assert!(pb.read().unwrap().origin_url.is_none());
    }

    #[test]
    fn inbound_concealed_mark_is_reported() {
        let mut pb = MemoryPasteboard::new();
        pb.put_external(
            PasteboardContent::Text("from a password manager".into()),
            true,
        );
        assert!(pb.read().unwrap().concealed);
        assert!(!pb.current_is_transient());
    }

    #[test]
    fn clear_after_copy_only_clears_our_own_write() {
        let mut pb = MemoryPasteboard::new();
        let receipt = write_text(&mut pb, "secret", true);

        // The user copied something else since — never clobber it.
        pb.put_external(PasteboardContent::Text("their stuff".into()), false);
        assert!(!pb.clear_if_unchanged(receipt));
        assert!(pb.read().is_some());

        // Untouched since our write → the guarded clear proceeds.
        let receipt2 = write_text(&mut pb, "secret again", true);
        assert!(pb.clear_if_unchanged(receipt2));
        assert!(pb.read().is_none());
    }

    #[test]
    fn change_count_is_monotonic() {
        let mut pb = MemoryPasteboard::new();
        let c1 = write_text(&mut pb, "a", false);
        let c2 = write_text(&mut pb, "b", false);
        assert!(c2.0 > c1.0);
        assert_eq!(pb.change_count(), c2);
    }

    #[test]
    fn external_content_is_offered_and_our_own_write_is_not() {
        let mut pb = MemoryPasteboard::new();
        assert!(!pb.holds_external_content()); // empty

        pb.put_external(PasteboardContent::Text("from elsewhere".into()), false);
        assert!(pb.holds_external_content());

        // Our own copy-out is transient-marked: offering to ingest it
        // back would be a loop, not a service.
        let receipt = write_text(&mut pb, "our copy-out", true);
        assert!(!pb.holds_external_content());

        pb.clear_if_unchanged(receipt);
        assert!(!pb.holds_external_content()); // cleared
    }
}
