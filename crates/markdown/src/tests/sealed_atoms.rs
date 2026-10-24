//! Plan R1's grammar cases and sealed object fixtures P01 to P07 under both dialects, at the
//! parser's level (`MarkdownSealedAtomTests`); rendering stays with the shell.

use super::*;

// Ordinary text conformance

/// C01: GFM strikes single and double tilde runs and leaves a triple run literal; a triple tilde
/// fence opens a code block in both dialects.
#[test]
fn single_and_double_tildes_strike_under_gfm_and_triple_tildes_stay_literal() {
    assert_eq!(
        blocks("~a~ ~~b~~ ~~~c~~~", Dialect::Gfm),
        [paragraph(vec![
            enter(Trait::Deletion),
            text("a"),
            leave(Trait::Deletion),
            text(" "),
            enter(Trait::Deletion),
            text("b"),
            leave(Trait::Deletion),
            text(" ~~~c~~~"),
        ])]
    );
    assert_eq!(
        blocks("~a~ ~~b~~ ~~~c~~~", Dialect::CommonMark),
        [paragraph(vec![text("~a~ ~~b~~ ~~~c~~~")])]
    );
    for dialect in BOTH {
        assert_eq!(
            blocks("~~~\ncode\n~~~", dialect),
            [Block::CodeBlock {
                info: vec![],
                literal: vec![part("code\n")]
            }],
            "{dialect:?}"
        );
    }
}

/// GFM's extended autolinks drop trailing punctuation and an unbalanced `)` and keep balanced
/// parentheses and a query; `CommonMark` leaves every bare address as text.
#[test]
fn extended_autolinks_drop_trailing_punctuation_and_keep_balanced_parentheses() {
    let www = || autolink("http://www.example.com", "www.example.com");
    let cases: Vec<(&str, Vec<Event>)> = vec![
        ("www.example.com.", [www(), vec![text(".")]].concat()),
        (
            "(www.example.com)",
            [vec![text("(")], www(), vec![text(")")]].concat(),
        ),
        (
            "www.example.com/a_(b)",
            autolink("http://www.example.com/a_(b)", "www.example.com/a_(b)"),
        ),
        (
            "www.example.com/a)",
            [
                autolink("http://www.example.com/a", "www.example.com/a"),
                vec![text(")")],
            ]
            .concat(),
        ),
        (
            "https://example.com/?",
            [
                autolink("https://example.com/", "https://example.com/"),
                vec![text("?")],
            ]
            .concat(),
        ),
        (
            "https://example.com/?q=1",
            autolink("https://example.com/?q=1", "https://example.com/?q=1"),
        ),
        (
            "https://example.com/a?b.",
            [
                autolink("https://example.com/a?b", "https://example.com/a?b"),
                vec![text(".")],
            ]
            .concat(),
        ),
    ];
    for (source, events) in cases {
        assert_eq!(
            blocks(source, Dialect::Gfm),
            [paragraph(events)],
            "{source}"
        );
        assert_eq!(
            blocks(source, Dialect::CommonMark),
            [paragraph(vec![text(source)])],
            "{source}"
        );
    }
}

#[test]
fn email_and_protocol_autolinks_follow_comrak() {
    let cases: Vec<(&str, Vec<Event>)> = vec![
        (
            "person@example.com",
            autolink("mailto:person@example.com", "person@example.com"),
        ),
        (
            "person@example.com.",
            [
                autolink("mailto:person@example.com", "person@example.com"),
                vec![text(".")],
            ]
            .concat(),
        ),
        (
            "a.b-c_d+e@example.co.uk",
            autolink("mailto:a.b-c_d+e@example.co.uk", "a.b-c_d+e@example.co.uk"),
        ),
        ("person@example", vec![text("person@example")]),
        (
            "http://example.com",
            autolink("http://example.com", "http://example.com"),
        ),
        (
            "https://example.com",
            autolink("https://example.com", "https://example.com"),
        ),
        (
            "www.example.com",
            autolink("http://www.example.com", "www.example.com"),
        ),
        (
            "mailto:person@example.com",
            autolink("mailto:person@example.com", "mailto:person@example.com"),
        ),
        // Published GFM 0.29 names only http and https; cmark-gfm and comrak also take ftp.
        (
            "ftp://example.com",
            autolink("ftp://example.com", "ftp://example.com"),
        ),
        // cmark-gfm read `www.` itself as the domain; comrak asks a dot in the domain after it.
        ("www. x", vec![text("www. x")]),
    ];
    for (source, events) in cases {
        assert_eq!(
            blocks(source, Dialect::Gfm),
            [paragraph(events)],
            "{source}"
        );
        assert_eq!(
            blocks(source, Dialect::CommonMark),
            [paragraph(vec![text(source)])],
            "{source}"
        );
    }
}

