import AppKit
import Carbon.HIToolbox

// Standalone interaction experiments, not the application's activation route.
enum Mode: String, CaseIterable {
    case dwell = "Edge · dwell"
    case proximity = "Edge · two proximity bands"
    case push = "Edge · outward delta probe"
    case corner = "Bottom-right corner · dwell"
    case modifier = "Option + edge approach"
    case status = "Menu-bar hover"
    case tab = "Visible edge tab"
    case held = "Held ⌘⌥G glance"
    case pointer = "Pointer-local ⌘⌥P"
    case drag = "Drag toward edge / drop"
    case shake = "Mouse shake"
    case doubleShift = "Double Shift tap"

    var hasEdgeTarget: Bool {
        switch self {
        case .dwell, .proximity, .push, .corner, .modifier, .tab, .drag: return true
        default: return false
        }
    }

    var instructions: String {
        switch self {
        case .dwell: return "Move your pointer onto the target at the actual screen edge—not this window. Wait half a second without clicking: a narrow peek expands into a card. Move away to dismiss."
        case .proximity: return "Move your pointer into the edge target. Pause briefly, then move all the way to the screen boundary: the narrow peek expands into a card. Move away to dismiss."
        case .push: return "Move your pointer into the edge target, then keep moving your mouse or finger outward against the screen boundary. Watch for the peek to expand. Waiting alone will not expand it; some devices may supply no useful outward deltas."
        case .corner: return "Move your pointer to the bottom-right corner of the chosen display, not the controls window. Wait half a second for the peek to expand. System Hot Corners may also respond."
        case .modifier: return "Hold Option, move your pointer into the edge target, and wait half a second for the peek to expand. Release Option or move away to dismiss."
        case .status: return "Move your pointer over RL in the macOS menu bar at the top of your screen. Do not click. Wait half a second, then move down into the card. Click RL only to reopen these controls."
        case .tab: return "Move your pointer over the small colored handle at the chosen screen edge. Wait half a second to see it expand into a card. Clicking the handle opens the mock editor directly."
        case .held: return "Press and HOLD Command + Option + G together. A card appears at the chosen screen edge. Release G to dismiss. To edit, keep holding G while moving into the card and clicking Open."
        case .pointer: return "Put your pointer anywhere on the desktop. Press Command + Option + P together, then release. A card appears beside the pointer. Move into it to click Open, or move away to dismiss."
        case .drag: return "Start dragging selected text from TextEdit or a file from Finder. While still holding the mouse button, move onto the edge handle, then into the card. Release to drop and open the mock editor; the payload is not imported."
        case .shake: return "Move your mouse or trackpad finger quickly left-right-left-right several times. A card should appear beside your pointer. Move into it to click Open, or move away to dismiss."
        case .doubleShift: return "Press and release Shift, then press and release it again quickly. Do not hold another modifier. A card appears beside your pointer. Extremely fast taps can be missed; try two distinct taps."
        }
    }
}

enum Side: String, CaseIterable { case right = "Right", left = "Left", top = "Top", bottom = "Bottom" }
enum Phase: String { case idle, peek, card }

struct DisplaySnapshot {
    let id: CGDirectDisplayID
    let name: String
    let frame: NSRect
    let visibleFrame: NSRect

    static func current() -> [DisplaySnapshot] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplaySnapshot(id: number.uint32Value, name: screen.localizedName,
                                   frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    static func selectedID(previous: CGDirectDisplayID?, in screens: [DisplaySnapshot]) -> CGDirectDisplayID? {
        if let previous, screens.contains(where: { $0.id == previous }) { return previous }
        return screens.first?.id
    }
}

struct ShiftTapDetector {
    private var shiftDown = false
    private var pressedAt: TimeInterval?
    private var contaminated = false
    private var lastTap: TimeInterval?

    mutating func reset(flags: NSEvent.ModifierFlags) {
        shiftDown = flags.contains(.shift)
        pressedAt = nil; lastTap = nil; contaminated = shiftDown
    }

