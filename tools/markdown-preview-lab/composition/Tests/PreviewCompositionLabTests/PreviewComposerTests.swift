import XCTest
@testable import PreviewCompositionLab

final class PreviewComposerTests: XCTestCase {
    private func compose(_ events: [PreviewEvent], dialect: PreviewDialect = .gfm) throws -> PreviewComposition {
        try PreviewComposer(dialect: dialect).compose(events)
    }

    private func html(_ source: String) -> PreviewEvent { .rawHTML([.text(source)]) }

    private func ink(_ result: PreviewComposition) -> String {
        result.runs.map { run in
            switch run {
            case .text(let text, _): return text
            case .object(let identity, _): return "[\(identity)]"
            case .image(let image, _):
                return image.fallback.map { part in
                    switch part {
                    case .text(let text): return text
                    case .object(let identity): return "[\(identity)]"
                    }
                }.joined()
            }
        }.joined()
    }

    private func traits(_ result: PreviewComposition, text: String) -> Set<PreviewCompositionLab.PreviewTrait>? {
        for run in result.runs {
            if case .text(let value, let style) = run, value == text { return style.traits }
        }
        return nil
    }

    private func images(_ result: PreviewComposition) -> [PreviewImage] {
        result.runs.compactMap { run in
            if case .image(let image, _) = run { return image }
            return nil
        }
    }

    func testEmptyComposition() throws {
        XCTAssertEqual(try compose([]), PreviewComposition(runs: [], diagnostics: []))
    }

    func testMixedHTMLAndMarkdownShareStylesInBothDialects() throws {
        for dialect in PreviewDialect.allCases {
            let result = try compose([
                .text("A "), html("<em>"), .text("one "), .enterMarkdown(.strong),
                .text("two"), .leaveMarkdown(.strong), html("</em>"), .text(" end"),
            ], dialect: dialect)
            XCTAssertEqual(ink(result), "A one two end")
            XCTAssertEqual(traits(result, text: "one "), [.emphasis])
            XCTAssertEqual(traits(result, text: "two"), [.emphasis, .strong])
            XCTAssertEqual(traits(result, text: " end"), [])
        }
    }

    func testHTMLScopeSurvivesParserBlockBoundaries() throws {
        let result = try compose([
            html("<del>"), .blockBoundary, .enterMarkdown(.emphasis), .text("x"),
            .leaveMarkdown(.emphasis), .blockBoundary, html("</del>"), .text("outside"),
        ])
        XCTAssertEqual(ink(result), "x\noutside")
        XCTAssertEqual(traits(result, text: "x"), [.deletion, .emphasis])
        XCTAssertEqual(traits(result, text: "outside"), [])
    }

    func testHTMLBlockTextIsNotReparsedAsMarkdown() throws {
        let result = try compose([html("<del>\n*x*\n</del>")])
        XCTAssertEqual(ink(result), "\n*x*\n")
        XCTAssertEqual(traits(result, text: "\n*x*\n"), [.deletion])
    }

    func testDecodedMarkdownTextNeverBecomesMarkup() throws {
        let result = try compose([.text("<em>literal</em> &lt;strong&gt;")])
        XCTAssertEqual(ink(result), "<em>literal</em> &lt;strong&gt;")
        XCTAssertEqual(traits(result, text: ink(result)), [])
    }

    func testRawHTMLTextDecodesExactlyOnceAndDoesNotBecomeTags() throws {
        let result = try compose([html("&lt;em&gt;literal&lt;/em&gt; &amp;lt;b&amp;gt;")])
        XCTAssertEqual(ink(result), "<em>literal</em> &lt;b&gt;")
        XCTAssertEqual(traits(result, text: ink(result)), [])
    }

    func testMalformedMarkupIsLiteralWithoutEntityDecoding() throws {
        let result = try compose([html("<em title='&amp; unfinished")])
        XCTAssertEqual(ink(result), "<em title='&amp; unfinished")
        XCTAssertEqual(result.diagnostics, [])
    }

