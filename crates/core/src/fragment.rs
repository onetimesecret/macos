//! The sealed fragment (Law 0001; ADR-0045 point 1): a selection's
//! ordered ink and object references, composed and read only here, never payload.

use std::borrow::Cow;
use std::collections::HashSet;
use std::io::{self, Write};

use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::document::strip_sentinels;
use crate::files::FILE_SIZE_LIMIT;
use crate::note::Note;
use crate::sheet::{ItemId, SealedChip, Segment, Sheet};

/// The one envelope version this build writes and reads.
pub(crate) const VERSION: u32 = 1;

/// The longest envelope this build reads: twice the largest file it opens
/// (core interface, Envelope, version 1).
pub(crate) const ENVELOPE_CAP: usize = 2 * FILE_SIZE_LIMIT;

/// The most references one envelope may name (Law 0001, paste row).
pub(crate) const REFERENCE_CAP: usize = 1024;

/// An envelope cap the parse holds an envelope to (Law 0001, paste row), and
/// the copy and the cut too (Law 0001, copy row and cut row).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnvelopeCap {
    /// Its length in bytes, [`EnvelopeCap::limit`] at most.
    Length,
    /// The references it names, [`EnvelopeCap::limit`] at most.
    References,
}

impl EnvelopeCap {
    /// The cap an envelope of `bytes` naming `references` passes, its
    /// length first; `None` within both.
    pub(crate) fn passed(bytes: usize, references: usize) -> Option<Self> {
        if bytes > ENVELOPE_CAP {
            Some(Self::Length)
        } else if references > REFERENCE_CAP {
            Some(Self::References)
        } else {
            None
        }
    }

    /// The most this cap allows: bytes, or references.
    #[must_use]
    pub const fn limit(self) -> usize {
        match self {
            Self::Length => ENVELOPE_CAP,
            Self::References => REFERENCE_CAP,
        }
    }
}

/// Why a copy or a cut composed nothing and changed nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CopyRefusal {
    /// An unknown page, one past its deadline (Law 0001, expiry row), a range
    /// [`Sheet::select`] refuses, or a cut the body refused.
    Refused,
    /// The envelope would pass a cap (Law 0001, copy row and cut row).
    PastCap(EnvelopeCap),
}

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
    /// The object's typed name, ink, a wiping owner (issue #247; Law 0004, C19).
    pub(crate) name: Option<Zeroizing<String>>,
    /// The object's note, ink, never empty (issue #247).
    pub(crate) note: Option<Zeroizing<String>>,
}

