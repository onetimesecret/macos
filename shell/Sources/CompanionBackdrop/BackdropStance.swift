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

    /// Where the window sits in the stacking order.
    var level: NSWindow.Level {
        switch self {
        case .resting: .backdropDesktop
        case .raised: .floating
        }
    }

    /// Whether clicks pass through to the desktop beneath. The resting
    /// surface must never intercept a click meant for a desktop icon.
    var ignoresMouse: Bool {
        switch self {
        case .resting: true
        case .raised: false
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
