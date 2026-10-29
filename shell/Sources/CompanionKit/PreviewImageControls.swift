import AppKit

@MainActor
private final class PreviewImageButton: NSButton {
    weak var preview: MarkdownPreviewView?

    override func mouseDown(with event: NSEvent) {
        guard preview?.isSelectedPage == true else { preview?.promote(); return }
        super.mouseDown(with: event)
    }
}

@MainActor
private final class PreviewImageControlCell: NSTextAttachmentCell {
    nonisolated let reservedSize: NSSize

    init(size: NSSize) {
        reservedSize = size
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Preview image cells are not unarchived") }

    override nonisolated func cellSize() -> NSSize { reservedSize }
    override nonisolated func cellBaselineOffset() -> NSPoint { .zero }

    override func draw(withFrame frame: NSRect, in view: NSView?) {}
}

extension NSAttributedString.Key {
    static let previewImageControl = NSAttributedString.Key("CompanionKitPreviewImageControl")
    static let previewLoadedImage = NSAttributedString.Key("CompanionKitPreviewLoadedImage")
}

@MainActor
final class PreviewImageControls {
    static let maximumControls = 32
    static let maximumActiveImages = 4

    private enum Action: CaseIterable {
        case load, cancel, unload, retry, unavailable

        var compactTitle: String {
            let key: String
            switch self {
            case .load: key = "Load image"
            case .cancel: key = "Cancel image"
            case .unload: key = "Unload image"
            case .retry: key = "Retry image"
            case .unavailable: key = "Image unavailable"
            }
            return CompanionL10n.string(key)
        }

        func fullTitle(host: String) -> String {
            let key: String
            switch self {
            case .load: key = "preview.image.load_from"
            case .cancel: key = "preview.image.cancel_from"
            case .unload: key = "preview.image.unload_from"
            case .retry: key = "preview.image.retry_from"
            case .unavailable: return compactTitle
            }
            return CompanionL10n.format(key, host)
        }
    }

    @MainActor
    private final class Entry {
        let descriptor: PreviewImageDescriptor
        let range: NSRange
        let approvedURL: URL?
        let host: String
        let refusal: String?
        let spokenAlt: String
        var controlRange = NSRange()
        var pictureRange = NSRange()
        var presentationWidth: CGFloat = 340
        let button = PreviewImageButton()
        var task: Task<Void, Never>?
        var image: NSImage?
        var failure: String?
        var generation = UUID()

        var action: Action {
            guard approvedURL != nil else { return .unavailable }
            if task != nil { return .cancel }
            if image != nil { return .unload }
            return failure == nil ? .load : .retry
        }

        init(descriptor: PreviewImageDescriptor, range: NSRange, text: NSAttributedString) {
            self.descriptor = descriptor
            self.range = range
            approvedURL = PreviewImageRequestPolicy.url(for: descriptor.destination)
            host = approvedURL?.host ?? ""
            refusal = approvedURL == nil ? PreviewImageRequestPolicy.refusal(for: descriptor.destination) : nil
            var alt = ""
            text.enumerateAttributes(in: range) { attributes, partRange, stop in
                guard attributes[.previewImagePlaceholder] == nil else { return }
                let part = attributes[.attachment] is ChipAttachment
                    ? CompanionL10n.string("[sealed content]")
                    : (text.string as NSString).substring(with: partRange)
                alt.unicodeScalars.append(contentsOf: part.unicodeScalars.prefix(241 - alt.unicodeScalars.count))
                if alt.unicodeScalars.count > 240 { stop.pointee = true }
            }
            if alt.isEmpty { spokenAlt = CompanionL10n.string("Image") }
            else if alt.unicodeScalars.count > 240 {
                spokenAlt = String(String.UnicodeScalarView(alt.unicodeScalars.prefix(240))) + "…"
            }
            else { spokenAlt = alt }
        }

        deinit { task?.cancel() }
    }

