import AppKit
import XCTest

@testable import CompanionKit

/// The preview-rendering scope preference gates whether markdown and
/// syntax-highlight styling reach the roll's quiet pages, the focused
/// editor only, or nowhere. The setting is at `PageModel.previewRendering`;
/// the scope enum is `PreviewRenderingScope` and defaults to `.allPages`.
///
/// The specimens fixed here (a heading, a fenced Swift block, a chip)
/// exercise every branch the scope discriminates: `.focusedOnly` leaves
/// the quiet region flat and unstyled, `.allPages` renders heading and
/// code faces plus token colour, and `.never` folds identically to
/// `.focusedOnly`. Chip attachments must survive every mode: they are
/// non-secret faces already, and the scope never disowns them.
///
/// The implementer is landing the property, the setter's cache
/// invalidation and the change notification in parallel; this file is
/// written against that contract and is expected to fail to build until
/// those symbols exist.
@MainActor
final class PageModelPreviewRenderingTests: XCTestCase {

    // MARK: Fixture helpers

    private func makeDefaults(_ label: String = #function) throws -> UserDefaults {
        let suite = "companion-preview-rendering-\(label)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    /// A page whose core document is a heading followed by a fenced
    /// Swift block, then trailing prose: enough surface to see heading
    /// font, code font and syntax colour under `.allPages`.
    private static let markdownFixture = """
        # Title heading line

        ```swift
        let value = 1
        print(value)
        ```

        trailing prose
        """

    /// Seeds `sheet` with the markdown fixture through the core's own
    /// mirror, then invalidates the roll's cache so the next
    /// `quietRendering` rebuilds against the seeded runs.
    private func seedMarkdown(model: PageModel, sheet: UInt64) {
        let json = #"[{"ink": "\#(Self.markdownFixture.replacingOccurrences(of: "\n", with: "\\n"))"}]"#
        XCTAssertTrue(model.coreClient.syncDocument(sheet: sheet, json: json))
        model.invalidateQuietRendering(for: sheet)
    }

    /// Seeds `sheet` with a leading ink run, a chip in the middle, and
    /// a trailing ink run. Returns the chip's id.
    @discardableResult
    private func seedChipDocument(model: PageModel, sheet: UInt64) throws -> UInt64 {
        let chip = try XCTUnwrap(
            model.coreClient.sealText(sheet: sheet, "swordfish", at: 0, length: 0),
            "the core refused to seal the fixture text"
        )
        let json = #"[{"ink": "before "}, {"chip": \#(chip.chipId)}, {"ink": " after"}]"#
        XCTAssertTrue(model.coreClient.syncDocument(sheet: sheet, json: json))
        model.invalidateQuietRendering(for: sheet)
        return chip.chipId
    }

    /// True when any character run in `rendered` carries a `.font`
    /// attribute distinct from `InkStyle.baseFont`.
    private func hasNonBaseFont(_ rendered: NSAttributedString) -> Bool {
        var seen = false
        rendered.enumerateAttribute(
            .font, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, stop in
            if let font = value as? NSFont, font != InkStyle.baseFont {
                seen = true
                stop.pointee = true
            }
        }
        return seen
    }

    /// True when any character run carries a foreground colour distinct
    /// from `NSColor.labelColor` (the flat quiet colour).
    private func hasNonLabelForeground(_ rendered: NSAttributedString) -> Bool {
        var seen = false
        rendered.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, stop in
            if let color = value as? NSColor, color != NSColor.labelColor {
                seen = true
                stop.pointee = true
            }
        }
        return seen
    }

    /// True when at least one character range carries a font matching
    /// `expected`.
    private func containsFont(_ rendered: NSAttributedString, matching expected: NSFont) -> Bool {
        var seen = false
        rendered.enumerateAttribute(
            .font, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, stop in
            if let font = value as? NSFont, font == expected {
                seen = true
                stop.pointee = true
            }
        }
        return seen
    }

