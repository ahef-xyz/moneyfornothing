import Foundation

/// Data of the "Kategorien einrichten" assistant: how much is categorized and what to decide,
/// in order of impact. Every accepted candidate becomes a `CategoryRule` (`match`) and applies
/// to all its transactions.
public struct SetupPlan: Hashable, Sendable {
    public struct Candidate: Hashable, Sendable, Identifiable {
        public enum Kind: String, Hashable, Sendable, CaseIterable {
            /// Recurring incoming payments (salary, child benefit, rent income).
            case income
            /// Direct debits / recurring monthly payments (rent, energy, insurance, subscriptions).
            case fixedCost
            /// Frequent or expensive counterparts.
            case counterparty
            /// Transfers between the user's own accounts.
            case transfer
        }

        /// Stable within one plan (derived from `match`).
        public let id: String
        public var kind: Kind
        /// What the user sees, e.g. "REWE Markt" or "Stadtwerke Köln (Gläubiger-ID …)".
        public var title: String
        public var match: CategoryRule.Match
        /// Not-yet-categorized (or machine-categorized) transactions the rule would cover.
        public var transactionIDs: [TransactionID]
        /// Sum of `transactionIDs` (signed, cents, EUR).
        public var totalCents: Int
        /// Typical monthly amount for recurring payments, `nil` otherwise.
        public var monthlyCents: Int?
        /// MFN's best guess (cascade), `nil` if none.
        public var suggestion: CategorySuggestion?
        /// Most likely categories for the number keys 1–9 (suggestion first), at most 9.
        public var alternatives: [CategoryID]

        public init(id: String, kind: Kind, title: String, match: CategoryRule.Match, transactionIDs: [TransactionID], totalCents: Int, monthlyCents: Int? = nil, suggestion: CategorySuggestion? = nil, alternatives: [CategoryID] = []) {
            self.id = id
            self.kind = kind
            self.title = title
            self.match = match
            self.transactionIDs = transactionIDs
            self.totalCents = totalCents
            self.monthlyCents = monthlyCents
            self.suggestion = suggestion
            self.alternatives = alternatives
        }
    }

    /// Booked/pending/planned transactions (cancelled left out).
    public var totalTransactions: Int
    /// Of those with a trusted category (manual or rule, any confidence ≥ review threshold).
    public var categorizedTransactions: Int
    /// Absolute amounts (cents), for "y % des Betrags".
    public var totalAbsoluteCents: Int
    public var categorizedAbsoluteCents: Int
    /// Distinct counterparts among the open transactions.
    public var openCounterparts: Int
    public var candidates: [Candidate]
    /// Share of transactions categorized if every candidate is accepted (0…1).
    public var projectedCoverage: Double

    public init(totalTransactions: Int = 0, categorizedTransactions: Int = 0, totalAbsoluteCents: Int = 0, categorizedAbsoluteCents: Int = 0, openCounterparts: Int = 0, candidates: [Candidate] = [], projectedCoverage: Double = 0) {
        self.totalTransactions = totalTransactions
        self.categorizedTransactions = categorizedTransactions
        self.totalAbsoluteCents = totalAbsoluteCents
        self.categorizedAbsoluteCents = categorizedAbsoluteCents
        self.openCounterparts = openCounterparts
        self.candidates = candidates
        self.projectedCoverage = projectedCoverage
    }

    public var coverage: Double { totalTransactions == 0 ? 1 : Double(categorizedTransactions) / Double(totalTransactions) }
    public var amountCoverage: Double { totalAbsoluteCents == 0 ? 1 : Double(categorizedAbsoluteCents) / Double(totalAbsoluteCents) }

    public func candidates(_ kind: Candidate.Kind) -> [Candidate] { candidates.filter { $0.kind == kind } }

    /// Whether to offer the assistant on its own (after the first sync): more than half open.
    public var suggestsSetup: Bool { totalTransactions >= 20 && coverage < 0.5 }
}

extension CategorizationService {
    /// Builds the assistant's plan from the current ledger without writing anything.
    ///
    /// Open transactions (no trusted category) are handed out in this order, each to at most one
    /// candidate:
    /// 1. `.transfer`: what `TransferStage` recognizes (own IBAN, exact counter-booking), grouped
    ///    by the rule that would cover it. Groups whose rule would also hit other open transactions
    ///    are left out.
    /// 2. The rest is grouped by `CategoryRule.Match.suggested(for:)`. A group whose money mostly
    ///    comes in and recurs in ≥ 2 months is `.income`; one that mostly goes out and is a direct
    ///    debit (creditor ID/mandate) recurring in ≥ 2 months, or a stable payment in ≥ 3 months,
    ///    is `.fixedCost`. `monthlyCents` is the median of the monthly sums.
    /// 3. Everything else is `.counterparty`, ranked by count × amount.
    ///
    /// Candidates come in that order (each kind by impact), at most `limit` in total.
    /// `projectedCoverage` counts the open transactions of the returned candidates.
    public func setupPlan(limit: Int = 40) async -> SetupPlan {
        let snapshot = await storeSnapshot()
        let builder = SetupPlanBuilder(snapshot: snapshot)
        let drafts = await builder.drafts(limit: limit)
        let representatives = drafts.compactMap(\.transactions.first)
        let cascade = await suggest(representatives, snapshot: snapshot)
        return await builder.plan(drafts, cascade: cascade)
    }
}

