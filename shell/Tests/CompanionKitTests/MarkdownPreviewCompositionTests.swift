import AppKit
import XCTest

@testable import CompanionKit

/// The rendered page preview with raw HTML composed through `PreviewComposer` (plan R3):
/// the native subset, escaped markup, image descriptors and sealed objects in rendered order.
@MainActor
final class MarkdownPreviewCompositionTests: XCTestCase {
    private func render(_ markdown: String, dialect: PreviewDialect = .gfm) -> NSAttributedString {
        MarkdownPreviewView.render(NSAttributedString(string: markdown), dialect: dialect)
    }

    private func range(_ text: String, in rendered: NSAttributedString) throws -> NSRange {
        let range = (rendered.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing rendered text: \(text)")
        return try XCTUnwrap(range.location == NSNotFound ? nil : range)
    }

    private func attribute(
        _ key: NSAttributedString.Key, of text: String, in rendered: NSAttributedString
    ) throws -> Any? {
        rendered.attribute(key, at: try range(text, in: rendered).location, effectiveRange: nil)
    }

    private func traits(_ text: String, in rendered: NSAttributedString) throws -> NSFontTraitMask {
        let font = try XCTUnwrap(try attribute(.font, of: text, in: rendered) as? NSFont)
        return NSFontManager.shared.traits(of: font).intersection([.boldFontMask, .italicFontMask])
    }

    private func struck(_ text: String, in rendered: NSAttributedString) throws -> Bool {
        try attribute(.strikethroughStyle, of: text, in: rendered) as? Int == NSUnderlineStyle.single.rawValue
    }

    private func link(_ text: String, in rendered: NSAttributedString) throws -> URL? {
        try attribute(.link, of: text, in: rendered) as? URL
    }

    private func chip(_ id: UInt64) -> ChipAttachment {
        ChipAttachment(info: ChipInfo(
            chipId: id, kind: "text", excerpt: "test-face", sizeLabel: "small", concealed: false
        ))
    }

    private func attachments(in rendered: NSAttributedString) -> [NSTextAttachment] {
        var found: [NSTextAttachment] = []
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) {
            value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            for _ in 0..<range.length { found.append(attachment) }
        }
        return found
    }

    /// Each image descriptor once, in rendered order, with the text it marks.
    private func images(in rendered: NSAttributedString) -> [(PreviewImageDescriptor, String)] {
        var found: [(PreviewImageDescriptor, String)] = []
        rendered.enumerateAttribute(.previewImage, in: NSRange(location: 0, length: rendered.length)) {
            value, range, _ in
            guard let descriptor = value as? PreviewImageDescriptor else { return }
            let text = (rendered.string as NSString).substring(with: range)
            if let last = found.last, last.0 == descriptor {
                found[found.count - 1].1 += text
            } else {
                found.append((descriptor, text))
            }
        }
        return found
    }

    /// A source with chips 1, 2, ... standing where `parts` has `nil`.
    private func source(_ parts: [String?]) -> (NSAttributedString, [ChipAttachment]) {
        let text = NSMutableAttributedString(string: "")
        var chips: [ChipAttachment] = []
        for part in parts {
            if let part {
                text.append(NSAttributedString(string: part))
            } else {
                let object = chip(UInt64(chips.count + 1))
                chips.append(object)
                text.append(NSAttributedString(attachment: object))
            }
        }
        return (text, chips)
    }

