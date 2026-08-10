import AppKit
import SwiftUI

/// The bottom-edge tab strip, Excel-anchored (docs/spec/04): one tab
/// per page carrying its own gauge, a + for a new page, and the
/// permanent dashed ◌ ledger tab at the right end. Click selects;
/// double-click holds the clock; drag reorders; ✕ on hover closes.
public struct TabStripView: View {
    @ObservedObject var model: PageModel

    public init(model: PageModel) {
        self.model = model
    }

    /// Each tab's frame in the strip's space, kept fresh by preference
    /// so a drag knows which slot the pointer is over. A plain mouse
    /// drag, not an item-provider drag session — the non-activating
    /// panel never grants the latter its session.
    @State private var tabFrames: [UInt64: CGRect] = [:]

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(model.sheets) { sheet in
                SheetTab(
                    sheet: sheet,
                    selected: model.selection == sheet.id && !model.showingLedger,
                    model: model
                )
                .opacity(model.draggingTab == sheet.id ? 0.6 : 1)
                .background(GeometryReader { geometry in
                    Color.clear.preference(
                        key: TabFramesKey.self,
                        value: [sheet.id: geometry.frame(in: .named(Self.stripSpace))]
                    )
                })
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.stripSpace))
                        .onChanged { value in
                            model.draggingTab = sheet.id
                            reorder(dragged: sheet.id, pointerX: value.location.x)
                        }
                        .onEnded { _ in model.draggingTab = nil }
                )
            }
            newPageTab
            Spacer(minLength: 8)
            promotePageTab
            ledgerTab
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(height: 32)
        .background(Color.panelBackground)
        .coordinateSpace(name: Self.stripSpace)
        .onPreferenceChange(TabFramesKey.self) { tabFrames = $0 }
    }

    private static let stripSpace = "tabStrip"

    /// Excel-style live reorder: the dragged tab lands after every tab
    /// whose midpoint the pointer has passed. Midpoints, not edges, keep
    /// the order stable while the strip re-lays-out mid-drag.
    private func reorder(dragged: UInt64, pointerX: CGFloat) {
        let target = model.sheets
            .filter { $0.id != dragged }
            .count { tabFrames[$0.id].map { $0.midX < pointerX } ?? false }
        let current = model.sheets.firstIndex { $0.id == dragged }
        if let current, target != current {
            model.move(dragged, to: target)
        }
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

    /// ↗ page (docs/spec/04, promotion flow): promote the visible page
    /// into a one-time link. Opens the inline confirmation — nothing
    /// leaves until its one confirming click.
    private var promotePageTab: some View {
        Button {
            if let sheet = model.selection { model.beginPromotion(.page(sheet)) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .medium))
                Text("page")
                    .font(.system(.caption2, design: .monospaced))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(model.selection == nil || model.showingLedger)
        .help("Promote this page to a one-time link")
        .accessibilityLabel(Text("Promote page to one-time link"))
    }

    /// The dashed residue tab: the audit trail, one line per event
    /// (⌘0). A toggle, so a second click returns to the page.
    private var ledgerTab: some View {
        Button(action: model.toggleLedger) {
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
        .help("The ledger: what the app did with each page and chip (⌘0)")
        .accessibilityLabel(Text("Ledger, \(model.ledgerEntries.count) records"))
    }
}

/// One tab: live title, its own gauge, ⏸ while held, ✕ on hover.
private struct SheetTab: View {
    let sheet: SheetSummary
    let selected: Bool
    @ObservedObject var model: PageModel

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
                // The ✕ keeps its seat whether or not it is visible —
                // revealing it must never nudge the title (the browsers'
                // convention: reserve, then fade in).
                Button {
                    model.close(sheet.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .accessibilityLabel(Text("Close page"))
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
            Button("Rename page…") { promptForRename() }
            Button(sheet.paused ? "Top the hold up" : "Hold the clock") { model.pause(sheet.id) }
            Button("Shorten the countdown") { model.cycleRung(sheet.id) }
            Button("Close page", role: .destructive) { model.close(sheet.id) }
        }
    }

    /// The rename gesture lives here because double-click is already
    /// the pause gesture: a tab that renamed on double-click could not
    /// hold its own clock. An NSAlert with a text field rather than a
    /// SwiftUI alert, since the SwiftUI form of this takes a text field
    /// only from macOS 14 and both apps ship to 13.
    ///
    /// Submitting an empty field is meaningful, not a cancel: it drops
    /// the override and lets the title derive from the page again.
    private func promptForRename() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rename this page"
        alert.informativeText =
            "The name shows on the tab and is frozen into each ledger record "
            + "the page produces, so keep the secret itself out of it. Leave the "
            + "field empty to let the title follow the page's own first line again."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = sheet.title
        field.placeholderString = "empty derives the title from the page"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // An accessory app's alert would otherwise open behind whatever
        // is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.renameSheet(sheet.id, to: field.stringValue)
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

/// The tabs' frames, gathered up the preference chain for the strip's
/// drag-to-reorder.
private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [UInt64: CGRect] = [:]

    static func reduce(value: inout [UInt64: CGRect], nextValue: () -> [UInt64: CGRect]) {
        value.merge(nextValue()) { _, newer in newer }
    }
}

/// A tab's gauge: the page's remaining life as geometry. Ember with a
/// hatched texture under one hour — urgency is never colour-only; a
/// held clock draws dashed — state as geometry (docs/spec/04).
public struct GaugeBar: View {
    let fraction: Double
    let paused: Bool
    let lastHour: Bool

    public init(fraction: Double, paused: Bool, lastHour: Bool) {
        self.fraction = fraction
        self.paused = paused
        self.lastHour = lastHour
    }

    public var body: some View {
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
