import AppKit
import Combine
import SwiftUI
import os

/// The background surface's window: a borderless pane covering the
/// primary screen, resting at desktop level (above the wallpaper, below
/// the icons and every normal window) and raised to floating for a
/// moment of editing. The mechanics follow Plash's recovered recipe and
/// the panel's focus law: the stance split lives in `BackdropStance`;
/// this controller only applies it.
@MainActor
final class BackdropWindowController: NSObject {
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
        // The stance is the single source of truth; the window follows.
        model.$stance
            .sink { [weak self] stance in self?.apply(stance) }
            .store(in: &observers)
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
        panel.setFrame(screen.frame, display: true)
    }

    private func apply(_ stance: BackdropStance) {
        // Key-ability first: a window must already refuse `canBecomeKey`
        // by the time it is ordered back, and already accept it by the
        // time it is made key.
        panel.isInteractive = stance.acceptsKey
        panel.ignoresMouseEvents = stance.ignoresMouse
        panel.level = stance.level
        switch stance {
        case .raised:
            // `.nonactivatingPanel` (set at init — the style-mask bit is
            // inert if toggled later): key without activating this app
            // or deactivating the user's frontmost one.
            panel.makeKeyAndOrderFront(nil)
        case .resting:
            // A non-activating panel has no "resign key" verb, and an
            // order-out round trip would blink the card mid-transition.
            // As in the panel's `handBackKeys`: pass key status through
            // an invisible relay and order *it* out — the window server
            // hands the keyboard to the active app while the surface
            // never leaves the screen.
            panel.makeFirstResponder(nil)
            if panel.isKeyWindow {
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
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        // Capture exclusion (docs/spec/05), doubly load-bearing here:
        // the panel is hidden between uses, but the backdrop is *always
        // on screen* — without this, every screen share and screenshot
        // would carry the surface's ink.
        sharingType = .none
        #if DEBUG
        // Debug builds only: COMPANION_ALLOW_CAPTURE=1 lifts the
        // exclusion so the surface can be screenshotted while
        // diagnosing the UI. Not persisted, compiled out of release.
        if ProcessInfo.processInfo.environment["COMPANION_ALLOW_CAPTURE"] != nil {
            sharingType = .readOnly
            FileHandle.standardError.write(Data(
                "[backdrop] DEBUG: capture exclusion OFF — surface is screenshot-able\n".utf8
            ))
        }
        #endif
    }

    /// Resting refuses the keyboard outright; raised may take it. A
    /// borderless panel refuses key by default — the override is what
    /// lets the raised editor type at all.
    override var canBecomeKey: Bool { isInteractive }

    /// Never the app's main window, in either stance.
    override var canBecomeMain: Bool { false }
}
