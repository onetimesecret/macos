import AppKit
import XCTest

@testable import CompanionKit

/// Handing the keyboard to an editor that is actually there (issue
/// #23).
///
/// One editor serves every page (ADR-0006), and it is torn down and
/// rebuilt more often than the page switches: a ledger round trip does
/// it, and since tabs and pages came apart so does a visit to a slot
/// whose page expired. The model holds that editor weakly, for the
/// grants and the summon to hand the keyboard to, and the window
/// between a teardown and ARC letting go is a window in which the
/// handle answers with a view that is no longer on screen. What the
/// hand-off needs to know is not whether the view exists but whether it
/// is mounted, and a mounted view is one inside a window.
///
/// Real AppKit objects rather than stand-ins: the fact under test is a
/// view's relationship to a window, which is not a thing worth
/// modelling twice.
@MainActor
final class EditorHandoffTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-editor-handoff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return isolatedModel(defaults: defaults)
    }

    /// A card-sized window with a text view mounted in it, held by the
    /// caller so nothing here rests on the weak handle under test.
    private func mountedEditor() -> (NSWindow, InkTextView) {
        let card = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        let textView = InkTextView(frame: card)
        window.contentView?.addSubview(textView)
        return (window, textView)
    }

    // MARK: Which editor may take the keys

    func testAnEditorInsideAWindowIsTheOneToFocus() {
        let (window, textView) = mountedEditor()
        XCTAssertNotNil(window.contentView)
        XCTAssertTrue(PageModel.mountedEditor(textView) === textView)
    }

    func testAnEditorTornOutOfItsWindowIsRefused() {
        let (_, textView) = mountedEditor()
        textView.removeFromSuperview()

        XCTAssertNil(
            PageModel.mountedEditor(textView),
            """
            a torn-down editor answers the model's weak handle until ARC lets go of it; \
            focusing it would put the keyboard nowhere and stop the poll waiting for the \
            editor that is actually coming
            """
        )
    }

    func testNoEditorAtAllIsRefused() {
        XCTAssertNil(PageModel.mountedEditor(nil))
    }

    // MARK: Retiring the handle when the mount goes

    func testDismantlingTheEditorRetiresTheModelsHandle() throws {
        let model = try makeModel()
        let textView = InkTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        let scroll = InkEditorView.scrollStack(for: textView)
        let coordinator = InkEditorView.Coordinator(model: model)
        model.mountEditor(textView, from: .panel)

        InkEditorView.dismantleNSView(scroll, coordinator: coordinator)

        XCTAssertNil(
            model.activeEditor,
            "the mount is gone, so the model must not offer it to the next hand-off"
        )
    }

    func testDismantlingAnEditorAlreadyReplacedLeavesTheLiveOneAlone() throws {
        let model = try makeModel()
        let outgoing = InkTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        let scroll = InkEditorView.scrollStack(for: outgoing)
        let coordinator = InkEditorView.Coordinator(model: model)
        // SwiftUI is free to build the replacement before dismantling
        // what it replaces, in which case the handle already names the
        // new editor and the teardown has nothing to retire.
        let incoming = InkTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        model.mountEditor(incoming, from: .panel)

        InkEditorView.dismantleNSView(scroll, coordinator: coordinator)

        XCTAssertTrue(
            model.activeEditor === incoming,
            "the live editor's handle was thrown away with the dead one's"
        )
    }

    // MARK: The order of a hand off between windows (ADR-0033, issue #198)

    /// A page mounted the way a window mounts it, in a window of its
    /// own so the geometry is real.
    @MainActor
    private struct Mount {
        let window: NSWindow
        let scroll: NSScrollView
        let coordinator: InkEditorView.Coordinator
        var textView: InkTextView? { scroll.documentView as? InkTextView }
    }

    private func mount(
        _ page: UInt64, of model: PageModel, in surface: PresentationOwner
    ) -> Mount {
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = surface
        let scroll = InkEditorView.makePage(
            model: model, sheetID: page, readOnly: false, coordinator: coordinator
        )
        let card = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        return Mount(window: window, scroll: scroll, coordinator: coordinator)
    }

    func testATransferTakesTheOutgoingEditorOffThePageBeforeTheOwnerMoves() throws {
        let model = try makeModel()
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let panel = mount(page, of: model, in: .panel)
        let editor = try XCTUnwrap(panel.textView)
        let storage = model.storage(for: page)
        XCTAssertEqual(storage.layoutManagers.count, 1)

        model.transferOwnership(to: .editorWindow)

        // Nothing has mounted in the other window and SwiftUI has not
        // dismantled this one. The page is already free of it, which
        // is the order said out loud: no later callback does this.
        XCTAssertEqual(
            storage.layoutManagers.count, 0,
            "the page changed hands with the outgoing window's editor still laying it out"
        )
        XCTAssertNil(storage.delegate, "the outgoing coordinator would still emit ops for this page")
        XCTAssertNil(panel.coordinator.currentSheet)
        XCTAssertFalse(editor.textStorage === storage)
        XCTAssertFalse(editor.isEditable, "an editor on no page accepts no typing")
        XCTAssertNil(model.activeEditor)
    }

    func testTheIncomingMountFindsNothingOfTheOtherWindowsToShed() throws {
        let model = try makeModel()
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let panel = mount(page, of: model, in: .panel)
        let storage = model.storage(for: page)

        model.transferOwnership(to: .editorWindow)
        let window = mount(page, of: model, in: .editorWindow)
        // SwiftUI takes the old mount down after the new one is built,
        // which is the order that used to decide who held the page.
        InkEditorView.dismantleNSView(panel.scroll, coordinator: panel.coordinator)

        let incoming = try XCTUnwrap(window.textView)
        XCTAssertEqual(storage.layoutManagers.count, 1)
        XCTAssertTrue(storage.layoutManagers.first === incoming.layoutManager)
        XCTAssertTrue(storage.delegate === window.coordinator)
        XCTAssertTrue(
            model.activeEditor === incoming,
            "the late dismantle retired the live editor's handle"
        )
    }

    func testAMountThatOutlivedTheHandOffGoesBackOnItsPageWhenOwnershipReturns() throws {
        let model = try makeModel()
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let panel = mount(page, of: model, in: .panel)
        let editor = try XCTUnwrap(panel.textView)
        editor.insertText(
            "a line the caret stands inside", replacementRange: NSRange(location: 0, length: 0)
        )
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        let storage = model.storage(for: page)

        // There and back inside one turn: no SwiftUI pass ran, so the
        // panel's mount was never taken down and nothing else mounted.
        model.transferOwnership(to: .editorWindow)
        model.transferOwnership(to: .panel)
        InkEditorView.updatePage(
            panel.scroll, model: model, sheetID: page, readOnly: false,
            coordinator: panel.coordinator
        )

        XCTAssertTrue(editor.textStorage === storage, "the editor is still standing on nothing")
        XCTAssertEqual(storage.layoutManagers.count, 1)
        XCTAssertTrue(storage.delegate === panel.coordinator)
        XCTAssertEqual(panel.coordinator.currentSheet, page)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 0))
        XCTAssertTrue(editor.isEditable, "the pass re-gates the editing the hand off refused")
        XCTAssertTrue(model.activeEditor === editor)
        XCTAssertNotNil(model.performSealedPaste)
    }

    func testAPassInTheWindowThatNoLongerOwnsTouchesNothing() throws {
        let model = try makeModel()
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let panel = mount(page, of: model, in: .panel)
        let storage = model.storage(for: page)
        model.transferOwnership(to: .editorWindow)
        let window = mount(page, of: model, in: .editorWindow)
        let owners = try XCTUnwrap(window.textView)

        // The panel's mount is still standing and SwiftUI runs a pass
        // over it, as it does on every published change.
        InkEditorView.updatePage(
            panel.scroll, model: model, sheetID: page, readOnly: false,
            coordinator: panel.coordinator
        )

        XCTAssertEqual(storage.layoutManagers.count, 1)
        XCTAssertTrue(storage.layoutManagers.first === owners.layoutManager)
        XCTAssertTrue(model.activeEditor === owners)
        XCTAssertNil(panel.coordinator.currentSheet)
    }

    func testARollThatOutlivedTheHandOffPutsItsEditorBackToo() throws {
        let model = try makeModel()
        model.showsTimeUnits = true
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let coordinator = InkEditorView.Coordinator(model: model)
        let roll = DayScrollView.makeRoll(model: model, coordinator: coordinator, emptyHint: "")
        let card = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(roll)
        roll.frame = card
        roll.layoutSubtreeIfNeeded()
        DayScrollView.updateRoll(roll, model: model, readOnly: false, coordinator: coordinator)
        let stack = try XCTUnwrap(roll.documentView as? DayStackView)
        let editor = try XCTUnwrap(stack.editor)
        editor.insertText("a day's page", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 5, length: 2))
        let storage = model.storage(for: page)

        model.transferOwnership(to: .editorWindow)
        XCTAssertEqual(storage.layoutManagers.count, 0)
        XCTAssertFalse(model.rollGeometry.holdsClaim(stack))

        model.transferOwnership(to: .panel)
        DayScrollView.updateRoll(roll, model: model, readOnly: false, coordinator: coordinator)

        XCTAssertTrue(stack.editor === editor, "the roll built a second editor")
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertEqual(storage.layoutManagers.count, 1)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 2))
        XCTAssertTrue(model.activeEditor === editor)
        XCTAssertTrue(model.rollGeometry.holdsClaim(stack))
        XCTAssertNotNil(model.onAnchorToday)
    }
}
