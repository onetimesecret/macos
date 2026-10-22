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

    /// One mounted editor: a coordinator of its own and the page
    /// surface the shipped mount builds (`InkEditorView.makePage` is
    /// the call `makeNSView` makes), inside a window of the given
    /// width. The window is returned so the caller keeps the whole
    /// mount alive.
    private struct Mount {
        let coordinator: InkEditorView.Coordinator
        let textView: InkTextView
        let scroll: NSScrollView
        let window: NSWindow
    }

    private func mount(
        _ page: UInt64, of model: PageModel, width: CGFloat, height: CGFloat = 160
    ) throws -> Mount {
        let coordinator = InkEditorView.Coordinator(model: model)
        let scroll = InkEditorView.makePage(
            model: model, sheetID: page, readOnly: false, coordinator: coordinator
        )
        let textView = try XCTUnwrap(scroll.documentView as? InkTextView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let mount = Mount(
            coordinator: coordinator, textView: textView, scroll: scroll, window: window
        )
        size(mount, width: width, height: height)
        // Let the mount's own restore land before the test touches the
        // clip. A hop still in flight holds the anchor it was handed,
        // and when its editor goes before it lands it puts that anchor
        // back over whatever was saved in between, which is right for
        // an editor that never showed the page and wrong for a fixture
        // that scrolled one by hand without waiting.
        pump()
        return mount
    }

    /// Give the mount's scroller its frame, which is SwiftUI's part of
    /// a mount and arrives when SwiftUI pleases.
    private func size(_ mount: Mount, width: CGFloat, height: CGFloat = 160) {
        if mount.scroll.superview == nil {
            mount.window.contentView?.addSubview(mount.scroll)
        }
        mount.scroll.frame = NSRect(x: 0, y: 0, width: width, height: height)
        mount.scroll.layoutSubtreeIfNeeded()
    }

    /// The mount going away, as SwiftUI takes it down.
    private func dismantle(_ mount: Mount) {
        mount.scroll.removeFromSuperview()
        InkEditorView.dismantleNSView(mount.scroll, coordinator: mount.coordinator)
    }

    private func settleLayout(of mount: Mount) throws {
        let container = try XCTUnwrap(mount.textView.textContainer)
        mount.textView.layoutManager?.ensureLayout(for: container)
        mount.scroll.layoutSubtreeIfNeeded()
    }

    /// The scroll restore lands one main queue hop after it is asked
    /// for (ADR-0005's timing discipline), so the test waits behind it
    /// on the same queue, by order and never by the clock
    /// (`drainMainQueue`).
    private func pump() {
        drainMainQueue()
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
        let first = try mount(page, of: model, width: 420)

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

        // The old mount goes and then the new one comes, which is the
        // order a hand off between two windows has to keep. A different
        // editor, with a different coordinator, over the same page: the
        // ledger round trip's shape too. Nothing below asks for a save
        // or a restore by name; the mount and the dismantle do both.
        dismantle(first)
        let second = try mount(page, of: model, width: 420)
        XCTAssertFalse(second.coordinator === first.coordinator)
        XCTAssertFalse(second.textView === first.textView)
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

    /// A character well inside a paragraph in the middle of the page,
    /// so the line it stands on at either width begins partway through
    /// the paragraph. A line that began a paragraph would begin the
    /// same line at every measure and prove much less.
    private func midParagraph(of text: String) -> Int {
        (text as NSString).range(of: "paragraph 20 ").location + 200
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
        let narrow = try mount(page, of: model, width: 320)
        let text = wrappingText()
        narrow.textView.insertText(
            text, replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try settleLayout(of: narrow)
        let narrowOffset = try scroll(narrow, toLineOf: midParagraph(of: text))
        let read = try topLine(of: narrow).characters
        let caret = NSRange(location: read.location + 5, length: 0)
        narrow.textView.setSelectedRange(caret)

        dismantle(narrow)

        XCTAssertEqual(
            model.viewStates.scrolls[page]?.characterIndex, read.location,
            "the place is kept as the first character of the line at the top")

        let wide = try mount(page, of: model, width: 640)
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
        let wide = try mount(page, of: model, width: 640)
        let text = wrappingText()
        wide.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        try settleLayout(of: wide)
        let wideOffset = try scroll(wide, toLineOf: midParagraph(of: text))
        let read = try topLine(of: wide).characters

        dismantle(wide)
        let narrow = try mount(page, of: model, width: 320)
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
        let narrow = try mount(page, of: model, width: 320)
        narrow.textView.insertText(
            wrappingText(), replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try settleLayout(of: narrow)
        // Typing followed the caret to the end of the page, so the top
        // is somewhere the fixture has to go back to.
        narrow.scroll.contentView.scroll(to: .zero)
        narrow.scroll.reflectScrolledClipView(narrow.scroll.contentView)
        XCTAssertEqual(narrow.scroll.contentView.bounds.origin.y, 0)

        dismantle(narrow)
        let kept = try XCTUnwrap(model.viewStates.scrolls[page])
        XCTAssertEqual(kept.characterIndex, 0)
        XCTAssertLessThan(kept.lineFraction, 0, "the inset above the first line went missing")

        let wide = try mount(page, of: model, width: 640)

        XCTAssertEqual(
            wide.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5,
            "the page came back one inset down, with its top margin out of sight")
    }

    /// Content can shrink while a page is in the background. The anchor
    /// names a character the page may no longer have, and the layout
    /// manager raises on an index it does not hold, so the lookup is
    /// clamped to the page as it now stands.
    func testAnAnchorPastTheEndOfAShrunkenPageResolvesToItsLastLine() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let editor = try mount(page, of: model, width: 420)
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
        let editor = try mount(page, of: model, width: 420)

        let anchor = try XCTUnwrap(ScrollAnchor(topOf: editor.textView, clipOrigin: .zero))
        let offset = try XCTUnwrap(anchor.offset(in: editor.textView))

        XCTAssertEqual(anchor.characterIndex, 0)
        XCTAssertEqual(offset.y, 0, accuracy: 0.5, "the top of an empty page is its top")
    }

    private func anchorTextStack(ink: String, wraps: Bool, width: CGFloat = 420) -> (
        storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer, text: NSTextView
    ) {
        let storage = NSTextStorage(string: ink, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(
            width: wraps ? width - 24 : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = wraps
        manager.addTextContainer(container)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 80), textContainer: container)
        text.textContainerInset = NSSize(width: 12, height: 8)
        manager.ensureLayout(for: container)
        return (storage, manager, container, text)
    }

    func testEOFExtraLineCaptureAfterTextInvalidationNeedsNoCallerLayout() throws {
        let paragraph = String(repeating: "ordinary words across a long page ", count: 20) + "\n"
        for wraps in [false, true] {
            for ink in [paragraph, ""] {
                for fraction: CGFloat in [0, 0.25] {
                    let reference = anchorTextStack(ink: ink, wraps: wraps)
                    let extra = reference.manager.extraLineFragmentRect
                    XCTAssertGreaterThan(extra.height, 0)
                    let stack = anchorTextStack(ink: String(repeating: "old line\n", count: 80), wraps: wraps)
                    stack.storage.setAttributedString(NSAttributedString(
                        string: ink, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                    stack.manager.invalidateLayout(
                        forCharacterRange: NSRange(location: 0, length: stack.storage.length), actualCharacterRange: nil)
                    XCTAssertEqual(stack.manager.extraLineFragmentRect.height, 0)

                    let anchor = try XCTUnwrap(ScrollAnchor(
                        topOf: stack.text, clipOrigin: NSPoint(x: 120,
                            y: stack.text.textContainerOrigin.y + extra.minY + fraction * extra.height)))

                    XCTAssertEqual(anchor.characterIndex, ink.utf16.count)
                    XCTAssertEqual(anchor.lineFraction, fraction, accuracy: 0.001)
                    XCTAssertEqual(anchor.x, 120)
                    XCTAssertGreaterThan(stack.manager.extraLineFragmentRect.height, 0)
                }
            }
        }
    }

    func testEOFExtraLineRestorationAfterWidthInvalidationNeedsNoCallerLayout() throws {
        let paragraph = String(repeating: "ordinary words across a long page ", count: 20) + "\n"
        for ink in [paragraph, ""] {
            for fraction: CGFloat in [0, 0.25] {
                let stack = anchorTextStack(ink: ink, wraps: true)
                let anchor = ScrollAnchor(characterIndex: ink.utf16.count, lineFraction: fraction, x: 120)
                let reference = anchorTextStack(ink: ink, wraps: true, width: 240)
                let extra = reference.manager.extraLineFragmentRect
                XCTAssertGreaterThan(extra.height, 0)
                stack.text.setFrameSize(NSSize(width: 240, height: 80))
                stack.manager.invalidateLayout(
                    forCharacterRange: NSRange(location: 0, length: stack.storage.length), actualCharacterRange: nil)
                XCTAssertEqual(stack.manager.extraLineFragmentRect.height, 0)

                let offset = try XCTUnwrap(anchor.offset(in: stack.text))

                XCTAssertEqual(offset.x, 120)
                XCTAssertEqual(offset.y, stack.text.textContainerOrigin.y
                    + extra.minY + fraction * extra.height, accuracy: 0.5)
                XCTAssertGreaterThan(stack.manager.extraLineFragmentRect.height, 0)
            }
        }
    }

    func testEOFExtraLineAnchorSurvivesWrapAndWidthChanges() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let page = try mintPage(in: model)
        let editor = try mount(page, of: model, width: 420)
        let text = String(repeating: "ordinary words across a long page ", count: 20) + "\n"
        editor.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        try settleLayout(of: editor)
        let manager = try XCTUnwrap(editor.textView.layoutManager)
        let extra = manager.extraLineFragmentRect
        XCTAssertGreaterThan(extra.height, 0)

        for fraction: CGFloat in [0, 0.25] {
            model.wrapsLines = false
            editor.coordinator.applyWrap(false)
            size(editor, width: 420)
            try settleLayout(of: editor)
            let original = manager.extraLineFragmentRect
            let anchor = try XCTUnwrap(ScrollAnchor(
                topOf: editor.textView,
                clipOrigin: NSPoint(x: 120, y: editor.textView.textContainerOrigin.y
                    + original.minY + fraction * original.height)
            ))
            XCTAssertEqual(anchor.characterIndex, text.utf16.count)
            XCTAssertEqual(anchor.lineFraction, fraction, accuracy: 0.001)

            for (wraps, width) in [(true, CGFloat(320)), (true, 640), (false, 640)] {
                model.wrapsLines = wraps
                editor.coordinator.applyWrap(wraps)
                size(editor, width: width)
                try settleLayout(of: editor)
                let current = manager.extraLineFragmentRect
                let offset = try XCTUnwrap(anchor.offset(in: editor.textView))
                XCTAssertGreaterThan(current.height, 0)
                if wraps { XCTAssertGreaterThan(current.minY, original.minY) }
                XCTAssertEqual(offset.x, 120)
                XCTAssertEqual(offset.y, editor.textView.textContainerOrigin.y
                    + current.minY + fraction * current.height, accuracy: 0.5)
            }
        }
    }

    func testEOFExtraLineAnchorFallsBackWhenTheTrailingNewlineIsRemoved() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let editor = try mount(page, of: model, width: 420)
        editor.textView.insertText("one\ntwo\n", replacementRange: NSRange(location: 0, length: 0))
        try settleLayout(of: editor)
        let manager = try XCTUnwrap(editor.textView.layoutManager)
        let extra = manager.extraLineFragmentRect
        let anchor = try XCTUnwrap(ScrollAnchor(
            topOf: editor.textView,
            clipOrigin: NSPoint(x: 0, y: editor.textView.textContainerOrigin.y + extra.midY)
        ))
        XCTAssertEqual(anchor.characterIndex, editor.textView.string.utf16.count)
        editor.textView.insertText("", replacementRange: NSRange(
            location: editor.textView.string.utf16.count - 1, length: 1))
        try settleLayout(of: editor)

        let last = manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil)
        let offset = try XCTUnwrap(anchor.offset(in: editor.textView))
        XCTAssertEqual(offset.y, editor.textView.textContainerOrigin.y + last.midY, accuracy: 0.5)
    }

    func testReturningToATabAfterEnablingWrapResetsSavedHorizontalOffset() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let first = try mintPage(in: model)
        let firstTab = try XCTUnwrap(model.selection)
        let editor = try mount(first, of: model, width: 420)
        editor.textView.insertText(String(repeating: "wide source line ", count: 100),
                                   replacementRange: NSRange(location: 0, length: 0))
        try settleLayout(of: editor)
        let storage = editor.textView.textStorage
        let caret = NSRange(location: 20, length: 3)
        editor.textView.setSelectedRange(caret)
        editor.scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
        editor.scroll.reflectScrolledClipView(editor.scroll.contentView)
        XCTAssertEqual(editor.scroll.contentView.bounds.minX, 200)

        let second = try mintPage(in: model)
        InkEditorView.updatePage(editor.scroll, model: model, sheetID: second,
                                 readOnly: false, coordinator: editor.coordinator)
        pump()
        XCTAssertEqual(model.viewStates.scrolls[first]?.x, 200)
        model.wrapsLines = true
        InkEditorView.updatePage(editor.scroll, model: model, sheetID: second,
                                 readOnly: false, coordinator: editor.coordinator)
        model.select(firstTab)
        InkEditorView.updatePage(editor.scroll, model: model, sheetID: first,
                                 readOnly: false, coordinator: editor.coordinator)
        pump()
        try settleLayout(of: editor)

        XCTAssertTrue(editor.scroll.documentView === editor.textView)
        XCTAssertTrue(editor.textView.textStorage === storage)
        XCTAssertEqual(editor.textView.selectedRange(), caret)
        XCTAssertEqual(editor.scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(editor.textView.frame.width, editor.scroll.contentView.bounds.width, accuracy: 0.5)
    }

    func testUnwrappedTabRestorationClampsXToCurrentSourceExtent() throws {
        for repetitions in [100, 10, 1] {
            let model = try makeModel()
            model.wrapsLines = false
            let page = try mintPage(in: model)
            let first = try mount(page, of: model, width: 420)
            first.textView.insertText(String(repeating: "wide source line ", count: 100),
                                      replacementRange: NSRange(location: 0, length: 0))
            try settleLayout(of: first)
            let savedX: CGFloat = 1_500
            first.scroll.contentView.scroll(to: NSPoint(x: savedX, y: 0))
            first.scroll.reflectScrolledClipView(first.scroll.contentView)
            dismantle(first)
            XCTAssertEqual(model.viewStates.scrolls[page]?.x, savedX)

            let replacement = String(repeating: "wide source line ", count: repetitions)
            XCTAssertTrue(model.coreClient.syncDocument(sheet: page, json: "[{\"ink\":\"\(replacement)\"}]"))
            model.storage(for: page).setAttributedString(NSAttributedString(
                string: replacement, attributes: [.font: InkStyle.baseFont]))
            let restored = try mount(page, of: model, width: 640)
            let manager = try XCTUnwrap(restored.textView.layoutManager)
            let container = try XCTUnwrap(restored.textView.textContainer)
            manager.ensureLayout(for: container)
            let used = manager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
            let width = ceil(used.maxX + restored.textView.textContainerInset.width * 2)
            let maxX = max(width - restored.scroll.contentView.bounds.width, 0)
            let expected = min(savedX, maxX)
            XCTAssertEqual(restored.scroll.contentView.bounds.minX, expected, accuracy: 0.5)
            if repetitions == 100 { XCTAssertEqual(expected, savedX) }
            if repetitions == 10 {
                XCTAssertGreaterThan(expected, 0)
                XCTAssertLessThan(expected, savedX)
            }
            if repetitions == 1 { XCTAssertEqual(expected, 0) }
        }
    }

    // MARK: A wrap change under the reader

    /// Mid paragraph and a quarter line in, so a restore to the paragraph or the line's top fails.
    func testTogglingWrapInATabKeepsTheReadersLineThroughRoundTrips() throws {
        let model = try makeModel()
        model.wrapsLines = true
        let page = try mintPage(in: model)
        let reader = try mount(page, of: model, width: 320)
        let text = wrappingText()
        reader.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        try settleLayout(of: reader)
        let target = midParagraph(of: text)
        let lineTop = try scroll(reader, toLineOf: target)
        let manager = try XCTUnwrap(reader.textView.layoutManager)
        let line = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: target), effectiveRange: nil)
        let start = lineTop + line.height / 4
        reader.scroll.contentView.scroll(to: NSPoint(x: 0, y: start))
        reader.scroll.reflectScrolledClipView(reader.scroll.contentView)
        let paragraph = (text as NSString).paragraphRange(for: NSRange(location: target, length: 0))
        XCTAssertGreaterThan(try topLine(of: reader).characters.location, paragraph.location,
            "the case needs a continuation line")

        for wraps in [false, true, false, true] {
            model.wrapsLines = wraps
            InkEditorView.updatePage(reader.scroll, model: model, sheetID: page,
                                     readOnly: false, coordinator: reader.coordinator)
            pump()
            try settleLayout(of: reader)
            XCTAssertTrue(NSLocationInRange(target, try topLine(of: reader).characters),
                "wraps \(wraps): the flip opened the page on another line")
            XCTAssertEqual(reader.scroll.contentView.bounds.minX, 0)
            if wraps { XCTAssertEqual(reader.scroll.contentView.bounds.minY, start, accuracy: 0.5) }
        }
    }

    /// The kept place is the flip's own; a reader who scrolls between flips is followed instead.
    func testAWrapFlipAfterTheReaderMovesKeepsTheirNewLine() throws {
        let model = try makeModel()
        model.wrapsLines = true
        let page = try mintPage(in: model)
        let reader = try mount(page, of: model, width: 320)
        let text = wrappingText()
        reader.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        try settleLayout(of: reader)
        _ = try scroll(reader, toLineOf: midParagraph(of: text))
        func flip(_ wraps: Bool) throws {
            model.wrapsLines = wraps
            InkEditorView.updatePage(reader.scroll, model: model, sheetID: page,
                                     readOnly: false, coordinator: reader.coordinator)
            pump()
            try settleLayout(of: reader)
        }

        try flip(false)
        let later = (text as NSString).range(of: "paragraph 30 ").location
        _ = try scroll(reader, toLineOf: later)
        try flip(true)

        let landed = try topLine(of: reader)
        XCTAssertEqual(landed.characters.location, later)
        XCTAssertEqual(reader.scroll.contentView.bounds.minY, landed.minY, accuracy: 0.5)
    }

    // MARK: What a mount and a dismantle owe the place

    /// A long page read to its middle and then left, for the tests that
    /// need a place worth keeping. Answers the line that was at the top.
    private func leaveAPlace(on page: UInt64, of model: PageModel) throws -> NSRange {
        let reader = try mount(page, of: model, width: 320)
        let text = wrappingText()
        reader.textView.insertText(
            text, replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try settleLayout(of: reader)
        _ = try scroll(reader, toLineOf: midParagraph(of: text))
        let read = try topLine(of: reader).characters
        dismantle(reader)
        return read
    }

    /// SwiftUI makes the scroller and sizes it when it pleases, and the
    /// restore's hop can land in between. A container with no width
    /// lays the page out unwrapped, one line to a paragraph, and a
    /// restore spent on that layout comes out at the start of the
    /// paragraph once the real width arrives, several lines above the
    /// one that was being read. So the restore waits for the clip's
    /// first real frame. The fixture's line is deep inside a paragraph
    /// for exactly this reason.
    func testAMountWhoseScrollerHasNoSizeYetRestoresWhenItGetsOne() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let read = try leaveAPlace(on: page, of: model)

        let coordinator = InkEditorView.Coordinator(model: model)
        let scroll = InkEditorView.makePage(
            model: model, sheetID: page, readOnly: false, coordinator: coordinator
        )
        let late = Mount(
            coordinator: coordinator,
            textView: try XCTUnwrap(scroll.documentView as? InkTextView),
            scroll: scroll,
            window: NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 160),
                styleMask: [.titled], backing: .buffered, defer: false
            )
        )
        XCTAssertTrue(scroll.contentView.bounds.isEmpty, "the fixture must start with no size")
        pump()

        size(late, width: 640)
        pump()

        let landed = try topLine(of: late)
        XCTAssertTrue(
            NSLocationInRange(read.location, landed.characters),
            "the restore was spent on a clip with no size and the page opened elsewhere")
        XCTAssertEqual(late.scroll.contentView.bounds.origin.y, landed.minY, accuracy: 0.5)
    }

    /// And an editor that goes before it was ever given a size has
    /// shown the page to nobody. It must not replace the place it was
    /// handed with the top of a view that was never on screen.
    func testAMountDismantledBeforeItHadASizeLeavesThePlaceAlone() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        _ = try leaveAPlace(on: page, of: model)
        let kept = try XCTUnwrap(model.viewStates.scrolls[page])

        let coordinator = InkEditorView.Coordinator(model: model)
        let scroll = InkEditorView.makePage(
            model: model, sheetID: page, readOnly: false, coordinator: coordinator
        )
        pump()
        InkEditorView.dismantleNSView(scroll, coordinator: coordinator)
        pump()

        XCTAssertEqual(model.viewStates.scrolls[page], kept)
    }

    /// SwiftUI may build a replacement before dismantling what it
    /// replaces. The building sheds the outgoing editor's layout
    /// manager, so by the time the outgoing one is dismantled its
    /// selection and its layout describe nothing, and the place it
    /// would write over belongs to the live editor.
    func testAnEditorAlreadyReplacedWritesNothingOverTheLiveOnesPlace() throws {
        let model = try makeModel()
        let page = try mintPage(in: model)
        let outgoing = try mount(page, of: model, width: 420)
        outgoing.textView.insertText(
            wrappingText(), replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        outgoing.textView.setSelectedRange(NSRange(location: 9, length: 0))

        let incoming = try mount(page, of: model, width: 420)
        XCTAssertNil(outgoing.textView.textStorage, "the fixture must have shed the old editor")
        incoming.textView.setSelectedRange(NSRange(location: 40, length: 0))
        incoming.coordinator.saveViewState(
            textView: incoming.textView, scrollView: incoming.scroll
        )
        let live = model.viewStates

        dismantle(outgoing)

        XCTAssertEqual(model.viewStates.carets[page], live.carets[page])
        XCTAssertEqual(model.viewStates.scrolls[page], live.scrolls[page])
        XCTAssertEqual(model.storage(for: page).layoutManagers.count, 1)
    }

    /// The storage outlives the editor and owns what is attached to it,
    /// so a dismantled editor left on the page would go on laying it
    /// out until that same page happened to be mounted again. A page
    /// selected in between is never that mount, which is how a
    /// background page came to keep a dead editor.
    func testADismantledEditorComesOffItsPage() throws {
        let model = try makeModel()
        let first = try mintPage(in: model)
        let second = try mintPage(in: model)
        let outgoing = try mount(first, of: model, width: 420)
        outgoing.textView.setSelectedRange(NSRange(location: 0, length: 0))

        dismantle(outgoing)
        // The next mount is over another page, so its shed never
        // visits the first one.
        let incoming = try mount(second, of: model, width: 420)

        XCTAssertEqual(
            model.storage(for: first).layoutManagers.count, 0,
            "the torn-down editor is still laying out a page nobody is showing"
        )
        XCTAssertNil(model.storage(for: first).delegate)
        XCTAssertNil(outgoing.coordinator.currentSheet)
        XCTAssertEqual(model.storage(for: second).layoutManagers.count, 1)
        XCTAssertTrue(model.activeEditor === incoming.textView)
    }

    /// The caret crosses between the two kinds of surface as well: the
    /// roll leaves it on the way out, and the building seats it for
    /// whichever surface mounts the page next.
    func testTheRollLeavesTheCaretForThePageSurface() throws {
        let model = try makeModel()
        model.showsTimeUnits = true
        let page = try mintPage(in: model)
        let coordinator = InkEditorView.Coordinator(model: model)
        let roll = DayScrollView.makeRoll(model: model, coordinator: coordinator, emptyHint: "")
        let card = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(roll)
        roll.frame = card
        roll.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(roll.documentView as? DayStackView)
        stack.update(projection: model.timeUnits, selectedPage: page, readOnly: false)
        let editor = try XCTUnwrap(stack.editor)
        editor.insertText(
            "a day's page", replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        editor.setSelectedRange(NSRange(location: 5, length: 2))

        DayScrollView.dismantleNSView(roll, coordinator: coordinator)
        let surface = try mount(page, of: model, width: 420)

        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 5, length: 2))
    }

    // MARK: The roll's own place

    func testTheRollsPlaceIsTakenOnceAndDiesWithItsPage() {
        var states = PageViewStates()
        let place = RollPlace(page: 7, anchor: ScrollAnchor(characterIndex: 40))

        states.leaveRollPlace(place)
        XCTAssertEqual(states.takeRollPlace(), place)
        XCTAssertNil(states.takeRollPlace(), "the roll after the next one opens at Day 0")

        states.leaveRollPlace(place)
        states.prune(keeping: [1])
        XCTAssertNil(states.rollPlace, "a dead page is nowhere to open the roll on")

        states.leaveRollPlace(place)
        states.leaveRollPlace(nil)
        XCTAssertNil(states.rollPlace, "a roll left at Day 0 replaces the place before it")
    }

    func testARollPlaceFollowsItsTextAcrossAReplacement() {
        let text = "line 1\nline 2\nline 3"
        let end = text.utf16.count
        XCTAssertEqual(RollPlace.rebased(7, from: text, to: "new\n" + text), 11)
        XCTAssertEqual(RollPlace.rebased(7, from: text, to: "line 1\nline 0\nline 2\nline 3"), 14,
                       "a line arriving at the anchor goes above it")
        XCTAssertEqual(RollPlace.rebased(7, from: text, to: text + "\nline 4"), 7)
        XCTAssertEqual(RollPlace.rebased(14, from: text, to: "line 1\nline 3"), 7)
        XCTAssertEqual(RollPlace.rebased(10, from: text, to: "line 1\nline 3"), 6,
                       "an anchor inside removed text goes to where the removal was")
        XCTAssertEqual(RollPlace.rebased(1, from: text, to: "xyz"), 0)
        XCTAssertEqual(RollPlace.rebased(end, from: text, to: "x" + text), end + 1)
        XCTAssertEqual(RollPlace.rebased(4, from: text, to: text), 4)
        XCTAssertEqual(RollPlace.rebased(3, from: "", to: text), 0)
        let place = RollPlace(
            page: 1, anchor: ScrollAnchor(characterIndex: 7, lineFraction: 0.25, x: 3), length: end)
        let moved = place.rebased(from: text, to: "new\n" + text)
        XCTAssertEqual(moved.anchor, ScrollAnchor(characterIndex: 11, lineFraction: 0.25, x: 3))
        XCTAssertEqual(moved.length, end + 4)
        XCTAssertEqual(moved.page, 1)
    }

    /// A mixed rewrite past the search's bound keeps the reader's share of the changed
    /// stretch rather than sending the anchor to its start (#283); an anchor in the shared
    /// head or tail still maps exactly, a middle deleted to nothing maps to its start, and a
    /// share falling inside a surrogate pair is snapped to the pair's start.
    func testARollPlaceKeepsItsShareOfARewriteTheSearchGivesUpOn() {
        let head = "HEAD\n"
        let tail = "\nTAIL"
        let oldBody = String(repeating: "ab", count: 1_000)
        let newBody = String(repeating: "cd", count: 2_000)
        let old = head + oldBody + tail
        let new = head + newBody + tail
        XCTAssertEqual(RollPlace.rebased(2, from: old, to: new), 2, "an anchor in the shared head moved")
        XCTAssertEqual(RollPlace.rebased(5 + 1_000, from: old, to: new), 5 + 2_000, "the share, halfway")
        XCTAssertEqual(RollPlace.rebased(5 + 500, from: old, to: new), 5 + 1_000, "the share, a quarter in")
        XCTAssertEqual(RollPlace.rebased(5, from: old, to: new), 5)
        XCTAssertEqual(
            RollPlace.rebased(old.utf16.count - 2, from: old, to: new), new.utf16.count - 2,
            "an anchor in the shared tail moved")
        XCTAssertEqual(RollPlace.rebased(1_000, from: oldBody, to: newBody), 2_000, "the share with no head or tail")
        XCTAssertEqual(RollPlace.rebased(2_000, from: oldBody, to: "x"), 1, "the end is the tail's")
        XCTAssertEqual(RollPlace.rebased(1_000, from: oldBody, to: ""), 0, "a middle deleted to nothing")
        XCTAssertEqual(
            RollPlace.rebased(5 + 1_000, from: old, to: head + tail), 5,
            "a middle deleted to nothing between a head and a tail")

        let paired = String(repeating: "🧪", count: 1_000)
        XCTAssertEqual(RollPlace.rebased(1_001, from: oldBody, to: paired), 1_000)
    }

    func testARollPlaceSurvivesInsertionsOnBothSidesInOneRefresh() {
        let old = "before\nTARGET\nafter"
        let new = "inserted above\n" + old + "\ninserted below"
        let start = (old as NSString).range(of: "TARGET").location
        let expected = (new as NSString).range(of: "TARGET").location
        let place = RollPlace(
            page: 7, anchor: ScrollAnchor(characterIndex: start, lineFraction: 0.25, x: 9),
            reading: .preview, length: old.utf16.count)

        let moved = place.rebased(from: old, to: new)

        XCTAssertEqual(moved.anchor, ScrollAnchor(characterIndex: expected, lineFraction: 0.25, x: 9))
        XCTAssertEqual(moved.page, place.page)
        XCTAssertEqual(moved.reading, place.reading)
        XCTAssertEqual(moved.length, new.utf16.count)
        for offset in 0..<"TARGET".utf16.count {
            XCTAssertEqual(RollPlace.rebased(start + offset, from: old, to: new), expected + offset)
        }
    }

    func testARollPlaceFollowsInteriorTextAcrossSeveralEdits() {
        let old = "first\nremove this\nTARGET\nlast"
        let new = "new first\nTARGET\nnew last\n"
        let start = (old as NSString).range(of: "TARGET").location
        let expected = (new as NSString).range(of: "TARGET").location

        XCTAssertEqual(RollPlace.rebased(start, from: old, to: new), expected)
        XCTAssertEqual(RollPlace.rebased(start + 3, from: old, to: new), expected + 3)
    }

    func testARollPlaceRebasesInteriorUnicodeInUTF16Units() {
        let target = "🧪e\u{301}👩‍💻TARGET"
        let old = "前\n" + target + "\n後"
        let new = "😀above\n" + old + "\nbelow🚀"
        let start = (old as NSString).range(of: target).location
        let expected = (new as NSString).range(of: target).location

        for offset in 0..<target.utf16.count {
            XCTAssertEqual(RollPlace.rebased(start + offset, from: old, to: new), expected + offset)
        }
    }

    func testARollPlaceKeepsReplacementAndInsertionBoundaries() {
        let old = "abcTARGETxyz"
        let new = "!abcTARGETxyz?"
        XCTAssertEqual(RollPlace.rebased(0, from: old, to: new), 1)
        XCTAssertEqual(RollPlace.rebased(old.utf16.count, from: old, to: new), new.utf16.count)
        XCTAssertEqual(RollPlace.rebased(-10, from: old, to: new), 1)
        XCTAssertEqual(RollPlace.rebased(100, from: old, to: new), new.utf16.count)
        XCTAssertEqual(RollPlace.rebased(5, from: "abc123xyz", to: "abcXYZxyz"), 3)
        XCTAssertEqual(RollPlace.rebased(5, from: "abc123xyz", to: "abcxyz"), 3)
        XCTAssertEqual(RollPlace.rebased(3, from: "abcTARGETxyz", to: "abc+TARGETxyz"), 4)
        XCTAssertEqual(RollPlace.rebased(4, from: old, to: ""), 0)
    }

    func testARollPlaceSurvivesEditsAroundAnInteriorPointOfAVeryLongLine() {
        let old = String(repeating: "a", count: 100_000) + "🧪TARGET"
            + String(repeating: "z", count: 100_000)
        let new = "+" + old + "-"
        let start = (old as NSString).range(of: "TARGET").location

        XCTAssertEqual(RollPlace.rebased(start, from: old, to: new), start + 1)
    }

    func testARollPlaceRebasesMixedEditsOnAVeryLongLine() {
        let middle = String(repeating: "a", count: 100_000) + "🧪TARGET"
            + String(repeating: "z", count: 100_000)
        let old = "<" + middle + ">"
        let new = "🐈[" + middle + "]"
        let start = (old as NSString).range(of: "TARGET").location

        XCTAssertEqual(RollPlace.rebased(start, from: old, to: new), start + 2)
    }

    func testARollPlaceSurvivesLargeInsertionsWithoutAnEditDistanceLimit() {
        let old = "before\nTARGET\nafter"
        let new = String(repeating: "+", count: 10_000) + old
            + String(repeating: "-", count: 10_000)
        let start = (old as NSString).range(of: "TARGET").location

        XCTAssertEqual(RollPlace.rebased(start, from: old, to: new), start + 10_000)
    }

    func testARollPlaceSurvivesParagraphDeletionsAboveAndBelowTheReader() {
        let lines = (0..<80).map { "line \($0) of a day that goes on" }
        let synced = (0..<20).map { "synced \($0) from elsewhere\n" }.joined()
        let old = lines.dropFirst(25).joined(separator: "\n") + "\n" + synced
        let new = lines.dropFirst(30).dropLast(10).joined(separator: "\n")
        let start = (old as NSString).range(of: "line 40 ").location
        let expected = (new as NSString).range(of: "line 40 ").location
        let place = RollPlace(
            page: 7, anchor: ScrollAnchor(characterIndex: start, lineFraction: 0.25, x: 9),
            length: old.utf16.count)

        let moved = place.rebased(from: old, to: new)

        XCTAssertEqual(expected, 300)
        XCTAssertEqual(moved.anchor, ScrollAnchor(characterIndex: expected, lineFraction: 0.25, x: 9))
        XCTAssertEqual(moved.length, new.utf16.count)
        XCTAssertEqual(moved.page, place.page)
    }

    func testARollPlaceSurvivesLargeUnicodeDeletionsOnBothSidesOnOneLine() {
        let target = "🧪e\u{301}👩‍💻TARGET"
        let removed = String(repeating: "x", count: 100_000)
        let old = removed + target + removed

        for offset in 0..<target.utf16.count {
            XCTAssertEqual(RollPlace.rebased(removed.utf16.count + offset, from: old, to: target), offset)
        }
        XCTAssertEqual(RollPlace.rebased(50_000, from: old, to: target), 0)
        XCTAssertEqual(RollPlace.rebased(old.utf16.count - 50_000, from: old, to: target),
                       target.utf16.count)
    }

    func testARollPlaceMapsLargeDeletedRunsToTheirLocalStarts() {
        let first = String(repeating: "🧪", count: 2_000)
        let second = String(repeating: "🧫", count: 2_000)
        let old = "A" + first + "B" + second + "C" + first
        let b = 1 + first.utf16.count
        let c = b + 1 + second.utf16.count

        XCTAssertEqual(RollPlace.rebased(2, from: old, to: "ABC"), 1)
        XCTAssertEqual(RollPlace.rebased(b, from: old, to: "ABC"), 1)
        XCTAssertEqual(RollPlace.rebased(b + 2, from: old, to: "ABC"), 2)
        XCTAssertEqual(RollPlace.rebased(c, from: old, to: "ABC"), 2)
        XCTAssertEqual(RollPlace.rebased(c + 2, from: old, to: "ABC"), 3)
    }

    func testARollPlaceMapsRemovedInteriorTextToItsLocalReplacementStart() {
        let old = "abc123MIDDLE456xyz"
        let new = "!abcMIDDLExyz?"

        XCTAssertEqual(RollPlace.rebased(4, from: old, to: new), 4)
        XCTAssertEqual(RollPlace.rebased(6, from: old, to: new), 4)
        XCTAssertEqual(RollPlace.rebased(13, from: old, to: new), 10)
        XCTAssertEqual(RollPlace.rebased(15, from: old, to: new), 10)
    }

    func testARollPlaceDoesNotMatchHalfOfAReplacedSurrogatePair() {
        let old = "abc😁TARGETend"
        let new = "abc🚀TARGETend"

        XCTAssertEqual(RollPlace.rebased(3, from: old, to: new), 3)
        XCTAssertEqual(RollPlace.rebased(4, from: old, to: new), 3)
        XCTAssertEqual(RollPlace.rebased(5, from: old, to: new), 5)
    }

    func testARollPlaceUsesSuffixAffinityForRepeatedInteriorText() {
        XCTAssertEqual(RollPlace.rebased(0, from: "aaaa", to: "!aaaaa?"), 2)
        XCTAssertEqual(RollPlace.rebased(2, from: "aaaa", to: "!aaaaa?"), 4)
    }

    func testARollPlaceKeepsRepeatedTextAffinityWhenOtherTextIsReplaced() {
        let old = "aaaaX"
        for prefix in ["", "!"] {
            for ending in ["X?", "Y?"] {
                let new = prefix + "aaaaa" + ending
                XCTAssertEqual(RollPlace.rebased(0, from: old, to: new), prefix.utf16.count + 1, new)
                XCTAssertEqual(RollPlace.rebased(2, from: old, to: new), prefix.utf16.count + 3, new)
            }
        }
    }

    func testARollPlaceKeepsRepeatedLineAffinityWhenTheEndingChanges() {
        let old = "ROW\nROW\nend"
        for prefix in ["", "prefix\n"] {
            for ending in ["end", "END"] {
                let new = prefix + "ROW\nROW\nROW\n" + ending
                XCTAssertEqual(RollPlace.rebased(0, from: old, to: new), prefix.utf16.count + 4, new)
                XCTAssertEqual(RollPlace.rebased(4, from: old, to: new), prefix.utf16.count + 8, new)
            }
        }
    }

    func testARollPlaceSurvivesAModeratelyLargePasteWithOtherReplacements() {
        for middle in ["before\nTARGET\nafter", "before TARGET after"] {
            let old = "<" + middle + ">"
            let start = (old as NSString).range(of: "TARGET").location
            for count in [340, 1_000] {
                for unit in ["+", "🧪"] {
                    let paste = String(repeating: unit, count: count)
                    let new = paste + "[" + middle + "]"
                    XCTAssertEqual(RollPlace.rebased(start, from: old, to: new),
                                   paste.utf16.count + start)
                }
            }
        }
    }

    func testARollPlaceSurvivesAModeratelyLargeRemovalWithOtherReplacements() {
        let removed = String(repeating: "+", count: 340)
        let old = removed + "<before\nTARGET\nafter>"
        let new = "[before\nTARGET\nafter]"

        XCTAssertEqual(RollPlace.rebased(348, from: old, to: new), 8)
        XCTAssertEqual(RollPlace.rebased(100, from: old, to: new), 0)
    }

    func testARollPlaceKeepsUTF16OffsetsInMixedRepeatedText() {
        let old = "🧪🧪X"
        for prefix in ["", "!"] {
            let new = prefix + "🧪🧪🧪Y?"
            for index in 0..<4 {
                XCTAssertEqual(RollPlace.rebased(index, from: old, to: new),
                               prefix.utf16.count + 2 + index)
            }
        }
    }

    /// Past the search's bound the anchor keeps its share of the rewrite (#283); here the
    /// share is the same offset, which the search could not have found in time.
    func testARollPlaceKeepsItsShareForExtensiveMixedReplacements() {
        let old = String(repeating: "a", count: 100_000) + "TARGET"
            + String(repeating: "z", count: 100_000)
        let new = String(repeating: "b", count: 100_000) + "TARGET"
            + String(repeating: "c", count: 100_000)

        XCTAssertEqual(RollPlace.rebased(100_000, from: old, to: new), 100_000)
    }

    func testARollPlaceCrossesBetweenSourceAndPreviewByProportion() {
        let short = String(repeating: "p", count: 400)
        let long = String(repeating: "s", count: 1_000)
        let anchor = ScrollAnchor(characterIndex: 300, lineFraction: 0.5, x: 4)
        let place = RollPlace(page: 1, anchor: anchor, reading: .source, length: 1_000)
        XCTAssertEqual(place.mappedAnchor(into: .source, text: short), anchor)
        XCTAssertEqual(place.mappedAnchor(into: .preview, text: short),
                       ScrollAnchor(characterIndex: 120, lineFraction: 0.5, x: 4))
        let preview = RollPlace(page: 1, anchor: ScrollAnchor(characterIndex: 120), reading: .preview, length: 400)
        XCTAssertEqual(preview.mappedAnchor(into: .source, text: long).characterIndex, 300)
        XCTAssertEqual(RollPlace(page: 1, anchor: ScrollAnchor(characterIndex: 1_000), length: 1_000)
            .mappedAnchor(into: .preview, text: short).characterIndex, 400)
        XCTAssertEqual(RollPlace(page: 1, anchor: ScrollAnchor(characterIndex: 9), reading: .preview)
            .mappedAnchor(into: .source, text: String(repeating: "s", count: 50)).characterIndex, 0)

        // The roll restores on every layout pass, so the same reading must not copy the page.
        var reads = 0
        func counted() -> String { reads += 1; return short }
        _ = place.mappedAnchor(into: .source, text: counted())
        XCTAssertEqual(reads, 0, "the same reading read the text")
        _ = place.mappedAnchor(into: .preview, text: counted())
        XCTAssertEqual(reads, 1)
    }

    /// A proportion that falls inside an emoji's surrogate pair is moved to the pair's
    /// start, in either direction (#290), and one already on a pair's start stays.
    func testARollPlaceCrossingReadingsStopsOnAScalarBoundary() {
        let paired = String(repeating: "🧪", count: 200)
        let source = RollPlace(page: 1, anchor: ScrollAnchor(characterIndex: 302), reading: .source, length: 1_000)
        XCTAssertEqual(source.mappedAnchor(into: .preview, text: paired).characterIndex, 120, "121 is a low surrogate")
        XCTAssertEqual(
            source.mappedAnchor(into: .preview, text: "a" + paired).characterIndex, 121, "121 starts a pair here")
        let preview = RollPlace(page: 1, anchor: ScrollAnchor(characterIndex: 100), reading: .preview, length: 300)
        XCTAssertEqual(preview.mappedAnchor(into: .source, text: paired).characterIndex, 132, "133 is a low surrogate")
    }

    /// Edit a storage holding `text`, and answer what the storage reports of the edit.
    private func storageEdit(
        of text: String, _ edit: (NSTextStorage) -> Void
    ) -> (text: String, edited: NSRange, delta: Int) {
        let storage = NSTextStorage(string: text)
        storage.beginEditing()
        edit(storage)
        let edited = storage.editedRange
        let delta = storage.changeInLength
        storage.endEditing()
        return (storage.string, edited, delta)
    }

    private func inserting(_ inserted: String, at location: Int, into text: String) -> (
        text: String, edited: NSRange, delta: Int
    ) {
        storageEdit(of: text) { $0.replaceCharacters(in: NSRange(location: location, length: 0), with: inserted) }
    }

    func testARollPlaceFollowsAStorageEditBeforeAtAndAfterItsAnchor() {
        let text = "line 1\nline 2\nline 3"
        let place = RollPlace(
            page: 4, anchor: ScrollAnchor(characterIndex: 7, lineFraction: 0.25, x: 3),
            length: text.utf16.count)
        // A reseed sends text arriving at the anchor above it; an edit at the anchor stays in view.
        for (location, inserted, expected, reseeded) in [
            (0, "new\n", 11, 11), (7, "line 0\n", 7, 14), (10, "X", 7, 7),
        ] {
            let edit = inserting(inserted, at: location, into: text)
            let moved = place.rebased(
                throughEdit: edit.edited, changeInLength: edit.delta, length: edit.text.utf16.count,
                text: edit.text, byProjection: false)
            XCTAssertEqual(moved.anchor, ScrollAnchor(characterIndex: expected, lineFraction: 0.25, x: 3), inserted)
            XCTAssertEqual(moved.length, edit.text.utf16.count)
            XCTAssertEqual(moved.page, place.page)
            XCTAssertEqual(moved.reading, place.reading)
            XCTAssertEqual(RollPlace.rebased(7, from: text, to: edit.text), reseeded, inserted)
        }
        let empty = inserting("first words", at: 0, into: "")
        XCTAssertEqual(RollPlace.rebased(
            0, throughEdit: empty.edited, changeInLength: empty.delta, length: 11, text: empty.text,
            byProjection: false), 0)
        let replaced = storageEdit(of: text) { $0.replaceCharacters(in: NSRange(location: 7, length: 4), with: "LINE") }
        XCTAssertEqual(
            RollPlace.rebased(7, throughEdit: replaced.edited, changeInLength: replaced.delta,
                              length: replaced.text.utf16.count, text: replaced.text, byProjection: false), 7,
            "a replacement starting at the anchor keeps it")
    }

    func testARollPlaceInsideAStorageDeletionGoesToWhereTheDeletionWas() {
        let text = "first\nsecond\nthird\nfourth"
        let edit = storageEdit(of: text) { $0.replaceCharacters(in: NSRange(location: 6, length: 13), with: "") }
        XCTAssertEqual(edit.text, "first\nfourth")
        for (index, expected) in [(2, 2), (6, 6), (13, 6), (18, 6), (19, 6), (21, 8), (25, 12)] {
            XCTAssertEqual(
                RollPlace.rebased(
                    index, throughEdit: edit.edited, changeInLength: edit.delta, length: 12, text: edit.text,
                    byProjection: false),
                expected,
                "index \(index)")
        }
    }

    func testARollPlaceInsideAStorageReplacementStaysWithinTheReplacement() {
        let text = "first\nsecond\nthird\nfourth"
        let replaced = NSRange(location: 6, length: 12)
        for replacement in ["2nd", "the second and the third, both rewritten"] {
            let edit = storageEdit(of: text) { $0.replaceCharacters(in: replaced, with: replacement) }
            let end = 6 + replacement.utf16.count
            let length = edit.text.utf16.count
            XCTAssertEqual(edit.edited, NSRange(location: 6, length: replacement.utf16.count))
            for index in replaced.location..<NSMaxRange(replaced) {
                let moved = RollPlace.rebased(
                    index, throughEdit: edit.edited, changeInLength: edit.delta, length: length, text: edit.text,
                    byProjection: false)
                XCTAssertEqual(moved, index == 6 ? 6 : max(index + edit.delta, 6), "index \(index) in \(replacement)")
                XCTAssertTrue((6...end).contains(moved), "index \(index) in \(replacement)")
            }
            XCTAssertEqual(RollPlace.rebased(
                18, throughEdit: edit.edited, changeInLength: edit.delta, length: length, text: edit.text,
                byProjection: false), end)
            XCTAssertEqual(
                RollPlace.rebased(
                    19, throughEdit: edit.edited, changeInLength: edit.delta, length: length, text: edit.text,
                    byProjection: false),
                end + 1)
            XCTAssertEqual(RollPlace.rebased(
                2, throughEdit: edit.edited, changeInLength: edit.delta, length: length, text: edit.text,
                byProjection: false), 2)
        }
    }

    /// An anchor inside an edit that writes emoji is snapped back to a pair's start (#311), for a
    /// person's replacement and a projection's whole restate; only those read the text.
    func testARollPlaceInsideAnEmojiReplacementStopsOnAScalarBoundary() {
        let text = "first\nsecond\nthird"
        let second = NSRange(location: 6, length: 6)
        let same = storageEdit(of: text) { $0.replaceCharacters(in: second, with: "🧪🧪🧪") }
        let length = same.text.utf16.count
        XCTAssertEqual(same.delta, 0)
        XCTAssertEqual(RollPlace.rebased(
            9, throughEdit: same.edited, changeInLength: same.delta, length: length, text: same.text,
            byProjection: false), 8, "9 is a low surrogate")
        let longer = storageEdit(of: text) { $0.replaceCharacters(in: second, with: "🧪🧪🧪🧪") }
        for (index, expected) in [(7, 8), (8, 10)] {
            XCTAssertEqual(RollPlace.rebased(
                index, throughEdit: longer.edited, changeInLength: longer.delta, length: longer.text.utf16.count,
                text: longer.text, byProjection: false), expected, "index \(index) moved by 2")
        }
        let restated = storageEdit(of: "abcdef") { $0.setAttributedString(NSAttributedString(string: "🧪🧪🧪")) }
        XCTAssertEqual(restated.edited, NSRange(location: 0, length: 6), "the storage reports the whole text")
        XCTAssertEqual(RollPlace.rebased(
            3, throughEdit: restated.edited, changeInLength: restated.delta, length: 6, text: restated.text,
            byProjection: true), 2, "3 is a low surrogate")

        // The mounted page's every keystroke rebases, so an index outside the edit must not copy the page.
        var reads = 0
        func counted() -> String { reads += 1; return same.text }
        for index in [2, 15] {
            _ = RollPlace(page: 1, anchor: ScrollAnchor(characterIndex: index), length: length).rebased(
                throughEdit: same.edited, changeInLength: same.delta, length: length, text: counted(),
                byProjection: false)
        }
        XCTAssertEqual(reads, 0, "an index outside the edit read the text")
        _ = RollPlace.rebased(
            9, throughEdit: same.edited, changeInLength: same.delta, length: length, text: counted(),
            byProjection: false)
        XCTAssertEqual(reads, 1)
    }

    /// An insertion with another paragraph's style, as a list depth nudge makes, is reported
    /// through to its paragraph's end, wider than the characters that changed.
    func testARollPlaceInsideAWidenedStorageEditMovesWithTheTextAfterTheInsertion() throws {
        final class Reported: @unchecked Sendable { var edit: (range: NSRange, delta: Int)? }
        let text = "a plain line\n- an item the reader is partway through\nlast line"
        let item = (text as NSString).paragraphRange(for: (text as NSString).range(of: "- an item"))
        let storage = NSTextStorage(string: text)
        let hanging = NSMutableParagraphStyle()
        hanging.headIndent = 24
        storage.addAttribute(.paragraphStyle, value: hanging, range: item)
        let reported = Reported()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { note in
            guard let edited = note.object as? NSTextStorage else { return }
            reported.edit = (edited.editedRange, edited.changeInLength)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        storage.replaceCharacters(in: NSRange(location: item.location, length: 0), with: "  ")

        let edit = try XCTUnwrap(reported.edit)
        XCTAssertEqual(edit.delta, 2)
        XCTAssertEqual(edit.range, NSRange(location: item.location, length: item.length + 2),
                       "the case needs the storage to report past the inserted characters")
        for reading in ["an item", "reader", "through", "last line"] {
            let index = (text as NSString).range(of: reading).location
            XCTAssertEqual(
                RollPlace.rebased(
                    index, throughEdit: edit.range, changeInLength: edit.delta, length: storage.length,
                    text: storage.string, byProjection: false),
                (storage.string as NSString).range(of: reading).location, reading)
        }
    }

    /// An undo step or a recovery restates the whole storage, so no old text survives to match.
    func testAWholeStorageRewriteKeepsAnInteriorIndexAndMovesTheEnd() {
        let text = "first\nsecond\nthird\nfourth"
        let end = text.utf16.count
        for rewritten in ["first\nfourth", "zero\nfirst\nsecond\nthird\nfourth"] {
            let edit = storageEdit(of: text) { $0.setAttributedString(NSAttributedString(string: rewritten)) }
            let length = rewritten.utf16.count
            XCTAssertEqual(edit.edited, NSRange(location: 0, length: length), "the storage reports the whole text")
            XCTAssertEqual(edit.delta, length - end)
            for (index, expected) in [(0, 0), (13, min(13, length)), (end, length)] {
                XCTAssertEqual(
                    RollPlace.rebased(
                        index, throughEdit: edit.edited, changeInLength: edit.delta, length: length,
                        text: edit.text, byProjection: true),
                    expected,
                    "index \(index) in \(rewritten)")
            }
        }
    }

    func testARollPlaceFollowsStorageEditsInUTF16Units() {
        let target = "👩‍💻 TARGET e\u{301}"
        let text = "🧪 first\n" + target + "\n🚀 last"
        let start = (text as NSString).range(of: target).location
        let place = RollPlace(page: 2, anchor: ScrollAnchor(characterIndex: start), length: text.utf16.count)
        let edits = [
            inserting("😀 above, 🐈\n", at: 0, into: text),
            storageEdit(of: text) { $0.replaceCharacters(in: NSRange(location: 0, length: start), with: "") },
            storageEdit(of: text) { $0.replaceCharacters(in: NSRange(location: 0, length: 2), with: "🐈🐈") },
            inserting("🚀", at: start + ("👩‍💻 " as NSString).length, into: text),
            inserting("\n🐈 below", at: text.utf16.count, into: text),
        ]
        for edit in edits {
            let moved = place.rebased(
                throughEdit: edit.edited, changeInLength: edit.delta, length: (edit.text as NSString).length,
                text: edit.text, byProjection: false)
            let index = moved.anchor.characterIndex
            XCTAssertEqual(index, (edit.text as NSString).range(of: "👩‍💻").location, edit.text)
            XCTAssertEqual(moved.length, (edit.text as NSString).length)
        }
    }

    /// One window's roll, mounted as the representable mounts it: made,
    /// sized, and given its first pass.
    private struct Roll {
        let coordinator: InkEditorView.Coordinator
        let scroll: NSScrollView
        let stack: DayStackView
        let window: NSWindow
    }

    private func mountRoll(
        of model: PageModel, in surface: PresentationOwner, width: CGFloat, height: CGFloat
    ) throws -> Roll {
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = surface
        let scroll = DayScrollView.makeRoll(model: model, coordinator: coordinator, emptyHint: "")
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll)
        scroll.frame = frame
        scroll.layoutSubtreeIfNeeded()
        DayScrollView.updateRoll(scroll, model: model, readOnly: false, coordinator: coordinator)
        return Roll(
            coordinator: coordinator, scroll: scroll,
            stack: try XCTUnwrap(scroll.documentView as? DayStackView), window: window
        )
    }

    private func pass(over roll: Roll, of model: PageModel) {
        DayScrollView.updateRoll(
            roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator
        )
    }

    private func dismantle(_ roll: Roll) {
        roll.scroll.removeFromSuperview()
        DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
    }

    /// Two pages of wrapping text in the panel's roll, scrolled so that
    /// a line from the middle of the quiet one stands at the top of the
    /// clip. Answers that page and the first character of that line.
    private func aRollReadPartWayDown(
        _ model: PageModel
    ) throws -> (roll: Roll, page: UInt64, character: Int) {
        model.showsTimeUnits = true
        let read = try mintPage(in: model)
        let roll = try mountRoll(of: model, in: .panel, width: 420, height: 320)
        let text = wrappingText()
        try XCTUnwrap(roll.stack.editor).insertText(
            text, replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        _ = try mintPage(in: model)
        pass(over: roll, of: model)
        try XCTUnwrap(roll.stack.editor).insertText(
            text, replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        pass(over: roll, of: model)

        let quiet = try XCTUnwrap(roll.stack.quietRegions[read])
        let layoutManager = try XCTUnwrap(quiet.layoutManager)
        let inside = (quiet.string as NSString).range(of: "paragraph 20 ").location + 200
        var glyphs = NSRange(location: 0, length: 0)
        let line = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: inside), effectiveRange: &glyphs
        )
        let y = quiet.frame.minY + quiet.textContainerOrigin.y + line.minY
        roll.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        roll.scroll.reflectScrolledClipView(roll.scroll.contentView)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, y, "the fixture must scroll")
        return (roll, read, layoutManager.characterIndexForGlyph(at: glyphs.location))
    }

    /// The days mode's half of the hand off (issue #198). The roll's
    /// offset belongs to no page, so the page table cannot carry it,
    /// and every page above the reader wraps differently in the wider
    /// window, so a distance could not either.
    func testAHandOffOpensTheOtherWindowsRollOnTheLineBeingRead() throws {
        let model = try makeModel()
        let (panel, page, character) = try aRollReadPartWayDown(model)

        model.transferOwnership(to: .editorWindow)
        XCTAssertEqual(model.viewStates.rollPlace?.page, page)
        dismantle(panel)
        let window = try mountRoll(of: model, in: .editorWindow, width: 640, height: 480)
        pump()

        let quiet = try XCTUnwrap(window.stack.quietRegions[page])
        let layoutManager = try XCTUnwrap(quiet.layoutManager)
        let container = try XCTUnwrap(quiet.textContainer)
        let top = window.scroll.contentView.bounds.origin.y
            - quiet.frame.minY - quiet.textContainerOrigin.y
        var glyphs = NSRange(location: 0, length: 0)
        let line = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndex(for: NSPoint(x: 0, y: top + 0.5), in: container),
            effectiveRange: &glyphs
        )
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        XCTAssertTrue(
            NSLocationInRange(character, characters),
            "the editor window's roll opened on \(characters), and character \(character) was being read"
        )
        XCTAssertEqual(line.minY, top, accuracy: 0.5, "the line stands at the top, as it did")
        XCTAssertNil(model.viewStates.rollPlace, "the place is taken once")
    }

    /// A summon is a hand off too when the editor window is open, and
    /// it presents today (issue #79): the place the editor window's
    /// roll left is dropped, and the panel's roll opens at Day 0.
    func testASummonsAnchorOutranksThePlaceAHandOffLeft() throws {
        let model = try makeModel()
        let (panel, _, _) = try aRollReadPartWayDown(model)

        model.transferOwnership(to: .editorWindow)
        model.anchorOnToday()
        dismantle(panel)
        let window = try mountRoll(of: model, in: .editorWindow, width: 640, height: 480)
        pump()

        XCTAssertEqual(window.scroll.contentView.bounds.origin.y, 0)
    }

    /// Only a hand off carries the roll's place. A roll rebuilt in its
    /// own window, a ledger round trip or the mode toggled, opens at
    /// Day 0 as it did before there were two windows.
    func testARollRebuiltInItsOwnWindowStillOpensAtDayZero() throws {
        let model = try makeModel()
        let (first, _, _) = try aRollReadPartWayDown(model)

        dismantle(first)
        XCTAssertNil(model.viewStates.rollPlace)
        let second = try mountRoll(of: model, in: .panel, width: 420, height: 320)
        pump()

        XCTAssertEqual(second.scroll.contentView.bounds.origin.y, 0)
    }
}
