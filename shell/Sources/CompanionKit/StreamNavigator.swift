import Foundation

/// The stream navigator: every live page as a checkpoint on one
/// vertical track down the rail, in the order the roll lays them out,
/// with the part of the roll the reader can see marked beside them.
///
/// It succeeds the rail's day rows and the faint minimap behind them
/// (issue #131) with one drawing instead of two. A day used to be a row
/// and its pages a bar behind the row, and the two did not line up,
/// because the rows were packed from the top while the bars were a
/// scaled impression of the roll. Here the node *is* the page: it sits
/// where the page's share of the roll puts it, nudged apart only as far
/// as its words need, and the viewport band is mapped through the same
/// node positions, so a band that covers a node covers the page under
/// the reader's eye.
///
/// Every decision is a pure function here and the view only draws:
/// which pages are nodes and in what order, which one is the first of
/// its day, how many empty days fall between two, where the seven day
/// window ends, where each node stands for a given rail height, where
/// the band and the line slivers fall, and what a click on bare track
/// scrolls to. In the idiom `TimeRailView.selectedBucket` and
/// `TimeUnitTab.target(for:)` set, so the whole navigator is under test
/// without a window.
///
/// What it never carries is text. `RollGeometry` hands it rectangles
/// (a page's span, a line's width) and it hands the view rectangles
/// back; the one string a node draws that the rail did not already
/// draw is the page's birth time.
public enum StreamNavigator {
    /// The longest rung on the ladder, in days. A page older than this
    /// is past every countdown the pad can run and stands on the roll
    /// because something kept it (a hold, a grace), so the navigator
    /// stops drawing it as time draining and says it is retained.
    public static let windowDays = 7

    /// What a node past the window says in place of a gauge.
    public static let retainedLabel = "7d+ · retained"

    /// One checkpoint on the stream: a page under its day, or the empty
    /// place today keeps while it holds no page.
    public struct Node: Equatable, Identifiable, Sendable {
        /// The page, or nil for today's empty place (ADR-0017).
        public let page: UInt64?
        /// The slot the page stands in, which a click selects, or nil
        /// for the empty place, whose click takes the create path.
        public let tab: UInt64?
        /// The day, 0 for today, as the projection counts them.
        public let bucket: Int
        /// Where the day sits in the projection's units, which is what
        /// the ⌘-number chords count.
        public let dayIndex: Int
        /// "Today", "Yesterday", "2 days ago": drawn on the first node
        /// of each day.
        public let dayLabel: String
        /// "today", "yesterday": what the tooltip and VoiceOver say.
        public let spokenDay: String
        /// The page's birth time, "11:39", or "11:39:12" where another
        /// page on the day shares the minute (`stamps`); empty for the
        /// empty place. The day is not repeated: it stands above the
        /// node in the day's words.
        public let stamp: String
        /// The page's title as the core resolves it (D-12), for the
        /// tooltip, when it is a name or a first line. Empty for the
        /// empty place and for a placeholder, which would only repeat
        /// the stamp the node already carries.
        public let title: String
        /// The first page on its day: drawn larger, with the day's
        /// words.
        public let firstOfDay: Bool
        /// The page the surface is showing.
        public let active: Bool
        /// Days between this node's day and the one above it that hold
        /// no drawn page, noted above the node.
        public let emptyDays: Int
        public let fractionRemaining: Double
        public let paused: Bool
        public let toppedUp: Bool
        public let lastHour: Bool
        /// The gauge as words, for VoiceOver and the gauge's tooltip.
        public let spokenRemaining: String

        /// Page ids are never zero (the seam's own assertion), so the
        /// empty place can take zero without colliding.
        public var id: UInt64 { page ?? 0 }
        public var hasPage: Bool { page != nil }
        /// Past the seven day window.
        public var trailing: Bool { StreamNavigator.isTrailing(bucket: bucket) }
        /// Where a click lands: the same answer the keyboard gets.
        public var target: SurfaceTarget { tab.map(SurfaceTarget.tab) ?? .today }
    }

    // MARK: The nodes

