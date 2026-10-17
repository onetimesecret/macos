import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class WrappingGeometryTests: XCTestCase {
    private func makeTextView(ink: Bool = true) -> (
        NSTextView, NSTextStorage, InkLayoutManager, InkTextContainer
    ) {
        let storage = NSTextStorage()
        let layout = InkLayoutManager()
        let container = InkTextContainer(size: NSSize(
            width: 396, height: CGFloat.greatestFiniteMagnitude
        ))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let frame = NSRect(x: 20, y: 30, width: 420, height: 80)
        let text: NSTextView = ink
            ? InkTextView(frame: frame, textContainer: container)
            : NSTextView(frame: frame, textContainer: container)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = false
        text.autoresizingMask = []
        text.minSize = NSSize(width: 5, height: 7)
        text.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        text.textContainerInset = NSSize(width: 12, height: 8)
        return (text, storage, layout, container)
    }

    private func lineRanges(in layout: NSLayoutManager, container: NSTextContainer) -> [NSRange] {
        var ranges: [NSRange] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) {
            _, _, _, range, _ in ranges.append(range)
        }
        return ranges
    }

    func testInvalidEditorMeasuresDoNotReplaceAnExistingCapture() {
        let container = InkTextContainer(size: .zero)
        XCTAssertTrue(container.setEditorMeasure(396))
        for measure in [CGFloat(0), -1, .nan, .infinity, .greatestFiniteMagnitude] {
            XCTAssertFalse(container.setEditorMeasure(measure))
            XCTAssertEqual(container.capturedEditorMeasure, 396)
        }
    }
}
