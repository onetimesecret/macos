import AppKit
import SwiftUI

/// Settings, backdrop edition: one small window, mirroring the panel
/// app's SettingsWindowController by shape rather than by import
/// (ADR-0010 keeps the targets apart). Connection settings are out of
/// scope for this surface; the window's whole business today is the
/// surface's own geometry. Unlike the backdrop itself this window
/// activates normally: opening Settings is a deliberate act.
@MainActor
final class BackdropSettingsWindowController {
    private var window: NSWindow?
    private let model: BackdropModel

    init(model: BackdropModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosted = NSHostingController(rootView: BackdropSettingsView(model: model))
            // The window owns its size; without this the hosting
            // controller re-imposes the view's preferred height and
            // fights the frame the window was given.
            hosted.sizingOptions = []
            let window = NSWindow(contentViewController: hosted)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 420, height: 160))
            window.center()
            self.window = window
        }
        // A raised card floats above normal windows; a .normal-level
        // Settings window would open key yet invisible beneath it, since
        // level beats key status for stacking. Match the card's current
        // level so ordering front actually reveals it.
        window?.level = model.stance == .raised ? .floating : .normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The surface section: one honest button. The geometry the drag and
/// resize gestures persist can wander somewhere unhelpful; this puts
/// the card back where a fresh install would have it.
struct BackdropSettingsView: View {
    @ObservedObject var model: BackdropModel

    var body: some View {
        Form {
            Section {
                Button("Reset to default position and size") {
                    model.resetGeometry()
                }
            } header: {
                Text("Surface")
            } footer: {
                Text("Returns the card to its original place and size. Takes effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
