import Foundation

/// First stage (CLAUDE.md §8 "Regel (Gläubiger-ID, Mandatsreferenz, Fingerprint)").
///
/// 1. **Explicit rules** (`CategoryRule`, ⇧⌘K), confidence 1. The most specific rule wins, on a tie the newest.
/// 2. **Learned rules** from the user's own corrections: a transaction that shares an exact
///    identifier with manually categorized history gets that category, confidence
///    `learnedConfidence`. Identifiers are checked from most to least specific (fingerprint,
///    mandate reference, creditor ID, counterpart IBAN); the first one that occurs in the history
///    decides. If the history disagrees for it (PayPal: one creditor ID, many categories) the
///    stage says nothing and leaves the transaction to kNN/LLM.
///
/// Only `.manual` labels are learned from: `.rule` labels either repeat an explicit rule (which
/// applies anyway) or came from learning, and learning from those would keep a removed rule alive.
public struct RuleStage: CategorizationStage {
    public let source: CategorySource = .rule
    public static let learnedConfidence = 0.95

    public init() {}

    public func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        let rules = context.rules.sorted {
            $0.specificity != $1.specificity ? $0.specificity > $1.specificity : $0.createdAt > $1.createdAt
        }
        let learned = LearnedRules(labeled: context.labeled)
        var result: [TransactionID: CategorySuggestion] = [:]
        for transaction in transactions {
            if let rule = rules.first(where: { $0.matches(transaction) }) {
                result[transaction.id] = CategorySuggestion(categoryID: rule.categoryID, source: .rule, confidence: 1)
            } else if let category = learned.category(for: transaction) {
                result[transaction.id] = CategorySuggestion(categoryID: category, source: .rule, confidence: Self.learnedConfidence)
            }
        }
        return result
    }
}

/// Index of exact identifiers in manually categorized history.
struct LearnedRules: Sendable {
    /// Most specific first.
    enum Key: CaseIterable, Sendable {
        case fingerprint, mandateReference, creditorID, counterpartIBAN

        /// Normalized value, `nil` if the transaction has none.
        func value(of transaction: Transaction) -> String? {
            let raw: String? = switch self {
            case .fingerprint: transaction.fingerprint
            case .mandateReference: transaction.mref.map { $0.trimmingCharacters(in: .whitespaces) }
            case .creditorID: transaction.creditorID.map(LearnedRules.compact)
            case .counterpartIBAN: transaction.counterpartIBAN.map(LearnedRules.compact)
            }
            guard let raw, !raw.isEmpty else { return nil }
            return raw
        }
    }

    /// Per key: value → categories seen, and which transaction carried each label (so a
    /// transaction never learns from itself).
    private var index: [Key: [String: [CategoryID: Set<TransactionID>]]] = [:]

    init(labeled: [Transaction]) {
        for transaction in labeled where transaction.categorySource == .manual {
            guard let category = transaction.categoryID else { continue }
            for key in Key.allCases {
                if let value = key.value(of: transaction) {
                    index[key, default: [:]][value, default: [:]][category, default: []].insert(transaction.id)
                }
            }
        }
    }

    var isEmpty: Bool { index.isEmpty }

    /// The unambiguous category of the most specific identifier known from history.
    func category(for transaction: Transaction) -> CategoryID? {
        for key in Key.allCases {
            guard let value = key.value(of: transaction), var seen = index[key]?[value] else { continue }
            for (category, ids) in seen {
                let others = ids.subtracting([transaction.id])
                if others.isEmpty { seen[category] = nil }
            }
            if seen.isEmpty { continue }
            return seen.count == 1 ? seen.keys.first : nil
        }
        return nil
    }

    static func compact(_ s: String) -> String { s.uppercased().filter { !$0.isWhitespace } }
}