    mutating func sample(flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Bool {
        let shift = flags.contains(.shift)
        let chord = !flags.intersection([.command, .option, .control]).isEmpty
        if chord { lastTap = nil }
        if shift && !shiftDown { pressedAt = time; contaminated = chord }
        if shift && chord { contaminated = true }
        defer { shiftDown = shift }
        guard !shift && shiftDown else { return false }
        defer { pressedAt = nil; contaminated = false }
        guard let pressedAt, time >= pressedAt, time - pressedAt < 0.3, !contaminated, !chord else {
            lastTap = nil
            return false
        }
        if let lastTap, time >= lastTap, time - lastTap < 0.4 {
            self.lastTap = nil
            return true
        }
        lastTap = time
        return false
    }
}

func stagedFrame(_ card: NSRect, stage: Phase, mode: Mode, side: Side) -> NSRect {
    guard stage == .peek else { return card }
    var frame = card
    if mode == .corner { frame.size.height = 34 }
    else if mode == .status || side == .top { frame.origin.y = frame.maxY - 34; frame.size.height = 34 }
    else if side == .bottom { frame.size.height = 34 }
    else if side == .left { frame.size.width = 34 }
    else { frame.origin.x = frame.maxX - 34; frame.size.width = 34 }
    return frame
}

struct EdgeGeometry {
    var frame: NSRect
    var side: Side
    var fraction: CGFloat
    var center: NSPoint {
        switch side {
        case .right: return NSPoint(x: frame.maxX, y: frame.minY + frame.height * fraction)
        case .left: return NSPoint(x: frame.minX, y: frame.minY + frame.height * fraction)
        case .top: return NSPoint(x: frame.minX + frame.width * fraction, y: frame.maxY)
        case .bottom: return NSPoint(x: frame.minX + frame.width * fraction, y: frame.minY)
        }
    }
    func distance(_ p: NSPoint) -> CGFloat {
        switch side {
        case .right: return frame.maxX - p.x
        case .left: return p.x - frame.minX
        case .top: return frame.maxY - p.y
        case .bottom: return p.y - frame.minY
        }
    }
    var entryFrame: NSRect {
        let c = center
        switch side {
        case .right: return NSRect(x: frame.maxX - 24, y: c.y - 70, width: 24, height: 140)
        case .left: return NSRect(x: frame.minX, y: c.y - 70, width: 24, height: 140)
        case .top: return NSRect(x: c.x - 70, y: frame.maxY - 24, width: 140, height: 24)
        case .bottom: return NSRect(x: c.x - 70, y: frame.minY, width: 140, height: 24)
        }
    }
    func contains(_ p: NSPoint, depth: CGFloat = 24, halfLength: CGFloat = 70) -> Bool {
        let d = distance(p)
        let along = (side == .left || side == .right) ? abs(p.y - center.y) : abs(p.x - center.x)
        return d >= 0 && d <= depth && along <= halfLength
    }
    func isExposed(at p: NSPoint, others: [NSRect]) -> Bool {
        var outside = p
        switch side {
        case .right: outside.x = frame.maxX + 1
        case .left: outside.x = frame.minX - 1
        case .top: outside.y = frame.maxY + 1
        case .bottom: outside.y = frame.minY - 1
        }
        return !others.contains { $0.contains(outside) }
    }
    func outward(_ event: NSEvent) -> CGFloat {
        switch side {
        case .right: return event.deltaX
        case .left: return -event.deltaX
        case .top: return -event.deltaY
        case .bottom: return event.deltaY
        }
    }
}

func clamped(_ rect: NSRect, to bounds: NSRect) -> NSRect {
    NSRect(x: max(bounds.minX, min(rect.minX, bounds.maxX - rect.width)),
           y: max(bounds.minY, min(rect.minY, bounds.maxY - rect.height)),
           width: rect.width, height: rect.height)
}

final class RevealPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CardButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class CardView: NSView {
    let title = NSTextField(labelWithString: "Reveal Lab")
    let detail = NSTextField(wrappingLabelWithString: "Content-free prototype")
    let open = CardButton(title: "Open mock editor", target: nil, action: nil)
    let dismiss = CardButton(title: "×", target: nil, action: nil)
    var commit: (() -> Void)?
    var cancel: (() -> Void)?
    var dropped: ((Int) -> Void)?
    var acceptsDrop = false
    var stage: Phase = .idle { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        title.font = .boldSystemFont(ofSize: 16)
        detail.font = .systemFont(ofSize: 11)
        open.target = self; open.action = #selector(openClicked)
        dismiss.target = self; dismiss.action = #selector(cancelClicked)
        open.bezelStyle = .rounded
        for view in [title, detail, open, dismiss] { addSubview(view) }
        registerForDraggedTypes([.string, .fileURL, .URL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func layout() {
        super.layout()
        let peek = stage != .card
        title.stringValue = peek ? "RL" : "Reveal Lab"
        title.frame = NSRect(x: 10, y: bounds.height - 32, width: bounds.width - 20, height: 22)
        detail.frame = NSRect(x: 12, y: 53, width: bounds.width - 24, height: 42)
        open.frame = NSRect(x: 10, y: 10, width: 190, height: 30)
        dismiss.frame = NSRect(x: bounds.width - 32, y: bounds.height - 30, width: 24, height: 24)
        detail.isHidden = peek; open.isHidden = peek; dismiss.isHidden = peek
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === open || hit.isDescendant(of: open) || hit === dismiss || hit.isDescendant(of: dismiss) { return hit }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        if open.isEnabled && !acceptsDrop { commit?() }
    }
    @objc func openClicked() { if open.isEnabled { commit?() } }
    @objc func cancelClicked() { cancel?() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { acceptsDrop ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { acceptsDrop ? .copy : [] }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { acceptsDrop }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrop else { return false }
        dropped?(sender.draggingPasteboard.pasteboardItems?.count ?? 0)
        return true
    }
}

final class HandleView: NSView {
    var enter: (() -> Void)?
    var exit: (() -> Void)?
    var click: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { enter?() }
    override func mouseExited(with event: NSEvent) { exit?() }
    override func mouseDown(with event: NSEvent) { click?() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        ("•" as NSString).draw(at: NSPoint(x: bounds.midX - 4, y: bounds.midY - 8),
                             withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 14)])
    }
}

final class TargetGuideView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.withAlphaComponent(0.22).setFill()
        bounds.fill()
        NSColor.systemOrange.setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        outline.lineWidth = 3
        outline.setLineDash([6, 4], count: 2, phase: 0)
        outline.stroke()
    }
}

final class Lab: NSObject, NSApplicationDelegate {
    let controls = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 690),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let reveal = RevealPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let handle = RevealPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let guide = RevealPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let marker = NSButton(checkboxWithTitle: "Show orange target marker on screen", target: nil, action: nil)
    let location = NSTextField(wrappingLabelWithString: "")
    let card = CardView(frame: .zero)
    let handleView = HandleView(frame: .zero)
    let modes = NSPopUpButton()
    let sides = NSPopUpButton()
    let displays = NSPopUpButton()
    let position = NSSlider(value: 0.5, minValue: 0.15, maxValue: 0.85, target: nil, action: nil)
    let pause = NSButton(checkboxWithTitle: "Pause triggers (shortcuts remain registered)", target: nil, action: nil)
    let instructions = NSTextField(wrappingLabelWithString: "")
    let telemetry = NSTextField(wrappingLabelWithString: "idle")
    let events = NSTextField(wrappingLabelWithString: "")
    var status: NSStatusItem!
    var keys: LabHotKeys?
    var timer: Timer?
    var globalMonitor: Any?
    var localMonitor: Any?
    var editor: NSWindow?
    var mode: Mode { Mode.allCases[modes.indexOfSelectedItem] }
    var side: Side { Side.allCases[sides.indexOfSelectedItem] }
    var displayProvider: () -> [DisplaySnapshot] = DisplaySnapshot.current
    var displaySnapshots: [DisplaySnapshot] = []
    var screen: DisplaySnapshot? {
        let index = displays.indexOfSelectedItem
        return displaySnapshots.indices.contains(index) ? displaySnapshots[index] : nil
    }
    var edge: EdgeGeometry? { screen.map { EdgeGeometry(frame: $0.frame, side: side, fraction: CGFloat(position.doubleValue)) } }
    var sleeping = false
    var triggersAvailable: Bool { !sleeping && screen != nil && pause.state == .off && editor?.isVisible != true }
    var phase: Phase = .idle
    var enteredAt: TimeInterval?
    var exitAt: TimeInterval?
    var shownAt: TimeInterval = 0
    var cardFrame = NSRect.zero
    var blocked = false
    var pointerWasOutside = false
    var armingOrigin = NSPoint.zero
    var hoveringStatus = false
    var hoveringHandle = false
    var held = false
    var explicitAnchor: NSPoint?
    var push: CGFloat = 0
    var lastDelta: CGFloat = 0

