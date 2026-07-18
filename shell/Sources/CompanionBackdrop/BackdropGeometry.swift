import CoreGraphics
import Foundation

/// Where the card sits and how much room it takes, as pure numbers
/// within the full-screen pane (docs/spec/feature/background-surface,
/// issue #33). The pane itself never moves or shrinks; only the card's
/// offset and measure inside it change, so the resting surface stays
/// mouse-transparent no matter where the card is parked. All the
/// judgement lives in `clamped(to:)`, a window-free function the tests
/// can interrogate directly, in the shell's pattern of testing the
/// decision rather than mocking AppKit.
struct BackdropGeometry: Codable, Equatable {
    /// The card's top-leading corner, offset from the pane's own
    /// top-leading corner. Both components are non-negative once
    /// clamped: the card never hangs off the pane.
    var origin: CGPoint

    /// The card's width. The card grows downward with its ink, so
    /// width is the one horizontal measure the user can set.
    var width: CGFloat

    /// The floor under the editor's height. Not the card's full
    /// height: the header and padding add their own chrome, and the
    /// ink may push past this floor on its own.
    var minEditorHeight: CGFloat

    /// Today's layout, verbatim: the 48 pt pin that was `.padding(48)`,
    /// the 640 pt column, the 220 pt editor floor.
    static let `default` = BackdropGeometry(
        origin: CGPoint(x: 48, y: 48),
        width: 640,
        minEditorHeight: 220
    )

    // MARK: Bounds

    /// Narrower than this and the countdown header starts to wrap; a
    /// glance surface must stay readable at a glance.
    static let minWidth: CGFloat = 360

    /// Wider than this and the card stops being a card. The pane clamp
    /// still applies on top, so a small display wins over this ceiling.
    static let maxWidth: CGFloat = 900

    /// The least editor worth having: a few visible lines, never a
    /// sliver.
    static let minReadableEditorHeight: CGFloat = 160

    /// Taller than this and the "card on a desktop" reading gives way
    /// to a full-screen slab, which the backdrop deliberately is not.
    static let maxEditorHeight: CGFloat = 600

    /// The card's non-editor height, approximately: the header row and
    /// the padding around the whole. An estimate is enough here; the
    /// clamp only needs a reasonable card extent to keep the whole of
    /// it within reach of the pane, not a pixel-perfect one.
    static let cardChromeHeight: CGFloat = 96

    // MARK: The clamp

    /// The one decision, pure: given a pane, return the nearest
    /// geometry that keeps the card readable, bounded, and fully on
    /// the pane. Absolute bounds apply first, then the pane's own
    /// limits, so a tiny pane may force the card below its readable
    /// minimum rather than push any of it off screen. A degenerate
    /// pane (zero, or smaller than any sensible card) collapses the
    /// geometry gracefully to whatever fits, never below zero and
    /// never through a crash.
    func clamped(to paneSize: CGSize) -> BackdropGeometry {
        let paneWidth = max(0, paneSize.width)
        let paneHeight = max(0, paneSize.height)

        let boundedWidth = min(max(width, Self.minWidth), Self.maxWidth)
        let fitWidth = min(boundedWidth, paneWidth)

        let boundedEditor = min(
            max(minEditorHeight, Self.minReadableEditorHeight),
            Self.maxEditorHeight
        )
        let fitEditor = min(boundedEditor, max(0, paneHeight - Self.cardChromeHeight))

        // The card's estimated extent, for keeping the whole of it on
        // the pane. When even that exceeds the pane, the origin pins
        // to the top-leading corner and the overflow is the pane's
        // problem, not a crash.
        let cardHeight = fitEditor + Self.cardChromeHeight
        let x = min(max(origin.x, 0), max(0, paneWidth - fitWidth))
        let y = min(max(origin.y, 0), max(0, paneHeight - cardHeight))

        return BackdropGeometry(
            origin: CGPoint(x: x, y: y),
            width: fitWidth,
            minEditorHeight: fitEditor
        )
    }
}

// MARK: Persistence

extension BackdropGeometry {
    /// The backdrop's own defaults suite, and only the backdrop's.
    /// ADR-0010: the backdrop and the panel are separate programs that
    /// merely rhyme; this is never CompanionApp's standard domain, and
    /// nothing in it is shared across the target line.
    static let defaultsSuiteName = "com.onetimesecret.companion.backdrop"

    /// One key, one JSON blob: the whole geometry travels together, so
    /// a partial write can never leave origin and width disagreeing.
    static let defaultsKey = "geometry"

    /// Read the stored geometry, or fall back to the default. A
    /// missing suite, a missing key, or an unreadable blob all resolve
    /// the same way: the card appears where it always has.
    static func load(from defaults: UserDefaults?) -> BackdropGeometry {
        guard
            let data = defaults?.data(forKey: defaultsKey),
            let stored = try? JSONDecoder().decode(BackdropGeometry.self, from: data)
        else { return .default }
        return stored
    }

    /// Write this geometry to the suite. Encoding a value of fixed
    /// shape does not fail in practice; if it somehow did, keeping the
    /// previous stored value is strictly better than storing garbage.
    func save(to defaults: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.defaultsKey)
    }
}
