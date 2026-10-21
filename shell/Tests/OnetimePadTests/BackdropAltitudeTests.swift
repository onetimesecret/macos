import AppKit
import XCTest

@testable import OnetimePad

/// The altitude resolver as the pure decision ADR-0032 states: stance,
/// key status, pin and keep-above go in; one of three window facts
/// comes out. The matrix is written out row by row rather than looped,
/// because a hand-run hardware check reads down a table more easily
/// than it reads a nested for-loop and because a regression that only
/// touches one row is easier to fault when the row is named.
final class BackdropAltitudeTests: XCTestCase {

    // MARK: Resting

    func testRestingUnpinnedKeylessPrefOffIsDesktop() {
        // The wallpaper-adjacent posture: no pin lifting it, no
        // preference asking for lift, and no keys pulling it up either.
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .resting, keyed: false, pinned: false, keepsAbove: false
            ),
            .desktop
        )
    }

    func testRestingUnpinnedKeylessPrefOnIsDesktop() {
        // Keep-above is a raised-time preference: it lifts a raised but
        // keyless surface, not a resting one. A resting card at
        // floating level would be a wallpaper that steals clicks (mouse
        // transparency is per-window; see the stance suite), and the
        // pin exists precisely for the reader who wants that.
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .resting, keyed: false, pinned: false, keepsAbove: true
            ),
            .desktop
        )
    }

    func testRestingUnpinnedKeyedPrefOffIsDesktop() {
        // A resting surface never actually holds the keyboard
        // (`BackdropStance.acceptsKey` is false), so this row is
        // unreachable in practice, but the resolver still owes an
        // answer, and the rule that governs it (unpinned rest is
        // furniture) gives desktop.
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .resting, keyed: true, pinned: false, keepsAbove: false
            ),
            .desktop
        )
    }

    func testRestingUnpinnedKeyedPrefOnIsDesktop() {
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .resting, keyed: true, pinned: false, keepsAbove: true
            ),
            .desktop
        )
    }

    func testRestingPinnedKeylessPrefOffIsFloating() {
        // The pin is the promise: keep the card above other apps
        // whether or not the person is typing into it.
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .resting, keyed: false, pinned: true, keepsAbove: false
            ),
            .floating
        )
    }

    func testRestingPinnedKeylessPrefOnIsFloating() {
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .resting, keyed: false, pinned: true, keepsAbove: true
            ),
            .floating
        )
    }

    func testRestingPinnedKeyedPrefOffIsFloating() {
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .resting, keyed: true, pinned: true, keepsAbove: false
            ),
            .floating
        )
    }

    func testRestingPinnedKeyedPrefOnIsFloating() {
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .resting, keyed: true, pinned: true, keepsAbove: true
            ),
            .floating
        )
    }

    // MARK: Raised

    func testRaisedUnpinnedKeylessPrefOffIsNormal() {
        // The point of the whole change: a raised surface that has
        // lost the keyboard to another app must not stand between the
        // person and the window they are working in.
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .raised, keyed: false, pinned: false, keepsAbove: false
            ),
            .normal
        )
    }

    func testRaisedUnpinnedKeylessPrefOnIsFloating() {
        // The keep-above preference: a raised card that stays above
        // other apps even while it waits for its keys back, for the
        // person who wants the pad watching over the shoulder of what
        // they are doing.
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .raised, keyed: false, pinned: false, keepsAbove: true
            ),
            .floating
        )
    }

    func testRaisedUnpinnedKeyedPrefOffIsFloating() {
        // Actively typed into: the card floats. The preference is
        // moot here because the keyboard is already keeping it up.
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .raised, keyed: true, pinned: false, keepsAbove: false
            ),
            .floating
        )
    }

    func testRaisedUnpinnedKeyedPrefOnIsFloating() {
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .raised, keyed: true, pinned: false, keepsAbove: true
            ),
            .floating
        )
    }

    func testRaisedPinnedKeylessPrefOffIsFloating() {
        // Pinned wins over everything else in the matrix.
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .raised, keyed: false, pinned: true, keepsAbove: false
            ),
            .floating
        )
    }

    func testRaisedPinnedKeylessPrefOnIsFloating() {
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .raised, keyed: false, pinned: true, keepsAbove: true
            ),
            .floating
        )
    }

    func testRaisedPinnedKeyedPrefOffIsFloating() {
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .raised, keyed: true, pinned: true, keepsAbove: false
            ),
            .floating
        )
    }

    func testRaisedPinnedKeyedPrefOnIsFloating() {
        XCTAssertEqual(
            BackdropAltitude.resolve(
                stance: .raised, keyed: true, pinned: true, keepsAbove: true
            ),
            .floating
        )
    }

    // MARK: The window levels the three cases resolve to

    func testDesktopLevelIsOneAboveTheWallpaper() {
        XCTAssertEqual(
            BackdropAltitude.desktop.level.rawValue,
            Int(CGWindowLevelForKey(.desktopWindow)) + 1
        )
    }

    func testNormalLevelIsTheOrdinaryWindowLevel() {
        XCTAssertEqual(BackdropAltitude.normal.level, .normal)
    }

    func testFloatingLevelSitsAboveOrdinaryWindows() {
        XCTAssertEqual(BackdropAltitude.floating.level, .floating)
        XCTAssertGreaterThan(
            BackdropAltitude.floating.level.rawValue,
            NSWindow.Level.normal.rawValue
        )
    }

    // MARK: Full screen participation follows altitude (ADR-0034)

    func testOnlyAFloatingSurfaceJoinsFullScreenSpaces() {
        // An auxiliary window is shown with the full screen window
        // whatever its level, so a card at normal that kept the bit was
        // drawn over the full screen app it had just yielded to (issue
        // 184). Normal and desktop decline, as ordinary windows do.
        XCTAssertTrue(BackdropAltitude.floating.joinsFullScreenSpaces)
        XCTAssertFalse(BackdropAltitude.normal.joinsFullScreenSpaces)
        XCTAssertFalse(BackdropAltitude.desktop.joinsFullScreenSpaces)
    }

    func testARaisedCardLeavesFullScreenSpacesOnlyWhenItYieldsToOtherApps() {
        // The one state that drops out: raised, keyless, unpinned and
        // with the preference off. Every other raised row floats and
        // follows the person into a full screen Space.
        for keyed in [false, true] {
            for pinned in [false, true] {
                for keepsAbove in [false, true] {
                    let joins = BackdropAltitude.resolve(
                        stance: .raised, keyed: keyed, pinned: pinned, keepsAbove: keepsAbove
                    ).joinsFullScreenSpaces
                    XCTAssertEqual(
                        joins, keyed || pinned || keepsAbove,
                        "keyed=\(keyed) pinned=\(pinned) keepsAbove=\(keepsAbove)"
                    )
                }
            }
        }
    }

    // MARK: A key companion window lowers the card (ADR-0032 Amendment 1, #293)

    /// Every stance × pin × preference row with a companion window
    /// (Settings, About, Send Feedback) holding the keyboard, so the
    /// card itself keyless. The expected altitude is stated per row
    /// rather than derived so a regression names the row it broke.
    func testAKeyCompanionLowersEveryFloatingRowToNormal() {
        let cases:
            [(stance: BackdropStance, pinned: Bool, keepsAbove: Bool, altitude: BackdropAltitude)] =
                [
                    // Unpinned rest: furniture stays on the desktop,
                    // already below the companion.
                    (.resting, false, false, .desktop),
                    (.resting, false, true, .desktop),
                    // Pinned rest: the pin would float the card over
                    // the companion, so the card gives way.
                    (.resting, true, false, .normal),
                    (.resting, true, true, .normal),
                    // Keyless raise, preference off: normal already.
                    (.raised, false, false, .normal),
                    // Keyless raise, preference on: the preference
                    // would float it over the companion.
                    (.raised, false, true, .normal),
                    // Pinned raise: pin and preference both give way.
                    (.raised, true, false, .normal),
                    (.raised, true, true, .normal),
                ]
        for c in cases {
            XCTAssertEqual(
                BackdropAltitude.resolve(
                    stance: c.stance, keyed: false, pinned: c.pinned,
                    keepsAbove: c.keepsAbove, companionKeyed: true
                ),
                c.altitude,
                "stance=\(c.stance) pinned=\(c.pinned) keepsAbove=\(c.keepsAbove)"
            )
        }
    }

    func testTheCardsOwnKeysWinOverAKeyCompanion() {
        // A raise is committed with `keyed: true` while the companion
        // it takes the keyboard from still reports key; the summon
        // must not flash at normal for that frame.
        for pinned in [false, true] {
            for keepsAbove in [false, true] {
                XCTAssertEqual(
                    BackdropAltitude.resolve(
                        stance: .raised, keyed: true, pinned: pinned,
                        keepsAbove: keepsAbove, companionKeyed: true
                    ),
                    .floating,
                    "pinned=\(pinned) keepsAbove=\(keepsAbove)"
                )
            }
        }
    }

}