/// C02: `^[note](key)` is a caret and an ordinary link in both dialects, no attribute.
#[test]
fn an_apple_inline_attribute_reads_as_a_caret_and_an_ordinary_link() {
    for dialect in BOTH {
        assert_eq!(
            blocks("^[note](key)", dialect),
            [paragraph(vec![
                text("^"),
                link("key", ""),
                text("note"),
                Event::LeaveLink
            ])],
            "{dialect:?}"
        );
    }
}

/// C03: no cell spans, so `||` leaves an empty cell and `^` is a cell's text; `CommonMark` reads
/// the lines as one paragraph.
#[test]
fn table_cells_never_span() {
    let source = "| a | b | c |\n| - | - | - |\n| a || b |\n| ^ | x | y |";
    assert_eq!(
        blocks(source, Dialect::Gfm),
        [table(
            vec![None, None, None],
            vec![vec![text("a")], vec![text("b")], vec![text("c")]],
            vec![
                vec![vec![text("a")], vec![], vec![text("b")]],
                vec![vec![text("^")], vec![text("x")], vec![text("y")]],
            ]
        )]
    );
    assert_eq!(
        blocks(source, Dialect::CommonMark),
        [paragraph(vec![
            text("| a | b | c |"),
            Event::SoftBreak,
            text("| - | - | - |"),
            Event::SoftBreak,
            text("| a || b |"),
            Event::SoftBreak,
            text("| ^ | x | y |"),
        ])]
    );
}

/// Both dialects take comments by the `CommonMark` 0.31 grammar, so `--` inside and `<!-->` are
/// raw HTML under GFM too.
#[test]
fn both_dialects_read_comments_by_the_commonmark_0_31_grammar() {
    for dialect in BOTH {
        for comment in ["<!-- c -->", "<!-- b -- c -->", "<!-->", "<!--->"] {
            assert_eq!(
                blocks(&format!("a {comment} b"), dialect),
                [paragraph(vec![
                    text("a "),
                    Event::RawHtml(vec![part(comment)]),
                    text(" b"),
                ])],
                "{dialect:?}: {comment}"
            );
        }
        assert_eq!(
            blocks("<!-- block -->", dialect),
            [Block::Html(vec![part("<!-- block -->\n")])],
            "{dialect:?}"
        );
    }
}

/// C05: both dialects keep a `textarea` block open across blank lines to its closing tag.
#[test]
fn a_textarea_block_runs_across_blank_lines_in_both_dialects() {
    for dialect in BOTH {
        assert_eq!(
            blocks("<textarea>\n\n*a*\n\n</textarea>\n\nafter", dialect),
            [
                Block::Html(vec![part("<textarea>\n\n*a*\n\n</textarea>\n")]),
                paragraph(vec![text("after")]),
            ],
            "{dialect:?}"
        );
    }
}

/// C06, `CommonMark` example 354: 0.31.2 counts currency symbols as punctuation, so each line
/// stays literal. cmark-gfm counted `$` alone; comrak counts all three under GFM too.
#[test]
fn currency_symbols_flank_emphasis_as_commonmark_0_31_punctuation_in_both_dialects() {
    let source = "*$*alpha.\n\n*£*bravo.\n\n*€*charlie.";
    for dialect in BOTH {
        assert_eq!(
            blocks(source, dialect),
            [
                paragraph(vec![text("*$*alpha.")]),
                paragraph(vec![text("*£*bravo.")]),
                paragraph(vec![text("*€*charlie.")]),
            ],
            "{dialect:?}"
        );
    }
}

// Sealed object fixtures

