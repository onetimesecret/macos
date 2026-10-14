import AppKit
import XCTest

@testable import CompanionKit

/// The editor's drags of a page's selection (Law 0001's drag, ⌥ drag and plain
/// drag rows, ADR-0047 point 10), driven below the session AppKit runs, against
/// the live core and on pasteboards of the test's own.
@MainActor
final class SealedDragTests: XCTestCase {
    private struct Page {
        let model: PageModel
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let field: NSTextField
        let window: NSWindow
        let sheet: UInt64
    }

    /// The envelope's documented shape (ADR-0047 point 1), read only here.
    private struct Envelope: Decodable {
        let version: Int
        let cut: String?
        let nodes: [Node]
    }

    private struct Node: Decodable {
        let ink: String?
        let ref: Ref?
    }

    private struct Ref: Decodable {
        let uuid: String
        let name: String?
    }

    private let placeholder = "[sealed content · tiny]"
    private let move: NSDragOperation = [.move, .copy]

    /// A model of the test's own, whose ordinary pasteboard is a private one.
    private func makeModel() throws -> (PageModel, NSPasteboard) {
        let suite = "companion-sealed-drag-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-sealed-drag-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = CompanionClient.ephemeral(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let ambient = NSPasteboard.withUniqueName()
        addTeardownBlock { ambient.releaseGlobally() }
        let model = PageModel(
            formFactor: .backdrop, defaults: defaults,
            seams: .init(
                stateDirectory: directory, client: client,
                clearClipboardIfOurs: { false }, ambientPasteboard: ambient))
        return (model, ambient)
    }

