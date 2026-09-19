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
