import AppKit
import XCTest

@testable import OnetimePad

/// The stance split, tested as the pure decision it is — the shell's
/// pattern for UI-adjacent logic: test the decision itself, never mock
/// AppKit. The window plumbing that applies it (ordering, key status,
/// the mouse pass-through) is hand-tested per the project's rules
/// (docs/spec/feature/background-surface, hardware checklist).
final class BackdropStanceTests: XCTestCase {
    // MARK: Resting — a passive pane behind everything

    func testRestingSitsJustAboveTheWallpapersOwnLevel() {
        // One above, not at: the wallpaper image is itself a window at
        // the desktop level, and a surface parked at that same level
        // can resolve behind it — invisible on a bare desktop.
        XCTAssertEqual(
            BackdropStance.resting.level(pinned: false).rawValue,
            Int(CGWindowLevelForKey(.desktopWindow)) + 1
        )
    }

    func testRestingStaysBelowTheDesktopIcons() {
        XCTAssertLessThan(
            BackdropStance.resting.level(pinned: false).rawValue,
            Int(CGWindowLevelForKey(.desktopIconWindow))
        )
    }

    func testRestingLetsClicksFallThroughToTheDesktop() {
        XCTAssertTrue(BackdropStance.resting.ignoresMouse(pinned: false))
    }

    func testRestingSpansTheWholePane() {
        // Desktop furniture covers the desktop; mouse transparency
        // makes the acreage free.
        XCTAssertTrue(BackdropStance.resting.spansPane(pinned: false))
    }

    func testRestingRefusesTheKeyboardOutright() {
        // A background surface that could silently receive keystrokes
        // would be a keylogger-shaped bug.
        XCTAssertFalse(BackdropStance.resting.acceptsKey)
    }

