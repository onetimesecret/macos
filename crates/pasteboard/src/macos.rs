#![allow(unsafe_code)]
//! The real `NSPasteboard` adapter (macOS only), on the classic
//! single-item API that nspasteboard.org-aware managers scan.

use std::ffi::c_void;
use std::ptr::NonNull;

use objc2::rc::{Retained, autoreleasepool};
use objc2::runtime::AnyObject;
use objc2_app_kit::{
    NSPasteboard, NSPasteboardItem, NSPasteboardName, NSPasteboardNameDrag,
    NSPasteboardNameGeneral, NSPasteboardType, NSPasteboardTypePNG, NSPasteboardTypeString,
    NSPasteboardTypeURL,
};
use objc2_foundation::{
    NSArray, NSData, NSRange, NSString, NSStringEncodingConversionOptions, NSUTF8StringEncoding,
};
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

    /// Whether the board declares any of `names`, compared as `NSString`s, with no
    /// conversion of the declared names.
    fn declares(&self, names: &[&NSString]) -> bool {
        self.pasteboard.types().is_some_and(|types| {
            types
                .to_vec()
                .iter()
                .any(|declared| names.iter().any(|name| declared.isEqualToString(name)))
        })
    }

    /// [`Pasteboard::read`]'s body, run inside the read's own autorelease pool.
    fn read_in_pool(&self) -> Option<PasteboardItem> {
        let string_type: &NSPasteboardType = unsafe { NSPasteboardTypeString };
        let png_type: &NSPasteboardType = unsafe { NSPasteboardTypePNG };
        let url_type: &NSPasteboardType = unsafe { NSPasteboardTypeURL };

        let text = self
            .pasteboard
            .stringForType(string_type)
            .and_then(|s| utf8_of(&s));
        let content = chosen_content(text, || {
            self.pasteboard
                .dataForType(png_type)
                .map(|data| data.to_vec())
        })?;

        let nspasteboard_concealed = self.declares(&[&NSString::from_str(CONCEALED_TYPE)]);

        // Only `public.url`: HTML has no standard place for its source
        // (ADR-0013).
        let origin_url = self
            .pasteboard
            .stringForType(url_type)
            .and_then(|url| utf8_of(&url))
            .filter(|url| !url.is_empty());

        Some(PasteboardItem {
            content,
            nspasteboard_concealed,
            origin_url,
        })
    }
}

