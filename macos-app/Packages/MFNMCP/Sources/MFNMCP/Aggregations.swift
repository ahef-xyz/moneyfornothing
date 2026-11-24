import Foundation
import MFNCore

/// A closed range of days, both ends included.
public struct DayPeriod: Hashable, Sendable {
    public var from: BankDay
    public var to: BankDay

    public init?(from: BankDay, to: BankDay) {
        guard from <= to else { return nil }
        self.init(checked: from, to)
    }

    private init(checked from: BankDay, _ to: BankDay) {
        self.from = from
        self.to = to
    }

    public func contains(_ day: BankDay) -> Bool { from <= day && day <= to }

    /// Days in the period (1 for a single day).
    public var length: Int { from.days(to: to) + 1 }

    /// The calendar month of `day`.
    public static func month(of day: BankDay) -> DayPeriod {
        let first = BankDay(year: day.year, month: day.month, day: 1) ?? day
        let last = first.adding(months: 1).adding(days: -1)
        return DayPeriod(from: first, to: last) ?? DayPeriod(checked: day, day)
    }

    /// "2026-11" for every month the period touches, oldest first.
    public var months: [String] {
        var result: [String] = []
        var cursor = BankDay(year: from.year, month: from.month, day: 1) ?? from
        while cursor <= to {
            result.append(Aggregations.monthKey(cursor))
            cursor = cursor.adding(months: 1)
        }
        return result
    }
}

/// The sums behind `sum_by_category`, `compare_periods` and `cash_flow`: pure functions over
/// transactions, so MFN adds and the model never does (CLAUDE.md §8). Shared with the planned
/// on-device questions (docs/v0.6.0.md O2).
///
/// What counts: booked transactions, and pending ones unless `includePending` is off. Planned
/// and cancelled ones never. Days are `Transaction.effectiveDate`. Sums are per currency.
public enum Aggregations {
    public enum Direction: String, Sendable {
        case income, spending
    }

    public struct CategorySum: Hashable, Sendable {
        public var categoryID: CategoryID?
        /// Of `count`, bookings without a category that count here because they go to or come
        /// from an own account (by IBAN), as in `cashFlow`. Only in the transfer row.
        public var uncategorizedTransfers = 0
        /// "2026-11" when summed per month.
        public var month: String?
        public var currency: String
        public var cents: Int
        public var count: Int
    }

    public struct Comparison: Hashable, Sendable {
        public var categoryID: CategoryID?
        public var currency: String
        public var firstCents: Int
        public var secondCents: Int
        public var firstCount: Int
        public var secondCount: Int
        /// Second minus first.
        public var differenceCents: Int { secondCents - firstCents }
    }

    public struct MonthFlow: Hashable, Sendable {
        public var month: String
        public var currency: String
        public var incomeCents = 0
        /// Positive: money that went out.
        public var spendingCents = 0
        public var netCents: Int { incomeCents - spendingCents }
        /// Bookings left out as transfers between own accounts.
        public var transfersLeftOut = 0
    }

    public static func counts(_ transaction: Transaction, includePending: Bool) -> Bool {
        switch transaction.status {
        case .booked: true
        case .pending: includePending
        case .planned, .cancelled: false
        }
    }

    static func monthKey(_ day: BankDay) -> String {
        "\(day.year)-\(day.month < 10 ? "0" : "")\(day.month)"
    }

    static func matches(_ cents: Int, _ direction: Direction?) -> Bool {
        switch direction {
        case nil: true
        case .income: cents > 0
        case .spending: cents < 0
        }
    }

    /// Sums per category (and month), largest outflow first within a month.
    public static func sumByCategory(_ transactions: [Transaction], in period: DayPeriod, byMonth: Bool = false,
                                     direction: Direction? = nil, includePending: Bool = true, ownIBANs: Set<String> = []) -> [CategorySum] {
        struct Key: Hashable { var category: CategoryID?; var month: String?; var currency: String }
        let own = Set(ownIBANs.map(compactIBAN).filter { !$0.isEmpty })
        var sums: [Key: (cents: Int, count: Int, detected: Int)] = [:]
        for transaction in transactions where counts(transaction, includePending: includePending)
            && period.contains(transaction.effectiveDate) && matches(transaction.amountCents, direction) {
            let detected = transaction.categoryID == nil && (transaction.counterpartIBAN.map { own.contains(compactIBAN($0)) } ?? false)
            let category = detected ? TransferStage.category : transaction.categoryID
            let key = Key(category: category, month: byMonth ? monthKey(transaction.effectiveDate) : nil, currency: transaction.currency)
            sums[key, default: (0, 0, 0)].cents += transaction.amountCents
            sums[key, default: (0, 0, 0)].count += 1
            if detected { sums[key, default: (0, 0, 0)].detected += 1 }
        }
        return sums.map { CategorySum(categoryID: $0.key.category, uncategorizedTransfers: $0.value.detected, month: $0.key.month,
                                      currency: $0.key.currency, cents: $0.value.cents, count: $0.value.count) }
            .sorted { ($0.month ?? "", $0.currency, $0.cents, $0.categoryID?.rawValue ?? "") < ($1.month ?? "", $1.currency, $1.cents, $1.categoryID?.rawValue ?? "") }
    }

