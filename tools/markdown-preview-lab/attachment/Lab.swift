import AppKit
import ApplicationServices

struct EventRecord: Codable {
    let route: String
    let object: String
    let result: String
}

final class Journal {
    var events: [EventRecord] = []
    func record(_ route: String, _ object: String, _ result: String) {
        events.append(EventRecord(route: route, object: object, result: result))
    }
}

final class Item {
    let id: String
    let title: String
    let sealed: Bool
    let cell: NSTextAttachmentCell
    var index = 0
    var loads = 0
    init(_ id: String, _ title: String, sealed: Bool = false, cell: NSTextAttachmentCell) {
        self.id = id; self.title = title; self.sealed = sealed; self.cell = cell
    }
}

class PaintedCell: NSTextAttachmentCell {
    let faceTitle: String
    var drawnFrame: NSRect?
    var drawnIndex: Int?
    init(_ title: String) {
        self.faceTitle = title
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError("No archive input") }
    override func cellSize() -> NSSize { NSSize(width: 218, height: 38) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -7) }
    override func accessibilityLabel() -> String? { faceTitle }
    override func draw(withFrame frame: NSRect, in view: NSView?, characterIndex index: Int,
                       layoutManager: NSLayoutManager) {
        drawnFrame = frame; drawnIndex = index
        draw(withFrame: frame, in: view)
    }
    override func draw(withFrame frame: NSRect, in view: NSView?) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: frame.insetBy(dx: 1, dy: 1)).stroke()
        let selected = (view as? NSTextView)?.selectedRange().contains(drawnIndex ?? -1) == true
        let text = (selected ? "▣ " : "□ ") + faceTitle
        (text as NSString).draw(in: frame.insetBy(dx: 7, dy: 9), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
    }
}

final class CellPressProbe: PaintedCell {
    var presses = 0
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        presses += 1
        onPress?()
        return true
    }
}

final class LoadElement: NSAccessibilityElement {
    weak var owner: LabTextView?
    let item: Item
    init(owner: LabTextView, item: Item) {
        self.owner = owner; self.item = item
        super.init()
        setAccessibilityParent(owner)
        setAccessibilityIdentifier("action-" + owner.labID + "-" + item.id)
        setAccessibilityRole(item.sealed ? .staticText : .button)
        if !item.sealed {
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Load image (simulated)", handler: { [weak self] in
                self?.accessibilityPerformPress() ?? false
            })])
        }
    }
    override func accessibilityLabel() -> String? {
        guard let owner else { return item.title }
        if !owner.selectedPage { return "Promote page before action: " + item.title }
        if item.sealed { return "Sealed stand-in: " + item.title }
        return "Load image (simulated): " + item.title + "; count \(item.loads)"
    }
    override func accessibilityHelp() -> String? {
        "Research only. First press promotes a quiet page; a separate press simulates load. No image fetch."
    }
    override func accessibilityFrame() -> NSRect {
        guard let owner, let window = owner.window else { return .zero }
        return window.convertToScreen(owner.convert(owner.itemFrame(item), to: nil))
    }
    override func accessibilityPerformPress() -> Bool {
        guard !item.sealed, let owner else { return false }
        return owner.activate(item, route: "AXPress/custom action")
    }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == NSSelectorFromString("accessibilityPerformPress") { return !item.sealed }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}

final class LabTextView: NSTextView, NSTextViewDelegate {
    let labID: String
    let custom: Bool
    let journal: Journal
    let storage: NSTextStorage
    var items: [Item] = []
    var elements: [LoadElement] = []
    var selectedPage: Bool { didSet {
        isSelectable = selectedPage
        setAccessibilityLabel(labID + (selectedPage ? ", selected page" : ", quiet page"))
    } }
    var onChange: (() -> Void)?
    var linkIntents = 0