    /// The checkpoints, in the roll's order: the projection's days
    /// newest first, and within a day its pages in strip order. One
    /// node per page, plus one for an empty today, which is a place
    /// whether or not a page stands in it.
    ///
    /// `selection` is the selected slot, as `PageModel.selection` names
    /// it. A page node is active when its slot is the selection; the
    /// empty place is active only by elimination, when no drawn page
    /// holds the selection, the same rule `TimeRailView.selectedBucket`
    /// states for the old rows. With `surfaceShowsRoll` false (a file or
    /// the ledger has replaced the roll) no node is active at all: what
    /// is on screen is then not on the rail.
    public static func nodes(
        projection: TimeUnitProjection, tabs: [TabSummary], selection: UInt64?,
        surfaceShowsRoll: Bool = true, timeZone: TimeZone = .current,
        stampFormat: StampFormat = .standard
    ) -> [Node] {
        // The empty place lights by elimination only: on a pad where no
        // drawn day holds a page, there is nothing else the mark could
        // sit on and today is where the next page would land.
        let anyPageDrawn = projection.units.contains { !$0.pageIDs.isEmpty }
        var nodes: [Node] = []
        for (dayIndex, unit) in projection.units.enumerated() {
            let gap = nodes.last.map { emptyDays(between: $0.bucket, and: unit.bucket) } ?? 0
            guard !unit.pageIDs.isEmpty else {
                nodes.append(Node(
                    page: nil, tab: nil, bucket: unit.bucket, dayIndex: dayIndex,
                    dayLabel: unit.railLabel, spokenDay: unit.spokenLabel, stamp: "", title: "",
                    firstOfDay: true, active: surfaceShowsRoll && !anyPageDrawn,
                    emptyDays: gap,
                    fractionRemaining: 0, paused: false, toppedUp: false, lastHour: false,
                    spokenRemaining: ""
                ))
                continue
            }
            let summaries = unit.tabIDs.map { id in tabs.first { $0.id == id } }
            let stamps = stamps(
                createdMs: summaries.map { $0?.pageCreatedMs }, format: stampFormat,
                timeZone: timeZone)
            for (index, page) in unit.pageIDs.enumerated() {
                let tab = unit.tabIDs[index]
                let summary = summaries[index]
                nodes.append(Node(
                    page: page, tab: tab, bucket: unit.bucket, dayIndex: dayIndex,
                    dayLabel: unit.railLabel, spokenDay: unit.spokenLabel,
                    stamp: stamps[index],
                    title: title(of: summary),
                    firstOfDay: index == 0, active: surfaceShowsRoll && selection == tab,
                    emptyDays: index == 0 ? gap : 0,
                    fractionRemaining: summary?.fractionRemaining ?? 0,
                    paused: summary?.paused ?? false,
                    toppedUp: summary?.holdToppedUp ?? false,
                    lastHour: summary?.lastHour ?? false,
                    spokenRemaining: summary?.spokenRemaining ?? ""
                ))
            }
        }
        return nodes
    }

    /// A day past the window. Strictly past: the seventh day back is the
    /// last one a 7d rung can still be counting down on.
    public static func isTrailing(bucket: Int) -> Bool {
        bucket < -windowDays
    }

    /// The days with no drawn page between two consecutive nodes'
    /// days, counted where they fall. `above` is nearer today.
    ///
    /// The seven day mark is not an empty day, and the days past it
    /// belong to the retained stretch: between a page four days ago and
    /// one eight days ago, the two empty days are the fifth and sixth,
    /// and what lies past the seventh is drawn as the window's end
    /// rather than counted as absence.
    public static func emptyDays(between above: Int, and below: Int) -> Int {
        let last = !isTrailing(bucket: above) && isTrailing(bucket: below) ? -windowDays : below
        return max(0, above - last - 1)
    }

    /// "1 empty day", "2 empty days": the note above a node whose day
    /// does not follow the one above it.
    public static func emptyDaysLabel(_ count: Int) -> String {
        "\(count) empty day\(count == 1 ? "" : "s")"
    }

