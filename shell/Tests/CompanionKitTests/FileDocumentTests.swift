import XCTest

@testable import CompanionKit

/// Open and save panels a test answers for.
@MainActor
final class ScriptedFilePanels: FilePanels {
    var openURL: URL?
    var destinationURL: URL?
    /// What the locate panel answers. Nil is a cancel.
    var locateURL: URL?

    private(set) var opens = 0
    private(set) var destinations = 0
    /// Each locate panel raised: the file it asked about and the
    /// directory it started in.
    private(set) var locates: [(name: String, directory: URL)] = []

    func chooseFileToOpen() -> URL? {
        opens += 1
        return openURL
    }

    func chooseDestination(suggestedName: String) -> URL? {
        destinations += 1
        return destinationURL
    }

    func chooseFileToLocate(named name: String, in directory: URL) -> URL? {
        locates.append((name, directory))
        return locateURL
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
        _ fixture: Fixture,
        panels: ScriptedFilePanels,
        fileLanguageDetection: LanguageDetectionService? = nil,
        client: CompanionClient? = nil
    ) -> PageModel {
        let model = PageModel(
            formFactor: .panel,
            defaults: fixture.defaults,
            seams: .init(
                stateDirectory: fixture.state,
                client: client ?? CompanionClient.ephemeral(tag: fixture.tag),
                saveDebounce: 0.05,
                fileLanguageDetection: fileLanguageDetection
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

    /// Wait for a detection round trip to finish, by order and never by
    /// the clock. The detector runs on `worker`, and its return hands
    /// the completion to the main queue from that same thread, so a
    /// block run on the worker after it is behind the hand over, and a
    /// main queue drain after that is behind the completion itself.
    /// The request is then gone from the service one way or the other,
    /// delivered or discarded, and the assertion says so rather than
    /// letting a wait that ran out pass for one that ended.
    private func waitForDetection(_ service: LanguageDetectionService, on worker: DispatchQueue) {
        worker.sync {}
        drainMainQueue()
        XCTAssertNil(service.currentRequest, "the detection round trip did not finish")
    }

    /// Wait for the debounced write to land, on the status the write
    /// publishes when it does (`waitUntil`). The status moves last of
    /// all in `saveState`, after the drafts file is written, so a test
    /// reading it after this reads what the write left.
    private func waitForSave(on model: PageModel) {
        waitUntil(model.$saveStatus, description: "the debounced write landed") { $0 == .saved }
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

    func testOpeningAnUnknownOrExtensionlessUtf8FileIsNotExtensionGated() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()

        model.openFile(at: try write("plain text\n", named: "no-suffix", in: fixture))
        model.openFile(at: try write("also text\n", named: "notes.unknown", in: fixture))

        XCTAssertEqual(model.openFiles.map(\.name), ["no-suffix", "notes.unknown"])
    }

    func testFileRenderingChoiceIsSessionOnlyAndDoesNotDirtyOrWriteTheFile() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("# literal source\n", named: "example.swift", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.activeFile?.id)

        XCTAssertEqual(model.fileRenderSuggestion?.mode, .source("swift"))
        model.selectFileRenderMode(.source("swift"))

        XCTAssertEqual(model.fileRenderMode(for: id), .source("swift"))
        XCTAssertNil(model.fileRenderSuggestion)
        XCTAssertFalse(try XCTUnwrap(model.activeFile).isDirty)
        XCTAssertEqual(try read(url), "# literal source\n")
        XCTAssertEqual(
            FileHeaderState.derive(from: try XCTUnwrap(model.activeFile), renderMode: model.activeFileRenderMode)
                .encodingAndFormat,
            "UTF-8 · Source (Swift)"
        )
    }

    func testExplicitRenderingChoiceOutranksLaterFilenameHints() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        model.openFile(at: try write("body\n", named: "example.swift", in: fixture))
        let id = try XCTUnwrap(model.activeFile?.id)
        model.keepFilePlainText()

        // Refreshing the roster may reconsider hints, but never replaces an
        // explicit session choice.
        model.refreshOpenFiles()
        XCTAssertEqual(model.fileRenderMode(for: id), .plainText)
        XCTAssertNil(model.fileRenderSuggestion)
    }

    func testRenderingSuggestionsRemainOwnedByEachOpenFile() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        model.openFile(at: try write("let value = 1\n", named: "first.swift", in: fixture))
        let first = try XCTUnwrap(model.activeFile?.id)
        model.openFile(at: try write("print('hello')\n", named: "second.py", in: fixture))
        let second = try XCTUnwrap(model.activeFile?.id)

        XCTAssertEqual(model.renderSuggestion(for: first)?.mode, .source("swift"))
        XCTAssertEqual(model.renderSuggestion(for: second)?.mode, .source("python"))
        model.selectFile(first)
        XCTAssertEqual(model.fileRenderSuggestion?.mode, .source("swift"))
    }

    func testDismissingOneSuggestionDoesNotDismissAnotherAndReloadOffersAgain() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let firstURL = try write("let first = 1\n", named: "first.swift", in: fixture)
        model.openFile(at: firstURL)
        let first = try XCTUnwrap(model.activeFile?.id)
        model.dismissFileRenderSuggestion()
        model.openFile(at: try write("let second = 2\n", named: "second.swift", in: fixture))
        let second = try XCTUnwrap(model.activeFile?.id)

        XCTAssertNil(model.renderSuggestion(for: first))
        XCTAssertEqual(model.renderSuggestion(for: second)?.mode, .source("swift"))

