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
    /// The stance the page content takes; a read only rail's nodes take no drop (issue 267).
    let readOnly: Bool
    @Environment(\.presentationSurface) private var surface

    /// The roll handed to a rail whose window does not own the page
    /// content: a measurement nobody publishes to and a pair of asks
    /// nobody answers. It is this view's own and is never claimed, so
    /// the navigator over it packs its nodes from the top and draws no
    /// band and no slivers, which is all a window with no roll mounted
    /// can honestly say about one.
    @StateObject private var unclaimedRoll = RollGeometryModel()

    public init(model: PageModel, readOnly: Bool) {
        self.model = model
        self.readOnly = readOnly
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
    /// the one place the choice is made. Ordinary presentation switches
    /// hide the non-owner window (ADR-0036); its unclaimed roll carries
    /// nodes packed from the top, with no band and no slivers.
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
    nonisolated static let width: CGFloat = 110

    /// The rail's width while multiple pads are on, with room for the heading's sort menu.
    nonisolated static let experimentalWidth: CGFloat = 150

    /// One measure for the rail and the layout caption in settings; with pads off it is `width`.
    nonisolated static func width(experimental: Bool) -> CGFloat {
        experimental ? experimentalWidth : width
    }

    public var body: some View {
        unifiedRail
    }

    private var unifiedRail: some View {
        let projection = model.timeUnits
        // A file or the ledger showing replaces the roll, so no page is
        // the page on screen while one is selected, and no node lights.
        let rollIsShowing = !model.showingLedger && model.selectedFile == nil
        let nodes = StreamNavigator.nodes(
            projection: projection, tabs: model.navigationTabs,
            selection: rollIsShowing ? model.selection : nil,
            surfaceShowsRoll: rollIsShowing,
            stampFormat: model.stampFormat
        )
        // `Files` and `Pad` are group labels in one navigation column.
        // The default stack centres its intrinsic text while the PAD
        // heading itself fills the column for its trailing plus, which
        // made the two labels look unrelated. One leading alignment line
        // gives the shelf, its heading, and the stream a shared origin.
        return VStack(alignment: .leading, spacing: 2) {
            // The Files shelf: fixed, above the days, and drawn only
            // when a file is open (ADR-0028). Files are navigation
            // peers and not dated regions, so they sit outside the roll
            // entirely rather than taking a day of their own, and
            // nothing here reaches `TimeUnitProjection.project`, which
            // is the ADR-0020 guarantee kept structurally: a file never
            // enters `tabs`, so the projection cannot see one.
            if !model.navigationFiles.isEmpty {
                GroupLabel(text: CompanionL10n.string("pad.files.heading"))
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: FileShelfRow.spacing) {
                        ForEach(model.navigationFiles) { file in
                            FileShelfRow(
                                file: file,
                                selected: model.selectedFile == file.id && !model.showingLedger,
                                model: model
                            )
                        }
                    }
                }
                .frame(maxHeight: FileShelfRow.shelfHeight(rows: model.navigationFiles.count))
            }
            padHeading(nodes: nodes)
            StreamNavigatorView(
                model: model,
                roll: Self.roll(
                    surface: surface, owner: model.owner,
                    owners: rollIsShowing ? model.rollGeometry : unclaimedRoll, unclaimed: unclaimedRoll
                ),
                drivesRoll: rollIsShowing && Self.drivesRoll(surface: surface, owner: model.owner),
                readOnly: readOnly,
                nodes: nodes,
                chords: chords(for: nodes, openFileCount: model.navigationFiles.count)
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(width: Self.width(experimental: model.pads.isEnabled))
        .background(Color.panelBackground)
    }

    static func nodes(for unit: TimeUnitProjection.Unit, in nodes: [StreamNavigator.Node]) -> [StreamNavigator.Node] {
        let pages = Set(unit.pageIDs)
        return nodes.filter { node in
            if let page = node.page { return pages.contains(page) }
            return pages.isEmpty && node.bucket == unit.bucket
        }
    }

    /// The heading menu's orders: the days', then the active checkpoint's day, which gives
    /// both a keyboard path outside the navigator (ADR-0060).
    static func sortSections(model: PageModel, nodes: [StreamNavigator.Node]) -> [PadSortSection] {
        var sections = [PadSortSection.days(in: model)]
        if let active = nodes.first(where: { $0.active && $0.hasPage }) {
            sections.append(.checkpoints(of: active, in: model))
        }
        return sections
    }

    private func sortMenu<Heading: View>(
        sections: [PadSortSection], @ViewBuilder heading: () -> Heading
    ) -> some View {
        let helps = sections.map(\.copy.help)
        return Menu {
            ForEach(sections, id: \.scope) { section in
                Section(section.copy.label) {
                    PadSortPicker(section: section, model: model)
                        .pickerStyle(.inline)
                        .labelsHidden()
                }
            }
        } label: {
            HStack(spacing: 4) {
                heading()
                Image(systemName: "chevron.down")
                    .font(.system(size: NSFont.miniSystemFontSize, weight: .medium))
                    .foregroundStyle(Color.secondaryInk)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(helps.joined(separator: "\n"))
        .accessibilityLabel(CompanionL10n.format(
            "pad.sort.label", CompanionL10n.string("pad.timeline.heading")))
        .accessibilityValue(helps.joined(separator: ", "))
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
    private func padHeading(nodes: [StreamNavigator.Node]) -> some View {
        HStack(spacing: 0) {
            if model.pads.isEnabled {
                sortMenu(sections: Self.sortSections(model: model, nodes: nodes)) {
                    GroupLabel(text: CompanionL10n.string("pad.timeline.heading"))
                }
            } else {
                GroupLabel(text: CompanionL10n.string("pad.heading"))
            }
            Spacer(minLength: 0)
            Button(action: model.newPage) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.emberText)
            .help(TabStripView.newPageHelp(chord: model.keymap.hintKeystroke(for: .pageNew)))
            .accessibilityLabel(Text(CompanionL10n.string("pad.page.new")))
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
                keymap: model.keymap, padsEnabled: model.pads.isEnabled
            ) {
                chords[node.id] = chord
            }
        }
        return chords
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
    /// With pads on, a binding `PadShortcutMonitor` takes for a pad is skipped.
    static func chord(
        forRowAt index: Int, keymap: ResolvedKeymap, padsEnabled: Bool = false
    ) -> Keystroke? {
        let number = index + 1
        guard let command = CommandID.allCases.first(where: { $0.selectsPageNumber == number })
        else { return nil }
        guard padsEnabled else { return keymap.hintKeystroke(for: command) }
        return keymap.bindings.first {
            $0.command == command && !switchesPads($0.keystroke, keymap: keymap)
        }?.keystroke
    }

    /// Whether `stroke` is a ⌘0 to ⌘9 that `PadShortcutMonitor` turns into a pad switch.
    nonisolated static func switchesPads(_ stroke: Keystroke, keymap: ResolvedKeymap) -> Bool {
        (0...9).contains { number in
            Keystroke.parse("cmd-\(number)") == .success(stroke)
                && PadShortcutMonitor.allows(number: number, keymap: keymap)
        }
    }

}

/// The navigator itself: the track, the nodes on it, the band over the
/// part of the roll the reader can see, and the slivers that say where
/// the lines fall. Every position comes from `StreamNavigator.layout`;
/// this view places what it is handed and answers the clicks.
///
/// It observes the roll's own measurement rather than the model for the
/// band and the slivers, so a scroll redraws this column and nothing
/// else on the card. The scrollbar lane takes track clicks and the
/// column takes drags; checkpoint labels retain their navigation taps.
/// Decorative drawing is hidden from VoiceOver.
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
    /// The rail's stance (`TimeRailView.readOnly`); a read only rail's nodes take no drop.
    let readOnly: Bool
    let nodes: [StreamNavigator.Node]
    let chords: [UInt64: Keystroke]

    @GestureState private var isScrubbing = false
    @State private var scrollDrag: StreamNavigator.ScrollDrag?
    @State private var dragInvalidated = false
    @State private var hoverID: UInt64?
    @State private var layoutCache = StreamNavigatorLayoutCache()
    @State private var mapCache = StreamNavigatorLayoutCache()
    /// The width the clip gives the drawing, less a legacy scroller when the system shows one.
    @State private var clipWidth: CGFloat?

    private typealias Metrics = StreamNavigator.Metrics

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: clipWidth ?? proxy.size.width, height: proxy.size.height)
            let layout = layoutCache.layout(
                nodes: nodes, geometry: roll.geometry, height: size.height, width: size.width)
            let nodeIDs = nodes.map(\.id)
            if StreamNavigator.isDense(layout, columnHeight: size.height) {
                let list = StreamNavigator.checkpointList(layout.placed)
                // The list keeps room for the active row, or the first when none is active.
                let row = (list.active ?? list.rows.first)?.placed.rowHeight ?? Metrics.firstRow
                let mapSize = CGSize(
                    width: proxy.size.width,
                    height: StreamNavigator.denseMapHeight(columnHeight: size.height, row: row))
                let map = mapCache.layout(
                    nodes: nodes, geometry: roll.geometry,
                    height: mapSize.height, width: mapSize.width, compact: true)
                VStack(spacing: Metrics.mapGap) {
                    stream(map, size: mapSize, nodeIDs: nodeIDs, compact: true)
                        .frame(width: mapSize.width, height: mapSize.height)
                    checkpointList(
                        list, height: max(0, size.height - mapSize.height - Metrics.mapGap))
                }
            } else {
                // Rows that outrun the column lengthen the drawing, and the column scrolls to
                // reach them inside its clip, with the overlay scroller a sidebar shows (#277).
                ScrollView(.vertical, showsIndicators: true) {
                    stream(layout, size: size, nodeIDs: nodeIDs)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(GeometryReader { content in
                            Color.clear.preference(key: ClipWidthKey.self, value: content.size.width)
                        })
                }
                .onPreferenceChange(ClipWidthKey.self) { clipWidth = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(CompanionL10n.string("pad.stream")))
    }

    /// The reading position as a whole percent in 0...100, and 0 when the roll has nothing to scroll.
    nonisolated static func readingPercent(
        viewportTop: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat
    ) -> Int {
        let range = documentHeight - viewportHeight
        guard range.isFinite, range > 0, viewportTop.isFinite else { return 0 }
        return Int(100 * min(1, max(0, viewportTop / range)))
    }

    /// The dense rail's checkpoints as rows in a scroll view of their own, which a selection
    /// change scrolls by the least move that shows the active row (#277).
    private func checkpointList(_ list: StreamNavigator.CheckpointList, height: CGFloat) -> some View {
        let reveal = list.active.map {
            RailReveal.Request(id: $0.id, top: $0.top, bottom: $0.bottom)
        }
        return ScrollView(.vertical, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                ForEach(list.rows) { row in
                    node(row.placed, width: nil, top: row.top)
                }
            }
            .frame(
                maxWidth: .infinity, minHeight: max(height, list.contentHeight),
                maxHeight: max(height, list.contentHeight), alignment: .topLeading)
            .background(RailReveal(request: reveal).accessibilityHidden(true))
            // The rows fill the clip, so this is the clip's width, as the drawing's is in the other branch.
            .background(GeometryReader { content in
                Color.clear.preference(key: ClipWidthKey.self, value: content.size.width)
            })
        }
        .onPreferenceChange(ClipWidthKey.self) { clipWidth = $0 }
        .frame(height: height)
    }

    /// The drawing itself, `layout.contentHeight` tall and clipped by the scroll view around it.
    private func stream(
        _ layout: StreamNavigator.Layout, size: CGSize, nodeIDs: [UInt64], compact: Bool = false
    ) -> some View {
        // The one clamp: `.empty` reads 0 and the drawing still fills the column.
        let contentHeight = max(size.height, layout.contentHeight)
        // A wheel over a column that scrolls turns the column; over one that fits, it
        // turns the roll (D-38), through a relay only the owner's rail installs, since a
        // relay in the other window would swallow that window's wheel for a roll it may
        // not drive.
        let relays = drivesRoll
            && StreamNavigator.relaysWheel(contentHeight: layout.contentHeight, columnHeight: size.height)
        let reveal = compact ? nil : layout.placed.first { $0.node.active }.map {
            RailReveal.Request(id: $0.id, top: $0.groundTop, bottom: $0.drawnTop + $0.rowHeight)
        }
        return ZStack(alignment: .topLeading) {
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
                viewportBand(band, width: size.width)
            }
            ForEach(layout.placed) { placed in
                if compact {
                    marker(for: placed.node)
                        .offset(x: Metrics.trackX - 3, y: placed.y)
                        .allowsHitTesting(false).accessibilityHidden(true)
                } else {
                    node(placed, width: size.width, top: placed.drawnTop)
                }
            }
            // A scrollbar lane along the leading edge stays reachable
            // where checkpoint rows span the column. It stops short of
            // the dots on the track, so the dots and the labels keep
            // their taps.
            Color.clear
                .frame(width: Metrics.scrollLaneWidth, height: contentHeight)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    jump(toTrackY: point.y, layout: layout)
                }
                .allowsHitTesting(drivesRoll && layout.band != nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(CompanionL10n.string("pad.stream.position")))
                .accessibilityValue(Text(CompanionL10n.format(
                    "pad.stream.percent",
                    Self.readingPercent(
                        viewportTop: roll.geometry.viewportTop,
                        documentHeight: roll.geometry.documentHeight,
                        viewportHeight: roll.geometry.viewportHeight))))
                .accessibilityAdjustableAction { direction in
                    let step = max(1, roll.geometry.viewportHeight * 0.8)
                    let delta: CGFloat = direction == .increment ? step : -step
                    let maximum = max(0, roll.geometry.documentHeight - roll.geometry.viewportHeight)
                    roll.scrub(toDocumentOffset: min(maximum, max(0, roll.geometry.viewportTop + delta)))
                }
                .accessibilityHidden(!drivesRoll || layout.band == nil)
        }
        .frame(width: size.width, height: contentHeight, alignment: .topLeading)
        .highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .updating($isScrubbing) { _, active, _ in active = true }
                .onChanged { value in
                    guard drivesRoll, layout.band != nil, !dragInvalidated else { return }
                    if scrollDrag == nil {
                        scrollDrag = StreamNavigator.ScrollDrag(
                            layout: layout, geometry: roll.geometry, startY: value.startLocation.y)
                    }
                    if let scrollDrag {
                        roll.scrub(toDocumentOffset: scrollDrag.offset(atY: value.location.y))
                    }
                }
                .onEnded { _ in scrollDrag = nil; dragInvalidated = false },
            including: drivesRoll && layout.band != nil ? .all : .subviews
        )
        .onChange(of: isScrubbing) { active in
            if !active { scrollDrag = nil; dragInvalidated = false }
        }
        .onChange(of: drivesRoll) { _ in invalidateDrag() }
        .onChange(of: model.pads.activeID) { _ in invalidateDrag() }
        .onChange(of: nodeIDs) { _ in invalidateDrag() }
        .onChange(of: size.width) { _ in invalidateDrag() }
        .onChange(of: size.height) { _ in invalidateDrag() }
        .onChange(of: DocumentStamp(roll.geometry.document)) { _ in invalidateDrag() }
        .onDisappear { scrollDrag = nil }
        .background(relays ? WheelRelay { event in roll.relay(wheel: event) }.accessibilityHidden(true) : nil)
        .background(RailReveal(request: reveal).accessibilityHidden(true))
    }

    private func invalidateDrag() {
        if isScrubbing || scrollDrag != nil { dragInvalidated = true }
        scrollDrag = nil
    }

    // MARK: The track

    /// The line the nodes sit on: solid through the seven day window,
    /// dashed past it, so the retained stretch reads as a different
    /// kind of ground.
    @ViewBuilder
    private func track(_ layout: StreamNavigator.Layout) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 1, height: layout.windowTrack.height)
            .offset(x: Metrics.trackX, y: layout.windowTrack.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        if let retained = layout.retainedTrack {
            Path { path in
                path.move(to: CGPoint(x: Metrics.trackX + 0.5, y: retained.y))
                path.addLine(to: CGPoint(x: Metrics.trackX + 0.5, y: retained.y + retained.height))
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
                .font(.system(size: NSFont.miniSystemFontSize, design: .monospaced))
                .foregroundStyle(Color.secondaryInk)
        }
        .offset(x: Metrics.trackX - 3, y: y - 6)
        .help("seven-day boundary; pages outside the window are retained because they hold content")
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
                .font(.system(size: NSFont.miniSystemFontSize, design: .monospaced))
                .foregroundStyle(Color.secondaryInk)
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
    /// the tooltip repeats what the gutter already shows. A nil `width`
    /// takes the width the list's clip offers.
    private func node(_ placed: StreamNavigator.Placed, width: CGFloat?, top: CGFloat) -> some View {
        let node = placed.node
        let target = node.target
        let first = node.firstOfDay
        let hovered = hoverID == node.id
        return Button { jump(to: target, documentTop: placed.documentTop) } label: {
            HStack(alignment: .top, spacing: 8) {
                marker(for: node)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    if first {
                        Text(node.dayLabel)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(node.active ? Color.primary : Color.secondaryInk)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if !node.stamp.isEmpty {
                        Text(node.stamp)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(node.active ? Color.primary : Color.secondaryInk)
                            .lineLimit(1)
                    }
                    if node.trailing {
                        Text(StreamNavigator.retainedLabel)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.secondaryInk)
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
        }
        .buttonStyle(.plain)
        .padding(.leading, Metrics.trackX - (first ? 3 : 2))
        .padding(.trailing, 2)
        .frame(width: width, height: placed.rowHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovered ? Color.primary.opacity(0.07) : .clear)
        )
        // The node takes drops for the page its click selects (issue 267).
        .background(TabDropOverlay.node(target, model: model, readOnly: readOnly))
        .contentShape(Rectangle())
        .offset(y: top)
        .onHover { inside in
            if inside {
                hoverID = node.id
            } else if hoverID == node.id {
                hoverID = nil
            }
        }
        .contextMenu {
            if model.pads.isEnabled {
                PadSortPicker(section: .checkpoints(of: node, in: model), model: model)
            }
        }
        .help(StreamNavigator.help(for: node, chord: chords[node.id]))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(StreamNavigator.spoken(for: node)))
        .accessibilityValue(Text(node.spokenRemaining))
        .accessibilityAddTraits(RowAccessibility.traits(selected: node.active))
        .accessibilityActivation(when: true) { jump(to: target, documentTop: placed.documentTop) }
        // The context menu's orders, by name, for VoiceOver (ADR-0060).
        .accessibilityActions {
            if model.pads.isEnabled {
                let section = PadSortSection.checkpoints(of: node, in: model)
                ForEach(PadSortCopy.orders, id: \.self) { order in
                    Button(section.actionName(order)) { section.apply(order, to: model) }
                }
            }
        }
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
    private func jump(to target: SurfaceTarget, documentTop: CGFloat) {
        model.select(target: target)
        guard drivesRoll else { return }
        roll.scroll(toDocumentOffset: StreamNavigator.jumpOffset(forDocumentTop: documentTop))
    }

    /// Bare track was clicked: scroll the roll to the stretch under the
    /// click and select nothing.
    private func jump(toTrackY y: CGFloat, layout: StreamNavigator.Layout) {
        guard drivesRoll, let band = layout.band, !band.contains(y),
              layout.anchors.count >= 2 else { return }
        roll.scroll(toDocumentOffset: layout.jumpOffset(
            forTrackY: y, viewportHeight: roll.geometry.viewportHeight
        ))
    }
}

/// Keeps document-proportional navigator work out of viewport-only
/// publications. Revision zero is intentionally uncached: it belongs to
/// hand-built or unmeasured geometry that has no identity contract.
@MainActor
final class StreamNavigatorLayoutCache {
    private struct Key: Equatable {
        let nodes: [StreamNavigator.Node]
        let documentIdentity: UUID
        let documentRevision: UInt64
        let height: CGFloat
        let width: CGFloat
        let compact: Bool
    }

    private var key: Key?
    private var documentLayout: StreamNavigator.Layout?
    /// How many document layouts this cache has made, cached or not.
    private(set) var builds = 0

    /// Called from inside a `GeometryReader` builder. The reference is
    /// retained in `@State`, but its cache mutations are intentionally not
    /// observable: publishing from body evaluation would invalidate the
    /// view from within its own body. The small node array is compared on
    /// each evaluation, and this single-entry cache may recompute while
    /// live resize alternates dimensions.
    func layout(
        nodes: [StreamNavigator.Node], geometry: RollGeometry,
        height: CGFloat, width: CGFloat, compact: Bool = false
    ) -> StreamNavigator.Layout {
        guard let identity = geometry.document.identity, geometry.document.revision > 0 else {
            builds += 1
            return StreamNavigator.layout(
                nodes: nodes, geometry: geometry, height: height, width: width, compact: compact)
        }
        let next = Key(
            nodes: nodes,
            documentIdentity: identity,
            documentRevision: geometry.document.revision,
            height: height,
            width: width,
            compact: compact
        )
        if key != next || documentLayout == nil {
            key = next
            builds += 1
            documentLayout = StreamNavigator.layout(
                nodes: nodes, geometry: geometry, height: height, width: width, compact: compact)
        }
        guard let documentLayout else { return .empty }
        return StreamNavigator.updatingViewport(
            in: documentLayout, geometry: geometry)
    }
}

/// A measured document told apart by its identity and revision, without comparing its line marks.
private struct DocumentStamp: Equatable {
    let identity: UUID?
    let revision: UInt64

    init(_ document: RollGeometry.Document) {
        identity = document.identity
        revision = document.revision
    }
}

/// A selection change brings the active node's row into the column (#277).
///
/// The column is a SwiftUI scroll view, and the one place its AppKit
/// scroll view can be reached is from inside its content: this view
/// sits behind the drawing, takes no clicks, and when the active node
/// changes it asks its enclosing scroll view for the least move that
/// shows the row, by `StreamNavigator.revealOffset`. The move waits one
/// hop on the main queue, for the content to have taken the new row
/// heights before the clip is measured against them.
struct RailReveal: NSViewRepresentable {
    /// The active node's ground, from the note or mark above its row through the row's bottom.
    struct Request: Equatable {
        let id: UInt64
        let top: CGFloat
        let bottom: CGFloat
    }

    let request: Request?

    func makeNSView(context: Context) -> RailRevealView {
        let view = RailRevealView()
        view.setAccessibilityElement(false)
        view.reveal(request)
        return view
    }

    func updateNSView(_ view: RailRevealView, context: Context) {
        view.reveal(request)
    }
}

final class RailRevealView: NSView {
    private(set) var memory = StreamNavigator.RevealMemory()
    /// The request standing when the hop runs, so two in one hop make one move, the last.
    private var pending: RailReveal.Request?
    /// The request a hop could not measure, asked again when the clip or the drawing
    /// changes size or the view comes into a window.
    private var waiting: RailReveal.Request?

    /// Flipped so a row's top is measured as the layout measures it, down from the column's top.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Scroll the ground into the clip, by `StreamNavigator.RevealMemory`: the node is
    /// recorded only once its ground was measured against the clip. Every update
    /// replaces the request a hop is waiting on, and one that is not due cancels it.
    func reveal(_ request: RailReveal.Request?) {
        unwatch()
        guard let request else {
            memory.forget()
            pending = nil
            return
        }
        guard memory.isDue(request.id) else {
            pending = nil
            return
        }
        schedule(request)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
            return
        }
        if let waiting { schedule(waiting) }
    }

    /// One hop on the main queue, for the content to take the new row heights first.
    private func schedule(_ request: RailReveal.Request) {
        pending = request
        DispatchQueue.main.async { [weak self] in
            guard let self, let next = self.pending else { return }
            self.pending = nil
            self.scroll(to: next)
        }
    }

    /// Wait on the clip and the drawing for a size a reveal can be measured against.
    private func watch(_ views: [NSView], for request: RailReveal.Request) {
        waiting = request
        for view in views {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(sizeChanged), name: NSView.frameDidChangeNotification, object: view)
        }
    }

    private func unwatch() {
        waiting = nil
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
    }

    @objc private func sizeChanged(_ notification: Notification) {
        if let waiting { schedule(waiting) }
    }

    private func scroll(to request: RailReveal.Request) {
        unwatch()
        guard memory.isDue(request.id) else { return }
        guard let scrollView = enclosingScrollView, let document = scrollView.documentView else {
            waiting = request
            return
        }
        // The offset is a distance down from the top, which is the clip origin's y
        // only over a flipped document, the one SwiftUI's scroll view keeps.
        guard document.isFlipped else { return }
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        // A clip with no height, or a drawing that has not yet filled it, measures nothing.
        guard visible.height > 0, document.frame.height >= clip.bounds.height else {
            watch([clip, document], for: request)
            return
        }
        memory.record(request.id)
        let ground = convert(
            NSRect(x: 0, y: request.top, width: 1, height: request.bottom - request.top), to: document)
        guard let offset = StreamNavigator.revealOffset(
            rowTop: ground.minY, rowHeight: ground.height,
            visibleTop: visible.minY, visibleHeight: visible.height,
            contentHeight: document.frame.height)
        else { return }
        clip.scroll(to: NSPoint(x: visible.minX, y: offset))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// The width the scroll view's clip gives the drawing.
private struct ClipWidthKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
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
        view.setAccessibilityElement(false)
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
    /// dismantle (`retire`), and as a last net by deinit, which copies
    /// the token out; nonisolated(unsafe) because deinit is nonisolated.
    private nonisolated(unsafe) var monitor: Any?

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

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

/// The menu's order choices and current value share their localized labels.
struct PadSortCopy {
    let direction: PadSortDirection
    let subject: String
    static let orders: [PadSortDirection] = [.natural, .chronological, .reverseChronological]

    var label: String { CompanionL10n.format("pad.sort.label", subject) }
    var currentOrder: String {
        switch direction {
        case .natural: return CompanionL10n.string("pad.sort.natural")
        case .chronological: return CompanionL10n.string("pad.sort.oldest")
        case .reverseChronological: return CompanionL10n.string("pad.sort.newest")
        }
    }
    var help: String { CompanionL10n.format("pad.sort.help", label, currentOrder) }
}

/// One order a menu or a VoiceOver action sets: the days', or one day's checkpoints'.
struct PadSortSection: Hashable {
    enum Scope: Hashable {
        case days
        case checkpoints(dayBucket: Int)
    }

    let scope: Scope
    let direction: PadSortDirection
    let subject: String

    var copy: PadSortCopy { PadSortCopy(direction: direction, subject: subject) }

    /// The VoiceOver action that chooses `order`.
    func actionName(_ order: PadSortDirection) -> String {
        CompanionL10n.format(
            "pad.sort.action", subject, PadSortCopy(direction: order, subject: subject).currentOrder)
    }

    @MainActor static func days(in model: PageModel) -> PadSortSection {
        PadSortSection(
            scope: .days, direction: model.pads.daySortDirection(for: model.pads.activeID),
            subject: CompanionL10n.string("pad.sort.days"))
    }

    @MainActor static func checkpoints(of node: StreamNavigator.Node, in model: PageModel) -> PadSortSection {
        PadSortSection(
            scope: .checkpoints(dayBucket: node.bucket),
            direction: model.pads.checkpointSortDirection(
                for: model.pads.activeID, onDate: model.dateKey(forDayBucket: node.bucket)),
            subject: CompanionL10n.format("pad.sort.checkpoints", node.spokenDay))
    }

    @MainActor func apply(_ order: PadSortDirection, to model: PageModel) {
        switch scope {
        case .days: model.setDaySort(order)
        case .checkpoints(let bucket): model.setCheckpointSort(order, dayBucket: bucket)
        }
    }
}

/// A section's three orders as a picker, for the heading menu and a node's context menu.
struct PadSortPicker: View {
    let section: PadSortSection
    let model: PageModel

    var body: some View {
        // A closure literal: a function value for `set` crashed Xcode 26.6's IRGen (see PR 261).
        Picker(section.copy.label, selection: Binding(
            get: { section.direction }, set: { section.apply($0, to: model) })) {
            ForEach(PadSortCopy.orders, id: \.self) { order in
                Text(PadSortCopy(direction: order, subject: section.subject).currentOrder).tag(order)
            }
        }
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

    /// A row's height, the unit the shelf is measured in.
    nonisolated static let height: CGFloat = 27
    /// The room between two rows on the shelf.
    nonisolated static let spacing: CGFloat = 2

    /// The shelf's tallest: every row up to two, then two and a half, so a third row shows
    /// there is more to scroll to.
    nonisolated static func shelfHeight(rows: Int) -> CGFloat {
        let shown = min(CGFloat(max(0, rows)), 2.5)
        return shown * height + max(0, shown.rounded(.up) - 1) * spacing
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: "doc")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.secondaryInk)
                    .accessibilityHidden(true)
                Text(file.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ZStack {
                if file.holdsUnsavedEdits { UnsavedDot() }
            }
            .frame(height: 3)
            .padding(.horizontal, 3)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.cellBackground : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(target: .file(file.id)) }
        .help(FileRowLabel.help(for: file))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(FileRowLabel.spoken(for: file)))
        .accessibilityAddTraits(RowAccessibility.traits(selected: selected))
        .accessibilityActivation(when: true) { model.select(target: .file(file.id)) }
    }
}

/// The empty today node's tooltip, the one decision of the old rows the
/// navigator still asks (`StreamNavigator.help`); a page node's tooltip
/// is composed there. A namespace and no longer a view since the
/// navigator replaced the rail's rows; kept under its name so the tests
/// read as they did.
///
/// Internal rather than private so the wording can be tested without
/// a window, in the idiom `TabStripView.newPageHelp` and
/// `SheetTab.holdMenuTitle` set.
enum TimeUnitTab {
    /// Today holding no page is the one place where a click conjures
    /// something, and the tooltip says so rather than promising a page
    /// that does not exist; with nothing bound it says only what the
    /// click does, which is still true.
    nonisolated static func todayHelp(chord: Keystroke?) -> String {
        Keystroke.chorded("Start today's page", chord: chord)
    }
}
