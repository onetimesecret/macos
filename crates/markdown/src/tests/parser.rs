//! The adapter's own rules: the placeholder window, line endings, limits, and where an object
//! stands when the grammar gives it no element of its own (`MarkdownParserTests`).

use super::*;

/// The window avoids literal plane 16 scalars and numeric references because no other spelling
/// decodes to one: no replacement in comrak's entity table, the `entities` crate, is in plane 16.
#[test]
fn no_named_entity_decodes_into_plane_sixteen() {
    let named: Vec<_> = entities::ENTITIES
        .iter()
        .filter(|entity| entity.entity.starts_with('&') && entity.entity.ends_with(';'))
        .collect();
    assert_eq!(named.len(), 2_125, "entities 1.0.1");
    for entity in named {
        assert!(
            !entity
                .characters
                .chars()
                .any(|scalar| scalar >= '\u{100000}'),
            "{}",
            entity.entity
        );
    }
}

#[test]
fn plane_sixteen_text_and_numeric_references_stay_text_beside_the_objects() {
    let template = "\u{100000} &#1048576; &#x100001; &#X100002; {obj} end";
    let (_, offsets) = page(template);
    for dialect in BOTH {
        let document = document(template, dialect).unwrap();
        assert_eq!(
            document.blocks,
            [paragraph(vec![
                text("\u{100000} \u{100000} \u{100001} \u{100002} "),
                object(0),
                text(" end"),
            ])],
            "{dialect:?}"
        );
        assert_eq!(document.atoms.len(), 1);
        assert_eq!(document.atoms[0].identity, "0");
        assert_eq!(document.atoms[0].offset, offsets[0]);
    }
    // A window of two skips the one scalar inside the lowest window of two.
    assert_eq!(
        blocks("\u{100001} {obj}{obj}", Dialect::Gfm),
        [paragraph(vec![text("\u{100001} "), object(0), object(1)])]
    );
}

/// Plane 16 has 65,534 scalars; one taken at U+108000 leaves runs of 32,768 and 32,765.
#[test]
fn a_page_with_no_placeholder_window_is_refused_before_parsing() {
    let objects = "{obj}".repeat(40_000);
    for taken in ["\u{108000}", "&#1081344;", "&#x108000;"] {
        assert_eq!(
            document(&format!("{taken}{objects}"), Dialect::Gfm),
            Err(ParseError::NoPlaceholderWindow),
            "{taken}"
        );
    }
    let fits = document(
        &format!("\u{108000}{}", "{obj}".repeat(32_768)),
        Dialect::Gfm,
    );
    assert_eq!(fits.unwrap().atoms.len(), 32_768);
}

#[test]
fn the_input_limit_counts_scalars_before_parsing() {
    let limits = Limits {
        maximum_input_scalars: 5,
        ..Limits::default()
    };
    assert!(crate::parse("12345", Dialect::Gfm, limits).is_ok());
    assert!(crate::parse("😀😀😀😀😀", Dialect::CommonMark, limits).is_ok());
    assert_eq!(
        crate::parse("123456", Dialect::Gfm, limits),
        Err(ParseError::InputLimit)
    );
}

#[test]
fn object_offsets_must_name_each_object_in_order() {
    let limits = Limits::default();
    for (text, offsets) in [
        ("ab", &[1][..]),
        ("\u{FFFC}\u{FFFC}", &[1, 0]),
        ("\u{FFFC}\u{FFFC}", &[0, 0]),
        ("\u{FFFC}", &[0, 1]),
        ("😀\u{FFFC}", &[1]),
    ] {
        assert_eq!(
            parse_with_objects(text, offsets, Dialect::Gfm, limits),
            Err(ParseError::ObjectOffset),
            "{text:?} {offsets:?}"
        );
    }
    // A U+FFFC no offset names is the page's own text.
    assert_eq!(
        crate::parse("a\u{FFFC}", Dialect::Gfm, limits)
            .unwrap()
            .blocks,
        [paragraph(vec![text("a\u{FFFC}")])]
    );
}