    var shiftTaps = ShiftTapDetector()
    var shakeStart: TimeInterval = 0
    var shakeSign: CGFloat = 0
    var shakeReversals = 0
    var shakeTravel: CGFloat = 0
    var logLines: [String] = []
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildControls()
        for panel in [reveal, handle, guide] {
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
            panel.isReleasedWhenClosed = false
        }
        reveal.contentView = card; handle.contentView = handleView
        guide.contentView = TargetGuideView(frame: .zero)
        guide.ignoresMouseEvents = true
        guide.hasShadow = false
        reveal.ignoresMouseEvents = true
        card.commit = { [weak self] in self?.openEditor() }
        card.cancel = { [weak self] in self?.dismiss(block: true) }
        card.dropped = { [weak self] count in self?.openEditor(dropCount: count) }
        handleView.enter = { [weak self] in self?.hoveringHandle = true }
        handleView.exit = { [weak self] in self?.hoveringHandle = false }
        handleView.click = { [weak self] in self?.openEditor() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = status.button {
            button.title = "RL"
            button.toolTip = "Reveal Lab — click for controls"
            button.target = self; button.action = #selector(showControls)
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        keys = LabHotKeys(onGlance: { [weak self] down in self?.glance(down) },
                          onPointer: { [weak self] in self?.pointerShortcut() },
                          onFailure: { [weak self] message in self?.log(message) })
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] in self?.mouseMoved($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown]) { [weak self] event in
            if event.type == .mouseMoved { self?.mouseMoved(event) }
            if event.type == .keyDown && event.keyCode == 53 { self?.dismiss(block: true) }
            return event
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
        changed()
        showControls()
    }

