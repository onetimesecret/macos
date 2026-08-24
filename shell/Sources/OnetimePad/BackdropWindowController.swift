import AppKit
import Combine
import CompanionKit
import SwiftUI
import os

/// The background surface's window: a borderless pane covering the
/// primary screen, resting at desktop level (above the wallpaper, below
/// the icons and every normal window; the pin lifts a rest to floating
/// and shrinks the window to the card's own rect, so clicks beside the
/// card stay someone else's) and raised to floating for a moment of
/// editing. The mechanics follow Plash's recovered recipe and
/// the panel's focus law: the stance split lives in `BackdropStance`;
/// this controller only applies it.
@MainActor
final class BackdropWindowController: NSObject, NSWindowDelegate {
    private let panel: BackdropPanel
    private let model: BackdropModel
    private var observers: [AnyCancellable] = []

    // nonisolated(unsafe): deinit is always nonisolated, even on a
    // @MainActor class (Swift 6), and the observation token isn't
    // Sendable. Safe here: removeObserver is documented thread-safe,
    // and every other touch runs on the main actor.
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    // The exposure watch, for the same reason and with the same care:
    // one token from the default centre for the window's own occlusion,
    // one from the workspace centre for Space switches.
    private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?
    private nonisolated(unsafe) var spaceObserver: NSObjectProtocol?

