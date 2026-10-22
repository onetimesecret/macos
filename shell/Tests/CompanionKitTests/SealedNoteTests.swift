import AppKit
import XCTest

@testable import CompanionKit

/// A sealed object's note (Law 0001's note row; sealed row spec, Doorway and The
/// note's popover; core interface, The note's routes): the doorway, the popover over
/// the page, and its edits on the note's own routes, against the live core.
@MainActor
final class SealedNoteTests: XCTestCase {
    private struct Page {
        let model: PageModel
        let client: BlockAskingClient
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let scroll: NSScrollView
        let window: NSWindow
        let sheet: UInt64
        let chip: UInt64
    }

    /// A client that records each sheet the page's block route is asked for,
    /// its copies and seals kept on a pasteboard in process memory.
    final class BlockAskingClient: CompanionClient, @unchecked Sendable {
        private(set) var blocksAsked: [UInt64] = []

        init(tag: String) {
            super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
        }

        override func blocks(sheet: UInt64) -> [BlockInfo] {
            blocksAsked.append(sheet)
            return super.blocks(sheet: sheet)
        }
    }

    /// `ab <chip> cd` in a window of its own, the page's text view holding
    /// the keys and its caret after `ab`.
    private func makePage(width: CGFloat = 520) throws -> Page {
        let suite = "companion-sealed-note-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-sealed-note-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = BlockAskingClient(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let ambient = NSPasteboard.withUniqueName()
        addTeardownBlock { ambient.releaseGlobally() }
        let model = PageModel(
            formFactor: .backdrop, defaults: defaults,
            seams: .init(
                stateDirectory: directory, client: client,
                clearClipboardIfOurs: { false }, ambientPasteboard: ambient))
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let sheet = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: sheet, coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = InkEditorView.bareScroller()
        scroll.frame = window.contentLayoutRect
        InkEditorView.seat(textView, in: scroll)
        window.contentView = scroll
        textView.isEditable = true
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()
        textView.layout()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let chip = try XCTUnwrap(coordinator.chipAttachment(at: 3)?.info.chipId)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        return Page(
            model: model, client: client, coordinator: coordinator, textView: textView,
            scroll: scroll, window: window, sheet: sheet, chip: chip)
    }

    private func note(_ page: Page) throws -> SealedNoteEditor {
        try XCTUnwrap(page.coordinator.noteEditor, "no note was opened")
    }

