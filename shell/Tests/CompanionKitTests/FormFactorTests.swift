import Foundation
import XCTest

@testable import CompanionKit

/// ADR-0010's two-stores rule, asserted where it would break. Both form
/// factors now run the same model over the same views; what keeps them
/// separate programs rather than one program with two windows is
/// entirely this value, so it is worth checking by name.
final class FormFactorTests: XCTestCase {
    /// The backdrop's sealed file must not land in the panel's
    /// directory, and neither directory may be a name Spotlight will
    /// walk into: the directory is named for the running build's bundle
    /// id and carries the `.noindex` suffix (ADR-0012).
    func testEachFormFactorSealsToItsOwnFile() {
        let panel = FormFactor.panel.stateFileURL
        let backdrop = FormFactor.backdrop.stateFileURL

        // The core carries this same name (`STATE_FILE_NAME` in
        // crates/ffi/src/persist.rs) to decide whether dropping a file
        // takes the content key with it, so these two assertions are
        // also the Swift half of that coupling.
        XCTAssertEqual(panel.lastPathComponent, "state.sealed")
        XCTAssertEqual(backdrop.lastPathComponent, "state.sealed")

        let panelDirectory = panel.deletingLastPathComponent().lastPathComponent
        let backdropDirectory = backdrop.deletingLastPathComponent().lastPathComponent

        XCTAssertTrue(panelDirectory.hasSuffix(".noindex"), panelDirectory)
        XCTAssertTrue(backdropDirectory.hasSuffix(".noindex"), backdropDirectory)

        XCTAssertEqual(panelDirectory, "\(FormFactor.panel.credentialService).noindex")
        XCTAssertEqual(backdropDirectory, "\(FormFactor.backdrop.credentialService).noindex")

        XCTAssertNotEqual(panel, backdrop)
    }

    /// Under the test runner `Bundle.main` is xctest, so both form
    /// factors take their fallbacks; the panel's directory is the panel's
    /// identifier and nothing else. Naming the directory after whatever
    /// process happens to host the code is the failure this guards.
    func testTheStateDirectoryTakesTheFallbackIdentifierOffBundle() {
        XCTAssertEqual(
            FormFactor.resolvedBundleIdentifier(fallback: FormFactor.panelBundleIdentifier),
            "com.onetimesecret.companion"
        )
        XCTAssertEqual(
            FormFactor.resolvedBundleIdentifier(fallback: FormFactor.backdropBundleIdentifier),
            "com.onetimesecret.companion.backdrop"
        )

        // Not ours, so never adopted, whatever the host process is.
        XCTAssertEqual(
            FormFactor.resolvedBundleIdentifier(fallback: "com.example.other"),
            "com.example.other"
        )

        // And nothing leaks the runner's own identity into a path.
        let runner = Bundle.main.bundleIdentifier ?? ""
        if !runner.hasPrefix(FormFactor.panelBundleIdentifier) {
            XCTAssertNotEqual(FormFactor.panel.credentialService, runner)
            XCTAssertFalse(
                FormFactor.panel.stateFileURL.path.contains("xctest"),
                FormFactor.panel.stateFileURL.path
            )
        }
    }

