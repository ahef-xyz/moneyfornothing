import Foundation

/// Merging two connections of the same bank, e.g. ING over web banking (`source`) into ING over
/// FinTS (`target`): the target keeps syncing, the source's history and the user's work
/// (categories, names, budgets) move over, the source goes away.
///
/// `plan` only reads the snapshot. It decides
/// - which source account belongs to which target account: same IBAN, else the only account of
///   that type on both sides (depots carry no IBAN). Never by name.
/// - which transactions are the same booking seen twice. Inside the target's window (its oldest
///   transaction onwards) source and target both hold the same bookings with different texts
///   (web display vs. MT940): same status, currency and amount, date at most `dateToleranceDays`
///   apart and the same counterparty (IBAN, or names where one is a prefix of the other).
///   Without a counterparty match a pair still counts if it is the only candidate on the exact
///   same day (`weak`), so the report shows how much rests on that. Candidates start
///   `dateToleranceDays` before the window: the web may date a booking a day earlier.
/// - what moves: every booked or cancelled source row without a twin, older history as well as
///   bookings inside the window that FinTS lacks (`sourceOnlyInWindow`, listed for checking).
///   Nothing booked is lost.
/// - what is dropped: unmatched pending and planned source rows. They are reservations and
///   orders of the web channel; on the target they would stay forever (`TransactionMerger` only
///   expires them inside a fetched window).
/// - the account names: each target account takes the name the user saw for its source (their
///   own rename, else the bank's name in the web banking).
///
/// `changes` turns a plan into writes; `LedgerStore.applyMerge` performs them and removes the
/// source in one database transaction, so a merge either happens completely or not at all.
public enum ConnectionMerge {
    /// Booking vs. value date and weekend shifts differ between the two channels.
    public static let dateToleranceDays = 2

    public struct AccountPair: Sendable, Equatable {
        public enum Reason: String, Sendable, Equatable {
            case iban
            case onlyOfType
        }

        public let source: Account
        public let target: Account
        public let reason: Reason
    }

    public struct TransactionPair: Sendable, Equatable {
        public let source: Transaction
        public let target: Transaction
        /// Only amount and date matched (the only candidate that day), not the counterparty.
        public let weak: Bool
    }

    public struct AccountPlan: Sendable, Equatable {
        public let pair: AccountPair
        /// Name for the target account (the source's displayed name), `nil` if it already shows it.
        public let newName: String?
        /// First day of the target's history; `nil` if the target has no transactions yet.
        public let windowStart: BankDay?
        public let matched: [TransactionPair]
        /// Booked and cancelled source rows before the window: they move to the target account.
        public let history: [Transaction]
        /// Booked source rows inside the window without a target twin: they move as well, but
        /// FinTS should have had them, so they are listed for checking. Should be (close to) empty.
        public let sourceOnlyInWindow: [Transaction]
        /// Target bookings without a source twin: new in the target, nothing to do.
        public let targetOnly: [Transaction]
        /// Unmatched pending and planned source rows: dropped with the source.
        public let dropped: [Transaction]

        /// Everything that moves to the target account.
        public var moving: [Transaction] { history + sourceOnlyInWindow }

        /// Matched pairs whose source has a category the target lacks (or a manual one).
        public var categoriesToCarry: Int {
            matched.count { Self.carriesCategory(from: $0.source, to: $0.target) }
        }

        public var weakMatches: Int { matched.count(where: \.weak) }

        static func carriesCategory(from source: Transaction, to target: Transaction) -> Bool {
            guard source.categoryID != nil else { return false }
            return target.categoryID == nil || (source.categorySource == .manual && target.categorySource != .manual)
        }
    }

    public struct Plan: Sendable, Equatable {
        public let source: ConnectionID
        public let target: ConnectionID
        public let accounts: [AccountPlan]
        public let unmatchedSourceAccounts: [Account]
        public let unmatchedTargetAccounts: [Account]

