//! Pasteboard adapter: the one crate that touches `NSPasteboard`, and the
//! hygiene contract of docs/spec/05 that every implementation meets.

use zeroize::Zeroizing;

#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "macos")]
pub use macos::{SystemDragItem, SystemPasteboard};

/// The nspasteboard.org marker for secret content.
pub const CONCEALED_TYPE: &str = "org.nspasteboard.ConcealedType";

/// The nspasteboard.org marker for short-lived content.
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
    /// True when the writer marked it [`CONCEALED_TYPE`].
    pub nspasteboard_concealed: bool,
    /// The `public.url` flavor, if declared (ADR-0013). Treat as content:
    /// a URL can carry a token.
    pub origin_url: Option<String>,
}

/// How a write should be marked.
#[derive(Debug, Clone, Copy)]
pub struct WriteOptions {
    /// Mark with [`CONCEALED_TYPE`] so clipboard managers ignore it.
    pub nspasteboard_concealed: bool,
}

/// A pasteboard change-count observation, used to guard clear-after-copy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChangeCount(pub u64);

/// The adapter contract.
pub trait Pasteboard {
    /// Read the current item, if there is one we can represent.
    fn read(&self) -> Option<PasteboardItem>;

    /// Write content marked [`TRANSIENT_TYPE`], and [`CONCEALED_TYPE`] per
    /// `options`; returns the change count for a later guarded clear.
    fn write(
        &mut self,
        content: Zeroizing<Vec<u8>>,
        kind: ContentKind,
        options: WriteOptions,
    ) -> ChangeCount;

    /// The pasteboard's current change count.
    fn change_count(&self) -> ChangeCount;

    /// Clear the pasteboard iff its change count is still `expected`;
    /// true when it cleared.
    fn clear_if_unchanged(&mut self, expected: ChangeCount) -> bool;

    /// Whether the board holds text or an image that is not our own
    /// transient write, from type metadata alone (ADR-0007 Amendment 1).
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

impl ContentKind {
    /// The pasteboard type a decrypted write of this kind goes under.
    #[must_use]
    pub const fn pasteboard_type(self) -> &'static str {
        match self {
            ContentKind::Text => "public.utf8-plain-text",
            ContentKind::Image => "public.png",
        }
    }
}

/// One item of a drag in flight, which a decrypted drag's payload is written
/// into when a destination asks for it (ADR-0045 point 5, proposed).
pub trait DragItem {
    /// Whether the item's pasteboard is the general pasteboard, which a
    /// decrypted drag never writes (ADR-0012 Amendment 1).
    fn on_general_pasteboard(&self) -> bool;

    /// Write the plaintext under its kind's type; false when refused.
    fn provide(&mut self, content: &[u8], kind: ContentKind) -> bool;
}

/// A drag item in process memory, for tests and hosts without `AppKit`.
#[derive(Debug, Default)]
pub struct MemoryDragItem {
    general: bool,
    provided: Option<(Zeroizing<Vec<u8>>, ContentKind)>,
}

impl MemoryDragItem {
    /// An item on a drag pasteboard.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// An item on the general pasteboard, as a mistaken caller would pass.
    #[must_use]
    pub fn on_general() -> Self {
        Self {
            general: true,
            provided: None,
        }
    }

    /// What was provided, if anything.
    #[must_use]
    pub fn provided(&self) -> Option<(&[u8], ContentKind)> {
        self.provided
            .as_ref()
            .map(|(bytes, kind)| (bytes.as_slice(), *kind))
    }
}

impl DragItem for MemoryDragItem {
    fn on_general_pasteboard(&self) -> bool {
        self.general
    }

    fn provide(&mut self, content: &[u8], kind: ContentKind) -> bool {
        self.provided = Some((Zeroizing::new(content.to_vec()), kind));
        true
    }
}

/// In-process pasteboard with `NSPasteboard` semantics, for tests, the
/// demo and non-macOS hosts.
#[derive(Debug, Default)]
pub struct MemoryPasteboard {
    item: Option<StoredItem>,
    change_count: u64,
}

