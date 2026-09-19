import AppKit
import Combine
import CompanionKit
import SwiftUI
import os

/// The primary editor window (ADR-0033), spike quality (issue #197):
/// an ordinary titled, resizable window at normal level over the same
/// pages the panel shows. It exists to dogfood the ADR's first three
/// eject triggers before presentation ownership (B2) is built, and it
/// does not ship in this form.
///
/// One store, one model: the root view is handed the panel's own
/// `PageModel`, never a second one. Two surfaces over one model cannot
/// both mount the editor yet, so ownership here is the crudest thing
/// that works: `BackdropModel.editorWindowOpen` stands for as long as
/// this window is open, and while it stands the panel rests, mounts no
/// page content and refuses every raise.
///
/// The window is built on each open and dropped on each close. A closed
/// window keeps its hosting view, and a hosting view keeps its editor
/// mounted, which is exactly the second mount the flag exists to
/// prevent. The frame survives through the autosave name, in defaults.
@MainActor
final class PrimaryEditorWindowController: NSObject, NSWindowDelegate {
    private let model: BackdropModel
    private var window: NSWindow?
    private var captureObserver: AnyCancellable?

    /// The defaults key the frame rests under between runs. State
    /// restoration is off (`isRestorable`), so this is the only thing
    /// of the window's that outlives the process.
    private static let frameAutosaveName = "PrimaryEditorWindow"

    init(model: BackdropModel) {
        self.model = model
        super.init()
    }

    /// Open the window, or bring the open one forward.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // The flag before the window: the panel has to have let go of
        // the pages by the time this window's editor mounts.
        model.editorWindowOpened()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // The app's name and nothing else, ever. A title reaches
        // Mission Control and the window list, which is further than
        // `sharingType` covers, so no page title or content goes in it.
        window.title = BackdropAppDelegate.productName
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 280)
        // No saved application state: restoration would write a
        // snapshot of the window, ink included, under
        // ~/Library/Saved Application State.
        window.isRestorable = false
        // Capture exclusion (docs/spec/05), on the panel's own terms:
        // closed at creation, and lifted only by the debug opt out, which
        // is observed only when this launch offers it.
        window.sharingType = .none
        if PageModel.captureOptOutOffered {
            captureObserver = model.pages.$allowCapture
                .sink { [weak window] allow in
                    window?.sharingType = allow ? .readOnly : .none
                }
        }
        window.contentView = NSHostingView(
            rootView: PrimaryEditorRootView(pages: model.pages)
        )
        window.delegate = self
        // Centre first, autosave second: setting the name restores a
        // saved frame over the centred one, and a first run keeps the
        // centre.
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.window = window

        window.makeKeyAndOrderFront(nil)
        model.pages.focusEditorWhenMounted(in: window)
        Self.logger.info("editor window=open")
    }

    // MARK: NSWindowDelegate

    /// Key status feeds the shared model, as the panel's does: the
    /// editor's focus rules and the ember border read it there.
    func windowDidBecomeKey(_ notification: Notification) {
        model.holdsKeys = true
    }

    func windowDidResignKey(_ notification: Notification) {
        model.holdsKeys = false
    }

    /// Tear the content down before the panel is told, so this window's
    /// editor is on its way out by the time the panel's mounts again.
    func windowWillClose(_ notification: Notification) {
        captureObserver = nil
        window?.delegate = nil
        window?.contentView = nil
        window = nil
        model.holdsKeys = false
        model.editorWindowClosed()
        Self.logger.info("editor window=closed")
    }

    /// Mechanics only, never content; the surface's own subsystem.
    private static let logger = Logger(
        subsystem: FormFactor.backdrop.loggerSubsystem, category: "editor-window"
    )
}

/// The editor window's face: the shared page surface in a plain stack,
/// with whichever page picker the person has chosen, where they chose
/// to have it. The archived panel's `WindowRootView` is the skeleton;
/// the title bar stands in for its header.
private struct PrimaryEditorRootView: View {
    @ObservedObject var pages: PageModel

    var body: some View {
        VStack(spacing: 0) {
            if pages.showsPagesDownSide {
                HStack(spacing: 0) {
                    if pages.showsTimeUnits {
                        TimeRailView(model: pages)
                    } else {
                        SlotRailView(model: pages)
                    }
                    Divider()
                    content
                }
            } else {
                content
            }
            PageStatusStack(model: pages)
            if !pages.showsPagesDownSide {
                Divider()
                if pages.showsTimeUnits {
                    TimeStripView(model: pages)
                } else {
                    TabStripView(model: pages)
                }
            }
        }
        .background(Color.panelBackground)
        .background(PageKeyboardMap(model: pages))
    }

    private var content: some View {
        PageContentView(model: pages, emptyHint: "click or ↩ to start one")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
