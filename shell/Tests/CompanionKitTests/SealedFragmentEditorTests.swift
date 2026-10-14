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
    /// Rich text by the name NSTextView offers it to a service.
    private static let legacyRTF = NSPasteboard.PasteboardType(
        "NeXT Rich Text Format v1.0 pasteboard type")

    /// `ab <SECRET> cd <TOKEN> ef`, twelve units, the page holding the keys.
    private func makePage(
        writeCutFragment: (@MainActor (SealedFragment, NSPasteboard) -> Bool)? = nil,
        client: CompanionClient? = nil
    ) throws -> Page {
        let suite = "companion-fragment-editor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-fragment-editor-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = client ?? CompanionClient.ephemeral(tag: UUID().uuidString)
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

    /// A note's copy and a file's copy write as AppKit does onto the model's board: their
    /// text as plain text and never the private type, over a board a page's copy filled.
    func testANoteOrAFileCopiesPlainTextAndNeverTheFragment() throws {
        let page = try makePage()
        XCTAssertTrue(page.model.applyNoteOps(
            chip: page.chips[0], json: #"[{"ins":{"at":0,"text":"rotate monthly"}}]"#,
            intent: .typing, selection: nil))
        func fillWithAPagesCopy() {
            XCTAssertTrue(page.window.makeFirstResponder(page.textView))
            page.textView.setSelectedRange(whole)
            page.textView.copy(nil)
            XCTAssertNotNil(
                page.pasteboard.data(forType: SealedFragment.pasteboardType),
                "the control: a page's copy wrote the fragment")
        }
        func assertPlainTextAlone(_ text: String, _ surface: String) {
            XCTAssertEqual(page.pasteboard.string(forType: .string), text, surface)
            XCTAssertFalse(
                page.pasteboard.types?.contains(SealedFragment.pasteboardType) ?? true,
                "\(surface) wrote the private type")
        }

        fillWithAPagesCopy()
        page.coordinator.beginNote(at: 3)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        note.textView.selectAll(nil)
        note.textView.copy(nil)
        assertPlainTextAlone("rotate monthly", "the note")
        note.escape()
        drainMainQueue()

        fillWithAPagesCopy()
        let storage = NSTextStorage(string: "line one\nline two\n")
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: 200))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let file = InkTextView(
            frame: NSRect(x: 220, y: 8, width: 200, height: 24), textContainer: container)
        let fileCoordinator = InkEditorView.Coordinator(model: page.model)
        file.coordinator = fileCoordinator
        fileCoordinator.textView = file
        fileCoordinator.currentSheet = CompanionClient.fileIDTag | 9_001
        page.window.contentView?.addSubview(file)
        XCTAssertTrue(page.window.makeFirstResponder(file))
        file.setSelectedRange(NSRange(location: 0, length: 8))
        file.copy(nil)
        assertPlainTextAlone("line one", "the file")
    }

    // MARK: Services

    /// A service asking for a selection holding an object gets the copy's
    /// public text alone, and one that writes back over it is not offered.
    func testAServiceTakesThePublicTextAndNoServiceWritesOverAnObject() throws {
        let page = try makePage()
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let ambient = page.pasteboard.changeCount
        page.textView.setSelectedRange(whole)

        let legacy = SealedFragment.legacyStringType
        XCTAssertEqual(
            page.textView.writablePasteboardTypes,
            [SealedFragment.pasteboardType, .string, legacy])
        XCTAssertNil(page.textView.validRequestor(forSendType: Self.legacyRTF, returnType: nil))
        XCTAssertNil(page.textView.validRequestor(forSendType: legacy, returnType: legacy))
        XCTAssertTrue(
            page.textView.validRequestor(forSendType: legacy, returnType: nil) as? InkTextView
                === page.textView)

        XCTAssertTrue(page.textView.writeSelection(
            to: board, types: [Self.legacyRTF, .rtfd, .rtf, legacy]))
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertEqual(board.pasteboardItems?.first?.types, [.string], "a rich type was written")
        XCTAssertEqual(board.string(forType: .string), "ab \(placeholder) cd \(placeholder) ef")
        let all = everything(on: board)
        XCTAssertFalse(all.contains("SECRET") || all.contains("TOKEN"), "a payload left the page")
        let written = board.changeCount
        XCTAssertFalse(page.textView.writeSelection(to: board, types: [Self.legacyRTF, .rtf]))
        XCTAssertEqual(board.changeCount, written, "a refused request wrote")

        board.clearContents()
        XCTAssertFalse(page.textView.writeSelection(to: board, type: Self.legacyRTF))
        XCTAssertTrue(page.textView.writeSelection(to: board, type: legacy))
        XCTAssertEqual(board.string(forType: .string), "ab \(placeholder) cd \(placeholder) ef")
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(page.pasteboard.changeCount, ambient, "the ordinary pasteboard moved")
        XCTAssertEqual(chips(page).map(\.chipId), page.chips, "a service changed the page")
    }

    /// Ink alone offers what AppKit offers, and several stretches holding an
    /// object write nothing, as the copy does.
    func testAServiceTakesInkAsAppKitWritesItAndSeveralStretchesNotAtAll() throws {
        let page = try makePage()
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        let types = page.textView.writablePasteboardTypes
        XCTAssertTrue(types.contains(Self.legacyRTF))
        XCTAssertTrue(page.textView.writeSelection(to: board, types: types))
        XCTAssertEqual(board.string(forType: .string), "ab")
        XCTAssertNotNil(board.data(forType: .rtf), "ink lost AppKit's rich text")

        board.clearContents()
        let cleared = board.changeCount
        page.textView.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 4)),
            NSValue(range: NSRange(location: 8, length: 4)),
        ]
        XCTAssertFalse(page.textView.writeSelection(to: board, types: [.string]))
        XCTAssertEqual(board.changeCount, cleared, "several stretches with an object wrote")
        XCTAssertEqual(page.model.notice, PageModel.severalStretchesLine, "the copy's line")
    }

    /// No service reaches the page, and the page writes nothing for one,
    /// while a field or the note holds the keys (ADR-0046).
    func testServicesStandAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let page = try makePage()
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let legacy = SealedFragment.legacyStringType
        page.textView.setSelectedRange(whole)
        XCTAssertNotNil(
            page.textView.validRequestor(forSendType: legacy, returnType: nil), "the control")
        let before = board.changeCount

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertFalse(page.textView.answersChords)
        XCTAssertNil(page.textView.validRequestor(forSendType: legacy, returnType: nil))
        XCTAssertFalse(page.textView.writeSelection(to: board, types: [legacy]))
        XCTAssertFalse(page.textView.writeSelection(to: board, type: legacy))
        XCTAssertEqual(board.changeCount, before, "the page wrote for a service under the field")

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        page.coordinator.beginNote(at: 3)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        page.textView.setSelectedRange(whole)
        XCTAssertNil(page.textView.validRequestor(forSendType: legacy, returnType: nil))
        XCTAssertFalse(page.textView.writeSelection(to: board, types: [legacy]))
        XCTAssertEqual(board.changeCount, before, "the page wrote for a service under the note")

        note.escape()
        drainMainQueue()
        XCTAssertTrue(page.textView.writeSelection(to: board, types: [legacy]))
        XCTAssertEqual(board.string(forType: .string), "ab \(placeholder) cd \(placeholder) ef")
    }

    // MARK: Share and Writing Tools

    /// A secondary click near the view's top left corner, over ink and no object.
    private func secondaryClick(in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: view.convert(NSPoint(x: 4, y: 4), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// A file over its own coordinator, as a mount over a file stands it; the view
    /// holds its coordinator weakly, so the caller keeps both.
    private func fileView(beside page: Page) -> (InkTextView, InkEditorView.Coordinator) {
        let storage = NSTextStorage(string: "line one\nline two\n")
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: 200))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let file = InkTextView(
            frame: NSRect(x: 220, y: 8, width: 200, height: 24), textContainer: container)
        let coordinator = InkEditorView.Coordinator(model: page.model)
        file.coordinator = coordinator
        coordinator.textView = file
        coordinator.currentSheet = CompanionClient.fileIDTag | 9_001
        page.window.contentView?.addSubview(file)
        return (file, coordinator)
    }

    /// Share… builds its picker over the selection with the menu, before any gate is
    /// asked, and Writing Tools reads and rewrites a selection past every gate, so a
    /// page's, a sealed name's and a note's text offer neither; nor Search With Google,
    /// which hands the selection to the browser, nor the typing suggestions the spell
    /// server makes around the caret at every move. A file keeps them all.
    func testAPageANameAndANoteOfferNoShareSearchWritingToolsOrSuggestions() throws {
        let page = try makePage()
        XCTAssertTrue(page.model.applyNoteOps(
            chip: page.chips[0], json: #"[{"ins":{"at":0,"text":"rotate monthly"}}]"#,
            intent: .typing, selection: nil))
        let (file, fileCoordinator) = fileView(beside: page)
        file.setSelectedRange(NSRange(location: 0, length: 4))
        let fileMenu = try XCTUnwrap(file.menu(for: secondaryClick(in: file)))
        XCTAssertTrue(fileMenu.items.contains(where: TextOffers.isShare), "the control: a file shares")

        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        let pageMenu = try XCTUnwrap(page.textView.menu(for: secondaryClick(in: page.textView)))
        XCTAssertFalse(pageMenu.items.contains(where: TextOffers.isShare), "the page shares")
        XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chips[0], sheet: page.sheet))
        let name = try openNameField(page)
        let nameMenu = try XCTUnwrap(name.menu(for: secondaryClick(in: name)))
        XCTAssertFalse(nameMenu.items.contains(where: TextOffers.isShare), "the name shares")
        page.coordinator.nameEditor?.keep(returningKeys: true)
        page.coordinator.beginNote(at: 3)
        drainMainQueue()
        let note = try XCTUnwrap(page.coordinator.noteEditor?.textView)
        note.selectAll(nil)
        let noteMenu = try XCTUnwrap(note.menu(for: secondaryClick(in: note)))
        XCTAssertFalse(noteMenu.items.contains(where: TextOffers.isShare), "the note shares")
        for menu in [pageMenu, nameMenu, noteMenu] {
            XCTAssertFalse(zip(menu.items, menu.items.dropFirst()).contains {
                $0.isSeparatorItem && $1.isSeparatorItem
            }, "Share left a doubled separator")
        }

        XCTAssertTrue(fileMenu.items.contains(where: TextOffers.isWebSearch), "the control: a file searches")
        for (menu, surface) in [(pageMenu, "page"), (nameMenu, "name"), (noteMenu, "note")] {
            XCTAssertFalse(menu.items.contains(where: TextOffers.isWebSearch), "the \(surface) searches")
        }
        XCTAssertTrue(file.isAutomaticTextCompletionEnabled, "the control: a file suggests")
        for (view, surface) in [(page.textView, "page"), (note, "note"), (name, "name")] as [(NSTextView, String)] {
            XCTAssertFalse(view.isAutomaticTextCompletionEnabled, "the \(surface) suggests")
            view.toggleAutomaticTextCompletion(nil)
            XCTAssertFalse(view.isAutomaticTextCompletionEnabled, "the \(surface)'s toggle")
        }

        guard #available(macOS 15.0, *) else { return }
        let writingTools = Selector(("showWritingTools:"))
        XCTAssertTrue(fileMenu.items.contains { $0.action == writingTools }, "the control")
        XCTAssertEqual(file.writingToolsBehavior, .default)
        XCTAssertEqual(page.textView.writingToolsBehavior, .none, "the page")
        XCTAssertEqual(note.writingToolsBehavior, .none, "the note")
        XCTAssertEqual(name.writingToolsBehavior, .none, "the name")
        for menu in [pageMenu, nameMenu, noteMenu] {
            XCTAssertFalse(menu.items.contains { $0.action == writingTools }, "Writing Tools offered")
        }
        fileCoordinator.currentSheet = page.sheet
        XCTAssertEqual(file.writingToolsBehavior, .none, "a page mounted where a file stood")
        XCTAssertFalse(file.isAutomaticTextCompletionEnabled, "a page mounted where a file stood")
    }

    /// Look Up and Translate are built titled with the selection they hold, Speech reads it
    /// out and Spelling and Grammar hands it to the spell server, so no gate at the click
    /// can stop a menu held open past a deadline: a page's, a sealed name's and a note's
    /// text menu offer none of them; a file keeps all.
    func testAPageANameAndANoteOfferNoLookUpTranslateSpeechOrSpelling() throws {
        let page = try makePage()
        XCTAssertTrue(page.model.applyNoteOps(
            chip: page.chips[0], json: #"[{"ins":{"at":0,"text":"rotate monthly"}}]"#,
            intent: .typing, selection: nil))
        func offers(_ menu: NSMenu) -> [String] {
            var found: [String] = []
            if menu.items.contains(where: TextOffers.isLookUpOrTranslate) { found.append("Look Up") }
            if menu.items.contains(where: TextOffers.isSpeech) { found.append("Speech") }
            if menu.items.contains(where: TextOffers.isSpelling) { found.append("Spelling") }
            return found
        }
        let (file, fileCoordinator) = fileView(beside: page)
        file.setSelectedRange(NSRange(location: 0, length: 4))
        let fileMenu = try XCTUnwrap(file.menu(for: secondaryClick(in: file)))
        XCTAssertEqual(
            offers(fileMenu), ["Look Up", "Speech", "Spelling"], "the control: a file offers them")
        XCTAssertEqual(
            fileMenu.items.filter(TextOffers.isLookUpOrTranslate).count, 2,
            "the control: a file offers Look Up and Translate")

        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        let pageMenu = try XCTUnwrap(page.textView.menu(for: secondaryClick(in: page.textView)))
        XCTAssertEqual(offers(pageMenu), [], "the page")
        XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chips[0], sheet: page.sheet))
        let name = try openNameField(page)
        name.selectAll(nil)
        let nameMenu = try XCTUnwrap(name.menu(for: secondaryClick(in: name)))
        XCTAssertEqual(offers(nameMenu), [], "the name")
        page.coordinator.nameEditor?.keep(returningKeys: true)
        page.coordinator.beginNote(at: 3)
        drainMainQueue()
        let note = try XCTUnwrap(page.coordinator.noteEditor?.textView)
        note.selectAll(nil)
        let noteMenu = try XCTUnwrap(note.menu(for: secondaryClick(in: note)))
        XCTAssertEqual(offers(noteMenu), [], "the note")
        for menu in [pageMenu, nameMenu, noteMenu] {
            XCTAssertNotEqual(menu.items.first?.isSeparatorItem, true, "a separator led the menu")
        }
        withExtendedLifetime(fileCoordinator) {}
    }

    /// Over a word continuous spelling marked, AppKit heads the menu with its guesses,
    /// Ignore Spelling and Learn Spelling; the filter takes them with the submenu.
    func testTheSpellingItemsOverAMisspelledWordLeaveWithTheSubmenu() {
        let menu = NSMenu()
        for action in ["_changeSpellingFromMenu:", "_ignoreSpellingFromMenu:", "_learnSpellingFromMenu:"] {
            menu.addItem(NSMenuItem(title: action, action: Selector((action)), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""))

        TextOffers.removeSelectionReaders(from: menu)

        XCTAssertEqual(menu.items.map(\.title), ["Cut"])
    }

    /// A page's Transformations keep the three its rewrite carries round an object; the
    /// conversions AppKit adds beside them, where an input source asks, leave the page's
    /// menu, and a note's keeps them.
    func testAPagesTransformationsAreTheThreeItsRewriteCarries() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        let pageMenu = try XCTUnwrap(page.textView.menu(for: secondaryClick(in: page.textView)))
        let transformations = { (menu: NSMenu) in
            menu.items.compactMap(\.submenu).first {
                $0.items.contains { $0.action == #selector(NSResponder.uppercaseWord(_:)) }
            }?.items.compactMap(\.action).map(NSStringFromSelector)
        }
        XCTAssertEqual(
            transformations(pageMenu), ["uppercaseWord:", "lowercaseWord:", "capitalizeWord:"])

        let built = NSMenu()
        let submenu = NSMenu()
        for action in ["uppercaseWord:", "lowercaseWord:", "capitalizeWord:", "convertToFullWidth:"] {
            submenu.addItem(NSMenuItem(title: action, action: Selector((action)), keyEquivalent: ""))
        }
        built.addItem(NSMenuItem(title: "Transformations", action: nil, keyEquivalent: ""))
        built.items[0].submenu = submenu

        TextOffers.removeUncarriedTransformations(from: built)

        XCTAssertEqual(
            transformations(built), ["uppercaseWord:", "lowercaseWord:", "capitalizeWord:"])
    }

    /// Continuous spelling reaches the spell server only through `checkTextInRange`, the
    /// one method the asking views gate for it, so a change of AppKit's route fails here.
    /// Its text is the test's own, never a page's.
    func testContinuousSpellingChecksThroughTheOneGatedMethod() {
        final class Checked: NSTextView {
            var onCheck: (() -> Void)?
            override func checkText(
                in range: NSRange, types checkingTypes: NSTextCheckingTypes,
                options: [NSSpellChecker.OptionKey: Any] = [:]
            ) {
                if checkingTypes & NSTextCheckingResult.CheckingType.spelling.rawValue != 0 {
                    onCheck?()
                }
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Checked(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        view.isContinuousSpellCheckingEnabled = true
        let checked = expectation(description: "a spelling check came through checkTextInRange")
        checked.assertForOverFulfill = false
        view.onCheck = { checked.fulfill() }

        view.insertText("wrnog speling ", replacementRange: NSRange(location: NSNotFound, length: 0))

        wait(for: [checked], timeout: 10)
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

    // MARK: Paste

    /// One item as another build or a crafted copy would leave it.
    private func put(_ envelope: String, text: String?, on pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(Data(envelope.utf8), forType: SealedFragment.pasteboardType))
        if let text { XCTAssertTrue(item.setString(text, forType: .string)) }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
    }

    /// The first ⌘V of a cut stands the same objects with their names and notes;
    /// a later ⌘V of the same board clones them, and each paste is one undo step.
    func testACutsFirstPasteReattachesItsObjectsAndALaterOneClonesThem() throws {
        let page = try makePage()
        XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chips[0], sheet: page.sheet))
        XCTAssertTrue(page.model.applyNoteOps(
            chip: page.chips[0], json: #"[{"ins":{"at":0,"text":"rotate monthly"}}]"#,
            intent: .typing, selection: nil))
        page.textView.setSelectedRange(whole)
        page.textView.cut(nil)
        XCTAssertNotNil(page.model.activeCut)

        var marks = page.model.dirtyMarks
        page.textView.paste(nil)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips, "the first paste did not reattach")
        XCTAssertEqual(chips(page).map(\.name), ["API_KEY", nil])
        XCTAssertEqual(page.model.noteText(chip: page.chips[0]), "rotate monthly")
        XCTAssertNil(page.model.activeCut, "the slot outlived the first paste")
        XCTAssertNotNil(page.coordinator.chipAttachment(at: 3), "the storage was not restated")
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: whole.length, length: 0))
        XCTAssertGreaterThan(page.model.dirtyMarks, marks, "the paste armed no write")

        marks = page.model.dirtyMarks
        page.textView.paste(nil)
        let all = chips(page)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.prefix(2).map(\.chipId), page.chips)
        let clones = Array(all.suffix(2))
        XCTAssertTrue(
            Set(clones.map(\.chipId)).isDisjoint(with: page.chips), "a later paste reattached")
        XCTAssertEqual(clones.map(\.name), ["API_KEY", nil])
        XCTAssertEqual(page.model.noteText(chip: clones[0].chipId), "rotate monthly")
        XCTAssertEqual(page.textView.textStorage?.length, 2 * whole.length)
        XCTAssertGreaterThan(page.model.dirtyMarks, marks, "the clone armed no write")

        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips, "one undo did not take both clones")
        XCTAssertEqual(page.textView.textStorage?.length, whole.length)
    }

    /// ⌘V after a copy clones every object core side, records one `sealed` for
    /// each clone, leaves the copied objects where they stand, and undoes as one step.
    func testAPasteAfterACopyClonesEveryObjectAsOneStep() throws {
        let page = try makePage()
        page.textView.setSelectedRange(whole)
        page.textView.copy(nil)
        page.textView.setSelectedRange(NSRange(location: whole.length, length: 0))
        let records = page.model.coreClient.ledger().count
        page.textView.paste(nil)

        let all = chips(page)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.prefix(2).map(\.chipId), page.chips, "the copy's objects moved")
        XCTAssertTrue(Set(all.suffix(2).map(\.chipId)).isDisjoint(with: page.chips))
        XCTAssertEqual(page.model.coreClient.ledger().count, records + 2, "one sealed per clone")
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 2 * whole.length, length: 0))

        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips)
        XCTAssertEqual(page.textView.textStorage?.length, whole.length)
    }

    /// Paste and Match Style and Paste Without Detection take a fragment through
    /// the core as ⌘V does, so neither places its public text as ink.
    func testEveryPasteCommandTakesAFragmentThroughTheCore() throws {
        let page = try makePage()
        page.textView.setSelectedRange(whole)
        page.textView.copy(nil)
        page.textView.setSelectedRange(NSRange(location: whole.length, length: 0))
        page.textView.pasteAsPlainText(nil)
        XCTAssertEqual(chips(page).count, 4, "Paste and Match Style placed no clones")
        page.textView.pasteWithoutDetection(nil)
        XCTAssertEqual(chips(page).count, 6, "Paste Without Detection placed no clones")
        XCTAssertFalse(page.textView.string.contains(placeholder), "a public text was pasted")
    }

    /// A note and a file leave a fragment to AppKit's paste, which reads the
    /// public text as another app does; the core places nothing for either.
    func testANoteOrAFileLeavesAFragmentToThePublicText() throws {
        let page = try makePage()
        page.textView.setSelectedRange(whole)
        page.textView.copy(nil)
        let file = page.sheet | CompanionClient.fileIDTag
        XCTAssertEqual(
            page.model.pasteFragment(
                from: page.pasteboard, sheet: file, ranges: [NSRange(location: 0, length: 0)]),
            .ordinary)

        page.coordinator.beginNote(at: 3)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertEqual(note.textView.coordinator?.writesNote, true)
        XCTAssertEqual(note.textView.coordinator?.pasteFragment(), false)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips)
        XCTAssertEqual(page.textView.textStorage?.length, whole.length)
        note.escape()
    }

    /// A burned object's reference pastes `[sealed content · burned]` and an
    /// unknown one `[sealed content · unavailable]`, each where its object stood.
    func testAGoneReferencePastesItsPlaceholderWhereTheObjectStood() throws {
        let page = try makePage()
        page.textView.setSelectedRange(whole)
        page.textView.copy(nil)
        XCTAssertTrue(page.model.coreClient.deleteChip(id: page.chips[0]))
        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        page.textView.paste(nil)

        let text = page.textView.string
        XCTAssertTrue(
            text.hasPrefix("ab [sealed content · burned] cd \u{FFFC} ef"), "out of position: \(text)")
        let standing = chips(page).map(\.chipId)
        XCTAssertEqual(standing.count, 2)
        XCTAssertEqual(standing.last, page.chips[1])
        XCTAssertNotEqual(standing.first, page.chips[1], "the live reference was not cloned")

        let uuid = UUID().uuidString.lowercased()
        put(
            #"{"version":1,"nodes":[{"ink":"x "},{"ref":{"uuid":"\#(uuid)"}},{"ink":" y"}]}"#,
            text: "x \(placeholder) y", on: page.pasteboard)
        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        page.textView.paste(nil)
        XCTAssertTrue(page.textView.string.hasPrefix("x [sealed content · unavailable] yab "))
        XCTAssertEqual(chips(page).map(\.chipId), standing)
    }

    /// An envelope this build cannot read pastes its item's public text and says
    /// so; with no text beside it, nothing changes and a line says nothing was placed.
    func testAnUnreadableEnvelopePastesItsPublicTextAndSaysSo() throws {
        let page = try makePage()
        put(#"{"version":2,"nodes":[]}"#, text: "x \(placeholder) y", on: page.pasteboard)
        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        page.textView.paste(nil)
        XCTAssertTrue(page.textView.string.hasPrefix("x \(placeholder) yab "))
        XCTAssertEqual(chips(page).map(\.chipId), page.chips)
        XCTAssertEqual(page.model.notice, PageModel.pastedPublicTextLine)

        put("not an envelope", text: nil, on: page.pasteboard)
        let length = page.textView.textStorage?.length
        page.textView.paste(nil)
        XCTAssertEqual(page.textView.textStorage?.length, length)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips)
        XCTAssertEqual(page.model.notice, PageModel.pasteRefusedLine)
    }

    /// A promise of the private type that gives nothing, as a provider that failed leaves it.
    private final class EmptyPromise: NSObject, NSPasteboardItemDataProvider {
        nonisolated func pasteboard(
            _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {}
    }

    /// An item naming the private type whose data cannot be read pastes as an unreadable
    /// envelope: its public text with the line, or, with no text, nothing and the refusal.
    func testAnItemWhoseFragmentCannotBeReadPastesItsPublicTextAndSaysSo() throws {
        let page = try makePage()
        let promise = EmptyPromise()
        func offer(text: String?) {
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setDataProvider(promise, forTypes: [SealedFragment.pasteboardType]))
            if let text { XCTAssertTrue(item.setString(text, forType: .string)) }
            page.pasteboard.clearContents()
            XCTAssertTrue(page.pasteboard.writeObjects([item]))
            let offered = SealedFragment.item(on: page.pasteboard)
            XCTAssertNotNil(offered, "the control: the item names the private type")
            XCTAssertNil(offered?.data(forType: SealedFragment.pasteboardType), "the control: no data")
        }

        // The coordinator's answer, not ⌘V, so a regression never reaches AppKit's general board.
        offer(text: "x \(placeholder) y")
        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(page.coordinator.pasteFragment(), "left to AppKit's paste")
        XCTAssertTrue(page.textView.string.hasPrefix("x \(placeholder) yab "), page.textView.string)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips)
        XCTAssertEqual(page.model.notice, PageModel.pastedPublicTextLine)

        offer(text: nil)
        let text = page.textView.string
        let marks = page.model.dirtyMarks
        XCTAssertTrue(page.coordinator.pasteFragment(), "left to AppKit's paste")
        XCTAssertEqual(page.textView.string, text)
        XCTAssertEqual(chips(page).map(\.chipId), page.chips)
        XCTAssertEqual(page.model.notice, PageModel.pasteRefusedLine)
        XCTAssertEqual(page.model.dirtyMarks, marks, "a refusal armed a write")
    }

    /// A paste that swept a due page settles at once: the swept page leaves the
    /// model's tabs without waiting for the timer (ADR-0048).
    func testAPasteThatSweepsADuePageSettlesAtOnce() throws {
        let page = try makePage()
        let client = page.model.coreClient
        let tab = try XCTUnwrap(page.model.tabs.first { $0.pageID == page.sheet }?.id)
        XCTAssertTrue(client.setRung(tab: tab, rung: .oneHour))
        page.textView.setSelectedRange(whole)
        page.textView.copy(nil)
        XCTAssertTrue(client.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        page.model.newPage()
        let fresh = try XCTUnwrap(page.model.selectedPageID)
        XCTAssertTrue(
            page.model.tabs.contains { $0.pageID == page.sheet }, "the control: the page still shows")

        let outcome = page.model.pasteFragment(
            from: page.pasteboard, sheet: fresh, ranges: [NSRange(location: 0, length: 0)])
        guard case .placed(let placed) = outcome else { return XCTFail("placed nothing") }
        XCTAssertEqual(placed.pagesExpired, 1)
        XCTAssertEqual(placed.expired, 2)
        XCTAssertFalse(
            page.model.tabs.contains { $0.pageID == page.sheet }, "the swept page stayed on screen")
    }

    /// A fragment or the slot's cut over several stretches places nothing and says so, as
    /// copy, cut and drag refuse them; a board of ink alone is left to AppKit's paste.
    func testAFragmentPastesIntoOneSelectionNotSeveral() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        page.textView.cut(nil)
        let standing = try XCTUnwrap(page.model.activeCut)
        let stretches = [
            NSValue(range: NSRange(location: 0, length: 2)),
            NSValue(range: NSRange(location: 4, length: 2)),
        ]
        let text = page.textView.string
        let objects = chips(page).map(\.chipId)
        let records = page.model.coreClient.ledger().count
        let marks = page.model.dirtyMarks
        let commands: [(name: String, run: (InkTextView) -> Void)] = [
            ("Paste", { $0.paste(nil) }),
            ("Paste and Match Style", { $0.pasteAsPlainText(nil) }),
            ("Paste Without Detection", { $0.pasteWithoutDetection(nil) }),
            ("the slot's Place", { XCTAssertFalse($0.coordinator?.placeActiveCut() ?? true) }),
        ]
        for command in commands {
            page.model.notice = nil
            page.textView.selectedRanges = stretches
            command.run(page.textView)
            XCTAssertEqual(page.model.notice, PageModel.severalStretchesPasteLine, command.name)
            XCTAssertEqual(page.textView.string, text, "\(command.name) changed the page")
            XCTAssertEqual(page.textView.selectedRanges, stretches, command.name)
        }
        XCTAssertEqual(chips(page).map(\.chipId), objects)
        XCTAssertEqual(page.model.activeCut, standing, "the refusal ended the cut")
        XCTAssertEqual(page.model.coreClient.ledger().count, records)
        XCTAssertEqual(page.model.dirtyMarks, marks, "a refusal armed a write")

        page.pasteboard.clearContents()
        XCTAssertTrue(page.pasteboard.setString("zz", forType: .string))
        page.model.notice = nil
        page.textView.selectedRanges = stretches
        XCTAssertEqual(page.coordinator.pasteFragment(), false, "ink alone was not left to AppKit")
        XCTAssertNil(page.model.notice)
    }

    /// A refused paste or place with nothing due changed nothing, so it arms no write;
    /// one a page past its deadline refused settles, takes the page and says why.
    func testARefusedPasteOrPlaceArmsAWriteOnlyWhenItsSettleSweeps() throws {
        let quiet = try makePage()
        put("not an envelope", text: nil, on: quiet.pasteboard)
        let marks = quiet.model.dirtyMarks
        quiet.textView.paste(nil)
        XCTAssertEqual(quiet.model.notice, PageModel.pasteRefusedLine)
        XCTAssertNil(quiet.model.activeCut)
        XCTAssertFalse(quiet.coordinator.placeActiveCut(), "a place with no cut standing")
        XCTAssertEqual(quiet.model.dirtyMarks, marks, "a refusal that changed nothing armed a write")

        let routes: [(name: String, run: (Page) -> Void)] = [
            ("paste", { $0.textView.paste(nil) }),
            ("place", { XCTAssertFalse($0.coordinator.placeActiveCut()) }),
        ]
        for route in routes {
            let page = try makePage()
            page.textView.setSelectedRange(NSRange(location: 3, length: 1))
            page.textView.cut(nil)
            XCTAssertNotNil(page.model.activeCut, "\(route.name): the control")
            try age(page, keepsChipIDs: false)
            page.textView.setSelectedRange(NSRange(location: 0, length: 0))
            let marks = page.model.dirtyMarks

            route.run(page)

            XCTAssertEqual(page.model.notice, PageModel.pageExpiredLine, route.name)
            XCTAssertFalse(
                page.model.tabs.contains { $0.pageID == page.sheet }, "\(route.name): no settle")
            XCTAssertGreaterThan(page.model.dirtyMarks, marks, "\(route.name): the sweep armed no write")
        }
    }

    /// A core whose paste sweeps as one naming an object does (ADR-0048) and then
    /// refuses, as a body refusing partway leaves it.
    private final class SweepThenRefuseClient: CompanionClient, @unchecked Sendable {
        private(set) var pagesSwept: UInt64 = 0

        init(tag: String) {
            super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
        }

        override func pasteFragment(
            sheet: UInt64, range: NSRange, envelope: Data, plainText: String?
        ) -> PlacedFragment? {
            pagesSwept += expireDue()
            return nil
        }
    }

    /// A paste refused after its own sweep took a due page still settles, though
    /// nothing is due by then: the page leaves and the sweep's write is armed.
    func testAPasteRefusedAfterItsSweepStillSettles() throws {
        let client = SweepThenRefuseClient(tag: UUID().uuidString)
        let page = try makePage(client: client)
        page.textView.setSelectedRange(whole)
        page.textView.copy(nil)
        try age(page)
        page.model.newPage()
        let fresh = try XCTUnwrap(page.model.selectedPageID)
        let marks = page.model.dirtyMarks

        XCTAssertEqual(
            page.model.pasteFragment(
                from: page.pasteboard, sheet: fresh, ranges: [NSRange(location: 0, length: 0)]),
            .refused)

        XCTAssertEqual(client.pagesSwept, 1, "the control: the paste's own sweep took the page")
        XCTAssertFalse(
            page.model.tabs.contains { $0.pageID == page.sheet }, "the swept page stayed on screen")
        XCTAssertGreaterThan(page.model.dirtyMarks, marks, "the sweep armed no write")
        XCTAssertEqual(page.model.notice, PageModel.pasteRefusedLine)
    }

    // MARK: The sealed paste and its offer

    /// A core whose board always holds what a sealed paste could take, and which
    /// counts the takes it is asked for rather than reading any board.
    private final class SealWitness: CompanionClient, @unchecked Sendable {
        private(set) var takes = 0

        init(tag: String) {
            super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
        }

        override func pasteboardHasContent() -> Bool { true }

        override func sealFromPasteboard(
            sheet: UInt64, at: UInt32, length: UInt32
        ) -> (chip: ChipInfo?, cleared: Bool) {
            takes += 1
            return (nil, false)
        }
    }

    /// ⇧⌘V as the bundled keymap binds it.
    private func sealChord(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
    }

    /// A board holding this app's own copy or cut holds nothing to seal: no
    /// offer is made, and ⇧⌘V and the offer's button take nothing and point at ⌘V.
    func testThisAppsOwnCopyOnTheBoardOffersNothingToSeal() throws {
        let client = SealWitness(tag: UUID().uuidString)
        let page = try makePage(client: client)
        page.coordinator.announce(page.textView)
        let caret = NSRange(location: 0, length: 0)

        func offerAnotherAppsText() {
            page.pasteboard.clearContents()
            page.pasteboard.setString("another app's text", forType: .string)
            page.model.refreshPasteboardOffer(from: .panel)
            XCTAssertTrue(page.model.pasteboardOffer, "the control: another app's text is offered")
        }

        for act in ["copy", "cut"] {
            offerAnotherAppsText()
            page.textView.setSelectedRange(NSRange(location: 0, length: 4))
            if act == "copy" { page.textView.copy(nil) } else { page.textView.cut(nil) }
            XCTAssertNotNil(SealedFragment.item(on: page.pasteboard), "\(act) wrote no fragment")
            let board = page.pasteboard.changeCount
            let length = page.textView.textStorage?.length
            let objects = chips(page).map(\.chipId)
            page.textView.setSelectedRange(caret)

            page.model.performSealedPaste?()
            XCTAssertEqual(page.model.notice, PageModel.ownCopySealLine, "\(act): the button")
            XCTAssertFalse(page.model.pasteboardOffer, "\(act): the refused button's offer stood")
            page.model.flash("before the chord")
            XCTAssertTrue(
                page.textView.performKeyEquivalent(with: try sealChord(in: page.window)), act)
            XCTAssertEqual(page.model.notice, PageModel.ownCopySealLine, "\(act): the chord")
            page.model.refreshPasteboardOffer(from: .panel)
            XCTAssertFalse(page.model.pasteboardOffer, "\(act): an offer was made over our own")

            XCTAssertEqual(client.takes, 0, "\(act): the core was asked to take our own")
            XCTAssertEqual(page.pasteboard.changeCount, board, "\(act): the board was touched")
            XCTAssertNotNil(SealedFragment.item(on: page.pasteboard), act)
            XCTAssertEqual(page.textView.textStorage?.length, length, act)
            XCTAssertEqual(chips(page).map(\.chipId), objects, act)
        }

        offerAnotherAppsText()
        XCTAssertNil(page.model.sealPasteboard(replacing: caret))
        XCTAssertEqual(client.takes, 1, "the control: another app's text goes to the core")
    }

    /// The private type a build other than this one writes, release or debug.
    static var otherBuildsType: NSPasteboard.PasteboardType {
        let other = CompanionClient.sealedFragmentType == CompanionClient.releaseSealedFragmentType
            ? CompanionClient.debugSealedFragmentType : CompanionClient.releaseSealedFragmentType
        return NSPasteboard.PasteboardType(other)
    }

    /// A copy another build of this app wrote is ours too: no offer, and ⇧⌘V and the
    /// offer's button take nothing; this build reads no envelope from it, so ⌘V is AppKit's.
    func testAnotherBuildsCopyOnTheBoardOffersNothingToSeal() throws {
        let client = SealWitness(tag: UUID().uuidString)
        let page = try makePage(client: client)
        page.coordinator.announce(page.textView)
        let caret = NSRange(location: 0, length: 0)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(Data([1, 2, 3]), forType: Self.otherBuildsType))
        XCTAssertTrue(item.setString("[sealed content · tiny]", forType: .string))
        page.pasteboard.clearContents()
        XCTAssertTrue(page.pasteboard.writeObjects([item]))
        let board = page.pasteboard.changeCount
        let length = page.textView.textStorage?.length

        page.model.refreshPasteboardOffer(from: .panel)
        XCTAssertFalse(page.model.pasteboardOffer, "an offer was made over another build's copy")
        page.model.performSealedPaste?()
        XCTAssertEqual(page.model.notice, PageModel.ownCopySealLine, "the button")
        page.model.flash("before the chord")
        XCTAssertTrue(page.textView.performKeyEquivalent(with: try sealChord(in: page.window)))
        XCTAssertEqual(page.model.notice, PageModel.ownCopySealLine, "the chord")
        XCTAssertEqual(client.takes, 0, "the core was asked to take another build's copy")
        XCTAssertEqual(page.pasteboard.changeCount, board, "the board was touched")
        XCTAssertEqual(page.textView.textStorage?.length, length)

        XCTAssertNil(SealedFragment.item(on: page.pasteboard), "this build read another's envelope")
        page.textView.setSelectedRange(caret)
        XCTAssertFalse(page.coordinator.pasteFragment(), "⌘V read another build's envelope")
    }

    /// While a field or the note holds the keys the offer's button seals nothing
    /// and says why, as the slot's place does (ADR-0046).
    func testTheOffersButtonStandsAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let client = SealWitness(tag: UUID().uuidString)
        let page = try makePage(client: client)
        page.coordinator.announce(page.textView)
        page.pasteboard.clearContents()
        page.pasteboard.setString("another app's text", forType: .string)
        page.model.refreshPasteboardOffer(from: .panel)
        XCTAssertTrue(page.model.pasteboardOffer, "the fixture made no offer")
        let length = page.textView.textStorage?.length

        func standsAside(_ holder: String) {
            page.model.flash("before the press")
            page.model.performSealedPaste?()
            XCTAssertEqual(page.model.notice, PageModel.sealWaitsLine, holder)
            XCTAssertEqual(client.takes, 0, "the button sealed under the \(holder)")
            XCTAssertEqual(page.textView.textStorage?.length, length, holder)
            XCTAssertTrue(page.model.pasteboardOffer, "the \(holder)'s wait withdrew the offer")
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
        XCTAssertTrue(page.window.firstResponder === page.textView)
        page.model.performSealedPaste?()
        XCTAssertEqual(client.takes, 1, "the button did not come back")
    }

    // MARK: Past an envelope cap (ADR-0053)

    /// A copy, cut or drag whose envelope would pass a cap writes, deletes and detaches
    /// nothing, an earlier cut stands, and the line names the core's own limit.
    func testACopyCutOrDragPastAnEnvelopeCapNamesItsLimitAndChangesNothing() throws {
        let page = try makePage()
        let client = page.model.coreClient
        page.textView.setSelectedRange(NSRange(location: 8, length: 1))
        page.textView.cut(nil)
        let standing = try XCTUnwrap(page.model.activeCut)
        let limit = 8 * 1024 * 1024
        let ink = String(repeating: "x", count: limit)
        XCTAssertTrue(client.applyOps(
            sheet: page.sheet, json: #"[{"ins":{"at":0,"text":"\#(ink)"}}]"#))
        let length = client.documentRuns(sheet: page.sheet).reduce(0) {
            if case .ink(let text) = $1 { $0 + text.utf16.count } else { $0 + 1 }
        }
        let all = NSRange(location: 0, length: length)
        let board = page.pasteboard.changeCount
        let records = client.ledger().count
        let tooLarge = "a selection holding sealed objects can be at most 8 MiB, so"

        XCTAssertFalse(page.model.copySelection([all], sheet: page.sheet))
        XCTAssertEqual(page.model.notice, "\(tooLarge) nothing was copied.")
        XCTAssertEqual(page.model.cutSelection([all], sheet: page.sheet), .refused)
        XCTAssertEqual(page.model.notice, "\(tooLarge) nothing was cut.")
        XCTAssertNil(page.model.dragFragment(sheet: page.sheet, range: all))
        XCTAssertEqual(page.model.notice, "\(tooLarge) the drag did not start.")

        XCTAssertEqual(page.pasteboard.changeCount, board, "a refusal wrote the board")
        XCTAssertEqual(chips(page).map(\.chipId), [page.chips[0]], "a refused cut moved an object")
        XCTAssertEqual(page.model.activeCut, standing, "the earlier cut went")
        XCTAssertEqual(client.ledger().count, records)
        XCTAssertEqual(
            PageModel.refusalLine(for: .pastCap(.tooManyObjects(limit: 1_024)), .cut),
            "a selection can hold at most 1024 sealed objects, so nothing was cut.")
    }

    /// A core answering the object count cap for every copy and cut once asked to,
    /// since sealing 1025 objects through the seam is too slow for a unit test.
    private final class ObjectCapClient: CompanionClient, @unchecked Sendable {
        var capped = false

        init(tag: String) {
            super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
        }

        override func copyFragmentResult(
            sheet: UInt64, range: NSRange
        ) -> Result<SealedFragment, FragmentRefusal> {
            capped ? .failure(.tooManyObjects(limit: 1_024))
                : super.copyFragmentResult(sheet: sheet, range: range)
        }

        override func cutFragmentResult(
            sheet: UInt64, range: NSRange
        ) -> Result<SealedFragment, FragmentRefusal> {
            capped ? .failure(.tooManyObjects(limit: 1_024))
                : super.cutFragmentResult(sheet: sheet, range: range)
        }
    }

    /// The editor's copy, cut, drag and service write past the object count cap each
    /// name the core's limit and change nothing, and an earlier cut stands.
    func testEveryEditorRoutePastTheObjectCapNamesItsLimitAndChangesNothing() throws {
        let client = ObjectCapClient(tag: UUID().uuidString)
        let page = try makePage(client: client)
        page.textView.setSelectedRange(NSRange(location: 8, length: 1))
        page.textView.cut(nil)
        let standing = try XCTUnwrap(page.model.activeCut, "the control: the cut")
        client.capped = true
        let service = NSPasteboard.withUniqueName()
        addTeardownBlock { service.releaseGlobally() }
        let all = NSRange(location: 0, length: 11)
        let capped = "a selection can hold at most 1024 sealed objects, so"
        let routes: [(name: String, line: String, run: () -> Void)] = [
            ("copy", "\(capped) nothing was copied.", { page.textView.copy(nil) }),
            ("cut", "\(capped) nothing was cut.", { page.textView.cut(nil) }),
            ("drag", "\(capped) the drag did not start.", {
                guard case .refused = page.coordinator.beginPageDrag() else {
                    return XCTFail("the drag began")
                }
            }),
            ("service", "\(capped) nothing was copied.", {
                XCTAssertFalse(page.textView.writeSelection(
                    to: service, types: page.textView.writablePasteboardTypes))
            }),
        ]
        for route in routes {
            page.textView.setSelectedRange(all)
            let board = page.pasteboard.changeCount
            let written = service.changeCount
            let text = page.textView.string

            route.run()

            XCTAssertEqual(page.model.notice, route.line, route.name)
            XCTAssertEqual(page.pasteboard.changeCount, board, "\(route.name) wrote the board")
            XCTAssertEqual(service.changeCount, written, "\(route.name) wrote the service's board")
            XCTAssertEqual(page.textView.string, text, "\(route.name) changed the page")
            XCTAssertEqual(chips(page).map(\.chipId), [page.chips[0]], route.name)
            XCTAssertEqual(page.model.activeCut, standing, "\(route.name): the earlier cut went")
        }
    }

    // MARK: A page past its deadline (ADR-0052)

    /// Puts `page` past its deadline with no sweep: a one hour rung, two hours on.
    /// After a cut the re-mint moves the chip ids, so `keepsChipIDs` is false there.
    private func age(_ page: Page, keepsChipIDs: Bool = true) throws {
        let client = page.model.coreClient
        let tab = try XCTUnwrap(page.model.tabs.first { $0.pageID == page.sheet }?.id)
        XCTAssertTrue(client.setRung(tab: tab, rung: .oneHour))
        XCTAssertTrue(client.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        // The re-mint is dense, so the editor's ids still name what the core holds.
        XCTAssertTrue(client.tabs().contains { $0.pageID == page.sheet }, "the page was swept")
        if keepsChipIDs { XCTAssertEqual(chips(page).map(\.chipId), page.chips) }
    }

    private func sent(_ page: Page) -> [String] {
        page.model.coreClient.ledger().filter { $0.event == "sent" }.map(\.destination)
    }

    /// From its deadline, before any sweep, each way out of a page the person asks
    /// for refuses, writes and records nothing, and settles at once with its line.
    func testEveryWayOutOfAPagePastItsDeadlineRefusesAndTheSettleTakesIt() throws {
        let routes: [(name: String, run: (Page) -> Void)] = [
            ("copy", {
                $0.textView.setSelectedRange(self.whole)
                $0.textView.copy(nil)
            }),
            ("cut", {
                $0.textView.setSelectedRange(self.whole)
                $0.textView.cut(nil)
            }),
            ("copy decrypted", { XCTAssertFalse($0.coordinator.copyOutChip(at: 3)) }),
            ("copy NAME=value", { XCTAssertFalse($0.coordinator.copyNameValue(at: 3)) }),
            ("copy name", { XCTAssertFalse($0.coordinator.copyName(at: 3)) }),
            ("the note", {
                $0.coordinator.beginNote(at: 3)
                XCTAssertNotEqual($0.coordinator.noteEditor?.isOpen, true, "the note opened")
            }),
            ("the drag", {
                $0.textView.setSelectedRange(self.whole)
                guard case .refused = $0.coordinator.beginPageDrag() else {
                    return XCTFail("the drag began")
                }
            }),
        ] + appKitReaders.map { way in (way.name, { way.run($0.textView) }) }
        for route in routes {
            let page = try makePage()
            XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chips[0], sheet: page.sheet))
            try age(page)
            let board = page.pasteboard.changeCount

            route.run(page)

            XCTAssertEqual(page.model.notice, PageModel.pageExpiredLine, route.name)
            XCTAssertFalse(
                page.model.tabs.contains { $0.pageID == page.sheet },
                "\(route.name): the page outlived its refusal")
            XCTAssertEqual(page.pasteboard.changeCount, board, "\(route.name) wrote the board")
            XCTAssertEqual(sent(page), [], "\(route.name) recorded a sent")
            XCTAssertNil(page.model.activeCut, route.name)
        }
    }

    /// AppKit's readers outside the text menu: look up, speech, spelling, grammar, text
    /// checking, completion, Quick Look and the style copies. Run only where a gate refuses:
    /// one that ran would speak, look up, hand the text to the spell server or write a board
    /// every process reads. A refused toggle leaves its setting as it stood.
    private var appKitReaders: [(name: String, run: (NSTextView) -> Void)] {
        let everything = { (view: NSTextView) in NSRange(location: 0, length: view.string.utf16.count) }
        return [
            ("Speech", {
                $0.selectAll(nil)
                $0.startSpeaking(nil)
            }),
            ("Look Up by force click", { view in
                guard let event = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: view.convert(NSPoint(x: 4, y: 4), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return XCTFail("no event") }
                view.quickLook(with: event)
            }),
            ("Look Up by key", {
                $0.selectAll(nil)
                $0.quickLookPreviewItems(nil)
            }),
            ("the definition of a range", {
                $0.showDefinition(
                    for: nil, range: NSRange(location: 0, length: 2), options: nil,
                    baselineOriginProvider: nil)
            }),
            ("the definition at a point", {
                $0.showDefinition(for: NSAttributedString(string: "ab"), at: .zero)
            }),
            ("Check Document Now", { $0.checkSpelling(nil) }),
            ("Show Spelling and Grammar", { $0.showGuessPanel(nil) }),
            ("Replace All", { $0.checkTextInDocument(nil) }),
            ("Replace in Selection", {
                $0.selectAll(nil)
                $0.checkTextInSelection(nil)
            }),
            ("Check Spelling While Typing", {
                $0.toggleContinuousSpellChecking(nil)
                XCTAssertFalse($0.isContinuousSpellCheckingEnabled, "it turned on")
            }),
            ("Check Grammar With Spelling", {
                let grammar = $0.isGrammarCheckingEnabled
                $0.toggleGrammarChecking(nil)
                XCTAssertEqual($0.isGrammarCheckingEnabled, grammar, "it toggled")
            }),
            ("the spelling panel's Ignore", { $0.ignoreSpelling(NSTextField(string: "ab")) }),
            ("a check as the text changes", {
                $0.checkText(in: everything($0), types: NSTextCheckingAllTypes, options: [:])
            }),
            ("completion", { $0.complete(nil) }),
            ("Quick Look Attachments", {
                $0.selectAll(nil)
                $0.toggleQuickLookPreviewPanel(nil)
            }),
            ("Copy Style", {
                $0.selectAll(nil)
                $0.copyFont(nil)
            }),
            ("Copy Ruler", {
                $0.selectAll(nil)
                $0.copyRuler(nil)
            }),
        ]
    }

    /// While a field or the note holds the keys, the page's readers stand aside without
    /// asking the page (ADR-0046); the note's own, and the page's once the keys come
    /// back, refuse past the deadline and settle (ADR-0052).
    func testAppKitsReadersStandAsideForTheKeysAndRefusePastTheDeadline() throws {
        for way in appKitReaders {
            let page = try makePage()
            page.coordinator.beginNote(at: 3)
            drainMainQueue()
            let note = try XCTUnwrap(page.coordinator.noteEditor)
            XCTAssertTrue(note.holdsKeys)
            try age(page)

            way.run(page.textView)
            XCTAssertNotEqual(page.model.notice, PageModel.pageExpiredLine, "\(way.name) under the note")
            XCTAssertTrue(page.model.tabs.contains { $0.pageID == page.sheet }, way.name)

            way.run(note.textView)
            XCTAssertEqual(page.model.notice, PageModel.pageExpiredLine, "the note's \(way.name)")
            XCTAssertFalse(page.model.tabs.contains { $0.pageID == page.sheet }, way.name)
        }
        for way in appKitReaders {
            let page = try makePage()
            XCTAssertTrue(page.window.makeFirstResponder(page.field))
            drainMainQueue()
            try age(page)

            way.run(page.textView)
            XCTAssertNotEqual(page.model.notice, PageModel.pageExpiredLine, "\(way.name) under the field")
            XCTAssertTrue(page.model.tabs.contains { $0.pageID == page.sheet }, way.name)

            XCTAssertTrue(page.window.makeFirstResponder(page.textView))
            drainMainQueue()
            way.run(page.textView)
            XCTAssertEqual(page.model.notice, PageModel.pageExpiredLine, way.name)
            XCTAssertFalse(page.model.tabs.contains { $0.pageID == page.sheet }, way.name)
        }
    }

    /// The core refuses to enrol a page past its deadline in sync, and that refusal
    /// settles the page with its line as every other does; a standing page enrols.
    func testARefusedEnrolmentOfAPagePastItsDeadlineSettlesIt() throws {
        let standing = try makePage()
        standing.model.sync.enrol(page: standing.sheet, on: true)
        XCTAssertTrue(standing.model.sync.isEnrolled(standing.sheet), "the control: it enrols")
        XCTAssertNotEqual(standing.model.notice, PageModel.pageExpiredLine)

        let page = try makePage()
        try age(page)
        page.model.sync.enrol(page: page.sheet, on: true)

        XCTAssertFalse(page.model.sync.isEnrolled(page.sheet))
        XCTAssertEqual(page.model.notice, PageModel.pageExpiredLine)
        XCTAssertFalse(page.model.tabs.contains { $0.pageID == page.sheet }, "no settle")
    }

    /// A conceal of a page or an object past its deadline sends nothing, and its
    /// refusal settles: the draft goes with its subject and the line says why.
    func testAConcealPastTheDeadlineSendsNothingAndTheSettleTakesThePage() throws {
        for onPage in [false, true] {
            let page = try makePage()
            let client = page.model.coreClient
            XCTAssertTrue(client.stubWireForTests(status: 0))
            try age(page)
            let target: ConcealDraft.Target = onPage ? .page(page.sheet) : .chip(page.chips[0])
            page.model.beginConceal(target)
            let draft = try XCTUnwrap(page.model.concealDraft)
            let outcome = onPage
                ? client.concealSheet(id: page.sheet, ttlSecs: draft.ttlSecs, passphrase: "", recipient: "")
                : client.concealChip(id: page.chips[0], ttlSecs: draft.ttlSecs, passphrase: "", recipient: "")
            XCTAssertFalse(outcome.ok)
            XCTAssertNil(client.lastWireForTests(), "the conceal reached the wire")

            page.model.finishConceal(outcome, for: target, draftID: draft.id)

            XCTAssertNil(page.model.concealDraft, "the draft outlived its subject")
            XCTAssertEqual(page.model.notice, PageModel.pageExpiredLine)
            XCTAssertFalse(page.model.tabs.contains { $0.pageID == page.sheet })
            XCTAssertEqual(sent(page), [])
        }
    }

    /// A core that refuses every note batch once asked to, as a batch it cannot place.
    private final class NoteRefusingClient: CompanionClient, @unchecked Sendable {
        var refusesNoteBatches = false

        init(tag: String) {
            super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
        }

        override func applyNoteOps(
            chip: UInt64, json: String, intent: EditorEditIntent = .typing,
            selection: EditorEditSelection? = nil
        ) -> Bool {
            !refusesNoteBatches
                && super.applyNoteOps(chip: chip, json: json, intent: intent, selection: selection)
        }
    }

    /// An open note whose text the core refuses after a refused batch closes rather
    /// than standing empty, and the settle takes its page with the line (ADR-0052).
    func testAnOpenNoteTheCoreRefusesClosesAndTheSettleTakesItsPage() throws {
        let client = NoteRefusingClient(tag: UUID().uuidString)
        let page = try makePage(client: client)
        page.coordinator.beginNote(at: 3)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        note.textView.insertText("rotate", replacementRange: NSRange(location: NSNotFound, length: 0))
        drainMainQueue()
        XCTAssertEqual(page.model.noteText(chip: page.chips[0]), "rotate", "the control")
        try age(page)
        client.refusesNoteBatches = true

        note.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        drainMainQueue()

        XCTAssertFalse(note.isOpen, "the refused note stood open")
        XCTAssertEqual(note.textView.string, "", "the closed note kept ink")
        XCTAssertEqual(page.model.notice, PageModel.pageExpiredLine)
        XCTAssertFalse(page.model.tabs.contains { $0.pageID == page.sheet }, "no settle")
    }

    /// A core that refuses both decrypted copies of a live object, as a failed
    /// pasteboard write would.
    private final class RefusedCopyClient: CompanionClient, @unchecked Sendable {
        init(tag: String) {
            super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
        }

        override func copyOutChip(id: UInt64) -> Bool { false }
        override func copyNameValue(chip: UInt64) -> Bool { false }
    }

    /// An object's copy or conceal refused for its own reason, while another page's
    /// late timer is due, settles that page but never says this one expired.
    func testAnObjectsRefusalSaysExpiredOnlyWhenItsOwnPageWent() throws {
        let routes: [(name: String, line: String?, run: (Page) -> Void)] = [
            ("copy decrypted", PageModel.copyRefusedLine, {
                XCTAssertFalse($0.coordinator.copyOutChip(at: 3))
            }),
            ("copy NAME=value", PageModel.copyRefusedLine, {
                XCTAssertFalse($0.coordinator.copyNameValue(at: 3))
            }),
            ("conceal", nil, { page in
                let target = ConcealDraft.Target.chip(page.chips[0])
                page.model.beginConceal(target)
                guard let draft = page.model.concealDraft else { return XCTFail("no draft") }
                page.model.finishConceal(
                    ConcealOutcome(ok: false, receiptId: nil, error: "the server did not answer"),
                    for: target, draftID: draft.id)
                XCTAssertNotNil(page.model.concealDraft, "the draft went with another page")
            }),
        ]
        for route in routes {
            let client = RefusedCopyClient(tag: UUID().uuidString)
            let page = try makePage(client: client)
            XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chips[0], sheet: page.sheet))
            let other = try anotherPageComesDue(beside: page)
            let notice = page.model.notice

            route.run(page)

            XCTAssertFalse(
                page.model.tabs.contains { $0.pageID == other }, "\(route.name): no settle")
            XCTAssertTrue(
                page.model.tabs.contains { $0.pageID == page.sheet }, "\(route.name) took its page")
            XCTAssertEqual(page.model.notice, route.line ?? notice, route.name)
        }
    }

    /// A second page with ink, past its deadline with no sweep; `page`'s own stays young.
    private func anotherPageComesDue(beside page: Page) throws -> UInt64 {
        let client = page.model.coreClient
        page.model.newPage()
        let other = try XCTUnwrap(page.model.selectedPageID)
        XCTAssertTrue(client.applyOps(sheet: other, json: #"[{"ins":{"at":0,"text":"due"}}]"#))
        let tab = try XCTUnwrap(page.model.tabs.first { $0.pageID == other }?.id)
        XCTAssertTrue(client.setRung(tab: tab, rung: .oneHour))
        XCTAssertTrue(client.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        XCTAssertTrue(client.tabs().contains { $0.pageID == other }, "the control: a sweep ran")
        return other
    }

    /// An object that stood on no page when its route refused, as a stale menu's would,
    /// takes the route's own line, though the settle takes another page that came due.
    func testAnUnknownObjectsRefusalNeverSaysAPageExpired() throws {
        let unknown: UInt64 = 4_242
        let routes: [(name: String, line: String?, run: (Page) -> Void)] = [
            ("copy decrypted", PageModel.copyRefusedLine, {
                XCTAssertFalse($0.model.copyOutChip(unknown))
            }),
            ("copy NAME=value", PageModel.copyRefusedLine, {
                XCTAssertFalse($0.model.copyChipNameValue(unknown))
            }),
            ("conceal", nil, {
                $0.model.finishConceal(
                    ConcealOutcome(ok: false, receiptId: nil, error: "that content is gone"),
                    for: .chip(unknown), draftID: UUID())
            }),
        ]
        for route in routes {
            let page = try makePage()
            XCTAssertFalse(page.model.coreClient.chipStands(unknown), "the control: no such object")
            XCTAssertTrue(page.model.coreClient.chipStands(page.chips[0]), "the control: one stands")
            let other = try anotherPageComesDue(beside: page)
            let notice = page.model.notice

            route.run(page)

            XCTAssertFalse(
                page.model.tabs.contains { $0.pageID == other }, "\(route.name): no settle")
            XCTAssertEqual(page.model.notice, route.line ?? notice, route.name)
        }
    }

    /// AppKit's own ways out, which no core route sees, ask first: past the deadline a
    /// service's write of ink alone, a drag of ink stretches, Use Selection for Find and
    /// the note's copy, cut, drag, service and Use Selection for Find give nothing out, and
    /// the settle takes the page with its line. The finder is asked only through its gate,
    /// since a finder that ran would write the find pasteboard every process reads.
    func testAppKitsWaysOutOfAPagePastItsDeadlineAskFirstAndSettle() throws {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let asks: [(name: String, run: (Page) throws -> Void)] = [
            ("a service of ink alone", {
                $0.textView.setSelectedRange(NSRange(location: 0, length: 2))
                XCTAssertFalse($0.textView.writeSelection(
                    to: board, types: $0.textView.writablePasteboardTypes))
                XCTAssertFalse($0.textView.writeSelection(to: board, type: .string), "once gone")
            }),
            ("a drag of ink stretches", {
                $0.textView.selectedRanges = [
                    NSValue(range: NSRange(location: 0, length: 2)),
                    NSValue(range: NSRange(location: 5, length: 2)),
                ]
                guard case .ordinary = $0.coordinator.beginPageDrag() else {
                    return XCTFail("the core was asked for ink stretches")
                }
                XCTAssertFalse($0.coordinator.givesOutShownText(), "AppKit's drag would run")
            }),
            ("the note", {
                let note = try XCTUnwrap($0.coordinator.noteEditor)
                XCTAssertTrue(note.isOpen)
                note.textView.selectAll(nil)
                XCTAssertFalse(note.textView.writeSelection(to: board, types: [.string]))
                XCTAssertEqual(
                    note.textView.coordinator?.givesOutShownText(), false,
                    "the note's copy, cut or drag would run")
            }),
            ("use selection for find", {
                $0.textView.setSelectedRange(NSRange(location: 0, length: 2))
                XCTAssertTrue($0.textView.refusesFinderAction(self.useSelectionForFind))
            }),
            ("the note's use selection for find", {
                let note = try XCTUnwrap($0.coordinator.noteEditor?.textView)
                note.selectAll(nil)
                XCTAssertTrue(note.refusesFinderAction(self.useSelectionForFind))
            }),
        ]
        for ask in asks {
            let page = try makePage()
            XCTAssertTrue(page.model.applyNoteOps(
                chip: page.chips[0], json: #"[{"ins":{"at":0,"text":"rotate monthly"}}]"#,
                intent: .typing, selection: nil))
            if ask.name.hasPrefix("the note") {
                page.coordinator.beginNote(at: 3)
                drainMainQueue()
            }
            XCTAssertTrue(page.coordinator.givesOutShownText(), "\(ask.name): the control")
            try age(page)
            let written = board.changeCount

            try ask.run(page)

            XCTAssertEqual(board.changeCount, written, "\(ask.name) wrote a page past its deadline")
            XCTAssertEqual(page.model.notice, PageModel.pageExpiredLine, ask.name)
            XCTAssertFalse(
                page.model.tabs.contains { $0.pageID == page.sheet }, "\(ask.name): no settle")
        }
    }

    /// The name field's own editor over the object at 3, holding the keys, its draft selected.
    private func openNameField(_ page: Page) throws -> SealedNameTextView {
        page.coordinator.beginNaming(at: 3)
        drainMainQueue()
        let field = try XCTUnwrap(page.coordinator.nameEditor?.field, "no field opened")
        let editor = try XCTUnwrap(field.currentEditor() as? SealedNameTextView, "not its own")
        editor.selectAll(nil)
        return editor
    }

    /// While its page stands a name leaves as a person asks: Copy name and the name
    /// field's copy and cut write it on the ambient board, and the field serves it.
    func testANameCopiesFromTheZoneAndTheFieldWhileItsPageStands() throws {
        let page = try makePage()
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chips[0], sheet: page.sheet))
        XCTAssertTrue(page.coordinator.copyName(at: 3))
        XCTAssertEqual(page.pasteboard.string(forType: .string), "API_KEY")
        XCTAssertEqual(page.model.notice, PageModel.copiedNameLine)

        let editor = try openNameField(page)
        page.pasteboard.clearContents()
        editor.copy(nil)
        XCTAssertEqual(page.pasteboard.string(forType: .string), "API_KEY", "the field's copy")
        XCTAssertTrue(editor.givesOut, "the field's drag")
        XCTAssertTrue(editor.writeSelection(to: board, types: editor.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "API_KEY", "the field's service")
        page.pasteboard.clearContents()
        editor.cut(nil)
        XCTAssertEqual(page.pasteboard.string(forType: .string), "API_KEY", "the field's cut")
        XCTAssertEqual(editor.string, "", "the cut took the draft")
        XCTAssertTrue(page.model.tabs.contains { $0.pageID == page.sheet })
    }

    /// A name is part of its page: past the deadline Copy name (above) and the name
    /// field's copy, cut, drag, service and AppKit's readers give nothing out, and the
    /// settle takes the page with its line. The drag is asked only through its gate, as
    /// a drag that ran would write the system's drag board.
    func testANamePastItsPagesDeadlineGivesNothingOutAndTheSettleTakesThePage() throws {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let asks: [(name: String, run: (SealedNameTextView) -> Void)] = [
            ("the field's copy", { $0.copy(nil) }),
            ("the field's cut", { $0.cut(nil) }),
            ("the field's service", {
                let legacy = SealedFragment.legacyStringType
                XCTAssertFalse($0.writeSelection(to: board, types: $0.writablePasteboardTypes))
                XCTAssertFalse($0.writeSelection(to: board, type: legacy), "once gone")
            }),
            ("the field's drag", { XCTAssertFalse($0.givesOut, "AppKit's drag would run") }),
        ] + appKitReaders.map { way in ("the field's \(way.name)", { way.run($0) }) }
        for ask in asks {
            let page = try makePage()
            XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chips[0], sheet: page.sheet))
            let editor = try openNameField(page)
            XCTAssertEqual(editor.string, "API_KEY", "the control: the field holds the name")
            try age(page)
            let written = (page.pasteboard.changeCount, board.changeCount)

            ask.run(editor)

            XCTAssertEqual(page.pasteboard.changeCount, written.0, "\(ask.name) wrote the board")
            XCTAssertEqual(board.changeCount, written.1, "\(ask.name) served the name")
            XCTAssertEqual(page.model.notice, PageModel.pageExpiredLine, ask.name)
            XCTAssertFalse(
                page.model.tabs.contains { $0.pageID == page.sheet }, "\(ask.name): no settle")
        }
    }

    /// Use Selection for Find as the Find menu sends it; only the tag is read.
    private var useSelectionForFind: NSMenuItem {
        let item = NSMenuItem(
            title: "Use Selection for Find",
            action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
        item.tag = NSTextFinder.Action.setSearchString.rawValue
        return item
    }

    /// While the page stands, Use Selection for Find over ink goes to the finder, on the
    /// page and in the note, and over an object still refuses with its own line.
    func testUseSelectionForFindGoesToTheFinderWhileThePageStands() throws {
        let page = try makePage()
        XCTAssertTrue(page.model.applyNoteOps(
            chip: page.chips[0], json: #"[{"ins":{"at":0,"text":"rotate monthly"}}]"#,
            intent: .typing, selection: nil))
        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertFalse(page.textView.refusesFinderAction(useSelectionForFind))
        page.textView.setSelectedRange(NSRange(location: 3, length: 1))
        XCTAssertTrue(page.textView.refusesFinderAction(useSelectionForFind))
        XCTAssertEqual(page.model.notice, "a chip has no text to search for")
        page.coordinator.beginNote(at: 3)
        drainMainQueue()
        let note = try XCTUnwrap(page.coordinator.noteEditor?.textView)
        note.selectAll(nil)
        XCTAssertFalse(note.refusesFinderAction(useSelectionForFind))
        XCTAssertTrue(page.model.tabs.contains { $0.pageID == page.sheet })
    }

    /// What another app reads from a copy: a rich or a plain text reader gets
    /// the public text, with a placeholder where each object stood.
    func testAnotherAppReadsThePublicTextAlone() throws {
        let page = try makePage()
        page.textView.setSelectedRange(whole)
        page.textView.copy(nil)
        let publicText = "ab \(placeholder) cd \(placeholder) ef"
        let rich = page.pasteboard.readObjects(forClasses: [NSAttributedString.self])
        XCTAssertEqual((rich?.first as? NSAttributedString)?.string, publicText)
        let plain = page.pasteboard.readObjects(forClasses: [NSString.self])
        XCTAssertEqual(plain?.first as? String, publicText)
    }

    /// While a field or the note holds the keys, Paste and Paste and Match Style
    /// reach the holder and the page places nothing (ADR-0046).
    func testPasteStandsAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let page = try makePage()
        page.textView.setSelectedRange(whole)
        page.textView.copy(nil)
        let pasteAction = #selector(NSText.paste(_:))
        let items = [
            NSMenuItem(title: "Paste", action: pasteAction, keyEquivalent: ""),
            NSMenuItem(
                title: "Paste and Match Style",
                action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: ""),
        ]
        let caret = NSRange(location: 0, length: 0)
        XCTAssertTrue(page.textView.answersChords, "the control: the page pastes")
        let length = page.textView.textStorage?.length

        func standsAside(_ holder: String) {
            for item in items {
                XCTAssertFalse(page.textView.validateMenuItem(item), "\(item.title), \(holder)")
            }
            page.textView.setSelectedRange(caret)
            page.textView.paste(nil)
            page.textView.pasteAsPlainText(nil)
            XCTAssertEqual(page.textView.textStorage?.length, length, "the page pasted under the \(holder)")
            XCTAssertEqual(chips(page).map(\.chipId), page.chips, holder)
        }

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertFalse(answerer(of: pasteAction, in: page.window) === page.textView)
        standsAside("field")

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        page.coordinator.beginNote(at: 3)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        XCTAssertTrue(answerer(of: pasteAction, in: page.window) === note.textView)
        standsAside("note")

        note.escape()
        drainMainQueue()
        XCTAssertTrue(page.window.firstResponder === page.textView)
        page.textView.setSelectedRange(caret)
        page.textView.paste(nil)
        XCTAssertEqual(chips(page).count, 4, "the paste did not come back")
    }
}
