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
    @MainActor
    private final class Entry {
        let descriptor: PreviewImageDescriptor
        let range: NSRange
        var controlRange = NSRange()
        var pictureRange = NSRange()
        let button = PreviewImageButton()
        var task: Task<Void, Never>?
        var image: NSImage?
        var failure: String?
        var generation = UUID()

        init(descriptor: PreviewImageDescriptor, range: NSRange) {
            self.descriptor = descriptor
            self.range = range
        }
    }

    private weak var preview: MarkdownPreviewView?
    private var original = NSAttributedString(string: "")
    private var entries: [Entry] = []
    private var presenting = false
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
                let entry = Entry(descriptor: descriptor, range: range)
                entry.button.preview = preview
                entry.button.bezelStyle = .rounded
                entry.button.controlSize = .small
                entry.button.setAccessibilityRole(.button)
                entry.button.setAccessibilityElement(true)
                entry.button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                entry.button.lineBreakMode = .byTruncatingMiddle
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
        storage.setAttributedString(text)
        let ranges = selection.map { value -> NSValue in
            let range = value.rangeValue
            let start = min(range.location, storage.length)
            return NSValue(range: NSRange(location: start, length: min(range.length, storage.length - start)))
        }
        preview.selectedRanges = ranges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : ranges
    }

    func discard() {
        for entry in entries {
            entry.generation = UUID()
            entry.task?.cancel()
            entry.task = nil
            entry.image = nil
            entry.failure = nil
        }
        present()
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
        guard entry.button === button else { return }
        if entry.task != nil || entry.image != nil {
            entry.generation = UUID()
            entry.task?.cancel()
            entry.task = nil
            entry.image = nil
            entry.failure = nil
            changed()
            return
        }
        guard preview.mayLoadImages,
              activeImages < Self.maximumActiveImages,
              let url = PreviewImageRequestPolicy.url(for: entry.descriptor.destination) else { return }
        let generation = UUID()
        entry.generation = generation
        entry.failure = nil
        let load = loadImage
        entry.task = Task { [weak self, weak entry] in
            do {
                guard !Task.isCancelled, entry?.generation == generation else { return }
                guard self?.preview?.mayLoadImages == true else {
                    self?.discard()
                    return
                }
                let image = try await load(url)
                guard !Task.isCancelled, let self, let entry,
                      entry.generation == generation else { return }
                entry.task = nil
                guard self.preview?.mayLoadImages == true else { self.discard(); return }
                entry.image = image
                self.changed()
            } catch {
                guard !Task.isCancelled, let self, let entry,
                      entry.generation == generation else { return }
                entry.task = nil
                guard self.preview?.mayLoadImages == true else { self.discard(); return }
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
        present()
        preview?.needsLayout = true
    }

    private func present() {
        guard !presenting, let preview, let storage = preview.textStorage else { return }
        presenting = true
        defer { presenting = false }
        let availableWidth = max(20, preview.bounds.width - preview.textContainerInset.width * 2 - 16)
        storage.beginEditing()
        for entry in entries {
            guard NSMaxRange(entry.pictureRange) <= storage.length else { continue }
            configure(entry)
            let paragraph = original.attribute(.paragraphStyle, at: entry.range.location,
                                               effectiveRange: nil) as? NSParagraphStyle
            let cell = paragraph?.textBlocks.last as? NSTextTableBlock
            let columns = max(1, cell?.table.numberOfColumns ?? 1)
            let room = max(1, availableWidth / CGFloat(columns) - (paragraph?.headIndent ?? 0) - (cell == nil ? 0 : 14))
            let slot = NSTextAttachment()
            slot.bounds = NSRect(x: 0, y: -6, width: min(340, room), height: 28)
            slot.attachmentCell = PreviewImageControlCell(size: slot.bounds.size)
            storage.addAttribute(.attachment, value: slot, range: entry.controlRange)
            let picture = NSTextAttachment()
            if let image = entry.image {
                picture.image = image
                let scale = min(1, min(room / max(1, image.size.width), 400 / max(1, image.size.height)))
                picture.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
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

    private func configure(_ entry: Entry) {
        let url = PreviewImageRequestPolicy.url(for: entry.descriptor.destination)
        let host = url?.host ?? ""
        let actionKey: String
        if entry.task != nil { actionKey = "preview.image.cancel_from" }
        else if entry.image != nil { actionKey = "preview.image.unload_from" }
        else if entry.failure != nil { actionKey = "preview.image.retry_from" }
        else { actionKey = "preview.image.load_from" }
        var alt = ""
        original.enumerateAttributes(in: entry.range) { attributes, range, _ in
            if attributes[.previewImagePlaceholder] != nil { return }
            if attributes[.attachment] is ChipAttachment {
                alt += CompanionL10n.string("[sealed content]")
            } else {
                alt += (original.string as NSString).substring(with: range)
            }
        }
        if alt.isEmpty { alt = CompanionL10n.string("Image") }
        entry.button.title = url == nil ? CompanionL10n.string("Image unavailable")
            : CompanionL10n.format(actionKey, host)
        let hasReservation = entry.task != nil || entry.image != nil
        entry.button.isEnabled = url != nil && preview?.isSelectedPage == true
            && (hasReservation || activeImages < Self.maximumActiveImages)
        let policy = CompanionL10n.string("One HTTPS image request. No redirects, cookies, or saved credentials.")
        let help = url.map { "\($0.absoluteString)\n\(policy)" }
            ?? PreviewImageRequestPolicy.refusal(for: entry.descriptor.destination) ?? CompanionL10n.string("Image unavailable")
        let capacity = !hasReservation && activeImages >= Self.maximumActiveImages
            ? CompanionL10n.string("Unload or cancel another image first (four images at a time).") : nil
        entry.button.toolTip = [entry.failure, capacity, help].compactMap { $0 }.joined(separator: "\n")
        entry.button.setAccessibilityLabel(CompanionL10n.format("preview.image.accessibility", entry.button.title, alt))
        entry.button.setAccessibilityHelp(entry.button.toolTip)
    }

    func layout() {
        guard let preview, let storage = preview.textStorage,
              let manager = preview.layoutManager, let container = preview.textContainer else { return }
        manager.ensureLayout(for: container)
        for entry in entries {
            guard NSMaxRange(entry.controlRange) <= storage.length else { continue }
            let glyphs = manager.glyphRange(forCharacterRange: entry.controlRange, actualCharacterRange: nil)
            let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            entry.button.frame = bounds.offsetBy(dx: preview.textContainerOrigin.x, dy: preview.textContainerOrigin.y)
        }
    }
}
