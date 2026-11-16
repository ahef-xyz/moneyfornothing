import Foundation

/// A one-off payment the user expects ("Autoreparatur im Januar"): a note for the forecast, never
/// an order. MFN stays read-only; nothing here reaches a bank.
///
/// Kept apart from `Transaction`: transactions belong to the connectors (fingerprint, merge on
/// sync), these belong to the user.
public struct PlannedItem: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var accountID: AccountID
    /// Day the money is expected to move.
    public var day: BankDay
    /// Negative = expense, positive = income. An estimate.
    public var amountCents: Int
    public var title: String
    public var createdAt: Date
    /// Bookings the user said are not this item ("Nein, kommt noch"): never suggested again.
    public var ignoredMatches: Set<TransactionID>

    public init(id: UUID = UUID(), accountID: AccountID, day: BankDay, amountCents: Int, title: String,
                createdAt: Date = Date(), ignoredMatches: Set<TransactionID> = []) {
        self.id = id
        self.accountID = accountID
        self.day = day
        self.amountCents = amountCents
        self.title = title
        self.createdAt = createdAt
        self.ignoredMatches = ignoredMatches
    }
}

/// One expected movement of an account's balance.
public struct ForecastEvent: Hashable, Sendable, Identifiable {
    public enum Source: Hashable, Sendable {
        /// Announced by the bank (`TransactionStatus.planned`: standing order, announced debit).
        case bank(TransactionID)
        /// Entered by the user (`PlannedItem`).
        case manual(UUID)
        /// Estimated from a monthly counterpart (`RecurringSeries`), `occurrence` months after its last booking.
        case recurring(key: String, occurrence: Int)
    }

    public var source: Source
    /// Day it counts on: overdue ones count as due today.
    public var day: BankDay
    /// Day it was due.
    public var dueDay: BankDay
    public var cents: Int
    public var title: String

    public init(source: Source, day: BankDay, dueDay: BankDay, cents: Int, title: String) {
        self.source = source
        self.day = day
        self.dueDay = dueDay
        self.cents = cents
        self.title = title
    }

    public var id: String {
        switch source {
        case let .bank(id): "bank:\(id.rawValue)"
        case let .manual(id): "manual:\(id.uuidString)"
        case let .recurring(key, occurrence): "recurring:\(key):\(occurrence)"
        }
    }

    /// Estimated by MFN, not known: nobody announced or entered it.
    public var isEstimate: Bool {
        if case .recurring = source { return true }
        return false
    }

    public var isOverdue: Bool { dueDay < day }
}

/// A counterpart that books about the same amount once a month.
public struct RecurringSeries: Hashable, Sendable {
    /// Unique per series (a counterpart can have several, e.g. two contracts with one insurer).
    public var key: String
    /// Counterpart name reduced to its letters, for comparing with other bookings.
    public var counterpartKey: String
    public var title: String
    /// Median amount with sign.
    public var cents: Int
    /// Newest booking.
    public var last: BankDay
}

/// What is expected on one account from today on.
public struct AccountForecast: Hashable, Sendable {
    /// Oldest first; on the same day incoming before outgoing (a salary on the rent day counts first).
    public var events: [ForecastEvent]
    /// Planned items a booking probably fulfilled already: not in `events` (the money is gone
    /// from the balance) until the user says the booking is something else.
    public var matches: [UUID: TransactionID]
    /// Recurring estimates are complete up to this day.
    public var until: BankDay

    public init(events: [ForecastEvent] = [], matches: [UUID: TransactionID] = [:], until: BankDay) {
        self.events = events
        self.matches = matches
        self.until = until
    }
}

/// A balance walked through forecast events.
public struct ForecastPath: Hashable, Sendable {
    public struct Step: Hashable, Sendable {
        public var day: BankDay
        /// Balance after the event.
        public var cents: Int
        public var event: ForecastEvent
    }

    public var startCents: Int
    public var steps: [Step]
    public var endCents: Int
    /// Lowest balance on the way (the start counts) and its day.
    public var lowestCents: Int
    public var lowestDay: BankDay
    /// First day below zero.
    public var firstNegativeDay: BankDay?
}

/// The forecast of an account balance (pure, synchronous): what the bank announced, what the user
/// planned and what books every month anyway. The last part is what makes a date months ahead
/// meaningful without the user planning their whole cash flow: salary and rent are estimated.
public enum BalanceForecast {
    /// Bank-announced payments overdue for longer are stale and left out.
    public static let overdueDays = 7
    /// A booking within this many days of an announced payment, same amount and counterpart, is
    /// that payment already executed.
    public static let matchDays = 3
    /// Recurring series are read from this many days of history.
    public static let historyDays = 200
    /// Bookings a month one counterpart can have and still be read as contracts with one company.
    public static let maxSeriesPerCounterpart = 3
    /// A booking this close to a planned item (days, amount within one part in
    /// `itemMatchDivisor`, i.e. 25 %) may be the item.
    public static let itemMatchDays = 7
    public static let itemMatchDivisor = 4

