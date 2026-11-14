import Foundation

/// A transaction with the category it should get (eval set, CLAUDE.md §8).
public struct LabeledExample: Hashable, Sendable {
    public var transaction: Transaction
    public var expected: CategoryID

    public init(transaction: Transaction, expected: CategoryID) {
        self.transaction = transaction
        self.expected = expected
    }
}

/// Measures a `Categorizer` against labeled examples: accuracy overall and per category, what
/// each stage covered, the share that reached the LLM (target ≤ 20 %), confusions and runtime.
///
/// Without ML: the stages are whatever the caller passes. `run` uses the context as given
/// (history = `context.labeled`); `crossValidate` uses the examples themselves as manual
/// history, fold by fold, which is what kNN and learned rules need.
public enum CategorizationEvaluation {
    public struct CategoryScore: Hashable, Sendable {
        /// Examples with this expected category.
        public var total: Int
        public var correct: Int
        /// Predictions of this category (right or wrong).
        public var predicted: Int

        public var recall: Double { total == 0 ? 0 : Double(correct) / Double(total) }
        public var precision: Double { predicted == 0 ? 0 : Double(correct) / Double(predicted) }
    }

    public struct StageScore: Hashable, Sendable {
        public var source: CategorySource
        /// Examples the stage was asked about (still open when it ran).
        public var seen: Int
        /// Examples whose final category came from this stage.
        public var decided: Int
        /// Of those, correct.
        public var correct: Int

        public var accuracy: Double { decided == 0 ? 0 : Double(correct) / Double(decided) }
    }

    public struct Confusion: Hashable, Sendable {
        public var expected: CategoryID
        /// `nil`: no stage had a suggestion.
        public var predicted: CategoryID?
        public var count: Int
    }

    public struct Result: Hashable, Sendable {
        public var total: Int
        public var correct: Int
        /// No suggestion at all (counts as wrong).
        public var uncovered: Int
        /// Machine suggestions below `Categorizer.reviewThreshold` ("Zu prüfen").
        public var needsReview: Int
        /// Correct among those at or above the review threshold.
        public var confidentCorrect: Int
        public var perCategory: [CategoryID: CategoryScore]
        /// In cascade order.
        public var stages: [StageScore]
        /// Examples the LLM stage was asked about (or, without one, those no stage settled).
        public var reachedLLM: Int
        /// Most frequent first.
        public var confusions: [Confusion]
        public var duration: Duration

        public var accuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }
        public var llmShare: Double { total == 0 ? 0 : Double(reachedLLM) / Double(total) }
        public var confident: Int { total - uncovered - needsReview }
        public var confidentAccuracy: Double { confident == 0 ? 0 : Double(confidentCorrect) / Double(confident) }

        public init() {
            total = 0; correct = 0; uncovered = 0; needsReview = 0; confidentCorrect = 0
            perCategory = [:]; stages = []; reachedLLM = 0; confusions = []; duration = .zero
        }

