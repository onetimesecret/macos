//! The page in the shape of the shell's `MarkdownDocument` types, in the JSON Swift synthesizes for
//! `Codable` enums (SE-0295): `{"case": {"label": v, "_0": v}}`, and `{}` for a case with none.

use serde::ser::SerializeMap;
use serde::{Serialize, Serializer};

/// A page read by its dialect, each sealed object an atom.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Document {
    /// The page's blocks in source order.
    pub blocks: Vec<Block>,
    /// Every object of the page in source order.
    pub atoms: Vec<Atom>,
}

/// An object's identity in the document's events and its UTF-16 offset in the page.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Atom {
    /// The object's index in the page, written in decimal.
    pub identity: String,
    /// Where the object's U+FFFC stands in the page, in UTF-16 code units.
    pub offset: usize,
}

/// A table column's alignment.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Alignment {
    /// `:-`
    #[serde(serialize_with = "empty")]
    Left,
    /// `:-:`
    #[serde(serialize_with = "empty")]
    Center,
    /// `-:`
    #[serde(serialize_with = "empty")]
    Right,
}

/// One list item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ListItem {
    /// Whether a task item's box is checked; `None` for an ordinary item.
    pub task: Option<bool>,
    /// The item's blocks.
    pub blocks: Vec<Block>,
}

/// A block of the page.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Block {
    /// A paragraph's inline events.
    #[serde(serialize_with = "unlabelled")]
    Paragraph(Vec<Event>),
    /// An ATX or setext heading.
    Heading {
        /// One to six.
        level: u8,
        /// The heading's inline events.
        #[serde(rename = "_1")]
        events: Vec<Event>,
    },
    /// A fenced or indented code block.
    CodeBlock {
        /// A fenced block's info string, empty for an indented block.
        info: Vec<HtmlPart>,
        /// The block's text.
        literal: Vec<HtmlPart>,
    },
    /// An HTML block's raw source.
    #[serde(serialize_with = "unlabelled")]
    Html(Vec<HtmlPart>),
    /// A thematic break.
    #[serde(serialize_with = "empty")]
    ThematicBreak,
    /// A block quote's blocks.
    #[serde(serialize_with = "unlabelled")]
    Quote(Vec<Block>),
    /// A bullet or ordered list.
    List {
        /// Whether the list is ordered.
        ordered: bool,
        /// An ordered list's first number, 0 for a bullet list.
        start: usize,
        /// Whether no blank line separates the items or their blocks.
        tight: bool,
        /// The list's items.
        items: Vec<ListItem>,
    },
    /// A GFM table; each row has the cells the parser kept, each cell its events.
    Table {
        /// One alignment per column.
        alignments: Vec<Option<Alignment>>,
        /// The header row's cells.
        header: Vec<Vec<Event>>,
        /// The body rows.
        body: Vec<Vec<Vec<Event>>>,
    },
    /// Objects with no element of their own, placed by source position.
    #[serde(serialize_with = "unlabelled")]
    Objects(Vec<String>),
}

/// A style a Markdown construct gives the text inside it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Trait {
    /// `*a*`
    #[serde(serialize_with = "empty")]
    Emphasis,
    /// `**a**`
    #[serde(serialize_with = "empty")]
    Strong,
    /// GFM's `~a~`
    #[serde(serialize_with = "empty")]
    Deletion,
    /// `` `a` ``
    #[serde(serialize_with = "empty")]
    Code,
}

/// One inline event of a paragraph, heading or table cell.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Event {
    /// Text the parser has already decoded.
    #[serde(serialize_with = "unlabelled")]
    Text(String),
    /// A sealed object by identity.
    #[serde(serialize_with = "unlabelled")]
    Object(String),
    /// A style opens.
    #[serde(serialize_with = "unlabelled")]
    EnterMarkdown(Trait),
    /// A style closes.
    #[serde(serialize_with = "unlabelled")]
    LeaveMarkdown(Trait),
    /// A soft line break.
    #[serde(serialize_with = "empty")]
    SoftBreak,
    /// A hard line break.
    #[serde(serialize_with = "empty")]
    HardBreak,
    /// Inline raw HTML.
    #[serde(rename = "rawHTML", serialize_with = "unlabelled")]
    RawHtml(Vec<HtmlPart>),
    /// A Markdown image; objects its alt text did not show stay in its address.
    MarkdownImage {
        /// The description as text, code and raw HTML literals.
        alt: Vec<HtmlPart>,
        /// The image's address.
        destination: Vec<HtmlPart>,
        /// The image's title.
        title: Vec<HtmlPart>,
    },
    /// A Markdown link opens; each object of its address is a U+FFFC stand-in.
    EnterLink {
        /// The link's address.
        destination: Vec<HtmlPart>,
        /// The link's title.
        title: Vec<HtmlPart>,
    },
    /// The innermost open link closes.
    #[serde(serialize_with = "empty")]
    LeaveLink,
}

/// Raw source split at sealed objects.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HtmlPart {
    /// Literal text.
    #[serde(serialize_with = "unlabelled")]
    Text(String),
    /// A sealed object by identity.
    #[serde(serialize_with = "unlabelled")]
    Object(String),
}

/// A Swift case with no values: an empty object under the case's name.
pub(crate) fn empty<S: Serializer>(serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_map(Some(0))?.end()
}

/// A Swift case with one unlabelled value, which Swift keys `_0`.
pub(crate) fn unlabelled<T: Serialize, S: Serializer>(
    value: &T,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    let mut map = serializer.serialize_map(Some(1))?;
    map.serialize_entry("_0", value)?;
    map.end()
}

pub(crate) trait PartsExt {
    /// Appends text, joined in place to a text part before it.
    fn append_text(&mut self, text: &str);
    /// Appends each part, joining text as `append_text` does.
    fn append_parts(&mut self, parts: &[HtmlPart]);
}

impl PartsExt for Vec<HtmlPart> {
    fn append_text(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        if let Some(HtmlPart::Text(joined)) = self.last_mut() {
            joined.push_str(text);
        } else {
            self.push(HtmlPart::Text(text.to_owned()));
        }
    }

    fn append_parts(&mut self, parts: &[HtmlPart]) {
        for part in parts {
            match part {
                HtmlPart::Text(text) => self.append_text(text),
                HtmlPart::Object(_) => self.push(part.clone()),
            }
        }
    }
}

impl PartsExt for Vec<Event> {
    fn append_text(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        if let Some(Event::Text(joined)) = self.last_mut() {
            joined.push_str(text);
        } else {
            self.push(Event::Text(text.to_owned()));
        }
    }

    fn append_parts(&mut self, parts: &[HtmlPart]) {
        for part in parts {
            match part {
                HtmlPart::Text(text) => self.append_text(text),
                HtmlPart::Object(identity) => self.push(Event::Object(identity.clone())),
            }
        }
    }
}

/// Each object as U+FFFC, the stand-in the composer refuses in an address.
pub(crate) fn standing_in(parts: &[HtmlPart]) -> Vec<HtmlPart> {
    let mut joined = Vec::new();
    for part in parts {
        match part {
            HtmlPart::Text(text) => joined.append_text(text),
            HtmlPart::Object(_) => joined.append_text("\u{FFFC}"),
        }
    }
    joined
}

/// The object parts of `parts`, in order.
pub(crate) fn objects_of(parts: &[HtmlPart]) -> impl Iterator<Item = &HtmlPart> {
    parts
        .iter()
        .filter(|part| matches!(part, HtmlPart::Object(_)))
}
