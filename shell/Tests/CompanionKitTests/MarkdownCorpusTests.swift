import CryptoKit
import Foundation
import XCTest

@testable import CompanionKit

/// The official CommonMark 0.31.2 and GFM 0.29 examples, read by the pinned parsers and
/// written back by `MarkdownHTMLSerializer`, compared with the HTML each specification shows.
@MainActor
final class MarkdownCorpusTests: XCTestCase {
    /// Examples whose specification HTML the CommonMark parser does not produce.
    private static let commonMarkMismatches: [Int: String] = [:]

    /// Examples whose specification HTML the GFM parser does not produce, and what it does instead.
    private static let gfmMismatches: [Int: String] = [
        140: "the tagfilter writes `<script` and `</script` as `&lt;script` and `&lt;/script`; the example shows the block unfiltered",
        141: "the tagfilter writes `<style` and `</style` as `&lt;style` and `&lt;/style`; the example shows the block unfiltered",
        142: "the tagfilter writes `<style` as `&lt;style`; the example shows the block unfiltered",
        145: "the tagfilter writes `<style>` and `</style>` as `&lt;style>` and `&lt;/style>`; the example shows the block unfiltered",
        147: "the tagfilter writes `<script>` and `</script>` as `&lt;script>` and `&lt;/script>`; the example shows the block unfiltered",
        324: "`&#87654321;` decodes to U+FFFD: `houdini_unescape_ent` accepts eight decimal digits, the spec seven",
        611: "the extended autolink links `http://foo.bar/baz` inside `<http://foo.bar/baz bim>`",
        615: "the extended email autolink links `foo+@bar.example.com` inside the angle brackets",
        617: "the extended autolink links `http://foo.bar` inside `< http://foo.bar >`",
        620: "the extended autolink links `http://example.com`",
        621: "the extended email autolink links `foo@bar.example.com` as `mailto:`",
        634: "the email autolink restarts at a second `@` (`postprocess_text`), so `txt@bin` and `txt@bin.com` link alone",
        635: "the xmpp autolink continues past every `/` (`postprocess_text`), so `xmpp:foo@bar.baz/txt/bin` links whole",
        649: "`<!-- not a comment -- two hyphens -->` is raw HTML under the CommonMark 0.31 comment grammar; GFM 0.29 refuses `--` inside",
        650: "`<!-->` is a whole comment under the CommonMark 0.31 grammar; GFM 0.29 escapes it",
    ]

    private struct Outcome {
        let example: CorpusExample
        let actual: String
        var matches: Bool { actual.utf8.elementsEqual(example.html.utf8) }
    }

    private func outcomes(_ examples: [CorpusExample], _ dialect: PreviewDialect) -> [Outcome] {
        examples.map { example in
            do {
                let document = try MarkdownParser.parse(example.markdown, dialect: dialect)
                return Outcome(example: example, actual: MarkdownHTMLSerializer.html(document, dialect: dialect))
            } catch {
                return Outcome(example: example, actual: "MarkdownParser.parse threw \(error)")
            }
        }
    }

    /// The mismatching examples must be the table's keys: a new mismatch fails, and so does a fixed one.
    private func assertMismatches(
        _ outcomes: [Outcome], equal known: [Int: String], _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let numbers = Set(outcomes.map(\.example.example))
        let mismatched = Set(outcomes.filter { !$0.matches }.map(\.example.example))
        for outcome in outcomes where !outcome.matches && known[outcome.example.example] == nil {
            XCTFail("""
            \(name) example \(outcome.example.example) (\(outcome.example.section)) differs from the specification
            markdown: \(String(reflecting: outcome.example.markdown))
            expected: \(String(reflecting: outcome.example.html))
            actual:   \(String(reflecting: outcome.actual))
            """, file: file, line: line)
        }
        for (number, reason) in known.sorted(by: { $0.key < $1.key }) where !mismatched.contains(number) {
            let state = numbers.contains(number) ? "now matches the specification" : "is not an example"
            XCTFail("\(name) example \(number) \(state); drop it from the table (\(reason))", file: file, line: line)
        }
    }

    func testTheDownloadedSpecificationsAreTheRecordedDownloads() throws {
        _ = try SpecificationCorpus.read(SpecificationCorpus.commonMarkSpec)
        _ = try SpecificationCorpus.read(SpecificationCorpus.gfmSpec)
    }

    func testTheCommonMarkExamplesAreNumberedOneTo652() throws {
        XCTAssertEqual(try SpecificationCorpus.commonMarkExamples().map(\.example), Array(1...652))
    }

