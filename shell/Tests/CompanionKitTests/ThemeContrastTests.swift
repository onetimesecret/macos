import AppKit
import SwiftUI
import XCTest

@testable import CompanionKit

/// The record's contrast row (docs/spec/design, section 9 row 5): every
/// colour that carries text clears 4.5:1 against what it is drawn on,
/// in the light appearance and in the dark one. The tree's colours are
/// mostly the system's, which know both appearances by themselves, and
/// the few that are ours are asserted here rather than trusted.
///
/// The measure is WCAG 2 relative luminance, computed from components
/// resolved under a named `NSAppearance`, so what is asserted is the
/// colour AppKit would actually draw and not the hex a comment names.
/// A translucent ink or wash is composited onto its backing first,
/// because the eye sees the blend and the ratio is about what the eye
/// sees.
@MainActor
final class ThemeContrastTests: XCTestCase {
    // MARK: The helper

    /// WCAG 2 relative luminance of an opaque sRGB colour.
    static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    /// `top` drawn over `bottom`, both in sRGB, with `top`'s alpha
    /// blended in and `bottom` taken as opaque. System label colours
    /// are black or white at a fraction, and the fence wash is the
    /// same, so nothing here can be judged without this step.
    static func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
        let t = top.usingColorSpace(.sRGB) ?? top
        let b = bottom.usingColorSpace(.sRGB) ?? bottom
        let alpha = t.alphaComponent
        return NSColor(
            srgbRed: t.redComponent * alpha + b.redComponent * (1 - alpha),
            green: t.greenComponent * alpha + b.greenComponent * (1 - alpha),
            blue: t.blueComponent * alpha + b.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    /// The contrast ratio of `ink` drawn on `backing`, with both
    /// resolved under `appearance` first, so a dynamic colour answers
    /// for the appearance asked about and not for whatever the test
    /// runner happens to be wearing.
    static func contrastRatio(
        _ ink: NSColor, on backing: NSColor, appearance name: NSAppearance.Name
    ) -> CGFloat {
        contrastRatio(ink, over: [backing], appearance: name)
    }

    /// The same, over a stack of layers laid bottom to top, for an ink
    /// drawn on a translucent wash that itself sits on the page.
    static func contrastRatio(
        _ ink: NSColor, over layers: [NSColor], appearance name: NSAppearance.Name
    ) -> CGFloat {
        let appearance = NSAppearance(named: name)!
        var ratio: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            let ground = layers.reduce(NSColor.white) { composite($1, over: $0) }
            let figure = composite(ink, over: ground)
            let lighter = max(relativeLuminance(figure), relativeLuminance(ground))
            let darker = min(relativeLuminance(figure), relativeLuminance(ground))
            ratio = (lighter + 0.05) / (darker + 0.05)
        }
        return ratio
    }

    /// The bar the record sets, and the two appearances it is set in.
    static let bar: CGFloat = 4.5
    static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// The page and the card: the two backings text is drawn on
    /// outside a fence. Both are system colours that carry the
    /// appearance, so one name serves both lights.
    static let backings: [(String, NSColor)] = [
        ("page", .windowBackgroundColor),
        ("card", .controlBackgroundColor),
    ]

    /// The fence wash as the eye sees it: the editor's translucent
    /// `codeBackground` laid on each of the two backings, bottom first.
    /// Token ink is drawn on this and nowhere else.
    static let fenceWashes: [(String, [NSColor])] = [
        ("the fence wash on the page", [.windowBackgroundColor, InkStyle.codeBackground]),
        ("the fence wash on the card", [.controlBackgroundColor, InkStyle.codeBackground]),
    ]

