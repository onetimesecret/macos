import CompanionKit
import XCTest

@testable import OnetimePad

final class LaunchStanceTests: XCTestCase {
    private func context(claimedByAnotherWindow: Bool = false) -> ActivationContext {
        ActivationContext(
            ambientPanelEnabled: true,
            owner: .panel,
            claimedByAnotherWindow: claimedByAnotherWindow
        )
    }

    // MARK: The person's launch selects the editor, as a summon

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

    // MARK: Ordinary activation leaves ordering to AppKit

    func testReturningToTheApplicationDoesNotSelectAnEditor() {
        XCTAssertEqual(ActivationRouter.routeForActivation(pendingSummon: nil, context: context()), .noop)
    }

    // MARK: About and Settings keep their claim

    func testAnActivationAnotherWindowAskedForDoesNothing() {
        XCTAssertEqual(
            ActivationRouter.routeForActivation(
                pendingSummon: nil, context: context(claimedByAnotherWindow: true)
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

}
