import AppKit
import XCTest

@testable import CompanionKit

/// Plan R1's fixtures under both dialects: the grammar cases its row names, sealed objects beside
/// each construct of research cases P01 to P07, and what the native rendering refuses.
@MainActor
final class MarkdownSealedAtomTests: XCTestCase {
    /// `template` with each `{obj}` a U+FFFC, and the UTF-16 offset of each.
    private func page(_ template: String) -> (text: String, offsets: [Int]) {
        var text = ""
        var offsets: [Int] = []
        for (index, piece) in template.components(separatedBy: "{obj}").enumerated() {
            if index > 0 {
                offsets.append(text.utf16.count)
                text += "\u{FFFC}"
            }
            text += piece
        }
        return (text, offsets)
    }

    private func marked(_ text: String) -> String {
        text.replacingOccurrences(of: "{obj}", with: "\u{FFFC}")
    }

    private func parse(_ template: String, _ dialect: PreviewDialect) throws -> [MarkdownBlock] {
        let (text, offsets) = page(template)
        return try MarkdownParser.parse(text, objects: offsets, dialect: dialect).blocks
    }

    /// The template as one paragraph of text with its objects in place, as a page with no syntax reads.
    private func plain(_ template: String) -> [MarkdownBlock] {
        var events: [PreviewEvent] = []
        for (index, piece) in template.components(separatedBy: "{obj}").enumerated() {
            if index > 0 { events.append(.object(String(index - 1))) }
            if !piece.isEmpty { events.append(.text(piece)) }
        }
        return [.paragraph(events)]
    }

    private func autolink(_ destination: String, _ text: String) -> [PreviewEvent] {
        [.enterLink(destination: [.text(destination)], title: []), .text(text), .leaveLink]
    }

    /// The page's source with chip k + 1 at the kth `{obj}`.
    private func source(_ template: String) -> (NSAttributedString, [ChipAttachment]) {
        let source = NSMutableAttributedString(string: "")
        var chips: [ChipAttachment] = []
        for (index, piece) in template.components(separatedBy: "{obj}").enumerated() {
            if index > 0 {
                let chip = ChipAttachment(info: ChipInfo(
                    chipId: UInt64(index), kind: "text", excerpt: "test-face", sizeLabel: "small", concealed: false
                ))
                chips.append(chip)
                source.append(NSAttributedString(attachment: chip))
            }
            source.append(NSAttributedString(string: piece))
        }
        return (source, chips)
    }

    /// The page as the preview renders it, cut before a closing bold paragraph that the plain
    /// fallback would show with its asterisks.
    private func render(
        _ template: String, _ dialect: PreviewDialect, file: StaticString = #filePath, line: UInt = #line
    ) -> (NSAttributedString, [ChipAttachment]) {
        let (page, chips) = source(template)
        let closed = NSMutableAttributedString(attributedString: page)
        closed.append(NSAttributedString(string: "\n\n**fin**"))
        let rendered = MarkdownPreviewView.render(closed, dialect: dialect)
        let fin = (rendered.string as NSString).range(of: "fin\n", options: [.backwards, .anchored])
        guard fin.location != NSNotFound,
              let font = rendered.attribute(.font, at: fin.location, effectiveRange: nil) as? NSFont,
              NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        else {
            XCTFail("\(dialect): \(template.debugDescription) rendered as the plain fallback", file: file, line: line)
            return (rendered, chips)
        }
        return (rendered.attributedSubstring(from: NSRange(location: 0, length: fin.location)), chips)
    }

