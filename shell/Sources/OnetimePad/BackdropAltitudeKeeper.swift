import AppKit
import Combine
import CompanionKit
import os

/// The part of the window controller that turns a stance, a key event,
/// the pin and the keep above preference into what is written on the
/// window: its level and its collection behavior, and nothing else.
///
/// It is a type of its own so that it can be tested against a window
/// that is never put on screen. The controller cannot be built under a
/// test runner without consequences: its first stance sink orders a
/// real pane onto the person's desktop, and a raise takes the keyboard
/// from whatever app they are typing in and installs a global mouse
/// monitor. The decisions that matter here need none of that. They are
/// which stance a key event is judged against, whether a write happens
/// at all, and which value of a changing pin or preference is read, and
/// all three are held in this type. What stays a hand check is that the
/// controller commits before it calls `makeKeyAndOrderFront`.
@MainActor
final class BackdropAltitudeKeeper {
    private let window: NSWindow

    /// The last stance the controller committed to, which is the stance
    /// a key event has to be judged against. The window server calls
    /// `windowDidResignKey` synchronously from inside `apply(.resting)`,
    /// while the surface hands its keys back, and the model's stance
    /// read from there catches the transition halfway. Committed before
    /// the rest hands off, and before `makeKeyAndOrderFront` on a
    /// raise, so a delegate turn arriving in the middle reads the
    /// stance the controller has settled on. A resign judged against
    /// the raise being left would park a resting surface at normal.
    private(set) var committedStance: BackdropStance = .resting

    init(window: NSWindow) {
        self.window = window
    }

    /// A stance change: commit to it, then write its altitude. The
    /// commit comes first because the writes and the ordering that
    /// follows them can fire the key delegates before this returns.
    func commit(_ stance: BackdropStance, keyed: Bool, pinned: Bool, keepsAbove: Bool) {
        committedStance = stance
        write(stance: stance, keyed: keyed, pinned: pinned, keepsAbove: keepsAbove)
    }

    /// An input changed under a stance that stays put: a key event, the
    /// pin, the preference, or the reconcile after a refused raise. The
    /// stance is never the caller's to supply here, which is the point:
    /// every one of those turns reads the committed one.
    func reapply(keyed: Bool, pinned: Bool, keepsAbove: Bool) {
        write(stance: committedStance, keyed: keyed, pinned: pinned, keepsAbove: keepsAbove)
    }

    /// The pin and the keep above preference, followed for the life of
    /// the keeper. Both change the altitude under a stance that stays
    /// put, so neither runs any of the stance choreography (key relay,
    /// activation hand-back, ordering).
    ///
    /// A `@Published` emits on willSet, before the property lands, so
    /// each sink hands the resolver the value it was given for the
    /// input that is changing and reads the model only for the other.
    /// A sink that read `model.pinned` back would write the altitude of
    /// the pin being left. The sinks live here so that this is tested,
    /// on a window that never reaches the screen.
    ///
    /// `keyed` is asked at each change, since key status is the
    /// window's to report and not the model's. The two pin hooks exist
    /// because the controller has work on either side of the altitude
    /// write (the mouse rule before it, the frame and the settling
    /// reads after it), and one sink calling them in order does not
    /// depend on the order Combine delivers to separate subscribers.
    /// Both are handed the emitted pin for the same willSet reason.
    func observe(
        _ model: BackdropModel,
        keyed: @escaping @MainActor () -> Bool,
        willRepin: @escaping @MainActor (Bool) -> Void = { _ in },
        didRepin: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        observers.removeAll()
        model.$pinned
            .dropFirst()
            .sink { [weak self, weak model] pinned in
                guard let self, let model else { return }
                willRepin(pinned)
                reapply(
                    keyed: keyed(), pinned: pinned,
                    keepsAbove: model.keepsAboveWhenInactive
                )
                didRepin(pinned)
            }
            .store(in: &observers)
        // The preference moves the level, and the full screen bit moves
        // with it because it follows the altitude (ADR-0034); no frame,
        // membership, mouse or ordering write belongs to it.
        model.$keepsAboveWhenInactive
            .dropFirst()
            .sink { [weak self, weak model] keepsAbove in
                guard let self, let model else { return }
                reapply(keyed: keyed(), pinned: model.pinned, keepsAbove: keepsAbove)
            }
            .store(in: &observers)
    }

    private var observers: [AnyCancellable] = []

    /// Where the surface sits in the stacking order and what it does on
    /// the Spaces it belongs to, both read from one resolved altitude
    /// and both written only when they actually move.
    ///
    /// The guards are not thrift. An assignment to `collectionBehavior`
    /// is a request to the window server, and a request naming different
    /// membership bits makes it move the window between Spaces; the
    /// stance sinks fire on every raise, including a raise over an
    /// already-raised surface, which is what ⌘Tab back does. Writing the
    /// same value each time asked for that work on every activation
    /// (issue #74). Level is guarded for company, since a level written
    /// is a restack even when the number is unchanged.
    ///
    /// The guard compares the whole value, so a change of stance or of
    /// altitude does still rewrite `collectionBehavior`: `.stationary`,
    /// `.ignoresCycle` and full screen participation are all in there,
    /// and full screen participation follows the altitude (ADR-0034).
    /// That makes the key delegate turns writers of it. A raised card
    /// that is unpinned with the keep above preference off moves
    /// between floating and normal as it gains and loses the keyboard,
    /// and each of those moves is one write that swaps
    /// `.fullScreenAuxiliary` for `.fullScreenNone` or back. A pinned
    /// card, or one with the preference on, floats either way, so the
    /// value does not change and the guard writes nothing. What never
    /// differs is the membership subset the rewrite names
    /// (`BackdropStance.spaceMembership(altitude:)`), which is the part
    /// a reassignment would turn on.
    private func write(stance: BackdropStance, keyed: Bool, pinned: Bool, keepsAbove: Bool) {
        // `BackdropAltitude.resolve` is the whole rule, asked once so
        // the level and the behavior describe the same answer. This
        // writes those two and leaves frame, membership and ordering
        // alone. A drop from floating to normal must not order the
        // window front, since that would raise it above the window the
        // person has just given the keyboard. Level goes first: on a
        // drop the card falls under the other app's windows before it
        // leaves that app's full screen Space, and on a raise it is
        // already floating by the time it joins one.
        let altitude = BackdropAltitude.resolve(
            stance: stance, keyed: keyed, pinned: pinned, keepsAbove: keepsAbove
        )
        let level = altitude.level
        if window.level != level {
            window.level = level
        }
        let behavior = stance.collectionBehavior(altitude: altitude)
        if window.collectionBehavior != behavior {
            // Debug rather than info: a genuine stance change writes
            // this every time and would crowd out the gate's own lines.
            // The window server's side of the guard cannot be tested
            // from here (reading `collectionBehavior` back gives our own
            // last assignment, not what the server did with it), so the
            // hardware run judges it by counting these lines: one per
            // key transition when unpinned with the preference off, and
            // none when pinned or keeping above.
            Self.logger.debug(
                "collectionBehavior write=\(behavior.rawValue, privacy: .public) was=\(self.window.collectionBehavior.rawValue, privacy: .public)"
            )
            window.collectionBehavior = behavior
        }
    }

    /// The same lane the controller writes to, so the behavior writes
    /// read in order against the stance lines.
    private static let logger = Logger(
        subsystem: FormFactor.backdrop.loggerSubsystem, category: "surface"
    )
}