impl Reference {
    fn of(chip: &SealedChip) -> Self {
        Self {
            uuid: chip.uuid,
            name: chip.name.clone(),
            note: chip
                .note
                .as_ref()
                .map(Note::text)
                .filter(|text| !text.is_empty()),
        }
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
    /// final size (Law 0004); the cap it would pass, before any buffer.
    pub(crate) fn envelope(&self) -> Result<Zeroizing<Vec<u8>>, EnvelopeCap> {
        let cut = self.cut.map(|cut| cut.to_string());
        let nodes: Vec<WireNode<'_>> = self
            .nodes
            .iter()
            .map(|node| match node {
                Node::Ink(text) => WireNode::Ink(Cow::Borrowed(text.as_str())),
                Node::Ref(reference) => WireNode::Ref(WireRef {
                    uuid: reference.uuid.to_string(),
                    name: reference
                        .name
                        .as_ref()
                        .map(|name| Cow::Borrowed(name.as_str())),
                    note: reference
                        .note
                        .as_ref()
                        .map(|text| Cow::Borrowed(text.as_str())),
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
        if let Some(cap) = EnvelopeCap::passed(sizer.0, self.references().count()) {
            return Err(cap);
        }
        let mut out = Zeroizing::new(Vec::with_capacity(sizer.0));
        serde_json::to_writer(&mut *out, &wire).expect("a fragment always encodes");
        debug_assert_eq!(out.len(), sizer.0, "sizing pass drifted from the write");
        Ok(out)
    }

    /// Read an envelope. `None` when this build cannot: another version, an
    /// unknown key, a malformed UUID, bytes that are not UTF-8 JSON, past a
    /// cap, or naming one object twice (Law 0001, paste row).
    pub(crate) fn parse(bytes: &[u8]) -> Option<Self> {
        if EnvelopeCap::passed(bytes.len(), 0).is_some() {
            return None;
        }
        let wire: WireFragment<'_> = serde_json::from_slice(bytes).ok()?;
        if wire.version != VERSION {
            return None;
        }
        let cut = match wire.cut {
            None => None,
            Some(text) => Some(ItemId::parse(&text)?),
        };
        let mut nodes = Vec::with_capacity(wire.nodes.len());
        let mut named: HashSet<ItemId> = HashSet::new();
        for node in wire.nodes {
            match node {
                WireNode::Ink(text) => {
                    if let Some(ink) = ink_of(text) {
                        nodes.push(Node::Ink(ink));
                    }
                }
                WireNode::Ref(reference) => {
                    let uuid = ItemId::parse(&reference.uuid)?;
                    // A second naming of one object would clone it twice (Law 0001, paste row).
                    if !named.insert(uuid)
                        || EnvelopeCap::passed(bytes.len(), named.len()).is_some()
                    {
                        return None;
                    }
                    nodes.push(Node::Ref(Reference {
                        uuid,
                        name: reference
                            .name
                            .filter(|name| !name.is_empty())
                            .map(|name| Zeroizing::new(name.into_owned())),
                        note: reference.note.and_then(ink_of),
                    }));
                }
            }
        }
        Some(Self { cut, nodes })
    }
}

/// An envelope's ink or note as wipeable text without the chip sentinel, which a
/// page or a note keeps for its chips alone (Law 0001); `None` when none is left.
pub(crate) fn ink_of(text: Cow<'_, str>) -> Option<Zeroizing<String>> {
    if text.is_empty() {
        return None;
    }
    // An escaped string was already owned; the rest copy at size.
    let mut ink = Zeroizing::new(text.into_owned());
    strip_sentinels(&mut ink);
    (!ink.is_empty()).then_some(ink)
}

impl Sheet {
    /// A UTF-16 range as a fragment and its public text, from one walk; `None`
    /// for an empty range, one past the body or one splitting a surrogate pair.
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
                        sizes.push(size_word(chip));
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

    /// Runs the shell shows of this page, a preview's rendered text between
    /// its objects and each object by chip id, as a fragment and its public
    /// text; `None` for no ink and no object, or an object off this page.
    /// The shown text is the ink (Law 0001, the preview's rows).
    pub(crate) fn compose(&self, shown: &[Segment]) -> Option<(Fragment, Zeroizing<String>)> {
        let mut nodes = Vec::with_capacity(shown.len());
        let mut sizes: Vec<&str> = Vec::new();
        for run in shown {
            match run {
                Segment::Ink(text) => {
                    if let Some(ink) = ink_of(Cow::Borrowed(text.as_str())) {
                        nodes.push(Node::Ink(ink));
                    }
                }
                Segment::Chip(id) => {
                    let chip = self.chip(*id)?;
                    nodes.push(Node::Ref(Reference::of(chip)));
                    sizes.push(size_word(chip));
                }
            }
        }
        if nodes.is_empty() {
            return None;
        }
        let plain = public_text(&nodes, &sizes);
        Some((Fragment { cut: None, nodes }, plain))
    }
}

/// A reference's placeholder word: its size class, or `unavailable` for a
/// record with no value whose size class is not known.
fn size_word(chip: &SealedChip) -> &str {
    match chip.size_label() {
        "" => "unavailable",
        label => label,
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

/// The envelope as JSON (core interface, Envelope, version 1).
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
    Ref(#[serde(borrow)] WireRef<'a>),
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireRef<'a> {
    uuid: String,
    #[serde(default, borrow, skip_serializing_if = "Option::is_none")]
    name: Option<Cow<'a, str>>,
    #[serde(default, borrow, skip_serializing_if = "Option::is_none")]
    note: Option<Cow<'a, str>>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;

    /// Compiles only for a type that wipes on drop: the pin the owner test rests on.
    fn wiping_owner<T: zeroize::ZeroizeOnDrop>(_: &T) {}
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
        let read = Fragment::parse(&fragment.envelope().unwrap()).unwrap();
        assert_eq!(read.nodes.len(), 5);
        assert_eq!(ink(&read.nodes[0]), Some("before "));
        assert_eq!(reference(&read.nodes[1]), Some(uuid(&store, id, a)));
        assert_eq!(ink(&read.nodes[2]), Some(" between \u{1F511} "));
        assert_eq!(reference(&read.nodes[3]), Some(uuid(&store, id, b)));
        assert_eq!(ink(&read.nodes[4]), Some(" after"));
        assert_eq!(read.cut, None, "a copy names no cut");
    }

    #[test]
    fn a_shown_selection_composes_as_the_pages_own_would() {
        let mut store = store();
        let (id, a, b) = mixed(&mut store);
        let sheet = store.sheet(id).unwrap();
        let (selected, plain) = sheet.select(0, BODY).unwrap();
        let shown = [
            Segment::Ink("before ".into()),
            Segment::Chip(a),
            Segment::Ink(" between \u{1F511} ".into()),
            Segment::Chip(b),
            Segment::Ink(" after".into()),
        ];
        let (composed, shown_plain) = sheet.compose(&shown).unwrap();
        assert_eq!(*composed.envelope().unwrap(), *selected.envelope().unwrap());
        assert_eq!(shown_plain.as_str(), plain.as_str());

        let rendered = [Segment::Ink("Heading\nbody ".into()), Segment::Chip(a)];
        let (fragment, plain) = sheet.compose(&rendered).unwrap();
        assert_eq!(
            ink(&fragment.nodes[0]),
            Some("Heading\nbody "),
            "the shown text is the ink"
        );
        assert_eq!(reference(&fragment.nodes[1]), Some(uuid(&store, id, a)));
        assert_eq!(plain.as_str(), "Heading\nbody [sealed content \u{b7} tiny]");
        assert_eq!(fragment.cut, None, "a composition names no cut");
    }

    #[test]
    fn a_shown_selection_naming_an_object_off_the_page_composes_nothing() {
        let mut store = store();
        let (id, a, _) = mixed(&mut store);
        let other = store.new_tab().1;
        let shown = [Segment::Ink("x".into()), Segment::Chip(a)];
        assert!(store.sheet(other).unwrap().compose(&shown).is_none());
        let sheet = store.sheet(id).unwrap();
        assert!(sheet.compose(&shown).is_some(), "the control: its own page");
        assert!(sheet.compose(&[]).is_none(), "nothing shown");
        assert!(
            sheet.compose(&[Segment::Ink(String::new())]).is_none(),
            "empty ink alone"
        );
        let (fragment, _) = sheet
            .compose(&[Segment::Ink("a\u{FFFC}b".into()), Segment::Chip(a)])
            .unwrap();
        assert_eq!(
            ink(&fragment.nodes[0]),
            Some("ab"),
            "a stray sentinel leaves the ink"
        );
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
        let envelope = fragment.envelope().unwrap();
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
        assert_eq!(
            store.copy_fragment(SheetId::from_raw(4_242), 0, 1).err(),
            Some(CopyRefusal::Refused)
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
        let envelope = fragment.envelope().unwrap();
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
            Fragment::parse(&read.envelope().unwrap())
                .unwrap()
                .nodes
                .len(),
            2,
            "what this build writes it reads back"
        );
    }

    fn named(store: &mut SheetStore<ManualClock>, id: SheetId, chip: ChipId) {
        store.set_chip_name(chip, "API_KEY").unwrap();
        assert!(store.apply_note_ops(
            chip,
            &[crate::store::EditOp::Insert {
                pos_u16: 0,
                text: "rotate \"monthly\"\nthen \u{1F511}".into(),
            }],
            crate::document::EditIntent::Typing,
            None,
        ));
        assert!(store.sheet(id).unwrap().chip(chip).unwrap().has_note());
    }

    fn name_and_note(node: &Node) -> (Option<&str>, Option<&str>) {
        match node {
            Node::Ref(reference) => (
                reference.name.as_deref().map(String::as_str),
                reference.note.as_deref().map(String::as_str),
            ),
            Node::Ink(_) => panic!("not a reference"),
        }
    }

    /// A parsed reference's name and note are wiping owners (Law 0004, C19): a plain
    /// `String` in either field would not compile here.
    #[test]
    fn a_references_name_and_note_are_wiping_owners() {
        let mut store = store();
        let (id, a, _) = mixed(&mut store);
        named(&mut store, id, a);
        let (fragment, _) = store.sheet(id).unwrap().select(0, BODY).unwrap();
        let read = Fragment::parse(&fragment.envelope().unwrap()).unwrap();
        let Node::Ref(reference) = &read.nodes[1] else {
            panic!("not a reference")
        };
        wiping_owner(reference.name.as_ref().unwrap());
        wiping_owner(reference.note.as_ref().unwrap());
    }

    #[test]
    fn the_envelope_round_trips_with_and_without_a_name_and_a_note() {
        let mut store = store();
        let (id, a, _) = mixed(&mut store);
        named(&mut store, id, a);
        let (fragment, _) = store.sheet(id).unwrap().select(0, BODY).unwrap();
        let read = Fragment::parse(&fragment.envelope().unwrap()).unwrap();
        assert_eq!(
            name_and_note(&read.nodes[1]),
            (Some("API_KEY"), Some("rotate \"monthly\"\nthen \u{1F511}"))
        );
        assert_eq!(name_and_note(&read.nodes[3]), (None, None), "B has neither");
        let text = String::from_utf8(fragment.envelope().unwrap().to_vec()).unwrap();
        assert_eq!(
            text.matches("\"name\"").count(),
            1,
            "absent, not null, when unnamed"
        );
        assert_eq!(text.matches("\"note\"").count(), 1);
    }

    #[test]
    fn the_public_text_names_neither_the_name_nor_the_note() {
        let mut store = store();
        let (id, a, _) = mixed(&mut store);
        named(&mut store, id, a);
        let (_, plain) = store.sheet(id).unwrap().select(0, BODY).unwrap();
        assert!(!plain.contains("API_KEY"));
        assert!(!plain.contains("monthly"));
        assert!(plain.contains("[sealed content \u{b7} tiny]"));
    }

    #[test]
    fn an_empty_name_or_note_reads_as_none() {
        let uuid = ItemId::random();
        let text = format!(
            r#"{{"version":1,"nodes":[{{"ref":{{"uuid":"{uuid}","name":"","note":""}}}}]}}"#
        );
        let read = Fragment::parse(text.as_bytes()).unwrap();
        assert_eq!(name_and_note(&read.nodes[0]), (None, None));
    }

    #[test]
    fn an_envelopes_ink_and_note_read_without_the_chip_sentinel() {
        let (uuid, other, s) = (ItemId::random(), ItemId::random(), '\u{FFFC}');
        // The quoted ink is owned once decoded, so both of `ink_of`'s paths run.
        let text = format!(
            r#"{{"version":1,"nodes":[{{"ink":"a{s}b"}},{{"ink":"\"{s}"}},{{"ink":"{s}"}},{{"ref":{{"uuid":"{uuid}","note":"n{s}"}}}},{{"ref":{{"uuid":"{other}","note":"{s}"}}}}]}}"#
        );
        let read = Fragment::parse(text.as_bytes()).unwrap();
        assert_eq!(
            read.nodes.len(),
            4,
            "ink of the sentinel alone stayed a node"
        );
        assert_eq!(ink(&read.nodes[0]), Some("ab"));
        assert_eq!(ink(&read.nodes[1]), Some("\""));
        assert_eq!(name_and_note(&read.nodes[2]), (None, Some("n")));
        assert_eq!(name_and_note(&read.nodes[3]), (None, None));
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

    fn naming(uuids: &[ItemId]) -> String {
        let nodes: Vec<String> = uuids
            .iter()
            .map(|uuid| format!(r#"{{"ref":{{"uuid":"{uuid}"}}}}"#))
            .collect();
        format!(r#"{{"version":1,"nodes":[{}]}}"#, nodes.join(","))
    }

    #[test]
    fn an_envelope_past_a_cap_or_naming_one_object_twice_is_refused_whole() {
        let at_cap: Vec<ItemId> = (0..REFERENCE_CAP).map(|_| ItemId::random()).collect();
        let read = Fragment::parse(naming(&at_cap).as_bytes()).unwrap();
        assert_eq!(read.references().count(), REFERENCE_CAP);
        let mut past = at_cap.clone();
        past.push(ItemId::random());
        assert!(
            Fragment::parse(naming(&past).as_bytes()).is_none(),
            "one past the cap"
        );

        let uuid = ItemId::random();
        assert!(
            Fragment::parse(naming(&[uuid, uuid]).as_bytes()).is_none(),
            "named twice"
        );

        let frame = r#"{"version":1,"nodes":[{"ink":""}]}"#.len();
        let ink = |len: usize| {
            format!(
                r#"{{"version":1,"nodes":[{{"ink":"{}"}}]}}"#,
                "x".repeat(len - frame)
            )
        };
        assert_eq!(ink(ENVELOPE_CAP).len(), ENVELOPE_CAP);
        assert!(Fragment::parse(ink(ENVELOPE_CAP).as_bytes()).is_some());
        assert!(
            Fragment::parse(ink(ENVELOPE_CAP + 1).as_bytes()).is_none(),
            "one byte past"
        );
    }

    fn naming_fragment(count: usize) -> Fragment {
        let nodes = (0..count)
            .map(|_| {
                Node::Ref(Reference {
                    uuid: ItemId::random(),
                    name: None,
                    note: None,
                })
            })
            .collect();
        Fragment { cut: None, nodes }
    }

    /// Ink of `len` bytes, then one reference, as a copy would compose it.
    fn ink_fragment(len: usize) -> Fragment {
        let mut fragment = naming_fragment(1);
        let text = Zeroizing::new("x".repeat(len));
        fragment.nodes.insert(0, Node::Ink(text));
        fragment
    }

    #[test]
    fn an_envelope_composed_at_a_cap_reads_back_and_one_past_composes_nothing() {
        let at_cap = naming_fragment(REFERENCE_CAP).envelope().unwrap();
        let read = Fragment::parse(&at_cap).unwrap();
        assert_eq!(read.references().count(), REFERENCE_CAP);
        assert_eq!(
            naming_fragment(REFERENCE_CAP + 1).envelope().err(),
            Some(EnvelopeCap::References)
        );

        let frame = ink_fragment(0).envelope().unwrap().len();
        let longest = ink_fragment(ENVELOPE_CAP - frame).envelope().unwrap();
        assert_eq!(longest.len(), ENVELOPE_CAP);
        assert!(
            Fragment::parse(&longest).is_some(),
            "what it writes it reads"
        );
        assert_eq!(
            ink_fragment(ENVELOPE_CAP - frame + 1).envelope().err(),
            Some(EnvelopeCap::Length),
            "one byte past"
        );
        assert_eq!(EnvelopeCap::Length.limit(), 8 * 1024 * 1024);
        assert_eq!(EnvelopeCap::References.limit(), 1024);
    }
}
