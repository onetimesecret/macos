import AppKit
import XCTest

@testable import OnetimePad

/// Which windows ⌘W closes as companion windows (issue #201): identity
/// against the windows already made. The windows here are never ordered
/// on screen.
@MainActor
final class CompanionWindowIdentityTests: XCTestCase {
    private func window(styleMask: NSWindow.StyleMask = [.titled, .closable], title: String = "") -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: styleMask, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    private func isCompanion(
        _ candidate: NSWindow, settings: NSWindow?, feedback: NSWindow?, about: NSWindow?
    ) -> Bool {
        BackdropAppDelegate.isCompanionWindow(candidate, settings: settings, feedback: feedback, about: about)
    }

    func testSettingsFeedbackAndAboutAreCompanionWindows() {
        let settings = window(title: "Settings")
        let feedback = window(title: "Send Feedback")
        let about = window()
        for candidate in [settings, feedback, about] {
            XCTAssertTrue(isCompanion(candidate, settings: settings, feedback: feedback, about: about))
        }
    }

    func testTheContentWindowsAreNot() {
        let settings = window(title: "Settings")
        let feedback = window(title: "Send Feedback")
        let about = window()
        let editor = window(styleMask: [.titled, .closable, .miniaturizable, .resizable], title: "OnetimePad")
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        XCTAssertFalse(isCompanion(editor, settings: settings, feedback: feedback, about: about))
        XCTAssertFalse(isCompanion(panel, settings: settings, feedback: feedback, about: about))
    }

    /// A confirmation on Settings is visible, titled and untitled, the
    /// shape the About lookup once mistook for the panel.
    func testASheetAttachedToSettingsIsNot() throws {
        let settings = window(title: "Settings")
        let sheet = window(styleMask: [.titled])
        settings.beginSheet(sheet)
        defer { settings.endSheet(sheet) }
        XCTAssertTrue(try XCTUnwrap(settings.attachedSheet) === sheet)
        XCTAssertFalse(isCompanion(sheet, settings: settings, feedback: nil, about: nil))
    }

    func testASavePanelIsNot() {
        let feedback = window(title: "Send Feedback")
        let savePanel = NSSavePanel()
        XCTAssertFalse(isCompanion(savePanel, settings: nil, feedback: feedback, about: nil))
    }

    /// The delegate keeps About weakly. Once AppKit lets that panel go,
    /// a window shaped like it is not taken for it.
    func testAnAboutPanelThatWasReleasedIsNot() {
        weak var released: NSWindow?
        autoreleasepool {
            let about = window()
            released = about
        }
        XCTAssertNil(released)
        let lookalike = window()
        XCTAssertFalse(isCompanion(lookalike, settings: nil, feedback: nil, about: released))
    }

    func testNoWindowMadeYetMeansNoCompanion() {
        XCTAssertFalse(isCompanion(window(), settings: nil, feedback: nil, about: nil))
    }
}