    func buildControls() {
        controls.title = "Reveal Lab — standalone prototypes"
        controls.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controls.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: controls.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: controls.contentView!.topAnchor, constant: 20)
        ])
        modes.addItems(withTitles: Mode.allCases.map(\.rawValue))
        sides.addItems(withTitles: Side.allCases.map(\.rawValue))
        refreshDisplays()
        for popup in [modes, sides, displays] { popup.target = self; popup.action = #selector(changed) }
        position.target = self; position.action = #selector(changed)
        pause.target = self; pause.action = #selector(changed)
        marker.state = .on
        marker.target = self; marker.action = #selector(updateGuide)
        let intro = NSTextField(wrappingLabelWithString: "Choose a gesture below, then try it on your actual desktop—not inside this window. Your selection is enabled immediately.")
        intro.font = .boldSystemFont(ofSize: 13)
        intro.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let gestureRow = NSStackView(views: [NSTextField(labelWithString: "Gesture to try:"), modes])
        let geometryRow = NSStackView(views: [NSTextField(labelWithString: "Target:"), displays, sides])
        let positionRow = NSStackView(views: [NSTextField(labelWithString: "Position along edge:"), position])
        position.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let show = NSButton(title: "Show card (fallback)", target: self, action: #selector(showFallback))
        let edit = NSButton(title: "Open mock editor", target: self, action: #selector(editFallback))
        let quit = NSButton(title: "Quit lab", target: self, action: #selector(quit))
        let actions = NSStackView(views: [show, edit, quit])
        instructions.heightAnchor.constraint(equalToConstant: 100).isActive = true
        location.heightAnchor.constraint(equalToConstant: 40).isActive = true
        events.heightAnchor.constraint(equalToConstant: 64).isActive = true
        telemetry.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        events.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let scope = NSTextField(wrappingLabelWithString: "When a card appears, move your pointer into it, then click the card or Open mock editor. Close the mock editor before trying another gesture. Click RL in the menu bar to reopen these controls.")
        for view in [intro, gestureRow, instructions, geometryRow, positionRow, location, marker, pause, actions, telemetry, events, scope] {
            stack.addArrangedSubview(view)
        }
        for label in [intro, instructions, location, telemetry, events, scope] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        controls.center()
    }

    func refreshDisplays() {
        let previous = screen?.id
        displaySnapshots = displayProvider()
        let selected = DisplaySnapshot.selectedID(previous: previous, in: displaySnapshots)
        displays.removeAllItems()
        displays.addItems(withTitles: displaySnapshots.enumerated().map { "\($0.offset + 1): \($0.element.name)" })
        if let index = displaySnapshots.firstIndex(where: { $0.id == selected }) { displays.selectItem(at: index) }
    }
    @objc func layoutChanged() { refreshDisplays(); changed() }
    @objc func workspaceChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.willSleepNotification { sleeping = true }
        if notification.name == NSWorkspace.didWakeNotification { sleeping = false; refreshDisplays() }
        changed()
        blocked = true
    }
    @objc func showControls() { controls.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func editFallback() { openEditor() }
    @objc func showFallback() {
        guard triggersAvailable else { log("Card unavailable: paused, sleeping, no display, or mock editor open"); return }
        revealNearPointer()
    }
    @objc func changed() {
        dismiss(block: false)
        held = false; explicitAnchor = nil; hoveringHandle = false; hoveringStatus = false
        instructions.stringValue = mode.instructions
        guard let screen, let edge else {
            handle.orderOut(nil); guide.orderOut(nil)
            displays.isEnabled = false; sides.isEnabled = false; position.isEnabled = false; marker.isEnabled = false
            location.stringValue = "No displays available. Reveal triggers are suspended."
            return
        }
        let target = edge.center
        let vertical = side == .left || side == .right
        let rect = clamped(NSRect(x: target.x - (vertical ? 10 : 35), y: target.y - (vertical ? 35 : 10),
                                 width: vertical ? 20 : 70, height: vertical ? 70 : 20), to: screen.visibleFrame)
        handle.setFrame(rect, display: true)
        if !sleeping && pause.state == .off && (mode == .tab || mode == .drag) { handle.orderFront(nil) }
        else { handle.orderOut(nil) }
        let usesEdgePlacement = mode.hasEdgeTarget || mode == .held
        displays.isEnabled = usesEdgePlacement
        sides.isEnabled = usesEdgePlacement && mode != .corner
        position.isEnabled = sides.isEnabled
        marker.isEnabled = mode.hasEdgeTarget
        if mode == .corner {
            location.stringValue = "Target: bottom-right corner of \(screen.name)."
        } else if usesEdgePlacement {
            let direction = side == .left || side == .right ? "up from the bottom" : "across from the left"
            location.stringValue = "Target: \(side.rawValue.lowercased()) edge of \(screen.name), \(Int(position.doubleValue * 100))% \(direction).\nMove the pointer to this screen location to try the edge gesture."
            if mode == .held { location.stringValue = "Card location: \(side.rawValue.lowercased()) edge of \(screen.name). Use the held shortcut, not edge hover." }
        } else {
            location.stringValue = mode == .status ? "Target: RL in the macOS menu bar. Edge and display settings do not apply." : "No screen-edge target. Use the gesture above; the card appears beside your pointer."
        }
        if mode.hasEdgeTarget && mode != .corner {
            let others = displaySnapshots.filter { $0.id != screen.id }.map(\.frame)
            if !edge.isExposed(at: edge.center, others: others) {
                location.stringValue = "Target borders another display at its center. Choose an outside edge or move the slider to an exposed part of this edge."
            }
        }
        updateGuide()
        log("Mode: \(mode.rawValue)")
    }
    @objc func updateGuide() {
        guard let screen, let edge, !sleeping, marker.state == .on, mode.hasEdgeTarget, pause.state == .off else {
            guide.orderOut(nil)
            return
        }
        let rect: NSRect
        if mode == .corner {
            guard let source = sourceFrame() else { guide.orderOut(nil); return }
            rect = source
        }
        else if mode == .tab || mode == .drag { rect = handle.frame.insetBy(dx: -5, dy: -5) }
        else { rect = edge.entryFrame }
        guide.setFrame(rect.intersection(screen.frame), display: true)
        guide.orderFront(nil)
    }
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { hoveringStatus = true }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { hoveringStatus = false }

    func log(_ text: String) {
        logLines.append(String(format: "%.2f %@", now, text))
        logLines = Array(logLines.suffix(6))
        events.stringValue = logLines.joined(separator: "\n")
    }

    func geometryEligible(_ p: NSPoint, exit: Bool = false) -> Bool {
        guard let screen, let edge else { return false }
        let others = displaySnapshots.filter { $0.id != screen.id }.map(\.frame)
        if mode == .corner {
            let right = EdgeGeometry(frame: screen.frame, side: .right, fraction: 0)
            let bottom = EdgeGeometry(frame: screen.frame, side: .bottom, fraction: 1)
            let width: CGFloat = exit ? 44 : 24
            return right.distance(p) >= 0 && right.distance(p) <= width && bottom.distance(p) >= 0 && bottom.distance(p) <= width
                && right.isExposed(at: p, others: others) && bottom.isExposed(at: p, others: others)
        }
        return edge.contains(p, depth: exit ? 44 : 24, halfLength: exit ? 90 : 70) && edge.isExposed(at: p, others: others)
    }

    func sourceEligible(_ p: NSPoint, exit: Bool = false) -> Bool {
        guard triggersAvailable else { return false }
        switch mode {
        case .status: return hoveringStatus
        case .tab: return hoveringHandle
        case .held: return held
        case .pointer, .shake, .doubleShift: return false
        case .modifier: return NSEvent.modifierFlags.contains(.option) && geometryEligible(p, exit: exit)
        case .drag: return NSEvent.pressedMouseButtons != 0 && (geometryEligible(p, exit: exit) || handle.frame.insetBy(dx: -12, dy: -12).contains(p))
        default: return geometryEligible(p, exit: exit)
        }
    }

    func tick() {
        let p = NSEvent.mouseLocation
        let time = now
        detectShift(time)
        let activeName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        telemetry.stringValue = "\(phase.rawValue) | active: \(activeName) | outward Δ: \(String(format: "%.1f", lastDelta)) | push: \(String(format: "%.1f", push)) | click: \(card.open.isEnabled ? "armed" : "not armed")"
        guard triggersAvailable else {
            shiftTaps.reset(flags: NSEvent.modifierFlags)
            if phase != .idle { dismiss(block: true) }
            return
        }
        if mode == .modifier && !NSEvent.modifierFlags.contains(.option) {
            if phase != .idle { dismiss(block: false) }
            enteredAt = nil
            return
        }
        if mode != .drag && NSEvent.pressedMouseButtons != 0 {
            if phase == .idle { enteredAt = nil }
            return
        }
        let source = sourceEligible(p)
        if blocked {
            if !source { blocked = false }
            return
        }
        if phase == .idle {
            if source {
                if enteredAt == nil { enteredAt = time; explicitAnchor = nil; push = 0 }
                if time - enteredAt! >= 0.12 { show(.peek) }
            } else { enteredAt = nil; push = 0 }
        } else {
            let insideCard = reveal.frame.contains(p)
            updateCardInteraction(at: p, time: time)
            let keep = retainsCard(at: p)
            if keep { exitAt = nil }
            else if let exitAt, time - exitAt > 0.2 { dismiss(block: false) }
            else if exitAt == nil { exitAt = time }
            if phase == .peek, let enteredAt {
                let elapsed = time - enteredAt
                let nearer = (edge?.distance(p)).map { $0 <= 4 } == true && geometryEligible(p)
                let intoPeek = insideCard && pointerWasOutside
                let expand: Bool
                switch mode {
                case .proximity: expand = elapsed >= 0.24 && nearer
                case .push: expand = elapsed >= 0.24 && push >= 18
                case .drag: expand = true
                default: expand = elapsed >= 0.45 || (elapsed >= 0.24 && intoPeek)
                }
                if expand { show(.card) }
            }
        }
        push = max(0, push - 0.15)

    }

    func retainsCard(at point: NSPoint) -> Bool {
        guard triggersAvailable else { return false }
        if explicitAnchor != nil || mode == .held || mode == .pointer || mode == .shake || mode == .doubleShift {
            return reveal.frame.insetBy(dx: -45, dy: -45).contains(point)
        }
        guard let source = sourceFrame() else { return false }
        return sourceEligible(point, exit: true) || reveal.frame.union(source).insetBy(dx: -16, dy: -16).contains(point)
    }

    func updateCardInteraction(at point: NSPoint, time: TimeInterval) {
        let inside = reveal.frame.contains(point)
        if !inside { pointerWasOutside = true }
        guard phase == .card, !card.acceptsDrop, !card.open.isEnabled else { return }
        let moved = hypot(point.x - armingOrigin.x, point.y - armingOrigin.y) >= 4
        if time - shownAt > 0.12 && inside && (pointerWasOutside || moved) {
            card.open.isEnabled = true
            card.detail.stringValue = "Click this card to open\nthe mock editor."
        }
    }

    func sourceFrame() -> NSRect? {
        guard let screen, let edge else { return nil }
        if mode == .status, let button = status.button, let window = button.window {
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        if mode == .tab || mode == .drag { return handle.frame }
        if mode == .corner { return NSRect(x: screen.frame.maxX - 24, y: screen.frame.minY, width: 24, height: 24) }
        let c = edge.center
        let vertical = side == .left || side == .right
        return NSRect(x: c.x - (vertical ? 24 : 70), y: c.y - (vertical ? 70 : 24), width: vertical ? 48 : 140, height: vertical ? 140 : 48)
    }

    func destination() -> NSRect? {
        guard let screen, let edge else { return nil }
        let bounds = screen.visibleFrame
        let size = NSSize(width: 248, height: 132)
        if let p = explicitAnchor { return clamped(NSRect(origin: NSPoint(x: p.x + 18, y: p.y - 70), size: size), to: (displaySnapshots.first { $0.frame.contains(p) } ?? screen).visibleFrame) }
        if mode == .status {
            guard let source = sourceFrame() else { return nil }
            let targetScreen = displaySnapshots.first { $0.frame.contains(NSPoint(x: source.midX, y: source.midY)) } ?? screen
            return clamped(NSRect(x: source.midX - 124, y: source.minY - 136, width: size.width, height: size.height), to: targetScreen.visibleFrame)
        }
        if mode == .corner { return NSRect(x: bounds.maxX - 248, y: bounds.minY, width: 248, height: 132) }
        let c = edge.center
        switch side {
        case .right: return clamped(NSRect(x: bounds.maxX - 248, y: c.y - 66, width: 248, height: 132), to: bounds)
        case .left: return clamped(NSRect(x: bounds.minX, y: c.y - 66, width: 248, height: 132), to: bounds)
        case .top: return clamped(NSRect(x: c.x - 124, y: bounds.maxY - 132, width: 248, height: 132), to: bounds)
        case .bottom: return clamped(NSRect(x: c.x - 124, y: bounds.minY, width: 248, height: 132), to: bounds)
        }
    }

    func show(_ stage: Phase) {
        guard stage != .idle, triggersAvailable, let destination = destination() else { return }
        let first = phase == .idle
        if first { cardFrame = destination }
        let frame = stagedFrame(cardFrame, stage: stage, mode: mode, side: side)
        phase = stage; card.stage = stage; shownAt = now; exitAt = nil
        armingOrigin = NSEvent.mouseLocation
        pointerWasOutside = !frame.contains(armingOrigin)
        card.open.isEnabled = false
        card.acceptsDrop = mode == .drag && stage == .card
        card.detail.stringValue = card.acceptsDrop ? "Drop text or a file here.\nOnly the item count is used." : "Move your pointer into this card\nto enable opening."
        reveal.ignoresMouseEvents = stage == .peek
        if first || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { reveal.setFrame(frame, display: true) }
        else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                reveal.animator().setFrame(frame, display: true)
            }
        }
        reveal.orderFront(nil)
        log(stage.rawValue)
    }

    func dismiss(block: Bool) {
        if phase != .idle { log("dismiss") }
        reveal.orderOut(nil)
        phase = .idle; card.stage = .idle; enteredAt = nil; exitAt = nil; explicitAnchor = nil
        blocked = block; push = 0; card.open.isEnabled = false; card.acceptsDrop = false
        shiftTaps.reset(flags: NSEvent.modifierFlags)
        shakeStart = 0; shakeSign = 0; shakeReversals = 0; shakeTravel = 0
    }

    func glance(_ down: Bool) {
        guard mode == .held, held != down else { return }
        guard triggersAvailable else { held = false; return }
        held = down
        if down {
            blocked = false; enteredAt = now; explicitAnchor = nil; show(.card)
        } else if !down { dismiss(block: true) }
    }
    func pointerShortcut() {
        guard mode == .pointer, triggersAvailable else { return }
        revealNearPointer()
    }
    func revealNearPointer() {
        guard triggersAvailable else { return }
        blocked = false; enteredAt = now; explicitAnchor = NSEvent.mouseLocation; show(.card)
    }
    func detectShift(_ time: TimeInterval, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard mode == .doubleShift, triggersAvailable else { shiftTaps.reset(flags: flags); return }
        if shiftTaps.sample(flags: flags, at: time) { revealNearPointer() }
    }
    func mouseMoved(_ event: NSEvent) {
        guard triggersAvailable, let edge else { return }
        if mode == .push {
            lastDelta = edge.outward(event)
            if geometryEligible(NSEvent.mouseLocation) && edge.distance(NSEvent.mouseLocation) <= 2 {
                push = max(0, push + lastDelta)
            } else { push = 0 }
        }
        if mode == .shake && NSEvent.pressedMouseButtons == 0 {
            let time = now
            let dx = event.deltaX
            guard abs(dx) > 2 else { return }
            if time - shakeStart > 0.65 { shakeStart = time; shakeReversals = 0; shakeTravel = 0; shakeSign = 0 }
            let sign: CGFloat = dx > 0 ? 1 : -1
            if shakeSign != 0 && sign != shakeSign { shakeReversals += 1 }
            shakeSign = sign; shakeTravel += abs(dx)
            if shakeReversals >= 4 && shakeTravel > 90 && phase == .idle {
                revealNearPointer(); shakeReversals = 0; shakeTravel = 0
            }
        }
    }

    func openEditor(dropCount: Int? = nil) {
        dismiss(block: true)
        if editor == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Reveal Lab — mock editor (not OnetimePad)"
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
            scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.autoresizingMask = [.width, .height]
            text.font = .systemFont(ofSize: 16)
            text.string = "Dummy editor. Type here after explicitly committing.\n\nClose this window to resume reveal experiments.\nNo real pad data is loaded."
            scroll.documentView = text; window.contentView = scroll; window.center()
            editor = window
        }
        if let dropCount { log("Drop committed: \(dropCount) item(s); payload ignored") }
        else { log("Explicit commit → mock editor") }
        editor!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let scroll = editor!.contentView as? NSScrollView { editor!.makeFirstResponder(scroll.documentView) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        keys?.shutdown()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSStatusBar.system.removeStatusItem(status)
    }
}

struct TestContext {
    let name: String

    func fail(_ message: String, line: Int = #line) -> Never {
        fputs("FAIL [\(name)] line \(line): \(message)\n", stderr)
        exit(1)
    }

    func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        if !condition() { fail(message, line: line) }
    }

    func require<T>(_ value: T?, _ message: String, line: Int = #line) -> T {
        guard let value else { fail(message, line: line) }
        return value
    }
}

