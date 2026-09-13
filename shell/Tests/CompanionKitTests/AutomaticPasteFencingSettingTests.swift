import XCTest

@testable import CompanionKit

/// Code presentation and detection preferences: defaults are explicit,
/// changes persist immediately, and no setting dirties page content.
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

        XCTAssertTrue(model.syntaxHighlightingEnabled)
        XCTAssertFalse(model.languageDetectionEnabled)
        XCTAssertFalse(model.automaticallyFencePastes)
        XCTAssertEqual(model.codeFontFamily, "")
        XCTAssertNil(defaults.object(forKey: "syntaxHighlightingEnabled"))
        XCTAssertNil(defaults.object(forKey: "languageDetectionEnabled"))
        XCTAssertNil(defaults.object(forKey: "automaticallyFencePastes"))
        XCTAssertNil(defaults.object(forKey: "codeFontFamily"))
    }

    func testPreferencePersistsImmediatelyAndSurvivesRelaunch() throws {
        let (first, defaults) = try makeModel()

        first.syntaxHighlightingEnabled = false
        first.languageDetectionEnabled = true
        first.automaticallyFencePastes = true
        first.codeFontFamily = "Menlo"

        XCTAssertEqual(defaults.object(forKey: "syntaxHighlightingEnabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "languageDetectionEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "automaticallyFencePastes") as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: "codeFontFamily"), "Menlo")
        let second = isolatedModel(defaults: defaults)
        XCTAssertFalse(second.syntaxHighlightingEnabled)
        XCTAssertTrue(second.languageDetectionEnabled)
        XCTAssertTrue(second.automaticallyFencePastes)
        XCTAssertEqual(second.codeFontFamily, "Menlo")
    }

    func testChangingPreferenceDoesNotMarkContentDirty() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        let marks = model.dirtyMarks

        model.syntaxHighlightingEnabled = false
        model.languageDetectionEnabled = true
        model.automaticallyFencePastes = true
        model.codeFontFamily = "Menlo"
        model.automaticallyFencePastes = false

        XCTAssertEqual(model.dirtyMarks, marks, "a preference armed a ciphertext write")
    }
}
