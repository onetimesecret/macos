import AppKit
import SwiftUI

/// Experimental pad chrome shared by the panel and primary editor.
public struct PadPickerView: View {
    @ObservedObject private var model: PageModel
    @Environment(\.presentationSurface) private var surface
    @StateObject private var keyboard = PadShortcutMonitor()
    @State private var menuOpen = false
    @State private var namingPad = false
    @State private var removingPad: PadEntry?
    @State private var confirmingRemoval = false
    @State private var nameDraft = ""
    @State private var nameSubmitted = false
    @State private var nameFailure: String?
    @State private var padRename = PadRename()

    public init(model: PageModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 12) {
            Button { menuOpen.toggle() } label: {
                HStack(spacing: 8) {
                    Text(model.pads.activePad.name).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption)
                    if !model.pads.activePad.isScratch {
                        Label(folderTally, systemImage: "folder")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CompanionL10n.format("pad.picker.current", model.pads.activePad.name))
            .popover(isPresented: $menuOpen, arrowEdge: .bottom) { pickerMenu }
            Spacer(minLength: 0)
            if model.pads.appAssociationsEnabled {
                ForEach(model.pads.activePad.applicationBundleIDs, id: \.self) { bundleID in
                    applicationButton(bundleID)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .font(.system(.body, design: .monospaced))
        .onAppear { keyboard.install(model: model, surface: surface) }
        .onDisappear {
            keyboard.stop()
            padRename.keep(in: model)
        }
        .onChange(of: model.owner) { _ in
            keyboard.commandHeld = false
            menuOpen = false
        }
        .onChange(of: menuOpen) { open in
            if !open { padRename.keep(in: model) }
        }
        .onReceive(keyboard.$selectedPad) { id in
            if id != nil { menuOpen = false }
        }
        .sheet(isPresented: $namingPad) { nameEditor }
        .alert(CompanionL10n.format("pad.remove.title", removingPad?.name ?? ""),
               isPresented: $confirmingRemoval) {
            Button(CompanionL10n.string("pad.remove"), role: .destructive) {
                if let pad = removingPad, !model.removePad(pad.id) {
                    model.flash(CompanionL10n.string("pad.remove.failed"))
                }
                removingPad = nil
            }
            Button(CompanionL10n.string("pad.cancel"), role: .cancel) { removingPad = nil }
        } message: {
            Text(CompanionL10n.string("pad.remove.explanation"))
        }
    }

    /// The create sheet, which Law 0007 exempts until a new cell has a seat;
    /// a rename happens in the pad's own cell (`PadRename`).
    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CompanionL10n.string("pad.new.title"))
                .font(.headline)
            TextField(CompanionL10n.string("pad.name"), text: $nameDraft)
                .onSubmit { submitName() }
            if let message = nameFailure ?? PadNameDraft.validationMessage(nameDraft),
               nameSubmitted || !nameDraft.isEmpty {
                Text(message).font(.caption).foregroundStyle(Color.emberText)
            }
            HStack {
                Spacer()
                Button(CompanionL10n.string("pad.cancel")) { namingPad = false }
                    .keyboardShortcut(.cancelAction)
                Button(CompanionL10n.string("pad.create")) { submitName() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 340)
        .onChange(of: nameDraft) { _ in nameFailure = nil }
    }

    private func beginCreating() {
        nameDraft = ""
        nameSubmitted = false
        nameFailure = nil
        menuOpen = false
        namingPad = true
    }

    private func submitName() {
        nameSubmitted = true
        guard PadNameDraft.validationMessage(nameDraft) == nil else { return }
        // Creating already activates the new pad; do not persist a second activation.
        if model.createPad(named: nameDraft) != nil { namingPad = false }
        else { nameFailure = CompanionL10n.string("pad.name.failed") }
    }

    private var folderTally: String {
        let count = model.pads.activePad.folderPaths.count
        return CompanionL10n.format(count == 1 ? "pad.folder.one" : "pad.folder.many", count)
    }

    private var pickerMenu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(CompanionL10n.string("pad.picker.heading")).font(.caption).foregroundStyle(.secondary).padding(8)
                ForEach(Array(model.pads.entries.enumerated()), id: \.element.id) { index, pad in
                    PadPickerCell(
                        model: model, pad: pad,
                        shortcut: keyboard.commandHeld && PadShortcutMonitor.allows(
                            number: index, keymap: model.keymap
                        ) && index <= 9 ? "⌘\(index)" : nil,
                        renaming: padRename.pad == pad.id,
                        draft: Binding(
                            get: { padRename.draft },
                            set: { padRename.edit($0, in: model) }
                        ),
                        select: { model.activatePad(pad.id); menuOpen = false },
                        rename: { padRename.open(pad, in: model) },
                        commitRename: { padRename.commit(in: model) },
                        keepRename: { padRename.keep(pad.id, in: model) },
                        remove: { removingPad = pad; menuOpen = false; confirmingRemoval = true }
                    )
                }
                Divider().padding(.vertical, 6)
                Button(CompanionL10n.string("pad.new.menu")) { beginCreating() }
                    .buttonStyle(.plain).padding(8)
                Toggle(CompanionL10n.string("pad.app.enabled"), isOn: Binding(
                    get: { model.pads.appAssociationsEnabled },
                    set: { model.pads.appAssociationsEnabled = $0 }
                ))
                .toggleStyle(.switch)
                Text(CompanionL10n.string("pad.app.caption"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(CompanionL10n.string("pad.paths.full"), isOn: Binding(
                    get: { model.pads.showFullPaths }, set: { model.pads.showFullPaths = $0 }
                ))
                .toggleStyle(.switch).padding(.top, 8)
            }
            .padding(10)
        }
        .frame(width: 350).frame(maxHeight: 620)
    }

    @ViewBuilder
    private func applicationButton(_ bundleID: String) -> some View {
        let running = model.runningAssociationApplications.first { $0.bundleIdentifier == bundleID }
        Button { model.activateAssociatedApplication(bundleID) } label: {
            if let image = running?.icon {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed").frame(width: 22, height: 22)
            }
        }
        .buttonStyle(.plain)
        .disabled(running == nil)
        .help(running.map { CompanionL10n.format("pad.app.switch", $0.localizedName ?? bundleID) }
              ?? CompanionL10n.format("pad.app.notRunningName", bundleID))
        .accessibilityLabel(CompanionL10n.format("pad.app.switch", running?.localizedName ?? bundleID))
    }
}

private struct PadPickerCell: View {
    @ObservedObject var model: PageModel
    let pad: PadEntry
    let shortcut: String?
    let renaming: Bool
    @Binding var draft: String
    let select: () -> Void
    let rename: () -> Void
    let commitRename: () -> Void
    let keepRename: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if renaming {
                    PadNameField(draft: $draft, commit: commitRename, keep: keepRename)
                    trailingMarks
                } else {
                    Button(action: select) {
                        HStack {
                            Text(pad.name).lineLimit(1)
                            trailingMarks
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !pad.isScratch {
                    Menu {
                        Button(CompanionL10n.string("pad.rename.menu"), action: rename)
                        Button(CompanionL10n.string("pad.remove.menu"), role: .destructive, action: remove)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(CompanionL10n.format("pad.actions", pad.name))
                }
            }
            if pad.isScratch {
                Text(CompanionL10n.string("pad.scratch.expiry"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if pad.folderPaths.isEmpty {
                    Label(CompanionL10n.string("pad.folder.none"), systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(pad.folderPaths, id: \.self) { path in
                    HStack {
                        Label(model.pads.showFullPaths ? path : URL(fileURLWithPath: path).lastPathComponent,
                              systemImage: "folder")
                            .font(.caption).foregroundStyle(.secondary).help(path)
                        Spacer(minLength: 8)
                        Button { model.removeFolder(path, fromPad: pad.id) } label: {
                            Image(systemName: "xmark").font(.caption)
                        }
                        .buttonStyle(.plain).accessibilityLabel(CompanionL10n.format("pad.folder.remove", path, pad.name))
                    }
                }
                Button { model.addFolder(toPad: pad.id) } label: {
                    Label(CompanionL10n.string("pad.folder.add"), systemImage: "plus").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if model.pads.appAssociationsEnabled {
                Menu {
                    ForEach(model.runningAssociationApplications, id: \.processIdentifier) { app in
                        if let bundleID = app.bundleIdentifier {
                            Button(app.localizedName ?? bundleID) {
                                model.addApplication(bundleID, toPad: pad.id)
                            }
                            .disabled(pad.applicationBundleIDs.contains(bundleID))
                        }
                    }
                    if !pad.applicationBundleIDs.isEmpty {
                        Divider()
                        ForEach(pad.applicationBundleIDs, id: \.self) { bundleID in
                            Button(CompanionL10n.format("pad.app.remove", applicationName(bundleID))) {
                                model.removeApplication(bundleID, fromPad: pad.id)
                            }
                        }
                    }
                } label: {
                    Label(CompanionL10n.string("pad.app.menu"), systemImage: "app").font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(10)
        .background(hovered ? Color.primary.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }

    @ViewBuilder private var trailingMarks: some View {
        Spacer()
        if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
        if pad.id == model.pads.activeID { Image(systemName: "checkmark") }
    }

    private func applicationName(_ id: String) -> String {
        model.runningAssociationApplications.first { $0.bundleIdentifier == id }?.localizedName ?? id
    }
}

/// The pad's name as a field in its own cell (Law 0007): Return commits,
/// Escape and the keyboard leaving keep, and nothing asks.
private struct PadNameField: View {
    @Binding var draft: String
    let commit: () -> Void
    let keep: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: keep)
            .onChange(of: focused) { now in
                if now { TabRename.selectWholeDraft() } else { keep() }
            }
            // On the next turn, once the field is in the popover's window.
            .onAppear { DispatchQueue.main.async { focused = true } }
            .accessibilityLabel(Text(CompanionL10n.string("pad.name")))
    }
}

/// Naming feedback is shared by create and rename, with the catalog enforcing
/// the same limits even when callers do not come through this view.
enum PadNameDraft {
    static func validationMessage(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return CompanionL10n.string("pad.name.empty") }
        if trimmed.count > 80 { return CompanionL10n.string("pad.name.long") }
        return nil
    }
}

/// The pad cell's rename field from opening to ending (Law 0007), apart
/// from the SwiftUI field so a test drives the code the cell runs.
@MainActor
struct PadRename {
    private var field = TabRename.Field()
    /// The pad whose cell holds the field, or nil while it is shut.
    private(set) var pad: UUID?
    /// The refusal standing in the line under the page, if one is.
    private var refusal: PageModel.NoticeHold?

    var draft: String { field.draft }
    var isOpen: Bool { pad != nil }
    var isRefusing: Bool { refusal != nil }

    /// Opens in `entry`'s cell on its name; a field open on another pad keeps.
    mutating func open(_ entry: PadEntry, in model: PageModel) {
        guard pad != entry.id else { return }
        keep(in: model)
        field.open(on: entry.name)
        pad = entry.id
    }

    /// A keystroke in the field. A refusal already said is judged again,
    /// so the line never describes a draft the field no longer holds.
    mutating func edit(_ draft: String, in model: PageModel) {
        guard isOpen else { return }
        field.draft = draft
        guard refusal != nil else { return }
        if let message = PadNameDraft.validationMessage(draft) {
            refuse(message, in: model)
        } else {
            release(in: model)
        }
    }

    /// Return: an untouched draft keeps, a name the catalog cannot take is
    /// said under the page with the field still open, and any other renames.
    mutating func commit(in model: PageModel) {
        guard let pad, let opened = field.opened else { return }
        guard case .rename(let name) = TabRename.outcome(
            draft: field.draft, current: opened, committed: true
        ) else { return keep(in: model) }
        if let message = PadNameDraft.validationMessage(name) {
            return refuse(message, in: model)
        }
        guard model.renamePad(pad, to: name) else {
            return refuse(CompanionL10n.string("pad.name.failed"), in: model)
        }
        shut(in: model)
    }

    /// Escape, the keyboard leaving, or the list closing: the name stands.
    /// A cell's ending names its pad, so a field moved to another cell stays.
    mutating func keep(_ id: UUID? = nil, in model: PageModel) {
        guard isOpen, id == nil || id == pad else { return }
        shut(in: model)
    }

    private mutating func refuse(_ message: String, in model: PageModel) {
        guard refusal == nil || model.notice != message else { return }
        refusal = model.holdNotice(message)
    }

    private mutating func release(in model: PageModel) {
        if let refusal { model.releaseNotice(refusal) }
        refusal = nil
    }

    private mutating func shut(in model: PageModel) {
        _ = field.end(committed: false)
        pad = nil
        release(in: model)
    }
}

/// App-local interception, never a system-wide hotkey or activity observer.
@MainActor
final class PadShortcutMonitor: ObservableObject {
    @Published var commandHeld = false
    @Published var selectedPad: UUID?
    // AppKit monitor tokens are not Sendable; registration and use happen on
    // main. Their removal is also safe during a nonisolated deinitialization.
    private nonisolated(unsafe) var monitor: Any?
    private nonisolated(unsafe) var resignObserver: NSObjectProtocol?

    /// User-remapped digit bindings retain their existing command. A digit
    /// still assigned to its bundled page selector can be reclaimed by the
    /// opt-in experiment. Scratch's unbound zero has the same boundary.
    nonisolated static func allows(number: Int, keymap: ResolvedKeymap) -> Bool {
        guard (0...9).contains(number),
              case .success(let stroke) = Keystroke.parse("cmd-\(number)") else { return false }
        guard keymap.explicitlyUnbound[.editor]?.contains(stroke) != true else { return false }
        let existing = keymap.command(for: stroke, in: .editor)
        return number == 0 ? existing == nil : existing?.selectsPageNumber == number
    }

    /// Pad selection is shared across windows, so a sheet in any app window
    /// suspends these application-local shortcuts even if another window is key.
    static func allowsPadSwitch(isModal: Bool, windows: [NSWindow]) -> Bool {
        !isModal && !windows.contains { $0.attachedSheet != nil || $0.sheetParent != nil }
    }

    func install(model: PageModel, surface: PresentationOwner) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self, weak model] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let model, model.pads.isEnabled, model.owner == surface else { return false }
                self.commandHeld = event.modifierFlags.contains(.command)
                guard event.type == .keyDown,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                      Self.allowsPadSwitch(isModal: NSApp.modalWindow != nil, windows: NSApp.windows),
                      let key = event.charactersIgnoringModifiers, let number = Int(key),
                      (0...9).contains(number), Self.allows(number: number, keymap: model.keymap)
                else { return false }
                // A claimed digit with no pad must not fall through to a slot.
                guard model.pads.entries.indices.contains(number) else { return true }
                let pad = model.pads.entries[number]
                model.activatePad(pad.id)
                self.selectedPad = pad.id
                return true
            }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.commandHeld = false } }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil; resignObserver = nil; commandHeld = false
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
