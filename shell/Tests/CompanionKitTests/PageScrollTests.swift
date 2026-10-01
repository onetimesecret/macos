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

    private func mouseEvent(
        _ type: NSEvent.EventType, in window: NSWindow,
        at location: NSPoint, flags: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1
        ))
    }

    func testBlankEditorClicksFocusAndPreserveInsertionPoint() throws {
        for ink in ["", "first line\nsecond line\n"] {
            for alreadyFocused in [false, true] {
                let (scroll, editor, storage, layoutManager, container) = makeStack(cardHeight: 720)
                let window = try XCTUnwrap(scroll.window)
                storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: ink)
                layoutManager.ensureLayout(for: container)
                scroll.layoutSubtreeIfNeeded()
                let caret = NSRange(location: min(3, storage.length), length: 0)
                editor.setSelectedRange(caret)
                _ = window.makeFirstResponder(alreadyFocused ? editor : nil)
                // Exercise the enlarged gap below the final newline through
                // the actual view hit by a click, including the clip.
                let point = NSPoint(x: 200, y: 650)
                let hit = try XCTUnwrap(scroll.hitTest(point))
                let location = scroll.convert(point, to: nil)
                window.postEvent(try mouseEvent(.leftMouseUp, in: window, at: location), atStart: true)
                hit.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, at: location))
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertEqual(editor.selectedRange(), caret)
            }
        }
    }

    func testBlankFocusPredicateLeavesNativeGesturesAlone() {
        XCTAssertTrue(InkTextView.shouldFocusBlankSpace(
            isEditable: true, clickCount: 1, modifierFlags: [.capsLock, .numericPad], containsTextLine: false
        ))
        for flags: NSEvent.ModifierFlags in [.shift, .command, .option, .control, [.shift, .option]] {
            XCTAssertFalse(InkTextView.shouldFocusBlankSpace(
                isEditable: true, clickCount: 1, modifierFlags: flags, containsTextLine: false
            ))
        }
        for count in [2, 3] {
            XCTAssertFalse(InkTextView.shouldFocusBlankSpace(
                isEditable: true, clickCount: count, modifierFlags: [], containsTextLine: false
            ))
        }
        XCTAssertFalse(InkTextView.shouldFocusBlankSpace(
            isEditable: false, clickCount: 1, modifierFlags: [], containsTextLine: false
        ))
        XCTAssertFalse(InkTextView.shouldFocusBlankSpace(
            isEditable: true, clickCount: 1, modifierFlags: [], containsTextLine: true
        ))
    }

    func testBlankMouseDownLeavesDragQueuedForNativeTracking() throws {
        let (scroll, editor, _, _, _) = makeStack(cardHeight: 320)
        let window = try XCTUnwrap(scroll.window)
        let start = NSPoint(x: 200, y: 250)
        let drag = try mouseEvent(.leftMouseDragged, in: window, at: NSPoint(x: 200, y: 50))
        window.postEvent(drag, atStart: true)
        XCTAssertFalse(editor.consumeBlankFocusClick(try mouseEvent(.leftMouseDown, in: window, at: start)))
        let queued = window.nextEvent(
            matching: .leftMouseDragged, until: .distantPast, inMode: .eventTracking, dequeue: true
        )
        XCTAssertEqual(queued?.type, .leftMouseDragged,
                       "NSTextView must receive the drag rather than losing it to focus handling")
        XCTAssertEqual(queued?.locationInWindow, drag.locationInWindow)
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

    func testAttachmentLineBandKeepsNativeCaretPlacement() {
        let (_, editor, storage, layoutManager, container) = makeStack(cardHeight: 320)
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: NSImage(size: NSSize(width: 80, height: 100)))
        storage.setAttributedString(NSAttributedString(attachment: attachment))
        layoutManager.ensureLayout(for: container)
        let line = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        XCTAssertGreaterThan(line.height, 50)
        XCTAssertTrue(editor.containsTextLine(at: NSPoint(
            x: 200, y: editor.textContainerOrigin.y + line.midY
        )))
        XCTAssertFalse(editor.containsTextLine(at: NSPoint(
            x: 200, y: editor.textContainerOrigin.y + line.maxY + 20
        )))
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
        window.postEvent(try mouseEvent(.leftMouseUp, in: window, at: event.locationInWindow), atStart: true)
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
