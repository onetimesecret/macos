import AppKit
import CompanionKit
import XCTest

@testable import OnetimePad

@MainActor
final class UndoMenuRoutingTests: XCTestCase {
    func testASettingsFieldKeepsItsNativeUndoManager() throws {
        let field = NSTextField(string: "")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = field
        XCTAssertTrue(window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(field.currentEditor())

        fieldEditor.insertText("edited")
        let undoManager = try XCTUnwrap(fieldEditor.undoManager)
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        XCTAssertEqual(field.stringValue, "")
        XCTAssertTrue(undoManager.canRedo)
    }
}
