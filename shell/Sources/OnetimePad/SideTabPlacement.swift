import Foundation
import CoreGraphics

enum SideTabEdge: String, CaseIterable, Codable {
    case left
    case right
}

struct SideTabDisplay: Equatable {
    let id: String
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
}

enum SideTabPlacement {
    static let width: CGFloat = 16
    static let height: CGFloat = 64
    static let cornerClearance: CGFloat = 24

    /// A normalized position runs from the usable top (0) to the usable bottom (1).
    static func frame(
        displayID: String?, edge: SideTabEdge, position: Double, displays: [SideTabDisplay]
    ) -> CGRect? {
        guard let displayID, let display = displays.first(where: { $0.id == displayID }),
              valid(display.frame), valid(display.visibleFrame),
              display.frame.contains(display.visibleFrame),
              display.visibleFrame.width >= width,
              display.visibleFrame.height >= height + 2 * cornerClearance else { return nil }

        let visible = display.visibleFrame
        switch edge {
        case .left:
            guard visible.minX == display.frame.minX else { return nil }
        case .right:
            guard visible.maxX == display.frame.maxX else { return nil }
        }

        let fraction = position.isFinite ? min(1, max(0, position)) : 0.5
        let bottom = (visible.minY + cornerClearance).rounded(.up)
        let top = (visible.maxY - cornerClearance - height).rounded(.down)
        guard top >= bottom else { return nil }
        let target = CGRect(
            x: edge == .left ? visible.minX.rounded(.up) : (visible.maxX - width).rounded(.down),
            y: (top - CGFloat(fraction) * (top - bottom)).rounded(),
            width: width, height: height
        )
        guard visible.contains(target) else { return nil }
        let outside = CGRect(
            x: edge == .left ? display.frame.minX - 1 : display.frame.maxX,
            y: target.minY, width: 1, height: height
        )
        guard !displays.contains(where: { other in
            other.id != display.id && valid(other.frame)
                && (overlaps(target, other.frame) || overlaps(outside, other.frame))
        }) else { return nil }
        return target
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.size.width > 0 && rect.size.height > 0
    }

    private static func overlaps(_ first: CGRect, _ second: CGRect) -> Bool {
        let shared = first.intersection(second)
        return !shared.isNull && shared.width > 0 && shared.height > 0
    }
}
