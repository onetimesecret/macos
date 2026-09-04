import XCTest

@testable import CompanionKit

/// What a conceal becomes on the wire, driven against the live core
/// through a stubbed transport (`stubWireForTests`). The Rust side
/// already pins the seam's own default and the mock transport's
/// reading of a named value; what only this suite can say is that the
/// value the shell sends is the value the wire carries, with nil
/// meaning the seam's default and a draft's figure arriving unchanged.
///
/// Every stub here answers with an outage rather than a link, on
/// purpose: a successful conceal writes the link to the real
/// clipboard core-side, and the request is on record before any
/// answer, so the outage costs the assertion nothing and the
/// developer's clipboard is left alone.
@MainActor
final class ConcealWireTests: XCTestCase {
    // PAT-shaped, assembled at runtime so the raw pattern never appears
    // in the repository text (the secret-scan CI job reads history).
    private let secret = "ghp_" + String(repeating: "n0ts3cr3t", count: 4)

    private func makeModel() throws -> PageModel {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-wire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suiteName = "companion-wire-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }
        return PageModel(
            formFactor: .panel,
            defaults: defaults,
            seams: .init(
                stateDirectory: tempDir,
                client: .ephemeral(tag: "wire-\(UUID().uuidString)"),
                saveDebounce: 0.05
            )
        )
    }

    /// Spin the main run loop until `done` holds or `timeout` passes.
    private func spinRunLoop(
        until done: () -> Bool, timeout: TimeInterval = 5
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// A client sending nil names no TTL, and the seam fills in the
    /// link's own seven days (ADR-0011 section 5): the shell never
    /// sends nil in practice, so this is the contract's floor rather
    /// than a path the app walks. Guest route, no token, and the
    /// record carries nothing of the payload.
    func testANilTtlLeavesAsTheSevenDayDefault() throws {
        let client = CompanionClient.ephemeral(tag: "wire-nil-\(UUID().uuidString)")
        XCTAssertNil(client.lastWireForTests(), "no stub, no record")
        XCTAssertTrue(client.configureConnection(
            serverUrl: "https://eu.onetimesecret.com", shareDomain: "", extid: "", token: nil
        ))
        XCTAssertNotEqual(client.newTab(), 0)
        let sheetID = try XCTUnwrap(client.tabs().first?.pageID)
        let chip = try XCTUnwrap(client.sealText(sheet: sheetID, secret, at: 0, length: 0))
        XCTAssertTrue(client.stubWireForTests(status: 0))
        XCTAssertNil(client.lastWireForTests(), "nothing sent yet")

        let outcome = client.concealChip(id: chip.chipId, ttlSecs: nil, passphrase: "", recipient: "")
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(try XCTUnwrap(outcome.error).contains("could not reach the server"))

        let record = try XCTUnwrap(client.lastWireForTests())
        XCTAssertEqual(record.method, "POST")
        XCTAssertTrue(record.url.hasSuffix("/api/v3/guest/secret/conceal"), record.url)
        XCTAssertFalse(record.authorized)
        XCTAssertEqual(record.ttl, 604_800, "the seam's own seven days")
        XCTAssertEqual(record.shareDomain, "eu.onetimesecret.com")
        XCTAssertFalse(record.hasPassphrase)
        XCTAssertNil(record.recipient)
        XCTAssertFalse(record.url.contains("n0ts3cr3t"))
    }

    /// The figure on a draft is the figure on the wire. The draft is
    /// walked off its default first, so a seam that quietly restored
    /// the default, or snapped the value down a ladder, would read
    /// differently from one that passed it through. The passphrase
    /// arrives as the fact of one and never as its text.
    func testADraftsTtlReachesTheWireUnchanged() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        XCTAssertTrue(model.coreClient.configureConnection(
            serverUrl: "https://eu.onetimesecret.com", shareDomain: "", extid: "", token: nil
        ))
        XCTAssertTrue(model.coreClient.syncDocument(sheet: page, json: #"[{"ink": "the credentials"}]"#))
        XCTAssertTrue(model.coreClient.stubWireForTests(status: 0))

        model.beginConceal(.page(page))
        XCTAssertEqual(model.concealDraft?.ttlSecs, ConcealDraft.defaultTtlSecs)
        model.concealDraft?.ttlSecs = 86_400
        model.concealDraft?.passphrase = "swordfish"
        model.confirmConceal()
        XCTAssertEqual(model.concealDraft?.inFlight, true)
        spinRunLoop { model.concealDraft?.inFlight == false }

        let draft = try XCTUnwrap(model.concealDraft)
        XCTAssertFalse(draft.inFlight, "the round trip came back")
        XCTAssertNil(draft.receiptId, "an outage leaves no receipt")
        XCTAssertNotNil(draft.error, "and the failure is inline, with retry")
        XCTAssertEqual(draft.ttlSecs, 86_400, "the draft keeps its figure for the retry")

        let record = try XCTUnwrap(model.coreClient.lastWireForTests())
        XCTAssertEqual(record.ttl, 86_400, "the draft's figure, not the default and not a rung")
        XCTAssertTrue(record.hasPassphrase)
        XCTAssertTrue(record.url.hasSuffix("/api/v3/guest/secret/conceal"), record.url)
        XCTAssertNil(record.recipient)
    }
}