    func testTheGFMPageYieldsExamplesOneTo677AsTheLabExtractedThem() throws {
        let examples = try SpecificationCorpus.gfmExamples()
        XCTAssertEqual(examples.map(\.example), Array(1...677))
        let lab = try JSONDecoder().decode(
            [CorpusExample].self,
            from: Data(contentsOf: SpecificationCorpus.results.appendingPathComponent("gfm-official-examples.json"))
        )
        XCTAssertEqual(lab.map(\.example), examples.map(\.example))
        for (ours, theirs) in zip(examples, lab) {
            XCTAssertTrue(ours.markdown.utf8.elementsEqual(theirs.markdown.utf8), "example \(ours.example) markdown")
            XCTAssertTrue(ours.html.utf8.elementsEqual(theirs.html.utf8), "example \(ours.example) html")
            XCTAssertEqual(ours.section, theirs.section, "example \(ours.example) section")
        }
    }

    func testEveryCommonMarkExampleRendersAsTheSpecificationShows() throws {
        let examples = try SpecificationCorpus.commonMarkExamples()
        assertMismatches(outcomes(examples, .commonMark), equal: Self.commonMarkMismatches, "CommonMark")
    }

    func testEveryGFMExampleRendersAsTheSpecificationShowsBeyondTheKnownMismatches() throws {
        let examples = try SpecificationCorpus.gfmExamples()
        assertMismatches(outcomes(examples, .gfm), equal: Self.gfmMismatches, "GFM")
    }

    func testTheExactMatchCountsAreReported() throws {
        let commonMark = outcomes(try SpecificationCorpus.commonMarkExamples(), .commonMark)
        let gfm = outcomes(try SpecificationCorpus.gfmExamples(), .gfm)
        let commonMarkExact = commonMark.filter(\.matches).count
        let gfmExact = gfm.filter(\.matches).count
        let commonMarkExpected = commonMark.count - Self.commonMarkMismatches.count
        let gfmExpected = gfm.count - Self.gfmMismatches.count
        let report = "Markdown corpus exact HTML: CommonMark 0.31.2 \(commonMarkExact) of \(commonMark.count), "
            + "GFM 0.29 \(gfmExact) of \(gfm.count)"
        print(report)
        XCTContext.runActivity(named: report) { _ in
            XCTAssertEqual(commonMark.count, 652, report)
            XCTAssertEqual(gfm.count, 677, report)
            XCTAssertEqual(commonMarkExact, commonMarkExpected, report)
            XCTAssertEqual(gfmExact, gfmExpected, report)
        }
    }
}

/// One numbered example of an official specification.
struct CorpusExample: Decodable {
    let example: Int
    let section: String
    let markdown: String
    let html: String
}

enum CorpusError: Error, CustomStringConvertible {
    case checksum(name: String, expected: String, actual: String)
    case malformed(String)

    var description: String {
        switch self {
        case .checksum(let name, let expected, let actual):
            return "\(name) is not the recorded download: SHA-256 \(actual), expected \(expected)"
        case .malformed(let reason): return "the GFM page does not read as the lab read it: \(reason)"
        }
    }
}

/// The unmodified specification downloads in the parser lab (tools/markdown-preview-lab/parser/CORPUS-NOTICE.md).
enum SpecificationCorpus {
    struct Download {
        let name: String
        let sha256: String
    }

    static let commonMarkSpec = Download(
        name: "commonmark-0.31.2-spec.json",
        sha256: "d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20"
    )
    static let gfmSpec = Download(
        name: "gfm-0.29-spec.html",
        sha256: "b153d814fdfc8624bb6da7449162c1cd707a637f7d1c1b636eb44b9cf63fa220"
    )

    /// Tests/CompanionKitTests/<this file> is four levels below the repository root.
    static let results = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tools/markdown-preview-lab/parser/results")

    /// The download's bytes, refused unless they hash to the recorded SHA-256.
    static func read(_ download: Download) throws -> Data {
        let data = try Data(contentsOf: results.appendingPathComponent(download.name))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == download.sha256 else {
            throw CorpusError.checksum(name: download.name, expected: download.sha256, actual: digest)
        }
        return data
    }

    static func commonMarkExamples() throws -> [CorpusExample] {
        try JSONDecoder().decode([CorpusExample].self, from: read(commonMarkSpec))
    }

    static func gfmExamples() throws -> [CorpusExample] {
        try examples(fromGFMPage: Array(read(gfmSpec)))
    }

    /// The page's numbered examples by the lab extractor's rules (tools/markdown-preview-lab/parser/run.py,
    /// `GFMExamples`): example div ids, the two code blocks, entities decoded, shown tabs and spaces restored.
    static func examples(fromGFMPage page: [UInt8]) throws -> [CorpusExample] {
        let headings = try sectionHeadings(page)
        let opening = Array("<div class=\"example\" id=\"example-".utf8)
        var examples: [CorpusExample] = []
        var cursor = 0
        while let start = find(opening, in: page, from: cursor) {
            let digits = start + opening.count
            guard let quote = find(Array("\"".utf8), in: page, from: digits),
                  let number = Int(String(decoding: page[digits..<quote], as: UTF8.self))
            else { throw CorpusError.malformed("an example id at byte \(start)") }
            let end = find(opening, in: page, from: quote) ?? page.count
            let markdown = try codeBlock("language-markdown", in: page, from: quote, before: end, example: number)
            let html = try codeBlock("language-html", in: page, from: markdown.end, before: end, example: number)
            examples.append(CorpusExample(
                example: number,
                section: headings.last(where: { $0.end <= start })?.title ?? "",
                markdown: markdown.text,
                html: html.text
            ))
            cursor = end
        }
        return examples
    }

