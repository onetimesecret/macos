import CompanionKit
import XCTest

@testable import OnetimePad

/// The File menu's ⌘W item's truth table (issue #201).
final class CloseMenuItemTests: XCTestCase {
    func testOnTheSurfaceItNamesTheFileOrThePage() {
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .surface, showing: .file(7), keyWindowCanClose: true),
            .closeFile)
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .surface, showing: .tab(3), keyWindowCanClose: false),
            .closePage(enabled: true), "the page's own ⌘W, so the item is enabled")
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .surface, showing: .today, keyWindowCanClose: true),
            .closePage(enabled: false), "today with no page has nothing to close")
    }

    func testInACompanionWindowItIsCloseWindowEnabledOnlyWhenItCanClose() {
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .companionWindow, showing: .file(7), keyWindowCanClose: true),
            .closeWindow(enabled: true))
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .companionWindow, showing: .tab(3), keyWindowCanClose: false),
            .closeWindow(enabled: false))
    }

    /// A sheet, a save panel or an alert with the keys, or no key window:
    /// dimmed even over a file the surface would close.
    func testWithNothingToCloseItIsDimmed() {
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .nothing, showing: .file(7), keyWindowCanClose: true),
            .closeWindow(enabled: false))
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .nothing, showing: .tab(3), keyWindowCanClose: false),
            .closeWindow(enabled: false))
    }

    func testTheTitlesAndEnablementRead() {
        XCTAssertEqual(CloseMenuItem.closeFile.title, "Close File")
        XCTAssertEqual(CloseMenuItem.closePage(enabled: true).title, "Close Page")
        XCTAssertEqual(CloseMenuItem.closeWindow(enabled: true).title, "Close Window")
        XCTAssertTrue(CloseMenuItem.closeFile.isEnabled)
        XCTAssertFalse(CloseMenuItem.closePage(enabled: false).isEnabled)
        XCTAssertTrue(CloseMenuItem.closeWindow(enabled: true).isEnabled)
    }
}
