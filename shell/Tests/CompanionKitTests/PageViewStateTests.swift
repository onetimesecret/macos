import AppKit
import XCTest

@testable import CompanionKit

/// A page's caret and scroll belong to the model, so the place one
/// editor leaves is the place the next one finds (issue #198).
///
/// One editor serves every page (ADR-0006), but it is not the only
/// editor a page will ever meet: a ledger round trip builds another,
/// and the editor window builds one of its own beside the panel's
/// (ADR-0033). Each comes with a fresh coordinator. While the place was
/// kept in the coordinator, every one of those started the page from
/// the top with the caret at zero. `EditorPersistenceTests` holds the
/// round trip through one editor; this suite holds the trip from one
/// editor to a different one.
///
/// The two windows are not the same width, and a paragraph wraps into a
/// different number of lines in each, so the scroll is kept as the line
/// at the top of the clip (`ScrollAnchor`) and never as a distance in
/// points. The width cases below are built so that a distance would
/// have failed them.
///
/// Real AppKit in headless windows, in the `PageScrollTests` idiom, and
/// every model is built with its seams named, so nothing here reaches
/// the installed app's state directory.
@MainActor
final class PageViewStateTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-page-view-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return isolatedModel(defaults: defaults)
    }

    private func mintPage(in model: PageModel) throws -> UInt64 {
        model.newPage()
        return try XCTUnwrap(model.selectedPageID)
    }

    /// One mounted editor: a coordinator of its own, a text view built
    /// by the shipped factory, and the scroller the page surface wraps
    /// it in, inside a window of the given width. The window is
    /// returned so the caller keeps the whole mount alive.
    private struct Mount {
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let scroll: NSScrollView
        let window: NSWindow
    }

    private func mount(
        _ page: UInt64, of model: PageModel, width: CGFloat, height: CGFloat = 160
    ) -> Mount {
        let coordinator = InkEditorView.Coordinator(model: model)
        let textView = InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator
        )
        let scroll = InkEditorView.scrollStack(for: textView)
        let card = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        return Mount(coordinator: coordinator, textView: textView, scroll: scroll, window: window)
    }

    private func settleLayout(of mount: Mount) throws {
        let container = try XCTUnwrap(mount.textView.textContainer)
        mount.textView.layoutManager?.ensureLayout(for: container)
        mount.scroll.layoutSubtreeIfNeeded()
    }

    /// The scroll restore lands one main queue hop after it is asked
    /// for (ADR-0005's timing discipline), so the loop is turned once
    /// to let it.
    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: The table's own laws

    func testARepairMendsAnEntryAndNeverResurrectsOne() {
        var states = PageViewStates()
        states.saveScroll(ScrollAnchor(characterIndex: 10), for: 1)

        states.repairScroll(ScrollAnchor(characterIndex: 90), for: 1)
        states.repairScroll(ScrollAnchor(characterIndex: 90), for: 2)

        XCTAssertEqual(states.scrolls[1], ScrollAnchor(characterIndex: 90))
        XCTAssertNil(states.scrolls[2], "a page pruned in the interim stays gone")
    }

    /// The page that had no place before the early save wrote one: what
    /// the repair puts back is the absence, so the page opens at its
    /// top rather than wherever the previous page's clip happened to be.
    func testARepairWithNoAnchorPutsTheAbsenceBack() {
        var states = PageViewStates()
        states.saveScroll(ScrollAnchor(characterIndex: 10), for: 1)

        states.repairScroll(nil, for: 1)

        XCTAssertNil(states.scrolls[1])
    }

    func testThePruneTakesADeadPagesPlaceAndKeepsAFiles() {
        let file = CompanionClient.fileIDTag | 4
        var states = PageViewStates()
        for id in [1, 2, file] {
            states.saveCaret(NSRange(location: 3, length: 0), for: id)
            states.saveScroll(ScrollAnchor(characterIndex: 20), for: id)
        }

        states.prune(keeping: [1])

        XCTAssertEqual(states.keys, [1, file])
        XCTAssertNil(states.carets[2])
        XCTAssertNil(states.scrolls[2])

        states.forget(file)
        XCTAssertEqual(states.keys, [1], "a file's place goes when the roster drops it by name")
    }

    /// The model prunes the table where it prunes the storage cache, so
    /// a page that dies takes its place with it whether or not any
    /// editor is mounted to notice.
    func testAClosedPagesPlaceIsPrunedByTheModelsRefresh() throws {
        let model = try makeModel()
        let kept = try mintPage(in: model)
        let closed = try mintPage(in: model)
        model.viewStates.saveCaret(NSRange(location: 1, length: 0), for: kept)
        model.viewStates.saveCaret(NSRange(location: 1, length: 0), for: closed)
        let tab = try XCTUnwrap(model.tabs.first { $0.pageID == closed }?.id)

        model.close(tab)

        XCTAssertNotNil(model.viewStates.carets[kept])
        XCTAssertNil(
            model.viewStates.carets[closed],
            "a dead page's caret would be waiting for whatever page took its slot")
    }

    // MARK: From one editor to another

    func testAPlaceSavedByOneEditorIsRestoredByAnother() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let first = mount(page, of: model, width: 420)

        let text = (0..<80).map { "line \($0) of the page\n" }.joined()
        first.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        let caret = NSRange(location: text.utf16.count / 2, length: 3)
        first.textView.setSelectedRange(caret)
        try settleLayout(of: first)
        let bottom = first.textView.frame.height - first.scroll.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 0, "the fixture must outgrow its card")
        let offset = NSPoint(x: 0, y: (bottom / 2).rounded())
        first.scroll.contentView.scroll(to: offset)
        first.scroll.reflectScrolledClipView(first.scroll.contentView)

        first.coordinator.saveViewState(textView: first.textView, scrollView: first.scroll)

        // A different editor, with a different coordinator, over the
        // same page: the ledger round trip's shape, and the hand off
        // between two windows'.
        let second = mount(page, of: model, width: 420)
        XCTAssertFalse(second.coordinator === first.coordinator)
        XCTAssertEqual(second.textView.selectedRange(), NSRange(location: 0, length: 0))

        second.coordinator.restoreViewState(
            textView: second.textView, scrollView: second.scroll, for: page
        )
        pump()

        XCTAssertEqual(
            second.textView.selectedRange(), caret,
            "the caret is the page's, whichever editor is standing on it")
        XCTAssertEqual(
            second.scroll.contentView.bounds.origin.y, offset.y, accuracy: 0.5,
            "the second editor opened the page somewhere the person was not")
    }

    // MARK: Across two widths

    /// Paragraphs long enough to wrap, so the number of lines above any
    /// given sentence depends on the measure, which is the whole reason
    /// a distance in points cannot be handed from one window to another.
    private func wrappingText() -> String {
        (0..<40).map { paragraph in
            "paragraph \(paragraph) " + (0..<45).map { "word\($0)" }.joined(separator: " ") + "\n"
        }.joined()
    }

    /// The characters of the line standing at the top of the clip, and
    /// where that line's top edge is in the document view.
    private func topLine(of mount: Mount) throws -> (characters: NSRange, minY: CGFloat) {
        let layoutManager = try XCTUnwrap(mount.textView.layoutManager)
        let container = try XCTUnwrap(mount.textView.textContainer)
        let origin = mount.textView.textContainerOrigin
        let top = mount.scroll.contentView.bounds.origin.y - origin.y
        // A hair inside the line, so a top edge resting exactly on the
        // boundary between two lines reads as the lower one.
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: top + 0.5), in: container)
        var glyphs = NSRange(location: 0, length: 0)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        return (
            layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil),
            rect.minY + origin.y
        )
    }

    /// Scroll `mount` so the line holding `character` sits exactly at
    /// the top of its clip, and answer the offset that took.
    private func scroll(_ mount: Mount, toLineOf character: Int) throws -> CGFloat {
        let layoutManager = try XCTUnwrap(mount.textView.layoutManager)
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = line.minY + mount.textView.textContainerOrigin.y
        mount.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        mount.scroll.reflectScrolledClipView(mount.scroll.contentView)
        return y
    }

    func testAPlaceSavedInANarrowEditorLandsTheSameLineInAWideOne() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let narrow = mount(page, of: model, width: 320)
        let text = wrappingText()
        narrow.textView.insertText(
            text, replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try settleLayout(of: narrow)
        let narrowOffset = try scroll(narrow, toLineOf: text.utf16.count / 2)
        let read = try topLine(of: narrow).characters
        let caret = NSRange(location: read.location + 5, length: 0)
        narrow.textView.setSelectedRange(caret)

        narrow.coordinator.saveViewState(textView: narrow.textView, scrollView: narrow.scroll)

        XCTAssertEqual(
            model.viewStates.scrolls[page]?.characterIndex, read.location,
            "the place is kept as the first character of the line at the top")

        let wide = mount(page, of: model, width: 640)
        wide.coordinator.restoreViewState(
            textView: wide.textView, scrollView: wide.scroll, for: page
        )
        pump()

        let landed = try topLine(of: wide)
        XCTAssertTrue(
            NSLocationInRange(read.location, landed.characters),
            "the wide editor opened on line \(landed.characters), which does not hold "
                + "character \(read.location) that the narrow one was reading from")
        XCTAssertEqual(
            wide.scroll.contentView.bounds.origin.y, landed.minY, accuracy: 0.5,
            "the line is on screen but not at the top")
        XCTAssertEqual(wide.textView.selectedRange(), caret)
        // The fixture has to be one where points would have failed, or
        // the two assertions above prove nothing about the anchor.
        XCTAssertGreaterThan(
            narrowOffset - wide.scroll.contentView.bounds.origin.y, 100,
            "the two measures laid this page out alike, so the offset alone would have passed")
    }

    /// And the way back, which is the rest of a hand off: the wide
    /// editor's place, restored into a narrow one.
    func testAPlaceSavedInAWideEditorLandsTheSameLineInANarrowOne() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let wide = mount(page, of: model, width: 640)
        let text = wrappingText()
        wide.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        try settleLayout(of: wide)
        let wideOffset = try scroll(wide, toLineOf: text.utf16.count / 2)
        let read = try topLine(of: wide).characters

        wide.coordinator.saveViewState(textView: wide.textView, scrollView: wide.scroll)

        let narrow = mount(page, of: model, width: 320)
        narrow.coordinator.restoreViewState(
            textView: narrow.textView, scrollView: narrow.scroll, for: page
        )
        pump()

        let landed = try topLine(of: narrow)
        XCTAssertTrue(NSLocationInRange(read.location, landed.characters))
        XCTAssertEqual(
            narrow.scroll.contentView.bounds.origin.y, landed.minY, accuracy: 0.5)
        XCTAssertGreaterThan(narrow.scroll.contentView.bounds.origin.y - wideOffset, 100)
    }

    /// The top inset sits above the first line, so a page left at the
    /// very top is a negative fraction of that line rather than the
    /// line's own top edge, and it comes back at zero at any width.
    func testAPageLeftAtTheVeryTopComesBackAtTheVeryTop() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let narrow = mount(page, of: model, width: 320)
        narrow.textView.insertText(
            wrappingText(), replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try settleLayout(of: narrow)
        // Typing followed the caret to the end of the page, so the top
        // is somewhere the fixture has to go back to.
        narrow.scroll.contentView.scroll(to: .zero)
        narrow.scroll.reflectScrolledClipView(narrow.scroll.contentView)
        XCTAssertEqual(narrow.scroll.contentView.bounds.origin.y, 0)

        narrow.coordinator.saveViewState(textView: narrow.textView, scrollView: narrow.scroll)

        let wide = mount(page, of: model, width: 640)
        wide.scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
        wide.coordinator.restoreViewState(
            textView: wide.textView, scrollView: wide.scroll, for: page
        )
        pump()

        XCTAssertEqual(wide.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
    }

    /// Content can shrink while a page is in the background. The anchor
    /// names a character the page may no longer have, and the layout
    /// manager raises on an index it does not hold, so the lookup is
    /// clamped to the page as it now stands.
    func testAnAnchorPastTheEndOfAShrunkenPageResolvesToItsLastLine() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let editor = mount(page, of: model, width: 420)
        editor.textView.insertText(
            "one\ntwo\nthree", replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try settleLayout(of: editor)
        let layoutManager = try XCTUnwrap(editor.textView.layoutManager)
        let lastLine = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil
        )

        let offset = try XCTUnwrap(
            ScrollAnchor(characterIndex: 5_000).offset(in: editor.textView)
        )

        XCTAssertEqual(
            offset.y, lastLine.minY + editor.textView.textContainerOrigin.y, accuracy: 0.5)
    }

    func testAnEmptyPageStillHasAPlace() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let editor = mount(page, of: model, width: 420)

        let anchor = try XCTUnwrap(ScrollAnchor(topOf: editor.textView, clipOrigin: .zero))
        let offset = try XCTUnwrap(anchor.offset(in: editor.textView))

        XCTAssertEqual(anchor.characterIndex, 0)
        XCTAssertEqual(offset.y, 0, accuracy: 0.5, "the top of an empty page is its top")
    }
}
