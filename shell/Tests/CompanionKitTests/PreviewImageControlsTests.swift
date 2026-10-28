import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class PreviewImageControlsTests: XCTestCase {
    private static let address = "https://example.com/image.png"
    private static let markdown = "![A small image](https://example.com/image.png)"

    @MainActor
    private struct Fixture {
        let model: PageModel
        let page: UInt64
        let window: NSWindow
        let scroll: NSScrollView
        let stack: DayStackView
        let coordinator: InkEditorView.Coordinator
        let preview: MarkdownPreviewView
        let loader: TestLoader

        func update() {
            stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
        }
    }

    private func fixture(_ source: String = "![A small image](https://example.com/image.png)") throws -> Fixture {
        let suite = "companion-image-controls-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let loader = TestLoader()
        let model = isolatedModel(defaults: defaults, saveDebounce: 3_600,
                                  previewImageLoad: { try await loader.load($0) })
        model.showsTimeUnits = true
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        model.syncDocument(sheet: page, runs: [.ink(source)])
        model.toggleMarkdownPreview(for: page)
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = DayScrollView.makeRoll(model: model, coordinator: coordinator, emptyHint: "hint")
        let frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.frame = frame
        scroll.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        stack.update(projection: model.timeUnits, selectedPage: page, readOnly: false)
        let preview = try XCTUnwrap(stack.previewRegions[page])
        return Fixture(model: model, page: page, window: window, scroll: scroll,
                       stack: stack, coordinator: coordinator, preview: preview, loader: loader)
    }

    private func eventually(
        _ predicate: @MainActor () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try XCTUnwrap(predicate() ? true : nil, "The image state did not settle", file: file, line: line)
    }

    private func image() -> NSImage {
        NSImage(size: NSSize(width: 24, height: 12))
    }

    private func source(in fixture: Fixture) -> String {
        fixture.model.coreClient.documentRuns(sheet: fixture.page).reduce(into: "") {
            if case .ink(let ink) = $1 { $0 += ink }
        }
    }

    private enum TestLoadError: Error { case unexpectedRequest }

    @MainActor
    private final class TestLoader {
        private(set) var requests: [URL] = []
        var handler: @MainActor (URL) async throws -> NSImage = { _ in
            throw TestLoadError.unexpectedRequest
        }

        func load(_ url: URL) async throws -> NSImage {
            requests.append(url)
            return try await handler(url)
        }
    }

    @MainActor
    private final class PendingLoads {
        private(set) var addresses: [URL] = []
        private var continuations: [CheckedContinuation<NSImage, Error>?] = []

        func load(_ url: URL) async throws -> NSImage {
            addresses.append(url)
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }

        func finish(_ index: Int, with image: NSImage) {
            let continuation = continuations[index]
            continuations[index] = nil
            continuation?.resume(returning: image)
        }
    }

    @MainActor
    private final class PresentationReentry: NSObject {
        let action: @MainActor () -> Void
        private(set) var calls = 0

        init(action: @escaping @MainActor () -> Void) { self.action = action }

        @objc func updated(_ notification: Notification) {
            guard calls == 0 else { return }
            calls += 1
            action()
        }
    }

    @MainActor
    private final class StorageEdits: NSObject {
        private(set) var calls = 0

        @objc func updated(_ notification: Notification) { calls += 1 }
    }

    private func loadedPictureBounds(in preview: MarkdownPreviewView) -> [CGRect] {
        guard let storage = preview.textStorage else { return [] }
        var bounds: [CGRect] = []
        storage.enumerateAttribute(.previewLoadedImage, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard value != nil,
                  let picture = storage.attribute(.attachment, at: range.location,
                                                  effectiveRange: nil) as? NSTextAttachment else { return }
            bounds.append(picture.bounds)
        }
        return bounds
    }

    func testOpeningScrollingAndDialectChangesDoNotLoadImages() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        var requests: [URL] = []
        fixture.loader.handler = { url in
            requests.append(url)
            return self.image()
        }
        XCTAssertEqual(fixture.preview.imageControls.buttons.count, 1)
        XCTAssertTrue(fixture.preview.string.contains("A small image"))
        fixture.preview.layoutSubtreeIfNeeded()
        let button = fixture.preview.imageControls.buttons[0]
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertTrue(button.accessibilityLabel()?.contains("A small image") == true)
        XCTAssertTrue(button.accessibilityLabel()?.contains("example.com") == true)
        XCTAssertGreaterThan(button.frame.width, 0)
        XCTAssertGreaterThan(button.frame.height, 0)
        fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: 50))
        fixture.update()
        fixture.model.markdownDialect = .commonMark
        fixture.model.markdownDialect = .gfm
        fixture.update()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(fixture.loader.requests.isEmpty)
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        XCTAssertTrue(fixture.preview.imageControls.buttons[0].title.hasPrefix("Load"))
    }

    func testMarkdownAndHTMLImagesWithTheSameAddressRequireSeparateActivation() async throws {
        let source = Self.markdown + " <img src=\"\(Self.address)\" alt=\"HTML image\">"
        let fixture = try fixture(source)
        defer { fixture.window.close() }
        var requests: [URL] = []
        fixture.loader.handler = { url in
            requests.append(url)
            return self.image()
        }
        XCTAssertEqual(fixture.preview.imageControls.buttons.count, 2)
        let marks = fixture.model.dirtyMarks
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
        XCTAssertEqual(requests.map(\.absoluteString), [Self.address])
        XCTAssertTrue(fixture.preview.imageControls.buttons[0].title.hasPrefix("Unload"))
        XCTAssertTrue(fixture.preview.imageControls.buttons[1].title.hasPrefix("Load"))
        fixture.preview.imageControls.buttons[1].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 2 }
        XCTAssertEqual(requests.map(\.absoluteString), [Self.address, Self.address])
        XCTAssertEqual(self.source(in: fixture), source)
        XCTAssertEqual(fixture.model.dirtyMarks, marks)
    }

    func testAnEmptyAltStillHasAnExplicitLoadControl() async throws {
        let fixture = try fixture("![](\(Self.address)) <img src=\"\(Self.address)\" alt=\"\">")
        defer { fixture.window.close() }
        var requests = 0
        fixture.loader.handler = { _ in
            requests += 1
            return self.image()
        }
        XCTAssertEqual(fixture.preview.imageControls.buttons.count, 2)
        fixture.preview.imageControls.buttons[1].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(fixture.preview.imageControls.buttons[0].title.hasPrefix("Load"))
        fixture.preview.setSelectedRange(NSRange(location: 0, length: fixture.preview.string.utf16.count))
        let copied = fixture.preview.shownSelection().flatMap { $0 }.reduce(into: "") {
            if case .ink(let text) = $1 { $0 += text }
        }
        XCTAssertTrue(copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testUnsupportedDestinationsHaveDisabledControlsAndNeverReachTheLoader() async throws {
        let fixture = try fixture("![Local](file:///tmp/image.png) ![Insecure](http://example.com/a.png)")
        defer { fixture.window.close() }
        var requests = 0
        fixture.loader.handler = { _ in
            requests += 1
            return self.image()
        }
        XCTAssertEqual(fixture.preview.imageControls.buttons.count, 2)
        for button in fixture.preview.imageControls.buttons {
            XCTAssertFalse(button.isEnabled)
            XCTAssertFalse(button.toolTip?.isEmpty ?? true)
            button.performClick(nil)
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(fixture.preview.string.contains("Local"))
        XCTAssertTrue(fixture.preview.string.contains("Insecure"))
    }

    func testCancellationRejectsALateResultAndNeedsAnotherLoadAction() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let pending = PendingLoads()
        fixture.loader.handler = { try await pending.load($0) }
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { pending.addresses.count == 1 }
        XCTAssertTrue(fixture.preview.imageControls.buttons[0].title.hasPrefix("Cancel"))
        fixture.preview.imageControls.buttons[0].performClick(nil)
        XCTAssertTrue(fixture.preview.imageControls.buttons[0].title.hasPrefix("Load"))
        pending.finish(0, with: image())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        XCTAssertEqual(pending.addresses.count, 1)
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { pending.addresses.count == 2 }
        pending.finish(1, with: image())
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
    }

    func testCancelAndReloadBeforeTheFirstTaskStartsPreservesTheNewRequest() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let pending = PendingLoads()
        fixture.loader.handler = { try await pending.load($0) }
        let button = fixture.preview.imageControls.buttons[0]
        button.performClick(nil)
        button.performClick(nil)
        button.performClick(nil)
        try await eventually { pending.addresses.count == 1 }
        pending.finish(0, with: image())
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
        XCTAssertTrue(button.title.hasPrefix("Unload"))
    }

    func testFailureOffersExplicitRetryAndUnloadDoesNotFetchAgain() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        var requests = 0
        fixture.loader.handler = { _ in
            requests += 1
            if requests == 1 { throw PreviewImageLoadError.invalidImage }
            return self.image()
        }
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { fixture.preview.imageControls.buttons[0].title.hasPrefix("Retry") }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        XCTAssertFalse(fixture.preview.imageControls.buttons[0].toolTip?.isEmpty ?? true)
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
        XCTAssertEqual(requests, 2)
        fixture.preview.imageControls.buttons[0].performClick(nil)
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        XCTAssertTrue(fixture.preview.imageControls.buttons[0].title.hasPrefix("Load"))
        XCTAssertEqual(requests, 2)
    }

    func testDialectReseedCancelsConsentAndRejectsTheOldRequestResult() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let pending = PendingLoads()
        fixture.loader.handler = { try await pending.load($0) }
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { pending.addresses.count == 1 }
        fixture.model.markdownDialect = .commonMark
        fixture.update()
        pending.finish(0, with: image())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        XCTAssertTrue(fixture.preview.imageControls.buttons[0].title.hasPrefix("Load"))
        XCTAssertEqual(pending.addresses.count, 1)
    }

    func testDeselectionDiscardsImagesAndPromotionAloneDoesNotReload() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        var requests = 0
        fixture.loader.handler = { _ in
            requests += 1
            return self.image()
        }
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
        fixture.model.newPage()
        fixture.update()
        XCTAssertFalse(fixture.preview.isSelectedPage)
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        fixture.preview.imageControls.buttons[0].performClick(nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 30, y: 12), modifierFlags: [],
            timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        fixture.preview.imageControls.buttons[0].mouseDown(with: click)
        fixture.update()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.model.selectedPageID, fixture.page)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
    }

    func testSourceReplacementAndPreviewRemovalDiscardLoadedImages() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        var requests = 0
        fixture.loader.handler = { _ in
            requests += 1
            return self.image()
        }
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
        fixture.model.syncDocument(sheet: fixture.page, runs: [.ink("![Replacement](\(Self.address))")])
        fixture.update()
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        XCTAssertTrue(fixture.preview.string.contains("Replacement"))
        XCTAssertTrue(fixture.preview.imageControls.buttons[0].title.hasPrefix("Load"))
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
        fixture.model.toggleMarkdownPreview(for: fixture.page)
        fixture.update()
        XCTAssertNil(fixture.preview.superview)
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        XCTAssertEqual(requests, 2)
    }

    func testNonownerCannotActivateAnOldPreviewOrInstallAnInflightResult() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let pending = PendingLoads()
        fixture.loader.handler = { try await pending.load($0) }
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { pending.addresses.count == 1 }
        let other: PresentationOwner = fixture.model.owner == .panel ? .editorWindow : .panel
        fixture.model.transferOwnership(to: other)
        pending.finish(0, with: image())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(fixture.preview.authorizeImageLoad())
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        XCTAssertFalse(fixture.preview.imageControls.buttons[0].isEnabled)
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(pending.addresses.count, 1)
    }

    func testExpiredPageRefusesANewLoadAndAnInflightResult() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let pending = PendingLoads()
        fixture.loader.handler = { try await pending.load($0) }
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { pending.addresses.count == 1 }
        let tab = try XCTUnwrap(fixture.model.tabs.first { $0.pageID == fixture.page }?.id)
        XCTAssertTrue(fixture.model.coreClient.setRung(tab: tab, rung: .oneHour))
        XCTAssertTrue(fixture.model.coreClient.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        pending.finish(0, with: image())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        XCTAssertFalse(fixture.preview.authorizeImageLoad())
        fixture.preview.imageControls.buttons.first?.performClick(nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(pending.addresses.count, 1)
        XCTAssertFalse(fixture.model.tabs.contains { $0.pageID == fixture.page })
    }

    func testLoadedImagesAndControlsDoNotEnterShownSelectionOrEnableDragging() async throws {
        let fixture = try fixture("before " + Self.markdown + " after")
        defer { fixture.window.close() }
        fixture.loader.handler = { _ in self.image() }
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
        fixture.preview.setSelectedRange(NSRange(location: 0, length: fixture.preview.string.utf16.count))
        let runs = fixture.preview.shownSelection().flatMap { $0 }
        let ink = runs.reduce(into: "") {
            if case .ink(let text) = $1 { $0 += text }
        }
        XCTAssertEqual(ink, "before A small image after\n")
        XCTAssertFalse(ink.contains("\u{FFFC}"))
        XCTAssertEqual(fixture.preview.draggingSessionsBegun, 0)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 30, y: 12), modifierFlags: [],
            timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertFalse(fixture.preview.dragSelection(with: event, offset: .zero, slideBack: false))
        XCTAssertEqual(fixture.preview.draggingSessionsBegun, 0)
    }

    func testFourActiveImagesLimitFurtherLoadsUntilOneIsCancelled() async throws {
        let fixture = try fixture((0..<5).map { "![image\($0)](\(Self.address))" }.joined(separator: "\n\n"))
        defer { fixture.window.close() }
        let pending = PendingLoads()
        fixture.loader.handler = { try await pending.load($0) }
        for index in 0..<4 { fixture.preview.imageControls.buttons[index].performClick(nil) }
        try await eventually { pending.addresses.count == 4 }
        XCTAssertFalse(fixture.preview.imageControls.buttons[4].isEnabled)
        fixture.preview.imageControls.buttons[4].performClick(nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(pending.addresses.count, 4)
        fixture.preview.imageControls.buttons[0].performClick(nil)
        XCTAssertTrue(fixture.preview.imageControls.buttons[4].isEnabled)
        fixture.preview.imageControls.buttons[4].performClick(nil)
        try await eventually { pending.addresses.count == 5 }
        for index in 0..<5 { pending.finish(index, with: image()) }
        try await eventually { fixture.preview.imageControls.loadedImageCount == 4 }
        XCTAssertTrue(fixture.preview.imageControls.buttons[0].title.hasPrefix("Load"))
        XCTAssertFalse(fixture.preview.imageControls.buttons[0].isEnabled)
    }

    func testControlBudgetKeepsRemainingAltTextWithoutMoreLoadRoutes() throws {
        let source = (0..<40).map { "![image\($0)](\(Self.address))" }.joined(separator: "\n\n")
        let fixture = try fixture(source)
        defer { fixture.window.close() }
        XCTAssertEqual(fixture.preview.imageControls.buttons.count, 32)
        for index in 0..<40 { XCTAssertTrue(fixture.preview.string.contains("image\(index)")) }
        XCTAssertEqual(self.source(in: fixture), source)
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
    }

    func testLoadedImagesRemeasureAndFitNormalAndTableWidths() async throws {
        let source = """
        # Image controls

        ![Landscape](https://example.com/landscape.png)

        <img alt="HTML image" src="https://example.com/second.png">

        ![Local image](file:///tmp/image.png)

        | Image | Description |
        | --- | --- |
        | ![Table image](https://example.com/table.png) | A bounded image |
        """
        let fixture = try fixture(source)
        defer { fixture.window.close() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 900, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4800, bitsPerPixel: 24))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<900 {
            for x in 0..<1600 {
                let offset = y * bitmap.bytesPerRow + x * 3
                pixels[offset] = UInt8(80 + x / 12)
                pixels[offset + 1] = UInt8(60 + y / 8)
                pixels[offset + 2] = 190
            }
        }
        let image = NSImage(size: NSSize(width: 1600, height: 900))
        image.addRepresentation(bitmap)
        fixture.loader.handler = { _ in image }
        let initialHeight = fixture.preview.frame.height
        fixture.preview.imageControls.buttons[0].performClick(nil)
        fixture.preview.imageControls.buttons[3].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 2 }
        try await eventually { fixture.preview.frame.height > initialHeight }
        let manager = try XCTUnwrap(fixture.preview.layoutManager)
        let container = try XCTUnwrap(fixture.preview.textContainer)
        let storage = try XCTUnwrap(fixture.preview.textStorage)
        for width: CGFloat in [320, 640] {
            fixture.window.setContentSize(NSSize(width: width, height: 900))
            fixture.scroll.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            fixture.update()
            let room = max(20, fixture.preview.bounds.width - fixture.preview.textContainerInset.width * 2 - 16)
            try await eventually {
                let pictures = self.loadedPictureBounds(in: fixture.preview)
                return pictures.count == 2 && abs(pictures[0].width - min(1600, room)) < 1
            }
            fixture.preview.layoutSubtreeIfNeeded()
            XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 2, "Resizing keeps the current image interaction")
            manager.ensureLayout(for: container)
            XCTAssertLessThanOrEqual(manager.usedRect(for: container).maxX, container.size.width + 1)
            storage.enumerateAttribute(.previewLoadedImage, in: NSRange(location: 0, length: storage.length)) {
                value, range, _ in
                guard value != nil else { return }
                let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
                XCTAssertLessThanOrEqual(attachment?.bounds.width ?? .infinity, width - 24)
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
                XCTAssertLessThanOrEqual(bounds.maxX, container.size.width + 1)
                XCTAssertEqual(bounds.width, attachment?.bounds.width ?? 0, accuracy: 1)
                let fragment = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                XCTAssertLessThanOrEqual(bounds.maxX, fragment.maxX + 1)
            }
            for button in fixture.preview.imageControls.buttons {
                XCTAssertGreaterThan(button.frame.height, 0)
                XCTAssertLessThanOrEqual(button.frame.maxX, fixture.preview.bounds.width + 1)
            }
            if let directory = ProcessInfo.processInfo.environment["PREVIEW_QA_ARTIFACTS"] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    fixture.preview.appearance = NSAppearance(named: appearance)
                    fixture.preview.drawsBackground = true
                    fixture.preview.backgroundColor = .textBackgroundColor
                    let bounds = fixture.preview.bounds
                    let output = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let representation = try XCTUnwrap(fixture.preview.bitmapImageRepForCachingDisplay(in: bounds))
                    fixture.preview.effectiveAppearance.performAsCurrentDrawingAppearance {
                        fixture.preview.cacheDisplay(in: bounds, to: representation)
                    }
                    try XCTUnwrap(representation.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent("image-controls-\(Int(width))-\(appearance.rawValue).png"))
                }
            }
        }
    }

    func testAnObjectInImageAltRetainsItsReferenceWhenTheImageLoads() async throws {
        let ink = "before ![image SECRET alt](\(Self.address)) after"
        let fixture = try fixture(ink)
        defer { fixture.window.close() }
        fixture.model.toggleMarkdownPreview(for: fixture.page)
        fixture.update()
        let editor = try XCTUnwrap(fixture.stack.editor)
        let range = (ink as NSString).range(of: "SECRET")
        editor.setSelectedRange(range)
        fixture.coordinator.sealSelectionOrLine()
        let chip = try XCTUnwrap(fixture.coordinator.chipAttachment(at: range.location)?.info.chipId)
        fixture.model.toggleMarkdownPreview(for: fixture.page)
        fixture.update()
        let preview = try XCTUnwrap(fixture.stack.previewRegions[fixture.page])
        fixture.loader.handler = { _ in self.image() }
        XCTAssertEqual(preview.imageControls.buttons.count, 1)
        preview.imageControls.buttons[0].performClick(nil)
        try await eventually { preview.imageControls.loadedImageCount == 1 }
        preview.setSelectedRange(NSRange(location: 0, length: preview.string.utf16.count))
        let runs = preview.shownSelection().flatMap { $0 }
        XCTAssertEqual(runs.filter { if case .chip = $0 { true } else { false } }, [.chip(chip)])
        let shownInk = runs.reduce(into: "") { if case .ink(let text) = $1 { $0 += text } }
        XCTAssertEqual(shownInk, "before image  alt after\n")
        XCTAssertFalse(shownInk.contains("SECRET"))
        XCTAssertFalse(shownInk.contains("\u{FFFC}"))
        guard case .composed(let fragment) = fixture.model.composeShownSelection([runs], sheet: fixture.page) else {
            return XCTFail("The loaded image changed the sealed-reference composition")
        }
        XCTAssertFalse(fragment.plainText.contains("SECRET"))
    }

    func testLoadingUnloadingAndResizingKeepTheTextStreamAndSelectionStable() async throws {
        let fixture = try fixture("before " + Self.markdown + " after")
        defer { fixture.window.close() }
        fixture.loader.handler = { _ in NSImage(size: NSSize(width: 800, height: 500)) }
        let storage = try XCTUnwrap(fixture.preview.textStorage)
        let original = storage.string
        let selection = (original as NSString).range(of: "after")
        let sentinel = NSAttributedString.Key("PreviewImageTestSentinel")
        storage.addAttribute(sentinel, value: "preserved", range: selection)
        fixture.preview.setSelectedRange(selection)
        let button = fixture.preview.imageControls.buttons[0]
        button.performClick(nil)
        XCTAssertEqual(storage.string, original)
        XCTAssertEqual(fixture.preview.selectedRange(), selection)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
        XCTAssertEqual(storage.string, original)
        XCTAssertEqual(fixture.preview.selectedRange(), selection)
        XCTAssertEqual(storage.attribute(sentinel, at: selection.location, effectiveRange: nil) as? String, "preserved")
        fixture.preview.setFrameSize(NSSize(width: 300, height: fixture.preview.frame.height))
        fixture.preview.layoutSubtreeIfNeeded()
        XCTAssertEqual(storage.string, original)
        XCTAssertEqual(fixture.preview.selectedRange(), selection)
        XCTAssertEqual(storage.attribute(sentinel, at: selection.location, effectiveRange: nil) as? String, "preserved")
        button.performClick(nil)
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        XCTAssertEqual(storage.string, original)
        XCTAssertEqual(fixture.preview.selectedRange(), selection)
        XCTAssertEqual(storage.attribute(sentinel, at: selection.location, effectiveRange: nil) as? String, "preserved")
        XCTAssertTrue(button === fixture.preview.imageControls.buttons[0])
    }

    func testLoadingAndUnloadingRestoreTheSamePreviewReadingLine() async throws {
        let lines = (0..<60).map { "line \($0) has enough text to recognize the reading position" }.joined(separator: "\n\n")
        let fixture = try fixture(Self.markdown + "\n\n" + lines)
        defer { fixture.window.close() }
        fixture.loader.handler = { _ in NSImage(size: NSSize(width: 500, height: 300)) }
        let preview = fixture.preview
        let manager = try XCTUnwrap(preview.layoutManager)
        let container = try XCTUnwrap(preview.textContainer)
        let index = (preview.string as NSString).range(of: "line 20 ").location
        XCTAssertNotEqual(index, NSNotFound)
        func lineYInClip() -> CGFloat {
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            return preview.frame.minY + preview.textContainerOrigin.y + bounds.minY
                - fixture.scroll.contentView.bounds.minY
        }
        let documentY = lineYInClip() + fixture.scroll.contentView.bounds.minY
        fixture.stack.scroll(toDocumentOffset: documentY + 2, animated: false)
        let place = try XCTUnwrap(fixture.stack.currentPlace)
        XCTAssertEqual(place.page, fixture.page)
        XCTAssertEqual(place.reading, .preview)
        let before = lineYInClip()
        let height = preview.frame.height
        let text = preview.string
        preview.imageControls.buttons[0].performClick(nil)
        try await eventually { preview.imageControls.loadedImageCount == 1 && preview.frame.height > height }
        XCTAssertEqual(preview.string, text)
        XCTAssertEqual(fixture.stack.currentPlace?.anchor.characterIndex, place.anchor.characterIndex)
        XCTAssertEqual(lineYInClip(), before, accuracy: 1)
        preview.imageControls.buttons[0].performClick(nil)
        try await eventually { abs(preview.frame.height - height) < 1 }
        XCTAssertEqual(preview.string, text)
        XCTAssertEqual(fixture.stack.currentPlace?.anchor.characterIndex, place.anchor.characterIndex)
        XCTAssertEqual(lineYInClip(), before, accuracy: 1)
    }

    func testPreserveConsentRechecksDestinationsEvenWhenTheAltTextIsUnchanged() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        fixture.loader.handler = { _ in self.image() }
        let preview = fixture.preview
        preview.imageControls.buttons[0].performClick(nil)
        try await eventually { preview.imageControls.loadedImageCount == 1 }
        let current = MarkdownPreviewView.render(NSAttributedString(string: Self.markdown))
        let changed = MarkdownPreviewView.render(NSAttributedString(
            string: "![A small image](https://other.example.org/new.png)"))
        XCTAssertEqual(current.string, changed.string)
        preview.imageControls.seed(changed, preserveConsent: true)
        XCTAssertEqual(preview.imageControls.loadedImageCount, 0)
        XCTAssertTrue(preview.imageControls.buttons[0].title.hasPrefix("Load"))
        XCTAssertTrue(preview.imageControls.buttons[0].title.contains("other.example.org"))
        XCTAssertEqual(fixture.loader.requests.count, 1)
        preview.imageControls.buttons[0].performClick(nil)
        try await eventually { preview.imageControls.loadedImageCount == 1 }
        XCTAssertEqual(fixture.loader.requests.map(\.absoluteString), [Self.address, "https://other.example.org/new.png"])
    }

    func testPreserveConsentRechecksImageRangesInAnUnchangedTextStream() async throws {
        let fixture = try fixture("a![same](\(Self.address))same")
        defer { fixture.window.close() }
        fixture.loader.handler = { _ in self.image() }
        let preview = fixture.preview
        preview.imageControls.buttons[0].performClick(nil)
        try await eventually { preview.imageControls.loadedImageCount == 1 }
        let first = MarkdownPreviewView.render(NSAttributedString(string: "a![same](\(Self.address))same"))
        let moved = MarkdownPreviewView.render(NSAttributedString(string: "asame![same](\(Self.address))"))
        XCTAssertEqual(first.string, moved.string)
        preview.imageControls.seed(moved, preserveConsent: true)
        XCTAssertEqual(preview.imageControls.loadedImageCount, 0)
        XCTAssertTrue(preview.imageControls.buttons[0].title.hasPrefix("Load"))
        XCTAssertEqual(fixture.loader.requests.count, 1)
    }


    func testDiscardRemeasuresTheMountedPreviewWithoutAnExplicitRollUpdate() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        fixture.loader.handler = { _ in NSImage(size: NSSize(width: 500, height: 500)) }
        let height = fixture.preview.frame.height
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 && fixture.preview.frame.height > height }
        fixture.preview.imageControls.discard()
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        try await eventually { abs(fixture.preview.frame.height - height) < 1 }
        XCTAssertEqual(fixture.loader.requests.count, 1)
    }

    func testExpiredImageActivationShowsTheExistingRefusalAndDisablesTheControl() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let button = fixture.preview.imageControls.buttons[0]
        XCTAssertTrue(button.isEnabled)
        let tab = try XCTUnwrap(fixture.model.tabs.first { $0.pageID == fixture.page }?.id)
        XCTAssertTrue(fixture.model.coreClient.setRung(tab: tab, rung: .oneHour))
        XCTAssertTrue(fixture.model.coreClient.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        fixture.model.notice = nil
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(fixture.loader.requests.isEmpty)
        XCTAssertEqual(fixture.model.notice, PageModel.pageExpiredLine)
        XCTAssertFalse(button.isEnabled)
        XCTAssertFalse(fixture.model.tabs.contains { $0.pageID == fixture.page })
    }

    func testALoaderThatCancelsItsOwnTaskReleasesItsImageReservation() async throws {
        let source = (0..<5).map { index in
            "![image\(index)](https://example.com/\(index == 3 ? "cancel" : String(index)).png)"
        }.joined(separator: "\n\n")
        let fixture = try fixture(source)
        defer { fixture.window.close() }
        let pending = PendingLoads()
        fixture.loader.handler = { url in
            if url.lastPathComponent == "cancel.png" {
                withUnsafeCurrentTask { $0?.cancel() }
                return self.image()
            }
            return try await pending.load(url)
        }
        for index in 0..<4 { fixture.preview.imageControls.buttons[index].performClick(nil) }
        XCTAssertFalse(fixture.preview.imageControls.buttons[4].isEnabled)
        try await eventually {
            fixture.loader.requests.count == 4
                && fixture.preview.imageControls.buttons[3].title.hasPrefix("Load")
                && fixture.preview.imageControls.buttons[4].isEnabled
        }
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
        fixture.preview.imageControls.buttons[4].performClick(nil)
        try await eventually { pending.addresses.count == 4 }
        for index in 0..<4 { pending.finish(index, with: image()) }
        try await eventually { fixture.preview.imageControls.loadedImageCount == 4 }
        XCTAssertEqual(fixture.loader.requests.count, 5)
        XCTAssertTrue(fixture.preview.imageControls.buttons[3].title.hasPrefix("Load"))
        XCTAssertFalse(fixture.preview.imageControls.buttons[3].isEnabled)
    }

    func testReentrantDiscardSchedulesACompletePresentationAfterTheCurrentPass() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        fixture.loader.handler = { _ in self.image() }
        let controls = fixture.preview.imageControls
        controls.buttons[0].performClick(nil)
        try await eventually { controls.loadedImageCount == 1 }
        let storage = try XCTUnwrap(fixture.preview.textStorage)
        let observer = PresentationReentry { controls.discard() }
        NotificationCenter.default.addObserver(
            observer, selector: #selector(PresentationReentry.updated(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: storage)
        defer { NotificationCenter.default.removeObserver(observer) }
        controls.resize()
        XCTAssertEqual(observer.calls, 0)
        try await eventually { observer.calls == 1 }
        try await eventually {
            guard controls.loadedImageCount == 0 else { return false }
            var loadedAttachment = false
            storage.enumerateAttribute(.previewLoadedImage, in: NSRange(location: 0, length: storage.length)) {
                value, _, _ in
                loadedAttachment = loadedAttachment || value != nil
            }
            return !loadedAttachment && controls.buttons[0].title.hasPrefix("Load")
        }
        XCTAssertEqual(fixture.loader.requests.count, 1)
    }


    func testResizeDefersStorageEditsUntilTheQueuedPresentation() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        fixture.loader.handler = { _ in NSImage(size: NSSize(width: 800, height: 400)) }
        fixture.preview.imageControls.buttons[0].performClick(nil)
        try await eventually { fixture.preview.imageControls.loadedImageCount == 1 }
        try await Task.sleep(for: .milliseconds(20))
        let storage = try XCTUnwrap(fixture.preview.textStorage)
        let observer = StorageEdits()
        NotificationCenter.default.addObserver(
            observer, selector: #selector(StorageEdits.updated(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: storage)
        defer { NotificationCenter.default.removeObserver(observer) }
        let before = loadedPictureBounds(in: fixture.preview)
        fixture.window.setContentSize(NSSize(width: 320, height: 320))
        fixture.scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        fixture.update()
        XCTAssertEqual(observer.calls, 0)
        XCTAssertEqual(loadedPictureBounds(in: fixture.preview), before)
        let room = max(20, fixture.preview.bounds.width - fixture.preview.textContainerInset.width * 2 - 16)
        try await eventually {
            guard let bounds = self.loadedPictureBounds(in: fixture.preview).first else { return false }
            return observer.calls > 0 && abs(bounds.width - room) < 1
        }
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 1)
        XCTAssertEqual(fixture.loader.requests.count, 1)
    }

    func testRetainedWindowCloseDiscardsImagesAndCancelsAnInflightResult() async throws {
        let fixture = try fixture(Self.markdown + "\n\n" + Self.markdown)
        defer { fixture.window.close() }
        let pending = PendingLoads()
        var calls = 0
        fixture.loader.handler = { url in
            calls += 1
            if calls == 1 { return self.image() }
            return try await pending.load(url)
        }
        let controls = fixture.preview.imageControls
        controls.buttons[0].performClick(nil)
        try await eventually { controls.loadedImageCount == 1 }
        controls.buttons[1].performClick(nil)
        try await eventually { pending.addresses.count == 1 }
        fixture.window.close()
        XCTAssertTrue(fixture.window.contentView === fixture.scroll)
        XCTAssertFalse(fixture.preview.isImagePresentationActive)
        XCTAssertEqual(controls.loadedImageCount, 0)
        XCTAssertTrue(controls.buttons.allSatisfy { !$0.isEnabled })
        pending.finish(0, with: image())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controls.loadedImageCount, 0)
        XCTAssertTrue(loadedPictureBounds(in: fixture.preview).isEmpty)
        controls.buttons[0].performClick(nil)
        XCTAssertEqual(fixture.loader.requests.count, 2)
    }

    func testLongAltTextIsCompleteInRenderedCopyAndBoundedInTheControlAnnouncement() throws {
        for alt in [String(repeating: "a", count: 400), "a" + String(repeating: "\u{0301}", count: 4_000)] {
            let fixture = try fixture("![\(alt)](\(Self.address))")
            defer { fixture.window.close() }
            let button = fixture.preview.imageControls.buttons[0]
            XCTAssertTrue(button.isEnabled)
            let spoken = try XCTUnwrap(button.accessibilityLabel())
            XCTAssertLessThan(spoken.utf16.count, 600)
            XCTAssertTrue(spoken.hasSuffix("…"))
            XCTAssertTrue(fixture.preview.string.contains(alt))
            fixture.preview.setSelectedRange(NSRange(location: 0, length: fixture.preview.string.utf16.count))
            let ink = fixture.preview.shownSelection().flatMap { $0 }.reduce(into: "") {
                if case .ink(let text) = $1 { $0 += text }
            }
            XCTAssertEqual(ink, alt + "\n")
            XCTAssertTrue(fixture.loader.requests.isEmpty)
        }
    }

    func testClearedStorageHidesTheOldControlAndRefusesItsAction() throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let button = fixture.preview.imageControls.buttons[0]
        XCTAssertFalse(button.isHidden)
        let storage = try XCTUnwrap(fixture.preview.textStorage)
        storage.setAttributedString(NSAttributedString(string: ""))
        fixture.preview.imageControls.layout()
        XCTAssertTrue(button.isHidden)
        button.performClick(nil)
        XCTAssertTrue(fixture.loader.requests.isEmpty)
        XCTAssertEqual(fixture.preview.imageControls.loadedImageCount, 0)
    }

}
