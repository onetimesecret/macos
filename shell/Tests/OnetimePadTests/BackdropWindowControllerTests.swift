import AppKit
import XCTest

@testable import OnetimePad

/// The two branch decisions the controller makes at the seams
/// AppKit hands it back, tested as pure choices on the same resolver
/// the controller reads: `BackdropAltitude.resolve`. The window
/// plumbing that carries those choices (the delegate turns, the
/// reconcile task) is hand-tested per the project's rules; what has
/// to hold in unit tests is the answer the decision returns for the
/// inputs the branch sees.
final class BackdropWindowControllerTests: XCTestCase {

    /// The resign-key delegate fires synchronously from inside
    /// `apply(.resting)` (the surface hands its keys back mid-rest),
    /// and reading `model.stance` from there catches the transition
    /// halfway. The controller reads `lastAppliedStance` instead,
    /// which the `apply(_:)` step stamps as it commits to the
    /// transition, so the altitude the resolver returns is the resting
    /// altitude for an unpinned rest — desktop, not the raised-normal
    /// figure a mid-transition read would produce.
    func testResignKeyDuringRestReadsLastAppliedStance() {
        // The controller stamps `lastAppliedStance = .resting` at the
        // top of `apply(.resting)`, before the ordering fires the
        // delegate turn. This is the input the delegate reads.
        let lastAppliedStance: BackdropStance = .resting
        let altitude = BackdropAltitude.resolve(
            stance: lastAppliedStance,
            keyed: false,
            pinned: false,
            keepsAbove: false
        )
        XCTAssertEqual(altitude, .desktop)
    }

    /// A pinned resign during a rest still floats: the pin is the
    /// standing promise to keep the card above other apps, and the
    /// resolver honours it whatever else is asked.
    func testResignKeyDuringRestUnderThePinStaysFloating() {
        let altitude = BackdropAltitude.resolve(
            stance: .resting,
            keyed: false,
            pinned: true,
            keepsAbove: false
        )
        XCTAssertEqual(altitude, .floating)
    }

    /// `makeKeyAndOrderFront` can be refused (an application-modal
    /// panel already holds key, for instance), and a refused raise
    /// leaves the panel at the raised-keyed altitude with no
    /// resign-key event to drop it. The controller's one-turn
    /// reconcile reads the honest keyless input against
    /// `lastAppliedStance = .raised`, and the resolver returns the
    /// normal altitude for an unpinned card with the preference off,
    /// which is what the reconcile writes to the panel.
    func testReconcileAfterRefusedRaise() {
        // The controller stamps `lastAppliedStance = .raised` in
        // `apply(.raised)` before the makeKeyAndOrderFront call. The
        // reconcile runs one main-actor turn later and reads
        // `panel.isKeyWindow` (false, because the raise was refused);
        // that is the keyed input to the resolver.
        let lastAppliedStance: BackdropStance = .raised
        let altitude = BackdropAltitude.resolve(
            stance: lastAppliedStance,
            keyed: false,
            pinned: false,
            keepsAbove: false
        )
        XCTAssertEqual(altitude, .normal)
    }

    /// The same refused raise, but with the keep-above preference on:
    /// the resolver lifts the keyless raised card back to floating,
    /// which is the preference's whole point.
    func testReconcileAfterRefusedRaiseHonoursKeepAbove() {
        let altitude = BackdropAltitude.resolve(
            stance: .raised,
            keyed: false,
            pinned: false,
            keepsAbove: true
        )
        XCTAssertEqual(altitude, .floating)
    }
}
