import XCTest

@testable import OnetimePad

/// The launch's stance and the activation that follows it, tested as
/// the pure decisions they are (dogfood phase 4). Nothing here launches
/// anything or builds a model: that the surface is on screen after a
/// real launch is hardware knowledge and stays in the manual matrix.
/// What can be pinned is which raise the launch asks for and which
/// activations are read as the launch's own.
final class LaunchStanceTests: XCTestCase {
    // MARK: The launch raises, as a summon

    func testTheLaunchRaisesAsASummon() {
        // A person opening the app is coming to the pad, not back to a
        // sentence they left in an older day, so the launch takes the
        // raise that anchors the roll on today.
        XCTAssertEqual(BackdropAppDelegate.launchRaise, .summon)
        XCTAssertTrue(BackdropModel.anchorsOnToday(raise: BackdropAppDelegate.launchRaise))
    }

    // MARK: The activation that arrives moments after

    func testTheLaunchsOwnActivationDoesNotRaiseASecondTime() {
        // LaunchServices activates the app within moments of
        // `applicationDidFinishLaunching`. The launch has already
        // raised by then, and one act must not arrive as two raises.
        XCTAssertFalse(
            BackdropAppDelegate.activationRaises(sinceLaunch: 0.3, claimedByAnotherWindow: false)
        )
    }

    func testAnActivationAfterTheLaunchWindowRaises() {
        // The first real ⌘Tab, hours later or two seconds later, is the
        // user choosing this app and answers with a raise.
        XCTAssertTrue(
            BackdropAppDelegate.activationRaises(
                sinceLaunch: BackdropAppDelegate.launchWindow, claimedByAnotherWindow: false
            )
        )
        XCTAssertTrue(
            BackdropAppDelegate.activationRaises(sinceLaunch: 3_600, claimedByAnotherWindow: false)
        )
    }

    func testAnActivationAnotherWindowAskedForDoesNotRaise() {
        // About and Settings activate the app for themselves; the
        // surface must not ride up with them however long ago the app
        // launched.
        XCTAssertFalse(
            BackdropAppDelegate.activationRaises(sinceLaunch: 3_600, claimedByAnotherWindow: true)
        )
    }

    func testTheLaunchWindowIsRecencyNotACounter() {
        // A login item or a background launch may never activate at
        // all. Had the exemption been a skip-one counter it would have
        // swallowed the first real ⌘Tab hours later; as recency it has
        // nothing left to swallow once the window has passed.
        XCTAssertTrue(
            BackdropAppDelegate.activationRaises(
                sinceLaunch: BackdropAppDelegate.launchWindow + 0.01, claimedByAnotherWindow: false
            )
        )
    }
}
