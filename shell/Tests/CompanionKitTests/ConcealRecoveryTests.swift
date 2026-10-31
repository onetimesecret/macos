import AppKit
import SwiftUI
import XCTest

@testable import CompanionKit

@MainActor
final class ConcealRecoveryTests: XCTestCase {
    private func makeModel(clearDelay: TimeInterval = 60) throws -> PageModel {
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
                clipboardClearDebounce: clearDelay))
        model.loadStateIfNeeded()
        model.newPage()
        return model
    }

    private func completeLink(_ model: PageModel) throws -> UInt64 {
        let page = try XCTUnwrap(model.selectedPageID)
        let client = model.coreClient
        XCTAssertTrue(client.syncDocument(sheet: page, json: #"[{"ink":"a test page"}]"#))
        XCTAssertTrue(client.configureConnection(
            serverUrl: "https://example.invalid", shareDomain: "", extid: "", token: nil))
        XCTAssertTrue(client.stubWireForTests(status: 200, body:
            #"{"record":{"receipt":{"identifier":"recovery-test"},"secret":{"identifier":"local-secret","key":"local-key"},"share_domain":null}}"#))
        model.beginConceal(.page(page))
        let draftID = try XCTUnwrap(model.concealDraft?.id)
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

    func testTheRecoveryTimerDisablesRecopyWithoutAClipboardAssertion() throws {
        let model = try makeModel(clearDelay: 0.01)
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
        guard let directory = ProcessInfo.processInfo.environment["ONETIMEPAD_SEALED_PREVIEW_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
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

    func testDeletionLabelsDistinguishASealedItemFromAPagesContents() {
        XCTAssertEqual(ConcealView.deleteLabel(for: .chip(1)), "Delete Local Sealed Content")
        XCTAssertEqual(ConcealView.deleteLabel(for: .page(1)), "Discard Local Page")
        XCTAssertFalse(ConcealView.deleteHelp(for: .page(1)).contains("close"))
    }
}
