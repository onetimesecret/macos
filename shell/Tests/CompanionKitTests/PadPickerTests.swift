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
