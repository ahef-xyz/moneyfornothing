import Foundation

/// What a categorization run did.
public struct CategorizationReport: Hashable, Sendable {
    /// Transactions that got a (new or confirmed) machine category.
    public var categorized: Int
    /// Of those, below `Categorizer.reviewThreshold` ("Zu prüfen").
    public var needsReview: Int
    public var bySource: [CategorySource: Int]
    /// Transactions looked at again after a rule or a manual category changed.
    public var reevaluated: Int
    /// Rule categories removed because no rule (or learned rule) covers them any more and no
    /// other stage had a suggestion.
    public var cleared: Int
    public var duration: Duration

    public init(categorized: Int = 0, needsReview: Int = 0, bySource: [CategorySource: Int] = [:], reevaluated: Int = 0, cleared: Int = 0, duration: Duration = .zero) {
        self.categorized = categorized
        self.needsReview = needsReview
        self.bySource = bySource
        self.reevaluated = reevaluated
        self.cleared = cleared
        self.duration = duration
    }

    mutating func add(_ other: CategorizationReport) {
        categorized += other.categorized
        needsReview += other.needsReview
        bySource.merge(other.bySource, uniquingKeysWith: +)
        reevaluated += other.reevaluated
        cleared += other.cleared
        duration += other.duration
    }
}

