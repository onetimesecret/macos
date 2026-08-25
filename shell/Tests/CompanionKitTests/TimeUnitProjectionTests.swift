import XCTest

@testable import CompanionKit

/// Every law of the day model, argued without a window, without AppKit
/// and without a running core (issue #79).
///
/// The projection is the whole of what the mode knows: which days exist,
/// which pages are on them, which of them the surface draws and how each
/// one reads. Swift builds only on macOS CI, so the model is deliberately
/// two pure things — an integer the core computes, tested in Rust, and
/// this function over the summaries carrying it. Nothing below constructs
/// a model, a view or a client; each case is a strip of summaries in, a
/// shape out.
final class TimeUnitProjectionTests: XCTestCase {
    /// One row of the strip, as `companion_tabs_json` would describe it.
    /// A slot holding no page reports no day and no content, which is
    /// the seam's own rule rather than this helper's convenience.
    private func slot(
        tab: UInt64,
        page: UInt64? = nil,
        day: Int = 0,
        content: Bool = false,
        remainingMs: UInt64 = 3_600_000,
        fraction: Double = 0.5,
        paused: Bool = false,
        toppedUp: Bool = false,
        lastHour: Bool = false,
        remaining: String = "1h"
    ) -> TabSummary {
        TabSummary(
            id: tab,
            hasPage: page != nil,
            pageID: page,
            title: "slot \(tab)",
            rungCode: 5,
            rungLabel: "7d",
            remainingMs: page == nil ? 0 : remainingMs,
            remainingLabel: page == nil ? "" : remaining,
            spokenRemaining: page == nil ? "" : "one hour",
            fractionRemaining: page == nil ? 0 : fraction,
            paused: paused,
            holdToppedUp: toppedUp,
            holdRemainingMs: 0,
            chipCount: 0,
            lastHour: lastHour,
            pageHasContent: page == nil ? false : content,
            pageDayOffset: page == nil ? nil : day
        )
    }

    private func project(
        _ tabs: [TabSummary], selecting page: UInt64? = nil
    ) -> TimeUnitProjection {
        TimeUnitProjection.project(tabs: tabs, selectedPageID: page, unit: .day)
    }

    // MARK: Today is a place

    /// Day 0 is a place and not a page: it has a row whether or not a
    /// gesture has put anything on it, which is how "today is always
    /// displayed" is satisfied by drawing rather than by minting
    /// (ADR-0017).
    func testTodayIsADayWithOrWithoutAPage() {
        let empty = project([])
        XCTAssertEqual(empty.units.map(\.bucket), [0], "today lost its place on an empty pad")
        XCTAssertEqual(empty.units.first?.label, "Today")
        XCTAssertEqual(empty.units.first?.pageIDs, [], "an empty day must not invent a page")
        XCTAssertEqual(empty.units.first?.tabIDs, [])
        XCTAssertEqual(empty.hiddenBlankPages, 0)

        let peopled = project([slot(tab: 1, page: 11, day: 0)])
        XCTAssertEqual(peopled.units.map(\.bucket), [0])
        XCTAssertEqual(peopled.units.first?.pageIDs, [11])
        XCTAssertEqual(peopled.units.first?.tabIDs, [1])
    }

    /// A slot whose page expired is on no day at all. The tab stands —
    /// it is still in the strip this projection reads — but there is
    /// nothing left to key a day on, so it draws no row and counts as
    /// nothing hidden either, because no live page is being kept back.
    func testASlotHoldingNoPageIsOnNoDay() {
        let projection = project([slot(tab: 1), slot(tab: 2)])
        XCTAssertEqual(projection.units.map(\.bucket), [0])
        XCTAssertEqual(projection.units.first?.tabIDs, [])
        XCTAssertEqual(projection.hiddenBlankPages, 0, "an empty slot is not a page in hiding")
    }

    // MARK: What earns a day a row

    /// The content bar decides, and it is the core's bar: a day gets a
    /// row exactly when its page would leave a mark in the ledger. A
    /// page holding nothing but whitespace does not manufacture a day.
    func testADayWhoseOnlyPageHasNothingOnItIsNotDrawn() {
        let projection = project([
            slot(tab: 1, page: 11, day: 0, content: true),
            slot(tab: 2, page: 22, day: -2, content: false),
        ])
        XCTAssertEqual(projection.units.map(\.bucket), [0], "a blank page conjured a day")
        XCTAssertEqual(projection.hiddenBlankPages, 1)
    }

    /// The other side of the same predicate. Whether the content is ink
    /// or a sealed chip with no ink at all is settled core-side and
    /// arrives here as one boolean; what this side must get right is
    /// that the boolean is what draws the row.
    func testADayWhosePageHasSomethingOnItIsDrawn() {
        let projection = project([slot(tab: 2, page: 22, day: -2, content: true)])
        XCTAssertEqual(projection.units.map(\.bucket), [0, -2])
        XCTAssertEqual(projection.units.last?.pageIDs, [22])
        XCTAssertEqual(projection.hiddenBlankPages, 0)
    }

