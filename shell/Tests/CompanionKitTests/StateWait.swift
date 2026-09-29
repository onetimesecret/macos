import Combine
import XCTest

extension XCTestCase {
    /// Wait for published state to answer `condition`, asked again on
    /// every value the publisher sends and never on the clock.
    ///
    /// The waits here are for the debounced write and the round trips
    /// that come back through the main actor: a real timer fires, its
    /// body hops to the main queue, and the model publishes the result.
    /// `drainMainQueue` cannot stand in for that, since a barrier on the
    /// main queue says nothing about a timer that has not fired yet. So
    /// the wait hangs on the state itself: a `@Published` property
    /// sends its current value on subscription, which settles a
    /// condition that already holds without a turn of the loop, and
    /// sends each change after, which is what fulfils the expectation
    /// the moment the state arrives. Between those the run loop turns
    /// as XCTest sees fit, so the timer fires when it is due and the
    /// wait ends when the state does.
    ///
    /// The value the publisher sends is the one about to be stored, so
    /// the condition reads its argument and not the model. By the time
    /// `wait` returns the setter has finished, and the model reads the
    /// same.
    ///
    /// The timeout is generous because it never decides the outcome; a
    /// wait that reaches it is a timer that never fired or a write that
    /// never landed, and either is worth failing loudly rather than
    /// letting the assertion after it speak first.
    @MainActor
    func waitUntil<P: Publisher>(
        _ publisher: P,
        timeout: TimeInterval = 10,
        description: String = "published state answered the condition",
        _ condition: @escaping (P.Output) -> Bool
    ) where P.Failure == Never {
        let answered = expectation(description: description)
        // A condition that keeps holding across later values would
        // otherwise count as a second fulfilment.
        answered.assertForOverFulfill = false
        let watch = publisher.sink { value in
            if condition(value) { answered.fulfill() }
        }
        wait(for: [answered], timeout: timeout)
        watch.cancel()
    }

    /// Let a window of the clock pass, for the one kind of assertion that
    /// needs it: that a timer did not fire inside it.
    ///
    /// A negative claim about a debounce cannot be waited on by order,
    /// since the thing it asserts is that nothing arrives. So the window
    /// is measured out, but on the main queue rather than by spinning
    /// the loop: the block that ends the wait is queued for the far end
    /// of the window, and anything the window's timers hop onto the
    /// queue before then runs ahead of it, so the assertion after this
    /// reads a model whose hops have landed. The timeout on the wait is
    /// not the window, and only fails a main queue that never ran.
    @MainActor
    func letElapse(_ window: TimeInterval) {
        let elapsed = expectation(description: "a window of \(window) s elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + window) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: window + 10)
    }
}
