import CoreGraphics

/// Geometry shared by sealed-object drawing, hit tests, and the inline name editor.
enum SealedBlockLayout {
    static let height: CGFloat = 52
    static let minimumWidth: CGFloat = 340
    static let maximumWidth: CGFloat = 560
    static let controlHeight: CGFloat = 24
    static let controlGap: CGFloat = 6
    static let copyWidth: CGFloat = 108

    static func preferredHeight(identityLineHeight: CGFloat) -> CGFloat {
        max(height, ceil(identityLineHeight) + 48)
    }

    static func preferredWidth(available: CGFloat, identityWidth: CGFloat) -> CGFloat {
        min(max(0, available), max(minimumWidth, min(maximumWidth, ceil(identityWidth) + 24)))
    }

    static func actionsRect(in frame: CGRect) -> CGRect {
        CGRect(x: max(frame.minX, frame.maxX - 36), y: frame.maxY - 32,
               width: min(controlHeight, frame.width), height: controlHeight)
    }

    static func copyRect(in frame: CGRect) -> CGRect? {
        let more = actionsRect(in: frame)
        let rect = CGRect(x: more.minX - controlGap - copyWidth, y: more.minY,
                          width: copyWidth, height: controlHeight)
        return rect.minX >= frame.minX + 12 ? rect : nil
    }

    static func moveRect(in frame: CGRect, before neighbourMinX: CGFloat) -> CGRect? {
        let rect = CGRect(x: neighbourMinX - controlGap - controlHeight,
                          y: actionsRect(in: frame).minY,
                          width: controlHeight, height: controlHeight)
        return rect.minX >= frame.minX + 12 ? rect : nil
    }

    struct Metrics: Equatable, Sendable {
        let width: CGFloat
        let horizontalPadding: CGFloat
        let pillRadius: CGFloat
    }

    static func copiesNameValue(kind: String) -> Bool { kind == "text" }

    struct NamedRow: Equatable, Sendable {
        let name: CGRect
        let equals: CGRect
        let value: CGRect
    }

    static func rowAllotment(
        available: CGFloat, name: CGFloat, equals: CGFloat, value: CGFloat,
        nameFloor: CGFloat
    ) -> (name: CGFloat, value: CGFloat) {
        let room = max(0, available)
        guard name + equals + value > room else { return (name, value) }
        let nameRoom = max(0, room - equals)
        let preferredName = min(name, nameRoom, max(nameFloor, nameRoom * 0.65))
        let valueWidth = max(0, min(value, nameRoom - preferredName))
        let nameWidth = min(name, max(0, nameRoom - valueWidth))
        return (nameWidth, max(0, min(value, nameRoom - nameWidth)))
    }

    static func metrics(containerWidth: CGFloat) -> Metrics {
        Metrics(width: containerWidth, horizontalPadding: 12, pillRadius: 4)
    }
}
