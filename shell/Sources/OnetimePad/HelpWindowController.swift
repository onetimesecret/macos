import AppKit

/// Local usage guidance, available without opening a browser or signing in.
@MainActor
final class HelpWindowController {
    private var window: NSWindow?
    private let levelFollower: CompanionLevelFollower

    init(model: BackdropModel) {
        levelFollower = CompanionLevelFollower(model: model)
    }

    func show() {
        if window == nil {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            let text = NSTextView(frame: scroll.contentView.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.isRichText = false
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            text.textColor = .labelColor
            text.backgroundColor = .textBackgroundColor
            text.textContainerInset = NSSize(width: 20, height: 20)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                       height: .greatestFiniteMagnitude)
            text.setAccessibilityLabel("OnetimePad usage guide")
            text.string = """
            OnetimePad Help

            Write on a page
            Choose File → New Page to start writing. In Timeline layout, this opens today's page; choose it again while on today's page to create another. Type or paste into the page. Use Edit → Undo and Redo to step through edits.

            Navigate pages
            Select a page in the sidebar or bottom tabs. General Settings lets you choose Timeline or Tabs layout. Timeline groups pages by day.

            Switch presentations
            Choose Window → Open in Window for the primary editor, or Window → Show Ambient Panel for the ambient panel. Enable the ambient panel in General Settings to make that command available.

            Open a file
            Choose File → Open. Save, Save As, and Close File apply to the open file. Close Window in the Window menu closes the window.

            Configure shortcuts
            Choose OnetimePad → Customize Keyboard Shortcuts to edit your keymap. Menu commands display the configured shortcuts when a binding is available.

            Get support
            Choose Help → Send Feedback to describe a problem. Review the feedback window before sending. Export Diagnostics saves a diagnostic report you can inspect.
            """
            scroll.documentView = text
            let window = NSWindow(contentRect: scroll.frame,
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "OnetimePad Help"
            window.contentView = scroll
            window.contentMinSize = NSSize(width: 360, height: 260)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.center()
            self.window = window
        }
        if let window { levelFollower.follow(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
