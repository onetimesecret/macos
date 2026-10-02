import AppKit
import XCTest
@testable import CompanionKit

@MainActor
final class PadModelTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "pad-model-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }
    func testSwitchingEmptyPadDoesNotMintAndExistingTabsStayInScratch() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        let existing = model.tabs
        model.pads.isEnabled = true
        XCTAssertEqual(model.navigationTabs.map(\.id), existing.map(\.id))
        let familia = try XCTUnwrap(model.createPad(named: "Familia"))
        XCTAssertEqual(model.pads.activeID, familia)
        XCTAssertTrue(model.navigationTabs.isEmpty)
        XCTAssertNil(model.selectedPageID)
        XCTAssertEqual(model.tabs.count, existing.count)
        model.activatePad(PadCatalog.scratchID)
        XCTAssertEqual(model.navigationTabs.map(\.id), existing.map(\.id))
    }
    func testNewPageOwnershipKeepsInactiveInkStorageAndDisablingRevealsAll() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        let scratchPage = try XCTUnwrap(model.selectedPageID)
        let storage = model.storage(for: scratchPage)
        storage.append(NSAttributedString(string: "Scratch ink"))
        model.pads.isEnabled = true
        let familia = try XCTUnwrap(model.createPad(named: "Familia"))
        model.newPage()
        let familiaTab = try XCTUnwrap(model.selection)
        XCTAssertEqual(model.navigationTabs.map(\.id), [familiaTab])
        XCTAssertEqual(model.pads.owner(ofTabUUID: model.selectedTab?.uuid), familia)
        model.refresh()
        XCTAssertTrue(model.storage(for: scratchPage) === storage)
        XCTAssertEqual(storage.string, "Scratch ink")
        model.activatePad(PadCatalog.scratchID)
        XCTAssertEqual(model.selectedPageID, scratchPage)
        model.pads.isEnabled = false
        XCTAssertEqual(model.navigationTabs.count, 2)
        model.select(index: 1)
        XCTAssertEqual(model.selection, familiaTab)
    }
    func testOpenFileRoutesUsingOnlyExplicitSuppliedPath() throws {
        let defaults = try defaults()
        let model = isolatedModel(defaults: defaults)
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pad-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let familia = try XCTUnwrap(model.createPad(named: "Familia"))
        XCTAssertTrue(model.pads.addFolder(directory.path, to: familia))
        model.activatePad(PadCatalog.scratchID)
        model.openFile(at: file)
        XCTAssertEqual(model.pads.activeID, familia)
        XCTAssertEqual(model.navigationFiles.count, 1)
        model.activatePad(PadCatalog.scratchID)
        XCTAssertTrue(model.navigationFiles.isEmpty)
        XCTAssertEqual(model.openFiles.count, 1)
    }
    func testUUIDOwnershipSurvivesDenseIDRemintOnRelaunch() throws {
        let defaults = try defaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pad-relaunch-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let tag = UUID().uuidString
        let first = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: .ephemeral(tag: tag)))
        first.loadStateIfNeeded()
        first.pads.isEnabled = true
        let familia = try XCTUnwrap(first.createPad(named: "Familia"))
        first.newPage()
        let uuid = try XCTUnwrap(first.selectedTab?.uuid)
        first.activatePad(PadCatalog.scratchID)
        first.closeCurrent()
        first.activatePad(familia)
        XCTAssertTrue(first.saveState())
        let second = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: .ephemeral(tag: tag)))
        second.loadStateIfNeeded()
        XCTAssertEqual(second.pads.activeID, familia)
        XCTAssertEqual(second.navigationTabs.count, 1)
        XCTAssertEqual(second.navigationTabs.first?.uuid, uuid)
        XCTAssertEqual(second.selection, 1, "dense counter changed; ownership must not")
    }
    func testSoftAppRouteYieldsToExplicitFileInBothOrdersAndModal() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        model.pads.appAssociationsEnabled = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pad-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("context.txt")
        try "context".write(to: file, atomically: true, encoding: .utf8)
        let hard = try XCTUnwrap(model.createPad(named: "Hard folder"))
        XCTAssertTrue(model.pads.addFolder(directory.path, to: hard))
        let soft = try XCTUnwrap(model.createPad(named: "Soft app"))
        model.pads.addApplication("example.editor", to: soft)
        model.activatePad(PadCatalog.scratchID)
        ModalSession.run { model.routeFromApplication("example.editor") }
        XCTAssertEqual(model.pads.activeID, PadCatalog.scratchID)
        model.routeFromApplication("example.editor")
        XCTAssertEqual(model.pads.activeID, soft)
        model.openFile(at: file)
        XCTAssertEqual(model.pads.activeID, hard)
        model.routeFromApplication("example.editor")
        XCTAssertEqual(model.pads.activeID, hard, "explicit file context wins regardless of notification order")
        XCTAssertEqual(model.pads.owner(ofFile: try XCTUnwrap(model.activeFile).path), hard)
    }

    func testFileOwnershipTransfersOnSaveAs() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let pad = try XCTUnwrap(model.createPad(named: "Familia"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pad-save-as-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("before.txt")
        let second = directory.appendingPathComponent("after.txt")
        try "hello".write(to: first, atomically: true, encoding: .utf8)
        model.openFile(at: first)
        let panels = PadTestPanels(destination: second)
        model.fileCoordinator = FileCoordinator(panels: panels)
        model.saveActiveFileAs()
        let saved = try XCTUnwrap(model.activeFile)
        XCTAssertEqual(URL(fileURLWithPath: saved.path).lastPathComponent, "after.txt")
        XCTAssertEqual(model.pads.owner(ofFile: saved.path), pad)
        XCTAssertEqual(model.navigationFiles.count, 1)
    }

    func testInactiveExpiryKeepsOtherPadContentAndDoesNotMint() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        let scratch = try XCTUnwrap(model.selection)
        XCTAssertTrue(model.coreClient.setRung(tab: scratch, rung: .oneHour))
        model.pads.isEnabled = true
        let familia = try XCTUnwrap(model.createPad(named: "Familia"))
        model.newPage()
        let active = try XCTUnwrap(model.selection)
        let activePage = try XCTUnwrap(model.selectedPageID)
        XCTAssertTrue(model.coreClient.setRung(tab: active, rung: .sevenDays))
        model.coreClient.ageForTests(byMs: 3 * 24 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
        XCTAssertEqual(model.pads.activeID, familia)
        XCTAssertEqual(model.selectedPageID, activePage)
        XCTAssertFalse(try XCTUnwrap(model.tabs.first { $0.id == scratch }).hasPage)
        XCTAssertTrue(try XCTUnwrap(model.navigationTabs.first).hasPage)
        let count = model.tabs.count
        model.activatePad(PadCatalog.scratchID)
        XCTAssertNil(model.selectedPageID)
        XCTAssertEqual(model.tabs.count, count)
    }

    func testPendingFileCloseBlocksPadAndAppAndExplicitFileRoutes() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let current = try XCTUnwrap(model.createPad(named: "Current"))
        let other = try XCTUnwrap(model.createPad(named: "Other"))
        model.pads.addApplication("example.editor", to: other)
        model.pads.appAssociationsEnabled = true
        model.activatePad(current)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pad-pending-\(UUID().uuidString).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        model.openFile(at: file)
        let id = try XCTUnwrap(model.selectedFile)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "dirty")]))
        model.applyOps(sheet: id, opsJSON: ops)
        _ = model.closeActiveFile()
        XCTAssertNotNil(model.pendingFileClose)
        model.activatePad(other)
        model.routeFromApplication("example.editor")
        model.openFile(at: file)
        XCTAssertEqual(model.pads.activeID, current)
        XCTAssertEqual(model.selectedFile, id)
        XCTAssertNotNil(model.pendingFileClose)
    }

}


@MainActor
private final class PadTestPanels: FilePanels {
    let destination: URL
    init(destination: URL) { self.destination = destination }
    func chooseFileToOpen() -> URL? { nil }
    func chooseDestination(suggestedName: String) -> URL? { destination }
    func chooseFileToLocate(named name: String, in directory: URL) -> URL? { nil }
}
