import AppKit
import SwiftUI

/// A tab as a drop target (issue 254), seated behind the tab's SwiftUI content. The
/// drops AppKit brings arrive here; every click falls through to the tab's own gestures.
struct TabDropOverlay: NSViewRepresentable {
    let model: PageModel
    let slot: UInt64

    func makeNSView(context: Context) -> TabDropTarget {
        TabDropTarget(model: model, slot: slot)
    }

    func updateNSView(_ view: TabDropTarget, context: Context) {
        view.slot = slot
    }
}

/// Where a drop on a tab goes: the end of the slot's page, by the routes a drop on the
/// page takes (Law 0001, drag and ⌥ drag rows), so a tab and a page sort one drag alike.
@MainActor
final class TabDropTarget: NSView {
    let model: PageModel
    /// The slot, not the page: the page is read live, so a slot whose page went aims nothing.
    var slot: UInt64

    init(model: PageModel, slot: UInt64) {
        self.model = model
        self.slot = slot
        super.init(frame: .zero)
        // The fragment, and the two kinds the core reads off another app's drag board.
        registerForDraggedTypes([SealedFragment.pasteboardType, .string, .png])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("a tab's drop target is never unarchived")
    }

    /// Nothing: the select, the hold and the reorder handle are the tab's SwiftUI gestures.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The page the slot holds right now, or nil for an empty slot (ADR-0017).
    var page: UInt64? {
        model.tabs.first { $0.id == slot }?.pageID
    }

    /// The route `sender` takes onto this tab, and what it carries.
    func dropRoute(for sender: NSDraggingInfo) -> InkTextView.DropRoute {
        classify(sender).route
    }

    private func classify(
        _ sender: NSDraggingInfo
    ) -> (route: InkTextView.DropRoute, cargo: InkTextView.DragCargo) {
        let cargo = InkTextView.cargo(of: sender, in: model)
        guard let page else { return (.refused, cargo) }
        if case .pageDrag(_, let from, _, _) = cargo, from == page { return (.ownDrag, cargo) }
        // A tab has no surface for AppKit to lay ink on, so ink from this app is refused here.
        let route = InkTextView.dropRoute(
            cargo, offered: sender.draggingSourceOperationMask, ontoPage: page,
            takesFragment: true, takesInk: false, seals: true)
        return (route, cargo)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    /// The cursor's answer, the page's own for each route: a page's drag moves or with
    /// ⌥ copies, a fragment copies, another app's drag copies into a seal.
    func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let mask = sender.draggingSourceOperationMask
        let (route, cargo) = classify(sender)
        switch route {
        case .refused, .ink:
            return []
        case .ownDrag:
            guard case .pageDrag(_, let sheet, let range, _) = cargo else { return [] }
            return ownDragOperation(range, on: sheet, offered: mask)
        case .move:
            return .move
        case .fragment:
            return mask.contains(.copy) ? .copy : []
        case .seal:
            return .copy
        }
    }

    /// The page's own drag onto its tab: a move of a range already ending the body is no drop.
    private func ownDragOperation(
        _ range: NSRange, on sheet: UInt64, offered mask: NSDragOperation
    ) -> NSDragOperation {
        let operation = InkTextView.pageDropOperation(offered: mask)
        let atEnd = NSMaxRange(range) == model.bodyLength(of: sheet)
        return operation == .move && atEnd ? [] : operation
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Read before drop to seal touches the drag board, which would ask our provider.
        let (route, cargo) = classify(sender)
        guard let page else { return false }
        let mask = sender.draggingSourceOperationMask
        switch route {
        case .refused, .ink:
            return false
        case .ownDrag:
            guard case .pageDrag(let source, _, let range, _) = cargo else { return false }
            let operation = ownDragOperation(range, on: page, offered: mask)
            guard operation != [], admitsDrop(from: source.textView, onto: page) else { return false }
            let showing = prepareSurface(of: page)
            let end = model.bodyLength(of: page)
            guard let placed = model.dropRange(
                range, sheet: page, at: end, cloning: operation == .copy)
            else { return false }
            source.invalidateOrdinaryPasteMeasurement()
            (showing ?? source).settleRewrite(selecting: placed.range)
            return true
        case .move:
            guard case .pageDrag(let source, let from, let range, _) = cargo,
                  admitsDrop(from: source.textView, onto: page)
            else { return false }
            let showing = prepareSurface(of: page)
            let end = model.bodyLength(of: page)
            guard let placed = model.dropRange(range, sheet: from, onto: page, at: end) else {
                return false
            }
            source.invalidateOrdinaryPasteMeasurement()
            source.settleRewrite(selecting: NSRange(location: range.location, length: 0))
            showing?.settleRewrite(selecting: placed.range)
            return true
        case .fragment:
            let source = sender.draggingSource as? InkTextView
            guard admitsDrop(from: source, onto: page) else { return false }
            let showing = prepareSurface(of: page)
            let end = model.bodyLength(of: page)
            guard case .placed(let placed) = model.pasteFragment(
                from: sender.draggingPasteboard, sheet: page,
                ranges: [NSRange(location: end, length: 0)])
            else { return false }
            showing?.settleRewrite(selecting: placed.range)
            return true
        case .seal:
            guard admitsDrop(from: nil, onto: page) else { return false }
            let showing = prepareSurface(of: page)
            let end = model.bodyLength(of: page)
            guard model.sealDrag(onto: page, at: end) != nil else { return false }
            showing?.settleRewrite(selecting: NSRange(location: end, length: 1))
            return true
        }
    }

    /// Whether a drop may land while a field or note holds the keys (Law 0007, keys row),
    /// asked of the page's surface when it shows, else the drag's source, else the owner's editor.
    private func admitsDrop(from source: InkTextView?, onto page: UInt64) -> Bool {
        let asked = model.surface(showing: page) ?? source ?? model.activeEditor as? InkTextView
        guard let coordinator = asked?.coordinator else { return true }
        return coordinator.admitsDrop(from: source)
    }

    /// The surface showing `page`, readied as its own drop readies it, or nil when none shows it.
    private func prepareSurface(of page: UInt64) -> InkEditorView.Coordinator? {
        guard let surface = model.surface(showing: page), let coordinator = surface.coordinator
        else { return nil }
        InkEditorView.discardComposition(in: surface)
        coordinator.invalidateOrdinaryPasteMeasurement()
        return coordinator
    }
}
