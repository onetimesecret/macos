import AppKit
import XCTest

@testable import CompanionKit

/// The op emitter's mapping (ADR-0013): one storage edit becomes one
/// replace-shaped batch, positions in UTF-16 code units. These feed
/// synthetic edits straight into the pure emitter, no delegate and no
/// view, so each mapping is asserted in isolation.
@MainActor
final class OpEmitterTests: XCTestCase {
    private func chipInfo(id: UInt64) -> ChipInfo {
        ChipInfo(chipId: id, kind: "text", excerpt: "ch…ip", sizeLabel: "4 ch", concealed: false)
    }

    func testTypingEmitsOneInsert() {
        let storage = NSTextStorage(string: "hello")
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
        let ops = InkEditorView.Coordinator.editOps(
            storage: storage, editedRange: NSRange(location: 5, length: 1), changeInLength: 1
        )
        XCTAssertEqual(ops, [.ins(at: 5, text: "!")])
    }

    func testDeletionSpanningAnEmojiEmitsItsFullUTF16Width() {
        let storage = NSTextStorage(string: "a\u{1F600}b")
        // The emoji is one character but two code units; the wire
        // speaks code units, so the delete is two wide.
        storage.deleteCharacters(in: NSRange(location: 1, length: 2))
        let ops = InkEditorView.Coordinator.editOps(
            storage: storage, editedRange: NSRange(location: 1, length: 0), changeInLength: -2
        )
        XCTAssertEqual(ops, [.del(at: 1, len: 2)])
    }

    func testDeletingAChipAttachmentEmitsOneDelete() {
        let storage = NSTextStorage(string: "ab")
        storage.insert(
            InkEditorView.Coordinator.chipString(chipInfo(id: 7)),
            at: 1
        )
        storage.deleteCharacters(in: NSRange(location: 1, length: 1))
        let ops = InkEditorView.Coordinator.editOps(
            storage: storage, editedRange: NSRange(location: 1, length: 0), changeInLength: -1
        )
        XCTAssertEqual(ops, [.del(at: 1, len: 1)])
    }

    func testAMultiRunPasteSplitsIntoInkAndChipOps() {
        let storage = NSTextStorage(string: "")
        let pasted = NSMutableAttributedString(string: "a\u{1F600}")
        pasted.append(InkEditorView.Coordinator.chipString(chipInfo(id: 9)))
        pasted.append(NSAttributedString(string: "b"))
        storage.insert(pasted, at: 0)
        let ops = InkEditorView.Coordinator.editOps(
            storage: storage, editedRange: NSRange(location: 0, length: 5), changeInLength: 5
        )
        XCTAssertEqual(ops, [
            .ins(at: 0, text: "a\u{1F600}"),
            .chip(at: 3, id: 9),
            .ins(at: 4, text: "b"),
        ])
    }

