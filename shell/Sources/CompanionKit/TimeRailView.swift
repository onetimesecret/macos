import SwiftUI

/// The days down the leading edge of the card: one row per unit of time
/// the projection is showing, newest at the top (issue #79).
///
/// Navigation, and deliberately nothing else. A row says which day it
/// is, shows how long the page on it that dies soonest has left, and
/// takes you there when it is clicked. It offers no rename, no close,
/// no rung, no hold and no drag-reorder: days have an order the user
/// does not shuffle and a label the user does not type, and a rail that
/// could close a day would be exactly the misreading ADR-0017's eject
/// trigger is about. Those four verbs are not lost: they sit on each
/// page's own gutter inside the roll, where a day holding two pages can
/// still say which of them is being renamed or closed.
///
/// A slot holding no page draws no row here, because a slot holding no
/// page is on no day. The tab is still standing underneath, named and
/// empty exactly as `expire_due` left it, and the strip shows it again
/// the moment the mode goes off. Nothing on this rail mints: today has
/// a row whether or not anything stands in it, and the row a click on
/// it lands on is the shipped create path, not a mint of its own
/// (ADR-0017).
///
/// It reuses `GaugeBar` and `EmptyRule` where they stand rather than
/// moving them, so `TabStripView.swift` takes no diff at all and the
/// claim that horizontal mode is untouched is a fact about the diff.
public struct TimeRailView: View {
    @ObservedObject var model: PageModel

    public init(model: PageModel) {
        self.model = model
    }

    /// The rail's width, fixed. It eats into the page's column and not
    /// into the header, which is why `BackdropGeometry.minWidth` and the
    /// clamp its tests pin do not move for this mode. Whether the card
    /// wants a wider floor while the days are showing is a question for
    /// the dogfood window rather than a number to guess at now.
    ///
    /// Ninety six points, up from fifty six, and the words are what
    /// bought them (issue #131). It is the measure that holds the
    /// longest phrase the rail can realistically be asked for, "10 days
    /// ago" from a page held past its rung, in the monospaced caption
    /// the rows draw in, with the row's own padding still around it.
    /// Longer than that truncates at the tail, which is the net rather
    /// than the plan.
    static let width: CGFloat = 96

