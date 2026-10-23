import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class CheckpointInsertionTests: XCTestCase {
    private struct Page {
        let tab: UInt64
        let sheet: UInt64
    }

    private struct Roll {
        let window: NSWindow
        let scroll: NSScrollView
        let stack: DayStackView
        let coordinator: InkEditorView.Coordinator
    }

    private func makeModel(tag: String = UUID().uuidString) throws -> PageModel {
        let suite = "companion-checkpoint-insertion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults, tag: tag, saveDebounce: 3_600)
        model.showsTimeUnits = true
        return model
    }

    // Seed through the core so fixture creation does not exercise the split under test.
    private func seed(_ text: String, in model: PageModel) throws -> Page {
        let tab = model.coreClient.newTab()
        XCTAssertNotEqual(tab, 0)
        let sheet = try XCTUnwrap(model.coreClient.tabs().first { $0.id == tab }?.pageID)
        let data = try JSONSerialization.data(withJSONObject: [["ink": text]])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(model.coreClient.syncDocument(sheet: sheet, json: json))
        model.refresh()
        model.select(tab)
        return Page(tab: tab, sheet: sheet)
    }

    private func makeWindow(holding scroll: NSScrollView) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll)
        scroll.frame = frame
        scroll.layoutSubtreeIfNeeded()
        return window
    }

    private func mountRoll(_ model: PageModel) throws -> Roll {
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = DayScrollView.makeRoll(
            model: model, coordinator: coordinator, emptyHint: "Start writing")
        let window = makeWindow(holding: scroll)
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
        let editor = try XCTUnwrap(stack.editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(model.activeEditor === editor)
        XCTAssertEqual(coordinator.currentSheet, model.selectedPageID)
        return Roll(window: window, scroll: scroll, stack: stack, coordinator: coordinator)
    }

    private func unmount(_ roll: Roll) {
        DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
        roll.window.close()
    }

    private func ink(_ sheet: UInt64, in client: CompanionClient) -> String {
        client.documentRuns(sheet: sheet).map {
            switch $0 {
            case .ink(let text): return text
            case .chip: return "\u{fffc}"
            }
        }.joined()
    }

    private func chips(_ sheet: UInt64, in client: CompanionClient) -> [ChipInfo] {
        client.documentRuns(sheet: sheet).compactMap {
            if case .chip(let chip) = $0 { return chip }
            return nil
        }
    }

    @discardableResult
    private func assertInsertion(
        in model: PageModel, after source: Page, previousOrder: [UInt64],
        prefix: String, suffix: String, roll: Roll? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Page {
        let tab = try XCTUnwrap(model.selection, file: file, line: line)
        let sheet = try XCTUnwrap(model.selectedPageID, file: file, line: line)
        XCTAssertFalse(previousOrder.contains(tab), file: file, line: line)
        XCTAssertNotEqual(sheet, source.sheet, file: file, line: line)
        let index = try XCTUnwrap(previousOrder.firstIndex(of: source.tab), file: file, line: line)
        var expected = previousOrder
        expected.insert(tab, at: index + 1)
        XCTAssertEqual(model.tabs.map(\.id), expected, file: file, line: line)
        XCTAssertEqual(model.coreClient.tabs().map(\.id), expected, file: file, line: line)
        XCTAssertEqual(ink(source.sheet, in: model.coreClient), prefix, file: file, line: line)
        XCTAssertEqual(ink(sheet, in: model.coreClient), suffix, file: file, line: line)
        XCTAssertEqual(model.storage(for: source.sheet).string, prefix, file: file, line: line)
        XCTAssertEqual(model.storage(for: sheet).string, suffix, file: file, line: line)
        XCTAssertFalse(model.showingLedger, file: file, line: line)
        XCTAssertNil(model.selectedFile, file: file, line: line)
        XCTAssertNil(model.notice, file: file, line: line)
        if let roll {
            let editor = try XCTUnwrap(roll.stack.editor, file: file, line: line)
            XCTAssertEqual(
                model.viewStates.carets[source.sheet],
                NSRange(location: prefix.utf16.count, length: 0), file: file, line: line)
            XCTAssertEqual(
                model.viewStates.carets[sheet], NSRange(location: 0, length: 0),
                file: file, line: line)
            roll.stack.update(projection: model.timeUnits, selectedPage: sheet, readOnly: false)
            XCTAssertTrue(roll.stack.editor === editor, file: file, line: line)
            XCTAssertTrue(model.activeEditor === editor, file: file, line: line)
            XCTAssertEqual(roll.coordinator.currentSheet, sheet, file: file, line: line)
            XCTAssertEqual(editor.string, suffix, file: file, line: line)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0), file: file, line: line)
            XCTAssertEqual(
                roll.stack.laidOut.compactMap { $0.header.pageIdentity },
                model.timeUnits.units.flatMap(\.pageIDs), file: file, line: line)
        }
        return Page(tab: tab, sheet: sheet)
    }

    private func mountedSplit(
        _ text: String, selection: NSRange, prefix: String, suffix: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let model = try makeModel()
        let source = try seed(text, in: model)
        let order = model.tabs.map(\.id)
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        let editor = try XCTUnwrap(roll.stack.editor)
        model.viewStates.saveCaret(NSRange(location: text.utf16.count, length: 0), for: source.sheet)
        editor.setSelectedRange(selection)
        model.newPage()
        try assertInsertion(
            in: model, after: source, previousOrder: order, prefix: prefix, suffix: suffix,
            roll: roll, file: file, line: line)
        XCTAssertEqual(
            ink(source.sheet, in: model.coreClient) + ink(try XCTUnwrap(model.selectedPageID), in: model.coreClient),
            text, file: file, line: line)
    }

    func testMountedCaretSplitsTheMiddleRatherThanUsingTheSavedCaret() throws {
        try mountedSplit("before\nafter", selection: NSRange(location: 7, length: 0),
            prefix: "before\n", suffix: "after")
    }

    /// A caret at offset 0 inserts a blank checkpoint. Moving the whole
    /// page would leave an empty source behind that the timeline no
    /// longer lists, so nothing moves.
    func testMountedCaretAtStartInsertsABlankCheckpointAndMovesNothing() throws {
        let model = try makeModel()
        let source = try seed("whole page", in: model)
        let order = model.tabs.map(\.id)
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        let editor = try XCTUnwrap(roll.stack.editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        model.newPage()
        let inserted = try assertInsertion(
            in: model, after: source, previousOrder: order, prefix: "whole page", suffix: "")
        XCTAssertEqual(model.viewStates.carets[source.sheet], NSRange(location: 0, length: 0))
        XCTAssertEqual(model.viewStates.carets[inserted.sheet], NSRange(location: 0, length: 0))
        roll.stack.update(projection: model.timeUnits, selectedPage: inserted.sheet, readOnly: false)
        XCTAssertEqual(roll.coordinator.currentSheet, inserted.sheet)
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(
            roll.stack.laidOut.compactMap { $0.header.pageIdentity },
            model.timeUnits.units.flatMap(\.pageIDs))
    }

    func testSavedCaretAtStartWithoutAnEditorMovesNothing() throws {
        let model = try makeModel()
        let source = try seed("whole page", in: model)
        let order = model.tabs.map(\.id)
        XCTAssertNil(model.activeEditor)
        model.viewStates.saveCaret(NSRange(location: 0, length: 0), for: source.sheet)
        model.newPage()
        try assertInsertion(
            in: model, after: source, previousOrder: order, prefix: "whole page", suffix: "")
        XCTAssertEqual(model.viewStates.carets[source.sheet], NSRange(location: 0, length: 0))
    }

    func testMountedCaretAtEndInsertsABlankCheckpoint() throws {
        try mountedSplit("whole page", selection: NSRange(location: 10, length: 0),
            prefix: "whole page", suffix: "")
    }

    func testSelectedTextMovesWithTheSuffixInsteadOfBeingDeleted() throws {
        try mountedSplit("left SELECTED right", selection: NSRange(location: 5, length: 8),
            prefix: "left ", suffix: "SELECTED right")
    }

    func testMountedSplitUsesUTF16OffsetsAcrossEmojiAndCombiningCharacters() throws {
        let prefix = "A👩🏽‍💻e\u{301}\n"
        let suffix = "🧪選択🇨🇦 end"
        XCTAssertNotEqual(prefix.count, prefix.utf16.count)
        try mountedSplit(prefix + suffix,
            selection: NSRange(location: prefix.utf16.count, length: "🧪選択".utf16.count),
            prefix: prefix, suffix: suffix)
    }

    func testSealedChipsKeepTheirIdentityOnBothSidesOfTheSplit() throws {
        let model = try makeModel()
        let source = try seed("abcdef", in: model)
        let retained = try XCTUnwrap(model.coreClient.sealText(
            sheet: source.sheet, "retained secret", at: 2, length: 0))
        let moved = try XCTUnwrap(model.coreClient.sealText(
            sheet: source.sheet, "moved secret", at: 5, length: 0))
        model.refresh()
        let before = chips(source.sheet, in: model.coreClient)
        XCTAssertEqual(before.map(\.chipId), [retained.chipId, moved.chipId])
        let order = model.tabs.map(\.id)
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        try XCTUnwrap(roll.stack.editor).setSelectedRange(NSRange(location: 5, length: 1))
        model.newPage()
        let inserted = try assertInsertion(
            in: model, after: source, previousOrder: order,
            prefix: "ab\u{fffc}cd", suffix: "\u{fffc}ef", roll: roll)
        XCTAssertEqual(chips(source.sheet, in: model.coreClient), [before[0]])
        XCTAssertEqual(chips(inserted.sheet, in: model.coreClient), [before[1]])
        XCTAssertNil(model.coreClient.activeCut())
        let attachment = try XCTUnwrap(model.storage(for: inserted.sheet)
            .attribute(.attachment, at: 0, effectiveRange: nil) as? ChipAttachment)
        XCTAssertEqual(attachment.info, before[1])
    }

    func testMountedBlankPageStillInsertsANewBlankCheckpoint() throws {
        try mountedSplit("", selection: NSRange(location: 0, length: 0), prefix: "", suffix: "")
    }

    func testSavedSelectionSuppliesTheSplitWhenNoEditorIsMounted() throws {
        let model = try makeModel()
        let source = try seed("left selected tail", in: model)
        let order = model.tabs.map(\.id)
        XCTAssertNil(model.activeEditor)
        model.viewStates.saveCaret(NSRange(location: 5, length: 8), for: source.sheet)
        model.newPage()
        let inserted = try assertInsertion(
            in: model, after: source, previousOrder: order, prefix: "left ", suffix: "selected tail")
        XCTAssertEqual(model.viewStates.carets[source.sheet], NSRange(location: 5, length: 0))
        XCTAssertEqual(model.viewStates.carets[inserted.sheet], NSRange(location: 0, length: 0))
    }

    func testMissingSavedCaretDefaultsToTheEnd() throws {
        let model = try makeModel()
        let source = try seed("unsplit 🧪 page", in: model)
        let order = model.tabs.map(\.id)
        XCTAssertNil(model.activeEditor)
        XCTAssertNil(model.viewStates.carets[source.sheet])
        model.newPage()
        try assertInsertion(in: model, after: source, previousOrder: order,
            prefix: "unsplit 🧪 page", suffix: "")
    }

    func testBlankPageWithoutAnEditorOrSavedCaretStillInserts() throws {
        let model = try makeModel()
        let source = try seed("", in: model)
        let order = model.tabs.map(\.id)
        XCTAssertNil(model.activeEditor)
        XCTAssertNil(model.viewStates.carets[source.sheet])
        model.newPage()
        try assertInsertion(in: model, after: source, previousOrder: order, prefix: "", suffix: "")
    }

    func testAnEditorStillOnAnotherPageDoesNotSupplyTheSelectedPagesCaret() throws {
        let model = try makeModel()
        let other = try seed("other page", in: model)
        let source = try seed("left tail", in: model)
        model.select(other.tab)
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        try XCTUnwrap(roll.stack.editor).setSelectedRange(NSRange(location: 0, length: 0))
        model.select(source.tab)
        model.viewStates.saveCaret(NSRange(location: 5, length: 0), for: source.sheet)
        XCTAssertEqual(roll.coordinator.currentSheet, other.sheet)
        let order = model.tabs.map(\.id)
        model.newPage()
        try assertInsertion(in: model, after: source, previousOrder: order, prefix: "left ", suffix: "tail")
        XCTAssertEqual(ink(other.sheet, in: model.coreClient), "other page")
    }

    func testMidListInsertionStandsAfterTheSelectedPageAndBeforeItsSuccessor() throws {
        let model = try makeModel()
        let first = try seed("first", in: model)
        let source = try seed("left tail", in: model)
        let successor = try seed("successor", in: model)
        let last = try seed("last", in: model)
        model.select(source.tab)
        let order = model.tabs.map(\.id)
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        try XCTUnwrap(roll.stack.editor).setSelectedRange(NSRange(location: 5, length: 0))
        model.newPage()
        let inserted = try assertInsertion(in: model, after: source, previousOrder: order,
            prefix: "left ", suffix: "tail", roll: roll)
        XCTAssertEqual(model.tabs.map(\.id), [first.tab, source.tab, inserted.tab, successor.tab, last.tab])
        XCTAssertEqual(model.timeUnits.units.flatMap(\.tabIDs), model.tabs.map(\.id))
        for (page, text) in [(first, "first"), (successor, "successor"), (last, "last")] {
            XCTAssertEqual(ink(page.sheet, in: model.coreClient), text)
        }
    }

    // The roll-only fixture changes a day label, not the model or the core's birth stamps.
    private func onYesterday(_ tab: TabSummary) throws -> TabSummary {
        let data = try JSONEncoder().encode(tab)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields["page_day_offset"] = -1
        return try JSONDecoder().decode(TabSummary.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func createFromEarlierCheckpoint(
        _ action: (PageModel, Roll, InkTextView) throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let model = try makeModel()
        let source = try seed("old prefix tail", in: model)
        let today = try seed("today stays here", in: model)
        model.select(source.tab)
        XCTAssertEqual(model.coreClient.tabs().compactMap(\.pageDayOffset), [0, 0])
        XCTAssertEqual(model.timeUnits.units.first { $0.bucket == 0 }?.tabIDs, [source.tab, today.tab])
        let projectedTabs = try model.tabs.map { $0.id == source.tab ? try onYesterday($0) : $0 }
        let projection = TimeUnitProjection.project(
            tabs: projectedTabs, selectedPageID: source.sheet, unit: .day)
        XCTAssertEqual(projection.units.first { $0.bucket == -1 }?.tabIDs, [source.tab])
        let order = model.tabs.map(\.id)
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        roll.stack.update(projection: projection, selectedPage: source.sheet, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        try action(model, roll, editor)
        try assertInsertion(in: model, after: source, previousOrder: order,
            prefix: "old prefix ", suffix: "tail", roll: roll, file: file, line: line)
        XCTAssertEqual(ink(today.sheet, in: model.coreClient), "today stays here", file: file, line: line)
    }

    private func commandEvent(_ key: String, code: UInt16, in roll: Roll) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: roll.window.windowNumber,
            context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: code))
    }

    // Surface chords belong to PageKeyboardMap; invoke its callback after event resolution.
    private func performCommandEvent(_ key: String, code: UInt16, in roll: Roll, model: PageModel) throws {
        let event = try commandEvent(key, code: code, in: roll)
        let command = try XCTUnwrap(model.keymap.command(for: event, in: .editor))
        XCTAssertEqual(command, .pageNew)
        XCTAssertEqual(command.dispatch, .surface)
        XCTAssertTrue(model.perform(command))
    }

    func testCmdNInsertsAtTheMountedCaretOfAnEarlierCheckpoint() throws {
        try createFromEarlierCheckpoint { model, roll, _ in
            try performCommandEvent("n", code: 45, in: roll, model: model)
        }
    }

    func testCmdTInsertsAtTheMountedCaretOfAnEarlierCheckpoint() throws {
        try createFromEarlierCheckpoint { model, roll, _ in
            try performCommandEvent("t", code: 17, in: roll, model: model)
        }
    }

    func testSidebarNewPageCallbackInsertsAtTheMountedCaret() throws {
        try createFromEarlierCheckpoint { model, _, _ in
            let sidebarNewPage: () -> Void = { model.newPage() }
            sidebarNewPage()
        }
    }

    private func commandCreatesFromLedger(_ key: String, code: UInt16) throws {
        let model = try makeModel()
        let source = try seed("page behind ledger", in: model)
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        let editor = try XCTUnwrap(roll.stack.editor)
        editor.setSelectedRange(NSRange(location: 5, length: 6))
        model.showLedger()
        XCTAssertTrue(model.showingLedger)
        let order = model.tabs.map(\.id)
        try performCommandEvent(key, code: code, in: roll, model: model)
        let created = try XCTUnwrap(model.selectedPageID)
        XCTAssertNotEqual(created, source.sheet)
        XCTAssertEqual(model.tabs.count, order.count + 1)
        XCTAssertEqual(Array(model.tabs.dropLast()).map(\.id), order)
        XCTAssertEqual(ink(source.sheet, in: model.coreClient), "page behind ledger")
        XCTAssertEqual(ink(created, in: model.coreClient), "")
        XCTAssertFalse(model.showingLedger)
    }

    func testCmdNCreatesFromTheLedgerInsteadOfJumpingToTheExistingTodayPage() throws {
        try commandCreatesFromLedger("n", code: 45)
    }

    func testCmdTCreatesFromTheLedgerInsteadOfJumpingToTheExistingTodayPage() throws {
        try commandCreatesFromLedger("t", code: 17)
    }

    func testCreatingWhileAFileIsMountedLeavesTheFileAndBackgroundPageUnchanged() throws {
        let model = try makeModel()
        let background = try seed("background page", in: model)
        model.viewStates.saveCaret(NSRange(location: 3, length: 0), for: background.sheet)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-insertion-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let text = "file selected text 🧪"
        try text.write(to: url, atomically: true, encoding: .utf8)
        model.openFile(at: url)
        let fileID = try XCTUnwrap(model.selectedFile)
        let fileBefore = model.openFiles
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = InkEditorView.makePage(
            model: model, sheetID: fileID, readOnly: false, coordinator: coordinator)
        let window = makeWindow(holding: scroll)
        let editor = try XCTUnwrap(scroll.documentView as? InkTextView)
        defer {
            coordinator.leavePage(editor, scrollView: scroll)
            window.close()
        }
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 8))
        let order = model.tabs.map(\.id)
        XCTAssertTrue(model.perform(.pageNew))
        let created = try XCTUnwrap(model.selectedPageID)
        XCTAssertEqual(model.tabs.count, order.count + 1)
        XCTAssertEqual(Array(model.tabs.dropLast()).map(\.id), order)
        XCTAssertEqual(ink(created, in: model.coreClient), "")
        XCTAssertEqual(ink(background.sheet, in: model.coreClient), "background page")
        let fileInk = model.coreClient.fileRuns(fileID).compactMap { run -> String? in
            if case .ink(let ink) = run { return ink }
            return nil
        }.joined()
        XCTAssertEqual(fileInk, text)
        XCTAssertEqual(model.storage(for: fileID).string, text)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        XCTAssertEqual(model.openFiles, fileBefore)
        XCTAssertNil(model.selectedFile)
    }

    func testCreatingFromTheLedgerDoesNotSplitThePageStillMountedBehindIt() throws {
        let model = try makeModel()
        let source = try seed("page behind ledger", in: model)
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        try XCTUnwrap(roll.stack.editor).setSelectedRange(NSRange(location: 5, length: 6))
        model.showLedger()
        XCTAssertTrue(model.showingLedger)
        let ledgerBefore = model.coreClient.ledger()
        XCTAssertFalse(ledgerBefore.isEmpty)
        let order = model.tabs.map(\.id)
        XCTAssertTrue(model.perform(.pageNew))
        let created = try XCTUnwrap(model.selectedPageID)
        XCTAssertEqual(model.tabs.count, order.count + 1)
        XCTAssertEqual(Array(model.tabs.dropLast()).map(\.id), order)
        XCTAssertEqual(ink(source.sheet, in: model.coreClient), "page behind ledger")
        XCTAssertEqual(model.storage(for: source.sheet).string, "page behind ledger")
        XCTAssertEqual(ink(created, in: model.coreClient), "")
        let ledgerAfter = model.coreClient.ledger()
        XCTAssertEqual(ledgerAfter.count, ledgerBefore.count + 1)
        XCTAssertEqual(ledgerAfter.first?.event, "created")
        XCTAssertEqual(Array(ledgerAfter.dropFirst()), ledgerBefore)
        XCTAssertFalse(model.showingLedger)
    }

    func testTabsModeCreatesABlankPageWithoutSplittingTheMountedSelection() throws {
        let model = try makeModel()
        let source = try seed("tabs keep their text", in: model)
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        try XCTUnwrap(roll.stack.editor).setSelectedRange(NSRange(location: 5, length: 4))
        model.showsTimeUnits = false
        XCTAssertTrue(model.perform(.pageNew))
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(ink(source.sheet, in: model.coreClient), "tabs keep their text")
        XCTAssertEqual(ink(try XCTUnwrap(model.selectedPageID), in: model.coreClient), "")
    }

    func testInsertionResetsTodaysSortToNaturalAndLaterSortsPreserveDocumentsAndTabOrder() throws {
        for initial: PadSortDirection in [.chronological, .reverseChronological, .natural] {
            let model = try makeModel()
            model.pads.isEnabled = true
            _ = try seed("first", in: model)
            let source = try seed("left tail", in: model)
            _ = try seed("successor", in: model)
            model.select(source.tab)
            let pad = model.pads.activeID
            let date = model.dateKey(forDayBucket: 0)
            XCTAssertFalse(date.isEmpty)
            model.pads.setCheckpointSort(.chronological, for: pad, onDate: date)
            let reversedCreationOrder = Array(model.timeUnits.units.flatMap(\.tabIDs).reversed())
            // Make natural differ from timestamp order even when creation stamps tie.
            for (index, tab) in reversedCreationOrder.enumerated() {
                XCTAssertTrue(model.coreClient.moveTab(id: tab, to: UInt64(index)))
            }
            model.refresh()
            XCTAssertEqual(model.tabs.map(\.id), reversedCreationOrder)
            model.pads.setCheckpointSort(initial, for: pad, onDate: date)
            XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: date), initial)
            let order = model.tabs.map(\.id)
            let roll = try mountRoll(model)
            defer { unmount(roll) }
            try XCTUnwrap(roll.stack.editor).setSelectedRange(NSRange(location: 5, length: 0))
            model.newPage()
            let inserted = try assertInsertion(in: model, after: source, previousOrder: order,
                prefix: "left ", suffix: "tail", roll: roll)
            XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: date), .natural)
            let naturalTabs = model.tabs.map(\.id)
            let naturalPages = model.tabs.compactMap(\.pageID)
            let documents = naturalPages.map { ink($0, in: model.coreClient) }
            XCTAssertEqual(model.timeUnits.units.flatMap(\.tabIDs), naturalTabs)
            XCTAssertEqual(model.timeUnits.units.flatMap(\.pageIDs), naturalPages)
            var chronological: [UInt64] = []
            for direction: PadSortDirection in [.chronological, .reverseChronological, .natural] {
                model.pads.setCheckpointSort(direction, for: pad, onDate: date)
                XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: date), direction)
                let projected = model.timeUnits.units.flatMap(\.pageIDs)
                if direction == .chronological { chronological = projected }
                if direction == .reverseChronological { XCTAssertEqual(projected, Array(chronological.reversed())) }
                if direction == .natural { XCTAssertEqual(projected, naturalPages) }
                XCTAssertEqual(Set(projected), Set(naturalPages))
                roll.stack.update(projection: model.timeUnits, selectedPage: inserted.sheet, readOnly: false)
                XCTAssertEqual(roll.stack.laidOut.compactMap { $0.header.pageIdentity }, projected)
                XCTAssertEqual(model.tabs.map(\.id), naturalTabs)
                XCTAssertEqual(model.coreClient.tabs().map(\.id), naturalTabs)
                XCTAssertEqual(naturalPages.map { ink($0, in: model.coreClient) }, documents)
                XCTAssertEqual(naturalPages.map { model.storage(for: $0).string }, documents)
                XCTAssertEqual(model.selectedPageID, inserted.sheet)
            }
        }
    }

    private func makeSyntheticCalendarModel() throws -> (PageModel, CheckpointCalendarFixtureClient) {
        let suite = "companion-checkpoint-calendar-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-checkpoint-calendar-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let client = CheckpointCalendarFixtureClient(tag: UUID().uuidString)
        let model = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: client, saveDebounce: 3_600))
        model.showsTimeUnits = true
        model.pads.isEnabled = true
        return (model, client)
    }

    private func fileSyntheticDay(
        _ day: Int, for page: Page, in model: PageModel, client: CheckpointCalendarFixtureClient
    ) throws {
        let uuid = try XCTUnwrap(model.tabs.first { $0.id == page.tab }?.uuid)
        client.syntheticDaysByTabUUID[uuid] = day
    }

    private func assertNaturalRollAndRail(
        _ roll: Roll, model: PageModel, file: StaticString = #filePath, line: UInt = #line
    ) {
        let projection = model.timeUnits
        let nodes = StreamNavigator.nodes(projection: projection, tabs: model.navigationTabs,
            selection: model.selection, surfaceShowsRoll: true, stampFormat: model.stampFormat)
        let rows = projection.units.map { TimeRailView.nodes(for: $0, in: nodes) }
        let pages = projection.units.flatMap(\.pageIDs)
        XCTAssertEqual(nodes.compactMap(\.page), pages, file: file, line: line)
        XCTAssertEqual(rows.map { $0.compactMap(\.page) }, projection.units.map(\.pageIDs), file: file, line: line)
        XCTAssertEqual(rows.flatMap { $0 }.map(\.id), nodes.map(\.id), file: file, line: line)
        XCTAssertEqual(Set(nodes.map(\.id)).count, nodes.count, file: file, line: line)
        XCTAssertEqual(nodes.filter(\.active).compactMap(\.page), [model.selectedPageID].compactMap { $0 },
            file: file, line: line)
        XCTAssertEqual(roll.stack.laidOut.compactMap { $0.header.pageIdentity }, pages, file: file, line: line)
        var headerIndex = 0
        for unit in projection.units {
            for index in unit.pageIDs.indices {
                guard headerIndex < roll.stack.laidOut.count else {
                    XCTFail("a projected page has no mounted header", file: file, line: line)
                    return
                }
                let header = roll.stack.laidOut[headerIndex].header
                let expectedMark: DayHeaderView.Mark = headerIndex == 0 || index > 0 ? .hairline : .tear
                XCTAssertEqual(header.mark, expectedMark, file: file, line: line)
                if index == 0 {
                    XCTAssertTrue(header.reading.hasPrefix(unit.spokenLabel), file: file, line: line)
                } else {
                    XCTAssertEqual(header.reading, header.timeText, file: file, line: line)
                }
                headerIndex += 1
            }
        }
    }

    func testSyntheticRepeatedDayRunsKeepNativeHeadersAndRailRowsThroughGutterRefresh() throws {
        let (model, client) = try makeSyntheticCalendarModel()
        let pages = try ["today first", "yesterday first", "yesterday second", "today second",
            "yesterday third", "today third"].map { try seed($0, in: model) }
        for index in [1, 2, 4] {
            try fileSyntheticDay(-1, for: pages[index], in: model, client: client)
        }
        model.refresh()
        model.select(pages[3].tab)
        model.pads.setDaySort(.natural, for: model.pads.activeID)
        XCTAssertEqual(client.actualTabs().compactMap(\.pageDayOffset), Array(repeating: 0, count: pages.count))
        let natural = TimeUnitProjection.project(tabs: model.navigationTabs,
            selectedPageID: model.selectedPageID, unit: .day).inNaturalOrder(tabs: model.navigationTabs)
        XCTAssertEqual(model.timeUnits, natural)
        XCTAssertEqual(natural.units.map(\.bucket), [0, -1, 0, -1, 0])
        XCTAssertEqual(natural.units.map(\.pageIDs), [
            [pages[0].sheet], [pages[1].sheet, pages[2].sheet], [pages[3].sheet],
            [pages[4].sheet], [pages[5].sheet]])
        XCTAssertEqual(Set(natural.units.map(\.id)).count, natural.units.count)
        let documents = pages.map { ink($0.sheet, in: client) }
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        assertNaturalRollAndRail(roll, model: model)
        let headers = roll.stack.laidOut.map(\.header)
        let rebuilds = roll.stack.rebuilds
        model.stampFormat = StreamNavigator.StampFormat(short: "h:mm a", fine: "h:mm:ss a")
        // An unchanged signature takes refreshGutters, which reads the model's repeated runs.
        for _ in 0..<2 {
            model.refresh()
            roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
            assertNaturalRollAndRail(roll, model: model)
            XCTAssertEqual(roll.stack.rebuilds, rebuilds)
            for (before, after) in zip(headers, roll.stack.laidOut.map(\.header)) {
                XCTAssertTrue(before === after)
            }
        }
        XCTAssertEqual(pages.map { ink($0.sheet, in: client) }, documents)
        XCTAssertEqual(roll.coordinator.currentSheet, pages[3].sheet)
    }

    func testSyntheticPriorDayInsertionResetsBothCheckpointDatesAndDaySortToNatural() throws {
        for initial: PadSortDirection in [.chronological, .reverseChronological, .natural] {
            let (model, client) = try makeSyntheticCalendarModel()
            let first = try seed("today first", in: model)
            let source = try seed("left tail", in: model)
            let successor = try seed("yesterday successor", in: model)
            let lastToday = try seed("today last", in: model)
            let unrelated = try seed("unrelated older day", in: model)
            let chip = try XCTUnwrap(client.sealText(sheet: source.sheet, "moved secret", at: 9, length: 0))
            try fileSyntheticDay(-1, for: source, in: model, client: client)
            try fileSyntheticDay(-1, for: successor, in: model, client: client)
            try fileSyntheticDay(-2, for: unrelated, in: model, client: client)
            model.refresh()
            model.select(source.tab)
            let sourceSummary = try XCTUnwrap(model.tabs.first { $0.id == source.tab })
            XCTAssertEqual(sourceSummary.pageDayOffset, -1)
            XCTAssertEqual(client.actualTabs().compactMap(\.pageDayOffset), [0, 0, 0, 0, 0])
            let pad = model.pads.activeID
            let todayDate = model.dateKey(forDayBucket: 0)
            let sourceDate = model.dateKey(forDayBucket: -1)
            let otherDate = model.dateKey(forDayBucket: -2)
            XCTAssertFalse(todayDate.isEmpty)
            XCTAssertNotEqual(todayDate, sourceDate)
            model.pads.setDaySort(initial, for: pad)
            model.pads.setCheckpointSort(.chronological, for: pad, onDate: todayDate)
            model.pads.setCheckpointSort(.reverseChronological, for: pad, onDate: sourceDate)
            model.pads.setCheckpointSort(.reverseChronological, for: pad, onDate: otherDate)
            let order = model.tabs.map(\.id)
            let roll = try mountRoll(model)
            defer { unmount(roll) }
            try XCTUnwrap(roll.stack.editor).setSelectedRange(NSRange(location: 5, length: 4))
            model.newPage()
            let inserted = try assertInsertion(in: model, after: source, previousOrder: order,
                prefix: "left ", suffix: "tail\u{fffc}", roll: roll)
            XCTAssertEqual(model.pads.daySortDirection(for: pad), .natural)
            XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: todayDate), .natural)
            XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: sourceDate), .natural)
            XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: otherDate), .reverseChronological)
            XCTAssertEqual(model.tabs.map(\.id),
                [first.tab, source.tab, inserted.tab, successor.tab, lastToday.tab, unrelated.tab])
            XCTAssertEqual(model.timeUnits.units.map(\.bucket), [0, -1, 0, -1, 0, -2])
            XCTAssertEqual(model.timeUnits.units.flatMap(\.tabIDs), model.tabs.map(\.id))
            XCTAssertEqual(model.tabs.first { $0.id == source.tab }?.pageCreatedMs, sourceSummary.pageCreatedMs)
            XCTAssertTrue(chips(source.sheet, in: client).isEmpty)
            XCTAssertEqual(chips(inserted.sheet, in: client), [chip])
            assertNaturalRollAndRail(roll, model: model)
            model.refresh()
            roll.stack.update(projection: model.timeUnits, selectedPage: inserted.sheet, readOnly: false)
            assertNaturalRollAndRail(roll, model: model)
            XCTAssertEqual(ink(successor.sheet, in: client), "yesterday successor")
            XCTAssertEqual(ink(lastToday.sheet, in: client), "today last")
            XCTAssertEqual(ink(unrelated.sheet, in: client), "unrelated older day")
        }
    }

    func testSameDayInsertionResetsCheckpointSortWithoutChangingDaySort() throws {
        for daySort: PadSortDirection in [.chronological, .reverseChronological, .natural] {
            let model = try makeModel()
            model.pads.isEnabled = true
            let source = try seed("left tail", in: model)
            _ = try seed("successor", in: model)
            model.select(source.tab)
            let pad = model.pads.activeID
            let date = model.dateKey(forDayBucket: 0)
            model.pads.setDaySort(daySort, for: pad)
            model.pads.setCheckpointSort(.reverseChronological, for: pad, onDate: date)
            let order = model.tabs.map(\.id)
            model.viewStates.saveCaret(NSRange(location: 5, length: 0), for: source.sheet)
            model.newPage()
            try assertInsertion(in: model, after: source, previousOrder: order, prefix: "left ", suffix: "tail")
            XCTAssertEqual(model.pads.daySortDirection(for: pad), daySort)
            XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: date), .natural)
            XCTAssertEqual(model.timeUnits.units.flatMap(\.tabIDs), model.tabs.map(\.id))
        }
    }

    func testCorePersistenceRestoresTheInsertedOrderAndSplitDocuments() throws {
        let tag = "checkpoint-insertion-\(UUID().uuidString)"
        let model = try makeModel(tag: tag)
        _ = try seed("first", in: model)
        let source = try seed("left 🧪 tail", in: model)
        _ = try seed("successor", in: model)
        model.select(source.tab)
        model.viewStates.saveCaret(NSRange(location: 5, length: 0), for: source.sheet)
        let order = model.tabs.map(\.id)
        model.newPage()
        try assertInsertion(in: model, after: source, previousOrder: order,
            prefix: "left ", suffix: "🧪 tail")
        let uuids = try model.tabs.map { try XCTUnwrap($0.uuid) }
        let documents = try model.tabs.map { ink(try XCTUnwrap($0.pageID), in: model.coreClient) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-order-\(UUID().uuidString).sealed")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(model.coreClient.persistSave(to: url.path))
        let restored = CompanionClient.ephemeral(tag: tag)
        XCTAssertTrue(restored.persistRestore(from: url.path))
        let tabs = restored.tabs()
        XCTAssertEqual(try tabs.map { try XCTUnwrap($0.uuid) }, uuids)
        XCTAssertEqual(try tabs.map { ink(try XCTUnwrap($0.pageID), in: restored) }, documents)
        let projection = TimeUnitProjection.project(tabs: tabs, selectedPageID: nil, unit: .day)
        XCTAssertEqual(projection.units.flatMap(\.tabIDs), tabs.map(\.id))
        XCTAssertEqual(projection.units.flatMap(\.pageIDs), tabs.compactMap(\.pageID))
    }

    // MARK: Today's place

    /// Yesterday's page selected with its caret mid text, today empty.
    /// The place gesture mints today's first page without touching
    /// yesterday's: a place is not ⌘N.
    private func startTodayFromYesterday(
        _ gesture: (PageModel) -> Void, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let (model, client) = try makeSyntheticCalendarModel()
        let yesterday = try seed("yesterday page", in: model)
        try fileSyntheticDay(-1, for: yesterday, in: model, client: client)
        model.refresh()
        model.select(yesterday.tab)
        XCTAssertEqual(model.tabs.first { $0.id == yesterday.tab }?.pageDayOffset, -1, file: file, line: line)
        XCTAssertEqual(model.timeUnits.units.first { $0.bucket == 0 }?.tabIDs ?? [], [], file: file, line: line)
        let roll = try mountRoll(model)
        defer { unmount(roll) }
        let editor = try XCTUnwrap(roll.stack.editor, file: file, line: line)
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        model.viewStates.saveCaret(NSRange(location: 5, length: 0), for: yesterday.sheet)
        gesture(model)
        XCTAssertEqual(model.tabs.count, 2, file: file, line: line)
        let created = try XCTUnwrap(model.selection, file: file, line: line)
        let page = try XCTUnwrap(model.selectedPageID, file: file, line: line)
        XCTAssertNotEqual(created, yesterday.tab, file: file, line: line)
        XCTAssertEqual(model.tabs.map(\.id), [yesterday.tab, created], file: file, line: line)
        XCTAssertEqual(ink(yesterday.sheet, in: client), "yesterday page", file: file, line: line)
        XCTAssertEqual(model.storage(for: yesterday.sheet).string, "yesterday page", file: file, line: line)
        XCTAssertEqual(ink(page, in: client), "", file: file, line: line)
        XCTAssertEqual(model.tabs.first { $0.id == created }?.pageDayOffset, 0, file: file, line: line)
        XCTAssertEqual(model.timeUnits.units.first { $0.bucket == 0 }?.tabIDs, [created], file: file, line: line)
        XCTAssertEqual(model.viewStates.carets[yesterday.sheet], NSRange(location: 5, length: 0), file: file, line: line)
        XCTAssertNil(model.notice, file: file, line: line)
        // The place fires again: it finds the page it made and mints nothing.
        gesture(model)
        XCTAssertEqual(model.tabs.count, 2, file: file, line: line)
        XCTAssertEqual(model.selection, created, file: file, line: line)
        XCTAssertEqual(ink(yesterday.sheet, in: client), "yesterday page", file: file, line: line)
    }

    func testStartTodayFromYesterdaysPageMintsABlankTodayWithoutSplitting() throws {
        try startTodayFromYesterday { $0.startToday() }
    }

    func testTheTodayTargetFromYesterdaysPageMintsABlankTodayWithoutSplitting() throws {
        try startTodayFromYesterday { $0.select(target: .today) }
    }

    func testStartTodayWithTodayPeopledSelectsItsFirstPageAndMintsNothing() throws {
        let (model, client) = try makeSyntheticCalendarModel()
        let today = try seed("today page", in: model)
        let yesterday = try seed("yesterday page", in: model)
        try fileSyntheticDay(-1, for: yesterday, in: model, client: client)
        model.refresh()
        model.select(yesterday.tab)
        model.viewStates.saveCaret(NSRange(location: 5, length: 0), for: yesterday.sheet)
        let order = model.tabs.map(\.id)
        model.startToday()
        XCTAssertEqual(model.tabs.map(\.id), order)
        XCTAssertEqual(model.selection, today.tab)
        XCTAssertEqual(ink(yesterday.sheet, in: client), "yesterday page")
        XCTAssertEqual(ink(today.sheet, in: client), "today page")
    }

    func testStartTodayOnAnEmptyPadMintsExactlyOnePage() throws {
        let model = try makeModel()
        XCTAssertTrue(model.tabs.isEmpty)
        model.startToday()
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.selection, model.tabs.first?.id)
        XCTAssertEqual(ink(try XCTUnwrap(model.selectedPageID), in: model.coreClient), "")
    }
}

