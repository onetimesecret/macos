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
        // Fail-closed: either signal saying "out of sight" is enough.
        // Refusing wrongly misroutes the press to the window underneath,
        // which the user can at least see; taking one wrongly acts on a
        // press in a surface nobody is being shown, which they cannot.
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

    // MARK: Which turn may write the gate

    func testAnyTurnMayOpenTheGate() {
        // The invariant everything else here is subordinate to: a card
        // the user can see answers clicks. A gate stuck shut is the
        // worst failure this feature can have, so no turn is ever
        // refused the opening.
        for turn in [SurfaceExposure.Turn.edge, .settling] {
            for isKey in [false, true] {
                XCTAssertTrue(
                    SurfaceExposure.writes(gate: false, from: turn, isKey: isKey),
                    "opening the gate must never be refused"
                )
            }
        }
    }

    func testTheSettlingTurnMayNotCloseTheGateOnAKeyedWindow() {
        // The raise's own gap: the card is ordered up over whatever was
        // covering it, and for a frame `occlusionState` still answers
        // with the pre-raise reading. Closing on that would pass the
        // user's next click to the app underneath, whereupon the
        // outside click monitor rests the card and the raise has undone
        // itself.
        XCTAssertFalse(SurfaceExposure.writes(gate: true, from: .settling, isKey: true))
    }

    func testTheSettlingTurnMayCloseTheGateOnAWindowThatIsNotKeyed() {
        // A pinned rest never takes the keyboard, and the settling read
        // is the only exposure judgment the pin gets.
        XCTAssertTrue(SurfaceExposure.writes(gate: true, from: .settling, isKey: false))
    }

    func testAnEdgeMayCloseTheGateOnAKeyedWindow() {
        // The window server volunteered the news this time, so the
        // reading is its own account of the present rather than a guess
        // taken a turn after an ordering. A keyed window really out of
        // sight is the worse fault of the two and earns no exemption.
        XCTAssertTrue(SurfaceExposure.writes(gate: true, from: .edge, isKey: true))
    }

    // MARK: The Space switch's re-readings

    func testTheSpaceSwitchIsReadPromptlyAndThenAgainOnceSettled() {
        // One reading is not enough. The notification arrives
        // mid-transition, where the server's answer describes the Space
        // being left, and a gate closed on that answer has no later edge
        // to reopen it: a window on every Space need not change its
        // occlusion because the user changed desktop.
        let reads = SurfaceExposure.spaceSettleReads
        XCTAssertEqual(reads.first, 0, "the prompt reading takes clicks off an absent card at once")
        XCTAssertGreaterThan(reads.count, 1, "a settled reading must follow the transient one")
        XCTAssertGreaterThanOrEqual(
            reads.last ?? 0, 0.5,
            "the last reading has to fall after the transition, animation included"
        )
        XCTAssertEqual(reads, reads.sorted(), "the settled reading is the last word")
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
