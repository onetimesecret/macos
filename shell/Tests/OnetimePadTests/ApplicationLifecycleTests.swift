import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    private func prepareMenuRoles() {
        _ = NSApplication.shared
        let main = NSApp.mainMenu ?? NSMenu(title: "Lifecycle Fixture")
        NSApp.mainMenu = main
        func attach(_ title: String, to parent: NSMenu) -> NSMenu {
            let menu = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            parent.addItem(item)
            return menu
        }
        if NSApp.windowsMenu == nil { NSApp.windowsMenu = attach("Window", to: main) }
        if NSApp.helpMenu == nil { NSApp.helpMenu = attach("Help", to: main) }
        if NSApp.servicesMenu == nil {
            let application = attach("Application", to: main)
            NSApp.servicesMenu = attach("Services", to: application)
        }
    }

    private func withApplication(keymapOverride: String? = nil, applicationIsActive: @escaping () -> Bool = { NSApp.isActive }, _ test: (BackdropAppDelegate, BackdropModel) throws -> Void) throws {
        prepareMenuRoles()
        let oldMain = NSApp.mainMenu, oldWindows = NSApp.windowsMenu
        let oldServices = NSApp.servicesMenu, oldHelp = NSApp.helpMenu
        let oldServicesParent = oldServices?.supermenu?.items.first { $0.submenu === oldServices }
        defer {
            oldServices?.supermenu?.items.first { $0.submenu === oldServices }?.submenu = nil
            oldServicesParent?.submenu = oldServices
            NSApp.mainMenu = oldMain; NSApp.windowsMenu = oldWindows
            NSApp.servicesMenu = oldServices; NSApp.helpMenu = oldHelp
        }
        let suite = "onetimepad.lifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        companion_init()
        let handle = try XCTUnwrap(suite.withCString { companion_new_ephemeral($0) })
        var overrideURL: URL?
        if let keymapOverride {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("keymap.json")
            try keymapOverride.write(to: file, atomically: true, encoding: .utf8)
            overrideURL = file
        }
        let pages = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: CompanionClient(adopting: handle), keymapOverride: overrideURL))
        let model = BackdropModel(defaults: defaults, pages: pages)
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let originalVisibleWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        defer {
            for window in NSApp.windows {
                let identifier = ObjectIdentifier(window)
                if !originalWindows.contains(identifier) {
                    if window is NSPanel {
                        window.orderOut(nil)
                    } else {
                        window.isReleasedWhenClosed = false
                        window.close()
                    }
                } else if !originalVisibleWindows.contains(identifier) && window.isVisible {
                    window.orderOut(nil)
                }
            }
        }
        try test(BackdropAppDelegate(model: model, applicationIsActive: applicationIsActive), model)
    }

    func testUnbundledAndUnrecognizedLaunchesAreRejected() throws {
        for identifier in [nil, "", "dev.onetimepad.settings-lifecycle-probe", "com.example.OnetimePad",
                           "dev.onetimesecret.pad.debug.copy", "com.onetimesecret.companion"] as [String?] {
            XCTAssertFalse(AppLaunchIdentity.accepts(identifier))
        }
        for identifier in [FormFactor.backdropBundleIdentifier, FormFactor.localBundleIdentifier,
                           FormFactor.devBundleIdentifier] {
            XCTAssertTrue(AppLaunchIdentity.accepts(identifier))
        }
    }

    func testExplicitSettingsAndRepeatedActivationDoNotCreateAnEditor() throws {
        try withApplication { app, model in
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            app.openSettings()
            let settings = try XCTUnwrap(app.madeSettings?.window)
            defer { settings.close() }
            XCTAssertFalse(settings.isRestorable)
            for _ in 0..<3 {
                app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
                XCTAssertFalse(model.editorWindowOpen)
                XCTAssertTrue(app.madeSettings?.window === settings)
            }
            settings.close()
            app.openSettings()
            XCTAssertTrue(app.madeSettings?.window === settings)
            XCTAssertFalse(settings.isRestorable)
        }
    }

    func testNewEditorRequestsSupersedeAbandonedCompanionActivation() throws {
        for companion in ["settings", "about", "feedback"] {
            for resign in [false, true] {
                for reason in [ActivationReason.hotkey, .statusItem, .reopen] {
                    try withApplication(applicationIsActive: { false }) { app, model in
                        app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
                        model.setAmbientPanelEnabled(false)
                        switch companion {
                        case "settings": app.openSettings()
                        case "about": app.showAbout()
                        default: app.sendFeedback()
                        }
                        if resign {
                            app.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
                        }
                        app.applySummon(reason)
                        XCTAssertFalse(model.editorWindowOpen)
                        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
                        XCTAssertTrue(model.editorWindowOpen, "\(companion), resign=\(resign), \(reason)")
                    }
                }
            }
        }
    }

    func testNewCompanionActivationStillSupersedesDeferredEditorRequest() throws {
        try withApplication(applicationIsActive: { false }) { app, model in
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            model.setAmbientPanelEnabled(false)
            app.applySummon(.hotkey)
            app.openSettings()
            app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            XCTAssertFalse(model.editorWindowOpen)
        }
    }

    func testBackgroundStartupAndOrdinaryActivationOpenNoSettingsOrEditor() throws {
        try withApplication { app, model in
            var initialOpens = 0
            app.selectInitialEditor = { initialOpens += 1 }
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            for _ in 0..<3 {
                app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            }
            XCTAssertEqual(initialOpens, 0)
            XCTAssertFalse(model.editorWindowOpen)
            XCTAssertNil(app.madeSettings)
        }
    }

    func testForegroundOpenWaitsForStartupAndIsConsumedOnce() throws {
        try withApplication { app, model in
            var opens = 0
            app.selectInitialEditor = { opens += 1 }
            XCTAssertTrue(app.applicationShouldOpenUntitledFile(NSApplication.shared))
            XCTAssertTrue(app.applicationOpenUntitledFile(NSApplication.shared))
            XCTAssertEqual(opens, 0)
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            XCTAssertEqual(opens, 1)
            app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            XCTAssertEqual(opens, 1)
            XCTAssertNil(app.madeSettings)
            XCTAssertFalse(model.editorWindowOpen)
        }
    }

    func testQueuedFinderOpenSupersedesPendingUntitledOpen() throws {
        for finderFirst in [false, true] {
            try withApplication { app, model in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("notes.txt")
                try "notes".write(to: file, atomically: true, encoding: .utf8)
                let pages = model.pages
                pages.loadStateIfNeeded()
                pages.showsTimeUnits = true
                pages.perform(.pageNew)
                var initialOpens = 0, finderOpens = 0, anchors = 0
                pages.installTodayAnchor({ anchors += 1 }, from: pages.owner)
                XCTAssertNotNil(pages.onAnchorToday)
                app.selectEditor = { finderOpens += 1 }
                app.selectInitialEditor = { initialOpens += 1; pages.anchorOnToday() }
                if finderFirst { app.application(NSApp, open: [file]) }
                XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
                if !finderFirst { app.application(NSApp, open: [file]) }

                app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))

                XCTAssertEqual(finderOpens, 1)
                XCTAssertEqual(initialOpens, 0)
                XCTAssertEqual(anchors, 0)
                XCTAssertEqual(pages.selectedFile, pages.openFiles.first?.id)
                XCTAssertNotNil(pages.selectedFile)
                XCTAssertEqual(pages.activeFile.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path },
                               file.resolvingSymlinksInPath().path)
                XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
                app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
                XCTAssertEqual(initialOpens, 0)
                XCTAssertEqual(anchors, 0)
                XCTAssertEqual(pages.activeFile.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path },
                               file.resolvingSymlinksInPath().path)
            }
        }
    }

    func testReopenBeforeStartupDoesNotReplayAsAnInitialLaunch() throws {
        for defaultLaunch in [true, false] {
            try withApplication { app, model in
                model.pages.loadStateIfNeeded()
                model.pages.showsTimeUnits = true
                model.pages.perform(.pageNew)
                var initialOpens = 0, anchors = 0
                app.selectInitialEditor = { initialOpens += 1; model.pages.anchorOnToday() }
                model.pages.installTodayAnchor({ anchors += 1 }, from: model.pages.owner)
                XCTAssertNotNil(model.pages.onAnchorToday)

                XCTAssertFalse(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
                app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification,
                    userInfo: [NSApplication.launchIsDefaultUserInfoKey: defaultLaunch]))
                app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

                XCTAssertEqual(initialOpens, 0)
                XCTAssertEqual(anchors, 0)
                XCTAssertTrue(model.editorWindowOpen)
                XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
                XCTAssertEqual(initialOpens, 0)
                XCTAssertEqual(anchors, 0)
            }
        }
    }

    func testNonDefaultLaunchSuppressesInitialUntitledButLaterOpensUseReopen() throws {
        for queued in [true, false] {
            try withApplication { app, model in
                let pages = model.pages
                pages.loadStateIfNeeded()
                pages.showsTimeUnits = true
                pages.perform(.pageNew)
                var initialOpens = 0, anchors = 0
                pages.installTodayAnchor({ anchors += 1 }, from: pages.owner)
                app.selectInitialEditor = { initialOpens += 1; pages.anchorOnToday() }
                if queued { XCTAssertTrue(app.applicationOpenUntitledFile(NSApp)) }
                app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification,
                    userInfo: [NSApplication.launchIsDefaultUserInfoKey: false]))
                if !queued { XCTAssertTrue(app.applicationOpenUntitledFile(NSApp)) }
                XCTAssertFalse(model.editorWindowOpen)
                let selection = pages.selection
                XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
                app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

                XCTAssertEqual(initialOpens, 0)
                XCTAssertEqual(anchors, 0)
                XCTAssertEqual(pages.selection, selection)
                XCTAssertTrue(model.editorWindowOpen)
            }
        }
    }

    func testNonDefaultStartupReopenThenUntitledReopensClosedEditorWithoutAnchoring() throws {
        try withApplication { app, model in
            let pages = model.pages
            pages.loadStateIfNeeded()
            pages.showsTimeUnits = true
            pages.perform(.pageNew)
            var anchors = 0
            pages.installTodayAnchor({ anchors += 1 }, from: pages.owner)
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification,
                userInfo: [NSApplication.launchIsDefaultUserInfoKey: false]))
            let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
            XCTAssertFalse(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
            app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            XCTAssertTrue(model.editorWindowOpen)
            for window in NSApp.windows where !existing.contains(ObjectIdentifier(window)) {
                window.close()
            }
            XCTAssertFalse(model.editorWindowOpen)
            let selection = pages.selection

            XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
            app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

            XCTAssertTrue(model.editorWindowOpen)
            XCTAssertEqual(pages.selection, selection)
            XCTAssertEqual(anchors, 0)
        }
    }

    func testExplicitDefaultLaunchConsumesQueuedUntitledOpen() throws {
        try withApplication { app, _ in
            var initialOpens = 0
            app.selectInitialEditor = { initialOpens += 1 }
            XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification,
                userInfo: [NSApplication.launchIsDefaultUserInfoKey: true]))
            XCTAssertEqual(initialOpens, 1)
        }
    }

    func testRepeatedUntitledOpenUsesReopenWithoutAnchoringAgain() throws {
        try withApplication { app, model in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("notes.txt")
            try "notes".write(to: file, atomically: true, encoding: .utf8)
            let pages = model.pages
            pages.loadStateIfNeeded()
            pages.showsTimeUnits = true
            pages.perform(.pageNew)
            var initialOpens = 0, anchors = 0
            pages.installTodayAnchor({ anchors += 1 }, from: pages.owner)
            app.selectInitialEditor = { initialOpens += 1; pages.anchorOnToday() }
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
            XCTAssertEqual(initialOpens, 1)
            XCTAssertEqual(anchors, 1)
            pages.openFile(at: file)
            let selectedFile = try XCTUnwrap(pages.selectedFile)

            XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
            app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

            XCTAssertEqual(initialOpens, 1)
            XCTAssertEqual(anchors, 1)
            XCTAssertEqual(pages.selectedFile, selectedFile)
            XCTAssertTrue(model.editorWindowOpen)
        }
    }

    func testQueuedFinderOpenDuringModalSuppressesPendingUntitledUntilDrain() throws {
        try withApplication { app, model in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("notes.txt")
            try "notes".write(to: file, atomically: true, encoding: .utf8)
            model.pages.loadStateIfNeeded()
            var initialOpens = 0, finderOpens = 0
            app.selectInitialEditor = { initialOpens += 1 }
            app.selectEditor = { finderOpens += 1 }
            XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
            app.application(NSApp, open: [file])
            ModalSession.run {
                app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
                XCTAssertEqual(app.finderDocuments, [file])
                XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
                XCTAssertEqual(initialOpens, 0)
                XCTAssertEqual(finderOpens, 0)
            }
            app.application(NSApp, open: [])
            XCTAssertEqual(app.finderDocuments, [])
            XCTAssertEqual(initialOpens, 0)
            XCTAssertEqual(finderOpens, 1)
            XCTAssertNotNil(model.pages.selectedFile)
        }
    }

    func testNonFileFinderURLDoesNotSuppressPendingUntitledOpen() throws {
        try withApplication { app, _ in
            var initialOpens = 0, finderOpens = 0
            app.selectInitialEditor = { initialOpens += 1 }
            app.selectEditor = { finderOpens += 1 }
            XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
            app.application(NSApp, open: [URL(string: "https://example.com/notes.txt")!])

            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))

            XCTAssertEqual(app.finderDocuments, [])
            XCTAssertEqual(initialOpens, 1)
            XCTAssertEqual(finderOpens, 0)
        }
    }

    func testVisibleSettingsKeepsNativeReopenHandling() throws {
        try withApplication { app, model in
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            app.openSettings()
            let settings = try XCTUnwrap(app.madeSettings?.window)
            defer { settings.close() }
            XCTAssertTrue(settings.isVisible)

            XCTAssertTrue(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))

            XCTAssertTrue(settings.isVisible)
            XCTAssertFalse(model.editorWindowOpen)
            XCTAssertTrue(app.madeSettings?.window === settings)
        }
    }

    private final class ReopenPanel: NSPanel {
        var reopenCount = 0
        override var canBecomeMain: Bool { true }
        override func makeKeyAndOrderFront(_ sender: Any?) {
            reopenCount += 1
            super.makeKeyAndOrderFront(sender)
        }
    }

    func testPanelOnlyReopenOrdersFrontmostWindowInsteadOfCreationOrder() throws {
        try withApplication { app, _ in
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            let first = ReopenPanel(contentRect: NSRect(x: 10, y: 10, width: 100, height: 100),
                                    styleMask: [.titled], backing: .buffered, defer: false)
            let second = ReopenPanel(contentRect: NSRect(x: 20, y: 20, width: 100, height: 100),
                                     styleMask: [.titled], backing: .buffered, defer: false)
            first.isReleasedWhenClosed = false
            second.isReleasedWhenClosed = false
            first.hidesOnDeactivate = false
            second.hidesOnDeactivate = false
            defer { first.close(); second.close() }
            first.orderFrontRegardless()
            second.orderFrontRegardless()
            first.orderFrontRegardless()
            var orderedPanels: [NSWindow] = []
            NSApp.enumerateWindows(options: [.orderedFrontToBack]) { window, _ in
                if window === first || window === second { orderedPanels.append(window) }
            }
            XCTAssertEqual(orderedPanels.count, 2)
            XCTAssertTrue(orderedPanels.first === first)

            XCTAssertFalse(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))

            XCTAssertEqual(first.reopenCount, 1)
            XCTAssertEqual(second.reopenCount, 0)
        }
    }

    func testSheetOnlyReopenOrdersItsParent() throws {
        try withApplication { app, _ in
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            let parent = ReopenPanel(contentRect: NSRect(x: 10, y: 10, width: 180, height: 180),
                                     styleMask: [.titled], backing: .buffered, defer: false)
            let sheet = ReopenPanel(contentRect: NSRect(x: 10, y: 10, width: 100, height: 100),
                                    styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            sheet.isReleasedWhenClosed = false
            parent.orderFront(nil)
            parent.beginSheet(sheet)
            defer { parent.endSheet(sheet); sheet.close(); parent.close() }
            XCTAssertTrue(sheet.sheetParent === parent)
            parent.reopenCount = 0
            sheet.reopenCount = 0

            XCTAssertFalse(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))

            XCTAssertEqual(parent.reopenCount, 1)
            XCTAssertEqual(sheet.reopenCount, 0)
        }
    }

    func testAmbientSheetIsExcludedFromOrdinaryReopenTargets() throws {
        try withApplication { app, model in
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            let parent = ReopenPanel(contentRect: NSRect(x: 10, y: 10, width: 180, height: 180),
                                     styleMask: [.titled], backing: .buffered, defer: false)
            let sheet = ReopenPanel(contentRect: NSRect(x: 10, y: 10, width: 100, height: 100),
                                    styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            sheet.isReleasedWhenClosed = false
            parent.orderFront(nil)
            parent.beginSheet(sheet)
            defer { parent.endSheet(sheet); sheet.close(); parent.close() }
            XCTAssertTrue(sheet.sheetParent === parent)
            XCTAssertTrue(BackdropAppDelegate.isVisibleOrdinaryWindow(sheet, isAmbientWindow: false))

            let target = BackdropAppDelegate.reopenWindow(sheet,
                isAmbientWindow: { $0 === parent }, isCompanion: { _ in false })

            XCTAssertNil(target)
            XCTAssertFalse(model.editorWindowOpen)
        }
    }

    func testWillFinishInstallsMenusBeforeStartupWithoutOpeningWindows() throws {
        try withApplication { app, _ in
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            app.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            var initialOpens = 0
            app.selectInitialEditor = { initialOpens += 1 }
            XCTAssertTrue(app.applicationOpenUntitledFile(NSApp))
            XCTAssertEqual(initialOpens, 0)
            XCTAssertNotNil(NSApp.mainMenu)
            XCTAssertEqual(NSApp.helpMenu?.items.first?.action, #selector(BackdropAppDelegate.openHelp(_:)))
            XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), before)
            XCTAssertNil(app.madeSettings)
            XCTAssertTrue(app.applicationSupportsSecureRestorableState(NSApp))
        }
    }

    func testAboutOnlyReopenDoesNotPermitUntitledFallback() throws {
        try withApplication { app, model in
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            var initialOpens = 0
            app.selectInitialEditor = { initialOpens += 1 }
            app.showAbout()
            let panel = try XCTUnwrap(NSApp.windows.first { app.isCompanionWindow($0) && $0.isVisible })
            defer { panel.close() }
            XCTAssertTrue(panel is NSPanel)
            let allowNativeReopen = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            if allowNativeReopen { _ = app.applicationOpenUntitledFile(NSApp) }
            XCTAssertFalse(allowNativeReopen)
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(initialOpens, 0)
            XCTAssertFalse(model.editorWindowOpen)
            XCTAssertNil(app.madeSettings)
        }
    }

    func testModalReopenDoesNotPermitUntitledFallback() throws {
        try withApplication { app, model in
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            var initialOpens = 0
            app.selectInitialEditor = { initialOpens += 1 }
            ModalSession.run {
                let allowNativeReopen = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                if allowNativeReopen { _ = app.applicationOpenUntitledFile(NSApp) }
                XCTAssertFalse(allowNativeReopen)
            }
            XCTAssertEqual(initialOpens, 0)
            XCTAssertFalse(model.editorWindowOpen)
        }
    }

    func testMenuInstallationCreatesNoWindowsAndPreservesNativeResponderTargets() throws {
        try withApplication { app, model in
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            let menus = MainMenuController(app: app)
            menus.install()
            let main = try XCTUnwrap(NSApp.mainMenu)
            XCTAssertEqual(main.items.map(\.title), [BackdropAppDelegate.productName, "File", "Edit", "View", "Window", "Help"].map(CompanionL10n.string))
            XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), before)
            XCTAssertNil(app.madeSettings)
            let settings = try XCTUnwrap(main.items[0].submenu?.items.first { $0.title == "Settings…" })
            XCTAssertEqual(settings.keyEquivalent, app.settingsKeystroke?.menuKeyEquivalent ?? "")
            let edit = try XCTUnwrap(main.items.first { $0.title == "Edit" }?.submenu)
            for title in ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"] {
                let item = try XCTUnwrap(edit.items.first { $0.title == title })
                XCTAssertNil(item.target)
                XCTAssertNotNil(item.action)
            }
            let window = try XCTUnwrap(main.items.first { $0.title == "Window" }?.submenu)
            XCTAssertTrue(NSApp.windowsMenu === window)
            let ambient = try XCTUnwrap(window.items.first { $0.title == "Show Ambient Panel" })
            model.setAmbientPanelEnabled(false)
            window.update()
            XCTAssertFalse(ambient.isEnabled)
        }
    }

    func testMenuFixtureRestoresRolesAndReleasesItsModel() throws {
        prepareMenuRoles()
        let main = NSApp.mainMenu, windows = NSApp.windowsMenu
        let services = NSApp.servicesMenu, help = NSApp.helpMenu
        let servicesParent = services?.supermenu
        weak var releasedApp: BackdropAppDelegate?
        weak var releasedModel: BackdropModel?
        try autoreleasepool {
            try withApplication { app, model in
                releasedApp = app
                releasedModel = model
                MainMenuController(app: app).install()
            }
        }
        XCTAssertTrue(NSApp.mainMenu === main)
        XCTAssertTrue(NSApp.windowsMenu === windows)
        XCTAssertTrue(NSApp.servicesMenu === services)
        XCTAssertTrue(NSApp.helpMenu === help)
        XCTAssertTrue(services?.supermenu === servicesParent)
        XCTAssertNil(releasedApp)
        XCTAssertNil(releasedModel)
    }

    func testUnboundMenuCommandsKeepTheirItemsWithoutShortcuts() throws {
        let keymap = #"[{"context":"Editor","bindings":{"cmd-,":null,"cmd-shift-w":null}}]"#
        try withApplication(keymapOverride: keymap) { app, _ in
            let menus = MainMenuController(app: app)
            menus.install()
            let main = try XCTUnwrap(NSApp.mainMenu)
            for title in ["Settings…", "Close Window"] {
                let item = try XCTUnwrap(main.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == title })
                XCTAssertEqual(item.keyEquivalent, "")
                XCTAssertEqual(item.keyEquivalentModifierMask, [])
                XCTAssertNotNil(item.action)
            }
        }
    }

    func testAVisibleCompanionPanelPreventsEditorReopen() throws {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.orderFront(nil)
        XCTAssertTrue(BackdropAppDelegate.isVisibleOrdinaryWindow(
            panel, isAmbientWindow: false, isCompanion: true))
        XCTAssertFalse(BackdropAppDelegate.isVisibleOrdinaryWindow(
            panel, isAmbientWindow: true, isCompanion: true))
    }

    func testOnlyVisibleOrdinaryWindowsPreventAnEditorReopen() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertFalse(BackdropAppDelegate.isVisibleOrdinaryWindow(window, isAmbientWindow: false))
        window.orderFront(nil)
        XCTAssertTrue(BackdropAppDelegate.isVisibleOrdinaryWindow(window, isAmbientWindow: false))
        XCTAssertFalse(BackdropAppDelegate.isVisibleOrdinaryWindow(window, isAmbientWindow: true))
    }
}
