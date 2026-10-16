import AppKit
import XCTest

@testable import CompanionKit

/// The move handle on a sealed block (Law 0001's move drag row; issue 255): its seat beside
/// the decrypted drag handle, when the two are drawn, what a press on it starts, and how
/// VoiceOver names each, driven against a mounted page in a window of the test's own.
@MainActor
final class SealedMoveHandleTests: XCTestCase {
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
    private let placeholder = "[sealed content · tiny]"

    /// A model of the test's own, whose ordinary pasteboard is a private one.
    private func makeModel() throws -> PageModel {
        let client = CompanionClient.ephemeral(tag: UUID().uuidString)
        let suite = "companion-move-handle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-move-handle-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
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
    private func mountPage(on model: PageModel, width: CGFloat = 520) throws -> Page {
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let sheet = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: sheet, coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentLayoutRect)
        let scroll = InkEditorView.bareScroller()
        scroll.frame = NSRect(x: 0, y: 40, width: width, height: 360)
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

    /// The pointer over `point` in the text view, or gone when nil.
    private func hover(_ page: Page, at point: NSPoint?, holdsKeys: Bool = true) {
        let away = NSPoint(x: -10_000, y: -10_000)
        page.textView.hoverRefreshInput = (
            page.window.convertPoint(toScreen: page.textView.convert(point ?? away, to: nil)),
            holdsKeys, point != nil)
        page.textView.refreshHover()
    }

    private func handles(_ page: Page) throws -> (move: NSRect, decrypted: NSRect, frame: NSRect) {
        let frame = try XCTUnwrap(page.textView.chipFrame(at: object))
        let cell = try XCTUnwrap(page.textView.chipCell(at: object))
        return (
            try XCTUnwrap(cell.moveHandleRect(in: frame), "no move handle"),
            try XCTUnwrap(cell.decryptedDragRect(in: frame), "no decrypted handle"), frame)
    }

    private func cell(_ kind: String) -> SealedBlockCell {
        SealedBlockCell(info: ChipInfo(
            chipId: 1, kind: kind, excerpt: "n0…3t", sizeLabel: "tiny", concealed: false))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, _ page: Page, at point: NSPoint
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: page.textView.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: page.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
    }

    private func dragEvent(_ page: Page, at point: NSPoint) throws -> NSEvent {
        try mouseEvent(.leftMouseDragged, page, at: point)
    }

    /// A press at `point` whose next event is `follow`, a lift or a move, through `mouseDown`.
    private func press(_ page: Page, at point: NSPoint, then follow: NSEvent) throws {
        page.window.postEvent(follow, atStart: true)
        page.textView.mouseDown(with: try mouseEvent(.leftMouseDown, page, at: point))
    }

    private func mid(_ rect: NSRect) -> NSPoint { NSPoint(x: rect.midX, y: rect.midY) }

    /// `rect`, drawn in the page's text view, on the screen, the space VoiceOver's frames are in.
    private func onScreen(_ rect: NSRect, in page: Page) -> NSRect {
        page.window.convertToScreen(page.textView.convert(rect, to: nil))
    }

    private func sent(_ model: PageModel) -> [String] {
        model.coreClient.ledger().filter { $0.event == "sent" }.map(\.destination)
    }

    // MARK: The seat

    /// The move handle sits a gap before the decrypted handle on the same row, the two
    /// never overlapping, and it is as wide as its glyph and the handles' inset each side.
    func testTheMoveHandleSitsAGapBeforeTheDecryptedHandleWithoutOverlap() throws {
        let words: CGFloat = 76
        let label: CGFloat = 92
        let glyph: CGFloat = 7
        let frame = NSRect(x: 10, y: 10, width: 320, height: SealedBlockCell.blockHeight)
        let metrics = SealedBlockLayout.metrics(containerWidth: frame.width)
        let decrypted = try XCTUnwrap(
            SealedBlockCell.decryptedDragRect(in: frame, wordsWidth: words, labelWidth: label))
        let move = try XCTUnwrap(SealedBlockCell.moveHandleRect(
            in: frame, glyphWidth: glyph, labelWidth: label, neighbourMinX: decrypted.minX))
        XCTAssertEqual(move.maxX, decrypted.minX - metrics.handleGap)
        XCTAssertEqual(move.minY, decrypted.minY)
        XCTAssertEqual(move.height, decrypted.height)
        XCTAssertEqual(move.width, glyph + metrics.handleInset * 2)
        XCTAssertFalse(move.intersects(decrypted))
        XCTAssertLessThan(move.minX, decrypted.minX, "the move handle is the inner one")

        let leastDecrypted = metrics.horizontalPadding * 2 + metrics.lockSize
            + metrics.lockToLabelGap + label + metrics.handleGap * 2 + words
            + metrics.handleInset * 2 + metrics.actionsWidth
        let leastBoth = leastDecrypted + metrics.handleGap + glyph + metrics.handleInset * 2
        func moveHandle(at width: CGFloat) -> NSRect? {
            let narrow = NSRect(x: 10, y: 10, width: width, height: frame.height)
            let neighbour = SealedBlockCell.decryptedDragRect(
                in: narrow, wordsWidth: words, labelWidth: label)
            return SealedBlockCell.moveHandleRect(
                in: narrow, glyphWidth: glyph, labelWidth: label,
                neighbourMinX: (neighbour ?? SealedBlockCell.actionsRect(in: narrow)).minX)
        }
        XCTAssertNotNil(moveHandle(at: leastBoth))
        XCTAssertNil(moveHandle(at: leastBoth - 1), "the move handle would meet the classification")
        XCTAssertNotNil(
            SealedBlockCell.decryptedDragRect(
                in: NSRect(x: 10, y: 10, width: leastBoth - 1, height: frame.height),
                wordsWidth: words, labelWidth: label),
            "the decrypted handle still stands where the move handle has gone")
    }

    /// On a narrow block the move handle gives way first, and once the decrypted handle has
    /// gone too the move handle does not come back into the seat it left (Law 0001, move drag row).
    func testTheMoveHandleGivesWayBeforeTheDecryptedHandleAndNeverTakesItsSeat() {
        let text = cell("text")
        var moveOnly = 0
        var decryptedOnly = 0
        var both = 0
        for width in stride(from: CGFloat(100), through: 480, by: 1) {
            let frame = NSRect(x: 0, y: 0, width: width, height: SealedBlockCell.blockHeight)
            let move = text.moveHandleRect(in: frame)
            let decrypted = text.decryptedDragRect(in: frame)
            switch (move, decrypted) {
            case (.some, .none): moveOnly += 1
            case (.none, .some): decryptedOnly += 1
            case (.some, .some): both += 1
            case (.none, .none): break
            }
        }
        XCTAssertEqual(moveOnly, 0, "a move handle drawn with no decrypted handle beside it")
        XCTAssertGreaterThan(decryptedOnly, 0, "no width lost the move handle alone")
        XCTAssertGreaterThan(both, 0, "no width held both")
    }

    /// A kind this build cannot drag decrypted has no decrypted handle, so its move handle
    /// sits where that one would: a gap before the actions seat.
    func testAKindWithNoDecryptedHandleSeatsTheMoveHandleBeforeTheActions() throws {
        let frame = NSRect(x: 0, y: 0, width: 400, height: SealedBlockCell.blockHeight)
        let metrics = SealedBlockLayout.metrics(containerWidth: frame.width)
        let file = cell("file")
        XCTAssertNil(file.decryptedDragRect(in: frame))
        XCTAssertNil(file.handleRect(.decrypted, in: frame))
        let move = try XCTUnwrap(file.handleRect(.move, in: frame))
        XCTAssertEqual(move, file.moveHandleRect(in: frame))
        XCTAssertEqual(move.maxX, SealedBlockCell.actionsRect(in: frame).minX - metrics.handleGap)
    }

    // MARK: When the handles are drawn

    /// The move handle exists while the block is hovered or selected and not otherwise, and
    /// its open hand goes with the decrypted handle's while a field holds the keys.
    func testTheMoveHandleExistsOnHoverOrSelectionAndNotOtherwise() throws {
        let page = try mountPage(on: try makeModel())
        let textView = page.textView
        let (move, decrypted, frame) = try handles(page)
        XCTAssertFalse(textView.drawsHandles(at: object), "at rest")
        XCTAssertEqual(textView.moveHandleCursorRects, [])

        hover(page, at: NSPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(textView.drawsHandles(at: object), "hovered")
        XCTAssertEqual(textView.moveHandleCursorRects, [move])
        XCTAssertEqual(textView.decryptedDragCursorRects, [decrypted])
        hover(page, at: NSPoint(x: frame.midX, y: frame.midY), holdsKeys: false)
        XCTAssertFalse(textView.drawsHandles(at: object), "the hover left with the keys")
        XCTAssertEqual(textView.moveHandleCursorRects, [])

        hover(page, at: nil)
        textView.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertFalse(textView.drawsHandles(at: object), "ink is selected")
        textView.setSelectedRange(NSRange(location: object, length: 0))
        XCTAssertFalse(textView.drawsHandles(at: object), "a caret before the block")
        textView.setSelectedRange(NSRange(location: object, length: 1))
        XCTAssertTrue(textView.drawsHandles(at: object), "selected")
        XCTAssertEqual(textView.moveHandleCursorRects, [move])

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertEqual(textView.moveHandleCursorRects, [], "under the field")
        XCTAssertTrue(page.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: object, length: 1))
        XCTAssertEqual(textView.moveHandleCursorRects, [move], "the hand came back")
    }

    /// Hovering and selecting a block draws its handles without moving its text or
    /// changing its height, and the handles keep off the lock, the classification, the
    /// actions seat and the bottom row (Law 0001, presentation invariants).
    func testTheHandlesChangeNoLayout() throws {
        let page = try mountPage(on: try makeModel())
        let textView = page.textView
        let container = try XCTUnwrap(textView.textContainer)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let cell = try XCTUnwrap(textView.chipCell(at: object))
        func draw() throws -> NSRect {
            let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
            textView.cacheDisplay(in: textView.bounds, to: rep)
            return try XCTUnwrap(cell.lastDrawnFrame)
        }
        let restingFrame = try XCTUnwrap(textView.chipFrame(at: object))
        let restingUsed = layoutManager.usedRect(for: container)
        let restingSize = cell.cellSize()
        let restingDrawn = try draw()

        hover(page, at: NSPoint(x: restingFrame.midX, y: restingFrame.midY))
        XCTAssertTrue(textView.drawsHandles(at: object))
        XCTAssertEqual(try draw(), restingDrawn, "hover moved the block")
        textView.setSelectedRange(NSRange(location: object, length: 1))
        XCTAssertEqual(try draw(), restingDrawn, "selection moved the block")
        XCTAssertEqual(textView.chipFrame(at: object), restingFrame)
        XCTAssertEqual(layoutManager.usedRect(for: container), restingUsed)
        XCTAssertEqual(cell.cellSize(), restingSize)
        XCTAssertEqual(restingDrawn.height, SealedBlockCell.blockHeight, accuracy: 0.5)

        let (move, decrypted, frame) = try handles(page)
        let layout = SealedBlockCell.contentLayout(in: frame)
        let labelEnd = layout.labelOrigin.x + layout.metrics.handleGap
        for handle in [move, decrypted] {
            XCTAssertFalse(handle.intersects(layout.lockRect))
            XCTAssertGreaterThan(handle.minX, labelEnd, "a handle over the classification")
            XCTAssertFalse(handle.intersects(SealedBlockCell.actionsRect(in: frame)))
            XCTAssertLessThanOrEqual(handle.maxY, layout.rowBand.minY, "a handle in the bottom row")
            XCTAssertTrue(frame.contains(handle))
        }
    }

    // MARK: The press

    /// A drag from the move handle is the page's own drag of the selected object: one item,
    /// the copy's fragment and its public text, with no plaintext written and no decrypted
    /// drag begun (Law 0001, move drag row; the drag and plain drag rows).
    func testADragFromTheMoveHandleIsThePagesOwnDragAndNoDecryptedOne() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let textView = page.textView
        let (move, _, _) = try handles(page)
        var sessions: [(items: [NSDraggingItem], source: NSDraggingSource)] = []
        textView.dragSessionWitness = { sessions.append(($0, $1)) }

        textView.beginMoveDrag(
            chipAt: object, event: try dragEvent(page, at: NSPoint(x: move.midX, y: move.midY)))

        XCTAssertEqual(textView.selectedRange(), NSRange(location: object, length: 1))
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertTrue(session.source === textView, "the page is the drag's source")
        XCTAssertFalse(session.source is DecryptedDrag)
        XCTAssertNil(page.coordinator.decryptedDrag)
        XCTAssertTrue(page.coordinator.dragsPageSelection)
        XCTAssertEqual(session.items.count, 1)
        let item = try XCTUnwrap(session.items.first?.item as? NSPasteboardItem)
        XCTAssertEqual(item.types, [SealedFragment.pasteboardType, .string])
        XCTAssertEqual(item.string(forType: .string), placeholder)

        let board = privateBoard()
        XCTAssertTrue(board.writeObjects([item]))
        let written = (board.types ?? []).compactMap { board.data(forType: $0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        XCTAssertFalse(written.contains(secret), written)
        XCTAssertEqual(sent(model), [], "a move recorded a declassification")
    }

    /// A block inside a wider selection draws its move handle on hover, and a drag from
    /// that handle takes the whole selection, as a drag from the block's face does: the
    /// fragment is the run of ink and the object (Law 0001, move drag row).
    func testTheMoveHandleDragsTheSelectionTheBlockIsIn() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let textView = page.textView
        let (move, _, frame) = try handles(page)
        let run = NSRange(location: 0, length: object + 1)
        textView.setSelectedRange(run)
        hover(page, at: NSPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(textView.drawsHandles(at: object), "hovered inside a wider selection")
        var sessions: [[NSDraggingItem]] = []
        textView.dragSessionWitness = { items, _ in sessions.append(items) }
        defer { page.coordinator.endPageDrag() }

        textView.beginMoveDrag(
            chipAt: object, event: try dragEvent(page, at: NSPoint(x: move.midX, y: move.midY)))

        XCTAssertEqual(textView.selectedRange(), run, "the selection collapsed to the block")
        XCTAssertEqual(sessions.count, 1)
        let item = try XCTUnwrap(sessions.first?.first?.item as? NSPasteboardItem)
        XCTAssertEqual(item.string(forType: .string), "ab \(placeholder)")
        XCTAssertTrue(page.coordinator.dragsPageSelection)
    }

    /// Which handle a press is on: the midpoint of each seat is its handle, and the gap
    /// between them, the lock, the actions seat and the bottom row are on neither.
    func testAPressIsOnTheHandleWhoseSeatItIsIn() throws {
        let frame = NSRect(x: 10, y: 10, width: 400, height: SealedBlockCell.blockHeight)
        let text = cell("text")
        let move = try XCTUnwrap(text.handleRect(.move, in: frame))
        let decrypted = try XCTUnwrap(text.handleRect(.decrypted, in: frame))
        XCTAssertEqual(text.handle(at: mid(move), in: frame), .move)
        XCTAssertEqual(text.handle(at: mid(decrypted), in: frame), .decrypted)
        XCTAssertNil(
            text.handle(at: NSPoint(x: (move.maxX + decrypted.minX) / 2, y: move.midY), in: frame),
            "the gap between the handles")
        XCTAssertNil(text.handle(at: mid(SealedBlockCell.actionsRect(in: frame)), in: frame))
        XCTAssertNil(
            text.handle(at: mid(SealedBlockCell.contentLayout(in: frame).lockRect), in: frame))
        XCTAssertNil(
            text.handle(at: NSPoint(x: move.midX, y: frame.maxY - 4), in: frame), "the bottom row")

        let file = cell("file")
        XCTAssertEqual(file.handle(at: mid(try XCTUnwrap(file.handleRect(.move, in: frame))), in: frame), .move)
        XCTAssertNil(file.handle(at: mid(decrypted), in: frame), "a kind with no decrypted handle")
    }

    /// A press on each handle that moves past the slop starts that handle's drag and no
    /// other, through `mouseDown`: from ⠿ the page's own session, from `drag decrypted`
    /// the decrypted drag (Law 0001, move drag and decrypted drag rows).
    func testAPressOnEachHandleStartsItsOwnDragThroughMouseDown() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let textView = page.textView
        let (move, decrypted, frame) = try handles(page)
        var sources: [NSDraggingSource] = []
        textView.dragSessionWitness = { _, source in sources.append(source) }
        defer { page.coordinator.endPageDrag() }
        hover(page, at: mid(frame))

        let onMove = mid(move)
        try press(page, at: onMove, then: try dragEvent(page, at: NSPoint(x: onMove.x + 12, y: onMove.y)))
        XCTAssertEqual(sources.count, 1)
        XCTAssertTrue(sources.last === textView, "the move handle started another drag")
        XCTAssertNil(page.coordinator.decryptedDrag)
        XCTAssertTrue(page.coordinator.dragsPageSelection)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: object, length: 1))
        page.coordinator.endPageDrag()