        public var isEmpty: Bool { accounts.isEmpty }
        /// Booked rows FinTS should have had (they move, but deserve a look).
        public var suspicious: Int { accounts.reduce(0) { $0 + $1.sourceOnlyInWindow.count } }
    }

    public enum PlanError: Error, Sendable, Equatable {
        case unknownConnection
        case sameConnection
        case differentBanks
    }

    public static func plan(_ snapshot: LedgerSnapshot, source: ConnectionID, target: ConnectionID) throws(PlanError) -> Plan {
        guard source != target else { throw .sameConnection }
        guard let from = snapshot.connections.first(where: { $0.id == source }),
              let to = snapshot.connections.first(where: { $0.id == target })
        else { throw .unknownConnection }
        guard from.connectorID == to.connectorID else { throw .differentBanks }

        let (pairs, restSource, restTarget) = pairAccounts(snapshot.accounts(of: source), snapshot.accounts(of: target))
        let involved = Set(pairs.flatMap { [$0.source.id, $0.target.id] })
        var byAccount: [AccountID: [Transaction]] = [:]
        for transaction in snapshot.transactions where involved.contains(transaction.accountID) {
            byAccount[transaction.accountID, default: []].append(transaction)
        }
        let plans = pairs.map { pair in
            let name = snapshot.displayName(of: pair.source)
            return planAccount(
                pair,
                newName: name == snapshot.displayName(of: pair.target) ? nil : name,
                source: byAccount[pair.source.id] ?? [],
                target: byAccount[pair.target.id] ?? []
            )
        }
        return Plan(source: source, target: target, accounts: plans, unmatchedSourceAccounts: restSource, unmatchedTargetAccounts: restTarget)
    }

    // MARK: - Accounts

    static func pairAccounts(_ source: [Account], _ target: [Account]) -> ([AccountPair], [Account], [Account]) {
        var pairs: [AccountPair] = []
        var restSource: [Account] = []
        var restTarget = target
        for account in source {
            guard let iban = normalizedIBAN(account.iban),
                  let index = restTarget.firstIndex(where: { normalizedIBAN($0.iban) == iban })
            else {
                restSource.append(account)
                continue
            }
            pairs.append(AccountPair(source: account, target: restTarget.remove(at: index), reason: .iban))
        }
        // Accounts without a usable IBAN (depots): pair if it is the only one of its type left on both sides.
        for type in AccountType.allCases {
            let sources = restSource.filter { $0.type == type }
            let targets = restTarget.filter { $0.type == type }
            guard sources.count == 1, targets.count == 1, let s = sources.first, let t = targets.first,
                  normalizedIBAN(s.iban) == nil || normalizedIBAN(t.iban) == nil
            else { continue }
            pairs.append(AccountPair(source: s, target: t, reason: .onlyOfType))
            restSource.removeAll { $0.id == s.id }
            restTarget.removeAll { $0.id == t.id }
        }
        return (pairs, restSource, restTarget)
    }

