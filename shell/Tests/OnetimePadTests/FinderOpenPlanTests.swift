import CompanionKit
import XCTest

@testable import OnetimePad

/// The Finder open drain (`FinderOpenPlan.decide`) as a pure decision, and
/// what the launch activation that follows it does with the route it arms.
final class FinderOpenPlanTests: XCTestCase {
    private let notes = URL(fileURLWithPath: "/tmp/qa/notes.txt")
    private let draft = URL(fileURLWithPath: "/tmp/qa/draft.md")
    private let link = URL(string: "https://example.com/private/etc/hosts")!
    private let context = ActivationContext(
        ambientPanelEnabled: false, owner: .editorWindow, claimedByAnotherWindow: false)

    private func plan(
        _ queued: [URL],
        startupComplete: Bool = true,
        modalSessionRunning: Bool = false,
        launchActivationOutstanding: Bool = false,
        appActive: Bool = true
    ) -> FinderOpenPlan {
        FinderOpenPlan.decide(
            queued: queued,
            startupComplete: startupComplete,
            modalSessionRunning: modalSessionRunning,
            launchActivationOutstanding: launchActivationOutstanding,
            appActive: appActive,
            context: context)
    }

    /// What the launch's own activation routes to, given what the drain armed.
    private func launchActivationRoute(after plan: FinderOpenPlan) -> ActivationRoute {
        ActivationRouter.routeForActivation(
            pendingSummon: plan.pendingRoute,
            sinceLaunch: 0.1,
            launchWindow: BackdropAppDelegate.launchWindow,
            context: context)
    }

    func testAFileDeliveredBeforeStartupCompletesIsHeldForTheDrain() {
        let held = plan([notes], startupComplete: false, launchActivationOutstanding: true)

        XCTAssertEqual(held, FinderOpenPlan(held: [notes]))
    }

    func testTheStartupDrainOpensTheHeldFileAndKeepsTheLaunchOffToday() {
        let drained = plan([notes], launchActivationOutstanding: true)

        XCTAssertEqual(drained.open, [notes])
        XCTAssertEqual(drained.held, [])
        XCTAssertEqual(
            drained.pendingRoute,
            ActivationRouter.decide(.openEditorPresentation, in: context),
            "the route comes from the table, not built by hand")
        let route = launchActivationRoute(after: drained)
        XCTAssertEqual(route, .openEditorWindow(.activation))
        guard case .openEditorWindow(let raise) = route else { return XCTFail("\(route)") }
        XCTAssertFalse(BackdropModel.anchorsOnToday(raise: raise),
                       "the opened file stays selected; the roll does not jump to today")
    }

    func testABatchWithNoFileOpensNothingAndLeavesTheLaunchItsSummon() {
        for queued in [[link], []] {
            let drained = plan(queued, launchActivationOutstanding: true)

            XCTAssertEqual(drained, FinderOpenPlan(), "\(queued)")
            XCTAssertEqual(launchActivationRoute(after: drained), .openEditorWindow(.summon))
        }
    }

    func testOnlyTheFilesInAMixedBatchOpen() {
        let drained = plan([link, notes, draft])

        XCTAssertEqual(drained.open, [notes, draft], "files open in the order they arrived")
    }

    func testNoRouteIsArmedWhenTheReplayAlreadyConsumedTheLaunchActivation() {
        let drained = plan([notes], launchActivationOutstanding: false)

        XCTAssertEqual(drained, FinderOpenPlan(open: [notes]))
    }

    func testAnInactiveAppArmsNoRouteOfItsOwn() {
        // applySummon defers the editor for an inactive app and arms the route there.
        let drained = plan([notes], launchActivationOutstanding: true, appActive: false)

        XCTAssertEqual(drained, FinderOpenPlan(open: [notes]))
    }

    func testAFinderOpenDuringAModalKeepsOnlyItsFiles() {
        let held = plan([notes, link], modalSessionRunning: true)

        XCTAssertEqual(held, FinderOpenPlan(held: [notes]))
    }

    func testABatchWithNoFileKeepsNothingBeforeStartup() {
        let held = plan([link], startupComplete: false)

        XCTAssertEqual(held, FinderOpenPlan())
    }

    func testTheHeldFilesOpenOnceTheModalHasEnded() {
        let held = plan([notes], modalSessionRunning: true).held
        let drained = plan(held + [draft])

        XCTAssertEqual(drained, FinderOpenPlan(open: [notes, draft]))
    }

    func testTheModelIsNotReadBeforeStartup() {
        var reads = 0
        func readContext() -> ActivationContext {
            reads += 1
            return context
        }
        _ = FinderOpenPlan.decide(
            queued: [notes], startupComplete: false, modalSessionRunning: false,
            launchActivationOutstanding: true, appActive: true, context: readContext())

        XCTAssertEqual(reads, 0)
    }
}
