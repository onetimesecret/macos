import SwiftUI

/// One SleeperCell: a draining ring (the star — state over content), a cyclable
/// natural-time label, a redacted preview, and a subtle share CTA (docs/00
/// §6.2). Fully operable from the keyboard and legible to VoiceOver.
struct SleeperCellView: View {
    let cell: CellSummary
    let onCycle: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fraction of life remaining, for the ring. Clamped to [0, 1].
    private var fraction: Double {
        guard let rung = Rung(apiString: cell.rung), rung.seconds > 0 else { return 0 }
        return min(1, max(0, Double(cell.remainingMs) / 1000.0 / rung.seconds))
    }

    var body: some View {
        HStack(spacing: 10) {
            countdownRing
            VStack(alignment: .leading, spacing: 2) {
                Text("\(cell.kind.uppercased()) · \(cell.rungLabel)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(cell.preview)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            shareButton
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cellBackground))
        .contextMenu {
            Button("Extend (cycle TTL)", action: onCycle)
            Button("Dismiss now", role: .destructive, action: onDismiss)
        }
        // Speak the whole cell as one element: what it is, then how long it has.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(cell.kind) cell, \(cell.preview)"))
        .accessibilityValue(Text(cell.remainingLabel))
    }

    private var countdownRing: some View {
        // The label (`3h`) is the always-present text equivalent of the ring, so
        // the countdown never relies on colour or motion alone (docs/00 §8).
        // Reduce Motion degrades to a static ring.
        Button(action: onCycle) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.flame, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut, value: fraction)
                Text(cell.rungLabel)
                    .font(.system(.caption2, design: .monospaced))
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Time to live"))
        .accessibilityValue(Text(cell.remainingLabel))
        .accessibilityHint(Text("Activate to extend"))
    }

    private var shareButton: some View {
        // A subtle bridge to a one-time link — present, quiet, never competing
        // (docs/00 §6.2). Wired to conceal in the share-bridge milestone.
        Button(action: {}) {
            Image(systemName: "arrow.up.forward")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Share as a one-time link"))
    }
}
