import Foundation
import SwiftUI

/// The presentation selected for one open file. This is shell session state:
/// it changes attributes only and is never encoded with the file or its draft.
public enum FileRenderMode: Equatable, Hashable, Sendable {
    case plainText
    case markdown
    case source(String)

    public var formatLabel: String {
        switch self {
        case .plainText: return "Plain Text"
        case .markdown: return "Markdown"
        case .source(let language): return "Source (\(language.capitalized))"
        }
    }
}

/// What the surface says about the file it is showing, and the banner
/// it puts up when that file changed underneath (ADR-0028).
///
/// The words are decided here, as pure functions of a `FileSummary`,
/// and drawn elsewhere. That split is the same one `SheetTab`'s menu
/// labels and `TimeUnitTab`'s tooltips already make, and it is what
/// lets the header's four readings be tested without a window.

/// The header's reading of a file: its name, whether it is on disk,
/// how old the draft is when one was restored, and the two quiet facts
/// beside them.
///
/// A value rather than four calls, because the four are one sentence a
/// reader takes in at once and a test should be able to assert about as
/// one thing.
public struct FileHeaderState: Equatable, Sendable {
    /// The filename, which is the only name a file has here.
    public let name: String
    /// `saved` or `unsaved`, or `not read` for a held file, which is
    /// neither. Words, never the dot alone: the dot is a redundant cue
    /// and the colour is never the only way to tell.
    public let saveWord: String
    /// Whether the unsaved dot is drawn beside the word.
    public let showsUnsavedDot: Bool
    /// `Thu 14:32` for a file whose buffer came back from the drafts
    /// file, so a person can judge the draft's age before saving over
    /// the file with it. Nil for everything else, including a file
    /// dirtied in this session, whose age a person already knows.
    public let lastEditStamp: String?
    /// `UTF-8 · Markdown`, `UTF-8 · Plain Text`, or a selected Source label,
    /// with the line ending
    /// appended when the file did not arrive with plain LF.
    public let encodingAndFormat: String
    /// The whole of the above in a sentence, for a reader who is
    /// hearing the header rather than looking at it.
    public let spoken: String

    /// The word that takes the save word's place on a held file. The
    /// header and the row both say it, so the two cannot describe one
    /// file differently.
    public static let notReadWord = "not read"

    /// The header's reading, derived. Pure, so the four readings are
    /// four assertions rather than four screenshots.
    public static func derive(
        from file: FileSummary, renderMode: FileRenderMode = .plainText
    ) -> FileHeaderState {
        // A held file is neither saved nor unsaved. Nothing of it was
        // read, so there is no copy here that could agree with the
        // disk or differ from it, and either word would be a claim
        // about text nobody has seen. The header says what is known
        // instead, in the words the row and the banner already use,
        // and draws no dot and no draft age beside it.
        if file.isHeld {
            return FileHeaderState(
                name: file.name,
                saveWord: notReadWord,
                showsUnsavedDot: false,
                lastEditStamp: nil,
                // The record's line ending is carried, but the format
                // facts describe text, and none is shown.
                encodingAndFormat: "",
                spoken: "\(file.name), \(notReadWord), this file cannot be read at its path"
            )
        }
        let dirty = file.isDirty
        let stamp: String? = (dirty && file.restoredFromDraft && file.lastEditedAt > 0)
            ? editStamp(unixSeconds: file.lastEditedAt)
            : nil
        var facts = "UTF-8 · \(renderMode.formatLabel)"
        if file.lineEnding == .crlf { facts += " · CRLF" }
        var spoken = "\(file.name), \(dirty ? "unsaved" : "saved")"
        if let stamp { spoken += ", last edited \(stamp)" }
        // Access refused is said in place of the conflict it may stand
        // in: "changed on disk" is what the core assumes of a copy it
        // cannot see, and what is actually known is that it cannot be
        // read.
        if file.accessRefused {
            spoken += ", this file cannot be read at its path"
        } else if file.conflict != .none {
            spoken += ", \(conflictSpoken(file.conflict))"
        } else if file.notFound {
            // Gone with no conflict standing, which is a clean copy or
            // one keep mine has answered. The words are the missing
            // conflict's, since the fact is the same one.
            spoken += ", \(conflictSpoken(.missing))"
        }
        return FileHeaderState(
            name: file.name,
            saveWord: dirty ? "unsaved" : "saved",
            showsUnsavedDot: dirty,
            lastEditStamp: stamp,
            encodingAndFormat: facts,
            spoken: spoken
        )
    }

