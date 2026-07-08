import SwiftUI

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
        }
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