    private weak var preview: MarkdownPreviewView?
    private var original = NSAttributedString(string: "")
    private var entries: [Entry] = []
    private var tableParagraphs: [(range: NSRange, style: NSParagraphStyle)] = []
    private var presentedLinearTables = Set<ObjectIdentifier>()
    private var presenting = false
    private var needsAnotherPresentation = false
    private var presentationScheduled = false
    private var keyViewVisibilityChanged = false
    private var compactWidthMeasurement: (font: NSFont, labels: [String], width: CGFloat)?
    private let loadImage: @MainActor (URL) async throws -> NSImage

    var buttons: [NSButton] { entries.map(\.button) }
    var loadedImageCount: Int { entries.filter { $0.image != nil }.count }

    init(
        preview: MarkdownPreviewView,
        load: @escaping @MainActor (URL) async throws -> NSImage = {
            try await PreviewImageLoader().load($0)
        }
    ) {
        self.preview = preview
        self.loadImage = load
    }

    func seed(_ text: NSAttributedString, preserveConsent: Bool = false) {
        var descriptors: [(PreviewImageDescriptor, NSRange)] = []
        text.enumerateAttribute(.previewImage, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard let descriptor = value as? PreviewImageDescriptor else { return }
            descriptors.append((descriptor, range))
            if descriptors.count == Self.maximumControls { stop.pointee = true }
        }
        let sameImages = descriptors.count == entries.count && zip(descriptors, entries).allSatisfy {
            $0.0.0 == $0.1.descriptor && $0.0.1 == $0.1.range
        }
        if !preserveConsent || original.string != text.string || !sameImages {
            clearEntries()
            for (descriptor, range) in descriptors {
                let entry = Entry(descriptor: descriptor, range: range, text: text)
                entry.button.preview = preview
                entry.button.bezelStyle = .rounded
                entry.button.controlSize = .small
                entry.button.setAccessibilityRole(.button)
                entry.button.setAccessibilityElement(true)
                entry.button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                entry.button.lineBreakMode = .byTruncatingTail
                entry.button.target = self
                entry.button.action = #selector(activate(_:))
                entry.button.tag = entries.count
                entries.append(entry)
                preview?.addSubview(entry.button)
            }
        }
        original = text
        seedStorage()
        present()
    }