    /// How a page's birth time reads where its day is already said.
    /// The day's words stand above the node and on the day's first
    /// gutter, so the time stands alone, "11:39", and never repeats
    /// the date the way the core's "MMDD-HHmm" placeholder must, which
    /// has no day beside it. Two pages on one day born in the same
    /// minute would read alike, so those take the finer form,
    /// "11:39:12". Both patterns are the user's (Settings, under the
    /// Days choice); an empty pattern reads as the standard one.
    public struct StampFormat: Equatable, Sendable {
        /// The pattern every page reads in, Unicode date format syntax.
        public var short: String
        /// The pattern pages sharing a `short` reading fall back to.
        public var fine: String

        public static let standard = StampFormat(short: "HH:mm", fine: "HH:mm:ss")

        public init(short: String, fine: String) {
            self.short = short
            self.fine = fine
        }

        var shortPattern: String { short.isEmpty ? Self.standard.short : short }
        var finePattern: String { fine.isEmpty ? Self.standard.fine : fine }
    }

    /// The page's birth time in local time, in the pattern given. A
    /// pattern that formats to the empty string (pure literals, an
    /// unbalanced quote, anything DateFormatter refuses to render)
    /// falls through to the standard pattern of the same class as the
    /// caller's, on the same "empty means the standard one" rule
    /// `StampFormat` states for a blank pattern: the reader still gets
    /// a stamp rather than an empty gutter.
    public static func stamp(
        createdMs: UInt64, pattern: String = StampFormat.standard.short,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = StampFormatterCache.formatter(pattern: pattern, timeZone: timeZone)
        let date = Date(timeIntervalSince1970: Double(createdMs) / 1000)
        let reading = formatter.string(from: date)
        guard reading.isEmpty, pattern != StampFormat.standard.short else { return reading }
        let fallback = StampFormatterCache.formatter(
            pattern: StampFormat.standard.short, timeZone: timeZone)
        return fallback.string(from: date)
    }

    /// The stamps for one day's pages, in the day's order: the short
    /// form for each, and the fine form for every page whose short
    /// form another page on the same day also reads, so no two gutters
    /// or nodes under one day's words say the same thing. A page with
    /// no birth stamp reads as empty and collides with nothing. The one
    /// rule the rail and the roll both read, so a node and its gutter
    /// cannot disagree about a page's time.
    public static func stamps(
        createdMs: [UInt64?], format: StampFormat = .standard, timeZone: TimeZone = .current
    ) -> [String] {
        let short = createdMs.map { ms in
            ms.map { stamp(createdMs: $0, pattern: format.shortPattern, timeZone: timeZone) } ?? ""
        }
        var readings: [String: Int] = [:]
        for reading in short where !reading.isEmpty { readings[reading, default: 0] += 1 }
        return createdMs.indices.map { index in
            guard let ms = createdMs[index], readings[short[index], default: 0] > 1 else {
                return short[index]
            }
            return stamp(createdMs: ms, pattern: format.finePattern, timeZone: timeZone)
        }
    }

    /// The title a node carries for its tooltip: the core's label when
    /// it is a name or the page's first line, and nothing for a
    /// placeholder, which is the stamp again in the core's own shape.
    static func title(of summary: TabSummary?) -> String {
        guard let summary, summary.titleSource != .placeholder else { return "" }
        return summary.title
    }

    // MARK: What a node says

    /// The tooltip: the day and the minute, the chord that reaches the
    /// day when the keymap bound one, and the page's title on a second
    /// line. The affordance is revealed, the page is not: the title is
    /// the one line the gutter already shows.
    @MainActor
    public static func help(for node: Node, chord: Keystroke?) -> String {
        guard node.hasPage else { return TimeUnitTab.todayHelp(hasPage: false, chord: chord) }
        var first = "\(node.spokenDay) · \(node.stamp)"
        if let chord { first += " (\(chord.displaySymbol))" }
        guard !node.title.isEmpty else { return first }
        return "\(first)\n\(node.title)"
    }

    /// What VoiceOver reads for a node: which day, which minute, what
    /// the page is called, and that it is retained past the window
    /// when it is. The gauge rides the value, in words, beside it.
    public static func spoken(for node: Node) -> String {
        guard node.hasPage else { return "\(node.spokenDay), no page" }
        var parts = [node.spokenDay, node.stamp]
        if !node.title.isEmpty { parts.append(node.title) }
        if node.trailing { parts.append("past seven days, retained because it holds content") }
        return parts.joined(separator: ", ")
    }

