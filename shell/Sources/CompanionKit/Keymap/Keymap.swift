import Foundation
import os

/// The keymap, resolved: which chord runs which command on which
/// surface, after the bundled default and any override the user wrote
/// have been read, checked and merged.
///
/// The rule the whole file obeys is that a keymap is data and the app
/// is code, and data is never trusted to be right. Every binding is
/// parsed before it is installed, every command id is checked against
/// the list of things this build can actually do, and anything that
/// fails is reported and dropped rather than carried forward as a
/// binding that quietly does nothing. A file that is wrong about its
/// own shape, rather than about one line, is refused whole, and the app
/// falls back to the last map that resolved cleanly, or to the bundled
/// default. What it never does is end up with a chord pointed
/// somewhere unintended.

// MARK: - Where a binding came from

/// Which file a binding or a complaint belongs to. Worth carrying
/// through every diagnostic: "the keymap is wrong" is not actionable
/// when the reader cannot tell whether the file to open is theirs or
/// ours.
public enum KeymapSource: String, Sendable {
    case bundledDefault = "the bundled default keymap"
    case userOverride = "your keymap"
}

// MARK: - What can be wrong

/// Everything the validator can find, in a shape that carries its own
/// explanation. These are reported rather than thrown: one bad line
/// must not cost the user the other twenty.
public enum KeymapDiagnostic: Equatable, Sendable {
    /// The file could not be read as a keymap at all, so none of it was
    /// used.
    case fileRejected(KeymapSource, KeymapFileFailure)
    /// The bundled default was missing from the bundle, which is a
    /// packaging fault rather than anything the user did.
    case defaultKeymapMissing
    case malformedKeystroke(KeymapSource, keystroke: String, failure: Keystroke.ParseFailure)
    case unknownCommand(KeymapSource, keystroke: String, command: String)
    case unknownContext(KeymapSource, context: String)
    /// Two spellings of the same chord in one section. The first by
    /// sorted order is kept so the outcome does not depend on the order
    /// a dictionary happened to hash into. A nil is that section's
    /// unbinding of the chord, which settles it as surely as a command
    /// does.
    case duplicateBinding(KeymapSource, keystroke: String, kept: CommandID?, dropped: CommandID?)
    /// A later section took a chord an earlier one had. Expected when
    /// an override reassigns a default binding, which is the whole
    /// point of overrides, and suspicious within one file.
    case reboundKeystroke(KeymapSource, keystroke: String, from: CommandID, to: CommandID)
    /// An unbinding aimed at a chord nothing had bound.
    case unbindsNothing(KeymapSource, keystroke: String)
    /// A binding in a context no surface consults yet. Legal, and inert
    /// until some surface starts asking.
    case contextNotConsulted(KeymapSource, context: KeymapContext, keystroke: String)

    /// One line, plain enough to log and to show.
    public var summary: String {
        switch self {
        case .fileRejected(let source, let failure):
            return "\(source.rawValue) was refused whole: \(failure.summary)"
        case .defaultKeymapMissing:
            return "the bundled default keymap is missing from this build, so no shortcut is bound"
        case .malformedKeystroke(let source, let keystroke, let failure):
            return "\(source.rawValue) binds \"\(keystroke)\", which is not a keystroke: \(failure.summary)"
        case .unknownCommand(let source, let keystroke, let command):
            return "\(source.rawValue) points \"\(keystroke)\" at \"\(command)\", which this build has no command for"
        case .unknownContext(let source, let context):
            return "\(source.rawValue) names the surface \"\(context)\", which does not exist"
        case .duplicateBinding(let source, let keystroke, let kept, let dropped):
            return "\(source.rawValue) settles \"\(keystroke)\" twice; kept \(Self.name(kept)), dropped \(Self.name(dropped))"
        case .reboundKeystroke(let source, let keystroke, let from, let to):
            return "\(source.rawValue) moves \"\(keystroke)\" from \(from.rawValue) to \(to.rawValue)"
        case .unbindsNothing(let source, let keystroke):
            return "\(source.rawValue) unbinds \"\(keystroke)\", which nothing had bound"
        case .contextNotConsulted(let source, let context, let keystroke):
            return "\(source.rawValue) binds \"\(keystroke)\" in \(context.rawValue), which no surface consults yet, so it will not fire"
        }
    }