        /// Plain-text summary for test logs and the console.
        public var summary: String {
            func pct(_ x: Double) -> String { String(format: "%.1f %%", x * 100) }
            var lines = [
                "Genauigkeit: \(pct(accuracy)) (\(correct)/\(total)), ohne Vorschlag: \(uncovered), zu prüfen: \(needsReview)",
                "Sicher (≥ \(Categorizer.reviewThreshold)): \(pct(confidentAccuracy)) von \(confident)",
                "Ans LLM: \(pct(llmShare)) (\(reachedLLM)), Laufzeit: \(duration)",
            ]
            for stage in stages {
                lines.append("  \(stage.source.rawValue): gesehen \(stage.seen), entschieden \(stage.decided), richtig \(pct(stage.accuracy))")
            }
            for (id, score) in perCategory.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                lines.append("  \(id.rawValue): \(score.correct)/\(score.total), Präzision \(pct(score.precision))")
            }
            for confusion in confusions.prefix(10) {
                lines.append("  \(confusion.expected.rawValue) → \(confusion.predicted?.rawValue ?? "–"): \(confusion.count)")
            }
            return lines.joined(separator: "\n")
        }

        mutating func add(_ other: Result) {
            total += other.total; correct += other.correct; uncovered += other.uncovered
            needsReview += other.needsReview; confidentCorrect += other.confidentCorrect
            reachedLLM += other.reachedLLM; duration += other.duration
            perCategory.merge(other.perCategory) { a, b in
                CategoryScore(total: a.total + b.total, correct: a.correct + b.correct, predicted: a.predicted + b.predicted)
            }
            if stages.isEmpty {
                stages = other.stages
            } else {
                for index in stages.indices where index < other.stages.count {
                    stages[index].seen += other.stages[index].seen
                    stages[index].decided += other.stages[index].decided
                    stages[index].correct += other.stages[index].correct
                }
            }
            var counts: [Pair: Int] = [:]
            for c in confusions + other.confusions { counts[Pair(expected: c.expected, predicted: c.predicted), default: 0] += c.count }
            confusions = Self.sorted(counts)
        }

        static func sorted(_ counts: [Pair: Int]) -> [Confusion] {
            counts.map { Confusion(expected: $0.key.expected, predicted: $0.key.predicted, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : ($0.expected.rawValue, $0.predicted?.rawValue ?? "") < ($1.expected.rawValue, $1.predicted?.rawValue ?? "") }
        }
    }

    struct Pair: Hashable { var expected: CategoryID; var predicted: CategoryID? }

    /// Categorizes the examples once with the given context (their own categories are ignored).
    public static func run(_ examples: [LabeledExample], categorizer: Categorizer, context: CategorizationContext = CategorizationContext()) async -> Result {
        let transactions = examples.map { uncategorized($0.transaction) }
        let recorder = SeenRecorder()
        var instrumented = categorizer
        instrumented.stages = categorizer.stages.enumerated().map { RecordingStage(index: $0.offset, base: $0.element, recorder: recorder) }

        let clock = ContinuousClock()
        let start = clock.now
        let suggestions = await instrumented.categorize(transactions, context: context)
        var result = Result()
        result.duration = clock.now - start

        let seen = await recorder.seen
        result.stages = categorizer.stages.enumerated().map { StageScore(source: $0.element.source, seen: seen[$0.offset]?.count ?? 0, decided: 0, correct: 0) }
        if let llm = categorizer.stages.firstIndex(where: { $0.source == .llm }) {
            result.reachedLLM = seen[llm]?.count ?? 0
        } else {
            result.reachedLLM = transactions.count { (suggestions[$0.id]?.confidence ?? 0) < categorizer.acceptThreshold }
        }

        var confusions: [Pair: Int] = [:]
        for (example, transaction) in zip(examples, transactions) {
            result.total += 1
            result.perCategory[example.expected, default: CategoryScore(total: 0, correct: 0, predicted: 0)].total += 1
            guard let suggestion = suggestions[transaction.id] else {
                result.uncovered += 1
                confusions[Pair(expected: example.expected, predicted: nil), default: 0] += 1
                continue
            }
            let right = suggestion.categoryID == example.expected
            result.perCategory[suggestion.categoryID, default: CategoryScore(total: 0, correct: 0, predicted: 0)].predicted += 1
            let review = suggestion.confidence < Categorizer.reviewThreshold
            if review { result.needsReview += 1 }
            // The deciding stage: the first of its source that saw it (sources are unique in practice).
            if let stage = result.stages.indices.first(where: { result.stages[$0].source == suggestion.source && seen[$0]?.contains(transaction.id) == true }) {
                result.stages[stage].decided += 1
                if right { result.stages[stage].correct += 1 }
            }
            if right {
                result.correct += 1
                result.perCategory[example.expected]?.correct += 1
                if !review { result.confidentCorrect += 1 }
            } else {
                confusions[Pair(expected: example.expected, predicted: suggestion.categoryID), default: 0] += 1
            }
        }
        result.confusions = Result.sorted(confusions)
        return result
    }

    /// k-fold cross-validation: each fold is categorized with the other folds as manual history.
    /// Folds are assigned round-robin by position, so the result is deterministic.
    public static func crossValidate(_ examples: [LabeledExample], categorizer: Categorizer, folds: Int = 5, accountTypes: [AccountID: AccountType] = [:], rules: [CategoryRule] = []) async -> Result {
        let k = max(2, min(folds, examples.count))
        guard examples.count >= 2 else {
            return await run(examples, categorizer: categorizer, context: CategorizationContext(accountTypes: accountTypes, rules: rules))
        }
        var total = Result()
        for fold in 0..<k {
            let test = examples.indices.filter { $0 % k == fold }.map { examples[$0] }
            let history = examples.indices.filter { $0 % k != fold }.map { index -> Transaction in
                var t = examples[index].transaction
                t.categoryID = examples[index].expected
                t.categorySource = .manual
                t.confidence = 1
                return t
            }
            let context = CategorizationContext(labeled: history, accountTypes: accountTypes, rules: rules)
            total.add(await run(test, categorizer: categorizer, context: context))
        }
        return total
    }

    private static func uncategorized(_ transaction: Transaction) -> Transaction {
        var t = transaction
        t.categoryID = nil
        t.categorySource = nil
        t.confidence = nil
        return t
    }
}

private actor SeenRecorder {
    var seen: [Int: Set<TransactionID>] = [:]
    func record(_ index: Int, _ ids: [TransactionID]) { seen[index, default: []].formUnion(ids) }
}

private struct RecordingStage: CategorizationStage {
    let index: Int
    let base: any CategorizationStage
    let recorder: SeenRecorder
    var source: CategorySource { base.source }

    func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        await recorder.record(index, transactions.map(\.id))
        return await base.suggest(transactions, context: context)
    }
}
