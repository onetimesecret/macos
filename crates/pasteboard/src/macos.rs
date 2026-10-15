#![allow(unsafe_code)]
//! The real `NSPasteboard` adapter (macOS only), on the classic
//! single-item API that nspasteboard.org-aware managers scan.

use std::ffi::c_void;
use std::ptr::NonNull;

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_app_kit::{
    NSPasteboard, NSPasteboardItem, NSPasteboardName, NSPasteboardNameDrag,
    NSPasteboardNameGeneral, NSPasteboardType, NSPasteboardTypePNG, NSPasteboardTypeString,
    NSPasteboardTypeURL,
};
use objc2_foundation::{NSArray, NSData, NSString};
use zeroize::Zeroizing;

use crate::{
    CONCEALED_TYPE, ChangeCount, ContentKind, DragItem, Pasteboard, PasteboardContent,
    PasteboardItem, TRANSIENT_TYPE, WriteOptions,
};

/// `Pasteboard` over a real `NSPasteboard`.
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
    /// Binds the system clipboard.
    #[must_use]
    pub fn new() -> Self {
        Self {
            pasteboard: NSPasteboard::generalPasteboard(),
        }
    }

    /// Binds the drag pasteboard, so dropped bytes are read core-side.
    #[must_use]
    pub fn drag() -> Self {
        Self {
            // SAFETY: reading a static extern pasteboard-name constant.
            pasteboard: NSPasteboard::pasteboardWithName(unsafe { NSPasteboardNameDrag }),
        }
    }

    /// An isolated, uniquely-named pasteboard for tests.
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

        // Only `public.url`: HTML has no standard place for its source
        // (ADR-0013).
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
        let transient_marker = NSString::from_str(TRANSIENT_TYPE);
        let nspasteboard_concealed_marker = NSString::from_str(CONCEALED_TYPE);

        let mut declared: Vec<&NSString> = vec![content_type(kind), &transient_marker];
        if options.nspasteboard_concealed {
            declared.push(&nspasteboard_concealed_marker);
        }
        let types_array = NSArray::from_slice(&declared);

        // SAFETY: no owner; concrete bytes are written up front, so no
        // owner callbacks are needed.
        let new_count = unsafe { self.pasteboard.declareTypes_owner(&types_array, None) };

        write_content(&*self.pasteboard, &content, kind);

        // nspasteboard.org markers carry empty data.
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
        let string_type = unsafe { NSPasteboardTypeString }.to_string();
        let png_type = unsafe { NSPasteboardTypePNG }.to_string();
        types.iter().any(|t| *t == string_type || *t == png_type)
    }
}

/// Where a plaintext is written: a whole pasteboard, or one of its items.
trait ContentTarget {
    fn set_string(&self, string: &NSString, kind: &NSPasteboardType) -> bool;
    fn set_data(&self, data: &NSData, kind: &NSPasteboardType) -> bool;
}

impl ContentTarget for NSPasteboard {
    fn set_string(&self, string: &NSString, kind: &NSPasteboardType) -> bool {
        self.setString_forType(string, kind)
    }

    fn set_data(&self, data: &NSData, kind: &NSPasteboardType) -> bool {
        self.setData_forType(Some(data), kind)
    }
}

impl ContentTarget for NSPasteboardItem {
    fn set_string(&self, string: &NSString, kind: &NSPasteboardType) -> bool {
        self.setString_forType(string, kind)
    }

    fn set_data(&self, data: &NSData, kind: &NSPasteboardType) -> bool {
        self.setData_forType(data, kind)
    }
}

/// The pasteboard and item `AppKit` hands a drag's data provider, borrowed
/// for one provide call (ADR-0045 point 5, proposed).
#[derive(Debug)]
pub struct SystemDragItem<'a> {
    pasteboard: &'a NSPasteboard,
    item: &'a NSPasteboardItem,
}

impl<'a> SystemDragItem<'a> {
    /// Borrow them from raw pointers; `None` for a null pointer or an object
    /// of any other class.
    ///
    /// # Safety
    /// Each non-null pointer must be a live Objective-C object for `'a`.
    #[must_use]
    pub unsafe fn from_raw(pasteboard: *mut c_void, item: *mut c_void) -> Option<Self> {
        let pasteboard = NonNull::new(pasteboard.cast::<AnyObject>())?;
        let item = NonNull::new(item.cast::<AnyObject>())?;
        // SAFETY: the caller vouches both are live objects for `'a`.
        let (pasteboard, item) = unsafe { (pasteboard.as_ref(), item.as_ref()) };
        Some(Self {
            pasteboard: pasteboard.downcast_ref::<NSPasteboard>()?,
            item: item.downcast_ref::<NSPasteboardItem>()?,
        })
    }
}

impl DragItem for SystemDragItem<'_> {
    fn on_general_pasteboard(&self) -> bool {
        // SAFETY: reading a static extern pasteboard-name constant.
        let general: &NSPasteboardName = unsafe { NSPasteboardNameGeneral };
        self.pasteboard.name().isEqualToString(general)
    }

    fn provide(&mut self, content: &[u8], kind: ContentKind) -> bool {
        write_content(self.item, content, kind)
    }
}

