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
/// packaging script actually produced belongs to CI, which now extracts
/// the key from the assembled `dist/OnetimePad.app/Contents/Info.plist`
/// in both the debug and the release packaging jobs
/// (`.github/workflows/ci.yml`). The two are complements, not copies:
/// this test catches the key leaving the source tree, and CI catches
/// the bundle losing it on the way in.
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
        XCTAssertEqual(
            keys["ITSAppUsesNonExemptEncryption"] as? Bool, true,
            "ring and rustls provide cryptography outside Apple's operating system"
        )
    }

    func testDistributionEntitlementsDeclareSandboxAndOutgoingNetworkAccess() throws {
        let entitlements = Self.shellDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/Companion.entitlements")
        let data = try Data(contentsOf: entitlements)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        let keys = try XCTUnwrap(parsed as? [String: Any])

        XCTAssertEqual(keys["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(keys["com.apple.security.network.client"] as? Bool, true)
    }

    /// The dev lane's identity is written by the packaging script and
    /// recognised by the shell, two files with no compile time tie
    /// between them. The script writes the id outright rather than
    /// deriving it from the release one, so a drift here would not be
    /// a suffix gone missing: it would be a dev build the tray calls a
    /// release build, and one `resolvedBundleIdentifier` does not know,
    /// so it takes the fallback and lands on the installed copy's
    /// state directory and Keychain service. The script is read and
    /// the one assignment looked for.
    func testThePackagingScriptWritesTheDevIdentifierTheShellRecognises() throws {
        let script = Self.shellDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/package-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(
            text.contains("DEV_BUNDLE_ID=\"\(FormFactor.devBundleIdentifier)\""),
            "scripts/package-app.sh does not assign DEV_BUNDLE_ID the id FormFactor names as the dev lane"
        )
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

    /// ⌘N belongs to the pad because nothing in AppKit is holding it
    /// (issue #77).
    ///
    /// The stock New item is a document-based app's, and this app has
    /// no document model: no declared document types here, and no
    /// window or document scene in `BackdropApp`, whose only scene is
    /// the Settings placeholder. Declaring a document type would hand
    /// AppKit a File menu with its own ⌘N in it, and a main-menu key
    /// equivalent wins over the surface's hidden buttons, so the chord
    /// the keymap installs would quietly stop reaching the pad. That is
    /// a subtle enough failure to be worth a test that names it.
    func testTheBundleClaimsNoDocumentTypesSoTheNewChordIsTheKeymaps() throws {
        let plist = Self.shellDirectory.appendingPathComponent("OnetimePad-Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        let keys = try XCTUnwrap(parsed as? [String: Any])

        XCTAssertNil(
            keys["CFBundleDocumentTypes"],
            "a declared document type gives AppKit its own ⌘N, which would shadow page::New")
    }
}
