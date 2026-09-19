import AppKit
import XCTest

@testable import CompanionKit

/// The presentation fields have one writer at a time, the owner, and a
/// write from the other window is declined (issue #198, ADR-0033).
///
/// The guard traps in a debug build, which is what a test process is,
/// so the refusal is watched through the seam that stands in for the
/// trap (`PageModel.Seams.declinedPresentationWrite`). The seam
/// replaces the trap and never the verdict: what these cases assert is
/// that the field did not move, and the recorder is only how they know
/// the guard was the reason.
///
/// Every model is built with its seams named, so nothing here reaches
/// the installed app's state directory.
@MainActor
final class PresentationGuardTests: XCTestCase {
    /// What the guard declined, in order.
    private final class Refusals {
        var seen: [(field: PresentationField, surface: PresentationOwner)] = []
        var fields: [PresentationField] { seen.map(\.field) }
    }

    private func makeModel(recording refusals: Refusals) throws -> PageModel {
        let suiteName = "companion-presentation-guard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-guard-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PageModel(
            formFactor: .backdrop,
            defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: .ephemeral(tag: UUID().uuidString),
                declinedPresentationWrite: { field, surface in
                    refusals.seen.append((field, surface))
                }
            )
        )
    }

    private func makeEditor() -> InkTextView {
        InkTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    }

    // MARK: The decision

    func testOnlyTheOwnerMayWrite() {
        XCTAssertTrue(PresentationOwner.mayWrite(.panel, owner: .panel))
        XCTAssertTrue(PresentationOwner.mayWrite(.editorWindow, owner: .editorWindow))
        XCTAssertFalse(PresentationOwner.mayWrite(.editorWindow, owner: .panel))
        XCTAssertFalse(PresentationOwner.mayWrite(.panel, owner: .editorWindow))
    }

    func testOnlyTheOwnersWindowInstallsTheKeyboardMap() {
        XCTAssertTrue(PageKeyboardMap.installs(surface: .panel, owner: .panel))
        XCTAssertTrue(PageKeyboardMap.installs(surface: .editorWindow, owner: .editorWindow))
        XCTAssertFalse(PageKeyboardMap.installs(surface: .editorWindow, owner: .panel))
        XCTAssertFalse(PageKeyboardMap.installs(surface: .panel, owner: .editorWindow))
    }

    func testOnlyTheOwnersWindowShowsTheContentArea() {
        XCTAssertTrue(PageContentView.mounts(surface: .panel, owner: .panel))
        XCTAssertTrue(PageContentView.mounts(surface: .editorWindow, owner: .editorWindow))
        XCTAssertFalse(PageContentView.mounts(surface: .editorWindow, owner: .panel))
        XCTAssertFalse(PageContentView.mounts(surface: .panel, owner: .editorWindow))
    }

    func testOnlyTheOwnersRailDrivesTheRoll() {
        XCTAssertTrue(TimeRailView.drivesRoll(surface: .panel, owner: .panel))
        XCTAssertTrue(TimeRailView.drivesRoll(surface: .editorWindow, owner: .editorWindow))
        XCTAssertFalse(TimeRailView.drivesRoll(surface: .editorWindow, owner: .panel))
        XCTAssertFalse(TimeRailView.drivesRoll(surface: .panel, owner: .editorWindow))
    }

    func testTheRailThatDoesNotOwnIsHandedARollNobodyClaims() throws {
        let model = try makeModel(recording: Refusals())
        let unclaimed = RollGeometryModel()
        let roll = NSObject()
        var wheels = 0
        var scrolls = 0
        model.rollGeometry.claim(
            by: roll, scroller: { _ in scrolls += 1 }, wheel: { _ in wheels += 1 }
        )

        let wheel = try Self.syntheticWheel()

        // The other window's rail first, while both counts are still
        // nought: it is handed the stand in, and the rail's two asks,
        // a scroll and a wheel turned over the column, are put to
        // whatever it was handed. Neither reaches the owner's roll.
        for (surface, owner) in [
            (PresentationOwner.editorWindow, PresentationOwner.panel),
            (.panel, .editorWindow),
        ] {
            let others = TimeRailView.roll(
                surface: surface, owner: owner,
                owners: model.rollGeometry, unclaimed: unclaimed
            )
            XCTAssertTrue(others === unclaimed)
            others.scroll(toDocumentOffset: 120)
            others.relay(wheel: wheel)
            XCTAssertEqual(others.geometry, .unmeasured)
        }
        XCTAssertEqual(scrolls, 0, "a click on the other window's rail moved the owner's roll")
        XCTAssertEqual(wheels, 0, "a wheel over the other window's rail reached the owner's roll")

        // The owner's rail is handed the owner's roll, and the same two
        // asks arrive, which is what makes the noughts above mean
        // something: the counters are wired to the roll being guarded.
        let owners = TimeRailView.roll(
            surface: .panel, owner: .panel,
            owners: model.rollGeometry, unclaimed: unclaimed
        )
        XCTAssertTrue(owners === model.rollGeometry)
        owners.scroll(toDocumentOffset: 120)
        owners.relay(wheel: wheel)
        XCTAssertEqual(scrolls, 1)
        XCTAssertEqual(wheels, 1)
    }

    /// A wheel event nobody turned, built from a Quartz event since
    /// AppKit offers no constructor for one. It is only ever handed to
    /// a closure, never posted, so no window or responder sees it.
    private static func syntheticWheel() throws -> NSEvent {
        let quartz = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0
            )
        )
        return try XCTUnwrap(NSEvent(cgEvent: quartz))
    }

    func testTheGuardNamesEveryFieldTheRecordLists() {
        // ADR-0033 lists eight, and a ninth added here without a guard
        // of its own would be a field with no owner again.
        XCTAssertEqual(PresentationField.allCases.count, 8)
    }

    // MARK: A write from the window that does not own

    func testThePanelOwnsUntilSomebodySaysOtherwise() throws {
        let model = try makeModel(recording: Refusals())
        XCTAssertEqual(model.owner, .panel)
    }

    func testAnEditorAnnouncedByTheOtherWindowIsDeclined() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)
        let editor = makeEditor()

        model.mountEditor(editor, from: .editorWindow)

        XCTAssertNil(model.activeEditor)
        XCTAssertEqual(refusals.fields, [.activeEditor])
        XCTAssertEqual(refusals.seen.first?.surface, .editorWindow)
    }

    func testTheOtherWindowCannotReplaceTheOwnersEditor() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)
        let owners = makeEditor()
        let others = makeEditor()
        model.mountEditor(owners, from: .panel)

        model.mountEditor(others, from: .editorWindow)

        XCTAssertTrue(model.activeEditor === owners)
        XCTAssertEqual(refusals.fields, [.activeEditor])
    }

    func testASealedPasteRouteFromTheOtherWindowIsDeclined() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)

        model.routeSealedPaste({}, from: .editorWindow)

        XCTAssertNil(model.performSealedPaste)
        XCTAssertEqual(refusals.fields, [.sealedPasteRoute])
    }

    func testATodayAnchorFromTheOtherWindowIsDeclined() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)

        model.installTodayAnchor({}, from: .editorWindow)

        XCTAssertNil(model.onAnchorToday)
        XCTAssertEqual(refusals.fields, [.todayAnchor])
    }

    func testARollGeometryClaimFromTheOtherWindowIsDeclined() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)
        let owners = NSObject()
        let others = NSObject()
        model.claimRollGeometry(by: owners, from: .panel)

        model.claimRollGeometry(by: others, from: .editorWindow)

        XCTAssertTrue(model.rollGeometry.holdsClaim(owners))
        XCTAssertFalse(model.rollGeometry.holdsClaim(others))
        XCTAssertEqual(refusals.fields, [.rollGeometry])
    }

    func testAKeyReportFromTheOtherWindowIsDeclinedEitherWay() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)

        model.reportKeys(true, from: .editorWindow)
        XCTAssertFalse(model.holdsKeys)

        // And the other window resigning says nothing about the page:
        // the owner's window still has the keyboard.
        model.reportKeys(true, from: .panel)
        model.reportKeys(false, from: .editorWindow)
        XCTAssertTrue(model.holdsKeys)

        XCTAssertEqual(refusals.fields, [.holdsKeys, .holdsKeys])
    }

    func testThePasteboardOfferAndTheRedrawCadenceAreTheOwnersToo() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)

        model.refreshPasteboardOffer(from: .editorWindow)
        model.startRedraw(interval: 30, from: .editorWindow)
        model.stopRedraw(from: .editorWindow)

        XCTAssertFalse(model.pasteboardOffer)
        XCTAssertEqual(refusals.fields, [.pasteboardOffer, .redrawCadence, .redrawCadence])
    }

    func testTheOwnersWritesAreAdmittedAndNothingIsRecorded() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)
        let editor = makeEditor()
        let roll = NSObject()

        model.mountEditor(editor, from: .panel)
        model.routeSealedPaste({}, from: .panel)
        model.installTodayAnchor({}, from: .panel)
        model.claimRollGeometry(by: roll, from: .panel)
        model.reportKeys(true, from: .panel)
        model.refreshPasteboardOffer(from: .panel)
        model.startRedraw(from: .panel)
        model.stopRedraw(from: .panel)

        XCTAssertTrue(model.activeEditor === editor)
        XCTAssertNotNil(model.performSealedPaste)
        XCTAssertNotNil(model.onAnchorToday)
        XCTAssertTrue(model.rollGeometry.holdsClaim(roll))
        XCTAssertTrue(model.holdsKeys)
        XCTAssertTrue(refusals.seen.isEmpty)
    }

    // MARK: A release asks nobody

    func testASurfaceRetiresItsOwnEditorAndNeverAnothers() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)
        let mounted = makeEditor()
        let stranger = makeEditor()
        model.mountEditor(mounted, from: .panel)

        model.retireEditor(stranger)
        XCTAssertTrue(model.activeEditor === mounted, "only the editor the handle names")

        model.retireEditor(mounted)
        XCTAssertNil(model.activeEditor)
        XCTAssertTrue(refusals.seen.isEmpty, "a release is not a claim, and is not guarded as one")
    }

    // MARK: The transfer

    func testATransferLetsGoOfEverythingTheOutgoingOwnerHeld() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)
        let roll = NSObject()
        model.mountEditor(makeEditor(), from: .panel)
        model.routeSealedPaste({}, from: .panel)
        model.installTodayAnchor({}, from: .panel)
        model.claimRollGeometry(by: roll, from: .panel)
        model.reportKeys(true, from: .panel)

        model.transferOwnership(to: .editorWindow)

        XCTAssertEqual(model.owner, .editorWindow)
        XCTAssertNil(model.activeEditor)
        XCTAssertNil(model.performSealedPaste)
        XCTAssertNil(model.onAnchorToday)
        XCTAssertFalse(model.rollGeometry.holdsClaim(roll))
        XCTAssertFalse(model.pasteboardOffer)
        XCTAssertFalse(
            model.holdsKeys,
            "the keys described the other window, and the new owner's reports its own"
        )
        XCTAssertTrue(refusals.seen.isEmpty)
    }

    func testTheGuardFollowsTheTransfer() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)
        let panels = makeEditor()
        let windows = makeEditor()
        model.transferOwnership(to: .editorWindow)

        // The panel's mount is still standing, since SwiftUI takes it
        // down in its own time, and an update pass of its own that got
        // this far must not put its editor back over the owner's.
        model.mountEditor(panels, from: .panel)
        XCTAssertNil(model.activeEditor)
        XCTAssertEqual(refusals.fields, [.activeEditor])

        model.mountEditor(windows, from: .editorWindow)
        XCTAssertTrue(model.activeEditor === windows)
        XCTAssertEqual(refusals.fields, [.activeEditor])
    }

    func testATransferToTheWindowThatAlreadyOwnsMovesNothing() throws {
        let refusals = Refusals()
        let model = try makeModel(recording: refusals)
        let editor = makeEditor()
        model.mountEditor(editor, from: .panel)
        model.reportKeys(true, from: .panel)

        model.transferOwnership(to: .panel)

        XCTAssertTrue(model.activeEditor === editor)
        XCTAssertTrue(model.holdsKeys)
    }

    func testATransferLeavesThePagesPlaceBeforeTheOwnerMoves() throws {
        let model = try makeModel(recording: Refusals())
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let coordinator = InkEditorView.Coordinator(model: model)
        let scroll = InkEditorView.makePage(
            model: model, sheetID: page, readOnly: false, coordinator: coordinator
        )
        let textView = try XCTUnwrap(scroll.documentView as? InkTextView)
        textView.insertText("a line the caret stands inside", replacementRange: NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: 7, length: 0))

        model.transferOwnership(to: .editorWindow)

        // The transfer takes this editor off the page, and an editor
        // asked for its place after that declines to answer. The place
        // has to be in the model already.
        XCTAssertEqual(model.viewStates.carets[page], NSRange(location: 7, length: 0))
    }
}
