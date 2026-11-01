import AppKit
import Carbon.HIToolbox
import Combine
import CompanionKit

@MainActor
final class CommandPaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private struct Row {
        let title: String
        let detail: String
        let shortcut: String?
        let command: CommandID?
        let scope: CommandPaletteScope?
        let tab: UInt64?
    }

    private let model: PageModel
    private let performWindowCommand: (CommandID) -> Void
    private let returnToPages: () -> Void
    private weak var originalWindow: NSWindow?
    private weak var originalResponder: NSResponder?
    private nonisolated(unsafe) weak var borrowedFocusResponder: (any CommandPaletteResponder)?
    private weak var originalEditor: NSTextView?
    private weak var originalControl: NSControl?
    private var originalControlSelection: NSRange?
    private var originalSelection: [NSValue] = []
    private weak var originalStorage: NSTextStorage?
    private var sourceWasEdited = false
    private var contextGeneration = UUID()
    private nonisolated(unsafe) var storageObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowCloseObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowResignObserver: NSObjectProtocol?
    private nonisolated(unsafe) var dateFormatObservers: [NSObjectProtocol] = []
    private var originalTarget: SurfaceTarget?
    private var originalPage: UInt64?
    private var originalLedger = false
    private var availableEditorCommands: Set<CommandID> = []
    private var hasPageContext = false
    private var modelObservation: AnyCancellable?
    private var modelChangeQueued = false
    private let realizedCells = NSHashTable<PaletteCommandCell>.weakObjects()
    private var rows: [Row] = []
    private var datedSource: [TabSummary] = []
    private var datedRows: [Row] = []
    private var datedLocale: String?
    private var datedTimeZone: String?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private var reopening = false
    private(set) var overlay: PaletteOverlayView?
    let search = NSSearchField()
    let table = PaletteTableView()
    private let scroll = NSScrollView()
    private let card = NSView()
    let backButton = NSButton(title: "", target: nil, action: nil)
    private let footer = NSTextField(labelWithString: "")

    init(model: PageModel, performWindowCommand: @escaping (CommandID) -> Void,
         returnToPages: @escaping () -> Void) {
        self.model = model
        self.performWindowCommand = performWindowCommand
        self.returnToPages = returnToPages
        super.init()
        search.delegate = self
        search.placeholderString = CompanionL10n.string("Search commands…")
        search.setAccessibilityLabel(CompanionL10n.string("Command Palette"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .fullWidth
        table.rowHeight = 42
        table.intercellSpacing = .zero
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(runSelected(_:))
        table.onCancel = { [weak self] in self?.dismiss(restoringFocus: true) }
        table.onRun = { [weak self] in self?.runSelected(nil) }
        table.setAccessibilityLabel(CompanionL10n.string("Commands"))
        table.backgroundColor = .controlBackgroundColor
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.shadowOpacity = 0.25
        card.layer?.shadowRadius = 16
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.bezelStyle = .inline
        backButton.setAccessibilityLabel(CompanionL10n.string("Back to Commands"))
        backButton.toolTip = CompanionL10n.string("Back to Commands")
        backButton.target = self
        backButton.action = #selector(showCommands(_:))
        card.addSubview(backButton)
        card.addSubview(search)
        card.addSubview(scroll)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        card.addSubview(footer)
        for name in [NSLocale.currentLocaleDidChangeNotification, NSNotification.Name.NSSystemTimeZoneDidChange] {
            dateFormatObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.datedLocale = nil
                    if self.overlay != nil, self.reopening { self.reload() }
                }
            })
        }
    }

    deinit {
        if let borrowed = borrowedFocusResponder {
            Task { @MainActor in borrowed.endPaletteFocusBorrow() }
        }
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        if let windowResignObserver { NotificationCenter.default.removeObserver(windowResignObserver) }
        for observer in dateFormatObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func show(in window: NSWindow, pageContext: Bool, reopen: Bool = false) {
        if overlay != nil {
            if originalWindow === window {
                if reopen { enterReopenMode() }
                else { dismiss(restoringFocus: true) }
                return
            }
        }
        guard let host = window.contentView else { return }
        if pageContext, let editor = model.activeEditor as? CommandPaletteResponder,
           !editor.prepareForCommandPalette() { return }
        if overlay != nil { dismiss(restoringFocus: false) }
        originalWindow = window
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
        }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: true) }
        }
        originalResponder = window.firstResponder
        originalControl = nil
        originalControlSelection = nil
        if let fieldEditor = window.firstResponder as? NSTextView, fieldEditor.isFieldEditor {
            originalControl = fieldEditor.delegate as? NSControl
            originalControlSelection = fieldEditor.selectedRange()
            originalResponder = originalControl
            originalEditor = nil
        } else {
            originalEditor = window.firstResponder as? NSTextView
        }
        originalSelection = originalEditor?.selectedRanges ?? []
        originalStorage = originalEditor?.textStorage
        sourceWasEdited = false
        contextGeneration = UUID()
        let generation = contextGeneration
        if let originalStorage {
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: originalStorage, queue: nil
            ) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        guard self?.contextGeneration == generation,
                              self?.originalStorage?.editedMask.contains(.editedCharacters) == true else { return }
                        self?.sourceWasEdited = true
                    }
                } else {
                    Task { @MainActor [weak self] in
                        guard self?.contextGeneration == generation else { return }
                        self?.sourceWasEdited = true
                    }
                }
            }
        }
        originalTarget = model.activeTarget
        originalPage = model.selectedPageID
        originalLedger = model.showingLedger
        availableEditorCommands = Set(CommandID.allCases.filter {
            (originalResponder as? CommandPaletteResponder)?.canPerformPaletteCommand($0) == true
        })
        hasPageContext = pageContext && originalControl == nil
        borrowedFocusResponder = originalResponder as? CommandPaletteResponder
        borrowedFocusResponder?.beginPaletteFocusBorrow()
        reopening = reopen
        search.stringValue = ""
        search.placeholderString = CompanionL10n.string(reopen ? "Search closed pages or tabs…" : "Search commands…")
        let overlay = PaletteOverlayView(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onOutsideClick = { [weak self] in self?.dismiss(restoringFocus: true) }
        overlay.onLayout = { [weak self] in self?.layout() }
        overlay.onKeyEquivalent = { [weak self] event in
            guard let self, (self.search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
            if event.keyCode == UInt16(kVK_Escape),
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                self.cancelSearchOrDismiss()
                return true
            }
            guard let command = self.model.keymap.command(for: event, in: .editor) else { return false }
            if command == .pageClose || command == .appCommandPalette {
                let modifiers = event.modifierFlags
                guard modifiers.contains(.command)
                    || (modifiers.contains(.control) && !modifiers.contains(.option)) else { return false }
                self.dismiss(restoringFocus: true)
                return true
            }
            guard event.modifierFlags.contains(.command) else { return false }
            if command.dispatch == .surface { self.dismiss(restoringFocus: true) }
            return false
        }
        overlay.interactiveRegion = card
        overlay.setAccessibilityRole(.group)
        overlay.setAccessibilityLabel(CompanionL10n.string("Command Palette"))
        overlay.setAccessibilityModal(true)
        overlay.addSubview(card)
        self.overlay = overlay
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.modelChangeQueued else { return }
                self.modelChangeQueued = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.modelChangeQueued = false
                    guard self.overlay != nil else { return }
                    self.reload()
                }
            }
        }
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        reload()
        layout()
        _ = window.makeFirstResponder(search)
        search.selectText(nil)
    }

    func dismiss(restoringFocus: Bool) {
        guard overlay != nil else { return }
        let borrowed = borrowedFocusResponder
        borrowedFocusResponder = nil
        defer { borrowed?.endPaletteFocusBorrow() }
        if !restoringFocus, let window = originalWindow {
            let responder = window.firstResponder
            if responder === search.currentEditor() || responder === table || responder === backButton {
                _ = window.makeFirstResponder(nil)
            }
        }
        overlay?.removeFromSuperview()
        overlay = nil
        contextGeneration = UUID()
        modelObservation = nil
        rows.removeAll()
        clearDatedCache()
        clearRealizedCells()
        table.reloadData()
        search.stringValue = ""
        footer.stringValue = ""
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
        storageObserver = nil
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        windowCloseObserver = nil
        if let windowResignObserver { NotificationCenter.default.removeObserver(windowResignObserver) }
        windowResignObserver = nil
        guard restoringFocus, let window = originalWindow, window.isVisible else { return }
        if let control = originalControl {
            guard control.window === window else { return }
            _ = window.makeFirstResponder(control)
            if let editor = control.currentEditor() as? NSTextView,
               let selection = originalControlSelection, NSMaxRange(selection) <= editor.string.utf16.count {
                editor.setSelectedRange(selection)
            }
            return
        }
        guard let responder = originalResponder else { return }
        if let view = responder as? NSView, view.window !== window { return }
        if let editor = originalEditor, contextIsCurrent,
           editor.window === window {
            let length = editor.string.utf16.count
            if originalSelection.allSatisfy({ NSMaxRange($0.rangeValue) <= length }) {
                editor.selectedRanges = originalSelection
            }
        }
        _ = window.makeFirstResponder(responder)
    }

    func dismissForClose(in window: NSWindow?) -> Bool {
        guard overlay != nil, originalWindow === window else { return false }
        dismiss(restoringFocus: true)
        return true
    }

    func isShowing(in window: NSWindow?) -> Bool {
        overlay != nil && originalWindow === window
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("paletteCommand")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? PaletteCommandCell)
            ?? PaletteCommandCell(title: "", detail: "", shortcut: nil)
        view.identifier = identifier
        realizedCells.add(view)
        view.configure(title: item.title, detail: item.detail, shortcut: item.shortcut)
        view.frame = NSRect(x: 0, y: 0, width: tableColumn?.width ?? tableView.bounds.width, height: 42)
        view.setAccessibilityLabel([item.title, item.detail, item.shortcut].compactMap { $0 }.joined(separator: ", "))
        return view
    }

    func controlTextDidChange(_ notification: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelSearchOrDismiss()
        case #selector(NSResponder.insertNewline(_:)):
            runSelected(nil)
        case #selector(NSResponder.deleteBackward(_:)) where reopening && search.stringValue.isEmpty:
            showCommands(nil)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
        default: return false
        }
        return true
    }

    private func cancelSearchOrDismiss() {
        if !search.stringValue.isEmpty {
            search.stringValue = ""
            reload()
        } else {
            dismiss(restoringFocus: true)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let index = min(max(0, table.selectedRow + delta), rows.count - 1)
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    @objc private func runSelected(_ sender: Any?) {
        let index = table.clickedRow >= 0 && sender != nil ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        if row.command == .pageReopenDated {
            enterReopenMode()
            return
        }
        let validContext = hasPageContext && contextIsCurrent
        dismiss(restoringFocus: true)
        if let tab = row.tab {
            if model.reopenClosedTab(tab) { returnToPages() }
            else { model.flash(CompanionL10n.string("palette.reopen_unavailable"), tone: .actionable) }
            return
        }
        guard let command = row.command else { return }
        if command.dispatch == .window {
            performWindowCommand(command)
        } else if command.dispatch == .editor {
            guard validContext, let editor = originalResponder as? CommandPaletteResponder else {
                refuseStaleContext()
                return
            }
            if !editor.performPaletteCommand(command) { refuseStaleContext() }
        } else {
            guard row.scope == .application || validContext else {
                refuseStaleContext()
                return
            }
            model.perform(command)
            if [.appOpenTimeline, .appSwitchToTabs, .pageReopenLast, .pageNew].contains(command) {
                returnToPages()
            }
        }
    }

    private func refuseStaleContext() {
        model.flash(CompanionL10n.string("palette.context_changed"), tone: .actionable)
    }

    private func enterReopenMode() {
        reopening = true
        search.stringValue = ""
        search.placeholderString = CompanionL10n.string("Search closed pages or tabs…")
        reload()
        _ = originalWindow?.makeFirstResponder(search)
    }

    @objc private func showCommands(_ sender: Any?) {
        reopening = false
        search.stringValue = ""
        search.placeholderString = CompanionL10n.string("Search commands…")
        reload()
        _ = originalWindow?.makeFirstResponder(search)
    }

    private func clearDatedCache() {
        datedSource.removeAll()
        datedRows.removeAll()
        datedLocale = nil
        datedTimeZone = nil
    }

    private func clearRealizedCells() {
        for cell in realizedCells.allObjects {
            cell.configure(title: "", detail: "", shortcut: nil)
            cell.toolTip = nil
            cell.setAccessibilityLabel(nil)
            cell.setAccessibilityHelp(nil)
        }
    }

    private func reload() {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
        if reopening {
            let source = model.closedTabs
            let locale = Locale.current.identifier
            let timeZone = TimeZone.current.identifier
            if source != datedSource || locale != datedLocale || timeZone != datedTimeZone {
                dateFormatter.locale = .current
                dateFormatter.timeZone = .current
                datedSource = source
                datedLocale = locale
                datedTimeZone = timeZone
                datedRows = source.map { tab in
                    let date = tab.pageCreatedMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                    let stamp = date.map { dateFormatter.string(from: $0) } ?? CompanionL10n.string("Saved tab")
                    return Row(title: tab.title, detail: stamp, shortcut: nil, command: nil, scope: nil, tab: tab.id)
                }
            }
            rows = datedRows.filter { row in
                let text = row.title + " " + row.detail
                return search.stringValue.split(whereSeparator: { $0.isWhitespace })
                    .allSatisfy { text.localizedStandardContains(String($0)) }
            }
        } else {
            clearDatedCache()
            rows = CommandPaletteCatalog.entries(keymap: model.keymap).compactMap { entry in
                let title = entry.command == .pageClose ? CompanionL10n.string(closeChoice.title) : entry.title
                guard entry.matches(search.stringValue, title: title), isAvailable(entry) else { return nil }
                return Row(title: title, detail: entry.scope.title,
                    shortcut: entry.shortcut, command: entry.command, scope: entry.scope, tab: nil)
            }
        }
        backButton.isHidden = !reopening
        search.nextKeyView = table
        table.nextKeyView = reopening ? backButton : search
        backButton.nextKeyView = search
        clearRealizedCells()
        table.reloadData()
        if !rows.isEmpty {
            let index = selected.flatMap { previous in
                rows.firstIndex { $0.command == previous.command && $0.tab == previous.tab }
            } ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        footer.stringValue = rows.isEmpty
            ? CompanionL10n.string(reopening ? "No closed pages or tabs" : "No matching commands")
            : CompanionL10n.string("↑↓ Select · Return Run · Esc Cancel")
        layout()
    }

    private func isAvailable(_ entry: CommandPaletteEntry) -> Bool {
        if entry.command == .pageReopenLast { return model.hasClosedTabs }
        if entry.command == .pageClose, !closeChoice.isEnabled { return false }
        if entry.command == .fileSaveAs || entry.command == .stateSaveNow {
            return hasPageContext && contextIsCurrent && CommandPalettePresentation.canSave(model.activeTarget)
        }
        if entry.scope == .application { return true }
        guard hasPageContext, contextIsCurrent else { return false }
        if entry.command.dispatch == .editor {
            return availableEditorCommands.contains(entry.command)
        }
        return true
    }

    private var closeChoice: CloseMenuItem {
        CloseMenuItem.resolve(target: .surface, showing: model.activeTarget,
            ledgerShowing: model.showingLedger, keyWindowCanClose: true)
    }

    private var contextIsCurrent: Bool {
        model.activeTarget == originalTarget && model.selectedPageID == originalPage
            && model.showingLedger == originalLedger
            && !sourceWasEdited && originalEditor?.textStorage === originalStorage
    }

    private func layout() {
        guard let overlay else { return }
        let room = overlay.bounds.insetBy(dx: 16, dy: 16)
        let width = min(600, max(0, room.width))
        let height = min(max(0, room.height), CGFloat(min(max(rows.count, 1), 8)) * 42 + 86)
        card.frame = NSRect(x: room.midX - width / 2, y: max(room.minY, room.maxY - height - 16),
                            width: width, height: height)
        let searchX: CGFloat = reopening ? 44 : 12
        backButton.frame = NSRect(x: 12, y: max(0, height - 40), width: 28, height: 28)
        search.frame = NSRect(x: searchX, y: max(0, height - 40), width: max(0, width - searchX - 12), height: 28)
        scroll.frame = NSRect(x: 1, y: 28, width: max(0, width - 2), height: max(0, height - 76))
        scroll.tile()
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        table.tableColumns.first?.width = scroll.contentSize.width
        footer.frame = NSRect(x: 12, y: 7, width: max(0, width - 24), height: 16)
    }
}

@MainActor
final class PaletteOverlayView: NSView {
    var onOutsideClick: (() -> Void)?
    var onLayout: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    weak var interactiveRegion: NSView?
    override func layout() { super.layout(); onLayout?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent?(event) == true
    }
    override func scrollWheel(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard interactiveRegion?.frame.contains(point) != true else { return }
        onOutsideClick?()
    }
}


@MainActor
final class PaletteTableView: NSTableView {
    var onCancel: (() -> Void)?
    var onRun: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onCancel?(); return }
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            onRun?()
            return
        }
        super.keyDown(with: event)
    }
}