/// The pasteboard type a kind of plaintext is written under.
fn content_type(kind: ContentKind) -> &'static NSPasteboardType {
    // SAFETY: reading static extern pasteboard-type constants.
    unsafe {
        match kind {
            ContentKind::Text => NSPasteboardTypeString,
            ContentKind::Image => NSPasteboardTypePNG,
        }
    }
}

/// The one content write every decrypted egress shares: text as a string,
/// an image as PNG data. Returns whether the target took it.
fn write_content(target: &impl ContentTarget, content: &[u8], kind: ContentKind) -> bool {
    match kind {
        ContentKind::Text => {
            let text = String::from_utf8_lossy(content);
            target.set_string(&NSString::from_str(&text), content_type(kind))
        }
        ContentKind::Image => target.set_data(&NSData::with_bytes(content), content_type(kind)),
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
        let string_type: &NSPasteboardType = unsafe { NSPasteboardTypeString };
        let url_type: &NSPasteboardType = unsafe { NSPasteboardTypeURL };
        let types = NSArray::from_slice(&[string_type, url_type]);
        // SAFETY: no owner; concrete bytes are written up front.
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

        write_text(&mut pb, "their stuff", false);
        assert!(!pb.clear_if_unchanged(receipt));
        assert!(pb.read().is_some());

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
        assert!(!pb.holds_external_content());

        let receipt = write_text(&mut pb, "our copy-out", true);
        assert!(!pb.holds_external_content());

        pb.clear_if_unchanged(receipt);
        assert!(!pb.holds_external_content());

        pb.pasteboard.clearContents();
        let string_type: &NSPasteboardType = unsafe { NSPasteboardTypeString };
        pb.pasteboard
            .setString_forType(&NSString::from_str("from elsewhere"), string_type);
        assert!(pb.holds_external_content());
    }

    fn raw<T>(object: &T) -> *mut c_void {
        std::ptr::from_ref(object).cast_mut().cast()
    }

    #[test]
    fn a_drag_item_takes_the_plaintext_under_its_kinds_type() {
        let board = SystemPasteboard::for_testing();
        let item = NSPasteboardItem::new();
        // SAFETY: both objects live to the end of the test.
        let mut drag = unsafe { SystemDragItem::from_raw(raw(&*board.pasteboard), raw(&*item)) }
            .expect("a pasteboard and an item");
        assert!(!drag.on_general_pasteboard());

        assert!(drag.provide("hunter2".as_bytes(), ContentKind::Text));
        let string_type: &NSPasteboardType = unsafe { NSPasteboardTypeString };
        assert_eq!(
            item.stringForType(string_type).map(|s| s.to_string()),
            Some("hunter2".to_string())
        );
        assert_eq!(string_type.to_string(), ContentKind::Text.pasteboard_type());

        let image = NSPasteboardItem::new();
        // SAFETY: as above.
        let mut drag =
            unsafe { SystemDragItem::from_raw(raw(&*board.pasteboard), raw(&*image)) }.unwrap();
        assert!(drag.provide(&[0x89, b'P', b'N', b'G'], ContentKind::Image));
        let png_type: &NSPasteboardType = unsafe { NSPasteboardTypePNG };
        assert_eq!(
            image.dataForType(png_type).map(|d| d.to_vec()),
            Some(vec![0x89, b'P', b'N', b'G'])
        );
        assert_eq!(png_type.to_string(), ContentKind::Image.pasteboard_type());
        assert!(
            board
                .pasteboard
                .types()
                .is_none_or(|types| types.count() == 0),
            "the item, not its pasteboard, took the bytes"
        );
    }

    #[test]
    fn a_drag_item_on_the_general_pasteboard_says_so() {
        // Only the general pasteboard's name is read; its contents are not touched.
        let general = NSPasteboard::generalPasteboard();
        let item = NSPasteboardItem::new();
        // SAFETY: both objects live to the end of the test.
        let drag = unsafe { SystemDragItem::from_raw(raw(&*general), raw(&*item)) }.unwrap();
        assert!(drag.on_general_pasteboard());
    }

    #[test]
    fn a_drag_item_refuses_null_and_objects_of_another_class() {
        let board = SystemPasteboard::for_testing();
        let item = NSPasteboardItem::new();
        let string = NSString::from_str("not an item");
        // SAFETY: every non-null pointer is a live object for the call.
        unsafe {
            assert!(SystemDragItem::from_raw(std::ptr::null_mut(), raw(&*item)).is_none());
            assert!(
                SystemDragItem::from_raw(raw(&*board.pasteboard), std::ptr::null_mut()).is_none()
            );
            assert!(SystemDragItem::from_raw(raw(&*board.pasteboard), raw(&*string)).is_none());
            assert!(SystemDragItem::from_raw(raw(&*string), raw(&*item)).is_none());
        }
    }
}
