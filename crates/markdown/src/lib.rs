//! The rendered page preview's Markdown reader (plan R1, issue 332): `CommonMark` or GFM by comrak,
//! each sealed object a plane 16 placeholder while it parses and an atom in the document after.

mod cells;
mod document;
mod source;
mod walker;

#[cfg(test)]
mod tests;

use comrak::{Arena, Options, parse_document};
use serde::Serialize;

pub use document::{Alignment, Atom, Block, Document, Event, HtmlPart, ListItem, Trait};

use document::{empty, unlabelled};
use source::Source;

/// The largest nesting limit accepted by the document walker.
pub const MAXIMUM_DEPTH: usize = 64;

/// The Markdown dialect a page is read under.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Dialect {
    /// `CommonMark` 0.31.2, every extension off.
    CommonMark,
    /// GitHub Flavored Markdown: tables, strikethrough, extended autolinks and task list items.
    Gfm,
}

/// Bounds on the work one page may ask for, as the composer's `CompositionLimits` sets them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    /// Unicode scalars in the page.
    pub maximum_input_scalars: usize,
    /// Block quotes, lists and inline containers, capped at [`MAXIMUM_DEPTH`].
    pub maximum_depth: usize,
    /// Every table of a page together, header rows and padding included.
    pub maximum_table_cells: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            maximum_input_scalars: 1_000_000,
            maximum_depth: MAXIMUM_DEPTH,
            maximum_table_cells: 100_000,
        }
    }
}

/// Why a page was refused; the preview then shows it as plain text.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ParseError {
    /// The page has more scalars than `Limits::maximum_input_scalars`.
    #[serde(serialize_with = "empty")]
    InputLimit,
    /// The page nests deeper than `Limits::maximum_depth` or [`MAXIMUM_DEPTH`].
    #[serde(serialize_with = "empty")]
    DepthLimit,
    /// The page's tables could make more cells than `Limits::maximum_table_cells`.
    #[serde(serialize_with = "empty")]
    TableCellLimit,
    /// No run of plane 16 scalars, one per object, avoids the page's own plane 16 scalars and
    /// numeric character reference values.
    #[serde(serialize_with = "empty")]
    NoPlaceholderWindow,
    /// An object offset out of ascending order, or at no U+FFFC of the page.
    #[serde(serialize_with = "empty")]
    ObjectOffset,
    /// The tree had a shape comrak never builds.
    #[serde(serialize_with = "empty")]
    ParserFailure,
    /// The walk refused a second emission, including reference-definition cases where stock
    /// comrak leaves definition lines inside a surviving paragraph's source range.
    #[serde(serialize_with = "unlabelled")]
    DuplicateObject(String),
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InputLimit => formatter.write_str("the page is over the input limit"),
            Self::DepthLimit => formatter.write_str("the page nests past the depth limit"),
            Self::TableCellLimit => {
                formatter.write_str("the page's tables are over the cell budget")
            }
            Self::NoPlaceholderWindow => formatter.write_str("no placeholder window fits the page"),
            Self::ObjectOffset => formatter.write_str("an object offset names no object"),
            Self::ParserFailure => formatter.write_str("the parser built an unexpected tree"),
            Self::DuplicateObject(identity) => write!(formatter, "object {identity} appears twice"),
        }
    }
}

impl std::error::Error for ParseError {}

/// `text` read under `dialect`, as a page with no sealed objects.
pub fn parse(text: &str, dialect: Dialect, limits: Limits) -> Result<Document, ParseError> {
    parse_with_objects(text, &[], dialect, limits)
}

/// `text` read under `dialect`; `objects` are the UTF-16 offsets in `text` of the U+FFFC
/// characters that are sealed objects, ascending. Object i's identity is i in decimal.
pub fn parse_with_objects(
    text: &str,
    objects: &[usize],
    dialect: Dialect,
    limits: Limits,
) -> Result<Document, ParseError> {
    let source = Source::new(text, objects, &limits)?;
    if dialect == Dialect::Gfm && cells::bound(&source.text) > limits.maximum_table_cells {
        return Err(ParseError::TableCellLimit);
    }
    let arena = Arena::new();
    let root = parse_document(&arena, &source.text, &options(dialect));
    if dialect == Dialect::Gfm && cells::exceeds_limit(root, limits.maximum_table_cells) {
        return Err(ParseError::TableCellLimit);
    }
    let blocks = walker::walk(root, &source, limits.maximum_depth.min(MAXIMUM_DEPTH))?;
    Ok(Document {
        blocks,
        atoms: source.atoms,
    })
}

/// comrak's options for `dialect`: every extension off but GFM's four.
fn options(dialect: Dialect) -> Options<'static> {
    let mut options = Options::default();
    if dialect == Dialect::Gfm {
        options.extension.table = true;
        options.extension.strikethrough = true;
        options.extension.autolink = true;
        options.extension.tasklist = true;
    }
    options
}
