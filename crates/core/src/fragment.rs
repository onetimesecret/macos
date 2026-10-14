//! The sealed fragment (Law 0001, ADR-0047): a selection's ordered ink and
//! object references, composed and read only here, never payload.

use std::borrow::Cow;
use std::io::{self, Write};

use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::sheet::{ItemId, SealedChip, Segment, Sheet};

/// The one envelope version this build writes and reads.
pub(crate) const VERSION: u32 = 1;

/// One run of a fragment, in selection order.
pub(crate) enum Node {
    /// Visible ink, never empty.
    Ink(Zeroizing<String>),
    /// A sealed object, by identity.
    Ref(Reference),
}

/// A sealed object as a fragment names it.
pub(crate) struct Reference {
    pub(crate) uuid: ItemId,
}

impl Reference {
    fn of(chip: &SealedChip) -> Self {
        Self { uuid: chip.uuid }
    }
}

/// A selection's ordered nodes; `cut` names the cut it came from.
pub(crate) struct Fragment {
    pub(crate) cut: Option<ItemId>,
    pub(crate) nodes: Vec<Node>,
}

/// A copied selection: the envelope when it holds an object, and the public
/// text every other app receives.
pub struct Copied {
    /// The private type's bytes, `None` for a selection of ink alone.
    pub envelope: Option<Zeroizing<Vec<u8>>>,
    /// The ink with `[sealed content · <size class>]` for each object.
    pub plain: Zeroizing<String>,
}

/// `[sealed content · <word>]`, the placeholder Law 0001 fixes.
pub(crate) fn placeholder(word: &str) -> String {
    format!("[sealed content \u{b7} {word}]")
}

impl Fragment {
    /// Whether any node names a sealed object.
    pub(crate) fn has_reference(&self) -> bool {
        self.references().next().is_some()
    }

    /// The references, in order.
    pub(crate) fn references(&self) -> impl Iterator<Item = &Reference> {
        self.nodes.iter().filter_map(|node| match node {
            Node::Ref(reference) => Some(reference),
            Node::Ink(_) => None,
        })
    }

    /// The envelope's bytes, encoded twice so the buffer is born at its
    /// final size (Law 0004).
    pub(crate) fn envelope(&self) -> Zeroizing<Vec<u8>> {
        let cut = self.cut.map(|cut| cut.to_string());
        let nodes: Vec<WireNode<'_>> = self
            .nodes
            .iter()
            .map(|node| match node {
                Node::Ink(text) => WireNode::Ink(Cow::Borrowed(text.as_str())),
                Node::Ref(reference) => WireNode::Ref(WireRef {
                    uuid: reference.uuid.to_string(),
                }),
            })
            .collect();
        let wire = WireFragment {
            version: VERSION,
            cut,
            nodes,
        };
        let mut sizer = Counter(0);
        serde_json::to_writer(&mut sizer, &wire).expect("a fragment always encodes");
        let mut out = Zeroizing::new(Vec::with_capacity(sizer.0));
        serde_json::to_writer(&mut *out, &wire).expect("a fragment always encodes");
        debug_assert_eq!(out.len(), sizer.0, "sizing pass drifted from the write");
        out
    }

    /// Read an envelope. `None` when this build cannot: another version, an
    /// unknown key, a malformed UUID, or bytes that are not UTF-8 JSON.
    pub(crate) fn parse(bytes: &[u8]) -> Option<Self> {
        let wire: WireFragment<'_> = serde_json::from_slice(bytes).ok()?;
        if wire.version != VERSION {
            return None;
        }
        let cut = match wire.cut {
            None => None,
            Some(text) => Some(ItemId::parse(&text)?),
        };
        let mut nodes = Vec::with_capacity(wire.nodes.len());
        for node in wire.nodes {
            match node {
                WireNode::Ink(text) if text.is_empty() => {}
                // An escaped string was already owned; the rest copy at size.
                WireNode::Ink(Cow::Owned(text)) => nodes.push(Node::Ink(Zeroizing::new(text))),
                WireNode::Ink(Cow::Borrowed(text)) => {
                    nodes.push(Node::Ink(Zeroizing::new(text.to_owned())));
                }
                WireNode::Ref(reference) => nodes.push(Node::Ref(Reference {
                    uuid: ItemId::parse(&reference.uuid)?,
                })),
            }
        }
        Some(Self { cut, nodes })
    }
}