    init(id: String, frame: NSRect, custom: Bool, selected: Bool, journal: Journal) {
        labID = id; self.custom = custom; selectedPage = selected; self.journal = journal
        storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: 2000))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        isEditable = false; isSelectable = selected; isRichText = true
        isVerticallyResizable = false; isHorizontallyResizable = false
        textContainerInset = NSSize(width: 10, height: 10)
        isAutomaticLinkDetectionEnabled = false
        importsGraphics = false
        delegate = self
        setAccessibilityIdentifier(id)
        setAccessibilityLabel(id + (selected ? ", selected page" : ", quiet page"))
        buildFixture()
        elements = custom ? items.map { LoadElement(owner: self, item: $0) } : []
    }
    required init?(coder: NSCoder) { fatalError("No archive input") }
    override var acceptsFirstResponder: Bool { selectedPage }
    override func becomeFirstResponder() -> Bool { selectedPage && super.becomeFirstResponder() }

    func buildFixture() {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        func text(_ value: String, _ attrs: [NSAttributedString.Key: Any] = [:]) {
            storage.append(NSAttributedString(string: value, attributes: base.merging(attrs) { _, rhs in rhs }))
        }
        func object(_ id: String, _ title: String, sealed: Bool = false,
                    attrs: [NSAttributedString.Key: Any] = [:], stock: Bool = false, cellPress: Bool = false) {
            let localImage = stock ? NSImage(size: NSSize(width: 218, height: 38), flipped: false) { rect in
                NSColor.controlBackgroundColor.setFill(); rect.fill()
                ("Stock local image" as NSString).draw(at: NSPoint(x: 7, y: 12), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
                return true
            } : nil
            let cell: NSTextAttachmentCell = stock ? NSTextAttachmentCell(imageCell: localImage)
                : cellPress ? CellPressProbe(title) : PaintedCell(title)
            let item = Item(id, title, sealed: sealed, cell: cell)
            if let probe = cell as? CellPressProbe {
                probe.onPress = { [weak self, weak item] in
                    guard let self, let item else { return }
                    self.activate(item, route: "cell-level AXPress")
                }
            }
            item.index = storage.length
            let attachment = NSTextAttachment()
            attachment.attachmentCell = cell
            let run = NSMutableAttributedString(attachment: attachment)
            run.addAttributes(base.merging(attrs) { _, rhs in rhs }, range: NSRange(location: 0, length: 1))
            storage.append(run); items.append(item)
        }
        text("Plain image attachment\n")
        object("plain", "Mountain image")
        text("\n\nImage inside link\n")
        object("linked", "Linked image", attrs: [.link: URL(string: "https://example.invalid/target")!])
        text("\nOuter link text\n", [.link: URL(string: "https://example.invalid/target")!])
        text("\nNSTextTable: image + sealed\n")
        let table = NSTextTable(); table.numberOfColumns = 1
        table.setContentWidth(100, type: .percentageValueType)
        for row in 0..<2 {
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: 0, columnSpan: 1)
            block.setWidth(4, type: .absoluteValueType, for: .padding)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(.separatorColor)
            let style = NSMutableParagraphStyle(); style.textBlocks = [block]
            object(row == 0 ? "table-image" : "table-sealed", row == 0 ? "Table image" : "Table sealed", sealed: row == 1,
                   attrs: [.paragraphStyle: style])
            text("\n", [.paragraphStyle: style])
        }
        text("\nImage alt: before ")
        object("alt-sealed", "Alt sealed object", sealed: true)
        text(" after\n")
        object("alt-image", "Image with object in alt")
        text("\n\nSealed outside image\n")
        object("sealed", "Named sealed, small", sealed: true)
        text("\n\nStock cell control\n")
        object("stock", "Stock NSTextAttachmentCell", stock: true)
        text("\nCell-level AXPress override\n")
        object("cell-press", "Cell press probe", cellPress: true)
        text("\n")
    }

    func itemFrame(_ item: Item) -> NSRect {
        layoutManager!.ensureLayout(for: textContainer!)
        let glyphs = layoutManager!.glyphRange(forCharacterRange: NSRange(location: item.index, length: 1), actualCharacterRange: nil)
        return layoutManager!.boundingRect(forGlyphRange: glyphs, in: textContainer!).offsetBy(
            dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }
    func item(at point: NSPoint) -> Item? { items.first { itemFrame($0).contains(point) } }
    func select(_ item: Item, route: String) {
        setSelectedRange(NSRange(location: item.index, length: 1))
        needsDisplay = true
        journal.record(route, item.id, "selected; no load")
    }
    @discardableResult
    func activate(_ item: Item, route: String) -> Bool {
        guard !item.sealed else {
            journal.record(route, item.id, "sealed; refused")
            return false
        }
        if !selectedPage {
            selectedPage = true
            journal.record(route, item.id, "promoted only")
        } else {
            select(item, route: route)
            item.loads += 1
            journal.record(route, item.id, "simulated load \(item.loads)")
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
        onChange?()
        return true
    }
    override func mouseDown(with event: NSEvent) {
        if !selectedPage {
            selectedPage = true
            journal.record("mouse", labID, "promoted only")
            onChange?()
            return
        }
        if custom, let item = item(at: convert(event.locationInWindow, from: nil)) {
            window?.makeFirstResponder(self)
            select(item, route: event.modifierFlags.contains(.command) ? "cmd-click attachment" : "plain click attachment")
            onChange?()
            return
        }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if custom, selectedPage, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           event.keyCode == 49 || event.keyCode == 36,
           let item = items.first(where: { selectedRange() == NSRange(location: $0.index, length: 1) }) {
            _ = activate(item, route: event.keyCode == 49 ? "Space" : "Return")
            return
        }
        super.keyDown(with: event)
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if !selectedPage {
            selectedPage = true
            journal.record("link delegate", labID, "promoted only")
            onChange?()
            return true
        }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            linkIntents += 1
            journal.record("cmd-link", labID, "simulated link intent only")
        } else {
            setSelectedRange(NSRange(location: charIndex, length: 0))
            journal.record("plain-link", labID, "caret only")
        }
        return true
    }
    func textView(_ textView: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        journal.record("native cell click delegate", labID, "index \(charIndex); no load")
    }
    override func accessibilityChildren() -> [Any]? {
        let native = super.accessibilityChildren() ?? []
        return custom ? native + elements : (native.isEmpty ? nil : native)
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        if custom, let match = elements.first(where: { $0.accessibilityFrame().contains(point) }) { return match }
        return super.accessibilityHitTest(point)
    }
}

