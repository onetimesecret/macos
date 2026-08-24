import AppKit
import SwiftUI
import XCTest

@testable import CompanionKit

/// The one suite that starts from an `NSEvent` (issue #76).
///
/// Everything else about the keymap is asserted on values: a chord
/// parses, a file resolves, a command id dispatches. What none of that
/// can say is whether a real press arrives as the thing the parser
/// wrote down, which is where the shift defect lived and where the
/// modifier mask's two decisions (caps lock dropped, the function and
/// numeric-pad flags dropped) are either right or invisible. So this
/// one builds the page's text view as `makeNSView` wires it, fabricates
/// the event AppKit would deliver, and hands it to the same
/// `performKeyEquivalent` and `keyDown` the responder chain calls.
///
/// The chord under test is the wrap toggle throughout, deliberately.
/// It is the one editor command whose effect is a flag on the model:
/// the other two seal, and a suite that seals reads the machine's
/// pasteboard.
@MainActor
final class KeymapEventTests: XCTestCase {
    /// The `z` key's place on the board, which is what an event
    /// carries and what a named key would be matched by.
    private let zKeyCode: UInt16 = 6

    /// The text view holds its coordinator weakly, the way the mounted
    /// editor's does, so the suite has to be what keeps it alive.
    private var coordinator: InkEditorView.Coordinator?

    private func makeStack(overrideText: String? = nil) throws -> (PageModel, InkTextView) {
        let suiteName = "companion-keymap-event-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        var override: URL?
        if let overrideText {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("keymap-\(UUID().uuidString).json")
            try overrideText.write(to: url, atomically: true, encoding: .utf8)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            override = url
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-keymap-event-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = PageModel(
            formFactor: .backdrop,
            defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: .ephemeral(tag: "keymap-event-\(UUID().uuidString)"),
                keymapOverride: override
            )
        )

        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let textView = InkTextView(frame: .zero, textContainer: container)
        let coordinator = InkEditorView.Coordinator(model: model)
        self.coordinator = coordinator
        textView.coordinator = coordinator
        coordinator.textView = textView
        return (model, textView)
    }

