//! Borrowed content projections and exact-sized NUL-terminated JSON output.
//! Upstream Loro and comrak allocations, a parsed Markdown document's own strings and serde's
//! internal scratch are outside this owner.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::ffi::c_char;
use std::io::{self, Write};
use std::ptr;
use std::sync::{Mutex, PoisonError};
use std::time::Instant;

use companion_core::{
    Availability, ChipMeta, Copied, LedgerEvent, LedgerRecord, PeerKind, SealedChip, Segment,
    Sheet, Tab, local_day,
};
use companion_markdown::{Document, ParseError};
use serde::ser::SerializeSeq;
use serde::{Serialize, Serializer};
use zeroize::{Zeroize, Zeroizing};

/// The allocation layout is exactly the JSON byte length plus one terminal NUL.
struct CStringBuffer(Box<[u8]>);

impl CStringBuffer {
    /// Room for `body` bytes and the terminal NUL, zeroed; `None` when that overflows.
    fn for_body(body: usize) -> Option<Self> {
        Some(Self(vec![0; body.checked_add(1)?].into_boxed_slice()))
    }

    fn body_mut(&mut self) -> &mut [u8] {
        self.0.split_last_mut().map_or(&mut [], |(_, body)| body)
    }

    fn body(&self) -> &[u8] {
        self.0.split_last().map_or(&[], |(_, body)| body)
    }

    /// Hand the buffer across the seam, recorded in [`LIVE`].
    fn into_raw(mut self) -> *mut c_char {
        let mut live = LIVE.lock().unwrap_or_else(PoisonError::into_inner);
        let bytes = std::mem::take(&mut self.0);
        let len = bytes.len();
        let raw = Box::into_raw(bytes).cast::<u8>();
        live.insert(raw.addr(), len);
        raw.cast::<c_char>()
    }

    /// Take back a buffer [`LIVE`] recorded, at its recorded length; `None` for any other pointer.
    ///
    /// # Safety
    /// The caller must not read through `raw` once this returns `Some`.
    unsafe fn from_raw(raw: *mut c_char) -> Option<Self> {
        let len = LIVE
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&raw.addr())?;
        let slice = ptr::slice_from_raw_parts_mut(raw.cast::<u8>(), len);
        Some(Self(unsafe { Box::from_raw(slice) }))
    }
}

/// Every buffer `into_raw` handed out and `from_raw` has not taken back: address to length.
/// A poisoned lock is read through: a refused hand-off or free would leak a buffer unwiped.
static LIVE: Mutex<BTreeMap<usize, usize>> = Mutex::new(BTreeMap::new());

#[cfg(test)]
pub(super) fn is_live(raw: *const c_char) -> bool {
    LIVE.lock()
        .unwrap_or_else(PoisonError::into_inner)
        .contains_key(&raw.addr())
}

impl Zeroize for CStringBuffer {
    fn zeroize(&mut self) {
        self.0.as_mut().zeroize();
    }
}

impl Drop for CStringBuffer {
    fn drop(&mut self) {
        self.zeroize();
    }
}

struct Count(usize);

impl Write for Count {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0 = self
            .0
            .checked_add(bytes.len())
            .ok_or_else(|| io::Error::other("JSON size overflow"))?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn encode<T: Serialize + ?Sized>(value: &T) -> serde_json::Result<CStringBuffer> {
    let mut count = Count(0);
    serde_json::to_writer(&mut count, value)?;
    let mut output = CStringBuffer::for_body(count.0)
        .ok_or_else(|| serde_json::Error::io(io::Error::other("JSON terminator size overflow")))?;
    let mut remaining = output.body_mut();
    serde_json::to_writer(&mut remaining, value)?;
    if !remaining.is_empty() {
        return Err(serde_json::Error::io(io::Error::other(
            "JSON size changed between passes",
        )));
    }
    // JSON escapes text NULs; also reject a custom serializer's raw interior NUL.
    if output.body().contains(&0) {
        return Err(serde_json::Error::io(io::Error::other(
            "interior NUL in JSON output",
        )));
    }
    Ok(output)
}

pub(super) fn to_c_json<T: Serialize + ?Sized>(value: &T) -> *mut c_char {
    encode(value).map_or(ptr::null_mut(), CStringBuffer::into_raw)
}

/// A paste's origin message, `{"origin": url}`, counted, then written once into a wiping
/// owner of its exact size with no `Value` copy of the URL (Law 0004, C17).
pub(super) fn origin_message(url: &str) -> Option<Zeroizing<String>> {
    #[derive(Serialize)]
    struct Message<'a> {
        origin: &'a str,
    }
    let message = Message { origin: url };
    let mut count = Count(0);
    serde_json::to_writer(&mut count, &message).ok()?;
    let mut bytes = Zeroizing::new(vec![0; count.0]);
    let mut remaining = bytes.as_mut_slice();
    serde_json::to_writer(&mut remaining, &message).ok()?;
    if !remaining.is_empty() {
        return None;
    }
    // A refused conversion hands its bytes back into a wiping owner to drop.
    String::from_utf8(std::mem::take(&mut *bytes))
        .map_err(|refused| Zeroizing::new(refused.into_bytes()))
        .ok()
        .map(Zeroizing::new)
}

