import Foundation

// Cascade order (see `CategorizationStage`):
// RuleStage → TransferStage → KnownMerchantStage → kNN → LLM.

/// Transfers between the user's own accounts → `umbuchung` (`.rule`, 0,95). Deterministic, no
/// learning needed. A transaction is a transfer if
///
/// 1. its counterpart IBAN is the IBAN of another own account, or
/// 2. exactly one other own account has the exact counter-booking (same amount, opposite sign)
///    within ±2 days, and that booking has exactly this one partner, too. Bookings whose
///    counterpart IBAN belongs to someone else never pair up. Two candidates (or a partner with
///    two candidates) are ambiguous: no suggestion.
///
/// Paying off an own credit card (either side is a `.card` account) is `umbuchung` too (decided
/// by the human, 2026-11-10): money moves between two own accounts, the card's own transactions
/// carry the real categories. Under `kredit` it would mix with real loan repayments and inflate
/// them by what was already spent on the card. (A card *not* connected to MFN is caught by the
/// merchant list as `kredit`, since its purchases are missing.)
public struct TransferStage: CategorizationStage {
    public let source: CategorySource = .rule
    public static let confidence = 0.95
    public static let category: CategoryID = "umbuchung"
    /// Giro (or any own account) ↔ own credit card: a transfer like any other.
    public static let cardSettlementCategory: CategoryID = "umbuchung"
    /// Maximum distance between a booking and its counter-booking, in days.
    public static let maxDayDistance = 2

    public init() {}

    public func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        let matcher = TransferMatcher(context: context, extra: transactions)
        var result: [TransactionID: CategorySuggestion] = [:]
        for transaction in transactions {
            if let category = matcher.category(for: transaction) {
                result[transaction.id] = CategorySuggestion(categoryID: category, source: .rule, confidence: Self.confidence)
            }
        }
        return result
    }
}

/// The pairing logic of `TransferStage`, built once per run.
struct TransferMatcher: Sendable {
    private let ownIBANs: Set<String>
    private let accountsByIBAN: [String: AccountID]
    private let accountTypes: [AccountID: AccountType]
    /// Candidate counter-bookings by amount.
    private let byAmount: [Int: [Transaction]]

    init(context: CategorizationContext, extra: [Transaction] = []) {
        ownIBANs = context.ownIBANs
        accountsByIBAN = context.ownAccountsByIBAN
        accountTypes = context.accountTypes
        var seen = Set<TransactionID>()
        var byAmount: [Int: [Transaction]] = [:]
        for transaction in context.recent + extra where transaction.status != .cancelled && transaction.amountCents != 0 {
            guard seen.insert(transaction.id).inserted else { continue }
            byAmount[transaction.amountCents, default: []].append(transaction)
        }
        self.byAmount = byAmount
    }

    func category(for transaction: Transaction) -> CategoryID? {
        guard transaction.status != .cancelled, transaction.amountCents != 0 else { return nil }
        if let iban = Self.iban(of: transaction) {
            guard ownIBANs.contains(iban) else { return nil }
            let target = accountsByIBAN[iban]
            if target == transaction.accountID { return nil }
            return category(transaction.accountID, target)
        }
        let partners = partners(of: transaction)
        guard partners.count == 1, let partner = partners.first, self.partners(of: partner).count == 1 else { return nil }
        return category(transaction.accountID, partner.accountID)
    }

    private func category(_ a: AccountID, _ b: AccountID?) -> CategoryID {
        let isCard = accountTypes[a] == .card || b.map { accountTypes[$0] == .card } == true
        return isCard ? TransferStage.cardSettlementCategory : TransferStage.category
    }

    /// Counter-bookings on other accounts within ±2 days that do not name a foreign counterpart.
    private func partners(of transaction: Transaction) -> [Transaction] {
        guard let candidates = byAmount[-transaction.amountCents] else { return [] }
        let day = transaction.effectiveDate
        return candidates.filter { other in
            guard other.id != transaction.id, other.accountID != transaction.accountID else { return false }
            if let iban = Self.iban(of: other), !ownIBANs.contains(iban) { return false }
            return abs(day.days(to: other.effectiveDate)) <= TransferStage.maxDayDistance
        }
    }

    private static func iban(of transaction: Transaction) -> String? {
        guard let iban = transaction.counterpartIBAN.map(LearnedRules.compact), !iban.isEmpty else { return nil }
        return iban
    }
}

/// Built-in list of well-known German merchants and patterns (REWE → lebensmittel, …),
/// `.rule` at 0,8: below the user's rules and the accept threshold, so kNN/LLM may still
/// overrule with more confidence. Works from the first sync. List and matching: `KnownMerchants`.
public struct KnownMerchantStage: CategorizationStage {
    public let source: CategorySource = .rule
    public static let confidence = 0.8

    public init() {}

    public func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        var result: [TransactionID: CategorySuggestion] = [:]
        for transaction in transactions where transaction.status != .cancelled {
            if let category = KnownMerchants.category(for: transaction) {
                result[transaction.id] = CategorySuggestion(categoryID: category, source: .rule, confidence: Self.confidence)
            }
        }
        return result
    }
}
