import CompanionKit
import XCTest

@testable import OnetimePad

/// The File menu's ⌘W item's truth table (issue #201).
final class CloseMenuItemTests: XCTestCase {
    func testOnTheSurfaceItIsCloseFileEnabledOnlyOnAFile() {
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .surface, onAFile: true, keyWindowCanClose: true),
            .closeFile(enabled: true))
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .surface, onAFile: false, keyWindowCanClose: true),
            .closeFile(enabled: false))
    }

    func testInACompanionWindowItIsCloseWindowEnabledOnlyWhenItCanClose() {
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .auxiliaryWindow, onAFile: true, keyWindowCanClose: true),
            .closeWindow(enabled: true))
        XCTAssertEqual(
            CloseMenuItem.resolve(target: .auxiliaryWindow, onAFile: false, keyWindowCanClose: false),
            .closeWindow(enabled: false))
    }

    func testTheTitlesAndEnablementRead() {
        XCTAssertEqual(CloseMenuItem.closeFile(enabled: false).title, "Close File")
        XCTAssertEqual(CloseMenuItem.closeWindow(enabled: true).title, "Close Window")
        XCTAssertFalse(CloseMenuItem.closeFile(enabled: false).isEnabled)
        XCTAssertTrue(CloseMenuItem.closeWindow(enabled: true).isEnabled)
    }
}