/// P01: the object flanks `_` as a letter does, so no underscore run beside it opens or closes.
#[test]
fn p01_underscore_emphasis_never_forms_beside_an_object() {
    for dialect in BOTH {
        for template in [
            "_note_{obj}",
            "{obj}_note_",
            "{obj}_note_{obj}",
            "a_{obj}_b",
        ] {
            assert_eq!(
                blocks(template, dialect),
                plain(template),
                "{dialect:?}: {template}"
            );
        }
        // An object alone between underscores is a word, as `_a_` is.
        assert_eq!(
            blocks("_{obj}_", dialect),
            [paragraph(vec![
                enter(Trait::Emphasis),
                object(0),
                leave(Trait::Emphasis)
            ])],
            "{dialect:?}"
        );
    }
}

/// P02: asterisk runs take an object as a letter, inside a word too; tildes strike under GFM alone.
#[test]
fn p02_asterisk_and_tilde_runs_flank_an_object_as_a_letter() {
    for dialect in BOTH {
        assert_eq!(
            blocks("a*{obj}*b", dialect),
            [paragraph(vec![
                text("a"),
                enter(Trait::Emphasis),
                object(0),
                leave(Trait::Emphasis),
                text("b"),
            ])],
            "{dialect:?}"
        );
        for (template, style) in [("*{obj}*", Trait::Emphasis), ("**{obj}**", Trait::Strong)] {
            assert_eq!(
                blocks(template, dialect),
                [paragraph(vec![enter(style), object(0), leave(style)])],
                "{dialect:?}: {template}"
            );
        }
        assert_eq!(
            blocks("*note*{obj}", dialect),
            [paragraph(vec![
                enter(Trait::Emphasis),
                text("note"),
                leave(Trait::Emphasis),
                object(0),
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks("{obj}*note*", dialect),
            [paragraph(vec![
                object(0),
                enter(Trait::Emphasis),
                text("note"),
                leave(Trait::Emphasis),
            ])],
            "{dialect:?}"
        );
    }
    for template in ["~~{obj}~~", "~{obj}~"] {
        assert_eq!(
            blocks(template, Dialect::Gfm),
            [paragraph(vec![
                enter(Trait::Deletion),
                object(0),
                leave(Trait::Deletion)
            ])],
            "{template}"
        );
        assert_eq!(
            blocks(template, Dialect::CommonMark),
            plain(template),
            "{template}"
        );
    }
}

/// P03 under comrak: an object is a domain character, so an extended autolink runs on through it
/// to whitespace and its address has the stand-in. `CommonMark` links none.
#[test]
fn p03_an_extended_autolink_runs_through_an_object() {
    let https = || autolink("https://example.com", "https://example.com");
    let through = |destination: &str, before: &str, after: &str| {
        vec![
            link(destination, ""),
            text(before),
            object(0),
            text(after),
            Event::LeaveLink,
        ]
        .into_iter()
        .filter(|event| *event != text(""))
        .collect::<Vec<_>>()
    };
    let cases: Vec<(&str, Vec<Event>)> = vec![
        (
            "www.example.com{obj}tail",
            through(
                "http://www.example.com\u{FFFC}tail",
                "www.example.com",
                "tail",
            ),
        ),
        (
            "www.example.com/{obj}",
            through("http://www.example.com/\u{FFFC}", "www.example.com/", ""),
        ),
        (
            "https://example.com/{obj}",
            through("https://example.com/\u{FFFC}", "https://example.com/", ""),
        ),
        (
            "https://example.com{obj}",
            through("https://example.com\u{FFFC}", "https://example.com", ""),
        ),
        (
            "https://example.com/a{obj}b",
            through(
                "https://example.com/a\u{FFFC}b",
                "https://example.com/a",
                "b",
            ),
        ),
        ("https://{obj}", through("https://\u{FFFC}", "https://", "")),
        (
            "www.example.com/({obj})",
            through(
                "http://www.example.com/(\u{FFFC})",
                "www.example.com/(",
                ")",
            ),
        ),
        (
            "www.example.com.{obj}",
            through("http://www.example.com.\u{FFFC}", "www.example.com.", ""),
        ),
        (
            "{obj}https://example.com",
            [vec![object(0)], https()].concat(),
        ),
        // The byte before `www.` must be whitespace or `*_~([`, and a placeholder's is neither.
        ("{obj}www.example.com", plain_events("{obj}www.example.com")),
        // comrak asks a dot in the domain after `www.`.
        ("www.{obj}", plain_events("www.{obj}")),
    ];
    for (template, events) in cases {
        assert_eq!(
            blocks(template, Dialect::Gfm),
            [paragraph(events)],
            "{template}"
        );
        assert_eq!(
            blocks(template, Dialect::CommonMark),
            plain(template),
            "{template}"
        );
    }
    assert_eq!(
        blocks("*www.example.com{obj}*", Dialect::Gfm),
        [paragraph(
            [
                vec![enter(Trait::Emphasis)],
                through("http://www.example.com\u{FFFC}", "www.example.com", ""),
                vec![leave(Trait::Emphasis)],
            ]
            .concat()
        )]
    );
    assert_eq!(
        blocks("*www.example.com{obj}*", Dialect::CommonMark),
        [paragraph(vec![
            enter(Trait::Emphasis),
            text("www.example.com"),
            object(0),
            leave(Trait::Emphasis),
        ])]
    );
}

/// P04: an email autolink's local part and domain both end at an object.
#[test]
fn p04_an_email_autolink_ends_at_an_object() {
    let email = || autolink("mailto:person@example.com", "person@example.com");
    let cases: Vec<(&str, Vec<Event>)> = vec![
        (
            "person@example.com{obj}",
            [email(), vec![object(0)]].concat(),
        ),
        (
            "{obj}person@example.com",
            [vec![object(0)], email()].concat(),
        ),
        (
            "mailto:person@example.com{obj}",
            [
                autolink("mailto:person@example.com", "mailto:person@example.com"),
                vec![object(0)],
            ]
            .concat(),
        ),
        (
            "person@{obj}example.com",
            vec![text("person@"), object(0), text("example.com")],
        ),
        (
            "per{obj}son@example.com",
            [
                vec![text("per"), object(0)],
                autolink("mailto:son@example.com", "son@example.com"),
            ]
            .concat(),
        ),
    ];
    for (template, events) in cases {
        assert_eq!(
            blocks(template, Dialect::Gfm),
            [paragraph(events)],
            "{template}"
        );
        assert_eq!(
            blocks(template, Dialect::CommonMark),
            plain(template),
            "{template}"
        );
    }
}

/// P05: an object beside a pipe, an escaped pipe or an empty cell stays in its cell under GFM;
/// `CommonMark` keeps the lines as paragraph text with the object in order.
#[test]
fn p05_an_object_beside_a_pipe_stays_in_its_cell() {
    let header = || vec![vec![text("a")], vec![text("b")]];
    let wide = || vec![vec![text("a")], vec![text("b")], vec![text("c")]];
    let cases: Vec<(&str, Block)> = vec![
        (
            "|{obj}| b |\n| - | - |\n| c | d |",
            table(
                vec![None, None],
                vec![vec![object(0)], vec![text("b")]],
                vec![vec![vec![text("c")], vec![text("d")]]],
            ),
        ),
        (
            "| a | b |\n| - | - |\n| c |{obj}|",
            table(
                vec![None, None],
                header(),
                vec![vec![vec![text("c")], vec![object(0)]]],
            ),
        ),
        (
            "| a | b |\n| - | - |\n| c \\|{obj} | d |",
            table(
                vec![None, None],
                header(),
                vec![vec![vec![text("c |"), object(0)], vec![text("d")]]],
            ),
        ),
        (
            "| a | b | c |\n| - | - | - |\n| {obj}|| d |",
            table(
                vec![None, None, None],
                wide(),
                vec![vec![vec![object(0)], vec![], vec![text("d")]]],
            ),
        ),
        (
            "| a | b | c |\n| - | - | - |\n| x ||{obj}|",
            table(
                vec![None, None, None],
                wide(),
                vec![vec![vec![text("x")], vec![], vec![object(0)]]],
            ),
        ),
    ];
    for (template, expected) in cases {
        assert_eq!(blocks(template, Dialect::Gfm), [expected], "{template}");
        let mut events = Vec::new();
        for (index, line) in template.split('\n').enumerate() {
            if index > 0 {
                events.push(Event::SoftBreak);
            }
            // One object a page, so each line's first is object 0; an escaped pipe reads as `|`.
            events.extend(plain_events(&line.replace("\\|", "|")));
        }
        assert_eq!(
            blocks(template, Dialect::CommonMark),
            [paragraph(events)],
            "{template}"
        );
    }
}

/// P05: comrak drops a row's cells past the header's count, and R1 gives a dropped cell's object
/// to the end of its row's last kept cell, so it renders and copies in source order.
#[test]
fn p05_an_excess_cells_object_ends_its_rows_last_cell() {
    let header = || vec![vec![text("a")], vec![text("b")]];
    let excess = "| a | b |\n| - | - |\n| c | d | {obj} |\n| e | f {obj} |";
    assert_eq!(
        blocks(excess, Dialect::Gfm),
        [table(
            vec![None, None],
            header(),
            vec![
                vec![vec![text("c")], vec![text("d"), object(0)]],
                vec![vec![text("e")], vec![text("f "), object(1)]],
            ]
        )]
    );
    assert_eq!(
        blocks(excess, Dialect::CommonMark),
        [paragraph(vec![
            text("| a | b |"),
            Event::SoftBreak,
            text("| - | - |"),
            Event::SoftBreak,
            text("| c | d | "),
            object(0),
            text(" |"),
            Event::SoftBreak,
            text("| e | f "),
            object(1),
            text(" |"),
        ])]
    );
    assert_eq!(
        blocks("| a | b |\n| - | - |\n| {obj} | d | {obj} |", Dialect::Gfm),
        [table(
            vec![None, None],
            header(),
            vec![vec![vec![object(0)], vec![text("d"), object(1)]]]
        )]
    );

    // A plain line after a table is one more row.
    let quoted = "> | a | b |\n> | - | - |\n> | c | d | {obj} |\n> after {obj}";
    assert_eq!(
        blocks(quoted, Dialect::Gfm),
        [Block::Quote(vec![table(
            vec![None, None],
            header(),
            vec![
                vec![vec![text("c")], vec![text("d"), object(0)]],
                vec![vec![text("after "), object(1)], vec![]],
            ]
        )])]
    );
    assert_eq!(
        blocks(quoted, Dialect::CommonMark),
        [Block::Quote(vec![paragraph(vec![
            text("| a | b |"),
            Event::SoftBreak,
            text("| - | - |"),
            Event::SoftBreak,
            text("| c | d | "),
            object(0),
            text(" |"),
            Event::SoftBreak,
            text("after "),
            object(1),
        ])])]
    );

    let listed = "- | a | b |\n  | - | - |\n  | c | d | {obj} |\n- next {obj}";
    assert_eq!(
        blocks(listed, Dialect::Gfm),
        [bullets(
            true,
            vec![
                item(
                    None,
                    vec![table(
                        vec![None, None],
                        header(),
                        vec![vec![vec![text("c")], vec![text("d"), object(0)]]]
                    )]
                ),
                item(None, vec![paragraph(vec![text("next "), object(1)])]),
            ]
        )]
    );
}

/// P05: an object in the delimiter row leaves it no delimiter row, so neither dialect has a table.
#[test]
fn p05_an_object_in_the_delimiter_row_leaves_no_table() {
    for dialect in BOTH {
        assert_eq!(
            blocks("| a | b |\n| - |{obj} - |\n| c | d |", dialect),
            [paragraph(vec![
                text("| a | b |"),
                Event::SoftBreak,
                text("| - |"),
                object(0),
                text(" - |"),
                Event::SoftBreak,
                text("| c | d |"),
            ])],
            "{dialect:?}"
        );
    }
}

/// P06: an object in a link's label or an image's alt text stays there.
#[test]
fn p06_label_and_alt_objects_stay_inside_their_element() {
    for dialect in BOTH {
        assert_eq!(
            blocks("[a {obj} b](https://example.com/)", dialect),
            [paragraph(vec![
                link("https://example.com/", ""),
                text("a "),
                object(0),
                text(" b"),
                Event::LeaveLink,
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks("[{obj}](https://example.com/)", dialect),
            [paragraph(vec![
                link("https://example.com/", ""),
                object(0),
                Event::LeaveLink
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks("![a {obj} b](https://example.com/i.png)", dialect),
            [paragraph(vec![image(
                vec![part("a "), part_object(0), part(" b")],
                parts("https://example.com/i.png"),
                vec![],
            )])],
            "{dialect:?}"
        );
        // An object between `!` and `[` leaves an ordinary link.
        assert_eq!(
            blocks("!{obj}[alt](https://example.com/i.png)", dialect),
            [paragraph(vec![
                text("!"),
                object(0),
                link("https://example.com/i.png", ""),
                text("alt"),
                Event::LeaveLink,
            ])],
            "{dialect:?}"
        );
    }
}

/// P06: an inline destination's object follows the element's text, as in the source, and refuses
/// its address; a title's object follows it too and leaves the address as it was.
#[test]
fn p06_inline_destination_and_title_objects_follow_the_elements_text() {
    for dialect in BOTH {
        assert_eq!(
            blocks("[label](https://example.com/{obj}) after", dialect),
            [paragraph(vec![
                link("https://example.com/\u{FFFC}", ""),
                text("label"),
                Event::LeaveLink,
                object(0),
                text(" after"),
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks("[a](<https://example.com/{obj}>)", dialect),
            [paragraph(vec![
                link("https://example.com/\u{FFFC}", ""),
                text("a"),
                Event::LeaveLink,
                object(0),
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks("[label](https://example.com/ \"t {obj}\") after", dialect),
            [paragraph(vec![
                link("https://example.com/", "t \u{FFFC}"),
                text("label"),
                Event::LeaveLink,
                object(0),
                text(" after"),
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks("![alt](https://example.com/{obj}.png)", dialect),
            [paragraph(vec![image(
                vec![part("alt")],
                vec![part("https://example.com/"), part_object(0), part(".png")],
                vec![],
            )])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks("![alt](https://example.com/i.png \"t {obj}\")", dialect),
            [paragraph(vec![image(
                vec![part("alt")],
                parts("https://example.com/i.png"),
                vec![part("t "), part_object(0)],
            )])],
            "{dialect:?}"
        );
    }
}

/// P06: an object between `]` and `(` breaks the inline link; GFM then autolinks the exposed URL.
#[test]
fn p06_an_object_between_the_brackets_and_the_destination_breaks_the_link() {
    let template = "[label]{obj}(https://example.com/)";
    assert_eq!(
        blocks(template, Dialect::Gfm),
        [paragraph(
            [
                vec![text("[label]"), object(0), text("(")],
                autolink("https://example.com/", "https://example.com/"),
                vec![text(")")],
            ]
            .concat()
        )]
    );
    assert_eq!(blocks(template, Dialect::CommonMark), plain(template));
}

/// P06: a definition's object stays at the definition, before or after its uses; every use of a
/// destination with one refuses it, and no object moves into a use.
#[test]
fn p06_reference_definitions_keep_their_objects_and_every_use_refuses_their_address() {
    let refused = |label: &str| {
        vec![
            link("https://example.com/\u{FFFC}", ""),
            text(label),
            Event::LeaveLink,
        ]
    };
    // comrak resolves references only while their addresses add up to no more than the page, so a
    // page this short keeps its third use as text (`reference_expansion_stops_at_the_page_size`).
    let uses = |last: usize| {
        [
            refused("x"),
            vec![text(", ")],
            refused("r"),
            vec![text(" and [r] "), object(last)],
        ]
        .concat()
    };
    for dialect in BOTH {
        assert_eq!(
            blocks(
                "[r]: https://example.com/{obj}\n\n[x][r], [r][] and [r] {obj}",
                dialect
            ),
            [objects(&[0]), paragraph(uses(1))],
            "{dialect:?}: before"
        );
        assert_eq!(
            blocks(
                "[x][r], [r][] and [r] {obj}\n\n[r]: https://example.com/{obj}",
                dialect
            ),
            [paragraph(uses(0)), objects(&[1])],
            "{dialect:?}: after"
        );
        // A title's stand-in refuses nothing, as an inline title's object refuses nothing.
        assert_eq!(
            blocks("[r]: https://example.com/ \"t {obj}\"\n\n[x][r]", dialect),
            [
                objects(&[0]),
                paragraph(vec![
                    link("https://example.com/", "t \u{FFFC}"),
                    text("x"),
                    Event::LeaveLink
                ]),
            ],
            "{dialect:?}: a title"
        );
        assert_eq!(
            blocks(
                "![a][r] {obj}\n\n[r]: https://example.com/i.png \"t {obj}\"",
                dialect
            ),
            [
                paragraph(vec![
                    image(
                        vec![part("a")],
                        parts("https://example.com/i.png"),
                        vec![part("t \u{FFFC}")]
                    ),
                    text(" "),
                    object(0),
                ]),
                objects(&[1]),
            ],
            "{dialect:?}: an image"
        );
        // Each object is its own scalar, so no later label matches a label with one.
        assert_eq!(
            blocks(
                "[a{obj}]: https://example.com/\n\n[a{obj}] and [a]",
                dialect
            ),
            [
                objects(&[0]),
                paragraph(vec![text("[a"), object(1), text("] and [a]")]),
            ],
            "{dialect:?}: a label"
        );
        // The first definition of a label wins; the ignored one keeps its object.
        assert_eq!(
            blocks(
                "[r]: https://example.com/a\n[r]: https://example.com/{obj}\n\n[r] {obj}",
                dialect
            ),
            [
                objects(&[0]),
                paragraph(vec![
                    link("https://example.com/a", ""),
                    text("r"),
                    Event::LeaveLink,
                    text(" "),
                    object(1),
                ]),
            ],
            "{dialect:?}: a second definition"
        );
    }
}

/// comrak 0.57.0 caps the address bytes references expand to at `min(page bytes, 100,000)`,
/// where cmark allows at least 100,000; padding the page lets the third use resolve.
#[test]
fn reference_expansion_stops_at_the_page_size() {
    let page = "[r]: https://example.com/{obj}\n\n[x][r], [r][] and [r] {obj}";
    let last = |padding: &str| match blocks(&format!("{page}{padding}"), Dialect::CommonMark).get(1)
    {
        Some(Block::Paragraph(events)) => events
            .iter()
            .filter(|event| **event == Event::LeaveLink)
            .count(),
        other => panic!("{other:?}"),
    };
    assert_eq!(last(""), 2);
    assert_eq!(last(&format!("\n\n{}", "p".repeat(20))), 3);
}

/// P06: an angle autolink's text shows its object once, and its address has the stand-in.
#[test]
fn p06_an_angle_autolink_shows_its_object_once() {
    for dialect in BOTH {
        assert_eq!(
            blocks("<https://example.com/{obj}/tail> after", dialect),
            [paragraph(vec![
                link("https://example.com/\u{FFFC}/tail", ""),
                text("https://example.com/"),
                object(0),
                text("/tail"),
                Event::LeaveLink,
                text(" after"),
            ])],
            "{dialect:?}"
        );
    }
}

/// P07: an object where a tag or attribute name must continue leaves no raw HTML.
#[test]
fn p07_an_object_in_a_tag_or_attribute_name_leaves_literal_text() {
    for dialect in BOTH {
        assert_eq!(blocks("<{obj}>", dialect), plain("<{obj}>"), "{dialect:?}");
        assert_eq!(
            blocks("<span data-{obj}>x</span>", dialect),
            [paragraph(vec![
                text("<span data-"),
                object(0),
                text(">x"),
                Event::RawHtml(vec![part("</span>")]),
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks("<span data-a{obj}=\"v\">x</span>", dialect),
            [paragraph(vec![
                text("<span data-a"),
                object(0),
                text("=\"v\">x"),
                Event::RawHtml(vec![part("</span>")]),
            ])],
            "{dialect:?}"
        );
    }
}

/// P07: an object in an attribute value or a comment stays in its raw HTML.
#[test]
fn p07_attribute_value_and_comment_objects_stay_in_their_raw_html() {
    for dialect in BOTH {
        for (template, open, close) in [
            (
                "a <span title=\"t {obj}\">x</span> b",
                "<span title=\"t ",
                "\">",
            ),
            (
                "a <span title='t {obj}'>x</span> b",
                "<span title='t ",
                "'>",
            ),
            ("a <span title=t{obj}>x</span> b", "<span title=t", ">"),
        ] {
            assert_eq!(
                blocks(template, dialect),
                [paragraph(vec![
                    text("a "),
                    Event::RawHtml(vec![part(open), part_object(0), part(close)]),
                    text("x"),
                    Event::RawHtml(vec![part("</span>")]),
                    text(" b"),
                ])],
                "{dialect:?}: {template}"
            );
        }
        assert_eq!(
            blocks("a <!-- {obj} --> b", dialect),
            [paragraph(vec![
                text("a "),
                Event::RawHtml(vec![part("<!-- "), part_object(0), part(" -->")]),
                text(" b"),
            ])],
            "{dialect:?}"
        );
    }
}

/// P07: an object in an `img` or `style` address stays in the raw HTML, in a paragraph or a block.
#[test]
fn p07_image_and_style_addresses_keep_their_objects_in_the_raw_html() {
    for dialect in BOTH {
        assert_eq!(
            blocks(
                "a <img src=\"https://example.com/{obj}.png\" alt=\"pic\"> b",
                dialect
            ),
            [paragraph(vec![
                text("a "),
                Event::RawHtml(vec![
                    part("<img src=\"https://example.com/"),
                    part_object(0),
                    part(".png\" alt=\"pic\">"),
                ]),
                text(" b"),
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks(
                "<img src=\"https://example.com/{obj}.png\" alt=\"pic\">",
                dialect
            ),
            [Block::Html(vec![
                part("<img src=\"https://example.com/"),
                part_object(0),
                part(".png\" alt=\"pic\">\n"),
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks(
                "a <span style=\"background: url(https://example.com/{obj})\">x</span> b",
                dialect
            ),
            [paragraph(vec![
                text("a "),
                Event::RawHtml(vec![
                    part("<span style=\"background: url(https://example.com/"),
                    part_object(0),
                    part(")\">"),
                ]),
                text("x"),
                Event::RawHtml(vec![part("</span>")]),
                text(" b"),
            ])],
            "{dialect:?}"
        );
    }
}

/// P07: an HTML block's object stays in its literal, a `script` body's too.
#[test]
fn p07_html_block_and_script_bodies_keep_their_objects_in_place() {
    for dialect in BOTH {
        assert_eq!(
            blocks("<div>\n*a* {obj}\n</div>", dialect),
            [Block::Html(vec![
                part("<div>\n*a* "),
                part_object(0),
                part("\n</div>\n")
            ])],
            "{dialect:?}"
        );
        assert_eq!(
            blocks("<script>\nvar a = \"{obj}\";\n</script>", dialect),
            [Block::Html(vec![
                part("<script>\nvar a = \""),
                part_object(0),
                part("\";\n</script>\n"),
            ])],
            "{dialect:?}"
        );
    }
}

/// An image inside a link keeps its own address and objects.
#[test]
fn an_image_inside_a_link_keeps_its_own_address() {
    for dialect in BOTH {
        assert_eq!(
            blocks(
                "[![a {obj}](https://example.com/i.png)](https://example.com/) b",
                dialect
            ),
            [paragraph(vec![
                link("https://example.com/", ""),
                image(
                    vec![part("a "), part_object(0)],
                    parts("https://example.com/i.png"),
                    vec![]
                ),
                Event::LeaveLink,
                text(" b"),
            ])],
            "{dialect:?}"
        );
    }
}

/// Under GFM each cell is its own; under `CommonMark` the same lines are one paragraph.
#[test]
fn table_source_becomes_cells_only_under_gfm() {
    let template = "| a | b | c |\n| - | - | - |\n| {obj} || ^ |";
    assert_eq!(
        blocks(template, Dialect::Gfm),
        [table(
            vec![None, None, None],
            vec![vec![text("a")], vec![text("b")], vec![text("c")]],
            vec![vec![vec![object(0)], vec![], vec![text("^")]]]
        )]
    );
    assert_eq!(
        blocks(template, Dialect::CommonMark),
        [paragraph(vec![
            text("| a | b | c |"),
            Event::SoftBreak,
            text("| - | - | - |"),
            Event::SoftBreak,
            text("| "),
            object(0),
            text(" || ^ |"),
        ])]
    );
}

/// Alignments and task items, which no fixture above names.
#[test]
fn alignments_and_task_items_keep_their_shape() {
    assert_eq!(
        blocks("| a | b | c | d |\n| :- | :-: | -: | - |", Dialect::Gfm),
        [table(
            vec![
                Some(Alignment::Left),
                Some(Alignment::Center),
                Some(Alignment::Right),
                None
            ],
            vec![
                vec![text("a")],
                vec![text("b")],
                vec![text("c")],
                vec![text("d")]
            ],
            vec![]
        )]
    );
    assert_eq!(
        blocks("- [ ] a {obj}\n- [x] b\n- c", Dialect::Gfm),
        [bullets(
            true,
            vec![
                item(Some(false), vec![paragraph(vec![text("a "), object(0)])]),
                item(Some(true), vec![paragraph(vec![text("b")])]),
                item(None, vec![paragraph(vec![text("c")])]),
            ]
        )]
    );
    assert_eq!(
        blocks("3. a\n4. b", Dialect::CommonMark),
        [Block::List {
            ordered: true,
            start: 3,
            tight: true,
            items: vec![
                item(None, vec![paragraph(vec![text("a")])]),
                item(None, vec![paragraph(vec![text("b")])]),
            ]
        }]
    );
}