    /// The three guards under the `Bundle.main` early return, which no
    /// test could reach before: under xctest the running identifier is
    /// the test runner's, so the fallback arm above is the only one the
    /// shipping entry point ever takes here.
    ///
    /// What they hold up is case 4's shell consequence (ADR-0016
    /// section 9). A `.debug` copy and an installed release copy are
    /// two apps to LaunchServices, and they must be two stores: two
    /// processes resolving to one identifier would share a state
    /// directory and a Keychain service, and two debounces would write
    /// over one another's `state.sealed` on the same second. The
    /// backdrop's identifier carries the panel's as a prefix, and the
    /// table records what the rule then actually does with it, which is
    /// adopt it: `.backdrop` is one dot-free suffix exactly as `.debug`
    /// is, and nothing in the rule can tell a sibling form factor from
    /// a build configuration. That is inert today, since the panel was
    /// archived (ADR-0014) and no shipping code asks for
    /// `FormFactor.panel` at all, and it is written down here rather
    /// than left as a surprise for whoever revives a second form
    /// factor: they would need a rule that names the siblings, not one
    /// that counts dots.
    func testOnlyTheAppsOwnIdentifierAndOneDotFreeSuffixAreAdopted() {
        let panel = FormFactor.panelBundleIdentifier
        let backdrop = FormFactor.backdropBundleIdentifier

        let cases: [(running: String?, fallback: String, resolved: String, why: String)] = [
            (nil, panel, panel, "a bare binary has no identifier at all"),
            (panel, panel, panel, "the app's own identifier is itself"),
            (backdrop, backdrop, backdrop, "and so is the other form factor's"),
            (
                panel + ".debug", panel, panel + ".debug",
                "the one suffix the build lane produces is adopted"
            ),
            (
                backdrop + ".debug", backdrop, backdrop + ".debug",
                "on either form factor"
            ),
            (
                backdrop, panel, backdrop,
                "one dot-free suffix, even where it spells the sibling form factor's own id"
            ),
            (
                backdrop + ".debug", panel, panel,
                "but two suffixes are refused, whatever they spell"
            ),
            (panel, backdrop, backdrop, "and the prefix does not run the other way either"),
            (panel + ".a.b", panel, panel, "two suffixes are not one suffix"),
            (panel + ".", panel, panel, "an empty suffix is not a suffix"),
            ("com.example.other", panel, panel, "another vendor's process is never adopted"),
        ]
        for probe in cases {
            XCTAssertEqual(
                FormFactor.resolvedBundleIdentifier(
                    running: probe.running, fallback: probe.fallback),
                probe.resolved,
                "\(probe.running ?? "nil") over \(probe.fallback): \(probe.why)"
            )
        }

        // The consequence, stated as the thing that would actually go
        // wrong: the debug copy and the release copy of one app resolve
        // to two identifiers, which is what makes them two stores.
        XCTAssertNotEqual(
            FormFactor.resolvedBundleIdentifier(running: backdrop + ".debug", fallback: backdrop),
            FormFactor.resolvedBundleIdentifier(running: backdrop, fallback: backdrop)
        )
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

        // Resting there means it inherits the state directory's naming,
        // its `.noindex` suffix, and its backup exclusion for free.
        for ledger in [panelLedger, backdropLedger] {
            XCTAssertTrue(
                ledger.deletingLastPathComponent().lastPathComponent.hasSuffix(".noindex"),
                ledger.path
            )
        }

        // No ledger is ever any state file.
        for ledger in [panelLedger, backdropLedger] {
            XCTAssertNotEqual(ledger, panelState)
            XCTAssertNotEqual(ledger, backdropState)
        }
    }

    /// The same rule one layer down: sharing a Keychain service would
    /// put both apps on one state key, which is the prompt storm
    /// `companion_new_scoped` exists to prevent. Both form factors now
    /// name a service of their own, so the core's unscoped default is
    /// unreachable and a `.debug` build cannot land on the release
    /// build's key.
    func testTheBackdropScopesItsCredentialsToItself() {
        XCTAssertEqual(FormFactor.backdrop.credentialService, "com.onetimesecret.companion.backdrop")
        XCTAssertEqual(FormFactor.panel.credentialService, "com.onetimesecret.companion")
        XCTAssertNotEqual(
            FormFactor.panel.credentialService,
            FormFactor.backdrop.credentialService
        )
    }

    /// The logger subsystem rides on the same identifier, so a trail
    /// reads back as the build that wrote it.
    func testTheLoggerSubsystemFollowsTheResolvedIdentifier() {
        XCTAssertEqual(FormFactor.panel.loggerSubsystem, FormFactor.panel.credentialService)
        XCTAssertEqual(FormFactor.backdrop.loggerSubsystem, FormFactor.backdrop.credentialService)
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
        XCTAssertNotEqual(client.newTab(), 0)
        let id = try XCTUnwrap(client.tabs().first?.pageID)

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
