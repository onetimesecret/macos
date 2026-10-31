//! Reference definitions keep their sealed objects before the visible blocks that follow them.

use super::*;

const TOP_PARAGRAPH: &str = "[r]: /u \"title {obj}\"\ntext {obj}\n\n[x][r]";
const TOP_PARAGRAPH_USED_TWICE: &str = "[r]: /u{obj}\n| a |\n| - |\n\n[x][r] [y][r]";
const TOP_UNDERLINE_ALONE: &str = "[r]: /u{obj}\n===\n[r]";
const TOP_SETEXT: &str = "[r]: /u{obj}\nHead {obj}\n===\n\n[x][r]";
const QUOTE_PARAGRAPH: &str = "> [r]: /u{obj}\n> text";
const QUOTE_SETEXT: &str = "> [r]: /u{obj}\n> Head {obj}\n> ===\n\n[x][r]";
const ITEM_PARAGRAPH: &str = "- [r]: /u{obj}\n  text {obj}\n\n[x][r]";
const ITEM_SETEXT: &str = "- [r]: /u{obj}\n  Head {obj}\n  ===\n\n[x][r]";
const REWOUND: &str = "[a]: /{obj}\n\"t\" junk\n[a]";
const REWOUND_OBJECT: &str = "[a]: /{obj}\n\"{obj}\" junk\n[a]";
const REWOUND_LINK: &str = "[a]: /{obj}\n\"[t](/{obj})\" junk\n[a]";

/// `[x][r]` with the definition's object as its address's stand-in.
fn refused(label: &str) -> Vec<Event> {
    vec![link("/u\u{FFFC}", ""), text(label), Event::LeaveLink]
}

fn heading(events: Vec<Event>) -> Block {
    Block::Heading { level: 1, events }
}

fn head() -> Vec<Event> {
    vec![text("Head "), object(1)]
}

/// The rewound line's events, then `[a]` with its definition's object as the stand-in.
fn rewound(line: Vec<Event>) -> Vec<Block> {
    let mut events = line;
    events.extend([
        Event::SoftBreak,
        link("/\u{FFFC}", ""),
        text("a"),
        Event::LeaveLink,
    ]);
    vec![objects(&[0]), paragraph(events)]
}

#[test]
fn a_paragraph_keeping_text_after_leading_definitions_leaves_them_their_objects() {
    for dialect in BOTH {
        assert_eq!(
            blocks(TOP_PARAGRAPH, dialect),
            [
                objects(&[0]),
                paragraph(vec![text("text "), object(1)]),
                paragraph(vec![
                    link("/u", "title \u{FFFC}"),
                    text("x"),
                    Event::LeaveLink
                ]),
            ],
            "{dialect:?}"
        );
        let mut underline = vec![text("==="), Event::SoftBreak];
        underline.extend(refused("r"));
        assert_eq!(
            blocks(TOP_UNDERLINE_ALONE, dialect),
            [objects(&[0]), paragraph(underline)],
            "{dialect:?}: an underline under definitions alone"
        );
    }
    let mut twice = refused("x");
    twice.push(text(" "));
    twice.extend(refused("y"));
    assert_eq!(
        blocks(TOP_PARAGRAPH_USED_TWICE, Dialect::CommonMark),
        [
            objects(&[0]),
            paragraph(vec![text("| a |"), Event::SoftBreak, text("| - |")]),
            paragraph(twice),
        ]
    );
}

#[test]
fn repeated_references_keep_definition_and_visible_objects_in_source_order() {
    for labels in [vec!["x", "y"], vec!["x", "y", "z"]] {
        let uses = labels
            .iter()
            .map(|label| format!("[{label}][r]"))
            .collect::<Vec<_>>()
            .join(" ");
        let mut events = Vec::new();
        for label in labels {
            if !events.is_empty() {
                events.push(text(" "));
            }
            events.extend(refused(label));
        }
        assert_eq!(
            blocks(
                &format!("[r]: /u{{obj}}\n| a {{obj}} |\n| - |\n\n{uses}"),
                Dialect::CommonMark,
            ),
            [
                objects(&[0]),
                paragraph(vec![
                    text("| a "),
                    object(1),
                    text(" |"),
                    Event::SoftBreak,
                    text("| - |"),
                ]),
                paragraph(events),
            ]
        );
    }
}

#[test]
fn a_setext_heading_after_leading_definitions_leaves_them_their_objects() {
    for dialect in BOTH {
        assert_eq!(
            blocks(TOP_SETEXT, dialect),
            [objects(&[0]), heading(head()), paragraph(refused("x"))],
            "{dialect:?}"
        );
    }
}

#[test]
fn in_a_block_quote_leading_definitions_keep_their_objects() {
    for dialect in BOTH {
        assert_eq!(
            blocks(QUOTE_PARAGRAPH, dialect),
            [Block::Quote(vec![
                objects(&[0]),
                paragraph(vec![text("text")])
            ])],
            "{dialect:?}: a paragraph"
        );
        assert_eq!(
            blocks(QUOTE_SETEXT, dialect),
            [
                Block::Quote(vec![objects(&[0]), heading(head())]),
                paragraph(refused("x")),
            ],
            "{dialect:?}: a setext heading"
        );
    }
}

#[test]
fn in_a_list_item_leading_definitions_keep_their_objects() {
    for dialect in BOTH {
        assert_eq!(
            blocks(ITEM_PARAGRAPH, dialect),
            [
                bullets(
                    true,
                    vec![item(
                        None,
                        vec![objects(&[0]), paragraph(vec![text("text "), object(1)])]
                    )]
                ),
                paragraph(refused("x")),
            ],
            "{dialect:?}: a paragraph"
        );
        assert_eq!(
            blocks(ITEM_SETEXT, dialect),
            [
                bullets(true, vec![item(None, vec![objects(&[0]), heading(head())])]),
                paragraph(refused("x")),
            ],
            "{dialect:?}: a setext heading"
        );
    }
}

/// A title with text after it on its line is no title; the definition ends before it.
#[test]
fn a_rewound_title_is_no_part_of_the_definition() {
    for dialect in BOTH {
        assert_eq!(
            blocks(REWOUND, dialect),
            rewound(vec![text("\"t\" junk")]),
            "{dialect:?}"
        );
        assert_eq!(
            blocks(REWOUND_OBJECT, dialect),
            rewound(vec![text("\""), object(1), text("\" junk")]),
            "{dialect:?}: an object in the title"
        );
        assert_eq!(
            blocks(REWOUND_LINK, dialect),
            rewound(vec![
                text("\""),
                link("/\u{FFFC}", ""),
                text("t"),
                Event::LeaveLink,
                object(1),
                text("\" junk"),
            ]),
            "{dialect:?}: a link in the title"
        );
    }
}
