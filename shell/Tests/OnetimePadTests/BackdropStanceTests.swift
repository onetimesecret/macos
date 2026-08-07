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
            [.stationary, .ignoresCycle, .fullScreenNone]
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
        // user is looking — full-screen Spaces included.
        XCTAssertEqual(
            BackdropStance.raised.collectionBehavior(pinned: false),
            [.moveToActiveSpace, .fullScreenAuxiliary]
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
            [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        )
    }

    func testThePinLeavesARaisedSurfaceAlone() {
        XCTAssertEqual(BackdropStance.raised.level(pinned: true), .floating)
        XCTAssertEqual(
            BackdropStance.raised.collectionBehavior(pinned: true),
            [.moveToActiveSpace, .fullScreenAuxiliary]
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
