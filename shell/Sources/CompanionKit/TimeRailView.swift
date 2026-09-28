import SwiftUI

/// The stream down the leading edge of the card: every live page as a
/// checkpoint on one track, newest at the top, with the part of the
/// roll the reader can see marked beside them (issue #79, issue #131,
/// and the stream navigator that succeeded the rail's day rows).
///
/// Navigation, and one plus. A node says which day and which minute a
/// page was made, shows how long the page the surface is on has left,
/// and takes you there when it is clicked; the bare track beside the
/// nodes scrolls the roll to the stretch clicked, and a wheel turned
/// over the column scrolls the roll as if it had turned over the page.
/// It offers no rename, no close, no rung, no hold and no drag-reorder:
/// days have an order the user does not shuffle and a label the user
/// does not type, and a rail that could close a day would be exactly
/// the misreading ADR-0017's eject trigger is about. Those verbs sit on
/// each page's own gutter inside the roll. The one thing the rail does
/// make is a new page, from the + on the PAD heading, which is the
/// strip's own + button (issue #158): a page is minted with the clock's
/// reading of now, so it needs no day to sit beside.
///
/// A slot holding no page draws no node here, because a slot holding no
/// page is on no day. The tab is still standing underneath, named and
/// empty exactly as `expire_due` left it, and the strip shows it again
/// the moment the mode goes off. No node on this rail mints by being
/// selected: today has a node whether or not anything stands in it, and
/// the place a click on the empty one lands on is the shipped create
/// path, not a mint of its own (ADR-0017).
///
/// Ember is spent on three things and nothing else: the active node and
/// the stretch of track under it, the bar beside the viewport band, and
/// the plus. Each is paired with a shape or a word (D-03).
///
/// It reuses `GaugeBar` and `GroupLabel` where they stand rather than
/// moving them, so `TabStripView.swift` takes no diff for this view and
/// the claim that horizontal mode is untouched is a fact about the diff.
public struct TimeRailView: View {
    @ObservedObject var model: PageModel
    @Environment(\.presentationSurface) private var surface

    /// The roll handed to a rail whose window does not own the page
    /// content: a measurement nobody publishes to and a pair of asks
    /// nobody answers. It is this view's own and is never claimed, so
    /// the navigator over it packs its nodes from the top and draws no
    /// band and no slivers, which is all a window with no roll mounted
    /// can honestly say about one.
    @StateObject private var unclaimedRoll = RollGeometryModel()

    public init(model: PageModel) {
        self.model = model
    }

    /// Whether this window's rail reads and drives the roll, pure: only
    /// the owner's does (ADR-0033). The roll geometry is one of the
    /// presentation fields with a single owner, and its claim guards
    /// the write. The claim's two answers, the scroll and the wheel,
    /// are reachable from any rail that holds the model, so the rail is
    /// guarded by construction, as `PageKeyboardMap` is: a window that
    /// does not own installs no wheel relay and is handed no roll to
    /// scroll, and a wheel turned over its rail falls through to
    /// whatever would have had it anyway.
    nonisolated static func drivesRoll(
        surface: PresentationOwner, owner: PresentationOwner
    ) -> Bool {
        PresentationOwner.mayWrite(surface, owner: owner)
    }

    /// Which roll a rail is handed, pure: the owner's own for the
    /// owner's rail, and the stand in for the other window's. This is
    /// the one place the choice is made, so it is the one place to
    /// change if the rail beside a glance (`GlanceView`, ADR-0033) is
    /// ever to draw more than the unclaimed roll's empty band.
    static func roll(
        surface: PresentationOwner, owner: PresentationOwner,
        owners: RollGeometryModel, unclaimed: RollGeometryModel
    ) -> RollGeometryModel {
        drivesRoll(surface: surface, owner: owner) ? owners : unclaimed
    }

    /// The rail's width, fixed. It eats into the page's column and not
    /// into the header, which is why `BackdropGeometry.minWidth` and the
    /// clamp its tests pin do not move for this mode. Whether the card
    /// wants a wider floor while the days are showing is a question for
    /// the dogfood window rather than a number to guess at now.
    ///
    /// One hundred and ten points, the navigator mockup's floor: the
    /// track, a node's dot, the day's words beside it and the gauge
    /// under them, with room for "10 days ago" in the monospaced
    /// caption. Longer than that truncates at the tail, which is the
    /// net rather than the plan.
    static let width: CGFloat = 110

