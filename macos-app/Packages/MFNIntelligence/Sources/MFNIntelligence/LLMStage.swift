import Foundation
import FoundationModels
import MFNCore
import os
import Synchronization

/// What `LLMStage` needs from a language model; the system model in the app, a fake in tests.
public protocol CategoryLanguageModel: Sendable {
    var isAvailable: Bool { get }
    func prewarm(instructions: String)
    /// Throws `LLMFailure` for the cases the stage handles, anything else for "batch failed".
    func answer(prompt: String, instructions: String) async throws -> LLMBatchAnswer
}

/// Failures the stage reacts to (CLAUDE.md §8).
public enum LLMFailure: Error, Equatable, Sendable {
    /// `exceededContextWindowSize`: halve the batch.
    case contextExceeded
    /// `guardrailViolation` / refusal: isolate and skip the booking.
    case guardrail
    /// Rate limited or concurrent requests: stop for this run.
    case busy
}

/// `SystemLanguageModel(useCase: .contentTagging)`, temperature 0, fresh session per call.
public struct SystemCategoryModel: CategoryLanguageModel {
    private let model: SystemLanguageModel

    public init() {
        model = SystemLanguageModel(useCase: .contentTagging)
    }

    public var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    public func prewarm(instructions: String) {
        guard isAvailable else { return }
        LanguageModelSession(model: model, instructions: instructions).prewarm()
    }

    public func answer(prompt: String, instructions: String) async throws -> LLMBatchAnswer {
        // A fresh session per batch: no transcript from earlier batches eats the 4k context.
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                generating: LLMBatchAnswer.self,
                includeSchemaInPrompt: true,
                options: GenerationOptions(temperature: 0)
            )
            return response.content
        } catch {
            if let failure = Self.classify(error) { throw failure }
            throw error
        }
    }

    static func classify(_ error: any Error) -> LLMFailure? {
        if #available(macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .contextExceeded
            case .guardrailViolation, .refusal: return .guardrail
            case .rateLimited, .timeout: return .busy
            default: return nil
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextExceeded
            case .guardrailViolation, .refusal: return .guardrail
            case .rateLimited, .concurrentRequests: return .busy
            default: return nil
            }
        }
        return nil
    }
}

/// Third stage (CLAUDE.md §8): Apple's on-device Foundation Model, `.contentTagging`, temperature 0.
/// Only sees what the earlier stages could not settle. Batches of `batchSize` (8–12), a fresh
/// session per batch, 3 similar labeled bookings per transaction as few-shots. Context overflow
/// halves the batch; a guardrail violation isolates and skips the offending booking. Without the
/// model (`availability` not `.available`) the stage returns nothing and rules + kNN stand alone.
public struct LLMStage: CategorizationStage {
    public struct Parameters: Sendable {
        public var batchSize: Int
        public var fewShotsPerTransaction: Int
        /// Upper bound for the model's self-reported certainty.
        public var maxConfidence: Double

        /// Longest wait for one model answer. A call that takes longer counts as `.busy`: the
        /// model stage stops for this run, rules and kNN results stay.
        public var timeout: Duration

        public init(batchSize: Int = 10, fewShotsPerTransaction: Int = 3, maxConfidence: Double = 0.9, timeout: Duration = .seconds(60)) {
            self.batchSize = min(max(batchSize, 1), 12)
            self.fewShotsPerTransaction = fewShotsPerTransaction
            self.maxConfidence = maxConfidence
            self.timeout = timeout
        }
    }

    public let source: CategorySource = .llm
    public var isSlow: Bool { true }
    public let embedding: any TextEmbedding
    public var parameters: Parameters
    public let model: any CategoryLanguageModel
    /// The user's switch (Settings, Kategorien). Asked before every batch, so turning it off
    /// takes effect for a running run at its next batch.
    public let isEnabled: @Sendable () -> Bool
    private let gate: ModelGate

    private static let logger = Logger(subsystem: "xyz.ahef.mfn", category: "categorizer.llm")
    /// One model call at a time in the whole app: a re-evaluation after a correction and the
    /// background run share the model instead of failing with `concurrentRequests`.
    static let sharedGate = ModelGate()

    public init(
        model: any CategoryLanguageModel = SystemCategoryModel(),
        embedding: any TextEmbedding = HybridEmbedding(),
        parameters: Parameters = Parameters(),
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.init(model: model, embedding: embedding, parameters: parameters, isEnabled: isEnabled, gate: Self.sharedGate)
    }

    init(model: any CategoryLanguageModel, embedding: any TextEmbedding, parameters: Parameters, isEnabled: @escaping @Sendable () -> Bool, gate: ModelGate) {
        self.model = model
        self.embedding = embedding
        self.parameters = parameters
        self.isEnabled = isEnabled
        self.gate = gate
    }

