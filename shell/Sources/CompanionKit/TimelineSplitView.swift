import AppKit
import SwiftUI
import os

/// Shared native divider for the timeline and page content in both presentations.
public struct TimelineSplitView<Rail: View, Content: View>: View {
    let showsTimeline: Bool
    let resizable: Bool
    let railWidth: CGFloat
    let onRailResize: @MainActor (CGFloat) -> Void
    let leftMouseIsDown: @MainActor () -> Bool
    let clock: @MainActor () -> TimeInterval
    let rail: Rail
    let content: Content

    public init(
        showsTimeline: Bool,
        resizable: Bool = true,
        railWidth: CGFloat,
        onRailResize: @escaping @MainActor (CGFloat) -> Void,
        leftMouseIsDown: @escaping @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        @ViewBuilder rail: () -> Rail,
        @ViewBuilder content: () -> Content
    ) {
        self.showsTimeline = showsTimeline
        self.resizable = resizable
        self.railWidth = railWidth
        self.onRailResize = onRailResize
        self.leftMouseIsDown = leftMouseIsDown
        self.clock = clock
        self.rail = rail()
        self.content = content()
    }

    public var body: some View {
        GeometryReader { proxy in
            let ceiling = TimelineSplit.railCeiling(splitWidth: proxy.size.width)
            // Not resizable: the rail's range closes on its placed width.
            let pinned = min(TimeRailView.clampedWidth(railWidth), ceiling)
            HSplitView {
                if showsTimeline {
                    rail
                        .frame(
                            minWidth: resizable ? TimeRailView.width : pinned,
                            idealWidth: resizable ? TimeRailView.width : pinned,
                            maxWidth: resizable ? ceiling : pinned)
                        .background(DividerWatch(
                            startWidth: railWidth, records: resizable, onMove: onRailResize,
                            leftMouseIsDown: leftMouseIsDown, clock: clock))
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

    /// The narrowest split in which the rail's start width and the page's minimum both fit.
    static let minimumSplitWidth = TimeRailView.width + dividerWidth + pageMinWidth

    /// The rail's widest allowed width in a split this wide, never under the rail's start width.
    static func railCeiling(splitWidth: CGFloat, dividerThickness: CGFloat = dividerWidth) -> CGFloat {
        guard splitWidth > 0 else { return TimeRailView.maxWidth }
        return TimeRailView.clampedWidth(splitWidth - pageMinWidth - dividerThickness)
    }

    /// Placements at one target and split width, each within the window of the last, after which the
    /// watch leaves the split at its own width.
    static let placementRepeatLimit = 10
    static let placementRepeatWindow: TimeInterval = 2

    /// The `userInfo` keys `NSSplitView.didResizeSubviewsNotification` documents.
    static let dividerIndexKey = "NSSplitViewDividerIndex"
    static let userResizeKey = "NSSplitViewUserResizeKey"
}

/// Keeps the leading pane at the person's width within the split's ceiling, and reports their divider moves.
private struct DividerWatch: NSViewRepresentable {
    let startWidth: CGFloat
    let records: Bool
    let onMove: @MainActor (CGFloat) -> Void
    let leftMouseIsDown: @MainActor () -> Bool
    let clock: @MainActor () -> TimeInterval

    func makeNSView(context: Context) -> DividerWatchView {
        let view = DividerWatchView()
        view.setAccessibilityElement(false)
        view.preferredWidth = startWidth
        view.records = records
        view.onMove = onMove
        view.leftMouseIsDown = leftMouseIsDown
        view.clock = clock
        return view
    }

    func updateNSView(_ view: DividerWatchView, context: Context) {
        view.setRecords(records)
        view.onMove = onMove
        view.leftMouseIsDown = leftMouseIsDown
        view.clock = clock
        view.adopt(startWidth)
    }

    static func dismantleNSView(_ view: DividerWatchView, coordinator: ()) {
        view.retire()
    }
}

private final class DividerWatchView: NSView {
    static let logger = Logger(subsystem: FormFactor.backdrop.loggerSubsystem, category: "timeline")
    /// The stored width at mount, then each divider move. `HSplitView` opens a pane at its
    /// minimum, so the watch places the divider itself.
    var preferredWidth: CGFloat = TimeRailView.width
    var onMove: (@MainActor (CGFloat) -> Void)?
    /// Off for a resting card: a resize is then placed back rather than taken as the person's.
    var records = true
    var leftMouseIsDown: @MainActor () -> Bool = { false }
    var clock: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private weak var split: NSSplitView?
    /// Set by SwiftUI's dismantle, after which the watch does not attach again.
    private var retired = false
    private var placementQueued = false
    /// Set by a resize that changed the split's own width, until the next main-queue turn.
    private var splitResizedThisTurn = false
    /// Set across the watch's own `setPosition`.
    private var placing = false
    private var recordPending = false
    /// Checks left before a pending record is written even with a button still held.
    private var releaseChecks = 0
    /// The split's and the leading pane's widths at the last notification: a divider drag moves the
    /// pane and leaves the split.
    private var lastSplitWidth: CGFloat?
    private var lastLeadingWidth: CGFloat?
    /// A placement the split did not take or kept undoing, not retried until the target or the split's width changes.
    private var failedPlacement: (target: CGFloat, splitWidth: CGFloat)?
    /// The last placement's target and split width, when it was made, and how many came in a row.
    private var lastPlacement: (target: CGFloat, splitWidth: CGFloat, at: TimeInterval, count: Int)?
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

    /// Not while a drag waits to be recorded, which places again, nor for the watch's own placement.
    /// A watch laid out before its split view was above it attaches then.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if split == nil, !retired, window != nil {
            attach()
        } else if !recordPending && !placing {
            queuePlacement()
        }
    }

    /// A stored width changed elsewhere, such as in the other presentation, unless this split's
    /// own drag is still waiting to be recorded.
    func adopt(_ width: CGFloat) {
        guard !recordPending, abs(width - preferredWidth) >= 0.5 else { return }
        preferredWidth = width
        queuePlacement()
    }

    /// Turning recording on, as the press that raises a card does, refuses held moves for that turn.
    /// Turning it off drops a drag still waiting, so the `adopt` that follows places the stored width.
    func setRecords(_ on: Bool) {
        guard on != records else { return }
        if on { markSplitResized() } else { recordPending = false }
        failedPlacement = nil
        lastPlacement = nil
        records = on
    }

    /// SwiftUI's dismantle: a drag still waiting is recorded on the next main-queue turn, outside the
    /// view update, since the record publishes.
    func retire() {
        retired = true
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
        guard !retired, window != nil, let split = enclosingSplitView() else { return }
        self.split = split
        observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: nil
        ) { [weak self, weak split] note in
            let userResize = (note.userInfo?[TimelineSplit.userResizeKey] as? NSNumber)?.boolValue == true
            let dividerMoved = note.userInfo?[TimelineSplit.dividerIndexKey] != nil
            let keys = (note.userInfo?.keys).map { names in names.map { "\($0)" }.sorted().joined(separator: ",") } ?? ""
            MainActor.assumeIsolated {
                // Case 13 reads these to learn which keys AppKit posts for a person's drag.
                DividerWatchView.logger.debug("timeline split resized, userInfo keys: \(keys, privacy: .public)")
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
        lastPlacement = nil
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
        let splitUnchanged = lastSplitWidth.map { abs($0 - width) < 0.5 } ?? false
        if !splitUnchanged { markSplitResized() }
        // A clamp that follows a window resize in the same turn is the split's, not the person's.
        let heldMove = dividerMoved && !splitResizedThisTurn && splitUnchanged && paneMoved && leftMouseIsDown()
        guard records, userResize || heldMove, split.arrangedSubviews.count > 1,
              let leading = split.arrangedSubviews.first, isDescendant(of: leading)
        else {
            return queuePlacement()
        }
        let granted = leading.frame.width
        // At the ceiling the split set the width, not the person, so a wider stored width stays, as in a squeeze.
        preferredWidth = granted < ceiling(of: split) - 0.5 ? granted : max(preferredWidth, granted)
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
        let held = leftMouseIsDown()
        guard !held || releaseChecks <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.recordWhenReleased() }
            return
        }
        // A bound that expires with the button still held records without placing under the pointer.
        recordDrag(thenPlace: !held)
    }

    /// Writes the person's width, then places the divider again, since `place()` skipped any resize
    /// that arrived while the record waited.
    private func recordDrag(thenPlace: Bool = true) {
        recordPending = false
        onMove?(preferredWidth)
        if thenPlace { queuePlacement() }
    }

    private func markSplitResized() {
        guard !splitResizedThisTurn else { return }
        splitResizedThisTurn = true
        DispatchQueue.main.async { [weak self] in self?.splitResizedThisTurn = false }
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
        let target = min(TimeRailView.clampedWidth(preferredWidth), ceiling(of: split))
        guard abs(leading.frame.width - target) >= 0.5 else {
            failedPlacement = nil
            return
        }
        if let failed = failedPlacement, abs(failed.target - target) < 0.5, abs(failed.splitWidth - width) < 0.5 {
            return
        }
        let now = clock()
        let repeats = lastPlacement.map {
            abs($0.target - target) < 0.5 && abs($0.splitWidth - width) < 0.5
                && now - $0.at < TimelineSplit.placementRepeatWindow ? $0.count + 1 : 1
        } ?? 1
        lastPlacement = (target, width, now, repeats)
        // Cleared a turn later, so a notification of this placement posted after the call is ignored too.
        placing = true
        split.setPosition(target, ofDividerAt: 0)
        DispatchQueue.main.async { [weak self] in self?.placing = false }
        lastLeadingWidth = leading.frame.width
        let refused = abs(leading.frame.width - target) >= 0.5
        failedPlacement = refused || repeats >= TimelineSplit.placementRepeatLimit ? (target, width) : nil
        if failedPlacement != nil {
            let pane = Double(leading.frame.width)
            Self.logger.notice(
                "timeline split kept its own width: target \(Double(target)), split \(Double(width)), pane \(pane)")
        }
    }

    /// The frame's ceiling, or the measured one where AppKit's divider is thicker, within SwiftUI's `maxWidth`.
    private func ceiling(of split: NSSplitView) -> CGFloat {
        TimelineSplit.railCeiling(
            splitWidth: split.bounds.width, dividerThickness: max(TimelineSplit.dividerWidth, split.dividerThickness))
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