    func testAReplaceEmitsDeleteThenInsert() {
        let storage = NSTextStorage(string: "hello world")
        storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "goodbye")
        let ops = InkEditorView.Coordinator.editOps(
            storage: storage, editedRange: NSRange(location: 0, length: 7), changeInLength: 2
        )
        XCTAssertEqual(ops, [.del(at: 0, len: 5), .ins(at: 0, text: "goodbye")])
    }

    func testTheWireJSONKeepsOrderAndShape() throws {
        let json = try XCTUnwrap(DocumentEditOp.wireJSON([
            .del(at: 1, len: 2),
            .ins(at: 1, text: "x\u{1F680}"),
            .chip(at: 3, id: 7),
        ]))
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: Any]]]
        )
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0]["del"]?["at"] as? Int, 1)
        XCTAssertEqual(parsed[0]["del"]?["len"] as? Int, 2)
        XCTAssertEqual(parsed[1]["ins"]?["at"] as? Int, 1)
        XCTAssertEqual(parsed[1]["ins"]?["text"] as? String, "x\u{1F680}")
        XCTAssertEqual(parsed[2]["chip"]?["at"] as? Int, 3)
        XCTAssertEqual(parsed[2]["chip"]?["id"] as? UInt64, 7)
    }

    func testTheMinimalReplaceDiffTrimsAndRespectsSurrogatePairs() {
        // A shared prefix and suffix leave only the middle.
        XCTAssertEqual(
            InkEditorView.Coordinator.minimalReplace(at: 10, old: "kana", new: "kaXYa"),
            [.del(at: 12, len: 1), .ins(at: 12, text: "XY")]
        )
        // Identical strings replace nothing (the abandoned-composition
        // shape; the caller already skips this, the diff agrees).
        XCTAssertEqual(
            InkEditorView.Coordinator.minimalReplace(at: 0, old: "same", new: "same"), []
        )
        // Two emoji sharing a high surrogate: the trim must not end
        // between the halves of the pair, or the core would refuse the
        // offset.
        let ops = InkEditorView.Coordinator.minimalReplace(
            at: 0, old: "\u{1F600}", new: "\u{1F601}"
        )
        XCTAssertEqual(ops, [.del(at: 0, len: 2), .ins(at: 0, text: "\u{1F601}")])
    }

    func testBlockLabelShowsOneStampWhenUntouchedSinceCreation() {
        XCTAssertEqual(
            InkEditorView.Coordinator.blockLabel(createdS: 1_000, modifiedS: 1_000),
            InkEditorView.Coordinator.blockLabel(createdS: 1_000, modifiedS: nil),
            "modified equal to (or absent alongside) created reads as one stamp"
        )
        XCTAssertFalse(
            InkEditorView.Coordinator.blockLabel(createdS: 1_000, modifiedS: 1_000).contains("→")
        )
    }

    /// The format keeps no seconds, so two instants inside the same
    /// minute render identically and must collapse to one stamp: a
    /// block touched forty seconds after its first commit is not a
    /// range worth printing. (Epoch minutes end at multiples of 60, and
    /// every real timezone offset is a whole number of minutes, so
    /// 1_000 and 1_019 share a rendered minute in any locale.)
    func testBlockLabelCollapsesAnEditWithinTheSameRenderedMinute() {
        let label = InkEditorView.Coordinator.blockLabel(createdS: 1_000, modifiedS: 1_019)
        XCTAssertFalse(label.contains("→"), "same rendered minute, so one stamp")
        XCTAssertEqual(label, InkEditorView.Coordinator.blockLabel(createdS: 1_000, modifiedS: nil))
    }

    /// One minute over the boundary is a range again: the collapse is
    /// about identical stamps, not about nearness.
    func testBlockLabelKeepsTheRangeAcrossAMinuteBoundary() {
        XCTAssertTrue(
            InkEditorView.Coordinator.blockLabel(createdS: 1_000, modifiedS: 1_060).contains("→")
        )
    }

    /// The format repeats every week: a modification exactly seven days
    /// after creation renders the same `EEE HH:mm` text while being a
    /// different moment entirely. The collapse compares the dates at
    /// minute granularity, not the rendered stamps, so the range
    /// survives the aliasing.
    func testBlockLabelKeepsTheRangeAcrossExactlyOneWeek() {
        XCTAssertTrue(
            InkEditorView.Coordinator.blockLabel(createdS: 1_000, modifiedS: 1_000 + 604_800)
                .contains("→"),
            "a week-later edit renders the same stamp text but is not the same minute"
        )
    }

    func testBlockLabelShowsBothStampsOnceEdited() {
        XCTAssertTrue(
            InkEditorView.Coordinator.blockLabel(createdS: 1_000, modifiedS: 2_000).contains("→"),
            "a block touched after its first commit shows created and modified"
        )
    }
}

/// The live wiring: a real storage with the coordinator as its
/// delegate over a real core, exactly as the mounted editor stands.
/// Each case asserts what crossed the seam and that the projection
/// still mirrors the document afterwards.
@MainActor
final class DocumentOpsWiringTests: XCTestCase {
    private var model: PageModel!
    private var coordinator: InkEditorView.Coordinator!
    private var textView: InkTextView!
    private var sheet: UInt64 = 0
    private var batches: [[DocumentEditOp]] = []

