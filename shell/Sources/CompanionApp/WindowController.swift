import AppKit
import Combine
import SwiftUI

/// The rev C window (docs/spec/04): a real window in the ordinary macOS
/// sense — moves by its title bar, resizes from any edge, remembers its
/// frame — while remaining a **non-activating accessory**. The focus
/// law is unchanged from the panel it replaces: the window accepts the
/// keyboard by deliberate act only (click into the page, click into the
/// empty state — which conjures the page, ADR-0005 — or summon with
/// ⌥Space) and opening it never deactivates the user's frontmost app.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: WindowModel
    private var observers: [AnyCancellable] = []

    init(model: WindowModel) {
        self.model = model
        let hosting = NSHostingController(
            rootView: WindowRootView(model: model)
                .frame(minWidth: 380, minHeight: 300)
                // The transparent title bar arrives as a top safe-area
                // inset; honouring it would stack a blank strip above
                // the header. The header IS the title bar — extend
                // under it (the buttons are hidden; the bar still drags).
                .ignoresSafeArea()
        )
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            // .titled gives the drag-by-title-bar and resize chrome;
            // .nonactivatingPanel keeps the focus law enforceable.
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = hosting
        panel.hidesOnDeactivate = false
        // The chrome is quiet: the SwiftUI header lives where the title
        // would; the transparent title bar remains the drag surface.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 380, height: 300)
        // Only take key focus if a view inside genuinely asks for it
        // (the page's text view); chrome clicks never make it key.
        panel.becomesKeyOnlyIfNeeded = true
        // Position and size persist across summons and relaunches.
        panel.setFrameAutosaveName("CompanionWindow")
        // Capture exclusion (docs/spec/05): invisible to screen sharing
        // and screenshots. Rev C keeps the surface quiet about it — the
        // exclusion itself is unchanged.
        panel.sharingType = .none
        // The window lives on one Space and comes when called.
        // `.canJoinAllSpaces` was the trap: for an accessory app it
        // joins fullscreen Spaces too — hovering over them uninvited —
        // and no collection behavior means "every desktop, but never
        // fullscreen". `.moveToActiveSpace` (with the explicit pull in
        // the summon paths) relocates it to wherever the user is
        // instead; a fullscreen Space only ever sees it by deliberate
        // summon, which `.fullScreenAuxiliary` permits.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init()
        panel.delegate = self
        // The pin decides the altitude among ordinary windows: pinned
        // floats above them (`.statusBar`, panel-floating); unpinned is
        // a normal window others can cover.
        model.$floatsOnTop
            .sink { [weak self] floats in
                guard let panel = self?.panel else { return }
                panel.level = floats ? .statusBar : .normal
                panel.isFloatingPanel = floats
            }
            .store(in: &observers)
        // Debug-only escape hatch: the Settings toggle (seeded by
        // COMPANION_ALLOW_CAPTURE=1 for scripted runs) lifts the
        // capture exclusion so the window can be screenshotted while
        // diagnosing the UI. A release build compiles this out.
        #if DEBUG
        model.$allowCapture
            .sink { [weak self] allow in
                self?.panel.sharingType = allow ? .readOnly : .none
                if allow {
                    FileHandle.standardError.write(Data(
                        "[companion] DEBUG: capture exclusion OFF — window is screenshot-able\n".utf8
                    ))
                }
            }
            .store(in: &observers)
        #endif
    }

    // MARK: Summon & dismiss

    /// Menu-bar click: show without taking the keyboard — clicking into
    /// the page is the deliberate act that grants it. The first reveal
    /// restores yesterday's pages (a Keychain prompt, if one comes,
    /// answers this click — not the launch).
    func show() {
        model.loadStateIfNeeded()
        pullToActiveSpace()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        // Visible on *this* Space toggles off; visible on some other
        // Space is as good as hidden — toggle brings it here.
        if panel.isVisible && panel.isOnActiveSpace { hide() } else { show() }
    }

    /// ⌥Space: summoning by keyboard IS the deliberate act, so the
    /// window takes the keys and the page is ready to type into.
    /// A second ⌥Space dismisses. `.nonactivatingPanel` means making it
    /// key never activates this app or deactivates the frontmost one.
    func summon() {
        if panel.isVisible && panel.isOnActiveSpace {
            hide()
        } else {
            model.loadStateIfNeeded()
            pullToActiveSpace()
            panel.makeKeyAndOrderFront(nil)
            // A pageless window would leave the grant with nothing to
            // land on — key status, dead keystrokes. The summon
            // conjures the page it promises (ADR-0005).
            if model.sheets.isEmpty {
                model.newPage()
            }
            // Focus defers one runloop turn: a page born this instant
            // reaches `activeEditor` only after SwiftUI's next render
            // pass. Asking now would find nil, skip the hand-off, and
            // leave typing to beep at the window (ADR-0005). An editor
            // already mounted simply gets the keys a turn later.
            Task { @MainActor [weak self] in
                guard let self, let editor = self.model.activeEditor else { return }
                self.panel.makeFirstResponder(editor)
            }
        }
    }

    /// A summon means *here*: if the window is up on some other Space,
    /// order it out first so ordering front lands it on this one —
    /// `.moveToActiveSpace` covers the well-behaved cases; the explicit
    /// round trip makes it a guarantee.
    private func pullToActiveSpace() {
        if panel.isVisible && !panel.isOnActiveSpace {
            panel.orderOut(nil)
        }
    }

    /// Esc: hand the keyboard back to wherever it came from. Dropping
    /// key status re-keys the active app's window; ours stays visible.
    func handBackKeys() {
        panel.makeFirstResponder(nil)
        guard panel.isKeyWindow else { return }
        // A non-activating panel has no "resign key" verb. Reordering
        // the window out and back returns the keyboard, but the round
        // trip blinks — a visible hide-and-reappear over a fullscreen
        // Space. Instead, pass key status through an invisible relay
        // and order *it* out: the window server hands the keyboard to
        // the active app while our window never leaves the screen.
        keyRelay.setFrameOrigin(panel.frame.origin)
        keyRelay.makeKeyAndOrderFront(nil)
        keyRelay.orderOut(nil)
        if panel.isKeyWindow {
            // The relay was refused key status (or key bounced back);
            // fall back to the round trip rather than keep the keys.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// The keyboard's waypoint on its way back to the active app: a
    /// zero-alpha, borderless speck that exists only to take key status
    /// from the window and immediately vanish with it.
    private lazy var keyRelay: NSPanel = {
        let relay = KeyRelayPanel(
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

    // MARK: NSWindowDelegate

    /// Double-clicking the title bar stretches the window vertically to
    /// full working height (zoom's "standard frame"); double-click again
    /// returns — AppKit handles the round trip.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let visible = window.screen?.visibleFrame ?? defaultFrame
        return NSRect(
            x: window.frame.origin.x,
            y: visible.minY,
            width: window.frame.width,
            height: visible.height
        )
    }

    /// The ember border tracks key status: it shows exactly while the
    /// page holds the keyboard (docs/spec/04, "accept, never take").
    func windowDidBecomeKey(_ notification: Notification) {
        model.holdsKeys = true
    }

    func windowDidResignKey(_ notification: Notification) {
        model.holdsKeys = false
    }
}

/// A borderless panel AppKit would otherwise refuse key status (no
/// title bar); it exists only as `keyRelay`'s class — a waypoint for
/// the keyboard on its way back to the active app.
private final class KeyRelayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
