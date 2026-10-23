import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class MarkdownPreviewRenderingTests: XCTestCase {
    private func render(_ markdown: String) -> NSAttributedString {
        MarkdownPreviewView.render(NSAttributedString(string: markdown))
    }

    private func range(_ text: String, in rendered: NSAttributedString) throws -> NSRange {
        let range = (rendered.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing rendered text: \(text)")
        return try XCTUnwrap(range.location == NSNotFound ? nil : range)
    }

    private func font(_ text: String, in rendered: NSAttributedString) throws -> NSFont {
        let index = try range(text, in: rendered).location
        return try XCTUnwrap(rendered.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
    }

    private func style(_ text: String, in rendered: NSAttributedString) throws -> NSParagraphStyle {
        let index = try range(text, in: rendered).location
        return try XCTUnwrap(rendered.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
    }

    private func link(_ text: String, in rendered: NSAttributedString) throws -> URL? {
        let index = try range(text, in: rendered).location
        return rendered.attribute(.link, at: index, effectiveRange: nil) as? URL
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

    func testHeadingsAndInlineFormattingRemoveSyntaxAndKeepParagraphBoundaries() throws {
        let rendered = render("""
        # Heading **bold**

        Body with **strong**, *emphasis*, ***both***, ~~gone~~ and `let x = 1`.

        Setext heading
        --------------
        """)
        XCTAssertEqual(rendered.string, "Heading bold\nBody with strong, emphasis, both, gone and let x = 1.\nSetext heading\n")
        XCTAssertGreaterThan(try font("Heading", in: rendered).pointSize, InkStyle.baseFont.pointSize)
        XCTAssertGreaterThan(try font("Setext", in: rendered).pointSize, InkStyle.baseFont.pointSize)
        XCTAssertEqual(try font("Body", in: rendered), InkStyle.baseFont)
        let manager = NSFontManager.shared
        XCTAssertTrue(manager.traits(of: try font("strong", in: rendered)).contains(.boldFontMask))
        XCTAssertTrue(manager.traits(of: try font("emphasis", in: rendered)).contains(.italicFontMask))
        XCTAssertTrue(manager.traits(of: try font("both", in: rendered)).contains([.boldFontMask, .italicFontMask]))
        let strike = try range("gone", in: rendered)
        XCTAssertEqual(rendered.attribute(.strikethroughStyle, at: strike.location, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(try font("let x", in: rendered), InkStyle.codeFont)
        XCTAssertNotNil(rendered.attribute(.backgroundColor, at: try range("let x", in: rendered).location, effectiveRange: nil))
        XCTAssertGreaterThan(try style("Heading", in: rendered).paragraphSpacingBefore, 0)
    }

    func testReferencesEscapesEntitiesAndAutolinksUseParserSemantics() throws {
        let rendered = render(#"""
        [Reference][docs], [docs] and [**Inline**](https://example.com/a?x=1&y=2).
        \*literal\* &amp; &#65; <https://example.org> <reader@example.org>

        [docs]: https://example.com/reference "Title"
        """#)
        XCTAssertTrue(rendered.string.contains("*literal* & A"))
        XCTAssertFalse(rendered.string.contains("[docs]:"))
        XCTAssertEqual(try link("Reference", in: rendered)?.absoluteString, "https://example.com/reference")
        XCTAssertEqual(try link("docs", in: rendered)?.absoluteString, "https://example.com/reference")
        XCTAssertEqual(try link("Inline", in: rendered)?.absoluteString, "https://example.com/a?x=1&y=2")
        XCTAssertEqual(try link("https://example.org", in: rendered)?.host, "example.org")
        XCTAssertEqual(try link("reader@example.org", in: rendered)?.scheme, "mailto")
        XCTAssertTrue(NSFontManager.shared.traits(of: try font("Inline", in: rendered)).contains(.boldFontMask))
    }

    func testOnlyHTTPHTTPSAndMailtoLinksAreInteractive() throws {
        let rendered = render("""
        [web](http://example.com) [secure](HTTPS://example.com) [mail](mailto:a@example.com)
        [script](javascript:alert%281%29) [file](file:///tmp/private) [data](data:text/plain,hello)
        [relative](/path) [fragment](#heading) [ftp](ftp://example.com)
        """)
        for label in ["web", "secure", "mail"] {
            XCTAssertNotNil(try link(label, in: rendered), label)
        }
        for label in ["script", "file", "data", "relative", "fragment", "ftp"] {
            XCTAssertNil(try link(label, in: rendered), label)
        }
    }

    /// A mailto link keeps the address and loses its query and fragment, which name headers,
    /// a body and attachments for the mail client; a web link keeps its query.
    func testAMailtoLinkKeepsTheAddressAndLosesItsQueryAndFragment() throws {
        let rendered = render("""
        [mail](mailto:a@example.com?subject=hi&attach=/etc/passwd&bcc=b@example.com#x)
        [plain](mailto:a@example.com) [web](https://example.com/a?x=1#top)
        """)
        XCTAssertEqual(try link("mail", in: rendered)?.absoluteString, "mailto:a@example.com")
        XCTAssertEqual(try link("plain", in: rendered)?.absoluteString, "mailto:a@example.com")
        XCTAssertEqual(try link("web", in: rendered)?.absoluteString, "https://example.com/a?x=1#top")
    }

    func testSoftBreaksBecomeSpacesAndHardBreaksStayInsideTheirParagraph() throws {
        let rendered = render("soft\nwrap  \nhard\\\nbreak\n\nnext")
        XCTAssertEqual(rendered.string, "soft wrap\u{2028}hard\u{2028}break\nnext\n")
        XCTAssertEqual(try style("soft", in: rendered), try style("break", in: rendered))
    }

    func testFencedAndIndentedCodeRemainLiteralAndDoNotLeakFenceMarkers() throws {
        let rendered = render("""
        ```swift
        let text = "**not bold**"
        <tag>&value</tag>
        ```

            indented *literal*
        """)
        XCTAssertEqual(rendered.string, "let text = \"**not bold**\"\n<tag>&value</tag>\nindented *literal*\n")
        XCTAssertEqual(try font("not bold", in: rendered), InkStyle.codeFont)
        XCTAssertEqual(try font("indented", in: rendered), InkStyle.codeFont)
        XCTAssertFalse(try style("let text", in: rendered).textBlocks.isEmpty)
        XCTAssertFalse(try style("indented", in: rendered).textBlocks.isEmpty)
        XCTAssertNil(try link("<tag>", in: rendered))
    }

    func testNestedListsTasksAndContinuationParagraphsHaveHangingIndents() throws {
        let rendered = render("""
        3. outer
           - inner
             - [x] done
             - [ ] pending

           continuation
        4. next
        """)
        XCTAssertTrue(rendered.string.contains("3.\touter"))
        XCTAssertTrue(rendered.string.contains("4.\tnext"))
        XCTAssertTrue(rendered.string.contains("•\tinner"))
        XCTAssertTrue(rendered.string.contains("☑\tdone"))
        XCTAssertTrue(rendered.string.contains("☐\tpending"))
        XCTAssertFalse(rendered.string.contains("[x]"))
        let outer = try style("outer", in: rendered)
        let inner = try style("inner", in: rendered)
        let done = try style("done", in: rendered)
        XCTAssertGreaterThan(outer.headIndent, outer.firstLineHeadIndent)
        XCTAssertGreaterThan(inner.headIndent, outer.headIndent)
        XCTAssertGreaterThan(done.headIndent, inner.headIndent)
        XCTAssertEqual(try style("continuation", in: rendered).headIndent, outer.headIndent)
        XCTAssertEqual(try style("continuation", in: rendered).firstLineHeadIndent, outer.headIndent)
    }

    func testBlockquotesAndThematicBreaksUseNativeParagraphBlocks() throws {
        let rendered = render("> quote **bold**\n>\n> > nested\n\n---\n\nafter")
        XCTAssertFalse(rendered.string.contains(">"))
        XCTAssertFalse(rendered.string.contains("---"))
        XCTAssertEqual(try style("quote", in: rendered).textBlocks.count, 1)
        XCTAssertEqual(try style("nested", in: rendered).textBlocks.count, 2)
        XCTAssertTrue(try style("after", in: rendered).textBlocks.isEmpty)
        let rule = try style("\u{200B}", in: rendered)
        let block = try XCTUnwrap(rule.textBlocks.first)
        XCTAssertEqual(block.width(for: .border, edge: .maxY), 1)
    }

    /// Images show alt text, supported HTML formats, and a script stays visible text
    /// (`MarkdownPreviewCompositionTests` has the composition fixtures).
    func testImagesUseAltTextAndHTMLComposesUnderThePreviewPolicy() throws {
        let rendered = render("""
        ![Remote **alt**](https://example.com/pixel.png) ![Local](file:///tmp/image.png)
        inline <em>HTML</em>

        <script>alert('literal')</script>
        """)
        XCTAssertTrue(rendered.string.contains("Remote alt Local"))
        XCTAssertFalse(rendered.string.contains("pixel.png"))
        XCTAssertFalse(rendered.string.contains("/tmp/image.png"))
        XCTAssertTrue(rendered.string.contains("inline HTML\n"))
        XCTAssertTrue(NSFontManager.shared.traits(of: try font("HTML", in: rendered)).contains(.italicFontMask))
        XCTAssertTrue(rendered.string.contains("<script>alert('literal')</script>"))
        XCTAssertTrue(attachments(in: rendered).isEmpty)
        XCTAssertNil(try link("Remote", in: rendered))
    }

    func testTablesUseNativeCellsWithAlignmentInlineFormattingAndEmptyCells() throws {
        let rendered = render(#"""
        | Left | Center | Right |
        | :--- | :----: | ----: |
        | **bold** | [link](https://example.com) | `code` |
        | escaped \| pipe | ~~strike~~ | |

        outside
        """#)
        XCTAssertFalse(rendered.string.contains("| Left"))
        XCTAssertFalse(rendered.string.contains(":---"))
        XCTAssertTrue(rendered.string.contains("escaped | pipe"))
        let left = try XCTUnwrap(try style("Left", in: rendered).textBlocks.last as? NSTextTableBlock)
        let center = try XCTUnwrap(try style("Center", in: rendered).textBlocks.last as? NSTextTableBlock)
        let right = try XCTUnwrap(try style("Right", in: rendered).textBlocks.last as? NSTextTableBlock)
        XCTAssertTrue(left.table === center.table)
        XCTAssertTrue(left.table === right.table)
        XCTAssertEqual(left.table.numberOfColumns, 3)
        XCTAssertEqual(left.table.layoutAlgorithm, .fixedLayoutAlgorithm)
        XCTAssertEqual(left.table.contentWidth, 100)
        XCTAssertEqual(left.table.contentWidthValueType, .percentageValueType)
        XCTAssertEqual(left.startingRow, 0)
        XCTAssertEqual(right.startingColumn, 2)
        XCTAssertEqual(try style("Center", in: rendered).alignment, .center)
        XCTAssertEqual(try style("Right", in: rendered).alignment, .right)
        XCTAssertTrue(NSFontManager.shared.traits(of: try font("Left", in: rendered)).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: try font("bold", in: rendered)).contains(.boldFontMask))
        XCTAssertEqual(try font("code", in: rendered), InkStyle.codeFont)
        XCTAssertEqual(try link("link", in: rendered)?.host, "example.com")
        XCTAssertTrue(try style("outside", in: rendered).textBlocks.isEmpty)

        var cells: Set<ObjectIdentifier> = []
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) {
            value, _, _ in
            for case let cell as NSTextTableBlock in (value as? NSParagraphStyle)?.textBlocks ?? [] {
                cells.insert(ObjectIdentifier(cell))
            }
        }
        XCTAssertEqual(cells.count, 9, "The empty trailing cell must have its own native paragraph.")
    }

    /// Published GFM has no spans: `||` is an empty cell, `^` is text in a cell of its own, and
    /// every cell takes one column and one row.
    func testTableCellsNeverSpanSoEmptyAndCaretCellsKeepTheirOwnColumns() throws {
        let rendered = render("""
        | one | two | three |
        | --- | --- | ----- |
        | wide     || tall  |
        | left | right | ^   |
        """)
        var cells: [(block: NSTextTableBlock, text: String)] = []
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) {
            value, range, _ in
            for case let cell as NSTextTableBlock in (value as? NSParagraphStyle)?.textBlocks ?? [] {
                cells.append((cell, (rendered.string as NSString).substring(with: range)))
            }
        }
        XCTAssertEqual(Set(cells.map { ObjectIdentifier($0.block) }).count, 9, "three cells in each of three rows")
        for (block, text) in cells {
            XCTAssertEqual(block.columnSpan, 1, text)
            XCTAssertEqual(block.rowSpan, 1, text)
            XCTAssertEqual(block.contentWidth, 100 / 3, accuracy: 0.01, text)
        }
        func place(_ text: String) -> [Int]? {
            cells.first { $0.text == text + "\n" }.map { [$0.block.startingRow, $0.block.startingColumn] }
        }
        XCTAssertEqual(place("wide"), [1, 0])
        XCTAssertEqual(place(""), [1, 1], "`||` leaves an empty cell")
        XCTAssertEqual(place("tall"), [1, 2])
        XCTAssertEqual(place("left"), [2, 0])
        XCTAssertEqual(place("right"), [2, 1])
        XCTAssertEqual(place("^"), [2, 2], "`^` is the cell's text")
    }

    func testTableLayoutWrapsToThePreviewWidthAndReflowsOnResize() throws {
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.isSelectedPage = true
        let words = Array(repeating: "wrapping words", count: 12).joined(separator: " ")
        view.reseed(with: PageModel.QuietRendering(
            text: NSAttributedString(string: "| Name | Description |\n| --- | --- |\n| row | \(words) |"),
            fenceRegions: []
        ))
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        func layout(width: CGFloat) -> NSRect {
            view.setFrameSize(NSSize(width: width, height: 2000))
            manager.ensureLayout(for: container)
            return manager.usedRect(for: container)
        }
        let narrow = layout(width: 320)
        let narrowContainerWidth = container.size.width
        XCTAssertEqual(narrowContainerWidth, 320 - view.textContainerInset.width * 2, accuracy: 1)
        XCTAssertGreaterThan(narrow.height, 0)
        XCTAssertLessThanOrEqual(narrow.maxX, narrowContainerWidth + 1)
        let wide = layout(width: 760)
        XCTAssertLessThanOrEqual(wide.maxX, container.size.width + 1)
        XCTAssertGreaterThan(wide.width, narrow.width)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertEqual(view.textContainerInset.width, 12)
        XCTAssertEqual(view.textContainerInset.height, InkEditorView.Coordinator.topInset)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        XCTAssertTrue(container.widthTracksTextView)
        XCTAssertEqual(view.textStorage?.layoutManagers.count, 1)
    }

    /// An object in a cell of a multi column table takes the cell's width, not the
    /// preview's, at either width of the preview; the editor's own container keeps its
    /// measure, since its fragments are as wide as the container (`SealedBlockTests`).
    func testAnObjectInAMultiColumnTableCellFitsTheCell() throws {
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.isSelectedPage = true
        let source = NSMutableAttributedString(string: "| Object | Note |\n| --- | --- |\n| ")
        let object = chip(1)
        source.append(NSAttributedString(attachment: object))
        source.append(NSAttributedString(string: " | beside |"))
        view.reseed(with: PageModel.QuietRendering(text: source, fenceRegions: []))
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let index = (view.string as NSString).range(of: "\u{FFFC}").location
        XCTAssertNotEqual(index, NSNotFound)
        for width: CGFloat in [360, 720] {
            view.setFrameSize(NSSize(width: width, height: 2000))
            manager.ensureLayout(for: container)
            let glyph = manager.glyphIndexForCharacter(at: index)
            let block = manager.attachmentSize(forGlyphAt: glyph)
            XCTAssertGreaterThan(block.width, 0, "\(width)")
            XCTAssertLessThanOrEqual(block.width, container.size.width / 2, "\(width): the object overran its cell")
            XCTAssertGreaterThan(block.width, container.size.width / 4, "\(width): the object took no cell")
            XCTAssertEqual(block.height, SealedBlockCell.blockHeight)
            XCTAssertLessThanOrEqual(manager.usedRect(for: container).maxX, container.size.width + 1)
        }

        let plain = NSTextContainer(size: NSSize(width: 400, height: 400))
        let cell = NSRect(x: 0, y: 0, width: 200, height: SealedBlockCell.blockHeight)
        XCTAssertEqual(
            SealedBlockCell.blockWidth(in: plain, proposedLineFragment: cell),
            floor(200 - plain.lineFragmentPadding * 2))
        let editor = InkTextContainer(size: plain.size)
        XCTAssertEqual(
            SealedBlockCell.blockWidth(in: editor, proposedLineFragment: cell),
            floor(400 - editor.lineFragmentPadding * 2), "the editor keeps its measure")
    }

    /// What the preview shows of a selection, in rendered order: a link's text is ink like
    /// the text around it, each object is its chip id, and the destination never appears.
    func testTheShownSelectionKeepsRenderedOrderAcrossALinkAndItsObjects() throws {
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        view.isSelectedPage = true
        let source = NSMutableAttributedString(string: "see [a link](https://example.com/secret) ")
        source.append(NSAttributedString(attachment: chip(5)))
        source.append(NSAttributedString(string: " then "))
        source.append(NSAttributedString(attachment: chip(6)))
        source.append(NSAttributedString(string: " end"))
        view.reseed(with: PageModel.QuietRendering(text: source, fenceRegions: []))
        XCTAssertEqual(view.string, "see a link \u{FFFC} then \u{FFFC} end\n")

        view.selectAll(nil)
        XCTAssertEqual(view.shownSelection(), [[
            .ink("see a link "), .chip(5), .ink(" then "), .chip(6), .ink(" end\n"),
        ]])

        let shown = view.string as NSString
        view.setSelectedRange(NSRange(location: shown.range(of: "link").location, length: 13))
        XCTAssertEqual(view.shownSelection(), [[.ink("link "), .chip(5), .ink(" then "), .chip(6)]])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(view.shownSelection(), [])
    }

    func testAttachmentsKeepObjectIdentityAcrossInlineCodeTablesAndHTML() throws {
        let source = NSMutableAttributedString(string: "# Before 😀 **")
        let first = chip(1)
        let second = chip(2)
        let third = chip(3)
        let fourth = chip(4)
        source.append(NSAttributedString(attachment: first))
        source.append(NSAttributedString(string: "** after\n\n```\n"))
        source.append(NSAttributedString(attachment: second))
        source.append(NSAttributedString(string: "\n```\n\n| Object |\n| --- |\n| "))
        source.append(NSAttributedString(attachment: third))
        source.append(NSAttributedString(string: " |\n\n<div>"))
        source.append(NSAttributedString(attachment: fourth))
        source.append(NSAttributedString(string: "</div>"))
        let original = NSAttributedString(attributedString: source)
        let rendered = MarkdownPreviewView.render(source)
        let found = attachments(in: rendered)
        XCTAssertEqual(found.count, 4)
        for (actual, expected) in zip(found, [first, second, third, fourth]) {
            XCTAssertTrue(actual === expected)
        }
        XCTAssertEqual(rendered.string.filter { $0 == "\u{FFFC}" }.count, 4)
        XCTAssertFalse(rendered.string.contains("test-face"))
        XCTAssertFalse(rendered.string.contains("OTSAttachment"))
        XCTAssertTrue(source.isEqual(to: original))
    }

    func testAttachmentsInNonvisibleDestinationsAndDefinitionsAreNotDroppedOrLinked() throws {
        let source = NSMutableAttributedString(string: "😀 é\r\n\r\n[hidden]: https://example.com/")
        let first = chip(1)
        let second = chip(2)
        source.append(NSAttributedString(attachment: first))
        source.append(NSAttributedString(string: "\r\n\r\n[visible](https://example.com/"))
        source.append(NSAttributedString(attachment: second))
        source.append(NSAttributedString(string: ")\r\n\r\nafter"))
        let rendered = MarkdownPreviewView.render(source)
        let found = attachments(in: rendered)
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.first === first)
        XCTAssertTrue(found.last === second)
        XCTAssertNil(try link("visible", in: rendered))
        XCTAssertFalse(rendered.string.contains("OTSAttachment"))
        let object = try range("\u{FFFC}", in: rendered)
        XCTAssertLessThan(object.location, try range("visible", in: rendered).location)
        let lastObject = (rendered.string as NSString).range(of: "\u{FFFC}", options: .backwards)
        XCTAssertLessThan(lastObject.location, try range("after", in: rendered).location)
    }

    /// An object inside a link's own destination is the link's: it follows the label, as in the
    /// source, outside the link, which it refuses (plan R1).
    func testAnObjectInALinkDestinationFollowsTheLabel() throws {
        let source = NSMutableAttributedString(string: "[label](https://example.com/")
        let hidden = chip(1)
        let visible = chip(2)
        source.append(NSAttributedString(attachment: hidden))
        source.append(NSAttributedString(string: ") then "))
        source.append(NSAttributedString(attachment: visible))
        source.append(NSAttributedString(string: " end\n\nnext "))
        let later = chip(3)
        source.append(NSAttributedString(attachment: later))
        let rendered = MarkdownPreviewView.render(source)
        let found = attachments(in: rendered)
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found[0] === hidden)
        XCTAssertTrue(found[1] === visible)
        XCTAssertTrue(found[2] === later)
        XCTAssertNil(try link("label", in: rendered))
        XCTAssertFalse(rendered.string.contains("OTSAttachment"))
        XCTAssertEqual(rendered.string, "label\u{FFFC} then \u{FFFC} end\nnext \u{FFFC}\n")
        XCTAssertNil(rendered.attribute(.link, at: 5, effectiveRange: nil), "an object never takes a link")
    }

    /// A token's spelling in the ink, prefix and digits with no closing Z or naming no
    /// object, is literal text; the object's own spelling resolves beside it.
    func testATokenLikeSpellingWithoutAnObjectStaysLiteral() throws {
        let source = NSMutableAttributedString(string: "OTSAttachment0Z OTSAttachment99Z ")
        let only = chip(7)
        source.append(NSAttributedString(attachment: only))
        let rendered = MarkdownPreviewView.render(source)
        XCTAssertEqual(rendered.string, "OTSAttachment0Z OTSAttachment99Z \u{FFFC}\n")
        XCTAssertEqual(attachments(in: rendered).count, 1)
        XCTAssertTrue(attachments(in: rendered).first === only)
    }

    func testInlineCodeInAHeadingKeepsTheHeadingSize() throws {
        let rendered = render("# Heading `code`")
        XCTAssertEqual(try font("Heading", in: rendered).pointSize, try font("code", in: rendered).pointSize)
        XCTAssertGreaterThan(try font("code", in: rendered).pointSize, InkStyle.baseFont.pointSize)
    }

    func testEmptyInputAndSourceStylingDoNotCarryEditorAttributesIntoPreview() throws {
        XCTAssertEqual(render("").length, 0)
        let source = NSAttributedString(string: "plain **bold**", attributes: [
            .foregroundColor: NSColor.clear,
            .link: URL(fileURLWithPath: "/tmp/private"),
            .font: NSFont.systemFont(ofSize: 80),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ])
        let rendered = MarkdownPreviewView.render(source)
        XCTAssertEqual(rendered.string, "plain bold\n")
        XCTAssertEqual(try font("plain", in: rendered), InkStyle.baseFont)
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.labelColor)
        XCTAssertNil(rendered.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNil(rendered.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
    }

    func testReseedingSkipsTheSameIdentityButRendersANewWrapper() throws {
        let view = MarkdownPreviewView(page: 1, coordinator: nil)
        let rendering = PageModel.QuietRendering(text: NSAttributedString(string: "**first**"), fenceRegions: [])
        XCTAssertNil(view.reseed(with: rendering), "a first seeding replaced no text")
        XCTAssertEqual(view.string, "first\n")
        let storage = try XCTUnwrap(view.textStorage)
        let sentinel = NSAttributedString.Key("MarkdownPreviewIdentityTest")
        storage.addAttribute(sentinel, value: true, range: NSRange(location: 0, length: 1))
        XCTAssertNil(view.reseed(with: rendering), "the same rendering replaced nothing")
        XCTAssertNotNil(storage.attribute(sentinel, at: 0, effectiveRange: nil))
        let replacement = PageModel.QuietRendering(text: rendering.text, fenceRegions: [])
        XCTAssertEqual(view.reseed(with: replacement), "first\n")
        XCTAssertNil(storage.attribute(sentinel, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            view.reseed(with: PageModel.QuietRendering(text: NSAttributedString(string: "# second"), fenceRegions: [])),
            "first\n")
        XCTAssertEqual(view.string, "second\n")
    }
}
