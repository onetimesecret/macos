import AppKit
import Combine
import Darwin
import os

/// A rendered page whose AppKit copy, link, reader and drag routes follow Law 0001's preview rows.
@MainActor
final class MarkdownPreviewView: AskingTextView {
    /// The page this preview shows and asks.
    let page: UInt64
    private weak var coordinator: InkEditorView.Coordinator?
    private let imageLoad: @MainActor (URL) async throws -> NSImage
    private let previewStorage: NSTextStorage
    private var seeded: PageModel.QuietRendering?
    private var seededDialect: PreviewDialect?
    private let links = PreviewLinks()
    private var imageControlsReady = false
    private var imageOwnership: AnyCancellable?
    private var imageWindowLifecycle: AnyCancellable?
    private var imageWindowIsClosing = false
    private(set) lazy var imageControls = PreviewImageControls(preview: self, load: imageLoad)
    var onImageLayoutChanged: (() -> Void)?

    var isImagePresentationActive: Bool {
        guard isSelectedPage, window != nil, !imageWindowIsClosing, let coordinator,
              coordinator.model.owner == coordinator.surface,
              coordinator.model.selectedPageID == page,
              coordinator.model.tabs.contains(where: { $0.pageID == page }) else { return false }
        return true
    }

    func authorizeImageLoad() -> Bool { isImagePresentationActive && mayReadOut }

    /// A click on a preview of a page the roll has not selected promotes it (ADR-0030).
    var onPromote: (() -> Void)?

    /// Only the selected page's preview is selectable and may take the keys (ADR-0030).
    var isSelectedPage = false {
        didSet {
            isSelectable = isSelectedPage
            if imageControlsReady, oldValue != isSelectedPage { imageControls.discard() }
        }
    }

    /// Drag sessions this view began; the tests pin it at none.
    private(set) var draggingSessionsBegun = 0

    init(page: UInt64, coordinator: InkEditorView.Coordinator?) {
        self.page = page
        self.coordinator = coordinator
        if let coordinator { imageLoad = coordinator.model.previewImageLoad }
        else { imageLoad = { _ in throw PreviewImageLoadError.invalidURL } }
        let storage = NSTextStorage()
        previewStorage = storage
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textContainerInset = NSSize(width: 12, height: InkEditorView.Coordinator.topInset)
        font = InkStyle.baseFont
        textColor = .labelColor
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        isAutomaticLinkDetectionEnabled = false
        TextOffers.offerUngatedReaders(false, on: self)
        links.preview = self
        delegate = links
        imageControlsReady = true
        imageOwnership = coordinator?.model.$owner.dropFirst().sink { [weak self] owner in
            guard let self, owner != self.coordinator?.surface else { return }
            Task { @MainActor [weak self] in self?.imageControls.discard() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Markdown previews are not unarchived")
    }

    // MARK: Focus and the click (ADR-0030)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { isSelectedPage }

    override func becomeFirstResponder() -> Bool {
        isSelectedPage && super.becomeFirstResponder()
    }

    /// On the selected page a click selects; on any other it promotes the page.
    override func mouseDown(with event: NSEvent) {
        guard isSelectedPage else { return promote() }
        super.mouseDown(with: event)
    }

    /// The click itself, apart from the event, as `QuietPageView.clicked(at:)` is.
    func promote() {
        onPromote?()
    }

    // MARK: AppKit's readers of the text (Law 0001, expiry row and the preview's rows)

    /// The page is asked, as the editor asks it; with no page to ask, nothing leaves.
    override var mayReadOut: Bool {
        coordinator?.model.givesOut(sheet: page) ?? false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        aimLinkItems(in: menu, at: convert(event.locationInWindow, from: nil))
        return menu
    }

    /// A ⌘-click and Open Link go to the coordinator's `openLink`, which asks this view first.
    override func openAimedLink(_ link: Any) {
        coordinator?.openLink(link, from: self)
    }

    override var linkBoard: NSPasteboard? { coordinator?.model.ambientPasteboard }

    /// The selection as the core composes it: the rendered text between the objects as
    /// the ink runs and each object by chip id, in rendered order (Law 0001, copy row).
    func shownSelection() -> [[CompanionClient.ShownRun]] {
        selectedRanges.map(\.rangeValue).filter { $0.length > 0 }.map { range in
            var runs: [CompanionClient.ShownRun] = []
            var ink: [String] = []
            let text = previewStorage.string as NSString
            previewStorage.enumerateAttributes(in: range) { attributes, run, _ in
                guard let chip = attributes[.attachment] as? ChipAttachment else {
                    if attributes[.attachment] == nil, attributes[.previewImagePlaceholder] == nil, run.length > 0 {
                        ink.append(text.substring(with: run))
                    }
                    return
                }
                if !ink.isEmpty { runs.append(.ink(ink.joined())); ink.removeAll(keepingCapacity: true) }
                for _ in 0..<run.length { runs.append(.chip(chip.info.chipId)) }
            }
            if !ink.isEmpty { runs.append(.ink(ink.joined())) }
            return runs
        }
    }

    /// Copy composes through the core, which refuses past the deadline (Law 0001, copy row).
    override func copy(_ sender: Any?) {
        guard let coordinator else { return }
        coordinator.model.copyShownSelection(shownSelection(), sheet: page)
    }

    /// A service takes the public text alone (Law 0001, export row).
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string, SealedFragment.legacyStringType]
    }

