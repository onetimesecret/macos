import AppKit
import CompanionKit

@MainActor
final class MainMenuController: NSObject, NSMenuDelegate {
    private unowned let app: BackdropAppDelegate
    private weak var closeItem: NSMenuItem?
    private weak var languageMenu: NSMenu?
    private weak var timelineItem: NSMenuItem?
    private weak var tabsItem: NSMenuItem?

    init(app: BackdropAppDelegate) {
        self.app = app
    }

    func install() {
        let main = NSMenu()
        let services = makeApplicationMenu(in: main)
        makeFileMenu(in: main)
        makeEditMenu(in: main)
        makeViewMenu(in: main)
        let window = makeWindowMenu(in: main)
        let help = makeHelpMenu(in: main)
        NSApp.mainMenu = main
        NSApp.servicesMenu = services
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
    }

    private func makeApplicationMenu(in main: NSMenu) -> NSMenu {
        let application = submenu(BackdropAppDelegate.productName, in: main)
        application.addItem(action(CompanionL10n.format("About %@", BackdropAppDelegate.productName)) { [app] in app.showAbout() })
        application.addItem(.separator())
        application.addItem(action(CompanionL10n.string("Settings…"), command: .appSettings) { [app] in app.openSettings() })
        application.addItem(action(CompanionL10n.string("Customize Keyboard Shortcuts…")) { [app] in app.pages.openUserKeymapFile() })
        application.addItem(.separator())
        let services = NSApp.servicesMenu ?? NSMenu(title: CompanionL10n.string("Services"))
        services.supermenu?.items.first { $0.submenu === services }?.submenu = nil
        let servicesItem = NSMenuItem(title: CompanionL10n.string("Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        application.addItem(servicesItem)
        application.addItem(.separator())
        application.addItem(responder(CompanionL10n.format("Hide %@", BackdropAppDelegate.productName), #selector(NSApplication.hide(_:)), key: "h"))
        application.addItem(responder(CompanionL10n.string("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]))
        application.addItem(responder(CompanionL10n.string("Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        application.addItem(.separator())
        application.addItem(responder(CompanionL10n.format("Quit %@", BackdropAppDelegate.productName), #selector(NSApplication.terminate(_:)), key: "q"))
        return services
    }

    private func makeFileMenu(in main: NSMenu) {
        let file = submenu(CompanionL10n.string("File"), in: main)
        file.delegate = self
        file.addItem(action(CompanionL10n.string("New Page"), command: .pageNew) { [app] in
            app.pages.perform(.pageNew)
            if !app.pages.holdsKeys { app.returnToOwner() }
        })
        file.addItem(action(CompanionL10n.string("Open…"), command: .fileOpen) { [app] in app.pages.perform(.fileOpen) })
        file.addItem(.separator())
        file.addItem(action(CompanionL10n.string("Save"), command: .stateSaveNow, enabled: onFile) { [app] in app.pages.perform(.stateSaveNow) })
        file.addItem(action(CompanionL10n.string("Save As…"), command: .fileSaveAs, enabled: onFile) { [app] in app.pages.perform(.fileSaveAs) })
        file.addItem(.separator())
        let close = action(CompanionL10n.string("Close"), command: .pageClose, enabled: { [weak self] in
            guard let self else { return false }
            return self.app.commandPaletteIsShowing || self.closeChoice.isEnabled
        }) { [app] in
            if app.dismissCommandPaletteForClose() { return }
            app.pages.closeWhatIsShowing(app.keyWindow.closeTarget) {
                app.sendToResponder(#selector(NSWindow.performClose(_:)))
            }
        }
        closeItem = close
        file.addItem(close)
        file.addItem(action(CompanionL10n.string("Reopen Last Closed Page or Tab"), command: .pageReopenLast,
                            enabled: { [app] in app.pages.hasClosedTabs }) { [app] in
            app.pages.perform(.pageReopenLast)
            app.returnToOwner()
        })
        file.addItem(action(CompanionL10n.string("Reopen Dated Tabs…"), command: .pageReopenDated) { [app] in
            app.showCommandPalette(reopen: true)
        })
    }

    private func makeEditMenu(in main: NSMenu) {
        let edit = submenu(CompanionL10n.string("Edit"), in: main)
        edit.addItem(responder(CompanionL10n.string("Undo"), #selector(EditStepResponder.undo(_:)), command: .editorUndo))
        edit.addItem(responder(CompanionL10n.string("Redo"), #selector(EditStepResponder.redo(_:)), command: .editorRedo))
        edit.addItem(.separator())
        edit.addItem(responder(CompanionL10n.string("Cut"), #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(responder(CompanionL10n.string("Copy"), #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(responder(CompanionL10n.string("Paste"), #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(responder(CompanionL10n.string("Paste and Match Style"), #selector(NSTextView.pasteAsPlainText(_:)), key: "v", modifiers: [.command, .option, .shift]))
        edit.addItem(responder(CompanionL10n.string("Delete"), #selector(NSText.delete(_:))))
        edit.addItem(responder(CompanionL10n.string("Select All"), #selector(NSText.selectAll(_:)), key: "a"))
        edit.addItem(.separator())
        edit.addItem(action(CompanionL10n.string(SealSelectionMenu.editMenuTitle), command: SealSelectionMenu.command,
                            enabled: { [app] in app.sealActions.canSeal }) { [app] in
            app.sendToResponder(#selector(SealResponder.sealSelectedContent(_:)))
        })
        if PageModel.languageDetectionFeaturesAvailable { addLanguageItems(to: edit) }
        edit.addItem(.separator())
        let find = submenu(CompanionL10n.string("Find"), in: edit)
        for (title, key, modifiers, tag) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find and Replace…", "f", [.command, .option], .showReplaceInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString)
        ] {
            let item = responder(CompanionL10n.string(title), #selector(NSTextView.performTextFinderAction(_:)), key: key, modifiers: modifiers)
            item.tag = tag.rawValue
            find.addItem(item)
        }
        find.addItem(responder(CompanionL10n.string("Jump to Selection"), #selector(NSResponder.centerSelectionInVisibleArea(_:)), key: "j"))
        let spelling = submenu(CompanionL10n.string("Spelling and Grammar"), in: edit)
        spelling.addItem(responder(CompanionL10n.string("Show Spelling and Grammar"), #selector(NSTextView.showGuessPanel(_:)), key: ":"))
        spelling.addItem(responder(CompanionL10n.string("Check Document Now"), #selector(NSTextView.checkSpelling(_:)), key: ";"))
        spelling.addItem(responder(CompanionL10n.string("Check Spelling While Typing"), #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        let substitutions = submenu(CompanionL10n.string("Substitutions"), in: edit)
        substitutions.addItem(responder(CompanionL10n.string("Show Substitutions"), #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        substitutions.addItem(responder(CompanionL10n.string("Smart Quotes"), #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        substitutions.addItem(responder(CompanionL10n.string("Smart Dashes"), #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        substitutions.addItem(responder(CompanionL10n.string("Text Replacement"), #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        let transformations = submenu(CompanionL10n.string("Transformations"), in: edit)
        transformations.addItem(responder(CompanionL10n.string("Make Upper Case"), #selector(NSTextView.uppercaseWord(_:))))
        transformations.addItem(responder(CompanionL10n.string("Make Lower Case"), #selector(NSTextView.lowercaseWord(_:))))
        transformations.addItem(responder(CompanionL10n.string("Capitalize"), #selector(NSTextView.capitalizeWord(_:))))
        let speech = submenu(CompanionL10n.string("Speech"), in: edit)
        speech.addItem(responder(CompanionL10n.string("Start Speaking"), #selector(NSTextView.startSpeaking(_:))))
        speech.addItem(responder(CompanionL10n.string("Stop Speaking"), #selector(NSTextView.stopSpeaking(_:))))
        edit.addItem(.separator())
        edit.addItem(responder(CompanionL10n.string("Emoji & Symbols"), #selector(NSApplication.orderFrontCharacterPalette(_:))))
    }

    private func makeViewMenu(in main: NSMenu) {
        let view = submenu(CompanionL10n.string("View"), in: main)
        view.delegate = self
        view.addItem(action(CompanionL10n.string("Command Palette…"), command: .appCommandPalette) { [app] in
            app.showCommandPalette()
        })
        view.addItem(.separator())
        let timeline = action(CompanionL10n.string("Open Timeline"), command: .appOpenTimeline) { [app] in
            app.pages.perform(.appOpenTimeline)
            app.returnToOwner()
        }
        timelineItem = timeline
        view.addItem(timeline)
        let tabs = action(CompanionL10n.string("Switch to Tabs View"), command: .appSwitchToTabs) { [app] in
            app.pages.perform(.appSwitchToTabs)
            app.returnToOwner()
        }
        tabsItem = tabs
        view.addItem(tabs)
        view.addItem(.separator())
        view.addItem(responder(CompanionL10n.string("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]))
    }

    private func makeWindowMenu(in main: NSMenu) -> NSMenu {
        let window = submenu(CompanionL10n.string("Window"), in: main)
        window.addItem(action(CompanionL10n.string("Open in Window")) { [app] in app.openEditorPresentation() })
        window.addItem(action(CompanionL10n.string("Show Ambient Panel"), enabled: { [app] in app.ambientPanelEnabled }) { [app] in app.showAmbientPresentation() })
        window.addItem(.separator())
        window.addItem(responder(CompanionL10n.string("Close Window"), #selector(NSWindow.performClose(_:)), command: .windowClose))
        window.addItem(.separator())
        window.addItem(responder(CompanionL10n.string("Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(responder(CompanionL10n.string("Zoom"), #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(responder(CompanionL10n.string("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        return window
    }

    private func makeHelpMenu(in main: NSMenu) -> NSMenu {
        let help = submenu(CompanionL10n.string("Help"), in: main)
        help.addItem(action(CompanionL10n.string("Export Diagnostics…")) { [app] in app.exportDiagnostics() })
        help.addItem(action(CompanionL10n.string("Copy Diagnostic Summary")) { [app] in app.copyDiagnosticSummary() })
        help.addItem(.separator())
        help.addItem(action(CompanionL10n.string("Send Feedback…")) { [app] in app.sendFeedback() })
        BackdropAppDelegate.installHelpItem(in: help, productName: BackdropAppDelegate.productName,
            keystroke: app.pages.keymap.menuKeystroke(for: .appHelp), target: app)
        return help
    }

    private var onFile: () -> Bool {
        { [app] in CommandPalettePresentation.canSave(app.pages.activeTarget) }
    }

    private var closeChoice: CloseMenuItem {
        CloseMenuItem.resolve(target: app.keyWindow.closeTarget, showing: app.pages.activeTarget,
                              ledgerShowing: app.pages.showingLedger, keyWindowCanClose: app.keyWindow.canClose)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        closeItem?.title = CompanionL10n.string(app.commandPaletteIsShowing ? "Close Command Palette" : closeChoice.title)
        timelineItem?.state = app.pages.showsTimeUnits ? .on : .off
        tabsItem?.state = app.pages.showsTimeUnits ? .off : .on
        if menu === languageMenu { updateLanguages(in: menu) }
    }

    private var languageTarget: ManualLanguageChoiceTarget? {
        ManualLanguageChoiceTarget.resolve(
            editorCanChoose: app.pages.languageActions.canChoose,
            editorSelectionIsEmpty: app.pages.languageActions.selectionIsEmpty,
            selectedFile: app.pages.showingLedger ? nil : app.pages.selectedFile)
    }

    private func addLanguageItems(to edit: NSMenu) {
        edit.addItem(action(CompanionL10n.string("Detect Code Language"), enabled: { [app] in app.pages.languageActions.canDetect }) { [app] in
            app.sendToResponder(#selector(LanguageDetectionResponder.detectCodeLanguage(_:)))
        })
        let choose = action(CompanionL10n.string("Choose Language"), enabled: { [weak self] in self?.languageTarget != nil }) {}
        let languages = NSMenu(title: CompanionL10n.string("Choose Language"))
        languages.delegate = self
        choose.submenu = languages
        languageMenu = languages
        edit.addItem(choose)
        updateLanguages(in: languages)
        edit.addItem(action(CompanionL10n.string("Paste Without Detection"), enabled: { [app] in app.pages.languageActions.canPaste }) { [app] in
            app.sendToResponder(#selector(LanguageDetectionResponder.pasteWithoutDetection(_:)))
        })
    }

    private func updateLanguages(in menu: NSMenu) {
        menu.removeAllItems()
        if case .file(let id) = languageTarget {
            menu.addItem(action(CompanionL10n.string("Plain Text")) { [app] in app.pages.selectFileRenderMode(.plainText, for: id) })
            menu.addItem(action(CompanionL10n.string("Markdown")) { [app] in app.pages.selectFileRenderMode(.markdown, for: id) })
            menu.addItem(.separator())
        }
        for language in InkEditorView.Coordinator.manualLanguages {
            menu.addItem(action(CodeLanguageName.display(language)) { [weak self] in
                guard let self else { return }
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
        if let command { bind(command, to: item) }
        return item
    }

    private func responder(_ title: String, _ selector: Selector, key: String = "",
                           modifiers: NSEvent.ModifierFlags = .command, command: CommandID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        if let command { bind(command, to: item) }
        return item
    }

    private func bind(_ command: CommandID, to item: NSMenuItem) {
        let chord = app.pages.keymap.menuKeystroke(for: command)
        item.keyEquivalent = chord?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = chord?.menuModifierMask ?? []
    }
}

@MainActor
final class MenuActionItem: NSMenuItem, NSMenuItemValidation {
    private var run: (() -> Void)?
    private var availability: (() -> Bool)?

    init(title: String, enabled: @escaping () -> Bool, run: @escaping () -> Void) {
        self.run = run
        self.availability = enabled
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(invoke)
        isEnabled = false
    }

    @objc private func invoke() { run?() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { availability?() ?? false }
}