    // MARK: Where the nodes stand

    /// The numbers the drawing is made of, in points. Read off the
    /// navigator mockup and kept together so the pure layout and the
    /// view agree on every one of them.
    public enum Metrics {
        /// The track's x, from the rail's leading edge.
        public static let trackX: CGFloat = 13
        /// Room above the first node and below the last.
        public static let top: CGFloat = 16
        public static let bottom: CGFloat = 10
        /// A day's first node carries its words; a later page on the
        /// same day carries its minute only.
        public static let firstRow: CGFloat = 30
        public static let row: CGFloat = 16
        /// The active node's gauge under its minute.
        public static let gaugeReserve: CGFloat = 8
        /// The retained words under a trailing node's minute.
        public static let trailingReserve: CGFloat = 14
        /// The empty days note above a node, and the seven day mark
        /// above the first trailing node, which must not stack tight.
        public static let gapBand: CGFloat = 21
        public static let gapBandAtWindow: CGFloat = 22
        public static let windowReserve: CGFloat = 14
        /// The line slivers start this far right of the track and stop
        /// this far short of the rail's edge.
        public static let sliverInset: CGFloat = 26
        public static let sliverTrailing: CGFloat = 8
        /// The least the viewport band is drawn as.
        public static let minimumBand: CGFloat = 6
        /// How far above a node's page a jump lands, so the gutter's
        /// rule is on screen.
        public static let jumpLead: CGFloat = 4
        /// A click on bare track lands the offset this far down the
        /// viewport, so the stretch clicked is read rather than kissed
        /// by the top edge.
        public static let trackLead: CGFloat = 0.3
        /// The gauge's width under the active node, the one place on
        /// the surface a page's remaining life is drawn while pages
        /// are organized by day.
        public static let gaugeWidth: CGFloat = 44
    }

    /// A node with its place on the rail.
    public struct Placed: Equatable, Identifiable, Sendable {
        public let node: Node
        /// The node's centre line, where its dot is drawn.
        public let y: CGFloat
        /// The row the node's words occupy, which slivers keep out of.
        public let rowTop: CGFloat
        public let rowHeight: CGFloat
        /// Where the empty days note is drawn, when there is one.
        public let noteY: CGFloat?
        /// The top of the page in the document, for the jump.
        public let documentTop: CGFloat

        public var id: UInt64 { node.id }
    }

    /// The part of the roll the reader can see, in rail coordinates.
    public struct Band: Equatable, Sendable {
        public let y: CGFloat
        public let height: CGFloat

        func contains(_ y: CGFloat) -> Bool {
            y >= self.y - 1 && y <= self.y + height + 1
        }
    }

    /// The stretch of track from the active node to the next.
    public struct Segment: Equatable, Sendable {
        public let y: CGFloat
        public let height: CGFloat
    }

    /// One line of a page as a sliver beside the track.
    public struct Sliver: Equatable, Identifiable, Sendable {
        /// The rounded rail row this sliver occupies. A cached document
        /// layout keeps it stable while only the viewport moves.
        public let id: Int
        public let y: CGFloat
        public let width: CGFloat
        /// Under the band: the lines the reader can see draw darker.
        public let inView: Bool
    }

    /// One point of the map from document offsets to rail y.
    public struct Anchor: Equatable, Sendable {
        public let document: CGFloat
        public let y: CGFloat
    }

    /// Everything the view draws, for one rail size and one measurement.
    public struct Layout: Equatable, Sendable {
        public let placed: [Placed]
        /// The track runs from here to the window's end or the foot.
        public let trackTop: CGFloat
        public let trackBottom: CGFloat
        /// Where the seven day window ends, when a node lies past it.
        public let windowY: CGFloat?
        public let band: Band?
        public let activeSegment: Segment?
        public let slivers: [Sliver]
        /// The rail height this document-proportional layout was prepared
        /// for. Viewport-only updates reuse it rather than accepting an
        /// unchecked height from a caller.
        let sourceHeight: CGFloat
        /// The map, kept so a click on bare track can be inverted.
        public let anchors: [Anchor]

