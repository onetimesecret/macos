import CompanionKit
import XCTest

@testable import OnetimePad

/// The launch's stance and the activation that decides it, tested as
/// the pure decision it is (dogfood phase 4). Nothing here launches
/// anything or builds a model: that the surface is on screen after a
/// real launch is hardware knowledge and stays in the manual matrix.
/// The resting stance a login item is left in is pinned only by its
/// negative: no activation means the router is never asked.
///
/// Scope after ADR-0033: launch routes both windows. With the ambient
/// panel on, the panel rests on every launch; with it off, the panel
/// is not shown at all. The editor window opens for a person's launch,
/// a Dock click, reopen or ⌘Tab, unless About or Settings claimed the
/// activation for itself (`testAnActivationAnotherWindowAskedForDoesNothing`),
/// and, with the ambient panel off, for the hotkey and the status item
/// as well (ActivationRouteTests holds those two rows). It never opens
/// for a login item or any launch the system performs without
/// activating the app. The cases in this file are the router's
/// decisions across the launch routes.
final class LaunchStanceTests: XCTestCase {
    private func context(claimedByAnotherWindow: Bool = false) -> ActivationContext {
        ActivationContext(
            ambientPanelEnabled: true,
            owner: .panel,
            claimedByAnotherWindow: claimedByAnotherWindow
        )
    }

    // MARK: The person's launch selects the editor, as a summon

    func testAnActivationInsideTheLaunchWindowIsTheLaunchActivation() {
        // A person's launch activates the app within moments of
        // `applicationDidFinishLaunching`. The launch itself placed the
        // surface resting and left the route to this activation.
        XCTAssertEqual(
            ActivationRouter.activationReason(
                sinceLaunch: 0, launchWindow: BackdropAppDelegate.launchWindow
            ),
            .launchActivation
        )
        XCTAssertEqual(
            ActivationRouter.activationReason(
                sinceLaunch: 0.3, launchWindow: BackdropAppDelegate.launchWindow
            ),
            .launchActivation
        )
    }

    func testTheLaunchActivationOpensTheEditorWindowAsASummon() {
        // A person opening the app is coming to the pad, not back to a
        // sentence they left in an older day, so the launch route anchors
        // the roll on today.
        XCTAssertEqual(
            ActivationRouter.decide(.launchActivation, in: context()),
            .openEditorWindow(.summon)
        )
    }

    func testDispatchPreservesTheLaunchSummonReason() {
        var editorRaise: BackdropRaise?
        BackdropAppDelegate.dispatch(
            ActivationRouter.decide(.launchActivation, in: context()),
            openEditorWindow: { editorRaise = $0 },
            raisePanel: { _ in XCTFail("launch must not raise the panel") },
            summonPanel: { XCTFail("launch must not summon the panel") },
            closeEditorForPanel: { XCTFail("launch must not close the editor") }
        )

        XCTAssertEqual(editorRaise, .summon)
        XCTAssertTrue(BackdropModel.anchorsOnToday(raise: editorRaise!))
    }

    // MARK: Every later activation is the user choosing the app

    func testAnActivationAtOrAfterTheLaunchWindowIsLate() {
        // The first real ⌘Tab, hours later or exactly at the boundary,
        // is the user naming the app rather than the launch activation.
        XCTAssertEqual(
            ActivationRouter.activationReason(
                sinceLaunch: BackdropAppDelegate.launchWindow,
                launchWindow: BackdropAppDelegate.launchWindow
            ),
            .lateActivation
        )
        XCTAssertEqual(
            ActivationRouter.activationReason(
                sinceLaunch: 3_600, launchWindow: BackdropAppDelegate.launchWindow
            ),
            .lateActivation
        )
    }

    func testALateActivationOpensTheEditorWindowAsAnActivation() {
        XCTAssertEqual(
            ActivationRouter.decide(.lateActivation, in: context()),
            .openEditorWindow(.activation)
        )
    }

    func testTheLaunchWindowIsRecencyNotACounter() {
        // A login item or a background launch never activates at all.
        // The first real ⌘Tab after the window is late even though no
        // earlier activation was classified.
        XCTAssertEqual(
            ActivationRouter.activationReason(
                sinceLaunch: BackdropAppDelegate.launchWindow + 0.01,
                launchWindow: BackdropAppDelegate.launchWindow
            ),
            .lateActivation
        )
    }

    // MARK: About and Settings keep their claim

    func testAnActivationAnotherWindowAskedForDoesNothing() {
        // About and Settings activate the app for themselves; the
        // editor must not be selected inside or after the launch window.
        XCTAssertEqual(
            ActivationRouter.decide(
                .launchActivation, in: context(claimedByAnotherWindow: true)
            ),
            .noop
        )
        XCTAssertEqual(
            ActivationRouter.decide(
                .lateActivation, in: context(claimedByAnotherWindow: true)
            ),
            .noop
        )
    }

    // MARK: The raise after a modal of ours

    func testAModalsReturnRaisesOverAStillRaisedSurface() {
        // An open or save panel returns to the surface that raised it.
        XCTAssertTrue(
            BackdropAppDelegate.raisesAfterModal(stance: .raised, modalSessionRunning: false)
        )
    }

    func testAModalsReturnDoesNotRaiseARestedSurface() {
        // A rest while the panel was up was somebody's deliberate act
        // and is not ours to undo.
        XCTAssertFalse(
            BackdropAppDelegate.raisesAfterModal(stance: .resting, modalSessionRunning: false)
        )
    }

    func testAModalsReturnDoesNotRaiseUnderANextModal() {
        // The deferred raise runs on the main queue, which drains
        // inside a modal's run loop; a second modal opened on the
        // first's return would otherwise take a `makeKeyAndOrderFront`
        // under its own session. The same fact the outside press rule
        // reads (`OutsidePress.rests`), read the same way.
        XCTAssertFalse(
            BackdropAppDelegate.raisesAfterModal(stance: .raised, modalSessionRunning: true)
        )
    }

    // MARK: The login launch — no activation, so nothing opens (B4)

    func testALoginLaunchOpensNoEditorWindowByItsAbsence() {
        // A login launch, or any other launch the system performs, is
        // filed by the absence of an activation inside `launchWindow`.
        // ADR-0033 requires it to open no editor window: the routing
        // table is what opens one, and only the launch activation and
        // its two later cousins route to the editor window. The launch
        // itself is not one of the routing table's reasons, so a launch
        // that never sends an activation is never asked, and no editor
        // window opens.
        //
        // What can be pinned here is the classifier: after the launch
        // window has passed with no activation, any activation that
        // does arrive is `.lateActivation` (a ⌘Tab hours later, a Dock
        // click), not `.launchActivation`, and the earlier moment when
        // the launch could have been read as itself is over. The rest
        // is asserted by the ADR text and by the fact that
        // `applicationDidFinishLaunching` calls `controller.show()`
        // and no editor window verb.
        XCTAssertEqual(
            ActivationRouter.activationReason(
                sinceLaunch: BackdropAppDelegate.launchWindow + 0.5,
                launchWindow: BackdropAppDelegate.launchWindow
            ),
            .lateActivation
        )
        XCTAssertEqual(
            ActivationRouter.activationReason(
                sinceLaunch: 3_600,
                launchWindow: BackdropAppDelegate.launchWindow
            ),
            .lateActivation
        )
    }
}
