import SwiftUI
import UniformTypeIdentifiers

/// The edge-docked shelf: a drop/paste target on top, a stack of
/// SleeperCells below, most recent on top (docs/spec/04). Minimal
/// chrome, generous whitespace, one accent.
struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 10) {
            header
            dropZone
            if model.cells.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.cells) { cell in
                            SleeperCellView(
                                cell: cell,
                                onCopy: { model.copyOut(cell.id) },
                                onCycle: { model.cycle(cell.id) },
                                onDismiss: { model.discard(cell.id) }
                            )
                        }
                    }
                }
            }
            devFooter
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

    private var dropZone: some View {
        Button(action: model.ingest) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal")
                Text("drop or paste here")
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
        .keyboardShortcut("v", modifiers: .command)
        .accessibilityLabel(Text("Paste into a new cell"))
        // The make-or-break behavior ADR-0002 measures: a real drag,
        // received without the panel ever taking focus (issue #3 WS1).
        // Text is extracted here and staged via the same dev-seed path
        // devStageSample uses — the NSPasteboard adapter (WS2) isn't
        // yet wired into companion-ffi's ingest (that's issue #4), so a
        // real system-pasteboard round trip isn't provable through this
        // path yet; what this proves is that the shell itself receives
        // drops without activating.
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

    /// DEV SCAFFOLDING — deleted with the NSPasteboard adapter: until the
    /// core can read the real pasteboard, this stages a sample cell so
    /// the vertical slice has something alive to show.
    private var devFooter: some View {
        Button("stage a sample cell (dev)", action: model.devStageSample)
            .buttonStyle(.link)
            .font(.caption2)
            .accessibilityLabel(Text("Stage a sample cell, developer scaffolding"))
    }
}
