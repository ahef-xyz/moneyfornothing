import Foundation

/// A payment that comes back at a fixed rhythm: a subscription, rent, an insurance, a salary.
/// Read from the bookings (`Subscriptions.detect`); the user can change one or add an own one
/// (`RecurringEntry`, `Subscriptions.applying`).
public struct RecurringPayment: Hashable, Sendable, Identifiable {
    public enum Cadence: Int, Sendable, CaseIterable, Codable {
        case monthly = 1
        case quarterly = 3
        case halfYearly = 6
        case yearly = 12

        public var months: Int { rawValue }

        /// Days between two bookings of this rhythm (weekends and holidays move debits).
        var gap: ClosedRange<Int> {
            switch self {
            case .monthly: 25...35
            case .quarterly: 80...100
            case .halfYearly: 170...195
            case .yearly: 350...380
            }
        }

        /// Bookings needed before it counts. Long rhythms are rare enough for two to tell.
        var minimumCount: Int {
            switch self {
            case .monthly, .quarterly: 3
            case .halfYearly, .yearly: 2
            }
        }

        /// Days a payment may be late before the series reads as ended.
        var graceDays: Int {
            switch self {
            case .monthly: 10
            case .quarterly: 15
            case .halfYearly, .yearly: 30
            }
        }
    }

    /// The amount stepped from one fixed price to another.
    public struct PriceChange: Hashable, Sendable {
        /// Amount before, with sign.
        public var previousCents: Int
        /// First booking with the new amount.
        public var since: BankDay
    }

    /// Stable while the series lives: account, counterpart, direction (and the amount, where one
    /// counterpart has several contracts).
    public var id: String
    public var accountID: AccountID
    /// Counterpart name of the newest booking.
    public var title: String
    public var counterpartKey: String
    public var cadence: Cadence
    /// Newest amount, with sign.
    public var cents: Int
    public var last: BankDay
    /// When the next one is due if the rhythm holds.
    public var next: BankDay
    /// Bookings in the rhythm.
    public var count: Int
    /// Category of the newest booking.
    public var categoryID: CategoryID?
    /// Only for a while after the change (`Subscriptions.priceChangeDays`).
    public var priceChange: PriceChange?
    /// The next payment is overdue beyond the grace period: probably cancelled.
    public var isEnded: Bool
    /// Oldest first.
    public var transactionIDs: [TransactionID]
    /// The user's entry behind this payment: an own one, or the change of a detected one.
    public var entryID: UUID?
    /// What the bookings said before the user changed it. `nil`: unchanged, or an own entry.
    public var detected: Detected?

    /// A detected payment as it was before the user's change.
    public struct Detected: Hashable, Sendable {
        public var title: String
        public var cents: Int
        public var cadence: Cadence

        public init(title: String, cents: Int, cadence: Cadence) {
            self.title = title
            self.cents = cents
            self.cadence = cadence
        }
    }

    /// Entered by the user, not read from bookings.
    public var isOwn: Bool { entryID != nil && detected == nil }
    public var isEdited: Bool { detected != nil }

    public var isIncome: Bool { cents > 0 }
    public var yearlyCents: Int { cents * 12 / cadence.months }
    /// Per month, rounded to the cent (a yearly 119,88 € is 9,99 €).
    public var monthlyCents: Int {
        let months = cadence.months
        return (cents >= 0 ? cents + months / 2 : cents - months / 2) / months
    }
}

/// What the user entered about a recurring payment: an own one (`seriesID == nil`), or other
/// values for a detected one. Removing it brings the detected values back.
public struct RecurringEntry: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// `RecurringPayment.id` of the detected payment this changes.
    public var seriesID: String?
    public var accountID: AccountID
    public var title: String
    /// Negative = expense, positive = income.
    public var amountCents: Int
    public var cadence: RecurringPayment.Cadence
    /// Own entries: a day it is due; the rhythm continues from there in both directions.
    public var anchorDay: BankDay?
    public var createdAt: Date

    public init(id: UUID = UUID(), seriesID: String? = nil, accountID: AccountID, title: String, amountCents: Int,
                cadence: RecurringPayment.Cadence, anchorDay: BankDay? = nil, createdAt: Date = Date()) {
        self.id = id
        self.seriesID = seriesID
        self.accountID = accountID
        self.title = title
        self.amountCents = amountCents
        self.cadence = cadence
        self.anchorDay = anchorDay
        self.createdAt = createdAt
    }
}

