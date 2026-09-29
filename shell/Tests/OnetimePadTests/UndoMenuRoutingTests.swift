import AppKit
import CompanionKit
import XCTest

@testable import OnetimePad

@MainActor
final class UndoMenuRoutingTests: XCTestCase {
    func testUndoAndRedoBecomeNilTargetedResponderCommands() throws {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let oldTarget = NSObject()
        let undo = NSMenuItem(title: "Undo", action: nil, keyEquivalent: "z")
        undo.target = oldTarget
        undo.isEnabled = false
        let redo = NSMenuItem(title: "Redo", action: nil, keyEquivalent: "Z")
        redo.target = oldTarget
        redo.isEnabled = false
        editMenu.addItem(undo)
        editMenu.addItem(redo)
        editMenu.autoenablesItems = false

        BackdropAppDelegate.routeUndoRedoThroughResponder(in: mainMenu)

        XCTAssertNil(undo.target)
        XCTAssertEqual(undo.action, #selector(EditStepResponder.undo(_:)))
        XCTAssertTrue(undo.isEnabled)
        XCTAssertNil(redo.target)
        XCTAssertEqual(redo.action, #selector(EditStepResponder.redo(_:)))
        XCTAssertTrue(redo.isEnabled)
        XCTAssertTrue(editMenu.autoenablesItems)
    }

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
