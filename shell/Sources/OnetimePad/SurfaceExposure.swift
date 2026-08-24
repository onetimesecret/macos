import AppKit

/// What the window server is actually doing with the surface at this
/// moment, as opposed to what the stance asked for. The stance decides
/// the posture the surface would like to hold; this reports whether the
/// user can presently see the result.
///
/// The distinction is not academic. A pinned rest floats above other
/// windows and takes the mouse, and its collection behavior asks to be
/// present on every Space including another app's full-screen one. The
/// window server grants that request in its own way, and on a
/// full-screen Space it can keep the surface in the hit-test path while
/// never compositing it (issue #73): clicks aimed at the full-screen app
/// landed in a card nobody could see. Whatever the server's reasons, a
/// surface that is not on screen has no business acting on a press, so
/// the two signals it does publish about the window are read back and
/// the mouse is refused whenever either says the surface is out of
/// sight. Whether those signals tell the truth about a window held in
/// the hit-test path without being composited is not knowable from here;
/// `docs/qa/verification-procedures/pinned-over-fullscreen.md` is where
/// it gets asked, and the gate follows what it is told either way.
///
/// Fail-closed by construction: `isDisplayed` requires both signals to
/// agree, so an unknown or half-answered state refuses the mouse rather
/// than claims it. Neither error is cheap. Refusing wrongly does not
/// merely lose the click: `ignoresMouseEvents` hands it to the window
/// underneath, so a press on a card the user can plainly see acts in
/// somebody else's window instead, and while raised the outside click
/// rule then rests the card the press was aimed at. Claiming wrongly is
/// still the worse of the two, because a misrouted press at least lands
/// in a window the user can see and can undo, while a press taken by a
/// surface nobody is being shown acts where they have no way to look.
struct SurfaceExposure: Equatable {
    /// Whether the window is on the Space the user is looking at, per
    /// `NSWindow.isOnActiveSpace`. False whenever the surface belongs to
    /// a Space that has been switched away from.
    let onActiveSpace: Bool

    /// Whether any part of the window is visible to the user, per
    /// `NSWindow.occlusionState`. This is the signal AppKit publishes so
    /// that an app can stop drawing what nobody will see, and a window
    /// wholly covered by another window reads as occluded here.
    let unoccluded: Bool

    /// The surface is genuinely on screen, so a press over it was aimed
    /// at it.
    var isDisplayed: Bool { onActiveSpace && unoccluded }

    /// On screen and unobstructed: what every posture assumes until the
    /// window server says otherwise, and what a window that has not been
    /// ordered in yet is treated as, since the ordering is about to
    /// happen and a gate closed in that gap would swallow the first
    /// click of the raise it belongs to.
    static let displayed = SurfaceExposure(onActiveSpace: true, unoccluded: true)

    /// The window's own account of itself. A window that is not visible
    /// at all is not being hidden from the user by anything the server
    /// did, so it reads as displayed and leaves the stance's rule
    /// standing; ordering it in is what will make the reading true.
    @MainActor
    init(window: NSWindow) {
        guard window.isVisible else {
            self = .displayed
            return
        }
        onActiveSpace = window.isOnActiveSpace
        unoccluded = window.occlusionState.contains(.visible)
    }

    init(onActiveSpace: Bool, unoccluded: Bool) {
        self.onActiveSpace = onActiveSpace
        self.unoccluded = unoccluded
    }

    /// Which turn is asking for the gate to be written, because they are
    /// not equally trustworthy.
    enum Turn {
        /// The window server volunteered the news: an occlusion change,
        /// or a Space switch that has had time to settle. What it
        /// reports now is what it is doing now.
        case edge

        /// The turn immediately after a stance was applied, which asks
        /// rather than is told. Ordering, levelling and framing have all
        /// just happened and the server's published state has not
        /// necessarily caught up with them.
        case settling
    }

