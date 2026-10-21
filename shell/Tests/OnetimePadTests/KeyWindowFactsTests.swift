import AppKit
import XCTest

@testable import OnetimePad

/// The two key window facts the File menu's ⌘W item reads (issue #201).
/// The windows here are never ordered on screen.
@MainActor
final class KeyWindowFactsTests: XCTestCase {
    private func window(styleMask: NSWindow.StyleMask) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: styleMask, backing: .buffered, defer: false)
    }

    func testNoKeyWindowCannotClose() {
        XCTAssertFalse(KeyWindowFacts.canClose(nil))
    }

    func testABorderlessWindowCannotClose() {
        XCTAssertFalse(KeyWindowFacts.canClose(window(styleMask: [.borderless])))
    }

    func testATitledWindowClosesOnlyWithACloseBox() {
        XCTAssertTrue(KeyWindowFacts.canClose(window(styleMask: [.titled, .closable])))
        XCTAssertFalse(KeyWindowFacts.canClose(window(styleMask: [.titled])))
    }

    func testADisabledCloseBoxCannotClose() throws {
        let window = window(styleMask: [.titled, .closable])
        try XCTUnwrap(window.standardWindowButton(.closeButton)).isEnabled = false
        XCTAssertFalse(KeyWindowFacts.canClose(window))
    }

    func testAWindowWithASheetCannotClose() {
        let window = window(styleMask: [.titled, .closable])
        let sheet = self.window(styleMask: [.titled])
        window.beginSheet(sheet)
        defer { window.endSheet(sheet) }
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertFalse(KeyWindowFacts.canClose(window))
    }

    func testTheCompanionFactFollowsTheKeyWindow() {
        let companion = window(styleMask: [.titled, .closable])
        let content = window(styleMask: [.titled, .closable])
        let facts = KeyWindowFacts { $0 === companion }

        facts.stand(companion)
        XCTAssertTrue(facts.companionIsKey)
        XCTAssertTrue(facts.canClose)

        facts.stand(content)
        XCTAssertFalse(facts.companionIsKey, "a content window that is key is not a companion")
        XCTAssertTrue(facts.canClose)

        facts.stand(nil)
        XCTAssertFalse(facts.companionIsKey)
        XCTAssertFalse(facts.canClose)
    }

    func testTheFactsPublishOnlyWhenTheyChange() {
        let companion = window(styleMask: [.titled, .closable])
        let facts = KeyWindowFacts { $0 === companion }
        var changes = 0
        let sink = facts.$companionIsKey.dropFirst().sink { _ in changes += 1 }
        defer { sink.cancel() }
        facts.stand(companion)
        facts.stand(companion)
        facts.stand(nil)
        XCTAssertEqual(changes, 2)
    }
}
