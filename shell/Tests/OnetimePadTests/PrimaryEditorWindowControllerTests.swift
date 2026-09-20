import XCTest

@testable import OnetimePad

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