    /// Both periods per category; categories present in either.
    public static func compare(_ transactions: [Transaction], first: DayPeriod, second: DayPeriod,
                               direction: Direction? = nil, includePending: Bool = true, ownIBANs: Set<String> = []) -> [Comparison] {
        struct Key: Hashable { var category: CategoryID?; var currency: String }
        let a = Dictionary(uniqueKeysWithValues: sumByCategory(transactions, in: first, direction: direction, includePending: includePending, ownIBANs: ownIBANs)
            .map { (Key(category: $0.categoryID, currency: $0.currency), $0) })
        let b = Dictionary(uniqueKeysWithValues: sumByCategory(transactions, in: second, direction: direction, includePending: includePending, ownIBANs: ownIBANs)
            .map { (Key(category: $0.categoryID, currency: $0.currency), $0) })
        return Set(a.keys).union(b.keys).map { key in
            Comparison(categoryID: key.category, currency: key.currency,
                       firstCents: a[key]?.cents ?? 0, secondCents: b[key]?.cents ?? 0,
                       firstCount: a[key]?.count ?? 0, secondCount: b[key]?.count ?? 0)
        }
        .sorted { (abs($0.differenceCents), $1.categoryID?.rawValue ?? "") > (abs($1.differenceCents), $0.categoryID?.rawValue ?? "") }
    }

    /// Income, spending and net per month, without transfers between own accounts
    /// (`TransferRules`). Every month of the period appears for every currency seen.
    public static func cashFlow(_ transactions: [Transaction], accounts: [Account], in period: DayPeriod,
                                includePending: Bool = true) -> [MonthFlow] {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hasCardAccount = accounts.contains { $0.type == .card }
        // A transfer to or from an own account also counts as one before it has a category.
        let ownIBANs = Set(accounts.compactMap { $0.iban.map(compactIBAN) }.filter { !$0.isEmpty })
        struct Key: Hashable { var month: String; var currency: String }
        var flows: [Key: MonthFlow] = [:]
        var currencies: Set<String> = []
        for transaction in transactions where counts(transaction, includePending: includePending) && period.contains(transaction.effectiveDate) {
            let key = Key(month: monthKey(transaction.effectiveDate), currency: transaction.currency)
            currencies.insert(transaction.currency)
            var flow = flows[key] ?? MonthFlow(month: key.month, currency: key.currency)
            let toOwnAccount = transaction.counterpartIBAN.map { ownIBANs.contains(compactIBAN($0)) } ?? false
            if toOwnAccount || TransferRules.isOwnTransfer(transaction, account: byID[transaction.accountID], hasCardAccount: hasCardAccount) {
                flow.transfersLeftOut += 1
            } else if transaction.amountCents > 0 {
                flow.incomeCents += transaction.amountCents
            } else {
                flow.spendingCents -= transaction.amountCents
            }
            flows[key] = flow
        }
        var result: [MonthFlow] = []
        for currency in currencies.sorted() {
            for month in period.months {
                result.append(flows[Key(month: month, currency: currency)] ?? MonthFlow(month: month, currency: currency))
            }
        }
        return result
    }

    static func compactIBAN(_ iban: String) -> String {
        iban.uppercased().filter { !$0.isWhitespace }
    }

    /// Booked balance of an account at the end of `day`: today's booked balance minus the booked
    /// transactions after that day. `nil` if the account has no balance or another currency.
    public static func balance(on day: BankDay, current: Balance, transactions: [Transaction]) -> Int? {
        var cents = current.bookedCents
        for transaction in transactions where transaction.status == .booked && transaction.effectiveDate > day {
            guard transaction.currency == current.currency else { return nil }
            cents -= transaction.amountCents
        }
        return cents
    }
}
