import AppKit
import XCTest

@testable import CompanionKit

/// The parser adapter's own rules (plan R1): the placeholder window, line endings, limits, and
/// where an object stands when the grammar gives it no element of its own.
@MainActor
final class MarkdownParserTests: XCTestCase {
    /// `parts` joined with U+FFFC where `nil` stands, and the UTF-16 offset of each.
    private func page(_ parts: [String?]) -> (String, [Int]) {
        var text = ""
        var offsets: [Int] = []
        var length = 0
        for part in parts {
            if let part {
                text += part
                length += part.utf16.count
            } else {
                offsets.append(length)
                text += "\u{FFFC}"
                length += 1
            }
        }
        return (text, offsets)
    }

    private func parse(
        _ parts: [String?], _ dialect: PreviewDialect = .gfm, limits: CompositionLimits = CompositionLimits()
    ) throws -> MarkdownDocument {
        let (text, offsets) = page(parts)
        return try MarkdownParser.parse(text, objects: offsets, dialect: dialect, limits: limits)
    }

    /// The same page as the preview renders it, chips 1, 2, ... where `parts` has `nil`.
    private func render(_ parts: [String?]) -> (NSAttributedString, [ChipAttachment]) {
        let text = NSMutableAttributedString(string: "")
        var chips: [ChipAttachment] = []
        for part in parts {
            if let part {
                text.append(NSAttributedString(string: part))
            } else {
                let chip = ChipAttachment(info: ChipInfo(
                    chipId: UInt64(chips.count + 1), kind: "text", excerpt: "test-face", sizeLabel: "small",
                    concealed: false
                ))
                chips.append(chip)
                text.append(NSAttributedString(attachment: chip))
            }
        }
        return (MarkdownPreviewView.render(text), chips)
    }

