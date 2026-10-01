import XCTest

@testable import CompanionKit

/// One ordered record shared by the scope and the client, so a test
/// can read off whether a core call happened between a start and its
/// stop rather than inferring it from two separate counts.
final class AccessJournal {
    private(set) var events: [String] = []

    func note(_ event: String) { events.append(event) }

    /// Forget what the arranging half of a test did, so the assertions
    /// read only the act.
    func clear() { events.removeAll() }
}

/// A security scope that grants nothing and counts everything.
///
/// It never calls the real pair. Outside a sandbox the real start
/// changes nothing a test can see, so there is nothing to delegate to;
/// what is under test is that the app asks, in the right order, and
/// closes exactly what it opened.
final class RecordingScope: SecurityScoping {
    let journal: AccessJournal
    /// What `startAccessing` answers. False is what a URL with no
    /// grant of its own says, and the stop is then not owed.
    var grants = true

    private(set) var starts = 0
    private(set) var stops = 0
    /// How many scopes are open right now, and the most that ever
    /// were, which is how a nested bracket shows.
    private(set) var depth = 0
    private(set) var deepest = 0
    /// A stop that had no start to answer.
    private(set) var strayStops = 0

    init(journal: AccessJournal) { self.journal = journal }

    func startAccessing(_ url: URL) -> Bool {
        starts += 1
        journal.note("start \(url.lastPathComponent)")
        guard grants else { return false }
        depth += 1
        deepest = max(deepest, depth)
        return true
    }

    func stopAccessing(_ url: URL) {
        stops += 1
        journal.note("stop \(url.lastPathComponent)")
        if depth == 0 { strayStops += 1 } else { depth -= 1 }
    }
}

/// An ephemeral client that writes every call that reaches a file on
/// disk into the journal, and can be told to refuse a save.
///
/// A subclass because the core grants whatever it is able to, so there
/// is no other way to see a call's place in the order, or to stand the
/// shell in front of a write that said no.
final class JournalingClient: CompanionClient, @unchecked Sendable {
    let journal: AccessJournal
    var refusesSaves = false

    /// The staging directory each save was handed, and whether it was
    /// standing at that moment.
    private(set) var stagingDirectories: [String?] = []
    private(set) var stagingStoodDuringTheCall: [Bool] = []
    /// The resolved path each hydration was handed.
    private(set) var hydrations: [(file: UInt64, resolvedPath: String?)] = []

    init(tag: String, journal: AccessJournal) {
        self.journal = journal
        super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
    }

    private func noteStaging(_ directory: String?) {
        stagingDirectories.append(directory)
        var isDirectory: ObjCBool = false
        let stands = directory.map {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && isDirectory.boolValue
        } ?? false
        stagingStoodDuringTheCall.append(stands)
    }

    override func openFile(path: String) -> UInt64? {
        journal.note("open")
        return super.openFile(path: path)
    }

    override func saveFile(_ file: UInt64, stagingDirectory: String?) -> Bool {
        journal.note("save")
        noteStaging(stagingDirectory)
        if refusesSaves { return false }
        return super.saveFile(file, stagingDirectory: stagingDirectory)
    }

    override func saveFile(_ file: UInt64, as path: String, stagingDirectory: String?) -> Bool {
        journal.note("saveAs")
        noteStaging(stagingDirectory)
        if refusesSaves { return false }
        return super.saveFile(file, as: path, stagingDirectory: stagingDirectory)
    }

    var checkStates: [FileCheckState] = []

    override func checkFile(_ file: UInt64) -> FileCheck? {
        journal.note("check")
        let answer = super.checkFile(file)
        if let answer { checkStates.append(answer.state) }
        return answer
    }

    override func reloadFile(_ file: UInt64) -> Bool {
        journal.note("reload")
        return super.reloadFile(file)
    }

    override func resolveFileKeepMine(_ file: UInt64) -> Bool {
        journal.note("keepMine")
        return super.resolveFileKeepMine(file)
    }

    override func resolveFileTakeTheirs(_ file: UInt64) -> Bool {
        journal.note("takeTheirs")
        return super.resolveFileTakeTheirs(file)
    }

    override func hydrateFile(_ file: UInt64, resolvedPath: String?) -> Bool {
        journal.note("hydrate")
        hydrations.append((file, resolvedPath))
        return super.hydrateFile(file, resolvedPath: resolvedPath)
    }

    override func relocateFile(_ file: UInt64, to path: String) -> Bool {
        journal.note("relocate")
        relocations.append((file, path))
        let answer = super.relocateFile(file, to: path)
        // Read at the moment of the answer, because the core keeps the
        // explanation only until the next open or relocation. After a
        // refusal it is there when the file would not open and absent
        // when the path was already held, which is the only way the
        // two can be told apart from outside.
        relocationAnswers.append((answer, answer ? nil : super.openFileErrorJSON()))
        return answer
    }

    /// The path each relocation was handed.
    private(set) var relocations: [(file: UInt64, path: String)] = []
    /// What the core answered each relocation, and for a refusal the
    /// open error it left, or nil when it left none.
    private(set) var relocationAnswers: [(accepted: Bool, openError: String?)] = []

    override func setFileBookmark(_ file: UInt64, base64: String) -> Bool {
        journal.note("bookmark")
        return super.setFileBookmark(file, base64: base64)
    }

    /// A last word on each roster row, for the one state the core
    /// reaches only through a draft too large to build in a test: a
    /// held record that still reads dirty. The core's own suite shows
    /// it produces that row; this restates it here.
    var restatesRow: ((FileSummary) -> FileSummary)?

    override func fileRoster() -> [FileSummary] {
        let rows = super.fileRoster()
        guard let restatesRow else { return rows }
        return rows.map(restatesRow)
    }
}

/// The sandbox's half of the file lane: every call that reaches a file
/// the person chose happens inside a security scope that is opened
/// once and closed once, a save stages where the shell says and leaves
/// nothing behind, the bookmark is made again after every write, and a
/// relaunch hydrates each file inside its own scope.
///
/// None of this runs under a sandbox, and none of it claims to. What
/// is asserted is the order and the balance, read off a journal the
/// scope seam and the client share, and the parts of the behaviour an
/// unsandboxed process does exhibit: real temp files, real bookmarks,
/// a file really moved while the app was away.
///
/// Every model is seamed for its state directory and its credentials,
/// as in `FileDocumentTests`.
@MainActor
final class FileAccessTests: XCTestCase {
    // MARK: The fixture

    private struct Fixture {
        let state: URL
        let workspace: URL
        let defaults: UserDefaults
        let tag: String
    }