    /// What one side of a duplicate is called in a line someone reads:
    /// a command id, or the unbinding a null spells.
    private static func name(_ command: CommandID?) -> String {
        command?.rawValue ?? "the unbinding"
    }

    /// Whether this one cost the user a binding they asked for. The
    /// rebindings and the unconsulted contexts are notes; the rest are
    /// faults.
    public var isFault: Bool {
        switch self {
        case .reboundKeystroke, .contextNotConsulted: return false
        default: return true
        }
    }
}

extension KeymapFileFailure {
    var summary: String {
        switch self {
        case .unreadable(let reason): return reason
        case .notJSON(let reason): return "it is not JSON5 (\(reason))"
        case .notAnArray: return "the top level is not an array of sections"
        case .sectionNotAnObject(let index): return "entry \(index) is not an object"
        case .bindingsNotAnObject(let index): return "the bindings of entry \(index) are not an object"
        case .contextNotAString(let index): return "the context of entry \(index) is not a string"
        case .unsupportedSchemaVersion(let version):
            return "it declares schema version \(version), and this build reads version \(KeymapFileReader.schemaVersion)"
        case .schemaVersionNotAWholeNumber(let found):
            return "its schema version is \(found) rather than a whole number, and this build reads version \(KeymapFileReader.schemaVersion)"
        case .repeatedSchemaVersion: return "it declares a schema version more than once"
        }
    }
}

extension Keystroke.ParseFailure {
    var summary: String {
        switch self {
        case .empty: return "it is empty"
        case .unknownModifier(let word): return "\"\(word)\" is not a modifier"
        case .repeatedModifier(let word): return "\"\(word)\" is named twice"
        case .unknownKey(let key): return "\"\(key)\" is not a key this build can bind"
        case .shiftedNonLetter(let key):
            return
                "shift can only be held over a letter, and \"\(key)\" is not one (name the glyph "
                + "shift produces, the way \"cmd-!\" names ⇧⌘1)"
        }
    }
}

// MARK: - The resolved map

/// The map the app actually runs on: a flat, sorted list of bindings,
/// and the complaints gathered on the way to it.
public struct ResolvedKeymap: Sendable {
    public struct Binding: Sendable, Hashable {
        public let context: KeymapContext
        public let keystroke: Keystroke
        public let command: CommandID
        /// Whether the section this came from allows the chord to be
        /// shown and honoured as an AppKit menu key equivalent.
        public let useKeyEquivalents: Bool
    }

    public let bindings: [Binding]
    public let diagnostics: [KeymapDiagnostic]
    /// Explicit `null` declarations remain distinguishable from chords that
    /// have never been assigned, for opt-in command layers such as pad picking.
    public let explicitlyUnbound: [KeymapContext: Set<Keystroke>]

    public init(bindings: [Binding], diagnostics: [KeymapDiagnostic],
                explicitlyUnbound: [KeymapContext: Set<Keystroke>] = [:]) {
        self.bindings = bindings
        self.diagnostics = diagnostics
        self.explicitlyUnbound = explicitlyUnbound
    }

    /// The empty map, which is what a build with an unreadable default
    /// and nothing to fall back on gets. No shortcut fires; every
    /// gesture that has a button or a menu item still works. Fail
    /// closed, in the small.
    public static let empty = ResolvedKeymap(bindings: [], diagnostics: [])

    /// The command a chord runs on a surface, if any.
    public func command(for keystroke: Keystroke, in context: KeymapContext) -> CommandID? {
        bindings.first { $0.context == context && $0.keystroke == keystroke }?.command
    }

    /// The bindings a given dispatch route has to install, in a stable
    /// order.
    public func bindings(in context: KeymapContext, dispatch: CommandID.Dispatch) -> [Binding] {
        bindings.filter { $0.context == context && $0.command.dispatch == dispatch }
    }

    /// The chord a menu item may advertise for a command.
    ///
    /// Only sections that opted into `use_key_equivalents` answer here.
    /// A menu key equivalent is an app-wide claim, live even while the
    /// keyboard belongs to a text field in Settings, so taking one has
    /// to be something the file asked for rather than something every
    /// binding gets for free.
    public func menuKeystroke(for command: CommandID) -> Keystroke? {
        bindings.first { $0.command == command && $0.useKeyEquivalents }?.keystroke
    }

