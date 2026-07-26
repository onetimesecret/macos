import AppKit
import CompanionKit
import SwiftUI

/// Settings — one small window (docs/spec/04), Connection first: server
/// URL, org extid + API token, share domain, and a test button. The
/// form itself is shared (`ConnectionSettingsView`); what belongs to the
/// panel is the window around it. Unlike the main window this one
/// activates normally: opening Settings is a deliberate act, and its
/// fields need the keyboard.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: PageModel

    init(model: PageModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosted = NSHostingController(
                rootView: ConnectionSettingsView(
                    model: model,
                    loginPresence: "the menu-bar presence"
                )
            )
            // The window owns its size; without this the hosting
            // controller re-imposes the view's preferred height and
            // fights the user's vertical resize.
            hosted.sizingOptions = []
            let window = NSWindow(contentViewController: hosted)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 420, height: 360))
            // Vertical resize only: the form is built for one width.
            window.contentMinSize = NSSize(width: 420, height: 300)
            window.contentMaxSize = NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude)
            window.center()
            self.window = window
        }
        // The panel floats at .statusBar while pinned (the default);
        // a .normal-level Settings window would open key yet invisible
        // beneath it — level beats key status for stacking. Match the
        // panel's level so ordering front actually reveals it.
        window?.level = model.floatsOnTop ? .statusBar : .normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
