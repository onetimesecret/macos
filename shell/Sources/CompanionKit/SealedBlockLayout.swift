import CoreGraphics

/// Pure geometry for a sealed block after TextKit has resolved its usable measure.
///
/// Every length a sealed block is drawn with lives here, so the block's
/// shape can be argued about in tests rather than read out of a drawing
/// routine. The drawing code asks for metrics and places things; it
/// invents no geometry of its own. Type faces, kerning and ink alphas
/// are the drawing code's, since they colour the block rather than
/// shape it.
enum SealedBlockLayout {
    /// A block is a fixed slab: its height is the same whatever measure
    /// the container offers, which is why it stands apart from `Metrics`
    /// and needs no container width to be asked for.
    static let height: CGFloat = 52

    struct Metrics: Equatable, Sendable {
        let width: CGFloat
        let height: CGFloat
        let cornerRadius: CGFloat
        let borderWidth: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        /// How far the block's top edge sits above the text baseline it
        /// is anchored to. TextKit wants the offset as a negative origin,
        /// which `blockBounds` builds from this.
        let baselineOffset: CGFloat
        /// The seat for the actions glyph on the classification's row:
        /// its size, and the drop from the block's top edge that puts it
        /// optically level with the classification rather than flush
        /// with the padding.
        let actionsWidth: CGFloat
        let actionsHeight: CGFloat
        let actionsTopInset: CGFloat
        /// The selection keyline sits just outside the border, drawn as
        /// a soft halo under the border's own stroke.
        let selectionRingInset: CGFloat
        let selectionRingWidth: CGFloat
        /// The second row's distance up from the block's bottom edge,
        /// where the excerpt and the size class sit.
        let bottomRowInset: CGFloat
        /// The lock badge, square, opening the top row.
        let lockSize: CGFloat
        /// The lock's drop below the top row. The glyph is a point
        /// lighter at its top than the classification's capitals, so
        /// flush with the row it floats; one point down it reads level.
        let lockTopNudge: CGFloat
        /// The breath between the lock and the classification.
        let lockToLabelGap: CGFloat
        /// The size class is set in a smaller face than the excerpt it
        /// shares a row with; dropped a point it sits on the excerpt's
        /// visual baseline rather than above it.
        let metadataBaselineNudge: CGFloat
        /// The least the excerpt keeps clear of the size class. The
        /// block is a fixed measure while the excerpt is the core's
        /// head and tail, so at a narrow measure the excerpt is cut at
        /// this gap rather than run under the size class.
        let excerptTrailingGap: CGFloat
        /// The pill under a hovered zone of a named row (sealed row spec, Hover pill and seat words):
        /// its height and radius, and how far it runs past its run each side.
        let pillHeight: CGFloat
        let pillRadius: CGFloat
        let pillOverhang: CGFloat
        /// What the `=` zone takes from the runs beside it, each side.
        let equalsSlop: CGFloat
        /// The two handles on the top row (sealed row spec, The handles): each one's clearance
        /// from its neighbour and from the classification, and its glyph's inset from its edge.
        let handleGap: CGFloat
        let handleInset: CGFloat
    }

    /// A zone of a named object's bottom row (Law 0001; sealed row spec, Zones).
    enum Zone: Equatable, Sendable, CaseIterable {
        case name
        case equals
        case value
    }

    /// Whether an object of `kind` copies `NAME=value`: text alone, as
    /// the core composes it (Law 0001, `=` zone row; core interface, `NAME=value`).
    static func copiesNameValue(kind: String) -> Bool {
        kind == "text"
    }

    /// Where a named row's three runs stand and what the pointer finds
    /// there, in the coordinates the block is drawn in.
    struct NamedRow: Equatable, Sendable {
        let name: CGRect
        let equals: CGRect
        let value: CGRect
        /// The band a zone answers in: the block's lower half.
        let band: CGRect
        let metrics: Metrics
        /// Whether `=` is a zone; false on an object that copies no `NAME=value`.
        let copiesNameValue: Bool
        /// Whether the value is a zone; false where the value is on another device (ADR-0058 point 4).
        let copiesValue: Bool

        /// The name and value zones are their runs; the `=` zone is its
        /// glyph and `equalsSlop` either side, taken from those runs.
        func zone(at point: CGPoint) -> Zone? {
            guard point.y >= band.minY, point.y < band.maxY else { return nil }
            let slop = metrics.equalsSlop
            if copiesNameValue, point.x >= equals.minX - slop, point.x < equals.maxX + slop {
                return .equals
            }
            if point.x >= name.minX, point.x < name.maxX { return .name }
            if copiesValue, point.x >= value.minX, point.x < value.maxX { return .value }
            return nil
        }

        /// The pill under `zone`, `pillOverhang` past its run each side;
        /// over `=` one pill spans the line, name to value.
        func pill(for zone: Zone) -> CGRect {
            let runs: (CGRect, CGRect) = switch zone {
            case .name: (name, name)
            case .equals: (name, value)
            case .value: (value, value)
            }
            let overhang = metrics.pillOverhang
            return CGRect(
                x: runs.0.minX - overhang,
                y: name.midY - metrics.pillHeight / 2,
                width: runs.1.maxX - runs.0.minX + overhang * 2,
                height: metrics.pillHeight
            )
        }
    }

    /// How wide a named row's name and value may be drawn in `available` points:
    /// the name gives way first, down to `nameFloor`, then the value (sealed row spec, Row).
    static func rowAllotment(
        available: CGFloat, name: CGFloat, equals: CGFloat, value: CGFloat,
        nameFloor: CGFloat
    ) -> (name: CGFloat, value: CGFloat) {
        let room = max(0, available)
        guard name + equals + value > room else { return (name, value) }
        let floor = min(name, max(0, nameFloor))
        let nameWidth = min(name, max(floor, room - equals - value))
        guard nameWidth + equals <= room else { return (max(0, room - equals), 0) }
        return (nameWidth, min(value, room - nameWidth - equals))
    }

    /// The measure the excerpt may run to before its tail is cut: the
    /// content column less the size class, which is drawn at its own
    /// measured width against the trailing inset, less the gap that
    /// keeps the two apart. Never negative, so a block too narrow for
    /// both draws no excerpt rather than one placed off the row.
    static func excerptWidth(containerWidth: CGFloat, metadataWidth: CGFloat) -> CGFloat {
        let metrics = metrics(containerWidth: containerWidth)
        return max(
            0,
            metrics.width - metrics.horizontalPadding * 2 - metadataWidth
                - metrics.excerptTrailingGap
        )
    }

    static func metrics(containerWidth: CGFloat) -> Metrics {
        Metrics(
            width: containerWidth,
            height: height,
            cornerRadius: 8,
            borderWidth: 1,
            horizontalPadding: 12,
            verticalPadding: 8,
            baselineOffset: 4,
            actionsWidth: 22,
            actionsHeight: 16,
            actionsTopInset: 6,
            selectionRingInset: 1,
            selectionRingWidth: 3,
            bottomRowInset: 24,
            lockSize: 9,
            lockTopNudge: 1,
            lockToLabelGap: 5,
            metadataBaselineNudge: 1,
            excerptTrailingGap: 8,
            pillHeight: 15,
            pillRadius: 4,
            pillOverhang: 3,
            equalsSlop: 2,
            handleGap: 8,
            handleInset: 5
        )
    }
}
