import AppKit
import Foundation
import UniformTypeIdentifiers

/// What the close review came back with, when a file with unsaved
/// edits is asked to go away.
///
/// The three readings of the standard macOS review, named rather than
/// carried as an `NSApplication.ModalResponse`, so the model's logic
/// reads as three outcomes and a test can hand it one without a window
/// on screen.
public enum FileCloseReview: Equatable, Sendable {
    /// Write the file, then close it.
    case save
    /// Throw the unsaved edits away and close it.
    case discard
    /// Leave the file open exactly as it stands.
    case cancel
}

/// The panels and prompts a file feature has to raise, behind a
/// protocol so the model never touches AppKit directly and a test can
/// script every answer.
///
/// Every one of them is modal and blocking, which is why they are
/// posed as plain returning functions rather than as callbacks: the
/// model's own logic is a straight line through them, and a callback
/// would spread one decision over three places.
@MainActor
public protocol FilePanels {
    /// Ask for a file to open. Nil means the person cancelled.
    func chooseFileToOpen() -> URL?

    /// Ask where to write a file. Nil means the person cancelled.
    func chooseDestination(suggestedName: String) -> URL?

    /// The Save, Discard, Cancel review a dirty file takes before it
    /// closes.
    func reviewUnsavedFile(named name: String) -> FileCloseReview

    /// The confirmation Take theirs asks for, since it throws away
    /// unsaved edits with no way back. True means go ahead.
    func confirmDiscardingEdits(named name: String) -> Bool
}

/// The one place in the app that raises a file panel, makes a
/// bookmark, or resolves one.
///
/// Two reasons it is one place rather than a helper called from
/// several. The panels are the app's only route to a path outside its
/// own state directory, so keeping them here makes that route
/// countable. And the access bracket below is where the security
/// scoped variant will go when the sandbox arrives, and a bracket that
/// can be bypassed is not a bracket.
@MainActor
public final class FileCoordinator {
    /// The panels this coordinator raises: the real ones in the app,
    /// scripted ones under a test.
    public let panels: FilePanels

    /// The default panels are the real ones in the app and refusing
    /// ones under the test runner.
    ///
    /// Enforced here rather than left to each suite, on the same
    /// reasoning as the state directory's own refusal
    /// (`FormFactor.refusesProductionStateUnderTests`): a panel is
    /// modal, so a test that reached one would not fail, it would hang
    /// the whole run with an alert nobody is looking at. A suite that
    /// wants an answer scripts one; a suite that never meant to raise
    /// a panel gets a cancel, which is the outcome a person who was
    /// not asked would have given.
    public init(panels: FilePanels? = nil) {
        if let panels {
            self.panels = panels
        } else if FormFactor.runningUnderTests {
            self.panels = RefusingFilePanels()
        } else {
            self.panels = SystemFilePanels()
        }
    }

    // MARK: Bookmarks

    /// A bookmark for a file, so a relaunch can find it again after a
    /// rename or a move.
    ///
    /// A plain bookmark, not a security scoped one. This app declares
    /// no sandbox entitlement today, and asking for
    /// `.withSecurityScope` without the entitlement fails rather than
    /// degrading. When the TestFlight sandbox arrives this gains
    /// `.withSecurityScope` and `withAccess(toBookmark:)` below gains
    /// its matching pair of calls, and those are the only two lines
    /// that change.
    public static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolve a bookmark and run `body` on the file it names, inside
    /// the access bracket.
    ///
    /// Resolution and access are one function on purpose. Under the
    /// sandbox a resolved URL is not yet a readable one:
    /// `startAccessingSecurityScopedResource` has to be running while
    /// the read or the write happens, and its `stop` has to run
    /// afterwards whatever the body did. Splitting the two into a
    /// resolver and a bracket is what lets a caller take the first and
    /// forget the second, so there is no resolver to call on its own.
    /// The IO itself is the core's, which means the bracket wraps a
    /// call across the seam rather than a `Data(contentsOf:)`, and
    /// that is exactly what has to be true for the write to be inside
    /// it.
    ///
    /// `isStale` is handed to the body rather than acted on here: only
    /// the caller knows whether it has a file to make a fresh bookmark
    /// from and somewhere to put it.
    public static func withAccess<T>(
        toBookmark data: Data, _ body: (_ url: URL, _ isStale: Bool) -> T
    ) -> T? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        // Not sandboxed today, so this is the identity bracket. Under
        // the sandbox it becomes start, defer stop, around exactly the
        // same body.
        return body(url, isStale)
    }

    /// A fresh bookmark for a file whose old one resolved stale,
    /// which is what a rename or a move on a volume that was remounted
    /// leaves behind. Nil when the file is no longer there to make one
    /// from, which is a missing file and not a stale bookmark.
    public static func refreshedBookmark(after url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return bookmark(for: url)
    }

    // MARK: Panels

    public func chooseFileToOpen() -> URL? { panels.chooseFileToOpen() }

    public func chooseDestination(suggestedName: String) -> URL? {
        panels.chooseDestination(suggestedName: suggestedName)
    }

    public func reviewUnsavedFile(named name: String) -> FileCloseReview {
        panels.reviewUnsavedFile(named: name)
    }

    public func confirmDiscardingEdits(named name: String) -> Bool {
        panels.confirmDiscardingEdits(named: name)
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
    public func reviewUnsavedFile(named name: String) -> FileCloseReview { .cancel }
    public func confirmDiscardingEdits(named name: String) -> Bool { false }
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a UTF-8 text file."
        // Bracketed, as every modal of ours is, so the surface learns
        // when the panel has returned and comes forward again.
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

    public func reviewUnsavedFile(named name: String) -> FileCloseReview {
        let alert = NSAlert()
        alert.messageText = "Save the changes to \(name)?"
        alert.informativeText = "Your changes will be lost if you do not save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        switch ModalSession.run({ alert.runModal() }) {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    public func confirmDiscardingEdits(named name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Take the copy on disk for \(name)?"
        alert.informativeText =
            "Your unsaved changes go, and there is no undo. The file is read again from disk."
        alert.addButton(withTitle: "Take theirs")
        alert.addButton(withTitle: "Cancel")
        return ModalSession.run { alert.runModal() } == .alertFirstButtonReturn
    }
}
