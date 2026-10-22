import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

/// The report's expected altitude reads the keeper's companion answer
/// (#293). Throwaway defaults and injected seams, never the installed state.
@MainActor
final class DiagnosticsReportTests: XCTestCase {

    private func makeModel(tag: String) -> BackdropModel {
        let name = "onetimepad.test.diagnostics.\(tag).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        companion_init()
        guard let handle = tag.withCString({ companion_new_ephemeral($0) }) else {
            fatalError("the core refused to create an ephemeral handle")
        }
        let pages = PageModel(
            formFactor: .backdrop,
            defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: CompanionClient(adopting: handle)
            )
        )
        return BackdropModel(defaults: defaults, pages: pages)
    }

    func testAPinnedCardUnderAKeyCompanionReportsNormal() {
        let model = makeModel(tag: "pinned-companion")
        model.pinned = true

        let report = DiagnosticsReport.capture(
            model: model, companionKeyed: true, shortcutStatus: "registered"
        )

        XCTAssertTrue(report.summary.contains("Companion window keyed: true"))
        XCTAssertTrue(
            report.summary.contains(
                "Expected panel altitude: normal (\(BackdropAltitude.normal.level.rawValue))"
            ),
            report.summary
        )
    }

    func testAPinnedCardWithNoKeyCompanionReportsFloating() {
        let model = makeModel(tag: "pinned-alone")
        model.pinned = true

        let report = DiagnosticsReport.capture(
            model: model, companionKeyed: false, shortcutStatus: "registered"
        )

        XCTAssertTrue(report.summary.contains("Companion window keyed: false"))
        XCTAssertTrue(
            report.summary.contains(
                "Expected panel altitude: floating (\(BackdropAltitude.floating.level.rawValue))"
            ),
            report.summary
        )
    }
}
