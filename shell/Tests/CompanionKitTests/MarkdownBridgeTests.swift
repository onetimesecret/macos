import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class MarkdownBridgeTests: XCTestCase {
    func testRustGoldenDocumentDecodesEveryCaseAndRoundTrips() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("crates/markdown/src/tests/document.json"))
        let document = try JSONDecoder().decode(MarkdownDocument.self, from: data)
        XCTAssertEqual(document.blocks.count, 8)
        XCTAssertEqual(document.atoms.map(\.offset), [0, 7, 12])
        let encoded = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(MarkdownDocument.self, from: encoded), document)
        guard case .paragraph(let events) = document.blocks[0] else { return XCTFail("paragraph") }
        XCTAssertEqual(events, [
            .text("t"), .object("0"), .enterMarkdown(.emphasis), .leaveMarkdown(.emphasis),
            .enterMarkdown(.strong), .leaveMarkdown(.strong), .enterMarkdown(.deletion), .leaveMarkdown(.deletion),
            .enterMarkdown(.code), .leaveMarkdown(.code), .softBreak, .hardBreak,
            .rawHTML([.text("<b>"), .object("1")]),
            .markdownImage(alt: [.text("alt")], destination: [.text("/i")], title: [.text("title")]),
            .enterLink(destination: [.text("/u\u{FFFC}")], title: []), .leaveLink,
        ])
    }

    func testEveryRefusalIsDecodedBeforeTheDocumentAndReleasedOnce() throws {
        let cases: [(String, MarkdownParseError)] = [
            (#"{"inputLimit":{}}"#, .inputLimit), (#"{"depthLimit":{}}"#, .depthLimit),
            (#"{"tableCellLimit":{}}"#, .tableCellLimit), (#"{"noPlaceholderWindow":{}}"#, .noPlaceholderWindow),
            (#"{"objectOffset":{}}"#, .objectOffset), (#"{"parserFailure":{}}"#, .parserFailure),
            (#"{"duplicateObject":{"_0":"3"}}"#, .duplicateObject("3")),
        ]
        for (json, expected) in cases {
            let pointer = try XCTUnwrap(strdup("{\"error\":\(json),\"blocks\":[],\"atoms\":[]}"))
            var released = 0
            XCTAssertThrowsError(try MarkdownParser.decode(pointer, release: {
                XCTAssertEqual($0, pointer)
                released += 1
                free($0)
            })) { XCTAssertEqual($0 as? MarkdownParseError, expected) }
            XCTAssertEqual(released, 1)
        }
    }

    func testBridgeFailuresAndSuccessfulDocumentsReleaseTheirBuffer() throws {
        XCTAssertThrowsError(try MarkdownParser.decode(nil)) {
            XCTAssertEqual($0 as? MarkdownBridgeError, .unavailable)
        }
        for json in ["not JSON", "{}", #"{"error":{"futureCase":{}}}"#] {
            let pointer = try XCTUnwrap(strdup(json))
            var released = 0
            XCTAssertThrowsError(try MarkdownParser.decode(pointer, release: {
                released += 1
                free($0)
            })) { XCTAssertEqual($0 as? MarkdownBridgeError, .invalidResponse) }
            XCTAssertEqual(released, 1)
        }
        let pointer = try XCTUnwrap(strdup(#"{"blocks":[],"atoms":[]}"#))
        var released = 0
        let document = try MarkdownParser.decode(pointer, release: {
            released += 1
            free($0)
        })
        XCTAssertEqual(document, MarkdownDocument(blocks: [], atoms: []))
        XCTAssertEqual(released, 1)
    }

    func testDecodedAtomTableMustMatchInputOffsetsAndDecimalIndices() throws {
        let expected = [MarkdownAtom(identity: "0", offset: 3), MarkdownAtom(identity: "1", offset: 8)]
        let malformed: [[MarkdownAtom]] = [
            [], [expected[0]], expected + [MarkdownAtom(identity: "2", offset: 13)],
            Array(expected.reversed()),
            [MarkdownAtom(identity: "1", offset: 3), MarkdownAtom(identity: "0", offset: 8)],
            [MarkdownAtom(identity: "0", offset: 4), expected[1]],
            [expected[0], MarkdownAtom(identity: "0", offset: 8)],
            [MarkdownAtom(identity: "00", offset: 3), expected[1]],
            [MarkdownAtom(identity: "+0", offset: 3), expected[1]],
            [MarkdownAtom(identity: "object", offset: 3), expected[1]],
        ]
        for atoms in malformed {
            let data = try JSONEncoder().encode(MarkdownDocument(blocks: [], atoms: atoms))
            let pointer = try XCTUnwrap(strdup(String(decoding: data, as: UTF8.self)))
            var released = 0
            XCTAssertThrowsError(try MarkdownParser.decode(pointer, objects: [3, 8], release: {
                released += 1
                free($0)
            })) { XCTAssertEqual($0 as? MarkdownBridgeError, .invalidResponse) }
            XCTAssertEqual(released, 1, "\(atoms)")
        }
        let data = try JSONEncoder().encode(MarkdownDocument(blocks: [], atoms: expected))
        let pointer = try XCTUnwrap(strdup(String(decoding: data, as: UTF8.self)))
        var released = 0
        let document = try MarkdownParser.decode(pointer, objects: [3, 8], release: {
            released += 1
            free($0)
        })
        XCTAssertEqual(document.atoms, expected)
        XCTAssertEqual(released, 1)
    }

    func testRealFFIReadsEmptyInputEmbeddedNULAndUTF16ObjectOffsets() throws {
        for dialect in PreviewDialect.allCases {
            XCTAssertEqual(try MarkdownParser.parse("", dialect: dialect), MarkdownDocument(blocks: [], atoms: []))
            let parsed = try MarkdownParser.parse("🦀\0\u{FFFC}tail", objects: [3], dialect: dialect)
            XCTAssertEqual(parsed.atoms, [MarkdownAtom(identity: "0", offset: 3)])
            XCTAssertEqual(parsed.blocks, [.paragraph([.text("🦀�"), .object("0"), .text("tail")])])
            let multiple = try MarkdownParser.parse("🦀\u{FFFC} é\u{FFFC}", objects: [2, 5], dialect: dialect)
            XCTAssertEqual(multiple.atoms, [MarkdownAtom(identity: "0", offset: 2), MarkdownAtom(identity: "1", offset: 5)])
            XCTAssertEqual(multiple.blocks, [.paragraph([.text("🦀"), .object("0"), .text(" é"), .object("1")])])
            XCTAssertThrowsError(try MarkdownParser.parse("\u{FFFC}", objects: [-1], dialect: dialect)) {
                XCTAssertEqual($0 as? MarkdownParseError, .objectOffset)
            }
            for field in [0, 1, 2] {
                var limits = CompositionLimits()
                if field == 0 { limits.maximumInputScalars = -1 }
                if field == 1 { limits.maximumDepth = -1 }
                if field == 2 { limits.maximumTableCells = -1 }
                XCTAssertThrowsError(try MarkdownParser.parse("x", dialect: dialect, limits: limits)) {
                    XCTAssertEqual($0 as? MarkdownBridgeError, .invalidLimits)
                }
            }
        }
    }

    func testRepeatedReferenceRefusalRendersTheOriginalPageWithItsObjectOnce() throws {
        let chip = ChipAttachment(info: ChipInfo(
            chipId: 1, kind: "text", excerpt: "test-face", sizeLabel: "small", concealed: false
        ))
        let source = NSMutableAttributedString(string: "[r]: /u")
        source.append(NSAttributedString(attachment: chip))
        source.append(NSAttributedString(string: "\n| a |\n| - |\n\n[x][r] [y][r]"))
        XCTAssertThrowsError(try MarkdownParser.parse(source.string, objects: [7], dialect: .commonMark)) {
            XCTAssertEqual($0 as? MarkdownParseError, .duplicateObject("0"))
        }
        let rendered = MarkdownPreviewView.render(source, dialect: .commonMark)
        XCTAssertEqual(rendered.string, source.string + "\n")
        var found: [NSTextAttachment] = []
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found.append(attachment) }
        }
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first === chip)
        XCTAssertNil(rendered.attribute(.link, at: 7, effectiveRange: nil))
    }

    func testNativeHTMLPreservesNonbreakingAndOtherSignificantSpaces() {
        for dialect in PreviewDialect.allCases {
            for text in ["&nbsp;", "\u{2002}", "\u{2028}"] {
                let expected = text == "&nbsp;" ? "\u{00A0}" : text
                XCTAssertEqual(MarkdownPreviewView.render(
                    NSAttributedString(string: "<div>\(text)</div>"), dialect: dialect
                ).string, expected + "\n")
            }
        }
    }

    func testAListEndingDefinitionUsesComraksPlacementOutsideTheList() throws {
        let text = "- a\n- [r]: /u\u{FFFC}\n\npara"
        for dialect in PreviewDialect.allCases {
            let offset = (text as NSString).range(of: "\u{FFFC}").location
            let document = try MarkdownParser.parse(text, objects: [offset], dialect: dialect)
            XCTAssertEqual(document.blocks, [
                .list(ordered: false, start: 0, tight: true, items: [
                    MarkdownListItem(task: nil, blocks: [.paragraph([.text("a")])]),
                    MarkdownListItem(task: nil, blocks: []),
                ]),
                .objects(["0"]), .paragraph([.text("para")]),
            ])
        }
    }

    func testConservativeCellRefusalUsesTheOriginalNonTablePage() throws {
        let text = "heading\n---\ncontinued"
        var limits = CompositionLimits()
        limits.maximumTableCells = 0
        XCTAssertThrowsError(try MarkdownParser.parse(text, dialect: .gfm, limits: limits)) {
            XCTAssertEqual($0 as? MarkdownParseError, .tableCellLimit)
        }
        XCTAssertEqual(MarkdownPreviewView.render(NSAttributedString(string: text), limits: limits).string, text + "\n")
        XCTAssertNoThrow(try MarkdownParser.parse(text, dialect: .commonMark, limits: limits))
    }

    func testReseedingTheSameRenderingKeepsThePreviewAndNewInputRefreshesIt() {
        let preview = MarkdownPreviewView(page: 1, coordinator: nil)
        let first = PageModel.QuietRendering(text: NSAttributedString(string: "**first**"), fenceRegions: [])
        XCTAssertNil(preview.reseed(with: first))
        XCTAssertEqual(preview.string, "first\n")
        XCTAssertNil(preview.reseed(with: first))
        let next = PageModel.QuietRendering(text: NSAttributedString(string: "<em>next</em>"), fenceRegions: [])
        XCTAssertEqual(preview.reseed(with: next), "first\n")
        XCTAssertEqual(preview.string, "next\n")
    }
}
