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

    func testLayoutMetricsUseTheFullNormalizedMeasure() {
        let metrics = SealedBlockLayout.metrics(containerWidth: 480)

        XCTAssertEqual(metrics.width, 480)
        XCTAssertEqual(metrics.height, 52)
        XCTAssertEqual(metrics.cornerRadius, 8)
        XCTAssertEqual(metrics.borderWidth, 1)
        XCTAssertEqual(metrics.verticalPadding, 8)
        XCTAssertEqual(metrics.horizontalPadding, 12)
        XCTAssertEqual(SealedBlockLayout.metrics(containerWidth: 7).width, 7)
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
                height: SealedBlockCell.blockHeight),
            glyphPosition: .zero,
            characterIndex: 0
        )

        XCTAssertEqual(
            bounds.width,
            floor(scroll.contentSize.width - container.lineFragmentPadding * 2),
            accuracy: 0.5
        )
        XCTAssertEqual(bounds.height, SealedBlockCell.blockHeight)
        XCTAssertEqual(SealedBlockCell.classification, "SEALED CONTENT")
    }

    func testFallbackCellIsABlockRatherThanAnIntrinsicPill() {
        let cell = SealedBlockCell(info: chip())

        XCTAssertEqual(cell.cellSize().height, SealedBlockCell.blockHeight)
        XCTAssertGreaterThanOrEqual(cell.cellSize().width, SealedBlockCell.fallbackBlockWidth)
    }

    func testANarrowMeasureDoesNotOverflowTheContainer() {
        let container = NSTextContainer(size: NSSize(
            width: 120,
            height: SealedBlockCell.blockHeight
        ))
        let width = SealedBlockCell.blockWidth(
            in: container,
            proposedLineFragment: NSRect(
                x: 0, y: 0,
                width: 120,
                height: SealedBlockCell.blockHeight)
        )

        XCTAssertEqual(width, floor(120 - container.lineFragmentPadding * 2))
        XCTAssertLessThan(width, 160)
    }

    func testEffectivelyUnboundedFiniteWidthsUseTheFallbackMeasure() {
        let container = NSTextContainer(size: NSSize(
            width: SealedBlockCell.effectivelyUnboundedWidth * 2,
            height: SealedBlockCell.blockHeight
        ))
        let width = SealedBlockCell.blockWidth(
            in: container,
            proposedLineFragment: NSRect(
                x: 0, y: 0,
                width: SealedBlockCell.effectivelyUnboundedWidth,
                height: SealedBlockCell.blockHeight)
        )

        XCTAssertEqual(
            width,
            floor(SealedBlockCell.fallbackBlockWidth - container.lineFragmentPadding * 2)
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

            XCTAssertEqual(SealedBlockCell.displayedSizeClass(label), label)
        }

        XCTAssertEqual(SealedBlockCell.displayedSizeClass("40 ch"), "size unknown")
        XCTAssertEqual(SealedBlockCell.displayedSizeClass("future-class"), "size unknown")
    }
}
