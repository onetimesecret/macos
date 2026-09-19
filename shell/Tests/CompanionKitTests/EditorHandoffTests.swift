import AppKit
import XCTest

@testable import CompanionKit

/// Handing the keyboard to an editor that is actually there (issue
/// #23).
///
/// One editor serves every page (ADR-0006), and it is torn down and
/// rebuilt more often than the page switches: a ledger round trip does
/// it, and since tabs and pages came apart so does a visit to a slot
/// whose page expired. The model holds that editor weakly, for the
/// grants and the summon to hand the keyboard to, and the window
/// between a teardown and ARC letting go is a window in which the
/// handle answers with a view that is no longer on screen. What the
/// hand-off needs to know is not whether the view exists but whether it
/// is mounted, and a mounted view is one inside a window.
///
/// Real AppKit objects rather than stand-ins: the fact under test is a
/// view's relationship to a window, which is not a thing worth
/// modelling twice.
@MainActor
final class EditorHandoffTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-editor-handoff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return isolatedModel(defaults: defaults)
    }

    /// A card-sized window with a text view mounted in it, held by the
    /// caller so nothing here rests on the weak handle under test.
    private func mountedEditor() -> (NSWindow, InkTextView) {
        let card = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        let textView = InkTextView(frame: card)
        window.contentView?.addSubview(textView)
        return (window, textView)
    }

    // MARK: Which editor may take the keys

    func testAnEditorInsideAWindowIsTheOneToFocus() {
        let (window, textView) = mountedEditor()
        XCTAssertNotNil(window.contentView)
        XCTAssertTrue(PageModel.mountedEditor(textView) === textView)
    }

    func testAnEditorTornOutOfItsWindowIsRefused() {
        let (_, textView) = mountedEditor()
        textView.removeFromSuperview()

        XCTAssertNil(
            PageModel.mountedEditor(textView),
            """
            a torn-down editor answers the model's weak handle until ARC lets go of it; \
            focusing it would put the keyboard nowhere and stop the poll waiting for the \
            editor that is actually coming
            """
        )
    }

    func testNoEditorAtAllIsRefused() {
        XCTAssertNil(PageModel.mountedEditor(nil))
    }

    // MARK: Retiring the handle when the mount goes

    func testDismantlingTheEditorRetiresTheModelsHandle() throws {
        let model = try makeModel()
        let textView = InkTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        let scroll = InkEditorView.scrollStack(for: textView)
        let coordinator = InkEditorView.Coordinator(model: model)
        model.mountEditor(textView, from: .panel)

        InkEditorView.dismantleNSView(scroll, coordinator: coordinator)

        XCTAssertNil(
            model.activeEditor,
            "the mount is gone, so the model must not offer it to the next hand-off"
        )
    }

    func testDismantlingAnEditorAlreadyReplacedLeavesTheLiveOneAlone() throws {
        let model = try makeModel()
        let outgoing = InkTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        let scroll = InkEditorView.scrollStack(for: outgoing)
        let coordinator = InkEditorView.Coordinator(model: model)
        // SwiftUI is free to build the replacement before dismantling
        // what it replaces, in which case the handle already names the
        // new editor and the teardown has nothing to retire.
        let incoming = InkTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        model.mountEditor(incoming, from: .panel)

        InkEditorView.dismantleNSView(scroll, coordinator: coordinator)

        XCTAssertTrue(
            model.activeEditor === incoming,
            "the live editor's handle was thrown away with the dead one's"
        )
    }
}
