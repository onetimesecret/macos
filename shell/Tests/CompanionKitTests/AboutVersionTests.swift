import XCTest

@testable import CompanionKit

/// What the About panel is handed (`showAbout` in BackdropApp.swift).
/// Since issue #89 the panel leads with the app's own marketing version
/// rather than the core's, so the resolution has three cases worth
/// pinning: a packaged app, a bare `swift run` with no Info.plist to
/// read, and a bundle missing the stamped build.
final class AboutVersionTests: XCTestCase {
    func testBundledAppLeadsWithItsOwnVersion() {
        let fields = AboutVersion.fields(
            core: "0.13.0", shortVersion: "0.13.0", bundleVersion: "0.13.0+ab12cd3")
        XCTAssertEqual(fields.applicationVersion, "0.13.0")
        XCTAssertEqual(fields.build, "0.13.0+ab12cd3")
    }

    func testTheAppVersionIsNotTheCoreVersion() {
        // The everyday case the split exists for: user visible work
        // moved the product's number and the seam stayed where it was.
        let fields = AboutVersion.fields(
            core: "0.11.0", shortVersion: "0.13.0", bundleVersion: "0.13.0+ab12cd3")
        XCTAssertEqual(fields.applicationVersion, "0.13.0")
        XCTAssertEqual(fields.build, "0.13.0+ab12cd3")
    }

    func testUnbundledRunFallsBackToTheCore() {
        let fields = AboutVersion.fields(
            core: "0.13.0", shortVersion: nil, bundleVersion: nil)
        XCTAssertEqual(fields.applicationVersion, "0.13.0")
        XCTAssertNil(fields.build)
    }

    func testMissingBuildCostsOnlyTheParentheses() {
        // Not a shape the build scripts produce, but the keys are read
        // rather than guaranteed, so the panel still gets a version.
        let fields = AboutVersion.fields(
            core: "0.13.0", shortVersion: "0.13.0", bundleVersion: nil)
        XCTAssertEqual(fields.applicationVersion, "0.13.0")
        XCTAssertNil(fields.build)
    }
}