        /// The document offset a rail y stands for: the map, inverted
        /// piece by piece.
        public func documentOffset(atY y: CGFloat) -> CGFloat {
            guard anchors.count >= 2 else { return 0 }
            for index in 1..<anchors.count {
                let a = anchors[index - 1], b = anchors[index]
                if y <= b.y {
                    let share = (y - a.y) / max(1, b.y - a.y)
                    return a.document + share * (b.document - a.document)
                }
            }
            return anchors[anchors.count - 1].document
        }

        /// Where a click on bare track scrolls the roll to: the offset
        /// under the click, led by a share of the viewport so the
        /// stretch clicked sits in the reader's eye rather than on the
        /// clip's top edge. Never above the document's top.
        public func jumpOffset(forTrackY y: CGFloat, viewportHeight: CGFloat) -> CGFloat {
            max(0, documentOffset(atY: y) - viewportHeight * Metrics.trackLead)
        }

        public static let empty = Layout(
            placed: [], trackTop: 0, trackBottom: 0, windowY: nil, band: nil,
            activeSegment: nil, slivers: [], sourceHeight: 0, anchors: []
        )
    }

    /// Where a click on a node scrolls the roll to: just above the
    /// page's gutter, and never above the document's top.
    public static func jumpOffset(forDocumentTop top: CGFloat) -> CGFloat {
        max(0, top - Metrics.jumpLead)
    }

