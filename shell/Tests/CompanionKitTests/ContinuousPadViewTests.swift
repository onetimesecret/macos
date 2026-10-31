import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class ContinuousPadViewTests: XCTestCase {
    private struct Surface {
        let window: NSWindow
        let scroll: NSScrollView
        let canvas: ContinuousPadCanvas
        let coordinator: InkEditorView.Coordinator
    }

    private func model(refusingCut: Bool = false) throws -> PageModel {
        let suite = "continuous-pad-view-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-pad-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = CompanionClient.ephemeral(tag: UUID().uuidString)
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { @MainActor in board.releaseGlobally() }
        let cutWriter: (@MainActor (SealedFragment, NSPasteboard) -> Bool)?
        if refusingCut {
            cutWriter = { (_: SealedFragment, _: NSPasteboard) -> Bool in false }
        } else {
            cutWriter = nil
        }
        let model = PageModel(formFactor: .backdrop, defaults: defaults, seams: .init(stateDirectory: directory,
            client: client, saveDebounce: 3_600, clearClipboardIfOurs: { false }, ambientPasteboard: board,
            writeCutFragment: cutWriter))
        model.showsTimeUnits = true
        return model
    }

    @discardableResult
    private func seed(_ text: String, in model: PageModel) throws -> UInt64 {
        let tab = model.coreClient.newTab()
        let page = try XCTUnwrap(model.coreClient.tabs().first { $0.id == tab }?.pageID)
        let data = try JSONSerialization.data(withJSONObject: [["ink": text]])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(model.coreClient.syncDocument(sheet: page, json: json))
        model.refresh()
        model.select(tab)
        return page
    }

    private func mount(_ model: PageModel, readOnly: Bool = false) throws -> Surface {
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = ContinuousPadView.makeSurface(model: model, coordinator: coordinator, readOnly: readOnly)
        let frame = NSRect(x: 0, y: 0, width: 520, height: 280)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll)
        scroll.frame = frame
        scroll.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(scroll.documentView as? ContinuousPadCanvas)
        canvas.measure()
        XCTAssertTrue(window.makeFirstResponder(canvas.editor))
        return Surface(window: window, scroll: scroll, canvas: canvas, coordinator: coordinator)
    }

    private func unmount(_ surface: Surface) {
        ContinuousPadView.dismantleNSView(surface.scroll, coordinator: surface.coordinator)
        surface.window.close()
    }

    private func body(_ page: UInt64, in model: PageModel) -> String {
        model.coreClient.documentRuns(sheet: page).map { run in
            switch run {
            case .ink(let text): return text
            case .chip: return "\u{fffc}"
            }
        }.joined()
    }

    private func metadataProjection(_ texts: [String], joined: Bool = false) -> ContinuousDocumentProjection {
        .init(pages: texts.enumerated().map { index, text in
            .init(id: UInt64(index + 1), uuid: "page-\(index + 1)", text: text,
                  joinedNextUUID: joined && index + 1 < texts.count ? "page-\(index + 2)" : nil)
        })
    }

    private func editedBlock(_ id: String, created: Int64, modified: Int64, paragraphs: Int = 1) -> BlockInfo {
        .init(id: id, createdS: created, modifiedS: modified, paragraphs: paragraphs)
    }

    func testContinuousBlockMetadataOffsetsPastBlankSeparatorAndUnicode() throws {
        let projection = metadataProjection(["😀first\n", "🦊second"])
        let metas = projection.blockMetas { page in
            [editedBlock("block-\(page)", created: Int64(page) * 1_000, modified: Int64(page) * 3_000)]
        }
        XCTAssertEqual(metas.map(\.paragraphs), [1, 1, 1])
        XCTAssertEqual(metas.map(\.createdS), [1_000, nil, 2_000])
        XCTAssertEqual(metas.map(\.modifiedS), [3_000, nil, 6_000])
        let storage = NSTextStorage(string: projection.text)
        let result = InkEditorView.Coordinator.applyMarkdownStyling(to: storage, blockMetas: metas,
            syntaxHighlightingEnabled: false, fenceRenderingLanguages: [:])
        XCTAssertEqual(result.displays.map(\.range), [
            NSRange(location: 0, length: 8), NSRange(location: 9, length: 8),
        ])
        XCTAssertTrue(result.displays.allSatisfy { $0.compactText == "edited" })
        XCTAssertTrue(result.displays.allSatisfy { $0.accessibilityText.contains("; edited ") })
    }

    func testContinuousJoinedParagraphCombinesStampsWithoutShiftingLaterBlock() {
        let projection = metadataProjection(["first", "second\nthird"], joined: true)
        let metas = projection.blockMetas { page in
            page == 1 ? [editedBlock("first", created: 1_000, modified: 3_000)] : [
                editedBlock("second", created: 2_000, modified: 4_000),
                editedBlock("third", created: 5_000, modified: 6_000),
            ]
        }
        XCTAssertEqual(metas.map(\.paragraphs), [1, 1])
        XCTAssertEqual(metas.map(\.createdS), [1_000, 5_000])
        XCTAssertEqual(metas.map(\.modifiedS), [4_000, 6_000])
        let result = InkEditorView.Coordinator.applyMarkdownStyling(
            to: NSTextStorage(string: projection.text), blockMetas: metas,
            syntaxHighlightingEnabled: false, fenceRenderingLanguages: [:])
        XCTAssertEqual(result.displays.map(\.logicalRange), [
            NSRange(location: 0, length: 12), NSRange(location: 12, length: 5),
        ])
    }

    func testContinuousJoinedMultilineBlockRetainsItsFullLogicalExtent() {
        let projection = metadataProjection(["first\nsecond", "third\nlast"], joined: true)
        let metas = projection.blockMetas { page in
            page == 1 ? [editedBlock("paste", created: 1_000, modified: 3_000, paragraphs: 2)] : [
                editedBlock("third", created: 2_000, modified: 4_000),
                editedBlock("last", created: 5_000, modified: 6_000),
            ]
        }
        XCTAssertEqual(metas.map(\.paragraphs), [2, 1])
        XCTAssertEqual(metas.map(\.createdS), [1_000, 5_000])
        XCTAssertEqual(metas.map(\.modifiedS), [4_000, 6_000])
        let result = InkEditorView.Coordinator.applyMarkdownStyling(
            to: NSTextStorage(string: projection.text), blockMetas: metas,
            syntaxHighlightingEnabled: false, fenceRenderingLanguages: [:])
        XCTAssertEqual(result.displays.map(\.logicalRange), [
            NSRange(location: 0, length: 18), NSRange(location: 18, length: 4),
        ])
    }

    func testContinuousEmptyCheckpointDoesNotConsumeAnotherPagesMetadata() {
        for joined in [false, true] {
            let projection = metadataProjection(["first", "", "third"], joined: joined)
            let metas = projection.blockMetas { page in
                [editedBlock("block-\(page)", created: Int64(page) * 1_000, modified: Int64(page) * 3_000)]
            }
            XCTAssertEqual(metas.map(\.paragraphs), joined ? [1] : [1, 1, 1])
            XCTAssertEqual(metas.map(\.createdS), joined ? [1_000] : [1_000, nil, 3_000])
            XCTAssertEqual(metas.map(\.modifiedS), joined ? [9_000] : [3_000, nil, 9_000])
            let result = InkEditorView.Coordinator.applyMarkdownStyling(
                to: NSTextStorage(string: projection.text), blockMetas: metas,
                syntaxHighlightingEnabled: false, fenceRenderingLanguages: [:])
            XCTAssertEqual(result.displays.map(\.range.location), joined ? [0] : [0, 7])
        }
    }

    func testContinuousBlockMetadataReadsCoreAndExposesBothCheckpointAccessibilityLabels() throws {
        let model = try model()
        _ = try seed("first", in: model)
        _ = try seed("second", in: model)
        let surface = try mount(model)
        let document = surface.canvas.document
        XCTAssertEqual(document.blockMetas, document.projection.blockMetas {
            model.coreClient.blocks(sheet: $0)
        })
        XCTAssertEqual(document.blockMetas.count, 2)
        let textNavigationChild = NSView(frame: .zero)
        surface.canvas.editor.setAccessibilityChildren([textNavigationChild])
        let metas = document.projection.blockMetas { page in
            [editedBlock("block-\(page)", created: 1_000, modified: 300_000)]
        }
        surface.coordinator.layOutBlockLabels(forMetas: metas)
        XCTAssertEqual(surface.coordinator.blockLabelLayout.map(\.range.location), [0, 6])
        let fields = surface.canvas.editor.subviews.compactMap { $0 as? BlockMetadataField }
        XCTAssertEqual(fields.count, 2)
        let children = surface.canvas.editor.accessibilityChildren() ?? []
        XCTAssertTrue(children.contains { ($0 as AnyObject) === textNavigationChild })
        for field in fields {
            XCTAssertTrue(children.contains { ($0 as AnyObject) === field })
            XCTAssertTrue(field.accessibilityLabel()?.hasPrefix("Created ") == true)
            XCTAssertTrue(field.accessibilityLabel()?.contains("; edited ") == true)
        }
        let firstPage = try XCTUnwrap(document.projection.pages.first?.id)
        XCTAssertTrue(model.coreClient.applyOps(sheet: firstPage,
            json: #"[{"ins":{"at":0,"text":"prefix\n"}}]"#))
        XCTAssertTrue(document.refresh())
        XCTAssertEqual(document.blockMetas, document.projection.blockMetas {
            model.coreClient.blocks(sheet: $0)
        })
        XCTAssertEqual(document.blockMetas.reduce(0) { $0 + $1.paragraphs }, 3)
        unmount(surface)
        XCTAssertTrue(document.blockMetas.isEmpty)
    }

    func testOneStorageSupportsNativeSelectionAndMovementAcrossCheckpoint() throws {
        let model = try model()
        _ = try seed("first line", in: model)
        _ = try seed("second line", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let storage = try XCTUnwrap(editor.textStorage)
        let segments = surface.canvas.document.projection.segments
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(surface.canvas.subviews.compactMap { $0 as? InkTextView }.count, 1)
        XCTAssertTrue(model.activeEditor === editor)
        XCTAssertTrue(storage === surface.canvas.document.storage)
        XCTAssertNil(surface.coordinator.currentSheet)
        let edge = try XCTUnwrap(segments[0].separatorRange)
        editor.setSelectedRange(NSRange(location: edge.location, length: 0))
        editor.moveRight(nil)
        XCTAssertEqual(editor.selectedRange().location, segments[1].bodyRange.location)
        XCTAssertEqual(model.selectedPageID, segments[1].page.id)
        editor.moveLeftAndModifySelection(nil)
        XCTAssertEqual(editor.selectedRange(), edge)
        editor.selectAll(nil)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: storage.length))
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertEqual(editor.string, surface.canvas.document.projection.text)
        XCTAssertFalse(surface.canvas.checkpointLabels.isEmpty)
        XCTAssertTrue(surface.canvas.checkpointLabels.allSatisfy {
            !$0.stringValue.contains("first line") && !$0.stringValue.contains("second line")
        })
    }

    func testRailSelectionScrollsSameEditorAndReadOnlyChangesInPlace() throws {
        let model = try model()
        _ = try seed(String(repeating: "a line\n", count: 50), in: model)
        _ = try seed("last checkpoint", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let last = try XCTUnwrap(surface.canvas.document.projection.segments.last)
        let first = try XCTUnwrap(surface.canvas.document.projection.segments.first)
        surface.canvas.open(page: first.page.id)
        let tab = try XCTUnwrap(model.tabs.first { $0.pageID == last.page.id })
        model.select(tab.id)
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: true,
            coordinator: surface.coordinator)
        XCTAssertEqual(editor.selectedRange().location, last.bodyRange.location)
        XCTAssertFalse(editor.isEditable)
        XCTAssertGreaterThan(surface.scroll.contentView.bounds.minY, 0)
        XCTAssertTrue(surface.canvas.editor === editor)
        XCTAssertEqual(Set(surface.canvas.extents.compactMap(\.page)), Set([first.page.id, last.page.id]))
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: false,
            coordinator: surface.coordinator)
        XCTAssertTrue(editor.isEditable)
    }

    func testWrappingAndHorizontalOffsetUseSameContinuousStorage() throws {
        let model = try model()
        _ = try seed(String(repeating: "word ", count: 100), in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let storage = surface.canvas.editor.textStorage
        XCTAssertFalse(surface.scroll.hasHorizontalScroller)
        model.wrapsLines = false
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: false,
            coordinator: surface.coordinator)
        XCTAssertTrue(surface.scroll.hasHorizontalScroller)
        XCTAssertGreaterThan(surface.canvas.frame.width, surface.scroll.contentSize.width)
        surface.canvas.scroll(to: NSPoint(x: 50, y: 0))
        XCTAssertGreaterThan(surface.scroll.contentView.bounds.minX, 0)
        model.wrapsLines = true
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: false,
            coordinator: surface.coordinator)
        XCTAssertFalse(surface.scroll.hasHorizontalScroller)
        XCTAssertEqual(surface.scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertTrue(surface.canvas.editor.textStorage === storage)
        XCTAssertEqual(surface.canvas.frame.width, surface.scroll.contentSize.width, accuracy: 0.5)
    }

    func testRemountRestoresCrossPageSelectionAndLocalReadingAnchor() throws {
        let model = try model()
        _ = try seed(String(repeating: "first\n", count: 40), in: model)
        _ = try seed(String(repeating: "second\n", count: 40), in: model)
        let first = try mount(model)
        let document = first.canvas.document
        let boundary = try XCTUnwrap(document.projection.segments.first?.separatorRange?.location)
        let selection = NSRange(location: boundary - 2, length: 5)
        first.canvas.editor.setSelectedRange(selection)
        first.canvas.scroll(to: NSPoint(x: 0, y: 150))
        let place = try XCTUnwrap(first.canvas.readingPlace)
        first.canvas.savePosition()
        unmount(first)
        let second = try mount(model)
        defer { unmount(second) }
        XCTAssertTrue(second.canvas.document === document)
        XCTAssertEqual(second.canvas.editor.selectedRange(), selection)
        XCTAssertEqual(second.canvas.readingPlace?.page, place.page)
        XCTAssertEqual(second.canvas.readingPlace?.anchor.characterIndex, place.anchor.characterIndex)
    }

    func testPadSwitchKeepsEditorAndRestoresEachDocumentsSelection() throws {
        let model = try model()
        model.pads.isEnabled = true
        _ = try seed("scratch words", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let scratch = surface.canvas.document
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        let otherPad = try XCTUnwrap(model.createPad(named: "Other"))
        model.newPage()
        let otherPage = try XCTUnwrap(model.selectedPageID)
        XCTAssertTrue(model.coreClient.syncDocument(sheet: otherPage, json: "[{\"ink\":\"other words\"}]"))
        model.refresh()
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: false,
            coordinator: surface.coordinator)
        let other = surface.canvas.document
        XCTAssertTrue(surface.canvas.editor === editor)
        XCTAssertFalse(other === scratch)
        XCTAssertEqual(surface.canvas.padID, otherPad)
        XCTAssertEqual(editor.string, "other words")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        model.activatePad(PadCatalog.scratchID)
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: false,
            coordinator: surface.coordinator)
        XCTAssertTrue(surface.canvas.document === scratch)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
        XCTAssertEqual(editor.string, "scratch words")
        model.activatePad(otherPad)
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: false,
            coordinator: surface.coordinator)
        XCTAssertTrue(surface.canvas.document === other)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testSuspendedSelectionFollowsItsCheckpointAfterEarlierContentChanges() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let first = try mount(model)
        let segments = first.canvas.document.projection.segments
        let selected = NSRange(location: segments[1].bodyRange.location + 1, length: 3)
        first.canvas.editor.setSelectedRange(selected)
        unmount(first)
        XCTAssertTrue(model.coreClient.applyOps(sheet: segments[0].page.id,
            json: #"[{"ins":{"at":0,"text":"new "}}]"#))
        model.refresh()
        let second = try mount(model)
        XCTAssertEqual(second.canvas.editor.selectedRange(), NSRange(location: selected.location + 4, length: 3))
        XCTAssertEqual((second.canvas.editor.string as NSString).substring(with: second.canvas.editor.selectedRange()), "rav")
        unmount(second)
        XCTAssertTrue(model.coreClient.syncDocument(sheet: segments[1].page.id, json: #"[{"ink":"br"}]"#))
        model.refresh()
        let third = try mount(model)
        defer { unmount(third) }
        XCTAssertEqual(third.canvas.editor.selectedRange(), NSRange(location: selected.location + 4, length: 1))
    }

    func testNativeReplacementSpanningCheckpointsUsesOneUndoAndRedo() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let segments = surface.canvas.document.projection.segments
        let original = editor.string
        let before = NSRange(location: 2, length: segments[1].bodyRange.location)
        let after = NSRange(location: 3, length: 0)
        editor.setSelectedRange(before)
        editor.insertText("X", replacementRange: before)
        XCTAssertEqual(editor.string, (original as NSString).replacingCharacters(in: before, with: "X"))
        XCTAssertEqual(body(segments[0].page.id, in: model), (segments[0].page.text as NSString).substring(to: 2) + "X")
        XCTAssertEqual(body(segments[1].page.id, in: model), (segments[1].page.text as NSString).substring(from: 2))
        XCTAssertEqual(editor.selectedRange(), after)
        editor.undo(nil)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.selectedRange(), before)
        for segment in segments { XCTAssertEqual(body(segment.page.id, in: model), segment.page.text) }
        editor.redo(nil)
        XCTAssertEqual(editor.string, (original as NSString).replacingCharacters(in: before, with: "X"))
        XCTAssertEqual(editor.selectedRange(), after)
    }

    func testNativeSeparatorDeletionSurvivesRemountAndShiftSelectionCrossesJoinedEdge() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let first = try mount(model)
        let segments = first.canvas.document.projection.segments
        let edge = try XCTUnwrap(segments[0].separatorRange)
        let expected = segments.map(\.page.text).joined()
        first.canvas.editor.setSelectedRange(edge)
        first.canvas.editor.deleteBackward(nil)
        XCTAssertEqual(first.canvas.editor.string, expected)
        XCTAssertEqual(model.coreClient.continuousJoinNext(sheet: segments[0].page.id), segments[1].page.uuid)
        ContinuousPadView.updateSurface(first.scroll, model: model, readOnly: false, coordinator: first.coordinator)
        XCTAssertEqual(first.canvas.editor.string, expected)
        unmount(first)
        let second = try mount(model)
        defer { unmount(second) }
        XCTAssertEqual(second.canvas.editor.string, expected)
        let editor = second.canvas.editor
        editor.setSelectedRange(NSRange(location: edge.location - 1, length: 0))
        editor.moveRightAndModifySelection(nil)
        editor.moveRightAndModifySelection(nil)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: edge.location - 1, length: 2))
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()),
            String(segments[0].page.text.suffix(1)) + String(segments[1].page.text.prefix(1)))
    }

    func testNativeCopyAndCutAllUseInjectedBoardAndOneUndoRestoresBothPages() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let original = editor.string
        let pages = surface.canvas.document.projection.pages
        editor.selectAll(nil)
        let selection = editor.selectedRange()
        editor.copy(nil)
        XCTAssertEqual(model.ambientPasteboard.string(forType: .string), original)
        editor.cut(nil)
        XCTAssertEqual(model.ambientPasteboard.string(forType: .string), original)
        XCTAssertEqual(editor.string, "")
        for page in pages { XCTAssertEqual(body(page.id, in: model), "") }
        editor.undo(nil)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.selectedRange(), selection)
        for page in pages { XCTAssertEqual(body(page.id, in: model), page.text) }
    }

    func testCheckpointCreationUsesLocalCaretOnSecondPage() throws {
        let model = try model()
        _ = try seed("first checkpoint", in: model)
        _ = try seed("second checkpoint", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let segments = surface.canvas.document.projection.segments
        let first = segments[0]
        let second = segments[1]
        let original = surface.canvas.editor.string
        surface.canvas.editor.setSelectedRange(NSRange(location: second.bodyRange.location + 3, length: 0))
        XCTAssertEqual(model.selectedPageID, second.page.id)
        let existing = Set(model.tabs.compactMap(\.pageID))
        model.newPage()
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: false,
            coordinator: surface.coordinator)
        let created = try XCTUnwrap(Set(model.tabs.compactMap(\.pageID)).subtracting(existing).first)
        XCTAssertEqual(body(first.page.id, in: model), first.page.text)
        XCTAssertEqual(body(second.page.id, in: model), (second.page.text as NSString).substring(to: 3))
        XCTAssertEqual(body(created, in: model), (second.page.text as NSString).substring(from: 3))
        XCTAssertEqual(surface.canvas.document.projection.pages.count, 3)
        XCTAssertEqual(surface.canvas.editor.string, original)
    }

    func testSealingSelectionOnSecondPageUsesItsLocalOffset() throws {
        let model = try model()
        _ = try seed("first checkpoint", in: model)
        _ = try seed("second checkpoint", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let segments = surface.canvas.document.projection.segments
        let first = segments[0]
        let second = segments[1]
        let local = NSRange(location: 2, length: 4)
        let selected = NSRange(location: second.bodyRange.location + local.location, length: local.length)
        surface.canvas.editor.setSelectedRange(selected)
        surface.canvas.editor.sealSelectedContent(nil)
        XCTAssertEqual(body(first.page.id, in: model), first.page.text)
        XCTAssertEqual(body(second.page.id, in: model), (second.page.text as NSString).replacingCharacters(in: local, with: "\u{fffc}"))
        XCTAssertNotNil(surface.canvas.editor.textStorage?.attribute(.attachment,
            at: selected.location, effectiveRange: nil) as? ChipAttachment)
        XCTAssertEqual(surface.canvas.editor.selectedRange(), NSRange(location: selected.location, length: 1))
        XCTAssertEqual(surface.canvas.editor.string, surface.canvas.document.projection.text)
    }

    func testSealMenuExcludesSelectionSpanningCheckpoints() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let edge = try XCTUnwrap(surface.canvas.document.projection.segments[0].separatorRange)
        surface.canvas.editor.setSelectedRange(NSRange(location: edge.location - 1, length: 3))
        XCTAssertNil(surface.coordinator.sealableSelection())
        let menu = NSMenu()
        surface.coordinator.appendSealItem(to: menu)
        XCTAssertEqual(menu.numberOfItems, 0)
        let local = NSRange(location: 0, length: 2)
        surface.canvas.editor.setSelectedRange(local)
        XCTAssertEqual(surface.coordinator.sealableSelection(), local)
    }

    func testLanguageAvailabilityUsesCurrentFenceClassificationAndIncludesOpenFenceEnd() throws {
        let model = try model()
        _ = try seed("first checkpoint", in: model)
        _ = try seed("plain second checkpoint", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let storage = try XCTUnwrap(editor.textStorage)
        editor.setSelectedRange(NSRange(location: storage.length, length: 0))
        XCTAssertFalse(surface.coordinator.manualLanguageTargetAvailable)

        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\n```\nlet value = 1")
        editor.setSelectedRange(NSRange(location: storage.length, length: 0))
        XCTAssertTrue(surface.coordinator.manualLanguageTargetAvailable)
        editor.didChangeText()
        XCTAssertTrue(surface.coordinator.manualLanguageTargetAvailable)

        let opening = (editor.string as NSString).range(of: "```")
        XCTAssertNotEqual(opening.location, NSNotFound)
        storage.replaceCharacters(in: opening, with: "plain")
        editor.setSelectedRange(NSRange(location: storage.length, length: 0))
        XCTAssertFalse(surface.coordinator.manualLanguageTargetAvailable)
        editor.didChangeText()
        XCTAssertFalse(surface.coordinator.manualLanguageTargetAvailable)

        editor.insertText("\n```\nvalue\n```\nafter", replacementRange: editor.selectedRange())
        XCTAssertFalse(surface.coordinator.manualLanguageTargetAvailable)
    }

    func testStaleCheckpointCannotSealIntoCurrentlySelectedPage() throws {
        let model = try model()
        model.pads.isEnabled = true
        let other = try XCTUnwrap(model.createPad(named: "Other"))
        model.activatePad(PadCatalog.scratchID)
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let pages = surface.canvas.document.projection.pages
        let firstTab = try XCTUnwrap(model.tabs.first { $0.pageID == pages[0].id })
        model.pads.onChange = nil
        model.pads.assign(tabUUID: try XCTUnwrap(firstTab.uuid), to: other)
        model.selectContinuousPage(pages[1].id)
        surface.canvas.editor.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertEqual(model.sealTarget, pages[1].id)
        surface.canvas.editor.sealSelectedContent(nil)
        for page in pages { XCTAssertEqual(body(page.id, in: model), page.text) }
        XCTAssertEqual(model.notice, "this checkpoint is no longer available")
    }

    func testDiscontiguousCopyAndCutExplainRefusalWithoutChangingClipboardOrPages() throws {
        let model = try model()
        _ = try seed("first", in: model)
        _ = try seed("second", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let segments = surface.canvas.document.projection.segments
        let original = editor.string
        let ranges = [NSRange(location: 0, length: 2),
                      NSRange(location: segments[1].bodyRange.location + 1, length: 2)]
        editor.selectedRanges = ranges.map { NSValue(range: $0) }
        model.ambientPasteboard.clearContents()
        XCTAssertTrue(model.ambientPasteboard.setString("previous clipboard", forType: .string))
        let clipboardVersion = model.ambientPasteboard.changeCount
        editor.copy(nil)
        XCTAssertEqual(model.notice, PageModel.severalStretchesLine)
        editor.cut(nil)
        XCTAssertEqual(model.notice, PageModel.severalStretchesCutLine)
        XCTAssertEqual(model.ambientPasteboard.changeCount, clipboardVersion)
        XCTAssertEqual(model.ambientPasteboard.string(forType: .string), "previous clipboard")
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.selectedRanges.map(\.rangeValue), ranges)
        for segment in segments { XCTAssertEqual(body(segment.page.id, in: model), segment.page.text) }
    }

    func testResplittingIntoAnEmptyJoinedCheckpointPreservesItsFollowingJoin() throws {
        let model = try model()
        _ = try seed("abcdef", in: model)
        _ = try seed("", in: model)
        _ = try seed("third", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let document = surface.canvas.document
        let editor = surface.canvas.editor
        let pages = document.projection.pages
        editor.setSelectedRange(NSRange(location: 6, length: 2))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "abcdefthird")
        XCTAssertTrue(document.splitCheckpoint(source: pages[0].id, at: 3, destination: pages[1].id))
        XCTAssertEqual(body(pages[0].id, in: model), "abc")
        XCTAssertEqual(body(pages[1].id, in: model), "def")
        XCTAssertEqual(document.projection.pages[1].joinedNextUUID, pages[2].uuid)
        editor.setSelectedRange(document.projection.segments[1].bodyRange)
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "abcthird")
        XCTAssertTrue(document.splitCheckpoint(source: pages[0].id, at: 1, destination: pages[1].id))
        XCTAssertEqual(body(pages[0].id, in: model), "a")
        XCTAssertEqual(body(pages[1].id, in: model), "bc")
        XCTAssertEqual(body(pages[2].id, in: model), "third")
        XCTAssertEqual(editor.string, "abcthird")
        XCTAssertEqual(document.projection.pages[0].joinedNextUUID, pages[1].uuid)
        XCTAssertEqual(document.projection.pages[1].joinedNextUUID, pages[2].uuid)
    }

    func testContinuousFenceLanguageSurvivesRemountAndEarlierPageEdits() throws {
        let model = try model()
        model.syntaxHighlightingEnabled = true
        model.previewRendering = .allPages
        _ = try seed("intro", in: model)
        _ = try seed("```\nlet value = 1\n```", in: model)
        let first = try mount(model)
        let pages = first.canvas.document.projection.pages
        let fenceStart = first.canvas.document.projection.segments[1].bodyRange.location
        first.canvas.editor.setSelectedRange(NSRange(location: fenceStart + 5, length: 0))
        first.coordinator.applyManualLanguage("swift")
        XCTAssertEqual(model.fenceRenderingLanguages(for: pages[1].id), [0: "swift"])
        XCTAssertTrue(model.fenceRenderingLanguages(for: pages[0].id).isEmpty)
        unmount(first)
        let second = try mount(model)
        defer { unmount(second) }
        let editor = second.canvas.editor
        func keywordColor() -> NSColor? {
            let start = second.canvas.document.projection.segments[1].bodyRange.location
            return editor.textStorage?.attribute(.foregroundColor, at: start + 4,
                                                  effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(model.fenceRenderingLanguages(for: pages[1].id), [0: "swift"])
        XCTAssertEqual(keywordColor(), InkStyle.tokenColor(.keyword))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("new\n", replacementRange: editor.selectedRange())
        XCTAssertEqual(second.canvas.document.projection.segments[1].bodyRange.location, fenceStart + 4)
        XCTAssertEqual(model.fenceRenderingLanguages(for: pages[1].id), [0: "swift"])
        XCTAssertEqual(keywordColor(), InkStyle.tokenColor(.keyword))
        let codeEnd = NSMaxRange(second.canvas.document.projection.segments[1].bodyRange)
        editor.setSelectedRange(NSRange(location: codeEnd, length: 0))
        editor.insertText("\n", replacementRange: editor.selectedRange())
        XCTAssertTrue(model.fenceRenderingLanguages(for: pages[1].id).isEmpty)
        XCTAssertNotEqual(keywordColor(), InkStyle.tokenColor(.keyword))
    }

    func testTypingAfterASealCanBeUndoneWithoutReversingTheSeal() throws {
        let model = try model()
        _ = try seed("first", in: model)
        _ = try seed("second secret", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let second = surface.canvas.document.projection.segments[1]
        editor.setSelectedRange(NSRange(location: second.bodyRange.location + 7, length: 6))
        editor.sealSelectedContent(nil)
        let sealedText = editor.string
        XCTAssertEqual(body(second.page.id, in: model), "second \u{fffc}")
        editor.setSelectedRange(NSRange(location: sealedText.utf16.count, length: 0))
        editor.insertText(" after", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, sealedText + " after")
        editor.undo(nil)
        XCTAssertEqual(editor.string, sealedText)
        XCTAssertEqual(body(second.page.id, in: model), "second \u{fffc}")
    }

    func testTabDragAppendsToExplicitCheckpointAtJoinedBoundary() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let segments = surface.canvas.document.projection.segments
        let editor = surface.canvas.editor
        editor.setSelectedRange(try XCTUnwrap(segments[0].separatorRange))
        editor.deleteBackward(nil)
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        guard case .fragment(let item) = surface.coordinator.beginPageDrag() else {
            return XCTFail("The prefix did not produce a drag fragment.")
        }
        defer { surface.coordinator.endPageDrag() }
        XCTAssertTrue(model.ambientPasteboard.writeObjects([item]))
        let slot = try XCTUnwrap(model.tabs.first { $0.pageID == segments[0].page.id }?.id)
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: model.owner)
        let drop = DraggingInfoStub(pasteboard: model.ambientPasteboard, source: editor,
            location: .zero, window: surface.window, mask: .move)
        XCTAssertEqual(target.operation(for: drop), .move)
        XCTAssertTrue(target.performDragOperation(drop))
        XCTAssertEqual(body(segments[0].page.id, in: model), "phaal")
        XCTAssertEqual(body(segments[1].page.id, in: model), "bravo")
        editor.undo(nil)
        XCTAssertEqual(body(segments[0].page.id, in: model), "alpha")
        XCTAssertEqual(body(segments[1].page.id, in: model), "bravo")
    }

    func testTabFragmentDropAppendsToExplicitCheckpointAtJoinedBoundary() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let segments = surface.canvas.document.projection.segments
        let editor = surface.canvas.editor
        editor.setSelectedRange(try XCTUnwrap(segments[0].separatorRange))
        editor.deleteBackward(nil)
        editor.setSelectedRange(NSRange(location: segments[0].bodyRange.length, length: 1))
        editor.sealSelectedContent(nil)
        let sourceText = body(segments[1].page.id, in: model)
        editor.setSelectedRange(NSRange(location: segments[0].bodyRange.length, length: 2))
        XCTAssertTrue(surface.coordinator.copySelection())
        XCTAssertNotNil(SealedFragment.item(on: model.ambientPasteboard))
        let slot = try XCTUnwrap(model.tabs.first { $0.pageID == segments[0].page.id }?.id)
        let target = TabDropTarget(model: model, slot: slot, readOnly: false, surface: model.owner)
        let drop = DraggingInfoStub(pasteboard: model.ambientPasteboard, source: nil,
            location: .zero, window: surface.window, mask: .copy)
        XCTAssertEqual(target.dropRoute(for: drop), .fragment)
        XCTAssertEqual(target.operation(for: drop), .copy)
        XCTAssertTrue(target.performDragOperation(drop))
        XCTAssertEqual(body(segments[0].page.id, in: model), "alpha\u{fffc}r")
        XCTAssertEqual(body(segments[1].page.id, in: model), sourceText)
        editor.undo(nil)
        XCTAssertEqual(body(segments[0].page.id, in: model), "alpha")
        XCTAssertEqual(body(segments[1].page.id, in: model), sourceText)
    }

    func testCheckpointSplitAfterJoinedNeighborWasRemoved() throws {
        let model = try model()
        _ = try seed("first checkpoint", in: model)
        _ = try seed("second checkpoint", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let segments = surface.canvas.document.projection.segments
        surface.canvas.editor.setSelectedRange(try XCTUnwrap(segments[0].separatorRange))
        surface.canvas.editor.deleteBackward(nil)
        let removedTab = try XCTUnwrap(model.tabs.first { $0.pageID == segments[1].page.id })
        XCTAssertTrue(model.coreClient.closeTab(id: removedTab.id))
        model.refresh()
        let original = surface.canvas.editor.string
        surface.canvas.editor.setSelectedRange(NSRange(location: 3, length: 0))
        model.newPage()
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: false,
            coordinator: surface.coordinator)
        XCTAssertEqual(surface.canvas.document.projection.pages.count, 2)
        XCTAssertEqual(body(segments[0].page.id, in: model), String(original.prefix(3)))
        XCTAssertEqual(surface.canvas.editor.string, original)
    }

    func testPageUndoAfterContinuousEditRestoresEveryCheckpointAndCanRedo() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        let pages = surface.canvas.document.projection.pages
        let original = surface.canvas.editor.string
        surface.canvas.editor.setSelectedRange(NSRange(location: 2, length: 6))
        surface.canvas.editor.insertText("X", replacementRange: surface.canvas.editor.selectedRange())
        let edited = surface.canvas.editor.string
        let editedSelection = surface.canvas.editor.selectedRange()
        unmount(surface)
        XCTAssertTrue(model.undoEdit(sheet: pages[0].id).applied)
        XCTAssertEqual(body(pages[0].id, in: model), pages[0].text)
        XCTAssertEqual(body(pages[1].id, in: model), pages[1].text)
        XCTAssertTrue(model.redoEdit(sheet: pages[0].id).applied)
        let remounted = try mount(model)
        defer { unmount(remounted) }
        XCTAssertNotEqual(original, edited)
        XCTAssertEqual(remounted.canvas.editor.string, edited)
        XCTAssertEqual(remounted.canvas.editor.selectedRange(), editedSelection)
    }

    func testSurfaceRefreshKeepsSelectionRebasedAfterEarlierPageChanges() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let first = surface.canvas.document.projection.pages[0].id
        let caret = surface.canvas.editor.string.utf16.count
        surface.canvas.editor.setSelectedRange(NSRange(location: caret, length: 0))
        XCTAssertTrue(model.coreClient.applyOps(sheet: first,
            json: #"[{"ins":{"at":0,"text":"new "}}]"#))
        ContinuousPadView.updateSurface(surface.scroll, model: model, readOnly: false,
            coordinator: surface.coordinator)
        XCTAssertEqual(surface.canvas.editor.selectedRange(), NSRange(location: caret + 4, length: 0))
    }

    func testOwnershipTransferDetachesThenRebindsExistingCanvas() throws {
        let model = try model()
        _ = try seed("first checkpoint", in: model)
        _ = try seed("second checkpoint", in: model)
        let original = try mount(model)
        defer { unmount(original) }
        let document = original.canvas.document
        let selection = NSRange(location: 3, length: 2)
        original.canvas.editor.setSelectedRange(selection)
        model.transferOwnership(to: .editorWindow)
        XCTAssertEqual(document.storage.layoutManagers.count, 0)
        XCTAssertNil(document.storage.delegate)
        XCTAssertFalse(original.canvas.editor.textStorage === document.storage)
        XCTAssertFalse(original.canvas.editor.isEditable)
        XCTAssertNil(original.coordinator.continuousDocument)
        let incoming = try mount(model)
        XCTAssertTrue(incoming.canvas.document === document)
        XCTAssertEqual(document.storage.layoutManagers.count, 1)
        XCTAssertEqual(incoming.canvas.editor.selectedRange(), selection)
        model.transferOwnership(to: .panel)
        XCTAssertFalse(incoming.canvas.editor.isEditable)
        ContinuousPadView.updateSurface(original.scroll, model: model, readOnly: false,
            coordinator: original.coordinator)
        XCTAssertTrue(original.canvas.editor.textStorage === document.storage)
        XCTAssertTrue(model.activeEditor === original.canvas.editor)
        XCTAssertEqual(original.canvas.editor.selectedRange(), selection)
        unmount(incoming)
        XCTAssertTrue(model.activeEditor === original.canvas.editor)
        XCTAssertEqual(document.storage.layoutManagers.count, 1)
        XCTAssertNotNil(document.onChange)
    }

    func testStaleSameLengthReplacementRefreshesWithoutPartiallyEditingAnotherPage() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let segments = surface.canvas.document.projection.segments
        let selection = NSRange(location: 2, length: segments[1].bodyRange.location)
        surface.canvas.editor.setSelectedRange(selection)
        XCTAssertTrue(model.coreClient.syncDocument(sheet: segments[1].page.id, json: "[{\"ink\":\"DELTA\"}]"))
        surface.canvas.editor.insertText("X", replacementRange: selection)
        XCTAssertEqual(body(segments[0].page.id, in: model), segments[0].page.text)
        XCTAssertEqual(body(segments[1].page.id, in: model), "DELTA")
        XCTAssertEqual(surface.canvas.editor.string, segments[0].page.text + "\nDELTA")
        XCTAssertEqual(surface.canvas.editor.string, surface.canvas.document.projection.text)
    }

    func testRemoteTextMatchingMarkedProvisionalTextEndsCompositionWithoutDuplication() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let segments = surface.canvas.document.projection.segments
        let second = segments[1]
        let insertion = NSRange(location: second.bodyRange.location + 1, length: 0)
        editor.setSelectedRange(insertion)
        editor.setMarkedText("IME", selectedRange: NSRange(location: 3, length: 0), replacementRange: insertion)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(body(second.page.id, in: model), second.page.text)
        let remote = (second.page.text as NSString).replacingCharacters(in: NSRange(location: 1, length: 0), with: "IME")
        let data = try JSONSerialization.data(withJSONObject: [["ink": remote]])
        XCTAssertTrue(model.coreClient.syncDocument(sheet: second.page.id,
            json: try XCTUnwrap(String(data: data, encoding: .utf8))))
        model.refresh()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, segments[0].page.text + "\n" + remote)
        editor.unmarkText()
        XCTAssertEqual(body(second.page.id, in: model), remote)
        XCTAssertEqual(editor.string, surface.canvas.document.projection.text)
    }

    func testExternalEditBeforeLocalHistoryDisablesOffsetBasedUndoAfterRefresh() throws {
        let model = try model()
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let segments = surface.canvas.document.projection.segments
        editor.setSelectedRange(NSRange(location: NSMaxRange(segments[1].bodyRange), length: 0))
        editor.insertText("X", replacementRange: editor.selectedRange())
        let context = InkDocument.continuous(surface.canvas.document.scope)
        XCTAssertTrue(model.canStepEdit(context, back: true))
        let remote = "remote " + segments[0].page.text
        let data = try JSONSerialization.data(withJSONObject: [["ink": remote]])
        XCTAssertTrue(model.coreClient.syncDocument(sheet: segments[0].page.id,
            json: try XCTUnwrap(String(data: data, encoding: .utf8))))
        model.refresh()
        XCTAssertFalse(model.canStepEdit(context, back: true))
        editor.undo(nil)
        XCTAssertEqual(body(segments[0].page.id, in: model), remote)
        XCTAssertEqual(body(segments[1].page.id, in: model), segments[1].page.text + "X")
    }

    func testFailedClipboardWriteRestoresWholeCrossCheckpointCut() throws {
        let model = try model(refusingCut: true)
        _ = try seed("alpha", in: model)
        _ = try seed("bravo", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let pages = surface.canvas.document.projection.pages
        let original = editor.string
        model.ambientPasteboard.clearContents()
        XCTAssertTrue(model.ambientPasteboard.setString("clipboard stays", forType: .string))
        editor.selectAll(nil)
        let selection = editor.selectedRange()
        editor.cut(nil)
        XCTAssertEqual(model.ambientPasteboard.string(forType: .string), "clipboard stays")
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.selectedRange(), selection)
        for page in pages { XCTAssertEqual(body(page.id, in: model), page.text) }
        XCTAssertEqual(model.notice, PageModel.cutPutBackLine)
    }

    func testAdjacentNativeTypingCoalescesUntilCaretMoves() throws {
        let model = try model()
        _ = try seed("prefix ", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let original = editor.string
        editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        for letter in ["a", "b", "c"] {
            editor.insertText(letter, replacementRange: editor.selectedRange())
        }
        XCTAssertEqual(editor.string, original + "abc")
        editor.undo(nil)
        XCTAssertEqual(editor.string, original)
        editor.redo(nil)
        XCTAssertEqual(editor.string, original + "abc")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("X", replacementRange: editor.selectedRange())
        editor.undo(nil)
        XCTAssertEqual(editor.string, original + "abc")
    }

    func testDragMovesTextAndChipAcrossCheckpointAndUndoRestoresBothPages() throws {
        let model = try model()
        _ = try seed("alpha secret omega", in: model)
        _ = try seed("bravo destination", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        let editor = surface.canvas.editor
        let initial = surface.canvas.document.projection.segments
        editor.setSelectedRange(NSRange(location: initial[0].bodyRange.location + 2, length: 4))
        editor.sealSelectedContent(nil)
        let attachment = try XCTUnwrap(editor.textStorage?.attribute(.attachment,
            at: initial[0].bodyRange.location + 2, effectiveRange: nil) as? ChipAttachment)
        let chipID = attachment.info.chipId
        let segments = surface.canvas.document.projection.segments
        let original = editor.string
        let range = NSRange(location: segments[0].bodyRange.location, length: 4)
        let moved = (original as NSString).substring(with: range)
        let sourceBefore = body(segments[0].page.id, in: model)
        let destinationBefore = body(segments[1].page.id, in: model)
        let boardVersion = model.ambientPasteboard.changeCount
        editor.setSelectedRange(range)
        guard case .fragment(let item) = surface.coordinator.beginPageDrag() else {
            return XCTFail("The text and chip selection did not produce a drag fragment.")
        }
        XCTAssertNotNil(item.data(forType: SealedFragment.pasteboardType))
        XCTAssertTrue(surface.coordinator.dropPageDrag(at: original.utf16.count, offered: .move))
        surface.coordinator.endPageDrag()
        XCTAssertEqual(model.ambientPasteboard.changeCount, boardVersion)
        XCTAssertEqual(body(segments[0].page.id, in: model), (sourceBefore as NSString).substring(from: 4))
        XCTAssertEqual(body(segments[1].page.id, in: model), destinationBefore + moved)
        let movedIDs = model.coreClient.documentRuns(sheet: segments[1].page.id).compactMap { run -> UInt64? in
            if case .chip(let info) = run { return info.chipId }
            return nil
        }
        XCTAssertEqual(movedIDs, [chipID])
        editor.undo(nil)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(body(segments[0].page.id, in: model), sourceBefore)
        XCTAssertEqual(body(segments[1].page.id, in: model), destinationBefore)
        XCTAssertEqual(editor.selectedRange(), range)
        editor.redo(nil)
        XCTAssertEqual(body(segments[0].page.id, in: model), (sourceBefore as NSString).substring(from: 4))
        XCTAssertEqual(body(segments[1].page.id, in: model), destinationBefore + moved)
    }

    func testOptionalIsolatedSurfaceSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["ONETIMEPAD_TEST_SNAPSHOT_PATH"],
              path.hasPrefix("/tmp/") else {
            throw XCTSkip("Set ONETIMEPAD_TEST_SNAPSHOT_PATH to a PNG under /tmp/ to render the isolated surface.")
        }
        let model = try model()
        _ = try seed("# A quieter place to write\n\nThe whole pad is one writing surface. Select a sentence here and keep going through the next checkpoint.", in: model)
        _ = try seed("## Later that afternoon\n\nThe cursor moves through this paragraph just like any other. There is no separate card to click into.", in: model)
        _ = try seed("## Still one page\n\nA checkpoint marks a moment in the margin. The text stays together.\n\nKeep the writing area calm, keep navigation nearby, and let the words set the pace.", in: model)
        let surface = try mount(model)
        defer { unmount(surface) }
        surface.window.setContentSize(NSSize(width: 860, height: 560))
        surface.window.appearance = NSAppearance(named: .darkAqua)
        surface.scroll.frame = try XCTUnwrap(surface.window.contentView).bounds
        surface.scroll.drawsBackground = true
        surface.scroll.backgroundColor = .windowBackgroundColor
        surface.scroll.layoutSubtreeIfNeeded()
        surface.canvas.measure()
        surface.canvas.scroll(to: .zero)
        let bitmap = try XCTUnwrap(surface.scroll.bitmapImageRepForCachingDisplay(in: surface.scroll.bounds))
        surface.scroll.cacheDisplay(in: surface.scroll.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