/// CR and CRLF read as LF; a CRLF counted twice would put the definition's object after `e`.
#[test]
fn line_endings_read_as_lf_and_atoms_keep_their_offsets_in_the_page() {
    let template = "a\r\n\r\nb\rc\r\n\r\n[r]: https://e.example/{obj}\r\n\r\nd {obj}\r\n\r\ne";
    let (_, offsets) = page(template);
    for dialect in BOTH {
        let document = document(template, dialect).unwrap();
        let atoms: Vec<_> = document.atoms.iter().map(|atom| atom.offset).collect();
        assert_eq!(atoms, offsets);
        assert_eq!(
            document.blocks,
            [
                paragraph(vec![text("a")]),
                paragraph(vec![text("b"), Event::SoftBreak, text("c")]),
                objects(&[0]),
                paragraph(vec![text("d "), object(1)]),
                paragraph(vec![text("e")]),
            ],
            "{dialect:?}"
        );
    }
}

/// Block quotes, lists and inline containers count; the walk stops before the stack would.
#[test]
fn nesting_past_the_depth_limit_is_refused() {
    let deep = format!("{} deep", ">".repeat(100_000));
    assert_eq!(
        crate::parse(&deep, Dialect::Gfm, Limits::default()),
        Err(ParseError::DepthLimit)
    );
    let quotes = format!("{}x", "> ".repeat(64));
    assert!(crate::parse(&quotes, Dialect::CommonMark, Limits::default()).is_ok());
    assert_eq!(
        crate::parse(
            &format!("> {quotes}"),
            Dialect::CommonMark,
            Limits::default()
        ),
        Err(ParseError::DepthLimit)
    );

    let one = Limits {
        maximum_depth: 1,
        ..Limits::default()
    };
    assert!(crate::parse("**a**", Dialect::Gfm, one).is_ok());
    assert!(
        crate::parse("- a\n- b", Dialect::Gfm, one).is_ok(),
        "items share a level"
    );
    for page in ["**a *b***", "> [a](/u)", "![a *b*](/i)"] {
        assert_eq!(
            crate::parse(page, Dialect::Gfm, one),
            Err(ParseError::DepthLimit),
            "{page}"
        );
    }
}

#[test]
fn an_oversized_caller_limit_still_refuses_nesting_past_the_internal_ceiling() {
    let oversized = Limits {
        maximum_depth: usize::MAX,
        ..Limits::default()
    };
    let at_ceiling = format!("{}text", "> ".repeat(crate::MAXIMUM_DEPTH));
    let above_ceiling = format!("> {at_ceiling}");
    for dialect in BOTH {
        assert!(crate::parse(&at_ceiling, dialect, oversized).is_ok());
        assert_eq!(
            crate::parse(&above_ceiling, dialect, oversized),
            Err(ParseError::DepthLimit)
        );
        let lower = Limits {
            maximum_depth: 1,
            ..oversized
        };
        assert!(crate::parse("> text", dialect, lower).is_ok());
        assert_eq!(
            crate::parse("> > text", dialect, lower),
            Err(ParseError::DepthLimit)
        );
    }
}

#[test]
fn adversarial_nesting_returns_on_a_dispatch_sized_stack() {
    let pages = [
        (
            format!("{}a{}", "![".repeat(20_000), "](/u)".repeat(20_000)),
            false,
        ),
        (
            format!("{}a{}", "*".repeat(20_000), "*".repeat(20_000)),
            false,
        ),
        (format!("{} deep", "> ".repeat(50_000)), false),
        (format!("{}x", "> - ".repeat(20_000)), false),
        (
            format!("{}a{}", "[".repeat(20_000), "](/u)".repeat(20_000)),
            true,
        ),
        (
            format!("{}a{}", "*_".repeat(5_000), "_*".repeat(5_000)),
            true,
        ),
        ("[".repeat(100_000), true),
        ("<".repeat(100_000), true),
        ("`".repeat(100_000), true),
    ];
    for (page, parses) in pages {
        for maximum_depth in [crate::MAXIMUM_DEPTH, usize::MAX] {
            let page = page.clone();
            let outcomes = std::thread::Builder::new()
                .stack_size(512 * 1024)
                .spawn(move || {
                    BOTH.map(|dialect| {
                        let limits = Limits {
                            maximum_depth,
                            ..Limits::default()
                        };
                        crate::parse(&page, dialect, limits).map(drop)
                    })
                })
                .unwrap()
                .join()
                .unwrap();
            let expected = if parses {
                Ok(())
            } else {
                Err(ParseError::DepthLimit)
            };
            assert_eq!(outcomes, [expected.clone(), expected]);
        }
    }
}

