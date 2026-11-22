import Foundation
import Synchronization

/// Snapshot of everything the UI shows. Value type, cheap to hand to the main actor.
///
/// The mutating methods are the single implementation of "how the ledger changes"; every
/// `LedgerStore` applies them to its in-memory snapshot (after persisting, if it persists).
public struct LedgerSnapshot: Sendable, Equatable {
    public var connections: [Connection] = []
    public var accounts: [Account] = []
    public var balances: [AccountID: Balance] = [:]
    public var transactions: [Transaction] = [] {
        // Any change (also via this public setter) drops the lookups; they are rebuilt on demand.
        didSet { transactionIndex = TransactionIndex() }
    }
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
    /// Fixed costs the user entered or changed (`RecurringEntry`), oldest first.
    public var recurringEntries: [RecurringEntry] = []
    /// Opening balances of accounts without a bank connection (`ConnectorID.manual`); their
    /// balance is computed from it (`ManualAccount.balance`).
    public var openingBalances: [AccountID: OpeningBalance] = [:]
    /// CSV imports (v10), oldest first. Rows they added carry `Transaction.importID`.
    public var importBatches: [ImportBatch] = []
    /// Transactions a sync brought in that the user has not looked at yet ("Neu"). Filled by
    /// `apply(_ update:)` (`newTransactionIDs(after:merge:)`), emptied by `markSeen(_:)`.
    public var newTransactionIDs: Set<TransactionID> = []
    /// Lookups by account, ID and import over `transactions`; not part of `==`.
    private var transactionIndex = TransactionIndex()

    public init() {}

    /// The user's name for the account, else the bank's.
    public func displayName(of account: Account) -> String {
        customAccountNames[account.id] ?? account.name
    }

    public func accounts(of connection: ConnectionID) -> [Account] {
        accounts.filter { $0.connectionID == connection }
    }

    /// Newest first, like `transactions`.
    public func transactions(of account: AccountID) -> [Transaction] {
        transactionIndex.lookups(for: transactions).byAccount[account]?.map { transactions[$0] } ?? []
    }

    public func transaction(_ id: TransactionID) -> Transaction? {
        index(of: id).map { transactions[$0] }
    }

    /// Position of a transaction in `transactions`.
    func index(of id: TransactionID) -> Int? {
        transactionIndex.lookups(for: transactions).byID[id]
    }

    /// Positions of these IDs in `transactions`, ascending (newest first); unknown IDs are skipped.
    func indices<S: Sequence>(of ids: S) -> [Int] where S.Element == TransactionID {
        let byID = transactionIndex.lookups(for: transactions).byID
        return ids.compactMap { byID[$0] }.sorted()
    }

    /// Changes only category fields of the rows at `indices`, keeping the lookups (IDs,
    /// accounts and order are unchanged, so they stay valid).
    mutating func updateCategories(at indices: [Int], _ body: (inout Transaction) -> Void) {
        let index = transactionIndex
        for position in indices { body(&transactions[position]) }
        transactionIndex = index
    }

    /// The rows at `indices` after `body`, without changing the snapshot.
    private func categoryChanges(at indices: [Int], _ body: (inout Transaction) -> Void) -> [Transaction] {
        indices.map { position in
            var transaction = transactions[position]
            body(&transaction)
            return transaction
        }
    }

    /// Puts rows computed by the `…Changes` methods back in place. Only their category fields
    /// differ from the stored rows; unknown IDs are skipped.
    public mutating func replaceCategorized(_ changed: [Transaction]) {
        let positions = changed.compactMap { transaction in index(of: transaction.id).map { ($0, transaction) } }
        let index = transactionIndex
        for (position, transaction) in positions {
            transactions[position].categoryID = transaction.categoryID
            transactions[position].categorySource = transaction.categorySource
            transactions[position].confidence = transaction.confidence
        }
        transactionIndex = index
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
        accounts = accountsReplacing(incoming, of: connection)
    }

