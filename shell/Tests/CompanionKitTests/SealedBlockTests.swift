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

    func testMetadataAcceptsEveryCoreSizeClassAndFailsClosedForUnknownValues() throws {
        let byteLengths = [1, 64, 1_024, 65_536, 1_048_576]
        var labels = Set<String>()

        for byteLength in byteLengths {
            let client = CompanionClient.ephemeral(
                tag: "sealed-size-class-\(byteLength)-\(UUID().uuidString)")
            client.newTab()
            let pageID = try XCTUnwrap(client.tabs().first?.pageID)
            let text = String(repeating: "x", count: byteLength)
            let label = try XCTUnwrap(
                client.sealText(sheet: pageID, text, at: 0, length: 0)?.sizeLabel)

            labels.insert(label)
            XCTAssertEqual(ChipCell.displayedSizeClass(label), label)
        }

        XCTAssertEqual(labels.count, byteLengths.count)
        XCTAssertEqual(ChipCell.displayedSizeClass("40 ch"), "size unknown")
        XCTAssertEqual(ChipCell.displayedSizeClass("future-class"), "size unknown")
    }
}
