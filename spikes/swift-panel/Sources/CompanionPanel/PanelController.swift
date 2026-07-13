import AppKit
import Combine
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
    private var levelObserver: AnyCancellable?

    init(model: PanelModel, edge: NSRectEdge = .maxX) {
        self.edge = edge
        // NSHostingController sizes the window to the SwiftUI view's
        // fitting size, which otherwise collapses to the content's
        // intrinsic (narrow) width and overrides the contentRect below.
        // Pin the root to the intended shelf size so the window stays
        // 320 wide, top-anchored, the ScrollView filling the rest.
        let hosting = NSHostingController(
            rootView: PanelView(model: model).frame(width: 320, height: 480, alignment: .top)
        )
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        // Window level is a persisted setting (PanelModel.floatsOnTop),
        // applied and kept in sync in the observer set up after super.init.
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Only take key focus if a control inside genuinely asks for it.
        panel.becomesKeyOnlyIfNeeded = true
        // Capture exclusion (docs/spec/05): secrets on screen must not
        // leak into screenshots or screen recordings, so the panel is
        // excluded from capture. In the real app this is an honest,
        // user-visible toggle; the spike forces it on, since the spike's
        // job is to confirm `.none` is compatible with the rest of the
        // panel's behavior.
        panel.sharingType = .none
        // Debug-only escape hatch: a DEBUG build honours
        // COMPANION_ALLOW_CAPTURE=1 so the panel can be screenshotted
        // while diagnosing the UI. A release build compiles this out
        // entirely, so capture exclusion can never be disabled in a
        // shipped binary.
        #if DEBUG
        if ProcessInfo.processInfo.environment["COMPANION_ALLOW_CAPTURE"] != nil {
            panel.sharingType = .readOnly
            FileHandle.standardError.write(Data(
                "[companion] DEBUG: capture exclusion OFF — panel is screenshot-able\n".utf8
            ))
        }
        #endif
        super.init()
        // Follow the float-on-top setting: `.statusBar` sits above every
        // other app; `.normal` lets other windows cover the panel. The
        // publisher emits its current value on subscribe, so this also
        // sets the initial level.
        levelObserver = model.$floatsOnTop.sink { [weak self] floats in
            self?.panel.level = floats ? .statusBar : .normal
        }
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
