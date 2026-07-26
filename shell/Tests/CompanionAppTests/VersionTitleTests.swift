import XCTest

@testable import CompanionApp

/// The tray menu's version line (App.swift). Three shapes: a bare
/// `swift run` has no bundle version, a stamped bundle extends the
/// core's version with the git SHA, and a bundle that does not extend
/// the core's own version is a stale-xcframework warning, not a
/// cosmetic difference.
final class VersionTitleTests: XCTestCase {
    func testUnbundledRunSpeaksForTheCore() {
        XCTAssertEqual(
            AppDelegate.versionTitle(core: "0.1.0", bundleVersion: nil),
            "core 0.1.0")
    }

    func testStampedBundleShowsTheBuild() {
        XCTAssertEqual(
            AppDelegate.versionTitle(core: "0.1.0", bundleVersion: "0.1.0+ab12cd3"),
            "build 0.1.0+ab12cd3")
    }

    func testPlainBundleShowsTheBuild() {
        // No git available at build time: the stamp is just the version.
        XCTAssertEqual(
            AppDelegate.versionTitle(core: "0.1.0", bundleVersion: "0.1.0"),
            "build 0.1.0")
    }

    func testDriftNamesBothSides() {
        // The bundle was stamped from a newer Cargo.toml than the
        // xcframework the binary actually linked.
        XCTAssertEqual(
            AppDelegate.versionTitle(core: "0.1.0", bundleVersion: "0.2.0+ab12cd3"),
            "build 0.2.0+ab12cd3, core 0.1.0")
    }
}
