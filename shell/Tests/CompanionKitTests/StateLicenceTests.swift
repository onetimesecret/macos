import XCTest

@testable import CompanionKit

/// The quit-save licence's truth table (App.swift). The core folds
/// "no file yet" and "refused" into one false from
/// `companion_persist_restore`; the file's presence on disk is what
/// tells a fresh start from a restore failure — and only the failure
/// may cost the session its licence to write the sealed file at quit.
final class StateLicenceTests: XCTestCase {
    func testFreshStartEarnsTheLicence() {
        // No file on disk: nothing exists to protect, and the session
        // owns its future.
        XCTAssertTrue(PageModel.grantsSaveLicence(fileExists: false, restored: false))
    }

    func testRestoredSessionKeepsTheLicence() {
        XCTAssertTrue(PageModel.grantsSaveLicence(fileExists: true, restored: true))
    }

    func testRefusedRestoreWithholdsTheLicence() {
        // The file exists but would not open — Keychain key denied or
        // missing, damaged snapshot. Quit must not overwrite it with
        // this session's consolation page.
        XCTAssertFalse(PageModel.grantsSaveLicence(fileExists: true, restored: false))
    }
}
