import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class CheckpointMarkdownPreviewTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "companion-checkpoint-preview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeModel(defaults: UserDefaults? = nil) throws -> PageModel {
        let model = isolatedModel(defaults: try defaults ?? makeDefaults())
        model.showsTimeUnits = true
        return model
    }

    @discardableResult
    private func page(in model: PageModel, saying ink: String = "# Heading\nbody") throws -> UInt64 {
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        model.syncDocument(sheet: page, runs: [.ink(ink)])
        XCTAssertEqual(source(for: page, in: model), ink)
        return page
    }

    private func source(for page: UInt64, in model: PageModel) -> String {
        model.coreClient.documentRuns(sheet: page).reduce(into: "") {
            if case .ink(let ink) = $1 { $0 += ink }
        }
    }

    private func summary(for page: UInt64, in model: PageModel) throws -> TabSummary {
        try XCTUnwrap(model.tabs.first { $0.pageID == page })
    }

    private func button(in header: DayHeaderView) throws -> NSButton {
        try XCTUnwrap(header.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func header(for page: UInt64, in model: PageModel) throws -> DayHeaderView {
        let header = DayHeaderView(model: model)
        header.show(
            words: .init(day: "Today", time: "12:00"), spokenLabel: "Today",
            mark: .none, summary: try summary(for: page, in: model))
        header.frame = NSRect(x: 0, y: 0, width: 420, height: header.preferredHeight)
        header.place()
        return header
    }

    private struct Roll {
        let window: NSWindow
        let scroll: NSScrollView
        let stack: DayStackView
        let coordinator: InkEditorView.Coordinator
    }

    private func mountRoll(_ model: PageModel) throws -> Roll {
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = DayScrollView.makeRoll(
            model: model, coordinator: coordinator, emptyHint: "hint")
        let frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.frame = frame
        scroll.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        stack.update(
            projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
        return Roll(window: window, scroll: scroll, stack: stack, coordinator: coordinator)
    }

    private func header(for page: UInt64, in roll: Roll) throws -> DayHeaderView {
        try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == page }?.header)
    }

    private func body(for page: UInt64, in roll: Roll) throws -> NSView {
        try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == page }?.body)
    }

    private func preview(for page: UInt64, in roll: Roll) throws -> MarkdownPreviewView {
        let preview = try XCTUnwrap(roll.stack.previewRegions[page])
        XCTAssertTrue(try body(for: page, in: roll) === preview)
        XCTAssertNil(roll.stack.quietRegions[page])
        XCTAssertTrue(preview.superview === roll.stack)
        XCTAssertFalse(preview.isHidden)
        XCTAssertFalse(preview.isEditable)
        XCTAssertGreaterThan(preview.frame.width, 0)
        XCTAssertGreaterThan(preview.frame.height, 0)
        return preview
    }

    private func headingIsStyled(_ storage: NSTextStorage) -> Bool {
        (storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont) != InkStyle.baseFont
    }

    // MARK: The preview as a page's text (Law 0001, the preview's rows)

    /// The links a preview opened, recorded in place of the browser.
    private final class OpenedLinks {
        var urls: [URL] = []
    }

    /// A model whose copies go to a board of the test's own and whose links open here.
    private struct Gated {
        let model: PageModel
        let pasteboard: NSPasteboard
        let opened: OpenedLinks
    }

    private func makeGatedModel() throws -> Gated {
        let defaults = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-preview-gated-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = CompanionClient.ephemeral(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        let opened = OpenedLinks()
        let model = PageModel(
            formFactor: .backdrop, defaults: defaults,
            seams: .init(
                stateDirectory: directory, client: client,
                clearClipboardIfOurs: { false }, ambientPasteboard: pasteboard,
                openURL: { opened.urls.append($0) }))
        model.showsTimeUnits = true
        return Gated(model: model, pasteboard: pasteboard, opened: opened)
    }

    private static let secretLink = URL(string: "https://example.com/secret")!

    /// `# Heading\nbody [x](<secretLink>) <SECRET> tail`, the object sealed from `SECRET`,
    /// with the preview on; the page is the selected one.
    private static let sealedInk = "# Heading\nbody [x](\(secretLink.absoluteString)) SECRET tail"

    /// Where the object stands in the page's source once `SECRET` is sealed.
    private static let objectIndex = (sealedInk as NSString).range(of: "SECRET").location

    private func sealedPreviewPage(in model: PageModel) throws -> (page: UInt64, chip: UInt64) {
        let page = try page(in: model, saying: Self.sealedInk)
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let editor = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator))
        let secret = NSRange(location: Self.objectIndex, length: 6)
        editor.setSelectedRange(secret)
        coordinator.sealSelectionOrLine()
        let chip = try XCTUnwrap(coordinator.chipAttachment(at: secret.location)?.info.chipId)
        coordinator.leavePage(editor, scrollView: nil)
        model.toggleMarkdownPreview(for: page)
        return (page, chip)
    }

    /// The envelope's documented shape (core interface, Envelope, version 1), read only here.
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

    /// The character index of the first link the preview draws.
    private func linkIndex(in preview: MarkdownPreviewView) throws -> Int {
        let storage = try XCTUnwrap(preview.textStorage)
        return try XCTUnwrap(
            (0..<storage.length).first { storage.attribute(.link, at: $0, effectiveRange: nil) != nil },
            "no link was rendered")
    }

    /// A secondary click near the view's top left corner, over ink and no object.
    private func secondaryClick(in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: view.convert(NSPoint(x: 4, y: 4), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// The readers this machine's services may or may not add to a text menu, as items of
    /// the test's own, with a link's Open With and Edit Link… beside them.
    private func readerControls() -> [NSMenuItem] {
        var items = [
            ("Search With Google", "_searchWithGoogleFromMenu:"),
            ("Show Writing Tools", "showWritingTools:"),
            ("Look Up “body”", "_rvMenuItemAction:"),
            ("Translate “body”", "_rvMenuItemAction:"),
            ("Edit Link…", "orderFrontLinkPanel:"),
        ].map { NSMenuItem(title: $0.0, action: Selector(($0.1)), keyEquivalent: "") }
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.identifier = NSUserInterfaceItemIdentifier("__NSTextViewContextSubmenuIdentifierOpenWith")
        let app = NSMenuItem(title: "Browser.app", action: nil, keyEquivalent: "")
        app.representedObject = URL(fileURLWithPath: "/Applications/Browser.app")
        openWith.submenu = NSMenu()
        openWith.submenu?.addItem(app)
        items.append(openWith)
        let speech = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        speech.submenu = NSMenu()
        speech.submenu?.addItem(NSMenuItem(
            title: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: ""))
        items.append(speech)
        return items
    }

    /// The text menu AppKit builds over `view` on a base seeded with `readerControls()`.
    private func seededMenu(_ view: NSTextView) throws -> NSMenu {
        let base = NSMenu()
        readerControls().forEach(base.addItem)
        let kept = view.menu
        view.menu = base
        defer { view.menu = kept }
        return try XCTUnwrap(view.menu(for: secondaryClick(in: view)))
    }

    /// The readers `menu` still offers, by name.
    private func readers(in menu: NSMenu) -> [String] {
        var found: [String] = []
        if menu.items.contains(where: TextOffers.isShare) { found.append("Share") }
        if menu.items.contains(where: TextOffers.isLookUpOrTranslate) { found.append("Look Up") }
        if menu.items.contains(where: TextOffers.isSpeech) { found.append("Speech") }
        if menu.items.contains(where: TextOffers.isSpelling) { found.append("Spelling") }
        if menu.items.contains(where: TextOffers.isWebSearch) { found.append("Search With") }
        if menu.items.contains(where: TextOffers.isWritingTools) { found.append("Writing Tools") }
        if menu.items.contains(where: TextOffers.isOpenWith) { found.append("Open With") }
        if menu.items.contains(where: TextOffers.isEditLink) { found.append("Edit Link") }
        return found
    }

    /// Makes the application's current event a click with `flags`, as a real one would be.
    private func click(with flags: NSEvent.ModifierFlags) throws {
        let app = NSApplication.shared
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        app.postEvent(event, atStart: true)
        let current = app.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
        XCTAssertTrue(app.currentEvent === current, "the click is not the current event")
    }

    /// A ⌘-click on the preview's link, through the delegate, as AppKit's tracking sends it.
    private func commandClickLink(in preview: MarkdownPreviewView) throws {
        let index = try linkIndex(in: preview)
        let link = try XCTUnwrap(preview.textStorage?.attribute(.link, at: index, effectiveRange: nil))
        try click(with: .command)
        defer { try? click(with: []) }
        XCTAssertTrue(preview.delegate?.textView?(preview, clickedOnLink: link, at: index) == true)
    }

    /// Puts `page` past its deadline with no sweep: a one hour rung, two hours on.
    private func age(_ page: UInt64, in model: PageModel) throws {
        let tab = try XCTUnwrap(model.tabs.first { $0.pageID == page }?.id)
        XCTAssertTrue(model.coreClient.setRung(tab: tab, rung: .oneHour))
        XCTAssertTrue(model.coreClient.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        XCTAssertTrue(model.coreClient.tabs().contains { $0.pageID == page }, "the page was swept")
    }

    private func mouseDragged(in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: view.convert(NSPoint(x: 30, y: 12), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// The preview's text menu offers no reader of the selection and the view answers
    /// Writing Tools, typing suggestions, inline predictions and data detectors with none,
    /// as the page's own editor does (Law 0001, export row): the menu is built on items of
    /// the test's own so no runner's services decide it.
    func testAPreviewOffersNoReaderAndAnswersWritingToolsSuggestionsAndDetectorsWithNone() throws {
        let gated = try makeGatedModel()
        let (page, _) = try sealedPreviewPage(in: gated.model)
        let roll = try mountRoll(gated.model)
        defer { roll.window.close() }
        let preview = try preview(for: page, in: roll)
        XCTAssertTrue(roll.window.makeFirstResponder(preview))
        preview.setSelectedRange(NSRange(location: 0, length: 7))

        let menu = try XCTUnwrap(preview.menu(for: secondaryClick(in: preview)))
        XCTAssertEqual(readers(in: menu), [])
        XCTAssertEqual(readers(in: try seededMenu(preview)), [])
        XCTAssertFalse(zip(menu.items, menu.items.dropFirst()).contains {
            $0.isSeparatorItem && $1.isSeparatorItem
        }, "a reader left a doubled separator")

        XCTAssertFalse(preview.isAutomaticTextCompletionEnabled)
        preview.toggleAutomaticTextCompletion(nil)
        XCTAssertFalse(preview.isAutomaticTextCompletionEnabled, "the toggle")
        XCTAssertFalse(preview.isAutomaticDataDetectionEnabled)
        preview.toggleAutomaticDataDetection(nil)
        XCTAssertFalse(preview.isAutomaticDataDetectionEnabled, "the toggle")
        XCTAssertFalse(preview.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(preview.isEditable)
        guard #available(macOS 15.0, *) else { return }
        XCTAssertEqual(preview.writingToolsBehavior, .none)
        XCTAssertEqual(preview.inlinePredictionType, .no)
    }

    /// The preview copies what it shows through the core (Law 0001, copy row): one fragment
    /// whose ink runs are the rendered text between the objects, never the source markdown,
    /// and whose references are the objects, in rendered order; the public text puts a
    /// placeholder where each object stood, and a service takes the public text alone.
    func testAPreviewCopiesWhatItShowsAsOneFragmentWithEachObjectByReference() throws {
        let gated = try makeGatedModel()
        let (page, chip) = try sealedPreviewPage(in: gated.model)
        let roll = try mountRoll(gated.model)
        defer { roll.window.close() }
        let preview = try preview(for: page, in: roll)
        XCTAssertTrue(roll.window.makeFirstResponder(preview))
        XCTAssertEqual(preview.string, "Heading\nbody x \u{FFFC} tail\n")
        preview.selectAll(nil)

        preview.copy(nil)

        let envelope = try envelope(on: gated.pasteboard)
        XCTAssertEqual(envelope.version, 1)
        XCTAssertNil(envelope.cut)
        XCTAssertEqual(envelope.nodes.map(\.ink), ["Heading\nbody x ", nil, " tail\n"])
        let reference = try XCTUnwrap(envelope.nodes[1].ref)
        let own = try XCTUnwrap(gated.model.coreClient.copyFragment(
            sheet: page, range: NSRange(location: Self.objectIndex, length: 1)))
        let ownEnvelope = try JSONDecoder().decode(Envelope.self, from: try XCTUnwrap(own.envelope))
        XCTAssertEqual(ownEnvelope.nodes.first?.ref, reference, "the page's own reference")
        XCTAssertEqual(
            gated.pasteboard.string(forType: .string), "Heading\nbody x [sealed content · tiny] tail\n")
        let written = everything(on: gated.pasteboard)
        XCTAssertFalse(written.contains("SECRET"), "payload reached the board")
        XCTAssertFalse(written.contains("# Heading"), "the source markdown reached the board")
        XCTAssertFalse(written.contains(Self.secretLink.absoluteString), "the link's destination")
        XCTAssertEqual(
            Set(gated.pasteboard.pasteboardItems?.first?.types ?? []),
            [SealedFragment.pasteboardType, .string], "the copy's two types and no other")
        _ = chip

        preview.setSelectedRange(NSRange(location: 0, length: 7))
        preview.copy(nil)
        XCTAssertEqual(gated.pasteboard.string(forType: .string), "Heading")
        XCTAssertNil(gated.pasteboard.data(forType: SealedFragment.pasteboardType), "ink alone")

        preview.selectAll(nil)
        let service = NSPasteboard.withUniqueName()
        defer { service.releaseGlobally() }
        XCTAssertEqual(
            Set(preview.writablePasteboardTypes), [.string, SealedFragment.legacyStringType])
        XCTAssertTrue(preview.writeSelection(
            to: service, types: [SealedFragment.pasteboardType, .string]))
        XCTAssertEqual(service.string(forType: .string), "Heading\nbody x [sealed content · tiny] tail\n")
        XCTAssertNil(service.data(forType: SealedFragment.pasteboardType), "a service takes the public text alone")
        XCTAssertNil(preview.validRequestor(forSendType: .string, returnType: .string), "nothing writes back")
    }

    /// No drag starts from the preview, with an object in the selection or not (Law 0001,
    /// plain drag row): the drag's image would draw the objects' faces where no gate sees.
    func testAPreviewStartsNoDragFromASelectionHoldingAnObject() throws {
        let gated = try makeGatedModel()
        let (page, _) = try sealedPreviewPage(in: gated.model)
        let roll = try mountRoll(gated.model)
        defer { roll.window.close() }
        let preview = try preview(for: page, in: roll)
        XCTAssertTrue(roll.window.makeFirstResponder(preview))
        preview.selectAll(nil)
        let board = gated.pasteboard.changeCount
        let event = try mouseDragged(in: preview)

        XCTAssertFalse(preview.dragSelection(with: event, offset: .zero, slideBack: true))
        XCTAssertNil(preview.dragImageForSelection(with: event, origin: nil))
        let objectIndex = (preview.string as NSString).range(of: "\u{FFFC}").location
        let cell = try XCTUnwrap(
            (preview.textStorage?.attribute(.attachment, at: objectIndex, effectiveRange: nil)
                as? NSTextAttachment)?.attachmentCell)
        preview.delegate?.textView?(
            preview, draggedCell: cell, in: preview.bounds, event: event, at: objectIndex)

        XCTAssertEqual(preview.draggingSessionsBegun, 0)
        XCTAssertEqual(gated.pasteboard.changeCount, board)
        XCTAssertEqual(NSPasteboard(name: .drag).changeCount, NSPasteboard(name: .drag).changeCount)
        preview.setSelectedRange(NSRange(location: 0, length: 7))
        XCTAssertFalse(preview.dragSelection(with: event, offset: .zero, slideBack: true), "ink alone")
        XCTAssertEqual(preview.draggingSessionsBegun, 0)
    }

    /// A link in the preview opens only by ⌘-click through the coordinator's `openLink`,
    /// which asks the page first; a plain click opens nothing (Law 0001, link rows).
    func testAPreviewsLinkOpensOnlyByCommandClickThroughTheGate() throws {
        let gated = try makeGatedModel()
        let (page, _) = try sealedPreviewPage(in: gated.model)
        let roll = try mountRoll(gated.model)
        defer { roll.window.close() }
        let preview = try preview(for: page, in: roll)
        XCTAssertTrue(roll.window.makeFirstResponder(preview))
        let index = try linkIndex(in: preview)
        let link = try XCTUnwrap(preview.textStorage?.attribute(.link, at: index, effectiveRange: nil))

        try click(with: [])
        XCTAssertTrue(preview.delegate?.textView?(preview, clickedOnLink: link, at: index) == true)
        XCTAssertEqual(gated.opened.urls, [], "a plain click opened the link")

        try commandClickLink(in: preview)
        XCTAssertEqual(gated.opened.urls, [Self.secretLink])

        preview.openAimedLink(link)
        XCTAssertEqual(gated.opened.urls, [Self.secretLink, Self.secretLink], "Open Link")
        XCTAssertTrue(gated.model.tabs.contains { $0.pageID == page })
    }

    /// From its deadline, before any sweep, every way out of a preview refuses, writes
    /// and opens nothing, and settles at once with its line (Law 0001, expiry row).
    func testEveryWayOutOfAPreviewPastItsPagesDeadlineRefusesAndTheSettleTakesIt() throws {
        let ways: [(name: String, run: (MarkdownPreviewView) throws -> Void)] = [
            ("copy", { $0.copy(nil) }),
            ("a service's write", { preview in
                let service = NSPasteboard.withUniqueName()
                defer { service.releaseGlobally() }
                XCTAssertFalse(preview.writeSelection(to: service, types: [.string]))
                XCTAssertNil(service.string(forType: .string))
            }),
            ("⌘-click", { try self.commandClickLink(in: $0) }),
            ("Open Link", { preview in
                let index = try self.linkIndex(in: preview)
                let link = try XCTUnwrap(preview.textStorage?.attribute(.link, at: index, effectiveRange: nil))
                preview.openAimedLink(link)
            }),
            ("Copy Link", { preview in
                let index = try self.linkIndex(in: preview)
                let link = try XCTUnwrap(preview.textStorage?.attribute(.link, at: index, effectiveRange: nil))
                let item = NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: "")
                item.representedObject = AskingTextView.LinkTarget(link: link, index: index)
                preview.copyLinkFromMenu(item)
            }),
            ("the readers", { preview in
                XCTAssertFalse(preview.mayReadOut)
            }),
        ]
        for way in ways {
            let gated = try makeGatedModel()
            let (page, _) = try sealedPreviewPage(in: gated.model)
            let roll = try mountRoll(gated.model)
            defer { roll.window.close() }
            let preview = try preview(for: page, in: roll)
            XCTAssertTrue(roll.window.makeFirstResponder(preview))
            preview.selectAll(nil)
            try age(page, in: gated.model)
            let board = gated.pasteboard.changeCount

            try way.run(preview)

            XCTAssertEqual(gated.opened.urls, [], "\(way.name) opened the link")
            XCTAssertEqual(gated.pasteboard.changeCount, board, "\(way.name) wrote the board")
            XCTAssertEqual(gated.model.notice, PageModel.pageExpiredLine, way.name)
            XCTAssertFalse(gated.model.tabs.contains { $0.pageID == page }, "\(way.name): no settle")
            XCTAssertEqual(readers(in: try seededMenu(preview)), [], "\(way.name): the menu")
        }
    }

    func testPerPagePreviewDefaultsOffAndTogglesIndependentlyOfEveryGlobalScope() throws {
        let model = try makeModel()
        let first = try page(in: model)
        let second = try page(in: model)
        for scope in PreviewRenderingScope.allCases {
            model.previewRendering = scope
            XCTAssertFalse(model.markdownPreviewEnabled(for: first), scope.rawValue)
            XCTAssertFalse(model.markdownPreviewEnabled(for: second), scope.rawValue)
            XCTAssertEqual(model.previewRendering, scope)

            model.toggleMarkdownPreview(for: first)

            XCTAssertTrue(model.markdownPreviewEnabled(for: first))
            XCTAssertFalse(model.markdownPreviewEnabled(for: second))
            XCTAssertEqual(model.previewRendering, scope)

            model.toggleMarkdownPreview(for: first)
            XCTAssertFalse(model.markdownPreviewEnabled(for: first))
            XCTAssertEqual(model.previewRendering, scope)
        }
    }

    /// A page whose preview renders the ink itself skips the quiet styling pass under
    /// **All pages**: its quiet rendering is plain ink the renderer parses once.
    func testAPreviewedPageSkipsTheQuietStylingPassAndTheToggleRestoresIt() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let page = try page(in: model)
        let styled = model.quietRendering(for: page)
        XCTAssertTrue(headingIsStyled(NSTextStorage(attributedString: styled.text)))

        model.toggleMarkdownPreview(for: page)
        let plain = model.quietRendering(for: page)
        XCTAssertFalse(plain === styled, "the toggle dropped the cache")
        XCTAssertFalse(headingIsStyled(NSTextStorage(attributedString: plain.text)))
        XCTAssertEqual(plain.text.string, "# Heading\nbody")
        XCTAssertEqual(MarkdownPreviewView.render(plain.text).string, "Heading\nbody\n")

        model.toggleMarkdownPreview(for: page)
        XCTAssertTrue(headingIsStyled(NSTextStorage(attributedString: model.quietRendering(for: page).text)))
    }

    func testNonselectedHeaderTogglesOnlyItsPreviewWithoutChangingSelectionEditorOrFocus() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let first = try page(in: model)
        let selected = try page(in: model)
        let selectedTab = model.selection
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let selection = NSRange(location: 3, length: 2)
        editor.setSelectedRange(selection)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let header = try header(for: first, in: roll)
        let toggle = try button(in: header)
        XCTAssertFalse(header.isActive)
        XCTAssertEqual(toggle.state, .off)

        toggle.performClick(nil)

        XCTAssertTrue(model.markdownPreviewEnabled(for: first))
        XCTAssertFalse(model.markdownPreviewEnabled(for: selected))
        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(try preview(for: first, in: roll).string, "Heading\nbody\n")
        XCTAssertEqual(model.selectedPageID, selected)
        XCTAssertEqual(model.selection, selectedTab)
        XCTAssertEqual(model.previewRendering, .allPages)
        XCTAssertEqual(model.previewRendering, .allPages)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(try body(for: selected, in: roll) === editor)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertTrue(headingIsStyled(storage))
        XCTAssertEqual(editor.selectedRange(), selection)

        toggle.performClick(nil)

        XCTAssertFalse(model.markdownPreviewEnabled(for: first))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertNil(roll.stack.previewRegions[first])
        let quiet = try XCTUnwrap(roll.stack.quietRegions[first])
        XCTAssertTrue(try body(for: first, in: roll) === quiet)
        XCTAssertEqual(quiet.string, "# Heading\nbody")
        XCTAssertTrue(headingIsStyled(try XCTUnwrap(quiet.textStorage)))
        XCTAssertEqual(source(for: first, in: model), "# Heading\nbody")
        XCTAssertEqual(model.selectedPageID, selected)
        XCTAssertEqual(model.selection, selectedTab)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
    }

    func testQuietHeaderCanEnableRenderedPreviewUnderNeverAndRestorePlainQuietSource() throws {
        let model = try makeModel()
        model.previewRendering = .never
        let first = try page(in: model)
        let selected = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let toggle = try button(in: header(for: first, in: roll))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertFalse(headingIsStyled(storage))

        toggle.performClick(nil)

        XCTAssertEqual(model.previewRendering, .never)
        XCTAssertEqual(model.previewRendering, .never)
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))
        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(try preview(for: first, in: roll).string, "Heading\nbody\n")
        XCTAssertFalse(headingIsStyled(storage))

        toggle.performClick(nil)

        XCTAssertNil(roll.stack.previewRegions[first])
        let quiet = try XCTUnwrap(roll.stack.quietRegions[first])
        XCTAssertTrue(try body(for: first, in: roll) === quiet)
        XCTAssertFalse(headingIsStyled(try XCTUnwrap(quiet.textStorage)))
        XCTAssertEqual(quiet.string, "# Heading\nbody")
        XCTAssertEqual(model.selectedPageID, selected)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
    }

    func testSelectedPreviewToggleTransfersFocusToPreviewAndBackWithoutClickingPreview() throws {
        let model = try makeModel()
        let page = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let selection = NSRange(location: 3, length: 2)
        editor.setSelectedRange(selection)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let toggle = try button(in: header(for: page, in: roll))

        toggle.performClick(nil)

        let preview = try preview(for: page, in: roll)
        XCTAssertTrue(roll.window.firstResponder === preview)
        XCTAssertTrue(PageModel.mountedEditor(model.activeEditor, in: roll.window) === preview)
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)

        toggle.performClick(nil)

        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.selectedRange(), selection)
    }

    func testSelectedPreviewOwnershipRoundTripRestoresOriginalEditorAndStorage() throws {
        let model = try makeModel()
        let page = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let originalOwner = model.owner
        let other: PresentationOwner = originalOwner == .panel ? .editorWindow : .panel
        model.toggleMarkdownPreview(for: page)
        XCTAssertTrue(model.activeEditor === editor)

        model.transferOwnership(to: other)
        XCTAssertNil(roll.coordinator.currentSheet)
        let incoming = try mountRoll(model)
        defer { incoming.window.close() }
        XCTAssertEqual(incoming.coordinator.surface, other)
        XCTAssertEqual(incoming.coordinator.currentSheet, page)
        XCTAssertTrue(incoming.stack.editor?.textStorage === storage)
        _ = try preview(for: page, in: incoming)

        model.transferOwnership(to: originalOwner)
        DayScrollView.updateRoll(
            roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertNil(incoming.coordinator.currentSheet)
        _ = try preview(for: page, in: roll)
        model.toggleMarkdownPreview(for: page)

        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(try XCTUnwrap(editor.textStorage) === storage)
        XCTAssertEqual(editor.string, "# Heading\nbody")
        XCTAssertEqual(roll.coordinator.currentSheet, page)
        XCTAssertEqual(model.selectedPageID, page)
        XCTAssertTrue(try body(for: page, in: roll) === editor)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
    }

    func testHeaderNavigationFromSelectedPreviewFocusesOtherEditorAndReturnsToPreview() throws {
        let model = try makeModel()
        let other = try page(in: model, saying: "# Other\nbody")
        let previewPage = try page(in: model)
        model.toggleMarkdownPreview(for: previewPage)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertTrue(roll.window.makeFirstResponder(try preview(for: previewPage, in: roll)))

        XCTAssertTrue(roll.stack.focusEditor(on: other))
        XCTAssertEqual(model.selectedPageID, other)
        DayScrollView.updateRoll(
            roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)

        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertEqual(roll.coordinator.currentSheet, other)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.string, "# Other\nbody")

        XCTAssertTrue(roll.stack.focusEditor(on: previewPage))
        XCTAssertEqual(model.selectedPageID, previewPage)
        DayScrollView.updateRoll(
            roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)

        XCTAssertTrue(roll.stack.focusEditor(on: previewPage))
        XCTAssertTrue(roll.window.firstResponder === (try preview(for: previewPage, in: roll)))
        XCTAssertEqual(roll.coordinator.currentSheet, previewPage)
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
    }

    func testNonselectedPreviewActivationSelectsPageWithoutUsingRenderedSelectionAsSourceCaret() throws {
        let model = try makeModel()
        let markdown = "# **Preview**\n\nbody with **markup**"
        let previewPage = try page(in: model, saying: markdown)
        try page(in: model)
        let sourceSelection = NSRange(location: 18, length: 2)
        model.viewStates.saveCaret(sourceSelection, for: previewPage)
        model.toggleMarkdownPreview(for: previewPage)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let preview = try preview(for: previewPage, in: roll)
        preview.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertNotEqual(model.selectedPageID, previewPage)

        preview.promote()

        XCTAssertEqual(model.selectedPageID, previewPage)
        DayScrollView.updateRoll(
            roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertEqual(try self.preview(for: previewPage, in: roll).string, "Preview\nbody with markup\n")
        XCTAssertTrue(model.markdownPreviewEnabled(for: previewPage))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(roll.coordinator.currentSheet, previewPage)
        XCTAssertEqual(editor.selectedRange(), sourceSelection)
        XCTAssertEqual(model.viewStates.carets[previewPage], sourceSelection)
        XCTAssertEqual(source(for: previewPage, in: model), markdown)
    }

    func testSelectedTablePreviewUsesNativeCellsAndRestoresSameEditorStorageAndSelection() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let markdown = """
        # Heading

        | Name | Value |
        | --- | ---: |
        | **alpha** | 42 |
        """
        let page = try page(in: model, saying: markdown)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let selection = NSRange(location: 3, length: 4)
        editor.setSelectedRange(selection)
        let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        let toggle = try button(in: header(for: page, in: roll))
        XCTAssertTrue(headingIsStyled(storage))

        toggle.performClick(nil)

        let preview = try preview(for: page, in: roll)
        let rendered = try XCTUnwrap(preview.textStorage)
        XCTAssertEqual(preview.string, "Heading\nName\nValue\nalpha\n42\n\n")
        var cells: [NSTextTableBlock] = []
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) {
            value, _, _ in
            cells.append(contentsOf: (value as? NSParagraphStyle)?.textBlocks.compactMap {
                $0 as? NSTextTableBlock
            } ?? [])
        }
        let firstCell = try XCTUnwrap(cells.first)
        XCTAssertEqual(Set(cells.map(ObjectIdentifier.init)).count, 4)
        XCTAssertTrue(cells.allSatisfy { $0.table === firstCell.table })
        XCTAssertEqual(firstCell.table.numberOfColumns, 2)
        XCTAssertTrue(cells.contains { $0.startingRow == 1 && $0.startingColumn == 1 })
        XCTAssertFalse(rendered === storage)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(editor.superview === roll.stack)
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(editor.string, markdown)
        XCTAssertEqual(source(for: page, in: model), markdown)
        XCTAssertEqual(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont, headingFont)
        XCTAssertEqual(roll.coordinator.appliedPreviewRendering, .allPages)

        roll.stack.update(projection: model.timeUnits, selectedPage: page, readOnly: false)
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        toggle.performClick(nil)

        XCTAssertFalse(model.markdownPreviewEnabled(for: page))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertNil(roll.stack.previewRegions[page])
        XCTAssertNil(roll.stack.quietRegions[page])
        XCTAssertTrue(try body(for: page, in: roll) === editor)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(storage.string, markdown)
        XCTAssertEqual(source(for: page, in: model), markdown)
        XCTAssertEqual(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont, headingFont)
        XCTAssertEqual(model.previewRendering, .allPages)
        XCTAssertEqual(roll.coordinator.appliedPreviewRendering, .allPages)
    }

    func testSelectingPreviewPageAndLeavingItMovesSameEditorWithoutChangingPagePreviewState() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "# First\nbody")
        let firstTab = try summary(for: first, in: model).id
        let second = try page(in: model, saying: "# Second\nbody")
        let secondTab = try summary(for: second, in: model).id
        model.toggleMarkdownPreview(for: first)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let secondStorage = try XCTUnwrap(editor.textStorage)
        let secondSelection = NSRange(location: 4, length: 2)
        let firstSelection = NSRange(location: 3, length: 1)
        editor.setSelectedRange(secondSelection)
        model.viewStates.saveCaret(firstSelection, for: first)
        XCTAssertEqual(try preview(for: first, in: roll).string, "First\nbody\n")
        XCTAssertFalse(editor.isHidden)

        model.select(firstTab)
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)

        let firstStorage = try XCTUnwrap(editor.textStorage)
        XCTAssertEqual(model.selectedPageID, first)
        XCTAssertEqual(roll.coordinator.currentSheet, first)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(firstStorage === model.storage(for: first))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(try preview(for: first, in: roll).string, "First\nbody\n")
        XCTAssertNotNil(roll.stack.quietRegions[second])

        model.select(secondTab)
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)

        XCTAssertEqual(model.selectedPageID, second)
        XCTAssertEqual(roll.coordinator.currentSheet, second)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === secondStorage)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.selectedRange(), secondSelection)
        XCTAssertTrue(try body(for: second, in: roll) === editor)
        XCTAssertNil(roll.stack.quietRegions[second])
        XCTAssertEqual(try preview(for: first, in: roll).string, "First\nbody\n")
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))
        XCTAssertFalse(model.markdownPreviewEnabled(for: second))

        model.select(firstTab)
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
        model.toggleMarkdownPreview(for: first)

        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === firstStorage)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.selectedRange(), firstSelection)
        XCTAssertTrue(try body(for: first, in: roll) === editor)
    }

    /// A preview of a page the roll has not selected is as a quiet page is (ADR-0030):
    /// not selectable, never the first responder, and a click on it promotes its page.
    func testAPreviewOfAnUnselectedPageIsNotSelectableAndAClickPromotesIt() throws {
        let model = try makeModel()
        let first = try page(in: model)
        let second = try page(in: model)
        model.toggleMarkdownPreview(for: first)
        model.toggleMarkdownPreview(for: second)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let firstPreview = try preview(for: first, in: roll)
        let secondPreview = try preview(for: second, in: roll)
        XCTAssertTrue(secondPreview.isSelectedPage)
        XCTAssertTrue(secondPreview.isSelectable)
        XCTAssertTrue(secondPreview.acceptsFirstResponder)
        XCTAssertTrue(roll.window.makeFirstResponder(secondPreview))
        XCTAssertFalse(firstPreview.isSelectedPage)
        XCTAssertFalse(firstPreview.isSelectable)
        XCTAssertFalse(firstPreview.acceptsFirstResponder)

        // A responder that refuses the keys leaves them with the window, as a quiet page does.
        roll.window.makeFirstResponder(firstPreview)
        XCTAssertFalse(roll.window.firstResponder === firstPreview, "the keys went to a quiet preview")
        XCTAssertEqual(model.selectedPageID, second)
        XCTAssertEqual(roll.coordinator.currentSheet, second)
        XCTAssertTrue(roll.window.makeFirstResponder(secondPreview))

        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: firstPreview.convert(NSPoint(x: 4, y: 4), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: roll.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        firstPreview.mouseDown(with: click)

        XCTAssertEqual(model.selectedPageID, first)
        XCTAssertEqual(roll.coordinator.currentSheet, first)
        XCTAssertTrue(firstPreview.isSelectedPage)
        XCTAssertTrue(firstPreview.isSelectable)
        XCTAssertFalse(secondPreview.isSelectedPage)
        XCTAssertFalse(secondPreview.isSelectable)
        XCTAssertTrue(roll.window.firstResponder === firstPreview)
        XCTAssertTrue(PageModel.mountedEditor(model.activeEditor) === firstPreview)
    }

    func testReusedHeaderChangesTargetAndHidesButtonForEmptyToday() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let first = try page(in: model)
        let second = try page(in: model)
        let header = try header(for: first, in: model)
        let toggle = try button(in: header)
        XCTAssertEqual(toggle.state, .off)
        toggle.performClick(nil)
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))

        header.refresh(summary: try summary(for: second, in: model))
        header.place()
        XCTAssertEqual(header.pageIdentity, second)
        XCTAssertEqual(toggle.state, .off)
        toggle.performClick(nil)
        XCTAssertTrue(model.markdownPreviewEnabled(for: second))
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))

        header.show(
            words: .init(day: "Today", time: ""), spokenLabel: "Today",
            mark: .none, summary: nil)
        header.place()
        XCTAssertNil(header.pageIdentity)
        XCTAssertTrue(toggle.isHidden)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertNil(header.accessibilityChildren())
        toggle.performClick(nil)
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))
        XCTAssertTrue(model.markdownPreviewEnabled(for: second))

        header.refresh(summary: try summary(for: first, in: model))
        header.place()
        XCTAssertEqual(header.pageIdentity, first)
        XCTAssertFalse(toggle.isHidden)
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(toggle.state, .on)
        toggle.performClick(nil)
        XCTAssertFalse(model.markdownPreviewEnabled(for: first))
        XCTAssertTrue(model.markdownPreviewEnabled(for: second))
        XCTAssertEqual(model.previewRendering, .allPages)
        XCTAssertEqual(model.previewRendering, .allPages)
    }

    func testButtonStartsOffAndRefreshesFromPageBooleanRegardlessOfHybridScope() throws {
        for scope in PreviewRenderingScope.allCases {
            let model = try makeModel()
            model.previewRendering = scope
            let first = try page(in: model)
            try page(in: model)
            let header = try header(for: first, in: model)
            let toggle = try button(in: header)
            XCTAssertFalse(header.isActive)
            XCTAssertEqual(toggle.state, .off, scope.rawValue)
            XCTAssertFalse(model.markdownPreviewEnabled(for: first))
            XCTAssertFalse(try XCTUnwrap(toggle.accessibilityLabel()).isEmpty)
            let disabledTooltip = try XCTUnwrap(toggle.toolTip)

            toggle.performClick(nil)

            XCTAssertEqual(toggle.state, .on)
            XCTAssertTrue(model.markdownPreviewEnabled(for: first))
            XCTAssertEqual(model.previewRendering, scope)
            XCTAssertNotEqual(toggle.toolTip, disabledTooltip)
            model.toggleMarkdownPreview(for: first)
            header.refresh(summary: try summary(for: first, in: model))
            XCTAssertEqual(toggle.state, .off)
            XCTAssertEqual(toggle.toolTip, disabledTooltip)
        }
    }

    func testMouseAndAccessibilityHitTestsReachButtonBesideTitleAndTime() throws {
        let model = try makeModel()
        let page = try page(in: model)
        let tab = try summary(for: page, in: model).id
        model.renameTab(tab, to: String(repeating: "long title ", count: 20))
        let header = try header(for: page, in: model)
        let window = NSWindow(
            contentRect: header.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = header
        defer { window.close() }
        header.place()
        let toggle = try button(in: header)
        XCTAssertGreaterThanOrEqual(toggle.frame.minX, header.timeFrame.maxX)
        XCTAssertLessThanOrEqual(toggle.frame.maxX, header.bounds.maxX)
        let local = NSPoint(x: toggle.frame.midX, y: toggle.frame.midY)
        XCTAssertTrue(header.hitTest(local) === toggle)
        let screen = window.convertPoint(toScreen: header.convert(local, to: nil))
        XCTAssertTrue((header.accessibilityHitTest(screen) as? NSButton) === toggle)
        XCTAssertTrue(header.accessibilityChildren()?.contains {
            ($0 as? NSButton) === toggle
        } == true)
        let timePoint = NSPoint(x: header.timeFrame.midX, y: header.timeFrame.midY)
        let timeScreen = window.convertPoint(toScreen: header.convert(timePoint, to: nil))
        XCTAssertTrue((header.accessibilityHitTest(timeScreen) as? NSView) === header)
    }

    func testGlobalHybridSettingChangesWhilePreviewStaysOnWithoutReplacingEditorOrSource() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let quietPage = try page(in: model)
        let selected = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let selection = NSRange(location: 3, length: 2)
        editor.setSelectedRange(selection)
        model.toggleMarkdownPreview(for: selected)

        for scope in [PreviewRenderingScope.never, .focusedOnly, .allPages, .never] {
            model.previewRendering = scope
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)

            XCTAssertTrue(model.markdownPreviewEnabled(for: selected))
            XCTAssertFalse(model.markdownPreviewEnabled(for: quietPage))
            XCTAssertEqual(model.previewRendering, scope)
            XCTAssertEqual(try preview(for: selected, in: roll).string, "Heading\nbody\n")
            XCTAssertEqual(try button(in: header(for: selected, in: roll)).state, .on)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
            XCTAssertTrue(editor.isHidden)
            XCTAssertFalse(editor.isEditable)
            XCTAssertEqual(roll.coordinator.appliedPreviewRendering, scope)
            XCTAssertEqual(headingIsStyled(storage), scope != .never)
            let quiet = try XCTUnwrap(roll.stack.quietRegions[quietPage])
            XCTAssertEqual(headingIsStyled(try XCTUnwrap(quiet.textStorage)), scope == .allPages)
            XCTAssertEqual(storage.string, "# Heading\nbody")
            XCTAssertEqual(source(for: selected, in: model), "# Heading\nbody")
        }

        model.toggleMarkdownPreview(for: selected)

        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertFalse(headingIsStyled(storage))
        XCTAssertEqual(roll.coordinator.appliedPreviewRendering, .never)
    }

    func testEditorMakeUpdateAndDirectApplyUseOnlyGlobalHybridScope() throws {
        let model = try makeModel()
        model.previewRendering = .never
        let first = try page(in: model)
        model.toggleMarkdownPreview(for: first)
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = InkEditorView.makePage(
            model: model, sheetID: first, readOnly: false, coordinator: coordinator)
        let editor = try XCTUnwrap(scroll.documentView as? InkTextView)
        let storage = try XCTUnwrap(editor.textStorage)
        defer { InkEditorView.dismantleNSView(scroll, coordinator: coordinator) }
        XCTAssertEqual(coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(storage))

        model.toggleMarkdownPreview(for: first)
        coordinator.applyPreviewRendering(model.previewRendering)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(storage))
        model.previewRendering = .allPages
        model.toggleMarkdownPreview(for: first)
        coordinator.applyPreviewRendering(model.previewRendering)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(storage))

        let second = try page(in: model)
        InkEditorView.updatePage(
            scroll, model: model, sheetID: second, readOnly: false, coordinator: coordinator)
        XCTAssertEqual(coordinator.currentSheet, second)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(try XCTUnwrap(editor.textStorage)))
        model.toggleMarkdownPreview(for: second)
        model.previewRendering = .never
        InkEditorView.updatePage(
            scroll, model: model, sheetID: second, readOnly: false, coordinator: coordinator)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(try XCTUnwrap(editor.textStorage)))
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))
        XCTAssertTrue(model.markdownPreviewEnabled(for: second))
    }

    func testPreviewKeepsEditorNoneditableAcrossReadOnlyUpdatesAndRestoresLatestEditability() throws {
        for readOnly in [false, true] {
            let model = try makeModel()
            let page = try page(in: model)
            let roll = try mountRoll(model)
            defer { roll.window.close() }
            let editor = try XCTUnwrap(roll.stack.editor)
            let storage = try XCTUnwrap(editor.textStorage)
            let selection = NSRange(location: 4, length: 1)
            editor.setSelectedRange(selection)
            roll.stack.update(projection: model.timeUnits, selectedPage: page, readOnly: readOnly)
            XCTAssertEqual(editor.isEditable, !readOnly)

            model.toggleMarkdownPreview(for: page)
            XCTAssertTrue(editor.isHidden)
            XCTAssertFalse(editor.isEditable)
            roll.stack.update(projection: model.timeUnits, selectedPage: page, readOnly: readOnly)
            XCTAssertTrue(editor.isHidden)
            XCTAssertFalse(editor.isEditable)
            model.toggleMarkdownPreview(for: page)
            XCTAssertFalse(editor.isHidden)
            XCTAssertEqual(editor.isEditable, !readOnly)
            XCTAssertEqual(editor.selectedRange(), selection)

            model.toggleMarkdownPreview(for: page)
            roll.stack.update(projection: model.timeUnits, selectedPage: page, readOnly: !readOnly)
            XCTAssertTrue(editor.isHidden)
            XCTAssertFalse(editor.isEditable)
            model.toggleMarkdownPreview(for: page)
            XCTAssertFalse(editor.isHidden)
            XCTAssertEqual(editor.isEditable, readOnly)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertTrue(try body(for: page, in: roll) === editor)
        }
    }

    func testSelectedAndQuietPreviewsRefreshFromChangedSourceOnModelRefreshAndRollUpdate() throws {
        for isSelected in [true, false] {
            let model = try makeModel()
            let page = try page(in: model)
            if !isSelected { try self.page(in: model) }
            let selected = model.selectedPageID
            model.toggleMarkdownPreview(for: page)
            let roll = try mountRoll(model)
            defer { roll.window.close() }
            let editor = try XCTUnwrap(roll.stack.editor)
            let storage = try XCTUnwrap(editor.textStorage)
            XCTAssertEqual(try preview(for: page, in: roll).string, "Heading\nbody\n")

            let replacement = "# Updated\n\nA **new** paragraph."
            model.syncDocument(sheet: page, runs: [.ink(replacement)])
            model.refresh()
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)

            XCTAssertEqual(try preview(for: page, in: roll).string, "Updated\nA new paragraph.\n")
            XCTAssertEqual(source(for: page, in: model), replacement)
            XCTAssertTrue(model.markdownPreviewEnabled(for: page))
            XCTAssertEqual(model.selectedPageID, selected)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
            XCTAssertEqual(editor.isHidden, isSelected)
            XCTAssertEqual(editor.isEditable, !isSelected)
        }
    }

    func testPreviewChoicesPersistInV2ByPageUUIDAndReloadIndependentlyOfGlobalScope() throws {
        let defaults = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-preview-reload-\(UUID().uuidString)")
        let tag = UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        func launch() -> PageModel {
            PageModel(formFactor: .backdrop, defaults: defaults,
                seams: .init(stateDirectory: directory, client: .ephemeral(tag: tag), saveDebounce: 3_600))
        }
        let first = launch()
        first.loadStateIfNeeded()
        let disabledPage = try XCTUnwrap(first.selectedPageID)
        let disabledUUID = try XCTUnwrap(first.selectedTab?.pageUUID)
        first.toggleMarkdownPreview(for: disabledPage)
        first.toggleMarkdownPreview(for: disabledPage)
        first.newPage()
        let enabledPage = try XCTUnwrap(first.selectedPageID)
        let enabledUUID = try XCTUnwrap(first.selectedTab?.pageUUID)
        first.previewRendering = .never
        first.toggleMarkdownPreview(for: enabledPage)
        _ = first.saveStateForQuit()
        XCTAssertNotEqual(disabledUUID, enabledUUID)
        XCTAssertEqual(defaults.dictionary(forKey: "pageMarkdownPreviewV2") as? [String: Bool],
                       [disabledUUID: false, enabledUUID: true])
        XCTAssertNil(defaults.object(forKey: "pageMarkdownPreviewV1"))
        defaults.set([disabledUUID: true, enabledUUID: false], forKey: "pageMarkdownPreviewV1")

        let second = launch()
        second.refresh()
        second.loadStateIfNeeded()
        XCTAssertEqual(second.previewRendering, .never)
        let restoredDisabled = try XCTUnwrap(second.tabs.first { $0.pageUUID == disabledUUID }?.pageID)
        let restoredEnabled = try XCTUnwrap(second.tabs.first { $0.pageUUID == enabledUUID }?.pageID)
        for scope in PreviewRenderingScope.allCases {
            second.previewRendering = scope
            XCTAssertFalse(second.markdownPreviewEnabled(for: restoredDisabled))
            XCTAssertTrue(second.markdownPreviewEnabled(for: restoredEnabled))
            XCTAssertEqual(second.previewRendering, scope)
            XCTAssertEqual(second.previewRendering, scope)
        }
        second.toggleMarkdownPreview(for: restoredEnabled)
        XCTAssertFalse(second.markdownPreviewEnabled(for: restoredEnabled))
        XCTAssertEqual(defaults.dictionary(forKey: "pageMarkdownPreviewV2") as? [String: Bool],
                       [disabledUUID: false, enabledUUID: false])
    }

    func testLegacyV1PreferenceIsIgnoredWhenV2HasNoEntry() throws {
        let defaults = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-preview-legacy-\(UUID().uuidString)")
        let tag = UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        func launch() -> PageModel {
            PageModel(formFactor: .backdrop, defaults: defaults,
                seams: .init(stateDirectory: directory, client: .ephemeral(tag: tag), saveDebounce: 3_600))
        }
        let first = launch()
        first.loadStateIfNeeded()
        let firstUUID = try XCTUnwrap(first.selectedTab?.pageUUID)
        first.newPage()
        let secondUUID = try XCTUnwrap(first.selectedTab?.pageUUID)
        first.previewRendering = .allPages
        _ = first.saveStateForQuit()
        defaults.set([firstUUID: true, secondUUID: false], forKey: "pageMarkdownPreviewV1")
        XCTAssertNil(defaults.object(forKey: "pageMarkdownPreviewV2"))

        let second = launch()
        second.refresh()
        second.loadStateIfNeeded()
        for uuid in [firstUUID, secondUUID] {
            let page = try XCTUnwrap(second.tabs.first { $0.pageUUID == uuid }?.pageID)
            XCTAssertFalse(second.markdownPreviewEnabled(for: page))
            XCTAssertEqual(second.previewRendering, .allPages)
        }
    }

    /// The first V2 write removes the V1 key, which nothing reads any more.
    func testTheFirstV2WriteRemovesTheLegacyV1Key() throws {
        let defaults = try makeDefaults()
        let model = try makeModel(defaults: defaults)
        let page = try page(in: model)
        defaults.set(["stale": true], forKey: "pageMarkdownPreviewV1")
        XCTAssertNil(defaults.object(forKey: "pageMarkdownPreviewV2"))

        model.toggleMarkdownPreview(for: page)

        XCTAssertNil(defaults.object(forKey: "pageMarkdownPreviewV1"))
        XCTAssertEqual(defaults.dictionary(forKey: "pageMarkdownPreviewV2")?.count, 1)
        XCTAssertTrue(model.markdownPreviewEnabled(for: page))
    }

    func testReplacementPageInSameTabDoesNotInheritPreviewChoice() throws {
        let defaults = try makeDefaults()
        let model = try makeModel(defaults: defaults)
        model.loadStateIfNeeded()
        let oldPage = try XCTUnwrap(model.selectedPageID)
        let tab = try XCTUnwrap(model.selection)
        let oldUUID = try XCTUnwrap(model.selectedTab?.pageUUID)
        model.toggleMarkdownPreview(for: oldPage)
        XCTAssertTrue(model.markdownPreviewEnabled(for: oldPage))
        XCTAssertTrue(model.coreClient.discardPage(id: oldPage))
        let replacement = model.coreClient.openPage(tab: tab)
        XCTAssertNotEqual(replacement, 0)
        model.refresh()
        let replacementUUID = try XCTUnwrap(model.tabs.first { $0.id == tab }?.pageUUID)
        XCTAssertNotEqual(replacementUUID, oldUUID)
        XCTAssertFalse(model.markdownPreviewEnabled(for: replacement))
        XCTAssertFalse(model.markdownPreviewEnabled(for: oldPage))
        XCTAssertEqual(model.previewRendering, model.previewRendering)
        XCTAssertNil(defaults.dictionary(forKey: "pageMarkdownPreviewV2")?[oldUUID])
        model.toggleMarkdownPreview(for: replacement)
        XCTAssertTrue(model.markdownPreviewEnabled(for: replacement))
        XCTAssertEqual(defaults.dictionary(forKey: "pageMarkdownPreviewV2")?[replacementUUID] as? Bool, true)
    }

    func testPreviewStateAndMountedRegionExpireWithPageWithoutChangingOtherPages() throws {
        let defaults = try makeDefaults()
        let model = try makeModel(defaults: defaults)
        model.loadStateIfNeeded()
        let expiring = try XCTUnwrap(model.selectedPageID)
        let expiringUUID = try XCTUnwrap(model.selectedTab?.pageUUID)
        let tab = try XCTUnwrap(model.selection)
        model.toggleMarkdownPreview(for: expiring)
        XCTAssertTrue(model.coreClient.setRung(tab: tab, rung: .oneHour))
        let survivor = try page(in: model)
        XCTAssertTrue(model.coreClient.setRung(
            tab: try summary(for: survivor, in: model).id, rung: .sevenDays))
        model.toggleMarkdownPreview(for: survivor)
        let untouched = try page(in: model)
        XCTAssertTrue(model.coreClient.setRung(
            tab: try summary(for: untouched, in: model).id, rung: .sevenDays))
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let expiredPreview = try preview(for: expiring, in: roll)

        XCTAssertTrue(model.coreClient.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        model.coreClient.expireDue()
        model.refresh()
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)

        XCTAssertFalse(model.tabs.contains { $0.pageID == expiring })
        XCTAssertFalse(model.markdownPreviewEnabled(for: expiring))
        XCTAssertTrue(model.markdownPreviewEnabled(for: survivor))
        XCTAssertFalse(model.markdownPreviewEnabled(for: untouched))
        XCTAssertEqual(model.selectedPageID, untouched)
        XCTAssertNil(roll.stack.previewRegions[expiring])
        XCTAssertNil(roll.stack.quietRegions[expiring])
        XCTAssertNil(expiredPreview.superview)
        XCTAssertFalse(roll.stack.laidOut.contains { $0.header.pageIdentity == expiring })
        XCTAssertEqual(try preview(for: survivor, in: roll).string, "Heading\nbody\n")
        let persisted = defaults.dictionary(forKey: "pageMarkdownPreviewV2") as? [String: Bool]
        XCTAssertNil(persisted?[expiringUUID])
        model.toggleMarkdownPreview(for: expiring)
        XCTAssertEqual(defaults.dictionary(forKey: "pageMarkdownPreviewV2") as? [String: Bool], persisted)
        XCTAssertTrue(model.markdownPreviewEnabled(for: survivor))
        XCTAssertFalse(model.markdownPreviewEnabled(for: untouched))
    }

    func testOlderSummaryWithoutPageUUIDStillDecodes() throws {
        let model = try makeModel()
        let page = try page(in: model)
        let data = try JSONEncoder().encode(summary(for: page, in: model))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields.removeValue(forKey: "page_uuid")
        let decoded = try JSONDecoder().decode(TabSummary.self,
            from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertNil(decoded.pageUUID)
        XCTAssertEqual(decoded.pageID, page)
    }

    func testNoteEditorKeepsGlobalHybridScopeWhileItsPagePreviewIsEnabled() throws {
        let model = try makeModel()
        model.previewRendering = .never
        let page = try page(in: model)
        model.toggleMarkdownPreview(for: page)
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let editor = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator))
        defer { coordinator.leavePage(editor, scrollView: nil) }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        coordinator.sealSelectionOrLine()
        let chip = try XCTUnwrap(coordinator.chipAttachment(at: 0)?.info.chipId)
        let note = SealedNoteEditor(model: model)
        XCTAssertTrue(note.coordinator.loadNote(chip: chip))
        defer { note.coordinator.unloadNote() }
        model.applyingProjection { note.storage.mutableString.setString("# Heading\nbody") }
        note.coordinator.restyle()
        XCTAssertTrue(model.markdownPreviewEnabled(for: page))
        XCTAssertEqual(model.previewRendering, .never)
        XCTAssertEqual(note.coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(note.storage))

        model.previewRendering = .allPages
        note.coordinator.applyPreviewRendering(model.previewRendering)
        XCTAssertTrue(model.markdownPreviewEnabled(for: page))
        XCTAssertEqual(model.previewRendering, .allPages)
        XCTAssertEqual(note.coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(note.storage))
        XCTAssertEqual(note.storage.string, "# Heading\nbody")
    }
}
