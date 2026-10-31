import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class MarkdownDeferredRenderingTests: XCTestCase {
    private var source: String {
        let block = "## Heading **bold**\n\n~~strike~~ [link](https://example.com)\n\n"
        return String(repeating: block, count: MarkdownPreviewView.deferredRenderingThreshold / block.utf16.count + 1)
    }

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
        XCTAssertEqual(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, InkStyle.baseFont)
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
        view.setSelectedRange(NSRange(location: 1, length: 3))
        var callbacks = 0
        view.onRenderingChanged = { _ in callbacks += 1 }
        view.reseed(with: rendering(source), dialect: .gfm)
        let pending = try XCTUnwrap(view.renderingTask)
        XCTAssertEqual(view.reseed(with: rendering("# New page"), dialect: .gfm), "Before\n")
        XCTAssertTrue(pending.isCancelled)
        XCTAssertFalse(view.isRendering)
        XCTAssertEqual(view.string, "New page\n")
        let replacementSelection = NSRange(location: 2, length: 2)
        view.setSelectedRange(replacementSelection)
        await pending.value
        XCTAssertEqual(view.string, "New page\n")
        XCTAssertEqual(view.selectedRange(), replacementSelection)
        XCTAssertEqual(callbacks, 0)
    }

    func testEqualReplacementReusesPendingWorkAndPublishesOnce() async throws {
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        var callbacks = 0
        view.onRenderingChanged = { _ in callbacks += 1 }
        view.reseed(with: rendering(source), dialect: .gfm)
        let pending = try XCTUnwrap(view.renderingTask)
        let replacement = rendering(source)
        view.reseed(with: replacement, dialect: .gfm)
        XCTAssertEqual(view.renderingTask, pending)
        await pending.value
        XCTAssertFalse(view.isRendering)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(view.string, MarkdownPreviewView.render(replacement.text).string)
        view.reseed(with: replacement, dialect: .gfm)
        XCTAssertNil(view.renderingTask)
        XCTAssertEqual(callbacks, 1)
    }

    func testCancelledCurrentRenderingReleasesBusyStateWithCurrentSource() async throws {
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.isSelectedPage = true
        view.reseed(with: rendering("# Before"), dialect: .gfm)
        var callbacks = 0
        view.onRenderingChanged = { previous in
            XCTAssertEqual(previous, "Before\n")
            callbacks += 1
        }
        view.reseed(with: rendering(source), dialect: .gfm)
        let pending = try XCTUnwrap(view.renderingTask)
        pending.cancel()
        await pending.value
        XCTAssertFalse(view.isRendering)
        XCTAssertNil(view.renderingTask)
        XCTAssertTrue(view.isSelectable)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(callbacks, 1)
    }

    func testCancelledRenderingCanRetryIdenticalAndEquivalentSources() async throws {
        let original = rendering(source)
        let expected = MarkdownPreviewView.render(original.text)
        for sameWrapper in [true, false] {
            let view = MarkdownPreviewView(page: 1, coordinator: nil)
            view.isSelectedPage = true
            view.reseed(with: original, dialect: .gfm)
            let cancelled = try XCTUnwrap(view.renderingTask)
            cancelled.cancel()
            await cancelled.value
            XCTAssertEqual(view.string, source)
            var callbacks = 0
            view.onRenderingChanged = { previous in
                XCTAssertEqual(previous, self.source)
                callbacks += 1
            }
            view.reseed(with: sameWrapper ? original : rendering(source), dialect: .gfm)
            XCTAssertTrue(view.isRendering)
            let retry = try XCTUnwrap(view.renderingTask)
            XCTAssertNotEqual(retry, cancelled)
            await retry.value
            XCTAssertFalse(view.isRendering)
            XCTAssertTrue(view.isSelectable)
            XCTAssertEqual(view.string, expected.string)
            XCTAssertEqual(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                           expected.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(callbacks, 1)
            view.reseed(with: original, dialect: .gfm)
            view.reseed(with: rendering(source), dialect: .gfm)
            XCTAssertNil(view.renderingTask)
            XCTAssertEqual(callbacks, 1)
        }
    }

    func testEqualLengthCanonicalUnicodeEditReplacesPendingSource() async throws {
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.reseed(with: rendering("\u{212b}\n" + source), dialect: .gfm)
        let previous = try XCTUnwrap(view.renderingTask)
        view.reseed(with: rendering("\u{00c5}\n" + source), dialect: .gfm)
        let latest = try XCTUnwrap(view.renderingTask)
        XCTAssertNotEqual(previous, latest)
        await latest.value
        await previous.value
        XCTAssertFalse(view.isRendering)
        XCTAssertEqual(view.string.utf16.first, 0x00c5)
    }

    func testCompletedLargeSourceReusesEquivalentWrapperWithoutLoadingFlash() async throws {
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.isSelectedPage = true
        view.reseed(with: rendering(source), dialect: .gfm)
        try await XCTUnwrap(view.renderingTask).value
        let storage = try XCTUnwrap(view.textStorage)
        let output = NSAttributedString(attributedString: storage)
        let selection = NSRange(location: 0, length: 7)
        view.setSelectedRange(selection)
        XCTAssertTrue(view.imageControls.buttons.isEmpty)
        XCTAssertNil(view.reseed(with: rendering(source), dialect: .gfm))
        XCTAssertFalse(view.isRendering)
        XCTAssertNil(view.renderingTask)
        XCTAssertTrue(view.isSelectable)
        XCTAssertTrue(storage.isEqual(to: output))
        XCTAssertEqual(view.selectedRange(), selection)
    }

    func testTypefaceChangesKeepDeepSelectionAcrossRepeatedDeferredReseeds() async throws {
        let previousTypeface = InkStyle.typeface
        defer { InkStyle.typeface = previousTypeface }
        InkStyle.typeface = .init(family: "Helvetica", codeFamily: "Menlo", size: 13)
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.isSelectedPage = true
        let original = rendering(source)
        view.reseed(with: original, dialect: .gfm)
        try await XCTUnwrap(view.renderingTask).value
        let text = view.string
        let selection = NSRange(location: text.utf16.count / 2, length: 40)
        view.setSelectedRange(selection)
        InkStyle.typeface = .init(family: "Helvetica", codeFamily: "Menlo", size: 22)
        view.reseed(with: original, dialect: .gfm)
        let superseded = try XCTUnwrap(view.renderingTask)
        InkStyle.typeface = .init(family: "Helvetica", codeFamily: "Menlo", size: 17)
        view.reseed(with: rendering(source), dialect: .gfm)
        let latest = try XCTUnwrap(view.renderingTask)
        view.reseed(with: rendering(source), dialect: .gfm)
        XCTAssertEqual(view.renderingTask, latest)
        await latest.value
        await superseded.value
        XCTAssertEqual(view.string, text)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                       MarkdownPreviewView.render(original.text).attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    }

    func testPendingReplacementClampsOriginalSelectionForSynchronousAndDeferredFinalText() async throws {
        for deferredReplacement in [false, true] {
            let view = MarkdownPreviewView(page: 1, coordinator: nil)
            view.isSelectedPage = true
            view.reseed(with: rendering(source + source), dialect: .gfm)
            try await XCTUnwrap(view.renderingTask).value
            let finalSource = deferredReplacement ? source : String(repeating: "word ", count: 2_000)
            let finalLength = MarkdownPreviewView.render(NSAttributedString(string: finalSource)).length
            view.setSelectedRange(NSRange(location: finalLength - 12, length: 40))
            view.reseed(with: rendering(source + source + "\nintermediate"), dialect: .gfm)
            let superseded = try XCTUnwrap(view.renderingTask)
            view.reseed(with: rendering(finalSource), dialect: .gfm)
            if deferredReplacement { try await XCTUnwrap(view.renderingTask).value }
            else { XCTAssertNil(view.renderingTask) }
            XCTAssertEqual(view.string.utf16.count, finalLength)
            XCTAssertEqual(view.selectedRange(), NSRange(location: finalLength - 12, length: 12))
            let currentSelection = NSRange(location: 2, length: 3)
            view.setSelectedRange(currentSelection)
            await superseded.value
            XCTAssertEqual(view.selectedRange(), currentSelection)
        }
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
        let pending = try XCTUnwrap(view.renderingTask)
        await pending.value
        XCTAssertFalse(view.isRendering)
        XCTAssertGreaterThan(view.frame.height, initialHeight + 1_000)
        XCTAssertGreaterThan(stack.frame.height, initialHeight + 1_000)
        XCTAssertTrue(view.string.hasPrefix("Heading bold\n"))
    }

    private func rendering(_ text: String) -> PageModel.QuietRendering {
        PageModel.QuietRendering(text: NSAttributedString(string: text), fenceRegions: [])
    }
}
