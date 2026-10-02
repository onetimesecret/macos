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
