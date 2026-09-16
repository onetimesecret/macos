import XCTest

@testable import CompanionKit

/// The two time patterns (how a page's birth time reads beside its
/// day, and the finer form two pages sharing a minute fall back to)
/// are presentation preferences: they persist on their own keys and
/// mark no page content dirty.
@MainActor
final class StampFormatSettingTests: XCTestCase {
    private func makeModel() throws -> (model: PageModel, defaults: UserDefaults) {
        let suite = "companion-stamp-format-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return (isolatedModel(defaults: defaults), defaults)
    }

    func testMissingPreferenceReadsAsTheStandardPatterns() throws {
        let (model, defaults) = try makeModel()

        XCTAssertEqual(model.stampFormat, .standard)
        XCTAssertEqual(model.stampFormat.short, "HH:mm")
        XCTAssertEqual(model.stampFormat.fine, "HH:mm:ss")
        XCTAssertNil(defaults.object(forKey: "stampFormatShort"))
        XCTAssertNil(defaults.object(forKey: "stampFormatFine"))
    }

    func testPreferencePersistsImmediatelyAndSurvivesRelaunch() throws {
        let (first, defaults) = try makeModel()

        first.stampFormat = StreamNavigator.StampFormat(short: "h:mm a", fine: "h:mm:ss a")

        XCTAssertEqual(defaults.string(forKey: "stampFormatShort"), "h:mm a")
        XCTAssertEqual(defaults.string(forKey: "stampFormatFine"), "h:mm:ss a")
        let second = isolatedModel(defaults: defaults)
        XCTAssertEqual(second.stampFormat.short, "h:mm a")
        XCTAssertEqual(second.stampFormat.fine, "h:mm:ss a")
    }

    func testChangingPreferenceDoesNotMarkContentDirty() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        let marks = model.dirtyMarks

        model.stampFormat.short = "HH.mm"
        model.stampFormat = .standard

        XCTAssertEqual(model.dirtyMarks, marks, "a presentation preference armed a ciphertext write")
    }
}
