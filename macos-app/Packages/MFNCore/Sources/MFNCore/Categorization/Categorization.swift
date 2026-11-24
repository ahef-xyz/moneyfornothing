import Foundation

/// A proposed category for one transaction.
public struct CategorySuggestion: Hashable, Sendable {
    public var categoryID: CategoryID
    public var source: CategorySource
    /// 0…1. Below `Categorizer.reviewThreshold` the transaction lands in "Zu prüfen".
    public var confidence: Double

    public init(categoryID: CategoryID, source: CategorySource, confidence: Double) {
        self.categoryID = categoryID
        self.source = source
        self.confidence = min(max(confidence, 0), 1)
    }
}

/// What every stage may look at besides the transactions to categorize.
public struct CategorizationContext: Sendable {
    /// Transactions with a trusted category (manual, or rule): kNN neighbours, LLM few-shots.
    public var labeled: [Transaction]
    public var accountTypes: [AccountID: AccountType]
    public var rules: [CategoryRule]
    /// IBANs of the user's own accounts, compact (upper case, no spaces). `TransferStage`.
    public var ownIBANs: Set<String>
    /// Own account behind each IBAN in `ownIBANs` (compact), where known. `TransferStage` uses it
    /// to tell a card settlement from a transfer.
    public var ownAccountsByIBAN: [String: AccountID]
    /// Every non-cancelled transaction of the ledger, categorized or not: `TransferStage` looks
    /// for the counter-booking on another own account here.
    public var recent: [Transaction]