func selfTest() {
    let test = TestContext(name: "self-test geometry")
    let frame = NSRect(x: -1000, y: 0, width: 1000, height: 800)
    let edge = EdgeGeometry(frame: frame, side: .right, fraction: 0.5)
    test.expect(edge.contains(NSPoint(x: -12, y: 400)), "Entry band must include 12pt depth")
    test.expect(!edge.contains(NSPoint(x: -25, y: 400)), "Entry band must exclude 25pt depth")
    test.expect(!edge.contains(NSPoint(x: -12, y: 480)), "Entry band must exclude 80pt along-edge distance")
    test.expect(edge.contains(NSPoint(x: -25, y: 480), depth: 44, halfLength: 90), "Exit band must include its wider margin")
    test.expect(!edge.contains(NSPoint(x: 1, y: 400)), "Points outside the display must be excluded")
    test.expect(edge.isExposed(at: NSPoint(x: 0, y: 400), others: []), "Unshared edge must be exposed")
    test.expect(!edge.isExposed(at: NSPoint(x: 0, y: 400), others: [NSRect(x: 0, y: 0, width: 1000, height: 800)]), "Shared seam must not be exposed")
    test.expect(edge.isExposed(at: NSPoint(x: 0, y: 700), others: [NSRect(x: 0, y: 0, width: 1000, height: 600)]), "Unshared part of a partial seam must be exposed")
    for side in Side.allCases {
        let test = TestContext(name: "self-test side=\(side.rawValue)")
        let e = EdgeGeometry(frame: frame, side: side, fraction: 0.5)
        test.expect(e.distance(e.center) == 0, "Edge center must have zero depth")
        test.expect(e.contains(e.center), "Edge center must be eligible")
        test.expect(frame.contains(e.entryFrame), "Entry marker must fit inside the display")
        test.expect(e.contains(NSPoint(x: e.entryFrame.midX, y: e.entryFrame.midY)), "Marker center must be eligible")
        let card = NSRect(x: -248, y: 30, width: 248, height: 132)
        let peek = stagedFrame(card, stage: .peek, mode: .corner, side: side)
        test.expect(peek == NSRect(x: card.minX, y: card.minY, width: 248, height: 34), "Corner peek must stay bottom-aligned regardless of prior side")
        test.expect(stagedFrame(card, stage: .card, mode: .corner, side: side) == card, "Full-card stage must preserve its frame")
    }
    let bounds = NSRect(x: -1000, y: 30, width: 1000, height: 740)
    test.expect(bounds.contains(clamped(NSRect(x: 0, y: -100, width: 248, height: 132), to: bounds)), "Card must clamp to visible bounds")

    let a = DisplaySnapshot(id: 11, name: "Same name", frame: frame, visibleFrame: bounds)
    let b = DisplaySnapshot(id: 22, name: "Same name", frame: frame, visibleFrame: bounds)
    let displays = TestContext(name: "self-test display selection")
    displays.expect(DisplaySnapshot.selectedID(previous: nil, in: [a, b]) == a.id, "Initial selection must use the first display")
    displays.expect(DisplaySnapshot.selectedID(previous: a.id, in: [b, a]) == a.id, "Reordering duplicate names must preserve display ID")
    displays.expect(DisplaySnapshot.selectedID(previous: a.id, in: [b]) == b.id, "Removing the selected display must select an available display")
    displays.expect(DisplaySnapshot.selectedID(previous: a.id, in: []) == nil, "Empty displays must have no selection")
    displays.expect(DisplaySnapshot.selectedID(previous: nil, in: [b]) == b.id, "Displays returning after an empty snapshot must recover")

    func fires(_ samples: [(TimeInterval, NSEvent.ModifierFlags)]) -> [TimeInterval] {
        var detector = ShiftTapDetector()
        return samples.compactMap { detector.sample(flags: $0.1, at: $0.0) ? $0.0 : nil }
    }
    let shift = TestContext(name: "self-test double Shift timing")
    shift.expect(fires([(0, .shift), (0.05, []), (0.15, .shift), (0.2, [])]) == [0.2], "Two clean short taps must fire once")
    shift.expect(fires([(0, .shift), (0.31, []), (0.4, .shift), (0.45, [])]).isEmpty, "Long Shift hold must invalidate the pair")
    shift.expect(fires([(0, .shift), (0.05, []), (0.6, .shift), (0.65, [])]).isEmpty, "Widely separated taps must not fire")
    for (name, modifier) in [("Command", NSEvent.ModifierFlags.command), ("Option", .option), ("Control", .control)] {
        let test = TestContext(name: "self-test Shift+\(name)")
        let chord = modifier.union(.shift)
        for contaminatedTap: [(TimeInterval, NSEvent.ModifierFlags)] in [
            [(0, chord), (0.02, .shift), (0.06, [])],
            [(0, .shift), (0.02, chord), (0.04, .shift), (0.06, [])],
            [(0, .shift), (0.02, chord), (0.06, modifier), (0.08, [])]
        ] {
            test.expect(fires(contaminatedTap + [(0.12, .shift), (0.16, [])]).isEmpty, "Chord contamination must survive releasing the other modifier before Shift")
            test.expect(fires([(-0.1, .shift), (-0.05, [])] + contaminatedTap + [(0.12, .shift), (0.16, [])]).isEmpty, "Contaminated second tap must discard a pending first tap")
        }
        test.expect(fires([(0, .shift), (0.05, []), (0.08, modifier), (0.1, []), (0.12, .shift), (0.16, [])]).isEmpty, "An intervening modifier must discard a pending tap")
    }
    var detector = ShiftTapDetector()
    _ = detector.sample(flags: .shift, at: 0)
    _ = detector.sample(flags: [], at: 0.05)
    detector.reset(flags: .shift)
    shift.expect(!detector.sample(flags: [], at: 0.1), "Reset during a held Shift must ignore its release")
    _ = detector.sample(flags: .shift, at: 0.15)
    shift.expect(!detector.sample(flags: [], at: 0.2), "Reset must clear the pending first tap")
    print("PASS: geometry, display selection/reorder/removal/empty recovery, corner peek across all sides, deterministic Shift timing/chord/reset tests")
}

