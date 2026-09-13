import AppKit
import XCTest

@testable import OnetimePad

/// The menu exception to the outside click rule, tested as the pure
/// decision it is (issue #41). Nothing here mocks AppKit: the intervals
/// are written by hand on the same uptime clock the real events carry,
/// which is the whole reason the rule was given this shape. That the
/// window server delivers our menu presses to a global monitor at all is
/// hardware knowledge and stays in the manual matrix.
final class MenuTrackingTests: XCTestCase {
    /// A stand-in for "some moment on the uptime clock". Values below
    /// are offsets from it, in seconds.
    private let t: TimeInterval = 1_000

    // MARK: The four cases the rule exists for

    func testAPressJustBeforeASessionOpensIsTheOneThatOpenedIt() {
        // The click comes first and the notification follows from it, so
        // the opening press always lands fractionally outside its own
        // session. Reading it as an outside click is precisely the bug:
        // clicking Edit rested the card and dismissed the menu.
        let sessions = [MenuTracking.Session(began: t, ended: t + 2)]
        XCTAssertTrue(MenuTracking.claims(press: t - 0.01, sessions: sessions))
    }

    func testAPressDuringASessionBelongsToTheMenu() {
        // Choosing Find, halfway through the menu being up.
        let sessions = [MenuTracking.Session(began: t, ended: t + 2)]
        XCTAssertTrue(MenuTracking.claims(press: t + 1, sessions: sessions))
    }

    func testAPressJustAfterASessionClosesRestsTheSurface() {
        // The menu is gone; the next press is the user going elsewhere,
        // and the rule that dismisses the card must still fire.
        let sessions = [MenuTracking.Session(began: t, ended: t + 2)]
        XCTAssertFalse(MenuTracking.claims(press: t + 2.01, sessions: sessions))
    }

    func testAPlainOutsidePressWithNoMenusAtAllRestsTheSurface() {
        XCTAssertFalse(MenuTracking.claims(press: t, sessions: []))
    }

    // MARK: The boundaries either side

    func testAPressLongBeforeASessionIsNotClaimedByIt() {
        // A click into another app, and only then a menu of ours: the
        // grace covers the gap between a press and its notification,
        // never a whole gesture.
        let sessions = [MenuTracking.Session(began: t, ended: t + 2)]
        XCTAssertFalse(
            MenuTracking.claims(press: t - MenuTracking.openingGrace - 0.01, sessions: sessions)
        )
    }

    func testThePressThatChoosesTheLastItemIsStillInside() {
        // The end of tracking and the press that caused it share a
        // moment; the boundary is inclusive so the choice is not read as
        // a dismissal.
        let sessions = [MenuTracking.Session(began: t, ended: t + 2)]
        XCTAssertTrue(MenuTracking.claims(press: t + 2, sessions: sessions))
    }

    func testAnOpenSessionClaimsEveryPressAfterItsStart() {
        // Judged while the menu is still up, which is what a submenu or
        // a slow choice looks like.
        let sessions = [MenuTracking.Session(began: t, ended: nil)]
        XCTAssertTrue(MenuTracking.claims(press: t + 5, sessions: sessions))
    }

    // MARK: The end that never came

    func testAnOpenSessionStopsClaimingOnceItIsOlderThanTheLimit() {
        // One begin without its end would otherwise claim every press
        // for the life of the process, and the outside click rule would
        // be dead with no symptom but a card that never rests again.
        let sessions = [MenuTracking.Session(began: t, ended: nil)]
        XCTAssertFalse(
            MenuTracking.claims(press: t + MenuTracking.openLimit + 0.01, sessions: sessions)
        )
    }

    func testAMenuHeldOpenNearlyToTheLimitStillClaimsItsPress() {
        // The limit must not cost a real menu its exception: a person
        // reading a long menu, or leaving one standing while they think,
        // is inside the cap for the whole of it.
        let sessions = [MenuTracking.Session(began: t, ended: nil)]
        XCTAssertTrue(
            MenuTracking.claims(press: t + MenuTracking.openLimit - 0.01, sessions: sessions)
        )
    }

    func testAnUnbalancedSessionLetsAPlainOutsideClickRestTheSurfaceAgain() {
        // The shape of the fault, end to end: a begin whose end never
        // posted, and then, much later, the user clicking into another
        // app. That press must rest the card.
        let stranded = [MenuTracking.Session(began: t, ended: nil)]
        XCTAssertFalse(MenuTracking.claims(press: t + 600, sessions: stranded))
    }

    func testAPressBetweenTwoSessionsRestsTheSurface() {
        // Two menus in a row, and a click elsewhere in between: the
        // record is a set of intervals, not a single high water mark.
        let sessions = [
            MenuTracking.Session(began: t, ended: t + 1),
            MenuTracking.Session(began: t + 10, ended: t + 11),
        ]
        XCTAssertFalse(MenuTracking.claims(press: t + 5, sessions: sessions))
    }

    // MARK: Delivery order, which is what the interval form buys

    func testAPressIsJudgedTheSameWhetherOrNotTheMenuHasClosedYet() {
        // The monitor's handler is deferred, and a menu runs a nested
        // loop, so the handler routinely runs after the session it must
        // judge has ended. A boolean "is a menu up" would answer
        // differently in these two states; the interval cannot.
        let open = [MenuTracking.Session(began: t, ended: nil)]
        let closed = [MenuTracking.Session(began: t, ended: t + 2)]
        XCTAssertEqual(
            MenuTracking.claims(press: t + 1, sessions: open),
            MenuTracking.claims(press: t + 1, sessions: closed)
        )
    }

