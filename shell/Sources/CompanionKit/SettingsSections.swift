import AppKit
import ServiceManagement
import SwiftUI

/// Launch at login, through `SMAppService.mainApp` (macOS 13+). The
/// registration belongs to exactly one bundle: the installed copy in
/// /Applications. A dev build running from .build/ or dist/ must never
/// claim the login item, or login would resurrect whichever build ran
/// Settings last.
///
/// `SMAppService.mainApp` is per-bundle by construction, so the two form
/// factors register and unregister independently even though they share
/// this code — each one's `mainApp` is its own bundle.
public enum LaunchAtLogin {
    /// The guard, as a pure decision on the bundle's path so the rule
    /// is testable without a bundle: only a copy installed under
    /// /Applications may register.
    public nonisolated static func pathMayRegister(_ bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Applications/")
    }

    public static var mayRegister: Bool {
        pathMayRegister(Bundle.main.bundleURL.path)
    }

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration can land in `.requiresApproval`: macOS holds the
    /// item disabled until the user approves it in System Settings.
    public static var awaitingApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public static func set(enabled: Bool) throws {
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
///
/// Shared by both form factors, which reach their own Keychain service
/// through their own model: the same form, two stores.
public struct ConnectionSettingsView: View {
    @ObservedObject var model: PageModel

    /// What the login toggle's caption promises to bring back. The
    /// panel's presence is a menu-bar item; the backdrop's is the
    /// surface itself.
    private let loginPresence: String

    /// Whether the capture opt-out is offered here. Debug builds only,
    /// and only where the surrounding target actually honours it.
    private let offersCaptureToggle: Bool

    public init(model: PageModel, loginPresence: String, offersCaptureToggle: Bool = true) {
        self.model = model
        self.loginPresence = loginPresence
        self.offersCaptureToggle = offersCaptureToggle
    }

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

    public var body: some View {
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
            if offersCaptureToggle {
                Section {
                    Toggle("Allow screenshots of the surface", isOn: $model.allowCapture)
                } header: {
                    Text("Debug build only: lifts the screen-capture exclusion until the app quits. A release build has no such switch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            ? "Brings \(loginPresence) back when you log in."
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
