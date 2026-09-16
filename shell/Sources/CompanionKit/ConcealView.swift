import SwiftUI

/// The conceal confirmation, inline and in place (docs/spec/04 — not
/// a modal): destination, TTL starting at the link's own seven-day
/// default (ADR-0011 section 5, never the page's remaining time per
/// ADR-0026), optional passphrase and recipient, one confirming click.
/// The network
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

    /// The link's TTL choices as (seconds, label). The values coincide
    /// with the page ladder's rungs, but the link default is not a rung
    /// of any ladder (ADR-0011 section 5; `ConcealDraft.defaultTtlSecs`):
    /// a link's lifetime is its own, never the page's (ADR-0026).
    private static let linkTtlChoices: [(secs: UInt64, label: String)] = [
        (3600, "1 hour"), (10800, "3 hours"), (28800, "8 hours"),
        (86400, "24 hours"), (259_200, "3 days"), (604_800, "7 days"),
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let sealed = sealedItemsLine {
                Text(sealed)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
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
                .help("The server this conceal goes to")
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

    /// The confirmation's second line on a page target: a page travels
    /// with its sealed payloads, that being the product (D-09), so the
    /// sheet says how many are going. Nil on a chip target, where the
    /// title already names the one item, and nil at zero, where there
    /// is nothing to announce.
    private var sealedItemsLine: String? {
        guard case .page(let id) = draft.target else { return nil }
        return Self.sealedItemsLine(count: Self.sealedItemCount(ofPage: id, in: model.tabs))
    }

    /// The sentence for a count of sealed items, or nil when there are
    /// none. Pure, so the singular and the plural are assertions rather
    /// than a thing read off a screen.
    nonisolated static func sealedItemsLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "includes 1 sealed item" : "includes \(count) sealed items"
    }

    /// How many sealed items a page carries, read from the roster the
    /// model already decoded rather than asked of the core again. A
    /// page the roster no longer holds counts as carrying none, which
    /// is the fail closed reading: the sheet then says nothing rather
    /// than something it cannot stand behind.
    nonisolated static func sealedItemCount(ofPage id: UInt64, in tabs: [TabSummary]) -> Int {
        Int(tabs.first { $0.pageID == id }?.chipCount ?? 0)
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
                    ForEach(Self.linkTtlChoices, id: \.secs) { rung in
                        Text(rung.label).tag(rung.secs)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 110)
                Text("· defaults to the link's own 7 days; the page's clock is not an input")
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
                    .foregroundStyle(Color.emberText)
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
        case .chip: "the content travelled · remove the chip; its bytes are zeroized"
        case .page: "the page travelled · close it; it rests in the ledger"
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
