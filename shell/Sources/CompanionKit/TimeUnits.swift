import Foundation

/// Which unit of time a page is filed under, and how that unit reads
/// out loud (issue #79).
///
/// One case, deliberately. The issue asks for the unit to be
/// configurable and to start with the day, and this is what starting
/// with the day costs honestly: the bucketing is parameterised at the
/// seam where retrofitting it later would be expensive, and nothing
/// here guesses at a week. A week needs a week-start policy — Sunday or
/// Monday, the locale's or a fixed one — and probably a second field on
/// the summary, and a prototype has no basis to choose either. When one
/// is designed it arrives as a second case here, and every law below is
/// already asking this enum rather than assuming a day.
public enum TimeUnit: String, Sendable {
    /// A local day, as the core counts them: the offset on the summary
    /// is already relative to today and already folded through the
    /// store's own UTC offset, so nothing up here has to know what
    /// today is or be told when it changes.
    case day

    /// The bucket a page's day-relative offset falls in. The identity
    /// for a day, because the core is already counting in the unit the
    /// mode groups by; a coarser unit divides here, and this is the one
    /// line it would divide in.
    public func bucket(dayOffset: Int) -> Int {
        switch self {
        case .day:
            return dayOffset
        }
    }

    /// The label the rail draws: "Today", "-1d", "-3d".
    ///
    /// Relative rather than dated, which is the whole reason a day whose
    /// page expired can simply be absent: the reader sees Today, -1d,
    /// -3d and reads the jump straight off the labels, with no ghost row
    /// standing in for the day that went. It is also what lets local
    /// midnight roll the reading over on the redraw the app already
    /// runs, since the offsets behind it are recomputed on every read.
    ///
    /// A bucket above zero renders as Today as well. A page cannot
    /// honestly be born tomorrow, so a positive offset means the host
    /// clock moved backwards between the stamp and the reading, and the
    /// friendlier lie is to call that page today's rather than to
    /// invent a future day and put it above today on the rail.
    public func label(bucket: Int) -> String {
        switch self {
        case .day:
            return bucket >= 0 ? "Today" : "\(bucket)d"
        }
    }

    /// The same label as a phrase, for the accessibility label and the
    /// tooltip: "today", "yesterday", "3 days ago".
    ///
    /// Doc 05 asks that nothing be abbreviation-only, so the short form
    /// rides the rail where the column is 56pt wide and this one rides
    /// everywhere a full sentence fits.
    public func spokenLabel(bucket: Int) -> String {
        switch self {
        case .day:
            if bucket >= 0 { return "today" }
            if bucket == -1 { return "yesterday" }
            return "\(-bucket) days ago"
        }
    }
}

/// The live pages grouped by the day they were born on: everything the
/// time-unit mode draws, derived from the tab summaries and nothing
/// else (issue #79).
///
/// A unit of time is not an object the app creates, names, orders or
/// reaps. It is this — a query over the pages that happen to be alive,
/// recomputed whenever anyone asks, persisted nowhere. That is what
/// keeps the calendar from becoming a second lifetime mechanism for
/// tabs (ADR-0017's named eject trigger): no tab is created, closed,
/// re-dated, re-ordered or re-labelled here, because this type cannot
/// reach a tab at all. It reads summaries and returns a shape.
///
/// Every law of the model lives in `project(tabs:selectedPageID:unit:)`
/// and nowhere else, so the views that come later have nothing left to
/// decide and the whole model is under test without a window, an
/// AppKit object or a running core (ADR-0020).
public struct TimeUnitProjection: Equatable, Sendable {
    /// One day, as the rail and the roll draw it.
    ///
    /// The gauge fields are a rendering convenience rather than a fact
    /// about the day: they are the shipped `GaugeBar`'s four arguments,
    /// taken from the one page in this day that dies soonest, so a row
    /// showing several pages says how long the day has left rather than
    /// how long its first page has. A day holding no page carries the
    /// quiet values and the rail draws `EmptyRule` over them instead.
    public struct Unit: Equatable, Sendable, Identifiable {
        /// How far back this day is, in units, counted from today: 0
        /// for today, -1 for yesterday. Unique within a projection,
        /// which is what makes it the identity as well.
        public let bucket: Int
        /// "Today", "-1d" — what the rail draws.
        public let label: String
        /// "today", "yesterday" — what VoiceOver says.
        public let spokenLabel: String
        /// The pages this day holds, in strip order. Empty only for
        /// today, which is a place whether or not a page stands in it.
        public let pageIDs: [UInt64]
        /// The slots those pages are standing in, in the same order.
        /// The rail navigates by these; it never renames, re-orders or
        /// closes one, because a day is not a slot.
        public let tabIDs: [UInt64]
        /// The soonest-dying page's share of its rung still to run.
        public let fractionRemaining: Double
        /// The soonest-dying page is held.
        public let paused: Bool
        /// That hold is already at its ceiling, so the next press
        /// releases it rather than topping it up.
        public let toppedUp: Bool
        /// The soonest-dying page is inside its last hour.
        public let lastHour: Bool
        /// What that page's countdown reads, "2h" or "14m".
        public let remainingLabel: String

