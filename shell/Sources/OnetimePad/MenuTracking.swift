import AppKit

/// The app's own menus, as the outside click rule has to see them
/// (issue #41).
///
/// While the surface is raised, a global mouse monitor rests it on any
/// press it observes, on the reasoning that a press the card's window
/// never received belongs to somebody else. Menus break that reasoning.
/// Menu tracking runs in windows the window server owns, so a click on
/// our own menu bar, on the status item's menu, or on a chip's context
/// menu reaches the monitor looking exactly like a click into another
/// application. The card fell to the desktop, the app deactivated, and
/// the menu the user had just opened was torn down before an item could
/// be chosen: Edit then Find could never fire, though the same command
/// worked from the keyboard.
///
/// The exception is recorded here as intervals rather than as a
/// suppression flag. A menu runs a nested event loop, and the monitor's
/// own handler is deliberately deferred to a later turn, so by the time
/// the handler asks whether a menu is up, the menu is usually already
/// down and a flag would read false. What does not change is when the
/// press happened: `NSEvent.timestamp` and
/// `ProcessInfo.processInfo.systemUptime` are the same clock, so a
/// session can be written down as the interval it occupied and every
/// press judged by its own moment. Delivery order then stops mattering,
/// which is the whole point of the shape.
///
/// The judgment is a pure function over those intervals, in the manner
/// of `BackdropStance` and `BackdropModel.stanceAfterSummon`; the
/// notifications feed it and nothing more.
enum MenuTracking {
    /// One tracking session, on the uptime clock. `ended` is nil while
    /// the menu is still up, which is the ordinary case at the moment a
    /// press must be judged.
    struct Session: Equatable {
        var began: TimeInterval
        var ended: TimeInterval?
    }

    /// How far before a session's start a press may fall and still be
    /// counted as the press that opened it. The mouse down comes first
    /// and the notification follows as its consequence, so the opening
    /// press is always fractionally outside its own session's interval.
    /// Half a second is far more than that gap and still far less than
    /// the time it takes a person to click somewhere else, and the
    /// window is narrower than it looks: a press is judged within a turn
    /// or two of happening, so a session opened long after some earlier
    /// click cannot reach back and claim it.
    static let openingGrace: TimeInterval = 0.5

    /// How long a closed session stays on the books. Only presses that
    /// have yet to be judged can need it, and those are at most a turn
    /// or a nested loop behind, so five seconds is generous. Sessions
    /// are dropped rather than accumulated because the watch lives as
    /// long as the app does.
    static let retention: TimeInterval = 5

    /// Whether a menu owns this press, and the monitor should therefore
    /// leave the surface raised.
    ///
    /// A press belongs to a session when it falls inside it, when it
    /// falls within `grace` of its start (it is the click that opened
    /// the menu), or when it falls after the start of a session that has
    /// not yet closed. Everything else is genuinely elsewhere: another
    /// application, the desktop, one of our own ordinary windows.
    static func claims(
        press timestamp: TimeInterval,
        sessions: [Session],
        grace: TimeInterval = openingGrace
    ) -> Bool {
        sessions.contains { session in
            timestamp >= session.began - grace && timestamp <= (session.ended ?? .infinity)
        }
    }

    /// A menu began tracking. Old sessions are swept here, on the one
    /// event that is already rare, so the list stays short without a
    /// timer of its own.
    static func opening(_ sessions: [Session], at now: TimeInterval) -> [Session] {
        pruned(sessions, now: now) + [Session(began: now, ended: nil)]
    }

    /// A menu stopped tracking. The innermost open session closes,
    /// because a submenu opens and closes within its parent's session
    /// and posts its own pair of notifications. An end with nothing open
    /// is left alone rather than invented, since a session that never
    /// began cannot have contained a press.
    static func closing(_ sessions: [Session], at now: TimeInterval) -> [Session] {
        guard let index = sessions.lastIndex(where: { $0.ended == nil }) else { return sessions }
        var closed = sessions
        closed[index].ended = now
        return closed
    }

    /// Sessions still worth keeping: everything still open, and
    /// everything that closed within `retention` of now.
    static func pruned(
        _ sessions: [Session], now: TimeInterval, retention: TimeInterval = retention
    ) -> [Session] {
        sessions.filter { session in
            guard let ended = session.ended else { return true }
            return now - ended <= retention
        }
    }
}

/// The live record of menu tracking in this process: two notifications
/// in, one question out. It holds state and no policy; the policy is
/// `MenuTracking`'s pure functions, which is where the tests are.
@MainActor
final class MenuTrackingWatch {
    /// The sessions currently on the books, oldest first.
    private(set) var sessions: [MenuTracking.Session] = []

    // nonisolated(unsafe) for the reason the controller's other
    // observers carry it: deinit is nonisolated even on a @MainActor
    // class (Swift 6) and the tokens are not Sendable. Safe here, since
    // removeObserver is documented thread-safe and every other touch
    // runs on the main actor.
    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []

    /// Object nil on both observations, so every menu in the process is
    /// covered: the main menu bar, the status item's menu, and the chip
    /// context menu in the editor, without any of them having to know
    /// this rule exists.
    ///
    /// Queue nil, so each notification is delivered synchronously on the
    /// thread that posted it. Menus track on the main thread, and the
    /// synchronous delivery is what keeps a session's start on the books
    /// before the nested loop can hand the main queue back to a deferred
    /// monitor handler.
    init(center: NotificationCenter = .default) {
        tokens = [
            center.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.record { MenuTracking.opening($0, at: $1) }
                }
            },
            center.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.record { MenuTracking.closing($0, at: $1) }
                }
            },
        ]
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Whether a press at this event timestamp belongs to one of our
    /// own menus, and so must not rest the surface.
    func claims(press timestamp: TimeInterval) -> Bool {
        MenuTracking.claims(press: timestamp, sessions: sessions)
    }

    /// Both notifications reduce to the same move: read the clock the
    /// events are stamped on, and fold it into the record.
    private func record(
        _ transform: ([MenuTracking.Session], TimeInterval) -> [MenuTracking.Session]
    ) {
        sessions = transform(sessions, ProcessInfo.processInfo.systemUptime)
    }
}
