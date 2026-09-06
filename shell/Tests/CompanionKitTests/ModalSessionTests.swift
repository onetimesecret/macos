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
        // Open or Cancel, Save or Discard: the surface comes forward
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
}
