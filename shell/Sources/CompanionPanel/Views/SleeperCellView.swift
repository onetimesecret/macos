import SwiftUI

/// One SleeperCell: a draining ring (state over content), a cyclable
/// natural-time label, the masked recognition line, and a copy-out
/// affordance — the core moment (docs/spec/01). Fully operable from the
/// keyboard and legible to VoiceOver; the panel never takes focus.
struct SleeperCellView: View {
    let cell: CellSummary
    let onCopy: () -> Void
    let onCycle: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fraction of life remaining, for the ring. Clamped to [0, 1].
    private var fraction: Double {
        guard let rung = Rung(rawValue: cell.ttlCode), rung.seconds > 0 else { return 0 }
        return min(1, max(0, Double(cell.remainingMs) / 1000.0 / rung.seconds))
    }

    var body: some View {
        HStack(spacing: 10) {
            countdownRing
            VStack(alignment: .leading, spacing: 2) {
                Text(caption)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(cell.recognition)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            copyButton
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cellBackground))
        .contextMenu {
            Button("Copy back out", action: onCopy)
            Button("Extend (cycle TTL)", action: onCycle)
            Button("Dismiss now", role: .destructive, action: onDismiss)
        }
        // Speak the whole cell as one element: what it is, then how long
        // it has — in words, never colour or motion alone.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityValue(Text(cell.spokenRemaining))
    }

    /// "TEXT · 8h", plus the honest detection note when a heuristic
    /// matched ("looks like a GitHub token" — a hunch, not a certainty).
    private var caption: String {
        var parts = ["\(cell.kind.uppercased()) · \(cell.ttlLabel)"]
        if let detected = cell.detectedAs {
            parts.append("looks like a \(detected)")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        var description = "\(cell.kind) cell"
        if cell.concealed {
            description += ", concealed"
        }
        if let detected = cell.detectedAs {
            description += ", looks like a \(detected)"
        } else if !cell.concealed {
            description += ", \(cell.recognition)"
        }
        return description
    }

    private var countdownRing: some View {
        // The label ("8h") is the always-present text equivalent of the
        // ring, so the countdown never relies on colour or motion alone
        // (docs/spec/05 a11y). Reduce Motion degrades to a static ring.
        Button(action: onCycle) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.ember, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut, value: fraction)
                Text(cell.ttlLabel)
                    .font(.system(.caption2, design: .monospaced))
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Time to live"))
        .accessibilityValue(Text(cell.spokenRemaining))
        .accessibilityHint(Text("Activate to cycle the ladder and reset the clock"))
    }

    private var copyButton: some View {
        // Copy-out is the whole point: the core writes the pasteboard
        // itself; this button only asks.
        Button(action: onCopy) {
            Image(systemName: "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Copy back out"))
    }
}
