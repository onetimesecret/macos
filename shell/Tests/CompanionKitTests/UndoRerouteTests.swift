import AppKit
import XCTest

@testable import CompanionKit

/// ⌘Z was AppKit's and is the core's (issue #132).
///
/// The suite stands the editor up the way `makeNSView` wires it, over a
/// core of its own, and presses the chord the bundled keymap names. What
/// it asserts is the whole reroute: the core's document moved, the
/// storage the editor lays out moved with it, and the caret landed where
/// the core said the writer's hand had been.
///
/// The model is built with its seams named. A `PageModel` under the test
/// runner with default seams resolves to the installed app's own state
/// directory, and a suite that types into that is a suite that edits
/// somebody's real pages.
@MainActor
final class UndoRerouteTests: XCTestCase {
    /// The `z` key's place on the board, which is what an event carries.
    private let zKeyCode: UInt16 = 6

    private var model: PageModel!
    private var coordinator: InkEditorView.Coordinator!
    private var textView: InkTextView!
    private var sheet: UInt64 = 0

    /// Not a `setUp` override: those are nonisolated and this fixture is
    /// main-actor state. Every case calls it first.
    private func makeEditor() throws {
        let suiteName = "companion-undo-reroute-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        model = isolatedModel(defaults: defaults)
        model.newPage()
        sheet = try XCTUnwrap(model.selection)

        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let storage = model.storage(for: sheet)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = InkTextView(frame: .zero, textContainer: container)
        textView.isRichText = true
        textView.allowsUndo = true
        coordinator = InkEditorView.Coordinator(model: model)
        textView.coordinator = coordinator
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.currentSheet = sheet
        storage.delegate = coordinator
    }

    private var storage: NSTextStorage { model.storage(for: sheet) }

    /// The core's document, read back through the seam and flattened.
    private func coreText() -> String {
        model.coreClient.documentRuns(sheet: sheet).map {
            switch $0 {
            case .ink(let text): return text
            case .chip: return "\u{FFFC}"
            }
        }.joined()
    }

    private func type(_ text: String) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func testAStepBackTakesTheTypingOutOfTheCoreAndTheStorageTogether() throws {
        try makeEditor()
        type("a whole thought")
        XCTAssertEqual(coreText(), "a whole thought")
        XCTAssertTrue(model.canUndoEdit(sheet: sheet))

        coordinator.step(back: true)

        XCTAssertEqual(coreText(), "", "the core still holds the reverted text")
        XCTAssertEqual(storage.string, "", "the editor's storage did not follow the core")
        XCTAssertEqual(textView.selectedRange().location, 0)
        XCTAssertTrue(model.canRedoEdit(sheet: sheet))
    }

    func testAStepForwardPutsItBack() throws {
        try makeEditor()
        type("a whole thought")
        coordinator.step(back: true)
        coordinator.step(back: false)

        XCTAssertEqual(coreText(), "a whole thought")
        XCTAssertEqual(storage.string, "a whole thought")
        XCTAssertFalse(model.canRedoEdit(sheet: sheet))
    }

    /// Nothing on the stack is not an error and not a rewrite: the page
    /// stands exactly as it was, which is the fail-closed shape the seam
    /// returns and this route honours.
    func testAStepWithNothingBehindItChangesNothing() throws {
        try makeEditor()
        type("standing")
        // The whole page in one step, and then one more press.
        coordinator.step(back: true)
        XCTAssertFalse(model.canUndoEdit(sheet: sheet))

        let outcome = model.undoEdit(sheet: sheet)
        XCTAssertFalse(outcome.applied)
        XCTAssertNil(outcome.caret)
        XCTAssertEqual(coreText(), "")
        XCTAssertEqual(storage.string, "")
    }

    /// The press itself, not the method behind it: ⌘Z has to reach the
    /// text view's key-equivalent route, since that is what runs before
    /// the standard Edit menu can hand the chord to `NSUndoManager`.
    func testTheChordItselfReachesTheCore() throws {
        try makeEditor()
        type("pressed")
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "z",
                charactersIgnoringModifiers: "z",
                isARepeat: false,
                keyCode: zKeyCode
            ),
            "AppKit refused to build the event this test presses")

        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(coreText(), "")
        XCTAssertEqual(storage.string, "")
    }

    /// The caret is the core's answer, not a guess made up here: a step
    /// comes back to where it began, in the middle of a line as readily
    /// as at the start of a page.
    func testTheCaretLandsWhereTheStepBegan() throws {
        try makeEditor()
        type("alpha omega")
        // A restate empties the core's stack, so the typing that
        // follows is the first step on it and begins where the caret
        // is, well inside the line.
        model.syncDocument(sheet: sheet, runs: [.ink("alpha omega")])
        XCTAssertFalse(model.canUndoEdit(sheet: sheet))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        type(" beta")
        XCTAssertEqual(coreText(), "alpha beta omega")

        let outcome = model.undoEdit(sheet: sheet)
        XCTAssertTrue(outcome.applied)
        XCTAssertEqual(outcome.caret, 5)
        XCTAssertEqual(coreText(), "alpha omega")
    }

    /// Typing arrives as one op batch per keystroke, and the merge
    /// interval is what keeps ⌘Z from being a per-character gesture: two
    /// bursts a fraction of a second apart come back as one step.
    func testTypingInsideTheIntervalComesBackAsOneStep() throws {
        try makeEditor()
        type("alpha")
        type(" omega")
        XCTAssertEqual(coreText(), "alpha omega")

        let outcome = model.undoEdit(sheet: sheet)
        XCTAssertTrue(outcome.applied)
        XCTAssertEqual(coreText(), "", "the second burst came back on its own")
        XCTAssertEqual(outcome.caret, 0, "a merged step returns to where it began")
        XCTAssertFalse(model.canUndoEdit(sheet: sheet))
    }

    /// A step never un-seals (ADR-0009). Sealing clears the core's stack,
    /// so the chord after a seal is a no-op rather than a gesture that
    /// pulls the sentinel back out from under zeroized bytes.
    func testASealCannotBeSteppedBack() throws {
        try makeEditor()
        type("secret words")
        let chip = try XCTUnwrap(
            model.coreClient.sealText(sheet: sheet, "secret words", at: 0, length: 12))
        XCTAssertFalse(model.canUndoEdit(sheet: sheet))
        XCTAssertFalse(model.undoEdit(sheet: sheet).applied)
        XCTAssertEqual(coreText(), "\u{FFFC}")
        XCTAssertTrue(chip.chipId > 0)
    }
}
