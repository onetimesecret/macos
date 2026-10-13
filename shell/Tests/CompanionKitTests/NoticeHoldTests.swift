import Foundation
import XCTest

@testable import CompanionKit

/// The line under the page held for a refusal while its field stays open
/// (Law 0007, Refusing; D-14), as against `flash`, which clears itself.
@MainActor
final class NoticeHoldTests: XCTestCase {
    private func model() throws -> PageModel {
        let suite = "notice-hold-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return isolatedModel(defaults: defaults)
    }

    /// A negative window, so clock based: the earlier flash's clear and
    /// any dwell of the hold's own would both land inside it.
    func testAHeldLineOutlastsTheDwellAndGoesWhenReleased() throws {
        let model = try model()
        model.flash("long lines wrap")
        let hold = model.holdNotice("Enter a pad name.")
        XCTAssertEqual(model.noticeTone, .actionable, "a refusal is something to act on")
        letElapse(PageModel.noticeDwell + 0.5)
        XCTAssertEqual(model.notice, "Enter a pad name.", "the held line cleared on the flash dwell")
        model.releaseNotice(hold)
        XCTAssertNil(model.notice)
    }

    func testAReleaseLeavesANewerNoticeStanding() throws {
        let model = try model()
        let hold = model.holdNotice("Enter a pad name.")
        model.flash("long lines wrap")
        model.releaseNotice(hold)
        XCTAssertEqual(model.notice, "long lines wrap", "a release took down a line it did not put up")
    }
}
