import XCTest
@testable import CompanionKit

@MainActor
final class TimeUnitNaturalOrderTests: XCTestCase {
    private func tab(
        _ id: UInt64, page: UInt64? = nil, day: Int = 0, content: Bool = true,
        remainingMs: UInt64 = 3_600_000, fraction: Double = 0.5,
        paused: Bool = false, toppedUp: Bool = false, lastHour: Bool = false,
        remaining: String = "1h", spoken: String = "one hour"
    ) -> TabSummary {
        TabSummary(
            id: id, hasPage: page != nil, pageID: page,
            title: "slot \(id)", titleSource: .derived, rungCode: 5, rungLabel: "7d",
            remainingMs: remainingMs, remainingLabel: remaining, spokenRemaining: spoken,
            fractionRemaining: fraction, paused: paused, holdToppedUp: toppedUp,
            holdRemainingMs: 0, chipCount: 0, lastHour: lastHour,
            pageHasContent: page != nil && content, pageDayOffset: page == nil ? nil : day,
            pageCreatedMs: page.map { 1_791_000_000_000 + $0 * 1_000 }
        )
    }

    private func project(_ tabs: [TabSummary], selecting page: UInt64? = nil) -> TimeUnitProjection {
        TimeUnitProjection.project(tabs: tabs, selectedPageID: page, unit: .day)
    }

    func testCrossDayInterleavingFormsContiguousRunsWithUniquePageBasedIDs() {
        let tabs = [
            tab(7, page: 104), tab(8, page: 101, day: -1),
            tab(9, page: 105), tab(10, page: 103), tab(11, page: 102, day: -2)
        ]
        let grouped = project(tabs)
        XCTAssertTrue(grouped.units.allSatisfy { $0.sequenceID == nil && $0.id == $0.bucket })
        let natural = grouped.inNaturalOrder(tabs: tabs)
        XCTAssertEqual(natural.units.map(\.bucket), [0, -1, 0, -2])
        XCTAssertEqual(natural.units.map(\.pageIDs), [[104], [101], [105, 103], [102]])
        XCTAssertEqual(natural.units.map(\.tabIDs), [[7], [8], [9, 10], [11]])
        XCTAssertEqual(natural.units.map(\.id), [104, 101, 105, 102])
        XCTAssertEqual(Set(natural.units.map(\.id)).count, natural.units.count)
        for run in natural.units {
            let template = grouped.units.first { $0.bucket == run.bucket }
            XCTAssertEqual(run.label, template?.label)
            XCTAssertEqual(run.railLabel, template?.railLabel)
            XCTAssertEqual(run.spokenLabel, template?.spokenLabel)
        }
    }

    func testNaturalOrderUsesDrawnPageWhitelistAndRetainsHiddenBlankCount() {
        let tabs = [
            tab(1, page: 101), tab(2, page: 102, day: -2, content: false),
            tab(3, page: 103, day: -1), tab(4, page: 104, day: -1, content: false),
            tab(5), tab(6, page: 106)
        ]
        let grouped = project(tabs)
        let natural = grouped.inNaturalOrder(tabs: tabs)
        XCTAssertEqual(natural.units.map(\.pageIDs), [[101], [103, 104], [106]])
        XCTAssertEqual(Set(natural.units.flatMap(\.pageIDs)), Set(grouped.units.flatMap(\.pageIDs)))
        XCTAssertEqual(natural.hiddenBlankPages, 1)
        XCTAssertEqual(natural.hiddenBlankPages, grouped.hiddenBlankPages)
        let selected = project(tabs, selecting: 102).inNaturalOrder(tabs: tabs)
        XCTAssertEqual(selected.units.map(\.pageIDs), [[101], [102], [103, 104], [106]])
        XCTAssertEqual(selected.hiddenBlankPages, 0)
    }

    func testEmptyTodayRemainsBeforeRunsWithoutTakingAPageIdentity() {
        let tabs = [tab(1, page: 101, day: -1), tab(2, page: 102, day: -2)]
        let grouped = project(tabs)
        let natural = grouped.inNaturalOrder(tabs: tabs)
        XCTAssertEqual(natural.units.map(\.bucket), [0, -1, -2])
        XCTAssertEqual(natural.units.map(\.pageIDs), [[], [101], [102]])
        XCTAssertEqual(natural.units.map(\.id), [0, 101, 102])
        XCTAssertEqual(natural.units.first, grouped.units.first)
        XCTAssertEqual(natural.inNaturalOrder(tabs: tabs), natural)
        XCTAssertEqual(project([]).inNaturalOrder(tabs: []), project([]))
    }

