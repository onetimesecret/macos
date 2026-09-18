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

    // MARK: The keyless helper — what companion windows read

    func testKeylessMatchesResolveWithKeyedFalse() {
        // Every stance × pin × preference row, judged both ways: the
        // helper is the resolver with `keyed: false`, and nothing else.
        for stance in [BackdropStance.resting, .raised] {
            for pinned in [false, true] {
                for keepsAbove in [false, true] {
                    XCTAssertEqual(
                        BackdropAltitude.keylessAltitude(
                            stance: stance, pinned: pinned, keepsAbove: keepsAbove
                        ),
                        BackdropAltitude.resolve(
                            stance: stance, keyed: false,
                            pinned: pinned, keepsAbove: keepsAbove
                        )
                    )
                }
            }
        }
    }

    // MARK: The companion mapping — desktop collapses to normal

    func testCompanionLevelPromotesDesktopToNormal() {
        // A titled companion window (Settings, About) parked below the
        // icons could resolve behind the wallpaper as easily as the
        // surface can, so the desktop case reads as normal there. The
        // other two cases carry through unchanged.
        XCTAssertEqual(BackdropAltitude.desktop.companionLevel, .normal)
        XCTAssertEqual(BackdropAltitude.normal.companionLevel, .normal)
        XCTAssertEqual(BackdropAltitude.floating.companionLevel, .floating)
    }

    func testCompanionLevelForKeylessInputs() {
        // The two states a companion window actually reads together:
        // an unpinned resting surface hands the companion the normal
        // level (desktop lifted), while a pinned or keep-above raise
        // hands it floating.
        XCTAssertEqual(
            BackdropAltitude.keylessAltitude(
                stance: .resting, pinned: false, keepsAbove: false
            ).companionLevel,
            .normal
        )
        XCTAssertEqual(
            BackdropAltitude.keylessAltitude(
                stance: .resting, pinned: true, keepsAbove: false
            ).companionLevel,
            .floating
        )
        XCTAssertEqual(
            BackdropAltitude.keylessAltitude(
                stance: .raised, pinned: false, keepsAbove: true
            ).companionLevel,
            .floating
        )
        XCTAssertEqual(
            BackdropAltitude.keylessAltitude(
                stance: .raised, pinned: false, keepsAbove: false
            ).companionLevel,
            .normal
        )
    }

    /// Every stance × pin × preference row a companion window (Settings,
    /// About) can read the surface in, taken end-to-end from
    /// `keylessAltitude` through `companionLevel`. The expected level
    /// is stated per row rather than derived so a regression names the
    /// row it broke; the table is short enough to read as one.
    func testKeylessCompanionLevelMatrix() {
        let cases:
            [(stance: BackdropStance, pinned: Bool, keepsAbove: Bool, level: NSWindow.Level)] = [
                // An unpinned resting surface with the preference off:
                // Settings sits at normal, above nothing in particular.
                (.resting, false, false, .normal),
                // Same, preference on: keep-above lifts a raise, not
                // a rest; the companion sees the resting answer and
                // holds at normal.
                (.resting, false, true, .normal),
                // Pinned rest: the pin lifts the surface to floating,
                // so the companion has to float too or the pin would
                // hide it.
                (.resting, true, false, .floating),
                (.resting, true, true, .floating),
                // Keyless raise, preference off: the raised surface
                // has dropped to normal, and the companion sits at
                // normal beside it.
                (.raised, false, false, .normal),
                // Keyless raise, preference on: the raise floats
                // above other apps, and the companion has to too.
                (.raised, false, true, .floating),
                // Pinned raise: pin wins whatever the preference does.
                (.raised, true, false, .floating),
                (.raised, true, true, .floating),
            ]
        for c in cases {
            XCTAssertEqual(
                BackdropAltitude.keylessAltitude(
                    stance: c.stance, pinned: c.pinned, keepsAbove: c.keepsAbove
                ).companionLevel,
                c.level,
                "stance=\(c.stance) pinned=\(c.pinned) keepsAbove=\(c.keepsAbove)"
            )
        }
    }
}