// Calendar summaries are synthetic; the underlying core birth stamps and operations stay real.
private final class CheckpointCalendarFixtureClient: CompanionClient, @unchecked Sendable {
    var syntheticDaysByTabUUID: [String: Int] = [:]

    init(tag: String) {
        super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
    }

    func actualTabs() -> [TabSummary] { super.tabs() }

    override func tabs() -> [TabSummary] {
        super.tabs().map { tab in
            guard let uuid = tab.uuid, let day = syntheticDaysByTabUUID[uuid], tab.hasPage else { return tab }
            return TabSummary(
                id: tab.id, uuid: tab.uuid, pageUUID: tab.pageUUID, hasPage: tab.hasPage, pageID: tab.pageID,
                title: tab.title, titleSource: tab.titleSource,
                rungCode: tab.rungCode, rungLabel: tab.rungLabel,
                remainingMs: tab.remainingMs, remainingLabel: tab.remainingLabel,
                spokenRemaining: tab.spokenRemaining, fractionRemaining: tab.fractionRemaining,
                paused: tab.paused, holdToppedUp: tab.holdToppedUp, holdRemainingMs: tab.holdRemainingMs,
                chipCount: tab.chipCount, lastHour: tab.lastHour, pageHasContent: tab.pageHasContent,
                pageDayOffset: day, pageCreatedMs: tab.pageCreatedMs)
        }
    }
}
