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
        waitUntil(model.$notice, description: "the flash's dwell ended on an empty line") { $0 == nil }
    }

    /// A flash stands in front of a held line for its dwell, then gives
    /// the line back while the field that raised it is still open.
    func testAHeldLineComesBackWhenAFlashInFrontOfItEnds() throws {
        let model = try model()
        let hold = model.holdNotice("Enter a pad name.")
        model.flash("long lines wrap")
        XCTAssertEqual(model.notice, "long lines wrap")
        XCTAssertEqual(model.noticeTone, .plain)
        waitUntil(model.$notice, description: "the held line came back") { $0 == "Enter a pad name." }
        XCTAssertEqual(model.noticeTone, .actionable, "the held line came back in the flash's ink")
        model.releaseNotice(hold)
        XCTAssertNil(model.notice)
    }

    /// The model's own clears, a new page and a closed tab among them, put
    /// a held line back rather than leave the open field's refusal unsaid.
    func testTheModelsClearsPutAHeldLineBack() throws {
        let model = try model()
        model.loadStateIfNeeded()
        let hold = model.holdNotice("Enter a pad name.")
        model.newPage()
        XCTAssertEqual(model.notice, "Enter a pad name.", "a new page took the held line down")
        model.close(try XCTUnwrap(model.selection))
        XCTAssertEqual(model.notice, "Enter a pad name.", "a closed tab took the held line down")
        model.releaseNotice(hold)
        XCTAssertNil(model.notice)
        model.newPage()
        XCTAssertNil(model.notice, "a released line came back")
    }
}
