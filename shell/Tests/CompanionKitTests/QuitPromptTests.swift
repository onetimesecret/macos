import AppKit
import XCTest

@testable import CompanionKit

@MainActor
private final class FlushSpy: QuitFlushable {
    private let outcome: QuitSaveOutcome
    private(set) var flushes = 0

    init(_ outcome: QuitSaveOutcome) {
        self.outcome = outcome
    }

    func saveStateForQuit() -> QuitSaveOutcome {
        flushes += 1
        return outcome
    }
}

/// The nonmodal terminate policy: one synchronous flush, then a deterministic
/// reply with no presentation callback or user-file save path.
@MainActor
final class QuitPromptTests: XCTestCase {
    func testASettledFlushTerminatesAfterExactlyOneFlush() {
        let model = FlushSpy(.settled)

        XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateNow)
        XCTAssertEqual(model.flushes, 1)
    }

    func testDirtyDraftsDoNotChangeASettledReply() throws {
        let suiteName = "companion-quit-draft-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = isolatedModel(defaults: defaults)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-quit-\(UUID().uuidString).txt")
        try Data("disk\n".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        model.openFile(at: url)
        let id = try XCTUnwrap(model.activeFile?.id)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "draft ")]))
        model.applyOps(sheet: id, opsJSON: ops)

        XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateNow)
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: url), as: UTF8.self), "disk\n",
            "quit flushes shell state but does not implicitly save the user file"
        )
    }

    func testARefusedFlushCancelsTerminationAutomatically() {
        let model = FlushSpy(.refused)

        XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateCancel)
        XCTAssertEqual(model.flushes, 1)
    }

    func testAnUnsavableFlushCancelsTerminationAutomatically() {
        let model = FlushSpy(.unsavableWithContent)

        XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateCancel)
        XCTAssertEqual(model.flushes, 1)
    }

    func testEveryOutcomeFlushesExactlyOnce() {
        for outcome in [QuitSaveOutcome.settled, .refused, .unsavableWithContent] {
            let model = FlushSpy(outcome)
            _ = QuitPrompt.terminateReply(flushing: model)
            XCTAssertEqual(model.flushes, 1, "\(outcome)")
        }
    }
}
