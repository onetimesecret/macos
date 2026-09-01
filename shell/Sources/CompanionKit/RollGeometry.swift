import SwiftUI

/// Where the days stand in the roll, and how much of it the reader can
/// see: the measurement behind the rail's minimap (issue #131).
///
/// Geometry and nothing else. An extent is a day's top and height in the
/// roll's own document coordinates, which is a fact about how much page
/// that day holds, and the viewport is the window the clip has open onto
/// it. No text, no attributed string, no snapshot of a rendered page
/// crosses this type, and that is the load-bearing decision rather than
/// an economy: a minimap drawn from glyphs would be a second surface
/// rendering page content, it would have to reimplement how a concealed
/// block draws, and it would invite an argument about whether two point
/// text is legible. Rectangles cannot leak a word.
///
/// Measured by the roll (`DayStackView.measuredGeometry`), mapped into
/// the rail by `RailMinimap`, and carried between them as a value, so
/// the whole path is testable without a window at one end and with one
/// at the other.
public struct RollGeometry: Equatable, Sendable {
    /// One day's span down the roll: where its first header begins and
    /// how far its last page reaches.
    public struct Extent: Equatable, Sendable {
        /// The day this span belongs to, 0 for today, as the projection
        /// counts them.
        public let bucket: Int
        /// The top of the day's first header, measured down from the
        /// top of the document.
        public let top: CGFloat
        /// Down to the bottom of the day's last page. Never negative,
        /// and possibly a hair short of a point on a day the layout has
        /// not measured yet.
        public let height: CGFloat

        public init(bucket: Int, top: CGFloat, height: CGFloat) {
            self.bucket = bucket
            self.top = top
            self.height = height
        }

        public var bottom: CGFloat { top + height }
    }

    /// The days, in document order: today first, the days before it
    /// under it, exactly the order the roll lays them out in.
    public let extents: [Extent]
    /// How tall the whole roll is. Zero before the first layout pass,
    /// which is the signal that there is nothing honest to draw yet.
    public let documentHeight: CGFloat
    /// Where the clip is, measured down from the top of the document.
    /// Can be negative for the length of an elastic overscroll, which
    /// the mapping clamps rather than refuses.
    public let viewportTop: CGFloat
    /// How much of the roll the clip has open.
    public let viewportHeight: CGFloat

    public init(
        extents: [Extent], documentHeight: CGFloat, viewportTop: CGFloat, viewportHeight: CGFloat
    ) {
        self.extents = extents
        self.documentHeight = documentHeight
        self.viewportTop = viewportTop
        self.viewportHeight = viewportHeight
    }

    /// A roll nobody has measured: what the rail draws over before the
    /// first layout pass, and what a roll going away leaves behind. The
    /// minimap over it is empty rather than wrong, which is the only
    /// honest reading of a document with no height.
    public static let unmeasured = RollGeometry(
        extents: [], documentHeight: 0, viewportTop: 0, viewportHeight: 0
    )

    /// Fold the roll's rows into days.
    ///
    /// The roll lays out one row per page, and a day can hold more than
    /// one page; the rail draws one row per day. Two pages born on one
    /// day are therefore one extent covering both, which is what keeps
    /// the minimap's bars in the same count and the same order as the
    /// rail's rows. Count and order are the whole of the agreement: the
    /// bars are a scaled impression of the roll in their own space, so a
    /// bar is not level with the row for the same day and is not meant
    /// to be. Consecutive rather than grouped, because
    /// the roll already emits a day's pages together and an extent that
    /// jumped a gap would claim ground belonging to the day in between.
    ///
    /// Pure, so the fold is an assertion rather than something inferred
    /// from a mounted stack.
    public static func merging(_ measured: [Extent]) -> [Extent] {
        var merged: [Extent] = []
        for extent in measured {
            guard let last = merged.last, last.bucket == extent.bucket else {
                merged.append(extent)
                continue
            }
            let top = min(last.top, extent.top)
            merged[merged.count - 1] = Extent(
                bucket: last.bucket, top: top, height: max(last.bottom, extent.bottom) - top
            )
        }
        return merged
    }
}

/// The roll's measurement, published for the rail alone.
///
/// Its own observable rather than a field on `PageModel` because the
/// viewport moves on every scroll event, and a published change on the
/// model would redraw the header, the status stack and the page along
/// with the minimap. Observed by the minimap and by nothing else, a
/// scroll costs a few rectangles.
///
/// Every publication takes a hop through the main actor's queue, and
/// that is not a throttle for its own sake: `relayout` runs inside
/// `updateNSView`, and observable state written there is state written
/// during a SwiftUI render pass. The hop puts the change after the pass
/// that measured it. It coalesces on the way, so a burst of scroll
/// notifications inside one turn of the loop lands as one redraw.
@MainActor
public final class RollGeometryModel: ObservableObject {
    /// What the roll last measured. `unmeasured` until a roll is
    /// mounted and laid out.
    @Published public private(set) var geometry: RollGeometry = .unmeasured

