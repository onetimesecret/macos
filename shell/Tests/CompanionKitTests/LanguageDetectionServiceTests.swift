import Foundation
import XCTest

@testable import CompanionKit

final class LanguageDetectionServiceTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var maximumActive = 0
        private(set) var detected: [String] = []
        private(set) var completed: [UUID] = []

        func began(_ value: String) {
            lock.lock()
            active += 1
            maximumActive = max(maximumActive, active)
            detected.append(value)
            lock.unlock()
        }

        func ended() {
            lock.lock()
            active -= 1
            lock.unlock()
        }

        func completed(_ requestID: UUID) {
            lock.lock()
            completed.append(requestID)
            lock.unlock()
        }

        func snapshot() -> (maximumActive: Int, detected: [String], completed: [UUID]) {
            lock.lock()
            defer { lock.unlock() }
            return (maximumActive, detected, completed)
        }
    }

    private func request(
        _ text: String,
        requestID: UUID = UUID(),
        revision: UInt64 = 1
    ) -> LanguageDetectionRequest {
        LanguageDetectionRequest(
            requestID: requestID,
            documentID: 42,
            revision: revision,
            targetRange: NSRange(location: 3, length: 4),
            trigger: .ordinaryPaste,
            selectionSnapshot: NSRange(location: 3, length: 0),
            data: Data(text.utf8)
        )
    }

    func testDetectorIsSerialAndOnlyNewestPendingRequestRunsAndCompletes() {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let newestCompleted = expectation(description: "newest request completed")
        let probe = Probe()
        let callbackQueue = DispatchQueue(label: "language-detection-test.callback")
        let service = LanguageDetectionService(
            detector: { data in
                let text = String(decoding: data, as: UTF8.self)
                probe.began(text)
                if text == "first" {
                    firstStarted.signal()
                    _ = releaseFirst.wait(timeout: .now() + 2)
                }
                probe.ended()
                return text
            },
            completionQueue: callbackQueue
        )

        let first = request("first", revision: 1)
        let second = request("second", revision: 2)
        let third = request("third", revision: 3)
        service.submit(first, validating: { _ in true }) { result in
            probe.completed(result.context.requestID)
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)

        service.submit(second, validating: { _ in true }) { result in
            probe.completed(result.context.requestID)
        }
        service.submit(third, validating: { _ in true }) { result in
            probe.completed(result.context.requestID)
            newestCompleted.fulfill()
        }
        releaseFirst.signal()

        wait(for: [newestCompleted], timeout: 2)
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.maximumActive, 1)
        XCTAssertEqual(snapshot.detected, ["first", "third"])
        XCTAssertEqual(snapshot.completed, [third.requestID])
        XCTAssertEqual(service.currentResult?.context.requestID, third.requestID)
        XCTAssertNil(service.currentRequest)
    }

    func testFailedCurrentContextValidationDropsResultAndReleasesRequest() {
        let completion = expectation(description: "stale completion")
        completion.isInverted = true
        let inferenceFinished = expectation(description: "inference finished")
        let callbackQueue = DispatchQueue(label: "language-detection-test.stale-callback")
        let service = LanguageDetectionService(
            detector: { _ in
                inferenceFinished.fulfill()
                return "swift"
            },
            completionQueue: callbackQueue
        )
        let stale = request("let value = 1")

        service.submit(stale, validating: { context in
            context.revision == 999
        }) { _ in
            completion.fulfill()
        }

        wait(for: [inferenceFinished], timeout: 1)
        wait(for: [completion], timeout: 0.2)
        callbackQueue.sync {}
        XCTAssertNil(service.currentRequest)
        XCTAssertNil(service.currentResult)
    }

    func testCancellationSuppressesAnInFlightCompletion() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completion = expectation(description: "cancelled completion")
        completion.isInverted = true
        let service = LanguageDetectionService(
            detector: { _ in
                started.signal()
                _ = release.wait(timeout: .now() + 2)
                return "rust"
            },
            completionQueue: DispatchQueue(label: "language-detection-test.cancel-callback")
        )
        let cancelled = request("fn main() {}")

        service.submit(cancelled, validating: { _ in true }) { _ in
            completion.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        service.cancel(requestID: cancelled.requestID)
        release.signal()

        wait(for: [completion], timeout: 0.2)
        XCTAssertNil(service.currentRequest)
        XCTAssertNil(service.currentResult)
    }

    func testInvalidationClearsAnAlreadyDeliveredResult() {
        let completion = expectation(description: "result delivered")
        let service = LanguageDetectionService(
            detector: { _ in "python" },
            completionQueue: DispatchQueue(label: "language-detection-test.invalidate-callback")
        )
        let current = request("print('hello')")

        service.submit(current, validating: { _ in true }) { _ in
            completion.fulfill()
        }
        wait(for: [completion], timeout: 1)
        XCTAssertNotNil(service.currentResult)

        service.invalidate()

        XCTAssertNil(service.currentRequest)
        XCTAssertNil(service.currentResult)
    }
}
