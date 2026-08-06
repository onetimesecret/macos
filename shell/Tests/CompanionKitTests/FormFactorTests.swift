import Foundation
import XCTest

@testable import CompanionKit

/// ADR-0010's two-stores rule, asserted where it would break. Both form
/// factors now run the same model over the same views; what keeps them
/// separate programs rather than one program with two windows is
/// entirely this value, so it is worth checking by name.
final class FormFactorTests: XCTestCase {
    /// The backdrop's sealed file must not land in the panel's
    /// directory.
    func testEachFormFactorSealsToItsOwnFile() {
        let panel = FormFactor.panel.stateFileURL
        let backdrop = FormFactor.backdrop.stateFileURL

        XCTAssertEqual(panel.lastPathComponent, "state.sealed")
        XCTAssertEqual(backdrop.lastPathComponent, "state.sealed")
        XCTAssertEqual(panel.deletingLastPathComponent().lastPathComponent, "CompanionApp")
        XCTAssertEqual(backdrop.deletingLastPathComponent().lastPathComponent, "CompanionBackdrop")
        XCTAssertNotEqual(panel, backdrop)
    }

    /// The ledger is a sibling of the state file, never the state file
    /// and never shared. Two form factors keep two ledgers for the same
    /// reason they keep two state files, and the two lifetimes (the
    /// ledger's long-lived key, the content store's boot-bound one) must
    /// not land in one place.
    func testTheLedgerRestsBesideTheStateFileAndNeverSharesOne() {
        let panelLedger = FormFactor.panel.ledgerFileURL
        let backdropLedger = FormFactor.backdrop.ledgerFileURL
        let panelState = FormFactor.panel.stateFileURL
        let backdropState = FormFactor.backdrop.stateFileURL

        XCTAssertEqual(panelLedger.lastPathComponent, "ledger.sealed")
        XCTAssertEqual(backdropLedger.lastPathComponent, "ledger.sealed")

        // Beside its own state file, in the same directory.
        XCTAssertEqual(
            panelLedger.deletingLastPathComponent(),
            panelState.deletingLastPathComponent()
        )
        XCTAssertEqual(
            backdropLedger.deletingLastPathComponent(),
            backdropState.deletingLastPathComponent()
        )

        // Two form factors, two ledgers.
        XCTAssertNotEqual(panelLedger, backdropLedger)

        // No ledger is ever any state file.
        for ledger in [panelLedger, backdropLedger] {
            XCTAssertNotEqual(ledger, panelState)
            XCTAssertNotEqual(ledger, backdropState)
        }
    }

    /// The same rule one layer down: sharing the panel's Keychain
    /// service would put both apps on one state key, which is the
    /// prompt-storm `companion_new_scoped` exists to prevent. The panel
    /// passes nil and takes the core's own default.
    func testTheBackdropScopesItsCredentialsToItself() {
        XCTAssertEqual(FormFactor.backdrop.credentialService, "com.onetimesecret.companion.backdrop")
        XCTAssertNil(FormFactor.panel.credentialService)
    }

    /// The backdrop opens a week out, where the panel takes the core's
    /// own shorter default: a span you can reason about by the calendar
    /// suits a surface you are looking at all day.
    func testTheBackdropOpensOnItsOwnRung() {
        XCTAssertEqual(FormFactor.backdrop.defaultRung, .sevenDays)
        XCTAssertNil(FormFactor.panel.defaultRung)
    }
}

/// The restore's last mile, against the live core: what a surface
/// mirrors out through `syncDocument` is what `documentRuns` hands back
/// to the editor rebuilding after a restore. A drift here is a page that
/// reopens wrong. No Keychain and no state file are touched:
/// constructing a client reaches neither.
final class DocumentMirrorTests: XCTestCase {
    func testInkRoundTripsThroughTheDocumentMirror() throws {
        let client = CompanionClient()
        let id = client.newSheet()
        XCTAssertNotEqual(id, 0)

        let ink = "wifi guest pw rotates friday\nask ops for the new one"
        let json = try XCTUnwrap(Self.inkRunsJSON(ink))
        XCTAssertTrue(client.syncDocument(sheet: id, json: json))

        let runs = client.documentRuns(sheet: id)
        XCTAssertEqual(Self.ink(of: runs), ink)

        // An emptied page mirrors back empty rather than keeping the
        // last non-empty snapshot.
        XCTAssertTrue(client.syncDocument(sheet: id, json: "[]"))
        XCTAssertEqual(Self.ink(of: client.documentRuns(sheet: id)), "")
    }

    private static func inkRunsJSON(_ text: String) -> String? {
        guard !text.isEmpty else { return "[]" }
        guard let data = try? JSONSerialization.data(withJSONObject: [["ink": text]]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    private static func ink(of runs: [RestoredRun]) -> String {
        runs.compactMap { if case .ink(let text) = $0 { text } else { nil } }.joined()
    }
}
