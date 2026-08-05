import AppKit
import Combine
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
                panel.ignoresMouseEvents = model.stance.ignoresMouse(pinned: pinned)
                panel.level = model.stance.level(pinned: pinned)
                panel.collectionBehavior = model.stance.collectionBehavior(pinned: pinned)
                applyFrame(stance: model.stance, pinned: pinned, geometry: model.geometry)
            }
            .store(in: &observers)
        // While the window hugs the card (a pinned rest), the card's
        // geometry IS the window's frame, so a geometry change made
        // outside a raise (Settings' reset, a screen-change reclamp)
        // must move the window too. Raised drags redraw within the
        // full pane and land here as no-ops.
        model.$geometry
            .dropFirst()
            .sink { [weak self] geometry in
                guard let self else { return }
                if !model.stance.spansPane(pinned: model.pinned) {
                    applyFrame(stance: model.stance, pinned: model.pinned, geometry: geometry)
                }
            }
            .store(in: &observers)
        // Debug-only escape hatch: the Settings toggle (seeded by
        // COMPANION_ALLOW_CAPTURE=1 for scripted runs) lifts the
        // capture exclusion so the surface can be screenshotted while
        // diagnosing the UI. A release build compiles this out.
        #if DEBUG
        model.pages.$allowCapture
            .sink { [weak self] allow in
                self?.panel.sharingType = allow ? .readOnly : .none
                if allow {
                    FileHandle.standardError.write(Data(
                        "[backdrop] DEBUG: capture exclusion OFF — surface is screenshot-able\n".utf8
                    ))
                }
            }
            .store(in: &observers)
        #endif
        // Displays come and go; the surface re-fits the primary screen.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToScreen() }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
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
        applyFrame(stance: model.stance, pinned: model.pinned, geometry: model.geometry)
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
        panel.ignoresMouseEvents = stance.ignoresMouse(pinned: model.pinned)
        panel.level = stance.level(pinned: model.pinned)
        panel.collectionBehavior = stance.collectionBehavior(pinned: model.pinned)
        // Extent before ordering: a raise must already cover the pane
        // when it takes key (the click-outside catcher), and a pinned
        // rest must already hug the card when it orders front.
        applyFrame(stance: stance, pinned: model.pinned, geometry: model.geometry)
        switch stance {
        case .raised:
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
        Self.logger.info(
            "stance=\(stance == .raised ? "raised" : "resting", privacy: .public) level=\(self.panel.level.rawValue, privacy: .public) visible=\(self.panel.isVisible, privacy: .public) frame=\(NSStringFromRect(self.panel.frame), privacy: .public)"
        )
    }

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
        // The debug opt-out lives on the shared model, which seeds
        // itself from COMPANION_ALLOW_CAPTURE and is never persisted;
        // the controller observes it. Starting closed here means a
        // failure to observe leaves the exclusion on.
        sharingType = .none
    }

    /// Resting refuses the keyboard outright; raised may take it. A
    /// borderless panel refuses key by default — the override is what
    /// lets the raised editor type at all.
    override var canBecomeKey: Bool { isInteractive }

    /// Never the app's main window, in either stance.
    override var canBecomeMain: Bool { false }
}