    /// No service may write back over a preview.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        guard returnType == nil else { return nil }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// The composition's public text in whichever public type was asked for, never the envelope.
    override func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let fragment = composedForRequester(),
              let item = fragment.pasteboardItem(
                  offering: types.filter { $0 != SealedFragment.pasteboardType })
        else { return false }
        pboard.clearContents()
        return pboard.writeObjects([item])
    }

    override func writeSelection(
        to pboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard type == .string || type == SealedFragment.legacyStringType,
              let fragment = composedForRequester()
        else { return false }
        return pboard.setString(fragment.plainText, forType: .string)
    }

    /// The composition for a service, its refusal told as a copy's is.
    private func composedForRequester() -> SealedFragment? {
        guard let coordinator else { return nil }
        let composition = coordinator.model.composeShownSelection(shownSelection(), sheet: page)
        if let line = PageModel.refusalLine(for: composition, .copy) { coordinator.model.flash(line) }
        guard case .composed(let fragment) = composition else { return nil }
        return fragment
    }

    /// Use Selection for Find hands the text to the finder's board (Law 0001, expiry row).
    override func performFindPanelAction(_ sender: Any?) {
        guard !refusesFinderAction(sender) else { return }
        super.performFindPanelAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard !refusesFinderAction(sender) else { return }
        super.performTextFinderAction(sender)
    }

    private func refusesFinderAction(_ sender: Any?) -> Bool {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? (sender as? NSControl)?.tag
        guard tag == NSTextFinder.Action.setSearchString.rawValue else { return false }
        return !mayReadOut
    }

    // MARK: No drag starts here (Law 0001, plain drag row)

    override func dragSelection(
        with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool
    ) -> Bool {
        false
    }

    override func dragImageForSelection(with event: NSEvent, origin: NSPointPointer?) -> NSImage? {
        nil
    }

    override func beginDraggingSession(
        with items: [NSDraggingItem], event: NSEvent, source: any NSDraggingSource
    ) -> NSDraggingSession {
        draggingSessionsBegun += 1
        return super.beginDraggingSession(with: items, event: event, source: source)
    }

    @discardableResult
    func reseed(with rendering: PageModel.QuietRendering, dialect: PreviewDialect) -> String? {
        if rendering === seeded, dialect == seededDialect { return nil }
        let sameSource = dialect == seededDialect && seeded?.text.isEqual(to: rendering.text) == true
        let reusesImageTemplate = sameSource && !imageControls.buttons.isEmpty
        let previous = seeded == nil || reusesImageTemplate ? nil : previewStorage.string
        seeded = rendering
        seededDialect = dialect
        if reusesImageTemplate { return nil }
        imageControls.seed(Self.render(rendering.text, dialect: dialect), preserveConsent: sameSource)
        needsDisplay = true
        return previous
    }

    override func layout() {
        super.layout()
        if imageControlsReady { imageControls.layout() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        if imageControlsReady, widthChanged { imageControls.resize() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard imageControlsReady else { return }
        imageWindowLifecycle = nil
        imageWindowIsClosing = false
        guard let window else { imageControls.discard(); return }
        let names = [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification]
        imageWindowLifecycle = Publishers.MergeMany(names.map {
            NotificationCenter.default.publisher(for: $0)
        }).sink { [weak self, weak window] notification in
            guard let self, let window, notification.object as? NSWindow === window else { return }
            if notification.name == NSWindow.willCloseNotification {
                self.imageWindowIsClosing = true
                self.imageControls.discard()
            } else if window.isKeyWindow || window.occlusionState.contains(.visible) {
                self.imageWindowIsClosing = false
                self.imageControls.resize()
            }
        }
        imageControls.resize()
    }

    override func accessibilityChildren() -> [Any]? {
        let buttons = imageControlsReady ? imageControls.buttons : []
        var children = (super.accessibilityChildren() ?? []).filter { child in
            !buttons.contains(where: { $0.isHidden && (child as AnyObject) === $0 })
        }
        for button in buttons where !button.isHidden && !children.contains(where: { ($0 as AnyObject) === button }) {
            children.append(button)
        }
        return children
    }

    override nonisolated func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard Thread.isMainThread else { return super.accessibilityHitTest(point) }
        let button: NSButton? = MainActor.assumeIsolated {
            if imageControlsReady, let window {
                let local = convert(window.convertPoint(fromScreen: point), from: nil)
                if let button = imageControls.buttons.first(where: { !$0.isHidden && $0.frame.contains(local) }) { return button }
            }
            return nil
        }
        return button ?? super.accessibilityHitTest(point)
    }

    /// `dialect` selects the pinned parser that reads the page (`MarkdownParser`, plan R1) and how
    /// its raw HTML composes (plan R3).
    static func render(
        _ source: NSAttributedString, dialect: PreviewDialect = .gfm,
        limits: CompositionLimits = CompositionLimits(),
        nativeLimits: NativePreviewLimits = NativePreviewLimits(),
        onDiagnostic: ((PreviewRenderingDiagnostic) -> Void)? = nil
    ) -> NSAttributedString {
        MarkdownPreviewRenderer(
            source: source, dialect: dialect, limits: limits, nativeLimits: nativeLimits,
            onDiagnostic: onDiagnostic
        ).render()
    }
}

