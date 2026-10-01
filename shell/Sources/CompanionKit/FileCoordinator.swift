import AppKit
import Foundation
import UniformTypeIdentifiers

/// The system file panels, behind a protocol so the model never touches
/// AppKit directly and a test can script every answer. Dirty-close and
/// conflict decisions are inline model state and do not belong here.
@MainActor
public protocol FilePanels {
    /// Ask for a file to open. Nil means the person cancelled.
    func chooseFileToOpen() -> URL?

    /// Ask where to write a file. Nil means the person cancelled.
    func chooseDestination(suggestedName: String) -> URL?

    /// Ask where a file the app can no longer reach is now. The panel
    /// opens in `directory`, which is where the file was last known to
    /// be, and names the file it is asking about. Nil means the person
    /// cancelled.
    func chooseFileToLocate(named name: String, in directory: URL) -> URL?
}

/// The two calls that open and close a security scope, behind a
/// protocol so a test can count them.
///
/// The pair is the whole of what the sandbox asks of this app at
/// runtime, and the only thing that can go wrong with it quietly is an
/// imbalance: a start with no stop leaks a kernel resource until the
/// process ends, and a stop with no start is a call on a grant that
/// was never open. Neither fails at the call site. A counted seam is
/// the one way to see either, so every start and every stop in the app
/// goes through this and nowhere else.
public protocol SecurityScoping {
    /// Open the scope on `url`. False when there was nothing to open,
    /// which is the ordinary answer for a URL that carries no grant.
    func startAccessing(_ url: URL) -> Bool

    /// Close a scope `startAccessing` opened. Called only after a true.
    func stopAccessing(_ url: URL)
}

/// The real pair.
public struct SystemSecurityScoping: SecurityScoping {
    public init() {}

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// What a bookmark resolved to, handed to the body that runs inside
/// its access bracket.
public struct BookmarkAccess {
    /// Where the file is now, which after a move is not where the
    /// bookmark was made.
    public let url: URL

    /// The bookmark resolved but wants remaking. Handed to the body
    /// rather than acted on by the bracket: only the caller knows
    /// whether it has somewhere to put a fresh one.
    public let isStale: Bool

    /// Whether the bookmark was a security scoped one. False for a
    /// record written before the scoped bookmarks: it resolves, and
    /// the body runs, but no scope was opened, so under the sandbox
    /// the read inside it is refused and the caller hears that from
    /// the core in the ordinary way.
    public let isScoped: Bool
}

/// The one place in the app that raises a file panel, makes a
/// bookmark, resolves one, or opens a security scope.
///
/// Three reasons it is one place rather than a helper called from
/// several. The panels are the app's only route to a path outside its
/// own state directory, so keeping them here makes that route
/// countable. The access brackets below are what let a sandboxed build
/// read and write a file the person chose, and a bracket that can be
/// bypassed is not a bracket. And the staging directory a save writes
/// its temp file in is the third thing the sandbox decides, so it is
/// handed out here beside the other two.
///
/// One code path serves the sandboxed lane and the unsandboxed ones.
/// Outside a sandbox a scoped bookmark is made and resolved the same
/// way and the start and stop calls succeed without granting anything
/// new, so nothing here asks which lane it is running in.
@MainActor
public final class FileCoordinator {
    /// The open and save panels this coordinator raises: the real ones
    /// in the app, scripted ones under a test.
    public let panels: FilePanels

    /// The start and stop pair every bracket goes through: the real
    /// one in the app, a counting one under a test.
    public let scope: SecurityScoping

    /// Where a save to `target` stages its temp file, or nil when no
    /// such directory can be had.
    ///
    /// Settable so a test can stand in front of the refusal. The
    /// default asks the system for an item replacement directory for
    /// the target. What is known about that directory is what was
    /// observed, not something this code holds the system to: in the
    /// sandbox probe runs the directory handed back was one a rename
    /// onto the target succeeded from. Nothing here relies on that
    /// always holding. If the directory is ever on another volume the
    /// rename fails, the core takes its temp file back, and the save
    /// is refused out loud with the file on disk untouched.
    public var makeStagingDirectory: (_ target: URL) -> URL? = FileCoordinator.itemReplacementDirectory

    /// The default panels are the real ones in the app and refusing
    /// ones under the test runner.
    ///
    /// Enforced here rather than left to each suite, on the same
    /// reasoning as the state directory's own refusal
    /// (`FormFactor.refusesProductionStateUnderTests`): a panel is
    /// modal, so a test that reached one would not fail, it would hang
    /// the whole run with a panel nobody is looking at. A suite that
    /// wants an answer scripts one; a suite that never meant to raise
    /// a panel gets a cancel, which is the outcome a person who was
    /// not asked would have given.
    ///
    /// The scope defaults to the real pair under the runner as well.
    /// It touches no state of the installed app, and outside a sandbox
    /// it changes nothing a test can see.
    public init(panels: FilePanels? = nil, scope: SecurityScoping = SystemSecurityScoping()) {
        if let panels {
            self.panels = panels
        } else if FormFactor.runningUnderTests {
            self.panels = RefusingFilePanels()
        } else {
            self.panels = SystemFilePanels()
        }
        self.scope = scope
    }