    private func seedStorage() {
        guard let preview, let storage = preview.textStorage else { return }
        let selection = preview.selectedRanges
        let text = NSMutableAttributedString(attributedString: original)
        for entry in entries.reversed() {
            let control = NSTextAttachment()
            let picture = NSTextAttachment()
            control.attachmentCell = PreviewImageControlCell(size: .zero)
            picture.attachmentCell = PreviewImageControlCell(size: .zero)
            let insertion = NSMutableAttributedString(attachment: control)
            insertion.addAttribute(.previewImageControl, value: entry.descriptor.occurrence,
                                   range: NSRange(location: 0, length: 1))
            insertion.append(NSAttributedString(attachment: picture))
            if let paragraph = original.attribute(.paragraphStyle, at: entry.range.location,
                                                  effectiveRange: nil) {
                insertion.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: 2))
            }
            text.insert(insertion, at: NSMaxRange(entry.range))
        }
        for (index, entry) in entries.enumerated() {
            entry.controlRange = NSRange(location: NSMaxRange(entry.range) + index * 2, length: 1)
            entry.pictureRange = NSRange(location: entry.controlRange.location + 1, length: 1)
        }
        tableParagraphs.removeAll()
        presentedLinearTables.removeAll()
        original.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: original.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  style.textBlocks.contains(where: { $0 is NSTextTableBlock }) else { return }
            let start = mappedOriginalIndex(range.location)
            let end = mappedOriginalIndex(NSMaxRange(range))
            tableParagraphs.append((NSRange(location: start, length: end - start), style))
        }
        storage.setAttributedString(text)
        let ranges = selection.map { value -> NSValue in
            let range = value.rangeValue
            let start = min(range.location, storage.length)
            return NSValue(range: NSRange(location: start, length: min(range.length, storage.length - start)))
        }
        preview.selectedRanges = ranges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : ranges
    }

    func discard() {
        guard entries.contains(where: { $0.task != nil || $0.image != nil || $0.failure != nil }) else {
            entries.forEach(configure)
            return
        }
        for entry in entries {
            entry.generation = UUID()
            entry.task?.cancel()
            entry.task = nil
            entry.image = nil
            entry.failure = nil
        }
        changed()
    }

    private func clearEntries() {
        for entry in entries {
            entry.generation = UUID()
            entry.task?.cancel()
            entry.button.removeFromSuperview()
        }
        entries.removeAll()
    }

    @objc private func activate(_ button: NSButton) {
        guard entries.indices.contains(button.tag), let preview else { return }
        let entry = entries[button.tag]
        guard entry.button === button, !button.isHidden,
              let storage = preview.textStorage, validRanges(entry, in: storage) else {
            setHidden(true, for: entry)
            return
        }
        if entry.task != nil || entry.image != nil {
            entry.generation = UUID()
            entry.task?.cancel()
            entry.task = nil
            entry.image = nil
            entry.failure = nil
            changed()
            return
        }
        guard preview.authorizeImageLoad() else { discard(); return }
        guard activeImages < Self.maximumActiveImages,
              let url = entry.approvedURL else { return }
        let generation = UUID()
        entry.generation = generation
        entry.failure = nil
        let load = loadImage
        entry.task = Task { [weak self, weak entry] in
            defer {
                if let self, let entry, entry.generation == generation, entry.task != nil {
                    entry.task = nil
                    self.changed()
                }
            }
            do {
                guard !Task.isCancelled, entry?.generation == generation else { return }
                guard self?.preview?.authorizeImageLoad() == true else {
                    self?.discard()
                    return
                }
                let image = try await load(url)
                guard !Task.isCancelled, let self, let entry,
                      entry.generation == generation else { return }
                entry.task = nil
                guard self.preview?.authorizeImageLoad() == true else { self.discard(); return }
                entry.image = image
                self.changed()
            } catch {
                guard !Task.isCancelled, let self, let entry,
                      entry.generation == generation else { return }
                entry.task = nil
                guard self.preview?.authorizeImageLoad() == true else { self.discard(); return }
                entry.failure = error.localizedDescription
                self.changed()
            }
        }
        changed()
    }

    private var activeImages: Int { entries.filter { $0.task != nil || $0.image != nil }.count }

    private func changed() {
        present()
        preview?.onImageLayoutChanged?()
        if let preview { NSAccessibility.post(element: preview, notification: .layoutChanged) }
    }

    func resize() {
        guard !entries.isEmpty else { return }
        entries.forEach(configure)
        schedulePresentation()
    }

    private func present() {
        guard !presenting else {
            needsAnotherPresentation = true
            return
        }
        guard let preview, let storage = preview.textStorage else { return }
        presenting = true
        defer {
            presenting = false
            if needsAnotherPresentation {
                needsAnotherPresentation = false
                schedulePresentation()
            }
        }
        let availableWidth = max(20, preview.bounds.width - preview.textContainerInset.width * 2 - 16)
        storage.beginEditing()
        let linearTables = linearizedTables(availableWidth: availableWidth)
        if linearTables != presentedLinearTables {
            restoreParagraphs(in: storage, linearTables: linearTables)
            presentedLinearTables = linearTables
        }
        for entry in entries {
            guard validRanges(entry, in: storage) else {
                setHidden(true, for: entry)
                continue
            }
            setHidden(false, for: entry)
            let paragraph = original.attribute(.paragraphStyle, at: entry.range.location,
                                               effectiveRange: nil) as? NSParagraphStyle
            let cell = paragraph?.textBlocks.last as? NSTextTableBlock
            let linear = cell.map { linearTables.contains(ObjectIdentifier($0.table)) } ?? false
            let columns = linear ? 1 : max(1, cell?.table.numberOfColumns ?? 1)
            let room = max(1, availableWidth / CGFloat(columns) - (paragraph?.headIndent ?? 0) - (cell == nil || linear ? 0 : 14))
            entry.presentationWidth = min(340, room)
            configure(entry)
            let slot = NSTextAttachment()
            slot.bounds = NSRect(x: 0, y: -6, width: entry.presentationWidth, height: 28)
            slot.attachmentCell = PreviewImageControlCell(size: slot.bounds.size)
            storage.addAttribute(.attachment, value: slot, range: entry.controlRange)
            let picture = NSTextAttachment()
            if let image = entry.image {
                picture.image = image
                picture.bounds = Self.pictureBounds(image: image, room: room,
                                                     backingScale: preview.window?.backingScaleFactor ?? 1)
                storage.addAttribute(.previewLoadedImage, value: entry.descriptor.occurrence, range: entry.pictureRange)
            } else {
                picture.bounds = .zero
                picture.attachmentCell = PreviewImageControlCell(size: .zero)
                storage.removeAttribute(.previewLoadedImage, range: entry.pictureRange)
            }
            storage.addAttribute(.attachment, value: picture, range: entry.pictureRange)
        }
        storage.endEditing()
        preview.needsLayout = true
        preview.needsDisplay = true
    }

    static func pictureBounds(image: NSImage, room: CGFloat, backingScale: CGFloat) -> NSRect {
        let rasters = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
        if let raster = rasters.max(by: {
            Double($0.pixelsWide) * Double($0.pixelsHigh) < Double($1.pixelsWide) * Double($1.pixelsHigh)
        }) {
            return pictureBounds(pixelSize: NSSize(width: raster.pixelsWide, height: raster.pixelsHigh),
                                 room: room, backingScale: backingScale)
        }
        if !image.representations.isEmpty,
           let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return pictureBounds(pixelSize: NSSize(width: raster.width, height: raster.height),
                                 room: room, backingScale: backingScale)
        }
        return fittedBounds(pointSize: image.size, room: room)
    }

    static func pictureBounds(pixelSize: NSSize, room: CGFloat, backingScale: CGFloat) -> NSRect {
        let scale = max(1, backingScale)
        return fittedBounds(pointSize: NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale), room: room)
    }

    private static func fittedBounds(pointSize: NSSize, room: CGFloat) -> NSRect {
        let fit = min(1, min(room / max(1, pointSize.width), 400 / max(1, pointSize.height)))
        return NSRect(x: 0, y: 0, width: pointSize.width * fit, height: pointSize.height * fit)
    }

    private func minimumControlWidth(font: NSFont) -> CGFloat {
        let labels = Action.allCases.map(\.compactTitle)
        if let cached = compactWidthMeasurement, cached.font == font, cached.labels == labels { return cached.width }
        let width = max(44, labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 20 }.max() ?? 44)
        compactWidthMeasurement = (font, labels, width)
        return width
    }

    private func linearizedTables(availableWidth: CGFloat) -> Set<ObjectIdentifier> {
        var result = Set<ObjectIdentifier>()
        for entry in entries {
            guard let style = original.attribute(.paragraphStyle, at: entry.range.location,
                                                  effectiveRange: nil) as? NSParagraphStyle,
                  let cell = style.textBlocks.last as? NSTextTableBlock else { continue }
            let room = availableWidth / CGFloat(max(1, cell.table.numberOfColumns)) - style.headIndent - 14
            let font = entry.button.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
            if room < minimumControlWidth(font: font) { result.insert(ObjectIdentifier(cell.table)) }
        }
        return result
    }

    private func mappedOriginalIndex(_ index: Int) -> Int {
        index + entries.filter { NSMaxRange($0.range) <= index }.count * 2
    }

    private func restoreParagraphs(in storage: NSTextStorage, linearTables: Set<ObjectIdentifier>) {
        func adjusted(_ style: NSParagraphStyle) -> NSParagraphStyle {
            guard style.textBlocks.contains(where: {
                guard let cell = $0 as? NSTextTableBlock else { return false }
                return linearTables.contains(ObjectIdentifier(cell.table))
            }), let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return style }
            copy.textBlocks = style.textBlocks.filter {
                guard let cell = $0 as? NSTextTableBlock else { return true }
                return !linearTables.contains(ObjectIdentifier(cell.table))
            }
            return copy
        }
        for paragraph in tableParagraphs where NSMaxRange(paragraph.range) <= storage.length {
            storage.addAttribute(.paragraphStyle, value: adjusted(paragraph.style), range: paragraph.range)
        }
        for entry in entries {
            guard validRanges(entry, in: storage),
                  let style = original.attribute(.paragraphStyle, at: entry.range.location,
                                                 effectiveRange: nil) as? NSParagraphStyle,
                  style.textBlocks.contains(where: { $0 is NSTextTableBlock }) else { continue }
            storage.addAttribute(.paragraphStyle, value: adjusted(style),
                                 range: NSRange(location: entry.controlRange.location, length: 2))
        }
    }

    private func schedulePresentation() {
        guard !presentationScheduled else { return }
        presentationScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            self.changed()
        }
    }

    private func configure(_ entry: Entry) {
        let url = entry.approvedURL
        let action = entry.action
        let fullTitle = action.fullTitle(host: entry.host)
        let font = entry.button.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let needsCompact = action != .unavailable
            && (fullTitle as NSString).size(withAttributes: [.font: font]).width + 20 > entry.presentationWidth
        let visibleTitle = needsCompact ? action.compactTitle : fullTitle
        if entry.button.title != visibleTitle { entry.button.title = visibleTitle }
        let hasReservation = entry.task != nil || entry.image != nil
        entry.button.isEnabled = url != nil && preview?.isImagePresentationActive == true
            && (hasReservation || activeImages < Self.maximumActiveImages)
        let policy = PreviewImageRequestPolicy.requestSummary
        let help = url.map { "\($0.absoluteString)\n\(policy)" }
            ?? entry.refusal ?? CompanionL10n.string("Image unavailable")
        let capacity = !hasReservation && activeImages >= Self.maximumActiveImages
            ? CompanionL10n.string("Unload or cancel another image first (four images at a time).") : nil
        entry.button.toolTip = [entry.failure, capacity, help].compactMap { $0 }.joined(separator: "\n")
        let label = CompanionL10n.format("preview.image.accessibility", fullTitle, entry.spokenAlt)
        let changed = entry.button.accessibilityLabel() != label
        entry.button.setAccessibilityHelp(entry.button.toolTip)
        if changed {
            entry.button.setAccessibilityLabel(label)
            NSAccessibility.post(element: entry.button, notification: .titleChanged)
        }
    }

    private func validRanges(_ entry: Entry, in storage: NSTextStorage) -> Bool {
        guard entry.controlRange.length == 1, entry.pictureRange.length == 1,
              entry.controlRange.location >= 0,
              entry.pictureRange.location == NSMaxRange(entry.controlRange),
              NSMaxRange(entry.pictureRange) <= storage.length else { return false }
        let text = storage.string as NSString
        return text.character(at: entry.controlRange.location) == 0xFFFC
            && text.character(at: entry.pictureRange.location) == 0xFFFC
            && storage.attribute(.previewImageControl, at: entry.controlRange.location,
                                 effectiveRange: nil) as? Int == entry.descriptor.occurrence
            && storage.attribute(.attachment, at: entry.pictureRange.location,
                                 effectiveRange: nil) is NSTextAttachment
    }

    private func setHidden(_ hidden: Bool, for entry: Entry) {
        guard entry.button.isHidden != hidden else { return }
        entry.button.isHidden = hidden
        keyViewVisibilityChanged = true
    }

    func layout() {
        guard let preview, let storage = preview.textStorage,
              let manager = preview.layoutManager, let container = preview.textContainer else { return }
        manager.ensureLayout(for: container)
        var keyViewGeometryChanged = false
        for entry in entries {
            guard validRanges(entry, in: storage) else {
                setHidden(true, for: entry)
                continue
            }
            setHidden(false, for: entry)
            let glyphs = manager.glyphRange(forCharacterRange: entry.controlRange, actualCharacterRange: nil)
            let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let frame = bounds.offsetBy(dx: preview.textContainerOrigin.x, dy: preview.textContainerOrigin.y)
            if entry.button.frame != frame {
                entry.button.frame = frame
                keyViewGeometryChanged = true
            }
        }
        if (keyViewGeometryChanged || keyViewVisibilityChanged), let window = preview.window {
            keyViewVisibilityChanged = false
            window.recalculateKeyViewLoop()
        }
    }
}
