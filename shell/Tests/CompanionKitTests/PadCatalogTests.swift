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
    func testNewPadsUseV7AndLegacyIDsAreNotRemintedOnReload() throws {
        let defaults = try defaults()
        let catalog = PadCatalog(defaults: defaults)
        let pad = try XCTUnwrap(catalog.create(named: "Familia"))
        XCTAssertEqual(pad.uuid.6 >> 4, 7)
        XCTAssertEqual(pad.uuid.8 >> 6, 2)
        catalog.assign(tabUUID: "legacy-tab", to: pad)
        let legacy = "6D07A934-226E-4F3A-A799-099AE914AA42"
        let raw = try XCTUnwrap(defaults.data(forKey: PadCatalog.storageKey))
        let json = try XCTUnwrap(String(data: raw, encoding: .utf8))
        defaults.set(Data(json.replacingOccurrences(of: pad.uuidString, with: legacy).utf8), forKey: PadCatalog.storageKey)
        let restored = PadCatalog(defaults: defaults)
        XCTAssertNil(restored.loadFailure)
        XCTAssertEqual(restored.activeID, UUID(uuidString: legacy))
        XCTAssertEqual(restored.owner(ofTabUUID: "legacy-tab"), UUID(uuidString: legacy))
        XCTAssertEqual(restored.entries.first?.id, PadCatalog.scratchID)
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
    func testManualVisitWinsOverLegacyFutureTimestampsAndRemainsRecentAfterReload() throws {
        let defaults = try defaults()
        let catalog = PadCatalog(defaults: defaults)
        catalog.isEnabled = true
        catalog.appAssociationsEnabled = true
        let pads = try (0..<10).map { try XCTUnwrap(catalog.create(named: "Pad \($0)")) }
        catalog.addApplication("dev.zed.Zed", to: pads[0])
        catalog.addApplication("dev.zed.Zed", to: pads[9])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: PadCatalog.storageKey))) as? [String: Any])
        // Older builds stored wall-clock timestamps. All these values are in
        // the future relative to the review host, and the oldest pad is absent
        // from the bounded recent set before it is explicitly visited.
        json["lastUsed"] = pads.enumerated().flatMap {
            [$0.element.uuidString, 4_000_000_000 + Double($0.offset)] as [Any]
        }
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: PadCatalog.storageKey)
        let restored = PadCatalog(defaults: defaults)
        XCTAssertEqual(restored.pad(forApplication: "dev.zed.Zed"), pads[9])
        restored.activate(pads[0])
        XCTAssertEqual(restored.activeID, pads[0])
        XCTAssertEqual(restored.pad(forApplication: "dev.zed.Zed"), pads[0])
        XCTAssertEqual(PadCatalog(defaults: defaults).pad(forApplication: "dev.zed.Zed"), pads[0])
    }

    func testManualReselectionPromotesAnAutomaticallySelectedOlderPadOnce() throws {
        let catalog = PadCatalog(defaults: try defaults())
        catalog.isEnabled = true
        catalog.appAssociationsEnabled = true
        let older = try XCTUnwrap(catalog.create(named: "Familia"))
        let newer = try XCTUnwrap(catalog.create(named: "Otto"))
        catalog.addApplication("dev.zed.Zed", to: older)
        catalog.addApplication("dev.zed.Zed", to: newer)
        catalog.activate(older, recordRecency: false)
        XCTAssertEqual(catalog.activeID, older)
        XCTAssertEqual(catalog.pad(forApplication: "dev.zed.Zed"), newer)
        var changes = 0
        catalog.onChange = { changes += 1 }
        catalog.activate(older)
        XCTAssertEqual(catalog.pad(forApplication: "dev.zed.Zed"), older)
        XCTAssertEqual(changes, 1)
        catalog.activate(older)
        XCTAssertEqual(changes, 1, "the active manual MRU must remain a no-op")
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
    func testRenamingAndRemovingPadRetainsContentOwnershipInScratch() throws {
        let defaults = try defaults()
        let catalog = PadCatalog(defaults: defaults)
        let pad = try XCTUnwrap(catalog.create(named: "Typo"))
        catalog.assign(tabUUID: "tab", to: pad)
        catalog.assign(filePath: "/note.txt", to: pad)
        catalog.rememberSelection(tabUUID: "tab", filePath: "/note.txt", for: pad)
        XCTAssertFalse(catalog.rename(pad, to: "  "))
        XCTAssertFalse(catalog.rename(pad, to: String(repeating: "x", count: 81)))
        XCTAssertTrue(catalog.rename(pad, to: " Familia "))
        XCTAssertEqual(catalog.activePad.name, "Familia")
        XCTAssertFalse(catalog.remove(PadCatalog.scratchID))
        XCTAssertTrue(catalog.remove(pad))
        XCTAssertEqual(catalog.activeID, PadCatalog.scratchID)
        XCTAssertEqual(catalog.owner(ofTabUUID: "tab"), PadCatalog.scratchID)
        XCTAssertEqual(catalog.owner(ofFile: "/note.txt"), PadCatalog.scratchID)
        let restored = PadCatalog(defaults: defaults)
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertNil(restored.rememberedFile(for: pad))
    }
    func testNoOpSelectionAndImplicitScratchMovesDoNotPersist() throws {
        let catalog = PadCatalog(defaults: try defaults())
        let pad = try XCTUnwrap(catalog.create(named: "Familia"))
        catalog.assign(tabUUID: "tab", to: pad)
        catalog.remember(tabUUID: "tab", for: pad)
        var changes = 0
        catalog.onChange = { changes += 1 }
        catalog.activate(pad)
        catalog.assign(tabUUID: "tab", to: pad)
        catalog.remember(tabUUID: "tab", for: pad)
        let paths = catalog.showFullPaths
        catalog.showFullPaths = paths
        catalog.transferFiles([("/unowned.txt", "/new.txt")])
        catalog.assign(filePath: "/new.txt", to: PadCatalog.scratchID)
        XCTAssertEqual(changes, 0)
    }
    func testReconciliationPrunesClosedIdentitiesAndExpiredDayPreferences() throws {
        let defaults = try defaults()
        let catalog = PadCatalog(defaults: defaults)
        let pad = try XCTUnwrap(catalog.create(named: "Familia"))
        catalog.assign(tabUUID: "closed", to: pad)
        catalog.assign(tabUUID: "empty-surviving", to: pad)
        catalog.assign(filePath: "/closed.txt", to: pad)
        catalog.rememberSelection(tabUUID: "closed", filePath: "/closed.txt", for: pad)
        catalog.toggleCheckpointSort(for: pad, onDate: "2026-10-01")
        catalog.reconcileTabs(["empty-surviving"], checkpointKeys: [])
        catalog.reconcileFiles([])
        let restored = PadCatalog(defaults: defaults)
        XCTAssertEqual(restored.owner(ofTabUUID: "closed"), PadCatalog.scratchID)
        XCTAssertEqual(restored.owner(ofTabUUID: "empty-surviving"), pad)
        XCTAssertEqual(restored.owner(ofFile: "/closed.txt"), PadCatalog.scratchID)
        XCTAssertNil(restored.rememberedTab(for: pad))
        XCTAssertNil(restored.rememberedFile(for: pad))
        XCTAssertEqual(restored.checkpointSortDirection(for: pad, onDate: "2026-10-01"), .chronological)
    }
    func testSymlinkAndCaseAliasesCannotAcquireAnotherOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pad-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let catalog = PadCatalog(defaults: try defaults())
        let first = try XCTUnwrap(catalog.create(named: "First"))
        let second = try XCTUnwrap(catalog.create(named: "Second"))
        XCTAssertTrue(catalog.addFolder(root.path, to: first))
        XCTAssertFalse(catalog.addFolder(alias.path, to: second))
        XCTAssertEqual(catalog.pad(forPath: alias.appendingPathComponent("new.txt").path), first)
        let sensitivity = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        let alternate = directory.appendingPathComponent("work")
        if sensitivity == true {
            try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: false)
            XCTAssertTrue(catalog.addFolder(alternate.path, to: second))
        } else {
            XCTAssertFalse(catalog.addFolder(alternate.path, to: second))
            XCTAssertEqual(catalog.pad(forPath: alternate.appendingPathComponent("new.txt").path), first)
        }
    }
    func testRememberedFileFollowsPathTransferAndLegacyCatalogLoads() throws {
        let defaults = try defaults()
        let catalog = PadCatalog(defaults: defaults)
        let pad = try XCTUnwrap(catalog.create(named: "Familia"))
        catalog.assign(filePath: "/before.txt", to: pad)
        catalog.rememberSelection(tabUUID: "tab", filePath: "/before.txt", for: pad)
        catalog.transferFiles([("/before.txt", "/after.txt")])
        XCTAssertEqual(catalog.rememberedFile(for: pad), "/after.txt")
        XCTAssertEqual(PadCatalog(defaults: defaults).rememberedFile(for: pad), "/after.txt")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: PadCatalog.storageKey))) as? [String: Any])
        json.removeValue(forKey: "rememberedFiles")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: PadCatalog.storageKey)
        let legacy = PadCatalog(defaults: defaults)
        XCTAssertNil(legacy.loadFailure)
        XCTAssertEqual(legacy.owner(ofFile: "/after.txt"), pad)
    }

}
