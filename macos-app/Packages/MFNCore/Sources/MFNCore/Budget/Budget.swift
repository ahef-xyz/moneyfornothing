import Foundation

/// A spending budget for one account and a recurring period.
public struct AccountBudget: Hashable, Codable, Sendable, Identifiable {
    public enum Period: String, Hashable, Codable, Sendable, CaseIterable {
        case weekly, monthly, quarterly, yearly

        public var title: String {
            switch self {
            case .weekly: "Woche"
            case .monthly: "Monat"
            case .quarterly: "Quartal"
            case .yearly: "Jahr"
            }
        }
    }

    /// Start the period with the account's top-up ("Aufladung": salary, transfer from another
    /// account) instead of the fixed day: if a qualifying deposit lands within ± `toleranceDays`
    /// of the nominal start, the period starts that day.
    public struct IncomeAnchor: Hashable, Codable, Sendable {
        /// 1…7 (weekly budgets at most 3, so weeks cannot overlap).
        public var toleranceDays: Int
        /// Only deposits from this counterpart (contains, case/accents ignored); `nil` = the
        /// largest deposit in the window of at least `minimumShare` of the budget.
        public var counterpart: String?

        public static let minimumShare = 0.25

        public init(toleranceDays: Int = 3, counterpart: String? = nil) {
            self.toleranceDays = min(max(toleranceDays, 1), 7)
            let trimmed = counterpart?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.counterpart = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    public var accountID: AccountID
    /// Budget per period in cents (positive).
    public var amountCents: Int
    public var period: Period
    /// First day of a period: day of month 1…28 (monthly, quarterly, yearly) or weekday
    /// 1 = Monday … 7 = Sunday (weekly).
    public var startDay: Int
    /// `nil` = the period always starts on `startDay`.
    public var anchor: IncomeAnchor?

    public var id: AccountID { accountID }

    public init(accountID: AccountID, amountCents: Int, period: Period = .monthly, startDay: Int = 1, anchor: IncomeAnchor? = nil) {
        self.accountID = accountID
        self.amountCents = max(0, amountCents)
        self.period = period
        self.startDay = period == .weekly ? min(max(startDay, 1), 7) : min(max(startDay, 1), 28)
        if var anchor, period == .weekly { anchor.toleranceDays = min(anchor.toleranceDays, 3); self.anchor = anchor } else { self.anchor = anchor }
    }

    /// The period that contains `day`. With an `anchor`, `transactions` (any accounts; only this
    /// account's deposits are used) move period starts to the day the money came in.
    public func range(containing day: BankDay, transactions: [Transaction] = []) -> ClosedRange<BankDay> {
        let starts = actualStarts(around: day, transactions: transactions)
        let index = starts.lastIndex { $0 <= day } ?? 0
        return starts[index]...starts[index + 1].adding(days: -1)
    }

    /// The `count` complete periods before the one containing `day`, newest first.
    public func previousRanges(before day: BankDay, count: Int, transactions: [Transaction] = []) -> [ClosedRange<BankDay>] {
        let starts = actualStarts(around: day, transactions: transactions, before: count + 1)
        guard let current = starts.lastIndex(where: { $0 <= day }) else { return [] }
        return (0..<count).compactMap { offset in
            let index = current - 1 - offset
            guard index >= 0 else { return nil }
            return starts[index]...starts[index + 1].adding(days: -1)
        }
    }

    /// Nominal period starts around `day` (`before` periods back, 2 ahead), each moved to its
    /// anchor deposit if there is one. Strictly increasing.
    private func actualStarts(around day: BankDay, transactions: [Transaction], before: Int = 2) -> [BankDay] {
        var nominal: [BankDay] = [periodStart(containing: day)]
        for _ in 0..<before { nominal.insert(periodStart(containing: nominal[0].adding(days: -1)), at: 0) }
        for _ in 0..<2 { if let last = nominal.last { nominal.append(next(after: last)) } }
        guard let anchor else { return nominal }
        let deposits = transactions.filter {
            $0.accountID == accountID && $0.amountCents > 0 && $0.status != .cancelled && $0.status != .planned
        }
        var result: [BankDay] = []
        for start in nominal {
            let window = start.adding(days: -anchor.toleranceDays)...start.adding(days: anchor.toleranceDays)
            let moved = Self.anchorDeposit(in: window, deposits: deposits, anchor: anchor, budgetCents: amountCents)?.effectiveDate ?? start
            // Never at or before the previous start (tolerance is below half a period).
            result.append(result.last.map { max(moved, $0.adding(days: 1)) } ?? moved)
        }
        return result
    }

    /// The deposit that starts a period: from the chosen counterpart, else the largest of at
    /// least `minimumShare` of the budget; on a tie the earliest.
    static func anchorDeposit(in window: ClosedRange<BankDay>, deposits: [Transaction], anchor: IncomeAnchor, budgetCents: Int) -> Transaction? {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")) }
        let minimum = max(1, Int(Double(budgetCents) * IncomeAnchor.minimumShare))
        return deposits
            .filter { window.contains($0.effectiveDate) }
            .filter { deposit in
                if let wanted = anchor.counterpart { return fold(deposit.counterpartName).contains(fold(wanted)) }
                return deposit.amountCents >= minimum
            }
            .min { a, b in a.amountCents != b.amountCents ? a.amountCents > b.amountCents : a.effectiveDate < b.effectiveDate }
    }

    private func periodStart(containing day: BankDay) -> BankDay {
        switch period {
        case .weekly:
            // BankDay.weekday: 1 = Sunday … 7 = Saturday → Monday-based 1…7.
            let mondayBased = (day.weekday + 5) % 7 + 1
            return day.adding(days: -((mondayBased - startDay + 7) % 7))
        case .monthly, .quarterly, .yearly:
            let months = period == .monthly ? 1 : period == .quarterly ? 3 : 12
            // Anchor: startDay in January (quarters Jan/Apr/Jul/Oct, years from January).
            var candidate = BankDay(year: day.year, month: 1, day: startDay) ?? day
            if candidate > day { candidate = candidate.adding(months: -12) }
            while candidate.adding(months: months) <= day { candidate = candidate.adding(months: months) }
            return candidate
        }
    }

    private func next(after start: BankDay) -> BankDay {
        switch period {
        case .weekly: start.adding(days: 7)
        case .monthly: start.adding(months: 1)
        case .quarterly: start.adding(months: 3)
        case .yearly: start.adding(months: 12)
        }
    }
}

/// Where a budget stands today and where it is heading.
public struct BudgetStatus: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Forecast within the budget.
        case onTrack
        /// Spent is within, but the forecast goes over.
        case atRisk
        /// Already spent more than the budget.
        case exceeded
    }