        try Data("let reloaded = 3\n".utf8).write(to: firstURL)
        model.checkOpenFilesOnActivate()
        XCTAssertEqual(model.renderSuggestion(for: first)?.mode, .source("swift"))
    }

    func testSaveAsReconsidersFilenameSuggestionWithoutOverridingExplicitMode() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        model.openFile(at: try write("let value = 1\n", named: "example.swift", in: fixture))
        let id = try XCTUnwrap(model.activeFile?.id)
        panels.destinationURL = fixture.workspace.appendingPathComponent("example.py")

        model.saveActiveFileAs()
        XCTAssertEqual(model.renderSuggestion(for: id)?.mode, .source("python"))

        model.selectFileRenderMode(.plainText, for: id)
        panels.destinationURL = fixture.workspace.appendingPathComponent("example.rb")
        model.saveActiveFileAs()
        XCTAssertEqual(model.fileRenderMode(for: id), .plainText)
        XCTAssertNil(model.renderSuggestion(for: id))
    }

    func testStaleContentDetectionCannotOfferAChangedFileSnapshot() throws {
        guard PageModel.languageDetectionFeaturesAvailable else { throw XCTSkip("detection is unavailable") }
        let fixture = try makeFixture()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let worker = DispatchQueue(label: "file-document-tests.detection-worker")
        let service = LanguageDetectionService(
            detector: { _ in
                started.signal()
                _ = release.wait(timeout: .now() + 2)
                return "swift"
            },
            workerQueue: worker
        )
        let model = makeModel(
            fixture, panels: ScriptedFilePanels(), fileLanguageDetection: service
        )
        model.languageDetectionEnabled = true
        model.loadStateIfNeeded()
        model.openFile(at: try write("unclassified content\n", named: "extensionless", in: fixture))
        let id = try XCTUnwrap(model.activeFile?.id)
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        try type("changed ", at: 0, into: id, on: model)
        release.signal()
        waitForDetection(service, on: worker)

        XCTAssertNil(model.renderSuggestion(for: id))
        XCTAssertNil(model.fileContentRenderHint(for: id))
    }

    func testSaveAsToMarkdownCancelsAnOlderContentSuggestion() throws {
        guard PageModel.languageDetectionFeaturesAvailable else { throw XCTSkip("detection is unavailable") }
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let worker = DispatchQueue(label: "file-document-tests.detection-worker")
        let service = LanguageDetectionService(
            detector: { _ in
                started.signal()
                _ = release.wait(timeout: .now() + 2)
                return "swift"
            },
            workerQueue: worker
        )
        let model = makeModel(
            fixture, panels: panels, fileLanguageDetection: service
        )
        model.languageDetectionEnabled = true
        model.loadStateIfNeeded()
        model.openFile(at: try write("let value = 1\n", named: "extensionless", in: fixture))
        let id = try XCTUnwrap(model.activeFile?.id)
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        panels.destinationURL = fixture.workspace.appendingPathComponent("notes.md")

        model.saveActiveFileAs()
        release.signal()
        waitForDetection(service, on: worker)

        XCTAssertEqual(model.fileRenderMode(for: id), .markdown)
        XCTAssertNil(model.renderSuggestion(for: id))
        XCTAssertNil(model.fileContentRenderHint(for: id))
    }

    func testConcurrentExtensionlessDetectionRetainsSuggestionsForBothFiles() throws {
        guard PageModel.languageDetectionFeaturesAvailable else { throw XCTSkip("detection is unavailable") }
        let fixture = try makeFixture()
        let service = LanguageDetectionService(detector: { data in
            let text = String(decoding: data, as: UTF8.self)
            return text.contains("let ") ? "swift" : "python"
        })
        let model = makeModel(
            fixture, panels: ScriptedFilePanels(), fileLanguageDetection: service
        )
        model.languageDetectionEnabled = true
        model.loadStateIfNeeded()
        model.openFile(at: try write("let value = 1\n", named: "first", in: fixture))
        let first = try XCTUnwrap(model.activeFile?.id)
        model.openFile(at: try write("print('hello')\n", named: "second", in: fixture))
        let second = try XCTUnwrap(model.activeFile?.id)

        waitUntil(model.$fileRenderSuggestions, description: "both files were classified") {
            $0.count == 2
        }

        XCTAssertEqual(model.renderSuggestion(for: first)?.mode, .source("swift"))
        XCTAssertEqual(model.renderSuggestion(for: second)?.mode, .source("python"))
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

    // MARK: Inline dirty close

    func testClosingADirtyFileWithSaveWritesItAndThenCloses() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("the ", at: 0, into: id, on: model)

        model.closeActiveFile()
        XCTAssertEqual(model.pendingFileClose, PendingFileClose(fileID: id, name: "notes.txt"))
        XCTAssertTrue(model.openFiles.first?.isDirty == true, "the file remains editable while pending")
        model.resolvePendingFileClose(.save)

        XCTAssertEqual(try read(url), "the body\n")
        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertNil(model.selectedFile, "the surface fell back to the pad")
    }

    /// A pending close is answered only by its own three actions or by
    /// another close gesture. ⌘S while it stands makes the file clean,
    /// which overtakes the question rather than answering it: the
    /// decision is withdrawn and the tab stays.
    func testSavingWhileADirtyCloseDecisionStandsWithdrawsTheDecisionAndKeepsTheTab() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.activeFile?.id)
        try type("the ", at: 0, into: id, on: model)

        model.closeActiveFile()
        XCTAssertEqual(model.pendingFileClose?.fileID, id)
        XCTAssertTrue(model.saveFile(id))

        XCTAssertEqual(try read(url), "the body\n")
        XCTAssertEqual(model.openFiles.map(\.id), [id], "the tab stays open")
        XCTAssertNil(model.pendingFileClose, "the question no longer applies")
        XCTAssertEqual(model.selectedFile, id)

        // A clean file closes at once on the next close gesture, as any
        // clean file does.
        XCTAssertTrue(model.closeActiveFile())
        XCTAssertTrue(model.openFiles.isEmpty)
    }

    /// Undo back to the saved text withdraws the decision and leaves
    /// Redo alive: closing the tab would have taken the redo history
    /// with it, and closing is the one step here that cannot be undone.
    func testUndoingAPendingCloseBackToSavedTextWithdrawsTheDecisionAndKeepsRedo() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.activeFile?.id)
        let mounted = model.storage(for: id)
        try type("the ", at: 0, into: id, on: model)

        model.closeActiveFile()
        XCTAssertEqual(model.pendingFileClose?.fileID, id)
        XCTAssertTrue(model.undoEdit(sheet: id).applied)

        XCTAssertEqual(try read(url), "body\n", "nothing was written")
        XCTAssertEqual(model.openFiles.map(\.id), [id], "the tab stays open")
        XCTAssertNil(model.pendingFileClose, "the question no longer applies")
        XCTAssertFalse(model.openFiles.first?.isDirty == true)

        XCTAssertTrue(model.redoEdit(sheet: id).applied, "Redo survived the withdrawn decision")
        XCTAssertEqual(mounted.string, "the body\n")
        XCTAssertTrue(model.openFiles.first?.isDirty == true, "and the file is dirty again")
    }

    /// Take theirs promises "Undo restores this copy", and a close
    /// standing over it must not break that promise by closing the tab
    /// the moment the buffer matches the disk.
    func testTakingTheirsWhileADirtyCloseDecisionStandsWithdrawsTheDecisionAndKeepsUndo() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.activeFile?.id)
        let mounted = model.storage(for: id)
        try type("mine ", at: 0, into: id, on: model)
        try Data("theirs\n".utf8).write(to: url)
        model.checkOpenFilesOnActivate()

        model.closeActiveFile()
        XCTAssertEqual(model.pendingFileClose?.fileID, id)
        model.resolveConflict(.takeTheirs)

        XCTAssertEqual(try read(url), "theirs\n")
        XCTAssertEqual(mounted.string, "theirs\n")
        XCTAssertEqual(model.openFiles.map(\.id), [id], "the tab stays open")
        XCTAssertNil(model.pendingFileClose, "the question no longer applies")
        XCTAssertEqual(model.openFiles.first?.conflict, FileConflict.none)

        XCTAssertTrue(model.undoEdit(sheet: id).applied, "Undo still restores this copy")
        XCTAssertEqual(mounted.string, "mine body\n")
    }

    func testSaveCloseFailureLeavesTheFileAndInlineDecisionStanding() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let url = try write("before\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.activeFile?.id)
        try type("mine ", at: 0, into: id, on: model)
        try Data("theirs\n".utf8).write(to: url)
        model.checkOpenFilesOnActivate()

        model.closeActiveFile()
        model.resolvePendingFileClose(.save)

        XCTAssertEqual(model.pendingFileClose?.fileID, id)
        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertEqual(model.storage(for: id).string, "mine before\n")
        XCTAssertEqual(try read(url), "theirs\n")
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

        model.closeActiveFile()
        model.resolvePendingFileClose(.discard)

        XCTAssertEqual(try read(url), "body\n", "discard means the file is not written")
        XCTAssertTrue(model.openFiles.isEmpty)
    }

    func testKeepEditingLeavesTheFileOpenAndStillDirty() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("the ", at: 0, into: id, on: model)

        model.closeActiveFile()
        model.resolvePendingFileClose(.keepEditing)

        XCTAssertNil(model.pendingFileClose)
        XCTAssertEqual(model.openFiles.count, 1, "Keep editing leaves everything exactly as it was")
        XCTAssertTrue(model.openFiles.first?.isDirty == true)
        XCTAssertEqual(model.selectedFile, id)
    }

    func testLeavingAFileClearsItsStalePendingCloseState() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        model.openFile(at: try write("body\n", named: "notes.txt", in: fixture))
        let id = try XCTUnwrap(model.activeFile?.id)
        try type("the ", at: 0, into: id, on: model)
        let page = try XCTUnwrap(model.selectedPageID)

        model.closeActiveFile()
        XCTAssertEqual(model.pendingFileClose?.fileID, id)
        model.select(page)

        XCTAssertNil(model.pendingFileClose)
        XCTAssertNil(model.selectedFile)
        XCTAssertEqual(model.openFiles.count, 1)
    }

    func testClosingACleanFilePublishesNoPendingDecision() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        model.openFile(at: try write("body\n", named: "notes.txt", in: fixture))

        model.closeActiveFile()

        XCTAssertNil(model.pendingFileClose, "there is nothing to decide")
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

    func testKeepMineOverAChangedFileReadsUnsavedWhenUndoneBackToTheOldText() throws {
        // The text the buffer returns to is the copy the disk no longer
        // holds. A header that read saved there would be untrue, and
        // nothing would ever correct it: the check answers unchanged.
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("before\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        let mounted = model.storage(for: id)
        try type("mine ", at: 0, into: id, on: model)
        try Data("theirs\n".utf8).write(to: url)
        model.checkOpenFilesOnActivate()
        model.resolveConflict(.keepMine)

        XCTAssertTrue(model.undoEdit(sheet: id).applied)

        XCTAssertEqual(mounted.string, "before\n")
        var row = try XCTUnwrap(model.openFiles.first)
        XCTAssertTrue(row.isDirty, "the disk holds the other copy")
        XCTAssertEqual(FileHeaderState.derive(from: row).saveWord, "unsaved")
        XCTAssertTrue(FileHeaderState.derive(from: row).showsUnsavedDot)
        model.checkOpenFilesOnActivate()
        row = try XCTUnwrap(model.openFiles.first)
        XCTAssertTrue(row.isDirty, "and an activation does not take the word back")
        XCTAssertEqual(row.conflict, FileConflict.none)
        XCTAssertEqual(try read(url), "theirs\n")

        // The save the consent was given for writes the old text back,
        // and only then does the header read saved.
        XCTAssertTrue(model.saveFile(id))
        XCTAssertEqual(try read(url), "before\n")
        row = try XCTUnwrap(model.openFiles.first)
        XCTAssertFalse(row.isDirty)
        XCTAssertEqual(FileHeaderState.derive(from: row).saveWord, "saved")
    }

    func testTakeTheirsDirectlyTakesTheCopyOnDiskAndCanBeUndoneAndRedone() throws {
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

        let mounted = model.storage(for: id)
        model.resolveConflict(.takeTheirs)

        XCTAssertTrue(model.storage(for: id) === mounted)
        XCTAssertEqual(mounted.string, "theirs\n")
        XCTAssertFalse(model.openFiles.first?.isDirty == true)
        XCTAssertEqual(model.openFiles.first?.conflict, FileConflict.none)
        XCTAssertTrue(model.canUndoEdit(sheet: id), "Take theirs enters the core file history")
        XCTAssertTrue(model.undoEdit(sheet: id).applied)
        XCTAssertEqual(mounted.string, "mine before\n")
        XCTAssertTrue(model.redoEdit(sheet: id).applied)
        XCTAssertEqual(mounted.string, "theirs\n")
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

        let mounted = model.storage(for: id)
        let mine = mounted.string
        try FileManager.default.removeItem(at: url)
        model.notice = nil
        model.checkOpenFilesOnActivate()

        XCTAssertEqual(model.openFiles.first?.conflict, FileConflict.missing)
        XCTAssertEqual(model.notice, PageModel.missingNotice(name: "notes.txt"))
        model.resolveConflict(.takeTheirs)
        XCTAssertEqual(mounted.string, mine, "a failed Take theirs preserves the mounted buffer")
        XCTAssertTrue(model.openFiles.first?.isDirty == true)
        XCTAssertEqual(model.openFiles.first?.conflict, FileConflict.missing)
    }

    // MARK: Refusals

    func testAFileWithAnUnsupportedEncodingIsRefusedWithConversionGuidance() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = fixture.workspace.appendingPathComponent("utf16.txt")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: url)

        model.openFile(at: url)

        XCTAssertTrue(model.openFiles.isEmpty, "a refused file opens no tab")
        XCTAssertEqual(
            model.notice,
            "utf16.txt uses an unsupported text encoding. Convert it to UTF-8, then try again."
        )
    }

    func testAnInvalidUtf8PNGIsRefusedAsUnsupportedEncoding() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = fixture.workspace.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF]).write(to: url)

        model.openFile(at: url)

        XCTAssertTrue(model.openFiles.isEmpty, "a refused file opens no tab")
        XCTAssertEqual(
            model.notice,
            "image.png uses an unsupported text encoding. Convert it to UTF-8, then try again."
        )
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

    /// The refusal wording, without files on disk that are genuinely binary
    /// or four megabytes of anything.
    func testTheRefusalSentencesAreDerivedFromTheCoresOwnJson() {
        XCTAssertEqual(
            PageModel.openRefusalNotice(name: "a.txt", json: #"{"error":"binary"}"#),
            "a.txt contains binary data and cannot be opened as text. Choose a UTF-8 text file instead."
        )
        XCTAssertEqual(
            PageModel.openRefusalNotice(name: "a.txt", json: #"{"error":"notUtf8"}"#),
            "a.txt uses an unsupported text encoding. Convert it to UTF-8, then try again."
        )
        XCTAssertEqual(
            PageModel.openRefusalNotice(
                name: "a.txt", json: #"{"error":"tooLarge","limit":4194304}"#),
            "a.txt is larger than 4 MiB, so it was not opened.")
        XCTAssertEqual(
            PageModel.openRefusalNotice(name: "a.txt", json: #"{"error":"io","detail":"x"}"#),
            "a.txt could not be read, so it was not opened.")
        XCTAssertEqual(
            PageModel.openRefusalNotice(name: "folder", json: #"{"error":"io","detail":"is a directory"}"#),
            "folder is a directory, so it was not opened.")
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
        waitForSave(on: first)
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
            "the launch hydrates every restored file before anything draws it")
    }

    func testRestoredFileReinfersSuggestionButDoesNotPersistExplicitMode() throws {
        let fixture = try makeFixture()
        let url = try write("let value = 1\n", named: "example.swift", in: fixture)
        let first = makeModel(fixture, panels: ScriptedFilePanels())
        first.loadStateIfNeeded()
        first.openFile(at: url)
        let firstID = try XCTUnwrap(first.activeFile?.id)
        first.selectFileRenderMode(.markdown, for: firstID)
        XCTAssertTrue(first.saveState())

        let second = makeModel(fixture, panels: ScriptedFilePanels())
        second.loadStateIfNeeded()
        let restored = try XCTUnwrap(second.openFiles.first)

        XCTAssertEqual(second.fileRenderMode(for: restored.id), .plainText)
        XCTAssertEqual(second.renderSuggestion(for: restored.id)?.mode, .source("swift"))
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

    /// The drafts leg has its own write, so the cancelled quit's line
    /// names the dirty files only while that write is still owed. A
    /// refusal from the content or ledger leg after the drafts landed
    /// costs the pages alone, and so does an unsavable session, whose
    /// drafts leg settled by definition.
    func testTheCancelledQuitLineNamesTheDirtyFilesOnlyWhileTheirDraftsAreUnwritten() {
        func file(_ name: String, dirty: Bool) -> FileSummary {
            FileSummary(
                id: CompanionClient.fileIDTag | 1, name: name, path: "/tmp/\(name)",
                isDirty: dirty, conflict: .none, lineEnding: .lf, hasBOM: false,
                lastEditedAt: 0, restoredFromDraft: false
            )
        }
        let pagesOnly =
            "the sealed state file was not written, so this session's pages will not survive the quit"
        XCTAssertEqual(
            PageModel.quitRefusalSentence(
                .refused, files: [file("a.txt", dirty: false)], draftsUnwritten: true),
            pagesOnly,
            "a clean file adds nothing to the loss")
        XCTAssertEqual(
            PageModel.quitRefusalSentence(
                .refused, files: [file("a.txt", dirty: true)], draftsUnwritten: false),
            pagesOnly,
            "a draft the drafts leg wrote survives a refusal from another leg")
        XCTAssertEqual(
            PageModel.quitRefusalSentence(
                .refused,
                files: [
                    file("a.txt", dirty: true), file("b.md", dirty: false),
                    file("c.txt", dirty: true),
                ],
                draftsUnwritten: true),
            "the sealed state file was not written, so this session's pages and the unsaved "
                + "changes to a.txt and c.txt will not survive the quit")
        XCTAssertEqual(
            PageModel.quitRefusalSentence(
                .unsavableWithContent, files: [file("a.txt", dirty: true)], draftsUnwritten: false),
            "nothing typed this session is on disk, so its pages will not survive the quit",
            "an unsavable session's drafts leg settled, so its drafts are on disk")
        XCTAssertNil(
            PageModel.quitRefusalSentence(
                .settled, files: [file("a.txt", dirty: true)], draftsUnwritten: true))
    }

    /// The flag the surface hands the line is the model's own drafts
    /// dirtiness: set by an edit, cleared by the drafts leg's write,
    /// so a flush that lands the drafts stops the line naming them.
    func testTheDraftsLegClearsTheDirtinessTheQuitLineReads() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let url = try write("one\n", named: "a.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        _ = model.storage(for: id)

        try type("well ", at: 0, into: id, on: model)
        XCTAssertTrue(model.draftsDirty, "an edit owes the drafts file a write")

        XCTAssertTrue(model.saveState())
        XCTAssertFalse(model.draftsDirty, "the drafts leg landed, so no draft is at stake")
        XCTAssertTrue(
            try XCTUnwrap(model.openFiles.first).isDirty,
            "the file stays dirty; only its draft is on disk")
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

    // MARK: Render mode and the bytes

    /// The render mode is session state and attributes only (D-18,
    /// D-05): it says how a file looks on screen and nothing about
    /// what the file says. A flip followed by a save leaves the bytes
    /// on disk identical, and a real write under the flipped mode
    /// carries exactly the edit and nothing the mode drew.
    func testARenderModeFlipLeavesTheFileBytesIdentical() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let original = "# heading\n\nbody\n\n```swift\nlet x = 1\n```\n"
        let url = try write(original, named: "notes.md", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.activeFile?.id)
        _ = model.storage(for: id)
        let before = model.fileRenderMode(for: id)

        model.selectFileRenderMode(.source("swift"), for: id)
        XCTAssertNotEqual(model.fileRenderMode(for: id), before, "the flip must be a flip")
        _ = model.saveFile(id)

        XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8), "the mode reached the bytes")
        XCTAssertFalse(try XCTUnwrap(model.activeFile).isDirty, "a mode flip is not an edit")

        try type("typed ", at: 0, into: id, on: model)
        XCTAssertTrue(model.saveFile(id))

        XCTAssertEqual(
            try Data(contentsOf: url), Data(("typed " + original).utf8),
            "a save under the flipped mode wrote something the mode drew")
    }

    // MARK: 7a. What a refused close does, and how often one is asked for

    /// Save closes the file itself once the write lands. The roster
    /// refresh inside the save withdraws the decision but closes
    /// nothing, so the core is asked for the close once and only once.
    /// A second ask would land on an id the core no longer holds, and
    /// file ids are not promised never to be reused.
    func testSaveAsksTheCoreToCloseTheFileExactlyOnce() throws {
        let fixture = try makeFixture()
        let client = ScriptedCloseClient(tag: fixture.tag)
        let model = makeModel(fixture, panels: ScriptedFilePanels(), client: client)
        model.loadStateIfNeeded()
        model.openFile(at: try write("a\n", named: "a.txt", in: fixture))
        let dirty = try XCTUnwrap(model.openFiles.first?.id)
        try type("x", at: 0, into: dirty, on: model)

        model.closeFile(dirty)
        XCTAssertEqual(model.pendingFileClose?.fileID, dirty)
        model.resolvePendingFileClose(.save)

        XCTAssertTrue(model.openFiles.isEmpty, "the save went through and the close followed it")
        XCTAssertNil(model.pendingFileClose, "and the decision left with the file")
        XCTAssertEqual(
            client.closeRequests, [dirty],
            "the close the Save action made itself is the only one owed")
    }

    /// A roster that reads the pending file as clean withdraws the
    /// decision and asks the core for nothing: no close is automatic.
    /// The pass still prunes the per-file side tables against the roster
    /// it published, or they outlive the files they describe.
    func testACleanFileWithAPendingCloseStaysOpenWithNoDecisionAndTheSideTablesPruned() throws {
        let fixture = try makeFixture()
        let client = ScriptedCloseClient(tag: fixture.tag)
        let model = makeModel(fixture, panels: ScriptedFilePanels(), client: client)
        model.loadStateIfNeeded()
        model.openFile(at: try write("a\n", named: "a.txt", in: fixture))
        let dirty = try XCTUnwrap(model.openFiles.first?.id)
        try type("x", at: 0, into: dirty, on: model)
        model.openFile(at: try write("# b\n", named: "b.md", in: fixture))
        let leaving = try XCTUnwrap(model.openFiles.last?.id)
        XCTAssertEqual(
            model.fileRenderModes[leaving], FileRenderMode.markdown,
            "the second file arrived with a render mode of its own")

        model.closeFile(dirty)
        XCTAssertEqual(model.pendingFileClose?.fileID, dirty)

        // The roster a successful save would publish: the file with the
        // decision on it is clean now, and the other one is gone.
        model.standOpenFiles([
            FileSummary(
                id: dirty, name: "a.txt",
                path: fixture.workspace.appendingPathComponent("a.txt").path,
                isDirty: false, conflict: .none, lineEnding: .lf, hasBOM: false,
                lastEditedAt: 0, restoredFromDraft: false
            )
        ])

        XCTAssertEqual(client.closeRequests, [], "no close was asked for")
        XCTAssertNil(model.pendingFileClose, "the decision was withdrawn, not answered")
        XCTAssertEqual(
            model.openFiles.map { $0.id }, [dirty] as [UInt64],
            "the roster published is the new one and the tab is still on it")
        XCTAssertNil(
            model.fileRenderModes[leaving],
            "the file that left took its render mode with it")
    }
}

/// The nine findings of the adversarial Swift review, each with the
/// test that would have caught it. Kept in their own class so the
/// scenarios read as the probes they are rather than as more coverage
/// of the happy path.
@MainActor
final class FileReviewFixTests: XCTestCase {
    private struct Fixture {
        let state: URL
        let workspace: URL
        let defaults: UserDefaults
        let tag: String
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-fix-\(UUID().uuidString)", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let suiteName = "companion-fix-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            state: state, workspace: workspace, defaults: defaults,
            tag: "fix-\(UUID().uuidString)"
        )
    }

    private func makeModel(_ fixture: Fixture, panels: ScriptedFilePanels) -> PageModel {
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

    private func type(_ text: String, at offset: Int, into id: UInt64, on model: PageModel) throws {
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: offset, text: text)]))
        model.applyOps(sheet: id, opsJSON: ops)
    }

    // MARK: 1. The prune keeps files

    /// The review's own probe. A refresh runs on every page gesture and
    /// on every expiry, and it used to drop the open file's storage
    /// while the one persistent text view was still laying it out.
    /// Every restate then guarded on a missing entry and did nothing,
    /// so Take theirs reported a reload the screen never got.
    func testARefreshDoesNotEvictAnOpenFilesStorage() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let url = try write("hello\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        _ = model.storage(for: id)
        XCTAssertTrue(model.pagesWithStorage.contains(id))

        // A page gesture, which is what a refresh rides in on.
        model.newPage()

        XCTAssertTrue(
            model.pagesWithStorage.contains(id),
            "a file is never in tabs, so the page prune must exempt it by tag")
    }

    func testTakeTheirsReachesTheScreenAfterARefresh() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("hello\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        // The object the one persistent text view is laying out. Held
        // by reference on purpose: asking the model for the storage
        // again after the fact would rebuild an evicted entry from the
        // core and report a screen that had been fixed by the asking.
        // What the person sees is this object.
        let mounted = model.storage(for: id)
        try type("mine ", at: 0, into: id, on: model)
        // The refresh that used to throw the storage away.
        model.newPage()
        model.selectFile(id)

        try Data("theirs\n".utf8).write(to: url)
        model.checkOpenFilesOnActivate()
        XCTAssertEqual(model.openFiles.first?.conflict, FileConflict.changed)

        model.resolveConflict(.takeTheirs)

        XCTAssertEqual(
            mounted.string, "theirs\n",
            "the notice says the file was read again, so the editor must show it")
        XCTAssertTrue(
            model.storage(for: id) === mounted,
            "and it is still the same object, restated in place rather than replaced")
    }

    // MARK: 2. A reopen restates rather than orphans

    func testReopeningTheShowingFileRestatesTheMountedStorage() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let url = try write("first\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        let mounted = model.storage(for: id)

        // The same file dropped on the card again while it is showing.
        model.openFile(at: url)

        XCTAssertEqual(model.openFiles.count, 1, "one file, not two")
        XCTAssertTrue(
            model.storage(for: id) === mounted,
            "the object the text view holds is the object the model still knows about")
        XCTAssertTrue(model.pagesWithStorage.contains(id))
    }

    // MARK: 3. The rail's chords match the chords that reach the rows

    func testTheDayChordLabelMatchesTheIndexThatSelectsIt() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        model.showsTimeUnits = true
        model.openFile(at: try write("a\n", named: "a.txt", in: fixture))
        let file = try XCTUnwrap(model.openFiles.first?.id)

        let index = TimeRailView.targetIndex(forDay: 0, openFileCount: model.openFiles.count)
        XCTAssertEqual(index, 1, "one file sits ahead of the first day")
        let targets = model.visibleTargets
        XCTAssertEqual(targets.first, SurfaceTarget.file(file), "files are drawn first")
        XCTAssertNotEqual(
            targets[index], SurfaceTarget.file(file),
            "the chord the rail prints beside today must not select the file")
        // And the label and the selection are one arithmetic: the row
        // the rail numbers is the row select(index:) lands on.
        model.select(index: index)
        XCTAssertNil(model.selectedFile, "selecting today put the file away")
    }

    func testWithNoFileOpenTheDayChordsAreExactlyWhatTheyWere() throws {
        XCTAssertEqual(TimeRailView.targetIndex(forDay: 0, openFileCount: 0), 0)
        XCTAssertEqual(TimeRailView.targetIndex(forDay: 4, openFileCount: 0), 4)
    }

    // MARK: 4. One notice for an activation that reloaded several files

    func testAnActivationThatReloadedThreeFilesPostsOneNoticeNamingAll() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        var urls: [URL] = []
        for name in ["a.txt", "b.txt", "c.txt"] {
            let url = try write("before\n", named: name, in: fixture)
            urls.append(url)
            model.openFile(at: url)
        }
        model.notice = nil

        for url in urls { try Data("after\n".utf8).write(to: url) }
        model.checkOpenFilesOnActivate()

        let notice = try XCTUnwrap(model.notice)
        for name in ["a.txt", "b.txt", "c.txt"] {
            XCTAssertTrue(notice.contains(name), "\(name) is missing from: \(notice)")
        }
    }

    func testOneReloadedFileKeepsTheSentenceItAlwaysHad() {
        XCTAssertEqual(
            PageModel.activationNotice([.reloaded("a.txt")]),
            PageModel.reloadedNotice(name: "a.txt"))
        XCTAssertEqual(
            PageModel.activationNotice([.missing("a.txt")]),
            PageModel.missingNotice(name: "a.txt"))
        XCTAssertNil(PageModel.activationNotice([]))
        let both = PageModel.activationNotice([.reloaded("a.txt"), .missing("b.txt")]) ?? ""
        XCTAssertTrue(both.contains("a.txt"), both)
        XCTAssertTrue(both.contains("b.txt"), both)
    }

    // MARK: 5. Save As onto the file's own path is a save

    func testSaveAsOntoTheFilesOwnChangedPathRaisesTheConflict() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        let url = try write("before\n", named: "notes.txt", in: fixture)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        try type("mine ", at: 0, into: id, on: model)

        // Something else writes it, and the person picks its own name
        // in the save panel, which is a save and takes a save's check.
        try Data("theirs\n".utf8).write(to: url)
        panels.destinationURL = url
        model.saveActiveFileAs()

        XCTAssertEqual(
            model.openFiles.first?.conflict, FileConflict.changed,
            "the panel is not a way around the before-save check")
        XCTAssertEqual(try String(decoding: Data(contentsOf: url), as: UTF8.self), "theirs\n",
                       "and nothing was written over the copy on disk")
    }

    // MARK: 6. A file keeps its caret and scroll

    func testTheViewStatePruneKeepsAFilesEntry() {
        let file = CompanionClient.fileIDTag | 7
        let page: UInt64 = 3
        let dead: UInt64 = 9
        let pruned = PageViewStates.pruned(
            [file: 11, page: 22, dead: 33], keeping: Set([page])
        )
        XCTAssertEqual(pruned[file], 11, "a file is never in the live page set and must survive")
        XCTAssertEqual(pruned[page], 22)
        XCTAssertNil(pruned[dead], "a dead page's caret still goes")
    }

    // MARK: 7. Keep editing restores the selection

    func testKeepEditingAnotherFileRestoresTheSelection() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        model.openFile(at: try write("a\n", named: "a.txt", in: fixture))
        model.openFile(at: try write("b\n", named: "b.txt", in: fixture))
        let dirty = try XCTUnwrap(model.openFiles.first?.id)
        try type("x", at: 0, into: dirty, on: model)
        let showing = try XCTUnwrap(model.openFiles.last?.id)
        model.selectFile(showing)

        model.closeFile(dirty)
        XCTAssertEqual(model.selectedFile, dirty, "the requested file is shown with its inline state")
        XCTAssertEqual(model.pendingFileClose?.fileID, dirty)
        model.resolvePendingFileClose(.keepEditing)

        XCTAssertEqual(model.openFiles.count, 2, "Keep editing closed nothing")
        XCTAssertEqual(
            model.selectedFile, showing,
            "and left the person looking at the file they were on")
    }

    func testKeepEditingFromAPageReturnsToThePage() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = makeModel(fixture, panels: panels)
        model.loadStateIfNeeded()
        model.openFile(at: try write("a\n", named: "a.txt", in: fixture))
        let dirty = try XCTUnwrap(model.openFiles.first?.id)
        try type("x", at: 0, into: dirty, on: model)
        let page = try XCTUnwrap(model.selectedPageID)
        model.select(page)
        XCTAssertNil(model.selectedFile)

        model.closeFile(dirty)
        XCTAssertEqual(model.selectedFile, dirty)
        model.resolvePendingFileClose(.keepEditing)

        XCTAssertNil(model.selectedFile, "the pad was showing before and is showing after")
    }

    func testKeepEditingFromTheLedgerReturnsToTheLedger() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        model.openFile(at: try write("a\n", named: "a.txt", in: fixture))
        let dirty = try XCTUnwrap(model.openFiles.first?.id)
        try type("x", at: 0, into: dirty, on: model)
        model.select(try XCTUnwrap(model.selectedPageID))
        model.showLedger()
        XCTAssertTrue(model.showingLedger)

        model.closeFile(dirty)
        XCTAssertFalse(model.showingLedger)
        model.resolvePendingFileClose(.keepEditing)

        XCTAssertTrue(model.showingLedger)
        XCTAssertNil(model.selectedFile)
    }

    // MARK: 8. The Edit menu tells the truth about a file

    func testUndoAndRedoGreyTruthfullyForAFile() throws {
        let fixture = try makeFixture()
        let model = makeModel(fixture, panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        model.openFile(at: try write("body\n", named: "notes.txt", in: fixture))
        let id = try XCTUnwrap(model.openFiles.first?.id)

        XCTAssertFalse(model.canUndoEdit(sheet: id), "a file just opened has nothing to take back")
        XCTAssertFalse(model.canRedoEdit(sheet: id))

        try type("the ", at: 0, into: id, on: model)
        XCTAssertTrue(
            model.canUndoEdit(sheet: id),
            "the page route refuses a tagged id, so this has to be the file's own")
        XCTAssertFalse(model.canRedoEdit(sheet: id))

        XCTAssertTrue(model.undoEdit(sheet: id).applied)
        XCTAssertFalse(model.canUndoEdit(sheet: id))
        XCTAssertTrue(model.canRedoEdit(sheet: id), "a step taken back is a step to put back")
    }

    // MARK: 9. No em dashes in the new comments

    func testTheFileSourcesCarryNoEmDashes() throws {
        // The prose rule is about what this lane wrote, so this reads
        // the two files the lane owns whole. The shared files carry
        // house-style dashes that predate the rule.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for name in ["Sources/CompanionKit/FileCoordinator.swift", "Sources/CompanionKit/FileSurface.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("\u{2014}"), "\(name) holds an em dash")
            XCTAssertFalse(text.contains("\u{2013}"), "\(name) holds an en dash")
        }
    }
}

