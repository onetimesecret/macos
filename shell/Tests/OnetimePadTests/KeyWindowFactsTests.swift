import AppKit
import CompanionKit
import XCTest

@testable import OnetimePad

/// The two key window facts the ⌘W and ⇧⌘W items read (issue #201).
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

    func testTheCloseTargetFollowsTheKeyWindow() {
        let editor = window(styleMask: [.titled, .closable])
        let companion = window(styleMask: [.titled, .closable])
        let other = window(styleMask: [.titled, .closable])
        let facts = KeyWindowFacts(isOwnerWindow: { $0 === editor }, isCompanionWindow: { $0 === companion })

        facts.stand(editor)
        XCTAssertEqual(facts.closeTarget, .surface)
        XCTAssertTrue(facts.canClose)

        facts.stand(companion)
        XCTAssertEqual(facts.closeTarget, .companionWindow)
        XCTAssertTrue(facts.canClose)

        facts.stand(other)
        XCTAssertEqual(facts.closeTarget, .nothing, "a window of neither kind closes nothing")
    }

    /// Send Feedback's Export puts a save panel on it as a sheet, and the
    /// sheet is key: ⌘W closes neither the window behind it nor the surface.
    func testTheFeedbackExportSheetClosesNothing() {
        let feedback = window(styleMask: [.titled, .closable])
        let exportSheet = window(styleMask: [.titled])
        let facts = KeyWindowFacts(
            isOwnerWindow: { _ in false },
            isCompanionWindow: {
                BackdropAppDelegate.isCompanionWindow($0, settings: nil, feedback: feedback, about: nil)
            })
        feedback.beginSheet(exportSheet)
        defer { feedback.endSheet(exportSheet) }

        facts.stand(exportSheet)
        XCTAssertEqual(facts.closeTarget, .nothing)
        XCTAssertFalse(facts.canClose)

        facts.stand(feedback)
        XCTAssertEqual(facts.closeTarget, .companionWindow)
        XCTAssertFalse(facts.canClose, "the window behind the sheet cannot close yet")
    }

    func testNoKeyWindowClosesNothing() {
        let editor = window(styleMask: [.titled, .closable])
        let facts = KeyWindowFacts(isOwnerWindow: { $0 === editor }, isCompanionWindow: { _ in true })
        facts.stand(editor)
        facts.stand(nil)
        XCTAssertEqual(facts.closeTarget, .nothing)
        XCTAssertFalse(facts.canClose)
    }

    /// About is keyed before `showAbout` records it, so the first read
    /// says nothing; the refresh after the record recovers the companion.
    func testARefreshAfterALateRecordRecoversTheCompanionTarget() {
        let about = window(styleMask: [.titled, .closable])
        var known: NSWindow?
        let facts = KeyWindowFacts(
            keyWindow: { about }, isOwnerWindow: { _ in false }, isCompanionWindow: { $0 === known })

        facts.stand(about)
        XCTAssertEqual(facts.closeTarget, .nothing)

        known = about
        facts.refresh()
        XCTAssertEqual(facts.closeTarget, .companionWindow)
        XCTAssertTrue(facts.canClose)
    }

    func testTheFactsPublishOnlyWhenTheyChange() {
        let companion = window(styleMask: [.titled, .closable])
        let facts = KeyWindowFacts(isOwnerWindow: { _ in false }, isCompanionWindow: { $0 === companion })
        var changes = 0
        let sink = facts.$closeTarget.dropFirst().sink { _ in changes += 1 }
        defer { sink.cancel() }
        facts.stand(companion)
        facts.stand(companion)
        facts.stand(nil)
        XCTAssertEqual(changes, 2)
    }
}
