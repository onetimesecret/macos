import XCTest

@testable import CompanionKit

final class HTMLTokenizerTests: XCTestCase {
    func testEmptyInputAndEmptyTextParts() throws {
        XCTAssertEqual(try HTMLTokenizer().tokenize([]), [])
        XCTAssertEqual(try HTMLTokenizer().tokenize([.text(""), .text("")]), [])
    }

    func testTextCoalescesWithoutDecodingOrNormalizingScalars() throws {
        let input: [HTMLPart] = [.text("e\u{301}&am"), .text("p;\r\n"), .text("💠")]
        let tokens = try HTMLTokenizer().tokenize(input)
        XCTAssertEqual(tokens, [.text([.text("e\u{301}&amp;\r\n💠")])])
        assertSource(tokens, equals: input)
    }

    func testWholeLeafContainsMultipleTagsTextAndComments() throws {
        let input = "before<B ID=one disabled>raw&amp;<!--note--></B>after"
        XCTAssertEqual(try HTMLTokenizer().tokenize([.text(input)]), [
            .text([.text("before")]),
            tag("b", raw: [.text("<B ID=one disabled>")], attributes: [
                attribute("id", [.text("one")]), attribute("disabled"),
            ]),
            .text([.text("raw&amp;")]),
            .comment([.text("<!--note-->")]),
            tag("b", raw: [.text("</B>")], closing: true),
            .text([.text("after")]),
        ])
    }

