import AppKit
import XCTest

@testable import CompanionKit

/// A tab as a drop target (issue 254; Law 0001's drag and ⌥ drag rows): the drop is placed at
/// the end of the tab's page by the routes a drop on the page takes, driven below the
/// session AppKit runs, against the live core and on pasteboards of the test's own.
@MainActor
final class TabDropTests: XCTestCase {
    private struct Page {
        let model: PageModel
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let window: NSWindow
        let sheet: UInt64
        /// A field in the page's window, standing in for a name's (Law 0007, keys row).
        let field: NSTextField
    }

    private let placeholder = "[sealed content · tiny]"
    private let move: NSDragOperation = [.move, .copy]
    private let copy: NSDragOperation = [.copy]

    /// A model of the test's own, on `client`, whose ordinary pasteboard is a private one.
    private func makeModel(client: CompanionClient? = nil) throws -> PageModel {
        let suite = "companion-tab-drop-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-tab-drop-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = client ?? CompanionClient.ephemeral(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let ambient = NSPasteboard.withUniqueName()
        addTeardownBlock { ambient.releaseGlobally() }
        return PageModel(
            formFactor: .backdrop, defaults: defaults,
            seams: .init(
                stateDirectory: directory, client: client,
                clearClipboardIfOurs: { false }, ambientPasteboard: ambient))
    }