    public static func counterpartKey(_ name: String) -> String {
        name.lowercased().filter(\.isLetter)
    }

    /// A booking with its counterpart key, computed once (the forecast compares it many times).
    private struct Keyed {
        let booking: Transaction
        let key: String
        var signedKey: String { (booking.amountCents > 0 ? "+" : "-") + key }
    }

    /// - Parameters:
    ///   - planned: the account's `.planned` transactions.
    ///   - actual: the account's pending and booked transactions of at least the last `historyDays` days.
    ///   - items: the account's planned items.
    ///   - until: last day recurring estimates are made for.
    public static func forecast(planned: [Transaction], actual: [Transaction], items: [PlannedItem],
                                today: BankDay, until: BankDay) -> AccountForecast {
        var events: [ForecastEvent] = []
        let overdueFrom = today.adding(days: -overdueDays)
        let keyed = actual.map { Keyed(booking: $0, key: counterpartKey($0.counterpartName)) }

        // Announced by the bank, unless already executed. A booking executes one payment only:
        // two equal standing orders need two bookings.
        var announced: [Transaction] = []
        if !planned.isEmpty {
            let byAmount = Dictionary(grouping: keyed, by: \.booking.amountCents)
            var executing: Set<TransactionID> = []
            for payment in planned.sorted(by: { ($0.valueDate, $0.id.rawValue) < ($1.valueDate, $1.id.rawValue) }) where payment.valueDate >= overdueFrom {
                let key = counterpartKey(payment.counterpartName)
                let execution = (byAmount[payment.amountCents] ?? []).first { candidate in
                    !executing.contains(candidate.booking.id)
                        && abs(candidate.booking.effectiveDate.days(to: payment.valueDate)) <= matchDays
                        && (key.isEmpty || candidate.key == key)
                }
                if let execution {
                    executing.insert(execution.booking.id)
                    continue
                }
                announced.append(payment)
                events.append(ForecastEvent(source: .bank(payment.id), day: max(payment.valueDate, today), dueDay: payment.valueDate,
                                            cents: payment.amountCents, title: payment.counterpartName))
            }
        }

        // Monthly counterparts, unless the bank announced that month's payment itself.
        let series = recurring(keyed, today: today)
        let announcedKeys = announced.map { counterpartKey($0.counterpartName) }
        for one in series {
            for occurrence in 1...24 {
                let due = one.last.adding(months: occurrence)
                if due > until { break }
                if due < overdueFrom { continue }
                let isAnnounced = announced.indices.contains { index in
                    (announced[index].amountCents > 0) == (one.cents > 0)
                        && announcedKeys[index] == one.counterpartKey
                        && abs(announced[index].valueDate.days(to: due)) <= 10
                }
                if isAnnounced { continue }
                events.append(ForecastEvent(source: .recurring(key: one.key, occurrence: occurrence), day: max(due, today), dueDay: due,
                                            cents: one.cents, title: one.title))
            }
        }

        // The user's items, unless a booking looks like one of them.
        let recurringCounterparts = Set(series.map { ($0.cents > 0 ? "+" : "-") + $0.counterpartKey })
        var matches: [UUID: TransactionID] = [:]
        var used: Set<TransactionID> = []
        for item in items.sorted(by: { ($0.day, $0.id.uuidString) < ($1.day, $1.id.uuidString) }) {
            let created = BankDay(item.createdAt)
            let candidate = keyed.filter { candidate in
                let booking = candidate.booking
                return booking.effectiveDate >= created
                    && abs(booking.effectiveDate.days(to: item.day)) <= itemMatchDays
                    && (booking.amountCents > 0) == (item.amountCents > 0)
                    && abs(booking.amountCents - item.amountCents) * itemMatchDivisor <= abs(item.amountCents)
                    && !item.ignoredMatches.contains(booking.id)
                    && !used.contains(booking.id)
                    && !recurringCounterparts.contains(candidate.signedKey)
            }
            .map(\.booking)
            .min { (abs($0.amountCents - item.amountCents), $0.id.rawValue) < (abs($1.amountCents - item.amountCents), $1.id.rawValue) }
            if let candidate {
                matches[item.id] = candidate.id
                used.insert(candidate.id)
            } else {
                events.append(ForecastEvent(source: .manual(item.id), day: max(item.day, today), dueDay: item.day,
                                            cents: item.amountCents, title: item.title))
            }
        }

        events.sort { ($0.day, -$0.cents, $0.id) < ($1.day, -$1.cents, $1.id) }
        return AccountForecast(events: events, matches: matches, until: until)
    }

