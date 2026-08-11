import AppKit
import XCTest

@testable import CompanionKit

/// Wrapping, both halves of it: the geometry `setWrap` builds, and the
/// state ⌥Z and Settings share.
///
/// The geometry is what the assertions are about, not the flags. A
/// wrapped page must never be able to scroll sideways, an unwrapped one
/// must be able to, and neither must leave the card holding a page
/// narrower than itself — a text view that stops short of its clip
/// leaves a strip where clicks place no caret.
@MainActor
final class WrapTests: XCTestCase {
    /// The editor's TextKit 1 stack in a real window, wired through the
    /// same `scrollStack` the mounted editor uses, and laid out at a
    /// card's size before anything asks about widths.
    private func makeStack() -> (NSScrollView, InkTextView, NSTextStorage, NSLayoutManager, NSTextContainer) {
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let textView = InkTextView(frame: .zero, textContainer: container)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        let scroll = InkEditorView.scrollStack(for: textView)

        let card = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        return (scroll, textView, storage, layoutManager, container)
    }

    /// One line far wider than any card, so wrapping is the only thing
    /// that can keep it inside one.
    private var longLine: String {
        String(repeating: "the quick brown fox jumps over the lazy dog ", count: 40)
    }

    private func write(_ text: String, to storage: NSTextStorage) {
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    }

    /// Force the frame the text view would take for the text it holds,
    /// which is what the scroll view reads to decide what can scroll.
    private func settle(
        _ textView: InkTextView, _ layoutManager: NSLayoutManager, _ container: NSTextContainer
    ) {
        layoutManager.ensureLayout(for: container)
        textView.sizeToFit()
    }

    func testAnUnwrappedLineOutgrowsTheCardAndCanScrollSideways() {
        let (scroll, textView, storage, layoutManager, container) = makeStack()
        write(longLine, to: storage)
        InkEditorView.setWrap(false, textView: textView, scroll: scroll)
        settle(textView, layoutManager, container)

        XCTAssertGreaterThan(
            textView.frame.width, scroll.contentSize.width,
            "the line was folded back into the card, so nothing was unwrapped"
        )
        XCTAssertTrue(
            scroll.hasHorizontalScroller,
            "the page runs wider than its clip with no way to travel there"
        )
    }

    func testAWrappedLineNeverOutgrowsTheCard() {
        let (scroll, textView, storage, layoutManager, container) = makeStack()
        write(longLine, to: storage)
        InkEditorView.setWrap(true, textView: textView, scroll: scroll)
        settle(textView, layoutManager, container)

        XCTAssertLessThanOrEqual(
            textView.frame.width, scroll.contentSize.width,
            "a wrapped page ran past the card's edge"
        )
        XCTAssertFalse(scroll.hasHorizontalScroller)
    }

    /// The return trip is the one the flags do not make on their own: a
    /// text view that ran wide keeps that frame, and only an explicit
    /// hand-back takes it down to the card again.
    func testWrappingAgainTakesBackTheWidthTheLineClaimed() {
        let (scroll, textView, storage, layoutManager, container) = makeStack()
        write(longLine, to: storage)
        InkEditorView.setWrap(false, textView: textView, scroll: scroll)
        settle(textView, layoutManager, container)
        XCTAssertGreaterThan(textView.frame.width, scroll.contentSize.width)

        InkEditorView.setWrap(true, textView: textView, scroll: scroll)
        settle(textView, layoutManager, container)

        XCTAssertLessThanOrEqual(
            textView.frame.width, scroll.contentSize.width,
            "the page kept the width it took while unwrapped"
        )
        XCTAssertFalse(scroll.hasHorizontalScroller)
    }

    /// Unwrapped, the page sizes itself to its longest line. A page of
    /// short lines must still fill the card, or every click to the right
    /// of the text falls on the scroll view and places no caret.
    func testAnUnwrappedShortPageStillFillsTheCard() {
        let (scroll, textView, storage, layoutManager, container) = makeStack()
        write("hi\nthere\n", to: storage)
        InkEditorView.setWrap(false, textView: textView, scroll: scroll)
        settle(textView, layoutManager, container)

        XCTAssertGreaterThanOrEqual(
            textView.frame.width, scroll.contentSize.width,
            "the page stopped short of the card, leaving a dead strip beside the text"
        )
    }

    /// The vertical guarantee `PageScrollTests` covers must survive the
    /// container being rebuilt: unwrapping resets the container's height
    /// as well as its width, and a height that came back finite would cap
    /// the page at one screenful again.
    func testUnwrappingKeepsALongPageScrollableDownwards() {
        let (scroll, textView, storage, layoutManager, container) = makeStack()
        write((0..<400).map { "line \($0)\n" }.joined(), to: storage)
        InkEditorView.setWrap(false, textView: textView, scroll: scroll)
        settle(textView, layoutManager, container)

        let laidOut = layoutManager.usedRect(for: container).height
        XCTAssertGreaterThan(laidOut, scroll.contentSize.height, "the fixture must outgrow its card")
        XCTAssertGreaterThanOrEqual(
            textView.frame.height, laidOut,
            "unwrapping capped the page's height, so its tail is unreachable"
        )
    }

