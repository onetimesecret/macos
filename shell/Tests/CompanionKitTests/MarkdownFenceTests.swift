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

    /// The visual seam between blocks is the reserved label gap, so a
    /// fence typed line by line — one core block per line — must not
    /// reserve it anywhere but above the opening rule: the interior
    /// lines run at ordinary spacing and the slab reads as contiguous.
    func testAFenceTypedLineByLineReservesNoInteriorGaps() {
        makeEditor()
        for piece in ["```", "\n", "echo hi", "\n", "```", "\n", "after"] {
            textView.insertText(piece, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        coordinator.restyle()
        for line in 1...2 {
            let style = attributes(ofLine: line)[.paragraphStyle] as? NSParagraphStyle
            XCTAssertEqual(
                style?.paragraphSpacingBefore, 0,
                "line \(line) reserved a label gap inside the fence"
            )
        }
        // The prose below the closing rule is its own block again, and
        // its stamp gets its gap back.
        let after = attributes(ofLine: 3)[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(
            after?.paragraphSpacingBefore,
            InkEditorView.Coordinator.blockLabelReserve
        )
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
        }
        XCTAssertEqual(font(ofLine: 6), InkStyle.headingFont(level: 1))
        // The wash is one slab per region, painted by the layout
        // manager, so the region has to run from the opening rule
        // through the closing one and stop before the heading below.
        XCTAssertEqual(coordinator.fenceRegions, [NSRange(location: 17, length: 38)])
    }

    /// The wash is drawn by the layout manager as one rectangle per
    /// region, so no line carries a `.backgroundColor` of its own: a
    /// per-paragraph attribute painted per-line stripes with gaps at
    /// every paragraph seam. What the attributes must still say is that
    /// the fence's own rules are dimmed markup.
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
            XCTAssertEqual(
                background(ofLine: line), NSColor.clear,
                "line \(line) carries a per-line wash; the slab belongs to the layout manager"
            )
        }
        XCTAssertEqual(foreground(ofLine: 0), NSColor.tertiaryLabelColor)
        XCTAssertEqual(foreground(ofLine: 2), NSColor.tertiaryLabelColor)
        XCTAssertEqual(
            coordinator.fenceRegions,
            [NSRange(location: 0, length: (storage.string as NSString).length)]
        )
    }

    /// Closing the fence hands the lines below it back to prose, wash
    /// and all: the restyle pass lays every line down as plain ink
    /// before it decides what the line is, and the region — the range
    /// the layout manager washes — closes at the answering rule instead
    /// of running to the end of the page.
    func testClosingAFenceReleasesTheLinesBelowIt() {
        makeEditor()
        paste(
            """
            ```
            # comment
            """
        )
        // An open fence washes to the last line of the page.
        XCTAssertEqual(coordinator.fenceRegions, [NSRange(location: 0, length: 13)])

        textView.setSelectedRange(NSRange(location: (storage.string as NSString).length, length: 0))
        textView.insertText(
            "\n```\n# a heading",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        coordinator.restyle()

        XCTAssertEqual(font(ofLine: 3), InkStyle.headingFont(level: 1))
        // The region now ends with the answering rule's own line; the
        // heading below it is outside the wash.
        XCTAssertEqual(coordinator.fenceRegions, [NSRange(location: 0, length: 18)])
    }
}

/// The slab's geometry, tested as arithmetic (the shell's pattern for
/// UI-adjacent logic): given the metrics a layout pass would hand over,
/// the rectangle must span the region top to bottom at full container
/// width, offset by the container's origin, and decline to paint
/// nothing.
final class CodeSlabTests: XCTestCase {
    func testTheSlabSpansTheRegionAtFullContainerWidth() {
        let slab = InkLayoutManager.slabRect(
            firstLineTop: 40, regionBottom: 100,
            containerWidth: 380, origin: NSPoint(x: 12, y: 12)
        )
        XCTAssertEqual(slab, NSRect(x: 12, y: 52, width: 380, height: 60))
    }

    /// The reserved label gap above a stamped fence lives in the first
    /// line's fragment rect, not its used rect, so the caller measures
    /// the top from the used rect; the arithmetic only has to keep the
    /// origin offset honest, not re-subtract the gap.
    func testTheSlabHonorsTheContainerOrigin() {
        let slab = InkLayoutManager.slabRect(
            firstLineTop: 0, regionBottom: 17,
            containerWidth: 200, origin: NSPoint(x: 20, y: 32)
        )
        XCTAssertEqual(slab, NSRect(x: 20, y: 32, width: 200, height: 17))
    }

    func testDegenerateMetricsPaintNothing() {
        XCTAssertNil(InkLayoutManager.slabRect(
            firstLineTop: 50, regionBottom: 50, containerWidth: 380, origin: .zero
        ))
        XCTAssertNil(InkLayoutManager.slabRect(
            firstLineTop: 60, regionBottom: 50, containerWidth: 380, origin: .zero
        ))
        XCTAssertNil(InkLayoutManager.slabRect(
            firstLineTop: 0, regionBottom: 50, containerWidth: 0, origin: .zero
        ))
    }
}

/// The fold from classified paragraphs to fence regions, tested on
/// ranges alone: the scanner has already said what every line is, so
/// the fold only has to pair rules and stretch the region between them.
@MainActor
final class FenceRegionFoldTests: XCTestCase {
    private typealias Paragraph = (range: NSRange, kind: InkStyle.LineKind)

    func testAClosedFenceIsOneRegionRuleToRule() {
        let paragraphs: [Paragraph] = [
            (NSRange(location: 0, length: 8), .heading(level: 1, markerLength: 2)),
            (NSRange(location: 8, length: 4), .fenceRule),
            (NSRange(location: 12, length: 10), .code),
            (NSRange(location: 22, length: 4), .fenceRule),
            (NSRange(location: 26, length: 5), .body),
        ]
        XCTAssertEqual(
            InkEditorView.Coordinator.fenceRegions(of: paragraphs),
            [NSRange(location: 8, length: 18)]
        )
    }

    func testAnOpenFenceRunsToTheLastParagraph() {
        let paragraphs: [Paragraph] = [
            (NSRange(location: 0, length: 4), .fenceRule),
            (NSRange(location: 4, length: 6), .code),
        ]
        XCTAssertEqual(
            InkEditorView.Coordinator.fenceRegions(of: paragraphs),
            [NSRange(location: 0, length: 10)]
        )
    }

    /// Two fences back to back are two slabs, not one: the rule that
    /// closes the first cannot also open the second.
    func testAdjacentFencesStaySeparateRegions() {
        let paragraphs: [Paragraph] = [
            (NSRange(location: 0, length: 4), .fenceRule),
            (NSRange(location: 4, length: 4), .fenceRule),
            (NSRange(location: 8, length: 4), .fenceRule),
            (NSRange(location: 12, length: 4), .fenceRule),
        ]
        XCTAssertEqual(
            InkEditorView.Coordinator.fenceRegions(of: paragraphs),
            [NSRange(location: 0, length: 8), NSRange(location: 8, length: 8)]
        )
    }

    func testAPageWithoutFencesHasNoRegions() {
        let paragraphs: [Paragraph] = [
            (NSRange(location: 0, length: 6), .body),
            (NSRange(location: 6, length: 8), .heading(level: 2, markerLength: 3)),
        ]
        XCTAssertEqual(InkEditorView.Coordinator.fenceRegions(of: paragraphs), [])
    }
}
