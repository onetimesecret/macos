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
/// One part of the route is left uncovered: the scroll that follows a
/// step. The editor stood up here has no scroll view around it, and
/// wrapping it in one so a case could assert that a scroller moved
/// would be testing AppKit's scrolling rather than anything this route
/// decides.
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

        // The shipping factory rather than a hand-wired view, because
        // several of these cases are about flags the factory sets: what
        // AppKit is allowed to hold, and whether the page accepts
        // typing at all.
        coordinator = InkEditorView.Coordinator(model: model)
        textView = InkEditorView.makeInkTextView(
            model: model, sheetID: sheet, coordinator: coordinator
        )
        textView.isEditable = true
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.currentSheet = sheet
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

    /// A step rewrites the storage from the core's runs, which are
    /// plain text under the base font. Nothing on the step's own path
    /// fires `textDidChange`, and `updateNSView` turns back at the
    /// unchanged page, so unless the step lays the styling down itself
    /// the page reads as unstyled prose until the writer types the next
    /// character.
    func testAStepLeavesTheStylingStanding() throws {
        try makeEditor()
        type("# heading")
        let styledFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertEqual(
            styledFont, InkStyle.headingFont(level: 1),
            "the fixture never got its styling in the first place")

        // A restate empties the core's stack, so the keystroke after it
        // is the whole of the step this case takes back.
        model.syncDocument(sheet: sheet, runs: [.ink("# heading")])
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        type("!")

        coordinator.step(back: true)

        XCTAssertEqual(storage.string, "# heading")
        XCTAssertEqual(
            storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont,
            InkStyle.headingFont(level: 1),
            "the heading came back at body weight")
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            NSColor.tertiaryLabelColor,
            "the marker came back undimmed")
    }

    /// The gate is `step`'s own. Both routes that exist check editing
    /// before they call it, and the point of the guard inside is the
    /// route nobody has written yet.
    func testTheStepRouteRefusesAPageThatIsNotEditable() throws {
        try makeEditor()
        type("standing")
        textView.isEditable = false

        coordinator.step(back: true)

        XCTAssertEqual(coreText(), "standing")
        XCTAssertEqual(storage.string, "standing")
    }

    /// A composition in flight is anchored to offsets the step is about
    /// to rewrite, and the emission gate skips its bookkeeping for
    /// every projection write, so a marked span left open would outlive
    /// the storage it points into. The step settles it on the page it
    /// was typed on first, the way the page swap does.
    func testAStepSettlesAnOpenCompositionFirst() throws {
        try makeEditor()
        type("base")
        textView.setMarkedText(
            "\u{304B}",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText(), "the fixture never opened a composition")

        coordinator.step(back: true)

        XCTAssertFalse(
            textView.hasMarkedText(),
            "the composition outlived the storage it was anchored to")
        XCTAssertNil(
            coordinator.imeComposition,
            "the gate is still tracking a span the step has rewritten")
        XCTAssertEqual(storage.string, coreText())
    }

    // MARK: The other routes to undo

    /// AppKit must not keep a second stack of the page's text. It is
    /// not the stack the chord drives any more, so anything on it is a
    /// stack that can only ever disagree with the core, and Edit > Undo
    /// clicked with the mouse is a live route into it: a manager that
    /// held the last few keystrokes would rewrite the storage behind
    /// the core's back, and on a shared page it would happily revert
    /// text that arrived from another device.
    func testTheEditorKeepsNoAppKitStackOfThePagesText() throws {
        try makeEditor()
        type("typed")
        XCTAssertFalse(textView.allowsUndo)
        XCTAssertNil(
            textView.undoManager,
            "AppKit is holding a second stack of the page's text")
    }

    /// And the menu item itself lands on the core. `undo:` is what the
    /// Edit menu sends down the responder chain, and the page's text
    /// view is first responder while a page is being typed into.
    func testTheMenuActionDrivesTheCore() throws {
        try makeEditor()
        type("clicked from the menu")
        XCTAssertTrue(coreText().contains("clicked"))

        textView.undo(nil)
        XCTAssertEqual(coreText(), "")
        XCTAssertEqual(storage.string, "")

        textView.redo(nil)
        XCTAssertEqual(coreText(), "clicked from the menu")
    }

    /// What actually greys the app's Edit menu out. The items are
    /// SwiftUI's, so they carry SwiftUI's target and are never offered
    /// to `validateMenuItem`; `.disabled` reads this pair instead, and
    /// this pair is the core's own answer for the page under the
    /// editor.
    func testTheMenusEnablementFollowsTheCoresAnswer() throws {
        try makeEditor()
        model.activeEditor = textView
        model.refreshEditSteps()
        XCTAssertFalse(model.editSteps.canUndo)
        XCTAssertFalse(model.editSteps.canRedo)

        // No hand-written refresh from here on: the edit and the step
        // publish it themselves, which is the wiring under test.
        type("something to take back")
        XCTAssertTrue(model.editSteps.canUndo)
        XCTAssertFalse(model.editSteps.canRedo)

        coordinator.step(back: true)
        XCTAssertFalse(model.editSteps.canUndo)
        XCTAssertTrue(model.editSteps.canRedo)

        // A page shown read-only offers neither, which is what the
        // resting card and the roll's past days arrive as.
        textView.isEditable = false
        model.refreshEditSteps()
        XCTAssertFalse(model.editSteps.canUndo)
        XCTAssertFalse(model.editSteps.canRedo)

        // And with no page holding the keyboard at all.
        textView.isEditable = true
        model.refreshEditSteps()
        XCTAssertTrue(model.editSteps.canRedo)
        model.activeEditor = nil
        model.refreshEditSteps()
        XCTAssertFalse(model.editSteps.canUndo)
        XCTAssertFalse(model.editSteps.canRedo)
    }

    /// The view still answers for itself, for any route that does
    /// arrive nil-targeted. This proves the method, not the app's menu,
    /// which is dimmed from the model above.
    func testTheMenuItemsValidateAgainstTheCore() throws {
        try makeEditor()
        let undoItem = NSMenuItem(
            title: "Undo", action: #selector(InkTextView.undo(_:)), keyEquivalent: "")
        let redoItem = NSMenuItem(
            title: "Redo", action: #selector(InkTextView.redo(_:)), keyEquivalent: "")
        XCTAssertFalse(textView.validateMenuItem(undoItem))
        XCTAssertFalse(textView.validateMenuItem(redoItem))

        type("something to take back")
        XCTAssertTrue(textView.validateMenuItem(undoItem))
        XCTAssertFalse(textView.validateMenuItem(redoItem))

        textView.undo(nil)
        XCTAssertFalse(textView.validateMenuItem(undoItem))
        XCTAssertTrue(textView.validateMenuItem(redoItem))
    }

    /// A page shown read-only is not a page a chord may rewrite. The
    /// resting card and the roll's read-only pages both reach the same
    /// view with editing off, and the press must fall through rather
    /// than edit a document nobody is allowed to type into.
    func testAReadOnlyPageRefusesTheChordAndTheMenu() throws {
        try makeEditor()
        type("standing")
        textView.isEditable = false

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
        XCTAssertFalse(textView.performKeyEquivalent(with: event))
        textView.undo(nil)

        XCTAssertEqual(coreText(), "standing")
        XCTAssertEqual(storage.string, "standing")
        let undoItem = NSMenuItem(
            title: "Undo", action: #selector(InkTextView.undo(_:)), keyEquivalent: "")
        XCTAssertFalse(textView.validateMenuItem(undoItem))
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
