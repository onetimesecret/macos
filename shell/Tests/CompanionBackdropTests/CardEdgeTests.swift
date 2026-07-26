import Foundation
import XCTest

@testable import CompanionBackdrop

/// Resizing the card from any of its eight grips, tested as the pure
/// decision it is. The clamp has the last word elsewhere; what is
/// asserted here is only what each pull asks for.
final class CardEdgeTests: XCTestCase {
    private let card = BackdropGeometry(
        origin: CGPoint(x: 100, y: 100),
        width: 600,
        height: 400
    )

    // MARK: The edges that only change a measure

    func testPullingTheTrailingEdgeWidensWithoutMovingTheCard() {
        let resized = CardEdge.trailing.resized(card, by: CGSize(width: 120, height: 0))
        XCTAssertEqual(resized.origin, card.origin)
        XCTAssertEqual(resized.width, 720)
        XCTAssertEqual(resized.height, card.height)
    }

    func testPullingTheBottomEdgeDeepensWithoutMovingTheCard() {
        let resized = CardEdge.bottom.resized(card, by: CGSize(width: 0, height: 90))
        XCTAssertEqual(resized.origin, card.origin)
        XCTAssertEqual(resized.height, 490)
        XCTAssertEqual(resized.width, card.width)
    }

    // MARK: The edges that move the origin as well

    func testPullingTheLeadingEdgeMovesTheOriginAndKeepsTheOppositeEdgeStill() {
        let resized = CardEdge.leading.resized(card, by: CGSize(width: 50, height: 0))
        XCTAssertEqual(resized.origin.x, 150)
        XCTAssertEqual(resized.width, 550)
        // The trailing edge is where it was: 100 + 600 == 150 + 550.
        XCTAssertEqual(resized.origin.x + resized.width, card.origin.x + card.width)
    }

    func testPullingTheTopEdgeMovesTheOriginAndKeepsTheBottomStill() {
        let resized = CardEdge.top.resized(card, by: CGSize(width: 0, height: 40))
        XCTAssertEqual(resized.origin.y, 140)
        XCTAssertEqual(resized.height, 360)
        XCTAssertEqual(resized.origin.y + resized.height, card.origin.y + card.height)
    }

    // MARK: Corners pull in both axes at once

    func testACornerResizesBothAxes() {
        let resized = CardEdge.bottomTrailing.resized(
            card, by: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(resized.origin, card.origin)
        XCTAssertEqual(resized.width, 700)
        XCTAssertEqual(resized.height, 500)
    }

    func testTheOppositeCornerMovesTheOriginInBothAxes() {
        let resized = CardEdge.topLeading.resized(card, by: CGSize(width: 30, height: 30))
        XCTAssertEqual(resized.origin, CGPoint(x: 130, y: 130))
        XCTAssertEqual(resized.width, 570)
        XCTAssertEqual(resized.height, 370)
    }

    // MARK: The minimums, which the origin-moving grips must respect

    func testPullingTrailingPastTheFloorStopsAtTheFloor() {
        let resized = CardEdge.trailing.resized(card, by: CGSize(width: -5000, height: 0))
        XCTAssertEqual(resized.width, BackdropGeometry.minWidth)
        XCTAssertEqual(resized.origin, card.origin)
    }

    /// The cap that keeps a shrinking card from sliding away from the
    /// pointer: once the leading edge has taken the card to its minimum
    /// width, further pull moves neither the origin nor the measure.
    func testPullingLeadingPastTheFloorPinsTheOriginToo() {
        let resized = CardEdge.leading.resized(card, by: CGSize(width: 5000, height: 0))
        XCTAssertEqual(resized.width, BackdropGeometry.minWidth)
        XCTAssertEqual(resized.origin.x, card.origin.x + (card.width - BackdropGeometry.minWidth))
        // The trailing edge still has not moved.
        XCTAssertEqual(resized.origin.x + resized.width, card.origin.x + card.width)
    }

    func testPullingTopPastTheFloorPinsTheOriginToo() {
        let resized = CardEdge.top.resized(card, by: CGSize(width: 0, height: 5000))
        XCTAssertEqual(resized.height, BackdropGeometry.minHeight)
        XCTAssertEqual(
            resized.origin.y, card.origin.y + (card.height - BackdropGeometry.minHeight)
        )
        XCTAssertEqual(resized.origin.y + resized.height, card.origin.y + card.height)
    }

    // MARK: Every grip leaves a legal card

    func testNoGripCanProduceACardBelowItsMinimums() {
        for edge in CardEdge.allCases {
            for pull in [-4000.0, -400.0, 0.0, 400.0, 4000.0] {
                let resized = edge.resized(
                    card, by: CGSize(width: pull, height: pull)
                )
                XCTAssertGreaterThanOrEqual(
                    resized.width, BackdropGeometry.minWidth, "\(edge) at \(pull)"
                )
                XCTAssertGreaterThanOrEqual(
                    resized.height, BackdropGeometry.minHeight, "\(edge) at \(pull)"
                )
            }
        }
    }
}
