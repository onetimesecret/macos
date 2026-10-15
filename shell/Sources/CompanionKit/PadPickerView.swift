import AppKit
import SwiftUI

/// The pad switcher shared by the card and the editor window's toolbar:
/// the active pad's name opens a menu of pads, New Pad… and Manage Pads…
/// (ADR-0039 Amendment 1). Folders, apps, renames and removals are the
/// Pads tab of Settings (`PadSettingsView`).
public struct PadPickerView: View {
    /// Where the picker stands: a row of its own over the card's page,
    /// or an item in the editor window's toolbar, which has its own inset.
    public enum Placement: Sendable { case row, toolbar }

    @ObservedObject private var model: PageModel
    private let placement: Placement
    @Environment(\.presentationSurface) private var surface
    @StateObject private var keyboard = PadShortcutMonitor()
    @State private var creating = false
    @State private var anchor = PadMenuAnchor()

    public init(model: PageModel, placement: Placement = .row) {
        self.model = model
        self.placement = placement
    }

    public var body: some View {
        HStack(spacing: 12) {
            Button(action: showMenu) {
                HStack(spacing: 8) {
                    Text(model.pads.activePad.name).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption)
                    if !model.pads.activePad.isScratch {
                        Label(folderTally, systemImage: "folder")
                            .font(.caption).foregroundStyle(Color.secondaryInk)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(PadMenuAnchorView(anchor: anchor))
            .accessibilityLabel(CompanionL10n.format("pad.picker.current", model.pads.activePad.name))
            Spacer(minLength: 0)
            if model.pads.appAssociationsEnabled {
                ForEach(model.pads.activePad.applicationBundleIDs, id: \.self) { bundleID in
                    applicationButton(bundleID)
                }
            }
        }
        .padding(.horizontal, placement == .row ? 12 : 4)
        .padding(.vertical, placement == .row ? 9 : 0)
        .onAppear { keyboard.install(model: model, surface: surface) }
        .onDisappear { keyboard.stop() }
        .sheet(isPresented: $creating) { PadCreateSheet(model: model, isPresented: $creating) }
    }

    /// The menu, built at each click so its checkmark and shortcuts are
    /// the catalog's and the keymap's as they stand, and dropped below
    /// the button as a pull-down.
    private func showMenu() {
        guard let view = anchor.view else { return }
        let menu = PadSwitcherMenu.menu(
            entries: PadSwitcherMenu.entries(
                pads: model.pads.entries, activeID: model.pads.activeID, keymap: model.keymap),
            select: { [model] id in model.activatePad(id) },
            newPad: { [$creating] in $creating.wrappedValue = true },
            manage: { [model] in model.openSettings(.pads) }
        )
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: view)
    }

    private var folderTally: String {
        let count = model.pads.activePad.folderPaths.count
        return CompanionL10n.format(count == 1 ? "pad.folder.one" : "pad.folder.many", count)
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

/// The pads as a native menu: each pad once, the active one checked in
/// the leading column, ⌘0 to ⌘9 shown where the keymap leaves the digit
/// to pads, then New Pad… and Manage Pads…. The shortcuts are labels:
/// `PadShortcutMonitor` is what switches on them.
enum PadSwitcherMenu {
    struct Entry: Equatable {
        let id: UUID
        let name: String
        let checked: Bool
        let digit: Int?
    }

    static func entries(pads: [PadEntry], activeID: UUID, keymap: ResolvedKeymap) -> [Entry] {
        pads.enumerated().map { index, pad in
            Entry(
                id: pad.id, name: pad.name, checked: pad.id == activeID,
                digit: PadShortcutMonitor.allows(number: index, keymap: keymap) ? index : nil)
        }
    }

    @MainActor
    static func menu(
        entries: [Entry],
        select: @escaping (UUID) -> Void,
        newPad: @escaping () -> Void,
        manage: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            let item = self.item(entry.name, { select(entry.id) })
            item.state = entry.checked ? .on : .off
            if let digit = entry.digit {
                item.keyEquivalent = String(digit)
                item.keyEquivalentModifierMask = .command
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(item(CompanionL10n.string("pad.new.menu"), newPad))
        menu.addItem(item(CompanionL10n.string("pad.manage.menu"), manage))
        return menu
    }

    @MainActor
    private static func item(_ title: String, _ perform: @escaping () -> Void) -> NSMenuItem {
        let action = PadMenuAction(perform)
        let item = NSMenuItem(title: title, action: #selector(PadMenuAction.fire(_:)), keyEquivalent: "")
        item.target = action
        // The menu holds its items and an item its represented object,
        // which keeps the weakly held target alive as long as the menu.
        item.representedObject = action
        return item
    }
}

/// One menu item's action, as a target AppKit can send to.
@MainActor
final class PadMenuAction: NSObject {
    private let perform: () -> Void

    init(_ perform: @escaping () -> Void) {
        self.perform = perform
    }

    @objc func fire(_ sender: Any?) {
        perform()
    }
}

/// The view the pad menu drops from, kept by reference so the button's
/// action can find it.
@MainActor
final class PadMenuAnchor {
    weak var view: NSView?
}

struct PadMenuAnchorView: NSViewRepresentable {
    let anchor: PadMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

/// The create sheet, from the switcher's New Pad… and the Pads tab's,
/// which Law 0007 exempts until a new row has a seat; a rename happens
/// in the pad's own row (`PadRename`).
struct PadCreateSheet: View {
    @ObservedObject var model: PageModel
    @Binding var isPresented: Bool
    @State private var draft = ""
    @State private var submitted = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CompanionL10n.string("pad.new.title"))
                .font(.headline)
            TextField(CompanionL10n.string("pad.name"), text: $draft)
                .onSubmit(submit)
            if let message = failure ?? PadNameDraft.validationMessage(draft),
               submitted || !draft.isEmpty {
                Text(message).font(.caption).foregroundStyle(Color.emberText)
            }
            HStack {
                Spacer()
                Button(CompanionL10n.string("pad.cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(CompanionL10n.string("pad.create"), action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 340)
        .onChange(of: draft) { _ in failure = nil }
    }

    private func submit() {
        submitted = true
        guard PadNameDraft.validationMessage(draft) == nil else { return }
        // Creating already activates the new pad; do not persist a second activation.
        if model.createPad(named: draft) != nil { isPresented = false }
        else { failure = CompanionL10n.string("pad.name.failed") }
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

/// One item of a pad's Applications pop-up: a running app or an
/// associated one, checked when it is associated.
struct PadApplicationChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let associated: Bool

    /// The running apps in their order, then any associated app that is
    /// not running, so an association can be unchecked while its app is quit.
    static func choices(
        running: [(bundleID: String, name: String)], associated: [String]
    ) -> [PadApplicationChoice] {
        var seen = Set<String>()
        var choices: [PadApplicationChoice] = []
        for app in running where seen.insert(app.bundleID).inserted {
            choices.append(.init(
                id: app.bundleID, name: app.name, associated: associated.contains(app.bundleID)))
        }
        for bundleID in associated where seen.insert(bundleID).inserted {
            choices.append(.init(id: bundleID, name: bundleID, associated: true))
        }
        return choices
    }

    /// The pop-up's menu: each choice once, checked when associated; a
    /// choice handed to `toggle` is the state it had when chosen.
    @MainActor
    static func menu(
        choices: [PadApplicationChoice], toggle: @escaping (PadApplicationChoice) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in choices {
            let action = PadMenuAction { toggle(choice) }
            let item = NSMenuItem(
                title: choice.name, action: #selector(PadMenuAction.fire(_:)), keyEquivalent: "")
            item.target = action
            item.representedObject = action
            item.state = choice.associated ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// The pad row's rename field from opening to ending (Law 0007), apart
/// from the SwiftUI field so a test drives the code the row runs. A
/// refusal is said under the field, in the row, rather than under a page
/// in another window.
@MainActor
struct PadRename {
    private var field = TabRename.Field()
    /// The pad whose row holds the field, or nil while it is shut.
    private(set) var pad: UUID?
    /// What the field refuses, said under it, if anything.
    private(set) var refusal: String?

    var draft: String { field.draft }
    var isOpen: Bool { pad != nil }
    var isRefusing: Bool { refusal != nil }

    /// Opens in `entry`'s row on its name; a field open on another pad keeps.
    mutating func open(_ entry: PadEntry) {
        guard pad != entry.id else { return }
        keep()
        field.open(on: entry.name)
        pad = entry.id
    }

    /// A keystroke in the field. A refusal already said is judged again,
    /// so the line never describes a draft the field no longer holds.
    mutating func edit(_ draft: String) {
        guard isOpen else { return }
        field.draft = draft
        guard isRefusing else { return }
        refusal = PadNameDraft.validationMessage(draft)
    }

    /// Return: an untouched draft keeps, a name the catalog cannot take is
    /// said under the field with the field still open, and any other renames.
    mutating func commit(in model: PageModel) {
        guard let pad, let opened = field.opened else { return }
        guard case .rename(let name) = TabRename.outcome(
            draft: field.draft, current: opened, committed: true
        ) else { return keep() }
        if let message = PadNameDraft.validationMessage(name) {
            refusal = message
            return
        }
        guard model.renamePad(pad, to: name) else {
            refusal = CompanionL10n.string("pad.name.failed")
            return
        }
        shut()
    }

    /// Escape, the keyboard leaving, or the tab closing: the name stands.
    /// A row's ending names its pad, so a field moved to another row stays.
    mutating func keep(_ id: UUID? = nil) {
        guard isOpen, id == nil || id == pad else { return }
        shut()
    }

    private mutating func shut() {
        _ = field.end(committed: false)
        pad = nil
        refusal = nil
    }
}

/// App-local interception, never a system-wide hotkey or activity observer.
@MainActor
final class PadShortcutMonitor: ObservableObject {
    // AppKit monitor tokens are not Sendable; registration and use happen on
    // main. Their removal is also safe during a nonisolated deinitialization.
    private nonisolated(unsafe) var monitor: Any?

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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak model] event in
            let consumed = MainActor.assumeIsolated {
                guard let model, model.pads.isEnabled, model.owner == surface,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                      Self.allowsPadSwitch(isModal: NSApp.modalWindow != nil, windows: NSApp.windows),
                      let key = event.charactersIgnoringModifiers, let number = Int(key),
                      (0...9).contains(number), Self.allows(number: number, keymap: model.keymap)
                else { return false }
                // A claimed digit with no pad must not fall through to a slot.
                guard model.pads.entries.indices.contains(number) else { return true }
                model.activatePad(model.pads.entries[number].id)
                return true
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
