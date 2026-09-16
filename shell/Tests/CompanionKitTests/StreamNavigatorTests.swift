import XCTest

@testable import CompanionKit

/// The stream navigator's decisions (the successor to issue #131's
/// minimap): which pages are nodes and in what order, what each says,
/// where it stands for a given rail height, where the band and the
/// slivers fall, and what a click scrolls to.
///
/// A navigator is a drawing, and drawings are hardware verification's
/// business (docs/qa/hardware-verification.md). What is here is
/// everything that was kept out of the drawing, as measurements in and
/// shapes out, with no window anywhere.
@MainActor
final class StreamNavigatorTests: XCTestCase {
    /// 2025-09-14 11:39:00 UTC, the minute the mockup's first
    /// checkpoint was made.
    private let born: UInt64 = 1_757_849_940_000
    private let utc = TimeZone(identifier: "UTC")!

    private func slot(
        tab: UInt64, page: UInt64? = nil, day: Int = 0, title: String = "",
        titleSource: TitleSource = .derived,
        createdMs: UInt64? = nil, fraction: Double = 0.5, paused: Bool = false
    ) -> TabSummary {
        TabSummary(
            id: tab,
            hasPage: page != nil,
            pageID: page,
            title: title,
            titleSource: titleSource,
            rungCode: 5,
            rungLabel: "7d",
            remainingMs: page == nil ? 0 : 3_600_000,
            remainingLabel: page == nil ? "" : "1h",
            spokenRemaining: page == nil ? "" : "one hour",
            fractionRemaining: page == nil ? 0 : fraction,
            paused: paused,
            holdToppedUp: false,
            holdRemainingMs: 0,
            chipCount: 0,
            lastHour: false,
            pageHasContent: page != nil,
            pageDayOffset: page == nil ? nil : day,
            pageCreatedMs: page == nil ? nil : (createdMs ?? born)
        )
    }

    private func nodes(
        _ tabs: [TabSummary], selecting tab: UInt64? = nil, showsRoll: Bool = true,
        stampFormat: StreamNavigator.StampFormat = .standard
    ) -> [StreamNavigator.Node] {
        let projection = TimeUnitProjection.project(
            tabs: tabs, selectedPageID: nil, unit: .day)
        return StreamNavigator.nodes(
            projection: projection, tabs: tabs, selection: tab,
            surfaceShowsRoll: showsRoll, timeZone: utc, stampFormat: stampFormat)
    }

    private func extent(
        _ node: StreamNavigator.Node, top: CGFloat, height: CGFloat,
        lines: [RollGeometry.LineMark] = []
    ) -> RollGeometry.Extent {
        RollGeometry.Extent(
            bucket: node.bucket, page: node.page, top: top, height: height, lines: lines)
    }

    // MARK: The nodes

