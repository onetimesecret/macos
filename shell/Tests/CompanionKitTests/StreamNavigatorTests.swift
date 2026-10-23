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

    func testGapCountsAreIndependentOfDayDirection() {
        for (a, b) in [(0, -3), (-4, -9), (-8, -12)] {
            XCTAssertEqual(StreamNavigator.emptyDays(between: a, and: b),
                           StreamNavigator.emptyDays(between: b, and: a))
        }
        XCTAssertEqual(StreamNavigator.emptyDays(between: -3, and: 0), 2)
    }

    func testRetainedBoundarySeparatesOldestFirstNodes() throws {
        let ordered = Array(nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -4),
            slot(tab: 3, page: 33, day: -9)
        ]).reversed())
        let geometry = RollGeometry(extents: ordered.enumerated().map {
            extent($0.element, top: CGFloat($0.offset) * 1000, height: 1000)
        }, documentHeight: 3000, viewportTop: 0, viewportHeight: 200)
        let layout = StreamNavigator.layout(nodes: ordered, geometry: geometry, height: 280, width: 140)
        let boundary = try XCTUnwrap(layout.windowY)
        XCTAssertGreaterThan(boundary, layout.placed[0].y)
        XCTAssertLessThan(boundary, layout.placed[1].y)
        XCTAssertEqual(layout.retainedTrack, .init(y: layout.trackTop, height: boundary - layout.trackTop))
        XCTAssertEqual(layout.windowTrack, .init(y: boundary, height: layout.trackBottom - boundary))
    }

    /// With every day retained, the mark stands above the first node newest first and past the
    /// last node oldest first, the dashed stretch on its far side; no retained day dashes nothing.
    func testTheRetainedStretchFollowsTheOrderWhenEveryDayIsRetained() throws {
        let newestFirst = nodes([
            slot(tab: 1, page: 11, day: -8),
            slot(tab: 2, page: 22, day: -9),
            slot(tab: 3, page: 33, day: -12),
        ]).filter(\.hasPage)
        XCTAssertEqual(newestFirst.map(\.bucket), [-8, -9, -12], "the control")
        XCTAssertTrue(newestFirst.allSatisfy(\.trailing), "the control")
        XCTAssertFalse(StreamNavigator.runsOldestFirst(newestFirst))

        let layout = StreamNavigator.layout(
            nodes: newestFirst, geometry: .unmeasured, height: 400, width: 102)
        let mark = try XCTUnwrap(layout.windowY, "the seven day mark vanished")
        XCTAssertLessThan(mark, try XCTUnwrap(layout.placed.first).y)
        XCTAssertEqual(layout.windowTrack, .init(y: layout.trackTop, height: mark - layout.trackTop))
        XCTAssertEqual(layout.retainedTrack, .init(y: mark, height: layout.trackBottom - mark))

        let oldestFirst = Array(newestFirst.reversed())
        XCTAssertTrue(StreamNavigator.runsOldestFirst(oldestFirst))
        for height: CGFloat in [400, 60] {
            let reversed = StreamNavigator.layout(
                nodes: oldestFirst, geometry: .unmeasured, height: height, width: 102)
            let last = try XCTUnwrap(reversed.placed.last)
            let end = try XCTUnwrap(reversed.windowY, "the seven day mark vanished at \(height)")
            XCTAssertGreaterThan(end, last.rowBottom, "the mark met the last row at \(height)")
            XCTAssertLessThan(end, reversed.trackBottom, "the mark passed the foot at \(height)")
            XCTAssertEqual(reversed.retainedTrack, .init(y: reversed.trackTop, height: end - reversed.trackTop))
            XCTAssertEqual(reversed.windowTrack, .init(y: end, height: reversed.trackBottom - end))
        }
        let tight = StreamNavigator.layout(nodes: oldestFirst, geometry: .unmeasured, height: 60, width: 102)
        XCTAssertEqual(tight.contentHeight, tight.packedHeight, "the mark's room is outside the packed height")

        let live = nodes([slot(tab: 1, page: 11, day: -1), slot(tab: 2, page: 22, day: -3)])
        for ordered in [live, Array(live.reversed())] {
            let fits = StreamNavigator.layout(nodes: ordered, geometry: .unmeasured, height: 400, width: 102)
            XCTAssertNil(fits.windowY)
            XCTAssertNil(fits.retainedTrack, "a rail with no retained day drew a dashed stretch")
            XCTAssertEqual(fits.windowTrack, .init(y: fits.trackTop, height: fits.trackBottom - fits.trackTop))
        }
    }

    /// A short last page puts its row past the column's foot, which the column scrolls to (#277);
    /// only rows that outrun the column packed tight make the rail dense (ADR-0060).
    func testOrdinaryOverflowScrollsAndOnlyPackedOverflowIsDense() {
        let pair = nodes([slot(tab: 1, page: 11, day: 0), slot(tab: 2, page: 22, day: -1)])
        let geometry = RollGeometry(
            extents: [extent(pair[0], top: 0, height: 5_000), extent(pair[1], top: 5_000, height: 100)],
            documentHeight: 5_100, viewportTop: 0, viewportHeight: 300)
        for height: CGFloat in [300, 500, 700] {
            let layout = StreamNavigator.layout(nodes: pair, geometry: geometry, height: height, width: 102)
            XCTAssertGreaterThan(layout.contentHeight, height, "the control: the last row fits at \(height)")
            XCTAssertFalse(StreamNavigator.isDense(layout, columnHeight: height), "two rows went dense at \(height)")
        }
        let dense = StreamNavigator.layout(
            nodes: threeDays(pagesPerDay: 12), geometry: .unmeasured, height: 480, width: 102)
        XCTAssertTrue(StreamNavigator.isDense(dense, columnHeight: 480), "36 rows fit a 480 point column")
        XCTAssertEqual(dense.packedHeight, dense.contentHeight, "the packed rows and the packed drawing differ")
    }

    /// The map takes two fifths of a roomy column, 40 points at least, and gives way in a short
    /// one so the list keeps room for one whole row.
    func testTheDenseMapLeavesTheListRoomForOneRow() {
        let gap = StreamNavigator.Metrics.mapGap
        XCTAssertEqual(StreamNavigator.denseMapHeight(columnHeight: 400, row: 38), 160)
        XCTAssertEqual(StreamNavigator.denseMapHeight(columnHeight: 120, row: 38), 48)
        XCTAssertEqual(StreamNavigator.denseMapHeight(columnHeight: 90, row: 38), 40)
        for height: CGFloat in [30, 44, 60, 82] {
            let map = StreamNavigator.denseMapHeight(columnHeight: height, row: 24)
            XCTAssertGreaterThanOrEqual(map, 0, "a negative map at \(height)")
            XCTAssertGreaterThanOrEqual(height - map - gap, 24, "the list lost its row at \(height)")
        }
        XCTAssertEqual(StreamNavigator.denseMapHeight(columnHeight: 10, row: 24), 0)
    }

    func testDenseMapFitsMinimumHeightAndCoversLongDocumentInBothOrders() {
        let checkpoints = nodes((1...60).map {
            slot(tab: UInt64($0), page: UInt64($0 + 100), day: 0,
                 createdMs: born + UInt64($0) * 60_000)
        })
        for ordered in [checkpoints, Array(checkpoints.reversed())] {
            let geometry = RollGeometry(extents: ordered.enumerated().map {
                extent($0.element, top: CGFloat($0.offset) * 5000, height: 5000)
            }, documentHeight: 300000, viewportTop: 140000, viewportHeight: 180)
            XCTAssertTrue(
                StreamNavigator.isDense(
                    StreamNavigator.layout(nodes: ordered, geometry: geometry, height: 180, width: 142),
                    columnHeight: 180),
                "the control: a 180 point column fits every row")
            let layout = StreamNavigator.layout(nodes: ordered, geometry: geometry,
                                                 height: 72, width: 142, compact: true)
            XCTAssertEqual(layout.placed.count, 60)
            XCTAssertTrue(layout.placed.allSatisfy { $0.y >= layout.trackTop && $0.y <= layout.trackBottom })
            XCTAssertEqual(layout.documentOffset(atY: layout.trackBottom), 300000, accuracy: 1)
            let last = layout.anchors[layout.anchors.count - 2]
            let end = layout.anchors[layout.anchors.count - 1]
            XCTAssertLessThan(end.y - last.y, 1, "dense segments are smaller than a point")
            XCTAssertEqual(layout.documentOffset(atY: (last.y + end.y) / 2),
                           (last.document + end.document) / 2, accuracy: 0.001)
            XCTAssertNotNil(layout.band)
        }
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
        func reading(_ stamp: String?, firstOfDay: Bool = true) -> String {
            DayHeaderView.words(spokenLabel: "today", stamp: stamp, firstOfDay: firstOfDay)
                .reading(name: nil)
        }
        XCTAssertEqual(reading("11:39"), "today · 11:39")
        XCTAssertEqual(reading("11:55", firstOfDay: false), "11:55")
        XCTAssertEqual(reading(nil), "today")
        XCTAssertEqual(reading(""), "today")
        XCTAssertEqual(reading(nil, firstOfDay: false), "today")
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

    /// A day's first row is drawn a point higher than a later row, so a rail packed tight from
    /// the top, in a column that fits it or one it outruns, still draws no row into the one above.
    func testPackedRowsAreDrawnClearOfTheRowAbove() throws {
        let nodes = threeDays(pagesPerDay: 4)
        XCTAssertTrue(
            zip(nodes, nodes.dropFirst()).contains { !$0.firstOfDay && $1.firstOfDay },
            "the control: no later row meets the next day's first")
        for (height, dense) in [(CGFloat(400), false), (120, true)] {
            let layout = StreamNavigator.layout(
                nodes: nodes, geometry: .unmeasured, height: height, width: 102)
            let first = try XCTUnwrap(layout.placed.first)
            XCTAssertEqual(first.y, StreamNavigator.Metrics.top, "the first row moved at height \(height)")
            if dense {
                XCTAssertGreaterThan(layout.contentHeight, height, "the control: the column fits its rows")
            } else {
                XCTAssertEqual(layout.contentHeight, height, "the control: the rows outran the column")
            }
            let frames = layout.placed.map { placed in
                CGRect(x: 0, y: placed.drawnTop, width: 102, height: placed.rowHeight)
            }
            for (index, upper) in frames.enumerated() {
                for lower in frames.dropFirst(index + 1) {
                    XCTAssertFalse(upper.intersects(lower), "rows at \(upper) and \(lower) meet at height \(height)")
                }
            }
            for (upper, lower) in zip(frames, frames.dropFirst()) {
                XCTAssertLessThanOrEqual(upper.maxY, lower.minY, "a row rose into the one above at height \(height)")
            }
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(frames.last).maxY, layout.contentHeight - StreamNavigator.Metrics.bottom,
                "the last row passed the foot at height \(height)")
        }
    }

    /// A rail with more rows than its column fits (issue #277: 36 pages over three days in a
    /// 480 point column) places no row above the column; the rows beyond it lengthen the
    /// drawing instead, and the track and the map run to its foot, for the column to scroll to.
    func testADenseRailGrowsPastTheColumnRatherThanAboveIt() throws {
        let height: CGFloat = 480
        let layout = StreamNavigator.layout(
            nodes: threeDays(pagesPerDay: 12), geometry: .unmeasured, height: height, width: 102)
        XCTAssertEqual(layout.placed.count, 36)
        let last = try XCTUnwrap(layout.placed.last)
        XCTAssertGreaterThan(last.drawnTop + last.rowHeight, height, "the control: the column fits its rows")
        XCTAssertEqual(
            try XCTUnwrap(layout.placed.first).drawnTop,
            StreamNavigator.Metrics.top - StreamNavigator.Metrics.rowLift(firstOfDay: true))
        for placed in layout.placed {
            XCTAssertGreaterThanOrEqual(placed.drawnTop, 0, "a row was placed above the column at \(placed.drawnTop)")
        }
        XCTAssertEqual(
            layout.contentHeight, last.y + last.rowHeight + StreamNavigator.Metrics.bottom,
            "the drawing ends somewhere other than the foot's margin under the last row")
        XCTAssertEqual(layout.trackBottom, layout.contentHeight - StreamNavigator.Metrics.bottom)
        XCTAssertEqual(layout.anchors.last?.y, layout.trackBottom, "the map stops short of the drawing's foot")
        assertLaidOutInOrder(layout, height: height)

        // A column shorter than its two margins, as a collapsing column publishes.
        let tall = RollGeometry(extents: [], documentHeight: 1000, viewportTop: 0, viewportHeight: 300)
        let short = StreamNavigator.layout(nodes: threeDays(pagesPerDay: 12), geometry: tall, height: 8, width: 102)
        XCTAssertEqual(short.placed.first?.y, StreamNavigator.Metrics.top)
        for placed in short.placed {
            XCTAssertGreaterThanOrEqual(
                placed.drawnTop, 0, "a row was placed above a short column at \(placed.drawnTop)")
        }
        assertLaidOutInOrder(short, height: 8)
    }

    /// A selection moving to a row outside the clip asks for the least scroll that shows it,
    /// to the clip's top from above and to its bottom from below, never past the drawing's
    /// ends, and a row in view asks for nothing.
    func testASelectionChangeAsksForTheLeastScrollThatShowsItsRow() {
        func reveal(rowTop: CGFloat, rowHeight: CGFloat = 16, visibleTop: CGFloat = 200) -> CGFloat? {
            StreamNavigator.revealOffset(
                rowTop: rowTop, rowHeight: rowHeight, visibleTop: visibleTop, visibleHeight: 400, contentHeight: 1000)
        }
        XCTAssertNil(reveal(rowTop: 200), "the row at the clip's top asked for a scroll")
        XCTAssertNil(reveal(rowTop: 584), "the row at the clip's bottom asked for a scroll")
        XCTAssertEqual(reveal(rowTop: 150), 150, "a row above the clip did not come to its top")
        XCTAssertEqual(reveal(rowTop: 590), 206, "a row below the clip did not come to its bottom")
        XCTAssertEqual(reveal(rowTop: 990, rowHeight: 30), 600, "the scroll ran past the drawing's foot")
        XCTAssertEqual(reveal(rowTop: -5, visibleTop: 0), 0, "the scroll ran above the drawing's top")
        XCTAssertNil(
            StreamNavigator.revealOffset(
                rowTop: 100, rowHeight: 16, visibleTop: 0, visibleHeight: 400, contentHeight: 400),
            "a column that fits its rows asked for a scroll")
    }

    /// The column reveals the active node once, and again only after the selection moved
    /// on and back, or after the roll left and came back; a reveal that could not be made,
    /// and so was never recorded, stays due.
    func testTheColumnRevealsANodeOnceUntilTheSelectionMovesOrTheRollLeaves() {
        var memory = StreamNavigator.RevealMemory()
        XCTAssertTrue(memory.isDue(11), "the first node was not revealed")
        XCTAssertTrue(memory.isDue(11), "a reveal that was never made stopped being due")
        memory.record(11)
        XCTAssertFalse(memory.isDue(11), "a layout moving the row revealed it again")
        XCTAssertTrue(memory.isDue(22), "the selection moved and nothing scrolled")
        memory.record(22)
        XCTAssertTrue(memory.isDue(11), "a node selected again was not revealed")
        memory.record(11)
        memory.forget()
        XCTAssertNil(memory.revealed, "the roll left and the column still remembers its node")
        XCTAssertTrue(memory.isDue(11), "the roll came back and its node stayed out of view")
    }

    /// A hop that finds the clip with no height, or the drawing not yet as tall as the clip,
    /// moves nothing and leaves the reveal due, and the clip or the drawing taking its size
    /// makes it with no second update. Out of its window the view answers no size; back in
    /// it, the reveal is made.
    func testARevealThatMeasuredNothingIsMadeWhenTheClipTakesItsSize() {
        let cases: [(clip: CGFloat, drawing: CGFloat, leaves: Bool)] = [
            (0, 1000, false), (400, 100, false), (0, 1000, true),
        ]
        let request = RailReveal.Request(id: 11, top: 900, bottom: 930)
        for (clipHeight, drawingHeight, leaves) in cases {
            let label = "a \(clipHeight) point clip over a \(drawingHeight) point drawing"
            let column = RevealColumn(clipHeight: clipHeight, drawingHeight: drawingHeight)
            addTeardownBlock { column.window.close() }

            column.reveal.reveal(request)
            drainMainQueue()
            XCTAssertTrue(column.reveal.memory.isDue(11), "\(label) used up the reveal")
            XCTAssertEqual(column.offset, 0, "\(label) moved the clip")

            if leaves { column.scroll.removeFromSuperview() }
            column.scroll.setFrameSize(NSSize(width: 100, height: 400))
            column.document.setFrameSize(NSSize(width: 100, height: 1000))
            drainMainQueue()
            if leaves {
                XCTAssertTrue(column.reveal.memory.isDue(11), "a view out of its window answered the clip's size")
                XCTAssertEqual(column.offset, 0, "a view out of its window moved the clip")
                column.window.contentView?.addSubview(column.scroll)
                drainMainQueue()
            }
            XCTAssertFalse(column.reveal.memory.isDue(11), "\(label) left the reveal due once the clip took its size")
            XCTAssertEqual(column.offset, 530, "\(label) did not bring the row to the clip's bottom")
        }
    }

    /// Two updates in one hop make one move, the last, and a last one already revealed makes none.
    func testTheLastUpdateInAHopDecidesTheReveal() {
        let column = RevealColumn(clipHeight: 400, drawingHeight: 1000)
        addTeardownBlock { column.window.close() }
        let far = RailReveal.Request(id: 11, top: 900, bottom: 930)
        let near = RailReveal.Request(id: 22, top: 500, bottom: 530)
        column.reveal.reveal(near)
        drainMainQueue()
        XCTAssertEqual(column.offset, 130, "the control: the first reveal brought its row to the clip's bottom")

        column.reveal.reveal(far)
        column.reveal.reveal(near)
        drainMainQueue()
        XCTAssertEqual(column.offset, 130, "a request replaced in its hop moved the clip")
        XCTAssertTrue(column.reveal.memory.isDue(11), "a request replaced in its hop was recorded")
    }

    /// A `RailRevealView` behind a flipped drawing inside a scroll view, in a window never ordered.
    private struct RevealColumn {
        final class Document: NSView {
            override var isFlipped: Bool { true }
        }

        let window: NSWindow
        let scroll: NSScrollView
        let document: Document
        let reveal: RailRevealView

        init(clipHeight: CGFloat, drawingHeight: CGFloat) {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 400),
                styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 400))
            scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: clipHeight))
            document = Document(frame: NSRect(x: 0, y: 0, width: 100, height: drawingHeight))
            scroll.documentView = document
            reveal = RailRevealView(frame: NSRect(x: 0, y: 0, width: 100, height: 1000))
            document.addSubview(reveal)
            window.contentView?.addSubview(scroll)
        }

        /// How far down the drawing the clip stands.
        var offset: CGFloat { scroll.contentView.bounds.minY }
    }

    /// A row's ground begins at the note or the mark it keeps above itself, and at its own
    /// sliver box when it keeps none, so a reveal brings the note in with the row.
    func testARowsGroundBeginsAtItsNoteWhenItKeepsOne() throws {
        let layout = StreamNavigator.layout(
            nodes: nodes([
                slot(tab: 1, page: 11, day: 0),
                slot(tab: 2, page: 22, day: -3),
                slot(tab: 3, page: 33, day: -9),
            ]),
            geometry: .unmeasured, height: 400, width: 102)
        let plain = try XCTUnwrap(layout.placed.first)
        XCTAssertEqual(plain.node.emptyDays, 0, "the control")
        XCTAssertEqual(plain.groundTop, plain.rowTop)
        let noted = layout.placed[1]
        XCTAssertEqual(noted.node.emptyDays, 2, "the control")
        XCTAssertEqual(noted.groundTop, noted.y - StreamNavigator.Metrics.gapBand)
        XCTAssertEqual(noted.noteY, noted.groundTop + 1, "the note is drawn off its row's ground")
        let marked = layout.placed[2]
        XCTAssertTrue(marked.node.trailing, "the control")
        XCTAssertEqual(
            marked.groundTop,
            marked.y - StreamNavigator.Metrics.gapBandAtWindow - StreamNavigator.Metrics.windowReserve)
        XCTAssertLessThan(try XCTUnwrap(layout.windowY), marked.rowTop, "the window mark is drawn below its row's box")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(layout.windowY), marked.groundTop, "the window mark is drawn off its row's ground")
    }

    /// On a dense rail the band lives in the drawing's coordinates and stays inside it, on
    /// the first layout and on the viewport only path alike, at either end of the roll.
    func testADenseRailsBandStaysInsideTheDrawingOnTheViewportOnlyPath() throws {
        let nodes = threeDays(pagesPerDay: 12)
        let top = RollGeometry(extents: [], documentHeight: 10_000, viewportTop: 0, viewportHeight: 300)
        let layout = StreamNavigator.layout(nodes: nodes, geometry: top, height: 480, width: 102)
        XCTAssertGreaterThan(layout.contentHeight, 480, "the control: the column fits its rows")
        for viewportTop: CGFloat in [0, 4_850, 9_700] {
            let geometry = RollGeometry(
                extents: [], documentHeight: 10_000, viewportTop: viewportTop, viewportHeight: 300)
            let fresh = try XCTUnwrap(
                StreamNavigator.layout(nodes: nodes, geometry: geometry, height: 480, width: 102).band)
            let updated = try XCTUnwrap(StreamNavigator.updatingViewport(in: layout, geometry: geometry).band)
            XCTAssertEqual(updated, fresh, "the viewport only path drew the band elsewhere at \(viewportTop)")
            XCTAssertGreaterThanOrEqual(updated.y, 0, "the band rose above the drawing at \(viewportTop)")
            XCTAssertLessThanOrEqual(
                updated.y + updated.height, layout.contentHeight,
                "the band passed the drawing's foot at \(viewportTop)")
        }
        let foot = try XCTUnwrap(
            StreamNavigator.updatingViewport(
                in: layout,
                geometry: RollGeometry(
                    extents: [], documentHeight: 10_000, viewportTop: 9_700, viewportHeight: 300)
            ).band)
        XCTAssertGreaterThan(foot.y + foot.height, 480, "the control: the band at the roll's end sits inside the column")
    }

    /// A wheel over the column turns the roll while the drawing fits the column, the foot's
    /// margin included, and turns the column once the rows outrun it by more than that.
    func testTheWheelTurnsTheRollWhileTheDrawingFitsTheColumn() {
        let margin = StreamNavigator.Metrics.bottom
        XCTAssertTrue(StreamNavigator.relaysWheel(contentHeight: 400, columnHeight: 400))
        XCTAssertTrue(
            StreamNavigator.relaysWheel(contentHeight: 400 + margin, columnHeight: 400),
            "overflow within the foot's margin changed what the wheel means")
        XCTAssertFalse(
            StreamNavigator.relaysWheel(contentHeight: 400 + margin + 1, columnHeight: 400),
            "a column the rows outrun kept the wheel for the roll")
        let fits = StreamNavigator.layout(
            nodes: threeDays(pagesPerDay: 4), geometry: .unmeasured, height: 400, width: 102)
        XCTAssertTrue(StreamNavigator.relaysWheel(contentHeight: fits.contentHeight, columnHeight: 400))
        let dense = StreamNavigator.layout(
            nodes: threeDays(pagesPerDay: 12), geometry: .unmeasured, height: 480, width: 102)
        XCTAssertFalse(StreamNavigator.relaysWheel(contentHeight: dense.contentHeight, columnHeight: 480))
    }

    /// A line landing on a row's last drawn point yields no sliver, and one landing two
    /// points above the row yields one, for a day's first row and a later one alike: the
    /// box the slivers keep clear of is the drawn row one point higher and as tall.
    func testASliverNeverCrossesARowsLastPointAndMayStandJustAboveIt() throws {
        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: 0, createdMs: born + 60_000),
        ])
        XCTAssertEqual(nodes.map(\.firstOfDay), [true, false])
        // A 200 point document over a 200 point span: a document offset is a rail point.
        let height: CGFloat = StreamNavigator.Metrics.top + 200 + StreamNavigator.Metrics.bottom
        func geometry(lines: [RollGeometry.LineMark]) -> RollGeometry {
            RollGeometry(
                extents: [
                    extent(nodes[0], top: 50, height: 50, lines: lines),
                    extent(nodes[1], top: 150, height: 50),
                ],
                documentHeight: 200, viewportTop: 0, viewportHeight: 200)
        }
        let bare = StreamNavigator.layout(nodes: nodes, geometry: geometry(lines: []), height: height, width: 102)
        XCTAssertEqual(bare.placed.map(\.y), [66, 166], "the control: the packing moved a node off its place")
        let lastPoints = bare.placed.map { $0.drawnTop + $0.rowHeight - 1 }
        let justAbove = bare.placed.map { $0.drawnTop - 2 }
        let lines = (lastPoints + justAbove).map {
            RollGeometry.LineMark(y: bare.documentOffset(atY: $0), width: 1)
        }
        let layout = StreamNavigator.layout(
            nodes: nodes, geometry: geometry(lines: lines), height: height, width: 102)
        XCTAssertEqual(layout.placed.map(\.y), bare.placed.map(\.y), "the lines moved a node")
        XCTAssertEqual(layout.slivers.map(\.y), justAbove, "a sliver crossed a row's last point, or one just above a row was dropped")
    }

    /// At a fractional top the slivers keep clear of every whole point a row paints and the
    /// one above it, as at a whole point top: a line on the point above or on the last
    /// painted point yields no sliver, and one a point further out on either side yields one.
    func testAtAFractionalTopNoSliverCrossesAPointTheRowPaints() throws {
        let nodes = nodes([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: 0, createdMs: born + 60_000),
        ])
        // A 200 point document over a 200 point span: a document offset is a rail point.
        let height: CGFloat = StreamNavigator.Metrics.top + 200 + StreamNavigator.Metrics.bottom
        func geometry(lines: [RollGeometry.LineMark]) -> RollGeometry {
            RollGeometry(
                extents: [
                    extent(nodes[0], top: 50.4, height: 50, lines: lines),
                    extent(nodes[1], top: 150.4, height: 49.6),
                ],
                documentHeight: 200, viewportTop: 0, viewportHeight: 200)
        }
        let bare = StreamNavigator.layout(nodes: nodes, geometry: geometry(lines: []), height: height, width: 102)
        for placed in bare.placed {
            XCTAssertNotEqual(
                placed.drawnTop, placed.drawnTop.rounded(), "the control: a row was drawn at a whole point")
            XCTAssertNotEqual(
                placed.drawnTop + placed.rowHeight, (placed.drawnTop + placed.rowHeight).rounded(),
                "the control: a row ended at a whole point")
        }
        // A whole point p is painted when [p, p + 1) meets [drawnTop, drawnTop + rowHeight).
        let painted = bare.placed.map {
            (first: $0.drawnTop.rounded(.down), last: ($0.drawnTop + $0.rowHeight).rounded(.up) - 1)
        }
        let dropped = painted.flatMap { [$0.first - 1, $0.last] }
        let kept = painted.flatMap { [$0.first - 2, $0.last + 1] }
        let lines = (dropped + kept).map {
            RollGeometry.LineMark(y: bare.documentOffset(atY: $0), width: 1)
        }
        let layout = StreamNavigator.layout(
            nodes: nodes, geometry: geometry(lines: lines), height: height, width: 102)
        XCTAssertEqual(layout.placed.map(\.y), bare.placed.map(\.y), "the lines moved a node")
        XCTAssertEqual(
            layout.slivers.map(\.y), kept.sorted(),
            "a sliver crossed a point a row paints or the one above it, or one a point clear of a row was dropped")
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
                    sliver.y >= placed.rowTop && sliver.y <= placed.rowBottom,
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

    /// The dense rail's compact map is prepared once per document revision, as the drawing
    /// is: a viewport only publication reuses it and draws what a fresh map would.
    func testAViewportOnlyChangeReusesTheCachedCompactMap() {
        let nodes = threeDays(pagesPerDay: 12)
        let document = RollGeometry.Document(
            extents: nodes.enumerated().map { index, node in
                extent(node, top: CGFloat(index) * 500, height: 500, lines: [
                    RollGeometry.LineMark(y: CGFloat(index) * 500 + 40, width: 0.6),
                ])
            },
            height: 18_000, identity: UUID(), revision: 4)
        let resting = RollGeometry(document: document, viewportTop: 0, viewportHeight: 300)
        let scrolled = RollGeometry(document: document, viewportTop: 9_000, viewportHeight: 300)
        let cache = StreamNavigatorLayoutCache()

        let first = cache.layout(nodes: nodes, geometry: resting, height: 72, width: 102, compact: true)
        let moved = cache.layout(nodes: nodes, geometry: scrolled, height: 72, width: 102, compact: true)
        XCTAssertEqual(cache.builds, 1, "a viewport only publication rebuilt the compact map")
        XCTAssertNotEqual(moved.band, first.band, "the control: the band did not move")
        XCTAssertEqual(
            moved, StreamNavigator.layout(nodes: nodes, geometry: scrolled, height: 72, width: 102, compact: true))

        let revised = RollGeometry(
            document: RollGeometry.Document(
                extents: document.extents, height: document.height,
                identity: document.identity, revision: 5),
            viewportTop: 9_000, viewportHeight: 300)
        _ = cache.layout(nodes: nodes, geometry: revised, height: 72, width: 102, compact: true)
        XCTAssertEqual(cache.builds, 2, "a new revision reused the old map")
        _ = cache.layout(nodes: nodes, geometry: revised, height: 72, width: 102)
        XCTAssertEqual(cache.builds, 3, "the full drawing was answered from the compact map")
    }

    /// The dense rail's list stacks every row under the one before, `listSpacing` apart from
    /// the list's top, and names the active row for the reveal.
    func testTheCheckpointListStacksEveryRowAndNamesTheActiveOne() throws {
        let layout = StreamNavigator.layout(
            nodes: threeDays(pagesPerDay: 12), geometry: .unmeasured, height: 480, width: 102)
        let list = StreamNavigator.checkpointList(layout.placed)
        XCTAssertEqual(list.rows.map(\.placed), layout.placed)
        XCTAssertEqual(list.rows.first?.top, 0)
        for (upper, lower) in zip(list.rows, list.rows.dropFirst()) {
            XCTAssertEqual(lower.top, upper.bottom + StreamNavigator.Metrics.listSpacing)
        }
        XCTAssertEqual(list.contentHeight, try XCTUnwrap(list.rows.last).bottom)
        XCTAssertEqual(list.active?.id, layout.placed.first { $0.node.active }?.id)
        XCTAssertNotNil(list.active, "the control: no node is active")
        XCTAssertEqual(StreamNavigator.checkpointList([]).contentHeight, 0)
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
            stacked.placed[1].drawnTop, stacked.placed[0].drawnTop + stacked.placed[0].rowHeight,
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

    /// SwiftUI dismantles the relay when ownership leaves the window,
    /// and the view is still standing in its window when it does. The
    /// watch ends there and then, with the roll's answer let go.
    func testWheelRelayStopsWatchingWhenItIsRetiredInsideItsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = root
        let relay = WheelRelayView(frame: root.bounds)
        relay.relay = { _ in }
        XCTAssertFalse(relay.isWatching, "a view in no window watches nothing")

        root.addSubview(relay)
        XCTAssertTrue(relay.isWatching)

        relay.retire()
        XCTAssertFalse(relay.isWatching)
        XCTAssertNil(relay.relay)
        XCTAssertTrue(relay.window === window, "and it never had to leave the window for that")
    }

    func testScrollbarDragPreservesGrabAndReachesDocumentEnds() throws {
        let checkpoints = nodes([slot(tab: 1, page: 11), slot(tab: 2, page: 12, day: -1)])
        let geometry = RollGeometry(
            extents: [extent(checkpoints[0], top: 0, height: 100),
                      extent(checkpoints[1], top: 100, height: 1900)],
            documentHeight: 2000, viewportTop: 400, viewportHeight: 300)
        let layout = StreamNavigator.layout(nodes: checkpoints, geometry: geometry, height: 400, width: 102)
        let band = try XCTUnwrap(layout.band)
        for grab in [band.y + 1, band.y + band.height / 2, band.y + band.height - 1] {
            let drag = StreamNavigator.ScrollDrag(layout: layout, geometry: geometry, startY: grab)
            XCTAssertEqual(drag.offset(atY: grab), 400, accuracy: 0.01)
            XCTAssertGreaterThan(drag.offset(atY: grab + 10), 400)
            XCTAssertLessThan(drag.offset(atY: grab - 10), 400)
            XCTAssertEqual(drag.offset(atY: -100), 0)
            XCTAssertEqual(drag.offset(atY: 500), 1700)
        }
        let trackY = band.y + band.height + 15
        let drag = StreamNavigator.ScrollDrag(layout: layout, geometry: geometry, startY: trackY)
        XCTAssertEqual(drag.offset(atY: trackY),
                       min(1700, layout.jumpOffset(forTrackY: trackY, viewportHeight: 300)), accuracy: 0.01)
    }

    func testScrubbingUsesImmediateRouteAndRetiresWithClaim() {
        let roll = RollGeometryModel()
        let owner = NSObject()
        var jumps: [CGFloat] = []
        var scrubs: [CGFloat] = []
        roll.claim(by: owner, scroller: { jumps.append($0) }, scrubber: { scrubs.append($0) })
        roll.scroll(toDocumentOffset: 100)
        roll.scrub(toDocumentOffset: 200)
        XCTAssertEqual(jumps, [100])
        XCTAssertEqual(scrubs, [200])
        roll.relinquish()
        roll.scrub(toDocumentOffset: 300)
        XCTAssertEqual(scrubs, [200])
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

    /// Three consecutive days of `pagesPerDay` pages each, newest first, the fourth page
    /// selected, so a later row meets the next day's first row at each day boundary.
    private func threeDays(pagesPerDay: Int) -> [StreamNavigator.Node] {
        var tabs: [TabSummary] = []
        for day in 0..<3 {
            for index in 0..<pagesPerDay {
                let number = UInt64(day * pagesPerDay + index + 1)
                let created: UInt64 = born - UInt64(day) * 86_400_000 + UInt64(index) * 60_000
                tabs.append(slot(tab: number, page: 100 + number, day: -day, createdMs: created))
            }
        }
        return nodes(tabs, selecting: 4)
    }

    /// No node's words may begin above where the one before them ended,
    /// and none may hang off the drawing, which is never shorter than the column.
    private func assertLaidOutInOrder(
        _ layout: StreamNavigator.Layout, height: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            layout.contentHeight, height, "the drawing is shorter than its column", file: file, line: line)
        var settled: CGFloat = 0
        for placed in layout.placed {
            XCTAssertGreaterThanOrEqual(
                placed.drawnTop, settled, "a node began above where the one before it ended",
                file: file, line: line)
            XCTAssertGreaterThan(placed.rowHeight, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(
                placed.drawnTop + placed.rowHeight, layout.contentHeight,
                "a node was drawn past the foot of the drawing", file: file, line: line)
            settled = placed.drawnTop + placed.rowHeight
        }
    }
}
