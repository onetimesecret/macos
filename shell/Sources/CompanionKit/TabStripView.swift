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
/// The strip is the slots, so it stops being a row of deadlines.
///
/// The strip has no cap (issue #158). ⌘1 to ⌘9 reach the first nine
/// slots and the tenth onward have no chord, so the strip has to hold
/// more slots than fit across the card. It scrolls sideways, without a
/// bar, and follows the selection: a slot selected by chord, click or
/// mint is brought into view, so a new page minted past the edge is on
/// screen the moment it exists. Scrolling rather than clipping with a
/// marker, because a clipped tab is a slot a person cannot reach with
/// the mouse, and a marker is chrome that says "there is more" without
/// getting them there. The FILES group stays pinned ahead of the
/// scroll: files are few and are navigation peers, not slots.
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
            // The FILES group, before the PAD group and drawn only when
            // there is one (ADR-0028). With no file open this whole
            // branch is absent, so the strip is the strip it has always
            // been: the same views in the same order with the same
            // spacing, and `stripGroupsAreAbsentWithNoFileOpen` holds
            // the model side of that.
            if !model.openFiles.isEmpty {
                GroupLabel(text: "FILES")
                ForEach(model.openFiles) { file in
                    FileTab(
                        file: file,
                        selected: model.selectedFile == file.id && !model.showingLedger,
                        model: model
                    )
                }
                GroupLabel(text: "PAD")
            }
            // The slots scroll as one run with the + at their end, so
            // the + always sits after the last slot the way it always
            // has, and a strip wider than the card is reached by
            // scrolling rather than lost past the edge (issue #158).
            // The frames the reorder reads are taken in the strip's own
            // space, which the scroll offset is part of, so a drag over
            // a scrolled strip still lands on the slot under the pointer.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.tabs) { sheet in
                            SheetTab(
                                sheet: sheet,
                                selected: model.selection == sheet.id && !model.showingLedger,
                                model: model
                            )
                            .id(sheet.id)
                            .opacity(model.draggingTab == sheet.id ? 0.6 : 1)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(
                                    key: TabFramesKey.self,
                                    value: [sheet.id: geometry.frame(in: .named(Self.stripSpace))]
                                )
                            })
                            .simultaneousGesture(
                                DragGesture(
                                    minimumDistance: 4, coordinateSpace: .named(Self.stripSpace)
                                )
                                .onChanged { value in
                                    model.draggingTab = sheet.id
                                    reorder(dragged: sheet.id, pointerX: value.location.x)
                                }
                                .onEnded { _ in model.draggingTab = nil }
                            )
                        }
                        newPageTab
                    }
                }
                .onChange(of: model.selection) { selection in
                    // Follow the selection, unanimated: a chord or a
                    // mint that lands past the edge is on screen at
                    // once, and a slot already in view is left alone.
                    guard let selection else { return }
                    proxy.scrollTo(selection)
                }
            }
            Spacer(minLength: 8)
            // Also built and not drawn (issue #78): the conceal action
            // still works everywhere else it worked, and the strip stops
            // carrying a button for it.
            if HiddenUI.showsConcealButton {
                concealPageTab
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
        .help(Self.newPageHelp(chord: model.keymap.hintKeystroke(for: .pageNew)))
        .accessibilityLabel(Text("New page"))
    }

    /// The + button's tooltip, which names the chord the keymap actually
    /// bound rather than the one this view used to spell out. A keymap
    /// that moved `page::New` moves the tooltip with it, and a keymap
    /// that unbound it leaves the tooltip saying only what the button
    /// does, which is still true.
    static func newPageHelp(chord: Keystroke?) -> String {
        guard let chord else { return "New page" }
        return "New page (\(chord.displaySymbol))"
    }

    /// The ledger tab's tooltip, on the same terms. It named ⌘0 until
    /// the bundled keymap withdrew that binding (issue #78), which left
    /// a button advertising a chord that no longer did anything. Now the
    /// chord appears only when something bound it, which for the tab's
    /// own build is a keymap the user wrote.
    static func ledgerHelp(chord: Keystroke?) -> String {
        let what = "The ledger: what the app did with each page and chip"
        guard let chord else { return what }
        return "\(what) (\(chord.displaySymbol))"
    }

    /// ↗ page (docs/spec/04, conceal flow): conceal the visible page
    /// into a one-time link. Opens the inline confirmation — nothing
    /// leaves until its one confirming click.
    private var concealPageTab: some View {
        Button {
            if let page = model.selectedPageID { model.beginConceal(.page(page)) }
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
        .help("Conceal this page into a one-time link")
        .accessibilityLabel(Text("Conceal page into one-time link"))
    }

    /// The dashed residue tab: the audit trail, one line per event. A
    /// toggle, so a second click returns to the page. Built and not
    /// drawn today (issue #78).
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
        .help(Self.ledgerHelp(chord: model.keymap.hintKeystroke(for: .ledgerShow)))
        .accessibilityLabel(Text("Ledger, \(model.ledgerEntries.count) records"))
    }
}

