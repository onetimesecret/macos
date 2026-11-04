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

/// Opens the leading pane at `startWidth` and reports its width after each divider move.
private struct DividerWatch: NSViewRepresentable {
    let startWidth: CGFloat
    let onMove: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerWatchView {
        let view = DividerWatchView()
        view.setAccessibilityElement(false)
        view.startWidth = startWidth
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
    /// Applied once per mount: `HSplitView` opens a pane at its minimum, not its ideal width.
    var startWidth: CGFloat = TimeRailView.width
    var onMove: (@MainActor (CGFloat) -> Void)?
    private weak var split: NSSplitView?
    private var started = false
    private var starting = false
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
        startIfNeeded()
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
            // Divider moves carry an index; window resizes stay unrecorded (TimelineSplitViewTests).
            let moved = note.userInfo?["NSSplitViewDividerIndex"] != nil
            MainActor.assumeIsolated {
                guard let watch = self else { return }
                guard moved else { return watch.startIfNeeded() }
                guard !watch.starting, let leading = split?.arrangedSubviews.first else { return }
                watch.onMove?(leading.frame.width)
            }
        }
        startIfNeeded()
    }

    private func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Moves the divider to `startWidth` once the split has laid its panes out; the move is not recorded.
    private func startIfNeeded() {
        guard !started, let split, split.bounds.width > 0, split.arrangedSubviews.count > 1 else { return }
        started = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let split = self.split, split.arrangedSubviews.count > 1,
                  let leading = split.arrangedSubviews.first,
                  abs(leading.frame.width - self.startWidth) >= 0.5
            else { return }
            self.starting = true
            split.setPosition(self.startWidth, ofDividerAt: 0)
            self.starting = false
        }
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