    private func type(_ text: String, into editor: SealedNoteEditor) {
        editor.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func pageInk(_ page: Page) -> String {
        page.model.coreClient.documentRuns(sheet: page.sheet).reduce(into: "") {
            if case .ink(let ink) = $1 { $0 += ink }
        }
    }

    private func keyEvent(
        _ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    // MARK: Where the popover stands (Law 0001, note row; sealed row spec, Placement)

    func testThePopoverHangsUnderTheBlockAtTheBlocksMeasure() {
        let content = CGRect(x: 0, y: 0, width: 600, height: 500)
        let block = CGRect(x: 20, y: 40, width: 540, height: 52)
        let placement = NotePopoverLayout.placement(
            block: block, doorwayX: 530, content: content, expanded: false)
        XCTAssertEqual(placement.frame.minX, block.minX)
        XCTAssertEqual(placement.frame.width, block.width)
        XCTAssertEqual(placement.frame.minY, block.maxY, "the popover is not under the block")
        XCTAssertEqual(
            placement.frame.height, NotePopoverLayout.height + NotePopoverLayout.arrowHeight)
        XCTAssertTrue(placement.below)
        XCTAssertEqual(placement.arrowX, 530 - block.minX, "the arrow is not under the doorway")
        XCTAssertEqual(NotePopoverLayout.cornerRadius, 10)
    }

    /// A block narrower than the popover's minimum puts the note across
    /// the card's content width (Law 0001, note row).
    func testANarrowBlockPutsTheNoteAcrossTheContentWidth() {
        let content = CGRect(x: 0, y: 0, width: 360, height: 500)
        let minimum = NotePopoverLayout.minimumWidth
        let narrow = CGRect(x: 30, y: 40, width: minimum - 1, height: 52)
        let placement = NotePopoverLayout.placement(
            block: narrow, doorwayX: narrow.maxX - 10, content: content, expanded: false)
        let inset = NotePopoverLayout.edgeInset
        XCTAssertEqual(placement.frame.minX, content.minX + inset)
        XCTAssertEqual(placement.frame.width, content.width - inset * 2)
        let wide = CGRect(x: 30, y: 40, width: minimum, height: 52)
        XCTAssertEqual(
            NotePopoverLayout.placement(
                block: wide, doorwayX: wide.maxX, content: content, expanded: false
            ).frame.width, minimum, "a block at the minimum took the content width")
        XCTAssertEqual(NotePopoverLayout.minimumWidth, 320)
    }

    /// Expanded, the note covers the content area and has no arrow; with no
    /// room under the block it stands over it, its arrow below.
    func testExpandedTheNoteCoversTheContentAndWithoutRoomBelowItStandsAbove() {
        let content = CGRect(x: 0, y: 0, width: 600, height: 500)
        let block = CGRect(x: 20, y: 400, width: 540, height: 52)
        let expanded = NotePopoverLayout.placement(
            block: block, doorwayX: 530, content: content, expanded: true)
        XCTAssertEqual(
            expanded.frame,
            content.insetBy(dx: NotePopoverLayout.edgeInset, dy: NotePopoverLayout.edgeInset))
        XCTAssertNil(expanded.arrowX)
        let above = NotePopoverLayout.placement(
            block: block, doorwayX: 530, content: content, expanded: false)
        XCTAssertFalse(above.below)
        XCTAssertEqual(above.frame.maxY, block.minY)
        let edge = NotePopoverLayout.placement(
            block: CGRect(x: 20, y: 40, width: 540, height: 52), doorwayX: 0, content: content,
            expanded: false)
        XCTAssertEqual(
            edge.arrowX, NotePopoverLayout.cornerRadius + NotePopoverLayout.arrowHalfWidth,
            "the arrow left the popover's straight edge")
    }

    // MARK: The doorway (sealed row spec, Doorway)

    /// Once a note exists the seat reads `small · note`, size class first;
    /// a hovered zone or a copy takes the seat whole.
    func testTheSeatOpensADoorwayOnceANoteExists() {
        XCTAssertEqual(
            SealedBlockCell.seatText(sizeLabel: "small", hasNote: true, hovered: nil, copied: false),
            "small · note")
        XCTAssertEqual(
            SealedBlockCell.seatText(sizeLabel: "small", hasNote: false, hovered: nil, copied: false),
            "small")
        XCTAssertEqual(
            SealedBlockCell.seatText(
                sizeLabel: "small", hasNote: true, hovered: .value, copied: false),
            "copies the value, decrypted")
        let frame = NSRect(x: 0, y: 0, width: 480, height: SealedBlockCell.blockHeight)
        let face = ChipInfo(
            chipId: 1, kind: "text", excerpt: "ab…cd", sizeLabel: "small", concealed: false,
            hasNote: true)
        let doorway = SealedBlockCell(info: face).doorwayRect(in: frame)
        let layout = SealedBlockCell.contentLayout(in: frame)
        XCTAssertEqual(doorway?.maxX ?? 0, layout.metadataRight, accuracy: 0.5)
        XCTAssertEqual(doorway?.minY, layout.metadataY)
        XCTAssertNil(
            SealedBlockCell(info: ChipInfo(
                chipId: 1, kind: "text", excerpt: "ab…cd", sizeLabel: "small", concealed: false)
            ).doorwayRect(in: frame), "an object with no note has a doorway")
    }

    /// A click on `note` opens the note on its first click and nothing on
    /// the clicks after it, named or not.
    func testAClickOnTheDoorwayOpensTheNoteOnce() {
        for named in [false, true] {
            XCTAssertEqual(
                InkTextView.chipClick(
                    named: named, zone: nil, inRow: true, onDoorway: true, clickCount: 1,
                    modifierFlags: []),
                .openNote)
            XCTAssertEqual(
                InkTextView.chipClick(
                    named: named, zone: nil, inRow: true, onDoorway: true, clickCount: 2,
                    modifierFlags: []),
                .ignore, "a double click on the doorway opened the name field")
        }
    }

    // MARK: Opening and closing

    /// *Note…* opens the popover under the block in the page's own window,
    /// so no window of its own can be counted an outside click, and the
    /// keys go to the note; the page's caret stays where it was.
    func testTheMenusVerbOpensTheNoteInThePagesOwnWindow() throws {
        let page = try makePage()
        let menu = try XCTUnwrap(page.coordinator.chipMenu(at: 3))
        let verb = try XCTUnwrap(menu.items.first { $0.title == "Note…" })
        _ = (verb.target as? NSObject)?.perform(verb.action, with: verb)
        let editor = try note(page)

        XCTAssertTrue(editor.isOpen)
        XCTAssertTrue(editor.popover.window === page.window, "the note stood in a window of its own")
        XCTAssertTrue(editor.overlay.superview === page.scroll)
        XCTAssertTrue(editor.holdsKeys)
        XCTAssertTrue(page.textView.yieldsKeys)
        let block = editor.overlay.convert(try XCTUnwrap(page.textView.chipFrame(at: 3)), from: page.textView)
        XCTAssertEqual(editor.popover.frame.minY, block.maxY, accuracy: 0.5)
        XCTAssertEqual(editor.popover.frame.width, block.width, accuracy: 0.5)
        XCTAssertEqual(editor.popover.title.stringValue, "NOTE")
        XCTAssertEqual(editor.popover.hint.stringValue, "esc closes")
        XCTAssertEqual(editor.popover.expandHint.stringValue, "⇧esc")
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    /// A click on the doorway opens the note; Esc closes it and gives the
    /// keys back to the page; *Edit Note…* reads so once a note exists.
    func testTheDoorwayOpensTheNoteAndEscClosesIt() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type("rotate monthly", into: editor)
        editor.escape()
        XCTAssertFalse(editor.isOpen)
        XCTAssertNil(editor.overlay.superview)
        XCTAssertTrue(page.window.firstResponder === page.textView, "the keys did not come back")
        XCTAssertEqual(page.textView.chipCell(at: 3)?.info.hasNote, true, "the doorway did not open")

        let menu = try XCTUnwrap(page.coordinator.chipMenu(at: 3))
        XCTAssertNotNil(menu.items.first { $0.title == "Edit Note…" })
        XCTAssertFalse(menu.items.contains { $0.title == "Note…" })

        page.textView.layout()
        let frame = try XCTUnwrap(page.textView.chipFrame(at: 3))
        let doorway = try XCTUnwrap(page.textView.chipCell(at: 3)?.doorwayRect(in: frame))
        let press = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: page.textView.convert(NSPoint(x: doorway.midX, y: doorway.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: page.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        page.textView.mouseDown(with: press)
        XCTAssertTrue(editor.isOpen, "the doorway's click opened nothing")
        XCTAssertEqual(editor.textView.string, "rotate monthly", "the note came back empty")
    }

    /// The arrows and ⇧Esc grow the note to the content area and back; Esc
    /// on an expanded note contracts it rather than closing it.
    func testTheArrowsAndShiftEscExpandAndContractAndEscContracts() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        let contracted = editor.popover.frame
        let inset = NotePopoverLayout.edgeInset

        editor.popover.expand.performClick(nil)
        XCTAssertTrue(editor.isExpanded)
        XCTAssertEqual(editor.popover.frame, editor.overlay.bounds.insetBy(dx: inset, dy: inset))
        XCTAssertEqual(editor.popover.hint.stringValue, "esc contracts")
        editor.popover.expand.performClick(nil)
        XCTAssertFalse(editor.isExpanded)
        XCTAssertEqual(editor.popover.frame, contracted)

        let shiftEscape = try keyEvent("\u{1b}", keyCode: 53, flags: .shift, in: page.window)
        editor.textView.keyDown(with: shiftEscape)
        XCTAssertTrue(editor.isExpanded, "⇧Esc did not expand")
        editor.textView.keyDown(with: shiftEscape)
        XCTAssertFalse(editor.isExpanded, "⇧Esc did not contract")

        editor.textView.keyDown(with: shiftEscape)
        editor.textView.cancelOperation(nil)
        XCTAssertTrue(editor.isOpen, "Esc closed an expanded note")
        XCTAssertFalse(editor.isExpanded, "Esc did not contract")
        XCTAssertEqual(editor.popover.frame, contracted)
        editor.textView.cancelOperation(nil)
        XCTAssertFalse(editor.isOpen)
    }

    /// The keys leaving the note, the page changing under it, the page
    /// going read only, the object leaving and the name field opening all
    /// close the note.
    func testTheNoteClosesWhenItsSeatGoes() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        page.window.makeFirstResponder(page.textView)
        drainMainQueue()
        XCTAssertFalse(editor.isOpen, "a click elsewhere left the note open")

        page.coordinator.beginNote(at: 3)
        page.coordinator.updateEditability(of: page.textView, to: false)
        XCTAssertFalse(editor.isOpen, "a read only page kept the note")
        page.coordinator.beginNote(at: 3)
        XCTAssertFalse(editor.isOpen, "a read only page opened the note")
        page.coordinator.updateEditability(of: page.textView, to: true)

        page.coordinator.beginNote(at: 3)
        page.coordinator.beginNaming(at: 3)
        XCTAssertFalse(editor.isOpen, "the name field and the note stood together")
        page.coordinator.keepNaming()

        page.coordinator.beginNote(at: 3)
        let other = page.model.storage(for: try XCTUnwrap({ () -> UInt64? in
            page.model.newPage()
            return page.model.selectedPageID
        }()))
        page.coordinator.moveEditor(
            page.textView, to: try XCTUnwrap(page.model.selectedPageID), storage: other,
            restoringScrollIn: nil)
        XCTAssertFalse(editor.isOpen, "a page swap kept the note")
    }

    func testTheObjectLeavingThePageClosesItsNote() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        let storage = try XCTUnwrap(page.textView.textStorage)
        storage.deleteCharacters(in: NSRange(location: 3, length: 1))
        page.coordinator.followNote()
        XCTAssertFalse(editor.isOpen, "the note outlived its object")
    }

    // MARK: Writing in the note

    /// What is typed in the note is the note's, core-side, and the page's
    /// ink, caret and undo are as they were; the note's ⌘Z steps the note,
    /// and the page's chords stand aside while the note holds the keys.
    func testANoteEditLeavesThePagesCaretAndUndoAlone() throws {
        let page = try makePage()
        page.textView.insertText(" more", replacementRange: NSRange(location: 7, length: 0))
        page.textView.setSelectedRange(NSRange(location: 1, length: 0))
        let inkBefore = pageInk(page)
        let canUndoPage = page.model.canUndoEdit(sheet: page.sheet)
        let pageUndoName = page.model.undoActionName(sheet: page.sheet)
        XCTAssertTrue(canUndoPage, "the page has no step to lose")

        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type("rotate", into: editor)
        type(" monthly", into: editor)
        XCTAssertEqual(page.model.noteText(chip: page.chip), "rotate monthly")
        XCTAssertEqual(pageInk(page), inkBefore, "the note's ink reached the page")

        let undo = try keyEvent("z", keyCode: 6, flags: .command, in: page.window)
        XCTAssertFalse(page.textView.performKeyEquivalent(with: undo), "the page took the note's ⌘Z")
        XCTAssertTrue(editor.textView.performKeyEquivalent(with: undo))
        XCTAssertNotEqual(page.model.noteText(chip: page.chip), "rotate monthly")
        XCTAssertEqual(editor.textView.string, page.model.noteText(chip: page.chip))
        XCTAssertEqual(pageInk(page), inkBefore, "the note's ⌘Z stepped the page")
        XCTAssertEqual(page.model.canUndoEdit(sheet: page.sheet), canUndoPage)
        XCTAssertEqual(page.model.undoActionName(sheet: page.sheet), pageUndoName)

        let seal = try keyEvent("v", keyCode: 9, flags: [.command, .shift], in: page.window)
        XCTAssertTrue(editor.textView.performKeyEquivalent(with: seal), "a seal fell through the note")
        XCTAssertEqual(pageInk(page), inkBefore)

        editor.escape()
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertEqual(pageInk(page), inkBefore)
        XCTAssertEqual(page.model.canUndoEdit(sheet: page.sheet), canUndoPage)
    }

    /// The doorway follows the note: it opens with the first ink and goes
    /// when the note holds only whitespace.
    func testTheDoorwayFollowsTheNotesInk() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type("  ", into: editor)
        XCTAssertEqual(page.textView.chipCell(at: 3)?.info.hasNote, false)
        type("x", into: editor)
        XCTAssertEqual(page.textView.chipCell(at: 3)?.info.hasNote, true)
        editor.textView.selectAll(nil)
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(page.textView.chipCell(at: 3)?.info.hasNote, false)
        XCTAssertEqual(page.model.noteText(chip: page.chip), "")
    }

