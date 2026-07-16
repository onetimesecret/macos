import AppKit
import SwiftUI

/// The surface's face: one card of ink at a comfortable reading measure
/// over the desktop, with the page's countdown and draining gauge. The
/// card dims to a glance while resting and becomes a plain editor while
/// raised; the ember border shows exactly while the surface holds the
/// keyboard, the same visual law as the panel.
struct BackdropRootView: View {
    @ObservedObject var model: BackdropModel
    @FocusState private var inkFocused: Bool

    private var raised: Bool { model.stance == .raised }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The raised window spans the screen, so without this a
            // click beside the card would be swallowed by our own
            // transparent pane. Clicking outside the card rests the
            // surface instead — the click's plain meaning. (While
            // resting the window ignores the mouse entirely, so the
            // gesture is unreachable there.)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if raised { model.rest() }
                }
            card
                .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(keyboardMap)
        .onChange(of: model.stance) { stance in
            // The raise made the window key (controller-side, before
            // this render); the editor takes first responder with it.
            inkFocused = stance == .raised
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let sheet = model.sheet {
                gauge(sheet)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            // The ember border: the surface holds the keyboard exactly
            // while raised — visible state, never colour alone (the
            // caret and focus ring agree).
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.ember.opacity(raised ? 0.8 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.ember).frame(width: 6, height: 6)
            Text("backdrop")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            if let sheet = model.sheet {
                countdownButton(sheet)
            }
        }
    }

    /// The countdown label: remaining time on the current rung; click
    /// cycles the ladder and resets the clock (docs/spec/04). Only
    /// reachable while raised — the resting window ignores the mouse.
    private func countdownButton(_ sheet: BackdropSheetSummary) -> some View {
        Button {
            model.cycleRung()
        } label: {
            HStack(spacing: 5) {
                if sheet.paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 8))
                        .accessibilityHidden(true)
                }
                Text(sheet.remainingLabel)
                    .font(.system(.caption, design: .monospaced))
                Text(sheet.rungLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(sheet.lastHour ? Color.ember : .secondary)
        }
        .buttonStyle(.plain)
        .help("Click to cycle the ladder and reset the clock")
        .accessibilityLabel(Text("Countdown"))
        .accessibilityValue(Text(sheet.spokenRemaining))
        .accessibilityHint(Text("Activate to cycle the ladder and reset the clock"))
    }

    /// The page's draining gauge, the resting surface's one honest
    /// motion (repainted at the stance's cadence, not animated).
    private func gauge(_ sheet: BackdropSheetSummary) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(sheet.lastHour ? Color.ember : Color.secondary)
                    .frame(width: max(0, geometry.size.width * sheet.fractionRemaining))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if raised {
            TextEditor(text: $model.ink)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($inkFocused)
                .frame(minHeight: 220)
                .onChange(of: model.ink) { text in
                    model.inkEdited(text)
                }
        } else if model.ink.isEmpty {
            // The empty state: a single calm line (docs/spec/03, tone).
            Text("empty — ⌃⌥Space raises the surface")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        } else {
            // The glance: the same ink at the same measure, dimmed —
            // promote and demote must not make the text jump.
            Text(model.ink)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        }
    }

    /// The window-level keyboard map, active exactly while the surface
    /// holds the keys (raised): Esc rests it, handing the keyboard back.
    private var keyboardMap: some View {
        Group {
            Button("") { model.rest() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// The ember accent (#d45a2a) — the same single accent the panel
    /// uses; duplicated here because form factors are separate targets
    /// (ADR-0010).
    static let ember = Color(red: 0.831, green: 0.353, blue: 0.165)
}
