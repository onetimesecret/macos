import AppKit
import ServiceManagement
import SwiftUI

/// Settings — one small window (docs/spec/04), Connection first: server
/// URL, org extid + API token, share domain, and a test button. Unlike
/// the main window this one activates normally: opening Settings is a
/// deliberate act, and its fields need the keyboard.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: WindowModel

    init(model: WindowModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosted = NSHostingController(rootView: ConnectionSettingsView(model: model))
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

/// Launch at login, through `SMAppService.mainApp` (macOS 13+). The
/// registration belongs to exactly one bundle: the installed copy in
/// /Applications. A dev build running from .build/ or dist/ must never
/// claim the login item, or login would resurrect whichever build ran
/// Settings last.
enum LaunchAtLogin {
    /// The guard, as a pure decision on the bundle's path so the rule
    /// is testable without a bundle: only a copy installed under
    /// /Applications may register.
    nonisolated static func pathMayRegister(_ bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Applications/")
    }

    static var mayRegister: Bool {
        pathMayRegister(Bundle.main.bundleURL.path)
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration can land in `.requiresApproval`: macOS holds the
    /// item disabled until the user approves it in System Settings.
    static var awaitingApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Connection settings. The token field is write-only by design: what
/// is stored can never be read back out of the Keychain into this UI —
/// the placeholder just says one is held.
struct ConnectionSettingsView: View {
    @ObservedObject var model: WindowModel

    @State private var serverUrl = ""
    @State private var extid = ""
    @State private var token = ""
    @State private var shareDomain = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var testing = false
    @State private var confirmingClear = false
    @State private var launchAtLogin = false
    @State private var loginStatus: String?

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $serverUrl, prompt: Text("https://eu.onetimesecret.com"))
                TextField("Share domain", text: $shareDomain, prompt: Text("optional — defaults to the server's host"))
            } header: {
                Text("Where promotion goes — the app's one outbound destination, https only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Organization extid", text: $extid, prompt: Text("empty for guest promotion"))
                SecureField("API token", text: $token, prompt: Text(tokenPrompt))
                if model.connection?.hasToken == true {
                    Button("Clear stored token", role: .destructive) { confirmingClear = true }
                        .confirmationDialog(
                            "Clear the stored API token?",
                            isPresented: $confirmingClear,
                            titleVisibility: .visible
                        ) {
                            Button("Clear token", role: .destructive) { clearToken() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Promotion falls back to guest links until you enter a new token.")
                        }
                }
            } header: {
                Text("The token goes straight to the Keychain and is never shown again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Start at login", isOn: loginBinding)
                    .disabled(!LaunchAtLogin.mayRegister)
                if let loginStatus {
                    Text(loginStatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.ember)
                }
            } header: {
                Text(loginCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if DEBUG
            Section {
                Toggle("Allow screenshots of the window", isOn: $model.allowCapture)
            } header: {
                Text("Debug build only: lifts the screen-capture exclusion until the app quits. A release build has no such switch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
            HStack {
                Button("Test") { test() }
                    .disabled(testing)
                if testing {
                    ProgressView().controlSize(.small)
                }
                if let status {
                    Text(status)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(statusIsError ? Color.ember : Color.secondary)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .onAppear(perform: load)
    }

    private var tokenPrompt: String {
        (model.connection?.hasToken ?? false) ? "•••• stored in the Keychain" : "paste your API token"
    }

    /// The toggle speaks to `SMAppService` directly; a refused
    /// registration reverts the switch to the system's actual state
    /// rather than showing a wish as a fact.
    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wanted in
                do {
                    try LaunchAtLogin.set(enabled: wanted)
                    launchAtLogin = wanted
                    loginStatus = wanted && LaunchAtLogin.awaitingApproval
                        ? "waiting for approval under System Settings, Login Items"
                        : nil
                } catch {
                    launchAtLogin = LaunchAtLogin.isEnabled
                    loginStatus = "macOS refused: \(error.localizedDescription)"
                }
            }
        )
    }

    private var loginCaption: String {
        LaunchAtLogin.mayRegister
            ? "Brings the menu-bar presence back when you log in."
            : "Only the installed copy in /Applications can register at login, so a dev build never claims the login item."
    }

    private func load() {
        launchAtLogin = LaunchAtLogin.isEnabled
        guard let connection = model.connection else { return }
        serverUrl = connection.serverUrl
        extid = connection.extid
        shareDomain = connection.shareDomain
    }

    private func save() {
        // An untouched token field keeps the stored token (nil through
        // the seam); typed text replaces it. Deleting is explicit:
        // clear the extid and the token is unused either way.
        let accepted = model.saveConnection(
            serverUrl: serverUrl.trimmingCharacters(in: .whitespaces),
            shareDomain: shareDomain.trimmingCharacters(in: .whitespaces),
            extid: extid.trimmingCharacters(in: .whitespaces),
            token: token.isEmpty ? nil : token
        )
        token = ""
        statusIsError = !accepted
        status = accepted ? "saved" : "refused — the server URL must be https://…"
    }

    private func clearToken() {
        let cleared = model.clearToken()
        token = ""
        statusIsError = !cleared
        status = cleared ? "token cleared" : "could not clear the token"
    }

    private func test() {
        save()
        guard !statusIsError else { return }
        testing = true
        status = nil
        model.testConnection { outcome in
            testing = false
            statusIsError = !outcome.ok
            status = outcome.ok ? "the server answers" : (outcome.error ?? "test failed")
        }
    }
}