    /// The drawing, decided.
    ///
    /// Each node starts where its page's share of the roll puts it
    /// (`top / documentHeight` of the column), then the nodes are
    /// pushed apart just far enough that no node's words overlap the
    /// next, from the top down, and pulled back up from the foot so the
    /// last one stays on the rail. A node reserves room above itself
    /// for its empty days note and, at the window, for the seven day
    /// mark. The map from document to rail then runs through the nodes
    /// as they were finally placed, so the band and the slivers are
    /// level with the nodes and not with the roll's raw proportions.
    ///
    /// An unmeasured roll has no proportions: every node starts at the
    /// top and the packing alone decides, which is where the nodes go
    /// for the pass between a roll mounting and its first layout. A
    /// roll with a height but no measured blocks, the publish between a
    /// height's capture and the extents' arrival, gets the rule any
    /// missing run gets: each node is interpolated between its measured
    /// neighbours or, with none, spread evenly between the document's
    /// ends, so the extents landing moves the nodes instead of
    /// unstacking them.
    public static func layout(
        nodes: [Node], geometry: RollGeometry, height: CGFloat, width: CGFloat
    ) -> Layout {
        guard height > 0, !nodes.isEmpty else { return .empty }
        let documentHeight = resolvedDocumentHeight(geometry)
        let document = max(1, documentHeight)
        let windowIndex = nodes.firstIndex(where: \.trailing)
        let documentTops = resolvedDocumentTops(
            nodes: nodes, geometry: geometry, documentHeight: documentHeight)
        var reserves: [CGFloat] = []
        var gapBands: [CGFloat] = []
        var heights: [CGFloat] = []
        for (index, node) in nodes.enumerated() {
            let atWindow = index == windowIndex
            let gapBand = node.emptyDays > 0
                ? (atWindow ? Metrics.gapBandAtWindow : Metrics.gapBand) : 0
            let reserve = gapBand + (atWindow ? Metrics.windowReserve : 0)
            var rowHeight = node.firstOfDay ? Metrics.firstRow : Metrics.row
            if node.active, !node.trailing, node.hasPage { rowHeight += Metrics.gaugeReserve }
            if node.trailing { rowHeight += Metrics.trailingReserve }
            gapBands.append(gapBand)
            reserves.append(reserve)
            heights.append(rowHeight + reserve)
        }
        let span = height - Metrics.top - Metrics.bottom
        var ys = documentTops.map { Metrics.top + ($0 / document) * span }
        for index in 1..<ys.count {
            ys[index] = max(ys[index], ys[index - 1] + heights[index - 1])
        }
        let limit = height - Metrics.bottom
        for index in ys.indices.reversed() {
            let cap = index == ys.count - 1
                ? limit - heights[index] : ys[index + 1] - heights[index]
            ys[index] = min(ys[index], cap)
        }
        let nodeYs = ys.indices.map { ys[$0] + reserves[$0] }

        let anchors = [Anchor(document: 0, y: Metrics.top - 8)]
            + nodeYs.indices.map { Anchor(document: documentTops[$0], y: nodeYs[$0]) }
            + [Anchor(document: document, y: limit)]
        let map = { (offset: CGFloat) -> CGFloat in
            railY(forDocumentOffset: offset, anchors: anchors, trackBottom: limit)
        }

        let placed = nodes.indices.map { index in
            Placed(
                node: nodes[index], y: nodeYs[index],
                rowTop: nodeYs[index] - 8, rowHeight: heights[index] - reserves[index],
                noteY: nodes[index].emptyDays > 0 ? ys[index] + 1 : nil,
                documentTop: documentTops[index]
            )
        }

        let band = band(anchors: anchors, trackBottom: limit, geometry: geometry, height: height)

        var segment: Segment?
        if let active = nodes.firstIndex(where: \.active) {
            let from = nodeYs[active]
            let to = active + 1 < nodeYs.count ? nodeYs[active + 1] : limit
            segment = Segment(y: from, height: max(2, to - from))
        }

        let windowY = windowIndex.map { ys[$0] + gapBands[$0] + 2 }

        let available = width - Metrics.trackX - Metrics.sliverInset - Metrics.sliverTrailing
        var slivers: [Int: Sliver] = [:]
        if available > 2 {
            // A node's words, and the note and the mark reserved above
            // them, are ground no sliver may cross.
            let rows = placed.indices.map {
                (min(ys[$0], placed[$0].rowTop), placed[$0].rowTop + placed[$0].rowHeight)
            }
            for extent in geometry.extents {
                for line in extent.lines {
                    // Whole points: a one point sliver is drawn on a
                    // point, and two lines landing on the same one are
                    // one sliver.
                    let y = map(line.y).rounded()
                    if rows.contains(where: { y >= $0.0 && y <= $0.1 }) { continue }
                    let key = Int(y)
                    let sliver = Sliver(
                        id: key,
                        y: y,
                        width: 2 + min(1, max(0, line.width)) * (available - 2),
                        inView: band?.contains(y) ?? false
                    )
                    if let seen = slivers[key], seen.width >= sliver.width { continue }
                    slivers[key] = sliver
                }
            }
        }

        return Layout(
            placed: placed,
            trackTop: Metrics.top - 8,
            trackBottom: limit,
            windowY: windowY,
            band: band,
            activeSegment: segment,
            slivers: slivers.values.sorted { $0.y < $1.y },
            sourceHeight: height,
            anchors: anchors
        )
    }

    /// Reapply only the viewport-dependent half of a prepared document
    /// layout. Node placement, anchors, line mapping, collision removal,
    /// and sliver widths remain unchanged while the clip moves.
    static func updatingViewport(
        in layout: Layout, geometry: RollGeometry
    ) -> Layout {
        let band = band(
            anchors: layout.anchors, trackBottom: layout.trackBottom,
            geometry: geometry, height: layout.sourceHeight)
        let slivers = layout.slivers.map { sliver in
            Sliver(
                id: sliver.id, y: sliver.y, width: sliver.width,
                inView: band?.contains(sliver.y) ?? false)
        }
        return Layout(
            placed: layout.placed,
            trackTop: layout.trackTop,
            trackBottom: layout.trackBottom,
            windowY: layout.windowY,
            band: band,
            activeSegment: layout.activeSegment,
            slivers: slivers,
            sourceHeight: layout.sourceHeight,
            anchors: layout.anchors
        )
    }

