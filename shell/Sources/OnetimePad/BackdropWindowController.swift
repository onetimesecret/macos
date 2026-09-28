import AppKit
import Combine
import CompanionKit
import SwiftUI
import os

/// The background surface's window: a borderless pane covering the
/// primary screen. Where it sits in the stacking order is
/// `BackdropAltitude.resolve`'s to decide from four inputs together
/// (stance, key status, the pin and the keep-above preference,
/// ADR-0032), so an unpinned rest sits at desktop level (above the
/// wallpaper, below the icons and every normal window), a pinned rest
/// floats above other windows and shrinks to the card's own rect so
/// clicks beside the card stay someone else's, and a raise floats
/// while it holds the keyboard or the pin or the keep-above preference
/// asks it to; a raised card that has lost the keyboard, unpinned and
/// with the preference off, drops to normal so the app the person just
/// gave the keyboard can cover it. The mechanics follow Plash's
/// recovered recipe and the panel's focus law: the stance split lives
/// in `BackdropStance`; this controller only writes what the resolver
/// returns and reapplies it on each input that decides it.
@MainActor
final class BackdropWindowController: NSObject, NSWindowDelegate {
    private let panel: BackdropPanel
    private let model: BackdropModel
    private var observers: [AnyCancellable] = []

    /// What writes the panel's level and collection behavior, and the
    /// holder of the stance the controller last committed to, which is
    /// the stance the delegate methods below are judged against. The
    /// window server calls `windowDidResignKey` synchronously from
    /// inside `apply(.resting)`, while the surface hands its keys back,
    /// and reading `model.stance` from there catches the transition
    /// halfway, when neither the previous stance nor the settling one
    /// answers the altitude question honestly. The keeper is a type of
    /// its own so that this decision can be tested against a window
    /// that never reaches the screen (`BackdropAltitudeKeeper`).
    private let altitude: BackdropAltitudeKeeper

    /// The reconcile task from the last raise: a single main-actor turn
    /// later, the controller re-reads key status and drops the panel
    /// to the keyless altitude if the raise was refused (e.g. by an
    /// application-modal panel that stole key). Cancelled and replaced
    /// on every raise so a stale reconcile from an earlier gesture
    /// cannot fight a later one.
    private var raiseReconcile: Task<Void, Never>?

    // nonisolated(unsafe): deinit is always nonisolated, even on a
    // @MainActor class (Swift 6), and the observation token isn't
    // Sendable. Safe here: removeObserver is documented thread-safe,
    // and every other touch runs on the main actor.
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    // The exposure watch, for the same reason and with the same care:
    // one token from the default centre for the window's own occlusion,
    // one from the workspace centre per settle trigger, and one from the
    // distributed centre per trigger only it carries.
    private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?
    private nonisolated(unsafe) var workspaceObservers: [NSObjectProtocol] = []
    private nonisolated(unsafe) var distributedObservers: [NSObjectProtocol] = []

