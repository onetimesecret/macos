import AppKit

/// A model the terminate path can flush. The quit decision needs one
/// thing from whatever holds the pages, and asking for exactly that
/// keeps the decision itself out of AppKit's reach: a delegate hands
/// its model over, and the flush is taken from the model rather than
/// improvised at the call site.
@MainActor
public protocol QuitFlushable {
    /// Seal whatever the debounce still holds, and report what the
    /// quit costs (`PageModel.saveStateForQuit`).
    func saveStateForQuit() -> QuitSaveOutcome

    /// The names of the open files carrying unsaved edits at the moment
    /// the quit is asked. Names and not a count, because a general
    /// warning about unsaved work is the one nobody can act on
    /// (`PageModel.draftsAtRiskSentence` makes the same argument).
    var dirtyFileNames: [String] { get }
}

extension PageModel: QuitFlushable {
    public var dirtyFileNames: [String] { openFiles.filter(\.isDirty).map(\.name) }
}

/// What the quit says to the user, and what it answers the system with
/// (issue #49). The application delegate owns the alert's appearance,
/// the activation, and the two buttons; everything about which story is
/// told, and whether the quit proceeds, is decided here so it can be
/// read and tested without an `NSAlert` on screen.
public enum QuitPrompt: Equatable, Sendable {
    /// Nothing is owed and nothing is lost: quit without a word.
    case quitSilently
    /// Quitting costs the user something they may not know about. Say
    /// so while the choice is still theirs to make.
    case warn(Warning)

    /// The alert's copy, in `NSAlert`'s own two registers: the sentence
    /// that lands first, and the paragraph that explains what it means
    /// for the file on disk.
    public struct Warning: Equatable, Sendable {
        public let messageText: String
        public let informativeText: String

        public init(messageText: String, informativeText: String) {
            self.messageText = messageText
            self.informativeText = informativeText
        }
    }

    /// The sentence a dirty file adds to whatever else the quit says.
    ///
    /// It is a notice and not a save or discard sheet, and the
    /// difference is the whole point. The draft survives the quit: it
    /// is sealed under the content key and restored at the next launch
    /// with its marker still showing, so a Discard button here would
    /// manufacture the one loss path this feature does not have, at
    /// exactly the moment a person is dismissing things by reflex. The
    /// two answers are therefore go back and save, or quit and keep
    /// the draft.
    ///
    /// Agreed with the count: one file "has" changes and is reopened
    /// as "the file", several "have" them and come back as "the
    /// files", so the notice reads as a sentence whichever it names.
    static func draftsClause(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let several = names.count > 1
        let has = several ? "have" : "has"
        let files = several ? "files" : "file"
        let them = several ? "the files" : "the file"
        return "\(PageModel.englishList(names)) \(has) unsaved changes that are not on disk. "
            + "The pad keeps them in its own sealed state and reopens the "
            + "\(files) with them at the next launch, still marked unsaved. "
            + "Cancel and press Cmd S to write them to \(them) instead."
    }

    /// The same names under a write that did not land. The promise the
    /// clause above makes rests on the seal having been written, and
    /// this is the branch where it was not, so the notice says the
    /// weaker true thing instead of the stronger false one.
    static func draftsAtRisk(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "Unsaved changes to \(PageModel.englishList(names)) are in memory "
            + "only and go with the quit."
    }

    /// The flush's verdict, turned into the thing the user sees. A
    /// refused write is the loudest: pages that were supposed to land
    /// did not, and staying is a real retry. A session that never held
    /// the licence has no write to retry, only the choice between
    /// accepting the loss and going back to discard the unreadable
    /// file, so its warning points at that door instead.
    public static func forOutcome(
        _ outcome: QuitSaveOutcome, dirtyFiles: [String] = []
    ) -> QuitPrompt {
        let drafts = draftsClause(dirtyFiles)
        switch outcome {
        case .settled:
            guard let drafts else { return .quitSilently }
            return .warn(
                Warning(
                    messageText: dirtyFiles.count == 1
                        ? "\(dirtyFiles[0]) has unsaved changes"
                        : "\(dirtyFiles.count) open files have unsaved changes",
                    informativeText: drafts
                ))
        case .refused:
            return .warn(
                Warning(
                    messageText: "This page could not be saved",
                    informativeText:
                        "The sealed state file was not written, so this session's page "
                        + "will not survive the quit. The previous file, if any, is untouched."
                        + (draftsAtRisk(dirtyFiles).map { " " + $0 } ?? "")
                ))
        case .unsavableWithContent:
            // The banner's warning, repeated at the last moment it can
            // still change the outcome (issue #49).
            return .warn(
                Warning(
                    messageText: "This session was never being saved",
                    informativeText:
                        "The existing sealed state file could not be read at launch, so "
                        + "nothing written this session is on disk, and it will not survive "
                        + "the quit. That file is untouched. Cancel and use \"discard it and "
                        + "start saving\" on the page to keep this session's content instead."
                        + (draftsAtRisk(dirtyFiles).map { " " + $0 } ?? "")
                ))
        }
    }

    /// The whole terminate decision: flush first, then answer. The
    /// flush happens exactly once and before anything is shown, because
    /// what the alert would say depends on how the write went; a silent
    /// outcome never reaches `present`, so a settled quit is never
    /// interrupted. `present` returns true when the user chose to quit
    /// anyway. Cancelling is never a retry loop, only a return to the
    /// surface.
    @MainActor
    public static func terminateReply(
        flushing model: some QuitFlushable,
        present: @MainActor (Warning) -> Bool
    ) -> NSApplication.TerminateReply {
        // Read before the flush: the flush seals the pad's own state
        // and never writes a person's file, so the roster it leaves is
        // the roster it found, and taking the names first keeps the
        // question independent of that.
        let dirty = model.dirtyFileNames
        switch forOutcome(model.saveStateForQuit(), dirtyFiles: dirty) {
        case .quitSilently:
            return .terminateNow
        case .warn(let warning):
            return present(warning) ? .terminateNow : .terminateCancel
        }
    }
}
