import AppKit
import Combine
import CompanionKit
import CoreGraphics

@MainActor
enum SideTabDisplays {
    static func current() -> [SideTabDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let id = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            return SideTabDisplay(id: id, name: screen.localizedName,
                frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
}

@MainActor
final class SideTabController {
    let panel: SideTabPanel
    let button: SideTabButton
    private let model: BackdropModel
    private let displays: @MainActor () -> [SideTabDisplay]
    private let systemAllows: @MainActor () -> Bool
    private let onOpen: @MainActor () -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var refreshPending = false
    private var sessionActive = true
    private var machineAwake = true
    private var screensAwake = true
    private var menuDepth = 0
    private var sheetDepth = 0
    private var stopped = false
    private nonisolated(unsafe) var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private nonisolated(unsafe) var presentationObservation: NSKeyValueObservation?

    init(
        model: BackdropModel,
        displays: @escaping @MainActor () -> [SideTabDisplay] = SideTabDisplays.current,
        systemAllows: @escaping @MainActor () -> Bool = SideTabController.systemAllows,
        observeSystem: Bool = true,
        onOpen: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.displays = displays
        self.systemAllows = systemAllows
        self.onOpen = onOpen
        panel = SideTabPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        button = SideTabButton(frame: .zero)
        panel.contentView = button
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone]
        panel.isExcludedFromWindowsMenu = true
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.setAccessibilityLabel("Open ambient panel")
        button.toolTip = "Open ambient panel (⌃⌥Space)"
        button.onPress = { [weak self] in self?.open() }

        model.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }.store(in: &subscriptions)
        model.pages.$owner.removeDuplicates().sink { [weak self] _ in
            self?.scheduleRefresh()
        }.store(in: &subscriptions)
        if observeSystem { observe() }
        refresh()
    }

    deinit {
        for (center, token) in observations { center.removeObserver(token) }
        presentationObservation?.invalidate()
    }

    func stop() {
        stopped = true
        panel.orderOut(nil)
        subscriptions.removeAll()
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        presentationObservation?.invalidate()
        presentationObservation = nil
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    private var target: CGRect? {
        guard !stopped, model.sideTab.enabled, model.ambientPanelEnabled,
              !model.editorWindowOpen, model.pages.owner == .panel,
              model.stance == .resting, !model.pinned,
              sessionActive, machineAwake, screensAwake,
              menuDepth == 0, sheetDepth == 0, systemAllows() else { return nil }
        return SideTabPlacement.frame(displayID: model.sideTab.displayID, edge: model.sideTab.edge,
            position: model.sideTab.position, displays: displays())
    }

    func refresh() {
        guard let target else {
            panel.orderOut(nil)
            return
        }
        button.edge = model.sideTab.edge
        panel.setFrame(target, display: true)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    private func open() {
        guard panel.isVisible, let target, panel.frame == target else {
            refresh()
            return
        }
        panel.orderOut(nil)
        onOpen()
    }

    static func systemAllows() -> Bool {
        guard let app = NSApp, !app.isHidden, !ModalSession.isRunning,
              !ModalSession.isBracketed,
              !app.currentSystemPresentationOptions.contains(.fullScreen),
              !app.windows.contains(where: { $0.attachedSheet != nil }) else { return false }
        return true
    }

    private func watch(
        _ name: Notification.Name, center: NotificationCenter = .default,
        change: @escaping @MainActor (SideTabController) -> Void = { $0.refresh() }
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
            }
        }
        observations.append((center, token))
    }

    private func observe() {
        for name in [NSApplication.didChangeScreenParametersNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     ModalSession.didEndNotification] { watch(name) }
        watch(NSMenu.didBeginTrackingNotification) { $0.menuDepth += 1; $0.refresh() }
        watch(NSMenu.didEndTrackingNotification) { $0.menuDepth = max(0, $0.menuDepth - 1); $0.refresh() }
        watch(NSWindow.willBeginSheetNotification) { $0.sheetDepth += 1; $0.refresh() }
        watch(NSWindow.didEndSheetNotification) { $0.sheetDepth = max(0, $0.sheetDepth - 1); $0.refresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        watch(NSWorkspace.activeSpaceDidChangeNotification, center: workspace)
        watch(NSWorkspace.didActivateApplicationNotification, center: workspace)
        watch(NSWorkspace.willSleepNotification, center: workspace) { $0.machineAwake = false; $0.refresh() }
        watch(NSWorkspace.didWakeNotification, center: workspace) { $0.machineAwake = true; $0.refresh() }
        watch(NSWorkspace.screensDidSleepNotification, center: workspace) { $0.screensAwake = false; $0.refresh() }
        watch(NSWorkspace.screensDidWakeNotification, center: workspace) { $0.screensAwake = true; $0.refresh() }
        watch(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { $0.sessionActive = false; $0.refresh() }
        watch(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { $0.sessionActive = true; $0.refresh() }
        presentationObservation = NSApplication.shared.observe(\.currentSystemPresentationOptions) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
}

final class SideTabPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SideTabButton: NSButton {
    var onPress: (() -> Void)?
    var edge: SideTabEdge = .right { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(press)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("side tabs are created in code") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func press() { onPress?() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (isHighlighted ? NSColor.selectedControlColor : .windowBackgroundColor).setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.stroke()
        let symbol = edge == .right ? "chevron.left" : "chevron.right"
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            .applying(.init(paletteColors: [isHighlighted ? .selectedControlTextColor : .labelColor]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.draw(in: NSRect(x: (bounds.width - 10) / 2, y: (bounds.height - 14) / 2,
            width: 10, height: 14))
    }
}
