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
                       "sealed content, TOKEN, sk-live-…9Qz, small, has note")
        let peer = SealedBlockCell(info: face(available: false))
        XCTAssertEqual(peer.accessibilityLabel(), "sealed content, text · value on another device, small")
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

    /// Records the proposal TextKit supplies during synchronous layout.
    private final class ProposalRecorder: NSTextAttachmentCell {
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
        sealed.append(NSAttributedString(attachment: ChipAttachment(info: face())))
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
        for byteLength in [1, 80, 2_048] {
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
    func testShortValuesReturnUnusedMeasureToALongName() {
        let widths = SealedBlockLayout.rowAllotment(
            available: 100, name: 200, equals: 10, value: 5, nameFloor: 20)
        XCTAssertEqual(widths.name, 85)
        XCTAssertEqual(widths.value, 5)
    }

    func testControlTitlesFitTheirBoundsWithLongTranslatedCopyFeedbackAndNotes() {
        let titles = [
            "Entschlüsselten Inhalt in die Zwischenablage kopieren",
            "Der entschlüsselte Inhalt wurde in die Zwischenablage kopiert",
            "Bearbeiten Sie die Anmerkung zu diesem versiegelten Inhalt",
        ]
        for title in titles {
            for width in [CGFloat(1), 7, 24, 108] {
                let bounds = NSRect(x: 30, y: 20, width: width, height: 24)
                let fitted = SealedBlockCell.controlTitle(SealedBlockCell.controlString(title), in: bounds)
                XCTAssertGreaterThanOrEqual(fitted.rect.minX, bounds.minX)
                XCTAssertGreaterThanOrEqual(fitted.rect.minY, bounds.minY)
                XCTAssertLessThanOrEqual(fitted.rect.maxX, bounds.maxX)
                XCTAssertLessThanOrEqual(fitted.rect.maxY, bounds.maxY)
                XCTAssertLessThanOrEqual(fitted.text.size().width, max(0, width - 8))
                if width >= 24 {
                    XCTAssertFalse(fitted.text.string.isEmpty)
                    XCTAssertTrue(fitted.text.string.hasSuffix("…"))
                }
            }
        }
    }

    func testLongControlTitlesDoNotPaintOutsideTheirButtons() throws {
        for title in [
            "Entschlüsselten Inhalt in die Zwischenablage kopieren",
            "Der entschlüsselte Inhalt wurde in die Zwischenablage kopiert",
            "Bearbeiten Sie die Anmerkung zu diesem versiegelten Inhalt",
        ] {
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 80,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            let button = NSRect(x: 66, y: 28, width: 108, height: 24)
            let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 240, height: 80).fill()
            appearance.performAsCurrentDrawingAppearance {
                SealedBlockCell.drawControl(SealedBlockCell.controlString(title), in: button, bordered: true)
            }
            NSGraphicsContext.restoreGraphicsState()
            var painted = 0
            var outside = 0
            let allowance = button.insetBy(dx: -1, dy: -1)
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    let pixel = try XCTUnwrap(rep.colorAt(x: x, y: y))
                    if min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) < 0.99 {
                        painted += 1
                        if !allowance.contains(NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                            outside += 1
                        }
                    }
                }
            }
            XCTAssertGreaterThan(painted, 0)
            XCTAssertEqual(outside, 0, "a long control title painted beyond its button")
        }
    }

    func testCopyControlMeasureFitsBothLocalizedLabelsWithoutChangingDuringFeedback() throws {
        let copy = "Entschlüsselten Inhalt kopieren"
        let feedback = "Der Inhalt wurde kopiert"
        let width = SealedBlockLayout.controlWidth(for:
            SealedBlockCell.controlString(copy).size().width,
            SealedBlockCell.controlString(feedback).size().width)
        let frame = NSRect(x: 0, y: 0, width: 560, height: SealedBlockCell.preferredHeight)
        let button = try XCTUnwrap(SealedBlockLayout.copyRect(in: frame, width: width))
        for title in [copy, feedback] {
            let fitted = SealedBlockCell.controlTitle(SealedBlockCell.controlString(title), in: button)
            XCTAssertEqual(fitted.text.string, title)
        }
        let narrow = NSRect(x: 0, y: 0, width: width + 30, height: frame.height)
        XCTAssertNil(SealedBlockLayout.copyRect(in: narrow, width: width))
    }

    func testMoreHitTargetAddsSlopWithoutEnteringTheCopyControl() throws {
        let cell = SealedBlockCell(info: face())
        for width in [CGFloat(60), 180, 340, 560] {
            let frame = NSRect(x: 10, y: 20, width: width, height: SealedBlockCell.preferredHeight)
            let drawn = SealedBlockCell.actionsRect(in: frame)
            let hit = SealedBlockCell.actionsHitRect(in: frame)
            XCTAssertTrue(frame.contains(hit))
            XCTAssertTrue(hit.contains(drawn))
            XCTAssertGreaterThan(hit.height, drawn.height)
            if let copy = cell.copyRect(in: frame) { XCTAssertFalse(hit.intersects(copy)) }
        }
    }

    func testNarrowEditableObjectIncludesItsNoteInTheStatusWhenTheNoteButtonDoesNotFit() throws {
        let cell = SealedBlockCell(info: face(note: true))
        for width in [CGFloat(180), 220, 260] {
            let frame = NSRect(x: 0, y: 0, width: width, height: SealedBlockCell.preferredHeight)
            XCTAssertNil(cell.doorwayRect(in: frame))
            let image = NSImage(size: frame.size)
            image.lockFocus()
            let editor = InkTextView(frame: frame)
            editor.isEditable = true
            cell.draw(withFrame: frame, in: editor)
            image.unlockFocus()
            XCTAssertEqual(cell.lastDrawnStatus, CompanionL10n.format("chip.status.has_note", "sealed text"))
            XCTAssertEqual(cell.lastDrawnStatusSymbol, "note.text")
            let symbol = try XCTUnwrap(cell.lastDrawnStatusSymbolFrame)
            XCTAssertTrue(frame.contains(symbol))
            for control in [cell.copyRect(in: frame), cell.moveHandleRect(in: frame),
                            SealedBlockCell.actionsRect(in: frame)].compactMap({ $0 }) {
                XCTAssertFalse(symbol.intersects(control))
            }
        }
    }

    func testNotePopoverAnchorUsesMoreWhenTheNoteButtonDoesNotFit() throws {
        let cell = SealedBlockCell(info: face(note: true))
        let narrow = NSRect(x: 10, y: 20, width: 180, height: SealedBlockCell.preferredHeight)
        XCTAssertNil(cell.doorwayRect(in: narrow))
        XCTAssertEqual(cell.noteAnchorRect(in: narrow), SealedBlockCell.actionsRect(in: narrow))
        let wide = NSRect(x: 10, y: 20, width: 480, height: SealedBlockCell.preferredHeight)
        XCTAssertEqual(cell.noteAnchorRect(in: wide), try XCTUnwrap(cell.doorwayRect(in: wide)))
    }

    func testUnknownKindsUseNeutralClassificationInsteadOfSealedText() {
        for available in [true, false] {
            let cell = SealedBlockCell(info: ChipInfo(
                chipId: 7, kind: "future-kind", excerpt: "preview", sizeLabel: "small",
                concealed: false, available: available))
            let frame = NSRect(x: 0, y: 0, width: 480, height: SealedBlockCell.preferredHeight)
            let image = NSImage(size: frame.size)
            image.lockFocus()
            cell.draw(withFrame: frame, in: nil)
            image.unlockFocus()
            XCTAssertEqual(cell.lastDrawnStatus, CompanionL10n.string(
                available ? "chip.status.classification" : "chip.status.elsewhere"))
        }
    }

    func testNoteControlUsesTheSameMeasuredTitleAndInsetsAsCopy() throws {
        let cell = SealedBlockCell(info: face(note: true))
        let frame = NSRect(x: 0, y: 0, width: 480, height: SealedBlockCell.preferredHeight)
        let note = try XCTUnwrap(cell.doorwayRect(in: frame))
        let title = SealedBlockCell.controlString(SealedBlockCell.doorwayWord)
        XCTAssertEqual(note.width, SealedBlockLayout.controlWidth(for: title.size().width))
        XCTAssertEqual(SealedBlockCell.controlTitle(title, in: note).text.string, title.string)
    }

}
