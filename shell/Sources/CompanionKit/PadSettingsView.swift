import AppKit
import SwiftUI

/// The Pads tab of Settings: the experiment's switch, and with it on the
/// pads with their folders and apps, renamed in place and removed behind
/// the platform's confirmation (ADR-0039 Amendment 1). Switching pads is
/// the switcher's menu (`PadPickerView`), not this list's.
public struct PadSettingsView: View {
    @ObservedObject private var model: PageModel
    @ObservedObject private var pads: PadCatalog
    @State private var routes = PadSettingsRoutes()
    @State private var removingPad: PadEntry?
    @State private var confirmingRemoval = false
    @State private var removalFailed = false

    public init(model: PageModel) {
        self.model = model
        self.pads = model.pads
    }

    public var body: some View {
        Form {
            Section {
                Toggle(CompanionL10n.string("pad.settings.enabled"), isOn: Binding(
                    get: { pads.isEnabled }, set: { pads.isEnabled = $0 }
                ))
                .disabled(pads.loadFailure != nil)
                if let failure = pads.loadFailure {
                    Text(failure).font(.caption).foregroundStyle(Color.emberText)
                }
            } header: {
                SettingsCaption(CompanionL10n.string("pad.settings.caption"))
            } footer: {
                SettingsCaption(CompanionL10n.string("pad.settings.storage"))
            }
            if pads.isEnabled {
                Section {
                    ForEach(pads.entries) { pad in
                        PadSettingsRow(
                            model: model, pad: pad,
                            renaming: routes.rename.pad == pad.id,
                            refusal: routes.rename.pad == pad.id ? routes.rename.refusal : nil,
                            draft: Binding(
                                get: { routes.rename.draft },
                                set: { routes.rename.edit($0) }
                            ),
                            rename: { routes.beginRename(pad) },
                            commitRename: { routes.rename.commit(in: model) },
                            keepRename: { routes.rename.keep(pad.id) },
                            remove: { routes.rename.keep(); removingPad = pad; confirmingRemoval = true }
                        )
                    }
                    if removalFailed {
                        Text(CompanionL10n.string("pad.remove.failed"))
                            .font(.caption).foregroundStyle(Color.emberText)
                    }
                    Button(CompanionL10n.string("pad.new.menu")) { routes.beginCreating() }
                } header: {
                    Text(CompanionL10n.string("pad.picker.heading"))
                }
                Section {
                    Toggle(CompanionL10n.string("pad.app.enabled"), isOn: Binding(
                        get: { pads.appAssociationsEnabled },
                        set: { pads.appAssociationsEnabled = $0 }
                    ))
                } footer: {
                    SettingsCaption(CompanionL10n.string("pad.app.caption"))
                }
                Section {
                    Toggle(CompanionL10n.string("pad.paths.full"), isOn: Binding(
                        get: { pads.showFullPaths }, set: { pads.showFullPaths = $0 }
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { routes.rename.keep() }
        .sheet(isPresented: $routes.creating) {
            PadCreateSheet(model: model, isPresented: $routes.creating)
        }
        .alert(CompanionL10n.format("pad.remove.title", removingPad?.name ?? ""),
               isPresented: $confirmingRemoval) {
            Button(CompanionL10n.string("pad.remove"), role: .destructive) {
                if let pad = removingPad { removalFailed = !model.removePad(pad.id) }
                removingPad = nil
            }
            Button(CompanionL10n.string("pad.cancel"), role: .cancel) { removingPad = nil }
        } message: {
            Text(CompanionL10n.string("pad.remove.explanation"))
        }
    }
}

/// One pad in the Pads tab: its name, or the rename field over it, with
/// the actions menu at the trailing edge, and under the name its folders
/// and its Applications pop-up, on the name's leading edge.
private struct PadSettingsRow: View {
    @ObservedObject var model: PageModel
    let pad: PadEntry
    let renaming: Bool
    let refusal: String?
    @Binding var draft: String
    let rename: () -> Void
    let commitRename: () -> Void
    let keepRename: () -> Void
    let remove: () -> Void
    @State private var anchor = PadMenuAnchor()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if renaming {
                    PadNameField(
                        draft: $draft, commit: commitRename, keep: keepRename,
                        keysMoved: model.editorKeysMayHaveMoved)
                } else {
                    Text(pad.name).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !pad.isScratch {
                    Menu {
                        Button(CompanionL10n.string("pad.rename.menu"), action: rename)
                        Button(CompanionL10n.string("pad.remove.menu"), role: .destructive, action: remove)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(CompanionL10n.format("pad.actions", pad.name))
                }
            }
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(Color.emberText)
            }
            if pad.isScratch {
                Text(CompanionL10n.string("pad.scratch.expiry"))
                    .font(.caption).foregroundStyle(Color.secondaryInk)
            } else {
                folders
            }
            if model.pads.appAssociationsEnabled, !pad.isScratch {
                applications
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var folders: some View {
        if pad.folderPaths.isEmpty {
            Label(CompanionL10n.string("pad.folder.none"), systemImage: "folder")
                .font(.caption).foregroundStyle(Color.secondaryInk)
        }
        ForEach(pad.folderPaths, id: \.self) { path in
            HStack {
                Label(model.pads.showFullPaths ? path : URL(fileURLWithPath: path).lastPathComponent,
                      systemImage: "folder")
                    .font(.caption).foregroundStyle(Color.secondaryInk).help(path)
                Spacer(minLength: 8)
                Button { model.removeFolder(path, fromPad: pad.id) } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(CompanionL10n.format("pad.folder.remove", path, pad.name))
            }
        }
        Button { model.addFolder(toPad: pad.id) } label: {
            Label(CompanionL10n.string("pad.folder.add"), systemImage: "plus").font(.caption)
        }
        .buttonStyle(.borderless)
    }

    /// One pop-up whose items carry their state as menu checkmarks: a
    /// running app toggles on and off, and an associated app that is not
    /// running stays listed, checked. A button that drops an AppKit menu,
    /// so its label stands at its peers' size, as a SwiftUI pop-up's does not.
    private var applications: some View {
        Button(action: showApplications) {
            HStack(spacing: 4) {
                Label(CompanionL10n.string("pad.app.menu"), systemImage: "macwindow")
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .background(PadMenuAnchorView(anchor: anchor))
    }

    private func showApplications() {
        guard let view = anchor.view else { return }
        let menu = PadApplicationChoice.menu(
            choices: PadApplicationChoice.choices(
                running: model.runningAssociationApplications.compactMap { app in
                    app.bundleIdentifier.map { ($0, app.localizedName ?? $0) }
                },
                associated: pad.applicationBundleIDs),
            toggle: { [model, pad] choice in
                if choice.associated { model.removeApplication(choice.id, fromPad: pad.id) }
                else { model.addApplication(choice.id, toPad: pad.id) }
            })
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: view)
    }
}

/// The pad's name as a field in its own row (Law 0007): Return commits,
/// Escape and the keyboard leaving keep, and nothing asks.
private struct PadNameField: View {
    @Binding var draft: String
    let commit: () -> Void
    let keep: () -> Void
    /// The field is in the Settings window, where the page sees no keys move.
    let keysMoved: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: keep)
            .onChange(of: focused) { now in
                if now { TabRename.selectWholeDraft() } else { keep() }
                keysMoved()
            }
            // On the next turn, once the field is in the window.
            .onAppear { DispatchQueue.main.async { focused = true } }
            .accessibilityLabel(Text(CompanionL10n.string("pad.name")))
    }
}

/// What the Pads tab has up: the create sheet and a row's rename field,
/// apart from the view so a test drives the routes its buttons take.
@MainActor
struct PadSettingsRoutes {
    var creating = false
    var rename = PadRename()

    /// *Rename*: the field opens in the pad's row.
    mutating func beginRename(_ pad: PadEntry) {
        rename.open(pad)
    }

    /// *New Pad…*: the create sheet, which Law 0007 exempts, with any
    /// open field's name kept.
    mutating func beginCreating() {
        rename.keep()
        creating = true
    }
}
