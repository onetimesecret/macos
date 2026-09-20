import XCTest

@testable import CompanionKit

/// The Customize Keyboard Shortcuts… menu item (BackdropApp.swift): the
/// model side is `PageModel.openUserKeymapFile()`, which seeds the file
/// with the bundled default on the first click and opens the existing
/// bytes on every one after that. The menu item posts no chord and has
/// no side effect a suite can drive from AppKit, so this exercises the
/// method directly.
///
/// Every model here is seamed for both its state directory and its
/// keymap override, so the installed app's Application Support is not
/// touched.
@MainActor
final class KeymapOpenFileTests: XCTestCase {
    private struct Fixture {
        let state: URL
        let configuration: URL
        let keymap: URL
        let defaults: UserDefaults
        let tag: String
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-keymap-open-\(UUID().uuidString)", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        // The configuration directory is deliberately not created here.
        // The point of the method under test is that the click is what
        // creates it.
        let configuration = root.appendingPathComponent("configuration", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let keymap = FormFactor.userKeymapFileURL(in: configuration)
        let suiteName = "companion-keymap-open-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            state: state, configuration: configuration, keymap: keymap,
            defaults: defaults, tag: "keymap-open-\(UUID().uuidString)"
        )
    }

    private func makeModel(_ fixture: Fixture) -> PageModel {
        PageModel(
            formFactor: .panel,
            defaults: fixture.defaults,
            seams: .init(
                stateDirectory: fixture.state,
                client: CompanionClient.ephemeral(tag: fixture.tag),
                saveDebounce: 0.05,
                keymapOverride: fixture.keymap
            )
        )
    }

    func testFirstOpenSeedsTheKeymapWithTheBundledDefault() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture)
        model.loadStateIfNeeded()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.keymap.path),
            "the config directory is not created by the launch path"
        )

        model.openUserKeymapFile()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.keymap.path),
            "the click seeds the file"
        )
        let onDisk = try String(contentsOf: fixture.keymap, encoding: .utf8)
        let seed = try XCTUnwrap(
            Keymap.bundledDefaultText(),
            "the bundle ships the default the seed copies"
        )
        XCTAssertEqual(onDisk, seed, "the file the person opens is what the app already reads")

        let file = try XCTUnwrap(model.openFiles.first, "the seeded file is mounted as a document")
        XCTAssertEqual(file.name, "keymap.json")
        XCTAssertEqual(model.selectedFile, file.id, "the keymap is the surface after the click")
    }

    func testSecondOpenLeavesTheUsersOwnBytesAlone() throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.configuration, withIntermediateDirectories: true)
        let hand = "[\n  // hand-written override\n  { \"context\": \"Editor\", \"bindings\": {} }\n]\n"
        try Data(hand.utf8).write(to: fixture.keymap)

        let model = makeModel(fixture)
        model.loadStateIfNeeded()

        model.openUserKeymapFile()

        let onDisk = try String(contentsOf: fixture.keymap, encoding: .utf8)
        XCTAssertEqual(onDisk, hand, "an existing file is opened, not overwritten")

        let file = try XCTUnwrap(model.openFiles.first)
        XCTAssertEqual(file.name, "keymap.json")
    }
}
