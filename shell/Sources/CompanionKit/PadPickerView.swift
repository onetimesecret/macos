import AppKit
import SwiftUI

/// Experimental pad chrome shared by the panel and primary editor.
public struct PadPickerView: View {
    @ObservedObject private var model: PageModel
    @Environment(\.presentationSurface) private var surface
    @StateObject private var keyboard = PadShortcutMonitor()
    @State private var menuOpen = false
    @State private var creatingPad = false
    @State private var newName = ""

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
            .accessibilityLabel("Choose pad, current pad \(model.pads.activePad.name)")
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
        .onDisappear { keyboard.stop() }
        .onChange(of: model.owner) { _ in
            keyboard.commandHeld = false
            menuOpen = false
        }
        .onReceive(keyboard.$selectedPad) { id in
            if id != nil { menuOpen = false }
        }
        .alert("New pad", isPresented: $creatingPad) {
            TextField("Pad name", text: $newName)
            Button("Create") {
                if let id = model.createPad(named: newName) { model.activatePad(id) }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private var folderTally: String {
        let count = model.pads.activePad.folderPaths.count
        return "\(count) \(count == 1 ? "folder" : "folders")"
    }

    private var pickerMenu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("PADS").font(.caption).foregroundStyle(.secondary).padding(8)
                ForEach(Array(model.pads.entries.enumerated()), id: \.element.id) { index, pad in
                    PadPickerCell(
                        model: model, pad: pad,
                        shortcut: keyboard.commandHeld && PadShortcutMonitor.allows(
                            number: index, keymap: model.keymap
                        ) && index <= 9 ? "⌘\(index)" : nil,
                        select: { model.activatePad(pad.id); menuOpen = false }
                    )
                }
                Divider().padding(.vertical, 6)
                Button("New pad…") { menuOpen = false; creatingPad = true }
                    .buttonStyle(.plain).padding(8)
                Toggle("App associations", isOn: Binding(
                    get: { model.pads.appAssociationsEnabled },
                    set: { model.pads.appAssociationsEnabled = $0 }
                ))
                .toggleStyle(.switch)
                Text("Use application context to suggest recent pads.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show full paths", isOn: Binding(
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
        .help(running.map { "Switch to \($0.localizedName ?? bundleID)" }
              ?? "\(bundleID) is not running")
        .accessibilityLabel("Switch to \(running?.localizedName ?? bundleID)")
    }
}

private struct PadPickerCell: View {
    @ObservedObject var model: PageModel
    let pad: PadEntry
    let shortcut: String?
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: select) {
                HStack {
                    Text(pad.name).lineLimit(1)
                    Spacer()
                    if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
                    if pad.id == model.pads.activeID { Image(systemName: "checkmark") }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if pad.isScratch {
                Text("Usual page expiry across restarts.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if pad.folderPaths.isEmpty {
                    Label("No folder linked", systemImage: "folder")
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
                        .buttonStyle(.plain).accessibilityLabel("Remove \(path) from \(pad.name)")
                    }
                }
                Button { model.addFolder(toPad: pad.id) } label: {
                    Label("Add folder…", systemImage: "plus").font(.caption)
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
                            Button("Remove \(applicationName(bundleID))") {
                                model.removeApplication(bundleID, fromPad: pad.id)
                            }
                        }
                    }
                } label: {
                    Label("Applications…", systemImage: "app").font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(10)
        .background(hovered ? Color.primary.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }

    private func applicationName(_ id: String) -> String {
        model.runningAssociationApplications.first { $0.bundleIdentifier == id }?.localizedName ?? id
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

    func install(model: PageModel, surface: PresentationOwner) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self, weak model] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let model, model.pads.isEnabled, model.owner == surface else { return false }
                self.commandHeld = event.modifierFlags.contains(.command)
                guard event.type == .keyDown,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                      NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil,
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