    func testQuotedGreaterThanAndOppositeQuoteCharacters() throws {
        let raw = #"<A X="a>b'c" Y='d>e"f' Z=bare />"#
        XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [
            tag("a", raw: [.text(raw)], attributes: [
                attribute("x", [.text("a>b'c")]),
                attribute("y", [.text("d>e\"f")]),
                attribute("z", [.text("bare")]),
            ], selfClosing: true),
        ])
    }

    func testStrayLessThanBeforeAQuoteDoesNotAbsorbClosingOrFollowingTags() throws {
        for quote in ["'", "\""] {
            let comparison = " b\(quote)s c > d"
            let input: [HTMLPart] = [.text("<div>a <" + comparison + "</div>")]
            let tokens = try HTMLTokenizer().tokenize(input)
            XCTAssertEqual(tokens, [
                tag("div", raw: [.text("<div>")]), .text([.text("a ")]),
                .literal([.text("<")]), .text([.text(comparison)]),
                tag("div", raw: [.text("</div>")], closing: true),
            ], quote)
            assertSource(tokens, equals: input)

            let beforeBold = " b\(quote)s "
            let nested: [HTMLPart] = [.text("<div>a <" + beforeBold + "<b>bold</b></div>")]
            let nestedTokens = try HTMLTokenizer().tokenize(nested)
            XCTAssertEqual(nestedTokens, [
                tag("div", raw: [.text("<div>")]), .text([.text("a ")]),
                .literal([.text("<")]), .text([.text(beforeBold)]),
                tag("b", raw: [.text("<b>")]), .text([.text("bold")]),
                tag("b", raw: [.text("</b>")], closing: true),
                tag("div", raw: [.text("</div>")], closing: true),
            ], quote)
            assertSource(nestedTokens, equals: nested)

            let invalidClosing: [HTMLPart] = [.text("</" + beforeBold + "<b>bold</b>")]
            let closingTokens = try HTMLTokenizer().tokenize(invalidClosing)
            XCTAssertEqual(closingTokens, [
                .literal([.text("<")]), .text([.text("/" + beforeBold)]),
                tag("b", raw: [.text("<b>")]), .text([.text("bold")]),
                tag("b", raw: [.text("</b>")], closing: true),
            ], quote)
            assertSource(closingTokens, equals: invalidClosing)
        }
    }

    func testBooleanAndEmptyAttributesRemainDistinct() throws {
        let raw = #"<input disabled empty="" other='' checked = yes foo bar>"#
        XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [
            tag("input", raw: [.text(raw)], attributes: [
                attribute("disabled"), attribute("empty", []), attribute("other", []),
                attribute("checked", [.text("yes")]), attribute("foo"), attribute("bar"),
            ]),
        ])
    }

    func testDuplicateAttributesKeepTheirOriginalOrder() throws {
        let raw = #"<a X=first x="second" X>"#
        XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [
            tag("a", raw: [.text(raw)], attributes: [
                attribute("x", [.text("first")]), attribute("x", [.text("second")]), attribute("x"),
            ]),
        ])
    }

    func testASCIINamesFoldWithoutChangingRawSourceOrValues() throws {
        let raw = "<X-Y:z_2 DATA-X.y:_9=MiXeD _A:B=V>"
        XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [
            tag("x-y:z_2", raw: [.text(raw)], attributes: [
                attribute("data-x.y:_9", [.text("MiXeD")]), attribute("_a:b", [.text("V")]),
            ]),
        ])
    }

    func testNonASCIINamesStayLiteralWithoutNarrowingToASCII() throws {
        for scalar in ["é", "\u{141}", "\u{10041}", "\u{10FFFF}"] {
            let invalidOpening: [HTMLPart] = [.text("<\(scalar)>")]
            let openingTokens = try HTMLTokenizer().tokenize(invalidOpening)
            XCTAssertEqual(openingTokens, [.literal([.text("<")]), .text([.text("\(scalar)>")])])
            assertSource(openingTokens, equals: invalidOpening)
            for raw in ["<A\(scalar)>", "</A\(scalar)>", "<a \(scalar)=x>"] {
                let input: [HTMLPart] = [.text(raw)]
                let tokens = try HTMLTokenizer().tokenize(input)
                XCTAssertEqual(tokens, [.literal(input)])
                assertSource(tokens, equals: input)
            }
        }
    }

    func testHTMLWhitespaceAndClosingTags() throws {
        let opening = "<A\tX\r=\n'v'\u{0C}disabled >"
        let closing = "</A\t\r\n\u{0C} >"
        XCTAssertEqual(try HTMLTokenizer().tokenize([.text(opening + closing)]), [
            tag("a", raw: [.text(opening)], attributes: [attribute("x", [.text("v")]), attribute("disabled")]),
            tag("a", raw: [.text(closing)], closing: true),
        ])
        for whitespace in ["\u{0B}", "\u{00A0}"] {
            let raw = "<a" + whitespace + "x=1>"
            XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [.literal([.text(raw)])])
        }
    }

    func testSelfClosingTagsWithAndWithoutAttributes() throws {
        for raw in ["<br/>", "<br />"] {
            XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [
                tag("br", raw: [.text(raw)], selfClosing: true),
            ])
        }
        let raw = #"<br x="v"/>"#
        XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [
            tag("br", raw: [.text(raw)], attributes: [attribute("x", [.text("v")])], selfClosing: true),
        ])
    }

    func testSlashBelongsToUnquotedValueUnlessSeparatedByWhitespace() throws {
        for (raw, value, selfClosing) in [
            ("<a x=y/>", "y/", false),
            ("<a x=/>", "/", false),
            ("<a x=y/ >", "y/", false),
            ("<a x=y />", "y", true),
            ("<a x=https://example.invalid/path/>", "https://example.invalid/path/", false),
        ] {
            XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [
                tag("a", raw: [.text(raw)], attributes: [attribute("x", [.text(value)])], selfClosing: selfClosing),
            ], raw)
        }
    }

    func testObjectsInQuotedAndUnquotedAttributeValuesKeepExactOrder() throws {
        let input: [HTMLPart] = [
            .text("<a x=\"pre"), .object("first\" > &"), .object("second"),
            .text("post\" y="), .object("third'>'"), .text("tail >"),
        ]
        let tokens = try HTMLTokenizer().tokenize(input)
        XCTAssertEqual(tokens, [tag("a", raw: input, attributes: [
            attribute("x", [.text("pre"), .object("first\" > &"), .object("second"), .text("post")]),
            attribute("y", [.object("third'>'"), .text("tail")]),
        ])])
        assertSource(tokens, equals: input)
        assertObjectOrder(tokens, equals: ["first\" > &", "second", "third'>'"])
    }

    func testObjectsOutsideMarkupAreOpaqueTextAtoms() throws {
        let input: [HTMLPart] = [.object("<b>"), .object(""), .text("x"), .object("&amp;")]
        let tokens = try HTMLTokenizer().tokenize(input)
        XCTAssertEqual(tokens, [.text(input)])
        assertObjectOrder(tokens, equals: ["<b>", "", "&amp;"])
    }

    func testObjectsCannotSupplyAnyPartOfTagNames() throws {
        let invalidOpening: [HTMLPart] = [.text("<"), .object("a"), .text(">")]
        let openingTokens = try HTMLTokenizer().tokenize(invalidOpening)
        XCTAssertEqual(openingTokens, [.literal([.text("<")]), .text([.object("a"), .text(">")])])
        assertSource(openingTokens, equals: invalidOpening)
        let inputs: [[HTMLPart]] = [
            [.text("<a"), .object("suffix"), .text(">")],
            [.text("</a"), .object("suffix"), .text(">")],
            [.text("</a "), .object("trailing"), .text(">")],
            [.text("<a"), .object(""), .text(">")],
        ]
        for input in inputs {
            let tokens = try HTMLTokenizer().tokenize(input)
            XCTAssertEqual(tokens, [.literal(input)])
            assertSource(tokens, equals: input)
        }
    }

    func testObjectsCannotSupplyAnyPartOfAttributeNames() throws {
        let inputs: [[HTMLPart]] = [
            [.text("<a "), .object("name"), .text("=x>")],
            [.text("<a na"), .object("middle"), .text("me=x>")],
            [.text("<a name"), .object(""), .text("=x>")],
        ]
        for input in inputs {
            let tokens = try HTMLTokenizer().tokenize(input)
            XCTAssertEqual(tokens, [.literal(input)])
            assertSource(tokens, equals: input)
        }
    }

    func testCommentsRetainDelimitersAndOpaqueObjects() throws {
        let input: [HTMLPart] = [
            .text("<!--a"), .object("-->"), .text("b"), .object("<!--"), .text("-->") ,
        ]
        let tokens = try HTMLTokenizer().tokenize(input)
        XCTAssertEqual(tokens, [.comment(input)])
        assertSource(tokens, equals: input)
        assertObjectOrder(tokens, equals: ["-->", "<!--"])
        for raw in ["<!---->", "<!--a>b-->", "<!--a--b-->", "<!--<!-->"] {
            XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [.comment([.text(raw)])])
        }
    }

    func testMalformedCommentsBecomeLiterals() throws {
        for raw in [
            "<!--", "<!--x>y", "<!-->", "<!--->", "<!-->x-->",
            "<!--->x-->", "<!--x<!--y-->", "<!--x--!>y-->", "<!--x<!--->",
        ] {
            XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [.literal([.text(raw)])], raw)
        }
        let input: [HTMLPart] = [.text("<!--bad"), .object("first"), .text("tail"), .object("second")]
        let tokens = try HTMLTokenizer().tokenize(input)
        XCTAssertEqual(tokens, [.literal(input)])
        assertObjectOrder(tokens, equals: ["first", "second"])
    }

    func testDeclarationsAndProcessingInstructionsRemainLiteral() throws {
        for raw in ["<!DOCTYPE html>", "<!unknown a='>'>", "<?instruction x=\"v>z\"?>"] {
            XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [.literal([.text(raw)])])
        }
        let input: [HTMLPart] = [.text("<!DOCTYPE "), .object("opaque"), .text(">")]
        XCTAssertEqual(try HTMLTokenizer().tokenize(input), [.literal(input)])
    }

    func testUnsupportedTagSyntaxRemainsLiteral() throws {
        for raw in [
            "<a ä=x>", "<a.b>", "<a / >", "</a/>", "</a x>",
            "<a x=>", "<a x=one=two>", "<a x=one<two>", "<a x=`bad`>", "<a x=\"v\"y=two>",
        ] {
            XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [.literal([.text(raw)])], raw)
        }
    }

    func testInvalidMarkupPrefixesEmitOnlyTheLessThanAsLiteral() throws {
        for raw in ["< a>", "<1a>", "<ä>", "</", "</ >", "</1a>", "<\"quoted >", "<'quoted >"] {
            let input: [HTMLPart] = [.text(raw)]
            let tokens = try HTMLTokenizer().tokenize(input)
            XCTAssertEqual(tokens, [.literal([.text("<")]), .text([.text(String(raw.dropFirst()))])], raw)
            assertSource(tokens, equals: input)
        }
    }

    func testObjectsAndEntitiesAfterStrayLessThanStayInSourceOrderBeforeATag() throws {
        let input: [HTMLPart] = [
            .text("<"), .object("first\"'<>"), .text(" b's &amp; "), .object("second"), .text("<b>bold</b>"),
        ]
        let tokens = try HTMLTokenizer().tokenize(input)
        XCTAssertEqual(tokens, [
            .literal([.text("<")]),
            .text([.object("first\"'<>"), .text(" b's &amp; "), .object("second")]),
            tag("b", raw: [.text("<b>")]), .text([.text("bold")]),
            tag("b", raw: [.text("</b>")], closing: true),
        ])
        assertSource(tokens, equals: input)
        assertObjectOrder(tokens, equals: ["first\"'<>", "second"])
    }

    func testEOFInsideMarkupKeepsTheEntireRemainderLiteral() throws {
        for raw in ["<", "<a", "<a ", "<a x=", "<a x='v>tail<b>", "<a x=\"v>tail<b>"] {
            let input: [HTMLPart] = [.text("before" + raw)]
            let tokens = try HTMLTokenizer().tokenize(input)
            XCTAssertEqual(tokens, [.text([.text("before")]), .literal([.text(raw)])], raw)
            assertSource(tokens, equals: input)
        }
        let input: [HTMLPart] = [.text("<a x='"), .object("first"), .text("<b>"), .object("second")]
        let tokens = try HTMLTokenizer().tokenize(input)
        XCTAssertEqual(tokens, [.literal(input)])
        assertObjectOrder(tokens, equals: ["first", "second"])
    }

    func testTokenizerDoesNotDecodeEntitiesInAnyTokenKind() throws {
        let raw = #"&amp;<a x="&quot;"><!--&lt;--><!BAD &gt;>"#
        XCTAssertEqual(try HTMLTokenizer().tokenize([.text(raw)]), [
            .text([.text("&amp;")]),
            tag("a", raw: [.text(#"<a x="&quot;">"#)], attributes: [attribute("x", [.text("&quot;")])]),
            .comment([.text("<!--&lt;-->")]),
            .literal([.text("<!BAD &gt;>")]),
        ])
    }

    func testSourceReconstructsExactlyAcrossEveryTokenKind() throws {
        let input: [HTMLPart] = [
            .text("e\u{301}&am"), .text("p;\r\n"), .object("outer-e\u{301}"),
            .text("<B x=\"left"), .object("value-first"), .text("right\" y="),
            .object("value-second"), .text(" >middle"), .object("middle"),
            .text("<!--note"), .object("comment"), .text("--></B><!DOCTYPE html>"),
            .text("<bad na"), .object("malformed"), .text("me=x>tail"), .object("tail"),
        ]
        let tokens = try HTMLTokenizer().tokenize(input)
        XCTAssertEqual(tokens.map(kind), ["text", "tag", "text", "comment", "tag", "literal", "literal", "text"])
        assertSource(tokens, equals: input)
        assertObjectOrder(tokens, equals: [
            "outer-e\u{301}", "value-first", "value-second", "middle", "comment", "malformed", "tail",
        ])
    }

    func testTextPartSplitsDoNotChangeTokenization() throws {
        let samples = [
            #"before<A X="a>b" disabled>text&amp;<!--note--></A>"#,
            "e\u{301}<x y='👨‍👩‍👧‍👦'>", "<!-->bad--><b>", "<a x='unfinished><b>",
        ]
        for (sampleIndex, sample) in samples.enumerated() {
            let scalars = Array(sample.unicodeScalars)
            let expected = try HTMLTokenizer().tokenize([.text(sample)])
            for split in 0...scalars.count {
                let input: [HTMLPart] = [
                    .text(String(String.UnicodeScalarView(scalars[..<split]))),
                    .text(""),
                    .text(String(String.UnicodeScalarView(scalars[split...]))),
                ]
                XCTAssertEqual(try HTMLTokenizer().tokenize(input), expected, "sample \(sampleIndex), split \(split)")
            }
        }
    }

    func testObjectSplitsInterruptMarkupAndEntitySpellings() throws {
        let interruptedComment: [HTMLPart] = [.text("<!-"), .object("-"), .text("note-->")]
        XCTAssertEqual(try HTMLTokenizer().tokenize(interruptedComment), [.literal(interruptedComment)])
        let interruptedEnd: [HTMLPart] = [.text("<!--note--"), .object(">"), .text("tail")]
        XCTAssertEqual(try HTMLTokenizer().tokenize(interruptedEnd), [.literal(interruptedEnd)])
        let interruptedTag: [HTMLPart] = [.text("<a"), .object(">"), .text("tail")]
        XCTAssertEqual(try HTMLTokenizer().tokenize(interruptedTag), [.literal(interruptedTag)])
        let interruptedEntity: [HTMLPart] = [.text("&am"), .object("p"), .text(";")]
        XCTAssertEqual(try HTMLTokenizer().tokenize(interruptedEntity), [.text(interruptedEntity)])
        XCTAssertEqual(HTMLEntities.decode("&am"), "&am")
        XCTAssertEqual(HTMLEntities.decode(";"), ";")
        let betweenTags: [HTMLPart] = [.text("<b>"), .object("middle"), .text("</b>")]
        XCTAssertEqual(try HTMLTokenizer().tokenize(betweenTags), [
            tag("b", raw: [.text("<b>")]), .text([.object("middle")]),
            tag("b", raw: [.text("</b>")], closing: true),
        ])
        for input in [interruptedComment, interruptedEnd, interruptedTag, interruptedEntity, betweenTags] {
            assertSource(try HTMLTokenizer().tokenize(input), equals: input)
        }
    }

    func testInputLimitCountsUnicodeScalarsAtTheExactBoundary() throws {
        let input: [HTMLPart] = [.text("e\u{301}"), .object("opaque"), .text("💠")]
        let tokenizer = HTMLTokenizer(maximumInputScalars: 4)
        assertSource(try tokenizer.tokenize(input), equals: input)
        assertError(HTMLTokenizer(maximumInputScalars: 3), input, .inputLimit)
        assertError(tokenizer, input + [.text("x")], .inputLimit)
        assertError(tokenizer, input + [.object("")], .inputLimit)
        assertError(tokenizer, input + [.text("")], .inputLimit)
    }

    func testEmptyTextPartsEachConsumeOneInputBudgetUnit() throws {
        for budget in [0, 1, 8] {
            let tokenizer = HTMLTokenizer(maximumInputScalars: budget, maximumTokens: 0)
            let exact = Array(repeating: HTMLPart.text(""), count: budget)
            XCTAssertEqual(try tokenizer.tokenize(exact), [], "budget \(budget)")
            assertError(tokenizer, exact + [.text("")], .inputLimit)
        }
    }

    func testEmptyTextPartsShareTheInputBudgetWithScalarsAndObjects() throws {
        let input: [HTMLPart] = [.text(""), .text("e\u{301}"), .object(""), .text("")]
        let tokenizer = HTMLTokenizer(maximumInputScalars: 5)
        let tokens = try tokenizer.tokenize(input)
        XCTAssertEqual(tokens, [.text([.text("e\u{301}"), .object("")])])
        assertSource(tokens, equals: input)
        assertError(HTMLTokenizer(maximumInputScalars: 4), input, .inputLimit)
        assertError(tokenizer, input + [.text("")], .inputLimit)
    }

    func testObjectIdentityLengthDoesNotChangeItsInputCost() throws {
        let identity = String(repeating: "💠", count: 4096)
        let input: [HTMLPart] = [.object(identity)]
        let tokens = try HTMLTokenizer(maximumInputScalars: 1).tokenize(input)
        XCTAssertTrue(tokens == [.text(input)])
        assertSource(tokens, equals: input)
        assertError(HTMLTokenizer(maximumInputScalars: 0), input, .inputLimit)
        assertError(HTMLTokenizer(maximumInputScalars: 1), input + [.object("")], .inputLimit)
    }

    func testSparseObjectsAndHighUnicodeScalarsReconstructInEveryContext() throws {
        let high = "\u{0}\u{D7FF}\u{E000}\u{FFFC}\u{FFFF}\u{100000}\u{10FFFF}"
        let value: [HTMLPart] = [.text(high), .object(""), .text(high), .object(high)]
        let opening: [HTMLPart] = [.text("<A TITLE=\"")] + value + [.text("\">")]
        let body: [HTMLPart] = [.text(high), .object("repeat"), .text(high)]
        let comment: [HTMLPart] = [.text("<!--" + high), .object("repeat"), .text(high + "-->")]
        let closing: [HTMLPart] = [.text("</A>")]
        let input = opening + body + comment + closing
        let tokens = try HTMLTokenizer().tokenize(input)
        XCTAssertEqual(tokens, [
            tag("a", raw: coalesced(opening), attributes: [attribute("title", value)]),
            .text(body), .comment(comment), tag("a", raw: closing, closing: true),
        ])
        assertSource(tokens, equals: input)
        assertObjectOrder(tokens, equals: ["", high, "repeat", "repeat"])
    }

    func testLargeLeafAcceptsTheDefaultInputBoundaryWithSparseObjects() throws {
        let left = String(repeating: "x", count: 500_000)
        let right = String(repeating: "💠", count: 499_992)
        let high = "\u{0}\u{D7FF}\u{E000}\u{FFFC}\u{10FFFF}"
        let input: [HTMLPart] = [
            .text(left), .object(""), .text(high), .text(""), .object("<b>"), .text(right),
        ]
        let tokenizer = HTMLTokenizer()
        let tokens = try tokenizer.tokenize(input)
        XCTAssertTrue(tokens == [.text([
            .text(left), .object(""), .text(high), .object("<b>"), .text(right),
        ])])
        for extra in [HTMLPart.text("x"), .object("next"), .text("")] {
            assertError(tokenizer, input + [extra], .inputLimit)
        }
    }

    func testTokenizerAndComposerDefaultTokenBudgetsMatch() {
        XCTAssertEqual(HTMLTokenizer().maximumTokens, CompositionLimits().maximumTokens)
    }

    func testZeroAndNegativeLimitsHaveDeterministicEmptyBehavior() throws {
        for limit in [0, -1] {
            let tokenizer = HTMLTokenizer(maximumInputScalars: limit, maximumTokens: limit)
            XCTAssertEqual(try tokenizer.tokenize([]), [])
            assertError(tokenizer, [.text("")], .inputLimit)
            assertError(tokenizer, [.object("")], .inputLimit)
            assertError(HTMLTokenizer(maximumTokens: limit), [.text("x")], .tokenLimit)
        }
    }

    func testTokenLimitAcceptsBoundaryAndRejectsOneMoreToken() throws {
        let input: [HTMLPart] = [.text("x<a><!--note--><!bad>")]
        XCTAssertEqual(try HTMLTokenizer(maximumTokens: 4).tokenize(input).count, 4)
        assertError(HTMLTokenizer(maximumTokens: 3), input, .tokenLimit)
        XCTAssertEqual(try HTMLTokenizer(maximumTokens: 1).tokenize([.text("a"), .text("b")]), [.text([.text("ab")])])
        assertError(HTMLTokenizer(maximumTokens: 0), [.text("<a>")], .tokenLimit)
    }

    func testInputLimitIsCheckedBeforeTokenLimit() {
        assertError(HTMLTokenizer(maximumInputScalars: 1, maximumTokens: 0), [.text("xx")], .inputLimit)
        assertError(HTMLTokenizer(maximumInputScalars: 3, maximumTokens: 1), [.text("<a>tail")], .inputLimit)
    }

    func testTokenizerCanBeReusedAfterALimitError() throws {
        let tokenizer = HTMLTokenizer(maximumInputScalars: 20, maximumTokens: 2)
        assertError(tokenizer, [.text("a<b>c")], .tokenLimit)
        assertError(tokenizer, [.text(String(repeating: "x", count: 21))], .inputLimit)
        XCTAssertEqual(try tokenizer.tokenize([.text("<b>")]), [tag("b", raw: [.text("<b>")])])
    }

    func testBoundedRunsOfLessThanSignsDoNotRescanAsSeparateTokens() throws {
        let raw = String(repeating: "<", count: 32_768) + ">"
        let tokens = try HTMLTokenizer(maximumTokens: 1).tokenize([.text(raw)])
        XCTAssertEqual(tokens.count, 1)
        XCTAssertTrue(tokens == [.literal([.text(raw)])])
        assertSource(tokens, equals: [.text(raw)])
    }

    func testBoundedLessThanRunStopsBeforeARealTagAndSpendsTheTokenBudget() throws {
        let prefix = String(repeating: "<", count: 32_768)
        let input: [HTMLPart] = [.text(prefix + "<b>bold</b>")]
        let tokens = try HTMLTokenizer(maximumTokens: 4).tokenize(input)
        XCTAssertEqual(tokens, [
            .literal([.text(prefix)]), tag("b", raw: [.text("<b>")]), .text([.text("bold")]),
            tag("b", raw: [.text("</b>")], closing: true),
        ])
        assertSource(tokens, equals: input)
        assertError(HTMLTokenizer(maximumTokens: 3), input, .tokenLimit)
    }

    func testDeterministicBoundedRandomSourcePreservation() throws {
        var random = DeterministicRandom()
        let alphabet: [HTMLPart] = [
            "<", ">", "!", "-", "/", "\"", "'", "a", "A", " ", "\n", "=", "_", ":", ".",
            "0", "&", ";", "💠", "\u{301}", "\u{0}", "`", "",
        ].map { .text($0) } + [.object("<>&'\""), .object(""), .object("e\u{301}")]
        let tokenizer = HTMLTokenizer(maximumInputScalars: 128, maximumTokens: 128)
        for iteration in 0..<512 {
            var input: [HTMLPart] = []
            for _ in 0..<random.next(97) { input.append(alphabet[random.next(alphabet.count)]) }
            let tokens = try tokenizer.tokenize(input)
            let mergedTokens = try tokenizer.tokenize(coalesced(input))
            guard sourceUnits(sourceParts(tokens)) == sourceUnits(input),
                  objects(sourceParts(tokens)) == objects(input),
                  tokens == mergedTokens,
                  try tokens == tokenizer.tokenize(input) else {
                XCTFail("Source/order/determinism mismatch: seed 0x12345678, iteration \(iteration)")
                return
            }
        }
    }

    func testGenericTokenizerStillScansNestedTagsInsideScript() throws {
        let input: [HTMLPart] = [.text(#"<script>const x="<img src='asset'>";</script>"#)]
        let expected: [HTMLToken] = [
            tag("script", raw: [.text("<script>")]), .text([.text("const x=\"")]),
            tag("img", raw: [.text("<img src='asset'>")], attributes: [attribute("src", [.text("asset")])]),
            .text([.text("\";")]), tag("script", raw: [.text("</script>")], closing: true),
        ]
        XCTAssertEqual(try HTMLTokenizer().tokenize(input), expected)
        let disabled = try HTMLTokenizer().tokenize(input, rawTextElement: nil, recognizingRawText: false)
        XCTAssertEqual(disabled.tokens, expected)
        XCTAssertNil(disabled.rawTextElement)
    }

    func testRawScriptBodyDoesNotCreateNestedTagsAndIgnoresJSQuotes() throws {
        let body = #"const x="<img src='asset'>"; const dangling="unclosed"#
        let input: [HTMLPart] = [.text("<ScRiPt>" + body + "</SCRIPT><a href=next>next</a>")]
        let result = try HTMLTokenizer().tokenize(input, rawTextElement: nil, recognizingRawText: true)
        XCTAssertEqual(result.tokens, [
            tag("script", raw: [.text("<ScRiPt>")]), .rawText([.text(body)], decodeEntities: false),
            tag("script", raw: [.text("</SCRIPT>")], closing: true),
            tag("a", raw: [.text("<a href=next>")], attributes: [attribute("href", [.text("next")])]),
            .text([.text("next")]), tag("a", raw: [.text("</a>")], closing: true),
        ])
        XCTAssertNil(result.rawTextElement)
        assertSource(result.tokens, equals: input)
    }

    func testRawTextAndRCDATAElementNamesSelectEntityFlags() throws {
        let body = "<img src='asset'><a href='link'>label</a>&amp;<!--note-->"
        for name in ["script", "style", "xmp", "iframe", "noembed", "noframes", "title", "textarea"] {
            let opening = "<" + name.uppercased() + ">"
            let closing = "</" + name.uppercased() + ">"
            let input: [HTMLPart] = [.text(opening + body + closing)]
            let result = try HTMLTokenizer().tokenize(input, rawTextElement: nil, recognizingRawText: true)
            XCTAssertEqual(result.tokens, [
                tag(name, raw: [.text(opening)]),
                .rawText([.text(body)], decodeEntities: name == "title" || name == "textarea"),
                tag(name, raw: [.text(closing)], closing: true),
            ], name)
            XCTAssertNil(result.rawTextElement, name)
            assertSource(result.tokens, equals: input)
        }
    }

    func testRawTextClosingRequiresExactNameAndOnlyTrailingWhitespace() throws {
        let body = "</scripty></scripture></style></script/></script x></script x='>'></ script></script\u{00A0}>"
        let closing = "</sCrIpT\t\r\n\u{0C} >"
        let input: [HTMLPart] = [.text(body + closing + "tail")]
        let result = try HTMLTokenizer().tokenize(input, rawTextElement: "script", recognizingRawText: true)
        XCTAssertEqual(result.tokens, [
            .rawText([.text(body)], decodeEntities: false),
            tag("script", raw: [.text(closing)], closing: true), .text([.text("tail")]),
        ])
        XCTAssertNil(result.rawTextElement)
        assertSource(result.tokens, equals: input)
    }

    func testNonASCIIRawTextStateDoesNotSelectASCIIMode() throws {
        let input: [HTMLPart] = [.text("<B>x</B>")]
        let expected = try HTMLTokenizer().tokenize(input)
        for state in ["ſcript", "SCRIPT\u{10FFFF}", "\u{100053}CRIPT", "SCRIPT\u{0}"] {
            let result = try HTMLTokenizer().tokenize(input, rawTextElement: state, recognizingRawText: true)
            XCTAssertEqual(result.tokens, expected, state)
            XCTAssertNil(result.rawTextElement, state)
        }
    }

    func testNonASCIIRawTextClosingCandidatesRemainBody() throws {
        let body = "</ſcript></SCRIPT\u{10FFFF}></\u{100053}CRIPT>"
        let closing = "</SCRIPT>"
        let input: [HTMLPart] = [.text(body + closing)]
        let result = try HTMLTokenizer().tokenize(input, rawTextElement: "ScRiPt", recognizingRawText: true)
        XCTAssertEqual(result.tokens, [
            .rawText([.text(body)], decodeEntities: false),
            tag("script", raw: [.text(closing)], closing: true),
        ])
        XCTAssertNil(result.rawTextElement)
        assertSource(result.tokens, equals: input)
    }

    func testRawTextClosingIsRecognizedInsideCommentLikeBodyText() throws {
        let result = try HTMLTokenizer().tokenize(
            [.text("<!--</script>-->")], rawTextElement: "script", recognizingRawText: true
        )
        XCTAssertEqual(result.tokens, [
            .rawText([.text("<!--")], decodeEntities: false),
            tag("script", raw: [.text("</script>")], closing: true), .text([.text("-->")]),
        ])
        XCTAssertNil(result.rawTextElement)
    }

    func testOnlyValidNonSelfClosingOpeningTagsEnterRawText() throws {
        for raw in ["<script/>", "<script />", "</script>", "<scripts>", "<script x=>", "<!--<script>-->"] {
            let input: [HTMLPart] = [.text(raw + "<img src=x>")]
            let result = try HTMLTokenizer().tokenize(input, rawTextElement: nil, recognizingRawText: true)
            XCTAssertNil(result.rawTextElement, raw)
            XCTAssertEqual(result.tokens, try HTMLTokenizer().tokenize(input), raw)
        }
        let opened = try HTMLTokenizer(maximumTokens: 1).tokenize(
            [.text("<script>")], rawTextElement: nil, recognizingRawText: true
        )
        XCTAssertEqual(opened.tokens, [tag("script", raw: [.text("<script>")])])
        XCTAssertEqual(opened.rawTextElement, "script")
    }

    func testRawTextStatePersistsAcrossLeavesAndAnEmptyLeaf() throws {
        let tokenizer = HTMLTokenizer()
        let first = try tokenizer.tokenize([.text("<script>first")], rawTextElement: nil, recognizingRawText: true)
        XCTAssertEqual(first.tokens, [tag("script", raw: [.text("<script>")]), .rawText([.text("first")], decodeEntities: false)])
        XCTAssertEqual(first.rawTextElement, "script")
        let empty = try tokenizer.tokenize([], rawTextElement: first.rawTextElement, recognizingRawText: true)
        XCTAssertEqual(empty.tokens, [])
        XCTAssertEqual(empty.rawTextElement, "script")
        let body: [HTMLPart] = [.object("middle"), .text("<img src=x>&amp;")]
        let second = try tokenizer.tokenize(body, rawTextElement: empty.rawTextElement, recognizingRawText: true)
        XCTAssertEqual(second.tokens, [.rawText(body, decodeEntities: false)])
        XCTAssertEqual(second.rawTextElement, "script")
        let last = try tokenizer.tokenize(
            [.text("</script><b>tail")], rawTextElement: second.rawTextElement, recognizingRawText: true
        )
        XCTAssertEqual(last.tokens, [
            tag("script", raw: [.text("</script>")], closing: true),
            tag("b", raw: [.text("<b>")]), .text([.text("tail")]),
        ])
        XCTAssertNil(last.rawTextElement)
    }

    func testRawTextDoesNotJoinClosingTagsSplitAcrossLeaves() throws {
        let tokenizer = HTMLTokenizer()
        let firstInput: [HTMLPart] = [.text("<script>x</scr")]
        let first = try tokenizer.tokenize(firstInput, rawTextElement: nil, recognizingRawText: true)
        XCTAssertEqual(first.tokens, [tag("script", raw: [.text("<script>")]), .rawText([.text("x</scr")], decodeEntities: false)])
        let secondInput: [HTMLPart] = [.text("ipt><img src=x>")]
        let second = try tokenizer.tokenize(secondInput, rawTextElement: first.rawTextElement, recognizingRawText: true)
        XCTAssertEqual(second.tokens, [.rawText(secondInput, decodeEntities: false)])
        XCTAssertEqual(second.rawTextElement, "script")
        let last = try tokenizer.tokenize([.text("</script>")], rawTextElement: second.rawTextElement, recognizingRawText: true)
        XCTAssertEqual(last.tokens, [tag("script", raw: [.text("</script>")], closing: true)])
        XCTAssertNil(last.rawTextElement)
        assertSource(first.tokens + second.tokens + last.tokens, equals: firstInput + secondInput + [.text("</script>")])
    }

    func testDisabledRecognitionDoesNotEnterAnyRawTextMode() throws {
        for name in ["script", "style", "xmp", "iframe", "noembed", "noframes", "title", "textarea", "plaintext"] {
            let input: [HTMLPart] = [.text("<" + name + "><img src=x></" + name + ">")]
            let result = try HTMLTokenizer().tokenize(input, rawTextElement: nil, recognizingRawText: false)
            XCTAssertEqual(result.tokens, try HTMLTokenizer().tokenize(input), name)
            XCTAssertEqual(result.tokens.map(kind), ["tag", "tag", "tag"], name)
            XCTAssertNil(result.rawTextElement, name)
        }
    }

    func testSuppliedRawTextStateRemainsActiveWhenNewRecognitionIsDisabled() throws {
        let result = try HTMLTokenizer().tokenize(
            [.text("<img src=x></script><style>tail")], rawTextElement: "SCRIPT", recognizingRawText: false
        )
        XCTAssertEqual(result.tokens, [
            .rawText([.text("<img src=x>")], decodeEntities: false),
            tag("script", raw: [.text("</script>")], closing: true),
            tag("style", raw: [.text("<style>")]), .text([.text("tail")]),
        ])
        XCTAssertNil(result.rawTextElement)
    }

    func testPlaintextNeverRecognizesAClosingTagEvenInLaterLeaves() throws {
        let body: [HTMLPart] = [.text("&amp;</plaintext><img src=x>"), .object("first"), .text("</SCRIPT>")]
        let input: [HTMLPart] = [.text("<PLAINTEXT>")] + body
        let first = try HTMLTokenizer().tokenize(input, rawTextElement: nil, recognizingRawText: true)
        XCTAssertEqual(first.tokens, [tag("plaintext", raw: [.text("<PLAINTEXT>")]), .rawText(body, decodeEntities: false)])
        XCTAssertEqual(first.rawTextElement, "plaintext")
        let secondInput: [HTMLPart] = [.object("second"), .text("</plaintext><title>&amp;")]
        let second = try HTMLTokenizer().tokenize(secondInput, rawTextElement: first.rawTextElement, recognizingRawText: true)
        XCTAssertEqual(second.tokens, [.rawText(secondInput, decodeEntities: false)])
        XCTAssertEqual(second.rawTextElement, "plaintext")
        assertSource(first.tokens + second.tokens, equals: input + secondInput)
        assertObjectOrder(first.tokens + second.tokens, equals: ["first", "second"])
    }

    func testRawTextObjectsCannotSupplyClosingSyntaxAndKeepExactOrder() throws {
        let body: [HTMLPart] = [
            .text("e\u{301}"), .object("first"), .text("</scr"), .object("middle"),
            .text("ipt><img src=x>"), .object("</script>"), .text("&amp;"),
        ]
        let input: [HTMLPart] = [.text("<script>")] + body + [.text("</SCRIPT>"), .object("after")]
        let result = try HTMLTokenizer().tokenize(input, rawTextElement: nil, recognizingRawText: true)
        XCTAssertEqual(result.tokens, [
            tag("script", raw: [.text("<script>")]), .rawText(body, decodeEntities: false),
            tag("script", raw: [.text("</SCRIPT>")], closing: true), .text([.object("after")]),
        ])
        XCTAssertNil(result.rawTextElement)
        assertSource(result.tokens, equals: input)
        assertObjectOrder(result.tokens, equals: ["first", "middle", "</script>", "after"])
    }

    func testRawTextClosingCanSpanTextPartsWithinOneLeaf() throws {
        let input: [HTMLPart] = [.text("<scr"), .text("ipt>body</scr"), .text(""), .text("IPT"), .text(" >tail")]
        let result = try HTMLTokenizer().tokenize(input, rawTextElement: nil, recognizingRawText: true)
        XCTAssertEqual(result.tokens, [
            tag("script", raw: [.text("<script>")]), .rawText([.text("body")], decodeEntities: false),
            tag("script", raw: [.text("</scrIPT >")], closing: true), .text([.text("tail")]),
        ])
        XCTAssertNil(result.rawTextElement)
        assertSource(result.tokens, equals: input)
    }

    func testRawTextCanExitAndEnterAnotherModeWithinOneLeaf() throws {
        let result = try HTMLTokenizer().tokenize(
            [.text("<script>x</script><title>&amp;</title><textarea>tail")],
            rawTextElement: nil, recognizingRawText: true
        )
        XCTAssertEqual(result.tokens, [
            tag("script", raw: [.text("<script>")]), .rawText([.text("x")], decodeEntities: false),
            tag("script", raw: [.text("</script>")], closing: true),
            tag("title", raw: [.text("<title>")]), .rawText([.text("&amp;")], decodeEntities: true),
            tag("title", raw: [.text("</title>")], closing: true),
            tag("textarea", raw: [.text("<textarea>")]), .rawText([.text("tail")], decodeEntities: true),
        ])
        XCTAssertEqual(result.rawTextElement, "textarea")
    }

    func testRawTextInputAndTokenLimitsIncludeBodyAndClosingTokens() throws {
        let input: [HTMLPart] = [.text("<script>x</script>")]
        let result = try HTMLTokenizer(maximumTokens: 3).tokenize(input, rawTextElement: nil, recognizingRawText: true)
        XCTAssertEqual(result.tokens.count, 3)
        for budget in [0, 1, 2] {
            XCTAssertThrowsError(try HTMLTokenizer(maximumTokens: budget).tokenize(input, rawTextElement: nil, recognizingRawText: true)) {
                XCTAssertEqual($0 as? HTMLTokenizationError, .tokenLimit)
            }
        }
        let emptyBody = try HTMLTokenizer(maximumTokens: 2).tokenize(
            [.text("<script></script>")], rawTextElement: nil, recognizingRawText: true
        )
        XCTAssertEqual(emptyBody.tokens.map(kind), ["tag", "tag"])
        let closingOnly = try HTMLTokenizer(maximumTokens: 1).tokenize(
            [.text("</script>")], rawTextElement: "script", recognizingRawText: true
        )
        XCTAssertEqual(closingOnly.tokens.count, 1)
        XCTAssertNil(closingOnly.rawTextElement)
        let empty = try HTMLTokenizer(maximumInputScalars: 0, maximumTokens: 0).tokenize(
            [], rawTextElement: "title", recognizingRawText: true
        )
        XCTAssertEqual(empty.tokens, [])
        XCTAssertEqual(empty.rawTextElement, "title")
        for input: [HTMLPart] in [[.text("")], [.object("")], [.text("x")]] {
            XCTAssertThrowsError(try HTMLTokenizer(maximumInputScalars: 0, maximumTokens: 0).tokenize(
                input, rawTextElement: "script", recognizingRawText: true
            )) { XCTAssertEqual($0 as? HTMLTokenizationError, .inputLimit) }
        }
        let body: [HTMLPart] = [.text("e\u{301}"), .object("opaque"), .text("")]
        assertSource(try HTMLTokenizer(maximumInputScalars: 4, maximumTokens: 1).tokenize(
            body, rawTextElement: "textarea", recognizingRawText: true
        ).tokens, equals: body)
        XCTAssertThrowsError(try HTMLTokenizer(maximumInputScalars: 3).tokenize(
            body, rawTextElement: "textarea", recognizingRawText: true
        )) { XCTAssertEqual($0 as? HTMLTokenizationError, .inputLimit) }
    }

    func testRawTextBoundedFailedClosingCandidatesAndLessThanRuns() throws {
        let candidate = "</script" + String(repeating: " ", count: 32) + "<"
        let body = String(repeating: candidate, count: 256) + String(repeating: "<", count: 32_768)
        let input: [HTMLPart] = [.text(body)]
        let result = try HTMLTokenizer(maximumTokens: 1).tokenize(input, rawTextElement: "script", recognizingRawText: true)
        XCTAssertTrue(result.tokens == [.rawText(input, decodeEntities: false)])
        XCTAssertEqual(result.rawTextElement, "script")
        assertSource(result.tokens, equals: input)
    }

    func testDeterministicBoundedRandomRawTextPreservation() throws {
        var random = DeterministicRandom()
        let alphabet: [HTMLPart] = [
            "<script>", "</SCRIPT>", "</script x>", "<title>", "</title>", "<plaintext>",
            "<img src=x>", "<", ">", "\"", "'", "\n", " ", "&amp;", "e\u{301}", "",
        ].map { .text($0) } + [.object("</script>"), .object(""), .object("e\u{301}")]
        let modes: [String?] = [nil, "script", "textarea", "plaintext"]
        let tokenizer = HTMLTokenizer(maximumInputScalars: 2048, maximumTokens: 128)
        for iteration in 0..<512 {
            var input: [HTMLPart] = []
            for _ in 0..<random.next(65) { input.append(alphabet[random.next(alphabet.count)]) }
            let mode = modes[random.next(modes.count)]
            let recognizing = random.next(2) == 1
            let result = try tokenizer.tokenize(input, rawTextElement: mode, recognizingRawText: recognizing)
            let merged = try tokenizer.tokenize(coalesced(input), rawTextElement: mode, recognizingRawText: recognizing)
            guard sourceUnits(sourceParts(result.tokens)) == sourceUnits(input),
                  objects(sourceParts(result.tokens)) == objects(input),
                  result.tokens == merged.tokens, result.rawTextElement == merged.rawTextElement else {
                XCTFail("Raw-text source/order/state mismatch: seed 0x12345678, iteration \(iteration)")
                return
            }
        }
    }

    func testEntitiesDecodeSupportedNamedReferencesIndependently() {
        XCTAssertEqual(HTMLEntities.decode("&amp;&lt;&gt;&quot;&apos;&nbsp;"), "&<>\"'\u{00A0}")
        XCTAssertEqual(HTMLEntities.decode("plain e\u{301}💠\r\n"), "plain e\u{301}💠\r\n")
        XCTAssertEqual(HTMLEntities.decode(""), "")
    }

    func testEntitiesDecodeDecimalAndHexadecimalScalars() {
        for (input, expected) in [
            ("&#65;&#x41;&#X41;", "AAA"), ("&#00065;&#x000041;", "AA"),
            ("&#128160;&#x1F4A0;", "💠💠"), ("&#1;", "\u{1}"),
            ("&#128;", "\u{80}"), ("&#x10FFFF;", "\u{10FFFF}"),
        ] {
            XCTAssertEqual(HTMLEntities.decode(input), expected, input)
        }
    }

    func testEntitiesReplaceZeroSurrogatesOutOfRangeAndOverflow() {
        for input in [
            "&#0;", "&#x0;", "&#55296;", "&#xD800;", "&#xDFFF;",
            "&#1114112;", "&#x110000;", "&#4294967296;", "&#xFFFFFFFF;",
        ] {
            XCTAssertEqual(HTMLEntities.decode(input), "\u{FFFD}", input)
        }
    }

    func testEntitiesPreserveUnknownMalformedAndUnterminatedReferences() {
        for input in [
            "&AMP;", "&copy;", "&unknown;", "&#;", "&#x;", "&#X;", "&#-1;", "&#+65;",
            "&# 65;", "&#6 5;", "&#xZZ;", "&#x+41;", "&amp", "&#65", "&#x41", "&", ";",
        ] {
            XCTAssertEqual(HTMLEntities.decode(input), input, input)
        }
        XCTAssertEqual(HTMLEntities.decode("&unknown;&amp;"), "&unknown;&")
        XCTAssertEqual(HTMLEntities.decode("&&amp;"), "&&")
    }

    func testEntitiesDecodeExactlyOnce() {
        XCTAssertEqual(HTMLEntities.decode("&amp;lt; &#38;amp;"), "&lt; &amp;")
        XCTAssertEqual(HTMLEntities.decode("&#x26;#65;"), "&#65;")
    }

    func testEntitiesBoundReferenceLookahead() {
        let withinBoundary = "&#" + String(repeating: "0", count: 28) + "65;"
        let beyondBoundary = "&#" + String(repeating: "0", count: 29) + "65;"
        XCTAssertEqual(HTMLEntities.decode(withinBoundary), "A")
        XCTAssertEqual(HTMLEntities.decode(beyondBoundary), beyondBoundary)
        let longUnknown = "&" + String(repeating: "x", count: 4096) + ";"
        XCTAssertTrue(HTMLEntities.decode(longUnknown + "&amp;") == longUnknown + "&")
    }

    private func attribute(_ name: String, _ value: [HTMLPart]? = nil) -> HTMLAttribute {
        HTMLAttribute(name: name, value: value)
    }

    private func tag(
        _ name: String, raw: [HTMLPart], attributes: [HTMLAttribute] = [],
        closing: Bool = false, selfClosing: Bool = false
    ) -> HTMLToken {
        .tag(HTMLTag(name: name, isClosing: closing, isSelfClosing: selfClosing, attributes: attributes, raw: raw))
    }

    private func assertError(
        _ tokenizer: HTMLTokenizer, _ input: [HTMLPart], _ expected: HTMLTokenizationError,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try tokenizer.tokenize(input), file: file, line: line) { error in
            XCTAssertEqual(error as? HTMLTokenizationError, expected, file: file, line: line)
        }
    }

    private func assertSource(
        _ tokens: [HTMLToken], equals input: [HTMLPart],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(sourceUnits(sourceParts(tokens)) == sourceUnits(input), "Source scalar/atom mismatch", file: file, line: line)
    }

    private func assertObjectOrder(
        _ tokens: [HTMLToken], equals identities: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(objects(sourceParts(tokens)), identities.map { $0.unicodeScalars.map(\.value) }, file: file, line: line)
    }

    private enum SourceUnit: Equatable {
        case scalar(UInt32)
        case object([UInt32])
    }

    private func sourceUnits(_ parts: [HTMLPart]) -> [SourceUnit] {
        parts.flatMap { part -> [SourceUnit] in
            switch part {
            case .text(let text): return text.unicodeScalars.map { .scalar($0.value) }
            case .object(let identity): return [.object(identity.unicodeScalars.map(\.value))]
            }
        }
    }

    private func sourceParts(_ tokens: [HTMLToken]) -> [HTMLPart] {
        tokens.flatMap { token in
            switch token {
            case .text(let parts), .comment(let parts), .literal(let parts), .rawText(let parts, _): return parts
            case .tag(let tag): return tag.raw
            }
        }
    }

    private func objects(_ parts: [HTMLPart]) -> [[UInt32]] {
        parts.compactMap { part in
            if case .object(let identity) = part { return identity.unicodeScalars.map(\.value) }
            return nil
        }
    }

    private func kind(_ token: HTMLToken) -> String {
        switch token {
        case .text: return "text"
        case .tag: return "tag"
        case .comment: return "comment"
        case .literal: return "literal"
        case .rawText: return "rawText"
        }
    }

    private func coalesced(_ parts: [HTMLPart]) -> [HTMLPart] {
        var result: [HTMLPart] = []
        for part in parts {
            if case .text(let text) = part {
                if text.isEmpty { continue }
                if case .text(let previous)? = result.last {
                    result[result.count - 1] = .text(previous + text)
                } else {
                    result.append(part)
                }
            } else {
                result.append(part)
            }
        }
        return result
    }

    private struct DeterministicRandom {
        private var state: UInt64 = 0x12345678

        mutating func next(_ upperBound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(upperBound))
        }
    }
}
