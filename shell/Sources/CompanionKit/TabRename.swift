import Foundation

/// What a rename field's ending means, decided apart from the field.
///
/// A rename is not destructive, so it takes an inline field rather
/// than a dialog (D-14, issue #172): the title on the tab, or on the
/// page's day gutter, becomes editable in place, commits on return
/// and cancels on escape or when the keyboard goes elsewhere. Two
/// fields ask, one SwiftUI and one AppKit, and neither can be driven
/// under the test runner without a window, so the part of the rename
/// that is a decision lives here, where a test reaches it directly.
///
/// The model is still the one surface that owns a tab's identity. This
/// answers with the name to hand it, or with the fact that nothing
/// happened, and never renames anything itself.
public enum TabRename {
    /// The two ways a field can end.
    public enum Outcome: Equatable {
        /// Hand the model this name. An empty name is meaningful, not a
        /// cancel: it drops the override and lets the title derive from
        /// the page's own first line again.
        case rename(String)
        /// Nothing happened at all, and the title stands as it was.
        case keep
    }

    /// The name a draft submits: trimmed, because a name of only
    /// spaces would be an override the tab could not show, and the
    /// empty name it trims to is the one that derives the title again.
    public nonisolated static func name(from draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The outcome of a field that ended with `draft` in it, over a tab
    /// that showed `current` when the field opened. Only a return
    /// commits; escape and a keyboard that went elsewhere both keep.
    /// A return over an untouched draft keeps too, since the title the
    /// field opened on may be the page's own first line, and freezing
    /// that into an override would be a change the user never made.
    public nonisolated static func outcome(
        draft: String, current: String, committed: Bool
    ) -> Outcome {
        guard committed else { return .keep }
        let name = Self.name(from: draft)
        return name == current ? .keep : .rename(name)
    }
}
