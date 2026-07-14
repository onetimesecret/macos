import AppKit
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
            let window = NSWindow(contentViewController: hosted)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 420, height: 260))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
            } header: {
                Text("The token goes straight to the Keychain and is never shown again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        .onAppear(perform: load)
    }

    private var tokenPrompt: String {
        (model.connection?.hasToken ?? false) ? "•••• stored in the Keychain" : "paste your API token"
    }

    private func load() {
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
