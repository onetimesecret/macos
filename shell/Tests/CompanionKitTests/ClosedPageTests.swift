import AppKit
import XCTest

@testable import CompanionKit

private final class ClosedPageSaveClient: CompanionClient, @unchecked Sendable {
    var refusesSave = false
    private(set) var destructiveCloses = 0

    init(tag: String) {
        super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
    }

    override func persistSave(to path: String) -> Bool {
        refusesSave ? false : super.persistSave(to: path)
    }

    override func closeTab(id: UInt64) -> Bool {
        destructiveCloses += 1
        return super.closeTab(id: id)
    }
}

@MainActor
final class ClosedPageTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let tag: String
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("closed-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "closed-pages-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(directory: directory, defaults: defaults, tag: suite)
    }

    private func model(_ fixture: Fixture, client: CompanionClient? = nil) -> PageModel {
        let model = PageModel(formFactor: .panel, defaults: fixture.defaults,
            seams: .init(stateDirectory: fixture.directory,
                client: client ?? .ephemeral(tag: fixture.tag), saveDebounce: 3_600,
                saveRetryDebounce: 3_600))
        model.loadStateIfNeeded()
        return model
    }

    private func seed(_ text: String, in model: PageModel) throws -> TabSummary {
        let tab = try XCTUnwrap(model.selectedTab)
        let page = try XCTUnwrap(tab.pageID)
        model.applyOps(sheet: page,
            opsJSON: try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: text)])))
        return try XCTUnwrap(model.tabs.first { $0.id == tab.id })
    }

    private func ink(_ model: PageModel, page: UInt64) -> String {
        model.coreClient.documentRuns(sheet: page).compactMap { run in
            if case .ink(let text) = run { return text }
            return nil
        }.joined()
    }

    func testCloseInBothLayoutsHidesAndReopensTheSameSavedPageWithoutDiscard() throws {
        for timeline in [false, true] {
            let fixture = try fixture()
            let client = ClosedPageSaveClient(tag: fixture.tag)
            let model = model(fixture, client: client)
            let tab = try seed("saved private draft", in: model)
            let page = try XCTUnwrap(tab.pageID)
            model.showsTimeUnits = timeline
            let storage = model.storage(for: page)
            let events = model.coreClient.ledger().map(\.event)

            model.closeCurrent()

            XCTAssertTrue(model.navigationTabs.isEmpty)
            XCTAssertTrue(model.continuousTabs(scope: "legacy").isEmpty)
            XCTAssertNil(model.selection)
            XCTAssertEqual(model.tabs.map(\.id), [tab.id])
            XCTAssertEqual(model.closedTabs.map(\.id), [tab.id])
            XCTAssertEqual(ink(model, page: page), "saved private draft")
            XCTAssertEqual(model.coreClient.ledger().map(\.event), events)
            XCTAssertEqual(client.destructiveCloses, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                FormFactor.stateFileURL(in: fixture.directory).path))

            XCTAssertTrue(model.reopenLastClosedTab())
            XCTAssertEqual(model.selection, tab.id)
            XCTAssertEqual(model.selectedPageID, page)
            XCTAssertEqual(model.tabs.count, 1)
            XCTAssertTrue(model.storage(for: page) === storage)
            XCTAssertEqual(ink(model, page: page), "saved private draft")
            XCTAssertTrue(model.closedTabs.isEmpty)
        }
    }

    func testClosingEveryPagePreservesSnapshotAndClosedOrderAcrossRestart() throws {
        let fixture = try fixture()
        let first = model(fixture)
        let alpha = try seed("alpha saved", in: first)
        first.newPage()
        let beta = try seed("beta saved", in: first)
        first.close(alpha.id)
        first.close(beta.id)
        XCTAssertTrue(first.navigationTabs.isEmpty)
        XCTAssertEqual(first.closedTabs.map(\.uuid), [beta.uuid, alpha.uuid])

        let second = model(fixture)
        XCTAssertTrue(second.navigationTabs.isEmpty)
        XCTAssertNil(second.selection)
        XCTAssertEqual(second.tabs.count, 2)
        XCTAssertEqual(second.closedTabs.map(\.uuid), [beta.uuid, alpha.uuid])
        XCTAssertTrue(second.reopenLastClosedTab())
        let restored = try XCTUnwrap(second.selectedTab)
        XCTAssertEqual(restored.uuid, beta.uuid)
        XCTAssertEqual(ink(second, page: try XCTUnwrap(restored.pageID)), "beta saved")
        XCTAssertEqual(second.tabs.count, 2)
    }

    func testClosedPageStillExpiresAndReopeningItsSlotDoesNotMintContent() throws {
        let fixture = try fixture()
        let model = model(fixture)
        let tab = try seed("expires while hidden", in: model)
        model.showsTimeUnits = true
        model.close(tab.id)
        XCTAssertTrue(model.coreClient.ageForTests(byMs: 31 * 24 * 60 * 60 * 1_000))
        _ = model.settleCoreEvent()
        let expired = try XCTUnwrap(model.closedTabs.first)
        XCTAssertEqual(expired.uuid, tab.uuid)
        XCTAssertFalse(expired.hasPage)
        let events = model.coreClient.ledger().map(\.event)

        XCTAssertTrue(model.reopenClosedTab(expired.id))

        XCTAssertFalse(model.showsTimeUnits)
        XCTAssertEqual(model.selection, expired.id)
        XCTAssertNil(model.selectedPageID)
        XCTAssertFalse(try XCTUnwrap(model.selectedTab).hasPage)
        XCTAssertEqual(model.coreClient.ledger().map(\.event), events)
        XCTAssertEqual(model.tabs.count, 1)
    }

    func testRefusedSaveLeavesPageVisibleAndNeverCallsDestructiveClose() throws {
        let fixture = try fixture()
        let client = ClosedPageSaveClient(tag: fixture.tag)
        let model = model(fixture, client: client)
        let tab = try seed("not saved yet", in: model)
        client.refusesSave = true

        model.close(tab.id)

        XCTAssertEqual(model.navigationTabs.map(\.id), [tab.id])
        XCTAssertTrue(model.closedTabs.isEmpty)
        XCTAssertEqual(model.selection, tab.id)
        XCTAssertEqual(client.destructiveCloses, 0)
        XCTAssertEqual(model.saveStatus, .failed)
    }

    func testClosedRosterIsPadScopedAndInactiveContinuousProjectionAlsoFiltersIt() throws {
        let model = model(try fixture())
        let scratch = try seed("scratch saved", in: model)
        model.pads.isEnabled = true
        let other = try XCTUnwrap(model.createPad(named: "Other"))
        model.newPage()
        let otherTab = try seed("other saved", in: model)
        model.close(scratch.id)
        XCTAssertEqual(model.pads.activeID, other)
        XCTAssertEqual(model.navigationTabs.map(\.id), [otherTab.id])
        XCTAssertTrue(model.closedTabs.isEmpty)
        XCTAssertTrue(model.continuousTabs(scope: PadCatalog.scratchID.uuidString).isEmpty)

        model.activatePad(PadCatalog.scratchID)
        XCTAssertEqual(model.closedTabs.map(\.id), [scratch.id])
        XCTAssertFalse(model.reopenClosedTab(otherTab.id))
        XCTAssertTrue(model.reopenClosedTab(scratch.id))
        XCTAssertEqual(model.selection, scratch.id)
        XCTAssertEqual(model.navigationTabs.map(\.id), [scratch.id])
        model.close(scratch.id)
        model.pads.isEnabled = false
        XCTAssertEqual(model.navigationTabs.map(\.id), [otherTab.id])
        XCTAssertTrue(model.continuousTabs(scope: "legacy").allSatisfy { $0.id != scratch.id })
    }

    func testReorderingVisibleTabsTranslatesPastHiddenSlotsWithPadsOnOrOff() throws {
        for padsEnabled in [false, true] {
            let model = model(try fixture())
            let hidden = try seed("hidden saved", in: model)
            model.close(hidden.id)
            model.pads.isEnabled = padsEnabled
            model.newPage()
            let beta = try seed("visible beta", in: model)
            model.newPage()
            let gamma = try seed("visible gamma", in: model)
            var otherPadTab: TabSummary?
            if padsEnabled {
                _ = try XCTUnwrap(model.createPad(named: "Other"))
                model.newPage()
                otherPadTab = try seed("other pad", in: model)
                model.activatePad(PadCatalog.scratchID)
            }
            XCTAssertEqual(model.navigationTabs.map(\.id), [beta.id, gamma.id])

            model.move(beta.id, to: 1)
            XCTAssertEqual(model.navigationTabs.map(\.id), [gamma.id, beta.id])
            XCTAssertEqual(model.closedTabs.map(\.id), [hidden.id])
            XCTAssertEqual(model.tabs.first?.id, hidden.id)
            if let otherPadTab { XCTAssertEqual(model.tabs.last?.id, otherPadTab.id) }

            model.move(beta.id, to: 0)
            XCTAssertEqual(model.navigationTabs.map(\.id), [beta.id, gamma.id])
            XCTAssertEqual(model.tabs.first?.id, hidden.id)
            XCTAssertEqual(model.tabs.count, padsEnabled ? 4 : 3)
        }
    }

}
