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
///
/// The card carries a real height, the way a window does. It began as a
/// floor under the editor while the card grew downward with its ink,
/// which reads well for one page of ink and badly for everything the
/// parity work added: a tab strip, a ledger, and an inline promotion
/// all need the card to be a fixed frame with a scrolling page inside
/// it, not a shape that changes size as the page fills.
struct BackdropGeometry: Codable, Equatable {
    /// The card's top-leading corner, offset from the pane's own
    /// top-leading corner. Both components are non-negative once
    /// clamped: the card never hangs off the pane.
    var origin: CGPoint

    /// The card's width.
    var width: CGFloat

    /// The card's height, chrome included.
    var height: CGFloat

    /// Today's layout: the 48 pt pin that was `.padding(48)`, the
    /// 640 pt column, and a height matching the editor floor and
    /// chrome the card shipped with.
    static let `default` = BackdropGeometry(
        origin: CGPoint(x: 48, y: 48),
        width: 640,
        height: 316
    )

    // MARK: Bounds

    /// Narrower than this and the countdown header starts to wrap; a
    /// glance surface must stay readable at a glance.
    static let minWidth: CGFloat = 360

    /// Shorter than this and the header, the page, and the tab strip
    /// stop fitting together: the card's equivalent of the panel
    /// window's 300 pt floor.
    static let minHeight: CGFloat = 260

    /// There is no fixed ceiling. A window may be dragged as large as
    /// its screen, and the card is being sized like a window; the pane
    /// is the only limit, applied by the clamp below. (The 900 × 600
    /// ceilings the card shipped with were a reading-measure argument
    /// from when it held exactly one page of ink.)

    // MARK: The clamp

    /// The one decision, pure: given a pane, return the nearest
    /// geometry that keeps the card readable, bounded, and fully on
    /// the pane. Absolute minimums apply first, then the pane's own
    /// limits, so a tiny pane may force the card below its readable
    /// minimum rather than push any of it off screen. A degenerate
    /// pane (zero, or smaller than any sensible card) collapses the
    /// geometry gracefully to whatever fits, never below zero and
    /// never through a crash.
    ///
    /// The pane is a rect, not a size: the window spans the whole
    /// screen, but the menu bar and Dock own strips of it that a
    /// floating card cannot outrank. A card allowed under the menu bar
    /// keeps its header where no click can reach it, so the usable
    /// region the clamp confines to starts below that strip.
    func clamped(to pane: CGRect) -> BackdropGeometry {
        // Raw components, not the rect accessors: CGRect normalizes a
        // negative size (`width` turns absolute, `minX` shifts), which
        // would quietly promote a degenerate pane to a real one.
        let paneWidth = max(0, pane.size.width)
        let paneHeight = max(0, pane.size.height)

        let fitWidth = min(max(width, Self.minWidth), paneWidth)
        let fitHeight = min(max(height, Self.minHeight), paneHeight)

        let x = min(max(origin.x, pane.origin.x), pane.origin.x + max(0, paneWidth - fitWidth))
        let y = min(max(origin.y, pane.origin.y), pane.origin.y + max(0, paneHeight - fitHeight))

        return BackdropGeometry(
            origin: CGPoint(x: x, y: y),
            width: fitWidth,
            height: fitHeight
        )
    }

    /// The whole-pane clamp, for a pane with nothing carved out of it.
    func clamped(to paneSize: CGSize) -> BackdropGeometry {
        clamped(to: CGRect(origin: .zero, size: paneSize))
    }
}

// MARK: Persistence

extension BackdropGeometry {
    /// One key, one JSON blob: the whole geometry travels together, so
    /// a partial write can never leave origin and width disagreeing.
    static let defaultsKey = "backdrop.geometry"

    /// The card's non-editor height, approximately: the header row and
    /// the padding around the whole. Only used to read a geometry
    /// written before the card had a real height.
    private static let legacyChromeHeight: CGFloat = 96

    private enum CodingKeys: String, CodingKey {
        case origin, width, height
        case minEditorHeight
    }

    /// A geometry written by the editor-floor layout still decodes: its
    /// `minEditorHeight` plus the chrome that sat around it is the
    /// height it was actually drawing. Without this the first launch
    /// after the change would silently reset a card the user had
    /// placed, which is the sort of small betrayal that makes a person
    /// stop trusting a tool with placement at all.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        origin = try container.decode(CGPoint.self, forKey: .origin)
        width = try container.decode(CGFloat.self, forKey: .width)
        if let stored = try container.decodeIfPresent(CGFloat.self, forKey: .height) {
            height = stored
        } else {
            let floor = try container.decode(CGFloat.self, forKey: .minEditorHeight)
            height = floor + Self.legacyChromeHeight
        }
    }

    /// Written in the current shape only: the legacy key is something
    /// this type reads, never something it writes back.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin, forKey: .origin)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }

    /// Read the stored geometry, or fall back to the default. A
    /// missing key or an unreadable blob resolves the same way: the
    /// card appears where it always has.
    static func load(from defaults: UserDefaults) -> BackdropGeometry {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let stored = try? JSONDecoder().decode(BackdropGeometry.self, from: data)
        else { return .default }
        return stored
    }

    /// Write this geometry to the defaults. Encoding a value of fixed
    /// shape does not fail in practice; if it somehow did, keeping the
    /// previous stored value is strictly better than storing garbage.
    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
