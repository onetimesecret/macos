import AppKit
import XCTest

@testable import CompanionKit

/// A page longer than the card must stay reachable. The bug this guards
/// against was silent: text kept arriving, the caret kept moving down,
/// and everything past one cardful simply could not be scrolled to,
/// because `NSScrollView` had capped the text view's `maxSize` at the
/// clip's size and a vertically resizable text view will not grow past
/// it. The assertion is the document's own height against the layout it
/// was given, which is the fact the scroller reads.
@MainActor
final class PageScrollTests: XCTestCase {
    /// The editor's TextKit 1 stack in a real window, wired through the
    /// same `scrollStack` the mounted editor uses.
    private func makeStack(cardHeight: CGFloat) -> (NSScrollView, InkTextView, NSTextStorage, NSLayoutManager, NSTextContainer) {
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

        // The card: a window the scroll view fills, sized as the
        // backdrop sizes it. The frame lands after the document view is
        // in place, which is the ordering that provoked the cap.
        let card = NSRect(x: 0, y: 0, width: 420, height: cardHeight)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        return (scroll, textView, storage, layoutManager, container)
    }

    private func page(lines: Int) -> String {
        (0..<lines).map { "line \($0) of the page\n" }.joined()
    }

    func testBlankEditorClicksFocusAndPreserveInsertionPoint() throws {
        for ink in ["", "first line\nsecond line"] {
            let (scroll, editor, storage, layoutManager, container) = makeStack(cardHeight: 320)
            let window = try XCTUnwrap(scroll.window)
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: ink)
            layoutManager.ensureLayout(for: container)
            scroll.layoutSubtreeIfNeeded()
            let caret = NSRange(location: min(3, storage.length), length: 0)
            editor.setSelectedRange(caret)
            _ = window.makeFirstResponder(nil)
            let point = NSPoint(x: 200, y: 250)
            let hit = try XCTUnwrap(scroll.hitTest(point))
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: scroll.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            hit.mouseDown(with: event)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), caret)
        }
    }

    func testTextLineBandsKeepNativeCaretPlacement() {
        let (_, editor, storage, layoutManager, container) = makeStack(cardHeight: 320)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "first line\nsecond line\n")
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            XCTAssertTrue(editor.containsTextLine(at: NSPoint(
                x: 200, y: editor.textContainerOrigin.y + rect.midY
            )), "clicking anywhere along an existing line must use native selection")
        }
        XCTAssertTrue(editor.containsTextLine(at: NSPoint(
            x: 200, y: editor.textContainerOrigin.y + layoutManager.extraLineFragmentRect.midY
        )), "the empty final line is still a line")
        XCTAssertFalse(editor.containsTextLine(at: NSPoint(x: 200, y: 250)))
        XCTAssertFalse(editor.containsTextLine(at: NSPoint(x: 200, y: 2)))
    }

    func testBlankClipAcceptsTheFirstClickAndFocusesItsEditor() throws {
        let (scroll, editor, _, _, _) = makeStack(cardHeight: 320)
        let window = try XCTUnwrap(scroll.window)
        let clip = scroll.contentView
        _ = window.makeFirstResponder(nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 200, y: 250),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        XCTAssertTrue(clip.needsPanelToBecomeKey)
        XCTAssertTrue(clip.acceptsFirstMouse(for: event))
        clip.mouseDown(with: event)
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testAPageTallerThanTheCardCanScroll() {
        let (scroll, textView, storage, layoutManager, container) = makeStack(cardHeight: 320)
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 0), with: page(lines: 400)
        )
        layoutManager.ensureLayout(for: container)
        scroll.layoutSubtreeIfNeeded()

        let laidOut = layoutManager.usedRect(for: container).height
        XCTAssertGreaterThan(laidOut, 320, "the fixture must outgrow its card")
        XCTAssertGreaterThanOrEqual(
            textView.frame.height, laidOut,
            "the document stopped growing, so the tail of the page is unreachable"
        )
        XCTAssertGreaterThan(
            textView.frame.height - scroll.contentView.bounds.height, 0,
            "a document no taller than its clip has nothing to scroll"
        )
    }

    /// The last line must be scrollable *to*, not merely accounted for:
    /// the clip has to be able to travel far enough to put it on screen.
    func testTheEndOfALongPageCanBeReached() {
        let (scroll, textView, storage, layoutManager, container) = makeStack(cardHeight: 320)
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 0), with: page(lines: 400)
        )
        layoutManager.ensureLayout(for: container)
        scroll.layoutSubtreeIfNeeded()

        let bottom = textView.frame.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)

        let lastGlyph = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: layoutManager.numberOfGlyphs - 1, length: 1),
            in: container
        )
        XCTAssertTrue(
            scroll.contentView.bounds.intersects(lastGlyph.offsetBy(
                dx: textView.textContainerInset.width,
                dy: textView.textContainerInset.height
            )),
            "the page's last line never comes into view"
        )
    }

    /// The cap the scroll view would otherwise stamp is taken from the
    /// card's height at mount, so a card that starts small was the worst
    /// case: it would fix the ceiling low and never lift it.
    func testAShortCardDoesNotCapTheDocument() {
        let (_, textView, storage, layoutManager, container) = makeStack(cardHeight: 120)
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 0), with: page(lines: 200)
        )
        layoutManager.ensureLayout(for: container)

        XCTAssertGreaterThanOrEqual(
            textView.frame.height, layoutManager.usedRect(for: container).height,
            "the mount-time card height became the page's ceiling"
        )
    }
}