    init(model: BackdropModel) {
        self.model = model
        panel = BackdropPanel()
        panel.contentView = NSHostingView(rootView: BackdropRootView(model: model))
        super.init()
        panel.delegate = self
        // The stance is the single source of truth; the window follows.
        model.$stance
            .sink { [weak self] stance in self?.apply(stance) }
            .store(in: &observers)
        // The pin re-altitudes the current stance in place: level,
        // Space membership, mouse transparency and window extent
        // follow, but none of the stance choreography (key relay,
        // activation hand-back, ordering) runs for a mere altitude
        // change. The closure's value, not the model's: a @Published
        // emits on willSet, before the property lands.
        model.$pinned
            .dropFirst()
            .sink { [weak self] pinned in
                guard let self else { return }
                // In the order `apply(_:)` uses, and for the same
                // reason. The stance's own ungated rule goes first,
                // because the level and frame below are about to change
                // what is on screen and the window server's present
                // reading still describes the posture being left: a pin
                // judged from that reading is a pin judged from where
                // the card was a moment ago.
                panel.ignoresMouseEvents = model.stance.ignoresMouse(pinned: pinned)
                panel.level = model.stance.level(pinned: pinned)
                panel.collectionBehavior = model.stance.collectionBehavior(pinned: pinned)
                applyFrame(
                    stance: model.stance, pinned: pinned,
                    geometry: model.displayedGeometry
                )
                // And the settled reading a turn later, once the window
                // server has made of all that what it will. Without it
                // the pin has no exposure gate at all, since neither an
                // occlusion change nor a Space switch need follow it.
                Task { @MainActor in
                    self.applyMouseGate(
                        stance: self.model.stance, pinned: self.model.pinned, from: .settling
                    )
                }
            }
            .store(in: &observers)
        // Wherever the window hugs the card (a pinned rest, and every
        // raise), the card's geometry IS the window's frame, so any
        // change to it must move the window. Settled changes and
        // in-flight ones both: a drag under the pointer publishes
        // proposals, and the window following them is what makes the
        // card appear to move at all. A @Published emits on willSet,
        // so the effective geometry is composed from the closure's
        // value and whichever of the pair has already landed.
        model.$geometry
            .dropFirst()
            .sink { [weak self] geometry in
                guard let self else { return }
                follow(geometry: model.inFlight ?? geometry)
            }
            .store(in: &observers)
        model.$inFlight
            .dropFirst()
            .sink { [weak self] inFlight in
                guard let self else { return }
                follow(geometry: inFlight ?? model.geometry)
            }
            .store(in: &observers)
        // Escape hatch: the Settings toggle (seeded by
        // COMPANION_ALLOW_CAPTURE for scripted runs) lifts the capture
        // exclusion so the surface can be screenshotted while
        // diagnosing the UI. The subscription is only installed when
        // this launch offers the switch, so a plain release run keeps
        // the `sharingType = .none` set at window creation and has
        // nothing that can write to it.
        if PageModel.captureOptOutOffered {
            model.pages.$allowCapture
                .sink { [weak self] allow in
                    self?.panel.sharingType = allow ? .readOnly : .none
                    if allow {
                        FileHandle.standardError.write(Data(
                            "[backdrop] capture exclusion OFF: surface is screenshot-able\n".utf8
                        ))
                    }
                }
                .store(in: &observers)
        }
        // Displays come and go; the surface re-fits the primary screen.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToScreen() }
        }
        // The two edges at which what the user can see of the surface
        // changes without the stance changing at all (issue #73). The
        // occlusion notification is the authoritative one: AppKit posts
        // it so that an app can stop drawing what nobody will see, and
        // the mouse gate wants the same fact for the opposite reason.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMouseGate(from: .edge) }
        }
        // A Space switch is the other, and it is watched as well as
        // occlusion because a window that claims every Space keeps its
        // membership across the switch and need not change occlusion
        // state for the card to stop being composited. The reading is
        // taken a turn later, and then once more when the transition is
        // certainly over: the switch is still settling at the moment the
        // notification arrives, the window server's answer during it
        // describes the Space being left, and a gate closed on that
        // answer would have no later edge to reopen it.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshMouseGateAcrossSpaceSwitch() }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    /// Launch: the backdrop takes its place at the desktop immediately —
    /// an ambient surface has no summon ceremony for merely existing.
    func show() {
        model.start()
        fitToScreen()
        apply(model.stance)
    }

    /// The primary screen only, for now — per-display backdrops are an
    /// open question in the feature spec.
    private func fitToScreen() {
        guard let screen = NSScreen.screens.first else { return }
        // The pane changed shape, so the card's geometry may now point
        // off the edge of it; the model pulls the card back on screen.
        // The pane spans the whole screen, but the card is confined
        // to the visible frame — the menu bar and Dock outrank a
        // floating card, and a header parked under the menu bar could
        // never be clicked again. AppKit's bottom-left frames convert
        // to the pane's top-leading coordinates here.
        let usable = CGRect(
            x: screen.visibleFrame.minX - screen.frame.minX,
            y: screen.frame.maxY - screen.visibleFrame.maxY,
            width: screen.visibleFrame.width,
            height: screen.visibleFrame.height
        )
        model.reclamp(pane: usable)
        // Reclamp first, frame second: a card-hugging window must be
        // framed from the geometry the new pane has already judged.
        applyFrame(
            stance: model.stance, pinned: model.pinned, geometry: model.displayedGeometry
        )
    }

    /// The window follows a geometry, but only in the postures where
    /// the window is the card. The unpinned rest spans the pane, so a
    /// card moved within it is a redraw, not a window move.
    private func follow(geometry: BackdropGeometry) {
        guard !model.stance.spansPane(pinned: model.pinned) else { return }
        applyFrame(stance: model.stance, pinned: model.pinned, geometry: geometry)
    }

    /// The window's extent for a given posture: the whole screen when
    /// the stance spans the pane, the card's own rect (translated from
    /// the pane's top-leading coordinates to AppKit's bottom-left
    /// screen coordinates) when it hugs the card. Parameters are
    /// explicit because the pin and geometry sinks fire on willSet,
    /// before the model's own property has landed.
    private func applyFrame(
        stance: BackdropStance, pinned: Bool, geometry: BackdropGeometry
    ) {
        guard let screen = NSScreen.screens.first else { return }
        let target: NSRect
        if stance.spansPane(pinned: pinned) {
            target = screen.frame
        } else {
            target = NSRect(
                x: screen.frame.minX + geometry.origin.x,
                y: screen.frame.maxY - geometry.origin.y - geometry.height,
                width: geometry.width,
                height: geometry.height
            )
        }
        if panel.frame != target {
            panel.setFrame(target, display: true)
        }
    }

    private func apply(_ stance: BackdropStance) {
        // Key-ability first: a window must already refuse `canBecomeKey`
        // by the time it is ordered back, and already accept it by the
        // time it is made key.
        panel.isInteractive = stance.acceptsKey
        // The posture's own rule, ungated, because the ordering below is
        // about to change what is on screen: the window server's present
        // reading describes the posture being left, and a raise arriving
        // over a card that was buried under someone's window would start
        // life mouse-transparent for no reason. The settled reading is
        // taken a turn later, once the ordering has happened.
        panel.ignoresMouseEvents = stance.ignoresMouse(pinned: model.pinned)
        panel.level = stance.level(pinned: model.pinned)
        panel.collectionBehavior = stance.collectionBehavior(pinned: model.pinned)
        // Extent before ordering: a card-hugging window must already
        // hug when it orders front, or the frame change would be
        // visible as a snap after the fact.
        applyFrame(stance: stance, pinned: model.pinned, geometry: model.displayedGeometry)
        switch stance {
        case .raised:
            watchForOutsideClicks()
            // A summon means *here*: if the surface is up on some other
            // Space, order it out first so ordering front lands it on
            // this one — `.moveToActiveSpace` covers the well-behaved
            // cases; the explicit round trip makes it a guarantee (the
            // panel's summon does the same). A keyed surface the user
            // cannot see would silently swallow ink.
            if panel.isVisible && !panel.isOnActiveSpace {
                panel.orderOut(nil)
            }
            // `.nonactivatingPanel` (set at init — the style-mask bit is
            // inert if toggled later): key without activating this app
            // or deactivating the user's frontmost one. (⌘Tab is the
            // one route that activates first; the raise is then its
            // consequence, not its cause.)
            panel.makeKeyAndOrderFront(nil)
        case .resting:
            stopWatchingForOutsideClicks()
            panel.makeFirstResponder(nil)
            if NSApp.isActive {
                // A ⌘Tab or Dock summon made this app active; resting
                // hands the whole activation back, not just key status
                // — an active app with no key-able window would strand
                // the keyboard.
                NSApp.deactivate()
            } else if panel.isKeyWindow {
                // The hotkey path: the app never activated, so there is
                // no activation to return — only key status. A
                // non-activating panel has no "resign key" verb, and an
                // order-out round trip would blink the card
                // mid-transition. As in the panel's `handBackKeys`:
                // pass key status through an invisible relay and order
                // *it* out — the window server hands the keyboard to
                // the active app while the surface never leaves the
                // screen.
                keyRelay.setFrameOrigin(panel.frame.origin)
                keyRelay.makeKeyAndOrderFront(nil)
                keyRelay.orderOut(nil)
                if panel.isKeyWindow {
                    // The relay was refused key status (or key bounced
                    // back); fall back to the round trip rather than
                    // keep the keys — the blink is the lesser wrong.
                    panel.orderOut(nil)
                }
            }
            // Front of the *resting* level, not `orderBack`: the level
            // itself keeps the surface under the icons and every normal
            // window, while back-of-level ordering could resolve behind
            // the wallpaper's own window and vanish on a bare desktop.
            panel.orderFrontRegardless()
        }
        // Now that the ordering has happened, ask the window server what
        // it made of it. A turn later rather than here: occlusion and
        // Space membership settle after the order, not during it, and
        // the closure reads the model rather than this call's arguments
        // because by then both have landed and a stance that changed in
        // between should win. That turn may open the gate but not close
        // it over a keyed window, for the reason `applyMouseGate` gives.
        Task { @MainActor in self.refreshMouseGate(from: .settling) }
        Self.logger.info(
            "stance=\(stance == .raised ? "raised" : "resting", privacy: .public) level=\(self.panel.level.rawValue, privacy: .public) visible=\(self.panel.isVisible, privacy: .public) frame=\(NSStringFromRect(self.panel.frame), privacy: .public)"
        )
    }

    // MARK: The mouse gate

    /// Whether the surface takes the mouse right now, judged by the
    /// stance and by what the window server is actually showing of it
    /// (issue #73). The decision is `BackdropStance.ignoresMouse(pinned:
    /// exposure:)`; all this does is read the window and apply it.
    ///
    /// Written only on a change, since the gate is consulted from every
    /// edge that can move it and an unchanged assignment is a message to
    /// the window server for nothing. The change is logged because the
    /// gate closing is invisible by definition: the symptom of a gate
    /// stuck shut is a pinned card that stops answering clicks, and this
    /// line is the only way to tell that from a card that never got the
    /// press at all.
    ///
    /// Which turn is asking matters, and `SurfaceExposure.writes(gate:
    /// from:isKey:)` is where that is decided: the turn after a stance
    /// is applied may open the gate but may not close it on a keyed
    /// window, whose occlusion reading can still be a frame behind the
    /// raise that has just happened.
    private func applyMouseGate(
        stance: BackdropStance, pinned: Bool, from turn: SurfaceExposure.Turn
    ) {
        let exposure = SurfaceExposure(window: panel)
        let ignores = stance.ignoresMouse(pinned: pinned, exposure: exposure)
        guard panel.ignoresMouseEvents != ignores else { return }
        guard SurfaceExposure.writes(gate: ignores, from: turn, isKey: panel.isKeyWindow) else {
            Self.logger.info(
                "mouse gate=held open (settling over a keyed window) onActiveSpace=\(exposure.onActiveSpace, privacy: .public) unoccluded=\(exposure.unoccluded, privacy: .public)"
            )
            return
        }
        panel.ignoresMouseEvents = ignores
        Self.logger.info(
            "mouse gate=\(ignores ? "closed" : "open", privacy: .public) onActiveSpace=\(exposure.onActiveSpace, privacy: .public) unoccluded=\(exposure.unoccluded, privacy: .public)"
        )
    }

    /// The gate re-judged against the model as it stands, for the edges
    /// that carry no posture of their own: an occlusion change, a Space
    /// switch, and the settling turn after a stance or the pin is
    /// applied.
    private func refreshMouseGate(from turn: SurfaceExposure.Turn) {
        applyMouseGate(stance: model.stance, pinned: model.pinned, from: turn)
    }

    /// The Space switch read twice, promptly and then once it has
    /// settled (`SurfaceExposure.spaceSettleReads`).
    ///
    /// A single reading taken from the notification lands
    /// mid-transition, where the server is still describing the desktop
    /// the user has left, and it can close the gate on a card that is
    /// perfectly visible. Nothing would reopen it. The window claims
    /// every Space, so its occlusion need not change when the desktop
    /// does, and the gate would stay shut for as long as the app runs:
    /// a card the user can see, refusing every click, with no way to
    /// tell that from the pin having quietly failed. The schedule is
    /// what guarantees a settled answer always follows the transient
    /// one, and the settled answer is the last word.
    private func refreshMouseGateAcrossSpaceSwitch() {
        for delay in SurfaceExposure.spaceSettleReads {
            guard delay > 0 else {
                refreshMouseGate(from: .edge)
                continue
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.refreshMouseGate(from: .edge)
            }
        }
    }

    // MARK: Resting on an outside click

    /// Watch for a click landing anywhere that is not this app, and
    /// rest the surface when one does.
    ///
    /// "Outside" means outside everything this app puts on screen, and
    /// the card's own window is only part of that. Menus are the rest:
    /// they track in windows the window server owns, so a press on our
    /// menu bar, on the status item's menu, or on a chip's context menu
    /// reaches this monitor indistinguishable from a click into another
    /// application. Those presses are not outside anything, and resting
    /// on them tore down the menu the user had just opened (issue #41),
    /// so they are excluded here by the intervals `MenuTracking` keeps.
    /// Our ordinary windows, Settings and About, are outside by this
    /// rule and rest the card, which is the older behaviour left
    /// standing.
    ///
    /// A *global* monitor deliberately: it observes the press and
    /// consumes nothing, so the click goes on to the window it was
    /// aimed at and macOS activates that app in the ordinary way. The
    /// pane-wide catcher view this replaces did consume it: the
    /// surface rested, but the clicked app never activated, so the
    /// keyboard fell back to whichever app happened to be frontmost
    /// and the user's next keystrokes went somewhere they were not
    /// looking. (Mouse monitors need no Accessibility grant; only
    /// keyboard ones do.)
    ///
    /// Only while raised. A resting surface has nothing to dismiss,
    /// and a monitor that outlived the raise would be a standing
    /// observer of every click the user makes all day.
    private func watchForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // The moment of the press, carried out of the closure on
            // its own: NSEvent is not Sendable, and the timestamp is
            // the only thing the decision needs. It shares its base
            // with `ProcessInfo.processInfo.systemUptime`, which is how
            // it can be compared against the menu tracking intervals.
            let pressedAt = event.timestamp
            // Hopped to a later turn deliberately, not merely to reach
            // the main actor: the clicked app's activation and our own
            // resign-key are still in flight when this fires, and
            // `apply(.resting)` reads `isKeyWindow` to decide whether
            // to run the key relay. Resting synchronously could read
            // stale key status and pull the keyboard back out of the
            // app the user just chose, which is the very fault this
            // whole change exists to remove.
            Task { @MainActor in
                guard let self else { return }
                // A menu of ours had the press, so nothing to dismiss.
                // Judged by the press's own timestamp rather than by
                // whether a menu is up now, because this turn may well
                // be the one the menu's nested loop finally released.
                guard !self.menuTracking.claims(press: pressedAt) else { return }
                self.model.rest()
            }
        }
    }

    private func stopWatchingForOutsideClicks() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    // nonisolated(unsafe) for the same reason as `screenObserver`: deinit
    // is nonisolated even on a @MainActor class, and the monitor token
    // is not Sendable. Every other touch is on the main actor.
    private nonisolated(unsafe) var outsideClickMonitor: Any?

    /// What the app's own menus were doing, and when. It watches for
    /// the life of the controller rather than only while raised: two
    /// notifications cost nothing, and a session that began before the
    /// raise is exactly the kind of thing a press then has to be
    /// judged against.
    private let menuTracking = MenuTrackingWatch()

    /// The surface's mechanics in the unified log — stance, level,
    /// visibility, frame; never content. Watch with:
    /// `log stream --predicate 'subsystem == "com.onetimesecret.companion.backdrop"'`
    private static let logger = Logger(
        subsystem: "com.onetimesecret.companion.backdrop", category: "surface"
    )

    // MARK: NSWindowDelegate

    /// Key status feeds the model: the ember border shows exactly
    /// while the surface holds the keyboard, and the summon decision
    /// distinguishes raised-and-keyed (summon rests it) from
    /// raised-but-keyboard-less (summon re-keys it).
    func windowDidBecomeKey(_ notification: Notification) {
        model.holdsKeys = true
    }

    func windowDidResignKey(_ notification: Notification) {
        model.holdsKeys = false
    }

    /// The keyboard's waypoint on its way back to the active app: a
    /// zero-alpha, borderless speck that exists only to take key status
    /// from the surface and immediately vanish with it.
    private lazy var keyRelay: NSPanel = {
        let relay = BackdropKeyRelayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        relay.alphaValue = 0
        relay.isReleasedWhenClosed = false
        relay.isExcludedFromWindowsMenu = true
        relay.sharingType = .none
        relay.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return relay
    }()
}

