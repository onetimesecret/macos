import Foundation
import XCTest

@testable import CompanionKit

private final class ClipboardClearProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int {
        lock.withLock { count }
    }

    @discardableResult
    func clear() -> Bool {
        lock.withLock { count += 1 }
        return true
    }
}

@MainActor
final class ClipboardClearLifecycleTests: XCTestCase {
    private func makeModel(
        probe: ClipboardClearProbe,
        clearDelay: TimeInterval = 0.01
    ) throws -> PageModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-clipboard-clear-\(UUID().uuidString)", isDirectory: true)
        let suite = "companion-clipboard-clear-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return PageModel(
            formFactor: .panel,
            defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: .ephemeral(tag: "clipboard-clear-\(UUID().uuidString)"),
                saveDebounce: 60,
                clipboardClearDebounce: clearDelay,
                clearClipboardIfOurs: { probe.clear() }
            )
        )
    }

    private func spinRunLoop(
        until done: () -> Bool, timeout: TimeInterval = 1
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testSuccessfulConcealClearsClipboardAfterItsDraftWasDismissed() throws {
        let probe = ClipboardClearProbe()
        let model = try makeModel(probe: probe)
        let target = ConcealDraft.Target.page(41)
        model.beginConceal(target)
        model.dismissConceal()

        model.finishConceal(
            ConcealOutcome(ok: true, receiptId: "receipt-41", error: nil),
            for: target
        )

        XCTAssertNil(model.concealDraft, "a stale result must not restore a dismissed draft")
        spinRunLoop { probe.callCount == 1 }
        XCTAssertEqual(probe.callCount, 1, "the successful egress still arms its guarded clear")
    }

    func testSuccessfulConcealDoesNotMutateAReplacementDraft() throws {
        let probe = ClipboardClearProbe()
        let model = try makeModel(probe: probe)
        let staleTarget = ConcealDraft.Target.page(41)
        let replacementTarget = ConcealDraft.Target.chip(73)
        model.beginConceal(staleTarget)
        model.beginConceal(replacementTarget)

        model.finishConceal(
            ConcealOutcome(ok: true, receiptId: "stale-receipt", error: nil),
            for: staleTarget
        )

        let replacement = try XCTUnwrap(model.concealDraft)
        XCTAssertEqual(replacement.target, replacementTarget)
        XCTAssertNil(replacement.receiptId)
        XCTAssertNil(replacement.error)
        XCTAssertFalse(replacement.inFlight)
        spinRunLoop { probe.callCount == 1 }
        XCTAssertEqual(probe.callCount, 1, "the stale success still arms its guarded clear")
    }

    func testModelTeardownClearsBeforeInvalidatingAPendingTimer() throws {
        let probe = ClipboardClearProbe()
        weak var releasedModel: PageModel?

        do {
            var model: PageModel? = try makeModel(probe: probe, clearDelay: 60)
            releasedModel = model
            let target = ConcealDraft.Target.page(41)
            model?.beginConceal(target)
            model?.dismissConceal()
            model?.finishConceal(
                ConcealOutcome(ok: true, receiptId: "receipt-41", error: nil),
                for: target
            )
            XCTAssertEqual(probe.callCount, 0, "the long timer has not fired")
            model = nil
        }

        XCTAssertNil(releasedModel)
        XCTAssertEqual(probe.callCount, 1, "teardown performs the pending guarded clear")
    }
}