/// The non-isolated part of `setupPlan`, one per call.
struct SetupPlanBuilder: Sendable {
    struct Draft: Sendable {
        var kind: SetupPlan.Candidate.Kind
        var match: CategoryRule.Match
        var title: String
        var transactions: [Transaction]
        var monthlyCents: Int?
        /// From the plan itself (transfer detection, salary heuristic); the cascade comes first.
        var suggestion: CategorySuggestion?
        var weight: Int
        var totalCents: Int { transactions.reduce(0) { $0 + $1.amountCents } }
        var isInflow: Bool { totalCents > 0 }
    }

    /// Confidence of the plan's own heuristics (salary): a hint, not a category.
    static let heuristicConfidence = 0.6

    let snapshot: LedgerSnapshot
    let relevant: [Transaction]
    let open: [Transaction]
    let context: CategorizationContext

    init(snapshot: LedgerSnapshot) {
        self.snapshot = snapshot
        relevant = snapshot.transactions.filter { $0.status != .cancelled }
        open = relevant.filter { !Self.trusted($0) }
        context = CategorizationContext(snapshot: snapshot)
    }

    static func trusted(_ transaction: Transaction) -> Bool {
        transaction.categoryID != nil
            && (transaction.categorySource == .manual || (transaction.confidence ?? 0) >= Categorizer.reviewThreshold)
    }

    // MARK: - Drafts

    func drafts(limit: Int) async -> [Draft] {
        var assigned = Set<TransactionID>()
        let transfers = await transferDrafts(assigned: &assigned)
        var income: [Draft] = [], fixed: [Draft] = [], counterparty: [Draft] = []
        for (match, transactions) in Self.grouped(open.filter { !assigned.contains($0.id) }) {
            var draft = Draft(kind: .counterparty, match: match, title: Self.title(transactions[0], match), transactions: transactions, weight: Self.weight(transactions))
            if let monthly = Self.recurringIncome(transactions) {
                draft.kind = .income
                draft.monthlyCents = monthly
                if Self.looksLikeSalary(transactions, monthly: monthly) {
                    draft.suggestion = CategorySuggestion(categoryID: "gehalt", source: .rule, confidence: Self.heuristicConfidence)
                }
                income.append(draft)
            } else if let monthly = Self.fixedCost(transactions) {
                draft.kind = .fixedCost
                draft.monthlyCents = monthly
                fixed.append(draft)
            } else {
                counterparty.append(draft)
            }
        }
        let byWeight: (Draft, Draft) -> Bool = { $0.weight != $1.weight ? $0.weight > $1.weight : $0.title < $1.title }
        let all = transfers.sorted(by: byWeight) + income.sorted(by: byWeight) + fixed.sorted(by: byWeight) + counterparty.sorted(by: byWeight)
        return Array(all.prefix(max(0, limit)))
    }

