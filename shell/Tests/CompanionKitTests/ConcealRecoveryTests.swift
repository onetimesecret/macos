import AppKit
import SwiftUI
import XCTest

@testable import CompanionKit

private final class RecoveryClipboardProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let cleared: [XCTestExpectation]

    init(cleared: XCTestExpectation, again: XCTestExpectation? = nil) {
        self.cleared = [cleared] + [again].compactMap { $0 }
    }
    var callCount: Int { lock.withLock { count } }

    func record() {
        let next = lock.withLock {
            count += 1
            return cleared.indices.contains(count - 1) ? cleared[count - 1] : nil
        }
        next?.fulfill()
    }
}

@MainActor
final class ConcealRecoveryTests: XCTestCase {
    private func makeModel(
        recoveryDelay: TimeInterval? = nil,
        clipboardDelay: TimeInterval? = nil,
        clearProbe: RecoveryClipboardProbe? = nil
    ) throws -> PageModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conceal-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "conceal-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let client = CompanionClient.ephemeral(tag: suite)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = PageModel(
            formFactor: .panel, defaults: defaults,
            seams: .init(stateDirectory: directory, client: client, saveDebounce: 60,
                clipboardClearDebounce: clipboardDelay,
                concealLinkRecoveryDebounce: recoveryDelay,
                clearClipboardIfOurs: {
                    let cleared = client.clearClipboardIfOurs()
                    clearProbe?.record()
                    return cleared
                }))
        model.loadStateIfNeeded()
        model.newPage()
        return model
    }

    private func prepareLink(_ model: PageModel) throws -> (page: UInt64, draftID: UUID) {
        let page = try XCTUnwrap(model.selectedPageID)
        let client = model.coreClient
        XCTAssertTrue(client.syncDocument(sheet: page, json: #"[{"ink":"a test page"}]"#))
        XCTAssertTrue(client.configureConnection(
            serverUrl: "https://example.invalid", shareDomain: "", extid: "", token: nil))
        XCTAssertTrue(client.stubWireForTests(status: 200, body:
            #"{"record":{"receipt":{"identifier":"recovery-test"},"secret":{"identifier":"local-secret","key":"local-key"},"share_domain":null}}"#))
        model.beginConceal(.page(page))
        let draftID = try XCTUnwrap(model.concealDraft?.id)
        return (page, draftID)
    }

    private func completeLink(_ model: PageModel) throws -> UInt64 {
        let (page, draftID) = try prepareLink(model)
        let client = model.coreClient
        let outcome = client.concealSheet(id: page, ttlSecs: 3600, passphrase: "", recipient: "")
        XCTAssertTrue(outcome.ok)
        model.finishConceal(outcome, for: .page(page), draftID: draftID)
        return try XCTUnwrap(outcome.copyToken)
    }

    func testDraftIdentifiesTheSelectedObjectAndPage() throws {
        let model = try makeModel()
        let page = try XCTUnwrap(model.selectedPageID)
        let tab = try XCTUnwrap(model.selection)
        model.renameTab(tab, to: "Deployment")
        let chip = try XCTUnwrap(model.coreClient.sealText(sheet: page, "a test sealed value", at: 0, length: 0))
        XCTAssertTrue(model.coreClient.setChipName("API_TOKEN", chip: chip.chipId))
        model.refresh()
        model.beginConceal(.chip(chip.chipId))
        let label = try XCTUnwrap(model.concealDraft?.targetLabel)
        XCTAssertTrue(label.contains("API_TOKEN"))
        XCTAssertTrue(label.contains(chip.excerpt))
        model.beginConceal(.page(page))
        XCTAssertEqual(model.concealDraft?.targetLabel, "Deployment")
    }

    func testLinkCanBeCopiedAgainAndDismissalEndsRecovery() throws {
        let model = try makeModel()
        let token = try completeLink(model)
        XCTAssertEqual(model.concealDraft?.canCopyLink, true)
        XCTAssertTrue(model.copyConcealedLink())
        XCTAssertTrue(model.coreClient.canCopyConcealedLink(token: token))
        model.dismissConceal()
        XCTAssertFalse(model.coreClient.canCopyConcealedLink(token: token))
        XCTAssertFalse(model.copyConcealedLink())
    }

    func testClipboardClearingDoesNotEndLinkRecovery() throws {
        let cleared = expectation(description: "the clipboard timer fired")
        let probe = RecoveryClipboardProbe(cleared: cleared)
        let model = try makeModel(clipboardDelay: 0.01, clearProbe: probe)
        let token = try completeLink(model)
        wait(for: [cleared], timeout: 10)
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertEqual(model.concealDraft?.canCopyLink, true)
        XCTAssertTrue(model.coreClient.canCopyConcealedLink(token: token))
        XCTAssertEqual(CompanionClient.concealLinkRecoverySeconds(), 60)
    }

    func testCopyingTheLinkAgainRearmsClipboardClearing() throws {
        let first = expectation(description: "the initial link copy cleared")
        let second = expectation(description: "the copied-again link cleared")
        let probe = RecoveryClipboardProbe(cleared: first, again: second)
        let model = try makeModel(clipboardDelay: 0.01, clearProbe: probe)
        let token = try completeLink(model)
        let link = try XCTUnwrap(model.coreClient.memoryPasteboardTextForTests())
        XCTAssertEqual(URL(string: link)?.host, "example.invalid")
        wait(for: [first], timeout: 10)
        XCTAssertNil(model.coreClient.memoryPasteboardTextForTests())
        XCTAssertTrue(model.coreClient.canCopyConcealedLink(token: token))

        XCTAssertTrue(model.copyConcealedLink())
        XCTAssertEqual(model.coreClient.memoryPasteboardTextForTests(), link)
        wait(for: [second], timeout: 10)
        XCTAssertNil(model.coreClient.memoryPasteboardTextForTests())
        XCTAssertEqual(probe.callCount, 2)
        XCTAssertTrue(model.coreClient.canCopyConcealedLink(token: token))
    }

    func testModelTeardownForgetsRecoveryWhileItsClientRemainsAlive() throws {
        weak var released: PageModel?
        let session = try autoreleasepool { () throws -> (client: CompanionClient, token: UInt64) in
            let model = try makeModel()
            released = model
            let token = try completeLink(model)
            XCTAssertTrue(model.coreClient.canCopyConcealedLink(token: token))
            return (model.coreClient, token)
        }
        XCTAssertNil(released)
        XCTAssertFalse(session.client.canCopyConcealedLink(token: session.token))
        XCTAssertFalse(session.client.copyConcealedLink(token: session.token))
        XCTAssertNil(session.client.memoryPasteboardTextForTests())
    }

    func testInFlightCreationFinishesCleanupBeforeReleasingItsModel() throws {
        let cleared = expectation(description: "completed copy cleaned up during teardown")
        let probe = RecoveryClipboardProbe(cleared: cleared)
        var model: PageModel? = try makeModel(clipboardDelay: 60, clearProbe: probe)
        let client = try XCTUnwrap(model?.coreClient)
        weak var released = model
        _ = try prepareLink(try XCTUnwrap(model))
        model?.confirmConceal()
        model = nil
        XCTAssertNotNil(released)
        wait(for: [cleared], timeout: 10)
        XCTAssertNil(released)
        XCTAssertNil(client.memoryPasteboardTextForTests())
        XCTAssertEqual(probe.callCount, 1)
    }

    func testTheRecoveryTimerDisablesRecopyWithoutAClipboardAssertion() throws {
        let model = try makeModel(recoveryDelay: 0.01)
        let token = try completeLink(model)
        waitUntil(model.$concealDraft, description: "the recovery window ended") {
            $0?.canCopyLink == false
        }
        XCTAssertFalse(model.coreClient.canCopyConcealedLink(token: token))
        XCTAssertFalse(model.copyConcealedLink())
        XCTAssertEqual(ConcealView.successLine(canCopyLink: false), "link created; copying it again is no longer available.")
        XCTAssertFalse(ConcealView.successLine(canCopyLink: true).contains("is on the clipboard"))
    }

    func testRenderSharingPreviewsWhenRequested() throws {
        let directory = ProcessInfo.processInfo.environment["ONETIMEPAD_SEALED_PREVIEW_DIR"]
        try XCTSkipUnless(directory?.isEmpty == false, "Set ONETIMEPAD_SEALED_PREVIEW_DIR to render sharing fixtures.")
        let output = URL(fileURLWithPath: try XCTUnwrap(directory), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try makeModel()
        let page = try XCTUnwrap(model.selectedPageID)
        let chip = try XCTUnwrap(model.coreClient.sealText(
            sheet: page, "synthetic preview value", at: 0, length: 0))
        XCTAssertTrue(model.coreClient.setChipName("API_TOKEN", chip: chip.chipId))
        XCTAssertTrue(model.coreClient.configureConnection(
            serverUrl: "https://example.invalid", shareDomain: "", extid: "", token: nil))
        model.refresh()
        model.beginConceal(.chip(chip.chipId))
        let form = try XCTUnwrap(model.concealDraft)
        var success = form
        success.receiptId = "synthetic-preview"
        success.canCopyLink = true
        for (state, draft) in [("form", form), ("success", success)] {
            for (name, scheme, appearance) in [
                ("light", ColorScheme.light, NSAppearance.Name.aqua),
                ("dark", ColorScheme.dark, .darkAqua),
            ] {
                for width in [CGFloat(260), 600] {
                    let content = ConcealView(model: model, draft: draft)
                        .environment(\.colorScheme, scheme)
                        .padding(.vertical, 12)
                        .frame(width: width, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let host = NSHostingView(rootView: content)
                    host.appearance = NSAppearance(named: appearance)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = host.appearance
                    window.contentView = host
                    defer { window.close() }
                    host.frame = NSRect(x: 0, y: 0, width: width, height: ceil(host.fittingSize.height))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertLessThan(host.frame.height, 1_000)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.effectiveAppearance.performAsCurrentDrawingAppearance {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                    }
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: output.appendingPathComponent("sharing-\(state)-\(name)-\(Int(width))w.png"))
                }
            }
        }
    }

    func testSharingRecoveryLocalizationKeysResolve() {
        let expected = [
            "sharing.recovery.copy": "Copy Link Again",
            "sharing.recovery.done": "Done",
            "sharing.recovery.success": "link created and copied; copy it again below.",
            "sharing.recovery.unavailable": "link created; copying it again is no longer available.",
            "sharing.recovery.copy_failed": "this link is no longer available to copy again.",
            "sharing.recovery.delete_chip": "Delete Local Sealed Content",
            "sharing.recovery.discard_page": "Discard Local Page",
            "sharing.recovery.delete_chip.help": "delete this local sealed item; this cannot be undone",
            "sharing.recovery.discard_page.help": "discard this page's contents; keep its timeline position",
            "sharing.recovery.help": "available for up to %u seconds after creation",
            "sharing.recovery.target": "Sharing: %@",
        ]
        for (key, value) in expected {
            XCTAssertEqual(CompanionL10n.string(key), value, "unresolved or stale key: \(key)")
        }
        XCTAssertEqual(ConcealView.recoveryHelp, "available for up to 60 seconds after creation")
        XCTAssertEqual(ConcealView.sharingTargetLabel("API_TOKEN"), "Sharing: API_TOKEN")
    }

    func testDeletionLabelsDistinguishASealedItemFromAPagesContents() {
        XCTAssertEqual(ConcealView.deleteLabel(for: .chip(1)), "Delete Local Sealed Content")
        XCTAssertEqual(ConcealView.deleteLabel(for: .page(1)), "Discard Local Page")
        XCTAssertFalse(ConcealView.deleteHelp(for: .page(1)).contains("close"))
    }
}