    // MARK: Bookmarks

    /// A security scoped bookmark for a file, so a relaunch can find
    /// it again after a rename or a move, and under the sandbox can
    /// read and write it again at all.
    ///
    /// Call it while access to the file is open: inside the panel
    /// bracket for a file just chosen, inside the bookmark bracket for
    /// one being refreshed. A sandboxed process that asks outside one
    /// is refused.
    ///
    /// It throws rather than answering nil, because a file without a
    /// bookmark is a file the next launch may not be able to reopen,
    /// and the person is owed a sentence about that while the file is
    /// still in front of them.
    ///
    /// A bookmark follows the file it was made from, and a save
    /// replaces that file with a new one at the same path. So the
    /// bookmark is made again after every save and every Save As, not
    /// only at the open.
    public func bookmark(for url: URL) throws -> Data {
        try makeBookmark(url)
    }

    /// The call `bookmark(for:)` makes. Settable for the same reason
    /// the staging directory is: a refusal here is a sandbox answer,
    /// and a test has no other way to stand in front of one.
    public var makeBookmark: (_ url: URL) throws -> Data = { url in
        try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolve a bookmark and run `body` on the file it names, inside
    /// the access bracket. Nil when the bookmark resolves to nothing,
    /// in which case `body` did not run and the caller falls back to
    /// the path it has on record, with no scope.
    ///
    /// Resolution and access are one function on purpose. Under the
    /// sandbox a resolved URL is not yet a readable one: the scope has
    /// to be open while the read or the write happens, and it has to
    /// be closed afterwards whatever the body did. Splitting the two
    /// into a resolver and a bracket is what lets a caller take the
    /// first and forget the second, so there is no resolver to call on
    /// its own. The IO itself is the core's, which means the bracket
    /// wraps a call across the seam rather than a `Data(contentsOf:)`,
    /// and that is exactly what has to be true for the write to be
    /// inside it.
    ///
    /// The stop is owed only for a start that answered true, and it is
    /// made on the same URL the start was.
    ///
    /// A bookmark that will not resolve as a scoped one is tried again
    /// as a plain one, which is what every record written before the
    /// scoped bookmarks holds. The body then runs with no scope open.
    /// Outside a sandbox that is all it needs. Inside one the core's
    /// read is refused, and that file alone says so.
    ///
    /// Neither resolution mounts a volume or raises a panel of its
    /// own. A file on a share that is not mounted is a missing file
    /// for now, and the brackets run on every activation, which is no
    /// moment to start a mount nobody asked for.
    public func withAccess<T>(
        toBookmark data: Data, _ body: (BookmarkAccess) -> T
    ) -> T? {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            let started = scope.startAccessing(url)
            defer { if started { scope.stopAccessing(url) } }
            return body(BookmarkAccess(url: url, isStale: isStale, isScoped: true))
        }
        isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return body(BookmarkAccess(url: url, isStale: isStale, isScoped: false))
    }

    /// Run `body` with access open on a URL a panel or a drop handed
    /// over.
    ///
    /// Such a URL usually carries its grant already and the start
    /// answers false, which is tolerated: the body runs either way.
    /// The start is made regardless because a URL that arrives by
    /// another road, a drop or a file the system asked the app to
    /// open, may need it, and asking costs nothing when it does not.
    public func withAccess<T>(to url: URL, _ body: () -> T) -> T {
        let started = scope.startAccessing(url)
        defer { if started { scope.stopAccessing(url) } }
        return body()
    }

    // MARK: The Trash

    /// Whether `url` names something inside a Trash: the person's own
    /// or the one a volume keeps for them.
    ///
    /// Asked at a relaunch of where a bookmark resolved to. A bookmark
    /// follows its file, and a file moved to the Trash is followed
    /// there, where it keeps its identity and so looks exactly like a
    /// file that was merely moved. A person who threw a file away did
    /// not move it, and a tab that came back bound to the Trash would
    /// save their next edit into it without a word. So a bookmark that
    /// leads there is treated as one that leads nowhere.
    ///
    /// Settable because the real answer needs a real Trash, which is
    /// no place for a test to leave things.
    public var isInTrash: (_ url: URL) -> Bool = FileCoordinator.systemTrashContains

    /// The system's answer. An item it cannot place, which includes
    /// one that is not there, is not in the Trash: the read that
    /// follows reports on it in the ordinary way.
    public nonisolated static func systemTrashContains(_ url: URL) -> Bool {
        var relationship = FileManager.URLRelationship.other
        do {
            try FileManager.default.getRelationship(
                &relationship, of: .trashDirectory, in: [], toItemAt: url)
        } catch {
            return false
        }
        return relationship == .contains
    }

