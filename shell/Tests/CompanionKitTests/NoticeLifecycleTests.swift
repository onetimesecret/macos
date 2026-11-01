import Foundation
import XCTest

@testable import CompanionKit

@MainActor
final class NoticeLifecycleTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suite = "notice-lifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return isolatedModel(defaults: defaults)
    }

    func testFlashClearsAfterItsDwell() throws {
        let model = try makeModel()
        model.flash("copied")
        waitUntil(model.$notice, description: "notice dwell elapsed") { $0 == nil }
        XCTAssertNil(model.noticeAction)
    }

    func testNoticeActionCanReplaceTheNotice() throws {
        let model = try makeModel()
        var performed = 0
        model.flash("try again", action: .init(label: "Retry") {
            performed += 1
            model.flash("saved")
        })
        model.performNoticeAction()
        XCTAssertEqual(performed, 1)
        XCTAssertEqual(model.notice, "saved")
        XCTAssertNil(model.noticeAction)
        model.performNoticeAction()
        XCTAssertEqual(performed, 1)
    }

    func testNewPageClearsTheNoticeAndItsAction() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        model.flash("try again", action: .init(label: "Retry") {})
        model.newPage()
        XCTAssertNil(model.notice)
        XCTAssertNil(model.noticeAction)
    }
}