pub(super) fn from_string(text: String) -> *mut c_char {
    let text = Zeroizing::new(text);
    if text.as_bytes().contains(&0) {
        return ptr::null_mut();
    }
    let Some(mut output) = CStringBuffer::for_body(text.len()) else {
        return ptr::null_mut();
    };
    output.body_mut().copy_from_slice(text.as_bytes());
    output.into_raw()
}

/// Wipe and free a buffer this module handed out; null and any pointer it never handed out are left alone.
///
/// # Safety
/// `raw` must not be freed already, since its address may now belong to a newer
/// buffer; the caller must not read through `raw` after this call.
pub(super) unsafe fn free(raw: *mut c_char) {
    if !raw.is_null() {
        drop(unsafe { CStringBuffer::from_raw(raw) });
    }
}

// Field order matches serde_json::Value's sorted object keys at the old seam.
#[derive(Serialize)]
pub(super) struct ChipFace<'a> {
    /// False when the value is on another device (ADR-0058 point 4).
    available: bool,
    chip_id: u64,
    concealed: bool,
    excerpt: &'a str,
    has_note: bool,
    kind: &'static str,
    name: Option<&'a str>,
    size_label: &'a str,
}

pub(super) fn chip_face(chip: &SealedChip) -> ChipFace<'_> {
    ChipFace {
        available: chip.is_local(),
        chip_id: chip.id().raw(),
        concealed: chip.conceal().is_some(),
        excerpt: chip.excerpt(),
        has_note: chip.has_note(),
        kind: match chip.availability() {
            Availability::Local(local) => match local.meta() {
                ChipMeta::Text { .. } => "text",
                ChipMeta::Image { .. } => "image",
            },
            Availability::Peer { kind, .. } => match kind {
                Some(PeerKind::Text) => "text",
                Some(PeerKind::Image) => "image",
                None => "unknown",
            },
        },
        name: chip.name(),
        size_label: chip.size_label(),
    }
}

#[derive(Serialize)]
#[serde(untagged)]
enum Run<'a> {
    Ink { ink: &'a str },
    Chip { chip: ChipFace<'a> },
}

pub(super) struct InkRuns<'a>(pub &'a str);

impl Serialize for InkRuns<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(usize::from(!self.0.is_empty())))?;
        if !self.0.is_empty() {
            seq.serialize_element(&Run::Ink { ink: self.0 })?;
        }
        seq.end()
    }
}

pub(super) struct DocumentRuns<'a>(pub &'a Sheet);

impl Serialize for DocumentRuns<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(None)?;
        for segment in self.0.segments() {
            match segment {
                Segment::Ink(text) => seq.serialize_element(&Run::Ink { ink: text })?,
                Segment::Chip(id) => {
                    if let Some(chip) = self.0.chip(*id) {
                        seq.serialize_element(&Run::Chip {
                            chip: chip_face(chip),
                        })?;
                    }
                }
            }
        }
        seq.end()
    }
}

/// A page's Markdown reading: the document itself, or `{"error": refusal}`.
pub(super) fn markdown_json(reading: Result<Document, ParseError>) -> *mut c_char {
    #[derive(Serialize)]
    struct Refusal<'a> {
        error: &'a ParseError,
    }
    match reading {
        Ok(document) => to_c_json(&document),
        Err(error) => to_c_json(&Refusal { error: &error }),
    }
}

#[derive(Serialize)]
pub(super) struct ActiveCut<'a> {
    pub objects: Vec<ChipFace<'a>>,
    pub page_id: Option<u64>,
}

struct LossyText<'a>(Cow<'a, str>);

impl Serialize for LossyText<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0)
    }
}

impl Drop for LossyText<'_> {
    fn drop(&mut self) {
        if let Cow::Owned(text) = &mut self.0 {
            text.zeroize();
        }
    }
}

