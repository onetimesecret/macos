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
    /// The raised editor takes the mouse for its own controls, and
    /// hugs the card for the same reason the pinned rest does.
    ///
    /// ADR-0015 records why this is all-or-nothing and what it costs.
    func ignoresMouse(pinned: Bool) -> Bool {
        switch self {
        case .resting: !pinned
        case .raised: false
        }
    }

    /// Whether the window covers the whole pane or shrinks to the
    /// card's own rect. Only the unpinned rest spans it: that stance is
    /// desktop furniture and mouse-transparent, so its acreage costs
    /// nothing. Every stance that takes the mouse hugs the card,
    /// because window extent is what decides click routing above other
    /// apps' windows and a transparent pane over the whole screen
    /// swallows every click aimed past the card.
    ///
    /// The raised editor used to span the pane and use it as a
    /// click-outside-to-rest catcher. That catcher ate the click: the
    /// surface rested, but the app the user actually clicked never
    /// activated, so the keyboard went back to whichever app happened
    /// to be frontmost and their keystrokes landed somewhere they were
    /// not looking. Resting on an outside click is now a passive
    /// global event monitor's job (`BackdropWindowController`), which
    /// observes the press without consuming it.
    func spansPane(pinned: Bool) -> Bool {
        switch self {
        case .resting: !pinned
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

    /// How the surface relates to Spaces. Every posture claims every
    /// desktop Space, and that constancy is the point (issue #74, ADR-
    /// 0019). A window bound to the Space it was created on drags the
    /// user back to that Space whenever the app is activated, which is
    /// how ⌘Tab kept landing on Desktop 1; and changing the membership
    /// bits on a stance flip asks the window server to reassign the
    /// window between Spaces, which is a recomposition the user sees.
    /// Claiming all of them costs nothing here, since the surface is
    /// wallpaper-adjacent furniture in the resting stance and follows
    /// the user by construction in the raised one, where a keyed window
    /// left behind on another Space would silently swallow ink.
    ///
    /// What still varies is what the surface does once it is there:
    /// `.stationary` and `.ignoresCycle` while resting, because desktop
    /// furniture rides no Mission Control sweep and the window cycle
    /// must never land on a mouse-transparent pane, and neither while
    /// raised, which is an ordinary editor for as long as it is up.
    ///
    /// Full-screen Spaces are the one deliberate exception to the
    /// constancy: an unpinned rest declines them (Plash's recipe; a
    /// desktop-level card in another app's full-screen room could only
    /// ever be an invisible one), while a raise and a pinned rest both
    /// accept them.
    ///
    /// A pinned rest joins every Space, full-screen ones
    /// included: the pin exists to keep the card readable beside
    /// whatever the user is writing, and a pin that vanished on a
    /// Space switch would fail its one purpose. `.ignoresCycle` stays;
    /// the window cycle must never land on a mouse-transparent pane.
    ///
    /// What the pinned rest does *not* keep is `.stationary`. That flag
    /// belongs to the wallpaper recipe the unpinned rest is built from,
    /// where it holds the pane still through a Mission Control sweep at
    /// desktop level. A pinned card is not furniture on the desktop but
    /// an overlay above other applications' windows, and
    /// `.canJoinAllSpaces` with `.fullScreenAuxiliary` is the whole of
    /// the recipe AppKit documents for that. Carrying the third flag
    /// along asked the window server for a combination nothing defines,
    /// and over another app's full-screen Space it answered by keeping
    /// the card in the hit-test path without ever drawing it (issue
    /// #73). The mouse gate makes those invisible presses harmless; this
    /// is the half that tries to make the card visible instead.
    func collectionBehavior(pinned: Bool) -> NSWindow.CollectionBehavior {
        switch self {
        case .resting:
            pinned
                ? [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
                : [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        case .raised: [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }

    /// Which Spaces the window belongs to, separated from what it does
    /// once it is on one. These are the bits the window server reads as
    /// membership, and the only ones whose change makes it move a window
    /// from one Space to another.
    ///
    /// Kept apart so the invariant can be stated and tested on its own:
    /// membership is the same in every posture, so no stance change, pin
    /// or summon ever asks for a reassignment. Full-screen participation
    /// is not counted here, since it decides whether a Space of that
    /// kind is joined at all rather than which desktop the window sits
    /// on.
    func spaceMembership(pinned: Bool) -> NSWindow.CollectionBehavior {
        collectionBehavior(pinned: pinned)
            .intersection([.canJoinAllSpaces, .moveToActiveSpace, .transient])
    }

    /// Whether a summon has to order the window out before ordering it
    /// back, to be sure it lands on the Space the user is looking at.
    ///
    /// The round trip is a blink: the card leaves the screen and returns
    /// within the same gesture, and on every ⌘Tab back from another
    /// Space that blink was the flicker (issue #74). It is kept as a
    /// safety net rather than deleted, because a window that is up on a
    /// Space the user has left is exactly the fault the summon exists to
    /// undo, and being wrong about that would silently swallow ink.
    ///
    /// With membership constant at "every Space" the condition can no
    /// longer arise between desktops, which is where the flicker was
    /// seen: a window on all of them is on whichever desktop the user is
    /// looking at. It is not unreachable. An unpinned rest declines
    /// full-screen Spaces (`.fullScreenNone`), so while another app is
    /// full screen the card is visible on its desktops and yet not on
    /// the Space in front of the user, and a summon from there is the
    /// stranded case exactly; a raise taken while a Space transition is
    /// still in flight can read the same way for a moment. The blink
    /// those cost is the card arriving where the user is, which is the
    /// summon keeping its promise rather than a defect.
    static func requiresSpaceRoundTrip(visible: Bool, onActiveSpace: Bool) -> Bool {
        visible && !onActiveSpace
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

    /// How long the card takes to cross between the glance and the
    /// editor (D-02). The two stances differ only in opacity, and the
    /// crossing is short enough to read as one thing settling rather
    /// than something arriving: 160 ms, or nothing at all when the
    /// person has asked the system for less motion, in which case the
    /// end state lands in the same frame the stance changes. Pure, so
    /// the number and the exception can be asserted without a view.
    static func stanceFadeDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : 0.16
    }

    /// Whether the person has asked for reduced motion, read from the
    /// system setting. A closure rather than a direct read so a test
    /// can drive the answer without touching the accessibility
    /// preference of the machine it runs on. The view asks at each
    /// stance change, which is the only moment the answer matters, so
    /// a setting flipped mid-session is honoured at the next crossing.
    @MainActor static var reduceMotionPreferred: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The fade as it stands right now: the pure rule applied to the
    /// system's answer. This is what the view reads.
    @MainActor static func currentStanceFadeDuration() -> Double {
        stanceFadeDuration(reduceMotion: reduceMotionPreferred())
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
