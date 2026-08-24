import XCTest

@testable import CompanionKit

/// What the validator does with a file, good or bad (issue #76).
///
/// The rule under test throughout: a keymap is data, and data is
/// checked before it is installed. One bad line costs that line and
/// nothing else; a file that is wrong about its own shape costs the
/// whole file and the app falls back rather than running on a partial
/// map. Nothing here touches a real keymap on disk, so the suite says
/// the same thing on a machine whose owner has rebound everything.
final class KeymapValidationTests: XCTestCase {
    /// A minimal, valid default the override tests can lie on top of.
    private let simpleDefault = """
        [
          { "context": "Editor", "bindings": { "cmd-alt-n": "page::New" } }
        ]
        """

    private func resolve(_ text: String) -> ResolvedKeymap {
        Keymap.resolve(defaultText: text, overrideText: nil)
    }

    // MARK: JSON5, the two tolerances

    func testCommentsAndTrailingCommasAreRead() {
        let keymap = resolve(
            """
            // The whole file may explain itself.
            [
              /* and a block comment too */
              {
                "context": "Editor",
                "bindings": {
                  "cmd-alt-n": "page::New", // even at the end of a line
                },
              },
            ]
            """)
        XCTAssertEqual(keymap.faults, [])
        XCTAssertEqual(keymap.bindings.count, 1)
        XCTAssertEqual(keymap.bindings.first?.command, .pageNew)
    }

    /// A naive stripper would take the `//` out of the middle of this
    /// string and leave broken JSON behind.
    func testASlashInsideAStringIsNotAComment() {
        let keymap = resolve(
            """
            [{ "context": "Editor", "bindings": { "cmd-/": "page::New" } }]
            """)
        XCTAssertEqual(keymap.faults, [])
        XCTAssertEqual(keymap.bindings.first?.keystroke.canonical, "cmd-/")
    }

    func testMalformedJSONCostsTheWholeFile() {
        let keymap = resolve("[{ \"context\": \"Editor\" ")
        XCTAssertTrue(keymap.bindings.isEmpty)
        guard case .fileRejected(.bundledDefault, .notJSON) = keymap.diagnostics.first else {
            return XCTFail("expected the file to be refused whole, got \(keymap.diagnostics)")
        }
    }

    func testATopLevelThatIsNotAnArrayCostsTheWholeFile() {
        let keymap = resolve("{ \"context\": \"Editor\" }")
        XCTAssertEqual(keymap.diagnostics, [.fileRejected(.bundledDefault, .notAnArray)])
    }

    // MARK: The schema version

    func testTheDeclaredVersionIsAccepted() {
        let keymap = resolve(
            """
            [
              { "schema_version": 1 },
              { "context": "Editor", "bindings": { "cmd-alt-n": "page::New" } }
            ]
            """)
        XCTAssertEqual(keymap.faults, [])
        XCTAssertEqual(keymap.bindings.count, 1)
    }

    /// A file from a future build is refused rather than half read: the
    /// version exists precisely so that a format change can say so.
    func testAVersionThisBuildDoesNotKnowCostsTheWholeFile() {
        let keymap = resolve(
            """
            [
              { "schema_version": 99 },
              { "context": "Editor", "bindings": { "cmd-alt-n": "page::New" } }
            ]
            """)
        XCTAssertTrue(keymap.bindings.isEmpty)
        XCTAssertEqual(
            keymap.diagnostics, [.fileRejected(.bundledDefault, .unsupportedSchemaVersion(99))])
    }

    func testTwoVersionsInOneFileAreRefused() {
        let keymap = resolve("[{ \"schema_version\": 1 }, { \"schema_version\": 1 }]")
        XCTAssertEqual(
            keymap.diagnostics, [.fileRejected(.bundledDefault, .repeatedSchemaVersion)])
    }

    /// A file that says nothing about its version is version 1, because
    /// the format shipped before anyone needed to say.
    func testAnUndeclaredVersionIsTheOneThisBuildReads() {
        XCTAssertEqual(resolve(simpleDefault).faults, [])
    }

    // MARK: One line at a time

    func testAMalformedKeystrokeCostsOnlyItself() {
        let keymap = resolve(
            """
            [{ "context": "Editor", "bindings": {
              "cmd-nope": "page::New",
              "cmd-w": "page::Close"
            } }]
            """)
        XCTAssertEqual(keymap.bindings.map(\.command), [.pageClose])
        XCTAssertEqual(
            keymap.faults,
            [.malformedKeystroke(.bundledDefault, keystroke: "cmd-nope", failure: .unknownKey("nope"))]
        )
    }

    func testACommandThisBuildCannotRunIsRefused() {
        let keymap = resolve(
            """
            [{ "context": "Editor", "bindings": { "cmd-k": "page::Teleport" } }]
            """)
        XCTAssertTrue(keymap.bindings.isEmpty)
        XCTAssertEqual(
            keymap.faults,
            [.unknownCommand(.bundledDefault, keystroke: "cmd-k", command: "page::Teleport")])
    }

    func testASurfaceThatDoesNotExistIsRefused() {
        let keymap = resolve(
            """
            [{ "context": "Sidebar", "bindings": { "cmd-k": "page::New" } }]
            """)
        XCTAssertTrue(keymap.bindings.isEmpty)
        XCTAssertEqual(keymap.faults, [.unknownContext(.bundledDefault, context: "Sidebar")])
    }

