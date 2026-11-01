import AppKit
import XCTest

@testable import CompanionKit

/// Sealed-object controls on a mounted page in an isolated window.
@MainActor
final class SealedMoveHandleTests: XCTestCase {
    private final class HandoffWindow: NSWindow {
        var refusesPageHandoff = false

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if refusesPageHandoff, responder is InkTextView { return false }
            return super.makeFirstResponder(responder)
        }
    }

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
        let window = HandoffWindow(
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
        var next: NSEvent? = follow
        page.textView.handlePressEventSource = { defer { next = nil }; return next }
        defer { page.textView.handlePressEventSource = nil }
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

    func testMoveCopyAndMoreUseSeparateTargetsOnTheSecondaryRow() throws {
        let text = cell("text")
        let frame = NSRect(x: 10, y: 10, width: 320, height: 70)
        let move = try XCTUnwrap(text.moveHandleRect(in: frame))
        let copy = try XCTUnwrap(text.copyRect(in: frame))
        let more = SealedBlockCell.actionsRect(in: frame)
        XCTAssertEqual(move.maxX + 6, copy.minX)
        XCTAssertEqual(copy.maxX + 6, more.minX)
        XCTAssertEqual(move.size, NSSize(width: 24, height: 24))
        XCTAssertEqual(copy.size, NSSize(width: SealedBlockCell.copyControlWidth, height: 24))
        for rect in [move, copy, more] { XCTAssertTrue(frame.contains(rect)) }
        XCTAssertFalse(move.intersects(copy))
        XCTAssertFalse(copy.intersects(more))
    }

    func testNarrowObjectsKeepMoreAndCanStillMoveWithoutACopyControl() throws {
        let text = cell("text")
        let frame = NSRect(x: 0, y: 0, width: 90, height: 70)
        XCTAssertNil(text.copyRect(in: frame))
        XCTAssertNotNil(text.moveHandleRect(in: frame))
        XCTAssertTrue(frame.contains(SealedBlockCell.actionsRect(in: frame)))
        let tiny = NSRect(x: 0, y: 0, width: 30, height: 70)
        XCTAssertTrue(tiny.contains(SealedBlockCell.actionsRect(in: tiny)))
    }

    func testUnavailableKindsStillOfferStructuralMove() throws {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 70)
        let file = cell("file")
        XCTAssertNil(file.copyRect(in: frame))
        let move = try XCTUnwrap(file.moveHandleRect(in: frame))
        XCTAssertEqual(move.maxX + 6, SealedBlockCell.actionsRect(in: frame).minX)
    }

    func testControlsAndCursorTargetsAreAvailableWithoutPriorHover() throws {
        let page = try mountPage(on: try makeModel())
        let textView = page.textView
        let (move, copy, frame) = try handles(page)
        XCTAssertTrue(textView.drawsHandles(at: object))
        XCTAssertEqual(textView.moveHandleCursorRects, [move])
        XCTAssertEqual(textView.decryptedDragCursorRects, [copy])
        hover(page, at: mid(frame))
        hover(page, at: nil)
        XCTAssertEqual(textView.moveHandleCursorRects, [move])
        textView.setSelectedRange(NSRange(location: object, length: 1))
        XCTAssertEqual(textView.moveHandleCursorRects, [move])
        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertEqual(textView.moveHandleCursorRects, [])
        XCTAssertTrue(page.window.makeFirstResponder(textView))
        XCTAssertEqual(textView.moveHandleCursorRects, [move])
    }

    func testMixedSelectionDrawsTheSealedObjectWithSelectedForeground() throws {
        let page = try mountPage(on: try makeModel())
        let view = page.textView
        let cell = try XCTUnwrap(view.chipCell(at: object))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(cell.lastDrawnSelected, false)
        view.selectAll(nil)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(view.selectedRange().length, 1)
        XCTAssertEqual(cell.lastDrawnSelected, true)
        XCTAssertEqual(cell.lastDrawnShowsControls, true)
    }

    func testHoverAndSelectionDoNotChangeObjectLayout() throws {
        let page = try mountPage(on: try makeModel())
        let textView = page.textView
        let container = try XCTUnwrap(textView.textContainer)
        let manager = try XCTUnwrap(textView.layoutManager)
        let cell = try XCTUnwrap(textView.chipCell(at: object))
        let frame = try XCTUnwrap(textView.chipFrame(at: object))
        let used = manager.usedRect(for: container)
        let size = cell.cellSize()
        func draw() throws -> NSRect {
            let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
            textView.cacheDisplay(in: textView.bounds, to: rep)
            return try XCTUnwrap(cell.lastDrawnFrame)
        }
        let resting = try draw()
        hover(page, at: mid(frame))
        XCTAssertEqual(try draw(), resting)
        textView.setSelectedRange(NSRange(location: object, length: 1))
        XCTAssertEqual(try draw(), resting)
        XCTAssertEqual(textView.chipFrame(at: object), frame)
        XCTAssertEqual(manager.usedRect(for: container), used)
        XCTAssertEqual(cell.cellSize(), size)
        XCTAssertEqual(resting.height, cell.preferredBounds(available: frame.width).height, accuracy: 0.5)
        let row = try XCTUnwrap(cell.namedRow(in: frame, editingWidth: 60))
        for control in [try XCTUnwrap(cell.moveHandleRect(in: frame)), try XCTUnwrap(cell.copyRect(in: frame))] {
            XCTAssertGreaterThanOrEqual(control.minY, row.geometry.name.maxY + 8)
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
        defer { page.coordinator.endPageDrag() }

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
        let frame = NSRect(x: 10, y: 10, width: 400, height: SealedBlockCell.preferredHeight)
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

    func testAPlainCopyControlClickCopiesOnceAndSelectsTheObject() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let (_, copy, _) = try handles(page)
        var sessions = 0
        page.textView.dragSessionWitness = { _, _ in sessions += 1 }
        try press(page, at: mid(copy), then: try mouseEvent(.leftMouseUp, page, at: mid(copy)))
        XCTAssertEqual(sessions, 0)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: object, length: 1))
        XCTAssertNotNil(page.textView.copyBeat)
        XCTAssertEqual(sent(model).count, 1)
    }

    func testAccessibilityButtonsHaveUsefulNamesAndRealPressActions() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let textView = page.textView
        let (_, copy, frame) = try handles(page)
        let more = SealedBlockCell.actionsRect(in: frame)
        let elements = textView.handleAccessibilityElements
        XCTAssertEqual(elements.map { $0.accessibilityLabel() },
                       ["Copy Decrypted", "Sealed Content Actions"])
        XCTAssertEqual(elements.map { $0.accessibilityFrame() },
                       [copy, more].map { onScreen($0, in: page) })
        for element in elements {
            XCTAssertEqual(element.accessibilityRole(), .button)
            XCTAssertTrue((element.accessibilityParent() as AnyObject?) === textView)
        }
        XCTAssertTrue(elements[0].accessibilityPerformPress())
        XCTAssertEqual(textView.selectedRange(), NSRange(location: object, length: 1))
        XCTAssertEqual(sent(model).count, 1)
        var presented: NSMenu?
        page.coordinator.chipMenuPresenter = { menu, _, _ in presented = menu }
        XCTAssertTrue(elements[1].accessibilityPerformPress())
        XCTAssertTrue(try XCTUnwrap(presented).items.contains { $0.title == "Copy Decrypted Contents" })
        hover(page, at: nil)
        XCTAssertEqual(textView.handleAccessibilityElements.count, 2)
        textView.handlesMayHaveMoved()
        for (first, second) in zip(elements, textView.handleAccessibilityElements) {
            XCTAssertTrue(first === second)
        }
        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertFalse(elements[0].accessibilityPerformPress())
    }

    func testAccessibilityHelpGivesEachControlsGuidanceAndObjectIdentity() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let view = page.textView
        let cell = try XCTUnwrap(view.chipCell(at: object))
        let chip = cell.info.chipId
        XCTAssertTrue(model.setChipName("API_KEY", chip: chip, sheet: page.sheet))
        XCTAssertTrue(model.applyNoteOps(
            chip: chip, json: #"[{"ins":{"at":0,"text":"Rotate monthly"}}]"#,
            intent: .typing, selection: nil))
        model.restateChipFace(chip, sheet: page.sheet)
        view.handlesMayHaveMoved()
        let elements = view.handleAccessibilityElements
        XCTAssertEqual(elements.map { $0.accessibilityLabel() },
                       ["Copy Decrypted", "Sealed Content Actions", "Note"])
        let helpKeys = ["chip.control.copy.help", "chip.control.actions.help", "chip.control.note.help"]
        let identity = try XCTUnwrap(view.chipCell(at: object)?.accessibilityLabel())
        XCTAssertTrue(identity.contains("API_KEY"))
        for (element, key) in zip(elements, helpKeys) {
            XCTAssertEqual(element.accessibilityHelp(), CompanionL10n.string(key) + "\n" + identity)
        }
    }

    func testAccessibilityFramesFollowTheirControlsWhenTheWindowMoves() throws {
        let page = try mountPage(on: try makeModel())
        page.window.setFrameOrigin(NSPoint(x: 300, y: 200))
        let textView = page.textView
        let (_, copy, frame) = try handles(page)
        let controls = [copy, SealedBlockCell.actionsRect(in: frame)]
        let elements = textView.handleAccessibilityElements
        XCTAssertEqual(elements.count, 2)
        for (element, rect) in zip(elements, controls) {
            XCTAssertEqual(element.accessibilityFrame(), onScreen(rect, in: page))
        }
        page.window.setFrameOrigin(NSPoint(x: 120, y: 640))
        XCTAssertEqual(elements.map { $0.accessibilityFrame() }, controls.map { onScreen($0, in: page) })
    }

    func testNarrowObjectsMoveThroughNativeCutAndPasteActions() throws {
        let model = try makeModel()
        let page = try mountPage(on: model, width: 90)
        let view = page.textView
        let frame = try XCTUnwrap(view.chipFrame(at: object))
        let cell = try XCTUnwrap(view.chipCell(at: object))
        let chip = cell.info.chipId
        XCTAssertNil(cell.moveHandleRect(in: frame))
        XCTAssertNil(cell.copyRect(in: frame))
        XCTAssertEqual(view.handleAccessibilityElements.map { $0.accessibilityLabel() }, ["Sealed Content Actions"])
        view.setSelectedRange(NSRange(location: object, length: 1))
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.cut(_:)), to: view, from: nil))
        XCTAssertNil(view.chipIndex(ofChip: chip))
        XCTAssertNotNil(model.activeCut)
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.paste(_:)), to: view, from: nil))
        XCTAssertEqual(view.chipIndex(ofChip: chip), end)
        XCTAssertNil(model.activeCut)
        XCTAssertEqual(view.string, "ab  cd\u{FFFC}")
        XCTAssertEqual(sent(model), [])
    }

    func testRenderSealedObjectPreviewsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["ONETIMEPAD_SEALED_PREVIEW_DIR"] else {
            throw XCTSkip("set ONETIMEPAD_SEALED_PREVIEW_DIR to render synthetic sealed-object previews")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let original = InkStyle.typeface
        defer { InkStyle.typeface = original }
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for size in [13.0, 40.0] {
                for width in [CGFloat(260), 680] {
                    let model = try makeModel()
                    model.fontSize = size
                    let page = try mountPage(on: model, width: width)
                    page.window.appearance = NSAppearance(named: appearance)
                    page.textView.appearance = NSAppearance(named: appearance)
                    page.textView.drawsBackground = true
                    page.textView.backgroundColor = .windowBackgroundColor
                    let cell = try XCTUnwrap(page.textView.chipCell(at: object))
                    XCTAssertTrue(model.setChipName("API_KEY", chip: cell.info.chipId, sheet: page.sheet))
                    XCTAssertTrue(model.applyNoteOps(
                        chip: cell.info.chipId, json: #"[{"ins":{"at":0,"text":"Rotate monthly"}}]"#,
                        intent: .typing, selection: nil))
                    model.restateChipFace(cell.info.chipId, sheet: page.sheet)
                    page.coordinator.applyTypeface(model.typeface)
                    page.textView.layoutManager?.ensureLayout(for: try XCTUnwrap(page.textView.textContainer))
                    for selected in [false, true] {
                        page.textView.setSelectedRange(NSRange(location: selected ? object : 0, length: selected ? 1 : 0))
                        let capture = NSRect(x: 0, y: 0, width: page.textView.bounds.width, height: 200)
                        let rep = try XCTUnwrap(page.textView.bitmapImageRepForCachingDisplay(in: capture))
                        page.textView.cacheDisplay(in: capture, to: rep)
                        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        let name = "\(appearanceName)-\(Int(size))pt-\(Int(width))w-\(selected ? "selected" : "resting").png"
                        try data.write(to: output.appendingPathComponent(name))
                    }
                }
            }
        }
    }
    func testReadOnlyEditorsRenderStatusWithoutActionControls() throws {
        let page = try mountPage(on: try makeModel())
        page.coordinator.updateEditability(of: page.textView, to: false)
        let cell = try XCTUnwrap(page.textView.chipCell(at: object))
        let bitmap = try XCTUnwrap(page.textView.bitmapImageRepForCachingDisplay(in: page.textView.bounds))
        page.textView.cacheDisplay(in: page.textView.bounds, to: bitmap)
        XCTAssertEqual(cell.lastDrawnShowsControls, false)
        XCTAssertTrue(page.textView.handleAccessibilityElements.isEmpty)
        XCTAssertTrue(page.textView.decryptedDragCursorRects.isEmpty)
        XCTAssertTrue(page.textView.moveHandleCursorRects.isEmpty)
    }

    func testHandlePressCancelsWhenTheEditorLeavesItsWindowBeforeRelease() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let (_, copy, _) = try handles(page)
        let point = mid(copy)
        let release = try mouseEvent(.leftMouseUp, page, at: point)
        let down = try mouseEvent(.leftMouseDown, page, at: point)
        page.textView.handlePressEventSource = {
            page.textView.removeFromSuperview()
            return release
        }
        defer { page.textView.handlePressEventSource = nil }
        page.textView.mouseDown(with: down)
        XCTAssertTrue(sent(model).isEmpty)
        XCTAssertNil(page.textView.copyBeat)
    }

    func testHandlePressCancelsWhenTheEditorBecomesReadOnlyBeforeRelease() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let (_, copy, _) = try handles(page)
        let point = mid(copy)
        let release = try mouseEvent(.leftMouseUp, page, at: point)
        page.textView.handlePressEventSource = {
            page.textView.isEditable = false
            return release
        }
        defer { page.textView.handlePressEventSource = nil }
        page.textView.mouseDown(with: try mouseEvent(.leftMouseDown, page, at: point))
        XCTAssertTrue(sent(model).isEmpty)
        XCTAssertNil(page.textView.copyBeat)
    }

    func testHandlePressAllowsWindowActivationBeforeRelease() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let (_, copy, _) = try handles(page)
        let point = mid(copy)
        let release = try mouseEvent(.leftMouseUp, page, at: point)
        var context = (applicationActive: false, windowKey: false, windowVisible: false)
        page.textView.handlePressContextSource = { context }
        page.textView.handlePressEventSource = {
            context = (true, true, true)
            return release
        }
        defer {
            page.textView.handlePressContextSource = nil
            page.textView.handlePressEventSource = nil
        }
        page.textView.mouseDown(with: try mouseEvent(.leftMouseDown, page, at: point))
        XCTAssertEqual(sent(model), ["clipboard"])
        XCTAssertNotNil(page.textView.copyBeat)
    }

    func testHandlePressCancelsAfterLosingObservedActivation() throws {
        for loss in [(false, true, true), (true, false, true), (true, true, false)] {
            let model = try makeModel()
            let page = try mountPage(on: model)
            let (_, copy, _) = try handles(page)
            let point = mid(copy)
            let stationary = try mouseEvent(.leftMouseDragged, page, at: point)
            let release = try mouseEvent(.leftMouseUp, page, at: point)
            var context = (applicationActive: false, windowKey: false, windowVisible: false)
            var eventCount = 0
            page.textView.handlePressContextSource = { context }
            page.textView.handlePressEventSource = {
                eventCount += 1
                context = eventCount == 1 ? (true, true, true) : loss
                return eventCount == 1 ? stationary : release
            }
            defer {
                page.textView.handlePressContextSource = nil
                page.textView.handlePressEventSource = nil
            }
            page.textView.mouseDown(with: try mouseEvent(.leftMouseDown, page, at: point))
            XCTAssertEqual(eventCount, 2)
            XCTAssertTrue(sent(model).isEmpty)
            XCTAssertNil(page.textView.copyBeat)
        }
    }

    func testCopyAcknowledgementFollowsItsObjectAndEndsWithOneShotTimer() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let chip = try XCTUnwrap(page.textView.chipCell(at: object)?.info.chipId)
        let beforeScheduling = Date()
        page.textView.beginCopyBeat(at: object)
        let afterScheduling = Date()
        let timer = try XCTUnwrap(page.textView.copyBeatTimerForTests)
        XCTAssertTrue(timer.isValid)
        XCTAssertGreaterThanOrEqual(timer.fireDate.timeIntervalSince(beforeScheduling),
                                    SealedBlockCell.beatDuration - 0.05)
        XCTAssertLessThanOrEqual(timer.fireDate.timeIntervalSince(afterScheduling),
                                 SealedBlockCell.beatDuration + 0.05)
        page.textView.insertText("prefix ", replacementRange: NSRange(location: 0, length: 0))
        let moved = try XCTUnwrap(page.textView.chipIndex(ofChip: chip))
        XCTAssertNotEqual(moved, object)
        let cell = try XCTUnwrap(page.textView.chipCell(at: moved))
        let manager = try XCTUnwrap(page.textView.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(page.textView.textContainer))
        let frame = try XCTUnwrap(page.textView.chipFrame(at: moved))
        let image = NSImage(size: page.textView.bounds.size)
        image.lockFocus()
        cell.draw(withFrame: frame, in: page.textView, characterIndex: moved, layoutManager: manager)
        image.unlockFocus()
        XCTAssertEqual(cell.lastDrawnCopied, true)
        timer.fire()
        XCTAssertFalse(timer.isValid)
        XCTAssertNil(page.textView.copyBeat)
        XCTAssertNil(page.textView.copyBeatTimerForTests)
    }

    func testAccessibilityCopyCommitsAValidNameAndRefusesAnInvalidDraft() throws {
        for draft in ["API_KEY", "not.valid"] {
            let model = try makeModel()
            let page = try mountPage(on: model)
            let copy = try XCTUnwrap(page.textView.handleAccessibilityElements.first {
                $0.accessibilityLabel() == "Copy Decrypted"
            })
            page.coordinator.beginNaming(at: object)
            let name = try XCTUnwrap(page.coordinator.nameEditor)
            name.draft = draft
            page.textView.handlesMayHaveMoved()
            XCTAssertTrue(copy.isAccessibilityEnabled())
            let valid = draft == "API_KEY"
            XCTAssertEqual(copy.accessibilityPerformPress(), valid)
            XCTAssertEqual(sent(model).count, valid ? 1 : 0)
            XCTAssertEqual(name.isOpen, !valid)
            if valid { XCTAssertEqual(page.textView.chipCell(at: object)?.info.name, draft) }
            else { XCTAssertNotNil(name.rename.error) }
        }
    }

    func testAccessibilityCopyYieldsToATextFieldInAnotherWindow() throws {
        let model = try makeModel()
        let page = try mountPage(on: model)
        let copy = try XCTUnwrap(page.textView.handleAccessibilityElements.first {
            $0.accessibilityLabel() == "Copy Decrypted"
        })
        page.coordinator.beginNaming(at: object)
        let name = try XCTUnwrap(page.coordinator.nameEditor)
        name.draft = "API_KEY"
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        other.contentView?.addSubview(field)
        XCTAssertTrue(other.makeFirstResponder(field))
        page.textView.keyWindowSourceForTests = { other }
        defer { page.textView.keyWindowSourceForTests = nil }
        page.textView.handlesMayHaveMoved()
        XCTAssertFalse(copy.isAccessibilityEnabled())
        XCTAssertFalse(copy.accessibilityPerformPress())
        XCTAssertTrue(sent(model).isEmpty)
        XCTAssertTrue(name.isOpen)
    }

    func testNameSeatFollowsItsObjectBeforeTheDeferredFieldRelayout() throws {
        let page = try mountPage(on: try makeModel())
        page.coordinator.beginNaming(at: object)
        let original = try XCTUnwrap(page.textView.naming)
        page.textView.insertText("prefix ", replacementRange: NSRange(location: 0, length: 0))
        let moved = try XCTUnwrap(page.textView.chipIndex(ofChip: original.chip))
        XCTAssertNotEqual(moved, original.index)
        let cell = try XCTUnwrap(page.textView.chipCell(at: moved))
        let manager = try XCTUnwrap(page.textView.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(page.textView.textContainer))
        let frame = try XCTUnwrap(page.textView.chipFrame(at: moved))
        let image = NSImage(size: page.textView.bounds.size)
        image.lockFocus()
        cell.draw(withFrame: frame, in: page.textView, characterIndex: moved, layoutManager: manager)
        image.unlockFocus()
        XCTAssertEqual(cell.lastDrawnEditingWidth, original.width)
    }

    func testAccessibilityEnablementFollowsNameDraftAndFocusLifecycle() throws {
        let page = try mountPage(on: try makeModel())
        let copy = try XCTUnwrap(page.textView.handleAccessibilityElements.first {
            $0.accessibilityLabel() == SealedBlockCell.decryptedDragWords
        })
        XCTAssertTrue(copy.isAccessibilityEnabled())
        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertFalse(copy.isAccessibilityEnabled())
        page.coordinator.beginNaming(at: object)
        let name = try XCTUnwrap(page.coordinator.nameEditor)
        XCTAssertTrue(copy.isAccessibilityEnabled())
        name.draft = "API_KEY"
        XCTAssertTrue(name.commit(returningKeys: false))
        XCTAssertFalse(name.isOpen)
        XCTAssertTrue(page.textView.answersChords)
        XCTAssertTrue(copy.isAccessibilityEnabled())
        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertFalse(page.textView.answersChords)
        XCTAssertFalse(copy.isAccessibilityEnabled())
        XCTAssertFalse(copy.accessibilityPerformPress())
        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        drainMainQueue()
        XCTAssertTrue(copy.isAccessibilityEnabled())
    }

    func testRefusedPageHandoffLeavesTheOpenNoteInPlace() throws {
        let page = try mountPage(on: try makeModel())
        page.coordinator.beginNote(at: object)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        XCTAssertTrue(note.isOpen)
        let responder = page.window.firstResponder
        let window = try XCTUnwrap(page.window as? HandoffWindow)
        window.refusesPageHandoff = true
        XCTAssertFalse(page.coordinator.prepareChipAction())
        XCTAssertTrue(note.isOpen)
        XCTAssertTrue(page.window.firstResponder === responder)
    }

}