    private func attachments(in rendered: NSAttributedString) -> [(location: Int, attachment: NSTextAttachment)] {
        var found: [(location: Int, attachment: NSTextAttachment)] = []
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) {
            value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            for location in range.location..<NSMaxRange(range) { found.append((location, attachment)) }
        }
        return found
    }

    /// Each run with a link, in rendered order, with its address.
    private func linkRuns(in rendered: NSAttributedString) -> [(String, String)] {
        var runs: [(String, String)] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard let value else { return }
            let address = (value as? URL)?.absoluteString ?? "\(value)"
            runs.append(((rendered.string as NSString).substring(with: range), address))
        }
        return runs
    }

    /// Each image descriptor once, in rendered order, with the text it marks.
    private func images(in rendered: NSAttributedString) -> [(PreviewAddress, String)] {
        var found: [(PreviewImageDescriptor, String)] = []
        rendered.enumerateAttribute(.previewImage, in: NSRange(location: 0, length: rendered.length)) {
            value, range, _ in
            guard let descriptor = value as? PreviewImageDescriptor else { return }
            let text = (rendered.string as NSString).substring(with: range)
            if let last = found.last, last.0 == descriptor {
                found[found.count - 1].1 += text
            } else {
                found.append((descriptor, text))
            }
        }
        return found.map { ($0.0.destination, $0.1) }
    }

    /// The `[row, column]` of the native table cell at `location`, nil outside any table.
    private func cell(at location: Int, in rendered: NSAttributedString) -> [Int]? {
        let style = rendered.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        guard let block = style?.textBlocks.last as? NSTextTableBlock else { return nil }
        return [block.startingRow, block.startingColumn]
    }

    private func tableCells(in rendered: NSAttributedString) -> [NSTextTableBlock] {
        var cells: [ObjectIdentifier: NSTextTableBlock] = [:]
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) {
            value, _, _ in
            for case let cell as NSTextTableBlock in (value as? NSParagraphStyle)?.textBlocks ?? [] {
                cells[ObjectIdentifier(cell)] = cell
            }
        }
        return Array(cells.values)
    }

    /// One page under one dialect: its blocks, then its rendering's text, every object once in
    /// `order` (source order by default) and outside any link, every link run and every image.
    @discardableResult
    private func check(
        _ template: String, _ dialect: PreviewDialect, _ expected: [MarkdownBlock], shows: String,
        order: [Int]? = nil, links: [(String, String)] = [], images expectedImages: [(PreviewAddress, String)] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> NSAttributedString {
        let name = "\(dialect): \(template.debugDescription)"
        XCTAssertEqual(try parse(template, dialect), expected, name, file: file, line: line)
        let (rendered, chips) = render(template, dialect, file: file, line: line)
        XCTAssertEqual(rendered.string, marked(shows), name, file: file, line: line)
        let found = attachments(in: rendered)
        XCTAssertEqual(
            found.map { item in chips.firstIndex { $0 === item.attachment } ?? -1 }, order ?? Array(chips.indices),
            "\(name): objects", file: file, line: line
        )
        for item in found {
            XCTAssertNil(rendered.attribute(.link, at: item.location, effectiveRange: nil),
                         "\(name): an object took a link", file: file, line: line)
        }
        let runs = linkRuns(in: rendered)
        XCTAssertEqual(runs.map(\.0), links.map { marked($0.0) }, "\(name): linked text", file: file, line: line)
        XCTAssertEqual(runs.map(\.1), links.map(\.1), "\(name): link addresses", file: file, line: line)
        let shown = images(in: rendered)
        XCTAssertEqual(shown.map(\.0), expectedImages.map(\.0), "\(name): image addresses", file: file, line: line)
        XCTAssertEqual(shown.map(\.1), expectedImages.map { marked($0.1) }, "\(name): image text", file: file, line: line)
        return rendered
    }

    // MARK: Ordinary text conformance

    /// C01: GFM strikes single and double tilde runs and leaves a triple run literal; a triple
    /// tilde fence opens a code block in both dialects.
    func testSingleAndDoubleTildesStrikeUnderGFMAndTripleTildesStayLiteral() throws {
        XCTAssertEqual(try parse("~a~ ~~b~~ ~~~c~~~", .gfm), [.paragraph([
            .enterMarkdown(.deletion), .text("a"), .leaveMarkdown(.deletion), .text(" "),
            .enterMarkdown(.deletion), .text("b"), .leaveMarkdown(.deletion), .text(" ~~~c~~~"),
        ])])
        XCTAssertEqual(try parse("~a~ ~~b~~ ~~~c~~~", .commonMark), [.paragraph([.text("~a~ ~~b~~ ~~~c~~~")])])
        for dialect in PreviewDialect.allCases {
            XCTAssertEqual(try parse("~~~\ncode\n~~~", dialect), [.codeBlock(info: [], literal: [.text("code\n")])],
                           "\(dialect)")
        }
    }

    /// GFM's extended autolinks drop trailing punctuation and an unbalanced `)` and keep balanced
    /// parentheses and a query; CommonMark leaves every bare address as text.
    func testExtendedAutolinksDropTrailingPunctuationAndKeepBalancedParentheses() throws {
        let cases: [(String, [PreviewEvent])] = [
            ("www.example.com.", autolink("http://www.example.com", "www.example.com") + [.text(".")]),
            ("(www.example.com)", [.text("(")] + autolink("http://www.example.com", "www.example.com") + [.text(")")]),
            ("www.example.com/a_(b)", autolink("http://www.example.com/a_(b)", "www.example.com/a_(b)")),
            ("www.example.com/a)", autolink("http://www.example.com/a", "www.example.com/a") + [.text(")")]),
            ("https://example.com/?", autolink("https://example.com/", "https://example.com/") + [.text("?")]),
            ("https://example.com/?q=1", autolink("https://example.com/?q=1", "https://example.com/?q=1")),
            ("https://example.com/a?b.", autolink("https://example.com/a?b", "https://example.com/a?b") + [.text(".")]),
        ]
        for (source, events) in cases {
            XCTAssertEqual(try parse(source, .gfm), [.paragraph(events)], source)
            XCTAssertEqual(try parse(source, .commonMark), [.paragraph([.text(source)])], source)
        }
    }

    func testEmailAndProtocolAutolinksFollowThePinnedGFMParser() throws {
        let cases: [(String, [PreviewEvent])] = [
            ("person@example.com", autolink("mailto:person@example.com", "person@example.com")),
            ("person@example.com.", autolink("mailto:person@example.com", "person@example.com") + [.text(".")]),
            ("a.b-c_d+e@example.co.uk", autolink("mailto:a.b-c_d+e@example.co.uk", "a.b-c_d+e@example.co.uk")),
            ("person@example", [.text("person@example")]),
            ("http://example.com", autolink("http://example.com", "http://example.com")),
            ("https://example.com", autolink("https://example.com", "https://example.com")),
            ("www.example.com", autolink("http://www.example.com", "www.example.com")),
            ("mailto:person@example.com", autolink("mailto:person@example.com", "mailto:person@example.com")),
            // Published GFM 0.29 names only http:// and https://; comrak also takes ftp://.
            ("ftp://example.com", autolink("ftp://example.com", "ftp://example.com")),
            ("www. x", [.text("www. x")]),
        ]
        for (source, events) in cases {
            XCTAssertEqual(try parse(source, .gfm), [.paragraph(events)], source)
            XCTAssertEqual(try parse(source, .commonMark), [.paragraph([.text(source)])], source)
        }
    }

    /// C02: `^[note](key)` is a caret and an ordinary link in both dialects, no attribute.
    func testAnAppleInlineAttributeReadsAsACaretAndAnOrdinaryLink() throws {
        for dialect in PreviewDialect.allCases {
            XCTAssertEqual(try parse("^[note](key)", dialect), [.paragraph([
                .text("^"), .enterLink(destination: [.text("key")], title: []), .text("note"), .leaveLink,
            ])], "\(dialect)")
        }
    }

    /// C03: no cell spans, so `||` leaves an empty cell and `^` is a cell's text; CommonMark reads
    /// the lines as one paragraph.
    func testTableCellsNeverSpan() throws {
        let source = "| a | b | c |\n| - | - | - |\n| a || b |\n| ^ | x | y |"
        XCTAssertEqual(try parse(source, .gfm), [.table(
            alignments: [nil, nil, nil], header: [[.text("a")], [.text("b")], [.text("c")]],
            body: [[[.text("a")], [], [.text("b")]], [[.text("^")], [.text("x")], [.text("y")]]]
        )])
        XCTAssertEqual(try parse(source, .commonMark), [.paragraph([
            .text("| a | b | c |"), .softBreak, .text("| - | - | - |"), .softBreak, .text("| a || b |"), .softBreak,
            .text("| ^ | x | y |"),
        ])])
    }

    /// Both parsers take comments by the CommonMark 0.31 grammar, so `--` inside and `<!-->` are raw
    /// HTML under GFM too (GFM examples 649 and 650 in `MarkdownCorpusTests`).
    func testBothParsersReadCommentsByTheCommonMark031Grammar() throws {
        for dialect in PreviewDialect.allCases {
            for comment in ["<!-- c -->", "<!-- b -- c -->", "<!-->", "<!--->"] {
                XCTAssertEqual(try parse("a \(comment) b", dialect), [.paragraph([
                    .text("a "), .rawHTML([.text(comment)]), .text(" b"),
                ])], "\(dialect): \(comment)")
            }
            XCTAssertEqual(try parse("<!-- block -->", dialect), [.html([.text("<!-- block -->\n")])], "\(dialect)")
        }
    }

    /// C05: both parsers keep a `textarea` block open across blank lines to its closing tag;
    /// published GFM 0.29's first start condition names only `script`, `pre` and `style`.
    func testATextareaBlockRunsAcrossBlankLinesInBothDialects() throws {
        for dialect in PreviewDialect.allCases {
            XCTAssertEqual(try parse("<textarea>\n\n*a*\n\n</textarea>\n\nafter", dialect), [
                .html([.text("<textarea>\n\n*a*\n\n</textarea>\n")]), .paragraph([.text("after")]),
            ], "\(dialect)")
        }
    }

    /// Comrak uses CommonMark punctuation in both modes for this currency-symbol fixture.
    func testCurrencySymbolsLeaveTheseEmphasisDelimitersLiteralInBothDialects() throws {
        let source = "*$*alpha.\n\n*£*bravo.\n\n*€*charlie."
        XCTAssertEqual(try parse(source, .commonMark), [
            .paragraph([.text("*$*alpha.")]), .paragraph([.text("*£*bravo.")]), .paragraph([.text("*€*charlie.")]),
        ])
        XCTAssertEqual(try parse(source, .gfm), [
            .paragraph([.text("*$*alpha.")]), .paragraph([.text("*£*bravo.")]), .paragraph([.text("*€*charlie.")]),
        ])
    }

    // MARK: Sealed-object fixtures

    /// P01: the object flanks `_` as a letter does, so no underscore run beside it opens or closes.
    func testP01UnderscoreEmphasisNeverFormsBesideAnObject() throws {
        for dialect in PreviewDialect.allCases {
            try check("_note_{obj}", dialect, [.paragraph([.text("_note_"), .object("0")])], shows: "_note_{obj}\n")
            try check("{obj}_note_", dialect, [.paragraph([.object("0"), .text("_note_")])], shows: "{obj}_note_\n")
            try check("{obj}_note_{obj}", dialect, [.paragraph([.object("0"), .text("_note_"), .object("1")])],
                      shows: "{obj}_note_{obj}\n")
            try check("a_{obj}_b", dialect, [.paragraph([.text("a_"), .object("0"), .text("_b")])], shows: "a_{obj}_b\n")
            // An object alone between underscores is a word, as `_a_` is.
            try check("_{obj}_", dialect, [.paragraph([
                .enterMarkdown(.emphasis), .object("0"), .leaveMarkdown(.emphasis),
            ])], shows: "{obj}\n")
        }
    }

    /// P02: asterisk runs take an object as a letter, inside a word too; tildes strike under GFM alone.
    func testP02AsteriskAndTildeRunsFlankAnObjectAsALetter() throws {
        for dialect in PreviewDialect.allCases {
            try check("a*{obj}*b", dialect, [.paragraph([
                .text("a"), .enterMarkdown(.emphasis), .object("0"), .leaveMarkdown(.emphasis), .text("b"),
            ])], shows: "a{obj}b\n")
            try check("*{obj}*", dialect, [.paragraph([
                .enterMarkdown(.emphasis), .object("0"), .leaveMarkdown(.emphasis),
            ])], shows: "{obj}\n")
            try check("**{obj}**", dialect, [.paragraph([
                .enterMarkdown(.strong), .object("0"), .leaveMarkdown(.strong),
            ])], shows: "{obj}\n")
            try check("*note*{obj}", dialect, [.paragraph([
                .enterMarkdown(.emphasis), .text("note"), .leaveMarkdown(.emphasis), .object("0"),
            ])], shows: "note{obj}\n")
            try check("{obj}*note*", dialect, [.paragraph([
                .object("0"), .enterMarkdown(.emphasis), .text("note"), .leaveMarkdown(.emphasis),
            ])], shows: "{obj}note\n")
        }
        for template in ["~~{obj}~~", "~{obj}~"] {
            try check(template, .gfm, [.paragraph([
                .enterMarkdown(.deletion), .object("0"), .leaveMarkdown(.deletion),
            ])], shows: "{obj}\n")
            try check(template, .commonMark, plain(template), shows: template + "\n")
        }
    }

    /// Comrak extends an autolink through an object; the renderer refuses that destination.
    func testP03AnExtendedAutolinkThroughAnObjectHasNoActiveAddress() throws {
        func through(_ destination: String, _ before: String, _ after: String = "") -> [PreviewEvent] {
            [.enterLink(destination: [.text(destination)], title: []), .text(before), .object("0")]
                + (after.isEmpty ? [] : [.text(after)]) + [.leaveLink]
        }
        let cases: [(String, [PreviewEvent], [(String, String)])] = [
            ("www.example.com{obj}tail", through("http://www.example.com\u{FFFC}tail", "www.example.com", "tail"), []),
            ("https://example.com{obj}", through("https://example.com\u{FFFC}", "https://example.com"), []),
            ("https://example.com/a{obj}b", through("https://example.com/a\u{FFFC}b", "https://example.com/a", "b"), []),
            ("www.example.com.{obj}", through("http://www.example.com.\u{FFFC}", "www.example.com."), []),
            ("{obj}www.example.com", [.object("0"), .text("www.example.com")], []),
            ("{obj}https://example.com", [.object("0")] + autolink("https://example.com", "https://example.com"),
             [("https://example.com", "https://example.com")]),
            ("https://{obj}", through("https://\u{FFFC}", "https://"), []),
            ("www.{obj}", [.text("www."), .object("0")], []),
            ("www.example.com/({obj})", through("http://www.example.com/(\u{FFFC})", "www.example.com/(", ")"), []),
        ]
        for (template, events, links) in cases {
            try check(template, .gfm, [.paragraph(events)], shows: template + "\n", links: links)
            try check(template, .commonMark, plain(template), shows: template + "\n")
        }
        try check("*www.example.com{obj}*", .gfm, [.paragraph(
            [.enterMarkdown(.emphasis)] + through("http://www.example.com\u{FFFC}", "www.example.com")
                + [.leaveMarkdown(.emphasis)]
        )], shows: "www.example.com{obj}\n")
        try check("*www.example.com{obj}*", .commonMark, [.paragraph([
            .enterMarkdown(.emphasis), .text("www.example.com"), .object("0"), .leaveMarkdown(.emphasis),
        ])], shows: "www.example.com{obj}\n")
    }

    /// P04: an email autolink's local part and domain both end at an object.
    func testP04AnEmailAutolinkEndsAtAnObject() throws {
        let email = autolink("mailto:person@example.com", "person@example.com")
        let cases: [(String, [PreviewEvent], [(String, String)])] = [
            ("person@example.com{obj}", email + [.object("0")], [("person@example.com", "mailto:person@example.com")]),
            ("{obj}person@example.com", [.object("0")] + email, [("person@example.com", "mailto:person@example.com")]),
            ("mailto:person@example.com{obj}",
             autolink("mailto:person@example.com", "mailto:person@example.com") + [.object("0")],
             [("mailto:person@example.com", "mailto:person@example.com")]),
            ("person@{obj}example.com", [.text("person@"), .object("0"), .text("example.com")], []),
            ("per{obj}son@example.com", [.text("per"), .object("0")] + autolink("mailto:son@example.com", "son@example.com"),
             [("son@example.com", "mailto:son@example.com")]),
        ]
        for (template, events, links) in cases {
            try check(template, .gfm, [.paragraph(events)], shows: template + "\n", links: links)
            try check(template, .commonMark, plain(template), shows: template + "\n")
        }
    }

    /// P05: an object beside a pipe, an escaped pipe or an empty cell stays in its cell under GFM;
    /// CommonMark keeps the lines as paragraph text with the object in order.
    func testP05AnObjectBesideAPipeStaysInItsCell() throws {
        let header: [[PreviewEvent]] = [[.text("a")], [.text("b")]]
        let wide: [[PreviewEvent]] = [[.text("a")], [.text("b")], [.text("c")]]
        let cases: [(String, MarkdownBlock, String, [Int])] = [
            ("|{obj}| b |\n| - | - |\n| c | d |",
             .table(alignments: [nil, nil], header: [[.object("0")], [.text("b")]], body: [[[.text("c")], [.text("d")]]]),
             "{obj}\nb\nc\nd\n\n", [0, 0]),
            ("| a | b |\n| - | - |\n| c |{obj}|",
             .table(alignments: [nil, nil], header: header, body: [[[.text("c")], [.object("0")]]]),
             "a\nb\nc\n{obj}\n\n", [1, 1]),
            ("| a | b |\n| - | - |\n| c \\|{obj} | d |",
             .table(alignments: [nil, nil], header: header, body: [[[.text("c |"), .object("0")], [.text("d")]]]),
             "a\nb\nc |{obj}\nd\n\n", [1, 0]),
            ("| a | b | c |\n| - | - | - |\n| {obj}|| d |",
             .table(alignments: [nil, nil, nil], header: wide, body: [[[.object("0")], [], [.text("d")]]]),
             "a\nb\nc\n{obj}\n\nd\n\n", [1, 0]),
            ("| a | b | c |\n| - | - | - |\n| x ||{obj}|",
             .table(alignments: [nil, nil, nil], header: wide, body: [[[.text("x")], [], [.object("0")]]]),
             "a\nb\nc\nx\n\n{obj}\n\n", [1, 2]),
        ]
        for (template, table, shows, place) in cases {
            let rendered = try check(template, .gfm, [table], shows: shows)
            XCTAssertEqual(attachments(in: rendered).map { cell(at: $0.location, in: rendered) }, [place],
                           template.debugDescription)
            let lines = template.components(separatedBy: "\n")
            var events: [PreviewEvent] = []
            for (index, line) in lines.enumerated() {
                if index > 0 { events.append(.softBreak) }
                if case .paragraph(let parts)? = plain(line).first { events += parts }
            }
            // The escaped pipe reads as `|` in paragraph text too.
            let unescaped = events.map { (event: PreviewEvent) -> PreviewEvent in
                event == .text("| c \\|") ? .text("| c |") : event
            }
            let flat = try check(template, .commonMark, [.paragraph(unescaped)],
                                 shows: lines.joined(separator: " ").replacingOccurrences(of: "\\|", with: "|") + "\n")
            XCTAssertTrue(tableCells(in: flat).isEmpty, template.debugDescription)
        }
    }

    /// P05: comrak drops a row's cells past the header's count, and R1 gives a dropped cell's
    /// object to the end of its row's last kept cell, so it renders and copies in source order.
    func testP05AnExcessCellsObjectEndsItsRowsLastCell() throws {
        let header: [[PreviewEvent]] = [[.text("a")], [.text("b")]]
        let excess = "| a | b |\n| - | - |\n| c | d | {obj} |\n| e | f {obj} |"
        let rendered = try check(excess, .gfm, [
            .table(alignments: [nil, nil], header: header, body: [
                [[.text("c")], [.text("d"), .object("0")]], [[.text("e")], [.text("f "), .object("1")]],
            ]),
        ], shows: "a\nb\nc\nd{obj}\ne\nf {obj}\n\n")
        XCTAssertEqual(attachments(in: rendered).map { cell(at: $0.location, in: rendered) }, [[1, 1], [2, 1]])
        try check(excess, .commonMark, [.paragraph([
            .text("| a | b |"), .softBreak, .text("| - | - |"), .softBreak, .text("| c | d | "), .object("0"),
            .text(" |"), .softBreak, .text("| e | f "), .object("1"), .text(" |"),
        ])], shows: "| a | b | | - | - | | c | d | {obj} | | e | f {obj} |\n")

        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.isSelectedPage = true
        view.reseed(with: PageModel.QuietRendering(text: source(excess).0, fenceRegions: []), dialect: .gfm)
        view.selectAll(nil)
        XCTAssertEqual(view.shownSelection(), [[
            .ink("a\nb\nc\nd"), .chip(1), .ink("\ne\nf "), .chip(2), .ink("\n\n"),
        ]], "a copy follows the rendered order")

        try check("| a | b |\n| - | - |\n| {obj} | d | {obj} |", .gfm, [
            .table(alignments: [nil, nil], header: header, body: [[[.object("0")], [.text("d"), .object("1")]]]),
        ], shows: "a\nb\n{obj}\nd{obj}\n\n")

        // comrak takes a plain line after a table as one more row.
        let quoted = "> | a | b |\n> | - | - |\n> | c | d | {obj} |\n> after {obj}"
        try check(quoted, .gfm, [.quote([
            .table(alignments: [nil, nil], header: header, body: [
                [[.text("c")], [.text("d"), .object("0")]], [[.text("after "), .object("1")], []],
            ]),
        ])], shows: "a\nb\nc\nd{obj}\nafter {obj}\n\n\n")
        try check(quoted, .commonMark, [.quote([.paragraph([
            .text("| a | b |"), .softBreak, .text("| - | - |"), .softBreak, .text("| c | d | "), .object("0"),
            .text(" |"), .softBreak, .text("after "), .object("1"),
        ])])], shows: "| a | b | | - | - | | c | d | {obj} | after {obj}\n")

        let listed = "- | a | b |\n  | - | - |\n  | c | d | {obj} |\n- next {obj}"
        try check(listed, .gfm, [.list(ordered: false, start: 0, tight: true, items: [
            MarkdownListItem(task: nil, blocks: [
                .table(alignments: [nil, nil], header: header, body: [[[.text("c")], [.text("d"), .object("0")]]]),
            ]),
            MarkdownListItem(task: nil, blocks: [.paragraph([.text("next "), .object("1")])]),
        ])], shows: "•\t\na\nb\nc\nd{obj}\n\n•\tnext {obj}\n")
    }

    /// P05: an object in the delimiter row leaves it no delimiter row, so neither dialect has a table.
    func testP05AnObjectInTheDelimiterRowLeavesNoTable() throws {
        for dialect in PreviewDialect.allCases {
            try check("| a | b |\n| - |{obj} - |\n| c | d |", dialect, [.paragraph([
                .text("| a | b |"), .softBreak, .text("| - |"), .object("0"), .text(" - |"), .softBreak,
                .text("| c | d |"),
            ])], shows: "| a | b | | - |{obj} - | | c | d |\n")
        }
    }

    /// P06: an object in a link's label or an image's alt text stays there; the link marks the
    /// label's text and never the object.
    func testP06LabelAndAltObjectsStayInsideTheirElement() throws {
        for dialect in PreviewDialect.allCases {
            try check("[a {obj} b](https://example.com/)", dialect, [.paragraph([
                .enterLink(destination: [.text("https://example.com/")], title: []),
                .text("a "), .object("0"), .text(" b"), .leaveLink,
            ])], shows: "a {obj} b\n", links: [("a ", "https://example.com/"), (" b", "https://example.com/")])
            try check("[{obj}](https://example.com/)", dialect, [.paragraph([
                .enterLink(destination: [.text("https://example.com/")], title: []), .object("0"), .leaveLink,
            ])], shows: "{obj}\n")
            try check("![a {obj} b](https://example.com/i.png)", dialect, [.paragraph([
                .markdownImage(
                    alt: [.text("a "), .object("0"), .text(" b")], destination: [.text("https://example.com/i.png")]
                ),
            ])], shows: "a {obj} b\n", images: [(.unreviewed("https://example.com/i.png"), "a {obj} b")])
            // An object between `!` and `[` leaves an ordinary link.
            try check("!{obj}[alt](https://example.com/i.png)", dialect, [.paragraph([
                .text("!"), .object("0"), .enterLink(destination: [.text("https://example.com/i.png")], title: []),
                .text("alt"), .leaveLink,
            ])], shows: "!{obj}alt\n", links: [("alt", "https://example.com/i.png")])
        }
    }

    /// P06: an inline destination's object follows the element's text, as in the source, and refuses
    /// its address; a title's object follows it too and leaves the address as it was.
    func testP06InlineDestinationAndTitleObjectsFollowTheElementsText() throws {
        for dialect in PreviewDialect.allCases {
            try check("[label](https://example.com/{obj}) after", dialect, [.paragraph([
                .enterLink(destination: [.text("https://example.com/\u{FFFC}")], title: []),
                .text("label"), .leaveLink, .object("0"), .text(" after"),
            ])], shows: "label{obj} after\n")
            try check("[a](<https://example.com/{obj}>)", dialect, [.paragraph([
                .enterLink(destination: [.text("https://example.com/\u{FFFC}")], title: []),
                .text("a"), .leaveLink, .object("0"),
            ])], shows: "a{obj}\n")
            try check("[label](https://example.com/ \"t {obj}\") after", dialect, [.paragraph([
                .enterLink(destination: [.text("https://example.com/")], title: [.text("t \u{FFFC}")]),
                .text("label"), .leaveLink, .object("0"), .text(" after"),
            ])], shows: "label{obj} after\n", links: [("label", "https://example.com/")])
            try check("![alt](https://example.com/{obj}.png)", dialect, [.paragraph([
                .markdownImage(
                    alt: [.text("alt")], destination: [.text("https://example.com/"), .object("0"), .text(".png")]
                ),
            ])], shows: "alt{obj}\n", images: [(.refused(.sealedObject), "alt{obj}")])
            try check("![alt](https://example.com/i.png \"t {obj}\")", dialect, [.paragraph([
                .markdownImage(
                    alt: [.text("alt")], destination: [.text("https://example.com/i.png")],
                    title: [.text("t "), .object("0")]
                ),
            ])], shows: "alt{obj}\n", images: [(.unreviewed("https://example.com/i.png"), "alt{obj}")])
        }
    }

    /// P06: an object between `]` and `(` breaks the inline link; GFM then autolinks the exposed URL.
    func testP06AnObjectBetweenTheBracketsAndTheDestinationBreaksTheLink() throws {
        let template = "[label]{obj}(https://example.com/)"
        try check(template, .gfm, [.paragraph(
            [.text("[label]"), .object("0"), .text("(")] + autolink("https://example.com/", "https://example.com/")
                + [.text(")")]
        )], shows: template + "\n", links: [("https://example.com/", "https://example.com/")])
        try check(template, .commonMark, plain(template), shows: template + "\n")
    }

    /// P06: a definition's object stays at the definition, before or after its uses; every use of a
    /// destination with one refuses it, and no object moves into a use.
    func testP06ReferenceDefinitionsKeepTheirObjectsAndEveryUseRefusesTheirAddress() throws {
        let refused: [HTMLPart] = [.text("https://example.com/\u{FFFC}")]
        for dialect in PreviewDialect.allCases {
            try check("[r]: https://example.com/{obj}\n\n[x][r], [r][] and [r] {obj}", dialect, [
                .objects(["0"]),
                .paragraph([
                    .enterLink(destination: refused, title: []), .text("x"), .leaveLink, .text(", "),
                    .enterLink(destination: refused, title: []), .text("r"), .leaveLink, .text(" and [r] "), .object("1"),
                ]),
            ], shows: "{obj}\nx, r and [r] {obj}\n")
            try check("[x][r], [r][] and [r] {obj}\n\n[r]: https://example.com/{obj}", dialect, [
                .paragraph([
                    .enterLink(destination: refused, title: []), .text("x"), .leaveLink, .text(", "),
                    .enterLink(destination: refused, title: []), .text("r"), .leaveLink, .text(" and [r] "), .object("0"),
                ]),
                .objects(["1"]),
            ], shows: "x, r and [r] {obj}\n{obj}\n")
            // A title's stand-in refuses nothing, as an inline title's object refuses nothing.
            try check("[r]: https://example.com/ \"t {obj}\"\n\n[x][r]", dialect, [
                .objects(["0"]),
                .paragraph([
                    .enterLink(destination: [.text("https://example.com/")], title: [.text("t \u{FFFC}")]),
                    .text("x"), .leaveLink,
                ]),
            ], shows: "{obj}\nx\n", links: [("x", "https://example.com/")])
            try check("![a][r] {obj}\n\n[r]: https://example.com/i.png \"t {obj}\"", dialect, [
                .paragraph([
                    .markdownImage(
                        alt: [.text("a")], destination: [.text("https://example.com/i.png")], title: [.text("t \u{FFFC}")]
                    ),
                    .text(" "), .object("0"),
                ]),
                .objects(["1"]),
            ], shows: "a {obj}\n{obj}\n", images: [(.unreviewed("https://example.com/i.png"), "a")])
            // Each object is its own scalar, so no later label matches a label with one.
            try check("[a{obj}]: https://example.com/\n\n[a{obj}] and [a]", dialect, [
                .objects(["0"]), .paragraph([.text("[a"), .object("1"), .text("] and [a]")]),
            ], shows: "{obj}\n[a{obj}] and [a]\n")
            // The first definition of a label wins; the ignored one keeps its object.
            try check("[r]: https://example.com/a\n[r]: https://example.com/{obj}\n\n[r] {obj}", dialect, [
                .objects(["0"]),
                .paragraph([
                    .enterLink(destination: [.text("https://example.com/a")], title: []), .text("r"), .leaveLink,
                    .text(" "), .object("1"),
                ]),
            ], shows: "{obj}\nr {obj}\n", links: [("r", "https://example.com/a")])
        }
    }

    /// P06: an angle autolink's text shows its object once, and its address has the stand-in.
    func testP06AnAngleAutolinkShowsItsObjectOnceAndOpensNothing() throws {
        for dialect in PreviewDialect.allCases {
            try check("<https://example.com/{obj}/tail> after", dialect, [.paragraph([
                .enterLink(destination: [.text("https://example.com/\u{FFFC}/tail")], title: []),
                .text("https://example.com/"), .object("0"), .text("/tail"), .leaveLink, .text(" after"),
            ])], shows: "https://example.com/{obj}/tail after\n")
        }
    }

    /// P07: an object where a tag or attribute name must continue leaves no raw HTML, so the text
    /// shows as written with the object in place.
    func testP07AnObjectInATagOrAttributeNameLeavesLiteralText() throws {
        for dialect in PreviewDialect.allCases {
            try check("<{obj}>", dialect, [.paragraph([.text("<"), .object("0"), .text(">")])], shows: "<{obj}>\n")
            // The unmatched `</span>` is raw HTML the composer shows as text.
            try check("<span data-{obj}>x</span>", dialect, [.paragraph([
                .text("<span data-"), .object("0"), .text(">x"), .rawHTML([.text("</span>")]),
            ])], shows: "<span data-{obj}>x</span>\n")
            try check("<span data-a{obj}=\"v\">x</span>", dialect, [.paragraph([
                .text("<span data-a"), .object("0"), .text("=\"v\">x"), .rawHTML([.text("</span>")]),
            ])], shows: "<span data-a{obj}=\"v\">x</span>\n")
        }
    }

    /// P07: an object in a quoted or unquoted attribute value stands where its tag stands; one in a
    /// comment stands in place, and the comment leaves no text.
    func testP07AttributeValueAndCommentObjectsStandWhereTheirTagStands() throws {
        for dialect in PreviewDialect.allCases {
            for (template, tag) in [
                ("a <span title=\"t {obj}\">x</span> b", ["<span title=\"t ", "\">"]),
                ("a <span title='t {obj}'>x</span> b", ["<span title='t ", "'>"]),
                ("a <span title=t{obj}>x</span> b", ["<span title=t", ">"]),
            ] {
                try check(template, dialect, [.paragraph([
                    .text("a "), .rawHTML([.text(tag[0]), .object("0"), .text(tag[1])]), .text("x"),
                    .rawHTML([.text("</span>")]), .text(" b"),
                ])], shows: "a {obj}x b\n")
            }
            try check("a <!-- {obj} --> b", dialect, [.paragraph([
                .text("a "), .rawHTML([.text("<!-- "), .object("0"), .text(" -->")]), .text(" b"),
            ])], shows: "a {obj} b\n")
        }
    }

    /// P07: an object in an `img` source refuses it; the descriptor names `src` alone, so srcset and
    /// CSS addresses are dropped and only their objects show, before the alt text.
    func testP07ImageAndStyleAddressesWithAnObject() throws {
        for dialect in PreviewDialect.allCases {
            try check("a <img src=\"https://example.com/{obj}.png\" alt=\"pic\"> b", dialect, [.paragraph([
                .text("a "),
                .rawHTML([.text("<img src=\"https://example.com/"), .object("0"), .text(".png\" alt=\"pic\">")]),
                .text(" b"),
            ])], shows: "a {obj}pic b\n", images: [(.refused(.sealedObject), "{obj}pic")])
            try check("<img src=\"https://example.com/{obj}.png\" alt=\"pic\">", dialect, [
                .html([.text("<img src=\"https://example.com/"), .object("0"), .text(".png\" alt=\"pic\">\n")]),
            ], shows: "{obj}pic\n", images: [(.refused(.sealedObject), "{obj}pic")])
            try check(
                "a <img src=\"https://example.com/i.png\" srcset=\"https://example.com/{obj}.png 2x\" alt=\"pic\"> b",
                dialect, [.paragraph([
                    .text("a "),
                    .rawHTML([
                        .text("<img src=\"https://example.com/i.png\" srcset=\"https://example.com/"), .object("0"),
                        .text(".png 2x\" alt=\"pic\">"),
                    ]),
                    .text(" b"),
                ])], shows: "a {obj}pic b\n", images: [(.unreviewed("https://example.com/i.png"), "{obj}pic")]
            )
            try check("a <span style=\"background: url(https://example.com/{obj})\">x</span> b", dialect, [.paragraph([
                .text("a "),
                .rawHTML([.text("<span style=\"background: url(https://example.com/"), .object("0"), .text(")\">")]),
                .text("x"), .rawHTML([.text("</span>")]), .text(" b"),
            ])], shows: "a {obj}x b\n")
            try check(
                "a <img style=\"background: url(https://example.com/{obj})\" src=\"https://example.com/i.png\" alt=\"pic\"> b",
                dialect, [.paragraph([
                    .text("a "),
                    .rawHTML([
                        .text("<img style=\"background: url(https://example.com/"), .object("0"),
                        .text(")\" src=\"https://example.com/i.png\" alt=\"pic\">"),
                    ]),
                    .text(" b"),
                ])], shows: "a {obj}pic b\n", images: [(.unreviewed("https://example.com/i.png"), "{obj}pic")]
            )
            try check("a <img src=\"https://example.com/i.png\" alt=\"a {obj} b\"> b", dialect, [.paragraph([
                .text("a "), .rawHTML([.text("<img src=\"https://example.com/i.png\" alt=\"a "), .object("0"), .text(" b\">")]),
                .text(" b"),
            ])], shows: "a a {obj} b b\n", images: [(.unreviewed("https://example.com/i.png"), "a {obj} b")])
        }
    }

    /// P07: an HTML block's object stays in its literal; a `script` body's object shows in place,
    /// in GFM's filtered tag text and in CommonMark's raw-text body.
    func testP07HTMLBlockAndScriptBodiesShowTheirObjectsInPlace() throws {
        for dialect in PreviewDialect.allCases {
            try check("<div>\n*a* {obj}\n</div>", dialect, [
                .html([.text("<div>\n*a* "), .object("0"), .text("\n</div>\n")]),
            ], shows: "*a* {obj}\n")
        }
        let script = "<script>\nvar a = \"{obj}\";\n</script>"
        let block: [MarkdownBlock] = [.html([.text("<script>\nvar a = \""), .object("0"), .text("\";\n</script>\n")])]
        try check(script, .gfm, block, shows: "<script> var a = \"{obj}\"; </script>\n")
        try check(script, .commonMark, block, shows: "<script>\nvar a = \"{obj}\";\n</script>\n")
    }

    // MARK: Native restrictions

    /// Of GFM's autolinks only http, https and mailto open, `www.` as http; an ftp autolink and an
    /// Apple attribute's key stay inert text, and CommonMark has no autolink to open.
    func testOnlyHTTPHTTPSAndMailtoAutolinksAreInteractive() throws {
        let source = "http://example.com https://example.com www.example.com person@example.com "
            + "mailto:person@example.com ftp://example.com ^[note](key)"
        let (gfm, _) = render(source, .gfm)
        XCTAssertEqual(gfm.string, source.replacingOccurrences(of: "[note](key)", with: "note") + "\n")
        let runs = linkRuns(in: gfm)
        XCTAssertEqual(runs.map(\.0), [
            "http://example.com", "https://example.com", "www.example.com", "person@example.com",
            "mailto:person@example.com",
        ])
        XCTAssertEqual(runs.map(\.1), [
            "http://example.com", "https://example.com", "http://www.example.com", "mailto:person@example.com",
            "mailto:person@example.com",
        ])
        let (commonMark, _) = render(source, .commonMark)
        XCTAssertTrue(linkRuns(in: commonMark).isEmpty)
    }

    /// An image shows as inert text with its descriptor, inside a link too, and its object with it.
    func testAnImageNeverTakesALinkEvenInsideOne() throws {
        for dialect in PreviewDialect.allCases {
            try check("[![a {obj}](https://example.com/i.png)](https://example.com/) b", dialect, [.paragraph([
                .enterLink(destination: [.text("https://example.com/")], title: []),
                .markdownImage(alt: [.text("a "), .object("0")], destination: [.text("https://example.com/i.png")]),
                .leaveLink, .text(" b"),
            ])], shows: "a {obj} b\n", images: [(.unreviewed("https://example.com/i.png"), "a {obj}")])
        }
    }

    /// Under GFM each cell is one native cell of one column and one row; under CommonMark the same
    /// lines render with no table at all.
    func testTableSourceBecomesNativeCellsOnlyUnderGFM() throws {
        let template = "| a | b | c |\n| - | - | - |\n| {obj} || ^ |"
        let gfm = try check(template, .gfm, [.table(
            alignments: [nil, nil, nil], header: [[.text("a")], [.text("b")], [.text("c")]],
            body: [[[.object("0")], [], [.text("^")]]]
        )], shows: "a\nb\nc\n{obj}\n\n^\n\n")
        let cells = tableCells(in: gfm)
        XCTAssertEqual(cells.count, 6)
        XCTAssertTrue(cells.allSatisfy { $0.rowSpan == 1 && $0.columnSpan == 1 })
        XCTAssertEqual(attachments(in: gfm).map { cell(at: $0.location, in: gfm) }, [[1, 0]])
        XCTAssertEqual(cell(at: (gfm.string as NSString).range(of: "^").location, in: gfm), [1, 2])

        let commonMark = try check(template, .commonMark, [.paragraph([
            .text("| a | b | c |"), .softBreak, .text("| - | - | - |"), .softBreak, .text("| "), .object("0"),
            .text(" || ^ |"),
        ])], shows: "| a | b | c | | - | - | - | | {obj} || ^ |\n")
        XCTAssertTrue(tableCells(in: commonMark).isEmpty)
    }

    /// The composer takes comments by HTML's syntax: `<!-->` and `<!--->`, raw HTML to both parsers,
    /// show as text, and a comment with `--` inside leaves none (`HTMLTokenizerTests`).
    func testCommentsOutsideHTMLSyntaxShowAsText() throws {
        for dialect in PreviewDialect.allCases {
            let (rendered, _) = render("a <!--> b <!---> c <!-- d -- e --> f", dialect)
            XCTAssertEqual(rendered.string, "a <!--> b <!---> c  f\n", "\(dialect)")
        }
    }

    /// GFM filters a `textarea` tag to text and lays its body out as HTML text; CommonMark keeps the
    /// body raw. Neither formats the Markdown inside.
    func testATextareaComposesAsTextInBothDialects() throws {
        let source = "<textarea>\n\n*a*\n\n</textarea>"
        let (gfm, _) = render(source, .gfm)
        XCTAssertEqual(gfm.string, "<textarea> *a* </textarea>\n")
        let (commonMark, _) = render(source, .commonMark)
        XCTAssertEqual(commonMark.string, "<textarea>\n\n*a*\n\n</textarea>\n")
        for rendered in [gfm, commonMark] {
            let location = (rendered.string as NSString).range(of: "*a*").location
            let font = try XCTUnwrap(rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
            XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
        }
    }
}
