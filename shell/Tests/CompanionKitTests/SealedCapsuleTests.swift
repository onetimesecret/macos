import AppKit
import XCTest

@testable import CompanionKit

/// The sealed block's actions and the lines that follow them, as the
/// stream navigator design drew them (2026-09-15): the menu with its
/// chord and its red removal, the actions glyph's seat, and the three
/// notices. Words and rectangles, no window.
@MainActor
final class SealedCapsuleTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suite = "companion-sealed-capsule-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return isolatedModel(defaults: defaults)
    }

    // MARK: The menu

    /// Copy decrypted advertises the keymap's chord beside the verb,
    /// and the removal is set in red as well as apart.
    func testTheMenuAdvertisesTheChordAndSetsRemovalInRed() throws {
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
        XCTAssertEqual(menu.items.count, 4)
        let chord = try XCTUnwrap(model.keymap.hintKeystroke(for: .chipCopyDecrypted))
        XCTAssertEqual(chord.displaySymbol, "⇧⌘C")
        XCTAssertEqual(menu.items[0].keyEquivalent, "c")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [.command, .shift])
        let title = try XCTUnwrap(menu.items[3].attributedTitle)
        XCTAssertEqual(title.string, "Remove protected content")
        XCTAssertEqual(
            title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            NSColor.systemRed)

        // The chord acts on exactly one selected object and on nothing
        // else, so it can never reach a payload nobody pointed at.
        textView.setSelectedRange(NSRange(location: 3, length: 1))
        XCTAssertEqual(coordinator.selectedChipIndex, 3)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(coordinator.selectedChipIndex)
        textView.setSelectedRange(NSRange(location: 2, length: 2))
        XCTAssertNil(coordinator.selectedChipIndex, "a mixed selection offered the chord a payload")
    }

    /// The actions glyph keeps a seat in the block's top trailing
    /// corner, inside the block, whether or not it is drawn.
    func testTheActionsGlyphSitsInTheBlocksTopTrailingCorner() {
        let frame = NSRect(x: 10, y: 100, width: 400, height: ChipCell.blockHeight)
        let seat = ChipCell.actionsRect(in: frame)
        XCTAssertTrue(frame.contains(seat), "the seat hung off the block")
        XCTAssertEqual(seat.maxX, frame.maxX - 12, "the seat did not share the metadata's inset")
        // The block is drawn in a flipped text view: the top row is the
        // one nearer `minY`.
        XCTAssertLessThan(seat.midY, frame.midY, "the seat was not on the top row")
        XCTAssertEqual(ChipCell.actionsGlyph, "···")
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
            PageModel.copiedLine(clearsIn: 90, size: "small"),
            "copied decrypted contents — small. the clipboard clears in 90 seconds.")
        XCTAssertEqual(
            PageModel.copiedLine(clearsIn: 90),
            "copied decrypted contents. the clipboard clears in 90 seconds.")
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