    /// The measurement waiting for the hop, if one is in flight.
    private var pending: RollGeometry?

    /// The roll measured itself. Nothing is published if the answer is
    /// the one already on screen, which is the common case: the roll
    /// re-measures on every cosmetic redraw, and a countdown ticking
    /// moves no frame.
    func publish(_ measured: RollGeometry) {
        guard measured != geometry else {
            // The roll came back to where it already was before the hop
            // could run, so there is nothing left to say.
            pending = nil
            return
        }
        let alreadyScheduled = pending != nil
        pending = measured
        guard !alreadyScheduled else { return }
        Task { @MainActor [weak self] in self?.settle() }
    }

    /// The roll is going away, or a fresh one is arriving with nothing
    /// laid out yet. Through the same hop as any other publication, for
    /// the same reason: a mount happens inside `makeNSView`.
    func reset() {
        publish(.unmeasured)
    }

    private func settle() {
        guard let next = pending else { return }
        pending = nil
        geometry = next
    }
}

/// The map from the roll's coordinates to the rail's: what the faint
/// background behind the days is made of (issue #131).
///
/// Two shapes and no more. A bar per day, as tall a share of the rail as
/// that day is of the roll, so a day holding a long page reads as a
/// taller smear than a day holding a line. A band over the part of the
/// roll the reader can see, which moves as the roll scrolls. Both are
/// pure functions of a measurement and a height, in the idiom
/// `TimeRailView.selectedBucket` and `chord(forRowAt:)` set, so the
/// whole minimap is under test without a window.
public enum RailMinimap {
    /// One day's share of the rail: where it starts and how tall it is,
    /// in the rail's own coordinates, top down.
    public struct Bar: Equatable, Sendable {
        public let bucket: Int
        public let y: CGFloat
        public let height: CGFloat
    }

    /// The part of the roll the reader can see, in the same
    /// coordinates.
    public struct Band: Equatable, Sendable {
        public let y: CGFloat
        public let height: CGFloat
    }

    /// The least a shape may be drawn as. A day holding one short line
    /// out of a very long roll scales to a fraction of a point, and a
    /// bar rounded away would say the day holds nothing when the rail
    /// is drawing a row for it right there.
    public static let hairline: CGFloat = 2

    /// The days, mapped. Empty before the roll has been measured: a
    /// document with no height has no proportions, and inventing some
    /// would draw a shape that is not a reading of anything.
    ///
    /// A walk rather than a map, because the hairline floor is what
    /// makes the bars able to collide. A day scaled to a fifth of a
    /// point is drawn two points tall, which is ground the next day was
    /// going to start on, and two faint fills over one another are twice
    /// the ink: the seam would read as a mark rather than as the join it
    /// is. So each bar starts no higher than where the one above it
    /// ended, and the borrowed room comes off the day below, which is
    /// the day that had room to spare.
    ///
    /// The floor yields to the foot of the rail and never the other way
    /// round. A last day pushed against the bottom is drawn thinner than
    /// a hairline rather than hanging off the column or climbing back
    /// over its neighbour, and a rail too short to give every day a
    /// hairline runs out of room honestly, in the order the days come
    /// in.
    public static func bars(of roll: RollGeometry, in height: CGFloat) -> [Bar] {
        guard height > 0, roll.documentHeight > 0 else { return [] }
        let scale = height / roll.documentHeight
        let floor = min(hairline, height)
        var bars: [Bar] = []
        // Where the last bar ended, which is the highest the next one may
        // begin.
        var settled: CGFloat = 0
        for extent in roll.extents {
            let top = max(clamped(extent.top * scale, from: 0, to: height), settled)
            let bottom = clamped(extent.bottom * scale, from: top, to: height)
            let wanted = max(bottom - top, floor)
            let y = max(min(top, height - wanted), settled)
            let drawn = max(min(wanted, height - y), 0)
            bars.append(Bar(bucket: extent.bucket, y: y, height: drawn))
            settled = y + drawn
        }
        return bars
    }

    /// The viewport band, or nothing at all when the whole roll is on
    /// screen: a band around everything marks nothing, and the pad
    /// spends most of its life holding less page than a card. It is the
    /// scrolled reader the band exists for.
    ///
    /// An elastic overscroll puts the clip above the document or below
    /// its end. The band clamps into the rail rather than hanging off
    /// it, so the rubber band at the top of the roll reads as the band
    /// resting against the ceiling.
    public static func band(of roll: RollGeometry, in height: CGFloat) -> Band? {
        guard height > 0, roll.documentHeight > 0, roll.viewportHeight > 0,
              roll.viewportHeight < roll.documentHeight else { return nil }
        let scale = height / roll.documentHeight
        let top = clamped(roll.viewportTop * scale, from: 0, to: height)
        let bottom = clamped(
            (roll.viewportTop + roll.viewportHeight) * scale, from: top, to: height
        )
        let drawn = max(bottom - top, min(hairline, height))
        return Band(y: min(top, height - drawn), height: drawn)
    }

    private static func clamped(_ value: CGFloat, from low: CGFloat, to high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }
}