/// The counterpart to the two tag exemptions: a file that leaves the
/// roster leaves nothing behind in any of the three maps.
///
/// Its own class because it needs a real editor mounted over the file,
/// which is what puts a caret and a scroll offset in the model's view
/// state table in the first place. Nothing else in the file suites
/// builds one.
@MainActor
final class FileCloseSweepTests: XCTestCase {
    private func makeFixture() throws -> (state: URL, workspace: URL, defaults: UserDefaults) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-sweep-\(UUID().uuidString)", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let suiteName = "companion-sweep-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        return (state, workspace, defaults)
    }

    func testAClosedFileLeavesNoStorageNoCaretAndNoScroll() throws {
        let fixture = try makeFixture()
        let panels = ScriptedFilePanels()
        let model = PageModel(
            formFactor: .panel,
            defaults: fixture.defaults,
            seams: .init(
                stateDirectory: fixture.state,
                client: .ephemeral(tag: "sweep-\(UUID().uuidString)"),
                saveDebounce: 0.05
            )
        )
        model.fileCoordinator = FileCoordinator(panels: panels)
        model.loadStateIfNeeded()

        let url = fixture.workspace.appendingPathComponent("notes.txt")
        try Data("a file with some lines\nand another\n".utf8).write(to: url)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)

        // A real editor over the file, built the way the factory tests
        // build one, because a caret and a scroll offset only exist
        // once something has actually been mounted and left.
        let coordinator = InkEditorView.Coordinator(model: model)
        let textView = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: id, coordinator: coordinator
        ))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = textView
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertEqual(coordinator.currentSheet, id, "the editor is mounted over the file")
        coordinator.saveViewState(textView: textView, scrollView: scroll)

        XCTAssertTrue(model.pagesWithStorage.contains(id))
        XCTAssertNotNil(model.viewStates.carets[id])
        XCTAssertNotNil(model.viewStates.scrolls[id])

        model.closeActiveFile()

        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertFalse(
            model.pagesWithStorage.contains(id), "the storage went with the file")
        XCTAssertNil(model.viewStates.carets[id], "and so did the caret")
        XCTAssertNil(model.viewStates.scrolls[id], "and the scroll offset")
    }

    /// The sweep no longer needs an editor to be standing anywhere. The
    /// place is the model's, so a file whose editor was torn down before
    /// the file went is swept all the same, where the coordinator's own
    /// maps could only be reached through a mounted editor.
    func testAClosedFileIsSweptWithNoEditorMounted() throws {
        let fixture = try makeFixture()
        let model = PageModel(
            formFactor: .panel,
            defaults: fixture.defaults,
            seams: .init(
                stateDirectory: fixture.state,
                client: .ephemeral(tag: "sweep-\(UUID().uuidString)"),
                saveDebounce: 0.05
            )
        )
        model.fileCoordinator = FileCoordinator(panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let url = fixture.workspace.appendingPathComponent("notes.txt")
        try Data("body\n".utf8).write(to: url)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        model.viewStates.saveCaret(NSRange(location: 2, length: 0), for: id)
        model.viewStates.saveScroll(ScrollAnchor(characterIndex: 2), for: id)
        XCTAssertNil(model.activeEditor, "the fixture must have no editor to go through")

        model.standOpenFiles([])

        XCTAssertFalse(model.viewStates.keys.contains(id))
    }

    /// The same sweep reached by the other door: a roster that simply
    /// stops naming the file, which is what the restore's automatic
    /// drop of a missing clean file looks like from up here.
    func testAFileThatLeavesTheRosterIsSweptWithoutAClose() throws {
        let fixture = try makeFixture()
        let model = PageModel(
            formFactor: .panel,
            defaults: fixture.defaults,
            seams: .init(
                stateDirectory: fixture.state,
                client: .ephemeral(tag: "sweep-\(UUID().uuidString)"),
                saveDebounce: 0.05
            )
        )
        model.fileCoordinator = FileCoordinator(panels: ScriptedFilePanels())
        model.loadStateIfNeeded()
        let url = fixture.workspace.appendingPathComponent("notes.txt")
        try Data("body\n".utf8).write(to: url)
        model.openFile(at: url)
        let id = try XCTUnwrap(model.openFiles.first?.id)
        _ = model.storage(for: id)
        let page = try XCTUnwrap(model.selectedPageID)
        _ = model.storage(for: page)

        model.standOpenFiles([])

        XCTAssertFalse(model.pagesWithStorage.contains(id))
        XCTAssertTrue(
            model.pagesWithStorage.contains(page),
            "the sweep is keyed on the tag, so a page is never caught by it")
    }
}