    /// Whether the on-device model can run now (Apple Intelligence on, assets downloaded).
    public var isAvailable: Bool { model.isAvailable }

    /// Loads the model ahead of the first batch (call at app start, CLAUDE.md §8). Does nothing
    /// while the user has switched the model off.
    public func prewarm() {
        guard isEnabled() else { return }
        model.prewarm(instructions: LLMPrompt.instructions)
    }

    public func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        await suggestOrStop(transactions, context: context).suggestions
    }

    /// `stopped`: the model is busy, rate limited or hung (`.busy`), so the stage gives up for
    /// the rest of the run. Switched off or unavailable is not a stop: the earlier stages'
    /// guesses are then final.
    public func suggestOrStop(_ transactions: [Transaction], context: CategorizationContext) async -> (suggestions: [TransactionID: CategorySuggestion], stopped: Bool) {
        guard !transactions.isEmpty, isEnabled() else { return ([:], false) }
        guard isAvailable else {
            Self.logger.info("Foundation model unavailable, skipping \(transactions.count, privacy: .public) bookings")
            return ([:], false)
        }
        let index = await NeighbourIndex.build(labeled: context.labeled, queries: transactions, embedding: embedding)
        var result: [TransactionID: CategorySuggestion] = [:]
        var start = 0
        while start < transactions.count {
            guard !Task.isCancelled, isEnabled() else { return (result, false) }
            let batch = Array(transactions[start ..< min(start + parameters.batchSize, transactions.count)])
            start += batch.count
            switch await run(batch, context: context, index: index) {
            case let .done(suggestions):
                result.merge(suggestions) { a, _ in a }
            case let .stop(suggestions):
                result.merge(suggestions) { a, _ in a }
                return (result, true)
            }
        }
        return (result, false)
    }

    // MARK: Batches

    enum BatchOutcome {
        case done([TransactionID: CategorySuggestion])
        /// The model refuses further work for now (rate limit, concurrent requests): keep what we have.
        case stop([TransactionID: CategorySuggestion])
    }

    private func run(_ batch: [Transaction], context: CategorizationContext, index: NeighbourIndex?) async -> BatchOutcome {
        do {
            return .done(try await ask(batch, context: context, index: index))
        } catch {
            switch error as? LLMFailure {
            case .contextExceeded, .guardrail:
                guard batch.count > 1 else {
                    Self.logger.info("Skipping one booking after \(String(describing: error), privacy: .public)")
                    return .done([:])
                }
                let half = batch.count / 2
                let first = await run(Array(batch[..<half]), context: context, index: index)
                guard case let .done(a) = first else { return first }
                let second = await run(Array(batch[half...]), context: context, index: index)
                switch second {
                case let .done(b): return .done(a.merging(b) { x, _ in x })
                case let .stop(b): return .stop(a.merging(b) { x, _ in x })
                }
            case .busy:
                Self.logger.notice("Foundation model busy or rate limited, stopping")
                return .stop([:])
            case nil:
                Self.logger.error("Foundation model batch failed: \(String(describing: type(of: error)), privacy: .public)")
                return .done([:])
            }
        }
    }

    private func ask(_ batch: [Transaction], context: CategorizationContext, index: NeighbourIndex?) async throws -> [TransactionID: CategorySuggestion] {
        let items = batch.enumerated().map { offset, transaction in
            LLMPrompt.Item(number: offset + 1, transaction: transaction, accountType: context.accountTypes[transaction.accountID])
        }
        let prompt = LLMPrompt.prompt(items: items, examples: examples(for: batch, index: index))
        let model = model
        let answer = try await gate.run(timeout: parameters.timeout) {
            try await model.answer(prompt: prompt, instructions: LLMPrompt.instructions)
        }
        return Self.suggestions(from: answer, items: items, maxConfidence: parameters.maxConfidence)
    }

    /// The 3 nearest labeled bookings per transaction, de-duplicated (by text and category).
    func examples(for batch: [Transaction], index: NeighbourIndex?) -> [LLMPrompt.Example] {
        guard let index, parameters.fewShotsPerTransaction > 0 else { return [] }
        var seen = Set<String>()
        var examples: [LLMPrompt.Example] = []
        for transaction in batch {
            for neighbour in index.neighbours(of: transaction, k: parameters.fewShotsPerTransaction) {
                let key = TransactionText(neighbour.entry.transaction).embeddingText + "→" + neighbour.entry.category.rawValue
                if seen.insert(key).inserted {
                    examples.append(LLMPrompt.Example(transaction: neighbour.entry.transaction, category: neighbour.entry.category))
                }
            }
        }
        return examples
    }

    static func suggestions(from answer: LLMBatchAnswer, items: [LLMPrompt.Item], maxConfidence: Double) -> [TransactionID: CategorySuggestion] {
        let byNumber = Dictionary(items.map { ($0.number, $0.transaction) }, uniquingKeysWith: { a, _ in a })
        var result: [TransactionID: CategorySuggestion] = [:]
        for assignment in answer.zuordnungen {
            guard let transaction = byNumber[assignment.nummer], result[transaction.id] == nil else { continue }
            var confidence = min(Double(assignment.sicherheit) / 100, maxConfidence)
            // Plausibility: an income category for an expense goes to review. (The reverse is
            // normal: Kindergeld → kinder, card settlement → kredit, cash deposit → bargeld.)
            if let info = CategoryCatalog.info(assignment.kategorie.categoryID), info.isIncome, transaction.amountCents < 0 {
                confidence = min(confidence, 0.5)
            }
            result[transaction.id] = CategorySuggestion(categoryID: assignment.kategorie.categoryID, source: .llm, confidence: confidence)
        }
        return result
    }
}

