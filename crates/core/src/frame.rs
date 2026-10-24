//! The key frame a ceremony cuts (relay decision background section 5): the
//! page's rebuild, then each standing object's note rebuilt beside it
//! (ADR-0058 point 6).

use std::collections::BTreeSet;

use zeroize::Zeroizing;

use crate::persist::{Reader, Sink, Sizer, Writer, count};
use crate::sheet::ItemId;

/// Opens a frame that names its notes; bytes without it are a page rebuild alone.
const MAGIC: &[u8; 8] = b"OTSFRM02";

/// A frame's parts, borrowed from its bytes.
pub(crate) struct Frame<'a> {
    /// The page's rebuild.
    pub(crate) page: &'a [u8],
    /// Each object's identity and its note's rebuild, in the order written.
    pub(crate) notes: Vec<(ItemId, &'a [u8])>,
}

/// The frame of `page` and `notes`, written once at its exact size (Law 0004).
pub(crate) fn encode(page: &[u8], notes: &[(ItemId, Zeroizing<Vec<u8>>)]) -> Zeroizing<Vec<u8>> {
    let mut sizer = Sizer(0);
    emit(page, notes, &mut sizer);
    let mut buffer = Zeroizing::new(Vec::with_capacity(sizer.0));
    emit(page, notes, &mut Writer(&mut buffer));
    debug_assert_eq!(buffer.len(), sizer.0, "sizing pass drifted from the write");
    buffer
}

/// The magic, the page's rebuild, a count, then each note's identity and rebuild.
fn emit(page: &[u8], notes: &[(ItemId, Zeroizing<Vec<u8>>)], out: &mut dyn Sink) {
    out.raw(MAGIC);
    out.bytes(page);
    out.u64(notes.len() as u64);
    for (object, rebuild) in notes {
        out.raw(object.as_bytes());
        out.bytes(rebuild);
    }
}

/// Read a frame; `None` for a layout that does not parse, an identity named
/// twice or a byte past the last note.
pub(crate) fn decode(bytes: &[u8]) -> Option<Frame<'_>> {
    if !bytes.starts_with(MAGIC) {
        return Some(Frame {
            page: bytes,
            notes: Vec::new(),
        });
    }
    let mut reader = Reader {
        buf: bytes,
        pos: MAGIC.len(),
    };
    let page = reader.bytes()?;
    let written = count(&mut reader).ok()?;
    let mut seen = BTreeSet::new();
    let mut notes = Vec::new();
    for _ in 0..written {
        let object = ItemId::from_bytes(reader.raw(16)?.try_into().ok()?);
        let rebuild = reader.bytes()?;
        if !seen.insert(object) {
            return None;
        }
        notes.push((object, rebuild));
    }
    reader.done().then_some(Frame { page, notes })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notes(rebuilds: &[(ItemId, &[u8])]) -> Vec<(ItemId, Zeroizing<Vec<u8>>)> {
        rebuilds
            .iter()
            .map(|(object, rebuild)| (*object, Zeroizing::new(rebuild.to_vec())))
            .collect()
    }

    #[test]
    fn a_frame_reads_back_as_written_at_its_exact_size() {
        let (first, second) = (ItemId::random(), ItemId::random());
        let written = notes(&[(first, b"one rebuild"), (second, b"")]);
        let frame = encode(b"the page", &written);
        assert_eq!(
            frame.capacity(),
            frame.len(),
            "the frame grew past its size"
        );
        let parts = decode(&frame).expect("a written frame reads");
        assert_eq!(parts.page, b"the page");
        assert_eq!(
            parts.notes,
            vec![(first, &b"one rebuild"[..]), (second, &b""[..])]
        );
    }

    #[test]
    fn bytes_without_the_magic_are_a_page_rebuild_alone() {
        let parts = decode(b"loro snapshot bytes").unwrap();
        assert_eq!(parts.page, b"loro snapshot bytes");
        assert!(parts.notes.is_empty());
    }

    #[test]
    fn a_short_a_trailing_or_a_doubled_frame_is_refused() {
        let object = ItemId::random();
        let frame = encode(b"page", &notes(&[(object, b"rebuild")]));
        for cut in MAGIC.len()..frame.len() {
            assert!(decode(&frame[..cut]).is_none(), "{cut} bytes read");
        }
        let mut trailing = frame.to_vec();
        trailing.push(0);
        assert!(decode(&trailing).is_none());
        let doubled = encode(b"page", &notes(&[(object, b"a"), (object, b"b")]));
        assert!(decode(&doubled).is_none());
        let mut overstated = frame.to_vec();
        let at = MAGIC.len() + 8 + 4;
        overstated[at..at + 8].copy_from_slice(&u64::MAX.to_le_bytes());
        assert!(decode(&overstated).is_none());
    }
}
