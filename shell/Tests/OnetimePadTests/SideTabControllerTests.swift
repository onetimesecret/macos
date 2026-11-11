import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

@MainActor
final class SideTabControllerTests: XCTestCase {
    private let notificationCenter = NotificationCenter()
    private let workspaceCenter = NotificationCenter()
    private final class RecoveryClock: SideTabRecoveryScheduling {
        final class Job {
            let deadline: TimeInterval
            let action: @MainActor () -> Void
            var cancelled = false
            init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
                self.deadline = deadline
                self.action = action
            }
        }

        var time: TimeInterval = 1_000
        private var jobs: [Job] = []
        var pending: Int { jobs.filter { !$0.cancelled }.count }

        func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            let job = Job(deadline: time + delay, action: action)
            jobs.append(job)
            return { job.cancelled = true }
        }

        func advance(by interval: TimeInterval) {
            time += interval
            let due = jobs.filter { $0.deadline <= time }
            jobs.removeAll { $0.deadline <= time }
            for job in due where !job.cancelled { job.action() }
        }
    }

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
        observeSystem: Bool = false, clock: RecoveryClock? = nil,
        onOpen: @escaping @MainActor () -> Void = {}
    ) -> SideTabController {
        let display = display
        let controller = SideTabController(model: model, displays: { [display] },
            systemAllows: systemAllows, observeSystem: observeSystem,
            now: { clock?.time ?? ProcessInfo.processInfo.systemUptime }, recoveryScheduler: clock,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, onOpen: onOpen)
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
        XCTAssertEqual(tab.panel.title, "OnetimePad side tab")
        XCTAssertEqual(tab.panel.accessibilityLabel(), "OnetimePad side tab")
        XCTAssertEqual(tab.button.toolTip, "Open ambient panel")
    }

    func testDuplicateDisplayIdentitiesProduceOnePickerEntry() {
        let duplicate = SideTabDisplay(id: display.id, name: "Duplicate", frame: display.frame,
            visibleFrame: display.visibleFrame)
        let other = SideTabDisplay(id: "other", name: "Other", frame: display.frame,
            visibleFrame: display.visibleFrame)
        XCTAssertEqual(SideTabDisplays.unique([display, duplicate, other]), [display, other])
    }

    func testDisabledTabDoesNotReadDisplaySnapshots() throws {
        let model = try model()
        var reads = 0
        let tab = SideTabController(model: model, displays: { reads += 1; return [] },
            systemAllows: { true }, observeSystem: false,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, onOpen: {})
        defer { tab.stop() }
        tab.refresh()
        model.sideTab.position = 0.3
        drainMainQueue()
        XCTAssertEqual(reads, 0)
    }

    func testMissingMenuEndRecoversAtTheExistingBoundWithoutPolling() throws {
        let model = try enabledModel()
        let clock = RecoveryClock()
        let display = display
        let tab = SideTabController(model: model, displays: { [display] }, systemAllows: { true },
            now: { clock.time }, recoveryScheduler: clock,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, onOpen: {})
        defer { tab.stop() }

        notificationCenter.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        XCTAssertEqual(clock.pending, 1)
        tab.refresh()
        XCTAssertEqual(clock.pending, 1)
        clock.advance(by: MenuTracking.openLimit - 0.1)
        XCTAssertFalse(tab.panel.isVisible)
        clock.advance(by: 0.2)
        XCTAssertTrue(tab.panel.isVisible)
        XCTAssertEqual(clock.pending, 0)
    }

    func testNestedMenusStaySuppressedUntilTheLastEndAndCancelRecovery() throws {
        let model = try enabledModel()
        let clock = RecoveryClock()
        let display = display
        let tab = SideTabController(model: model, displays: { [display] }, systemAllows: { true },
            now: { clock.time }, recoveryScheduler: clock,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, onOpen: {})
        defer { tab.stop() }
        let center = notificationCenter
        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        clock.advance(by: 1)
        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        XCTAssertTrue(tab.panel.isVisible)
        XCTAssertEqual(clock.pending, 0)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        XCTAssertTrue(tab.panel.isVisible)
    }

    func testMissingSheetEndRecoversAfterTransitionAndActualStateAllows() throws {
        let model = try enabledModel()
        let clock = RecoveryClock()
        let desktop = DesktopState(displays: [display])
        let tab = SideTabController(model: model, displays: { desktop.displays },
            systemAllows: { desktop.allowed }, now: { clock.time }, recoveryScheduler: clock,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, onOpen: {})
        defer { tab.stop() }
        notificationCenter.post(name: NSWindow.willBeginSheetNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        XCTAssertEqual(clock.pending, 1)
        desktop.allowed = false
        clock.advance(by: SideTabController.sheetTransitionDuration + 0.01)
        XCTAssertFalse(tab.panel.isVisible)
        XCTAssertEqual(clock.pending, 0)
        desktop.allowed = true
        tab.refresh()
        XCTAssertTrue(tab.panel.isVisible)
    }

    func testMissingSheetEndDoesNotLeaveTransitionSuppressionBehind() throws {
        let model = try enabledModel()
        let clock = RecoveryClock()
        let display = display
        let tab = SideTabController(model: model, displays: { [display] }, systemAllows: { true },
            now: { clock.time }, recoveryScheduler: clock,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, onOpen: {})
        defer { tab.stop() }
        notificationCenter.post(name: NSWindow.willBeginSheetNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        clock.advance(by: SideTabController.sheetTransitionDuration + 0.01)
        XCTAssertTrue(tab.panel.isVisible)
        XCTAssertEqual(clock.pending, 0)
    }

    func testSheetEndRechecksAfterNativeDetachWithoutAnotherNotification() throws {
        let model = try enabledModel()
        let clock = RecoveryClock()
        let desktop = DesktopState(displays: [display])
        let tab = SideTabController(model: model, displays: { desktop.displays },
            systemAllows: { desktop.allowed }, now: { clock.time }, recoveryScheduler: clock,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, onOpen: {})
        defer { tab.stop() }
        notificationCenter.post(name: NSWindow.willBeginSheetNotification, object: nil)
        desktop.allowed = false
        clock.advance(by: SideTabController.sheetTransitionDuration + 0.01)
        XCTAssertFalse(tab.panel.isVisible)
        XCTAssertEqual(clock.pending, 0)

        notificationCenter.post(name: NSWindow.didEndSheetNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        XCTAssertEqual(clock.pending, 1)
        desktop.allowed = true
        clock.advance(by: SideTabController.sheetTransitionDuration + 0.01)
        XCTAssertTrue(tab.panel.isVisible)
        XCTAssertEqual(clock.pending, 0)
    }

    func testSheetEndRecoveryStillRespectsNativeState() throws {
        let model = try enabledModel()
        let clock = RecoveryClock()
        let desktop = DesktopState(displays: [display])
        let tab = SideTabController(model: model, displays: { desktop.displays },
            systemAllows: { desktop.allowed }, now: { clock.time }, recoveryScheduler: clock,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, onOpen: {})
        defer { tab.stop() }
        desktop.allowed = false
        notificationCenter.post(name: NSWindow.didEndSheetNotification, object: nil)
        XCTAssertEqual(clock.pending, 1)
        clock.advance(by: SideTabController.sheetTransitionDuration + 0.01)
        XCTAssertFalse(tab.panel.isVisible)
        XCTAssertEqual(clock.pending, 0)
    }

    func testStoppingCancelsPendingMenuAndSheetRecovery() throws {
        let model = try enabledModel()
        let clock = RecoveryClock()
        let display = display
        let tab = SideTabController(model: model, displays: { [display] }, systemAllows: { true },
            now: { clock.time }, recoveryScheduler: clock,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, onOpen: {})
        notificationCenter.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        notificationCenter.post(name: NSWindow.willBeginSheetNotification, object: nil)
        XCTAssertEqual(clock.pending, 2)
        tab.stop()
        XCTAssertEqual(clock.pending, 0)
        clock.advance(by: MenuTracking.openLimit + 1)
        XCTAssertFalse(tab.panel.isVisible)
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
                summonPanel: { model.summon() }, closeEditorForPanel: {},
                hideApp: { XCTFail("unexpected hide") })
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
            observeSystem: false,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, onOpen: { XCTFail("unexpected open") })
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
        let clock = RecoveryClock()
        let tab = controller(model, observeSystem: true, clock: clock)
        notificationCenter.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        notificationCenter.post(name: NSMenu.didEndTrackingNotification, object: nil)
        XCTAssertTrue(tab.panel.isVisible)
        let center = workspaceCenter
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
        notificationCenter.post(name: NSWindow.willBeginSheetNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        notificationCenter.post(name: NSWindow.didEndSheetNotification, object: nil)
        XCTAssertFalse(tab.panel.isVisible)
        clock.advance(by: SideTabController.sheetTransitionDuration + 0.01)
        XCTAssertTrue(tab.panel.isVisible)
    }

    func testInjectedCentersKeepSyntheticEventsWithinTheirController() throws {
        let model = try enabledModel()
        let clock = RecoveryClock()
        let first = controller(model, observeSystem: true, clock: clock)
        let otherNotifications = NotificationCenter()
        let otherWorkspace = NotificationCenter()
        let display = display
        let second = SideTabController(model: model, displays: { [display] }, systemAllows: { true },
            now: { clock.time }, recoveryScheduler: clock,
            notificationCenter: otherNotifications, workspaceCenter: otherWorkspace, onOpen: {})
        defer { second.stop() }
        notificationCenter.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        XCTAssertFalse(first.panel.isVisible)
        XCTAssertTrue(second.panel.isVisible)
        notificationCenter.post(name: NSMenu.didEndTrackingNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertFalse(first.panel.isVisible)
        XCTAssertTrue(second.panel.isVisible)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertTrue(first.panel.isVisible)
        otherNotifications.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        XCTAssertTrue(first.panel.isVisible)
        XCTAssertFalse(second.panel.isVisible)
    }
}
