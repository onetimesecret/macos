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
        ChipInfo(chipId: id, kind: "text", excerpt: "ch…ip", sizeLabel: "tiny", concealed: false)
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

    func testContainsChipRejectsInvalidRangesWithoutEnumerating() {
        let storage = NSTextStorage(string: "ink")
        let invalidRanges = [
            NSRange(location: NSNotFound, length: 0),
            NSRange(location: storage.length + 1, length: 0),
            NSRange(location: storage.length, length: 1),
            NSRange(location: Int.max - 1, length: 10),
        ]

        for range in invalidRanges {
            XCTAssertFalse(
                InkEditorView.Coordinator.containsChip(storage, in: range),
                "invalid range \(range) must not be enumerated"
            )
        }
    }

    func testContainsChipRetainsValidRangeBehavior() {
        let storage = NSTextStorage(string: "ab")
        storage.insert(InkEditorView.Coordinator.chipString(chipInfo(id: 7)), at: 1)

        XCTAssertFalse(
            InkEditorView.Coordinator.containsChip(
                storage, in: NSRange(location: 0, length: 1)))
        XCTAssertTrue(
            InkEditorView.Coordinator.containsChip(
                storage, in: NSRange(location: 1, length: 1)))
        XCTAssertFalse(
            InkEditorView.Coordinator.containsChip(
                storage, in: NSRange(location: storage.length, length: 0)))
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

    func testBlockDetailsStayAbsentUntilARealEditExists() {
        XCTAssertNil(InkEditorView.Coordinator.blockDetails(createdS: 1_000, modifiedS: 1_000))
        XCTAssertNil(InkEditorView.Coordinator.blockDetails(createdS: 1_000, modifiedS: 999))
    }

    /// First and last keystrokes are separate core touches. Collapsing
    /// one rendered minute keeps ordinary typing from making nearly
    /// every freshly written block claim it was edited.
    func testBlockDetailsCollapseTouchesInsideTheSameMinute() {
        XCTAssertNil(
            InkEditorView.Coordinator.blockDetails(createdS: 1_000, modifiedS: 1_019)
        )
    }

    func testBlockDetailsUseCheckpointDayContextForSameDayEdits() throws {
        let created = Date(timeIntervalSince1970: 3_600)
        let details = try XCTUnwrap(
            InkEditorView.Coordinator.blockDetails(createdS: 3_600, modifiedS: 7_200)
        )
        let readings = details.components(separatedBy: " · ")
        XCTAssertEqual(readings.count, 2, "details should retain their semantic separator")
        let weekday = DateFormatter()
        weekday.dateFormat = "EEE"
        XCTAssertFalse(
            readings.contains { $0.contains(weekday.string(from: created)) },
            "same-day details should omit weekday context"
        )
    }

    func testBlockDetailsRestoreWeekdaysForCrossDayEdits() throws {
        let calendar = Calendar.current
        let created = calendar.startOfDay(for: Date())
        let modified = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: created))
        let details = try XCTUnwrap(InkEditorView.Coordinator.blockDetails(
            createdS: Int64(created.timeIntervalSince1970),
            modifiedS: Int64(modified.timeIntervalSince1970)
        ))
        let readings = details.components(separatedBy: " · ")
        XCTAssertEqual(readings.count, 2, "details should retain their semantic separator")
        let weekday = DateFormatter()
        weekday.dateFormat = "EEE"
        XCTAssertTrue(readings[0].contains(weekday.string(from: created)))
        XCTAssertTrue(readings[1].contains(weekday.string(from: modified)))
    }

    func testBlockDetailsUseTheLocaleAndTimeZoneOfTheCurrentRender() throws {
        let created = Date(timeIntervalSince1970: 0)
        let modified = Date(timeIntervalSince1970: 3_600)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let pacific = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let us = Locale(identifier: "en_US")
        let french = Locale(identifier: "fr_FR")
        let frenchResourceURL = try XCTUnwrap(
            Bundle.module.url(forResource: "fr", withExtension: "lproj")
        )
        let frenchBundle = try XCTUnwrap(Bundle(path: frenchResourceURL.path))

        func time(_ date: Date, _ locale: Locale, _ timeZone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate("jm")
            return formatter.string(from: date)
        }
        func accessibilityDate(_ date: Date, _ locale: Locale, _ timeZone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        let usUTC = try XCTUnwrap(InkEditorView.Coordinator.blockDetails(
            createdS: 0, modifiedS: 3_600, locale: us, timeZone: utc
        ))
        let frenchPacific = try XCTUnwrap(InkEditorView.Coordinator.blockDetails(
            createdS: 0, modifiedS: 3_600, locale: french, timeZone: pacific, bundle: frenchBundle
        ))

        XCTAssertEqual(
            usUTC,
            "created \(time(created, us, utc)) · edited \(time(modified, us, utc))"
        )
        XCTAssertEqual(
            frenchPacific,
            "créé le \(time(created, french, pacific)) · modifié le \(time(modified, french, pacific))"
        )
        XCTAssertEqual(
            InkEditorView.Coordinator.blockAccessibilityText(
                createdS: 0, modifiedS: 3_600,
                locale: french, timeZone: pacific, bundle: frenchBundle
            ),
            "Créé le \(accessibilityDate(created, french, pacific)) ; modifié le \(accessibilityDate(modified, french, pacific))"
        )
        XCTAssertEqual(
            frenchBundle.localizedString(forKey: "edited", value: nil, table: nil), "modifié"
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

    /// The compact metadata affordances currently mounted over the page
    /// (ADR-0013): plain subviews of the text view, one per edited block.
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
        // The new object is selected (D-30), and sealing is not
        // undoable.
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 1))
        XCTAssertNil(textView.undoManager, "AppKit is vending a stack for a page it does not own")
        assertParity()
    }

    func testSealingSelectsTheNewObject() {
        makeEditor()
        textView.insertText(
            "head SECRET tail", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 5, length: 6))
        coordinator.sealSelectionOrLine()

        // The selection covers exactly the sentinel character, so the
        // transformation is visible where it happened rather than the
        // caret sitting quietly after it.
        let selected = textView.selectedRange()
        XCTAssertEqual(selected, NSRange(location: 5, length: 1))
        XCTAssertTrue(
            InkEditorView.Coordinator.containsChip(storage, in: selected),
            "the selection is the chip, not the ink beside it")
        XCTAssertEqual((storage.string as NSString).character(at: 5), 0xFFFC)
        assertParity()
    }

    func testSealedPasteOverAChipIsRefused() {
        makeEditor()
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()
        guard case .chip(let sealed)? = coreRuns().dropFirst().first else {
            return XCTFail("the seal left no chip")
        }
        // A selection that swallows the chip: "b", the chip, " c".
        textView.setSelectedRange(NSRange(location: 1, length: 4))
        batches = []
        model.notice = nil
        coordinator.sealedPaste()

        // A chip leaves the page only by an act aimed at it (D-08). The
        // chord refuses with the line, no delete crosses the seam, and
        // the chip is still standing core-side with the ink around it.
        XCTAssertEqual(model.notice, InkEditorView.Coordinator.alreadySealedLine)
        XCTAssertEqual(batches, [], "a refused seal must emit no ops")
        XCTAssertEqual(coreRuns().count, 3)
        guard case .chip(let still)? = coreRuns().dropFirst().first else {
            return XCTFail("the refused seal reaped the chip")
        }
        XCTAssertEqual(still.chipId, sealed.chipId)
        XCTAssertEqual(storage.string.utf16.count, 7, "ab, space, the chip, space, cd")
        assertParity()
    }

    func testTheChipMenuOffersPlaintextByName() throws {
        XCTAssertEqual(
            InkEditorView.Coordinator.chipMenuTitles,
            ["Copy decrypted contents", "Create one-time link…", "Remove protected content"])
        makeEditor()
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()

        // The two egresses and the separated removal (D-29), every
        // action aimed at the coordinator that owns the chip. Locate
        // actions semantically so adding another item does not break an
        // unrelated contract.
        let menu = NSMenu()
        coordinator.appendChipItems(to: menu, at: 3)
        let copy = try XCTUnwrap(
            menu.items.first { $0.title == "Copy decrypted contents" })
        let link = try XCTUnwrap(
            menu.items.first { $0.title == "Create one-time link…" })
        let remove = try XCTUnwrap(
            menu.items.first { $0.title == "Remove protected content" })
        XCTAssertTrue(menu.items.contains { $0.isSeparatorItem })
        // The two egresses come first, in the order D-41 renders them,
        // and the separator keeps the removal below both.
        let copyIndex = try XCTUnwrap(menu.items.firstIndex(of: copy))
        let linkIndex = try XCTUnwrap(menu.items.firstIndex(of: link))
        let removalIndex = try XCTUnwrap(menu.items.firstIndex(of: remove))
        let separatorIndex = try XCTUnwrap(
            menu.items.firstIndex(where: \.isSeparatorItem))
        XCTAssertLessThan(copyIndex, linkIndex)
        XCTAssertLessThan(linkIndex, separatorIndex)
        XCTAssertGreaterThan(removalIndex, separatorIndex)
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(item.target === coordinator, "\(item.title) is not the coordinator's")
        }
        // Ink offers no chip items at all.
        let ink = NSMenu()
        coordinator.appendChipItems(to: ink, at: 0)
        XCTAssertTrue(ink.items.isEmpty)
    }

    func testTheContextMenuOffersSealSelectionOverInkOnly() {
        makeEditor()
        textView.isEditable = true
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))

        // Nothing selected: no row, and the Edit menu item is dimmed.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.refreshLanguageActionAvailability()
        XCTAssertFalse(model.sealActions.canSeal)
        let bare = NSMenu()
        coordinator.appendSealItem(to: bare)
        XCTAssertTrue(bare.items.isEmpty)

        // Ink selected: the row is offered and runs the seal (D-30).
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.refreshLanguageActionAvailability()
        XCTAssertTrue(model.sealActions.canSeal)
        let offered = NSMenu()
        coordinator.appendSealItem(to: offered)
        XCTAssertEqual(offered.items.map(\.title), [SealSelectionMenu.contextMenuTitle])
        XCTAssertTrue(offered.items[0].target === coordinator)
        coordinator.sealSelectionOrLine()

        // A selection holding the chip: the row is withheld, because
        // it would only refuse; the Edit item stays enabled so the
        // refusal is said rather than hidden.
        textView.setSelectedRange(NSRange(location: 1, length: 4))
        coordinator.refreshLanguageActionAvailability()
        XCTAssertTrue(model.sealActions.canSeal)
        let overChip = NSMenu()
        coordinator.appendSealItem(to: overChip)
        XCTAssertTrue(overChip.items.isEmpty)
        model.notice = nil
        textView.sealSelectedContent(nil)
        XCTAssertEqual(model.notice, InkEditorView.Coordinator.alreadySealedLine)
        assertParity()
    }

    func testAClickOnAChipSelectsItWhole() throws {
        makeEditor()
        textView.insertText(
            "ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let attachment = try XCTUnwrap(
            storage.attribute(.attachment, at: 3, effectiveRange: nil) as? ChipAttachment)
        let cell = try XCTUnwrap(attachment.attachmentCell)

        // A plain click selects the whole object and never places a
        // caret inside it (D-28); no menu opens on the click.
        coordinator.textView(textView, clickedOn: cell, in: .zero, at: 3)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 1))
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

    // MARK: Block metadata (ADR-0013: compact edited affordance)

    func testAFreshEmptyPageCarriesNoBlockLabel() {
        makeEditor()
        XCTAssertTrue(labelFields().isEmpty, "no committed content, nothing to stamp")
    }

    func testTypingAnUntouchedBlockAddsNoMetadataChrome() {
        makeEditor()
        type("alpha")
        XCTAssertTrue(labelFields().isEmpty)
        XCTAssertTrue(coordinator.blockLabelLayout.isEmpty)
    }

    func testUntouchedParagraphsReserveNoMetadataRows() {
        makeEditor()
        type("alpha", "\n", "beta")
        storage.enumerateAttribute(
            .paragraphStyle, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            XCTAssertEqual((value as? NSParagraphStyle)?.paragraphSpacingBefore, 0)
        }
        XCTAssertEqual(
            textView.textContainerInset.height, InkEditorView.Coordinator.topInset,
            "metadata must not enlarge the page's top inset"
        )
    }

    func testOnlyEditedBlocksProduceAnAffordance() {
        let storage = NSTextStorage(string: "first\nsecond")
        let result = InkEditorView.Coordinator.applyMarkdownStyling(
            to: storage, sheet: 1,
            blockMetas: [
                BlockInfo(id: "first", createdS: 1_000, modifiedS: 1_000, paragraphs: 1),
                BlockInfo(id: "second", createdS: 2_000, modifiedS: 3_000, paragraphs: 1),
            ],
            syntaxHighlightingEnabled: false, fenceRenderingLanguages: [:]
        )
        XCTAssertEqual(result.displays.count, 1)
        XCTAssertEqual(result.displays[0].range.location, 6)
        XCTAssertEqual(result.displays[0].compactText, "edited")
        XCTAssertTrue(result.displays[0].detailText.contains("created"))
        XCTAssertTrue(result.displays[0].detailText.contains("edited"))
    }

    /// A block can open on an empty paragraph — a paste that kept its
    /// leading blank, a return pressed before the words arrived. The
    /// affordance belongs to the first line a reader can see, not to
    /// the whitespace above it, or it floats free of the words it
    /// describes.
    func testAnAffordanceSkipsItsBlockLeadingBlankLine() {
        let storage = NSTextStorage(string: "alpha\n\nbeta words")
        let result = InkEditorView.Coordinator.applyMarkdownStyling(
            to: storage, sheet: 1,
            blockMetas: [
                BlockInfo(id: "alpha", createdS: 1_000, modifiedS: 1_000, paragraphs: 1),
                BlockInfo(id: "beta", createdS: 2_000, modifiedS: 3_000, paragraphs: 2),
            ],
            syntaxHighlightingEnabled: false, fenceRenderingLanguages: [:]
        )
        XCTAssertEqual(result.displays.count, 1)
        XCTAssertEqual(
            result.displays[0].range, NSRange(location: 7, length: 10),
            "the affordance rode the block's blank opening line"
        )
    }

    /// The display still treats a fence as one visual region, but its
    /// metadata now rides the opening rule instead of reserving a row.
    func testAFenceCoalescesToOneEditedAffordance() {
        let storage = NSTextStorage(string: "```\ncode\n```")
        let result = InkEditorView.Coordinator.applyMarkdownStyling(
            to: storage, sheet: 1,
            blockMetas: [
                BlockInfo(id: "open", createdS: 1_000, modifiedS: 1_000, paragraphs: 1),
                BlockInfo(id: "body", createdS: 2_000, modifiedS: 2_000, paragraphs: 1),
                BlockInfo(id: "close", createdS: 3_000, modifiedS: 4_000, paragraphs: 1),
            ],
            syntaxHighlightingEnabled: false, fenceRenderingLanguages: [:]
        )
        XCTAssertEqual(result.displays.count, 1)
        XCTAssertEqual(result.displays[0].range, NSRange(location: 0, length: 4))
        XCTAssertEqual(result.displays[0].logicalRange, NSRange(location: 0, length: storage.length))
    }

    func testCaretFocusCoversTheCompleteLogicalBlock() {
        let storage = NSTextStorage(string: "first\nsecond")
        let result = InkEditorView.Coordinator.applyMarkdownStyling(
            to: storage, sheet: 1,
            blockMetas: [
                BlockInfo(id: "paste", createdS: 1_000, modifiedS: 3_000, paragraphs: 2)
            ],
            syntaxHighlightingEnabled: false, fenceRenderingLanguages: [:]
        )
        XCTAssertEqual(result.displays.count, 1)
        XCTAssertEqual(
            InkEditorView.Coordinator.blockFocusLocation(
                for: NSRange(location: 7, length: 0), in: result.displays,
                documentLength: storage.length
            ),
            result.displays[0].range.location,
            "the second paragraph belongs to the same logical block"
        )
    }

    func testTimestampSpanUsesTheEarliestCreationAndLatestTouch() throws {
        let span = try XCTUnwrap(InkEditorView.Coordinator.timestampSpan(for: [
            (createdS: 2_000, modifiedS: nil),
            (createdS: 1_000, modifiedS: 1_000),
            (createdS: 3_000, modifiedS: 9_000),
        ]))
        XCTAssertEqual(span.createdS, 1_000)
        XCTAssertEqual(span.modifiedS, 9_000)
        XCTAssertNil(InkEditorView.Coordinator.timestampSpan(for: [
            (createdS: nil, modifiedS: nil)
        ]))
    }

    func testAffordanceOriginIsTrailingAlignedAndVerticallyCentered() {
        let origin = InkEditorView.Coordinator.blockAffordanceOrigin(
            firstLine: NSRect(x: 8, y: 40, width: 220, height: 24),
            containerWidth: 500, containerOrigin: NSPoint(x: 12, y: 16),
            affordanceSize: NSSize(width: 90, height: 20)
        )
        XCTAssertEqual(origin.x, 416)
        XCTAssertEqual(origin.y, 58)
    }

    /// A short line lends the affordance its margin; a line that runs to
    /// the measure has none to lend, and the wide reading stands down
    /// rather than draw itself over the words it describes.
    func testAFullMeasureLineRefusesTheWideReading() {
        XCTAssertTrue(InkEditorView.Coordinator.blockAffordanceFits(
            lineMaxX: 200, containerWidth: 500, affordanceWidth: 180
        ))
        XCTAssertFalse(InkEditorView.Coordinator.blockAffordanceFits(
            lineMaxX: 480, containerWidth: 500, affordanceWidth: 180
        ))
        // Exactly flush counts as room: gap, pill and trailing inset
        // together reach the measure and no further.
        XCTAssertTrue(InkEditorView.Coordinator.blockAffordanceFits(
            lineMaxX: 306, containerWidth: 500, affordanceWidth: 180
        ))
        XCTAssertFalse(InkEditorView.Coordinator.blockAffordanceFits(
            lineMaxX: 307, containerWidth: 500, affordanceWidth: 180
        ))
    }

    /// In no-wrap mode TextKit's container is unbounded while the text
    /// view grows with the document. The affordance instead follows the
    /// document view's actual visible viewport. Its leading container
    /// origin must be removed because `blockAffordanceOrigin` adds it
    /// back when translating container coordinates into view coordinates.
    func testAnUnboundedContainerUsesTheVisibleViewportWithoutDoubleCountingInsets() {
        let visibleRect = NSRect(x: 200, y: 0, width: 640, height: 320)
        let measure = InkEditorView.Coordinator.blockAffordanceMeasure(
            containerWidth: .greatestFiniteMagnitude,
            visibleRect: visibleRect, containerOriginX: 12
        )
        XCTAssertEqual(measure, 828)
        let origin = InkEditorView.Coordinator.blockAffordanceOrigin(
            firstLine: .zero, containerWidth: measure,
            containerOrigin: NSPoint(x: 12, y: 0), affordanceSize: NSSize(width: 90, height: 20)
        )
        XCTAssertEqual(
            origin.x, visibleRect.maxX - 90 - InkEditorView.Coordinator.blockLabelTrailingInset
        )
        XCTAssertEqual(
            InkEditorView.Coordinator.blockAffordanceMeasure(
                containerWidth: SealedBlockCell.effectivelyUnboundedWidth,
                visibleRect: visibleRect, containerOriginX: 12
            ),
            measure
        )
        // A wrapped page remains constrained by its text container rather
        // than taking the wider viewport during a resize.
        XCTAssertEqual(
            InkEditorView.Coordinator.blockAffordanceMeasure(
                containerWidth: 500, visibleRect: visibleRect, containerOriginX: 12
            ),
            500
        )
        XCTAssertFalse(
            InkEditorView.Coordinator.blockAffordanceFits(
                lineMaxX: 810, containerWidth: measure, affordanceWidth: 18
            ),
            "the wide reading fit beyond the visible viewport"
        )
    }

    /// The pill's border is a dynamic colour flattened to a CGColor, the
    /// one place where a light-mode answer would otherwise be kept
    /// through a switch to dark.
    func testThePillsWashesFollowTheAppearance() {
        let field = BlockMetadataField(labelWithString: "edited")
        field.wantsLayer = true
        field.layer?.borderWidth = 1

        field.appearance = NSAppearance(named: .aqua)
        field.refreshPillColors()
        let light = field.layer?.borderColor?.components
        XCTAssertNotNil(light)

        field.appearance = NSAppearance(named: .darkAqua)
        field.refreshPillColors()
        let dark = field.layer?.borderColor?.components
        XCTAssertNotNil(dark)

        XCTAssertNotEqual(light, dark, "the border kept its light-mode reading")
    }

    /// The pill refuses the hit test so the caret can land behind it.
    /// Metadata supplements, rather than replaces, AppKit's text children
    /// so VoiceOver text navigation remains present.
    func testThePageAddsItsAffordancesToExistingAccessibilityChildren() {
        makeEditor()
        let textNavigationChild = NSView(frame: .zero)
        textView.setAccessibilityChildren([textNavigationChild])
        type("alpha")
        // A block typed just now reads as untouched and mints no pill,
        // so the page is handed stamps that make it an edited one. Age
        // is the one thing a test cannot wait for.
        coordinator.layOutBlockLabels(forMetas: [
            BlockInfo(id: "alpha", createdS: 1_000, modifiedS: 300_000, paragraphs: 1)
        ])
        let field = try! XCTUnwrap(labelFields().first, "the fixture minted no affordance")
        let children = textView.accessibilityChildren()
        XCTAssertNotNil(children, "the text view declared no AX children")
        XCTAssertTrue(
            children?.contains { ($0 as AnyObject) === textNavigationChild } == true,
            "metadata replaced the text view's existing accessibility children"
        )
        XCTAssertTrue(
            children?.contains { ($0 as AnyObject) === field } == true,
            "the metadata pill was not exposed to assistive technology"
        )
        XCTAssertTrue(field.accessibilityLabel()?.hasPrefix("Created ") == true)
    }

    /// The tooltip owner must outlive the loop that registered it.
    /// AppKit holds the owner weakly, so a bridged string would be gone
    /// before the first hover; the coordinator answers instead, out of a
    /// table it rebuilds whenever it rebuilds the rects.
    func testTheRowsTooltipSurvivesTheLoopThatRegisteredIt() {
        makeEditor()
        type("alpha")
        coordinator.layOutBlockLabels(forMetas: [
            BlockInfo(id: "alpha", createdS: 1_000, modifiedS: 300_000, paragraphs: 1)
        ])
        let tags = coordinator.blockToolTipTags
        XCTAssertEqual(tags.count, 1, "the edited row registered no tooltip")
        let text = coordinator.view(
            textView, stringForToolTip: tags[0], point: .zero, userData: nil
        )
        XCTAssertTrue(text.hasPrefix("Created "), "the tooltip lost its stamps: \(text)")
        XCTAssertTrue(text.contains("; edited "))

        // A tag the rebuild has forgotten answers with nothing rather
        // than with some other block's reading.
        XCTAssertEqual(
            coordinator.view(
                textView, stringForToolTip: tags[0] + 9_999, point: .zero, userData: nil
            ),
            ""
        )
    }

    func testRepositioningRetainsUnchangedTooltipsAndRemovesOnlyBlockRegistrations() {
        makeEditor()
        let unrelatedTag = textView.addToolTip(NSRect(x: 350, y: 0, width: 20, height: 20),
                                               owner: self, userData: nil)
        type("alpha")
        coordinator.layOutBlockLabels(forMetas: [
            BlockInfo(id: "alpha", createdS: 1_000, modifiedS: 300_000, paragraphs: 1)
        ])
        let tags = coordinator.blockToolTipTags
        let shapeCount = coordinator.blockLabelShapeCount
        XCTAssertEqual(tags.count, 1)
        coordinator.refitBlockLabels()
        XCTAssertEqual(
            coordinator.blockToolTipTags, tags,
            "an unchanged row re-registered its tooltip during layout"
        )
        XCTAssertEqual(
            coordinator.blockLabelShapeCount, shapeCount,
            "an unchanged row called sizeToFit during layout"
        )
        // No stamps, no edited blocks: the rects and their strings go
        // together, leaving nothing behind to answer a stale hover. The
        // unrelated tag is deliberately not in the coordinator table and
        // is left to its owner rather than cleared wholesale.
        coordinator.layOutBlockLabels(forMetas: [])
        XCTAssertTrue(
            coordinator.blockToolTipTags.isEmpty, "a tooltip outlived its affordance"
        )
        XCTAssertEqual(
            coordinator.view(textView, stringForToolTip: tags[0], point: .zero, userData: nil),
            "",
            "a removed block tag resolved to stale metadata"
        )
        textView.removeToolTip(unrelatedTag)
    }

    /// Whatever the pill says, the label a screen reader hears carries
    /// both stamps in full.
    func testTheAccessibilityLabelKeepsBothStampsInFull() {
        let storage = NSTextStorage(string: "first\nsecond")
        let result = InkEditorView.Coordinator.applyMarkdownStyling(
            to: storage, sheet: 1,
            blockMetas: [
                BlockInfo(id: "first", createdS: 1_000, modifiedS: 1_000, paragraphs: 1),
                BlockInfo(id: "second", createdS: 2_000, modifiedS: 300_000, paragraphs: 1),
            ],
            syntaxHighlightingEnabled: false, fenceRenderingLanguages: [:]
        )
        let text = result.displays[0].accessibilityText
        XCTAssertTrue(text.hasPrefix("Created "))
        XCTAssertTrue(text.contains("; edited "))
        XCTAssertTrue(text.contains("1970"), "the full date is missing: \(text)")
    }

    // MARK: Hover point

    private let hoverRect = NSRect(x: 0, y: 100, width: 200, height: 300)

    func testHoverPointInsideVisibleRectPassesThrough() {
        let point = NSPoint(x: 50, y: 150)
        XCTAssertEqual(
            InkTextView.hoverPoint(pointer: point, visibleRect: hoverRect, holdsKeys: true),
            point
        )
    }

    func testHoverPointOutsideVisibleRectClears() {
        XCTAssertNil(InkTextView.hoverPoint(
            pointer: NSPoint(x: 50, y: 50), visibleRect: hoverRect, holdsKeys: true
        ))
    }

    func testHoverPointWithoutKeysClears() {
        XCTAssertNil(InkTextView.hoverPoint(
            pointer: NSPoint(x: 50, y: 150), visibleRect: hoverRect, holdsKeys: false
        ))
    }

    func testHoverPointOverAnotherWindowClears() {
        XCTAssertNil(InkTextView.hoverPoint(
            pointer: NSPoint(x: 50, y: 150), visibleRect: hoverRect,
            holdsKeys: true, pointsIntoWindow: false
        ))
    }

    func testClipBoundsChangeRefreshesHoverFromInjectedScreenPoint() throws {
        makeEditor()
        let scroll = InkEditorView.scrollStack(for: textView)
        let card = NSRect(x: 0, y: 0, width: 720, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        coordinator.observeClip(of: scroll)

        type("alpha")
        coordinator.layOutBlockLabels(forMetas: [
            BlockInfo(id: "alpha", createdS: 1_000, modifiedS: 300_000, paragraphs: 1)
        ])
        scroll.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(labelFields().first, "the fixture minted no affordance")
        let compact = field.stringValue
        let localPoint = NSPoint(x: field.frame.midX, y: field.frame.midY)
        XCTAssertTrue(textView.visibleRect.contains(localPoint), "the hover target is outside the page")
        let windowPoint = textView.convert(localPoint, to: nil)
        textView.hoverRefreshInput = (
            screenPoint: window.convertPoint(toScreen: windowPoint),
            holdsKeys: true,
            pointsIntoWindow: true
        )

        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )

        XCTAssertNotEqual(
            field.stringValue, compact,
            "a clip bounds change did not re-resolve hover under the injected pointer"
        )
    }

    func testHoverPointOnMaxYEdgeFollowsRectContains() {
        let edge = NSPoint(x: 50, y: hoverRect.maxY)
        XCTAssertFalse(hoverRect.contains(edge))
        XCTAssertNil(InkTextView.hoverPoint(pointer: edge, visibleRect: hoverRect, holdsKeys: true))
        let minEdge = NSPoint(x: 50, y: hoverRect.minY)
        XCTAssertEqual(
            InkTextView.hoverPoint(pointer: minEdge, visibleRect: hoverRect, holdsKeys: true),
            minEdge
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
