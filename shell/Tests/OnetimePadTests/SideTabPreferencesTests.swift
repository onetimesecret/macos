import CompanionCore
import Foundation
import XCTest

@testable import CompanionKit
@testable import OnetimePad

private final class SideTabCountingDefaults: UserDefaults, @unchecked Sendable {
    var sideTabWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == SideTabPreferences.defaultsKey { sideTabWrites += 1 }
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class SideTabPreferencesTests: XCTestCase {
    private func defaults() throws -> SideTabCountingDefaults {
        let suite = "side-tab-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(SideTabCountingDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testNonFinitePositionsPreserveTheOtherSettingsWhenSaved() throws {
        let defaults = try defaults()
        for position in [Double.nan, .infinity, -.infinity] {
            let preferences = SideTabPreferences(enabled: true, displayID: "selected-display",
                edge: .left, position: position)
            preferences.save(to: defaults)
            XCTAssertEqual(SideTabPreferences.load(from: defaults),
                SideTabPreferences(enabled: true, displayID: "selected-display", edge: .left, position: 0.5))
            XCTAssertEqual(preferences.normalizedPosition, 0.5)
        }
    }

    func testOutOfRangePositionsClampDuringSaveAndLoad() throws {
        let defaults = try defaults()
        for (position, expected) in [(-3.0, 0.0), (4.0, 1.0)] {
            let preferences = SideTabPreferences(enabled: true, displayID: "selected-display",
                edge: .left, position: position)
            preferences.save(to: defaults)
            XCTAssertEqual(SideTabPreferences.load(from: defaults).position, expected)

            defaults.set(try JSONEncoder().encode(preferences), forKey: SideTabPreferences.defaultsKey)
            let loaded = SideTabPreferences.load(from: defaults)
            XCTAssertEqual(loaded.position, expected)
            XCTAssertTrue(loaded.enabled)
            XCTAssertEqual(loaded.displayID, "selected-display")
            XCTAssertEqual(loaded.edge, .left)
        }
    }

    func testFinitePositionsAndDisplaySelectionRoundTripUnchanged() throws {
        let defaults = try defaults()
        for position in [0.0, 0.213, 0.5, 0.817, 1.0] {
            let preferences = SideTabPreferences(enabled: false, displayID: "selected-display",
                edge: .right, position: position)
            preferences.save(to: defaults)
            XCTAssertEqual(SideTabPreferences.load(from: defaults), preferences)
            XCTAssertEqual(preferences.normalizedPosition, position)
        }
    }

    func testNoOpModelAssignmentsDoNotWritePreferences() throws {
        let defaults = try defaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-tab-preferences-state-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        companion_init()
        let tag = UUID().uuidString
        let handle = try XCTUnwrap(tag.withCString { companion_new_ephemeral($0) })
        let pages = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: CompanionClient(adopting: handle)))
        let model = BackdropModel(defaults: defaults, pages: pages)

        let original = model.sideTab
        let baseline = defaults.sideTabWrites
        model.sideTab = original
        XCTAssertEqual(defaults.sideTabWrites, baseline)
        model.sideTab.position = 0.6
        XCTAssertEqual(defaults.sideTabWrites, baseline + 1)
        let changed = model.sideTab
        model.sideTab = changed
        XCTAssertEqual(defaults.sideTabWrites, baseline + 1)
        model.sideTab.enabled = true
        XCTAssertEqual(defaults.sideTabWrites, baseline + 2)
        XCTAssertEqual(SideTabPreferences.load(from: defaults), model.sideTab)

        for (position, expected) in [(2.0, 1.0), (-1.0, 0.0), (.nan, 0.5),
                                     (.infinity, 0.5), (-.infinity, 0.5)] {
            let previous = model.sideTab.position
            let writes = defaults.sideTabWrites
            model.sideTab.position = position
            XCTAssertEqual(model.sideTab.position, expected)
            XCTAssertEqual(SideTabPreferences.load(from: defaults), model.sideTab)
            let expectedWrites = writes + (previous == expected ? 0 : 1)
            XCTAssertEqual(defaults.sideTabWrites, expectedWrites)
            model.sideTab.position = expected
            XCTAssertEqual(defaults.sideTabWrites, expectedWrites)
        }
    }
}
