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

    /// The slab's height belongs to the block, not to the measure it is
    /// laid out in, so it can be asked for without inventing a width.
    func testHeightIsAskedForWithoutAContainerMeasure() {
        XCTAssertEqual(SealedBlockLayout.height, 52)
        XCTAssertEqual(SealedBlockCell.blockHeight, SealedBlockLayout.height)
        for width in [CGFloat(0), 7, 240, 1_200] {
            XCTAssertEqual(
                SealedBlockLayout.metrics(containerWidth: width).height,
                SealedBlockLayout.height
            )
        }
    }

    /// Every number the block is drawn with comes from the one metrics
    /// value: the baseline drop, the actions seat, the selection ring
    /// and the two rows all derive from it rather than from literals
    /// hidden in the drawing routine.
    func testLayoutMetricsCarryTheWholeBlockGeometry() {
        let metrics = SealedBlockLayout.metrics(containerWidth: 300)

        XCTAssertEqual(metrics.baselineOffset, 4)
        XCTAssertEqual(metrics.actionsWidth, 22)
        XCTAssertEqual(metrics.actionsHeight, 16)
        XCTAssertEqual(metrics.actionsTopInset, 6)
        XCTAssertEqual(metrics.selectionRingInset, 1)
        XCTAssertEqual(metrics.selectionRingWidth, 3)
        XCTAssertEqual(metrics.bottomRowInset, 24)
        XCTAssertEqual(metrics.lockSize, 9)
    }

    func testBlockBoundsHangFromTheBaselineByTheMetricOffset() {
        let metrics = SealedBlockLayout.metrics(containerWidth: 300)
        let bounds = SealedBlockCell.blockBounds(width: 300)

        XCTAssertEqual(bounds.origin.x, 0)
        XCTAssertEqual(bounds.origin.y, -metrics.height + metrics.baselineOffset)
        XCTAssertEqual(bounds.width, 300)
        XCTAssertEqual(bounds.height, metrics.height)
    }

    func testActionsSeatFollowsTheMetricsRatherThanLiterals() {
        let frame = NSRect(x: 10, y: 10, width: 300, height: SealedBlockCell.blockHeight)
        let metrics = SealedBlockLayout.metrics(containerWidth: frame.width)
        let seat = SealedBlockCell.actionsRect(in: frame)

        XCTAssertEqual(seat.maxX, frame.maxX - metrics.horizontalPadding)
        XCTAssertEqual(seat.minY, frame.minY + metrics.actionsTopInset)
        XCTAssertEqual(seat.width, metrics.actionsWidth)
        XCTAssertEqual(seat.height, metrics.actionsHeight)
    }

    func testContentRowsAndLockFollowTheMetrics() {
        let frame = NSRect(x: 10, y: 10, width: 300, height: SealedBlockCell.blockHeight)
        let metrics = SealedBlockLayout.metrics(containerWidth: frame.width)
        let layout = SealedBlockCell.contentLayout(in: frame)

        XCTAssertEqual(layout.left, frame.minX + metrics.horizontalPadding)
        XCTAssertEqual(layout.topRowY, frame.minY + metrics.verticalPadding)
        XCTAssertEqual(layout.bottomRowY, frame.maxY - metrics.bottomRowInset)
        XCTAssertEqual(layout.lockRect.size, NSSize(width: metrics.lockSize, height: metrics.lockSize))
        XCTAssertEqual(layout.lockRect.minX, layout.left)
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
