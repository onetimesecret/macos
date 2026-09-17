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
        XCTAssertEqual(metrics.lockTopNudge, 1)
        XCTAssertEqual(metrics.lockToLabelGap, 5)
        XCTAssertEqual(metrics.metadataBaselineNudge, 1)
        XCTAssertEqual(metrics.excerptTrailingGap, 8)
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
        XCTAssertEqual(layout.lockRect.minY, layout.topRowY + metrics.lockTopNudge)
    }

    /// The classification opens a named gap past the lock, on the
    /// lock's row, so the top row is placed from the layout and not
    /// from a sum of lock size and gap kept in the drawing routine.
    func testClassificationStartsAGapPastTheLock() {
        let frame = NSRect(x: 10, y: 10, width: 300, height: SealedBlockCell.blockHeight)
        let metrics = SealedBlockLayout.metrics(containerWidth: frame.width)
        let layout = SealedBlockCell.contentLayout(in: frame)

        XCTAssertEqual(layout.labelOrigin.x, layout.lockRect.maxX + metrics.lockToLabelGap)
        XCTAssertEqual(
            layout.labelOrigin.x,
            layout.left + metrics.lockSize + metrics.lockToLabelGap)
        XCTAssertEqual(layout.labelOrigin.y, layout.topRowY)
    }

    /// The size class ends at the trailing inset the actions seat
    /// shares and sits a named nudge below the bottom row, level with
    /// the excerpt's larger face.
    func testMetadataEndsAtTheTrailingInsetOnTheNudgedBaseline() {
        let frame = NSRect(x: 10, y: 10, width: 300, height: SealedBlockCell.blockHeight)
        let metrics = SealedBlockLayout.metrics(containerWidth: frame.width)
        let layout = SealedBlockCell.contentLayout(in: frame)
        let origin = layout.metadataOrigin(width: 30)

        XCTAssertEqual(layout.metadataRight, SealedBlockCell.actionsRect(in: frame).maxX)
        XCTAssertEqual(origin.x, frame.maxX - metrics.horizontalPadding - 30)
        XCTAssertEqual(origin.y, layout.bottomRowY + metrics.metadataBaselineNudge)
        XCTAssertEqual(layout.metadataY, origin.y)
    }

    /// The block is a fixed measure and the excerpt is drawn at the
    /// core's length, so at a narrow measure the excerpt's rect must
    /// stop a gap short of the size class rather than run under it.
    func testExcerptStopsShortOfTheMetadataColumnAtANarrowMeasure() {
        let frame = NSRect(x: 10, y: 10, width: 120, height: SealedBlockCell.blockHeight)
        let metrics = SealedBlockLayout.metrics(containerWidth: frame.width)
        let layout = SealedBlockCell.contentLayout(in: frame)
        let metadataWidth: CGFloat = 40
        let rect = layout.excerptRect(metadataWidth: metadataWidth, height: 14)
        let metadataMinX = layout.metadataOrigin(width: metadataWidth).x

        XCTAssertEqual(rect.minX, layout.left)
        XCTAssertEqual(rect.minY, layout.bottomRowY)
        XCTAssertEqual(rect.height, 14)
        XCTAssertLessThanOrEqual(rect.maxX, metadataMinX - metrics.excerptTrailingGap)
        XCTAssertEqual(
            rect.width,
            SealedBlockLayout.excerptWidth(containerWidth: frame.width, metadataWidth: metadataWidth))
        XCTAssertEqual(
            SealedBlockLayout.excerptWidth(containerWidth: 120, metadataWidth: 40),
            120 - metrics.horizontalPadding * 2 - 40 - metrics.excerptTrailingGap)
    }

    /// A block too narrow for the size class and the gap draws no
    /// excerpt rather than one with a negative measure.
    func testExcerptWidthNeverGoesNegative() {
        XCTAssertEqual(SealedBlockLayout.excerptWidth(containerWidth: 40, metadataWidth: 40), 0)
        XCTAssertEqual(SealedBlockLayout.excerptWidth(containerWidth: 0, metadataWidth: 0), 0)
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

    /// Wrapped mode: the container is exactly the captured measure.
    /// That is the common case, and it must match as a candidate, not
    /// fall through to the captured measure only because every
    /// candidate failed a strict ceiling.
    func testAContainerEqualToTheCapturedMeasureIsTheMeasure() {
        let container = InkTextContainer(size: NSSize(
            width: 400,
            height: SealedBlockCell.blockHeight
        ))
        XCTAssertTrue(container.setEditorMeasure(400))
        let width = SealedBlockCell.blockWidth(
            in: container,
            proposedLineFragment: NSRect(
                x: 0, y: 0,
                width: 400,
                height: SealedBlockCell.blockHeight)
        )

        XCTAssertEqual(width, floor(400 - container.lineFragmentPadding * 2))
    }

    /// Unwrapped mode: the container and the proposed fragment are
    /// both effectively infinite, so only the captured measure can
    /// size the block, and it spans the padding like the container.
    func testAnUnboundedContainerTakesTheCapturedMeasure() {
        let container = InkTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        XCTAssertTrue(container.setEditorMeasure(480))
        let width = SealedBlockCell.blockWidth(
            in: container,
            proposedLineFragment: NSRect(
                x: 0, y: 0,
                width: CGFloat.greatestFiniteMagnitude,
                height: SealedBlockCell.blockHeight)
        )

        XCTAssertEqual(width, floor(480 - container.lineFragmentPadding * 2))
    }

    /// A container wider than the captured measure may not widen it.
    func testAContainerWiderThanTheCapturedMeasureIsCapped() {
        let container = InkTextContainer(size: NSSize(
            width: 600,
            height: SealedBlockCell.blockHeight
        ))
        XCTAssertTrue(container.setEditorMeasure(400))
        let width = SealedBlockCell.blockWidth(
            in: container,
            proposedLineFragment: NSRect(
                x: 0, y: 0,
                width: 600,
                height: SealedBlockCell.blockHeight)
        )

        XCTAssertEqual(width, floor(400 - container.lineFragmentPadding * 2))
    }

    /// The proposed fragment spans the padding like the container does,
    /// so when it is the measure the padding still comes off, or the
    /// block overruns the line by the padding on each side.
    func testAFiniteFragmentInAnUnboundedContainerGivesBackThePadding() {
        let plain = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        XCTAssertGreaterThan(plain.lineFragmentPadding, 0, "the padding has nothing to prove")
        let fragment = NSRect(x: 0, y: 0, width: 300, height: SealedBlockCell.blockHeight)

        XCTAssertEqual(
            SealedBlockCell.blockWidth(in: plain, proposedLineFragment: fragment),
            floor(300 - plain.lineFragmentPadding * 2))

        let captured = InkTextContainer(size: plain.size)
        XCTAssertTrue(captured.setEditorMeasure(480))
        XCTAssertEqual(
            SealedBlockCell.blockWidth(in: captured, proposedLineFragment: fragment),
            floor(300 - captured.lineFragmentPadding * 2),
            "a fragment under the captured measure kept the padding")
    }

    /// Records what TextKit hands an attachment cell during layout.
    private final class ProposalRecorder: NSTextAttachmentCell {
        // Layout runs synchronously on the thread that asked for it,
        // which here is the test's; the cell's hook is nonisolated.
        nonisolated(unsafe) var proposedFragment: NSRect?
        nonisolated(unsafe) var glyphPosition: NSPoint?

        override nonisolated func cellFrame(
            for textContainer: NSTextContainer,
            proposedLineFragment lineFrag: NSRect,
            glyphPosition position: NSPoint,
            characterIndex charIndex: Int
        ) -> NSRect {
            proposedFragment = lineFrag
            glyphPosition = position
            return super.cellFrame(
                for: textContainer,
                proposedLineFragment: lineFrag,
                glyphPosition: position,
                characterIndex: charIndex
            )
        }
    }

    /// The premise `blockWidth` rests on, checked against TextKit
    /// rather than assumed: the proposed line fragment is as wide as
    /// the container, padding included, and the padding shows up in
    /// the glyph origin instead. With that geometry the block laid out
    /// through the fragment must end inside the padding, not at the
    /// container's edge.
    func testTextKitProposesAFragmentAsWideAsTheContainer() {
        let padding: CGFloat = 5
        let recorder = ProposalRecorder()
        let probe = NSTextAttachment(data: nil, ofType: nil)
        probe.attachmentCell = recorder
        let storage = NSTextStorage(attributedString: NSAttributedString(string: "ab "))
        storage.append(NSAttributedString(attachment: probe))
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 300, height: 1_000))
        container.lineFragmentPadding = padding
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        XCTAssertEqual(recorder.proposedFragment?.minX, 0)
        XCTAssertEqual(recorder.proposedFragment?.width, 300)
        XCTAssertGreaterThanOrEqual(recorder.glyphPosition?.x ?? 0, padding)

        let sealed = NSTextStorage(attributedString: NSAttributedString(string: "ab "))
        sealed.append(NSAttributedString(attachment: ChipAttachment(info: chip())))
        let sealedLayout = NSLayoutManager()
        sealed.addLayoutManager(sealedLayout)
        let sealedContainer = NSTextContainer(size: NSSize(width: 300, height: 1_000))
        sealedContainer.lineFragmentPadding = padding
        sealedLayout.addTextContainer(sealedContainer)
        sealedLayout.ensureLayout(for: sealedContainer)
        let glyph = sealedLayout.glyphIndexForCharacter(at: 3)

        XCTAssertEqual(sealedLayout.attachmentSize(forGlyphAt: glyph).width, 300 - padding * 2)
        let block = sealedLayout.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: sealedContainer)
        XCTAssertLessThanOrEqual(block.maxX, 300 - padding, "the block overran the padding")
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
