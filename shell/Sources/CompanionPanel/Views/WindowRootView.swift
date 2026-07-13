import SwiftUI

/// The window's face (docs/spec/04): a quiet header where the title bar
/// is, one page of ink and chips (or the ledger), the page's draining
/// gauge, and the bottom-edge tab strip. An ember border shows exactly
/// while the page holds the keyboard.
struct WindowRootView: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .frame(height: 34)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = model.notice {
                Text(notice)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ember)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let sheet = model.selectedSheet, !model.showingLedger {
                // The page's bottom edge drains continuously.
                GaugeBar(
                    fraction: sheet.fractionRemaining,
                    paused: sheet.paused,
                    lastHour: sheet.lastHour
                )
                .frame(height: 4)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            }
            Divider()
            TabStripView(model: model)
        }
        .background(Color.panelBackground)
        .overlay(
            // The ember border: the page holds the keyboard — visible
            // state, never colour alone (the caret and focus ring agree).
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.ember.opacity(model.holdsKeys ? 0.8 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .background(keyboardMap)
        // The 1 Hz countdown redraw runs only while the window is on
        // screen (docs/spec/05 frugality budget).
        .onAppear { model.startRedraw() }
        .onDisappear { model.stopRedraw() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.ember).frame(width: 6, height: 6)
            Text(model.showingLedger ? "the ledger" : "Airlock")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if let sheet = model.selectedSheet, !model.showingLedger {
                countdownButton(sheet)
            }
            pinToggle
        }
    }

    /// The countdown label: remaining time on the current rung; click
    /// cycles the ladder and resets the clock (docs/spec/04).
    private func countdownButton(_ sheet: SheetSummary) -> some View {
        Button {
            model.cycleRung(sheet.id)
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

    /// Float-on-top setting. A real `Toggle` so VoiceOver announces a
    /// switch with on/off state; the window level follows it.
    private var pinToggle: some View {
        Toggle(isOn: $model.floatsOnTop) {
            Image(systemName: model.floatsOnTop ? "pin.fill" : "pin")
                .font(.system(size: 9))
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(model.floatsOnTop
            ? "Floating above other windows — click to let them cover it"
            : "Behaves like a normal window — click to keep it on top")
        .accessibilityLabel(Text("Keep window above other windows"))
    }

    @ViewBuilder
    private var content: some View {
        if model.showingLedger {
            LedgerView(entries: model.ledgerEntries)
        } else if let selection = model.selection {
            InkEditorView(model: model, sheetID: selection)
                .id(selection) // storage swap keyed on the page
        } else {
            VStack(spacing: 6) {
                Text("Empty is the resting state.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("⌥⌘N for a page")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The window-level keyboard map (docs/spec/04), carried by
    /// zero-size hidden buttons: active exactly while the window holds
    /// the keys — never a global claim (⌥Space, the one exception,
    /// lives in `GlobalHotKey`). ⇧⌘V and ⌘↩ belong to the editor.
    private var keyboardMap: some View {
        Group {
            // ⌘1–⌘9: jump by visible tab order.
            ForEach(1...9, id: \.self) { number in
                Button("") { model.select(index: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
            // ⌘0: the ledger.
            Button("") { model.showLedger() }
                .keyboardShortcut("0", modifiers: .command)
            // ⌥⌘N: new page, default rung.
            Button("") { model.newPage() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            // ⌥⌘← / ⌥⌘→: previous / next page.
            Button("") { model.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("") { model.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            // Esc outside the editor (the ledger, chrome): hand back.
            Button("") { model.escape() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
