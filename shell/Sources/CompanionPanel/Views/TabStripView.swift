import SwiftUI
import UniformTypeIdentifiers

/// The bottom-edge tab strip, Excel-anchored (docs/spec/04): one tab
/// per page carrying its own gauge, a + for a new page, and the
/// permanent dashed ◌ ledger tab at the right end. Click selects;
/// double-click holds the clock; drag reorders; ✕ on hover closes.
struct TabStripView: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.sheets.enumerated()), id: \.element.id) { index, sheet in
                SheetTab(
                    sheet: sheet,
                    selected: model.selection == sheet.id && !model.showingLedger,
                    model: model
                )
                .onDrag {
                    model.draggingTab = sheet.id
                    return NSItemProvider(object: String(sheet.id) as NSString)
                }
                .onDrop(
                    of: [UTType.plainText],
                    delegate: TabDropDelegate(target: sheet.id, index: index, model: model)
                )
            }
            newPageTab
            Spacer(minLength: 8)
            ledgerTab
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(height: 32)
        .background(Color.panelBackground)
    }

    private var newPageTab: some View {
        Button(action: model.newPage) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("New page (⌥⌘N)")
        .accessibilityLabel(Text("New page"))
    }

    /// The dashed residue tab: expired and closed pages, dimmed (⌘0).
    private var ledgerTab: some View {
        Button(action: model.showLedger) {
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 10))
                if !model.ledgerEntries.isEmpty {
                    Text("\(model.ledgerEntries.count)")
                        .font(.system(.caption2, design: .monospaced))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                    .foregroundStyle(model.showingLedger ? Color.ember : .secondary)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("The ledger — expired and closed pages (⌘0)")
        .accessibilityLabel(Text("Ledger, \(model.ledgerEntries.count) dead pages"))
    }
}

/// One tab: live title, its own gauge, ⏸ while held, ✕ on hover.
private struct SheetTab: View {
    let sheet: SheetSummary
    let selected: Bool
    @ObservedObject var model: WindowModel

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if sheet.paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(sheet.title)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if hovering {
                    Button {
                        model.close(sheet.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Close page"))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 18)
            GaugeBar(
                fraction: sheet.fractionRemaining,
                paused: sheet.paused,
                lastHour: sheet.lastHour
            )
            .frame(height: 3)
            .padding(.horizontal, 3)
        }
        .frame(maxWidth: 140)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.cellBackground : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Select on click; a double-click's second tap holds the clock
        // (1h → 24h → top-up). The first tap selecting is harmless — a
        // page being paused is a page worth looking at.
        .gesture(TapGesture(count: 2).onEnded { model.pause(sheet.id) })
        .simultaneousGesture(TapGesture().onEnded { model.select(sheet.id) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityValue(Text(sheet.spokenRemaining))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button(sheet.paused ? "Top the hold up" : "Hold the clock") { model.pause(sheet.id) }
            Button("Cycle the countdown") { model.cycleRung(sheet.id) }
            Button("Close page", role: .destructive) { model.close(sheet.id) }
        }
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
}

/// Live drag-to-reorder: entering a tab while dragging another moves it
/// there immediately, so the strip previews its final order.
private struct TabDropDelegate: DropDelegate {
    let target: UInt64
    let index: Int
    let model: WindowModel

    func dropEntered(info: DropInfo) {
        guard let dragged = model.draggingTab, dragged != target else { return }
        model.move(dragged, to: index)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.draggingTab = nil
        return true
    }
}

/// A tab's gauge: the page's remaining life as geometry. Ember with a
/// hatched texture under one hour — urgency is never colour-only; a
/// held clock draws dashed — state as geometry (docs/spec/04).
struct GaugeBar: View {
    let fraction: Double
    let paused: Bool
    let lastHour: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                if paused {
                    // Frozen, dashed: a held clock does not drain.
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: width, y: geometry.size.height / 2))
                    }
                    .stroke(
                        Color.secondary,
                        style: StrokeStyle(lineWidth: geometry.size.height, dash: [3, 2])
                    )
                } else if lastHour {
                    // Hatched ember: the texture carries the urgency
                    // alongside the colour.
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: width, y: geometry.size.height / 2))
                    }
                    .stroke(
                        Color.ember,
                        style: StrokeStyle(lineWidth: geometry.size.height, dash: [2, 1.5])
                    )
                } else {
                    Capsule()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: width)
                }
            }
        }
        .accessibilityHidden(true) // the tab speaks its remaining time in words
    }
}
