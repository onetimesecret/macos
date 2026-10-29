import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class MarkdownDeferredRenderingTests: XCTestCase {
    private let source = String(repeating: "## Heading **bold**\n\n~~strike~~ [link](https://example.com)\n\n", count: 400)

    func testLargePreviewYieldsAndOffersNoInterimText() async throws {
        let suite = "deferred-preview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        model.syncDocument(sheet: page, runs: [.ink(source)])
        let coordinator = InkEditorView.Coordinator(model: model)
        let view = MarkdownPreviewView(page: page, coordinator: coordinator)
        view.isSelectedPage = true
        XCTAssertTrue(view.mayReadOut)
        let completed = expectation(description: "rendered")
        view.onRenderingChanged = { previous in
            XCTAssertNil(previous)
            completed.fulfill()
        }
        XCTAssertNil(view.reseed(with: rendering(source), dialect: .gfm))
        XCTAssertTrue(view.isRendering)
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        XCTAssertFalse(view.mayReadOut)
        XCTAssertTrue(view.shownSelection().isEmpty)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertFalse(view.writeSelection(to: board, type: .string))
        await Task.yield()
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertFalse(view.isRendering)
        XCTAssertTrue(view.mayReadOut)
        XCTAssertEqual(view.string, MarkdownPreviewView.render(NSAttributedString(string: source)).string)
    }

    func testShortReplacementRejectsPendingLargeCompletion() async throws {
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.reseed(with: rendering("# Before"), dialect: .gfm)
        var callbacks = 0
        view.onRenderingChanged = { _ in callbacks += 1 }
        view.reseed(with: rendering(source), dialect: .gfm)
        XCTAssertEqual(view.reseed(with: rendering("# New page"), dialect: .gfm), "Before\n")
        XCTAssertFalse(view.isRendering)
        XCTAssertEqual(view.string, "New page\n")
        _ = try await MarkdownPreviewParsing.shared.parse("barrier", objects: [], dialect: .gfm, limits: CompositionLimits())
        await Task.yield()
        XCTAssertEqual(view.string, "New page\n")
        XCTAssertEqual(callbacks, 0)
    }

    func testDialectChangePublishesOnlyLatestLargeRendering() async throws {
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.reseed(with: rendering("# Before"), dialect: .gfm)
        let completed = expectation(description: "latest dialect")
        view.onRenderingChanged = { previous in
            XCTAssertEqual(previous, "Before\n")
            completed.fulfill()
        }
        let text = rendering(source)
        view.reseed(with: text, dialect: .commonMark)
        view.reseed(with: text, dialect: .gfm)
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertFalse(view.string.contains("~~"))
        XCTAssertFalse(view.isRendering)
    }

    func testCancelledQueuedParserDoesNotReturnAStaleDocument() async throws {
        let task = Task {
            try await MarkdownPreviewParsing.shared.parse(source, objects: [], dialect: .gfm, limits: CompositionLimits())
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled parser returned a document")
        } catch is CancellationError {
        }
    }

    func testMountedRollRemeasuresAfterDeferredCompletion() async throws {
        let suite = "deferred-roll-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        model.showsTimeUnits = true
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        model.syncDocument(sheet: page, runs: [.ink(source)])
        if !model.markdownPreviewEnabled(for: page) { model.toggleMarkdownPreview(for: page) }
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = DayScrollView.makeRoll(model: model, coordinator: coordinator, emptyHint: "Fixture")
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        stack.update(projection: model.timeUnits, selectedPage: page, readOnly: false)
        let view = try XCTUnwrap(stack.previewRegions[page])
        XCTAssertTrue(view.isRendering)
        let initialHeight = view.frame.height
        let completed = expectation(description: "mounted preview remeasured")
        let rollCompletion = view.onRenderingChanged
        view.onRenderingChanged = { previous in
            rollCompletion?(previous)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertFalse(view.isRendering)
        XCTAssertGreaterThan(view.frame.height, initialHeight + 1_000)
        XCTAssertGreaterThan(stack.frame.height, initialHeight + 1_000)
        XCTAssertTrue(view.string.hasPrefix("Heading bold\n"))
    }

    private func rendering(_ text: String) -> PageModel.QuietRendering {
        PageModel.QuietRendering(text: NSAttributedString(string: text), fenceRegions: [])
    }
}