    // MARK: Staging

    /// Run `body` with a directory to stage a save to `target` in, and
    /// remove the directory afterwards whatever the body did.
    ///
    /// A grant on a document covers the document and not the directory
    /// it sits in, so a sandboxed save cannot make its temp file
    /// beside the target. It makes it here instead and renames it onto
    /// the target, and the rename is the one step the grant is needed
    /// for. Every lane stages this way, so the builds a developer runs
    /// exercise the route the sandboxed build depends on.
    ///
    /// The body is handed nil only when no directory can be had, and
    /// the core then makes the temp file beside the target as it
    /// always did. After a save that landed, the temp file was renamed
    /// away; after one that did not, the core took it back. Either way
    /// the directory is empty by the time it is removed.
    public func withStagingDirectory<T>(for target: URL, _ body: (URL?) -> T) -> T {
        let directory = makeStagingDirectory(target)
        defer {
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        return body(directory)
    }

    /// The system's own answer to where a replacement for `target`
    /// should be staged.
    ///
    /// Asked of the target first and of its directory second, because
    /// a Save As names a file that does not exist yet and the question
    /// is really about the volume.
    public nonisolated static func itemReplacementDirectory(for target: URL) -> URL? {
        let manager = FileManager.default
        for anchor in [target, target.deletingLastPathComponent()] {
            if let directory = try? manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: anchor, create: true
            ) {
                return directory
            }
        }
        return nil
    }

    // MARK: Panels

    public func chooseFileToOpen() -> URL? { panels.chooseFileToOpen() }

    public func chooseDestination(suggestedName: String) -> URL? {
        panels.chooseDestination(suggestedName: suggestedName)
    }

    /// Ask where the file last known at `recordedPath` is now.
    ///
    /// The panel is the grant as much as the answer. Under the sandbox
    /// a file the person picks in it is one the app may read and write
    /// again, which is the whole of what a file that lost its access
    /// needs, so the same panel serves a file that moved and a file
    /// that never did.
    public func chooseFileToLocate(recordedPath: String) -> URL? {
        let recorded = URL(fileURLWithPath: recordedPath)
        return panels.chooseFileToLocate(
            named: recorded.lastPathComponent, in: recorded.deletingLastPathComponent())
    }
}

/// The panels a test run gets unless it scripts its own: every one of
/// them answers the way an untouched panel does.
///
/// Cancel rather than a crash, deliberately. Most of the suite has
/// nothing to do with files and reaches a panel only by accident, and
/// a cancel leaves the model exactly where it was, which is what such
/// a test is asserting anyway.
@MainActor
public struct RefusingFilePanels: FilePanels {
    public init() {}
    public func chooseFileToOpen() -> URL? { nil }
    public func chooseDestination(suggestedName: String) -> URL? { nil }
    public func chooseFileToLocate(named name: String, in directory: URL) -> URL? { nil }
}

/// The real panels: the ones with a window.
///
/// The open panel allows every file type because the core decides whether
/// the selected item can be opened as UTF-8 text. The save panel retains its
/// plain-text and Markdown suggestions.
@MainActor
public struct SystemFilePanels: FilePanels {
    public init() {}

    /// The types the save panel offers first. Markdown has no single system
    /// type every editor agrees on, so the extensions are listed beside
    /// `.plainText`.
    static var offeredTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        for ext in FileFormatHints.markdownExtensions.sorted() {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    public func chooseFileToOpen() -> URL? {
        runOpenPanel(prompt: "Open", message: "Choose a UTF-8 text file.", startingIn: nil)
    }

    /// The one open panel, for both of the questions it is asked: which
    /// file to open, and where a file is now. One file, never a
    /// directory, never several.
    private func runOpenPanel(prompt: String, message: String, startingIn directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let directory { panel.directoryURL = directory }
        panel.prompt = prompt
        panel.message = message
        // The open panel and Save As are the app's modal entry points.
        // The bracket lets the surface learn when the panel has returned.
        return ModalSession.run { panel.runModal() } == .OK ? panel.url : nil
    }

    public func chooseDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = Self.offeredTypes
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        return ModalSession.run { panel.runModal() } == .OK ? panel.url : nil
    }

    /// The open panel again, started where the file was last known to
    /// be and saying which file it is asking about.
    ///
    /// An open panel has no name field to fill in, so the name goes in
    /// the message, which is the one place the panel gives for it. The
    /// starting directory is a request: the system shows it when it
    /// still exists and falls back to its own choice when it does not.
    public func chooseFileToLocate(named name: String, in directory: URL) -> URL? {
        runOpenPanel(
            prompt: "Locate", message: Self.locateMessage(named: name), startingIn: directory)
    }

    /// What the locate panel says above its file list. Pure, so the
    /// words are testable without a panel.
    public nonisolated static func locateMessage(named name: String) -> String {
        "Choose where \(name) is now."
    }
}