    /// The exemption that keeps the surface honest rather than clever:
    /// the day under the caret is always drawn, so the region the user
    /// is typing into does not pop into existence on the first
    /// character they type.
    func testTheSelectedPagesDayIsDrawnEvenWithNothingOnIt() {
        let strip = [slot(tab: 4, page: 44, day: -4, content: false)]
        XCTAssertEqual(project(strip).units.map(\.bucket), [0], "the control: blank and unselected")

        let selected = project(strip, selecting: 44)
        XCTAssertEqual(selected.units.map(\.bucket), [0, -4])
        XCTAssertEqual(selected.hiddenBlankPages, 0, "the page under the caret is not in hiding")
    }

    // MARK: The shape of the rail

    /// Newest first, which is the order the issue writes the rail in and
    /// the order the roll runs: today at the top, time downward.
    func testTheDaysComeNewestFirst() {
        let projection = project([
            slot(tab: 3, page: 33, day: -5, content: true),
            slot(tab: 1, page: 11, day: 0, content: true),
            slot(tab: 2, page: 22, day: -1, content: true),
        ])
        XCTAssertEqual(projection.units.map(\.bucket), [0, -1, -5])
        XCTAssertEqual(projection.units.map(\.label), ["Today", "-1d", "-5d"])
    }

    /// One page a day is the emergent shape, not a rule the app
    /// enforces. Several pages born on one day are grouped under that
    /// day in strip order, because refusing a shipped gesture or merging
    /// two pages' documents are both opinionated where the issue asked
    /// for unopinionated.
    func testTwoPagesBornTheSameDayShareOneDayInStripOrder() {
        let projection = project([
            slot(tab: 7, page: 77, day: -1, content: true),
            slot(tab: 3, page: 33, day: -1, content: true),
        ])
        XCTAssertEqual(projection.units.map(\.bucket), [0, -1])
        XCTAssertEqual(projection.units.last?.pageIDs, [77, 33], "the day reordered its pages")
        XCTAssertEqual(projection.units.last?.tabIDs, [7, 3])
    }

    /// A day the projection draws draws everything on it. The filter is
    /// by day and not by page, so a page never quietly disappears out of
    /// a day that is on screen — and the hidden count stays about days
    /// nobody can reach rather than about pages inside days they can.
    func testADrawnDayCarriesEveryPageOnIt() {
        let projection = project([
            slot(tab: 1, page: 11, day: -1, content: true),
            slot(tab: 2, page: 22, day: -1, content: false),
        ])
        XCTAssertEqual(projection.units.last?.pageIDs, [11, 22])
        XCTAssertEqual(projection.hiddenBlankPages, 0)
    }

    /// The middle day's expiry, which is the first of the issue's three
    /// questions. The scroll closes up and the gap lives in the labels:
    /// -1d then -3d, with nothing standing in for the day that went. A
    /// row held open for a day whose page died would be a tombstone for
    /// dead content, and the tab underneath is standing anyway.
    func testAnExpiredMiddleDayLeavesAGapInTheLabelsAndNoRow() {
        let before = project([
            slot(tab: 1, page: 11, day: -1, content: true),
            slot(tab: 2, page: 22, day: -2, content: true),
            slot(tab: 3, page: 33, day: -3, content: true),
        ])
        XCTAssertEqual(before.units.map(\.bucket), [0, -1, -2, -3])

        // The middle page expired: its slot stands, empty and named.
        let after = project([
            slot(tab: 1, page: 11, day: -1, content: true),
            slot(tab: 2),
            slot(tab: 3, page: 33, day: -3, content: true),
        ])
        XCTAssertEqual(after.units.map(\.bucket), [0, -1, -3], "the day that went left a row behind")
        XCTAssertEqual(after.units.map(\.label), ["Today", "-1d", "-3d"])
        XCTAssertEqual(after.hiddenBlankPages, 0)
    }

    // MARK: The count of what is not shown

    /// Nine slots can fill with old pages that have nothing on them, and
    /// the projection draws none of them: today becomes unreachable with
    /// no visible cause. The count is the honesty valve, and the
    /// instrument for the content predicate itself — routinely above
    /// zero means the bar is wrong (ADR-0020's eject triggers).
    func testTheHiddenCountIsTheLivePagesTheProjectionDrops() {
        let projection = project([
            slot(tab: 1, page: 11, day: -1, content: false),
            slot(tab: 2, page: 22, day: -2, content: false),
            slot(tab: 3, page: 33, day: -2, content: false),
            slot(tab: 4, page: 44, day: -3, content: true),
            slot(tab: 5),
        ])
        XCTAssertEqual(projection.units.map(\.bucket), [0, -3])
        XCTAssertEqual(projection.hiddenBlankPages, 3, "the footer would understate what is hidden")
    }

