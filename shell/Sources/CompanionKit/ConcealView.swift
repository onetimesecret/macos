import SwiftUI

/// The conceal confirmation, inline and in place (docs/spec/04 — not
/// a modal): destination, TTL seeded from the page's remaining time,
/// optional passphrase and recipient, one confirming click. The network
/// boundary is explicit — nothing leaves until "Create link". Failure
/// is inline with retry; success says the link is on the clipboard and
/// offers Burn local copy.
public struct ConcealView: View {
    @ObservedObject var model: PageModel
    let draft: ConcealDraft

    public init(model: PageModel, draft: ConcealDraft) {
        self.model = model
        self.draft = draft
    }

    /// The ladder as (seconds, label) — the same rungs the countdown
    /// speaks (docs/spec/04).
    private static let ladder: [(secs: UInt64, label: String)] = [
        (3600, "1 hour"), (10800, "3 hours"), (28800, "8 hours"),
        (86400, "24 hours"), (259_200, "3 days"), (604_800, "7 days"),
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if draft.receiptId != nil {
                success
            } else {
                form
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cellBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.ember.opacity(0.5), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
            Text(destination)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help("The app's one outbound destination")
            Button {
                model.dismissConceal()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Dismiss"))
        }
    }

    private var title: String {
        switch draft.target {
        case .chip: "conceal this sealed content into a one-time link"
        case .page: "conceal this page into a one-time link"
        }
    }

    /// Where the request goes and as whom — the explicit boundary line.
    private var destination: String {
        guard let connection = model.connection, connection.configured else {
            return "no server configured"
        }
        let host = connection.serverUrl.replacingOccurrences(of: "https://", with: "")
        let who = connection.hasToken && !connection.extid.isEmpty ? connection.extid : "guest"
        return "\(host) · \(who)"
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("link lives")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Picker("Link time to live", selection: ttlBinding) {
                    ForEach(Self.ladder, id: \.secs) { rung in
                        Text(rung.label).tag(rung.secs)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 110)
                Text("· seeded from the page's clock, snapped down")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                SecureField("passphrase (optional)", text: fieldBinding(\.passphrase))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                TextField("recipient email (optional)", text: fieldBinding(\.recipient))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 190)
            }
            if let error = draft.error {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ember)
                    .accessibilityLabel(Text("Conceal failed: \(error)"))
            }
            HStack {
                if !isConfigured {
                    Text("guest route — add an account in Settings → Connection")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if draft.inFlight {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Sending"))
                }
                Button(draft.error == nil ? "Create link" : "Retry") {
                    model.confirmConceal()
                }
                .controlSize(.small)
                .disabled(draft.inFlight)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var isConfigured: Bool {
        (model.connection?.hasToken ?? false) && !(model.connection?.extid.isEmpty ?? true)
    }

    private var success: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("the link is on the clipboard — paste it where it needs to go")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
            Button("Burn local copy") { model.burnConcealedCopy() }
                .controlSize(.small)
                .help(burnHelp)
            Button("Keep it") { model.dismissConceal() }
                .controlSize(.small)
        }
    }

    private var burnHelp: String {
        switch draft.target {
        case .chip: "The content travelled — remove the chip; its bytes are zeroized"
        case .page: "The page travelled — close it; it rests in the ledger"
        }
    }

    // MARK: Bindings into the draft held by the model

    private var ttlBinding: Binding<UInt64> {
        Binding(
            get: { model.concealDraft?.ttlSecs ?? draft.ttlSecs },
            set: { model.concealDraft?.ttlSecs = $0 }
        )
    }

    private func fieldBinding(_ path: WritableKeyPath<ConcealDraft, String>) -> Binding<String> {
        Binding(
            get: { model.concealDraft?[keyPath: path] ?? "" },
            set: { model.concealDraft?[keyPath: path] = $0 }
        )
    }
}
