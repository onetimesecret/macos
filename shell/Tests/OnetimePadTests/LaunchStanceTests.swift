import XCTest

@testable import OnetimePad

/// The launch's stance and the activation that decides it, tested as
/// the pure decision it is (dogfood phase 4). Nothing here launches
/// anything or builds a model: that the surface is on screen after a
/// real launch is hardware knowledge and stays in the manual matrix,
/// and a `BackdropModel` reaches for the installed state directory, so
/// the resting stance a login item is left in is pinned only by its
/// negative, that no activation means no raise is ever asked for. What
/// can be pinned is which raise each activation answers with.
final class LaunchStanceTests: XCTestCase {
    // MARK: The person's launch raises, as a summon

    func testTheLaunchRaiseIsASummon() {
        // A person opening the app is coming to the pad, not back to a
        // sentence they left in an older day, so the launch's activation
        // takes the raise that anchors the roll on today.
        XCTAssertEqual(BackdropAppDelegate.launchRaise, .summon)
        XCTAssertTrue(BackdropModel.anchorsOnToday(raise: BackdropAppDelegate.launchRaise))
    }

    func testAnActivationInsideTheLaunchWindowRaisesAsTheLaunch() {
        // A person's launch activates the app within moments of
        // `applicationDidFinishLaunching`. The launch itself placed the
        // surface resting and left the raise to this activation, which
        // is read as the launch and raises the way the launch would.
        XCTAssertEqual(
            BackdropAppDelegate.activationRaises(sinceLaunch: 0, claimedByAnotherWindow: false),
            BackdropAppDelegate.launchRaise
        )
        XCTAssertEqual(
            BackdropAppDelegate.activationRaises(sinceLaunch: 0.3, claimedByAnotherWindow: false),
            BackdropAppDelegate.launchRaise
        )
    }

    // MARK: Every later activation is the user choosing the app

    func testAnActivationAfterTheLaunchWindowRaisesAsAnActivation() {
        // The first real ⌘Tab, hours later or two seconds later, is the
        // user naming the app and not this surface, and the roll stays
        // where they left it.
        XCTAssertEqual(
            BackdropAppDelegate.activationRaises(
                sinceLaunch: BackdropAppDelegate.launchWindow, claimedByAnotherWindow: false
            ),
            .activation
        )
        XCTAssertEqual(
            BackdropAppDelegate.activationRaises(sinceLaunch: 3_600, claimedByAnotherWindow: false),
            .activation
        )
    }

    func testTheLaunchWindowIsRecencyNotACounter() {
        // A login item or a background launch never activates at all.
        // Had the launch's share been a skip-one counter it would have
        // read the first real ⌘Tab hours later as the launch and moved
        // the roll under the reader; as recency it has nothing left to
        // claim once the window has passed.
        XCTAssertEqual(
            BackdropAppDelegate.activationRaises(
                sinceLaunch: BackdropAppDelegate.launchWindow + 0.01, claimedByAnotherWindow: false
            ),
            .activation
        )
    }

    // MARK: About and Settings keep their claim

    func testAnActivationAnotherWindowAskedForDoesNotRaise() {
        // About and Settings activate the app for themselves; the
        // surface must not ride up with them, inside the launch window
        // or hours after it.
        XCTAssertNil(
            BackdropAppDelegate.activationRaises(sinceLaunch: 0.3, claimedByAnotherWindow: true)
        )
        XCTAssertNil(
            BackdropAppDelegate.activationRaises(sinceLaunch: 3_600, claimedByAnotherWindow: true)
        )
    }

    // MARK: The raise after a modal of ours

    func testAModalsReturnRaisesOverAStillRaisedSurface() {
        // The open panel, a file review, the rename prompt or a
        // cancelled quit: the surface was raised when it went up and
        // comes forward again once it is down.
        XCTAssertTrue(
            BackdropAppDelegate.raisesAfterModal(stance: .raised, modalSessionRunning: false)
        )
    }

    func testAModalsReturnDoesNotRaiseARestedSurface() {
        // A rest while the panel was up was somebody's deliberate act,
        // or the quit notice reached from a resting card's tray menu,
        // and neither is ours to undo.
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
}
