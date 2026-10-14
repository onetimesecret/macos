import AppKit
import XCTest

@testable import CompanionKit

/// The editor's half of the sealed fragment (Law 0001's copy and select all
/// rows, ADR-0047): what the page's copy writes, on a pasteboard of the
/// test's own, against the live core.
@MainActor
final class SealedFragmentEditorTests: XCTestCase {
    private struct Page {
        let model: PageModel
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let field: NSTextField
        let window: NSWindow
        let pasteboard: NSPasteboard
        let sheet: UInt64
        let chips: [UInt64]
    }

    /// The envelope's documented shape (ADR-0047 point 1), read only here.
    private struct Envelope: Decodable {
        let version: Int
        let cut: String?
        let nodes: [Node]
    }

    private struct Node: Decodable, Equatable {
        let ink: String?
        let ref: Ref?
    }

    private struct Ref: Decodable, Equatable {
        let uuid: String
        let name: String?
        let note: String?
    }

    private let whole = NSRange(location: 0, length: 12)
    private let placeholder = "[sealed content · tiny]"

    /// `ab <SECRET> cd <TOKEN> ef`, twelve units, the page holding the keys.
    private func makePage(
        writeCutFragment: (@MainActor (SealedFragment, NSPasteboard) -> Bool)? = nil
    ) throws -> Page {
        let suite = "companion-fragment-editor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-fragment-editor-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = CompanionClient.ephemeral(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        let model = PageModel(
            formFactor: .backdrop, defaults: defaults,
            seams: .init(
                stateDirectory: directory, client: client,
                clearClipboardIfOurs: { false }, ambientPasteboard: pasteboard,
                writeCutFragment: writeCutFragment))
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
            "ab SECRET cd TOKEN ef", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()
        textView.setSelectedRange(NSRange(location: 8, length: 5))
        coordinator.sealSelectionOrLine()
        textView.layout()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let chips = try [3, 8].map { try XCTUnwrap(coordinator.chipAttachment(at: $0)?.info.chipId) }
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        drainMainQueue()
        return Page(
            model: model, coordinator: coordinator, textView: textView, field: field,
            window: window, pasteboard: pasteboard, sheet: sheet, chips: chips)
    }

    private func envelope(on pasteboard: NSPasteboard) throws -> Envelope {
        let data = try XCTUnwrap(
            pasteboard.data(forType: SealedFragment.pasteboardType), "no fragment was written")
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    /// Every byte of every type on the board, as text, to search for payload.
    private func everything(on pasteboard: NSPasteboard) -> String {
        (pasteboard.types ?? []).compactMap { pasteboard.data(forType: $0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    }

    private func chips(_ page: Page) -> [ChipInfo] {
        page.model.coreClient.documentRuns(sheet: page.sheet).compactMap {
            if case .chip(let chip) = $0 { chip } else { nil }
        }
    }

    // MARK: Copy

    /// A mixed selection writes one item: the envelope under the private
    /// type, in the selection's order, and the public text; nothing else.
    func testACopyOfAMixedSelectionWritesTheFragmentAndThePublicTextAlone() throws {
        let page = try makePage()
        page.textView.setSelectedRange(whole)
        page.textView.copy(nil)

        XCTAssertEqual(page.pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(
            page.pasteboard.pasteboardItems?.first?.types,
            [SealedFragment.pasteboardType, .string],
            "a rich or other type rode along on the ordinary copy")
        XCTAssertEqual(
            page.pasteboard.string(forType: .string),
            "ab \(placeholder) cd \(placeholder) ef")
        let copied = try envelope(on: page.pasteboard)
        XCTAssertEqual(copied.version, 1)
        XCTAssertNil(copied.cut, "a copy is not a cut")
        XCTAssertEqual(copied.nodes.map(\.ink), ["ab ", nil, " cd ", nil, " ef"])
        let refs = copied.nodes.compactMap(\.ref)
        XCTAssertEqual(refs.count, 2)
        XCTAssertNotEqual(refs[0].uuid, refs[1].uuid)
        let all = everything(on: page.pasteboard)
        XCTAssertFalse(all.contains("SECRET") || all.contains("TOKEN"), "a payload left the page")
        XCTAssertEqual(chips(page).map(\.chipId), page.chips, "a copy changed the page")
    }

    /// A one object copy is a one reference fragment.
    func testACopyOfOneObjectIsAOneReferenceFragment() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        page.textView.copy(nil)

        XCTAssertEqual(page.pasteboard.string(forType: .string), placeholder)
        let nodes = try envelope(on: page.pasteboard).nodes
        XCTAssertEqual(nodes.count, 1)
        XCTAssertNil(nodes.first?.ink)
        XCTAssertNotNil(nodes.first?.ref)
    }

    /// Ink alone writes plain text and no private type, so an in-app paste
    /// keeps its ordinary path (ADR-0047 point 2).
    func testACopyOfInkAloneWritesPlainTextOnly() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        page.textView.copy(nil)

        XCTAssertEqual(page.pasteboard.pasteboardItems?.first?.types, [.string])
        XCTAssertEqual(page.pasteboard.string(forType: .string), "ab")
    }

    /// An empty selection, a refused range and a file write nothing.
    func testACopyTheCoreDoesNotComposeWritesNothing() throws {
        let page = try makePage()
        let before = page.pasteboard.changeCount
        page.textView.copy(nil)
        XCTAssertFalse(page.model.copySelection([], sheet: page.sheet))
        XCTAssertFalse(
            page.model.copySelection(
                [NSRange(location: 0, length: 2), NSRange(location: 40, length: 2)],
                sheet: page.sheet),
            "one refused range refuses the copy")
        XCTAssertFalse(
            page.model.copySelection(
                [NSRange(location: 0, length: 2)], sheet: page.sheet | CompanionClient.fileIDTag))
        XCTAssertEqual(page.pasteboard.changeCount, before)
    }

    /// Several stretches of ink copy as plain text by line; several holding
    /// an object write nothing and say so, since one envelope holds one range.
    func testSeveralStretchesCopyAsInkOrNotAtAll() throws {
        let page = try makePage()
        page.textView.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 2)),
            NSValue(range: NSRange(location: 5, length: 2)),
        ]
        page.textView.copy(nil)
        XCTAssertEqual(page.pasteboard.pasteboardItems?.first?.types, [.string])
        XCTAssertEqual(page.pasteboard.string(forType: .string), "ab\ncd")
        XCTAssertNotEqual(page.model.notice, PageModel.severalStretchesLine)

        let before = page.pasteboard.changeCount
        page.textView.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 4)),
            NSValue(range: NSRange(location: 8, length: 4)),
        ]
        page.textView.copy(nil)
        XCTAssertEqual(page.pasteboard.changeCount, before, "objects left as placeholder ink")
        XCTAssertEqual(page.model.notice, PageModel.severalStretchesLine)
    }

    // MARK: Select all

    /// Select all takes each object whole, and its copy carries every
    /// object by reference; the page's own clone of that copy holds them all.
    func testSelectAllHoldsEveryObjectAndItsCopyCarriesEachByReference() throws {
        let page = try makePage()
        page.textView.selectAll(nil)
        XCTAssertEqual(page.textView.selectedRange(), whole)
        page.textView.copy(nil)

        let copied = try envelope(on: page.pasteboard)
        XCTAssertEqual(copied.nodes.compactMap(\.ref).count, page.chips.count)
        let data = try XCTUnwrap(page.pasteboard.data(forType: SealedFragment.pasteboardType))
        let placed = try XCTUnwrap(page.model.coreClient.pasteFragment(
            sheet: page.sheet, range: NSRange(location: 12, length: 0), envelope: data,
            plainText: page.pasteboard.string(forType: .string)))
        XCTAssertEqual(placed.cloned, 2, "a reference did not resolve to its live object")
        XCTAssertFalse(placed.unreadable)
    }

    // MARK: Name and note (#247)

    /// Each reference carries its own object's name and note, and only
    /// where it has them; a paste's clone takes both.
    func testEachReferenceCarriesItsObjectsNameAndNote() throws {
        let page = try makePage()
        XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chips[0], sheet: page.sheet))
        XCTAssertTrue(page.model.applyNoteOps(
            chip: page.chips[0], json: #"[{"ins":{"at":0,"text":"rotate monthly"}}]"#,
            intent: .typing, selection: nil))
        page.textView.setSelectedRange(whole)
        page.textView.copy(nil)

        let refs = try envelope(on: page.pasteboard).nodes.compactMap(\.ref)
        XCTAssertEqual(refs.map(\.name), ["API_KEY", nil])
        XCTAssertEqual(refs.map(\.note), ["rotate monthly", nil])
        XCTAssertFalse(
            everything(on: page.pasteboard).contains("SECRET"), "the name's value rode along")

        let data = try XCTUnwrap(page.pasteboard.data(forType: SealedFragment.pasteboardType))
        XCTAssertNotNil(page.model.coreClient.pasteFragment(
            sheet: page.sheet, range: NSRange(location: 12, length: 0), envelope: data,
            plainText: nil))
        let clone = try XCTUnwrap(chips(page).dropFirst(2).first)
        XCTAssertFalse(page.chips.contains(clone.chipId))
        XCTAssertEqual(clone.name, "API_KEY")
        XCTAssertTrue(clone.hasNote)
        XCTAssertEqual(page.model.noteText(chip: clone.chipId), "rotate monthly")
    }

    // MARK: The keys' holder (ADR-0046)

    /// While a field or the note holds the keys, the menu's Copy and Select
    /// All reach the holder, and the page's own routes write and select nothing.
    func testCopyAndSelectAllStandAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let page = try makePage()
        let copyAction = #selector(NSText.copy(_:))
        let selectAllAction = #selector(NSText.selectAll(_:))
        let copyItem = NSMenuItem(title: "Copy", action: copyAction, keyEquivalent: "")
        page.textView.setSelectedRange(whole)
        XCTAssertTrue(page.textView.validateMenuItem(copyItem), "the control: the page copies")
        let before = page.pasteboard.changeCount
        let selection = NSRange(location: 3, length: 1)

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertFalse(page.textView.answersChords)
        for action in [copyAction, selectAllAction] {
            XCTAssertFalse(
                answerer(of: action, in: page.window) === page.textView,
                "\(action) reached the page from the field")
        }
        XCTAssertFalse(page.textView.validateMenuItem(copyItem))
        page.textView.setSelectedRange(selection)
        page.textView.copy(nil)
        page.textView.selectAll(nil)
        XCTAssertEqual(page.pasteboard.changeCount, before, "the page copied under the field")
        XCTAssertEqual(page.textView.selectedRange(), selection)

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        page.coordinator.beginNote(at: 3)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        XCTAssertTrue(page.textView.yieldsKeys)
        XCTAssertTrue(answerer(of: copyAction, in: page.window) === note.textView)
        XCTAssertTrue(answerer(of: selectAllAction, in: page.window) === note.textView)
        page.textView.copy(nil)
        page.textView.selectAll(nil)
        XCTAssertEqual(page.pasteboard.changeCount, before, "the page copied under the note")
        XCTAssertEqual(page.textView.selectedRange(), selection)

        note.escape()
        drainMainQueue()
        XCTAssertTrue(page.window.firstResponder === page.textView)
        page.textView.copy(nil)
        XCTAssertNotEqual(page.pasteboard.changeCount, before, "the copy did not come back")
        XCTAssertEqual(page.pasteboard.string(forType: .string), placeholder)
    }

    // MARK: Cut and the clipboard slot

    /// ⌘X writes the cut's fragment, detaches every object as the active cut
    /// in one step, and one ⌘Z stands the same objects again.
    func testACutDetachesItsObjectsAsOneStepAndOneUndoStandsThemAgain() throws {
        let page = try makePage()
        let marks = page.model.dirtyMarks
        page.textView.setSelectedRange(whole)
        page.textView.cut(nil)

        XCTAssertEqual(
            page.pasteboard.pasteboardItems?.first?.types, [SealedFragment.pasteboardType, .string])
        XCTAssertEqual(
            page.pasteboard.string(forType: .string), "ab \(placeholder) cd \(placeholder) ef")
        let cut = try envelope(on: page.pasteboard)
        XCTAssertNotNil(cut.cut, "a cut's fragment names its cut")
        XCTAssertEqual(cut.nodes.compactMap(\.ref).count, 2)
        let all = everything(on: page.pasteboard)
        XCTAssertFalse(all.contains("SECRET") || all.contains("TOKEN"), "a payload left the page")
        XCTAssertEqual(page.textView.string, "")
        XCTAssertTrue(chips(page).isEmpty)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(page.model.activeCut?.pageID, page.sheet)
        XCTAssertEqual(page.model.activeCut?.objects.map(\.chipId), page.chips)
        XCTAssertGreaterThan(page.model.dirtyMarks, marks, "the cut armed no write")

        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips, "one undo did not stand them all")
        XCTAssertEqual(page.textView.textStorage?.length, whole.length)
        XCTAssertNil(page.model.activeCut, "the slot outlived the undo")
    }

    /// A board that refuses the cut's fragment gets the cut back: the core's
    /// undo stands every object again and a line says so (Law 0002).
    func testACutTheBoardRefusesIsPutBack() throws {
        let page = try makePage(writeCutFragment: { _, _ in false })
        let before = page.pasteboard.changeCount
        page.textView.setSelectedRange(whole)
        page.textView.cut(nil)

        XCTAssertEqual(page.pasteboard.changeCount, before)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips, "the refused cut took its objects")
        XCTAssertEqual(page.textView.textStorage?.length, whole.length)
        XCTAssertEqual(page.textView.selectedRange(), whole)
        XCTAssertNil(page.model.activeCut, "a slot for a cut that was put back")
        XCTAssertEqual(page.model.notice, PageModel.cutPutBackLine)
    }

    /// The slot names each object by its name or as sealed content, and its
    /// size class; never its payload nor its excerpt.
    func testTheSlotNamesTheCutObjectsByTheirFacesAlone() throws {
        let page = try makePage()
        XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chips[0], sheet: page.sheet))
        let excerpts = chips(page).map(\.excerpt)
        page.textView.setSelectedRange(whole)
        page.textView.cut(nil)

        let cut = try XCTUnwrap(page.model.activeCut)
        let sentence = try XCTUnwrap(PageModel.cutSlotSentence(for: cut))
        XCTAssertEqual(
            sentence, "cut, waiting to be placed: API_KEY · tiny, sealed content · tiny")
        for excerpt in excerpts {
            XCTAssertFalse(sentence.contains(excerpt), "the slot drew an excerpt")
        }
        XCTAssertFalse(sentence.contains("SECRET") || sentence.contains("TOKEN"))
        XCTAssertNil(PageModel.cutSlotSentence(for: ActiveCut(pageID: page.sheet, objects: [])))
    }

    /// The line stands under the owner's page only, with a cut standing, and
    /// never over a file or the ledger.
    func testTheSlotStandsUnderTheOwnersPageAlone() {
        func shows(_ cut: Bool, _ page: Bool, _ file: Bool, _ ledger: Bool, _ owns: Bool) -> Bool {
            PageModel.shouldShowCutSlot(
                cutStands: cut, hasPage: page, fileShowing: file, ledgerShowing: ledger,
                ownsPresentation: owns)
        }
        XCTAssertTrue(shows(true, true, false, false, true))
        XCTAssertFalse(shows(false, true, false, false, true), "no cut stands")
        XCTAssertFalse(shows(true, false, false, false, true), "an empty slot has no caret")
        XCTAssertFalse(shows(true, true, true, false, true), "a file takes no object")
        XCTAssertFalse(shows(true, true, false, true, true), "the ledger is a reading surface")
        XCTAssertFalse(shows(true, true, false, false, false), "the other window")
    }

    /// The slot's button places the same object at the caret as one step,
    /// with its name, and the line goes; ⌘Z takes the place back.
    func testTheSlotPlacesTheSameObjectAtTheCaretAndItsLineGoes() throws {
        let page = try makePage()
        XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chips[0], sheet: page.sheet))
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        page.textView.cut(nil)
        XCTAssertEqual(page.model.activeCut?.objects.map(\.chipId), [page.chips[0]])
        XCTAssertEqual(chips(page).map(\.chipId), [page.chips[1]])

        let end = try XCTUnwrap(page.textView.textStorage?.length)
        page.textView.setSelectedRange(NSRange(location: end, length: 0))
        page.model.mountEditor(page.textView, from: page.model.owner)
        let marks = page.model.dirtyMarks
        page.model.placeActiveCutAtCaret()

        XCTAssertEqual(chips(page).map(\.chipId), page.chips.reversed(), "not the same object")
        XCTAssertEqual(chips(page).last?.name, "API_KEY")
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: end + 1, length: 0))
        XCTAssertTrue(page.coordinator.chipAttachment(at: end) != nil, "the storage was not restated")
        XCTAssertNil(page.model.activeCut, "the line outlived its first place")
        XCTAssertGreaterThan(page.model.dirtyMarks, marks, "the place armed no write")

        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page).map(\.chipId), [page.chips[1]], "one undo did not take it back")
        XCTAssertFalse(page.coordinator.placeActiveCut(), "a place with no cut standing")
        XCTAssertEqual(chips(page).map(\.chipId), [page.chips[1]])
    }

    /// A cut of ink alone writes plain text and leaves the standing cut as it was.
    func testACutOfInkAloneWritesPlainTextAndLeavesTheSlotAlone() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        page.textView.cut(nil)
        let standing = try XCTUnwrap(page.model.activeCut)

        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        page.textView.cut(nil)
        XCTAssertEqual(page.pasteboard.pasteboardItems?.first?.types, [.string])
        XCTAssertEqual(page.pasteboard.string(forType: .string), "ab")
        XCTAssertTrue(page.textView.string.hasPrefix("  cd"))
        XCTAssertEqual(page.model.activeCut, standing)
    }

    /// Several stretches of ink cut as AppKit does; several holding an object
    /// cut nothing and say so, since one envelope holds one range.
    func testSeveralStretchesCutAsInkOrNotAtAll() throws {
        let page = try makePage()
        page.textView.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 4)),
            NSValue(range: NSRange(location: 8, length: 4)),
        ]
        let before = page.pasteboard.changeCount
        page.textView.cut(nil)
        XCTAssertEqual(page.pasteboard.changeCount, before)
        XCTAssertEqual(page.textView.textStorage?.length, whole.length)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips)
        XCTAssertEqual(page.model.notice, PageModel.severalStretchesCutLine)
        XCTAssertNil(page.model.activeCut)

        page.textView.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 2)),
            NSValue(range: NSRange(location: 5, length: 2)),
        ]
        page.textView.cut(nil)
        XCTAssertEqual(page.pasteboard.string(forType: .string), "ab\ncd")
        XCTAssertEqual(page.textView.textStorage?.length, whole.length - 4)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips, "an ink cut moved an object")
        XCTAssertNil(page.model.activeCut)
    }

    /// While a field or the note holds the keys, Cut reaches the holder, the
    /// page cuts nothing and the slot's button places nothing (ADR-0046).
    func testCutAndThePlaceStandAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        page.textView.cut(nil)
        let standing = try XCTUnwrap(page.model.activeCut)
        let cutAction = #selector(NSText.cut(_:))
        let cutItem = NSMenuItem(title: "Cut", action: cutAction, keyEquivalent: "")
        let selection = NSRange(location: 0, length: 4)
        page.textView.setSelectedRange(selection)
        XCTAssertTrue(page.textView.validateMenuItem(cutItem), "the control: the page cuts")
        let before = page.pasteboard.changeCount
        let length = page.textView.textStorage?.length

        func standsAside(_ holder: String) {
            XCTAssertFalse(page.textView.validateMenuItem(cutItem), holder)
            page.textView.setSelectedRange(selection)
            page.textView.cut(nil)
            XCTAssertFalse(page.coordinator.placeActiveCut(), holder)
            XCTAssertEqual(page.pasteboard.changeCount, before, "the page cut under the \(holder)")
            XCTAssertEqual(page.textView.textStorage?.length, length, holder)
            XCTAssertEqual(chips(page).map(\.chipId), [page.chips[1]], holder)
            XCTAssertEqual(page.model.activeCut, standing, holder)
        }

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertFalse(answerer(of: cutAction, in: page.window) === page.textView)
        standsAside("field")
        XCTAssertEqual(page.model.notice, PageModel.placeWaitsLine)

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        page.coordinator.beginNote(at: 7)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        XCTAssertTrue(answerer(of: cutAction, in: page.window) === note.textView)
        standsAside("note")

        note.escape()
        drainMainQueue()
        XCTAssertTrue(page.window.firstResponder === page.textView)
        XCTAssertTrue(page.coordinator.placeActiveCut(), "the place did not come back")
        XCTAssertNil(page.model.activeCut)
    }
}
