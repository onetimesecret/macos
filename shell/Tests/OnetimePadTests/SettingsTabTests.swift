import AppKit
import XCTest

@testable import OnetimePad

/// The Settings window's tabs, tested as the table they are. The window
/// itself is AppKit and is checked by hand; what can be checked here is
/// that the table would draw: General first, every label distinct, and
/// every symbol name one this SDK actually has, since a misspelt SF
/// Symbol renders as an empty toolbar item and reports nothing.
final class SettingsTabTests: XCTestCase {
    @MainActor
    func testNativeSettingsSceneRedirectsAndCanBeOpenedAgain() async {
        var opens = 0
        let view = SettingsSceneRedirectView { opens += 1 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(opens, 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isRestorable)
        // Reuse the host: a native request can key the same scene again.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(opens, 2)
        XCTAssertFalse(window.isVisible)
    }

    func testGeneralComesFirst() {
        XCTAssertEqual(SettingsTab.allCases.first, .general)
        XCTAssertEqual(SettingsTab.general.label, "General")
    }

    func testCodeFollowsGeneral() {
        XCTAssertEqual(Array(SettingsTab.allCases.prefix(2)), [.general, .code])
        XCTAssertEqual(SettingsTab.code.label, "Code")
    }

    func testEachTabHasItsOwnLabelAndIndex() {
        let labels = SettingsTab.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "two tabs sharing a label would be one tab twice")
        for (position, tab) in SettingsTab.allCases.enumerated() {
            XCTAssertEqual(tab.index, position, "\(tab) is declared at \(position) but indexes itself elsewhere")
        }
    }

    func testEverySymbolResolves() {
        for tab in SettingsTab.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil),
                "\(tab.label) names the symbol \(tab.symbolName), which this SDK does not have")
        }
    }

    /// The window keeps its last tab, except when the surface's banner
    /// has sent the user to clear a ledger that will not open: that
    /// button lives on General, so that is where the window lands.
    func testARefusedLedgerLandsOnGeneral() {
        XCTAssertEqual(SettingsTab.landing(current: .sync, ledgerRestoreRefused: true), .general)
        XCTAssertEqual(SettingsTab.landing(current: .connection, ledgerRestoreRefused: true), .general)
    }

    func testAnOrdinaryShowKeepsTheLastTab() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(SettingsTab.landing(current: tab, ledgerRestoreRefused: false), tab)
        }
    }
}
