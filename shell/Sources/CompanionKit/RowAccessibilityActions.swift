import SwiftUI

/// The press the strip's rows, the Files shelf's rows and the Timeline's
/// nodes offer only while it applies. A row is one element built from
/// `.ignore`d children, which inherits no activation from its tap
/// gesture, so the press is given here, and withheld, for example
/// mid-rename, when the element is the field's container instead.
extension View {
    /// The default action, the one VoiceOver's press runs.
    @ViewBuilder
    func accessibilityActivation(when offered: Bool, action: @escaping () -> Void) -> some View {
        if offered {
            accessibilityAction(.default, action)
        } else {
            self
        }
    }
}

enum RowAccessibility {
    /// A row is a button unless it is renaming, and selected is
    /// selected either way.
    static func traits(selected: Bool, renaming: Bool) -> AccessibilityTraits {
        var traits: AccessibilityTraits = []
        if selected { traits.insert(.isSelected) }
        if !renaming { traits.insert(.isButton) }
        return traits
    }

    /// The same rule for a row that never renames.
    static func traits(selected: Bool) -> AccessibilityTraits {
        traits(selected: selected, renaming: false)
    }
}
