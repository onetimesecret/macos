import Foundation
import XCTest

@testable import CompanionKit

/// The declaration the sudden-termination latch is a gate on
/// (persistence decision background section 2, ADR-0012).
/// `NSSupportsSuddenTermination` is
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
            keys["ITSAppUsesNonExemptEncryption"] as? Bool, false,
            "the initial release follows the no-documentation questionnaire outcome; see encryption-export-compliance.md"
        )
        XCTAssertNil(
            keys["ITSEncryptionExportComplianceCode"],
            "the no-documentation path has no Apple-issued compliance code"
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

    /// Keep the source template aligned with the file access entitlements
    /// that package-app.sh verifies in the distribution signature.
    func testDistributionEntitlementsDeclareUserSelectedFileAccess() throws {
        let entitlements = Self.shellDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/Companion.entitlements")
        let data = try Data(contentsOf: entitlements)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        let keys = try XCTUnwrap(parsed as? [String: Any])

        XCTAssertEqual(
            keys["com.apple.security.files.user-selected.read-write"] as? Bool, true,
            "package-app.sh requires user selected file read and write access")
        XCTAssertEqual(
            keys["com.apple.security.files.bookmarks.app-scope"] as? Bool, true,
            "package-app.sh requires the app scope bookmark entitlement")
    }

    /// The local and dev lanes' identities are checked into the build-lane
    /// manifest and recognised by the shell, two files with no compile-time
    /// tie between them. A drift here would make a development build fall
    /// back to the shipping id's state directory and Keychain service.
    func testTheBuildLaneManifestNamesTheIdentifiersTheShellRecognises() throws {
        let manifest = Self.shellDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/build-lanes.sh")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        XCTAssertTrue(
            text.contains("LOCAL_BUNDLE_ID=\"\(FormFactor.localBundleIdentifier)\""),
            "scripts/build-lanes.sh does not assign LOCAL_BUNDLE_ID the id FormFactor names as the local lane"
        )
        XCTAssertTrue(
            text.contains("DEV_BUNDLE_ID=\"\(FormFactor.devBundleIdentifier)\""),
            "scripts/build-lanes.sh does not assign DEV_BUNDLE_ID the id FormFactor names as the dev lane"
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

    /// Plain text is offered under Open With at Alternate rank; Markdown, logs and
    /// dotenv files are Default rank. No NSDocumentClass, which issue #77 relies on.
    func testTheBundleDeclaresItsDocumentTypesWithNoDocumentClass() throws {
        let keys = try Self.identitySheet()
        let types = try XCTUnwrap(
            keys["CFBundleDocumentTypes"] as? [[String: Any]],
            "with no document type the Finder greys the pad out under Open With")

        let ranks = try Dictionary(types.map { type -> (String, String) in
            XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Editor")
            XCTAssertNil(
                type["NSDocumentClass"],
                "a document model would bring AppKit's own New, and ⌘N belongs to page::New")
            let contentTypes = try XCTUnwrap(type["LSItemContentTypes"] as? [String])
            XCTAssertEqual(contentTypes.count, 1, "one content type per declaration, so each has its own rank")
            return (contentTypes[0], try XCTUnwrap(type["LSHandlerRank"] as? String))
        }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(ranks.count, types.count, "one content type is declared twice")
        XCTAssertEqual(ranks, [
            "public.plain-text": "Alternate",
            "net.daringfireball.markdown": "Default",
            "com.apple.log": "Default",
            "com.onetimesecret.pad.dotenv": "Default",
        ])
    }

    /// Every declared content type the system does not define is imported here, with its extensions.
    func testTheBundleImportsTheTypesItsDocumentTypesName() throws {
        let keys = try Self.identitySheet()
        let imported = try XCTUnwrap(keys["UTImportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertNil(keys["UTExportedTypeDeclarations"], "three lanes exporting one type would contend for it")

        let extensions = try Dictionary(imported.map { type -> (String, [String]) in
            XCTAssertEqual(type["UTTypeConformsTo"] as? [String], ["public.plain-text"])
            let tags = try XCTUnwrap(type["UTTypeTagSpecification"] as? [String: Any])
            return (
                try XCTUnwrap(type["UTTypeIdentifier"] as? String),
                try XCTUnwrap(tags["public.filename-extension"] as? [String])
            )
        }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(extensions.count, imported.count, "one type is imported twice")
        XCTAssertEqual(Set(extensions.keys), ["net.daringfireball.markdown", "com.onetimesecret.pad.dotenv"])
        XCTAssertEqual(
            Set(extensions["net.daringfireball.markdown"] ?? []), FileFormatHints.markdownExtensions,
            "the Finder and the editor disagree about which files are Markdown")
        XCTAssertEqual(extensions["com.onetimesecret.pad.dotenv"], ["env", "envrc"])
    }

    private static func identitySheet() throws -> [String: Any] {
        let plist = shellDirectory.appendingPathComponent("OnetimePad-Info.plist")
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist), options: [], format: nil)
        return try XCTUnwrap(parsed as? [String: Any])
    }
}
