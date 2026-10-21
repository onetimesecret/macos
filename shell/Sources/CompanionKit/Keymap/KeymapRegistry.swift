import Foundation

/// Where a command id stops being a string and becomes something the
/// app does.
///
/// One switch, exhaustive by the compiler's insistence, which is the
/// property worth having: a command added to `CommandID` without an
/// arm here will not build, so the list of ids and the list of
/// behaviours cannot drift apart. The keymap layer above never calls a
/// selector by name and never looks anything up in a dictionary of
/// closures, because both of those are ways for a typo to survive until
/// someone presses the key.
extension PageModel {
    /// Runs the command, and says whether it was this object's to run.
    ///
    /// False means the command belongs to the page's own text view,
    /// which holds the caret and the selection the seal gestures act
    /// on. It is not a failure; it is the seam between the two dispatch
    /// routes, stated where both sides can see it.
    @discardableResult
    public func perform(_ command: CommandID) -> Bool {
        if let number = command.selectsPageNumber {
            select(index: number - 1)
            return true
        }
        switch command {
        case .pageNew:
            newPage()
        case .pageClose:
            // ⌘W closes what is on the surface: the file, with its dirty
            // decision inline, or the page (ADR-0028). A key window with
            // neither takes the chord through `closeWhatIsShowing` (issue #201).
            if case .file = activeTarget { closeActiveFile() } else { closeCurrent() }
        case .fileOpen:
            openFile()
        case .fileSaveAs:
            saveActiveFileAs()
        case .pagePrevious:
            step(-1)
        case .pageNext:
            step(1)
        case .ledgerShow:
            showLedger()
        case .surfaceHandBackKeys:
            escape()
        case .stateSaveNow:
            // ⌘S asks for what is on screen to be on disk. On a file
            // that writes the file, which is the one place in the app
            // where a chord reaches a person's own filesystem, and it
            // is refused while that file is in conflict. On a page it
            // flushes the sealed state file, exactly as it always has
            // (issue #46). One intent, two readings, no rebinding.
            if case .file = activeTarget { saveActiveFile() } else { _ = saveState() }
        case .appSettings:
            onOpenSettings?()
        case .editorToggleWrap:
            toggleWrap()
        case .clipboardSeal, .clipboardSealSelection, .chipCopyDecrypted,
            .editorDetectCodeLanguage, .editorUndo, .editorRedo, .noteToggleExpanded:
            // The page's own text view answers these: the seal, copy
            // decrypted and language gestures act on its selection, and
            // undo has to place a caret after the core moves the
            // document underneath it.
            return false
        case .windowClose:
            // ⇧⌘W is the Window menu's and sends `performClose:` to the
            // key window (issue #201). The model has no window to close.
            return false
        case .pageSelect1, .pageSelect2, .pageSelect3, .pageSelect4, .pageSelect5,
            .pageSelect6, .pageSelect7, .pageSelect8, .pageSelect9:
            // Answered above, by number, so the nine cases stay one
            // behaviour rather than nine copies of it.
            return true
        }
        return true
    }
}

/// What ⌘W closes (issue #201): the page or file on the surface while
/// the owner's window is key, otherwise the auxiliary window that has
/// the keys, which is Settings, About or Send Feedback.
public enum CloseChordTarget: Equatable, Sendable {
    case surface
    case auxiliaryWindow
}

extension PageModel {
    /// The model's half of where ⌘W goes. `holdsKeys` is false while an
    /// auxiliary window has the keys, and also while no window of ours is
    /// key; the File menu asks AppKit whether the key window can close.
    public var closeChordTarget: CloseChordTarget {
        holdsKeys ? .surface : .auxiliaryWindow
    }

    /// Runs ⌘W: `page::Close` on the surface, or `closeKeyWindow` when
    /// the keyboard is in a window with no page or file to close.
    public func closeWhatIsShowing(closeKeyWindow: () -> Void) {
        switch closeChordTarget {
        case .surface:
            perform(.pageClose)
        case .auxiliaryWindow:
            closeKeyWindow()
        }
    }
}
