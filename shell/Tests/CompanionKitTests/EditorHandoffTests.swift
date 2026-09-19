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
        _ page: UInt64, of model: PageModel, in surface: PresentationOwner,
        width: CGFloat = 420, height: CGFloat = 320
    ) -> Mount {
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = surface
        let scroll = InkEditorView.makePage(
            model: model, sheetID: page, readOnly: false, coordinator: coordinator
        )
        let card = NSRect(x: 0, y: 0, width: width, height: height)
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

    // MARK: The page's place across a hand off and back

    /// The scroll restore lands one main queue hop after it is asked
    /// for, so the test waits behind it on the same queue
    /// (`drainMainQueue`). By order and never by the clock: a fixed
    /// stretch of the run loop was spent on other tests' timers about
    /// one full run in three, and the restore had not landed.
    private func pump() {
        drainMainQueue()
    }

    /// Paragraphs long enough to wrap, so the two windows lay the page
    /// out in different numbers of lines (`PageViewStateTests`).
    private func wrappingText() -> String {
        (0..<40).map { paragraph in
            "paragraph \(paragraph) " + (0..<45).map { "word\($0)" }.joined(separator: " ") + "\n"
        }.joined()
    }

    /// The characters of the line standing at the top of the clip, and
    /// where that line's top edge is in the document view.
    private func topLine(of mount: Mount) throws -> (characters: NSRange, minY: CGFloat) {
        let textView = try XCTUnwrap(mount.textView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let top = mount.scroll.contentView.bounds.origin.y - origin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: top + 0.5), in: container)
        var glyphs = NSRange(location: 0, length: 0)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        return (
            layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil),
            rect.minY + origin.y
        )
    }

    /// The mount going away, as SwiftUI takes it down.
    private func dismantle(_ mount: Mount) {
        mount.scroll.removeFromSuperview()
        InkEditorView.dismantleNSView(mount.scroll, coordinator: mount.coordinator)
    }

    /// The panel is card sized and the editor window is wider, so the
    /// trip is made at two measures, and the late dismantle is the
    /// order that used to lose the place: the incoming mount shed the
    /// outgoing editor before it had been asked where it was.
    func testTheCaretAndTheLineBeingReadSurviveThePanelToTheEditorWindowAndBack() throws {
        let model = try makeModel()
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let panel = mount(page, of: model, in: .panel, width: 320, height: 160)
        pump()
        let panelEditor = try XCTUnwrap(panel.textView)
        let text = wrappingText()
        panelEditor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        let layoutManager = try XCTUnwrap(panelEditor.layoutManager)
        layoutManager.ensureLayout(for: try XCTUnwrap(panelEditor.textContainer))
        panel.scroll.layoutSubtreeIfNeeded()
        let reading = (text as NSString).range(of: "paragraph 20 ").location + 200
        let line = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: reading), effectiveRange: nil
        )
        panel.scroll.contentView.scroll(
            to: NSPoint(x: 0, y: line.minY + panelEditor.textContainerOrigin.y)
        )
        panel.scroll.reflectScrolledClipView(panel.scroll.contentView)
        let readInPanel = try topLine(of: panel).characters
        let caret = NSRange(location: readInPanel.location + 5, length: 3)
        panelEditor.setSelectedRange(caret)
        let panelOffset = panel.scroll.contentView.bounds.origin.y

        // To the editor window, the old mount taken down late.
        model.transferOwnership(to: .editorWindow)
        let window = mount(page, of: model, in: .editorWindow, width: 640, height: 480)
        dismantle(panel)
        pump()

        let windowEditor = try XCTUnwrap(window.textView)
        let landedInWindow = try topLine(of: window)
        XCTAssertTrue(
            NSLocationInRange(readInPanel.location, landedInWindow.characters),
            "the editor window opened on \(landedInWindow.characters), which does not hold "
                + "character \(readInPanel.location) that the panel was reading from"
        )
        XCTAssertEqual(
            window.scroll.contentView.bounds.origin.y, landedInWindow.minY, accuracy: 0.5
        )
        XCTAssertEqual(windowEditor.selectedRange(), caret)
        XCTAssertGreaterThan(
            panelOffset - window.scroll.contentView.bounds.origin.y, 100,
            "the two measures laid this page out alike, so a distance in points would have passed"
        )

        // And back, the person having moved the caret meanwhile.
        let moved = NSRange(location: caret.location + 40, length: 0)
        windowEditor.setSelectedRange(moved)
        model.transferOwnership(to: .panel)
        let panelAgain = mount(page, of: model, in: .panel, width: 320, height: 160)
        dismantle(window)
        pump()

        let landedInPanel = try topLine(of: panelAgain)
        XCTAssertTrue(
            NSLocationInRange(landedInWindow.characters.location, landedInPanel.characters),
            "the panel came back on \(landedInPanel.characters), which does not hold the "
                + "character the editor window's top line began with"
        )
        XCTAssertEqual(
            panelAgain.scroll.contentView.bounds.origin.y, landedInPanel.minY, accuracy: 0.5
        )
        XCTAssertEqual(panelAgain.textView?.selectedRange(), moved)
        XCTAssertEqual(model.storage(for: page).layoutManagers.count, 1)
    }
}
