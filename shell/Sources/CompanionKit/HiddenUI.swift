import Foundation

/// The elements the UI is deliberately not showing (issue #78).
///
/// Dogfood triage named four affordances that were not earning their
/// place on the card: the ledger's entry points, the resize glyph in the
/// bottom corner, the promote button in the tab strip, and the coloured
/// dot beside the app's name. None of them was deleted. Some will come
/// back in a different shape and some will be taken out for good, and
/// until that is decided the honest thing is to keep the code and stop
/// drawing it.
///
/// So each site reads a flag from here rather than being commented out
/// where it stands. One place says what is hidden, one place turns any
/// of it back on, and the views keep compiling against the model, which
/// is what stops a hidden affordance from quietly rotting: a rename in
/// the model still has to typecheck against the view that used to show
/// it.
///
/// These are `static let` on purpose. The decision belongs to the build,
/// not to a preference and not to a launch variable: nothing a running
/// app does should be able to put one of these back on screen, because
/// the point of the exercise is to see the surface without them.
///
/// One deliberate exception, at the site rather than here. A ledger
/// that will not open puts a standing line on the surface telling the
/// user to clear it in Settings, and that clear is the only way out;
/// so `ConnectionSettingsView` shows its section while
/// `PageModel.ledgerRestoreRefused` stands, and it goes again the
/// moment the clear lands. Hiding an affordance is a judgement about
/// clutter, and it is not worth making it by ending a recovery route
/// the app itself just recommended.
public enum HiddenUI {
    /// The dashed ledger tab at the right end of the strip, the ⌘0
    /// binding in the bundled keymap, and the clear button in Settings.
    /// `LedgerView` and every model verb behind it are untouched; what
    /// goes is the way in. The command id stays legal, so an override
    /// keymap can still bind it (issue #78).
    public static let showsLedgerEntryPoints = false

    /// The ↗ page button, which promotes the visible page to a one-time
    /// link. The promotion flow itself, its confirmation and its ledger
    /// records all stand (issue #78).
    public static let showsPromoteButton = false

    /// The drawn corner glyph that says the card is resizable. The eight
    /// invisible grips underneath it keep their gestures: the card
    /// resizes exactly as it did, it just no longer advertises the fact
    /// (issue #78).
    public static let showsResizeGlyph = false

    /// The 6pt ember dot at the head of the header, beside the app's
    /// name. The name stays, and so does the header's drag (issue #78).
    public static let showsHeaderDot = false

    /// Whether Settings draws its Clear-the-ledger section: when the
    /// entry points are shown at all, and while a refused ledger is
    /// standing on the surface pointing at this control as the way out.
    ///
    /// A decision rather than an expression inside a view body, so the
    /// exception above is somewhere a test can reach
    /// (`RestoreFailureTests`).
    public static func showsLedgerClear(ledgerRestoreRefused: Bool) -> Bool {
        showsLedgerEntryPoints || ledgerRestoreRefused
    }
}
