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
        XCTAssertEqual(state.encodingAndFormat, "UTF-8 · Plain Text")
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

    func testTheFormatComesFromTheSelectedMode() {
        XCTAssertEqual(FileHeaderState.format(for: .plainText), "Plain Text")
        XCTAssertEqual(FileHeaderState.format(for: .markdown), "Markdown")
        XCTAssertEqual(FileHeaderState.format(for: .source("swift")), "Source (Swift)")
    }

    /// Line endings are shown only when they are not LF, which is the
    /// specification's rule and the reason the label is not always
    /// three facts long.
    func testCRLFIsNamedAndLFIsNot() {
        XCTAssertEqual(
            FileHeaderState.derive(from: file(name: "notes.txt")).encodingAndFormat,
            "UTF-8 · Plain Text")
        XCTAssertEqual(
            FileHeaderState.derive(from: file(name: "notes.txt", lineEnding: .crlf))
                .encodingAndFormat,
            "UTF-8 · Plain Text · CRLF")
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

    func testTheDirtyCloseActionsAreOrderedByOutcomeWithKeepEditingLastAndDefault() {
        XCTAssertEqual(
            FileCloseAction.allCases.map(\.label),
            ["Save edits", "Keep saved file", "Keep editing"]
        )
        XCTAssertEqual(FileCloseAction.allCases.filter(\.isDefault), [.keepEditing])
        XCTAssertEqual(FileCloseAction.allCases.last, .keepEditing)
        XCTAssertEqual(FileCloseBanner.sentence(name: "notes.txt"), "notes.txt has unsaved changes")
    }

    func testDirtyCloseOwnsReturnAheadOfASimultaneousConflict() {
        XCTAssertEqual(
            FileBannerDefaultAction.derive(hasPendingClose: true, hasConflict: true),
            .keepEditing
        )
        XCTAssertEqual(
            FileBannerDefaultAction.derive(hasPendingClose: true, hasConflict: false),
            .keepEditing
        )
    }

    func testSaveAsOwnsReturnOnlyWhenAConflictStandsWithoutDirtyClose() {
        XCTAssertEqual(
            FileBannerDefaultAction.derive(hasPendingClose: false, hasConflict: true),
            .saveAs
        )
        XCTAssertEqual(
            FileBannerDefaultAction.derive(hasPendingClose: false, hasConflict: false),
            .none
        )
    }

    func testTheConflictBannerNamesTheFileAndSaysSavingIsRefused() {
        XCTAssertEqual(
            FileConflictBanner.sentence(for: .changed, name: "README.md"),
            "README.md changed on disk and this copy has unsaved edits · "
                + "saving is refused until one copy is chosen")
        XCTAssertTrue(
            FileConflictBanner.sentence(for: .missing, name: "notes.txt")
                .contains("no longer at its path"))
    }

    /// The copy register (D-15) speaks in the third person outside
    /// tooltips, so neither conflict may address the reader as "you".
    func testTheConflictSentenceSpeaksInTheThirdPerson() {
        for conflict in [FileConflict.changed, .missing] {
            let sentence = FileConflictBanner.sentence(for: conflict, name: "README.md")
            let words = sentence.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
            XCTAssertFalse(words.contains("you"), sentence)
            XCTAssertFalse(words.contains("your"), sentence)
            XCTAssertFalse(sentence.contains("!"), sentence)
        }
    }


    func testHeaderUsesTheExplicitlySelectedModeRatherThanTheFilename() {
        let state = FileHeaderState.derive(from: file(name: "README.md"), renderMode: .source("swift"))
        XCTAssertEqual(state.encodingAndFormat, "UTF-8 · Source (Swift)")
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
        model.standOpenFiles([file(id: id, dirty: true)])
        model.select(target: .file(id))
        model.perform(.pageClose)
        XCTAssertEqual(model.tabs.count, 1, "on a file the close chord leaves the tabs alone")
        XCTAssertEqual(
            model.pendingFileClose?.fileID, id,
            "on a dirty file the close chord publishes the inline decision"
        )
    }

    /// The two new ids reach the two file commands.
    ///
    /// What they do once there is the panel's answer, and under the
    /// runner every panel cancels (`RefusingFilePanels`), so this says
    /// the routing exists and stops: a cancelled Open opens nothing
    /// and a cancelled Save As writes nothing, both silently, which is
    /// what a person who dismissed a panel expects.
    func testTheTwoNewCommandsAreTheModelsToRun() throws {
        let model = isolatedModel(defaults: try defaults())
        XCTAssertTrue(model.perform(.fileOpen))
        XCTAssertTrue(model.openFiles.isEmpty, "a cancelled panel opens nothing")
        XCTAssertNil(model.notice, "a cancelled panel says nothing")
        XCTAssertTrue(model.perform(.fileSaveAs))
        XCTAssertNil(model.notice)
    }
}
