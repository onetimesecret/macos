import XCTest

@testable import CompanionKit

/// The login-item guard (SettingsSections.swift): only the installed
/// copy under /Applications may register with `SMAppService`. A dev
/// build running from .build/ or dist/ must never claim the login
/// item, or login would resurrect whichever build ran Settings last.
final class LaunchAtLoginTests: XCTestCase {
    func testInstalledCopyMayRegister() {
        XCTAssertTrue(LaunchAtLogin.pathMayRegister("/Applications/OnetimePad.app"))
    }

    func testDevBuildsMayNot() {
        XCTAssertFalse(
            LaunchAtLogin.pathMayRegister(
                "/Users/d/Projects/dev/onetimesecret/macos/dist/OnetimePad.app"))
        XCTAssertFalse(
            LaunchAtLogin.pathMayRegister(
                "/Users/d/Projects/dev/onetimesecret/macos/shell/.build/debug/OnetimePad"))
    }

    func testLookalikePrefixesMayNot() {
        // A sibling directory that merely starts with the string, and
        // the user-level ~/Applications, are both outside the channel
        // install.sh maintains.
        XCTAssertFalse(LaunchAtLogin.pathMayRegister("/ApplicationsBackup/OnetimePad.app"))
        XCTAssertFalse(LaunchAtLogin.pathMayRegister("/Users/d/Applications/OnetimePad.app"))
    }
}
