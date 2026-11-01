import AppKit

@MainActor
public protocol CommandPaletteResponder: AnyObject {
    func prepareForCommandPalette() -> Bool
    func beginPaletteFocusBorrow()
    func endPaletteFocusBorrow()
    func canPerformPaletteCommand(_ command: CommandID) -> Bool
    @discardableResult func performPaletteCommand(_ command: CommandID) -> Bool
}

public extension CommandPaletteResponder {
    func beginPaletteFocusBorrow() {}
    func endPaletteFocusBorrow() {}
}

public enum CommandPaletteScope: Int, CaseIterable, Sendable {
    case application, page, selection

    public var title: String {
        switch self {
        case .application: CompanionL10n.string("Application")
        case .page: CompanionL10n.string("Current Page or Tab")
        case .selection: CompanionL10n.string("Editor and Selection")
        }
    }
}

public struct CommandPaletteEntry: Identifiable, Equatable, Sendable {
    public var id: CommandID { command }
    public let command: CommandID
    public let title: String
    public let scope: CommandPaletteScope
    public let keywords: String
    public let shortcut: String?

    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        let text = title + " " + keywords + " " + command.rawValue
        return words.allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

public enum CommandPaletteCatalog {
    public static func entries(keymap: ResolvedKeymap) -> [CommandPaletteEntry] {
        let definitions: [(CommandID, String, CommandPaletteScope, String)] = [
            (.appOpenTimeline, "Open Timeline", .application, "view dated pages history"),
            (.appSwitchToTabs, "Switch to Tabs View", .application, "layout navigation"),
            (.pageReopenDated, "Reopen Dated Tabs…", .application, "closed saved pages history restore re-open"),
            (.pageReopenLast, "Reopen Last Closed Page or Tab", .application, "restore saved re-open"),
            (.pageNew, "New Page", .application, "new tab"),
            (.fileOpen, "Open File…", .application, "document"),
            (.appSettings, "Settings…", .application, "preferences"),
            (.appHelp, "OnetimePad Help", .application, "documentation"),
            (.windowClose, "Close Window", .application, "window dismiss"),
            (.stateSaveNow, "Save", .page, "disk state document"),
            (.fileSaveAs, "Save As…", .page, "file document"),
            (.pageClose, "Close Page or Tab", .page, "hide dismiss"),
            (.pagePrevious, "Previous Page or Tab", .page, "navigate"),
            (.pageNext, "Next Page or Tab", .page, "navigate"),
            (.editorToggleWrap, "Toggle Line Wrapping", .page, "text horizontal"),
            (.clipboardSeal, "Seal Clipboard", .selection, "insert paste"),
            (.clipboardSealSelection, "Seal Selected Content", .selection, "text line"),
            (.chipCopyDecrypted, "Copy Decrypted Contents", .selection, "sealed object"),
            (.editorUndo, "Undo", .selection, "edit"),
            (.editorRedo, "Redo", .selection, "edit"),
            (.editorDetectCodeLanguage, "Detect Code Language", .selection, "syntax"),
            (.noteToggleExpanded, "Toggle Note Expansion", .selection, "sealed note")
        ]
        return definitions.map { command, title, scope, keywords in
            CommandPaletteEntry(command: command, title: CompanionL10n.string(title),
                scope: scope, keywords: keywords,
                shortcut: keymap.hintKeystroke(for: command)?.displaySymbol)
        }.enumerated().sorted { left, right in
            left.element.scope == right.element.scope
                ? left.offset < right.offset : left.element.scope.rawValue < right.element.scope.rawValue
        }.map(\.element)
    }
}
