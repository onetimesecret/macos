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
        XCTAssertGreaterThanOrEqual(cell.cellSize().width, ChipCell.fallbackBlockWidth)
    }

    func testANarrowMeasureDoesNotOverflowTheContainer() {
        let container = NSTextContainer(size: NSSize(
            width: 120,
            height: ChipCell.blockHeight
        ))
        let width = ChipCell.blockWidth(
            in: container,
            proposedLineFragment: NSRect(
                x: 0, y: 0,
                width: 120,
                height: ChipCell.blockHeight)
        )

        XCTAssertEqual(width, floor(120 - container.lineFragmentPadding * 2))
        XCTAssertLessThan(width, 160)
    }

    func testEffectivelyUnboundedFiniteWidthsUseTheFallbackMeasure() {
        let container = NSTextContainer(size: NSSize(
            width: ChipCell.effectivelyUnboundedWidth * 2,
            height: ChipCell.blockHeight
        ))
        let width = ChipCell.blockWidth(
            in: container,
            proposedLineFragment: NSRect(
                x: 0, y: 0,
                width: ChipCell.effectivelyUnboundedWidth,
                height: ChipCell.blockHeight)
        )

        XCTAssertEqual(
            width,
            floor(ChipCell.fallbackBlockWidth - container.lineFragmentPadding * 2)
        )
    }

    func testMetadataAcceptsCoreSizeClassesAndFailsClosedForUnknownValues() throws {
        // The core owns bucket boundaries. The shell verifies only that
        // labels crossing the seam belong to the vocabulary it can draw.
        let byteLengths = [1, 80, 2_048]

        for byteLength in byteLengths {
            let client = CompanionClient.ephemeral(
                tag: "sealed-size-class-\(byteLength)-\(UUID().uuidString)")
            client.newTab()
            let pageID = try XCTUnwrap(client.tabs().first?.pageID)
            let text = String(repeating: "x", count: byteLength)
            let label = try XCTUnwrap(
                client.sealText(sheet: pageID, text, at: 0, length: 0)?.sizeLabel)

            XCTAssertEqual(ChipCell.displayedSizeClass(label), label)
        }

        XCTAssertEqual(ChipCell.displayedSizeClass("40 ch"), "size unknown")
        XCTAssertEqual(ChipCell.displayedSizeClass("future-class"), "size unknown")
    }
}
