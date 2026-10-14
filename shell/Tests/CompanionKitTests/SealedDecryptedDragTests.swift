import AppKit
import XCTest

@testable import CompanionKit

/// The decrypted drag from a block's handle (Law 0001's decrypted drag row,
/// ADR-0047 point 11, ADR-0050), driven below the session AppKit runs, against
/// the live core and on pasteboards of the test's own.
@MainActor
final class SealedDecryptedDragTests: XCTestCase {
    private struct Page {
        let model: PageModel
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let field: NSTextField
        let window: NSWindow
        let sheet: UInt64
    }

    private let secret = "n0ts3cr3t"
    /// Where the sealed object stands on a mounted page.
    private let object = 3

    /// A model of the test's own, whose ordinary pasteboard is a private one.
    private func makeModel() throws -> PageModel {
        let suite = "companion-decrypted-drag-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-decrypted-drag-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = CompanionClient.ephemeral(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let ambient = privateBoard()
        return PageModel(
            formFactor: .backdrop, defaults: defaults,
            seams: .init(
                stateDirectory: directory, client: client,
                clearClipboardIfOurs: { false }, ambientPasteboard: ambient))
    }

    private func privateBoard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        board.clearContents()
        return board
    }

    /// A new page reading `ab <secret> cd` with the secret sealed, in a window of its
    /// own with the keys: `ab # cd`, the object at index 3.
    private func mountPage(on model: PageModel) throws -> Page {
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
        textView.insertText(
            "ab \(secret) cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: object, length: secret.count))
        coordinator.sealSelectionOrLine()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        drainMainQueue()
        return Page(
            model: model, coordinator: coordinator, textView: textView, field: field,
            window: window, sheet: sheet)
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

    private func sent(_ model: PageModel) -> [String] {
        model.coreClient.ledger().filter { $0.event == "sent" }.map(\.destination)
    }

    private func chipID(_ page: Page) -> UInt64? {
        page.coordinator.chipAttachment(at: object)?.info.chipId
    }

    private func begin(_ page: Page) throws -> (source: DecryptedDrag, item: NSPasteboardItem) {
        try XCTUnwrap(
            page.coordinator.beginDecryptedDrag(at: object), "the handle started no drag")
    }

    // MARK: The handle

    /// The handle sits on the classification's row a gap before the actions seat, and
    /// a block too narrow to hold it beside the classification offers none.
    func testTheHandleSitsBeforeTheActionsSeatAndOnlyWhereItFits() throws {
        let words: CGFloat = 76
        let label: CGFloat = 92
        let frame = NSRect(x: 10, y: 10, width: 300, height: SealedBlockCell.blockHeight)
        let metrics = SealedBlockLayout.metrics(containerWidth: frame.width)
        let actions = SealedBlockCell.actionsRect(in: frame)
        let handle = try XCTUnwrap(
            SealedBlockCell.decryptedDragRect(in: frame, wordsWidth: words, labelWidth: label))
        XCTAssertEqual(handle.maxX, actions.minX - metrics.handleGap)
        XCTAssertEqual(handle.minY, actions.minY)
        XCTAssertEqual(handle.height, actions.height)
        XCTAssertEqual(handle.width, words + metrics.handleInset * 2)

        let least = metrics.horizontalPadding * 2 + metrics.lockSize + metrics.lockToLabelGap
            + label + metrics.handleGap * 2 + words + metrics.handleInset * 2
            + metrics.actionsWidth
        func fits(_ width: CGFloat) -> Bool {
            SealedBlockCell.decryptedDragRect(
                in: NSRect(x: 10, y: 10, width: width, height: frame.height),
                wordsWidth: words, labelWidth: label) != nil
        }
        XCTAssertTrue(fits(least))
        XCTAssertFalse(fits(least - 1), "the handle would meet the classification")
    }

    /// A text object drags as plain text and an image as PNG, as copy decrypted writes
    /// them; a kind this build does not know has no handle.
    func testTheHandleDragsTheChipsOwnTypeAndAnUnknownKindHasNone() {
        XCTAssertEqual(DecryptedDrag.pasteboardType(forKind: "text"), .string)
        XCTAssertEqual(DecryptedDrag.pasteboardType(forKind: "image"), .png)
        XCTAssertNil(DecryptedDrag.pasteboardType(forKind: "file"))
        let frame = NSRect(x: 0, y: 0, width: 400, height: SealedBlockCell.blockHeight)
        func cell(_ kind: String) -> SealedBlockCell {
            SealedBlockCell(info: ChipInfo(
                chipId: 1, kind: kind, excerpt: "n0…3t", sizeLabel: "tiny", concealed: false))
        }
        XCTAssertNotNil(cell("text").decryptedDragRect(in: frame))
        XCTAssertNotNil(cell("image").decryptedDragRect(in: frame))
        XCTAssertNil(cell("file").decryptedDragRect(in: frame))
    }

    /// Only a first plain press on the handle while it is drawn starts the drag, and
    /// only once the press has moved.
    func testOnlyAFirstPlainPressOnADrawnHandleStartsTheDrag() {
        func starts(
            on: Bool = true, shown: Bool = true, clicks: Int = 1,
            flags: NSEvent.ModifierFlags = []
        ) -> Bool {
            InkTextView.startsDecryptedDrag(
                onHandle: on, handleShown: shown, clickCount: clicks, modifierFlags: flags)
        }
        XCTAssertTrue(starts())
        XCTAssertTrue(starts(flags: .capsLock), "a state flag is no gesture")
        XCTAssertFalse(starts(on: false))
        XCTAssertFalse(starts(shown: false), "a handle not drawn is not there to press")
        XCTAssertFalse(starts(clicks: 2))
        for flag: NSEvent.ModifierFlags in [.command, .shift, .control, .option] {
            XCTAssertFalse(starts(flags: flag))
        }
        let start = NSPoint(x: 10, y: 10)
        XCTAssertFalse(InkTextView.pressBecomesDrag(from: start, to: NSPoint(x: 12, y: 11)))
        XCTAssertTrue(InkTextView.pressBecomesDrag(from: start, to: NSPoint(x: 13, y: 10)))
    }

    /// The pointer turns to an open hand over the handle while it is drawn, hovered or
    /// selected, and over none while a field or the note holds the keys (ADR-0046).
    func testTheHandleShowsAnOpenHandWhereAPressWouldStartTheDrag() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let textView = page.textView
        let frame = try XCTUnwrap(textView.chipFrame(at: object))
        let handle = try XCTUnwrap(textView.chipCell(at: object)?.decryptedDragRect(in: frame))
        XCTAssertEqual(textView.decryptedDragCursorRects, [], "a handle not drawn")

        func hover(_ point: NSPoint, holdsKeys: Bool = true) {
            textView.hoverRefreshInput = (
                page.window.convertPoint(toScreen: textView.convert(point, to: nil)),
                holdsKeys, true)
            textView.refreshHover()
        }
        hover(NSPoint(x: frame.midX, y: frame.midY))
        XCTAssertEqual(textView.hoveredChipIndex, object)
        XCTAssertEqual(textView.decryptedDragCursorRects, [handle], "the hovered block")
        hover(NSPoint(x: frame.midX, y: frame.midY), holdsKeys: false)
        XCTAssertNil(textView.hoveredChipIndex)
        XCTAssertEqual(textView.decryptedDragCursorRects, [], "the hover left")

        textView.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertEqual(textView.decryptedDragCursorRects, [], "ink is selected")
        textView.setSelectedRange(NSRange(location: object, length: 0))
        XCTAssertEqual(textView.decryptedDragCursorRects, [], "a caret before the block")
        textView.setSelectedRange(NSRange(location: object, length: 1))
        XCTAssertEqual(textView.decryptedDragCursorRects, [handle], "the selected block")

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertEqual(textView.decryptedDragCursorRects, [], "under the field")

        XCTAssertTrue(page.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: object, length: 1))
        page.coordinator.beginNote(at: object)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        XCTAssertEqual(textView.decryptedDragCursorRects, [], "under the note")

        note.escape()
        drainMainQueue()
        textView.setSelectedRange(NSRange(location: object, length: 1))
        XCTAssertEqual(textView.decryptedDragCursorRects, [handle], "the hand came back")
    }

    // MARK: The drag and its provider

    /// The drag offers a copy to another app and nothing inside this one.
    func testTheDragOffersACopyToAnotherAppAndNothingInsideThisOne() {
        XCTAssertEqual(DecryptedDrag.operationMask(for: .outsideApplication), .copy)
        XCTAssertEqual(DecryptedDrag.operationMask(for: .withinApplication), [])
    }

    /// The item promises the chip's own type and holds nothing until a destination
    /// asks; the ask is written by the core, records one `sent` to `drag` and arms a
    /// write, and the drop leaves the object where it stood.
    func testADestinationsAskIsWrittenByTheCoreAndRecordsOneDrag() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        XCTAssertNil(page.coordinator.beginDecryptedDrag(at: 0), "ink has no handle")
        let (source, item) = try begin(page)
        XCTAssertTrue(page.coordinator.decryptedDrag === source)
        XCTAssertEqual(item.types, [.string], "a promise of the chip's own type alone")
        let board = privateBoard()
        XCTAssertTrue(board.writeObjects([item]))
        XCTAssertEqual(source.asks, 0)
        XCTAssertEqual(sent(model), [], "nothing is written or recorded before an ask")

        let marks = model.dirtyMarks
        XCTAssertEqual(board.string(forType: .string), secret, "the destination's read")
        XCTAssertEqual(source.asks, 1)
        XCTAssertEqual(sent(model), ["drag"])
        XCTAssertGreaterThan(model.dirtyMarks, marks, "the record arms a write (issue #52)")

        source.end(with: .copy)
        XCTAssertNil(page.coordinator.decryptedDrag, "the session's end lets the drag go")
        XCTAssertEqual(shape(page), "ab # cd", "a successful drop never deletes the object")
    }

    /// A drag that dropped nowhere answers no later ask, and an ask with no pasteboard
    /// or for another type is refused; none writes or records.
    func testACancelledDragAndAForeignAskAreRefused() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let board = privateBoard()

        let (stray, strayItem) = try begin(page)
        stray.pasteboard(nil, item: strayItem, provideDataForType: .string)
        stray.pasteboard(board, item: strayItem, provideDataForType: .png)
        XCTAssertEqual(stray.asks, 2)
        XCTAssertNil(strayItem.data(forType: .png))
        XCTAssertEqual(sent(model), [])
        stray.end(with: [])

        let (source, item) = try begin(page)
        XCTAssertTrue(board.writeObjects([item]))
        source.end(with: [])
        XCTAssertTrue(source.cancelled)
        XCTAssertNil(page.coordinator.decryptedDrag)
        XCTAssertNil(board.string(forType: .string), "a cancelled drag answered a later ask")
        XCTAssertEqual(source.asks, 1)
        XCTAssertEqual(sent(model), [])
        XCTAssertEqual(shape(page), "ab # cd")
    }

    /// An ask past the page's deadline is refused, writes and records nothing, and
    /// settles the page with no line, since the destination asked (ADR-0052).
    func testAnAskPastThePagesDeadlineIsRefusedAndSettlesWithoutALine() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let (source, item) = try begin(page)
        let client = model.coreClient
        let tab = try XCTUnwrap(model.tabs.first { $0.pageID == page.sheet }?.id)
        XCTAssertTrue(client.setRung(tab: tab, rung: .oneHour))
        XCTAssertTrue(client.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        XCTAssertTrue(client.tabs().contains { $0.pageID == page.sheet }, "the control: no sweep")
        let board = privateBoard()
        XCTAssertTrue(board.writeObjects([item]))

        XCTAssertNil(board.string(forType: .string), "the payload left a page past its deadline")
        XCTAssertEqual(source.asks, 1)
        XCTAssertEqual(sent(model), [])
        XCTAssertNotEqual(model.notice, PageModel.pageExpiredLine, "a line answered the ask")
        XCTAssertFalse(
            model.tabs.contains { $0.pageID == page.sheet }, "the refusal left the page standing")
        source.end(with: [])
    }

    // MARK: Inside the app (ADR-0050)

    /// The app's own decrypted drag lands on no page: refused before drop to seal reads
    /// the drag board, so no provider is asked, nothing is recorded and nothing seals.
    /// A drag from another app still meets drop to seal.
    func testTheDecryptedDragLandsOnNoPageOfThisApp() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let other = try mountPage(on: model)
        let (source, item) = try begin(page)
        let board = privateBoard()
        XCTAssertTrue(board.writeObjects([item]))

        let foreign = FakeDrop(
            source: nil, board: board, location: other.textView.convert(.zero, to: nil))
        XCTAssertEqual(
            other.textView.draggingEntered(foreign), .copy,
            "the control: another app's drag meets drop to seal")

        other.coordinator.beginNote(at: object)
        let note = try XCTUnwrap(other.coordinator.noteEditor?.textView)
        model.notice = nil
        let targets = [(page.textView, "its own page"), (other.textView, "another page"),
                       (note, "a note")]
        for (target, name) in targets {
            let drop = FakeDrop(
                source: source, board: board,
                location: target.convert(NSPoint(x: 10, y: 10), to: nil))
            // Checked first, so a regression stops before drop to seal reads a drag board.
            guard target.draggingEntered(drop) == [] else {
                return XCTFail("\(name) offered to take the decrypted drag")
            }
            XCTAssertEqual(target.draggingUpdated(drop), [], name)
            XCTAssertEqual(target.dragOperation(for: drop, type: .string), [], name)
            XCTAssertFalse(target.prepareForDragOperation(drop), name)
            XCTAssertFalse(target.performDragOperation(drop), name)
        }
        XCTAssertEqual(other.model.noteText(chip: try XCTUnwrap(chipID(other))), "")
        XCTAssertEqual(source.asks, 0, "a surface of this app asked the provider")
        XCTAssertNil(model.notice, "drop to seal ran, and said it had nothing to seal")
        XCTAssertEqual(sent(model), [])
        XCTAssertEqual(shape(page), "ab # cd")
        XCTAssertEqual(shape(other), "ab # cd", "the drop sealed a new object")
    }

    // MARK: Standing aside (ADR-0046)

    /// While a name field or the note holds the keys, the handle starts no drag and
    /// the line says why.
    func testTheDecryptedDragStandsAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertFalse(page.textView.answersChords)
        model.notice = nil
        XCTAssertNil(page.coordinator.beginDecryptedDrag(at: object), "under the field")
        XCTAssertEqual(model.notice, PageModel.decryptedDragWaitsLine)

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        page.coordinator.beginNote(at: object)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        model.notice = nil
        XCTAssertNil(page.coordinator.beginDecryptedDrag(at: object), "under the note")
        XCTAssertEqual(model.notice, PageModel.decryptedDragWaitsLine)

        note.escape()
        drainMainQueue()
        XCTAssertTrue(page.window.firstResponder === page.textView)
        XCTAssertNotNil(page.coordinator.beginDecryptedDrag(at: object), "the drag came back")
        XCTAssertEqual(sent(model), [])
    }
}

/// A drop as AppKit describes it to a destination; never passed to a super call.
@MainActor
private final class FakeDrop: NSObject, @preconcurrency NSDraggingInfo {
    let draggingSource: Any?
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(source: Any?, board: NSPasteboard, location: NSPoint) {
        draggingSource = source
        draggingPasteboard = board
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
