import AppKit
import SwiftUI

/// An edge-docked, non-activating panel — a *surface*, not a window. It
/// sits against a screen edge, is dismissed as easily as it appears,
/// and — the load-bearing rule — **never steals keyboard focus**
/// (docs/spec/04). For assistive-technology users an unexpected focus
/// change is destructive; for everyone it is rude. `.nonactivatingPanel`
/// plus never calling `makeKey` enforces it.
///
/// This is the surface the #4 hardware session measures for ADR-0002:
/// operable under VoiceOver, from the keyboard, without ever taking
/// focus from the frontmost app.
@MainActor
final class PanelController: NSObject {
    private let panel: NSPanel
    private let edge: NSRectEdge

    init(model: PanelModel, edge: NSRectEdge = .maxX) {
        self.edge = edge
        let hosting = NSHostingController(rootView: PanelView(model: model))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Only take key focus if a control inside genuinely asks for it.
        panel.becomesKeyOnlyIfNeeded = true
        // Capture exclusion (docs/spec/05): off by default, surfaced
        // honestly as a toggle in the real app — always on in the spike,
        // since the spike's job is to confirm this and `.none` are
        // compatible with the rest of the panel's behavior.
        panel.sharingType = .none
        super.init()
    }

    /// Show docked to the chosen edge without activating the app or
    /// taking key focus (`orderFrontRegardless`, never
    /// `makeKeyAndOrderFront`).
    func show() {
        positionAgainstEdge()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    private func positionAgainstEdge() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 12
        var frame = panel.frame
        switch edge {
        case .minX:
            frame.origin.x = visible.minX + margin
        default: // .maxX and anything else: dock to the right edge
            frame.origin.x = visible.maxX - frame.width - margin
        }
        frame.origin.y = visible.maxY - frame.height - margin
        panel.setFrame(frame, display: true)
    }
}
