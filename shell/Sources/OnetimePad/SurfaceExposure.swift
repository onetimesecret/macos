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
/// the two signals it does answer honestly are read back and the mouse
/// is refused whenever either says the surface is out of sight.
///
/// Fail-closed by construction: `isDisplayed` requires both signals to
/// agree, so an unknown or half-answered state refuses the mouse rather
/// than claims it. The worst case of refusing wrongly is a click on the
/// card that does not raise it; the worst case of claiming wrongly is a
/// press meant for another application acted on by this one.
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
