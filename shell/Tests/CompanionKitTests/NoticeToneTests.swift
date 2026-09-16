import Foundation
import XCTest

@testable import CompanionKit

/// The notice line's tone (design record, section 5): ember is for
/// what needs acting on, and everything else the line says is a quiet
/// fact. The tone travels with the words through `flash`, so the
/// surface reads one property and the two can never disagree.
@MainActor
final class NoticeToneTests: XCTestCase {
    private func model(_ suite: String) throws -> PageModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return isolatedModel(defaults: defaults)
    }

    func testANoticeDefaultsToThePlainTone() throws {
        let model = try model("notice-tone-default")
        model.flash("the link is on the clipboard")
        XCTAssertEqual(model.notice, "the link is on the clipboard")
        XCTAssertEqual(model.noticeTone, .plain)
    }

    func testAnActionableNoticeSaysSo() throws {
        let model = try model("notice-tone-actionable")
        model.flash(PageModel.writeRefusalNotice(name: "notes.md"), tone: .actionable)
        XCTAssertEqual(model.noticeTone, .actionable)
    }

    func testTheNextPlainNoticeTakesTheToneBackWithIt() throws {
        // The tone is the notice's, not the model's: a quiet line after
        // a refusal must not inherit the refusal's ember.
        let model = try model("notice-tone-reset")
        model.flash(PageModel.writeRefusalNotice(name: "notes.md"), tone: .actionable)
        model.flash("long lines wrap")
        XCTAssertEqual(model.noticeTone, .plain)
    }

    func testTheToggleNoticesArePlain() throws {
        // The one notice a keystroke raises is a report of what it did.
        let model = try model("notice-tone-wrap")
        model.toggleWrap()
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(model.noticeTone, .plain)
    }
}
