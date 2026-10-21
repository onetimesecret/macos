import SwiftUI

/// Accessibility actions the strip's and the rail's rows offer only
/// while they apply. A row is one element built from `.ignore`d
/// children, which inherits no activation from its tap gesture, so the
/// press and the named verbs are given here, and withheld, for example
/// mid-rename, when the element is the field's container instead.
extension View {
    @ViewBuilder
    func accessibilityNewPageAction(when offered: Bool, action: @escaping () -> Void) -> some View {
        if offered {
            accessibilityAction(named: Text("New page"), action)
        } else {
            self
        }
    }

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
