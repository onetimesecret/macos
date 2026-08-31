#![allow(unsafe_code)]
//! The real `NSPasteboard` adapter (macOS only). Meets the same
//! [`Pasteboard`] contract [`crate::MemoryPasteboard`] is tested
//! against — the hygiene rules in this file are the ones under test in
//! `super::tests`, not new ones.
//!
//! Content lives on the classic (single-item) API
//! (`declareTypes:owner:` / `setString:forType:` / `setData:forType:`):
//! the companion always writes exactly one item, and this is what
//! nspasteboard.org-aware clipboard managers scan for the hygiene
//! marker types. Images ride on `NSPasteboardTypePNG`; deeper image
//! format support is open question #6 in doc 06.

use objc2::rc::Retained;
use objc2_app_kit::{
    NSPasteboard, NSPasteboardNameDrag, NSPasteboardType, NSPasteboardTypePNG,
    NSPasteboardTypeString, NSPasteboardTypeURL,
};
use objc2_foundation::{NSArray, NSData, NSString};
use zeroize::Zeroizing;

use crate::{
    CONCEALED_TYPE, ChangeCount, ContentKind, Pasteboard, PasteboardContent, PasteboardItem,
    TRANSIENT_TYPE, WriteOptions,
};

/// `Pasteboard` over a real `NSPasteboard`. [`SystemPasteboard::new`]
/// binds the system clipboard; tests bind an isolated, uniquely-named
/// pasteboard so they never touch the developer's real clipboard and
/// never race each other.
#[derive(Debug)]
pub struct SystemPasteboard {
    pasteboard: Retained<NSPasteboard>,
}

impl Default for SystemPasteboard {
    fn default() -> Self {
        Self::new()
    }
}

impl SystemPasteboard {
    /// Binds `NSPasteboard.generalPasteboard` — the real system clipboard.
    #[must_use]
    pub fn new() -> Self {
        Self {
            pasteboard: NSPasteboard::generalPasteboard(),
        }
    }

    /// Binds the drag pasteboard (`NSPasteboardNameDrag`) — the board an
    /// in-flight drag session's content rides on. Drop-to-seal reads it
    /// core-side, so dropped bytes never transit the shell (the drag
    /// boundary decision, docs/qa/hardware-verification.md).
    #[must_use]
    pub fn drag() -> Self {
        Self {
            // SAFETY: reading a static extern pasteboard-name constant.
            pasteboard: NSPasteboard::pasteboardWithName(unsafe { NSPasteboardNameDrag }),
        }
    }

    /// An isolated, uniquely-named pasteboard — not the system clipboard.
    /// For tests only, so they don't clobber the developer's clipboard or
    /// race each other over shared global state.
    #[cfg(test)]
    fn for_testing() -> Self {
        Self {
            pasteboard: NSPasteboard::pasteboardWithUniqueName(),
        }
    }

    fn types_present(&self) -> Vec<String> {
        self.pasteboard
            .types()
            .map(|types| types.to_vec().iter().map(ToString::to_string).collect())
            .unwrap_or_default()
    }
}

impl Pasteboard for SystemPasteboard {
    fn read(&self) -> Option<PasteboardItem> {
        let string_type: &NSPasteboardType = unsafe { NSPasteboardTypeString };
        let png_type: &NSPasteboardType = unsafe { NSPasteboardTypePNG };
        let url_type: &NSPasteboardType = unsafe { NSPasteboardTypeURL };

        let content = if let Some(s) = self.pasteboard.stringForType(string_type) {
            PasteboardContent::Text(s.to_string())
        } else if let Some(data) = self.pasteboard.dataForType(png_type) {
            PasteboardContent::Image(data.to_vec())
        } else {
            return None;
        };

        let nspasteboard_concealed = self.types_present().iter().any(|t| t == CONCEALED_TYPE);

        // Provenance, read in the same pass as the content so the shell
        // never has a reason to touch the board itself (ADR-0007
        // Amendment 1, ADR-0013). Only the declared `public.url` flavor
        // is consulted: the HTML flavor sometimes knows its source too,
        // but there is no standard place it keeps it (Chromium uses a
        // private type of its own, WebKit writes none), so digging
        // through markup would be a parser, not a read, and the flavor
        // is deliberately left alone.
        let origin_url = self
            .pasteboard
            .stringForType(url_type)
            .map(|url| url.to_string())
            .filter(|url| !url.is_empty());

        Some(PasteboardItem {
            content,
            nspasteboard_concealed,
            origin_url,
        })
    }

    fn write(
        &mut self,
        content: Zeroizing<Vec<u8>>,
        kind: ContentKind,
        options: WriteOptions,
    ) -> ChangeCount {
        let string_type: &NSPasteboardType = unsafe { NSPasteboardTypeString };
        let png_type: &NSPasteboardType = unsafe { NSPasteboardTypePNG };
        let content_type = match kind {
            ContentKind::Text => string_type,
            ContentKind::Image => png_type,
        };

        let transient_marker = NSString::from_str(TRANSIENT_TYPE);
        let nspasteboard_concealed_marker = NSString::from_str(CONCEALED_TYPE);

        let mut declared: Vec<&NSString> = vec![content_type, &transient_marker];
        if options.nspasteboard_concealed {
            declared.push(&nspasteboard_concealed_marker);
        }
        let types_array = NSArray::from_slice(&declared);

        // SAFETY: `new_owner` is `None` — the companion never needs
        // pasteboard-owner callbacks (promised data, change notification);
        // it writes concrete bytes up front.
        let new_count = unsafe { self.pasteboard.declareTypes_owner(&types_array, None) };

        match kind {
            ContentKind::Text => {
                let text = String::from_utf8_lossy(&content);
                self.pasteboard
                    .setString_forType(&NSString::from_str(&text), string_type);
            }
            ContentKind::Image => {
                self.pasteboard
                    .setData_forType(Some(&NSData::with_bytes(&content)), png_type);
            }
        }

        // Empty data is the nspasteboard.org convention for marker-only
        // types: their presence, not their payload, is the signal.
        let marker_data = NSData::with_bytes(&[]);
        self.pasteboard
            .setData_forType(Some(&marker_data), &transient_marker);
        if options.nspasteboard_concealed {
            self.pasteboard
                .setData_forType(Some(&marker_data), &nspasteboard_concealed_marker);
        }

        ChangeCount(new_count as u64)
    }

