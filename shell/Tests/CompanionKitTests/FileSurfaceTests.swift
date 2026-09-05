import XCTest

@testable import CompanionKit

/// The file surface: what the header says, what a row says out loud,
/// which drops are taken, where a file sits in the visible order, and
/// which reading the two shared chords take (ADR-0028).
///
/// Model level and pure functions only. The views are drawings of the
/// answers below, and the answers are what a reviewer can check.
///
/// Every model here is `isolatedModel`: a directory made for the test
/// and an in-process credential store. A model built without seams
/// under the runner resolves the installed app's own pages and ledger.
@MainActor
final class FileSurfaceTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suiteName = "companion-files-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func file(
        id: UInt64 = CompanionClient.fileIDTag | 1,
        name: String = "README.md",
        path: String = "/tmp/README.md",
        dirty: Bool = false,
        conflict: FileConflict = .none,
        lineEnding: FileLineEnding = .lf,
        lastEditedAt: UInt64 = 0,
        restoredFromDraft: Bool = false
    ) -> FileSummary {
        FileSummary(
            id: id,
            name: name,
            path: path,
            isDirty: dirty,
            conflict: conflict,
            lineEnding: lineEnding,
            hasBOM: false,
            lastEditedAt: lastEditedAt,
            restoredFromDraft: restoredFromDraft
        )
    }

    // MARK: The header

    func testACleanFileReadsAsSaved() {
        let state = FileHeaderState.derive(from: file())
        XCTAssertEqual(state.name, "README.md")
        XCTAssertEqual(state.saveWord, "saved")
        XCTAssertFalse(state.showsUnsavedDot)
        XCTAssertNil(state.lastEditStamp)
        XCTAssertEqual(state.encodingAndFormat, "UTF-8 · Markdown")
    }

    func testADirtyFileReadsAsUnsavedInWordsAndNotOnlyAsADot() {
        let state = FileHeaderState.derive(from: file(dirty: true))
        XCTAssertEqual(state.saveWord, "unsaved")
        XCTAssertTrue(state.showsUnsavedDot)
        XCTAssertTrue(state.spoken.contains("unsaved"))
    }

    /// The whole of what the app owes for quitting without a save
    /// sheet: the age of the typing, before the save chord is pressed.
    func testARestoredDraftStatesTheTimeOfItsLastEdit() {
        let state = FileHeaderState.derive(
            from: file(dirty: true, lastEditedAt: 1_756_900_000, restoredFromDraft: true))
        let stamp = try? XCTUnwrap(state.lastEditStamp)
        XCTAssertEqual(stamp, FileHeaderState.editStamp(unixSeconds: 1_756_900_000))
        XCTAssertTrue(state.spoken.contains("last edited"))
    }

    /// A file dirtied in this session shows no stamp: its age is the
    /// last few minutes and the person already knows it.
    func testAFileDirtiedThisSessionCarriesNoStamp() {
        let state = FileHeaderState.derive(from: file(dirty: true, lastEditedAt: 1_756_900_000))
        XCTAssertNil(state.lastEditStamp)
    }

    func testTheFormatComesFromTheExtension() {
        XCTAssertEqual(FileHeaderState.format(forName: "notes.txt"), "Plain text")
        XCTAssertEqual(FileHeaderState.format(forName: "README.MD"), "Markdown")
        XCTAssertEqual(FileHeaderState.format(forName: "Makefile"), "Plain text")
    }

    /// Line endings are shown only when they are not LF, which is the
    /// specification's rule and the reason the label is not always
    /// three facts long.
    func testCRLFIsNamedAndLFIsNot() {
        XCTAssertEqual(
            FileHeaderState.derive(from: file(name: "notes.txt")).encodingAndFormat,
            "UTF-8 · Plain text")
        XCTAssertEqual(
            FileHeaderState.derive(from: file(name: "notes.txt", lineEnding: .crlf))
                .encodingAndFormat,
            "UTF-8 · Plain text · CRLF")
    }

    // MARK: Rows, spoken

    func testARowNamesItsFileAndItsSaveStateInWords() {
        XCTAssertEqual(FileRowLabel.spoken(for: file()), "file, README.md, saved")
        XCTAssertEqual(
            FileRowLabel.spoken(for: file(dirty: true)), "file, README.md, unsaved")
        XCTAssertEqual(
            FileRowLabel.spoken(for: file(dirty: true, conflict: .changed)),
            "file, README.md, unsaved, changed on disk")
    }

    func testTheConflictBannerNamesTheFileAndSaysSavingIsRefused() {
        let sentence = FileConflictBanner.sentence(for: .changed, name: "README.md")
        XCTAssertTrue(sentence.contains("README.md"))
        XCTAssertTrue(sentence.contains("refused"))
        XCTAssertTrue(
            FileConflictBanner.sentence(for: .missing, name: "notes.txt")
                .contains("no longer at its path"))
    }

    // MARK: Drops

    func testThePadOpensPlainTextAndMarkdownAndRefusesTheRest() {
        XCTAssertTrue(FileDropDecision.opens(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertTrue(FileDropDecision.opens(URL(fileURLWithPath: "/tmp/README.md")))
        XCTAssertTrue(FileDropDecision.opens(URL(fileURLWithPath: "/tmp/Makefile")))
        XCTAssertFalse(FileDropDecision.opens(URL(fileURLWithPath: "/tmp/shot.png")))
        XCTAssertFalse(FileDropDecision.opens(URL(fileURLWithPath: "/tmp/paper.pdf")))
        XCTAssertFalse(FileDropDecision.opens(URL(fileURLWithPath: "/tmp/archive.zip")))
    }

    func testARefusedDropSaysSoAndNamesTheItem() throws {
        let model = isolatedModel(defaults: try defaults())
        model.refuseUnsupportedDrop(name: "shot.png")
        XCTAssertEqual(model.notice, PageModel.unsupportedDropNotice(name: "shot.png"))
        XCTAssertTrue(try XCTUnwrap(model.notice).contains("shot.png"))
    }

    // MARK: Selection and the visible order

    /// The claim the whole layout rests on: a pad with no file open is
    /// the pad it has always been, in both modes.
    func testTheVisibleOrderIsUnchangedWithNoFileOpen() throws {
        let model = isolatedModel(defaults: try defaults())
        model.perform(.pageNew)
        model.perform(.pageNew)
        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertEqual(model.visibleTargets, model.tabs.map { .tab($0.id) })
        model.showsTimeUnits = true
        XCTAssertEqual(
            model.visibleTargets.count, model.timeUnits.units.count,
            "a pad with no file open draws exactly its days")
    }

    func testFilesComeFirstInTheVisibleOrderInOpenOrder() throws {
        let model = isolatedModel(defaults: try defaults())
        model.perform(.pageNew)
        let first = CompanionClient.fileIDTag | 7
        let second = CompanionClient.fileIDTag | 8
        model.standOpenFiles([
            file(id: first, name: "README.md"),
            file(id: second, name: "notes.txt"),
        ])
        let targets = model.visibleTargets
        XCTAssertEqual(Array(targets.prefix(2)), [.file(first), .file(second)])
        XCTAssertEqual(targets.count, 3)
    }

    func testSelectingAFileShowsItAndSelectingATabPutsItAway() throws {
        let model = isolatedModel(defaults: try defaults())
        model.perform(.pageNew)
        let tab = try XCTUnwrap(model.tabs.first?.id)
        let id = CompanionClient.fileIDTag | 3
        model.standOpenFiles([file(id: id)])

        model.select(target: .file(id))
        XCTAssertEqual(model.selectedFile, id)
        XCTAssertEqual(model.activeTarget, .file(id))
        XCTAssertEqual(model.activeFile?.name, "README.md")
        // The slot the person left keeps its place, so going back is a
        // return rather than a new selection.
        XCTAssertEqual(model.selection, tab)

        model.select(target: .tab(tab))
        XCTAssertNil(model.selectedFile)
        XCTAssertEqual(model.activeTarget, .tab(tab))
    }

    /// ⌘1 counts the surface, and with a file open the first thing on
    /// the surface is that file.
    func testTheFirstJumpChordLandsOnTheFirstFile() throws {
        let model = isolatedModel(defaults: try defaults())
        model.perform(.pageNew)
        let id = CompanionClient.fileIDTag | 4
        model.standOpenFiles([file(id: id)])
        model.perform(.pageSelect1)
        XCTAssertEqual(model.selectedFile, id)
        model.perform(.pageSelect2)
        XCTAssertNil(model.selectedFile)
    }

    /// A closed file cannot leave the surface pointing at nothing.
    func testTheSelectionFallsAwayWhenTheFileLeavesTheRoster() throws {
        let model = isolatedModel(defaults: try defaults())
        let id = CompanionClient.fileIDTag | 5
        model.standOpenFiles([file(id: id)])
        model.select(target: .file(id))
        model.standOpenFiles([])
        XCTAssertNil(model.selectedFile)
        XCTAssertNil(model.activeFile)
    }

    func testAskingForANewPagePutsTheFileAway() throws {
        let model = isolatedModel(defaults: try defaults())
        let id = CompanionClient.fileIDTag | 6
        model.standOpenFiles([file(id: id)])
        model.select(target: .file(id))
        model.perform(.pageNew)
        XCTAssertNil(model.selectedFile)
    }

    // MARK: The two second readings

    /// ⌘S on a page flushes the sealed state, and on a file writes the
    /// file. The stubs are what says which arm ran; the point of the
    /// test is the routing, which is W3's half of the seam.
    func testTheSaveChordRoutesByWhatIsOnScreen() throws {
        let model = isolatedModel(defaults: try defaults())
        model.perform(.pageNew)
        model.notice = nil
        model.perform(.stateSaveNow)
        XCTAssertNil(model.notice, "on a page the save chord is the sealed state's, silently")

        let id = CompanionClient.fileIDTag | 9
        model.standOpenFiles([file(id: id)])
        model.select(target: .file(id))
        model.perform(.stateSaveNow)
        XCTAssertNotNil(model.notice, "on a file the save chord takes the file's arm")
    }

    func testTheCloseChordRoutesByWhatIsOnScreen() throws {
        let model = isolatedModel(defaults: try defaults())
        model.perform(.pageNew)
        model.perform(.pageNew)
        model.notice = nil
        model.perform(.pageClose)
        XCTAssertEqual(model.tabs.count, 1, "on a page the close chord closes the tab")

        let id = CompanionClient.fileIDTag | 10
        model.standOpenFiles([file(id: id)])
        model.select(target: .file(id))
        model.perform(.pageClose)
        XCTAssertEqual(model.tabs.count, 1, "on a file the close chord leaves the tabs alone")
        XCTAssertNotNil(model.notice)
    }

    /// The two new ids reach the two stubs, which is all the keymap can
    /// promise until the model lane wires the panels behind them.
    func testTheTwoNewCommandsAreTheModelsToRun() throws {
        let model = isolatedModel(defaults: try defaults())
        XCTAssertTrue(model.perform(.fileOpen))
        XCTAssertNotNil(model.notice)
        model.notice = nil
        XCTAssertTrue(model.perform(.fileSaveAs))
        XCTAssertNotNil(model.notice)
    }
}
