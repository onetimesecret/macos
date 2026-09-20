import XCTest

@testable import OnetimePad

/// The outside click rule's verdict, tested as the pure decision it is
/// (issue #41, dogfood phase 4). The two facts it weighs are read by the
/// controller: whether a menu of ours owned the press, from the
/// intervals `MenuTracking` keeps, and whether a modal of ours is up,
/// from the AppKit fact `ModalSession` reads. That the window server
/// reports a click in the out of process open panel to a global monitor
/// at all is hardware knowledge and stays in the manual matrix.
///
/// Scope after ADR-0033: this rule governs the ambient panel only. The
/// primary editor window is an ordinary activating `NSWindow` and lets
/// AppKit decide when key status resigns; nothing here reads from it.
final class OutsidePressTests: XCTestCase {
    func testAPlainOutsidePressRestsTheSurface() {
        XCTAssertTrue(OutsidePress.rests(claimedByMenu: false, modalSessionRunning: false))
    }

    func testAPressAMenuOwnsDoesNotRest() {
        // Edit then Find, from the menu bar: the older exception, kept.
        XCTAssertFalse(OutsidePress.rests(claimedByMenu: true, modalSessionRunning: false))
    }

    func testAPressWhileTheOpenPanelIsUpDoesNotRest() {
        // A folder, Cancel, or Open itself, clicked in the panel the
        // system drew in another process: resting here is what took the
        // pad away at the moment the person chose their file.
        XCTAssertFalse(OutsidePress.rests(claimedByMenu: false, modalSessionRunning: true))
    }

    func testBothExceptionsAtOnceStillDoNotRest() {
        // A context menu raised over a panel is not a thing the app
        // does, but the rule is a conjunction and should say so.
        XCTAssertFalse(OutsidePress.rests(claimedByMenu: true, modalSessionRunning: true))
    }
}
