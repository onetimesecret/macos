import AppKit
import XCTest

@testable import CompanionKit

/// Building the one editor, and moving it from page to page, apart from
/// the scroll view it has always been built inside.
///
/// There is exactly one editor for every page (ADR-0006), and until now
/// there was also exactly one way to bring it into the world: a
/// representable that made a text view and a scroller in a single
/// breath. A surface that shows several days at once needs the same
/// editor mounted somewhere else (ADR-0020), and the danger in
/// separating the two halves is not that the seam breaks loudly, it is
/// that a flag goes missing quietly. The flags below are the ones whose
/// absence is invisible until it matters: rich text, or chips stop
/// surviving an edit; undo, or ⌘Z beeps; the coordinator on both the
/// view and the storage, or the page stops speaking to the core at all.
///
/// Real AppKit in a headless window, in the `PageScrollTests` idiom,
/// because what is under test is a view's wiring and its geometry rather
/// than a decision worth modelling twice.
@MainActor
final class EditorFactoryTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-editor-factory-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return isolatedModel(defaults: defaults)
    }

    /// A page minted by the shipped gesture, named the way every
    /// page-addressed call names one: by page identity, never by the
    /// slot's (ADR-0017).
    private func mintPage(in model: PageModel) throws -> UInt64 {
        model.newPage()
        return try XCTUnwrap(model.selectedPageID)
    }

    /// The card, sized as the backdrop sizes it.
    private func cardWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
    }

    // MARK: Building the editor

    func testTheBuiltEditorCarriesTheFlagsThePageRestsOn() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let coordinator = InkEditorView.Coordinator(model: model)

        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator
        ))

        XCTAssertTrue(
            textView.isRichText,
            "a plain-text view drops chip attachments the moment the page is edited"
        )
        XCTAssertFalse(
            textView.allowsUndo,
            "undo is the core's stack now (issue #132); a second AppKit history of the "
                + "same document could only ever disagree with it"
        )
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(
            textView.isAutomaticSpellingCorrectionEnabled,
            "the page renders what was typed; nothing may rewrite ink on its way in"
        )
        XCTAssertFalse(textView.drawsBackground, "the card's own material shows through the page")
        // AppKit's two find switches read back as one choice, and the
        // bar is the face this page picks: with it on, `usesFindPanel`
        // answers false however it was set. `enableFinding` sets both,
        // in the order `makeNSView` set them before the building was
        // factored out of it (9da5cdc), so what the built editor
        // carries is what the mounted page has always carried, and the
        // bar is the switch that can be held to it.
        XCTAssertTrue(textView.usesFindBar, "the bar under the card's edge, not a second window")
        XCTAssertEqual(textView.textContainerInset.height, InkEditorView.Coordinator.topInset)
        XCTAssertEqual(textView.typingAttributes[.font] as? NSFont, InkStyle.baseFont)
        XCTAssertEqual(
            textView.textContainer?.widthTracksTextView, true,
            "the container takes its width from the view, which is what makes the page wrap"
        )
    }

    func testTheBuiltEditorSpeaksThroughTheCoordinatorItWasHanded() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let coordinator = InkEditorView.Coordinator(model: model)

        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator
        ))

        XCTAssertTrue(textView.delegate === coordinator)
        XCTAssertTrue(textView.coordinator === coordinator, "the page's chords have nowhere to go")
        XCTAssertTrue(
            model.storage(for: page).delegate === coordinator,
            "without the storage delegate the page types into the shell and never into the core"
        )
        XCTAssertTrue(coordinator.textView === textView)
        XCTAssertEqual(coordinator.currentSheet, page, "the editor knows which page it is showing")
        XCTAssertTrue(
            model.activeEditor === textView,
            "the focus law hands the keyboard through this handle (ADR-0005, issue #23)"
        )
        XCTAssertTrue(
            model.performSealedPaste != nil,
            "the summon-time offer's button reaches the caret by no other road"
        )
    }

    /// A ledger round trip, or a visit to a slot whose page expired,
    /// tears the editor down and builds another over the same page. The
    /// storage outlives both, so the shed has to run at every building
    /// or two managers end up laying one page out (ADR-0006).
    func testASecondBuildingOverThePageLeavesOneLayoutManager() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let first = InkEditorView.Coordinator(model: model)
        // The first editor and its manager are both held for the length
        // of the test, so what the count says below is the shed's doing
        // and never ARC's.
        let torndown = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: first
        ))
        let oldManager = model.storage(for: page).layoutManagers.first
        XCTAssertEqual(model.storage(for: page).layoutManagers.count, 1)
        XCTAssertTrue(torndown.layoutManager === oldManager)

        let second = InkEditorView.Coordinator(model: model)
        let rebuilt = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: second
        ))

        XCTAssertEqual(
            model.storage(for: page).layoutManagers.count, 1,
            "a second manager over one storage lets a stale editor render a page being edited"
        )
        XCTAssertTrue(
            model.storage(for: page).layoutManagers.first === rebuilt.layoutManager,
            "the page is laid out by the editor that is on screen"
        )
        XCTAssertFalse(
            model.storage(for: page).layoutManagers.contains { $0 === oldManager },
            "the torn-down editor is still laying this page out"
        )
        XCTAssertTrue(
            model.storage(for: page).delegate === second,
            "ops would be emitted by a coordinator nobody is listening to"
        )
    }

    /// The two halves compose back into the page the app mounts, and the
    /// scroller's part of that is the one flag whose absence is silent:
    /// an unbounded `maxSize`, without which the document stops growing
    /// at exactly one cardful.
    func testTheBuiltEditorAndItsScrollerStillMakeAPageThatCanGrow() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let coordinator = InkEditorView.Coordinator(model: model)

        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator
        ))
        let scroll = InkEditorView.scrollStack(for: textView)

        XCTAssertEqual(textView.maxSize.width, CGFloat.greatestFiniteMagnitude)
        XCTAssertEqual(
            textView.maxSize.height, CGFloat.greatestFiniteMagnitude,
            "a capped document is written past its first cardful and never scrolled to"
        )
        XCTAssertTrue(textView.isVerticallyResizable)
        XCTAssertFalse(
            textView.isHorizontallyResizable,
            "width is the container's business, so the page wraps rather than running sideways"
        )

        let window = cardWindow()
        window.contentView?.addSubview(scroll)
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        scroll.layoutSubtreeIfNeeded()

        XCTAssertTrue(scroll.documentView === textView)
        XCTAssertEqual(model.storage(for: page).layoutManagers.count, 1)
        XCTAssertTrue(model.storage(for: page).delegate === coordinator)
    }

    // MARK: Moving the editor between pages

    /// The swap ceremony with no scroller of its own: the shape a
    /// surface that rolls several days past one clip will mount the
    /// editor in (ADR-0020). Everything that belongs to the page still
    /// crosses (the storage, the storage delegate, the caret) and the
    /// offset, which belongs to a scroller rather than to a page, is
    /// simply not asked for.
    func testMovingTheEditorWithNoScrollerCarriesThePageAndItsCaret() throws {
        let model = try makeModel()
        let first = try mintPage(in: model)
        let second = try mintPage(in: model)
        let coordinator = InkEditorView.Coordinator(model: model)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: first, coordinator: coordinator
        ))

        // Mounted in a plain view, not in a scroller: the editor is one
        // region among several rather than the only thing in its clip.
        let window = cardWindow()
        textView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        window.contentView?.addSubview(textView)

        textView.insertText(
            "the first page", replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        let firstStorage = model.storage(for: first)
        let secondStorage = model.storage(for: second)

        coordinator.moveEditor(
            textView, to: second, storage: secondStorage, restoringScrollIn: nil
        )

        XCTAssertTrue(textView.textStorage === secondStorage, "the editor is showing the old page")
        XCTAssertEqual(coordinator.currentSheet, second, "undo would rewrite the page next door")
        XCTAssertNil(
            firstStorage.delegate,
            "a page in the background must stop emitting, or a projection reads as an edit"
        )
        XCTAssertTrue(secondStorage.delegate === coordinator)
        XCTAssertEqual(secondStorage.layoutManagers.count, 1)
        XCTAssertEqual(
            firstStorage.layoutManagers.count, 0,
            "the manager travels with the editor; the page left behind keeps none"
        )

        // And back: a page returns with the caret it was left with.
        coordinator.moveEditor(
            textView, to: first, storage: firstStorage, restoringScrollIn: nil
        )

        XCTAssertTrue(textView.textStorage === firstStorage)
        XCTAssertEqual(coordinator.currentSheet, first)
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: 4, length: 0),
            "the caret is the page's wherever the page is mounted"
        )
        XCTAssertTrue(firstStorage.delegate === coordinator)
        XCTAssertNil(secondStorage.delegate)
        XCTAssertEqual(firstStorage.layoutManagers.count, 1)
        XCTAssertEqual(secondStorage.layoutManagers.count, 0)
    }
}
