import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class SealedBlockTests: XCTestCase {
    private func face(name: String? = nil, note: Bool = false, available: Bool = true) -> ChipInfo {
        ChipInfo(chipId: 7, kind: "text", excerpt: "sk-live-…9Qz", sizeLabel: "small",
                 concealed: false, name: name, hasNote: note, available: available)
    }

    func testShortObjectsUseACompactMeasureAndLongIdentityHasAnUpperBound() {
        let short = SealedBlockCell(info: face()).preferredBounds(available: 1_200)
        let long = SealedBlockCell(info: face(name: String(repeating: "LONG_", count: 12)))
            .preferredBounds(available: 1_200)
        XCTAssertEqual(short.width, SealedBlockLayout.minimumWidth)
        XCTAssertGreaterThan(long.width, short.width)
        XCTAssertLessThanOrEqual(long.width, SealedBlockLayout.maximumWidth)
        for available in [CGFloat(0), 7, 60, 120, 250] {
            XCTAssertEqual(SealedBlockCell(info: face()).preferredBounds(available: available).width, available)
        }
    }

    func testIdentityAndControlsStaySeparateAcrossTheSupportedFontSizes() throws {
        let original = InkStyle.typeface
        defer { InkStyle.typeface = original }
        for size in stride(from: CGFloat(8), through: 40, by: 1) {
            InkStyle.typeface = InkStyle.Typeface(family: "", codeFamily: "", size: size)
            let cell = SealedBlockCell(info: face(name: "TOKEN"))
            let bounds = cell.preferredBounds(available: 560)
            let frame = NSRect(origin: .zero, size: bounds.size)
            let row = try XCTUnwrap(cell.namedRow(in: frame))
            let controls = SealedBlockCell.actionsRect(in: frame)
            XCTAssertLessThanOrEqual(row.geometry.name.maxY + 8, controls.minY, "size \(size)")
            XCTAssertGreaterThanOrEqual(frame.height - controls.maxY, 8)
            XCTAssertGreaterThanOrEqual(controls.width, 24)
            XCTAssertGreaterThanOrEqual(controls.height, 24)
        }
    }

    func testEveryControlHasOneNonoverlappingVisibleRect() throws {
        for width in [CGFloat(180), 260, 340, 560] {
            let cell = SealedBlockCell(info: face())
            let frame = NSRect(x: 10, y: 20, width: width, height: 70)
            let more = SealedBlockCell.actionsRect(in: frame)
            XCTAssertTrue(frame.contains(more))
            let copy = try XCTUnwrap(cell.copyRect(in: frame))
            XCTAssertTrue(frame.contains(copy))
            XCTAssertFalse(copy.intersects(more))
            if let move = cell.moveHandleRect(in: frame) {
                XCTAssertTrue(frame.contains(move))
                XCTAssertFalse(move.intersects(copy))
            }
            XCTAssertEqual(cell.decryptedDragRect(in: frame), copy)
        }
        let tiny = NSRect(x: 0, y: 0, width: 60, height: 70)
        XCTAssertTrue(tiny.contains(SealedBlockCell.actionsRect(in: tiny)))
        XCTAssertNil(SealedBlockCell(info: face()).copyRect(in: tiny))
    }

    func testCopyControlIsAbsentWhenTheValueIsNotOnThisDevice() {
        let cell = SealedBlockCell(info: face(available: false))
        let frame = NSRect(x: 0, y: 0, width: 320, height: 70)
        XCTAssertNil(cell.copyRect(in: frame))
        XCTAssertNotNil(cell.moveHandleRect(in: frame))
        XCTAssertEqual(SealedBlockCell.valueText(of: cell.info), "text · value on another device")
    }

    func testNamedIdentityIsDistinctFromShellAssignment() throws {
        let cell = SealedBlockCell(info: face(name: "TOKEN"))
        let frame = NSRect(x: 0, y: 0, width: 320, height: 70)
        let row = try XCTUnwrap(cell.namedRow(in: frame))
        XCTAssertEqual(row.name.string, "TOKEN")
        XCTAssertEqual(row.equals.string, " · ")
        XCTAssertEqual(row.value.string, "sk-live-…9Qz")
    }

    func testNameAndValueFitNarrowAndLargeTypeRows() throws {
        let original = InkStyle.typeface
        defer { InkStyle.typeface = original }
        for size in [CGFloat(8), 13, 40] {
            InkStyle.typeface = InkStyle.Typeface(family: "", codeFamily: "", size: size)
            let cell = SealedBlockCell(info: face(name: String(repeating: "TOKEN_", count: 10)))
            for width in [CGFloat(60), 120, 320, 560] {
                let frame = NSRect(origin: .zero, size: cell.preferredBounds(available: width).size)
                let row = try XCTUnwrap(cell.namedRow(in: frame))
                XCTAssertLessThanOrEqual(row.geometry.value.maxX, frame.maxX - 12 + 0.1)
                XCTAssertGreaterThanOrEqual(row.geometry.name.minX, frame.minX)
            }
        }
    }

    func testNoteDoorwayIsStableDuringCopyFeedbackAndNeverOverlapsControls() throws {
        let cell = SealedBlockCell(info: face(note: true))
        let frame = NSRect(x: 10, y: 20, width: 400, height: 70)
        let note = try XCTUnwrap(cell.doorwayRect(in: frame))
        XCTAssertFalse(note.intersects(try XCTUnwrap(cell.copyRect(in: frame))))
        XCTAssertFalse(note.intersects(try XCTUnwrap(cell.moveHandleRect(in: frame))))
    }

    func testAccessibilityNamesAvailableIdentityAndNoteWithoutReadingAnotherValue() {
        XCTAssertEqual(SealedBlockCell(info: face(name: "TOKEN", note: true)).accessibilityLabel(),
                       "Sealed content, TOKEN, sk-live-…9Qz, small, has note")
        let peer = SealedBlockCell(info: face(available: false))
        XCTAssertEqual(peer.accessibilityLabel(), "Sealed content, text · value on another device, small")
        XCTAssertFalse(peer.accessibilityLabel()?.contains("sk-live") ?? true)
    }

    func testViewportMeasureIsUsedEvenWhenHorizontalWrappingIsOff() {
        let container = InkTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude))
        XCTAssertTrue(container.setEditorMeasure(480))
        XCTAssertEqual(SealedBlockCell.blockWidth(in: container, proposedLineFragment: NSRect(
            x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 70)),
            480 - container.lineFragmentPadding * 2)
    }

    func testAttachmentAndTextKitUseTheSameCompactBounds() throws {
        let cell = SealedBlockCell(info: face())
        let container = NSTextContainer(size: NSSize(width: 900, height: 600))
        let fragment = NSRect(x: 0, y: 0, width: 900, height: 70)
        let attachment = ChipAttachment(info: face())
        let bounds = attachment.attachmentBounds(for: container, proposedLineFragment: fragment,
                                                 glyphPosition: .zero, characterIndex: 0)
        let frame = cell.cellFrame(for: container, proposedLineFragment: fragment,
                                   glyphPosition: .zero, characterIndex: 0)
        XCTAssertEqual(bounds.size, frame.size)
        XCTAssertEqual(bounds.size.width, SealedBlockLayout.minimumWidth)
        XCTAssertEqual(cell.cellBaselineOffset(), bounds.origin)
    }

    func testUnknownSizeClassesDoNotBecomeCountLabels() {
        XCTAssertEqual(SealedBlockCell.displayedSizeClass("SMALL"), "small")
        XCTAssertEqual(SealedBlockCell.displayedSizeClass("40 ch"), "size unknown")
    }

    func testChipAvailabilityMustBeExplicitInTheWireFace() throws {
        let face = #"{"chip_id":7,"kind":"text","excerpt":"","size_label":"small","concealed":false,"has_note":false}"#
        for suffix in ["", #", "available":null"#, #", "available":"true""#] {
            let json = String(face.dropLast()) + suffix + "}"
            XCTAssertThrowsError(try JSONDecoder().decode(ChipInfo.self, from: Data(json.utf8)))
        }
        for available in [false, true] {
            let json = String(face.dropLast()) + ",\"available\":\(available)}"
            let decoded = try JSONDecoder().decode(ChipInfo.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.available, available)
        }
    }

    func testCopyFeedbackDurationRespectsReduceMotion() {
        XCTAssertNil(SealedBlockCell.beatStrength(elapsed: -0.1, reduceMotion: false))
        XCTAssertEqual(SealedBlockCell.beatStrength(elapsed: 0.5, reduceMotion: false), 1)
        XCTAssertNil(SealedBlockCell.beatStrength(elapsed: 1, reduceMotion: false))
        XCTAssertEqual(SealedBlockCell.beatStrength(elapsed: 0, reduceMotion: true), 1)
    }
}