    /// Two spellings of one chord in one section. The first by sorted
    /// order is kept, so which one wins does not depend on the order a
    /// dictionary happened to hash into.
    func testTwoSpellingsOfOneChordInOneSectionAreADuplicate() {
        let keymap = resolve(
            """
            [{ "context": "Editor", "bindings": {
              "alt-cmd-n": "page::Close",
              "cmd-alt-n": "page::New"
            } }]
            """)
        XCTAssertEqual(keymap.bindings.map(\.command), [.pageClose])
        XCTAssertEqual(
            keymap.faults,
            [
                .duplicateBinding(
                    .bundledDefault, keystroke: "cmd-alt-n", kept: .pageClose, dropped: .pageNew)
            ])
    }

    /// A binding in a context nothing consults is legal and inert, and
    /// saying so is kinder than silence.
    func testABindingInAnUnconsultedContextIsNoted() throws {
        let keymap = resolve(
            """
            [{ "context": "TabStrip", "bindings": { "cmd-k": "page::New" } }]
            """)
        XCTAssertEqual(keymap.faults, [])
        XCTAssertEqual(
            keymap.diagnostics,
            [.contextNotConsulted(.bundledDefault, context: .tabStrip, keystroke: "cmd-k")])
        XCTAssertNil(keymap.command(for: try parse("cmd-k"), in: .editor))
    }

    /// A section with no context is every context, which is how Zed
    /// reads one and therefore how a file copied from there behaves.
    func testASectionWithoutAContextAppliesEverywhere() throws {
        let keymap = Keymap.resolve(
            defaultText: """
                [{ "bindings": { "cmd-k": "page::New" } }]
                """,
            overrideText: nil)
        XCTAssertEqual(keymap.bindings.count, KeymapContext.allCases.count)
        XCTAssertEqual(keymap.command(for: try parse("cmd-k"), in: .editor), .pageNew)
    }

    // MARK: The user's file, laid over ours

    func testAnOverrideTakesTheChord() throws {
        let keymap = Keymap.resolve(
            defaultText: simpleDefault,
            overrideText: """
                [{ "context": "Editor", "bindings": { "cmd-alt-n": "page::Close" } }]
                """)
        XCTAssertEqual(keymap.command(for: try parse("cmd-alt-n"), in: .editor), .pageClose)
        XCTAssertEqual(keymap.faults, [])
    }

    func testAnOverrideCanAddAChordOfItsOwn() throws {
        let keymap = Keymap.resolve(
            defaultText: simpleDefault,
            overrideText: """
                [{ "context": "Editor", "bindings": { "ctrl-n": "page::New" } }]
                """)
        XCTAssertEqual(keymap.bindings.count, 2)
        XCTAssertEqual(keymap.command(for: try parse("ctrl-n"), in: .editor), .pageNew)
    }

    /// Null is Zed's unbinding, and it has to work, or a user cannot
    /// take back a chord the app claimed.
    func testNullTakesAChordAway() {
        let keymap = Keymap.resolve(
            defaultText: simpleDefault,
            overrideText: """
                [{ "context": "Editor", "bindings": { "cmd-alt-n": null } }]
                """)
        XCTAssertTrue(keymap.bindings.isEmpty)
        XCTAssertEqual(keymap.faults, [])
    }

    func testAnUnbindingThatHitsNothingIsReported() {
        let keymap = Keymap.resolve(
            defaultText: simpleDefault,
            overrideText: """
                [{ "context": "Editor", "bindings": { "cmd-alt-j": null } }]
                """)
        XCTAssertEqual(keymap.faults, [.unbindsNothing(.userOverride, keystroke: "cmd-alt-j")])
    }

    // MARK: Falling back

    /// A typo in the user's file costs them their customisation and not
    /// their app.
    func testARefusedOverrideLeavesTheDefaultStanding() {
        let keymap = Keymap.resolve(defaultText: simpleDefault, overrideText: "not json at all")
        XCTAssertEqual(keymap.bindings.map(\.command), [.pageNew])
        guard case .fileRejected(.userOverride, _) = keymap.faults.first else {
            return XCTFail("expected the override to be named as the refused file")
        }
    }

    /// The default going missing is a packaging fault, and the answer is
    /// the last map that resolved cleanly.
    func testAMissingDefaultFallsBackToTheLastGoodMap() {
        let previous = resolve(simpleDefault)
        let keymap = Keymap.resolve(defaultText: nil, overrideText: nil, previous: previous)
        XCTAssertEqual(keymap.bindings.map(\.command), [.pageNew])
        XCTAssertEqual(keymap.diagnostics.first, .defaultKeymapMissing)
    }

    /// With nothing to fall back to, no chord fires. Almost every
    /// gesture still has a button or a menu item, and the two that do
    /// not are named in `docs/development/about-the-keymap.md`, so the
    /// app stays usable and nothing is pointed anywhere unintended.
    func testAMissingDefaultAndNoHistoryBindsNothing() {
        let keymap = Keymap.resolve(defaultText: nil, overrideText: nil)
        XCTAssertTrue(keymap.bindings.isEmpty)
        XCTAssertEqual(keymap.diagnostics, [.defaultKeymapMissing])
    }

    /// A refused default is not patched up with the override alone: a
    /// keymap built from half its sources is a surprise waiting for the
    /// first chord.
    func testARefusedDefaultDoesNotLeaveTheOverrideRunningAlone() {
        let keymap = Keymap.resolve(
            defaultText: "{",
            overrideText: """
                [{ "context": "Editor", "bindings": { "cmd-k": "page::New" } }]
                """)
        XCTAssertTrue(keymap.bindings.isEmpty)
    }

    private func parse(_ text: String) throws -> Keystroke {
        switch Keystroke.parse(text) {
        case .success(let keystroke): return keystroke
        case .failure(let failure): throw failure
        }
    }
}
