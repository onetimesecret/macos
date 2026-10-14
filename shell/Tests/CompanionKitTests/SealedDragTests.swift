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

    // MARK: The drag's image

    /// An image's pixels, drawn once into a bitmap of its own size.
    private func pixels(_ image: NSImage?) throws -> Data {
        let image = try XCTUnwrap(image, "the drag had no image")
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width),
            pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let bytes = try XCTUnwrap(rep.bitmapData)
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    /// The image of a drag of the whole page: the page drag's own, or AppKit's.
    private func dragImage(_ page: Page, appKits: Bool = false) throws -> Data {
        page.textView.selectAll(nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 60, y: 300), modifierFlags: [],
            timestamp: 0, windowNumber: page.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        var origin = NSPoint.zero
        let image = appKits
            ? page.textView.dragImageForSelection(with: event, origin: &origin)
            : page.textView.pageDragImage(with: event, origin: &origin)
        return try pixels(image)
    }

    /// Other apps see the drag's image pass, so it draws the selection's ink and each
    /// object's face, its size class and any name, but never its excerpt: two objects
    /// that differ only in their contents drag as one image.
    func testTheDragsImageDrawsInkAndEachFaceButNoExcerpt() throws {
        let (model, _) = try makeModel()
        let seal = [NSRange(location: 3, length: 6)]
        let secret = try mountPage(on: model, text: "ab SECRET cd", seals: seal)
        let other = try mountPage(on: model, text: "ab QWERTY cd", seals: seal)
        let ink = try mountPage(on: model, text: "xy SECRET cd", seals: seal)
        let faces = try [secret, other].map { try XCTUnwrap(chips($0).first) }
        XCTAssertNotEqual(faces[0].excerpt, faces[1].excerpt, "the control: the excerpts differ")
        XCTAssertEqual(faces[0].sizeLabel, faces[1].sizeLabel)
        XCTAssertNotEqual(
            try dragImage(secret, appKits: true), try dragImage(other, appKits: true),
            "the control: AppKit's own image draws the excerpt")

        XCTAssertEqual(try dragImage(secret), try dragImage(other), "the image drew an excerpt")
        XCTAssertNotEqual(try dragImage(secret), try dragImage(ink), "the image drew no ink")

        let unnamed = try dragImage(secret)
        for (page, face) in zip([secret, other], faces) {
            XCTAssertTrue(page.model.setChipName("API_KEY", chip: face.chipId, sheet: page.sheet))
        }
        XCTAssertEqual(try dragImage(secret), try dragImage(other), "a named row drew its value")
        XCTAssertNotEqual(try dragImage(secret), unnamed, "the image drew no name")
        XCTAssertFalse(secret.textView.drawsPageDragImage, "the page kept drawing drag faces")
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

        page.coordinator.endPageDrag()
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

        page.coordinator.endPageDrag()
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
        page.coordinator.endPageDrag()
        XCTAssertEqual(shape(page), "zab # cd # ef", "a stale drag's end removed a run")
    }

    // MARK: Between pages

    /// A drag dropped on another page moves there through the core as one
    /// transaction: the same objects with their names, both pages restated, no
    /// `sealed` record, and ⌘Z on the source leaves one of each (ADR-0054).
    func testADragToAnotherPageMovesTheSameObjectsAndTheSourceUndoLeavesOne() throws {
        let (model, _) = try makeModel()
        let source = try mountPage(on: model)
        let ids = chips(source).map(\.chipId)
        XCTAssertTrue(model.setChipName("API_KEY", chip: ids[0], sheet: source.sheet))
        let target = try mountPage(on: model, text: "xy", seals: [])
        _ = try beginDrag(source, NSRange(location: 0, length: 4))
        let records = model.coreClient.ledger().count
        let marks = model.dirtyMarks

        XCTAssertTrue(target.coordinator.dropMovedPageDrag(from: source.coordinator, at: 2, offered: move))
        XCTAssertEqual(shape(target), "xyab #", "the drop did not stand the run")
        XCTAssertEqual(chips(target).map(\.chipId), [ids[0]], "the move took a new identity")
        XCTAssertEqual(chips(target).first?.name, "API_KEY")
        XCTAssertFalse(target.textView.string.contains(placeholder), "the public text landed")
        XCTAssertNotNil(target.coordinator.chipAttachment(at: 5), "the destination was not restated")
        XCTAssertEqual(target.textView.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertEqual(shape(source), " cd # ef", "the move left its source run")
        XCTAssertEqual(source.textView.textStorage?.length, 8, "the source was not restated")
        XCTAssertEqual(source.textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(chips(source).map(\.chipId), [ids[1]])
        XCTAssertEqual(model.coreClient.ledger().count, records, "a move recorded something")
        XCTAssertGreaterThan(model.dirtyMarks, marks, "the move armed no write")

        source.coordinator.endPageDrag()
        XCTAssertEqual(shape(source), " cd # ef", "the session's end removed a run")
        XCTAssertFalse(source.coordinator.dragsPageSelection)
        source.coordinator.step(back: true)
        XCTAssertEqual(shape(source), " cd # ef", "⌘Z on the source stood a run again")
        XCTAssertEqual(
            (chips(source) + chips(target)).map(\.chipId).sorted(), ids.sorted(),
            "an object stands twice")
        target.coordinator.step(back: true)
        XCTAssertEqual(shape(target), "xy", "one ⌘Z on the destination left part of the run")
    }

    /// ⌥, or a source that changed under its drag, pastes the drag's copy fragment on
    /// the other page, cloning its objects, and the source keeps its run (ADR-0054 point 5).
    func testAnOptionOrStaleDragToAnotherPagePastesACopyAndLeavesItsSource() throws {
        let (model, _) = try makeModel()
        let source = try mountPage(on: model)
        let ids = chips(source).map(\.chipId)
        let target = try mountPage(on: model, text: "xy", seals: [])
        let point = target.textView.convert(
            NSPoint(x: 10, y: target.textView.bounds.maxY - 2), to: nil)

        let option = try beginDrag(source, NSRange(location: 0, length: 4))
        let copy = FakeDrag(source: source.textView, board: option, mask: .copy, location: point)
        XCTAssertEqual(target.textView.dropRoute(for: copy), .fragment)
        XCTAssertEqual(target.textView.dragOperation(for: copy, type: .string), .copy)
        XCTAssertTrue(target.textView.performDragOperation(copy))
        source.coordinator.endPageDrag()
        XCTAssertEqual(shape(target), "xyab #")
        XCTAssertFalse(ids.contains(try XCTUnwrap(chips(target).first).chipId), "⌥ kept an identity")
        XCTAssertEqual(shape(source), "ab # cd # ef", "⌥ took the source run")

        let stale = try beginDrag(source, NSRange(location: 0, length: 4))
        source.textView.insertText("z", replacementRange: NSRange(location: 0, length: 0))
        let moved = FakeDrag(source: source.textView, board: stale, mask: move, location: point)
        XCTAssertNil(target.coordinator.pageDragToMove(from: source.coordinator, offered: move))
        XCTAssertEqual(target.textView.dropRoute(for: moved), .fragment)
        XCTAssertEqual(target.textView.dragOperation(for: moved, type: .string), .copy)
        XCTAssertTrue(target.textView.performDragOperation(moved))
        source.coordinator.endPageDrag()
        XCTAssertEqual(shape(target), "xyab #ab #", "the stale drag placed no copy")
        XCTAssertEqual(shape(source), "zab # cd # ef", "a stale drag moved or removed a run")
        XCTAssertEqual(chips(source).map(\.chipId), ids)
    }

    /// A drag no page took, or one a rename field or another app took the public text
    /// of, leaves its source whatever the session's answer: only a page's drop moves a run.
    func testADragNoPageTookLeavesItsSource() throws {
        let (model, _) = try makeModel()
        let page = try mountPage(on: model)
        for _ in 0..<2 {
            _ = try beginDrag(page, NSRange(location: 0, length: 4))
            XCTAssertTrue(page.coordinator.dragsPageSelection)
            page.coordinator.endPageDrag()
            XCTAssertEqual(shape(page), "ab # cd # ef", "the session's end removed the run")
            XCTAssertFalse(page.coordinator.dragsPageSelection)
        }
    }

    /// A move from a page past its deadline is refused at the drop: the sweep takes
    /// that page at once, the line says so, and the destination keeps what it had.
    func testAMoveFromAPagePastItsDeadlineSettlesAndChangesNothing() throws {
        let (model, _) = try makeModel()
        let source = try mountPage(on: model)
        let client = model.coreClient
        let tab = try XCTUnwrap(model.tabs.first { $0.pageID == source.sheet }?.id)
        XCTAssertTrue(client.setRung(tab: tab, rung: .oneHour))
        _ = try beginDrag(source, NSRange(location: 0, length: 4))
        XCTAssertTrue(client.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        let target = try mountPage(on: model, text: "xy", seals: [])
        XCTAssertTrue(
            model.tabs.contains { $0.pageID == source.sheet }, "the control: the page still shows")
        let records = client.ledger().count

        XCTAssertNotNil(target.coordinator.pageDragToMove(from: source.coordinator, offered: move))
        XCTAssertFalse(target.coordinator.dropMovedPageDrag(from: source.coordinator, at: 2, offered: move))
        XCTAssertEqual(shape(target), "xy", "the destination changed")
        XCTAssertTrue(chips(target).isEmpty)
        XCTAssertFalse(model.tabs.contains { $0.pageID == source.sheet }, "the due page stayed")
        XCTAssertEqual(model.notice, PageModel.pageExpiredLine)
        XCTAssertGreaterThan(client.ledger().count, records, "the sweep recorded nothing")
    }

    /// Through the view's own drop: another page's drag moves through the core, never
    /// sealed as its public text, and the page's own drag moves in place.
    func testTheViewsDropRoutesAFragmentAndTheOwnDragThroughTheCore() throws {
        let (model, _) = try makeModel()
        let source = try mountPage(on: model)
        let target = try mountPage(on: model, text: "xy", seals: [])
        let ids = chips(source).map(\.chipId)
        let board = try beginDrag(source, NSRange(location: 0, length: 4))

        let below = NSPoint(x: 10, y: target.textView.bounds.maxY - 2)
        XCTAssertEqual(target.textView.characterIndexForInsertion(at: below), 2)
        let foreign = FakeDrag(
            source: source.textView, board: board, mask: move,
            location: target.textView.convert(below, to: nil))
        XCTAssertEqual(target.textView.dropRoute(for: foreign), .move)
        XCTAssertEqual(target.textView.dragOperation(for: foreign, type: .string), .move)
        XCTAssertTrue(target.textView.performDragOperation(foreign))
        XCTAssertEqual(shape(target), "xyab #", "another page's drag did not move here")
        XCTAssertEqual(chips(target).map(\.chipId), [ids[0]])
        XCTAssertEqual(shape(source), " cd # ef", "the move left its source run")
        source.coordinator.endPageDrag()

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

    // MARK: Ink from this app's editors

    /// A board of plain ink, as AppKit's own drag of text writes it.
    private func inkBoard(_ text: String) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString(text, forType: .string)
        return board
    }

    /// AppKit's drop of `drag` on `view`, run only once the route says ink, since a
    /// drop to seal would read the system's drag board.
    private func dropInk(_ drag: DraggingInfoStub, on page: Page) -> Bool {
        let view = page.textView
        guard view.dropRoute(for: drag) == .ink else {
            XCTFail("ink from this app did not route as ink")
            return false
        }
        XCTAssertNotEqual(view.draggingEntered(drag), [], "the page offered no drop for ink")
        _ = view.draggingUpdated(drag)
        return view.prepareForDragOperation(drag) && view.performDragOperation(drag)
    }

    /// Ink dragged from another page lands as ink, never sealed: one stretch moves
    /// through the core, and ⌥ lands a copy as AppKit drops it; no object is made.
    func testInkFromAnotherPageLandsAsInkAndNeverSeals() throws {
        let (model, _) = try makeModel()
        let source = try mountPage(on: model)
        let target = try mountPage(on: model, text: "xy", seals: [])
        let ids = chips(source).map(\.chipId)
        let records = model.coreClient.ledger().count
        let end = target.textView.convert(
            NSPoint(x: 10, y: target.textView.bounds.maxY - 2), to: nil)

        let stretch = try beginDrag(source, NSRange(location: 0, length: 2))
        XCTAssertNil(SealedFragment.item(on: stretch), "the control: ink alone carries no fragment")
        let moved = FakeDrag(source: source.textView, board: stretch, mask: move, location: end)
        XCTAssertEqual(target.textView.dropRoute(for: moved), .move)
        XCTAssertTrue(target.textView.performDragOperation(moved))
        source.coordinator.endPageDrag()
        XCTAssertEqual(shape(target), "xyab", "one stretch of ink did not move as ink")
        XCTAssertEqual(shape(source), " # cd # ef")

        let copied = try beginDrag(source, NSRange(location: 3, length: 2))
        let option = DraggingInfoStub(
            pasteboard: copied, source: source.textView, location: end, window: target.window,
            mask: .copy)
        XCTAssertTrue(dropInk(option, on: target), "⌥ ink from another page did not land")
        source.coordinator.endPageDrag()
        XCTAssertEqual(shape(target), "xyabcd", "⌥ ink did not land as ink")
        XCTAssertEqual(shape(source), " # cd # ef", "⌥ ink left its source")

        XCTAssertTrue(chips(target).isEmpty, "ink from another page was sealed")
        XCTAssertEqual(chips(source).map(\.chipId), ids)
        XCTAssertEqual(model.coreClient.ledger().count, records, "a seal was recorded")

        target.textView.isEditable = false
        XCTAssertEqual(target.textView.dropRoute(for: option), .refused)
        XCTAssertEqual(target.textView.draggingEntered(option), [])
        XCTAssertFalse(target.textView.performDragOperation(option))
        XCTAssertEqual(shape(target), "xyabcd", "a read only page took ink")
    }

    /// The note's ink, dragged onto its own page or another, lands as ink and never
    /// meets drop to seal, though the note holds the keys while it is dragged from.
    func testInkFromTheNoteLandsAsInkAndNeverSeals() throws {
        let (model, _) = try makeModel()
        let page = try mountPage(on: model)
        let other = try mountPage(on: model, text: "xy", seals: [])
        let ids = chips(page).map(\.chipId)
        page.coordinator.beginNote(at: 3)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys, "the control: the note holds the keys")
        note.textView.insertText("kept", replacementRange: NSRange(location: NSNotFound, length: 0))
        note.textView.selectAll(nil)
        let records = model.coreClient.ledger().count

        let home = DraggingInfoStub(
            pasteboard: inkBoard("kept"), source: note.textView,
            location: page.textView.convert(NSPoint(x: 10, y: page.textView.bounds.maxY - 2), to: nil),
            window: page.window)
        XCTAssertEqual(
            page.textView.dragOperation(for: home, type: .string), .copy,
            "AppKit's answer between two text views, so the note keeps its ink")
        XCTAssertTrue(dropInk(home, on: page), "the note's ink did not land on its page")
        XCTAssertEqual(shape(page), "ab # cd # efkept")
        XCTAssertEqual(model.noteText(chip: ids[0]), "kept", "the drop changed the note")

        let away = DraggingInfoStub(
            pasteboard: inkBoard("kept"), source: note.textView,
            location: other.textView.convert(NSPoint(x: 10, y: other.textView.bounds.maxY - 2), to: nil),
            window: other.window)
        XCTAssertTrue(dropInk(away, on: other), "the note's ink did not land on another page")
        XCTAssertEqual(shape(other), "xykept")
        XCTAssertEqual(model.noteText(chip: ids[0]), "kept", "the note lost its ink")

        XCTAssertEqual(chips(page).map(\.chipId), ids, "the note's ink was sealed")
        XCTAssertTrue(chips(other).isEmpty, "the note's ink was sealed")
        XCTAssertEqual(model.coreClient.ledger().count, records, "a seal was recorded")
    }

    /// Another app's ink still meets drop to seal on a page, and finds nowhere to land
    /// on a page that takes no edits; the route is read, never the system's drag board.
    func testAnotherAppsInkStillMeetsDropToSeal() throws {
        let (model, _) = try makeModel()
        let page = try mountPage(on: model)
        let foreign = DraggingInfoStub(
            pasteboard: inkBoard("hunter2"), source: nil,
            location: page.textView.convert(NSPoint(x: 10, y: 10), to: nil), window: page.window)
        XCTAssertEqual(page.textView.dropRoute(for: foreign), .seal)
        XCTAssertEqual(page.textView.draggingEntered(foreign), .copy)
        XCTAssertEqual(page.textView.draggingUpdated(foreign), .copy)

        page.textView.isEditable = false
        XCTAssertEqual(page.textView.dropRoute(for: foreign), .refused)
        XCTAssertEqual(page.textView.draggingEntered(foreign), [])
        XCTAssertFalse(page.textView.performDragOperation(foreign))
        XCTAssertEqual(shape(page), "ab # cd # ef")
    }

    // MARK: Standing aside (ADR-0046)

    /// While a name field or the note holds the keys, the page starts no drag and
    /// takes no drop, its own, another page's move or a fragment, and the line says why.
    func testDragsStandAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let (model, _) = try makeModel()
        let page = try mountPage(on: model)
        let other = try mountPage(on: model)
        let foreign = try beginDrag(other, NSRange(location: 0, length: 4))
        XCTAssertNotNil(SealedFragment.item(on: foreign), "the control: a fragment to drop")
        _ = try beginDrag(page, NSRange(location: 0, length: 4))

        func standsAside(_ holder: String) {
            model.notice = nil
            XCTAssertFalse(page.coordinator.dropPageDrag(at: 12, offered: move), holder)
            XCTAssertEqual(model.notice, PageModel.dropWaitsLine, holder)
            model.notice = nil
            XCTAssertNotNil(
                page.coordinator.pageDragToMove(from: other.coordinator, offered: move),
                "the control: a move to drop under the \(holder)")
            XCTAssertFalse(
                page.coordinator.dropMovedPageDrag(from: other.coordinator, at: 12, offered: move),
                holder)
            XCTAssertEqual(model.notice, PageModel.dropWaitsLine, holder)
            let ink = DraggingInfoStub(
                pasteboard: inkBoard("zz"), source: other.textView,
                location: page.textView.convert(NSPoint(x: 10, y: 10), to: nil),
                window: page.window, mask: .copy)
            // Never let a drop to seal read the system's drag board.
            guard page.textView.dropRoute(for: ink) == .ink else {
                return XCTFail("ink from another page did not route as ink under the \(holder)")
            }
            model.notice = nil
            XCTAssertFalse(page.textView.performDragOperation(ink), holder)
            XCTAssertEqual(model.notice, PageModel.dropWaitsLine, holder)
            XCTAssertFalse(page.coordinator.dropFragment(from: foreign, at: 12), holder)
            XCTAssertEqual(shape(page), "ab # cd # ef", "the page took a drop under the \(holder)")
            XCTAssertEqual(shape(other), "ab # cd # ef", "a run left the other page under the \(holder)")
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
        XCTAssertTrue(page.coordinator.dropFragment(from: foreign, at: 0), "nor the fragment")
        XCTAssertEqual(shape(page), "ab # cd # efab #")
        XCTAssertTrue(
            page.coordinator.dropMovedPageDrag(from: other.coordinator, at: 0, offered: move),
            "nor the other page's move")
        XCTAssertEqual(shape(page), "ab #ab # cd # efab #")
        XCTAssertEqual(shape(other), " cd # ef")
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
