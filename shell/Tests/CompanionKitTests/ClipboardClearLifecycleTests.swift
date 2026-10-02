import Foundation
import XCTest

@testable import CompanionKit

/// Stands in for the guarded clear, counting the calls and, when a test
/// hands it one, fulfilling an expectation on each so the test can wait
/// for the clear timer's firing by the event itself and never by the
/// clock.
private final class ClipboardClearProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let cleared: XCTestExpectation?

    init(cleared: XCTestExpectation? = nil) {
        self.cleared = cleared
    }

    var callCount: Int {
        lock.withLock { count }
    }

    @discardableResult
    func clear() -> Bool {
        lock.withLock { count += 1 }
        cleared?.fulfill()
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

    func testSuccessfulConcealClearsClipboardAfterItsDraftWasDismissed() throws {
        let cleared = expectation(description: "the guarded clear fired")
        let probe = ClipboardClearProbe(cleared: cleared)
        let model = try makeModel(probe: probe)
        let target = ConcealDraft.Target.page(41)
        model.beginConceal(target)
        let draftID = try XCTUnwrap(model.concealDraft?.id)
        model.dismissConceal()

        model.finishConceal(
            ConcealOutcome(ok: true, receiptId: "receipt-41", error: nil),
            for: target, draftID: draftID
        )

        XCTAssertNil(model.concealDraft, "a stale result must not restore a dismissed draft")
        wait(for: [cleared], timeout: 10)
        XCTAssertEqual(probe.callCount, 1, "the successful egress still arms its guarded clear")
    }

    func testSuccessfulConcealDoesNotMutateAReplacementDraft() throws {
        let cleared = expectation(description: "the guarded clear fired")
        let probe = ClipboardClearProbe(cleared: cleared)
        let model = try makeModel(probe: probe)
        let staleTarget = ConcealDraft.Target.page(41)
        let replacementTarget = ConcealDraft.Target.chip(73)
        model.beginConceal(staleTarget)
        let draftID = try XCTUnwrap(model.concealDraft?.id)
        model.beginConceal(replacementTarget)

        model.finishConceal(
            ConcealOutcome(ok: true, receiptId: "stale-receipt", error: nil),
            for: staleTarget, draftID: draftID
        )

        let replacement = try XCTUnwrap(model.concealDraft)
        XCTAssertEqual(replacement.target, replacementTarget)
        XCTAssertNil(replacement.receiptId)
        XCTAssertNil(replacement.error)
        XCTAssertFalse(replacement.inFlight)
        wait(for: [cleared], timeout: 10)
        XCTAssertEqual(probe.callCount, 1, "the stale success still arms its guarded clear")
    }

    func testLateOutcomeDoesNotPopulateAReopenedOfferForTheSameTarget() throws {
        for success in [false, true] {
            let cleared = success ? expectation(description: "the earlier successful egress clears") : nil
            let probe = ClipboardClearProbe(cleared: cleared)
            let model = try makeModel(probe: probe)
            let target = ConcealDraft.Target.page(41)
            model.beginConceal(target)
            let earlierID = try XCTUnwrap(model.concealDraft?.id)
            model.dismissConceal()
            model.beginConceal(target)
            model.concealDraft?.passphrase = "new options"
            let replacementID = try XCTUnwrap(model.concealDraft?.id)
            XCTAssertNotEqual(earlierID, replacementID)

            model.finishConceal(
                ConcealOutcome(ok: success, receiptId: success ? "old-receipt" : nil,
                    error: success ? nil : "old refusal"),
                for: target, draftID: earlierID
            )

            let replacement = try XCTUnwrap(model.concealDraft)
            XCTAssertEqual(replacement.id, replacementID)
            XCTAssertEqual(replacement.passphrase, "new options")
            XCTAssertNil(replacement.receiptId)
            XCTAssertNil(replacement.error)
            XCTAssertFalse(replacement.inFlight)
            if let cleared { wait(for: [cleared], timeout: 10) }
            else { XCTAssertEqual(probe.callCount, 0) }
        }
    }

    func testModelTeardownClearsBeforeInvalidatingAPendingTimer() throws {
        let probe = ClipboardClearProbe()
        weak var releasedModel: PageModel?

        do {
            var model: PageModel? = try makeModel(probe: probe, clearDelay: 60)
            releasedModel = model
            let target = ConcealDraft.Target.page(41)
            model?.beginConceal(target)
            let draftID = try XCTUnwrap(model?.concealDraft?.id)
            model?.dismissConceal()
            model?.finishConceal(
                ConcealOutcome(ok: true, receiptId: "receipt-41", error: nil),
                for: target, draftID: draftID
            )
            XCTAssertEqual(probe.callCount, 0, "the long timer has not fired")
            model = nil
        }

        XCTAssertNil(releasedModel)
        XCTAssertEqual(probe.callCount, 1, "teardown performs the pending guarded clear")
    }
}
