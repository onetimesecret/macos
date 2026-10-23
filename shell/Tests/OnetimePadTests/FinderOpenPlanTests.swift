import CompanionKit
import XCTest

@testable import OnetimePad

/// The Finder open drain (`FinderOpenPlan.decide`) as a pure decision, and
/// what the launch activation that follows it does with the route it arms.
final class FinderOpenPlanTests: XCTestCase {
    private let notes = URL(fileURLWithPath: "/tmp/qa/notes.txt")
    private let draft = URL(fileURLWithPath: "/tmp/qa/draft.md")
    private let link = URL(string: "https://example.com/private/etc/hosts")!
    private func plan(
        _ queued: [URL],
        startupComplete: Bool = true,
        modalSessionRunning: Bool = false,
        modalBracketed: Bool = false,
        closeDecisionPending: Bool = false
    ) -> FinderOpenPlan {
        FinderOpenPlan.decide(
            queued: queued,
            startupComplete: startupComplete,
            modalSessionRunning: modalSessionRunning,
            modalBracketed: modalBracketed,
            closeDecisionPending: closeDecisionPending)
    }

    func testAFileDeliveredBeforeStartupCompletesIsHeldForTheDrain() {
        let held = plan([notes], startupComplete: false)

        XCTAssertEqual(held, FinderOpenPlan(held: [notes]))
    }

    func testStartupDrainOpensTheHeldFiles() {
        XCTAssertEqual(plan([notes]), FinderOpenPlan(open: [notes]))
    }

    func testABatchWithNoFileOpensNothing() {
        for queued in [[link], []] { XCTAssertEqual(plan(queued), FinderOpenPlan()) }
    }

    func testOnlyTheFilesInAMixedBatchOpen() {
        let drained = plan([link, notes, draft])

        XCTAssertEqual(drained.open, [notes, draft], "files open in the order they arrived")
    }

    func testAFinderOpenDuringAModalKeepsOnlyItsFiles() {
        let held = plan([notes, link], modalSessionRunning: true)

        XCTAssertEqual(held, FinderOpenPlan(held: [notes]))
    }

    func testABatchWithNoFileKeepsNothingBeforeStartup() {
        let held = plan([link], startupComplete: false)

        XCTAssertEqual(held, FinderOpenPlan())
    }

    func testAFinderOpenWhileAPanelOrdersItselfOutWaits() {
        // The session is over but the bracket is still on the stack (`ModalSession.isBracketed`).
        let held = plan([notes, link], modalBracketed: true)

        XCTAssertEqual(held, FinderOpenPlan(held: [notes]))
    }

    func testTheHeldFilesOpenOnceTheModalHasEnded() {
        let held = plan([notes], modalSessionRunning: true).held
        let drained = plan(held + [draft])

        XCTAssertEqual(drained, FinderOpenPlan(open: [notes, draft]))
    }

    func testAFinderOpenDuringACloseDecisionKeepsOnlyItsFiles() {
        let held = plan([notes, link], closeDecisionPending: true)

        XCTAssertEqual(held, FinderOpenPlan(held: [notes]))
    }

    func testTheHeldFilesOpenOnceTheCloseDecisionResolves() {
        let held = plan([notes], closeDecisionPending: true).held

        XCTAssertEqual(plan(held), FinderOpenPlan(open: [notes]))
    }

    func testTheModelIsNotReadBeforeStartup() {
        var reads = 0
        func closeDecision() -> Bool { reads += 1; return false }
        _ = FinderOpenPlan.decide(queued: [notes], startupComplete: false,
            modalSessionRunning: false, modalBracketed: false, closeDecisionPending: closeDecision())
        XCTAssertEqual(reads, 0)
    }
}
