import XCTest

@testable import CompanionKit

/// Panels a test answers for.
///
/// Every one of them is a stored answer rather than a closure, because
/// what these tests assert is which answer the model acted on, and a
/// closure would let a test assert on a call it never actually made.
/// `reviews` and `confirmations` are counted so a test can say the
/// review was raised once, or not at all.
@MainActor
final class ScriptedFilePanels: FilePanels {
    var openURL: URL?
    var destinationURL: URL?
    var review: FileCloseReview = .cancel
    var confirmation = true

    private(set) var reviews = 0
    private(set) var confirmations = 0
    private(set) var opens = 0
    private(set) var destinations = 0

    func chooseFileToOpen() -> URL? {
        opens += 1
        return openURL
    }

    func chooseDestination(suggestedName: String) -> URL? {
        destinations += 1
        return destinationURL
    }

    func reviewUnsavedFile(named name: String) -> FileCloseReview {
        reviews += 1
        return review
    }

    func confirmDiscardingEdits(named name: String) -> Bool {
        confirmations += 1
        return confirmation
    }
}

/// The file lane driven whole through the model: open a real file in a
/// directory the test owns, type into it, watch the dirty mark move,
/// save it and read the bytes back off disk, and stand a second model
/// over the same sealed directory to see the unsaved edits come back.
///
/// Every model here is seamed for both its state directory and its
/// credentials, so nothing touches the installed app's pages, ledger,
/// drafts or Keychain. The drafts file is always derived from the
/// seamed directory through `FormFactor.draftsFileURL(in:)` and never
/// spelled, because the core finds it by that name beside the state
/// file and a test that spelled its own would pass against a path the
/// app never writes.
@MainActor
final class FileDocumentTests: XCTestCase {
    // MARK: The fixture