    func testRestingIsDesktopFurnitureAcrossSpaces() {
        XCTAssertEqual(
            BackdropStance.resting.collectionBehavior(pinned: false),
            [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        )
    }

    func testRestingRepaintsCoarsely() {
        // Always on screen, so frugality lives in the cadence: one
        // repaint every 30 s at a glance, never a 1 Hz idle tick.
        XCTAssertEqual(BackdropStance.resting.tickInterval, 30)
    }

    // MARK: Raised — the panel model, borrowed for the moment of editing

    func testRaisedFloats() {
        XCTAssertEqual(BackdropStance.raised.level(pinned: false), .floating)
    }

    func testRaisedTakesTheMouse() {
        XCTAssertFalse(BackdropStance.raised.ignoresMouse(pinned: false))
        XCTAssertFalse(BackdropStance.raised.ignoresMouse(pinned: true))
    }

    func testRaisedHugsTheCard() {
        // The raise takes the mouse, so its window must be exactly the
        // card. A pane-wide window that took clicks would swallow every
        // press aimed past the card, which is how the click-outside
        // catcher this replaces stranded the keyboard: the surface
        // rested, but the app the user clicked never activated. The pin
        // does not change it either way.
        XCTAssertFalse(BackdropStance.raised.spansPane(pinned: false))
        XCTAssertFalse(BackdropStance.raised.spansPane(pinned: true))
    }

    func testEveryStanceThatTakesTheMouseHugsTheCard() {
        // The invariant the two postures above are instances of: mouse
        // transparency is decided per window at the window server, so
        // window extent is the only thing that keeps a click-taking
        // surface from owning the whole screen.
        for pinned in [false, true] {
            for stance in [BackdropStance.resting, .raised] where !stance.ignoresMouse(pinned: pinned) {
                XCTAssertFalse(
                    stance.spansPane(pinned: pinned),
                    "a stance that takes the mouse must not span the pane"
                )
            }
        }
    }

    func testRaisedMayTakeTheKeyboard() {
        XCTAssertTrue(BackdropStance.raised.acceptsKey)
    }

    func testRaisedEarnsTheOneHertzTick() {
        XCTAssertEqual(BackdropStance.raised.tickInterval, 1)
    }

    func testRaisedFollowsTheUserToTheActiveSpace() {
        // A surface that holds the keyboard must be visible where the
        // user is looking, full-screen Spaces included. It gets there by
        // being on every Space already rather than by being moved onto
        // this one, so that no summon costs a reassignment (issue #74).
        XCTAssertEqual(
            BackdropStance.raised.collectionBehavior(pinned: false),
            [.canJoinAllSpaces, .fullScreenAuxiliary]
        )
    }

    // MARK: The pin, a resting altitude (plus the click that undoes it)

    func testAPinnedRestFloatsAboveNormalWindows() {
        XCTAssertEqual(BackdropStance.resting.level(pinned: true), .floating)
    }

    func testAPinnedRestTakesTheMouseButNeverTheKeyboard() {
        // A floating card that stayed mouse-transparent would route
        // clicks into the window it covers, where the user cannot see
        // them land: the click-through trap. So the pinned rest takes
        // the mouse (a click means "raise", nothing else), while the
        // keyboard refusal stands; keys still belong to the window the
        // user is writing in.
        XCTAssertFalse(BackdropStance.resting.ignoresMouse(pinned: true))
        XCTAssertFalse(BackdropStance.resting.acceptsKey)
    }

    func testAPinnedRestHugsTheCard() {
        // Taking the mouse is safe only because the window shrinks to
        // the card: mouse transparency is per-window, so a full-pane
        // window that took clicks would block the whole screen.
        XCTAssertFalse(BackdropStance.resting.spansPane(pinned: true))
    }

    func testAPinnedRestIsReadableOnEverySpace() {
        // The pin exists to keep the card in view while the user
        // writes elsewhere, full-screen apps included; a pin that
        // vanished on a Space switch would fail its one purpose.
        XCTAssertEqual(
            BackdropStance.resting.collectionBehavior(pinned: true),
            [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        )
    }

    func testAPinnedRestIsAnOverlayRatherThanFurniture() {
        // `.stationary` belongs to the wallpaper recipe the unpinned
        // rest is built from. Carried into the pin it asked the window
        // server for a combination nothing documents, and over another
        // app's full-screen Space the answer was a card kept in the
        // hit-test path but never drawn (issue #73).
        XCTAssertFalse(
            BackdropStance.resting.collectionBehavior(pinned: true).contains(.stationary)
        )
        XCTAssertTrue(
            BackdropStance.resting.collectionBehavior(pinned: false).contains(.stationary)
        )
    }

    func testThePinLeavesARaisedSurfaceAlone() {
        XCTAssertEqual(BackdropStance.raised.level(pinned: true), .floating)
        XCTAssertEqual(
            BackdropStance.raised.collectionBehavior(pinned: true),
            [.canJoinAllSpaces, .fullScreenAuxiliary]
        )
    }

    // MARK: Spaces — one membership, held through every posture

    func testEveryPostureClaimsEverySpace() {
        // The fix for the ⌘Tab return landing on Desktop 1 (issue #74,
        // ADR-0019): a window bound to the Space it was created on drags
        // the user back there whenever the app is activated, because the
        // window server switches Spaces to reveal the app's windows.
        for stance in [BackdropStance.resting, .raised] {
            for pinned in [false, true] {
                XCTAssertTrue(
                    stance.collectionBehavior(pinned: pinned).contains(.canJoinAllSpaces),
                    "a posture bound to one Space pulls the user back to it on activation"
                )
            }
        }
    }

    func testNoPostureChangeAsksForAReassignment() {
        // The flicker half of the same issue: the membership bits are
        // what the window server reads to decide which Space a window
        // lives on, and writing different ones on a stance flip is a
        // move between Spaces, seen as a blink. Every posture must name
        // the same membership, so no summon, rest or pin can ask for
        // one.
        let memberships = Set(
            [BackdropStance.resting, .raised].flatMap { stance in
                [false, true].map { stance.spaceMembership(pinned: $0).rawValue }
            }
        )
        XCTAssertEqual(memberships, [NSWindow.CollectionBehavior.canJoinAllSpaces.rawValue])
    }

    func testOnlyFullScreenParticipationVariesByPosture() {
        // The one deliberate exception: a desktop-level card in another
        // app's full-screen room could only ever be an invisible one, so
        // the unpinned rest declines those Spaces while the pin and the
        // raise accept them. This decides whether such a Space is joined
        // at all, not which desktop the window sits on.
        XCTAssertTrue(
            BackdropStance.resting.collectionBehavior(pinned: false).contains(.fullScreenNone)
        )
        XCTAssertTrue(
            BackdropStance.resting.collectionBehavior(pinned: true).contains(.fullScreenAuxiliary)
        )
        XCTAssertTrue(
            BackdropStance.raised.collectionBehavior(pinned: false).contains(.fullScreenAuxiliary)
        )
    }

    // MARK: The summon's round trip, the safety net that used to blink

    func testASurfaceStrandedOnAnotherSpaceIsRoundTripped() {
        // The one case the net exists for: a window up on a Space the
        // user has left would take the keyboard out of sight.
        XCTAssertTrue(
            BackdropStance.requiresSpaceRoundTrip(visible: true, onActiveSpace: false)
        )
    }

    func testASurfaceAlreadyHereIsNeverRoundTripped() {
        // Which is now every case, since a window on all Spaces is on
        // the active one by definition. The blink this used to cost on
        // each ⌘Tab back is the flicker of issue #74.
        XCTAssertFalse(
            BackdropStance.requiresSpaceRoundTrip(visible: true, onActiveSpace: true)
        )
    }

    func testAnUnshownSurfaceIsNeverRoundTripped() {
        // Nothing to order out, and ordering out a window that is not up
        // would be a second way to lose the summon.
        XCTAssertFalse(
            BackdropStance.requiresSpaceRoundTrip(visible: false, onActiveSpace: false)
        )
        XCTAssertFalse(
            BackdropStance.requiresSpaceRoundTrip(visible: false, onActiveSpace: true)
        )
    }

    // MARK: The summon decision — a summon first, a dismissal last

    func testSummonRaisesARestingSurface() {
        XCTAssertEqual(
            BackdropModel.stanceAfterSummon(current: .resting, holdsKeys: false),
            .raised
        )
    }

    func testSummonRekeysARaisedSurfaceThatLostTheKeyboard() {
        // Raised but keyboard-less — the user worked beside the card —
        // summons the keys back; it does NOT read as "put it away".
        XCTAssertEqual(
            BackdropModel.stanceAfterSummon(current: .raised, holdsKeys: false),
            .raised
        )
    }

    func testSummonRestsOnlyARaisedSurfaceHoldingTheKeyboard() {
        XCTAssertEqual(
            BackdropModel.stanceAfterSummon(current: .raised, holdsKeys: true),
            .resting
        )
    }

    // MARK: The desktop level is genuinely below normal windows

    func testDesktopLevelSitsBelowNormalWindows() {
        XCTAssertLessThan(NSWindow.Level.backdropDesktop.rawValue, NSWindow.Level.normal.rawValue)
    }
}