    static func normalizedIBAN(_ iban: String?) -> String? {
        guard let iban else { return nil }
        let cleaned = iban.uppercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Transactions

    /// Candidates of one status, currency and amount: only these can pair.
    private struct BucketKey: Hashable {
        let status: TransactionStatus
        let currency: String
        let amountCents: Int

        init(_ transaction: Transaction) {
            status = transaction.status
            currency = transaction.currency
            amountCents = transaction.amountCents
        }
    }

    static func planAccount(_ pair: AccountPair, newName: String?, source: [Transaction], target: [Transaction]) -> AccountPlan {
        let kept = source.filter(isKept)
        let droppable = source.filter { !isKept($0) }
        guard let windowStart = target.map(\.effectiveDate).min() else {
            return AccountPlan(pair: pair, newName: newName, windowStart: nil, matched: [], history: sorted(kept), sourceOnlyInWindow: [], targetOnly: [], dropped: sorted(droppable))
        }
        let searchStart = windowStart.adding(days: -dateToleranceDays)

        // Matchable: booked and pending rows from `searchStart` on. Cancelled rows have no twin.
        let candidates = source.filter { isMatchable($0) && $0.effectiveDate >= searchStart }
        var buckets: [BucketKey: [Int]] = [:]
        for index in candidates.indices { buckets[BucketKey(candidates[index]), default: []].append(index) }
        let ibans = candidates.map { normalizedIBAN($0.counterpartIBAN) }
        var used = Set<Int>()
        var matched: [TransactionPair] = []

        func near(_ booking: Transaction) -> [Int] {
            (buckets[BucketKey(booking)] ?? []).filter { index in
                !used.contains(index) && abs(candidates[index].effectiveDate.days(to: booking.effectiveDate)) <= dateToleranceDays
            }
        }

        // Strong matches first, so a weak guess never takes a partner a strong one needs.
        var open: [Transaction] = []
        for booking in sorted(target) {
            let bookingIBAN = normalizedIBAN(booking.counterpartIBAN)
            let strong = near(booking)
                .filter { sameCounterparty(candidates[$0], ibans[$0], booking, bookingIBAN) }
                .min { abs(candidates[$0].effectiveDate.days(to: booking.effectiveDate)) < abs(candidates[$1].effectiveDate.days(to: booking.effectiveDate)) }
            if let strong {
                used.insert(strong)
                matched.append(TransactionPair(source: candidates[strong], target: booking, weak: false))
            } else {
                open.append(booking)
            }
        }
        var targetOnly: [Transaction] = []
        for booking in open {
            let sameDay = near(booking).filter { candidates[$0].effectiveDate == booking.effectiveDate }
            if sameDay.count == 1, let index = sameDay.first {
                used.insert(index)
                matched.append(TransactionPair(source: candidates[index], target: booking, weak: true))
            } else {
                targetOnly.append(booking)
            }
        }

        let twins = Set(used.map { candidates[$0].id })
        let unmatchedKept = kept.filter { !twins.contains($0.id) }
        return AccountPlan(
            pair: pair,
            newName: newName,
            windowStart: windowStart,
            matched: matched.sorted { newestFirst($0.target, $1.target) },
            // Unmatched rows from before the window (the pre-window days included) are ordinary history.
            history: sorted(unmatchedKept.filter { $0.effectiveDate < windowStart || $0.status == .cancelled }),
            sourceOnlyInWindow: sorted(unmatchedKept.filter { $0.effectiveDate >= windowStart && $0.status == .booked }),
            targetOnly: sorted(targetOnly),
            dropped: sorted(droppable.filter { !twins.contains($0.id) })
        )
    }

    /// Rows that survive the merge when unmatched: bookings and their cancellations.
    static func isKept(_ transaction: Transaction) -> Bool {
        transaction.status == .booked || transaction.status == .cancelled
    }

    static func isMatchable(_ transaction: Transaction) -> Bool {
        transaction.status == .booked || transaction.status == .pending
    }

    static func sameCounterparty(_ lhs: Transaction, _ lhsIBAN: String?, _ rhs: Transaction, _ rhsIBAN: String?) -> Bool {
        if let lhsIBAN, let rhsIBAN { return lhsIBAN == rhsIBAN }
        return TransactionMerger.sameMerchant(lhs.counterpartName, rhs.counterpartName)
    }

    static func sorted(_ transactions: [Transaction]) -> [Transaction] {
        transactions.sorted(by: newestFirst)
    }

    static func newestFirst(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        LedgerSnapshot.newestFirst(lhs, rhs)
    }
}

// MARK: - Applying a plan

extension ConnectionMerge {
    public struct CategoryChange: Sendable, Equatable {
        public let categoryID: CategoryID?
        public let source: CategorySource?
        public let confidence: Double?
    }