    /// The chord a tooltip may name for a command, whatever section it
    /// came from.
    ///
    /// Deliberately not `menuKeystroke`. That one is gated on
    /// `use_key_equivalents` because taking a menu equivalent is an
    /// app-wide claim on a chord; saying "and you can also press this"
    /// in a help string claims nothing and installs nothing. A file that
    /// declined key equivalents still bound the chord, and a tooltip
    /// that went quiet about it would be hiding something true.
    ///
    /// Nil means nothing is bound, and then the caller says only what
    /// the button does. A button whose chord was unbound must not keep
    /// advertising it.
    public func hintKeystroke(for command: CommandID) -> Keystroke? {
        bindings.first { $0.command == command }?.keystroke
    }

    /// The faults worth telling someone about.
    public var faults: [KeymapDiagnostic] { diagnostics.filter(\.isFault) }
}

// MARK: - Reading, checking, merging

/// Only here to name a class in this module for `Bundle(for:)`, which is
/// how the module finds the bundle it was linked into. `LogoMark` keeps
/// its own for the same job; neither is worth sharing, and a token that
/// travels between files is a token someone moves by accident.
private final class KeymapBundleToken {}

public enum Keymap {
    /// The bundled default's name in the resources. The packaging
    /// script copies this file into the app bundle beside the logo
    /// mark (`scripts/package-app.sh`).
    public static let defaultResourceName = "default-keymap"
    public static let defaultResourceExtension = "json"

    /// The schema version this build reads and writes.
    public static var schemaVersion: Int { KeymapFileReader.schemaVersion }

    /// Where the bundled default actually is, which differs by how the
    /// code is running. Searched exactly the way `LogoMark` searches for
    /// the logo, and for the same reason: `Bundle.module` is not used
    /// here on purpose. SwiftPM's generated accessor looks for its
    /// resource bundle beside `Bundle.main`, which for an assembled app
    /// is the directory holding OnetimePad.app rather than anywhere
    /// inside it, and when the lookup misses it calls `fatalError`.
    ///
    /// That matters more here than it does for an icon. The whole point
    /// of `defaultKeymapMissing` is to survive a packaging script that
    /// forgot to copy this file; reaching for `Bundle.module` to find
    /// out would turn the diagnostic into a crash inside `PageModel`'s
    /// initialiser, on the launch that most needs to keep going. A miss
    /// returns nil, and the ladder above falls to the empty map.
    static let defaultURL: URL? = {
        // The shipped app, where scripts/package-app.sh puts the file.
        if let url = Bundle.main.url(
            forResource: defaultResourceName, withExtension: defaultResourceExtension)
        {
            return url
        }
        // `swift run` and `swift test`, where SwiftPM leaves the
        // resource bundle beside the binary or beside the test bundle
        // this module is linked into.
        let home = Bundle(for: KeymapBundleToken.self).bundleURL
        for directory in [home, home.deletingLastPathComponent()] {
            let path = directory.appendingPathComponent("OnetimePad_CompanionKit.bundle").path
            if let url = Bundle(path: path)?.url(
                forResource: defaultResourceName, withExtension: defaultResourceExtension)
            {
                return url
            }
        }
        return nil
    }()

