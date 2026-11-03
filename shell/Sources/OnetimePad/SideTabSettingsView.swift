import AppKit
import SwiftUI

struct SideTabSettingsView: View {
    @ObservedObject var model: BackdropModel
    @State private var displays = SideTabDisplays.current()

    var body: some View {
        Toggle("Show a side tab for the ambient panel", isOn: Binding(
            get: { model.sideTab.enabled },
            set: { enabled in
                if enabled && model.sideTab.displayID == nil {
                    model.sideTab.displayID = displays.first?.id
                }
                model.sideTab.enabled = enabled
            }))
            .disabled(!model.ambientPanelEnabled)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displays = SideTabDisplays.current()
            }
        if model.sideTab.enabled {
            Group {
                Picker("Side tab display", selection: $model.sideTab.displayID) {
                    Text("Choose a display").tag(String?.none)
                    ForEach(displays, id: \.id) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                    if let id = model.sideTab.displayID, !displays.contains(where: { $0.id == id }) {
                        Text("Disconnected display").tag(Optional(id))
                    }
                }
                Picker("Side tab edge", selection: $model.sideTab.edge) {
                    Text("Left").tag(SideTabEdge.left)
                    Text("Right").tag(SideTabEdge.right)
                }
                HStack {
                    Text("Top")
                    Slider(value: $model.sideTab.position, in: 0...1)
                        .accessibilityLabel("Side tab position")
                        .accessibilityValue("\(Int(model.sideTab.position * 100)) percent from top")
                    Text("Bottom")
                }
                Text("Click the tab to open today. It appears while the ambient panel is resting and unpinned, with the editor window closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if SideTabPlacement.frame(displayID: model.sideTab.displayID, edge: model.sideTab.edge,
                    position: model.sideTab.position, displays: displays) == nil {
                    Text("The selected edge is unavailable here. Choose another display, edge, or position away from the Dock and adjoining displays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!model.ambientPanelEnabled)
        }
    }
}