/// Finds recurring payments in an account's bookings (pure, synchronous).
///
/// Wider than `BalanceForecast.recurring`, which only wants what is safe to project onto a
/// balance: this one reads two years, knows quarterly to yearly rhythms, keeps a series through a
/// price change and still lists one that just ended.
public enum Subscriptions {
    /// Two yearly payments need more than a year of history.
    public static let historyDays = 800
    /// A price change is pointed out for this long.
    public static let priceChangeDays = 120
    /// Both halves of a transfer between two banks book within this many days.
    public static let transferDays = 2
    /// Transfers between the user's own accounts are not costs.
    public static let excludedCategories: Set<CategoryID> = BudgetForecast.excludedCategories

    /// - Parameters:
    ///   - transactions: any accounts, any order; only booked ones in EUR count.
    ///   - ownIBANs: IBANs of the user's accounts (any spacing or case). Bookings from or to one
    ///     of them are transfers, also where the other account's half is missing.
    /// - Returns: Expenses first (largest per month first), then income, ended ones last.
    public static func detect(transactions: [Transaction], ownIBANs: Set<String> = [], today: BankDay) -> [RecurringPayment] {
        let from = today.adding(days: -historyDays)
        let own = Set(ownIBANs.map(normalized))
        var groups: [String: [Transaction]] = [:]
        // Every booking by amount: the other half of a transfer between two of the user's accounts
        // is the same sum with the opposite sign in another account.
        var byAmount: [Int: [(day: BankDay, account: AccountID)]] = [:]
        for booking in transactions {
            guard booking.status == .booked, booking.currency == "EUR", booking.amountCents != 0,
                  booking.effectiveDate >= from, booking.effectiveDate <= today else { continue }
            byAmount[booking.amountCents, default: []].append((booking.effectiveDate, booking.accountID))
            guard !excludedCategories.contains(booking.categoryID ?? "") else { continue }
            if !own.isEmpty, let iban = booking.counterpartIBAN, own.contains(normalized(iban)) { continue }
            let key = BalanceForecast.counterpartKey(booking.counterpartName)
            guard !key.isEmpty else { continue }
            groups["\(booking.accountID.rawValue)|\(booking.amountCents > 0 ? "+" : "-")\(key)", default: []].append(booking)
        }
        func isMirrored(_ booking: Transaction) -> Bool {
            byAmount[-booking.amountCents]?.contains {
                $0.account != booking.accountID && abs($0.day.days(to: booking.effectiveDate)) <= transferDays
            } ?? false
        }
        var result: [RecurringPayment] = []
        func add(_ sorted: [Transaction], id: String) -> Bool {
            guard let found = payment(sorted, id: id, today: today) else { return false }
            // A standing order to the user's own savings account is found, but it is not a cost:
            // left out when most of its bookings arrive in another account (also without a
            // category saying so).
            let bookings = Set(found.transactionIDs)
            let mirrored = sorted.count { bookings.contains($0.id) && isMirrored($0) }
            if mirrored * 3 < found.count * 2 { result.append(found) }
            return true
        }
        for (id, list) in groups {
            let sorted = list.sorted { ($0.effectiveDate, $0.id.rawValue) < ($1.effectiveDate, $1.id.rawValue) }
            if add(sorted, id: id) { continue }
            // Several contracts with one company (two insurances, two phone plans): each keeps
            // its own exact amount.
            let amounts = Dictionary(grouping: sorted, by: \.amountCents)
            guard amounts.count > 1 else { continue }
            for (amount, same) in amounts { _ = add(same, id: "\(id)|\(amount)") }
        }
        return ordered(result)
    }

    private static func ordered(_ payments: [RecurringPayment]) -> [RecurringPayment] {
        payments.sorted { lhs, rhs in
            if lhs.isEnded != rhs.isEnded { return !lhs.isEnded }
            if lhs.isIncome != rhs.isIncome { return !lhs.isIncome }
            if abs(lhs.monthlyCents) != abs(rhs.monthlyCents) { return abs(lhs.monthlyCents) > abs(rhs.monthlyCents) }
            return lhs.id < rhs.id
        }
    }