    private struct Fixture {
        let state: URL
        let workspace: URL
        let defaults: UserDefaults
        let tag: String
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-files-\(UUID().uuidString)", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let suiteName = "companion-files-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            state: state, workspace: workspace, defaults: defaults,
            tag: "files-\(UUID().uuidString)"
        )
    }

    /// A model over the fixture, with scripted panels already in place.
    /// Two models built from one fixture share a credential tag, which
    /// is what makes the second one a relaunch rather than a stranger.
    @discardableResult
    private func makeModel(
        _ fixture: Fixture, panels: ScriptedFilePanels
    ) -> PageModel {
        let model = PageModel(
            formFactor: .panel,
            defaults: fixture.defaults,
            seams: .init(
                stateDirectory: fixture.state,
                client: .ephemeral(tag: fixture.tag),
                saveDebounce: 0.05
            )
        )
        model.fileCoordinator = FileCoordinator(panels: panels)
        return model
    }

    private func write(_ text: String, named name: String, in fixture: Fixture) throws -> URL {
        let url = fixture.workspace.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func type(_ text: String, at offset: Int, into id: UInt64, on model: PageModel) throws {
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: offset, text: text)]))
        model.applyOps(sheet: id, opsJSON: ops)
    }

    private func spinRunLoop(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: Open, edit, save

    func testOpeningAFileFillsItsStorageFromTheFileOnDisk() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("first line\nsecond line\n", named: "notes.txt", in: fixture)

        model.openFile(at: url)

        let file = try XCTUnwrap(model.openFiles.first)
        XCTAssertTrue(file.id.isFileID, "a file id carries the tag and no page id does")
        XCTAssertEqual(file.name, "notes.txt")
        XCTAssertFalse(file.isDirty, "a file just read from disk holds no unsaved edits")
        XCTAssertEqual(model.selectedFile, file.id, "the file the person opened is the one showing")
        XCTAssertEqual(
            model.storage(for: file.id).string, "first line\nsecond line\n",
            "the storage is built from the file's own runs")
    }

    func testTheOpenPanelsAnswerIsWhatGetsOpened() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        panels.openURL = try write("from the panel\n", named: "panel.txt", in: fixture)

        model.openFile()

        XCTAssertEqual(panels.opens, 1)
        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertEqual(model.openFiles.first?.name, "panel.txt")
    }

    func testTypingDirtiesTheFileAndSavingWritesTheBytesAndSettlesClean() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("hello\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        _ = model.storage(for: id)

        try type("well ", at: 0, into: id, on: model)

        let dirty = try XCTUnwrap(model.openFiles.first)
        XCTAssertTrue(dirty.isDirty, "the buffer holds what the file does not")
        XCTAssertTrue(
            FileHeaderState.derive(from: dirty).showsUnsavedDot,
            "the header shows the unsaved mark from the same roster row")
        XCTAssertEqual(try read(url), "hello\n", "nothing autosaves in place")

        XCTAssertTrue(model.saveFile(id))

        XCTAssertEqual(try read(url), "well hello\n", "the save wrote the buffer to the file")
        let saved = try XCTUnwrap(model.openFiles.first)
        XCTAssertFalse(saved.isDirty, "the roster was refreshed from the core after the save")
        XCTAssertFalse(FileHeaderState.derive(from: saved).showsUnsavedDot)
    }

    func testSaveAsMovesTheIdentityAndLeavesTheOriginal() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let original = try write("first\n", named: "first.txt", in: fixture)
        model.openFile(at: original)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("very ", at: 0, into: id, on: model)

        let destination = fixture.workspace.appendingPathComponent("second.txt")
        panels.destinationURL = destination
        model.saveActiveFileAs()

        XCTAssertEqual(panels.destinations, 1)
        XCTAssertEqual(try read(destination), "very first\n", "the buffer went to the new path")
        XCTAssertEqual(try read(original), "first\n", "the original was left where it was")
        let file = try XCTUnwrap(model.openFiles.first)
        XCTAssertEqual(file.name, "second.txt", "the file adopted the path it was written to")
        XCTAssertFalse(file.isDirty)
    }

    func testACancelledSaveAsPanelWritesNothing() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("untouched\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("x", at: 0, into: id, on: model)

        panels.destinationURL = nil
        model.saveActiveFileAs()

        XCTAssertEqual(try read(url), "untouched\n")
        XCTAssertTrue(model.openFiles.first?.isDirty == true, "the edits are still unsaved")
    }

    // MARK: The close review

    func testClosingADirtyFileWithSaveWritesItAndThenCloses() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("the ", at: 0, into: id, on: model)

        panels.review = .save
        model.closeActiveFile()

        XCTAssertEqual(panels.reviews, 1, "a dirty file takes the review")
        XCTAssertEqual(try read(url), "the body\n")
        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertNil(model.selectedFile, "the surface fell back to the pad")
    }

    func testClosingADirtyFileWithDiscardLeavesTheFileOnDiskAlone() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("the ", at: 0, into: id, on: model)

        panels.review = .discard
        model.closeActiveFile()

        XCTAssertEqual(panels.reviews, 1)
        XCTAssertEqual(try read(url), "body\n", "discard means the file is not written")
        XCTAssertTrue(model.openFiles.isEmpty)
    }

    func testCancellingTheReviewLeavesTheFileOpenAndStillDirty() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("the ", at: 0, into: id, on: model)

        panels.review = .cancel
        model.closeActiveFile()

        XCTAssertEqual(panels.reviews, 1)
        XCTAssertEqual(model.openFiles.count, 1, "cancel leaves everything exactly as it was")
        XCTAssertTrue(model.openFiles.first?.isDirty == true)
        XCTAssertEqual(model.selectedFile, id)
    }

    func testClosingACleanFileRaisesNoReviewAtAll() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        model.openFile(at: try write("body\n", named: "notes.txt", in: fixture))

        model.closeActiveFile()

        XCTAssertEqual(panels.reviews, 0, "there is nothing to review")
        XCTAssertTrue(model.openFiles.isEmpty)
    }

    // MARK: What else wrote the file

    func testACleanFileChangedUnderneathIsReadAgainAndSaidSo() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("before\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        _ = model.storage(for: id)
        model.notice = nil

        try Data("after\n".utf8).write(to: url)
        model.checkOpenFilesOnActivate()

        XCTAssertEqual(model.storage(for: id).string, "after\n", "a clean file is reloaded")
        XCTAssertEqual(model.openFiles.first?.conflict, FileConflict.none, "clean never conflicts")
        XCTAssertEqual(
            model.notice, PageModel.reloadedNotice(name: "notes.txt"),
            "reload without asking, and always say so afterwards")
    }

    func testADirtyFileChangedUnderneathEntersAConflictAndSaveIsRefused() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("before\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("mine ", at: 0, into: id, on: model)

        try Data("theirs\n".utf8).write(to: url)
        model.checkOpenFilesOnActivate()

        XCTAssertEqual(model.openFiles.first?.conflict, FileConflict.changed)
        model.notice = nil
        XCTAssertFalse(model.saveFile(id), "save stays refused until a resolution is chosen")
        XCTAssertEqual(model.notice, PageModel.unresolvedConflictNotice(name: "notes.txt"))
        XCTAssertEqual(try read(url), "theirs\n", "the refused save wrote nothing")
    }

    func testKeepMineClearsTheConflictAndTheNextSaveOverwrites() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("before\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("mine ", at: 0, into: id, on: model)
        try Data("theirs\n".utf8).write(to: url)
        model.checkOpenFilesOnActivate()

        model.resolveConflict(.keepMine)

        XCTAssertEqual(model.openFiles.first?.conflict, FileConflict.none)
        XCTAssertTrue(model.saveFile(id))
        XCTAssertEqual(try read(url), "mine before\n", "keep mine wins on the next save")
    }

    func testTakeTheirsAsksFirstAndThenTakesTheCopyOnDisk() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("before\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        _ = model.storage(for: id)
        try type("mine ", at: 0, into: id, on: model)
        try Data("theirs\n".utf8).write(to: url)
        model.checkOpenFilesOnActivate()

        panels.confirmation = false
        model.resolveConflict(.takeTheirs)
        XCTAssertEqual(panels.confirmations, 1)
        XCTAssertTrue(
            model.openFiles.first?.isDirty == true,
            "a refused confirmation throws nothing away")

        panels.confirmation = true
        model.resolveConflict(.takeTheirs)

        XCTAssertEqual(model.storage(for: id).string, "theirs\n")
        XCTAssertFalse(model.openFiles.first?.isDirty == true)
        XCTAssertEqual(model.openFiles.first?.conflict, FileConflict.none)
    }

    func testAFileThatWentAwayUnderADirtyBufferSaysSoAndStandsInAMissingConflict() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("before\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("mine ", at: 0, into: id, on: model)

        try FileManager.default.removeItem(at: url)
        model.notice = nil
        model.checkOpenFilesOnActivate()

        XCTAssertEqual(model.openFiles.first?.conflict, FileConflict.missing)
        XCTAssertEqual(model.notice, PageModel.missingNotice(name: "notes.txt"))
    }

    // MARK: Refusals

    func testAFileThatIsNotUtf8IsRefusedByName() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = fixture.workspace.appendingPathComponent("binary.txt")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: url)

        model.openFile(at: url)

        XCTAssertTrue(model.openFiles.isEmpty, "a refused file opens no tab")
        XCTAssertEqual(model.notice, "binary.txt is not UTF-8 text, so it was not opened.")
    }

    func testAFilePastTheLimitIsRefusedAndTheRefusalNamesTheLimit() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = fixture.workspace.appendingPathComponent("huge.txt")
        try Data(repeating: UInt8(ascii: "a"), count: 5 * 1024 * 1024).write(to: url)

        model.openFile(at: url)

        XCTAssertTrue(model.openFiles.isEmpty)
        let notice = try XCTUnwrap(model.notice)
        XCTAssertTrue(notice.hasPrefix("huge.txt is larger than "), notice)
        XCTAssertTrue(notice.contains("MiB"), "the refusal names the limit: \(notice)")
    }

    func testAFileThatIsNotThereAtAllIsRefusedByName() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()

        model.openFile(at: fixture.workspace.appendingPathComponent("nothing.txt"))

        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertEqual(model.notice, "nothing.txt could not be read, so it was not opened.")
    }

    /// The refusal wording, without a file on disk that is genuinely
    /// four megabytes of anything.
    func testTheRefusalSentencesAreDerivedFromTheCoresOwnJson() {
        XCTAssertEqual(
            PageModel.openRefusalNotice(name: "a.txt", json: #"{"error":"notUtf8"}"#),
            "a.txt is not UTF-8 text, so it was not opened.")
        XCTAssertEqual(
            PageModel.openRefusalNotice(
                name: "a.txt", json: #"{"error":"tooLarge","limit":4194304}"#),
            "a.txt is larger than 4 MiB, so it was not opened.")
        XCTAssertEqual(
            PageModel.openRefusalNotice(name: "a.txt", json: #"{"error":"io","detail":"x"}"#),
            "a.txt could not be read, so it was not opened.")
        XCTAssertEqual(
            PageModel.openRefusalNotice(name: "a.txt", json: nil),
            "a.txt could not be opened.")
    }

    // MARK: The editor's two stores

    func testTheEditorSwitchesStoresOnTheIdAndBack() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let page = try XCTUnwrap(model.selectedPageID)
        try type("this is the page\n", at: 0, into: page, on: model)
        let url = try write("this is the file\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let file = try XCTUnwrap(model.openFiles.first?.id)
        // Both edits before either storage is built, because a storage
        // is the editor's object and the editor is what mutates it: an
        // op applied with no text view mounted moves the core and
        // leaves the storage behind, which is a mismatch the model's
        // own parity assertion catches. What is under test here is
        // which store an id reaches, and building the storages after
        // the edits asks exactly that.
        try type("A ", at: 0, into: file, on: model)
        try type("B ", at: 0, into: page, on: model)

        // Page, file, page, and each storage keeps its own text. The
        // one persistent text view swaps between these two objects, so
        // a store routed by the wrong half of the tag would show one
        // document's words under the other's id.
        XCTAssertEqual(model.storage(for: page).string, "B this is the page\n")
        XCTAssertEqual(model.storage(for: file).string, "A this is the file\n")
        XCTAssertEqual(
            model.storage(for: page).string, "B this is the page\n",
            "coming back to the page finds the page, not the file it passed through")
        XCTAssertTrue(model.openFiles.first?.isDirty == true, "the file edit landed on the file")
    }

    func testUndoAndRedoOnAFileMoveTheFileAndNotThePage() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let page = try XCTUnwrap(model.selectedPageID)
        try type("page\n", at: 0, into: page, on: model)
        model.openFile(at: try write("file\n", named: "notes.txt", in: fixture))
        let file = try XCTUnwrap(model.openFiles.first?.id)
        _ = model.storage(for: file)
        try type("edited ", at: 0, into: file, on: model)

        XCTAssertTrue(model.undoEdit(sheet: file).applied)
        XCTAssertEqual(model.storage(for: file).string, "file\n", "the step came off the file")
        XCTAssertEqual(model.storage(for: page).string, "page\n", "the page never moved")
        XCTAssertFalse(model.openFiles.first?.isDirty == true, "undo made it clean again")

        XCTAssertTrue(model.redoEdit(sheet: file).applied)
        XCTAssertEqual(model.storage(for: file).string, "edited file\n")
        XCTAssertTrue(model.openFiles.first?.isDirty == true)
    }

    // MARK: Drafts across a relaunch

    func testADirtyFileComesBackWithItsDraftAndItsAge() throws {
        let fixture = try makeFixture()
        let url = try write("on disk\n", named: "notes.txt", in: fixture)
        let draftsFile = FormFactor.draftsFileURL(in: fixture.state)

        let first = makeModel(fixture, panels: ScriptedFilePanels())
        first.loadStateIfNeeded()
        first.openFile(at: url)
        let id = try XCTUnwrap(first.openFiles.first?.id)
        try type("unsaved ", at: 0, into: id, on: first)
        // The drafts write rides the state debounce, so this is the
        // real timer firing rather than a hand-driven write.
        spinRunLoop(until: { FileManager.default.fileExists(atPath: draftsFile.path) })
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: draftsFile.path),
            "the drafts file is written on the same debounce as the sealed state")

        let second = makeModel(fixture, panels: ScriptedFilePanels())
        second.loadStateIfNeeded()

        let restored = try XCTUnwrap(second.openFiles.first)
        XCTAssertEqual(restored.name, "notes.txt", "the tab came back")
        XCTAssertTrue(restored.isDirty, "and it came back with its unsaved marker")
        XCTAssertTrue(restored.restoredFromDraft)
        XCTAssertGreaterThan(
            restored.lastEditedAt, 0,
            "the header states the draft's age, so the stamp has to survive the seal")
        XCTAssertEqual(
            second.storage(for: restored.id).string, "unsaved on disk\n",
            "the unsaved edits themselves came back, not just the mark")
        XCTAssertEqual(try read(url), "on disk\n", "and nothing was written to the file")
    }

    func testACleanFileComesBackReadyToDrawWithNoReloadOwed() throws {
        let fixture = try makeFixture()
        let url = try write("just reading\n", named: "notes.txt", in: fixture)

        let first = makeModel(fixture, panels: ScriptedFilePanels())
        first.loadStateIfNeeded()
        first.openFile(at: url)
        XCTAssertTrue(first.saveState(), "force the drafts write rather than waiting")

        let second = makeModel(fixture, panels: ScriptedFilePanels())
        second.loadStateIfNeeded()

        let restored = try XCTUnwrap(second.openFiles.first)
        XCTAssertFalse(restored.isDirty)
        XCTAssertEqual(
            second.storage(for: restored.id).string, "just reading\n",
            "the restore hands back a roster that is ready to draw")
    }

    func testFilesComeBackInTheOrderTheyWereOpened() throws {
        let fixture = try makeFixture()
        let first = makeModel(fixture, panels: ScriptedFilePanels())
        first.loadStateIfNeeded()
        for name in ["a.txt", "b.txt", "c.txt"] {
            first.openFile(at: try write("\(name)\n", named: name, in: fixture))
        }
        XCTAssertTrue(first.saveState())

        let second = makeModel(fixture, panels: ScriptedFilePanels())
        second.loadStateIfNeeded()

        XCTAssertEqual(second.openFiles.map(\.name), ["a.txt", "b.txt", "c.txt"])
    }

    func testAFileThatWentAwayWhileTheAppWasClosedIsNotReopenedAndIsNamed() throws {
        let fixture = try makeFixture()
        let url = try write("here for now\n", named: "notes.txt", in: fixture)
        let first = makeModel(fixture, panels: ScriptedFilePanels())
        first.loadStateIfNeeded()
        first.openFile(at: url)
        XCTAssertTrue(first.saveState())

        try FileManager.default.removeItem(at: url)

        let second = makeModel(fixture, panels: ScriptedFilePanels())
        second.loadStateIfNeeded()

        XCTAssertTrue(second.openFiles.isEmpty, "there is no tab to open onto nothing")
        let notice = try XCTUnwrap(second.notice)
        XCTAssertTrue(notice.contains("notes.txt"), "the launch names the file: \(notice)")
    }

    func testClosingTheLastFileTakesTheDraftsFileWithIt() throws {
        let fixture = try makeFixture()
        let draftsFile = FormFactor.draftsFileURL(in: fixture.state)
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        model.openFile(at: try write("body\n", named: "notes.txt", in: fixture))
        XCTAssertTrue(model.saveState())
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftsFile.path))

        model.closeActiveFile()
        XCTAssertTrue(model.saveState())

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: draftsFile.path),
            "an empty roster leaves no file behind rather than an empty one")
    }

    /// ADR-0016 section 6's rotation, driven by the call `saveState`'s
    /// rotate leg makes.
    ///
    /// Driven through the client rather than through the leg's own
    /// predicate, because that predicate is "a tab remains and none of
    /// them holds a page", and reaching that state headlessly means
    /// waiting out an expiry. What is under test here is not when the
    /// rotation fires, which `StateLicenceTests` already pins as a
    /// pure function; it is that the drafts come through it readable,
    /// and the call is the call either way. Two rotations rather than
    /// one, so the drafts have been through two generations of the key.
    func testAKeyRotationLeavesTheDraftReadable() throws {
        let fixture = try makeFixture()
        let url = try write("on disk\n", named: "notes.txt", in: fixture)
        let stateFile = FormFactor.stateFileURL(in: fixture.state)

        let first = makeModel(fixture, panels: ScriptedFilePanels())
        first.loadStateIfNeeded()
        first.openFile(at: url)
        let id = try XCTUnwrap(first.openFiles.first?.id)
        try type("unsaved ", at: 0, into: id, on: first)
        XCTAssertTrue(first.saveState(), "the drafts reach disk before the rotation runs")

        XCTAssertTrue(first.coreClient.persistRotateAndSave(to: stateFile.path))
        try type("more ", at: 0, into: id, on: first)
        XCTAssertTrue(first.saveState())
        XCTAssertTrue(first.coreClient.persistRotateAndSave(to: stateFile.path))

        let second = makeModel(fixture, panels: ScriptedFilePanels())
        second.loadStateIfNeeded()

        let restored = try XCTUnwrap(second.openFiles.first)
        XCTAssertTrue(restored.isDirty)
        XCTAssertEqual(
            second.storage(for: restored.id).string, "more unsaved on disk\n",
            "the rotation rewrote the drafts under the new key rather than orphaning them")
    }

    /// Emptying the pad is a page lifecycle event, and a person can be
    /// holding a dirty file tab while it happens. The erase reseals
    /// the drafts under the halves it just minted rather than dropping
    /// them, so the file survives the pad going away.
    func testEmptyingThePadKeepsAnOpenFilesDraft() throws {
        let fixture = try makeFixture()
        let draftsFile = FormFactor.draftsFileURL(in: fixture.state)
        let stateFile = FormFactor.stateFileURL(in: fixture.state)
        let first = makeModel(fixture, panels: ScriptedFilePanels())
        first.loadStateIfNeeded()
        first.openFile(at: try write("on disk\n", named: "notes.txt", in: fixture))
        let id = try XCTUnwrap(first.openFiles.first?.id)
        try type("unsaved ", at: 0, into: id, on: first)
        XCTAssertTrue(first.saveState())
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftsFile.path))

        // The content erase, by the same call the emptied pad makes.
        XCTAssertTrue(first.coreClient.persistErase(at: stateFile.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: draftsFile.path),
            "a roster with a file open is resealed rather than dropped")

        let second = makeModel(fixture, panels: ScriptedFilePanels())
        second.loadStateIfNeeded()
        let restored = try XCTUnwrap(second.openFiles.first)
        XCTAssertTrue(restored.isDirty)
        XCTAssertEqual(
            second.storage(for: restored.id).string, "unsaved on disk\n",
            "and it is readable under the halves the erase minted")
    }

    /// The other half of the same branch, and the door decisions.md
    /// item 14 actually points at: the explicit discard takes the
    /// drafts unconditionally.
    func testTheExplicitDiscardAlwaysTakesTheDrafts() throws {
        let fixture = try makeFixture()
        let draftsFile = FormFactor.draftsFileURL(in: fixture.state)
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        model.openFile(at: try write("body\n", named: "notes.txt", in: fixture))
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("unsaved ", at: 0, into: id, on: model)
        XCTAssertTrue(model.saveState())
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftsFile.path))

        XCTAssertTrue(model.coreClient.draftsErase(at: draftsFile.path))

        XCTAssertFalse(FileManager.default.fileExists(atPath: draftsFile.path))
    }

    func testSaveAsOntoAnAlreadyOpenFileIsRefusedByName() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let taken = try write("taken\n", named: "taken.txt", in: fixture)
        model.openFile(at: taken)
        model.openFile(at: try write("mine\n", named: "mine.txt", in: fixture))
        XCTAssertEqual(model.openFiles.count, 2)

        panels.destinationURL = taken
        model.notice = nil
        model.saveActiveFileAs()

        XCTAssertEqual(model.notice, PageModel.pathInUseNotice(name: "taken.txt"))
        XCTAssertEqual(try read(taken), "taken\n", "nothing was written to it")
        XCTAssertEqual(model.activeFile?.name, "mine.txt", "the identity did not move")
    }

    /// Decisions.md item 14: the discard names what it will take.
    func testTheDiscardSentenceNamesTheDirtyFilesByName() {
        func file(_ name: String, dirty: Bool) -> FileSummary {
            FileSummary(
                id: CompanionClient.fileIDTag | 1, name: name, path: "/tmp/\(name)",
                isDirty: dirty, conflict: .none, lineEnding: .lf, hasBOM: false,
                lastEditedAt: 0, restoredFromDraft: false
            )
        }
        XCTAssertNil(
            PageModel.draftsAtRiskSentence(files: [file("a.txt", dirty: false)]),
            "a clean file has nothing at risk")
        XCTAssertEqual(
            PageModel.draftsAtRiskSentence(files: [file("a.txt", dirty: true)]),
            "Unsaved changes to a.txt go with it.")
        XCTAssertEqual(
            PageModel.draftsAtRiskSentence(files: [
                file("a.txt", dirty: true), file("b.md", dirty: false),
                file("c.txt", dirty: true),
            ]),
            "Unsaved changes to a.txt and c.txt go with it.")
    }

    // MARK: The roster is the authority

    func testEverySaveRefreshesTheRosterTheHeaderAndTheDotsRead() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)

        try type("the ", at: 0, into: id, on: model)
        XCTAssertEqual(
            model.openFiles, model.coreClient.fileRoster(),
            "the published roster is what the core holds, after an edit")

        XCTAssertTrue(model.saveFile(id))
        XCTAssertEqual(
            model.openFiles, model.coreClient.fileRoster(),
            "and again after a save, which is what moves the dot")
    }
}
