import AppKit

/// A model the terminate path can flush synchronously.
@MainActor
public protocol QuitFlushable {
    /// Seal pending shell state and report whether termination may proceed.
    func saveStateForQuit() -> QuitSaveOutcome

    /// Whether an earlier cancelled quit left its "quit anyway" line
    /// standing on the surface over the files at risk now. While it does,
    /// the next quit request is the answer to that line and terminates.
    var quitAnywayOffered: Bool { get }

    /// Record a cancelled quit so the surface can say why it was
    /// cancelled and offer to quit anyway.
    func offerQuitAnyway(after outcome: QuitSaveOutcome)
}

extension PageModel: QuitFlushable {}

/// The terminate decision. It performs exactly one synchronous state flush,
/// never presents UI, and never writes an open file through a file-save path.
///
/// A refused or unsavable flush cancels the first quit and puts one
/// standing line under the page, naming what the quit would lose and
/// offering to quit anyway. The second quit request, whether ⌘Q again
/// or that line's button, terminates: the person has read the line and
/// asked twice, which is the inline confirmation D-14 allows and the
/// only one the quit path asks for. Nothing here can hold the app open
/// for the rest of a session.
///
/// A ⌘Q over file edits the line never named cancels again and names them.
public enum QuitPrompt {
    @MainActor
    public static func terminateReply(
        flushing model: some QuitFlushable
    ) -> NSApplication.TerminateReply {
        // The flush runs regardless, and the offer is read after it, so a
        // file whose draft the flush wrote is not counted at risk.
        let outcome = model.saveStateForQuit()
        switch outcome {
        case .settled:
            return .terminateNow
        case .refused, .unsavableWithContent, .unsavableWithDrafts:
            if model.quitAnywayOffered { return .terminateNow }
            model.offerQuitAnyway(after: outcome)
            return .terminateCancel
        }
    }
}