    /// Where a document offset falls on the rail: the map through the
    /// anchors, piece by piece, and the track's foot for anything past
    /// the last one.
    private static func railY(
        forDocumentOffset offset: CGFloat, anchors: [Anchor], trackBottom: CGFloat
    ) -> CGFloat {
        guard anchors.count >= 2 else { return trackBottom }
        for index in 1..<anchors.count {
            let a = anchors[index - 1], b = anchors[index]
            if offset <= b.document {
                let share = (offset - a.document) / max(1, b.document - a.document)
                return a.y + share * (b.y - a.y)
            }
        }
        return trackBottom
    }

    /// The band over the clip's window, mapped through the anchors as
    /// the nodes were placed. Absent when the whole roll is on screen,
    /// never thinner than the minimum, and clamped into the rail when
    /// the clip is in the elastic. The one rule for the first drawing
    /// and for every viewport-only update after it.
    private static func band(
        anchors: [Anchor], trackBottom: CGFloat, geometry: RollGeometry, height: CGFloat
    ) -> Band? {
        let document = resolvedDocumentHeight(geometry)
        guard anchors.count >= 2, document > 0, geometry.viewportHeight > 0,
            geometry.viewportHeight < document
        else { return nil }
        let map = { (offset: CGFloat) -> CGFloat in
            railY(forDocumentOffset: offset, anchors: anchors, trackBottom: trackBottom)
        }
        let top = map(max(0, geometry.viewportTop))
        let bottom = map(min(document, geometry.viewportTop + geometry.viewportHeight))
        let drawn = max(Metrics.minimumBand, bottom - top)
        return Band(y: min(max(0, top), height - drawn), height: drawn)
    }

    /// Resolve transient gaps in the measured extents without sending a
    /// later node back to document zero. Missing runs are interpolated
    /// between their measured neighbours, or between a neighbour and the
    /// document boundary, then clamped into nondecreasing order. A run
    /// with no measured neighbour at all spans the whole document, so a
    /// roll with a height and no extents yet spreads its nodes evenly
    /// rather than stacking them at zero.
    private static func resolvedDocumentHeight(_ geometry: RollGeometry) -> CGFloat {
        max(max(geometry.documentHeight, geometry.extents.map(\.bottom).max() ?? 0), 0)
    }

    private static func resolvedDocumentTops(
        nodes: [Node], geometry: RollGeometry, documentHeight: CGFloat
    ) -> [CGFloat] {
        var measured: [CGFloat?] = nodes.map { node in
            geometry.extents.first {
                $0.page == node.page && $0.bucket == node.bucket
            }?.top
        }
        var start = 0
        while start < measured.count {
            guard measured[start] == nil else {
                start += 1
                continue
            }
            var end = start
            while end < measured.count, measured[end] == nil { end += 1 }

            let lowerIndex = start == 0 ? 0 : start - 1
            let lower = measured[..<start].compactMap { $0 }.last ?? 0
            let upperIndex = end
            let upper = measured[end...].compactMap { $0 }.first ?? documentHeight
            let span = max(upperIndex - lowerIndex, 1)
            for index in start..<end {
                let share = CGFloat(index - lowerIndex) / CGFloat(span)
                measured[index] = lower + share * (upper - lower)
            }
            start = end
        }

        let ceiling = documentHeight
        var floor: CGFloat = 0
        return measured.map { candidate in
            let top = min(max(candidate ?? floor, floor), ceiling)
            floor = top
            return top
        }
    }

    /// How long a jump takes: the stance's own 160 ms, and nothing at
    /// all for a reader who asked for less motion, which is the one
    /// motion rule the surface has (D-02).
    public static func jumpDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : 0.16
    }
}

/// One `DateFormatter` per (pattern, timeZone.identifier), so the rail
/// and the roll do not allocate a formatter every second per node
/// (Claude #6). `DateFormatter` is thread-safe once configured for the
/// read side; the cache guards the shared dictionary with a lock, since
/// `stamp` is non-isolated and reads run from both the SwiftUI body and
/// the assembly pass.
private enum StampFormatterCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    static func formatter(pattern: String, timeZone: TimeZone) -> DateFormatter {
        let key = "\(timeZone.identifier)\u{1F}\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let made = DateFormatter()
        made.locale = Locale(identifier: "en_US_POSIX")
        made.timeZone = timeZone
        made.dateFormat = pattern
        cache[key] = made
        return made
    }
}
