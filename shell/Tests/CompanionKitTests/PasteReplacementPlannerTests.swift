import Foundation
import XCTest

@testable import CompanionKit

final class PasteReplacementPlannerTests: XCTestCase {
    private func context(
        _ document: String = "",
        range: NSRange = NSRange(location: 0, length: 0),
        markdown: Bool = true,
        inFence: Bool = false,
        inContainer: Bool = false,
        attachment: Bool = false,
        markedText: Bool = false
    ) -> PasteDestinationContext {
        PasteDestinationContext(
            documentText: document,
            replacementRange: range,
            isMarkdownCapable: markdown,
            intersectsCodeFence: inFence,
            isInListOrQuoteContainer: inContainer,
            intersectsAttachment: attachment,
            hasMarkedText: markedText
        )
    }

    func testPlansOneCompleteReplacementAndCaret() throws {
        let plan = try XCTUnwrap(PasteReplacementPlanner.plan(
            payload: "let value = 1",
            destination: context(),
            acceptedLanguageLabel: "swift"
        ))

        XCTAssertEqual(plan.replacementRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(plan.replacementText, "```swift\nlet value = 1\n```")
        XCTAssertEqual(
            plan.finalCaretRange,
            NSRange(location: plan.replacementText.utf16.count, length: 0)
        )
    }

    func testDelimiterIsLongerThanEveryPayloadBacktickRun() throws {
        let payload = "let a = `x`\nlet b = `````y`````"
        let plan = try XCTUnwrap(PasteReplacementPlanner.plan(
            payload: payload,
            destination: context(),
            acceptedLanguageLabel: "swift"
        ))

        XCTAssertEqual(plan.replacementText, "``````swift\n\(payload)\n``````")
    }

    func testCRLFPayloadIsUnchangedAndSuppliesStructuralLineEnding() throws {
        let payload = "first\r\nsecond\r\n"
        let plan = try XCTUnwrap(PasteReplacementPlanner.plan(
            payload: payload,
            destination: context(),
            acceptedLanguageLabel: "text"
        ))

        XCTAssertEqual(plan.replacementText, "```text\r\nfirst\r\nsecond\r\n```")
        XCTAssertTrue(plan.replacementText.contains(payload))
    }

    func testMissingPayloadTerminatorAddsOnlyTheRequiredNewline() throws {
        let plan = try XCTUnwrap(PasteReplacementPlanner.plan(
            payload: "print(1)",
            destination: context("before\r\nafter", range: NSRange(location: 8, length: 0)),
            acceptedLanguageLabel: "python"
        ))

        XCTAssertEqual(plan.replacementText, "```python\r\nprint(1)\r\n```\r\n")
    }

    func testTabsAndPayloadSpacingRemainExact() throws {
        let payload = "\tif true {\n\t\tprint(\"yes\")\n\t}"
        let plan = try XCTUnwrap(PasteReplacementPlanner.plan(
            payload: payload,
            destination: context(),
            acceptedLanguageLabel: "swift"
        ))

        XCTAssertTrue(plan.replacementText.contains("\n\(payload)\n"))
    }

    func testCaretUsesEmojiUTF16LengthAndReplacementLocation() throws {
        let payload = "print(\"👩🏽‍💻\")"
        let plan = try XCTUnwrap(PasteReplacementPlanner.plan(
            payload: payload,
            destination: context("before\n", range: NSRange(location: 7, length: 0)),
            acceptedLanguageLabel: "swift"
        ))

        XCTAssertEqual(
            plan.finalCaretRange,
            NSRange(location: 7 + plan.replacementText.utf16.count, length: 0)
        )
        XCTAssertNotEqual(plan.replacementText.utf16.count, plan.replacementText.count)
    }

    func testAlreadyFencedPayloadsAreIneligible() {
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: "```swift\nlet x = 1\n```",
            destination: context(),
            acceptedLanguageLabel: "swift"
        ))
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: "~~~python\r\nprint(1)\r\n~~~",
            destination: context(),
            acceptedLanguageLabel: "python"
        ))
    }

    func testDestinationInsideOrCrossingFenceIsIneligible() {
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: "let x = 1",
            destination: context("```\ncode\n```", range: NSRange(location: 4, length: 0), inFence: true),
            acceptedLanguageLabel: "swift"
        ))
    }

    func testMarkdownPredictionIsIneligible() {
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: "# Heading\n\n- item",
            destination: context(),
            acceptedLanguageLabel: "Markdown"
        ))
    }

    func testInlineAndPartialLineDestinationsAreIneligible() {
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: "let x = 1",
            destination: context("prefix suffix", range: NSRange(location: 7, length: 0)),
            acceptedLanguageLabel: "swift"
        ))
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: "let x = 1",
            destination: context("old line\n", range: NSRange(location: 0, length: 3)),
            acceptedLanguageLabel: "swift"
        ))
    }

    func testWholeLineReplacementMayExcludeExistingTerminator() throws {
        let document = "before\nold\nafter"
        let plan = try XCTUnwrap(PasteReplacementPlanner.plan(
            payload: "new",
            destination: context(document, range: NSRange(location: 7, length: 3)),
            acceptedLanguageLabel: "text"
        ))

        XCTAssertEqual(plan.replacementText, "```text\nnew\n```")
        let replaced = (document as NSString).replacingCharacters(
            in: plan.replacementRange,
            with: plan.replacementText
        )
        XCTAssertEqual(replaced, "before\n```text\nnew\n```\nafter")
    }

    func testUnicodeParagraphSeparatorIsAWholeLineBoundaryAndStructuralEnding() throws {
        let document = "before\u{2029}after"
        let plan = try XCTUnwrap(PasteReplacementPlanner.plan(
            payload: "let value = 1\u{2029}",
            destination: context(document, range: NSRange(location: 7, length: 0)),
            acceptedLanguageLabel: "swift"
        ))

        XCTAssertEqual(plan.replacementText, "```swift\u{2029}let value = 1\u{2029}```\u{2029}")
    }

    func testCRLFBoundaryCannotSplitTheTerminator() {
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: "new",
            destination: context("before\r\nafter", range: NSRange(location: 7, length: 0)),
            acceptedLanguageLabel: "text"
        ))
    }

    func testNonMarkdownAndEditorOwnedExclusionsAreIneligible() {
        let payload = "let x = 1"
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: payload,
            destination: context(markdown: false),
            acceptedLanguageLabel: "swift"
        ))
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: payload,
            destination: context(inContainer: true),
            acceptedLanguageLabel: "swift"
        ))
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: payload,
            destination: context(attachment: true),
            acceptedLanguageLabel: "swift"
        ))
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: payload,
            destination: context(markedText: true),
            acceptedLanguageLabel: "swift"
        ))
    }

    func testWhitespaceOnlyPayloadAndUnsafeLabelAreIneligible() {
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: " \t\r\n",
            destination: context(),
            acceptedLanguageLabel: "swift"
        ))
        XCTAssertNil(PasteReplacementPlanner.plan(
            payload: "let x = 1",
            destination: context(),
            acceptedLanguageLabel: "swift bad"
        ))
    }
}
