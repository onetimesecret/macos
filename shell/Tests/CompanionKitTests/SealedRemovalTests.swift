import AppKit
import XCTest

@testable import CompanionKit

/// Law 0001's backspace rows (D-30, ADR-0046 point 1): the first press beside
/// an object selects it, the second detaches it, and the removal line's Undo
/// stands the same object again, against the live core, for every deletion.
@MainActor
final class SealedRemovalTests: XCTestCase {
    private struct Page {
        let model: PageModel
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let field: NSTextField
        let window: NSWindow
        let sheet: UInt64
        let chips: [UInt64]
    }

    /// Where a page's two objects stand.
    private enum Layout {
        /// `ab <SECRET> cd <TOKEN> ef`, objects at 3 and 8.
        case apart
        /// `ab <SECRET><TOKEN> ef`, objects at 3 and 4.
        case adjacent
        /// `<SECRET> cd <TOKEN> ef`, objects at 0 and 5.
        case leading

        var text: String {
            switch self {
            case .apart: "ab SECRET cd TOKEN ef"
            case .adjacent: "ab SECRETTOKEN ef"
            case .leading: "SECRET cd TOKEN ef"
            }
        }

        /// Each seal's range, in the text the seals before it left.
        var seals: [NSRange] {
            switch self {
            case .apart: [NSRange(location: 3, length: 6), NSRange(location: 8, length: 5)]
            case .adjacent: [NSRange(location: 3, length: 6), NSRange(location: 4, length: 5)]
            case .leading: [NSRange(location: 0, length: 6), NSRange(location: 5, length: 5)]
            }
        }
    }

    /// `layout`'s page and `tail`, the page holding the keys.
    private func makePage(tail: String = "", layout: Layout = .apart) throws -> Page {
        let suite = "companion-sealed-removal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-sealed-removal-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = CompanionClient.ephemeral(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        let model = PageModel(
            formFactor: .backdrop, defaults: defaults,
            seams: .init(
                stateDirectory: directory, client: client,
                clearClipboardIfOurs: { false }, ambientPasteboard: pasteboard))
        model.newPage()
        let sheet = try XCTUnwrap(model.selectedPageID)
        let blank = try mount(model, sheet, chips: [])
        let (coordinator, textView) = (blank.coordinator, blank.textView)
        let seals = layout.seals
        textView.insertText(
            layout.text + tail, replacementRange: NSRange(location: NSNotFound, length: 0))
        for seal in seals {
            textView.setSelectedRange(seal)
            coordinator.sealSelectionOrLine()
        }
        textView.layout()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let chips = try seals.map {
            try XCTUnwrap(coordinator.chipAttachment(at: $0.location)?.info.chipId)
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        drainMainQueue()
        model.notice = nil
        return Page(
            model: model, coordinator: coordinator, textView: textView, field: blank.field,
            window: blank.window, sheet: sheet, chips: chips)
    }

