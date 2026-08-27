import AppKit
import XCTest

@testable import CompanionKit

/// The language a fence declares, carried from the opening rule down to
/// every line the block holds (the spec's part 2, "Language capture").
/// The info string was always parsed; what was thrown away was the
/// language on the opening rule, and this is the reading that keeps it.
///
/// Pure, the `classify(lines:)` pattern: the whole decision is testable
/// without a text view, and no attribute is involved yet.
@MainActor
final class FenceLanguageTests: XCTestCase {
    private func kinds(_ page: String) -> [InkStyle.LineKind] {
        InkStyle.classify(lines: page.components(separatedBy: "\n"))
    }

    func testTheOpeningRuleGivesItsLanguageToEveryLineOfTheBlock() {
        XCTAssertEqual(
            kinds(
                """
                # before
                ```swift
                let x = 1
                print(x)
                ```
                after
                """
            ),
            [
                .heading(level: 1, markerLength: 2),
                .fenceRule,
                .code(language: "swift"),
                .code(language: "swift"),
                .fenceRule,
                .body,
            ]
        )
    }

    /// A writer types the nickname they know. The alias table is what
    /// makes `js` and `javascript` the same block.
    func testAnAliasResolvesToItsCanonicalLanguage() {
        XCTAssertEqual(
            kinds("```js\nconst a = 1\n```"),
            [.fenceRule, .code(language: "javascript"), .fenceRule]
        )
        XCTAssertEqual(
            kinds("```Bash\nls\n```"),
            [.fenceRule, .code(language: "shell"), .fenceRule]
        )
    }

    /// A bare fence and a language nobody has heard of are the same
    /// answer, deliberately: guessing is worse than plain ink, so both
    /// carry nil and the block renders as it always has.
    func testABareOrUnknownFenceCarriesNoLanguage() {
        XCTAssertEqual(
            kinds("```\nwhatever\n```"),
            [.fenceRule, .code(language: nil), .fenceRule]
        )
        XCTAssertEqual(
            kinds("```brainfuck\n+++\n```"),
            [.fenceRule, .code(language: nil), .fenceRule]
        )
    }

    /// An info string can say more than a language, so only its first
    /// word is read.
    func testOnlyTheFirstWordOfTheInfoStringIsTheLanguage() {
        XCTAssertEqual(
            kinds("```python title=main.py\nx = 1\n```"),
            [.fenceRule, .code(language: "python"), .fenceRule]
        )
    }

    func testATildeFenceCarriesItsLanguageToo() {
        XCTAssertEqual(
            kinds("~~~python\nx = 1\n~~~"),
            [.fenceRule, .code(language: "python"), .fenceRule]
        )
    }

    /// A page mid-paste holds its language to the last line, the same
    /// reading an unterminated fence already got for its wash.
    func testAnUnterminatedFenceCarriesItsLanguageToTheLastLine() {
        XCTAssertEqual(
            kinds("```rust\nfn main() {\n    let x = 1;"),
            [.fenceRule, .code(language: "rust"), .code(language: "rust")]
        )
    }

    /// The behaviour language capture must not break: a rule carrying an
    /// info string cannot close the block it is inside, so a second
    /// ```` ```swift ```` line is content about code and the language of
    /// the block is still the one the opening rule named.
    func testARuleWithAnInfoStringInsideABlockIsStillContent() {
        XCTAssertEqual(
            kinds(
                """
                ```swift
                let a = 1
                ```swift
                let b = 2
                ```
                after
                """
            ),
            [
                .fenceRule,
                .code(language: "swift"),
                .code(language: "swift"),
                .code(language: "swift"),
                .fenceRule,
                .body,
            ]
        )
    }

    /// The scanner's own state, read the way the restyle walk reads it:
    /// the language stands while the fence is open and is gone the
    /// moment the answering rule closes it, so the block below starts
    /// from nothing.
    func testTheLanguageLastsExactlyAsLongAsTheFence() {
        var scanner = InkStyle.FenceScanner()
        XCTAssertNil(scanner.fenceLanguage)
        XCTAssertEqual(scanner.classify("```yml"), .fenceRule)
        XCTAssertEqual(scanner.fenceLanguage, "yaml")
        XCTAssertEqual(scanner.classify("key: value"), .code(language: "yaml"))
        XCTAssertEqual(scanner.classify("```"), .fenceRule)
        XCTAssertNil(scanner.fenceLanguage)
    }

    /// The colors live in one place so a test can name them and dark
    /// mode costs nothing: every one is a system color.
    func testTheFourColorsAreFixedInOnePlace() {
        XCTAssertEqual(InkStyle.tokenColor(.keyword), NSColor.systemPurple)
        XCTAssertEqual(InkStyle.tokenColor(.string), NSColor.systemRed)
        XCTAssertEqual(InkStyle.tokenColor(.comment), NSColor.secondaryLabelColor)
        XCTAssertEqual(InkStyle.tokenColor(.number), NSColor.systemBlue)
    }
}

