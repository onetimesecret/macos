//! One walk over comrak's tree: each object goes where plan R1's ownership rules put it, then
//! the objects no node emitted are placed by block source position.

use std::collections::{BTreeMap, HashSet};

use comrak::nodes::{AstNode, ListType, NodeValue, Sourcepos, TableAlignment};

use crate::document::{PartsExt, objects_of, standing_in};
use crate::source::{Piece, Position, Source};
use crate::{Alignment, Block, Event, HtmlPart, ListItem, ParseError, Trait};

type Node<'a> = &'a AstNode<'a>;

pub(crate) fn walk<'a>(
    root: Node<'a>,
    source: &Source,
    maximum_depth: usize,
) -> Result<Vec<Block>, ParseError> {
    let definitions = definitions(root, &source.positions);
    let mut walker = Walker {
        source,
        maximum_depth,
        definitions,
        emitted: vec![false; source.object_count()],
        log: Vec::new(),
        depth: 0,
    };
    let mut blocks = walker.blocks(root)?;
    let unplaced: Vec<Unplaced> = (0..source.object_count())
        .filter(|&atom| !walker.emitted[atom])
        .map(|atom| Unplaced {
            identity: atom.to_string(),
            position: source.positions[atom],
        })
        .collect();
    place(unplaced, &mut blocks);
    Ok(blocks.into_iter().map(Placed::into_block).collect())
}

/// Per object, whether no leaf block's span covers it, plan R1's mark of a definition's object.
fn definitions<'a>(root: Node<'a>, positions: &[Position]) -> Vec<bool> {
    let mut spans: Vec<(Position, Position)> = root
        .descendants()
        .filter_map(|node| {
            let data = node.data();
            let leaf = data.value.block()
                && !matches!(
                    data.value,
                    NodeValue::Document
                        | NodeValue::BlockQuote
                        | NodeValue::List(_)
                        | NodeValue::Item(_)
                        | NodeValue::TaskItem(_)
                );
            let (start, end) = span(data.sourcepos);
            (leaf && start <= end).then_some((start, end))
        })
        .collect();
    spans.sort_unstable();
    let mut merged: Vec<(Position, Position)> = Vec::with_capacity(spans.len());
    for (start, end) in spans {
        match merged.last_mut() {
            Some(last) if start <= last.1 => last.1 = last.1.max(end),
            _ => merged.push((start, end)),
        }
    }
    // A sweep, so `positions` must ascend, as `Source` records them in source order.
    let mut next = 0;
    positions
        .iter()
        .map(|&position| {
            while next < merged.len() && merged[next].1 < position {
                next += 1;
            }
            merged.get(next).is_none_or(|&(start, _)| position < start)
        })
        .collect()
}

fn span(sourcepos: Sourcepos) -> (Position, Position) {
    (
        Position {
            line: sourcepos.start.line,
            column: sourcepos.start.column,
        },
        Position {
            line: sourcepos.end.line,
            column: sourcepos.end.column,
        },
    )
}

/// A block and its source span, kept until every object the walk left out has a place.
struct Placed {
    shape: Shape,
    start: Position,
    end: Position,
}

enum Shape {
    Leaf(Block),
    Quote(Vec<Placed>),
    List {
        ordered: bool,
        start: usize,
        tight: bool,
        items: Vec<PlacedItem>,
    },
    /// `rows` are the first and last source lines of each of `body`'s rows.
    Table {
        alignments: Vec<Option<Alignment>>,
        header: Vec<Vec<Event>>,
        body: Vec<Vec<Vec<Event>>>,
        rows: Vec<(usize, usize)>,
    },
}

struct PlacedItem {
    task: Option<bool>,
    blocks: Vec<Placed>,
    start: Position,
}

impl Placed {
    fn into_block(self) -> Block {
        match self.shape {
            Shape::Leaf(block) => block,
            Shape::Quote(children) => {
                Block::Quote(children.into_iter().map(Self::into_block).collect())
            }
            Shape::List {
                ordered,
                start,
                tight,
                items,
            } => Block::List {
                ordered,
                start,
                tight,
                items: items
                    .into_iter()
                    .map(|item| ListItem {
                        task: item.task,
                        blocks: item.blocks.into_iter().map(Self::into_block).collect(),
                    })
                    .collect(),
            },
            Shape::Table {
                alignments,
                header,
                body,
                ..
            } => Block::Table {
                alignments,
                header,
                body,
            },
        }
    }
}

