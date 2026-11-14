import Foundation
import FoundationModels
import MFNCore
import os

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

        public init(batchSize: Int = 10, fewShotsPerTransaction: Int = 3, maxConfidence: Double = 0.9) {
            self.batchSize = min(max(batchSize, 1), 12)
            self.fewShotsPerTransaction = fewShotsPerTransaction
            self.maxConfidence = maxConfidence
        }
    }

    public let source: CategorySource = .llm
    public let embedding: any TextEmbedding
    public var parameters: Parameters
    public let model: any CategoryLanguageModel

    private static let logger = Logger(subsystem: "xyz.ahef.mfn", category: "categorizer.llm")

    public init(model: any CategoryLanguageModel = SystemCategoryModel(), embedding: any TextEmbedding = HybridEmbedding(), parameters: Parameters = Parameters()) {
        self.model = model
        self.embedding = embedding
        self.parameters = parameters
    }

    /// Whether the on-device model can run now (Apple Intelligence on, assets downloaded).
    public var isAvailable: Bool { model.isAvailable }

    /// Loads the model ahead of the first batch (call at app start, CLAUDE.md §8).
    public func prewarm() {
        model.prewarm(instructions: LLMPrompt.instructions)
    }

    public func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        guard !transactions.isEmpty else { return [:] }
        guard isAvailable else {
            Self.logger.info("Foundation model unavailable, skipping \(transactions.count, privacy: .public) bookings")
            return [:]
        }
        let index = await NeighbourIndex.build(labeled: context.labeled, queries: transactions, embedding: embedding)
        var result: [TransactionID: CategorySuggestion] = [:]
        var start = 0
        while start < transactions.count {
            let batch = Array(transactions[start ..< min(start + parameters.batchSize, transactions.count)])
            start += batch.count
            switch await run(batch, context: context, index: index) {
            case let .done(suggestions):
                result.merge(suggestions) { a, _ in a }
            case let .stop(suggestions):
                result.merge(suggestions) { a, _ in a }
                return result
            }
        }
        return result
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
        let answer = try await model.answer(prompt: prompt, instructions: LLMPrompt.instructions)
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
