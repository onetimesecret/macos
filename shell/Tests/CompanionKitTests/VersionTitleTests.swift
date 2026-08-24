import XCTest

@testable import CompanionKit

/// The tray menu's version line (App.swift). Two shapes: a bare
/// `swift run` has no bundle version and the core speaks alone, and a
/// bundled build names both the stamped bundle version and the core it
/// linked. Since issue #89 the app's marketing version and the core's
/// crate version have separate sources, so the two numbers differing is
/// the ordinary case and the line no longer treats it as a warning
/// worth special phrasing.
final class VersionTitleTests: XCTestCase {
    func testUnbundledRunSpeaksForTheCore() {
        XCTAssertEqual(
            BuildVersion.trayTitle(core: "0.1.0", bundleVersion: nil),
            "core 0.1.0")
    }

    func testStampedBundleShowsTheBuild() {
        XCTAssertEqual(
            BuildVersion.trayTitle(core: "0.1.0", bundleVersion: "0.1.0+ab12cd3"),
            "build 0.1.0+ab12cd3, core 0.1.0")
    }

    func testPlainBundleShowsTheBuild() {
        // No git available at build time: the stamp is just the version.
        // Matching the core is now a coincidence rather than a claim, so
        // the core is still named.
        XCTAssertEqual(
            BuildVersion.trayTitle(core: "0.1.0", bundleVersion: "0.1.0"),
            "build 0.1.0, core 0.1.0")
    }

    func testDriftNamesBothSides() {
        // The everyday case now: the app moved for work a user can see
        // and the seam did not move with it.
        XCTAssertEqual(
            BuildVersion.trayTitle(core: "0.1.0", bundleVersion: "0.13.0+ab12cd3"),
            "build 0.13.0+ab12cd3, core 0.1.0")
    }
}
