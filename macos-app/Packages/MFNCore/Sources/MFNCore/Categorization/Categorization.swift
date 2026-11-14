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
    func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion]
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
        var best: [TransactionID: CategorySuggestion] = [:]
        var open = transactions.filter { $0.status != .cancelled }
        for stage in stages where !open.isEmpty {
            let suggestions = await stage.suggest(open, context: context)
            for (id, suggestion) in suggestions where suggestion.confidence > (best[id]?.confidence ?? -1) {
                best[id] = suggestion
            }
            open.removeAll { (best[$0.id]?.confidence ?? 0) >= acceptThreshold }
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
