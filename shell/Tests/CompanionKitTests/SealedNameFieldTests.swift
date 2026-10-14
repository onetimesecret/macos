import AppKit
import XCTest

@testable import CompanionKit

/// A sealed object's name, edited in the name's seat (Law 0007, ADR-0042
/// points 1 and 3), against the live core through an isolated model.
@MainActor
final class SealedNameFieldTests: XCTestCase {
    private struct Page {
        let model: PageModel
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let scroll: NSScrollView
        let sheet: UInt64
        let chip: UInt64
    }

    /// `ab <chip> cd` on a page of its own, the chip sealed from `SECRET`.
    private func makePage() throws -> Page {
        let suite = "companion-sealed-name-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let sheet = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: sheet, coordinator: coordinator))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        InkEditorView.seat(textView, in: scroll)
        textView.isEditable = true
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()
        textView.layout()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let chip = try XCTUnwrap(coordinator.chipAttachment(at: 3)?.info.chipId)
        return Page(
            model: model, coordinator: coordinator, textView: textView, scroll: scroll,
            sheet: sheet, chip: chip)
    }

    private func coreName(_ page: Page) -> String? {
        for run in page.model.coreClient.documentRuns(sheet: page.sheet) {
            if case .chip(let face) = run, face.chipId == page.chip { return face.name }
        }
        return nil
    }

    private func field(_ page: Page) throws -> SealedNameEditor {
        try XCTUnwrap(page.coordinator.nameEditor, "no field was opened")
    }

    // MARK: Opening

    /// *Name…* opens the field in the name's seat on the current name,
    /// with `NAME` as its placeholder, and the excerpt stays to its right.
    func testTheFieldOpensInTheSeatOnTheNameWithTheExcerptToItsRight() throws {
        let page = try makePage()
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        XCTAssertTrue(editor.isOpen)
        XCTAssertEqual(editor.draft, "", "an unnamed object's field opens on nothing")
        XCTAssertEqual(editor.field.placeholderAttributedString?.string, "NAME")
        XCTAssertTrue(editor.field.superview === page.textView, "the field is not in the seat")
        let frame = try XCTUnwrap(page.textView.chipFrame(at: 3))
        let layout = SealedBlockCell.contentLayout(in: frame)
        XCTAssertEqual(
            editor.field.frame.minX, layout.left - SealedNameEditor.textInset, accuracy: 0.5)
        XCTAssertTrue(layout.rowBand.contains(NSPoint(
            x: editor.field.frame.midX, y: editor.field.frame.midY)))
        let naming = try XCTUnwrap(page.textView.naming)
        XCTAssertEqual(naming.chip, page.chip)
        let cell = try XCTUnwrap(page.textView.chipCell(at: 3))
        let row = try XCTUnwrap(cell.namedRow(in: frame, editingWidth: naming.width))
        XCTAssertEqual(
            row.geometry.equals.minX, editor.field.frame.maxX + SealedNameEditor.textInset,
            accuracy: 0.5, "the `=` does not follow the field")
        XCTAssertEqual(row.value.string, cell.info.excerpt, "the excerpt left the row")
        XCTAssertGreaterThanOrEqual(row.geometry.value.minX, row.geometry.equals.maxX)

        editor.keep(returningKeys: false)
        XCTAssertTrue(page.model.setChipName("DB_PASSWORD", chip: page.chip, sheet: page.sheet))
        page.coordinator.beginNaming(at: 3)
        XCTAssertEqual(editor.draft, "DB_PASSWORD", "a named object's field opens on its name")
    }

    /// The menu's verb reads *Name…* unnamed and *Rename…* named, and both
    /// open the field.
    func testTheMenusVerbOpensTheField() throws {
        let page = try makePage()
        let unnamed = try XCTUnwrap(page.coordinator.chipMenu(at: 3))
        let verb = try XCTUnwrap(unnamed.items.first { $0.title == "Name…" })
        XCTAssertFalse(unnamed.items.contains { $0.title == "Rename…" })
        _ = (verb.target as? NSObject)?.perform(verb.action, with: verb)
        XCTAssertEqual(page.coordinator.nameEditor?.isOpen, true)
        page.coordinator.keepNaming()

        XCTAssertTrue(page.model.setChipName("DB_PASSWORD", chip: page.chip, sheet: page.sheet))
        let named = try XCTUnwrap(page.coordinator.chipMenu(at: 3))
        XCTAssertNotNil(named.items.first { $0.title == "Rename…" })
        XCTAssertFalse(named.items.contains { $0.title == "Name…" })
    }