    /// A new page reading `text` with each of `seals` sealed, in a window of its
    /// own with the keys; `ab <SECRET> cd <TOKEN> ef` by default, twelve units.
    private func mountPage(
        on model: PageModel, text: String = "ab SECRET cd TOKEN ef",
        seals: [NSRange] = [NSRange(location: 3, length: 6), NSRange(location: 8, length: 5)]
    ) throws -> Page {
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let sheet = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: sheet, coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentLayoutRect)
        let scroll = InkEditorView.bareScroller()
        scroll.frame = NSRect(x: 0, y: 40, width: 520, height: 360)
        InkEditorView.seat(textView, in: scroll)
        content.addSubview(scroll)
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 200, height: 24))
        content.addSubview(field)
        window.contentView = content
        textView.isEditable = true
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        for seal in seals {
            textView.setSelectedRange(seal)
            coordinator.sealSelectionOrLine()
        }
        textView.layout()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        drainMainQueue()
        return Page(
            model: model, coordinator: coordinator, textView: textView, window: window,
            sheet: sheet, field: field)
    }

    /// A page nobody shows, reading `text` as ink, and its slot.
    private func unshownPage(on model: PageModel, text: String) throws -> (sheet: UInt64, slot: UInt64) {
        model.newPage()
        let sheet = try XCTUnwrap(model.selectedPageID)
        if !text.isEmpty {
            XCTAssertTrue(model.coreClient.applyOps(
                sheet: sheet, json: #"[{"ins":{"at":0,"text":"\#(text)"}}]"#))
        }
        return (sheet, try slot(of: sheet, on: model))
    }

    private func slot(of sheet: UInt64, on model: PageModel) throws -> UInt64 {
        try XCTUnwrap(model.tabs.first { $0.pageID == sheet }?.id)
    }

    private func chips(_ model: PageModel, _ sheet: UInt64) -> [ChipInfo] {
        model.coreClient.documentRuns(sheet: sheet).compactMap {
            if case .chip(let chip) = $0 { chip } else { nil }
        }
    }

    /// Ink as each run reads, with `#` where an object stands.
    private func shape(_ model: PageModel, _ sheet: UInt64) -> String {
        model.coreClient.documentRuns(sheet: sheet).map {
            switch $0 {
            case .chip: "#"
            case .ink(let text): text
            }
        }.joined()
    }

    /// Begin a drag of `range`, and its item on a board of the test's own.
    private func beginDrag(_ page: Page, _ range: NSRange) throws -> NSPasteboard {
        page.textView.setSelectedRange(range)
        guard case .fragment(let item) = page.coordinator.beginPageDrag() else {
            XCTFail("the page's drag wrote no fragment")
            throw CocoaError(.featureUnsupported)
        }
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        return board
    }

    private func inkBoard(_ text: String) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString(text, forType: .string)
        return board
    }

    /// A drag as the tab sees it, from `source` with `board` under `mask`.
    private func drag(
        from source: Any?, board: NSPasteboard, mask: NSDragOperation
    ) -> DraggingInfoStub {
        DraggingInfoStub(pasteboard: board, source: source, location: .zero, window: nil, mask: mask)
    }

    // MARK: A drag from another page

    /// A page's drag dropped on another page's tab moves its range to the end of that
    /// page's body through the core, keeping the object's identity and name, leaving the
    /// source run, recording nothing and arming a write (Law 0001, drag row).
    func testADragDroppedOnAnotherPagesTabMovesItsRangeToTheEndKeepingTheObject() throws {
        let model = try makeModel()
        let source = try mountPage(on: model)
        let ids = chips(model, source.sheet).map(\.chipId)
        XCTAssertTrue(model.setChipName("API_KEY", chip: ids[0], sheet: source.sheet))
        let (dest, slot) = try unshownPage(on: model, text: "xy")
        let target = TabDropTarget(model: model, slot: slot)
        let board = try beginDrag(source, NSRange(location: 0, length: 4))
        let drop = drag(from: source.textView, board: board, mask: move)
        let records = model.coreClient.ledger().count
        let marks = model.dirtyMarks

        XCTAssertEqual(target.dropRoute(for: drop), .move)
        XCTAssertEqual(target.draggingEntered(drop), .move)
        XCTAssertEqual(target.draggingUpdated(drop), .move)
        XCTAssertTrue(target.performDragOperation(drop))
        XCTAssertEqual(shape(model, dest), "xyab #", "the run was not placed at the end")
        XCTAssertEqual(chips(model, dest).map(\.chipId), [ids[0]], "the move took a new identity")
        XCTAssertEqual(chips(model, dest).first?.name, "API_KEY")
        XCTAssertEqual(shape(model, source.sheet), " cd # ef", "the move left its source run")
        XCTAssertEqual(source.textView.textStorage?.length, 8, "the source was not restated")
        XCTAssertEqual(source.textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(chips(model, source.sheet).map(\.chipId), [ids[1]])
        XCTAssertEqual(model.coreClient.ledger().count, records, "a move recorded something")
        XCTAssertGreaterThan(model.dirtyMarks, marks, "the move armed no write")
        XCTAssertFalse(model.hasStorage(for: dest), "the drop built a storage for a page nobody shows")
        XCTAssertFalse(model.storage(for: dest).string.contains(placeholder), "the public text was placed")

        source.coordinator.endPageDrag()
        XCTAssertEqual(shape(model, source.sheet), " cd # ef", "the session's end removed a run")
    }

    /// A drop on the tab of a page that shows restates its surface and selects the placed
    /// run, as a drop on that page does.
    func testADropOnAShowingPagesTabRestatesItsSurfaceAndSelectsTheRun() throws {
        let model = try makeModel()
        let source = try mountPage(on: model)
        let dest = try mountPage(on: model, text: "xy", seals: [])
        let target = TabDropTarget(model: model, slot: try slot(of: dest.sheet, on: model))
        let board = try beginDrag(source, NSRange(location: 0, length: 4))

        XCTAssertTrue(target.performDragOperation(drag(from: source.textView, board: board, mask: move)))
        XCTAssertEqual(shape(model, dest.sheet), "xyab #")
        XCTAssertEqual(dest.textView.textStorage?.length, 6, "the destination was not restated")
        XCTAssertNotNil(dest.coordinator.chipAttachment(at: 5), "the object's face did not stand")
        XCTAssertEqual(dest.textView.selectedRange(), NSRange(location: 2, length: 4))
    }

    /// ⌥ over another page's tab pastes the copy fragment at the end: every object cloned
    /// under a new identity, and the source keeps its run (Law 0001, ⌥ drag row).
    func testOptionOverAnotherPagesTabClonesTheRangeToTheEndAndLeavesTheSource() throws {
        let model = try makeModel()
        let source = try mountPage(on: model)
        let ids = chips(model, source.sheet).map(\.chipId)
        let (dest, slot) = try unshownPage(on: model, text: "xy")
        let target = TabDropTarget(model: model, slot: slot)
        let board = try beginDrag(source, NSRange(location: 0, length: 4))
        let drop = drag(from: source.textView, board: board, mask: copy)

        XCTAssertEqual(target.dropRoute(for: drop), .fragment)
        XCTAssertEqual(target.draggingEntered(drop), .copy)
        XCTAssertTrue(target.performDragOperation(drop))
        XCTAssertEqual(shape(model, dest), "xyab #", "the copy was not placed at the end")
        XCTAssertEqual(chips(model, dest).count, 1)
        XCTAssertFalse(model.hasStorage(for: dest), "the drop built a storage for a page nobody shows")
        XCTAssertFalse(ids.contains(try XCTUnwrap(chips(model, dest).first?.chipId)), "the clone kept the identity")
        XCTAssertEqual(shape(model, source.sheet), "ab # cd # ef", "⌥ took the source run")
        XCTAssertEqual(chips(model, source.sheet).map(\.chipId), ids)
    }

    /// The end is counted in UTF-16 units, so a drop on the tab of a page reading a surrogate
    /// pair stands the object after the pair, where the core and the surface both put it.
    func testTheEndIsCountedInUTF16UnitsPastASurrogatePair() throws {
        let standIn = DragStandIn(tag: UUID().uuidString)
        let model = try makeModel(client: standIn)
        let source = try mountPage(on: model)
        let (dest, slot) = try unshownPage(on: model, text: "x😀")
        let target = TabDropTarget(model: model, slot: slot)
        XCTAssertEqual(model.bodyLength(of: dest), 3, "the pair did not count as two units")

        XCTAssertTrue(target.performDragOperation(drag(from: nil, board: inkBoard("hunter2"), mask: copy)))
        XCTAssertEqual(standIn.drops, [[dest, 3, 0]], "the seal was not aimed past the pair")
        XCTAssertEqual(shape(model, dest), "x😀#")

        let board = try beginDrag(source, NSRange(location: 0, length: 4))
        XCTAssertTrue(target.performDragOperation(drag(from: source.textView, board: board, mask: move)))
        XCTAssertEqual(shape(model, dest), "x😀#ab #", "the move was not placed after the pair and the object")
        XCTAssertEqual(model.bodyLength(of: dest), 8)
        XCTAssertFalse(model.hasStorage(for: dest), "the drops built a storage for a page nobody shows")
    }

    // MARK: The page's own tab

    /// The page's own drag dropped on its tab moves the range to the end of its body as one
    /// step; a range already ending the body is offered no move, and ⌥ clones it there.
    func testAPagesOwnDragOnItsTabMovesTheRangeToTheEndAndOptionClonesIt() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let ids = chips(model, page.sheet).map(\.chipId)
        let target = TabDropTarget(model: model, slot: try slot(of: page.sheet, on: model))
        var board = try beginDrag(page, NSRange(location: 0, length: 4))
        var drop = drag(from: page.textView, board: board, mask: move)

        XCTAssertEqual(target.dropRoute(for: drop), .ownDrag)
        XCTAssertEqual(target.draggingEntered(drop), .move)
        XCTAssertTrue(target.performDragOperation(drop))
        XCTAssertEqual(shape(model, page.sheet), " cd # efab #", "the own drop was not a core move")
        XCTAssertEqual(chips(model, page.sheet).map(\.chipId), [ids[1], ids[0]])
        XCTAssertEqual(page.textView.textStorage?.length, 12, "the page was not restated")
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 8, length: 4))
        page.coordinator.endPageDrag()

        board = try beginDrag(page, NSRange(location: 8, length: 4))
        drop = drag(from: page.textView, board: board, mask: move)
        XCTAssertEqual(target.draggingEntered(drop), [], "a range at the end was offered a move")
        XCTAssertFalse(target.performDragOperation(drop))
        XCTAssertEqual(shape(model, page.sheet), " cd # efab #")

        drop = drag(from: page.textView, board: board, mask: copy)
        XCTAssertEqual(target.draggingEntered(drop), .copy)
        XCTAssertTrue(target.performDragOperation(drop))
        XCTAssertEqual(shape(model, page.sheet), " cd # efab #ab #", "⌥ did not clone to the end")
        XCTAssertEqual(chips(model, page.sheet).count, 3)
        page.coordinator.endPageDrag()
    }

    // MARK: A page past its deadline

    /// A tab whose page went takes no drop and offers no operation; a tab whose page is due
    /// but not yet swept refuses through the core, which settles with the expired line and
    /// changes neither page (Law 0001, expiry row).
    func testATabWhosePageIsPastItsDeadlineTakesNoDrop() throws {
        let model = try makeModel()
        let client = model.coreClient
        let source = try mountPage(on: model)
        let (dest, slot) = try unshownPage(on: model, text: "xy")
        XCTAssertTrue(client.setRung(tab: slot, rung: .oneHour))
        let target = TabDropTarget(model: model, slot: slot)
        let board = try beginDrag(source, NSRange(location: 0, length: 4))
        let drop = drag(from: source.textView, board: board, mask: move)
        XCTAssertEqual(target.dropRoute(for: drop), .move, "the control: a live page takes the move")

        XCTAssertTrue(client.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        XCTAssertTrue(model.tabs.contains { $0.pageID == dest }, "the control: the page still shows")
        XCTAssertEqual(target.draggingEntered(drop), .move, "the strip still says the page stands")
        XCTAssertFalse(target.performDragOperation(drop), "a due page took the drop")
        XCTAssertFalse(model.tabs.contains { $0.pageID == dest }, "the due page stayed")
        XCTAssertEqual(model.notice, PageModel.pageExpiredLine)
        XCTAssertEqual(shape(model, source.sheet), "ab # cd # ef", "the refused move changed the source")
        XCTAssertEqual(chips(model, source.sheet).count, 2)

        model.notice = nil
        XCTAssertNil(target.page, "a swept slot still names a page")
        XCTAssertEqual(target.dropRoute(for: drop), .refused)
        XCTAssertEqual(target.draggingEntered(drop), [])
        XCTAssertEqual(target.draggingUpdated(drop), [])
        XCTAssertFalse(target.performDragOperation(drop))
        let foreign = drag(from: nil, board: inkBoard("hunter2"), mask: copy)
        XCTAssertEqual(target.dropRoute(for: foreign), .refused, "an empty slot offered a seal")
        XCTAssertEqual(target.draggingEntered(foreign), [])
        XCTAssertNil(model.notice, "a refused drop on an empty slot said something")
        XCTAssertEqual(shape(model, source.sheet), "ab # cd # ef")
    }

    /// Another app's drag on the tab of a page due but not yet swept settles first, so the
    /// core never reads the board for it, and the expired line says why (Law 0001, expiry row).
    func testASealOnTheTabOfADuePageSettlesWithTheExpiredLine() throws {
        let standIn = DragStandIn(tag: UUID().uuidString)
        let model = try makeModel(client: standIn)
        let client = model.coreClient
        let (dest, slot) = try unshownPage(on: model, text: "xy")
        XCTAssertTrue(client.setRung(tab: slot, rung: .oneHour))
        let target = TabDropTarget(model: model, slot: slot)
        let foreign = drag(from: nil, board: inkBoard("hunter2"), mask: copy)
        XCTAssertEqual(target.dropRoute(for: foreign), .seal, "the control: a live page takes the seal")

        XCTAssertTrue(client.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        XCTAssertTrue(model.tabs.contains { $0.pageID == dest }, "the control: the page still shows")
        XCTAssertEqual(target.draggingEntered(foreign), .copy, "the strip still says the page stands")
        XCTAssertFalse(target.performDragOperation(foreign), "a due page took the seal")
        XCTAssertFalse(model.tabs.contains { $0.pageID == dest }, "the due page stayed")
        XCTAssertEqual(model.notice, PageModel.pageExpiredLine)
        XCTAssertEqual(standIn.drops, [], "the core read the board for a page past its deadline")
        XCTAssertNil(target.page, "a swept slot still names a page")
        XCTAssertEqual(target.draggingEntered(foreign), [])
    }

    // MARK: The card's stance and the window's ownership

    /// A resting card's tab takes no drop, as its read only page takes none (ADR-0015), and
    /// a tab in the window that does not own the page content takes none (ADR-0033); each
    /// offers no operation, reads nothing and says nothing.
    func testATabOnARestingCardOrInTheWindowThatDoesNotOwnTakesNoDrop() throws {
        let standIn = DragStandIn(tag: UUID().uuidString)
        let model = try makeModel(client: standIn)
        let source = try mountPage(on: model)
        let (dest, slot) = try unshownPage(on: model, text: "xy")
        let board = try beginDrag(source, NSRange(location: 0, length: 4))
        let moving = drag(from: source.textView, board: board, mask: move)
        let foreign = drag(from: nil, board: inkBoard("hunter2"), mask: copy)

        func refuses(_ target: TabDropTarget, _ state: String) {
            XCTAssertFalse(target.takesDrops, state)
            for drop in [moving, foreign] {
                XCTAssertEqual(target.dropRoute(for: drop), .refused, state)
                XCTAssertEqual(target.draggingEntered(drop), [], state)
                XCTAssertEqual(target.draggingUpdated(drop), [], state)
                XCTAssertFalse(target.performDragOperation(drop), state)
            }
            XCTAssertEqual(shape(model, dest), "xy", "a drop was placed \(state)")
            XCTAssertEqual(shape(model, source.sheet), "ab # cd # ef", "the source lost its run \(state)")
            XCTAssertEqual(standIn.drops, [], "the core read the board \(state)")
            XCTAssertNil(model.notice, "a refused drop said something \(state)")
        }

        let raised = TabDropTarget(model: model, slot: slot, surface: .panel)
        XCTAssertEqual(raised.dropRoute(for: moving), .move, "the control: the owner's raised tab takes the move")
        refuses(TabDropTarget(model: model, slot: slot, readOnly: true, surface: .panel), "on a resting card")

        model.transferOwnership(to: .editorWindow)
        refuses(raised, "in the window that does not own")

        // The hand off ended the standing drag, so the owner's control is the seal.
        let editor = TabDropTarget(model: model, slot: slot, surface: .editorWindow)
        XCTAssertTrue(editor.takesDrops)
        XCTAssertEqual(editor.draggingEntered(foreign), .copy)
        XCTAssertTrue(editor.performDragOperation(foreign))
        XCTAssertEqual(shape(model, dest), "xy#", "the owner's tab took no drop")
        XCTAssertEqual(standIn.drops, [[dest, 2, 0]])
    }

    // MARK: A fragment and another app's drag

    /// A copy fragment brought by anything but a standing page drag pastes at the end of
    /// the tab's page through the core, cloning its object (Law 0001, paste row).
    func testAFragmentOnTheBoardPastesAtTheEndOfTheTabsPage() throws {
        let model = try makeModel()
        let source = try mountPage(on: model)
        let ids = chips(model, source.sheet).map(\.chipId)
        let (dest, slot) = try unshownPage(on: model, text: "xy")
        let target = TabDropTarget(model: model, slot: slot)
        let board = try beginDrag(source, NSRange(location: 0, length: 4))
        source.coordinator.endPageDrag()
        let drop = drag(from: NSView(), board: board, mask: move)

        XCTAssertEqual(target.dropRoute(for: drop), .fragment)
        XCTAssertEqual(target.draggingEntered(drop), .copy)
        XCTAssertTrue(target.performDragOperation(drop))
        XCTAssertEqual(shape(model, dest), "xyab #", "the fragment did not paste at the end")
        XCTAssertEqual(chips(model, dest).count, 1)
        XCTAssertFalse(model.hasStorage(for: dest), "the drop built a storage for a page nobody shows")
        XCTAssertFalse(ids.contains(try XCTUnwrap(chips(model, dest).first?.chipId)))
        XCTAssertEqual(shape(model, source.sheet), "ab # cd # ef", "a paste took the source run")
    }

    /// Another app's drag seals at the end of the tab's page, the core reading the board
    /// itself; ink from this app is refused on every tab.
    func testAnotherAppsDragSealsAtTheEndOfTheTabsPageAndThisAppsInkIsRefused() throws {
        let standIn = DragStandIn(tag: UUID().uuidString)
        let model = try makeModel(client: standIn)
        let source = try mountPage(on: model)
        let (dest, slot) = try unshownPage(on: model, text: "xy")
        let target = TabDropTarget(model: model, slot: slot)
        let foreign = drag(from: nil, board: inkBoard("hunter2"), mask: copy)

        XCTAssertEqual(target.dropRoute(for: foreign), .seal)
        XCTAssertEqual(target.draggingEntered(foreign), .copy)
        XCTAssertEqual(target.draggingUpdated(foreign), .copy)
        XCTAssertTrue(target.performDragOperation(foreign))
        XCTAssertEqual(standIn.drops, [[dest, 2, 0]], "the seal was not aimed at the body's end")
        XCTAssertEqual(shape(model, dest), "xy#", "the seal did not stand at the end")
        XCTAssertEqual(chips(model, dest).count, 1)
        XCTAssertFalse(model.hasStorage(for: dest), "the drop built a storage for a page nobody shows")

        let ink = drag(from: source.textView, board: inkBoard("plain"), mask: move)
        XCTAssertEqual(target.dropRoute(for: ink), .refused, "this app's ink found a surface on a tab")
        XCTAssertEqual(target.draggingEntered(ink), [])
        XCTAssertFalse(target.performDragOperation(ink))
        XCTAssertEqual(shape(model, dest), "xy#")
        XCTAssertEqual(standIn.drops.count, 1, "a refused drop reached the core")
    }

    /// A seal dropped on the tab of a page that shows stands the object's face on its surface
    /// and leaves it selected, as the page's own seal does; while a field in that window
    /// has the keys it waits, as the move and the paste do (Law 0007, keys row).
    func testASealDroppedOnAShowingPagesTabStandsTheFaceOnItsSurface() throws {
        let standIn = DragStandIn(tag: UUID().uuidString)
        let model = try makeModel(client: standIn)
        let dest = try mountPage(on: model, text: "xy", seals: [])
        let target = TabDropTarget(model: model, slot: try slot(of: dest.sheet, on: model))
        let foreign = drag(from: nil, board: inkBoard("hunter2"), mask: copy)

        XCTAssertTrue(dest.window.makeFirstResponder(dest.field))
        drainMainQueue()
        XCTAssertEqual(target.dropRoute(for: foreign), .seal, "the control: the tab still sorts the drag")
        XCTAssertFalse(target.performDragOperation(foreign), "the seal was placed under the field")
        XCTAssertEqual(model.notice, PageModel.dropWaitsLine)
        XCTAssertEqual(standIn.drops, [], "the core read the board while a field had the keys")
        XCTAssertEqual(shape(model, dest.sheet), "xy")

        XCTAssertTrue(dest.window.makeFirstResponder(dest.textView))
        model.notice = nil
        XCTAssertTrue(target.performDragOperation(foreign))
        XCTAssertEqual(shape(model, dest.sheet), "xy#")
        XCTAssertEqual(dest.textView.textStorage?.length, 3, "the surface was not restated")
        XCTAssertNotNil(dest.coordinator.chipAttachment(at: 2), "the face did not stand")
        XCTAssertEqual(dest.textView.selectedRange(), NSRange(location: 2, length: 1))
    }

    /// The decrypted drag is refused on every tab, its own page's or another's: every destination
    /// call refuses it before drop to seal reads the drag pasteboard, and its provider is
    /// never asked (Law 0001, decrypted drag row).
    func testTheDecryptedDragLandsOnNoTab() throws {
        let standIn = DragStandIn(tag: UUID().uuidString)
        let model = try makeModel(client: standIn)
        let page = try mountPage(on: model)
        let (dest, slot) = try unshownPage(on: model, text: "xy")
        let (source, item) = try XCTUnwrap(
            page.coordinator.beginDecryptedDrag(at: 3), "the handle started no drag")
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        let records = model.coreClient.ledger().count
        let drop = drag(from: source, board: board, mask: copy)

        for (target, name) in [
            (TabDropTarget(model: model, slot: slot), "another page's tab"),
            (TabDropTarget(model: model, slot: try self.slot(of: page.sheet, on: model)), "its own tab"),
        ] {
            XCTAssertEqual(target.dropRoute(for: drop), .refused, name)
            XCTAssertEqual(target.draggingEntered(drop), [], name)
            XCTAssertEqual(target.draggingUpdated(drop), [], name)
            XCTAssertFalse(target.performDragOperation(drop), name)
        }
        XCTAssertEqual(standIn.drops, [], "a tab of this app ran drop to seal")
        XCTAssertEqual(source.asks, 0, "a tab of this app asked the provider")
        XCTAssertEqual(shape(model, dest), "xy", "the drop stood an object on the tab's page")
        XCTAssertEqual(shape(model, page.sheet), "ab # cd # ef")
        XCTAssertEqual(model.coreClient.ledger().count, records, "a refused drop recorded something")
        XCTAssertNil(model.notice, "a refused drop said something")
        source.end(with: [])
    }

    /// An item with another build's fragment is refused on a tab, which has no surface to
    /// lay its public text on as ink, the page's answer (2026-10-14 every build's copy amendment).
    func testAnotherBuildsFragmentOnATabIsRefused() throws {
        let standIn = DragStandIn(tag: UUID().uuidString)
        let model = try makeModel(client: standIn)
        let (dest, slot) = try unshownPage(on: model, text: "xy")
        let target = TabDropTarget(model: model, slot: slot)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(Data([1, 2, 3]), forType: SealedFragmentEditorTests.otherBuildsType))
        XCTAssertTrue(item.setString(placeholder, forType: .string))
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        let drop = drag(from: nil, board: board, mask: copy)

        XCTAssertEqual(target.dropRoute(for: drop), .refused, "another build's fragment was sorted as another app's drag")
        XCTAssertEqual(target.draggingEntered(drop), [])
        XCTAssertEqual(target.draggingUpdated(drop), [])
        XCTAssertFalse(target.performDragOperation(drop))
        XCTAssertEqual(shape(model, dest), "xy", "another build's fragment was placed on the tab's page")
        XCTAssertEqual(standIn.drops, [], "the core read the board for another build's fragment")
        XCTAssertNil(model.notice, "a refused drop said something")
    }

    // MARK: The tab's own gestures

    /// The target answers no hit test, so the tab's select, hold and reorder handle keep
    /// their gestures, and the strip reorders with the target seated.
    func testTheTargetTakesNoClicksSoTheReorderHandleKeepsItsGesture() throws {
        let model = try makeModel()
        let (first, slot) = try unshownPage(on: model, text: "")
        let (second, _) = try unshownPage(on: model, text: "")
        let target = TabDropTarget(model: model, slot: slot)
        target.frame = NSRect(x: 0, y: 0, width: 120, height: 22)

        XCTAssertNil(target.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertNil(target.hitTest(NSPoint(x: 119, y: 21)))
        XCTAssertEqual(target.registeredDraggedTypes.count, 3)
        XCTAssertEqual(model.tabs.compactMap(\.pageID), [first, second])
        model.move(slot, to: 1)
        XCTAssertEqual(model.tabs.compactMap(\.pageID), [second, first])
        XCTAssertEqual(target.page, first, "the target lost its slot's page across the reorder")
    }

    /// A client whose drop to seal stands its object from the test's own text, recording
    /// where each was aimed, so no step reads the system drag board.
    private final class DragStandIn: CompanionClient, @unchecked Sendable {
        var drops: [[UInt64]] = []

        init(tag: String) {
            super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
        }

        override func sealFromDrag(sheet: UInt64, at: UInt32, length: UInt32) -> ChipInfo? {
            drops.append([sheet, UInt64(at), UInt64(length)])
            return sealText(sheet: sheet, "dropped in", at: at, length: length)
        }
    }
}
