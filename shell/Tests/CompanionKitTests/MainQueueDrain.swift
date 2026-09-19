import XCTest

extension XCTestCase {
    /// Wait for every hop already on the main queue to have run, by
    /// order and never by the clock.
    ///
    /// The editor defers work by `DispatchQueue.main.async` (the scroll
    /// restore in `InkEditorView.Coordinator`) and by main actor tasks
    /// (the roll's measurement), and both land on the one serial main
    /// queue. A block queued here is behind all of them, so when it has
    /// run they have run, whatever else the loop was busy with. A fixed
    /// stretch of `RunLoop.run(until:)` promises no such thing: in a
    /// full run, timers left by earlier tests can use the whole stretch
    /// up before the main queue is serviced once, and the test then
    /// reads a view whose restore has not landed.
    ///
    /// One barrier covers only what was queued before it. A hop may
    /// queue another on its way out, and a restore that found a clip
    /// with no size is asked for again by the clip's first frame, which
    /// queues a second hop behind the first barrier. So the drain is
    /// repeated: each round is behind everything the round before let
    /// loose, and `rounds` is one more than the longest chain the
    /// sources hold, which is two.
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