    /// A new page holding `text` with each of `seals` sealed, in a window of its
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
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 200, height: 24))
        content.addSubview(scroll)
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
            model: model, coordinator: coordinator, textView: textView, field: field,
            window: window, sheet: sheet)
    }

    private func chips(_ page: Page) -> [ChipInfo] {
        page.model.coreClient.documentRuns(sheet: page.sheet).compactMap {
            if case .chip(let chip) = $0 { chip } else { nil }
        }
    }

    /// Ink as each run reads, with `#` where an object stands.
    private func shape(_ page: Page) -> String {
        page.model.coreClient.documentRuns(sheet: page.sheet).map {
            switch $0 {
            case .chip: "#"
            case .ink(let text): text
            }
        }.joined()
    }

    /// Begin a drag of `range`, and the item it carries on a board of the test's own.
    private func beginDrag(_ page: Page, _ range: NSRange) throws -> NSPasteboard {
        page.textView.setSelectedRange(range)
        guard case .fragment(let item) = page.coordinator.beginPageDrag() else {
            XCTFail("the page's drag carried no fragment")
            throw CocoaError(.featureUnsupported)
        }
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        return board
    }

    /// Every byte of every type on the board, as text, to search for payload.
    private func everything(on pasteboard: NSPasteboard) -> String {
        (pasteboard.types ?? []).compactMap { pasteboard.data(forType: $0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    }

    // MARK: The plain drag

    /// The page's drag carries one item: the copy's envelope and its public text,
    /// so a drop in another app reads ink and placeholders alone; the ordinary
    /// pasteboard is untouched.
    func testThePlainDragCarriesTheCopysFragmentAndNothingElse() throws {
        let (model, ambient) = try makeModel()
        let page = try mountPage(on: model)
        let before = ambient.changeCount
        page.textView.setSelectedRange(NSRange(location: 0, length: 12))
        guard case .fragment(let item) = page.coordinator.beginPageDrag() else {
            return XCTFail("the page's drag carried no fragment")
        }
        XCTAssertEqual(item.types, [SealedFragment.pasteboardType, .string])
        XCTAssertEqual(
            item.string(forType: .string), "ab \(placeholder) cd \(placeholder) ef")
        let envelope = try JSONDecoder().decode(
            Envelope.self, from: try XCTUnwrap(item.data(forType: SealedFragment.pasteboardType)))
        XCTAssertEqual(envelope.version, 1)
        XCTAssertNil(envelope.cut, "a drag is not a cut")
        XCTAssertEqual(envelope.nodes.compactMap(\.ref).count, 2)

        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        let written = everything(on: board)
        XCTAssertFalse(written.contains("SECRET") || written.contains("TOKEN"), written)
        XCTAssertEqual(ambient.changeCount, before, "a drag wrote the ordinary pasteboard")
        XCTAssertEqual(page.textView.textStorage?.length, 12, "starting a drag edited the page")
    }

    /// Outside the app a page's drag offers only a copy, so no other app can take
    /// the selection off the page; inside it a move, and ⌥ narrows that to a copy.
    func testADragOffersAMoveOnlyInsideTheAppAndOptionNarrowsItToACopy() {
        XCTAssertEqual(InkTextView.pageDragMask(for: .outsideApplication, editable: true), .copy)
        XCTAssertEqual(InkTextView.pageDragMask(for: .outsideApplication, editable: false), .copy)
        XCTAssertEqual(
            InkTextView.pageDragMask(for: .withinApplication, editable: true), [.move, .copy])
        XCTAssertEqual(InkTextView.pageDragMask(for: .withinApplication, editable: false), .copy)
        XCTAssertEqual(InkTextView.pageDropOperation(offered: [.move, .copy]), .move)
        XCTAssertEqual(InkTextView.pageDropOperation(offered: .copy), .copy, "the ⌥ drag")
        XCTAssertEqual(InkTextView.pageDropOperation(offered: .generic), [])
        XCTAssertEqual(InkTextView.pageDropOperation(offered: []), [])
    }

    /// A drag of ink alone carries plain text alone, and several stretches holding
    /// an object drag nothing and say why.
    func testInkAloneDragsAsPlainTextAndSeveralStretchesWithAnObjectDoNot() throws {
        let (model, _) = try makeModel()
        let page = try mountPage(on: model)
        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        guard case .fragment(let item) = page.coordinator.beginPageDrag() else {
            return XCTFail("a drag of ink carried nothing")
        }
        XCTAssertEqual(item.types, [.string])
        XCTAssertEqual(item.string(forType: .string), "ab")

        page.textView.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 2)),
            NSValue(range: NSRange(location: 8, length: 1)),
        ]
        guard case .refused = page.coordinator.beginPageDrag() else {
            return XCTFail("several stretches holding an object started a drag")
        }
        XCTAssertEqual(page.model.notice, PageModel.severalStretchesDragLine)
        XCTAssertFalse(page.coordinator.dragsPageSelection)

        page.textView.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 2)),
            NSValue(range: NSRange(location: 10, length: 2)),
        ]
        guard case .ordinary = page.coordinator.beginPageDrag() else {
            return XCTFail("several stretches of ink did not drag as AppKit drags them")
        }
    }

    // MARK: The drag inside the page

    /// A drop on the page moves ink and objects through the core as one step that
    /// keeps every object, selects what moved, arms a write, and one ⌘Z undoes it.
    func testADragInsideThePageMovesInkAndObjectsAsOneStepKeepingThem() throws {
        let (model, _) = try makeModel()
        let page = try mountPage(on: model)
        XCTAssertTrue(model.setChipName("API_KEY", chip: chips(page)[0].chipId, sheet: page.sheet))
        let ids = chips(page).map(\.chipId)
        let records = model.coreClient.ledger().count
        let marks = model.dirtyMarks
        _ = try beginDrag(page, NSRange(location: 0, length: 4))
        XCTAssertEqual(page.coordinator.pageDragOperation(at: 12, offered: move), .move)

        XCTAssertTrue(page.coordinator.dropPageDrag(at: 12, offered: move))
        XCTAssertEqual(shape(page), " cd # efab #")
        XCTAssertEqual(chips(page).map(\.chipId), ids.reversed(), "a move took a new identity")
        XCTAssertEqual(chips(page).last?.name, "API_KEY")
        XCTAssertNotNil(page.coordinator.chipAttachment(at: 11), "the storage was not restated")
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 8, length: 4))
        XCTAssertGreaterThan(model.dirtyMarks, marks, "the move armed no write")
        XCTAssertEqual(model.coreClient.ledger().count, records, "a move recorded something")

        page.coordinator.endPageDrag(operation: .move)
        XCTAssertEqual(shape(page), " cd # efab #", "the session's end removed the moved run")
        page.coordinator.step(back: true)
        XCTAssertEqual(shape(page), "ab # cd # ef", "one undo did not take the move back")
        XCTAssertEqual(chips(page).map(\.chipId), ids)
    }

    /// ⌥ clones every object in the range core side as one step: new identities
    /// beside the originals, the name carried, one `sealed` each, and one ⌘Z.
    func testAnOptionDragClonesEveryObjectCoreSide() throws {
        let (model, _) = try makeModel()
        let page = try mountPage(on: model)
        let ids = chips(page).map(\.chipId)
        XCTAssertTrue(model.setChipName("API_KEY", chip: ids[0], sheet: page.sheet))
        let records = model.coreClient.ledger().count
        let marks = model.dirtyMarks
        _ = try beginDrag(page, NSRange(location: 0, length: 4))
        XCTAssertEqual(page.coordinator.pageDragOperation(at: 12, offered: .copy), .copy)

        XCTAssertTrue(page.coordinator.dropPageDrag(at: 12, offered: .copy))
        XCTAssertEqual(shape(page), "ab # cd # efab #")
        let all = chips(page)
        XCTAssertEqual(Array(all.prefix(2).map(\.chipId)), ids, "the originals moved")
        let clone = try XCTUnwrap(all.last)
        XCTAssertFalse(ids.contains(clone.chipId), "the ⌥ drag kept an identity")
        XCTAssertEqual(clone.name, "API_KEY")
        XCTAssertEqual(model.coreClient.ledger().count, records + 1, "one sealed per clone")
        XCTAssertGreaterThan(model.dirtyMarks, marks, "the clone armed no write")
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 12, length: 4))

        page.coordinator.endPageDrag(operation: .copy)
        page.coordinator.step(back: true)
        XCTAssertEqual(shape(page), "ab # cd # ef", "one undo did not take the clone back")
        XCTAssertEqual(chips(page).map(\.chipId), ids)
    }

    /// A move onto its own range is no drop, and a page that changed under the
    /// drag takes none: nothing is moved and nothing is armed.
    func testADropOntoItsOwnRangeOrAChangedPageChangesNothing() throws {
        let (model, _) = try makeModel()
        let page = try mountPage(on: model)
        _ = try beginDrag(page, NSRange(location: 3, length: 4))
        for index in 3...7 {
            XCTAssertEqual(page.coordinator.pageDragOperation(at: index, offered: move), [])
        }
        let marks = model.dirtyMarks
        XCTAssertFalse(page.coordinator.dropPageDrag(at: 5, offered: move))
        XCTAssertEqual(shape(page), "ab # cd # ef")
        XCTAssertEqual(model.dirtyMarks, marks, "a drop onto its own range armed a write")
        XCTAssertEqual(page.coordinator.pageDragOperation(at: 5, offered: .copy), .copy)

        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        page.textView.insertText("z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(page.coordinator.pageDragOperation(at: 13, offered: move), [])
        XCTAssertFalse(page.coordinator.dropPageDrag(at: 13, offered: move))
        XCTAssertEqual(shape(page), "zab # cd # ef", "a stale drag moved the wrong run")
        page.coordinator.endPageDrag(operation: .move)
        XCTAssertEqual(shape(page), "zab # cd # ef", "a stale drag's end removed a run")
    }

    // MARK: Between pages

    /// A fragment dragged from another page pastes there through the core, as a
    /// clone while its source still stands; the move's end then removes the source
    /// run, which detaches, so ⌘Z there stands the same object again.
    func testADragToAnotherPagePastesThereAndTheMoveRemovesItsSource() throws {
        let (model, _) = try makeModel()
        let source = try mountPage(on: model)
        let ids = chips(source).map(\.chipId)
        XCTAssertTrue(model.setChipName("API_KEY", chip: ids[0], sheet: source.sheet))
        let target = try mountPage(on: model, text: "xy", seals: [])
        let board = try beginDrag(source, NSRange(location: 0, length: 4))

        XCTAssertTrue(target.coordinator.dropFragment(from: board, at: 2))
        XCTAssertEqual(shape(target), "xyab #", "the drop did not paste the fragment")
        let clone = try XCTUnwrap(chips(target).first)
        XCTAssertFalse(ids.contains(clone.chipId))
        XCTAssertEqual(clone.name, "API_KEY")
        XCTAssertFalse(target.textView.string.contains(placeholder), "the public text landed")

        source.coordinator.pageDragMovedAway()
        source.coordinator.endPageDrag(operation: .move)
        XCTAssertEqual(shape(source), " cd # ef", "the move left its source run")
        XCTAssertEqual(chips(source).map(\.chipId), [ids[1]])
        XCTAssertFalse(source.coordinator.dragsPageSelection)
        source.coordinator.step(back: true)
        XCTAssertEqual(shape(source), "ab # cd # ef")
        XCTAssertEqual(chips(source).map(\.chipId), ids, "the removal did not detach")
        XCTAssertEqual(chips(source).first?.name, "API_KEY")
    }

    /// A drag another page copied, no destination took, or another app answered
    /// with a move leaves its source: only a page of this app moves a run away.
    func testACopiedCancelledOrForeignDragLeavesItsSource() throws {
        let (model, _) = try makeModel()
        let page = try mountPage(on: model)
        for (operation, movedAway): (NSDragOperation, Bool) in [
            (.copy, true), ([], true), ([], false), (.move, false),
        ] {
            _ = try beginDrag(page, NSRange(location: 0, length: 4))
            if movedAway { page.coordinator.pageDragMovedAway() }
            page.coordinator.endPageDrag(operation: operation)
            XCTAssertEqual(
                shape(page), "ab # cd # ef",
                "\(operation.rawValue), moved away \(movedAway): the run was removed")
            XCTAssertFalse(page.coordinator.dragsPageSelection)
        }
    }

    /// Through the view's own drop: a fragment from another page is pasted, never
    /// sealed as its public text, and the page's own drag moves through the core.
    func testTheViewsDropRoutesAFragmentAndTheOwnDragThroughTheCore() throws {
        let (model, _) = try makeModel()
        let source = try mountPage(on: model)
        let target = try mountPage(on: model, text: "xy", seals: [])
        let board = try beginDrag(source, NSRange(location: 0, length: 4))

        let below = NSPoint(x: 10, y: target.textView.bounds.maxY - 2)
        XCTAssertEqual(target.textView.characterIndexForInsertion(at: below), 2)
        let foreign = FakeDrag(
            source: source.textView, board: board, mask: move,
            location: target.textView.convert(below, to: nil))
        XCTAssertEqual(target.textView.dragOperation(for: foreign, type: .string), .move)
        XCTAssertTrue(target.textView.performDragOperation(foreign))
        XCTAssertEqual(shape(target), "xyab #", "a fragment from another page was not pasted")
        source.coordinator.endPageDrag(operation: .move)
        XCTAssertEqual(shape(source), " cd # ef", "the move's end left its source run")

        let end = NSPoint(x: 10, y: source.textView.bounds.maxY - 2)
        XCTAssertEqual(source.textView.characterIndexForInsertion(at: end), 8)
        let own = try beginDrag(source, NSRange(location: 3, length: 2))
        let drag = FakeDrag(
            source: source.textView, board: own, mask: move,
            location: source.textView.convert(end, to: nil))
        XCTAssertEqual(source.textView.dragOperation(for: drag, type: .string), .move)
        XCTAssertTrue(source.textView.performDragOperation(drag))
        XCTAssertEqual(shape(source), " cd ef #", "the page's own drop was not a core move")

        target.textView.isEditable = false
        XCTAssertEqual(target.textView.dragOperation(for: foreign, type: .string), [])
        XCTAssertFalse(target.textView.performDragOperation(foreign))
        XCTAssertEqual(shape(target), "xyab #", "a read only page took a drop")
    }

    // MARK: Standing aside (ADR-0046)

    /// While a name field or the note holds the keys, the page starts no drag and
    /// takes no drop, its own or another page's, and the line says why.
    func testDragsStandAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let (model, _) = try makeModel()
        let page = try mountPage(on: model)
        let other = try mountPage(on: model)
        let foreign = try beginDrag(other, NSRange(location: 0, length: 4))
        other.coordinator.endPageDrag(operation: .copy)
        XCTAssertNotNil(SealedFragment.item(on: foreign), "the control: a fragment to drop")
        _ = try beginDrag(page, NSRange(location: 0, length: 4))

        func standsAside(_ holder: String) {
            model.notice = nil
            XCTAssertFalse(page.coordinator.dropPageDrag(at: 12, offered: move), holder)
            XCTAssertEqual(model.notice, PageModel.dropWaitsLine, holder)
            XCTAssertFalse(page.coordinator.dropFragment(from: foreign, at: 12), holder)
            XCTAssertEqual(shape(page), "ab # cd # ef", "the page took a drop under the \(holder)")
        }

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertFalse(page.textView.answersChords)
        standsAside("field")
        let held = page.coordinator.beginPageDrag()
        guard case .refused = held else { return XCTFail("a drag began under the field") }

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        _ = try beginDrag(page, NSRange(location: 0, length: 4))
        page.coordinator.beginNote(at: 3)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        standsAside("note")
        guard case .refused = page.coordinator.beginPageDrag() else {
            return XCTFail("a drag began under the note")
        }

        note.escape()
        drainMainQueue()
        XCTAssertTrue(page.window.firstResponder === page.textView)
        _ = try beginDrag(page, NSRange(location: 0, length: 4))
        XCTAssertTrue(page.coordinator.dropPageDrag(at: 12, offered: move), "the drop did not come back")
        XCTAssertEqual(shape(page), " cd # efab #")
        XCTAssertTrue(page.coordinator.dropFragment(from: foreign, at: 0), "nor the other page's")
        XCTAssertEqual(shape(page), "ab # cd # efab #")
    }
}

/// A drop as AppKit describes it to a destination, for the view's own drop routes.
@MainActor
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingSource: Any?
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation: NSPoint
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(source: NSView, board: NSPasteboard, mask: NSDragOperation, location: NSPoint) {
        draggingSource = source
        draggingPasteboard = board
        draggingSourceOperationMask = mask
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
