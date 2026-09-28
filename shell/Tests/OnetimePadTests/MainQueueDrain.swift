import XCTest

extension XCTestCase {
    /// Wait for every hop already on the main queue to have run, by
    /// order and never by the clock.
    ///
    /// The same drain as `CompanionKitTests/MainQueueDrain.swift`, kept
    /// here because a test target cannot see another's helpers. A block
    /// queued on the main queue is behind everything queued before it,
    /// so when it has run they have run, whatever else the loop was busy
    /// with; a fixed stretch of `RunLoop.run(until:)` promises no such
    /// thing, since timers left by earlier tests can use the stretch up
    /// before the queue is serviced once. The drain is repeated because
    /// a hop may queue another on its way out, and `rounds` is one more
    /// than the longest chain the sources hold.
    ///
    /// The timeout is generous because it is never what decides the
    /// outcome. A healthy run leaves each wait after a turn of the
    /// loop, and one that does not is a main queue that never ran,
    /// which is worth failing loudly.
    @MainActor
    func drainMainQueue(rounds: Int = 3, timeout: TimeInterval = 10) {
        for round in 1...rounds {
            let drained = expectation(description: "main queue drained, round \(round)")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: timeout)
        }
    }
}
