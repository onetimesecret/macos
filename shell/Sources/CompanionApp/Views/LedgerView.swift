import CompanionKit
import SwiftUI

/// The ledger (⌘0): dead pages as dimmed, read-only ink — records, not
/// pages. A chip appears only as its excerpt, struck through and
/// labelled "zeroized"; the sealed bytes died with the page. Session-
/// bound, capacity a dozen; Esc leaves (docs/spec/04).
struct LedgerView: View {
    let entries: [LedgerEntry]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if entries.isEmpty {
                    Text("Nothing has died yet.")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        LedgerRecord(entry: entry)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LedgerRecord: View {
    let entry: LedgerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(entry.cause) · \(Self.age(entry.ageMs))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            // The runs as one flowing text: dimmed ink, struck
            // tombstones. Copy of visible ink is allowed — it was never
            // secret; the tombstone's excerpt always rendered.
            body(of: entry)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(.quaternary)
        )
        .accessibilityElement(children: .combine)
    }

    private func body(of entry: LedgerEntry) -> Text {
        entry.runs.reduce(Text("")) { text, run in
            switch run {
            case .ink(let ink):
                text + Text(ink).foregroundColor(.secondary)
            case .tombstone(let excerpt):
                text
                    + Text(excerpt).strikethrough().foregroundColor(.secondary)
                    + Text(" zeroized").foregroundColor(Color.ember.opacity(0.8))
            }
        }
    }

    static func age(_ ms: UInt64) -> String {
        let seconds = ms / 1000
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }
}
