import AppKit
import Combine

/// Keeps one companion window (Settings, About) at the surface's
/// keyless altitude for as long as that window is open (ADR-0032,
/// workplan item A4).
///
/// A raised card floats above normal windows, and so does a pinned
/// resting one; a companion left at `.normal` would sit key yet
/// invisible beneath it, since level beats key status for stacking. The
/// answer cannot be read once at open either. The pin can be toggled on
/// the card while About is up, and the card then floats over a window
/// that was placed for the altitude it had a moment earlier. So the
/// follower writes the level when it starts and again whenever one of
/// the three inputs the keyless resolver reads is published, and it
/// lets go when the window closes.
///
/// There is one of these per companion window and one implementation
/// for both, so Settings and About cannot drift apart.
@MainActor
final class CompanionLevelFollower {
    private let model: BackdropModel
    private weak var window: NSWindow?
    private var observers: [AnyCancellable] = []

    // nonisolated(unsafe): deinit is nonisolated even on a @MainActor
    // class, and the token is not Sendable. `removeObserver` is
    // documented thread safe, and every other touch is on the main
    // actor.
    private nonisolated(unsafe) var closeObserver: NSObjectProtocol?

    init(model: BackdropModel) {
        self.model = model
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    /// Whether a window is being followed right now.
    var isFollowing: Bool { !observers.isEmpty }

    /// How many subscriptions are held: one per input the resolver
    /// reads and one for the close, so four while following and none
    /// otherwise. Following the same window again must not add to it,
    /// and a doubled set is invisible in the level it writes, which is
    /// why the number is readable.
    var subscriptionCount: Int { observers.count + (closeObserver == nil ? 0 : 1) }

    /// Start following, or carry on. The level is written from the
    /// model as it stands on every call, so reopening a window that is
    /// already followed still lands it at the present altitude. The
    /// sinks are installed once per window; a different window replaces
    /// the one followed before.
    ///
    /// The close is watched through the notification centre rather than
    /// the window's delegate, because the About panel is AppKit's and
    /// its delegate is not ours to take.
    func follow(_ window: NSWindow) {
        if self.window !== window {
            stop()
        }
        self.window = window
        apply()
        guard observers.isEmpty else { return }
        // A @Published emits on willSet, before the property lands, so
        // each sink hands the resolver the value it was given for the
        // input that is changing and reads the model only for the two
        // that are not.
        model.$stance
            .dropFirst()
            .sink { [weak self] stance in self?.apply(stance: stance) }
            .store(in: &observers)
        model.$pinned
            .dropFirst()
            .sink { [weak self] pinned in self?.apply(pinned: pinned) }
            .store(in: &observers)
        model.$keepsAboveWhenInactive
            .dropFirst()
            .sink { [weak self] keepsAbove in self?.apply(keepsAbove: keepsAbove) }
            .store(in: &observers)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Let go of the window. A closed window that kept its sinks would
    /// still have a level written onto it, which nobody sees but is one
    /// wire more than the app needs. The next `follow` builds a fresh
    /// set against the model as it stands then.
    func stop() {
        observers.removeAll()
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        window = nil
    }

    /// The companion has no key status of its own to feed the resolver,
    /// so it reads the surface's keyless answer and maps desktop to
    /// normal (a titled window at desktop level could resolve behind
    /// the wallpaper as easily as the surface can). Written only on a
    /// change, since a level written is a restack even when the number
    /// is the same.
    private func apply(
        stance: BackdropStance? = nil, pinned: Bool? = nil, keepsAbove: Bool? = nil
    ) {
        guard let window else { return }
        let level = BackdropAltitude.keylessAltitude(
            stance: stance ?? model.stance,
            pinned: pinned ?? model.pinned,
            keepsAbove: keepsAbove ?? model.keepsAboveWhenInactive
        ).companionLevel
        guard window.level != level else { return }
        window.level = level
        // The surface's own level moves on the same published change,
        // from a separate subscriber, and a level written lands a
        // window at the front of its new level. Which of the two is
        // written last is Combine's to decide, so a companion that
        // holds the keyboard is ordered front a turn later, once both
        // writes have happened, and stays in front of the card either
        // way. Only when key: a Pin toggled on the card while Settings
        // is merely open must not pull Settings over the card the
        // person is working in.
        Task { @MainActor [weak window] in
            guard let window, window.isKeyWindow, window.isVisible else { return }
            window.orderFront(nil)
        }
    }
}