    /// `accounts` after `replaceAccounts(_:of:)`, without changing the snapshot.
    public func accountsReplacing(_ incoming: [Account], of connection: ConnectionID) -> [Account] {
        let byID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = accounts.map { byID[$0.id] ?? $0 }
        let known = Set(merged.map(\.id))
        merged.append(contentsOf: incoming.filter { !known.contains($0.id) })
        return merged
    }

    /// Drops a connection with everything that belongs to it (accounts, balances, transactions,
    /// card statements, positions, sync state). Unknown IDs are ignored.
    public mutating func removeConnection(_ id: ConnectionID) {
        let accountIDs = Set(accounts(of: id).map(\.id))
        connections.removeAll { $0.id == id }
        accounts.removeAll { $0.connectionID == id }
        for account in accountIDs { balances[account] = nil }
        if !newTransactionIDs.isEmpty {
            newTransactionIDs.subtract(transactions.lazy.filter { accountIDs.contains($0.accountID) }.map(\.id))
        }
        transactions.removeAll { accountIDs.contains($0.accountID) }
        cardStatements.removeAll { accountIDs.contains($0.accountID) }
        securities.removeAll { accountIDs.contains($0.accountID) }
        syncStates[id] = nil
        for account in accountIDs { customAccountNames[account] = nil }
        for account in accountIDs { budgets[account] = nil }
        for account in accountIDs { depotHistory[account] = nil }
        plannedItems.removeAll { accountIDs.contains($0.accountID) }
        recurringEntries.removeAll { accountIDs.contains($0.accountID) }
        for account in accountIDs { openingBalances[account] = nil }
        importBatches.removeAll { accountIDs.contains($0.accountID) }
    }

    /// Balance of an account without a bank connection: opening balance plus its booked
    /// transactions. `nil` for unknown accounts and accounts of a real bank (the bank reports theirs).
    public func computedManualBalance(of account: AccountID, asOf: Date) -> Balance? {
        guard let stored = accounts.first(where: { $0.id == account }),
              connections.first(where: { $0.id == stored.connectionID })?.isManual == true else { return nil }
        return ManualAccount.balance(opening: openingBalances[account], transactions: transactions(of: account), currency: stored.currency, asOf: asOf)
    }

    // MARK: Imports

    public func importBatch(_ id: ImportBatchID) -> ImportBatch? {
        importBatches.first { $0.id == id }
    }

    /// Rows a CSV import added that are still stored, newest first.
    public func transactions(ofImport id: ImportBatchID) -> [Transaction] {
        transactionIndex.lookups(for: transactions).byImport[id]?.map { transactions[$0] } ?? []
    }

    public mutating func upsert(importBatch batch: ImportBatch) {
        if let index = importBatches.firstIndex(where: { $0.id == batch.id }) {
            importBatches[index] = batch
        } else {
            importBatches.append(batch)
            importBatches.sort { ($0.importedAt, $0.id.rawValue) < ($1.importedAt, $1.id.rawValue) }
        }
    }

    /// A CSV import: its batch and the merged rows in one go.
    public mutating func recordImport(_ batch: ImportBatch, merge: TransactionMerger.Result) {
        upsert(importBatch: batch)
        apply(merge)
    }

    /// What `removeImportedTransactions` takes away.
    public struct ImportRemoval: Sendable, Equatable {
        public var transactions: Set<TransactionID> = []
        /// Batches left without any row; they go too.
        public var emptiedBatches: Set<ImportBatchID> = []
        /// Accounts that lost rows (balance recompute for accounts without a bank).
        public var accounts: Set<AccountID> = []
        public var isEmpty: Bool { transactions.isEmpty }
    }

