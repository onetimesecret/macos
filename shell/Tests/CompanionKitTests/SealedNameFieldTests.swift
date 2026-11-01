import AppKit
import XCTest

@testable import CompanionKit

/// A sealed object's name, edited in the name's seat (Law 0007; ADR-0042 point 1;
/// Law 0001, name zone row), against the live core through an isolated model.
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
    private func makePage(width: CGFloat = 520) throws -> Page {
        let suite = "companion-sealed-name-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let sheet = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: sheet, coordinator: coordinator))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
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

    func testSealedNameAndActionLocalizationKeysResolve() {
        let expected = [
            "chip.name.field": "Variable name",
            "chip.name.long": "use 64 characters or fewer for the variable name",
            "chip.name.charset": "use A–Z, a–z, digits and underscores, starting with a letter or underscore",
            "chip.name.title": "variable name · e.g. API_KEY",
            "chip.name.hint": "Return saves · Esc cancels",
            "chip.name.save": "Save",
            "chip.name.cancel": "Cancel",
            "chip.name.failed": "the variable name could not be saved; try again",
            "chip.menu.copy_reference": "Copy Sealed Reference",
            "chip.menu.copy_decrypted": "Copy Decrypted Contents",
            "chip.control.copy": "Copy Decrypted",
            "chip.handle.decrypted": "Copy Decrypted Contents",
        ]
        for (key, value) in expected {
            XCTAssertEqual(CompanionL10n.string(key), value, "unresolved or stale key: \(key)")
        }
        for key in [
            "chip.name.help", "chip.name.field.help", "chip.name.save.help", "chip.name.cancel.help",
            "chip.menu.copy_name", "chip.menu.copy_name_value", "chip.menu.create_link", "chip.menu.name",
            "chip.menu.rename", "chip.menu.note", "chip.menu.edit_note", "chip.menu.remove",
            "chip.menu.copy_reference.help", "chip.menu.copy_decrypted.help", "chip.menu.copy_name_value.help",
            "chip.control.copied", "chip.control.note", "chip.control.move.help", "chip.control.copy.help",
            "chip.control.actions.help", "chip.control.note.help", "chip.status.classification",
            "chip.status.text", "chip.status.image", "chip.status.elsewhere", "chip.status.has_note",
            "chip.accessibility.actions", "chip.accessibility.note", "chip.accessibility.note_presence",
        ] {
            XCTAssertNotEqual(CompanionL10n.string(key), key)
        }
        XCTAssertEqual(CompanionL10n.format("chip.status.has_note", "sealed text"), "sealed text · has note")
        let helper = SealedNameHelpView()
        XCTAssertEqual(helper.help.stringValue, CompanionL10n.string("chip.name.help"))
        XCTAssertEqual(helper.save.accessibilityHelp(), CompanionL10n.string("chip.name.save.help"))
        XCTAssertEqual(helper.cancel.accessibilityHelp(), CompanionL10n.string("chip.name.cancel.help"))
    }

    func testNamingHelpKeepsItsControlsInsideVeryNarrowAndWideBounds() {
        let helper = SealedNameHelpView()
        for width in [CGFloat(1), 7, 40, 80, 120, 149, 244, 440] {
            for message in ["", ChipRename.words(for: .outsideCharset)] {
                helper.error.stringValue = message
                helper.frame = NSRect(x: 0, y: 0, width: width, height: helper.preferredHeight(width: width))
                helper.layout()
                for view in helper.subviews where !view.isHidden {
                    XCTAssertGreaterThanOrEqual(view.frame.minX, helper.bounds.minX)
                    XCTAssertGreaterThanOrEqual(view.frame.minY, helper.bounds.minY)
                    XCTAssertLessThanOrEqual(view.frame.maxX, helper.bounds.maxX)
                    XCTAssertLessThanOrEqual(view.frame.maxY, helper.bounds.maxY)
                    XCTAssertGreaterThanOrEqual(view.frame.width, 0)
                    XCTAssertGreaterThanOrEqual(view.frame.height, 0)
                }
                XCTAssertFalse(helper.hint.frame.intersects(helper.save.frame))
                XCTAssertFalse(helper.hint.frame.intersects(helper.cancel.frame))
                XCTAssertFalse(helper.save.frame.intersects(helper.cancel.frame))
                if width < 244 {
                    XCTAssertLessThanOrEqual(helper.hint.frame.maxY, helper.cancel.frame.minY)
                } else {
                    XCTAssertGreaterThanOrEqual(helper.hint.frame.width, helper.hint.intrinsicContentSize.width)
                }
                if width < 140 {
                    XCTAssertLessThan(helper.cancel.frame.maxY, helper.save.frame.minY)
                } else if width == 440 {
                    XCTAssertEqual(helper.hint.frame.midY, helper.cancel.frame.midY)
                }
            }
        }
    }

    func testNamingHelpFitsLongerButtonTitlesAtNarrowWidths() {
        let helper = SealedNameHelpView()
        helper.save.title = "Save Variable Name"
        helper.cancel.title = "Discard This Draft"
        for width in [CGFloat(180), 244, 440] {
            helper.frame = NSRect(x: 0, y: 0, width: width, height: helper.preferredHeight(width: width))
            helper.layout()
            for button in [helper.save, helper.cancel] {
                XCTAssertTrue(helper.bounds.contains(button.frame))
                XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width)
            }
            XCTAssertFalse(helper.save.frame.intersects(helper.cancel.frame))
            XCTAssertFalse(helper.hint.frame.intersects(helper.save.frame))
            XCTAssertFalse(helper.hint.frame.intersects(helper.cancel.frame))
        }
    }

    func testShortViewportClipsNamingHelpWithoutCoveringTheDraft() throws {
        for width in [CGFloat(260), 520] {
            let page = try makePage(width: width)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 140),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page.scroll
            defer { window.close() }
            page.scroll.frame.size.height = 140
            page.scroll.layoutSubtreeIfNeeded()
            page.coordinator.beginNaming(at: 3)
            let editor = try field(page)
            editor.draft = "invalid.name"
            XCTAssertFalse(editor.commit(returningKeys: false))
            editor.helpView.layoutSubtreeIfNeeded()
            let fieldFrame = editor.field.convert(editor.field.bounds, to: editor.overlay)
            XCTAssertFalse(editor.helpScroll.isHidden)
            XCTAssertFalse(editor.helpScroll.frame.intersects(fieldFrame))
            XCTAssertTrue(editor.overlay.bounds.contains(editor.helpScroll.frame))
            XCTAssertLessThan(editor.helpScroll.contentSize.height, editor.helpView.frame.height)

            let fieldPoint = editor.field.convert(
                NSPoint(x: editor.field.bounds.midX, y: editor.field.bounds.midY), to: page.scroll)
            XCTAssertNil(editor.overlay.hitTest(fieldPoint), "the helper intercepted a draft click")
            let actions = editor.helpView.save.frame.union(editor.helpView.cancel.frame)
            editor.helpView.scrollToVisible(actions)
            XCTAssertTrue(editor.helpView.visibleRect.intersects(editor.helpView.save.frame))
            XCTAssertTrue(editor.helpView.visibleRect.intersects(editor.helpView.cancel.frame))
            editor.helpView.cancel.performClick(nil)
            XCTAssertFalse(editor.isOpen)
        }
    }

    func testRenderNamingPreviewsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["ONETIMEPAD_SEALED_PREVIEW_DIR"] else {
            throw XCTSkip("set ONETIMEPAD_SEALED_PREVIEW_DIR to render synthetic naming previews")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let original = InkStyle.typeface
        defer { InkStyle.typeface = original }
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width in [CGFloat(260), 680] {
                let page = try makePage(width: width)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = page.scroll
                window.appearance = NSAppearance(named: appearance)
                page.scroll.appearance = window.appearance
                page.textView.appearance = window.appearance
                page.textView.drawsBackground = true
                page.textView.backgroundColor = .windowBackgroundColor
                page.model.fontSize = 13
                page.coordinator.applyTypeface(page.model.typeface)
                page.textView.layoutManager?.ensureLayout(for: try XCTUnwrap(page.textView.textContainer))
                page.coordinator.beginNaming(at: 3)
                let editor = try field(page)
                for error in [false, true] {
                    editor.draft = error ? "my.key" : "API_KEY"
                    if error { editor.commit() }
                    page.scroll.layoutSubtreeIfNeeded()
                    let capture = page.scroll.bounds
                    let rep = try XCTUnwrap(page.scroll.bitmapImageRepForCachingDisplay(in: capture))
                    page.scroll.cacheDisplay(in: capture, to: rep)
                    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    let name = "name-\(appearanceName)-\(Int(width))w-\(error ? "error" : "valid").png"
                    try data.write(to: output.appendingPathComponent(name))
                }
                editor.keep(returningKeys: false)
            }
        }
    }

    // MARK: Opening

    /// Naming opens beside its item with an example, format help and visible endings.
    func testTheFieldOpensWithItsVariableNameInstructionsAndActions() throws {
        let page = try makePage()
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        XCTAssertTrue(editor.isOpen)
        XCTAssertEqual(editor.draft, "", "an unnamed object's field opens on nothing")
        XCTAssertEqual(editor.field.placeholderAttributedString?.string, "API_KEY")
        XCTAssertEqual(editor.field.accessibilityLabel(), "Variable name")
        XCTAssertTrue(editor.field.superview === page.textView, "the field is not in the seat")
        let frame = try XCTUnwrap(page.textView.chipFrame(at: 3))
        let layout = SealedBlockCell.contentLayout(in: frame)
        XCTAssertEqual(
            editor.field.frame.minX, layout.left - SealedNameEditor.textInset, accuracy: 0.5)
        XCTAssertTrue(layout.rowBand.contains(NSPoint(
            x: editor.field.frame.midX, y: editor.field.frame.midY)))
        let naming = try XCTUnwrap(page.textView.naming)
        XCTAssertEqual(naming.chip, page.chip)
        XCTAssertTrue(editor.overlay.superview === page.scroll)
        XCTAssertEqual(editor.helpView.title.stringValue, CompanionL10n.string("chip.name.title"))
        XCTAssertTrue(editor.helpView.help.stringValue.contains("64"))
        XCTAssertEqual(editor.helpView.hint.stringValue, "Return saves · Esc cancels")
        XCTAssertEqual(editor.helpView.save.title, "Save")
        XCTAssertEqual(editor.helpView.cancel.title, "Cancel")

        editor.keep(returningKeys: false)
        XCTAssertTrue(page.model.setChipName("DB_PASSWORD", chip: page.chip, sheet: page.sheet))
        page.coordinator.beginNaming(at: 3)
        XCTAssertEqual(editor.draft, "DB_PASSWORD", "a named object's field opens on its name")
    }

    /// Naming actions explain that the format is a variable name.
    func testTheMenusVerbOpensTheField() throws {
        let page = try makePage()
        let unnamed = try XCTUnwrap(page.coordinator.chipMenu(at: 3))
        let verb = try XCTUnwrap(unnamed.items.first { $0.title == "Set Variable Name…" })
        XCTAssertFalse(unnamed.items.contains { $0.title == "Edit Variable Name…" })
        _ = (verb.target as? NSObject)?.perform(verb.action, with: verb)
        XCTAssertEqual(page.coordinator.nameEditor?.isOpen, true)
        page.coordinator.nameEditor?.keep(returningKeys: true)

        XCTAssertTrue(page.model.setChipName("DB_PASSWORD", chip: page.chip, sheet: page.sheet))
        let named = try XCTUnwrap(page.coordinator.chipMenu(at: 3))
        XCTAssertNotNil(named.items.first { $0.title == "Edit Variable Name…" })
        XCTAssertFalse(named.items.contains { $0.title == "Set Variable Name…" })
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

    /// Cancel keeps the old name; focus loss saves; empty saves remove it.
    func testCancelKeepsWhileFocusLossAndReturnSave() throws {
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
        XCTAssertEqual(coreName(page), "OTHER", "a valid focus-loss draft was discarded")

        page.coordinator.beginNaming(at: 3)
        editor.commit()
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(coreName(page), "OTHER")

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

    /// Invalid names stay open with local feedback, independent of the shared footer.
    func testARefusalStaysBesideTheFieldAndUpdatesAsTheDraftChanges() throws {
        let page = try makePage()
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        let originalNotice = page.model.notice
        editor.draft = "my.key"
        editor.commit()

        XCTAssertTrue(editor.isOpen, "a refusal shut the field")
        XCTAssertTrue(editor.rename.isRefusing)
        XCTAssertEqual(editor.helpView.error.stringValue, ChipRename.words(for: .outsideCharset))
        XCTAssertEqual(page.model.notice, originalNotice)
        XCTAssertNil(coreName(page))
        page.model.flash("a passing line")
        XCTAssertEqual(page.model.notice, "a passing line")

        editor.draft = String(repeating: "A", count: 65)
        XCTAssertEqual(page.model.notice, "a passing line")
        XCTAssertEqual(editor.helpView.error.stringValue, ChipRename.words(for: .tooLong))
        editor.draft = "MY_KEY"
        XCTAssertFalse(editor.rename.isRefusing)
        XCTAssertEqual(editor.helpView.error.stringValue, "")
        XCTAssertEqual(page.model.notice, "a passing line")
        editor.commit()
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(coreName(page), "MY_KEY")
    }

    func testTheRefusalsWordsAreTheFieldsOwn() {
        XCTAssertEqual(
            ChipRename.words(for: .tooLong), CompanionL10n.string("chip.name.long"))
        XCTAssertEqual(
            ChipRename.words(for: .outsideCharset),
            CompanionL10n.string("chip.name.charset")
        )
    }

    func testAnInvalidFocusLossKeepsTheDraftOpenForCorrection() throws {
        let page = try makePage()
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        editor.draft = "my.key"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        XCTAssertTrue(editor.isOpen)
        XCTAssertEqual(editor.draft, "my.key")
        XCTAssertFalse(editor.helpView.error.stringValue.isEmpty)
        XCTAssertNil(coreName(page))
        editor.draft = "MY_KEY"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(coreName(page), "MY_KEY")
    }

    private func hostNameEditor(_ page: Page) -> NSWindow {
        let window = NSWindow(contentRect: page.scroll.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.scroll
        return window
    }

    private func typeInvalidName(in editor: SealedNameEditor) throws {
        let input = try XCTUnwrap(editor.field.currentEditor() as? NSTextView)
        input.insertText("my.key", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
    }

    func testInvalidBlurDefersRefocusAndKeepsTheDraftEditable() throws {
        let page = try makePage()
        let window = hostNameEditor(page)
        defer { window.close() }
        let originalKeyWindow = NSApp?.keyWindow
        let originallyActive = NSApp?.isActive
        let originallyKey = window.isKeyWindow
        let originallyVisible = window.isVisible
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        try typeInvalidName(in: editor)

        XCTAssertTrue(window.makeFirstResponder(page.textView))
        XCTAssertTrue(window.firstResponder === page.textView, "refocus ran inside a responder transition")
        XCTAssertTrue(editor.isOpen)
        XCTAssertTrue(editor.rename.isRefusing)
        drainMainQueue()
        XCTAssertTrue(editor.holdsKeys)
        XCTAssertEqual(editor.draft, "my.key")
        XCTAssertEqual(editor.rename.error, ChipRename.words(for: .outsideCharset))
        XCTAssertNil(coreName(page))
        XCTAssertTrue(NSApp?.keyWindow === originalKeyWindow)
        XCTAssertEqual(NSApp?.isActive, originallyActive)
        XCTAssertEqual(window.isKeyWindow, originallyKey)
        XCTAssertEqual(window.isVisible, originallyVisible)

        let input = try XCTUnwrap(editor.field.currentEditor() as? NSTextView)
        input.insertText("MY_KEY", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        XCTAssertTrue(window.makeFirstResponder(page.textView))
        drainMainQueue()
        XCTAssertFalse(editor.isOpen)
        XCTAssertTrue(window.firstResponder === page.textView)
        XCTAssertEqual(coreName(page), "MY_KEY")
    }

    func testCancelInvalidatesPendingInvalidDraftRefocus() throws {
        let page = try makePage()
        let window = hostNameEditor(page)
        defer { window.close() }
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        try typeInvalidName(in: editor)
        XCTAssertTrue(window.makeFirstResponder(page.textView))
        XCTAssertTrue(editor.rename.isRefusing)
        editor.helpView.cancel.performClick(nil)
        drainMainQueue()
        XCTAssertFalse(editor.isOpen)
        XCTAssertFalse(editor.holdsKeys)
        XCTAssertTrue(editor.field.isHidden)
        XCTAssertNil(editor.overlay.superview)
        XCTAssertTrue(window.firstResponder === page.textView)
        XCTAssertNil(coreName(page))
    }

    func testWindowTeardownInvalidatesPendingInvalidDraftRefocus() throws {
        let page = try makePage()
        let window = hostNameEditor(page)
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        try typeInvalidName(in: editor)
        XCTAssertTrue(window.makeFirstResponder(page.textView))
        XCTAssertTrue(editor.rename.isRefusing)
        window.close()
        drainMainQueue()
        XCTAssertFalse(editor.isOpen)
        XCTAssertFalse(editor.holdsKeys)
        XCTAssertTrue(editor.field.isHidden)
        XCTAssertNil(editor.overlay.superview)
        XCTAssertNil(coreName(page))
    }

    func testWindowTeardownSavesAValidPendingDraft() throws {
        let page = try makePage()
        let window = hostNameEditor(page)
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        let input = try XCTUnwrap(editor.field.currentEditor() as? NSTextView)
        input.insertText("API_KEY", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        XCTAssertTrue(editor.holdsKeys)
        window.close()
        drainMainQueue()
        XCTAssertFalse(editor.isOpen)
        XCTAssertTrue(editor.field.isHidden)
        XCTAssertNil(editor.overlay.superview)
        XCTAssertEqual(coreName(page), "API_KEY")
    }

    func testFocusingAnInvalidDraftRestoresItsFieldWithoutChangingIt() throws {
        let page = try makePage()
        let window = NSWindow(contentRect: page.scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.scroll
        defer { window.close() }
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        editor.draft = "my.key"
        editor.commit()
        XCTAssertTrue(window.makeFirstResponder(page.textView))
        XCTAssertFalse(editor.holdsKeys)
        XCTAssertTrue(editor.focusDraft())
        XCTAssertTrue(editor.holdsKeys)
        XCTAssertEqual(editor.draft, "my.key")
        XCTAssertEqual(editor.rename.error, CompanionL10n.string("chip.name.charset"))
        XCTAssertNil(coreName(page))
    }

    private final class NameRefusingClient: CompanionClient, @unchecked Sendable {
        init(tag: String) { super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag)) }
        override func setChipName(_ name: String, chip: UInt64) -> Bool { false }
    }

    func testANameWriteRefusalDoesNotCallAnExistingItemUnavailable() throws {
        let suite = "sealed-name-refusal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let client = NameRefusingClient(tag: suite)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let model = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: client, clearClipboardIfOurs: { false }))
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let chip = try XCTUnwrap(client.sealText(sheet: page, "synthetic value", at: 0, length: 0))
        var rename = ChipRename()
        rename.open(chip: chip.chipId, sheet: page, name: nil, in: model)
        rename.edit("API_KEY", in: model)
        XCTAssertFalse(rename.commit(in: model))
        XCTAssertTrue(client.chipStands(chip.chipId))
        XCTAssertTrue(rename.isOpen)
        XCTAssertEqual(rename.draft, "API_KEY")
        XCTAssertEqual(rename.error, CompanionL10n.string("chip.name.failed"))
    }

    func testTheVisibleSaveAndCancelButtonsEndTheEdit() throws {
        let page = try makePage()
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        editor.draft = "API_KEY"
        editor.helpView.save.performClick(nil)
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(coreName(page), "API_KEY")
        XCTAssertNil(editor.overlay.superview)

        page.coordinator.beginNaming(at: 3)
        editor.draft = "OTHER_KEY"
        editor.helpView.cancel.performClick(nil)
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(coreName(page), "API_KEY")
        XCTAssertEqual(editor.field.stringValue, "")
        XCTAssertNil(editor.overlay.superview)
    }

    // MARK: The write a name arms (core interface, The name)

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

    /// A removed object cancels its draft; a mounted page losing editability saves it.
    func testRemovalCancelsWhileLosingEditabilitySavesTheName() throws {
        let page = try makePage()
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        editor.draft = "GONE"
        let storage = try XCTUnwrap(page.textView.textStorage)
        storage.deleteCharacters(in: NSRange(location: 3, length: 1))
        page.coordinator.finishNaming()
        XCTAssertFalse(editor.isOpen, "the field outlived its object")
        XCTAssertNil(page.textView.naming)
        XCTAssertNil(coreName(page), "teardown named an object removed from the mounted document")

        let second = try makePage()
        second.coordinator.beginNaming(at: 3)
        let secondEditor = try field(second)
        secondEditor.draft = "SAVED_NAME"
        second.coordinator.updateEditability(of: second.textView, to: false)
        XCTAssertFalse(secondEditor.isOpen)
        XCTAssertEqual(coreName(second), "SAVED_NAME")
        XCTAssertFalse(second.textView.isEditable)
    }

    func testLeavingThePageSavesAValidNameBeforeDetachingItsStorage() throws {
        let page = try makePage()
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        editor.draft = "SAVED_NAME"
        page.coordinator.leavePage(page.textView, scrollView: page.scroll)
        XCTAssertEqual(coreName(page), "SAVED_NAME")
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(editor.field.stringValue, "")
        XCTAssertNil(editor.overlay.superview)
        XCTAssertEqual(page.textView.string, "")
        XCTAssertFalse(page.textView.isEditable)
    }

    func testTeardownClosesInvalidDraftsWithoutChangingTheName() throws {
        for leavePage in [false, true] {
            let page = try makePage()
            XCTAssertTrue(page.model.setChipName("API_KEY", chip: page.chip, sheet: page.sheet))
            page.coordinator.beginNaming(at: 3)
            let editor = try field(page)
            editor.draft = "invalid.name"
            if leavePage {
                page.coordinator.leavePage(page.textView, scrollView: page.scroll)
            } else {
                page.coordinator.updateEditability(of: page.textView, to: false)
            }
            XCTAssertEqual(coreName(page), "API_KEY")
            XCTAssertFalse(editor.isOpen)
            XCTAssertEqual(editor.field.stringValue, "")
            XCTAssertNil(editor.overlay.superview)
        }
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
    func testFinishingAnOwnedDraftLeavesTheEditorsKeyboardUsable() throws {
        let page = try makePage()
        let window = NSWindow(contentRect: page.scroll.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.scroll
        defer { window.close() }
        page.coordinator.beginNaming(at: 3)
        let editor = try field(page)
        editor.draft = "SAVED_NAME"
        XCTAssertTrue(editor.holdsKeys)
        page.coordinator.finishNaming()
        XCTAssertEqual(coreName(page), "SAVED_NAME")
        XCTAssertTrue(window.firstResponder === page.textView)
        XCTAssertTrue(page.textView.answersChords)
    }

}
