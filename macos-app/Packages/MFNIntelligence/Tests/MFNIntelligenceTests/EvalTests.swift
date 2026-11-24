import Foundation
import MFNCore
import Testing
@testable import MFNIntelligence

/// Eval against the synthetic set (CLAUDE.md §8): ≥ 85 % correct, ≤ 20 % to the LLM,
/// 100 bookings < 30 s. Results are printed for STATUS.md.
@Suite(.serialized) struct EvalTests {
    struct Score: CustomStringConvertible {
        var total = 0
        var correct = 0
        var confident = 0
        var confidentCorrect = 0
        var missing = 0
        var bySource: [CategorySource: (n: Int, ok: Int)] = [:]

        var accuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }
        var confidentShare: Double { total == 0 ? 0 : Double(confident) / Double(total) }
        var confidentPrecision: Double { confident == 0 ? 0 : Double(confidentCorrect) / Double(confident) }

        mutating func add(_ suggestion: CategorySuggestion?, expected: CategoryID, acceptThreshold: Double = 0.85) {
            total += 1
            guard let suggestion else { missing += 1; return }
            let ok = suggestion.categoryID == expected
            if ok { correct += 1 }
            if suggestion.confidence >= acceptThreshold {
                confident += 1
                if ok { confidentCorrect += 1 }
            }
            var entry = bySource[suggestion.source] ?? (0, 0)
            entry.n += 1
            if ok { entry.ok += 1 }
            bySource[suggestion.source] = entry
        }

        var description: String {
            let sources = CategorySource.allCases.compactMap { s in bySource[s].map { "\(s.rawValue) \($0.ok)/\($0.n)" } }.joined(separator: ", ")
            return String(format: "n=%d correct=%.1f%% confident=%.1f%% (precision %.1f%%) missing=%d [%@]",
                          total, accuracy * 100, confidentShare * 100, confidentPrecision * 100, missing, sources)
        }
    }

    @Test func evalSetIsBalancedOverTheCatalog() throws {
        let set = try EvalSet.load()
        #expect(set.items.count == 300)
        #expect(Set(set.items.map(\.id)).count == 300)
        let catalog = Set(CategoryCatalog.all.map(\.id.rawValue))
        let counts = Dictionary(grouping: set.items, by: \.category).mapValues(\.count)
        #expect(Set(counts.keys) == catalog)
        #expect((counts.values.min() ?? 0) >= 8)
        #expect((counts.values.max() ?? 0) <= 12)
    }

    /// kNN alone, leave-one-out over all 300 bookings.
    @Test func knnLeaveOneOut() async throws {
        let set = try EvalSet.load()
        let stage = KNNStage()
        let labeled = set.labeled
        let expected = set.expected
        var score = Score()
        let started = Date()
        for (index, query) in set.transactions.enumerated() {
            var history = labeled
            history.remove(at: index)
            let s = await stage.suggest([query], context: CategorizationContext(labeled: history, accountTypes: set.accountTypes))
            score.add(s[query.id], expected: expected[query.id] ?? "sonstiges")
        }
        print("EVAL kNN leave-one-out: \(score) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        #expect(score.confidentPrecision >= 0.95)
        #expect(score.confidentShare >= 0.8, "≤ 20 % may go on to the LLM")
    }

    /// Full cascade (rules → kNN → LLM), 10 folds of 30: each fold is categorized with the other
    /// 270 as labeled history. Then 100 bookings in one go against the other 200, timed.
    /// LLM parts only run when the on-device model is available. `withModel: false` is the
    /// cascade with the Settings switch "Apple Intelligence für Kategorien verwenden" off.
    @Test(arguments: [true, false]) func cascadeTenFolds(withModel: Bool) async throws {
        let set = try EvalSet.load()
        let embedding = HybridEmbedding()
        let llm = LLMStage(embedding: embedding, isEnabled: { withModel })
        let llmAvailable = withModel && llm.isAvailable
        if llmAvailable { llm.prewarm() }
        let early: [any CategorizationStage] = [RuleStage(), KNNStage(embedding: embedding)]
        let categorizer = Categorizer(stages: llmAvailable ? early + [llm] : early)
        let transactions = set.transactions
        let labeled = set.labeled
        let expected = set.expected

        func context(excluding range: Range<Int>) -> CategorizationContext {
            let history = labeled.enumerated().filter { !range.contains($0.offset) }.map(\.element)
            return CategorizationContext(labeled: history, accountTypes: set.accountTypes, rules: EvalSet.creditorRules(from: history))
        }

        var score = Score()
        var toLLM = 0
        for fold in 0 ..< 10 {
            let range = (fold * 30) ..< ((fold + 1) * 30)
            let queries = Array(transactions[range])
            let ctx = context(excluding: range)
            // What reaches stage 3: not settled (≥ acceptThreshold) by rules + kNN.
            let settled = await Categorizer(stages: early).categorize(queries, context: ctx)
            toLLM += queries.filter { (settled[$0.id]?.confidence ?? 0) < categorizer.acceptThreshold }.count
            let result = await categorizer.categorize(queries, context: ctx)
            for q in queries { score.add(result[q.id], expected: expected[q.id] ?? "sonstiges") }
        }
        let llmShare = Double(toLLM) / Double(transactions.count)

        let hundred = 0 ..< 100
        let started = Date()
        _ = await categorizer.categorize(Array(transactions[hundred]), context: context(excluding: hundred))
        let seconds = Date().timeIntervalSince(started)

        let mode = llmAvailable ? "rules+kNN+LLM" : withModel ? "rules+kNN, LLM unavailable" : "rules+kNN, LLM switched off"
        print("EVAL cascade (\(mode)): \(score); to LLM \(String(format: "%.1f", llmShare * 100)) %; 100 bookings in \(String(format: "%.1f", seconds)) s")

        #expect(llmShare <= 0.2)
        #expect(seconds < 30)
        if llmAvailable {
            #expect(score.accuracy >= 0.85)
        }
    }
}