    /// The selected presentation, not a filename inference. Filename hints
    /// are considered only when a file opens; the header reports the current
    /// choice afterwards.
    public static func format(for mode: FileRenderMode) -> String {
        mode.formatLabel
    }

    /// `Thu 14:32`: the same day name and clock time the block stamps
    /// carry (ADR-0013). Short on purpose, and for the same reason
    /// there: a full calendar date would overstate how long a draft is
    /// expected to sit unsaved.
    public static func editStamp(unixSeconds: UInt64) -> String {
        stampFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    /// The literal `HH` holds the clock at 24 hours whatever the locale
    /// says; the weekday name still localizes.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    private static func conflictSpoken(_ conflict: FileConflict) -> String {
        switch conflict {
        case .none: return ""
        case .changed: return "this file changed on disk"
        case .missing: return "this file is no longer at its path"
        }
    }
}

/// File suffix hints used for presentation and save-panel suggestions.
/// They never decide whether a file may be opened; the core evaluates the
/// actual bytes after every panel selection or drop.
enum FileFormatHints {
    /// Markdown's conventional extensions, used for the save panel and the
    /// initial Markdown rendering default.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdwn"]
}

/// A nonmodal rendering proposal shown after a source-language hint. Each
/// action changes session presentation only; it never edits the text storage.
public struct FileRenderSuggestionBanner: View {
    @ObservedObject private var model: PageModel
    public let suggestion: FileRenderSuggestion

