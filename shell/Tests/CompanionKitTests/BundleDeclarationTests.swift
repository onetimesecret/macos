import Foundation
import XCTest

@testable import CompanionKit

/// The declaration the sudden-termination latch is a gate on
/// (ADR-0016 section 2, ADR-0012). `NSSupportsSuddenTermination` is
/// what makes this app killable outright at logout or shutdown, and
/// `PageModel`'s `SuddenTerminationLatch` is the only thing that then
/// holds the kill off while a write is pending. Drop the key and every
/// latch test still passes over a guarantee that has quietly become the
/// accident of never having opted in; keep the key without the latch
/// and a logout takes the pad. Both halves are load bearing, and only
/// one of them was pinned.
///
/// This reads the plist in the source tree, which is the file
/// `scripts/package-app.sh` copies into the bundle, and not the bundle
/// itself: SwiftPM never builds the .app, so `Bundle.main` under xctest
/// is the test runner and carries none of these keys. Pinning what the
/// packaging script actually produced belongs to CI, in a later layer
/// of this effort.
final class BundleDeclarationTests: XCTestCase {
    /// The shell package's own directory, from this file's location:
    /// Tests/CompanionKitTests/<this file> is three levels down.
    private static var shellDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testTheShippedPlistDeclaresSuddenTermination() throws {
        let plist = Self.shellDirectory.appendingPathComponent("OnetimePad-Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        let keys = try XCTUnwrap(parsed as? [String: Any])

        XCTAssertEqual(
            keys["NSSupportsSuddenTermination"] as? Bool, true,
            "the app opts out of sudden termination, so the latch guards a kill that cannot happen"
        )
        // The identity the state directory, the Keychain service and
        // every TCC grant are keyed off: ids are infrastructure
        // (ADR-0014), so the plist agreeing with the code is what keeps
        // a shipped build reading the store it wrote yesterday.
        XCTAssertEqual(
            keys["CFBundleIdentifier"] as? String, FormFactor.backdropBundleIdentifier)
    }

    /// One bundle, one identity sheet. The panel target was archived
    /// (shell/Package.swift), and a second identity sheet reappearing
    /// beside this one would mean a second app shipping under whatever
    /// keys it happened to carry, this test's subject included. So the
    /// count is asserted rather than the file merely being found.
    func testTheShellShipsExactlyOneIdentitySheet() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: Self.shellDirectory, includingPropertiesForKeys: nil)
        let plists = contents.filter { $0.lastPathComponent.hasSuffix("Info.plist") }
        XCTAssertEqual(
            plists.map(\.lastPathComponent).sorted(), ["OnetimePad-Info.plist"],
            "a second bundle identity appeared beside the one this suite pins"
        )
    }
}