    /// The double click opens the field only where ADR-0042 point 3 says:
    /// a named row's name zone, or anywhere on an unnamed row.
    func testADoubleClickOpensTheFieldOnlyWhereTheRuleSays() {
        XCTAssertEqual(
            InkTextView.chipClick(
                named: true, zone: .name, inRow: true, clickCount: 2, modifierFlags: []),
            .openName)
        for zone in [SealedBlockLayout.Zone.value, .equals] {
            XCTAssertEqual(
                InkTextView.chipClick(
                    named: true, zone: zone, inRow: true, clickCount: 2, modifierFlags: []),
                .ignore, "a double click on a decrypted zone opened the field")
        }
        XCTAssertEqual(
            InkTextView.chipClick(
                named: true, zone: nil, inRow: true, clickCount: 2, modifierFlags: []),
            .select, "a named row opened from outside its name zone")
        XCTAssertEqual(
            InkTextView.chipClick(
                named: false, zone: nil, inRow: true, clickCount: 2, modifierFlags: []),
            .openName)
        XCTAssertEqual(
            InkTextView.chipClick(
                named: false, zone: nil, inRow: false, clickCount: 2, modifierFlags: []),
            .select, "an unnamed block opened from its top row")
        XCTAssertEqual(
            InkTextView.chipClick(
                named: false, zone: nil, inRow: true, clickCount: 3, modifierFlags: []),
            .ignore)
        XCTAssertEqual(
            InkTextView.chipClick(
                named: false, zone: nil, inRow: true, clickCount: 2, modifierFlags: .command),
            .select)
    }

    /// A page shown read only opens no field.
    func testAReadOnlyPageOpensNoField() throws {
        let page = try makePage()
        page.textView.isEditable = false
        page.coordinator.beginNaming(at: 3)
        XCTAssertNotEqual(page.coordinator.nameEditor?.isOpen, true)
    }

    // MARK: Ending

    /// Return names the object core-side and redraws its block where it
    /// stands; the field shuts.
    func testReturnNamesTheObjectAndRedrawsItsBlock() throws {
        let page = try makePage()
        let cell = try XCTUnwrap(page.textView.chipCell(at: 3))
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        editor.draft = "  MY_API_KEY "
        editor.commit()

        XCTAssertFalse(editor.isOpen)
        XCTAssertNil(page.textView.naming)
        XCTAssertTrue(editor.field.isHidden)
        XCTAssertEqual(coreName(page), "MY_API_KEY", "trimmed and handed to the core")
        XCTAssertEqual(cell.info.name, "MY_API_KEY", "the block was not redrawn in place")
        XCTAssertTrue(page.textView.chipCell(at: 3) === cell, "the page was restated")
    }

    /// Escape, the keyboard leaving, and an untouched Return keep the
    /// name; an empty Return clears it and the row is unnamed again.
    func testEscapeFocusLossAndAnUntouchedReturnKeepAndAnEmptyReturnClears() throws {
        let page = try makePage()
        XCTAssertTrue(page.model.setChipName("DB_PASSWORD", chip: page.chip, sheet: page.sheet))
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)

        editor.draft = "OTHER"
        editor.keep(returningKeys: true)
        XCTAssertEqual(coreName(page), "DB_PASSWORD", "escape renamed")

        page.coordinator.beginNaming(at: 3)
        editor.draft = "OTHER"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(coreName(page), "DB_PASSWORD", "a focus loss renamed")

        page.coordinator.beginNaming(at: 3)
        editor.commit()
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(coreName(page), "DB_PASSWORD")

