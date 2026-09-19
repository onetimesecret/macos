import XCTest

@testable import CompanionKit

/// The owner resolver as the pure decision ADR-0033 states: whether the
/// panel is raised and whether the editor window is open go in, and the
/// one window that owns the live page content comes out. The matrix is
/// written out row by row rather than looped, as the altitude suite's
/// is, because a hand run hardware check reads down a table more easily
/// than it reads a nested loop and because a regression that touches
/// one row is easier to fault when the row is named.
///
/// Nothing here builds a model, a view or a window. The function has no
/// key status among its inputs, which is how it keeps the promise that
/// the keyboard passing to Settings, About or a modal panel moves
/// nothing. That promise is tested where key status and the owner meet,
/// in the form factor's model, since a case here could only call one
/// pure function twice with the same arguments.
final class PageOwnershipTests: XCTestCase {

    // MARK: The rule as shipped

    func testRestingPanelWithEditorWindowClosedIsPanel() {
        // Today's app before anyone opens the editor window: the card
        // rests on the desktop and is the only content window there is.
        // The answer is the panel even when nothing is mounted, because
        // the resolver is total and never names a closed window.
        XCTAssertEqual(
            PresentationOwner.resolve(panelRaised: false, editorWindowOpen: false),
            .panel
        )
    }

    func testRaisedPanelWithEditorWindowClosedIsPanel() {
        XCTAssertEqual(
            PresentationOwner.resolve(panelRaised: true, editorWindowOpen: false),
            .panel
        )
    }

    func testRestingPanelWithEditorWindowOpenIsEditorWindow() {
        // The one row the editor window wins under the shipped rule. It
        // is also where ownership returns when a raised panel rests
        // beside an open editor window.
        XCTAssertEqual(
            PresentationOwner.resolve(panelRaised: false, editorWindowOpen: true),
            .editorWindow
        )
    }

    func testRaisedPanelWithEditorWindowOpenIsPanel() {
        // A summon is the person asking to type into the card, so the
        // raised panel takes ownership from an open editor window, and
        // the editor window shows a glance until the panel rests.
        XCTAssertEqual(
            PresentationOwner.resolve(panelRaised: true, editorWindowOpen: true),
            .panel
        )
    }

    // MARK: The never grant policy

    func testPolicyRestingPanelWithEditorWindowClosedIsEditorWindow() {
        // Never grant means never. With the editor window closed the
        // answer names a window with nothing mounted in it, so nothing
        // is mounted anywhere and the panel is a glance, which is what
        // a read only panel is. Were these two rows the panel's, a
        // person under the policy could edit in the card by closing the
        // editor window first.
        XCTAssertEqual(
            PresentationOwner.resolve(
                panelRaised: false, editorWindowOpen: false, panelMayOwn: false
            ),
            .editorWindow
        )
    }

    func testPolicyRaisedPanelWithEditorWindowClosedIsEditorWindow() {
        XCTAssertEqual(
            PresentationOwner.resolve(
                panelRaised: true, editorWindowOpen: false, panelMayOwn: false
            ),
            .editorWindow
        )
    }

    func testPolicyRestingPanelWithEditorWindowOpenIsEditorWindow() {
        XCTAssertEqual(
            PresentationOwner.resolve(
                panelRaised: false, editorWindowOpen: true, panelMayOwn: false
            ),
            .editorWindow
        )
    }

    func testPolicyRaisedPanelWithEditorWindowOpenIsEditorWindow() {
        // The row the switch exists for: a summon raises the panel, and
        // the editor window keeps the live page content anyway. A read
        // only panel is one answer in every row and not a second
        // architecture.
        XCTAssertEqual(
            PresentationOwner.resolve(
                panelRaised: true, editorWindowOpen: true, panelMayOwn: false
            ),
            .editorWindow
        )
    }

    // MARK: The default

    func testTheDefaultPolicyLetsThePanelOwn() {
        // No caller passes the switch today, so the default is the
        // shipped behaviour. Pinning it here means turning the policy
        // on has to be a deliberate edit at a call site.
        for panelRaised in [false, true] {
            for editorWindowOpen in [false, true] {
                XCTAssertEqual(
                    PresentationOwner.resolve(
                        panelRaised: panelRaised, editorWindowOpen: editorWindowOpen
                    ),
                    PresentationOwner.resolve(
                        panelRaised: panelRaised,
                        editorWindowOpen: editorWindowOpen,
                        panelMayOwn: true
                    )
                )
            }
        }
    }
}
