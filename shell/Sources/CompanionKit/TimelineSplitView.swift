import SwiftUI

/// Shared native divider for the timeline and page content in both presentations.
public struct TimelineSplitView<Rail: View, Content: View>: View {
    let showsTimeline: Bool
    let rail: Rail
    let content: Content

    public init(
        showsTimeline: Bool,
        @ViewBuilder rail: () -> Rail,
        @ViewBuilder content: () -> Content
    ) {
        self.showsTimeline = showsTimeline
        self.rail = rail()
        self.content = content()
    }

    public var body: some View {
        HSplitView {
            if showsTimeline {
                rail
                    .frame(minWidth: TimeRailView.width, idealWidth: TimeRailView.width, maxWidth: 280)
            }
            content
                .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
    }
}
