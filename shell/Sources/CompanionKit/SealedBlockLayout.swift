import CoreGraphics

/// Pure geometry for a sealed block after TextKit has resolved its usable measure.
///
/// Every number a sealed block is drawn with lives here, so the block's
/// shape can be argued about in tests rather than read out of a drawing
/// routine. The drawing code asks for metrics and places things; it
/// invents no constants of its own.
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
            lockSize: 9
        )
    }
}
