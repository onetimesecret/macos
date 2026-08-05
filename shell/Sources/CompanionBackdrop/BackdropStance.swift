import AppKit

/// The backdrop's two postures, and everything that mechanically follows
/// from them (docs/spec/feature/background-surface). The research's
/// central lesson — even the reference wallpaper app cannot be typed
/// into *at* the desktop level — is encoded here as a hard split: the
/// surface is either resting (a passive pane behind every window) or
/// raised (a floating, key-taking editor), never something in between.
enum BackdropStance: Equatable {
    /// Behind everything: desktop level, mouse-transparent, refuses the
    /// keyboard. Glanceable, never interactive.
    case resting

    /// Summoned for a moment of editing: floating level, clickable,
    /// may become key. Structurally the panel model — the backdrop
    /// borrows it exactly as long as the user is typing.
    case raised

    /// Where the window sits in the stacking order. The pin lifts the
    /// resting pane above normal windows. A pinned rest still refuses
    /// the keyboard (the hard split's central lesson holds); its one
    /// concession to the mouse is that a click raises it, the same
    /// deliberate act any other summon is.
    func level(pinned: Bool) -> NSWindow.Level {
        switch self {
        case .resting: pinned ? .floating : .backdropDesktop
        case .raised: .floating
        }
    }

    /// Whether clicks pass through to whatever lies beneath. Mouse
    /// transparency is all-or-nothing per window, decided at the
    /// window server. The unpinned rest must never intercept a click
    /// meant for a desktop icon, so it stays transparent. A pinned
    /// rest floats above other windows; a card that stayed transparent
    /// there would route clicks into windows the user cannot see (the
    /// click-through trap this replaces), so it takes the mouse, and
    /// `spansPane` shrinks the window to the card so only the card
    /// takes it. The click's one meaning while resting is "raise".
    func ignoresMouse(pinned: Bool) -> Bool {
        switch self {
        case .resting: !pinned
        case .raised: false
        }
    }

    /// Whether the window covers the whole pane or shrinks to the
    /// card's own rect. Full coverage is the norm: the unpinned rest
    /// is desktop furniture (and mouse-transparent, so its acreage
    /// costs nothing), and the raised editor needs the pane as its
    /// click-outside-to-rest catcher. The pinned rest is the one
    /// posture where window extent decides click routing above other
    /// apps' windows, so there the window hugs the card and the rest
    /// of the screen stays someone else's to click.
    func spansPane(pinned: Bool) -> Bool {
        switch self {
        case .resting: !pinned
        case .raised: true
        }
    }

    /// Whether the window may take the keyboard. Resting refuses it
    /// outright — a background surface that could silently receive
    /// keystrokes would be a keylogger-shaped bug.
    var acceptsKey: Bool {
        switch self {
        case .resting: false
        case .raised: true
        }
    }

    /// How the surface relates to Spaces. Resting is furniture on the
    /// desktop: unaffected by Mission Control transitions, skipped by
    /// the window cycle, absent from full-screen Spaces (Plash's
    /// recipe). Raised follows the user instead: it moves to the
    /// active Space — full-screen ones included — because a surface
    /// that holds the keyboard must be visible where the user is
    /// looking; keys landing on an off-Space window would silently
    /// swallow ink.
    ///
    /// A pinned rest joins every Space instead, full-screen ones
    /// included: the pin exists to keep the card readable beside
    /// whatever the user is writing, and a pin that vanished on a
    /// Space switch would fail its one purpose. `.ignoresCycle` stays;
    /// the window cycle must never land on a mouse-transparent pane.
    func collectionBehavior(pinned: Bool) -> NSWindow.CollectionBehavior {
        switch self {
        case .resting:
            pinned
                ? [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                : [.stationary, .ignoresCycle, .fullScreenNone]
        case .raised: [.moveToActiveSpace, .fullScreenAuxiliary]
        }
    }

    /// The countdown redraw cadence. The backdrop is always on screen,
    /// so — unlike the panel, whose 1 Hz tick runs only while visible —
    /// its redraw never stops. The frugality budget (docs/spec/03 §4)
    /// is honoured by coarseness instead: a glance surface repaints
    /// every 30 s; only the raised editor earns the 1 Hz tick.
    var tickInterval: TimeInterval {
        switch self {
        case .resting: 30
        case .raised: 1
        }
    }
}

extension NSWindow.Level {
    /// AppKit exposes no `.desktop` constant; the window server does
    /// (CGWindowLevelForKey). One *above* it, deliberately: the
    /// wallpaper image is itself a window at the desktop level, so a
    /// surface parked at that same level can resolve behind the
    /// wallpaper and be invisible on a bare desktop. +1 clears the
    /// wallpaper while staying far below the desktop icons
    /// (`.desktopIconWindow` is 20 levels up) and every normal window.
    static let backdropDesktop = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
    )
}
