import AppKit
import SwiftUI

struct PadInspectorView: View {
    @ObservedObject var model: PageModel
    @ObservedObject var pads: PadCatalog
    @Binding var routes: PadInspectorRoutes
    let showsNewPad: Bool
    @State private var removingPad: PadEntry?
    @State private var confirmingRemoval = false
    @State private var removalFailed = false
    @State private var applicationAnchor = PadViewAnchor()

    private var pad: PadEntry { pads.activePad }
    private var index: Int { pads.entries.firstIndex(where: { $0.id == pad.id }) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(CompanionL10n.string("pad.inspector.title")).font(.headline)
                Spacer()
                Button { model.isPadInspectorVisible = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(CompanionL10n.string("pad.inspector.close"))
                .accessibilityLabel(CompanionL10n.string("pad.inspector.close"))
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    name
                    if let failure = pads.loadFailure {
                        Text(failure).font(.callout).foregroundStyle(Color.emberText)
                    } else if pad.isScratch {
                        Text(CompanionL10n.string("pad.scratch.expiry"))
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        folders
                        applications
                    }
                    if removalFailed {
                        Text(CompanionL10n.string("pad.remove.failed"))
                            .font(.callout).foregroundStyle(Color.emberText)
                    }
                    // Always in view: ADR-0039 asks the attempt to state the storage limitation clearly.
                    VStack(alignment: .leading, spacing: 6) {
                        Text(CompanionL10n.string("pad.links.about")).font(.caption.weight(.semibold))
                        Text(CompanionL10n.string("pad.links.storage")).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            if showsNewPad {
                Divider()
                PadNewButton(model: model, routes: $routes).padding(16)
            }
        }
        .background(Color.panelBackground)
        .onChange(of: pad.id) { _ in removalFailed = false }
        .alert(CompanionL10n.format("pad.remove.title", removingPad?.name ?? ""),
               isPresented: $confirmingRemoval) {
            Button(CompanionL10n.string("pad.remove"), role: .destructive) {
                if let removingPad { removalFailed = !model.removePad(removingPad.id) }
                removingPad = nil
            }
            Button(CompanionL10n.string("pad.cancel"), role: .cancel) { removingPad = nil }
        } message: {
            Text(CompanionL10n.string("pad.remove.explanation"))
        }
    }

    private var name: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if routes.rename.pad == pad.id {
                    PadNameField(draft: Binding(get: { routes.rename.draft }, set: { routes.rename.edit($0) }),
                                 commit: { routes.rename.commit(in: model) },
                                 keep: { routes.rename.keep(pad.id) },
                                 keysMoved: model.editorKeysMayHaveMoved)
                } else {
                    Text(pad.name).font(.title2.weight(.semibold))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !pad.isScratch {
                    Menu {
                        Button(CompanionL10n.string("pad.rename.menu")) { routes.beginRename(pad) }
                        Divider()
                        Button(CompanionL10n.format("pad.move.up", pad.name)) { pads.moveUp(pad.id) }
                            .disabled(index <= 1)
                        Button(CompanionL10n.format("pad.move.down", pad.name)) { pads.moveDown(pad.id) }
                            .disabled(index == pads.entries.count - 1)
                        Divider()
                        Button(CompanionL10n.string("pad.remove.menu"), role: .destructive) {
                            routes.rename.keep()
                            removingPad = pad
                            confirmingRemoval = true
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(CompanionL10n.format("pad.actions", pad.name))
                    .disabled(pads.loadFailure != nil)
                }
            }
            if let refusal = routes.rename.refusal, routes.rename.pad == pad.id {
                Text(refusal).font(.caption).foregroundStyle(Color.emberText)
            }
            if PadShortcutMonitor.allows(number: index, keymap: model.keymap) {
                Text("⌘\(index)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CompanionL10n.string("pad.folder.heading")).font(.headline)
            if pad.folderPaths.isEmpty {
                Text(CompanionL10n.string("pad.folder.none")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(pad.folderPaths, id: \.self) { path in
                let label = PadFolderLabel(path: path)
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text(label.parent).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .help(path)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(path)
                    Spacer(minLength: 0)
                    Button { model.removeFolder(path, fromPad: pad.id) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(CompanionL10n.format("pad.folder.remove", path, pad.name))
                    .accessibilityLabel(CompanionL10n.format("pad.folder.remove", path, pad.name))
                }
            }
            Button { model.addFolder(toPad: pad.id) } label: {
                Label(CompanionL10n.string("pad.folder.add"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CompanionL10n.string("pad.app.menu")).font(.headline)
            if pad.applicationBundleIDs.isEmpty {
                Text(CompanionL10n.string("pad.app.none")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(pad.applicationBundleIDs, id: \.self) { bundleID in
                let app = model.runningAssociationApplications.first { $0.bundleIdentifier == bundleID }
                HStack(spacing: 10) {
                    Image(systemName: "app").foregroundStyle(.secondary)
                    Text(app?.localizedName ?? bundleID).font(.callout)
                        .lineLimit(2).truncationMode(.middle).help(bundleID)
                    Spacer(minLength: 0)
                    Button { model.removeApplication(bundleID, fromPad: pad.id) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(CompanionL10n.format("pad.app.remove", app?.localizedName ?? bundleID, pad.name))
                    .accessibilityLabel(CompanionL10n.format("pad.app.remove", app?.localizedName ?? bundleID, pad.name))
                }
            }
            Button(action: showApplications) {
                Label(CompanionL10n.string("pad.app.add"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .background(PadViewAnchorView(anchor: applicationAnchor))
        }
    }

    private func showApplications() {
        guard let view = applicationAnchor.view else { return }
        let selectedPad = pad.id
        let choices = PadApplicationChoice.choices(
            running: model.runningAssociationApplications.compactMap { app in
                app.bundleIdentifier.map { ($0, app.localizedName ?? $0) }
            }, associated: pad.applicationBundleIDs)
        let menu = PadApplicationChoice.menu(choices: choices) { choice in
            if choice.associated { model.removeApplication(choice.id, fromPad: selectedPad) }
            else { model.addApplication(choice.id, toPad: selectedPad) }
        }
        if choices.isEmpty {
            let item = NSMenuItem(title: CompanionL10n.string("pad.app.noRunning"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}

struct PadFolderLabel: Equatable {
    let name: String
    let parent: String

    init(path: String) {
        let url = URL(fileURLWithPath: path)
        name = url.lastPathComponent
        parent = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

private struct PadNameField: View {
    @Binding var draft: String
    let commit: () -> Void
    let keep: () -> Void
    let keysMoved: () -> Void
    @FocusState private var focused: Bool
    @State private var anchor = PadViewAnchor()

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1)
            .focused($focused)
            .background(PadViewAnchorView(anchor: anchor))
            .onSubmit(commit)
            .onExitCommand(perform: keep)
            .onChange(of: focused) { now in
                if now {
                    DispatchQueue.main.async {
                        guard focused, let editor = anchor.view?.window?.firstResponder as? NSTextView,
                              editor.isFieldEditor else { return }
                        editor.selectAll(nil)
                    }
                } else { keep() }
                keysMoved()
            }
            .task { await Task.yield(); if !Task.isCancelled { focused = true } }
            .accessibilityLabel(Text(CompanionL10n.string("pad.name")))
    }
}

@MainActor
struct PadInspectorRoutes {
    var creation = PadCreation()
    var rename = PadRename()

    mutating func beginRename(_ pad: PadEntry) { rename.open(pad) }

    mutating func beginCreating() {
        rename.keep()
        creation.isPresented = true
    }
}
