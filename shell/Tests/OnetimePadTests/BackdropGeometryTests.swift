import Foundation
import XCTest

@testable import OnetimePad

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
        XCTAssertEqual(geometry.height, 316)
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
        XCTAssertEqual(clamped.origin.y, roomyPane.height - clamped.height)
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
            height: 700
        )
        let pane = CGSize(width: 800, height: 500)
        let clamped = geometry.clamped(to: pane)
        XCTAssertEqual(clamped.width, 800)
        XCTAssertEqual(clamped.height, 500)
        XCTAssertEqual(clamped.origin, .zero)
    }

    // MARK: An inset pane — the menu bar and Dock own their strips

    /// The screen with a 25 pt menu bar and an 80 pt Dock carved off,
    /// in the pane's top-leading coordinates.
    private let insetPane = CGRect(x: 0, y: 25, width: 1920, height: 975)

    func testACardCannotBeParkedUnderTheMenuBar() {
        // The defect that motivated the rect: a zoomed card whose
        // header sat under the menu bar could never be double-clicked
        // back down.
        var geometry = BackdropGeometry.default
        geometry.origin = CGPoint(x: 48, y: 0)
        XCTAssertEqual(geometry.clamped(to: insetPane).origin.y, insetPane.minY)
    }

    func testACardCannotHangIntoTheDockStrip() {
        var geometry = BackdropGeometry.default
        geometry.origin = CGPoint(x: 48, y: 5000)
        let clamped = geometry.clamped(to: insetPane)
        XCTAssertEqual(clamped.origin.y, insetPane.maxY - clamped.height)
    }

    func testAFullHeightCardFillsExactlyTheInsetPane() {
        var geometry = BackdropGeometry.default
        geometry.origin.y = insetPane.minY
        geometry.height = insetPane.height
        let clamped = geometry.clamped(to: insetPane)
        XCTAssertEqual(clamped.origin.y, insetPane.minY)
        XCTAssertEqual(clamped.height, insetPane.height)
    }

    func testTheSizeClampIsTheRectClampAtZero() {
        var geometry = BackdropGeometry.default
        geometry.origin = CGPoint(x: 5000, y: -50)
        XCTAssertEqual(
            geometry.clamped(to: roomyPane),
            geometry.clamped(to: CGRect(origin: .zero, size: roomyPane))
        )
    }

    // MARK: The absolute bounds

    func testWidthIsHeldAboveItsFloorOnARoomyPane() {
        var geometry = BackdropGeometry.default
        geometry.width = 100
        XCTAssertEqual(geometry.clamped(to: roomyPane).width, BackdropGeometry.minWidth)
    }

    func testHeightIsHeldAboveItsFloorOnARoomyPane() {
        var geometry = BackdropGeometry.default
        geometry.height = 10
        XCTAssertEqual(geometry.clamped(to: roomyPane).height, BackdropGeometry.minHeight)
    }

    /// Sized like a window: the pane is the only ceiling, so a card
    /// dragged out to fill a large display keeps every point of it.
    /// (The card once carried 900 × 600 ceilings, from when it held one
    /// page of ink and a reading measure was the whole argument.)
    func testTheOnlyCeilingIsThePane() {
        var geometry = BackdropGeometry.default
        geometry.origin = .zero
        geometry.width = 5000
        geometry.height = 5000
        let clamped = geometry.clamped(to: roomyPane)
        XCTAssertEqual(clamped.width, roomyPane.width)
        XCTAssertEqual(clamped.height, roomyPane.height)
    }

    // MARK: Degenerate panes collapse gracefully, never through a crash

    func testAZeroPaneCollapsesEverythingToZero() {
        let clamped = BackdropGeometry.default.clamped(to: CGSize.zero)
        XCTAssertEqual(clamped.origin, .zero)
        XCTAssertEqual(clamped.width, 0)
        XCTAssertEqual(clamped.height, 0)
    }

    func testATinyPaneKeepsTheCardWithinItAndAboveZero() {
        let pane = CGSize(width: 10, height: 10)
        let clamped = BackdropGeometry.default.clamped(to: pane)
        XCTAssertEqual(clamped.origin, .zero)
        XCTAssertGreaterThanOrEqual(clamped.width, 0)
        XCTAssertLessThanOrEqual(clamped.width, pane.width)
        XCTAssertGreaterThanOrEqual(clamped.height, 0)
        XCTAssertLessThanOrEqual(clamped.height, pane.height)
    }

    func testANegativePaneIsTreatedAsEmptyNotACrash() {
        let clamped = BackdropGeometry.default.clamped(
            to: CGSize(width: -100, height: -100)
        )
        XCTAssertEqual(clamped.origin, .zero)
        XCTAssertEqual(clamped.width, 0)
        XCTAssertEqual(clamped.height, 0)
    }

    // MARK: The wire and the defaults

    func testGeometrySurvivesAJSONRoundTrip() throws {
        let geometry = BackdropGeometry(
            origin: CGPoint(x: 123.5, y: 67),
            width: 480,
            height: 340
        )
        let data = try JSONEncoder().encode(geometry)
        let decoded = try JSONDecoder().decode(BackdropGeometry.self, from: data)
        XCTAssertEqual(decoded, geometry)
    }

    /// A card placed before the geometry carried a real height still
    /// opens where it was left: the old editor floor plus the chrome
    /// that sat around it is the height it was drawing.
    func testAGeometryWrittenWithAnEditorFloorStillDecodes() throws {
        // Encoded through a stand-in for the old shape rather than a
        // hand-written blob, so the fixture cannot drift from how
        // CGPoint actually writes itself.
        struct LegacyGeometry: Encodable {
            var origin: CGPoint
            var width: CGFloat
            var minEditorHeight: CGFloat
        }
        let legacy = try JSONEncoder().encode(
            LegacyGeometry(origin: CGPoint(x: 12, y: 34), width: 500, minEditorHeight: 220)
        )
        let decoded = try JSONDecoder().decode(BackdropGeometry.self, from: legacy)
        XCTAssertEqual(decoded.origin, CGPoint(x: 12, y: 34))
        XCTAssertEqual(decoded.width, 500)
        XCTAssertEqual(decoded.height, 316)
    }

    func testGeometrySurvivesADefaultsRoundTripInAThrowawaySuite() throws {
        // A throwaway domain, wiped on the way out: tests never touch
        // the app's real domain.
        let suiteName = "com.onetimesecret.pad.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(BackdropGeometry.load(from: defaults), .default)

        let geometry = BackdropGeometry(
            origin: CGPoint(x: 12, y: 34),
            width: 500,
            height: 300
        )
        geometry.save(to: defaults)
        XCTAssertEqual(BackdropGeometry.load(from: defaults), geometry)
    }

    func testAnUnreadableStoredBlobFallsBackToTheDefault() throws {
        let suiteName = "com.onetimesecret.pad.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not geometry".utf8), forKey: BackdropGeometry.defaultsKey)
        XCTAssertEqual(BackdropGeometry.load(from: defaults), .default)
    }
}