    /// One launch: the model, and the three things a test reads.
    private struct Launch {
        let model: PageModel
        let client: JournalingClient
        let scope: RecordingScope
        let journal: AccessJournal
        let panels: ScriptedFilePanels
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-access-\(UUID().uuidString)", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let suiteName = "companion-access-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            state: state, workspace: workspace, defaults: defaults,
            tag: "access-\(UUID().uuidString)"
        )
    }

    /// A model over the fixture with the recording scope and client in
    /// place before anything is loaded. Two launches from one fixture
    /// share a credential tag, which is what makes the second a
    /// relaunch. `prepare` runs on the coordinator before the restore,
    /// for a test that needs a seam answering differently by then.
    private func launch(
        _ fixture: Fixture, load: Bool = true,
        prepare: (FileCoordinator) -> Void = { _ in }
    ) -> Launch {
        let journal = AccessJournal()
        let client = JournalingClient(tag: fixture.tag, journal: journal)
        let scope = RecordingScope(journal: journal)
        let panels = ScriptedFilePanels()
        let model = PageModel(
            formFactor: .panel,
            defaults: fixture.defaults,
            seams: .init(
                stateDirectory: fixture.state,
                client: client,
                saveDebounce: 0.05
            )
        )
        let coordinator = FileCoordinator(panels: panels, scope: scope)
        prepare(coordinator)
        model.fileCoordinator = coordinator
        if load { model.loadStateIfNeeded() }
        return Launch(model: model, client: client, scope: scope, journal: journal, panels: panels)
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

    /// Every scope that was opened was closed, and nothing was closed
    /// that had not been opened.
    private func assertBalanced(
        _ scope: RecordingScope, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(scope.starts, scope.stops, "a start went unanswered", file: file, line: line)
        XCTAssertEqual(scope.depth, 0, "a scope is still open", file: file, line: line)
        XCTAssertEqual(scope.strayStops, 0, "a stop had no start", file: file, line: line)
    }

    /// A file open in a fresh launch, with the journal cleared so the
    /// test reads only what it does next.
    private func openedFile(
        _ text: String = "body\n", named name: String = "notes.txt", in fixture: Fixture
    ) throws -> (launch: Launch, url: URL, id: UInt64) {
        let url = try write(text, named: name, in: fixture)
        let launched = launch(fixture)
        launched.model.openFile(at: url)
        let id = try XCTUnwrap(launched.model.openFiles.first(where: { $0.name == name })?.id)
        assertBalanced(launched.scope)
        launched.journal.clear()
        return (launched, url, id)
    }

    // MARK: The coordinator's brackets

    func testThePanelBracketStopsExactlyWhatItStartedAndRunsTheBodyInside() {
        let journal = AccessJournal()
        let scope = RecordingScope(journal: journal)
        let coordinator = FileCoordinator(panels: ScriptedFilePanels(), scope: scope)
        let url = URL(fileURLWithPath: "/nowhere/notes.txt")

        let answer = coordinator.withAccess(to: url) { () -> Int in
            journal.note("body")
            return 7
        }

        XCTAssertEqual(answer, 7, "the bracket hands back what the body returned")
        XCTAssertEqual(journal.events, ["start notes.txt", "body", "stop notes.txt"])
        assertBalanced(scope)
    }

    func testAStartThatAnswersFalseStillRunsTheBodyAndOwesNoStop() {
        let journal = AccessJournal()
        let scope = RecordingScope(journal: journal)
        scope.grants = false
        let coordinator = FileCoordinator(panels: ScriptedFilePanels(), scope: scope)

        coordinator.withAccess(to: URL(fileURLWithPath: "/nowhere/notes.txt")) {
            journal.note("body")
        }

        XCTAssertEqual(
            journal.events, ["start notes.txt", "body"],
            "a panel's URL usually answers false, and the body runs regardless")
        XCTAssertEqual(scope.stops, 0, "a stop is owed only for a start that answered true")
    }

    func testABookmarkBracketResolvesStartsRunsAndStops() throws {
        let fixture = try makeFixture()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        let journal = AccessJournal()
        let scope = RecordingScope(journal: journal)
        let coordinator = FileCoordinator(panels: ScriptedFilePanels(), scope: scope)
        let bookmark = try coordinator.bookmark(for: url)

        let resolved = coordinator.withAccess(toBookmark: bookmark) { access -> String in
            journal.note("body")
            XCTAssertTrue(access.isScoped)
            return access.url.path
        }

        XCTAssertTrue(PageModel.samePath(try XCTUnwrap(resolved), url.path))
        XCTAssertEqual(journal.events, ["start notes.txt", "body", "stop notes.txt"])
        assertBalanced(scope)
    }

    func testAPlainBookmarkFromBeforeTheScopedOnesRunsTheBodyWithNoScope() throws {
        let fixture = try makeFixture()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        let journal = AccessJournal()
        let scope = RecordingScope(journal: journal)
        let coordinator = FileCoordinator(panels: ScriptedFilePanels(), scope: scope)
        let plain = try url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

        let resolved = coordinator.withAccess(toBookmark: plain) { access -> String in
            XCTAssertFalse(access.isScoped, "the body is told no scope was opened")
            return access.url.path
        }

        XCTAssertTrue(PageModel.samePath(try XCTUnwrap(resolved), url.path))
        XCTAssertEqual(scope.starts, 0, "there is no scope to open on a plain bookmark")
        XCTAssertEqual(scope.stops, 0)
    }

    func testABookmarkThatResolvesToNothingRunsNoBodyAndOpensNoScope() {
        let scope = RecordingScope(journal: AccessJournal())
        let coordinator = FileCoordinator(panels: ScriptedFilePanels(), scope: scope)

        let ran: Bool? = coordinator.withAccess(toBookmark: Data("not a bookmark".utf8)) { _ in true }

        XCTAssertNil(ran, "nil is how the caller learns to fall back to the recorded path")
        XCTAssertEqual(scope.starts, 0)
    }

    func testTheStagingDirectoryStandsForTheBodyAndIsGoneAfterwards() throws {
        let fixture = try makeFixture()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        let coordinator = FileCoordinator(panels: ScriptedFilePanels())

        let staged: URL? = coordinator.withStagingDirectory(for: url) { directory in
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: directory?.path ?? "", isDirectory: &isDirectory)
                    && isDirectory.boolValue,
                "the directory is made before the body runs")
            return directory
        }

        let directory = try XCTUnwrap(staged, "this volume has an item replacement directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAStagingDirectoryCanBeHadForASaveAsTargetThatDoesNotExistYet() throws {
        let fixture = try makeFixture()
        let target = fixture.workspace.appendingPathComponent("not-yet.txt")

        let directory = try XCTUnwrap(FileCoordinator.itemReplacementDirectory(for: target))
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: Open

    func testAnOpenReadsAndBookmarksInsideOneBracket() throws {
        let fixture = try makeFixture()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        let launched = launch(fixture)
        launched.journal.clear()

        launched.model.openFile(at: url)

        XCTAssertEqual(
            launched.journal.events,
            ["start notes.txt", "open", "bookmark", "stop notes.txt"],
            "the read and the bookmark are both inside, and the bookmark is made before the stop")
        assertBalanced(launched.scope)
        let id = try XCTUnwrap(launched.model.openFiles.first?.id)
        XCTAssertFalse(
            try XCTUnwrap(launched.client.fileBookmarkBase64(id)).isEmpty,
            "the core carries the bookmark from here on")
    }

    func testARefusedOpenStillClosesItsBracket() throws {
        let fixture = try makeFixture()
        let launched = launch(fixture)
        launched.journal.clear()

        launched.model.openFile(at: fixture.workspace.appendingPathComponent("absent.txt"))

        XCTAssertEqual(launched.journal.events, ["start absent.txt", "open", "stop absent.txt"])
        assertBalanced(launched.scope)
        XCTAssertTrue(launched.model.openFiles.isEmpty)
    }

    func testABookmarkThatCannotBeMadeAtOpenIsSaidInOneSentenceAndTheFileStaysOpen() throws {
        let fixture = try makeFixture()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        let launched = launch(fixture) { coordinator in
            coordinator.makeBookmark = { _ in throw CocoaError(.fileReadUnknown) }
        }

        launched.model.openFile(at: url)

        XCTAssertEqual(launched.model.openFiles.map(\.name), ["notes.txt"], "the open itself went through")
        XCTAssertEqual(
            launched.model.notice, PageModel.bookmarkFailureNotice(name: "notes.txt"))
        assertBalanced(launched.scope)
    }

    // MARK: Save

    func testASaveBracketsTheCheckTheWriteAndTheBookmarkOnce() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)
        launched.journal.clear()

        XCTAssertTrue(launched.model.saveFile(id))

        XCTAssertEqual(
            launched.journal.events,
            ["start notes.txt", "check", "save", "bookmark", "stop notes.txt"],
            "one bracket holds the check, the write and the fresh bookmark")
        assertBalanced(launched.scope)
        XCTAssertEqual(launched.scope.deepest, 1)
        XCTAssertEqual(try read(url), "mine body\n")
    }

    func testASaveStagesInADirectoryThatIsRemovedAfterTheWriteLands() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)

        XCTAssertTrue(launched.model.saveFile(id))

        let staging = try XCTUnwrap(
            launched.client.stagingDirectories.last ?? nil,
            "every save is handed a staging directory when one can be had")
        XCTAssertEqual(launched.client.stagingStoodDuringTheCall, [true])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staging),
            "the shell made the directory, so the shell removes it")
        XCTAssertNotEqual(
            URL(fileURLWithPath: staging).resolvingSymlinksInPath().path,
            fixture.workspace.resolvingSymlinksInPath().path,
            "the temp file is not made beside the target")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path),
            ["notes.txt"], "and nothing is left beside the target either")
        XCTAssertEqual(try read(url), "mine body\n")
    }

    func testARefusedSaveStillRemovesItsStagingDirectoryAndClosesItsBracket() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)
        launched.client.refusesSaves = true
        launched.journal.clear()

        XCTAssertFalse(launched.model.saveFile(id))

        XCTAssertEqual(
            launched.journal.events, ["start notes.txt", "check", "save", "stop notes.txt"],
            "no bookmark is made for a write that did not land")
        assertBalanced(launched.scope)
        let staging = try XCTUnwrap(launched.client.stagingDirectories.last ?? nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging))
        XCTAssertEqual(
            launched.model.notice, PageModel.writeRefusalNotice(name: "notes.txt"),
            "a refused write is said")
        XCTAssertEqual(try read(url), "body\n")
        XCTAssertEqual(launched.model.openFiles.first?.isDirty, true, "and the edits are still held")
    }

    func testAStagedWriteTheCoreItselfRefusesLeavesNoTempFileAndNoDirectory() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)
        // A directory where the file was cannot be renamed onto, so
        // the core's own staged write fails at its last step, which is
        // the failure that would leave a temp file if anything did.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: url.appendingPathComponent("occupant"))
        XCTAssertTrue(launched.client.resolveFileKeepMine(id), "consent to write over what is there")

        _ = launched.model.saveFile(id)

        assertBalanced(launched.scope)
        for staging in launched.client.stagingDirectories.compactMap({ $0 }) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging))
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path),
            ["notes.txt"], "nothing was left beside the target")
    }

    func testWithNoStagingDirectoryTheSaveIsRefusedWithoutCallingTheCore() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        launched.model.fileCoordinator.makeStagingDirectory = { _ in nil }
        try type("mine ", at: 0, into: id, on: launched.model)
        launched.journal.clear()

        XCTAssertFalse(launched.model.saveFile(id))

        XCTAssertTrue(launched.client.stagingDirectories.isEmpty)
        XCTAssertEqual(launched.journal.events, ["start notes.txt", "check", "stop notes.txt"])
        assertBalanced(launched.scope)
        XCTAssertEqual(launched.model.notice, PageModel.writeRefusalNotice(name: "notes.txt"))
        XCTAssertEqual(try read(url), "body\n")
        XCTAssertEqual(launched.model.openFiles.first?.isDirty, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path),
                       ["notes.txt"])
    }

    func testWithNoStagingDirectorySaveAsLeavesTheDestinationAndIdentityAlone() throws {
        for exists in [false, true] {
            let fixture = try makeFixture()
            let (launched, url, id) = try openedFile(in: fixture)
            try type("mine ", at: 0, into: id, on: launched.model)
            let target = fixture.workspace.appendingPathComponent("copy.txt")
            if exists { try Data("destination\n".utf8).write(to: target) }
            let originalPath = try XCTUnwrap(launched.model.openFiles.first(where: { $0.id == id })?.path)
            let bookmark = launched.client.fileBookmarkBase64(id)
            launched.panels.destinationURL = target
            launched.model.fileCoordinator.makeStagingDirectory = { _ in nil }
            launched.journal.clear()

            launched.model.saveActiveFileAs()

            XCTAssertTrue(launched.client.stagingDirectories.isEmpty)
            XCTAssertEqual(launched.journal.events, ["start copy.txt", "stop copy.txt"])
            assertBalanced(launched.scope)
            XCTAssertEqual(launched.model.notice, PageModel.writeRefusalNotice(name: "copy.txt"))
            XCTAssertEqual(launched.model.openFiles.first(where: { $0.id == id })?.path, originalPath)
            XCTAssertEqual(launched.model.openFiles.first?.isDirty, true)
            XCTAssertEqual(launched.client.fileBookmarkBase64(id), bookmark)
            XCTAssertEqual(try read(url), "body\n")
            if exists {
                XCTAssertEqual(try read(target), "destination\n")
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path).sorted(),
                           exists ? ["copy.txt", "notes.txt"] : ["notes.txt"])
        }
    }

    func testTheBookmarkMadeAfterASaveStillFindsTheFileOnceItMoves() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)
        XCTAssertTrue(launched.model.saveFile(id))
        XCTAssertTrue(launched.model.saveState(), "seal the roster with the bookmark the save made")

        // The save put a new file at the path. Moving that file is
        // what a bookmark taken before the save cannot follow.
        let elsewhere = fixture.workspace.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let moved = elsewhere.appendingPathComponent("notes.txt")
        try FileManager.default.moveItem(at: url, to: moved)

        let second = launch(fixture)

        let restored = try XCTUnwrap(
            second.model.openFiles.first, "the file was found where it is now")
        XCTAssertTrue(PageModel.samePath(restored.path, moved.path))
        XCTAssertEqual(second.model.storage(for: restored.id).string, "mine body\n")
    }

    func testABookmarkThatCannotBeMadeAfterASaveIsSaidAndTheSaveStands() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)
        launched.model.fileCoordinator.makeBookmark = { _ in throw CocoaError(.fileReadUnknown) }

        XCTAssertTrue(launched.model.saveFile(id), "the write landed, which is what a save answers for")

        XCTAssertEqual(try read(url), "mine body\n")
        XCTAssertEqual(
            launched.model.notice, PageModel.bookmarkFailureNotice(name: "notes.txt"))
        assertBalanced(launched.scope)
    }

    // MARK: Save As

    func testSaveAsWritesAndBookmarksInsideThePanelBracket() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)
        let target = fixture.workspace.appendingPathComponent("copy.txt")
        launched.panels.destinationURL = target
        launched.journal.clear()

        launched.model.saveActiveFileAs()

        XCTAssertEqual(
            launched.journal.events,
            ["start copy.txt", "saveAs", "bookmark", "stop copy.txt"],
            "the write and the new bookmark are inside the bracket on the panel's URL")
        assertBalanced(launched.scope)
        XCTAssertEqual(try read(target), "mine body\n")
        XCTAssertEqual(try read(url), "body\n", "the original is left alone")
        XCTAssertEqual(launched.client.stagingStoodDuringTheCall, [true])
        let staging = try XCTUnwrap(launched.client.stagingDirectories.last ?? nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path).sorted(),
            ["copy.txt", "notes.txt"])
    }

    func testTheBookmarkFollowsASaveAsToTheNewFile() throws {
        let fixture = try makeFixture()
        let (launched, _, id) = try openedFile(in: fixture)
        let target = fixture.workspace.appendingPathComponent("copy.txt")
        launched.panels.destinationURL = target

        launched.model.saveActiveFileAs()

        let base64 = try XCTUnwrap(launched.client.fileBookmarkBase64(id))
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        let resolved = launched.model.fileCoordinator.withAccess(toBookmark: data) { $0.url.path }
        XCTAssertTrue(PageModel.samePath(try XCTUnwrap(resolved), target.path))
    }

    func testARefusedSaveAsClosesItsBracketAndRemovesItsStagingDirectory() throws {
        let fixture = try makeFixture()
        let (launched, _, _) = try openedFile(in: fixture)
        let target = fixture.workspace.appendingPathComponent("copy.txt")
        launched.panels.destinationURL = target
        launched.client.refusesSaves = true
        launched.journal.clear()

        launched.model.saveActiveFileAs()

        XCTAssertEqual(launched.journal.events, ["start copy.txt", "saveAs", "stop copy.txt"])
        assertBalanced(launched.scope)
        let staging = try XCTUnwrap(launched.client.stagingDirectories.last ?? nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging))
        XCTAssertEqual(launched.model.notice, PageModel.writeRefusalNotice(name: "copy.txt"))
        XCTAssertEqual(launched.model.activeFile?.name, "notes.txt", "the identity did not move")
    }

    func testSaveAsOntoTheFilesOwnNameNestsTheSaveInsideThePanelBracketAndBothClose() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)
        launched.panels.destinationURL = url
        launched.journal.clear()

        launched.model.saveActiveFileAs()

        XCTAssertEqual(
            launched.journal.events,
            [
                "start notes.txt", "start notes.txt", "check", "save", "bookmark",
                "stop notes.txt", "stop notes.txt",
            ])
        XCTAssertEqual(launched.scope.deepest, 2, "the file's own bracket opened inside the panel's")
        assertBalanced(launched.scope)
        XCTAssertEqual(try read(url), "mine body\n")
    }

    // MARK: Check, reload, conflict

    func testAnActivationChecksEachFileInsideItsOwnBracket() throws {
        let fixture = try makeFixture()
        let a = try write("a\n", named: "a.txt", in: fixture)
        let b = try write("b\n", named: "b.txt", in: fixture)
        let launched = launch(fixture)
        launched.model.openFile(at: a)
        launched.model.openFile(at: b)
        launched.journal.clear()

        launched.model.checkOpenFilesOnActivate()

        XCTAssertEqual(
            launched.journal.events,
            ["start a.txt", "check", "stop a.txt", "start b.txt", "check", "stop b.txt"])
        assertBalanced(launched.scope)
        XCTAssertEqual(launched.scope.deepest, 1, "one file's scope is closed before the next opens")
    }

    func testACleanFileChangedUnderneathIsReloadedInsideTheSameBracketAsItsCheck() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try Data("theirs, and longer\n".utf8).write(to: url)

        launched.model.checkOpenFilesOnActivate()

        XCTAssertEqual(
            launched.journal.events, ["start notes.txt", "check", "reload", "bookmark", "stop notes.txt"])
        assertBalanced(launched.scope)
        XCTAssertEqual(launched.model.storage(for: id).string, "theirs, and longer\n")
    }

    func testKeepMineAndTakeTheirsEachRunInsideABracket() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)
        try Data("theirs, and longer\n".utf8).write(to: url)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.model.openFiles.first?.conflict, .changed)
        launched.model.selectFile(id)
        launched.journal.clear()

        launched.model.resolveConflict(.takeTheirs)

        XCTAssertEqual(launched.journal.events, ["start notes.txt", "takeTheirs", "stop notes.txt"])
        assertBalanced(launched.scope)
        XCTAssertEqual(launched.model.storage(for: id).string, "theirs, and longer\n")

        try type("again ", at: 0, into: id, on: launched.model)
        try Data("theirs once more, longer still\n".utf8).write(to: url)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.model.openFiles.first?.conflict, .changed)
        launched.journal.clear()

        launched.model.resolveConflict(.keepMine)

        XCTAssertEqual(launched.journal.events, ["start notes.txt", "keepMine", "stop notes.txt"])
        assertBalanced(launched.scope)
        XCTAssertEqual(launched.model.openFiles.first?.conflict, FileConflict.none)
    }

    func testAFileWithNoBookmarkRunsItsCallsWithNoScopeAtAll() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        XCTAssertTrue(launched.client.setFileBookmark(id, base64: ""))
        launched.model.fileCoordinator.makeBookmark = { _ in throw CocoaError(.fileReadUnknown) }
        try type("mine ", at: 0, into: id, on: launched.model)
        launched.journal.clear()

        XCTAssertTrue(launched.model.saveFile(id))

        XCTAssertEqual(
            launched.journal.events, ["check", "save"],
            "the body runs unbracketed, which is all a file in the app's own container needs")
        XCTAssertEqual(try read(url), "mine body\n")
    }

    // MARK: Restore

    func testARestoreHydratesEachFileInsideItsOwnScopeWithItsResolvedPath() throws {
        let fixture = try makeFixture()
        let a = try write("a\n", named: "a.txt", in: fixture)
        let b = try write("b\n", named: "b.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: a)
        first.model.openFile(at: b)
        XCTAssertTrue(first.model.saveState())

        let second = launch(fixture)

        XCTAssertEqual(
            second.journal.events,
            ["start a.txt", "hydrate", "stop a.txt", "start b.txt", "hydrate", "stop b.txt"],
            "each file is read inside its own scope, and one closes before the next opens")
        assertBalanced(second.scope)
        XCTAssertEqual(second.client.hydrations.count, 2)
        for (hydration, url) in zip(second.client.hydrations, [a, b]) {
            XCTAssertTrue(
                PageModel.samePath(try XCTUnwrap(hydration.resolvedPath), url.path),
                "the core is handed where the bookmark resolved to")
        }
        XCTAssertEqual(second.model.openFiles.map(\.name), ["a.txt", "b.txt"])
        XCTAssertFalse(
            second.model.openFiles.contains(where: \.pendingHydration),
            "no row is published before it is hydrated")
        let ids = second.model.openFiles.map(\.id)
        XCTAssertEqual(second.model.storage(for: ids[0]).string, "a\n")
        XCTAssertEqual(second.model.storage(for: ids[1]).string, "b\n")
    }

    func testAFileMovedWhileTheAppWasAwayIsRestoredWhereItIsNow() throws {
        let fixture = try makeFixture()
        let url = try write("travels\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        XCTAssertTrue(first.model.saveState())

        let elsewhere = fixture.workspace.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let moved = elsewhere.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: url, to: moved)

        let second = launch(fixture)

        let restored = try XCTUnwrap(second.model.openFiles.first, "the file was not dropped as missing")
        XCTAssertTrue(PageModel.samePath(restored.path, moved.path), "the core was rebound: \(restored.path)")
        XCTAssertEqual(restored.name, "renamed.txt")
        XCTAssertEqual(second.model.storage(for: restored.id).string, "travels\n")
        XCTAssertTrue(
            PageModel.samePath(try XCTUnwrap(second.client.hydrations.first?.resolvedPath), moved.path))
        XCTAssertEqual(
            second.journal.events,
            ["start renamed.txt", "hydrate", "bookmark", "stop renamed.txt"],
            "and the bookmark was made again, inside the scope, for where the file is now")
        assertBalanced(second.scope)
        XCTAssertNil(second.model.notice, "a move within one volume is not a change to report")
    }

    func testADirtyFileMovedWhileTheAppWasAwayKeepsItsDraftAtTheNewPath() throws {
        let fixture = try makeFixture()
        let url = try write("on disk\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        let id = try XCTUnwrap(first.model.openFiles.first?.id)
        try type("unsaved ", at: 0, into: id, on: first.model)
        XCTAssertTrue(first.model.saveState())

        let moved = fixture.workspace.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: url, to: moved)

        let second = launch(fixture)

        let restored = try XCTUnwrap(second.model.openFiles.first)
        XCTAssertTrue(PageModel.samePath(restored.path, moved.path))
        XCTAssertTrue(restored.isDirty)
        XCTAssertEqual(restored.conflict, FileConflict.none, "the file it was drafted against is the file found")
        XCTAssertEqual(second.model.storage(for: restored.id).string, "unsaved on disk\n")
        XCTAssertEqual(try read(moved), "on disk\n", "nothing was written")
    }

    func testARecordWithAPlainBookmarkStillRestoresAndIsGivenAScopedOne() throws {
        let fixture = try makeFixture()
        let url = try write("legacy\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        let id = try XCTUnwrap(first.model.openFiles.first?.id)
        // What every record written before the scoped bookmarks holds.
        let plain = try url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        XCTAssertTrue(first.client.setFileBookmark(id, base64: plain.base64EncodedString()))
        XCTAssertTrue(first.model.saveState())

        let second = launch(fixture)

        let restored = try XCTUnwrap(second.model.openFiles.first, "a legacy record still restores")
        XCTAssertEqual(second.model.storage(for: restored.id).string, "legacy\n")
        XCTAssertEqual(
            second.journal.events, ["hydrate", "bookmark"],
            "no scope is opened on a plain bookmark, and it is replaced once the file has been read")
        XCTAssertEqual(second.scope.starts, 0)
        XCTAssertTrue(
            PageModel.samePath(try XCTUnwrap(second.client.hydrations.first?.resolvedPath), url.path))

        // The replacement is a scoped one: the next bracket opens a scope.
        second.journal.clear()
        second.model.checkOpenFilesOnActivate()
        XCTAssertEqual(second.journal.events, ["start notes.txt", "check", "stop notes.txt"])
    }

    func testARecordWithNoBookmarkIsHydratedAtItsRecordedPathWithNoScope() throws {
        let fixture = try makeFixture()
        let url = try write("recorded\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        let id = try XCTUnwrap(first.model.openFiles.first?.id)
        XCTAssertTrue(first.client.setFileBookmark(id, base64: ""))
        XCTAssertTrue(first.model.saveState())

        let second = launch(fixture)

        XCTAssertEqual(second.journal.events, ["hydrate"])
        XCTAssertEqual(second.client.hydrations.count, 1)
        XCTAssertNil(second.client.hydrations[0].resolvedPath, "nil reads the path on record")
        XCTAssertEqual(second.scope.starts, 0)
        let restored = try XCTUnwrap(second.model.openFiles.first)
        XCTAssertEqual(second.model.storage(for: restored.id).string, "recorded\n")
    }

    func testABookmarkThatNoLongerResolvesFallsBackToTheRecordedPath() throws {
        let fixture = try makeFixture()
        let url = try write("recorded\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        let id = try XCTUnwrap(first.model.openFiles.first?.id)
        XCTAssertTrue(
            first.client.setFileBookmark(id, base64: Data("not a bookmark".utf8).base64EncodedString()))
        XCTAssertTrue(first.model.saveState())

        let second = launch(fixture)

        XCTAssertEqual(second.journal.events, ["hydrate"])
        XCTAssertNil(second.client.hydrations.first?.resolvedPath)
        XCTAssertEqual(second.model.openFiles.map(\.name), ["notes.txt"])
    }

    func testOneFileThatWillNotBeReadLeavesTheOthersRestored() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode 000 file, so there is nothing to refuse")
        let fixture = try makeFixture()
        let first = launch(fixture)
        var urls: [URL] = []
        for name in ["a.txt", "b.txt", "c.txt"] {
            let url = try write("\(name)\n", named: name, in: fixture)
            urls.append(url)
            first.model.openFile(at: url)
        }
        XCTAssertTrue(first.model.saveState())

        // The nearest thing an unsandboxed process has to a read the
        // sandbox refuses.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: urls[1].path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: urls[1].path)
        }

        let second = launch(fixture)

        XCTAssertEqual(
            second.model.openFiles.map(\.name), ["a.txt", "b.txt", "c.txt"],
            "the file that would not be read is held, and the ones either side of it are restored")
        let ids = second.model.openFiles.map(\.id)
        XCTAssertEqual(second.model.storage(for: ids[0]).string, "a.txt\n")
        XCTAssertEqual(second.model.storage(for: ids[2]).string, "c.txt\n")
        XCTAssertEqual(second.client.hydrations.count, 3, "each was tried, in its own bracket")
        assertBalanced(second.scope)
        XCTAssertEqual(second.scope.deepest, 1)
        XCTAssertNil(second.model.notice, "nothing was dropped, so the launch has nothing to name")
    }

    func testADirtyFileThatWillNotBeReadKeepsItsDraftInAConflict() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode 000 file, so there is nothing to refuse")
        let fixture = try makeFixture()
        let url = try write("on disk\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        let id = try XCTUnwrap(first.model.openFiles.first?.id)
        try type("unsaved ", at: 0, into: id, on: first.model)
        XCTAssertTrue(first.model.saveState())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        let second = launch(fixture)

        let restored = try XCTUnwrap(
            second.model.openFiles.first, "unsaved work is never dropped for want of a read")
        XCTAssertTrue(restored.isDirty)
        XCTAssertEqual(restored.conflict, .changed)
        XCTAssertEqual(second.model.storage(for: restored.id).string, "unsaved on disk\n")
        assertBalanced(second.scope)
        // The draft is settled, so the row is not held, and it says
        // why the copy on disk is not on offer.
        XCTAssertFalse(restored.pendingHydration)
        XCTAssertTrue(restored.accessRefused)
        XCTAssertEqual(
            FileConflictBanner.actions(for: restored), [.locate, .keepMine, .saveAs],
            "locate is offered, and take theirs is not while nothing can be read")

        // The read comes back, and the activation's check is what
        // notices: the mark goes, and the copy on disk can be taken.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        second.model.checkOpenFilesOnActivate()
        let after = try XCTUnwrap(second.model.openFiles.first)
        XCTAssertFalse(after.accessRefused, "the mark clears on the next read that succeeds")
        XCTAssertTrue(after.isDirty)
        assertBalanced(second.scope)
    }

    func testARebindOntoAPathAnotherRestoredFileHoldsLeavesBothStandingAndKeepsTheOldBookmark() throws {
        let fixture = try makeFixture()
        let a = try write("a\n", named: "a.txt", in: fixture)
        let b = try write("b\n", named: "b.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: a)
        first.model.openFile(at: b)
        let ids = first.model.openFiles.map(\.id)
        // The second record's bookmark is made to resolve to the first
        // file's path, which is what two records look like after one
        // file was moved over the other.
        let bookmarkForA = try XCTUnwrap(first.client.fileBookmarkBase64(ids[0]))
        XCTAssertTrue(first.client.setFileBookmark(ids[1], base64: bookmarkForA))
        XCTAssertTrue(first.model.saveState())

        let second = launch(fixture)

        XCTAssertEqual(second.model.openFiles.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(
            second.journal.events,
            ["start a.txt", "hydrate", "stop a.txt", "start a.txt", "hydrate", "stop a.txt"],
            "the refused rebind makes no fresh bookmark: it would be a bookmark for the other file")
        assertBalanced(second.scope)
        let restored = second.model.openFiles
        XCTAssertEqual(second.model.storage(for: restored[1].id).string, "b\n")
    }

    // MARK: What a restore owes the drafts file

    func testAMoveFoundAtOneLaunchIsOnRecordAtTheNextWithNothingTouched() throws {
        let fixture = try makeFixture()
        let url = try write("travels\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        XCTAssertTrue(first.model.saveState())
        let moved = fixture.workspace.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: url, to: moved)

        // The launch that finds the file where it went. Nobody opens,
        // edits, saves or closes anything, and then the app quits,
        // which is one `saveState`.
        let second = launch(fixture)
        XCTAssertTrue(second.journal.events.contains("bookmark"), "the move was found and rebookmarked")
        XCTAssertTrue(second.model.draftsDirty, "the record on disk is now behind the roster")
        XCTAssertTrue(second.model.saveState())
        XCTAssertFalse(second.model.draftsDirty)

        let third = launch(fixture)

        XCTAssertEqual(
            third.journal.events, ["start renamed.txt", "hydrate", "stop renamed.txt"],
            "the record already carries the new path and a bookmark that is not stale, so nothing is made again")
        let restored = try XCTUnwrap(third.model.openFiles.first)
        XCTAssertTrue(PageModel.samePath(restored.path, moved.path))
        XCTAssertFalse(third.model.draftsDirty, "a restore that changed nothing owes no write")
        XCTAssertNil(third.model.notice)
    }

    func testAScopedBookmarkGivenToALegacyRecordIsOnRecordAtTheNextLaunch() throws {
        let fixture = try makeFixture()
        let url = try write("legacy\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        let id = try XCTUnwrap(first.model.openFiles.first?.id)
        let plain = try url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        XCTAssertTrue(first.client.setFileBookmark(id, base64: plain.base64EncodedString()))
        XCTAssertTrue(first.model.saveState())

        let second = launch(fixture)
        XCTAssertEqual(second.journal.events, ["hydrate", "bookmark"])
        XCTAssertTrue(second.model.saveState())

        let third = launch(fixture)

        XCTAssertEqual(
            third.journal.events, ["start notes.txt", "hydrate", "stop notes.txt"],
            "the upgrade was stored, so it is not made again at every launch")
    }

    func testAFileDroppedAtOneLaunchIsNotAnnouncedAgainAtTheNext() throws {
        let fixture = try makeFixture()
        let kept = try write("kept\n", named: "kept.txt", in: fixture)
        let gone = try write("gone\n", named: "gone.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: kept)
        first.model.openFile(at: gone)
        XCTAssertTrue(first.model.saveState())
        try FileManager.default.removeItem(at: gone)

        let second = launch(fixture)
        XCTAssertNotNil(second.model.notice, "the launch that finds it gone says so")
        XCTAssertTrue(second.model.saveState())

        let third = launch(fixture)

        XCTAssertEqual(third.model.openFiles.map(\.name), ["kept.txt"])
        XCTAssertEqual(third.client.hydrations.count, 1, "the dropped record left the drafts file")
        XCTAssertNil(third.model.notice, "and it is said once, not at every launch")
    }

    func testAStaleBookmarkMendedOnActivationIsOwedToTheDraftsFile() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        XCTAssertTrue(launched.model.saveState())
        XCTAssertFalse(launched.model.draftsDirty)
        // A move while the file is open leaves its bookmark resolving,
        // and stale.
        let moved = fixture.workspace.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: url, to: moved)
        let before = try XCTUnwrap(launched.client.fileBookmarkBase64(id))
        launched.journal.clear()

        launched.model.checkOpenFilesOnActivate()

        try XCTSkipUnless(
            launched.journal.events.contains("bookmark"),
            "this system did not call the bookmark stale, so there was nothing to mend")
        XCTAssertNotEqual(launched.client.fileBookmarkBase64(id), before)
        XCTAssertTrue(
            launched.model.draftsDirty,
            "a mended bookmark that lives only in memory is lost at the next quit")
        assertBalanced(launched.scope)
    }

    // MARK: A bookmark the old file still answers to

    func testSaveAsWithNoBookmarkToBeHadDropsTheOldOneAndTheRelaunchStaysAtTheNewPath() throws {
        let fixture = try makeFixture()
        let (first, original, id) = try openedFile("theirs\n", in: fixture)
        let target = fixture.workspace.appendingPathComponent("copy.txt")
        first.panels.destinationURL = target
        first.model.fileCoordinator.makeBookmark = { _ in throw CocoaError(.fileReadUnknown) }

        first.model.saveActiveFileAs()

        XCTAssertEqual(
            first.model.notice, PageModel.bookmarkFailureNotice(name: "copy.txt"))
        XCTAssertEqual(
            first.client.fileBookmarkBase64(id), "",
            "the bookmark for the file that was saved away from is not kept")
        // Edits made to the copy, which is where a wrong rebind would
        // do its harm: a draft one save away from the original.
        try type("mine ", at: 0, into: id, on: first.model)
        XCTAssertTrue(first.model.saveState())

        let second = launch(fixture)

        let restored = try XCTUnwrap(second.model.openFiles.first)
        XCTAssertTrue(
            PageModel.samePath(restored.path, target.path),
            "the tab is still the copy: \(restored.path)")
        XCTAssertEqual(second.client.hydrations.count, 1)
        XCTAssertNil(
            second.client.hydrations[0].resolvedPath,
            "with no bookmark the recorded path is read and nothing can rebind it")
        XCTAssertEqual(restored.conflict, FileConflict.none)
        XCTAssertTrue(second.model.saveFile(restored.id))
        XCTAssertEqual(try read(target), "mine theirs\n")
        XCTAssertEqual(try read(original), "theirs\n", "the file that was saved away from is untouched")
    }

    // MARK: The Trash

    func testTheSystemsTrashAnswerIsNoForAnOrdinaryFileAndForOneThatIsNotThere() throws {
        let fixture = try makeFixture()
        let url = try write("here\n", named: "notes.txt", in: fixture)
        XCTAssertFalse(FileCoordinator.systemTrashContains(url))
        XCTAssertFalse(
            FileCoordinator.systemTrashContains(fixture.workspace.appendingPathComponent("absent.txt")))
    }

    /// A directory standing in for the Trash, and the seam that says
    /// so. The real one keeps a file's identity across the move just
    /// as this rename does, which is the whole of what matters here.
    private func trash(in fixture: Fixture) throws -> (URL, (FileCoordinator) -> Void) {
        let bin = fixture.workspace.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let resolved = bin.resolvingSymlinksInPath().path + "/"
        return (bin, { coordinator in
            coordinator.isInTrash = { $0.resolvingSymlinksInPath().path.hasPrefix(resolved) }
        })
    }

    func testACleanFileThrownAwayWhileTheAppWasClosedDoesNotComeBackFromTheTrash() throws {
        let fixture = try makeFixture()
        let url = try write("discarded\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        XCTAssertTrue(first.model.saveState())
        let (bin, seam) = try trash(in: fixture)
        try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent("notes.txt"))

        let second = launch(fixture, prepare: seam)

        XCTAssertTrue(second.model.openFiles.isEmpty, "a thrown away file is not a tab")
        XCTAssertEqual(second.client.hydrations.count, 1)
        XCTAssertNil(
            second.client.hydrations[0].resolvedPath,
            "the bookmark led into the Trash, so the recorded path is what is read")
        XCTAssertEqual(
            second.model.notice,
            PageModel.launchNotice(
                reloaded: [],
                notices: [DraftNotice(name: "notes.txt", path: url.path, reason: .missing)]))
        XCTAssertFalse(second.journal.events.contains("bookmark"))
        assertBalanced(second.scope)
    }

    func testADraftOverAFileThrownAwayStandsInAMissingConflictAndIsNotBoundToTheTrash() throws {
        let fixture = try makeFixture()
        let url = try write("on disk\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        let id = try XCTUnwrap(first.model.openFiles.first?.id)
        try type("unsaved ", at: 0, into: id, on: first.model)
        XCTAssertTrue(first.model.saveState())
        let (bin, seam) = try trash(in: fixture)
        let trashed = bin.appendingPathComponent("notes.txt")
        try FileManager.default.moveItem(at: url, to: trashed)

        let second = launch(fixture, prepare: seam)

        let restored = try XCTUnwrap(second.model.openFiles.first, "the draft is kept")
        // Compared by directory, since nothing is at the path any more
        // and a path with nothing at it does not resolve the same way
        // twice.
        XCTAssertTrue(
            PageModel.samePath(
                URL(fileURLWithPath: restored.path).deletingLastPathComponent().path,
                fixture.workspace.path),
            "the file is still bound to where it was, not to the Trash: \(restored.path)")
        XCTAssertEqual(restored.name, "notes.txt")
        XCTAssertEqual(restored.conflict, .missing)
        XCTAssertTrue(restored.isDirty)
        XCTAssertEqual(second.model.storage(for: restored.id).string, "unsaved on disk\n")
        XCTAssertFalse(second.model.saveFile(restored.id), "and no save goes anywhere until the person chooses")
        XCTAssertEqual(try read(trashed), "on disk\n", "nothing was written into the Trash")
        assertBalanced(second.scope)
    }

    // MARK: Renames that cross

    func testAFileRenamedOntoANameAnotherOpenFileMovedOffIsNotDroppedForItsPlaceInTheRoster() throws {
        let fixture = try makeFixture()
        let a = try write("a\n", named: "a.txt", in: fixture)
        let b = try write("b\n", named: "b.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: a)
        first.model.openFile(at: b)
        let ids = first.model.openFiles.map(\.id)
        // What the two records look like after b stepped aside to
        // old.txt and a took its name: the first record's bookmark
        // leads to b.txt, which the second record still names, and the
        // second's leads to old.txt. Arranged by handing each record
        // the bookmark rather than by renaming, because on the system
        // this was written on a bookmark whose recorded path has some
        // other file at it resolves to that path, and the renames
        // alone never produce the crossing.
        let old = try write("b\n", named: "old.txt", in: fixture)
        let forB = try XCTUnwrap(first.client.fileBookmarkBase64(ids[1]))
        let forOld = try first.model.fileCoordinator.bookmark(for: old)
        XCTAssertTrue(first.client.setFileBookmark(ids[0], base64: forB))
        XCTAssertTrue(first.client.setFileBookmark(ids[1], base64: forOld.base64EncodedString()))
        XCTAssertTrue(first.model.saveState())
        try FileManager.default.removeItem(at: a)

        let second = launch(fixture)

        XCTAssertEqual(
            second.journal.events,
            [
                "start b.txt", "hydrate", "stop b.txt",
                "start old.txt", "hydrate", "bookmark", "stop old.txt",
                "start b.txt", "hydrate", "bookmark", "stop b.txt",
            ],
            "the first file waits for the second to move off the name, then takes it")
        XCTAssertEqual(
            second.model.openFiles.map(\.name), ["b.txt", "old.txt"],
            "the first file was not dropped as missing for being asked first")
        XCTAssertFalse(second.model.openFiles.contains(where: \.pendingHydration))
        XCTAssertEqual(
            Set(second.model.openFiles.map(\.path)).count, 2, "no two tabs share one file")
        XCTAssertFalse(
            second.model.notice?.contains("no longer at its path") ?? false,
            "nothing is reported missing: \(second.model.notice ?? "")")
        assertBalanced(second.scope)
    }

    func testTwoFilesThatTradedNamesBothComeBackAndNeitherIsLeftWaiting() throws {
        let fixture = try makeFixture()
        let a = try write("a\n", named: "a.txt", in: fixture)
        let b = try write("b\n", named: "b.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: a)
        first.model.openFile(at: b)
        let ids = first.model.openFiles.map(\.id)
        // Each record is given the other's bookmark, which is what the
        // two look like after the files traded names.
        let forA = try XCTUnwrap(first.client.fileBookmarkBase64(ids[0]))
        let forB = try XCTUnwrap(first.client.fileBookmarkBase64(ids[1]))
        XCTAssertTrue(first.client.setFileBookmark(ids[0], base64: forB))
        XCTAssertTrue(first.client.setFileBookmark(ids[1], base64: forA))
        XCTAssertTrue(first.model.saveState())

        let second = launch(fixture)

        XCTAssertEqual(second.model.openFiles.map(\.name), ["a.txt", "b.txt"])
        XCTAssertFalse(
            second.model.openFiles.contains(where: \.pendingHydration),
            "a wait that cannot end is ended at the recorded path")
        XCTAssertEqual(
            Set(second.model.openFiles.map(\.path)).count, 2, "no two tabs share one file")
        assertBalanced(second.scope)

        // Each is read at its recorded path, and the grant on that
        // path is the other file's bookmark. So the reads that end the
        // wait happen with both scopes open, which is the only
        // arrangement in which a sandboxed build can make either.
        XCTAssertEqual(
            second.journal.events,
            [
                "start b.txt", "hydrate", "stop b.txt",
                "start a.txt", "hydrate", "stop a.txt",
                "start b.txt", "start a.txt",
                "hydrate", "bookmark", "hydrate", "bookmark",
                "stop a.txt", "stop b.txt",
            ],
            "the tie is broken inside both files' scopes, and each is given a bookmark there")
        XCTAssertEqual(second.scope.deepest, 2)
        let rows = second.model.openFiles
        XCTAssertEqual(second.model.storage(for: rows[0].id).string, "a\n")
        XCTAssertEqual(second.model.storage(for: rows[1].id).string, "b\n")
        // And each now carries a bookmark for the path it rests at,
        // so every later bracket opens its scope on its own file.
        for row in rows {
            let data = try XCTUnwrap(
                Data(base64Encoded: try XCTUnwrap(second.client.fileBookmarkBase64(row.id))))
            let resolved = FileCoordinator(panels: ScriptedFilePanels())
                .withAccess(toBookmark: data) { $0.url.path }
            XCTAssertTrue(PageModel.samePath(try XCTUnwrap(resolved), row.path), row.name)
        }
        XCTAssertTrue(second.model.draftsDirty, "and the drafts file is owed the mended bookmarks")
    }

    // MARK: A file the launch could not read

    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
    }

    private func unlock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    /// Whether a roster path still names `url`, for a file that is no
    /// longer there. `samePath` cannot answer that: it resolves
    /// symlinks through the file itself, and with nothing at the path
    /// the temp directory's own link is left unresolved on one side.
    /// So the directories are compared, which do exist, and the names.
    private func stillRecorded(_ path: String, at url: URL) -> Bool {
        let recorded = URL(fileURLWithPath: path)
        return recorded.lastPathComponent == url.lastPathComponent
            && PageModel.samePath(
                recorded.deletingLastPathComponent().path, url.deletingLastPathComponent().path)
    }

    /// A relaunch over one clean file the process may not read, which
    /// is the nearest an unsandboxed test comes to a file whose grant
    /// is gone: the stat answers and the read is refused. The journal
    /// is cleared so the test reads only what it does next.
    private func heldFile(
        in fixture: Fixture
    ) throws -> (launch: Launch, url: URL, id: UInt64) {
        try XCTSkipIf(getuid() == 0, "root reads a mode 000 file, so there is nothing to refuse")
        let url = try write("body\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        XCTAssertTrue(first.model.saveState())
        try lock(url)
        let second = launch(fixture)
        let id = try XCTUnwrap(second.model.openFiles.first?.id, "the file was dropped, not held")
        assertBalanced(second.scope)
        second.journal.clear()
        return (second, url, id)
    }

    func testACleanFileThatWillNotBeReadIsHeldWithNoTextShownAsItsOwn() throws {
        let fixture = try makeFixture()
        let (held, url, id) = try heldFile(in: fixture)

        let row = try XCTUnwrap(held.model.openFiles.first)
        XCTAssertTrue(row.isHeld, "kept in the roster so the person can say where it is")
        XCTAssertTrue(row.pendingHydration)
        XCTAssertTrue(row.accessRefused)
        XCTAssertFalse(row.isDirty)
        XCTAssertEqual(row.conflict, FileConflict.none)
        XCTAssertTrue(PageModel.samePath(row.path, url.path), "it still names the last known path")
        XCTAssertEqual(held.model.storage(for: id).string, "", "nothing was read, so nothing is shown")
        XCTAssertTrue(FileUnavailableBanner.stands(for: row))
        held.model.selectFile(id)
        held.model.resolveConflict(.keepMine)
        XCTAssertTrue(held.journal.events.isEmpty, "a held input never reaches Keep mine")
        XCTAssertNil(held.model.notice, "nothing was dropped, so the launch names nothing")

        // Typing is refused by the core, and a save is refused out
        // loud, so the empty buffer can never reach the file.
        try type("x", at: 0, into: id, on: held.model)
        XCTAssertTrue(held.client.fileRuns(id).isEmpty)
        XCTAssertFalse(held.model.saveFile(id))
        XCTAssertEqual(held.model.notice, PageModel.heldFileNotice(name: "notes.txt"))
        XCTAssertFalse(held.journal.events.contains("save"), "the core was not even asked")
        try unlock(url)
        XCTAssertEqual(try read(url), "body\n")
    }

    func testAHeldFileComesBackHeldAtTheNextLaunchAndReadableOnceItCanBeRead() throws {
        let fixture = try makeFixture()
        let (held, url, _) = try heldFile(in: fixture)
        XCTAssertTrue(held.model.saveState())

        let third = launch(fixture)
        XCTAssertEqual(third.model.openFiles.first?.isHeld, true, "the record went back out as it came")

        XCTAssertTrue(third.model.saveState())
        try unlock(url)
        let fourth = launch(fixture)
        let row = try XCTUnwrap(fourth.model.openFiles.first)
        XCTAssertFalse(row.pendingHydration)
        XCTAssertFalse(row.accessRefused)
        XCTAssertEqual(fourth.model.storage(for: row.id).string, "body\n")
    }

    func testAHeldFileIsAskedAgainOnActivationAndSettlesOnceItCanBeRead() throws {
        let fixture = try makeFixture()
        let (held, url, id) = try heldFile(in: fixture)
        // The editor has the empty buffer mounted, as it would on screen.
        XCTAssertEqual(held.model.storage(for: id).string, "")

        held.model.checkOpenFilesOnActivate()

        XCTAssertEqual(held.model.openFiles.first?.isHeld, true, "still refused, still held")
        XCTAssertEqual(
            held.journal.events, ["start notes.txt", "hydrate", "stop notes.txt"],
            "a held file is hydrated again inside its scope, and never checked or reloaded")
        XCTAssertNil(held.model.notice, "the banner is already saying it")
        assertBalanced(held.scope)

        try unlock(url)
        held.model.checkOpenFilesOnActivate()

        let row = try XCTUnwrap(held.model.openFiles.first)
        XCTAssertFalse(row.pendingHydration)
        XCTAssertFalse(row.accessRefused, "the mark clears with the first read that succeeds")
        XCTAssertEqual(held.model.storage(for: id).string, "body\n", "and the mounted buffer is restated")
        XCTAssertNil(held.model.notice, "the file had not changed, so there is nothing to say")
        assertBalanced(held.scope)
    }

    func testAHeldFileThatHasSinceGoneIsDroppedOnActivationAndNamed() throws {
        let fixture = try makeFixture()
        let (held, url, _) = try heldFile(in: fixture)
        try FileManager.default.removeItem(at: url)

        held.model.checkOpenFilesOnActivate()

        XCTAssertTrue(held.model.openFiles.isEmpty, "a clean file that is simply gone leaves, as at launch")
        XCTAssertEqual(held.model.notice, PageModel.missingNotice(name: "notes.txt"))
        XCTAssertTrue(held.model.draftsDirty, "and the drafts file is owed the smaller roster")
        assertBalanced(held.scope)
    }

    // MARK: An open never lands on a pending row

    func testAnOpenOfAHeldFilesPathHydratesItFirst() throws {
        let fixture = try makeFixture()
        let (held, url, id) = try heldFile(in: fixture)

        // Still refused: the row is asked, stays held, and the open
        // is refused rather than handed the pending id.
        held.model.openFile(at: url)

        XCTAssertEqual(
            held.journal.events, ["start notes.txt", "hydrate", "open", "stop notes.txt"],
            "hydrate first, then open, both inside the panel's bracket")
        XCTAssertEqual(held.model.openFiles.map(\.id), [id])
        XCTAssertEqual(held.model.openFiles.first?.isHeld, true)
        XCTAssertNotEqual(held.model.activeFile?.id, id, "the held row was not raised as the answer")
        XCTAssertEqual(
            held.model.notice,
            PageModel.openRefusalNotice(name: "notes.txt", json: held.client.openFileErrorJSON()))
        assertBalanced(held.scope)

        // Readable now: the same open settles the row and lands on it.
        try unlock(url)
        held.journal.clear()
        held.model.openFile(at: url)

        XCTAssertEqual(
            held.journal.events,
            ["start notes.txt", "hydrate", "open", "bookmark", "stop notes.txt"])
        XCTAssertEqual(held.model.openFiles.map(\.id), [id], "one tab, the one that was already there")
        let row = try XCTUnwrap(held.model.openFiles.first)
        XCTAssertFalse(row.pendingHydration)
        XCTAssertFalse(row.accessRefused)
        XCTAssertEqual(held.model.activeFile?.id, id)
        XCTAssertEqual(held.model.storage(for: id).string, "body\n")
        assertBalanced(held.scope)
    }

    func testTheCoreRefusesAnOpenThatWouldLandOnAPendingRow() throws {
        // The rule underneath the one above, for a shell that forgot
        // to hydrate first: the core will not hand back a pending id.
        let fixture = try makeFixture()
        let url = try write("body\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        XCTAssertTrue(first.model.saveState())

        let second = launch(fixture, load: false)
        XCTAssertTrue(
            second.client.draftsRestore(from: FormFactor.draftsFileURL(in: fixture.state).path))
        let pending = try XCTUnwrap(second.client.fileRoster().first)
        XCTAssertTrue(pending.pendingHydration)

        XCTAssertNil(second.client.openFile(path: url.path), "refused, though the file reads perfectly well")
        XCTAssertEqual(second.client.fileRoster().count, 1, "and no second buffer was opened over it")

        XCTAssertTrue(second.client.hydrateFile(pending.id, resolvedPath: nil))
        XCTAssertEqual(second.client.openFile(path: url.path), pending.id)
    }

    // MARK: Locate

    /// A dirty file whose disk copy went somewhere its bookmark cannot
    /// follow, standing in a missing conflict and selected.
    private func strandedDraft(
        in fixture: Fixture
    ) throws -> (launch: Launch, url: URL, moved: URL, id: UInt64) {
        let (launched, url, id) = try openedFile("on disk\n", in: fixture)
        try type("unsaved ", at: 0, into: id, on: launched.model)
        XCTAssertTrue(launched.client.setFileBookmark(id, base64: ""))
        let moved = fixture.workspace.appendingPathComponent("elsewhere.txt")
        try FileManager.default.moveItem(at: url, to: moved)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.model.openFiles.first?.conflict, .missing)
        launched.model.selectFile(id)
        launched.journal.clear()
        return (launched, url, moved, id)
    }

    func testLocatingAHeldFileReadsAndBookmarksInsideThePanelBracketAndSettlesIt() throws {
        let fixture = try makeFixture()
        let (held, url, id) = try heldFile(in: fixture)
        XCTAssertEqual(held.model.storage(for: id).string, "")
        let before = try XCTUnwrap(held.client.fileBookmarkBase64(id))
        // The person finds the file somewhere it can be read.
        let found = fixture.workspace.appendingPathComponent("found.txt")
        try FileManager.default.moveItem(at: url, to: found)
        try unlock(found)
        held.panels.locateURL = found

        held.model.locateFile(id)

        XCTAssertEqual(
            held.journal.events,
            ["start found.txt", "relocate", "bookmark", "stop found.txt"],
            "the core's read and the fresh bookmark are both inside the panel's bracket")
        assertBalanced(held.scope)
        XCTAssertEqual(held.panels.locates.count, 1)
        XCTAssertEqual(held.panels.locates.first?.name, "notes.txt", "the panel names the file it asks about")
        XCTAssertTrue(
            PageModel.samePath(
                try XCTUnwrap(held.panels.locates.first?.directory.path), fixture.workspace.path),
            "and starts where the file was last known to be")

        let row = try XCTUnwrap(held.model.openFiles.first)
        XCTAssertFalse(row.pendingHydration)
        XCTAssertFalse(row.accessRefused)
        XCTAssertFalse(row.isDirty)
        XCTAssertEqual(row.name, "found.txt")
        XCTAssertTrue(PageModel.samePath(row.path, found.path))
        XCTAssertEqual(held.model.storage(for: id).string, "body\n", "a clean file adopts the copy on disk")
        XCTAssertNil(held.model.notice)

        // The bookmark was replaced, and the new one names the file
        // where it is now.
        let after = try XCTUnwrap(held.client.fileBookmarkBase64(id))
        XCTAssertNotEqual(after, before)
        let resolved = FileCoordinator(panels: ScriptedFilePanels())
            .withAccess(toBookmark: try XCTUnwrap(Data(base64Encoded: after))) { $0.url.path }
        XCTAssertTrue(PageModel.samePath(try XCTUnwrap(resolved), found.path))

        // And the drafts file is owed the new path and the new bookmark.
        XCTAssertTrue(held.model.draftsDirty)
        XCTAssertTrue(held.model.saveState())
        let next = launch(fixture)
        let restored = try XCTUnwrap(next.model.openFiles.first)
        XCTAssertTrue(PageModel.samePath(restored.path, found.path))
        XCTAssertFalse(restored.pendingHydration)
    }

    func testCancellingTheLocatePanelChangesNothing() throws {
        let fixture = try makeFixture()
        let (held, _, id) = try heldFile(in: fixture)
        let roster = held.model.openFiles
        let bookmark = held.client.fileBookmarkBase64(id)
        let owed = held.model.draftsDirty
        let starts = held.scope.starts
        held.panels.locateURL = nil

        held.model.locateFile(id)

        XCTAssertEqual(held.panels.locates.count, 1, "the panel was raised")
        XCTAssertTrue(held.journal.events.isEmpty, "and after the cancel nothing was asked of anything")
        XCTAssertEqual(held.scope.starts, starts, "no scope was opened")
        XCTAssertEqual(held.model.openFiles, roster)
        XCTAssertEqual(held.client.fileBookmarkBase64(id), bookmark)
        XCTAssertEqual(held.model.draftsDirty, owed)
        XCTAssertNil(held.model.notice)
    }

    func testLocatingTheFileADraftWasMeasuredAgainstLetsTheDraftStandWithNoConflict() throws {
        let fixture = try makeFixture()
        let (launched, url, moved, id) = try strandedDraft(in: fixture)
        let stranded = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertTrue(stranded.notFound)
        XCTAssertEqual(
            FileConflictBanner.actions(for: stranded), [.locate, .keepMine, .saveAs],
            "nothing is at the path, so take theirs has nothing to take")
        launched.panels.locateURL = moved

        launched.model.resolveConflict(.locate)

        XCTAssertEqual(
            launched.journal.events,
            ["start elsewhere.txt", "relocate", "bookmark", "stop elsewhere.txt"])
        assertBalanced(launched.scope)
        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, FileConflict.none, "the same file, found again")
        XCTAssertTrue(row.isDirty, "and the draft is still a draft")
        XCTAssertTrue(PageModel.samePath(row.path, moved.path))
        XCTAssertEqual(launched.model.storage(for: id).string, "unsaved on disk\n")
        XCTAssertFalse(
            try XCTUnwrap(launched.client.fileBookmarkBase64(id)).isEmpty,
            "the file has a bookmark again")
        XCTAssertTrue(launched.model.draftsDirty)

        // The save lands where the file is, and recreates nothing
        // where it was.
        XCTAssertTrue(launched.model.saveFile(id))
        XCTAssertEqual(try read(moved), "unsaved on disk\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLocatingADifferentTextIsAConflictInWhichTheCopyOnDiskCanBeTaken() throws {
        let fixture = try makeFixture()
        let (launched, _, _, id) = try strandedDraft(in: fixture)
        let other = try write("theirs\n", named: "other.txt", in: fixture)
        launched.panels.locateURL = other

        launched.model.resolveConflict(.locate)

        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, .changed, "two texts, and the person chooses")
        XCTAssertFalse(row.accessRefused)
        XCTAssertTrue(row.isDirty)
        XCTAssertTrue(PageModel.samePath(row.path, other.path))
        XCTAssertEqual(launched.model.storage(for: id).string, "unsaved on disk\n", "the draft stands")
        XCTAssertEqual(
            FileConflictBanner.actions(for: row), [.keepMine, .takeTheirs, .saveAs],
            "take theirs is on offer now that there is a copy to take")
        XCTAssertFalse(launched.model.saveFile(id), "and the save stays refused until one is chosen")
        XCTAssertEqual(try read(other), "theirs\n")

        launched.model.resolveConflict(.takeTheirs)
        XCTAssertEqual(launched.model.storage(for: id).string, "theirs\n")
        assertBalanced(launched.scope)
    }

    func testLocatingOntoAFileAnotherTabHoldsIsRefusedWithItsOwnSentence() throws {
        let fixture = try makeFixture()
        let (launched, url, _, id) = try strandedDraft(in: fixture)
        let other = try write("b\n", named: "b.txt", in: fixture)
        launched.model.openFile(at: other)
        launched.model.selectFile(id)
        launched.journal.clear()
        let bookmark = launched.client.fileBookmarkBase64(id)
        launched.panels.locateURL = other

        launched.model.locateFile(id)

        XCTAssertEqual(
            launched.model.notice, PageModel.locateHeldNotice(name: "notes.txt", holder: "b.txt"))
        XCTAssertEqual(
            launched.journal.events, ["start b.txt", "stop b.txt"],
            "the bracket opened and closed, and the core was not asked")
        assertBalanced(launched.scope)
        let row = try XCTUnwrap(launched.model.openFiles.first(where: { $0.id == id }))
        XCTAssertEqual(row.conflict, .missing, "the record is as it was")
        XCTAssertTrue(stillRecorded(row.path, at: url))
        XCTAssertEqual(launched.client.fileBookmarkBase64(id), bookmark)
        XCTAssertEqual(launched.model.storage(for: id).string, "unsaved on disk\n")
    }

    func testLocatingAFileThatIsNotTextOrIsTooLargeIsRefusedAsAnOpenIsAndTheRecordStays() throws {
        let fixture = try makeFixture()
        let (launched, url, _, id) = try strandedDraft(in: fixture)
        let binary = fixture.workspace.appendingPathComponent("b.bin")
        try Data([0x66, 0x6f, 0xFF, 0xFE]).write(to: binary)
        let huge = fixture.workspace.appendingPathComponent("huge.txt")
        try Data(repeating: 0x61, count: 4 * 1024 * 1024 + 1).write(to: huge)

        launched.panels.locateURL = binary
        launched.model.locateFile(id)

        XCTAssertEqual(
            launched.model.notice,
            PageModel.openRefusalNotice(name: "b.bin", json: #"{"error":"notUtf8"}"#),
            "the sentence an open gives for the same file")
        XCTAssertEqual(launched.journal.events, ["start b.bin", "relocate", "stop b.bin"])

        launched.panels.locateURL = huge
        launched.model.locateFile(id)

        XCTAssertEqual(
            launched.model.notice, "huge.txt is larger than 4 MiB, so it was not opened.")
        assertBalanced(launched.scope)

        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, .missing, "the record is as it was")
        XCTAssertTrue(stillRecorded(row.path, at: url))
        XCTAssertTrue(row.isDirty)
        XCTAssertEqual(launched.model.storage(for: id).string, "unsaved on disk\n")
        XCTAssertFalse(launched.journal.events.contains("bookmark"))
    }

    func testABookmarkThatCannotBeMadeAfterALocateIsSaidAndTheOldOneIsDropped() throws {
        let fixture = try makeFixture()
        let (held, url, id) = try heldFile(in: fixture)
        let found = fixture.workspace.appendingPathComponent("found.txt")
        try FileManager.default.moveItem(at: url, to: found)
        try unlock(found)
        held.panels.locateURL = found
        held.model.fileCoordinator.makeBookmark = { _ in throw CocoaError(.fileReadUnknown) }

        held.model.locateFile(id)

        XCTAssertEqual(held.model.openFiles.first?.name, "found.txt", "the file was located all the same")
        XCTAssertEqual(held.model.notice, PageModel.bookmarkFailureNotice(name: "found.txt"))
        XCTAssertEqual(
            held.client.fileBookmarkBase64(id), "",
            "the old bookmark named a file the person has said is not this one")
        assertBalanced(held.scope)
    }

    // MARK: A file moved while the app is running

    func testACleanFileMovedWhileTheAppIsRunningIsFollowedRatherThanReportedMissing() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile("travels\n", in: fixture)
        XCTAssertEqual(launched.model.storage(for: id).string, "travels\n")
        XCTAssertTrue(launched.model.saveState())
        let moved = fixture.workspace.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: url, to: moved)
        launched.journal.clear()

        launched.model.checkOpenFilesOnActivate()

        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertTrue(PageModel.samePath(row.path, moved.path), "the file was followed: \(row.path)")
        XCTAssertEqual(row.name, "renamed.txt")
        XCTAssertEqual(row.conflict, FileConflict.none)
        XCTAssertFalse(row.isDirty)
        XCTAssertNil(launched.model.notice, "a move is not a change, and nothing is missing")
        // A stale bookmark may be mended before the check, which is one
        // more "bookmark" on a system that calls it stale.
        XCTAssertEqual(
            launched.journal.events.filter { $0 != "bookmark" },
            ["start renamed.txt", "check", "relocate", "stop renamed.txt"],
            "the rebind happens inside the scope the check already holds")
        XCTAssertEqual(launched.journal.events.dropLast().last, "bookmark", "and is bookmarked before it closes")
        XCTAssertTrue(
            PageModel.samePath(try XCTUnwrap(launched.client.relocations.first?.path), moved.path))
        assertBalanced(launched.scope)
        XCTAssertEqual(launched.model.storage(for: id).string, "travels\n")
        XCTAssertTrue(launched.model.draftsDirty, "the drafts file is owed the new path")
    }

    func testADraftOverAFileMovedWhileTheAppIsRunningStandsAndSavesWhereTheFileIsNow() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile("on disk\n", in: fixture)
        try type("unsaved ", at: 0, into: id, on: launched.model)
        let moved = fixture.workspace.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: url, to: moved)
        launched.journal.clear()

        // The check a save makes first is the one that finds the move.
        XCTAssertTrue(launched.model.saveFile(id))

        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertTrue(PageModel.samePath(row.path, moved.path))
        XCTAssertEqual(row.conflict, FileConflict.none)
        XCTAssertFalse(row.isDirty)
        XCTAssertEqual(try read(moved), "unsaved on disk\n", "the save landed on the file where it is")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path), "and recreated nothing where it was")
        XCTAssertEqual(launched.scope.deepest, 1, "one bracket around the check, the rebind and the write")
        assertBalanced(launched.scope)
    }

    func testAFileThrownAwayWhileTheAppIsRunningIsReportedMissingAndNotFollowed() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile("discarded\n", in: fixture)
        let bin = fixture.workspace.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent("notes.txt"))
        let binPath = bin.resolvingSymlinksInPath().path
        launched.model.fileCoordinator.isInTrash = {
            $0.resolvingSymlinksInPath().path.hasPrefix(binPath)
        }

        launched.model.checkOpenFilesOnActivate()

        XCTAssertFalse(launched.journal.events.contains("relocate"), "a Trash is not somewhere to follow a file")
        let row = try XCTUnwrap(launched.model.openFiles.first(where: { $0.id == id }))
        XCTAssertTrue(stillRecorded(row.path, at: url))
        XCTAssertEqual(launched.model.notice, PageModel.missingNotice(name: "notes.txt"))
        assertBalanced(launched.scope)
    }

    func testAFileMovedOntoAPathAnotherTabHoldsIsReportedMissingAndBothStand() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile("a\n", in: fixture)
        let other = try write("b\n", named: "b.txt", in: fixture)
        launched.model.openFile(at: other)
        // The first file is moved over the second while both are open.
        _ = try FileManager.default.replaceItemAt(other, withItemAt: url)
        launched.journal.clear()

        let holder = try XCTUnwrap(launched.model.openFiles.first(where: { $0.id != id }))
        XCTAssertTrue(PageModel.samePath(holder.path, other.path))

        launched.model.checkOpenFilesOnActivate()

        let row = try XCTUnwrap(launched.model.openFiles.first(where: { $0.id == id }))
        XCTAssertTrue(stillRecorded(row.path, at: url), "the refused rebind left it where it was")
        XCTAssertEqual(launched.model.openFiles.count, 2)
        XCTAssertTrue(row.notFound)
        assertBalanced(launched.scope)

        // The reason it stayed is the core's refusal of a path another
        // open file holds, and nothing else. The rebind was asked for,
        // once, at the very path the other tab is on.
        XCTAssertEqual(launched.client.relocations.count, 1, "the bookmark was followed and the core asked")
        let asked = try XCTUnwrap(launched.client.relocations.first)
        XCTAssertEqual(asked.file, id)
        XCTAssertTrue(PageModel.samePath(asked.path, other.path), "asked at the holder's path: \(asked.path)")
        let answer = try XCTUnwrap(launched.client.relocationAnswers.first)
        XCTAssertFalse(answer.accepted, "the core refused")
        // The core refuses a relocation for three reasons. The id is
        // open, so it was not an unknown file. A file that would not
        // open leaves an open error behind, and none was left. What
        // remains is the path in use.
        XCTAssertNil(answer.openError, "the file there opens as text, so it was not an open refusal")
        XCTAssertTrue(launched.client.fileRoster().contains(where: { $0.id == id }))
        XCTAssertEqual(try read(other), "a\n", "and what sits at that path is text an open would take")
        XCTAssertTrue(
            try XCTUnwrap(launched.model.notice).contains("notes.txt is no longer at its path"),
            "so the file is reported missing")

        // The proof from the other side: with the holder closed and
        // nothing else changed, the same rebind to the same path is
        // accepted.
        launched.model.closeFile(holder.id)
        XCTAssertEqual(launched.model.openFiles.count, 1)
        launched.model.checkOpenFilesOnActivate()

        XCTAssertEqual(launched.client.relocations.count, 2)
        XCTAssertTrue(PageModel.samePath(try XCTUnwrap(launched.client.relocations.last?.path), other.path))
        XCTAssertEqual(launched.client.relocationAnswers.last?.accepted, true)
        let followed = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(followed.id, id)
        XCTAssertTrue(PageModel.samePath(followed.path, other.path), "the path was free, so the file is followed")
        XCTAssertFalse(followed.notFound)
        assertBalanced(launched.scope)
    }

    func testAFileThatWasOnlyMovedKeepsItsUndoHistoryThroughTheRebind() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile("on disk\n", in: fixture)
        try type("saved ", at: 0, into: id, on: launched.model)
        XCTAssertTrue(launched.model.saveFile(id))
        XCTAssertTrue(launched.client.canUndoFile(id), "the typing is still a step after the save")
        let moved = fixture.workspace.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: url, to: moved)

        launched.model.checkOpenFilesOnActivate()

        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertTrue(PageModel.samePath(row.path, moved.path), "the file was followed")
        XCTAssertFalse(row.isDirty)
        XCTAssertTrue(
            launched.client.canUndoFile(id),
            "a move that changed no word must not empty the undo stack")
        XCTAssertEqual(launched.client.undoFile(id)?.applied, true)
        guard case .ink(let text)? = launched.client.fileRuns(id).first else {
            return XCTFail("the undone buffer holds no text")
        }
        XCTAssertEqual(text, "on disk\n", "and the step it takes back is the typing")
    }

    // MARK: A clean file that is no longer at its path

    func testACleanFileThatGoesMissingIsOfferedLocateAndSaysSoOnce() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile("body\n", in: fixture)
        // No bookmark to follow the file with, which is what a bookmark
        // that could not be made, or no longer resolves, leaves.
        XCTAssertTrue(launched.client.setFileBookmark(id, base64: ""))
        let moved = fixture.workspace.appendingPathComponent("elsewhere.txt")
        try FileManager.default.moveItem(at: url, to: moved)
        launched.model.selectFile(id)

        launched.model.checkOpenFilesOnActivate()

        let gone = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertTrue(gone.notFound)
        XCTAssertFalse(gone.isDirty)
        XCTAssertEqual(gone.conflict, FileConflict.none, "a clean file never enters a conflict")
        XCTAssertTrue(gone.offersLocate)
        XCTAssertTrue(
            FileUnavailableBanner.stands(for: gone),
            "so the banner that offers Locate is what stands for it")
        XCTAssertEqual(launched.model.notice, PageModel.missingNotice(name: "notes.txt"))
        XCTAssertEqual(launched.model.storage(for: id).string, "body\n", "the text read earlier stays")

        // The banner is saying it from here, so the next activation
        // does not say it again.
        launched.model.notice = nil
        launched.model.checkOpenFilesOnActivate()
        XCTAssertNil(launched.model.notice)
        XCTAssertEqual(launched.model.openFiles.first?.notFound, true)

        // The person says where the file is.
        launched.journal.clear()
        launched.panels.locateURL = moved
        launched.model.locateFile(id)

        XCTAssertEqual(
            launched.journal.events,
            ["start elsewhere.txt", "relocate", "bookmark", "stop elsewhere.txt"])
        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertFalse(row.notFound)
        XCTAssertFalse(FileUnavailableBanner.stands(for: row))
        XCTAssertTrue(PageModel.samePath(row.path, moved.path))
        XCTAssertNil(launched.model.notice)
        assertBalanced(launched.scope)
    }

    func testACleanFileThatComesBackToItsPathLosesTheMark() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile("body\n", in: fixture)
        XCTAssertTrue(launched.client.setFileBookmark(id, base64: ""))
        let aside = fixture.workspace.appendingPathComponent("aside.txt")
        try FileManager.default.moveItem(at: url, to: aside)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.model.openFiles.first?.notFound, true)

        try FileManager.default.moveItem(at: aside, to: url)
        launched.model.checkOpenFilesOnActivate()

        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertFalse(row.notFound, "the banner comes down with the mark")
        XCTAssertFalse(FileUnavailableBanner.stands(for: row))
    }

    // MARK: A save never makes a file where there is none

    /// An open file with no bookmark whose disk copy has been moved
    /// away, which is a file gone from its path with nothing to follow
    /// it by.
    private func strandedFile(
        _ text: String = "body\n", in fixture: Fixture
    ) throws -> (launch: Launch, url: URL, moved: URL, id: UInt64) {
        let (launched, url, id) = try openedFile(text, in: fixture)
        XCTAssertTrue(launched.client.setFileBookmark(id, base64: ""))
        let moved = fixture.workspace.appendingPathComponent("elsewhere.txt")
        try FileManager.default.moveItem(at: url, to: moved)
        launched.model.selectFile(id)
        launched.journal.clear()
        return (launched, url, moved, id)
    }

    func testASaveOfACleanFileThatIsGoneIsRefusedAndRecreatesNothing() throws {
        let fixture = try makeFixture()
        let (launched, url, _, id) = try strandedFile(in: fixture)

        // The very first save, before any activation has looked: the
        // save's own check finds the file gone, and the core refuses.
        XCTAssertFalse(launched.model.saveFile(id))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "the file a person moved away is not made again at its old path")
        XCTAssertEqual(
            launched.model.notice, PageModel.saveNotFoundNotice(name: "notes.txt"),
            "one sentence, naming Locate and Save As")
        XCTAssertEqual(launched.model.noticeTone, .actionable)
        XCTAssertEqual(
            launched.journal.events, ["check", "save"],
            "the core was asked, and it is the core that refused")
        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertTrue(row.notFound)
        XCTAssertFalse(row.isDirty)
        XCTAssertEqual(row.conflict, FileConflict.none)
        XCTAssertTrue(FileUnavailableBanner.stands(for: row), "and the banner that offers Locate stands")
        XCTAssertEqual(launched.model.storage(for: id).string, "body\n", "the text read earlier stays")
        XCTAssertEqual(
            launched.client.stagingStoodDuringTheCall, [true],
            "the refusal is not for want of somewhere to stage")
        let staging = try XCTUnwrap(launched.client.stagingDirectories.first ?? nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging), "and the staging directory is gone")
        assertBalanced(launched.scope)

        // Asked again, the answer and the sentence are the same.
        launched.model.notice = nil
        XCTAssertFalse(launched.model.saveFile(id))
        XCTAssertEqual(launched.model.notice, PageModel.saveNotFoundNotice(name: "notes.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTheCoreRefusesTheSaveWhateverTheShellAskedFirst() throws {
        // The rule underneath the one above, for a shell path that
        // skipped the check: the core looks at the path itself.
        let fixture = try makeFixture()
        let (launched, url, _, id) = try strandedFile(in: fixture)
        XCTAssertEqual(launched.client.fileRoster().first?.notFound, false, "nothing has looked yet")

        XCTAssertFalse(launched.client.saveFile(id, stagingDirectory: nil))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(launched.client.fileRoster().first?.notFound, true, "the refusal leaves the mark")
        XCTAssertFalse(launched.journal.events.contains("check"))
    }

    func testASaveOfADraftWhoseFileIsGoneIsRefusedUntilKeepMineAndRecreatesNothingBefore() throws {
        let fixture = try makeFixture()
        let (launched, url, _, id) = try strandedFile("on disk\n", in: fixture)
        try type("unsaved ", at: 0, into: id, on: launched.model)
        launched.journal.clear()

        // The save's own check puts the draft in the missing conflict,
        // and the write is never asked for.
        XCTAssertFalse(launched.model.saveFile(id))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing was recreated")
        XCTAssertEqual(launched.journal.events, ["check"], "the conflict refused before the core was asked")
        var row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, .missing)
        XCTAssertTrue(row.notFound)
        XCTAssertEqual(FileConflictBanner.actions(for: row), [.locate, .keepMine, .saveAs])
        XCTAssertEqual(
            launched.model.notice, PageModel.unresolvedConflictNotice(for: row),
            "the refused save names the ways out, and not only the news")
        XCTAssertEqual(launched.model.noticeTone, .actionable)

        // From here the standing conflict refuses, in the same
        // sentence, after looking once more for the file.
        launched.model.notice = nil
        XCTAssertFalse(launched.model.saveFile(id))
        XCTAssertEqual(
            launched.model.notice,
            "notes.txt is no longer at its path. Choose Locate, keep mine, or Save As before saving.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // And the core refuses the same draft when asked directly.
        XCTAssertFalse(launched.client.saveFile(id, stagingDirectory: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // Keep mine is the consent that makes the file again, which is
        // the one save over a missing file that is allowed.
        launched.model.resolveConflict(.keepMine)
        row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, FileConflict.none)
        XCTAssertTrue(launched.model.saveFile(id))
        XCTAssertEqual(try read(url), "unsaved on disk\n")
        row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertFalse(row.notFound)
        XCTAssertFalse(row.isDirty)
        assertBalanced(launched.scope)
    }

    func testASaveOfADraftTypedOverAFileAlreadyMarkedGoneIsRefusedOutLoud() throws {
        // The activation has already said the file is gone, once, while
        // the file held no edits. The draft typed afterwards is in no
        // conflict until the save's own check finds one, and that check
        // has nothing new to report. The save still owes its sentence.
        let fixture = try makeFixture()
        let (launched, url, _, id) = try strandedFile("on disk\n", in: fixture)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.model.openFiles.first?.notFound, true)
        try type("unsaved ", at: 0, into: id, on: launched.model)
        var row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, FileConflict.none, "nothing has looked since the typing")
        launched.model.notice = nil

        XCTAssertFalse(launched.model.saveFile(id))

        row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, .missing)
        XCTAssertEqual(
            launched.model.notice,
            "notes.txt is no longer at its path. Choose Locate, keep mine, or Save As before saving.")
        XCTAssertEqual(launched.model.noticeTone, .actionable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing was recreated")
        assertBalanced(launched.scope)
    }

    func testAStandingMissingConflictIsLookedAtAgainAndAFileThatIsBackIsSaved() throws {
        let fixture = try makeFixture()
        let (launched, url, moved, id) = try strandedFile("on disk\n", in: fixture)
        try type("unsaved ", at: 0, into: id, on: launched.model)
        XCTAssertFalse(launched.model.saveFile(id))
        XCTAssertEqual(launched.model.openFiles.first?.conflict, .missing)

        // Moved back as it left, with no activation in between to
        // notice. The refusal would be a sentence about a file that is
        // there.
        try FileManager.default.moveItem(at: moved, to: url)
        launched.model.notice = nil
        launched.journal.clear()

        XCTAssertTrue(launched.model.saveFile(id))

        XCTAssertEqual(launched.journal.events.first, "check", "the row was not trusted, the disk was asked")
        XCTAssertEqual(try read(url), "unsaved on disk\n")
        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, FileConflict.none)
        XCTAssertFalse(row.notFound)
        XCTAssertFalse(row.isDirty)
        XCTAssertNil(launched.model.notice)
        assertBalanced(launched.scope)
    }

    func testAStandingMissingConflictOverAFileRewrittenMeanwhileBecomesTheChangedConflict() throws {
        let fixture = try makeFixture()
        let (launched, url, _, id) = try strandedFile("on disk\n", in: fixture)
        try type("unsaved ", at: 0, into: id, on: launched.model)
        XCTAssertFalse(launched.model.saveFile(id))
        XCTAssertEqual(launched.model.openFiles.first?.conflict, .missing)

        // Another tool writes a new file at the path.
        try Data("rewritten\n".utf8).write(to: url)
        launched.model.notice = nil

        XCTAssertFalse(launched.model.saveFile(id))

        var row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, .changed, "the file is there, and it is not the one the draft saw")
        XCTAssertFalse(row.notFound)
        XCTAssertEqual(
            launched.model.notice, PageModel.unresolvedConflictNotice(name: "notes.txt"),
            "the sentence is about the file as it is")
        XCTAssertEqual(try read(url), "rewritten\n", "and nothing was written over it")

        // The same disk, answered from the banner that still said
        // gone: keep mine on a second file in that state is not taken
        // as consent to overwrite a copy nobody was shown.
        try FileManager.default.removeItem(at: url)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.model.openFiles.first?.conflict, .missing)
        try Data("rewritten again\n".utf8).write(to: url)
        launched.model.resolveConflict(.keepMine)
        row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, .changed)
        XCTAssertFalse(launched.model.saveFile(id))
        XCTAssertEqual(try read(url), "rewritten again\n")
        assertBalanced(launched.scope)
    }

    func testKeepMineOverAChangedFileDoesNotRecreateOneDeletedAfterwards() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile("on disk\n", in: fixture)
        XCTAssertTrue(launched.client.setFileBookmark(id, base64: ""))
        launched.model.selectFile(id)
        try type("unsaved ", at: 0, into: id, on: launched.model)
        try Data("theirs\n".utf8).write(to: url)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.model.openFiles.first?.conflict, .changed)
        launched.model.resolveConflict(.keepMine)
        XCTAssertEqual(launched.model.openFiles.first?.conflict, FileConflict.none)

        // The consent was to overwrite a copy. The file is then
        // deleted, which nobody has been asked about.
        try FileManager.default.removeItem(at: url)
        launched.model.notice = nil

        XCTAssertFalse(launched.model.saveFile(id))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing was recreated")
        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, .missing)
        XCTAssertTrue(row.isDirty)
        XCTAssertEqual(launched.model.notice, PageModel.unresolvedConflictNotice(for: row))
        XCTAssertEqual(launched.model.noticeTone, .actionable)
        assertBalanced(launched.scope)
    }

    func testAWriteThatFailsAfterKeepMineOverAMissingFileSaysTheWriteFailed() throws {
        // Keep mine has answered the question of the missing file, so
        // a save that then fails is a write that failed, and is not
        // said as a file that must be located.
        let fixture = try makeFixture()
        let (launched, url, _, id) = try strandedFile("on disk\n", in: fixture)
        try type("unsaved ", at: 0, into: id, on: launched.model)
        launched.model.checkOpenFilesOnActivate()
        launched.model.resolveConflict(.keepMine)
        launched.client.refusesSaves = true

        XCTAssertFalse(launched.model.saveFile(id))

        XCTAssertEqual(launched.model.notice, PageModel.writeRefusalNotice(name: "notes.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        assertBalanced(launched.scope)
    }

    func testAWriteTheCoreRefusesForACleanFileNotFoundWithAKeepMineSaysTheWriteFailed() throws {
        // The corner a bool could not tell apart. The file is gone, it
        // holds no edits, a keep mine stands over the empty path, and
        // the write then fails for a reason of its own. The row is not
        // found, clean and in no conflict, which is also what a save
        // refused for being not found leaves, so only the core's reason
        // can choose the sentence.
        let fixture = try makeFixture()
        let (launched, url, _, id) = try strandedFile(in: fixture)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertTrue(launched.client.resolveFileKeepMine(id))
        // A staging directory that is not there fails the core's own
        // write and nothing else about the save.
        let absent = fixture.workspace.appendingPathComponent("no-such-staging", isDirectory: true)
        launched.model.fileCoordinator.makeStagingDirectory = { _ in absent }
        launched.model.notice = nil

        XCTAssertFalse(launched.model.saveFile(id))

        guard case .write(let detail)? = launched.client.saveFileRefusal() else {
            return XCTFail("the core refused for the write, and says so")
        }
        XCTAssertFalse(detail.isEmpty, "the kind of failure travels with the reason")
        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertTrue(row.notFound)
        XCTAssertFalse(row.isDirty)
        XCTAssertEqual(row.conflict, FileConflict.none)
        XCTAssertEqual(
            launched.model.notice, PageModel.writeRefusalNotice(name: "notes.txt"),
            "the sentence follows the reason and not the row")
        XCTAssertEqual(launched.model.noticeTone, .actionable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        assertBalanced(launched.scope)
    }

    func testTheCoreSaysWhichRefusalASaveWas() throws {
        let fixture = try makeFixture()
        let (launched, url, _, id) = try strandedFile("on disk\n", in: fixture)
        XCTAssertNil(launched.client.saveFileErrorJSON(), "no save has been asked for")

        XCTAssertFalse(launched.client.saveFile(id, stagingDirectory: nil))
        XCTAssertEqual(launched.client.saveFileRefusal(), .notFound)
        XCTAssertEqual(launched.client.saveFileErrorJSON(), #"{"error":"notFound"}"#)

        // A draft over the same empty path is left in the missing
        // conflict by that refusal, and refused for the conflict after.
        try type("unsaved ", at: 0, into: id, on: launched.model)
        XCTAssertFalse(launched.client.saveFile(id, stagingDirectory: nil))
        XCTAssertEqual(launched.client.saveFileRefusal(), .notFound)
        XCTAssertFalse(launched.client.saveFile(id, stagingDirectory: nil))
        XCTAssertEqual(launched.client.saveFileRefusal(), .conflict)

        XCTAssertFalse(launched.client.saveFile(CompanionClient.fileIDTag | 4096, stagingDirectory: nil))
        XCTAssertEqual(launched.client.saveFileRefusal(), .unknownFile)

        // A save that writes leaves nothing to explain.
        XCTAssertTrue(launched.client.resolveFileKeepMine(id))
        XCTAssertTrue(launched.client.saveFile(id, stagingDirectory: nil))
        XCTAssertNil(launched.client.saveFileRefusal())
        XCTAssertEqual(try read(url), "unsaved on disk\n")
    }

    func testSaveAsOntoAnOpenFileIsRefusedByTheCoreAndNamedFromItsReason() throws {
        let fixture = try makeFixture()
        let (launched, _, id) = try openedFile(in: fixture)
        let taken = try write("taken\n", named: "taken.txt", in: fixture)
        launched.model.openFile(at: taken)
        launched.model.selectFile(id)
        launched.panels.destinationURL = taken
        launched.model.notice = nil
        launched.journal.clear()

        launched.model.saveActiveFileAs()

        XCTAssertTrue(
            launched.journal.events.contains("saveAs"),
            "the core is asked, and it is the core that refuses")
        XCTAssertEqual(launched.client.saveFileRefusal(), .pathInUse)
        XCTAssertEqual(launched.model.notice, PageModel.pathInUseNotice(name: "taken.txt"))
        XCTAssertEqual(launched.model.noticeTone, .plain)
        XCTAssertEqual(try read(taken), "taken\n", "nothing was written to it")
        XCTAssertEqual(launched.model.activeFile?.name, "notes.txt", "the identity did not move")
        for staging in launched.client.stagingDirectories.compactMap({ $0 }) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging))
        }
        assertBalanced(launched.scope)
    }

    func testTheSaveRefusalSentenceIsChosenFromTheReason() {
        func row(
            dirty: Bool = false, conflict: FileConflict = .none, notFound: Bool = false,
            accessRefused: Bool = false
        ) -> FileSummary {
            FileSummary(
                id: CompanionClient.fileIDTag | 1, name: "a.txt", path: "/tmp/a.txt",
                isDirty: dirty, conflict: conflict, lineEnding: .lf, hasBOM: false,
                lastEditedAt: 0, restoredFromDraft: false,
                accessRefused: accessRefused, notFound: notFound
            )
        }
        let gone = row(notFound: true)
        let missing = row(dirty: true, conflict: .missing, notFound: true)
        let changed = row(dirty: true, conflict: .changed)

        // The same row, two reasons, two sentences.
        XCTAssertEqual(
            PageModel.saveRefusalNotice(.notFound, for: gone),
            PageModel.saveNotFoundNotice(name: "a.txt"))
        XCTAssertEqual(
            PageModel.saveRefusalNotice(.write(detail: "permission denied"), for: gone),
            PageModel.writeRefusalNotice(name: "a.txt"))

        XCTAssertEqual(
            PageModel.saveRefusalNotice(.notFound, for: missing),
            PageModel.unresolvedConflictNotice(for: missing),
            "a draft left in the missing conflict is owed the sentence that offers keep mine")
        XCTAssertEqual(
            PageModel.saveRefusalNotice(.conflict, for: changed),
            PageModel.unresolvedConflictNotice(name: "a.txt"))
        XCTAssertEqual(
            PageModel.saveRefusalNotice(.conflict, for: missing),
            PageModel.unresolvedConflictNotice(for: missing))
        XCTAssertEqual(
            PageModel.saveRefusalNotice(.pendingHydration, for: gone),
            PageModel.heldFileNotice(name: "a.txt"))
        for reason: FileSaveRefusal? in [.unknownFile, .pathInUse, nil] {
            XCTAssertEqual(
                PageModel.saveRefusalNotice(reason, for: gone),
                PageModel.writeRefusalNotice(name: "a.txt"),
                "a reason with no sentence of its own is the write that did not land")
        }

        let inUse = PageModel.saveAsRefusalNotice(
            .pathInUse, file: "a.txt", target: "b.txt", holder: "held.txt")
        XCTAssertEqual(inUse.text, PageModel.pathInUseNotice(name: "held.txt"))
        XCTAssertEqual(inUse.tone, .plain)
        XCTAssertEqual(
            PageModel.saveAsRefusalNotice(.pathInUse, file: "a.txt", target: "b.txt", holder: nil).text,
            PageModel.pathInUseNotice(name: "b.txt"))
        let held = PageModel.saveAsRefusalNotice(
            .pendingHydration, file: "a.txt", target: "b.txt", holder: nil)
        XCTAssertEqual(held.text, PageModel.heldFileNotice(name: "a.txt"))
        XCTAssertEqual(held.tone, .actionable)
        for reason: FileSaveRefusal? in [.write(detail: "x"), .conflict, .notFound, .unknownFile, nil] {
            let sentence = PageModel.saveAsRefusalNotice(
                reason, file: "a.txt", target: "b.txt", holder: nil)
            XCTAssertEqual(sentence.text, PageModel.writeRefusalNotice(name: "b.txt"))
            XCTAssertEqual(sentence.tone, .actionable)
        }
    }

    func testASaveRefusalIsReadFromTheCoresJSONAndAnUnknownOneIsNoReason() {
        XCTAssertEqual(FileSaveRefusal(json: #"{"error":"pendingHydration"}"#), .pendingHydration)
        XCTAssertEqual(FileSaveRefusal(json: #"{"error":"conflict"}"#), .conflict)
        XCTAssertEqual(FileSaveRefusal(json: #"{"error":"notFound"}"#), .notFound)
        XCTAssertEqual(FileSaveRefusal(json: #"{"error":"pathInUse"}"#), .pathInUse)
        XCTAssertEqual(FileSaveRefusal(json: #"{"error":"unknownFile"}"#), .unknownFile)
        XCTAssertEqual(
            FileSaveRefusal(json: #"{"error":"write","detail":"permission denied"}"#),
            .write(detail: "permission denied"))
        XCTAssertEqual(FileSaveRefusal(json: #"{"error":"write"}"#), .write(detail: ""))
        XCTAssertNil(FileSaveRefusal(json: nil))
        XCTAssertNil(FileSaveRefusal(json: "not json"))
        XCTAssertNil(FileSaveRefusal(json: #"{"error":"somethingNewer"}"#))
    }

    func testSaveAsOntoTheFilesOwnNameWritesItWhenNothingIsThere() throws {
        // The way out that makes a file: the person chose this
        // destination in a panel, which a bare save never had.
        let fixture = try makeFixture()
        let (launched, url, moved, id) = try strandedFile(in: fixture)
        XCTAssertFalse(launched.model.saveFile(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        launched.panels.destinationURL = url
        launched.journal.clear()

        launched.model.saveActiveFileAs()

        XCTAssertEqual(try read(url), "body\n", "the file is written where the person said")
        XCTAssertEqual(try read(moved), "body\n", "and the one that was moved away is untouched")
        XCTAssertEqual(
            launched.journal.events,
            ["start notes.txt", "saveAs", "bookmark", "stop notes.txt"],
            "a save as inside the panel's bracket, and not the save a missing file refuses")
        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertFalse(row.notFound)
        XCTAssertFalse(FileUnavailableBanner.stands(for: row))
        XCTAssertTrue(PageModel.samePath(row.path, url.path))
        assertBalanced(launched.scope)
    }

    // MARK: A held file has nothing of its own to lose

    func testClosingAHeldFileClosesItAtOnce() throws {
        let fixture = try makeFixture()
        let (held, _, id) = try heldFile(in: fixture)

        held.model.closeFile(id)

        XCTAssertNil(held.model.pendingFileClose)
        XCTAssertTrue(held.model.openFiles.isEmpty)
        XCTAssertTrue(held.client.fileRoster().isEmpty, "the core let it go")
    }

    func testClosingAHeldFileWhoseRecordReadsDirtyNeverAsksTheDirtyCloseDecision() throws {
        // A record whose draft was too large to keep comes back dirty
        // with no draft behind it, and when the system then refuses the
        // read it is held still reading dirty. Its buffer is empty. The
        // decision offers to save, discard or keep editing, and there
        // is nothing here any of the three could act on.
        let fixture = try makeFixture()
        let (held, url, id) = try heldFile(in: fixture)
        held.client.restatesRow = { row in
            guard row.isHeld else { return row }
            return FileSummary(
                id: row.id, name: row.name, path: row.path, isDirty: true,
                conflict: row.conflict, lineEnding: row.lineEnding, hasBOM: row.hasBOM,
                lastEditedAt: 1_756_900_000, restoredFromDraft: row.restoredFromDraft,
                externallyReloaded: row.externallyReloaded,
                pendingHydration: row.pendingHydration, accessRefused: row.accessRefused,
                notFound: row.notFound)
        }
        held.model.refreshOpenFiles()
        let row = try XCTUnwrap(held.model.openFiles.first)
        XCTAssertTrue(row.isHeld)
        XCTAssertTrue(row.isDirty, "the record says dirty")
        XCTAssertFalse(row.holdsUnsavedEdits, "and holds nothing")
        XCTAssertEqual(FileHeaderState.derive(from: row).saveWord, "not read")
        XCTAssertNil(
            PageModel.draftsAtRiskSentence(files: [row]),
            "there are no unsaved changes of this file's to lose")

        // By the row's close button, with another surface showing.
        held.model.closeFile(id)

        XCTAssertNil(held.model.pendingFileClose, "no decision was published")
        XCTAssertTrue(held.model.openFiles.isEmpty, "the tab closed at once")
        XCTAssertTrue(held.client.fileRoster().isEmpty)
        try unlock(url)
        XCTAssertEqual(try read(url), "body\n", "and the file on disk is as it was")
    }

    func testClosingTheSelectedHeldFileWhoseRecordReadsDirtyAlsoClosesAtOnce() throws {
        let fixture = try makeFixture()
        let (held, _, id) = try heldFile(in: fixture)
        held.client.restatesRow = { row in
            guard row.isHeld else { return row }
            return FileSummary(
                id: row.id, name: row.name, path: row.path, isDirty: true,
                conflict: row.conflict, lineEnding: row.lineEnding, hasBOM: row.hasBOM,
                lastEditedAt: row.lastEditedAt, restoredFromDraft: row.restoredFromDraft,
                externallyReloaded: row.externallyReloaded,
                pendingHydration: row.pendingHydration, accessRefused: row.accessRefused,
                notFound: row.notFound)
        }
        held.model.refreshOpenFiles()
        held.model.selectFile(id)
        XCTAssertEqual(held.model.activeFile?.id, id)

        // By the close chord, which closes the file that is showing.
        XCTAssertTrue(held.model.closeActiveFile(), "closed, with nothing asked")

        XCTAssertNil(held.model.pendingFileClose)
        XCTAssertTrue(held.model.openFiles.isEmpty)
    }

    func testAnOrdinaryDirtyFileStillGetsTheDirtyCloseDecision() throws {
        // The rule above is for a held file only.
        let fixture = try makeFixture()
        let (launched, _, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)

        launched.model.closeFile(id)

        XCTAssertEqual(launched.model.pendingFileClose?.fileID, id)
        XCTAssertEqual(launched.model.openFiles.count, 1)
    }

    // MARK: A draft whose file cannot be read, across an activation

    func testACleanMatchingWitnessFirstDenialIsPublishedOnActivation() throws {
        try assertMatchingWitnessFirstDenialIsPublished(dirty: false)
    }

    func testADirtyMatchingWitnessFirstDenialIsPublishedOnActivation() throws {
        try assertMatchingWitnessFirstDenialIsPublished(dirty: true)
    }

    private func assertMatchingWitnessFirstDenialIsPublished(dirty: Bool) throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode 000 file, so there is nothing to refuse")
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile("on disk\n", in: fixture)
        if dirty { try type("unsaved ", at: 0, into: id, on: launched.model) }
        let text = launched.model.storage(for: id).string
        let before = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertFalse(before.accessRefused)
        XCTAssertFalse(before.notFound)
        XCTAssertEqual(before.conflict, .none)
        try lock(url) // permissions change, not the content witness
        launched.journal.clear()
        launched.client.checkStates.removeAll()

        launched.model.checkOpenFilesOnActivate()

        XCTAssertEqual(launched.client.checkStates, [.unchanged], "the disk witness still matches")
        XCTAssertEqual(launched.journal.events, ["start notes.txt", "check", "stop notes.txt"])
        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row, launched.client.fileRoster().first, "the first denial reaches the published roster")
        XCTAssertTrue(row.accessRefused)
        XCTAssertFalse(row.notFound)
        XCTAssertFalse(row.pendingHydration)
        XCTAssertEqual(row.isDirty, dirty)
        XCTAssertEqual(row.conflict, dirty ? .changed : .none)
        XCTAssertEqual(FileUnavailableBanner.stands(for: row), !dirty)
        if dirty {
            XCTAssertEqual(FileConflictBanner.actions(for: row), [.locate, .keepMine, .saveAs])
        }
        XCTAssertEqual(launched.model.storage(for: id).string, text, "the check does not replace the buffer")
        assertBalanced(launched.scope)
    }

    func testADraftWhoseFileCannotBeReadStaysInItsConflictThroughAnActivation() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode 000 file, so there is nothing to refuse")
        let fixture = try makeFixture()
        let url = try write("on disk\n", named: "notes.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: url)
        let firstID = try XCTUnwrap(first.model.openFiles.first?.id)
        try type("unsaved ", at: 0, into: firstID, on: first.model)
        XCTAssertTrue(first.model.saveState())
        try lock(url)
        let second = launch(fixture)
        let id = try XCTUnwrap(second.model.openFiles.first?.id)
        XCTAssertEqual(second.model.openFiles.first?.conflict, .changed)
        second.journal.clear()

        // The stat answers and matches the record, and the read is
        // still refused: the launch and the activation after it must
        // say the same thing about the same disk.
        second.model.checkOpenFilesOnActivate()

        let row = try XCTUnwrap(second.model.openFiles.first)
        XCTAssertTrue(row.accessRefused)
        XCTAssertEqual(row.conflict, .changed, "the conflict the launch set is not undone by a stat")
        XCTAssertEqual(FileConflictBanner.actions(for: row), [.locate, .keepMine, .saveAs])
        XCTAssertFalse(FileUnavailableBanner.stands(for: row))

        XCTAssertFalse(second.model.saveFile(id), "a copy nobody read is not saved over")
        XCTAssertEqual(second.model.notice, PageModel.unresolvedConflictNotice(for: row))
        XCTAssertFalse(second.journal.events.contains("save"), "the core was not even asked")
        try unlock(url)
        XCTAssertEqual(try read(url), "on disk\n")
        assertBalanced(second.scope)
    }

    func testARefusedTakeTheirsRestatesTheRowSoTheBannerOffersLocateInstead() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode 000 file, so there is nothing to refuse")
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile("on disk\n", in: fixture)
        try type("unsaved ", at: 0, into: id, on: launched.model)
        try Data("theirs\n".utf8).write(to: url)
        launched.model.checkOpenFilesOnActivate()
        launched.model.selectFile(id)
        let before = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(before.conflict, .changed)
        XCTAssertEqual(FileConflictBanner.actions(for: before), [.keepMine, .takeTheirs, .saveAs])
        try lock(url)

        launched.model.resolveConflict(.takeTheirs)

        XCTAssertEqual(launched.model.notice, PageModel.readRefusalNotice(name: "notes.txt"))
        let after = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertTrue(after.accessRefused, "the refused read is on the published row")
        XCTAssertEqual(
            FileConflictBanner.actions(for: after), [.locate, .keepMine, .saveAs],
            "the action that has just failed is withdrawn, and Locate is offered")
        XCTAssertEqual(launched.model.storage(for: id).string, "unsaved on disk\n", "the draft stands")
        assertBalanced(launched.scope)
    }

    // MARK: An activation while a file panel is up

    /// Panels that behave as the real ones do while they are up: the
    /// answer comes back from inside a modal bracket, and the app can
    /// be activated before it does.
    private final class ActivatingFilePanels: FilePanels {
        var url: URL?
        var whileThePanelIsUp: () -> Void = {}
        /// Use the production centre so the model hears the modal end
        /// before the gesture processes the panel's answer.
        private let center = NotificationCenter.default

        private func answer() -> URL? {
            ModalSession.run(center: center) {
                whileThePanelIsUp()
                return url
            }
        }

        func chooseFileToOpen() -> URL? { answer() }
        func chooseDestination(suggestedName: String) -> URL? { answer() }
        func chooseFileToLocate(named name: String, in directory: URL) -> URL? { answer() }
    }

    func testAnActivationWhileTheLocatePanelIsUpWaitsForTheLocateToFinish() throws {
        let fixture = try makeFixture()
        let (held, url, id) = try heldFile(in: fixture)
        // The file went somewhere no bookmark follows it, which is why
        // the person is locating it. Asked now, the launch's question
        // would find nothing at the recorded path and drop the row.
        XCTAssertTrue(held.client.setFileBookmark(id, base64: ""))
        let found = fixture.workspace.appendingPathComponent("found.txt")
        try FileManager.default.moveItem(at: url, to: found)
        try unlock(found)
        let panels = ActivatingFilePanels()
        panels.url = found
        var rowsSeenFromInsideThePanel: [UInt64] = []
        panels.whileThePanelIsUp = {
            // The person went to the Finder to look, and came back.
            held.model.checkOpenFilesOnActivate()
            rowsSeenFromInsideThePanel = held.model.openFiles.map(\.id)
        }
        held.model.fileCoordinator = FileCoordinator(panels: panels, scope: held.scope)
        held.journal.clear()

        held.model.locateFile(id)

        XCTAssertEqual(rowsSeenFromInsideThePanel, [id], "the row the panel is about was left alone")
        XCTAssertEqual(
            held.journal.events.prefix(4),
            ["start found.txt", "relocate", "bookmark", "stop found.txt"],
            "nothing was asked of the core until the panel had answered")
        XCTAssertEqual(
            Array(held.journal.events.dropFirst(4)),
            ["start found.txt", "check", "stop found.txt"],
            "and the check that was put off is made once, afterwards")
        let row = try XCTUnwrap(held.model.openFiles.first, "the tab is still there")
        XCTAssertEqual(row.id, id)
        XCTAssertFalse(row.pendingHydration)
        XCTAssertTrue(PageModel.samePath(row.path, found.path))
        XCTAssertEqual(held.model.storage(for: id).string, "body\n")
        XCTAssertNil(held.model.notice, "nothing is said about a file that is fine")
        assertBalanced(held.scope)
    }

    func testAPanelRefusalNoticeSurvivesTheOwedActivationCheck() throws {
        let fixture = try makeFixture()
        let (launched, _, _) = try openedFile(in: fixture)
        let refused = try write("", named: "binary.txt", in: fixture)
        try Data([0, 1, 2]).write(to: refused)
        let panels = ActivatingFilePanels()
        panels.url = refused
        panels.whileThePanelIsUp = { launched.model.checkOpenFilesOnActivate() }
        launched.model.fileCoordinator = FileCoordinator(panels: panels, scope: launched.scope)

        launched.model.openFile()

        XCTAssertEqual(launched.journal.events.filter { $0 == "check" }.count, 1)
        XCTAssertEqual(launched.model.notice,
                       PageModel.openRefusalNotice(name: "binary.txt", json: launched.client.openFileErrorJSON()))
    }

    func testAnActivationOutsideAnyPanelIsNotPutOff() throws {
        let fixture = try makeFixture()
        let (launched, _, _) = try openedFile(in: fixture)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.journal.events, ["start notes.txt", "check", "stop notes.txt"])
    }

    func testANonFileModalEndImmediatelyConsumesAnOwedCheckOnce() throws {
        let fixture = try makeFixture()
        let (launched, _, _) = try openedFile(in: fixture)
        ModalSession.run {
            ModalSession.run {
                launched.model.checkOpenFilesOnActivate()
                launched.model.checkOpenFilesOnActivate()
                XCTAssertTrue(launched.journal.events.isEmpty)
            }
            XCTAssertTrue(launched.journal.events.isEmpty, "inner end must not reenter the outer modal")
        }
        XCTAssertEqual(launched.journal.events, ["start notes.txt", "check", "stop notes.txt"])
        launched.journal.clear()
        ModalSession.run {}
        launched.model.openFile() // cancelled panel
        XCTAssertTrue(launched.journal.events.isEmpty, "the owed check was consumed, not left armed")
    }

    func testAModalEndWithoutAnActivationDoesNotCheckFiles() throws {
        let fixture = try makeFixture()
        let (launched, _, _) = try openedFile(in: fixture)
        ModalSession.run {}
        XCTAssertTrue(launched.journal.events.isEmpty)
    }

    func testAnActualActivationClearsTheCheckOwedByANonFileModal() throws {
        let fixture = try makeFixture()
        let (launched, _, _) = try openedFile(in: fixture)
        ModalSession.run(center: NotificationCenter()) {
            launched.model.checkOpenFilesOnActivate()
        }

        XCTAssertFalse(launched.journal.events.contains("check"))
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.journal.events.filter { $0 == "check" }.count, 1)
        launched.journal.clear()
        launched.model.openFile() // cancelled panel
        XCTAssertTrue(launched.journal.events.isEmpty)
    }

    func testARefusedOpenAfterHydrationDropsTheRecordedRow() throws {
        let fixture = try makeFixture()
        let (held, url, _) = try heldFile(in: fixture)
        XCTAssertTrue(held.model.saveState())
        XCTAssertFalse(held.model.draftsDirty)
        try unlock(url)
        try Data([0, 1, 2]).write(to: url)
        held.model.openFile(at: url)
        XCTAssertTrue(held.model.openFiles.isEmpty)
        XCTAssertTrue(held.model.draftsDirty)
        XCTAssertTrue(held.model.saveState())
        let next = launch(fixture)
        XCTAssertTrue(next.model.openFiles.isEmpty)
        XCTAssertNil(next.model.notice)
        assertBalanced(held.scope)
    }

    func testARefusedOrdinaryOpenDoesNotDirtyTheRoster() throws {
        let fixture = try makeFixture()
        let launched = launch(fixture)
        let url = fixture.workspace.appendingPathComponent("binary.dat")
        try Data([0, 1, 2]).write(to: url)
        launched.model.openFile(at: url)
        XCTAssertFalse(launched.model.draftsDirty)
    }

    func testKeepMineRefusalReportsTheNewConflict() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try type("mine ", at: 0, into: id, on: launched.model)
        try FileManager.default.removeItem(at: url)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.model.openFiles.first?.conflict, .missing)
        try Data("replacement, longer\n".utf8).write(to: url)
        launched.model.resolveConflict(.keepMine)
        let row = try XCTUnwrap(launched.model.openFiles.first)
        XCTAssertEqual(row.conflict, .changed)
        XCTAssertEqual(launched.model.notice,
                       "Keep mine could not be applied. " + PageModel.unresolvedConflictNotice(for: row))
        XCTAssertEqual(launched.model.noticeTone, .actionable)
        XCTAssertEqual(launched.model.storage(for: id).string, "mine body\n")
        XCTAssertEqual(try read(url), "replacement, longer\n")
    }

    func testSuccessfulReloadRenewsANonStaleBookmarkAndPersistsIt() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        XCTAssertTrue(launched.model.saveState())
        var renewals = 0
        let bookmark = launched.model.fileCoordinator.makeBookmark
        launched.model.fileCoordinator.makeBookmark = { url in
            renewals += 1
            XCTAssertEqual(launched.scope.depth, 1)
            return try bookmark(url)
        }
        try Data("new contents, longer\n".utf8).write(to: url)
        let data = try XCTUnwrap(launched.client.fileBookmarkBase64(id).flatMap { Data(base64Encoded: $0) })
        let stale = launched.model.fileCoordinator.withAccess(toBookmark: data) { $0.isStale }
        XCTAssertEqual(stale, false)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(renewals, 1)
        XCTAssertFalse(try XCTUnwrap(launched.model.openFiles.first).externallyReloaded)
        XCTAssertTrue(launched.model.draftsDirty)
        XCTAssertTrue(launched.model.saveState())
        let next = launch(fixture)
        XCTAssertEqual(next.model.storage(for: id).string, "new contents, longer\n")
        assertBalanced(launched.scope)
    }

    func testAtomicReplacementReloadRenewsBeforeTheBracketCloses() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        XCTAssertTrue(launched.model.saveState())
        try Data("atomic replacement, longer\n".utf8).write(to: url, options: .atomic)
        launched.model.checkOpenFilesOnActivate()
        let events = launched.journal.events
        let reload = try XCTUnwrap(events.firstIndex(of: "reload"))
        let renewed = try XCTUnwrap(events.lastIndex(of: "bookmark"))
        XCTAssertGreaterThan(renewed, reload)
        XCTAssertEqual(events.last, "stop notes.txt")
        XCTAssertEqual(launched.model.storage(for: id).string, "atomic replacement, longer\n")
        XCTAssertTrue(launched.model.draftsDirty)
        assertBalanced(launched.scope)
    }

    func testReloadBeforeSaveRenewsForBothTheReadAndTheWrite() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        try Data("external contents, longer\n".utf8).write(to: url)
        XCTAssertTrue(launched.model.saveFile(id))
        XCTAssertEqual(launched.journal.events,
                       ["start notes.txt", "check", "reload", "bookmark", "save", "bookmark", "stop notes.txt"])
        XCTAssertEqual(try read(url), "external contents, longer\n")
        assertBalanced(launched.scope)
    }

    func testUnchangedAndDirtyChangedChecksDoNotRenewAFreshBookmark() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertFalse(launched.journal.events.contains("bookmark"))
        try type("mine ", at: 0, into: id, on: launched.model)
        try Data("external contents, longer\n".utf8).write(to: url)
        launched.journal.clear()
        launched.model.checkOpenFilesOnActivate()
        XCTAssertFalse(launched.journal.events.contains("reload"))
        XCTAssertFalse(launched.journal.events.contains("bookmark"))
        XCTAssertEqual(launched.model.openFiles.first?.conflict, .changed)
    }

    func testFailedBookmarkRenewalAfterReloadKeepsThePreviousBookmark() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        XCTAssertTrue(launched.model.saveState())
        let before = launched.client.fileBookmarkBase64(id)
        launched.model.fileCoordinator.makeBookmark = { _ in throw CocoaError(.fileReadUnknown) }
        try Data("external contents, longer\n".utf8).write(to: url)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertEqual(launched.client.fileBookmarkBase64(id), before)
        XCTAssertFalse(launched.model.draftsDirty)
        XCTAssertEqual(launched.model.storage(for: id).string, "external contents, longer\n")
        XCTAssertEqual(launched.model.notice, PageModel.reloadedNotice(name: "notes.txt"))
        assertBalanced(launched.scope)
    }

    func testHolderNewsAndBookmarkFailureAreBothReported() {
        XCTAssertEqual(PageModel.activationNotice([.reloaded("b.txt"), .bookmarkFailed("b.txt")]),
                       PageModel.reloadedNotice(name: "b.txt") + " "
                       + PageModel.bookmarkFailureNotice(name: "b.txt"))
    }

    func testFailedReloadDoesNotRenewTheBookmark() throws {
        let fixture = try makeFixture()
        let (launched, url, id) = try openedFile(in: fixture)
        XCTAssertTrue(launched.model.saveState())
        let before = launched.client.fileBookmarkBase64(id)
        try Data([0, 1, 2]).write(to: url)
        launched.model.checkOpenFilesOnActivate()
        XCTAssertTrue(launched.journal.events.contains("reload"))
        XCTAssertFalse(launched.journal.events.contains("bookmark"))
        XCTAssertEqual(launched.client.fileBookmarkBase64(id), before)
        XCTAssertFalse(launched.model.draftsDirty)
        XCTAssertEqual(launched.model.storage(for: id).string, "body\n")
    }

    func testLocateReportsAHoldersBookmarkFailureBesideTheRefusal() throws {
        try XCTSkipIf(getuid() == 0, "root reads mode 000 files")
        let fixture = try makeFixture()
        let a = try write("a\n", named: "a.txt", in: fixture)
        let b = try write("b\n", named: "b.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: a)
        first.model.openFile(at: b)
        XCTAssertTrue(first.model.saveState())
        try lock(a)
        try lock(b)
        let second = launch(fixture)
        let ids = second.model.openFiles.map(\.id)
        try unlock(b)
        second.panels.locateURL = b
        second.model.fileCoordinator.makeBookmark = { _ in throw CocoaError(.fileReadUnknown) }
        second.model.locateFile(ids[0])
        XCTAssertEqual(second.model.notice,
                       PageModel.locateHeldNotice(name: "a.txt", holder: "b.txt") + " "
                       + PageModel.bookmarkFailureNotice(name: "b.txt"))
        XCTAssertEqual(second.client.fileBookmarkBase64(ids[1]), "")
        XCTAssertFalse(second.model.openFiles[1].pendingHydration)
        XCTAssertTrue(second.model.draftsDirty)
        XCTAssertTrue(second.model.saveState())
        assertBalanced(second.scope)
    }

    // MARK: Locating onto a path a held file holds

    func testLocatingOntoAHeldFilesPathSettlesThatFileInsideThePanelsGrant() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode 000 file, so there is nothing to refuse")
        let fixture = try makeFixture()
        let a = try write("a\n", named: "a.txt", in: fixture)
        let b = try write("b\n", named: "b.txt", in: fixture)
        let first = launch(fixture)
        first.model.openFile(at: a)
        first.model.openFile(at: b)
        XCTAssertTrue(first.model.saveState())
        try lock(a)
        try lock(b)
        let second = launch(fixture)
        XCTAssertEqual(second.model.openFiles.map(\.isHeld), [true, true])
        let ids = second.model.openFiles.map(\.id)
        // The panel the person answers in is what lets b be read.
        try unlock(b)
        second.model.selectFile(ids[0])
        second.panels.locateURL = b
        second.journal.clear()

        second.model.locateFile(ids[0])

        XCTAssertEqual(
            second.journal.events, ["start b.txt", "hydrate", "bookmark", "stop b.txt"],
            "the holder is asked again inside the panel's bracket and given a bookmark there")
        let rows = second.model.openFiles
        XCTAssertEqual(rows.map(\.id), ids)
        XCTAssertTrue(rows[0].isHeld, "the file that was being located is as it was")
        XCTAssertFalse(rows[1].pendingHydration, "and the tab the chosen file belongs to came to life")
        XCTAssertFalse(rows[1].accessRefused)
        XCTAssertEqual(second.model.storage(for: ids[1]).string, "b\n")
        XCTAssertEqual(
            second.model.notice, PageModel.locateHeldNotice(name: "a.txt", holder: "b.txt"))
        XCTAssertTrue(second.model.draftsDirty)
        assertBalanced(second.scope)
    }

    // MARK: The roster's optional keys

    func testARosterRowWithoutTheLaterFlagsStillDecodes() throws {
        // A default on the property does not make a key optional on the
        // wire; the decoder is what does. One row without the three
        // flags, as a core that predates them would send it.
        let json = """
            [{"id": 9223372036854775809, "name": "a.txt", "path": "/tmp/a.txt",
              "isDirty": true, "conflict": "changed", "lineEnding": "crlf",
              "hasBOM": true, "lastEditedAt": 7, "restoredFromDraft": true}]
            """
        let rows = try JSONDecoder().decode([FileSummary].self, from: Data(json.utf8))
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, CompanionClient.fileIDTag | 1)
        XCTAssertEqual(row.name, "a.txt")
        XCTAssertTrue(row.isDirty)
        XCTAssertEqual(row.conflict, .changed)
        XCTAssertEqual(row.lineEnding, .crlf)
        XCTAssertTrue(row.hasBOM)
        XCTAssertEqual(row.lastEditedAt, 7)
        XCTAssertTrue(row.restoredFromDraft)
        XCTAssertFalse(row.externallyReloaded)
        XCTAssertFalse(row.pendingHydration)
        XCTAssertFalse(row.accessRefused)
        XCTAssertFalse(row.notFound)

        // And a row that carries them reads them, through the same path.
        let full = """
            [{"id": 9223372036854775809, "name": "a.txt", "path": "/tmp/a.txt",
              "isDirty": false, "conflict": "none", "lineEnding": "lf",
              "hasBOM": false, "lastEditedAt": 0, "restoredFromDraft": true,
              "externallyReloaded": true, "pendingHydration": true, "accessRefused": true,
              "notFound": true}]
            """
        let held = try XCTUnwrap(
            try JSONDecoder().decode([FileSummary].self, from: Data(full.utf8)).first)
        XCTAssertTrue(held.externallyReloaded)
        XCTAssertTrue(held.isHeld)
        XCTAssertTrue(held.notFound)

        // A required key that is absent is still an error.
        XCTAssertThrowsError(
            try JSONDecoder().decode([FileSummary].self, from: Data(#"[{"id": 1}]"#.utf8)))
    }

    // MARK: The sentence

    func testTheLocateSentencesNameTheFileAndArePlain() {
        let sentences = [
            PageModel.heldFileNotice(name: "notes.txt"),
            PageModel.locateHeldNotice(name: "notes.txt", holder: "b.txt"),
            SystemFilePanels.locateMessage(named: "notes.txt"),
        ]
        XCTAssertEqual(
            sentences[0],
            "notes.txt has not been read, so there is nothing to save. Locate the file or close the tab.")
        XCTAssertEqual(
            sentences[1],
            "b.txt is already open, so notes.txt was not pointed at it. "
                + "Close it first, or choose another file.")
        XCTAssertEqual(sentences[2], "Choose where notes.txt is now.")
        for sentence in sentences {
            XCTAssertFalse(sentence.contains("\u{2014}"))
            XCTAssertFalse(sentence.contains("\u{2013}"))
        }
    }

    func testTheBookmarkFailureSentenceNamesTheFileAndIsPlain() {
        let sentence = PageModel.bookmarkFailureNotice(name: "notes.txt")
        XCTAssertEqual(
            sentence,
            "notes.txt may not reopen after a relaunch, because access to it could not be kept.")
        XCTAssertFalse(sentence.contains("\u{2014}"))
        XCTAssertFalse(sentence.contains("\u{2013}"))
    }
}
