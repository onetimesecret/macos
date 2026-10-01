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
        restoredFromDraft: Bool = false,
        pendingHydration: Bool = false,
        accessRefused: Bool = false,
        notFound: Bool = false
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
            restoredFromDraft: restoredFromDraft,
            pendingHydration: pendingHydration,
            accessRefused: accessRefused,
            notFound: notFound
        )
    }

    // MARK: The header

    func testAHeldCRLFHeaderSpeaksOnlyTheUnreadState() {
        let held = file(lineEnding: .crlf, pendingHydration: true, accessRefused: true)
        let state = FileHeaderState.derive(from: held, renderMode: .source("swift"))
        XCTAssertEqual(state.spoken, "README.md, not read, this file cannot be read at its path")
        XCTAssertEqual(state.encodingAndFormat, "")
        XCTAssertFalse(state.showsUnsavedDot)
        XCTAssertNil(state.lastEditStamp)
    }

    func testHeldInputsOfferNoKeepMineEvenWithAnInconsistentConflict() {
        for conflict in [FileConflict.none, .changed, .missing] {
            let held = file(dirty: true, conflict: conflict,
                            pendingHydration: true, accessRefused: true)
            XCTAssertEqual(FileConflictBanner.actions(for: held), [.locate])
        }
    }

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

    func testTheDirtyCloseActionsAreOrderedByOutcomeWithKeepEditingLast() {
        XCTAssertEqual(
            FileCloseAction.allCases.map(\.label),
            ["Save file", "Discard changes", "Keep editing"]
        )
        XCTAssertEqual(FileCloseAction.allCases.last, .keepEditing)
        XCTAssertEqual(FileCloseBanner.sentence(name: "notes.txt"), "notes.txt has unsaved changes")
    }

    /// Each close action carries a tooltip and a VoiceOver hint. The
    /// conflict banner replaces its labels instead, in the first person;
    /// a hint keeps the button's own text and reads after it, which is
    /// the right slot for an action whose label is already a verb.
    /// Discard is the destructive one, and both of its strings say the
    /// draft is destroyed and does not come back.
    func testTheCloseBannerActionsEachSayWhatTheyDo() {
        XCTAssertEqual(
            FileCloseBanner.help(for: .save),
            "Write the file and close the tab once the write succeeds")
        XCTAssertEqual(
            FileCloseBanner.help(for: .discard),
            "Close the tab and destroy the draft. It cannot be recovered.")
        XCTAssertEqual(
            FileCloseBanner.help(for: .keepEditing),
            "Leave the tab open with its draft intact")
        XCTAssertEqual(
            FileCloseBanner.accessibilityHint(for: .save),
            "Writes the file, then closes the tab")
        XCTAssertEqual(
            FileCloseBanner.accessibilityHint(for: .discard),
            "Closes the tab and destroys the draft, which cannot be recovered")
        XCTAssertEqual(
            FileCloseBanner.accessibilityHint(for: .keepEditing),
            "Leaves the tab open and keeps the draft")
        for action in FileCloseAction.allCases {
            let help = FileCloseBanner.help(for: action)
            let hint = FileCloseBanner.accessibilityHint(for: action)
            XCTAssertFalse(help.isEmpty, "\(action)")
            XCTAssertFalse(hint.isEmpty, "\(action)")
            for sentence in [help, hint] {
                let words = sentence.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                XCTAssertFalse(words.contains("you"), sentence)
                XCTAssertFalse(words.contains("your"), sentence)
            }
        }
        XCTAssertTrue(FileCloseBanner.help(for: .discard).contains("cannot be recovered"))
        XCTAssertTrue(FileCloseBanner.accessibilityHint(for: .discard).contains("cannot be recovered"))
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

    // MARK: Locate, and the file that cannot be read

    func testTheConflictBannerOffersLocateOnlyWhenTheOtherCopyCannotBeReached() {
        XCTAssertEqual(
            FileConflictBanner.actions(for: file(dirty: true, conflict: .changed)),
            [.keepMine, .takeTheirs, .saveAs],
            "a file that merely changed keeps its three actions")
        XCTAssertEqual(
            FileConflictBanner.actions(for: file(dirty: true, conflict: .missing, notFound: true)),
            [.locate, .keepMine, .saveAs],
            "nothing is at the path, so there is no copy to take and no button that could only fail")
        XCTAssertEqual(
            FileConflictBanner.actions(for: file(dirty: true, conflict: .missing)),
            [.locate, .keepMine, .saveAs],
            "and the conflict alone says so, for a row from a core that sends no mark")
        XCTAssertEqual(
            FileConflictBanner.actions(for: file(dirty: true, conflict: .changed, accessRefused: true)),
            [.locate, .keepMine, .saveAs],
            "take theirs is not offered while there is no copy that can be read")
        for row in [
            file(dirty: true, conflict: .changed),
            file(dirty: true, conflict: .missing),
            file(dirty: true, conflict: .changed, accessRefused: true),
        ] {
            XCTAssertEqual(
                FileConflictBanner.actions(for: row).last, .saveAs,
                "the action that destroys nothing keeps the last place (D-17)")
        }
    }

    func testAnAccessRefusedConflictSaysTheFileCannotBeReadRatherThanThatItChanged() {
        let row = file(name: "notes.txt", dirty: true, conflict: .changed, accessRefused: true)
        XCTAssertEqual(
            FileConflictBanner.sentence(for: row),
            "notes.txt cannot be read at its path and this copy has unsaved edits · "
                + "saving is refused until one copy is chosen")
        // The two conflicts that can be read keep the words they had.
        XCTAssertEqual(
            FileConflictBanner.sentence(for: file(dirty: true, conflict: .changed)),
            FileConflictBanner.sentence(for: .changed, name: "README.md"))
        XCTAssertEqual(
            FileConflictBanner.sentence(for: file(dirty: true, conflict: .missing)),
            FileConflictBanner.sentence(for: .missing, name: "README.md"))
    }

    func testTheUnavailableBannerStandsForAFileThatCannotBeReadAndIsInNoConflict() {
        let held = file(
            name: "notes.txt", path: "/Users/someone/notes.txt",
            restoredFromDraft: true, pendingHydration: true, accessRefused: true)
        XCTAssertTrue(held.isHeld)
        XCTAssertTrue(FileUnavailableBanner.stands(for: held))
        XCTAssertTrue(
            FileUnavailableBanner.stands(for: file(accessRefused: true)),
            "a clean open file whose reload was refused gets the same two actions")
        XCTAssertFalse(FileUnavailableBanner.stands(for: file()))
        XCTAssertFalse(
            FileUnavailableBanner.stands(for: file(dirty: true, conflict: .changed, accessRefused: true)),
            "a conflict has its own banner, and only one of the two ever stands")
        XCTAssertFalse(file(pendingHydration: true).isHeld, "pending alone is a wait, not a hold")

        let sentence = FileUnavailableBanner.sentence(name: held.name, path: held.path)
        XCTAssertEqual(
            sentence, "notes.txt cannot be read at /Users/someone/notes.txt",
            "it names the file and the last known path")
        let words = sentence.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        XCTAssertFalse(words.contains("you"))
        XCTAssertFalse(sentence.contains("!"))
    }

    func testTheUnavailableBannerStandsForACleanFileThatIsNoLongerAtItsPath() {
        // A clean file never enters a conflict, so without this banner
        // nothing standing would say the file is gone, and nothing
        // would offer Locate.
        let gone = file(name: "notes.txt", path: "/Users/someone/notes.txt", notFound: true)
        XCTAssertTrue(gone.offersLocate)
        XCTAssertTrue(gone.isUnavailable)
        XCTAssertTrue(FileUnavailableBanner.stands(for: gone))
        XCTAssertEqual(
            FileUnavailableBanner.sentence(for: gone),
            "notes.txt is no longer at /Users/someone/notes.txt")
        XCTAssertEqual(
            FileUnavailableBanner.sentence(for: file(name: "notes.txt", path: "/p/notes.txt", accessRefused: true)),
            "notes.txt cannot be read at /p/notes.txt",
            "a file that is there and cannot be read keeps its own sentence")

        // A draft in the missing conflict has the conflict banner, and
        // only one of the two ever stands.
        XCTAssertFalse(
            FileUnavailableBanner.stands(for: file(dirty: true, conflict: .missing, notFound: true)))
        // After keep mine the conflict is answered and the file is
        // still gone, so what is left to offer is the way to find it.
        let kept = file(dirty: true, conflict: .none, notFound: true)
        XCTAssertTrue(FileUnavailableBanner.stands(for: kept))

        XCTAssertEqual(
            FileHeaderState.derive(from: gone).spoken,
            "notes.txt, saved, this file is no longer at its path")
        XCTAssertEqual(
            FileRowLabel.spoken(for: gone), "file, notes.txt, saved, no longer at its path")
        XCTAssertEqual(
            FileRowLabel.spoken(for: file(name: "notes.txt", dirty: true, conflict: .missing, notFound: true)),
            "file, notes.txt, unsaved, no longer at its path",
            "said once, not once for the conflict and again for the mark")
    }

    func testAFileThatCannotBeReadSaysSoInTheHeaderAndOnItsRow() {
        let held = file(name: "notes.txt", pendingHydration: true, accessRefused: true)
        XCTAssertEqual(
            FileHeaderState.derive(from: held).spoken,
            "notes.txt, not read, this file cannot be read at its path")
        XCTAssertEqual(
            FileRowLabel.spoken(for: held), "file, notes.txt, not read, cannot be read at its path")
        // Access refused is said in place of the conflict it stands in.
        let draft = file(name: "notes.txt", dirty: true, conflict: .changed, accessRefused: true)
        XCTAssertEqual(
            FileRowLabel.spoken(for: draft), "file, notes.txt, unsaved, cannot be read at its path")
        XCTAssertFalse(FileHeaderState.derive(from: draft).spoken.contains("changed on disk"))
    }

    func testARefusedSaveNamesTheActionsTheBannerActuallyOffers() {
        XCTAssertEqual(
            PageModel.unresolvedConflictNotice(for: file(name: "a.txt", dirty: true, conflict: .changed)),
            PageModel.unresolvedConflictNotice(name: "a.txt"))
        let missing = PageModel.unresolvedConflictNotice(
            for: file(name: "a.txt", dirty: true, conflict: .missing))
        XCTAssertEqual(
            missing,
            "a.txt is no longer at its path. Choose Locate, keep mine, or Save As before saving.")
        let refused = PageModel.unresolvedConflictNotice(
            for: file(name: "a.txt", dirty: true, conflict: .changed, accessRefused: true))
        XCTAssertEqual(
            refused,
            "a.txt cannot be read at its path. Choose Locate, keep mine, or Save As before saving.")
        XCTAssertFalse(refused.contains("take theirs"))
    }

    /// A held file is neither saved nor unsaved: nothing of it was
    /// read. The header must not say "saved" of text nobody has seen,
    /// and must not say "unsaved" of a record whose draft was dropped
    /// for its size, which is dirty in name only.
    func testAHeldFileReadsAsNotReadAndNeverAsSavedOrUnsaved() {
        let clean = file(name: "notes.txt", pendingHydration: true, accessRefused: true)
        let droppedDraft = file(
            name: "notes.txt", dirty: true, lastEditedAt: 1_756_900_000,
            restoredFromDraft: true, pendingHydration: true, accessRefused: true)
        for held in [clean, droppedDraft] {
            XCTAssertTrue(held.isHeld)
            XCTAssertFalse(held.holdsUnsavedEdits)
            let state = FileHeaderState.derive(from: held, renderMode: .markdown)
            XCTAssertEqual(state.saveWord, "not read")
            XCTAssertEqual(state.saveWord, FileHeaderState.notReadWord)
            XCTAssertFalse(state.showsUnsavedDot)
            XCTAssertNil(state.lastEditStamp, "there is no draft whose age could be stated")
            XCTAssertEqual(state.encodingAndFormat, "", "no text is shown, so none is described")
            XCTAssertEqual(
                state.spoken, "notes.txt, not read, this file cannot be read at its path")
            let words = state.spoken.components(separatedBy: CharacterSet.alphanumerics.inverted)
            XCTAssertFalse(words.contains("saved"))
            XCTAssertFalse(words.contains("unsaved"))
            XCTAssertEqual(
                FileRowLabel.spoken(for: held),
                "file, notes.txt, not read, cannot be read at its path")
        }
        // A settled file the system will not let be read is not held,
        // and keeps the save word its buffer earns.
        let settled = file(name: "notes.txt", accessRefused: true)
        XCTAssertFalse(settled.isHeld)
        XCTAssertEqual(FileHeaderState.derive(from: settled).saveWord, "saved")
        XCTAssertTrue(file(dirty: true).holdsUnsavedEdits)
        XCTAssertFalse(file().holdsUnsavedEdits)
    }

    /// The refused save of a file with no unsaved edits and nothing at
    /// its path: one sentence, naming Locate and Save As and nothing
    /// the file is not offered.
    func testASaveOfAFileThatIsGoneNamesLocateAndSaveAs() {
        let sentence = PageModel.saveNotFoundNotice(name: "a.txt")
        XCTAssertEqual(
            sentence,
            "a.txt is no longer at its path, so it was not saved. "
                + "Choose Locate to find it, or Save As to write it somewhere.")
        XCTAssertFalse(sentence.lowercased().contains("keep mine"))
        let words = sentence.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        XCTAssertFalse(words.contains("you"))
        XCTAssertFalse(sentence.contains("!"))
    }

    /// The two words are different things on the wire: the roster's
    /// mark is `accessRefused`, and `unreadable` is only ever the
    /// reason on a notice for a file that was dropped.
    func testAccessRefusedAndUnreadableAreDifferentWordsOnTheWire() throws {
        let row = """
            {"id": 1, "name": "a.txt", "path": "/p/a.txt", "isDirty": false,
             "conflict": "none", "lineEnding": "lf", "hasBOM": false,
             "lastEditedAt": 0, "restoredFromDraft": true,
             "pendingHydration": true, "accessRefused": true, "notFound": false}
            """
        let decoded = try JSONDecoder().decode(FileSummary.self, from: Data(row.utf8))
        XCTAssertTrue(decoded.accessRefused)
        XCTAssertTrue(decoded.isHeld)
        // The old spelling of the mark is not read as the mark.
        let old = row.replacingOccurrences(of: "accessRefused", with: "unreadable")
        let stale = try JSONDecoder().decode(FileSummary.self, from: Data(old.utf8))
        XCTAssertFalse(stale.accessRefused)
        XCTAssertFalse(stale.isHeld)
        XCTAssertEqual(DraftNoticeReason.unreadable.rawValue, "unreadable")
        let notice = try JSONDecoder().decode(
            DraftNotice.self,
            from: Data(#"{"name": "a.txt", "path": "/p/a.txt", "reason": "unreadable"}"#.utf8))
        XCTAssertEqual(notice.reason, .unreadable)
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
