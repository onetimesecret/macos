import Foundation
import CoreGraphics
import XCTest

@testable import OnetimePad

final class SideTabPlacementTests: XCTestCase {
    private func display(
        _ id: String = "main", frame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 800),
        visible: CGRect? = nil
    ) -> SideTabDisplay {
        SideTabDisplay(id: id, name: id, frame: frame, visibleFrame: visible ?? frame)
    }

    func testMissingSelectionAndDisconnectedDisplayProduceNoTarget() {
        let screens = [display()]
        XCTAssertNil(SideTabPlacement.frame(displayID: nil, edge: .right, position: 0.5, displays: screens))
        XCTAssertNil(SideTabPlacement.frame(displayID: "removed", edge: .right, position: 0.5, displays: screens))
        XCTAssertNil(SideTabPlacement.frame(displayID: "main", edge: .right, position: 0.5, displays: []))
    }

    func testBothSideTargetsFitTheirVisibleBoundsAtNegativeOrigins() throws {
        let screen = display(frame: CGRect(x: -1400, y: -300, width: 1000, height: 800),
            visible: CGRect(x: -1400, y: -240, width: 1000, height: 716))
        let left = SideTabPlacement.frame(displayID: "main", edge: .left, position: 0.5, displays: [screen])
        let right = SideTabPlacement.frame(displayID: "main", edge: .right, position: 0.5, displays: [screen])
        XCTAssertEqual(left, CGRect(x: -1400, y: 86, width: 16, height: 64))
        XCTAssertEqual(right, CGRect(x: -416, y: 86, width: 16, height: 64))
        XCTAssertTrue(screen.visibleFrame.contains(try XCTUnwrap(left)))
        XCTAssertTrue(screen.visibleFrame.contains(try XCTUnwrap(right)))
    }

    func testPositionRunsFromTopToBottomWithCornerClearanceAndClamping() {
        let screen = display(visible: CGRect(x: 0, y: 60, width: 1000, height: 716))
        for position in [-2.0, 0.0] {
            XCTAssertEqual(SideTabPlacement.frame(displayID: "main", edge: .right,
                position: position, displays: [screen])?.minY, 688)
        }
        for position in [1.0, 2.0] {
            XCTAssertEqual(SideTabPlacement.frame(displayID: "main", edge: .right,
                position: position, displays: [screen])?.minY, 84)
        }
        for position in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(SideTabPlacement.frame(displayID: "main", edge: .right,
                position: position, displays: [screen])?.minY, 386)
        }
    }

    func testDockInsetDisablesOnlyTheOccupiedSide() {
        let leftDock = display(visible: CGRect(x: 60, y: 0, width: 940, height: 776))
        XCTAssertNil(SideTabPlacement.frame(displayID: "main", edge: .left,
            position: 0.5, displays: [leftDock]))
        XCTAssertNotNil(SideTabPlacement.frame(displayID: "main", edge: .right,
            position: 0.5, displays: [leftDock]))
        let rightDock = display(visible: CGRect(x: 0, y: 0, width: 999, height: 776))
        XCTAssertNil(SideTabPlacement.frame(displayID: "main", edge: .right,
            position: 0.5, displays: [rightDock]))
        XCTAssertNotNil(SideTabPlacement.frame(displayID: "main", edge: .left,
            position: 0.5, displays: [rightDock]))
    }

    func testSharedSideIsRejectedWhileTheOutsideSideRemainsAvailable() {
        let screens = [display(), display("adjacent", frame: CGRect(x: 1000, y: 0, width: 1200, height: 900))]
        XCTAssertNil(SideTabPlacement.frame(displayID: "main", edge: .right, position: 0.5, displays: screens))
        XCTAssertNotNil(SideTabPlacement.frame(displayID: "main", edge: .left, position: 0.5, displays: screens))
        XCTAssertNil(SideTabPlacement.frame(displayID: "adjacent", edge: .left, position: 0.5, displays: screens))
        XCTAssertNotNil(SideTabPlacement.frame(displayID: "adjacent", edge: .right, position: 0.5, displays: screens))
    }

    func testPartialSeamChecksTheWholeTabInsteadOfOnlyItsCenter() {
        let main = display()
        let aboveCenter = display("partial", frame: CGRect(x: 1000, y: 420, width: 800, height: 700))
        XCTAssertNil(SideTabPlacement.frame(displayID: "main", edge: .right,
            position: 0.5, displays: [main, aboveCenter]))
        XCTAssertNotNil(SideTabPlacement.frame(displayID: "main", edge: .right,
            position: 1, displays: [main, aboveCenter]))
        let atTopBoundary = display("touching", frame: CGRect(x: 1000, y: 432, width: 800, height: 700))
        XCTAssertNotNil(SideTabPlacement.frame(displayID: "main", edge: .right,
            position: 0.5, displays: [main, atTopBoundary]))
    }

    func testOverlappingDisplayAtTheTargetIsRejected() {
        let overlapping = display("overlap", frame: CGRect(x: 990, y: 300, width: 800, height: 200))
        XCTAssertNil(SideTabPlacement.frame(displayID: "main", edge: .right,
            position: 0.5, displays: [display(), overlapping]))
    }

    func testInsufficientSpaceAndInvalidGeometryProduceNoTarget() {
        let frames = [
            CGRect(x: 0, y: 0, width: 15, height: 800),
            CGRect(x: 0, y: 0, width: 1000, height: 111),
            CGRect(x: 0, y: 0, width: 0, height: 800),
            CGRect(x: 0, y: 0, width: -100, height: 800),
            CGRect(x: 0, y: 0, width: 1000, height: -800),
            CGRect(x: Double.nan, y: 0, width: 1000, height: 800),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                width: CGFloat.greatestFiniteMagnitude, height: 800),
        ]
        for frame in frames {
            XCTAssertNil(SideTabPlacement.frame(displayID: "main", edge: .right,
                position: 0.5, displays: [display(frame: frame)]))
        }
        let outsideVisible = display(visible: CGRect(x: 0, y: 0, width: 1001, height: 800))
        XCTAssertNil(SideTabPlacement.frame(displayID: "main", edge: .right,
            position: 0.5, displays: [outsideVisible]))
        let negativeVisible = display(visible: CGRect(x: 1000, y: 0, width: -1000, height: 800))
        XCTAssertNil(SideTabPlacement.frame(displayID: "main", edge: .right,
            position: 0.5, displays: [negativeVisible]))
    }

    func testExactMinimumHeightUsesOnePositionWithBothClearances() {
        let screen = display(frame: CGRect(x: 0, y: 0, width: 16, height: 112))
        for position in [0.0, 0.5, 1.0] {
            XCTAssertEqual(SideTabPlacement.frame(displayID: "main", edge: .right,
                position: position, displays: [screen]), CGRect(x: 0, y: 24, width: 16, height: 64))
        }
    }

    func testGeometryFollowsSelectedIdentityWithoutChoosingAnotherDisplay() {
        let first = display()
        let selected = display("selected", frame: CGRect(x: -1200, y: 0, width: 1200, height: 800))
        let target = SideTabPlacement.frame(displayID: "selected", edge: .left,
            position: 0.5, displays: [first, selected])
        XCTAssertEqual(target?.minX, -1200)
        XCTAssertNil(SideTabPlacement.frame(displayID: "selected", edge: .left,
            position: 0.5, displays: [first]))
    }
}
