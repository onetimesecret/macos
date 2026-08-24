import AppKit
import CompanionKit
import SwiftUI

/// Settings, backdrop edition: one small window holding the same
/// Connection form the panel shows plus the surface's own section.
/// Unlike the backdrop itself this window activates normally: opening
/// Settings is a deliberate act, and its fields need the keyboard.
///
/// The form is shared, the stores are not: this window's model reaches
/// the backdrop's own Keychain service, so a token saved here is the
/// backdrop's and never the panel's (ADR-0010).
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
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 420, height: 440))
            // Vertical resize only: the form is built for one width.
            window.contentMinSize = NSSize(width: 420, height: 320)
            window.contentMaxSize = NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude)
            // The window is built once and shown many times, so without
            // this it would keep the Space it was first opened on and
            // every later ⌘, would carry the user there instead of
            // opening here. It is one of the app's two ordinary windows,
            // About being the other, and both can pull an activation
            // onto another desktop now that the surface itself claims
            // all of them (issue #74); About takes the same bit where it
            // is shown.
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.center()
            self.window = window
        }
        // A raised card floats above normal windows, and so does a
        // pinned resting one; a .normal-level Settings window would
        // open key yet invisible beneath it, since level beats key
        // status for stacking. Match the card's current level so
        // ordering front actually reveals it.
        window?.level = model.stance == .raised || model.pinned ? .floating : .normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The backdrop's Settings: the shared Connection form, and above it
/// the one setting only this form factor has: where the card sits.
struct BackdropSettingsView: View {
    @ObservedObject var model: BackdropModel

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(height: 120)
            ConnectionSettingsView(
                model: model.pages,
                loginPresence: "the surface"
            )
        }
        .frame(width: 420)
    }
}
