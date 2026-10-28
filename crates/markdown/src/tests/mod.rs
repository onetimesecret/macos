//! Parser level cases ported from the shell's `MarkdownParserTests` and `MarkdownSealedAtomTests`.

mod corpus;
mod definitions;
mod html;
mod json;
mod parser;
mod profile;
mod sealed_atoms;
mod tree_shapes;

use crate::{
    Alignment, Block, Dialect, Document, Event, HtmlPart, Limits, ListItem, ParseError, Trait,
    parse_with_objects,
};

pub(super) const BOTH: [Dialect; 2] = [Dialect::CommonMark, Dialect::Gfm];

/// `template` with each `{obj}` a U+FFFC, and the UTF-16 offset of each.
pub(super) fn page(template: &str) -> (String, Vec<usize>) {
    let mut text = String::new();
    let mut offsets = Vec::new();
    let mut length = 0;
    for (index, piece) in template.split("{obj}").enumerate() {
        if index > 0 {
            offsets.push(length);
            text.push('\u{FFFC}');
            length += 1;
        }
        text.push_str(piece);
        length += piece.encode_utf16().count();
    }
    (text, offsets)
}

pub(super) fn document(template: &str, dialect: Dialect) -> Result<Document, ParseError> {
    limited(template, dialect, Limits::default())
}

pub(super) fn limited(
    template: &str,
    dialect: Dialect,
    limits: Limits,
) -> Result<Document, ParseError> {
    let (text, offsets) = page(template);
    parse_with_objects(&text, &offsets, dialect, limits)
}

pub(super) fn blocks(template: &str, dialect: Dialect) -> Vec<Block> {
    match document(template, dialect) {
        Ok(document) => document.blocks,
        Err(error) => panic!("{dialect:?}: {template:?} refused: {error:?}"),
    }
}

/// The template as one paragraph of text with its objects in place, as a page with no syntax reads.
pub(super) fn plain(template: &str) -> Vec<Block> {
    vec![Block::Paragraph(plain_events(template))]
}

pub(super) fn plain_events(template: &str) -> Vec<Event> {
    let mut events = Vec::new();
    for (index, piece) in template.split("{obj}").enumerate() {
        if index > 0 {
            events.push(object(index - 1));
        }
        if !piece.is_empty() {
            events.push(text(piece));
        }
    }
    events
}

pub(super) fn text(text: &str) -> Event {
    Event::Text(text.to_owned())
}

pub(super) fn object(index: usize) -> Event {
    Event::Object(index.to_string())
}

pub(super) fn enter(style: Trait) -> Event {
    Event::EnterMarkdown(style)
}

pub(super) fn leave(style: Trait) -> Event {
    Event::LeaveMarkdown(style)
}

pub(super) fn part(text: &str) -> HtmlPart {
    HtmlPart::Text(text.to_owned())
}

pub(super) fn part_object(index: usize) -> HtmlPart {
    HtmlPart::Object(index.to_string())
}

/// A text part, or none for an empty address.
pub(super) fn parts(text: &str) -> Vec<HtmlPart> {
    if text.is_empty() {
        Vec::new()
    } else {
        vec![part(text)]
    }
}

pub(super) fn link(destination: &str, title: &str) -> Event {
    Event::EnterLink {
        destination: parts(destination),
        title: parts(title),
    }
}

pub(super) fn autolink(destination: &str, label: &str) -> Vec<Event> {
    vec![link(destination, ""), text(label), Event::LeaveLink]
}

pub(super) fn image(alt: Vec<HtmlPart>, destination: Vec<HtmlPart>, title: Vec<HtmlPart>) -> Event {
    Event::MarkdownImage {
        alt,
        destination,
        title,
    }
}

pub(super) fn paragraph(events: Vec<Event>) -> Block {
    Block::Paragraph(events)
}

pub(super) fn objects(indices: &[usize]) -> Block {
    Block::Objects(indices.iter().map(usize::to_string).collect())
}

pub(super) fn item(task: Option<bool>, blocks: Vec<Block>) -> ListItem {
    ListItem { task, blocks }
}

pub(super) fn bullets(tight: bool, items: Vec<ListItem>) -> Block {
    Block::List {
        ordered: false,
        start: 0,
        tight,
        items,
    }
}

pub(super) fn table(
    alignments: Vec<Option<Alignment>>,
    header: Vec<Vec<Event>>,
    body: Vec<Vec<Vec<Event>>>,
) -> Block {
    Block::Table {
        alignments,
        header,
        body,
    }
}

/// Every object identity in `blocks`, in document order.
pub(super) fn identities(blocks: &[Block]) -> Vec<String> {
    fn of_parts(parts: &[HtmlPart]) -> impl Iterator<Item = String> + '_ {
        parts.iter().filter_map(|part| match part {
            HtmlPart::Object(identity) => Some(identity.clone()),
            HtmlPart::Text(_) => None,
        })
    }
    fn of_events(events: &[Event]) -> Vec<String> {
        events
            .iter()
            .flat_map(|event| -> Vec<String> {
                match event {
                    Event::Object(identity) => vec![identity.clone()],
                    Event::RawHtml(parts) => of_parts(parts).collect(),
                    Event::MarkdownImage {
                        alt,
                        destination,
                        title,
                    } => of_parts(alt)
                        .chain(of_parts(destination))
                        .chain(of_parts(title))
                        .collect(),
                    Event::EnterLink { destination, title } => {
                        of_parts(destination).chain(of_parts(title)).collect()
                    }
                    _ => Vec::new(),
                }
            })
            .collect()
    }
    blocks
        .iter()
        .flat_map(|block| -> Vec<String> {
            match block {
                Block::Paragraph(events) | Block::Heading { events, .. } => of_events(events),
                Block::CodeBlock { info, literal } => {
                    of_parts(info).chain(of_parts(literal)).collect()
                }
                Block::Html(parts) => of_parts(parts).collect(),
                Block::ThematicBreak => Vec::new(),
                Block::Quote(children) => identities(children),
                Block::List { items, .. } => items
                    .iter()
                    .flat_map(|item| identities(&item.blocks))
                    .collect(),
                Block::Table { header, body, .. } => header
                    .iter()
                    .chain(body.iter().flatten())
                    .flat_map(|cell| of_events(cell))
                    .collect(),
                Block::Objects(objects) => objects.clone(),
            }
        })
        .collect()
}
