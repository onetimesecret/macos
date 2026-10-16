import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class CheckpointMarkdownPreviewTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "companion-checkpoint-preview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeModel(defaults: UserDefaults? = nil) throws -> PageModel {
        let model = isolatedModel(defaults: try defaults ?? makeDefaults())
        model.showsTimeUnits = true
        return model
    }

    @discardableResult
    private func page(in model: PageModel, saying ink: String = "# Heading\nbody") throws -> UInt64 {
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        model.syncDocument(sheet: page, runs: [.ink(ink)])
        XCTAssertEqual(source(for: page, in: model), ink)
        return page
    }

    private func source(for page: UInt64, in model: PageModel) -> String {
        model.coreClient.documentRuns(sheet: page).reduce(into: "") {
            if case .ink(let ink) = $1 { $0 += ink }
        }
    }

    private func summary(for page: UInt64, in model: PageModel) throws -> TabSummary {
        try XCTUnwrap(model.tabs.first { $0.pageID == page })
    }

    private func button(in header: DayHeaderView) throws -> NSButton {
        try XCTUnwrap(header.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func header(for page: UInt64, in model: PageModel) throws -> DayHeaderView {
        let header = DayHeaderView(model: model)
        header.show(
            words: .init(day: "Today", time: "12:00"), spokenLabel: "Today",
            mark: .none, summary: try summary(for: page, in: model))
        header.frame = NSRect(x: 0, y: 0, width: 420, height: header.preferredHeight)
        header.place()
        return header
    }

    private struct Roll {
        let window: NSWindow
        let scroll: NSScrollView
        let stack: DayStackView
        let coordinator: InkEditorView.Coordinator
    }

    private func mountRoll(_ model: PageModel) throws -> Roll {
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = DayScrollView.makeRoll(
            model: model, coordinator: coordinator, emptyHint: "hint")
        let frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.frame = frame
        scroll.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        stack.update(
            projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
        return Roll(window: window, scroll: scroll, stack: stack, coordinator: coordinator)
    }

    private func header(for page: UInt64, in roll: Roll) throws -> DayHeaderView {
        try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == page }?.header)
    }

    private func body(for page: UInt64, in roll: Roll) throws -> NSView {
        try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == page }?.body)
    }

    private func preview(for page: UInt64, in roll: Roll) throws -> MarkdownPreviewView {
        let preview = try XCTUnwrap(roll.stack.previewRegions[page])
        XCTAssertTrue(try body(for: page, in: roll) === preview)
        XCTAssertNil(roll.stack.quietRegions[page])
        XCTAssertTrue(preview.superview === roll.stack)
        XCTAssertFalse(preview.isHidden)
        XCTAssertFalse(preview.isEditable)
        XCTAssertGreaterThan(preview.frame.width, 0)
        XCTAssertGreaterThan(preview.frame.height, 0)
        return preview
    }

    private func headingIsStyled(_ storage: NSTextStorage) -> Bool {
        (storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont) != InkStyle.baseFont
    }

    func testPerPagePreviewDefaultsOffAndTogglesIndependentlyOfEveryGlobalScope() throws {
        let model = try makeModel()
        let first = try page(in: model)
        let second = try page(in: model)
        for scope in PreviewRenderingScope.allCases {
            model.previewRendering = scope
            XCTAssertFalse(model.markdownPreviewEnabled(for: first), scope.rawValue)
            XCTAssertFalse(model.markdownPreviewEnabled(for: second), scope.rawValue)
            XCTAssertEqual(model.previewRendering(for: first), scope)
            XCTAssertEqual(model.previewRendering(for: second), scope)

            model.toggleMarkdownPreview(for: first)

            XCTAssertTrue(model.markdownPreviewEnabled(for: first))
            XCTAssertFalse(model.markdownPreviewEnabled(for: second))
            XCTAssertEqual(model.previewRendering, scope)
            XCTAssertEqual(model.previewRendering(for: first), scope)
            XCTAssertEqual(model.previewRendering(for: second), scope)

            model.toggleMarkdownPreview(for: first)
            XCTAssertFalse(model.markdownPreviewEnabled(for: first))
            XCTAssertEqual(model.previewRendering(for: first), scope)
        }
    }

    func testNonselectedHeaderTogglesOnlyItsPreviewWithoutChangingSelectionEditorOrFocus() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let first = try page(in: model)
        let selected = try page(in: model)
        let selectedTab = model.selection
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let selection = NSRange(location: 3, length: 2)
        editor.setSelectedRange(selection)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let header = try header(for: first, in: roll)
        let toggle = try button(in: header)
        XCTAssertFalse(header.isActive)
        XCTAssertEqual(toggle.state, .off)

        toggle.performClick(nil)

        XCTAssertTrue(model.markdownPreviewEnabled(for: first))
        XCTAssertFalse(model.markdownPreviewEnabled(for: selected))
        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(try preview(for: first, in: roll).string, "Heading\nbody\n")
        XCTAssertEqual(model.selectedPageID, selected)
        XCTAssertEqual(model.selection, selectedTab)
        XCTAssertEqual(model.previewRendering, .allPages)
        XCTAssertEqual(model.previewRendering(for: first), .allPages)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(try body(for: selected, in: roll) === editor)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertTrue(headingIsStyled(storage))
        XCTAssertEqual(editor.selectedRange(), selection)

        toggle.performClick(nil)

        XCTAssertFalse(model.markdownPreviewEnabled(for: first))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertNil(roll.stack.previewRegions[first])
        let quiet = try XCTUnwrap(roll.stack.quietRegions[first])
        XCTAssertTrue(try body(for: first, in: roll) === quiet)
        XCTAssertEqual(quiet.string, "# Heading\nbody")
        XCTAssertTrue(headingIsStyled(try XCTUnwrap(quiet.textStorage)))
        XCTAssertEqual(source(for: first, in: model), "# Heading\nbody")
        XCTAssertEqual(model.selectedPageID, selected)
        XCTAssertEqual(model.selection, selectedTab)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
    }

    func testQuietHeaderCanEnableRenderedPreviewUnderNeverAndRestorePlainQuietSource() throws {
        let model = try makeModel()
        model.previewRendering = .never
        let first = try page(in: model)
        let selected = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let toggle = try button(in: header(for: first, in: roll))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertFalse(headingIsStyled(storage))

        toggle.performClick(nil)

        XCTAssertEqual(model.previewRendering, .never)
        XCTAssertEqual(model.previewRendering(for: first), .never)
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))
        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(try preview(for: first, in: roll).string, "Heading\nbody\n")
        XCTAssertFalse(headingIsStyled(storage))

        toggle.performClick(nil)

        XCTAssertNil(roll.stack.previewRegions[first])
        let quiet = try XCTUnwrap(roll.stack.quietRegions[first])
        XCTAssertTrue(try body(for: first, in: roll) === quiet)
        XCTAssertFalse(headingIsStyled(try XCTUnwrap(quiet.textStorage)))
        XCTAssertEqual(quiet.string, "# Heading\nbody")
        XCTAssertEqual(model.selectedPageID, selected)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
    }

    func testSelectedPreviewToggleTransfersFocusToPreviewAndBackWithoutClickingPreview() throws {
        let model = try makeModel()
        let page = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let selection = NSRange(location: 3, length: 2)
        editor.setSelectedRange(selection)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let toggle = try button(in: header(for: page, in: roll))

        toggle.performClick(nil)

        let preview = try preview(for: page, in: roll)
        XCTAssertTrue(roll.window.firstResponder === preview)
        XCTAssertTrue(PageModel.mountedEditor(model.activeEditor, in: roll.window) === preview)
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)

        toggle.performClick(nil)

        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.selectedRange(), selection)
    }

    func testSelectedPreviewOwnershipRoundTripRestoresOriginalEditorAndStorage() throws {
        let model = try makeModel()
        let page = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let originalOwner = model.owner
        let other: PresentationOwner = originalOwner == .panel ? .editorWindow : .panel
        model.toggleMarkdownPreview(for: page)
        XCTAssertTrue(model.activeEditor === editor)

        model.transferOwnership(to: other)
        XCTAssertNil(roll.coordinator.currentSheet)
        let incoming = try mountRoll(model)
        defer { incoming.window.close() }
        XCTAssertEqual(incoming.coordinator.surface, other)
        XCTAssertEqual(incoming.coordinator.currentSheet, page)
        XCTAssertTrue(incoming.stack.editor?.textStorage === storage)
        _ = try preview(for: page, in: incoming)

        model.transferOwnership(to: originalOwner)
        DayScrollView.updateRoll(
            roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertNil(incoming.coordinator.currentSheet)
        _ = try preview(for: page, in: roll)
        model.toggleMarkdownPreview(for: page)

        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(try XCTUnwrap(editor.textStorage) === storage)
        XCTAssertEqual(editor.string, "# Heading\nbody")
        XCTAssertEqual(roll.coordinator.currentSheet, page)
        XCTAssertEqual(model.selectedPageID, page)
        XCTAssertTrue(try body(for: page, in: roll) === editor)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
    }

    func testHeaderNavigationFromSelectedPreviewFocusesOtherEditorAndReturnsToPreview() throws {
        let model = try makeModel()
        let other = try page(in: model, saying: "# Other\nbody")
        let previewPage = try page(in: model)
        model.toggleMarkdownPreview(for: previewPage)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertTrue(roll.window.makeFirstResponder(try preview(for: previewPage, in: roll)))

        XCTAssertTrue(roll.stack.focusEditor(on: other))
        XCTAssertEqual(model.selectedPageID, other)
        DayScrollView.updateRoll(
            roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)

        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertEqual(roll.coordinator.currentSheet, other)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.string, "# Other\nbody")

        XCTAssertTrue(roll.stack.focusEditor(on: previewPage))
        XCTAssertEqual(model.selectedPageID, previewPage)
        DayScrollView.updateRoll(
            roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)

        XCTAssertTrue(roll.stack.focusEditor(on: previewPage))
        XCTAssertTrue(roll.window.firstResponder === (try preview(for: previewPage, in: roll)))
        XCTAssertEqual(roll.coordinator.currentSheet, previewPage)
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
    }

    func testNonselectedPreviewActivationSelectsPageWithoutUsingRenderedSelectionAsSourceCaret() throws {
        let model = try makeModel()
        let markdown = "# **Preview**\n\nbody with **markup**"
        let previewPage = try page(in: model, saying: markdown)
        try page(in: model)
        let sourceSelection = NSRange(location: 18, length: 2)
        model.viewStates.saveCaret(sourceSelection, for: previewPage)
        model.toggleMarkdownPreview(for: previewPage)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let preview = try preview(for: previewPage, in: roll)
        preview.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertNotEqual(model.selectedPageID, previewPage)
        let activate = try XCTUnwrap(preview.onActivate)

        activate()

        XCTAssertEqual(model.selectedPageID, previewPage)
        DayScrollView.updateRoll(
            roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertEqual(try self.preview(for: previewPage, in: roll).string, "Preview\nbody with markup\n")
        XCTAssertTrue(model.markdownPreviewEnabled(for: previewPage))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(roll.coordinator.currentSheet, previewPage)
        XCTAssertEqual(editor.selectedRange(), sourceSelection)
        XCTAssertEqual(model.viewStates.carets[previewPage], sourceSelection)
        XCTAssertEqual(source(for: previewPage, in: model), markdown)
    }

    func testSelectedTablePreviewUsesNativeCellsAndRestoresSameEditorStorageAndSelection() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let markdown = """
        # Heading

        | Name | Value |
        | --- | ---: |
        | **alpha** | 42 |
        """
        let page = try page(in: model, saying: markdown)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let selection = NSRange(location: 3, length: 4)
        editor.setSelectedRange(selection)
        let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        let toggle = try button(in: header(for: page, in: roll))
        XCTAssertTrue(headingIsStyled(storage))

        toggle.performClick(nil)

        let preview = try preview(for: page, in: roll)
        let rendered = try XCTUnwrap(preview.textStorage)
        XCTAssertEqual(preview.string, "Heading\nName\nValue\nalpha\n42\n\n")
        var cells: [NSTextTableBlock] = []
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) {
            value, _, _ in
            cells.append(contentsOf: (value as? NSParagraphStyle)?.textBlocks.compactMap {
                $0 as? NSTextTableBlock
            } ?? [])
        }
        let firstCell = try XCTUnwrap(cells.first)
        XCTAssertEqual(Set(cells.map(ObjectIdentifier.init)).count, 4)
        XCTAssertTrue(cells.allSatisfy { $0.table === firstCell.table })
        XCTAssertEqual(firstCell.table.numberOfColumns, 2)
        XCTAssertTrue(cells.contains { $0.startingRow == 1 && $0.startingColumn == 1 })
        XCTAssertFalse(rendered === storage)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(editor.superview === roll.stack)
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(editor.string, markdown)
        XCTAssertEqual(source(for: page, in: model), markdown)
        XCTAssertEqual(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont, headingFont)
        XCTAssertEqual(roll.coordinator.appliedPreviewRendering, .allPages)

        roll.stack.update(projection: model.timeUnits, selectedPage: page, readOnly: false)
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        toggle.performClick(nil)

        XCTAssertFalse(model.markdownPreviewEnabled(for: page))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertNil(roll.stack.previewRegions[page])
        XCTAssertNil(roll.stack.quietRegions[page])
        XCTAssertTrue(try body(for: page, in: roll) === editor)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(storage.string, markdown)
        XCTAssertEqual(source(for: page, in: model), markdown)
        XCTAssertEqual(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont, headingFont)
        XCTAssertEqual(model.previewRendering, .allPages)
        XCTAssertEqual(roll.coordinator.appliedPreviewRendering, .allPages)
    }

    func testSelectingPreviewPageAndLeavingItMovesSameEditorWithoutChangingPagePreviewState() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "# First\nbody")
        let firstTab = try summary(for: first, in: model).id
        let second = try page(in: model, saying: "# Second\nbody")
        let secondTab = try summary(for: second, in: model).id
        model.toggleMarkdownPreview(for: first)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let secondStorage = try XCTUnwrap(editor.textStorage)
        let secondSelection = NSRange(location: 4, length: 2)
        let firstSelection = NSRange(location: 3, length: 1)
        editor.setSelectedRange(secondSelection)
        model.viewStates.saveCaret(firstSelection, for: first)
        XCTAssertEqual(try preview(for: first, in: roll).string, "First\nbody\n")
        XCTAssertFalse(editor.isHidden)

        model.select(firstTab)
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)

        let firstStorage = try XCTUnwrap(editor.textStorage)
        XCTAssertEqual(model.selectedPageID, first)
        XCTAssertEqual(roll.coordinator.currentSheet, first)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(firstStorage === model.storage(for: first))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(try preview(for: first, in: roll).string, "First\nbody\n")
        XCTAssertNotNil(roll.stack.quietRegions[second])

        model.select(secondTab)
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)

        XCTAssertEqual(model.selectedPageID, second)
        XCTAssertEqual(roll.coordinator.currentSheet, second)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === secondStorage)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.selectedRange(), secondSelection)
        XCTAssertTrue(try body(for: second, in: roll) === editor)
        XCTAssertNil(roll.stack.quietRegions[second])
        XCTAssertEqual(try preview(for: first, in: roll).string, "First\nbody\n")
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))
        XCTAssertFalse(model.markdownPreviewEnabled(for: second))

        model.select(firstTab)
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
        model.toggleMarkdownPreview(for: first)

        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === firstStorage)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.selectedRange(), firstSelection)
        XCTAssertTrue(try body(for: first, in: roll) === editor)
    }

    func testKeyboardFocusActivatesNonselectedPreview() throws {
        let model = try makeModel()
        let first = try page(in: model)
        let second = try page(in: model)
        model.toggleMarkdownPreview(for: first)
        model.toggleMarkdownPreview(for: second)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let firstPreview = try preview(for: first, in: roll)
        let secondPreview = try preview(for: second, in: roll)
        XCTAssertTrue(roll.window.makeFirstResponder(secondPreview))

        XCTAssertTrue(roll.window.makeFirstResponder(firstPreview))

        XCTAssertEqual(model.selectedPageID, first)
        XCTAssertEqual(roll.coordinator.currentSheet, first)
        XCTAssertTrue(roll.window.firstResponder === firstPreview)
        XCTAssertTrue(PageModel.mountedEditor(model.activeEditor) === firstPreview)
    }

    func testReusedHeaderChangesTargetAndHidesButtonForEmptyToday() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let first = try page(in: model)
        let second = try page(in: model)
        let header = try header(for: first, in: model)
        let toggle = try button(in: header)
        XCTAssertEqual(toggle.state, .off)
        toggle.performClick(nil)
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))

        header.refresh(summary: try summary(for: second, in: model))
        header.place()
        XCTAssertEqual(header.pageIdentity, second)
        XCTAssertEqual(toggle.state, .off)
        toggle.performClick(nil)
        XCTAssertTrue(model.markdownPreviewEnabled(for: second))
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))

        header.show(
            words: .init(day: "Today", time: ""), spokenLabel: "Today",
            mark: .none, summary: nil)
        header.place()
        XCTAssertNil(header.pageIdentity)
        XCTAssertTrue(toggle.isHidden)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertNil(header.accessibilityChildren())
        toggle.performClick(nil)
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))
        XCTAssertTrue(model.markdownPreviewEnabled(for: second))

        header.refresh(summary: try summary(for: first, in: model))
        header.place()
        XCTAssertEqual(header.pageIdentity, first)
        XCTAssertFalse(toggle.isHidden)
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(toggle.state, .on)
        toggle.performClick(nil)
        XCTAssertFalse(model.markdownPreviewEnabled(for: first))
        XCTAssertTrue(model.markdownPreviewEnabled(for: second))
        XCTAssertEqual(model.previewRendering(for: first), .allPages)
        XCTAssertEqual(model.previewRendering(for: second), .allPages)
    }

    func testButtonStartsOffAndRefreshesFromPageBooleanRegardlessOfHybridScope() throws {
        for scope in PreviewRenderingScope.allCases {
            let model = try makeModel()
            model.previewRendering = scope
            let first = try page(in: model)
            try page(in: model)
            let header = try header(for: first, in: model)
            let toggle = try button(in: header)
            XCTAssertFalse(header.isActive)
            XCTAssertEqual(toggle.state, .off, scope.rawValue)
            XCTAssertFalse(model.markdownPreviewEnabled(for: first))
            XCTAssertFalse(try XCTUnwrap(toggle.accessibilityLabel()).isEmpty)
            let disabledTooltip = try XCTUnwrap(toggle.toolTip)

            toggle.performClick(nil)

            XCTAssertEqual(toggle.state, .on)
            XCTAssertTrue(model.markdownPreviewEnabled(for: first))
            XCTAssertEqual(model.previewRendering(for: first), scope)
            XCTAssertNotEqual(toggle.toolTip, disabledTooltip)
            model.toggleMarkdownPreview(for: first)
            header.refresh(summary: try summary(for: first, in: model))
            XCTAssertEqual(toggle.state, .off)
            XCTAssertEqual(toggle.toolTip, disabledTooltip)
        }
    }

    func testMouseAndAccessibilityHitTestsReachButtonBesideTitleAndTime() throws {
        let model = try makeModel()
        let page = try page(in: model)
        let tab = try summary(for: page, in: model).id
        model.renameTab(tab, to: String(repeating: "long title ", count: 20))
        let header = try header(for: page, in: model)
        let window = NSWindow(
            contentRect: header.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = header
        defer { window.close() }
        header.place()
        let toggle = try button(in: header)
        XCTAssertGreaterThanOrEqual(toggle.frame.minX, header.timeFrame.maxX)
        XCTAssertLessThanOrEqual(toggle.frame.maxX, header.bounds.maxX)
        let local = NSPoint(x: toggle.frame.midX, y: toggle.frame.midY)
        XCTAssertTrue(header.hitTest(local) === toggle)
        let screen = window.convertPoint(toScreen: header.convert(local, to: nil))
        XCTAssertTrue((header.accessibilityHitTest(screen) as? NSButton) === toggle)
        XCTAssertTrue(header.accessibilityChildren()?.contains {
            ($0 as? NSButton) === toggle
        } == true)
        let timePoint = NSPoint(x: header.timeFrame.midX, y: header.timeFrame.midY)
        let timeScreen = window.convertPoint(toScreen: header.convert(timePoint, to: nil))
        XCTAssertTrue((header.accessibilityHitTest(timeScreen) as? NSView) === header)
    }

    func testGlobalHybridSettingChangesWhilePreviewStaysOnWithoutReplacingEditorOrSource() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let quietPage = try page(in: model)
        let selected = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let selection = NSRange(location: 3, length: 2)
        editor.setSelectedRange(selection)
        model.toggleMarkdownPreview(for: selected)

        for scope in [PreviewRenderingScope.never, .focusedOnly, .allPages, .never] {
            model.previewRendering = scope
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)

            XCTAssertTrue(model.markdownPreviewEnabled(for: selected))
            XCTAssertFalse(model.markdownPreviewEnabled(for: quietPage))
            XCTAssertEqual(model.previewRendering(for: selected), scope)
            XCTAssertEqual(model.previewRendering(for: quietPage), scope)
            XCTAssertEqual(try preview(for: selected, in: roll).string, "Heading\nbody\n")
            XCTAssertEqual(try button(in: header(for: selected, in: roll)).state, .on)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
            XCTAssertTrue(editor.isHidden)
            XCTAssertFalse(editor.isEditable)
            XCTAssertEqual(roll.coordinator.appliedPreviewRendering, scope)
            XCTAssertEqual(headingIsStyled(storage), scope != .never)
            let quiet = try XCTUnwrap(roll.stack.quietRegions[quietPage])
            XCTAssertEqual(headingIsStyled(try XCTUnwrap(quiet.textStorage)), scope == .allPages)
            XCTAssertEqual(storage.string, "# Heading\nbody")
            XCTAssertEqual(source(for: selected, in: model), "# Heading\nbody")
        }

        model.toggleMarkdownPreview(for: selected)

        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertFalse(headingIsStyled(storage))
        XCTAssertEqual(roll.coordinator.appliedPreviewRendering, .never)
    }

    func testEditorMakeUpdateAndDirectApplyUseOnlyGlobalHybridScope() throws {
        let model = try makeModel()
        model.previewRendering = .never
        let first = try page(in: model)
        model.toggleMarkdownPreview(for: first)
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = InkEditorView.makePage(
            model: model, sheetID: first, readOnly: false, coordinator: coordinator)
        let editor = try XCTUnwrap(scroll.documentView as? InkTextView)
        let storage = try XCTUnwrap(editor.textStorage)
        defer { InkEditorView.dismantleNSView(scroll, coordinator: coordinator) }
        XCTAssertEqual(coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(storage))

        model.toggleMarkdownPreview(for: first)
        coordinator.applyPreviewRendering(model.previewRendering)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(storage))
        model.previewRendering = .allPages
        model.toggleMarkdownPreview(for: first)
        coordinator.applyPreviewRendering(model.previewRendering)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(storage))

        let second = try page(in: model)
        InkEditorView.updatePage(
            scroll, model: model, sheetID: second, readOnly: false, coordinator: coordinator)
        XCTAssertEqual(coordinator.currentSheet, second)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(try XCTUnwrap(editor.textStorage)))
        model.toggleMarkdownPreview(for: second)
        model.previewRendering = .never
        InkEditorView.updatePage(
            scroll, model: model, sheetID: second, readOnly: false, coordinator: coordinator)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(try XCTUnwrap(editor.textStorage)))
        XCTAssertTrue(model.markdownPreviewEnabled(for: first))
        XCTAssertTrue(model.markdownPreviewEnabled(for: second))
    }

    func testPreviewKeepsEditorNoneditableAcrossReadOnlyUpdatesAndRestoresLatestEditability() throws {
        for readOnly in [false, true] {
            let model = try makeModel()
            let page = try page(in: model)
            let roll = try mountRoll(model)
            defer { roll.window.close() }
            let editor = try XCTUnwrap(roll.stack.editor)
            let storage = try XCTUnwrap(editor.textStorage)
            let selection = NSRange(location: 4, length: 1)
            editor.setSelectedRange(selection)
            roll.stack.update(projection: model.timeUnits, selectedPage: page, readOnly: readOnly)
            XCTAssertEqual(editor.isEditable, !readOnly)

            model.toggleMarkdownPreview(for: page)
            XCTAssertTrue(editor.isHidden)
            XCTAssertFalse(editor.isEditable)
            roll.stack.update(projection: model.timeUnits, selectedPage: page, readOnly: readOnly)
            XCTAssertTrue(editor.isHidden)
            XCTAssertFalse(editor.isEditable)
            model.toggleMarkdownPreview(for: page)
            XCTAssertFalse(editor.isHidden)
            XCTAssertEqual(editor.isEditable, !readOnly)
            XCTAssertEqual(editor.selectedRange(), selection)

            model.toggleMarkdownPreview(for: page)
            roll.stack.update(projection: model.timeUnits, selectedPage: page, readOnly: !readOnly)
            XCTAssertTrue(editor.isHidden)
            XCTAssertFalse(editor.isEditable)
            model.toggleMarkdownPreview(for: page)
            XCTAssertFalse(editor.isHidden)
            XCTAssertEqual(editor.isEditable, readOnly)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertTrue(try body(for: page, in: roll) === editor)
        }
    }

    func testSelectedAndQuietPreviewsRefreshFromChangedSourceOnModelRefreshAndRollUpdate() throws {
        for isSelected in [true, false] {
            let model = try makeModel()
            let page = try page(in: model)
            if !isSelected { try self.page(in: model) }
            let selected = model.selectedPageID
            model.toggleMarkdownPreview(for: page)
            let roll = try mountRoll(model)
            defer { roll.window.close() }
            let editor = try XCTUnwrap(roll.stack.editor)
            let storage = try XCTUnwrap(editor.textStorage)
            XCTAssertEqual(try preview(for: page, in: roll).string, "Heading\nbody\n")

            let replacement = "# Updated\n\nA **new** paragraph."
            model.syncDocument(sheet: page, runs: [.ink(replacement)])
            model.refresh()
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)

            XCTAssertEqual(try preview(for: page, in: roll).string, "Updated\nA new paragraph.\n")
            XCTAssertEqual(source(for: page, in: model), replacement)
            XCTAssertTrue(model.markdownPreviewEnabled(for: page))
            XCTAssertEqual(model.selectedPageID, selected)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
            XCTAssertEqual(editor.isHidden, isSelected)
            XCTAssertEqual(editor.isEditable, !isSelected)
        }
    }

    func testPreviewChoicesPersistInV2ByPageUUIDAndReloadIndependentlyOfGlobalScope() throws {
        let defaults = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-preview-reload-\(UUID().uuidString)")
        let tag = UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        func launch() -> PageModel {
            PageModel(formFactor: .backdrop, defaults: defaults,
                seams: .init(stateDirectory: directory, client: .ephemeral(tag: tag), saveDebounce: 3_600))
        }
        let first = launch()
        first.loadStateIfNeeded()
        let disabledPage = try XCTUnwrap(first.selectedPageID)
        let disabledUUID = try XCTUnwrap(first.selectedTab?.pageUUID)
        first.toggleMarkdownPreview(for: disabledPage)
        first.toggleMarkdownPreview(for: disabledPage)
        first.newPage()
        let enabledPage = try XCTUnwrap(first.selectedPageID)
        let enabledUUID = try XCTUnwrap(first.selectedTab?.pageUUID)
        first.previewRendering = .never
        first.toggleMarkdownPreview(for: enabledPage)
        _ = first.saveStateForQuit()
        XCTAssertNotEqual(disabledUUID, enabledUUID)
        XCTAssertEqual(defaults.dictionary(forKey: "pageMarkdownPreviewV2") as? [String: Bool],
                       [disabledUUID: false, enabledUUID: true])
        XCTAssertNil(defaults.object(forKey: "pageMarkdownPreviewV1"))
        defaults.set([disabledUUID: true, enabledUUID: false], forKey: "pageMarkdownPreviewV1")

        let second = launch()
        second.refresh()
        second.loadStateIfNeeded()
        XCTAssertEqual(second.previewRendering, .never)
        let restoredDisabled = try XCTUnwrap(second.tabs.first { $0.pageUUID == disabledUUID }?.pageID)
        let restoredEnabled = try XCTUnwrap(second.tabs.first { $0.pageUUID == enabledUUID }?.pageID)
        for scope in PreviewRenderingScope.allCases {
            second.previewRendering = scope
            XCTAssertFalse(second.markdownPreviewEnabled(for: restoredDisabled))
            XCTAssertTrue(second.markdownPreviewEnabled(for: restoredEnabled))
            XCTAssertEqual(second.previewRendering(for: restoredDisabled), scope)
            XCTAssertEqual(second.previewRendering(for: restoredEnabled), scope)
        }
        second.toggleMarkdownPreview(for: restoredEnabled)
        XCTAssertFalse(second.markdownPreviewEnabled(for: restoredEnabled))
        XCTAssertEqual(defaults.dictionary(forKey: "pageMarkdownPreviewV2") as? [String: Bool],
                       [disabledUUID: false, enabledUUID: false])
    }

    func testLegacyV1PreferenceIsIgnoredWhenV2HasNoEntry() throws {
        let defaults = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-preview-legacy-\(UUID().uuidString)")
        let tag = UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        func launch() -> PageModel {
            PageModel(formFactor: .backdrop, defaults: defaults,
                seams: .init(stateDirectory: directory, client: .ephemeral(tag: tag), saveDebounce: 3_600))
        }
        let first = launch()
        first.loadStateIfNeeded()
        let firstUUID = try XCTUnwrap(first.selectedTab?.pageUUID)
        first.newPage()
        let secondUUID = try XCTUnwrap(first.selectedTab?.pageUUID)
        first.previewRendering = .allPages
        _ = first.saveStateForQuit()
        defaults.set([firstUUID: true, secondUUID: false], forKey: "pageMarkdownPreviewV1")
        XCTAssertNil(defaults.object(forKey: "pageMarkdownPreviewV2"))

        let second = launch()
        second.refresh()
        second.loadStateIfNeeded()
        for uuid in [firstUUID, secondUUID] {
            let page = try XCTUnwrap(second.tabs.first { $0.pageUUID == uuid }?.pageID)
            XCTAssertFalse(second.markdownPreviewEnabled(for: page))
            XCTAssertEqual(second.previewRendering(for: page), .allPages)
        }
    }

    func testReplacementPageInSameTabDoesNotInheritPreviewChoice() throws {
        let defaults = try makeDefaults()
        let model = try makeModel(defaults: defaults)
        model.loadStateIfNeeded()
        let oldPage = try XCTUnwrap(model.selectedPageID)
        let tab = try XCTUnwrap(model.selection)
        let oldUUID = try XCTUnwrap(model.selectedTab?.pageUUID)
        model.toggleMarkdownPreview(for: oldPage)
        XCTAssertTrue(model.markdownPreviewEnabled(for: oldPage))
        XCTAssertTrue(model.coreClient.discardPage(id: oldPage))
        let replacement = model.coreClient.openPage(tab: tab)
        XCTAssertNotEqual(replacement, 0)
        model.refresh()
        let replacementUUID = try XCTUnwrap(model.tabs.first { $0.id == tab }?.pageUUID)
        XCTAssertNotEqual(replacementUUID, oldUUID)
        XCTAssertFalse(model.markdownPreviewEnabled(for: replacement))
        XCTAssertFalse(model.markdownPreviewEnabled(for: oldPage))
        XCTAssertEqual(model.previewRendering(for: replacement), model.previewRendering)
        XCTAssertNil(defaults.dictionary(forKey: "pageMarkdownPreviewV2")?[oldUUID])
        model.toggleMarkdownPreview(for: replacement)
        XCTAssertTrue(model.markdownPreviewEnabled(for: replacement))
        XCTAssertEqual(defaults.dictionary(forKey: "pageMarkdownPreviewV2")?[replacementUUID] as? Bool, true)
    }

    func testPreviewStateAndMountedRegionExpireWithPageWithoutChangingOtherPages() throws {
        let defaults = try makeDefaults()
        let model = try makeModel(defaults: defaults)
        model.loadStateIfNeeded()
        let expiring = try XCTUnwrap(model.selectedPageID)
        let expiringUUID = try XCTUnwrap(model.selectedTab?.pageUUID)
        let tab = try XCTUnwrap(model.selection)
        model.toggleMarkdownPreview(for: expiring)
        XCTAssertTrue(model.coreClient.setRung(tab: tab, rung: .oneHour))
        let survivor = try page(in: model)
        XCTAssertTrue(model.coreClient.setRung(
            tab: try summary(for: survivor, in: model).id, rung: .sevenDays))
        model.toggleMarkdownPreview(for: survivor)
        let untouched = try page(in: model)
        XCTAssertTrue(model.coreClient.setRung(
            tab: try summary(for: untouched, in: model).id, rung: .sevenDays))
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let expiredPreview = try preview(for: expiring, in: roll)

        XCTAssertTrue(model.coreClient.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        model.coreClient.expireDue()
        model.refresh()
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)

        XCTAssertFalse(model.tabs.contains { $0.pageID == expiring })
        XCTAssertFalse(model.markdownPreviewEnabled(for: expiring))
        XCTAssertTrue(model.markdownPreviewEnabled(for: survivor))
        XCTAssertFalse(model.markdownPreviewEnabled(for: untouched))
        XCTAssertEqual(model.selectedPageID, untouched)
        XCTAssertNil(roll.stack.previewRegions[expiring])
        XCTAssertNil(roll.stack.quietRegions[expiring])
        XCTAssertNil(expiredPreview.superview)
        XCTAssertFalse(roll.stack.laidOut.contains { $0.header.pageIdentity == expiring })
        XCTAssertEqual(try preview(for: survivor, in: roll).string, "Heading\nbody\n")
        let persisted = defaults.dictionary(forKey: "pageMarkdownPreviewV2") as? [String: Bool]
        XCTAssertNil(persisted?[expiringUUID])
        model.toggleMarkdownPreview(for: expiring)
        XCTAssertEqual(defaults.dictionary(forKey: "pageMarkdownPreviewV2") as? [String: Bool], persisted)
        XCTAssertTrue(model.markdownPreviewEnabled(for: survivor))
        XCTAssertFalse(model.markdownPreviewEnabled(for: untouched))
    }

    func testOlderSummaryWithoutPageUUIDStillDecodes() throws {
        let model = try makeModel()
        let page = try page(in: model)
        let data = try JSONEncoder().encode(summary(for: page, in: model))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields.removeValue(forKey: "page_uuid")
        let decoded = try JSONDecoder().decode(TabSummary.self,
            from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertNil(decoded.pageUUID)
        XCTAssertEqual(decoded.pageID, page)
    }

    func testNoteEditorKeepsGlobalHybridScopeWhileItsPagePreviewIsEnabled() throws {
        let model = try makeModel()
        model.previewRendering = .never
        let page = try page(in: model)
        model.toggleMarkdownPreview(for: page)
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let editor = try XCTUnwrap(InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator))
        defer { coordinator.leavePage(editor, scrollView: nil) }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        coordinator.sealSelectionOrLine()
        let chip = try XCTUnwrap(coordinator.chipAttachment(at: 0)?.info.chipId)
        let note = SealedNoteEditor(model: model)
        XCTAssertTrue(note.coordinator.loadNote(chip: chip))
        defer { note.coordinator.unloadNote() }
        model.applyingProjection { note.storage.mutableString.setString("# Heading\nbody") }
        note.coordinator.restyle()
        XCTAssertTrue(model.markdownPreviewEnabled(for: page))
        XCTAssertEqual(model.previewRendering(for: page), .never)
        XCTAssertEqual(note.coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(note.storage))

        model.previewRendering = .allPages
        note.coordinator.applyPreviewRendering(model.previewRendering)
        XCTAssertTrue(model.markdownPreviewEnabled(for: page))
        XCTAssertEqual(model.previewRendering(for: page), .allPages)
        XCTAssertEqual(note.coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(note.storage))
        XCTAssertEqual(note.storage.string, "# Heading\nbody")
    }
}
