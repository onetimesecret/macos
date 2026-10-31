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
}

private final class ContinuousMetadataFixtureClient: CompanionClient, @unchecked Sendable {
    var dayOffset = 0
    var createdDelta: UInt64 = 0

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
                pageDayOffset: tab.hasPage ? dayOffset : nil, pageCreatedMs: tab.pageCreatedMs.map { $0 + createdDelta })
        }
    }
}
