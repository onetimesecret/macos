import XCTest

@testable import CompanionKit

/// The optional menu-bar diagnostic line. Every artifact is labelled by
/// what it versions; a bare `swift run` simply has no app build to name.
final class VersionTitleTests: XCTestCase {
    func testUnbundledRunNamesBothRustCrates() {
        XCTAssertEqual(
            BuildVersion.menuTitle(
                ffiVersion: "0.27.0", coreVersion: "0.21.0", bundleVersion: nil),
            "FFI 0.27.0 · Core 0.21.0")
    }

    func testStampedBundleNamesBuildAndBothRustCrates() {
        XCTAssertEqual(
            BuildVersion.menuTitle(
                ffiVersion: "0.27.0",
                coreVersion: "0.21.0",
                bundleVersion: "0.21.0+ab12cd3"
            ),
            "Build 0.21.0+ab12cd3 · FFI 0.27.0 · Core 0.21.0")
    }

    func testPlainBundleStillLabelsEachArtifact() {
        XCTAssertEqual(
            BuildVersion.menuTitle(
                ffiVersion: "0.27.0", coreVersion: "0.21.0", bundleVersion: "0.21.0"),
            "Build 0.21.0 · FFI 0.27.0 · Core 0.21.0")
    }

    // MARK: Which lane the build came from

    func testTheDevLaneSaysSoInTheLine() {
        // Two copies of the app run side by side all day. Which one
        // this menu belongs to is the question the line is opened to
        // answer, so it is the one thing it must not leave out.
        XCTAssertEqual(
            BuildVersion.menuTitle(
                ffiVersion: "0.27.0",
                coreVersion: "0.21.0",
                bundleVersion: "0.21.0+ab12cd3",
                devLane: true
            ),
            "Build 0.21.0+ab12cd3 · FFI 0.27.0 · Core 0.21.0 · Dev")
    }

    func testTheReleaseLineIsUnchanged() {
        XCTAssertEqual(
            BuildVersion.menuTitle(
                ffiVersion: "0.27.0",
                coreVersion: "0.21.0",
                bundleVersion: "0.21.0",
                devLane: false
            ),
            BuildVersion.menuTitle(
                ffiVersion: "0.27.0",
                coreVersion: "0.21.0",
                bundleVersion: "0.21.0"
            ))
    }

    func testTheLaneIsReadOffTheBundleIdentifier() {
        // The one identifier package-app.sh --debug writes, by name and
        // nothing else: the installed copy must never be mistaken for a
        // dev build, and neither may the retired legacy dev id or a
        // .debug suffix on the shipping id, both of which the old
        // suffix check would have waved through.
        XCTAssertEqual(FormFactor.devBundleIdentifier, "dev.onetimesecret.pad.debug")
        XCTAssertTrue(BuildVersion.isDevLane(bundleIdentifier: FormFactor.devBundleIdentifier))
        XCTAssertFalse(
            BuildVersion.isDevLane(bundleIdentifier: FormFactor.backdropBundleIdentifier))
        // The local install is a development build but not the dev lane:
        // it is the release configuration, installed and dogfooded.
        XCTAssertEqual(FormFactor.localBundleIdentifier, "dev.onetimesecret.pad")
        XCTAssertFalse(
            BuildVersion.isDevLane(bundleIdentifier: FormFactor.localBundleIdentifier))
        XCTAssertFalse(
            BuildVersion.isDevLane(bundleIdentifier: "com.onetimesecret.companion.backdrop.debug"))
        XCTAssertFalse(BuildVersion.isDevLane(bundleIdentifier: "com.onetimesecret.pad.debug"))
        // A bare `swift run` has no bundle at all, which is not the dev
        // lane in this sense: it has no packaged identity to contradict.
        XCTAssertFalse(BuildVersion.isDevLane(bundleIdentifier: nil))
    }
}
