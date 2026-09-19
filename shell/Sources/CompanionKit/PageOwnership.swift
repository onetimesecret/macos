import Foundation

/// Which of the two content windows owns the live page content, as one
/// explicit answer rather than whichever mount site wrote last.
///
/// Two windows can show the same page now: the ambient panel and the
/// editor window (ADR-0033). A page's storage takes exactly one layout
/// manager (ADR-0006), and the presentation state beside it (the active
/// editor, the sealed paste route, the today anchor, the roll geometry,
/// key ownership, the redraw cadence, the pasteboard offer and the
/// keyboard map) has room for one writer, so exactly one window owns at
/// a time. The owner mounts the editor and writes those fields. The
/// other window shows a glance, or nothing, and never mounts a second
/// editor on a live storage.
///
/// The resolver takes the two facts that decide it, and nothing else.
/// Key status is deliberately not among them: the keyboard passing to
/// Settings, About, a modal panel or another application moves nothing,
/// and a rule that cannot see key status cannot be moved by it. The
/// panel's posture arrives as a Bool because the stance type belongs to
/// the OnetimePad target while the mount sites that ask live here; the
/// form factor translates its stance on the way in.
public enum PresentationOwner: Equatable, Sendable {
    /// The ambient panel. It owns whenever it is raised, because a
    /// summon is the person asking to type into the card, and it owns
    /// whenever the editor window is closed, as it did before there was
    /// a second window to ask about.
    case panel

    /// The editor window. It owns while it is open and the panel rests,
    /// which is also where ownership returns when a raised panel rests
    /// beside an open editor window.
    case editorWindow

    /// The full matrix, in one place: the panel owns while it is raised
    /// or while the editor window is closed, and the editor window owns
    /// otherwise.
    ///
    /// The answer is total. With the editor window closed the panel
    /// owns even if nothing is mounted anywhere, because an owner that
    /// could be nobody would leave every mount site a third branch to
    /// get wrong, and a closed window has no editor to hand anything to.
    ///
    /// `panelMayOwn` is the read only panel as one policy switch: with
    /// it false the panel is never granted ownership while the editor
    /// window is open, raised or not, and that is the whole of the
    /// restriction. The closed rows still answer the panel, since the
    /// rule is total and a closed window cannot be handed anything;
    /// whether a panel under the policy mounts an editor in those rows
    /// is the mount site's question, not this function's. Nothing
    /// passes false today. The parameter exists so the policy
    /// is proved against the same function the app runs, not against a
    /// second architecture built for the occasion.
    public nonisolated static func resolve(
        panelRaised: Bool, editorWindowOpen: Bool, panelMayOwn: Bool = true
    ) -> PresentationOwner {
        guard editorWindowOpen else { return .panel }
        guard panelMayOwn else { return .editorWindow }
        return panelRaised ? .panel : .editorWindow
    }
}
