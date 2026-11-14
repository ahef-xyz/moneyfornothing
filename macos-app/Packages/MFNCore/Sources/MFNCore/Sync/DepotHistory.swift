import Foundation

/// One day of a depot: value and purchase value, recorded with every sync that fetched the
/// positions. The banks deliver no history (FinTS MT535 is a snapshot), so the curve starts with
/// the first sync after this was introduced. The last sync of a day wins.
public struct DepotValuePoint: Sendable, Hashable, Identifiable {
    public let accountID: AccountID
    public var day: BankDay
    /// Depot value as the bank reports it (the depot balance).
    public var valueCents: Int
    /// Sum of the purchase values; `nil` unless every position has a purchase price in `currency`.
    public var purchaseCents: Int?
    public var currency: String

    public var id: BankDay { day }

    public init(accountID: AccountID, day: BankDay, valueCents: Int, purchaseCents: Int?, currency: String = "EUR") {
        self.accountID = accountID
        self.day = day
        self.valueCents = valueCents
        self.purchaseCents = purchaseCents
        self.currency = currency
    }

    /// The point a sync records: `nil` if the update carries no positions (not a depot).
    public static func recorded(from update: AccountUpdate) -> DepotValuePoint? {
        guard let positions = update.securities else { return nil }
        let currency = update.balance.currency
        let purchases = positions.map { $0.currency == currency ? $0.purchaseValueCents : nil }
        let purchase: Int? = positions.isEmpty || purchases.contains(nil) ? nil : purchases.reduce(0) { $0 + ($1 ?? 0) }
        return DepotValuePoint(accountID: update.accountID, day: BankDay(update.balance.asOf),
                               valueCents: update.balance.bookedCents, purchaseCents: purchase, currency: currency)
    }
}

extension LedgerSnapshot {
    /// Upserts by day and keeps the history of the account sorted, oldest first. A sync records
    /// today, so the common case appends or replaces the last point without sorting.
    public mutating func record(_ point: DepotValuePoint) {
        var points = depotHistory[point.accountID] ?? []
        if let last = points.last, last.day == point.day {
            points[points.count - 1] = point
        } else if points.last.map({ $0.day < point.day }) ?? true {
            points.append(point)
        } else {
            points.removeAll { $0.day == point.day }
            points.append(point)
            points.sort { $0.day < $1.day }
        }
        depotHistory[point.accountID] = points
    }

    /// Many points at once (demo data, merge): one merge and one sort per account; a later point
    /// of the same day wins.
    public mutating func record(_ points: [DepotValuePoint]) {
        for (account, incoming) in Dictionary(grouping: points, by: \.accountID) {
            var byDay = Dictionary((depotHistory[account] ?? []).map { ($0.day, $0) }, uniquingKeysWith: { _, new in new })
            for point in incoming { byDay[point.day] = point }
            depotHistory[account] = byDay.values.sorted { $0.day < $1.day }
        }
    }
}