    func testSupportedFormattingSubset() throws {
        let cases: [(String, PreviewCompositionLab.PreviewTrait)] = [
            ("em", .emphasis), ("i", .emphasis), ("strong", .strong), ("b", .strong),
            ("del", .deletion), ("s", .deletion), ("strike", .deletion), ("code", .code),
        ]
        for (tag, trait) in cases {
            let result = try compose([html("<\(tag)>x</\(tag)>outside")])
            XCTAssertEqual(ink(result), "xoutside", tag)
            XCTAssertEqual(traits(result, text: "x"), [trait], tag)
            XCTAssertEqual(traits(result, text: "outside"), [], tag)
        }
    }

    func testNestedSameTraitDoesNotClearOuterTrait() throws {
        let result = try compose([html("<em>outer<em>inner</em>still</em>plain")])
        XCTAssertEqual(traits(result, text: "still"), [.emphasis])
        XCTAssertEqual(traits(result, text: "plain"), [])
    }

    func testMarkdownAndHTMLStacksAreIndependent() throws {
        let result = try compose([
            .enterMarkdown(.strong), html("<strong>x</strong>"), .text("y"),
            .leaveMarkdown(.strong), .text("z"),
        ])
        XCTAssertEqual(traits(result, text: "y"), [.strong])
        XCTAssertEqual(traits(result, text: "z"), [])
    }

    func testMalformedNestingClosesThroughNearestMatchingElement() throws {
        let result = try compose([html("<em><strong>x</em>y</strong>")])
        XCTAssertEqual(ink(result), "xy</strong>")
        XCTAssertEqual(traits(result, text: "x"), [.emphasis, .strong])
        XCTAssertEqual(traits(result, text: "y"), [])
        XCTAssertEqual(result.diagnostics, [.recoveredNesting("em"), .unmatchedClosingTag("strong")])
    }

    func testUnclosedAllowedHTMLStyleEndsWithComposition() throws {
        let composer = PreviewComposer(dialect: .gfm)
        XCTAssertEqual(traits(try composer.compose([html("<em>x")]), text: "x"), [.emphasis])
        XCTAssertEqual(traits(try composer.compose([.text("y")]), text: "y"), [])
    }

    func testSelfClosingNonVoidElementIsEmptyInThisPrototype() throws {
        let result = try compose([html("<em />x")])
        XCTAssertEqual(ink(result), "x")
        XCTAssertEqual(traits(result, text: "x"), [])
    }

    func testBlockSeparatorsAndExplicitBreak() throws {
        let result = try compose([
            html("<p>one</p><div>two<br>three</div>"), .blockBoundary, .blockBoundary, .text("four"),
        ])
        XCTAssertEqual(ink(result), "one\ntwo\nthree\nfour")
    }

    func testRawWhitespaceIsPreservedRatherThanBrowserCollapsed() throws {
        XCTAssertEqual(ink(try compose([html("<span>a  b\n c</span>")])), "a  b\n c")
    }

    func testGFMFilterPrecedesElementPolicyForAllNineNames() throws {
        for tag in ["title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "script", "plaintext"] {
            let source = "<\(tag.uppercased())>body</\(tag)>"
            let gfm = try compose([html(source)], dialect: .gfm)
            XCTAssertEqual(ink(gfm), source, tag)
            XCTAssertEqual(gfm.diagnostics, [.gfmFiltered(tag), .gfmFiltered(tag)], tag)
            let commonMark = try compose([html(source)], dialect: .commonMark)
            XCTAssertEqual(ink(commonMark), source, tag)
            XCTAssertEqual(commonMark.diagnostics, tag == "plaintext"
                            ? [.escapedElement(tag)] : [.escapedElement(tag), .escapedElement(tag)], tag)
        }
    }

