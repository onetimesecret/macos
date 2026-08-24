import Foundation

/// A keystroke as the keymap file spells it, and as the running app has
/// to recognise it.
///
/// The spelling is Zed's: a hyphen separated run of modifier words
/// ending in one key, so `cmd-shift-v` and `cmd-alt-left` mean what a
/// Zed user already expects them to mean. Everything in this file is
/// pure. It turns text into a value, and a value back into the two
/// shapes the frameworks want (a SwiftUI `KeyboardShortcut`, an AppKit
/// menu equivalent), without ever asking AppKit what happened. That
/// separation is the point: the parser is the part most likely to be
/// wrong, and it is the part a unit test can hold still.

// MARK: - Modifiers

/// The four modifiers a binding may name. `fn` and Zed's `secondary`
/// are deliberately absent: neither has an honest meaning in a menu key
/// equivalent on this platform, and a binding that silently never fires
/// is worse than one the validator refuses out loud.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)

    /// The words a file may use for each one. Zed writes `cmd`, `ctrl`
    /// and `alt`; the longer spellings are accepted because a person
    /// writing the file by hand reaches for them, and refusing a
    /// synonym teaches nothing.
    static let byWord: [String: KeyModifiers] = [
        "cmd": .command, "command": .command,
        "ctrl": .control, "control": .control,
        "alt": .option, "opt": .option, "option": .option,
        "shift": .shift,
    ]

    /// The canonical order, which is the order the bundled default is
    /// written in, so a binding read back out of a diagnostic looks
    /// like the line the author typed.
    var canonicalWords: [String] {
        var words: [String] = []
        if contains(.command) { words.append("cmd") }
        if contains(.control) { words.append("ctrl") }
        if contains(.option) { words.append("alt") }
        if contains(.shift) { words.append("shift") }
        return words
    }
}

// MARK: - Keys

/// The key a binding ends on: either one character, which is what most
/// bindings want, or one of the named keys that has no character to
/// name it by.
public enum KeyName: Hashable, Sendable {
    /// A single character, always folded to lower case. Shift is a
    /// modifier here, never a capital letter, so `cmd-shift-v` and
    /// `cmd-V` cannot drift apart into two different bindings.
    case character(Character)
    /// A key with a name rather than a character.
    case named(NamedKey)
}

/// The named keys, spelled the way Zed spells them. Function keys are
/// missing on purpose: SwiftUI's `KeyEquivalent` has no way to say F5,
/// so a binding on one could be validated and then never installed,
/// which is the exact failure this whole layer exists to prevent.
public enum NamedKey: String, CaseIterable, Sendable {
    case escape
    case enter
    case tab
    case space
    case backspace
    case delete
    case up
    case down
    case left
    case right
    case home
    case end
    case pageup
    case pagedown

    /// The virtual key code the hardware reports for this key. Used
    /// only when matching a real event, where the character a key
    /// produces is unreliable but its position on the board is not.
    /// These are Carbon's `kVK_` constants, written out rather than
    /// imported so this file stays free of frameworks.
    var virtualKeyCode: UInt16 {
        switch self {
        case .escape: return 0x35
        case .enter: return 0x24
        case .tab: return 0x30
        case .space: return 0x31
        case .backspace: return 0x33
        case .delete: return 0x75
        case .up: return 0x7E
        case .down: return 0x7D
        case .left: return 0x7B
        case .right: return 0x7C
        case .home: return 0x73
        case .end: return 0x77
        case .pageup: return 0x74
        case .pagedown: return 0x79
        }
    }
}

// MARK: - The keystroke

/// One parsed binding key: the modifiers held, and the key struck.
public struct Keystroke: Hashable, Sendable {
    public let modifiers: KeyModifiers
    public let key: KeyName

    public init(modifiers: KeyModifiers, key: KeyName) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Why a spelling was refused. Each case carries enough to write a
    /// line a person can act on without opening this file.
    public enum ParseFailure: Error, Equatable, Sendable {
        case empty
        case unknownModifier(String)
        case repeatedModifier(String)
        case unknownKey(String)
        /// Shift held over a key that is not a letter, which the two
        /// dispatch routes would read differently. See `parse`.
        case shiftedNonLetter(String)
    }