extension NSAttributedString.Key {
    /// An image's alt text and objects in a rendered preview, valued by its `PreviewImageDescriptor`.
    static let previewImage = NSAttributedString.Key("CompanionKitPreviewImage")
    static let previewImagePlaceholder = NSAttributedString.Key("CompanionKitPreviewImagePlaceholder")
}

/// An image's ordinal and composed address in one rendering.
struct PreviewImageDescriptor: Hashable {
    let occurrence: Int
    let destination: PreviewAddress
}

struct NativePreviewLimits {
    var maximumTableColumns = 8
    var maximumTableCells = 1_024

    func tableCellTotal(rows: Int, columns: Int, alreadyRendered: Int) -> Int? {
        guard rows >= 0, columns > 0, alreadyRendered >= 0, columns <= maximumTableColumns else { return nil }
        let cells = rows.multipliedReportingOverflow(by: columns)
        guard !cells.overflow else { return nil }
        let total = alreadyRendered.addingReportingOverflow(cells.partialValue)
        guard !total.overflow, total.partialValue <= maximumTableCells else { return nil }
        return total.partialValue
    }
}

enum PreviewRenderingDiagnostic {
    case linkPolicyEvaluation(Int)
    case fontResolution(NSFont, Set<PreviewTrait>)
    case fontSizing(NSFont, CGFloat)
    case fontTraitConversion(NSFont, NSFontTraitMask)
}