    func testGFMFilteredTokenDecodesEntitiesWithoutRetokenizing() throws {
        let result = try compose([html("<script title='&amp; &lt;em&gt;'>x</script>")])
        XCTAssertEqual(ink(result), "<script title='& <em>'>x</script>")
        XCTAssertEqual(traits(result, text: "<script title='& <em>'>"), [])
        XCTAssertEqual(result.diagnostics, [.gfmFiltered("script"), .gfmFiltered("script")])
    }

    func testCommonMarkRawTextDoesNotProduceImagesOrLinkScopes() throws {
        for tag in ["script", "style", "xmp", "iframe", "noembed", "noframes", "title", "textarea", "plaintext"] {
            let source = "<\(tag)>const x = \"<img src='https://example.invalid/x'><a href='https://example.invalid/y'>\";</\(tag)>"
            let result = try compose([html(source), .text("outside")], dialect: .commonMark)
            XCTAssertEqual(ink(result), source + "outside", tag)
            XCTAssertTrue(images(result).isEmpty, tag)
            XCTAssertEqual(result.runs.last, .text("outside", PreviewStyle()), tag)
        }
    }

    func testRawTextClosesAtHTMLClosingTagRegardlessOfScriptQuotes() throws {
        let source = "<script>const x = \"<unclosed</script><em>outside</em>"
        let result = try compose([html(source)], dialect: .commonMark)
        XCTAssertEqual(ink(result), "<script>const x = \"<unclosed</script>outside")
        XCTAssertEqual(traits(result, text: "outside"), [.emphasis])
    }

    func testCommonMarkRawTextScopeAndObjectOrderAcrossHTMLLeaves() throws {
        let result = try compose([
            html("<script>prefix"),
            .rawHTML([.text("<img src='"), .object("body"), .text("'>&amp;")]),
            html("</SCRIPT><strong>outside</strong>"),
        ], dialect: .commonMark)
        XCTAssertEqual(ink(result), "<script>prefix<img src='[body]'>&amp;</SCRIPT>outside")
        XCTAssertEqual(result.objectOrder, ["body"])
        XCTAssertTrue(images(result).isEmpty)
        XCTAssertEqual(traits(result, text: "outside"), [.strong])
    }

    func testRCDATAAndRawTextHaveDifferentEntityDecoding() throws {
        for tag in ["title", "textarea", "script", "style"] {
            let result = try compose([html("<\(tag)>&lt;img src='x'&gt;&amp;</\(tag)>")], dialect: .commonMark)
            let body = tag == "title" || tag == "textarea" ? "<img src='x'>&" : "&lt;img src='x'&gt;&amp;"
            XCTAssertEqual(ink(result), "<\(tag)>\(body)</\(tag)>")
            XCTAssertTrue(images(result).isEmpty)
        }
    }

    func testGFMFilterPreventsRawTextScopeFromConsumingNestedHTML() throws {
        let result = try compose([html("<script><em>body</em></script>")])
        XCTAssertEqual(ink(result), "<script>body</script>")
        XCTAssertEqual(traits(result, text: "body"), [.emphasis])
    }

    func testStructuredParserEventsInsideRawTextAreRejected() {
        for event: PreviewEvent in [
            .enterMarkdown(.strong), .leaveMarkdown(.strong),
            .markdownImage(alt: [], destination: [.text("/image")]),
        ] {
            XCTAssertThrowsError(try compose([html("<script>"), event], dialect: .commonMark)) {
                XCTAssertEqual($0 as? CompositionError, .structuredEventInRawText)
            }
        }
    }

    func testFilterOnlyRecognizesExactTagNames() throws {
        let result = try compose([html("<scripture>x</scripture>")])
        XCTAssertEqual(result.diagnostics, [.escapedElement("scripture"), .escapedElement("scripture")])
    }

    func testUnsupportedResourceElementsRemainLiteral() throws {
        let source = "<video poster='https://example.invalid/a'><source src='b'></video>"
        let result = try compose([html(source)])
        XCTAssertEqual(ink(result), source)
        XCTAssertTrue(images(result).isEmpty)
    }

