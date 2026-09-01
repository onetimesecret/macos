import XCTest

@testable import CompanionKit

/// The map from the roll to the rail's faint background (issue #131).
///
/// A minimap is a drawing, and drawings are hardware verification's
/// business (docs/qa/hardware-verification.md). What is here is
/// everything that was kept out of the drawing: how a day's span becomes
/// a bar, how the clip's position becomes a band, and what either of
/// them does at the edges, where a roll is empty, a day is a hair tall,
/// or an elastic overscroll has put the clip outside the document. Each
/// case is a measurement in and a shape out, with no window anywhere.
final class RailMinimapTests: XCTestCase {
    private func extent(_ bucket: Int, _ top: CGFloat, _ height: CGFloat) -> RollGeometry.Extent {
        RollGeometry.Extent(bucket: bucket, top: top, height: height)
    }

    private func roll(
        _ extents: [RollGeometry.Extent],
        document: CGFloat,
        viewportTop: CGFloat = 0,
        viewportHeight: CGFloat = 0
    ) -> RollGeometry {
        RollGeometry(
            extents: extents,
            documentHeight: document,
            viewportTop: viewportTop,
            viewportHeight: viewportHeight
        )
    }

    /// No bar may begin above the one before it ended, and none may
    /// hang off the column. Two faint fills over one another are twice
    /// the ink, so an overlap draws a seam the reader would take for a
    /// mark rather than for the join between two days.
    private func assertLaidOutInOrder(
        _ bars: [RailMinimap.Bar], in height: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var settled: CGFloat = 0
        for bar in bars {
            XCTAssertGreaterThanOrEqual(
                bar.y, settled, "a bar began above where the one before it ended",
                file: file, line: line)
            XCTAssertGreaterThanOrEqual(bar.height, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(
                bar.y + bar.height, height,
                "a bar was drawn past the foot of the rail", file: file, line: line)
            settled = bar.y + bar.height
        }
    }

    // MARK: Nothing to draw

    /// A roll nobody has measured has no proportions, so the minimap
    /// draws nothing rather than inventing some. This is the state the
    /// rail is in for the pass between a roll mounting and its first
    /// layout, and the state a dismantled roll leaves behind.
    func testAnUnmeasuredRollDrawsNothing() {
        XCTAssertEqual(RailMinimap.bars(of: .unmeasured, in: 200), [])
        XCTAssertNil(RailMinimap.band(of: .unmeasured, in: 200))
    }

    /// And a rail with no height to draw into draws nothing either,
    /// which is what a `GeometryReader` reports for one pass before the
    /// card has laid the column out.
    func testARailWithNoHeightDrawsNothing() {
        let measured = roll([extent(0, 0, 100)], document: 100, viewportHeight: 40)
        XCTAssertEqual(RailMinimap.bars(of: measured, in: 0), [])
        XCTAssertNil(RailMinimap.band(of: measured, in: 0))
    }

    // MARK: The days

    /// One day that is the whole roll fills the rail, which is the
    /// simplest reading of "as tall a share of the column as the day is
    /// of the document" and the pad's ordinary state: today, alone.
    func testOneDayIsTheWholeColumn() {
        let bars = RailMinimap.bars(of: roll([extent(0, 0, 300)], document: 300), in: 120)
        XCTAssertEqual(bars, [RailMinimap.Bar(bucket: 0, y: 0, height: 120)])
    }

    /// Several days keep their order, their proportions and their
    /// places: today at the top of the rail because it is at the top of
    /// the roll, and a day holding twice the page reading twice as tall.
    /// Nothing overlaps and nothing hangs off the end.
    func testTheDaysKeepTheirOrderAndTheirShare() {
        let measured = roll(
            [extent(0, 0, 100), extent(-1, 100, 150), extent(-3, 250, 150)], document: 400
        )
        let bars = RailMinimap.bars(of: measured, in: 100)
        XCTAssertEqual(bars.map(\.bucket), [0, -1, -3], "the days lost the roll's own order")
        XCTAssertEqual(bars.map(\.y), [0, 25, 62.5])
        XCTAssertEqual(bars.map(\.height), [25, 37.5, 37.5])
        assertLaidOutInOrder(bars, in: 100)
    }

    /// A day holding one line at the top of a very long roll scales to a
    /// fraction of a point. It is drawn as a hairline instead of rounded
    /// away, because the rail is drawing a row for that day right there
    /// and a background saying the day is nothing would contradict it.
    func testATinyDayStillLeavesAMark() {
        let measured = roll([extent(0, 0, 8), extent(-1, 8, 4_000)], document: 4_008)
        let bars = RailMinimap.bars(of: measured, in: 100)
        XCTAssertEqual(bars.first?.height, RailMinimap.hairline)
        XCTAssertEqual(bars.first?.y, 0)
        assertLaidOutInOrder(bars, in: 100)
    }

    /// And the room it borrows comes off the day below it rather than
    /// out of thin air: the next bar starts where the hairline ended,
    /// not where its own share of the roll began. Two faint fills laid
    /// over one another would be twice the ink, and the seam would read
    /// as a mark rather than as the join between two days.
    func testAHairlineTakesItsRoomFromTheDayBelow() {
        let measured = roll([extent(0, 0, 8), extent(-1, 8, 4_000)], document: 4_008)
        let bars = RailMinimap.bars(of: measured, in: 100)
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[1].y, RailMinimap.hairline, "the second day began under the first")
        XCTAssertEqual(bars[1].height, 100 - RailMinimap.hairline)
        assertLaidOutInOrder(bars, in: 100)
    }

