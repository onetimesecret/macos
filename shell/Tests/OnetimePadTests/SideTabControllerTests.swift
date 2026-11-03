import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

@MainActor
final class SideTabControllerTests: XCTestCase {
    private final class DesktopState {
        var allowed = true
        var displays: [SideTabDisplay]
        init(displays: [SideTabDisplay]) { self.displays = displays }
    }
    private let display = SideTabDisplay(id: "test-display", name: "Test display",
        frame: CGRect(x: 0, y: 0, width: 900, height: 700),
        visibleFrame: CGRect(x: 0, y: 25, width: 900, height: 650))

    private func model(defaults: UserDefaults? = nil) throws -> BackdropModel {
        let suite = "side-tab-\(UUID().uuidString)"
        let defaults = try defaults ?? XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        companion_init()
        let tag = UUID().uuidString
        let handle = try XCTUnwrap(tag.withCString { companion_new_ephemeral($0) })
        let pages = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: CompanionClient(adopting: handle)))
        return BackdropModel(defaults: defaults, pages: pages)
    }

    private func enabledModel() throws -> BackdropModel {
        let model = try model()
        model.sideTab = SideTabPreferences(enabled: true, displayID: display.id)
        return model
    }

    private func controller(
        _ model: BackdropModel, systemAllows: @escaping @MainActor () -> Bool = { true },
        observeSystem: Bool = false, onOpen: @escaping @MainActor () -> Void = {}
    ) -> SideTabController {
        let display = display
        let controller = SideTabController(model: model, displays: { [display] },
            systemAllows: systemAllows, observeSystem: observeSystem, onOpen: onOpen)
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    func testOffByDefaultAndSettingsRoundTrip() throws {
        let suite = "side-tab-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let first = try model(defaults: defaults)
        XCTAssertFalse(first.sideTab.enabled)
        first.sideTab = SideTabPreferences(enabled: true, displayID: "chosen-display", edge: .left, position: 0.2)
        let second = try model(defaults: defaults)
        XCTAssertEqual(second.sideTab, first.sideTab)
        second.sideTab.enabled = false
        XCTAssertFalse(SideTabPreferences.load(from: defaults).enabled)
        XCTAssertEqual(SideTabPreferences.load(from: defaults).displayID, "chosen-display")
        defaults.set(Data("invalid".utf8), forKey: SideTabPreferences.defaultsKey)
        XCTAssertEqual(SideTabPreferences.load(from: defaults), SideTabPreferences())
    }

    func testShowingTabDoesNotChangeKeyWindowOrPageState() throws {
        let model = try enabledModel()
        let key = NSApplication.shared.keyWindow
        let owner = model.pages.owner
        let selection = model.pages.selection
        let tab = controller(model)
        XCTAssertTrue(tab.panel.isVisible)
        XCTAssertFalse(tab.panel.canBecomeKey)
        XCTAssertFalse(tab.panel.canBecomeMain)
        XCTAssertFalse(tab.panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(tab.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(NSApp.keyWindow === key)
        XCTAssertEqual(model.pages.owner, owner)
        XCTAssertEqual(model.pages.selection, selection)
        XCTAssertEqual(model.stance, .resting)
        XCTAssertEqual(tab.button.bounds.size, tab.panel.frame.size)
        XCTAssertEqual(tab.button.accessibilityLabel(), "Open ambient panel")
        XCTAssertTrue(tab.button.acceptsFirstMouse(for: nil))
    }

    func testFirstButtonActionUsesTheExplicitSummonRoute() throws {
        let model = try enabledModel()
        var opens = 0
        let tab = controller(model, onOpen: {
            opens += 1
            let route = ActivationRouter.decide(.sideTabClick, in: ActivationContext(
                ambientPanelEnabled: model.ambientPanelEnabled, owner: model.pages.owner,
                claimedByAnotherWindow: false))
            BackdropAppDelegate.dispatch(route, openEditorWindow: { _ in XCTFail("unexpected editor") },
                raisePanel: { _ in XCTFail("unexpected recovery raise") },
                summonPanel: { model.summon() }, closeEditorForPanel: {})
        })
        tab.button.performClick(nil)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(model.stance, .raised)
        XCTAssertFalse(tab.panel.isVisible)
        tab.button.performClick(nil)
        XCTAssertEqual(opens, 1)
    }

    func testModelChangesHideAndRestoreTabAfterPublishedValuesSettle() throws {
        let model = try enabledModel()
        let tab = controller(model)
        model.pinned = true
        drainMainQueue()
        XCTAssertFalse(tab.panel.isVisible)
        model.pinned = false
        drainMainQueue()
        XCTAssertTrue(tab.panel.isVisible)
        model.raise(.activation)
        drainMainQueue()
        XCTAssertFalse(tab.panel.isVisible)
        model.rest()
        drainMainQueue()
        XCTAssertTrue(tab.panel.isVisible)
        model.editorWindowOpened()
        drainMainQueue()
        XCTAssertFalse(tab.panel.isVisible)
        model.editorWindowClosed()
        drainMainQueue()
        XCTAssertTrue(tab.panel.isVisible)
        model.setAmbientPanelEnabled(false)
        drainMainQueue()
        XCTAssertFalse(tab.panel.isVisible)
        model.setAmbientPanelEnabled(true)
        drainMainQueue()
        XCTAssertTrue(tab.panel.isVisible)
        model.sideTab.enabled = false
        drainMainQueue()
        XCTAssertFalse(tab.panel.isVisible)
    }

    func testClicksWorkAtFractionalAndEndpointPositionsOnEitherEdge() throws {
        let model = try enabledModel()
        var opens = 0
        for edge in SideTabEdge.allCases {
            for position in [0.0, 0.213, 0.817, 1.0] {
                model.sideTab.edge = edge
                model.sideTab.position = position
                let tab = controller(model, onOpen: { opens += 1 })
                let before = opens
                tab.button.performClick(nil)
                XCTAssertEqual(opens, before + 1, "\(edge) at \(position)")
                tab.stop()
            }
        }
    }

    func testClickRechecksEligibilityBeforeQueuedRefresh() throws {
        let model = try enabledModel()
        var opens = 0
        let tab = controller(model, onOpen: { opens += 1 })
        model.pinned = true
        tab.button.performClick(nil)
        XCTAssertEqual(opens, 0)
        XCTAssertFalse(tab.panel.isVisible)
    }

    func testSystemVetoAndChangedPlacementRejectStaleClicks() throws {
        let model = try enabledModel()
        let desktop = DesktopState(displays: [display])
        var opens = 0
        let tab = controller(model, systemAllows: { desktop.allowed }, onOpen: { opens += 1 })
        desktop.allowed = false
        tab.button.performClick(nil)
        XCTAssertEqual(opens, 0)
        XCTAssertFalse(tab.panel.isVisible)
        desktop.allowed = true
        tab.refresh()
        let previous = tab.panel.frame
        model.sideTab.position = 0.8
        tab.button.performClick(nil)
        XCTAssertEqual(opens, 0)
        XCTAssertNotEqual(tab.panel.frame, previous)
    }

    func testDisconnectedSelectionDoesNotMoveToAnotherDisplay() throws {
        let model = try enabledModel()
        let display = display
        let desktop = DesktopState(displays: [display])
        let tab = SideTabController(model: model, displays: { desktop.displays }, systemAllows: { true },
            observeSystem: false, onOpen: { XCTFail("unexpected open") })
        defer { tab.stop() }
        desktop.displays = [SideTabDisplay(id: "replacement", name: "Replacement", frame: display.frame,
            visibleFrame: display.visibleFrame)]
        tab.refresh()
        XCTAssertFalse(tab.panel.isVisible)
        desktop.displays = [display]
        tab.refresh()
        XCTAssertTrue(tab.panel.isVisible)
        tab.stop()
        tab.refresh()
        XCTAssertFalse(tab.panel.isVisible)
    }

    func testMenuAndWorkspaceNotificationsHideTab() throws {
        let model = try enabledModel()
        let tab = controller(model, observeSystem: true)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        XCTAssertTrue(tab.panel.isVisible)
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertTrue(tab.panel.isVisible)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertTrue(tab.panel.isVisible)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertTrue(tab.panel.isVisible)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertTrue(tab.panel.isVisible)
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: nil)
        XCTAssertTrue(tab.panel.isVisible)
    }
}
