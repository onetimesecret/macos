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
        let textView = InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator)
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()

        let menu = try XCTUnwrap(coordinator.chipMenu(at: 3))
        let copy = try XCTUnwrap(menu.items.first {
            $0.title == "Copy decrypted contents"
        })
        let link = try XCTUnwrap(menu.items.first {
            $0.title == "Create one-time link…"
        })
        let remove = try XCTUnwrap(menu.items.first {
            $0.title == "Remove protected content"
        })
        XCTAssertEqual(copy.title, "Copy decrypted contents")
        XCTAssertEqual(link.title, "Create one-time link…")
        XCTAssertEqual(remove.title, "Remove protected content")
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
    /// The paragraph is labeled as well, to hold that the label
    /// reserve above the block moves neither frame. The cell records
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
        style.paragraphSpacingBefore = InkEditorView.Coordinator.blockLabelReserve
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
        XCTAssertEqual(PageModel.removedLine, "protected content removed.")
    }

    /// A removal flashes its line. Undo is owed to issue 170 and not
    /// offered until the core keeps a detached object to reattach; the
    /// gate is one constant, so the button appears the moment it flips.
    func testARemovalFlashesItsLineAndOffersUndoOnlyWhenTheCoreCan() throws {
        let model = try makeModel()
        var undone = 0
        model.noteRemoval { undone += 1 }
        XCTAssertEqual(model.notice, PageModel.removedLine)
        XCTAssertEqual(model.noticeTone, .plain)
        if PageModel.offersRemovalUndo {
            XCTAssertEqual(model.noticeAction?.label, "Undo")
        } else {
            XCTAssertNil(model.noticeAction, "an Undo was offered that the core cannot honour")
        }
        XCTAssertEqual(undone, 0)
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