    public var body: some View {
        let projection = model.timeUnits
        // A file or the ledger showing replaces the roll, so no page is
        // the page on screen while one is selected, and no node lights.
        let rollIsShowing = !model.showingLedger && model.selectedFile == nil
        let nodes = StreamNavigator.nodes(
            projection: projection, tabs: model.tabs,
            selection: rollIsShowing ? model.selection : nil,
            surfaceShowsRoll: rollIsShowing,
            stampFormat: model.stampFormat
        )
        // `FILES` and `PAD` are group labels in one navigation column.
        // The default stack centres its intrinsic text while the PAD
        // heading itself fills the column for its trailing plus, which
        // made the two labels look unrelated. One leading alignment line
        // gives the shelf, its heading, and the stream a shared origin.
        VStack(alignment: .leading, spacing: 2) {
            // The Files shelf: fixed, above the days, and drawn only
            // when a file is open (ADR-0028). Files are navigation
            // peers and not dated regions, so they sit outside the roll
            // entirely rather than taking a day of their own, and
            // nothing here reaches `TimeUnitProjection.project`, which
            // is the ADR-0020 guarantee kept structurally: a file never
            // enters `tabs`, so the projection cannot see one.
            if !model.openFiles.isEmpty {
                GroupLabel(text: "FILES")
                ForEach(model.openFiles) { file in
                    FileShelfRow(
                        file: file,
                        selected: model.selectedFile == file.id && !model.showingLedger,
                        model: model
                    )
                }
            }
            padHeading
            StreamNavigatorView(
                model: model,
                roll: Self.roll(
                    surface: surface, owner: model.owner,
                    owners: model.rollGeometry, unclaimed: unclaimedRoll
                ),
                drivesRoll: Self.drivesRoll(surface: surface, owner: model.owner),
                nodes: nodes,
                chords: chords(for: nodes, openFileCount: model.openFiles.count)
            )
            hiddenPages(count: projection.hiddenBlankPages)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .background(Color.panelBackground)
    }

    /// The PAD group's heading with the strip's + on it. The plus sits
    /// on the heading and not on today's node, because a new page
    /// lands on today whatever the rail is showing, and a plus beside a
    /// day would promise a page on that day. It mints outright, the way
    /// the strip's does: a click on a plus is the deliberate ask, so it
    /// takes none of `openToday()`'s jump-first reading. The tooltip
    /// names the chord the keymap bound to `page::New`, in the strip's
    /// words, so the two buttons that do one thing cannot describe it
    /// two ways.
    private var padHeading: some View {
        HStack(spacing: 0) {
            GroupLabel(text: "PAD")
            Spacer(minLength: 0)
            Button(action: model.newPage) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.emberText)
            .help(TimeUnitTab.newPageHelp(chord: model.keymap.hintKeystroke(for: .pageNew)))
            .accessibilityLabel(Text("New page"))
        }
        .padding(.top, 6)
        .padding(.trailing, 2)
        .padding(.bottom, 2)
    }

    /// The chord that reaches each day's first node, resolved before
    /// the navigator is built so the view stays a drawing rather than a
    /// lookup. A node's day decides its chord; the later pages on a day
    /// have none, because the chord lands on the day's first page.
    private func chords(
        for nodes: [StreamNavigator.Node], openFileCount: Int
    ) -> [UInt64: Keystroke] {
        var chords: [UInt64: Keystroke] = [:]
        for node in nodes where node.firstOfDay {
            // The days start after the open files, because
            // `visibleTargets` draws files first in both modes and
            // `select(index:)` indexes that array. Numbering the days
            // from zero would print command 1 beside today while
            // command 1 selected the first file, which is a label that
            // lies about the chord it names.
            if let chord = Self.chord(
                forRowAt: Self.targetIndex(forDay: node.dayIndex, openFileCount: openFileCount),
                keymap: model.keymap
            ) {
                chords[node.id] = chord
            }
        }
        return chords
    }

    /// The count of what the mode is hiding, and the instrument for the
    /// content predicate itself.
    ///
    /// Old pages with nothing on them draw no nodes here, so without a
    /// count a person would not know they exist, or that the strip
    /// still holds them. The count says so out loud, and its tooltip
    /// names the toggle that brings those pages back. They cost nothing
    /// else, since the strip has no cap (issue #158), and nothing is
    /// auto-discarded: reaping blank pages is a lifetime mechanism
    /// nobody asked for (ADR-0016).
    ///
    /// A number that is routinely above zero in dogfood means the
    /// content bar is set wrong, which is ADR-0020's fifth eject
    /// trigger, so this line is a measurement as much as a message.
    @ViewBuilder
    private func hiddenPages(count: Int) -> some View {
        if let line = Self.hiddenPagesLine(count: count) {
            Text(line)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(Self.hiddenPagesHelp(count: count))
                .accessibilityLabel(Text(Self.hiddenPagesHelp(count: count)))
        }
    }