    public var budget: AccountBudget
    public var range: ClosedRange<BankDay>
    /// Spent so far in the period (booked + pending outflows minus refunds), positive cents.
    public var spentCents: Int
    /// Planned transactions (standing orders, announced debits) still to come, positive cents.
    public var plannedCents: Int
    /// Recurring payments seen in earlier periods but not yet in this one, positive cents.
    public var expectedRecurringCents: Int
    /// Remaining variable spending at the usual pace, positive cents.
    public var expectedVariableCents: Int
    public var daysLeft: Int
    public var daysTotal: Int
    /// Last day the bank data covers (last sync); spending after it is forecast, not known.
    public var dataAsOf: BankDay

    /// Spent + everything expected until the period ends.
    public var forecastCents: Int { spentCents + plannedCents + expectedRecurringCents + expectedVariableCents }
    public var remainingCents: Int { budget.amountCents - spentCents }
    /// Left to spend per day, after planned and recurring payments (never negative).
    public var perDayCents: Int {
        guard daysLeft > 0 else { return 0 }
        return max(0, (budget.amountCents - spentCents - plannedCents - expectedRecurringCents) / daysLeft)
    }

    public var state: State {
        if spentCents > budget.amountCents { return .exceeded }
        return forecastCents > budget.amountCents ? .atRisk : .onTrack
    }

    public var spentFraction: Double { budget.amountCents == 0 ? 0 : Double(spentCents) / Double(budget.amountCents) }
    public var forecastFraction: Double { budget.amountCents == 0 ? 0 : Double(forecastCents) / Double(budget.amountCents) }
}

/// Computes `BudgetStatus` from the ledger (pure, synchronous).
///
/// What counts: outflows of the account (booked, pending) in the period; refunds
/// (`erstattung`) reduce them; transfers between own accounts (`umbuchung`) never count.
/// Forecast = spent + planned (status `.planned`) + recurring counterparts seen in ≥ 2 of the
/// last 3 periods but not yet in this one (median amount) + variable spending at the daily pace
/// of the last 3 periods (or of this period while there is no history) × days left.
public enum BudgetForecast {
    public static let excludedCategories: Set<CategoryID> = ["umbuchung"]
    public static let refundCategories: Set<CategoryID> = ["erstattung"]

