import Combine
import XCTest

@testable import CompanionKit

/// The hop the roll's measurement takes on its way to the rail
/// (issue #131).
///
/// The mapping either side of it is a pure function with its own suite;
/// what is here is the one stateful piece between the roll and the
/// minimap, and the two questions it answers. Which roll is speaking,
/// now that a replacement can be built and measured before the surface
/// it replaces is dismantled; and how many redraws a burst of
/// measurements costs, which is the whole reason the publication is
/// coalesced rather than assigned. No window at either end: a publisher
/// is an object with an identity and nothing more.
@MainActor
final class RollGeometryModelTests: XCTestCase {
    /// A stand-in for the stack that publishes. The model names its
    /// publisher by identity alone and never reaches through the
    /// reference, so a test needs an object and nothing else.
    private final class Roll {}

    private func measured(_ documentHeight: CGFloat) -> RollGeometry {
        RollGeometry(
            extents: [RollGeometry.Extent(bucket: 0, page: 1, top: 0, height: documentHeight)],
            documentHeight: documentHeight,
            viewportTop: 0,
            viewportHeight: 100
        )
    }

    /// Let the queue turn. Every publication is deliberately one hop
    /// late, so nothing is true of this model until the loop has had a
    /// turn, and a test that asserted synchronously would be asserting
    /// on the pass that measured.
    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
    }

    /// A mount clears what the last roll left behind. The rail must not
    /// spend the pass between a roll going away and the next one laying
    /// itself out drawing the shape of a surface that is gone.
    func testAMountClearsWhatTheLastRollLeftBehind() async {
        let model = RollGeometryModel()
        let first = Roll()
        model.claim(by: first)
        model.publish(measured(300), from: first)
        await settle()
        XCTAssertEqual(model.geometry.documentHeight, 300)

        model.claim(by: Roll())
        await settle()
        XCTAssertEqual(model.geometry, .unmeasured, "a fresh roll inherited the last one's shape")
    }

    /// The interleaving SwiftUI actually performs when the ledger opens
    /// over the roll or the mode toggles: the replacement is built and
    /// measured before the surface it replaces is dismantled. The
    /// parting reset belongs to a roll nobody is drawing any more, so it
    /// says nothing, and the minimap keeps the measurement it was just
    /// given.
    func testATeardownCannotBlankTheRollThatReplacedIt() async {
        let model = RollGeometryModel()
        let old = Roll()
        model.claim(by: old)
        model.publish(measured(300), from: old)
        await settle()

        let new = Roll()
        model.claim(by: new)
        model.publish(measured(700), from: new)
        model.reset(from: old)
        await settle()

        XCTAssertEqual(
            model.geometry.documentHeight, 700,
            "the outgoing roll's teardown blanked the measurement of the roll replacing it")
    }

    /// And it cannot go on measuring either. A dismantled stack whose
    /// clip notification arrives late has no window to measure against,
    /// so what it would publish is an empty roll, which is the same
    /// blanking by another route.
    func testARollThatHasBeenReplacedNoLongerSpeaks() async {
        let model = RollGeometryModel()
        let old = Roll()
        model.claim(by: old)
        let new = Roll()
        model.claim(by: new)
        model.publish(measured(700), from: new)
        await settle()

        model.publish(.unmeasured, from: old)
        model.publish(measured(120), from: old)
        await settle()

        XCTAssertEqual(
            model.geometry.documentHeight, 700, "a replaced roll went on publishing")
    }

    // MARK: What a burst costs

    /// The common case, and the reason the model is asked before the
    /// rail is told: the roll re-measures on every cosmetic redraw, and
    /// a countdown ticking moves no frame. A measurement the rail is
    /// already drawing is not a redraw.
    func testAMeasurementTheRailIsAlreadyDrawingIsNotPublished() async {
        let model = RollGeometryModel()
        let roll = Roll()
        model.claim(by: roll)
        model.publish(measured(300), from: roll)
        await settle()

        var redraws = 0
        let watch = model.objectWillChange.sink { _ in redraws += 1 }
        defer { watch.cancel() }
        model.publish(measured(300), from: roll)
        await settle()

        XCTAssertEqual(redraws, 0, "the rail was redrawn for a roll that had not moved")
    }

    /// And a burst inside one turn of the loop is one redraw, which is
    /// what the hop is for. A flick sends a run of clip notifications
    /// before the loop turns, and the rail is interested in where the
    /// roll came to rest.
    func testABurstInsideOneTurnOfTheLoopIsOneRedraw() async {
        let model = RollGeometryModel()
        let roll = Roll()
        model.claim(by: roll)
        await settle()

        var redraws = 0
        let watch = model.objectWillChange.sink { _ in redraws += 1 }
        defer { watch.cancel() }
        model.publish(measured(300), from: roll)
        model.publish(measured(400), from: roll)
        model.publish(measured(500), from: roll)
        await settle()

        XCTAssertEqual(redraws, 1, "a burst of measurements cost the rail a redraw apiece")
        XCTAssertEqual(
            model.geometry.documentHeight, 500,
            "the rail settled on a measurement the roll had already left behind")
    }

    /// The ordinary teardown, with nothing replacing the roll: the
    /// ledger opening over it, or the mode going off. The rail is left
    /// with nothing to draw, which is the honest reading of a card with
    /// no roll on it.
    func testTheLastRollLeavesTheRailWithNothingToDraw() async {
        let model = RollGeometryModel()
        let roll = Roll()
        model.claim(by: roll)
        model.publish(measured(300), from: roll)
        await settle()

        model.reset(from: roll)
        await settle()
        XCTAssertEqual(model.geometry, .unmeasured, "a roll that went away kept its shape")
    }
}
