import AppKit
import XCTest

@testable import CompanionKit

/// The page's face and size as a setting: what a typeface resolves to,
/// how the ramp follows it, and how the two fields reach the page.
///
/// Real fonts, because the question is what the system does with a
/// name: Menlo ships on every Mac and a family nobody has installed
/// must fall back rather than fail. The styling is a process-wide
/// value (`InkStyle.typeface`), so every test here puts the standard
/// back on the way out.
@MainActor
final class TypefaceTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated { InkStyle.typeface = .standard }
        super.tearDown()
    }

    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let suite = "typeface-tests-\(name)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: Resolution

    func testTheStandardTypefaceIsTheSystemMonospacedFaceAtThirteen() {
        let expected = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(InkStyle.Typeface.standard.font(size: 13, weight: .regular), expected)
        XCTAssertTrue(InkStyle.Typeface.standard.usesSystemFamily)
        XCTAssertTrue(InkStyle.Typeface.standard.isInstalled)
    }

    func testANamedFamilyResolvesToThatFamilyAtTheAskedSize() {
        let menlo = InkStyle.Typeface(family: "Menlo", size: 16)
        let font = menlo.font(size: 16, weight: .regular)
        XCTAssertEqual(font.familyName, "Menlo")
        XCTAssertEqual(font.pointSize, 16)
        XCTAssertTrue(menlo.isInstalled)
    }

    /// The user types "menlo"; the system says "Menlo". Same family.
    func testTheFamilyIsMatchedWithoutRegardToCase() {
        let typed = InkStyle.Typeface(family: "menlo", size: 13)
        XCTAssertTrue(typed.isInstalled)
        XCTAssertEqual(typed.font(size: 13, weight: .regular).familyName, "Menlo")
    }

    func testAFamilyNobodyHasFallsBackToTheSystemFace() {
        let missing = InkStyle.Typeface(family: "No Such Family 9f3a", size: 15)
        XCTAssertFalse(missing.isInstalled)
        XCTAssertEqual(
            missing.font(size: 15, weight: .regular),
            NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        )
    }

    func testTheSizeIsClampedAndWhole() {
        XCTAssertEqual(InkStyle.Typeface(family: "", size: 2).size, 8)
        XCTAssertEqual(InkStyle.Typeface(family: "", size: 400).size, 40)
        XCTAssertEqual(InkStyle.Typeface(family: "", size: 13.4).size, 13)
        XCTAssertEqual(InkStyle.Typeface(family: "  Menlo ", size: 13).family, "Menlo")
    }

    // MARK: The ramp

    func testTheRampAtTheStandardSizeIsWhatThePageAlwaysWore() {
        InkStyle.typeface = .standard
        XCTAssertEqual(InkStyle.baseFont.pointSize, 13)
        XCTAssertEqual(InkStyle.headingFont(level: 1).pointSize, 17)
        XCTAssertEqual(InkStyle.headingFont(level: 2).pointSize, 15)
        XCTAssertEqual(InkStyle.headingFont(level: 3).pointSize, 14)
        XCTAssertEqual(InkStyle.headingFont(level: 4).pointSize, 13)
    }

    func testTheRampScalesWithTheBaseSize() {
        InkStyle.typeface = InkStyle.Typeface(family: "", size: 26)
        XCTAssertEqual(InkStyle.baseFont.pointSize, 26)
        XCTAssertEqual(InkStyle.headingFont(level: 1).pointSize, 34)
        XCTAssertEqual(InkStyle.headingFont(level: 2).pointSize, 30)
        XCTAssertEqual(InkStyle.headingFont(level: 3).pointSize, 28)
        XCTAssertEqual(InkStyle.headingFont(level: 4).pointSize, 26)
    }

    func testTheCellFollowsTheTypeface() {
        InkStyle.typeface = .standard
        let narrow = InkStyle.cellWidth
        InkStyle.typeface = InkStyle.Typeface(family: "", size: 26)
        XCTAssertEqual(InkStyle.cellWidth, narrow * 2, accuracy: 0.5)
        XCTAssertEqual(InkStyle.hangingIndent(markerLength: 2), InkStyle.cellWidth * 2)
        InkStyle.typeface = InkStyle.Typeface(family: "Menlo", size: 13)
        XCTAssertEqual(InkStyle.baseFont.familyName, "Menlo")
        XCTAssertEqual(InkStyle.headingFont(level: 1).familyName, "Menlo")
    }

    // MARK: The setting

    func testAPageOpensInTheStandardTypefaceUntilToldOtherwise() throws {
        let model = isolatedModel(defaults: try makeDefaults("default"))
        XCTAssertEqual(model.fontFamily, "")
        XCTAssertEqual(model.fontSize, 13)
        XCTAssertEqual(model.typeface, .standard)
        XCTAssertEqual(InkStyle.typeface, .standard)
    }

    func testTheSettingSticksAndReachesTheStyling() throws {
        let defaults = try makeDefaults("persistence")
        let model = isolatedModel(defaults: defaults)
        model.fontFamily = "Menlo"
        model.fontSize = 18
        XCTAssertEqual(InkStyle.typeface, InkStyle.Typeface(family: "Menlo", size: 18))
        XCTAssertEqual(InkStyle.baseFont.familyName, "Menlo")
        XCTAssertEqual(InkStyle.baseFont.pointSize, 18)

        InkStyle.typeface = .standard
        let reopened = isolatedModel(defaults: defaults)
        XCTAssertEqual(reopened.fontFamily, "Menlo")
        XCTAssertEqual(reopened.fontSize, 18)
        XCTAssertEqual(InkStyle.typeface, reopened.typeface, "a relaunch styles in what was saved")
    }

    func testTheModelClampsTheSizeAndTrimsTheFamily() throws {
        let model = isolatedModel(defaults: try makeDefaults("clamp"))
        model.fontSize = 3
        XCTAssertEqual(model.fontSize, 8)
        model.fontSize = 99
        XCTAssertEqual(model.fontSize, 40)
        model.fontFamily = "  Menlo  "
        XCTAssertEqual(model.fontFamily, "Menlo")
    }

    /// A family typed before the font is installed is kept, and the
    /// page wears the fallback in the meantime: the setting says what
    /// the user wants, the styling says what the Mac can do.
    func testAMissingFamilyIsKeptAsTypedAndDrawnAsTheSystemFace() throws {
        let model = isolatedModel(defaults: try makeDefaults("missing"))
        model.fontFamily = "No Such Family 9f3a"
        XCTAssertEqual(model.fontFamily, "No Such Family 9f3a")
        XCTAssertFalse(model.typeface.isInstalled)
        XCTAssertEqual(InkStyle.baseFont, NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    // MARK: The page

    /// The mounted page follows the setting on the next pass: every
    /// line is laid down in the new base font, a heading in the ramp
    /// derived from it, and the caret types in it too.
    func testTheMountedPageIsRestyledInTheNewTypeface() throws {
        let model = isolatedModel(defaults: try makeDefaults("restyle"))
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let coordinator = InkEditorView.Coordinator(model: model)
        let textView = InkEditorView.makeInkTextView(model: model, sheetID: page, coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(textView)
        textView.insertText("# heading\nbody line\n", replacementRange: NSRange(location: 0, length: 0))
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 17)

        model.fontSize = 20
        coordinator.applyTypeface(model.typeface)

        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 26)
        let bodyStart = ("# heading\n" as NSString).length
        XCTAssertEqual((storage.attribute(.font, at: bodyStart, effectiveRange: nil) as? NSFont)?.pointSize, 20)
        XCTAssertEqual((textView.typingAttributes[.font] as? NSFont)?.pointSize, 20)
    }

    /// A quiet day's rendering carries its font in its attributes, so
    /// the model forgets every rendering when the typeface moves and
    /// the roll re-reads them in the new face.
    func testQuietRenderingsAreReadAgainInTheNewTypeface() throws {
        let model = isolatedModel(defaults: try makeDefaults("quiet"))
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let before = model.quietRendering(for: page)
        XCTAssertTrue(model.quietRendering(for: page) === before, "an unchanged day is the same object")

        model.fontSize = 20

        let after = model.quietRendering(for: page)
        XCTAssertFalse(after === before)
    }
}
