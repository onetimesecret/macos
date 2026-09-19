import Foundation
import SwiftUI

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
    /// The answer is total, because an owner that could be nobody
    /// would leave every mount site a third branch to get wrong. Under
    /// the shipped rule the panel owns with the editor window closed,
    /// even if nothing is mounted anywhere: a closed window has no
    /// editor to hand anything to.
    ///
    /// `panelMayOwn` is the read only panel as one policy switch: with
    /// it false the panel is never granted ownership, in any row, and
    /// that is the whole of the policy. The closed rows answer the
    /// editor window too. That names a window with nothing mounted in
    /// it, which is still an answer and still total: every mount site
    /// asks whether its own surface owns, the panel's is told no, and
    /// so nothing is mounted anywhere and the card is a glance. Were
    /// the closed rows left to the panel, the policy would be a panel
    /// that edits whenever the editor window happens to be shut, which
    /// is not what ADR-0033 means by read only, and the mount sites
    /// would need a second question to close the gap. Nothing passes
    /// false today. The parameter exists so the policy is proved
    /// against the same function the app runs, not against a second
    /// architecture built for the occasion.
    public nonisolated static func resolve(
        panelRaised: Bool, editorWindowOpen: Bool, panelMayOwn: Bool = true
    ) -> PresentationOwner {
        guard panelMayOwn else { return .editorWindow }
        guard editorWindowOpen else { return .panel }
        return panelRaised ? .panel : .editorWindow
    }

    /// Whether a surface may write a presentation field, pure: only the
    /// owner may. One line, and a function anyway, so that the refusal
    /// is an assertion in a test and not a reading of the guard that
    /// wraps it (`PageModel.admits(_:from:)`), which traps in a debug
    /// build and so cannot be walked into by a test process.
    public nonisolated static func mayWrite(
        _ surface: PresentationOwner, owner: PresentationOwner
    ) -> Bool {
        surface == owner
    }

    /// Whether a surface's own window holds the keyboard, pure. The
    /// model keeps one key fact, and it is the owner's
    /// (`PageModel.holdsKeys`), so a surface that does not own holds no
    /// keyboard the model knows of, whatever the fact says. A surface
    /// that lights anything from the keyboard asks through here
    /// (`PageModel.holdsKeys(on:)`): read bare, the fact lights a
    /// resting card for as long as the person types in the editor
    /// window.
    public nonisolated static func holdsKeyboard(
        _ surface: PresentationOwner, owner: PresentationOwner, ownerHoldsKeys: Bool
    ) -> Bool {
        surface == owner && ownerHoldsKeys
    }

    /// The word the log uses for this surface. Mechanics only.
    var logName: String {
        switch self {
        case .panel: "panel"
        case .editorWindow: "editor-window"
        }
    }
}

/// The presentation state that has exactly one writer at a time, named
/// so that a declined write can say what it was reaching for. These are
/// the eight ADR-0033 lists. Selection, the selected file, the active
/// target and the ledger's visibility are not among them: those are
/// the shared model, which either window may change.
///
/// A claim on one of these is the owner's alone. Letting go is not
/// guarded by ownership, because ownership has usually moved by the
/// time a surface is torn down, and a surface that could not retire its
/// own handle would leave it standing. A release is guarded by identity
/// where there is one to check (`PageModel.retireEditor(_:)`, the roll
/// geometry's claim), so a surface can only ever let go of what is its
/// own.
public enum PresentationField: String, Sendable, CaseIterable {
    case activeEditor = "active-editor"
    case sealedPasteRoute = "sealed-paste-route"
    case todayAnchor = "today-anchor"
    case rollGeometry = "roll-geometry"
    case holdsKeys = "holds-keys"
    case redrawCadence = "redraw-cadence"
    case pasteboardOffer = "pasteboard-offer"
    /// Guarded by construction, where the others are guarded at the
    /// write: `PageKeyboardMap` installs no chord in a window that does
    /// not own, so there is no write to decline.
    case keyboardMap = "keyboard-map"
}

// MARK: - Which surface a view is standing in

private struct PresentationSurfaceKey: EnvironmentKey {
    static let defaultValue: PresentationOwner = .panel
}

extension EnvironmentValues {
    /// Which of the two content windows this view hierarchy belongs to.
    /// The mount sites read it to say who is writing, and the guard on
    /// the model compares that with who owns. The panel is the default
    /// because it is the surface that has always been there; the editor
    /// window names itself at its root.
    public var presentationSurface: PresentationOwner {
        get { self[PresentationSurfaceKey.self] }
        set { self[PresentationSurfaceKey.self] = newValue }
    }
}
