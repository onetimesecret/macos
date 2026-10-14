import AppKit
import XCTest

@testable import CompanionKit

/// Law 0001's backspace rows (D-30, ADR-0047 point 4): the first press beside
/// an object selects it, the second detaches it, and the removal line's Undo
/// stands the same object again, against the live core.
@MainActor
final class SealedRemovalTests: XCTestCase {
    private struct Page {
        let model: PageModel
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let field: NSTextField
        let window: NSWindow
        let sheet: UInt64
        let chips: [UInt64]
    }

    /// `ab <SECRET> cd <TOKEN> ef`, twelve units, objects at 3 and 8, the page holding the keys.
    private func makePage() throws -> Page {
        let suite = "companion-sealed-removal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-sealed-removal-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = CompanionClient.ephemeral(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        let model = PageModel(
            formFactor: .backdrop, defaults: defaults,
            seams: .init(
                stateDirectory: directory, client: client,
                clearClipboardIfOurs: { false }, ambientPasteboard: pasteboard))
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let sheet = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: sheet, coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentLayoutRect)
        let scroll = InkEditorView.bareScroller()
        scroll.frame = NSRect(x: 0, y: 40, width: 520, height: 360)
        InkEditorView.seat(textView, in: scroll)
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 200, height: 24))
        content.addSubview(scroll)
        content.addSubview(field)
        window.contentView = content
        textView.isEditable = true
        textView.insertText(
            "ab SECRET cd TOKEN ef", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()
        textView.setSelectedRange(NSRange(location: 8, length: 5))
        coordinator.sealSelectionOrLine()
        textView.layout()
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let chips = try [3, 8].map { try XCTUnwrap(coordinator.chipAttachment(at: $0)?.info.chipId) }
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        drainMainQueue()
        model.notice = nil
        return Page(
            model: model, coordinator: coordinator, textView: textView, field: field,
            window: window, sheet: sheet, chips: chips)
    }

    private func chips(_ page: Page) -> [UInt64] {
        page.model.coreClient.documentRuns(sheet: page.sheet).compactMap {
            if case .chip(let chip) = $0 { chip.chipId } else { nil }
        }
    }

    private func length(_ page: Page) -> Int? { page.textView.textStorage?.length }

    /// Two presses take the first object: the caret after it, then its selection.
    private func removeFirstObject(_ page: Page) {
        page.textView.setSelectedRange(NSRange(location: 4, length: 0))
        page.textView.deleteBackward(nil)
        page.textView.deleteBackward(nil)
    }

    // MARK: Two presses

    /// A backspace after an object selects it whole and removes nothing; the
    /// second removes it, and the line says so with Undo beside it (D-30).
    func testTheFirstBackspaceBesideAnObjectSelectsItAndTheSecondRemovesIt() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 4, length: 0))

        page.textView.deleteBackward(nil)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 3, length: 1))
        XCTAssertEqual(chips(page), page.chips, "the first press removed the object")
        XCTAssertEqual(length(page), 12)
        XCTAssertNil(page.model.notice, "the first press said something")

        page.textView.deleteBackward(nil)
        XCTAssertEqual(chips(page), [page.chips[1]])
        XCTAssertEqual(length(page), 11)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(page.model.notice, PageModel.removedLine)
        XCTAssertEqual(page.model.noticeAction?.label, "Undo")
    }

    /// A forward delete before an object follows the same two presses.
    func testTheFirstForwardDeleteBeforeAnObjectSelectsItAndTheSecondRemovesIt() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 8, length: 0))

        page.textView.deleteForward(nil)
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 8, length: 1))
        XCTAssertEqual(chips(page), page.chips)

        page.textView.deleteForward(nil)
        XCTAssertEqual(chips(page), [page.chips[0]])
        XCTAssertEqual(page.model.notice, PageModel.removedLine)
        XCTAssertEqual(page.model.noticeAction?.label, "Undo")
    }

    /// Beside ink a press deletes one character, as it always did, and says nothing.
    func testAPressBesideInkDeletesOneCharacter() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 3, length: 0))
        page.textView.deleteBackward(nil)
        XCTAssertEqual(page.textView.string.prefix(2), "ab")
        XCTAssertEqual(length(page), 11)
        page.textView.setSelectedRange(NSRange(location: 3, length: 0))
        page.textView.deleteForward(nil)
        XCTAssertEqual(length(page), 10)
        XCTAssertEqual(chips(page), page.chips)
        XCTAssertNil(page.model.notice)
    }

    /// A selection of ink and an object goes in one press and offers the same Undo.
    func testASelectionHoldingAnObjectGoesInOnePressWithUndo() throws {
        let page = try makePage()
        page.textView.setSelectedRange(NSRange(location: 1, length: 4))
        page.textView.deleteBackward(nil)
        XCTAssertEqual(chips(page), [page.chips[1]])
        XCTAssertEqual(page.model.notice, PageModel.removedLine)

        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips, "Undo did not stand the object again")
        XCTAssertEqual(length(page), 12)
    }

    // MARK: Undo

    /// The line's Undo reattaches the removed instance, not a clone, and
    /// selects it again; the line goes with it.
    func testTheRemovalLinesUndoStandsTheSameObjectAgain() throws {
        let page = try makePage()
        removeFirstObject(page)
        XCTAssertEqual(chips(page), [page.chips[1]])

        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips, "Undo stood another object or none")
        XCTAssertEqual(page.coordinator.chipAttachment(at: 3)?.info.chipId, page.chips[0])
        XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 3, length: 1))
        XCTAssertNil(page.model.notice)
        XCTAssertNil(page.model.noticeAction)
    }

    /// The removal is its own step: a deletion after it is undone first, and
    /// the next ⌘Z stands the object.
    func testARemovalIsItsOwnStep() throws {
        let page = try makePage()
        removeFirstObject(page)
        page.textView.deleteBackward(nil)
        XCTAssertEqual(length(page), 10)

        page.coordinator.step(back: true)
        XCTAssertEqual(length(page), 11)
        XCTAssertEqual(chips(page), [page.chips[1]], "one ⌘Z undid the removal with the ink")
        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page), page.chips)
    }

    /// Once the page moves past the removal, by an edit or another page, the
    /// line keeps its words and loses its Undo, which would step back the wrong edit.
    func testTheUndoGoesOnceThePageMovesPastTheRemoval() throws {
        let page = try makePage()
        removeFirstObject(page)
        page.textView.setSelectedRange(NSRange(location: 0, length: 0))
        page.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(page.model.notice, PageModel.removedLine)
        XCTAssertNil(page.model.noticeAction, "an Undo that would take the typing back")

        page.coordinator.step(back: true)
        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page), page.chips)
        removeFirstObject(page)
        XCTAssertNotNil(page.model.noticeAction)
        let undo = try XCTUnwrap(page.model.noticeAction)
        page.model.newPage()
        page.coordinator.currentSheet = page.model.selectedPageID
        XCTAssertNil(page.model.noticeAction, "an Undo aimed at another page")

        undo.perform()
        XCTAssertEqual(chips(page), [page.chips[1]], "a stale Undo stepped a page back")
    }

    /// The object's menu removes through the same line and the same Undo.
    func testTheMenusRemovalOffersTheSameUndo() throws {
        let page = try makePage()
        let menu = try XCTUnwrap(page.coordinator.chipMenu(at: 8))
        let remove = try XCTUnwrap(menu.items.first { $0.title == "Remove Sealed Content" })
        _ = (remove.target as? NSObject)?.perform(remove.action, with: remove)
        XCTAssertEqual(chips(page), [page.chips[0]])
        XCTAssertEqual(page.model.noticeAction?.label, "Undo")

        page.model.performNoticeAction()
        XCTAssertEqual(chips(page), page.chips)
    }

    // MARK: Standing aside

    /// While a field or the note holds the keys, the page's backspace and
    /// forward delete select and remove nothing, and the line's Undo waits
    /// and says so; ⌘Z on the page brings the object back once it has the keys.
    func testBackspaceAndTheUndoStandAsideWhileAFieldOrTheNoteHoldsTheKeys() throws {
        let page = try makePage()
        removeFirstObject(page)
        XCTAssertEqual(chips(page), [page.chips[1]])
        let besideTheOther = NSRange(location: 8, length: 0)

        func standsAside(_ holder: String) {
            XCTAssertFalse(page.textView.answersChords, holder)
            page.textView.setSelectedRange(besideTheOther)
            page.textView.deleteBackward(nil)
            XCTAssertEqual(page.textView.selectedRange(), besideTheOther, holder)
            page.textView.setSelectedRange(NSRange(location: 7, length: 1))
            page.textView.deleteBackward(nil)
            page.textView.setSelectedRange(NSRange(location: 7, length: 0))
            page.textView.deleteForward(nil)
            XCTAssertEqual(page.textView.selectedRange(), NSRange(location: 7, length: 0), holder)
            XCTAssertEqual(chips(page), [page.chips[1]], holder)
            XCTAssertEqual(length(page), 11, holder)
        }

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        page.model.performNoticeAction()
        XCTAssertEqual(page.model.notice, PageModel.undoWaitsLine)
        XCTAssertEqual(chips(page), [page.chips[1]], "the Undo stepped the page under the field")
        standsAside("field")

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        page.coordinator.beginNote(at: 7)
        let note = try XCTUnwrap(page.coordinator.noteEditor)
        drainMainQueue()
        XCTAssertTrue(note.holdsKeys)
        standsAside("note")

        note.escape()
        drainMainQueue()
        XCTAssertTrue(page.window.firstResponder === page.textView)
        page.coordinator.step(back: true)
        XCTAssertEqual(chips(page), page.chips, "the removal did not come back")
    }
}
