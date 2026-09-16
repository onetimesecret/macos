import AppKit
import XCTest

@testable import CompanionKit

/// The mounted AppKit integration coverage for the preview-rendering scope
/// preference, sitting next to `DayScrollTests` and driving the same real
/// roll (`DayScrollView.makeRoll` in a headless window). Unit coverage of
/// the model-side rendering payload lives in `PageModelPreviewRenderingTests`;
/// this suite asserts what a scope flip does under the eye of the running
/// surface: the one editor keeps its identity, quiet regions carry the
/// same wash-capable geometry the editor does, the roll's measurement
/// follows the styled heights, and a notification posted by one model
/// stops at that model's own roll.
@MainActor
final class DayScrollPreviewRenderingTests: XCTestCase {
    // MARK: Fixtures

    /// Enough surface to see heading font, code font and syntax colour
    /// under `.allPages` and lose all three under `.never`. Written on a
    /// bare fence so `fenceRenderingLanguages` can attach a session
    /// language to it in the fence-language test.
    private static let bareFenceMarkdownFixture = """
        # Title heading line

        ```
        let value = 1
        print(value)
        return value
        ```

        trailing prose line one
        trailing prose line two
        """

    private func makeModel(suite: String = #function) throws -> PageModel {
        let suiteName = "companion-day-scroll-preview-\(suite)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = isolatedModel(defaults: defaults)
        model.showsTimeUnits = true
        return model
    }

    /// A page whose document holds the given ink, minted and left as the
    /// selection. Read the returned pageID once and use it against the
    /// core-facing routes that name a page by identity.
    @discardableResult
    private func page(in model: PageModel, saying ink: String) throws -> UInt64 {
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let escaped = ink
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertTrue(model.coreClient.syncDocument(
            sheet: page, json: "[{\"ink\": \"\(escaped)\"}]"
        ))
        model.refresh()
        return page
    }

    private func onDay(_ tab: TabSummary, _ day: Int) -> TabSummary {
        TabSummary(
            id: tab.id,
            hasPage: tab.hasPage,
            pageID: tab.pageID,
            title: tab.title,
            rungCode: tab.rungCode,
            rungLabel: tab.rungLabel,
            remainingMs: tab.remainingMs,
            remainingLabel: tab.remainingLabel,
            spokenRemaining: tab.spokenRemaining,
            fractionRemaining: tab.fractionRemaining,
            paused: tab.paused,
            holdToppedUp: tab.holdToppedUp,
            holdRemainingMs: tab.holdRemainingMs,
            chipCount: tab.chipCount,
            lastHour: tab.lastHour,
            pageHasContent: tab.pageHasContent,
            pageDayOffset: day,
            pageCreatedMs: tab.pageCreatedMs
        )
    }

    private func filed(_ model: PageModel, under days: [Int]) -> [TabSummary] {
        var tabs: [TabSummary] = []
        for (index, tab) in model.tabs.enumerated() {
            tabs.append(onDay(tab, index < days.count ? days[index] : 0))
        }
        return tabs
    }

    /// One page per day in strip order, newest first: the projection
    /// `DayScrollTests` uses to hand-spread pages the core would refuse
    /// to keep on different days.
    private func spreadOverDays(_ model: PageModel, selecting page: UInt64?) -> TimeUnitProjection {
        var days: [Int] = []
        for index in model.tabs.indices { days.append(-index) }
        return TimeUnitProjection.project(
            tabs: filed(model, under: days), selectedPageID: page, unit: .day
        )
    }

    private struct Roll {
        let window: NSWindow
        let scroll: NSScrollView
        let stack: DayStackView
        let coordinator: InkEditorView.Coordinator
    }

    private func mountRoll(model: PageModel, height: CGFloat = 320) throws -> Roll {
        let coordinator = InkEditorView.Coordinator(model: model)
        let scroll = DayScrollView.makeRoll(
            model: model, coordinator: coordinator, emptyHint: "hint"
        )
        let card = NSRect(x: 0, y: 0, width: 420, height: height)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        return Roll(window: window, scroll: scroll, stack: stack, coordinator: coordinator)
    }

