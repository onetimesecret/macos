import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class MarkdownIntegrationPerformanceTests: XCTestCase {
    func testSyntheticParseDecodeAndNativeComposition() throws {
        for repetitions in [100, 1_000] {
            let text = String(repeating: "## Heading **bold**\n\nText &amp; [link](https://example.com).\n\n", count: repetitions)
            for dialect in PreviewDialect.allCases {
                let start = Date.timeIntervalSinceReferenceDate
                let document = try MarkdownParser.parse(text, dialect: dialect)
                let parsed = Date.timeIntervalSinceReferenceDate
                let rendered = MarkdownPreviewView.render(NSAttributedString(string: text), dialect: dialect)
                let finished = Date.timeIntervalSinceReferenceDate
                XCTAssertEqual(document.blocks.count, repetitions * 2)
                XCTAssertFalse(rendered.string.contains("**"))
                print("preview-profile \(dialect) input=\(text.utf8.count) parse_decode_ms=\((parsed - start) * 1_000) full_render_ms=\((finished - parsed) * 1_000)")
            }
        }
    }
}
