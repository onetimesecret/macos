import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class PadPickerTests: XCTestCase {
    private let defaultsText = """
        [{"context":"Editor","bindings":{
          "cmd-1":"page::Select1","cmd-2":"page::Select2","cmd-3":"page::Select3"
        }}]
        """

    func testPadLayerHonorsReboundAndExplicitlyRemovedDigitsIncludingScratch() {
        let keymap = Keymap.resolve(defaultText: defaultsText, overrideText: """
            [{"context":"Editor","bindings":{
              "cmd-0":null,"cmd-1":null,"cmd-2":"app::Settings"
            }}]
            """)
        XCTAssertFalse(PadShortcutMonitor.allows(number: 0, keymap: keymap))
        XCTAssertFalse(PadShortcutMonitor.allows(number: 1, keymap: keymap))
        XCTAssertFalse(PadShortcutMonitor.allows(number: 2, keymap: keymap))
        XCTAssertTrue(PadShortcutMonitor.allows(number: 3, keymap: keymap))
        let fallback = Keymap.resolve(defaultText: nil, overrideText: nil, previous: keymap)
        XCTAssertFalse(PadShortcutMonitor.allows(number: 0, keymap: fallback))
    }

    func testLaterRebindingClearsExplicitUnboundState() {
        let keymap = Keymap.resolve(defaultText: defaultsText, overrideText: """
            [{"context":"Editor","bindings":{"cmd-1":null}},
             {"context":"Editor","bindings":{"cmd-1":"page::Select1"}}]
            """)
        XCTAssertTrue(PadShortcutMonitor.allows(number: 1, keymap: keymap))
        XCTAssertTrue(PadShortcutMonitor.allows(number: 0, keymap: keymap))
    }

    func testNameValidationExplainsEmptyAndOverlongNamesWithoutTruncating() {
        for name in ["", " ", "\n\t"] {
            XCTAssertEqual(PadNameDraft.validationMessage(name), CompanionL10n.string("pad.name.empty"))
        }
        let exactLimit = String(repeating: "🐕", count: 80)
        XCTAssertNil(PadNameDraft.validationMessage("  " + exactLimit + "\n"))
        XCTAssertEqual(PadNameDraft.validationMessage(exactLimit + "x"),
                       CompanionL10n.string("pad.name.long"))
        XCTAssertNotEqual(CompanionL10n.string("pad.name.empty"), "pad.name.empty")
        XCTAssertNotEqual(CompanionL10n.string("pad.name.long"), "pad.name.long")
    }

    // MARK: The pad cell's rename field (Law 0007, issue #249)

    private func padModel() throws -> (PageModel, PadEntry) {
        let suite = "pad-rename-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        model.pads.isEnabled = true
        let id = try XCTUnwrap(model.createPad(named: "Otto"))
        return (model, try XCTUnwrap(model.pads.entries.first { $0.id == id }))
    }

    private func name(of pad: PadEntry, in model: PageModel) -> String? {
        model.pads.entries.first { $0.id == pad.id }?.name
    }

    func testReturnInTheCellRenamesThePadAndShutsTheField() throws {
        let (model, pad) = try padModel()
        var rename = PadRename()
        rename.open(pad, in: model)
        XCTAssertTrue(rename.isOpen)
        XCTAssertEqual(rename.pad, pad.id)
        XCTAssertEqual(rename.draft, "Otto", "the field did not open on the pad's name")

        rename.edit("  Otto Renamed ", in: model)
        rename.commit(in: model)
        XCTAssertEqual(name(of: pad, in: model), "Otto Renamed")
        XCTAssertFalse(rename.isOpen)
        XCTAssertNil(model.notice)
    }

    func testAnUntouchedReturnEscapeAndFocusLossKeepTheName() throws {
        let (model, pad) = try padModel()
        var rename = PadRename()
        rename.open(pad, in: model)
        rename.edit("Otto ", in: model)
        rename.commit(in: model)
        XCTAssertFalse(rename.isOpen, "an untouched Return left the field open")
        XCTAssertEqual(name(of: pad, in: model), "Otto")

        // Escape, the keyboard leaving and the list closing all end in `keep`.
        rename.open(pad, in: model)
        rename.edit("Payroll", in: model)
        rename.keep(in: model)
        XCTAssertFalse(rename.isOpen)
        XCTAssertEqual(name(of: pad, in: model), "Otto")
    }

    func testAFieldMovedToAnotherCellOutlivesTheFocusLossOfTheOneItLeft() throws {
        let (model, otto) = try padModel()
        let familiaID = try XCTUnwrap(model.createPad(named: "Familia"))
        let familia = try XCTUnwrap(model.pads.entries.first { $0.id == familiaID })
        var rename = PadRename()
        rename.open(otto, in: model)
        rename.open(familia, in: model)
        XCTAssertEqual(rename.draft, "Familia")
        rename.keep(otto.id, in: model)
        XCTAssertEqual(rename.pad, familia.id, "the cell it left shut the field it moved to")
        rename.keep(familia.id, in: model)
        XCTAssertFalse(rename.isOpen)
    }

    func testARefusalKeepsBothTheFieldAndTheLine() throws {
        let (model, pad) = try padModel()
        var rename = PadRename()
        rename.open(pad, in: model)
        rename.edit("", in: model)
        rename.commit(in: model)
        XCTAssertTrue(rename.isOpen, "an empty pad name shut the field")
        XCTAssertEqual(model.notice, CompanionL10n.string("pad.name.empty"))
        XCTAssertEqual(model.noticeTone, .actionable)
        XCTAssertEqual(name(of: pad, in: model), "Otto")

        rename.edit(String(repeating: "o", count: 81), in: model)
        XCTAssertEqual(model.notice, CompanionL10n.string("pad.name.long"), "the line kept an old refusal")
        rename.edit("Payroll", in: model)
        XCTAssertNil(model.notice, "the line still refused a draft the pad can take")
        XCTAssertTrue(rename.isOpen)

        rename.edit("", in: model)
        rename.commit(in: model)
        rename.keep(in: model)
        XCTAssertNil(model.notice, "the refusal outlived its field")
        XCTAssertEqual(name(of: pad, in: model), "Otto")
    }

    /// A keystroke over a still refused draft leaves a notice standing in
    /// front of the refusal, with its action, and the line comes back on
    /// the refusal the draft now earns.
    func testAKeystrokeUnderAFlashLeavesTheFlashStanding() throws {
        let (model, pad) = try padModel()
        var rename = PadRename()
        rename.open(pad, in: model)
        rename.edit("", in: model)
        rename.commit(in: model)
        XCTAssertEqual(model.notice, CompanionL10n.string("pad.name.empty"))
        model.flash(
            "autosave refused", tone: .actionable,
            action: PageModel.NoticeAction(label: "Retry") {})

        rename.edit(" ", in: model)
        XCTAssertEqual(model.notice, "autosave refused", "the same refusal cut the flash")
        XCTAssertNotNil(model.noticeAction, "the same refusal took the flash's Retry")
        rename.edit(String(repeating: "o", count: 81), in: model)
        XCTAssertEqual(model.notice, "autosave refused", "a new refusal cut the flash")
        XCTAssertNotNil(model.noticeAction, "a new refusal took the flash's Retry")

        model.performNoticeAction()
        XCTAssertEqual(model.notice, CompanionL10n.string("pad.name.long"))
        XCTAssertTrue(rename.isOpen)
        rename.edit("Payroll", in: model)
        XCTAssertNil(model.notice)
    }

    func testANameTheCatalogRefusesIsSaidWithTheFieldOpen() throws {
        let (model, _) = try padModel()
        let scratch = try XCTUnwrap(model.pads.entries.first { $0.isScratch })
        var rename = PadRename()
        rename.open(scratch, in: model)
        rename.edit("Notes", in: model)
        rename.commit(in: model)
        XCTAssertTrue(rename.isOpen)
        XCTAssertEqual(model.notice, CompanionL10n.string("pad.name.failed"))
        XCTAssertEqual(name(of: scratch, in: model), scratch.name)
    }

    /// The list's *Rename pad…* route: the field opens in the cell over the
    /// open list, and no step raises the create sheet or a modal session.
    func testRenamePadOpensTheCellOverTheOpenListAndRaisesNoSheet() throws {
        let (model, pad) = try padModel()
        var ends = 0
        let token = NotificationCenter.default.addObserver(
            forName: ModalSession.didEndNotification, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { ends += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        var routes = PadPickerRoutes()
        routes.listOpen = true
        func inTheCell(_ moment: String) {
            XCTAssertTrue(routes.listOpen, "the list closed \(moment)")
            XCTAssertFalse(routes.creating, "the sheet came up \(moment)")
            XCTAssertFalse(ModalSession.isRunning, "a modal session ran \(moment)")
        }

        routes.beginRename(pad, in: model)
        XCTAssertEqual(routes.rename.pad, pad.id, "the field did not open in the pad's cell")
        inTheCell("on opening")
        routes.rename.edit("", in: model)
        routes.rename.commit(in: model)
        inTheCell("on a refusal")
        routes.rename.edit("Payroll", in: model)
        routes.rename.commit(in: model)
        inTheCell("on a commit")
        XCTAssertEqual(name(of: pad, in: model), "Payroll")
        XCTAssertEqual(ends, 0)
    }

    /// *New pad…* is the one route to the sheet, and it shuts the list,
    /// keeping the name under any field that was open.
    func testNewPadShutsTheListAndKeepsAnOpenFieldsName() throws {
        let (model, pad) = try padModel()
        var routes = PadPickerRoutes()
        routes.listOpen = true
        routes.beginRename(pad, in: model)
        routes.rename.edit("", in: model)
        routes.rename.commit(in: model)
        XCTAssertNotNil(model.notice)

        routes.beginCreating(in: model)
        XCTAssertTrue(routes.creating)
        XCTAssertFalse(routes.listOpen)
        XCTAssertFalse(routes.rename.isOpen, "the field outlived the list")
        XCTAssertNil(model.notice, "the refusal outlived its field")
        XCTAssertEqual(name(of: pad, in: model), "Otto")
    }

    func testTheRenameSheetsStringsAreGoneAndTheCreateSheetsStay() {
        for key in ["pad.rename.title", "pad.rename"] {
            XCTAssertEqual(CompanionL10n.string(key), key, "\(key) is still in the strings")
        }
        for key in ["pad.cancel", "pad.name", "pad.new.title", "pad.create", "pad.rename.menu"] {
            XCTAssertNotEqual(CompanionL10n.string(key), key, "\(key) went with the rename sheet")
        }
    }

    func testPadShortcutsYieldToSheetAttachedToAnotherWindow() {
        _ = NSApplication.shared
        let windows = (0..<3).map { _ in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        let parent = windows[0], other = windows[1], sheet = windows[2]
        defer {
            if parent.attachedSheet === sheet { parent.endSheet(sheet) }
            windows.forEach { $0.orderOut(nil); $0.close() }
        }
        XCTAssertTrue(PadShortcutMonitor.allowsPadSwitch(isModal: false, windows: [parent, other]))
        XCTAssertFalse(PadShortcutMonitor.allowsPadSwitch(isModal: true, windows: [parent, other]))
        parent.beginSheet(sheet)
        XCTAssertFalse(parent.isKeyWindow)
        XCTAssertTrue(parent.attachedSheet === sheet)
        XCTAssertTrue(sheet.sheetParent === parent)
        // The other window has no sheet; inspecting only that window would
        // incorrectly allow a shortcut to change the shared pad selection.
        XCTAssertNil(other.attachedSheet)
        XCTAssertNil(other.sheetParent)
        XCTAssertTrue(PadShortcutMonitor.allowsPadSwitch(isModal: false, windows: [other]))
        XCTAssertFalse(PadShortcutMonitor.allowsPadSwitch(isModal: false, windows: [parent, other]))
        XCTAssertFalse(PadShortcutMonitor.allowsPadSwitch(isModal: false, windows: [other, sheet]))
        parent.endSheet(sheet)
        XCTAssertTrue(PadShortcutMonitor.allowsPadSwitch(isModal: false, windows: [parent, other]))
    }

    func testSortAccessibilitySeparatesCurrentOrderFromNextAction() {
        let oldest = PadSortCopy(direction: .chronological, subject: "days")
        XCTAssertEqual(oldest.label, "days sort order")
        XCTAssertEqual(oldest.currentOrder, "Oldest first")
        XCTAssertEqual(oldest.action, "Activate to sort days newest first")
        let newest = PadSortCopy(direction: .reverseChronological, subject: "today checkpoints")
        XCTAssertEqual(newest.currentOrder, "Newest first")
        XCTAssertEqual(newest.action, "Activate to sort today checkpoints oldest first")
    }

    func testExperimentalRailWidthAndLayoutDisclosureUseSameMeasure() {
        XCTAssertEqual(TimeRailView.width(experimental: false), 110)
        XCTAssertEqual(TimeRailView.width(experimental: true), 150)
        XCTAssertEqual(TimeRailView.width, TimeRailView.width(experimental: false))
        XCTAssertTrue(GeneralSettingsView.pageLayoutCaption(experimental: false).contains("110 points"))
        XCTAssertTrue(GeneralSettingsView.pageLayoutCaption(experimental: true).contains("150 points"))
    }

    func testPadLocalizedFormatsKeepNamesAndPathsLiteral() {
        XCTAssertEqual(CompanionL10n.format("pad.picker.current", "Familia 100%"),
                       "Choose pad, current pad Familia 100%")
        XCTAssertEqual(CompanionL10n.format("pad.folder.remove", "/tmp/%@", "Dog Jokes"),
                       "Remove /tmp/%@ from Dog Jokes")
        XCTAssertEqual(CompanionL10n.format("pad.folder.one", 1), "1 folder")
        XCTAssertEqual(CompanionL10n.format("pad.folder.many", 2), "2 folders")
    }

    func testNativeRollAndRailFollowSameSortedActivePadProjection() throws {
        let suite = "pad-picker-ui-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        model.showsTimeUnits = true
        model.pads.isEnabled = true
        // The existing Scratch page must not leak into the named pad's roll.
        let otherPadPages = Set(model.navigationTabs.compactMap(\.pageID))
        let namedPad = try XCTUnwrap(model.createPad(named: "Familia"))
        model.activatePad(namedPad)
        for text in ["First checkpoint", "Second checkpoint", "Third checkpoint"] {
            model.newPage()
            let page = try XCTUnwrap(model.selectedPageID)
            XCTAssertTrue(model.coreClient.syncDocument(sheet: page, json: "[{\"ink\":\"\(text)\"}]"))
            model.refresh()
        }
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = DayScrollView.makeRoll(model: model, coordinator: coordinator, emptyHint: "Start writing")
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        let chronological = model.timeUnits.units.flatMap(\.pageIDs)
        XCTAssertEqual(chronological.count, 3)
        XCTAssertTrue(otherPadPages.isDisjoint(with: chronological))
        stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
        XCTAssertEqual(stack.laidOut.compactMap { $0.header.pageIdentity }, chronological)
        XCTAssertEqual(stack.laidOut.first?.header.mark, .hairline)
        model.toggleCheckpointSort(dayBucket: 0)
        stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
        let nodes = StreamNavigator.nodes(projection: model.timeUnits, tabs: model.navigationTabs,
            selection: model.selection, surfaceShowsRoll: true, stampFormat: model.stampFormat)
        XCTAssertEqual(nodes.compactMap(\.page), Array(chronological.reversed()))
        XCTAssertEqual(stack.laidOut.compactMap { $0.header.pageIdentity }, nodes.compactMap(\.page))
        XCTAssertEqual(Set(nodes.compactMap(\.tab)).count, nodes.count)
        coordinator.leavePage(try XCTUnwrap(stack.editor), scrollView: nil)
    }
}