        let onDecrypted = mid(decrypted)
        try press(
            page, at: onDecrypted,
            then: try dragEvent(page, at: NSPoint(x: onDecrypted.x + 12, y: onDecrypted.y)))
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources.last is DecryptedDrag, "the decrypted handle started another drag")
        XCTAssertNotNil(page.coordinator.decryptedDrag)
        XCTAssertFalse(page.coordinator.dragsPageSelection)
        XCTAssertEqual(sent(model), [], "no destination asked")
    }

    /// A press on the move handle that lifts before it moves selects the object and
    /// starts no drag, the page's or the decrypted one (Law 0001, move drag row).
    func testAPressOnTheMoveHandleThatLiftsFirstSelectsTheObjectAndDragsNothing() throws {
        let page = try mountPage(on: try makeModel())
        let textView = page.textView
        let (move, _, frame) = try handles(page)
        var sessions = 0
        textView.dragSessionWitness = { _, _ in sessions += 1 }
        hover(page, at: mid(frame))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))

        try press(page, at: mid(move), then: try mouseEvent(.leftMouseUp, page, at: mid(move)))

        XCTAssertEqual(textView.selectedRange(), NSRange(location: object, length: 1))
        XCTAssertEqual(sessions, 0)
        XCTAssertFalse(page.coordinator.dragsPageSelection)
        XCTAssertNil(page.coordinator.decryptedDrag)
    }

    /// The move handle's press is gated as the decrypted handle's is: a first plain press
    /// on a drawn handle, and nothing else.
    func testOnlyAFirstPlainPressOnADrawnMoveHandleStartsTheDrag() {
        XCTAssertTrue(InkTextView.startsHandleDrag(
            onHandle: true, handleShown: true, clickCount: 1, modifierFlags: []))
        XCTAssertFalse(InkTextView.startsHandleDrag(
            onHandle: true, handleShown: false, clickCount: 1, modifierFlags: []))
        XCTAssertFalse(InkTextView.startsHandleDrag(
            onHandle: true, handleShown: true, clickCount: 1, modifierFlags: .option))
        XCTAssertFalse(InkTextView.startsHandleDrag(
            onHandle: false, handleShown: true, clickCount: 1, modifierFlags: []))
    }

    // MARK: VoiceOver

    /// VoiceOver finds one element per drawn handle, *Move* and *Drag decrypted*, each at its
    /// handle's seat under the text view, the same object from one ask to the next; a block
    /// at rest offers none.
    func testVoiceOverNamesBothHandlesAtTheirSeats() throws {
        let page = try mountPage(on: try makeModel())
        let textView = page.textView
        XCTAssertEqual(textView.handleAccessibilityElements(), [], "at rest")
        XCTAssertEqual(
            SealedBlockCell.Handle.move.accessibilityLabel, CompanionL10n.string("chip.handle.move"))
        XCTAssertEqual(
            SealedBlockCell.Handle.decrypted.accessibilityLabel,
            CompanionL10n.string("chip.handle.decrypted"))
        XCTAssertEqual(SealedBlockCell.Handle.move.accessibilityLabel, "Move", "the key is unresolved")
        XCTAssertEqual(SealedBlockCell.Handle.decrypted.accessibilityLabel, "Drag decrypted")

        let (move, decrypted, frame) = try handles(page)
        hover(page, at: NSPoint(x: frame.midX, y: frame.midY))
        let elements = textView.handleAccessibilityElements()
        XCTAssertEqual(elements.map { $0.accessibilityLabel() }, ["Move", "Drag decrypted"])
        XCTAssertEqual(
            elements.map { $0.accessibilityFrame() },
            [move, decrypted].map { onScreen($0, in: page) })
        for element in elements {
            XCTAssertEqual(element.accessibilityRole(), .handle)
            XCTAssertTrue((element.accessibilityParent() as AnyObject?) === textView)
        }
        let again = textView.handleAccessibilityElements()
        XCTAssertEqual(again.count, 2)
        for (first, second) in zip(elements, again) {
            XCTAssertTrue(first === second, "a new element on every ask")
        }
        let children = try XCTUnwrap(textView.accessibilityChildren())
        for element in elements {
            XCTAssertTrue(children.contains { ($0 as AnyObject) === element })
        }

        hover(page, at: nil)
        XCTAssertEqual(textView.handleAccessibilityElements(), [], "the hover left")
        textView.setSelectedRange(NSRange(location: object, length: 1))
        XCTAssertEqual(
            textView.handleAccessibilityElements().map { $0.accessibilityLabel() },
            ["Move", "Drag decrypted"], "the selected block")
    }

    /// Each handle's element answers the screen frame of its seat, the one the VoiceOver
    /// cursor box is drawn around. The text view is flipped, so a parent space frame taken
    /// as drawn would put the box down the block instead of on the top row.
    func testTheHandleElementsAnswerTheScreenFrameOfTheirSeats() throws {
        let page = try mountPage(on: try makeModel())
        page.window.setFrameOrigin(NSPoint(x: 300, y: 200))
        let textView = page.textView
        XCTAssertTrue(textView.isFlipped)
        XCTAssertEqual(
            textView.accessibilityFrame(), onScreen(textView.bounds, in: page), "the parent")

        let (move, decrypted, frame) = try handles(page)
        hover(page, at: NSPoint(x: frame.midX, y: frame.midY))
        let elements = textView.handleAccessibilityElements()
        XCTAssertEqual(elements.count, 2)
        for (element, seat) in zip(elements, [move, decrypted]) {
            let expected = onScreen(seat, in: page)
            let answered = element.accessibilityFrame()
            XCTAssertEqual(answered.minX, expected.minX, accuracy: 0.5, "\(seat)")
            XCTAssertEqual(answered.minY, expected.minY, accuracy: 0.5, "\(seat)")
            XCTAssertEqual(answered.width, expected.width, accuracy: 0.5)
            XCTAssertEqual(answered.height, expected.height, accuracy: 0.5)
            XCTAssertGreaterThan(
                answered.midY, onScreen(frame, in: page).midY,
                "the box is on the bottom half of the block")
        }

        page.window.setFrameOrigin(NSPoint(x: 120, y: 640))
        XCTAssertEqual(
            elements.map { $0.accessibilityFrame() },
            [move, decrypted].map { onScreen($0, in: page) }, "the window moved")
    }
}