/// One tab: live title, its own gauge, ⏸ while held, ✕ on hover. A
/// slot holding no page draws a dashed rule where the gauge goes and
/// says so out loud, because there is no clock to render and the tab
/// is still the user's to select, rename, re-rung or close.
///
/// The gauge under the title stays on purpose. Dogfood phase 4 took it
/// out for an evening, together with the full width `GaugeBar` that
/// `PageStatusStack` drew along the page's bottom edge, because a thin
/// horizontal bar at the foot of a text surface reads as a horizontal
/// scroll bar for long unwrapped lines. The maintainer's call was that
/// the full width bar was the one wearing that costume, so it stays
/// gone, while a short bar under a tab title, framed by the tab, does
/// not read as a scroll bar and is the strip's one picture of how
/// long each page has left (docs/dogfood/ABERRATIONS.md, 2026-09-05).
/// Whatever else is ever added down here must not be a thin bar that
/// runs the width of the page.
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
                // The ✕ keeps its seat whether or not it is visible, since
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
            // Present only while the sync switch is on: with it off the
            // menu is exactly yesterday's menu, which is the
            // indistinguishability issue #102 promises. Per page,
            // because enrolment is (relay protocol §1).
            if model.sync.enabled, let pageID = sheet.pageID {
                Button(Self.syncMenuTitle(enrolled: model.sync.isEnrolled(pageID))) {
                    model.sync.enrol(page: pageID, on: !model.sync.isEnrolled(pageID))
                }
            }
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

    /// The sync item's label: what the click will do, both ways. Pure,
    /// like its neighbours, so the offer at each state is testable
    /// without a menu — nonisolated because nothing about it needs
    /// the view's actor, and the tests call it from off it.
    nonisolated static func syncMenuTitle(enrolled: Bool) -> String {
        enrolled ? "Stop syncing this page" : "Sync this page to your devices"
    }

    /// The tooltip: the tier in words, since the chip carries it only
    /// as a number. `holdRemainingMs` is what is left of the hold, not
    /// of the page; the page's own time is the gauge under the title
    /// and the countdown in its day gutter.
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
    /// hold its own clock. The prompt itself is shared
    /// (`TabRenamePrompt`), since the roll's day headers offer the same
    /// verb on the same slots (issue #79) and two alerts explaining one
    /// rule would eventually explain it differently.
    private func promptForRename() {
        guard let name = TabRenamePrompt.newName(for: sheet.title) else { return }
        model.renameTab(sheet.id, to: name)
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

/// One open file on the strip: its filename after a document glyph,
/// the ember dot while it holds unsaved edits, and a ✕ on hover.
///
/// A sibling of `SheetTab` and not a `SheetTab` bent to fit. The two
/// share a shape and share nothing else: a file has no rung to cycle,
/// no clock to hold, no name to rename, and nothing to sync, so a tab
/// that reused the slot's context menu would offer five verbs the core
/// refuses. What it does keep is the ✕'s reserved seat, so revealing
/// the close mark never nudges the filename.
///
/// Where a slot draws its gauge, a file draws its unsaved marker or
/// nothing at all. Never a gauge: a file has no countdown, and a bar at
/// any value would say it had one (ADR-0028).
///
/// Internal rather than private so the pure label below can be tested
/// without a strip, in the idiom `SheetTab.holdMenuTitle` set.
struct FileTab: View {
    let file: FileSummary
    let selected: Bool
    @ObservedObject var model: PageModel

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true) // the tab says "file" in words
                Text(file.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    model.closeFile(file.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .accessibilityLabel(Text("Close file"))
            }
            .padding(.horizontal, 8)
            .frame(height: 18)
            // The gauge's seat, kept so a file tab and a page tab stand
            // the same height beside each other. What sits in it is the
            // unsaved dot or nothing, and never a bar.
            ZStack {
                if file.isDirty { UnsavedDot() }
            }
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
        // One tap, one meaning. The strip's second tap holds a page's
        // clock, and a file has no clock to hold.
        .onTapGesture { model.select(target: .file(file.id)) }
        .help(FileRowLabel.help(for: file))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(FileRowLabel.spoken(for: file)))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button("Save") { model.select(target: .file(file.id)); model.saveActiveFile() }
            Button("Save As…") { model.select(target: .file(file.id)); model.saveActiveFileAs() }
            Button("Close file", role: .destructive) { model.closeFile(file.id) }
        }
    }
}

