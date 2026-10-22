import AppKit
import CompanionKit

@MainActor
final class MainMenuController: NSObject, NSMenuDelegate {
    private unowned let app: BackdropAppDelegate
    private weak var closeItem: NSMenuItem?
    private weak var languageMenu: NSMenu?

    init(app: BackdropAppDelegate) {
        self.app = app
    }

    func install() {
        let main = NSMenu()
        let application = submenu(BackdropAppDelegate.productName, in: main)
        application.addItem(action("About \(BackdropAppDelegate.productName)") { [app] in app.showAbout() })
        application.addItem(.separator())
        application.addItem(action("Settings…", command: .appSettings) { [app] in app.openSettings() })
        application.addItem(action("Customize Keyboard Shortcuts…") { [app] in app.pages.openUserKeymapFile() })
        application.addItem(.separator())
        NSApp.servicesMenu = submenu("Services", in: application)
        application.addItem(.separator())
        application.addItem(responder("Hide \(BackdropAppDelegate.productName)", #selector(NSApplication.hide(_:)), key: "h"))
        application.addItem(responder("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]))
        application.addItem(responder("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        application.addItem(.separator())
        application.addItem(responder("Quit \(BackdropAppDelegate.productName)", #selector(NSApplication.terminate(_:)), key: "q"))

        let file = submenu("File", in: main)
        file.delegate = self
        file.addItem(action("New Page", command: .pageNew) { [app] in
            app.pages.perform(.pageNew)
            if !app.pages.holdsKeys { app.returnToOwner() }
        })
        file.addItem(action("Open…", command: .fileOpen) { [app] in app.pages.perform(.fileOpen) })
        file.addItem(.separator())
        file.addItem(action("Save", command: .stateSaveNow, enabled: onFile) { [app] in app.pages.perform(.stateSaveNow) })
        file.addItem(action("Save As…", command: .fileSaveAs, enabled: onFile) { [app] in app.pages.perform(.fileSaveAs) })
        file.addItem(.separator())
        let close = action("Close", command: .pageClose, enabled: { [unowned self] in self.closeChoice.isEnabled }) { [app] in
            app.pages.closeWhatIsShowing(app.keyWindow.closeTarget) {
                app.sendToResponder(#selector(NSWindow.performClose(_:)))
            }
        }
        closeItem = close
        file.addItem(close)

        let edit = submenu("Edit", in: main)
        edit.addItem(responder("Undo", #selector(EditStepResponder.undo(_:)), command: .editorUndo))
        edit.addItem(responder("Redo", #selector(EditStepResponder.redo(_:)), command: .editorRedo))
        edit.addItem(.separator())
        edit.addItem(responder("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(responder("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(responder("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(responder("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), key: "v", modifiers: [.command, .option, .shift]))
        edit.addItem(responder("Delete", #selector(NSText.delete(_:))))
        edit.addItem(responder("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        edit.addItem(.separator())
        edit.addItem(action(SealSelectionMenu.editMenuTitle, command: SealSelectionMenu.command,
                            enabled: { [app] in app.sealActions.canSeal }) { [app] in
            app.sendToResponder(#selector(SealResponder.sealSelectedContent(_:)))
        })
        if PageModel.languageDetectionFeaturesAvailable { addLanguageItems(to: edit) }
        edit.addItem(.separator())
        let find = submenu("Find", in: edit)
        for (title, key, modifiers, tag) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString)
        ] {
            let item = responder(title, #selector(NSTextView.performTextFinderAction(_:)), key: key, modifiers: modifiers)
            item.tag = tag.rawValue
            find.addItem(item)
        }
        let spelling = submenu("Spelling and Grammar", in: edit)
        spelling.addItem(responder("Show Spelling and Grammar", #selector(NSTextView.showGuessPanel(_:)), key: ":"))
        spelling.addItem(responder("Check Document Now", #selector(NSTextView.checkSpelling(_:)), key: ";"))
        spelling.addItem(responder("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        let substitutions = submenu("Substitutions", in: edit)
        substitutions.addItem(responder("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        substitutions.addItem(responder("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        substitutions.addItem(responder("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        substitutions.addItem(responder("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        let transformations = submenu("Transformations", in: edit)
        transformations.addItem(responder("Make Upper Case", #selector(NSTextView.uppercaseWord(_:))))
        transformations.addItem(responder("Make Lower Case", #selector(NSTextView.lowercaseWord(_:))))
        transformations.addItem(responder("Capitalize", #selector(NSTextView.capitalizeWord(_:))))
        let speech = submenu("Speech", in: edit)
        speech.addItem(responder("Start Speaking", #selector(NSTextView.startSpeaking(_:))))
        speech.addItem(responder("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))))

        let view = submenu("View", in: main)
        view.addItem(responder("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]))
        let window = submenu("Window", in: main)
        window.addItem(action("Open in Window") { [app] in app.openEditorPresentation() })
        window.addItem(action("Show Ambient Panel", enabled: { [app] in app.ambientPanelEnabled }) { [app] in app.showAmbientPresentation() })
        window.addItem(.separator())
        window.addItem(responder("Close Window", #selector(NSWindow.performClose(_:)), command: .windowClose))
        window.addItem(.separator())
        window.addItem(responder("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(responder("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(responder("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window
        let help = submenu("Help", in: main)
        help.addItem(action("Export Diagnostics…") { [app] in app.exportDiagnostics() })
        help.addItem(action("Copy Diagnostic Summary") { [app] in app.copyDiagnosticSummary() })
        help.addItem(.separator())
        help.addItem(action("Send Feedback…") { [app] in app.sendFeedback() })
        NSApp.mainMenu = main
    }

    private var onFile: () -> Bool {
        { [app] in if case .file = app.pages.activeTarget { true } else { false } }
    }

    private var closeChoice: CloseMenuItem {
        CloseMenuItem.resolve(target: app.keyWindow.closeTarget, showing: app.pages.activeTarget,
                              ledgerShowing: app.pages.showingLedger, keyWindowCanClose: app.keyWindow.canClose)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        closeItem?.title = closeChoice.title
        if menu === languageMenu { updateLanguages(in: menu) }
    }

    private var languageTarget: ManualLanguageChoiceTarget? {
        ManualLanguageChoiceTarget.resolve(
            editorCanChoose: app.pages.languageActions.canChoose,
            editorSelectionIsEmpty: app.pages.languageActions.selectionIsEmpty,
            selectedFile: app.pages.showingLedger ? nil : app.pages.selectedFile)
    }

    private func addLanguageItems(to edit: NSMenu) {
        edit.addItem(action("Detect Code Language", enabled: { [app] in app.pages.languageActions.canDetect }) { [app] in
            app.sendToResponder(#selector(LanguageDetectionResponder.detectCodeLanguage(_:)))
        })
        let choose = action("Choose Language", enabled: { [unowned self] in self.languageTarget != nil }) {}
        let languages = NSMenu(title: "Choose Language")
        languages.delegate = self
        choose.submenu = languages
        languageMenu = languages
        edit.addItem(choose)
        updateLanguages(in: languages)
        edit.addItem(action("Paste Without Detection", enabled: { [app] in app.pages.languageActions.canPaste }) { [app] in
            app.sendToResponder(#selector(LanguageDetectionResponder.pasteWithoutDetection(_:)))
        })
    }

    private func updateLanguages(in menu: NSMenu) {
        menu.removeAllItems()
        if case .file(let id) = languageTarget {
            menu.addItem(action("Plain Text") { [app] in app.pages.selectFileRenderMode(.plainText, for: id) })
            menu.addItem(action("Markdown") { [app] in app.pages.selectFileRenderMode(.markdown, for: id) })
            menu.addItem(.separator())
        }
        for language in InkEditorView.Coordinator.manualLanguages {
            menu.addItem(action(CodeLanguageName.display(language)) { [unowned self] in
                self.languageTarget?.choose(language, send: self.app.sendToResponder(_:carrying:)) { [app] mode, id in
                    app.pages.selectFileRenderMode(mode, for: id)
                }
            })
        }
    }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    private func action(_ title: String, command: CommandID? = nil,
                        enabled: @escaping () -> Bool = { true }, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = MenuActionItem(title: title, enabled: enabled, run: run)
        bind(command, to: item)
        return item
    }

    private func responder(_ title: String, _ selector: Selector, key: String = "",
                           modifiers: NSEvent.ModifierFlags = .command, command: CommandID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        if let command { bind(command, to: item) }
        return item
    }

    private func bind(_ command: CommandID?, to item: NSMenuItem) {
        let chord = command.flatMap { app.pages.keymap.menuKeystroke(for: $0) }
        item.keyEquivalent = chord?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = chord?.menuModifierMask ?? []
    }
}

@MainActor
private final class MenuActionItem: NSMenuItem, NSMenuItemValidation {
    private let run: () -> Void
    private let availability: () -> Bool

    init(title: String, enabled: @escaping () -> Bool, run: @escaping () -> Void) {
        self.run = run
        self.availability = enabled
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not archived") }

    @objc private func invoke() { run() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { availability() }
}
