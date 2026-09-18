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
        // can resolve behind it — invisible on a bare desktop. The
        // altitude for the unpinned resting stance is the desktop case,
        // and its level is `backdropDesktop`; the arithmetic is stated
        // once, on the extension.
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .resting, keyed: false, pinned: false, keepsAbove: false
            ).level.rawValue,
            Int(CGWindowLevelForKey(.desktopWindow)) + 1
        )
    }

    func testRestingStaysBelowTheDesktopIcons() {
        XCTAssertLessThan(
            BackdropAltitude.resolve(
                stance: .resting, keyed: false, pinned: false, keepsAbove: false
            ).level.rawValue,
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
            BackdropStance.resting.collectionBehavior(altitude: .desktop),
            [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        )
    }

    func testRestingRepaintsCoarsely() {
        // Always on screen, so frugality lives in the cadence: one
        // repaint every 30 s at a glance, never a 1 Hz idle tick.
        XCTAssertEqual(BackdropStance.resting.tickInterval, 30)
    }

    // MARK: Raised — the panel model, borrowed for the moment of editing

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
        // A raise that holds the keyboard floats, and so does a pinned
        // or keep above one.
        XCTAssertEqual(
            BackdropStance.raised.collectionBehavior(altitude: .floating),
            [.canJoinAllSpaces, .fullScreenAuxiliary]
        )
    }

    func testARaisedCardThatDroppedToNormalLeavesFullScreenSpaces() {
        // Issue 184, ADR-0034. An auxiliary window is shown with the
        // full screen window whatever its level, so a raised card that
        // had yielded the keyboard and dropped to normal was still drawn
        // over the full screen app the person had switched to. At normal
        // it declines those Spaces, as an ordinary window does.
        XCTAssertEqual(
            BackdropStance.raised.collectionBehavior(altitude: .normal),
            [.canJoinAllSpaces, .fullScreenNone]
        )
    }

    // MARK: The pin, a resting altitude (plus the click that undoes it)

    func testAPinnedRestFloatsAboveNormalWindows() {
        // The pin's whole purpose is to keep the card above other apps,
        // so the resolver returns floating for the pinned resting case
        // whatever else is asked (`BackdropAltitudeTests` holds the full
        // matrix).
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .resting, keyed: false, pinned: true, keepsAbove: false
            ).level,
            .floating
        )
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
            BackdropStance.resting.collectionBehavior(altitude: .floating),
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
            BackdropStance.resting.collectionBehavior(altitude: .floating).contains(.stationary)
        )
        XCTAssertTrue(
            BackdropStance.resting.collectionBehavior(altitude: .desktop).contains(.stationary)
        )
    }

    // MARK: Spaces — one membership, held through every posture

    func testEveryPostureClaimsEverySpace() {
        // The fix for the ⌘Tab return landing on Desktop 1 (issue #74,
        // ADR-0019): a window bound to the Space it was created on drags
        // the user back there whenever the app is activated, because the
        // window server switches Spaces to reveal the app's windows.
        for (stance, altitude) in Self.everyCell {
            XCTAssertTrue(
                stance.collectionBehavior(altitude: altitude).contains(.canJoinAllSpaces),
                "a posture bound to one Space pulls the user back to it on activation"
            )
        }
    }

    /// All six stance by altitude cells. Two are unreachable today (a
    /// rest never resolves to normal, a raise never to desktop), and
    /// the rule still owes each of them an answer that breaks nothing.
    private static let everyCell: [(BackdropStance, BackdropAltitude)] =
        [BackdropStance.resting, .raised].flatMap { stance in
            [BackdropAltitude.desktop, .normal, .floating].map { (stance, $0) }
        }

    func testTheFullStanceByAltitudeMatrix() {
        // Written out cell by cell, so a regression names the cell it
        // broke. Resting adds `.ignoresCycle`, desktop adds
        // `.stationary`, and the full screen bit is read from the
        // altitude alone (ADR-0034).
        let expected: [(BackdropStance, BackdropAltitude, NSWindow.CollectionBehavior)] = [
            (.resting, .desktop, [.canJoinAllSpaces, .ignoresCycle, .stationary, .fullScreenNone]),
            (.resting, .normal, [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone]),
            (.resting, .floating, [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]),
            (.raised, .desktop, [.canJoinAllSpaces, .stationary, .fullScreenNone]),
            (.raised, .normal, [.canJoinAllSpaces, .fullScreenNone]),
            (.raised, .floating, [.canJoinAllSpaces, .fullScreenAuxiliary]),
        ]
        for (stance, altitude, behavior) in expected {
            XCTAssertEqual(
                stance.collectionBehavior(altitude: altitude), behavior,
                "stance=\(stance) altitude=\(altitude)"
            )
        }
    }

    func testTheReachableStatesKeepTheBehaviorTheyHadBeforeTheRuleMoved() {
        // The three literals the stance used to state by hand, reached
        // through the resolver from the inputs that produce them. Only
        // the raised, keyless, unpinned, preference off state is new.
        func behavior(
            _ stance: BackdropStance, keyed: Bool, pinned: Bool, keepsAbove: Bool
        ) -> NSWindow.CollectionBehavior {
            stance.collectionBehavior(
                altitude: BackdropAltitude.resolve(
                    stance: stance, keyed: keyed, pinned: pinned, keepsAbove: keepsAbove
                )
            )
        }
        XCTAssertEqual(
            behavior(.resting, keyed: false, pinned: false, keepsAbove: false),
            [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        )
        XCTAssertEqual(
            behavior(.resting, keyed: false, pinned: true, keepsAbove: false),
            [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        )
        for (keyed, pinned, keepsAbove) in [
            (true, false, false), (true, true, false), (false, true, false),
            (false, false, true), (true, false, true),
        ] {
            XCTAssertEqual(
                behavior(.raised, keyed: keyed, pinned: pinned, keepsAbove: keepsAbove),
                [.canJoinAllSpaces, .fullScreenAuxiliary],
                "keyed=\(keyed) pinned=\(pinned) keepsAbove=\(keepsAbove)"
            )
        }
        XCTAssertEqual(
            behavior(.raised, keyed: false, pinned: false, keepsAbove: false),
            [.canJoinAllSpaces, .fullScreenNone]
        )
    }

    func testNoPostureChangeAsksForAReassignment() {
        // The flicker half of the same issue: the membership bits are
        // what the window server reads to decide which Space a window
        // lives on, and writing different ones on a stance flip is a
        // move between Spaces, seen as a blink. Every stance at every
        // altitude must name the same membership, so no summon, rest,
        // pin or key transition can ask for one. The key transitions
        // are the new writers (ADR-0034), which is why all six cells
        // are held to it and not only the reachable ones.
        let memberships = Set(
            Self.everyCell.map { stance, altitude in
                stance.spaceMembership(altitude: altitude).rawValue
            }
        )
        XCTAssertEqual(memberships, [NSWindow.CollectionBehavior.canJoinAllSpaces.rawValue])
    }

    func testFullScreenParticipationVariesWhileMembershipDoesNot() {
        // Full screen participation follows altitude, not stance
        // (ADR-0034): the auxiliary bit is present exactly when the
        // altitude is floating. A card at desktop level in another
        // app's full screen room could only ever be an invisible one,
        // and a card at normal level there is drawn over the app the
        // person has just switched to (issue 184), so both decline
        // those Spaces. This decides whether such a Space is joined at
        // all, not which desktop the window sits on, and membership,
        // the invariant above, stays put either way.
        for (stance, altitude) in Self.everyCell {
            let behavior = stance.collectionBehavior(altitude: altitude)
            XCTAssertEqual(
                behavior.contains(.fullScreenAuxiliary), altitude == .floating,
                "stance=\(stance) altitude=\(altitude)"
            )
            XCTAssertEqual(
                behavior.contains(.fullScreenNone), altitude != .floating,
                "stance=\(stance) altitude=\(altitude)"
            )
            XCTAssertEqual(
                stance.spaceMembership(altitude: altitude), [.canJoinAllSpaces],
                "stance=\(stance) altitude=\(altitude)"
            )
        }
    }

    func testExactlyOneFullScreenBitIsEverSet() {
        // AppKit's header allows at most one of primary, auxiliary and
        // none, and the issue 73 lesson is that a combination nothing
        // defines gets an answer nothing defines. Naming none of them
        // would leave the choice to a default, so the rule always names
        // one. The surface is never a full screen window of its own and
        // never tiles, so primary and the tiling bits stay clear.
        let fullScreenBits: [NSWindow.CollectionBehavior] = [
            .fullScreenPrimary, .fullScreenAuxiliary, .fullScreenNone,
        ]
        let neverSet: NSWindow.CollectionBehavior = [
            .fullScreenPrimary, .fullScreenAllowsTiling, .fullScreenDisallowsTiling,
        ]
        for (stance, altitude) in Self.everyCell {
            let behavior = stance.collectionBehavior(altitude: altitude)
            let set = fullScreenBits.filter { behavior.contains($0) }
            XCTAssertEqual(set.count, 1, "stance=\(stance) altitude=\(altitude)")
            XCTAssertTrue(
                behavior.isDisjoint(with: neverSet), "stance=\(stance) altitude=\(altitude)"
            )
        }
    }

    // MARK: The summon's round trip, the safety net that used to blink

    func testASurfaceStrandedOnAnotherSpaceIsRoundTripped() {
        // The case the net exists for: a window up on a Space the user
        // has left would take the keyboard out of sight. It is still
        // reachable, all-Spaces membership notwithstanding, because the
        // unpinned rest declines full-screen Spaces: summoned from
        // another app's full-screen room, the card is visible on the
        // desktops and not on the Space in front of the user.
        XCTAssertTrue(
            BackdropStance.requiresSpaceRoundTrip(visible: true, onActiveSpace: false)
        )
    }

    func testASurfaceAlreadyHereIsNeverRoundTripped() {
        // Which is every summon between desktops, since a window on all
        // of them is on whichever one the user is looking at. The blink
        // this used to cost on each ⌘Tab back is the flicker of issue
        // #74.
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

    // MARK: What a raise is for, which is not the same on both routes

    /// The roll goes back to today when the user names the surface, and
    /// stays where the reader left it when they merely name the app
    /// (issue #79, ADR-0020 item 13). A ⌘Tab return re-keys the card
    /// without being a summon, and moving the roll under somebody who
    /// came back to the sentence they were reading is the one thing the
    /// anchor must never do.
    func testOnlyASummonTakesTheRollBackToToday() {
        XCTAssertTrue(BackdropModel.anchorsOnToday(raise: .summon))
        XCTAssertFalse(
            BackdropModel.anchorsOnToday(raise: .activation),
            "⌘Tab, the app switcher and the Dock name the app, not this surface"
        )
    }

    // MARK: The desktop level is genuinely below normal windows

    func testDesktopLevelSitsBelowNormalWindows() {
        XCTAssertLessThan(NSWindow.Level.backdropDesktop.rawValue, NSWindow.Level.normal.rawValue)
    }

    // MARK: The crossing between the two stances (D-02)

    func testStanceFadeIsOneHundredSixtyMilliseconds() {
        XCTAssertEqual(BackdropStance.stanceFadeDuration(reduceMotion: false), 0.16)
    }

    func testReduceMotionZeroesTheStanceFade() {
        // The end state is the same either way; only the crossing
        // goes, so a person who asked for less motion sees the card
        // arrive in the frame the stance changes.
        XCTAssertEqual(BackdropStance.stanceFadeDuration(reduceMotion: true), 0)
    }

    /// The seam the view reads through, driven here without touching
    /// the accessibility preference of the machine the test runs on.
    @MainActor
    func testTheViewReadsTheSystemSettingThroughTheSeam() {
        let before = BackdropStance.reduceMotionPreferred
        defer { BackdropStance.reduceMotionPreferred = before }
        BackdropStance.reduceMotionPreferred = { true }
        XCTAssertEqual(BackdropStance.currentStanceFadeDuration(), 0)
        BackdropStance.reduceMotionPreferred = { false }
        XCTAssertEqual(BackdropStance.currentStanceFadeDuration(), 0.16)
    }
}
