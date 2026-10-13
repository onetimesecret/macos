import AppKit
import XCTest

@testable import CompanionKit

/// Whoever holds the keys answers the page's chords and Edit menu (ADR-0046),
/// shown with a plain field, the shape the SwiftUI rename fields edit through.
@MainActor
final class KeyHolderTests: XCTestCase {
    private struct Page {
        let model: PageModel
        let textView: InkTextView
        let field: NSTextField
        let window: NSWindow
        let sheet: UInt64
    }

    /// `let key = 1` on a page, selected whole, with a field beside it.
    private func makePage() throws -> Page {
        let suite = "companion-key-holder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        // A seal that wrongly reached the page would take the clipboard.
        XCTAssertTrue(model.coreClient.useMemoryPasteboardForTests())
        let coordinator = InkEditorView.Coordinator(model: model)
        model.newPage()
        let sheet = try XCTUnwrap(model.selectedPageID)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: sheet, coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentLayoutRect)
        let scroll = InkEditorView.bareScroller()
        scroll.frame = NSRect(x: 0, y: 40, width: 520, height: 320)
        InkEditorView.seat(textView, in: scroll)
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 200, height: 24))
        content.addSubview(scroll)
        content.addSubview(field)
        window.contentView = content
        textView.isEditable = true
        window.makeFirstResponder(textView)
        textView.insertText(
            "let key = 1", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: 11))
        drainMainQueue()
        return Page(model: model, textView: textView, field: field, window: window, sheet: sheet)
    }

    private func chord(
        _ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private func ink(_ page: Page) -> String {
        page.model.coreClient.documentRuns(sheet: page.sheet).reduce(into: "") {
            if case .ink(let ink) = $1 { $0 += ink }
        }
    }

    /// With a field holding the keys the page takes none of its chords,
    /// answers none of the Edit menu's actions, and the menu greys them.
    func testAFieldHoldingTheKeysTakesThePagesChordsAndMenuAway() throws {
        let page = try makePage()
        XCTAssertTrue(page.textView.answersChords, "the control: the page holds the keys")
        XCTAssertTrue(page.model.languageActions.canChoose, "the control: a line of code chooses")
        XCTAssertTrue(page.model.sealActions.canSeal, "the control: a selection seals")
        let before = ink(page)
        let undoable = page.model.canUndoEdit(sheet: page.sheet)
        XCTAssertTrue(undoable, "the fixture has nothing to step")

        XCTAssertTrue(page.window.makeFirstResponder(page.field))
        drainMainQueue()
        XCTAssertTrue(page.textView.yieldsKeys)
        XCTAssertFalse(page.textView.answersChords)
        for (characters, keyCode, flags) in [
            ("z", UInt16(6), NSEvent.ModifierFlags.command), ("z", 6, [.command, .shift]),
            ("\r", 36, .command), ("v", 9, [.command, .shift]),
        ] {
            let event = try chord(characters, keyCode: keyCode, flags: flags, in: page.window)
            XCTAssertFalse(
                page.textView.performKeyEquivalent(with: event),
                "the page took \(flags) \(characters) under the field")
        }
        for action in pageMenuActions {
            XCTAssertFalse(
                answerer(of: action, in: page.window) is InkTextView,
                "\(action) reached the page from the field")
        }
        page.textView.undo(nil)
        page.textView.sealSelectedContent(nil)
        page.textView.chooseCodeLanguage(CodeLanguageChoice(language: "swift"))
        XCTAssertEqual(ink(page), before, "the page moved under the field")
        XCTAssertEqual(page.model.canUndoEdit(sheet: page.sheet), undoable)
        let undoItem = NSMenuItem(
            title: "Undo", action: #selector(EditStepResponder.undo(_:)), keyEquivalent: "")
        XCTAssertFalse(page.textView.validateMenuItem(undoItem))
        XCTAssertFalse(page.model.languageActions.canChoose, "the menu offered the page's language")
        XCTAssertFalse(page.model.languageActions.canDetect)
        XCTAssertFalse(page.model.languageActions.canPaste)
        XCTAssertFalse(page.model.sealActions.canSeal, "the menu offered the page's seal")

        XCTAssertTrue(page.window.makeFirstResponder(page.textView))
        drainMainQueue()
        XCTAssertTrue(page.textView.answersChords)
        XCTAssertTrue(page.model.languageActions.canChoose, "the menu did not come back to the page")
        page.textView.chooseCodeLanguage(CodeLanguageChoice(language: "swift"))
        XCTAssertEqual(ink(page), "```swift\nlet key = 1\n```", "Choose Language missed the page")
    }
}