    func testCommentsRemoveCommentTextButPreserveObjectReferencesInOrder() throws {
        let result = try compose([
            .text("before"), .rawHTML([.text("<!-- hidden "), .object("one"), .text(" "),
                                      .object("two"), .text(" -->")]), .text("after"),
        ])
        XCTAssertEqual(ink(result), "before[one][two]after")
        XCTAssertEqual(result.objectOrder, ["one", "two"])
    }

    func testObjectsSurviveUnsupportedTagsAndMalformedNames() throws {
        let result = try compose([
            .rawHTML([.text("<unknown data-x='"), .object("one"), .text("'>")]),
            .rawHTML([.text("<em"), .object("two"), .text(">")]),
            .object("three"),
        ])
        XCTAssertEqual(ink(result), "<unknown data-x='[one]'><em[two]>[three]")
        XCTAssertEqual(result.objectOrder, ["one", "two", "three"])
    }

    func testObjectsInIgnoredAttributesAreRecoveredAtOpeningTag() throws {
        let result = try compose([
            .rawHTML([.text("<em style='url("), .object("css"), .text(")' title='"),
                      .object("title"), .text("'>")]), .text("body"), html("</em>"),
        ])
        XCTAssertEqual(ink(result), "[css][title]body")
        XCTAssertEqual(result.objectOrder, ["css", "title"])
        XCTAssertEqual(traits(result, text: "body"), [.emphasis])
        XCTAssertTrue(images(result).isEmpty)
    }

    func testHTMLImageProducesOnlyInertDescriptorWithDecodedAlt() throws {
        let result = try compose([html("<img src='https://example.invalid/a?x=1&amp;y=2' alt='A &amp; B' onload='run()'>")])
        XCTAssertEqual(images(result), [PreviewImage(
            destination: .unreviewed("https://example.invalid/a?x=1&y=2"), fallback: [.text("A & B")]
        )])
        XCTAssertEqual(ink(result), "A & B")
    }

    func testMarkdownImageAltIsAlreadyDecoded() throws {
        let result = try compose([.markdownImage(alt: [.text("&amp; <em>literal</em>")], destination: [.text("/relative")])])
        XCTAssertEqual(ink(result), "&amp; <em>literal</em>")
        XCTAssertEqual(images(result).first?.destination, .unreviewed("/relative"))
    }

    func testImageDescriptorDoesNotSelectRequestSchemesOrCredentialsPolicy() throws {
        for address in ["http://localhost/x", "https://user:password@example.invalid/x", "file:///tmp/x", "data:image/png,x", "javascript:example", "../relative"] {
            let result = try compose([.markdownImage(alt: [], destination: [.text(address)])])
            XCTAssertEqual(images(result).first?.destination, .unreviewed(address))
        }
    }

    func testMissingAndEmptyDestinations() throws {
        let result = try compose([
            html("<img alt='one'><img src='' alt='two'>"),
            .markdownImage(alt: [.text("three")], destination: nil),
        ])
        XCTAssertEqual(images(result).map(\.destination), Array(repeating: .refused(.missing), count: 3))
        XCTAssertEqual(ink(result), "onetwothree")
    }

    func testHTMLImageObjectOrderIncludesEveryAttributeNotJustAlt() throws {
        for dialect in PreviewDialect.allCases {
            let result = try compose([
                .object("before"),
                .rawHTML([.text("<img src='https://example.invalid/"), .object("destination"),
                          .text("' alt='left "), .object("alt"), .text(" right' title='"),
                          .object("metadata"), .text("' srcset='"), .object("srcset"), .text("'>")]),
                .object("after"),
            ], dialect: dialect)
            XCTAssertEqual(result.objectOrder, ["before", "destination", "alt", "metadata", "srcset", "after"])
            XCTAssertEqual(ink(result), "[before][destination]left [alt] right[metadata][srcset][after]")
            XCTAssertEqual(images(result).first?.destination, .refused(.sealedObject))
        }
    }

