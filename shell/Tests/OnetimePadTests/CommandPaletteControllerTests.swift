import AppKit
import CompanionCore
import SwiftUI
import XCTest

@testable import CompanionKit
@testable import OnetimePad

@MainActor
private final class PaletteEditorProbe: NSTextView, CommandPaletteResponder {
    var performed: [CommandID] = []
    var selectionAtExecution: NSRange?
    var wasFirstResponder = false
    private(set) var borrowBegins = 0
    private(set) var borrowEnds = 0
    func beginPaletteFocusBorrow() { borrowBegins += 1 }
    func endPaletteFocusBorrow() { borrowEnds += 1 }
    var allowsPreparation = true
    func prepareForCommandPalette() -> Bool { allowsPreparation }
    func canPerformPaletteCommand(_ command: CommandID) -> Bool { command == .clipboardSealSelection }
    func performPaletteCommand(_ command: CommandID) -> Bool {
        performed.append(command)
        selectionAtExecution = selectedRange()
        wasFirstResponder = window?.firstResponder === self
        return true
    }
}

@MainActor
private final class PaletteEventSink: NSResponder {
    private(set) var scrolls = 0
    private(set) var rightPresses = 0
    override func scrollWheel(with event: NSEvent) { scrolls += 1 }
    override func rightMouseDown(with event: NSEvent) { rightPresses += 1 }
}

@MainActor
private final class PaletteKeyEquivalentSink: NSView {
    private(set) var received = 0
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        received += 1
        return true
    }
}

