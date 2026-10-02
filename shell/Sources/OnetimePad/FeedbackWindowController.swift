import AppKit
import CompanionKit
import SwiftUI
import UniformTypeIdentifiers

/// A draft and a reviewed diagnostics snapshot live together until Send succeeds.
@MainActor
final class FeedbackDraft: ObservableObject {
    @Published var message = ""
    @Published var contact = ""
    @Published var includeDiagnostics = true
    @Published private(set) var report: DiagnosticsReport
    @Published private(set) var sending = false
    @Published private(set) var sent = false
    @Published private(set) var error: String?

    @Published private(set) var serverURL: String
    private let serverURLProvider: () -> String
    private let makeReport: () -> DiagnosticsReport
    private let submit: @MainActor (String, String, String?) async throws -> Void

    init(
        serverURL: @escaping () -> String,
        makeReport: @escaping () -> DiagnosticsReport,
        submit: @escaping @MainActor (String, String, String?) async throws -> Void = { server, message, contact in
            try await FeedbackClient(serverURL: server).send(message: message, contact: contact)
        }
    ) {
        self.serverURLProvider = serverURL
        self.serverURL = serverURL()
        self.makeReport = makeReport
        self.submit = submit
        report = makeReport()
    }

    var destination: String {
        FeedbackClient(serverURL: serverURL).endpointURL?.absoluteString ?? "Invalid server URL — update Connection settings."
    }

    func refreshDestination() {
        guard !sending && !sent else { return }
        serverURL = serverURLProvider()
    }

    var canSend: Bool {
        !sending && !sent && (includeDiagnostics || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var submittedMessage: String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard includeDiagnostics else { return text }
        return [text, "OnetimePad diagnostics\n\(report.details)"]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func refreshDiagnostics() { report = makeReport() }

    func startAnother() {
        message = ""
        contact = ""
        error = nil
        sent = false
        refreshDestination()
        refreshDiagnostics()
    }

    @discardableResult
    func send() -> Task<Void, Never>? {
        guard canSend else { return nil }
        // Capture exactly the snapshot and fields the person reviewed.
        let targetServer = serverURL
        let submitted = submittedMessage
        let replyContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        error = nil
        return Task {
            do {
                try await submit(targetServer, submitted, replyContact.isEmpty ? nil : replyContact)
                sent = true
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

@MainActor
final class FeedbackWindowController: NSObject {
    private var window: NSWindow?
    private var draft: FeedbackDraft?
    private let levelFollower: CompanionLevelFollower
    private let serverURL: () -> String
    private let makeReport: () -> DiagnosticsReport

    init(model: BackdropModel, makeReport: @escaping () -> DiagnosticsReport) {
        serverURL = { [weak model] in model?.pages.connection?.serverUrl ?? "https://eu.onetimesecret.com" }
        self.makeReport = makeReport
        levelFollower = CompanionLevelFollower(model: model)
        super.init()
    }

    func show() {
        if window == nil {
            let draft = FeedbackDraft(serverURL: serverURL, makeReport: makeReport)
            self.draft = draft
            let view = FeedbackView(
                draft: draft,
                close: { [weak self] in self?.window?.close() },
                export: { [weak self] report, completion in
                    guard let window = self?.window else { completion(false); return }
                    DiagnosticsActions.export(report, attachedTo: window, completion: completion)
                }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Send Feedback"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            // No saved application state: restoration would write a
            // snapshot of the window, draft included, under
            // ~/Library/Saved Application State. `sharingType` stays at
            // its default, as Settings and About leave it: the capture
            // exclusion covers the surfaces that hold ink, not this one.
            window.isRestorable = false
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.setContentSize(NSSize(width: 560, height: 630))
            window.contentMinSize = NSSize(width: 480, height: 540)
            window.center()
            self.window = window
        }
        draft?.refreshDestination()
        if let window { levelFollower.follow(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private struct FeedbackView: View {
    @ObservedObject var draft: FeedbackDraft
    let close: () -> Void
    let export: (DiagnosticsReport, @escaping (Bool) -> Void) -> Void
    @State private var exportResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if draft.sent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(.green)
                Text("Feedback sent").font(.title2.bold())
                Text("Thank you. Your feedback was received by \(draft.destination).")
                    .textSelection(.enabled)
                Spacer()
                HStack {
                    Button("New Feedback") { draft.startAnother() }
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Send Feedback").font(.title2.bold())
                        Text("Describe what happened and what you expected.").foregroundStyle(.secondary)
                        Text("Send to: \(draft.destination)\nTime zone: \(TimeZone.current.identifier)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        TextField("Contact (optional)", text: $draft.contact,
                                  prompt: Text("Email or another way to reach you"))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Message (optional when including diagnostics)").font(.headline)
                            TextEditor(text: $draft.message)
                                .font(.body)
                                .frame(minHeight: 90, idealHeight: 110)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                                .accessibilityLabel("Feedback message")
                        }
                        Toggle("Include diagnostics", isOn: $draft.includeDiagnostics)
                        Text("Review the snapshot below. Your message, contact, time zone and selected diagnostics are submitted when you choose Send.")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            Text(draft.report.details)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 120, idealHeight: 180)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityLabel("Diagnostics preview")
                        HStack {
                            Button("Refresh") { draft.refreshDiagnostics() }
                            Button("Copy Summary") { DiagnosticsActions.copySummary(draft.report) }
                            Button("Export…") {
                                export(draft.report) { exported in
                                    exportResult = exported ? "Diagnostics exported." : nil
                                }
                            }
                        }
                        if let exportResult {
                            Text(exportResult).font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = draft.error {
                            Text("Could not confirm feedback was received: \(error)")
                                .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                            Text("Your draft is still here. A retry may send a duplicate if the earlier request arrived. You can also export diagnostics to share separately.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Close", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    if draft.sending {
                        ProgressView().controlSize(.small)
                        Text("Sending…").foregroundStyle(.secondary)
                    }
                    Button(draft.error == nil ? "Send" : "Try Again") { draft.send() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.canSend)
                }
            }
        }
        .padding(22)
        .disabled(draft.sending)
    }
}

@MainActor
enum DiagnosticsActions {
    static func copySummary(_ report: DiagnosticsReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.summary, forType: .string)
    }

    static func export(
        _ report: DiagnosticsReport, attachedTo window: NSWindow,
        completion: @escaping (Bool) -> Void
    ) {
        let panel = savePanel()
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { completion(false); return }
                do {
                    try report.details.write(to: url, atomically: true, encoding: .utf8)
                    completion(true)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Could not export diagnostics"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window)
                    completion(false)
                }
            }
        }
    }

    private static func savePanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = "OnetimePad-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        return panel
    }

    @discardableResult
    static func export(_ report: DiagnosticsReport) -> Bool {
        let panel = savePanel()
        guard ModalSession.run({ panel.runModal() }) == .OK, let url = panel.url else { return false }
        do {
            try report.details.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not export diagnostics"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            ModalSession.run { alert.runModal() }
            return false
        }
    }
}