    func testMarkdownImageDestinationObjectIsRefusedAndRecoveredAfterAlt() throws {
        let result = try compose([.markdownImage(
            alt: [.text("a"), .object("alt"), .text("b")],
            destination: [.text("https://example.invalid/"), .object("destination")]
        )])
        XCTAssertEqual(ink(result), "a[alt]b[destination]")
        XCTAssertEqual(result.objectOrder, ["alt", "destination"])
        XCTAssertEqual(images(result).first?.destination, .refused(.sealedObject))
    }

    func testDuplicateAttributesUseFirstValueButPreserveLaterObjects() throws {
        let result = try compose([
            .rawHTML([.text("<img alt='first' ALT='"), .object("duplicate-alt"),
                      .text("' src='https://example.invalid/' SRC='"), .object("duplicate-src"), .text("'>")]),
        ])
        XCTAssertEqual(ink(result), "first[duplicate-alt][duplicate-src]")
        XCTAssertEqual(images(result).first?.destination, .refused(.sealedObject))
    }

    func testReservedPlaceholderAddressesAreRefusedAfterHTMLDecoding() throws {
        for source in ["OTSAttachment123Z", "&#79;TSAttachment123Z", "&#xFFFC;"] {
            let result = try compose([html("<img src='https://example.invalid/\(source)' alt='a'>")])
            XCTAssertEqual(images(result).first?.destination, .refused(.sealedObject), source)
        }
        let result = try compose([.markdownImage(alt: [], destination: [.text("https://example.invalid/OTSAttachment1Z")])])
        XCTAssertEqual(images(result).first?.destination, .refused(.sealedObject))
    }

    func testReservedPlaceholdersInDuplicateDestinationsAreRefused() throws {
        for tag in ["img src", "a href"] {
            let pieces = tag.split(separator: " ")
            let result = try compose([
                html("<\(pieces[0]) \(pieces[1])='https://example.invalid/' \(pieces[1])='&#79;TSAttachment1Z'>"),
                .text("label"),
            ])
            if pieces[0] == "img" {
                XCTAssertEqual(images(result).first?.destination, .refused(.sealedObject))
            } else {
                XCTAssertEqual(result.runs.last, .text("label", PreviewStyle(link: .refused(.sealedObject))))
            }
        }
    }

    func testLinkedImageHasSeparateImageAndLinkAddresses() throws {
        let result = try compose([html("<a href='https://example.invalid/open'><img src='https://example.invalid/image' alt='alt'></a>")])
        guard case .image(let image, let style) = result.runs.first else { return XCTFail("Expected image") }
        XCTAssertEqual(image.destination, .unreviewed("https://example.invalid/image"))
        XCTAssertEqual(style.link, .unreviewed("https://example.invalid/open"))
    }

    func testObjectInLinkDestinationRefusesAddressWithoutLosingReference() throws {
        let result = try compose([
            .rawHTML([.text("<a href='https://example.invalid/"), .object("link"), .text("'>")]),
            .text("label"), html("</a>"),
        ])
        XCTAssertEqual(ink(result), "[link]label")
        XCTAssertEqual(result.objectOrder, ["link"])
        XCTAssertEqual(result.runs.last, .text("label", PreviewStyle(link: .refused(.sealedObject))))
    }

    func testDuplicateObjectIdentityRejectsWholeComposition() {
        XCTAssertThrowsError(try compose([.object("one"), .rawHTML([.text("<!--"), .object("one"), .text("-->")])])) {
            XCTAssertEqual($0 as? CompositionError, .duplicateObject("one"))
        }
    }

    func testEmptyIdentityRejectsWholeComposition() {
        XCTAssertThrowsError(try compose([.object("")])) {
            XCTAssertEqual($0 as? CompositionError, .emptyObjectIdentity)
        }
    }

