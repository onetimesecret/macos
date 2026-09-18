import XCTest

@testable import OnetimePad

/// AppKit hands back no reference to the standard About panel, so the
/// app picks it out of its windows by what it is. The rule is pure so
/// that each thing it must not match is an assertion: whatever it
/// returns is handed a Space behavior and a level follower.
final class AboutPanelLookupTests: XCTestCase {
    private func matches(
        visible: Bool = true, titled: Bool = true, title: String = "",
        isSheet: Bool = false, isSettings: Bool = false
    ) -> Bool {
        BackdropAppDelegate.looksLikeTheAboutPanel(
            visible: visible, titled: titled, title: title,
            isSheet: isSheet, isSettings: isSettings
        )
    }

    func testAVisibleTitledWindowWithNoTitleTextIsThePanel() {
        XCTAssertTrue(matches())
    }

    func testASheetIsNeverThePanel() {
        // A confirmation run on the Settings window is visible, titled
        // and carries no title text.
        XCTAssertFalse(matches(isSheet: true))
    }

    func testTheSettingsWindowIsNeverThePanel() {
        // Whatever its title reads at the time, the empty string
        // included.
        XCTAssertFalse(matches(isSettings: true))
        XCTAssertFalse(matches(title: "General", isSettings: true))
    }

    func testTheSurfaceAndAnythingHiddenOrNamedAreNotThePanel() {
        XCTAssertFalse(matches(titled: false), "the surface and its key relay are borderless")
        XCTAssertFalse(matches(visible: false))
        XCTAssertFalse(matches(title: "Settings"))
    }
}
