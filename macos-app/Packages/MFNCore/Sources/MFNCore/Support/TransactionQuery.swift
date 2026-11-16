import Foundation

/// Search, filter and sort for transaction lists (UI now, later the `listTransactions` tool of
/// the language model, CLAUDE.md §8). Pure and synchronous; no I/O.
public struct TransactionQuery: Hashable, Sendable {
    public enum Sort: String, CaseIterable, Hashable, Sendable {
        case newestFirst
        case oldestFirst
        /// Largest expense first.
        case largestOutflow
        /// Largest income first.
        case largestInflow
        /// Counterpart A–Z, then newest first.
        case counterpart

        /// Only date sorts keep the day sections and running balances in the list.
        public var isChronological: Bool { self == .newestFirst || self == .oldestFirst }
    }

    public enum Direction: String, CaseIterable, Hashable, Sendable {
        case all, inflow, outflow
    }

    public enum Period: String, CaseIterable, Hashable, Sendable {
        case all, thisMonth, lastMonth, last30Days, last90Days, thisYear, lastYear

        /// Inclusive bank-day range relative to `today`, `nil` for `.all`.
        public func range(today: BankDay) -> ClosedRange<BankDay>? {
            let firstOfMonth = BankDay(year: today.year, month: today.month, day: 1) ?? today
            switch self {
            case .all: return nil
            case .thisMonth: return firstOfMonth...today
            case .lastMonth:
                let start = firstOfMonth.adding(months: -1)
                return start...firstOfMonth.adding(days: -1)
            case .last30Days: return today.adding(days: -29)...today
            case .last90Days: return today.adding(days: -89)...today
            case .thisYear: return (BankDay(year: today.year, month: 1, day: 1) ?? today)...today
            case .lastYear:
                guard let start = BankDay(year: today.year - 1, month: 1, day: 1),
                      let end = BankDay(year: today.year - 1, month: 12, day: 31) else { return nil }
                return start...end
            }
        }
    }

    public var text: String
    public var sort: Sort
    public var direction: Direction
    public var period: Period
    /// `nil` = all categories.
    public var category: CategoryID?
    /// Empty = all accounts.
    public var accounts: Set<AccountID>
    /// `TransactionInitiator.key` of the person who made the transaction (shared accounts); `nil` = everyone.
    public var initiator: String?
    /// Only transactions without any category (takes precedence over `category`).
    public var onlyUncategorized = false
    /// Only rows a CSV import added (`Transaction.importID`).
    public var onlyImported = false

    public init(
        text: String = "",
        sort: Sort = .newestFirst,
        direction: Direction = .all,
        period: Period = .all,
        category: CategoryID? = nil,
        accounts: Set<AccountID> = []
    ) {
        self.text = text
        self.sort = sort
        self.direction = direction
        self.period = period
        self.category = category
        self.accounts = accounts
    }

    /// Something narrows the list (sorting alone does not).
    public var isFiltering: Bool {
        !tokens.isEmpty || direction != .all || period != .all || category != nil || !accounts.isEmpty || initiator != nil || onlyUncategorized || onlyImported
    }

    /// Filters only, keeps the order of `transactions`.
    /// - Parameter initiator: the person behind a transaction (shared accounts), for the
    ///   `initiator` filter and the text search.
    public func filter(
        _ transactions: [Transaction],
        today: BankDay = .today,
        accountName: (AccountID) -> String? = { _ in nil },
        initiator: (Transaction) -> TransactionInitiator? = { _ in nil }
    ) -> [Transaction] {
        let range = period.range(today: today)
        let tokens = self.tokens.map(SearchToken.init)
        return transactions.filter { transaction in
            switch direction {
            case .all: break
            case .inflow: guard transaction.amountCents > 0 else { return false }
            case .outflow: guard transaction.amountCents < 0 else { return false }
            }
            if let range, !range.contains(transaction.effectiveDate) { return false }
            if onlyImported, transaction.importID == nil { return false }
            if onlyUncategorized {
                if transaction.categoryID != nil { return false }
            } else if let category, transaction.categoryID != category { return false }
            if !accounts.isEmpty, !accounts.contains(transaction.accountID) { return false }
            let person = (self.initiator != nil || !tokens.isEmpty) ? initiator(transaction) : nil
            if let wanted = self.initiator, person?.key != wanted { return false }
            guard !tokens.isEmpty else { return true }
            // Each field folded once per transaction, not once per token.
            let fields = SearchFields(transaction, accountName: accountName(transaction.accountID), extra: person?.name)
            return tokens.allSatisfy { fields.matches($0, amountCents: transaction.amountCents) }
        }
    }

    /// Filters and sorts.
    public func apply(
        _ transactions: [Transaction],
        today: BankDay = .today,
        accountName: (AccountID) -> String? = { _ in nil },
        initiator: (Transaction) -> TransactionInitiator? = { _ in nil }
    ) -> [Transaction] {
        sorted(filter(transactions, today: today, accountName: accountName, initiator: initiator))
    }

