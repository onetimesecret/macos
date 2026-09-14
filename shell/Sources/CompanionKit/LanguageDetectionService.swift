import Foundation

/// The action that requested source-language inference.
public enum LanguageDetectionTrigger: Sendable, Hashable {
    case ordinaryPaste
    case manual
    case fenceSuggestion
}

/// Immutable input and editor context for one inference request.
public struct LanguageDetectionRequest: Sendable, Hashable {
    public let requestID: UUID
    public let documentID: UInt64
    public let revision: UInt64
    public let targetRange: NSRange
    public let trigger: LanguageDetectionTrigger
    public let selectionSnapshot: NSRange
    public let data: Data

    public init(
        requestID: UUID = UUID(),
        documentID: UInt64,
        revision: UInt64,
        targetRange: NSRange,
        trigger: LanguageDetectionTrigger,
        selectionSnapshot: NSRange,
        data: Data
    ) {
        self.requestID = requestID
        self.documentID = documentID
        self.revision = revision
        self.targetRange = targetRange
        self.trigger = trigger
        self.selectionSnapshot = selectionSnapshot
        self.data = data
    }

    public var context: LanguageDetectionContext {
        LanguageDetectionContext(
            requestID: requestID,
            documentID: documentID,
            revision: revision,
            targetRange: targetRange,
            trigger: trigger,
            selectionSnapshot: selectionSnapshot
        )
    }
}

/// Request identity and editor context without the inference input snapshot.
public struct LanguageDetectionContext: Sendable, Hashable {
    public let requestID: UUID
    public let documentID: UInt64
    public let revision: UInt64
    public let targetRange: NSRange
    public let trigger: LanguageDetectionTrigger
    public let selectionSnapshot: NSRange
}

/// A current, context-validated inference result.
public struct LanguageDetectionResult: Sendable, Hashable {
    public let context: LanguageDetectionContext
    public let language: String?
}

/// Runs source-language inference serially while retaining at most one running
/// request and the newest pending request for each document.
public final class LanguageDetectionService: @unchecked Sendable {
    public typealias Detector = @Sendable (Data) -> String?
    public typealias ContextValidator = @Sendable (LanguageDetectionContext) -> Bool
    public typealias Completion = @Sendable (LanguageDetectionResult) -> Void

    private struct Work: Sendable {
        let request: LanguageDetectionRequest
        let generation: UInt64
        let validator: ContextValidator
        let completion: Completion
    }

    private struct Delivery: Sendable {
        let context: LanguageDetectionContext
        let generation: UInt64
        let validator: ContextValidator
        let completion: Completion
    }

    private struct State {
        var generation: UInt64 = 0
        var running: Work?
        var pending: [UInt64: Work] = [:]
        var pendingOrder: [UInt64] = []
        var currentRequests: [UInt64: Work] = [:]
        var currentResults: [UInt64: (generation: UInt64, result: LanguageDetectionResult)] = [:]
    }

    private let detector: Detector
    private let workerQueue: DispatchQueue
    private let completionQueue: DispatchQueue
    private let lock = NSLock()
    private var state = State()

    public init(
        detector: @escaping Detector = CompanionClient.detectSourceLanguage(in:),
        workerQueue: DispatchQueue = DispatchQueue(
            label: "com.onetimesecret.companion.language-detection",
            qos: .userInitiated
        ),
        completionQueue: DispatchQueue = .main
    ) {
        self.detector = detector
        self.workerQueue = workerQueue
        self.completionQueue = completionQueue
    }

    /// The newest request still eligible to produce a result.
    public var currentRequest: LanguageDetectionRequest? {
        locked { state.currentRequests.values.max(by: { $0.generation < $1.generation })?.request }
    }

    /// The newest result that passed its supplied context validator.
    public var currentResult: LanguageDetectionResult? {
        locked { state.currentResults.values.max(by: { $0.generation < $1.generation })?.result }
    }

