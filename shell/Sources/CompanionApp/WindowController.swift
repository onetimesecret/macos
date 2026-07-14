import AppKit
import Combine
import SwiftUI

/// The rev C window (docs/spec/04): a real window in the ordinary macOS
/// sense — moves by its title bar, resizes from any edge, remembers its
/// frame — while remaining a **non-activating accessory**. The focus
/// law is unchanged from the panel it replaces: the window accepts the
/// keyboard by deliberate act only (click into the page, or summon with
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
        super.init()
        panel.delegate = self
        // The pin decides the whole altitude story, not just the level:
        // pinned floats above everything (`.statusBar`, panel-floating,
        // welcome on fullscreen Spaces); unpinned is a normal window —
        // other windows cover it and fullscreen apps exclude it.
        model.$floatsOnTop
            .sink { [weak self] floats in
                guard let panel = self?.panel else { return }
                panel.level = floats ? .statusBar : .normal
                panel.isFloatingPanel = floats
                panel.collectionBehavior = floats
                    ? [.canJoinAllSpaces, .fullScreenAuxiliary]
                    : [.canJoinAllSpaces]
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
    /// the page is the deliberate act that grants it.
    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    /// ⌥Space: summoning by keyboard IS the deliberate act, so the
    /// window takes the keys and the page is ready to type into.
    /// A second ⌥Space dismisses. `.nonactivatingPanel` means making it
    /// key never activates this app or deactivates the frontmost one.
    func summon() {
        if panel.isVisible {
            hide()
        } else {
            panel.makeKeyAndOrderFront(nil)
            if let editor = model.activeEditor {
                panel.makeFirstResponder(editor)
            }
        }
    }

    /// Esc: hand the keyboard back to wherever it came from. Dropping
    /// key status re-keys the active app's window; ours stays visible.
    func handBackKeys() {
        panel.makeFirstResponder(nil)
        if panel.isKeyWindow {
            // A non-activating panel has no "resign key" verb; briefly
            // reordering out is the reliable way to return the keyboard
            // without dismissing the window.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

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