/// A definition's object stays at the definition, before or after the reference, and a reference
/// to it refuses the address with the stand-in; no object moves from later text.
#[test]
fn a_definition_keeps_its_objects_and_its_references_refuse_their_address() {
    for dialect in BOTH {
        assert_eq!(
            blocks(
                "[r]: https://e.example/{obj} \"t\"\n\n[link][r] then {obj}",
                dialect
            ),
            [
                objects(&[0]),
                paragraph(vec![
                    link("https://e.example/\u{FFFC}", "t"),
                    text("link"),
                    Event::LeaveLink,
                    text(" then "),
                    object(1),
                ]),
            ],
            "{dialect:?}: before"
        );
        assert_eq!(
            blocks(
                "![pic][r] {obj} end\n\n[r]: https://e.example/{obj}",
                dialect
            ),
            [
                paragraph(vec![
                    image(
                        vec![part("pic")],
                        vec![part("https://e.example/\u{FFFC}")],
                        vec![]
                    ),
                    text(" "),
                    object(0),
                    text(" end"),
                ]),
                objects(&[1]),
            ],
            "{dialect:?}: after"
        );
        assert_eq!(
            blocks("[a{obj}]: /u\n\nplain", dialect),
            [objects(&[0]), paragraph(vec![text("plain")])],
            "{dialect:?}: in a label"
        );
        assert_eq!(
            blocks("[r]: /u{obj}", dialect),
            [objects(&[0])],
            "{dialect:?}: alone"
        );
        assert_eq!(
            blocks("> [r]: /u{obj}\n>\n> text", dialect),
            [Block::Quote(vec![
                objects(&[0]),
                paragraph(vec![text("text")])
            ])],
            "{dialect:?}: in a quote"
        );
        assert_eq!(
            blocks("- a\n- [r]: /u{obj}\n- b", dialect),
            [bullets(
                true,
                vec![
                    item(None, vec![paragraph(vec![text("a")])]),
                    item(None, vec![objects(&[0])]),
                    item(None, vec![paragraph(vec![text("b")])]),
                ]
            )],
            "{dialect:?}: in an item of its own"
        );
    }
}

/// Placement compares byte columns, as comrak's block positions count them; a tab that comrak
/// expands to its tab stop moves neither the object nor the block it falls in.
#[test]
fn a_tab_before_a_definitions_object_keeps_it_in_its_container() {
    for dialect in BOTH {
        assert_eq!(
            blocks("-\t[r]:\t/u{obj}\n\n\ta{obj}\n- b", dialect),
            [bullets(
                true,
                vec![
                    item(
                        None,
                        vec![objects(&[0]), paragraph(vec![text("a"), object(1)])]
                    ),
                    item(None, vec![paragraph(vec![text("b")])]),
                ]
            )],
            "{dialect:?}: in a list item"
        );
        assert_eq!(
            blocks(">\t[r]: /u{obj}\n>\n>\ta{obj}\n\nafter", dialect),
            [
                Block::Quote(vec![objects(&[0]), paragraph(vec![text("a"), object(1)])]),
                paragraph(vec![text("after")]),
            ],
            "{dialect:?}: in a quote"
        );
    }
}