/// The preview's delegate: a link opens only by `openAimedLink`, and an object's
/// attachment gives AppKit nothing to drag, open or write (Law 0001, link and attachment rows).
@MainActor
private final class PreviewLinks: NSObject, NSTextViewDelegate {
    weak var preview: MarkdownPreviewView?

    /// A ⌘-click opens through the gate; a plain click selects, as on a page.
    func textView(_ view: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if NSApp?.currentEvent?.modifierFlags.contains(.command) == true {
            preview?.openAimedLink(link)
        }
        return true
    }

    /// A drag that starts on an object starts nothing here.
    func textView(
        _ view: NSTextView, draggedCell cell: any NSTextAttachmentCellProtocol,
        in rect: NSRect, event: NSEvent, at charIndex: Int
    ) {}
}

@MainActor
private final class MarkdownPreviewRenderer {
    private struct Context {
        var indent: CGFloat = 0
        var markerWidth: CGFloat = 28
        var blocks: [NSTextBlock] = []
        var spacing: CGFloat = 8
    }

    /// A composed identity naming no object of this rendering, or one it already showed, a table
    /// with no columns or a row wider than its columns, or a rendering that left an object out.
    private enum RenderFailure: Error {
        case unknownObject, objectShownTwice, tableWithoutColumns, rowWiderThanTable, objectMissing
        case nativeTableLimit
    }

    private enum LinkPolicyResult {
        case accepted(NSURL)
        case refused
    }

    private struct FontKey: Hashable {
        let base: NSFont
        let traits: Set<PreviewTrait>
    }

    private struct FontSizeKey: Hashable {
        let base: NSFont
        let size: CGFloat
    }

    private static let headingScales: [CGFloat] = [1.8, 1.55, 1.35, 1.18, 1.08, 1]
    private static let htmlEdgeContent = CharacterSet(charactersIn: " \t\r\n\u{000C}").inverted
    private static let forbiddenAddressScalars = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    private static let authorityDelimiters = CharacterSet(charactersIn: "@/?#")
    private static let ipv6ScopeScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private let output = NSMutableAttributedString(string: "")
    private let text: String
    private let dialect: PreviewDialect
    private let limits: CompositionLimits
    private let nativeLimits: NativePreviewLimits
    private var nativeTableCells = 0
    private let onDiagnostic: ((PreviewRenderingDiagnostic) -> Void)?
    private var reviewedLinks: [Int: LinkPolicyResult] = [:]
    private var resolvedFonts: [FontKey: NSFont] = [:]
    private var sizedFonts: [FontSizeKey: NSFont] = [:]
    /// The page's objects in source order, and the UTF-16 offset of each.
    private let attachments: [NSTextAttachment]
    private let offsets: [Int]
    /// One stream for the document, so HTML scope crosses blocks (plan R3).
    private var composer: PreviewCompositionStream
    private var images = 0
    /// The objects shown, by index, checked here apart from the parser's and the composer's checks.
    private var shown: Set<Int> = []

    init(
        source: NSAttributedString, dialect: PreviewDialect, limits: CompositionLimits, nativeLimits: NativePreviewLimits,
        onDiagnostic: ((PreviewRenderingDiagnostic) -> Void)?
    ) {
        let raw = source.string as NSString
        var attachments: [NSTextAttachment] = []
        var offsets: [Int] = []
        source.enumerateAttribute(.attachment, in: NSRange(location: 0, length: source.length)) {
            value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            for index in range.location..<NSMaxRange(range) where raw.character(at: index) == 0xFFFC {
                attachments.append(attachment)
                offsets.append(index)
            }
        }
        text = source.string
        self.dialect = dialect
        self.limits = limits
        self.nativeLimits = nativeLimits
        self.onDiagnostic = onDiagnostic
        self.attachments = attachments
        self.offsets = offsets
        composer = PreviewComposer(dialect: dialect, limits: limits, collectDiagnostics: false).start()
    }

    /// The preview, or the page's plain text when parsing or composition refuses the page.
    func render() -> NSAttributedString {
        do {
            let document = try MarkdownParser.parse(text, objects: offsets, dialect: dialect, limits: limits)
            for block in document.blocks { try renderBlock(block, context: Context()) }
            try composer.finish()
            guard shown.count == attachments.count else { throw RenderFailure.objectMissing }
            return NSAttributedString(attributedString: output)
        } catch {
            Self.log(error)
            return plainText()
        }
    }

