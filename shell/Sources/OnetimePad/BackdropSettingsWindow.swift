import AppKit
import Combine
import CompanionKit
import SwiftUI

/// The tabs of the Settings window, in toolbar order. General first,
/// as every Apple app has it, then code presentation, followed by the
/// two that reach outside the Mac: where a conceal goes, and how pages travel.
///
/// The symbol names are SF Symbols. A misspelt one draws nothing and
/// complains nowhere, so `SettingsTabTests` resolves each of them.
enum SettingsTab: Int, CaseIterable {
    case general
    case code
    case connection
    case sync

    var label: String {
        switch self {
        case .general: "General"
        case .code: "Code"
        case .connection: "Connection"
        case .sync: "Sync"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .code: "curlybraces"
        case .connection: "network"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }

    /// The tab's place in the toolbar, which is also its index in the
    /// tab view controller: the raw value, since the cases are declared
    /// in toolbar order.
    var index: Int { rawValue }

    /// Which tab a `show()` lands on. The window keeps whichever tab
    /// was open last, as Settings windows do, with one exception: the
    /// surface's banner for a ledger that will not open sends the user
    /// here to clear it, and the clear lives on General. Opening on
    /// any other tab would turn that instruction into a search.
    static func landing(current: SettingsTab, ledgerRestoreRefused: Bool) -> SettingsTab {
        ledgerRestoreRefused ? .general : current
    }
}

/// Settings, backdrop edition: a standard macOS Settings window, its
/// tabs along the top as a toolbar, hosting the shared forms.
/// Unlike the backdrop itself this window activates normally: opening
/// Settings is a deliberate act, and its fields need the keyboard.
///
/// The forms are shared, the stores are not: this window's model
/// reaches the backdrop's own Keychain service, so a token saved here
/// is the backdrop's and never the panel's (ADR-0010).
@MainActor
final class BackdropSettingsWindowController: NSObject {
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private let model: BackdropModel

    /// One width for every tab: the forms are built for it, and a
    /// Settings window that changed width between tabs would look like
    /// several windows taking turns.
    private static let width: CGFloat = 480

    /// Each tab's height, fixed, so the window animates between them
    /// rather than opening at whatever height the last form left. The
    /// figures come from the forms as written: a grouped row is about
    /// 44pt with its padding, a caption line about 15pt, and a section
    /// adds roughly 16pt of air. General carries the long captions, the
    /// two type rows and so the most height; Connection is two short
    /// sections and a button row; Sync is sized for the switch, the
    /// sign-in line and a small device roster. A form that grows past
    /// its figure, such as General when the ledger clear or the capture
    /// switch appears, scrolls rather than pushing the window around.
    private static func height(of tab: SettingsTab) -> CGFloat {
        switch tab {
        case .general: 700
        case .code: 390
        case .connection: 360
        case .sync: 380
        }
    }

    /// Keeps the Settings window's level in step with the surface while
    /// it is open, and lets go when it closes. The same type follows
    /// About (`CompanionLevelFollower`).
    private let levelFollower: CompanionLevelFollower

    init(model: BackdropModel) {
        self.model = model
        levelFollower = CompanionLevelFollower(model: model)
        super.init()
    }

    /// Whether a window is the Settings window. The About lookup asks,
    /// so that it can never take this window for AppKit's panel.
    func owns(_ candidate: NSWindow) -> Bool {
        window === candidate
    }

    func show() {
        if window == nil {
            let tabs = makeTabs()
            let window = NSWindow(contentViewController: tabs)
            // The title stands only until a tab is selected; from then
            // on the toolbar tab style takes it from the selected item
            // (`makeTabs`).
            window.title = "Settings"
            // Titled and closable only. Each tab has the size it
            // needs and the window takes that size as the tab changes;
            // a resize handle would only let the user break that. The
            // minimise button goes too, deliberately: a Settings window
            /// with short tabs is closed and reopened, and a
            // minimised one would only hide the tab a refused ledger
            // sends the user to (`SettingsTab.landing`).
            window.styleMask = [.titled, .closable]
            // The preference style is what puts the tabs under the
            // title as icons with labels, the way System Settings and
            // every Apple app's Settings window draws them.
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
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
            self.tabs = tabs
        }
        if let tabs {
            let current = SettingsTab(rawValue: tabs.selectedTabViewItemIndex) ?? .general
            tabs.selectedTabViewItemIndex = SettingsTab.landing(
                current: current,
                ledgerRestoreRefused: model.pages.ledgerRestoreRefused
            ).index
        }
        // A raised card floats above normal windows, and so does a
        // pinned resting one; a .normal-level Settings window would
        // open key yet invisible beneath it, since level beats key
        // status for stacking. The altitude comes from
        // `BackdropAltitude.keylessAltitude` read as a companion level
        // (ADR-0032, #188): Settings has no key status of its own to
        // feed the resolver, so it reads the surface's keyless answer
        // and maps desktop to normal (a titled window at desktop level
        // could resolve behind the wallpaper as easily as the surface
        // can). The follower writes it now and on every published
        // change while the window is up, so a pin or a keep above
        // switch flipped inside Settings moves the window at the moment
        // the switch does.
        if let window {
            levelFollower.follow(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The tab view controller in its toolbar style, which is the whole
    /// of the standard Settings look: the tabs become toolbar items,
    /// the selected tab's title becomes the window's, and the window
    /// is resized to each tab's `preferredContentSize` as the selection
    /// moves.
    private func makeTabs() -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            tabs.addTabViewItem(makeItem(for: tab))
        }
        return tabs
    }

    private func makeItem(for tab: SettingsTab) -> NSTabViewItem {
        let hosted: NSViewController
        switch tab {
        case .general:
            hosted = host(
                GeneralSettingsView(
                    model: model.pages,
                    loginPresence: "the surface",
                    resetSurface: { [model] in model.resetGeometry() },
                    keepsAbove: Binding(
                        get: { [model] in model.keepsAboveWhenInactive },
                        set: { [model] in model.keepsAboveWhenInactive = $0 }
                    ),
                    ambientPanelEnabled: Binding(
                        get: { [model] in model.ambientPanelEnabled },
                        set: { [model] in model.ambientPanelEnabled = $0 }
                    )
                ),
                for: tab
            )
        case .code:
            hosted = host(CodeSettingsView(model: model.pages), for: tab)
        case .connection:
            hosted = host(ConnectionSettingsView(model: model.pages), for: tab)
        case .sync:
            hosted = host(SyncSettingsView(sync: model.pages.sync), for: tab)
        }
        hosted.title = tab.label
        let item = NSTabViewItem(viewController: hosted)
        item.label = tab.label
        item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.label)
        return item
    }

    /// One tab's hosting controller. The tab owns its size; without
    /// clearing `sizingOptions` the hosting controller would re-impose
    /// the form's own preferred height, which for a grouped form is
    /// whatever its scroll view feels like, and fight the figure the
    /// tab was given.
    private func host<Content: View>(_ view: Content, for tab: SettingsTab) -> NSViewController {
        let hosted = NSHostingController(rootView: view)
        hosted.sizingOptions = []
        hosted.preferredContentSize = NSSize(width: Self.width, height: Self.height(of: tab))
        return hosted
    }
}