/// Runs the `Categorizer` against the ledger and writes the results (the app calls it after
/// syncs and when rules change). Manual categories are never overwritten.
///
/// - Incremental: `categorizeUncategorized()` only looks at transactions without a category.
/// - Rule changes (`apply(rule:)`, `removeRule(_:)`) and corrections (`setManual`) re-evaluate
///   exactly the non-manual transactions they can affect.
/// - One operation at a time: operations queue behind each other, so a slow LLM batch never
///   races a rule change. Calls to `categorizeUncategorized()` while one is queued or running
///   share it; if they arrive mid-run, the run makes one more pass for what came in meanwhile.
public actor CategorizationService {
    private let store: any LedgerStore
    private let categorizer: Categorizer
    private let clock = ContinuousClock()

    /// End of the operation queue.
    private var tail: Task<Void, Never>?
    private var uncategorizedRun: Task<CategorizationReport, any Error>?
    private var uncategorizedStarted = false
    private var uncategorizedAgain = false

    public init(store: any LedgerStore, categorizer: Categorizer) {
        self.store = store
        self.categorizer = categorizer
    }

    /// The rule the rule sheet (⇧⌘K) starts with for this transaction.
    /// For `setupPlan` (other file): the current ledger.
    func storeSnapshot() async -> LedgerSnapshot {
        await store.snapshot()
    }

    /// For `setupPlan`: the cascade's guesses without writing anything.
    func suggest(_ transactions: [Transaction], snapshot: LedgerSnapshot) async -> [TransactionID: CategorySuggestion] {
        await categorizer.categorize(transactions, context: CategorizationContext(snapshot: snapshot))
    }

    public nonisolated func suggestedRule(for transaction: Transaction) -> CategoryRule.Match? {
        CategoryRule.Match.suggested(for: transaction)
    }

    /// Categorizes every transaction without a category (new ones after a sync).
    @discardableResult
    public func categorizeUncategorized() async throws -> CategorizationReport {
        if let run = uncategorizedRun {
            if uncategorizedStarted { uncategorizedAgain = true }
            return try await run.value
        }
        let run = enqueue { try await self.uncategorizedPasses() }
        uncategorizedRun = run
        return try await run.value
    }

    /// Stores the rule (new or edited) and re-evaluates every non-manual transaction it matches,
    /// or matched before an edit. Returns how many non-manual transactions the rule matches.
    @discardableResult
    public func apply(rule: CategoryRule) async throws -> Int {
        try await enqueue { try await self.performApply(rule) }.value
    }

    /// Removes the rule; transactions it categorized fall back to the rest of the cascade.
    @discardableResult
    public func removeRule(_ id: UUID) async throws -> CategorizationReport {
        try await enqueue { try await self.performRemoveRule(id) }.value
    }

    /// The user's choice (⌘K); `nil` clears the category. The correction becomes a label right
    /// away: non-manual transactions sharing an identifier with it (creditor ID, mandate,
    /// IBAN, fingerprint) are re-evaluated, so learned rules and kNN pick it up.
    @discardableResult
    public func setManual(_ category: CategoryID?, for transactions: [TransactionID]) async throws -> CategorizationReport {
        try await enqueue { try await self.performSetManual(category, for: transactions) }.value
    }

    // MARK: - Queue

    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Task<T, any Error> {
        let previous = tail
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return task
    }

    // MARK: - Operations

    private func uncategorizedPasses() async throws -> CategorizationReport {
        uncategorizedStarted = true
        defer {
            uncategorizedRun = nil
            uncategorizedStarted = false
            uncategorizedAgain = false
        }
        var total = CategorizationReport()
        repeat {
            uncategorizedAgain = false
            let snapshot = await store.snapshot()
            let open = snapshot.transactions.filter { $0.categoryID == nil && $0.status != .cancelled }
            total.add(try await categorize(open, snapshot: snapshot, reevaluating: false))
        } while uncategorizedAgain
        return total
    }

    private func performApply(_ rule: CategoryRule) async throws -> Int {
        let previous = await store.snapshot().categoryRules.first { $0.id == rule.id }
        try await store.upsertRule(rule)
        let snapshot = await store.snapshot()
        let affected = snapshot.transactions.filter {
            $0.categorySource != .manual && (rule.matches($0) || previous?.matches($0) == true)
        }
        try await reevaluate(Set(affected.map(\.id)), in: snapshot)
        return snapshot.transactions.count { $0.categorySource != .manual && rule.matches($0) }
    }

    private func performRemoveRule(_ id: UUID) async throws -> CategorizationReport {
        let removed = await store.snapshot().categoryRules.first { $0.id == id }
        try await store.removeRule(id)
        guard let removed else { return CategorizationReport() }
        let snapshot = await store.snapshot()
        let affected = snapshot.transactions.filter { $0.categorySource == .rule && removed.matches($0) }
        return try await reevaluate(Set(affected.map(\.id)), in: snapshot)
    }

    private func performSetManual(_ category: CategoryID?, for ids: [TransactionID]) async throws -> CategorizationReport {
        try await store.setCategory(category, source: .manual, confidence: category == nil ? nil : 1, for: Set(ids))
        let snapshot = await store.snapshot()
        let corrected = Set(ids)
        var identifiers: [LearnedRules.Key: Set<String>] = [:]
        for transaction in snapshot.transactions where corrected.contains(transaction.id) {
            for key in LearnedRules.Key.allCases {
                if let value = key.value(of: transaction) { identifiers[key, default: []].insert(value) }
            }
        }
        guard !identifiers.isEmpty else { return CategorizationReport() }
        let siblings = snapshot.transactions.filter { transaction in
            transaction.categorySource != .manual && LearnedRules.Key.allCases.contains { key in
                key.value(of: transaction).map { identifiers[key]?.contains($0) == true } ?? false
            }
        }
        return try await reevaluate(Set(siblings.map(\.id)), in: snapshot)
    }

    // MARK: - Running the cascade

    /// Runs the cascade again for these transactions (never manual ones). A transaction whose
    /// category came from a rule and gets no suggestion now loses it; other machine categories
    /// stay if the cascade has nothing new (e.g. LLM unavailable).
    @discardableResult
    private func reevaluate(_ ids: Set<TransactionID>, in snapshot: LedgerSnapshot) async throws -> CategorizationReport {
        let targets = snapshot.transactions.filter { ids.contains($0.id) && $0.categorySource != .manual && $0.status != .cancelled }
        return try await categorize(targets, snapshot: snapshot, reevaluating: true)
    }

    private func categorize(_ transactions: [Transaction], snapshot: LedgerSnapshot, reevaluating: Bool) async throws -> CategorizationReport {
        guard !transactions.isEmpty else { return CategorizationReport() }
        let start = clock.now
        var context = CategorizationContext(snapshot: snapshot)
        // A transaction must not be its own neighbour or few-shot with a stale label.
        let targetIDs = Set(transactions.map(\.id))
        context.labeled.removeAll { targetIDs.contains($0.id) }

        let suggestions = await categorizer.categorize(transactions, context: context)
        let byID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let changed = suggestions.filter { id, suggestion in
            guard let current = byID[id] else { return false }
            return current.categoryID != suggestion.categoryID || current.categorySource != suggestion.source || current.confidence != suggestion.confidence
        }
        let cleared = reevaluating
            ? Set(transactions.filter { $0.categorySource == .rule && suggestions[$0.id] == nil }.map(\.id))
            : []
        try await store.clearCategories(cleared)
        try await store.setCategories(changed)

        var report = CategorizationReport(reevaluated: reevaluating ? transactions.count : 0, cleared: cleared.count)
        for suggestion in suggestions.values {
            report.categorized += 1
            report.bySource[suggestion.source, default: 0] += 1
            if suggestion.source != .manual, suggestion.confidence < Categorizer.reviewThreshold { report.needsReview += 1 }
        }
        report.duration = clock.now - start
        return report
    }
}
