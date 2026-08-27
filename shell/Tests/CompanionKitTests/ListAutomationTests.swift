import AppKit
import XCTest

@testable import CompanionKit

/// What the page will call a list, decided without a view (the shell's
/// pattern for UI-adjacent logic: the reading is a pure function and
/// AppKit is never mocked). The marker grammar is deliberately narrow,
/// because the parser's answer is what licenses the editor to write ink
/// the user did not type, and a false positive there is a surprise
/// keystroke rather than a cosmetic slip.
final class ListMarkerTests: XCTestCase {
    func testABulletIsReadWithTheIndentItHangsFrom() {
        let plain = InkStyle.listMarker(of: "- milk")
        XCTAssertEqual(plain, InkStyle.ListItem(indent: "", marker: .bullet("-"), length: 2))

        let nested = InkStyle.listMarker(of: "  * milk")
        XCTAssertEqual(nested, InkStyle.ListItem(indent: "  ", marker: .bullet("*"), length: 4))

        // GitHub accepts `+` and almost nobody types it; one table row
        // is the whole cost of keeping it.
        let tabbed = InkStyle.listMarker(of: "\t+ milk")
        XCTAssertEqual(tabbed, InkStyle.ListItem(indent: "\t", marker: .bullet("+"), length: 3))
    }

    func testAnOrderedItemKeepsItsNumberAndItsDelimiter() {
        XCTAssertEqual(
            InkStyle.listMarker(of: "1. first"),
            InkStyle.ListItem(indent: "", marker: .ordered(number: 1, delimiter: "."), length: 3)
        )
        XCTAssertEqual(
            InkStyle.listMarker(of: "12) twelfth"),
            InkStyle.ListItem(indent: "", marker: .ordered(number: 12, delimiter: ")"), length: 4)
        )
        XCTAssertEqual(
            InkStyle.listMarker(of: "   0. zeroth"),
            InkStyle.ListItem(
                indent: "   ", marker: .ordered(number: 0, delimiter: "."), length: 6
            )
        )
    }

    func testATaskBoxIsReadAheadOfTheBulletItIsBuiltOn() {
        XCTAssertEqual(
            InkStyle.listMarker(of: "- [ ] ship it"),
            InkStyle.ListItem(indent: "", marker: .task(checked: false), length: 6)
        )
        XCTAssertEqual(
            InkStyle.listMarker(of: "- [x] shipped"),
            InkStyle.ListItem(indent: "", marker: .task(checked: true), length: 6)
        )
        XCTAssertEqual(
            InkStyle.listMarker(of: "  - [X] shipped"),
            InkStyle.ListItem(indent: "  ", marker: .task(checked: true), length: 8)
        )
        // Without the trailing space the line is a bullet whose content
        // begins with a bracket, which is exactly what it looks like.
        XCTAssertEqual(
            InkStyle.listMarker(of: "- [x]"),
            InkStyle.ListItem(indent: "", marker: .bullet("-"), length: 2)
        )
    }

    /// Everything the grammar has to refuse, one row per way a line can
    /// look like a list and not be one. The single space after the
    /// marker is what does most of the work.
    func testTheGrammarRefusesWhatIsNotAList() {
        for line in [
            "",
            "milk",
            "-x",
            "-",
            "--- a rule",
            "1.5 litres",
            "1.a",
            "*emphasis*",
            "*",
            "[x] no bullet at all",
            "1234567890. too many digits to count with",
            " a leading space is not a marker",
        ] {
            XCTAssertNil(InkStyle.listMarker(of: line), "\"\(line)\" was read as a list item")
        }
    }

    /// An empty item is the marker and nothing else, which is how the
    /// keystroke path tells "continue this list" from "end it".
    func testAnEmptyItemIsTheMarkerAndNothingElse() {
        for line in ["- ", "  1. ", "- [ ] "] {
            let item = InkStyle.listMarker(of: line)
            XCTAssertEqual(item?.length, line.utf16.count, "\"\(line)\" carried unread content")
        }
    }

