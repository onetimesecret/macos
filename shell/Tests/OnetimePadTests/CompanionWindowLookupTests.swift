import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

/// The delegate's companion lookup (#293), asked of windows it never made.
/// Throwaway defaults and injected seams, never the installed state.
@MainActor
final class CompanionWindowLookupTests: XCTestCase {

    private func makeDelegate(tag: String) -> BackdropAppDelegate {
        let name = "onetimepad.test.companion-lookup.\(tag).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-lookup-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        companion_init()
        guard let handle = tag.withCString({ companion_new_ephemeral($0) }) else {
            fatalError("the core refused to create an ephemeral handle")
        }
        let pages = PageModel(
            formFactor: .backdrop,
            defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: CompanionClient(adopting: handle)
            )
        )
        return BackdropAppDelegate(model: BackdropModel(defaults: defaults, pages: pages))
    }

    func testAnUntitledAlertShapedWindowIsNoCompanionAndMakesNoController() {
        // Titled with no title text and not a sheet: the unavailable
        // shortcut alert's shape, which a lookup by appearance took for About.
        let delegate = makeDelegate(tag: "alert-shaped")
        let alert = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        alert.isReleasedWhenClosed = false
        alert.title = ""

        XCTAssertFalse(delegate.isCompanionWindow(alert))
        XCTAssertNil(delegate.madeSettings)
        XCTAssertNil(delegate.madeFeedback)
    }
}