impl Sheet {
    /// A UTF-16 range of the body as a fragment and its public text, from one
    /// walk. `None` for an empty range, one past the body, or one splitting a
    /// surrogate pair.
    pub(crate) fn select(
        &self,
        at_u16: u32,
        len_u16: u32,
    ) -> Option<(Fragment, Zeroizing<String>)> {
        let start = at_u16 as usize;
        let end = start.checked_add(len_u16 as usize)?;
        if start == end {
            return None;
        }
        let mut nodes = Vec::new();
        let mut sizes: Vec<&str> = Vec::new();
        let mut pos = 0usize;
        for segment in &self.segments {
            match segment {
                Segment::Ink(text) => {
                    let units = text.encode_utf16().count();
                    if pos + units > start && pos < end {
                        let from = start.saturating_sub(pos);
                        let to = (end - pos).min(units);
                        let slice = utf16_slice(text, from, to)?;
                        nodes.push(Node::Ink(Zeroizing::new(slice.to_owned())));
                    }
                    pos += units;
                }
                Segment::Chip(id) => {
                    if (start..end).contains(&pos) {
                        let chip = self.chip(*id)?;
                        nodes.push(Node::Ref(Reference::of(chip)));
                        sizes.push(&chip.size_label);
                    }
                    pos += 1;
                }
            }
        }
        if end > pos {
            return None;
        }
        let plain = public_text(&nodes, &sizes);
        Some((Fragment { cut: None, nodes }, plain))
    }
}

/// The ink, with a size-class placeholder for each reference, at its final
/// size (Law 0004).
fn public_text(nodes: &[Node], sizes: &[&str]) -> Zeroizing<String> {
    let placeholders: Vec<String> = sizes.iter().map(|size| placeholder(size)).collect();
    let total: usize = nodes
        .iter()
        .filter_map(|node| match node {
            Node::Ink(text) => Some(text.len()),
            Node::Ref(_) => None,
        })
        .sum::<usize>()
        + placeholders.iter().map(String::len).sum::<usize>();
    let mut out = Zeroizing::new(String::with_capacity(total));
    let mut placeholders = placeholders.iter();
    for node in nodes {
        match node {
            Node::Ink(text) => out.push_str(text),
            Node::Ref(_) => out.push_str(placeholders.next().expect("one size per reference")),
        }
    }
    out
}

/// `text[from..to]` in UTF-16 code units; `None` when a bound splits a pair.
fn utf16_slice(text: &str, from: usize, to: usize) -> Option<&str> {
    let mut units = 0usize;
    let mut start = (from == 0).then_some(0);
    let mut end = (to == 0).then_some(0);
    for (byte, ch) in text.char_indices() {
        units += ch.len_utf16();
        let after = byte + ch.len_utf8();
        if units == from {
            start = Some(after);
        }
        if units == to {
            end = Some(after);
        }
    }
    text.get(start?..end?)
}

/// Counts the bytes a sizing pass would write.
struct Counter(usize);

impl Write for Counter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0 += buf.len();
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// The envelope as JSON (ADR-0047 point 1).
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireFragment<'a> {
    version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cut: Option<String>,
    #[serde(borrow)]
    nodes: Vec<WireNode<'a>>,
}

