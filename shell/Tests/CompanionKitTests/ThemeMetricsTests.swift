import AppKit
import XCTest

@testable import CompanionKit

/// The one number the theme takes from the platform rather than from
/// the design record: the mini control size the seat words, the note
/// hints and the rail's small labels are set in (issue #297).
final class ThemeMetricsTests: XCTestCase {
    /// The size was a literal 9 in thirteen places before it was the
    /// system's; this fails the day the platform moves it.
    func testTheMiniControlSizeIsStillNinePoints() {
        XCTAssertEqual(NSFont.miniSystemFontSize, 9)
        XCTAssertEqual(NSFont.miniSystemFontSize, NSFont.systemFontSize(for: .mini))
    }
}
