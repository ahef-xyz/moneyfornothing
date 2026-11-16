import Foundation

/// Snapshot of everything the UI shows. Value type, cheap to hand to the main actor.
///
/// The mutating methods are the single implementation of "how the ledger changes"; every
/// `LedgerStore` applies them to its in-memory snapshot (after persisting, if it persists).
public struct LedgerSnapshot: Sendable, Equatable {
    public var connections: [Connection] = []
    public var accounts: [Account] = []
    public var balances: [AccountID: Balance] = [:]
    public var transactions: [Transaction] = []
    public var cardStatements: [CardStatement] = []
    public var securities: [SecurityPosition] = []
    public var syncStates: [ConnectionID: SyncState] = [:]
    /// Names the user gave accounts. Kept apart from `Account.name`, which the bank sets again
    /// on every sync; `accounts` always carries the bank's name.
    public var customAccountNames: [AccountID: String] = [:]
    /// User rules for categories (⇧⌘K), newest first.
    public var categoryRules: [CategoryRule] = []
    /// Spending budgets per account.
    public var budgets: [AccountID: AccountBudget] = [:]
    /// Depot value per day, oldest first (`DepotValuePoint`, recorded by `apply(_ update:)`).
    public var depotHistory: [AccountID: [DepotValuePoint]] = [:]
    /// One-off payments the user expects (`PlannedItem`), by day.
    public var plannedItems: [PlannedItem] = []

    public init() {}

    /// The user's name for the account, else the bank's.
    public func displayName(of account: Account) -> String {
        customAccountNames[account.id] ?? account.name
    }

    public func accounts(of connection: ConnectionID) -> [Account] {
        accounts.filter { $0.connectionID == connection }
    }

    public func transactions(of account: AccountID) -> [Transaction] {
        transactions.filter { $0.accountID == account }
    }

    // MARK: - Mutations

    public mutating func upsert(connection: Connection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
    }

    /// Accounts that disappeared keep their data until the user removes them explicitly
    /// (banks hide accounts temporarily).
    public mutating func replaceAccounts(_ incoming: [Account], of connection: ConnectionID) {
        let byID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = accounts.map { byID[$0.id] ?? $0 }
        let known = Set(merged.map(\.id))
        merged.append(contentsOf: incoming.filter { !known.contains($0.id) })
        accounts = merged
    }

    /// Drops a connection with everything that belongs to it (accounts, balances, transactions,
    /// card statements, positions, sync state). Unknown IDs are ignored.
    public mutating func removeConnection(_ id: ConnectionID) {
        let accountIDs = Set(accounts(of: id).map(\.id))
        connections.removeAll { $0.id == id }
        accounts.removeAll { $0.connectionID == id }
        for account in accountIDs { balances[account] = nil }
        transactions.removeAll { accountIDs.contains($0.accountID) }
        cardStatements.removeAll { accountIDs.contains($0.accountID) }
        securities.removeAll { accountIDs.contains($0.accountID) }
        syncStates[id] = nil
        for account in accountIDs { customAccountNames[account] = nil }
        for account in accountIDs { budgets[account] = nil }
        for account in accountIDs { depotHistory[account] = nil }
        plannedItems.removeAll { accountIDs.contains($0.accountID) }
    }

    public mutating func upsertPlannedItem(_ item: PlannedItem) {
        plannedItems.removeAll { $0.id == item.id }
        plannedItems.append(item)
        plannedItems.sort { ($0.day, $0.createdAt) < ($1.day, $1.createdAt) }
    }

    public mutating func removePlannedItem(_ id: UUID) {
        plannedItems.removeAll { $0.id == id }
    }

    public mutating func upsertRule(_ rule: CategoryRule) {
        categoryRules.removeAll { $0.id == rule.id }
        categoryRules.insert(rule, at: 0)
    }

    public mutating func removeRule(_ id: UUID) {
        categoryRules.removeAll { $0.id == id }
    }

    /// Machine suggestions in one go. Never overwrites a manual category; unknown IDs are skipped.
    /// Returns the changed transactions (for persisting).
    @discardableResult
    public mutating func setCategories(_ suggestions: [TransactionID: CategorySuggestion]) -> [Transaction] {
        guard !suggestions.isEmpty else { return [] }
        var changed: [Transaction] = []
        for index in transactions.indices {
            guard let suggestion = suggestions[transactions[index].id], transactions[index].categorySource != .manual else { continue }
            transactions[index].categoryID = suggestion.categoryID
            transactions[index].categorySource = suggestion.source
            transactions[index].confidence = suggestion.confidence
            changed.append(transactions[index])
        }
        return changed
    }

