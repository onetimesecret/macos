import XCTest
@testable import CompanionKit

final class DiagnosticEventsTests: XCTestCase {
    func testTrailDropsOldestEntriesAtCapacity() {
        let trail = DiagnosticEvents(capacity: 2)
        trail.record(.panelRaised)
        trail.record(.panelRested)
        trail.record(.shortcutFailed, status: -9878)
        XCTAssertEqual(trail.snapshot().map(\.kind), [.panelRested, .shortcutFailed])
        XCTAssertEqual(trail.snapshot().last?.status, -9878)
    }

    func testCoreMessagesBecomeFixedLabelsWithoutBackendText() {
        let trail = DiagnosticEvents()
        trail.recordCoreDiagnostic("companion-ffi: the state-key item would not load (secret-path/token)", isFault: true)
        trail.recordCoreDiagnostic("companion-credentials: the data protection keychain refused service user@example.com", isFault: false)
        trail.recordCoreDiagnostic("arbitrary backend error: note content /Users/person/file", isFault: true)
        trail.recordCoreDiagnostic("unrecognized notice containing private data", isFault: false)
        XCTAssertEqual(trail.snapshot().map(\.kind), [.stateKeyRefused, .keychainLoginFallback, .coreFault])
        XCTAssertTrue(trail.snapshot().allSatisfy { $0.status == nil })
    }
}
