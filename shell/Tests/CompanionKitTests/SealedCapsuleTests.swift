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

        let menu = NSMenu()
        coordinator.appendChipItems(to: menu, at: 3)
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
        let frame = NSRect(x: 10, y: 100, width: 400, height: ChipCell.blockHeight)
        let layout = ChipCell.contentLayout(in: frame)
        let seat = ChipCell.actionsRect(in: frame)
        XCTAssertTrue(frame.contains(layout.lockRect), "the lock hung off the block")
        XCTAssertLessThan(layout.topRowY, layout.bottomRowY, "the rows were vertically reversed")
        XCTAssertLessThan(layout.lockRect.midY, frame.midY, "the lock was not on the top row")
        XCTAssertTrue(frame.contains(seat), "the seat hung off the block")
        XCTAssertEqual(seat.maxX, frame.maxX - 12, "the seat did not share the metadata's inset")
        XCTAssertLessThan(seat.midY, frame.midY, "the seat was not on the top row")
        XCTAssertEqual(ChipCell.actionsGlyph, "···")
    }

    /// This exercises the TextKit 1 attachment-cell path used by the
    /// editor rather than calling the attachment's bounds method directly.
    func testLiveAttachmentLayoutUsesTheEditorMeasure() throws {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        let textView = InkTextView(
            frame: scroll.contentView.bounds,
            textContainer: container
        )
        textView.textContainerInset = .zero
        scroll.documentView = textView
        storage.append(InkEditorView.Coordinator.chipString(ChipInfo(
            chipId: 7,
            kind: "text",
            excerpt: "sk-live-…9Qz",
            sizeLabel: "small",
            concealed: false
        )))

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
            scroll.contentSize.width - container.lineFragmentPadding * 2)

        XCTAssertEqual(attachmentSize.width, expectedWidth, accuracy: 0.5)
        XCTAssertEqual(glyphBounds.width, expectedWidth, accuracy: 0.5)
        XCTAssertEqual(attachmentSize.height, ChipCell.blockHeight, accuracy: 0.5)
        XCTAssertNotEqual(attachmentSize.width, 240, "live layout used the fallback cell width")
        XCTAssertGreaterThan(glyphBounds.height, 0)
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
        XCTAssertNotEqual(attachmentSize.width, 240)
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