    private func attachments(in rendered: NSAttributedString) -> [NSTextAttachment] {
        var found: [NSTextAttachment] = []
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) {
            value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            for _ in 0..<range.length { found.append(attachment) }
        }
        return found
    }

    private func assertThrows(
        _ expected: MarkdownParseError, _ body: () throws -> MarkdownDocument,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? MarkdownParseError, expected, file: file, line: line)
        }
    }

    // MARK: The placeholder window

    func testPlaneSixteenTextAndNumericReferencesStayTextBesideTheObjects() throws {
        let parts: [String?] = ["\u{100000} &#1048576; &#x100001; &#X100002; ", nil, " end"]
        let (_, offsets) = page(parts)
        for dialect in PreviewDialect.allCases {
            let document = try parse(parts, dialect)
            XCTAssertEqual(document.blocks, [.paragraph([
                .text("\u{100000} \u{100000} \u{100001} \u{100002} "), .object("0"), .text(" end"),
            ])], "\(dialect)")
            XCTAssertEqual(document.atoms, [MarkdownAtom(identity: "0", offset: offsets[0])])
        }
        // A window of two skips the one scalar inside the lowest window of two.
        XCTAssertEqual(try parse(["\u{100001} ", nil, nil]).blocks, [
            .paragraph([.text("\u{100001} "), .object("0"), .object("1")]),
        ])

        let (rendered, chips) = render(parts)
        XCTAssertEqual(rendered.string, "\u{100000} \u{100000} \u{100001} \u{100002} \u{FFFC} end\n")
        XCTAssertEqual(attachments(in: rendered).count, 1)
        XCTAssertTrue(attachments(in: rendered).first === chips[0])
    }

    /// Plane 16 has 65,534 scalars; one taken at U+108000 leaves runs of 32,768 and 32,765.
    func testAPageWithNoPlaceholderWindowThrowsBeforeParsing() throws {
        let objects = [String?](repeating: nil, count: 40_000)
        assertThrows(.noPlaceholderWindow) { try parse(["\u{108000}"] + objects) }
        assertThrows(.noPlaceholderWindow) { try parse(["&#1081344;"] + objects) }
        assertThrows(.noPlaceholderWindow) { try parse(["&#x108000;"] + objects) }
        XCTAssertEqual(try parse(["\u{108000}"] + objects.prefix(32_768)).atoms.count, 32_768)
    }

    func testTheInputLimitThrowsBeforeParsing() throws {
        var limits = CompositionLimits()
        limits.maximumInputScalars = 5
        XCTAssertNoThrow(try MarkdownParser.parse("12345", dialect: .gfm, limits: limits))
        XCTAssertNoThrow(try MarkdownParser.parse("😀😀😀😀😀", dialect: .commonMark, limits: limits), "scalars")
        assertThrows(.inputLimit) { try MarkdownParser.parse("123456", dialect: .gfm, limits: limits) }
    }

    func testObjectOffsetsMustNameEachObjectInOrder() {
        assertThrows(.objectOffset) { try MarkdownParser.parse("ab", objects: [1], dialect: .gfm) }
        assertThrows(.objectOffset) { try MarkdownParser.parse("\u{FFFC}\u{FFFC}", objects: [1, 0], dialect: .gfm) }
        assertThrows(.objectOffset) { try MarkdownParser.parse("\u{FFFC}", objects: [0, 1], dialect: .gfm) }
        assertThrows(.objectOffset) { try MarkdownParser.parse("😀\u{FFFC}", objects: [1], dialect: .gfm) }
    }

    /// CR and CRLF read as LF; a CRLF counted twice would put the definition's object after `e`.
    func testLineEndingsReadAsLFAndAtomsKeepTheirOffsetsInThePage() throws {
        let parts: [String?] = ["a\r\n\r\nb\rc\r\n\r\n[r]: https://e.example/", nil, "\r\n\r\nd ", nil, "\r\n\r\ne"]
        let (_, offsets) = page(parts)
        for dialect in PreviewDialect.allCases {
            let document = try parse(parts, dialect)
            XCTAssertEqual(document.atoms, [
                MarkdownAtom(identity: "0", offset: offsets[0]), MarkdownAtom(identity: "1", offset: offsets[1]),
            ])
            XCTAssertEqual(document.blocks, [
                .paragraph([.text("a")]),
                .paragraph([.text("b"), .softBreak, .text("c")]),
                .objects(["0"]),
                .paragraph([.text("d "), .object("1")]),
                .paragraph([.text("e")]),
            ], "\(dialect)")
        }
    }

    /// Block quotes, lists and inline containers count; the walk stops before the stack would.
    func testNestingPastTheDepthLimitThrows() throws {
        let deep = String(repeating: ">", count: 100_000) + " deep"
        assertThrows(.depthLimit) { try MarkdownParser.parse(deep, dialect: .gfm) }
        let quotes = String(repeating: "> ", count: 64) + "x"
        XCTAssertNoThrow(try MarkdownParser.parse(quotes, dialect: .commonMark))
        assertThrows(.depthLimit) { try MarkdownParser.parse("> " + quotes, dialect: .commonMark) }

        var limits = CompositionLimits()
        limits.maximumDepth = 1
        XCTAssertNoThrow(try MarkdownParser.parse("**a**", dialect: .gfm, limits: limits))
        XCTAssertNoThrow(try MarkdownParser.parse("- a\n- b", dialect: .gfm, limits: limits), "items share a level")
        assertThrows(.depthLimit) { try MarkdownParser.parse("**a *b***", dialect: .gfm, limits: limits) }
        assertThrows(.depthLimit) { try MarkdownParser.parse("> [a](/u)", dialect: .gfm, limits: limits) }
    }

    // MARK: Objects the grammar hides

    /// A definition's object stays at the definition, before or after the reference, and a
    /// reference to it refuses the address with the stand-in; no object moves from later text.
    func testADefinitionKeepsItsObjectsAndItsReferencesRefuseTheirAddress() throws {
        for dialect in PreviewDialect.allCases {
            let before: [String?] = ["[r]: https://e.example/", nil, " \"t\"\n\n[link][r] then ", nil]
            XCTAssertEqual(try parse(before, dialect).blocks, [
                .objects(["0"]),
                .paragraph([
                    .enterLink(destination: [.text("https://e.example/\u{FFFC}")], title: [.text("t")]),
                    .text("link"), .leaveLink, .text(" then "), .object("1"),
                ]),
            ], "\(dialect): before")
            XCTAssertEqual(try parse(["![pic][r] ", nil, " end\n\n[r]: https://e.example/", nil], dialect).blocks, [
                .paragraph([
                    .markdownImage(alt: [.text("pic")], destination: [.text("https://e.example/\u{FFFC}")], title: []),
                    .text(" "), .object("0"), .text(" end"),
                ]),
                .objects(["1"]),
            ], "\(dialect): after")
            XCTAssertEqual(try parse(["[r]: /u \"title ", nil, "\"\ntext ", nil, "\n\n[x][r]"], dialect).blocks, [
                .objects(["0"]),
                .paragraph([.text("text "), .object("1")]),
                .paragraph([
                    .enterLink(destination: [.text("/u")], title: [.text("title \u{FFFC}")]), .text("x"), .leaveLink,
                ]),
            ], "\(dialect): a definition opening a paragraph, its object in the title")
            XCTAssertEqual(try parse(["[a", nil, "]: /u\n\nplain"], dialect).blocks, [
                .objects(["0"]), .paragraph([.text("plain")]),
            ], "\(dialect): in a label")
            XCTAssertEqual(try parse(["[r]: /u", nil], dialect).blocks, [.objects(["0"])], "\(dialect): alone")
            XCTAssertEqual(try parse(["> [r]: /u", nil, "\n> text"], dialect).blocks, [
                .quote([.objects(["0"]), .paragraph([.text("text")])]),
            ], "\(dialect): in a quote")
            let listed = try parse(["- a\n- [r]: /u", nil, "\n- b"], dialect)
            guard case .list(_, _, _, let items)? = listed.blocks.first else { return XCTFail("\(dialect): a list") }
            XCTAssertEqual(items.map(\.blocks), [
                [.paragraph([.text("a")])], [.objects(["0"])], [.paragraph([.text("b")])],
            ], "\(dialect): in an item of its own")
        }
    }

    func testAnInlineLinksOwnDestinationAndTitleObjectsStandWhereItOpens() throws {
        for dialect in PreviewDialect.allCases {
            let link: [String?] = ["a [label ", nil, "](https://e.example/", nil, " \"t ", nil, "\") b"]
            XCTAssertEqual(try parse(link, dialect).blocks, [
                .paragraph([
                    .text("a "),
                    .enterLink(
                        destination: [.text("https://e.example/"), .object("1")], title: [.text("t "), .object("2")]
                    ),
                    .text("label "), .object("0"), .leaveLink, .text(" b"),
                ]),
            ], "\(dialect)")
            XCTAssertEqual(try parse(["![alt ", nil, "](/i", nil, " \"t ", nil, "\")"], dialect).blocks, [
                .paragraph([.markdownImage(
                    alt: [.text("alt "), .object("0")], destination: [.text("/i"), .object("1")],
                    title: [.text("t "), .object("2")]
                )]),
            ], "\(dialect): image")
        }
    }

    /// The autolink's text shows its object, so its address holds the stand-in and is refused.
    func testAnAngleAutolinkShowsItsObjectOnceAndRefusesItsAddress() throws {
        let parts: [String?] = ["<https://e.example/", nil, ">"]
        for dialect in PreviewDialect.allCases {
            XCTAssertEqual(try parse(parts, dialect).blocks, [.paragraph([
                .enterLink(destination: [.text("https://e.example/\u{FFFC}")], title: []),
                .text("https://e.example/"), .object("0"), .leaveLink,
            ])], "\(dialect)")
        }
        let (rendered, chips) = render(parts)
        XCTAssertEqual(rendered.string, "https://e.example/\u{FFFC}\n")
        XCTAssertEqual(attachments(in: rendered).count, 1)
        XCTAssertTrue(attachments(in: rendered).first === chips[0])
        XCTAssertNil(rendered.attribute(.link, at: 0, effectiveRange: nil))
    }

    func testFenceInfoObjectsBelongToTheCodeBlockAndOpenIt() throws {
        let parts: [String?] = ["```swift ", nil, "\nlet a = ", nil, "\n```\n"]
        for dialect in PreviewDialect.allCases {
            XCTAssertEqual(try parse(parts, dialect).blocks, [
                .codeBlock(
                    info: [.text("swift "), .object("0")], literal: [.text("let a = "), .object("1"), .text("\n")]
                ),
            ], "\(dialect)")
        }
        let (rendered, chips) = render(parts)
        XCTAssertEqual(rendered.string, "\u{FFFC}let a = \u{FFFC}\n")
        let found = attachments(in: rendered)
        XCTAssertEqual(found.count, 2)
        for (actual, expected) in zip(found, chips) { XCTAssertTrue(actual === expected) }
    }

    /// cmark-gfm drops a row's cells past the header's count, so their objects end the row's last kept cell.
    func testAGFMTableRowsExcessCellObjectEndsTheRowsLastCell() throws {
        let parts: [String?] = ["| a | b |\n| - | - |\n| c | d | ", nil, " |\n| e |\n\nafter ", nil]
        XCTAssertEqual(try parse(parts, .gfm).blocks, [
            .table(
                alignments: [nil, nil], header: [[.text("a")], [.text("b")]],
                body: [[[.text("c")], [.text("d"), .object("0")]], [[.text("e")], []]]
            ),
            .paragraph([.text("after "), .object("1")]),
        ])
        guard case .paragraph(let events)? = try parse(parts, .commonMark).blocks.first else {
            return XCTFail("CommonMark reads the lines as a paragraph")
        }
        XCTAssertTrue(events.contains(.object("0")))

        let (rendered, chips) = render(parts)
        let found = attachments(in: rendered)
        XCTAssertEqual(found.count, 2)
        for (actual, expected) in zip(found, chips) { XCTAssertTrue(actual === expected) }
        let first = (rendered.string as NSString).range(of: "\u{FFFC}").location
        let style = rendered.attribute(.paragraphStyle, at: first, effectiveRange: nil) as? NSParagraphStyle
        let block = style?.textBlocks.last as? NSTextTableBlock
        XCTAssertEqual(block.map { [$0.startingRow, $0.startingColumn] }, [1, 1], "the object ends its row's last cell")
    }

    /// Every object identity in `blocks`, in document order.
    private func identities(_ blocks: [MarkdownBlock]) -> [String] {
        func events(_ events: [PreviewEvent]) -> [String] {
            events.flatMap { event -> [String] in
                switch event {
                case .object(let identity): return [identity]
                case .rawHTML(let parts): return parts.objectIdentities
                case .markdownImage(let alt, let destination, let title):
                    return (alt + (destination ?? []) + title).objectIdentities
                case .enterLink(let destination, let title): return ((destination ?? []) + title).objectIdentities
                default: return []
                }
            }
        }
        return blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let inline), .heading(_, let inline): return events(inline)
            case .codeBlock(let info, let literal): return (info + literal).objectIdentities
            case .html(let parts): return parts.objectIdentities
            case .thematicBreak: return []
            case .quote(let children): return identities(children)
            case .list(_, _, _, let items): return items.flatMap { identities($0.blocks) }
            case .table(_, let header, let body): return (header + body.flatMap { $0 }).flatMap(events)
            case .objects(let objects): return objects
            }
        }
    }

    /// Pages built to hide, copy or split an object; each object appears once, parsed and rendered.
    func testEveryObjectAppearsOnceOnPagesThatHideOrCopyIt() throws {
        let pages: [[String?]] = [
            ["[r]: /u", nil, "\n| a |\n| - |\n| ", nil, " |"],
            ["text ", nil, "\n| a |\n| - |\n| b |"],
            ["[r]: /u", nil, "\n| a |\n| - |\n\n[x][r] [y][r]"],
            ["> - [r]: /u", nil, "\n>   [x][r] ", nil],
            ["<a href=\"", nil, "\">[x](/u", nil, " \"", nil, "\")</a>"],
            ["![a ![b](/i", nil, ")](/j", nil, " \"", nil, "\")"],
            ["[![a", nil, "](/i", nil, ")](/u", nil, ")"],
            ["[a](<", nil, ">) [b](", nil, " '", nil, "')"],
            ["```", nil, "\n```"],
            ["<!-- ", nil, " -->\n\n<div>\n", nil, "\n</div>"],
            ["| a |\n| - |\n| b | ", nil, " | ", nil, " |\n", nil],
            ["- [ ] ", nil, "\n- [x] ", nil, "\n- [", nil, "] c"],
            [nil, "\n===\n\n[r]: /u", nil, "\nHeading ", nil, "\n---"],
            ["1. [r]: /u", nil, "\n2. b ", nil],
            ["    ", nil, " indented\n\n*", nil, "*", nil, "**", nil, "** ~~", nil, "~~ `", nil, "`"],
            ["\\", nil, " &#x", nil, "; &", nil, "amp; [", nil, "]: /u\n\n[", nil, "]"],
            ["[r]: /a", nil, "\n[r]: /b", nil, "\n\n[r]"],
            ["<https://e.example/", nil, "> www.e.example", nil, " a", nil, "@e.example"],
        ]
        for parts in pages {
            let count = parts.filter { $0 == nil }.count
            for dialect in PreviewDialect.allCases {
                let document = try parse(parts, dialect)
                XCTAssertEqual(identities(document.blocks).sorted(), (0..<count).map(String.init).sorted(),
                               "\(dialect): \(parts)")
            }
            let (rendered, chips) = render(parts)
            let found = attachments(in: rendered)
            XCTAssertEqual(found.count, count, "\(parts)")
            XCTAssertEqual(Set(found.map(ObjectIdentifier.init)), Set(chips.map(ObjectIdentifier.init)), "\(parts)")
        }
    }

    // MARK: Objects beside syntax

    /// The placeholder is neither space nor punctuation, so an object flanks a delimiter as a letter does.
    func testAnObjectFlanksEmphasisAsALetterDoes() throws {
        for dialect in PreviewDialect.allCases {
            XCTAssertEqual(try parse(["*note*", nil, " and _note_", nil], dialect).blocks, [.paragraph([
                .enterMarkdown(.emphasis), .text("note"), .leaveMarkdown(.emphasis), .object("0"),
                .text(" and _note_"), .object("1"),
            ])], "\(dialect)")
        }
    }

    /// The vendored autolink patch ends a GFM extended autolink at an object.
    func testAnExtendedAutolinkEndsAtAnObject() throws {
        XCTAssertEqual(try parse(["see www.example.com", nil, " now"], .gfm).blocks, [.paragraph([
            .text("see "), .enterLink(destination: [.text("http://www.example.com")], title: []),
            .text("www.example.com"), .leaveLink, .object("0"), .text(" now"),
        ])])
        XCTAssertEqual(try parse(["see www.example.com", nil, " now"], .commonMark).blocks, [.paragraph([
            .text("see www.example.com"), .object("0"), .text(" now"),
        ])])
    }
}