    public init(model: PageModel, suggestion: FileRenderSuggestion) {
        _model = ObservedObject(wrappedValue: model)
        self.suggestion = suggestion
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text("render as \(suggestion.language)?")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button("Use \(suggestion.language)") {
                model.selectFileRenderMode(suggestion.mode, for: suggestion.fileID)
            }
            .font(.system(.caption, design: .monospaced))
            .controlSize(.small)
            .accessibilityLabel(Text("Use \(suggestion.language) rendering"))
            Button("Keep Plain Text") { model.keepFilePlainText(suggestion.fileID) }
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
            Menu("Choose Language…") {
                Button("Plain Text") { model.selectFileRenderMode(.plainText, for: suggestion.fileID) }
                Button("Markdown") { model.selectFileRenderMode(.markdown, for: suggestion.fileID) }
                if let contentHint = model.fileContentRenderHint(for: suggestion.fileID),
                   contentHint != suggestion.mode
                {
                    Divider()
                    Button("Detected: \(contentHint.formatLabel)") {
                        model.selectFileRenderMode(contentHint, for: suggestion.fileID)
                    }
                }
                Divider()
                ForEach(InkEditorView.Coordinator.manualLanguages, id: \.self) { language in
                    Button(language.capitalized) {
                        model.selectFileRenderMode(.source(language), for: suggestion.fileID)
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
            .controlSize(.small)
            Button("Dismiss") { model.dismissFileRenderSuggestion(suggestion.fileID) }
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Rendering suggestion: \(suggestion.language)"))
    }
}

/// What a row says out loud, wherever a file is drawn as a row: the
/// strip's FILES group and the rail's Files shelf both speak this, so
/// the two cannot describe the same file differently.
///
/// It says the save state in words. The dot beside it is a second way
/// of saying the same thing and never the only one, which is what keeps
/// the surface readable at any colour vision.
public enum FileRowLabel {
    public static func spoken(for file: FileSummary) -> String {
        // A held file is neither saved nor unsaved: nothing of it was
        // read. The row says so in the header's own word.
        if file.isHeld {
            return "file, \(file.name), \(FileHeaderState.notReadWord), cannot be read at its path"
        }
        var label = "file, \(file.name), \(file.isDirty ? "unsaved" : "saved")"
        if file.accessRefused {
            return label + ", cannot be read at its path"
        }
        switch file.conflict {
        case .none: if file.notFound { label += ", no longer at its path" }
        case .changed: label += ", changed on disk"
        case .missing: label += ", no longer at its path"
        }
        return label
    }

    /// The row's tooltip: the last known path, which is the fact a
    /// filename alone leaves out and the one two files of the same name
    /// need between them.
    public static func help(for file: FileSummary) -> String {
        file.path
    }
}

/// The unsaved marker: a small ember dot, drawn where a page's gauge
/// would be and never instead of the words beside it.
///
/// It takes the seat `EmptyRule` takes on a slot holding no page, for
/// the same reason: a file has no clock, and a gauge on a file would be
/// a countdown on something that is never going to expire.
struct UnsavedDot: View {
    var body: some View {
        Circle()
            .fill(Color.ember)
            .frame(width: 5, height: 5)
            .accessibilityHidden(true) // the row says "unsaved" in words
    }
}

/// The nonmodal dirty-close decision shown above the file editor. Editing
/// remains available while the request stands, including Return to insert a
/// newline. The banner does not claim a default keyboard action.
public struct FileCloseBanner: View {
    public let pending: PendingFileClose
    public let resolve: (FileCloseAction) -> Void

    public init(pending: PendingFileClose, resolve: @escaping (FileCloseAction) -> Void) {
        self.pending = pending
        self.resolve = resolve
    }

    public static func sentence(name: String) -> String {
        "\(name) has unsaved changes"
    }

    /// The tooltip for each action. Pure, so the three are testable as
    /// words. Discard is the one that destroys something, and its
    /// tooltip says so and says the draft does not come back.
    public static func help(for action: FileCloseAction) -> String {
        switch action {
        case .save:
            return "Write the file and close the tab once the write succeeds"
        case .discard:
            return "Close the tab and destroy the draft. It cannot be recovered."
        case .keepEditing:
            return "Leave the tab open with its draft intact"
        }
    }

    /// What VoiceOver reads after each action's label.
    public static func accessibilityHint(for action: FileCloseAction) -> String {
        switch action {
        case .save:
            return "Writes the file, then closes the tab"
        case .discard:
            return "Closes the tab and destroys the draft, which cannot be recovered"
        case .keepEditing:
            return "Leaves the tab open and keeps the draft"
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(Self.sentence(name: pending.name))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.emberText)
            Spacer(minLength: 8)
            Button(FileCloseAction.save.label) { resolve(.save) }
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
                .help(Self.help(for: .save))
                .accessibilityHint(Text(Self.accessibilityHint(for: .save)))
            Button(FileCloseAction.discard.label, role: .destructive) { resolve(.discard) }
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
                .help(Self.help(for: .discard))
                .accessibilityHint(Text(Self.accessibilityHint(for: .discard)))
            Button(FileCloseAction.keepEditing.label) { resolve(.keepEditing) }
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
                .help(Self.help(for: .keepEditing))
                .accessibilityHint(Text(Self.accessibilityHint(for: .keepEditing)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Self.sentence(name: pending.name)))
    }
}

/// The file changed on disk while this copy held unsaved edits, and
/// nothing is written until a person says which copy wins (ADR-0028).
///
/// Three actions, in the order they are read. Editing is not blocked while the
/// banner stands, including Return to insert a newline; only saving is refused.
///
/// A fourth action stands in front of the three when the other copy cannot be
/// reached at all, because the file is no longer at its path or cannot be read
/// there. Locate… does not choose between the copies. It finds the one that is
/// missing, and if the two still differ afterwards the three choose as before.
/// It leads because it is the one that answers the sentence, and Save As keeps
/// the last place, which is where the action that destroys nothing belongs.
///
/// Take theirs is not offered while the file cannot be read, or while it is no
/// longer at its path: there is no copy to take, and a button that can only
/// fail is not an action.
public struct FileConflictBanner: View {
    let file: FileSummary
    let resolve: (FileConflictResolution) -> Void

    public init(file: FileSummary, resolve: @escaping (FileConflictResolution) -> Void) {
        self.file = file
        self.resolve = resolve
    }

    /// The sentence, which names the file and says what is at stake.
    /// Pure, so the two conflicts are testable as words rather than as
    /// a drawn banner.
    public static func sentence(for conflict: FileConflict, name: String) -> String {
        switch conflict {
        case .none:
            return ""
        case .changed:
            return "\(name) changed on disk and this copy has unsaved edits · "
                + "saving is refused until one copy is chosen"
        case .missing:
            return "\(name) is no longer at its path and this copy has unsaved edits · "
                + "saving is refused until one copy is chosen"
        }
    }

    /// The sentence for the file as it stands, which is the one above
    /// unless the file cannot be read. Then the banner says that
    /// instead of "changed on disk": changed is what the core assumes
    /// of a copy it cannot see, and what is known is that it cannot be
    /// read.
    public static func sentence(for file: FileSummary) -> String {
        guard file.accessRefused, file.conflict != .none else {
            return sentence(for: file.conflict, name: file.name)
        }
        return "\(file.name) cannot be read at its path and this copy has unsaved edits · "
            + "saving is refused until one copy is chosen"
    }

    /// The actions the banner draws for a file, in the order they are
    /// read. Pure, so which file is offered what is testable without a
    /// drawn banner.
    public static func actions(for file: FileSummary) -> [FileConflictResolution] {
        var actions: [FileConflictResolution] = []
        if file.offersLocate { actions.append(.locate) }
        actions.append(.keepMine)
        if file.offersTakeTheirs { actions.append(.takeTheirs) }
        actions.append(.saveAs)
        return actions
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(Self.sentence(for: file))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.emberText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if file.offersLocate {
                FileLocateButton { resolve(.locate) }
            }
            // The two competing copies are named by the one each action keeps.
            Button("Keep mine") { resolve(.keepMine) }
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
                .help("Write this copy over the file on disk on the next save")
                .accessibilityLabel(Text("Keep my copy and overwrite the file"))
            if file.offersTakeTheirs {
                Button("Take theirs") { resolve(.takeTheirs) }
                    .font(.system(.caption, design: .monospaced))
                    .controlSize(.small)
                    .help("Replace this copy with the file on disk. Undo restores this copy.")
                    .accessibilityLabel(Text("Take the copy on disk; Undo restores my copy"))
            }
            Button("Save As") { resolve(.saveAs) }
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
                .help("Write this copy somewhere else and leave the file on disk alone")
                .accessibilityLabel(Text("Save my copy somewhere else and leave both"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Self.sentence(for: file)))
    }
}

/// The one Locate… button, drawn the same in both banners that offer it.
struct FileLocateButton: View {
    let action: () -> Void

    var body: some View {
        Button("Locate…", action: action)
            .font(.system(.caption, design: .monospaced))
            .controlSize(.small)
            .help("Choose where this file is now")
            .accessibilityLabel(Text("Locate the file"))
            .accessibilityHint(Text("Opens a panel to choose where the file is now"))
    }
}

/// The file cannot be reached where it was last known to be, because it cannot
/// be read there or because nothing is there, and there is no conflict for the
/// three actions to settle. That is one of three things: nothing of the file
/// was ever read, which is a file the launch is holding; this copy is clean;
/// or this copy has unsaved edits and keep mine has already answered the
/// conflict, so what is left to offer is the way to find the file.
///
/// A clean file never enters a conflict, so for a clean file that has gone
/// from its path this banner is the only standing sign of it, and the only
/// place Locate is offered.
///
/// The spec's unavailable state (docs/spec/feature/file-editing, Reopening on
/// relaunch): it names the last known path and offers two actions, one to
/// locate the file and one to close the tab. The tab never disappears on its
/// own and nothing is recreated at the path.
///
/// A held file shows no text, because none was read, and its editor takes no
/// typing. The banner is the whole of what the surface knows about it.
public struct FileUnavailableBanner: View {
    let file: FileSummary
    let locate: () -> Void
    let close: () -> Void

    public init(file: FileSummary, locate: @escaping () -> Void, close: @escaping () -> Void) {
        self.file = file
        self.locate = locate
        self.close = close
    }

    /// Whether this banner, rather than the conflict banner or none,
    /// is the one a file gets.
    public static func stands(for file: FileSummary) -> Bool {
        file.isUnavailable
    }

    /// The sentence, which names the file and the last known path.
    /// Pure, so it is testable as words.
    public static func sentence(name: String, path: String) -> String {
        "\(name) cannot be read at \(path)"
    }

    /// The sentence for a file with nothing at its path.
    public static func missingSentence(name: String, path: String) -> String {
        "\(name) is no longer at \(path)"
    }

    /// The sentence for the file as it stands. Access refused is said
    /// when both marks are somehow set, since it is the one that says
    /// something is there.
    public static func sentence(for file: FileSummary) -> String {
        if file.notFound, !file.accessRefused {
            return missingSentence(name: file.name, path: file.path)
        }
        return sentence(name: file.name, path: file.path)
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(Self.sentence(for: file))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.emberText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            FileLocateButton(action: locate)
            Button("Close", action: close)
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
                .help("Close the tab and leave the file on disk as it is")
                .accessibilityLabel(Text("Close the tab"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Self.sentence(for: file)))
    }
}