/// The header's three columns, tested as the arithmetic they are. The
/// header used to lay the indicator cluster over a centred identity,
/// which held only while the identity stayed under its cap; a file
/// identity asks for whatever its own words need, and on a narrow card
/// the two drew on the same points. What is asserted here is that the
/// cluster's ground is reserved, at every width.
///
/// This is the width the header actually gives its middle column: the
/// view measures its own ground and hands `identityWidth` the answer,
/// so these cases stand behind the drawing rather than beside it. Where
/// the column then sits is the HStack's own centring and is not
/// asserted here.
final class HeaderLayoutTests: XCTestCase {
    /// The cluster at its wordiest: a capture warning, a save word, a
    /// sync word and the pin toggle.
    private let indicators: CGFloat = 150

    func testTheIdentityNeverReachesTheIndicatorCluster() {
        for cardWidth in stride(from: CGFloat(120), through: 1600, by: 20) {
            let width = HeaderLayout.identityWidth(
                cardWidth: cardWidth, indicatorWidth: indicators
            )
            // A starved identity draws nothing and so can overlap
            // nothing; the width assertion below is what covers it.
            guard width > 0 else { continue }
            // Both clusters keep their ground and both gutters survive,
            // whatever the identity had to say.
            XCTAssertLessThanOrEqual(
                width, cardWidth - 2 * (indicators + HeaderLayout.gutter),
                "identity underlaps the cluster at card width \(cardWidth)"
            )
        }
    }

    func testANarrowCardStarvesTheIdentityRatherThanOverlapping() {
        // Narrower than the cluster and its mirror together: the
        // identity gets nothing, which is the right thing to lose.
        let width = HeaderLayout.identityWidth(cardWidth: 200, indicatorWidth: indicators)
        XCTAssertEqual(width, 0)
        // And it starves the whole way down, rather than turning
        // negative and reading as room the cluster could borrow.
        for cardWidth in stride(from: CGFloat(0), through: 316, by: 4) {
            XCTAssertGreaterThanOrEqual(
                HeaderLayout.identityWidth(cardWidth: cardWidth, indicatorWidth: indicators), 0
            )
        }
    }

    func testAWideCardStopsAtTheCapRatherThanRunningOn() {
        let width = HeaderLayout.identityWidth(cardWidth: 1600, indicatorWidth: indicators)
        XCTAssertEqual(width, HeaderLayout.identityCap)
    }
}