    func testABulletRepeatsItselfAndAnOrderedItemCountsOn() {
        XCTAssertEqual(InkStyle.listMarker(of: "- milk")?.successor, "- ")
        XCTAssertEqual(InkStyle.listMarker(of: "  * milk")?.successor, "  * ")
        XCTAssertEqual(InkStyle.listMarker(of: "3. third")?.successor, "4. ")
        XCTAssertEqual(InkStyle.listMarker(of: "3) third")?.successor, "4) ")
        XCTAssertEqual(InkStyle.listMarker(of: "\t9. ninth")?.successor, "\t10. ")
    }

    /// The next thing to do has not been done yet, so a checked item
    /// begets an unchecked one.
    func testATaskItemContinuesUnchecked() {
        XCTAssertEqual(InkStyle.listMarker(of: "- [x] shipped")?.successor, "- [ ] ")
        XCTAssertEqual(InkStyle.listMarker(of: "  - [ ] pending")?.successor, "  - [ ] ")
    }

    /// The page is one fixed-pitch font, so the hanging indent is
    /// arithmetic: a prefix is as wide as its character count.
    @MainActor
    func testTheHangingIndentIsTheMarkerWidthInCells() {
        XCTAssertGreaterThan(InkStyle.cellWidth, 0)
        XCTAssertEqual(InkStyle.hangingIndent(markerLength: 2), InkStyle.cellWidth * 2)
        XCTAssertEqual(InkStyle.hangingIndent(markerLength: 6), InkStyle.cellWidth * 6)
        XCTAssertEqual(InkStyle.hangingIndent(markerLength: 0), 0)
    }
}

/// The classifier's half of the same question: which lines the page
/// will treat as items at all. A fence's interior is the case worth
/// asserting twice, since it is where a list reading would be actively
/// wrong (issue #75).
@MainActor
final class ListClassificationTests: XCTestCase {
    private func kinds(_ page: String) -> [InkStyle.LineKind] {
        InkStyle.classify(lines: page.components(separatedBy: "\n"))
    }

    func testBodyLinesThatParseAsItemsAreLists() {
        XCTAssertEqual(
            kinds(
                """
                shopping
                - milk
                  1. first
                - [x] done
                not a list
                """
            ),
            [
                .body,
                .list(markerLength: 2),
                .list(markerLength: 5),
                .list(markerLength: 6),
                .body,
            ]
        )
    }

    /// The same characters, one fence deeper: `- x` is a flag on a
    /// command line and the automation must never see an item there.
    func testInsideAFenceAnItemIsCode() {
        XCTAssertEqual(
            kinds(
                """
                - a real bullet
                ```sh
                ls - x
                - not a bullet
                1. not an item either
                ```
                - a real bullet again
                """
            ),
            [
                .list(markerLength: 2),
                .fenceRule,
                .code(language: "shell"),
                .code(language: "shell"),
                .code(language: "shell"),
                .fenceRule,
                .list(markerLength: 2),
            ]
        )
    }

    /// A heading is read first, so a line can never be both.
    func testAHeadingIsNotAList() {
        XCTAssertEqual(kinds("# - milk"), [.heading(level: 1, markerLength: 2)])
    }
}

/// The keystroke, through a real text view over a real core: what the
/// storage holds afterwards, what crossed the seam, and what one ⌘Z
/// takes back.
///
/// The model is built with injected seams, without exception. A model
/// on default seams under the runner resolves the installed app's own
/// state directory, and a suite that writes there writes over somebody's
/// pages (ADR-0018).
@MainActor
final class ListKeystrokeTests: XCTestCase {
    private var model: PageModel!
    private var coordinator: InkEditorView.Coordinator!
    private var textView: InkTextView!
    private var sheet: UInt64 = 0
    private var batches: [[DocumentEditOp]] = []

    // Not a setUp override: those are nonisolated and this fixture is
    // main-actor state. Every test calls it first.
    private func makeEditor() {
        let suiteName = "companion-kit-list-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
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
        textView.allowsUndo = true
        coordinator = InkEditorView.Coordinator(model: model)
        textView.coordinator = coordinator
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.currentSheet = sheet
        storage.delegate = coordinator
        batches = []
        coordinator.onEmit = { [weak self] ops in self?.batches.append(ops) }
    }

    private var storage: NSTextStorage { model.storage(for: sheet) }