    func testEachRunRecalculatesGaugeFromItsOwnSoonestSummaryWithStoredOrderTies() throws {
        let tabs = [
            tab(1, page: 101, remainingMs: 5_000, fraction: 0.8),
            tab(2, page: 102, remainingMs: 3_000, fraction: 0.6,
                paused: true, toppedUp: true, remaining: "3s", spoken: "three seconds"),
            tab(3, page: 103, remainingMs: 3_000, fraction: 0.4),
            tab(4, page: 104, day: -1),
            tab(5, page: 105, remainingMs: 1_000, fraction: 0.1,
                lastHour: true, remaining: "1s", spoken: "one second")
        ]
        let grouped = project(tabs)
        XCTAssertEqual(grouped.units.first?.fractionRemaining, 0.1)
        let natural = grouped.inNaturalOrder(tabs: tabs)
        let first = try XCTUnwrap(natural.units.first)
        XCTAssertEqual(first.pageIDs, [101, 102, 103])
        XCTAssertEqual(first.fractionRemaining, 0.6)
        XCTAssertTrue(first.paused)
        XCTAssertTrue(first.toppedUp)
        XCTAssertFalse(first.lastHour)
        XCTAssertEqual(first.remainingLabel, "3s")
        XCTAssertEqual(first.spokenRemaining, "three seconds")
        let last = try XCTUnwrap(natural.units.last)
        XCTAssertEqual(last.pageIDs, [105])
        XCTAssertEqual(last.fractionRemaining, 0.1)
        XCTAssertFalse(last.paused)
        XCTAssertFalse(last.toppedUp)
        XCTAssertTrue(last.lastHour)
        XCTAssertEqual(last.remainingLabel, "1s")
        XCTAssertEqual(last.spokenRemaining, "one second")
    }

    func testNaturalOrderRoundTripsGroupedSortsWithoutChangingSourceDates() {
        let tabs = [
            tab(1, page: 104), tab(2, page: 101, day: -1),
            tab(3, page: 103, day: -1), tab(4, page: 102)
        ]
        let sourceDates = tabs.map(\.pageCreatedMs)
        let sourceDays = tabs.map(\.pageDayOffset)
        let grouped = project(tabs)
        let natural = grouped.inNaturalOrder(tabs: tabs)
        for ascending in [true, false] {
            let reordered = grouped.units.sorted {
                ascending ? $0.bucket < $1.bucket : $0.bucket > $1.bucket
            }.map { unit in
                TimeUnitProjection.Unit(
                    bucket: unit.bucket, label: unit.label,
                    spokenLabel: unit.spokenLabel, railLabel: unit.railLabel,
                    pageIDs: Array(unit.pageIDs.reversed()), tabIDs: Array(unit.tabIDs.reversed()),
                    fractionRemaining: unit.fractionRemaining, paused: unit.paused,
                    toppedUp: unit.toppedUp, lastHour: unit.lastHour,
                    remainingLabel: unit.remainingLabel, spokenRemaining: unit.spokenRemaining
                )
            }
            let sorted = TimeUnitProjection(units: reordered, hiddenBlankPages: grouped.hiddenBlankPages)
            XCTAssertEqual(sorted.inNaturalOrder(tabs: tabs), natural)
        }
        XCTAssertEqual(natural.inNaturalOrder(tabs: tabs), natural)
        XCTAssertEqual(natural.units.map(\.pageIDs), [[104], [101, 103], [102]])
        XCTAssertEqual(tabs.map(\.pageCreatedMs), sourceDates)
        XCTAssertEqual(tabs.map(\.pageDayOffset), sourceDays)
    }

    func testFutureOffsetsFoldIntoTodayRuns() {
        let tabs = [tab(1, page: 101, day: 3), tab(2, page: 102, day: -1), tab(3, page: 103)]
        let natural = project(tabs).inNaturalOrder(tabs: tabs)
        XCTAssertEqual(natural.units.map(\.bucket), [0, -1, 0])
        XCTAssertEqual(natural.units.map(\.pageIDs), [[101], [102], [103]])
        XCTAssertEqual(natural.units.map(\.railLabel), ["Today", "Yesterday", "Today"])
    }

    func testRailRowsBelongOnlyToTheirOwnRunWhenDayBucketsRepeat() {
        let tabs = [tab(1, page: 101), tab(2, page: 102, day: -1), tab(3, page: 103)]
        let natural = project(tabs).inNaturalOrder(tabs: tabs)
        let nodes = StreamNavigator.nodes(projection: natural, tabs: tabs, selection: nil)
        let rows = natural.units.map { TimeRailView.nodes(for: $0, in: nodes) }
        XCTAssertEqual(rows.map { $0.compactMap(\.page) }, [[101], [102], [103]])
        XCTAssertEqual(rows.flatMap { $0 }.map(\.id), nodes.map(\.id))
    }

    func testEmptyTodayRailRowContainsOnlyTheEmptyNode() {
        let tabs = [tab(1, page: 101, day: -1)]
        let natural = project(tabs).inNaturalOrder(tabs: tabs)
        let nodes = StreamNavigator.nodes(projection: natural, tabs: tabs, selection: nil)
        let rows = natural.units.map { TimeRailView.nodes(for: $0, in: nodes) }
        XCTAssertEqual(rows.map(\.count), [1, 1])
        XCTAssertNil(rows[0][0].page)
        XCTAssertEqual(rows[1][0].page, 101)
    }
}
