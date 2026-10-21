import AppKit
import XCTest

@testable import OnetimePad

/// The File menu's Close Window item dims on this fact (issue #201): no
/// key window, or a borderless one, and `performClose:` has nothing to
/// act on. The windows here are never ordered on screen.
@MainActor
final class KeyWindowCloseabilityTests: XCTestCase {
    private func window(styleMask: NSWindow.StyleMask) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: styleMask, backing: .buffered, defer: false)
    }

    func testNoKeyWindowCannotClose() {
        XCTAssertFalse(KeyWindowCloseability.canClose(nil))
    }

    func testABorderlessWindowCannotClose() {
        XCTAssertFalse(KeyWindowCloseability.canClose(window(styleMask: [.borderless])))
    }

    func testATitledWindowWithACloseBoxCan() {
        XCTAssertTrue(KeyWindowCloseability.canClose(window(styleMask: [.titled, .closable])))
        XCTAssertFalse(KeyWindowCloseability.canClose(window(styleMask: [.titled])))
    }

    func testTheFactPublishesOnlyWhenItChanges() {
        let fact = KeyWindowCloseability()
        var changes = 0
        let sink = fact.$canClose.dropFirst().sink { _ in changes += 1 }
        defer { sink.cancel() }
        fact.stand(true)
        fact.stand(true)
        fact.stand(false)
        XCTAssertEqual(changes, 2)
    }
}
