import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class ContinuousSurfaceLifecycleTests: XCTestCase {
    private struct Surface {
        let window: NSWindow
        let scroll: NSScrollView
        let canvas: ContinuousPadCanvas
        let coordinator: InkEditorView.Coordinator
    }

    private func model(client suppliedClient: CompanionClient? = nil) throws -> PageModel {
        let suite = "continuous-lifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = suppliedClient ?? CompanionClient.ephemeral(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { @MainActor in board.releaseGlobally() }
        let model = PageModel(formFactor: .backdrop, defaults: defaults, seams: .init(stateDirectory: directory,
            client: client, saveDebounce: 3_600, clearClipboardIfOurs: { false }, ambientPasteboard: board))
        model.showsTimeUnits = true
        return model
    }

    @discardableResult
    private func seed(_ text: String, in model: PageModel) throws -> UInt64 {
        let tab = model.coreClient.newTab()
        let page = try XCTUnwrap(model.coreClient.tabs().first { $0.id == tab }?.pageID)
        let data = try JSONSerialization.data(withJSONObject: [["ink": text]])
        XCTAssertTrue(model.coreClient.syncDocument(sheet: page, json: try XCTUnwrap(String(data: data, encoding: .utf8))))
        if model.pads.isEnabled {
            let uuid = try XCTUnwrap(model.coreClient.tabs().first { $0.id == tab }?.uuid)
            model.pads.assign(tabUUID: uuid, to: model.pads.activeID)
        }
        model.refresh()
        model.select(tab)
        return page
    }

    private func mount(_ model: PageModel) throws -> Surface {
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = ContinuousPadView.makeSurface(model: model, coordinator: coordinator)
        let frame = NSRect(x: 0, y: 0, width: 520, height: 280)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll)
        scroll.frame = frame
        scroll.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(scroll.documentView as? ContinuousPadCanvas)
        canvas.measure()
        XCTAssertTrue(window.makeFirstResponder(canvas.editor))
        return Surface(window: window, scroll: scroll, canvas: canvas, coordinator: coordinator)
    }

    private func unmount(_ surface: Surface) {
        ContinuousPadView.dismantleNSView(surface.scroll, coordinator: surface.coordinator)
        surface.window.close()
    }

    private func update(_ surface: Surface, model: PageModel) {
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: false, coordinator: surface.coordinator)
    }

    private func body(_ page: UInt64, in model: PageModel) -> String {
        model.coreClient.documentRuns(sheet: page).map { run in
            switch run {
            case .ink(let text): return text
            case .chip: return "\u{fffc}"
            }
        }.joined()
    }

    private func sealedSurface() throws -> (model: PageModel, surface: Surface, chipOffset: Int) {
        let model = try model()
        let first = try seed("prefix suffix", in: model)
        _ = try XCTUnwrap(model.coreClient.sealText(sheet: first, "fixture secret", at: 7, length: 0))
        _ = try seed("other checkpoint", in: model)
        let surface = try mount(model)
        let segment = try XCTUnwrap(surface.canvas.document.projection.segments.first { $0.page.id == first })
        return (model, surface, segment.bodyRange.location + 7)
    }

    func testContinuousChipRemovalOffersNoticeUndoForTheCompleteDocument() throws {
        let fixture = try sealedSurface()
        let model = fixture.model, surface = fixture.surface
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let original = editor.string
        editor.setSelectedRange(NSRange(location: fixture.chipOffset + 1, length: 0))
        editor.deleteBackward(nil)
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, original.replacingOccurrences(of: "\u{fffc}", with: ""))
        XCTAssertEqual(model.notice, PageModel.removedLine)
        XCTAssertEqual(model.noticeAction?.label, "Undo")
        model.performNoticeAction()
        XCTAssertEqual(editor.string, original)
    }

    func testEditingAnotherCheckpointRetiresTheContinuousRemovalNoticeUndo() throws {
        let fixture = try sealedSurface()
        let model = fixture.model, surface = fixture.surface
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        editor.setSelectedRange(NSRange(location: fixture.chipOffset, length: 1))
        editor.deleteBackward(nil)
        let staleUndo = try XCTUnwrap(model.noticeAction)
        let next = try XCTUnwrap(surface.canvas.document.projection.segments.last)
        editor.setSelectedRange(NSRange(location: NSMaxRange(next.bodyRange), length: 0))
        editor.insertText("X", replacementRange: editor.selectedRange())
        XCTAssertNil(model.noticeAction)
        let edited = editor.string
        staleUndo.perform()
        XCTAssertEqual(editor.string, edited)
        XCTAssertTrue(editor.string.hasSuffix("X"))
    }

    func testContinuousRemovalByReachEndsItsDeletionGroup() throws {
        let fixture = try sealedSurface()
        let model = fixture.model, surface = fixture.surface
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let original = editor.string
        editor.setSelectedRange(NSRange(location: fixture.chipOffset - 1, length: 0))
        editor.deleteToEndOfParagraph(nil)
        XCTAssertEqual(model.notice, PageModel.removedLine)
        XCTAssertEqual(model.noticeAction?.label, "Undo")
        let removed = editor.string
        XCTAssertFalse(removed.contains("\u{fffc}"))
        editor.deleteBackward(nil)
        XCTAssertNotEqual(editor.string, removed)
        XCTAssertNil(model.noticeAction)
        editor.undo(nil)
        XCTAssertEqual(editor.string, removed)
        editor.undo(nil)
        XCTAssertEqual(editor.string, original)
    }

    func testContinuousRemovalNoticeUndoSurvivesUnmountWithoutRetainingText() throws {
        let fixture = try sealedSurface()
        let model = fixture.model, surface = fixture.surface
        let editor = surface.canvas.editor
        let document = surface.canvas.document
        let original = editor.string
        editor.setSelectedRange(NSRange(location: fixture.chipOffset, length: 1))
        editor.deleteBackward(nil)
        XCTAssertEqual(model.noticeAction?.label, "Undo")
        unmount(surface)
        XCTAssertTrue(document.isSuspended)
        model.performNoticeAction()
        XCTAssertTrue(document.isSuspended)
        XCTAssertEqual(document.storage.string, "")
        let remounted = try mount(model)
        defer { unmount(remounted) }
        XCTAssertEqual(remounted.canvas.editor.string, original)
    }

    func testReverseSortedCheckpointSplitUsesAdjacentNaturalDestination() throws {
        let model = try model()
        model.pads.isEnabled = true
        let source = try seed("first second", in: model)
        model.setCheckpointSort(.reverseChronological, dayBucket: 0)
        let surface = try mount(model)
        defer { unmount(surface) }
        let original = surface.canvas.editor.string
        surface.canvas.editor.setSelectedRange(NSRange(location: 6, length: 0))
        model.newPage()
        update(surface, model: model)
        let pages = surface.canvas.document.projection.pages
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.first?.id, source)
        XCTAssertEqual(pages.first?.text, "first ")
        XCTAssertEqual(pages.last?.text, "second")
        XCTAssertEqual(pages.first?.joinedNextUUID, pages.last?.uuid)
        XCTAssertEqual(surface.canvas.editor.string, original)
        XCTAssertEqual(model.pads.checkpointSortDirection(for: model.pads.activeID,
            onDate: model.dateKey(forDayBucket: 0)), .natural)
    }

    func testEmptySelectedCheckpointSurvivesRefreshAndFutureProjectionStaysVisible() throws {
        let model = try model()
        _ = try seed("text", in: model)
        let blank = try seed("", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        surface.canvas.open(page: blank)
        let caret = surface.canvas.editor.selectedRange()
        model.refresh()
        update(surface, model: model)
        XCTAssertEqual(model.selectedPageID, blank)
        XCTAssertEqual(surface.canvas.editor.selectedRange(), caret)
        let tab = try XCTUnwrap(model.tabs.first { $0.pageID == blank })
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        for offset in [-2, 3] {
            fields["page_day_offset"] = offset
            let projected = try JSONDecoder().decode(TabSummary.self, from: JSONSerialization.data(withJSONObject: fields))
            let timeline = TimeUnitProjection.project(tabs: [projected], selectedPageID: blank, unit: .day)
            XCTAssertTrue(timeline.units.flatMap(\.pageIDs).contains(blank))
        }
    }

    func testSplitRefusesANonadjacentDestinationWithoutChangingText() throws {
        let model = try model()
        _ = try seed("first", in: model)
        _ = try seed("middle", in: model)
        _ = try seed("last", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let document = surface.canvas.document
        let pages = document.projection.pages
        let text = document.storage.string
        XCTAssertFalse(document.splitCheckpoint(source: pages[0].id, at: 2, destination: pages[2].id))
        XCTAssertEqual(document.storage.string, text)
        document.refresh(force: true)
        XCTAssertEqual(document.storage.string, text)
    }

    func testLateDismantleDoesNotClearNewOwnersDocument() throws {
        let model = try model()
        _ = try seed("first checkpoint", in: model)
        let first = try mount(model)
        let second = try mount(model)
        defer { unmount(second) }
        let document = second.canvas.document
        XCTAssertTrue(first.canvas.document === document)
        unmount(first)
        XCTAssertTrue(model.activeEditor === second.canvas.editor)
        XCTAssertFalse(document.isSuspended)
        XCTAssertEqual(second.canvas.editor.string, "first checkpoint")
        second.canvas.editor.setSelectedRange(NSRange(location: 0, length: 0))
        second.canvas.editor.insertText("new ", replacementRange: second.canvas.editor.selectedRange())
        XCTAssertEqual(second.canvas.editor.string, "new first checkpoint")
    }

    func testSurfaceBecomesReadOnlyWhenItsCoreRosterIsEmpty() throws {
        let model = try model()
        _ = try seed("text", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        XCTAssertTrue(surface.canvas.editor.isEditable)
        for tab in model.tabs { XCTAssertTrue(model.coreClient.closeTab(id: tab.id)) }
        update(surface, model: model)
        XCTAssertTrue(surface.canvas.document.projection.pages.isEmpty)
        XCTAssertFalse(surface.canvas.editor.isEditable)
    }

    func testUnmountDropsContentAndRefreshDoesNotRepopulateInactiveDocument() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        let document = surface.canvas.document
        let text = surface.canvas.editor.string
        let selection = NSRange(location: 2, length: 6)
        surface.canvas.editor.setSelectedRange(selection)
        unmount(surface)
        XCTAssertTrue(document.isSuspended)
        XCTAssertEqual(document.storage.string, "")
        XCTAssertTrue(document.projection.pages.isEmpty)
        model.refresh()
        XCTAssertEqual(document.storage.string, "")
        let remounted = try mount(model)
        defer { unmount(remounted) }
        XCTAssertEqual(remounted.canvas.editor.string, text)
        XCTAssertEqual(remounted.canvas.editor.selectedRange(), selection)
    }

    func testDeletedPadAndDisabledPadScopesAreEvicted() throws {
        let model = try model()
        model.pads.isEnabled = true
        let pad = try XCTUnwrap(model.createPad(named: "temporary"))
        _ = try seed("text", in: model)
        weak var removedDocument: ContinuousPadDocument?
        do {
            let document = model.continuousPadDocument()
            removedDocument = document
        }
        XCTAssertNotNil(removedDocument)
        XCTAssertTrue(model.removePad(pad))
        XCTAssertNil(removedDocument)
        weak var disabledDocument: ContinuousPadDocument?
        do {
            let document = model.continuousPadDocument()
            disabledDocument = document
        }
        model.pads.isEnabled = false
        XCTAssertNil(disabledDocument)
    }

    func testCheckpointLabelsAreReusedAcrossCursorAndTextChanges() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let labels = surface.canvas.checkpointLabels
        XCTAssertEqual(labels.count, 2)
        surface.canvas.editor.setSelectedRange(NSRange(location: 1, length: 0))
        update(surface, model: model)
        XCTAssertTrue(zip(labels, surface.canvas.checkpointLabels).allSatisfy { $0 === $1 })
        surface.canvas.editor.insertText("more ", replacementRange: surface.canvas.editor.selectedRange())
        update(surface, model: model)
        XCTAssertEqual(surface.canvas.checkpointLabels.count, labels.count)
        XCTAssertTrue(zip(labels, surface.canvas.checkpointLabels).allSatisfy { $0 === $1 })
    }

    func testCheckpointMetadataRefreshesGeometryAndLabelsWithoutTextChanges() throws {
        let client = ContinuousMetadataFixtureClient()
        let model = try model(client: client)
        let page = try seed("same text", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let label = try XCTUnwrap(surface.canvas.checkpointLabels.first)
        let originalLabel = label.stringValue
        XCTAssertEqual(surface.canvas.extents.first { $0.page == page }?.bucket, 0)
        client.dayOffset = -1
        client.createdDelta = 3_600_000
        model.refresh()
        update(surface, model: model)
        XCTAssertEqual(surface.canvas.editor.string, "same text")
        XCTAssertEqual(surface.canvas.extents.first { $0.page == page }?.bucket, -1)
        XCTAssertTrue(surface.canvas.checkpointLabels.first === label)
        XCTAssertNotEqual(label.stringValue, originalLabel)
    }

    func testCheckpointLabelsUseConfiguredStampFormatsAndDisambiguateCollisions() throws {
        let client = ContinuousMetadataFixtureClient()
        let model = try model(client: client)
        let first = try seed("alpha", in: model)
        let second = try seed("bravo", in: model)
        client.createdOverrides = [first: 1_000, second: 2_000]
        model.stampFormat = .init(short: "'checkpoint'", fine: "'seconds 'ss")
        model.refresh()
        let surface = try mount(model)
        defer { unmount(surface) }
        let labels = surface.canvas.checkpointLabels
        XCTAssertEqual(labels.map(\.stringValue), ["seconds 01", "seconds 02"])
        model.stampFormat = .init(short: "'stamp 'ss", fine: "HH:mm:ss")
        update(surface, model: model)
        XCTAssertEqual(surface.canvas.checkpointLabels.map(\.stringValue), ["stamp 01", "stamp 02"])
        XCTAssertTrue(zip(labels, surface.canvas.checkpointLabels).allSatisfy { $0 === $1 })
    }

    func testPadSwitchSettlesMarkedTextBeforeSuspendingTheOldDocument() throws {
        let model = try model()
        model.pads.isEnabled = true
        let scratchPage = try seed("scratch words", in: model)
        let otherPad = try XCTUnwrap(model.createPad(named: "Other"))
        let otherPage = try seed("other words", in: model)
        model.activatePad(PadCatalog.scratchID)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let scratch = surface.canvas.document
        let insertion = NSRange(location: 2, length: 0)
        editor.setSelectedRange(insertion)
        editor.setMarkedText("IME", selectedRange: NSRange(location: 3, length: 0), replacementRange: insertion)
        XCTAssertTrue(editor.hasMarkedText())
        model.activatePad(otherPad)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertTrue(scratch.isSuspended)
        XCTAssertEqual(scratch.storage.string, "")
        update(surface, model: model)
        XCTAssertEqual(editor.string, "other words")
        editor.unmarkText()
        XCTAssertEqual(body(otherPage, in: model), "other words")
        XCTAssertEqual(body(scratchPage, in: model), "scIMEratch words")
        model.activatePad(PadCatalog.scratchID)
        update(surface, model: model)
        XCTAssertEqual(editor.string, "scIMEratch words")
        XCTAssertFalse(editor.hasMarkedText())
    }

    func testOptInContinuousTypingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["ONETIMEPAD_RUN_CONTINUOUS_BENCHMARK"] == "1" else {
            throw XCTSkip("Set ONETIMEPAD_RUN_CONTINUOUS_BENCHMARK=1 for the isolated typing benchmark.")
        }
        let client = ContinuousBenchmarkFixtureClient()
        let model = try model(client: client)
        let content = String(repeating: "A line of ordinary checkpoint text.\n", count: 30)
        for index in 0..<100 { _ = try seed("Checkpoint \(index)\n" + content, in: model) }
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let originalLength = editor.string.utf16.count
        editor.setSelectedRange(NSRange(location: originalLength, length: 0))
        update(surface, model: model)
        client.snapshotReads = 0
        var refreshMilliseconds: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            surface.canvas.document.refresh()
            refreshMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        let refreshReads = client.snapshotReads
        client.snapshotReads = 0
        var typingMilliseconds: [Double] = []
        var insertionMilliseconds: [Double] = []
        var geometryMilliseconds: [Double] = []
        var surfaceUpdateMilliseconds: [Double] = []
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            editor.insertText("x", replacementRange: editor.selectedRange())
            let inserted = ProcessInfo.processInfo.systemUptime
            surface.canvas.measure()
            let measured = ProcessInfo.processInfo.systemUptime
            update(surface, model: model)
            let finished = ProcessInfo.processInfo.systemUptime
            insertionMilliseconds.append((inserted - start) * 1_000)
            geometryMilliseconds.append((measured - inserted) * 1_000)
            surfaceUpdateMilliseconds.append((finished - measured) * 1_000)
            typingMilliseconds.append((finished - start) * 1_000)
        }
        XCTAssertEqual(editor.string.utf16.count, originalLength + 10)
        let typingReads = client.snapshotReads
        var restyleMilliseconds: [Double] = []
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            surface.coordinator.restyle()
            restyleMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        model.previewRendering = .never
        model.syntaxHighlightingEnabled = false
        update(surface, model: model)
        var plainTypingMilliseconds: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            editor.insertText("x", replacementRange: editor.selectedRange())
            update(surface, model: model)
            plainTypingMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        var directEditMilliseconds: [Double] = []
        for _ in 0..<5 {
            let at = editor.string.utf16.count
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(surface.canvas.document.apply([.ins(at: at, text: "x")], intent: .typing,
                selection: .init(before: NSRange(location: at, length: 0),
                    after: NSRange(location: at + 1, length: 0))))
            directEditMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        XCTAssertEqual(editor.string.utf16.count, originalLength + 20)
        let result: [String: Any] = [
            "pages": 100, "initialUTF16Length": originalLength,
            "unchangedRefreshMilliseconds": refreshMilliseconds, "unchangedRefreshSnapshotReads": refreshReads,
            "typingMilliseconds": typingMilliseconds, "typingSnapshotReads": typingReads,
            "insertionMilliseconds": insertionMilliseconds, "geometryMilliseconds": geometryMilliseconds,
            "surfaceUpdateMilliseconds": surfaceUpdateMilliseconds, "restyleMilliseconds": restyleMilliseconds,
            "plainTypingMilliseconds": plainTypingMilliseconds, "directEditMilliseconds": directEditMilliseconds,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("CONTINUOUS_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }
}

private final class ContinuousBenchmarkFixtureClient: CompanionClient, @unchecked Sendable {
    var snapshotReads = 0

    init() {
        super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: UUID().uuidString))
    }

    override func continuousSnapshot(sheet: UInt64) -> ContinuousPageSnapshot? {
        snapshotReads += 1
        return super.continuousSnapshot(sheet: sheet)
    }
}

private final class ContinuousMetadataFixtureClient: CompanionClient, @unchecked Sendable {
    var dayOffset = 0
    var createdDelta: UInt64 = 0
    var createdOverrides: [UInt64: UInt64] = [:]

    init() {
        super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: UUID().uuidString))
    }

    override func tabs() -> [TabSummary] {
        super.tabs().map { tab in
            TabSummary(id: tab.id, uuid: tab.uuid, pageUUID: tab.pageUUID, hasPage: tab.hasPage, pageID: tab.pageID,
                title: tab.title, titleSource: tab.titleSource, rungCode: tab.rungCode, rungLabel: tab.rungLabel,
                remainingMs: tab.remainingMs, remainingLabel: tab.remainingLabel,
                spokenRemaining: tab.spokenRemaining, fractionRemaining: tab.fractionRemaining,
                paused: tab.paused, holdToppedUp: tab.holdToppedUp, holdRemainingMs: tab.holdRemainingMs,
                chipCount: tab.chipCount, lastHour: tab.lastHour, pageHasContent: tab.pageHasContent,
                pageDayOffset: tab.hasPage ? dayOffset : nil,
                pageCreatedMs: tab.pageID.flatMap { createdOverrides[$0] } ?? tab.pageCreatedMs.map { $0 + createdDelta })
        }
    }
}