    func testUnbalancedMarkdownRejectsWholeComposition() {
        for events: [PreviewEvent] in [
            [.leaveMarkdown(.strong)], [.enterMarkdown(.strong)],
            [.enterMarkdown(.strong), .leaveMarkdown(.emphasis)],
        ] {
            XCTAssertThrowsError(try compose(events)) {
                XCTAssertEqual($0 as? CompositionError, .unbalancedMarkdown)
            }
        }
    }

    func testInputLimitIsDocumentWideIncludingImageMetadata() {
        var composer = PreviewComposer(dialect: .gfm)
        composer.limits.maximumInputScalars = 5
        XCTAssertNoThrow(try composer.compose([.text("ab"), .text("cde")]))
        XCTAssertThrowsError(try composer.compose([.text("abc"), .text("def")])) {
            XCTAssertEqual($0 as? CompositionError, .inputLimit)
        }
        XCTAssertThrowsError(try composer.compose([.markdownImage(alt: [.text("abc")], destination: [.text("def")])])) {
            XCTAssertEqual($0 as? CompositionError, .inputLimit)
        }
    }

    func testEmptyTextFragmentsConsumeDocumentBudget() {
        var composer = PreviewComposer(dialect: .gfm)
        composer.limits.maximumInputScalars = 2
        XCTAssertNoThrow(try composer.compose([.rawHTML([.text(""), .text("")])]))
        XCTAssertThrowsError(try composer.compose([.rawHTML([.text(""), .text(""), .text("")])])) {
            XCTAssertEqual($0 as? CompositionError, .inputLimit)
        }
    }

    func testEventAndOutputLimits() {
        var composer = PreviewComposer(dialect: .gfm)
        composer.limits.maximumEvents = 1
        XCTAssertThrowsError(try composer.compose([.text("a"), .text("b")])) {
            XCTAssertEqual($0 as? CompositionError, .eventLimit)
        }
        composer.limits.maximumEvents = 100
        composer.limits.maximumOutputRuns = 1
        XCTAssertThrowsError(try composer.compose([.text("a"), .object("b")])) {
            XCTAssertEqual($0 as? CompositionError, .outputLimit)
        }
    }

    func testTokenLimitIsDocumentWideNotResetForEachHTMLLeaf() {
        var composer = PreviewComposer(dialect: .gfm)
        composer.limits.maximumTokens = 2
        XCTAssertNoThrow(try composer.compose([html("<em>"), html("</em>")]))
        XCTAssertThrowsError(try composer.compose([html("<em>"), html("x"), html("</em>")])) {
            XCTAssertEqual($0 as? HTMLTokenizationError, .tokenLimit)
        }
    }

    func testDepthLimitCombinesMarkdownAndHTMLStacks() {
        var composer = PreviewComposer(dialect: .gfm)
        composer.limits.maximumDepth = 2
        XCTAssertNoThrow(try composer.compose([html("<em><strong>x</strong></em>")]))
        XCTAssertThrowsError(try composer.compose([
            .enterMarkdown(.code), html("<em><strong>x</strong></em>"), .leaveMarkdown(.code),
        ])) {
            XCTAssertEqual($0 as? CompositionError, .depthLimit)
        }
    }

    func testDeterministicObjectOrderAcrossMixedContexts() throws {
        for dialect in PreviewDialect.allCases {
            for count in 1...64 {
                var events: [PreviewEvent] = []
                for index in 0..<count {
                    let id = String(index)
                    switch index % 5 {
                    case 0: events.append(.object(id))
                    case 1: events.append(.rawHTML([.text("<!--"), .object(id), .text("-->")]))
                    case 2: events.append(.rawHTML([.text("<span title='"), .object(id), .text("'></span>")]))
                    case 3: events.append(.markdownImage(alt: [.object(id)], destination: [.text("/image")]))
                    default: events.append(.rawHTML([.text("<unknown x='"), .object(id), .text("'>")]))
                    }
                }
                XCTAssertEqual(try compose(events, dialect: dialect).objectOrder, (0..<count).map(String.init))
            }
        }
    }
}