    /// The detected payments with the user's entries: changed ones carry the user's name, amount
    /// and rhythm (and remember the detected ones), own entries are added. An entry for a payment
    /// that is no longer detected does nothing.
    public static func applying(_ entries: [RecurringEntry], to detected: [RecurringPayment], today: BankDay) -> [RecurringPayment] {
        guard !entries.isEmpty else { return detected }
        let changes = Dictionary(entries.compactMap { entry in entry.seriesID.map { ($0, entry) } }, uniquingKeysWith: { first, _ in first })
        var result = detected.map { payment -> RecurringPayment in
            guard let entry = changes[payment.id] else { return payment }
            var changed = payment
            changed.entryID = entry.id
            changed.detected = RecurringPayment.Detected(title: payment.title, cents: payment.cents, cadence: payment.cadence)
            changed.title = entry.title
            changed.cents = entry.amountCents
            if entry.amountCents != payment.cents { changed.priceChange = nil }
            if entry.cadence != payment.cadence {
                changed.cadence = entry.cadence
                changed.next = payment.last.adding(months: entry.cadence.months)
                changed.isEnded = changed.next.days(to: today) > entry.cadence.graceDays
            }
            return changed
        }
        for entry in entries where entry.seriesID == nil {
            let next = nextDay(from: entry.anchorDay ?? BankDay(entry.createdAt), every: entry.cadence, today: today)
            result.append(RecurringPayment(
                id: "own:\(entry.id.uuidString)", accountID: entry.accountID, title: entry.title,
                counterpartKey: BalanceForecast.counterpartKey(entry.title), cadence: entry.cadence,
                cents: entry.amountCents, last: next.adding(months: -entry.cadence.months), next: next, count: 0,
                categoryID: nil, priceChange: nil, isEnded: false, transactionIDs: [], entryID: entry.id
            ))
        }
        return ordered(result)
    }

    /// First day on or after `today` in the rhythm through `anchor`. Counted from the anchor each
    /// time, so a 31st stays a 31st where the month has one.
    static func nextDay(from anchor: BankDay, every cadence: RecurringPayment.Cadence, today: BankDay) -> BankDay {
        let months = (today.year - anchor.year) * 12 + today.month - anchor.month
        // Largest step count at or before today's month, then forward until it is not in the past.
        var steps = Int((Double(months) / Double(cadence.months)).rounded(.down))
        var day = anchor.adding(months: steps * cadence.months)
        while day < today {
            steps += 1
            day = anchor.adding(months: steps * cadence.months)
        }
        return day
    }

    private static func normalized(_ iban: String) -> String {
        iban.filter { !$0.isWhitespace }.uppercased()
    }

    /// `sorted`: one counterpart, one direction, oldest first.
    private static func payment(_ sorted: [Transaction], id: String, today: BankDay) -> RecurringPayment? {
        guard let last = sorted.last else { return nil }
        for cadence in RecurringPayment.Cadence.allCases {
            // The newest bookings that keep the rhythm: an old gap (a paused contract) does not
            // spoil what has been regular since.
            var start = sorted.count - 1
            while start > 0, cadence.gap.contains(sorted[start - 1].effectiveDate.days(to: sorted[start].effectiveDate)) {
                start -= 1
            }
            let run = Array(sorted[start...])
            guard run.count >= cadence.minimumCount else { continue }
            let change = priceChange(in: run)
            guard change != nil || isSteady(run) else { continue }

            let next = last.effectiveDate.adding(months: cadence.months)
            let age = last.effectiveDate.days(to: today)
            // Long gone: not even worth listing as ended.
            guard age <= max(120, cadence.months * 45) else { return nil }
            let recentChange = change.flatMap { $0.since.days(to: today) <= priceChangeDays ? $0 : nil }
            return RecurringPayment(
                id: id, accountID: last.accountID, title: last.counterpartName,
                counterpartKey: BalanceForecast.counterpartKey(last.counterpartName), cadence: cadence,
                cents: last.amountCents, last: last.effectiveDate, next: next, count: run.count,
                categoryID: last.categoryID, priceChange: recentChange,
                isEnded: next.days(to: today) > cadence.graceDays, transactionIDs: run.map(\.id)
            )
        }
        return nil
    }

    /// One fixed price, then another: at least two equal bookings before the step, only equal
    /// ones after it. An electricity bill that differs every month has no price to change.
    private static func priceChange(in run: [Transaction]) -> RecurringPayment.PriceChange? {
        guard let step = run.indices.dropFirst().last(where: { run[$0].amountCents != run[$0 - 1].amountCents }) else { return nil }
        let before = run[..<step]
        let after = run[step...]
        guard before.count >= 2, let old = before.last?.amountCents, let new = after.first?.amountCents,
              before.suffix(2).allSatisfy({ $0.amountCents == old }), after.allSatisfy({ $0.amountCents == new }) else { return nil }
        return RecurringPayment.PriceChange(previousCents: old, since: run[step].effectiveDate)
    }

    /// The newest amounts (up to six) lie within ± 25 % of their median: a contract, not a shop
    /// visited once a month.
    private static func isSteady(_ run: [Transaction]) -> Bool {
        let amounts = run.suffix(6).map { abs($0.amountCents) }.sorted()
        let median = amounts[amounts.count / 2]
        return amounts.allSatisfy { abs($0 - median) * 4 <= median }
    }
}