/// A borderless panel AppKit would otherwise refuse key status (no
/// title bar); it exists only as `keyRelay`'s class — a waypoint for
/// the keyboard on its way back to the active app.
private final class BackdropKeyRelayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The window itself. Plash's desktop-window recipe, adapted: a
/// borderless, transparent, shadowless pane that is `.stationary` (does
/// not ride Mission Control transitions), `.ignoresCycle` (⌘` never
/// lands on it), and `.fullScreenNone` (a full-screen Space is another
/// app's room; the backdrop does not follow it there). Key status is
/// stance-gated the way Plash gates interactivity.
final class BackdropPanel: NSPanel {
    /// Set by the controller from the stance, before ordering changes.
    var isInteractive = false

    init() {
        super.init(
            contentRect: .zero,
            // `.nonactivatingPanel` must be set at init: AppKit only
            // applies the window-server tag during initialization, and
            // a panel given the bit later draws as key yet silently
            // refuses text input (the philz.blog trap, cited in the
            // research doc).
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        // Collection behavior is stance-owned (`BackdropStance`) and
        // applied by the controller on every transition.
        // Capture exclusion (docs/spec/05), doubly load-bearing here:
        // the panel is hidden between uses, but the backdrop is *always
        // on screen* — without this, every screen share and screenshot
        // would carry the surface's ink.
        // The opt-out lives on the shared model, which seeds itself
        // from COMPANION_ALLOW_CAPTURE and is never persisted; the
        // controller observes it only when this launch offers it.
        // Starting closed here means a launch that never observes,
        // which is every ordinary release launch, leaves the exclusion
        // on for the life of the window.
        sharingType = .none
    }

    /// Resting refuses the keyboard outright; raised may take it. A
    /// borderless panel refuses key by default — the override is what
    /// lets the raised editor type at all.
    override var canBecomeKey: Bool { isInteractive }

    /// Never the app's main window, in either stance.
    override var canBecomeMain: Bool { false }
}
