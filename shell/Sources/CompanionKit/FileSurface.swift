import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    /// `saved` or `unsaved`. Words, never the dot alone: the dot is a
    /// redundant cue and the colour is never the only way to tell.
    public let saveWord: String
    /// Whether the unsaved dot is drawn beside the word.
    public let showsUnsavedDot: Bool
    /// `Thu 14:32` for a file whose buffer came back from the drafts
    /// file, so a person can judge the draft's age before saving over
    /// the file with it. Nil for everything else, including a file
    /// dirtied in this session, whose age a person already knows.
    public let lastEditStamp: String?
    /// `UTF-8 · Markdown` or `UTF-8 · Plain text`, with the line ending
    /// appended when the file did not arrive with plain LF.
    public let encodingAndFormat: String
    /// The whole of the above in a sentence, for a reader who is
    /// hearing the header rather than looking at it.
    public let spoken: String

    /// The header's reading, derived. Pure, so the four readings are
    /// four assertions rather than four screenshots.
    public static func derive(from file: FileSummary) -> FileHeaderState {
        let dirty = file.isDirty
        let stamp: String? = (dirty && file.restoredFromDraft && file.lastEditedAt > 0)
            ? editStamp(unixSeconds: file.lastEditedAt)
            : nil
        var facts = "UTF-8 · \(format(forName: file.name))"
        if file.lineEnding == .crlf { facts += " · CRLF" }
        var spoken = "\(file.name), \(dirty ? "unsaved" : "saved")"
        if let stamp { spoken += ", last edited \(stamp)" }
        if file.conflict != .none { spoken += ", \(conflictSpoken(file.conflict))" }
        return FileHeaderState(
            name: file.name,
            saveWord: dirty ? "unsaved" : "saved",
            showsUnsavedDot: dirty,
            lastEditStamp: stamp,
            encodingAndFormat: facts,
            spoken: spoken
        )
    }

    /// Plain text or Markdown, from the filename's own extension. The
    /// pad opens nothing else, so there is no third answer and no
    /// unknown: a name with no extension at all is plain text, which is
    /// what it will be read and written as.
    public static func format(forName name: String) -> String {
        let markdown: Set<String> = ["md", "markdown", "mdown", "mkd", "mdwn"]
        let ext = (name as NSString).pathExtension.lowercased()
        return markdown.contains(ext) ? "Markdown" : "Plain text"
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

/// Whether a dropped item is one the pad opens.
///
/// The decision is here and not at the drop site because it is a rule
/// about the feature rather than about the gesture: the open panel
/// filters on the same answer, and a drop that opened something the
/// panel would not offer would be a second, wider door into the same
/// room.
///
/// It is deliberately narrow. Anything that is not plain text as far as
/// the system is concerned is refused, and refused out loud: a drop
/// must never become a paste of the item's bytes into whatever page is
/// under the cursor, which is the one outcome here that would put a
/// person's file contents onto a page with a countdown on it.
public enum FileDropDecision {
    /// The Markdown extensions the pad answers to. Markdown has no
    /// single system type every editor agrees on, so the extension is
    /// what decides, and it decides the same way the format label does.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdwn"]

    /// Whether the pad opens the item at this path. Pure and taking a
    /// URL rather than a provider, so the rule is testable without a
    /// drag.
    public static func opens(_ url: URL) -> Bool {
        if markdownExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            // No extension at all, or one the system has never seen.
            // A file with no extension is usually plain text and the
            // core refuses it in one sentence if it is not, which is a
            // better answer than a drop that does nothing.
            return url.pathExtension.isEmpty
        }
        // Conformance rather than equality: .txt, .text, .log, .conf
        // and a source file all conform to plain text, and all of them
        // are files a person edits by hand.
        return type.conforms(to: .plainText)
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
        var label = "file, \(file.name), \(file.isDirty ? "unsaved" : "saved")"
        switch file.conflict {
        case .none: break
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

/// The unsaved marker: a small ember dot, drawn beside a file's name on
/// the strip and where a page's gauge would be on the rail, and never
/// instead of the words beside it.
///
/// On the rail it takes the seat `EmptyRule` takes on a day holding no
/// page, for the same reason: a file has no clock, and a gauge on a
/// file would be a countdown on something that is never going to
/// expire.
struct UnsavedDot: View {
    var body: some View {
        Circle()
            .fill(Color.ember)
            .frame(width: 5, height: 5)
            .accessibilityHidden(true) // the row says "unsaved" in words
    }
}

/// The file changed on disk while this copy held unsaved edits, and
/// nothing is written until a person says which copy wins (ADR-0028).
///
/// Three actions, in the order they are read, with Save As focused: it
/// is the only one of the three that destroys nothing, and a banner
/// that arrives under a person's hands should have its safe exit under
/// the return key. Editing is not blocked while it stands, because the
/// buffer is still theirs to work on; only saving is refused.
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
            return "\(name) changed on disk and this copy has unsaved edits. "
                + "Saving is refused until you choose."
        case .missing:
            return "\(name) is no longer at its path and this copy has unsaved edits. "
                + "Saving is refused until you choose."
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(Self.sentence(for: file.conflict, name: file.name))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.ember)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // Keep mine and Take theirs each destroy one of the two
            // copies, so they are named by what they keep rather than
            // by what they discard, and Save As sits last and focused.
            Button("Keep mine") { resolve(.keepMine) }
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
                .help("Write this copy over the file on disk on the next save")
                .accessibilityLabel(Text("Keep my copy and overwrite the file"))
            Button("Take theirs") { resolve(.takeTheirs) }
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
                .help("Discard the unsaved edits and read the file again. This asks first.")
                .accessibilityLabel(Text("Take the copy on disk and discard my unsaved edits"))
            Button("Save As") { resolve(.saveAs) }
                .font(.system(.caption, design: .monospaced))
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .help("Write this copy somewhere else and leave the file on disk alone")
                .accessibilityLabel(Text("Save my copy somewhere else and leave both"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Self.sentence(for: file.conflict, name: file.name)))
    }
}