impl Pasteboard for SystemPasteboard {
    fn read(&self) -> Option<PasteboardItem> {
        // The board's autoreleased strings and data go when the read returns, unwiped.
        autoreleasepool(|_| self.read_in_pool())
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
        if self.declares(&[&NSString::from_str(TRANSIENT_TYPE)]) {
            return false;
        }
        // SAFETY: reading static extern pasteboard-type constants.
        let (string_type, png_type) = unsafe { (NSPasteboardTypeString, NSPasteboardTypePNG) };
        self.declares(&[string_type, png_type])
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
/// for one provide call (ADR-0045 point 5).
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

/// The content a read takes: the text when it converted, else the PNG, as when the board
/// has no text at all. The variant takes the text's buffer as is (C45).
fn chosen_content(
    text: Option<Zeroizing<String>>,
    png: impl FnOnce() -> Option<Vec<u8>>,
) -> Option<PasteboardContent> {
    match text {
        Some(mut text) => Some(PasteboardContent::Text(std::mem::take(&mut *text))),
        None => png().map(PasteboardContent::Image),
    }
}

/// A string's UTF-8, converted by Foundation into a zeroed wiping buffer of the length it
/// reports, with no `UTF8String` copy; `None` unless the whole string converts (C17).
fn utf8_of(string: &NSString) -> Option<Zeroizing<String>> {
    let len = string.lengthOfBytesUsingEncoding(NSUTF8StringEncoding);
    let units = string.length();
    if len == 0 {
        // Zero bytes for a nonempty string is Foundation's refusal to convert it.
        return (units == 0).then(|| Zeroizing::new(String::new()));
    }
    let mut bytes = Zeroizing::new(vec![0u8; len]);
    let mut used: usize = 0;
    let mut leftover = NSRange::new(0, 0);
    // SAFETY: `bytes` has room for the `len` bytes allowed, and `used` and `leftover`
    // are live locals for the call.
    let converted = unsafe {
        string.getBytes_maxLength_usedLength_encoding_options_range_remainingRange(
            bytes.as_mut_ptr().cast::<c_void>(),
            len,
            &raw mut used,
            NSUTF8StringEncoding,
            NSStringEncodingConversionOptions::empty(),
            NSRange::new(0, units),
            &raw mut leftover,
        )
    };
    if !converted || used != len || leftover.length != 0 {
        return None;
    }
    // A refused conversion hands its bytes back into a wiping owner to drop.
    String::from_utf8(std::mem::take(&mut *bytes))
        .map_err(|refused| Zeroizing::new(refused.into_bytes()))
        .ok()
        .map(Zeroizing::new)
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
        assert!(pb.declares(&[&NSString::from_str(TRANSIENT_TYPE)]));
    }

    #[test]
    fn read_captures_the_origin_url_when_present_and_none_otherwise() {
        use objc2_foundation::NSArray;
        fn wiping_owner<T: zeroize::ZeroizeOnDrop>(_: &T) {}
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
        let origin = item.origin_url.as_ref().unwrap();
        assert_eq!(origin.as_str(), "https://example.test/article?token=q");
        // A wiping owner whose capacity is its length (C17).
        wiping_owner(origin);
        assert_eq!(origin.capacity(), origin.len(), "the origin copy grew");

        let mut pb = SystemPasteboard::for_testing();
        write_text(&mut pb, "no origin here", false);
        assert!(pb.read().unwrap().origin_url.is_none());
    }

    /// A board holding `text` as a string and, when given, `url` as `public.url`.
    fn board_with(text: &NSString, url: Option<&NSString>) -> SystemPasteboard {
        let pb = SystemPasteboard::for_testing();
        let string_type: &NSPasteboardType = unsafe { NSPasteboardTypeString };
        let url_type: &NSPasteboardType = unsafe { NSPasteboardTypeURL };
        let types = NSArray::from_slice(&[string_type, url_type]);
        // SAFETY: no owner; concrete bytes are written up front.
        unsafe { pb.pasteboard.declareTypes_owner(&types, None) };
        pb.pasteboard.setString_forType(text, string_type);
        if let Some(url) = url {
            pb.pasteboard.setString_forType(url, url_type);
        }
        pb
    }

    /// `a`, an unpaired high surrogate, `b`: a string with no UTF-8 form.
    fn unpaired_surrogate() -> Retained<NSString> {
        let units: [u16; 3] = [0x61, 0xD800, 0x62];
        // SAFETY: `units` is live for the call, which copies it.
        unsafe { NSString::stringWithCharacters_length(NonNull::from(&units).cast(), units.len()) }
    }

    #[test]
    fn utf8_of_converts_a_whole_string_and_refuses_an_unpaired_surrogate() {
        for text in ["", "https://exämple.test/reset?tk=SECRET", "🦀 café"] {
            let utf8 = utf8_of(&NSString::from_str(text)).unwrap();
            assert_eq!(utf8.as_str(), text);
            assert_eq!(utf8.capacity(), utf8.len(), "the buffer outgrew {text:?}");
        }
        assert!(utf8_of(&unpaired_surrogate()).is_none());
    }

    #[test]
    fn a_non_ascii_origin_reads_whole_and_a_surrogate_written_as_one_yields_no_origin() {
        let url = "https://exämple.test/reset?tk=SECRET";
        let pb = board_with(
            &NSString::from_str("quoted"),
            Some(&NSString::from_str(url)),
        );
        let item = pb.read().unwrap();
        assert_eq!(item.origin_url.as_deref().map(String::as_str), Some(url));

        let pb = board_with(&NSString::from_str("quoted"), Some(&unpaired_surrogate()));
        let item = pb.read().expect("the text still reads");
        assert_eq!(item.content, PasteboardContent::Text("quoted".into()));
        assert!(item.origin_url.is_none());
    }

    #[test]
    fn a_non_ascii_text_reads_whole() {
        let text = "exämple 🦀 token";
        let item = board_with(&NSString::from_str(text), None).read().unwrap();
        assert_eq!(item.content, PasteboardContent::Text(text.into()));
    }

    #[test]
    fn a_text_without_utf8_falls_through_to_the_image_as_no_text_does() {
        let png = || Some(vec![0x89, b'P', b'N', b'G']);
        assert_eq!(
            chosen_content(utf8_of(&unpaired_surrogate()), png),
            Some(PasteboardContent::Image(vec![0x89, b'P', b'N', b'G']))
        );
        assert_eq!(
            chosen_content(utf8_of(&unpaired_surrogate()), || None),
            None
        );
        assert_eq!(
            chosen_content(None, png),
            png().map(PasteboardContent::Image)
        );
        assert_eq!(
            chosen_content(utf8_of(&NSString::from_str("quoted")), || {
                panic!("a text that converted never asks for the image")
            }),
            Some(PasteboardContent::Text("quoted".into()))
        );
    }

    #[test]
    fn write_without_the_nspasteboard_mark_carries_only_transient() {
        let mut pb = SystemPasteboard::for_testing();
        write_text(&mut pb, "not a secret", false);
        let item = pb.read().unwrap();
        assert!(!item.nspasteboard_concealed);
        assert!(pb.declares(&[&NSString::from_str(TRANSIENT_TYPE)]));
        assert!(!pb.declares(&[&NSString::from_str(CONCEALED_TYPE)]));
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
        assert!(
            item.stringForType(string_type)
                .is_some_and(|s| s.isEqualToString(&NSString::from_str("hunter2")))
        );
        assert!(
            string_type.isEqualToString(&NSString::from_str(ContentKind::Text.pasteboard_type()))
        );

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
        assert!(
            png_type.isEqualToString(&NSString::from_str(ContentKind::Image.pasteboard_type()))
        );
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
