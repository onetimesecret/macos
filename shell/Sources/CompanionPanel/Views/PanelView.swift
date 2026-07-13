import SwiftUI
import UniformTypeIdentifiers

/// TRANSITIONAL SURFACE: the spike's docked shelf, now speaking the
/// rev C core — a seal target on top, the pages below in tab order,
/// each with its pausable countdown. The real rev C window (movable,
/// resizable, bottom tabs, the ink editor) is the next slice.
struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 10) {
            header
            sealZone
            if let notice = model.notice {
                Text(notice)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ember)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.sheets.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.sheets) { sheet in
                            SheetRowView(
                                sheet: sheet,
                                onCycle: { model.cycleRung(sheet.id) },
                                onPause: { model.pause(sheet.id) },
                                onClose: { model.close(sheet.id) }
                            )
                        }
                    }
                }
            }
            footer
        }
        .padding(12)
        .background(Color.panelBackground)
        // The 1 Hz countdown redraw runs only while this view is on
        // screen (docs/spec/05 frugality budget).
        .onAppear { model.startRedraw() }
        .onDisappear { model.stopRedraw() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.ember).frame(width: 7, height: 7)
            Text("Companion").font(.system(.subheadline, design: .monospaced))
            Spacer()
            Text("PRESENT, NOT CENTRAL")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            pinToggle
        }
    }

    /// Float-on-top setting. A real `Toggle` (not a bare button) so
    /// VoiceOver announces it as a switch with on/off state — the panel's
    /// window level follows it (PanelController).
    private var pinToggle: some View {
        Toggle(isOn: $model.floatsOnTop) {
            Image(systemName: model.floatsOnTop ? "pin.fill" : "pin")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(model.floatsOnTop
            ? "Floating above other windows — click to let them cover it"
            : "Behaves like a normal window — click to keep it on top")
        .accessibilityLabel(Text("Keep panel above other windows"))
    }

    /// The sealed paste (⇧⌘V) and drop-to-seal target. Masking is by
    /// gesture, not by content: what lands here becomes an opaque chip,
    /// unread and unclassified (docs/spec/04).
    private var sealZone: some View {
        Button(action: model.sealPaste) {
            HStack(spacing: 6) {
                Image(systemName: "seal")
                Text("drop or ⇧⌘V to seal")
                    .font(.system(.callout, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1, dash: [4])
                    )
                    .foregroundStyle(.secondary)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .accessibilityLabel(Text("Seal the clipboard's content onto the page"))
        // Drop-to-seal, received without the panel ever taking focus.
        // Interim route: the text goes to the core's seal-text entry
        // (the ⌘↩ call); the boundary-lawful end state is the core
        // reading NSDraggingInfo.draggingPasteboard itself
        // (docs/hardware-verification.md — a hardware-session decision).
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text else { return }
                Task { @MainActor in model.receiveDrop(text) }
            }
            return true
        }
    }

    private var emptyState: some View {
        Text("Empty is the resting state.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("new page", action: model.newPage)
                .buttonStyle(.link)
                .font(.caption2)
                .accessibilityLabel(Text("New page"))
            Spacer()
            // DEV SCAFFOLDING — present only while the core is built
            // with --dev-scaffolding: seeds the clipboard and seals it,
            // so the panel shows a live chip without leaving the app.
            Button("seal a sample (dev)", action: model.devStageSample)
                .buttonStyle(.link)
                .font(.caption2)
                .accessibilityLabel(Text("Seal a sample chip, developer scaffolding"))
        }
    }
}
