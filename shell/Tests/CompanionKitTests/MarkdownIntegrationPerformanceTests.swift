import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class MarkdownIntegrationPerformanceTests: XCTestCase {
    func testSyntheticParseDecodeAndNativeComposition() throws {
        try parseAndRender(repetitions: [100], reportTimings: false)
    }

    func testOptInLargePreviewProfile() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PREVIEW_PROFILE"] == "1")
        try parseAndRender(repetitions: [100, 1_000], reportTimings: true)
        try reseedBatch(repetitions: 1_000, reportTimings: true)
    }

    private func parseAndRender(repetitions counts: [Int], reportTimings: Bool) throws {
        for repetitions in counts {
            let text = String(repeating: "## Heading **bold**\n\nText &amp; [link](https://example.com).\n\n", count: repetitions)
            for dialect in PreviewDialect.allCases {
                let start = Date.timeIntervalSinceReferenceDate
                let document = try MarkdownParser.parse(text, dialect: dialect)
                let parsed = Date.timeIntervalSinceReferenceDate
                let rendered = MarkdownPreviewView.render(NSAttributedString(string: text), dialect: dialect)
                let finished = Date.timeIntervalSinceReferenceDate
                XCTAssertEqual(document.blocks.count, repetitions * 2)
                XCTAssertFalse(rendered.string.contains("**"))
                if reportTimings {
                    print("preview-profile \(dialect) input=\(text.utf8.count) parse_decode_ms=\((parsed - start) * 1_000) full_render_ms=\((finished - parsed) * 1_000)")
                }
            }
        }
    }

    func testSeveralLargePreviewsReseedAndLayoutInOneBatch() throws {
        try reseedBatch(repetitions: 100, reportTimings: false)
    }

    private func reseedBatch(repetitions: Int, reportTimings: Bool) throws {
        let suite = "markdown-preview-performance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        let coordinator = InkEditorView.Coordinator(model: model)
        let source = String(repeating: "## Heading **bold**\n\nText &amp; [link](https://example.com).\n\n", count: repetitions)
        var pages: [UInt64] = []
        for _ in 0..<4 {
            model.newPage()
            let page = try XCTUnwrap(model.selectedPageID)
            model.syncDocument(sheet: page, runs: [.ink(source)])
            if !model.markdownPreviewEnabled(for: page) { model.toggleMarkdownPreview(for: page) }
            pages.append(page)
        }
        let renderings = pages.map { model.quietRendering(for: $0) }
        let previews = pages.map { MarkdownPreviewView(page: $0, coordinator: coordinator) }
        for preview in previews { preview.frame = NSRect(x: 0, y: 0, width: 420, height: 320) }
        let start = Date.timeIntervalSinceReferenceDate
        for (preview, rendering) in zip(previews, renderings) {
            XCTAssertNil(preview.reseed(with: rendering, dialect: model.markdownDialect))
            XCTAssertTrue(preview.string.hasPrefix("Heading bold\n"))
        }
        let seeded = Date.timeIntervalSinceReferenceDate
        for preview in previews {
            if let container = preview.textContainer { preview.layoutManager?.ensureLayout(for: container) }
        }
        let laidOut = Date.timeIntervalSinceReferenceDate
        for (preview, rendering) in zip(previews, renderings) {
            XCTAssertNil(preview.reseed(with: rendering, dialect: model.markdownDialect))
        }
        let reused = Date.timeIntervalSinceReferenceDate
        if reportTimings {
            print("preview-batch pages=\(previews.count) bytes_per_page=\(source.utf8.count) reseed_ms=\((seeded - start) * 1_000) layout_ms=\((laidOut - seeded) * 1_000) unchanged_reseed_ms=\((reused - laidOut) * 1_000)")
        }
    }
}