    init(model: BackdropModel, onCardClick: @escaping () -> Void) {
        self.model = model
        panel = BackdropPanel()
        altitude = BackdropAltitudeKeeper(window: panel)
        panel.contentView = NSHostingView(
            rootView: BackdropRootView(model: model, onCardClick: onCardClick)
        )
        super.init()
        panel.delegate = self
        // The stance is the single source of truth; the window follows.
        model.$stance
            .sink { [weak self] stance in self?.apply(stance) }
            .store(in: &observers)
        model.$ambientPanelEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.applyPanelEnabled(enabled, handBackActivation: false)
            }
            .store(in: &observers)
        // The pin re-altitudes the current stance in place: level,
        // Space membership, mouse transparency and window extent
        // follow, but none of the stance choreography (key relay,
        // activation hand-back, ordering) runs for a mere altitude
        // change. The keeper owns both altitude sinks, the pin's and
        // the keep above preference's (ADR-0032, #187), so that which
        // value each reads on willSet is tested there; the hooks are
        // handed the emitted pin, not the model's, for the same reason.
        altitude.observe(
            model,
            keyed: { [weak self] in self?.panel.isKeyWindow ?? false },
            willRepin: { [weak self] pinned in
                guard let self else { return }
                // In the order `apply(_:)` uses, and for the same
                // reason. The stance's own ungated rule goes first,
                // because the altitude and frame that follow are about
                // to change what is on screen and the window server's
                // present reading still describes the posture being
                // left: a pin judged from that reading is a pin judged
                // from where the card was a moment ago.
                panel.ignoresMouseEvents = model.stance.ignoresMouse(pinned: pinned)
            },
            didRepin: { [weak self] pinned in
                guard let self else { return }
                applyFrame(
                    stance: model.stance, pinned: pinned,
                    geometry: model.displayedGeometry
                )
                // And the readings a turn later, once the window server
                // has made of all that what it will. Without them the
                // pin has no exposure gate at all, since neither an
                // occlusion change nor a Space switch need follow it.
                refreshMouseGateAfterPostureChange()
            }
        )
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
        // The workspace's transitions are the others
        // (`SurfaceExposure.settleTriggers`), and they are watched as
        // well as occlusion because a window that claims every Space
        // keeps its membership across a switch and need not change
        // occlusion state for the card to stop being composited, while a
        // wake or a session hand-back changes what is on screen without
        // telling the window anything about itself. Each is read a turn
        // later, and then once more when the transition is certainly
        // over: the switch is still settling at the moment the
        // notification arrives, the window server's answer during it
        // describes the state being left, and a gate closed on that
        // answer would have no later edge to reopen it.
        workspaceObservers = SurfaceExposure.settleTriggers.map { name in
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshMouseGateAcrossTransition() }
            }
        }
        // The unlock, which the workspace centre does not carry: an
        // ordinary lock switches no session and need not sleep the
        // displays, so it is the distributed centre or nothing.
        distributedObservers = SurfaceExposure.distributedSettleTriggers.map { name in
            DistributedNotificationCenter.default().addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshMouseGateAcrossTransition() }
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    /// Launch: restore the pages and fit the primary screen. An enabled
    /// panel takes its resting place; a disabled panel remains ordered
    /// out until the preference changes.
    func show() {
        model.start()
        fitToScreen()
        if model.ambientPanelEnabled {
            apply(model.stance)
        } else {
            applyPanelEnabled(false, handBackActivation: false)
        }
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

    private func applyPanelEnabled(_ enabled: Bool, handBackActivation: Bool) {
        guard enabled else {
            raiseReconcile?.cancel()
            stopWatchingForOutsideClicks()
            panel.makeFirstResponder(nil)
            panel.isInteractive = false
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            Self.logger.info("ambient panel=hidden")
            return
        }
        apply(
            model.stance,
            panelEnabled: true,
            handBackActivation: handBackActivation
        )
    }

    private func apply(
        _ stance: BackdropStance,
        panelEnabled: Bool? = nil,
        handBackActivation: Bool = true
    ) {
        guard panelEnabled ?? model.ambientPanelEnabled else {
            applyPanelEnabled(false, handBackActivation: false)
            return
        }
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
        // The raise is about to take the keys, so the altitude is
        // resolved with `keyed: true`: the summon must not flash at a
        // lower level for the frame between placing the panel and
        // AppKit reporting it key. The rest hands the keys away, so it
        // resolves with `keyed: false`; the outcome collapses to the
        // keyless answer anyway, but the honest input is worth it. The
        // key answer for the delegate turns lives in the panel's own
        // `isKeyWindow` from that point on.
        //
        // The keeper commits to the stance before it writes, and both
        // happen before the ordering below: the resign-key delegate can
        // arrive synchronously from inside `apply(.resting)` (the
        // surface hands its keys back mid-rest), and it is judged
        // against the stance committed here.
        altitude.commit(
            stance,
            keyed: stance == .raised,
            pinned: model.pinned,
            keepsAbove: model.keepsAboveWhenInactive
        )
        // Extent before ordering: a card-hugging window must already
        // hug when it orders front, or the frame change would be
        // visible as a snap after the fact.
        applyFrame(stance: stance, pinned: model.pinned, geometry: model.displayedGeometry)
        switch stance {
        case .raised:
            watchForOutsideClicks()
            // A summon means *here*: a surface up on some Space the user
            // has left would take the keyboard where they cannot see it
            // and silently swallow ink, so it is ordered out first and
            // ordering front lands it on this Space instead. The round
            // trip is a blink, and on a ⌘Tab back from another Space
            // that blink was the flicker (issue #74); now that every
            // posture claims every desktop, a visible window is already
            // on the desktop the user is looking at and the net does not
            // fire there. It still can from another app's full-screen
            // Space, which an unpinned rest declines to join and so does
            // a raised card that dropped to normal (ADR-0034), and
            // transiently mid-transition, where the blink is the card
            // landing here rather than a defect.
            if BackdropStance.requiresSpaceRoundTrip(
                visible: panel.isVisible, onActiveSpace: panel.isOnActiveSpace
            ) {
                // Logged because the blink is the whole symptom of issue
                // #74 and the net is the one order-out left that can
                // cause it: without a line here, a net that fired and a
                // net that stayed idle look the same in the stream, and
                // the hardware procedure asks the runner to tell them
                // apart.
                Self.logger.info("summon=round trip (surface was off-Space)")
                panel.orderOut(nil)
            }
            // `.nonactivatingPanel` (set at init — the style-mask bit is
            // inert if toggled later): key without activating this app
            // or deactivating the user's frontmost one. (⌘Tab is the
            // one route that activates first; the raise is then its
            // consequence, not its cause.)
            panel.makeKeyAndOrderFront(nil)
            // One-turn reconcile: `makeKeyAndOrderFront` can be
            // refused (an application-modal panel already holds key,
            // for instance), and a refused raise leaves the panel at
            // the raised-keyed altitude with no resign-key event to
            // drop it. A single main-actor turn later, this reads what
            // the window server made of the call and, if the raise did
            // not take, resolves the altitude with the honest keyless
            // input instead.
            raiseReconcile?.cancel()
            raiseReconcile = Task { @MainActor [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                if !panel.isKeyWindow {
                    altitude.reapply(
                        keyed: false,
                        pinned: model.pinned,
                        keepsAbove: model.keepsAboveWhenInactive
                    )
                }
            }
        case .resting:
            stopWatchingForOutsideClicks()
            panel.makeFirstResponder(nil)
            if handBackActivation, NSApp.isActive {
                // A ⌘Tab or Dock summon made this app active; resting
                // hands the whole activation back, not just key status
                // — an active app with no key-able window would strand
                // the keyboard. With an editor window that can take the
                // keyboard it has one: that window is up or about to
                // be, the keyboard goes to it
                // (`PrimaryEditorWindowController`), and the activation
                // is not ours to hand back. Without the exception the
                // rest that opening the window causes would deactivate
                // the app under it. An editor window in the Dock is no
                // exception, since it can take nothing, and the same
                // fact decides the keyboard's return, so the two cannot
                // disagree and leave an active app with no key window.
                // The rule is `BackdropModel.restHandsBackActivation`,
                // ADR-0033's "does not fire while the editor window is
                // visible" read through `editorWindowCanTakeKeys`.
                if BackdropModel.restHandsBackActivation(
                    appActive: true, editorWindowCanTakeKeys: model.editorWindowCanTakeKeys
                ) {
                    NSApp.deactivate()
                }
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
        // Space membership settle after the order, not during it.
        refreshMouseGateAfterPostureChange()
        Self.logger.info(
            "stance=\(stance == .raised ? "raised" : "resting", privacy: .public) window=\(self.panel.windowNumber, privacy: .public) level=\(self.panel.level.rawValue, privacy: .public) visible=\(self.panel.isVisible, privacy: .public) frame=\(NSStringFromRect(self.panel.frame), privacy: .public)"
        )
    }

    // MARK: Altitude and Spaces

    // The level and the collection behavior are written by
    // `BackdropAltitudeKeeper`, from one resolved altitude and only
    // when they actually move. The rule, the guards and the reason the
    // key delegate turns now write the full screen bit (ADR-0034) are
    // stated there. Nothing in this controller writes either property
    // directly.

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
    /// from:raised:)` is where that is decided: the turn after a stance
    /// is applied may open the gate but may not close it on a raised
    /// surface, whose occlusion reading can still be a frame behind the
    /// raise that has just happened.
    private func applyMouseGate(
        stance: BackdropStance, pinned: Bool, from turn: SurfaceExposure.Turn
    ) {
        let exposure = SurfaceExposure(window: panel)
        let ignores = stance.ignoresMouse(pinned: pinned, exposure: exposure)
        guard panel.ignoresMouseEvents != ignores else { return }
        guard SurfaceExposure.writes(gate: ignores, from: turn, raised: stance == .raised) else {
            Self.logger.info(
                "mouse gate=held open (settling over a raised surface) onActiveSpace=\(exposure.onActiveSpace, privacy: .public) unoccluded=\(exposure.unoccluded, privacy: .public)"
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
    ///
    /// The turn a reading was scheduled with is what it deserved when it
    /// was scheduled; `SurfaceExposure.authority(of:sinceTransition:)`
    /// is what it deserves now, which is less whenever a transition
    /// began while the reading was waiting.
    private func refreshMouseGate(from turn: SurfaceExposure.Turn) {
        applyMouseGate(
            stance: model.stance,
            pinned: model.pinned,
            from: SurfaceExposure.authority(of: turn, sinceTransition: sinceTransition)
        )
    }

    /// When the workspace last told us a transition was starting, on the
    /// clock `NSEvent` timestamps share, and how long ago that was. A
    /// transition that never happened is infinitely long over.
    private var transitionBeganAt: TimeInterval?

    private var sinceTransition: TimeInterval {
        guard let transitionBeganAt else { return .infinity }
        return ProcessInfo.processInfo.systemUptime - transitionBeganAt
    }

    /// The pair of readings every posture change takes for itself: a
    /// stance applied, or the pin toggled under a stance that stays put.
    ///
    /// The prompt one is a turn later rather than immediate, since
    /// occlusion and Space membership settle after the ordering rather
    /// than during it, and it reads the model rather than the caller's
    /// arguments because by then both have landed and a stance that
    /// changed in between should win. It may open the gate but not close
    /// it over a raise, for the reason `applyMouseGate` gives, which is
    /// what makes the second reading necessary rather than tidy: a card
    /// put in front while it was already wholly covered posts no
    /// occlusion change afterwards, so without a scheduled reading
    /// nothing would ever shut the gate on a surface the user cannot
    /// see.
    private func refreshMouseGateAfterPostureChange() {
        Task { @MainActor [weak self] in self?.refreshMouseGate(from: .settling) }
        scheduleMouseGateRead(SurfaceExposure.postureSettleRead)
    }

    /// A workspace transition read twice, promptly and then once it has
    /// settled (`SurfaceExposure.settleReads`).
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
    /// one, and the settled answer is the last word. Each reading is
    /// written with the authority the schedule gives it: the prompt one
    /// is a guess taken mid-transition and may not close the gate on a
    /// card that holds the keyboard, while the settled one may.
    private func refreshMouseGateAcrossTransition() {
        // Stamped before the readings are scheduled, and read by every
        // reading that fires from anywhere: a raise's settled reading
        // waiting out its second has no other way to learn that the
        // desktop changed underneath it.
        transitionBeganAt = ProcessInfo.processInfo.systemUptime
        for read in SurfaceExposure.settleReads {
            scheduleMouseGateRead(read)
        }
    }

    /// One scheduled reading, taken now if it has no delay.
    private func scheduleMouseGateRead(_ read: SurfaceExposure.SettleRead) {
        guard read.delay > 0 else {
            refreshMouseGate(from: read.turn)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(read.delay))
            self?.refreshMouseGate(from: read.turn)
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
    /// The open and save panels are the other kind: modern macOS draws
    /// them in a separate service process, so a click on a folder, on
    /// Cancel or on Open reaches this monitor the same way, and resting
    /// on it took the pad away at the moment the person chose their
    /// file. Those are excluded by the AppKit fact `ModalSession`
    /// reads, and the two exclusions meet in `OutsidePress`, which is
    /// where the rule is stated once. Our ordinary windows, Settings
    /// and About, are outside by this rule and rest the card, which is
    /// the older behaviour left standing.
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
                // A menu of ours had the press, or a modal of ours is
                // up, so nothing to dismiss. The menu is judged by the
                // press's own timestamp rather than by whether a menu
                // is up now, because this turn may well be the one the
                // menu's nested loop finally released. The modal is
                // judged now, because a modal session keeps draining
                // this queue and the press that dismisses a panel is a
                // mouse down while the panel returns on the mouse up
                // after it, so the panel is still up when this runs.
                guard OutsidePress.rests(
                    claimedByMenu: self.menuTracking.claims(press: pressedAt),
                    modalSessionRunning: ModalSession.isRunning
                ) else { return }
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
    /// visibility, frame; never content. The subsystem is the resolved
    /// bundle id rather than the release constant, so a dev copy running
    /// beside the installed one writes under `dev.onetimesecret.pad`
    /// and the two can be told apart. Watch both lanes with:
    /// `log stream --predicate 'subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad"}'`
    private static let logger = Logger(
        subsystem: FormFactor.backdrop.loggerSubsystem, category: "surface"
    )

    // MARK: NSWindowDelegate

    /// Key status is reported to the model, which keeps it only while
    /// the panel owns the page content (`BackdropModel.keyStatusChanged`).
    /// The ember border shows exactly while the panel owns and holds
    /// the keyboard (`PageModel.holdsKeys(on:)`), and the summon
    /// decision distinguishes raised-and-keyed (summon rests it) from
    /// raised-but-keyboard-less (summon re-keys it). The altitude the
    /// panel sits at is `BackdropAltitude.resolve`'s to decide from
    /// the four inputs together, and this passes the key answer that
    /// has just arrived so the resolver reads honest facts.
    func windowDidBecomeKey(_ notification: Notification) {
        altitude.reapply(
            keyed: true,
            pinned: model.pinned,
            keepsAbove: model.keepsAboveWhenInactive
        )
        model.keyStatusChanged(of: .panel, keyed: true)
    }

    /// Losing the keyboard is never a rest, and that is load-bearing:
    /// an open or save panel, or a ⌘Tab to work beside the card, can
    /// take key from a surface that stays raised, and a rest here would
    /// pull the pad away under every one of them. The stance moves only
    /// by the routes that name it.
    ///
    /// The keeper's committed stance is what the event is judged
    /// against, not `model.stance`: the resign fires synchronously from
    /// inside `apply(.resting)`, and `model.stance` is halfway between
    /// the previous stance and the settling one at that moment, while
    /// the keeper committed as the controller began the transition and
    /// gives the honest answer. The key turns write level and the full
    /// screen bit that follows it (ADR-0034), and never frame,
    /// membership or ordering.
    func windowDidResignKey(_ notification: Notification) {
        altitude.reapply(
            keyed: false,
            pinned: model.pinned,
            keepsAbove: model.keepsAboveWhenInactive
        )
        model.keyStatusChanged(of: .panel, keyed: false)
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
/// lands on it), `.canJoinAllSpaces` (furniture belongs on every
/// desktop, and a window bound to one drags the user back to it on
/// every activation, issue #74) and `.fullScreenNone` (a full-screen
/// Space is another app's room; the unpinned backdrop does not follow
/// it there). That is the recipe at desktop level only. Full screen
/// participation follows the altitude (ADR-0034): a floating card
/// carries `.fullScreenAuxiliary` and follows the person into those
/// rooms, while a card at normal or desktop level declines them as an
/// ordinary window would. Key status is stance-gated the way Plash gates
/// interactivity. Where the panel sits in the stacking order is not
/// the panel's own concern: `BackdropAltitude.resolve` picks a level
/// from stance, key status, the pin and the keep-above preference
/// together (ADR-0032), and the controller writes it.
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
        // Collection behavior is `BackdropStance`'s to state, from the
        // stance and the resolved altitude together, and the controller
        // applies it on every transition of either.
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