    func testTheSupportedHTMLSubsetRendersNativelyWithoutItsTags() throws {
        let rendered = render("""
        Plain <em>alpha</em> <i>bravo</i> <strong>charlie</strong> <b>delta</b> <del>echo</del> \
        <s>foxtrot</s> <strike>golf</strike> <code>hotel</code> <span>india</span> juliet
        """)
        XCTAssertEqual(rendered.string, "Plain alpha bravo charlie delta echo foxtrot golf hotel india juliet\n")
        XCTAssertEqual(try traits("alpha", in: rendered), .italicFontMask)
        XCTAssertEqual(try traits("bravo", in: rendered), .italicFontMask)
        XCTAssertEqual(try traits("charlie", in: rendered), .boldFontMask)
        XCTAssertEqual(try traits("delta", in: rendered), .boldFontMask)
        for word in ["echo", "foxtrot", "golf"] {
            XCTAssertTrue(try struck(word, in: rendered), word)
        }
        XCTAssertEqual(try attribute(.font, of: "hotel", in: rendered) as? NSFont, InkStyle.codeFont)
        XCTAssertNotNil(try attribute(.backgroundColor, of: "hotel", in: rendered))
        for word in ["Plain", "india", "juliet"] {
            XCTAssertEqual(try traits(word, in: rendered), [], word)
            XCTAssertFalse(try struck(word, in: rendered), word)
            XCTAssertEqual(try attribute(.font, of: word, in: rendered) as? NSFont, InkStyle.baseFont, word)
        }
    }

    /// `A <em>one **two**</em>` spans HTML and Markdown nodes; each word takes both scopes.
    func testMarkdownAndHTMLFormattingCombineAcrossEachOther() throws {
        let rendered = render("A <em>one **two**</em> end and **bold <em>both</em>** after")
        XCTAssertEqual(rendered.string, "A one two end and bold both after\n")
        XCTAssertEqual(try traits("one", in: rendered), .italicFontMask)
        XCTAssertEqual(try traits("two", in: rendered), [.italicFontMask, .boldFontMask])
        XCTAssertEqual(try traits("end", in: rendered), [])
        XCTAssertEqual(try traits("bold", in: rendered), .boldFontMask)
        XCTAssertEqual(try traits("both", in: rendered), [.italicFontMask, .boldFontMask])
        XCTAssertEqual(try traits("after", in: rendered), [])
    }

    /// `<del>` blocks around a paragraph strike it; one HTML block with the same lines is
    /// HTML text, so its Markdown stays literal (plan R3).
    func testHTMLScopeCrossesBlocksAndAnHTMLBlockIsNotReparsedAsMarkdown() throws {
        let across = render("<del>\n\n*x*\n\n</del>\n\nafter")
        XCTAssertEqual(across.string, "x\nafter\n")
        XCTAssertTrue(try struck("x", in: across))
        XCTAssertEqual(try traits("x", in: across), .italicFontMask)
        XCTAssertFalse(try struck("after", in: across))

        let within = render("<del>\n*x*\n</del>\n\nafter")
        XCTAssertEqual(within.string, "*x*\nafter\n")
        XCTAssertTrue(try struck("*x*", in: within))
        XCTAssertEqual(try traits("*x*", in: within), [])
        XCTAssertFalse(try struck("after", in: within))
    }

    func testDecodedAndEscapedTextNeverBecomesMarkup() throws {
        let rendered = render(#"&lt;em&gt;literal&lt;/em&gt; and \<b>escaped\</b> `<i>code</i>`"#)
        XCTAssertEqual(rendered.string, "<em>literal</em> and <b>escaped</b> <i>code</i>\n")
        XCTAssertEqual(try traits("literal", in: rendered), [])
        XCTAssertEqual(try traits("escaped", in: rendered), [])
        XCTAssertEqual(try traits("code", in: rendered), [])
    }

    /// Markup outside the subset is escaped into visible text; GFM's disallowed tags too, so
    /// no script runs and no frame embeds.
    func testUnsupportedAndDisallowedMarkupStaysVisibleText() throws {
        let rendered = render("""
        Press <kbd>K</kbd> now.

        <script>alert('x')</script>

        <iframe src="https://example.invalid/embed"></iframe>
        """)
        XCTAssertEqual(rendered.string, """
        Press <kbd>K</kbd> now.
        <script>alert('x')</script>
        <iframe src="https://example.invalid/embed"></iframe>

        """)
        XCTAssertTrue(attachments(in: rendered).isEmpty)
        XCTAssertTrue(images(in: rendered).isEmpty)
        XCTAssertNil(try link("iframe", in: rendered))
    }

    /// Comments leave no text and no empty paragraph; an object inside one keeps its place.
    func testCommentsVanishAndKeepTheirObjects() throws {
        let (text, chips) = source(["before <!-- hidden ", nil, " --> after\n\n<!-- block note -->\n\nend"])
        let rendered = MarkdownPreviewView.render(text)
        XCTAssertEqual(rendered.string, "before \u{FFFC} after\nend\n")
        let found = attachments(in: rendered)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first === chips[0])
    }

