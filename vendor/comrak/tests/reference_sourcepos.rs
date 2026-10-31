//! Reference-definition positions and rejected next-line titles.

use comrak::nodes::NodeValue;
use comrak::{Arena, Options, parse_document};

#[test]
fn surviving_paragraphs_and_headings_start_after_definitions() {
    for newline in ["\n", "\r\n", "\r"] {
        for (prefix, indent) in [("", ""), ("> ", "> "), ("- ", "  "), ("> > ", "> > ")] {
            for heading in [false, true] {
                let mut input = format!("{prefix}[r]: /url{newline}{indent}étext{newline}");
                if heading {
                    input.push_str(&format!("{indent}==={newline}"));
                }
                let arena = Arena::new();
                let root = parse_document(&arena, &input, &Options::default());
                let block = root
                    .descendants()
                    .find(|n| {
                        matches!(n.data().value, NodeValue::Paragraph | NodeValue::Heading(_))
                    })
                    .unwrap();
                assert_eq!(
                    block.data().sourcepos.start,
                    (2, indent.len() + 1).into(),
                    "{input:?}"
                );
                let first = block.first_child().unwrap();
                assert_eq!(
                    first.data().sourcepos.start,
                    (2, indent.len() + 1).into(),
                    "{input:?}"
                );
            }
        }
    }
}

#[test]
fn multiple_and_multiline_definitions_advance_all_consumed_offsets() {
    for input in ["[r]: /r\n[s]: /s\ntext\n", "[r]: /r\n  \"title\"\ntext\n"] {
        let arena = Arena::new();
        let root = parse_document(&arena, input, &Options::default());
        let paragraph = root.first_child().unwrap();
        assert_eq!(paragraph.data().sourcepos.start, (3, 1).into());
        assert_eq!(
            paragraph.first_child().unwrap().data().sourcepos.start,
            (3, 1).into()
        );
    }
}

#[test]
fn definitions_without_remaining_content_accept_eof() {
    for newline in ["", "\n", "\r\n", "\r"] {
        let arena = Arena::new();
        let root = parse_document(&arena, &format!("[r]: /url{newline}"), &Options::default());
        assert!(root.first_child().is_none());
    }
}

#[test]
fn rejected_next_line_titles_are_empty_in_reference_links() {
    for newline in ["\n", "\r\n", "\r"] {
        let input = format!("[a]: /url{newline}\"title\" junk{newline}[a]");
        let arena = Arena::new();
        let root = parse_document(&arena, &input, &Options::default());
        let link = root
            .descendants()
            .find(|n| matches!(n.data().value, NodeValue::Link(_)))
            .unwrap();
        let data = link.data();
        let NodeValue::Link(link) = &data.value else {
            unreachable!()
        };
        assert_eq!(link.url, "/url");
        assert_eq!(link.title, "");
    }
}
