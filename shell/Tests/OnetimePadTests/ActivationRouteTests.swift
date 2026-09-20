import CompanionKit
import XCTest

@testable import OnetimePad

/// The routing table (`ActivationRouter.decide`) as a pure decision
/// pinned across every reason × world-state combination B4 files
/// (issue #200, ADR-0033). Nothing here builds a model or a window:
/// the routing function reads a plain fact struct and returns a plain
/// route, and this file is where the "route by how the person arrived,
/// never by last use" rule lives as an assertion.
///
/// The naming mirrors `LaunchStanceTests`: one function per row of the
/// table, one XCTAssert per fact, so a failure names the row.
final class ActivationRouteTests: XCTestCase {
    // MARK: The activation reasons — launch, late, reopen

    private static func editorRoute(_ raise: BackdropRaise) -> ActivationRoute {
        .openEditorWindow(raise)
    }

    private func base(
        ambientPanelEnabled: Bool = true,
        owner: PresentationOwner = .panel,
        claimedByAnotherWindow: Bool = false
    ) -> ActivationContext {
        ActivationContext(
            ambientPanelEnabled: ambientPanelEnabled,
            owner: owner,
            claimedByAnotherWindow: claimedByAnotherWindow
        )
    }

    func testLaunchActivationSelectsEditorWindowWithSummon() {
        // A person's launch is coming to the pad, not back to a
        // sentence, so the roll anchors on today (`.summon`). The panel
        // preference does not change the route.
        for enabled in [false, true] {
            XCTAssertEqual(
                ActivationRouter.decide(
                    .launchActivation,
                    in: base(ambientPanelEnabled: enabled)
                ),
                Self.editorRoute(.summon)
            )
        }
    }

    func testLateActivationSelectsEditorWindowAsAnActivation() {
        // ⌘Tab or a Dock click on an inactive app; the roll stays
        // where the person left it. The panel preference does not
        // change the route.
        for enabled in [false, true] {
            XCTAssertEqual(
                ActivationRouter.decide(
                    .lateActivation,
                    in: base(ambientPanelEnabled: enabled)
                ),
                Self.editorRoute(.activation)
            )
        }
    }

    func testReopenSelectsEditorWindowAsAnActivation() {
        // Reopen (Dock click while frontmost, `open -a`): same as
        // late activation. The distinction is the callback, kept so
        // the delegate can route each one without a synthetic
        // classifier. The panel preference does not change the route.
        for enabled in [false, true] {
            XCTAssertEqual(
                ActivationRouter.decide(
                    .reopen,
                    in: base(ambientPanelEnabled: enabled)
                ),
                Self.editorRoute(.activation)
            )
        }
    }

    // MARK: About and Settings keep their claim

    func testActivationsClaimedByAnotherWindowNoop() {
        // About and Settings activate the app for themselves. Every
        // activation reason honours their claim; every summon does
        // not, because a hotkey inside an About sheet is still a
        // summon.
        for reason in [
            ActivationReason.launchActivation,
            .lateActivation,
            .reopen,
        ] {
            XCTAssertEqual(
                ActivationRouter.decide(
                    reason,
                    in: base(claimedByAnotherWindow: true)
                ),
                .noop
            )
        }
    }

    // MARK: Modal return and cancelled quit — back to the owner

    func testModalReturnRoutesToTheOwner() {
        XCTAssertEqual(
            ActivationRouter.decide(.modalReturn, in: base(owner: .panel)),
            .raisePanel(.activation)
        )
        XCTAssertEqual(
            ActivationRouter.decide(
                .modalReturn,
                in: base(owner: .editorWindow)
            ),
            .openEditorWindow(.activation)
        )
    }

    func testCancelledQuitRoutesToTheOwner() {
        // The cancelled quit line is under the page, and the page is
        // in the window that owns it (ADR-0033).
        XCTAssertEqual(
            ActivationRouter.decide(.cancelledQuit, in: base(owner: .panel)),
            .raisePanel(.activation)
        )
        XCTAssertEqual(
            ActivationRouter.decide(
                .cancelledQuit,
                in: base(owner: .editorWindow)
            ),
            .openEditorWindow(.activation)
        )
    }

    // MARK: Summons — hotkey, status item, card click

    func testHotkeySummonsThePanelWithTheAmbientPanelOn() {
        XCTAssertEqual(
            ActivationRouter.decide(.hotkey, in: base()),
            .summonPanel
        )
    }

    func testStatusItemSummonsThePanelWithTheAmbientPanelOn() {
        XCTAssertEqual(
            ActivationRouter.decide(.statusItem, in: base()),
            .summonPanel
        )
    }

    func testCardClickSummonsThePanel() {
        // The card is the resting panel, so a click on it is a
        // summon whatever the world says elsewhere.
        XCTAssertEqual(
            ActivationRouter.decide(.cardClick, in: base()),
            .summonPanel
        )
    }

    func testHotkeySelectsTheEditorWindowWithTheAmbientPanelOff() {
        // ADR-0033: with the panel off, the hotkey and the status
        // item pick the editor window instead.
        XCTAssertEqual(
            ActivationRouter.decide(
                .hotkey,
                in: base(ambientPanelEnabled: false)
            ),
            .openEditorWindow(.activation)
        )
    }

    func testStatusItemSelectsTheEditorWindowWithTheAmbientPanelOff() {
        XCTAssertEqual(
            ActivationRouter.decide(
                .statusItem,
                in: base(ambientPanelEnabled: false)
            ),
            .openEditorWindow(.activation)
        )
    }

    // MARK: The launch/late classifier

    func testActivationReasonClassifiesByRecency() {
        XCTAssertEqual(
            ActivationRouter.activationReason(sinceLaunch: 0, launchWindow: 2),
            .launchActivation
        )
        XCTAssertEqual(
            ActivationRouter.activationReason(sinceLaunch: 1.99, launchWindow: 2),
            .launchActivation
        )
        XCTAssertEqual(
            ActivationRouter.activationReason(sinceLaunch: 2, launchWindow: 2),
            .lateActivation
        )
        XCTAssertEqual(
            ActivationRouter.activationReason(sinceLaunch: 3_600, launchWindow: 2),
            .lateActivation
        )
    }

}
