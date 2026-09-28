import AppKit
import SwiftUI

/// The window that does not own the page content shows a glance, not a
/// second editor (ADR-0033). A glance is a rendering of the selected
/// page over private storage: it cannot take focus, cannot be selected,
/// is not a first responder candidate and is never entered into
/// `PageModel.storages`, so ADR-0006's one layout manager per storage
/// rule holds unchanged.
///
/// It follows the owning editor through `PageModel.quietRendering(for:)`:
/// the model drops its cached rendering at every accepted edit (through
/// `invalidateQuietRendering(for:)` on the ops path) and at every
/// dependency change (through `invalidateQuietRenderings`), and the
/// SwiftUI wrapper re-reads on the next publish. Sealed objects render
/// as chips exactly as on a quiet day; no plaintext appears here that
/// the owning editor would not show.
///
/// Two directions: the resting card while the editor window owns, and
/// the editor window while a raised panel owns. Both mount this view;
/// the surface's own root view is responsible for asking the resolver
/// (`PresentationOwner.mayWrite`) and building `GlanceView` in the not
/// owning branch.

// MARK: - The SwiftUI wrapper

/// The glance the non-owner mounts in place of `PageContentView`.
/// Watches the model so an edit accepted on the other window's editor
/// republishes and this wrapper hands its NSView the model's rebuilt
/// rendering.
public struct GlanceView: NSViewRepresentable {
    @ObservedObject var model: PageModel

    public init(model: PageModel) {
        self.model = model
    }

    public func makeNSView(context: Context) -> GlancePageView {
        GlancePageView()
    }

    public func updateNSView(_ view: GlancePageView, context: Context) {
        // The selected page, if any: the shared model (`selectedPageID`)
        // is the same in both windows, so a glance follows selections
        // made in the owner. `activeFile` and `showingLedger` are
        // deliberately not answered here (the glance's scope is the
        // selected page); the parent branches for those cases separately.
        guard let page = model.selectedPageID, !page.isFileID else {
            view.showEmpty()
            return
        }
        view.render(model.quietRendering(for: page), for: page)
    }
}

// MARK: - The NSView

/// The glance itself: an `NSTextView` mounted over its own storage the
/// model never learns of, with no delegate, no editability, no
/// selection, and no first-responder claim. The same shape as
/// `QuietPageView` on the roll, kept single-purpose here so the glance
/// can be reasoned about on its own.
public final class GlancePageView: NSTextView {
    /// The page the glance is currently drawn from, kept so the wrapper
    /// can compare against the next update and rebuild the storage
    /// wholesale on a selection change.
    private var currentPage: UInt64?

    /// The model's rendering this glance was last seeded from. Identity
    /// comparison decides whether the next render is a cache hit; the
    /// model hands back the same object while nothing has changed
    /// (`PageModel.quietRendering(for:)`).
    private var seeded: PageModel.QuietRendering?

    /// This glance's storage, held here because nothing else would
    /// (`QuietPageView`'s note applies): TextKit 1's storage → layout
    /// manager → container → view chain is unowned back the other way,
    /// so a storage nobody keeps is freed out from under the view still
    /// laying it out. The model never learns of it — it is not entered
    /// into `PageModel.storages` — so the projection parity assertion
    /// and the editor's mount sites never see it.
    private let ownStorage: NSTextStorage

    public init() {
        let storage = NSTextStorage()
        self.ownStorage = storage
        let layoutManager = InkLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        // The editor's own inset and base font, so the glance sits where
        // the mounted editor would and does not shift the moment
        // ownership returns. Block-label reserve is deliberately absent
        // (ADR-0030): quiet renderings carry no labels.
        textContainerInset = NSSize(width: 12, height: InkEditorView.Coordinator.topInset)
        font = InkStyle.baseFont
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the glance is never unarchived")
    }

    /// Take the page's rendering, rebuilding the storage on a page
    /// change and re-seeding it on a content change. The identity check
    /// on `rendering !== seeded` shortcuts the common pass where nothing
    /// about the shown page has moved.
    public func render(_ rendering: PageModel.QuietRendering, for page: UInt64) {
        if currentPage != page {
            currentPage = page
            seeded = rendering
            ownStorage.setAttributedString(rendering.text)
            if let manager = layoutManager as? InkLayoutManager {
                manager.fenceRegions = rendering.fenceRegions
            }
            needsDisplay = true
            return
        }
        guard rendering !== seeded else { return }
        seeded = rendering
        ownStorage.setAttributedString(rendering.text)
        if let manager = layoutManager as? InkLayoutManager {
            manager.fenceRegions = rendering.fenceRegions
            needsDisplay = true
        }
    }

    /// Empty the glance, for when no page is selected. Cheap: the
    /// storage becomes empty and the view lays out nothing.
    public func showEmpty() {
        currentPage = nil
        seeded = nil
        ownStorage.setAttributedString(NSAttributedString())
        needsDisplay = true
    }

    /// The glance is never a first-responder candidate. There is one
    /// focusable text view in the app and it is the owner's editor
    /// (ADR-0006); a keystroke landing here would leave the owner with
    /// no way to answer.
    public override var acceptsFirstResponder: Bool { false }

    public override func becomeFirstResponder() -> Bool { false }

    /// A click here is not an ask to focus. The glance stands in for a
    /// live editor the person cannot address from this window; the
    /// gesture that would move ownership is on the other window's own
    /// terms (`BackdropModel.keyTurn` and the resting card's raise).
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    public override var needsPanelToBecomeKey: Bool { false }

    /// The storage the glance draws from, exposed for tests so the
    /// invariant "not in `PageModel.storages`" can be checked as
    /// identity rather than as prose.
    public var storageForTesting: NSTextStorage { ownStorage }
}
