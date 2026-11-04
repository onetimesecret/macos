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
                        .frame(minWidth: TimeRailView.width, idealWidth: TimeRailView.width, maxWidth: ceiling)
                        .background(DividerWatch(startWidth: railWidth, onMove: onRailResize))
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
    /// The page's narrowest width beside the timeline.
    static let pageMinWidth: CGFloat = 160

    /// The thin divider's thickness.
    static let dividerWidth: CGFloat = 1

    /// The rail's widest allowed width in a split this wide, so the page keeps `pageMinWidth`.
    static func railCeiling(splitWidth: CGFloat) -> CGFloat {
        guard splitWidth > 0 else { return TimeRailView.maxWidth }
        return TimeRailView.clampedWidth(splitWidth - pageMinWidth - dividerWidth)
    }
}

/// Keeps the leading pane at the person's width within the split's ceiling, and reports their divider moves.
private struct DividerWatch: NSViewRepresentable {
    let startWidth: CGFloat
    let onMove: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerWatchView {
        let view = DividerWatchView()
        view.setAccessibilityElement(false)
        view.preferredWidth = startWidth
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

private final class DividerWatchView: NSView {
    /// The stored width at mount, then each divider move. `HSplitView` opens a pane at its
    /// minimum, so the watch places the divider itself.
    var preferredWidth: CGFloat = TimeRailView.width
    var onMove: (@MainActor (CGFloat) -> Void)?
    private weak var split: NSSplitView?
    /// Set by a placement until the next main-queue turn, so the resize it causes is not recorded.
    private var placing = false
    private var placementQueued = false
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        queuePlacement()
    }

    func retire() {
        detach()
        onMove = nil
    }

    private func attach() {
        detach()
        guard window != nil, let split = enclosingSplitView() else { return }
        self.split = split
        observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: nil
        ) { [weak self, weak split] note in
            // Only divider moves name a divider index; window resizes stay unrecorded (TimelineSplitViewTests).
            let moved = note.userInfo?["NSSplitViewDividerIndex"] != nil
            MainActor.assumeIsolated {
                guard let watch = self, let split else { return }
                watch.splitDidResize(split, dividerMoved: moved)
            }
        }
        queuePlacement()
    }

    private func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func splitDidResize(_ split: NSSplitView, dividerMoved: Bool) {
        guard !placing else { return }
        guard dividerMoved, split.arrangedSubviews.count > 1, let leading = split.arrangedSubviews.first else {
            return queuePlacement()
        }
        preferredWidth = leading.frame.width
        onMove?(leading.frame.width)
    }

    /// Places the divider on the next main-queue turn, outside the split's own resize pass.
    private func queuePlacement() {
        guard !placementQueued, split != nil else { return }
        placementQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.placementQueued = false
            self.place()
        }
    }

    /// The person's width, or the ceiling when the split is too narrow for it.
    private func place() {
        guard let split, split.bounds.width > 0, split.arrangedSubviews.count > 1,
              let leading = split.arrangedSubviews.first
        else { return }
        let target = min(
            TimeRailView.clampedWidth(preferredWidth), TimelineSplit.railCeiling(splitWidth: split.bounds.width))
        guard abs(leading.frame.width - target) >= 0.5 else { return }
        placing = true
        split.setPosition(target, ofDividerAt: 0)
        DispatchQueue.main.async { [weak self] in self?.placing = false }
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
