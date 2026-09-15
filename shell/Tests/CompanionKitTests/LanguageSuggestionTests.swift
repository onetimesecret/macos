import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class LanguageSuggestionTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-language-suggestion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let model = isolatedModel(defaults: defaults)
        model.languageDetectionEnabled = true
        return model
    }

    private func makeEditor(
        detector: @escaping LanguageDetectionService.Detector = { _ in nil }
    ) throws -> (PageModel, InkEditorView.Coordinator, InkTextView) {
        let model = try makeModel()
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let coordinator = InkEditorView.Coordinator(
            model: model,
            ordinaryPasteShadowEnabled: false,
            languageDetectionService: LanguageDetectionService(detector: detector)
        )
        let textView = InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator
        )
        textView.isEditable = true
        return (model, coordinator, textView)
    }

    private func insert(_ text: String, into textView: InkTextView) {
        textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
    }

    private func settleMainQueue() {
        let settled = expectation(description: "main queue settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
    }

    func testDetectionSettingDisablesDetectorBackedAction() throws {
        let detectorCalled = expectation(description: "detector called")
        detectorCalled.isInverted = true
        let (model, coordinator, textView) = try makeEditor(detector: { _ in
            detectorCalled.fulfill()
            return "swift"
        })
        insert("let value = 1", into: textView)
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        model.languageDetectionEnabled = false
        coordinator.applyLanguageDetection(false)

        XCTAssertFalse(textView.canDetectCodeLanguage)
        XCTAssertFalse(model.languageActions.canDetect)
        XCTAssertTrue(model.languageActions.canChoose)
        textView.detectCodeLanguage(nil)
        wait(for: [detectorCalled], timeout: 0.1)
    }

    func testManualPickerRemainsAvailableWhenDetectionAbstains() throws {
        let detectorCalled = expectation(description: "detector called")
        let (model, coordinator, textView) = try makeEditor(detector: { _ in
            detectorCalled.fulfill()
            return nil
        })
        let source = "let value = 1"
        insert(source, into: textView)
        textView.setSelectedRange(NSRange(location: 0, length: source.utf16.count))

        textView.detectCodeLanguage(nil)
        wait(for: [detectorCalled], timeout: 1)
        settleMainQueue()

        let menu = NSMenu()
        coordinator.appendLanguageItems(to: menu)
        let choose = try XCTUnwrap(menu.items.first { $0.title == "Choose Language" })
        XCTAssertNotNil(choose.submenu?.items.first { $0.title == "Swift" })
        XCTAssertTrue(model.languageActions.canChoose)

        textView.chooseCodeLanguage("swift")

        XCTAssertEqual(textView.string, "```swift\n\(source)\n```")
    }

    func testIneligibleNonemptySelectionIsNotReportedAsNoSelection() throws {
        let (model, _, textView) = try makeEditor()
        let source = "```\nlet value = 1\n```\nafter"
        insert(source, into: textView)

        textView.setSelectedRange(NSRange(location: 0, length: source.utf16.count))

        XCTAssertFalse(model.languageActions.canChoose)
        XCTAssertEqual(model.languageActions.selectionIsEmpty, false)
    }

    func testUnmountingEditorRetiresLanguageMenuAvailability() throws {
        let (model, coordinator, textView) = try makeEditor()
        insert("let value = 1", into: textView)
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        XCTAssertTrue(model.languageActions.canChoose)

        coordinator.parkEditor()

        XCTAssertFalse(model.languageActions.canChoose)
        XCTAssertFalse(model.languageActions.canDetect)
        XCTAssertNil(model.languageActions.selectionIsEmpty)
    }

    func testManualSelectionWrapIsOneExplicitEdit() throws {
        let (_, coordinator, textView) = try makeEditor()
        let source = "let value = 1"
        insert(source, into: textView)
        textView.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
        var emitted: [[DocumentEditOp]] = []
        coordinator.onEmit = { emitted.append($0) }

        coordinator.applyManualLanguage("swift")

        XCTAssertEqual(textView.string, "```swift\n\(source)\n```")
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(
            emitted.first,
            [.del(at: 0, len: source.utf16.count), .ins(at: 0, text: textView.string)]
        )
    }

    func testBareFenceManualLanguageIsDisplayOnlyAndUsesCodeFont() throws {
        let (_, coordinator, textView) = try makeEditor()
        let source = "```\nlet value = 1\n```"
        insert(source, into: textView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        var emitted: [[DocumentEditOp]] = []
        coordinator.onEmit = { emitted.append($0) }

        coordinator.applyManualLanguage("swift")

        XCTAssertEqual(textView.string, source)
        XCTAssertTrue(emitted.isEmpty)
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font, InkStyle.codeFont)
        let color = try XCTUnwrap(
            textView.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        )
        XCTAssertEqual(color, InkStyle.tokenColor(.keyword))
    }

    func testDetectedBareFenceUnsupportedScannerLanguageUsesCodeFontWithoutTokenColors() throws {
        let detectorCalled = expectation(description: "detector called")
        let (_, coordinator, textView) = try makeEditor(detector: { _ in
            detectorCalled.fulfill()
            return "kotlin"
        })
        let source = "```\nfun answer() = 42\n```"
        insert(source, into: textView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        textView.detectCodeLanguage(nil)
        wait(for: [detectorCalled], timeout: 1)
        settleMainQueue()

        let menu = NSMenu()
        coordinator.appendLanguageItems(to: menu)
        let highlight = try XCTUnwrap(
            menu.items.first { $0.title == "Use Kotlin for Highlighting" }
        )
        XCTAssertTrue(
            NSApp.sendAction(try XCTUnwrap(highlight.action), to: highlight.target, from: highlight)
        )

        XCTAssertEqual(textView.string, source)
        let codeOffset = (source as NSString).range(of: "fun").location
        let font = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: codeOffset, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(font, InkStyle.codeFont)
        let color = try XCTUnwrap(
            textView.textStorage?.attribute(.foregroundColor, at: codeOffset, effectiveRange: nil) as? NSColor
        )
        XCTAssertEqual(color, NSColor.labelColor)
    }

    func testDetectedBareFenceSuggestionIsVisibleAndCanInsertLabel() throws {
        let detectorCalled = expectation(description: "detector called")
        let (_, coordinator, textView) = try makeEditor(detector: { data in
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "let value = 1\n")
            detectorCalled.fulfill()
            return "swift"
        })
        insert("```\nlet value = 1\n```", into: textView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        XCTAssertTrue(textView.canDetectCodeLanguage)
        textView.detectCodeLanguage(nil)
        wait(for: [detectorCalled], timeout: 1)
        settleMainQueue()

        let menu = NSMenu()
        coordinator.appendLanguageItems(to: menu)
        XCTAssertTrue(menu.items.contains { $0.title == "Suggested: Swift" })
        XCTAssertTrue(menu.items.contains { $0.title == "Dismiss Suggestion" })
        XCTAssertTrue(menu.items.contains { $0.title == "Paste Without Detection" })
        let insert = try XCTUnwrap(menu.items.first { $0.title == "Insert swift in Fence" })
        var emitted: [[DocumentEditOp]] = []
        coordinator.onEmit = { emitted.append($0) }

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(insert.action), to: insert.target, from: insert))

        XCTAssertEqual(textView.string, "```swift\nlet value = 1\n```")
        XCTAssertEqual(emitted, [[.ins(at: 3, text: "swift")]])
    }

    func testExplicitUnknownFenceAndCaretAfterClosedFenceAreNotTargets() throws {
        let (_, coordinator, textView) = try makeEditor()
        let source = "```unknown\n++\n```\nafter"
        insert(source, into: textView)

        textView.setSelectedRange(NSRange(location: 12, length: 0))
        var menu = NSMenu()
        coordinator.appendLanguageItems(to: menu)
        XCTAssertEqual(menu.items.first { $0.title == "Detect Code Language…" }?.isEnabled, false)

        textView.setSelectedRange(NSRange(location: 20, length: 0))
        menu = NSMenu()
        coordinator.appendLanguageItems(to: menu)
        XCTAssertEqual(menu.items.first { $0.title == "Detect Code Language…" }?.isEnabled, false)
    }
}
