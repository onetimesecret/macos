import AppKit
import XCTest

@testable import CompanionKit

/// A page's caret and scroll belong to the model, so the place one
/// editor leaves is the place the next one finds (issue #198).
///
/// One editor serves every page (ADR-0006), but it is not the only
/// editor a page will ever meet: a ledger round trip builds another,
/// and the editor window builds one of its own beside the panel's
/// (ADR-0033). Each comes with a fresh coordinator. While the place was
/// kept in the coordinator, every one of those started the page from
/// the top with the caret at zero. `EditorPersistenceTests` holds the
/// round trip through one editor; this suite holds the trip from one
/// editor to a different one.
///
/// Real AppKit in headless windows, in the `PageScrollTests` idiom, and
/// every model is built with its seams named, so nothing here reaches
/// the installed app's state directory.
@MainActor
final class PageViewStateTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-page-view-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return isolatedModel(defaults: defaults)
    }

    private func mintPage(in model: PageModel) throws -> UInt64 {
        model.newPage()
        return try XCTUnwrap(model.selectedPageID)
    }

    /// One mounted editor: a coordinator of its own, a text view built
    /// by the shipped factory, and the scroller the page surface wraps
    /// it in, inside a window of the given width. The window is
    /// returned so the caller keeps the whole mount alive.
    private struct Mount {
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let scroll: NSScrollView
        let window: NSWindow
    }

    private func mount(
        _ page: UInt64, of model: PageModel, width: CGFloat, height: CGFloat = 160
    ) -> Mount {
        let coordinator = InkEditorView.Coordinator(model: model)
        let textView = InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator
        )
        let scroll = InkEditorView.scrollStack(for: textView)
        let card = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        return Mount(coordinator: coordinator, textView: textView, scroll: scroll, window: window)
    }

    private func settleLayout(of mount: Mount) throws {
        let container = try XCTUnwrap(mount.textView.textContainer)
        mount.textView.layoutManager?.ensureLayout(for: container)
        mount.scroll.layoutSubtreeIfNeeded()
    }

    /// The scroll restore lands one main queue hop after it is asked
    /// for (ADR-0005's timing discipline), so the loop is turned once
    /// to let it.
    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: The table's own laws

    func testARepairMendsAnEntryAndNeverResurrectsOne() {
        var states = PageViewStates()
        states.saveScroll(NSPoint(x: 0, y: 10), for: 1)

        states.repairScroll(NSPoint(x: 0, y: 90), for: 1)
        states.repairScroll(NSPoint(x: 0, y: 90), for: 2)

        XCTAssertEqual(states.scrolls[1], NSPoint(x: 0, y: 90))
        XCTAssertNil(states.scrolls[2], "a page pruned in the interim stays gone")
    }

    func testThePruneTakesADeadPagesPlaceAndKeepsAFiles() {
        let file = CompanionClient.fileIDTag | 4
        var states = PageViewStates()
        for id in [1, 2, file] {
            states.saveCaret(NSRange(location: 3, length: 0), for: id)
            states.saveScroll(NSPoint(x: 0, y: 20), for: id)
        }

        states.prune(keeping: [1])

        XCTAssertEqual(states.keys, [1, file])
        XCTAssertNil(states.carets[2])
        XCTAssertNil(states.scrolls[2])

        states.forget(file)
        XCTAssertEqual(states.keys, [1], "a file's place goes when the roster drops it by name")
    }

    /// The model prunes the table where it prunes the storage cache, so
    /// a page that dies takes its place with it whether or not any
    /// editor is mounted to notice.
    func testAClosedPagesPlaceIsPrunedByTheModelsRefresh() throws {
        let model = try makeModel()
        let kept = try mintPage(in: model)
        let closed = try mintPage(in: model)
        model.viewStates.saveCaret(NSRange(location: 1, length: 0), for: kept)
        model.viewStates.saveCaret(NSRange(location: 1, length: 0), for: closed)
        let tab = try XCTUnwrap(model.tabs.first { $0.pageID == closed }?.id)

        model.close(tab)

        XCTAssertNotNil(model.viewStates.carets[kept])
        XCTAssertNil(
            model.viewStates.carets[closed],
            "a dead page's caret would be waiting for whatever page took its slot")
    }

    // MARK: From one editor to another

    func testAPlaceSavedByOneEditorIsRestoredByAnother() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let first = mount(page, of: model, width: 420)

        let text = (0..<80).map { "line \($0) of the page\n" }.joined()
        first.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        let caret = NSRange(location: text.utf16.count / 2, length: 3)
        first.textView.setSelectedRange(caret)
        try settleLayout(of: first)
        let bottom = first.textView.frame.height - first.scroll.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 0, "the fixture must outgrow its card")
        let offset = NSPoint(x: 0, y: (bottom / 2).rounded())
        first.scroll.contentView.scroll(to: offset)
        first.scroll.reflectScrolledClipView(first.scroll.contentView)

        first.coordinator.saveViewState(textView: first.textView, scrollView: first.scroll)

        // A different editor, with a different coordinator, over the
        // same page: the ledger round trip's shape, and the hand off
        // between two windows'.
        let second = mount(page, of: model, width: 420)
        XCTAssertFalse(second.coordinator === first.coordinator)
        XCTAssertEqual(second.textView.selectedRange(), NSRange(location: 0, length: 0))

        second.coordinator.restoreViewState(
            textView: second.textView, scrollView: second.scroll, for: page
        )
        pump()

        XCTAssertEqual(
            second.textView.selectedRange(), caret,
            "the caret is the page's, whichever editor is standing on it")
        XCTAssertEqual(
            second.scroll.contentView.bounds.origin.y, offset.y, accuracy: 0.5,
            "the second editor opened the page somewhere the person was not")
    }
}
