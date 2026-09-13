import XCTest

@testable import CompanionKit

/// The automatic paste-fencing preference: absent means off, a change is
/// persisted immediately, and changing it never edits or marks page content.
@MainActor
final class AutomaticPasteFencingSettingTests: XCTestCase {
    private func makeModel() throws -> (model: PageModel, defaults: UserDefaults) {
        let suite = "companion-automatic-paste-fencing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return (isolatedModel(defaults: defaults), defaults)
    }

    func testMissingPreferenceIsOffAndIsNotWrittenDuringInitialization() throws {
        let (model, defaults) = try makeModel()

        XCTAssertFalse(model.automaticallyFencePastes)
        XCTAssertNil(defaults.object(forKey: "automaticallyFencePastes"))
    }

    func testPreferencePersistsImmediatelyAndSurvivesRelaunch() throws {
        let (first, defaults) = try makeModel()

        first.automaticallyFencePastes = true

        XCTAssertEqual(defaults.object(forKey: "automaticallyFencePastes") as? Bool, true)
        let second = isolatedModel(defaults: defaults)
        XCTAssertTrue(second.automaticallyFencePastes)
    }

    func testChangingPreferenceDoesNotMarkContentDirty() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        let marks = model.dirtyMarks

        model.automaticallyFencePastes = true
        model.automaticallyFencePastes = false

        XCTAssertEqual(model.dirtyMarks, marks, "a preference armed a ciphertext write")
    }
}
