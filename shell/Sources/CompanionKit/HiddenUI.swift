import Foundation

/// The elements the UI is deliberately not showing (issue #78).
///
/// Dogfood triage named four affordances that were not earning their
/// place on the card: the ledger's entry points, the resize glyph in the
/// bottom corner, the ↗ page button in the tab strip, and the coloured
/// dot beside the app's name. None of them was deleted. The ledger's
/// entry points are drawn again and have no flag here. The other three
/// will come back in a different shape or be taken out for good, and
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
public enum HiddenUI {
    /// The ↗ page button, which conceals the visible page into a
    /// one-time link. The conceal flow itself, its confirmation and its
    /// ledger records all stand (issue #78).
    public static let showsConcealButton = false

    /// The drawn corner glyph that says the card is resizable. The eight
    /// invisible grips underneath it keep their gestures: the card
    /// resizes exactly as it did, it just no longer advertises the fact
    /// (issue #78).
    public static let showsResizeGlyph = false

    /// The 6pt ember dot at the head of the header, beside the app's
    /// name. The name stays, and so does the header's drag (issue #78).
    public static let showsHeaderDot = false
}
