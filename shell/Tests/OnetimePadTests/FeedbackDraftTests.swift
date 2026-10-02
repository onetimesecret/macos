import XCTest
@testable import OnetimePad

@MainActor
final class FeedbackDraftTests: XCTestCase {
    private let report = DiagnosticsReport(summary: "summary", details: "reviewed snapshot")

    func testSnapshotIsIncludedOnlyWhenSelected() {
        let draft = FeedbackDraft(serverURL: { "https://example.test" }, makeReport: { self.report })
        draft.message = "  The panel disappeared.  "
        XCTAssertEqual(draft.submittedMessage, "The panel disappeared.\n\nOnetimePad diagnostics\nreviewed snapshot")
        draft.includeDiagnostics = false
        XCTAssertEqual(draft.submittedMessage, "The panel disappeared.")
        draft.message = "\n "
        draft.contact = "person@example.test"
        XCTAssertFalse(draft.canSend, "Contact alone is not feedback")
    }

    func testFailurePreservesDraftAndRequiresExplicitRetry() async {
        var attempts = 0
        let draft = FeedbackDraft(
            serverURL: { "https://example.test" }, makeReport: { self.report },
            submit: { _, _, _ in
                attempts += 1
                throw URLError(.timedOut)
            }
        )
        draft.message = "Please investigate"
        draft.contact = "person@example.test"
        await draft.send()?.value
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(draft.message, "Please investigate")
        XCTAssertEqual(draft.contact, "person@example.test")
        XCTAssertEqual(draft.report.details, "reviewed snapshot")
        XCTAssertNotNil(draft.error)
        XCTAssertTrue(draft.canSend)
        XCTAssertFalse(draft.sent)
        await Task.yield()
        XCTAssertEqual(attempts, 1)
        await draft.send()?.value
        XCTAssertEqual(attempts, 2)
    }

    func testSendCapturesReviewedFieldsAndBlocksDuplicateClicks() async {
        var server = "https://first.example.test"
        var submitted: (String, String, String?)?
        let draft = FeedbackDraft(
            serverURL: { server }, makeReport: { self.report },
            submit: { submitted = ($0, $1, $2) }
        )
        draft.message = "Reviewed message"
        draft.contact = " person@example.test "
        let task = draft.send()
        XCTAssertTrue(draft.sending)
        XCTAssertNil(draft.send())
        server = "https://second.example.test"
        draft.refreshDestination()
        draft.message = "Later edit"
        await task?.value
        XCTAssertEqual(submitted?.0, "https://first.example.test")
        XCTAssertEqual(submitted?.1, "Reviewed message\n\nOnetimePad diagnostics\nreviewed snapshot")
        XCTAssertEqual(submitted?.2, "person@example.test")
        XCTAssertTrue(draft.sent)
        XCTAssertNil(draft.send())
        draft.startAnother()
        XCTAssertEqual(draft.destination, "https://second.example.test/api/v3/feedback")
        XCTAssertEqual(draft.message, "")
        XCTAssertFalse(draft.sent)
    }

    func testPresentationRetakesTheSnapshotOnlyWhileTheDraftIsIdle() async {
        var captures = 0
        var server = "https://first.example.test"
        let draft = FeedbackDraft(
            serverURL: { server },
            makeReport: {
                captures += 1
                return DiagnosticsReport(summary: "summary", details: "snapshot \(captures)")
            },
            submit: { _, _, _ in }
        )
        XCTAssertEqual(draft.report.details, "snapshot 1")
        draft.prepareForPresentation()
        XCTAssertEqual(draft.report.details, "snapshot 2", "an idle draft reviews the app as it is now")

        draft.message = "Reviewed message"
        let task = draft.send()
        XCTAssertTrue(draft.sending)
        server = "https://second.example.test"
        draft.prepareForPresentation()
        XCTAssertEqual(draft.report.details, "snapshot 2", "a send in flight keeps what it carries")
        XCTAssertEqual(draft.destination, "https://first.example.test/api/v3/feedback")

        await task?.value
        XCTAssertTrue(draft.sent)
        draft.prepareForPresentation()
        XCTAssertEqual(draft.report.details, "snapshot 2", "a sent draft keeps what it sent")
        XCTAssertEqual(draft.destination, "https://first.example.test/api/v3/feedback")
        XCTAssertEqual(captures, 2)
    }

    func testFreshOpenRefreshesDestinationWithoutDiscardingDraft() {
        var server = "invalid"
        let draft = FeedbackDraft(serverURL: { server }, makeReport: { self.report })
        draft.message = "Keep this draft"
        server = "https://fixed.example.test"
        draft.refreshDestination()
        XCTAssertEqual(draft.destination, "https://fixed.example.test/api/v3/feedback")
        XCTAssertEqual(draft.message, "Keep this draft")
    }
}