struct Walker<'s> {
    source: &'s Source,
    maximum_depth: usize,
    /// Per object: whether it stands in a reference definition.
    definitions: Vec<bool>,
    emitted: Vec<bool>,
    /// Emitted objects in walk order, so an element can tell which its own text showed.
    log: Vec<usize>,
    depth: usize,
}

impl Walker<'_> {
    // Nesting and emission

    /// Each block quote, list and inline container is one level; a list's items share its level.
    fn enter(&mut self) -> Result<(), ParseError> {
        self.depth += 1;
        if self.depth > self.maximum_depth {
            return Err(ParseError::DepthLimit);
        }
        Ok(())
    }

    fn leave(&mut self) {
        self.depth -= 1;
    }

    fn emit(&mut self, atom: usize) -> Result<(), ParseError> {
        if self.emitted[atom] {
            return Err(ParseError::DuplicateObject(atom.to_string()));
        }
        self.emitted[atom] = true;
        self.log.push(atom);
        Ok(())
    }

    /// Text-like content: every object in it is emitted here.
    fn parts(&mut self, text: &str) -> Result<Vec<HtmlPart>, ParseError> {
        let mut parts = Vec::new();
        for piece in self.source.pieces(text) {
            match piece {
                Piece::Text(text) => parts.append_text(text),
                Piece::Atom(atom) => {
                    self.emit(atom)?;
                    parts.push(HtmlPart::Object(atom.to_string()));
                }
            }
        }
        Ok(parts)
    }

    /// A destination or title. An object of a definition or one the element's own text showed is
    /// the stand-in U+FFFC, which the composer refuses as an address; any other is emitted here.
    fn address(&mut self, text: &str, shown: &HashSet<usize>) -> Result<Vec<HtmlPart>, ParseError> {
        let mut parts = Vec::new();
        for piece in self.source.pieces(text) {
            match piece {
                Piece::Text(text) => parts.append_text(text),
                Piece::Atom(atom) if self.definitions[atom] || shown.contains(&atom) => {
                    parts.append_text("\u{FFFC}");
                }
                Piece::Atom(atom) => {
                    self.emit(atom)?;
                    parts.push(HtmlPart::Object(atom.to_string()));
                }
            }
        }
        Ok(parts)
    }

    /// A link or image's destination and title. Each sees every object emitted since `mark`,
    /// the element's own text and then its destination, as already shown.
    fn addresses(
        &mut self,
        url: &str,
        title: &str,
        mark: usize,
    ) -> Result<(Vec<HtmlPart>, Vec<HtmlPart>), ParseError> {
        let shown: HashSet<usize> = self.log[mark..].iter().copied().collect();
        let destination = self.address(url, &shown)?;
        let shown: HashSet<usize> = self.log[mark..].iter().copied().collect();
        Ok((destination, self.address(title, &shown)?))
    }

    // Blocks

    fn blocks<'a>(&mut self, parent: Node<'a>) -> Result<Vec<Placed>, ParseError> {
        let mut blocks = Vec::new();
        for node in parent.children() {
            self.block(node, &mut blocks)?;
        }
        Ok(blocks)
    }

    fn block<'a>(&mut self, node: Node<'a>, into: &mut Vec<Placed>) -> Result<(), ParseError> {
        let data = node.data();
        let (start, end) = span(data.sourcepos);
        let shape = match &data.value {
            NodeValue::Paragraph => Shape::Leaf(Block::Paragraph(self.inlines(node)?)),
            NodeValue::Heading(heading) => Shape::Leaf(Block::Heading {
                level: heading.level,
                events: self.inlines(node)?,
            }),
            NodeValue::CodeBlock(code) => {
                // The info string's objects belong to the block and open it.
                let info = self.parts(&code.info)?;
                Shape::Leaf(Block::CodeBlock {
                    info,
                    literal: self.parts(&code.literal)?,
                })
            }
            NodeValue::HtmlBlock(html) => Shape::Leaf(Block::Html(self.parts(&html.literal)?)),
            NodeValue::ThematicBreak => Shape::Leaf(Block::ThematicBreak),
            NodeValue::Table(table) => self.table(node, &table.alignments)?,
            NodeValue::BlockQuote => {
                self.enter()?;
                let children = self.blocks(node)?;
                self.leave();
                Shape::Quote(children)
            }
            NodeValue::List(list) => {
                self.enter()?;
                let items = self.items(node)?;
                self.leave();
                let ordered = list.list_type == ListType::Ordered;
                Shape::List {
                    ordered,
                    start: if ordered { list.start } else { 0 },
                    tight: list.tight,
                    items,
                }
            }
            _ => {
                self.enter()?;
                into.extend(self.blocks(node)?);
                self.leave();
                return Ok(());
            }
        };
        into.push(Placed { shape, start, end });
        Ok(())
    }

    fn items<'a>(&mut self, list: Node<'a>) -> Result<Vec<PlacedItem>, ParseError> {
        let mut items = Vec::new();
        for node in list.children() {
            let data = node.data();
            let task = match &data.value {
                NodeValue::Item(_) => None,
                NodeValue::TaskItem(task) => Some(task.symbol.is_some()),
                _ => return Err(ParseError::ParserFailure),
            };
            items.push(PlacedItem {
                task,
                blocks: self.blocks(node)?,
                start: span(data.sourcepos).0,
            });
        }
        Ok(items)
    }

    /// Cells as comrak keeps them: one per column, a row's excess cells dropped.
    fn table<'a>(
        &mut self,
        node: Node<'a>,
        alignments: &[TableAlignment],
    ) -> Result<Shape, ParseError> {
        let alignments = alignments
            .iter()
            .map(|alignment| match alignment {
                TableAlignment::Left => Some(Alignment::Left),
                TableAlignment::Center => Some(Alignment::Center),
                TableAlignment::Right => Some(Alignment::Right),
                TableAlignment::None => None,
            })
            .collect();
        let mut header = None;
        let mut body = Vec::new();
        let mut rows = Vec::new();
        for row in node.children() {
            let data = row.data();
            let NodeValue::TableRow(is_header) = data.value else {
                return Err(ParseError::ParserFailure);
            };
            let mut cells = Vec::new();
            for cell in row.children() {
                if !matches!(cell.data().value, NodeValue::TableCell) {
                    return Err(ParseError::ParserFailure);
                }
                cells.push(self.inlines(cell)?);
            }
            if header.is_none() && is_header {
                header = Some(cells);
            } else {
                let (start, end) = span(data.sourcepos);
                body.push(cells);
                rows.push((start.line, start.line.max(end.line)));
            }
        }
        // comrak opens every table with its header row.
        let header = header.ok_or(ParseError::ParserFailure)?;
        Ok(Shape::Table {
            alignments,
            header,
            body,
            rows,
        })
    }

    // Inlines

    fn inlines<'a>(&mut self, parent: Node<'a>) -> Result<Vec<Event>, ParseError> {
        let mut events = Vec::new();
        self.append_inlines(parent, &mut events)?;
        Ok(events)
    }

    fn append_inlines<'a>(
        &mut self,
        parent: Node<'a>,
        events: &mut Vec<Event>,
    ) -> Result<(), ParseError> {
        for node in parent.children() {
            self.inline(node, events)?;
        }
        Ok(())
    }

    fn inline<'a>(&mut self, node: Node<'a>, events: &mut Vec<Event>) -> Result<(), ParseError> {
        let data = node.data();
        match &data.value {
            NodeValue::Text(text) => events.append_parts(&self.parts(text)?),
            NodeValue::SoftBreak => events.push(Event::SoftBreak),
            NodeValue::LineBreak => events.push(Event::HardBreak),
            NodeValue::Code(code) => {
                events.push(Event::EnterMarkdown(Trait::Code));
                events.append_parts(&self.parts(&code.literal)?);
                events.push(Event::LeaveMarkdown(Trait::Code));
            }
            NodeValue::HtmlInline(html) => events.push(Event::RawHtml(self.parts(html)?)),
            NodeValue::Emph => self.styled(Trait::Emphasis, node, events)?,
            NodeValue::Strong => self.styled(Trait::Strong, node, events)?,
            NodeValue::Strikethrough => self.styled(Trait::Deletion, node, events)?,
            NodeValue::Link(link) => {
                self.enter()?;
                let mark = self.log.len();
                let mut label = Vec::new();
                self.append_inlines(node, &mut label)?;
                let (destination, title) = self.addresses(&link.url, &link.title, mark)?;
                self.leave();
                // The address's own objects follow the label, outside the link, as an image's
                // follow its alt text.
                events.push(Event::EnterLink {
                    destination: standing_in(&destination),
                    title: standing_in(&title),
                });
                events.extend(label);
                events.push(Event::LeaveLink);
                let own: Vec<HtmlPart> = objects_of(&destination)
                    .chain(objects_of(&title))
                    .cloned()
                    .collect();
                events.append_parts(&own);
            }
            NodeValue::Image(image) => {
                self.enter()?;
                let mark = self.log.len();
                let mut alt = Vec::new();
                self.append_alt(node, &mut alt)?;
                let (destination, title) = self.addresses(&image.url, &image.title, mark)?;
                self.leave();
                events.push(Event::MarkdownImage {
                    alt,
                    destination,
                    title,
                });
            }
            _ => {
                self.enter()?;
                self.append_inlines(node, events)?;
                self.leave();
            }
        }
        Ok(())
    }

    fn styled<'a>(
        &mut self,
        style: Trait,
        node: Node<'a>,
        events: &mut Vec<Event>,
    ) -> Result<(), ParseError> {
        self.enter()?;
        events.push(Event::EnterMarkdown(style));
        self.append_inlines(node, events)?;
        events.push(Event::LeaveMarkdown(style));
        self.leave();
        Ok(())
    }

    /// An image description as cmark's HTML writer gives it: text, code and raw HTML literals,
    /// each break a space. A nested link or image's own address objects follow its text.
    fn append_alt<'a>(
        &mut self,
        parent: Node<'a>,
        alt: &mut Vec<HtmlPart>,
    ) -> Result<(), ParseError> {
        for node in parent.children() {
            let data = node.data();
            match &data.value {
                NodeValue::Text(text) => alt.append_parts(&self.parts(text)?),
                NodeValue::Code(code) => alt.append_parts(&self.parts(&code.literal)?),
                NodeValue::HtmlInline(html) => alt.append_parts(&self.parts(html)?),
                NodeValue::SoftBreak | NodeValue::LineBreak => alt.append_text(" "),
                NodeValue::Link(link) | NodeValue::Image(link) => {
                    self.enter()?;
                    let mark = self.log.len();
                    let mut inner = Vec::new();
                    self.append_alt(node, &mut inner)?;
                    let (destination, title) = self.addresses(&link.url, &link.title, mark)?;
                    self.leave();
                    alt.append_parts(&inner);
                    let own: Vec<HtmlPart> = objects_of(&destination)
                        .chain(objects_of(&title))
                        .cloned()
                        .collect();
                    alt.append_parts(&own);
                }
                _ => {
                    self.enter()?;
                    self.append_alt(node, alt)?;
                    self.leave();
                }
            }
        }
        Ok(())
    }
}