    /// Asserts `ink` clears the bar on every backing in both
    /// appearances, naming the failing pair so the number that missed
    /// is in the message.
    func assertClearsTheBar(
        _ ink: NSColor, named name: String,
        on backings: [(String, NSColor)] = ThemeContrastTests.backings,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for appearance in Self.appearances {
            for (backingName, backing) in backings {
                let ratio = Self.contrastRatio(ink, on: backing, appearance: appearance)
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.bar,
                    "\(name) on the \(backingName) under \(appearance.rawValue) reads \(ratio):1",
                    file: file, line: line
                )
            }
        }
    }

    // MARK: The helper is the WCAG measure

    func testTheHelperGivesTheTwoEndsOfTheScale() {
        XCTAssertEqual(
            Self.contrastRatio(.black, on: .white, appearance: .aqua), 21, accuracy: 0.01)
        XCTAssertEqual(
            Self.contrastRatio(.white, on: .white, appearance: .aqua), 1, accuracy: 0.01)
    }

    func testAHalfTransparentInkIsJudgedAsItsBlend() {
        // Half black on white is mid grey, which is a known 3.9:1 and
        // not the 21:1 the alpha would hide if it went unblended.
        let half = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
        XCTAssertEqual(Self.contrastRatio(half, on: .white, appearance: .aqua), 3.95, accuracy: 0.05)
    }

    func testTheAppearanceAskedAboutIsTheOneResolved() {
        // The primary label is near black in light and near white in
        // dark; asking for each appearance by name must give each one.
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        var lightLabel: CGFloat = 0
        var darkLabel: CGFloat = 0
        light.performAsCurrentDrawingAppearance {
            lightLabel = Self.relativeLuminance(Self.composite(.labelColor, over: .white))
        }
        dark.performAsCurrentDrawingAppearance {
            darkLabel = Self.relativeLuminance(Self.composite(.labelColor, over: .black))
        }
        XCTAssertLessThan(lightLabel, 0.1)
        XCTAssertGreaterThan(darkLabel, 0.6)
    }

    // MARK: The system's own text ink, on both backings

    func testThePrimaryLabelClearsTheBarOnPageAndCard() {
        assertClearsTheBar(.labelColor, named: "the primary label")
    }

    // MARK: Ember as ink (D-03)

    func testEmberTextClearsTheBarOnPageAndCard() {
        assertClearsTheBar(.emberText, named: "ember text")
    }

    func testEmberTextIsTheFillDarkenedInLightAndLightenedInDark() {
        // The token is the accent's hue moved toward the ink's end of
        // the scale in each appearance, which is why one token serves
        // both: darker than the fill under light, lighter under dark.
        let fill = NSColor(srgbHex: 0xDC4A22)
        let fillLuminance = Self.relativeLuminance(fill)
        var light: CGFloat = 0
        var dark: CGFloat = 0
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            light = Self.relativeLuminance(Self.composite(.emberText, over: .white))
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            dark = Self.relativeLuminance(Self.composite(.emberText, over: .black))
        }
        XCTAssertLessThan(light, fillLuminance)
        XCTAssertGreaterThan(dark, fillLuminance)
    }

    func testTheFillItselfIsBelowTheBarWhichIsWhyTheInkExists() {
        // Not a target to fix: the fill is never text. This pins the
        // reason the second token is there at all.
        let fill = NSColor(srgbHex: 0xDC4A22)
        XCTAssertLessThan(Self.contrastRatio(fill, on: .white, appearance: .aqua), Self.bar)
    }

    // MARK: The fence token ramp (D-06)

    /// Each of the four inks clears the bar on the wash it is drawn on,
    /// under both appearances. The message names the pair that missed.
    func testTheFourTokenInksClearTheBarOnTheFenceWash() {
        let inks: [(String, NSColor)] = [
            ("the keyword ink", .inkKeyword),
            ("the string ink", .inkString),
            ("the comment ink", .inkComment),
            ("the number ink", .inkNumber),
        ]
        for (inkName, ink) in inks {
            for appearance in Self.appearances {
                for (washName, layers) in Self.fenceWashes {
                    let ratio = Self.contrastRatio(ink, over: layers, appearance: appearance)
                    XCTAssertGreaterThanOrEqual(
                        ratio, Self.bar,
                        "\(inkName) on \(washName) under \(appearance.rawValue) reads \(ratio):1")
                }
            }
        }
    }

    /// The system hues the ramp descends from do not clear the wash,
    /// which is the whole reason the ramp exists rather than the hues.
    func testTheSystemHuesThemselvesMissTheWashUnderLight() {
        for hue in [NSColor.systemPurple, .systemRed, .systemBlue] {
            let ratio = Self.contrastRatio(
                hue, over: Self.fenceWashes[0].1, appearance: .aqua)
            XCTAssertLessThan(ratio, Self.bar)
        }
    }

    /// The four are told apart by hue, not only by depth: no two share
    /// a shade in either appearance. A ramp that darkened them into one
    /// grey would pass the bar and lose the point of colouring.
    func testTheFourTokenInksStayDistinct() {
        for appearance in Self.appearances {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let shades = [NSColor.inkKeyword, .inkString, .inkComment, .inkNumber]
                    .map { Self.composite($0, over: .white) }
                    .map { [$0.redComponent, $0.greenComponent, $0.blueComponent] }
                for i in shades.indices {
                    for j in shades.indices where j > i {
                        XCTAssertNotEqual(shades[i], shades[j])
                    }
                }
            }
        }
    }
}