    /// The mount order the real editor runs in: wrap is applied while
    /// the scroll view is still zero-sized, because SwiftUI gives it a
    /// frame afterwards. Unwrapped, the text view's autoresizing is off,
    /// so nothing but the clip observer will ever widen it to the card
    /// it landed in — this is that observer, end to end.
    func testAPageMountedUnwrappedFillsTheCardItLandsIn() throws {
        let suite = "wrap-tests-mount"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = PageModel(formFactor: .backdrop, defaults: defaults)

        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        let storage = NSTextStorage(string: "hi\n")
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let textView = InkTextView(frame: .zero, textContainer: container)
        let scroll = InkEditorView.scrollStack(for: textView)

        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.textView = textView
        coordinator.observeClip(of: scroll)
        coordinator.applyWrap(false)

        let card = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            textView.frame.width, scroll.contentSize.width,
            "the page stayed at its mount-time width, so most of the card is dead to clicks"
        )
    }

    // MARK: Find

    /// The Find menu items are validated against the first responder
    /// before they light up, and a page that answers no leaves ⌘F dead
    /// with nothing on screen to say why. The tags are the ones SwiftUI's
    /// `TextEditingCommands` actually ships: 1 is Find…, 12 is Find and
    /// Replace…, 2 and 3 are next and previous.
    func testTheFindMenuLightsUpOverThePage() {
        let (_, textView, _, _, _) = makeStack()
        InkEditorView.enableFinding(on: textView)

        for tag in [1, 12, 2, 3] {
            let item = NSMenuItem(
                title: "find",
                action: #selector(NSTextView.performFindPanelAction(_:)),
                keyEquivalent: ""
            )
            item.tag = tag
            XCTAssertTrue(
                textView.validateUserInterfaceItem(item),
                "the page refuses find action \(tag), so its menu item stays grey"
            )
        }
    }

    /// ⌘E over a chip would put the chip's attachment character in the
    /// search field, and from there a Replace All would delete sealed
    /// bytes as a side effect of a text operation. It refuses instead
    /// (ADR-0009: a chip leaves only by an act aimed at the chip).
    func testUseSelectionForFindRefusesAChip() throws {
        let (_, textView, storage, _, _) = makeStack()
        InkEditorView.enableFinding(on: textView)
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: InkEditorView.Coordinator.chipString(
                ChipInfo(
                    chipId: 1, kind: "text", excerpt: "to…en",
                    sizeLabel: "5 ch", promoted: false
                )
            )
        )
        textView.setSelectedRange(NSRange(location: 0, length: storage.length))

        let item = NSMenuItem(
            title: "Use Selection for Find",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: ""
        )
        item.tag = NSTextFinder.Action.setSearchString.rawValue
        XCTAssertTrue(textView.refusesFinderAction(item))
    }

    /// The refusal is aimed at chips alone: ⌘E over ordinary ink is how
    /// find is meant to be used.
    func testUseSelectionForFindAllowsInk() {
        let (_, textView, storage, _, _) = makeStack()
        InkEditorView.enableFinding(on: textView)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "deploy friday")
        textView.setSelectedRange(NSRange(location: 0, length: 6))

        let item = NSMenuItem(
            title: "Use Selection for Find",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: ""
        )
        item.tag = NSTextFinder.Action.setSearchString.rawValue
        XCTAssertFalse(textView.refusesFinderAction(item))
    }

    // MARK: The state behind the geometry

    func testAPageWrapsUntilToldOtherwise() throws {
        let suite = "wrap-tests-default"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertTrue(PageModel(formFactor: .backdrop, defaults: defaults).wrapsLines)
    }

    /// ⌥Z and the Settings toggle are the same value, and it outlives the
    /// session: the page opens however it was last left.
    func testTheToggleSticks() throws {
        let suite = "wrap-tests-persistence"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let model = PageModel(formFactor: .backdrop, defaults: defaults)
        model.toggleWrap()
        XCTAssertFalse(model.wrapsLines)
        XCTAssertFalse(PageModel(formFactor: .backdrop, defaults: defaults).wrapsLines)

        model.toggleWrap()
        XCTAssertTrue(model.wrapsLines)
        XCTAssertTrue(PageModel(formFactor: .backdrop, defaults: defaults).wrapsLines)
    }

    /// The keystroke is invisible on a page whose lines all fit, so it
    /// says what it did.
    func testTheToggleSaysWhatItDid() throws {
        let suite = "wrap-tests-notice"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let model = PageModel(formFactor: .backdrop, defaults: defaults)
        model.toggleWrap()
        XCTAssertEqual(model.notice, "long lines run on")
        model.toggleWrap()
        XCTAssertEqual(model.notice, "long lines wrap")
    }
}
