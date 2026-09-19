import AppKit
import XCTest

@testable import CompanionKit

/// One editor serves every page (ADR-0006, D-07), and the claim that
/// makes that worth anything is that a page comes back exactly as it
/// was left: the caret where the writer put it, the scroll where the
/// page was read to, and the undo stack the page had. Each of those is
/// pinned on its own elsewhere; this suite asks for all three across
/// one round trip, which is the acceptance the record states.
///
/// The switch is driven the way `updateNSView` drives it when
/// `sheetID` changes: the model's selection moves and the coordinator
/// hands the editor over with the scroller it lives in. SwiftUI's
/// `Context` cannot be built by hand, so the representable's update
/// pass is not called; the call it makes is.
///
/// The model is built with its seams named, so nothing here reaches
/// the installed app's state directory.
@MainActor
final class EditorPersistenceTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-editor-persistence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return isolatedModel(defaults: defaults)
    }

    private func mintPage(in model: PageModel) throws -> UInt64 {
        model.newPage()
        return try XCTUnwrap(model.selectedPageID)
    }

    /// The scroll restore lands one main queue hop after the swap
    /// (ADR-0005's timing discipline), so the loop is turned once to
    /// let it.
    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testACaretAndUndoSurviveATabChange() throws {
        let model = try makeModel()
        let first = try mintPage(in: model)
        let second = try mintPage(in: model)
        let coordinator = InkEditorView.Coordinator(model: model)
        let textView = InkEditorView.makeInkTextView(
            model: model, sheetID: first, coordinator: coordinator
        )
        textView.isEditable = true
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.currentSheet = first
        model.mountEditor(textView, from: .panel)

        // A short card, so the page written below outgrows its clip and
        // the scroll offset is a real position rather than zero.
        let scroll = InkEditorView.scrollStack(for: textView)
        let card = NSRect(x: 0, y: 0, width: 420, height: 160)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()

        // One insertion is one undoable step in the core.
        let page = (0..<80).map { "line \($0) of the first page\n" }.joined()
        textView.insertText(page, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(model.coreClient.canUndo(sheet: first))
        XCTAssertFalse(model.coreClient.canRedo(sheet: first))

        let caret = NSRange(location: page.utf16.count / 2, length: 0)
        textView.setSelectedRange(caret)

        let container = try XCTUnwrap(textView.textContainer)
        textView.layoutManager?.ensureLayout(for: container)
        scroll.layoutSubtreeIfNeeded()
        let bottom = textView.frame.height - scroll.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 0, "the fixture must outgrow its card")
        let offset = NSPoint(x: 0, y: (bottom / 2).rounded())
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)

        // Away to the second page and back again.
        model.select(second)
        coordinator.moveEditor(
            textView, to: second, storage: model.storage(for: second), restoringScrollIn: scroll
        )
        pump()
        XCTAssertEqual(coordinator.currentSheet, second)
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: 0, length: 0),
            "the second page's caret is its own, not the first page's")

        model.select(first)
        coordinator.moveEditor(
            textView, to: first, storage: model.storage(for: first), restoringScrollIn: scroll
        )
        pump()

        XCTAssertEqual(coordinator.currentSheet, first)
        XCTAssertEqual(textView.selectedRange(), caret, "the caret did not survive the trip")
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y, offset.y, accuracy: 0.5,
            "the scroll did not survive the trip")
        XCTAssertTrue(
            model.coreClient.canUndo(sheet: first), "the undo stack did not survive the trip")
        XCTAssertFalse(model.coreClient.canRedo(sheet: first))
        XCTAssertFalse(
            model.coreClient.canUndo(sheet: second), "the first page's step leaked next door")

        // And the step is still the one that was taken: one press
        // takes the whole insertion out and leaves nothing behind it.
        coordinator.step(back: true)
        XCTAssertEqual(model.storage(for: first).string, "")
        XCTAssertFalse(model.coreClient.canUndo(sheet: first))
        XCTAssertTrue(model.coreClient.canRedo(sheet: first))
    }
}