    /// Text onto the page, then the classification walk the keystroke
    /// path reads from. Restyle runs on every change in the mounted
    /// editor; here it is called by hand so a test never depends on
    /// notification timing for the reading it is about to assert.
    private func write(_ text: String) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.restyle()
        settleUndo()
        batches = []
    }

    /// An undo manager closes its per-event group when the run loop
    /// turns, and a test has no turning run loop of its own. Without
    /// this the fixture and the keystroke under test would share one
    /// group, and a single ⌘Z would take back both, which says nothing
    /// about the keystroke and everything about the harness.
    private func settleUndo() {
        textView.breakUndoCoalescing()
        RunLoop.current.run(until: Date())
    }

    private func caret(to location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    // MARK: Continuing

    func testReturnAtTheEndOfAnItemContinuesTheList() {
        makeEditor()
        write("- milk")
        let before = storage.length

        textView.insertNewline(nil)

        XCTAssertEqual(storage.string, "- milk\n- ")
        XCTAssertEqual(
            storage.length - before, 3,
            "the page grew by more than the newline and the marker"
        )
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: 9, length: 0),
            "the caret must land after the marker's trailing space"
        )
    }

    func testAnOrderedItemContinuesByCountingOn() {
        makeEditor()
        write("3) third")
        textView.insertNewline(nil)
        XCTAssertEqual(storage.string, "3) third\n4) ")
    }

    func testATaskItemContinuesUnchecked() {
        makeEditor()
        write("  - [x] shipped")
        textView.insertNewline(nil)
        XCTAssertEqual(storage.string, "  - [x] shipped\n  - [ ] ")
    }

    /// The whole point of ADR-0024: the automation writes on the
    /// caret's line and the line the keystroke made, and the numbers
    /// under it stand exactly as typed. A list whose numbers repeat is
    /// the writer's to fix, the same as in any text file.
    func testNothingBelowTheCaretIsRenumbered() {
        makeEditor()
        write("1. first\n2. second")
        caret(to: 8)

        textView.insertNewline(nil)

        XCTAssertEqual(storage.string, "1. first\n2. \n2. second")
    }

    /// The continuation is one ordinary insert, so the core sees what
    /// it would see from typing and provenance needs no special case
    /// (ADR-0013).
    func testTheContinuationCrossesTheSeamAsOneOrdinaryInsert() {
        makeEditor()
        write("- milk")
        textView.insertNewline(nil)
        XCTAssertEqual(batches, [[.ins(at: 6, text: "\n- ")]])
    }

    // MARK: Ending

    func testReturnOnAnEmptyItemTakesTheMarkerOffAndAddsNoLine() {
        makeEditor()
        write("- milk\n- ")

        textView.insertNewline(nil)

        XCTAssertEqual(storage.string, "- milk\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 0))
        XCTAssertEqual(batches, [[.del(at: 7, len: 2)]], "ending the list was not one plain delete")
    }

    func testEndingAnIndentedTaskListLeavesAPlainEmptyLine() {
        makeEditor()
        write("  - [ ] ")
        textView.insertNewline(nil)
        XCTAssertEqual(storage.string, "")
    }

    // MARK: Splitting

    /// A Return in the middle of an item splits the line as it always
    /// did. Pushing the text to the caret's right under a marker its
    /// author never typed would rewrite that text's reading, which is
    /// what the law is there to prevent.
    func testAMidLineReturnSplitsWithoutAMarker() {
        makeEditor()
        write("- milk and eggs")
        caret(to: 7)
        textView.insertNewline(nil)
        XCTAssertEqual(storage.string, "- milk \nand eggs")
    }

    /// ⇧Return is the hard wrap inside an item, and it stays exactly
    /// that: the escape hatch has to keep working.
    func testShiftReturnStaysAPlainLineBreak() {
        makeEditor()
        write("- milk")
        textView.insertLineBreak(nil)
        XCTAssertFalse(
            storage.string.hasSuffix("- "), "a line break wrote a marker it was not asked for"
        )
    }

    // MARK: The gates

    func testNoContinuationInsideAFence() {
        makeEditor()
        write("```sh\n- x")
        caret(to: 9)

        textView.insertNewline(nil)

        XCTAssertEqual(
            storage.string, "```sh\n- x\n",
            "a flag inside a fence was continued as a bullet (issue #75)"
        )
    }

    /// Mid-composition the marked text is not the writer's word yet,
    /// and resolving it with a marker underneath is not this keystroke's
    /// business (the ADR-0013 gate).
    func testNoContinuationWhileAnImeIsComposing() {
        makeEditor()
        write("- ")
        caret(to: 2)
        textView.setMarkedText(
            "ka", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        textView.insertNewline(nil)

        XCTAssertFalse(
            storage.string.contains("\n- "),
            "the empty-item branch ran under a live composition"
        )
        XCTAssertTrue(storage.string.hasPrefix("- "), "the marker was taken off mid-composition")
    }

    /// Return over a selection replaces what is selected; continuing
    /// the marker of a line whose content is on its way out is not the
    /// gesture that was asked for.
    func testNoContinuationWhenReturnReplacesASelection() {
        makeEditor()
        write("- milk")
        textView.setSelectedRange(NSRange(location: 2, length: 4))
        textView.insertNewline(nil)
        XCTAssertEqual(storage.string, "- \n")
    }

    /// The cache the keystroke reads is stamped with the storage it was
    /// read from. An edit the walk has not seen yet leaves it unable to
    /// vouch for itself, and it says nothing rather than something
    /// stale, which fails closed to a plain newline.
    func testAStaleClassificationAnswersNothing() {
        makeEditor()
        write("- milk")
        XCTAssertEqual(coordinator.classifiedKind(ofParagraphAt: 0), .list(markerLength: 2))

        storage.replaceCharacters(in: NSRange(location: 6, length: 0), with: " and eggs")
        XCTAssertNil(
            coordinator.classifiedKind(ofParagraphAt: 0),
            "a cache from a page of another length still answered"
        )
    }

    // MARK: Undo

    /// One keystroke, one undo step: ⌘Z after a continuation puts the
    /// caret back with no orphaned marker, and takes nothing of what
    /// was typed before it.
    func testOneUndoReversesTheContinuationAndNothingElse() {
        makeEditor()
        write("- milk")
        textView.insertNewline(nil)
        XCTAssertEqual(storage.string, "- milk\n- ")

        textView.undoManager?.undo()

        XCTAssertEqual(storage.string, "- milk")
    }

    func testOneUndoPutsBackAMarkerTheEmptyItemBranchRemoved() {
        makeEditor()
        write("- milk\n- ")
        textView.insertNewline(nil)
        XCTAssertEqual(storage.string, "- milk\n")

        textView.undoManager?.undo()

        XCTAssertEqual(storage.string, "- milk\n- ")
    }

    // MARK: Depth

    /// The nudge is two spaces at the line's start and nothing else:
    /// the marker keeps its own glyph, because a depth change is not a
    /// licence to restyle a character the writer typed.
    func testTabInTheMarkerRegionDeepensByExactlyTwoSpaces() {
        makeEditor()
        write("- milk")
        caret(to: 2)

        textView.insertTab(nil)

        XCTAssertEqual(storage.string, "  - milk")
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: 4, length: 0),
            "the caret left the marker region, so a second Tab would not deepen again"
        )
    }

    /// The commonest nesting gesture there is: type the marker, reach
    /// for Tab before any content exists. The caret sits exactly at the
    /// marker's end, and the region has to include that boundary or the
    /// gesture answers with a literal tab.
    func testTabAtTheMarkersEndDeepensAnItemWithNoContentYet() {
        makeEditor()
        write("- ")

        textView.insertTab(nil)

        XCTAssertEqual(storage.string, "  - ")
    }

    func testTabTwiceDeepensTwice() {
        makeEditor()
        write("- milk")
        caret(to: 2)

        textView.insertTab(nil)
        textView.insertTab(nil)

        XCTAssertEqual(storage.string, "    - milk")
    }

    /// Anywhere else on the line Tab is the character it has always
    /// been. The depth reading is only unambiguous in the marker.
    func testTabInAnItemsContentStaysALiteralTab() {
        makeEditor()
        write("- milk")

        textView.insertTab(nil)

        XCTAssertEqual(storage.string, "- milk\t")
    }

    func testShiftTabTakesBackTwoSpaces() {
        makeEditor()
        write("  - milk")
        caret(to: 4)

        textView.insertBacktab(nil)

        XCTAssertEqual(storage.string, "- milk")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    /// Depth spelled with a tab comes back one tab at a time: the
    /// outdent takes back a level, never a measurement of its own.
    func testShiftTabTakesBackOneTab() {
        makeEditor()
        write("\t- milk")
        caret(to: 3)

        textView.insertBacktab(nil)

        XCTAssertEqual(storage.string, "- milk")
    }

    /// An item hanging from nothing has nothing to give back, and the
    /// keystroke stops there rather than walking the key view loop and
    /// taking the focus out of the page with it.
    func testShiftTabOnAnUnindentedItemLeavesItAlone() {
        makeEditor()
        write("- milk")
        caret(to: 2)

        textView.insertBacktab(nil)

        XCTAssertEqual(storage.string, "- milk")
        XCTAssertEqual(batches, [], "an outdent with nothing to remove still reached the core")
    }

    /// A selection spanning lines has no single caret line, and
    /// deepening every line it covers would be writing where the caret
    /// is not, which is the one thing ADR-0024 forbids outright. The
    /// keystroke falls through to the ordinary tab.
    func testASelectionAcrossLinesFallsThroughToTheOrdinaryTab() {
        makeEditor()
        write("- milk\n- eggs")
        textView.setSelectedRange(NSRange(location: 0, length: 13))

        textView.insertTab(nil)

        XCTAssertEqual(storage.string, "\t")
    }

    // MARK: The gates, again

    func testNoDepthChangeInsideAFence() {
        makeEditor()
        write("```sh\n- x")
        caret(to: 6)

        textView.insertTab(nil)

        XCTAssertEqual(
            storage.string, "```sh\n\t- x",
            "a flag inside a fence was nudged as if it had depth (issue #75)"
        )
    }

    func testNoDepthChangeWhileAnImeIsComposing() {
        makeEditor()
        write("- ")
        caret(to: 2)
        textView.setMarkedText(
            "ka", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        textView.insertTab(nil)

        XCTAssertFalse(
            storage.string.hasPrefix("  "),
            "the line was deepened under a live composition"
        )
    }

    /// One keystroke, one undo step, for the nudge exactly as for the
    /// continuation: ⌘Z takes back the depth and none of the words
    /// typed before it.
    func testOneUndoReversesOneNudge() {
        makeEditor()
        write("- milk")
        caret(to: 2)
        textView.insertTab(nil)
        XCTAssertEqual(storage.string, "  - milk")

        textView.undoManager?.undo()

        XCTAssertEqual(storage.string, "- milk")
    }

    /// The nudge is an ordinary insert and the outdent an ordinary
    /// delete, so the core sees what typing would have sent it and
    /// ADR-0013's provenance needs no special case.
    func testTheDepthNudgeCrossesTheSeamAsAnOrdinaryEdit() {
        makeEditor()
        write("- milk")
        caret(to: 2)
        textView.insertTab(nil)
        XCTAssertEqual(batches, [[.ins(at: 0, text: "  ")]])

        coordinator.restyle()
        settleUndo()
        batches = []
        textView.insertBacktab(nil)
        XCTAssertEqual(batches, [[.del(at: 0, len: 2)]])
    }

    // MARK: Display

    /// The marker is the thing the eye scans for: it keeps its own
    /// glyph and full label colour, and the item hangs its wrapped
    /// lines under the content instead.
    func testAnItemHangsItsWrappedLinesUnderTheContent() {
        makeEditor()
        write("- milk and eggs and everything else the shop had")

        let style = storage.attributes(at: 0, effectiveRange: nil)[.paragraphStyle]
            as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, InkStyle.hangingIndent(markerLength: 2))
        XCTAssertEqual(
            storage.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor,
            NSColor.labelColor,
            "the marker was dimmed; a list marker is structure, not markup to hide"
        )
        XCTAssertEqual(
            storage.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont, InkStyle.baseFont
        )
    }

    func testAFlagInsideAFenceHangsFromNothing() {
        makeEditor()
        write("```sh\n- x\n```")
        let style = storage.attributes(at: 6, effectiveRange: nil)[.paragraphStyle]
            as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, 0)
    }

    /// An item is ordinary body ink apart from its indent, and "- see
    /// https://…" is the commonest line in a working note.
    func testAnItemStillCarriesItsLinks() {
        makeEditor()
        write("- see https://example.com")
        XCTAssertNotNil(storage.attributes(at: 8, effectiveRange: nil)[.link])
    }
}
