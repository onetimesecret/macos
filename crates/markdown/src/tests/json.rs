//! The JSON the shell decodes: every case of every type, pinned against `document.json`.

use super::*;
use crate::Atom;

fn every_case() -> Document {
    let events = vec![
        text("t"),
        object(0),
        enter(Trait::Emphasis),
        leave(Trait::Emphasis),
        enter(Trait::Strong),
        leave(Trait::Strong),
        enter(Trait::Deletion),
        leave(Trait::Deletion),
        enter(Trait::Code),
        leave(Trait::Code),
        Event::SoftBreak,
        Event::HardBreak,
        Event::RawHtml(vec![part("<b>"), part_object(1)]),
        image(vec![part("alt")], vec![part("/i")], vec![part("title")]),
        link("/u\u{FFFC}", ""),
        Event::LeaveLink,
    ];
    Document {
        blocks: vec![
            paragraph(events),
            Block::Heading {
                level: 2,
                events: vec![text("h")],
            },
            Block::CodeBlock {
                info: vec![part("rust")],
                literal: vec![part("let a;\n")],
            },
            Block::Html(vec![part("<div>\n")]),
            Block::ThematicBreak,
            Block::Quote(vec![objects(&[2])]),
            Block::List {
                ordered: true,
                start: 3,
                tight: false,
                items: vec![
                    item(None, vec![]),
                    item(Some(true), vec![]),
                    item(Some(false), vec![]),
                ],
            },
            table(
                vec![
                    Some(Alignment::Left),
                    Some(Alignment::Center),
                    Some(Alignment::Right),
                    None,
                ],
                vec![vec![text("a")], vec![], vec![], vec![]],
                vec![vec![vec![text("b")]]],
            ),
        ],
        atoms: vec![
            Atom {
                identity: "0".into(),
                offset: 0,
            },
            Atom {
                identity: "1".into(),
                offset: 7,
            },
            Atom {
                identity: "2".into(),
                offset: 12,
            },
        ],
    }
}

#[test]
fn the_document_serializes_as_swift_synthesizes_codable() {
    let json = serde_json::to_string_pretty(&every_case()).unwrap();
    assert_eq!(json, include_str!("document.json").trim_end());
}

#[test]
fn each_refusal_serializes_as_swift_synthesizes_codable() {
    let errors = [
        ParseError::InputLimit,
        ParseError::DepthLimit,
        ParseError::TableCellLimit,
        ParseError::NoPlaceholderWindow,
        ParseError::ObjectOffset,
        ParseError::ParserFailure,
        ParseError::DuplicateObject("3".into()),
    ];
    assert_eq!(
        serde_json::to_string(&errors).unwrap(),
        concat!(
            r#"[{"inputLimit":{}},{"depthLimit":{}},{"tableCellLimit":{}},"#,
            r#"{"noPlaceholderWindow":{}},{"objectOffset":{}},{"parserFailure":{}},"#,
            r#"{"duplicateObject":{"_0":"3"}}]"#
        )
    );
}
