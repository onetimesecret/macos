import AppKit
import SwiftUI

/// The bottom-edge tab strip, Excel-anchored (docs/spec/04): one tab
/// per durable slot carrying its own gauge, a + for a new tab, and the
/// permanent dashed ◌ ledger tab at the right end. Click selects;
/// double-click holds the clock; drag reorders; ✕ on hover closes.
///
/// The ledger tab and the ↗ page button are built here and not shown
/// (issue #78, `HiddenUI`), so what a user sees today is the slots and
/// the +.
///
/// A slot whose page expired keeps its place, its name and its rung,
/// and draws the dashed empty treatment instead of a gauge (ADR-0017).
/// The strip is the slots, so it stops being nine deadlines.
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
            ForEach(model.tabs) { sheet in
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
            // Also built and not drawn (issue #78): promotion still
            // works everywhere else it worked, and the strip stops
            // carrying a button for it.
            if HiddenUI.showsPromoteButton {
                promotePageTab
            }
            // Built and not drawn (issue #78): the ledger keeps
            // recording, and the strip stops offering the way in.
            if HiddenUI.showsLedgerEntryPoints {
                ledgerTab
            }
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
        let target = model.tabs
            .filter { $0.id != dragged }
            .count { tabFrames[$0.id].map { $0.midX < pointerX } ?? false }
        let current = model.tabs.firstIndex { $0.id == dragged }
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
        .help("New page (⌘N)")
        .accessibilityLabel(Text("New page"))
    }

    /// ↗ page (docs/spec/04, promotion flow): promote the visible page
    /// into a one-time link. Opens the inline confirmation — nothing
    /// leaves until its one confirming click.
    private var promotePageTab: some View {
        Button {
            if let page = model.selectedPageID { model.beginPromotion(.page(page)) }
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
        .disabled(model.selectedPageID == nil || model.showingLedger)
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

/// One tab: live title, its own gauge, ⏸ while held, ✕ on hover. A
/// slot holding no page draws a dashed rule where the gauge goes and
/// says so out loud, because there is no clock to render and the tab
/// is still the user's to select, rename, re-rung or close.
///
/// Internal rather than private so the two menu labels below, which are
/// pure functions of the slot's state, can be tested without a menu.
struct SheetTab: View {
    let sheet: TabSummary
    let selected: Bool
    @ObservedObject var model: PageModel

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if sheet.paused {
                    HoldChip(toppedUp: sheet.holdToppedUp)
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
                .accessibilityLabel(Text("Close tab"))
            }
            .padding(.horizontal, 8)
            .frame(height: 18)
            if sheet.hasPage {
                GaugeBar(
                    fraction: sheet.fractionRemaining,
                    paused: sheet.paused,
                    toppedUp: sheet.holdToppedUp,
                    lastHour: sheet.lastHour
                )
                .frame(height: 3)
                .padding(.horizontal, 3)
            } else {
                // The dashed treatment the ledger tab already uses: a
                // slot with no clock draws no gauge, because a gauge at
                // zero reads as a page about to die rather than as a
                // slot waiting to be used (ADR-0017).
                EmptyRule()
                    .frame(height: 3)
                    .padding(.horizontal, 3)
            }
        }
        .frame(maxWidth: 140)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.cellBackground : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Select on click; a double-click's second tap cycles the hold
        // (1h → 24h → released). The first tap selecting is harmless on
        // a slot that holds a page: a page being paused is a page worth
        // looking at. On an empty slot the first tap mints one
        // (ADR-0017), and the hold that would land on that fresh page is
        // refused by the model, which is where the decision lives
        // because these recognizers are re-made as the view re-renders.
        .gesture(TapGesture(count: 2).onEnded { model.pause(sheet.id) })
        .simultaneousGesture(TapGesture().onEnded { model.select(sheet.id) })
        .help(holdDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityValue(Text(sheet.spokenRemaining))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button("Rename tab…") { promptForRename() }
            // Disabled rather than hidden on an empty slot: the item
            // keeps its place in a menu whose shape the user knows, and
            // an item that says it will hold a clock there would be
            // offering a gesture the core refuses, having no clock.
            Button(holdMenuTitle) { model.pause(sheet.id) }
                .disabled(!sheet.hasPage)
            Button(Self.rungMenuTitle(hasPage: sheet.hasPage)) { model.cycleRung(sheet.id) }
            Button("Close tab", role: .destructive) { model.close(sheet.id) }
        }
    }

    /// What the next double-click does, named plainly — the gesture is
    /// a cycle, so the menu has to say which turn of it is next. On an
    /// empty slot the item is disabled and this is the label it wears
    /// while it is.
    private var holdMenuTitle: String {
        Self.holdMenuTitle(paused: sheet.paused, toppedUp: sheet.holdToppedUp)
    }

    /// The hold item's label, given the clock's state. Pure, so what
    /// the menu offers at each turn of the cycle is testable without a
    /// menu.
    static func holdMenuTitle(paused: Bool, toppedUp: Bool) -> String {
        if toppedUp { return "Release the hold" }
        return paused ? "Top the hold up to 24h" : "Hold the clock for 1h"
    }

    /// The rung item's label. On an empty slot the gesture sets the
    /// rung the slot's next page is born at rather than shortening any
    /// countdown, and there is no countdown to name, so the item says
    /// what it will actually do (ADR-0017).
    static func rungMenuTitle(hasPage: Bool) -> String {
        hasPage ? "Shorten the countdown" : "Shorten the next page's countdown"
    }

    /// The tooltip: the tier in words, since the dash carries it only
    /// as a texture. `holdRemainingMs` is what is left of the hold, not
    /// of the page — the page's own time is the gauge and the header.
    private var holdDescription: String {
        guard sheet.hasPage else {
            return "This tab holds no page. Select it to open one at \(sheet.rungLabel)."
        }
        guard sheet.paused else {
            return "Double-click to hold this page's clock for an hour"
        }
        let left = Self.holdLeft.string(
            from: TimeInterval(sheet.holdRemainingMs) / 1000
        )
        let tier = sheet.holdToppedUp ? "topped up to 24h" : "held 1h"
        guard let left else { return "Clock \(tier)" }
        let next = sheet.holdToppedUp ? "release it" : "top it up to 24h"
        return "Clock \(tier), \(left) left — double-click to \(next)"
    }

    private static let holdLeft: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

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
        alert.messageText = "Rename this tab"
        alert.informativeText =
            "The name shows on the tab and is frozen into each ledger record "
            + "the tab's pages produce, so keep the secret itself out of it. It "
            + "outlives every page the tab holds, and only closing the tab ends "
            + "it. Leave the field empty to let the label follow the page's own "
            + "first line again."
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
        model.renameTab(sheet.id, to: field.stringValue)
    }

    private var accessibilityDescription: String {
        guard sheet.hasPage else { return "tab, \(sheet.title), holding no page" }
        var description = "page, \(sheet.title)"
        if sheet.chipCount > 0 {
            description += ", \(sheet.chipCount) sealed chip\(sheet.chipCount == 1 ? "" : "s")"
        }
        if sheet.paused {
            description += sheet.holdToppedUp ? ", clock held, topped up" : ", clock held"
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

/// The hold, as a chip on the tab: ⏸ and the span the last press
/// bought. The gesture does three different things now, and the tab is
/// where all three happen, so the tier is worth the ~20 points it costs
/// the title — the dashed gauge alone says *held* but never *which
/// press comes next*.
///
/// The ⏸ stays in front of the number, and not for decoration: "24h"
/// is also a rung label, and without the pause mark a chip reading
/// "24h" would be read as the page's countdown rather than its hold.
/// The tab carries no rung label of its own, so inside a tab the mark
/// is enough to separate them.
struct HoldChip: View {
    let toppedUp: Bool

    /// What the hold is worth in words — the tooltip and the context
    /// menu say the same thing at length.
    static func label(toppedUp: Bool) -> String {
        toppedUp ? "24h" : "1h"
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "pause.fill")
                .font(.system(size: 6))
            Text(Self.label(toppedUp: toppedUp))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
        .foregroundStyle(.secondary)
        .fixedSize() // never squeezed by a long title
        .accessibilityHidden(true) // the tab speaks the hold in words
    }
}

/// What a slot with no page draws where its gauge would be: a dashed
/// rule, the same language the ledger tab speaks. Not a gauge at zero,
/// which would read as a page an instant from death rather than as a
/// slot standing empty and ready, and not nothing at all, which would
/// make the tab jump a few points taller than its neighbours every time
/// a page expired.
struct EmptyRule: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
            }
            .stroke(
                Color.secondary.opacity(0.5),
                style: StrokeStyle(lineWidth: geometry.size.height, dash: [2, 3])
            )
        }
        .accessibilityHidden(true) // the tab says it holds no page in words
    }
}

/// A tab's gauge: the page's remaining life as geometry. Ember with a
/// hatched texture under one hour — urgency is never colour-only; a
/// held clock draws dashed — state as geometry (docs/spec/04).
public struct GaugeBar: View {
    let fraction: Double
    let paused: Bool
    let toppedUp: Bool
    let lastHour: Bool

    /// The dash a held clock draws with. The longer hold draws the
    /// longer dash: the same language the gauge already speaks, since
    /// the tier is a fact about duration and the dash is the only mark
    /// on the gauge that measures anything. A tab is 140 points wide
    /// with a title, a ⏸ and a ✕ already in it, so the tier gets no
    /// glyph of its own — the tooltip and the context menu carry the
    /// number.
    static let firstHoldDash: [CGFloat] = [3, 2]
    static let toppedUpDash: [CGFloat] = [7, 2]

    public init(fraction: Double, paused: Bool, toppedUp: Bool = false, lastHour: Bool) {
        self.fraction = fraction
        self.paused = paused
        self.toppedUp = toppedUp
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
                        style: StrokeStyle(
                            lineWidth: geometry.size.height,
                            dash: toppedUp ? Self.toppedUpDash : Self.firstHoldDash
                        )
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
