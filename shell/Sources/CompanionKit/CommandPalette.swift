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

    public func matches(_ query: String, title displayedTitle: String? = nil) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        let text = (displayedTitle ?? title) + " " + keywords + " " + command.rawValue
        return words.allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

public enum CommandPaletteCatalog {
    public static func entries(keymap: ResolvedKeymap) -> [CommandPaletteEntry] {
        CommandID.allCases.compactMap { command in
            guard let definition = command.paletteDefinition else { return nil }
            return CommandPaletteEntry(command: command, title: CompanionL10n.string(definition.title),
                scope: definition.scope, keywords: definition.keywords,
                shortcut: keymap.hintKeystroke(for: command)?.displaySymbol)
        }.enumerated().sorted { left, right in
            left.element.scope == right.element.scope
                ? left.offset < right.offset : left.element.scope.rawValue < right.element.scope.rawValue
        }.map(\.element)
    }
}

extension CommandID {
    var paletteDefinition: (title: String, scope: CommandPaletteScope, keywords: String)? {
        switch self {
        case .appOpenTimeline: ("Open Timeline", .application, "view dated pages history")
        case .appSwitchToTabs: ("Switch to Tabs View", .application, "layout navigation")
        case .pageReopenDated: ("Reopen Dated Tabs…", .application, "closed saved pages history restore re-open")
        case .pageReopenLast: ("Reopen Last Closed Page or Tab", .application, "restore saved re-open")
        case .pageNew: ("New Page", .application, "new tab")
        case .fileOpen: ("Open File…", .application, "document")
        case .appSettings: ("Settings…", .application, "preferences")
        case .appHelp: ("OnetimePad Help", .application, "documentation")
        case .windowClose: ("Close Window", .application, "window dismiss")
        case .stateSaveNow: ("Save", .page, "disk state document")
        case .fileSaveAs: ("Save As…", .page, "file document")
        case .pageClose: ("Close Page or Tab", .page, "hide dismiss")
        case .pagePrevious: ("Previous Page or Tab", .page, "navigate")
        case .pageNext: ("Next Page or Tab", .page, "navigate")
        case .editorToggleWrap: ("Toggle Line Wrapping", .page, "text horizontal")
        case .clipboardSeal: ("Seal Clipboard", .selection, "insert paste")
        case .clipboardSealSelection: ("Seal Selected Content", .selection, "text line")
        case .chipCopyDecrypted: ("Copy Decrypted Contents", .selection, "sealed object")
        case .editorUndo: ("Undo", .selection, "edit")
        case .editorRedo: ("Redo", .selection, "edit")
        case .editorDetectCodeLanguage: ("Detect Code Language", .selection, "syntax")
        case .noteToggleExpanded: ("Toggle Note Expansion", .selection, "sealed note")
        case .pageSelect1, .pageSelect2, .pageSelect3, .pageSelect4, .pageSelect5,
             .pageSelect6, .pageSelect7, .pageSelect8, .pageSelect9,
             .ledgerShow, .surfaceHandBackKeys, .appCommandPalette:
            nil
        }
    }
}