    /// Stable sort by `sort`; ties keep newest first.
    public func sorted(_ transactions: [Transaction]) -> [Transaction] {
        let newestFirst: (Transaction, Transaction) -> Bool = { $0.effectiveDate > $1.effectiveDate }
        let indexed = Array(transactions.enumerated())
        func order(_ a: (offset: Int, element: Transaction), _ b: (offset: Int, element: Transaction), _ less: (Transaction, Transaction) -> Bool?) -> Bool {
            if let result = less(a.element, b.element) { return result }
            return a.offset < b.offset
        }
        let result: [(offset: Int, element: Transaction)] = switch sort {
        case .newestFirst:
            indexed.sorted { order($0, $1) { $0.effectiveDate == $1.effectiveDate ? nil : newestFirst($0, $1) } }
        case .oldestFirst:
            indexed.sorted { order($0, $1) { $0.effectiveDate == $1.effectiveDate ? nil : $0.effectiveDate < $1.effectiveDate } }
        case .largestOutflow:
            indexed.sorted { order($0, $1) { $0.amountCents == $1.amountCents ? nil : $0.amountCents < $1.amountCents } }
        case .largestInflow:
            indexed.sorted { order($0, $1) { $0.amountCents == $1.amountCents ? nil : $0.amountCents > $1.amountCents } }
        case .counterpart:
            indexed.sorted {
                order($0, $1) { a, b in
                    let result = a.counterpartName.localizedStandardCompare(b.counterpartName)
                    return result == .orderedSame ? (a.effectiveDate == b.effectiveDate ? nil : newestFirst(a, b)) : result == .orderedAscending
                }
            }
        }
        return result.map(\.element)
    }

    // MARK: Text search

    /// Words of the search text; all must match (AND).
    var tokens: [String] {
        text.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }.filter { !$0.isEmpty }
    }

    private static let foldingLocale = Locale(identifier: "de_DE")

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: foldingLocale)
    }

    /// A search word, parsed once per query.
    struct SearchToken {
        let text: String
        let cents: Int?
        let signed: Bool

        init(_ text: String) {
            self.text = text
            cents = TransactionQuery.amountCents(text)
            signed = text.hasPrefix("-") || text.hasPrefix("+")
        }
    }

    /// The searchable fields of one transaction, folded once.
    struct SearchFields {
        /// Folded and without spaces: IBANs are typed with or without them. Search words never
        /// contain spaces, so this one check also covers the field as written.
        let compact: [String]

        init(_ transaction: Transaction, accountName: String?, extra: String?) {
            let fields: [String?] = [
                transaction.counterpartName, transaction.purpose, transaction.counterpartIBAN, transaction.eref,
                transaction.mref, transaction.creditorID, transaction.categoryID?.rawValue, accountName, extra,
            ]
            compact = fields.compactMap { field in
                field.map { TransactionQuery.fold($0).replacingOccurrences(of: " ", with: "") }
            }
        }

        /// The word matches a field, or – if it is a number like `12,50`, `12.5` or `-12` – the
        /// amount (sign ignored unless given).
        func matches(_ token: SearchToken, amountCents: Int) -> Bool {
            if let cents = token.cents, token.signed ? amountCents == cents : abs(amountCents) == abs(cents) { return true }
            return compact.contains { $0.contains(token.text) }
        }
    }

    /// A word matches a text field or the amount (see `SearchFields.matches`).
    static func matches(_ token: String, _ transaction: Transaction, accountName: String?, extra: String? = nil) -> Bool {
        SearchFields(transaction, accountName: accountName, extra: extra).matches(SearchToken(token), amountCents: transaction.amountCents)
    }

    /// `12`, `12,5`, `12,50`, `12.50`, `1.234,56`, `-3,99` → cents; `nil` if not an amount.
    static func amountCents(_ token: String) -> Int? {
        var text = token
        var sign = 1
        if text.hasPrefix("-") { sign = -1; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        text = text.replacingOccurrences(of: "€", with: "")
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }), text.contains(where: \.isNumber) else { return nil }
        // German style: last separator followed by 1–2 digits is the decimal mark.
        let separators = text.indices.filter { text[$0] == "," || text[$0] == "." }
        var euros = text
        var cents = 0
        if let last = separators.last {
            let fraction = text[text.index(after: last)...]
            if (1...2).contains(fraction.count) {
                euros = String(text[..<last])
                cents = Int(fraction.count == 1 ? fraction + "0" : String(fraction)) ?? 0
            }
        }
        euros.removeAll { $0 == "," || $0 == "." }
        guard let whole = euros.isEmpty ? 0 : Int(euros), whole < 100_000_000 else { return nil }
        return sign * (whole * 100 + cents)
    }
}