    /// The plan for removing these rows. Throws `TransactionRemovalError.notImported` if any
    /// known ID is bank data: synced transactions are never deleted. Unknown IDs are ignored.
    public func importRemoval(_ ids: Set<TransactionID>) throws(TransactionRemovalError) -> ImportRemoval {
        var removal = ImportRemoval()
        var notImported: Set<TransactionID> = []
        // Removed rows per batch; a batch is emptied when that equals all its rows.
        var removedPerBatch: [ImportBatchID: Int] = [:]
        let lookups = transactionIndex.lookups(for: transactions)
        for id in ids {
            guard let position = lookups.byID[id] else { continue }
            let transaction = transactions[position]
            guard let batch = transaction.importID else {
                notImported.insert(transaction.id)
                continue
            }
            removal.transactions.insert(transaction.id)
            removal.accounts.insert(transaction.accountID)
            removedPerBatch[batch, default: 0] += 1
        }
        guard notImported.isEmpty else { throw .notImported(notImported) }
        let known = Set(importBatches.map(\.id))
        removal.emptiedBatches = Set(removedPerBatch.compactMap { batch, removed in
            known.contains(batch) && lookups.byImport[batch]?.count == removed ? batch : nil
        })
        return removal
    }

    public mutating func apply(_ removal: ImportRemoval) {
        guard !removal.isEmpty else { return }
        transactions.removeAll { removal.transactions.contains($0.id) }
        importBatches.removeAll { removal.emptiedBatches.contains($0.id) }
        newTransactionIDs.subtract(removal.transactions)
    }

    public mutating func upsertPlannedItem(_ item: PlannedItem) {
        plannedItems.removeAll { $0.id == item.id }
        plannedItems.append(item)
        plannedItems.sort { ($0.day, $0.createdAt) < ($1.day, $1.createdAt) }
    }

    public mutating func removePlannedItem(_ id: UUID) {
        plannedItems.removeAll { $0.id == id }
    }

