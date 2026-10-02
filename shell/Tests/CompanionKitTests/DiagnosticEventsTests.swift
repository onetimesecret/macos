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

    func testStartedAtIsTheProcessStartNotTheFirstTouch() {
        let caseBegan = Date()
        let first = DiagnosticEvents()
        let second = DiagnosticEvents()
        // A trail made after this case began still dates itself earlier,
        // to when the runner was launched, and every trail agrees on it:
        // each reads the kernel's one record of the process start.
        XCTAssertLessThan(first.startedAt, caseBegan, "the process began before this case did")
        XCTAssertEqual(first.startedAt, second.startedAt)
        XCTAssertEqual(DiagnosticEvents.shared.startedAt, first.startedAt)

        // A weak floor, so a garbage read cannot pass as a long uptime:
        // no process began before the machine booted. The kernel's boot
        // time is read rather than derived from `systemUptime`, which
        // stops while the machine sleeps and so would put the boot later
        // than it was.
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        XCTAssertEqual(sysctlbyname("kern.boottime", &boot, &size, nil, 0), 0)
        let booted = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        XCTAssertGreaterThanOrEqual(first.startedAt, booted)
    }
}
