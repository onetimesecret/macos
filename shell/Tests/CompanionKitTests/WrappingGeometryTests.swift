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

    func testConfigurationLeavesViewAndScrollerSizingToTheCaller() {
        for ink in [true, false] {
            for wraps in [false, true] {
                let (text, storage, _, container) = makeTextView(ink: ink)
                let scroll = InkEditorView.bareScroller()
                scroll.frame.size = NSSize(width: 640, height: 480)
                scroll.hasHorizontalScroller = true
                let stack = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 1_000))
                scroll.documentView = stack
                stack.addSubview(text)
                let frame = text.frame
                let minimum = text.minSize
                let maximum = text.maxSize
                let scroller = scroll.hasHorizontalScroller

                InkEditorView.configureWrapping(wraps, textView: text, viewportWidth: 420)

                XCTAssertEqual(text.frame, frame)
                XCTAssertEqual(text.minSize, minimum)
                XCTAssertEqual(text.maxSize, maximum)
                XCTAssertFalse(text.isHorizontallyResizable)
                XCTAssertFalse(text.isVerticallyResizable)
                XCTAssertEqual(text.autoresizingMask, [])
                XCTAssertEqual(scroll.hasHorizontalScroller, scroller)
                XCTAssertTrue(scroll.documentView === stack)
                XCTAssertEqual(container.widthTracksTextView, wraps)
                XCTAssertEqual(container.size.width, wraps ? 396 : .greatestFiniteMagnitude)
                XCTAssertEqual(container.size.height, .greatestFiniteMagnitude)
                XCTAssertEqual(container.capturedEditorMeasure, 396)
                withExtendedLifetime(storage) {}
            }
        }
    }

    func testUnwrappedUsedRectCanExceedAManuallySizedEditor() {
        for ink in [true, false] {
            let (text, storage, layout, container) = makeTextView(ink: ink)
            storage.setAttributedString(NSAttributedString(
                string: String(repeating: "a long line of ordinary text ", count: 60),
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]
            ))
            let frame = text.frame
            InkEditorView.configureWrapping(true, textView: text, viewportWidth: 420)
            layout.ensureLayout(for: container)
            let wrapped = layout.usedRect(for: container)
            let wrappedLines = lineRanges(in: layout, container: container)
            XCTAssertLessThanOrEqual(wrapped.width, 396)

            InkEditorView.configureWrapping(false, textView: text, viewportWidth: 420)
            layout.ensureLayout(for: container)
            let unwrapped = layout.usedRect(for: container)
            XCTAssertGreaterThan(unwrapped.width, frame.width)
            XCTAssertLessThan(unwrapped.height, wrapped.height)
            XCTAssertEqual(text.frame, frame)

            InkEditorView.configureWrapping(true, textView: text, viewportWidth: 420)
            layout.ensureLayout(for: container)
            XCTAssertLessThanOrEqual(layout.usedRect(for: container).width, 396)
            XCTAssertEqual(lineRanges(in: layout, container: container), wrappedLines)
            XCTAssertEqual(layout.usedRect(for: container).height, wrapped.height, accuracy: 0.5)
            XCTAssertEqual(text.frame, frame)
            withExtendedLifetime(storage) {}
        }
    }

    func testUnwrappedViewportResizeRemeasuresAttachmentsWithoutGrowingTheirContainer() {
        let (text, storage, layout, container) = makeTextView()
        storage.setAttributedString(InkEditorView.Coordinator.chipString(ChipInfo(
            chipId: 7, kind: "text", excerpt: "to…en", sizeLabel: "small", concealed: false
        )))
        let frame = text.frame
        for viewport in [CGFloat(420), 300, 540] {
            InkEditorView.configureWrapping(false, textView: text, viewportWidth: viewport)
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: 0)
            let measure = viewport - text.textContainerInset.width * 2
            XCTAssertEqual(container.size.width, .greatestFiniteMagnitude)
            XCTAssertEqual(container.capturedEditorMeasure, measure)
            XCTAssertEqual(
                layout.attachmentSize(forGlyphAt: glyph).width,
                floor(measure - container.lineFragmentPadding * 2), accuracy: 0.5
            )
            XCTAssertEqual(text.frame, frame)
        }
        withExtendedLifetime(storage) {}
    }

    func testBlockLabelsUseTheVisibleViewportWithAnUnwrappedContainer() {
        let (text, storage, _, container) = makeTextView()
        InkEditorView.configureWrapping(false, textView: text, viewportWidth: 420)
        let visible = NSRect(x: 200, y: 0, width: 420, height: 80)
        let measure = InkEditorView.Coordinator.blockAffordanceMeasure(
            containerWidth: container.size.width, visibleRect: visible,
            containerOriginX: text.textContainerOrigin.x
        )
        let origin = InkEditorView.Coordinator.blockAffordanceOrigin(
            firstLine: .zero, containerWidth: measure, containerOrigin: text.textContainerOrigin,
            affordanceSize: NSSize(width: 90, height: 20)
        )
        XCTAssertEqual(origin.x + 90 + InkEditorView.Coordinator.blockLabelTrailingInset, visible.maxX)
        XCTAssertTrue(measure.isFinite)
        withExtendedLifetime(storage) {}
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
