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

    func testSaveAsWhileExperimentDisabledPreservesOwnershipAndRememberedFile() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let pad = try XCTUnwrap(model.createPad(named: "Familia"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pad-disabled-save-as-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let before = directory.appendingPathComponent("before.txt")
        let after = directory.appendingPathComponent("after.txt")
        try "hello".write(to: before, atomically: true, encoding: .utf8)
        model.openFile(at: before)
        let fileID = try XCTUnwrap(model.selectedFile)
        model.pads.isEnabled = false
        model.selectFile(fileID)
        model.fileCoordinator = FileCoordinator(panels: PadTestPanels(destination: after))
        model.saveActiveFileAs()
        let saved = try XCTUnwrap(model.activeFile)
        XCTAssertEqual(model.pads.owner(ofFile: saved.path), pad)
        XCTAssertEqual(model.pads.rememberedFile(for: pad), PadCatalog.normalizedPath(saved.path))
        model.pads.isEnabled = true
        XCTAssertEqual(model.selectedFile, fileID)
        XCTAssertEqual(model.navigationFiles.map(\.id), [fileID])
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

    func testPadNavigationDismissesConcealForPagesAndChips() throws {
        for useChip in [false, true] {
            let model = isolatedModel(defaults: try defaults())
            model.loadStateIfNeeded()
            model.pads.isEnabled = true
            let source = try XCTUnwrap(model.createPad(named: "Source"))
            model.newPage()
            let target: ConcealDraft.Target
            if useChip {
                let chip = try XCTUnwrap(model.sealText("private", replacing: NSRange(location: 0, length: 0)))
                target = .chip(chip.chipId)
            } else {
                target = .page(try XCTUnwrap(model.selectedPageID))
            }
            model.beginConceal(target)
            model.activatePad(PadCatalog.scratchID)
            XCTAssertNil(model.concealDraft)
            model.activatePad(source)
            model.beginConceal(target)
            XCTAssertNotNil(model.createPad(named: "Created"))
            XCTAssertNil(model.concealDraft)
            model.activatePad(source)
            model.beginConceal(target)
            XCTAssertTrue(model.removePad(source))
            XCTAssertNil(model.concealDraft)
        }
    }
    func testExperimentToggleDismissesConcealButSamePadEditsPreserveIt() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        let target = ConcealDraft.Target.page(try XCTUnwrap(model.selectedPageID))
        model.beginConceal(target)
        model.pads.isEnabled = true
        XCTAssertNil(model.concealDraft)
        let pad = try XCTUnwrap(model.createPad(named: "Familia"))
        model.newPage()
        let current = ConcealDraft.Target.page(try XCTUnwrap(model.selectedPageID))
        model.beginConceal(current)
        model.activatePad(pad)
        XCTAssertTrue(model.renamePad(pad, to: "Renamed"))
        model.pads.showFullPaths.toggle()
        model.pads.appAssociationsEnabled.toggle()
        XCTAssertEqual(model.concealDraft?.target, current)
        model.pads.isEnabled = false
        XCTAssertNil(model.concealDraft)
    }
    func testExperimentToggleKeepsPendingDirtyCloseVisibleAndRestoresItsOwner() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let owner = try XCTUnwrap(model.createPad(named: "Owner"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pad-toggle-dirty-\(UUID().uuidString).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        model.openFile(at: file)
        let id = try XCTUnwrap(model.selectedFile)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "dirty ")]))
        model.applyOps(sheet: id, opsJSON: ops)
        let storage = model.storage(for: id)
        let before = storage.string
        _ = model.closeActiveFile()
        model.pads.isEnabled = false
        XCTAssertEqual(model.selectedFile, id)
        XCTAssertEqual(model.pendingFileClose?.fileID, id)
        XCTAssertEqual(model.activeFile?.holdsUnsavedEdits, true)
        model.pads.activate(PadCatalog.scratchID) // Inactive navigation preference differs.
        model.pads.isEnabled = true
        XCTAssertEqual(model.pads.activeID, owner)
        XCTAssertEqual(model.selectedFile, id)
        XCTAssertEqual(model.pendingFileClose?.fileID, id)
        XCTAssertTrue(model.navigationFiles.contains { $0.id == id })
        XCTAssertTrue(model.storage(for: id) === storage)
        XCTAssertEqual(storage.string, before)
        model.resolvePendingFileClose(.keepEditing)
        XCTAssertNil(model.pendingFileClose)
        XCTAssertEqual(model.selectedFile, id)
        XCTAssertEqual(model.activeFile?.holdsUnsavedEdits, true)
    }
    func testKeepEditingAfterEnablingPadsReturnsToPreviousFilesOwner() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pad-toggle-close-return-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        let ownerA = try XCTUnwrap(model.createPad(named: "A"))
        model.openFile(at: first)
        let fileA = try XCTUnwrap(model.selectedFile)
        let ownerB = try XCTUnwrap(model.createPad(named: "B"))
        model.openFile(at: second)
        let fileB = try XCTUnwrap(model.selectedFile)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "dirty ")]))
        model.applyOps(sheet: fileB, opsJSON: ops)
        model.pads.isEnabled = false
        model.selectFile(fileA)
        model.closeFile(fileB)
        XCTAssertEqual(model.pendingFileClose?.fileID, fileB)
        XCTAssertEqual(model.selectedFile, fileB)
        model.pads.isEnabled = true
        XCTAssertEqual(model.pads.activeID, ownerB)
        model.resolvePendingFileClose(.keepEditing)
        XCTAssertNil(model.pendingFileClose)
        XCTAssertEqual(model.pads.activeID, ownerA)
        XCTAssertEqual(model.selectedFile, fileA)
        XCTAssertEqual(model.navigationFiles.map(\.id), [fileA])
        XCTAssertEqual(model.openFiles.first { $0.id == fileB }?.holdsUnsavedEdits, true)
    }

    func testReopeningExistingFilePreservesOwnerDespiteNewFolderBindingAndAlias() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pad-reopen-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        let alias = directory.appendingPathComponent("alias.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let owner = try XCTUnwrap(model.createPad(named: "Owner"))
        model.openFile(at: file)
        let id = try XCTUnwrap(model.selectedFile)
        let other = try XCTUnwrap(model.createPad(named: "Other"))
        XCTAssertTrue(model.pads.addFolder(directory.path, to: other))
        for supplied in [file, alias] {
            model.activatePad(other)
            model.openFile(at: supplied)
            XCTAssertEqual(model.selectedFile, id)
            XCTAssertEqual(model.openFiles.count, 1)
            XCTAssertEqual(model.pads.activeID, owner)
            XCTAssertEqual(model.pads.owner(ofFile: try XCTUnwrap(model.activeFile?.path)), owner)
        }
    }
    func testReopeningScratchFileDoesNotAcquireCurrentPadOwnership() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pad-reopen-scratch-\(UUID().uuidString).txt")
        try "scratch file".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        model.openFile(at: file)
        let id = try XCTUnwrap(model.selectedFile)
        _ = try XCTUnwrap(model.createPad(named: "Other"))
        model.openFile(at: file)
        XCTAssertEqual(model.selectedFile, id)
        XCTAssertEqual(model.pads.activeID, PadCatalog.scratchID)
        XCTAssertEqual(model.pads.owner(ofFile: try XCTUnwrap(model.activeFile?.path)), PadCatalog.scratchID)
        XCTAssertEqual(model.openFiles.count, 1)
    }

    func testSwitchingPadsRestoresSelectedFileAndRemovalRehomesWithoutDeleting() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let pad = try XCTUnwrap(model.createPad(named: "Familia"))
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let ink = model.storage(for: page)
        ink.append(NSAttributedString(string: "keep this ink"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pad-remember-file-\(UUID().uuidString).txt")
        try "file ink".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        model.openFile(at: file)
        let fileID = try XCTUnwrap(model.selectedFile)
        model.activatePad(PadCatalog.scratchID)
        model.activatePad(pad)
        XCTAssertEqual(model.selectedFile, fileID)
        XCTAssertEqual(model.activeFile?.id, fileID)
        XCTAssertTrue(model.renamePad(pad, to: "Renamed"))
        XCTAssertTrue(model.removePad(pad))
        XCTAssertEqual(model.pads.activeID, PadCatalog.scratchID)
        XCTAssertTrue(model.tabs.contains { $0.pageID == page })
        XCTAssertTrue(model.navigationFiles.contains { $0.id == fileID })
        XCTAssertTrue(model.storage(for: page) === ink)
        XCTAssertEqual(ink.string, "keep this ink")
    }
    func testPageExpiryPrunesDateOrderButRetainsSurvivingTabOwnership() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let pad = try XCTUnwrap(model.createPad(named: "Familia"))
        model.newPage()
        let tab = try XCTUnwrap(model.selection)
        let uuid = try XCTUnwrap(model.selectedTab?.uuid)
        let date = model.dateKey(forDayBucket: 0)
        model.toggleCheckpointSort(dayBucket: 0)
        XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: date), .reverseChronological)
        XCTAssertTrue(model.coreClient.setRung(tab: tab, rung: .oneHour))
        model.coreClient.ageForTests(byMs: 3 * 24 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
        XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: date), .chronological)
        XCTAssertEqual(model.pads.owner(ofTabUUID: uuid), pad)
        model.closeCurrent()
        XCTAssertEqual(model.pads.owner(ofTabUUID: uuid), PadCatalog.scratchID)
    }

    func testClosingFilePrunesItsRecordedOwnerAndRememberedSelection() throws {
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        model.pads.isEnabled = true
        let pad = try XCTUnwrap(model.createPad(named: "Familia"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pad-prune-closed-\(UUID().uuidString).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        model.openFile(at: file)
        let path = try XCTUnwrap(model.activeFile?.path)
        XCTAssertEqual(model.pads.owner(ofFile: path), pad)
        _ = model.closeActiveFile()
        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertEqual(model.pads.owner(ofFile: path), PadCatalog.scratchID)
        XCTAssertNil(model.pads.rememberedFile(for: pad))
    }
    func testFailedDraftRestoreDoesNotPruneSavedFileOwnership() throws {
        let defaults = try defaults()
        let catalog = PadCatalog(defaults: defaults)
        catalog.isEnabled = true
        let pad = try XCTUnwrap(catalog.create(named: "Familia"))
        catalog.assign(filePath: "/unrestored-file.txt", to: pad)
        catalog.rememberSelection(tabUUID: nil, filePath: "/unrestored-file.txt", for: pad)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pad-draft-refused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("unreadable draft state".utf8).write(to: FormFactor.draftsFileURL(in: directory))
        let model = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: .ephemeral(tag: UUID().uuidString)))
        model.refreshOpenFiles()
        model.loadStateIfNeeded()
        model.refreshOpenFiles()
        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertEqual(model.pads.owner(ofFile: "/unrestored-file.txt"), pad)
        XCTAssertEqual(model.pads.rememberedFile(for: pad), "/unrestored-file.txt")
    }

    func testRosterReadCrossingMidnightDefersCheckpointPruningUntilStableDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let before = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 23, minute: 59, second: 59)))
        let after = before.addingTimeInterval(2)
        XCTAssertNil(PageModel.validatedPadRosterDate(readStartedAt: before, readFinishedAt: after, calendar: calendar, finishedCalendar: calendar))
        let beforeReference = try XCTUnwrap(PageModel.validatedPadRosterDate(readStartedAt: before.addingTimeInterval(-1), readFinishedAt: before, calendar: calendar, finishedCalendar: calendar))
        XCTAssertEqual(PageModel.padDateKey(forDayBucket: 0, now: beforeReference, calendar: calendar), "2026-10-02")
        let catalog = PadCatalog(defaults: try defaults())
        let pad = try XCTUnwrap(catalog.create(named: "Familia"))
        catalog.toggleCheckpointSort(for: pad, onDate: "2026-10-02")
        catalog.assign(tabUUID: "closed", to: pad)
        catalog.reconcileTabs([], checkpointKeys: nil)
        XCTAssertEqual(catalog.checkpointSortDirection(for: pad, onDate: "2026-10-02"), .reverseChronological)
        XCTAssertEqual(catalog.owner(ofTabUUID: "closed"), PadCatalog.scratchID)
        let stableReference = try XCTUnwrap(PageModel.validatedPadRosterDate(readStartedAt: after, readFinishedAt: after.addingTimeInterval(1), calendar: calendar, finishedCalendar: calendar))
        let stableKey = pad.uuidString + "/" + PageModel.padDateKey(forDayBucket: -1, now: stableReference, calendar: calendar)
        catalog.reconcileTabs([], checkpointKeys: [stableKey])
        XCTAssertEqual(catalog.checkpointSortDirection(for: pad, onDate: "2026-10-02"), .reverseChronological)
        catalog.reconcileTabs([], checkpointKeys: [])
        XCTAssertEqual(catalog.checkpointSortDirection(for: pad, onDate: "2026-10-02"), .chronological)
    }
    func testRosterDateValidationRejectsTimezoneAndBackwardsClockChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12)))
        var movedCalendar = calendar
        movedCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 3600))
        XCTAssertNil(PageModel.validatedPadRosterDate(readStartedAt: now, readFinishedAt: now.addingTimeInterval(1), calendar: calendar, finishedCalendar: movedCalendar))
        XCTAssertNil(PageModel.validatedPadRosterDate(readStartedAt: now, readFinishedAt: now.addingTimeInterval(-1), calendar: calendar, finishedCalendar: calendar))
    }

    func testProjectedDaySortKeysStayStableForFuturePagesAndRosterReordering() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12)))
        XCTAssertEqual(PageModel.padDateKey(forDayBucket: 0, now: today, calendar: calendar), "2026-10-02")
        XCTAssertEqual(PageModel.padDateKey(forDayBucket: 4, now: today, calendar: calendar), "2026-10-02")
        XCTAssertEqual(PageModel.padDateKey(forDayBucket: -1, now: today, calendar: calendar), "2026-10-01")
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3)))
        XCTAssertEqual(PageModel.padDateKey(forDayBucket: -1, now: midnight, calendar: calendar), "2026-10-02")
        let model = isolatedModel(defaults: try defaults())
        model.loadStateIfNeeded()
        let original = try XCTUnwrap(model.tabs.first)
        func summary(id: UInt64, offset: Int, stamp: UInt64) throws -> TabSummary {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            json["id"] = id
            json["page_day_offset"] = offset
            json["page_created_ms"] = stamp
            let decoded = try JSONDecoder().decode(TabSummary.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.pageDayOffset, offset, "the fixture must exercise the supplied day bucket")
            XCTAssertEqual(decoded.pageCreatedMs, stamp, "the fixture must retain its distinct creation stamp")
            return decoded
        }
        let future = try summary(id: 101, offset: 4, stamp: 1_900_000_000_000)
        let current = try summary(id: 102, offset: 0, stamp: 1_791_000_000_000)
        let yesterday = try summary(id: 103, offset: -1, stamp: 1_790_000_000_000)
        let owner = PadCatalog.scratchID
        let todayKey = owner.uuidString + "/2026-10-02"
        let expected: Set<String> = [todayKey, owner.uuidString + "/2026-10-01"]
        XCTAssertEqual(PageModel.checkpointSortKeys(for: [future, current, yesterday], now: today, calendar: calendar, owner: { _ in owner }), expected)
        XCTAssertEqual(PageModel.checkpointSortKeys(for: [yesterday, current, future], now: today, calendar: calendar, owner: { _ in owner }), expected)
        let onlyFuture = PageModel.checkpointSortKeys(for: [future], now: today, calendar: calendar, owner: { _ in owner })
        XCTAssertEqual(onlyFuture, [todayKey])
        let catalog = PadCatalog(defaults: try defaults())
        catalog.toggleCheckpointSort(for: owner, onDate: "2026-10-02")
        catalog.reconcileTabs([], checkpointKeys: onlyFuture)
        XCTAssertEqual(catalog.checkpointSortDirection(for: owner, onDate: "2026-10-02"), .reverseChronological)
    }

    func testFailedContentRestoreDoesNotPruneSavedPadOwnership() throws {
        let defaults = try defaults()
        let catalog = PadCatalog(defaults: defaults)
        catalog.isEnabled = true
        let pad = try XCTUnwrap(catalog.create(named: "Familia"))
        catalog.assign(tabUUID: "unrestored-tab", to: pad)
        catalog.remember(tabUUID: "unrestored-tab", for: pad)
        catalog.toggleCheckpointSort(for: pad, onDate: "2026-10-01")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pad-refused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("unreadable core state".utf8).write(to: FormFactor.stateFileURL(in: directory))
        let model = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: .ephemeral(tag: UUID().uuidString)))
        model.refresh() // Before restore, an empty ephemeral roster is not authoritative.
        model.loadStateIfNeeded()
        model.refresh()
        XCTAssertEqual(model.pads.owner(ofTabUUID: "unrestored-tab"), pad)
        XCTAssertEqual(model.pads.rememberedTab(for: pad), "unrestored-tab")
        XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: "2026-10-01"), .reverseChronological)
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
