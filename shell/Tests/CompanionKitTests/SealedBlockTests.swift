import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class SealedBlockTests: XCTestCase {
    private func chip() -> ChipInfo {
        ChipInfo(
            chipId: 7,
            kind: "text",
            excerpt: "sk-live-…9Qz",
            sizeLabel: "small",
            concealed: false
        )
    }

    func testBlockUsesTheViewportMeasureAndFixedHeight() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        let textView = NSTextView(frame: scroll.contentView.bounds)
        scroll.documentView = textView
        let container = try XCTUnwrap(textView.textContainer)
        let attachment = ChipAttachment(info: chip())

        let bounds = attachment.attachmentBounds(
            for: container,
            proposedLineFragment: NSRect(
                x: 0, y: 0,
                width: CGFloat.greatestFiniteMagnitude,
                height: ChipCell.blockHeight),
            glyphPosition: .zero,
            characterIndex: 0
        )

        XCTAssertEqual(
            bounds.width,
            floor(scroll.contentSize.width - container.lineFragmentPadding * 2),
            accuracy: 0.5
        )
        XCTAssertEqual(bounds.height, ChipCell.blockHeight)
        XCTAssertEqual(ChipCell.classification, "SEALED CONTENT")
    }

    func testFallbackCellIsABlockRatherThanAnIntrinsicPill() {
        let cell = ChipCell(info: chip())

        XCTAssertEqual(cell.cellSize().height, ChipCell.blockHeight)
        XCTAssertGreaterThanOrEqual(cell.cellSize().width, 240)
    }

    func testMetadataAllowsOnlySizeClassesAndNeverCounts() {
        XCTAssertEqual(ChipCell.displayedSizeClass("small"), "small")
        XCTAssertEqual(ChipCell.displayedSizeClass("HUGE"), "huge")
        XCTAssertEqual(ChipCell.displayedSizeClass("40 ch"), "size unknown")
    }
}
