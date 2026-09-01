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
        for bar in bars {
            XCTAssertGreaterThanOrEqual(bar.y, 0)
            XCTAssertLessThanOrEqual(bar.y + bar.height, 100, "a day was drawn past the rail")
        }
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
    }

    /// The last day of a long roll is drawn against the bottom of the
    /// rail rather than starting past it, which is the same clamp from
    /// the other end.
    func testTheLastDayStopsAtTheFootOfTheRail() {
        let measured = roll([extent(0, 0, 990), extent(-1, 990, 10)], document: 1_000)
        let bars = RailMinimap.bars(of: measured, in: 100)
        let last = bars.last
        XCTAssertEqual(last?.height, RailMinimap.hairline)
        XCTAssertEqual(last?.y, 100 - RailMinimap.hairline)
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
    /// as the rows drawn over them.
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
