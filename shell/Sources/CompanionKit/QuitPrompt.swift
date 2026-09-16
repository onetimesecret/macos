import AppKit

/// A model the terminate path can flush synchronously.
@MainActor
public protocol QuitFlushable {
    /// Seal pending shell state and report whether termination may proceed.
    func saveStateForQuit() -> QuitSaveOutcome
}

extension PageModel: QuitFlushable {}

/// The terminate decision. It performs exactly one synchronous state flush,
/// never presents UI, and never writes an open file through a file-save path.
public enum QuitPrompt {
    @MainActor
    public static func terminateReply(
        flushing model: some QuitFlushable
    ) -> NSApplication.TerminateReply {
        switch model.saveStateForQuit() {
        case .settled:
            return .terminateNow
        case .refused, .unsavableWithContent:
            // Existing inline save or recovery state remains where it is. The
            // quit path neither activates the app nor presents another layer.
            return .terminateCancel
        }
    }
}