    /// Every h2 and h3 heading's text and where it closes, as the lab reads a section name.
    private static func sectionHeadings(_ page: [UInt8]) throws -> [(end: Int, title: String)] {
        var headings: [(end: Int, title: String)] = []
        var cursor = 0
        while let start = find(Array("<h".utf8), in: page, from: cursor) {
            cursor = start + 2
            guard start + 3 < page.count, page[start + 2] == UInt8(ascii: "2") || page[start + 2] == UInt8(ascii: "3"),
                  page[start + 3] == UInt8(ascii: " ") || page[start + 3] == UInt8(ascii: ">")
            else { continue }
            let closing = Array("</h".utf8) + [page[start + 2], UInt8(ascii: ">")]
            guard let tagEnd = find(Array(">".utf8), in: page, from: start),
                  let end = find(closing, in: page, from: tagEnd)
            else { throw CorpusError.malformed("an unclosed heading at byte \(start)") }
            var text: [UInt8] = []
            var inTag = false
            for byte in page[(tagEnd + 1)..<end] {
                switch byte {
                case UInt8(ascii: "<"): inTag = true
                case UInt8(ascii: ">"): inTag = false
                default: if !inTag { text.append(byte) }
                }
            }
            let title = String(decoding: try decodeEntities(text[...]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headings.append((end: end + closing.count, title: title))
            cursor = end + closing.count
        }
        return headings
    }

    /// One example code block's source: the space spans unwrapped, entities decoded, arrows made tabs.
    private static func codeBlock(
        _ language: String, in page: [UInt8], from start: Int, before limit: Int, example: Int
    ) throws -> (text: String, end: Int) {
        let opening = Array("<code class=\"\(language)\">".utf8)
        guard let open = find(opening, in: page, from: start, before: limit),
              let close = find(Array("</code>".utf8), in: page, from: open + opening.count, before: limit)
        else { throw CorpusError.malformed("example \(example) has no \(language) block") }
        var body = Array(page[(open + opening.count)..<close])
        for tag in ["<span class=\"space\">", "</span>"] { body = removing(Array(tag.utf8), from: body) }
        guard !body.contains(UInt8(ascii: "<")) else {
            throw CorpusError.malformed("example \(example) has other markup in its \(language) block")
        }
        let decoded = try decodeEntities(body[...])
        return (String(decoding: replacingArrows(decoded), as: UTF8.self), close + 7)
    }

    private static let entities: [([UInt8], UInt8)] = [
        (Array("&amp;".utf8), UInt8(ascii: "&")),
        (Array("&lt;".utf8), UInt8(ascii: "<")),
        (Array("&gt;".utf8), UInt8(ascii: ">")),
        (Array("&quot;".utf8), UInt8(ascii: "\"")),
    ]

    /// The four references the page's examples use; any other is a page the lab never read.
    private static func decodeEntities(_ bytes: ArraySlice<UInt8>) throws -> [UInt8] {
        var decoded: [UInt8] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard bytes[index] == UInt8(ascii: "&") else {
                decoded.append(bytes[index])
                index += 1
                continue
            }
            guard let entity = entities.first(where: { bytes[index...].starts(with: $0.0) }) else {
                let excerpt = String(decoding: bytes[index..<min(index + 12, bytes.endIndex)], as: UTF8.self)
                throw CorpusError.malformed("an unexpected reference \(String(reflecting: excerpt))")
            }
            decoded.append(entity.1)
            index += entity.0.count
        }
        return decoded
    }

    /// U+2192, the page's shown tab, back to a tab.
    private static func replacingArrows(_ bytes: [UInt8]) -> [UInt8] {
        let arrow: [UInt8] = [0xE2, 0x86, 0x92]
        var replaced: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index...].starts(with: arrow) {
                replaced.append(0x09)
                index += arrow.count
            } else {
                replaced.append(bytes[index])
                index += 1
            }
        }
        return replaced
    }

    private static func removing(_ pattern: [UInt8], from bytes: [UInt8]) -> [UInt8] {
        var kept: [UInt8] = []
        var cursor = 0
        while let found = find(pattern, in: bytes, from: cursor) {
            kept += bytes[cursor..<found]
            cursor = found + pattern.count
        }
        return kept + bytes[cursor...]
    }

    /// The first `pattern` starting at or after `start` that ends by `limit`.
    private static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int, before limit: Int? = nil) -> Int? {
        let last = (limit ?? bytes.count) - pattern.count
        guard !pattern.isEmpty, start <= last else { return nil }
        for index in start...last where bytes[index] == pattern[0] {
            if bytes[index..<(index + pattern.count)].elementsEqual(pattern) { return index }
        }
        return nil
    }
}