    public var body: some View {
        let projection = model.timeUnits
        let selected = Self.selectedBucket(projection: projection, selection: model.selection)
        VStack(spacing: 2) {
            ForEach(rows(of: projection)) { row in
                TimeUnitTab(
                    unit: row.unit,
                    selected: !model.showingLedger && row.unit.bucket == selected,
                    chord: row.chord,
                    model: model
                )
            }
            Spacer(minLength: 4)
            hiddenPages(count: projection.hiddenBlankPages)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .background(Color.panelBackground)
    }

    /// The days paired with the chords that reach them, resolved before
    /// the list is built so the view builder stays a list rather than a
    /// lookup. A row's place decides its chord and its day decides its
    /// identity, which is the pairing this walk exists to make.
    private func rows(of projection: TimeUnitProjection) -> [TimeRailRow] {
        var rows: [TimeRailRow] = []
        for (index, unit) in projection.units.enumerated() {
            let chord = Self.chord(forRowAt: index, keymap: model.keymap)
            rows.append(TimeRailRow(unit: unit, chord: chord))
        }
        return rows
    }

    /// The honesty valve for the nine-slot wall, and the instrument for
    /// the content predicate itself.
    ///
    /// Nine slots can fill with old pages that have nothing on them.
    /// The projection draws none of them, so today becomes unreachable
    /// with no visible cause, and the refusal reads as a bug rather
    /// than as a full pad. The count says so out loud, and its tooltip
    /// names the toggle that brings those pages back. Nothing is
    /// auto-discarded to make room: reaping blank pages is a lifetime
    /// mechanism nobody asked for (ADR-0016).
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
    /// too. A selection standing in a slot the rail draws no row for (an
    /// empty slot, or a blank old page the content bar is holding
    /// back) lights nothing at all: what is on screen is then not on
    /// the rail, and marking a row would say the surface is somewhere
    /// it is not.
    ///
    /// Today is the one row that can answer to no slot, and while it
    /// holds no page it takes the mark only by elimination, on the pad
    /// where no drawn day holds a page, so there is nothing else the
    /// mark could sit on and today is the place the next page would
    /// land. Pure, because which row is lit is a decision and not a
    /// drawing.
    static func selectedBucket(projection: TimeUnitProjection, selection: UInt64?) -> Int? {
        if let selection,
            let day = projection.units.first(where: { $0.tabIDs.contains(selection) }) {
            return day.bucket
        }
        guard projection.units.allSatisfy({ $0.pageIDs.isEmpty }) else { return nil }
        return projection.units.first { $0.bucket == 0 }?.bucket
    }

    /// The ⌘-number that lands on the row at this place on the rail.
    ///
    /// ⌘1 to ⌘9 count the rail's rows while the mode is on, so the row at
    /// index 1 is what ⌘2 selects and its tooltip can say so. Asked of
    /// the keymap rather than spelled here, for `newPageHelp`'s reason:
    /// a user who moved the chord moves the tooltip with it, and a user
    /// who unbound it gets a tooltip that says only what the row does.
    /// Nothing is bound past the ninth row, and a tenth day (which
    /// takes ten live pages, one over the cap) simply has no chord.
    static func chord(forRowAt index: Int, keymap: ResolvedKeymap) -> Keystroke? {
        let number = index + 1
        guard let command = CommandID.allCases.first(where: { $0.selectsPageNumber == number })
        else { return nil }
        return keymap.hintKeystroke(for: command)
    }

    /// What the footer prints, or nothing at all when nothing is being
    /// held back. Short, because it is a footer and not a row: it counts
    /// what the rail is not showing, and a sentence at the bottom of the
    /// column would weigh more than the days above it. The sentence
    /// rides the tooltip and the accessibility label instead, and "3
    /// blank" is words rather than an abbreviation, so doc 05's rule is
    /// answered at both ends.
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

/// One row of the rail, ready to draw: a day and the chord that reaches
/// it.
///
/// Identified by its day and never by its place, so a day expiring out
/// of the middle of the rail does not shuffle the identity of every row
/// under it. At file scope rather than nested in the view because a
/// row is a value the view happens to build, and because `Identifiable`
/// wants an `id` no actor is holding.
private struct TimeRailRow: Identifiable {
    let unit: TimeUnitProjection.Unit
    let chord: Keystroke?

    var id: Int { unit.bucket }
}

/// One day on the rail: its relative label in words over the gauge of
/// the page on it that dies soonest, or the dashed rule when the day
/// holds no page at all.
///
/// Internal rather than private so the three pure decisions below (the
/// target a tap resolves to and the two tooltips) can be tested without
/// a window, in the idiom `TabStripView.newPageHelp` and
/// `SheetTab.holdMenuTitle` set.
struct TimeUnitTab: View {
    let unit: TimeUnitProjection.Unit
    let selected: Bool
    /// The chord that does what a click here does, when the keymap
    /// bound one to this row's place. Nil is not a failure: it is a row
    /// past the ninth, or a keymap that took the binding away.
    let chord: Keystroke?
    @ObservedObject var model: PageModel

    var body: some View {
        VStack(spacing: 3) {
            Text(unit.railLabel)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            if unit.pageIDs.isEmpty {
                // The strip's own treatment for a place with no clock
                // in it: a gauge at zero would read as a page an
                // instant from death rather than as today waiting to be
                // written on (ADR-0017).
                EmptyRule()
                    .frame(height: 3)
                    .padding(.horizontal, 3)
            } else {
                GaugeBar(
                    fraction: unit.fractionRemaining,
                    paused: unit.paused,
                    toppedUp: unit.toppedUp,
                    lastHour: unit.lastHour
                )
                .frame(height: 3)
                .padding(.horizontal, 3)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.cellBackground : .clear)
        )
        .contentShape(Rectangle())
        // One tap, one meaning. The strip's second tap holds the page's
        // clock; a day is not a clock and holds nothing, so there is no
        // double-tap here and no gesture to lose a race with.
        .onTapGesture { model.select(target: Self.target(for: unit)) }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(unit.spokenLabel))
        .accessibilityValue(Text(unit.spokenRemaining))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Where a tap on this row lands.
    ///
    /// The same answer the keyboard gets, and deliberately the same
    /// shape: a day answers with its first page's slot, and only today
    /// can answer with no slot at all. `PageModel.visibleTargets` maps
    /// the very same units the very same way, so a click on the second
    /// row and ⌘2 cannot disagree about where the second day is.
    static func target(for unit: TimeUnitProjection.Unit) -> SurfaceTarget {
        guard let tab = unit.tabIDs.first else { return .today }
        return .tab(tab)
    }

    /// The tooltip: what this row does, and the chord that does it too.
    /// Today with nothing on it is the one row whose click makes
    /// something, so it says so rather than promising a page that is
    /// not there yet.
    private var helpText: String {
        guard unit.pageIDs.isEmpty else {
            return Self.dayHelp(spokenLabel: unit.spokenLabel, chord: chord)
        }
        return Self.todayHelp(hasPage: false, chord: chord)
    }

    /// A row's tooltip: what the row does, in the same words the row
    /// itself now shows. It used to be where the phrase behind "-3d"
    /// lived, and issue #131 moved the phrase onto the rail; what is
    /// left is the verb and the chord, which is the part a label cannot
    /// carry. With nothing bound it says only what the row does, which
    /// is still true.
    static func dayHelp(spokenLabel: String, chord: Keystroke?) -> String {
        chorded("Go to \(spokenLabel)", chord: chord)
    }

    /// Today's tooltip, which has two readings. Today already holding a
    /// page is a jump like any other; today holding none is the one
    /// place on the rail where a click conjures something, and saying
    /// "go to today" there would describe a page that does not exist.
    /// The two agree word for word about the day that has one, so a row
    /// that gains a page reads the same either way it was asked.
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
