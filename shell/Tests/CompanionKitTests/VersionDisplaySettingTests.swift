import XCTest

@testable import CompanionKit

/// The menu's technical-version line is opt-in and persists as a presentation
/// preference without marking page content dirty.
@MainActor
final class VersionDisplaySettingTests: XCTestCase {
    private func makeModel() throws -> (model: PageModel, defaults: UserDefaults) {
        let suite = "companion-version-display-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return (isolatedModel(defaults: defaults), defaults)
    }

    func testMissingPreferenceLeavesMenuVersionsHidden() throws {
        let (model, defaults) = try makeModel()

        XCTAssertFalse(model.showsVersionsInMenu)
        XCTAssertNil(defaults.object(forKey: "showsVersionsInMenu"))
    }

    func testPreferencePersistsImmediatelyAndSurvivesRelaunch() throws {
        let (first, defaults) = try makeModel()

        first.showsVersionsInMenu = true

        XCTAssertEqual(defaults.object(forKey: "showsVersionsInMenu") as? Bool, true)
        XCTAssertTrue(isolatedModel(defaults: defaults).showsVersionsInMenu)
    }

    func testChangingPreferenceDoesNotMarkContentDirty() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        let marks = model.dirtyMarks

        model.showsVersionsInMenu = true
        model.showsVersionsInMenu = false

        XCTAssertEqual(model.dirtyMarks, marks, "a presentation preference armed a ciphertext write")
    }
}