    /// The publication hop `RollGeometryModel` books, given room to run.
    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
    }

    /// A re-entry into `update()` with the model's current projection and
    /// selection. Stand-in for the `updateNSView` a `@Published` change
    /// would trigger in the shipping surface.
    private func republish(_ roll: Roll, _ model: PageModel) {
        roll.stack.update(
            projection: spreadOverDays(model, selecting: model.selectedPageID),
            selectedPage: model.selectedPageID,
            readOnly: false
        )
    }

    /// True when the storage lays anything other than `InkStyle.baseFont`
    /// on at least one attachment-free character run. Heading and code
    /// runs both fail it, which is the whole of what a scope flip moves.
    private func hasNonBaseFont(_ storage: NSTextStorage) -> Bool {
        var seen = false
        storage.enumerateAttribute(
            .font, in: NSRange(location: 0, length: storage.length)
        ) { value, _, stop in
            if let font = value as? NSFont, font != InkStyle.baseFont {
                seen = true
                stop.pointee = true
            }
        }
        return seen
    }

    /// True when any character range carries a foreground colour other
    /// than `NSColor.labelColor`. The token colours are the whole reason
    /// syntax highlighting exists to flip, but headings' dim hash markers
    /// and fence rules also render as `tertiaryLabelColor` on the
    /// unhighlighted path, so this reads any styled foreground at all.
    private func hasNonLabelForeground(_ storage: NSTextStorage) -> Bool {
        countNonLabelForegroundRuns(storage) > 0
    }

    /// The number of contiguous foreground-colour runs distinct from
    /// `labelColor`. A code line with three coloured tokens contributes
    /// three; a fence rule painted `tertiaryLabelColor` end-to-end
    /// contributes one. Used to compare styled runs across a syntax-
    /// highlighting flip, where the fence rules stand either way and
    /// the tokens are what move.
    private func countNonLabelForegroundRuns(_ storage: NSTextStorage) -> Int {
        var count = 0
        storage.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let color = value as? NSColor, color != NSColor.labelColor {
                count += 1
            }
        }
        return count
    }

    // MARK: 1. Mounted editor updates across every scope pair, in place

    /// The editor is the app's one focus-holding view and it must not be
    /// re-parented for a preference change. Each scope pair below flips
    /// the setting under a mounted markdown page and asserts that the
    /// storage crossed the branch (styled → plain, or plain → styled)
    /// while the same `InkTextView` instance stayed in the stack.

    func testMountedEditorFlipsFromAllPagesToNeverWithoutReplacingTheEditor() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        try page(in: model, saying: "yesterday's page")
        let selected = try page(in: model, saying: Self.bareFenceMarkdownFixture)
        let roll = try mountRoll(model: model)
        republish(roll, model)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertEqual(model.selectedPageID, selected)
        XCTAssertTrue(
            hasNonBaseFont(storage),
            "allPages must lay heading and code fonts on the mounted markdown page"
        )

        model.previewRendering = .never
        republish(roll, model)

        XCTAssertTrue(
            roll.stack.editor === editor,
            "changing the scope tore down and re-parented the mounted editor"
        )
        XCTAssertTrue(
            editor.textStorage === storage,
            "the editor's storage was swapped, not restyled"
        )
        XCTAssertFalse(
            hasNonBaseFont(storage),
            "never must strip the mounted page back to plain ink"
        )
    }

    func testMountedEditorFlipsFromNeverToFocusedOnlyWithoutReplacingTheEditor() throws {
        let model = try makeModel()
        model.previewRendering = .never
        try page(in: model, saying: "yesterday's page")
        try page(in: model, saying: Self.bareFenceMarkdownFixture)
        let roll = try mountRoll(model: model)
        republish(roll, model)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertFalse(
            hasNonBaseFont(storage), "never is the baseline plain profile"
        )

        model.previewRendering = .focusedOnly
        republish(roll, model)

        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(
            hasNonBaseFont(storage),
            "focusedOnly must lay heading and code fonts on the focused page"
        )
    }

    func testMountedEditorFlipsFromNeverToAllPagesWithoutReplacingTheEditor() throws {
        let model = try makeModel()
        model.previewRendering = .never
        try page(in: model, saying: "yesterday's page")
        try page(in: model, saying: Self.bareFenceMarkdownFixture)
        let roll = try mountRoll(model: model)
        republish(roll, model)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertFalse(hasNonBaseFont(storage))

        model.previewRendering = .allPages
        republish(roll, model)

        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(
            hasNonBaseFont(storage),
            "allPages must reach the mounted editor as it reaches quiet days"
        )
    }

    // MARK: 2. Cache invalidation on syntax-highlighting change

    /// A populated quiet cache had the old highlighter's tokens baked in;
    /// flipping `syntaxHighlightingEnabled` has to drop it or a quiet day
    /// stays coloured after the reader turned colour off.
    func testChangingSyntaxHighlightingInvalidatesPopulatedQuietRenderingCache() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        model.syntaxHighlightingEnabled = true
        let quietPage = try page(in: model, saying: """
            ```swift
            let value = 1
            print(value)
            ```
            """)
        // A second mint moves the editor off the fenced page so it is a
        // quiet day rather than the focused one.
        try page(in: model, saying: "later that morning")

        let before = model.quietRendering(for: quietPage)
        let beforeRuns = countNonLabelForegroundRuns(
            NSTextStorage(attributedString: before.text)
        )
        XCTAssertGreaterThan(
            beforeRuns, 2,
            "the fixture failed to populate the cache with token colours to invalidate"
        )

        model.syntaxHighlightingEnabled = false
        let after = model.quietRendering(for: quietPage)
        let afterRuns = countNonLabelForegroundRuns(
            NSTextStorage(attributedString: after.text)
        )

        XCTAssertFalse(
            before === after,
            "flipping syntax highlighting did not drop the populated quiet cache"
        )
        XCTAssertLessThan(
            afterRuns, beforeRuns,
            "the rebuild after the flip did not shed the token colours the flip is about"
        )
    }

    // MARK: 3. Manually selected bare-fence language survives the transition

    /// The user picks a language for a bare fence while the page is
    /// focused. The label lives on the presentation state, not on the
    /// bytes, so it must still colour tokens when the editor leaves and
    /// the page becomes a quiet region of the roll.
    func testManualBareFenceLanguageSurvivesFocusToQuietTransition() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        model.syntaxHighlightingEnabled = true
        // `languageDetectionEnabled` stays off: the point here is the
        // user's explicit pick, not the detector's inference.
        let other = try page(in: model, saying: "another day")
        let bare = try page(in: model, saying: """
            ```
            let value = 1
            print(value)
            ```
            """)
        let roll = try mountRoll(model: model)
        republish(roll, model)
        XCTAssertEqual(
            roll.coordinator.currentSheet, bare,
            "the fixture failed to seat the editor on the fenced page before the pick"
        )

        // The user's pick on the still-focused bare fence: presentation
        // state keyed by the opening rule's paragraph location.
        model.setFenceRenderingLanguage("swift", sheet: bare, at: 0)

        // The transition: move the editor to `other`, which lets `bare`
        // become a quiet region of the roll.
        let otherTab = try XCTUnwrap(model.tabs.first(where: { $0.pageID == other })?.id)
        model.select(otherTab)
        republish(roll, model)
        XCTAssertEqual(model.selectedPageID, other)

        let rendering = model.quietRendering(for: bare)
        XCTAssertFalse(
            rendering.fenceRegions.isEmpty,
            "the bare fence's wash region did not survive the transition"
        )
        XCTAssertTrue(
            hasNonLabelForeground(NSTextStorage(attributedString: rendering.text)),
            "the quiet rebuild missed the swift tokens the user coloured while focused"
        )
    }

    // MARK: 4. Quiet fences carry wash-capable geometry

    /// A quiet region draws the same fence slab the mounted page does,
    /// so the region's `InkLayoutManager` must carry the fence's regions
    /// (ADR-0030). Empty regions here mean the wash cannot paint.
    func testQuietFenceReceivesWashCapableGeometry() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let quietPage = try page(in: model, saying: Self.bareFenceMarkdownFixture)
        try page(in: model, saying: "another day")
        let roll = try mountRoll(model: model)
        republish(roll, model)

        let region = try XCTUnwrap(roll.stack.quietRegions[quietPage])
        let layoutManager = try XCTUnwrap(region.layoutManager as? InkLayoutManager)

        XCTAssertFalse(
            layoutManager.fenceRegions.isEmpty,
            "the quiet region's layout manager holds no fence geometry, so no wash can draw"
        )
    }

    // MARK: 5. Quiet pages carry no unexplained block-label spacing

    /// Block created/modified stamps are an editor-only affordance
    /// (ADR-0030), so a quiet region must not reserve the paragraph gap
    /// the labels sit in and must not extend its top inset for a label
    /// row nothing will draw.
    func testQuietPagesDoNotRetainBlockLabelSpacing() throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        let quietPage = try page(in: model, saying: Self.bareFenceMarkdownFixture)
        try page(in: model, saying: "another day")
        let roll = try mountRoll(model: model)
        republish(roll, model)

        let region = try XCTUnwrap(roll.stack.quietRegions[quietPage])
        XCTAssertEqual(
            region.textContainerInset.height,
            InkEditorView.Coordinator.topInset,
            "a quiet region kept the editor's block-label reserve above its first line"
        )
        let storage = try XCTUnwrap(region.textStorage)
        var offenders = 0
        storage.enumerateAttribute(
            .paragraphStyle, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            if style.paragraphSpacingBefore >= InkEditorView.Coordinator.blockLabelReserve {
                offenders += 1
            }
        }
        XCTAssertEqual(
            offenders, 0,
            "a quiet paragraph reserved the editor-only block-label spacing"
        )
    }

    // MARK: 6. Scope changes recalculate the roll's measurement

    /// The rail's minimap is a reading of geometry, not of the page's
    /// content: bar count, extent order, viewport band. When a scope
    /// flip shortens heading and code lines back to plain ink, every
    /// downstream measurement must follow — the quiet region's own
    /// frame, the stack's document height, the `RollGeometry` handed to
    /// the rail, and the bar proportions the minimap maps that geometry
    /// through. What is asserted here is that they moved, not their
    /// pixel values, which belong to hardware verification.
    func testScopeChangeRecalculatesQuietHeightStackGeometryAndMinimapProportions()
        async throws {
        let model = try makeModel()
        model.previewRendering = .allPages
        // Enough writing on the quiet day to outgrow one cardful, so the
        // stack's own height is measured off the content rather than
        // pinned to the clip's viewport floor.
        let heavy = ([
            "# Heading one",
            "",
            "```swift",
        ] + (0..<20).map { "let value\($0) = \($0)" } + [
            "```",
            "",
        ] + (0..<20).map { "trailing prose \($0)" }).joined(separator: "\n")
        try page(in: model, saying: heavy)
        try page(in: model, saying: "another day")
        let roll = try mountRoll(model: model, height: 180)
        republish(roll, model)
        await settle()

        // The quiet region for the markdown fixture is the last row of
        // the roll, since the fixture was minted first and the editor
        // lands on the most recent page.
        let beforeRow = try XCTUnwrap(roll.stack.laidOut.last).body.frame
        let beforeDocumentHeight = roll.stack.frame.height
        let beforeMeasured = roll.stack.measuredGeometry
        let beforePublished = model.rollGeometry.geometry
        XCTAssertFalse(
            beforeMeasured.extents.isEmpty,
            "the fixture failed to hand the navigator any extents to compare"
        )

        model.previewRendering = .never
        republish(roll, model)
        await settle()

        let afterRow = try XCTUnwrap(roll.stack.laidOut.last).body.frame
        XCTAssertNotEqual(
            afterRow.height, beforeRow.height,
            "a scope flip did not remeasure the quiet page below the editor"
        )
        XCTAssertNotEqual(
            roll.stack.frame.height, beforeDocumentHeight,
            "the stack's document height did not follow its content"
        )
        let afterMeasured = roll.stack.measuredGeometry
        XCTAssertNotEqual(
            afterMeasured.documentHeight, beforeMeasured.documentHeight,
            "the measurement handed to the rail did not move with the scope"
        )
        XCTAssertNotEqual(
            afterMeasured.extents.map(\.height), beforeMeasured.extents.map(\.height),
            "per-page extents did not follow the newly styled row heights"
        )
        XCTAssertNotEqual(
            model.rollGeometry.geometry, beforePublished,
            "the published RollGeometry did not follow the remeasurement"
        )
        XCTAssertNotEqual(
            afterMeasured.extents.map { $0.lines.map(\.y) },
            beforeMeasured.extents.map { $0.lines.map(\.y) },
            "the navigator's line slivers did not update when the roll's lines did"
        )
    }

    // MARK: 7. `.never` for Markdown and for whole-file Source mode

    /// The Markdown page: mounted editor and every quiet region collapse
    /// to plain ink, heading fonts and token colours included.
    func testNeverCollapsesMarkdownStylingOnMountedAndQuietPages() throws {
        let model = try makeModel()
        model.previewRendering = .never
        model.syntaxHighlightingEnabled = true
        let quietPage = try page(in: model, saying: Self.bareFenceMarkdownFixture)
        try page(in: model, saying: Self.bareFenceMarkdownFixture)
        let roll = try mountRoll(model: model)
        republish(roll, model)

        let editorStorage = try XCTUnwrap(roll.stack.editor?.textStorage)
        XCTAssertFalse(
            hasNonBaseFont(editorStorage),
            "never must render the mounted markdown page as plain ink"
        )
        XCTAssertFalse(
            hasNonLabelForeground(editorStorage),
            "never must carry no token colour on the mounted page"
        )
        let quietStorage = try XCTUnwrap(
            roll.stack.quietRegions[quietPage]?.textStorage
        )
        XCTAssertFalse(hasNonBaseFont(quietStorage))
        XCTAssertFalse(hasNonLabelForeground(quietStorage))
    }

    /// The whole-file Source mode: `.never` outranks the file's own
    /// render-mode pick and collapses the buffer back to plain-file
    /// styling — no code font, no token colours — through the same
    /// `Coordinator.restyle()` path the roll's editor drives.
    func testNeverCollapsesWholeFileSourceModeStyling() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        let path = workspace.appendingPathComponent("example.swift")
        try Data("let value = 1\nprint(value)\n".utf8).write(to: path)

        let suiteName = "companion-day-scroll-preview-file-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "companion-scope-state-\(UUID().uuidString)", isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: stateDir) }
        let model = PageModel(
            formFactor: .panel,
            defaults: defaults,
            seams: .init(
                stateDirectory: stateDir,
                client: .ephemeral(tag: UUID().uuidString),
                saveDebounce: nil
            )
        )
        model.loadStateIfNeeded()
        model.syntaxHighlightingEnabled = true
        model.previewRendering = .allPages
        model.openFile(at: path)
        let fileID = try XCTUnwrap(model.activeFile?.id)
        XCTAssertTrue(
            fileID.isFileID,
            "the fixture did not open a file id — the Source-mode path is not under test"
        )
        model.selectFileRenderMode(.source("swift"), for: fileID)

        let coordinator = InkEditorView.Coordinator(model: model)
        let textView = InkEditorView.makeInkTextView(
            model: model, sheetID: fileID, coordinator: coordinator
        )
        let storage = try XCTUnwrap(textView.textStorage)
        // The default typeface names one family for both prose and code
        // (System Monospaced), so font identity cannot distinguish the
        // two paths. Foreground colour can: `restyleSourceFile` lays
        // token colour under `.allPages` with highlighting on, and
        // `restylePlainFile` does not.
        XCTAssertTrue(
            hasNonLabelForeground(storage),
            "Source mode with highlighting on did not colour a keyword to strip"
        )

        model.previewRendering = .never
        coordinator.applyPreviewRendering(.never)

        XCTAssertFalse(
            hasNonLabelForeground(storage),
            "never on a Source-mode file kept its token colours"
        )
        XCTAssertEqual(
            textView.textContainerInset.height,
            InkEditorView.Coordinator.topInset,
            "the plain-file inset must fall back to the ordinary top inset"
        )
    }

    // MARK: 8. Notifications from one model do not refresh another model's roll

    /// The roll registers `quietRenderingsDidInvalidateNotification` with
    /// `object: model`, so a second model posting the same name posts to
    /// its own subscribers alone. A spy on `modelA` sees only `modelA`'s
    /// own scope flip; `modelB` writing to its scope must not reach it.
    func testNotificationsFromAnotherModelDoNotReachThisRoll() throws {
        let modelA = try makeModel(suite: "notif-a")
        modelA.previewRendering = .allPages
        try page(in: modelA, saying: Self.bareFenceMarkdownFixture)
        try page(in: modelA, saying: "another day")
        let rollA = try mountRoll(model: modelA)
        republish(rollA, modelA)

        let modelB = try makeModel(suite: "notif-b")
        modelB.previewRendering = .allPages
        try page(in: modelB, saying: "other content")

        let received = Received()
        let token = NotificationCenter.default.addObserver(
            forName: PageModel.quietRenderingsDidInvalidateNotification,
            object: modelA,
            queue: nil
        ) { _ in received.count += 1 }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }

        modelB.previewRendering = .focusedOnly
        XCTAssertEqual(
            received.count, 0,
            "modelA's observer received modelB's invalidation, so a roll would too"
        )

        modelA.previewRendering = .focusedOnly
        XCTAssertEqual(
            received.count, 1,
            "modelA's own scope flip did not deliver the notification the roll listens for"
        )
    }

    /// Counter box passed into the notification closure. A class rather
    /// than a captured `var Int` so the closure stays `Sendable` under
    /// strict concurrency without lying with `nonisolated(unsafe)`. The
    /// notification queue is `nil`, so posts are delivered synchronously
    /// in the poster's context (main here); no locking is needed.
    private final class Received: @unchecked Sendable {
        var count = 0
    }
}