#[derive(Serialize, Deserialize)]
enum WireNode<'a> {
    #[serde(rename = "ink")]
    Ink(#[serde(borrow)] Cow<'a, str>),
    #[serde(rename = "ref")]
    Ref(WireRef),
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireRef {
    uuid: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;
    use crate::sheet::{ChipId, SheetId};
    use crate::store::SheetStore;

    const SECRET: &str = "ghp_n0ts3cr3tn0ts3cr3t";
    /// The mixed body's length in UTF-16 code units.
    const BODY: u32 = 27;

    fn store() -> SheetStore<ManualClock> {
        SheetStore::new(ManualClock::new()).with_grace_snap(false)
    }

    /// `ink → object A → ink → object B → ink`, the law's own example.
    fn mixed(store: &mut SheetStore<ManualClock>) -> (SheetId, ChipId, ChipId) {
        let id = store.new_tab().1;
        let a = store.seal_text(id, SECRET).unwrap();
        let b = store.seal_text(id, &"b".repeat(300)).unwrap();
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink("before ".into()),
                Segment::Chip(a),
                Segment::Ink(" between \u{1F511} ".into()),
                Segment::Chip(b),
                Segment::Ink(" after".into()),
            ],
        ));
        (id, a, b)
    }

    fn uuid(store: &SheetStore<ManualClock>, id: SheetId, chip: ChipId) -> ItemId {
        store.sheet(id).unwrap().chip(chip).unwrap().uuid()
    }

    fn ink(node: &Node) -> Option<&str> {
        match node {
            Node::Ink(text) => Some(text),
            Node::Ref(_) => None,
        }
    }

    fn reference(node: &Node) -> Option<ItemId> {
        match node {
            Node::Ref(reference) => Some(reference.uuid),
            Node::Ink(_) => None,
        }
    }

    #[test]
    fn a_mixed_selection_keeps_its_ink_and_references_in_order() {
        let mut store = store();
        let (id, a, b) = mixed(&mut store);
        let (fragment, _) = store.sheet(id).unwrap().select(0, BODY).unwrap();
        let read = Fragment::parse(&fragment.envelope()).unwrap();
        assert_eq!(read.nodes.len(), 5);
        assert_eq!(ink(&read.nodes[0]), Some("before "));
        assert_eq!(reference(&read.nodes[1]), Some(uuid(&store, id, a)));
        assert_eq!(ink(&read.nodes[2]), Some(" between \u{1F511} "));
        assert_eq!(reference(&read.nodes[3]), Some(uuid(&store, id, b)));
        assert_eq!(ink(&read.nodes[4]), Some(" after"));
        assert_eq!(read.cut, None, "a copy names no cut");
    }

    #[test]
    fn the_public_text_puts_a_size_class_placeholder_where_each_object_stood() {
        let mut store = store();
        let (id, ..) = mixed(&mut store);
        let (_, plain) = store.sheet(id).unwrap().select(0, BODY).unwrap();
        assert_eq!(
            plain.as_str(),
            "before [sealed content \u{b7} tiny] between \u{1F511} \
             [sealed content \u{b7} small] after"
        );
        assert_eq!(plain.capacity(), plain.len(), "born at its final size");
    }

    #[test]
    fn neither_representation_holds_payload_or_ciphertext() {
        let mut store = store();
        let (id, ..) = mixed(&mut store);
        let (fragment, plain) = store.sheet(id).unwrap().select(0, BODY).unwrap();
        let envelope = fragment.envelope();
        for needle in [SECRET, "bbbbbbbb", "n0ts3cr3t"] {
            assert!(!plain.contains(needle));
            assert!(
                !envelope
                    .windows(needle.len())
                    .any(|window| window == needle.as_bytes()),
                "{needle} reached the envelope"
            );
        }
    }

    #[test]
    fn a_one_object_copy_is_a_one_reference_fragment() {
        let mut store = store();
        let (id, a, _) = mixed(&mut store);
        let (fragment, plain) = store.sheet(id).unwrap().select(7, 1).unwrap();
        assert_eq!(fragment.nodes.len(), 1);
        assert_eq!(reference(&fragment.nodes[0]), Some(uuid(&store, id, a)));
        assert_eq!(plain.as_str(), "[sealed content \u{b7} tiny]");
    }

    #[test]
    fn a_whole_page_selection_holds_every_object_by_reference() {
        let mut store = store();
        let (id, a, b) = mixed(&mut store);
        let (fragment, _) = store.sheet(id).unwrap().select(0, BODY).unwrap();
        let named: Vec<ItemId> = fragment.nodes.iter().filter_map(reference).collect();
        assert_eq!(named, vec![uuid(&store, id, a), uuid(&store, id, b)]);
        assert!(
            store.sheet(id).unwrap().select(0, BODY + 1).is_none(),
            "past the body"
        );
    }

    #[test]
    fn a_copy_of_ink_alone_offers_its_text_and_no_envelope_and_changes_nothing() {
        let mut store = store();
        let (id, ..) = mixed(&mut store);
        let records = store.ledger().count();
        let copied = store.copy_fragment(id, 0, 7).unwrap();
        assert!(copied.envelope.is_none());
        assert_eq!(copied.plain.as_str(), "before ");

        let whole = store.copy_fragment(id, 0, BODY).unwrap();
        assert!(Fragment::parse(&whole.envelope.unwrap()).is_some());
        assert!(
            store
                .copy_fragment(SheetId::from_raw(4_242), 0, 1)
                .is_none()
        );
        assert_eq!(store.ledger().count(), records);
        assert_eq!(store.sheet(id).unwrap().chip_count(), 2);
    }

    #[test]
    fn a_range_that_splits_a_pair_or_is_empty_selects_nothing() {
        let mut store = store();
        let (id, ..) = mixed(&mut store);
        let sheet = store.sheet(id).unwrap();
        // The key's pair occupies units 17 and 18.
        assert!(sheet.select(0, 18).is_none());
        assert!(sheet.select(18, 2).is_none());
        assert!(sheet.select(17, 2).is_some());
        assert!(
            sheet.select(3, 0).is_none(),
            "an empty selection writes nothing"
        );
    }

    #[test]
    fn the_envelope_is_written_at_its_exact_size() {
        let mut store = store();
        let (id, ..) = mixed(&mut store);
        let (fragment, _) = store.sheet(id).unwrap().select(0, BODY).unwrap();
        let envelope = fragment.envelope();
        assert_eq!(envelope.capacity(), envelope.len());
    }

    #[test]
    fn the_envelope_reads_as_its_documented_shape() {
        let uuid = ItemId::random();
        let text = format!(
            r#"{{"version":1,"cut":"{uuid}","nodes":[{{"ink":"a \"quoted\"\nline"}},{{"ref":{{"uuid":"{uuid}"}}}}]}}"#
        );
        let read = Fragment::parse(text.as_bytes()).unwrap();
        assert_eq!(read.cut, Some(uuid));
        assert_eq!(ink(&read.nodes[0]), Some("a \"quoted\"\nline"));
        assert_eq!(reference(&read.nodes[1]), Some(uuid));
        assert_eq!(
            Fragment::parse(&read.envelope()).unwrap().nodes.len(),
            2,
            "what this build writes it reads back"
        );
    }

    #[test]
    fn an_envelope_this_build_cannot_read_is_refused_whole() {
        let uuid = ItemId::random();
        let unreadable = [
            r#"{"version":2,"nodes":[]}"#.to_string(),
            r#"{"nodes":[]}"#.to_string(),
            r#"{"version":1,"nodes":[],"extra":true}"#.to_string(),
            r#"{"version":1,"nodes":[{"image":"x"}]}"#.to_string(),
            format!(r#"{{"version":1,"nodes":[{{"ref":{{"uuid":"{uuid}","payload":"x"}}}}]}}"#),
            r#"{"version":1,"nodes":[{"ref":{"uuid":"not-a-uuid"}}]}"#.to_string(),
            r#"{"version":1,"cut":"not-a-uuid","nodes":[]}"#.to_string(),
            "not json".to_string(),
            String::new(),
        ];
        for text in unreadable {
            assert!(Fragment::parse(text.as_bytes()).is_none(), "read {text}");
        }
        assert!(Fragment::parse(&[0xff, 0xfe, b'{']).is_none(), "not UTF-8");
    }
}