        page.coordinator.beginNaming(at: 3)
        editor.draft = "   "
        editor.commit()
        XCTAssertNil(coreName(page), "an empty Return kept the name")
        XCTAssertNil(page.textView.chipCell(at: 3)?.info.name)
    }

    /// The endings are decided by `TabRename`, the one rule every name
    /// field ends through (Law 0007).
    func testTheEndingsAreTabRenamesOutcomes() throws {
        let page = try makePage()
        var rename = ChipRename()
        rename.open(chip: page.chip, sheet: page.sheet, name: "DB_PASSWORD", in: page.model)
        XCTAssertEqual(rename.draft, "DB_PASSWORD")
        rename.edit("DB_PASSWORD ", in: page.model)
        XCTAssertTrue(rename.commit(in: page.model))
        XCTAssertNil(coreName(page), "an untouched Return named the object")

        rename.open(chip: page.chip, sheet: page.sheet, name: nil, in: page.model)
        rename.edit("", in: page.model)
        XCTAssertTrue(rename.commit(in: page.model))
        XCTAssertNil(coreName(page), "an untouched empty Return is a keep, not a clear")
    }

    // MARK: Refusing

    /// A draft outside the rule is said in the line under the page with
    /// the field open; the line stays past the notice dwell and goes once
    /// the draft becomes a name the core takes.
    func testARefusalKeepsTheFieldAndTheLine() throws {
        let page = try makePage()
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        editor.draft = "my.key"
        editor.commit()

        XCTAssertTrue(editor.isOpen, "a refusal shut the field")
        XCTAssertTrue(editor.rename.isRefusing)
        XCTAssertEqual(page.model.notice, ChipRename.words(for: .outsideCharset))
        XCTAssertNil(coreName(page))
        page.model.flash("a passing line")
        XCTAssertEqual(page.model.notice, "a passing line")

        editor.draft = String(repeating: "A", count: 65)
        XCTAssertEqual(page.model.notice, "a passing line", "a new refusal cut the line in front")
        waitUntil(page.model.$notice, description: "the line came back on the new refusal") {
            $0 == ChipRename.words(for: .tooLong)
        }
        editor.draft = "MY_KEY"
        XCTAssertFalse(editor.rename.isRefusing)
        XCTAssertNil(page.model.notice, "the line outlived its refusal")
        editor.commit()
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(coreName(page), "MY_KEY")
    }

    func testTheRefusalsWordsAreTheFieldsOwn() {
        XCTAssertEqual(
            ChipRename.words(for: .tooLong), "Use 64 characters or fewer for the name.")
        XCTAssertEqual(
            ChipRename.words(for: .outsideCharset),
            "Use the letters A to Z, digits and underscores for the name, and start it with a letter or an underscore."
        )
    }

    // MARK: The write a name arms (ADR-0043 point 5)

    /// A name set or cleared and a note edited each mark the page dirty;
    /// a name the core refuses marks nothing.
    func testANameOrANoteEditArmsAWriteAndARefusalArmsNone() throws {
        let page = try makePage()
        var marks = page.model.dirtyMarks
        XCTAssertTrue(page.model.setChipName("DB_PASSWORD", chip: page.chip, sheet: page.sheet))
        XCTAssertEqual(coreName(page), "DB_PASSWORD")
        XCTAssertGreaterThan(page.model.dirtyMarks, marks, "a name armed no write")

        marks = page.model.dirtyMarks
        XCTAssertFalse(page.model.setChipName("db.password", chip: page.chip, sheet: page.sheet))
        XCTAssertEqual(coreName(page), "DB_PASSWORD")
        XCTAssertEqual(page.model.dirtyMarks, marks, "a refused name armed a write")

        XCTAssertTrue(page.model.setChipName("", chip: page.chip, sheet: page.sheet))
        XCTAssertNil(coreName(page))
        XCTAssertGreaterThan(page.model.dirtyMarks, marks, "a cleared name armed no write")

        marks = page.model.dirtyMarks
        XCTAssertTrue(page.model.applyNoteOps(
            chip: page.chip, json: #"[{"ins":{"at":0,"text":"rotate monthly"}}]"#,
            intent: .typing, selection: nil))
        XCTAssertEqual(page.model.noteText(chip: page.chip), "rotate monthly")
        XCTAssertGreaterThan(page.model.dirtyMarks, marks, "a note edit armed no write")
    }

    // MARK: Keeping when the seat goes

    /// The object leaving the page, the page leaving the editor, and the
    /// page going read only all keep the name and shut the field.
    func testTheObjectOrItsPageLeavingKeepsTheName() throws {
        let page = try makePage()
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        editor.draft = "GONE"
        let storage = try XCTUnwrap(page.textView.textStorage)
        storage.deleteCharacters(in: NSRange(location: 3, length: 1))
        page.coordinator.followNaming()
        XCTAssertFalse(editor.isOpen, "the field outlived its object")
        XCTAssertNil(page.textView.naming)

        let second = try makePage()
        second.coordinator.beginNaming(at: 3)
        let secondEditor = try field(second)
        secondEditor.draft = "KEPT_NOT"
        second.coordinator.updateEditability(of: second.textView, to: false)
        XCTAssertFalse(secondEditor.isOpen)
        XCTAssertNil(coreName(second))
    }

    /// While the field holds the keys, the page's chords stand aside, so
    /// ⌘Z cannot step the page back under a draft.
    func testThePagesChordsStandAsideForTheField() throws {
        let page = try makePage()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = page.scroll
        page.textView.setSelectedRange(NSRange(location: 7, length: 0))
        page.textView.insertText(" more", replacementRange: NSRange(location: NSNotFound, length: 0))
        func pageInk() -> String {
            page.model.coreClient.documentRuns(sheet: page.sheet).reduce(into: "") {
                if case .ink(let ink) = $1 { $0 += ink }
            }
        }
        XCTAssertTrue(pageInk().hasSuffix("cd more"))
        XCTAssertTrue(page.model.canUndoEdit(sheet: page.sheet), "the fixture has nothing to step")
        XCTAssertFalse(page.textView.yieldsKeys)
        page.coordinator.beginNaming(at: 3)
        XCTAssertTrue(page.textView.yieldsKeys, "the field does not hold the keys")
        let undo = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        _ = page.textView.performKeyEquivalent(with: undo)
        XCTAssertTrue(pageInk().hasSuffix("cd more"), "the page stepped back under the field")
        page.coordinator.nameEditor?.keep(returningKeys: true)
        XCTAssertTrue(window.firstResponder === page.textView, "the keys did not come back")
    }

    /// A shut field keeps no draft, in the field or its editor, however
    /// it ended.
    func testAShutFieldKeepsNoDraft() throws {
        let page = try makePage()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = page.scroll
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        let fieldEditor = try XCTUnwrap(editor.field.currentEditor() as? NSTextView)
        editor.draft = "LEFT_BEHIND"
        editor.keep(returningKeys: true)
        XCTAssertEqual(editor.field.stringValue, "", "Escape left the draft in the field")
        XCTAssertEqual(fieldEditor.string, "", "Escape left the draft in its editor")

        page.coordinator.beginNaming(at: 3)
        editor.draft = "MY_KEY"
        editor.commit()
        XCTAssertEqual(coreName(page), "MY_KEY")
        XCTAssertEqual(editor.field.stringValue, "", "Return left the draft in the field")
        XCTAssertEqual(fieldEditor.string, "")

        page.coordinator.beginNaming(at: 3)
        XCTAssertEqual(editor.draft, "MY_KEY", "reopening lost the name")
        editor.draft = "GONE"
        try XCTUnwrap(page.textView.textStorage).deleteCharacters(in: NSRange(location: 3, length: 1))
        page.coordinator.followNaming()
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(editor.field.stringValue, "", "the draft outlived its object")
    }

    /// A drag from elsewhere finds nowhere to land in the field, since a
    /// seal cannot stand in a name; the draft is as it was.
    func testTheFieldTakesNoDropFromElsewhere() throws {
        let page = try makePage()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = page.scroll
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        editor.draft = "KEPT"
        let fieldEditor = try XCTUnwrap(editor.field.currentEditor() as? NSTextView)
        XCTAssertTrue(fieldEditor.allowsUndo, "the field's typing has no undo")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString("hunter2", forType: .string)
        let other = DraggingInfoStub(
            pasteboard: board, source: nil,
            location: fieldEditor.convert(NSPoint(x: 2, y: 2), to: nil), window: window)
        XCTAssertEqual(fieldEditor.draggingEntered(other), [])
        XCTAssertEqual(fieldEditor.draggingUpdated(other), [])
        XCTAssertFalse(fieldEditor.performDragOperation(other))
        XCTAssertEqual(editor.field.stringValue, "KEPT")
    }

    /// The Edit menu's actions find the field's chain, which passes the page
    /// by, Undo reaching the window's own; the menu greys the page's items.
    func testThePagesMenuActionsStandAsideForTheField() throws {
        let page = try makePage()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = page.scroll
        window.makeFirstResponder(page.textView)
        page.textView.setSelectedRange(NSRange(location: 0, length: 2))
        drainMainQueue()
        XCTAssertTrue(page.model.sealActions.canSeal, "the control: the page's selection seals")
        for action in pageMenuActions {
            XCTAssertTrue(answerer(of: action, in: window) === page.textView, "the control: \(action)")
        }

        page.coordinator.beginNaming(at: 3)
        drainMainQueue()
        XCTAssertTrue(page.textView.yieldsKeys, "the field does not hold the keys")
        for action in pageMenuActions {
            XCTAssertFalse(
                answerer(of: action, in: window) is InkTextView,
                "\(action) reached the page under the field")
        }
        XCTAssertTrue(answerer(of: #selector(EditStepResponder.undo(_:)), in: window) === window)
        XCTAssertFalse(page.model.sealActions.canSeal, "the menu offered the page's seal")
        XCTAssertFalse(page.model.languageActions.canPaste)

        page.coordinator.nameEditor?.keep(returningKeys: true)
        drainMainQueue()
        XCTAssertTrue(
            answerer(of: #selector(EditStepResponder.undo(_:)), in: window) === page.textView,
            "the page lost its own Undo once the field shut")
        XCTAssertTrue(page.model.languageActions.canPaste, "the menu did not come back to the page")
    }
}