    /// Reads `cmd-shift-v` and its kin.
    ///
    /// The last segment is the key and everything before it is a
    /// modifier, with one wrinkle worth stating: the key may itself be
    /// a hyphen, as in `cmd--`, which splits into two empty final
    /// segments, one for the separator and one for the key.
    ///
    /// It is the pair that says so, and only the pair. A single empty
    /// tail is `cmd-`, a spelling that names a modifier and then stops,
    /// and reading that as the hyphen key would be worse than useless:
    /// it would eat the modifier the author did write and bind bare
    /// minus, so a typo in an override would put a command under an
    /// ordinary character someone types into a page. A lone empty tail
    /// falls through to the unknown-key refusal instead, which costs the
    /// author one line and tells them which.
    ///
    /// Shift over a key that is not a letter is refused for the reason
    /// `fn` and the function keys are refused: it would validate here
    /// and then fire on one route and not the other. A key event's
    /// unmodified characters honour shift on this platform, so
    /// `cmd-shift-1` arrives at the page as `!` and never matches the
    /// `1` the file wrote, while the surface's hidden buttons install
    /// the same spelling and fire. Shift over a letter is exactly the
    /// case lower-casing rescues, and shift over a named key is matched
    /// by position, so both stay bindable.
    public static func parse(_ text: String) -> Result<Keystroke, ParseFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        var segments = trimmed.split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        // Two empty segments in a row are the hyphen key wearing a
        // separator's clothes: `cmd--` is command plus minus.
        var keyToken = segments.removeLast()
        if keyToken.isEmpty, segments.last?.isEmpty == true {
            keyToken = "-"
            segments.removeLast()
        }

        var modifiers: KeyModifiers = []
        for word in segments {
            guard let modifier = KeyModifiers.byWord[word.lowercased()] else {
                return .failure(.unknownModifier(word))
            }
            guard !modifiers.contains(modifier) else {
                return .failure(.repeatedModifier(word))
            }
            modifiers.insert(modifier)
        }

        let lowered = keyToken.lowercased()
        if let named = NamedKey(rawValue: lowered) {
            return .success(Keystroke(modifiers: modifiers, key: .named(named)))
        }
        if lowered.count == 1, let character = lowered.first {
            guard !modifiers.contains(.shift) || character.isLetter else {
                return .failure(.shiftedNonLetter(keyToken))
            }
            return .success(Keystroke(modifiers: modifiers, key: .character(character)))
        }
        return .failure(.unknownKey(keyToken))
    }

    /// The spelling this keystroke would be written as, whatever
    /// spelling it arrived in. Two files that bind `cmd-alt-n` and
    /// `alt-cmd-n` are binding the same chord, and this is what lets
    /// the validator say so.
    public var canonical: String {
        var words = modifiers.canonicalWords
        switch key {
        case .character(let character): words.append(String(character))
        case .named(let named): words.append(named.rawValue)
        }
        return words.joined(separator: "-")
    }

    /// The chord as a person reads it: ⌘N, ⇧⌘V, ⌥⌘←.
    ///
    /// For tooltips and button labels, which is the one place the app
    /// tells someone what to press without the frameworks doing the
    /// telling. A menu item gets its chord from AppKit and never needs
    /// this; a `help` string has no such machinery behind it, and the
    /// alternative to rendering the resolved chord is spelling one into
    /// the view, which is how a tooltip comes to advertise a key that
    /// the keymap moved.
    ///
    /// The modifier order is Apple's own, which is not the canonical
    /// order: a keymap file reads left to right in the order the words
    /// were typed, and a chord on screen reads in the order the symbols
    /// have sat in every macOS menu for thirty years.
    public var displaySymbol: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        switch key {
        case .character(let character): symbols += String(character).uppercased()
        case .named(let named): symbols += named.displaySymbol
        }
        return symbols
    }
}

extension NamedKey {
    /// The glyph a menu would show for this key. The four that have no
    /// settled glyph are spelled out, because a made-up symbol teaches
    /// nobody anything.
    var displaySymbol: String {
        switch self {
        case .escape: return "⎋"
        case .enter: return "↩"
        case .tab: return "⇥"
        case .space: return "␣"
        case .backspace: return "⌫"
        case .delete: return "⌦"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .home: return "↖"
        case .end: return "↘"
        case .pageup: return "⇞"
        case .pagedown: return "⇟"
        }
    }
}

// MARK: - Recognising a real keystroke

extension Keystroke {
    /// Whether a key event is this keystroke.
    ///
    /// Pure, and taking the three facts an event carries rather than
    /// the event, because the interesting cases (a shifted letter
    /// reporting itself as a capital, an arrow key that carries the
    /// function flag whether or not a binding asked for it) are worth
    /// pinning in a test that never has to fabricate an `NSEvent`.
    ///
    /// Character keys are matched by the character the board would have
    /// produced without modifiers, folded to lower case, because that
    /// is the only reading under which shift is a modifier rather than
    /// a different key. Folding rescues letters and nothing else, which
    /// is why the parser refuses shift over anything but a letter.
    /// Named keys are matched by position, since a layout may put
    /// anything under the character a named key emits.
    public func matches(
        charactersIgnoringModifiers: String?,
        virtualKeyCode: UInt16,
        modifiers eventModifiers: KeyModifiers
    ) -> Bool {
        guard eventModifiers == modifiers else { return false }
        switch key {
        case .named(let named):
            return virtualKeyCode == named.virtualKeyCode
        case .character(let character):
            guard let typed = charactersIgnoringModifiers?.lowercased() else { return false }
            return typed == String(character)
        }
    }
}