    /// What `LedgerStore.applyMerge` writes, in one database transaction, before it removes `source`.
    public struct Changes: Sendable, Equatable {
        public let source: ConnectionID
        /// Rows moved to their target account (same ID, so the upsert moves instead of copying).
        public var moves: [Transaction] = []
        /// Target rows that take over the category of their source twin. By ID: a row a running
        /// sync replaced meanwhile is skipped instead of brought back.
        public var categories: [TransactionID: CategoryChange] = [:]
        /// Target account → name to show (the source's).
        public var names: [AccountID: String] = [:]
        /// Source budgets, now for the target account (only where the target has none).
        public var budgets: [AccountBudget] = []
        /// Source account → target account, for app-side settings (hidden, totals, order).
        public var accounts: [AccountID: AccountID] = [:]
        /// Recorded depot history of the source, now for the target (only days the target lacks).
        public var depotValues: [DepotValuePoint] = []
        /// The source's planned items, now for the target account.
        public var plannedItems: [PlannedItem] = []

        public init(source: ConnectionID) {
            self.source = source
        }
    }

    public static func changes(_ plan: Plan, in snapshot: LedgerSnapshot) -> Changes {
        var changes = Changes(source: plan.source)
        for account in plan.accounts {
            let target = account.pair.target.id
            changes.accounts[account.pair.source.id] = target
            changes.moves += account.moving.map { $0.moved(to: target) }
            for pair in account.matched where AccountPlan.carriesCategory(from: pair.source, to: pair.target) {
                changes.categories[pair.target.id] = CategoryChange(
                    categoryID: pair.source.categoryID, source: pair.source.categorySource, confidence: pair.source.confidence
                )
            }
            if let name = account.newName { changes.names[target] = name }
            if var budget = snapshot.budgets[account.pair.source.id], snapshot.budgets[target] == nil {
                budget.accountID = target
                changes.budgets.append(budget)
            }
            let targetDays = Set((snapshot.depotHistory[target] ?? []).map(\.day))
            changes.depotValues += (snapshot.depotHistory[account.pair.source.id] ?? [])
                .filter { !targetDays.contains($0.day) }
                .map { DepotValuePoint(accountID: target, day: $0.day, valueCents: $0.valueCents, purchaseCents: $0.purchaseCents, currency: $0.currency) }
            // Moved bookings keep their IDs; a matched source twin goes away, its "this is not the
            // item" answer passes to the target twin.
            let twins = Dictionary(account.matched.map { ($0.source.id, $0.target.id) }, uniquingKeysWith: { first, _ in first })
            for var item in snapshot.plannedItems where item.accountID == account.pair.source.id {
                item.accountID = target
                item.ignoredMatches = Set(item.ignoredMatches.map { twins[$0] ?? $0 })
                changes.plannedItems.append(item)
            }
        }
        return changes
    }
}

extension LedgerSnapshot {
    /// `ConnectionMerge.Changes` on the in-memory state, then the source connection is removed.
    /// The encrypted store runs the same steps inside one SQL transaction.
    public mutating func applyMerge(_ changes: ConnectionMerge.Changes) {
        apply(TransactionMerger.Result(upserts: changes.moves))
        for (id, change) in changes.categories {
            guard let index = transactions.firstIndex(where: { $0.id == id }) else { continue }
            transactions[index].categoryID = change.categoryID
            transactions[index].categorySource = change.source
            transactions[index].confidence = change.confidence
        }
        for (account, name) in changes.names { setCustomName(name, for: account) }
        for budget in changes.budgets { budgets[budget.accountID] = budget }
        record(changes.depotValues)
        for item in changes.plannedItems { upsertPlannedItem(item) }
        removeConnection(changes.source)
    }
}

extension Transaction {
    /// The same transaction on another account: same ID (so an upsert moves the row), fingerprint
    /// recomputed for the new account, categorisation kept.
    func moved(to account: AccountID) -> Transaction {
        Transaction(
            id: id, accountID: account, bookingDate: bookingDate, valueDate: valueDate, amountCents: amountCents,
            currency: currency, counterpartName: counterpartName, counterpartIBAN: counterpartIBAN, purpose: purpose,
            eref: eref, mref: mref, creditorID: creditorID, status: status, externalID: externalID,
            originalAmountCents: originalAmountCents, originalCurrency: originalCurrency, rawJSON: rawJSON,
            categoryID: categoryID, categorySource: categorySource, confidence: confidence
        )
    }
}