    // Not a setUp override: those are nonisolated, and this fixture is
    // main-actor state. Every test calls it first.
    private func makeEditor() {
        // A throwaway defaults domain, and a model that rests entirely
        // in temporary space: no state file is loaded or written here
        // (loadStateIfNeeded is never called, and markDirty stands down
        // for an unloaded session), but nothing about this suite is
        // worth the installed app's own files being within reach.
        let defaults = UserDefaults(suiteName: "companion-kit-ops-tests")!
        defaults.removePersistentDomain(forName: "companion-kit-ops-tests")
        model = isolatedModel(defaults: defaults)
        model.newPage()
        sheet = model.selection!

        // The editor's TextKit 1 stack, assembled as makeNSView wires
        // it: one layout manager over the page's cached storage, the
        // coordinator as storage delegate.
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

    /// Keystrokes, not a paste: each piece arrives as its own edit,
    /// which is what makes a typed newline a block boundary. A passage
    /// handed over whole, newlines and all, is a paste and stays one
    /// block (ADR-0013).
    private func type(_ pieces: String...) {
        for piece in pieces {
            textView.insertText(piece, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// The core's document, read back through the seam.
    private func coreRuns() -> [RestoredRun] {
        model.coreClient.documentRuns(sheet: sheet)
    }

    /// The block labels currently mounted over the page (ADR-0013):
    /// plain subviews of the text view, one per block that has a
    /// created stamp.
    private func labelFields() -> [NSTextField] {
        textView.subviews.compactMap { $0 as? NSTextField }
    }

    private func assertParity(file: StaticString = #filePath, line: UInt = #line) {
        let shell = InkEditorView.Coordinator.runs(of: storage)
        let core = coreRuns()
        XCTAssertEqual(shell.count, core.count, "run counts diverged", file: file, line: line)
        for (ours, theirs) in zip(shell, core) {
            switch (ours, theirs) {
            case (.ink(let a), .ink(let b)):
                XCTAssertEqual(a, b, file: file, line: line)
            case (.chip(let a), .chip(let b)):
                XCTAssertEqual(a, b.chipId, file: file, line: line)
            default:
                XCTFail("run kinds diverged", file: file, line: line)
            }
        }
    }

    func testProjectionParityOverARandomEditScript() {
        makeEditor()
        // A seeded generator, so a failure replays.
        var generator = SplitMix64(seed: 0x0EED)
        let alphabet: [String] = ["a", "b", " ", "\n", "\u{1F600}", "\u{00E9}", "\u{1F680}", "#"]
        for _ in 0..<200 {
            let text = storage.string as NSString
            let length = text.length
            if length > 0, generator.next() % 3 == 0 {
                // A deletion over a range snapped to character
                // boundaries, the way every real edit arrives.
                let start = Int(generator.next() % UInt64(length))
                let span = Int(generator.next() % 4)
                var range = NSRange(location: start, length: min(span, length - start))
                range = text.rangeOfComposedCharacterSequences(for: range)
                storage.replaceCharacters(in: range, with: "")
            } else {
                let at = length == 0 ? 0 : Int(generator.next() % UInt64(length + 1))
                let boundary = text.rangeOfComposedCharacterSequences(
                    for: NSRange(location: min(at, length), length: 0))
                let piece = alphabet[Int(generator.next() % UInt64(alphabet.count))]
                storage.replaceCharacters(
                    in: NSRange(location: boundary.location, length: 0), with: piece)
            }
            assertParity()
        }
        XCTAssertFalse(batches.isEmpty)
    }

    func testAnImeCompositionCommitProducesOneBatch() {
        makeEditor()
        textView.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        batches = []
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        // Compose, revise, commit: the marked stages must stay off the
        // seam; only the resolved text crosses, as one batch.
        textView.setMarkedText(
            "ka", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setMarkedText(
            "kan", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(batches.count, 0, "marked text leaked ops")
        textView.insertText(
            "\u{304B}\u{3093}", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(batches.count, 1, "a commit is one batch")
        XCTAssertEqual(batches.first, [.ins(at: 2, text: "\u{304B}\u{3093}")])
        assertParity()
    }

    func testAnAbandonedImeCompositionProducesZeroOps() {
        makeEditor()
        textView.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        batches = []
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.setMarkedText(
            "ka", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        // Esc: the composition dies; the ADR forbids phantom ops, so
        // NOTHING may have crossed the seam.
        textView.setMarkedText(
            "", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.unmarkText()
        XCTAssertEqual(batches, [], "an abandoned composition left phantom ops")
        XCTAssertEqual(storage.string, "ab")
        assertParity()
    }

    /// A page switch arriving mid-composition, which ⌘2 is: a key
    /// equivalent the input method does not swallow. One editor serves
    /// every page and the switch swaps the storage underneath it
    /// (ADR-0006), so the composition has to end on the page it was
    /// typed on, before the page under it changes. Nothing may still be
    /// marked afterwards, and nothing may be left in flight for the
    /// incoming page to inherit (issue #23).
    func testASwitchMidCompositionEndsItOnThePageItWasTypedOn() {
        makeEditor()
        textView.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        batches = []
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.setMarkedText(
            "ka", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText(), "nothing was composed, so nothing is at stake")
        XCTAssertEqual(batches.count, 0, "marked text leaked ops")

        InkEditorView.discardComposition(in: textView)

        XCTAssertFalse(
            textView.hasMarkedText(),
            "the composition would have crossed the swap into another page's offsets"
        )
        XCTAssertNil(
            coordinator.imeComposition,
            "the composition settled on its own page rather than staying in flight"
        )
        // Whatever the input method had provisionally placed belongs to
        // this page and stays here, in the storage and in the core
        // alike. What must not happen is a divergence between them.
        assertParity()
    }

    func testSealSelectionReplacesTheSelectionCoreSide() {
        makeEditor()
        textView.insertText(
            "a\u{1F600} SECRET tail", replacementRange: NSRange(location: NSNotFound, length: 0))
        // Select "SECRET" past the astral prefix: a(0) emoji(1,2)
        // space(3) S(4)..T(9).
        textView.setSelectedRange(NSRange(location: 4, length: 6))
        batches = []
        coordinator.sealSelectionOrLine()

        // The selection left the body core-side and the sentinel stands
        // in its place; the projection write is guarded, so no op
        // crossed for it.
        XCTAssertEqual(batches, [], "the seal's projection write leaked ops")
        let runs = coreRuns()
        XCTAssertEqual(runs.count, 3)
        guard case .ink(let head) = runs[0], case .chip = runs[1],
              case .ink(let tail) = runs[2]
        else {
            return XCTFail("unexpected shape after a range seal: \(runs)")
        }
        XCTAssertEqual(head, "a\u{1F600} ")
        XCTAssertEqual(tail, " tail")
        XCTAssertFalse(storage.string.contains("SECRET"))
        // The caret sits just past the chip, and sealing is not
        // undoable.
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertEqual(textView.undoManager?.canUndo, false)
        assertParity()
    }

    func testAnUndoResurrectingADeadChipIsStrippedSilently() {
        makeEditor()
        textView.insertText(
            "seal me", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: 7))
        coordinator.sealSelectionOrLine()
        guard case .chip(let face)? = coreRuns().first else {
            return XCTFail("the seal left no chip")
        }
        // The chip dies (deleted whole, as backspace would).
        storage.deleteCharacters(in: NSRange(location: 0, length: 1))
        XCTAssertTrue(coreRuns().isEmpty)
        // A stale undo replays the attachment: the core rejects the
        // chip op, recovery strips the glyph, and no chip returns,
        // because undo never un-seals.
        storage.insert(
            InkEditorView.Coordinator.chipString(
                ChipInfo(
                    chipId: face.chipId, kind: face.kind, excerpt: face.excerpt,
                    sizeLabel: face.sizeLabel, concealed: face.concealed)),
            at: 0
        )
        XCTAssertFalse(InkEditorView.Coordinator.runs(of: storage).contains {
            if case .chip = $0 { true } else { false }
        }, "the dead chip's glyph survived recovery")
        XCTAssertTrue(coreRuns().isEmpty)
        assertParity()
    }

    // MARK: Block labels (ADR-0013: created/modified above each block)

    func testAFreshEmptyPageCarriesNoBlockLabel() {
        makeEditor()
        XCTAssertTrue(labelFields().isEmpty, "no committed content, nothing to stamp")
    }

    func testTypingCommitsAndLabelsItsBlock() {
        makeEditor()
        type("alpha")
        let labels = labelFields()
        XCTAssertEqual(labels.count, 1)
        XCTAssertFalse(labels[0].stringValue.isEmpty)
    }

    func testASplitParagraphGetsItsOwnLabel() {
        makeEditor()
        type("alpha", "\n", "beta")
        XCTAssertEqual(labelFields().count, 2, "each typed line stamps separately")
    }

    func testBlankLinesBetweenParagraphsAreNotStamped() {
        makeEditor()
        type("alpha", "\n", "\n", "\n", "   ", "\n", "beta")
        XCTAssertEqual(
            labelFields().count, 2,
            "spacing between paragraphs is not writing, so it carries no visible stamp"
        )
    }

    /// The paste rule (ADR-0013): lines that arrived together stay
    /// together, so the page shows one time above the passage instead of
    /// the same time repeated down its margin.
    func testAPastedPassageCarriesOneLabelAboveItsFirstLine() {
        makeEditor()
        // One edit carrying its own newlines: the shape ⌘V delivers, and
        // the shape the core reads as a single block.
        textView.insertText(
            "one\ntwo\nthree", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(labelFields().count, 1, "one stamp for the whole paste")
        let layout = coordinator.blockLabelLayout
        XCTAssertEqual(layout.count, 1)
        XCTAssertEqual(
            layout[0].range, NSRange(location: 0, length: 4),
            "the stamp sits above the paste's first line, not above every line"
        )

        // What the reader types after it is their own block, stamped
        // separately.
        type("\n", "mine")
        XCTAssertEqual(labelFields().count, 2)
        XCTAssertEqual(coordinator.blockLabelLayout.last?.range.location, 14)
    }

    /// A fence typed line by line is one block per line core-side, but
    /// the eye reads the fence as one slab, so the display coalesces
    /// the region under a single stamp above the opening rule.
    func testAFenceTypedLineByLineCarriesOneLabel() {
        makeEditor()
        type("```", "\n", "let x = 1", "\n", "```")
        XCTAssertEqual(labelFields().count, 1, "one stamp for the whole fence region")
        let layout = coordinator.blockLabelLayout
        XCTAssertEqual(layout.count, 1)
        XCTAssertEqual(
            layout[0].range, NSRange(location: 0, length: 4),
            "the stamp sits above the opening rule, not above every line"
        )
    }

    /// The closing rule ends the region: what the reader types after it
    /// is prose again, stamped on its own.
    func testABlockAfterTheClosingFenceStampsSeparately() {
        makeEditor()
        type("```", "\n", "code", "\n", "```", "\n", "after")
        XCTAssertEqual(labelFields().count, 2, "the fence is one stamp, the prose after another")
        XCTAssertEqual(
            coordinator.blockLabelLayout.last?.range.location, 13,
            "the second stamp belongs to the line below the closing rule"
        )
    }

    /// A fence left open holds to the last line of the page, exactly as
    /// the styling already reads it: the region, and its single stamp,
    /// run to the end.
    func testAnUnclosedFenceStillCoalescesToOneLabel() {
        makeEditor()
        type("```", "\n", "still code", "\n", "more code")
        XCTAssertEqual(labelFields().count, 1)
        XCTAssertEqual(coordinator.blockLabelLayout.first?.range.location, 0)
    }

    /// The region's stamp spans the blocks it covers: earliest created
    /// to latest touch, rendered through the same collapse rule a lone
    /// block's label follows. The wiring above cannot hold the clock
    /// still, so the span math is asserted on the pure function.
    func testAFenceRegionLabelSpansEarliestToLatest() {
        XCTAssertEqual(
            InkEditorView.Coordinator.fenceRegionLabel(stamps: [
                (createdS: 2_000, modifiedS: nil),
                (createdS: 1_000, modifiedS: 1_000),
                (createdS: 3_000, modifiedS: 9_000),
            ]),
            InkEditorView.Coordinator.blockLabel(createdS: 1_000, modifiedS: 9_000)
        )
        // Created counts as the latest touch for a block never modified.
        XCTAssertEqual(
            InkEditorView.Coordinator.fenceRegionLabel(stamps: [
                (createdS: 1_000, modifiedS: nil),
                (createdS: 5_000, modifiedS: nil),
            ]),
            InkEditorView.Coordinator.blockLabel(createdS: 1_000, modifiedS: 5_000)
        )
        // A region with no committed content wears nothing.
        XCTAssertNil(
            InkEditorView.Coordinator.fenceRegionLabel(stamps: [
                (createdS: nil, modifiedS: nil)
            ])
        )
    }

    /// The gap a labeled block reserves is above its own first line, so
    /// the label has to land inside that gap. Placing it against the
    /// line fragment rect instead drops it onto the previous
    /// paragraph's last line, which is what the screen showed.
    func testALabelSitsInItsOwnGapAndNotOnThePrecedingLine() {
        makeEditor()
        type("alpha", "\n", "beta")
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return XCTFail("the editor's TextKit stack is missing")
        }
        layoutManager.ensureLayout(for: container)
        coordinator.repositionBlockLabels()
        let labels = labelFields().sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(labels.count, 2)

        let origin = textView.textContainerOrigin
        // Where "alpha" and "beta" actually draw.
        let first = layoutManager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        let second = layoutManager.lineFragmentUsedRect(forGlyphAt: 6, effectiveRange: nil)

        XCTAssertGreaterThanOrEqual(labels[0].frame.minY, 0, "the top label stays on screen")
        XCTAssertLessThanOrEqual(
            labels[0].frame.maxY, origin.y + first.minY,
            "the top label clears the first line it belongs to"
        )
        XCTAssertGreaterThanOrEqual(
            labels[1].frame.minY, origin.y + first.maxY,
            "the second label clears the paragraph above it"
        )
        XCTAssertLessThanOrEqual(
            labels[1].frame.maxY, origin.y + second.minY,
            "the second label clears the line it belongs to"
        )
    }
}

/// A tiny deterministic generator, so the random edit script replays
/// identically on failure.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
