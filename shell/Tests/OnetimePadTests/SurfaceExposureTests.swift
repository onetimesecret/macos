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
        // A raised window that cannot be seen taking clicks is the worse
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
            for raised in [false, true] {
                XCTAssertTrue(
                    SurfaceExposure.writes(gate: false, from: turn, raised: raised),
                    "opening the gate must never be refused"
                )
            }
        }
    }

    func testTheSettlingTurnMayNotCloseTheGateOnARaisedSurface() {
        // The raise's own gap: the card is ordered up over whatever was
        // covering it, and for a frame `occlusionState` still answers
        // with the pre-raise reading. Closing on that would pass the
        // user's next click to the app underneath, whereupon the
        // outside click monitor rests the card and the raise has undone
        // itself.
        XCTAssertFalse(SurfaceExposure.writes(gate: true, from: .settling, raised: true))
    }

    func testTheSettlingTurnMayCloseTheGateOnASurfaceThatIsNotRaised() {
        // A pinned rest is never in front by its own stance, and the
        // settling read is the only exposure judgment the pin gets.
        XCTAssertTrue(SurfaceExposure.writes(gate: true, from: .settling, raised: false))
    }

    func testAnEdgeMayCloseTheGateOnARaisedSurface() {
        // The window server volunteered the news this time, so the
        // reading is its own account of the present rather than a guess
        // taken a turn after an ordering. A raised card really out of
        // sight is the worse fault of the two and earns no exemption.
        XCTAssertTrue(SurfaceExposure.writes(gate: true, from: .edge, raised: true))
    }

    // MARK: A transition's re-readings

    func testATransitionIsReadPromptlyAndThenAgainOnceSettled() {
        // One reading is not enough. The notification arrives
        // mid-transition, where the server's answer describes the Space
        // being left, and a gate closed on that answer has no later edge
        // to reopen it: a window on every Space need not change its
        // occlusion because the user changed desktop.
        let reads = SurfaceExposure.settleReads
        XCTAssertEqual(
            reads.first?.delay, 0, "the prompt reading takes clicks off an absent card at once"
        )
        XCTAssertGreaterThan(reads.count, 1, "a settled reading must follow the transient one")
        XCTAssertGreaterThanOrEqual(
            reads.last?.delay ?? 0, 0.5,
            "the last reading has to fall after the transition, animation included"
        )
        XCTAssertEqual(
            reads.map(\.delay), reads.map(\.delay).sorted(),
            "the settled reading is the last word"
        )
    }

    func testThePromptReadingOfATransitionCannotCloseTheGateOnARaisedSurface() {
        // The prompt reading lands mid-transition, where the server
        // describes the state being left. On a freshly raised card that
        // answer can say "not here" about a card the user is looking at,
        // and a gate closed there passes the next click underneath,
        // whereupon the outside click monitor rests the card. It is
        // taken as a settling turn for exactly that reason.
        let prompt = SurfaceExposure.settleReads.first
        XCTAssertEqual(prompt?.turn, .settling)
        XCTAssertFalse(
            SurfaceExposure.writes(gate: true, from: prompt?.turn ?? .edge, raised: true),
            "a mid-transition answer must not take the clicks off a card the stance puts in front"
        )
    }

    func testTheSettledReadingOfATransitionDecidesEvenOverARaisedSurface() {
        // The counterweight: once the transition is certainly over the
        // server is describing where it arrived, and a raised card that
        // is genuinely out of sight has to stop taking clicks.
        let settled = SurfaceExposure.settleReads.last
        XCTAssertEqual(settled?.turn, .edge)
        XCTAssertTrue(
            SurfaceExposure.writes(gate: true, from: settled?.turn ?? .settling, raised: true)
        )
    }

    func testWakeAndSessionReturnAreReadTheSameWayASpaceSwitchIs() {
        // A card that came back from sleep or from the lock screen
        // refusing clicks would go on refusing them until the user
        // happened to change desktop, since neither wake nor a session
        // hand-back tells the window anything about itself.
        XCTAssertTrue(
            SurfaceExposure.settleTriggers.contains(NSWorkspace.activeSpaceDidChangeNotification)
        )
        XCTAssertTrue(
            SurfaceExposure.settleTriggers.contains(NSWorkspace.screensDidWakeNotification)
        )
        XCTAssertTrue(
            SurfaceExposure.settleTriggers.contains(NSWorkspace.sessionDidBecomeActiveNotification)
        )
    }

    // MARK: The raise's own re-reading

    func testTheRaiseSchedulesAReadingThatCanCloseTheGateOnItself() {
        // A card raised while it was already wholly covered reads
        // occluded before the raise and occluded after it, so no
        // occlusion change is posted and no edge arrives. The settling
        // turn the raise takes may not close the gate on a raised surface,
        // which leaves this reading as the only thing that ever can.
        let read = SurfaceExposure.raiseSettleRead
        XCTAssertGreaterThanOrEqual(
            read.delay, 0.5, "the reading has to fall after the raise has landed"
        )
        XCTAssertEqual(read.turn, .edge)
        XCTAssertTrue(
            SurfaceExposure.writes(gate: true, from: read.turn, raised: true),
            "an occluded raised card must end up refusing the mouse, not merely start out doing so"
        )
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
