import SwiftUI

extension Color {
    /// The brand flame — the single accent, used sparingly (docs/00 §9). The
    /// warm coral of the design system.
    static let flame = Color(red: 0.98, green: 0.42, blue: 0.24)

    /// Surface colours degrade to solid, legible fills under Increase Contrast /
    /// Reduce Transparency because they come from the system palette (docs/00 §8).
    static let panelBackground = Color(nsColor: .windowBackgroundColor)
    static let cellBackground = Color(nsColor: .controlBackgroundColor)
}
