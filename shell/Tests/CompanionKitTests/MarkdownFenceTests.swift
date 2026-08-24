import AppKit
import XCTest

@testable import CompanionKit

/// Fenced blocks, read as a person reads them (issue #75). A fence is
/// the one piece of markup whose meaning is not local: everything
/// between the two rules is literally what was typed, so a `# comment`
/// inside a fence is a comment about code and never an h1.
///
/// The classifier is pure, which is the shell's pattern for
/// UI-adjacent logic: the decision is tested directly and AppKit is
/// never mocked.
@MainActor
final class FenceScannerTests: XCTestCase {
    private func kinds(_ page: String) -> [InkStyle.LineKind] {
        InkStyle.classify(lines: page.components(separatedBy: "\n"))
    }

    func testMarkdownInsideAFenceIsInert() {
        let kinds = kinds(
            """
            ```
            # comment
            - flag value
            * star
            ```
            """
        )
        XCTAssertEqual(
            kinds,
            [.fenceRule, .code, .code, .code, .fenceRule]
        )
    }

    func testHeadingsOutsideAFenceStillRender() {
        XCTAssertEqual(kinds("### deploy friday"), [.heading(level: 3, markerLength: 4)])
        XCTAssertEqual(kinds("#hashtag"), [.body])
    }

    func testProseReturnsAfterTheClosingFence() {
        let kinds = kinds(
            """
            # before
            ```sh
            # inside
            ```
            # after
            """
        )
        XCTAssertEqual(
            kinds,
            [
                .heading(level: 1, markerLength: 2),
                .fenceRule,
                .code,
                .fenceRule,
                .heading(level: 1, markerLength: 2),
            ]
        )
    }

    /// A fence left open is a page mid-thought, most often a paste that
    /// has not landed its tail yet. It holds to the last line rather
    /// than being second-guessed into prose.
    func testAnUnterminatedFenceHoldsToTheEndOfThePage() {
        let kinds = kinds(
            """
            ```
            # still code
            ## still code
            """
        )
        XCTAssertEqual(kinds, [.fenceRule, .code, .code])
    }

    func testTheInfoStringDoesNotCloseTheFenceItOpens() {
        var scanner = InkStyle.FenceScanner()
        XCTAssertEqual(scanner.classify("```swift"), .fenceRule)
        XCTAssertTrue(scanner.insideFence)
        XCTAssertEqual(scanner.classify("```"), .fenceRule)
        XCTAssertFalse(scanner.insideFence)
    }

    /// A closing rule answers its opener: same character, and at least
    /// as long. Anything else met inside the block is content.
    func testOnlyAMatchingRuleClosesTheBlock() {
        XCTAssertEqual(
            kinds(
                """
                ~~~
                ```
                still inside
                ~~~
                """
            ),
            [.fenceRule, .code, .code, .fenceRule]
        )
        XCTAssertEqual(
            kinds(
                """
                ````
                ```
                ````
                """
            ),
            [.fenceRule, .code, .fenceRule]
        )
    }

    func testAnInlineCodeSpanDoesNotOpenAFence() {
        XCTAssertEqual(kinds("run ```ls``` first"), [.body])
        XCTAssertEqual(kinds("`` two ticks"), [.body])
    }

    func testAnIndentedRuleStillOpensAFence() {
        XCTAssertEqual(kinds("  ```\n  # comment"), [.fenceRule, .code])
    }
}

/// The same reading, applied to real text storage through the editor's
/// own restyle pass: what the eye would see, asserted as attributes.
@MainActor
final class FenceRenderingTests: XCTestCase {
    private var model: PageModel!
    private var coordinator: InkEditorView.Coordinator!
    private var textView: InkTextView!
    private var sheet: UInt64 = 0

    /// The editor's TextKit 1 stack over a model that rests entirely in
    /// temporary space, credentials in process memory: nothing here can
    /// reach the installed app's pages (ADR-0018).
    private func makeEditor() {
        let defaults = UserDefaults(suiteName: "companion-kit-fence-tests")!
        defaults.removePersistentDomain(forName: "companion-kit-fence-tests")
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

    /// The attributes at the first character of the given line, counting
    /// from the top of the page.
    private func attributes(ofLine index: Int) -> [NSAttributedString.Key: Any] {
        let text = storage.string as NSString
        var location = 0
        for _ in 0..<index {
            location = NSMaxRange(text.paragraphRange(for: NSRange(location: location, length: 0)))
        }
        return storage.attributes(at: location, effectiveRange: nil)
    }

    private func font(ofLine index: Int) -> NSFont? {
        attributes(ofLine: index)[.font] as? NSFont
    }

    private func background(ofLine index: Int) -> NSColor? {
        attributes(ofLine: index)[.backgroundColor] as? NSColor
    }

    private func foreground(ofLine index: Int) -> NSColor? {
        attributes(ofLine: index)[.foregroundColor] as? NSColor
    }

    func testAHashInsideAFenceStaysPlainInk() {
        makeEditor()
        paste(
            """
            # a real heading
            ```
            # comment
            - flag value
            * star
            ```
            # a heading again
            """
        )
        XCTAssertEqual(font(ofLine: 0), InkStyle.headingFont(level: 1))
        for line in 2...4 {
            XCTAssertEqual(font(ofLine: line), InkStyle.baseFont, "line \(line) took heading weight")
            XCTAssertEqual(foreground(ofLine: line), NSColor.labelColor, "line \(line) was dimmed")
            XCTAssertEqual(background(ofLine: line), InkStyle.codeBackground)
        }
        XCTAssertEqual(font(ofLine: 6), InkStyle.headingFont(level: 1))
        XCTAssertEqual(background(ofLine: 6), NSColor.clear)
    }

    func testTheFenceItselfRendersAsABlock() {
        makeEditor()
        paste(
            """
            ```swift
            let x = 1
            ```
            """
        )
        for line in 0...2 {
            XCTAssertEqual(background(ofLine: line), InkStyle.codeBackground)
        }
        XCTAssertEqual(foreground(ofLine: 0), NSColor.tertiaryLabelColor)
        XCTAssertEqual(foreground(ofLine: 2), NSColor.tertiaryLabelColor)
    }

    /// Closing the fence hands the lines below it back to prose, wash
    /// and all: the restyle pass lays every line down as plain ink
    /// before it decides what the line is.
    func testClosingAFenceReleasesTheLinesBelowIt() {
        makeEditor()
        paste(
            """
            ```
            # comment
            """
        )
        XCTAssertEqual(background(ofLine: 1), InkStyle.codeBackground)

        textView.setSelectedRange(NSRange(location: (storage.string as NSString).length, length: 0))
        textView.insertText(
            "\n```\n# a heading",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        coordinator.restyle()

        XCTAssertEqual(background(ofLine: 1), InkStyle.codeBackground)
        XCTAssertEqual(font(ofLine: 3), InkStyle.headingFont(level: 1))
        XCTAssertEqual(background(ofLine: 3), NSColor.clear)
    }
}
