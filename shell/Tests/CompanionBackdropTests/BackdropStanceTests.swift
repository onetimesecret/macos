import AppKit
import XCTest

@testable import CompanionBackdrop

/// The stance split, tested as the pure decision it is — the shell's
/// pattern for UI-adjacent logic: test the decision itself, never mock
/// AppKit. The window plumbing that applies it (ordering, key status,
/// the mouse pass-through) is hand-tested per the project's rules
/// (docs/spec/feature/background-surface, hardware checklist).
final class BackdropStanceTests: XCTestCase {
    // MARK: Resting — a passive pane behind everything

    func testRestingSitsAtTheWindowServersDesktopLevel() {
        XCTAssertEqual(
            BackdropStance.resting.level.rawValue,
            Int(CGWindowLevelForKey(.desktopWindow))
        )
    }

    func testRestingLetsClicksFallThroughToTheDesktop() {
        XCTAssertTrue(BackdropStance.resting.ignoresMouse)
    }

    func testRestingRefusesTheKeyboardOutright() {
        // A background surface that could silently receive keystrokes
        // would be a keylogger-shaped bug.
        XCTAssertFalse(BackdropStance.resting.acceptsKey)
    }

    func testRestingRepaintsCoarsely() {
        // Always on screen, so frugality lives in the cadence: one
        // repaint every 30 s at a glance, never a 1 Hz idle tick.
        XCTAssertEqual(BackdropStance.resting.tickInterval, 30)
    }

    // MARK: Raised — the panel model, borrowed for the moment of editing

    func testRaisedFloats() {
        XCTAssertEqual(BackdropStance.raised.level, .floating)
    }

    func testRaisedTakesTheMouse() {
        XCTAssertFalse(BackdropStance.raised.ignoresMouse)
    }

    func testRaisedMayTakeTheKeyboard() {
        XCTAssertTrue(BackdropStance.raised.acceptsKey)
    }

    func testRaisedEarnsTheOneHertzTick() {
        XCTAssertEqual(BackdropStance.raised.tickInterval, 1)
    }

    // MARK: The desktop level is genuinely below normal windows

    func testDesktopLevelSitsBelowNormalWindows() {
        XCTAssertLessThan(NSWindow.Level.backdropDesktop.rawValue, NSWindow.Level.normal.rawValue)
    }

    // MARK: The document mirror — ink runs on the wire

    func testEmptyInkMirrorsAnEmptyDocument() {
        XCTAssertEqual(BackdropCore.inkRunsJSON(""), "[]")
    }

    func testInkMirrorsAsASingleRun() throws {
        let json = try XCTUnwrap(BackdropCore.inkRunsJSON("meet at 4 — badge code inside"))
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]]
        )
        XCTAssertEqual(decoded, [["ink": "meet at 4 — badge code inside"]])
    }

    func testInkWithQuotesAndNewlinesSurvivesTheEncoding() throws {
        let ink = "line one\nline \"two\"\n\ttabbed"
        let json = try XCTUnwrap(BackdropCore.inkRunsJSON(ink))
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]]
        )
        XCTAssertEqual(decoded, [["ink": ink]])
    }
}