    /// One entry per ID, and one change per detected payment.
    public mutating func upsertRecurringEntry(_ entry: RecurringEntry) {
        recurringEntries.removeAll { $0.id == entry.id || (entry.seriesID != nil && $0.seriesID == entry.seriesID) }
        recurringEntries.append(entry)
        recurringEntries.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public mutating func removeRecurringEntry(_ id: UUID) {
        recurringEntries.removeAll { $0.id == id }
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
        let changed = categoryChanges(suggestions)
        replaceCategorized(changed)
        return changed
    }

    /// What `setCategories` would change, without changing the snapshot.
    public func categoryChanges(_ suggestions: [TransactionID: CategorySuggestion]) -> [Transaction] {
        guard !suggestions.isEmpty else { return [] }
        let targets = indices(of: suggestions.keys).filter { transactions[$0].categorySource != .manual }
        return categoryChanges(at: targets) { transaction in
            guard let suggestion = suggestions[transaction.id] else { return }
            transaction.categoryID = suggestion.categoryID
            transaction.categorySource = suggestion.source
            transaction.confidence = suggestion.confidence
        }
    }

    /// Removes machine categories (everything but manual) in one go, e.g. after the rule that
    /// set them was removed. Returns the changed transactions (for persisting).
    @discardableResult
    public mutating func clearCategories(_ ids: Set<TransactionID>) -> [Transaction] {
        let changed = clearedCategoryChanges(ids)
        replaceCategorized(changed)
        return changed
    }

    /// What `clearCategories` would change, without changing the snapshot.
    public func clearedCategoryChanges(_ ids: Set<TransactionID>) -> [Transaction] {
        guard !ids.isEmpty else { return [] }
        let targets = indices(of: ids).filter { transactions[$0].categorySource != .manual && transactions[$0].categoryID != nil }
        return categoryChanges(at: targets) { transaction in
            transaction.categoryID = nil
            transaction.categorySource = nil
            transaction.confidence = nil
        }
    }

    /// `nil` or blank restores the bank's name.
    public mutating func setCustomName(_ name: String?, for account: AccountID) {
        customAccountNames[account] = Self.normalizedCustomName(name)
    }

    /// What `setCustomName` stores: trimmed, `nil` for blank.
    public static func normalizedCustomName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Applies the merge; import batches it leaves without rows (`importBatchesEmptied(by:)`) go too.
    public mutating func apply(_ merge: TransactionMerger.Result) {
        guard !merge.isEmpty else { return }
        let emptied = importBatchesEmptied(by: merge)
        let upsertIDs = Set(merge.upserts.map(\.id))
        transactions.removeAll { merge.deletions.contains($0.id) || upsertIDs.contains($0.id) }
        if !merge.upserts.isEmpty {
            // Both runs are sorted: merging them is linear, no full re-sort.
            transactions = Self.mergeSorted(transactions, merge.upserts.sorted(by: Self.newestFirst))
        }
        if !emptied.isEmpty { importBatches.removeAll { emptied.contains($0.id) } }
        if !newTransactionIDs.isEmpty { newTransactionIDs.subtract(merge.deletions) }
    }

    /// The user looked at these transactions: they are no longer "Neu". Unknown IDs are ignored.
    public mutating func markSeen(_ ids: Set<TransactionID>) {
        newTransactionIDs.subtract(ids)
    }

    /// `newTransactionIDs` once `merge` (computed for `update`) is applied.
    ///
    /// New are booked and pending rows the account did not hold before. Not new:
    /// - anything from the first sync of an account (`since == nil`, or nothing stored yet): that
    ///   is its history, not news,
    /// - a booking that resolves a stored reservation the user already saw (it is the same
    ///   payment); a booking of an unseen reservation stays new,
    /// - planned and cancelled rows.
    public func newTransactionIDs(after update: AccountUpdate, merge: TransactionMerger.Result) -> Set<TransactionID> {
        var result = newTransactionIDs.subtracting(merge.deletions)
        guard update.since != nil else { return result }
        let lookups = transactionIndex.lookups(for: transactions)
        guard let stored = lookups.byAccount[update.accountID], !stored.isEmpty else { return result }
        let reservation = Dictionary(merge.resolved.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for transaction in merge.upserts where transaction.status == .booked || transaction.status == .pending {
            guard lookups.byID[transaction.id] == nil else { continue }
            if let pending = reservation[transaction.id], lookups.byID[pending] != nil, !newTransactionIDs.contains(pending) { continue }
            result.insert(transaction.id)
        }
        return result
    }

    /// Import batches whose remaining rows this merge all deletes or takes over (a synced row
    /// without `importID` replacing an imported one with the same ID). Batches that had no rows
    /// before are not touched.
    public func importBatchesEmptied(by merge: TransactionMerger.Result) -> Set<ImportBatchID> {
        guard !importBatches.isEmpty, !merge.isEmpty else { return [] }
        let lookups = transactionIndex.lookups(for: transactions)
        let replaced = merge.deletions.union(merge.upserts.map(\.id))
        // Batches the merge's rows still (or newly) belong to.
        let incoming = Set(merge.upserts.compactMap(\.importID))
        var touched: Set<ImportBatchID> = []
        for id in replaced {
            guard let position = lookups.byID[id], let batch = transactions[position].importID,
                  !incoming.contains(batch) else { continue }
            touched.insert(batch)
        }
        return touched.filter { batch in
            !(lookups.byImport[batch] ?? []).contains { !replaced.contains(transactions[$0].id) }
        }
    }

    /// Two runs sorted by `newestFirst` as one sorted array.
    static func mergeSorted(_ lhs: [Transaction], _ rhs: [Transaction]) -> [Transaction] {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        var result: [Transaction] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var left = lhs.startIndex
        var right = rhs.startIndex
        while left < lhs.endIndex, right < rhs.endIndex {
            // Stable for equal keys: the stored row first.
            if newestFirst(rhs[right], lhs[left]) {
                result.append(rhs[right])
                right += 1
            } else {
                result.append(lhs[left])
                left += 1
            }
        }
        result.append(contentsOf: lhs[left...])
        result.append(contentsOf: rhs[right...])
        return result
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
        setCategory(category, source: source, confidence: confidence, for: [id] as Set<TransactionID>).first
    }

    /// One category for many transactions (manual correction of a selection). Unknown IDs are
    /// skipped. Returns the changed transactions (for persisting).
    @discardableResult
    public mutating func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for ids: Set<TransactionID>) -> [Transaction] {
        let changed = categoryChanges(category, source: source, confidence: confidence, for: ids)
        replaceCategorized(changed)
        return changed
    }

    /// What `setCategory(_:source:confidence:for:)` would change, without changing the snapshot.
    public func categoryChanges(_ category: CategoryID?, source: CategorySource, confidence: Double?, for ids: Set<TransactionID>) -> [Transaction] {
        guard !ids.isEmpty else { return [] }
        return categoryChanges(at: indices(of: ids)) { transaction in
            transaction.categoryID = category
            transaction.categorySource = category == nil ? nil : source
            transaction.confidence = category == nil ? nil : confidence
        }
    }

    /// Everything one account delivered in a sync, applied in one go. The merge runs against
    /// the transactions stored at that moment, so a categorisation that finished meanwhile is
    /// inherited, not overwritten. Returns the merge (for persisting).
    @discardableResult
    public mutating func apply(_ update: AccountUpdate) -> TransactionMerger.Result {
        let merge = merge(for: update)
        apply(update, merge: merge)
        return merge
    }

    /// The merge `apply(_ update:)` would run against the stored transactions.
    public func merge(for update: AccountUpdate) -> TransactionMerger.Result {
        TransactionMerger.merge(stored: transactions(of: update.accountID), incoming: update.transactions, since: update.since)
    }

    /// `apply(_ update:)` with its merge computed beforehand (`merge(for:)`), and optionally
    /// `newTransactionIDs(after:merge:)` too.
    public mutating func apply(_ update: AccountUpdate, merge: TransactionMerger.Result, newTransactionIDs precomputed: Set<TransactionID>? = nil) {
        let fresh = precomputed ?? newTransactionIDs(after: update, merge: merge)
        balances[update.accountID] = update.balance
        apply(merge)
        newTransactionIDs = fresh
        if let statements = update.cardStatements { replaceCardStatements(statements, of: update.accountID) }
        if let positions = update.securities { replaceSecurities(positions, of: update.accountID) }
        if let point = DepotValuePoint.recorded(from: update) { record(point) }
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

public enum ImportBatchError: Error, Equatable, Sendable {
    /// The account the CSV import is for is not in the ledger.
    case unknownAccount(AccountID)
}

/// Lazily built lookups over `LedgerSnapshot.transactions`, shared by copies of one snapshot
/// value and rebuilt after a change. Always equal: a cache, not data.
struct TransactionIndex: Sendable, Equatable {
    struct Lookups: Sendable {
        /// Positions per account, ascending (so newest first).
        var byAccount: [AccountID: [Int]] = [:]
        var byID: [TransactionID: Int] = [:]
        /// Positions per CSV import, ascending.
        var byImport: [ImportBatchID: [Int]] = [:]
    }

    private final class Storage: Sendable {
        let lookups = Mutex<Lookups?>(nil)
    }

    private let storage = Storage()

    static func == (lhs: TransactionIndex, rhs: TransactionIndex) -> Bool { true }

    func lookups(for transactions: [Transaction]) -> Lookups {
        storage.lookups.withLock { cached in
            if let cached { return cached }
            var built = Lookups()
            built.byID.reserveCapacity(transactions.count)
            for (position, transaction) in transactions.enumerated() {
                built.byAccount[transaction.accountID, default: []].append(position)
                // First occurrence wins, like `firstIndex(where:)`.
                if built.byID[transaction.id] == nil { built.byID[transaction.id] = position }
                if let batch = transaction.importID { built.byImport[batch, default: []].append(position) }
            }
            cached = built
            return built
        }
    }
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
    /// Opening balance of an account without a bank connection; `nil` removes it.
    func setOpeningBalance(_ opening: OpeningBalance?, for account: AccountID) async throws
    func storedTransactions(of account: AccountID) -> [Transaction]
    func apply(_ merge: TransactionMerger.Result) async throws
    func replaceCardStatements(_ statements: [CardStatement], of account: AccountID) async throws
    func replaceSecurities(_ positions: [SecurityPosition], of account: AccountID) async throws
    func setSyncState(_ state: SyncState, for connection: ConnectionID) async throws
    /// The user looked at these transactions: drops them from `newTransactionIDs`.
    func markSeen(_ ids: Set<TransactionID>) async throws
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
    /// Adds or changes a fixed cost entry (by ID; one change per detected payment).
    func upsertRecurringEntry(_ entry: RecurringEntry) async throws
    func removeRecurringEntry(_ id: UUID) async throws
    /// Removes machine categories in one write; manual categories stay untouched.
    func clearCategories(_ ids: Set<TransactionID>) async throws
    /// One category for many transactions in one write (manual correction of a selection).
    func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for transactions: Set<TransactionID>) async throws
    /// Balance, transactions (merged against what is stored), card statements and positions of
    /// one account in one write with one published snapshot.
    func apply(_ update: AccountUpdate) async throws
    /// Depot history points in one write (upsert by account and day); demo data and imports.
    func recordDepotValues(_ points: [DepotValuePoint]) async throws
    /// A CSV import (v10): the batch and the merged rows (which carry its `importID`) in one write.
    func recordImport(_ batch: ImportBatch, merge: TransactionMerger.Result) async throws
    /// Deletes CSV-imported rows in one write; batches left empty go too. Throws
    /// `TransactionRemovalError.notImported` and removes nothing if any ID is bank data.
    /// Returns what was removed.
    @discardableResult
    func removeImportedTransactions(_ ids: Set<TransactionID>) async throws -> LedgerSnapshot.ImportRemoval
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

    public func setOpeningBalance(_ opening: OpeningBalance?, for account: AccountID) {
        change { $0.openingBalances[account] = opening }
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

    public func markSeen(_ ids: Set<TransactionID>) {
        guard !state.newTransactionIDs.isDisjoint(with: ids) else { return }
        change { $0.markSeen(ids) }
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

    public func upsertRecurringEntry(_ entry: RecurringEntry) throws {
        guard state.accounts.contains(where: { $0.id == entry.accountID }) else { throw PlannedItemError.unknownAccount(entry.accountID) }
        change { $0.upsertRecurringEntry(entry) }
    }

    public func removeRecurringEntry(_ id: UUID) {
        change { $0.removeRecurringEntry(id) }
    }

    public func recordImport(_ batch: ImportBatch, merge: TransactionMerger.Result) throws {
        // Like the encrypted store (foreign key): a batch needs its account.
        guard state.accounts.contains(where: { $0.id == batch.accountID }) else { throw ImportBatchError.unknownAccount(batch.accountID) }
        change { $0.recordImport(batch, merge: merge) }
    }

    @discardableResult
    public func removeImportedTransactions(_ ids: Set<TransactionID>) throws -> LedgerSnapshot.ImportRemoval {
        let removal = try state.importRemoval(ids)
        guard !removal.isEmpty else { return removal }
        change { $0.apply(removal) }
        return removal
    }

    public func clearCategories(_ ids: Set<TransactionID>) {
        change { $0.clearCategories(ids) }
    }

    public func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for transactions: Set<TransactionID>) {
        guard !transactions.isEmpty else { return }
        change { $0.setCategory(category, source: source, confidence: confidence, for: transactions) }
    }
}