/// Runs model calls one after another, each with a time limit. A call past its limit is left
/// behind (the framework may not honour cancellation) and reported as `LLMFailure.busy`; while
/// such an abandoned call still holds the model, every further call fails at once with `.busy`
/// instead of waiting for it. Waiting for a busy model is bounded by the same limit and ends
/// when the caller is cancelled.
actor ModelGate {
    private var busy = false
    /// The call that holds the model now.
    private var holder: UUID?
    /// That call ran past its time limit and was left behind.
    private var abandoned = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>, timer: Task<Void, Never>)] = []

    /// The time limit fired (as opposed to `.busy` thrown by the model itself).
    private struct TimedOut: Error {}

    func run<T: Sendable>(timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if Task.isCancelled { throw CancellationError() }
        guard !(busy && abandoned) else { throw LLMFailure.busy }
        let token = UUID()
        guard await acquire(token, within: timeout) else {
            if Task.isCancelled { throw CancellationError() }
            throw LLMFailure.busy
        }
        let work = Task { try await operation() }
        // Released when the call really ends, also after a timeout.
        Task { _ = await work.result; self.release(token) }
        do {
            return try await Self.first(of: work, within: timeout)
        } catch is TimedOut {
            // Only if this call still holds the model: it may have ended right after the limit.
            if holder == token { abandoned = true }
            throw LLMFailure.busy
        }
    }

    /// `false` if the model stayed busy for `timeout`, or the caller was cancelled.
    private func acquire(_ token: UUID, within timeout: Duration) async -> Bool {
        guard busy else {
            busy = true
            holder = token
            return true
        }
        let gate = self
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await gate.giveUp(token)
                }
                waiters.append((token, continuation, timer))
            }
        } onCancel: {
            Task { await gate.giveUp(token) }
        }
    }

    private func giveUp(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timer.cancel()
        waiter.continuation.resume(returning: false)
    }

    private func release(_ token: UUID) {
        guard holder == token else { return }
        abandoned = false
        if waiters.isEmpty {
            busy = false
            holder = nil
        } else {
            // The model passes straight to the next caller: `busy` stays true.
            let next = waiters.removeFirst()
            next.timer.cancel()
            holder = next.id
            next.continuation.resume(returning: true)
        }
    }

    /// The task's result, or `TimedOut` once `timeout` has passed (or the caller is cancelled).
    private static func first<T: Sendable>(of work: Task<T, any Error>, within timeout: Duration) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation)
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    if race.finish(.failure(TimedOut())) { work.cancel() }
                }
                Task {
                    let result = await work.result
                    race.finish(result)
                    // Answered in time: the timer need not hold the answer for the rest of the minute.
                    timer.cancel()
                }
            }
        } onCancel: {
            if race.finish(.failure(CancellationError())) { work.cancel() }
        }
    }
}

/// The first `finish` resumes the continuation; later ones are ignored.
private final class Race<T: Sendable>: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<T, any Error>?, pending: Result<T, any Error>?, done: Bool)>((nil, nil, false))

    func start(_ continuation: CheckedContinuation<T, any Error>) {
        let pending: Result<T, any Error>? = state.withLock { state in
            if let pending = state.pending { return pending }
            state.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    /// Whether this call decided the race.
    @discardableResult
    func finish(_ result: Result<T, any Error>) -> Bool {
        let (continuation, won): (CheckedContinuation<T, any Error>?, Bool) = state.withLock { state in
            guard !state.done else { return (nil, false) }
            state.done = true
            if let continuation = state.continuation {
                state.continuation = nil
                return (continuation, true)
            }
            state.pending = result
            return (nil, true)
        }
        continuation?.resume(with: result)
        return won
    }
}