    /// An HTML link passes the Markdown link's scheme policy; its click route is the preview's.
    func testHTMLLinksTakeTheMarkdownLinkPolicy() throws {
        let rendered = render("""
        <a href="https://example.com/x?a=1&amp;b=2">site</a> <a href="javascript:alert(1)">script</a> \
        <a href="mailto:a@example.com?subject=x">mail</a> <a>bare</a> \
        [outer <a href="https://example.com/inner">inner</a>](https://example.com/outer)
        """)
        XCTAssertEqual(try link("site", in: rendered)?.absoluteString, "https://example.com/x?a=1&b=2")
        XCTAssertEqual(try attribute(.foregroundColor, of: "site", in: rendered) as? NSColor, NSColor.linkColor)
        XCTAssertNil(try link("script", in: rendered))
        XCTAssertEqual(try link("mail", in: rendered)?.absoluteString, "mailto:a@example.com")
        XCTAssertNil(try link("bare", in: rendered))
        XCTAssertEqual(try link("inner", in: rendered)?.absoluteString, "https://example.com/outer")
    }

    /// An image renders as its alt text in secondary ink, with a descriptor naming its address,
    /// no link, even inside one, and no attachment (ADR-0059).
    func testImagesShowAltTextWithAnInertDescriptor() throws {
        let rendered = render("""
        ![Remote *alt*](https://example.invalid/pixel.png) \
        <img src="https://example.invalid/a.png?x=1&amp;y=2" alt="Logo &amp; mark" \
        srcset="https://example.invalid/b.png 2x" onerror="run()"> \
        [![Badge](https://example.invalid/badge.svg)](https://example.com/project) ![](https://example.invalid/empty.png)
        """)
        XCTAssertEqual(rendered.string, "Remote alt Logo & mark Badge \n")
        let found = images(in: rendered)
        XCTAssertEqual(found.map(\.0), [
            PreviewImageDescriptor(occurrence: 0, destination: .unreviewed("https://example.invalid/pixel.png")),
            PreviewImageDescriptor(occurrence: 1, destination: .unreviewed("https://example.invalid/a.png?x=1&y=2")),
            PreviewImageDescriptor(occurrence: 2, destination: .unreviewed("https://example.invalid/badge.svg")),
        ])
        XCTAssertEqual(found.map(\.1), ["Remote alt", "Logo & mark", "Badge"])
        for alt in ["Remote", "Logo", "Badge"] {
            XCTAssertNil(try link(alt, in: rendered), alt)
            XCTAssertEqual(try attribute(.foregroundColor, of: alt, in: rendered) as? NSColor,
                           NSColor.secondaryLabelColor, alt)
        }
        XCTAssertEqual(try traits("alt", in: rendered), [], "alt text is plain text")
        XCTAssertTrue(attachments(in: rendered).isEmpty)
    }

    /// An object in an image's or a link's address refuses the address and still stands in
    /// rendered order, which a selection's copy keeps (Law 0001, copy row; ADR-0059 §5).
    func testObjectsInAddressesAreRefusedAndKeepTheirPlaceInCopy() throws {
        let (text, chips) = source([
            "![alt ](https://example.invalid/", nil, ") then <img src=\"https://example.invalid/", nil,
            "\" alt=\"html ", nil, "\"> and <a href=\"https://example.com/", nil, "\">label</a> end",
        ])
        let rendered = MarkdownPreviewView.render(text)
        XCTAssertEqual(rendered.string, "alt \u{FFFC} then \u{FFFC}html \u{FFFC} and \u{FFFC}label end\n")
        let found = attachments(in: rendered)
        XCTAssertEqual(found.count, 4)
        for (actual, expected) in zip(found, chips) { XCTAssertTrue(actual === expected) }
        XCTAssertEqual(images(in: rendered).map(\.0.destination), [.refused(.sealedObject), .refused(.sealedObject)])
        XCTAssertNil(try link("label", in: rendered))
        XCTAssertFalse(rendered.string.contains("OTSAttachment"))

        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.isSelectedPage = true
        view.reseed(with: PageModel.QuietRendering(text: text, fenceRegions: []))
        view.selectAll(nil)
        XCTAssertEqual(view.shownSelection(), [[
            .ink("alt "), .chip(1), .ink(" then "), .chip(2), .ink("html "), .chip(3), .ink(" and "),
            .chip(4), .ink("label end\n"),
        ]])
    }

