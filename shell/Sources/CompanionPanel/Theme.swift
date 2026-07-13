import SwiftUI

extension Color {
    /// The ember accent (#d45a2a) — the single accent colour, used
    /// sparingly, never as the only carrier of state (design brief;
    /// docs/spec/04).
    static let ember = Color(red: 0.831, green: 0.353, blue: 0.165)

    /// Surface colours degrade to solid, legible fills under Increase
    /// Contrast / Reduce Transparency because they come from the system
    /// palette (docs/spec/05 a11y).
    static let panelBackground = Color(nsColor: .windowBackgroundColor)
    static let cellBackground = Color(nsColor: .controlBackgroundColor)
}
