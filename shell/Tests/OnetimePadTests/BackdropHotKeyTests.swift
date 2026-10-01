import AppKit
import Carbon.HIToolbox
import XCTest

@testable import OnetimePad

final class BackdropHotKeyTests: XCTestCase {
    @MainActor
    func testConflictingRegistrationReportsStatusAndCanRetryAfterRelease() throws {
        _ = NSApplication.shared
        var firstFailure: BackdropHotKey.RegistrationFailure?
        var first = BackdropHotKey(
            keyCode: UInt32(kVK_F19),
            modifiers: UInt32(controlKey | optionKey | shiftKey),
            onFailure: { firstFailure = $0 }, action: {})
        guard first != nil else {
            throw XCTSkip("Test shortcut unavailable: \(String(describing: firstFailure))")
        }
        var conflict: BackdropHotKey.RegistrationFailure?
        let second = BackdropHotKey(
            keyCode: UInt32(kVK_F19),
            modifiers: UInt32(controlKey | optionKey | shiftKey),
            onFailure: { conflict = $0 }, action: {})
        XCTAssertNil(second)
        XCTAssertEqual(conflict?.stage, .shortcut)
        XCTAssertEqual(conflict?.status, OSStatus(eventHotKeyExistsErr))

        first = nil
        var retryFailure: BackdropHotKey.RegistrationFailure?
        let retry = BackdropHotKey(
            keyCode: UInt32(kVK_F19),
            modifiers: UInt32(controlKey | optionKey | shiftKey),
            onFailure: { retryFailure = $0 }, action: {})
        XCTAssertNotNil(retry)
        XCTAssertNil(retryFailure)
        withExtendedLifetime(retry) {}
    }
}