    /// - Parameter dataAsOf: day of the last sync. Spending between it and the end of the period
    ///   is forecast (the bank has not reported it yet); `nil` = today.
    public static func status(for budget: AccountBudget, transactions: [Transaction], today: BankDay = .today, dataAsOf: BankDay? = nil) -> BudgetStatus {
        let range = budget.range(containing: today, transactions: transactions)
        // Data never claims to be newer than today, and is at least from the period start - 1.
        let asOf = min(max(dataAsOf ?? today, range.lowerBound.adding(days: -1)), today)
        let own = transactions.filter { $0.accountID == budget.accountID && $0.status != .cancelled && !excludedCategories.contains($0.categoryID ?? "") }
        let actual = own.filter { $0.status != .planned }

        func spending(_ list: [Transaction]) -> Int {
            list.reduce(0) { sum, t in
                if t.amountCents < 0 { return sum - t.amountCents }
                if let c = t.categoryID, refundCategories.contains(c) { return sum - t.amountCents }
                return sum
            }
        }

        let current = actual.filter { range.contains($0.effectiveDate) }
        let spent = max(0, spending(current))
        let planned = own.filter { $0.status == .planned && $0.amountCents < 0 && range.contains($0.valueDate) && $0.valueDate > asOf }
        let plannedCents = -planned.reduce(0) { $0 + $1.amountCents }

        // Recurring counterparts from earlier periods.
        let history = budget.previousRanges(before: today, count: 3, transactions: transactions)
        func key(_ t: Transaction) -> String { t.counterpartName.lowercased().filter { $0.isLetter } }
        // Recurring = fixed-cost-like: in ≥ 2 of the last 3 periods, at most one payment per
        // period, amounts within ±25 % of their median (groceries every week do not qualify).
        var seen: [String: [Int]] = [:]
        var multiple: Set<String> = []
        for past in history {
            var inPeriod: [String: (sum: Int, count: Int)] = [:]
            for t in actual where t.amountCents < 0 && past.contains(t.effectiveDate) {
                let k = key(t)
                inPeriod[k] = ((inPeriod[k]?.sum ?? 0) - t.amountCents, (inPeriod[k]?.count ?? 0) + 1)
            }
            for (k, v) in inPeriod {
                seen[k, default: []].append(v.sum)
                if v.count > 1 { multiple.insert(k) }
            }
        }
        let recurringKeys = Set(seen.filter { k, values in
            guard !k.isEmpty, values.count >= 2, !multiple.contains(k) else { return false }
            let median = Double(values.sorted()[values.count / 2])
            return values.allSatisfy { abs(Double($0) - median) <= median * 0.25 }
        }.keys)
        let alreadyThisPeriod = Set(current.filter { $0.amountCents < 0 }.map(key))
        let plannedKeys = Set(planned.map(key))
        let expectedRecurring = recurringKeys.subtracting(alreadyThisPeriod).subtracting(plannedKeys).reduce(0) { sum, k in
            let values = (seen[k] ?? []).sorted()
            return sum + (values.isEmpty ? 0 : values[values.count / 2])
        }

        // Variable pace: everything but recurring counterparts.
        let daysTotal = range.lowerBound.days(to: range.upperBound) + 1
        let elapsed = range.lowerBound.days(to: today) + 1
        let daysLeft = max(0, daysTotal - elapsed)
        // Days the data covers in this period, and the days still to forecast after it.
        let covered = max(0, range.lowerBound.days(to: asOf) + 1)
        let unknownDays = max(0, daysTotal - covered)
        let completeHistory = history.filter { past in actual.contains { $0.effectiveDate <= past.lowerBound } }
        let paceCentsPerDay: Double
        if !completeHistory.isEmpty {
            let days = completeHistory.reduce(0) { $0 + $1.lowerBound.days(to: $1.upperBound) + 1 }
            let variable = completeHistory.reduce(0) { sum, past in
                sum + spending(actual.filter { past.contains($0.effectiveDate) && !recurringKeys.contains(key($0)) })
            }
            paceCentsPerDay = days > 0 ? Double(max(0, variable)) / Double(days) : 0
        } else {
            let variable = spending(current.filter { !recurringKeys.contains(key($0)) })
            paceCentsPerDay = covered > 0 ? Double(max(0, variable)) / Double(covered) : 0
        }

        return BudgetStatus(
            budget: budget,
            range: range,
            spentCents: spent,
            plannedCents: plannedCents,
            expectedRecurringCents: expectedRecurring,
            expectedVariableCents: Int((paceCentsPerDay * Double(unknownDays)).rounded()),
            daysLeft: daysLeft,
            daysTotal: daysTotal,
            dataAsOf: asOf
        )
    }
}