    public init(
        labeled: [Transaction] = [],
        accountTypes: [AccountID: AccountType] = [:],
        rules: [CategoryRule] = [],
        ownIBANs: Set<String> = [],
        ownAccountsByIBAN: [String: AccountID] = [:],
        recent: [Transaction] = []
    ) {
        self.labeled = labeled
        self.accountTypes = accountTypes
        self.rules = rules
        self.ownIBANs = Set(ownIBANs.map(LearnedRules.compact)).union(ownAccountsByIBAN.keys.map(LearnedRules.compact))
        self.ownAccountsByIBAN = Dictionary(ownAccountsByIBAN.map { (LearnedRules.compact($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.recent = recent
    }

    /// From the ledger: manual and rule categories count as labels.
    public init(snapshot: LedgerSnapshot) {
        labeled = snapshot.transactions.filter {
            $0.categoryID != nil && ($0.categorySource == .manual || $0.categorySource == .rule)
        }
        accountTypes = Dictionary(snapshot.accounts.map { ($0.id, $0.type) }, uniquingKeysWith: { a, _ in a })
        rules = snapshot.categoryRules
        var byIBAN: [String: AccountID] = [:]
        for account in snapshot.accounts {
            guard let iban = account.iban.map(LearnedRules.compact), !iban.isEmpty else { continue }
            byIBAN[iban] = byIBAN[iban] ?? account.id
        }
        ownAccountsByIBAN = byIBAN
        ownIBANs = Set(byIBAN.keys)
        recent = snapshot.transactions.filter { $0.status != .cancelled }
    }
}

/// One step of the cascade (CLAUDE.md §8). Returns suggestions for those transactions it can say
/// something about; it may skip any.
///
/// Order of the full cascade (the app builds it):
/// `RuleStage → TransferStage → KnownMerchantStage → kNN → LLM`.
/// - `RuleStage` (1,0 explicit, 0,95 learned) and `TransferStage` (0,95) are exact and settle a
///   transaction (≥ `Categorizer.acceptThreshold`).
/// - `KnownMerchantStage` (0,8) is a guess from a built-in list: it counts as categorized
///   (≥ review threshold) but stays open, so kNN/LLM may overrule it with more confidence.
/// - kNN learns from the user's labels, the LLM handles the rest.
public protocol CategorizationStage: Sendable {
    var source: CategorySource { get }
    /// A stage that takes seconds per handful of bookings (the language model). The categorizer
    /// gives it the open bookings in chunks and reports after each one, so results land as they
    /// come and a stop (lock, quit) keeps what is done.
    var isSlow: Bool { get }
    func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion]
    /// Like `suggest`, plus whether the stage gave up for the rest of the run (the model is busy
    /// or hung): bookings it did not answer are then not final. Default: never gives up.
    func suggestOrStop(_ transactions: [Transaction], context: CategorizationContext) async -> (suggestions: [TransactionID: CategorySuggestion], stopped: Bool)
}

extension CategorizationStage {
    public var isSlow: Bool { false }

    public func suggestOrStop(_ transactions: [Transaction], context: CategorizationContext) async -> (suggestions: [TransactionID: CategorySuggestion], stopped: Bool) {
        (await suggest(transactions, context: context), false)
    }
}

/// How far a categorization run is: `done` of `total` bookings went through the cascade.
public struct CategorizationProgress: Hashable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// Runs the stages in order. A transaction leaves the cascade once a stage is at least
/// `acceptThreshold` sure; otherwise the next stage tries and the most confident suggestion wins.
public struct Categorizer: Sendable {
    /// Below this a machine category goes to "Zu prüfen" (CLAUDE.md §8).
    public static let reviewThreshold = 0.7

    public var stages: [any CategorizationStage]
    public var acceptThreshold: Double

    public init(stages: [any CategorizationStage], acceptThreshold: Double = 0.85) {
        self.stages = stages
        self.acceptThreshold = acceptThreshold
    }

    public func categorize(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        await categorize(transactions, context: context, slowChunkSize: .max, onStep: nil)
    }

    /// Bookings per chunk for slow stages (three to four model batches).
    public static let defaultSlowChunkSize = 40

    /// Like `categorize(_:context:)`, but reports as it goes: once after the fast stages (with
    /// what they settled, at least `acceptThreshold`), then after every chunk of a slow stage
    /// (with the best suggestion for each booking of that chunk). A booking is reported only
    /// once the cascade is through with it, so a run stopped midway (cancelled task) leaves the
    /// rest without a category, and the next run gives them the full cascade.
    /// `skipsSlowStages`: only the fast stages (user actions must not wait for the model).
    public func categorize(
        _ transactions: [Transaction],
        context: CategorizationContext,
        slowChunkSize: Int,
        skipsSlowStages: Bool = false,
        onStep: (@Sendable (_ improved: [TransactionID: CategorySuggestion], _ progress: CategorizationProgress) async -> Void)?
    ) async -> [TransactionID: CategorySuggestion] {
        var best: [TransactionID: CategorySuggestion] = [:]
        let all = transactions.filter { $0.status != .cancelled }
        var open = all
        var reportedFast = false
        let chunkSize = max(slowChunkSize, 1)

        func improve(with suggestions: [TransactionID: CategorySuggestion]) -> [TransactionID: CategorySuggestion] {
            var improved: [TransactionID: CategorySuggestion] = [:]
            for (id, suggestion) in suggestions where suggestion.confidence > (best[id]?.confidence ?? -1) {
                best[id] = suggestion
                improved[id] = suggestion
            }
            return improved
        }

        var gaveUp = false
        for stage in stages where !open.isEmpty && !(skipsSlowStages && stage.isSlow) && !gaveUp {
            if Task.isCancelled { break }
            guard stage.isSlow, let onStep else {
                _ = improve(with: await stage.suggest(open, context: context))
                open.removeAll { (best[$0.id]?.confidence ?? 0) >= acceptThreshold }
                continue
            }
            if !reportedFast {
                reportedFast = true
                await onStep(best.filter { $0.value.confidence >= acceptThreshold },
                             CategorizationProgress(done: all.count - open.count, total: all.count))
            }
            var done = all.count - open.count
            var start = 0
            let queue = open
            while start < queue.count, !Task.isCancelled {
                let chunk = Array(queue[start ..< min(start + chunkSize, queue.count)])
                start += chunk.count
                let (suggestions, stopped) = await stage.suggestOrStop(chunk, context: context)
                // A chunk the stage could not finish (cancelled) is not reported: its bookings
                // stay open for the next run instead of keeping a weak fast guess for good.
                guard !Task.isCancelled else { break }
                _ = improve(with: suggestions)
                if stopped {
                    // The model gave up: only what it answered is final. The rest of this
                    // chunk and of the run stays open for the next run.
                    let answered = Dictionary(uniqueKeysWithValues: chunk.compactMap { t in
                        suggestions[t.id] == nil ? nil : best[t.id].map { (t.id, $0) }
                    })
                    await onStep(answered, CategorizationProgress(done: min(done + answered.count, all.count), total: all.count))
                    gaveUp = true
                    break
                }
                done += chunk.count
                let finished = Dictionary(uniqueKeysWithValues: chunk.compactMap { t in best[t.id].map { (t.id, $0) } })
                await onStep(finished, CategorizationProgress(done: min(done, all.count), total: all.count))
            }
            open.removeAll { (best[$0.id]?.confidence ?? 0) >= acceptThreshold }
        }
        if !reportedFast, let onStep {
            // Stopped before a slow stage ran: only what is settled counts, weak guesses wait
            // for the next run's full cascade.
            let settled = Task.isCancelled ? best.filter { $0.value.confidence >= acceptThreshold } : best
            await onStep(settled, CategorizationProgress(done: all.count, total: all.count))
        }
        return best
    }
}

/// A user rule ("immer diese Kategorie für …", ⇧⌘K). Rule matches have confidence 1.
public struct CategoryRule: Codable, Hashable, Sendable, Identifiable {
    public enum Match: Codable, Hashable, Sendable {
        /// SEPA creditor ID (Gläubiger-ID), exact.
        case creditorID(String)
        /// Mandate reference, exact.
        case mandateReference(String)
        /// Counterpart IBAN, exact (spaces and case ignored).
        case counterpartIBAN(String)
        /// Counterpart name contains the text (case/diacritics ignored).
        case counterpart(String)
        /// Purpose contains the text (case/diacritics ignored).
        case purpose(String)
    }

    public let id: UUID
    public var match: Match
    public var categoryID: CategoryID
    public var createdAt: Date

    public init(id: UUID = UUID(), match: Match, categoryID: CategoryID, createdAt: Date = Date()) {
        self.id = id
        self.match = match
        self.categoryID = categoryID
        self.createdAt = createdAt
    }

    public func matches(_ transaction: Transaction) -> Bool {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE")) }
        func iban(_ s: String) -> String { s.uppercased().filter { !$0.isWhitespace } }
        switch match {
        case let .creditorID(value): return transaction.creditorID.map { iban($0) == iban(value) } ?? false
        case let .mandateReference(value): return transaction.mref == value
        case let .counterpartIBAN(value): return transaction.counterpartIBAN.map { iban($0) == iban(value) } ?? false
        case let .counterpart(value): return !value.isEmpty && fold(transaction.counterpartName).contains(fold(value))
        case let .purpose(value): return !value.isEmpty && fold(transaction.purpose).contains(fold(value))
        }
    }

    /// Exact identifiers first (creditor, mandate, IBAN), then text matches; newest rule wins a tie.
    public var specificity: Int {
        switch match {
        case .creditorID, .mandateReference: 3
        case .counterpartIBAN: 2
        case .counterpart, .purpose: 1
        }
    }
}