    /// Reference images and later markup keep their objects separate during composition.
    func testAReferenceImageTakesNoObjectFromElsewhere() throws {
        let (text, chips) = source([
            "![pic][r] <a href=\"https://example.com/", nil, "\">label</a> <img src=\"https://example.invalid/", nil,
            "\" alt=\"html\"> <b", nil, ">bold</b> middle ", nil, " end\n\n[r]: https://example.invalid/", nil,
        ])
        let rendered = MarkdownPreviewView.render(text)
        XCTAssertEqual(rendered.string, "pic \u{FFFC}label \u{FFFC}html <b\u{FFFC}>bold</b> middle \u{FFFC} end\n\u{FFFC}\n")
        let found = attachments(in: rendered)
        XCTAssertEqual(found.count, 5)
        for (actual, expected) in zip(found, chips) { XCTAssertTrue(actual === expected) }
        XCTAssertNil(try link("label", in: rendered))
        XCTAssertEqual(images(in: rendered).map { $0.0.destination }, [.refused(.sealedObject), .refused(.sealedObject)])
        XCTAssertEqual(images(in: rendered).map { $0.1 }, ["pic", "\u{FFFC}html"])
        XCTAssertEqual(try traits("bold", in: rendered), [])
    }

    /// Inside a Markdown link, accepted or refused, an HTML link around it never applies.
    func testAnHTMLLinkNeverAppliesInsideAMarkdownLink() throws {
        let (text, _) = source(["<a href=\"https://outer.example/\">[label](https://ok.example/", nil, ") after</a>"])
        let rendered = MarkdownPreviewView.render(text)
        XCTAssertNil(try link("label", in: rendered))
        XCTAssertEqual(try link("after", in: rendered)?.host, "outer.example")
    }

