import AppKit
import SwiftUI
import XCTest

@testable import CompanionKit

/// The glance the non-owner mounts (ADR-0033, B3).
///
/// Every rule the glance is written to keep is a property of the object
/// on its own: it holds a storage the model never learns of, it renders
/// from `PageModel.quietRendering(for:)`, it re-renders on every
/// invalidation the model announces, it refuses first-responder and it
/// takes no click that would key a window.
///
/// AppKit objects rather than stand-ins here. The invariant under test
/// is a relationship between the view and the model's storage map, and
/// the model's map is what would notice a mistake in production.
@MainActor
final class GlanceViewTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-glance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return isolatedModel(defaults: defaults)
    }

    /// A page whose document holds the given ink, minted and left as
    /// the selection. Shape borrowed from `DayScrollPreviewRenderingTests`.
    @discardableResult
    private func page(in model: PageModel, saying ink: String) throws -> UInt64 {
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let escaped = ink
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertTrue(model.coreClient.syncDocument(
            sheet: page, json: "[{\"ink\": \"\(escaped)\"}]"
        ))
        model.refresh()
        return page
    }

    // MARK: The glance is not a first-responder candidate

    func testTheGlanceRefusesFirstResponder() {
        // One focusable text view in the card, always: the owner's
        // editor (ADR-0006). The glance answers no whichever way the
        // question is asked, so a keystroke landing here has no path.
        let glance = GlancePageView()
        XCTAssertFalse(glance.acceptsFirstResponder)
        XCTAssertFalse(glance.becomeFirstResponder())
        XCTAssertFalse(glance.acceptsFirstMouse(for: nil))
        XCTAssertFalse(glance.needsPanelToBecomeKey)
    }

    func testTheGlanceIsNotEditableAndNotSelectable() {
        // A selection would carry the caret and open a copy path over
        // the same characters the owning editor is drawing; the glance
        // must not offer either.
        let glance = GlancePageView()
        XCTAssertFalse(glance.isEditable)
        XCTAssertFalse(glance.isSelectable)
    }

    // MARK: The projection parity assertion never sees a glance storage

    func testTheGlanceStorageStaysOutOfTheModelsMap() throws {
        // The parity assertion (`DocumentOpsTests.assertParity`) compares
        // one editor storage to one core document. Were the glance's
        // storage in `PageModel.storages`, an assembling pass would try
        // to shed its layout manager and the assertion would compare
        // two views' storages instead of one. It stays out because
        // `GlancePageView` builds and holds its own storage, and the
        // model is never told about it.
        let model = try makeModel()
        let pageID = try page(in: model, saying: "quiet ink")

        let glance = GlancePageView()
        glance.render(model.quietRendering(for: pageID), for: pageID)

        XCTAssertFalse(
            model.pagesWithStorage.contains(pageID),
            "the glance mounted a storage the model was told about, breaking the one layout manager per storage rule"
        )
        // The glance's own storage is identity-distinct from anything
        // the model would hand out for the same page.
        XCTAssertFalse(glance.storageForTesting === model.storage(for: pageID))
    }

    // MARK: The glance follows the model's rendering

    func testTheGlancePicksUpTheModelsRendering() throws {
        let model = try makeModel()
        let pageID = try page(in: model, saying: "first")

        let glance = GlancePageView()
        glance.render(model.quietRendering(for: pageID), for: pageID)

        XCTAssertEqual(glance.storageForTesting.string, "first")
    }

    func testTheGlanceReseedsAfterAnInvalidation() throws {
        // A per-page invalidation drops the model's cached rendering
        // (`invalidateQuietRendering(for:)`); the next call to
        // `quietRendering(for:)` builds a fresh payload. Handed to the
        // glance, the storage is refilled with the page's current ink.
        let model = try makeModel()
        let pageID = try page(in: model, saying: "before")

        let glance = GlancePageView()
        glance.render(model.quietRendering(for: pageID), for: pageID)
        XCTAssertEqual(glance.storageForTesting.string, "before")

        // Simulate the owning editor's edit: an accepted ops batch
        // rewrites the core document, invalidates the page's quiet
        // rendering and publishes.
        XCTAssertTrue(model.coreClient.syncDocument(
            sheet: pageID, json: "[{\"ink\": \"after\"}]"
        ))
        model.invalidateQuietRendering(for: pageID)

        glance.render(model.quietRendering(for: pageID), for: pageID)
        XCTAssertEqual(glance.storageForTesting.string, "after")
    }

    func testTheGlanceSwapsStorageWhenTheSelectedPageChanges() throws {
        let model = try makeModel()
        let firstPage = try page(in: model, saying: "first page ink")
        let secondPage = try page(in: model, saying: "second page ink")

        let glance = GlancePageView()
        glance.render(model.quietRendering(for: firstPage), for: firstPage)
        XCTAssertEqual(glance.storageForTesting.string, "first page ink")

        glance.render(model.quietRendering(for: secondPage), for: secondPage)
        XCTAssertEqual(glance.storageForTesting.string, "second page ink")

        // Neither call entered the map (both pages, checked in one).
        XCTAssertFalse(model.pagesWithStorage.contains(firstPage))
        XCTAssertFalse(model.pagesWithStorage.contains(secondPage))
    }

    func testTheGlanceClearsWhenNoPageIsSelected() {
        let glance = GlancePageView()
        // Rendering something first, so the clear is a change and not
        // the empty state a fresh view happens to be in.
        let payload = PageModel.QuietRendering(
            text: NSAttributedString(string: "something to clear"),
            fenceRegions: []
        )
        glance.render(payload, for: 0x0011_0000_0000_0001)
        XCTAssertEqual(glance.storageForTesting.string, "something to clear")

        glance.showEmpty()
        XCTAssertEqual(glance.storageForTesting.string, "")
    }

    // MARK: The wrapper picks the page and refuses files

    func testTheWrapperGlancesTheSelectedPage() throws {
        let model = try makeModel()
        let pageID = try page(in: model, saying: "wrapper hands the page")

        let host = NSHostingView(rootView: GlanceView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()

        let glance = try XCTUnwrap(findGlance(in: host))
        XCTAssertEqual(glance.storageForTesting.string, "wrapper hands the page")
        XCTAssertFalse(model.pagesWithStorage.contains(pageID))
    }

    // MARK: Helpers

    private func findGlance(in view: NSView) -> GlancePageView? {
        if let glance = view as? GlancePageView { return glance }
        for child in view.subviews {
            if let found = findGlance(in: child) { return found }
        }
        return nil
    }
}