    private static let logger = Logger(subsystem: FormFactor.backdrop.loggerSubsystem, category: "preview")

    /// A limit, or Markdown inside a CommonMark raw-text element a page left open, is a refusal an
    /// ordinary page can reach; any other error is a broken invariant, logged as a fault.
    private static func log(_ error: Error) {
        switch error {
        case MarkdownParseError.inputLimit, MarkdownParseError.depthLimit, MarkdownParseError.tableCellLimit,
             MarkdownParseError.noPlaceholderWindow, MarkdownParseError.duplicateObject,
             CompositionError.inputLimit, CompositionError.eventLimit,
             CompositionError.depthLimit, CompositionError.outputLimit, CompositionError.structuredEventInRawText,
             HTMLTokenizationError.inputLimit, HTMLTokenizationError.tokenLimit, RenderFailure.nativeTableLimit:
            logger.info("plain text preview: \(String(describing: error), privacy: .public)")
        default:
            logger.fault("plain text preview: \(String(describing: error), privacy: .public)")
        }
    }

    /// The page's text with LF line endings and its objects in place, one unstyled paragraph style.
    private func plainText() -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
        for (attachment, offset) in zip(attachments, offsets) {
            result.addAttribute(.attachment, value: attachment, range: NSRange(location: offset, length: 1))
        }
        for ending in ["\r\n", "\r"] {
            result.mutableString.replaceOccurrences(
                of: ending, with: "\n", options: .literal, range: NSRange(location: 0, length: result.length)
            )
        }
        if result.length > 0, !result.string.hasSuffix("\n") {
            result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        }
        result.addAttribute(
            .paragraphStyle, value: paragraphStyle(Context()),
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private lazy var baseAttributes: [NSAttributedString.Key: Any] = [
        .font: InkStyle.baseFont, .foregroundColor: NSColor.labelColor,
    ]

    private func paragraphStyle(_ context: Context, marker: String? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = context.indent
        style.firstLineHeadIndent = marker == nil ? context.indent : max(0, context.indent - context.markerWidth)
        style.paragraphSpacing = context.spacing
        style.lineSpacing = 2
        style.lineBreakMode = .byWordWrapping
        style.textBlocks = context.blocks
        style.tabStops = marker == nil ? [] : [
            NSTextTab(textAlignment: .left, location: context.indent)
        ]
        style.defaultTabInterval = 28
        return style
    }

    private func paragraph(
        _ content: NSAttributedString, context: Context, marker: String? = nil,
        style: NSMutableParagraphStyle? = nil
    ) {
        let text = NSMutableAttributedString(string: "")
        if let marker { text.append(NSAttributedString(string: marker + "\t", attributes: baseAttributes)) }
        text.append(content)
        if !text.string.hasSuffix("\n") {
            text.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        }
        text.addAttribute(
            .paragraphStyle, value: style ?? paragraphStyle(context, marker: marker),
            range: NSRange(location: 0, length: text.length)
        )
        output.append(text)
    }

    private func renderBlock(_ block: MarkdownBlock, context: Context, marker: String? = nil) throws {
        try composer.beginBlock()
        switch block {
        case .heading(let level, let events):
            var attributes = baseAttributes
            let size = InkStyle.baseFont.pointSize * Self.headingScales[min(5, max(0, level - 1))]
            attributes[.font] = resolvedFont(sizedFont(InkStyle.baseFont, size: size), traits: [.strong])
            let style = paragraphStyle(context, marker: marker)
            style.paragraphSpacingBefore = level <= 2 ? 10 : 6
            style.paragraphSpacing = 6
            paragraph(try inlines(events, attributes: attributes), context: context, marker: marker, style: style)
        case .paragraph(let events):
            paragraph(try inlines(events, attributes: baseAttributes), context: context, marker: marker)
        case .codeBlock(let info, let literal):
            var nested = context
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            block.setValue(0, type: .absoluteValueType, for: .minimumWidth)
            block.backgroundColor = .controlBackgroundColor
            block.setWidth(8, type: .absoluteValueType, for: .padding)
            nested.blocks.append(block)
            var attributes = baseAttributes
            attributes[.font] = InkStyle.codeFont
            // The info string shows nothing but its objects, which open the block.
            let content = try parts(info.objectIdentities.map(HTMLPart.object) + literal, attributes: attributes)
            paragraph(content, context: nested)
        case .quote(let children):
            var nested = context
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            block.setValue(0, type: .absoluteValueType, for: .minimumWidth)
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(.separatorColor)
            block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            nested.blocks.append(block)
            nested.indent += 12
            for child in children { try renderBlock(child, context: nested) }
        case .list(let ordered, let start, _, let items):
            try renderList(items, startingAt: ordered ? start : nil, context: context)
        case .table(let alignments, let header, let body):
            try renderTable(alignments: alignments, rows: [header] + body, context: context)
        case .html(let parts):
            // A block of tags alone, or of a comment, leaves no empty paragraph.
            let content = trimmed(try compose(.rawHTML(parts), attributes: baseAttributes))
            if content.length > 0 {
                paragraph(content, context: context)
            }
        case .thematicBreak:
            var nested = context
            let rule = NSTextBlock()
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setBorderColor(.separatorColor)
            nested.blocks.append(rule)
            let style = paragraphStyle(nested)
            style.minimumLineHeight = 1
            style.maximumLineHeight = 1
            style.paragraphSpacingBefore = 8
            style.paragraphSpacing = 12
            paragraph(NSAttributedString(string: "\u{200B}", attributes: baseAttributes), context: nested, style: style)
        case .objects(let identities):
            // Each object with no element of its own is a paragraph of its own.
            for identity in identities {
                paragraph(try compose(.object(identity), attributes: baseAttributes), context: context)
            }
        }
    }

    /// An HTML block without the whitespace its source lines leave at either end.
    private func trimmed(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        // U+2028 is what `br` composes to, a break the block keeps at either end.
        let first = string.rangeOfCharacter(from: Self.htmlEdgeContent)
        guard first.location != NSNotFound else { return NSAttributedString(string: "") }
        let last = string.rangeOfCharacter(from: Self.htmlEdgeContent, options: .backwards)
        return text.attributedSubstring(from: NSRange(
            location: first.location, length: NSMaxRange(last) - first.location
        ))
    }

    private func renderList(_ items: [MarkdownListItem], startingAt start: Int?, context: Context) throws {
        let markers = items.enumerated().map { offset, item in
            let task = item.task.map { $0 ? "☑" : "☐" }
            if let start { return "\(start + offset)." + (task.map { " " + $0 } ?? "") }
            return task ?? "•"
        }
        let widest = markers.map { ($0 as NSString).size(withAttributes: baseAttributes).width }.max() ?? 0
        let markerWidth = max(28, ceil((widest + 8) / 28) * 28)
        var nested = context
        nested.indent += markerWidth
        nested.markerWidth = markerWidth
        nested.spacing = 3
        for (item, marker) in zip(items, markers) {
            switch item.blocks.first {
            case .paragraph?, .heading?:
                try renderBlock(item.blocks[0], context: nested, marker: marker)
                for block in item.blocks.dropFirst() { try renderBlock(block, context: nested) }
            default:
                paragraph(NSAttributedString(string: ""), context: nested, marker: marker)
                for block in item.blocks { try renderBlock(block, context: nested) }
            }
        }
    }

    /// One native cell per column and row, as published GFM has no spans; a row's missing
    /// trailing cells are empty ones.
    private func renderTable(
        alignments: [MarkdownAlignment?], rows: [[[PreviewEvent]]], context: Context
    ) throws {
        let columnCount = alignments.count
        guard columnCount > 0 else { throw RenderFailure.tableWithoutColumns }
        guard rows.allSatisfy({ $0.count <= columnCount }) else { throw RenderFailure.rowWiderThanTable }
        guard let total = nativeLimits.tableCellTotal(rows: rows.count, columns: columnCount, alreadyRendered: nativeTableCells)
        else { throw RenderFailure.nativeTableLimit }
        nativeTableCells = total
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        table.setValue(0, type: .absoluteValueType, for: .minimumWidth)
        for (rowIndex, cells) in rows.enumerated() {
            for column in 0..<columnCount {
                let cell = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1
                )
                cell.setContentWidth(100 / CGFloat(columnCount), type: .percentageValueType)
                cell.setValue(0, type: .absoluteValueType, for: .minimumWidth)
                cell.setWidth(6, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.verticalAlignment = .topAlignment
                if rowIndex == 0 { cell.backgroundColor = .controlBackgroundColor }
                var nested = context
                nested.indent = 0
                nested.spacing = 0
                nested.blocks.append(cell)
                let style = paragraphStyle(nested)
                switch alignments[column] {
                case .center?: style.alignment = .center
                case .right?: style.alignment = .right
                default: style.alignment = .left
                }
                var attributes = baseAttributes
                if rowIndex == 0 {
                    attributes[.font] = resolvedFont(InkStyle.baseFont, traits: [.strong])
                }
                try composer.beginBlock()
                let content = column < cells.count
                    ? try inlines(cells[column], attributes: attributes) : NSAttributedString(string: "")
                paragraph(content, context: nested, style: style)
            }
        }
        // End the table with a paragraph outside its cells, including at end of document.
        paragraph(NSAttributedString(string: ""), context: context)
    }

    /// A block's inline events, each composed under the block's `attributes`.
    private func inlines(
        _ events: [PreviewEvent], attributes: [NSAttributedString.Key: Any]
    ) throws -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        for event in events { text.append(try compose(event, attributes: attributes)) }
        return text
    }