    /// Markdown traits cost events but no input, so an ordinary long page stays formatted
    /// (10 events a line went past the first event budget at about 10,000 lines).
    func testALongOrdinaryPageStaysFormatted() throws {
        let rendered = render(Array(repeating: "a *b* `c` d", count: 11_000).joined(separator: "\n"))
        let last = (rendered.string as NSString).range(of: "b", options: .backwards)
        let font = try XCTUnwrap(rendered.attribute(.font, at: last.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
    }

    /// HTML block text lays out as HTML: source line breaks are spaces, `br` breaks the line
    /// inside its paragraph, and the indentation around an image leaves nothing.
    func testHTMLBlocksLayOutTheirTextAsHTML() throws {
        let rendered = render("""
        <div>
        Line one
        Line two<br>
        Line three
        </div>

        <p align="center">
          <img src="logo.png" alt="Logo">
        </p>
        """)
        XCTAssertEqual(rendered.string, "Line one Line two\u{2028}Line three\nLogo\n")
        XCTAssertEqual(images(in: rendered).map(\.0.destination), [.unreviewed("logo.png")])
        // The trim takes source whitespace, not the break a `br` at either end composes to.
        XCTAssertEqual(render("<div><br>a<br></div>").string, "\u{2028}a\u{2028}\n")
    }

    /// The dialect reaches composition: GFM escapes a `script` tag and formats inside it;
    /// CommonMark keeps the raw-text body literal (plan R3). Both parsers read the line as one HTML block.
    func testTheDialectSelectsHowRawTextElementsCompose() throws {
        let gfm = render("<script><em>x</em></script>", dialect: .gfm)
        XCTAssertEqual(gfm.string, "<script>x</script>\n")
        XCTAssertEqual(try traits("x", in: gfm), .italicFontMask)
        let commonMark = render("<script><em>x</em></script>", dialect: .commonMark)
        XCTAssertEqual(commonMark.string, "<script><em>x</em></script>\n")
        XCTAssertEqual(try traits("x", in: commonMark), [])
    }

    /// A page past a composition limit shows its own text with every object in source order,
    /// unformatted, rather than a partial rendering.
    func testAPageOverACompositionLimitShowsItsPlainTextAndObjects() throws {
        let (text, chips) = source(["# Title **bold** <em>x</em> ", nil, "\r\n\r\nnext ", nil])
        var limits = CompositionLimits()
        limits.maximumInputScalars = 12
        let rendered = MarkdownPreviewView.render(text, limits: limits)
        XCTAssertEqual(rendered.string, "# Title **bold** <em>x</em> \u{FFFC}\n\nnext \u{FFFC}\n")
        XCTAssertEqual(try attribute(.font, of: "Title", in: rendered) as? NSFont, InkStyle.baseFont)
        XCTAssertEqual(try traits("x", in: rendered), [])
        let found = attachments(in: rendered)
        XCTAssertEqual(found.count, 2)
        for (actual, expected) in zip(found, chips) { XCTAssertTrue(actual === expected) }

        limits = CompositionLimits()
        limits.maximumDepth = 1
        XCTAssertEqual(MarkdownPreviewView.render(NSAttributedString(string: "**a *b***"), limits: limits).string,
                       "**a *b***\n")
        XCTAssertEqual(MarkdownPreviewView.render(NSAttributedString(string: "**a**"), limits: limits).string,
                       "a\n")
    }

    /// Rendering, layout and drawing of every resource-bearing construct start no load through
    /// the shared URL loading system. Out-of-process and socket loads are outside this probe.
    func testRenderingLayoutAndDrawingStartNoURLLoad() throws {
        XCTAssertTrue(URLProtocol.registerClass(LoadRecorder.self))
        defer { URLProtocol.unregisterClass(LoadRecorder.self) }
        LoadRecorder.reset()
        let markdown = """
        ![md](https://example.invalid/md.png "title") [![linked](https://example.invalid/l.png)](https://example.invalid/open)

        <img src="https://example.invalid/i.png" srcset="https://example.invalid/s.png 2x" alt="html">
        <span style="background: url(https://example.invalid/css.png)">css</span>
        <iframe src="https://example.invalid/frame"></iframe><video poster="https://example.invalid/p.png"></video>
        <object data="https://example.invalid/o"></object><link rel="stylesheet" href="https://example.invalid/s.css">
        <svg><image href="https://example.invalid/svg.png"/></svg> <a href="https://example.invalid/a">a</a>

        [ref]: https://example.invalid/ref.png
        """
        let rendered = render(markdown)
        XCTAssertTrue(attachments(in: rendered).isEmpty)
        XCTAssertEqual(images(in: rendered).count, 3)

        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.isSelectedPage = true
        view.reseed(with: PageModel.QuietRendering(text: NSAttributedString(string: markdown), fenceRegions: []))
        view.setFrameSize(NSSize(width: 480, height: 2000))
        let manager = try XCTUnwrap(view.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(view.textContainer))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertFalse(view.importsGraphics)
        XCTAssertEqual(LoadRecorder.requests, [])

        // The control: a shared-session request is one the probe sees and fails.
        let address = "https://example.invalid/control"
        let failed = expectation(description: "the control request fails")
        URLSession.shared.dataTask(with: try XCTUnwrap(URL(string: address))) { _, _, error in
            XCTAssertNotNil(error)
            failed.fulfill()
        }.resume()
        wait(for: [failed], timeout: 10)
        XCTAssertFalse(LoadRecorder.requests.isEmpty)
        XCTAssertTrue(LoadRecorder.requests.allSatisfy { $0 == address }, "\(LoadRecorder.requests)")
    }
}

/// Records every request the shared URL loading system offers it and fails each one.
private final class LoadRecorder: URLProtocol {
    nonisolated(unsafe) private static var recorded: [String] = []
    private static let lock = NSLock()

    static var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request.url?.absoluteString ?? "")
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}