func smokeTest(_ lab: Lab, app: NSApplication) {
    lab.timer?.invalidate()
    let startup = TestContext(name: "smoke startup")
    let originalProvider = lab.displayProvider
    let snapshots = lab.displaySnapshots
    startup.expect(!snapshots.isEmpty, "AppKit smoke tests require an available display")
    let keyWindow = app.keyWindow
    func select(_ mode: Mode) {
        lab.modes.selectItem(at: startup.require(Mode.allCases.firstIndex(of: mode), "Mode missing from popup"))
        lab.changed()
    }
    func post(_ name: Notification.Name) {
        NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
    }
    for mode in Mode.allCases {
        let test = TestContext(name: "smoke mode=\(mode.rawValue)")
        select(mode)
        test.expect(lab.instructions.stringValue == mode.instructions, "Instructions must match the selected mode")
        test.expect(lab.guide.ignoresMouseEvents && !lab.guide.canBecomeKey, "Guide must be non-key and mouse-transparent")
        test.expect(lab.guide.isVisible == mode.hasEdgeTarget, "Guide visibility must match the mode")
        if mode.hasEdgeTarget {
            let screen = test.require(lab.screen, "Guide needs a selected display")
            let expected: NSRect
            if mode == .corner { expected = test.require(lab.sourceFrame(), "Corner source missing") }
            else if mode == .tab || mode == .drag { expected = lab.handle.frame.insetBy(dx: -5, dy: -5) }
            else { expected = test.require(lab.edge, "Edge geometry missing").entryFrame }
            let clipped = expected.intersection(screen.frame)
            let actual = lab.guide.frame
            test.expect(abs(actual.minX - clipped.minX) <= 1 && abs(actual.minY - clipped.minY) <= 1
                        && abs(actual.width - clipped.width) <= 1 && abs(actual.height - clipped.height) <= 1,
                        "Marker frame \(actual) must match clipped source band \(clipped) within 1pt AppKit alignment")
        }
        lab.enteredAt = lab.now
        lab.show(.peek)
        lab.card.layoutSubtreeIfNeeded()
        test.expect(lab.phase == .peek && lab.card.stage == .peek, "Peek phase must reach CardView explicitly")
        test.expect(lab.card.open.isHidden && lab.reveal.ignoresMouseEvents, "Peek must hide controls and pass through clicks")
        lab.show(.card)
        test.expect(!lab.reveal.ignoresMouseEvents, "Full card must catch clicks before arming")
        test.expect(!lab.reveal.canBecomeKey && !lab.reveal.canBecomeMain, "Reveal must remain non-key and non-main")
        lab.reveal.setFrame(lab.cardFrame, display: true)
        lab.card.layoutSubtreeIfNeeded()
        test.expect(lab.card.stage == .card && !lab.card.open.isHidden, "Full stage must expose controls")
        let point = NSPoint(x: lab.cardFrame.midX - 10, y: lab.cardFrame.midY)
        lab.armingOrigin = point; lab.pointerWasOutside = false
        let click = test.require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 30, y: 100),
                                                  modifierFlags: [], timestamp: lab.now,
                                                  windowNumber: lab.reveal.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1), "Could not construct a simulated card click")
        var commits = 0
        let originalCommit = lab.card.commit
        lab.card.commit = { commits += 1 }
        test.expect(lab.card.acceptsFirstMouse(for: click) && lab.card.open.acceptsFirstMouse(for: click), "Card and Open must accept the first inactive click")
        test.expect(lab.card.hitTest(NSPoint(x: 30, y: 100)) === lab.card, "Card background must catch the click")
        lab.card.mouseDown(with: click)
        test.expect(commits == 0, "Unarmed click must not commit")
        lab.updateCardInteraction(at: point, time: lab.shownAt + 0.2)
        test.expect(!lab.card.open.isEnabled, "Stationary pointer must not arm")
        lab.updateCardInteraction(at: NSPoint(x: point.x + 2, y: point.y), time: lab.shownAt + 0.2)
        test.expect(!lab.card.open.isEnabled, "Two-point jitter must not arm")
        lab.updateCardInteraction(at: NSPoint(x: point.x + 6, y: point.y), time: lab.shownAt + 0.2)
        if mode != .drag {
            test.expect(lab.card.open.isEnabled, "Deliberate motion must arm the card")
            lab.card.mouseDown(with: click)
            test.expect(commits == 1, "Armed background click must commit exactly once")
        } else { test.expect(lab.card.acceptsDrop, "Drag card must accept drops instead of arming clicks") }
        lab.card.commit = originalCommit
        test.expect(app.keyWindow === keyWindow, "Reveal cycle must leave the key window unchanged")
        lab.dismiss(block: false)
        test.expect(lab.phase == .idle && lab.card.stage == .idle && !lab.reveal.isVisible, "Dismiss must reset phase, stage, and visibility")
    }

    let tracking = TestContext(name: "smoke mode=Menu-bar hover selector dispatch")
    select(.status)
    for (type, selector, expected) in [(NSEvent.EventType.mouseEntered, #selector(NSResponder.mouseEntered(with:)), true),
                                       (.mouseExited, #selector(NSResponder.mouseExited(with:)), false)] {
        tracking.expect(lab.responds(to: selector), "Tracking owner must respond to \(NSStringFromSelector(selector))")
        let event = tracking.require(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: lab.now,
                                                          windowNumber: lab.status.button?.window?.windowNumber ?? 0,
                                                          context: nil, eventNumber: 0, trackingNumber: 0, userData: nil), "Could not construct a tracking event")
        lab.perform(selector, with: event)
        tracking.expect(lab.hoveringStatus == expected, "Objective-C tracking dispatch must update hover state")
        tracking.expect(lab.sourceEligible(.zero) == expected, "Tracking dispatch must update status source eligibility")
    }

    let handle = TestContext(name: "smoke mode=Visible edge tab simulated inactive click")
    select(.tab)
    let click = handle.require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [],
                                                timestamp: lab.now, windowNumber: lab.handle.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1), "Could not construct a handle click")
    var clicks = 0
    let originalClick = lab.handleView.click
    lab.handleView.click = { clicks += 1 }
    handle.expect(lab.handleView.acceptsFirstMouse(for: click), "Handle must accept the first inactive click")
    if lab.handleView.acceptsFirstMouse(for: click) { lab.handleView.mouseDown(with: click) }
    handle.expect(clicks == 1, "Simulated first-click routing must call the handle callback once")
    handle.expect(app.keyWindow === keyWindow, "Simulated handle click must not change the key window")
    lab.handleView.click = originalClick

    let layout = TestContext(name: "smoke explicit CardView stage")
    lab.card.setFrameSize(NSSize(width: 248, height: 132))
    lab.card.stage = .peek; lab.card.layoutSubtreeIfNeeded()
    layout.expect(lab.card.open.isHidden, "Peek controls must stay hidden even at full-card bounds")
    lab.card.setFrameSize(NSSize(width: 34, height: 34))
    lab.card.stage = .card; lab.card.layoutSubtreeIfNeeded()
    layout.expect(!lab.card.open.isHidden, "Full-stage controls must not depend on intermediate animation bounds")

    for mode in [Mode.dwell, .tab, .drag, .status] {
        let test = TestContext(name: "smoke mode=\(mode.rawValue) anchored retention")
        lab.sides.selectItem(at: startup.require(Side.allCases.firstIndex(of: .right), "Right side missing"))
        select(mode)
        lab.showFallback()
        test.expect(lab.phase == .card && lab.explicitAnchor != nil, "Fallback action must create an explicitly anchored card")
        lab.dismiss(block: false)
        let screen = test.require(lab.screen, "Retention test needs a display")
        let anchor = NSPoint(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 120)
        lab.explicitAnchor = anchor
        lab.show(.card)
        lab.reveal.setFrame(lab.cardFrame, display: true)
        lab.hoveringStatus = true; lab.hoveringHandle = true
        let source = test.require(lab.sourceFrame(), "Source frame missing")
        let remote = NSPoint(x: source.midX, y: source.midY)
        let local = NSPoint(x: lab.reveal.frame.midX, y: lab.reveal.frame.midY)
        let padding = NSPoint(x: lab.reveal.frame.minX - 30, y: local.y)
        test.expect(lab.retainsCard(at: local) && lab.retainsCard(at: padding), "Explicit fallback must retain the card and its local padding")
        test.expect(!lab.reveal.frame.insetBy(dx: -45, dy: -45).contains(remote), "Retention fixture needs a remote source")
        test.expect(!lab.retainsCard(at: remote), "Remote source/hover must not retain an explicitly anchored card")
        let gap = NSPoint(x: (remote.x + local.x) / 2, y: (remote.y + local.y) / 2)
        test.expect(!lab.retainsCard(at: gap), "Far-away source corridor must not retain the fallback card")
        lab.explicitAnchor = nil
        test.expect(lab.retainsCard(at: remote), "Non-anchored source corridor must remain available")
        lab.dismiss(block: false)
    }

    let held = TestContext(name: "smoke mode=Held glance")
    select(.held)
    lab.glance(true)
    held.expect(lab.phase == .card, "Held press must reveal the card")
    lab.glance(false)
    held.expect(lab.phase == .idle, "Held release must dismiss")

    for mode in [Mode.dwell, .tab] {
        for marker in [NSControl.StateValue.on, .off] {
            for pause in [NSControl.StateValue.off, .on] {
                let test = TestContext(name: "smoke mode=\(mode.rawValue) workspace marker=\(marker.rawValue) pause=\(pause.rawValue)")
                lab.marker.state = marker; lab.pause.state = pause
                select(mode)
                post(NSWorkspace.activeSpaceDidChangeNotification)
                let guideExpected = marker == .on && pause == .off
                let handleExpected = mode == .tab && pause == .off
                test.expect(lab.guide.isVisible == guideExpected, "Space change must restore the eligible guide")
                test.expect(lab.handle.isVisible == handleExpected, "Space change must restore only eligible handles")
                lab.show(.card)
                post(NSWorkspace.willSleepNotification)
                test.expect(lab.sleeping && lab.phase == .idle && !lab.guide.isVisible && !lab.handle.isVisible, "Sleep must cancel reveal and hide guide/handle")
                post(NSWorkspace.activeSpaceDidChangeNotification)
                lab.pointerShortcut(); lab.revealNearPointer(); lab.show(.card); lab.tick()
                test.expect(lab.phase == .idle && !lab.guide.isVisible && !lab.handle.isVisible, "Space/polling/explicit reveal must not resume while sleeping")
                post(NSWorkspace.didWakeNotification)
                test.expect(!lab.sleeping && lab.guide.isVisible == guideExpected, "Wake must restore guide according to marker/pause")
                test.expect(lab.handle.isVisible == handleExpected, "Wake must restore only eligible handles")
            }
        }
    }
    lab.marker.state = .on; lab.pause.state = .off
    for mode in [Mode.held, .pointer, .doubleShift] {
        let test = TestContext(name: "smoke mode=\(mode.rawValue) sleeping shortcuts")
        select(mode)
        lab.revealNearPointer()
        post(NSWorkspace.willSleepNotification)
        post(NSWorkspace.activeSpaceDidChangeNotification)
        lab.layoutChanged()
        lab.glance(true); lab.pointerShortcut(); lab.showFallback()
        lab.detectShift(20, flags: .shift); lab.detectShift(20.05, flags: [])
        lab.detectShift(20.1, flags: .shift); lab.detectShift(20.15, flags: [])
        lab.tick()
        test.expect(lab.sleeping && !lab.held && lab.phase == .idle && !lab.reveal.isVisible,
                    "Sleeping shortcuts/fallbacks must not resume a card after Space/display notifications")
        post(NSWorkspace.didWakeNotification)
        test.expect(lab.triggersAvailable && lab.phase == .idle && !lab.held, "Wake must restore availability without replaying sleeping input")
    }

    let unavailable = TestContext(name: "smoke injected empty display snapshot")
    lab.displayProvider = { [] }
    lab.layoutChanged()
    unavailable.expect(lab.screen == nil && lab.edge == nil && lab.destination() == nil && lab.sourceFrame() == nil, "Empty snapshot must yield absent geometry, not a fabricated rectangle")
    unavailable.expect(lab.displays.numberOfItems == 0 && !lab.displays.isEnabled, "Empty snapshot must clear and disable the display picker")
    for mode in Mode.allCases {
        let test = TestContext(name: "smoke no displays mode=\(mode.rawValue)")
        select(mode)
        lab.show(.peek); lab.show(.card); lab.showFallback(); lab.glance(true); lab.pointerShortcut(); lab.tick()
        test.expect(!lab.geometryEligible(.zero) && !lab.sourceEligible(.zero), "No display must disable geometry and sources")
        test.expect(lab.phase == .idle && !lab.reveal.isVisible && !lab.guide.isVisible && !lab.handle.isVisible, "No display must suspend all reveal panels")
    }
    post(NSWorkspace.willSleepNotification); post(NSWorkspace.didWakeNotification)
    unavailable.expect(!lab.guide.isVisible && !lab.triggersAvailable, "Wake without displays must remain suspended")
    lab.displayProvider = originalProvider
    lab.layoutChanged()
    select(.tab)
    unavailable.expect(lab.screen != nil && lab.triggersAvailable && lab.guide.isVisible && lab.handle.isVisible, "Returning displays must restore geometry, triggers, guide, and handle")

    for cancellation in ["dismiss", "pause", "mode change", "Space change", "sleep/wake"] {
        let test = TestContext(name: "smoke mode=Double Shift reset on \(cancellation)")
        select(.doubleShift)
        lab.shiftTaps.reset(flags: [])
        lab.detectShift(10, flags: .shift); lab.detectShift(10.05, flags: [])
        if cancellation == "dismiss" { lab.dismiss(block: true) }
        else if cancellation == "pause" {
            lab.pause.state = .on; lab.changed()
            lab.detectShift(10.1, flags: .shift)
            lab.pause.state = .off; lab.changed()
        } else if cancellation == "mode change" { select(.dwell); select(.doubleShift) }
        else if cancellation == "Space change" { post(NSWorkspace.activeSpaceDidChangeNotification) }
        else { post(NSWorkspace.willSleepNotification); post(NSWorkspace.didWakeNotification) }
        lab.detectShift(10.15, flags: .shift); lab.detectShift(10.2, flags: [])
        test.expect(lab.phase == .idle, "Cancellation must discard the pending Shift tap")
        lab.detectShift(10.25, flags: .shift); lab.detectShift(10.3, flags: [])
        test.expect(lab.phase == .card, "Two fresh clean taps must work after cancellation")
        lab.dismiss(block: false)
    }

    print("PASS: AppKit startup, 12 mode render/reset cycles, click-catching cards, stationary/jitter rejection, deliberate motion arming, simulated card clicks, unchanged key window during reveal, simulated held press/release")
    app.terminate(nil)
}

if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Lab()
    app.delegate = delegate
    if CommandLine.arguments.contains("--smoke-test") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { smokeTest(delegate, app: app) }
    }
    app.run()
}