#[derive(Debug)]
struct StoredItem {
    bytes: Zeroizing<Vec<u8>>,
    kind: ContentKind,
    nspasteboard_concealed: bool,
    transient: bool,
    origin_url: Option<String>,
}

impl MemoryPasteboard {
    /// An empty pasteboard.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Place content as another app would.
    pub fn put_external(&mut self, content: PasteboardContent, nspasteboard_concealed: bool) {
        self.put_external_with_origin(content, nspasteboard_concealed, None);
    }

    /// [`MemoryPasteboard::put_external`] with a `public.url` origin.
    pub fn put_external_with_origin(
        &mut self,
        content: PasteboardContent,
        nspasteboard_concealed: bool,
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
            nspasteboard_concealed,
            transient: false,
            origin_url,
        });
    }

    /// True when the current item is marked transient.
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
            nspasteboard_concealed: item.nspasteboard_concealed,
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
            nspasteboard_concealed: options.nspasteboard_concealed,
            transient: true,
            origin_url: None,
        });
        ChangeCount(self.change_count)
    }

    fn change_count(&self) -> ChangeCount {
        ChangeCount(self.change_count)
    }

    fn clear_if_unchanged(&mut self, expected: ChangeCount) -> bool {
        if self.change_count == expected.0 {
            self.item = None;
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

    fn write_text(
        pb: &mut MemoryPasteboard,
        text: &str,
        nspasteboard_concealed: bool,
    ) -> ChangeCount {
        pb.write(
            Zeroizing::new(text.as_bytes().to_vec()),
            ContentKind::Text,
            WriteOptions {
                nspasteboard_concealed,
            },
        )
    }

    #[test]
    fn writes_are_marked_and_read_back() {
        let mut pb = MemoryPasteboard::new();
        write_text(&mut pb, "hunter2", true);
        assert!(pb.current_is_transient());
        let item = pb.read().unwrap();
        assert!(item.nspasteboard_concealed);
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

        pb.put_external(PasteboardContent::Text("plain".into()), false);
        assert!(pb.read().unwrap().origin_url.is_none());
        write_text(&mut pb, "our copy-out", true);
        assert!(pb.read().unwrap().origin_url.is_none());
    }

    #[test]
    fn inbound_nspasteboard_concealed_mark_is_reported() {
        let mut pb = MemoryPasteboard::new();
        pb.put_external(
            PasteboardContent::Text("from a password manager".into()),
            true,
        );
        assert!(pb.read().unwrap().nspasteboard_concealed);
        assert!(!pb.current_is_transient());
    }

    #[test]
    fn clear_after_copy_only_clears_our_own_write() {
        let mut pb = MemoryPasteboard::new();
        let receipt = write_text(&mut pb, "secret", true);

        pb.put_external(PasteboardContent::Text("their stuff".into()), false);
        assert!(!pb.clear_if_unchanged(receipt));
        assert!(pb.read().is_some());

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
    fn a_memory_drag_item_keeps_what_it_was_given_and_says_where_it_sits() {
        let mut item = MemoryDragItem::new();
        assert!(!item.on_general_pasteboard());
        assert!(item.provided().is_none());
        assert!(item.provide(b"hunter2", ContentKind::Text));
        assert_eq!(item.provided(), Some((&b"hunter2"[..], ContentKind::Text)));
        assert!(MemoryDragItem::on_general().on_general_pasteboard());
    }

    #[test]
    fn external_content_is_offered_and_our_own_write_is_not() {
        let mut pb = MemoryPasteboard::new();
        assert!(!pb.holds_external_content());

        pb.put_external(PasteboardContent::Text("from elsewhere".into()), false);
        assert!(pb.holds_external_content());

        let receipt = write_text(&mut pb, "our copy-out", true);
        assert!(!pb.holds_external_content());

        pb.clear_if_unchanged(receipt);
        assert!(!pb.holds_external_content());
    }
}