    private func transferDrafts(assigned: inout Set<TransactionID>) async -> [Draft] {
        let found = await TransferStage().suggest(open, context: context)
        guard !found.isEmpty else { return [] }
        var groups: [CategoryRule.Match: [Transaction]] = [:]
        var order: [CategoryRule.Match] = []
        for transaction in open where found[transaction.id] != nil {
            let iban = transaction.counterpartIBAN.map(LearnedRules.compact) ?? ""
            let match: CategoryRule.Match? = context.ownIBANs.contains(iban) ? .counterpartIBAN(iban) : CategoryRule.Match.suggested(for: transaction)
            guard let match else { continue }
            if groups[match] == nil { order.append(match) }
            groups[match, default: []].append(transaction)
        }
        let others = open.filter { found[$0.id] == nil }
        var drafts: [Draft] = []
        for match in order {
            guard let transactions = groups[match] else { continue }
            let rule = CategoryRule(match: match, categoryID: TransferStage.category)
            // Accepting the candidate stores this rule; it must not sweep up real payments.
            if others.contains(where: rule.matches) { continue }
            var counts: [CategoryID: Int] = [:]
            for transaction in transactions { if let c = found[transaction.id]?.categoryID { counts[c, default: 0] += 1 } }
            let category = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue > $1.key.rawValue }?.key ?? TransferStage.category
            transactions.forEach { assigned.insert($0.id) }
            drafts.append(Draft(
                kind: .transfer,
                match: match,
                title: transferTitle(transactions[0], match: match, category: category),
                transactions: transactions,
                suggestion: CategorySuggestion(categoryID: category, source: .rule, confidence: TransferStage.confidence),
                weight: Self.weight(transactions)
            ))
        }
        return drafts
    }

    private func transferTitle(_ transaction: Transaction, match: CategoryRule.Match, category: CategoryID) -> String {
        if case let .counterpartIBAN(iban) = match,
           let id = context.ownAccountsByIBAN[iban],
           let account = snapshot.accounts.first(where: { $0.id == id }) {
            return "\(account.type == .card ? "Kreditkarte" : "Eigenes Konto"): \(snapshot.displayName(of: account))"
        }
        return Self.title(transaction, match)
    }

    /// Groups by the rule the sheet would suggest, in ledger order.
    static func grouped(_ transactions: [Transaction]) -> [(CategoryRule.Match, [Transaction])] {
        var groups: [CategoryRule.Match: [Transaction]] = [:]
        var order: [CategoryRule.Match] = []
        for transaction in transactions {
            guard let match = CategoryRule.Match.suggested(for: transaction) else { continue }
            if groups[match] == nil { order.append(match) }
            groups[match, default: []].append(transaction)
        }
        return order.compactMap { match in groups[match].map { (match, $0) } }
    }

    static func title(_ transaction: Transaction, _ match: CategoryRule.Match) -> String {
        if !transaction.counterpartName.trimmingCharacters(in: .whitespaces).isEmpty { return transaction.counterpartName }
        switch match {
        case let .creditorID(v), let .mandateReference(v), let .counterpartIBAN(v), let .counterpart(v), let .purpose(v): return v
        }
    }

    /// Count × euros, as in the basic version.
    static func weight(_ transactions: [Transaction]) -> Int {
        transactions.count * max(1, transactions.reduce(0) { $0 + abs($1.amountCents) } / 100)
    }

    // MARK: - Recurrence

    struct Month: Hashable, Comparable {
        let year: Int, month: Int
        static func < (a: Month, b: Month) -> Bool { (a.year, a.month) < (b.year, b.month) }
    }

    /// Signed sums per calendar month.
    static func monthlySums(_ transactions: [Transaction]) -> [Month: Int] {
        var sums: [Month: Int] = [:]
        for t in transactions { sums[Month(year: t.effectiveDate.year, month: t.effectiveDate.month), default: 0] += t.amountCents }
        return sums
    }

    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Share of values within `tolerance` (relative) of their median.
    static func stability(_ values: [Int], tolerance: Double) -> Double {
        guard let median = median(values), median != 0 else { return 0 }
        let close = values.count { abs(Double($0 - median)) <= abs(Double(median)) * tolerance }
        return Double(close) / Double(values.count)
    }

    /// Median monthly inflow if money mostly comes in and recurs in ≥ 2 months, at most twice a
    /// month on average.
    static func recurringIncome(_ transactions: [Transaction]) -> Int? {
        let inflows = transactions.filter { $0.amountCents > 0 }
        let inSum = inflows.reduce(0) { $0 + $1.amountCents }
        let outSum = transactions.reduce(0) { $0 + max(0, -$1.amountCents) }
        guard inSum > outSum else { return nil }
        let sums = monthlySums(inflows)
        guard sums.count >= 2, inflows.count <= sums.count * 2 else { return nil }
        return median(Array(sums.values))
    }

    /// Median monthly outflow (negative) for direct debits recurring in ≥ 2 months, or other
    /// payments with a stable amount in ≥ 3 months; at most ~1,5 a month either way, so a payment
    /// service's direct debits (PayPal: many a month, any amount) stay a counterparty.
    static func fixedCost(_ transactions: [Transaction]) -> Int? {
        let outflows = transactions.filter { $0.amountCents < 0 }
        let outSum = outflows.reduce(0) { $0 - $1.amountCents }
        let inSum = transactions.reduce(0) { $0 + max(0, $1.amountCents) }
        guard outSum >= inSum, !outflows.isEmpty else { return nil }
        let sums = monthlySums(outflows)
        guard Double(outflows.count) <= Double(sums.count) * 1.5 else { return nil }
        let amounts = outflows.map(\.amountCents)
        let isDirectDebit = outflows.contains { ($0.creditorID?.isEmpty == false) || ($0.mref?.isEmpty == false) }
        let recurring = isDirectDebit
            ? sums.count >= 2 && stability(amounts, tolerance: 0.25) >= 0.6
            : sums.count >= 3 && stability(amounts, tolerance: 0.1) >= 0.8
        return recurring ? median(Array(sums.values)) : nil
    }

    static let salaryWords = ["gehalt", "lohn", "bezuege", "entgeltabrechnung"]

    /// Salary words in the purpose, or ≥ 500 € a month with a fairly stable amount.
    static func looksLikeSalary(_ transactions: [Transaction], monthly: Int) -> Bool {
        let inflows = transactions.filter { $0.amountCents > 0 }
        if inflows.contains(where: { t in MerchantText.words(t.purpose).contains { w in salaryWords.contains { w.hasPrefix($0) } } }) {
            return true
        }
        return monthly >= 50_000 && stability(inflows.map(\.amountCents), tolerance: 0.3) >= 0.7
    }

    // MARK: - Plan

    func plan(_ drafts: [Draft], cascade: [TransactionID: CategorySuggestion]) async -> SetupPlan {
        let representatives = drafts.compactMap(\.transactions.first)
        let known = await KnownMerchantStage().suggest(representatives, context: context)
        var candidates: [SetupPlan.Candidate] = []
        var seenIDs = Set<String>()
        for draft in drafts {
            guard let first = draft.transactions.first else { continue }
            var suggestion = draft.kind == .transfer ? draft.suggestion : (cascade[first.id] ?? known[first.id] ?? draft.suggestion)
            // Salary from a well-known employer (a supermarket): the merchant list's guess does not apply.
            if draft.kind == .income, let own = draft.suggestion,
               let current = suggestion, CategoryCatalog.info(current.categoryID)?.isIncome != true,
               current.confidence <= KnownMerchantStage.confidence {
                suggestion = own
            }
            if let current = suggestion, !draft.isInflow, CategoryCatalog.info(current.categoryID)?.isIncome == true {
                suggestion = nil
            }
            var id = "\(draft.kind.rawValue):\(String(describing: draft.match))"
            while !seenIDs.insert(id).inserted { id += "'" }
            candidates.append(SetupPlan.Candidate(
                id: id,
                kind: draft.kind,
                title: draft.title,
                match: draft.match,
                transactionIDs: draft.transactions.map(\.id),
                totalCents: draft.totalCents,
                monthlyCents: draft.monthlyCents,
                suggestion: suggestion,
                alternatives: Self.alternatives(for: draft, suggestion: suggestion, known: known[first.id]?.categoryID)
            ))
        }
        let covered = Set(candidates.flatMap(\.transactionIDs))
        let categorized = relevant.count - open.count
        return SetupPlan(
            totalTransactions: relevant.count,
            categorizedTransactions: categorized,
            totalAbsoluteCents: relevant.reduce(0) { $0 + abs($1.amountCents) },
            categorizedAbsoluteCents: relevant.filter(Self.trusted).reduce(0) { $0 + abs($1.amountCents) },
            openCounterparts: Set(open.map { $0.counterpartName.lowercased() }).count,
            candidates: candidates,
            projectedCoverage: relevant.isEmpty ? 1 : Double(categorized + covered.count) / Double(relevant.count)
        )
    }

    /// Suggestion first, then the merchant list, the machine guesses already on the transactions
    /// (most frequent first), then typical categories for the kind. Income categories only for
    /// money coming in; at most 9 (number keys).
    static func alternatives(for draft: Draft, suggestion: CategorySuggestion?, known: CategoryID?) -> [CategoryID] {
        var counts: [CategoryID: Int] = [:]
        for t in draft.transactions { if let c = t.categoryID { counts[c, default: 0] += 1 } }
        let guesses = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.map(\.key)
        let typical: [CategoryID] = switch (draft.kind, draft.isInflow) {
        case (.transfer, _): ["umbuchung", "kredit", "sparen_anlegen", "bargeld"]
        case (.income, _): ["gehalt", "einnahmen_sonstige", "erstattung", "zinsen", "umbuchung", "sparen_anlegen", "miete", "kinder"]
        case (.fixedCost, _): ["miete", "nebenkosten", "internet_telefon", "versicherung", "abos", "kredit", "sparen_anlegen", "sport", "steuern"]
        case (.counterparty, true): ["erstattung", "einnahmen_sonstige", "gehalt", "umbuchung", "online_shopping", "geschenke_spenden", "zinsen", "sonstiges"]
        case (.counterparty, false): ["lebensmittel", "restaurant", "online_shopping", "drogerie", "haushalt", "tanken", "kleidung", "freizeit", "sonstiges"]
        }
        var result: [CategoryID] = []
        for id in [suggestion?.categoryID, known].compactMap(\.self) + guesses + typical {
            guard !result.contains(id), let info = CategoryCatalog.info(id) else { continue }
            if info.isIncome, !draft.isInflow { continue }
            result.append(id)
            if result.count == 9 { break }
        }
        return result
    }
}
