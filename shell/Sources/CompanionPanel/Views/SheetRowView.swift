import SwiftUI

/// One page in the transitional list: the tab's face — title, chip
/// count, the pausable countdown — until the rev C window gives pages
/// their real bottom-edge tabs and ink editor. Fully operable from the
/// keyboard and legible to VoiceOver; the panel never takes focus.
struct SheetRowView: View {
    let sheet: SheetSummary
    let onCycle: () -> Void
    let onPause: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            countdownRing
            VStack(alignment: .leading, spacing: 2) {
                Text(caption)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(sheet.title)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if sheet.paused {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Clock held"))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cellBackground))
        .contextMenu {
            Button("Cycle the countdown", action: onCycle)
            Button(sheet.paused ? "Top the hold up" : "Hold the clock", action: onPause)
            Button("Close page", role: .destructive, action: onClose)
        }
        // Double-click a tab holds its clock (docs/spec/04). On the
        // transitional row the whole row is the tab.
        .onTapGesture(count: 2, perform: onPause)
        // Speak the whole page as one element: what it is, then how long
        // it has — in words, never colour or motion alone.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityValue(Text(sheet.spokenRemaining))
    }

    /// "8h · 2 sealed", plus the hold state in words.
    private var caption: String {
        var parts = [sheet.rungLabel]
        if sheet.chipCount > 0 {
            parts.append("\(sheet.chipCount) sealed")
        }
        if sheet.paused {
            parts.append("held")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        var description = "page, \(sheet.title)"
        if sheet.chipCount > 0 {
            description += ", \(sheet.chipCount) sealed chip\(sheet.chipCount == 1 ? "" : "s")"
        }
        if sheet.paused {
            description += ", clock held"
        }
        return description
    }

    private var countdownRing: some View {
        // The label ("8h") is the always-present text equivalent of the
        // gauge, so the countdown never relies on colour or motion alone
        // (docs/spec/05 a11y). Reduce Motion degrades to a static ring;
        // a held clock draws dashed — state as geometry.
        Button(action: onCycle) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: sheet.fractionRemaining)
                    .stroke(
                        Color.ember,
                        style: StrokeStyle(
                            lineWidth: 3,
                            lineCap: .round,
                            dash: sheet.paused ? [3, 3] : []
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut, value: sheet.fractionRemaining)
                Text(sheet.remainingLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Countdown"))
        .accessibilityValue(Text(sheet.spokenRemaining))
        .accessibilityHint(Text("Activate to cycle the ladder and reset the clock"))
    }
}