    // MARK: The gauge

    /// A row shows how long the day has left, not how long its first
    /// page has: the gauge is the soonest-dying page's, so a day cannot
    /// look comfortable while something on it is minutes from going.
    func testTheGaugeComesFromTheSoonestDyingPage() throws {
        let projection = project([
            slot(
                tab: 1, page: 11, day: -1, content: true, remainingMs: 7_200_000,
                fraction: 0.9, remaining: "2h"),
            slot(
                tab: 2, page: 22, day: -1, content: true, remainingMs: 600_000,
                fraction: 0.1, paused: true, toppedUp: true, lastHour: true, remaining: "10m"),
        ])
        let day = try XCTUnwrap(projection.units.last)
        XCTAssertEqual(day.remainingLabel, "10m")
        XCTAssertEqual(day.fractionRemaining, 0.1)
        XCTAssertTrue(day.paused)
        XCTAssertTrue(day.toppedUp)
        XCTAssertTrue(day.lastHour)
    }

    /// A day with nothing on it has no clock to report, so the gauge
    /// fields are quiet and the rail draws its empty rule over them
    /// rather than a full bar that would read as a page with all its
    /// time left.
    func testADayWithNoPageReportsNoClock() {
        let today = project([]).units.first
        XCTAssertEqual(today?.fractionRemaining, 0)
        XCTAssertEqual(today?.remainingLabel, "")
        XCTAssertEqual(today?.paused, false)
        XCTAssertEqual(today?.lastHour, false)
    }

    // MARK: How a day reads

    /// The label tables, both of them. Relative rather than dated, which
    /// is what lets a missing day show as a jump and what lets local
    /// midnight roll every label over on the redraw the app already
    /// runs.
    func testTheLabelsAreRelativeAndSpokenInFull() {
        XCTAssertEqual(TimeUnit.day.label(bucket: 0), "Today")
        XCTAssertEqual(TimeUnit.day.label(bucket: -1), "-1d")
        XCTAssertEqual(TimeUnit.day.label(bucket: -7), "-7d")
        XCTAssertEqual(TimeUnit.day.spokenLabel(bucket: 0), "today")
        XCTAssertEqual(TimeUnit.day.spokenLabel(bucket: -1), "yesterday")
        XCTAssertEqual(TimeUnit.day.spokenLabel(bucket: -7), "7 days ago")
        // The bucketing is parameterised where a coarser unit would
        // divide; for the day the core has already counted in days.
        XCTAssertEqual(TimeUnit.day.bucket(dayOffset: -3), -3)
    }

    /// A page cannot honestly be born tomorrow, so a bucket above zero
    /// means the host clock went backwards between the stamp and the
    /// reading. The mode calls that page today's rather than inventing a
    /// future day, and it draws it rather than hiding it: a duplicate
    /// label is a smaller lie than a page nobody can see.
    func testAClockThatWentBackwardsCannotInventAFutureDay() {
        XCTAssertEqual(TimeUnit.day.label(bucket: 3), "Today")
        XCTAssertEqual(TimeUnit.day.spokenLabel(bucket: 3), "today")

        let projection = project([slot(tab: 1, page: 11, day: 3, content: false)])
        XCTAssertEqual(projection.units.map(\.bucket), [3, 0])
        XCTAssertEqual(projection.units.map(\.label), ["Today", "Today"])
        XCTAssertEqual(projection.hiddenBlankPages, 0, "a page from a skewed clock went missing")
    }

    // MARK: Where the selection lands in the mode

    /// The mode's own reconciliation. The strip keeps a selection on a
    /// slot whose page expired, deliberately, because the slot is still
    /// on screen; here it is not, so the selection falls to the newest
    /// visible page. With nothing visible anywhere it stays where it is,
    /// which is the empty Today the create grant is waiting on — and it
    /// mints nothing in either case (ADR-0017).
    func testTheModesSelectionFallsToTheNewestVisiblePage() {
        let peopled = project([
            slot(tab: 1, page: 11, day: -1, content: true),
            slot(tab: 2),
        ])
        XCTAssertEqual(
            PageModel.reconciledTimeSelection(current: 2, projection: peopled), 1,
            "the selection stayed on a slot the rail does not draw")
        XCTAssertEqual(
            PageModel.reconciledTimeSelection(current: 1, projection: peopled), 1,
            "a selection the rail is drawing was moved anyway")

        let bare = project([slot(tab: 2)])
        XCTAssertEqual(
            PageModel.reconciledTimeSelection(current: 2, projection: bare), 2,
            "with no page in sight the selection must stay where it is")
        XCTAssertNil(PageModel.reconciledTimeSelection(current: nil, projection: bare))
    }
}
