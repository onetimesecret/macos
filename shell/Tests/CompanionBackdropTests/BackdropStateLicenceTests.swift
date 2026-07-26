import XCTest

@testable import CompanionBackdrop

/// The backdrop's quit-save licence and the storage it is licensed to
/// write. The truth table matches the panel's on purpose: the core
/// folds "no file yet" and "refused" into one false from
/// `companion_persist_restore`, and the file's presence on disk is what
/// tells a fresh start from a restore failure.
final class BackdropStateLicenceTests: XCTestCase {
    func testFreshStartEarnsTheLicence() {
        XCTAssertTrue(BackdropModel.grantsSaveLicence(fileExists: false, restored: false))
    }

    func testRestoredSessionKeepsTheLicence() {
        XCTAssertTrue(BackdropModel.grantsSaveLicence(fileExists: true, restored: true))
    }

    func testRefusedRestoreWithholdsTheLicence() {
        // The file exists but would not open. Quit must not overwrite
        // yesterday's page with this session's empty consolation.
        XCTAssertFalse(BackdropModel.grantsSaveLicence(fileExists: true, restored: false))
    }

    /// ADR-0010's two-stores rule, asserted where it would break: the
    /// backdrop's sealed file must not land in the panel's directory.
    func testTheStateFileIsTheBackdropsOwn() {
        let url = BackdropModel.stateFileURL
        XCTAssertEqual(url.lastPathComponent, "state.sealed")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "CompanionBackdrop")
    }

    /// The same rule one layer down: sharing the panel's Keychain
    /// service would put both apps on one state key, which is the
    /// prompt-storm `companion_new_scoped` exists to prevent.
    func testTheCredentialScopeIsTheBackdropsOwn() {
        XCTAssertEqual(BackdropCore.credentialService, "com.onetimesecret.companion.backdrop")
        XCTAssertNotEqual(BackdropCore.credentialService, "com.onetimesecret.companion")
    }

    /// The restore's last mile, against the live core: what the surface
    /// mirrors out through `inkRunsJSON` is what `documentInk` hands
    /// back to the editor. A restore replays the document the same way,
    /// so a drift here is a page that reopens wrong. No Keychain and no
    /// state file are touched: constructing the core reaches neither.
    @MainActor
    func testInkRoundTripsThroughTheDocumentMirror() throws {
        let core = BackdropCore()
        let id = core.newSheet()
        XCTAssertNotEqual(id, 0)

        let ink = "wifi guest pw rotates friday\nask ops for the new one"
        let json = try XCTUnwrap(BackdropCore.inkRunsJSON(ink))
        XCTAssertTrue(core.syncDocument(sheet: id, json: json))
        XCTAssertEqual(core.documentInk(sheet: id), ink)

        // An emptied page mirrors back empty rather than keeping the
        // last non-empty snapshot.
        let empty = try XCTUnwrap(BackdropCore.inkRunsJSON(""))
        XCTAssertTrue(core.syncDocument(sheet: id, json: empty))
        XCTAssertEqual(core.documentInk(sheet: id), "")
    }
}
