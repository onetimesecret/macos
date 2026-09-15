import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class LanguageDetectionPasteIntegrationTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-language-paste-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let model = isolatedModel(defaults: defaults)
        model.languageDetectionEnabled = true
        return model
    }

    private func mintPage(in model: PageModel) throws -> UInt64 {
        model.newPage()
        return try XCTUnwrap(model.selectedPageID)
    }

    private func makePasteboard(_ text: String) -> NSPasteboard {
        let board = NSPasteboard(name: .init("companion-language-paste-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(text, forType: .string)
        addTeardownBlock { board.clearContents() }
        return board
    }

    private func makeEditor(
        model: PageModel,
        page: UInt64,
        enabled: Bool,
        service: LanguageDetectionService,
        payload: @escaping () -> Data?
    ) -> (InkEditorView.Coordinator, InkTextView) {
        let coordinator = InkEditorView.Coordinator(
            model: model,
            ordinaryPasteShadowEnabled: enabled,
            languageDetectionService: service,
            ordinaryPastePayload: payload
        )
        let textView = InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator
        )
        textView.isEditable = true
        return (coordinator, textView)
    }

    func testLanguageDetectionOffKeepsAutofencingInert() throws {
        let detectorCalled = expectation(description: "detector called")
        detectorCalled.isInverted = true
        let service = LanguageDetectionService(detector: { _ in
            detectorCalled.fulfill()
            return "swift"
        })
        let model = try makeModel()
        model.languageDetectionEnabled = false
        model.automaticallyFencePastes = true
        let page = try mintPage(in: model)
        var payloadReads = 0
        let (_, textView) = makeEditor(
            model: model,
            page: page,
            enabled: false,
            service: service,
            payload: {
                payloadReads += 1
                return Data("let value = 1".utf8)
            }
        )
        var plainPasteCalls = 0

        textView.performOrdinaryPaste(nil) { _ in
            plainPasteCalls += 1
            textView.insertText("let value = 1", replacementRange: textView.selectedRange())
        }

        XCTAssertEqual(plainPasteCalls, 1)
        XCTAssertEqual(payloadReads, 0)
        XCTAssertEqual(textView.string, "let value = 1")
        wait(for: [detectorCalled], timeout: 0.1)
    }

    func testGateOffNeitherReadsPayloadNorCallsDetector() throws {
        let detectorCalled = expectation(description: "detector called")
        detectorCalled.isInverted = true
        let board = makePasteboard("let value = 1")
        var payloadReads = 0
        let service = LanguageDetectionService(detector: { _ in
            detectorCalled.fulfill()
            return "swift"
        })
        let model = try makeModel()
        let page = try mintPage(in: model)
        let (coordinator, _) = makeEditor(
            model: model,
            page: page,
            enabled: false,
            service: service,
            payload: {
                payloadReads += 1
                return board.string(forType: .string).map { Data($0.utf8) }
            }
        )

        XCTAssertNil(coordinator.ordinaryPasteMeasurementPayload())

        XCTAssertEqual(payloadReads, 0)
        XCTAssertNil(service.currentRequest)
        wait(for: [detectorCalled], timeout: 0.1)
    }

    func testGateOnSubmitsOneCapturedPayloadWithEditorContext() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let measured = expectation(description: "measurement reported")
        let board = makePasteboard("func greet() {}")
        var payloadReads = 0
        let service = LanguageDetectionService(detector: { data in
            detectorStarted.signal()
            _ = releaseDetector.wait(timeout: .now() + 2)
            return String(decoding: data, as: UTF8.self).hasPrefix("func") ? "swift" : nil
        })
        let model = try makeModel()
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: true,
            service: service,
            payload: {
                payloadReads += 1
                return board.string(forType: .string).map { Data($0.utf8) }
            }
        )
        let selection = NSRange(location: 0, length: 0)
        textView.setSelectedRange(selection)
        coordinator.onOrdinaryPasteMeasurement = { measurement in
            XCTAssertEqual(measurement.result.language, "swift")
            XCTAssertGreaterThanOrEqual(measurement.elapsed, .zero)
            measured.fulfill()
        }

        let captured = try XCTUnwrap(coordinator.ordinaryPasteMeasurementPayload())
        coordinator.observeOrdinaryPaste(payload: captured)

        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)
        let request = try XCTUnwrap(service.currentRequest)
        XCTAssertEqual(payloadReads, 1)
        XCTAssertEqual(request.data, Data("func greet() {}".utf8))
        XCTAssertEqual(request.documentID, page)
        XCTAssertEqual(request.revision, 0)
        XCTAssertEqual(request.targetRange, selection)
        XCTAssertEqual(request.selectionSnapshot, selection)
        XCTAssertEqual(request.trigger, .ordinaryPaste)
        releaseDetector.signal()
        wait(for: [measured], timeout: 1)
    }

    func testCharacterEditDropsPendingMeasurement() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let measured = expectation(description: "stale edit measurement")
        measured.isInverted = true
        let board = makePasteboard("print('hello')")
        let service = LanguageDetectionService(detector: { _ in
            detectorStarted.signal()
            _ = releaseDetector.wait(timeout: .now() + 2)
            return "python"
        })
        let model = try makeModel()
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: true,
            service: service,
            payload: { board.string(forType: .string).map { Data($0.utf8) } }
        )
        coordinator.onOrdinaryPasteMeasurement = { _ in measured.fulfill() }
        let captured = try XCTUnwrap(coordinator.ordinaryPasteMeasurementPayload())
        coordinator.observeOrdinaryPaste(payload: captured)
        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)

        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        releaseDetector.signal()

        wait(for: [measured], timeout: 0.2)
        XCTAssertNil(service.currentRequest)
        XCTAssertNil(service.currentResult)
    }

    func testPageSwitchDropsPendingMeasurement() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let measured = expectation(description: "stale switch measurement")
        measured.isInverted = true
        let board = makePasteboard("fn main() {}")
        let service = LanguageDetectionService(detector: { _ in
            detectorStarted.signal()
            _ = releaseDetector.wait(timeout: .now() + 2)
            return "rust"
        })
        let model = try makeModel()
        let first = try mintPage(in: model)
        let second = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: first,
            enabled: true,
            service: service,
            payload: { board.string(forType: .string).map { Data($0.utf8) } }
        )
        coordinator.onOrdinaryPasteMeasurement = { _ in measured.fulfill() }
        let captured = try XCTUnwrap(coordinator.ordinaryPasteMeasurementPayload())
        coordinator.observeOrdinaryPaste(payload: captured)
        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)

        coordinator.moveEditor(
            textView, to: second, storage: model.storage(for: second), restoringScrollIn: nil
        )
        releaseDetector.signal()

        wait(for: [measured], timeout: 0.2)
        XCTAssertNil(service.currentRequest)
        XCTAssertNil(service.currentResult)
    }

    func testSelectionAwayAndBackStillDropsPendingMeasurement() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let measured = expectation(description: "stale selection measurement")
        measured.isInverted = true
        let board = makePasteboard("func greet() {}")
        let service = LanguageDetectionService(detector: { _ in
            detectorStarted.signal()
            _ = releaseDetector.wait(timeout: .now() + 2)
            return "swift"
        })
        let model = try makeModel()
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: true,
            service: service,
            payload: { board.string(forType: .string).map { Data($0.utf8) } }
        )
        textView.string = "abc"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.onOrdinaryPasteMeasurement = { _ in measured.fulfill() }
        let captured = try XCTUnwrap(coordinator.ordinaryPasteMeasurementPayload())
        coordinator.observeOrdinaryPaste(payload: captured)
        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        releaseDetector.signal()

        wait(for: [measured], timeout: 0.2)
        XCTAssertNil(service.currentRequest)
        XCTAssertNil(service.currentResult)
    }

    func testReadOnlyRoundTripStillDropsPendingMeasurement() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let measured = expectation(description: "stale editability measurement")
        measured.isInverted = true
        let board = makePasteboard("fn main() {}")
        let service = LanguageDetectionService(detector: { _ in
            detectorStarted.signal()
            _ = releaseDetector.wait(timeout: .now() + 2)
            return "rust"
        })
        let model = try makeModel()
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: true,
            service: service,
            payload: { board.string(forType: .string).map { Data($0.utf8) } }
        )
        coordinator.onOrdinaryPasteMeasurement = { _ in measured.fulfill() }
        let captured = try XCTUnwrap(coordinator.ordinaryPasteMeasurementPayload())
        coordinator.observeOrdinaryPaste(payload: captured)
        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)

        coordinator.updateEditability(of: textView, to: false)
        coordinator.updateEditability(of: textView, to: true)
        releaseDetector.signal()

        wait(for: [measured], timeout: 0.2)
        XCTAssertNil(service.currentRequest)
        XCTAssertNil(service.currentResult)
    }

    func testAutomaticPasteFencingAppliesOneDetectedReplacement() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let edited = expectation(description: "fenced replacement emitted")
        let payload = "func greet() {\n    print(\"hello\")\n}"
        let service = LanguageDetectionService(detector: { data in
            XCTAssertEqual(String(decoding: data, as: UTF8.self), payload)
            detectorStarted.signal()
            _ = releaseDetector.wait(timeout: .now() + 2)
            return "swift"
        })
        let model = try makeModel()
        model.automaticallyFencePastes = true
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: false,
            service: service,
            payload: { Data(payload.utf8) }
        )
        coordinator.onEmit = { ops in
            XCTAssertEqual(ops, [.ins(at: 0, text: "```swift\n\(payload)\n```")])
            edited.fulfill()
        }
        var plainPasteCalls = 0

        textView.performOrdinaryPaste(nil) { _ in plainPasteCalls += 1 }

        XCTAssertEqual(plainPasteCalls, 0)
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)
        releaseDetector.signal()
        wait(for: [edited], timeout: 1)
        XCTAssertEqual(textView.string, "```swift\n\(payload)\n```")
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: textView.string.utf16.count, length: 0)
        )
    }

    func testTypingAfterAutomaticPasteUsesASeparateUndoStep() throws {
        let fenced = expectation(description: "automatic paste applied")
        let payload = "func greet() {}"
        let service = LanguageDetectionService(detector: { _ in "swift" })
        let model = try makeModel()
        model.automaticallyFencePastes = true
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: false,
            service: service,
            payload: { Data(payload.utf8) }
        )
        coordinator.onEmit = { _ in fenced.fulfill() }

        textView.performOrdinaryPaste(nil) { _ in XCTFail("eligible paste must be held") }
        wait(for: [fenced], timeout: 1)
        coordinator.onEmit = nil
        let block = "```swift\n\(payload)\n```"
        XCTAssertEqual(textView.string, block)

        textView.insertText("x", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, block + "x")

        coordinator.step(back: true)
        XCTAssertEqual(textView.string, block)
        coordinator.step(back: true)
        XCTAssertEqual(textView.string, "")
    }

    func testAutomaticPasteAbstentionFallsBackToOnePlainReplacement() throws {
        let edited = expectation(description: "plain fallback emitted")
        let payload = "ordinary prose"
        let service = LanguageDetectionService(detector: { _ in nil })
        let model = try makeModel()
        model.automaticallyFencePastes = true
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: false,
            service: service,
            payload: { Data(payload.utf8) }
        )
        coordinator.onEmit = { ops in
            XCTAssertEqual(ops, [.ins(at: 0, text: payload)])
            edited.fulfill()
        }

        textView.performOrdinaryPaste(nil) { _ in XCTFail("eligible paste must be captured once") }

        wait(for: [edited], timeout: 1)
        XCTAssertEqual(textView.string, payload)
    }

    func testAutomaticPasteAcrossLaterListParagraphStaysImmediateAndPlain() throws {
        let detectorCalled = expectation(description: "detector called")
        detectorCalled.isInverted = true
        let service = LanguageDetectionService(detector: { _ in
            detectorCalled.fulfill()
            return "swift"
        })
        let model = try makeModel()
        model.automaticallyFencePastes = true
        let page = try mintPage(in: model)
        let (_, textView) = makeEditor(
            model: model,
            page: page,
            enabled: false,
            service: service,
            payload: { Data("replacement".utf8) }
        )
        let existing = "ordinary line\n- list item\n"
        textView.insertText(existing, replacementRange: NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: existing.utf16.count))
        var plainPasteCalls = 0

        textView.performOrdinaryPaste(nil) { _ in
            plainPasteCalls += 1
            textView.insertText("replacement", replacementRange: textView.selectedRange())
        }

        XCTAssertEqual(plainPasteCalls, 1)
        XCTAssertEqual(textView.string, "replacement")
        wait(for: [detectorCalled], timeout: 0.1)
    }

    func testNeverKeepsAutomaticPasteInsideAFenceImmediateAndPlain() throws {
        let detectorCalled = expectation(description: "detector called")
        detectorCalled.isInverted = true
        let payload = "let value = 1"
        let service = LanguageDetectionService(detector: { _ in
            detectorCalled.fulfill()
            return "swift"
        })
        let model = try makeModel()
        model.previewRendering = .never
        model.automaticallyFencePastes = true
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: false,
            service: service,
            payload: { Data(payload.utf8) }
        )
        textView.insertText("```sh\n- x", replacementRange: NSRange(location: 0, length: 0))
        coordinator.restyle()
        XCTAssertEqual(coordinator.fenceRegions, [NSRange(location: 0, length: 9)])
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        var plainPasteCalls = 0

        textView.performOrdinaryPaste(nil) { _ in
            plainPasteCalls += 1
            textView.insertText(payload, replacementRange: textView.selectedRange())
        }

        XCTAssertEqual(plainPasteCalls, 1)
        XCTAssertEqual(textView.string, "```sh\n- \(payload)x")
        wait(for: [detectorCalled], timeout: 0.1)
    }

    func testAutomaticPasteBypassUsesImmediatePlainPasteWithoutDetection() throws {
        let detectorCalled = expectation(description: "detector called")
        detectorCalled.isInverted = true
        let payload = "let value = 1"
        let service = LanguageDetectionService(detector: { _ in
            detectorCalled.fulfill()
            return "swift"
        })
        let model = try makeModel()
        model.automaticallyFencePastes = true
        let page = try mintPage(in: model)
        var payloadReads = 0
        let (_, textView) = makeEditor(
            model: model,
            page: page,
            enabled: true,
            service: service,
            payload: {
                payloadReads += 1
                return Data(payload.utf8)
            }
        )
        var plainPasteCalls = 0

        textView.performOrdinaryPaste(nil, bypassingAutomaticFencing: true) { _ in
            plainPasteCalls += 1
            textView.insertText(payload, replacementRange: textView.selectedRange())
        }

        XCTAssertEqual(plainPasteCalls, 1)
        XCTAssertEqual(payloadReads, 0)
        XCTAssertEqual(textView.string, payload)
        wait(for: [detectorCalled], timeout: 0.1)
    }

    func testEditDuringAutomaticDetectionFallsBackAtCurrentSelection() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let payload = "fn main() {}"
        let service = LanguageDetectionService(detector: { _ in
            detectorStarted.signal()
            _ = releaseDetector.wait(timeout: .now() + 2)
            return "rust"
        })
        let model = try makeModel()
        model.automaticallyFencePastes = true
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: false,
            service: service,
            payload: { Data(payload.utf8) }
        )
        _ = coordinator

        textView.performOrdinaryPaste(nil) { _ in XCTFail("paste should be held") }
        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)
        textView.insertText("x", replacementRange: textView.selectedRange())
        releaseDetector.signal()

        let settled = expectation(description: "stale detector settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(textView.string, "x\(payload)")
        XCTAssertNotEqual(
            model.notice,
            "Paste canceled because the editor changed before detection finished."
        )
        XCTAssertNil(service.currentResult)
        XCTAssertTrue(textView.coordinator === coordinator)
    }

    func testSelectionChangeDuringAutomaticDetectionFallsBackAtCurrentSelection() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let fallbackApplied = expectation(description: "plain fallback applied")
        let payload = "let value = 1"
        let service = LanguageDetectionService(detector: { _ in
            detectorStarted.signal()
            _ = releaseDetector.wait(timeout: .now() + 2)
            return "swift"
        })
        let model = try makeModel()
        model.automaticallyFencePastes = true
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: false,
            service: service,
            payload: { Data(payload.utf8) }
        )
        textView.string = "abc"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.performOrdinaryPaste(nil) { _ in XCTFail("paste should be held") }
        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)
        textView.setSelectedRange(NSRange(location: 1, length: 1))
        coordinator.onEmit = { _ in
            if textView.string == "a\(payload)c" {
                fallbackApplied.fulfill()
            }
        }

        wait(for: [fallbackApplied], timeout: 1)
        releaseDetector.signal()
        XCTAssertEqual(textView.string, "a\(payload)c")
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: 1 + payload.utf16.count, length: 0)
        )
        XCTAssertTrue(textView.coordinator === coordinator)
    }

    func testSecondAutomaticPasteSettlesFirstAsPlainBeforeDetection() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let secondPasteApplied = expectation(description: "second paste applied")
        var payloads = ["first\n", "func second() {}"]
        let service = LanguageDetectionService(detector: { data in
            let payload = String(decoding: data, as: UTF8.self)
            if payload == "first\n" {
                detectorStarted.signal()
                _ = releaseDetector.wait(timeout: .now() + 2)
            }
            return "swift"
        })
        let model = try makeModel()
        model.automaticallyFencePastes = true
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: false,
            service: service,
            payload: { Data(payloads.removeFirst().utf8) }
        )
        coordinator.onEmit = { _ in
            if textView.string == "first\n```swift\nfunc second() {}\n```" {
                secondPasteApplied.fulfill()
            }
        }

        textView.performOrdinaryPaste(nil) { _ in XCTFail("first paste should be held") }
        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)
        textView.performOrdinaryPaste(nil) { _ in XCTFail("second paste should be held") }
        XCTAssertEqual(textView.string, "first\n")
        releaseDetector.signal()

        wait(for: [secondPasteApplied], timeout: 1)
        XCTAssertEqual(textView.string, "first\n```swift\nfunc second() {}\n```")
        XCTAssertTrue(textView.coordinator === coordinator)
    }

    func testDocumentSwitchCancelsPendingAutomaticPasteWithoutInsertion() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let payload = "fn main() {}"
        let service = LanguageDetectionService(detector: { _ in
            detectorStarted.signal()
            _ = releaseDetector.wait(timeout: .now() + 2)
            return "rust"
        })
        let model = try makeModel()
        model.automaticallyFencePastes = true
        let first = try mintPage(in: model)
        let second = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: first,
            enabled: false,
            service: service,
            payload: { Data(payload.utf8) }
        )

        textView.performOrdinaryPaste(nil) { _ in XCTFail("paste should be held") }
        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)
        coordinator.moveEditor(
            textView, to: second, storage: model.storage(for: second), restoringScrollIn: nil
        )
        releaseDetector.signal()

        let settled = expectation(description: "stale detector settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(model.storage(for: first).string, "")
        XCTAssertEqual(model.storage(for: second).string, "")
        XCTAssertEqual(
            model.notice,
            "Paste canceled because the editor changed before detection finished."
        )
        XCTAssertNil(service.currentResult)
        XCTAssertTrue(textView.coordinator === coordinator)
    }

    func testOrdinaryPasteRemainsImmediatePlainAndRunsExactlyOnce() throws {
        let detectorStarted = DispatchSemaphore(value: 0)
        let releaseDetector = DispatchSemaphore(value: 0)
        let measured = expectation(description: "paste measurement")
        let payload = "**plain**\nlet value = 1"
        let board = makePasteboard(payload)
        let service = LanguageDetectionService(detector: { _ in
            detectorStarted.signal()
            _ = releaseDetector.wait(timeout: .now() + 2)
            return "swift"
        })
        let model = try makeModel()
        let page = try mintPage(in: model)
        let (coordinator, textView) = makeEditor(
            model: model,
            page: page,
            enabled: true,
            service: service,
            payload: { board.string(forType: .string).map { Data($0.utf8) } }
        )
        coordinator.onOrdinaryPasteMeasurement = { _ in measured.fulfill() }
        var pasteCalls = 0

        textView.performOrdinaryPaste(nil) { _ in
            pasteCalls += 1
            XCTAssertTrue(textView.readSelection(from: board, type: .string))
        }

        XCTAssertEqual(pasteCalls, 1)
        XCTAssertEqual(textView.string, payload)
        XCTAssertEqual(detectorStarted.wait(timeout: .now() + 1), .success)
        releaseDetector.signal()
        wait(for: [measured], timeout: 1)
    }
}