#[derive(Serialize)]
struct CopiedJson<'a> {
    envelope: Option<LossyText<'a>>,
    plain: &'a str,
}

pub(super) fn copied_json(copied: &Copied) -> *mut c_char {
    to_c_json(&CopiedJson {
        envelope: copied
            .envelope
            .as_ref()
            .map(|bytes| LossyText(String::from_utf8_lossy(bytes))),
        plain: copied.plain.as_str(),
    })
}

fn secret_text<S: Serializer>(text: &Zeroizing<String>, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(text)
}

#[derive(Serialize)]
pub(super) struct TabSummary {
    chip_count: usize,
    fraction_remaining: f64,
    has_page: bool,
    hold_remaining_ms: u64,
    hold_topped_up: bool,
    id: u64,
    last_hour: bool,
    page_created_ms: Option<u64>,
    page_day_offset: Option<i64>,
    page_has_content: bool,
    page_id: Option<u64>,
    page_uuid: Option<String>,
    paused: bool,
    remaining_label: String,
    remaining_ms: u64,
    rung_code: i32,
    rung_label: String,
    spoken_remaining: String,
    #[serde(serialize_with = "secret_text")]
    title: Zeroizing<String>,
    title_source: &'static str,
    uuid: String,
}

pub(super) fn summary_json(
    tab: &Tab,
    now: Instant,
    utc_offset_seconds: i32,
    now_wall_ms: u64,
) -> TabSummary {
    let page = tab.page();
    let today = local_day(now_wall_ms, utc_offset_seconds);
    let remaining = page.map_or(std::time::Duration::ZERO, |sheet| sheet.remaining(now));
    TabSummary {
        chip_count: page.map_or(0, Sheet::chip_count),
        fraction_remaining: page.map_or(0.0, |sheet| {
            f64::from(sheet.fraction_remaining(tab.rung(), now))
        }),
        has_page: page.is_some(),
        hold_remaining_ms: page.map_or(0, |sheet| {
            u64::try_from(sheet.hold_remaining(now).as_millis()).unwrap_or(u64::MAX)
        }),
        hold_topped_up: page.is_some_and(|sheet| sheet.hold_topped_up(now)),
        id: tab.id().raw(),
        last_hour: page.is_some_and(|sheet| sheet.last_hour(now)),
        page_created_ms: page.map(Sheet::created_wall_ms),
        page_day_offset: page.map(|sheet| sheet.local_day(utc_offset_seconds) - today),
        page_has_content: page.is_some_and(Sheet::has_content),
        page_id: page.map(|sheet| sheet.id().raw()),
        page_uuid: page.map(|sheet| sheet.uuid().to_string()),
        paused: page.is_some_and(|sheet| sheet.is_held(now)),
        remaining_label: page
            .map(|sheet| sheet.remaining_label(now))
            .unwrap_or_default(),
        remaining_ms: u64::try_from(remaining.as_millis()).unwrap_or(u64::MAX),
        rung_code: super::ttl_to_code(tab.rung()),
        rung_label: tab.rung().to_string(),
        spoken_remaining: page.map_or_else(
            || "this tab holds no page".to_string(),
            |_| super::spoken_remaining(remaining),
        ),
        title: tab.label(utc_offset_seconds),
        title_source: tab.label_source().as_str(),
        uuid: tab.uuid().to_string(),
    }
}

#[derive(Serialize)]
pub(super) struct LedgerRow<'a> {
    at_ms: u64,
    created_at_ms: u64,
    destination: String,
    event: &'static str,
    item: String,
    size: &'static str,
    title: &'a str,
}

