import XCTest

@testable import OnetimePad

/// The primary editor window's decisions, tested as pure functions.
///
/// Scope: the ordinary activating `NSWindow` role ADR-0033 gives the
/// editor. The window's macOS-native invariants (normal level, ordinary
/// Space membership, AppKit-owned full screen, key and main status,
/// participation in ⌘Tab, Window menu, Mission Control, Stage Manager)
/// are AppKit defaults on a plain `NSWindow` and are not restated here;
/// the hardware procedure covers what only a person at the machine can
/// judge. The ambient panel's stance-driven behaviour lives in
/// `BackdropStanceTests`; the outside press rule that applies only to
/// the panel lives in `OutsidePressTests`.
final class PrimaryEditorWindowControllerTests: XCTestCase {
    private func handsBack(
        active: Bool = true,
        panelHoldsKeys: Bool = false,
        anotherVisibleKeyCapableWindow: Bool = false
    ) -> Bool {
        PrimaryEditorWindowController.closeHandsBackActivation(
            appActive: active,
            panelHoldsKeys: panelHoldsKeys,
            anotherVisibleKeyCapableWindow: anotherVisibleKeyCapableWindow
        )
    }

    func testCloseKeepsActivationForAnotherVisibleKeyCapableWindow() {
        XCTAssertFalse(handsBack(anotherVisibleKeyCapableWindow: true))
    }

    func testClosingTheLastAuxiliaryWindowReevaluatesTheActivation() {
        XCTAssertFalse(handsBack(anotherVisibleKeyCapableWindow: true))
        XCTAssertTrue(handsBack(anotherVisibleKeyCapableWindow: false))
    }

    func testCloseHandsBackActivationWhenNoWindowCanTakeKeys() {
        XCTAssertTrue(handsBack())
    }

    func testCloseKeepsActivationWhileThePanelHoldsKeys() {
        XCTAssertFalse(handsBack(panelHoldsKeys: true))
    }

    func testCloseCannotHandBackAnInactiveAppsActivation() {
        XCTAssertFalse(handsBack(active: false))
    }
}