@MainActor
final class PaletteCommandCell: NSTableCellView {
    let titleLabel: NSTextField
    let detailLabel: NSTextField
    let shortcutLabel: NSTextField

    init(title: String, detail: String, shortcut: String?) {
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(labelWithString: detail)
        shortcutLabel = NSTextField(labelWithString: shortcut ?? "")
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right
        for label in [titleLabel, detailLabel, shortcutLabel] { addSubview(label) }
        textField = titleLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("command cells are created in code") }

    func configure(title: String, detail: String, shortcut: String?) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        shortcutLabel.stringValue = shortcut ?? ""
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = min(10, bounds.width / 2)
        let shortcutWidth = min(100, max(0, bounds.width - inset * 2))
        let shortcutX = max(inset, bounds.maxX - inset - shortcutWidth)
        let titleWidth = max(0, shortcutX - inset - 8)
        titleLabel.frame = NSRect(x: inset, y: 21, width: titleWidth, height: 18)
        detailLabel.frame = NSRect(x: inset, y: 4, width: titleWidth, height: 15)
        shortcutLabel.frame = NSRect(x: shortcutX, y: 13, width: shortcutWidth, height: 18)
    }
}


@MainActor
internal enum CommandPalettePresentation {
    static func canSave(_ target: SurfaceTarget) -> Bool {
        if case .file = target { return true }
        return false
    }
}