/// The strip's group headings, FILES and PAD (ADR-0028).
///
/// They exist because the two classes have to be visibly separated and
/// a gap alone would not say why: a person seeing a document glyph
/// beside a countdown deserves to be told these are two kinds of thing
/// rather than left to infer it. Drawn only while both groups exist,
/// so a pad with no file open shows neither heading and reads exactly
/// as it did before files existed.
///
/// Exposed to VoiceOver as the group's name rather than hidden, which
/// is what makes the two named groups the specification asks for.
struct GroupLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(1.3)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .accessibilityLabel(Text("\(text.lowercased()) group"))
    }
}

/// Asking for a tab's new name, wherever the asking is done from.
///
/// An `NSAlert` with a text field rather than a SwiftUI alert, since the
/// SwiftUI form of this takes a text field only from macOS 14 and both
/// apps ship to 13. It answers with the string the user submitted and
/// nothing else (the caller renames) so the one surface that owns a
/// tab's identity stays the model.
///
/// Submitting an empty field is meaningful, not a cancel: it drops the
/// override and lets the title derive from the page again. Cancelling is
/// nil, and nil means nothing happened at all.
///
/// Shared because the strip is no longer the only place the verb is
/// offered. The roll carries rename on each page's own day-header gutter
/// (issue #79), and the informative text below is a rule about what a
/// tab name *is* (it outlives every page, it is frozen into every
/// ledger record, so the secret must stay out of it), which is a rule
/// the app should state once.
@MainActor
enum TabRenamePrompt {
    static func newName(for currentTitle: String) -> String? {
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
        field.stringValue = currentTitle
        field.placeholderString = "empty derives the title from the page"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // An accessory app's alert would otherwise open behind whatever
        // is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        // Bracketed like every modal of ours, so the surface comes
        // forward again once the prompt has returned.
        guard ModalSession.run({ alert.runModal() }) == .alertFirstButtonReturn else {
            return nil
        }
        return field.stringValue
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
/// the title: the dashed gauge alone says *held* but never *which
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

/// A gauge: the page's remaining life as geometry. Ember with a
/// hatched texture under one hour, since urgency is never colour-only,
/// and a held clock draws dashed: state as geometry (docs/spec/04). Drawn
/// under each tab of the strip and on the time rail's rows; no longer
/// along the page's own bottom edge, for the reason `SheetTab` gives.
public struct GaugeBar: View {
    let fraction: Double
    let paused: Bool
    let toppedUp: Bool
    let lastHour: Bool

    /// The dash a held clock draws with. The longer hold draws the
    /// longer dash: the same language the gauge already speaks, since
    /// the tier is a fact about duration and the dash is the only mark
    /// on the gauge that measures anything. A tab is 140 points wide
    /// with a title, a ⏸ and a ✕ already in it, and a rail row is
    /// narrower still, so the tier gets no glyph of its own on the
    /// gauge; the tab's `HoldChip`, the tooltip and the context menu
    /// carry the number.
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
