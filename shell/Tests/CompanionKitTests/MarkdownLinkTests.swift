import AppKit
import XCTest

@testable import CompanionKit

/// The link reading (ADR-0023), tested as the pure function it is: a
/// line of body ink goes in, the constructs that count as links come
/// out, ranges and all. Deliberately conservative — a link is an offer
/// to open something, and a guessed-at target is worse than plain ink.
final class LinkDetectionTests: XCTestCase {
    private func links(_ line: String) -> [InkStyle.InkLink] {
        InkStyle.links(in: line)
    }

    func testABareURLReadsAsALink() {
        let found = links("see https://example.com/docs today")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].target, "https://example.com/docs")
        XCTAssertEqual(found[0].range, NSRange(location: 4, length: 24))
        XCTAssertEqual(found[0].markup, [], "a bare URL carries no syntax to dim")
    }

    /// The full stop after a URL belongs to the sentence, not the
    /// target: `example.com.` is a different host from `example.com`.
    func testTrailingSentencePunctuationStaysProse() {
        for line in [
            "read https://example.com.",
            "read https://example.com,",
            "read https://example.com!",
            "read https://example.com;",
        ] {
            let found = links(line)
            XCTAssertEqual(found.count, 1, line)
            XCTAssertEqual(found[0].target, "https://example.com", line)
            XCTAssertEqual(found[0].range, NSRange(location: 5, length: 19), line)
        }
    }

    /// Parens are walked back only while unbalanced: the Wikipedia
    /// idiom keeps its tail, the prose's closing paren goes back to
    /// the prose.
    func testParensInAURLAreKeptWhileBalanced() {
        let wiki = links("https://en.wikipedia.org/wiki/Rust_(language)")
        XCTAssertEqual(wiki.first?.target, "https://en.wikipedia.org/wiki/Rust_(language)")

        let aside = links("(see https://example.com)")
        XCTAssertEqual(aside.first?.target, "https://example.com")
    }

    func testAMarkdownLinkStylesTheWholeConstruct() {
        // [docs](https://example.com/a)
        //  ^label                      ^ the rest is syntax
        let found = links("[docs](https://example.com/a)")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].target, "https://example.com/a")
        XCTAssertEqual(found[0].range, NSRange(location: 0, length: 29))
        XCTAssertEqual(
            found[0].markup,
            [NSRange(location: 0, length: 1), NSRange(location: 5, length: 24)],
            "the opening bracket, then everything from `](` to `)`, is dimmed syntax"
        )
    }

    /// The URL inside a markdown construct is not also a bare link: the
    /// construct claimed it.
    func testAMarkdownLinkIsNotDoubleCounted() {
        XCTAssertEqual(links("[docs](https://example.com)").count, 1)
    }

    /// Only http and https open anything. A markdown construct with any
    /// other scheme is plain ink wearing brackets.
    func testNonHTTPTargetsAreNotLinks() {
        XCTAssertEqual(links("[x](ftp://example.com)"), [])
        XCTAssertEqual(links("[x](javascript:alert(1))"), [])
        XCTAssertEqual(links("mailto:someone@example.com"), [])
    }

    /// The gate on bare URLs asks for a host, not a minimum length: a
    /// target shorter than `https://something` is still a link when a
    /// real host follows the scheme.
    func testAShortHTTPURLStillReadsAsALink() {
        let found = links("see http://a.io now")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].target, "http://a.io")
    }

    func testPlainProseCarriesNoLinks() {
        XCTAssertEqual(links("no urls here, not even http mentioned as a word"), [])
        XCTAssertEqual(links(""), [])
        XCTAssertEqual(links("https:// alone is not a link"), [])
    }

    func testTwoLinksOnOneLineComeBackInOrder() {
        let found = links("[a](https://a.example) and https://b.example")
        XCTAssertEqual(found.map(\.target), ["https://a.example", "https://b.example"])
        XCTAssertLessThan(found[0].range.location, found[1].range.location)
    }
}

/// The same reading, applied through the editor's restyle pass and
/// asserted as attributes: a body line's URL carries `.link`, a code
/// line's does not, and the markdown syntax dims without leaving the
/// screen.
@MainActor
final class LinkRenderingTests: XCTestCase {
    private var model: PageModel!
    private var coordinator: InkEditorView.Coordinator!
    private var textView: InkTextView!
    private var sheet: UInt64 = 0

    /// The editor's TextKit 1 stack over a model that rests entirely in
    /// temporary space, credentials in process memory: nothing here can
    /// reach the installed app's pages (ADR-0018).
    private func makeEditor() {
        let defaults = UserDefaults(suiteName: "companion-kit-link-tests")!
        defaults.removePersistentDomain(forName: "companion-kit-link-tests")
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

    private func paste(_ page: String) {
        textView.insertText(page, replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.restyle()
    }

    private func attributes(at location: Int) -> [NSAttributedString.Key: Any] {
        storage.attributes(at: location, effectiveRange: nil)
    }

    func testABodyLineURLCarriesTheLinkAttribute() {
        makeEditor()
        paste("see https://example.com today")
        let inside = attributes(at: 4)
        XCTAssertEqual((inside[.link] as? URL)?.absoluteString, "https://example.com")
        XCTAssertEqual(inside[.foregroundColor] as? NSColor, NSColor.linkColor)
        // The prose on either side is untouched.
        XCTAssertNil(attributes(at: 0)[.link])
        XCTAssertNil(attributes(at: 24)[.link])
    }

    /// A URL inside a fence is code (issue #75's rule, applied to
    /// links): nothing there is clickable.
    func testAURLInsideAFenceIsNotALink() {
        makeEditor()
        paste(
            """
            ```
            https://example.com
            ```
            """
        )
        XCTAssertNil(attributes(at: 4)[.link], "a fenced URL took the link attribute")
    }

    /// The markdown construct reads as one link: the label wears the
    /// link color, the syntax dims like a fence's rules, and the whole
    /// construct — syntax included — carries `.link`, so a ⌘-click
    /// anywhere on it opens the target.
    func testAMarkdownLinkDimsItsSyntaxInPlace() {
        makeEditor()
        paste("[docs](https://example.com)")
        XCTAssertEqual(
            (attributes(at: 1)[.link] as? URL)?.absoluteString, "https://example.com"
        )
        XCTAssertEqual(attributes(at: 1)[.foregroundColor] as? NSColor, NSColor.linkColor)
        XCTAssertEqual(
            attributes(at: 0)[.foregroundColor] as? NSColor, NSColor.tertiaryLabelColor,
            "the opening bracket is dimmed syntax"
        )
        XCTAssertEqual(
            attributes(at: 8)[.foregroundColor] as? NSColor, NSColor.tertiaryLabelColor,
            "the URL between the parens is dimmed syntax"
        )
        XCTAssertNotNil(attributes(at: 8)[.link], "but it still opens on ⌘-click")
    }

    /// The restyle pass lays every line back down to plain ink first,
    /// so a URL swallowed by a fence stops being a link on the next
    /// pass rather than keeping a stale attribute.
    func testOpeningAFenceAboveAURLUnlinksIt() {
        makeEditor()
        paste("https://example.com")
        XCTAssertNotNil(attributes(at: 0)[.link])

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("```\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.restyle()

        XCTAssertNil(attributes(at: 4)[.link], "the fenced URL kept its link attribute")
    }
}