    /// A literal's text and objects, each part its own composer event.
    private func parts(
        _ parts: [HTMLPart], attributes: [NSAttributedString.Key: Any]
    ) throws -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        for part in parts {
            switch part {
            case .text(let literal): text.append(try compose(.text(literal), attributes: attributes))
            case .object(let identity): text.append(try compose(.object(identity), attributes: attributes))
            }
        }
        return text
    }

    /// The native text of one composer event: `attributes` under the composed style.
    private func compose(
        _ event: PreviewEvent, attributes: [NSAttributedString.Key: Any]
    ) throws -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in try composer.consume(event) {
            switch run {
            case .text(let text, let style):
                result.append(NSAttributedString(string: text, attributes: styled(attributes, style)))
            case .object(let identity, _):
                result.append(try object(identity))
            case .image(let image, let style):
                result.append(try inertImage(image, attributes: styled(attributes, style)))
            }
        }
        return result
    }

    /// `attributes` with the composed traits and link; inside a Markdown link the composer
    /// gives that link, accepted or refused, and no HTML link.
    private func styled(
        _ attributes: [NSAttributedString.Key: Any], _ style: PreviewStyle
    ) -> [NSAttributedString.Key: Any] {
        var result = attributes
        let base = attributes[.font] as? NSFont ?? InkStyle.baseFont
        result[.font] = resolvedFont(base, traits: style.traits)
        if style.traits.contains(.code) {
            result[.backgroundColor] = NSColor.controlBackgroundColor
        }
        if style.traits.contains(.deletion) {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let url = reviewedLink(style) {
            result[.link] = url
            result[.foregroundColor] = NSColor.linkColor
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return result
    }

    private func resolvedFont(_ base: NSFont, traits: Set<PreviewTrait>) -> NSFont {
        let key = FontKey(base: base, traits: traits)
        if let font = resolvedFonts[key] { return font }
        onDiagnostic?(.fontResolution(base, traits))
        let manager = NSFontManager.shared
        var font = base
        if traits.contains(.code) {
            let inherited = manager.traits(of: font).intersection([.boldFontMask, .italicFontMask])
            font = convertedFont(sizedFont(InkStyle.codeFont, size: font.pointSize), traits: inherited)
        }
        if traits.contains(.strong) { font = convertedFont(font, traits: .boldFontMask) }
        if traits.contains(.emphasis) { font = convertedFont(font, traits: .italicFontMask) }
        resolvedFonts[key] = font
        return font
    }

    private func sizedFont(_ base: NSFont, size: CGFloat) -> NSFont {
        guard base.pointSize != size else { return base }
        let key = FontSizeKey(base: base, size: size)
        if let font = sizedFonts[key] { return font }
        onDiagnostic?(.fontSizing(base, size))
        let font = NSFontManager.shared.convert(base, toSize: size)
        sizedFonts[key] = font
        return font
    }

    private func convertedFont(_ base: NSFont, traits: NSFontTraitMask) -> NSFont {
        onDiagnostic?(.fontTraitConversion(base, traits))
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
    }

    private func reviewedLink(_ style: PreviewStyle) -> NSURL? {
        guard let occurrence = style.linkOccurrence else { return nil }
        let result: LinkPolicyResult
        if let reviewed = reviewedLinks[occurrence] {
            result = reviewed
        } else {
            onDiagnostic?(.linkPolicyEvaluation(occurrence))
            if case .unreviewed(let address)? = style.link, let url = safeURL(address) {
                result = .accepted(url as NSURL)
            } else {
                result = .refused
            }
            reviewedLinks[occurrence] = result
        }
        if case .accepted(let url) = result { return url }
        return nil
    }

    /// Alt text and objects remain ink beside the separate loading controls.
    private func inertImage(
        _ image: PreviewImage, attributes: [NSAttributedString.Key: Any]
    ) throws -> NSAttributedString {
        let descriptor = PreviewImageDescriptor(occurrence: images, destination: image.destination)
        images += 1
        var alt = attributes
        alt.removeValue(forKey: .link)
        alt.removeValue(forKey: .underlineStyle)
        alt[.foregroundColor] = NSColor.secondaryLabelColor
        let result = NSMutableAttributedString(string: "")
        for part in image.fallback {
            switch part {
            case .text(let text): result.append(NSAttributedString(string: text, attributes: alt))
            case .object(let identity): result.append(try object(identity))
            }
        }
        if result.length == 0 {
            alt[.previewImagePlaceholder] = true
            result.append(NSAttributedString(string: "\u{200B}", attributes: alt))
        }
        result.addAttribute(.previewImage, value: descriptor, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func safeURL(_ destination: String) -> URL? {
        guard !destination.unicodeScalars.contains(where: { Self.forbiddenAddressScalars.contains($0) }),
              var components = URLComponents(string: destination),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        if scheme == "mailto" {
            guard !components.path.isEmpty,
                  !components.path.unicodeScalars.contains(where: { Self.forbiddenAddressScalars.contains($0) })
            else { return nil }
            // A mailto query names headers and attachments for the mail client; the address alone opens.
            components.query = nil
            components.fragment = nil
        } else {
            // `https://docs.example.com@evil.example/` opens evil.example: userinfo refuses the link.
            guard let host = components.percentEncodedHost?.removingPercentEncoding, !host.isEmpty,
                  !host.unicodeScalars.contains(where: { Self.forbiddenAddressScalars.contains($0) }),
                  host.rangeOfCharacter(from: Self.authorityDelimiters) == nil,
                  !host.contains(":") || isIPv6Host(host),
                  components.user == nil, components.password == nil
            else { return nil }
        }
        return components.url
    }

    private func isIPv6Host(_ host: String) -> Bool {
        let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let parts = literal.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard !parts[1].isEmpty,
                  parts[1].unicodeScalars.allSatisfy({ Self.ipv6ScopeScalars.contains($0) }) else { return false }
        }
        var address = in6_addr()
        return String(parts[0]).withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    /// The object a composed identity names, as its attachment character.
    private func object(_ identity: String) throws -> NSAttributedString {
        guard let index = Int(identity), String(index) == identity, attachments.indices.contains(index) else {
            throw RenderFailure.unknownObject
        }
        guard shown.insert(index).inserted else { throw RenderFailure.objectShownTwice }
        var attributes = baseAttributes
        attributes[.attachment] = attachments[index]
        return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
    }
}
