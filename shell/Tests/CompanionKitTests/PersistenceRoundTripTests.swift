import XCTest

@testable import CompanionKit

/// The persistence lifecycle driven whole, for the first time from a
/// test: load, mutate, let the debounce timer genuinely fire, and then
/// stand a second model over the same directory the way a relaunch
/// would. Everything before this file exercised the licence arithmetic
/// as pure functions; nothing constructed a `PageModel` and watched a
/// sealed file appear. The three init seams make that possible without
/// touching anything real: the state directory is a temporary one the
/// test owns, the core handle's credentials live in process memory
/// (`CompanionClient.ephemeral(tag:)`, never the login Keychain), and
/// the debounce is shortened so waiting on the real timer costs
/// milliseconds rather than the shipping two seconds.
@MainActor
final class PersistenceRoundTripTests: XCTestCase {
    /// A temporary directory, a throwaway defaults domain, and a
    /// credential tag, all unique to this test and cleaned up after it.
    /// Not a setUp override: those are nonisolated, and the model under
    /// test is main-actor state, so every test calls this first.
    private func makeFixture() throws -> (tempDir: URL, defaults: UserDefaults, tag: String) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suiteName = "companion-roundtrip-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }
        return (tempDir, defaults, "roundtrip-\(UUID().uuidString)")
    }

    /// A model over the fixture's directory. Models built from the same
    /// tag share one in-memory credential map, which is exactly what
    /// two launches of one app share through the Keychain.
    private func makeModel(in tempDir: URL, defaults: UserDefaults, tag: String) -> PageModel {
        PageModel(
            formFactor: .panel,
            defaults: defaults,
            seams: .init(
                stateDirectory: tempDir,
                client: .ephemeral(tag: tag),
                saveDebounce: 0.05
            )
        )
    }

    /// Wait for the debounced write to land, on the status the write
    /// publishes when it does (`waitUntil`). The debounce timer and the
    /// main-actor hop its body makes both ride the run loop XCTest turns
    /// while it waits, and the status moves last of all in `saveState`,
    /// after both files are written, so a test reading the files after
    /// this reads what the write left.
    private func waitForSave(on model: PageModel) {
        waitUntil(model.$saveStatus, description: "the debounced write landed") { $0 == .saved }
    }

    func testAMutationRoundTripsThroughTheSealedFileOnTheRealDebounce() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        let stateFile = FormFactor.stateFileURL(in: tempDir)
        let ledgerFile = FormFactor.ledgerFileURL(in: tempDir)

        // First launch: an empty directory is a fresh start, which is
        // what earns the session its licences legitimately. No bypass,
        // just the same truth table the shipping launch runs.
        let first = makeModel(in: tempDir, defaults: defaults, tag: tag)
        first.loadStateIfNeeded()
        XCTAssertEqual(first.tabs.count, 1, "a fresh start conjures exactly one tab")
        let sheet = try XCTUnwrap(first.selectedPageID)

        // The mutation travels the ordinary edit path, so it marks the
        // store dirty and arms the debounce the way a keystroke does.
        let ink = "the page came back"
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: ink)]))
        first.applyOps(sheet: sheet, opsJSON: ops)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateFile.path),
            "the write must wait for the debounce, not land on the mutation itself"
        )

        // Let the real timer fire and the deferred write land.
        waitForSave(on: first)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateFile.path),
            "the debounced write never reached the state file"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ledgerFile.path),
            "the same write settles the ledger file beside it"
        )

        // Second launch over the same directory and the same credential
        // map: the restore must open the file, and the page must come
        // back with its ink, through the same replay the editor uses.
        let second = makeModel(in: tempDir, defaults: defaults, tag: tag)
        second.loadStateIfNeeded()
        XCTAssertEqual(second.tabs.count, 1, "the restored session holds the saved tab")
        let restored = try XCTUnwrap(second.selectedPageID)
        XCTAssertEqual(second.storage(for: restored).string, ink)
    }

    /// The quit flush, which is the one thing `saveStateForQuit()`'s
    /// existing coverage never asks of it: not what it reports, but
    /// that it writes. ADR-0016 section 1 names this exactly, a
    /// regression that removed the flush would leave every other
    /// persistence test green, because the debounce eventually writes
    /// everything they look at. So the window here is long enough that
    /// the timer cannot be what lands the bytes: if the file moves, the
    /// quit path moved it.
    ///
    /// The second half is the other side of the same call: quit is a
    /// flush and not an extra write, so nothing may land behind it. Two
    /// mechanisms hold that, `saveState` invalidating the armed timer on
    /// its way in and the generation check standing down a body that had
    /// already fired (`SaveSchedule`), and the assertion is on the
    /// outcome they share, because a duplicate is a whole extra
    /// ciphertext generation on disk for a store that did not change.
    func testTheQuitFlushWritesWhatTheDebounceStillHolds() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        let stateFile = FormFactor.stateFileURL(in: tempDir)

        // A window no test is patient enough to wait out by accident,
        // and long enough that every assertion below runs inside it.
        let model = PageModel(
            formFactor: .panel,
            defaults: defaults,
            seams: .init(
                stateDirectory: tempDir,
                client: .ephemeral(tag: tag),
                saveDebounce: 0.5
            )
        )
        model.loadStateIfNeeded()
        // Settle the launch mint by hand so the comparison below is
        // between two generations of a file that already exists, rather
        // than between nothing and something.
        XCTAssertTrue(model.saveState())
        let mintBytes = try Data(contentsOf: stateFile)

        let sheet = try XCTUnwrap(model.selectedPageID)
        let ink = "typed in the last second before logout"
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: ink)]))
        model.applyOps(sheet: sheet, opsJSON: ops)
        // Nothing has spun the run loop since the mutation, so the
        // debounce timer has not fired and cannot have: the file on
        // disk still describes the store as it was before the edit.
        XCTAssertEqual(
            try Data(contentsOf: stateFile), mintBytes,
            "the debounce should still be holding this write"
        )

        // The flush. Synchronous by contract, because the terminate
        // path answers with its result, so the bytes must have moved by
        // the time it returns.
        XCTAssertEqual(model.saveStateForQuit(), .settled)
        let flushedBytes = try Data(contentsOf: stateFile)
        XCTAssertNotEqual(
            flushedBytes, mintBytes,
            "quit returned settled without writing what the debounce was holding"
        )

        // Past the far end of the window the mutation armed. Nothing
        // may write in here: the timer was invalidated by the flush,
        // and had it fired first it would find its generation overtaken.
        letElapse(1.2)
        XCTAssertEqual(
            try Data(contentsOf: stateFile), flushedBytes,
            "the deferred body ran after the quit write and sealed a duplicate generation"
        )

        // And the flushed generation is the one a relaunch opens.
        let relaunch = makeModel(in: tempDir, defaults: defaults, tag: tag)
        relaunch.loadStateIfNeeded()
        let restored = try XCTUnwrap(relaunch.selectedPageID)
        XCTAssertEqual(relaunch.storage(for: restored).string, ink)
    }

    func testAForeignCredentialScopeCannotOpenTheFile() throws {
        // The negative that proves the round trip above is a real
        // decryption and not a file copy: a model whose credential map
        // never held the key meets an existing file it cannot open, and
        // the licence machinery answers by withholding the write: the
        // session runs on its consolation page and puts nothing over
        // yesterday's file.
        let (tempDir, defaults, tag) = try makeFixture()
        let stateFile = FormFactor.stateFileURL(in: tempDir)

        let first = makeModel(in: tempDir, defaults: defaults, tag: tag)
        first.loadStateIfNeeded()
        let sheet = try XCTUnwrap(first.selectedPageID)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "sealed elsewhere")]))
        first.applyOps(sheet: sheet, opsJSON: ops)
        waitForSave(on: first)
        let sealedBytes = try Data(contentsOf: stateFile)

        let stranger = makeModel(in: tempDir, defaults: defaults, tag: "stranger-\(UUID().uuidString)")
        stranger.loadStateIfNeeded()
        // The refusal keeps the session usable: a working page appears
        // (with the issue #49 standing state raised over it), but
        // nothing this session does may rewrite the file it could not
        // read, so the ciphertext on disk stays byte for byte what the
        // first session sealed.
        let strangerSheet = try XCTUnwrap(stranger.selectedPageID)
        let strangerOps = try XCTUnwrap(
            DocumentEditOp.wireJSON([.ins(at: 0, text: "the consolation page")]))
        stranger.applyOps(sheet: strangerSheet, opsJSON: strangerOps)
        letElapse(0.3)
        XCTAssertEqual(
            try Data(contentsOf: stateFile), sealedBytes,
            "an unlicensed session rewrote a file it could not read"
        )
    }
}
