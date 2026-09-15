import XCTest

@testable import CompanionKit

/// What the About panel is handed (`showAbout` in BackdropApp.swift): the
/// app/build pair in AppKit's standard fields and accurately labelled Rust
/// component versions in the technical-details block.
final class AboutVersionTests: XCTestCase {
    func testBundledAppLeadsWithItsOwnVersion() {
        let fields = AboutVersion.fields(
            ffiVersion: "0.27.0",
            coreVersion: "0.21.0",
            shortVersion: "0.21.0",
            bundleVersion: "0.21.0+ab12cd3"
        )
        XCTAssertEqual(fields.applicationVersion, "0.21.0")
        XCTAssertEqual(fields.build, "0.21.0+ab12cd3")
        XCTAssertEqual(fields.technicalVersions, "FFI 0.27.0\nCore 0.21.0")
    }

    func testTheAppVersionIsIndependentOfBothRustVersions() {
        let fields = AboutVersion.fields(
            ffiVersion: "0.27.0",
            coreVersion: "0.21.0",
            shortVersion: "0.22.0",
            bundleVersion: "0.22.0+ab12cd3"
        )
        XCTAssertEqual(fields.applicationVersion, "0.22.0")
        XCTAssertEqual(fields.build, "0.22.0+ab12cd3")
        XCTAssertEqual(fields.technicalVersions, "FFI 0.27.0\nCore 0.21.0")
    }

    func testUnbundledRunFallsBackToTheFFIVersion() {
        let fields = AboutVersion.fields(
            ffiVersion: "0.27.0",
            coreVersion: "0.21.0",
            shortVersion: nil,
            bundleVersion: nil
        )
        XCTAssertEqual(fields.applicationVersion, "0.27.0")
        XCTAssertNil(fields.build)
        XCTAssertEqual(fields.technicalVersions, "FFI 0.27.0\nCore 0.21.0")
    }

    func testMissingBuildCostsOnlyTheParentheses() {
        // Not a shape the build scripts produce, but the keys are read
        // rather than guaranteed, so the panel still gets a version.
        let fields = AboutVersion.fields(
            ffiVersion: "0.27.0",
            coreVersion: "0.21.0",
            shortVersion: "0.21.0",
            bundleVersion: nil
        )
        XCTAssertEqual(fields.applicationVersion, "0.21.0")
        XCTAssertNil(fields.build)
    }
}