// Placement

struct Unplaced {
    identity: String,
    position: Position,
}

/// Puts each object no node emitted in the deepest container covering it, before the first child
/// after it, or at the end of its table row's last kept cell. `unplaced` is in source order.
fn place(unplaced: Vec<Unplaced>, blocks: &mut Vec<Placed>) {
    if unplaced.is_empty() {
        return;
    }
    let mut insertions: Vec<(usize, Unplaced)> = Vec::new();
    let mut nested: BTreeMap<usize, Vec<Unplaced>> = BTreeMap::new();
    for object in unplaced {
        let after = blocks.partition_point(|block| block.start <= object.position);
        let covering = after
            .checked_sub(1)
            .filter(|&index| object.position <= blocks[index].end);
        let Some(index) = covering else {
            insertions.push((after, object));
            continue;
        };
        let inside = match &blocks[index].shape {
            Shape::Quote(_) => true,
            Shape::List { items, .. } => !items.is_empty(),
            Shape::Table { body, rows, .. } => row(object.position.line, rows, body).is_some(),
            Shape::Leaf(_) => false,
        };
        if inside {
            nested.entry(index).or_default().push(object);
        } else {
            insertions.push((after, object));
        }
    }
    for (index, objects) in nested {
        match &mut blocks[index].shape {
            Shape::Quote(children) => place(objects, children),
            Shape::List { items, .. } => {
                // Between two items, the earlier one takes it.
                let mut by_item: BTreeMap<usize, Vec<Unplaced>> = BTreeMap::new();
                for object in objects {
                    let after = items.partition_point(|item| item.start <= object.position);
                    by_item
                        .entry(after.saturating_sub(1))
                        .or_default()
                        .push(object);
                }
                for (item, objects) in by_item {
                    place(objects, &mut items[item].blocks);
                }
            }
            Shape::Table { body, rows, .. } => {
                for object in objects {
                    if let Some(row) = row(object.position.line, rows, body)
                        && let Some(cell) = body[row].last_mut()
                    {
                        cell.push(Event::Object(object.identity));
                    }
                }
            }
            Shape::Leaf(_) => {}
        }
    }
    if insertions.is_empty() {
        return;
    }
    // Stable, so objects at one index keep source order.
    insertions.sort_by_key(|(index, _)| *index);
    let mut queue = insertions.into_iter().peekable();
    let mut result = Vec::with_capacity(blocks.len() + queue.len());
    for (index, block) in std::mem::take(blocks)
        .into_iter()
        .map(Some)
        .chain(std::iter::once(None))
        .enumerate()
    {
        let mut objects: Vec<Unplaced> = Vec::new();
        while let Some((_, object)) = queue.next_if(|(at, _)| *at == index) {
            objects.push(object);
        }
        if let Some(first) = objects.first() {
            let position = first.position;
            result.push(Placed {
                shape: Shape::Leaf(Block::Objects(
                    objects.into_iter().map(|object| object.identity).collect(),
                )),
                start: position,
                end: position,
            });
        }
        result.extend(block);
    }
    *blocks = result;
}

