import XCTest

@testable import CompanionApp

/// The login-item guard (SettingsWindow.swift): only the installed
/// copy under /Applications may register with `SMAppService`. A dev
/// build running from .build/ or dist/ must never claim the login
/// item, or login would resurrect whichever build ran Settings last.
final class LaunchAtLoginTests: XCTestCase {
    func testInstalledCopyMayRegister() {
        XCTAssertTrue(LaunchAtLogin.pathMayRegister("/Applications/CompanionApp.app"))
    }

    func testDevBuildsMayNot() {
        XCTAssertFalse(
            LaunchAtLogin.pathMayRegister(
                "/Users/d/Projects/dev/onetimesecret/macos/dist/CompanionApp.app"))
        XCTAssertFalse(
            LaunchAtLogin.pathMayRegister(
                "/Users/d/Projects/dev/onetimesecret/macos/shell/.build/debug/CompanionApp"))
    }

    func testLookalikePrefixesMayNot() {
        // A sibling directory that merely starts with the string, and
        // the user-level ~/Applications, are both outside the channel
        // install-app.sh maintains.
        XCTAssertFalse(LaunchAtLogin.pathMayRegister("/ApplicationsBackup/CompanionApp.app"))
        XCTAssertFalse(LaunchAtLogin.pathMayRegister("/Users/d/Applications/CompanionApp.app"))
    }
}