    /// One node per page in the roll's order, the first page of each
    /// day carrying the day's words, every page carrying its time and
    /// never the date the day's words already say.
    func testEveryPageIsANodeAndOnlyADaysFirstCarriesTheDay() {
        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0, title: "stdout sync"),
            slot(tab: 2, page: 22, day: 0, createdMs: born + 16 * 60_000),
            slot(tab: 3, page: 33, day: -1),
        ])
        XCTAssertEqual(nodes.map(\.page), [11, 22, 33])
        XCTAssertEqual(nodes.map(\.firstOfDay), [true, false, true])
        XCTAssertEqual(nodes.map(\.dayLabel), ["Today", "Today", "Yesterday"])
        XCTAssertEqual(nodes.map(\.stamp), ["11:39", "11:55", "11:39"])
        XCTAssertEqual(nodes.map(\.title), ["stdout sync", "", ""])
        XCTAssertEqual(nodes.map(\.target), [.tab(1), .tab(2), .tab(3)])
    }

    /// The stamp is the page's birth time in the zone it is read in,
    /// "HH:mm" and never "HHmm", in whatever pattern the caller names.
    func testTheStampIsTheBirthTimeInLocalTime() {
        XCTAssertEqual(StreamNavigator.stamp(createdMs: born, timeZone: utc), "11:39")
        XCTAssertEqual(
            StreamNavigator.stamp(
                createdMs: born, timeZone: TimeZone(identifier: "America/Vancouver")!),
            "04:39")
        XCTAssertEqual(
            StreamNavigator.stamp(createdMs: born, pattern: "h:mm a", timeZone: utc), "11:39 AM")
    }

    /// Two pages on one day born in the same minute would read alike,
    /// so those two read to the second while the rest of the day keeps
    /// the minute; a page on another day sharing the minute is told
    /// apart by its day's words and stays short. The empty place has
    /// no stamp and collides with nothing.
    func testPagesSharingAMinuteReadToTheSecond() {
        let tabs = [
            slot(tab: 1, page: 11, day: 0, createdMs: born + 12_000),
            slot(tab: 2, page: 22, day: 0, createdMs: born + 48_000),
            slot(tab: 3, page: 33, day: 0, createdMs: born + 61_000),
            slot(tab: 4, page: 44, day: -1, createdMs: born + 12_000),
        ]
        XCTAssertEqual(
            nodes(tabs).map(\.stamp), ["11:39:12", "11:39:48", "11:40", "11:39"])
        XCTAssertEqual(
            StreamNavigator.stamps(createdMs: [born, nil, born + 30_000], timeZone: utc),
            ["11:39:00", "", "11:39:30"])
        XCTAssertEqual(StreamNavigator.stamps(createdMs: [], timeZone: utc), [])
    }

    /// Both patterns are the user's; an empty one reads as the standard.
    func testTheStampPatternsAreSettingsWithTheStandardBehindThem() {
        let twelveHour = StreamNavigator.StampFormat(short: "h:mm a", fine: "h:mm:ss a")
        XCTAssertEqual(
            StreamNavigator.stamps(
                createdMs: [born, born + 5_000, born + 90_000], format: twelveHour,
                timeZone: utc),
            ["11:39:00 AM", "11:39:05 AM", "11:40 AM"])
        let blank = StreamNavigator.StampFormat(short: "", fine: "")
        XCTAssertEqual(
            StreamNavigator.stamps(createdMs: [born, born + 5_000], format: blank, timeZone: utc),
            ["11:39:00", "11:39:05"])
        XCTAssertEqual(
            nodes([slot(tab: 1, page: 11)], stampFormat: twelveHour).map(\.stamp), ["11:39 AM"])
    }

    /// A pattern the formatter cannot render (pure literals, an
    /// unbalanced quote) falls through to the standard short pattern
    /// on the same "empty means the standard one" rule a blank pattern
    /// takes, so a broken setting still shows a stamp rather than an
    /// empty gutter.
    func testAMalformedPatternFallsThroughToTheStandardStamp() {
        let standard = StreamNavigator.stamp(createdMs: born, timeZone: utc)
        XCTAssertEqual(
            StreamNavigator.stamp(createdMs: born, pattern: "'", timeZone: utc), standard)
    }

    /// A `fine` pattern coarser than the birth resolution (say a `HH`
    /// short paired with a `HH:mm` fine, where two same-hour pages
    /// differ by many minutes) escalates to the fine reading, which is
    /// already distinct across the group; no further tiebreak needed.
    func testCoarseShortEscalatesToTheFineWhenItReadsThemApart() {
        let format = StreamNavigator.StampFormat(short: "HH", fine: "HH:mm")
        let readings = StreamNavigator.stamps(
            createdMs: [born, born + 16 * 60_000], format: format, timeZone: utc)
        XCTAssertEqual(readings, ["11:39", "11:55"])
        XCTAssertNotEqual(readings[0], readings[1])
    }

    /// A `fine` pattern that reads the same as the `short` (or that is
    /// still coarser than the birth resolution) leaves same-minute
    /// pages colliding after the escalation, so the standard fine
    /// `HH:mm:ss` is a final tiebreaker for exactly that case.
    func testACoarseFinePatternFallsThroughToTheStandardFine() {
        let format = StreamNavigator.StampFormat(short: "HH:mm", fine: "HH:mm")
        let readings = StreamNavigator.stamps(
            createdMs: [born + 12_000, born + 48_000], format: format, timeZone: utc)
        XCTAssertEqual(readings, ["11:39:12", "11:39:48"])
    }

    /// A placeholder title is the stamp again in the core's own shape,
    /// so a node carries none and its tooltip has no second line; a
    /// typed name and a first line are carried.
    func testAPlaceholderTitleIsNotCarriedTwice() throws {
        let nodes = nodes([
            slot(tab: 1, page: 11, title: "0914-1139", titleSource: .placeholder),
            slot(tab: 2, page: 22, title: "the vault", titleSource: .name, createdMs: born + 60_000),
            slot(
                tab: 3, page: 33, title: "stdout sync", titleSource: .derived,
                createdMs: born + 120_000),
        ])
        XCTAssertEqual(nodes.map(\.title), ["", "the vault", "stdout sync"])
        let placeholder = try XCTUnwrap(nodes.first)
        XCTAssertEqual(StreamNavigator.help(for: placeholder, chord: nil), "today · 11:39")
        XCTAssertEqual(StreamNavigator.spoken(for: placeholder), "today, 11:39")
    }

    /// Today with no page is a node with no minute, and the one node
    /// whose click takes the create path.
    func testAnEmptyTodayIsANodeWithNoMinute() throws {
        let node = try XCTUnwrap(nodes([]).first)
        XCTAssertNil(node.page)
        XCTAssertEqual(node.stamp, "")
        XCTAssertTrue(node.firstOfDay)
        XCTAssertEqual(node.target, .today)
        XCTAssertEqual(StreamNavigator.spoken(for: node), "today, no page")
    }

    /// The active node is the selected slot's, and the empty place is
    /// active only by elimination; with the roll replaced by a file or
    /// the ledger nothing is active at all.
    func testTheActiveNodeFollowsTheSelection() {
        let tabs = [slot(tab: 1, page: 11, day: 0), slot(tab: 2, page: 22, day: -2)]
        XCTAssertEqual(nodes(tabs, selecting: 2).map(\.active), [false, true])
        XCTAssertEqual(nodes(tabs, selecting: 1).map(\.active), [true, false])
        XCTAssertEqual(nodes(tabs, selecting: 9).map(\.active), [false, false],
            "a slot the rail does not draw lit a node anyway")
        XCTAssertEqual(nodes(tabs, selecting: 2, showsRoll: false).map(\.active), [false, false])

        XCTAssertEqual(nodes([slot(tab: 5)], selecting: 5).map(\.active), [true],
            "the empty place did not light on a pad with no drawn page")
        XCTAssertEqual(
            nodes([slot(tab: 5), slot(tab: 6, page: 66, day: -1)], selecting: 5).map(\.active),
            [false, false])
    }

    /// Days with no drawn page are counted where they fall, above the
    /// node they precede, and the seven day mark is not an empty day.
    func testEmptyDaysAreCountedWhereTheyFall() {
        XCTAssertEqual(StreamNavigator.emptyDays(between: 0, and: -1), 0)
        XCTAssertEqual(StreamNavigator.emptyDays(between: -1, and: -4), 2)
        XCTAssertEqual(StreamNavigator.emptyDays(between: 0, and: -7), 6)
        XCTAssertEqual(
            StreamNavigator.emptyDays(between: -4, and: -8), 2,
            "the days past the window were counted as empty")
        XCTAssertEqual(
            StreamNavigator.emptyDays(between: -8, and: -12), 3,
            "two retained pages lost the days between them")
        XCTAssertFalse(StreamNavigator.isTrailing(bucket: -7))
        XCTAssertTrue(StreamNavigator.isTrailing(bucket: -8))

        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: 0),
            slot(tab: 3, page: 33, day: -3),
            slot(tab: 4, page: 44, day: -9),
        ])
        XCTAssertEqual(nodes.map(\.emptyDays), [0, 0, 2, 3])
        XCTAssertEqual(nodes.map(\.trailing), [false, false, false, true])
        XCTAssertEqual(StreamNavigator.emptyDaysLabel(1), "1 empty day")
        XCTAssertEqual(StreamNavigator.emptyDaysLabel(2), "2 empty days")
    }

    // MARK: What a node says

    /// The tooltip names the day and the minute, the chord when one is
    /// bound, and the page's title on its own line; the empty place
    /// says what its click makes. VoiceOver hears the same facts and,
    /// past the window, that the page is retained.
    func testTheTooltipAndTheSpokenLabelSayTheSameFacts() throws {
        let page = try XCTUnwrap(nodes([slot(tab: 1, page: 11, title: "stdout sync")]).first)
        XCTAssertEqual(StreamNavigator.help(for: page, chord: nil), "today · 11:39\nstdout sync")
        let chord = try Keystroke.parse("cmd-1").get()
        XCTAssertEqual(
            StreamNavigator.help(for: page, chord: chord),
            "today · 11:39 (\(chord.displaySymbol))\nstdout sync")
        XCTAssertEqual(StreamNavigator.spoken(for: page), "today, 11:39, stdout sync")

        let untitled = try XCTUnwrap(nodes([slot(tab: 1, page: 11)]).first)
        XCTAssertEqual(StreamNavigator.help(for: untitled, chord: nil), "today · 11:39")

        let empty = try XCTUnwrap(nodes([]).first)
        XCTAssertEqual(StreamNavigator.help(for: empty, chord: nil), "Start today's page")

        let retained = try XCTUnwrap(nodes([slot(tab: 1, page: 11, day: -8)]).last)
        XCTAssertEqual(
            StreamNavigator.spoken(for: retained),
            "8 days ago, 11:39, past seven days, retained because it holds content")
    }

    /// The gutter's words are the day and the time on a day's first
    /// page, the time alone on the pages under it, the day alone for
    /// the empty place, and the retained words past the window.
    func testTheGutterSaysTheDayOnceAndTheTimeOnEveryPage() {
        XCTAssertEqual(
            DayHeaderView.dayText(spokenLabel: "today", stamp: "11:39"), "today · 11:39")
        XCTAssertEqual(
            DayHeaderView.dayText(spokenLabel: "today", stamp: "11:55", firstOfDay: false),
            "11:55")
        XCTAssertEqual(DayHeaderView.dayText(spokenLabel: "today", stamp: nil), "today")
        XCTAssertEqual(DayHeaderView.dayText(spokenLabel: "today", stamp: ""), "today")
        XCTAssertEqual(
            DayHeaderView.dayText(spokenLabel: "today", stamp: nil, firstOfDay: false), "today")
        XCTAssertEqual(DayHeaderView.retainedText(pageDayOffset: -3), "")
        XCTAssertEqual(DayHeaderView.retainedText(pageDayOffset: nil), "")
        XCTAssertEqual(
            DayHeaderView.retainedText(pageDayOffset: -8), StreamNavigator.retainedLabel)
    }

    // MARK: Where the nodes stand

    /// An unmeasured roll has no proportions, so the nodes pack from
    /// the top, in order, none overlapping the next and none past the
    /// foot; there is no band and no sliver to draw.
    func testAnUnmeasuredRollPacksTheNodesFromTheTop() {
        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: 0),
            slot(tab: 3, page: 33, day: -1),
        ], selecting: 1)
        let layout = StreamNavigator.layout(
            nodes: nodes, geometry: .unmeasured, height: 300, width: 102)
        XCTAssertEqual(layout.placed.map(\.id), [11, 22, 33])
        XCTAssertEqual(layout.placed[0].y, StreamNavigator.Metrics.top)
        assertLaidOutInOrder(layout, height: 300)
        XCTAssertNil(layout.band)
        XCTAssertEqual(layout.slivers, [])
        XCTAssertNil(layout.windowY)
        XCTAssertEqual(
            layout.activeSegment?.y, layout.placed[0].y, "the active stretch did not start at its node")
        XCTAssertEqual(StreamNavigator.layout(
            nodes: nodes, geometry: .unmeasured, height: 0, width: 102), .empty)
        XCTAssertEqual(StreamNavigator.layout(
            nodes: [], geometry: .unmeasured, height: 300, width: 102), .empty)
    }

    /// A measured roll puts each node where its page's share of the
    /// roll falls, and the map from document to rail runs through the
    /// nodes as placed: a node's own y answers back its page's top, and
    /// the band covers the clip's window.
    func testTheNodesStandWhereTheirPagesFallAndTheMapRunsThroughThem() throws {
        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -1),
            slot(tab: 3, page: 33, day: -2),
        ], selecting: 2)
        let geometry = RollGeometry(
            extents: [
                extent(nodes[0], top: 0, height: 500),
                extent(nodes[1], top: 500, height: 400),
                extent(nodes[2], top: 900, height: 100),
            ],
            documentHeight: 1000, viewportTop: 450, viewportHeight: 300)
        let layout = StreamNavigator.layout(
            nodes: nodes, geometry: geometry, height: 300, width: 102)

        assertLaidOutInOrder(layout, height: 300)
        XCTAssertEqual(layout.placed[0].y, StreamNavigator.Metrics.top)
        XCTAssertGreaterThan(layout.placed[1].y, 120, "the second node ignored its page's share")
        XCTAssertEqual(layout.placed[1].documentTop, 500)
        XCTAssertEqual(layout.documentOffset(atY: layout.placed[1].y), 500, accuracy: 0.5)
        XCTAssertEqual(layout.documentOffset(atY: layout.trackTop), 0, accuracy: 0.5)
        XCTAssertEqual(layout.documentOffset(atY: layout.trackBottom), 1000, accuracy: 0.5)
        XCTAssertEqual(
            layout.jumpOffset(forTrackY: layout.placed[1].y, viewportHeight: 300), 410, accuracy: 0.5,
            "a click on the track did not lead the offset by a share of the viewport")
        XCTAssertEqual(layout.jumpOffset(forTrackY: layout.trackTop, viewportHeight: 300), 0)

        let band = try XCTUnwrap(layout.band)
        XCTAssertLessThan(band.y, layout.placed[1].y, "the band began under the page it covers")
        XCTAssertGreaterThan(band.y + band.height, layout.placed[1].y,
            "the band ended above the page it covers")
        XCTAssertGreaterThanOrEqual(band.height, StreamNavigator.Metrics.minimumBand)

        let segment = try XCTUnwrap(layout.activeSegment)
        XCTAssertEqual(segment.y, layout.placed[1].y)
        XCTAssertEqual(segment.y + segment.height, layout.placed[2].y, accuracy: 0.5)
    }

    /// A transiently missing measurement must not send its node back to
    /// document zero. Interpolate between the surrounding measured pages
    /// so both the node tops and the inverse map remain monotonic.
    func testAMissingMiddleExtentIsInterpolatedWithoutReversingAnchors() {
        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -1),
            slot(tab: 3, page: 33, day: -2),
        ])
        let geometry = RollGeometry(
            extents: [
                extent(nodes[0], top: 0, height: 400),
                extent(nodes[2], top: 800, height: 200),
            ],
            documentHeight: 1000, viewportTop: 0, viewportHeight: 300)

        let layout = StreamNavigator.layout(
            nodes: nodes, geometry: geometry, height: 300, width: 102)

        XCTAssertEqual(layout.placed.map(\.documentTop), [0, 400, 800])
        XCTAssertEqual(layout.anchors.map(\.document), layout.anchors.map(\.document).sorted())
        XCTAssertEqual(
            layout.documentOffset(atY: layout.placed[1].y), 400, accuracy: 0.5,
            "the inverse map did not run through the interpolated middle page")
    }

    /// The band is absent when the whole roll is on screen, and clamps
    /// into the rail when the clip is in the elastic.
    func testTheBandIsAbsentWhenTheWholeRollIsOnScreenAndClampsOtherwise() throws {
        let nodes = nodes([slot(tab: 1, page: 11, day: 0)])
        let short = RollGeometry(
            extents: [extent(nodes[0], top: 0, height: 200)],
            documentHeight: 200, viewportTop: 0, viewportHeight: 300)
        XCTAssertNil(StreamNavigator.layout(
            nodes: nodes, geometry: short, height: 300, width: 102).band)

        let elastic = RollGeometry(
            extents: [extent(nodes[0], top: 0, height: 1000)],
            documentHeight: 1000, viewportTop: -40, viewportHeight: 300)
        let band = try XCTUnwrap(StreamNavigator.layout(
            nodes: nodes, geometry: elastic, height: 300, width: 102).band)
        XCTAssertGreaterThanOrEqual(band.y, 0)
        XCTAssertLessThanOrEqual(band.y + band.height, 300)
    }

    /// A node past the window puts the seven day mark above itself,
    /// under the empty days note, and the mark sits between the last
    /// counting node and the first retained one.
    func testTheWindowsEndIsMarkedAboveTheFirstRetainedNode() throws {
        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -3),
            slot(tab: 3, page: 33, day: -9),
        ])
        let layout = StreamNavigator.layout(
            nodes: nodes, geometry: .unmeasured, height: 400, width: 102)
        let windowY = try XCTUnwrap(layout.windowY)
        XCTAssertGreaterThan(windowY, layout.placed[1].y)
        XCTAssertLessThan(windowY, layout.placed[2].y)
        let note = try XCTUnwrap(layout.placed[2].noteY)
        XCTAssertLessThan(note, windowY, "the empty days note sat under the seven day mark")
        XCTAssertNotNil(layout.placed[1].noteY)
        XCTAssertNil(layout.placed[0].noteY)
        assertLaidOutInOrder(layout, height: 400)
    }

    /// The slivers are the pages' lines mapped through the nodes: one
    /// per laid-out line, none across a node's words, the ones under the
    /// band marked as in view, and two lines landing on one point drawn
    /// once at the wider of the two.
    func testTheSliversFollowTheLinesAndKeepOutOfTheNodes() throws {
        let nodes = nodes([slot(tab: 1, page: 11, day: 0), slot(tab: 2, page: 22, day: -1)],
            selecting: 1)
        let lines = stride(from: 40, through: 480, by: 40).map {
            RollGeometry.LineMark(y: CGFloat($0), width: CGFloat($0) / 480)
        }
        let geometry = RollGeometry(
            extents: [
                extent(nodes[0], top: 0, height: 500, lines: lines),
                extent(nodes[1], top: 500, height: 500, lines: [
                    RollGeometry.LineMark(y: 700, width: 0.2),
                    RollGeometry.LineMark(y: 700.2, width: 0.9),
                ]),
            ],
            documentHeight: 1000, viewportTop: 0, viewportHeight: 250)
        let layout = StreamNavigator.layout(
            nodes: nodes, geometry: geometry, height: 400, width: 102)

        XCTAssertFalse(layout.slivers.isEmpty)
        let available = 102 - StreamNavigator.Metrics.trackX
            - StreamNavigator.Metrics.sliverInset - StreamNavigator.Metrics.sliverTrailing
        for sliver in layout.slivers {
            XCTAssertGreaterThanOrEqual(sliver.width, 2)
            XCTAssertLessThanOrEqual(sliver.width, available)
            for placed in layout.placed {
                XCTAssertFalse(
                    sliver.y >= placed.rowTop && sliver.y <= placed.rowTop + placed.rowHeight,
                    "a sliver crossed a node's words at \(sliver.y)")
            }
        }
        XCTAssertEqual(layout.slivers.map(\.y), layout.slivers.map(\.y).sorted())
        let band = try XCTUnwrap(layout.band)
        XCTAssertTrue(layout.slivers.contains { $0.inView && band.contains($0.y) })
        XCTAssertTrue(layout.slivers.contains { !$0.inView })
        let doubled = layout.slivers.filter { $0.y > layout.placed[1].y }
        XCTAssertEqual(doubled.count, 1, "two lines on one point drew twice")
        XCTAssertEqual(doubled[0].width, 2 + 0.9 * (available - 2), accuracy: 0.01)
    }

    /// A viewport-only update retains every document-proportional result
    /// and every sliver identity while moving only the band and emphasis.
    func testViewportUpdateReusesPreparedDocumentLayout() {
        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -1),
        ])
        let document = RollGeometry.Document(
            extents: [
                extent(nodes[0], top: 0, height: 500, lines: [
                    RollGeometry.LineMark(y: 300, width: 0.4),
                ]),
                extent(nodes[1], top: 500, height: 500, lines: [
                    RollGeometry.LineMark(y: 700, width: 0.8),
                ]),
            ],
            height: 1000,
            revision: 9
        )
        let before = RollGeometry(document: document, viewportTop: 0, viewportHeight: 250)
        let after = RollGeometry(document: document, viewportTop: 600, viewportHeight: 250)
        let prepared = StreamNavigator.layout(
            nodes: nodes, geometry: before, height: 400, width: 102)
        let updated = StreamNavigator.updatingViewport(
            in: prepared, geometry: after)

        XCTAssertEqual(updated.placed, prepared.placed)
        XCTAssertEqual(updated.anchors, prepared.anchors)
        XCTAssertEqual(updated.slivers.map(\.id), prepared.slivers.map(\.id))
        XCTAssertEqual(updated.slivers.map(\.y), prepared.slivers.map(\.y))
        XCTAssertNotEqual(updated.band, prepared.band)
        XCTAssertNotEqual(updated.slivers.map(\.inView), prepared.slivers.map(\.inView))
    }

    /// A viewport-only update is the same drawing a fresh layout at
    /// that viewport would make: the band and the slivers' emphasis
    /// come from one rule, whichever path asked for them.
    func testAViewportUpdateEqualsAFreshLayoutAtThatViewport() {
        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -1),
            slot(tab: 3, page: 33, day: -2),
        ], selecting: 2)
        let document = RollGeometry.Document(
            extents: [
                extent(nodes[0], top: 0, height: 500, lines: [
                    RollGeometry.LineMark(y: 300, width: 0.4),
                ]),
                extent(nodes[1], top: 500, height: 400, lines: [
                    RollGeometry.LineMark(y: 700, width: 0.8),
                ]),
                extent(nodes[2], top: 900, height: 100),
            ],
            height: 1000,
            revision: 3
        )
        let resting = RollGeometry(document: document, viewportTop: 0, viewportHeight: 300)
        let scrolled = RollGeometry(document: document, viewportTop: 450, viewportHeight: 300)
        let elastic = RollGeometry(document: document, viewportTop: -40, viewportHeight: 300)
        let prepared = StreamNavigator.layout(
            nodes: nodes, geometry: resting, height: 400, width: 102)

        XCTAssertEqual(
            StreamNavigator.updatingViewport(in: prepared, geometry: resting),
            prepared, "reapplying the same viewport changed the drawing")
        for geometry in [scrolled, elastic] {
            XCTAssertEqual(
                StreamNavigator.updatingViewport(in: prepared, geometry: geometry),
                StreamNavigator.layout(nodes: nodes, geometry: geometry, height: 400, width: 102),
                "a viewport update at \(geometry.viewportTop) drew something a fresh layout would not")
        }
    }

    /// A roll with no height puts every node at document zero and lets
    /// the packing decide; a roll with a height but no measured blocks,
    /// the publish between a height's capture and the extents' arrival,
    /// spreads its nodes evenly down the document so the extents landing
    /// moves them rather than unstacking them.
    func testARollWithHeightAndNoExtentsSpreadsItsNodesEvenly() {
        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -1),
            slot(tab: 3, page: 33, day: -2),
            slot(tab: 4, page: 44, day: -3),
        ])
        let stacked = StreamNavigator.layout(
            nodes: nodes, geometry: .unmeasured, height: 400, width: 102)
        XCTAssertEqual(stacked.placed.map(\.documentTop), [0, 0, 0, 0])
        XCTAssertEqual(stacked.placed[0].y, StreamNavigator.Metrics.top)
        XCTAssertEqual(
            stacked.placed[1].rowTop, stacked.placed[0].rowTop + stacked.placed[0].rowHeight,
            "an unmeasured roll's second node did not pack against the first")

        let tall = RollGeometry(
            extents: [], documentHeight: 1000, viewportTop: 0, viewportHeight: 300)
        let spread = StreamNavigator.layout(
            nodes: nodes, geometry: tall, height: 400, width: 102)
        let tops = spread.placed.map(\.documentTop)
        XCTAssertEqual(tops, [0, 250, 500, 750])
        XCTAssertEqual(tops, tops.sorted())
        XCTAssertGreaterThan(
            spread.placed[1].y, stacked.placed[1].y,
            "a roll with a height and no extents stacked its nodes at the top")
        assertLaidOutInOrder(spread, height: 400)
    }

    func testMeasuredExtentsSetTheCeilingWhenDocumentHeightIsZeroOrStale() {
        let laidOutNodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -1),
        ])
        let extents = [
            extent(laidOutNodes[0], top: 0, height: 400),
            extent(laidOutNodes[1], top: 400, height: 200),
        ]

        for documentHeight: CGFloat in [0, 100] {
            let geometry = RollGeometry(
                extents: extents, documentHeight: documentHeight,
                viewportTop: 0, viewportHeight: 200)
            let layout = StreamNavigator.layout(
                nodes: laidOutNodes, geometry: geometry, height: 400, width: 102)

            XCTAssertEqual(layout.placed.map(\.documentTop), [0, 400])
            XCTAssertEqual(layout.anchors.last?.document, 600)
        }
    }

    /// The relay may forward through its hosting ancestor, but a sibling
    /// above it is same-window content that owns the wheel at that point.
    /// In that case the event must remain available to the occluder.
    func testWheelRelayDoesNotTakeEventsFromSameWindowOccludingContent() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = root
        let relay = WheelRelayView(frame: root.bounds)
        root.addSubview(relay)
        let point = NSPoint(x: 50, y: 50)

        XCTAssertTrue(WheelRelayView.shouldRelay(
            eventWindow: window, relayWindow: window, pointInside: true,
            hitView: root.hitTest(point), relayView: relay))

        let occluder = NSView(frame: relay.frame)
        root.addSubview(occluder)
        XCTAssertTrue(root.hitTest(point) === occluder)
        XCTAssertFalse(WheelRelayView.shouldRelay(
            eventWindow: window, relayWindow: window, pointInside: true,
            hitView: root.hitTest(point), relayView: relay))

        let otherWindow = NSWindow(
            contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        XCTAssertFalse(WheelRelayView.shouldRelay(
            eventWindow: otherWindow, relayWindow: window, pointInside: true,
            hitView: root, relayView: relay))
    }

    /// The occluder is found in the window's base space, which is what
    /// the content view's `hitTest` wants and where an event's location
    /// already is. With the content view's bounds shifted off the
    /// window's origin, converting the location into those bounds first
    /// would test a point outside the view and find nothing, so the
    /// relay would swallow a wheel that belonged to the occluder.
    func testWheelRelayResolvesTheOccluderInWindowBaseCoordinates() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = root
        root.setBoundsOrigin(NSPoint(x: 1000, y: 1000))
        let relay = WheelRelayView(frame: root.bounds)
        root.addSubview(relay)
        let point = NSPoint(x: 50, y: 50)

        XCTAssertNil(
            root.hitTest(root.convert(point, from: nil)),
            "the shifted bounds no longer discriminate between the two conversions")
        XCTAssertTrue(WheelRelayView.occludingView(at: point, in: window) === root)
        XCTAssertTrue(WheelRelayView.shouldRelay(
            eventWindow: window, relayWindow: window, pointInside: true,
            hitView: WheelRelayView.occludingView(at: point, in: window), relayView: relay))

        let occluder = NSView(frame: relay.frame)
        root.addSubview(occluder)
        XCTAssertTrue(WheelRelayView.occludingView(at: point, in: window) === occluder)
        XCTAssertFalse(WheelRelayView.shouldRelay(
            eventWindow: window, relayWindow: window, pointInside: true,
            hitView: WheelRelayView.occludingView(at: point, in: window), relayView: relay))
        XCTAssertNil(WheelRelayView.occludingView(at: point, in: nil))
    }

    /// A node's click lands just above its page, never above the
    /// document, and takes no time for a reader who asked for less
    /// motion.
    func testAJumpLandsJustAboveThePage() {
        XCTAssertEqual(StreamNavigator.jumpOffset(forDocumentTop: 100), 96)
        XCTAssertEqual(StreamNavigator.jumpOffset(forDocumentTop: 2), 0)
        XCTAssertEqual(StreamNavigator.jumpDuration(reduceMotion: true), 0)
        XCTAssertEqual(StreamNavigator.jumpDuration(reduceMotion: false), 0.16)
    }

    /// No node's words may begin above where the one before them ended,
    /// and none may hang off the column.
    private func assertLaidOutInOrder(
        _ layout: StreamNavigator.Layout, height: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var settled: CGFloat = 0
        for placed in layout.placed {
            XCTAssertGreaterThanOrEqual(
                placed.rowTop, settled, "a node began above where the one before it ended",
                file: file, line: line)
            XCTAssertGreaterThan(placed.rowHeight, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(
                placed.rowTop + placed.rowHeight, height,
                "a node was drawn past the foot of the rail", file: file, line: line)
            settled = placed.rowTop + placed.rowHeight
        }
    }
}
