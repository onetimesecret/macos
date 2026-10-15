import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class CheckpointMarkdownPreviewTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suite = "companion-checkpoint-preview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        model.showsTimeUnits = true
        return model
    }

    @discardableResult
    private func page(in model: PageModel) throws -> UInt64 {
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        XCTAssertTrue(model.coreClient.syncDocument(
            sheet: page, json: "[{\"ink\":\"# Heading\\nbody\"}]"))
        model.refresh()
        return page
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

    private func headingIsStyled(_ storage: NSTextStorage) -> Bool {
        (storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont) != InkStyle.baseFont
    }

    func testNonselectedHeaderTogglesItsPageNotTheSelectedPageOrTab() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let first = try page(in: model)
        let selected = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        let header = try XCTUnwrap(roll.stack.laidOut.first {
            $0.header.pageIdentity == first
        }?.header)
        let toggle = try button(in: header)
        XCTAssertFalse(header.isActive)
        XCTAssertEqual(toggle.state, .on)

        toggle.performClick(nil)

        XCTAssertEqual(model.selectedPageID, selected)
        XCTAssertEqual(model.previewRendering, .allPages)
        XCTAssertEqual(model.previewRendering(for: first), .never)
        XCTAssertEqual(model.previewRendering(for: selected), .allPages)
        XCTAssertEqual(toggle.state, .off)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(headingIsStyled(storage))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        let quiet = try XCTUnwrap(roll.stack.quietRegions[first])
        XCTAssertFalse(headingIsStyled(try XCTUnwrap(quiet.textStorage)))
    }

    func testQuietHeaderCanEnablePreviewUnderNeverWithoutChangingSelection() throws {
        let model = try makeModel()
        model.previewRendering = .never
        let first = try page(in: model)
        let selected = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let header = try XCTUnwrap(roll.stack.laidOut.first {
            $0.header.pageIdentity == first
        }?.header)
        let toggle = try button(in: header)
        XCTAssertEqual(toggle.state, .off)

        toggle.performClick(nil)

        XCTAssertEqual(model.previewRendering, .never)
        XCTAssertEqual(model.selectedPageID, selected)
        XCTAssertEqual(model.previewRendering(for: first), .allPages)
        XCTAssertEqual(model.previewRendering(for: selected), .never)
        XCTAssertEqual(toggle.state, .on)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[first])
        XCTAssertTrue(headingIsStyled(try XCTUnwrap(quiet.textStorage)))
    }

    func testReusedHeaderChangesTargetAndHidesButtonForEmptyToday() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let first = try page(in: model)
        let second = try page(in: model)
        let header = try header(for: first, in: model)
        let toggle = try button(in: header)
        toggle.performClick(nil)
        XCTAssertEqual(model.previewRendering(for: first), .never)

        header.refresh(summary: try summary(for: second, in: model))
        header.place()
        XCTAssertEqual(header.pageIdentity, second)
        XCTAssertEqual(toggle.state, .on)
        toggle.performClick(nil)
        XCTAssertEqual(model.previewRendering(for: second), .never)
        XCTAssertEqual(model.previewRendering(for: first), .never)

        header.show(
            words: .init(day: "Today", time: ""), spokenLabel: "Today",
            mark: .none, summary: nil)
        header.place()
        XCTAssertNil(header.pageIdentity)
        XCTAssertTrue(toggle.isHidden)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertNil(header.accessibilityChildren())
        toggle.performClick(nil)
        XCTAssertEqual(model.previewRendering(for: second), .never)

        header.refresh(summary: try summary(for: first, in: model))
        header.place()
        XCTAssertEqual(header.pageIdentity, first)
        XCTAssertFalse(toggle.isHidden)
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(toggle.state, .off)
        toggle.performClick(nil)
        XCTAssertEqual(model.previewRendering(for: first), .allPages)
        XCTAssertEqual(model.previewRendering(for: second), .never)
    }

    func testButtonStateRefreshesFromEffectivePagePreference() throws {
        let model = try makeModel()
        model.previewRendering = .focusedOnly
        let first = try page(in: model)
        try page(in: model)
        let header = try header(for: first, in: model)
        let toggle = try button(in: header)
        XCTAssertFalse(header.isActive)
        XCTAssertEqual(toggle.state, .on)
        XCTAssertFalse(model.markdownPreviewEnabled(for: first, quiet: true))
        XCTAssertFalse(try XCTUnwrap(toggle.accessibilityLabel()).isEmpty)
        let enabledTooltip = try XCTUnwrap(toggle.toolTip)

        toggle.performClick(nil)
        XCTAssertEqual(toggle.state, .off)
        XCTAssertEqual(model.previewRendering(for: first), .never)
        XCTAssertNotEqual(toggle.toolTip, enabledTooltip)
        model.toggleMarkdownPreview(for: first)
        header.refresh(summary: try summary(for: first, in: model))
        XCTAssertEqual(toggle.state, .on)
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

    func testSelectedHeaderRestylesMountedEditorWithoutGlobalPreferenceChange() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let page = try page(in: model)
        let roll = try mountRoll(model)
        defer { roll.window.close() }
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let header = try XCTUnwrap(roll.stack.laidOut.first {
            $0.header.pageIdentity == page
        }?.header)
        let toggle = try button(in: header)
        XCTAssertTrue(headingIsStyled(storage))

        toggle.performClick(nil)
        XCTAssertFalse(headingIsStyled(storage))
        roll.stack.update(projection: model.timeUnits, selectedPage: page, readOnly: false)
        XCTAssertEqual(model.previewRendering, .allPages)
        XCTAssertEqual(roll.coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(storage))
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)

        toggle.performClick(nil)
        XCTAssertTrue(headingIsStyled(storage))
        roll.stack.update(projection: model.timeUnits, selectedPage: page, readOnly: false)
        XCTAssertEqual(roll.coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(storage))
    }

    func testEditorMakeUpdateAndDirectApplyCompareEffectiveScope() throws {
        let model = try makeModel()
        model.previewRendering = .never
        let first = try page(in: model)
        model.toggleMarkdownPreview(for: first)
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = InkEditorView.makePage(
            model: model, sheetID: first, readOnly: false, coordinator: coordinator)
        let editor = try XCTUnwrap(scroll.documentView as? InkTextView)
        defer { InkEditorView.dismantleNSView(scroll, coordinator: coordinator) }
        XCTAssertEqual(coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(try XCTUnwrap(editor.textStorage)))

        model.toggleMarkdownPreview(for: first)
        coordinator.applyPreviewRendering(model.previewRendering)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(try XCTUnwrap(editor.textStorage)))
        model.toggleMarkdownPreview(for: first)
        coordinator.applyPreviewRendering(model.previewRendering)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(try XCTUnwrap(editor.textStorage)))

        let second = try page(in: model)
        InkEditorView.updatePage(
            scroll, model: model, sheetID: second, readOnly: false, coordinator: coordinator)
        XCTAssertEqual(coordinator.currentSheet, second)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(try XCTUnwrap(editor.textStorage)))
        model.toggleMarkdownPreview(for: second)
        InkEditorView.updatePage(
            scroll, model: model, sheetID: second, readOnly: false, coordinator: coordinator)
        XCTAssertEqual(coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(try XCTUnwrap(editor.textStorage)))
    }

    func testPreviewChoicesReloadByPageUUIDIndependentlyOfGlobalScope() throws {
        let suite = "checkpoint-preview-reload-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-preview-reload-\(UUID().uuidString)")
        let tag = UUID().uuidString
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        func launch() -> PageModel {
            PageModel(formFactor: .backdrop, defaults: defaults,
                seams: .init(stateDirectory: directory, client: .ephemeral(tag: tag), saveDebounce: 3_600))
        }
        let first = launch()
        first.loadStateIfNeeded()
        let disabledPage = try XCTUnwrap(first.selectedPageID)
        let disabledUUID = try XCTUnwrap(first.selectedTab?.pageUUID)
        first.toggleMarkdownPreview(for: disabledPage)
        first.newPage()
        let enabledPage = try XCTUnwrap(first.selectedPageID)
        let enabledUUID = try XCTUnwrap(first.selectedTab?.pageUUID)
        first.previewRendering = .never
        first.toggleMarkdownPreview(for: enabledPage)
        first.saveStateForQuit()

        let second = launch()
        second.refresh()
        second.loadStateIfNeeded()
        XCTAssertEqual(second.previewRendering, .never)
        let restoredDisabled = try XCTUnwrap(second.tabs.first { $0.pageUUID == disabledUUID }?.pageID)
        let restoredEnabled = try XCTUnwrap(second.tabs.first { $0.pageUUID == enabledUUID }?.pageID)
        XCTAssertEqual(second.previewRendering(for: restoredDisabled), .never)
        XCTAssertEqual(second.previewRendering(for: restoredEnabled), .allPages)
        second.previewRendering = .allPages
        XCTAssertEqual(second.previewRendering(for: restoredDisabled), .never)
        XCTAssertEqual(second.previewRendering(for: restoredEnabled), .allPages)
    }

    func testReplacementPageInSameTabDoesNotInheritPreviewChoice() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let oldPage = try XCTUnwrap(model.selectedPageID)
        let tab = try XCTUnwrap(model.selection)
        let oldUUID = try XCTUnwrap(model.selectedTab?.pageUUID)
        model.toggleMarkdownPreview(for: oldPage)
        XCTAssertEqual(model.previewRendering(for: oldPage), .never)
        XCTAssertTrue(model.coreClient.discardPage(id: oldPage))
        let replacement = model.coreClient.openPage(tab: tab)
        XCTAssertNotEqual(replacement, 0)
        model.refresh()
        XCTAssertNotEqual(model.tabs.first { $0.id == tab }?.pageUUID, oldUUID)
        XCTAssertEqual(model.previewRendering(for: replacement), .allPages)
    }

    func testPreviewStateExpiresWithPageAndDoesNotChangeOtherPages() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let expiring = try XCTUnwrap(model.selectedPageID)
        let tab = try XCTUnwrap(model.selection)
        model.toggleMarkdownPreview(for: expiring)
        model.coreClient.setRung(tab: tab, rung: .oneHour)
        model.newPage()
        let survivor = try XCTUnwrap(model.selectedPageID)
        model.coreClient.ageForTests(byMs: 2 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
        XCTAssertFalse(model.tabs.contains { $0.pageID == expiring })
        XCTAssertEqual(model.previewRendering(for: survivor), .allPages)
        model.toggleMarkdownPreview(for: expiring)
        XCTAssertEqual(model.previewRendering(for: survivor), .allPages)
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

    func testNoteEditorKeepsGlobalPreviewScopeDespitePageOverride() throws {
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
        XCTAssertEqual(note.coordinator.appliedPreviewRendering, .never)
        XCTAssertFalse(headingIsStyled(note.storage))

        model.previewRendering = .allPages
        model.toggleMarkdownPreview(for: page)
        note.coordinator.applyPreviewRendering(model.previewRendering)
        XCTAssertEqual(model.previewRendering(for: page), .never)
        XCTAssertEqual(note.coordinator.appliedPreviewRendering, .allPages)
        XCTAssertTrue(headingIsStyled(note.storage))
    }
}
