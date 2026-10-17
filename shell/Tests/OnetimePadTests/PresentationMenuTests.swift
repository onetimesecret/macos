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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("notes.txt")
        try "notes\n".write(to: file, atomically: true, encoding: .utf8)
        companion_init()
        let handle = "startup-open".withCString { companion_new_ephemeral($0) }!
        let pages = PageModel(formFactor: .backdrop, defaults: defaults,
                              seams: .init(stateDirectory: directory,
                                           client: CompanionClient(adopting: handle)))
        let model = BackdropModel(defaults: defaults, pages: pages)
        let delegate = BackdropAppDelegate(model: model)

        delegate.application(NSApplication.shared, open: [file])
        XCTAssertTrue(pages.openFiles.isEmpty, "the launch's file waits for the restored roster")
        XCTAssertFalse(model.editorWindowOpen)

        // The same file opens directly, so the gate is what held it back.
        pages.openFile(at: file)
        XCTAssertEqual(pages.openFiles.map(\.name), ["notes.txt"])
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