    /// `unmodified` is the event's `charactersIgnoringModifiers`, which
    /// is the string matching reads. It defaults to the same text
    /// because for most chords the board reports both alike; the
    /// shifted glyphs are where the two part company, and there the
    /// caller has to say so.
    private func press(
        _ characters: String,
        unmodified: String? = nil,
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: unmodified ?? characters,
                isARepeat: false,
                keyCode: keyCode
            ),
            "AppKit refused to build the event this test presses")
    }

    /// ⇧⌘1 as the board really reports it: `characters` is the
    /// unshifted `1`, because ⌘ suppresses the shift there, and
    /// `charactersIgnoringModifiers` is the shifted `!`, because that
    /// one honours shift. Matching reads the second of the two, which
    /// is why the file writes the glyph.
    private func pressShiftedOne() throws -> NSEvent {
        try press("1", unmodified: "!", flags: [.command, .shift], keyCode: 18)
    }

    /// A command-bearing chord travels the key-equivalent route, which
    /// is the one that reaches the page before the surface's hidden
    /// buttons get a look.
    func testAChordFromTheFileFiresThroughTheKeyEquivalentRoute() throws {
        let (model, textView) = try makeStack(
            overrideText: """
                [{ "context": "Editor", "bindings": { "cmd-alt-z": "editor::ToggleWrap" } }]
                """)
        let wrapped = model.wrapsLines
        let event = try press("z", flags: [.command, .option], keyCode: zKeyCode)

        XCTAssertTrue(
            textView.performKeyEquivalent(with: event),
            "the page did not claim a chord the keymap put on its route")
        XCTAssertNotEqual(model.wrapsLines, wrapped)
    }

    /// The bundled ⌥Z, which carries no ⌘ and so arrives as an ordinary
    /// key press on the page rather than as a key equivalent.
    func testAChordWithoutCommandFiresThroughTheKeyDownRoute() throws {
        let (model, textView) = try makeStack()
        let wrapped = model.wrapsLines
        // Matching reads the unmodified characters, which for ⌥Z is z;
        // the board's own `characters` would be Ω and is not consulted.
        let event = try press("z", flags: [.option], keyCode: zKeyCode)

        textView.keyDown(with: event)
        XCTAssertNotEqual(model.wrapsLines, wrapped)
    }

    /// Caps lock is a state, not a chord, and the flags carry it into
    /// every event pressed while the light is on. A mask that kept it
    /// would make ⌥Z a chord nobody with caps lock down can type.
    func testCapsLockDoesNotBreakAChord() throws {
        let (model, textView) = try makeStack()
        let wrapped = model.wrapsLines
        let event = try press("z", flags: [.option, .capsLock], keyCode: zKeyCode)

        textView.keyDown(with: event)
        XCTAssertNotEqual(model.wrapsLines, wrapped)
    }

    /// The spelling the parser sends an author to when it refuses
    /// `cmd-shift-1`, pressed as the board sends it. The event carries
    /// a shift flag the binding cannot name, so this fires only
    /// because matching leaves shift out of the comparison for a glyph
    /// that already carries it.
    func testAShiftedGlyphFiresFromTheGlyphSpelling() throws {
        let (model, textView) = try makeStack(
            overrideText: """
                [{ "context": "Editor", "bindings": { "cmd-!": "editor::ToggleWrap" } }]
                """)
        let wrapped = model.wrapsLines

        XCTAssertTrue(
            textView.performKeyEquivalent(with: try pressShiftedOne()),
            "the page did not claim the glyph spelling of a shifted chord")
        XCTAssertNotEqual(model.wrapsLines, wrapped)
    }

    /// And the spelling that is refused, pressed the same way, to show
    /// what the refusal is about: the file wrote `1` and the press says
    /// `!`, so this binding would have been dead on the page while the
    /// surface's hidden buttons fired it.
    func testTheUnshiftedSpellingWouldNotHaveFired() throws {
        let (_, textView) = try makeStack(
            overrideText: """
                [{ "context": "Editor", "bindings": { "cmd-1": "editor::ToggleWrap" } }]
                """)

        XCTAssertFalse(
            textView.performKeyEquivalent(with: try pressShiftedOne()),
            "a chord bound to the unshifted glyph answered a shifted press")
    }

    /// The chord that is not bound stays the page's own business: a
    /// press the keymap says nothing about is not claimed.
    func testAnUnboundChordIsLeftAlone() throws {
        let (_, textView) = try makeStack()
        let event = try press("j", flags: [.command, .control], keyCode: 38)
        XCTAssertFalse(textView.performKeyEquivalent(with: event))
    }

    // MARK: The surface route, and what it takes when asked

    /// A surface command bound to a chord without ⌘ is claimed by the
    /// hidden buttons, and claimed ahead of the page: a key equivalent
    /// is offered to the view tree before the first responder's
    /// `keyDown` runs. So an override binding ⌥N to a surface command
    /// costs the page ⌥N, which on a US layout is the dead key that
    /// composes ñ.
    ///
    /// The page's own route refuses exactly this (`InkTextView`
    /// answers non-command chords in `keyDown`, so they fire only
    /// while it holds the keyboard). The surface installs whatever the
    /// file names, and nothing warns. Pinned here as the fact it is:
    /// the bundled default names no such chord, and whether the
    /// validator should say something about one is a question this
    /// suite is not the place to answer.
    ///
    /// The claim is what is asserted, not the effect. The button's
    /// action needs a key window to run, which a test that must pass
    /// on a headless runner cannot promise; with one, verified by
    /// hand, the page is created.
    func testAnOptionOnlyChordOnTheSurfaceRouteTakesTheKeyFromThePage() throws {
        let (model, _) = try makeStack(
            overrideText: """
                [{ "context": "Editor", "bindings": { "alt-n": "page::New" } }]
                """)
        let host = NSHostingView(rootView: PageKeyboardMap(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(host)
        window.layoutIfNeeded()

        XCTAssertTrue(
            host.performKeyEquivalent(with: try press("n", flags: [.option], keyCode: 45)),
            "the surface did not install an option-only chord the file named")
        XCTAssertFalse(
            host.performKeyEquivalent(with: try press("m", flags: [.option], keyCode: 46)),
            "the surface claims keys nothing bound, so the claim above proves nothing")
    }
}