    /// True when `rendered` carries at least one `ChipAttachment`.
    private func containsChipAttachment(_ rendered: NSAttributedString) -> Bool {
        var seen = false
        rendered.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, stop in
            if value is ChipAttachment {
                seen = true
                stop.pointee = true
            }
        }
        return seen
    }

    /// True when every character carries `.font == InkStyle.baseFont`
    /// and `.foregroundColor == NSColor.labelColor`. Attachment ranges
    /// are exempt: a chip glyph does not carry the ink attributes.
    private func isFlatQuiet(_ rendered: NSAttributedString) -> Bool {
        var flat = true
        rendered.enumerateAttributes(
            in: NSRange(location: 0, length: rendered.length)
        ) { attrs, _, stop in
            if attrs[.attachment] != nil { return }
            if (attrs[.font] as? NSFont) != InkStyle.baseFont {
                flat = false
                stop.pointee = true
                return
            }
            if (attrs[.foregroundColor] as? NSColor) != NSColor.labelColor {
                flat = false
                stop.pointee = true
            }
        }
        return flat
    }

    // MARK: 1. Default value

    func testFreshModelDefaultsToAllPages() throws {
        let defaults = try makeDefaults()
        let model = isolatedModel(defaults: defaults)

        XCTAssertEqual(model.previewRendering, .allPages)
    }

    // MARK: 2. UserDefaults round-trip

    func testFocusedOnlyPersistsAndSurvivesRelaunch() throws {
        let defaults = try makeDefaults()
        let first = isolatedModel(defaults: defaults)

        first.previewRendering = .focusedOnly

        XCTAssertEqual(defaults.string(forKey: "previewRendering"), "focusedOnly")
        let second = isolatedModel(defaults: defaults)
        XCTAssertEqual(second.previewRendering, .focusedOnly)
    }

    // MARK: 3. Quiet rendering under .focusedOnly

    func testFocusedOnlyLeavesQuietRenderingFlat() throws {
        let defaults = try makeDefaults()
        let model = isolatedModel(defaults: defaults)
        model.newPage()
        let sheet = try XCTUnwrap(model.selection)
        model.previewRendering = .focusedOnly
        seedMarkdown(model: model, sheet: sheet)

        let rendered = model.quietRendering(for: sheet)

        XCTAssertTrue(
            isFlatQuiet(rendered),
            "focusedOnly must leave every ink run at baseFont + labelColor")
        XCTAssertFalse(
            hasNonBaseFont(rendered),
            "focusedOnly must not distinguish heading or code font")
        XCTAssertFalse(
            hasNonLabelForeground(rendered),
            "focusedOnly must not carry syntax colour")
    }

    // MARK: 4. Quiet rendering under .allPages

    func testAllPagesRendersHeadingAndCodeFonts() throws {
        let defaults = try makeDefaults()
        let model = isolatedModel(defaults: defaults)
        model.newPage()
        let sheet = try XCTUnwrap(model.selection)
        model.previewRendering = .allPages
        seedMarkdown(model: model, sheet: sheet)

        let rendered = model.quietRendering(for: sheet)

        XCTAssertTrue(
            containsFont(rendered, matching: InkStyle.headingFont(level: 1)),
            "allPages must lay the heading font over the heading line")
        XCTAssertTrue(
            containsFont(rendered, matching: InkStyle.font(for: .code)),
            "allPages must lay the code font over fence content")
    }

    func testAllPagesCarriesSyntaxColourWhenHighlightingEnabled() throws {
        let defaults = try makeDefaults()
        let model = isolatedModel(defaults: defaults)
        model.newPage()
        let sheet = try XCTUnwrap(model.selection)
        model.syntaxHighlightingEnabled = true
        model.previewRendering = .allPages
        seedMarkdown(model: model, sheet: sheet)

        let rendered = model.quietRendering(for: sheet)

        XCTAssertTrue(
            hasNonLabelForeground(rendered),
            "with syntax highlighting on, at least one fence token must carry a token colour")
    }

    // MARK: 5. Quiet rendering under .never

    func testNeverMatchesFocusedOnlyProfile() throws {
        let defaults = try makeDefaults()
        let model = isolatedModel(defaults: defaults)
        model.newPage()
        let sheet = try XCTUnwrap(model.selection)
        model.previewRendering = .never
        seedMarkdown(model: model, sheet: sheet)

        let rendered = model.quietRendering(for: sheet)

        XCTAssertTrue(
            isFlatQuiet(rendered),
            "never must leave every ink run at baseFont + labelColor")
        XCTAssertFalse(hasNonBaseFont(rendered))
        XCTAssertFalse(hasNonLabelForeground(rendered))
    }

    // MARK: 6. Cache invalidation on scope change

    func testChangingScopeInvalidatesQuietRenderingCache() throws {
        let defaults = try makeDefaults()
        let model = isolatedModel(defaults: defaults)
        model.newPage()
        let sheet = try XCTUnwrap(model.selection)
        model.previewRendering = .allPages
        seedMarkdown(model: model, sheet: sheet)

        let first = model.quietRendering(for: sheet)
        model.previewRendering = .focusedOnly
        let second = model.quietRendering(for: sheet)

        XCTAssertFalse(
            first === second,
            "changing preview scope must drop the cached rendering")
        XCTAssertTrue(hasNonBaseFont(first), "allPages baseline missed heading/code fonts")
        XCTAssertFalse(
            hasNonBaseFont(second),
            "focusedOnly rebuild must be flat after the scope flip")
    }

    // MARK: 7. Notification fires on change

    func testNotificationFiresExactlyOncePerDistinctChange() throws {
        let defaults = try makeDefaults()
        let model = isolatedModel(defaults: defaults)

        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: PageModel.previewRenderingDidChangeNotification,
            object: model,
            queue: nil
        ) { _ in count += 1 }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }

        model.previewRendering = .focusedOnly
        XCTAssertEqual(count, 1, "one notification per genuine change")

        model.previewRendering = .focusedOnly
        XCTAssertEqual(count, 1, "an assignment to the same value must not post")

        model.previewRendering = .never
        XCTAssertEqual(count, 2, "a second distinct change posts once more")
    }

    // MARK: 8. Chip preservation

    func testChipAttachmentSurvivesEveryScope() throws {
        for scope in PreviewRenderingScope.allCases {
            let defaults = try makeDefaults("chip-\(scope.rawValue)")
            let model = isolatedModel(defaults: defaults)
            model.newPage()
            let sheet = try XCTUnwrap(model.selection)
            model.previewRendering = scope
            _ = try seedChipDocument(model: model, sheet: sheet)

            let rendered = model.quietRendering(for: sheet)

            XCTAssertTrue(
                containsChipAttachment(rendered),
                "the chip attachment must survive scope \(scope.rawValue)")
        }
    }
}
