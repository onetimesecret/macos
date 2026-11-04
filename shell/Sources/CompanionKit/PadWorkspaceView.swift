import AppKit
import SwiftUI

struct PadWorkspaceLayout: Equatable {
    let showsPadList: Bool
    let showsEditor: Bool
    let inspectorWidth: CGFloat?

    init(width: CGFloat, inspecting: Bool) {
        showsPadList = inspecting && width >= 560
        showsEditor = !inspecting || width >= 900
        inspectorWidth = inspecting && width >= 900 ? 296 : nil
    }
}

/// The editor stays mounted while compact windows use its space for pad details.
public struct PadWorkspaceView<Content: View>: View {
    @ObservedObject private var model: PageModel
    @ObservedObject private var pads: PadCatalog
    private let readOnly: Bool
    private let content: Content
    @State private var routes = PadInspectorRoutes()
    @State private var anchor = PadViewAnchor()

    public init(model: PageModel, readOnly: Bool = false, @ViewBuilder content: () -> Content) {
        self.model = model
        self.pads = model.pads
        self.readOnly = readOnly
        self.content = content()
    }

    public var body: some View {
        GeometryReader { geometry in
            let layout = PadWorkspaceLayout(width: geometry.size.width, inspecting: model.isPadInspectorVisible)
            HStack(spacing: 0) {
                if layout.showsPadList {
                    VStack(spacing: 0) {
                        navigation
                        PadSidebarView(model: model, pads: pads, routes: $routes)
                    }
                    .frame(width: 180)
                    Divider()
                } else if !model.isPadInspectorVisible && model.showsPagesDownSide && !model.isPageExpanded {
                    VStack(spacing: 0) {
                        navigation
                        TimeRailView(model: model, readOnly: readOnly)
                    }
                    .frame(width: TimeRailView.width)
                    Divider()
                }
                content
                    .frame(minWidth: 0, maxWidth: layout.showsEditor ? .infinity : 0,
                           maxHeight: .infinity)
                    .clipped()
                    .opacity(layout.showsEditor ? 1 : 0)
                    .allowsHitTesting(layout.showsEditor)
                    .accessibilityHidden(!layout.showsEditor)
                if model.isPadInspectorVisible {
                    if layout.showsEditor { Divider() }
                    PadInspectorView(model: model, pads: pads, routes: $routes,
                                     showsNewPad: !layout.showsPadList)
                        .frame(width: layout.inspectorWidth)
                        .frame(maxWidth: layout.inspectorWidth == nil ? .infinity : nil)
                }
            }
            .background(PadViewAnchorView(anchor: anchor))
            .onChange(of: model.isPadInspectorVisible) { visible in
                if visible { resignEditor() }
                else { routes.rename.keep(); model.refocusEditorIfKeyed() }
            }
            .onChange(of: layout.showsEditor) { visible in
                if !visible { resignEditor() }
            }
        }
        .background(Color.panelBackground)
        .disabled(readOnly)
        .onChange(of: pads.activeID) { _ in routes.rename.keep() }
        .onDisappear { routes.rename.keep() }
    }

    private var navigation: some View {
        Picker(CompanionL10n.string("pad.navigation"), selection: $model.isPadInspectorVisible) {
            Text(CompanionL10n.string(model.showsTimeUnits ? "Timeline" : "Tabs")).tag(false)
            Text(CompanionL10n.string("pad.picker.heading")).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(8)
    }

    private func resignEditor() {
        guard let window = anchor.view?.window,
              let responder = window.firstResponder as? NSView,
              responder === model.activeEditor || responder is KeyGrantingClickView
                || responder is MarkdownPreviewView
                || ((responder as? NSTextView)?.isFieldEditor == true
                    && !routes.rename.isOpen && !model.hasPresentedPadCreation) else { return }
        window.makeFirstResponder(nil)
        model.editorKeysMayHaveMoved()
    }
}

private struct PadSidebarView: View {
    @ObservedObject var model: PageModel
    @ObservedObject var pads: PadCatalog
    @Binding var routes: PadInspectorRoutes

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(pads.entries.enumerated()), id: \.element.id) { index, pad in
                        Button { model.activatePad(pad.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: pad.isScratch ? "square.and.pencil" : "square.stack")
                                    .foregroundStyle(Color.secondary)
                                Text(pad.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                if PadShortcutMonitor.allows(number: index, keymap: model.keymap) {
                                    Text("⌘\(index)").font(.caption).foregroundStyle(Color.secondary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .background(pads.activeID == pad.id ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(pad.name)
                        .accessibilityAddTraits(pads.activeID == pad.id ? .isSelected : [])
                        .contextMenu {
                            if !pad.isScratch {
                                Button(CompanionL10n.format("pad.move.up", pad.name)) { pads.moveUp(pad.id) }
                                    .disabled(index <= 1)
                                Button(CompanionL10n.format("pad.move.down", pad.name)) { pads.moveDown(pad.id) }
                                    .disabled(index == pads.entries.count - 1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            Divider()
            PadNewButton(model: model, routes: $routes)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

struct PadNewButton: View {
    @ObservedObject var model: PageModel
    @Binding var routes: PadInspectorRoutes

    var body: some View {
        Button { routes.beginCreating() } label: {
            Label(CompanionL10n.string("pad.new.menu"), systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .disabled(model.pads.loadFailure != nil)
        .popover(isPresented: $routes.creation.isPresented, arrowEdge: .bottom) {
            PadCreateForm(model: model, creation: $routes.creation)
        }
    }
}