    /// The last day of a long roll is drawn against the bottom of the
    /// rail rather than starting past it, and the floor yields to the
    /// column rather than the column to the floor: a day with only a
    /// point of room left is drawn a point tall, which is still a mark,
    /// where a full hairline there could only have been taken out of its
    /// neighbour or off the end of the rail.
    func testTheLastDayStopsAtTheFootOfTheRail() {
        let measured = roll([extent(0, 0, 990), extent(-1, 990, 10)], document: 1_000)
        let bars = RailMinimap.bars(of: measured, in: 100)
        let last = bars.last
        XCTAssertEqual(last?.y, 99)
        XCTAssertEqual(last?.height, 1)
        assertLaidOutInOrder(bars, in: 100)
    }

    /// A rail too short to give every day a hairline runs out of room
    /// honestly, in the order the days come in, rather than stacking the
    /// remainder on top of one another at the foot. Nine days in ten
    /// points is not a card anybody has, which is exactly why the case
    /// is asserted rather than reasoned about.
    func testARailWithNoRoomLeftRunsOutInOrder() {
        let days = (0..<9).map { extent(-$0, CGFloat($0) * 100, 100) }
        let bars = RailMinimap.bars(of: roll(days, document: 900), in: 10)
        XCTAssertEqual(bars.count, 9, "a day the rail draws a row for lost its bar entirely")
        assertLaidOutInOrder(bars, in: 10)
    }

    // MARK: The viewport band

    /// A roll that fits in the card gets no band. A band around
    /// everything marks nothing, and the pad spends most of its life
    /// holding less page than a card: the band exists for the reader who
    /// has scrolled into history.
    func testTheBandIsAbsentWhenTheWholeRollIsOnScreen() {
        let measured = roll(
            [extent(0, 0, 200)], document: 200, viewportTop: 0, viewportHeight: 200
        )
        XCTAssertNil(RailMinimap.band(of: measured, in: 100))
        XCTAssertNil(
            RailMinimap.band(
                of: roll([extent(0, 0, 200)], document: 200, viewportHeight: 320), in: 100
            ),
            "a card taller than the roll drew a band anyway")
    }

    /// And it follows the clip down a roll that does not fit: a quarter
    /// of the way in, the band is a quarter of the way down and a
    /// quarter of the rail tall.
    func testTheBandFollowsTheClipDownTheRoll() {
        let measured = roll(
            [extent(0, 0, 800)], document: 800, viewportTop: 200, viewportHeight: 200
        )
        XCTAssertEqual(
            RailMinimap.band(of: measured, in: 100), RailMinimap.Band(y: 25, height: 25))
    }

    /// At the end of the roll the band rests on the foot of the rail,
    /// and it stays inside it when an elastic overscroll has carried the
    /// clip past the document's end. Overscroll at the top clamps the
    /// same way, against the ceiling.
    func testTheBandClampsIntoTheRailAtBothEnds() throws {
        let atEnd = roll([extent(0, 0, 400)], document: 400, viewportTop: 300, viewportHeight: 100)
        XCTAssertEqual(RailMinimap.band(of: atEnd, in: 100), RailMinimap.Band(y: 75, height: 25))

        let past = roll([extent(0, 0, 400)], document: 400, viewportTop: 360, viewportHeight: 100)
        let band = try XCTUnwrap(RailMinimap.band(of: past, in: 100))
        XCTAssertLessThanOrEqual(band.y + band.height, 100, "the band hung off the foot of the rail")
        XCTAssertEqual(band.y, 90)

        let above = roll([extent(0, 0, 400)], document: 400, viewportTop: -40, viewportHeight: 100)
        let ceiling = try XCTUnwrap(RailMinimap.band(of: above, in: 100))
        XCTAssertEqual(ceiling.y, 0, "the band was drawn above the top of the rail")
        XCTAssertEqual(ceiling.height, 15)
    }

    // MARK: Folding the roll's rows into days

    /// The roll lays out a row per page and the rail draws a row per
    /// day, so two pages born on one day are one bar covering both. The
    /// fold is what keeps the bars in the same count and the same order
    /// as the rail's rows, which is the whole of what the two share: the
    /// bars are proportional to the roll and never level with a row.
    func testTwoPagesOfOneDayAreOneExtent() {
        let merged = RollGeometry.merging([
            extent(0, 0, 100),
            extent(-1, 100, 60),
            extent(-1, 160, 40),
            extent(-2, 200, 50),
        ])
        XCTAssertEqual(merged.map(\.bucket), [0, -1, -2])
        XCTAssertEqual(merged.map(\.top), [0, 100, 200])
        XCTAssertEqual(merged.map(\.height), [100, 100, 50])
    }

    /// Days that are already one row apiece survive the fold untouched,
    /// and an empty list folds to an empty list rather than to a day
    /// nobody has.
    func testTheFoldLeavesDistinctDaysAlone() {
        let days = [extent(0, 0, 40), extent(-1, 40, 40), extent(-4, 80, 40)]
        XCTAssertEqual(RollGeometry.merging(days), days)
        XCTAssertEqual(RollGeometry.merging([]), [])
    }
}
