import AppKit
import SwiftUI
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
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel)
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
        let target = TabDropTarget(
            model: model, slot: try slot(of: dest.sheet, on: model), readOnly: false, surface: .panel)
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
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel)
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
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel)
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
        let target = TabDropTarget(
            model: model, slot: try slot(of: page.sheet, on: model), readOnly: false, surface: .panel)
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
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel)
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
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel)
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

        let raised = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel)
        XCTAssertEqual(raised.dropRoute(for: moving), .move, "the control: the owner's raised tab takes the move")
        refuses(TabDropTarget(model: model, slot: slot, readOnly: true, surface: .panel), "on a resting card")

        model.transferOwnership(to: .editorWindow)
        refuses(raised, "in the window that does not own")

        // The hand off ended the standing drag, so the owner's control is the seal.
        let editor = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .editorWindow)
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
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel)
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
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel)
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
        let target = TabDropTarget(
            model: model, slot: try slot(of: dest.sheet, on: model), readOnly: false, surface: .panel)
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
            (TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel), "another page's tab"),
            (TabDropTarget(
                model: model, slot: try self.slot(of: page.sheet, on: model), readOnly: false, surface: .panel),
             "its own tab"),
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
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel)
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
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: .panel)
        target.frame = NSRect(x: 0, y: 0, width: 120, height: 22)

        XCTAssertNil(target.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertNil(target.hitTest(NSPoint(x: 119, y: 21)))
        XCTAssertEqual(target.registeredDraggedTypes.count, 3)
        XCTAssertEqual(model.tabs.compactMap(\.pageID), [first, second])
        model.move(slot, to: 1)
        XCTAssertEqual(model.tabs.compactMap(\.pageID), [second, first])
        XCTAssertEqual(target.page, first, "the target lost its slot's page across the reorder")
    }

    // MARK: The side Timeline's page nodes (issue 267)

    /// Each page node of the side Timeline, in the default rail and the pads rail, seats one
    /// target aimed at the slot its click selects, the row a person aims at, and today's
    /// empty place, whose click takes the create path, seats none (ADR-0017).
    func testTheSideTimelineSeatsATargetOnEachPageNodeForThePageItsClickSelects() throws {
        for pads in [false, true] {
            let rail = pads ? "the pads rail" : "the default rail"
            let client = DayProjectionClockClient(tag: UUID().uuidString)
            let model = try makeModel(client: client)
            model.pads.isEnabled = pads
            let oldest = try unshownPage(on: model, text: "oldest")
            XCTAssertTrue(client.advanceDay())
            model.refresh()
            let first = try unshownPage(on: model, text: "first")
            let next = try unshownPage(on: model, text: "next")
            XCTAssertTrue(client.advanceDay())
            model.refresh()
            XCTAssertEqual(model.timeUnits.units.map(\.bucket), [0, -1, -2], rail)
            XCTAssertEqual(model.timeUnits.units.first?.pageIDs, [], "today holds a page in \(rail)")

            let host = mountTimeline(on: model, readOnly: false)
            let targets = nodeTargets(in: host, on: model)
            XCTAssertEqual(targets.map(\.slot), [first.slot, next.slot, oldest.slot], rail)
            XCTAssertEqual(targets.map(\.slot), clickedSlots(on: model), "a drop and a click part in \(rail)")
            XCTAssertEqual(targets.map(\.page), [first.sheet, next.sheet, oldest.sheet], rail)
            XCTAssertEqual(nodes(on: model).filter { !$0.hasPage }.map(\.target), [.today], rail)
            for target in targets {
                XCTAssertTrue(target.takesDrops, rail)
                XCTAssertGreaterThan(target.bounds.width, 0, rail)
                XCTAssertGreaterThan(target.bounds.height, 0, rail)
                XCTAssertNil(target.hitTest(NSPoint(x: target.bounds.midX, y: target.bounds.midY)), rail)
            }
            assertTheTargetsStack(targets, in: host, footInside: !pads, rail)
        }
    }

    /// A rail too dense for its pages' places, which the navigator packs up from the foot and
    /// the pads rail scrolls, still stacks its targets in node order without one meeting another;
    /// the navigator's rows pushed above the column seat none, so none lies over the heading.
    func testADenseTimelinesNodeTargetsStackInNodeOrderWithoutMeeting() throws {
        for pads in [false, true] {
            let rail = pads ? "the pads rail" : "the default rail"
            let client = DayProjectionClockClient(tag: UUID().uuidString)
            let model = try makeModel(client: client)
            model.pads.isEnabled = pads
            for _ in 0..<3 {
                for index in 0..<12 { _ = try unshownPage(on: model, text: "page \(index)") }
                XCTAssertTrue(client.advanceDay())
                model.refresh()
            }
            let host = mountTimeline(on: model, readOnly: false)
            let slots = clickedSlots(on: model)
            if pads {
                let targets = nodeTargets(in: host, on: model)
                XCTAssertEqual(targets.map(\.slot), slots, rail)
                assertTheTargetsStack(targets, in: host, footInside: false, rail)
                continue
            }
            let targets = seatedTargets(in: host)
            XCTAssertFalse(targets.isEmpty, "\(rail) seated no target")
            XCTAssertLessThan(targets.count, slots.count, "the control: \(rail) pushed no row above its column")
            XCTAssertEqual(
                targets.map(\.slot), Array(slots.suffix(targets.count)),
                "a row pushed above \(rail) seated a target, or a seated one left its node")
            let bounds = host.convert(host.bounds, to: nil)
            for target in targets {
                XCTAssertTrue(
                    bounds.contains(frame(of: target)), "a target at \(frame(of: target)) lies outside \(rail)")
            }
            assertTheTargetsStack(targets, in: host, footInside: true, rail)
        }
    }

    /// A node on a resting card takes no drop, as its read only page takes none (ADR-0015),
    /// and a node in the window that does not own the page content takes none (ADR-0033);
    /// raised, or once its window owns, the same node seals another app's drag.
    func testANodeOnARestingCardOrInTheWindowThatDoesNotOwnTakesNoDrop() throws {
        for pads in [false, true] {
            let rail = pads ? "the pads rail" : "the default rail"
            let standIn = DragStandIn(tag: UUID().uuidString)
            let model = try makeModel(client: standIn)
            model.pads.isEnabled = pads
            let destination = try unshownPage(on: model, text: "xy")
            let foreign = drag(from: nil, board: inkBoard("hunter2"), mask: copy)
            let host = mountTimeline(on: model, readOnly: true)

            /// The target on the destination's node as the rail stands now.
            func target() throws -> TabDropTarget {
                try XCTUnwrap(nodeTargets(in: host, on: model).first { $0.slot == destination.slot }, rail)
            }

            /// The node offers nothing, places nothing, reads no board and says nothing.
            func refuses(_ state: String) throws {
                let node = try target()
                XCTAssertFalse(node.takesDrops, "\(rail) \(state)")
                XCTAssertEqual(node.dropRoute(for: foreign), .refused, "\(rail) \(state)")
                XCTAssertEqual(node.draggingEntered(foreign), [], "\(rail) \(state)")
                XCTAssertFalse(node.performDragOperation(foreign), "\(rail) \(state)")
                XCTAssertEqual(standIn.drops, [], "the core read the board \(state)")
                XCTAssertEqual(shape(model, destination.sheet), "xy", "a drop was placed \(state)")
                XCTAssertNil(model.notice, "a refused drop said something \(state)")
            }

            XCTAssertTrue(try target().readOnly, rail)
            try refuses("on a resting card")

            host.rootView = timeline(model, readOnly: false, surface: .panel)
            XCTAssertFalse(try target().readOnly, rail)
            XCTAssertEqual(try target().draggingEntered(foreign), .copy, "the raised card's node refused")

            host.rootView = timeline(model, readOnly: false, surface: .editorWindow)
            XCTAssertEqual(try target().surface, .editorWindow, rail)
            try refuses("in the window that does not own")

            model.transferOwnership(to: .editorWindow)
            let owner = try target()
            XCTAssertTrue(owner.takesDrops, rail)
            XCTAssertTrue(owner.performDragOperation(foreign), rail)
            XCTAssertEqual(standIn.drops, [[destination.sheet, 2, 0]], rail)
            XCTAssertEqual(shape(model, destination.sheet), "xy#", rail)
        }
    }

    /// A node's target moves with its node when the nodes re sort, and a new page's node
    /// seats its own, so a drop still goes where the click on that row goes.
    func testANodesTargetFollowsItsNodeThroughAResortAndANewPage() throws {
        for pads in [false, true] {
            let rail = pads ? "the pads rail" : "the default rail"
            let model = try makeModel()
            model.pads.isEnabled = pads
            let first = try unshownPage(on: model, text: "a")
            let second = try unshownPage(on: model, text: "b")
            let third = try unshownPage(on: model, text: "c")
            let host = mountTimeline(on: model, readOnly: false)
            let before = nodeTargets(in: host, on: model)
            XCTAssertEqual(before.map(\.slot), clickedSlots(on: model), rail)
            XCTAssertEqual(Set(before.map(\.slot)), [first.slot, second.slot, third.slot], rail)

            let index = try XCTUnwrap(model.navigationTabs.firstIndex { $0.id == before[0].slot })
            model.move(try XCTUnwrap(before.last?.slot), to: index)
            let resorted = nodeTargets(in: host, on: model)
            XCTAssertNotEqual(clickedSlots(on: model), before.map(\.slot), "the move re sorted nothing")
            XCTAssertEqual(resorted.map(\.slot), clickedSlots(on: model), "a target kept its old row in \(rail)")
            for target in resorted {
                XCTAssertEqual(target.page, model.tabs.first { $0.id == target.slot }?.pageID, rail)
            }

            model.newPage()
            let made = try XCTUnwrap(model.selectedPageID)
            let madeSlot = try slot(of: made, on: model)
            let grown = nodeTargets(in: host, on: model)
            XCTAssertEqual(grown.count, 4, rail)
            XCTAssertEqual(grown.map(\.slot), clickedSlots(on: model), "the new node's row aims elsewhere in \(rail)")
            XCTAssertEqual(grown.first { $0.slot == madeSlot }?.page, made, rail)
        }
    }

    /// A page's drag dropped on another page's node moves its range to the end of the page
    /// that node names, keeping the object, through the same target a tab seats.
    func testADragDroppedOnAPageNodeMovesItsRangeToTheEndOfThatNodesPage() throws {
        for pads in [false, true] {
            let rail = pads ? "the pads rail" : "the default rail"
            let model = try makeModel()
            model.pads.isEnabled = pads
            let source = try mountPage(on: model)
            let ids = chips(model, source.sheet).map(\.chipId)
            let destination = try unshownPage(on: model, text: "xy")
            let sourceSlot = try slot(of: source.sheet, on: model)
            model.select(sourceSlot)
            let host = mountTimeline(on: model, readOnly: false)
            let targets = nodeTargets(in: host, on: model)
            XCTAssertEqual(targets.map(\.slot), clickedSlots(on: model), rail)
            let target = try XCTUnwrap(targets.first { $0.slot == destination.slot }, rail)
            let board = try beginDrag(source, NSRange(location: 0, length: 4))
            let drop = drag(from: source.textView, board: board, mask: move)

            XCTAssertEqual(target.draggingEntered(drop), .move, rail)
            XCTAssertTrue(target.performDragOperation(drop), rail)
            XCTAssertEqual(shape(model, destination.sheet), "xyab #", "the run was not placed at the end")
            XCTAssertEqual(chips(model, destination.sheet).map(\.chipId), [ids[0]], "the move took a new identity")
            XCTAssertEqual(shape(model, source.sheet), " cd # ef", "the move left its source run")
            XCTAssertEqual(model.selection, sourceSlot, "a drop on a node selected its page in \(rail)")
            source.coordinator.endPageDrag()
        }
    }

    /// ⌥ over another page's node pastes the copy fragment at the end of that page, every
    /// object cloned, and ⌥ over the source page's own node clones the range to its end;
    /// the source keeps its run (Law 0001, ⌥ drag row).
    func testOptionOverAPageNodeClonesTheRangeToTheEndOfItsPage() throws {
        for pads in [false, true] {
            let rail = pads ? "the pads rail" : "the default rail"
            let model = try makeModel()
            model.pads.isEnabled = pads
            let source = try mountPage(on: model)
            let ids = chips(model, source.sheet).map(\.chipId)
            let destination = try unshownPage(on: model, text: "xy")
            let sourceSlot = try slot(of: source.sheet, on: model)
            model.select(sourceSlot)
            let host = mountTimeline(on: model, readOnly: false)
            let targets = nodeTargets(in: host, on: model)
            let other = try XCTUnwrap(targets.first { $0.slot == destination.slot }, rail)
            let own = try XCTUnwrap(targets.first { $0.slot == sourceSlot }, rail)

            var board = try beginDrag(source, NSRange(location: 0, length: 4))
            var drop = drag(from: source.textView, board: board, mask: copy)
            XCTAssertEqual(other.dropRoute(for: drop), .fragment, rail)
            XCTAssertEqual(other.draggingEntered(drop), .copy, rail)
            XCTAssertTrue(other.performDragOperation(drop), rail)
            XCTAssertEqual(shape(model, destination.sheet), "xyab #", "the copy was not placed at the end in \(rail)")
            let clone = try XCTUnwrap(chips(model, destination.sheet).first?.chipId, rail)
            XCTAssertFalse(ids.contains(clone), "the clone kept the identity in \(rail)")
            XCTAssertEqual(shape(model, source.sheet), "ab # cd # ef", "⌥ took the source run in \(rail)")
            XCTAssertEqual(chips(model, source.sheet).map(\.chipId), ids, rail)
            source.coordinator.endPageDrag()

            board = try beginDrag(source, NSRange(location: 0, length: 4))
            drop = drag(from: source.textView, board: board, mask: copy)
            XCTAssertEqual(own.dropRoute(for: drop), .ownDrag, rail)
            XCTAssertEqual(own.draggingEntered(drop), .copy, rail)
            XCTAssertTrue(own.performDragOperation(drop), rail)
            XCTAssertEqual(shape(model, source.sheet), "ab # cd # efab #", "⌥ did not clone to the end in \(rail)")
            XCTAssertEqual(chips(model, source.sheet).count, 3, rail)
            source.coordinator.endPageDrag()
        }
    }

    /// The decrypted drag is refused on every page node, its own page's and another's, in
    /// every destination call before drop to seal reads the board, and its provider is never
    /// asked (Law 0001, decrypted drag row).
    func testEveryPageNodeRefusesTheDecryptedDrag() throws {
        for pads in [false, true] {
            let rail = pads ? "the pads rail" : "the default rail"
            let standIn = DragStandIn(tag: UUID().uuidString)
            let model = try makeModel(client: standIn)
            model.pads.isEnabled = pads
            let page = try mountPage(on: model)
            let destination = try unshownPage(on: model, text: "xy")
            let pageSlot = try slot(of: page.sheet, on: model)
            let targets = nodeTargets(in: mountTimeline(on: model, readOnly: false), on: model)
            let (source, item) = try XCTUnwrap(
                page.coordinator.beginDecryptedDrag(at: 3), "the handle started no drag in \(rail)")
            let board = NSPasteboard.withUniqueName()
            addTeardownBlock { board.releaseGlobally() }
            board.clearContents()
            XCTAssertTrue(board.writeObjects([item]))
            let records = model.coreClient.ledger().count
            let drop = drag(from: source, board: board, mask: copy)

            for (slot, name) in [(destination.slot, "another page's node"), (pageSlot, "its own node")] {
                let target = try XCTUnwrap(targets.first { $0.slot == slot }, "\(rail): \(name)")
                XCTAssertTrue(target.takesDrops, "the control: \(name) takes drops in \(rail)")
                XCTAssertEqual(target.dropRoute(for: drop), .refused, "\(rail): \(name)")
                XCTAssertEqual(target.draggingEntered(drop), [], "\(rail): \(name)")
                XCTAssertEqual(target.draggingUpdated(drop), [], "\(rail): \(name)")
                XCTAssertFalse(target.performDragOperation(drop), "\(rail): \(name)")
            }
            XCTAssertEqual(standIn.drops, [], "a node ran drop to seal in \(rail)")
            XCTAssertEqual(source.asks, 0, "a node asked the provider in \(rail)")
            XCTAssertEqual(shape(model, destination.sheet), "xy", "the drop stood an object in \(rail)")
            XCTAssertEqual(shape(model, page.sheet), "ab # cd # ef", rail)
            XCTAssertEqual(model.coreClient.ledger().count, records, "a refused drop recorded something in \(rail)")
            XCTAssertNil(model.notice, "a refused drop said something in \(rail)")
            source.end(with: [])
        }
    }

    /// A node whose page is due but not yet swept still offers the page's operation, and the
    /// drop refuses through the core and settles with the expired line; the swept page's
    /// node then seats no target (Law 0001, drag row).
    func testAPageNodeWhosePageIsDueRefusesTheDropAndSettlesWithTheExpiredLine() throws {
        for pads in [false, true] {
            let rail = pads ? "the pads rail" : "the default rail"
            let model = try makeModel()
            model.pads.isEnabled = pads
            let client = model.coreClient
            let source = try mountPage(on: model)
            let destination = try unshownPage(on: model, text: "xy")
            XCTAssertTrue(client.setRung(tab: destination.slot, rung: .oneHour), rail)
            let host = mountTimeline(on: model, readOnly: false)
            let target = try XCTUnwrap(nodeTargets(in: host, on: model).first { $0.slot == destination.slot }, rail)
            let board = try beginDrag(source, NSRange(location: 0, length: 4))
            let drop = drag(from: source.textView, board: board, mask: move)
            XCTAssertEqual(target.dropRoute(for: drop), .move, "the control: a live page takes the move in \(rail)")

            XCTAssertTrue(client.ageForTests(byMs: 2 * 60 * 60 * 1_000), rail)
            XCTAssertEqual(target.draggingEntered(drop), .move, "the rail still says the page stands in \(rail)")
            XCTAssertFalse(target.performDragOperation(drop), "a due page took the drop in \(rail)")
            XCTAssertEqual(model.notice, PageModel.pageExpiredLine, rail)
            XCTAssertFalse(model.tabs.contains { $0.pageID == destination.sheet }, "the due page stayed in \(rail)")
            XCTAssertEqual(shape(model, source.sheet), "ab # cd # ef", "the refused move changed the source in \(rail)")
            XCTAssertFalse(
                nodeTargets(in: host, on: model).contains { $0.slot == destination.slot },
                "the swept page's node still seats a target in \(rail)")
        }
    }

    /// The side Timeline as the card or editor window mounts it, under `readOnly` and `surface`.
    private func timeline(_ model: PageModel, readOnly: Bool, surface: PresentationOwner) -> AnyView {
        AnyView(TimeRailView(model: model, readOnly: readOnly).environment(\.presentationSurface, surface))
    }

    /// The side Timeline hosted in a window of its own that is never ordered on screen.
    private func mountTimeline(on model: PageModel, readOnly: Bool) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: timeline(model, readOnly: readOnly, surface: .panel))
        host.frame = NSRect(x: 0, y: 0, width: TimeRailView.width(experimental: model.pads.isEnabled), height: 480)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { window.close() }
        return host
    }

    /// Every target seated under `host` once it has laid out, top to bottom as drawn.
    private func seatedTargets(in host: NSView) -> [TabDropTarget] {
        host.layoutSubtreeIfNeeded()
        drainMainQueue()
        host.layoutSubtreeIfNeeded()
        return mountedTargets(in: host).sorted { frame(of: $0).midY > frame(of: $1).midY }
    }

    /// `seatedTargets(in:)`, where a count other than the page nodes `model` draws, an
    /// unmounted host's zero among them, fails the test.
    private func nodeTargets(
        in host: NSView, on model: PageModel, file: StaticString = #filePath, line: UInt = #line
    ) -> [TabDropTarget] {
        let targets = seatedTargets(in: host)
        let pageNodes = clickedSlots(on: model).count
        XCTAssertGreaterThan(pageNodes, 0, "the rail draws no page node to look for", file: file, line: line)
        XCTAssertEqual(
            targets.count, pageNodes, "the host seated \(targets.count) of \(pageNodes) page nodes' targets",
            file: file, line: line)
        return targets
    }

    /// Asserts `targets`, top to bottom as drawn, never meet and each sits under the one before;
    /// with `footInside`, the stream navigator's, the last one's bottom edge lies inside `host`.
    private func assertTheTargetsStack(
        _ targets: [TabDropTarget], in host: NSView, footInside: Bool, _ rail: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let frames = targets.map(frame(of:))
        for (index, upper) in frames.enumerated() {
            for lower in frames.dropFirst(index + 1) {
                XCTAssertFalse(
                    upper.intersects(lower), "targets at \(upper) and \(lower) overlap in \(rail)",
                    file: file, line: line)
            }
        }
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(
                lower.maxY, upper.minY, "a target at \(lower) rises into \(upper) in \(rail)",
                file: file, line: line)
        }
        guard footInside else { return }
        let bounds = host.convert(host.bounds, to: nil)
        guard let foot = frames.last?.minY else { return XCTFail("no target in \(rail)", file: file, line: line) }
        XCTAssertGreaterThanOrEqual(foot, bounds.minY, "the last target passes the foot of \(rail)", file: file, line: line)
        XCTAssertLessThanOrEqual(foot, bounds.maxY, "the last target ends above \(rail)", file: file, line: line)
    }

    /// Every target under `view`, in the order the view tree holds them.
    private func mountedTargets(in view: NSView) -> [TabDropTarget] {
        if let target = view as? TabDropTarget { return [target] }
        return view.subviews.flatMap { mountedTargets(in: $0) }
    }

    /// A target's frame in its window, whose y grows upward.
    private func frame(of target: TabDropTarget) -> NSRect {
        target.convert(target.bounds, to: nil)
    }

    /// The nodes the rail draws, top to bottom, as `TimeRailView` asks `StreamNavigator`.
    private func nodes(on model: PageModel) -> [StreamNavigator.Node] {
        StreamNavigator.nodes(
            projection: model.timeUnits, tabs: model.navigationTabs, selection: model.selection)
    }

    /// The slot each page node's click selects (`StreamNavigator.Node.target`), top to bottom.
    private func clickedSlots(on model: PageModel) -> [UInt64] {
        nodes(on: model).compactMap { node in
            if case .tab(let slot) = node.target { slot } else { nil }
        }
    }

    /// A client whose pages are born on a day count of the test's own, so the Timeline draws
    /// several days; `advanceDay` ages the core by the same day, so deadlines keep pace.
    private final class DayProjectionClockClient: CompanionClient, @unchecked Sendable {
        private static let dayMs: UInt64 = 24 * 60 * 60 * 1_000
        private let lock = NSLock()
        private var day = 0
        private var birthDays: [String: Int] = [:]

        init(tag: String) {
            super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
        }

        func advanceDay() -> Bool {
            guard ageForTests(byMs: Self.dayMs) else { return false }
            lock.lock()
            defer { lock.unlock() }
            day += 1
            return true
        }

        override func tabs() -> [TabSummary] {
            let tabs = super.tabs()
            lock.lock()
            defer { lock.unlock() }
            return tabs.map { tab in
                guard tab.hasPage, let uuid = tab.pageUUID else { return tab }
                let born = birthDays[uuid, default: day]
                birthDays[uuid] = born
                return TabSummary(
                    id: tab.id, uuid: tab.uuid, pageUUID: tab.pageUUID,
                    hasPage: tab.hasPage, pageID: tab.pageID,
                    title: tab.title, titleSource: tab.titleSource,
                    rungCode: tab.rungCode, rungLabel: tab.rungLabel,
                    remainingMs: tab.remainingMs, remainingLabel: tab.remainingLabel,
                    spokenRemaining: tab.spokenRemaining, fractionRemaining: tab.fractionRemaining,
                    paused: tab.paused, holdToppedUp: tab.holdToppedUp, holdRemainingMs: tab.holdRemainingMs,
                    chipCount: tab.chipCount, lastHour: tab.lastHour, pageHasContent: tab.pageHasContent,
                    pageDayOffset: born - day,
                    pageCreatedMs: 1_700_000_000_000 + UInt64(born) * Self.dayMs)
            }
        }
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
