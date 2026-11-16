import Foundation
import MFNCore

/// Complete fake banking world: 5 banks, 11 accounts, ~1,500 transactions over 18 months.
///
/// Covers every state the UI has to render: booked, pending, planned and cancelled
/// transactions, foreign-currency card payments, open and closed credit-card periods,
/// pockets without IBAN, depots with fractional shares. All data is invented; IBANs use the
/// invalid check digits `00` so they can never be mistaken for real ones.
public struct MockDataset: Sendable {
    public let today: BankDay
    public let now: Date
    public let connections: [Connection]
    public let accounts: [Account]
    /// State as the bank reports it today.
    public let transactions: [AccountID: [Transaction]]
    /// The same world a few days later: every pending transaction is booked (with the longer
    /// merchant text banks use for final bookings). Used to test pending → booked merging.
    public let transactionsAfterBooking: [AccountID: [Transaction]]
    public let cardStatements: [AccountID: [CardStatement]]
    public let securities: [AccountID: [SecurityPosition]]
    let openingBalances: [AccountID: Int]
    let overdraftCents: [AccountID: Int]

    public static func demo(today: BankDay = .today, now: Date = Date(), seed: UInt64 = 42) -> MockDataset {
        var generator = MockGenerator(seed: seed, today: today, now: now)
        return generator.make()
    }

    public var allTransactions: [Transaction] {
        transactions.values.flatMap { $0 }
    }

    public func accounts(of connection: ConnectionID) -> [Account] {
        accounts.filter { $0.connectionID == connection }
    }

    public func balance(for accountID: AccountID, afterBooking: Bool = false) -> Balance {
        let list = (afterBooking ? transactionsAfterBooking : transactions)[accountID] ?? []
        let account = accounts.first { $0.id == accountID }
        if account?.type == .depot {
            let value = (securities[accountID] ?? []).reduce(0) { $0 + $1.valueCents }
            return Balance(bookedCents: value, availableCents: nil, asOf: now)
        }
        let booked = (openingBalances[accountID] ?? 0) + list.filter { $0.status == .booked }.reduce(0) { $0 + $1.amountCents }
        let pending = list.filter { $0.status == .pending }.reduce(0) { $0 + $1.amountCents }
        let headroom = account?.creditLimitCents ?? overdraftCents[accountID] ?? 0
        return Balance(bookedCents: booked, availableCents: booked + pending + headroom, asOf: now)
    }
}

/// Well-known account IDs of the demo world, handy for tests and previews.
public enum MockAccounts {
    public static let ingGiro: AccountID = "mock-ing-giro"
    public static let ingExtra: AccountID = "mock-ing-extra"
    public static let dkbGiro: AccountID = "mock-dkb-giro"
    public static let dkbVisa: AccountID = "mock-dkb-visa"
    public static let dkbDepot: AccountID = "mock-dkb-depot"
    public static let trCash: AccountID = "mock-tr-cash"
    public static let trDepot: AccountID = "mock-tr-depot"
    public static let c24Giro: AccountID = "mock-c24-giro"
    public static let c24Pocket: AccountID = "mock-c24-pocket"
    public static let easyVisa: AccountID = "mock-easybank-visa"
    public static let easyTagesgeld: AccountID = "mock-easybank-tagesgeld"
}

public enum MockConnections {
    public static let ing: ConnectionID = "mock-ing"
    public static let dkb: ConnectionID = "mock-dkb"
    public static let tradeRepublic: ConnectionID = "mock-tr"
    public static let c24: ConnectionID = "mock-c24"
    public static let easybank: ConnectionID = "mock-easybank"
}

extension MockDataset {
    /// Demo budgets (added once to the demo ledger), chosen against the generated spending so
    /// the sidebar shows different states: comfortable, tight and over budget.
    public static let demoBudgets: [AccountBudget] = [
        // Salary account: the month starts with the salary, not on the 1st.
        AccountBudget(accountID: MockAccounts.ingGiro, amountCents: 600_000, period: .monthly, startDay: 1,
                      anchor: AccountBudget.IncomeAnchor(toleranceDays: 3, counterpart: "Muster Technik")),
        // Credit card: spending runs ahead of the month, the forecast warns.
        AccountBudget(accountID: MockAccounts.dkbVisa, amountCents: 150_000, period: .monthly, startDay: 1),
        // Card account of Trade Republic: tight.
        AccountBudget(accountID: MockAccounts.trCash, amountCents: 50_000, period: .monthly, startDay: 1),
        // Everyday account: a weekly allowance from Monday.
        AccountBudget(accountID: MockAccounts.c24Giro, amountCents: 15_000, period: .weekly, startDay: 1),
        // Second card: comfortable.
        AccountBudget(accountID: MockAccounts.easyVisa, amountCents: 40_000, period: .monthly, startDay: 1),
    ]
}

extension MockDataset {
    /// Demo planned payments (added once to the demo ledger): one soon, one months ahead, so the
    /// forecast panel has something to show.
    public static func demoPlannedItems(today: BankDay = .today) -> [PlannedItem] {
        [
            PlannedItem(accountID: MockAccounts.ingGiro, day: today.adding(days: 19), amountCents: -118_000, title: "Autoreparatur"),
            PlannedItem(accountID: MockAccounts.ingGiro, day: today.adding(days: 68), amountCents: -240_000, title: "Urlaub Anzahlung"),
        ]
    }
}

extension MockDataset {
    /// Demo depot history (added once to the demo ledger): one point per day for the last
    /// 18 months up to yesterday, a deterministic random walk that ends near today's value. The
    /// FinTS depot (DKB) has purchase values that grow with a monthly savings plan; Trade
    /// Republic has none, like the real connector so far.
    public func demoDepotHistory(seed: UInt64 = 7) -> [DepotValuePoint] {
        var rng = seed
        func noise() -> Double {
            // xorshift64*, deterministic across launches.
            rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
            return Double((rng &* 2_685_821_657_736_338_717) >> 11) / Double(1 << 53) - 0.5
        }
        let days = 548
        var points: [DepotValuePoint] = []
        for account in accounts where account.type == .depot {
            let positions = securities[account.id] ?? []
            let today = Double(positions.reduce(0) { $0 + $1.valueCents })
            let purchaseToday = positions.allSatisfy { $0.purchaseValueCents != nil } && !positions.isEmpty
                ? Double(positions.reduce(0) { $0 + ($1.purchaseValueCents ?? 0) }) : nil
            // Walk backwards from today: drift of about +8 % a year plus daily noise.
            var factor = 1.0
            var series: [(BankDay, Double)] = []
            for back in 1...days {
                factor /= 1 + 0.08 / 365 + noise() * 0.018
                series.append((self.today.adding(days: -back), factor))
            }
            for (day, factor) in series.reversed() {
                let monthsBack = Double((self.today.year - day.year) * 12 + self.today.month - day.month)
                let purchase = purchaseToday.map { $0 * max(0.35, 1 - monthsBack / 30) }
                // Demo only: the random walk runs in Double, rounded once to whole cents.
                points.append(DepotValuePoint(accountID: account.id, day: day, valueCents: Int((today * factor).rounded()),
                                              purchaseCents: purchase.map { Int($0.rounded()) }))
            }
        }
        return points
    }
}
