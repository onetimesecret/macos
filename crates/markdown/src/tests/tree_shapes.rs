use super::*;
use crate::{options, source::Source, walker};
use comrak::{Arena, nodes::NodeValue, parse_document};

#[test]
fn an_unexpected_list_child_refuses_the_valid_prefix() {
    let template = "prefix {obj}\n\n- first {obj}\n- last {obj}";
    let limits = Limits::default();
    let (page_text, offsets) = page(template);
    let source = Source::new(&page_text, &offsets, &limits).unwrap();
    for dialect in BOTH {
        let arena = Arena::new();
        let root = parse_document(&arena, &source.text, &options(dialect));
        assert_eq!(
            walker::walk(root, &source, limits.maximum_depth),
            Ok(vec![
                paragraph(vec![text("prefix "), object(0)]),
                bullets(
                    true,
                    vec![
                        item(None, vec![paragraph(vec![text("first "), object(1)])]),
                        item(None, vec![paragraph(vec![text("last "), object(2)])]),
                    ],
                ),
            ]),
            "{dialect:?} before mutation"
        );
        let list = root
            .children()
            .find(|node| matches!(node.data().value, NodeValue::List(_)))
            .unwrap();
        list.children().nth(1).unwrap().data_mut().value = NodeValue::Paragraph;
        assert_eq!(
            walker::walk(root, &source, limits.maximum_depth),
            Err(ParseError::ParserFailure),
            "{dialect:?} after mutation"
        );
    }
}

#[test]
fn an_unexpected_table_child_refuses_the_valid_prefix() {
    let template = "prefix {obj}\n\n| header |\n| --- |\n| first {obj} |\n| last {obj} |";
    let limits = Limits::default();
    let (page_text, offsets) = page(template);
    let source = Source::new(&page_text, &offsets, &limits).unwrap();
    let arena = Arena::new();
    let root = parse_document(&arena, &source.text, &options(Dialect::Gfm));
    assert_eq!(
        walker::walk(root, &source, limits.maximum_depth),
        Ok(vec![
            paragraph(vec![text("prefix "), object(0)]),
            table(
                vec![None],
                vec![vec![text("header")]],
                vec![
                    vec![vec![text("first "), object(1)]],
                    vec![vec![text("last "), object(2)]],
                ],
            ),
        ])
    );
    let table = root
        .children()
        .find(|node| matches!(node.data().value, NodeValue::Table(_)))
        .unwrap();
    table.children().nth(2).unwrap().data_mut().value = NodeValue::Paragraph;
    assert_eq!(
        walker::walk(root, &source, limits.maximum_depth),
        Err(ParseError::ParserFailure)
    );
}

#[test]
fn an_unexpected_row_child_refuses_the_valid_prefix() {
    let template = "prefix {obj}\n\n| left | right |\n| --- | --- |\n| first {obj} | last {obj} |";
    let limits = Limits::default();
    let (page_text, offsets) = page(template);
    let source = Source::new(&page_text, &offsets, &limits).unwrap();
    let arena = Arena::new();
    let root = parse_document(&arena, &source.text, &options(Dialect::Gfm));
    assert_eq!(
        walker::walk(root, &source, limits.maximum_depth),
        Ok(vec![
            paragraph(vec![text("prefix "), object(0)]),
            table(
                vec![None, None],
                vec![vec![text("left")], vec![text("right")]],
                vec![vec![
                    vec![text("first "), object(1)],
                    vec![text("last "), object(2)],
                ]],
            ),
        ])
    );
    let table = root
        .children()
        .find(|node| matches!(node.data().value, NodeValue::Table(_)))
        .unwrap();
    let row = table.children().nth(1).unwrap();
    row.children().nth(1).unwrap().data_mut().value = NodeValue::Paragraph;
    assert_eq!(
        walker::walk(root, &source, limits.maximum_depth),
        Err(ParseError::ParserFailure)
    );
}

#[test]
fn a_table_cannot_start_with_a_body_row() {
    let template = "prefix {obj}\n\n| header {obj} |\n| --- |\n| first {obj} |\n| last {obj} |";
    let limits = Limits::default();
    let (page_text, offsets) = page(template);
    let source = Source::new(&page_text, &offsets, &limits).unwrap();
    for swap_rows in [false, true] {
        let arena = Arena::new();
        let root = parse_document(&arena, &source.text, &options(Dialect::Gfm));
        assert_eq!(
            walker::walk(root, &source, limits.maximum_depth),
            Ok(vec![
                paragraph(vec![text("prefix "), object(0)]),
                table(
                    vec![None],
                    vec![vec![text("header "), object(1)]],
                    vec![
                        vec![vec![text("first "), object(2)]],
                        vec![vec![text("last "), object(3)]],
                    ],
                ),
            ])
        );
        let table = root
            .children()
            .find(|node| matches!(node.data().value, NodeValue::Table(_)))
            .unwrap();
        let header = table.first_child().unwrap();
        if swap_rows {
            header.insert_before(header.next_sibling().unwrap());
        } else {
            header.data_mut().value = NodeValue::TableRow(false);
        }
        assert_eq!(
            walker::walk(root, &source, limits.maximum_depth),
            Err(ParseError::ParserFailure),
            "swap rows: {swap_rows}"
        );
    }
}

#[test]
fn a_second_table_header_refuses_the_valid_prefix() {
    let template = "prefix {obj}\n\n| header {obj} |\n| --- |\n| first {obj} |\n| last {obj} |";
    let limits = Limits::default();
    let (page_text, offsets) = page(template);
    let source = Source::new(&page_text, &offsets, &limits).unwrap();
    let arena = Arena::new();
    let root = parse_document(&arena, &source.text, &options(Dialect::Gfm));
    assert_eq!(
        walker::walk(root, &source, limits.maximum_depth),
        Ok(vec![
            paragraph(vec![text("prefix "), object(0)]),
            table(
                vec![None],
                vec![vec![text("header "), object(1)]],
                vec![
                    vec![vec![text("first "), object(2)]],
                    vec![vec![text("last "), object(3)]],
                ],
            ),
        ])
    );
    let table = root
        .children()
        .find(|node| matches!(node.data().value, NodeValue::Table(_)))
        .unwrap();
    table.children().nth(2).unwrap().data_mut().value = NodeValue::TableRow(true);
    assert_eq!(
        walker::walk(root, &source, limits.maximum_depth),
        Err(ParseError::ParserFailure)
    );
}
