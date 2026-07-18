import Foundation
import XCTest

@testable import CompanionBackdrop

/// The card's placement, tested as the pure decision it is, in the
/// shell's pattern for UI-adjacent logic: interrogate `clamped(to:)`
/// directly, never mock AppKit. The gesture plumbing that proposes
/// geometries and the window that fits the pane are hand-tested per
/// the project's rules.
final class BackdropGeometryTests: XCTestCase {
    /// A pane comfortably larger than any card, so only the absolute
    /// bounds bite.
    private let roomyPane = CGSize(width: 1920, height: 1080)

    // MARK: The default is today's layout, verbatim

    func testDefaultMatchesTheLayoutTheCardShippedWith() {
        let geometry = BackdropGeometry.default
        XCTAssertEqual(geometry.origin, CGPoint(x: 48, y: 48))
        XCTAssertEqual(geometry.width, 640)
        XCTAssertEqual(geometry.minEditorHeight, 220)
    }

    func testDefaultSurvivesItsOwnClampOnARoomyPane() {
        // The shipped layout must already be legal; a default that the
        // clamp rewrites would mean the two disagree about the rules.
        XCTAssertEqual(BackdropGeometry.default.clamped(to: roomyPane), .default)
    }

    // MARK: The clamp keeps the card on the pane

    func testAnOffscreenOriginIsPulledBackWithinReach() {
        var geometry = BackdropGeometry.default
        geometry.origin = CGPoint(x: 5000, y: 5000)
        let clamped = geometry.clamped(to: roomyPane)
        XCTAssertEqual(clamped.origin.x, roomyPane.width - clamped.width)
        XCTAssertEqual(
            clamped.origin.y,
            roomyPane.height - (clamped.minEditorHeight + BackdropGeometry.cardChromeHeight)
        )
    }

    func testANegativeOriginPinsToTheTopLeadingCorner() {
        var geometry = BackdropGeometry.default
        geometry.origin = CGPoint(x: -10, y: -300)
        XCTAssertEqual(geometry.clamped(to: roomyPane).origin, .zero)
    }

    func testAShrinkingPaneReclampsBothOriginAndSize() {
        // The display-disconnect case: a card sized and parked for a
        // large screen must fold itself onto a smaller one.
        let geometry = BackdropGeometry(
            origin: CGPoint(x: 400, y: 300),
            width: 900,
            minEditorHeight: 600
        )
        let pane = CGSize(width: 800, height: 500)
        let clamped = geometry.clamped(to: pane)
        XCTAssertEqual(clamped.width, 800)
        XCTAssertEqual(
            clamped.minEditorHeight,
            pane.height - BackdropGeometry.cardChromeHeight
        )
        XCTAssertEqual(clamped.origin, .zero)
    }

    // MARK: The absolute bounds

    func testWidthIsHeldWithinItsBoundsOnARoomyPane() {
        var geometry = BackdropGeometry.default
        geometry.width = 100
        XCTAssertEqual(geometry.clamped(to: roomyPane).width, BackdropGeometry.minWidth)
        geometry.width = 5000
        XCTAssertEqual(geometry.clamped(to: roomyPane).width, BackdropGeometry.maxWidth)
    }

    func testEditorHeightIsHeldWithinItsBoundsOnARoomyPane() {
        var geometry = BackdropGeometry.default
        geometry.minEditorHeight = 10
        XCTAssertEqual(
            geometry.clamped(to: roomyPane).minEditorHeight,
            BackdropGeometry.minReadableEditorHeight
        )
        geometry.minEditorHeight = 5000
        XCTAssertEqual(
            geometry.clamped(to: roomyPane).minEditorHeight,
            BackdropGeometry.maxEditorHeight
        )
    }

    // MARK: Degenerate panes collapse gracefully, never through a crash

    func testAZeroPaneCollapsesEverythingToZero() {
        let clamped = BackdropGeometry.default.clamped(to: .zero)
        XCTAssertEqual(clamped.origin, .zero)
        XCTAssertEqual(clamped.width, 0)
        XCTAssertEqual(clamped.minEditorHeight, 0)
    }

    func testATinyPaneKeepsTheCardWithinItAndAboveZero() {
        let pane = CGSize(width: 10, height: 10)
        let clamped = BackdropGeometry.default.clamped(to: pane)
        XCTAssertEqual(clamped.origin, .zero)
        XCTAssertGreaterThanOrEqual(clamped.width, 0)
        XCTAssertLessThanOrEqual(clamped.width, pane.width)
        XCTAssertGreaterThanOrEqual(clamped.minEditorHeight, 0)
    }

    func testANegativePaneIsTreatedAsEmptyNotACrash() {
        let clamped = BackdropGeometry.default.clamped(
            to: CGSize(width: -100, height: -100)
        )
        XCTAssertEqual(clamped.origin, .zero)
        XCTAssertEqual(clamped.width, 0)
        XCTAssertEqual(clamped.minEditorHeight, 0)
    }

    // MARK: The wire and the suite

    func testGeometrySurvivesAJSONRoundTrip() throws {
        let geometry = BackdropGeometry(
            origin: CGPoint(x: 123.5, y: 67),
            width: 480,
            minEditorHeight: 240
        )
        let data = try JSONEncoder().encode(geometry)
        let decoded = try JSONDecoder().decode(BackdropGeometry.self, from: data)
        XCTAssertEqual(decoded, geometry)
    }

    func testGeometrySurvivesADefaultsRoundTripInAThrowawaySuite() throws {
        // A throwaway domain, wiped on the way out: tests never touch
        // the backdrop's real suite, let alone CompanionApp's.
        let suiteName = "com.onetimesecret.companion.backdrop.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(BackdropGeometry.load(from: defaults), .default)

        let geometry = BackdropGeometry(
            origin: CGPoint(x: 12, y: 34),
            width: 500,
            minEditorHeight: 300
        )
        geometry.save(to: defaults)
        XCTAssertEqual(BackdropGeometry.load(from: defaults), geometry)
    }

    func testAnUnreadableStoredBlobFallsBackToTheDefault() throws {
        let suiteName = "com.onetimesecret.companion.backdrop.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not geometry".utf8), forKey: BackdropGeometry.defaultsKey)
        XCTAssertEqual(BackdropGeometry.load(from: defaults), .default)
    }
}
