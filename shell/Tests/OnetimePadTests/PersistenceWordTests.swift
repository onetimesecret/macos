import CompanionKit
import XCTest

@testable import OnetimePad

/// The header's persistence word as a pure function (issue #296): drafts not
/// kept reaches a file surface, where the edits it is about are typed.
@MainActor
final class PersistenceWordTests: XCTestCase {
    private func word(
        fileActive: Bool, contentRefused: Bool = false, draftsHeld: Bool,
        saveStatus: SaveStatus = .saved
    ) -> BackdropRootView.PersistenceWord {
        BackdropRootView.persistenceWord(
            fileActive: fileActive, contentRefused: contentRefused, draftsHeld: draftsHeld,
            saveStatus: saveStatus)
    }

    func testADirtyFileActiveUnderAWithheldDraftsLicenceShowsDraftsNotKept() {
        XCTAssertEqual(word(fileActive: true, draftsHeld: true), .draftsNotKept)
        XCTAssertEqual(
            word(fileActive: true, contentRefused: true, draftsHeld: true), .draftsNotKept)
    }

    func testAFileSurfaceOtherwiseKeepsItsOwnWord() {
        XCTAssertEqual(word(fileActive: true, draftsHeld: false), .hidden)
        XCTAssertEqual(word(fileActive: true, contentRefused: true, draftsHeld: false), .hidden)
    }

    func testAPageSurfaceReadsTheRefusalsAheadOfTheStatus() {
        XCTAssertEqual(word(fileActive: false, contentRefused: true, draftsHeld: true), .notSaving)
        XCTAssertEqual(word(fileActive: false, draftsHeld: true), .draftsNotKept)
        XCTAssertEqual(word(fileActive: false, draftsHeld: false), .status(.saved))
    }
}
