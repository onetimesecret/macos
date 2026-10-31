import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class SealedUXIntegrationTests: XCTestCase {
    private let longName = "DEPLOY_" + String(repeating: "CREDENTIAL_", count: 5)

    private func makeModel() throws -> PageModel {
        let suite = "sealed-ux-integration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = CompanionClient.ephemeral(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { @MainActor in board.releaseGlobally() }
        return PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: client, saveDebounce: 3_600,
                         clearClipboardIfOurs: { false }, ambientPasteboard: board))
    }

    private func seed(_ text: String, in model: PageModel) throws -> UInt64 {
        let tab = model.coreClient.newTab()
        let page = try XCTUnwrap(model.coreClient.tabs().first { $0.id == tab }?.pageID)
        let data = try JSONSerialization.data(withJSONObject: [["ink": text]])
        XCTAssertTrue(model.coreClient.syncDocument(
            sheet: page, json: try XCTUnwrap(String(data: data, encoding: .utf8))))
        if model.pads.isEnabled {
            let uuid = try XCTUnwrap(model.coreClient.tabs().first { $0.id == tab }?.uuid)
            model.pads.assign(tabUUID: uuid, to: model.pads.activeID)
        }
        model.refresh()
        model.select(tab)
        return page
    }

    private func standalone(_ model: PageModel, page: UInt64) throws
        -> (editor: InkTextView, scroll: NSScrollView, coordinator: InkEditorView.Coordinator)
    {
        let coordinator = InkEditorView.Coordinator(model: model)
        let editor = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        InkEditorView.seat(editor, in: scroll)
        return (editor, scroll, coordinator)
    }

    private func measuredFrame(_ editor: InkTextView, at index: Int) throws -> NSRect {
        let manager = try XCTUnwrap(editor.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(editor.textContainer))
        return try XCTUnwrap(editor.chipFrame(at: index))
    }

    func testVariableNameChangesRemeasureTheExistingStandaloneAttachment() throws {
        let model = try makeModel()
        let page = try seed("ab SECRET cd", in: model)
        let chip = try XCTUnwrap(model.coreClient.sealText(sheet: page, "SECRET", at: 3, length: 6))
        let surface = try standalone(model, page: page)
        let cell = try XCTUnwrap(surface.editor.chipCell(at: 3))
        XCTAssertTrue(model.setChipName("KEY", chip: chip.chipId, sheet: page))
        let short = try measuredFrame(surface.editor, at: 3)
        XCTAssertEqual(short.width, SealedBlockLayout.minimumWidth)

        XCTAssertTrue(model.setChipName(longName, chip: chip.chipId, sheet: page))
        let expanded = try measuredFrame(surface.editor, at: 3)
        XCTAssertGreaterThan(expanded.width, short.width)
        XCTAssertEqual(cell.info.name, longName)
        XCTAssertTrue(surface.editor.chipCell(at: 3) === cell)

        XCTAssertTrue(model.setChipName("", chip: chip.chipId, sheet: page))
        XCTAssertEqual(try measuredFrame(surface.editor, at: 3).width, short.width)
        XCTAssertNil(cell.info.name)
        withExtendedLifetime(surface.scroll) {}
    }

    func testVariableNameChangesRemeasureStandaloneAndContinuousProjectionsTogether() throws {
        let model = try makeModel()
        let page = try seed("ab SECRET cd", in: model)
        let chip = try XCTUnwrap(model.coreClient.sealText(sheet: page, "SECRET", at: 3, length: 6))
        let standalone = try standalone(model, page: page)
        _ = try seed("Other checkpoint", in: model)
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = ContinuousPadView.makeSurface(model: model, coordinator: coordinator)
        let frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll)
        scroll.frame = frame
        scroll.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(scroll.documentView as? ContinuousPadCanvas)
        canvas.measure()
        defer {
            ContinuousPadView.dismantleNSView(scroll, coordinator: coordinator)
            window.close()
        }
        let segment = try XCTUnwrap(canvas.document.projection.segments.first { $0.page.id == page })
        let index = segment.bodyRange.location + 3
        let cell = try XCTUnwrap(canvas.editor.chipCell(at: index))
        let originalText = canvas.editor.string
        let shortContinuous = try measuredFrame(canvas.editor, at: index)
        let shortStandalone = try measuredFrame(standalone.editor, at: 3)

        XCTAssertTrue(model.setChipName(longName, chip: chip.chipId, sheet: page))
        XCTAssertGreaterThan(try measuredFrame(canvas.editor, at: index).width, shortContinuous.width)
        XCTAssertGreaterThan(try measuredFrame(standalone.editor, at: 3).width, shortStandalone.width)
        XCTAssertEqual(cell.info.name, longName)
        XCTAssertEqual(standalone.editor.chipCell(at: 3)?.info.name, longName)
        XCTAssertTrue(canvas.editor.chipCell(at: index) === cell)
        XCTAssertEqual(canvas.editor.string, originalText)

        XCTAssertTrue(model.coreClient.setChipName("KEY", chip: chip.chipId))
        model.restateChipFaces(onSheet: page)
        XCTAssertEqual(try measuredFrame(canvas.editor, at: index).width, shortContinuous.width)
        XCTAssertEqual(try measuredFrame(standalone.editor, at: 3).width, shortStandalone.width)
        XCTAssertEqual(cell.info.name, "KEY")
        withExtendedLifetime(standalone.scroll) {}
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in editor: InkTextView) throws -> NSEvent {
        let window = try XCTUnwrap(editor.window)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: editor.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func host(_ scroll: NSScrollView, editor: InkTextView) -> NSWindow {
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        editor.isEditable = true
        XCTAssertTrue(window.makeFirstResponder(editor))
        return window
    }

    func testCopyPressUsesTheSameObjectAfterTextShiftsItsIndex() throws {
        let model = try makeModel()
        let page = try seed("ab SECRET cd", in: model)
        let chip = try XCTUnwrap(model.coreClient.sealText(sheet: page, "SECRET", at: 3, length: 6))
        let surface = try standalone(model, page: page)
        let editor = surface.editor
        let window = host(surface.scroll, editor: editor)
        defer { editor.handlePressStarted = nil; window.close() }
        let original = try measuredFrame(editor, at: 3)
        let button = try XCTUnwrap(editor.chipCell(at: 3)?.copyRect(in: original))
        let down = try mouseEvent(.leftMouseDown, at: NSPoint(x: button.midX, y: button.midY), in: editor)
        let prefix = "Moved prefix\n"
        var hookError: Error?
        editor.handlePressStarted = {
            do {
                editor.insertText(prefix, replacementRange: NSRange(location: 0, length: 0))
                let current = try XCTUnwrap(editor.chipIndex(ofChip: chip.chipId))
                let moved = try self.measuredFrame(editor, at: current)
                let copy = try XCTUnwrap(editor.chipCell(at: current)?.copyRect(in: moved))
                window.postEvent(try self.mouseEvent(.leftMouseUp,
                    at: NSPoint(x: copy.midX, y: copy.midY), in: editor), atStart: true)
            } catch { hookError = error }
        }
        editor.mouseDown(with: down)
        XCTAssertNil(hookError)
        XCTAssertEqual(editor.chipIndex(ofChip: chip.chipId), 3 + prefix.utf16.count)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3 + prefix.utf16.count, length: 1))
        XCTAssertEqual(model.coreClient.ledger().filter { $0.event == "sent" }.count, 1)
        XCTAssertNotNil(editor.copyBeat)
    }

    func testRemovingAPressedObjectDoesNotCopyItsReplacement() throws {
        let model = try makeModel()
        let page = try seed("ab SECRET cd", in: model)
        let first = try XCTUnwrap(model.coreClient.sealText(sheet: page, "SECRET", at: 3, length: 6))
        let second = try XCTUnwrap(model.coreClient.sealText(sheet: page, "SECOND", at: 4, length: 0))
        let surface = try standalone(model, page: page)
        let editor = surface.editor
        let window = host(surface.scroll, editor: editor)
        defer { editor.handlePressStarted = nil; window.close() }
        let original = try measuredFrame(editor, at: 3)
        let button = try XCTUnwrap(editor.chipCell(at: 3)?.copyRect(in: original))
        let down = try mouseEvent(.leftMouseDown, at: NSPoint(x: button.midX, y: button.midY), in: editor)
        var hookError: Error?
        editor.handlePressStarted = {
            do {
                editor.insertText("", replacementRange: NSRange(location: 3, length: 1))
                let current = try XCTUnwrap(editor.chipIndex(ofChip: second.chipId))
                let moved = try self.measuredFrame(editor, at: current)
                let copy = try XCTUnwrap(editor.chipCell(at: current)?.copyRect(in: moved))
                window.postEvent(try self.mouseEvent(.leftMouseUp,
                    at: NSPoint(x: copy.midX, y: copy.midY), in: editor), atStart: true)
            } catch { hookError = error }
        }
        editor.mouseDown(with: down)
        XCTAssertNil(hookError)
        XCTAssertNil(editor.chipIndex(ofChip: first.chipId))
        XCTAssertEqual(editor.chipIndex(ofChip: second.chipId), 3)
        XCTAssertEqual(model.coreClient.ledger().filter { $0.event == "sent" }.count, 0)
        XCTAssertNil(editor.copyBeat)
    }

    func testReadOnlySurfaceRefusesCopyFromMouseAndAccessibility() throws {
        let model = try makeModel()
        let page = try seed("ab SECRET cd", in: model)
        _ = try XCTUnwrap(model.coreClient.sealText(sheet: page, "SECRET", at: 3, length: 6))
        let surface = try standalone(model, page: page)
        let editor = surface.editor
        let window = host(surface.scroll, editor: editor)
        defer { window.close() }
        let frame = try measuredFrame(editor, at: 3)
        let button = try XCTUnwrap(editor.chipCell(at: 3)?.copyRect(in: frame))
        editor.isEditable = false
        editor.handlesMayHaveMoved()
        let copy = try XCTUnwrap(editor.handleAccessibilityElements.first {
            $0.accessibilityLabel() == "Copy Decrypted Contents"
        })
        XCTAssertFalse(copy.isAccessibilityEnabled())
        XCTAssertFalse(copy.accessibilityPerformPress())
        XCTAssertFalse(surface.coordinator.copyOutChip(at: 3))
        let point = NSPoint(x: button.midX, y: button.midY)
        window.postEvent(try mouseEvent(.leftMouseUp, at: point, in: editor), atStart: true)
        editor.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: editor))
        XCTAssertEqual(model.coreClient.ledger().filter { $0.event == "sent" }.count, 0)
        XCTAssertNil(editor.copyBeat)
    }

}
