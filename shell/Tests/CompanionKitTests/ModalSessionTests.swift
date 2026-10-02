import AppKit
import XCTest

@testable import CompanionKit

/// The bracket every modal of ours runs inside. Nothing here puts a
/// panel on screen: a closure stands in for `runModal`, and the centre
/// is the test's own, so what is pinned is the promise the surface
/// relies on, that the end is announced once, after the body, whatever
/// the body answered.
@MainActor
final class ModalSessionTests: XCTestCase {
    func testTheEndIsAnnouncedOnceAfterTheBodyHasReturned() {
        let center = NotificationCenter()
        var order: [String] = []
        let token = center.addObserver(
            forName: ModalSession.didEndNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { order.append("ended") }
        }
        defer { center.removeObserver(token) }

        let answer = ModalSession.run(center: center) { () -> Int in
            order.append("body")
            return 42
        }

        XCTAssertEqual(answer, 42, "the body's answer passes through untouched")
        XCTAssertEqual(order, ["body", "ended"])
    }

    func testACancelledBodyIsAnnouncedTheSameAsAnAcceptedOne() {
        // Open or Save As, accepted or cancelled: the surface comes forward
        // again either way, so the bracket cannot know or care which.
        let center = NotificationCenter()
        var ends = 0
        let token = center.addObserver(
            forName: ModalSession.didEndNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { ends += 1 }
        }
        defer { center.removeObserver(token) }

        let cancelled: URL? = ModalSession.run(center: center) { nil }
        let accepted: URL? = ModalSession.run(center: center) { URL(fileURLWithPath: "/tmp/a") }

        XCTAssertNil(cancelled)
        XCTAssertNotNil(accepted)
        XCTAssertEqual(ends, 2)
    }

    func testTheBracketIsOpenForTheWholeOfTheBodyAndShutByTheAnnouncement() {
        // The panel orders itself out inside `runModal`, after AppKit's
        // own session has ended, and the window AppKit keys next hears
        // of it there. The bracket is the only fact that still says a
        // modal of ours is why.
        let center = NotificationCenter()
        var atTheEnd: Bool?
        let token = center.addObserver(
            forName: ModalSession.didEndNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { atTheEnd = ModalSession.isBracketed }
        }
        defer { center.removeObserver(token) }

        XCTAssertFalse(ModalSession.isBracketed)
        let inside = ModalSession.run(center: center) {
            ModalSession.run(center: center) { ModalSession.isBracketed }
                && ModalSession.isBracketed
        }

        XCTAssertTrue(inside, "through a nested bracket and after it")
        XCTAssertEqual(atTheEnd, false)
        XCTAssertFalse(ModalSession.isBracketed)
    }

    func testNoModalIsRunningUnderTheTestRunner() {
        // The AppKit fact the outside click rule reads, at rest. Run on
        // its own this case sees no application at all, since nothing
        // has forced `NSApplication.shared`, and the answer has to be
        // the closed one rather than a trap on a nil `NSApp`. The other
        // half, that `NSApp.modalWindow` is the open panel for the whole
        // of its `runModal` even though the panel is drawn out of
        // process, was measured by hand and cannot be asserted here
        // without hanging the run on a panel nobody is looking at.
        XCTAssertFalse(ModalSession.isRunning)
    }

    func testFilePanelsAreBracketedAndQuitStaysInline() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try String(
            contentsOf: root.appendingPathComponent("Sources/CompanionKit/FileCoordinator.swift"),
            encoding: .utf8
        )
        let appDelegate = try String(
            contentsOf: root.appendingPathComponent("Sources/OnetimePad/BackdropApp.swift"),
            encoding: .utf8
        )

        let quitStart = try XCTUnwrap(appDelegate.range(of: "    func applicationShouldTerminate("))
        let quitEnd = try XCTUnwrap(appDelegate.range(of: "\n    }", range: quitStart.upperBound..<appDelegate.endIndex))
        let quit = appDelegate[quitStart.lowerBound..<quitEnd.upperBound]
        XCTAssertEqual(coordinator.components(separatedBy: "ModalSession.run").count - 1, 2)
        XCTAssertFalse(quit.contains("ModalSession.run"), "quit does not enter a modal session")
        XCTAssertFalse(coordinator.contains("NSAlert"), "file decisions are inline")
        XCTAssertFalse(quit.contains("NSAlert"), "quit owns no alert")
    }

    /// A rename is not destructive and takes an inline field (D-14,
    /// issue #172), so the rename path never enters a modal session.
    /// The roll's gutter is the field that can be driven without a
    /// window: its rename begins, takes a draft and ends by the same
    /// calls the field editor makes, against a real model over its own
    /// state directory. The strip's SwiftUI field cannot be driven
    /// here; it decides its endings through the same `TabRename`, whose
    /// outcomes `TabRenameTests` pin.
    func testRenameNeverRunsAModalSession() throws {
        let suiteName = "companion-rename-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = isolatedModel(defaults: defaults)
        model.newPage()
        let tab = try XCTUnwrap(model.tabs.first)

        var ends = 0
        let token = NotificationCenter.default.addObserver(
            forName: ModalSession.didEndNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { ends += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let header = DayHeaderView(model: model)
        header.show(dayText: "today", spokenLabel: "today", mark: .none, summary: tab)

        header.beginRename()
        XCTAssertFalse(ModalSession.isRunning, "the field opens in place, not in a panel")
        header.renameDraft = "payroll"
        header.endRename(committed: true)
        XCTAssertEqual(model.tabs.first?.title, "payroll", "return hands the model the name")

        header.refresh(summary: model.tabs.first)
        header.beginRename()
        header.renameDraft = "ledger"
        header.endRename(committed: false)
        XCTAssertEqual(model.tabs.first?.title, "payroll", "escape and focus loss keep the title")
        XCTAssertEqual(header.renameDraft, "payroll", "and the gutter shows it again")

        XCTAssertEqual(ends, 0, "no bracket was entered on either ending")
        XCTAssertFalse(ModalSession.isRunning)
    }
}
