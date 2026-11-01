import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

@MainActor
private final class PaletteEditorProbe: NSTextView, CommandPaletteResponder {
    var performed: [CommandID] = []
    var selectionAtExecution: NSRange?
    var wasFirstResponder = false
    func prepareForCommandPalette() -> Bool { true }
    func canPerformPaletteCommand(_ command: CommandID) -> Bool { command == .clipboardSealSelection }
    func performPaletteCommand(_ command: CommandID) -> Bool {
        performed.append(command)
        selectionAtExecution = selectedRange()
        wasFirstResponder = window?.firstResponder === self
        return true
    }
}

@MainActor
final class CommandPaletteControllerTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let tag = "palette-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(tag)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: tag))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: tag)
            try? FileManager.default.removeItem(at: directory)
        }
        companion_init()
        let handle = try XCTUnwrap(tag.withCString { companion_new_ephemeral($0) })
        return PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: CompanionClient(adopting: handle)))
    }

    private func makeWindow() -> (NSWindow, PaletteEditorProbe) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = PaletteEditorProbe(frame: window.contentView!.bounds)
        editor.string = "original selection"
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        _ = window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 3, length: 5))
        return (window, editor)
    }

    private func render(_ palette: CommandPaletteController, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ONETIMEPAD_PALETTE_PREVIEW_DIR"],
              let overlay = palette.overlay else { return }
        overlay.layoutSubtreeIfNeeded()
        palette.table.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }

    func testEscapeRestoresOriginalSelectionAndResponder() throws {
        let model = try makeModel()
        let (window, editor) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        XCTAssertNotNil(palette.overlay)
        try render(palette, named: "commands-640w")
        window.setContentSize(NSSize(width: 360, height: 480))
        palette.overlay?.needsLayout = true
        try render(palette, named: "commands-360w")
        editor.setSelectedRange(NSRange(location: 0, length: 1))
        XCTAssertTrue(palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertNil(palette.overlay)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 5))
    }

    func testSearchKeepsOriginalEditorCommandsAndRestoresContextBeforeExecution() throws {
        let model = try makeModel()
        let (window, editor) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        palette.search.stringValue = "seal selected"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 1)
        editor.setSelectedRange(NSRange(location: 0, length: 1))
        XCTAssertTrue(palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(editor.performed, [.clipboardSealSelection])
        XCTAssertEqual(editor.selectionAtExecution, NSRange(location: 3, length: 5))
        XCTAssertTrue(editor.wasFirstResponder)
    }

    func testAChangedPageCannotReceiveTheCapturedSelectionCommand() throws {
        let model = try makeModel()
        let (window, editor) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        palette.search.stringValue = "seal selected"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        model.newPage()
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(editor.performed.isEmpty)
    }

    func testReopenDatedTabsIsAvailableWithoutAnOpenPage() throws {
        let model = try makeModel()
        let (window, _) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: false)
        palette.search.stringValue = "reopen dated"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 1)
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertNotNil(palette.overlay)
        XCTAssertEqual(palette.table.numberOfRows, 0)
    }

    func testEditingTheSamePageInvalidatesItsCapturedSelectionCommand() throws {
        let model = try makeModel()
        let (window, editor) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        palette.search.stringValue = "seal selected"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        editor.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "new prefix ")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(editor.performed.isEmpty)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testCloseWindowIsSeparateAndPageCloseIsAbsentWithoutAPage() throws {
        let model = try makeModel()
        let (window, _) = makeWindow()
        defer { window.close() }
        var commands: [CommandID] = []
        let palette = CommandPaletteController(model: model, performWindowCommand: { commands.append($0) }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        palette.search.stringValue = "page::Close"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 0)
        palette.search.stringValue = "close window"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 1)
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(commands, [.windowClose])
    }


    func testDatedPickerRestoresTheExistingSavedItem() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let tab = try XCTUnwrap(model.selection)
        XCTAssertTrue(model.coreClient.syncDocument(sheet: page, json: #"[{"ink":"A synthetic saved page"}]"#))
        model.refresh()
        model.closeCurrent()
        XCTAssertEqual(model.closedTabs.first?.id, tab)
        let (window, _) = makeWindow()
        defer { window.close() }
        var returned = 0
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: { returned += 1 })
        palette.show(in: window, pageContext: false, reopen: true)
        XCTAssertEqual(palette.table.numberOfRows, 1)
        try render(palette, named: "closed-pages-640w")
        window.setContentSize(NSSize(width: 360, height: 480))
        palette.overlay?.needsLayout = true
        try render(palette, named: "closed-pages-360w")
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(model.selection, tab)
        XCTAssertEqual(model.selectedPageID, page)
        XCTAssertTrue(model.closedTabs.isEmpty)
        XCTAssertEqual(returned, 1)
    }


    func testEscapeRestoresTheOriginalTextFieldAfterTheSearchReusesItsFieldEditor() throws {
        let model = try makeModel()
        let (window, _) = makeWindow()
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 28))
        field.stringValue = "original settings value"
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let original = try XCTUnwrap(field.currentEditor() as? NSTextView)
        original.setSelectedRange(NSRange(location: 2, length: 6))
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        let searchEditor = try XCTUnwrap(palette.search.currentEditor() as? NSTextView)
        searchEditor.insertText("timeline", replacementRange: NSRange(location: 0, length: searchEditor.string.utf16.count))
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        _ = palette.control(palette.search, textView: searchEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(palette.overlay)
        XCTAssertEqual(field.stringValue, "original settings value")
        let restored = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === restored)
        XCTAssertTrue(restored.delegate === field)
        XCTAssertEqual(restored.selectedRange(), NSRange(location: 2, length: 6))
    }


    func testRealizedRowsKeepShortcutLabelsInsideTheirActualCellBounds() throws {
        let model = try makeModel()
        let (window, _) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: false)
        for width in [CGFloat(640), 360] {
            window.setContentSize(NSSize(width: width, height: 480))
            palette.overlay?.needsLayout = true
            palette.overlay?.layoutSubtreeIfNeeded()
            palette.table.layoutSubtreeIfNeeded()
            for row in 0..<palette.table.numberOfRows {
                palette.table.scrollRowToVisible(row)
                let cell = try XCTUnwrap(palette.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? PaletteCommandCell)
                cell.layoutSubtreeIfNeeded()
                for label in [cell.titleLabel, cell.detailLabel, cell.shortcutLabel] {
                    XCTAssertTrue(cell.bounds.contains(label.frame), "label outside realized row at width \(width)")
                }
                let visible = palette.table.visibleRect
                let shortcut = cell.convert(cell.shortcutLabel.frame, to: palette.table)
                XCTAssertGreaterThanOrEqual(shortcut.minX, visible.minX)
                XCTAssertLessThanOrEqual(shortcut.maxX, visible.maxX)
                XCTAssertGreaterThanOrEqual(cell.shortcutLabel.frame.width, cell.shortcutLabel.intrinsicContentSize.width)
                XCTAssertFalse(cell.titleLabel.frame.intersects(cell.shortcutLabel.frame))
            }
        }
    }


    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testRealSealedNoteSurvivesQueuedFocusLossAndRestoresBeforePaletteRelease() async throws {
        for runCommand in [false, true] {
            let model = try makeModel()
            model.newPage()
            let page = try XCTUnwrap(model.selectedPageID)
            let coordinator = InkEditorView.Coordinator(model: model)
            let editor = try XCTUnwrap(InkEditorView.makeInkTextView(model: model, sheetID: page, coordinator: coordinator))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let scroll = InkEditorView.bareScroller()
            scroll.frame = window.contentLayoutRect
            InkEditorView.seat(editor, in: scroll)
            window.contentView = scroll
            window.orderFront(nil)
            _ = window.makeFirstResponder(editor)
            editor.insertText("ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.setSelectedRange(NSRange(location: 3, length: 6))
            coordinator.sealSelectionOrLine()
            editor.layout()
            editor.layoutManager?.ensureLayout(for: try XCTUnwrap(editor.textContainer))
            coordinator.beginNote(at: 3)
            let note = try XCTUnwrap(coordinator.noteEditor)
            note.textView.insertText("synthetic note", replacementRange: NSRange(location: NSNotFound, length: 0))
            let selection = NSRange(location: 2, length: 5)
            note.textView.setSelectedRange(selection)
            let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
            palette.show(in: window, pageContext: true)
            await drainMainQueue()
            XCTAssertTrue(note.isOpen)
            XCTAssertEqual(note.textView.string, "synthetic note")
            if runCommand {
                palette.search.stringValue = "note expansion"
                palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
                XCTAssertEqual(palette.table.numberOfRows, 1)
                _ = palette.control(palette.search, textView: NSTextView(),
                    doCommandBy: #selector(NSResponder.insertNewline(_:)))
            } else {
                _ = palette.control(palette.search, textView: NSTextView(),
                    doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            }
            await drainMainQueue()
            XCTAssertTrue(note.isOpen)
            XCTAssertEqual(note.isExpanded, runCommand)
            XCTAssertTrue(window.firstResponder === note.textView)
            XCTAssertEqual(note.textView.selectedRange(), selection)
            _ = window.makeFirstResponder(editor)
            await drainMainQueue()
            XCTAssertFalse(note.isOpen)
        }
    }

    func testPaletteInteriorClicksDoNotDismissButOutsideClicksDo() throws {
        let model = try makeModel()
        let (window, _) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: false)
        let overlay = try XCTUnwrap(palette.overlay)
        let card = try XCTUnwrap(overlay.interactiveRegion)
        for point in [NSPoint(x: card.frame.minX + 2, y: card.frame.minY + 2),
                      NSPoint(x: card.frame.midX, y: card.frame.minY + 15)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: overlay.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            overlay.mouseDown(with: event)
            XCTAssertNotNil(palette.overlay)
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: overlay.convert(NSPoint(x: 2, y: 2), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        overlay.mouseDown(with: event)
        XCTAssertNil(palette.overlay)
    }

    func testResizeDoesNotTakeFocusFromTheResults() throws {
        let model = try makeModel()
        let (window, _) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: false)
        XCTAssertTrue(window.makeFirstResponder(palette.table))
        window.setContentSize(NSSize(width: 360, height: 480))
        palette.overlay?.needsLayout = true
        palette.overlay?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.firstResponder === palette.table)
    }

    func testThePaletteShortcutTogglesAndReopenModeHasABackRoute() throws {
        let model = try makeModel()
        let (window, editor) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: false)
        palette.show(in: window, pageContext: false)
        XCTAssertNil(palette.overlay)
        XCTAssertTrue(window.firstResponder === editor)
        palette.show(in: window, pageContext: false, reopen: true)
        XCTAssertFalse(palette.backButton.isHidden)
        palette.backButton.performClick(nil)
        XCTAssertTrue(palette.backButton.isHidden)
        XCTAssertGreaterThan(palette.table.numberOfRows, 0)
        XCTAssertTrue(palette.search.nextKeyView === palette.table)
        XCTAssertTrue(palette.table.nextKeyView === palette.search)
    }

}