    // MARK: Keeping the record short

    func testOpeningASessionRecordsItAndSweepsTheStaleOnes() {
        let existing = [
            MenuTracking.Session(began: t - 100, ended: t - 99),
            MenuTracking.Session(began: t - 1, ended: t - 0.5),
        ]
        let opened = MenuTracking.opening(existing, at: t)
        XCTAssertEqual(
            opened,
            [
                MenuTracking.Session(began: t - 1, ended: t - 0.5),
                MenuTracking.Session(began: t, ended: nil),
            ]
        )
    }

    func testClosingEndsTheInnermostOpenSession() {
        // A submenu opens and closes inside its parent's session, and
        // posts its own pair of notifications.
        let nested = [
            MenuTracking.Session(began: t, ended: nil),
            MenuTracking.Session(began: t + 1, ended: nil),
        ]
        XCTAssertEqual(
            MenuTracking.closing(nested, at: t + 2),
            [
                MenuTracking.Session(began: t, ended: nil),
                MenuTracking.Session(began: t + 1, ended: t + 2),
            ]
        )
    }

    func testClosingWithNothingOpenInventsNothing() {
        let settled = [MenuTracking.Session(began: t, ended: t + 1)]
        XCTAssertEqual(MenuTracking.closing(settled, at: t + 2), settled)
    }

    func testPruningKeepsAnOpenSessionThatCanStillClaimAPress() {
        // A menu the user has left standing is still the reason the
        // next press must be ignored, so it survives the sweep for as
        // long as it is entitled to claim anything.
        let sessions = [MenuTracking.Session(began: t - 1, ended: nil)]
        XCTAssertEqual(MenuTracking.pruned(sessions, now: t), sessions)
    }

    func testPruningDropsAnOpenSessionThatOutlivedItsLimit() {
        // It can no longer claim a press, and left on the books it would
        // only give the next `closing` the wrong session to end.
        let sessions = [MenuTracking.Session(began: t - 600, ended: nil)]
        XCTAssertTrue(MenuTracking.pruned(sessions, now: t).isEmpty)
    }

    func testPruningDropsSessionsClosedBeyondRetention() {
        let sessions = [
            MenuTracking.Session(began: t - 60, ended: t - 59),
            MenuTracking.Session(began: t - 2, ended: t - 1),
        ]
        XCTAssertEqual(
            MenuTracking.pruned(sessions, now: t),
            [MenuTracking.Session(began: t - 2, ended: t - 1)]
        )
    }

    // MARK: The watch, which holds the record and no policy

    @MainActor
    func testTheWatchFollowsTheNotificationsOfEveryMenuInTheProcess() {
        // Object nil on both observations, so the main menu bar, the
        // status item's menu and the chip context menu are covered
        // without any of them knowing this rule exists. A bare NSMenu
        // stands in for all three, since the notification is the only
        // thing the watch ever sees of them.
        let center = NotificationCenter()
        let watch = MenuTrackingWatch(center: center)
        let menu = NSMenu()

        XCTAssertTrue(watch.sessions.isEmpty)
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertEqual(watch.sessions.count, 1)
        // Open, so a press arriving now is claimed; the press that
        // opened it, a moment earlier, is claimed too.
        let began = watch.sessions.first?.began ?? 0
        XCTAssertNil(watch.sessions.first?.ended)
        XCTAssertTrue(watch.claims(press: began - 0.01))

        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertNotNil(watch.sessions.first?.ended)
        // And the record still answers for that press once the session
        // has closed, which is the order the deferred monitor handler
        // actually runs in: the menu is down by the time it asks.
        XCTAssertTrue(watch.claims(press: began - 0.01))
    }

    @MainActor
    func testTheWatchStopsObservingTheCentreItWasGiven() {
        // Undoing the observations on `.default` regardless of what was
        // injected takes back nothing at all: the real observations
        // outlive the watch, holding it up by its own closures, and a
        // test's centre keeps feeding a watch its case has finished
        // with. The tokens must go back to the centre they came from.
        let center = RecordingCenter()
        do {
            let watch = MenuTrackingWatch(center: center)
            XCTAssertEqual(center.removed, 0)
            withExtendedLifetime(watch) {}
        }
        XCTAssertEqual(center.removed, 2, "both observations belong to the injected centre")
    }

    @MainActor
    func testTheWatchStampsSessionsOnTheClockEventsCarry() {
        // NSEvent.timestamp and systemUptime share a base; if the watch
        // stamped anything else, every comparison above would be
        // meaningless.
        let center = NotificationCenter()
        let watch = MenuTrackingWatch(center: center)
        let before = ProcessInfo.processInfo.systemUptime
        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        let after = ProcessInfo.processInfo.systemUptime

        let began = watch.sessions.first?.began ?? -1
        XCTAssertGreaterThanOrEqual(began, before)
        XCTAssertLessThanOrEqual(began, after)
    }
}

/// A notification centre that counts the observations taken back from
/// it. Nothing else about it differs from the real thing, which is the
/// point: the watch cannot tell it apart, and deinit either returns the
/// tokens here or quietly loses them somewhere else.
private final class RecordingCenter: NotificationCenter, @unchecked Sendable {
    // nonisolated(unsafe) because the watch's deinit is nonisolated, as
    // every deinit is; the only writes come from there and from the test
    // that owns this instance, both on the main thread.
    nonisolated(unsafe) var removed = 0

    override func removeObserver(_ observer: Any) {
        removed += 1
        super.removeObserver(observer)
    }
}
