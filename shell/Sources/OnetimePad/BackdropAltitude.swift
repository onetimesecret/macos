import AppKit

/// Where the surface sits in the stacking order, as one of three window
/// facts rather than a stance-owned constant. The old rule collapsed
/// altitude into stance and pin alone, which was enough while a raised
/// surface always held the keyboard and Settings never lived beside it;
/// it broke the moment a raised card lost key status to another window
/// and stayed at floating over top of everything, and it had nothing to
/// say about the keep-above preference that a person can now set.
///
/// The resolver takes what actually decides the altitude in one place
/// (ADR-0032): the stance the surface is in, whether it holds the
/// keyboard (or is about to take it, which the controller feeds as
/// `keyed: true` on a fresh raise so the summon does not flash at a
/// lower level), whether the pin is on, and whether the person has
/// asked for the card to keep above other apps when it is not being
/// typed into. A fifth input, whether one of the app's own companion
/// windows (Settings, About, Send Feedback) has the keyboard, lowers
/// a floating card to normal for as long as that is so (ADR-0032
/// Amendment 1, #293): those windows are ordinary windows at normal
/// level, and the card gives way to them rather than the other way
/// round.
enum BackdropAltitude {
    /// Just above the wallpaper's own window, below the desktop icons
    /// and every normal window. The unpinned resting altitude.
    case desktop

    /// The ordinary window level. What a raised surface drops to when
    /// it has lost the keyboard and the keep-above preference is off,
    /// so the app the person is working in can cover it without a fight.
    case normal

    /// Above every normal window. The pin's altitude, the raised and
    /// keyed altitude, and the keep-above altitude while the raised
    /// surface waits for its keys back.
    case floating

    /// The window level the case names, as `NSWindow.Level`. The
    /// desktop case reuses `NSWindow.Level.backdropDesktop` so the
    /// exact figure (one above the wallpaper) has one source of truth.
    var level: NSWindow.Level {
        switch self {
        case .desktop: .backdropDesktop
        case .normal: .normal
        case .floating: .floating
        }
    }

    /// Whether a surface at this altitude shares another app's full
    /// screen Space (ADR-0034). Only a floating one does. An auxiliary
    /// window is shown with the full screen window whatever its level,
    /// so a raised card that had dropped to normal after a ⌘Tab was
    /// still drawn over the full screen app it had just yielded to
    /// (issue 184). Full screen participation therefore follows
    /// altitude rather than stance: a card that floats above other apps
    /// follows the person into their full screen rooms, and a card at
    /// normal or desktop level stays out of them, which is what an
    /// ordinary window at those levels does.
    var joinsFullScreenSpaces: Bool { self == .floating }

    /// The full matrix, in one place. Pinned wins first because the pin
    /// is a promise to keep the card above other apps regardless of
    /// posture; a raised surface floats while it holds the keyboard
    /// (or is about to, per the caller's `keyed: true`); a raised
    /// surface that has lost key status drops to normal unless the
    /// keep-above preference lifts it back to floating; an unpinned
    /// rest is desktop furniture.
    ///
    /// A key companion window then lowers whatever floats to normal,
    /// pin and preference included (#293). The card's own keys win
    /// over it: a raise is committed with `keyed: true` while the
    /// companion still reports key, and the companion's resign follows
    /// a moment later. A card on the desktop stays there, since
    /// lifting furniture to normal would put it among the person's
    /// windows for nothing.
    static func resolve(
        stance: BackdropStance, keyed: Bool, pinned: Bool, keepsAbove: Bool,
        companionKeyed: Bool = false
    ) -> BackdropAltitude {
        let table: BackdropAltitude
        if pinned {
            table = .floating
        } else {
            switch stance {
            case .resting:
                table = .desktop
            case .raised:
                table = keyed || keepsAbove ? .floating : .normal
            }
        }
        if table == .floating, companionKeyed, !keyed { return .normal }
        return table
    }
}