    /// Removes machine categories (everything but manual) in one go, e.g. after the rule that
    /// set them was removed. Returns the changed transactions (for persisting).
    @discardableResult
    public mutating func clearCategories(_ ids: Set<TransactionID>) -> [Transaction] {
        guard !ids.isEmpty else { return [] }
        var changed: [Transaction] = []
        for index in transactions.indices {
            guard ids.contains(transactions[index].id), transactions[index].categorySource != .manual,
                  transactions[index].categoryID != nil else { continue }
            transactions[index].categoryID = nil
            transactions[index].categorySource = nil
            transactions[index].confidence = nil
            changed.append(transactions[index])
        }
        return changed
    }

    /// `nil` or blank restores the bank's name.
    public mutating func setCustomName(_ name: String?, for account: AccountID) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        customAccountNames[account] = trimmed.isEmpty ? nil : trimmed
    }

    public mutating func apply(_ merge: TransactionMerger.Result) {
        guard !merge.isEmpty else { return }
        let upsertIDs = Set(merge.upserts.map(\.id))
        transactions.removeAll { merge.deletions.contains($0.id) || upsertIDs.contains($0.id) }
        transactions.append(contentsOf: merge.upserts)
        transactions.sort(by: Self.newestFirst)
    }

    public mutating func replaceCardStatements(_ statements: [CardStatement], of account: AccountID) {
        cardStatements.removeAll { $0.accountID == account }
        cardStatements.append(contentsOf: statements)
    }

    public mutating func replaceSecurities(_ positions: [SecurityPosition], of account: AccountID) {
        securities.removeAll { $0.accountID == account }
        securities.append(contentsOf: positions)
    }

    /// Returns the updated transaction, or `nil` if the ID is unknown.
    @discardableResult
    public mutating func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for id: TransactionID) -> Transaction? {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return nil }
        transactions[index].categoryID = category
        transactions[index].categorySource = category == nil ? nil : source
        transactions[index].confidence = category == nil ? nil : confidence
        return transactions[index]
    }

    /// One category for many transactions (manual correction of a selection). Unknown IDs are
    /// skipped. Returns the changed transactions (for persisting).
    @discardableResult
    public mutating func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for ids: Set<TransactionID>) -> [Transaction] {
        guard !ids.isEmpty else { return [] }
        var changed: [Transaction] = []
        for index in transactions.indices where ids.contains(transactions[index].id) {
            transactions[index].categoryID = category
            transactions[index].categorySource = category == nil ? nil : source
            transactions[index].confidence = category == nil ? nil : confidence
            changed.append(transactions[index])
        }
        return changed
    }

    /// Everything one account delivered in a sync, applied in one go. The merge runs against
    /// the transactions stored at that moment, so a categorisation that finished meanwhile is
    /// inherited, not overwritten. Returns the merge (for persisting).
    @discardableResult
    public mutating func apply(_ update: AccountUpdate) -> TransactionMerger.Result {
        balances[update.accountID] = update.balance
        let merge = TransactionMerger.merge(stored: transactions(of: update.accountID), incoming: update.transactions, since: update.since)
        apply(merge)
        if let statements = update.cardStatements { replaceCardStatements(statements, of: update.accountID) }
        if let positions = update.securities { replaceSecurities(positions, of: update.accountID) }
        if let point = DepotValuePoint.recorded(from: update) { record(point) }
        return merge
    }

    public static func newestFirst(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        if lhs.effectiveDate != rhs.effectiveDate { return lhs.effectiveDate > rhs.effectiveDate }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

/// What one account delivered in a sync (`LedgerStore.apply(_:)`, one write, one publish).
public struct AccountUpdate: Sendable, Equatable {
    public var accountID: AccountID
    public var balance: Balance
    /// The bank's answer; merged into the stored transactions by the store.
    public var transactions: [Transaction]
    /// Start of the fetched window (`nil` = full history), see `TransactionMerger.merge`.
    public var since: BankDay?
    /// `nil` = not fetched (no card account), keep what is stored.
    public var cardStatements: [CardStatement]?
    /// `nil` = not fetched (no depot), keep what is stored.
    public var securities: [SecurityPosition]?

    public init(accountID: AccountID, balance: Balance, transactions: [Transaction], since: BankDay?, cardStatements: [CardStatement]? = nil, securities: [SecurityPosition]? = nil) {
        self.accountID = accountID
        self.balance = balance
        self.transactions = transactions
        self.since = since
        self.cardStatements = cardStatements
        self.securities = securities
    }
}

public struct SyncState: Sendable, Equatable, Codable {
    public enum Phase: Sendable, Equatable, Codable {
        case idle
        case syncing
        case waitingForApproval(AuthChallenge)
        case failed(ConnectorError)
        /// The bank answered, but MFN could not store the result (disk full, database error).
        case storeFailed(String)
    }

    public var phase: Phase
    public var lastSuccess: Date?
    public var consecutiveFailures: Int

    public init(phase: Phase = .idle, lastSuccess: Date? = nil, consecutiveFailures: Int = 0) {
        self.phase = phase
        self.lastSuccess = lastSuccess
        self.consecutiveFailures = consecutiveFailures
    }
}

public enum PlannedItemError: Error, Equatable, Sendable {
    /// The account the item belongs to is not in the ledger.
    case unknownAccount(AccountID)
}

/// Persistence boundary of MFN. The UI and `SyncEngine` only talk to this protocol.
///
/// `InMemoryLedgerStore` backs previews, tests and the mock app; `EncryptedLedgerStore`
/// (module `MFNStore`) persists into SQLCipher. Writes throw: a failed write is never swallowed.
public protocol LedgerStore: Actor {
    func snapshot() -> LedgerSnapshot
    func updates() -> AsyncStream<LedgerSnapshot>

    func upsert(connection: Connection) async throws
    /// Removes the connection and all its data ("Bank entfernen").
    func removeConnection(_ id: ConnectionID) async throws
    /// `ConnectionMerge.Changes` and the removal of their source in one write: all or nothing.
    func applyMerge(_ changes: ConnectionMerge.Changes) async throws
    func replaceAccounts(_ accounts: [Account], of connection: ConnectionID) async throws
    func setBalance(_ balance: Balance, for account: AccountID) async throws
    func storedTransactions(of account: AccountID) -> [Transaction]
    func apply(_ merge: TransactionMerger.Result) async throws
    func replaceCardStatements(_ statements: [CardStatement], of account: AccountID) async throws
    func replaceSecurities(_ positions: [SecurityPosition], of account: AccountID) async throws
    func setSyncState(_ state: SyncState, for connection: ConnectionID) async throws
    func syncState(for connection: ConnectionID) -> SyncState

    func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for transaction: TransactionID) async throws
    /// The user's name for an account; `nil` or blank restores the bank's name.
    func setCustomName(_ name: String?, for account: AccountID) async throws
    /// Categorization results in one write; manual categories stay untouched.
    func setCategories(_ suggestions: [TransactionID: CategorySuggestion]) async throws
    func upsertRule(_ rule: CategoryRule) async throws
    func removeRule(_ id: UUID) async throws
    func setBudget(_ budget: AccountBudget) async throws
    func removeBudget(for account: AccountID) async throws
    /// Adds or changes a planned item (by ID).
    func upsertPlannedItem(_ item: PlannedItem) async throws
    func removePlannedItem(_ id: UUID) async throws
    /// Removes machine categories in one write; manual categories stay untouched.
    func clearCategories(_ ids: Set<TransactionID>) async throws
    /// One category for many transactions in one write (manual correction of a selection).
    func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for transactions: Set<TransactionID>) async throws
    /// Balance, transactions (merged against what is stored), card statements and positions of
    /// one account in one write with one published snapshot.
    func apply(_ update: AccountUpdate) async throws
    /// Depot history points in one write (upsert by account and day); demo data and imports.
    func recordDepotValues(_ points: [DepotValuePoint]) async throws
}