        public var id: Int { bucket }
    }

    /// The visible days, newest first: today at the top, then back
    /// through whatever is still alive. Days whose pages have all
    /// expired are simply absent, and the gap shows in the labels
    /// rather than as a row standing in for something that is gone.
    public let units: [Unit]

    /// How many live pages the projection is not showing.
    ///
    /// Every page this counts is blank, because a page with something
    /// on it would have made its own day appear. The rail's footer says
    /// the number out loud, and the cap refusal names the toggle that
    /// brings those pages back, because nine slots full of blank old
    /// pages would otherwise make today unreachable with no visible
    /// cause. Nothing is auto-discarded to make room: reaping blank
    /// pages is a lifetime mechanism nobody asked for. The number is
    /// also the instrument for the content predicate itself — if it is
    /// routinely above zero in dogfood, the bar is set wrong
    /// (ADR-0020's eject triggers).
    public let hiddenBlankPages: Int

    /// Group the live pages into days. The single entry point, and the
    /// only place any of this is decided.
    ///
    /// The laws, in the order the walk applies them:
    ///
    /// - A page belongs to the day its own creation stamp falls on,
    ///   never its tab's. A slot outlives every page that stands in it,
    ///   so a page opened this morning into a tab from last week is
    ///   today's page; the core answers with the page's stamp for
    ///   exactly that reason.
    /// - A day is drawn when any page on it has something on it, or it
    ///   is today, or it holds the page the user has selected. Today is
    ///   always a place, even with nothing in it. The selected page's
    ///   day is always drawn so that the region under the caret does
    ///   not pop into existence on the first typed character.
    /// - A day that is drawn shows every page it holds, in strip order.
    ///   The filter is by day and not by page: a day the rail is
    ///   showing shows everything on it, so a page never quietly
    ///   vanishes out of a day that is on screen.
    /// - A day's gauge comes from its soonest-dying page, ties going to
    ///   the earlier one in strip order.
    ///
    /// Pure, `nonisolated` and over value types, so the whole model can
    /// be argued in tests that build no window and touch no core.
    public nonisolated static func project(
        tabs: [TabSummary], selectedPageID: UInt64?, unit: TimeUnit
    ) -> TimeUnitProjection {
        var rows: [Int: [TabSummary]] = [:]
        // A summary that claims a page but names neither its id nor its
        // day is not something the mode can draw or navigate to, so it
        // is carried nowhere — and counted, because a live page the
        // surface is not showing is exactly what the footer is for.
        var hidden = 0
        for tab in tabs {
            guard tab.hasPage else { continue }
            guard tab.pageID != nil, let offset = tab.pageDayOffset else {
                hidden += 1
                continue
            }
            rows[unit.bucket(dayOffset: offset), default: []].append(tab)
        }

        var buckets = Set(rows.keys)
        // Today is a place, not a page (ADR-0017): it has a row whether
        // or not a gesture has put anything on it, and rendering it
        // costs nothing, where minting it would start a countdown
        // nobody asked for.
        buckets.insert(unit.bucket(dayOffset: 0))
        var units: [Unit] = []
        for bucket in buckets.sorted(by: >) {
            let pages = rows[bucket] ?? []
            let holdsSelection = selectedPageID.map { id in
                pages.contains { $0.pageID == id }
            } ?? false
            // Above zero counts as today for `label`'s reason: a page
            // cannot be born tomorrow, so a bucket in the future is a
            // clock that went backwards, and its page belongs on screen
            // rather than hidden behind an arithmetic nobody can see.
            let drawn = bucket >= 0 || holdsSelection || pages.contains(where: \.pageHasContent)
            guard drawn else {
                hidden += pages.count
                continue
            }
            let soonest = pages.min { $0.remainingMs < $1.remainingMs }
            units.append(Unit(
                bucket: bucket,
                label: unit.label(bucket: bucket),
                spokenLabel: unit.spokenLabel(bucket: bucket),
                pageIDs: pages.compactMap(\.pageID),
                tabIDs: pages.map(\.id),
                fractionRemaining: soonest?.fractionRemaining ?? 0,
                paused: soonest?.paused ?? false,
                toppedUp: soonest?.holdToppedUp ?? false,
                lastHour: soonest?.lastHour ?? false,
                remainingLabel: soonest?.remainingLabel ?? ""
            ))
        }
        return TimeUnitProjection(units: units, hiddenBlankPages: hidden)
    }
}
