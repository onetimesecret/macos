import AppKit
import XCTest

@testable import CompanionKit

/// The status item falls back to the maruhi when the mark cannot be
/// read, which is the right behaviour at runtime and a silent wrong
/// icon everywhere else. These are what actually hold the shipped asset
/// to its shape, so the fallback stays theoretical.
@MainActor
final class LogoMarkTests: XCTestCase {
    func testTheShippedAssetParses() throws {
        let art = try XCTUnwrap(LogoMark.mark, "the logo asset is missing or unparseable")
        XCTAssertFalse(art.path.isEmpty)
        // The mark is the subject alone: the full bleed plate is
        // dropped, so what is left is smaller than the 1445 unit square
        // the artboard is, and squarish rather than a sliver.
        XCTAssertLessThan(art.bounds.width, 1445 * 0.99)
        XCTAssertGreaterThan(art.bounds.width, 0)
        XCTAssertGreaterThan(art.bounds.height, 0)
        XCTAssertEqual(art.bounds.width / art.bounds.height, 1, accuracy: 0.6)
    }

    func testTemplateImageIsTintableAndSquare() throws {
        let image = try XCTUnwrap(LogoMark.templateImage(side: 18))
        XCTAssertTrue(image.isTemplate, "a non-template image ignores the menu bar's appearance")
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    /// The fit centres the art and keeps it inside the inset box, which
    /// is what leaves a status item its optical margin.
    func testFitStaysInsideTheInsetBox() throws {
        let art = try XCTUnwrap(LogoMark.mark)
        let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
        let box = LogoMark.fitted(art, into: rect, fraction: 0.5).bounds
        XCTAssertLessThanOrEqual(max(box.width, box.height), 9.001)
        XCTAssertEqual(box.midX, rect.midX, accuracy: 0.001)
        XCTAssertEqual(box.midY, rect.midY, accuracy: 0.001)
    }

    /// An unsupported command draws a wrong mark if it is skipped, so
    /// the parser gives up on one instead.
    func testUnsupportedCommandIsRefused() {
        XCTAssertNil(LogoMark.parse(d: "M0 0 A 10 10 0 0 1 20 20 Z"))
        XCTAssertNil(LogoMark.parse(d: "10 10 L 20 20"))
        XCTAssertNil(LogoMark.parse(d: "M0 0 L 20"))
    }

    func testPlateOnlyArtworkYieldsNoMark() {
        let plate = """
        <svg width="100" height="100">
        <path d="M0 0 L100 0 L100 100 L0 100 Z" fill="#DC4A22"/>
        </svg>
        """
        XCTAssertNil(LogoMark.parse(svg: plate))
    }
}