    /// Submit work without creating an unbounded per-document queue. If inference
    /// is already running, this replaces pending work for the same document.
    public func submit(
        _ request: LanguageDetectionRequest,
        validating validator: @escaping ContextValidator,
        completion: @escaping Completion
    ) {
        let work: Work
        var shouldStart = false

        lock.lock()
        state.generation &+= 1
        work = Work(
            request: request,
            generation: state.generation,
            validator: validator,
            completion: completion
        )
        state.currentRequests[request.documentID] = work
        state.currentResults[request.documentID] = nil
        if state.running == nil {
            state.running = work
            shouldStart = true
        } else {
            if state.pending[request.documentID] == nil {
                state.pendingOrder.append(request.documentID)
            }
            state.pending[request.documentID] = work
        }
        lock.unlock()

        if shouldStart {
            start(work)
        }
    }

    /// Cancel the current request if its identity still matches. A detector call
    /// already in progress is allowed to return, but its result is discarded.
    public func cancel(requestID: UUID) {
        lock.lock()
        guard let entry = state.currentRequests.first(where: { $0.value.request.requestID == requestID }) else {
            lock.unlock()
            return
        }
        let documentID = entry.key
        state.currentRequests[documentID] = nil
        state.pending[documentID] = nil
        state.pendingOrder.removeAll { $0 == documentID }
        state.currentResults[documentID] = nil
        lock.unlock()
    }

    /// Invalidate all current request and result state. In-flight inference is
    /// not interrupted; its generation can no longer deliver a completion.
    public func invalidate() {
        lock.lock()
        state.generation &+= 1
        state.pending.removeAll()
        state.pendingOrder.removeAll()
        state.currentRequests.removeAll()
        state.currentResults.removeAll()
        lock.unlock()
    }

    private func start(_ work: Work) {
        workerQueue.async { [self] in
            let language = detector(work.request.data)
            inferenceFinished(work, language: language)
        }
    }

    private func inferenceFinished(_ work: Work, language: String?) {
        var next: Work?
        var delivery: Delivery?

        lock.lock()
        if state.running?.generation == work.generation {
            while let documentID = state.pendingOrder.first {
                state.pendingOrder.removeFirst()
                if let pending = state.pending.removeValue(forKey: documentID) {
                    state.running = pending
                    next = pending
                    break
                }
            }
            if next == nil { state.running = nil }
        }
        if state.currentRequests[work.request.documentID]?.generation == work.generation {
            delivery = Delivery(
                context: work.request.context,
                generation: work.generation,
                validator: work.validator,
                completion: work.completion
            )
        }
        lock.unlock()

        if let delivery {
            let result = LanguageDetectionResult(
                context: delivery.context,
                language: language
            )
            completionQueue.async { [self] in
                deliver(delivery, result: result)
            }
        }

        if let next {
            start(next)
        }
    }

    private func deliver(_ delivery: Delivery, result: LanguageDetectionResult) {
        guard isCurrent(delivery) else { return }
        guard delivery.validator(result.context) else {
            discardIfCurrent(delivery)
            return
        }

        lock.lock()
        guard state.currentRequests[delivery.context.documentID]?.generation == delivery.generation else {
            lock.unlock()
            return
        }
        state.currentRequests[delivery.context.documentID] = nil
        state.currentResults[delivery.context.documentID] = (delivery.generation, result)
        lock.unlock()

        delivery.completion(result)
    }

    private func isCurrent(_ delivery: Delivery) -> Bool {
        locked {
            state.currentRequests[delivery.context.documentID]?.generation == delivery.generation
        }
    }

    private func discardIfCurrent(_ delivery: Delivery) {
        lock.lock()
        if state.currentRequests[delivery.context.documentID]?.generation == delivery.generation {
            state.currentRequests[delivery.context.documentID] = nil
            state.currentResults[delivery.context.documentID] = nil
        }
        lock.unlock()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