/// The same reading laid down as attributes by the editor's own restyle
/// pass: what the eye would see inside a fence, and what it must not see
/// anywhere else (ADR-0024, amendment C: display only, fence only).
@MainActor
final class CodeHighlightingRenderingTests: XCTestCase {
    private var model: PageModel!
    private var coordinator: InkEditorView.Coordinator!
    private var textView: InkTextView!
    private var sheet: UInt64 = 0

    /// The editor's TextKit 1 stack over a model that rests entirely in
    /// temporary space, credentials in process memory: nothing here can
    /// reach the installed app's pages (ADR-0018).
    private func makeEditor() {
        let suite = "companion-kit-highlighting-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        model = isolatedModel(defaults: defaults)
        model.newPage()
        sheet = model.selection!

        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let storage = model.storage(for: sheet)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = InkTextView(frame: .zero, textContainer: container)
        textView.isRichText = true
        coordinator = InkEditorView.Coordinator(model: model)
        textView.coordinator = coordinator
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.currentSheet = sheet
        storage.delegate = coordinator
    }

    private var storage: NSTextStorage { model.storage(for: sheet) }

    /// A passage handed over whole, newlines and all: a paste, which is
    /// how a fenced block usually arrives on a page.
    private func paste(_ page: String) {
        textView.insertText(page, replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.restyle()
    }

    /// The color the first character of a given snippet wears. Located
    /// by searching the page rather than by counting, so a test reads as
    /// the sentence it is asserting.
    private func foreground(of needle: String) -> NSColor? {
        let range = (storage.string as NSString).range(of: needle)
        guard range.location != NSNotFound else {
            XCTFail("the page does not contain \(needle)")
            return nil
        }
        return storage.attributes(at: range.location, effectiveRange: nil)[.foregroundColor]
            as? NSColor
    }

    func testASwiftFenceColorsItsKeywordsStringsCommentsAndNumbers() {
        makeEditor()
        paste(
            """
            ```swift
            let name = "ada" // who
            var count = 42
            ```
            """
        )
        XCTAssertEqual(foreground(of: "let"), NSColor.systemPurple)
        XCTAssertEqual(foreground(of: "\"ada\""), NSColor.systemRed)
        XCTAssertEqual(foreground(of: "// who"), NSColor.secondaryLabelColor)
        XCTAssertEqual(foreground(of: "42"), NSColor.systemBlue)
        // Everything the tokenizer did not claim is ordinary ink, and
        // the rules themselves are markup, dimmed as they always were.
        XCTAssertEqual(foreground(of: "name"), NSColor.labelColor)
        XCTAssertEqual(foreground(of: "```swift"), NSColor.tertiaryLabelColor)
    }

    /// A block that names no language renders exactly as it did before
    /// highlighting existed. `let` here is a word in a note.
    func testABareFenceStaysPlainInk() {
        makeEditor()
        paste(
            """
            ```
            let name = "ada"
            ```
            """
        )
        XCTAssertEqual(foreground(of: "let"), NSColor.labelColor)
        XCTAssertEqual(foreground(of: "\"ada\""), NSColor.labelColor)
    }

    /// Amendment C's boundary, asserted from the outside: prose that
    /// happens to read like code takes no color at all, above the fence
    /// or below it.
    func testInkOutsideTheFenceTakesNoTokenColor() {
        makeEditor()
        paste(
            """
            let me tell you about 42
            ```swift
            let x = 1
            ```
            var too, and "quoted" prose
            """
        )
        XCTAssertEqual(foreground(of: "let me"), NSColor.labelColor)
        XCTAssertEqual(foreground(of: "42"), NSColor.labelColor)
        XCTAssertEqual(foreground(of: "var too"), NSColor.labelColor)
        XCTAssertEqual(foreground(of: "\"quoted\""), NSColor.labelColor)
        // The one line that is inside the fence still colors, so the
        // page above is not simply going uncolored by accident.
        XCTAssertEqual(foreground(of: "let x"), NSColor.systemPurple)
    }

    /// The whole contract of display-only styling: the restyle pass may
    /// say anything it likes about how the page looks and nothing at all
    /// about what it says. Select all and copy returns what was typed
    /// because these are the bytes that were typed.
    func testColoringChangesNoByteOfThePage() {
        makeEditor()
        let page = """
            ```swift
            let name = "ada" // who
            ```
            """
        paste(page)
        let before = storage.string
        coordinator.restyle()
        coordinator.restyle()
        XCTAssertEqual(storage.string, before)
        XCTAssertEqual(storage.string, page)
        // And the coloring really did happen over those unchanged bytes.
        XCTAssertEqual(foreground(of: "let"), NSColor.systemPurple)
    }

    /// A comment left open at the end of one block cannot color the
    /// block below it: the tokenizer is remade at every opening rule,
    /// which is the boundary tokenizer state never crosses.
    func testAnOpenCommentDoesNotLeakIntoTheNextBlock() {
        makeEditor()
        paste(
            """
            ```swift
            /* still open
            ```
            ```swift
            let x = 1
            ```
            """
        )
        XCTAssertEqual(foreground(of: "/* still open"), NSColor.secondaryLabelColor)
        XCTAssertEqual(foreground(of: "let x"), NSColor.systemPurple)
    }
}
