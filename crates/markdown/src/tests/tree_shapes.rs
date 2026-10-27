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

#[test]
fn unplaced_objects_before_a_lists_first_item_precede_the_list() {
    let template =
        "prefix {obj}\n\n[r]: /u{obj}\n[s]: /v{obj}\n\n- first {obj}\n- last {obj}\n\nsuffix {obj}";
    let limits = Limits::default();
    let (page_text, offsets) = page(template);
    let source = Source::new(&page_text, &offsets, &limits).unwrap();
    let expected = vec![
        paragraph(vec![text("prefix "), object(0)]),
        objects(&[1, 2]),
        bullets(
            true,
            vec![
                item(None, vec![paragraph(vec![text("first "), object(3)])]),
                item(None, vec![paragraph(vec![text("last "), object(4)])]),
            ],
        ),
        paragraph(vec![text("suffix "), object(5)]),
    ];
    for dialect in BOTH {
        let arena = Arena::new();
        let root = parse_document(&arena, &source.text, &options(dialect));
        assert_eq!(
            walker::walk(root, &source, limits.maximum_depth),
            Ok(expected.clone()),
            "{dialect:?} before mutation"
        );
        let list = root
            .children()
            .find(|node| matches!(node.data().value, NodeValue::List(_)))
            .unwrap();
        list.data_mut().sourcepos.start = (3, 1).into();
        let actual = walker::walk(root, &source, limits.maximum_depth).unwrap();
        assert_eq!(actual, expected, "{dialect:?} after mutation");
        assert_eq!(
            identities(&actual),
            ["0", "1", "2", "3", "4", "5"],
            "{dialect:?} object order"
        );
    }
}

#[test]
fn an_image_title_reusing_alt_and_destination_objects_emits_each_once() {
    let template = "![alt {obj}](/i{obj} \"title {obj}\")";
    let limits = Limits::default();
    let (page_text, offsets) = page(template);
    let source = Source::new(&page_text, &offsets, &limits).unwrap();
    for dialect in BOTH {
        let arena = Arena::new();
        let root = parse_document(&arena, &source.text, &options(dialect));
        assert_eq!(
            walker::walk(root, &source, limits.maximum_depth),
            Ok(vec![paragraph(vec![image(
                vec![part("alt "), part_object(0)],
                vec![part("/i"), part_object(1)],
                vec![part("title "), part_object(2)],
            )])]),
            "{dialect:?} before mutation"
        );
        let image_node = root
            .descendants()
            .find(|node| matches!(node.data().value, NodeValue::Image(_)))
            .unwrap();
        let NodeValue::Text(alt) = image_node.first_child().unwrap().data().value.clone() else {
            panic!("image alt text");
        };
        {
            let mut data = image_node.data_mut();
            let NodeValue::Image(image) = &mut data.value else {
                panic!("image");
            };
            image.title = format!("{alt} {} {}", image.url, image.title);
        }
        let actual = walker::walk(root, &source, limits.maximum_depth).unwrap();
        assert_eq!(
            actual,
            vec![paragraph(vec![image(
                vec![part("alt "), part_object(0)],
                vec![part("/i"), part_object(1)],
                vec![part("alt \u{FFFC} /i\u{FFFC} title "), part_object(2)],
            )])],
            "{dialect:?} after mutation"
        );
        assert_eq!(identities(&actual), ["0", "1", "2"], "{dialect:?}");
    }
}
