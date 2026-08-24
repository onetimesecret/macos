import SwiftUI

/// The ledger: the audit trail, one line per event. Every record is
/// metadata and nothing else: what happened, to which item, under which
/// page title, how big it was, and where it went. There is no ink here,
/// no excerpt and no tombstone, so this view has no path that could
/// render content even if it wanted one (ADR-0012). It outlives the boot
/// session and is trimmed to a rolling 90 day window core-side; Esc
/// leaves (docs/spec/04).
public struct LedgerView: View {
    let entries: [LedgerEntry]

    public init(entries: [LedgerEntry]) {
        self.entries = entries
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if entries.isEmpty {
                    Text("The ledger has nothing to show yet.")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(entries) { entry in
                        LedgerRecord(entry: entry)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One record: a verb, the page's title as of that moment, the coarse
/// size bucket, the destination class, an absolute timestamp, and the
/// item's correlation handle.
private struct LedgerRecord: View {
    let entry: LedgerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.event)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(Self.stamp(entry.atMs))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                // The correlation handle an auditor lines records up by.
                // Eight characters is enough to read at a glance; the
                // full UUID is the accessibility value.
                Text(Self.shortItem(entry.item))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(entry.size)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if entry.destination != "none" {
                    Text("→ \(entry.destination)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(.quaternary)
        )
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(entry.item))
    }

    static func shortItem(_ item: String) -> String {
        String(item.prefix(8))
    }

    /// An absolute stamp, not a relative age. The ledger survives
    /// reboots, and "3h ago" on a record written before the machine was
    /// last switched off is simply false.
    static func stamp(_ atMs: UInt64) -> String {
        Self.formatter.string(from: Date(timeIntervalSince1970: Double(atMs) / 1000))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