    /// Monthly counterparts: at least three bookings, 25 to 35 days apart, amounts within ± 25 %
    /// of their median, the newest at most 40 days old. Groceries (several a month) and ended
    /// contracts do not qualify. Bookings of one counterpart with exactly the same amount are
    /// tried as their own series first (two contracts with one insurer), up to
    /// `maxSeriesPerCounterpart`.
    public static func recurring(actual: [Transaction], today: BankDay) -> [RecurringSeries] {
        recurring(actual.map { Keyed(booking: $0, key: counterpartKey($0.counterpartName)) }, today: today)
    }

    private static func recurring(_ actual: [Keyed], today: BankDay) -> [RecurringSeries] {
        let from = today.adding(days: -historyDays)
        var groups: [String: [Transaction]] = [:]
        for candidate in actual {
            let booking = candidate.booking
            guard booking.amountCents != 0, booking.effectiveDate >= from, booking.effectiveDate <= today,
                  booking.status == .booked || booking.status == .pending, !candidate.key.isEmpty else { continue }
            groups[candidate.signedKey, default: []].append(booking)
        }
        var result: [RecurringSeries] = []
        for (key, list) in groups {
            var rest = list
            let byAmount = Dictionary(grouping: list, by: \.amountCents)
            if byAmount.count > 1 {
                // More bookings a month than a few contracts explain: a shop, even if it charges
                // the same price every week.
                let months = Set(list.map { $0.effectiveDate.year * 12 + $0.effectiveDate.month }).count
                if list.count > maxSeriesPerCounterpart * months { continue }
                for (amount, same) in byAmount {
                    guard let found = series(same, key: "\(key):\(amount)", today: today) else { continue }
                    result.append(found)
                    rest.removeAll { $0.amountCents == amount }
                }
            }
            if let found = series(rest, key: key, today: today) { result.append(found) }
        }
        return result.sorted { $0.key < $1.key }
    }

    private static func series(_ list: [Transaction], key: String, today: BankDay) -> RecurringSeries? {
        guard list.count >= 3 else { return nil }
        let sorted = list.sorted { $0.effectiveDate < $1.effectiveDate }
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            guard (25...35).contains(earlier.effectiveDate.days(to: later.effectiveDate)) else { return nil }
        }
        guard let last = sorted.last, last.effectiveDate.days(to: today) <= 40 else { return nil }
        let amounts = sorted.map { abs($0.amountCents) }.sorted()
        let median = amounts[amounts.count / 2]
        guard amounts.allSatisfy({ abs($0 - median) * 4 <= median }) else { return nil }
        return RecurringSeries(key: key, counterpartKey: counterpartKey(last.counterpartName), title: last.counterpartName,
                               cents: last.amountCents > 0 ? median : -median, last: last.effectiveDate)
    }

    /// Walks `start` through the events up to `until` (they are sorted, see `AccountForecast.events`).
    public static func path(start: Int, events: [ForecastEvent], today: BankDay, until: BankDay) -> ForecastPath {
        var running = start
        var path = ForecastPath(startCents: start, steps: [], endCents: start, lowestCents: start, lowestDay: today,
                                firstNegativeDay: start < 0 ? today : nil)
        for event in events where event.day <= until {
            running += event.cents
            path.steps.append(.init(day: event.day, cents: running, event: event))
            if running < path.lowestCents {
                path.lowestCents = running
                path.lowestDay = event.day
            }
            if running < 0, path.firstNegativeDay == nil { path.firstNegativeDay = event.day }
        }
        path.endCents = running
        return path
    }

    /// First day from today on which spending `amountCents` (positive) never takes the balance
    /// below zero up to `until`; `nil` if there is none. Only days on which the balance changes
    /// (and today) can be the first.
    public static func earliestDay(spending amountCents: Int, start: Int, events: [ForecastEvent],
                                   today: BankDay, until: BankDay) -> BankDay? {
        // End-of-day balances, one entry per day with events, today first.
        var days: [(day: BankDay, cents: Int)] = [(today, start)]
        var running = start
        for event in events where event.day <= until {
            running += event.cents
            if days[days.count - 1].day == event.day {
                days[days.count - 1].cents = running
            } else {
                days.append((event.day, running))
            }
        }
        // Lowest balance from each day on.
        var lowestAfter = Array(repeating: 0, count: days.count)
        var lowest = Int.max
        for index in days.indices.reversed() {
            lowest = min(lowest, days[index].cents)
            lowestAfter[index] = lowest
        }
        return days.indices.first { lowestAfter[$0] - amountCents >= 0 }.map { days[$0].day }
    }
}