@MainActor
final class CommandPaletteControllerTests: XCTestCase {
    private func makeModel(overrideText: String? = nil) throws -> PageModel {
        let tag = "palette-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(tag)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: tag))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: tag)
            try? FileManager.default.removeItem(at: directory)
        }
        var override: URL?
        if let overrideText {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-keymap-\(UUID().uuidString).json")
            try overrideText.write(to: url, atomically: true, encoding: .utf8)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            override = url
        }
        companion_init()
        let handle = try XCTUnwrap(tag.withCString { companion_new_ephemeral($0) })
        return PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: CompanionClient(adopting: handle), keymapOverride: override))
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
        XCTAssertEqual(model.notice, CompanionL10n.string("palette.context_changed"))
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
        XCTAssertNotNil(palette.overlay)
        XCTAssertEqual(palette.search.stringValue, "")
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


    func testInvokingFromAnotherWindowMovesThePaletteWithoutRestoringTheOldResponder() throws {
        let model = try makeModel()
        let (first, firstEditor) = makeWindow()
        let (second, secondEditor) = makeWindow()
        defer { first.close(); second.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: first, pageContext: false)
        XCTAssertTrue(palette.overlay?.window === first)
        palette.show(in: second, pageContext: true)
        XCTAssertTrue(palette.overlay?.window === second)
        XCTAssertFalse(first.firstResponder === firstEditor)
        XCTAssertEqual(firstEditor.borrowEnds, 1)
        XCTAssertEqual(secondEditor.borrowBegins, 1)
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(second.firstResponder === secondEditor)
        XCTAssertEqual(secondEditor.borrowEnds, 1)
    }

    func testCrossWindowReopenUsesTheInvokingWindowAndRemovesTheOldWindowObserver() throws {
        let model = try makeModel()
        let (first, firstEditor) = makeWindow()
        let (second, secondEditor) = makeWindow()
        defer { first.close(); second.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: first, pageContext: false)
        palette.show(in: second, pageContext: true, reopen: true)
        XCTAssertTrue(palette.overlay?.window === second)
        XCTAssertFalse(palette.backButton.isHidden)
        XCTAssertEqual(palette.search.placeholderString, CompanionL10n.string("Search closed pages or tabs…"))
        XCTAssertEqual(firstEditor.borrowEnds, 1)
        first.close()
        XCTAssertTrue(palette.overlay?.window === second)
        second.close()
        XCTAssertNil(palette.overlay)
        XCTAssertEqual(secondEditor.borrowEnds, 1)
    }

    func testClosingTheOriginWindowDismissesThePaletteAndReleasesItsFocusBorrow() throws {
        let model = try makeModel()
        let (window, editor) = makeWindow()
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        XCTAssertEqual(editor.borrowBegins, 1)
        window.close()
        XCTAssertNil(palette.overlay)
        XCTAssertEqual(editor.borrowEnds, 1)
        palette.dismiss(restoringFocus: true)
        XCTAssertEqual(editor.borrowEnds, 1)
    }


    func testSaveAvailabilityAndCloseLabelsMatchTheCurrentSurface() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let (window, _) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        palette.search.stringValue = "state::SaveNow"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 0)
        palette.dismiss(restoringFocus: true)
        model.showLedger()
        palette.show(in: window, pageContext: true)
        palette.search.stringValue = "close ledger"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 1)
        let ledgerRow = try XCTUnwrap(palette.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PaletteCommandCell)
        XCTAssertEqual(ledgerRow.titleLabel.stringValue, "Close Ledger")
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertFalse(model.showingLedger)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.txt")
        try "synthetic file".write(to: file, atomically: true, encoding: .utf8)
        model.openFile(at: file)
        palette.show(in: window, pageContext: true)
        palette.search.stringValue = "state::SaveNow"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 1)
        palette.search.stringValue = "close file"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 1)
        let fileRow = try XCTUnwrap(palette.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PaletteCommandCell)
        XCTAssertEqual(fileRow.titleLabel.stringValue, "Close File")
    }

    func testEnteringReopenModeReturnsFocusToItsSearchField() throws {
        let model = try makeModel()
        let (window, _) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: false)
        XCTAssertTrue(window.makeFirstResponder(palette.table))
        palette.show(in: window, pageContext: false, reopen: true)
        XCTAssertTrue(window.firstResponder === palette.search.currentEditor())
        XCTAssertFalse(palette.backButton.isHidden)
    }

    func testLosingTheOriginWindowsKeysDismissesAndReleasesTheFocusBorrow() throws {
        let model = try makeModel()
        let (window, editor) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNil(palette.overlay)
        XCTAssertEqual(editor.borrowEnds, 1)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 5))
    }

    func testViewMenuChecksTheCurrentLayout() throws {
        let model = try makeModel()
        let tag = "palette-menu-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: tag))
        defer { UserDefaults.standard.removePersistentDomain(forName: tag) }
        let app = BackdropAppDelegate(model: BackdropModel(defaults: defaults, pages: model))
        prepareApplicationMenuRoles()
        let previous = NSApp.mainMenu
        let windows = NSApp.windowsMenu, help = NSApp.helpMenu, services = NSApp.servicesMenu
        let servicesItem = services?.supermenu?.items.first { $0.submenu === services }
        defer {
            services?.supermenu?.items.first { $0.submenu === services }?.submenu = nil
            servicesItem?.submenu = services
            NSApp.mainMenu = previous
            NSApp.windowsMenu = windows
            NSApp.helpMenu = help
            NSApp.servicesMenu = services
        }
        let controller = MainMenuController(app: app)
        controller.install()
        let view = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == CompanionL10n.string("View") }?.submenu)
        let timeline = try XCTUnwrap(view.items.first { $0.title == CompanionL10n.string("Open Timeline") })
        let tabs = try XCTUnwrap(view.items.first { $0.title == CompanionL10n.string("Switch to Tabs View") })
        for showsTimeline in [false, true] {
            model.showsTimeUnits = showsTimeline
            controller.menuNeedsUpdate(view)
            XCTAssertEqual(timeline.state, showsTimeline ? .on : .off)
            XCTAssertEqual(tabs.state, showsTimeline ? .off : .on)
        }
    }


    func testPaletteRemainsAboveHostedContentAcrossSwiftUIUpdatesAndResizes() async throws {
        let model = try makeModel()
        let (window, _) = makeWindow()
        defer { window.close() }
        let hosted = NSHostingView(rootView: Text("synthetic before"))
        let container = PresentationContentContainer(content: hosted)
        window.contentView = container
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: false)
        let overlay = try XCTUnwrap(palette.overlay)
        for width in [CGFloat(640), 360] {
            hosted.rootView = Text("synthetic update at \(width)")
            window.setContentSize(NSSize(width: width, height: 480))
            await drainMainQueue()
            container.layoutSubtreeIfNeeded()
            hosted.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.contentView === container)
            XCTAssertTrue(overlay.superview === container)
            XCTAssertTrue(container.subviews.last === overlay)
            XCTAssertTrue(hosted.superview === container)
            XCTAssertEqual(hosted.frame, container.bounds)
            XCTAssertEqual(overlay.frame, container.bounds)
        }
    }

    func testPaletteShieldsBackgroundScrollingAndContextClicks() throws {
        let model = try makeModel()
        let (window, _) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: false)
        let overlay = try XCTUnwrap(palette.overlay)
        let sink = PaletteEventSink()
        let previous = overlay.nextResponder
        defer { overlay.nextResponder = previous }
        overlay.nextResponder = sink
        let cgScroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0))
        let scroll = try XCTUnwrap(NSEvent(cgEvent: cgScroll))
        overlay.scrollWheel(with: scroll)
        let right = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        overlay.rightMouseDown(with: right)
        XCTAssertEqual(sink.scrolls, 0)
        XCTAssertEqual(sink.rightPresses, 0)
        XCTAssertNotNil(palette.overlay)
    }

    func testCloseKeyEquivalentDismissesThePaletteBeforeTheUnderlyingPage() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let original = model.navigationTabs.map(\.id)
        let (window, editor) = makeWindow()
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let container = PresentationContentContainer(content: content)
        window.contentView = container
        _ = window.makeFirstResponder(editor)
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertTrue(container.performKeyEquivalent(with: event))
        XCTAssertNil(palette.overlay)
        XCTAssertEqual(model.navigationTabs.map(\.id), original)
        XCTAssertTrue(window.firstResponder === editor)
        let selection = editor.selectedRanges
        palette.show(in: window, pageContext: true)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        XCTAssertTrue(container.performKeyEquivalent(with: escape))
        XCTAssertNil(palette.overlay)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRanges, selection)
        XCTAssertEqual(model.navigationTabs.map(\.id), original)
        palette.show(in: window, pageContext: true)
        XCTAssertTrue(palette.dismissForClose(in: window))
        XCTAssertFalse(palette.dismissForClose(in: window))
        XCTAssertEqual(model.navigationTabs.map(\.id), original)
    }

    func testRestylingAttributesKeepsTheCapturedSelectionCommandUsable() throws {
        let model = try makeModel()
        let (window, editor) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        palette.search.stringValue = "seal selected"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.systemRed,
            range: NSRange(location: 0, length: editor.string.utf16.count))
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(editor.performed, [.clipboardSealSelection])
        XCTAssertEqual(editor.selectionAtExecution, NSRange(location: 3, length: 5))
    }

    func testEscapeClearsTheSearchBeforeDismissingThePalette() throws {
        let model = try makeModel()
        let (window, editor) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        palette.search.stringValue = "seal selected"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(palette.search.stringValue, "")
        XCTAssertNotNil(palette.overlay)
        XCTAssertGreaterThan(palette.table.numberOfRows, 1)
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(palette.overlay)
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testARefusedOtherWindowRequestLeavesTheExistingPaletteOpen() throws {
        let model = try makeModel()
        let (first, firstEditor) = makeWindow()
        let (second, secondEditor) = makeWindow()
        defer { first.close(); second.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: first, pageContext: false)
        let overlay = try XCTUnwrap(palette.overlay)
        secondEditor.allowsPreparation = false
        model.mountEditor(secondEditor, from: model.owner)
        palette.show(in: second, pageContext: true)
        XCTAssertTrue(palette.overlay === overlay)
        XCTAssertTrue(overlay.window === first)
        XCTAssertEqual(firstEditor.borrowEnds, 0)
        XCTAssertEqual(secondEditor.borrowBegins, 0)
    }

    func testSealedNameRestylingDoesNotInvalidatePageCommands() throws {
        let model = try makeModel()
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let coordinator = InkEditorView.Coordinator(model: model)
        let editor = try XCTUnwrap(InkEditorView.makeInkTextView(model: model, sheetID: page, coordinator: coordinator))
        let (window, placeholder) = makeWindow()
        defer { window.close() }
        placeholder.removeFromSuperview()
        let scroll = InkEditorView.bareScroller()
        scroll.frame = window.contentLayoutRect
        InkEditorView.seat(editor, in: scroll)
        window.contentView = scroll
        _ = window.makeFirstResponder(editor)
        editor.insertText("ab SECRET cd", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 3, length: 6))
        coordinator.sealSelectionOrLine()
        let chip = try XCTUnwrap(editor.chipCell(at: 3)?.info.chipId)
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        palette.search.stringValue = "Toggle Line Wrapping"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 1)
        XCTAssertTrue(model.setChipName("API_KEY", chip: chip, sheet: page))
        let wrapped = model.wrapsLines
        _ = palette.control(palette.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(model.wrapsLines, !wrapped)
    }

    func testSettingsTabContentCannotPreemptPaletteCloseAndKeepsItsController() throws {
        let model = try makeModel()
        _ = NSApplication.shared
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        var sinks: [PaletteKeyEquivalentSink] = []
        for index in 0..<2 {
            let controller = NSViewController()
            let sink = PaletteKeyEquivalentSink(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
            controller.view = sink
            controller.title = "Synthetic settings \(index)"
            controller.preferredContentSize = sink.frame.size
            tabs.addTabViewItem(NSTabViewItem(viewController: controller))
            sinks.append(sink)
        }
        let window = SettingsPaletteWindow(contentViewController: tabs)
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        defer { window.close() }
        window.orderFront(nil)
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        let close = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        for index in 0..<2 {
            tabs.selectedTabViewItemIndex = index
            palette.show(in: window, pageContext: false)
            XCTAssertTrue(window.contentViewController === tabs)
            XCTAssertTrue(palette.overlay?.superview === window.contentView)
            XCTAssertTrue(window.contentView?.subviews.last === palette.overlay)
            XCTAssertTrue(window.performKeyEquivalent(with: close))
            XCTAssertNil(palette.overlay)
            XCTAssertEqual(tabs.selectedTabViewItemIndex, index)
            XCTAssertEqual(sinks.reduce(0) { $0 + $1.received }, 0)
        }
    }

    func testUndoAndRedoKeepTheSearchResponderAndPaletteOpen() throws {
        let model = try makeModel()
        let (window, originalEditor) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        let searchEditor = try XCTUnwrap(palette.search.currentEditor())
        for modifiers in [NSEvent.ModifierFlags.command, [.command, .shift]] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
            XCTAssertFalse(try XCTUnwrap(palette.overlay).performKeyEquivalent(with: event))
            XCTAssertNotNil(palette.overlay)
            XCTAssertTrue(window.firstResponder === searchEditor)
            XCTAssertFalse(window.firstResponder === originalEditor)
        }
    }

    func testTheOpenDatedPickerRefreshesWhenItsPageExpiresAndDismissalClearsCells() async throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let tab = try XCTUnwrap(model.selection)
        let title = "synthetic derived title before expiry"
        XCTAssertTrue(model.coreClient.syncDocument(sheet: page, json: #"[{"ink":"synthetic derived title before expiry"}]"#))
        model.refresh()
        model.closeCurrent()
        let (window, _) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: false, reopen: true)
        let overlay = try XCTUnwrap(palette.overlay)
        let oldCell = try XCTUnwrap(palette.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PaletteCommandCell)
        XCTAssertEqual(oldCell.titleLabel.stringValue, title)
        XCTAssertTrue(companion_test_age_ms(model.coreClient.rawHandleForTests, 31 * 24 * 60 * 60 * 1_000))
        _ = model.settleCoreEvent()
        await drainMainQueue()
        let expired = try XCTUnwrap(model.closedTabs.first { $0.id == tab })
        XCTAssertFalse(expired.hasPage)
        XCTAssertNotEqual(expired.title, title)
        let cell = try XCTUnwrap(palette.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PaletteCommandCell)
        XCTAssertEqual(cell.titleLabel.stringValue, expired.title)
        XCTAssertFalse(oldCell.titleLabel.stringValue.contains(title))
        palette.search.stringValue = title
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 0)
        palette.dismiss(restoringFocus: true)
        XCTAssertEqual(palette.table.numberOfRows, 0)
        XCTAssertEqual(palette.search.stringValue, "")
        XCTAssertEqual(cell.titleLabel.stringValue, "")
        XCTAssertEqual(cell.detailLabel.stringValue, "")
        XCTAssertEqual(cell.shortcutLabel.stringValue, "")
        XCTAssertNil(cell.accessibilityLabel())
        XCTAssertNil(cell.toolTip)
        XCTAssertNil(overlay.superview)
        palette.show(in: window, pageContext: false)
        palette.show(in: window, pageContext: false, reopen: true)
        palette.search.stringValue = title
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
        XCTAssertEqual(palette.table.numberOfRows, 0)
    }

    func testOptionTextBindingsDoNotDismissSearchOrDispatchPageCommands() throws {
        let model = try makeModel(overrideText:
            #"[{"context":"Editor","bindings":{"alt-n":"page::New"}}]"#)
        model.loadStateIfNeeded()
        let original = model.tabs.map(\.id)
        let (window, _) = makeWindow()
        defer { window.close() }
        let palette = CommandPaletteController(model: model, performWindowCommand: { _ in }, returnToPages: {})
        palette.show(in: window, pageContext: true)
        let searchEditor = try XCTUnwrap(palette.search.currentEditor() as? NSTextView)
        searchEditor.setMarkedText("ñ", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.option], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "˜", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        XCTAssertEqual(model.keymap.command(for: event, in: .editor), .pageNew)
        XCTAssertFalse(try XCTUnwrap(palette.overlay).performKeyEquivalent(with: event))
        XCTAssertNotNil(palette.overlay)
        XCTAssertTrue(window.firstResponder === searchEditor)
        XCTAssertTrue(searchEditor.hasMarkedText())
        XCTAssertEqual(searchEditor.string, "ñ")
        XCTAssertEqual(model.tabs.map(\.id), original)
    }

}