struct Check: Codable { let name: String; let passed: Bool; let observed: String }
struct NativeNode: Codable {
    let source: String
    let role: String
    let label: String
    let element: Bool
    let pressSelectorAllowed: Bool
    let frame: String
    let runtimeClass: String
    let legacyActions: [String]
    let modernProtocol: Bool
    let customActions: [String]
}
struct Report: Codable {
    let os: String
    let pid: Int32
    let voiceOverEnabled: Bool
    let axTrustedWithoutPrompt: Bool
    let checks: [Check]
    let native: [NativeNode]
    let events: [EventRecord]
}

final class Lab: NSObject, NSApplicationDelegate {
    let output: URL
    let selfTest: Bool
    let duration: Double
    let journal = Journal()
    var window: NSWindow!
    var views: [LabTextView] = []
    var checks: [Check] = []
    var status: NSTextField!
    var exitCode: Int32 = 0
    init(output: URL, selfTest: Bool, duration: Double) {
        self.output = output; self.selfTest = selfTest; self.duration = duration
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 60, width: 1060, height: 860),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "TextKit1 Attachment AX Lab — simulated actions only"
        let content = window.contentView!
        let intro = NSTextField(wrappingLabelWithString: "Native cells | Custom selected page | Custom quiet page. Plain click selects; Shift-Right selects by keyboard; Space/Return simulates load. Quiet page: first click/AX press promotes, separate action loads. No URL is fetched or opened. Auto-close in \(Int(duration)) seconds.")
        intro.frame = NSRect(x: 15, y: 799, width: 1030, height: 50); content.addSubview(intro)
        for (n, config) in [("baseline", false, true), ("custom-selected", true, true), ("custom-quiet", true, false)].enumerated() {
            let label = NSTextField(labelWithString: config.0)
            label.frame = NSRect(x: 15 + n * 350, y: 770, width: 330, height: 22); content.addSubview(label)
            let view = LabTextView(id: config.0, frame: NSRect(x: 15 + n * 350, y: 70, width: 330, height: 695),
                                   custom: config.1, selected: config.2, journal: journal)
            content.addSubview(view); views.append(view)
            view.onChange = { [weak self] in self?.updateStatus() }
        }
        status = NSTextField(wrappingLabelWithString: "Ready. No simulated loads yet.")
        status.frame = NSRect(x: 15, y: 10, width: 1030, height: 50); content.addSubview(status)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(views[1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            views.forEach { $0.layoutManager?.ensureLayout(for: $0.textContainer!); $0.display() }
            if selfTest { runTests() }
            writeReport()
            try? FileManager.default.copyItem(at: output.appendingPathComponent("app-report.json"), to: output.appendingPathComponent("app-ready-report.json"))
            if let bitmap = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds) {
                window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("fixture.png"))
            }
            try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: output.appendingPathComponent("ready.pid"), atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [self] in
            writeReport()
            NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { writeReport() }
    func updateStatus() {
        status.stringValue = journal.events.suffix(3).map { "\($0.route): \($0.object) → \($0.result)" }.joined(separator: " | ")
    }
    func check(_ name: String, _ condition: Bool, _ observed: String) {
        checks.append(Check(name: name, passed: condition, observed: observed))
        if !condition { exitCode = 1 }
    }
    func click(_ view: LabTextView, _ item: Item, flags: NSEvent.ModifierFlags = []) {
        let rect = view.itemFrame(item)
        let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags,
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        if !view.custom {
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags,
                timestamp: event.timestamp + 0.01, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            NSApp.postEvent(up, atStart: true)
        }
        view.mouseDown(with: event)
    }
    func key(_ view: LabTextView, code: UInt16, text: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }
    func runTests() {
        let baseline = views[0], selected = views[1], quiet = views[2]
        for view in views {
            check("\(view.labID): explicit TK1 graph", view.layoutManager === view.storage.layoutManagers.first && view.textContainer?.layoutManager === view.layoutManager,
                  "\(String(describing: view.layoutManager)); storage managers=\(view.storage.layoutManagers.count)")
            for item in view.items {
                let rect = view.itemFrame(item)
                check("\(view.labID)/\(item.id): laid out", rect.width > 0 && rect.height > 0 && rect.maxY < view.bounds.height,
                      NSStringFromRect(rect))
                if let cell = item.cell as? PaintedCell, let drawn = cell.drawnFrame {
                    check("\(view.labID)/\(item.id): glyph and drawing geometry agree", abs(rect.minX - drawn.minX) < 1 && abs(rect.minY - drawn.minY) < 1 && rect.size == drawn.size,
                          "glyph=\(NSStringFromRect(rect)); drawn=\(NSStringFromRect(drawn))")
                }
            }
        }
        for item in [baseline.items[0], baseline.items.first { $0.id == "stock" }!] {
            baseline.setSelectedRange(NSRange(location: 0, length: 0))
            click(baseline, item)
            check("native baseline click \(item.id) does not load", item.loads == 0,
                  "range=\(baseline.selectedRange()), loads=\(item.loads); actual mouseDown with queued mouseUp")
        }
        baseline.setSelectedRange(NSRange(location: baseline.items[0].index, length: 0))
        baseline.moveRightAndModifySelection(nil)
        check("baseline native Shift-Right selects object", baseline.selectedRange() == NSRange(location: baseline.items[0].index, length: 1), "\(baseline.selectedRange())")
        let before = selected.storage.string
        let originalElement = selected.elements[0]
        for item in selected.items {
            let loads = item.loads
            click(selected, item)
            check("plain click selects \(item.id)", selected.selectedRange() == NSRange(location: item.index, length: 1) && item.loads == loads,
                  "range=\(selected.selectedRange()), loads=\(item.loads)")
            click(selected, item, flags: .command)
            check("cmd attachment click does not follow outer link \(item.id)", selected.linkIntents == 0 && item.loads == loads,
                  "link intents=\(selected.linkIntents), loads=\(item.loads)")
        }
        let plain = selected.items[0]
        selected.setSelectedRange(NSRange(location: plain.index, length: 0))
        selected.moveRightAndModifySelection(nil)
        check("native Shift-Right selects one attachment", selected.selectedRange() == NSRange(location: plain.index, length: 1), "\(selected.selectedRange())")
        key(selected, code: 49, text: " ")
        check("Space after keyboard selection simulates one load", plain.loads == 1, "loads=\(plain.loads)")
        key(selected, code: 36, text: "\r")
        check("Return after selection simulates one more load", plain.loads == 2, "loads=\(plain.loads)")
        selected.setSelectedRange(NSRange(location: plain.index, length: 0))
        selected.moveRight(nil)
        check("native Right traverses attachment without load", selected.selectedRange() == NSRange(location: plain.index + 1, length: 0) && plain.loads == 2,
              "range=\(selected.selectedRange()), loads=\(plain.loads)")
        let sealed = selected.items.first { $0.id == "alt-sealed" }!
        selected.select(sealed, route: "test")
        key(selected, code: 49, text: " ")
        check("sealed inside alt refuses keyboard load", sealed.loads == 0, "loads=\(sealed.loads)")
        for element in selected.elements {
            let count = element.item.loads
            let result = element.accessibilityPerformPress()
            check("direct custom press \(element.item.id)", element.item.sealed ? (!result && element.item.loads == count) : (result && element.item.loads == count + 1),
                  "result=\(result), loads=\(element.item.loads)")
            check("custom geometry \(element.item.id)", !element.accessibilityFrame().isEmpty, NSStringFromRect(element.accessibilityFrame()))
            let hit = selected.accessibilityHitTest(NSPoint(x: element.accessibilityFrame().midX, y: element.accessibilityFrame().midY))
            check("custom hit test \(element.item.id)", (hit as AnyObject?) === element, "same instance=\((hit as AnyObject?) === element)")
        }
        let q = quiet.items[0]
        let initialRange = quiet.selectedRange()
        click(quiet, q)
        check("quiet click promotes only", quiet.selectedPage && q.loads == 0 && quiet.selectedRange() == initialRange,
              "selected=\(quiet.selectedPage), loads=\(q.loads), range=\(quiet.selectedRange())")
        click(quiet, q)
        check("second click selects only", q.loads == 0 && quiet.selectedRange() == NSRange(location: q.index, length: 1), "loads=\(q.loads)")
        key(quiet, code: 49, text: " ")
        check("separate keyboard action after promotion loads", q.loads == 1, "loads=\(q.loads)")
        quiet.selectedPage = false; q.loads = 0
        let qe = quiet.elements[0]
        _ = qe.accessibilityPerformPress()
        check("quiet AX first press promotes only", quiet.selectedPage && q.loads == 0, "selected=\(quiet.selectedPage), loads=\(q.loads)")
        _ = qe.accessibilityPerformPress()
        check("quiet AX second press loads", q.loads == 1, "loads=\(q.loads)")
        let tableImage = selected.items.first { $0.id == "table-image" }!
        let tableSealed = selected.items.first { $0.id == "table-sealed" }!
        let style = selected.storage.attribute(.paragraphStyle, at: tableImage.index, effectiveRange: nil) as? NSParagraphStyle
        check("image uses actual NSTextTableBlock", style?.textBlocks.first is NSTextTableBlock, "blocks=\(style?.textBlocks.count ?? 0)")
        check("table sealed follows table image", tableImage.index < tableSealed.index, "\(tableImage.index) < \(tableSealed.index)")
        check("alt stand-in remains separate before image", sealed.index < selected.items.first { $0.id == "alt-image" }!.index && selected.elements.contains { $0.item === sealed }, "sealed index=\(sealed.index)")
        check("simulated load does not rewrite text", selected.storage.string == before, "UTF16 length=\(selected.storage.length)")
        let linked = selected.items.first { $0.id == "linked" }!
        check("linked image fixture has outer link attribute", selected.storage.attribute(.link, at: linked.index, effectiveRange: nil) != nil, "link present")
        let cellProbe = baseline.items.last!.cell as! CellPressProbe
        check("stock cell default press returns false", !baseline.items.first { $0.id == "stock" }!.cell.accessibilityPerformPress(), "in-process default press result")
        check("label-only cell default press returns false", !baseline.items[0].cell.accessibilityPerformPress(), "in-process default press result")
        check("direct cell-level press override callable", cellProbe.accessibilityPerformPress() && cellProbe.presses == 1, "presses=\(cellProbe.presses); not external AX evidence")
        let children = baseline.accessibilityChildren() ?? []
        let actionNames = NSSelectorFromString("accessibilityActionNames")
        let performAction = NSSelectorFromString("accessibilityPerformAction:")
        if children.count >= baseline.items.count, let proxy = children[8] as? NSObject {
            let actions = proxy.perform(actionNames)?.takeUnretainedValue() as? [String] ?? []
            check("native cell proxy advertises overridden AXPress", actions.contains("AXPress"), "actions=\(actions), class=\(NSStringFromClass(type(of: proxy)))")
            if actions.contains("AXPress") { _ = proxy.perform(performAction, with: "AXPress") }
            check("native cell proxy AXPress reaches cell override", cellProbe.presses == 2, "presses=\(cellProbe.presses)")
        } else {
            check("native cell proxy present", false, "children count=\(children.count)")
        }
        let action = selected.elements[0].accessibilityCustomActions()?.first
        let priorLoads = plain.loads
        let customResult = action?.handler?() ?? false
        check("named NSAccessibilityCustomAction handler executes", customResult && plain.loads == priorLoads + 1,
              "name=\(action?.name ?? "nil"), result=\(customResult), loads=\(plain.loads)")
        quiet.selectedPage = false
        _ = quiet.textView(quiet, clickedOnLink: URL(string: "https://example.invalid")!, at: quiet.items[1].index)
        check("quiet link delegate promotes without load", quiet.selectedPage && quiet.linkIntents == 0 && q.loads == 1,
              "selected=\(quiet.selectedPage), link intents=\(quiet.linkIntents), loads=\(q.loads)")
        quiet.selectedPage = false
        let quietProbe = quiet.items.last!.cell as! CellPressProbe
        _ = quietProbe.accessibilityPerformPress()
        check("cell-level action on quiet page promotes only", quiet.selectedPage && quiet.items.last!.loads == 0,
              "selected=\(quiet.selectedPage), loads=\(quiet.items.last!.loads)")
        _ = quietProbe.accessibilityPerformPress()
        check("cell-level separate action after promotion loads", quiet.items.last!.loads == 1, "loads=\(quiet.items.last!.loads)")
        quiet.selectedPage = false
        for view in views { for item in view.items { item.loads = 0 }; view.setSelectedRange(NSRange(location: 0, length: 0)); view.display() }
        check("custom element identity stable across selection", selected.elements[0] === originalElement, "same instance after all selection/action mutations; external focus not tested")
        journal.record("self-test", "complete", "external phase begins; loads reset, quiet page unselected")
        updateStatus()
    }
    func nativeSnapshot() -> [NativeNode] {
        var result: [NativeNode] = []
        func legacy(_ object: NSObject, _ key: String) -> Any? {
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector, with: key)?.takeUnretainedValue()
        }
        func add(_ object: NSObject, _ source: String) {
            let modern = object as? NSAccessibilityProtocol
            let actionSelector = NSSelectorFromString("accessibilityActionNames")
            let actions = object.responds(to: actionSelector)
                ? object.perform(actionSelector)?.takeUnretainedValue() as? [String] ?? [] : []
            result.append(NativeNode(source: source,
                role: modern?.accessibilityRole()?.rawValue ?? legacy(object, "AXRole") as? String ?? "nil",
                label: modern?.accessibilityLabel() ?? legacy(object, "AXDescription") as? String
                    ?? legacy(object, "AXTitle") as? String ?? "nil",
                element: modern?.isAccessibilityElement() ?? true,
                pressSelectorAllowed: modern?.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress")) ?? false,
                frame: modern.map { NSStringFromRect($0.accessibilityFrame()) }
                    ?? "position=\(String(describing: legacy(object, "AXPosition"))), size=\(String(describing: legacy(object, "AXSize")))",
                runtimeClass: NSStringFromClass(type(of: object)), legacyActions: actions, modernProtocol: modern != nil,
                                customActions: modern?.accessibilityCustomActions()?.map(\.name) ?? []))
        }
        for view in views {
            add(view, view.labID)
            for item in view.items { add(item.cell, view.labID + "/cell/" + item.id) }
            for element in view.elements { add(element, view.labID + "/supplement/" + element.item.id) }
            for (i, child) in (view.accessibilityChildren() ?? []).enumerated() {
                if let object = child as? NSObject { add(object, view.labID + "/child/\(i)") }
            }
        }
        return result
    }
    func writeReport() {
        let report = Report(os: ProcessInfo.processInfo.operatingSystemVersionString,
                            pid: ProcessInfo.processInfo.processIdentifier,
                            voiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled,
                            axTrustedWithoutPrompt: AXIsProcessTrusted(), checks: checks,
                            native: nativeSnapshot(), events: journal.events)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(report).write(to: output.appendingPathComponent("app-report.json")) }
        catch { fputs("report write failed: \(error)\n", stderr); exitCode = 1 }
    }
}

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let output = URL(fileURLWithPath: option("--output") ?? FileManager.default.currentDirectoryPath)
let duration = min(900, max(3, Double(option("--duration") ?? "300") ?? 300))
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let lab = Lab(output: output, selfTest: arguments.contains("--self-test"), duration: duration)
app.delegate = lab
app.run()
exit(lab.exitCode)
