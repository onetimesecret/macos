import AppKit
import SwiftUI
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

    // MARK: The pad row's rename field (Law 0007, issue #249)

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

    func testReturnInTheRowRenamesThePadAndShutsTheField() throws {
        let (model, pad) = try padModel()
        var rename = PadRename()
        rename.open(pad)
        XCTAssertTrue(rename.isOpen)
        XCTAssertEqual(rename.pad, pad.id)
        XCTAssertEqual(rename.draft, "Otto", "the field did not open on the pad's name")

        rename.edit("  Otto Renamed ")
        rename.commit(in: model)
        XCTAssertEqual(name(of: pad, in: model), "Otto Renamed")
        XCTAssertFalse(rename.isOpen)
        XCTAssertNil(rename.refusal)
    }

    func testAnUntouchedReturnEscapeAndFocusLossKeepTheName() throws {
        let (model, pad) = try padModel()
        var rename = PadRename()
        rename.open(pad)
        rename.edit("Otto ")
        rename.commit(in: model)
        XCTAssertFalse(rename.isOpen, "an untouched Return left the field open")
        XCTAssertEqual(name(of: pad, in: model), "Otto")

        // Escape, the keyboard leaving and the tab closing all end in `keep`.
        rename.open(pad)
        rename.edit("Payroll")
        rename.keep()
        XCTAssertFalse(rename.isOpen)
        XCTAssertEqual(name(of: pad, in: model), "Otto")
    }

    func testAFieldMovedToAnotherRowOutlivesTheFocusLossOfTheOneItLeft() throws {
        let (model, otto) = try padModel()
        let familiaID = try XCTUnwrap(model.createPad(named: "Familia"))
        let familia = try XCTUnwrap(model.pads.entries.first { $0.id == familiaID })
        var rename = PadRename()
        rename.open(otto)
        rename.open(familia)
        XCTAssertEqual(rename.draft, "Familia")
        rename.keep(otto.id)
        XCTAssertEqual(rename.pad, familia.id, "the row it left shut the field it moved to")
        rename.keep(familia.id)
        XCTAssertFalse(rename.isOpen)
    }

    /// A refusal is said under the field, in the pad's row, with the field
    /// open; nothing is said under a page, which stands in another window.
    func testARefusalIsSaidUnderTheFieldWithTheFieldOpen() throws {
        let (model, pad) = try padModel()
        var rename = PadRename()
        rename.open(pad)
        rename.edit("")
        rename.commit(in: model)
        XCTAssertTrue(rename.isOpen, "an empty pad name shut the field")
        XCTAssertEqual(rename.refusal, CompanionL10n.string("pad.name.empty"))
        XCTAssertNil(model.notice, "the refusal went to the line under the page")
        XCTAssertEqual(name(of: pad, in: model), "Otto")

        rename.edit(String(repeating: "o", count: 81))
        XCTAssertEqual(rename.refusal, CompanionL10n.string("pad.name.long"), "the field kept an old refusal")
        rename.edit("Payroll")
        XCTAssertNil(rename.refusal, "the field still refused a draft the pad can take")
        XCTAssertTrue(rename.isOpen)

        rename.edit("")
        rename.commit(in: model)
        rename.keep()
        XCTAssertNil(rename.refusal, "the refusal outlived its field")
        XCTAssertEqual(name(of: pad, in: model), "Otto")
    }

    func testANameTheCatalogRefusesIsSaidWithTheFieldOpen() throws {
        let (model, _) = try padModel()
        let scratch = try XCTUnwrap(model.pads.entries.first { $0.isScratch })
        var rename = PadRename()
        rename.open(scratch)
        rename.edit("Notes")
        rename.commit(in: model)
        XCTAssertTrue(rename.isOpen)
        XCTAssertEqual(rename.refusal, CompanionL10n.string("pad.name.failed"))
        XCTAssertEqual(name(of: scratch, in: model), scratch.name)
    }

    /// The Pads tab's *Rename* route: the field opens in the row, and no
    /// step raises the create sheet or a modal session.
    func testRenameOpensTheFieldInTheRowAndRaisesNoSheet() throws {
        let (model, pad) = try padModel()
        var ends = 0
        let token = NotificationCenter.default.addObserver(
            forName: ModalSession.didEndNotification, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { ends += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        var routes = PadSettingsRoutes()
        func inTheRow(_ moment: String) {
            XCTAssertFalse(routes.creating, "the sheet came up \(moment)")
            XCTAssertFalse(ModalSession.isRunning, "a modal session ran \(moment)")
        }

        routes.beginRename(pad)
        XCTAssertEqual(routes.rename.pad, pad.id, "the field did not open in the pad's row")
        inTheRow("on opening")
        routes.rename.edit("")
        routes.rename.commit(in: model)
        inTheRow("on a refusal")
        routes.rename.edit("Payroll")
        routes.rename.commit(in: model)
        inTheRow("on a commit")
        XCTAssertEqual(name(of: pad, in: model), "Payroll")
        XCTAssertEqual(ends, 0)
    }

    /// *New Pad…* is the one route to the sheet, and it keeps the name
    /// under any field that was open.
    func testNewPadRaisesTheSheetAndKeepsAnOpenFieldsName() throws {
        let (model, pad) = try padModel()
        var routes = PadSettingsRoutes()
        routes.beginRename(pad)
        routes.rename.edit("")
        routes.rename.commit(in: model)
        XCTAssertNotNil(routes.rename.refusal)

        routes.beginCreating()
        XCTAssertTrue(routes.creating)
        XCTAssertFalse(routes.rename.isOpen, "the field outlived the sheet's arrival")
        XCTAssertNil(routes.rename.refusal, "the refusal outlived its field")
        XCTAssertEqual(name(of: pad, in: model), "Otto")
    }

    // MARK: The switcher's menu (ADR-0039 Amendment 1)

    /// Each pad once, in the catalog's order, the active one checked and a
    /// digit beside each pad the keymap leaves its digit to.
    func testTheSwitcherListsEachPadWithItsCheckAndItsDigit() throws {
        let (model, otto) = try padModel()
        let keymap = Keymap.resolve(defaultText: defaultsText, overrideText: """
            [{"context":"Editor","bindings":{"cmd-1":null}}]
            """)
        let entries = PadSwitcherMenu.entries(
            pads: model.pads.entries, activeID: otto.id, keymap: keymap)
        XCTAssertEqual(entries.map(\.id), model.pads.entries.map(\.id))
        XCTAssertEqual(entries.filter(\.checked).map(\.id), [otto.id])
        XCTAssertEqual(entries.first?.digit, 0, "Scratch lost ⌘0")
        XCTAssertEqual(entries.dropFirst().first?.digit, nil, "an unbound ⌘1 still labels a pad")
    }

    /// The menu draws the check in its leading column and the digit in the
    /// shortcut column, and ends in New Pad… and Manage Pads….
    func testTheSwitcherMenuEndsInNewPadAndManagePads() {
        let first = UUID(), second = UUID()
        var picked: UUID?
        var managed = false
        let menu = PadSwitcherMenu.menu(
            entries: [
                .init(id: first, name: "Scratch", checked: false, digit: 0),
                .init(id: second, name: "Otto", checked: true, digit: nil),
            ],
            select: { picked = $0 }, newPad: {}, manage: { managed = true })
        XCTAssertEqual(
            menu.items.map { $0.isSeparatorItem ? nil : $0.title },
            ["Scratch", "Otto", nil, "New Pad…", "Manage Pads…"])
        XCTAssertEqual(menu.items[0].keyEquivalent, "0")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, .command)
        XCTAssertEqual(menu.items[1].keyEquivalent, "")
        XCTAssertEqual(menu.items.map(\.state), [.off, .on, .off, .off, .off])
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 4)
        XCTAssertEqual(picked, second)
        XCTAssertTrue(managed)
    }

    func testTheRenameSheetsStringsAreGoneAndTheCreateSheetsStay() {
        for key in ["pad.rename.title", "pad.rename"] {
            XCTAssertEqual(CompanionL10n.string(key), key, "\(key) is still in the strings")
        }
        for key in ["pad.cancel", "pad.name", "pad.new.title", "pad.create", "pad.rename.menu"] {
            XCTAssertNotEqual(CompanionL10n.string(key), key, "\(key) went with the rename sheet")
        }
    }

    /// Section headings are title case, as sidebar sections are, and the
    /// Applications pop-up carries no ellipsis: it is a menu, not a window.
    func testHeadingsAreTitleCaseAndTheApplicationsPopUpHasNoEllipsis() {
        XCTAssertEqual(CompanionL10n.string("pad.picker.heading"), "Pads")
        XCTAssertEqual(CompanionL10n.string("pad.timeline.heading"), "Timeline")
        XCTAssertEqual(CompanionL10n.string("pad.files.heading"), "Files")
        XCTAssertEqual(CompanionL10n.string("pad.app.menu"), "Applications")
        XCTAssertEqual(CompanionL10n.string("pad.app.remove"), "pad.app.remove", "the remove items became checkmarks")
    }

    /// One list, each app once: the running ones in order, checked when
    /// associated, then an associated app that is not running, checked,
    /// so it can still be unchecked.
    func testTheApplicationsPopUpListsEachAppOnceWithItsStateAsACheckmark() {
        let choices = PadApplicationChoice.choices(
            running: [("com.a", "A"), ("com.b", "B"), ("com.a", "A again")],
            associated: ["com.b", "com.quit"]
        )
        XCTAssertEqual(choices, [
            PadApplicationChoice(id: "com.a", name: "A", associated: false),
            PadApplicationChoice(id: "com.b", name: "B", associated: true),
            PadApplicationChoice(id: "com.quit", name: "com.quit", associated: true),
        ])
        var toggled: [PadApplicationChoice] = []
        let menu = PadApplicationChoice.menu(choices: choices) { toggled.append($0) }
        XCTAssertEqual(menu.items.map(\.title), ["A", "B", "com.quit"])
        XCTAssertEqual(menu.items.map(\.state), [.off, .on, .on])
        menu.performActionForItem(at: 1)
        XCTAssertEqual(toggled, [choices[1]], "the item handed over another app or state")
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
        XCTAssertEqual(newest.action, "Activate to sort today checkpoints in natural order")
        XCTAssertEqual(oldest.symbolName, "arrow.down")
        XCTAssertEqual(newest.symbolName, "arrow.up")
        let natural = PadSortCopy(direction: .natural, subject: "today checkpoints")
        XCTAssertEqual(natural.label, "today checkpoints sort order")
        XCTAssertEqual(natural.currentOrder, "Natural order")
        XCTAssertEqual(natural.action, "Activate to sort today checkpoints oldest first")
        XCTAssertEqual(natural.symbolName, "list.bullet")
    }

    func testDaySortAccessibilityCyclesThroughNaturalOrder() {
        let cases: [(PadSortDirection, String, String, String)] = [
            (.natural, "Natural order", "Activate to sort days oldest first", "list.bullet"),
            (.chronological, "Oldest first", "Activate to sort days newest first", "arrow.down"),
            (.reverseChronological, "Newest first", "Activate to sort days in natural order", "arrow.up")
        ]
        for (direction, value, action, symbol) in cases {
            let copy = PadSortCopy(direction: direction, subject: "days")
            XCTAssertEqual(copy.label, "days sort order")
            XCTAssertEqual(copy.currentOrder, value)
            XCTAssertEqual(copy.action, action)
            XCTAssertEqual(copy.symbolName, symbol)
        }
    }

    func testSortAccessibilityRetainsExplicitNextOverride() {
        let copy = PadSortCopy(direction: .reverseChronological, subject: "days", next: .chronological)
        XCTAssertEqual(copy.currentOrder, "Newest first")
        XCTAssertEqual(copy.action, "Activate to sort days oldest first")
    }

    func testExperimentalRailWidthAndLayoutDisclosureUseSameMeasure() {
        XCTAssertEqual(TimeRailView.width(experimental: false), 110)
        XCTAssertEqual(TimeRailView.width(experimental: true), 150)
        XCTAssertEqual(TimeRailView.width, TimeRailView.width(experimental: false))
        XCTAssertTrue(GeneralSettingsView.pageLayoutCaption(experimental: false).contains("110 points"))
        XCTAssertTrue(GeneralSettingsView.pageLayoutCaption(experimental: true).contains("150 points"))
        for experimental in [false, true] {
            let caption = GeneralSettingsView.pageLayoutCaption(experimental: experimental)
            XCTAssertTrue(caption.contains("older blank pages are hidden"))
            XCTAssertFalse(caption.contains("counted"))
        }
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
        model.toggleCheckpointSort(dayBucket: 0)
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
