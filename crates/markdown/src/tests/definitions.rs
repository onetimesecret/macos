//! comrak 0.57.0 leaves definition lines in a surviving paragraph's or setext heading's span and
//! keeps a rewound title: ignored tests expect a fixed comrak, `comrak_0_57` tests pin today's.

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
#[ignore = "needs comrak sourcepos fix after reference definitions, issue 332"]
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
fn comrak_0_57_keeps_definition_lines_in_a_paragraph_at_top_level() {
    for dialect in BOTH {
        assert_eq!(
            blocks(TOP_PARAGRAPH, dialect),
            [
                paragraph(vec![text("text "), object(1)]),
                paragraph(vec![
                    link("/u", "title \u{FFFC}"),
                    text("x"),
                    Event::LeaveLink,
                    object(0),
                ]),
            ],
            "{dialect:?}"
        );
        let mut underline = vec![text("==="), Event::SoftBreak];
        underline.extend(refused("r"));
        underline.push(object(0));
        assert_eq!(
            blocks(TOP_UNDERLINE_ALONE, dialect),
            [paragraph(underline)],
            "{dialect:?}: an underline under definitions alone"
        );
    }
    // The object reads as the first use's own, so the second use emits it again.
    assert_eq!(
        document(TOP_PARAGRAPH_USED_TWICE, Dialect::CommonMark),
        Err(ParseError::DuplicateObject("0".into()))
    );
}

#[test]
#[ignore = "needs comrak sourcepos fix after reference definitions, issue 332"]
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
fn comrak_0_57_keeps_definition_lines_in_a_setext_heading_at_top_level() {
    for dialect in BOTH {
        let mut use_ = refused("x");
        use_.push(object(0));
        assert_eq!(
            blocks(TOP_SETEXT, dialect),
            [heading(head()), paragraph(use_)],
            "{dialect:?}"
        );
    }
}

#[test]
#[ignore = "needs comrak sourcepos fix after reference definitions, issue 332"]
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
fn comrak_0_57_keeps_definition_lines_in_a_block_quotes_paragraph_or_heading() {
    for dialect in BOTH {
        assert_eq!(
            blocks(QUOTE_PARAGRAPH, dialect),
            [Block::Quote(vec![
                paragraph(vec![text("text")]),
                objects(&[0])
            ])],
            "{dialect:?}: a paragraph"
        );
        let mut use_ = refused("x");
        use_.push(object(0));
        assert_eq!(
            blocks(QUOTE_SETEXT, dialect),
            [Block::Quote(vec![heading(head())]), paragraph(use_)],
            "{dialect:?}: a setext heading"
        );
    }
}

#[test]
#[ignore = "needs comrak sourcepos fix after reference definitions, issue 332"]
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

#[test]
fn comrak_0_57_keeps_definition_lines_in_a_list_items_paragraph_or_heading() {
    for dialect in BOTH {
        let mut use_ = refused("x");
        use_.push(object(0));
        assert_eq!(
            blocks(ITEM_PARAGRAPH, dialect),
            [
                bullets(
                    true,
                    vec![item(None, vec![paragraph(vec![text("text "), object(1)])])]
                ),
                paragraph(use_.clone()),
            ],
            "{dialect:?}: a paragraph"
        );
        assert_eq!(
            blocks(ITEM_SETEXT, dialect),
            [
                bullets(true, vec![item(None, vec![heading(head())])]),
                paragraph(use_),
            ],
            "{dialect:?}: a setext heading"
        );
    }
}

/// A title with text after it on its line is no title; the definition ends before it.
#[test]
#[ignore = "needs comrak sourcepos fix after reference definitions, issue 332"]
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

#[test]
fn comrak_0_57_keeps_a_rewound_title() {
    for dialect in BOTH {
        assert_eq!(
            blocks(REWOUND, dialect),
            [paragraph(vec![
                text("\"t\" junk"),
                Event::SoftBreak,
                link("/\u{FFFC}", "t"),
                text("a"),
                Event::LeaveLink,
                object(0),
            ])],
            "{dialect:?}"
        );
        // The title's object shows in the paragraph's text and again in the kept title.
        for page in [REWOUND_OBJECT, REWOUND_LINK] {
            assert_eq!(
                document(page, dialect),
                Err(ParseError::DuplicateObject("1".into())),
                "{dialect:?}: {page:?}"
            );
        }
    }
}
