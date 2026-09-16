import CoreGraphics

/// Pure geometry for a sealed block after TextKit has resolved its usable measure.
enum SealedBlockLayout {
    struct Metrics: Equatable, Sendable {
        let width: CGFloat
        let height: CGFloat
        let cornerRadius: CGFloat
        let borderWidth: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
    }

    static func metrics(containerWidth: CGFloat) -> Metrics {
        Metrics(
            width: containerWidth,
            height: 52,
            cornerRadius: 8,
            borderWidth: 1,
            horizontalPadding: 12,
            verticalPadding: 8
        )
    }
}
