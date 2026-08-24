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
}

extension PageModel: QuitFlushable {}

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

    /// The flush's verdict, turned into the thing the user sees. A
    /// refused write is the loudest: pages that were supposed to land
    /// did not, and staying is a real retry. A session that never held
    /// the licence has no write to retry, only the choice between
    /// accepting the loss and going back to discard the unreadable
    /// file, so its warning points at that door instead.
    public static func forOutcome(_ outcome: QuitSaveOutcome) -> QuitPrompt {
        switch outcome {
        case .settled:
            return .quitSilently
        case .refused:
            return .warn(
                Warning(
                    messageText: "This page could not be saved",
                    informativeText:
                        "The sealed state file was not written, so this session's page "
                        + "will not survive the quit. The previous file, if any, is untouched."
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
        switch forOutcome(model.saveStateForQuit()) {
        case .quitSilently:
            return .terminateNow
        case .warn(let warning):
            return present(warning) ? .terminateNow : .terminateCancel
        }
    }
}