    /// Whether a gate decision taken on this turn may be written to the
    /// window.
    ///
    /// Opening is always allowed, from any turn: the invariant the whole
    /// gate is subordinate to is that a card the user can see must
    /// answer clicks, and a gate stuck shut is the worst failure this
    /// feature can have.
    ///
    /// Closing from the settling turn is refused while the surface is
    /// raised, because that reading can be a frame stale. A raise orders
    /// the card up over whatever was covering it, and for a moment
    /// `occlusionState` still holds the pre-raise answer: occluded. A
    /// gate closed on that answer passes the user's next click through
    /// to the application underneath, whereupon the outside click
    /// monitor rests the card and the raise has undone itself. The
    /// stance is what says the card is meant to be in front, and it is
    /// asked in place of `isKeyWindow`: this app raises without the
    /// keyboard as a matter of course (⌘, hands key status to Settings,
    /// a menu takes it for as long as it is open), and a raise that has
    /// lost the keys is still a raise, still on screen, and still owed
    /// its clicks. `raiseSettleRead` is what closes the gate a moment
    /// later if the card truly is not in front. Waiting for a
    /// notification edge instead would not do: a card raised while it
    /// was already buried reads as occluded before the raise and
    /// occluded after it, and a state that never changes posts no
    /// change.
    ///
    /// The refusal is not free, and what it costs is the fault this type
    /// ranks as the worse one: until the settled reading lands, a raised
    /// card the server is not showing goes on taking presses aimed past
    /// it. The trade is taken because the two errors are not bounded
    /// alike. This one lasts `settledDelay` and then ends of its own
    /// accord, while a gate wrongly shut can last as long as the app
    /// runs, since nothing need change afterwards to reopen it.
    static func writes(
        gate ignores: Bool, from turn: Turn, raised: Bool
    ) -> Bool {
        guard ignores, turn == .settling else { return true }
        return !raised
    }

    /// A re-reading of exposure to be taken later: when to take it, and
    /// what authority it carries when it is written.
    struct SettleRead: Equatable {
        /// Offset in seconds from the edge that scheduled the reading.
        let delay: TimeInterval

        /// The turn the reading counts as, which decides whether it may
        /// close the gate on a window holding the keyboard.
        let turn: Turn
    }

    /// How long a transition takes to be certainly over, animation
    /// included, after which the window server is describing the state
    /// it arrived at rather than the one it left.
    static let settledDelay: TimeInterval = 0.9

    /// When to re-read exposure after one of `settleTriggers`.
    ///
    /// The notification arrives while the transition is still in flight,
    /// and the answer the window server gives during one describes the
    /// state being left. One reading is therefore not enough. If the
    /// transient answer closes the gate on a card that is in fact
    /// present, nothing afterwards has to change for it to stay shut: a
    /// window that claims every Space keeps its membership across the
    /// switch and need not alter its occlusion because the user changed
    /// desktop, so no later edge arrives. The reopening has to be
    /// scheduled rather than waited for.
    ///
    /// The first reading is prompt, so a card that really has gone out
    /// of sight stops taking clicks at once, and it is taken as a
    /// settling turn: mid-transition is where the server's answer is
    /// least trustworthy, and a card the stance says is in front must
    /// not lose its clicks to a guess. The last falls after the transition
    /// is certainly over, carries an edge's authority, and is the one
    /// that decides.
    static let settleReads: [SettleRead] = [
        SettleRead(delay: 0, turn: .settling),
        SettleRead(delay: settledDelay, turn: .edge),
    ]

    /// The system edges after which what the user can see of the surface
    /// may have changed while the stance did not, and about which the
    /// window itself publishes nothing: the active Space changed, the
    /// displays woke, or the session came back from the lock screen or
    /// another user. A card that returned from any of them refusing
    /// clicks would go on refusing them until the user happened to
    /// change desktop.
    ///
    /// Occlusion is not in the list because AppKit posts that one per
    /// window and it needs no settling: a change it reports is the
    /// server's own account of the present.
    static let settleTriggers: [Notification.Name] = [
        NSWorkspace.activeSpaceDidChangeNotification,
        NSWorkspace.screensDidWakeNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
    ]

    /// The reading a raise schedules for itself.
    ///
    /// The settling turn a raise already takes may open the gate but not
    /// close it on a raised window, and for a card raised while it was
    /// already wholly covered that is the end of the matter: occlusion
    /// read occluded before the raise and reads occluded after it, so no
    /// change is posted and no edge ever arrives to correct the gate
    /// held open. A surface the user cannot see would go on taking
    /// clicks for as long as the raise lasted. This reading is late
    /// enough to speak for the raise itself and carries the authority
    /// the settling turn lacks.
    static let raiseSettleRead = SettleRead(delay: settledDelay, turn: .edge)
}

extension BackdropStance {
    /// Whether clicks pass through, judged against what the user can
    /// actually see rather than against the posture alone.
    ///
    /// The stance's own rule decides the ordinary case, and exposure can
    /// only ever be stricter: a surface out of sight always passes its
    /// clicks on, in every stance and in either pin state. The raised
    /// editor is included deliberately, though its summon pulls it to
    /// the user's Space and should keep it visible; an invisible window
    /// holding the keyboard and taking clicks is the worse fault of the
    /// two, so it earns the same gate rather than an exemption.
    func ignoresMouse(pinned: Bool, exposure: SurfaceExposure) -> Bool {
        guard exposure.isDisplayed else { return true }
        return ignoresMouse(pinned: pinned)
    }
}
