import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class LanguageDetectionPasteIntegrationTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-language-paste-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return isolatedModel(defaults: defaults)
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
