import Foundation

/// What a binding is allowed to point at.
///
/// A command id is a promise that something in this app already does
/// the thing. The keymap can move a chord from one command to another,
/// and a user's override can invent a chord we never thought of, but
/// neither can conjure behaviour: an id that no dispatch route answers
/// is refused by the validator rather than accepted and then ignored.
/// That is why this list is an enum and not a string. Adding a command
/// means writing the code that performs it in the same change.
///
/// The spelling is `namespace::Verb`, Zed's, and it is the stable part
/// of the contract. A user's keymap names these strings, so renaming
/// one breaks their file; treat the raw values as published.
public enum CommandID: String, CaseIterable, Sendable {
    case appCommandPalette = "app::CommandPalette"
    case appOpenTimeline = "app::OpenTimeline"
    case appSwitchToTabs = "app::SwitchToTabs"
    case pageReopenLast = "page::ReopenLast"
    case pageReopenDated = "page::ReopenDated"

    // Pages
    case pageNew = "page::New"
    case pageClose = "page::Close"
    case pagePrevious = "page::Previous"
    case pageNext = "page::Next"
    case pageSelect1 = "page::Select1"
    case pageSelect2 = "page::Select2"
    case pageSelect3 = "page::Select3"
    case pageSelect4 = "page::Select4"
    case pageSelect5 = "page::Select5"
    case pageSelect6 = "page::Select6"
    case pageSelect7 = "page::Select7"
    case pageSelect8 = "page::Select8"
    case pageSelect9 = "page::Select9"

    // Files, the peer content class to pages (ADR-0028). Only the two verbs
    // the app had no chord for at all are ids of their own. Saving a
    // file and closing one are second readings of `state::SaveNow` and
    // `page::Close`, because those raw values are published contract
    // and a person's own keymap already names them.
    case fileOpen = "file::Open"
    case fileSaveAs = "file::SaveAs"

    // The ledger
    case ledgerShow = "ledger::Show"

    // Sealing, which is the app's one irreversible gesture
    case clipboardSeal = "clipboard::Seal"
    case clipboardSealSelection = "clipboard::SealSelection"

    // A sealed object's named declassification: the one chord that
    // puts plaintext on the board, and only over a selected object
    // (D-29). The object's menu advertises it beside the verb.
    case chipCopyDecrypted = "chip::CopyDecrypted"

    // A sealed object's note grows to the card and back (Law 0001, issue
    // #246). Answered by the note's own writing surface, which holds the keys.
    case noteToggleExpanded = "note::ToggleExpanded"

    // The page's own presentation
    case editorToggleWrap = "editor::ToggleWrap"
    case editorDetectCodeLanguage = "editor::DetectCodeLanguage"

    // Undo, which is the core's stack now (issue #132)
    case editorUndo = "editor::Undo"
    case editorRedo = "editor::Redo"

    // The surface, and the app around it
    case surfaceHandBackKeys = "surface::HandBackKeys"
    case stateSaveNow = "state::SaveNow"
    case appSettings = "app::Settings"
    // The Help menu's product help item, from that menu only (issue #294).
    case appHelp = "app::Help"

    // The window around the surface (ADR-0033, issue #201): ⇧⌘W closes
    // the window the keyboard is in, from the Window menu only. ⌘W is
    // `page::Close` on the surface and closes a companion window that is key.
    case windowClose = "window::Close"

    /// Which piece of the app listens for this command.
    ///
    /// Not a detail of the file, a fact about the code: the surface
    /// commands are carried by the hidden buttons the raised card
    /// mounts, and the editor commands are answered by the page's own
    /// text view, which sees a keystroke before any of them. The seal
    /// gestures have to stay on the second route because the text view
    /// is first responder while a page is being typed into, and because
    /// what they act on (the caret, the selection) is the text view's
    /// alone. Undo joins them for the same reason and for one more: the
    /// text view has to see ⌘Z before the standard Edit menu does, or
    /// the menu item hands it to `NSUndoManager` and the core's stack
    /// never hears about it.
    public enum Dispatch: Sendable {
        case surface
        case editor
        /// Carried by a main-menu item's key equivalent, live app-wide
        /// even while Settings or another window without a surface holds
        /// the keys. The surface installer never installs a `.window`
        /// chord, so the menu is the one route and there is no fight
        /// with the surface's own hidden buttons over the same key.
        case window
    }

    public var dispatch: Dispatch {
        switch self {
        case .clipboardSeal, .clipboardSealSelection, .chipCopyDecrypted, .editorToggleWrap,
            .editorDetectCodeLanguage, .editorUndo, .editorRedo, .noteToggleExpanded:
            return .editor
        case .windowClose, .appHelp, .appCommandPalette:
            return .window
        default:
            return .surface
        }
    }

    /// For the nine jump commands, which visible tab they jump to,
    /// counting from one. Nil for everything else.
    public var selectsPageNumber: Int? {
        switch self {
        case .pageSelect1: return 1
        case .pageSelect2: return 2
        case .pageSelect3: return 3
        case .pageSelect4: return 4
        case .pageSelect5: return 5
        case .pageSelect6: return 6
        case .pageSelect7: return 7
        case .pageSelect8: return 8
        case .pageSelect9: return 9
        default: return nil
        }
    }
}

/// The surfaces a binding can belong to.
///
/// Only `Editor` is consulted today, and the other two are here because
/// naming them now is what keeps a later tab strip binding from needing
/// a schema change. The validator knows all three, so a user's override
/// that names `TabStrip` is read rather than rejected; it also says
/// plainly that nothing will fire, which is the honest answer to a
/// binding placed somewhere no code is listening.
public enum KeymapContext: String, CaseIterable, Sendable {
    case editor = "Editor"
    case tabStrip = "TabStrip"
    case ledger = "Ledger"

    /// Whether any part of the running app asks this context for its
    /// bindings. Flip one of these to true in the same change that
    /// teaches a surface to consult it, never before.
    public var isConsulted: Bool {
        self == .editor
    }
}
