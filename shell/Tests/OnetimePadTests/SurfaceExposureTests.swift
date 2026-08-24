import AppKit
import XCTest

@testable import OnetimePad

/// The exposure gate from issue #73: a surface the window server is not
/// showing must not act on a click. Tested as the pure decision it is,
/// the same way the stance split is; whether macOS reports a pinned card
/// over another app's full-screen Space as occluded is a hardware
/// question, and `docs/qa/verification-procedures/pinned-over-fullscreen.md`
/// is where it gets answered.
final class SurfaceExposureTests: XCTestCase {
    // MARK: The reading itself

    func testOnScreenAndUnobstructedIsDisplayed() {
        XCTAssertTrue(SurfaceExposure.displayed.isDisplayed)
    }

    func testASurfaceOnAnotherSpaceIsNotDisplayed() {
        XCTAssertFalse(
            SurfaceExposure(onActiveSpace: false, unoccluded: true).isDisplayed
        )
    }

    func testAWhollyCoveredSurfaceIsNotDisplayed() {
        // The full-screen case reaches the gate through this signal: the
        // window claims every Space, so it is on the active one by
        // definition, and only occlusion can report that nothing of it
        // is being composited there.
        XCTAssertFalse(
            SurfaceExposure(onActiveSpace: true, unoccluded: false).isDisplayed
        )
    }

    func testBothSignalsMustAgreeBeforeTheSurfaceCountsAsSeen() {
        // Fail-closed: either signal saying "out of sight" is enough,
        // because the cost of refusing a click wrongly is a raise that
        // does not happen, while the cost of taking one wrongly is a
        // press meant for another application acted on here.
        XCTAssertFalse(
            SurfaceExposure(onActiveSpace: false, unoccluded: false).isDisplayed
        )
    }

    // MARK: The gate over the stance's own rule

    func testAnInvisiblePinnedRestRefusesTheMouse() {
        // Issue #73 exactly: pinned, so the stance would take the mouse,
        // but nothing of the card is on screen, so the press belongs to
        // whatever the user was actually looking at.
        XCTAssertTrue(
            BackdropStance.resting.ignoresMouse(
                pinned: true,
                exposure: SurfaceExposure(onActiveSpace: true, unoccluded: false)
            )
        )
    }

    func testAVisiblePinnedRestStillTakesTheMouse() {
        // The gate is not allowed to quietly undo the pin: a card the
        // user can see keeps its one click, the one that means raise.
        XCTAssertFalse(
            BackdropStance.resting.ignoresMouse(pinned: true, exposure: .displayed)
        )
    }

    func testAnInvisibleRaisedEditorRefusesTheMouse() {
        // A keyed window that cannot be seen taking clicks is the worse
        // fault, so the raise gets no exemption from the gate.
        XCTAssertTrue(
            BackdropStance.raised.ignoresMouse(
                pinned: false,
                exposure: SurfaceExposure(onActiveSpace: false, unoccluded: true)
            )
        )
    }

    func testAVisibleRaisedEditorStillTakesTheMouse() {
        XCTAssertFalse(
            BackdropStance.raised.ignoresMouse(pinned: false, exposure: .displayed)
        )
    }

    func testExposureNeverGrantsTheMouseToAStanceThatRefusesIt() {
        // The gate is a one-way valve. The unpinned rest is transparent
        // by ADR-0015 whatever the window server reports, so no reading
        // of exposure may hand it a click.
        for exposure in [
            SurfaceExposure.displayed,
            SurfaceExposure(onActiveSpace: false, unoccluded: true),
            SurfaceExposure(onActiveSpace: true, unoccluded: false),
            SurfaceExposure(onActiveSpace: false, unoccluded: false),
        ] {
            XCTAssertTrue(
                BackdropStance.resting.ignoresMouse(pinned: false, exposure: exposure),
                "the unpinned rest must pass every click through, whatever is on screen"
            )
        }
    }

    func testAStanceOutOfSightIsAlwaysTransparent() {
        // The invariant the cases above are instances of: out of sight
        // is transparent, in every posture and either pin state.
        for stance in [BackdropStance.resting, .raised] {
            for pinned in [false, true] {
                XCTAssertTrue(
                    stance.ignoresMouse(
                        pinned: pinned,
                        exposure: SurfaceExposure(onActiveSpace: true, unoccluded: false)
                    ),
                    "a surface the user cannot see must never act on a press"
                )
            }
        }
    }
}