/// The body row on `line`, when it has a cell to take an object.
fn row(line: usize, rows: &[(usize, usize)], body: &[Vec<Vec<Event>>]) -> Option<usize> {
    let index = rows
        .partition_point(|&(first, _)| first <= line)
        .checked_sub(1)?;
    let (first, last) = rows[index];
    ((first..=last).contains(&line) && !body[index].is_empty()).then_some(index)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::page;
    use crate::{Dialect, Limits, options};
    use comrak::{Arena, parse_document};

    fn definitions_of(template: &str, dialect: Dialect) -> Vec<bool> {
        let (text, offsets) = page(template);
        let source = Source::new(&text, &offsets, &Limits::default()).unwrap();
        let arena = Arena::new();
        let root = parse_document(&arena, &source.text, &options(dialect));
        definitions(root, &source.positions)
    }

    #[test]
    fn a_definitions_object_is_one_no_leaf_block_covers() {
        for dialect in [Dialect::CommonMark, Dialect::Gfm] {
            assert_eq!(
                definitions_of(
                    "[r]: /u{obj}\n\n> [s]: /v{obj}\n\n- [t]: /w{obj}\n- x\n\npara {obj}",
                    dialect
                ),
                [true, true, true, false],
                "{dialect:?}: containers cover nothing"
            );
            assert_eq!(
                definitions_of(
                    "<div>\n{obj}\n</div>\n\n```{obj}\n{obj}\n```\n\n    {obj}\n\n# {obj}",
                    dialect
                ),
                [false; 5],
                "{dialect:?}: literals and headings"
            );
        }
        assert_eq!(
            definitions_of("| a |\n| - |\n| b | {obj} |\n| {obj} |", Dialect::Gfm),
            [false, false],
            "a dropped cell's row covers it"
        );
        assert_eq!(
            definitions_of("- [ ] [r]: /u{obj}\n- [r]: /u{obj}", Dialect::Gfm),
            [false, true],
            "a task item's text is no definition"
        );
    }

    #[test]
    fn positions_count_bytes_and_ascend_through_merged_spans() {
        assert_eq!(
            definitions_of(
                "é [r]: /u{obj}\n\n[s]: /é{obj}\n\n\t[t]: /u{obj}",
                Dialect::Gfm
            ),
            [false, true, false],
            "a tab indents the last line into a code block"
        );
    }

    /// cmark-gfm gave that paragraph line 0, which the shell's adapter had to repair.
    #[test]
    fn the_paragraph_a_table_splits_off_keeps_its_own_lines() {
        let arena = Arena::new();
        let root = parse_document(&arena, "x\ny\n| h |\n| - |\n", &options(Dialect::Gfm));
        let spans: Vec<(Position, Position)> = root
            .children()
            .map(|node| span(node.data().sourcepos))
            .collect();
        assert_eq!(
            spans,
            [
                (
                    Position { line: 1, column: 1 },
                    Position { line: 2, column: 1 }
                ),
                (
                    Position { line: 3, column: 1 },
                    Position { line: 4, column: 5 }
                ),
            ]
        );
    }
}
