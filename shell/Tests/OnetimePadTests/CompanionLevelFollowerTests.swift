import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

/// The follower Settings and About share, against a plain window that
/// is built deferred and never ordered, so nothing reaches the screen.
/// The model persists to a throwaway defaults suite and its pages live
/// in a directory made for the test, on an ephemeral core handle; never
/// the standard suite, never default seams.
@MainActor
final class CompanionLevelFollowerTests: XCTestCase {

    private func makeModel(tag: String) -> BackdropModel {
        let name = "onetimepad.test.follower.\(tag).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("follower-\(UUID().uuidString)", isDirectory: true)
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

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    func testFollowingWritesTheLevelAtOnce() {
        // A window opened beside a pinned card has to float from the
        // first frame, or it opens key yet invisible beneath the card.
        let model = makeModel(tag: "at-once")
        model.pinned = true
        let window = makeWindow()
        let follower = CompanionLevelFollower(model: model)

        follower.follow(window)

        XCTAssertEqual(window.level, .floating)
    }

    func testThePinMovesTheWindowAtTheMomentItIsToggled() {
        // The failing scenario: About opened while the card rests
        // unpinned, then Pin toggled on the card. A @Published emits on
        // willSet, so a sink that reads the model back sees the old pin
        // and leaves the window stranded under the card; the level is
        // asserted right after the assignment, with no turn in between.
        let model = makeModel(tag: "pin")
        let window = makeWindow()
        let follower = CompanionLevelFollower(model: model)
        follower.follow(window)
        XCTAssertEqual(window.level, .normal)

        model.pinned = true
        XCTAssertEqual(window.level, .floating)

        model.pinned = false
        XCTAssertEqual(window.level, .normal)
    }

    func testTheStanceAndThePreferenceMoveTheWindow() {
        let model = makeModel(tag: "stance-and-preference")
        let window = makeWindow()
        let follower = CompanionLevelFollower(model: model)
        follower.follow(window)

        // Keep above lifts a raise and not a rest, so the switch alone
        // changes nothing while the card rests.
        model.keepsAboveWhenInactive = true
        XCTAssertEqual(window.level, .normal)

        // An activation rather than a summon: the stance is what is
        // under test, and the roll has no reason to move.
        model.raise(.activation)
        XCTAssertEqual(window.level, .floating)

        model.keepsAboveWhenInactive = false
        XCTAssertEqual(window.level, .normal)

        model.keepsAboveWhenInactive = true
        XCTAssertEqual(window.level, .floating)

        model.rest()
        XCTAssertEqual(window.level, .normal)
    }

    func testAfterStopTheWindowNoLongerMoves() {
        let model = makeModel(tag: "stop")
        let window = makeWindow()
        let follower = CompanionLevelFollower(model: model)
        follower.follow(window)

        follower.stop()
        model.pinned = true

        XCTAssertFalse(follower.isFollowing)
        XCTAssertEqual(window.level, .normal)
    }

    func testClosingTheWindowStopsTheFollower() {
        // The close is heard through the notification centre, since the
        // About panel's delegate is not ours to take.
        let model = makeModel(tag: "close")
        let window = makeWindow()
        let follower = CompanionLevelFollower(model: model)
        follower.follow(window)

        window.close()
        model.pinned = true

        XCTAssertFalse(follower.isFollowing)
        XCTAssertEqual(window.level, .normal)
    }

    func testFollowingTheSameWindowTwiceAddsNoSubscriptions() {
        // Every ⌘, on an open Settings window and every About chosen
        // while About is up calls `follow` again. A second set of sinks
        // writes the same level and so shows nowhere but in the count,
        // and a second close observer would leave the first one behind
        // with nothing holding its token.
        let model = makeModel(tag: "twice")
        let window = makeWindow()
        let follower = CompanionLevelFollower(model: model)

        follower.follow(window)
        XCTAssertEqual(follower.subscriptionCount, 4)
        follower.follow(window)
        XCTAssertEqual(follower.subscriptionCount, 4)

        model.pinned = true
        XCTAssertEqual(window.level, .floating)
        follower.stop()
        XCTAssertEqual(follower.subscriptionCount, 0)
    }

    func testASecondWindowReplacesTheFirst() {
        let model = makeModel(tag: "replace")
        let first = makeWindow()
        let second = makeWindow()
        let follower = CompanionLevelFollower(model: model)
        follower.follow(first)

        follower.follow(second)
        XCTAssertEqual(follower.subscriptionCount, 4)
        model.pinned = true

        XCTAssertEqual(first.level, .normal, "the window let go of is no longer moved")
        XCTAssertEqual(second.level, .floating)

        // And the first window's close is no longer listened for.
        first.close()
        XCTAssertTrue(follower.isFollowing)
    }

    // MARK: Staying in front of the card

    /// Counts ordering calls and answers the key and visible questions
    /// by hand, so both sides of the rule can be asked of a window that
    /// is never on screen. `orderFront` deliberately does not reach
    /// AppKit.
    private final class OrderCountingWindow: NSWindow {
        var orderFrontCalls = 0
        var pretendsToBeKeyAndVisible = false

        override var isKeyWindow: Bool { pretendsToBeKeyAndVisible }
        override var isVisible: Bool { pretendsToBeKeyAndVisible }
        override func orderFront(_ sender: Any?) { orderFrontCalls += 1 }
    }

    private func makeOrderCountingWindow() -> OrderCountingWindow {
        let window = OrderCountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    func testALevelChangeOrdersNothingWhenTheWindowIsNotKey() async throws {
        // Settings merely open while the person works in the card: a
        // Pin toggled on the card moves Settings' level and must not
        // pull Settings over the card.
        let model = makeModel(tag: "not-key")
        let window = makeOrderCountingWindow()
        let follower = CompanionLevelFollower(model: model)
        follower.follow(window)

        model.pinned = true
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.orderFrontCalls, 0)
    }

    func testALevelChangeOrdersAKeyWindowFrontATurnLater() async throws {
        // The card's level is written on the same published change by
        // another subscriber, in an order Combine decides, and a level
        // written lands a window at the front of its level. The key
        // companion is ordered front after both, not between them.
        let model = makeModel(tag: "key")
        let window = makeOrderCountingWindow()
        window.pretendsToBeKeyAndVisible = true
        let follower = CompanionLevelFollower(model: model)
        follower.follow(window)

        model.pinned = true
        XCTAssertEqual(window.orderFrontCalls, 0, "not inside the willSet turn")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(window.orderFrontCalls, 1)

        // An unchanged level orders nothing.
        model.keepsAboveWhenInactive = true
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(window.orderFrontCalls, 1)
    }

    func testFollowingAgainAfterACloseLandsAtThePresentAltitude() {
        // AppKit reuses the one About panel, and Settings is built once
        // and shown many times: the next open follows the same window.
        let model = makeModel(tag: "reopen")
        let window = makeWindow()
        let follower = CompanionLevelFollower(model: model)
        follower.follow(window)
        window.close()
        model.pinned = true

        follower.follow(window)
        XCTAssertEqual(window.level, .floating)

        model.pinned = false
        XCTAssertEqual(window.level, .normal)
    }
}
