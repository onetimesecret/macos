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
            // ⌘N asks for a page to type on now. With the strip that is
            // a new slot; with the days down the side it is today's
            // page, which may already be there (issue #79). One command
            // with two readings of the same intent, rather than a
            // second id: the raw values here are published contract,
            // named in whatever keymap.json a user has written, and
            // both readings keep working under the chord they chose.
            if showsTimeUnits { openToday() } else { newPage() }
        case .pageClose:
            closeCurrent()
        case .pagePrevious:
            step(-1)
        case .pageNext:
            step(1)
        case .ledgerShow:
            showLedger()
        case .surfaceHandBackKeys:
            escape()
        case .stateSaveNow:
            _ = saveState()
        case .appSettings:
            onOpenSettings?()
        case .editorToggleWrap:
            // ⌥Z asks the page to stop wrapping, and with the days down
            // the side the page cannot: the roll wraps every day
            // whatever the preference says (issue #79). One command with
            // two readings of the same intent, the way `.pageNew` above
            // has two, except that here the second reading is a
            // refusal, said out loud rather than written silently into a
            // preference the surface on screen is not honouring. The
            // gate is here, at the dispatch, so that the stored value
            // and the flash cannot disagree about what just happened.
            if showsTimeUnits { flash(Self.wrapIsFixedNotice) } else { toggleWrap() }
        case .clipboardSeal, .clipboardSealSelection:
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
