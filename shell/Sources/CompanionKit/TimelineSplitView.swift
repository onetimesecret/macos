import AppKit
import SwiftUI

/// Shared native divider for the timeline and page content in both presentations.
public struct TimelineSplitView<Rail: View, Content: View>: View {
    let showsTimeline: Bool
    let railWidth: CGFloat
    let onRailResize: @MainActor (CGFloat) -> Void
    let leftMouseIsDown: @MainActor () -> Bool
    let rail: Rail
    let content: Content

    public init(
        showsTimeline: Bool,
        railWidth: CGFloat,
        onRailResize: @escaping @MainActor (CGFloat) -> Void,
        leftMouseIsDown: @escaping @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
        @ViewBuilder rail: () -> Rail,
        @ViewBuilder content: () -> Content
    ) {
        self.showsTimeline = showsTimeline
        self.railWidth = railWidth
        self.onRailResize = onRailResize
        self.leftMouseIsDown = leftMouseIsDown
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
                        .background(DividerWatch(
                            startWidth: railWidth, onMove: onRailResize, leftMouseIsDown: leftMouseIsDown))
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

    /// The rail's widest allowed width in a split this wide, never under the rail's start width.
    static func railCeiling(splitWidth: CGFloat, dividerThickness: CGFloat = dividerWidth) -> CGFloat {
        guard splitWidth > 0 else { return TimeRailView.maxWidth }
        return TimeRailView.clampedWidth(splitWidth - pageMinWidth - dividerThickness)
    }

    /// The `userInfo` keys `NSSplitView.didResizeSubviewsNotification` documents.
    static let dividerIndexKey = "NSSplitViewDividerIndex"
    static let userResizeKey = "NSSplitViewUserResizeKey"
}

/// Keeps the leading pane at the person's width within the split's ceiling, and reports their divider moves.
private struct DividerWatch: NSViewRepresentable {
    let startWidth: CGFloat
    let onMove: @MainActor (CGFloat) -> Void
    let leftMouseIsDown: @MainActor () -> Bool

    func makeNSView(context: Context) -> DividerWatchView {
        let view = DividerWatchView()
        view.setAccessibilityElement(false)
        view.preferredWidth = startWidth
        view.onMove = onMove
        view.leftMouseIsDown = leftMouseIsDown
        return view
    }

    func updateNSView(_ view: DividerWatchView, context: Context) {
        view.onMove = onMove
        view.leftMouseIsDown = leftMouseIsDown
        view.adopt(startWidth)
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
    var leftMouseIsDown: @MainActor () -> Bool = { false }
    private weak var split: NSSplitView?
    private var placementQueued = false
    /// Set across the watch's own `setPosition`.
    private var placing = false
    private var recordPending = false
    /// Checks left before a pending record is written even with a button still held.
    private var releaseChecks = 0
    /// The split's and the leading pane's widths at the last notification: a divider drag moves the
    /// pane and leaves the split.
    private var lastSplitWidth: CGFloat?
    private var lastLeadingWidth: CGFloat?
    /// A placement the split did not take, not retried until the target or the split's width changes.
    private var failedPlacement: (target: CGFloat, splitWidth: CGFloat)?
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

    /// Not mid-drag: a placement queued while the button is held or a record waits would block the
    /// held-button check, and the split's own resizes ask again once the drag ends.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !recordPending && !leftMouseIsDown() { queuePlacement() }
    }

    /// A stored width changed elsewhere, such as in the other presentation, unless this split's
    /// own drag is still waiting to be recorded.
    func adopt(_ width: CGFloat) {
        guard !recordPending, abs(width - preferredWidth) >= 0.5 else { return }
        preferredWidth = width
        queuePlacement()
    }

    /// SwiftUI's dismantle: a drag still waiting is recorded on the next main-queue turn, outside the
    /// view update, since the record publishes.
    func retire() {
        detach()
        guard recordPending else {
            onMove = nil
            return
        }
        DispatchQueue.main.async { [self] in
            if recordPending { recordDrag() }
            onMove = nil
        }
    }

    private func attach() {
        detach()
        guard window != nil, let split = enclosingSplitView() else { return }
        self.split = split
        observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: nil
        ) { [weak self, weak split] note in
            let userResize = (note.userInfo?[TimelineSplit.userResizeKey] as? NSNumber)?.boolValue == true
            let dividerMoved = note.userInfo?[TimelineSplit.dividerIndexKey] != nil
            MainActor.assumeIsolated {
                guard let watch = self, let split else { return }
                watch.splitDidResize(split, userResize: userResize, dividerMoved: dividerMoved)
            }
        }
        queuePlacement()
    }

    private func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        split = nil
        lastSplitWidth = nil
        lastLeadingWidth = nil
        failedPlacement = nil
    }

    /// A person's drag: AppKit's user-resize key, or a divider move under a held left button in a
    /// split whose own width did not change. Anything else is placed and not recorded.
    private func splitDidResize(_ split: NSSplitView, userResize: Bool, dividerMoved: Bool) {
        let width = split.bounds.width
        let leadingWidth = split.arrangedSubviews.first?.frame.width
        defer {
            lastSplitWidth = width
            lastLeadingWidth = leadingWidth
        }
        guard !placing else { return }
        let paneMoved = leadingWidth.map { abs($0 - (lastLeadingWidth ?? $0)) >= 0.5 } ?? false
        let heldMove = dividerMoved && !placementQueued && lastSplitWidth == width && paneMoved
            && leftMouseIsDown()
        guard userResize || heldMove, split.arrangedSubviews.count > 1,
              let leading = split.arrangedSubviews.first, isDescendant(of: leading)
        else {
            return queuePlacement()
        }
        preferredWidth = leading.frame.width
        // Re-armed on every move, so the bound counts from the latest one and a slow drag is not cut short.
        releaseChecks = 60
        guard !recordPending else { return }
        recordPending = true
        DispatchQueue.main.async { [weak self] in self?.recordWhenReleased() }
    }

    /// Records once the mouse button is up, so a drag's moves coalesce into one record; a button held
    /// three seconds past the last move no longer defers it.
    private func recordWhenReleased() {
        guard recordPending else { return }
        releaseChecks -= 1
        guard !leftMouseIsDown() || releaseChecks <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.recordWhenReleased() }
            return
        }
        recordDrag()
    }

    /// Writes the person's width, then places the divider again, since `place()` skipped any resize
    /// that arrived while the record waited.
    private func recordDrag() {
        recordPending = false
        onMove?(preferredWidth)
        queuePlacement()
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

    /// The person's width, or the ceiling when the split is too narrow for it. Not while a drag is
    /// waiting to be recorded: the divider is then where the person put it.
    private func place() {
        guard !recordPending, let split, split.bounds.width > 0, split.arrangedSubviews.count > 1,
              let leading = split.arrangedSubviews.first, isDescendant(of: leading)
        else { return }
        let width = split.bounds.width
        lastSplitWidth = width
        lastLeadingWidth = leading.frame.width
        let target = min(
            TimeRailView.clampedWidth(preferredWidth),
            TimelineSplit.railCeiling(splitWidth: width, dividerThickness: split.dividerThickness))
        guard abs(leading.frame.width - target) >= 0.5 else {
            failedPlacement = nil
            return
        }
        if let failed = failedPlacement, failed.target == target, failed.splitWidth == width { return }
        placing = true
        split.setPosition(target, ofDividerAt: 0)
        placing = false
        lastLeadingWidth = leading.frame.width
        failedPlacement = abs(leading.frame.width - target) >= 0.5 ? (target, width) : nil
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
