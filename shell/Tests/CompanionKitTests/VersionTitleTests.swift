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

    // MARK: Which lane the build came from

    func testTheDevLaneSaysSoInTheLine() {
        // Two copies of the app run side by side all day. Which one
        // this menu belongs to is the question the line is opened to
        // answer, so it is the one thing it must not leave out.
        XCTAssertEqual(
            BuildVersion.trayTitle(
                core: "0.1.0", bundleVersion: "0.13.0+ab12cd3", devLane: true),
            "build 0.13.0+ab12cd3, core 0.1.0, dev")
    }

    func testTheReleaseLineIsUnchanged() {
        XCTAssertEqual(
            BuildVersion.trayTitle(
                core: "0.1.0", bundleVersion: "0.13.0", devLane: false),
            BuildVersion.trayTitle(core: "0.1.0", bundleVersion: "0.13.0"))
    }

    func testTheLaneIsReadOffTheBundleIdentifier() {
        // The one identifier package-app.sh --debug writes, by name and
        // nothing else: the installed copy must never be mistaken for a
        // dev build, and neither may the retired legacy dev id or a
        // .debug suffix on the shipping id, both of which the old
        // suffix check would have waved through.
        XCTAssertEqual(FormFactor.devBundleIdentifier, "dev.onetimesecret.pad")
        XCTAssertTrue(BuildVersion.isDevLane(bundleIdentifier: FormFactor.devBundleIdentifier))
        XCTAssertFalse(
            BuildVersion.isDevLane(bundleIdentifier: FormFactor.backdropBundleIdentifier))
        XCTAssertFalse(
            BuildVersion.isDevLane(bundleIdentifier: "com.onetimesecret.companion.backdrop.debug"))
        XCTAssertFalse(BuildVersion.isDevLane(bundleIdentifier: "com.onetimesecret.pad.debug"))
        // A bare `swift run` has no bundle at all, which is not the dev
        // lane in this sense: it has no packaged identity to contradict.
        XCTAssertFalse(BuildVersion.isDevLane(bundleIdentifier: nil))
    }
}
