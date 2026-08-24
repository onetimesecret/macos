import AppKit
import SwiftUI

/// The thin layer where a parsed keystroke meets the two frameworks
/// that have to honour it: SwiftUI, for the hidden buttons the raised
/// surface carries, and AppKit, for a menu item's key equivalent and
/// for recognising an event the text view was handed.
///
/// Everything here is a translation and nothing here decides anything.
/// The decisions were all taken in `Keystroke` and `Keymap`, where a
/// test can reach them without a window.

// MARK: - SwiftUI

extension Keystroke {
    /// The shortcut a hidden button installs, or nil for a keystroke
    /// SwiftUI has no way to express.
    ///
    /// Bare Escape becomes `.cancelAction` rather than the plain escape
    /// equivalent, which is what this surface has always installed:
    /// the cancel action is Escape plus the standing agreement that
    /// this is the way out, and the surface's Escape is exactly that
    /// (it closes the ledger, or hands the keyboard back).
    public var keyboardShortcut: KeyboardShortcut? {
        if modifiers.isEmpty, key == .named(.escape) { return .cancelAction }
        guard let equivalent = keyEquivalent else { return nil }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case .character(let character):
            return KeyEquivalent(character)
        case .named(let named):
            switch named {
            case .escape: return .escape
            case .enter: return .return
            case .tab: return .tab
            case .space: return .space
            case .backspace: return .delete
            case .delete: return .deleteForward
            case .up: return .upArrow
            case .down: return .downArrow
            case .left: return .leftArrow
            case .right: return .rightArrow
            case .home: return .home
            case .end: return .end
            case .pageup: return .pageUp
            case .pagedown: return .pageDown
            }
        }
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}

// MARK: - AppKit menus

extension Keystroke {
    /// The string an `NSMenuItem` wants as its key equivalent. The
    /// named keys go up as the function-key code points AppKit reads
    /// them from, which is the only spelling a menu understands.
    public var menuKeyEquivalent: String {
        switch key {
        case .character(let character):
            return String(character)
        case .named(let named):
            switch named {
            case .escape: return "\u{1b}"
            case .enter: return "\r"
            case .tab: return "\t"
            case .space: return " "
            case .backspace: return "\u{8}"
            case .delete: return String(UnicodeScalar(NSDeleteFunctionKey)!)
            case .up: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case .down: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .left: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case .right: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case .home: return String(UnicodeScalar(NSHomeFunctionKey)!)
            case .end: return String(UnicodeScalar(NSEndFunctionKey)!)
            case .pageup: return String(UnicodeScalar(NSPageUpFunctionKey)!)
            case .pagedown: return String(UnicodeScalar(NSPageDownFunctionKey)!)
            }
        }
    }

    /// The mask that goes with it.
    public var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        return mask
    }
}

// MARK: - Recognising an event

extension KeyModifiers {
    /// The four modifiers we bind on, taken out of an event's flags.
    ///
    /// Everything else the flags carry is dropped on purpose. Caps lock
    /// is a state rather than a chord, and the function and numeric-pad
    /// flags ride along on every arrow key whether or not a binding
    /// asked for them, so keeping them would make `alt-left` a chord
    /// nobody can type.
    public init(eventFlags: NSEvent.ModifierFlags) {
        var result: KeyModifiers = []
        let flags = eventFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}

extension Keystroke {
    /// Whether a real key event is this keystroke.
    public func matches(event: NSEvent) -> Bool {
        matches(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            virtualKeyCode: event.keyCode,
            modifiers: KeyModifiers(eventFlags: event.modifierFlags)
        )
    }
}

extension ResolvedKeymap {
    /// The command a real key event runs on a surface, if any.
    public func command(for event: NSEvent, in context: KeymapContext) -> CommandID? {
        bindings.first { $0.context == context && $0.keystroke.matches(event: event) }?.command
    }

    /// One chord the surface will carry as a hidden button.
    public struct InstalledShortcut: Identifiable, Sendable {
        /// The chord itself is the identity: a surface cannot install
        /// the same chord twice, and the resolution has already made
        /// sure of it.
        public var id: Keystroke { keystroke }
        public let keystroke: Keystroke
        public let command: CommandID
        public let shortcut: KeyboardShortcut
    }

    /// The chords the surface installs, in resolution order.
    ///
    /// A binding SwiftUI cannot express is dropped rather than
    /// approximated. Nothing reaches here without having been
    /// validated, so the drop is a theoretical guard rather than an
    /// expected outcome, and it fails towards a chord that does nothing
    /// rather than towards a chord that does the wrong thing.
    public func surfaceShortcuts(in context: KeymapContext = .editor) -> [InstalledShortcut] {
        bindings(in: context, dispatch: .surface).compactMap { binding in
            binding.keystroke.keyboardShortcut.map {
                InstalledShortcut(
                    keystroke: binding.keystroke, command: binding.command, shortcut: $0)
            }
        }
    }
}