    /// Which day the rail marks as the one the surface is showing.
    ///
    /// The mark follows the selected page's day rather than the row
    /// that was last clicked, so a selection moved by the keyboard, or
    /// dropped onto another day by the fall after an expiry, moves it
    /// too. A selection standing in a slot the rail draws no node for
    /// (an empty slot, or a blank old page the content bar is holding
    /// back) lights nothing at all: what is on screen is then not on
    /// the rail, and marking a node would say the surface is somewhere
    /// it is not.
    ///
    /// Today is the one day that can answer to no slot, and while it
    /// holds no page it takes the mark only by elimination, on the pad
    /// where no drawn day holds a page, so there is nothing else the
    /// mark could sit on and today is the place the next page would
    /// land. Pure, because which day is lit is a decision and not a
    /// drawing; `StreamNavigator.nodes` states the same rule per node.
    static func selectedBucket(projection: TimeUnitProjection, selection: UInt64?) -> Int? {
        if let selection,
            let day = projection.units.first(where: { $0.tabIDs.contains(selection) }) {
            return day.bucket
        }
        guard projection.units.allSatisfy({ $0.pageIDs.isEmpty }) else { return nil }
        return projection.units.first { $0.bucket == 0 }?.bucket
    }

    /// Where the day at `day` sits in `PageModel.visibleTargets`, which
    /// is the array `select(index:)` indexes.
    ///
    /// Pure, and the only expression of the offset, so the chord a node
    /// prints and the chord that reaches that node are one arithmetic
    /// rather than two that have to be kept in step. Files come first
    /// in both layouts, which is the lead's decision, so the days start
    /// after them; numbering the days from zero would print command 1
    /// beside today while command 1 selected the first file.
    nonisolated static func targetIndex(forDay day: Int, openFileCount: Int) -> Int {
        openFileCount + day
    }

    /// The ⌘-number that lands on the day at this index.
    ///
    /// ⌘1 to ⌘9 count the days while the mode is on. Asked of the
    /// keymap rather than spelled here, so moving or removing a binding
    /// changes the tooltip with it. A tenth day simply has no chord.
    static func chord(forRowAt index: Int, keymap: ResolvedKeymap) -> Keystroke? {
        let number = index + 1
        guard let command = CommandID.allCases.first(where: { $0.selectsPageNumber == number })
        else { return nil }
        return keymap.hintKeystroke(for: command)
    }

    /// What the footer prints, or nothing at all when nothing is being
    /// held back. Short, because it is a footer and not a node: it
    /// counts what the rail is not showing, and a sentence at the
    /// bottom of the column would weigh more than the days above it.
    /// The sentence rides the tooltip and the accessibility label
    /// instead, and "3 blank" is words rather than an abbreviation, so
    /// doc 05's rule is answered at both ends.
    static func hiddenPagesLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) blank"
    }

    /// The same fact at length: how many live pages the days are not
    /// showing, and the one place they can be reached from.
    static func hiddenPagesHelp(count: Int) -> String {
        let pages = count == 1
            ? "One live page has nothing on it"
            : "\(count) live pages have nothing on them"
        return "\(pages), so no day is drawn for them. Turn the time tabs off in Settings "
            + "to reach them, nothing is discarded to make room."
    }
}

/// The navigator itself: the track, the nodes on it, the band over the
/// part of the roll the reader can see, and the slivers that say where
/// the lines fall. Every position comes from `StreamNavigator.layout`;
/// this view places what it is handed and answers the clicks.
///
/// It observes the roll's own measurement rather than the model for the
/// band and the slivers, so a scroll redraws this column and nothing
/// else on the card. The band, the slivers and the track take no
/// clicks, so a tap meant for a node still lands on the node, and they
/// are hidden from VoiceOver, which has the nodes themselves and would
/// hear nothing here it could act on.
struct StreamNavigatorView: View {
    @ObservedObject var model: PageModel
    @ObservedObject var roll: RollGeometryModel
    /// Whether this rail reaches a roll at all
    /// (`TimeRailView.drivesRoll`). False in the window that does not
    /// own, where `roll` is the stand in, no wheel relay is installed,
    /// and a click on a node selects its page without asking any roll
    /// to move. Selection is the shared model's and either window may
    /// change it; the scroll that follows is the owner's own business.
    let drivesRoll: Bool
    let nodes: [StreamNavigator.Node]
    let chords: [UInt64: Keystroke]

    @State private var hoverID: UInt64?
    @State private var layoutCache = StreamNavigatorLayoutCache()

    private typealias Metrics = StreamNavigator.Metrics

