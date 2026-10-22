import AppKit
import XCTest

@testable import CompanionKit

/// The sealed block's actions, live TextKit geometry, and the lines
/// that follow them, as the stream navigator design drew them
/// (2026-09-15).
@MainActor
final class SealedCapsuleTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suite = "companion-sealed-capsule-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return isolatedModel(defaults: defaults)
    }

    // MARK: The menu

    /// The menu exposes the three named actions, advertises the copy
    /// chord, and separates removal without depending on item offsets.
    func testTheMenuExposesTheNamedActionsAndAdvertisesTheCopyChord() throws {
        let model = try makeModel()
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator))
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()

        let menu = try XCTUnwrap(coordinator.chipMenu(at: 3))
        let copy = try XCTUnwrap(menu.items.first {
            $0.title == "Copy Decrypted Contents"
        })
        let link = try XCTUnwrap(menu.items.first {
            $0.title == "Create One-Time Link…"
        })
        let remove = try XCTUnwrap(menu.items.first {
            $0.title == "Remove Sealed Content"
        })
        XCTAssertEqual(copy.title, "Copy Decrypted Contents")
        XCTAssertEqual(link.title, "Create One-Time Link…")
        XCTAssertEqual(remove.title, "Remove Sealed Content")
        // The auto-enable pass a shown menu runs asks the coordinator,
        // which validates; the object's verbs must survive it.
        menu.update()
        for item in menu.items where item.action != nil {
            XCTAssertTrue(item.isEnabled, "\(item.title) is offered, so it is enabled")
        }
        XCTAssertNotNil(copy.action)
        XCTAssertNotNil(link.action)
        XCTAssertNotNil(remove.action)
        XCTAssertTrue(menu.items.contains { $0.isSeparatorItem })
        XCTAssertGreaterThan(
            try XCTUnwrap(menu.items.firstIndex(of: remove)),
            try XCTUnwrap(menu.items.firstIndex { $0.isSeparatorItem })
        )

        let chord = try XCTUnwrap(model.keymap.hintKeystroke(for: .chipCopyDecrypted))
        XCTAssertEqual(chord.displaySymbol, "⇧⌘C")
        XCTAssertEqual(copy.keyEquivalent, chord.menuKeyEquivalent)
        XCTAssertEqual(copy.keyEquivalentModifierMask, chord.menuModifierMask)

        // The chord acts on exactly one selected object and on nothing
        // else, so it can never reach a payload nobody pointed at.
        textView.setSelectedRange(NSRange(location: 3, length: 1))
        XCTAssertEqual(coordinator.selectedChipIndex, 3)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(coordinator.selectedChipIndex)
        textView.setSelectedRange(NSRange(location: 2, length: 2))
        XCTAssertNil(coordinator.selectedChipIndex, "a mixed selection offered the chord a payload")

        // Named, the menu gains the two copies in D-41's order as Law 0001's
        // presentation invariants extend it, and the chord stays on copy decrypted.
        name(textView, chipAt: 3, model: model, as: "MY_API_KEY")
        let named = try XCTUnwrap(coordinator.chipMenu(at: 3))
        XCTAssertEqual(
            named.items.map { $0.isSeparatorItem ? nil : $0.title },
            [
                "Copy Name", "Copy Decrypted Contents", "Copy Name=Value, Decrypted",
                "Create One-Time Link…", nil, "Rename", "Note…", nil,
                "Remove Sealed Content",
            ])
        for item in named.items where !item.isSeparatorItem {
            XCTAssertNotNil(item.action, "\(item.title) does nothing")
            XCTAssertEqual(
                item.keyEquivalent.isEmpty, item.title != "Copy Decrypted Contents",
                "\(item.title) took or lost the copy chord")
        }
    }

    // MARK: The named row's zones (Law 0001, unnamed row and zone rows; sealed row spec, Zones)

    /// Names the chip at `index` core-side and stands its new face in.
    private func name(
        _ textView: InkTextView, chipAt index: Int, model: PageModel, as name: String
    ) {
        guard let face = textView.chipCell(at: index)?.info,
              let sheet = textView.coordinator?.currentSheet
        else { return XCTFail("no chip at \(index)") }
        XCTAssertTrue(model.coreClient.setChipName(name, chip: face.chipId))
        model.restateChipFace(face.chipId, sheet: sheet)
    }

    /// A new face is stood in where the block stands: the same attachment
    /// and cell, the core's face, and no op crossing for it.
    func testAChipsFaceChangesInPlace() throws {
        let model = try makeModel()
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator))
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()
        let attachment = try XCTUnwrap(coordinator.chipAttachment(at: 3))
        let cell = try XCTUnwrap(textView.chipCell(at: 3))
        var emitted: [[DocumentEditOp]] = []
        coordinator.onEmit = { emitted.append($0) }

        name(textView, chipAt: 3, model: model, as: "  DB_PASSWORD ")

        XCTAssertTrue(coordinator.chipAttachment(at: 3) === attachment, "the page was restated")
        XCTAssertTrue(textView.chipCell(at: 3) === cell)
        XCTAssertEqual(attachment.info.name, "DB_PASSWORD", "the face is not the core's")
        XCTAssertEqual(cell.info.name, "DB_PASSWORD")
        XCTAssertTrue(emitted.isEmpty, "a face change crossed the seam as an edit")
        model.restateChipFace(4_242, sheet: page)
        XCTAssertEqual(attachment.info.name, "DB_PASSWORD", "an unknown chip moved a face")
    }

    /// A first click on a zone copies; a later click of the same press
    /// does nothing; off a zone, or with a modifier, the click selects.
    func testAZoneActsOnTheFirstClickAndAClickOffItSelects() {
        func click(
            _ zone: SealedBlockLayout.Zone?, _ count: Int, _ flags: NSEvent.ModifierFlags = []
        ) -> InkTextView.ChipClick {
            InkTextView.chipClick(
                named: true, zone: zone, inRow: zone != nil, clickCount: count,
                modifierFlags: flags)
        }
        for zone in SealedBlockLayout.Zone.allCases {
            XCTAssertEqual(click(zone, 1), .copy(zone))
            XCTAssertEqual(click(zone, 1, .capsLock), .copy(zone))
            XCTAssertEqual(click(zone, 3), .ignore)
            XCTAssertEqual(click(zone, 1, .shift), .select)
        }
        for zone in [SealedBlockLayout.Zone.value, .equals] {
            XCTAssertEqual(click(zone, 2), .ignore, "a second click on a decrypted zone acted again")
        }
        XCTAssertEqual(click(nil, 1), .select)
        XCTAssertEqual(click(nil, 2), .select)
        XCTAssertEqual(
            InkTextView.chipClick(
                named: false, zone: nil, inRow: true, clickCount: 1, modifierFlags: []),
            .select, "an unnamed row's click selects as the block does")
    }

    /// A zone acts only once the seat has named it under the pointer: a
    /// press that arrives first, as an activating click on a window that
    /// shows no hover does, finds no zone and selects.
    func testAZoneActsOnlyOnceTheSeatHasNamedIt() {
        XCTAssertEqual(
            InkTextView.actingZone(pointed: .value, index: 3, hoveredIndex: 3, hoveredZone: .value),
            .value)
        XCTAssertNil(
            InkTextView.actingZone(pointed: .value, index: 3, hoveredIndex: nil, hoveredZone: nil),
            "a press the seat never named copied")
        XCTAssertNil(
            InkTextView.actingZone(pointed: .value, index: 3, hoveredIndex: 3, hoveredZone: .name),
            "the seat named another zone")
        XCTAssertNil(
            InkTextView.actingZone(pointed: .equals, index: 3, hoveredIndex: 5, hoveredZone: .equals),
            "the seat that named it was another block's")
        XCTAssertNil(
            InkTextView.actingZone(pointed: nil, index: 3, hoveredIndex: 3, hoveredZone: .name))
        XCTAssertEqual(
            InkTextView.chipClick(
                named: true,
                zone: InkTextView.actingZone(
                    pointed: .value, index: 3, hoveredIndex: nil, hoveredZone: nil),
                inRow: true, clickCount: 1, modifierFlags: []),
            .select)
    }

    /// A client that counts the two decrypted copies and answers yes
    /// without writing the pasteboard, so each route can be told apart.
    private final class CopyCountingClient: CompanionClient, @unchecked Sendable {
        private(set) var copiedOut: [UInt64] = []
        private(set) var copiedNameValue: [UInt64] = []

        init(tag: String) {
            super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
        }

        override func copyOutChip(id: UInt64) -> Bool {
            copiedOut.append(id)
            return true
        }

        override func copyNameValue(chip: UInt64) -> Bool {
            copiedNameValue.append(chip)
            return true
        }
    }

    /// Each zone takes its own model route and says so in the line: the
    /// name to the ordinary pasteboard with no clear, the value by copy
    /// out, and `=` by the core's `name=value`.
    /// A page holding `ab <chip> cd` over a counting client, its ambient
    /// copies kept on a pasteboard of the test's own.
    private struct ZoneFixture {
        let model: PageModel
        let client: CopyCountingClient
        let pasteboard: NSPasteboard
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let chipID: UInt64
    }

    private func makeZoneFixture(_ tag: String) throws -> ZoneFixture {
        let suite = "companion-sealed-zones-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-sealed-zones-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.withUniqueName()
        let client = CopyCountingClient(tag: tag)
        let model = PageModel(
            formFactor: .backdrop, defaults: defaults,
            seams: .init(
                stateDirectory: directory, client: client,
                clearClipboardIfOurs: { false }, ambientPasteboard: pasteboard))
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator))
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()
        let chipID = try XCTUnwrap(coordinator.chipAttachment(at: 3)?.info.chipId)
        return ZoneFixture(
            model: model, client: client, pasteboard: pasteboard, coordinator: coordinator,
            textView: textView, chipID: chipID)
    }

    func testEachZoneCallsItsOwnModelRoute() throws {
        let fixture = try makeZoneFixture(#function)
        defer { fixture.pasteboard.releaseGlobally() }
        let (model, client, pasteboard, coordinator, textView, chipID) = (
            fixture.model, fixture.client, fixture.pasteboard, fixture.coordinator,
            fixture.textView, fixture.chipID)

        XCTAssertFalse(coordinator.copy(.name, chipAt: 3), "an unnamed object has no name")
        XCTAssertFalse(coordinator.copy(.equals, chipAt: 3), "nor a name=value")
        XCTAssertTrue(client.copiedNameValue.isEmpty)
        name(textView, chipAt: 3, model: model, as: "MY_API_KEY")

        XCTAssertTrue(coordinator.copy(.name, chipAt: 3))
        XCTAssertEqual(pasteboard.string(forType: .string), "MY_API_KEY")
        XCTAssertEqual(model.notice, PageModel.copiedNameLine)
        XCTAssertEqual(PageModel.copiedNameLine, "copied the name.")
        XCTAssertTrue(client.copiedOut.isEmpty && client.copiedNameValue.isEmpty)

        XCTAssertTrue(coordinator.copy(.value, chipAt: 3))
        XCTAssertEqual(client.copiedOut, [chipID])
        XCTAssertTrue(client.copiedNameValue.isEmpty)
        let line = PageModel.copiedLine(
            clearsIn: CompanionClient.clipboardClearSeconds(), size: "tiny")
        XCTAssertEqual(model.notice, line)

        model.flash("something else")
        XCTAssertTrue(coordinator.copy(.equals, chipAt: 3))
        XCTAssertEqual(client.copiedNameValue, [chipID])
        XCTAssertEqual(client.copiedOut, [chipID], "the = zone took the value's route")
        XCTAssertEqual(model.notice, line, "name=value says D-42's line as it stands")
        XCTAssertEqual(pasteboard.string(forType: .string), "MY_API_KEY", "a core copy is the core's")
    }

    /// A press on the value zone copies once and lights the beat; the
    /// second click of the same press copies nothing more; the name zone's
    /// press copies the name; none of them moves the selection.
    func testAPressOnAZoneCopiesOnceLightsTheBeatAndLeavesTheSelection() throws {
        let fixture = try makeZoneFixture(#function)
        defer { fixture.pasteboard.releaseGlobally() }
        let (model, client, textView) = (fixture.model, fixture.client, fixture.textView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        InkEditorView.seat(textView, in: scroll)
        window.contentView = scroll
        name(textView, chipAt: 3, model: model, as: "MY_API_KEY")
        textView.layout()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let frame = try XCTUnwrap(textView.chipFrame(at: 3))
        let row = try XCTUnwrap(textView.chipCell(at: 3)?.namedRow(in: frame)).geometry

        // The pointer arrives before it presses, so the seat names the zone first.
        func press(_ point: NSPoint, clicks: Int) throws {
            textView.hoverRefreshInput = (
                window.convertPoint(toScreen: textView.convert(point, to: nil)), true, true)
            textView.refreshHover()
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: textView.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: clicks, pressure: 1))
            textView.mouseDown(with: event)
        }
        let value = NSPoint(x: row.value.midX, y: row.value.midY)
        try press(value, clicks: 1)
        XCTAssertEqual(client.copiedOut, [fixture.chipID])
        XCTAssertEqual(textView.copyBeat?.zone, .value)
        XCTAssertEqual(textView.copyBeat?.chip, fixture.chipID)
        try press(value, clicks: 2)
        XCTAssertEqual(client.copiedOut, [fixture.chipID], "the second click copied again")

        let namePoint = NSPoint(x: row.name.midX, y: row.name.midY)
        try press(namePoint, clicks: 1)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "MY_API_KEY")
        XCTAssertEqual(textView.copyBeat?.zone, .name)
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: 0, length: 0),
            "a zone's click moved the selection")

        // The name zone's second click opens the field and copies nothing more.
        let copies = fixture.pasteboard.changeCount
        try press(namePoint, clicks: 2)
        XCTAssertEqual(fixture.coordinator.nameEditor?.isOpen, true)
        XCTAssertEqual(fixture.pasteboard.changeCount, copies, "the second click copied again")
        XCTAssertEqual(client.copiedOut, [fixture.chipID])
    }

    /// Hover is per point: the zone under the pointer, nothing between
    /// the runs' ends and the seat, and nothing on an unnamed block.
    func testHoverFindsTheZoneUnderThePointer() throws {
        let model = try makeModel()
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        InkEditorView.seat(textView, in: scroll)
        textView.insertText(
            "SECRET", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        coordinator.sealSelectionOrLine()
        textView.layout()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let frame = try XCTUnwrap(textView.chipFrame(at: 0))
        XCTAssertNil(
            textView.chipZone(at: NSPoint(x: frame.minX + 20, y: frame.maxY - 6), chipAt: 0),
            "an unnamed row answered a zone")

        name(textView, chipAt: 0, model: model, as: "DB_PASSWORD")
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let row = try XCTUnwrap(textView.chipCell(at: 0)?.namedRow(in: frame)).geometry
        for zone in SealedBlockLayout.Zone.allCases {
            let run = switch zone {
            case .name: row.name
            case .equals: row.equals
            case .value: row.value
            }
            XCTAssertEqual(
                textView.chipZone(at: NSPoint(x: run.midX, y: run.midY), chipAt: 0), zone)
        }
        XCTAssertNil(
            textView.chipZone(at: NSPoint(x: row.value.maxX + 4, y: row.value.midY), chipAt: 0))
    }

    /// In a flipped text view, the lock, classification, and actions
    /// affordance occupy the upper row while excerpt metadata is below.
    func testTheRowsLockAndActionsUseFlippedTextViewCoordinates() {
        let frame = NSRect(x: 10, y: 100, width: 400, height: SealedBlockCell.blockHeight)
        let layout = SealedBlockCell.contentLayout(in: frame)
        let seat = SealedBlockCell.actionsRect(in: frame)
        XCTAssertTrue(frame.contains(layout.lockRect), "the lock hung off the block")
        XCTAssertLessThan(layout.topRowY, layout.bottomRowY, "the rows were vertically reversed")
        XCTAssertLessThan(layout.lockRect.midY, frame.midY, "the lock was not on the top row")
        XCTAssertTrue(frame.contains(seat), "the seat hung off the block")
        XCTAssertEqual(seat.maxX, frame.maxX - 12, "the seat did not share the metadata's inset")
        XCTAssertLessThan(seat.midY, frame.midY, "the seat was not on the top row")
        XCTAssertEqual(SealedBlockCell.actionsGlyph, "···")
    }

    func testTheActionsSeatIgnoresStateFlagsButRejectsGestureModifiersAndLaterClicks() {
        XCTAssertTrue(InkTextView.shouldOpenChipActions(
            clickCount: 1, modifierFlags: []))
        XCTAssertTrue(InkTextView.shouldOpenChipActions(
            clickCount: 1, modifierFlags: .capsLock))
        XCTAssertTrue(InkTextView.shouldOpenChipActions(
            clickCount: 1, modifierFlags: .function))
        XCTAssertFalse(InkTextView.shouldOpenChipActions(
            clickCount: 2, modifierFlags: []))
        XCTAssertFalse(InkTextView.shouldOpenChipActions(
            clickCount: 1, modifierFlags: .command))
        XCTAssertFalse(InkTextView.shouldOpenChipActions(
            clickCount: 1, modifierFlags: .shift))
    }

    func testControlPrimaryTakesTheDirectContextMenuRoute() {
        XCTAssertTrue(InkTextView.shouldOpenChipContextMenu(
            clickCount: 1, modifierFlags: .control))
        XCTAssertTrue(InkTextView.shouldOpenChipContextMenu(
            clickCount: 1, modifierFlags: [.control, .capsLock]))
        XCTAssertFalse(InkTextView.shouldOpenChipContextMenu(
            clickCount: 2, modifierFlags: .control))
        XCTAssertFalse(InkTextView.shouldOpenChipContextMenu(
            clickCount: 1, modifierFlags: [.control, .option]))
    }

    /// An unwrapped editor, as the page mounts one: an effectively
    /// infinite container inside a scroll view, so only the captured
    /// viewport measure can size a block. The layout manager is the
    /// caller's so a test can stand a recording one in.
    private struct UnwrappedEditor {
        let storage: NSTextStorage
        let container: NSTextContainer
        let scroll: NSScrollView
        let textView: InkTextView
    }

    private func mountUnwrappedEditor(
        layoutManager: NSLayoutManager = NSLayoutManager(),
        scrollWidth: CGFloat = 480,
        inset: NSSize
    ) -> UnwrappedEditor {
        let storage = NSTextStorage()
        let container = InkTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: scrollWidth, height: 300))
        let textView = InkTextView(
            frame: scroll.contentView.bounds,
            textContainer: container
        )
        textView.textContainerInset = inset
        scroll.documentView = textView
        return UnwrappedEditor(
            storage: storage, container: container, scroll: scroll, textView: textView)
    }

    private func chip(_ id: UInt64, excerpt: String) -> NSAttributedString {
        InkEditorView.Coordinator.chipString(ChipInfo(
            chipId: id,
            kind: "text",
            excerpt: excerpt,
            sizeLabel: "small",
            concealed: false
        ))
    }

    /// This exercises the TextKit 1 attachment-cell path used by the
    /// editor rather than calling the attachment's bounds method directly.
    /// The container inset is not zero here on purpose: in unwrapped
    /// mode the captured measure is the only thing that knows about
    /// it, and a block that forgot it ran wider than the page.
    func testLiveAttachmentLayoutUsesTheEditorMeasure() throws {
        let inset = NSSize(width: 12, height: 12)
        let editor = mountUnwrappedEditor(inset: inset)
        let (storage, container, scroll, textView) =
            (editor.storage, editor.container, editor.scroll, editor.textView)
        let layoutManager = try XCTUnwrap(container.layoutManager)
        storage.append(chip(7, excerpt: "sk-live-…9Qz"))

        textView.layout()
        layoutManager.ensureLayout(for: container)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualCharacterRange: nil
        )
        XCTAssertEqual(glyphRange.length, 1)
        let attachmentSize = layoutManager.attachmentSize(forGlyphAt: glyphRange.location)
        let glyphBounds = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: container)
        let expectedWidth = floor(
            scroll.contentSize.width - inset.width * 2 - container.lineFragmentPadding * 2)

        XCTAssertEqual(attachmentSize.width, expectedWidth, accuracy: 0.5)
        XCTAssertEqual(glyphBounds.width, expectedWidth, accuracy: 0.5)
        XCTAssertEqual(attachmentSize.height, SealedBlockCell.blockHeight, accuracy: 0.5)
        XCTAssertNotEqual(
            attachmentSize.width, SealedBlockCell.fallbackBlockWidth,
            "live layout used the fallback cell width")
        XCTAssertGreaterThan(glyphBounds.height, 0)
        XCTAssertLessThanOrEqual(
            textView.textContainerOrigin.x + glyphBounds.maxX + inset.width,
            scroll.contentSize.width,
            "the block ran past the page measure and forced a horizontal scroll")
    }

    /// A viewport that has not been sized yet measures nothing. That
    /// zero must not be captured: captured, it is a ceiling every
    /// candidate fails, and every block collapses to the floor until
    /// another pass. The earlier capture stays until a real one comes.
    func testAZeroWidthViewportLeavesTheEarlierMeasureInPlace() throws {
        let editor = mountUnwrappedEditor(inset: .zero)
        let (storage, container, scroll, textView) =
            (editor.storage, editor.container, editor.scroll, editor.textView)
        let layoutManager = try XCTUnwrap(container.layoutManager)
        storage.append(chip(9, excerpt: "unsized"))
        textView.layout()
        layoutManager.ensureLayout(for: container)
        let sizedWidth = layoutManager.attachmentSize(forGlyphAt: 0).width
        XCTAssertEqual(
            sizedWidth, floor(480 - container.lineFragmentPadding * 2), accuracy: 0.5)

        scroll.setFrameSize(NSSize(width: 0, height: 300))
        XCTAssertEqual(scroll.contentSize.width, 0, "the viewport did not collapse")
        textView.layout()
        layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: storage.length),
            actualCharacterRange: nil
        )
        layoutManager.ensureLayout(for: container)

        XCTAssertEqual(
            layoutManager.attachmentSize(forGlyphAt: 0).width, sizedWidth, accuracy: 0.5,
            "a zero measure was captured and the block fell to the floor")
    }

    /// The frame `chipFrame(at:)` answers, the one a click is tested
    /// against, must be the frame the layout manager draws the block
    /// with. A block sealed out of the middle of a line shares that
    /// line with ink, and the ink's ascent rises above the block's own
    /// four points, so the glyph's bounding rect, which takes the
    /// line's used height, starts above the drawn block and stands
    /// taller than it; a seat computed off it misses the drawn glyph.
    /// The paragraph has extra leading as well, to hold that paragraph
    /// spacing above the block moves neither frame. The cell records
    /// the frame it is drawn with, so the two are compared, not eyed.
    func testTheClickFrameIsTheDrawnFrameWhenInkSharesTheLine() throws {
        let editor = mountUnwrappedEditor(inset: NSSize(width: 12, height: 10))
        let (storage, container, textView) = (editor.storage, editor.container, editor.textView)
        let layoutManager = try XCTUnwrap(container.layoutManager)
        let ink: [NSAttributedString.Key: Any] = [.font: InkStyle.font(for: .body)]
        storage.append(NSAttributedString(string: "a line above\nab ", attributes: ink))
        let chipIndex = storage.length
        storage.append(chip(11, excerpt: "inline"))
        storage.append(NSAttributedString(string: " cd", attributes: ink))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 20
        storage.addAttribute(
            .paragraphStyle, value: style,
            range: NSRange(location: chipIndex - 3, length: storage.length - chipIndex + 3))
        let cell = try XCTUnwrap(
            (storage.attribute(.attachment, at: chipIndex, effectiveRange: nil) as? ChipAttachment)?
                .attachmentCell as? SealedBlockCell)

        textView.layout()
        layoutManager.ensureLayout(for: container)
        let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)

        let drawn = try XCTUnwrap(cell.lastDrawnFrame, "the block was never drawn")
        let answered = try XCTUnwrap(textView.chipFrame(at: chipIndex))
        XCTAssertEqual(answered.minX, drawn.minX, accuracy: 0.5)
        XCTAssertEqual(answered.minY, drawn.minY, accuracy: 0.5)
        XCTAssertEqual(answered.width, drawn.width, accuracy: 0.5)
        XCTAssertEqual(answered.height, drawn.height, accuracy: 0.5)
        XCTAssertEqual(drawn.height, SealedBlockCell.blockHeight, accuracy: 0.5)
        XCTAssertNil(textView.chipFrame(at: 0), "ink answered a chip frame")

        // The case exists because the bounding rect is the wrong answer
        // here: the ink beside the block lifts it above the block and
        // stretches it, and the seat it yields is not the drawn seat.
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: chipIndex, length: 1), actualCharacterRange: nil)
        var bounding = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        bounding.origin.x += textView.textContainerOrigin.x
        bounding.origin.y += textView.textContainerOrigin.y
        XCTAssertLessThan(bounding.minY, drawn.minY, "the ink did not rise above the block; the case is moot")
        XCTAssertGreaterThan(bounding.height, drawn.height)
        XCTAssertNotEqual(
            SealedBlockCell.actionsRect(in: bounding).minY, SealedBlockCell.actionsRect(in: drawn).minY,
            "the seats agreed; the old frame would have hit")

        let outsideBlock = NSPoint(x: drawn.midX, y: bounding.minY + 0.5)
        XCTAssertTrue(bounding.contains(outsideBlock))
        XCTAssertFalse(drawn.contains(outsideBlock))
        let coordinator = InkEditorView.Coordinator(model: try makeModel())
        coordinator.textView = textView
        textView.coordinator = coordinator
        XCTAssertNil(
            coordinator.chipIndex(at: outsideBlock, in: textView),
            "hover used the glyph bounds instead of the clickable block frame")
    }

    /// A wrapped editor's finite container is already inset from the
    /// viewport, so it must win over the captured viewport measure.
    func testLiveAttachmentLayoutUsesTheWrappedContainerMeasure() throws {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 456, height: 300))
        container.widthTracksTextView = false
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        let textView = InkTextView(frame: scroll.contentView.bounds, textContainer: container)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        scroll.documentView = textView
        storage.append(InkEditorView.Coordinator.chipString(ChipInfo(
            chipId: 8,
            kind: "text",
            excerpt: "wrapped",
            sizeLabel: "small",
            concealed: false
        )))

        textView.layout()
        layoutManager.ensureLayout(for: container)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualCharacterRange: nil
        )
        let attachmentSize = layoutManager.attachmentSize(forGlyphAt: glyphRange.location)
        let expectedWidth = floor(container.size.width - container.lineFragmentPadding * 2)

        XCTAssertEqual(attachmentSize.width, expectedWidth, accuracy: 0.5)
        XCTAssertLessThan(attachmentSize.width, scroll.contentSize.width)
        XCTAssertNotEqual(attachmentSize.width, SealedBlockCell.fallbackBlockWidth)
    }

    /// Return and Space, bare, are the two keys that open a selected
    /// object's menu; with any modifier, or as any other key, they are
    /// typing and fall through to the editor.
    func testReturnAndSpaceOpenTheObjectsMenuAndNothingElseDoes() {
        XCTAssertTrue(InkTextView.opensObjectMenu(characters: "\r", modifiers: []))
        XCTAssertTrue(InkTextView.opensObjectMenu(characters: "\n", modifiers: []))
        XCTAssertTrue(InkTextView.opensObjectMenu(characters: " ", modifiers: []))
        XCTAssertFalse(InkTextView.opensObjectMenu(characters: "\r", modifiers: [.command]),
            "cmd-return is the seal chord, not the menu")
        XCTAssertFalse(InkTextView.opensObjectMenu(characters: " ", modifiers: [.shift]))
        XCTAssertFalse(InkTextView.opensObjectMenu(characters: "a", modifiers: []))
        XCTAssertFalse(InkTextView.opensObjectMenu(characters: nil, modifiers: []))
        XCTAssertTrue(
            InkTextView.opensObjectMenu(characters: "\r", modifiers: [.numericPad, .function]),
            "the keypad's return is still return")
    }

    // MARK: The caret and the selection (Law 0001)

    /// `ab <object> cd`, laid out in a window with the keys, the object at 3.
    private func caretPage() throws -> (InkTextView, NSWindow) {
        let model = try makeModel()
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = InkEditorView.bareScroller()
        scroll.frame = window.contentLayoutRect
        InkEditorView.seat(textView, in: scroll)
        window.contentView = scroll
        textView.isEditable = true
        window.makeFirstResponder(textView)
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        XCTAssertNotNil(coordinator.chipAttachment(at: 3), "the fixture holds no object at 3")
        XCTAssertEqual(textView.textStorage?.length, 7)
        return (textView, window)
    }

    /// One arrow press takes the caret over the object, either way.
    func testTheCaretCrossesAnObjectAsOneUnitBothWays() throws {
        let (textView, window) = try caretPage()
        defer { window.close() }
        let caret = { textView.selectedRange() }

        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.moveRight(nil)
        XCTAssertEqual(caret(), NSRange(location: 4, length: 0), "→ stopped inside the object")
        textView.moveLeft(nil)
        XCTAssertEqual(caret(), NSRange(location: 3, length: 0), "← stopped inside the object")

        var walked: [Int] = []
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        for _ in 0..<7 {
            textView.moveRight(nil)
            walked.append(caret().location)
        }
        XCTAssertEqual(walked, [1, 2, 3, 4, 5, 6, 7], "→ took two presses over the object")
        walked = []
        for _ in 0..<7 {
            textView.moveLeft(nil)
            walked.append(caret().location)
        }
        XCTAssertEqual(walked, [6, 5, 4, 3, 2, 1, 0], "← took two presses over the object")
    }

    /// Every shift extension holds the object whole or leaves it out.
    func testAShiftSelectionHoldsTheWholeObjectOrNoneOfIt() throws {
        let (textView, window) = try caretPage()
        defer { window.close() }
        let object = NSRange(location: 3, length: 1)

        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.moveRightAndModifySelection(nil)
        XCTAssertEqual(
            NSIntersectionRange(textView.selectedRange(), object), object,
            "⇧→ from before the object did not take it whole")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        textView.moveLeftAndModifySelection(nil)
        XCTAssertEqual(
            NSIntersectionRange(textView.selectedRange(), object), object,
            "⇧← from after the object did not take it whole")

        let extensions = [
            #selector(NSResponder.moveRightAndModifySelection(_:)),
            #selector(NSResponder.moveLeftAndModifySelection(_:)),
            #selector(NSResponder.moveWordRightAndModifySelection(_:)),
            #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
            #selector(NSResponder.moveUpAndModifySelection(_:)),
            #selector(NSResponder.moveDownAndModifySelection(_:)),
            #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)),
            #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)),
        ]
        for start in 0...7 {
            for extend in extensions {
                textView.setSelectedRange(NSRange(location: start, length: 0))
                for _ in 0..<3 {
                    textView.doCommand(by: extend)
                    let held = NSIntersectionRange(textView.selectedRange(), object).length
                    XCTAssertTrue(
                        held == 0 || NSLocationInRange(object.location, textView.selectedRange()),
                        "\(extend) from \(start) held part of the object")
                    XCTAssertTrue(held == 0 || held == object.length)
                }
            }
        }
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.moveToEndOfDocumentAndModifySelection(nil)
        XCTAssertEqual(NSIntersectionRange(textView.selectedRange(), object), object)
        XCTAssertTrue(
            InkEditorView.Coordinator.containsChip(
                try XCTUnwrap(textView.textStorage), in: textView.selectedRange()))
    }

    // MARK: The lines

    /// The copy line names what was copied, its size class and the
    /// interval; the link line says where the link is and what to do
    /// with it; the removal line says what happened.
    func testTheLinesReadAsTheDesignWroteThem() {
        XCTAssertEqual(
            PageModel.copiedLine(clearsIn: 60, size: "small"),
            "copied decrypted contents — small. the clipboard clears in 60 seconds.")
        XCTAssertEqual(
            PageModel.copiedLine(clearsIn: 60),
            "copied decrypted contents. the clipboard clears in 60 seconds.")
        XCTAssertEqual(
            PageModel.linkCopiedLine,
            "the link is on the clipboard — paste it where it needs to go.")
        XCTAssertEqual(PageModel.removedLine, "sealed content removed.")
    }

    /// The sheet's tooltip and its error lines say one-time link, in the
    /// menu's verb; conceal stays the code's word (ADR-0055 rule 3, issue #295).
    func testTheSheetNamesTheLinkAndNotTheServersVerb() {
        XCTAssertEqual(ConcealView.destinationHelp, "the server this one-time link is created on")
        XCTAssertEqual(
            ConcealView.failureLabel("refused"), "Could not create the link: refused")
        XCTAssertEqual(PageModel.linkFailedLine, "the link was not created")
    }

    /// The fallback already says the link failed, so VoiceOver reads it without
    /// the prefix; a named reason keeps it (issue #295).
    func testTheSpokenFallbackSaysTheOutcomeOnce() {
        XCTAssertEqual(
            ConcealView.failureLabel(PageModel.linkFailedLine), "the link was not created")
        XCTAssertEqual(
            ConcealView.failureLabel("there is nothing to send"),
            "Could not create the link: there is nothing to send")
    }

    /// Options the client could not encode reach the sheet as the fallback, and
    /// the client's diagnostic never does (issue #295).
    func testTheSheetNeverShowsTheClientsEncodingDiagnostic() throws {
        let outcome = CompanionClient.unencodableOptionsOutcome()
        XCTAssertFalse(outcome.ok)
        XCTAssertNil(outcome.error)

        let model = try makeModel()
        model.newPage()
        let target = ConcealDraft.Target.page(try XCTUnwrap(model.selectedPageID))
        model.beginConceal(target)
        let draftID = try XCTUnwrap(model.concealDraft?.id)
        model.finishConceal(outcome, for: target, draftID: draftID)

        let shown = try XCTUnwrap(model.concealDraft?.error)
        XCTAssertEqual(shown, PageModel.linkFailedLine)
        XCTAssertFalse(
            ConcealView.failureLabel(shown).localizedCaseInsensitiveContains("conceal"),
            "\(shown) says conceal, which rule 3 keeps for the code and the server")
    }

    /// A removal flashes its line with Undo beside it (D-30), since the core
    /// keeps the object detached; withdrawn, the words stay and the button goes.
    func testARemovalFlashesItsLineWithUndoAndAWithdrawalKeepsOnlyTheWords() throws {
        let model = try makeModel()
        model.newPage()
        let sheet = try XCTUnwrap(model.selectedPageID)
        XCTAssertTrue(PageModel.offersRemovalUndo)
        model.noteRemoval(sheet: sheet)
        XCTAssertEqual(model.notice, PageModel.removedLine)
        XCTAssertEqual(model.noticeTone, .plain)
        XCTAssertEqual(model.noticeAction?.label, "Undo")

        model.withdrawRemovalUndo()
        XCTAssertEqual(model.notice, PageModel.removedLine)
        XCTAssertNil(model.noticeAction)

        // Another line's button is not the removal's to withdraw.
        var undone = 0
        model.flash("a line with a button", action: .init(label: "Undo") { undone += 1 })
        model.withdrawRemovalUndo()
        XCTAssertEqual(model.noticeAction?.label, "Undo")
        model.performNoticeAction()
        XCTAssertEqual(undone, 1)
    }

    /// A notice's action runs once and takes the line down with it;
    /// the next plain notice carries no action of its own.
    func testANoticeActionRunsOnceAndClearsTheLine() throws {
        let model = try makeModel()
        var ran = 0
        model.flash("a line with a button", action: .init(label: "Undo") { ran += 1 })
        XCTAssertEqual(model.noticeAction?.label, "Undo")
        model.performNoticeAction()
        XCTAssertEqual(ran, 1)
        XCTAssertNil(model.notice)
        XCTAssertNil(model.noticeAction)
        model.performNoticeAction()
        XCTAssertEqual(ran, 1, "a spent action ran again")

        model.flash("a plain line")
        XCTAssertNil(model.noticeAction, "a plain notice inherited the last one's button")
    }
}
