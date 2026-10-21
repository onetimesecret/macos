import AppKit
import CoreGraphics

/// Which edge or corner of the card a resize drag is pulling, and what
/// that pull means. A window can be resized from any side; sizing the
/// card like a window means eight grips, and eight ways one translation
/// turns into a new geometry.
///
/// Pure, like `BackdropGeometry.clamped(to:)` beside it: the decision is
/// tested directly rather than by driving AppKit. The clamp still has
/// the last word; this only says what the user asked for.
enum CardEdge: CaseIterable {
    case top, bottom, leading, trailing
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// The pointer a window shows over this margin: macOS 15's frame
    /// cursors on every grip, and before 15 the axis arrows on edges
    /// with the plain arrow on corners, as windows showed then.
    var resizeCursor: NSCursor? {
        if #available(macOS 15, *) {
            return .frameResize(position: frameResizePosition, directions: .all)
        }
        switch self {
        case .leading, .trailing: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing: return nil
        }
    }

    /// The frame position this grip's cursor names.
    @available(macOS 15, *)
    var frameResizePosition: NSCursor.FrameResizePosition {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .left
        case .trailing: return .right
        case .topLeading: return .topLeft
        case .topTrailing: return .topRight
        case .bottomLeading: return .bottomLeft
        case .bottomTrailing: return .bottomRight
        }
    }

    /// Whether this grip moves the card's leading edge, which changes
    /// the origin as well as the width.
    private var movesLeading: Bool {
        switch self {
        case .leading, .topLeading, .bottomLeading: true
        default: false
        }
    }

    private var movesTrailing: Bool {
        switch self {
        case .trailing, .topTrailing, .bottomTrailing: true
        default: false
        }
    }

    /// Whether this grip moves the card's top edge, which changes the
    /// origin as well as the height.
    private var movesTop: Bool {
        switch self {
        case .top, .topLeading, .topTrailing: true
        default: false
        }
    }

    private var movesBottom: Bool {
        switch self {
        case .bottom, .bottomLeading, .bottomTrailing: true
        default: false
        }
    }

    /// The geometry this pull proposes.
    ///
    /// A leading or top pull moves two things at once, the origin and
    /// the measure, so the pull is capped at the point where the card
    /// would cross its minimum. Without the cap, dragging the top edge
    /// past the floor would keep walking the origin down while the
    /// clamp held the height, and the card would slide away from a
    /// pointer that is only asking it to stop shrinking.
    func resized(_ geometry: BackdropGeometry, by translation: CGSize) -> BackdropGeometry {
        var result = geometry
        if movesLeading {
            let dx = min(translation.width, geometry.width - BackdropGeometry.minWidth)
            result.origin.x += dx
            result.width -= dx
        }
        if movesTrailing {
            result.width = max(BackdropGeometry.minWidth, geometry.width + translation.width)
        }
        if movesTop {
            let dy = min(translation.height, geometry.height - BackdropGeometry.minHeight)
            result.origin.y += dy
            result.height -= dy
        }
        if movesBottom {
            result.height = max(BackdropGeometry.minHeight, geometry.height + translation.height)
        }
        return result
    }
}
