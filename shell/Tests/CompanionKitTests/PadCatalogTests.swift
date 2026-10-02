import XCTest
@testable import CompanionKit

@MainActor
final class PadCatalogTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "pad-catalog-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }
    func testFolderRootsAreExclusiveAndLongestComponentMatchWins() throws {
        let catalog = PadCatalog(defaults: try defaults())
        let familia = try XCTUnwrap(catalog.create(named: "Familia"))
        let docs = try XCTUnwrap(catalog.create(named: "Docs"))
        XCTAssertTrue(catalog.addFolder("/work/familia", to: familia))
        XCTAssertTrue(catalog.addFolder("/work/familia/docs", to: docs))
        XCTAssertFalse(catalog.addFolder("/work/familia/../familia", to: docs))
        XCTAssertFalse(catalog.addFolder("/scratch", to: PadCatalog.scratchID))
        XCTAssertEqual(catalog.pad(forPath: "/work/familia/file.swift"), familia)
        XCTAssertEqual(catalog.pad(forPath: "/work/familia/docs/note.md"), docs)
        XCTAssertNil(catalog.pad(forPath: "/work/familia-other/file.swift"))
        catalog.removeFolder("/work/familia/docs", from: docs)
        XCTAssertEqual(catalog.pad(forPath: "/work/familia/docs/note.md"), familia)
    }
    func testAppMatchingUsesRecentManualSelectionAndCanBeDisabled() throws {
        let catalog = PadCatalog(defaults: try defaults())
        catalog.isEnabled = true
        let familia = try XCTUnwrap(catalog.create(named: "Familia"))
        let otto = try XCTUnwrap(catalog.create(named: "Otto"))
        catalog.addApplication("dev.zed.Zed", to: familia)
        catalog.addApplication("dev.zed.Zed", to: otto)
        XCTAssertNil(catalog.pad(forApplication: "dev.zed.Zed"))
        catalog.appAssociationsEnabled = true
        catalog.activate(familia)
        XCTAssertEqual(catalog.pad(forApplication: "dev.zed.Zed"), familia)
        catalog.activate(otto, recordRecency: false)
        XCTAssertEqual(catalog.pad(forApplication: "dev.zed.Zed"), familia)
        for n in 0..<10 { _ = catalog.create(named: "Other \(n)") }
        XCTAssertNil(catalog.pad(forApplication: "dev.zed.Zed"))
    }
    func testOwnershipAndIndependentDateSortSurviveCatalogReload() throws {
        let defaults = try defaults()
        let catalog = PadCatalog(defaults: defaults)
        catalog.isEnabled = true
        let pad = try XCTUnwrap(catalog.create(named: "Familia"))
        catalog.assign(tabUUID: "stable-tab-uuid", to: pad)
        catalog.assign(filePath: "/work/note.md", to: pad)
        catalog.toggleDaySort(for: pad)
        catalog.toggleCheckpointSort(for: pad, onDate: "2026-10-01")
        let restored = PadCatalog(defaults: defaults)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertEqual(restored.owner(ofTabUUID: "stable-tab-uuid"), pad)
        XCTAssertEqual(restored.owner(ofFile: "/work/note.md"), pad)
        XCTAssertEqual(restored.daySortDirection(for: pad), .chronological)
        XCTAssertEqual(restored.checkpointSortDirection(for: pad, onDate: "2026-10-01"), .reverseChronological)
        XCTAssertEqual(restored.checkpointSortDirection(for: pad, onDate: "2026-10-02"), .chronological)
    }
    func testUnreadableCatalogCannotBeEnabledOrOverwritten() throws {
        let defaults = try defaults()
        let bytes = Data("{not readable}".utf8)
        defaults.set(bytes, forKey: PadCatalog.storageKey)
        let catalog = PadCatalog(defaults: defaults)
        XCTAssertNotNil(catalog.loadFailure)
        catalog.isEnabled = true
        XCTAssertFalse(catalog.isEnabled)
        XCTAssertNil(catalog.create(named: "Lost after restart"))
        XCTAssertFalse(catalog.addFolder("/work", to: PadCatalog.scratchID))
        XCTAssertEqual(defaults.data(forKey: PadCatalog.storageKey), bytes)
    }
    func testUnknownVersionIsPreserved() throws {
        let defaults = try defaults()
        let catalog = PadCatalog(defaults: defaults)
        catalog.isEnabled = true
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: PadCatalog.storageKey))) as? [String: Any])
        json["version"] = 2
        let bytes = try JSONSerialization.data(withJSONObject: json)
        defaults.set(bytes, forKey: PadCatalog.storageKey)
        let restored = PadCatalog(defaults: defaults)
        XCTAssertNotNil(restored.loadFailure)
        restored.showFullPaths = true
        XCTAssertEqual(defaults.data(forKey: PadCatalog.storageKey), bytes)
    }
}
