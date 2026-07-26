import AppKit
import CompanionKit
import SwiftUI

/// The window's face (docs/spec/04): a quiet header where the title bar
/// is, one page of ink and chips (or the ledger), the page's draining
/// gauge, and the bottom-edge tab strip. An ember border shows exactly
/// while the page holds the keyboard.
///
/// What a page *is* — the content area, the status lines, the countdown,
/// the keyboard map — is shared with the backdrop (`PageSurface.swift`).
/// What lives here is the panel's own chrome: the header standing in for
/// the title bar, the pin, and the window-shaped layout around them.
struct WindowRootView: View {
    @ObservedObject var model: PageModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .frame(height: 34)
            Divider()
            PageContentView(model: model, emptyHint: "click, ⌥Space, or ↩ for a page")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PageStatusStack(model: model)
            Divider()
            TabStripView(model: model)
        }
        .background(Color.panelBackground)
        .overlay(
            // The ember border: the window holds the keyboard, and a
            // keystroke lands somewhere (the editor when a page shows,
            // the Return grant when none does). Visible state, never
            // colour alone; the caret and focus ring agree.
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.ember.opacity(model.holdsKeys ? 0.8 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .background(PageKeyboardMap(model: model))
        // The 1 Hz countdown redraw runs only while the window is on
        // screen (docs/spec/05 frugality budget).
        .onAppear { model.startRedraw() }
        .onDisappear { model.stopRedraw() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.ember).frame(width: 6, height: 6)
            Text(model.showingLedger ? "the ledger" : "CompanionApp")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            #if DEBUG
            // Standing indicator while the debug capture opt-out is on:
            // the window is screenshot-able and screen-share-visible,
            // and stderr alone is invisible outside a terminal.
            if model.allowCapture {
                Image(systemName: "camera.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.ember)
                    .help("Debug: capture exclusion is OFF — this window shows up in screenshots and screen sharing")
                    .accessibilityLabel(Text("Screenshots allowed (debug)"))
            }
            #endif
            if let sheet = model.selectedSheet, !model.showingLedger {
                CountdownButton(sheet: sheet) { model.cycleRung(sheet.id) }
            }
            pinToggle
        }
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
}