    /// A surface over `sheet` in a window of its own, a field beside it, the surface holding the keys.
    private func mount(_ model: PageModel, _ sheet: UInt64, chips: [UInt64]) throws -> Page {
        let coordinator = InkEditorView.Coordinator(model: model)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: sheet, coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentLayoutRect)
        let scroll = InkEditorView.bareScroller()
        scroll.frame = NSRect(x: 0, y: 40, width: 520, height: 360)
        InkEditorView.seat(textView, in: scroll)
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 200, height: 24))
        content.addSubview(scroll)
        content.addSubview(field)
        window.contentView = content
        textView.isEditable = true
        textView.layout()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        XCTAssertTrue(window.makeFirstResponder(textView))
        return Page(
            model: model, coordinator: coordinator, textView: textView, field: field,
            window: window, sheet: sheet, chips: chips)
    }

    private func chips(_ page: Page) -> [UInt64] { chips(page.model, page.sheet) }

    private func chips(_ model: PageModel, _ sheet: UInt64) -> [UInt64] {
        model.coreClient.documentRuns(sheet: sheet).compactMap {
            if case .chip(let chip) = $0 { chip.chipId } else { nil }
        }
    }

    private func length(_ page: Page) -> Int? { page.textView.textStorage?.length }

    private static let noReplacement = NSRange(location: NSNotFound, length: 0)

    /// The line said a removal, with the Undo beside it.
    private func assertRemovalLine(
        _ page: Page, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(page.model.notice, PageModel.removedLine, message, file: file, line: line)
        XCTAssertEqual(page.model.noticeAction?.label, "Undo", message, file: file, line: line)
    }

    /// Two presses take the first object: the caret after it, then its selection.
    private func removeFirstObject(_ page: Page) {
        page.textView.setSelectedRange(NSRange(location: 4, length: 0))
        page.textView.deleteBackward(nil)
        page.textView.deleteBackward(nil)
    }

    // MARK: Two presses

    /// A backspace after an object selects it whole and removes nothing; the
    /// second removes it, and the line says so with Undo beside it (D-30).
    func testTheFirstBackspaceBesideAnObjectSelectsItAndTheSecondRemovesIt() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 4, length: 0))

        page.textView.deleteBackward(nil)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 3, length: 1))
        XCTAssertEqual(chips(page), page.chips, "the first press removed the object")
        XCTAssertEqual(length(page), 12)
        XCTAssertNil(page.model.notice, "the first press said something")

        page.textView.deleteBackward(nil)
        XCTAssertEqual(chips(page), [page.chips[1]])
        XCTAssertEqual(length(page), 11)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(page.model.notice, PageModel.removedLine)
        XCTAssertEqual(page.model.noticeAction?.label, "Undo")
    }

    /// A forward delete before an object follows the same two presses.
    func testTheFirstForwardDeleteBeforeAnObjectSelectsItAndTheSecondRemovesIt() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 8, length: 0))

        page.textView.deleteForward(nil)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 8, length: 1))
        XCTAssertEqual(chips(page), page.chips)

        page.textView.deleteForward(nil)
        XCTAssertEqual(chips(page), [page.chips[0]])
        XCTAssertEqual(page.model.notice, PageModel.removedLine)
        XCTAssertEqual(page.model.noticeAction?.label, "Undo")
    }

    /// Beside ink a press deletes one character, as it always did, and says nothing.
    func testAPressBesideInkDeletesOneCharacter() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 3, length: 0))
        page.textView.deleteBackward(nil)
        XCTAssertEqual(page.textView.string.prefix(2), "ab")
        XCTAssertEqual(length(page), 11)
        page.textView.setSelectedRange(NSRange(location: 3, length: 0))
        page.textView.deleteForward(nil)
        XCTAssertEqual(length(page), 10)
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertNil(page.model.notice)
    }

    /// ⌃T beside an object moves it a place and keeps it, so no line says a removal.
    func testATransposeBesideAnObjectKeepsItAndSaysNothing() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 4, length: 0))
        page.textView.transpose(nil)
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertEqual(page.coordinator.chipAttachment(at: 4)?.info.chipId, page.chips[0])
        XCTAssertNil(page.model.notice)
    }

    // MARK: Rewrites of the selection

    /// Both objects stand in the core and in the editor, each U+FFFC carrying its own, and
    /// nothing said a removal.
    private func assertObjectsStand(_ page: Page, _ message: String, line: UInt = #line) throws {
        XCTAssertEqual(chips(page), page.chips, message, line: line)
        let text = page.textView.string as NSString
        let faces = (0..<text.length).filter { text.character(at: $0) == 0xFFFC }
            .map { page.coordinator.chipAttachment(at: $0)?.info.chipId }
        XCTAssertEqual(faces, page.chips.map { Optional($0) }, message, line: line)
        XCTAssertNotEqual(page.model.notice, PageModel.removedLine, message, line: line)
        try assertParity(page, message, line: line)
    }

    /// Make Upper Case, Make Lower Case and Capitalize over a selection holding objects
    /// rewrite its ink and leave every object standing, the selection kept, each one
    /// step that one Undo takes back whole (D-30).
    func testATransformationOverObjectsRewritesTheInkAsOneStep() throws {
        let page = try makePage()
        let whole = NSRange(location: 0, length: 12)
        let ways: [(name: String, run: (NSTextView) -> Void, ink: String)] = [
            ("Make Upper Case", { $0.uppercaseWord(nil) }, "AB  CD  EF"),
            ("Make Lower Case", { $0.lowercaseWord(nil) }, "ab  cd  ef"),
            ("Capitalize", { $0.capitalizeWord(nil) }, "Ab  Cd  Ef"),
        ]
        var inks = [coreInk(page)]
        for way in ways {
            page.textView.setSelectedRange(whole)

            way.run(page.textView)

            XCTAssertEqual(coreInk(page), way.ink, way.name)
            try assertObjectsStand(page, way.name)
            XCTAssertNil(page.model.notice, way.name)
            XCTAssertEqual(page.textView.selectedRange(), whole, "\(way.name) moved the selection")
            inks.append(way.ink)
        }
        for ink in inks.dropLast().reversed() {
            page.coordinator.step(back: true)
            XCTAssertEqual(coreInk(page), ink, "one Undo took more or less than one transformation")
            try assertObjectsStand(page, "after Undo")
        }
    }

    /// A transformation from an object on, and at a caret before or after one, where
    /// AppKit picks the range, rewrites ink alone and the object stands.
    func testATransformationBesideAnObjectKeepsIt() throws {
        let ways: [(name: String, selection: NSRange, ink: String?)] = [
            ("from an object", NSRange(location: 3, length: 4), "ab  CD  ef"),
            ("at a caret before one", NSRange(location: 3, length: 0), nil),
            ("at a caret after one", NSRange(location: 4, length: 0), nil),
        ]
        for way in ways {
            let page = try makePage()
            page.textView.setSelectedRange(way.selection)

            page.textView.uppercaseWord(nil)

            if let ink = way.ink { XCTAssertEqual(coreInk(page), ink, way.name) }
            try assertObjectsStand(page, way.name)
            XCTAssertNil(page.model.notice, way.name)
        }
    }

    /// Substitutions' replace actions over a selection holding objects leave every object
    /// standing, and what one replaces in the ink on both sides of them is one step.
    func testAReplaceInSelectionOverObjectsKeepsThemAsOneStep() throws {
        try SpellCheckerOnTheRunner.requireDashReplacement()
        let page = try makePage(tail: " a -- b")
        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        page.textView.insertText("x -- y ", replacementRange: Self.noReplacement)
        let before = coreInk(page)
        page.textView.setSelectedRange(NSRange(location: 0, length: page.textView.string.utf16.count))

        page.textView.perform(Selector(("replaceDashesInSelection:")), with: nil)

        XCTAssertFalse(coreInk(page).contains("--"), "a dash was left: \(coreInk(page))")
        try assertObjectsStand(page, "Replace Dashes")
        page.coordinator.step(back: true)
        XCTAssertEqual(coreInk(page), before, "one Undo took more or less than the replace")
        try assertObjectsStand(page, "after Undo")
    }

    /// The spelling panel's Change replaces the selection with one word, so over a selection
    /// holding an object it is refused with the line; over ink it changes it.
    func testASpellingChangeOverAnObjectIsRefusedWithTheLine() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 1, length: 4))

        page.textView.changeSpelling(NSTextField(string: "x"))

        XCTAssertEqual(page.model.notice, PageModel.rewriteRefusedLine)
        XCTAssertEqual(coreInk(page), "ab  cd  ef")
        try assertObjectsStand(page, "the refused change")

        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        page.textView.changeSpelling(NSTextField(string: "xy"))
        XCTAssertEqual(coreInk(page), "xy  cd  ef", "the control: a change over ink")
        try assertObjectsStand(page, "the change over ink")
    }

    /// A rewrite's plan keeps one U+FFFC for each object and writes no ink where none
    /// stood; any other is refused whole.
    func testARewriteThatWouldNotKeepItsObjectsHasNoPlan() {
        let foreign = { (id: UInt64) in
            InkEditorView.Coordinator.chipString(ChipInfo(
                chipId: id, kind: "text", excerpt: "", sizeLabel: "tiny", concealed: false))
        }
        let storage = NSTextStorage(string: "ab")
        storage.append(foreign(1))
        storage.append(foreign(2))
        storage.append(NSAttributedString(string: "cd"))
        let whole = NSRange(location: 0, length: storage.length)
        let plan = { (text: String) in
            InkEditorView.Coordinator.inkRewrites(storage, of: whole, as: text)?.map(\.text)
        }

        XCTAssertEqual(plan("AB\u{FFFC}\u{FFFC}CD"), ["AB", "", "CD"])
        XCTAssertNil(plan("ABCD"), "it drops the objects")
        XCTAssertNil(plan("AB\u{FFFC}CD"), "it drops one")
        XCTAssertNil(plan("AB\u{FFFC}x\u{FFFC}CD"), "it writes ink between two objects")
    }

    /// A selection of ink and an object goes in one press and offers the same Undo.
    func testASelectionHoldingAnObjectGoesInOnePressWithUndo() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 1, length: 4))
        page.textView.deleteBackward(nil)
        XCTAssertEqual(chips(page), [page.chips[1]])
        XCTAssertEqual(page.model.notice, PageModel.removedLine)

        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips, "Undo did not stand the object again")
        XCTAssertEqual(length(page), 12)
    }

    // MARK: Undo

    /// The line's Undo reattaches the removed instance, not a clone, and
    /// selects it again; the line goes with it.
    func testTheRemovalLinesUndoStandsTheSameObjectAgain() throws {
        let page = try makePage()
        removeFirstObject(page)
        XCTAssertEqual(chips(page), [page.chips[1]])

        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips, "Undo stood another object or none")
        XCTAssertEqual(page.coordinator.chipAttachment(at: 3)?.info.chipId, page.chips[0])
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 3, length: 1))
        XCTAssertNil(page.model.notice)
        XCTAssertNil(page.model.noticeAction)
    }

    /// The removal is its own step: a deletion after it is undone first, and
    /// the next ⌘Z stands the object.
    func testARemovalIsItsOwnStep() throws {
        let page = try makePage()
        removeFirstObject(page)
        page.textView.deleteBackward(nil)
        XCTAssertEqual(length(page), 10)

        page.coordinator.step(back: true)
        XCTAssertEqual(length(page), 11)
        XCTAssertEqual(chips(page), [page.chips[1]], "one ⌘Z undid the removal with the ink")
        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page), page.chips)
    }

    /// Once the page moves past the removal, by an edit or another page, the
    /// line keeps its words and loses its Undo, which would step back the wrong edit.
    func testTheUndoGoesOnceThePageMovesPastTheRemoval() throws {
        let page = try makePage()
        removeFirstObject(page)
        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        page.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(page.model.notice, PageModel.removedLine)
        XCTAssertNil(page.model.noticeAction, "an Undo that would take the typing back")

        page.coordinator.step(back: true)
        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page), page.chips)
        removeFirstObject(page)
        XCTAssertNotNil(page.model.noticeAction)
        let undo = try XCTUnwrap(page.model.noticeAction)
        page.model.newPage()
        page.coordinator.currentSheet = page.model.selectedPageID
        XCTAssertNil(page.model.noticeAction, "an Undo aimed at another page")

        undo.perform()
        XCTAssertEqual(chips(page), [page.chips[1]], "a stale Undo stepped a page back")
    }

    /// The object's menu removes through the same line and the same Undo.
    func testTheMenusRemovalOffersTheSameUndo() throws {
        let page = try makePage()
        let menu = try XCTUnwrap(page.coordinator.chipMenu(at: 8))
        let remove = try XCTUnwrap(menu.items.first { $0.title == "Remove protected content" })
        _ = (remove.target as? NSObject)?.perform(remove.action, with: remove)
        XCTAssertEqual(chips(page), [page.chips[0]])
        XCTAssertEqual(page.model.noticeAction?.label, "Undo")

        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips)
    }

    // MARK: The Undo is the model's

    /// A removal whose surface is then dismantled and let go, as a ledger round trip
    /// takes the editor down; the model, the page and its objects are what remain.
    private func removeAndTearDown(
        before removal: (PageModel) throws -> Void = { _ in }
    ) throws -> (model: PageModel, sheet: UInt64, chips: [UInt64]) {
        weak var gone: InkEditorView.Coordinator?
        let kept = try autoreleasepool { () throws -> (PageModel, UInt64, [UInt64]) in
            let page = try makePage()
            try removal(page.model)
            removeFirstObject(page)
            assertRemovalLine(page, "the removal said nothing")
            let scroll = try XCTUnwrap(page.textView.enclosingScrollView)
            InkEditorView.dismantleNSView(scroll, coordinator: page.coordinator)
            page.window.contentView = nil
            gone = page.coordinator
            return (page.model, page.sheet, page.chips)
        }
        XCTAssertNil(gone, "the surface outlived its teardown")
        return kept
    }

    /// With the surface that made the removal gone, the line's Undo still stands the
    /// same object again, in the core and in the page's storage.
    func testTheRemovalLinesUndoOutlivesItsSurface() throws {
        let (model, sheet, removed) = try removeAndTearDown()
        XCTAssertEqual(chips(model, sheet), [removed[1]])
        XCTAssertEqual(model.noticeAction?.label, "Undo", "the teardown took the Undo")

        model.performNoticeAction()
        XCTAssertEqual(chips(model, sheet), removed, "the Undo died with its surface")
        XCTAssertEqual(
            InkEditorView.Coordinator.chipIDs(
                model.storage(for: sheet), in: NSRange(location: 3, length: 1)),
            [removed[0]], "the page's storage was left without the object")
    }

    /// A surface mounted on the page after the teardown takes the Undo's step, so the
    /// object comes back selected there.
    func testTheUndoStepsThroughTheSurfaceMountedAfterTheTeardown() throws {
        let (model, sheet, removed) = try removeAndTearDown()
        let page = try mount(model, sheet, chips: removed)
        model.mountEditor(page.textView, from: .panel)

        model.performNoticeAction()
        XCTAssertEqual(chips(page), removed)
        XCTAssertEqual(page.coordinator.chipAttachment(at: 3)?.info.chipId, removed[0])
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 3, length: 1))
    }

    /// While a field beside the remounted surface holds the keys, the Undo waits and
    /// says so (Law 0007, keys row); ⌘Z on the page brings the object back once it has them.
    func testTheUndoAfterTheTeardownStandsAsideWhileAFieldHoldsTheKeys() throws {
        let (model, sheet, removed) = try removeAndTearDown()
        let page = try mount(model, sheet, chips: removed)
        model.mountEditor(page.textView, from: .panel)
        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()

        model.performNoticeAction()
        XCTAssertEqual(model.notice, PageModel.undoWaitsLine)
        XCTAssertEqual(chips(page), [removed[1]], "the Undo stepped the page under the field")

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page), removed)
    }

    /// With the page shown nowhere, the owner's editor, mounted on another page before the
    /// removal, answers for the keys: while a field beside it holds them, the Undo waits.
    func testTheUndoWithItsPageShownNowhereWaitsWhileAFieldHoldsTheKeys() throws {
        var mounted: Page?
        let (model, sheet, removed) = try removeAndTearDown { model in
            model.newPage()
            let other = try mount(model, try XCTUnwrap(model.selectedPageID), chips: [])
            model.mountEditor(other.textView, from: .panel)
            mounted = other
        }
        let other = try XCTUnwrap(mounted)
        XCTAssertNotEqual(other.sheet, sheet)
        let undo = try XCTUnwrap(model.noticeAction, "the control: the Undo stands")
        XCTAssertTrue(other.window.makeFirstResponder(other.field))
        drainMainQueue()

        undo.perform()
        XCTAssertEqual(model.notice, PageModel.undoWaitsLine)
        XCTAssertEqual(chips(model, sheet), [removed[1]], "the Undo stepped the page under the field")
    }

    /// A surface mounting another page after the teardown takes the Undo off the line, so
    /// the button never steps a page out of sight; a press kept from before steps nothing.
    func testAMountOfAnotherPageRetiresTheUndo() throws {
        var another: UInt64?
        let (model, sheet, removed) = try removeAndTearDown { model in
            model.newPage()
            another = model.selectedPageID
        }
        let undo = try XCTUnwrap(model.noticeAction)
        let other = try mount(model, try XCTUnwrap(another), chips: [])
        XCTAssertNotEqual(other.sheet, sheet)
        XCTAssertEqual(model.notice, PageModel.removedLine)
        XCTAssertNil(model.noticeAction, "an Undo over a page out of sight")

        undo.perform()
        XCTAssertEqual(chips(model, sheet), [removed[1]], "a kept Undo stepped the page out of sight")
        XCTAssertNotEqual(model.notice, PageModel.undoWaitsLine)
    }

    /// A surface showing the page read only, as a resting card remounted on it, is the one
    /// the Undo steps through, so the editability gate leaves the page as it stands.
    func testTheUndoRewritesNoPageShownReadOnly() throws {
        let (model, sheet, removed) = try removeAndTearDown()
        let resting = try mount(model, sheet, chips: removed)
        resting.textView.isEditable = false
        let shown = resting.textView.string

        model.performNoticeAction()
        XCTAssertEqual(chips(model, sheet), [removed[1]], "the Undo stepped a page shown read only")
        XCTAssertEqual(resting.textView.string, shown, "the Undo rewrote a page shown read only")

        resting.textView.isEditable = true
        resting.coordinator.step(back: true)
        XCTAssertEqual(chips(model, sheet), removed, "the control: ⌘Z once the page takes edits")
    }

    /// An edit to the page through another surface takes the first surface's Undo off
    /// the line, and a press it kept steps nothing back.
    func testAnEditThroughAnotherSurfaceRetiresTheUndo() throws {
        let page = try makePage()
        removeFirstObject(page)
        let undo = try XCTUnwrap(page.model.noticeAction)
        let other = try mount(page.model, page.sheet, chips: page.chips)
        other.textView.setSelectedRange(NSRange(location: 0, length: 0))
        other.textView.insertText("x", replacementRange: Self.noReplacement)
        XCTAssertEqual(length(other), 12)
        XCTAssertEqual(page.model.notice, PageModel.removedLine)
        XCTAssertNil(page.model.noticeAction, "an Undo that would take the other surface's typing back")

        undo.perform()
        XCTAssertEqual(length(other), 12, "a kept Undo stepped the typing back")
        XCTAssertEqual(chips(page), [page.chips[1]])
    }

    /// ⌘Z after the removal is a step sent past it, so a kept press cannot step further back.
    func testAStepAfterTheRemovalRetiresTheLinesUndo() throws {
        let page = try makePage()
        removeFirstObject(page)
        let undo = try XCTUnwrap(page.model.noticeAction)
        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertNil(page.model.noticeAction, "an Undo that would step back past the removal")

        undo.perform()
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertEqual(length(page), 12, "a kept Undo stepped back past the removal")
    }

    /// A page that goes with no word of its own, as a sweep takes it, takes its removal's Undo along.
    func testTheUndoGoesWithItsPage() throws {
        let page = try makePage()
        removeFirstObject(page)
        let undo = try XCTUnwrap(page.model.noticeAction)
        _ = page.model.coreClient.closeTab(id: try XCTUnwrap(page.model.selection))
        page.model.refresh()
        XCTAssertEqual(page.model.notice, PageModel.removedLine)
        XCTAssertNil(page.model.noticeAction, "an Undo over a page that is gone")
        undo.perform()
        XCTAssertNotEqual(page.model.notice, PageModel.undoWaitsLine)
    }

    // MARK: Every deletion

    /// Each caret command whose first character in its direction is an object selects it
    /// and removes nothing; its second press removes it with the line (D-30).
    func testEveryCaretDeletionBesideAnObjectSelectsItFirst() throws {
        let presses: [(String, Int, NSRange, (InkTextView) -> Void)] = [
            ("⌥⌫", 4, NSRange(location: 3, length: 1), { $0.deleteWordBackward(nil) }),
            ("⌥⌦", 8, NSRange(location: 8, length: 1), { $0.deleteWordForward(nil) }),
            ("⌃⌫", 4, NSRange(location: 3, length: 1), {
                $0.deleteBackwardByDecomposingPreviousCharacter(nil)
            }),
            ("⌘⌫", 4, NSRange(location: 3, length: 1), { $0.deleteToBeginningOfLine(nil) }),
            ("to the paragraph's start", 4, NSRange(location: 3, length: 1), {
                $0.deleteToBeginningOfParagraph(nil)
            }),
            ("to the line's end", 3, NSRange(location: 3, length: 1), { $0.deleteToEndOfLine(nil) }),
            ("⌃K", 3, NSRange(location: 3, length: 1), { $0.deleteToEndOfParagraph(nil) }),
        ]
        for (name, caret, object, press) in presses {
            let page = try makePage()
            page.textView.setSelectedRange(NSRange(location: caret, length: 0))
            press(page.textView)
            XCTAssertEqual(page.textView.selectedRange(), object, name)
            XCTAssertEqual(chips(page), page.chips, "\(name): the first press removed the object")
            XCTAssertEqual(length(page), 12, name)
            XCTAssertNil(page.model.notice, "\(name): the first press said something")

            press(page.textView)
            XCTAssertEqual(chips(page).count, 1, name)
            XCTAssertEqual(length(page), 11, "\(name): the second press took more than the object")
            assertRemovalLine(page, name)
        }
    }

    /// A caret command whose reach runs past ink to an object takes it in that press,
    /// with the line, and the line's Undo stands every object it took again.
    func testADeletionReachingPastInkTakesItsObjectsWithTheLine() throws {
        let presses: [(String, Int, (InkTextView) -> Void)] = [
            ("⌥⌫ over a space", 5, { $0.deleteWordBackward(nil) }),
            ("⌥⌦ over a space", 7, { $0.deleteWordForward(nil) }),
            ("⌃K over the paragraph", 0, { $0.deleteToEndOfParagraph(nil) }),
            ("to the paragraph's start", 12, { $0.deleteToBeginningOfParagraph(nil) }),
            ("to the mark", 12, { $0.deleteToMark(nil) }),
        ]
        for (name, caret, press) in presses {
            let page = try makePage()
            page.textView.setMark(nil)
            page.textView.setSelectedRange(NSRange(location: caret, length: 0))
            press(page.textView)
            XCTAssertLessThan(chips(page).count, 2, "\(name) took no object")
            assertRemovalLine(page, name)

            page.model.performNoticeAction()
            XCTAssertEqual(chips(page), page.chips, "\(name): the Undo did not stand them again")
            XCTAssertEqual(length(page), 12, name)
        }
    }

    /// A removal that follows a deletion run is a step of its own: the line's Undo stands
    /// the objects and leaves the ink deleted before, which the next ⌘Z brings back.
    func testARemovalByReachIsItsOwnStepAfterADeletionRun() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 12, length: 0))
        page.textView.deleteBackward(nil)
        XCTAssertNil(page.model.notice)
        page.textView.deleteToBeginningOfParagraph(nil)
        XCTAssertEqual(chips(page), [])
        XCTAssertEqual(length(page), 0)
        assertRemovalLine(page, "a paragraph's deletion")

        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertEqual(length(page), 11, "one Undo took the removal and the ink before it")
        page.coordinator.step(back: true)
        XCTAssertEqual(length(page), 12)
    }

    /// Edit > Delete takes a selected object with the line; at a caret it takes nothing.
    func testEditDeleteTakesASelectedObjectWithTheLine() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 4, length: 0))
        page.textView.delete(nil)
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertEqual(length(page), 12)
        XCTAssertNil(page.model.notice)

        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        page.textView.delete(nil)
        XCTAssertEqual(chips(page), [page.chips[1]])
        assertRemovalLine(page, "Edit > Delete")
        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips)
    }

    /// ⌃Y over a selected object writes the kill buffer there and takes the object with the line.
    func testAYankOverASelectedObjectTakesItWithTheLine() throws {
        let page = try makePage(tail: "\nxy")
        page.textView.setSelectedRange(NSRange(location: 13, length: 0))
        page.textView.deleteToEndOfParagraph(nil)
        XCTAssertEqual(length(page), 13)
        XCTAssertNil(page.model.notice, "killing ink said something")

        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        page.textView.yank(nil)
        XCTAssertEqual(chips(page), [page.chips[1]])
        XCTAssertEqual(page.textView.string.prefix(6), "ab xy ")
        assertRemovalLine(page, "⌃Y")
        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertEqual(length(page), 13)
    }

    /// Typing or Return over a selected object takes it as one step with the line; the
    /// line's Undo stands it again and takes the letter back, not the typing before it.
    func testTypingOverASelectedObjectTakesItAsOneStepWithTheLine() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 12, length: 0))
        page.textView.insertText("zz", replacementRange: Self.noReplacement)
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        page.textView.insertText("x", replacementRange: Self.noReplacement)
        XCTAssertEqual(chips(page), [page.chips[1]])
        XCTAssertEqual(page.textView.string.prefix(4), "ab x")
        assertRemovalLine(page, "typing")

        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertEqual(length(page), 14, "the Undo took the typing before the removal")

        page.textView.setSelectedRange(NSRange(location: 8, length: 1))
        page.textView.insertNewline(nil)
        XCTAssertEqual(chips(page), [page.chips[0]])
        assertRemovalLine(page, "Return")
    }

    /// A composition over a selected object takes it once the composition ends, committed
    /// or abandoned, and the line comes then rather than while it is marked.
    func testACompositionOverASelectedObjectTakesItWithTheLineWhenItEnds() throws {
        for commits in [true, false] {
            let page = try makePage()
            page.textView.setSelectedRange(NSRange(location: 3, length: 1))
            page.textView.setMarkedText(
                "ka", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: Self.noReplacement)
            XCTAssertNil(page.model.notice, "the line came while the composition was marked")
            if commits {
                page.textView.insertText("\u{304B}", replacementRange: Self.noReplacement)
            } else {
                page.textView.setMarkedText(
                    "", selectedRange: NSRange(location: 0, length: 0),
                    replacementRange: Self.noReplacement)
                page.textView.unmarkText()
            }
            XCTAssertEqual(chips(page), [page.chips[1]], "commits: \(commits)")
            assertRemovalLine(page, "commits: \(commits)")
            page.model.performNoticeAction()
            XCTAssertEqual(chips(page), page.chips, "commits: \(commits)")
        }
    }

    /// The ink the core holds for `page`, its runs joined, objects left out.
    private func coreInk(_ page: Page) -> String {
        page.model.coreClient.documentRuns(sheet: page.sheet).reduce(into: "") {
            if case .ink(let text) = $1 { $0 += text }
        }
    }

    /// ⌃K over objects then ⌃Y brings back their paragraph's ink alone: AppKit's kill
    /// buffer holds U+FFFC as a character, and no page takes it as ink (Law 0001).
    func testAYankOfKilledObjectsLandsTheirInkWithoutTheObjectCharacter() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        page.textView.deleteToEndOfParagraph(nil)
        XCTAssertEqual(chips(page), [], "the control: ⌃K took the objects")
        XCTAssertEqual(length(page), 0)
        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        page.textView.yank(nil)
        XCTAssertEqual(length(page), 0, "the yank ran while a field held the keys (Law 0007, keys row)")
        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        drainMainQueue()

        page.textView.yank(nil)

        XCTAssertEqual(page.textView.string, "ab  cd  ef")
        XCTAssertEqual(coreInk(page), "ab  cd  ef")
        XCTAssertEqual(chips(page), [], "the yank stood an object")
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 10, length: 0))
        page.coordinator.step(back: true)
        XCTAssertEqual(page.textView.string, "", "the yank was no step of its own")
    }

    /// A composition committed with U+FFFC in it lands without it, the objects kept.
    func testACommittedCompositionLandsWithoutTheObjectCharacter() throws {
        let page = try makePage()
        page.textView.setMarkedText(
            "q", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)

        page.textView.insertText("q\u{FFFC}", replacementRange: Self.noReplacement)

        XCTAssertEqual(page.textView.string.prefix(3), "qab")
        XCTAssertEqual(coreInk(page), "qab  cd  ef")
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertNotNil(page.coordinator.chipAttachment(at: 4), "an object lost its face")
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 1, length: 0))
    }

    /// A page restated with U+FFFC as ink, as one an earlier build wrote may be, drops it
    /// when a refused batch sends the page through its recovery, which the core then takes.
    func testTheRecoveryDropsAnObjectCharacterNoObjectCarries() throws {
        let page = try makePage()
        let storage = try XCTUnwrap(page.textView.textStorage)
        page.model.applyingProjection {
            storage.insert(NSAttributedString(string: "\u{FFFC}"), at: 0)
        }
        let foreign = ChipInfo(
            chipId: 4_242, kind: "text", excerpt: "", sizeLabel: "tiny", concealed: false)

        storage.insert(InkEditorView.Coordinator.chipString(foreign), at: 1)

        XCTAssertEqual(page.textView.string.prefix(3), "ab ")
        XCTAssertEqual(coreInk(page), "ab  cd  ef")
        XCTAssertEqual(chips(page), page.chips)
    }

    /// The ink the core holds for page `sheet`, its runs joined, objects left out.
    private func coreInk(_ model: PageModel, _ sheet: UInt64) -> String {
        model.coreClient.documentRuns(sheet: sheet).reduce(into: "") {
            if case .ink(let text) = $1 { $0 += text }
        }
    }

    /// A page holding U+FFFC as ink, as a peer's batch or a page an earlier build saved
    /// leaves it, loses it at the projection that mounts it, a restate and the quiet one,
    /// as an edit the core keeps and the save follows, never a step of the page's own.
    func testAPagesObjectCharacterLeavesItAtEveryProjection() throws {
        let page = try makePage()
        let (model, client) = (page.model, page.model.coreClient)

        model.newPage()
        let fresh = try XCTUnwrap(model.selectedPageID)
        XCTAssertTrue(client.applyOps(sheet: fresh, json: #"[{"ins":{"at":0,"text":"ab"}}]"#))
        XCTAssertTrue(client.inkBelowTheGuardForTests(sheet: fresh, at: 1, "\u{FFFC}"))
        XCTAssertEqual(coreInk(model, fresh), "a\u{FFFC}b", "the control: the seam stood it")
        let marks = model.dirtyMarks
        let mounted = try mount(model, fresh, chips: [])
        XCTAssertEqual(mounted.textView.string, "ab")
        XCTAssertEqual(coreInk(model, fresh), "ab")
        try assertParity(mounted, "at the mount")
        drainMainQueue()
        XCTAssertGreaterThan(model.dirtyMarks, marks, "the take out was never saved")
        mounted.coordinator.step(back: true)
        XCTAssertEqual(mounted.textView.string, "", "the typed ink was not the one step")
        XCTAssertFalse(model.canUndoEdit(sheet: fresh), "the take out was a step of its own")

        page.textView.setSelectedRange(NSRange(location: 12, length: 0))
        page.textView.insertText("z", replacementRange: Self.noReplacement)
        XCTAssertTrue(client.inkBelowTheGuardForTests(sheet: page.sheet, at: 0, "\u{FFFC}"))
        page.coordinator.step(back: true)
        XCTAssertEqual(page.textView.string, "ab \u{FFFC} cd \u{FFFC} ef")
        XCTAssertEqual(coreInk(page), "ab  cd  ef")
        XCTAssertEqual(chips(page), page.chips)
        try assertParity(page, "after the restate")

        model.newPage()
        let quiet = try XCTUnwrap(model.selectedPageID)
        XCTAssertTrue(client.inkBelowTheGuardForTests(sheet: quiet, at: 0, "x\u{FFFC}y"))
        XCTAssertEqual(model.quietRendering(for: quiet).text.string, "xy")
        XCTAssertEqual(coreInk(model, quiet), "xy")
    }

    /// A page whose storage was kept, shown again after a peer's batch left U+FFFC in it as
    /// ink, loses it at that showing, as an edit the save follows and no Undo puts back.
    func testAKeptPagesObjectCharacterLeavesItWhenItIsNextShown() throws {
        let page = try makePage()
        let (model, client) = (page.model, page.model.coreClient)
        model.newPage()
        XCTAssertTrue(client.inkBelowTheGuardForTests(sheet: page.sheet, at: 0, "\u{FFFC}"))
        XCTAssertEqual(coreInk(page), "\u{FFFC}ab  cd  ef", "the control: the seam stood it")
        let kept = try XCTUnwrap(page.textView.textStorage)
        let marks = model.dirtyMarks

        let shown = try mount(model, page.sheet, chips: page.chips)

        XCTAssertTrue(shown.textView.textStorage === kept, "the page did not keep its storage")
        XCTAssertEqual(coreInk(page), "ab  cd  ef")
        XCTAssertEqual(chips(page), page.chips)
        try assertParity(shown, "at the showing")
        drainMainQueue()
        XCTAssertGreaterThan(model.dirtyMarks, marks, "the take out was never saved")
        shown.coordinator.step(back: true)
        XCTAssertFalse(coreInk(page).contains("\u{FFFC}"), "an Undo put it back")
    }

    /// A recovery keeps an object the storage stands at two indices once, at the first,
    /// and detaches nothing.
    func testTheRecoveryKeepsAnObjectStandingTwiceOnce() throws {
        let page = try makePage()
        let storage = try XCTUnwrap(page.textView.textStorage)
        let face = try XCTUnwrap(page.coordinator.chipAttachment(at: 3))
        page.model.applyingProjection {
            storage.insert(NSAttributedString(attachment: face), at: 0)
        }
        let foreign = ChipInfo(
            chipId: 4_242, kind: "text", excerpt: "", sizeLabel: "tiny", concealed: false)

        storage.insert(InkEditorView.Coordinator.chipString(foreign), at: 1)

        XCTAssertEqual(page.textView.string, "\u{FFFC}ab  cd \u{FFFC} ef")
        XCTAssertEqual(page.coordinator.chipAttachment(at: 0)?.info.chipId, page.chips[0])
        XCTAssertEqual(chips(page), page.chips)
        try assertParity(page, "after the recovery")
    }

    /// Outside text holding U+FFFC, read as AppKit's paste, a drop and a service's answer
    /// read a board, lands without it on a page and in a note, the caret after it.
    func testOutsideTextHoldingTheObjectCharacterLandsWithoutIt() throws {
        let page = try makePage()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("x\u{FFFC}y\u{FFFC}", forType: .string)

        page.textView.setSelectedRange(NSRange(location: 12, length: 0))
        XCTAssertTrue(page.textView.readSelection(from: board, type: .string))
        XCTAssertEqual(page.textView.string.suffix(4), "efxy")
        XCTAssertEqual(coreInk(page), "ab  cd  efxy")
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 14, length: 0))
        page.coordinator.step(back: true)
        XCTAssertEqual(coreInk(page), "ab  cd  ef", "the paste was no step of its own")

        page.coordinator.beginNote(at: 3)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.textView.readSelection(from: board, type: .string))
        XCTAssertEqual(note.textView.string, "xy")
        XCTAssertEqual(page.model.noteText(chip: page.chips[0]), "xy")
        XCTAssertEqual(note.textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    /// A board's text read over a selected object, as AppKit's paste and a service's
    /// answer write it, takes the object with the line.
    func testABoardsTextReadOverASelectedObjectTakesItWithTheLine() throws {
        let page = try makePage()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("q", forType: .string)
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        XCTAssertTrue(page.textView.readSelection(from: board, type: .string))
        XCTAssertEqual(chips(page), [page.chips[1]])
        XCTAssertEqual(page.textView.string.prefix(4), "ab q")
        assertRemovalLine(page, "a board's text")
        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips)
    }

    // MARK: A board's U+FFFC beside an object (Law 0001: one position per object)

    /// Two of the ways a board's text lands; SealedDragTests drives the third, a drop.
    private enum BoardRoute: CaseIterable {
        /// ⌘V as `paste(_:)` runs it, its board read standing in for AppKit's plain paste.
        case paste
        /// A service's answer, through `NSServicesMenuRequestor`.
        case service
    }

    /// `text` read from a board of the test's own at `selection`, by `route`.
    private func read(_ text: String, over selection: NSRange, on page: Page, by route: BoardRoute) {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString(text, forType: .string)
        page.textView.setSelectedRange(selection)
        switch route {
        case .paste:
            page.textView.performOrdinaryPaste(nil, bypassingAutomaticFencing: true) { _ in
                XCTAssertTrue(page.textView.readSelection(from: board, type: .string))
            }
        case .service:
            XCTAssertTrue(page.textView.readSelection(from: board))
        }
    }

    /// The editor and the core spell the same page.
    private func assertParity(_ page: Page, _ message: String, line: UInt = #line) throws {
        let storage = try XCTUnwrap(page.textView.textStorage)
        XCTAssertNil(PageModel.parityBreach(
            editor: InkEditorView.Coordinator.runs(of: storage),
            core: page.model.coreClient.documentRuns(sheet: page.sheet)),
            message, line: line)
    }

    /// Text holding U+FFFC landing right after an object, right before one and between
    /// two takes on none of their attachments: the page reads it without the character,
    /// each object stands once, and a delete of the ink beside them detaches nothing.
    func testABoardsObjectCharacterBesideAnObjectStandsNoSecondFace() throws {
        // The page, where the text lands, the editor's text after, and the caret whose
        // backspace takes ink beside an object (the first: the review's `d` of `cd`).
        let cases: [(layout: Layout, at: Int, reads: String, delete: Int)] = [
            (.apart, 4, "ab \u{FFFC}xy cd \u{FFFC} ef", 9),
            (.apart, 3, "ab xy\u{FFFC} cd \u{FFFC} ef", 5),
            (.apart, 8, "ab \u{FFFC} cd xy\u{FFFC} ef", 10),
            (.leading, 0, "xy\u{FFFC} cd \u{FFFC} ef", 2),
            (.adjacent, 4, "ab \u{FFFC}xy\u{FFFC} ef", 6),
        ]
        for route in BoardRoute.allCases {
            for text in ["x\u{FFFC}y", "\u{FFFC}xy\u{FFFC}", "xy\u{FFFC}"] {
                for spot in cases {
                    let label = "\(route) \(text.debugDescription) at \(spot.at), \(spot.layout)"
                    let page = try makePage(layout: spot.layout)
                    read(text, over: NSRange(location: spot.at, length: 0), on: page, by: route)

                    XCTAssertEqual(page.textView.string, spot.reads, label)
                    XCTAssertEqual(chips(page), page.chips, label)
                    try assertParity(page, label)
                    XCTAssertEqual(
                        page.textView.selectedRange(), NSRange(location: spot.at + 2, length: 0), label)

                    page.textView.setSelectedRange(NSRange(location: spot.delete, length: 0))
                    page.textView.deleteBackward(nil)
                    XCTAssertEqual(chips(page), page.chips, "a delete of ink detached an object: \(label)")
                    XCTAssertNil(page.model.notice, label)
                    try assertParity(page, "after the delete: \(label)")
                }
            }
        }
    }

    /// A bare U+FFFC beside an object, which inherits it whole, lands as nothing.
    func testABoardsBareObjectCharacterBesideAnObjectLandsAsNothing() throws {
        for route in BoardRoute.allCases {
            for (layout, at) in [(Layout.apart, 4), (.apart, 3), (.adjacent, 4), (.leading, 0)] {
                let label = "\(route) at \(at), \(layout)"
                let page = try makePage(layout: layout)
                let before = page.textView.string
                read("\u{FFFC}", over: NSRange(location: at, length: 0), on: page, by: route)
                XCTAssertEqual(page.textView.string, before, label)
                XCTAssertEqual(chips(page), page.chips, label)
                try assertParity(page, label)
            }
        }
    }

    /// A board's U+FFFC over a selection that starts with an object takes the object with
    /// the line, as any other board text does, rather than standing it again.
    func testABoardsObjectCharacterOverASelectedObjectTakesItWithTheLine() throws {
        for route in BoardRoute.allCases {
            for text in ["\u{FFFC}", "q\u{FFFC}"] {
                let label = "\(route) \(text.debugDescription)"
                let page = try makePage()
                read(text, over: NSRange(location: 3, length: 1), on: page, by: route)
                XCTAssertEqual(chips(page), [page.chips[1]], label)
                try assertParity(page, label)
                assertRemovalLine(page, label)
                page.model.performNoticeAction()
                XCTAssertEqual(chips(page), page.chips, label)
                try assertParity(page, "after the Undo: \(label)")
            }
        }
    }

    /// AppKit may ask to change an object's range and then make no edit. That ask judges
    /// no later edit: once the object goes by the core's cut, typing says no removal.
    func testAnAskNoEditFollowedJudgesNoLaterEdit() throws {
        let page = try makePage()
        XCTAssertTrue(page.textView.shouldChangeText(
            in: NSRange(location: 3, length: 1), replacementString: ""))
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        guard case .cut = page.coordinator.cutSelection() else { return XCTFail("the cut refused") }
        XCTAssertEqual(chips(page), [page.chips[1]], "the control: the cut took the object")
        page.model.notice = nil

        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        page.textView.insertText("z", replacementRange: Self.noReplacement)
        XCTAssertEqual(page.textView.string.prefix(3), "zab")
        XCTAssertNotEqual(page.model.notice, PageModel.removedLine, "typing said a removal it did not make")
        XCTAssertNil(page.model.noticeAction, "an Undo that would take the typing back")

        XCTAssertTrue(page.textView.shouldChangeText(
            in: NSRange(location: 8, length: 1), replacementString: ""))
        page.textView.setSelectedRange(NSRange(location: 8, length: 1))
        page.textView.deleteBackward(nil)
        XCTAssertEqual(chips(page), [], "the control: an asked edit that lands still takes its object")
        assertRemovalLine(page, "the edit after a stale ask")
    }

    /// A fragment pasted, or the slot's cut placed, over a selected object takes that object
    /// with the line, and the line's Undo stands it again.
    func testAPasteOrPlaceOverASelectedObjectTakesItWithTheLine() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 8, length: 1))
        XCTAssertTrue(page.coordinator.copySelection())
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        XCTAssertTrue(page.coordinator.pasteFragment(), "left to AppKit's paste")
        XCTAssertFalse(chips(page).contains(page.chips[0]))
        assertRemovalLine(page, "a fragment's paste")
        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips, "the Undo did not stand the pasted over object")

        page.textView.setSelectedRange(NSRange(location: 8, length: 1))
        guard case .cut = page.coordinator.cutSelection() else { return XCTFail("the cut refused") }
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        XCTAssertTrue(page.coordinator.placeActiveCut())
        XCTAssertEqual(chips(page), [page.chips[1]], "the place kept the object it stood over")
        assertRemovalLine(page, "the slot's place")
        page.model.performNoticeAction()
        XCTAssertTrue(chips(page).contains(page.chips[0]))
    }

    // MARK: Standing aside

    /// While a field or the note holds the keys, the page's backspace and
    /// forward delete select and remove nothing, and the line's Undo waits
    /// and says so; ⌘Z on the page brings the object back once it has the keys.
    func testBackspaceAndTheUndoStandAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let page = try makePage()
        removeFirstObject(page)
        XCTAssertEqual(chips(page), [page.chips[1]])
        let besideTheOther = NSRange(location: 8, length: 0)

        func standsAside(_ holder: String) {
            XCTAssertFalse(page.textView.answersChords, holder)
            page.textView.setSelectedRange(besideTheOther)
            page.textView.deleteBackward(nil)
            XCTAssertEqual(page.textView.selectedRange(), besideTheOther, holder)
            page.textView.setSelectedRange(NSRange(location: 7, length: 1))
            page.textView.deleteBackward(nil)
            page.textView.setSelectedRange(NSRange(location: 7, length: 0))
            page.textView.deleteForward(nil)
            XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 7, length: 0), holder)
            XCTAssertEqual(chips(page), [page.chips[1]], holder)
            XCTAssertEqual(length(page), 11, holder)
        }

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        page.model.performNoticeAction()
        XCTAssertEqual(page.model.notice, PageModel.undoWaitsLine)
        XCTAssertEqual(chips(page), [page.chips[1]], "the Undo stepped the page under the field")
        standsAside("field")

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        page.coordinator.beginNote(at: 7)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        standsAside("note")

        note.escape()
        drainMainQueue()
        XCTAssertTrue(page.window.firstResponder === page.textView)
        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page), page.chips, "the removal did not come back")
    }

    /// While a field or the note holds the keys, no other deletion, ⌃Y, typing over a
    /// selected object or rewrite of the selection changes anything on the page (Law 0007, keys row).
    func testEveryDeletionYankTypingAndRewriteStandAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let page = try makePage(tail: "\nxy")
        page.textView.setSelectedRange(NSRange(location: 13, length: 0))
        page.textView.deleteToEndOfParagraph(nil) // the kill buffer holds `xy` for ⌃Y
        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        page.textView.setMark(nil)
        let object = NSRange(location: 3, length: 1)
        let presses: [(String, NSRange, (InkTextView) -> Void)] = [
            ("⌥⌫", NSRange(location: 4, length: 0), { $0.deleteWordBackward(nil) }),
            ("⌥⌫ over a space", NSRange(location: 5, length: 0), { $0.deleteWordBackward(nil) }),
            ("⌥⌦", NSRange(location: 8, length: 0), { $0.deleteWordForward(nil) }),
            ("⌃⌫", NSRange(location: 4, length: 0), {
                $0.deleteBackwardByDecomposingPreviousCharacter(nil)
            }),
            ("⌘⌫", NSRange(location: 4, length: 0), { $0.deleteToBeginningOfLine(nil) }),
            ("to the paragraph's start", NSRange(location: 12, length: 0), {
                $0.deleteToBeginningOfParagraph(nil)
            }),
            ("to the line's end", NSRange(location: 3, length: 0), { $0.deleteToEndOfLine(nil) }),
            ("⌃K", NSRange(location: 0, length: 0), { $0.deleteToEndOfParagraph(nil) }),
            ("to the mark", NSRange(location: 12, length: 0), { $0.deleteToMark(nil) }),
            ("Edit > Delete", object, { $0.delete(nil) }),
            ("⌃Y", object, { $0.yank(nil) }),
            ("typing", object, { $0.insertText("x", replacementRange: Self.noReplacement) }),
            ("Make Upper Case", NSRange(location: 0, length: 12), { $0.uppercaseWord(nil) }),
            ("Make Lower Case", NSRange(location: 0, length: 12), { $0.lowercaseWord(nil) }),
            ("Capitalize", NSRange(location: 0, length: 12), { $0.capitalizeWord(nil) }),
            ("the spelling panel's Change", NSRange(location: 0, length: 2), {
                $0.changeSpelling(NSTextField(string: "xy"))
            }),
        ]
        func standsAside(_ holder: String) {
            XCTAssertFalse(page.textView.answersChords, holder)
            for (name, range, press) in presses {
                page.textView.setSelectedRange(range)
                press(page.textView)
                XCTAssertEqual(page.textView.selectedRange(), range, "\(holder): \(name)")
                XCTAssertEqual(chips(page), page.chips, "\(holder): \(name)")
                XCTAssertEqual(length(page), 13, "\(holder): \(name)")
                XCTAssertNil(page.model.notice, "\(holder): \(name)")
            }
        }

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        standsAside("field")

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        page.coordinator.beginNote(at: 3)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        standsAside("note")
        note.escape()
        drainMainQueue()
    }
}