    fn change_count(&self) -> ChangeCount {
        ChangeCount(self.pasteboard.changeCount() as u64)
    }

    fn clear_if_unchanged(&mut self, expected: ChangeCount) -> bool {
        if self.pasteboard.changeCount() as u64 != expected.0 {
            return false;
        }
        self.pasteboard.clearContents();
        true
    }

    fn holds_external_content(&self) -> bool {
        let types = self.types_present();
        if types.iter().any(|t| t == TRANSIENT_TYPE) {
            return false;
        }
        // The same two types read() can represent, answered from the
        // declared-type list alone — no content bytes cross into this
        // process for a yes/no.
        let string_type = unsafe { NSPasteboardTypeString }.to_string();
        let png_type = unsafe { NSPasteboardTypePNG }.to_string();
        types.iter().any(|t| *t == string_type || *t == png_type)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_text(
        pb: &mut SystemPasteboard,
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
        let mut pb = SystemPasteboard::for_testing();
        write_text(&mut pb, "hunter2", true);
        let item = pb.read().unwrap();
        assert!(item.nspasteboard_concealed);
        assert_eq!(item.content, PasteboardContent::Text("hunter2".into()));
        assert!(pb.types_present().iter().any(|t| t == TRANSIENT_TYPE));
    }

    #[test]
    fn read_captures_the_origin_url_when_present_and_none_otherwise() {
        use objc2_foundation::NSArray;
        let pb = SystemPasteboard::for_testing();
        // Text with a `public.url` flavor beside it, declared together,
        // as a browser leaves a copied link.
        let string_type: &NSPasteboardType = unsafe { NSPasteboardTypeString };
        let url_type: &NSPasteboardType = unsafe { NSPasteboardTypeURL };
        let types = NSArray::from_slice(&[string_type, url_type]);
        // SAFETY: no owner; concrete bytes are written up front, as in
        // `write` above.
        unsafe { pb.pasteboard.declareTypes_owner(&types, None) };
        pb.pasteboard
            .setString_forType(&NSString::from_str("quoted paragraph"), string_type);
        pb.pasteboard.setString_forType(
            &NSString::from_str("https://example.test/article?token=q"),
            url_type,
        );
        let item = pb.read().unwrap();
        assert_eq!(
            item.origin_url.as_deref(),
            Some("https://example.test/article?token=q")
        );

        // A plain write declares no URL flavor, so the read reports none.
        let mut pb = SystemPasteboard::for_testing();
        write_text(&mut pb, "no origin here", false);
        assert!(pb.read().unwrap().origin_url.is_none());
    }

    #[test]
    fn write_without_the_nspasteboard_mark_carries_only_transient() {
        let mut pb = SystemPasteboard::for_testing();
        write_text(&mut pb, "not a secret", false);
        let item = pb.read().unwrap();
        assert!(!item.nspasteboard_concealed);
        assert!(pb.types_present().iter().any(|t| t == TRANSIENT_TYPE));
    }

    #[test]
    fn clear_after_copy_only_clears_our_own_write() {
        let mut pb = SystemPasteboard::for_testing();
        let receipt = write_text(&mut pb, "secret", true);

        // Another write lands on the same (isolated) pasteboard, as if
        // the user copied something else since — never clobber it.
        write_text(&mut pb, "their stuff", false);
        assert!(!pb.clear_if_unchanged(receipt));
        assert!(pb.read().is_some());

        // Untouched since our write -> the guarded clear proceeds.
        let receipt2 = write_text(&mut pb, "secret again", true);
        assert!(pb.clear_if_unchanged(receipt2));
        assert!(pb.read().is_none());
    }

    #[test]
    fn change_count_is_monotonic() {
        let mut pb = SystemPasteboard::for_testing();
        let c1 = write_text(&mut pb, "a", false);
        let c2 = write_text(&mut pb, "b", false);
        assert!(c2.0 > c1.0);
        assert_eq!(pb.change_count(), c2);
    }

    #[test]
    fn our_own_transient_write_is_not_offered() {
        let mut pb = SystemPasteboard::for_testing();
        assert!(!pb.holds_external_content()); // empty board

        let receipt = write_text(&mut pb, "our copy-out", true);
        assert!(!pb.holds_external_content()); // transient-marked

        pb.clear_if_unchanged(receipt);
        assert!(!pb.holds_external_content()); // cleared

        // An unmarked write, as another app would leave it.
        pb.pasteboard.clearContents();
        let string_type: &NSPasteboardType = unsafe { NSPasteboardTypeString };
        pb.pasteboard
            .setString_forType(&NSString::from_str("from elsewhere"), string_type);
        assert!(pb.holds_external_content());
    }
}