    var body: some View {
        GeometryReader { proxy in
            let layout = layoutCache.layout(
                nodes: nodes, geometry: roll.geometry,
                height: proxy.size.height, width: proxy.size.width
            )
            ZStack(alignment: .topLeading) {
                // Bare track: a click here scrolls the roll to the
                // stretch clicked, selecting nothing. Under everything,
                // so the nodes above take their own clicks first.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { point in
                        jump(toTrackY: point.y, layout: layout)
                    }
                track(layout)
                if let windowY = layout.windowY {
                    windowMark(at: windowY)
                }
                ForEach(layout.placed) { placed in
                    if let noteY = placed.noteY {
                        emptyDaysNote(placed.node.emptyDays, at: noteY)
                    }
                }
                if let segment = layout.activeSegment {
                    Rectangle()
                        .fill(Color.ember)
                        .frame(width: 2, height: segment.height)
                        .offset(x: Metrics.trackX - 0.5, y: segment.y)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                slivers(layout)
                if let band = layout.band {
                    viewportBand(band, width: proxy.size.width)
                }
                ForEach(layout.placed) { placed in
                    node(placed, width: proxy.size.width)
                }
            }
            // Only the owner's rail installs the relay. A relay in the
            // other window would watch that window's wheel events and
            // swallow each one over the column, for a roll it may not
            // drive.
            .background(drivesRoll ? WheelRelay { event in roll.relay(wheel: event) } : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("pad stream"))
    }

    // MARK: The track

    /// The line the nodes sit on: solid down to where the seven day
    /// window ends, dashed past it, so the retained stretch reads as a
    /// different kind of ground.
    @ViewBuilder
    private func track(_ layout: StreamNavigator.Layout) -> some View {
        let solidEnd = layout.windowY ?? layout.trackBottom
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 1, height: max(0, solidEnd - layout.trackTop))
            .offset(x: Metrics.trackX, y: layout.trackTop)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        if let windowY = layout.windowY, layout.trackBottom > windowY {
            Path { path in
                path.move(to: CGPoint(x: Metrics.trackX + 0.5, y: windowY))
                path.addLine(to: CGPoint(x: Metrics.trackX + 0.5, y: layout.trackBottom))
            }
            .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Where the seven day window ends: a tick across the track and the
    /// word beside it. The tooltip says what the dashed stretch under
    /// it is.
    private func windowMark(at y: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Rectangle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 7, height: 1)
            Text("7d")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .offset(x: Metrics.trackX - 3, y: y - 6)
        .help("seven-day window ends here; the pages below are retained because they hold content")
        .accessibilityHidden(true)
    }

    /// Skipped time, noted where it falls: a dashed dot on the track and
    /// the count in words.
    private func emptyDaysNote(_ count: Int, at y: CGFloat) -> some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(
                    Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
                .frame(width: 5, height: 5)
            Text(StreamNavigator.emptyDaysLabel(count))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .offset(x: Metrics.trackX - 2, y: y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: The roll, faintly

    /// One sliver per laid-out line, as wide a share of the room beside
    /// the track as the line was of the wrap width. Geometry only: a
    /// long line is a long sliver and says nothing else. The lines under
    /// the band draw darker, because they are the ones the reader can
    /// see. Faint is a requirement rather than a taste: the nodes are
    /// the rail's content, and a background that competed with them
    /// would have turned a navigation column into a chart.
    private func slivers(_ layout: StreamNavigator.Layout) -> some View {
        ForEach(layout.slivers) { sliver in
            Rectangle()
                .fill(Color.secondary.opacity(sliver.inView ? 0.5 : 0.15))
                .frame(width: sliver.width, height: 1)
                .offset(x: Metrics.trackX + Metrics.sliverInset, y: sliver.y)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The part of the roll the reader can see: a wash across the
    /// column and, on the track, the bar in ember. Absent when the
    /// whole roll is on screen, since a band around everything marks
    /// nothing; it is the scrolled reader the band exists for.
    private func viewportBand(_ band: StreamNavigator.Band, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.08))
                .frame(width: width, height: band.height)
            Capsule()
                .fill(Color.ember)
                .frame(width: 3, height: band.height)
                .offset(x: Metrics.trackX - 1)
        }
        .offset(y: band.y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: The nodes

    /// One checkpoint: its dot on the track, the day's words when it is
    /// the first of its day, its minute, and under the active one its
    /// gauge. Hover reveals a fill behind it and never content (D-10);
    /// the tooltip repeats what the gutter already shows.
    private func node(_ placed: StreamNavigator.Placed, width: CGFloat) -> some View {
        let node = placed.node
        let first = node.firstOfDay
        let hovered = hoverID == node.id
        return HStack(alignment: .top, spacing: 8) {
            marker(for: node)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                if first {
                    Text(node.dayLabel)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(node.active ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !node.stamp.isEmpty {
                    Text(node.stamp)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(node.active ? .secondary : .tertiary)
                        .lineLimit(1)
                }
                if node.trailing {
                    Text(StreamNavigator.retainedLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if node.active, !node.trailing, node.hasPage {
                    GaugeBar(
                        fraction: node.fractionRemaining,
                        paused: node.paused,
                        toppedUp: node.toppedUp,
                        lastHour: node.lastHour
                    )
                    .frame(width: Metrics.gaugeWidth, height: 3)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Metrics.trackX - (first ? 3 : 2))
        .padding(.trailing, 2)
        .frame(width: width, height: placed.rowHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovered ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .offset(y: placed.y - (first ? 7 : 6))
        .onHover { inside in
            if inside {
                hoverID = node.id
            } else if hoverID == node.id {
                hoverID = nil
            }
        }
        .onTapGesture { jump(to: placed) }
        .help(StreamNavigator.help(for: node, chord: chords[node.id]))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(StreamNavigator.spoken(for: node)))
        .accessibilityValue(Text(node.spokenRemaining))
        .accessibilityAddTraits(node.active ? [.isSelected] : [])
    }

    /// The mark on the track. The active node is a filled ember dot,
    /// the one dot the rail draws: twenty hollow circles read as twenty
    /// things to look at, and only one of them is where the surface
    /// stands. Every other page is a quaternary tick across the track,
    /// wider for a day's first page, so the track reads as a ruler with
    /// one bead on it. The place today keeps while it holds no page is
    /// a dashed ring, in the strip's own language for a slot standing
    /// empty. Each mark keeps the same seat whichever it is, so a
    /// selection moving down the rail moves nothing else.
    @ViewBuilder
    private func marker(for node: StreamNavigator.Node) -> some View {
        let size: CGFloat = node.firstOfDay ? 7 : 5
        if !node.hasPage {
            Circle()
                .strokeBorder(
                    node.active ? Color.ember : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5])
                )
                .frame(width: size, height: size)
        } else if node.active {
            Circle()
                .fill(Color.ember)
                .frame(width: size, height: size)
        } else {
            Rectangle()
                .fill(.quaternary)
                .frame(width: size, height: 1)
                .frame(width: size, height: size)
        }
    }

    // MARK: Where a click lands

    /// A node was clicked: select its page, the same answer the keyboard
    /// gets, and bring its gutter to the top of the roll. The empty
    /// today place takes the create path, which is the one click on the
    /// rail that makes something (ADR-0017).
    private func jump(to placed: StreamNavigator.Placed) {
        model.select(target: placed.node.target)
        guard drivesRoll else { return }
        roll.scroll(toDocumentOffset: StreamNavigator.jumpOffset(forDocumentTop: placed.documentTop))
    }

    /// Bare track was clicked: scroll the roll to the stretch under the
    /// click and select nothing.
    private func jump(toTrackY y: CGFloat, layout: StreamNavigator.Layout) {
        guard drivesRoll, layout.anchors.count >= 2 else { return }
        roll.scroll(toDocumentOffset: layout.jumpOffset(
            forTrackY: y, viewportHeight: roll.geometry.viewportHeight
        ))
    }
}

/// Keeps document-proportional navigator work out of viewport-only
/// publications. Revision zero is intentionally uncached: it belongs to
/// hand-built or unmeasured geometry that has no identity contract.
@MainActor
private final class StreamNavigatorLayoutCache {
    private struct Key: Equatable {
        let nodes: [StreamNavigator.Node]
        let documentIdentity: UUID
        let documentRevision: UInt64
        let height: CGFloat
        let width: CGFloat
    }

    private var key: Key?
    private var documentLayout: StreamNavigator.Layout?

    /// Called from inside a `GeometryReader` builder. The reference is
    /// retained in `@State`, but its cache mutations are intentionally not
    /// observable: publishing from body evaluation would invalidate the
    /// view from within its own body. The small node array is compared on
    /// each evaluation, and this single-entry cache may recompute while
    /// live resize alternates dimensions.
    func layout(
        nodes: [StreamNavigator.Node], geometry: RollGeometry,
        height: CGFloat, width: CGFloat
    ) -> StreamNavigator.Layout {
        guard let identity = geometry.document.identity, geometry.document.revision > 0 else {
            return StreamNavigator.layout(
                nodes: nodes, geometry: geometry, height: height, width: width)
        }
        let next = Key(
            nodes: nodes,
            documentIdentity: identity,
            documentRevision: geometry.document.revision,
            height: height,
            width: width
        )
        if key != next || documentLayout == nil {
            key = next
            documentLayout = StreamNavigator.layout(
                nodes: nodes, geometry: geometry, height: height, width: width)
        }
        guard let documentLayout else { return .empty }
        return StreamNavigator.updatingViewport(
            in: documentLayout, geometry: geometry)
    }
}

/// A wheel turned over the rail reaches the roll.
///
/// The rail is SwiftUI and has no wheel of its own to answer, so a
/// wheel over the column would scroll nothing while the same wheel an
/// inch to the right scrolls the page. This view sits behind the
/// navigator, takes no clicks at all (its hit test answers nothing, so
/// every tap falls through to the nodes), and watches the window's
/// wheel events: one whose pointer is over the column is handed to the
/// roll's own scroll view, momentum and all, and swallowed here so
/// nothing else answers it twice.
private struct WheelRelay: NSViewRepresentable {
    let relay: (NSEvent) -> Void

    func makeNSView(context: Context) -> WheelRelayView {
        let view = WheelRelayView()
        view.relay = relay
        return view
    }

    func updateNSView(_ view: WheelRelayView, context: Context) {
        view.relay = relay
    }

    /// SwiftUI is done with the relay, which is every time ownership
    /// leaves this window and the rail drops its wheel (ADR-0033). The
    /// watch is retired here and not left to `viewDidMoveToWindow`,
    /// since a dismantled view is not promised a last trip through its
    /// window's lifecycle, and a monitor left standing is an app wide
    /// tap holding a closure over a roll that is no longer this rail's.
    /// As `DayScrollView.dismantleNSView` does for the roll's handle,
    /// the release is unconditional: it is this view's own watch.
    static func dismantleNSView(_ view: WheelRelayView, coordinator: ()) {
        view.retire()
    }
}

final class WheelRelayView: NSView {
    var relay: ((NSEvent) -> Void)?
    /// Retired on the main-actor view lifecycle path when the view leaves
    /// its window or moves between windows, and by the representable's
    /// dismantle (`retire`).
    private var monitor: Any?

    /// Whether the view is watching its window's wheel events.
    var isWatching: Bool { monitor != nil }

    /// The representable's dismantle: stop watching and let go of the
    /// roll's answer, whether or not the view ever leaves its window.
    func retire() {
        retireMonitor()
        relay = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        retireMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let relay = self.relay, let relayWindow = self.window,
                  event.window === relayWindow
            else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            let hitView = Self.occludingView(at: event.locationInWindow, in: relayWindow)
            guard Self.shouldRelay(
                eventWindow: event.window,
                relayWindow: relayWindow,
                pointInside: true,
                hitView: hitView,
                relayView: self
            ) else { return event }
            relay(event)
            return nil
        }
    }

    /// The view under a wheel, asked of the window's content view.
    /// `hitTest` wants a point in the receiver's superview's space, and
    /// for a content view that is the window's base space, the one an
    /// event's location already stands in, so the point is passed
    /// straight through. Converting it into the content view's own
    /// bounds first would test the wrong spot the moment those bounds
    /// stop coinciding with the window's origin.
    static func occludingView(at locationInWindow: NSPoint, in window: NSWindow?) -> NSView? {
        window?.contentView?.hitTest(locationInWindow)
    }

    /// The representable deliberately answers nil from `hitTest`, so an
    /// ordinary wheel over the rail resolves to one of its ancestors in
    /// the SwiftUI host. A hit on any other same-window branch belongs to
    /// content above the rail and must neither be forwarded nor swallowed.
    static func shouldRelay(
        eventWindow: NSWindow?, relayWindow: NSWindow?, pointInside: Bool,
        hitView: NSView?, relayView: NSView
    ) -> Bool {
        guard eventWindow === relayWindow, pointInside else { return false }
        guard let hitView else { return true }
        return hitView === relayView || relayView.isDescendant(of: hitView)
    }

    private func retireMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Durable slots placed down the leading edge. The slots remain the
/// same named, reorderable objects as the bottom presentation; only
/// their measure and reading direction change (D-26).
public struct SlotRailView: View {
    @ObservedObject var model: PageModel
    @State private var rowFrames: [UInt64: CGRect] = [:]

    public init(model: PageModel) {
        self.model = model
    }

    public var body: some View {
        // Keep the slot rail on the same leading grid as the stream
        // rail. The two placement modes are peers, so changing between
        // them must not make the Files and Pad labels jump sideways.
        VStack(alignment: .leading, spacing: 2) {
            if !model.openFiles.isEmpty {
                GroupLabel(text: "FILES")
                ForEach(model.openFiles) { file in
                    FileShelfRow(
                        file: file,
                        selected: model.selectedFile == file.id && !model.showingLedger,
                        model: model
                    )
                }
                GroupLabel(text: "PAD")
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(model.tabs) { sheet in
                        SlotRailRow(
                            sheet: sheet,
                            selected: model.selection == sheet.id
                                && model.selectedFile == nil && !model.showingLedger,
                            model: model,
                            beginReorder: { model.draggingTab = sheet.id },
                            reorder: { pointerY in
                                reorder(dragged: sheet.id, pointerY: pointerY)
                            },
                            endReorder: { model.draggingTab = nil }
                        )
                        .id(sheet.id)
                        .opacity(model.draggingTab == sheet.id ? 0.6 : 1)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(
                                key: SlotRailFramesKey.self,
                                value: [sheet.id: geometry.frame(in: .named(Self.space))]
                            )
                        })
                    }
                }
            }
            Button(action: model.newPage) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(TabStripView.newPageHelp(chord: model.keymap.hintKeystroke(for: .pageNew)))
            .accessibilityLabel(Text("New page"))
            if blankCount > 0 {
                Text("\(blankCount) blank")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("\(blankCount) blank slot\(blankCount == 1 ? "" : "s")"))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(width: TimeRailView.width)
        .background(Color.panelBackground)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(SlotRailFramesKey.self) { rowFrames = $0 }
    }

    fileprivate static let space = "slotRail"

    private var blankCount: Int {
        model.tabs.count { !$0.hasPage }
    }

    private func reorder(dragged: UInt64, pointerY: CGFloat) {
        let target = model.tabs
            .filter { $0.id != dragged }
            .count { rowFrames[$0.id].map { $0.midY < pointerY } ?? false }
        guard let current = model.tabs.firstIndex(where: { $0.id == dragged }), target != current
        else { return }
        model.move(dragged, to: target)
    }
}

private struct SlotRailRow: View {
    let sheet: TabSummary
    let selected: Bool
    @ObservedObject var model: PageModel
    let beginReorder: () -> Void
    let reorder: (CGFloat) -> Void
    let endReorder: () -> Void

    @State private var hovering = false
    @State private var renaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                if sheet.paused { HoldChip(toppedUp: sheet.holdToppedUp) }
                if renaming {
                    renameField
                } else {
                    Text(sheet.title)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                reorderHandle
                Button { model.close(sheet.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .accessibilityLabel(Text("Close tab"))
            }
            Group {
                if sheet.hasPage {
                    GaugeBar(
                        fraction: sheet.fractionRemaining,
                        paused: sheet.paused,
                        toppedUp: sheet.holdToppedUp,
                        lastHour: sheet.lastHour
                    )
                } else {
                    EmptyRule()
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 3)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.cellBackground : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(TapGesture(count: 2).onEnded { if !renaming { model.pause(sheet.id) } })
        .simultaneousGesture(TapGesture().onEnded { if !renaming { model.select(sheet.id) } })
        .accessibilityElement(children: renaming ? .contain : .ignore)
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityValue(Text(sheet.spokenRemaining))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button("Rename tab…") { beginRename() }
            Button(SheetTab.holdMenuTitle(
                paused: sheet.paused, toppedUp: sheet.holdToppedUp)
            ) { model.pause(sheet.id) }
                .disabled(!sheet.hasPage)
            Button(SheetTab.rungMenuTitle(hasPage: sheet.hasPage)) {
                model.cycleRung(sheet.id)
            }
            if model.sync.enabled, let pageID = sheet.pageID {
                Button(SheetTab.syncMenuTitle(enrolled: model.sync.isEnrolled(pageID))) {
                    model.sync.enrol(page: pageID, on: !model.sync.isEnrolled(pageID))
                }
            }
            Button("Close tab", role: .destructive) { model.close(sheet.id) }
        }
    }

    private var reorderHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 12, height: 18)
            .contentShape(Rectangle())
            .help("Drag to reorder tab")
            .accessibilityLabel(Text("Reorder tab"))
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(SlotRailView.space))
                    .onChanged { value in
                        beginReorder()
                        reorder(value.location.y)
                    }
                    .onEnded { _ in endReorder() }
            )
    }

    private func beginRename() {
        renameDraft = sheet.title
        renaming = true
    }

    private var renameField: some View {
        TextField("", text: $renameDraft)
            .textFieldStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .focused($renameFocused)
            .onSubmit { endRename(committed: true) }
            .onExitCommand { endRename(committed: false) }
            .onChange(of: renameFocused) { focused in
                if !focused { endRename(committed: false) }
            }
            .onAppear { DispatchQueue.main.async { renameFocused = true } }
            .accessibilityLabel(Text("Tab name"))
    }

    private func endRename(committed: Bool) {
        guard renaming else { return }
        renaming = false
        switch TabRename.outcome(draft: renameDraft, current: sheet.title, committed: committed) {
        case .rename(let name): model.renameTab(sheet.id, to: name)
        case .keep: break
        }
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

private struct SlotRailFramesKey: PreferenceKey {
    static let defaultValue: [UInt64: CGRect] = [:]

    static func reduce(value: inout [UInt64: CGRect], nextValue: () -> [UInt64: CGRect]) {
        value.merge(nextValue()) { _, newer in newer }
    }
}

/// One open file on the rail's Files shelf: the filename over the
/// unsaved marker, in the shape a day row already has so the column
/// reads as one column.
///
/// It draws no gauge and no dashed rule where a day draws one. A day
/// with no page draws the dash because a day is a place a page could
/// stand; a file is never a place a page stands, and a mark that said
/// otherwise would be the misreading the two classes exist to prevent.
///
/// Where a day says how long its soonest page has left, a file says
/// saved or unsaved, in words. Same seat, different fact, and neither
/// one is a countdown on the other.
struct FileShelfRow: View {
    let file: FileSummary
    let selected: Bool
    @ObservedObject var model: PageModel

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: "doc")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(file.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ZStack {
                if file.isDirty { UnsavedDot() }
            }
            .frame(height: 3)
            .padding(.horizontal, 3)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.cellBackground : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(target: .file(file.id)) }
        .help(FileRowLabel.help(for: file))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(FileRowLabel.spoken(for: file)))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The pure decisions a day's tab makes, shared by the bottom strip's
/// `TimeUnitBottomTab` and the navigator's nodes: the target a click
/// resolves to, which day offers a plus, and the tooltips. A namespace
/// and no longer a view since the navigator replaced the rail's rows;
/// kept under its name so the tests and the strip read as they did.
///
/// Internal rather than private so the decisions can be tested without
/// a window, in the idiom `TabStripView.newPageHelp` and
/// `SheetTab.holdMenuTitle` set. On the main actor, as the view it
/// replaced was, since the tooltips it builds read the strip's.
@MainActor
enum TimeUnitTab {
    /// Which bottom tab carries the + button: today, and only today. A
    /// page is minted with the clock's own reading of now, so today is
    /// the one day a new page can land on; a plus beside yesterday
    /// would promise a page in the past. Pure, so the strip's tests
    /// can pin the placement without a window. The side rail puts its
    /// plus on the PAD heading for the same reason.
    nonisolated static func offersNewPage(_ unit: TimeUnitProjection.Unit) -> Bool {
        unit.bucket == 0
    }

    /// The + button's tooltip, which is the strip's tooltip: one
    /// sentence for one action, so a keymap that moved `page::New`
    /// moves both, and a keymap that unbound it leaves both saying only
    /// what the button does.
    static func newPageHelp(chord: Keystroke?) -> String {
        TabStripView.newPageHelp(chord: chord)
    }

    /// Where a click on a day lands.
    ///
    /// The same answer the keyboard gets, and deliberately the same
    /// shape: a day answers with its first page's slot, and only today
    /// can answer with no slot at all. `PageModel.visibleTargets` maps
    /// the very same units the very same way, so a click on the second
    /// day and ⌘2 cannot disagree about where the second day is.
    static func target(for unit: TimeUnitProjection.Unit) -> SurfaceTarget {
        guard let tab = unit.tabIDs.first else { return .today }
        return .tab(tab)
    }

    /// A day's tooltip: what the click does, in the same words the day
    /// itself shows, and the chord that does it too. With nothing bound
    /// it says only what the click does, which is still true.
    static func dayHelp(spokenLabel: String, chord: Keystroke?) -> String {
        chorded("Go to \(spokenLabel)", chord: chord)
    }

    /// Today's tooltip, which has two readings. Today already holding a
    /// page is a jump like any other; today holding none is the one
    /// place where a click conjures something, and saying "go to today"
    /// there would describe a page that does not exist. The two agree
    /// word for word about the day that has one, so a day that gains a
    /// page reads the same either way it was asked.
    static func todayHelp(hasPage: Bool, chord: Keystroke?) -> String {
        guard hasPage else { return chorded("Start today's page", chord: chord) }
        return dayHelp(spokenLabel: "today", chord: chord)
    }

    /// The chord in parentheses after the description, or the plain
    /// description when the keymap bound nothing, `newPageHelp`'s
    /// shape, so every tooltip in the app degrades the same way.
    private static func chorded(_ what: String, chord: Keystroke?) -> String {
        guard let chord else { return what }
        return "\(what) (\(chord.displaySymbol))"
    }
}

extension View {
    @ViewBuilder
    func accessibilityNewPageAction(when offered: Bool, action: @escaping () -> Void) -> some View {
        if offered {
            accessibilityAction(named: Text("New page"), action)
        } else {
            self
        }
    }
}
