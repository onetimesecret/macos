import AppKit
import SwiftUI

/// Shared native divider for the timeline and page content in both presentations.
public struct TimelineSplitView<Rail: View, Content: View>: View {
    let showsTimeline: Bool
    let railWidth: CGFloat
    let onRailResize: @MainActor (CGFloat) -> Void
    let rail: Rail
    let content: Content

    public init(
        showsTimeline: Bool,
        railWidth: CGFloat,
        onRailResize: @escaping @MainActor (CGFloat) -> Void,
        @ViewBuilder rail: () -> Rail,
        @ViewBuilder content: () -> Content
    ) {
        self.showsTimeline = showsTimeline
        self.railWidth = railWidth
        self.onRailResize = onRailResize
        self.rail = rail()
        self.content = content()
    }

    public var body: some View {
        GeometryReader { proxy in
            let ceiling = TimelineSplit.railCeiling(splitWidth: proxy.size.width)
            HSplitView {
                if showsTimeline {
                    rail
                        .frame(
                            minWidth: TimeRailView.width,
                            idealWidth: min(TimeRailView.clampedWidth(railWidth), ceiling),
                            maxWidth: ceiling)
                        .background(DividerWatch(onMove: onRailResize))
                }
                content
                    .frame(minWidth: TimelineSplit.pageMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
        }
    }
}

/// The split's measures, outside the generic view so both test targets can name them.
enum TimelineSplit {
    /// The page's narrowest width beside the timeline; the rail yields before the page does.
    static let pageMinWidth: CGFloat = 160

    /// The thin divider's thickness.
    static let dividerWidth: CGFloat = 1

    /// The rail's widest allowed width in a split this wide, so the page keeps `pageMinWidth`.
    static func railCeiling(splitWidth: CGFloat) -> CGFloat {
        guard splitWidth > 0 else { return TimeRailView.maxWidth }
        return TimeRailView.clampedWidth(splitWidth - pageMinWidth - dividerWidth)
    }
}

/// Reports the leading pane's width after the enclosing split view's divider moves.
private struct DividerWatch: NSViewRepresentable {
    let onMove: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerWatchView {
        let view = DividerWatchView()
        view.setAccessibilityElement(false)
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: DividerWatchView, context: Context) {
        view.onMove = onMove
    }

    static func dismantleNSView(_ view: DividerWatchView, coordinator: ()) {
        view.retire()
    }
}

final class DividerWatchView: NSView {
    var onMove: (@MainActor (CGFloat) -> Void)?
    /// Copied out by the nonisolated deinit, as `WheelRelayView` does for its monitor.
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attach()
    }

    func retire() {
        detach()
        onMove = nil
    }

    private func attach() {
        detach()
        guard window != nil, let split = enclosingSplitView() else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
        ) { [weak self, weak split] note in
            // Divider moves carry an index; window resizes stay unrecorded (TimelineSplitViewTests).
            guard note.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
            MainActor.assumeIsolated {
                guard let watch = self, let leading = split?.arrangedSubviews.first else { return }
                watch.onMove?(leading.frame.width)
            }
        }
    }

    private func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func enclosingSplitView() -> NSSplitView? {
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView { return split }
            ancestor = view.superview
        }
        return nil
    }
}