/// comrak moves a list's end back to its last child when an empty line closes it, so the object of
/// a definition ending the list follows the list. cmark-gfm kept it in the item.
#[test]
fn a_definition_closing_a_list_after_an_empty_line_follows_the_list() {
    let list = |last: Vec<Block>| {
        bullets(
            true,
            vec![
                item(None, vec![paragraph(vec![text("a")])]),
                item(None, last),
            ],
        )
    };
    let para = || paragraph(vec![text("para")]);
    for dialect in BOTH {
        assert_eq!(
            blocks("- a\n- [r]: /u{obj}\n\npara", dialect),
            [list(vec![]), objects(&[0]), para()],
            "{dialect:?}: after an empty line"
        );
        for template in ["- a\n- [r]: /u{obj}\n   \npara", "- a\n- [r]: /u{obj}"] {
            assert_eq!(
                blocks(template, dialect),
                [list(vec![objects(&[0])])]
                    .into_iter()
                    .chain(template.ends_with("para").then(para))
                    .collect::<Vec<_>>(),
                "{dialect:?}: {template:?}"
            );
        }
        assert_eq!(
            blocks("> - a\n> - [r]: /u{obj}\n\npara", dialect),
            [Block::Quote(vec![list(vec![objects(&[0])])]), para()],
            "{dialect:?}: in a quote"
        );
    }
}

