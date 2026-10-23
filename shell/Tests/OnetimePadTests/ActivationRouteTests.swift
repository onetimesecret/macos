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

    func testOrdinaryActivationLeavesWindowOrderingToAppKit() {
        for enabled in [false, true] {
            for owner in [PresentationOwner.panel, .editorWindow] {
                XCTAssertEqual(ActivationRouter.routeForActivation(pendingSummon: nil,
                    context: base(ambientPanelEnabled: enabled, owner: owner)), .noop)
            }
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

    func testExplicitPresentationCommandsIgnoreCompanionClaims() {
        for claimed in [false, true] {
            XCTAssertEqual(ActivationRouter.decide(.openEditorPresentation,
                in: base(claimedByAnotherWindow: claimed)), .openEditorWindow(.activation))
            XCTAssertEqual(ActivationRouter.decide(.showAmbientPresentation,
                in: base(claimedByAnotherWindow: claimed)), .showAmbientPanel)
        }
        XCTAssertEqual(ActivationRouter.decide(.showAmbientPresentation,
            in: base(ambientPanelEnabled: false)), .noop)
    }

    func testOnlyDeliberatePanelRoutesCloseTheEditorBeforeRaising() {
        for route in [ActivationRoute.showAmbientPanel, .summonPanel,
                      .raisePanel(.activation), .raisePanel(.summon)] {
            var events: [String] = []
            BackdropAppDelegate.dispatch(route,
                openEditorWindow: { _ in XCTFail("unexpected editor route") },
                raisePanel: { _ in events.append("raise") },
                summonPanel: { events.append("summon") },
                closeEditorForPanel: { events.append("close") })
            switch route {
            case .showAmbientPanel: XCTAssertEqual(events, ["close", "raise"])
            case .summonPanel: XCTAssertEqual(events, ["close", "summon"])
            default: XCTAssertEqual(events, ["raise"])
            }
        }
    }

    // MARK: About and Settings keep their claim

    func testExplicitLaunchAndReopenRoutesDoNotReadAnUnusedCompanionFlag() {
        for claimed in [false, true] {
            let context = base(claimedByAnotherWindow: claimed)
            XCTAssertEqual(ActivationRouter.decide(.launchActivation, in: context), .openEditorWindow(.summon))
            XCTAssertEqual(ActivationRouter.decide(.reopen, in: context), .openEditorWindow(.activation))
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

    // MARK: App activation for editor summons

    func testInactiveEditorRoutesDeferUntilActivation() {
        for raise in [BackdropRaise.activation, .summon] {
            XCTAssertTrue(ActivationRouter.defersForActivation(
                route: .openEditorWindow(raise), appActive: false
            ))
            XCTAssertFalse(ActivationRouter.defersForActivation(
                route: .openEditorWindow(raise), appActive: true
            ))
        }
    }

    func testPanelRoutesAndNoopNeverDeferForActivation() {
        for route in [ActivationRoute.summonPanel, .showAmbientPanel, .raisePanel(.activation), .raisePanel(.summon), .noop] {
            for active in [false, true] {
                XCTAssertFalse(ActivationRouter.defersForActivation(route: route, appActive: active))
            }
        }
    }

    func testPendingExplicitSelectionsCompleteOnActivation() {
        for raise in [BackdropRaise.activation, .summon] {
            XCTAssertEqual(ActivationRouter.routeForActivation(
                pendingSummon: .openEditorWindow(raise), context: base()), .openEditorWindow(raise))
        }
    }

    func testAnotherWindowRequestCancelsPendingSelection() {
        XCTAssertEqual(ActivationRouter.routeForActivation(
            pendingSummon: .openEditorWindow(.activation),
            context: base(claimedByAnotherWindow: true)), .noop)
    }

    func testUnrequestedActivationNeverCreatesAnEditor() {
        for enabled in [false, true] {
            XCTAssertEqual(ActivationRouter.routeForActivation(
                pendingSummon: nil, context: base(ambientPanelEnabled: enabled)), .noop)
        }
    }
}
