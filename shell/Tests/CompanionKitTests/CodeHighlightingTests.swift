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

    /// The colours live in one place, Theme.swift, and the editor
    /// reads them from there: each kind maps to its ink token and the
    /// four are distinct from each other. What the tokens measure
    /// against the wash is ThemeContrastTests' question (D-06).
    func testTheFourColoursComeFromTheTheme() {
        XCTAssertEqual(InkStyle.tokenColor(.keyword), NSColor.inkKeyword)
        XCTAssertEqual(InkStyle.tokenColor(.string), NSColor.inkString)
        XCTAssertEqual(InkStyle.tokenColor(.comment), NSColor.inkComment)
        XCTAssertEqual(InkStyle.tokenColor(.number), NSColor.inkNumber)
    }

    /// Each token clears the record's bar against the wash it is drawn
    /// on, under both appearances, measured rather than named.
    func testTokenColoursClearFourPointFiveAgainstTheFenceWash() {
        for kind in [CodeInk.TokenKind.keyword, .string, .comment, .number] {
            for appearance in ThemeContrastTests.appearances {
                for (backingName, layers) in ThemeContrastTests.fenceWashes {
                    let ratio = ThemeContrastTests.contrastRatio(
                        InkStyle.tokenColor(kind), over: layers, appearance: appearance)
                    XCTAssertGreaterThanOrEqual(
                        ratio, ThemeContrastTests.bar,
                        "\(kind) on \(backingName) under \(appearance.rawValue) reads \(ratio):1")
                }
            }
        }
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

    private var storage: NSTextStorage {
        try! XCTUnwrap(textView.textStorage)
    }

    private func makeFileEditor(_ text: String, mode: FileRenderMode) {
        let suite = "companion-kit-file-rendering-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        model = isolatedModel(defaults: defaults)
        sheet = CompanionClient.fileIDTag | 9_001
        model.standOpenFiles([
            FileSummary(
                id: sheet, name: "sample.txt", path: "/tmp/sample.txt",
                isDirty: false, conflict: .none, lineEnding: .lf, hasBOM: false,
                lastEditedAt: 0, restoredFromDraft: false
            )
        ])
        model.selectFile(sheet)
        model.selectFileRenderMode(mode, for: sheet)

        let textStorage = NSTextStorage(attributedString: NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .bold),
                .foregroundColor: NSColor.systemRed,
                .backgroundColor: NSColor.systemYellow,
                .link: URL(string: "https://stale.invalid")!,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        ))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = InkTextView(frame: .zero, textContainer: container)
        textView.isRichText = true
        coordinator = InkEditorView.Coordinator(model: model)
        textView.coordinator = coordinator
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.currentSheet = sheet
        textStorage.delegate = coordinator
        coordinator.restyle()
    }

    private func offset(of needle: String) -> Int {
        (storage.string as NSString).range(of: needle).location
    }

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

    func testPlainTextFileLeavesMarkdownConstructsLiteral() throws {
        let text = "# Heading\n- item\n```swift\nlet value = 1\n```\n[link](https://example.com)\n"
        makeFileEditor(text, mode: .plainText)

        XCTAssertEqual(storage.string, text)
        for needle in ["#", "-", "```swift", "[link]"] {
            let location = offset(of: needle)
            XCTAssertEqual(
                try XCTUnwrap(storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont),
                InkStyle.baseFont
            )
            XCTAssertEqual(
                try XCTUnwrap(storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor),
                NSColor.labelColor
            )
            XCTAssertNil(storage.attribute(.link, at: location, effectiveRange: nil))
            XCTAssertNil(storage.attribute(.underlineStyle, at: location, effectiveRange: nil))
        }
        let listStyle = try XCTUnwrap(
            storage.attribute(.paragraphStyle, at: offset(of: "- item"), effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(listStyle.firstLineHeadIndent, 0)
    }

    func testSourceFileUsesFixedWidthTypographyWithoutMarkdownRendering() throws {
        let text = "# Heading\n- item\n```swift\nlet value = 1\n```\n[link](https://example.com)\n"
        makeFileEditor(text, mode: .source("swift"))

        XCTAssertEqual(storage.string, text)
        storage.enumerateAttribute(
            .font, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            XCTAssertEqual(value as? NSFont, InkStyle.codeFont)
            XCTAssertTrue((value as? NSFont)?.isFixedPitch == true)
        }
        let fence = offset(of: "```swift")
        XCTAssertEqual(
            try XCTUnwrap(storage.attribute(.foregroundColor, at: fence, effectiveRange: nil) as? NSColor),
            NSColor.labelColor
        )
        XCTAssertEqual(
            try XCTUnwrap(storage.attribute(.backgroundColor, at: fence, effectiveRange: nil) as? NSColor),
            NSColor.clear
        )
        XCTAssertNil(storage.attribute(.link, at: offset(of: "[link]"), effectiveRange: nil))
        XCTAssertEqual(foreground(of: "let"), InkStyle.tokenColor(.keyword))
    }

    func testUnsupportedSourceLanguageIsFixedWidthAndUncolored() throws {
        let text = "# Heading\n```kotlin\nfun answer() = 42\n```\n[link](https://example.com)\n"
        makeFileEditor(text, mode: .source("kotlin"))

        storage.enumerateAttributes(
            in: NSRange(location: 0, length: storage.length)
        ) { attributes, _, _ in
            XCTAssertEqual(attributes[.font] as? NSFont, InkStyle.codeFont)
            XCTAssertEqual(attributes[.foregroundColor] as? NSColor, NSColor.labelColor)
            XCTAssertEqual(attributes[.backgroundColor] as? NSColor, NSColor.clear)
            XCTAssertNil(attributes[.link])
            XCTAssertNil(attributes[.underlineStyle])
        }
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
        XCTAssertEqual(foreground(of: "let"), NSColor.inkKeyword)
        XCTAssertEqual(foreground(of: "\"ada\""), NSColor.inkString)
        XCTAssertEqual(foreground(of: "// who"), NSColor.inkComment)
        XCTAssertEqual(foreground(of: "42"), NSColor.inkNumber)
        // Everything the tokenizer did not claim is ordinary ink, and
        // the rules themselves are markup, dimmed as they always were.
        XCTAssertEqual(foreground(of: "name"), NSColor.labelColor)
        XCTAssertEqual(foreground(of: "```swift"), NSColor.tertiaryLabelColor)
    }

    /// A form feed is a newline to Foundation and is not a paragraph
    /// break to `paragraphRange`, so a line that opens with one is one
    /// line as far as the page is concerned. Trimming it off the head
    /// before tokenizing would move every offset on that line and paint
    /// the color one character to the left. Older sources carry page
    /// breaks like this and a plain paste lands the byte verbatim.
    func testAControlCharacterAtTheHeadOfALineDoesNotShiftItsColor() {
        makeEditor()
        paste("```swift\n\u{0C}let name = 1\n```")
        XCTAssertEqual(foreground(of: "let"), NSColor.inkKeyword)
        XCTAssertEqual(foreground(of: "\u{0C}"), NSColor.labelColor)
        XCTAssertEqual(foreground(of: "1"), NSColor.inkNumber)
        XCTAssertEqual(foreground(of: "name"), NSColor.labelColor)
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
        XCTAssertEqual(foreground(of: "let x"), NSColor.inkKeyword)
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
        XCTAssertEqual(foreground(of: "let"), NSColor.inkKeyword)
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
        XCTAssertEqual(foreground(of: "/* still open"), NSColor.inkComment)
        XCTAssertEqual(foreground(of: "let x"), NSColor.inkKeyword)
    }

    func testTurningHighlightingOffKeepsFixedWidthCodeTypography() throws {
        makeEditor()
        paste("prose\n```swift\nlet value = 1\n```\nafter")
        let code = (storage.string as NSString).range(of: "let").location
        XCTAssertEqual(foreground(of: "let"), NSColor.inkKeyword)

        model.syntaxHighlightingEnabled = false
        coordinator.applySyntaxHighlighting(false)

        XCTAssertEqual(foreground(of: "let"), NSColor.labelColor)
        XCTAssertEqual(
            try XCTUnwrap(storage.attribute(.font, at: code, effectiveRange: nil) as? NSFont),
            InkStyle.codeFont
        )

        model.syntaxHighlightingEnabled = true
        coordinator.applySyntaxHighlighting(true)
        XCTAssertEqual(foreground(of: "let"), NSColor.inkKeyword)
    }

    /// The whole of D-05 from the reader's side: headings keep their
    /// hashes and a fence keeps its rules on screen, dimmed rather than
    /// removed, so select all and copy hands back the page as it was
    /// typed. The reading is the one a copy takes: the text under the
    /// selection after select all, which is the storage's string over
    /// its full range. The pasteboard itself is not written, since a
    /// headless test binary has no pasteboard server worth trusting
    /// and the general pasteboard is the person's, not the suite's.
    func testSelectAllCopyReturnsTheTypedString() {
        makeEditor()
        let page = """
            # heading

            ## second

            body with a [link](https://example.invalid)

            ```swift
            let name = "ada" // who
            ```
            after
            """
        paste(page)
        XCTAssertEqual(foreground(of: "# heading"), NSColor.tertiaryLabelColor)
        XCTAssertEqual(foreground(of: "let"), NSColor.inkKeyword)

        let full = NSRange(location: 0, length: storage.length)
        XCTAssertEqual(storage.attributedSubstring(from: full).string, page)

        textView.selectAll(nil)
        XCTAssertEqual(textView.selectedRange(), full)
        XCTAssertEqual(
            storage.attributedSubstring(from: textView.selectedRange()).string, page,
            "what the copy would take is not what was typed")
    }
}