extension LedgerStore {
    /// Fallback for stores without a batch write: one `setCategory` per transaction.
    public func clearCategories(_ ids: Set<TransactionID>) async throws {
        var copy = snapshot()
        for transaction in copy.clearCategories(ids) {
            try await setCategory(nil, source: .rule, confidence: nil, for: transaction.id)
        }
    }
}

/// Fan-out of snapshots to `updates()` subscribers. Owned by a store actor.
public struct SnapshotBroadcaster: Sendable {
    private var continuations: [UUID: AsyncStream<LedgerSnapshot>.Continuation] = [:]

    public init() {}

    /// Registers a subscriber and emits `current` immediately. `onTermination` must remove the
    /// subscriber again via `remove(_:)` on the owning actor.
    public mutating func subscribe(current: LedgerSnapshot, onTermination: @escaping @Sendable (UUID) -> Void) -> AsyncStream<LedgerSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: LedgerSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        continuations[key] = continuation
        continuation.yield(current)
        continuation.onTermination = { _ in onTermination(key) }
        return stream
    }

    public mutating func remove(_ key: UUID) {
        continuations[key] = nil
    }

    public func publish(_ snapshot: LedgerSnapshot) {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    public mutating func finishAll() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations = [:]
    }
}

public actor InMemoryLedgerStore: LedgerStore {
    private var state = LedgerSnapshot()
    private var broadcaster = SnapshotBroadcaster()
    /// Number of published snapshots (tests check that batches publish once).
    private(set) var publishCount = 0

    public init(_ initial: LedgerSnapshot = LedgerSnapshot()) {
        self.state = initial
    }

    public func snapshot() -> LedgerSnapshot { state }

    /// Emits the current snapshot immediately, then after every change.
    public func updates() -> AsyncStream<LedgerSnapshot> {
        broadcaster.subscribe(current: state) { [weak self] key in
            Task { await self?.removeSubscriber(key) }
        }
    }

    private func removeSubscriber(_ key: UUID) {
        broadcaster.remove(key)
    }

    private func change(_ body: (inout LedgerSnapshot) -> Void) {
        body(&state)
        broadcaster.publish(state)
        publishCount += 1
    }

    public func upsert(connection: Connection) {
        change { $0.upsert(connection: connection) }
    }

    public func removeConnection(_ id: ConnectionID) {
        change { $0.removeConnection(id) }
    }

    public func applyMerge(_ changes: ConnectionMerge.Changes) {
        change { $0.applyMerge(changes) }
    }

    public func replaceAccounts(_ accounts: [Account], of connection: ConnectionID) {
        change { $0.replaceAccounts(accounts, of: connection) }
    }

    public func setBalance(_ balance: Balance, for account: AccountID) {
        change { $0.balances[account] = balance }
    }

    public func storedTransactions(of account: AccountID) -> [Transaction] {
        state.transactions(of: account)
    }

    public func apply(_ merge: TransactionMerger.Result) {
        guard !merge.isEmpty else { return }
        change { $0.apply(merge) }
    }

    public func apply(_ update: AccountUpdate) {
        change { $0.apply(update) }
    }

    /// Like the encrypted store (foreign key): points of unknown accounts are not stored.
    public func recordDepotValues(_ points: [DepotValuePoint]) {
        let known = Set(state.accounts.map(\.id))
        change { $0.record(points.filter { known.contains($0.accountID) }) }
    }

    public func replaceCardStatements(_ statements: [CardStatement], of account: AccountID) {
        change { $0.replaceCardStatements(statements, of: account) }
    }

    public func replaceSecurities(_ positions: [SecurityPosition], of account: AccountID) {
        change { $0.replaceSecurities(positions, of: account) }
    }

    public func setSyncState(_ syncState: SyncState, for connection: ConnectionID) {
        change { $0.syncStates[connection] = syncState }
    }

    public func syncState(for connection: ConnectionID) -> SyncState {
        state.syncStates[connection] ?? SyncState()
    }

    public func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for transaction: TransactionID) {
        change { $0.setCategory(category, source: source, confidence: confidence, for: transaction) }
    }

    public func setCustomName(_ name: String?, for account: AccountID) {
        change { $0.setCustomName(name, for: account) }
    }

    public func setCategories(_ suggestions: [TransactionID: CategorySuggestion]) {
        change { $0.setCategories(suggestions) }
    }

    public func upsertRule(_ rule: CategoryRule) {
        change { $0.upsertRule(rule) }
    }

    public func removeRule(_ id: UUID) {
        change { $0.removeRule(id) }
    }

    public func setBudget(_ budget: AccountBudget) {
        change { $0.budgets[budget.accountID] = budget }
    }

    public func removeBudget(for account: AccountID) {
        change { $0.budgets[account] = nil }
    }

    /// Like the encrypted store (foreign key): an item of an unknown account is an error.
    public func upsertPlannedItem(_ item: PlannedItem) throws {
        guard state.accounts.contains(where: { $0.id == item.accountID }) else { throw PlannedItemError.unknownAccount(item.accountID) }
        change { $0.upsertPlannedItem(item) }
    }

    public func removePlannedItem(_ id: UUID) {
        change { $0.removePlannedItem(id) }
    }

    public func clearCategories(_ ids: Set<TransactionID>) {
        change { $0.clearCategories(ids) }
    }

    public func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for transactions: Set<TransactionID>) {
        guard !transactions.isEmpty else { return }
        change { $0.setCategory(category, source: source, confidence: confidence, for: transactions) }
    }
}
