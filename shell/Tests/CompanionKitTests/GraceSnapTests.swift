import XCTest

@testable import CompanionKit

/// The boundary snap setting (ADR-0011 section 4, issue #146): one
/// boolean in this form factor's defaults, on unless turned off, told
/// to the core at launch and on every flip, and consulted by the core
/// only when a rung is applied. Every model below rests in a temporary
/// directory over an ephemeral credential store, so nothing here touches
/// a real state file or the login Keychain.
@MainActor
final class GraceSnapTests: XCTestCase {
    private static let day: UInt64 = 24 * 60 * 60 * 1_000

    private func makeModel() throws -> (model: PageModel, defaults: UserDefaults) {
        let suite = "companion-grace-snap-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return (isolatedModel(defaults: defaults), defaults)
    }

    /// The remaining life of the one page a fresh model opens on.
    private func remainingMs(of model: PageModel) throws -> UInt64 {
        model.refresh()
        return try XCTUnwrap(model.coreClient.tabs().first).remainingMs
    }

    func testTheSnapIsOnUnlessTurnedOffAndOutlivesARelaunch() throws {
        let (first, defaults) = try makeModel()
        XCTAssertTrue(first.snapsToBoundaries, "on by default (ADR-0011 section 4)")
        XCTAssertNil(defaults.object(forKey: "snapsToBoundaries"), "the default is not written down")

        first.snapsToBoundaries = false
        XCTAssertEqual(defaults.object(forKey: "snapsToBoundaries") as? Bool, false)

        let second = isolatedModel(defaults: defaults)
        XCTAssertFalse(second.snapsToBoundaries, "the preference did not survive a relaunch")
    }

    /// A new tab opens on the ceiling (ADR-0011 section 3), and with the
    /// snap on its deadline is the week plus the hours to the midnight
    /// after it: more than seven days, never more than eight. With the
    /// snap off the same tab gets exactly the week.
    func testANewPageOpensOnTheCeilingAndTheSnapRoundsItsDeadlineUp() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        let sheet = try XCTUnwrap(model.coreClient.tabs().first)
        XCTAssertEqual(Rung(rawValue: sheet.rungCode), .sevenDays)
        let snapped = try remainingMs(of: model)
        XCTAssertGreaterThanOrEqual(snapped, 7 * Self.day)
        XCTAssertLessThanOrEqual(snapped, 8 * Self.day)

        model.snapsToBoundaries = false
        let page = try XCTUnwrap(model.selection)
        XCTAssertTrue(model.coreClient.setRung(tab: page, rung: .sevenDays))
        let exact = try remainingMs(of: model)
        XCTAssertLessThanOrEqual(exact, 7 * Self.day)
        XCTAssertGreaterThan(exact, 7 * Self.day - 1_000)
    }

    /// Flipping the setting is a change to what the next rung does, not
    /// to any page: the deadline already set stands to the millisecond,
    /// and nothing is marked dirty, since the value lives in the
    /// defaults and not in the sealed file.
    func testFlippingTheSettingMovesNoDeadlineAndMarksNothingDirty() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        let before = try remainingMs(of: model)
        let marks = model.dirtyMarks

        model.snapsToBoundaries = false
        model.refresh()
        model.snapsToBoundaries = true
        model.refresh()

        let after = try remainingMs(of: model)
        XCTAssertLessThan(before - min(before, after), 1_000, "the flip moved a live deadline")
        XCTAssertEqual(model.dirtyMarks, marks, "a preference armed a ciphertext write")
    }

    /// The relaunched model tells the core what it read from the
    /// defaults: a model opened with the snap off mints exact pages.
    func testARelaunchWithTheSnapOffMintsExactPages() throws {
        let (first, defaults) = try makeModel()
        first.snapsToBoundaries = false

        let second = isolatedModel(defaults: defaults)
        second.loadStateIfNeeded()
        let exact = try remainingMs(of: second)
        XCTAssertLessThanOrEqual(exact, 7 * Self.day)
    }
}