pub(super) fn ledger_row(record: &LedgerRecord) -> LedgerRow<'_> {
    LedgerRow {
        at_ms: record.at_wall_ms(),
        created_at_ms: record.item_created_wall_ms(),
        destination: record.destination().to_string(),
        event: match record.event() {
            LedgerEvent::Created => "created",
            LedgerEvent::Sealed => "sealed",
            LedgerEvent::Sent => "sent",
            LedgerEvent::Expired => "expired",
            LedgerEvent::Discarded => "discarded",
        },
        item: record.item().to_string(),
        size: record.size().as_str(),
        title: record.title(),
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::ffi::{CStr, CString};

    use super::*;

    fn assert_encoding<T: Serialize + ?Sized>(value: &T, expected: &[u8]) {
        let mut output = encode(value).unwrap();
        assert_eq!(output.0.len(), expected.len() + 1);
        assert_eq!(&output.0[..expected.len()], expected);
        assert_eq!(output.0.last(), Some(&0));
        assert_eq!(
            CStr::from_bytes_with_nul(&output.0).unwrap().to_bytes(),
            expected
        );
        let address = output.0.as_ptr();
        let len = output.0.len();
        output.zeroize();
        assert_eq!(output.0.as_ptr(), address);
        assert_eq!(output.0.len(), len);
        assert!(output.0.iter().all(|byte| *byte == 0));
    }

    #[test]
    fn exact_nul_encoding_matches_serde_and_wipes_the_live_allocation() {
        for text in ["", "\"\\\n\r\t\0\u{001f}", "café 🦀 / <tag>"] {
            let runs = InkRuns(text);
            let expected = if text.is_empty() {
                serde_json::json!([])
            } else {
                serde_json::json!([{ "ink": text }])
            };
            assert_encoding(&runs, &serde_json::to_vec(&expected).unwrap());
        }
        let text = "café 🦀\0\n\"\\".repeat(65_536);
        assert_encoding(
            &InkRuns(&text),
            &serde_json::to_vec(&[serde_json::json!({"ink": text})]).unwrap(),
        );
    }

    /// The origin message is the JSON a `Value` made of it, in one wiping owner of its exact
    /// size (Law 0004, C17).
    #[test]
    fn the_origin_message_is_its_json_in_one_exact_wiping_owner() {
        fn wiping_owner<T: zeroize::ZeroizeOnDrop>(_: &T) {}
        for url in [
            "",
            "https://origin.example.test/reset?tk=Vq9Zx",
            "https://example.test/café/🦀?q=\"quoted\"&b=\\\n\t\0\u{001f}",
        ] {
            let message = origin_message(url).unwrap();
            wiping_owner(&message);
            assert_eq!(
                message.as_str(),
                serde_json::json!({ "origin": url }).to_string()
            );
            assert_eq!(message.capacity(), message.len(), "the message grew");
        }
    }

    #[test]
    fn chip_and_cut_fields_match_the_previous_sorted_json_bytes() {
        let face = ChipFace {
            available: true,
            chip_id: u64::MAX,
            concealed: true,
            excerpt: "excerpt 🦀\0\n\"\\",
            has_note: true,
            kind: "text",
            name: Some("name café\0\n\"\\"),
            size_label: "small",
        };
        let expected = serde_json::json!({
            "available": true,
            "chip_id": u64::MAX,
            "kind": "text",
            "excerpt": face.excerpt,
            "size_label": "small",
            "concealed": true,
            "name": face.name,
            "has_note": true,
        });
        assert_encoding(&face, &serde_json::to_vec(&expected).unwrap());
        assert_encoding(
            &ActiveCut {
                objects: vec![face],
                page_id: Some(u64::MAX),
            },
            &serde_json::to_vec(&serde_json::json!({"page_id": u64::MAX, "objects": [expected]}))
                .unwrap(),
        );
        assert_encoding(
            &ActiveCut {
                objects: vec![],
                page_id: None,
            },
            br#"{"objects":[],"page_id":null}"#,
        );
        assert_encoding(
            &ChipFace { available: false, chip_id: 0, concealed: false, excerpt: "", has_note: false, kind: "image", name: None, size_label: "tiny" },
            br#"{"available":false,"chip_id":0,"concealed":false,"excerpt":"","has_note":false,"kind":"image","name":null,"size_label":"tiny"}"#,
        );
    }

    #[test]
    fn copied_envelope_stays_a_string_with_the_same_lossy_utf8_semantics() {
        for envelope in [
            None,
            Some(&b"{\"text\":\"caf\xc3\xa9\"}\0\n"[..]),
            Some(&b"invalid \xff utf8"[..]),
        ] {
            let copied = Copied {
                envelope: envelope.map(|bytes| Zeroizing::new(bytes.to_vec())),
                plain: Zeroizing::new("plain café 🦀\0\n\"\\".to_string()),
            };
            let expected = serde_json::json!({
                "envelope": envelope.map(String::from_utf8_lossy),
                "plain": copied.plain.as_str(),
            });
            let raw = copied_json(&copied);
            assert!(!raw.is_null());
            let mut output = unsafe { CStringBuffer::from_raw(raw) }.unwrap();
            assert_eq!(
                CStr::from_bytes_with_nul(&output.0).unwrap().to_bytes(),
                serde_json::to_vec(&expected).unwrap()
            );
            output.zeroize();
            assert!(output.0.iter().all(|byte| *byte == 0));
        }
        assert!(matches!(
            LossyText(String::from_utf8_lossy(b"valid")).0,
            Cow::Borrowed(_)
        ));
        let mut lossy = LossyText(String::from_utf8_lossy(b"invalid \xff"));
        let Cow::Owned(text) = &mut lossy.0 else {
            panic!("expected replacement allocation")
        };
        text.zeroize();
        assert!(text.is_empty());
    }

    #[test]
    fn every_buffer_has_room_for_its_terminal_nul() {
        let mut empty = CStringBuffer::for_body(0).unwrap();
        assert_eq!(&*empty.0, &[0]);
        assert!(empty.body_mut().is_empty());
        assert!(CStringBuffer::for_body(usize::MAX).is_none());
        let raw = CStringBuffer::for_body(0).unwrap().into_raw();
        assert_eq!(unsafe { CStr::from_ptr(raw) }.to_bytes(), b"");
        unsafe { free(raw) };
    }

    #[test]
    fn raw_transfer_and_reconstruction_use_the_same_pointer_and_full_slice_length() {
        let owner = encode(&InkRuns("café 🦀\0\n\"\\")).unwrap();
        let address = owner.0.as_ptr();
        let len = owner.0.len();
        let raw = owner.into_raw();
        assert_eq!(raw.cast::<u8>().cast_const(), address);
        let mut owner = unsafe { CStringBuffer::from_raw(raw) }.unwrap();
        assert_eq!(owner.0.as_ptr(), address);
        assert_eq!(owner.0.len(), len);
        owner.zeroize();
        assert!(owner.0.iter().all(|byte| *byte == 0));
    }

    #[test]
    fn free_takes_back_only_what_this_module_handed_out() {
        let versions: [extern "C" fn() -> *const c_char; 3] = [
            super::super::companion_ffi_version,
            super::super::companion_version,
            super::super::companion_core_version,
        ];
        for version in versions {
            let raw = version();
            let before = unsafe { CStr::from_ptr(raw) }.to_owned();
            assert!(!is_live(raw));
            unsafe { super::super::companion_string_free(raw.cast_mut()) };
            assert_eq!(unsafe { CStr::from_ptr(raw) }, before.as_c_str());
        }

        let foreign = CString::new("foreign").unwrap().into_raw();
        unsafe { free(foreign) };
        assert_eq!(unsafe { CStr::from_ptr(foreign) }.to_bytes(), b"foreign");
        drop(unsafe { CString::from_raw(foreign) });

        let raw = from_string("handed out".to_string());
        assert!(is_live(raw));
        unsafe { free(raw.wrapping_add(1)) };
        assert_eq!(unsafe { CStr::from_ptr(raw) }.to_bytes(), b"handed out");
        let owner = unsafe { CStringBuffer::from_raw(raw) }.unwrap();
        assert!(!is_live(raw));
        assert!(unsafe { CStringBuffer::from_raw(raw) }.is_none());
        drop(owner);
    }

    #[test]
    fn a_markdown_reading_is_an_exact_live_buffer_the_free_path_wipes() {
        let text = "# café \u{FFFC}\n\n| a |\n| - |\n";
        let objects = [7_usize];
        let parse = || unsafe {
            super::super::companion_markdown_parse_json(
                text.as_ptr().cast(),
                text.len(),
                objects.as_ptr(),
                objects.len(),
                1,
                1_000,
                8,
                100,
            )
        };
        let expected = serde_json::to_vec(
            &companion_markdown::parse_with_objects(
                text,
                &objects,
                companion_markdown::Dialect::Gfm,
                companion_markdown::Limits::default(),
            )
            .unwrap(),
        )
        .unwrap();

        // The free path is `free`, then this owner's drop, which zeroizes.
        let raw = parse();
        assert!(is_live(raw));
        let mut owner = unsafe { CStringBuffer::from_raw(raw) }.unwrap();
        assert!(!is_live(raw));
        assert_eq!(owner.0.as_ptr(), raw.cast::<u8>().cast_const());
        assert_eq!(owner.0.len(), expected.len() + 1);
        assert_eq!(owner.body(), expected);
        assert_eq!(owner.0.last(), Some(&0));
        owner.zeroize();
        assert!(owner.0.iter().all(|byte| *byte == 0));
        drop(owner);

        let refused = super::super::markdown_parse_owned(|| Err(ParseError::InputLimit));
        assert!(is_live(refused));
        unsafe { super::super::companion_string_free(refused) };
    }

    #[test]
    #[ignore = "manual production Markdown JSON profile"]
    fn markdown_json_production_profile() {
        use companion_markdown::{Dialect, Limits, parse_with_objects};
        use std::time::Duration;

        for repetitions in [100, 1_000] {
            let text = "## Heading **bold**\n\nText &amp; &#x100000; \u{FFFC} [link](https://example.com).\n\n"
                .repeat(repetitions);
            let objects: Vec<_> = text
                .encode_utf16()
                .enumerate()
                .filter_map(|(offset, unit)| (unit == 0xFFFC).then_some(offset))
                .collect();
            for dialect in [Dialect::CommonMark, Dialect::Gfm] {
                let mut encode_time = Duration::ZERO;
                let mut free_time = Duration::ZERO;
                let mut json_bytes = 0;
                for _ in 0..10 {
                    let document =
                        parse_with_objects(&text, &objects, dialect, Limits::default()).unwrap();
                    let expected = serde_json::to_vec(&document).unwrap();
                    let start = Instant::now();
                    let raw = markdown_json(Ok(document));
                    encode_time += start.elapsed();
                    assert!(!raw.is_null());
                    assert!(is_live(raw));
                    let body = unsafe { CStr::from_ptr(raw) }.to_bytes();
                    assert_eq!(body, expected);
                    json_bytes = body.len();
                    let start = Instant::now();
                    unsafe { super::super::companion_string_free(raw) };
                    free_time += start.elapsed();
                }
                eprintln!(
                    "markdown-json-production {dialect:?} input={} objects={} json={} mean_us: encode_register_drop_document={} free={}",
                    text.len(),
                    objects.len(),
                    json_bytes,
                    encode_time.as_micros() / 10,
                    free_time.as_micros() / 10,
                );
            }
        }
    }

    #[test]
    fn a_poisoned_registry_still_hands_out_and_takes_back() {
        let poisoner = std::thread::spawn(|| {
            let _live = LIVE.lock().unwrap_or_else(PoisonError::into_inner);
            panic!("poison the registry on purpose");
        });
        assert!(poisoner.join().is_err());
        assert!(LIVE.is_poisoned());

        let raw = from_string("after the poison".to_string());
        assert!(!raw.is_null());
        assert!(is_live(raw));
        let owner = unsafe { CStringBuffer::from_raw(raw) }.unwrap();
        assert!(!is_live(raw));
        drop(owner);
    }

    #[test]
    fn ordinary_strings_share_the_exact_box_layout_and_free_path() {
        for text in [
            String::new(),
            "ordinary café 🦀".to_string(),
            "large".repeat(65_536),
        ] {
            let expected = text.as_bytes().to_vec();
            let raw = from_string(text);
            assert!(!raw.is_null());
            let mut owner = unsafe { CStringBuffer::from_raw(raw) }.unwrap();
            assert_eq!(owner.0.len(), expected.len() + 1);
            assert_eq!(&owner.0[..expected.len()], expected);
            owner.zeroize();
            assert!(owner.0.iter().all(|byte| *byte == 0));
        }
        assert!(from_string("interior\0NUL".to_string()).is_null());
        unsafe {
            super::super::companion_string_free(ptr::null_mut());
            super::super::companion_string_free(from_string("metadata".to_string()));
            super::super::companion_string_free(to_c_json(&InkRuns("ink\0🦀")));
        }
    }

    struct Changing<'a> {
        first: &'a str,
        second: &'a str,
        calls: Cell<usize>,
        fail_on: Option<usize>,
    }

    impl Serialize for Changing<'_> {
        fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
            let call = self.calls.get();
            self.calls.set(call + 1);
            if self.fail_on == Some(call) {
                return Err(serde::ser::Error::custom("refused"));
            }
            serializer.serialize_str(if call == 0 { self.first } else { self.second })
        }
    }

    #[test]
    fn errors_and_size_drift_return_null_instead_of_transferring_a_partial_buffer() {
        for (first, second, fail_on, calls) in [
            ("short", "much longer", None, 2),
            ("much longer", "short", None, 2),
            ("secret", "secret", Some(0), 1),
            ("secret", "secret", Some(1), 2),
        ] {
            let value = Changing {
                first,
                second,
                calls: Cell::new(0),
                fail_on,
            };
            assert!(to_c_json(&value).is_null());
            assert_eq!(value.calls.get(), calls);
        }
        assert!(Count(usize::MAX).write_all(b"x").is_err());
    }
}
