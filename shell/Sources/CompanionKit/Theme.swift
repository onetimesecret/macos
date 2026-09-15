import SwiftUI

extension Color {
    /// The ember accent (#DC4A22), the single accent colour, used
    /// sparingly, never as the only carrier of state and never as text
    /// (design brief; docs/spec/04; D-03). The hex is the shipped
    /// logo's, and the one the record names; the constant had drifted
    /// to a neighbouring shade and was brought back. This is the fill:
    /// the keyline, the unsaved dot, the hatch, a glyph's tint. A word
    /// in ember wears `emberText`.
    public static let ember = Color(red: 0.863, green: 0.290, blue: 0.133)

    /// Ember as ink: the same hue, darkened in the light appearance
    /// and lightened in the dark one until a caption in it clears the
    /// record's 4.5:1 on the page and on the card, which the fill's
    /// shade does not (it reads about 4.2:1 on white and 4:1 on the
    /// dark page). One dynamic colour rather than two, so a status
    /// line names one token and AppKit chooses the shade with the
    /// appearance. ThemeContrastTests measures both.
    public static let emberText = Color(nsColor: .emberText)

    /// Surface colours degrade to solid, legible fills under Increase
    /// Contrast / Reduce Transparency because they come from the system
    /// palette (docs/spec/05 a11y).
    public static let panelBackground = Color(nsColor: .windowBackgroundColor)
    public static let cellBackground = Color(nsColor: .controlBackgroundColor)
}

extension NSColor {
    /// Ember as ink, the AppKit side of `Color.emberText`, for the
    /// places that draw with an `NSColor`. Light #B0361A, dark #F5865F.
    public static let emberText = NSColor.appearanceAware(light: 0xB0361A, dark: 0xF5865F)

    /// A colour that answers for the appearance it is drawn under,
    /// from one sRGB hex per appearance. The system's own dynamic
    /// colours are built the same way; this is the same idea for the
    /// handful of shades that are ours. Anything that is not the dark
    /// appearance, including the high contrast variants, takes the
    /// light shade, which is the darker of the two and so the safer
    /// mistake.
    static func appearanceAware(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return NSColor(srgbHex: match == .darkAqua ? dark : light)
        }
    }

    /// An opaque sRGB colour from a 24 bit hex, the notation the
    /// design record and the logo asset use.
    convenience init(srgbHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