    /// A closed note leaves none of its ink in the shell, whether Esc
    /// closed it or its object left the page; the core still holds it.
    func testAClosedNoteLeavesNoInkInTheShell() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type("rotate monthly", into: editor)
        editor.escape()
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(editor.textView.string, "", "the note's ink outlived its popover")
        XCTAssertEqual(page.model.noteText(chip: page.chip), "rotate monthly")

        page.coordinator.beginNote(at: 3)
        XCTAssertEqual(editor.textView.string, "rotate monthly", "reopening lost the note")
        type(" again", into: editor)
        XCTAssertEqual(page.model.noteText(chip: page.chip), "rotate monthly again")
        let storage = try XCTUnwrap(page.textView.textStorage)
        storage.deleteCharacters(in: NSRange(location: 3, length: 1))
        page.coordinator.followNote()
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(editor.textView.string, "", "the note's ink outlived its object")
    }

    /// A drag from elsewhere finds nowhere to land in the note, since a
    /// seal cannot stand in it (ADR-0043 point 2); a drag of the note's own
    /// ink still moves it.
    func testTheNoteTakesNoDropFromElsewhere() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type("kept", into: editor)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString("hunter2", forType: .string)
        let point = editor.textView.convert(NSPoint(x: 8, y: 8), to: nil)

        let own = DraggingInfoStub(
            pasteboard: board, source: editor.textView, location: point, window: page.window)
        XCTAssertNotEqual(editor.textView.draggingEntered(own), [], "the control: its own drag")

        let other = DraggingInfoStub(
            pasteboard: board, source: nil, location: point, window: page.window)
        XCTAssertEqual(editor.textView.draggingEntered(other), [])
        XCTAssertEqual(editor.textView.draggingUpdated(other), [])
        XCTAssertFalse(editor.textView.performDragOperation(other))
        XCTAssertEqual(editor.textView.string, "kept")
        XCTAssertEqual(page.model.noteText(chip: page.chip), "kept")
    }

    // MARK: The page's own surface (ADR-0044)

    /// The same ink reads the same in the note as on the page, by font, colour
    /// and link, and a link's click goes to the page's handler (ADR-0023).
    func testTheNoteWearsThePagesFace() throws {
        let page = try makePage()
        let ink = "# Rotate\n- monthly\nsee https://example.com/keys\n```swift\nlet key = 1\n```\n"
        let start = try XCTUnwrap(page.textView.textStorage).length
        page.textView.insertText(
            "\n" + ink, replacementRange: NSRange(location: start, length: 0))
        let onPage = try XCTUnwrap(page.textView.textStorage)
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type(ink, into: editor)
        let inNote = try XCTUnwrap(editor.textView.textStorage)

        XCTAssertTrue(editor.textView.delegate === editor.coordinator)
        XCTAssertEqual(inNote.string, ink)
        for offset in 0..<(ink as NSString).length {
            for key in [NSAttributedString.Key.font, .foregroundColor, .link, .underlineStyle] {
                let note = inNote.attribute(key, at: offset, effectiveRange: nil) as? NSObject
                let mirror = onPage.attribute(key, at: start + 1 + offset, effectiveRange: nil) as? NSObject
                XCTAssertEqual(note, mirror, "\(key.rawValue) at \(offset) differs from the page's")
            }
        }
        XCTAssertEqual(
            inNote.attribute(.font, at: 2, effectiveRange: nil) as? NSFont,
            InkStyle.headingFont(level: 1), "the note's heading is not a heading")
        XCTAssertNotNil(
            inNote.attribute(.link, at: (ink as NSString).range(of: "https").location,
                             effectiveRange: nil), "the note's URL is not a link")
        XCTAssertEqual(
            (editor.textView.layoutManager as? InkLayoutManager)?.fenceRegions.count, 1,
            "the note's fence draws no slab")
    }

    /// Return on a list item continues it, Tab in its marker nests it, and
    /// each is a step of the note's own stack (ADR-0024).
    func testANoteContinuesAndNestsAListAsThePageDoes() throws {
        let page = try makePage()
        let inkBefore = pageInk(page)
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type("- first", into: editor)
        editor.textView.insertNewline(nil)
        XCTAssertEqual(editor.textView.string, "- first\n- ")
        editor.textView.insertTab(nil)
        XCTAssertEqual(editor.textView.string, "- first\n  - ")
        XCTAssertEqual(page.model.noteText(chip: page.chip), "- first\n  - ")

        editor.textView.undo(nil)
        XCTAssertEqual(page.model.noteText(chip: page.chip), "- first\n- ", "⌘Z took more than the nesting")
        editor.textView.undo(nil)
        XCTAssertEqual(page.model.noteText(chip: page.chip), "- first", "⌘Z took more than the marker")
        XCTAssertEqual(editor.textView.string, "- first")
        editor.textView.insertNewline(nil)
        editor.textView.insertNewline(nil)
        XCTAssertEqual(editor.textView.string, "- first\n", "a Return on an empty item kept it")
        XCTAssertEqual(pageInk(page), inkBefore, "the note's list reached the page")
    }

    /// A bare fence's display language is the note's and no page's; a
    /// selection wraps into a fence on the note's own routes.
    func testChooseLanguageActsOnTheNoteAndItsLabelIsTheNotesOwn() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type("```\nlet key = 1\n```", into: editor)
        editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(editor.textView.canChooseCodeLanguage)
        editor.coordinator.applyManualLanguage("swift")
        XCTAssertEqual(editor.textView.string, "```\nlet key = 1\n```", "a display label rewrote the note")
        XCTAssertNotEqual(
            editor.textView.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil)
                as? NSColor, NSColor.labelColor, "the fence took no colour from its label")
        XCTAssertEqual(page.model.fenceRenderingLanguages(for: page.sheet), [:])
        XCTAssertEqual(page.model.fenceRenderingLanguages(for: page.chip), [:])

        editor.textView.selectAll(nil)
        editor.textView.deleteBackward(nil)
        type("let key = 1", into: editor)
        editor.textView.selectAll(nil)
        editor.coordinator.applyManualLanguage("swift")
        XCTAssertEqual(page.model.noteText(chip: page.chip), "```swift\nlet key = 1\n```")
    }

    /// No seal lands in a note: the chords, the menu and the context menu
    /// seal nothing, and the page's ink and the board are as they were.
    func testNoSealLandsInANote() throws {
        let page = try makePage()
        let inkBefore = pageInk(page)
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type("hunter2", into: editor)
        editor.textView.selectAll(nil)

        XCTAssertFalse(editor.coordinator.sealsHere)
        XCTAssertNil(editor.coordinator.sealableSelection())
        let menu = NSMenu()
        editor.coordinator.appendSealItem(to: menu)
        XCTAssertTrue(menu.items.isEmpty, "the note's context menu offered a seal")
        let sealLine = try keyEvent("\r", keyCode: 36, flags: .command, in: page.window)
        XCTAssertTrue(editor.textView.performKeyEquivalent(with: sealLine), "⌘↩ fell through the note")
        XCTAssertFalse(page.textView.performKeyEquivalent(with: sealLine), "the page took the note's ⌘↩")
        editor.textView.sealSelectedContent(nil)
        editor.coordinator.sealedPaste()

        XCTAssertEqual(editor.textView.string, "hunter2")
        XCTAssertEqual(page.model.noteText(chip: page.chip), "hunter2")
        XCTAssertEqual(pageInk(page), inkBefore)
        XCTAssertEqual(page.model.coreClient.documentRuns(sheet: page.sheet).filter {
            if case .chip = $0 { true } else { false }
        }.count, 1, "a seal from the note stood on the page")
    }

    /// No object stands in a note: a batch carrying one is refused and the
    /// note restated, and the page's object finds nowhere to land in it.
    func testNoObjectStandsInANote() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type("kept", into: editor)
        let face = try XCTUnwrap(page.textView.chipCell(at: 3)?.info)
        editor.textView.insertText(
            InkEditorView.Coordinator.chipString(face),
            replacementRange: NSRange(location: 4, length: 0))
        drainMainQueue()
        XCTAssertEqual(editor.textView.string, "kept", "an object stood in the note")
        XCTAssertEqual(page.model.noteText(chip: page.chip), "kept")

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString("hunter2", forType: .string)
        let drag = DraggingInfoStub(
            pasteboard: board, source: page.textView,
            location: editor.textView.convert(NSPoint(x: 8, y: 8), to: nil), window: page.window)
        XCTAssertEqual(editor.textView.draggingEntered(drag), [])
        XCTAssertFalse(editor.textView.performDragOperation(drag))
        XCTAssertEqual(page.model.noteText(chip: page.chip), "kept")
    }

    /// A note shows no block stamps, and its chip id, which overlaps page
    /// ids, never reaches the page's block route.
    func testANoteShowsNoBlockStampsAndAsksNoPageForThem() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        let askedBefore = page.client.blocksAsked.count
        type("one\ntwo\n", into: editor)
        editor.textView.layout()
        XCTAssertFalse(
            editor.textView.subviews.contains { $0 is BlockMetadataField },
            "the note drew block stamps")
        XCTAssertEqual(
            Array(page.client.blocksAsked.dropFirst(askedBefore)).filter { $0 == page.chip }, [],
            "the note asked a page's block route with its chip id")
        XCTAssertEqual(editor.textView.textContainerInset, NSSize(width: 4, height: 4))
    }

    /// While the note holds the keys the Edit menu's actions reach the note,
    /// not the page, and the menu shows what the note can do (Law 0007, keys row).
    func testTheEditMenuActsOnTheNoteWhileItHoldsTheKeys() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        drainMainQueue()
        XCTAssertTrue(page.model.sealActions.canSeal, "the control: the page's selection seals")
        let inkBefore = pageInk(page)
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        type("```\nlet key = 1\n```", into: editor)
        editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
        drainMainQueue()

        for action in pageMenuActions {
            XCTAssertTrue(
                answerer(of: action, in: page.window) === editor.textView,
                "\(action) missed the note")
        }
        XCTAssertTrue(page.model.languageActions.canChoose, "the menu hid the note's Choose Language")
        XCTAssertFalse(page.model.sealActions.canSeal, "the menu offered a seal in the note")
        editor.textView.selectAll(nil)
        drainMainQueue()
        XCTAssertFalse(page.model.sealActions.canSeal, "the menu offered a seal over the note's text")

        page.textView.chooseCodeLanguage(CodeLanguageChoice(language: "rust"))
        page.textView.undo(nil)
        XCTAssertEqual(pageInk(page), inkBefore, "the page answered the menu under the note")
        let rawText = "let key = 1"
        editor.textView.selectAll(nil)
        editor.textView.insertText(rawText, replacementRange: editor.textView.selectedRange())
        editor.textView.selectAll(nil)
        XCTAssertTrue(editor.textView.tryToPerform(
            #selector(LanguageDetectionResponder.chooseCodeLanguage(_:)),
            with: CodeLanguageChoice(language: "rust")))
        XCTAssertEqual(page.model.noteText(chip: page.chip), "```rust\n\(rawText)\n```")
        XCTAssertEqual(pageInk(page), inkBefore)

        editor.escape()
        drainMainQueue()
        XCTAssertTrue(page.model.languageActions.canPaste, "the menu did not come back to the page")
    }

    /// ⌥Z, the page's wrap toggle, is not the note's: a note always wraps.
    func testTheWrapToggleStandsAsideInANote() throws {
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        let wraps = page.model.wrapsLines
        let toggle = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: page.window.windowNumber, context: nil, characters: "Ω",
            charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertEqual(page.model.keymap.command(for: toggle, in: .editor), .editorToggleWrap)
        editor.textView.keyDown(with: toggle)
        XCTAssertEqual(page.model.wrapsLines, wraps, "⌥Z in the note flipped the page's wrap")
        XCTAssertTrue(editor.isOpen)
    }

    /// A named object's note is headed with its name.
    func testANamedObjectsNoteIsHeadedWithItsName() throws {
        let page = try makePage()
        XCTAssertTrue(page.model.setChipName("MY_API_KEY", chip: page.chip, sheet: page.sheet))
        page.coordinator.beginNote(at: 3)
        XCTAssertEqual(try note(page).popover.title.stringValue, "NOTE · MY_API_KEY")
    }

    /// No route in or out of the note runs a modal session (D-14).
    func testNoNoteRouteRunsAModalSession() throws {
        var ends = 0
        let token = NotificationCenter.default.addObserver(
            forName: ModalSession.didEndNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { ends += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let page = try makePage()
        page.coordinator.beginNote(at: 3)
        let editor = try note(page)
        XCTAssertFalse(ModalSession.isRunning)
        editor.toggleExpanded()
        type("x", into: editor)
        editor.escape()
        editor.escape()
        XCTAssertFalse(ModalSession.isRunning)
        XCTAssertEqual(ends, 0)
    }

    // MARK: A page past its deadline (Law 0001, expiry row)

    /// Puts the page past its deadline with no sweep: a one hour rung, two hours on.
    private func age(_ page: Page) throws {
        let tab = try XCTUnwrap(page.model.tabs.first { $0.pageID == page.sheet }?.id)
        XCTAssertTrue(page.client.setRung(tab: tab, rung: .oneHour))
        XCTAssertTrue(page.client.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        // The re-mint is dense, so the page's and the object's ids still name what the core keeps.
        XCTAssertTrue(page.client.tabs().contains { $0.pageID == page.sheet }, "the page was swept")
        XCTAssertTrue(page.client.chipStands(page.chip), "the object was renumbered")
    }

    /// From its deadline, before any sweep, a note's batch, its undo and redo and a
    /// rename each refuse and settle at once with the expired line.
    func testANoteEditStepOrNamePastItsPagesDeadlineSettlesWithTheExpiredLine() throws {
        let routes: [(name: String, run: (Page, SealedNoteEditor) -> Void)] = [
            ("a batch", { _, editor in self.type(" monthly", into: editor) }),
            ("undo", { page, _ in
                XCTAssertFalse(page.model.stepEdit(.note(chip: page.chip), back: true).applied)
            }),
            ("redo", { page, _ in
                XCTAssertFalse(page.model.stepEdit(.note(chip: page.chip), back: false).applied)
            }),
            ("a name", { page, _ in
                XCTAssertFalse(page.model.setChipName("API_KEY", chip: page.chip, sheet: page.sheet))
            }),
        ]
        for route in routes {
            let page = try makePage()
            page.coordinator.beginNote(at: 3)
            let editor = try note(page)
            type("rotate", into: editor)
            try age(page)

            route.run(page, editor)
            drainMainQueue()

            XCTAssertEqual(page.model.notice, PageModel.pageExpiredLine, route.name)
            XCTAssertFalse(
                page.model.tabs.contains { $0.pageID == page.sheet },
                "\(route.name): the page outlived its refusal")
        }
    }
}