/// A link's own destination and title objects follow its label, as an image's follow its alt
/// text, and the address keeps a stand-in for each.
#[test]
fn an_inline_links_own_destination_and_title_objects_follow_its_label() {
    for dialect in BOTH {
        assert_eq!(
            blocks(
                "a [label {obj}](https://e.example/{obj} \"t {obj}\") b",
                dialect
            ),
            [paragraph(vec![
                text("a "),
                link("https://e.example/\u{FFFC}", "t \u{FFFC}"),
                text("label "),
                object(0),
                Event::LeaveLink,
                object(1),
                object(2),
                text(" b"),
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks("![alt {obj}](/i{obj} \"t {obj}\")", dialect),
            [paragraph(vec![image(
                vec![part("alt "), part_object(0)],
                vec![part("/i"), part_object(1)],
                vec![part("t "), part_object(2)],
            )])],
            "{dialect:?}: image"
        );
        assert_eq!(
            blocks("![a [b](/u{obj}) c](/i{obj})", dialect),
            [paragraph(vec![image(
                vec![part("a b"), part_object(0), part(" c")],
                vec![part("/i"), part_object(1)],
                vec![],
            )])],
            "{dialect:?}: a link in alt text"
        );
    }
}

/// The autolink's text shows its object, so its address has the stand-in and is refused.
#[test]
fn an_angle_autolink_shows_its_object_once_and_refuses_its_address() {
    for dialect in BOTH {
        assert_eq!(
            blocks("<https://e.example/{obj}>", dialect),
            [paragraph(vec![
                link("https://e.example/\u{FFFC}", ""),
                text("https://e.example/"),
                object(0),
                Event::LeaveLink,
            ])],
            "{dialect:?}"
        );
    }
}

#[test]
fn fence_info_objects_belong_to_the_code_block_and_open_it() {
    for dialect in BOTH {
        assert_eq!(
            blocks("```swift {obj}\nlet a = {obj}\n```\n", dialect),
            [Block::CodeBlock {
                info: vec![part("swift "), part_object(0)],
                literal: vec![part("let a = "), part_object(1), part("\n")],
            }],
            "{dialect:?}"
        );
    }
}

/// comrak drops a row's cells past the header's count, so their objects end the row's last cell.
#[test]
fn a_gfm_table_rows_excess_cell_object_ends_the_rows_last_cell() {
    let template = "| a | b |\n| - | - |\n| c | d | {obj} |\n| e |\n\nafter {obj}";
    assert_eq!(
        blocks(template, Dialect::Gfm),
        [
            table(
                vec![None, None],
                vec![vec![text("a")], vec![text("b")]],
                vec![
                    vec![vec![text("c")], vec![text("d"), object(0)]],
                    vec![vec![text("e")], vec![]],
                ]
            ),
            paragraph(vec![text("after "), object(1)]),
        ]
    );
    let Some(Block::Paragraph(events)) = blocks(template, Dialect::CommonMark).first().cloned()
    else {
        panic!("CommonMark reads the lines as a paragraph");
    };
    assert!(events.contains(&object(0)));
}

/// comrak gives the paragraph it keeps above a table its own lines; a definition's object before
/// that paragraph still stands at the definition.
#[test]
fn a_definitions_object_stays_above_the_paragraph_a_table_splits_off() {
    let header = vec![vec![text("h")]];
    assert_eq!(
        blocks(
            "[r]: /u{obj}\n\nA{obj}\n\nx{obj}\n| h |\n| - |\n\nB{obj}",
            Dialect::Gfm
        ),
        [
            objects(&[0]),
            paragraph(vec![text("A"), object(1)]),
            paragraph(vec![text("x"), object(2)]),
            table(vec![None], header.clone(), vec![]),
            paragraph(vec![text("B"), object(3)]),
        ]
    );
    assert_eq!(
        blocks(
            "> [r]: /u{obj}\n>\n> x{obj}\n> | h |\n> | - |",
            Dialect::Gfm
        ),
        [Block::Quote(vec![
            objects(&[0]),
            paragraph(vec![text("x"), object(1)]),
            table(vec![None], header.clone(), vec![]),
        ])]
    );
    assert_eq!(
        blocks("- [r]: /u{obj}\n\n  x{obj}\n  | h |\n  | - |", Dialect::Gfm),
        [bullets(
            true,
            vec![item(
                None,
                vec![
                    objects(&[0]),
                    paragraph(vec![text("x"), object(1)]),
                    table(vec![None], header, vec![]),
                ]
            )]
        )]
    );
}

/// comrak pads a short row to the header's width, so a few kilobytes of wide tables ask for
/// hundreds of thousands of cells; every table of a page shares one budget.
#[test]
fn tables_past_the_cell_budget_are_refused() {
    let six = Limits {
        maximum_table_cells: 6,
        ..Limits::default()
    };
    let page = "| a | b |\n| - | - |\n| c |\n| d |";
    assert!(crate::parse(page, Dialect::Gfm, six).is_ok());
    assert_eq!(
        crate::parse(&format!("{page}\n| e |"), Dialect::Gfm, six),
        Err(ParseError::TableCellLimit)
    );
    assert_eq!(
        crate::parse(
            "| a | b |\n| - | - |\n| c |\n\n| a | b |\n| - | - |\n| d |",
            Dialect::Gfm,
            six
        ),
        Err(ParseError::TableCellLimit)
    );
    assert!(crate::parse(&format!("{page}\n| e |"), Dialect::CommonMark, six).is_ok());

    let wide = format!(
        "|{}\n|{}\n{}",
        " a |".repeat(2_000),
        " - |".repeat(2_000),
        "x\n".repeat(262)
    );
    for page in [wide.clone(), format!("{wide}\n").repeat(3)] {
        assert_eq!(
            crate::parse(&page, Dialect::Gfm, Limits::default()),
            Err(ParseError::TableCellLimit)
        );
        assert!(crate::parse(&page, Dialect::CommonMark, Limits::default()).is_ok());
    }
}

/// Pages built to hide, copy or split an object; each object appears once.
#[test]
fn every_object_appears_once_on_pages_that_hide_or_copy_it() {
    let pages = [
        "[r]: /u{obj}\n| a |\n| - |\n| {obj} |",
        "text {obj}\n| a |\n| - |\n| b |",
        "> - [r]: /u{obj}\n>   [x][r] {obj}",
        "<a href=\"{obj}\">[x](/u{obj} \"{obj}\")</a>",
        "![a ![b](/i{obj})](/j{obj} \"{obj}\")",
        "[![a{obj}](/i{obj})](/u{obj})",
        "[a](<{obj}>) [b]({obj} '{obj}')",
        "```{obj}\n```",
        "<!-- {obj} -->\n\n<div>\n{obj}\n</div>",
        "| a |\n| - |\n| b | {obj} | {obj} |\n{obj}",
        "- [ ] {obj}\n- [x] {obj}\n- [{obj}] c",
        "{obj}\n===\n\n[r]: /u{obj}\nHeading {obj}\n---",
        "1. [r]: /u{obj}\n2. b {obj}",
        "    {obj} indented\n\n*{obj}*{obj}**{obj}** ~~{obj}~~ `{obj}`",
        "\\{obj} &#x{obj}; &{obj}amp; [{obj}]: /u\n\n[{obj}]",
        "[r]: /a{obj}\n[r]: /b{obj}\n\n[r]",
        "<https://e.example/{obj}> www.e.example{obj} a{obj}@e.example",
    ];
    for template in pages {
        let count = template.matches("{obj}").count();
        for dialect in BOTH {
            let mut found = identities(&blocks(template, dialect));
            found.sort();
            let mut expected: Vec<String> = (0..count).map(|index| index.to_string()).collect();
            expected.sort();
            assert_eq!(found, expected, "{dialect:?}: {template:?}");
        }
    }
}

/// The table takes its header before any definition above it resolves, so that line stays text, as
/// in cmark-gfm 0.29.0.gfm.13; `definitions.rs` reads the same page as `CommonMark`.
#[test]
fn a_definition_above_a_gfm_table_header_stays_paragraph_text() {
    assert_eq!(
        blocks("[r]: /u{obj}\n| a |\n| - |\n\n[x][r] [y][r]", Dialect::Gfm),
        [
            paragraph(vec![text("[r]: /u"), object(0)]),
            table(vec![None], vec![vec![text("a")]], vec![]),
            paragraph(vec![text("[x][r] [y][r]")]),
        ]
    );
}

/// comrak keeps no process wide state, so parses on many threads at once equal the same parses
/// run one at a time.
#[test]
fn parses_on_many_threads_equal_the_same_parses_in_turn() {
    let pages = [
        "~~a~~ ~b~ *c* https://example.com/x www.example.org/y person@example.com",
        "| a | b |\n| :- | -: |\n| ~c~ | **d** |\n| e |",
        "_x_ **y** `z` &amp; &#x41; <b>h</b> ~~~not~~~",
        "[r]: /u \"t\"\n\n[link][r] ![i](/i) <https://example.net/>",
        "- [ ] task ~~done~~\n- [x] *other*\n\n> quoted | not | a table",
    ];
    let jobs: Vec<(Dialect, &str)> = BOTH
        .iter()
        .flat_map(|&dialect| pages.iter().map(move |&page| (dialect, page)))
        .collect();
    let serial: Vec<Document> = jobs
        .iter()
        .map(|&(dialect, page)| crate::parse(page, dialect, Limits::default()).unwrap())
        .collect();
    std::thread::scope(|scope| {
        let workers: Vec<_> = (0..8)
            .map(|worker| {
                let jobs = &jobs;
                scope.spawn(move || {
                    (0..jobs.len() * 5)
                        .map(|round| {
                            let index = (round + worker) % jobs.len();
                            let (dialect, page) = jobs[index];
                            (index, crate::parse(page, dialect, Limits::default()))
                        })
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        for worker in workers {
            for (index, result) in worker.join().unwrap() {
                assert_eq!(result.as_ref(), Ok(&serial[index]), "{:?}", jobs[index]);
            }
        }
    });
}

/// The placeholder is neither space nor punctuation, so an object flanks a delimiter as a letter
/// does.
#[test]
fn an_object_flanks_emphasis_as_a_letter_does() {
    for dialect in BOTH {
        assert_eq!(
            blocks("*note*{obj} and _note_{obj}", dialect),
            [paragraph(vec![
                enter(Trait::Emphasis),
                text("note"),
                leave(Trait::Emphasis),
                object(0),
                text(" and _note_"),
                object(1),
            ])],
            "{dialect:?}"
        );
    }
}
