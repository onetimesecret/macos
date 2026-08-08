import XCTest

@testable import CompanionKit

/// Who gets offered the screen-capture opt-out. The exclusion is the
/// surface's security posture, so the switch that lifts it is reachable
/// only where someone asked for it: every debug build, and a release
/// build only when it was launched with COMPANION_ALLOW_CAPTURE set.
/// The decision is pure so the release branch can be asserted here,
/// from a binary that is itself a debug build.
final class CaptureOptOutTests: XCTestCase {
    func testDebugBuildAlwaysOffersTheSwitch() {
        XCTAssertTrue(
            PageModel.offersCaptureOptOut(isDebugBuild: true, launchVariableSet: false)
        )
    }

    func testReleaseBuildWithTheVariableOffersTheSwitch() {
        // How the installed app is diagnosed: open --env
        // COMPANION_ALLOW_CAPTURE=1 /Applications/OnetimePad.app
        XCTAssertTrue(
            PageModel.offersCaptureOptOut(isDebugBuild: false, launchVariableSet: true)
        )
    }

    func testOrdinaryReleaseLaunchHasNoSwitch() {
        // The case the whole gate exists for: a user who double-clicks
        // the installed app is never shown a way to turn the exclusion
        // off, and the controller installs no observer that could.
        XCTAssertFalse(
            PageModel.offersCaptureOptOut(isDebugBuild: false, launchVariableSet: false)
        )
    }

    /// The opt-out is a security decision, so it fails closed: absent
    /// the launch variable, capture stays excluded no matter what the
    /// last session chose. Nothing writes it to defaults.
    @MainActor
    func testCaptureIsOffAtLaunchWithoutTheVariable() throws {
        try XCTSkipIf(
            PageModel.captureVariableSet,
            "this run was launched with COMPANION_ALLOW_CAPTURE set"
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "capture-opt-out-tests"))
        defer { UserDefaults.standard.removePersistentDomain(forName: "capture-opt-out-tests") }
        let model = PageModel(formFactor: .backdrop, defaults: defaults)
        XCTAssertFalse(model.allowCapture)
    }
}
