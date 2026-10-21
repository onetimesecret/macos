import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

final class PresentationMenuTests: XCTestCase {
    @MainActor
    func testActivationBeforeStartupCompletesDoesNotMountEditor() {
        let suite = "onetimepad.startup-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        companion_init()
        let handle = "startup-gate".withCString { companion_new_ephemeral($0) }!
        let pages = PageModel(formFactor: .backdrop, defaults: defaults,
                              seams: .init(stateDirectory: directory,
                                           client: CompanionClient(adopting: handle)))
        let model = BackdropModel(defaults: defaults, pages: pages)
        let delegate = BackdropAppDelegate(model: model)
        delegate.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertFalse(model.editorWindowOpen)
        XCTAssertEqual(model.stance, .resting)
    }

    @MainActor
    func testAFinderOpenBeforeStartupCompletesWaitsForStartup() throws {
        let suite = "onetimepad.startup-open-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suite).fixtures", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let file = fixtures.appendingPathComponent("notes.txt")
        try "notes\n".write(to: file, atomically: true, encoding: .utf8)
        companion_init()
        let handle = "startup-open".withCString { companion_new_ephemeral($0) }!
        let pages = PageModel(formFactor: .backdrop, defaults: defaults,
                              seams: .init(stateDirectory: directory,
                                           client: CompanionClient(adopting: handle)))
        let model = BackdropModel(defaults: defaults, pages: pages)
        let delegate = BackdropAppDelegate(model: model)
        var selections = 0
        delegate.selectEditor = { selections += 1 }

        delegate.application(NSApplication.shared, open: [file])
        XCTAssertEqual(delegate.finderDocuments, [file], "the launch's file waits for the restored roster")
        XCTAssertTrue(pages.openFiles.isEmpty)
        XCTAssertEqual(selections, 0)

        // A launch restores the roster in `model.start()`, before `completeStartup`.
        pages.loadStateIfNeeded()
        delegate.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertEqual(delegate.finderDocuments, [])
        XCTAssertEqual(pages.openFiles.map(\.name), ["notes.txt"])
        XCTAssertEqual(selections, 1)
    }

    @MainActor
    func testAFinderOpenDuringACloseDecisionOpensOnceItResolves() throws {
        let suite = "onetimepad.close-decision-open-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suite).fixtures", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let notes = fixtures.appendingPathComponent("notes.txt")
        try "notes\n".write(to: notes, atomically: true, encoding: .utf8)
        let draft = fixtures.appendingPathComponent("draft.txt")
        try "draft\n".write(to: draft, atomically: true, encoding: .utf8)
        companion_init()
        let handle = "close-decision-open".withCString { companion_new_ephemeral($0) }!
        let pages = PageModel(formFactor: .backdrop, defaults: defaults,
                              seams: .init(stateDirectory: directory,
                                           client: CompanionClient(adopting: handle)))
        let model = BackdropModel(defaults: defaults, pages: pages)
        let delegate = BackdropAppDelegate(model: model)
        var selections = 0
        delegate.selectEditor = { selections += 1 }
        pages.loadStateIfNeeded()
        delegate.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
        pages.pads.isEnabled = true
        pages.openFile(at: notes)
        let id = try XCTUnwrap(pages.openFiles.first?.id)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "the ")]))
        pages.applyOps(sheet: id, opsJSON: ops)
        pages.closeActiveFile()
        XCTAssertTrue(pages.openRefusedForCloseDecision)

        delegate.application(NSApplication.shared, open: [draft])
        XCTAssertEqual(delegate.finderDocuments, [draft])
        XCTAssertEqual(pages.openFiles.map(\.name), ["notes.txt"])
        XCTAssertEqual(selections, 0)

        pages.resolvePendingFileClose(.keepEditing)
        drainMainQueue()
        XCTAssertEqual(delegate.finderDocuments, [])
        XCTAssertEqual(pages.openFiles.map(\.name), ["notes.txt", "draft.txt"])
        XCTAssertEqual(selections, 1)
    }

    @MainActor
    func testAmbientPreferenceSurvivesNativeMenuUpdate() {
        // A plain target has no matching selector. Automatic AppKit validation
        // would disable this item even when the model enables the panel.
        let target = NSObject()
        for enabled in [true, false] {
            let menu = NSMenu()
            BackdropAppDelegate.addPresentationItems(
                to: menu, ambientPanelEnabled: enabled, target: target)
            menu.update()
            XCTAssertFalse(menu.autoenablesItems)
            XCTAssertTrue(menu.items[0].isEnabled)
            XCTAssertEqual(menu.items[1].isEnabled, enabled)
            XCTAssertTrue(menu.items[1].target === target)
        }
    }
}
