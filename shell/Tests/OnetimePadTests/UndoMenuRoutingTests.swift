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
        XCTAssertFalse(undo.isEnabled)
        XCTAssertNil(redo.target)
        XCTAssertEqual(redo.action, #selector(EditStepResponder.redo(_:)))
        XCTAssertFalse(redo.isEnabled)
        XCTAssertTrue(editMenu.autoenablesItems)
    }

    func testMenuRebuildAndTrackingKeepResponderRoutingAndCustomShortcuts() {
        let root = NSMenu()
        let edit = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        root.addItem(editItem)
        let center = NotificationCenter()
        let watch = UndoMenuRoutingWatch(mainMenu: { root }, center: center)
        let swiftUITarget = NSObject()

        let undo = NSMenuItem(title: "Undo", action: nil, keyEquivalent: "u")
        undo.keyEquivalentModifierMask = [.command, .option]
        undo.target = swiftUITarget
        edit.addItem(undo)
        center.post(name: NSMenu.didAddItemNotification, object: edit)
        XCTAssertNil(undo.target)
        XCTAssertEqual(undo.action, #selector(EditStepResponder.undo(_:)))
        XCTAssertEqual(undo.keyEquivalent, "u")
        XCTAssertEqual(undo.keyEquivalentModifierMask, [.command, .option])

        // A native validator can add an action name. Repair a later
        // SwiftUI retarget without depending on the original button title.
        undo.title = "Undo Typing"
        undo.target = swiftUITarget
        undo.isEnabled = false
        center.post(name: NSMenu.didChangeItemNotification, object: edit)
        XCTAssertNil(undo.target)
        XCTAssertFalse(undo.isEnabled)

        edit.removeAllItems()
        let redo = NSMenuItem(title: "Redo", action: nil, keyEquivalent: "")
        redo.target = swiftUITarget
        edit.addItem(redo)
        center.post(name: NSMenu.didBeginTrackingNotification, object: root)
        XCTAssertNil(redo.target)
        XCTAssertEqual(redo.action, #selector(EditStepResponder.redo(_:)))
        XCTAssertEqual(redo.keyEquivalent, "")
        withExtendedLifetime(watch) {}
    }

    func testUnrelatedMenusAreNotRetargeted() {
        let root = NSMenu()
        let center = NotificationCenter()
        let watch = UndoMenuRoutingWatch(mainMenu: { root }, center: center)
        let popup = NSMenu(title: "Edit")
        let undo = NSMenuItem(title: "Undo", action: nil, keyEquivalent: "z")
        let target = NSObject()
        undo.target = target
        popup.addItem(undo)
        center.post(name: NSMenu.didAddItemNotification, object: popup)
        XCTAssertTrue(undo.target === target)
        XCTAssertNil(undo.action)
        withExtendedLifetime(watch) {}
    }

    func testDefaultCenterRoutesReplacementItemsAutomatically() {
        let root = NSMenu()
        let edit = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        root.addItem(editItem)
        let watch = UndoMenuRoutingWatch(mainMenu: { root })
        let swiftUITarget = NSObject()
        let original = NSMenuItem(title: "Redo", action: nil, keyEquivalent: "Z")
        original.target = swiftUITarget
        edit.addItem(original)
        XCTAssertNil(original.target)
        XCTAssertEqual(original.action, #selector(EditStepResponder.redo(_:)))

        edit.removeItem(original)
        let replacement = NSMenuItem(title: "Redo", action: nil, keyEquivalent: "r")
        replacement.target = swiftUITarget
        edit.addItem(replacement)
        XCTAssertNil(replacement.target)
        XCTAssertEqual(replacement.action, #selector(EditStepResponder.redo(_:)))
        XCTAssertEqual(replacement.keyEquivalent, "r")

        replacement.target = swiftUITarget
        replacement.title = "Redo Typing"
        XCTAssertNil(replacement.target)
        XCTAssertEqual(replacement.title, "Redo Typing")
        replacement.isEnabled = false
        XCTAssertFalse(replacement.isEnabled)
        withExtendedLifetime(watch) {}
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
        let fieldEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let redo = NSMenuItem(
            title: "Redo", action: #selector(EditStepResponder.redo(_:)), keyEquivalent: "Z"
        )

        fieldEditor.insertText("edited")
        let undoManager = try XCTUnwrap(fieldEditor.undoManager)
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        XCTAssertEqual(field.stringValue, "")
        XCTAssertTrue(undoManager.canRedo)
        XCTAssertTrue(fieldEditor.validateMenuItem(redo))

        undoManager.redo()
        XCTAssertEqual(field.stringValue, "edited")
        XCTAssertFalse(undoManager.canRedo)
    }
}
