import XCTest

@testable import CompanionKit

/// Issue #49 driven whole: a restore that fails over an existing file
/// raises a standing state the surface can show, the user's discard is
/// the one way back, and the write lifecycle reports itself. Built on
/// the same three init seams as the round-trip tests: a temporary state
/// directory, in-process credentials, a debounce short enough to let
/// the real timer fire.
@MainActor
final class RestoreFailureTests: XCTestCase {
    private func makeFixture() throws -> (tempDir: URL, defaults: UserDefaults, tag: String) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-restorefail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suiteName = "companion-restorefail-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }
        return (tempDir, defaults, "restorefail-\(UUID().uuidString)")
    }

    /// The retry window is defaulted rather than shortened: only the
    /// refusal tests at the foot of this file wait on one, and every
    /// other test here would rather the retry stayed out of the way.
    private func makeModel(
        in tempDir: URL, defaults: UserDefaults, tag: String,
        saveRetryDebounce: TimeInterval? = nil
    ) -> PageModel {
        PageModel(
            formFactor: .panel,
            defaults: defaults,
            seams: .init(
                stateDirectory: tempDir,
                client: .ephemeral(tag: tag),
                saveDebounce: 0.05,
                saveRetryDebounce: saveRetryDebounce
            )
        )
    }

    private func spinRunLoop(
        until condition: () -> Bool, timeout: TimeInterval = 5
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Seal real files into the fixture directory under one credential
    /// tag, so a model under a different tag meets files it cannot
    /// open: the shipping shape of a lost or denied key.
    private func sealFiles(
        in tempDir: URL, defaults: UserDefaults, tag: String, ink: String
    ) throws {
        let stateFile = FormFactor.stateFileURL(in: tempDir)
        let sealer = makeModel(in: tempDir, defaults: defaults, tag: tag)
        sealer.loadStateIfNeeded()
        let sheet = try XCTUnwrap(sealer.selectedPageID)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: ink)]))
        sealer.applyOps(sheet: sheet, opsJSON: ops)
        spinRunLoop { FileManager.default.fileExists(atPath: stateFile.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path))
    }

    func testAFreshStartRaisesNoStandingState() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        let model = makeModel(in: tempDir, defaults: defaults, tag: tag)
        model.loadStateIfNeeded()
        XCTAssertFalse(model.contentRestoreRefused)
        XCTAssertFalse(model.ledgerRestoreRefused)
    }

    func testARefusedRestoreRaisesTheStandingState() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "sealed elsewhere")

        // A different credential tag never held the keys, so both files
        // exist and neither opens: both standing states go up, and they
        // stay up, because nothing but the user's own gesture clears
        // them.
        let stranger = makeModel(
            in: tempDir, defaults: defaults, tag: "stranger-\(UUID().uuidString)")
        stranger.loadStateIfNeeded()
        XCTAssertTrue(stranger.contentRestoreRefused)
        XCTAssertTrue(stranger.ledgerRestoreRefused)
    }

    func testTheDiscardTakesTheStateDownAndTheNextSealLands() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        let stateFile = FormFactor.stateFileURL(in: tempDir)
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "sealed elsewhere")
        let refusedBytes = try Data(contentsOf: stateFile)

        let strangerTag = "stranger-\(UUID().uuidString)"
        let stranger = makeModel(in: tempDir, defaults: defaults, tag: strangerTag)
        stranger.loadStateIfNeeded()
        XCTAssertTrue(stranger.contentRestoreRefused)
        let sheet = try XCTUnwrap(stranger.selectedPageID)
        let ink = "the consolation page, kept"
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: ink)]))
        stranger.applyOps(sheet: sheet, opsJSON: ops)

        // The user's discard: the banner comes down at once, and the
        // reseal it arms replaces the unreadable file with this
        // session's own sealed generation inside one debounce.
        stranger.clearUnreadableStateFile()
        XCTAssertFalse(stranger.contentRestoreRefused)
        spinRunLoop {
            FileManager.default.fileExists(atPath: stateFile.path)
                && (try? Data(contentsOf: stateFile)) != refusedBytes
        }
        XCTAssertNotEqual(
            try Data(contentsOf: stateFile), refusedBytes,
            "the discard must end with this session's seal in place of the unreadable file"
        )

        // The proof the re-granted licence is real: a relaunch under
        // the discarding session's credentials restores what it typed.
        let relaunch = makeModel(in: tempDir, defaults: defaults, tag: strangerTag)
        relaunch.loadStateIfNeeded()
        XCTAssertFalse(relaunch.contentRestoreRefused)
        let restored = try XCTUnwrap(relaunch.selectedPageID)
        XCTAssertEqual(relaunch.storage(for: restored).string, ink)
    }

    func testTheDiscardIsANoOpForALicensedSession() throws {
        // The guard the erase hangs off: a session that holds its
        // licence has no unreadable file to discard, and the gesture
        // must not drop a file this session can and does write.
        let (tempDir, defaults, tag) = try makeFixture()
        let stateFile = FormFactor.stateFileURL(in: tempDir)
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "still mine")

        let owner = makeModel(in: tempDir, defaults: defaults, tag: tag)
        owner.loadStateIfNeeded()
        XCTAssertFalse(owner.contentRestoreRefused)
        owner.clearUnreadableStateFile()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateFile.path),
            "a licensed session's discard must leave the file alone"
        )
    }

    func testClearingTheLedgerTakesItsStandingStateDown() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "sealed elsewhere")

        let stranger = makeModel(
            in: tempDir, defaults: defaults, tag: "stranger-\(UUID().uuidString)")
        stranger.loadStateIfNeeded()
        XCTAssertTrue(stranger.ledgerRestoreRefused)
        stranger.clearLedger()
        XCTAssertFalse(stranger.ledgerRestoreRefused)
        // The content side is untouched by the ledger's gesture.
        XCTAssertTrue(stranger.contentRestoreRefused)
    }

    /// The standing line names the Settings clear as the one way out of
    /// a ledger that will not open, and issue #78 hid that control. So
    /// it comes back for exactly as long as the line stands, and goes
    /// again when the clear lands: the section's disappearance is the
    /// receipt for the gesture (`HiddenUI.showsLedgerClear`).
    func testTheRefusedLedgerSurfacesTheControlItsBannerNames() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "sealed elsewhere")

        XCTAssertFalse(
            HiddenUI.showsLedgerClear(ledgerRestoreRefused: false),
            "the section is hidden in the ordinary case, or this proves nothing")

        let stranger = makeModel(
            in: tempDir, defaults: defaults, tag: "stranger-\(UUID().uuidString)")
        stranger.loadStateIfNeeded()
        XCTAssertTrue(
            HiddenUI.showsLedgerClear(ledgerRestoreRefused: stranger.ledgerRestoreRefused),
            "the banner tells the user to clear the ledger in Settings and the section is not there")

        stranger.clearLedger()
        XCTAssertFalse(
            HiddenUI.showsLedgerClear(ledgerRestoreRefused: stranger.ledgerRestoreRefused))
    }

    func testTheSaveStatusWalksSavingThenSaved() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        let model = makeModel(in: tempDir, defaults: defaults, tag: tag)
        model.loadStateIfNeeded()
        // A fresh start mints a tab, and the mint owes a real write, so
        // the status is honest about it from launch: saving, then saved
        // when the debounced write lands.
        XCTAssertEqual(model.saveStatus, .saving)
        spinRunLoop { model.saveStatus == .saved }
        XCTAssertEqual(model.saveStatus, .saved)

        let sheet = try XCTUnwrap(model.selectedPageID)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "a keystroke")]))
        model.applyOps(sheet: sheet, opsJSON: ops)
        XCTAssertEqual(
            model.saveStatus, .saving,
            "the buffer differs from the file from the mark, not from the timer's far end"
        )

        spinRunLoop { model.saveStatus == .saved }
        XCTAssertEqual(model.saveStatus, .saved)
    }

    func testARestoredUntouchedSessionSaysNothing() throws {
        // The one shape that genuinely has nothing to say: a restore
        // that opened the file and a user who has not touched anything
        // since. No write is owed, so no word shows.
        let (tempDir, defaults, tag) = try makeFixture()
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "already sealed")
        let second = makeModel(in: tempDir, defaults: defaults, tag: tag)
        second.loadStateIfNeeded()
        XCTAssertEqual(second.saveStatus, .idle)
    }

    /// Issue #46: ⌘S calls `saveState()` directly, the same call the
    /// debounce timer and the quit path make. A press with nothing
    /// owed is the shortcut's whole point: the reassurance that the
    /// idle silence means "saved", not "unproven".
    func testForceSaveOnAnUntouchedRestoredSessionShowsSaved() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "already sealed")
        let second = makeModel(in: tempDir, defaults: defaults, tag: tag)
        second.loadStateIfNeeded()
        XCTAssertEqual(second.saveStatus, .idle)

        XCTAssertTrue(second.saveState())
        XCTAssertEqual(second.saveStatus, .saved)
    }

    /// A withheld content licence still shows its own standing state
    /// ahead of `saveStatus` (issue #49); ⌘S does not create a second,
    /// contradictory "saved" reading over that banner.
    func testForceSaveOverAWithheldLicenceLeavesTheStandingStateInPlace() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "sealed elsewhere")

        let stranger = makeModel(
            in: tempDir, defaults: defaults, tag: "stranger-\(UUID().uuidString)")
        stranger.loadStateIfNeeded()
        XCTAssertTrue(stranger.contentRestoreRefused)

        XCTAssertTrue(stranger.saveState())
        XCTAssertTrue(stranger.contentRestoreRefused)
    }

    func testTheQuitFlushOverAWithheldLicenceNamesTheLoss() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "sealed elsewhere")

        let stranger = makeModel(
            in: tempDir, defaults: defaults, tag: "stranger-\(UUID().uuidString)")
        stranger.loadStateIfNeeded()
        let sheet = try XCTUnwrap(stranger.selectedPageID)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "typed into the void")]))
        stranger.applyOps(sheet: sheet, opsJSON: ops)

        // The flush settles, because the withheld legs owe nothing, but
        // the session holds content that was never written: the quit
        // path must repeat the banner's warning rather than quit
        // silently.
        XCTAssertEqual(stranger.saveStateForQuit(), .unsavableWithContent)
    }

    func testTheQuitFlushOverAnEmptyUnlicensedSessionQuitsSilently() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "sealed elsewhere")

        let stranger = makeModel(
            in: tempDir, defaults: defaults, tag: "stranger-\(UUID().uuidString)")
        stranger.loadStateIfNeeded()
        // Nothing typed: nothing to lose, so no warning.
        XCTAssertEqual(stranger.saveStateForQuit(), .settled)
    }

    /// A damaged snapshot, which is the cause every other refusal test
    /// here stands in for without ever producing: they all withhold the
    /// licence by presenting a foreign credential tag, so the key is
    /// what is wrong. Here the key is right and the file is wrong, and
    /// the two are worth telling apart, because the restore has a
    /// branch that DROPS a file it cannot use, the superseded envelope
    /// (ADR-0016 section 9), and that branch hands the licence back. A
    /// file that is merely corrupt must take the other branch: the
    /// damage might be one flipped bit over pages the user still wants,
    /// and dropping it would spend the only copy.
    ///
    /// The damage is a bit flipped at the very end of the file, inside
    /// the AEAD tag, so the envelope's magic and header are exactly
    /// what this build wrote and no magic rule can be what fires.
    func testADamagedSnapshotWithholdsTheLicenceWithoutDroppingTheFile() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        let stateFile = FormFactor.stateFileURL(in: tempDir)
        try sealFiles(in: tempDir, defaults: defaults, tag: tag, ink: "yesterday's pages")

        var damaged = try Data(contentsOf: stateFile)
        damaged[damaged.count - 1] ^= 0xFF
        try damaged.write(to: stateFile)

        // The same credential tag the file was sealed under: this
        // session holds the right key and still cannot open the file.
        let model = makeModel(in: tempDir, defaults: defaults, tag: tag)
        model.loadStateIfNeeded()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateFile.path),
            "the restore dropped a file it could only not open, taking the pages with it"
        )
        XCTAssertTrue(
            model.contentRestoreRefused,
            "a damaged snapshot read as a fresh start, so this session may write over it"
        )
        // The ledger is a second file under a second key and was not
        // touched, so its own licence is untouched: the two refuse
        // independently or the pairing means nothing.
        XCTAssertFalse(model.ledgerRestoreRefused)

        // And the withholding is a real one: the consolation page this
        // session types on goes nowhere near the damaged bytes, which
        // are still all that remains of yesterday and might yet be
        // recovered by hand.
        let sheet = try XCTUnwrap(model.selectedPageID)
        let ink = "the consolation page"
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: ink)]))
        model.applyOps(sheet: sheet, opsJSON: ops)
        spinRunLoop(until: { false }, timeout: 0.3)
        XCTAssertEqual(
            try Data(contentsOf: stateFile), damaged,
            "a session that could not read the file wrote over it anyway"
        )

        // The way out is the same one gesture as for an unreadable key:
        // the user discards what cannot be read, and this session starts
        // saving from there.
        model.clearUnreadableStateFile()
        XCTAssertFalse(model.contentRestoreRefused)
        spinRunLoop {
            FileManager.default.fileExists(atPath: stateFile.path)
                && (try? Data(contentsOf: stateFile)) != damaged
        }
        XCTAssertNotEqual(try Data(contentsOf: stateFile), damaged)

        let relaunch = makeModel(in: tempDir, defaults: defaults, tag: tag)
        relaunch.loadStateIfNeeded()
        XCTAssertFalse(relaunch.contentRestoreRefused)
        let restored = try XCTUnwrap(relaunch.selectedPageID)
        XCTAssertEqual(relaunch.storage(for: restored).string, ink)
    }

    /// The one refusal lever a test has, and it is enough: make the
    /// directory unwritable. `CompanionClient` is final, so there is no
    /// double that could make `persistSave` say no, and `saveState`
    /// swallowing `prepareStateDirectory`'s throw is what lets the
    /// refusal land in the write itself rather than ahead of it.
    private func setWritable(_ writable: Bool, _ directory: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o700 : 0o500], ofItemAtPath: directory.path)
    }

    /// The window a refused write opens (ADR-0016 section 2), driven
    /// against a write that genuinely failed rather than against the
    /// arithmetic. Three claims, and the shipping ten seconds is not
    /// one of them: the status goes and stays `failed`, everything
    /// typed inside the window rides it instead of arming a shorter
    /// one, and the retry at its far end writes with no further gesture
    /// from anybody.
    ///
    /// The middle claim is the one worth the wall clock. The debounce
    /// here is 0.05 s and the retry 1.0 s, and the volume is made
    /// writable again immediately after the refusal: if a mutation
    /// re-armed the debounce, a write would land within a fifth of a
    /// second, and the file would move while the test is asserting that
    /// it does not.
    func testARefusedWriteOpensAWindowThatAbsorbsWhatFollows() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        let stateFile = FormFactor.stateFileURL(in: tempDir)
        addTeardownBlock { try? self.setWritable(true, tempDir) }

        let model = makeModel(in: tempDir, defaults: defaults, tag: tag, saveRetryDebounce: 1.0)
        model.loadStateIfNeeded()
        spinRunLoop { model.saveStatus == .saved }
        XCTAssertEqual(model.saveStatus, .saved)
        let settledBytes = try Data(contentsOf: stateFile)

        // The volume goes read-only under a session that holds both its
        // licences: nothing about permission is a licence question, so
        // this session may write and simply cannot.
        try setWritable(false, tempDir)
        let sheet = try XCTUnwrap(model.selectedPageID)
        let ink = "typed onto a full disk"
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: ink)]))
        model.applyOps(sheet: sheet, opsJSON: ops)
        spinRunLoop { model.saveStatus == .failed }
        XCTAssertEqual(
            model.saveStatus, .failed,
            "a refused write must say so; silence here reads as saved"
        )
        XCTAssertEqual(
            try Data(contentsOf: stateFile), settledBytes,
            "the refused write left something behind on disk"
        )

        // The refusal is sticky by design: a keystroke on top of it
        // does not make it old news, and the surface must not walk back
        // to a hopeful "saving" while the pages are still nowhere.
        try setWritable(true, tempDir)
        let more = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "and more")]))
        model.applyOps(sheet: sheet, opsJSON: more)
        XCTAssertEqual(model.saveStatus, .failed)

        // Well past the debounce, well inside the retry: the mutation
        // above was absorbed by the window the refusal opened, so
        // nothing has been written even though the volume now takes
        // writes again.
        spinRunLoop(until: { false }, timeout: 0.4)
        XCTAssertEqual(model.saveStatus, .failed)
        XCTAssertEqual(
            try Data(contentsOf: stateFile), settledBytes,
            "a mutation inside the retry window armed a window of its own"
        )

        // And the far end of the window, which no gesture reaches: the
        // retry comes back on its own and writes what the session has
        // been holding since the refusal.
        spinRunLoop { model.saveStatus == .saved }
        XCTAssertEqual(
            model.saveStatus, .saved,
            "the retry never fired, so a session that fails one write keeps its pages in memory"
        )
        XCTAssertNotEqual(try Data(contentsOf: stateFile), settledBytes)

        // The proof it is a real generation and not a status change: a
        // relaunch opens it and finds both edits.
        let relaunch = makeModel(in: tempDir, defaults: defaults, tag: tag)
        relaunch.loadStateIfNeeded()
        let restored = try XCTUnwrap(relaunch.selectedPageID)
        XCTAssertEqual(relaunch.storage(for: restored).string, "and more" + ink)
    }

    /// The loudest arm of the quit truth table (issue #49), which until
    /// now had never met a write that actually failed: the flush is
    /// refused, so the alert must say so whatever the licences read.
    func testTheQuitFlushOverARefusedWriteSaysRefused() throws {
        let (tempDir, defaults, tag) = try makeFixture()
        addTeardownBlock { try? self.setWritable(true, tempDir) }

        let model = makeModel(in: tempDir, defaults: defaults, tag: tag, saveRetryDebounce: 1.0)
        model.loadStateIfNeeded()
        spinRunLoop { model.saveStatus == .saved }

        try setWritable(false, tempDir)
        let sheet = try XCTUnwrap(model.selectedPageID)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "lost at logout")]))
        model.applyOps(sheet: sheet, opsJSON: ops)

        XCTAssertEqual(model.saveStateForQuit(), .refused)
    }
}