    /// The bundled default's text, or nil if this build lost it.
    public static func bundledDefaultText() -> String? {
        guard let url = defaultURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The map for this launch: the bundled default, with the user's
    /// override laid over it if they wrote one.
    ///
    /// An absent override is not an error and produces no diagnostic;
    /// most people will never write one. An override that cannot be
    /// read as a file is reported and ignored, leaving the default in
    /// force, because a user whose keymap has a typo in it should lose
    /// their customisation and not their app.
    ///
    /// `previous` is the map that last resolved cleanly, and today no
    /// shipping call site passes one: the map is resolved once, in
    /// `PageModel`'s initialiser, and nothing reloads it afterwards, so
    /// at launch there is nothing to fall back to and the fallback is
    /// the empty map. The parameter is kept because the day the file is
    /// watched and re-read is the day a bad save must not cost the user
    /// the keyboard they had a second ago, and the rule is easier to
    /// keep true from the start than to retrofit. Only the tests
    /// exercise the rung.
    public static func load(
        userOverride: URL?,
        previous: ResolvedKeymap? = nil
    ) -> ResolvedKeymap {
        var overrideText: String?
        var overrideFailure: KeymapFileFailure?
        if let userOverride, FileManager.default.fileExists(atPath: userOverride.path) {
            do {
                overrideText = try String(contentsOf: userOverride, encoding: .utf8)
            } catch {
                overrideFailure = .unreadable(error.localizedDescription)
            }
        }

        var resolved = resolve(
            defaultText: bundledDefaultText(),
            overrideText: overrideText,
            previous: previous
        )
        if let overrideFailure {
            resolved = ResolvedKeymap(
                bindings: resolved.bindings,
                diagnostics: [.fileRejected(.userOverride, overrideFailure)] + resolved.diagnostics,
                explicitlyUnbound: resolved.explicitlyUnbound
            )
        }
        return resolved
    }

    /// The same resolution over text rather than files, which is the
    /// form every test uses and the form the fallback rules are easiest
    /// to state in:
    ///
    /// - The default is missing or refused whole: fall back to the last
    ///   map that resolved cleanly, and if there is none, to the empty
    ///   map. The override is not applied on its own, because a keymap
    ///   built from half of its intended sources is a surprise waiting
    ///   for the first chord.
    /// - The override is refused whole: the default stands alone.
    /// - Either file is merely wrong in places: the good bindings are
    ///   kept and each bad one is reported.
    ///
    /// The first rule is the one with no live caller behind it yet: see
    /// `load` for why `previous` is here and why only tests reach it.
    public static func resolve(
        defaultText: String?,
        overrideText: String?,
        previous: ResolvedKeymap? = nil
    ) -> ResolvedKeymap {
        guard let defaultText else {
            return fallback(to: previous, with: [.defaultKeymapMissing])
        }

        let defaultSections: [KeymapSection]
        switch KeymapFileReader.read(defaultText) {
        case .success(let sections): defaultSections = sections
        case .failure(let failure):
            return fallback(to: previous, with: [.fileRejected(.bundledDefault, failure)])
        }

        var diagnostics: [KeymapDiagnostic] = []
        var sources: [(KeymapSource, [KeymapSection])] = [(.bundledDefault, defaultSections)]

        if let overrideText {
            switch KeymapFileReader.read(overrideText) {
            case .success(let sections): sources.append((.userOverride, sections))
            case .failure(let failure):
                diagnostics.append(.fileRejected(.userOverride, failure))
            }
        }

        return validate(sources: sources, carrying: diagnostics)
    }

    /// The last map that resolved cleanly, carrying the new complaint in
    /// front of the old ones. With no previous map, which is every
    /// shipping launch today, this is the empty map plus the reason it
    /// is empty.
    private static func fallback(
        to previous: ResolvedKeymap?, with diagnostics: [KeymapDiagnostic]
    ) -> ResolvedKeymap {
        ResolvedKeymap(
            bindings: previous?.bindings ?? [],
            diagnostics: diagnostics + (previous?.diagnostics ?? []),
            explicitlyUnbound: previous?.explicitlyUnbound ?? [:]
        )
    }

    /// The validator proper. Sections are applied in order, so a later
    /// one wins the chord, which is how an override reassigns a default
    /// binding and how `null` takes one away.
    private static func validate(
        sources: [(KeymapSource, [KeymapSection])],
        carrying diagnostics: [KeymapDiagnostic]
    ) -> ResolvedKeymap {
        var diagnostics = diagnostics
        var table: [KeymapContext: [Keystroke: ResolvedKeymap.Binding]] = [:]
        var explicitlyUnbound: [KeymapContext: Set<Keystroke>] = [:]

        for (source, sections) in sources {
            for section in sections {
                let contexts: [KeymapContext]
                if let name = section.contextName {
                    guard let context = KeymapContext(rawValue: name) else {
                        diagnostics.append(.unknownContext(source, context: name))
                        continue
                    }
                    contexts = [context]
                } else {
                    contexts = KeymapContext.allCases
                }

                // Within one section a chord is settled once, and by
                // whichever spelling sorts first, so two spellings of
                // the same chord cannot each win in a different context
                // and leave the surfaces disagreeing. A null settles a
                // chord too: nil here is an unbinding this section
                // already performed, not an absence.
                var settledInSection: [Keystroke: CommandID?] = [:]

                for binding in section.bindings {
                    let keystroke: Keystroke
                    switch Keystroke.parse(binding.keystroke) {
                    case .success(let parsed):
                        keystroke = parsed
                    case .failure(let failure):
                        diagnostics.append(
                            .malformedKeystroke(
                                source, keystroke: binding.keystroke, failure: failure))
                        continue
                    }

                    // Read before the chord is settled, so an id nothing
                    // implements is reported as the one thing wrong with
                    // the line rather than as half of a duplicate.
                    var command: CommandID?
                    if let commandText = binding.command {
                        guard let known = CommandID(rawValue: commandText) else {
                            diagnostics.append(
                                .unknownCommand(
                                    source, keystroke: binding.keystroke, command: commandText))
                            continue
                        }
                        command = known
                    }

                    if let kept = settledInSection[keystroke] {
                        diagnostics.append(
                            .duplicateBinding(
                                source,
                                keystroke: keystroke.canonical,
                                kept: kept,
                                dropped: command
                            ))
                        continue
                    }
                    settledInSection[keystroke] = command

                    guard let command else {
                        var unbound = false
                        for context in contexts {
                            explicitlyUnbound[context, default: []].insert(keystroke)
                        }
                        for context in contexts where table[context]?[keystroke] != nil {
                            table[context]?[keystroke] = nil
                            unbound = true
                        }
                        if !unbound {
                            diagnostics.append(
                                .unbindsNothing(source, keystroke: binding.keystroke))
                        }
                        continue
                    }

                    for context in contexts {
                        explicitlyUnbound[context]?.remove(keystroke)
                        // A section that restates a chord already
                        // pointed at this command changes nothing, and
                        // must take nothing away either: an override
                        // repeating a default line, to keep it in sight
                        // beside its own edits, cannot be read as
                        // withdrawing the menu equivalent the default
                        // granted. A section that asks for equivalents
                        // can still add one to a chord that had none.
                        var useKeyEquivalents = section.useKeyEquivalents
                        if let existing = table[context]?[keystroke] {
                            if existing.command == command {
                                useKeyEquivalents = useKeyEquivalents || existing.useKeyEquivalents
                            } else {
                                diagnostics.append(
                                    .reboundKeystroke(
                                        source,
                                        keystroke: keystroke.canonical,
                                        from: existing.command,
                                        to: command
                                    ))
                            }
                        }
                        if !context.isConsulted {
                            diagnostics.append(
                                .contextNotConsulted(
                                    source, context: context, keystroke: keystroke.canonical))
                        }
                        table[context, default: [:]][keystroke] = ResolvedKeymap.Binding(
                            context: context,
                            keystroke: keystroke,
                            command: command,
                            useKeyEquivalents: useKeyEquivalents
                        )
                    }
                }
            }
        }

        // Sorted, so the installed order is the same on every launch
        // and a test can name what it expects.
        let bindings = table.values
            .flatMap(\.values)
            .sorted {
                $0.context.rawValue == $1.context.rawValue
                    ? $0.keystroke.canonical < $1.keystroke.canonical
                    : $0.context.rawValue < $1.context.rawValue
            }

        return ResolvedKeymap(bindings: bindings, diagnostics: diagnostics,
                              explicitlyUnbound: explicitlyUnbound)
    }
}

// MARK: - Saying so out loud

extension ResolvedKeymap {
    /// Writes the faults to the unified log, beside the persistence
    /// trail, under the `keymap` category.
    ///
    /// A refused binding is not worth a banner over the page: it costs
    /// a shortcut, not any content, and the person it concerns is the
    /// person who just edited the file. The log is where they will look,
    /// and it is where a support conversation can reach:
    ///
    /// ```bash
    /// log show --predicate 'subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad", "dev.onetimesecret.pad.debug"}' --last 1h --style compact
    /// ```
    public func report(subsystem: String) {
        guard !faults.isEmpty else { return }
        let logger = Logger(subsystem: subsystem, category: "keymap")
        for fault in faults {
            logger.error("keymap: \(fault.summary, privacy: .public)")
        }
    }
}
