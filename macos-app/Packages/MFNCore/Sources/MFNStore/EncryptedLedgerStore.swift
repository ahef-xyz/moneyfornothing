import Foundation
import MFNCore

public enum StoreError: Error, Equatable, Sendable {
    /// SQLCipher is not active (e.g. the system SQLite got linked instead): refuse to store data.
    case encryptionUnavailable
    /// Wrong key or not a MFN database.
    case cannotDecrypt
    case corruptRow(String)
    case closed
    case database(String)
}

/// `LedgerStore` persisted in a SQLCipher database (AES-256, raw 256-bit key from the keychain).
///
/// Every write goes to the database first, inside one transaction; only after commit the
/// in-memory snapshot is updated and published. A failed write leaves both unchanged.
/// `close()` (app lock) closes the database; the store is unusable afterwards.
public actor EncryptedLedgerStore: LedgerStore {
    public static let fileName = "ledger.sqlite"

    private let db: SQLiteConnection
    /// The database file this store opened (for `backup`).
    private let url: URL
    private var state: LedgerSnapshot
    private var broadcaster = SnapshotBroadcaster()
    /// Number of published snapshots (tests check that batches publish once).
    private(set) var publishCount = 0

    private init(db: sending SQLiteConnection, url: URL, state: LedgerSnapshot) {
        self.db = db
        self.url = url
        self.state = state
    }

    /// Opens (or creates) the database at `url` with the 256-bit `key`, migrates it and loads
    /// the snapshot. Use `LedgerVault` to obtain the key; it is not retained.
    public static func open(at url: URL, key: Data) async throws(StoreError) -> EncryptedLedgerStore {
        guard key.count == 32 else { throw .database("Schlüssel muss 32 Byte haben") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .database("Verzeichnis: \(error.localizedDescription)")
        }
        var passphrase = key.sqlCipherRawKey
        defer { passphrase.wipe() }

        do {
            let db = try SQLiteConnection(path: url.path, passphrase: passphrase)
            let cipherVersion = try db.query("PRAGMA cipher_version").first?.optionalString("cipher_version")
            guard let cipherVersion, !cipherVersion.isEmpty else { throw StoreError.encryptionUnavailable }
            // First real read: fails with SQLITE_NOTADB if the key is wrong.
            _ = try db.query("SELECT count(*) AS n FROM sqlite_master")
            try db.execute("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")
            try Schema.migrate(db)
            let snapshot = try load(db)
            Log.store.info("Datenbank geöffnet (SQLCipher \(cipherVersion, privacy: .public), \(snapshot.transactions.count, privacy: .public) Buchungen)")
            return EncryptedLedgerStore(db: db, url: url, state: snapshot)
        } catch {
            throw map(error)
        }
    }

    /// Closes the database. Called when the app locks.
    public func close() {
        guard db.isOpen else { return }
        db.close()
        state = LedgerSnapshot()
        broadcaster.finishAll()
        Log.store.info("Datenbank geschlossen")
    }

    /// Consistent copy of this store's database to `destination`, still encrypted with the same
    /// key. The WAL is checkpointed into the main file first (and must be complete); the actor
    /// guarantees no write runs meanwhile. A failed copy leaves no partial file. Used before
    /// irreversible changes (merging connections).
    public func backup(to destination: URL) throws(StoreError) {
        guard db.isOpen else { throw .closed }
        do {
            // Columns: busy, log, checkpointed. busy = 1: pages stayed in the WAL, the copy would miss them.
            let result = try db.query("PRAGMA wal_checkpoint(TRUNCATE)").first
            guard try result?.int("busy") == 0 else { throw StoreError.database("Sicherung: WAL nicht vollständig übernommen") }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let error = error as? StoreError { throw error }
            throw .database("Sicherung: \(error.localizedDescription)")
        }
        Log.store.info("Datenbank gesichert")
    }

    // MARK: - LedgerStore

    public func snapshot() -> LedgerSnapshot { state }

    public func updates() -> AsyncStream<LedgerSnapshot> {
        broadcaster.subscribe(current: state) { [weak self] key in
            Task { await self?.removeSubscriber(key) }
        }
    }

    private func removeSubscriber(_ key: UUID) {
        broadcaster.remove(key)
    }

    public func storedTransactions(of account: AccountID) -> [Transaction] {
        state.transactions(of: account)
    }

    public func syncState(for connection: ConnectionID) -> SyncState {
        state.syncStates[connection] ?? SyncState()
    }

    public func upsert(connection: Connection) throws {
        try write { try $0.run(ConnectionTable.upsert, ConnectionTable.values(connection)) }
        change { $0.upsert(connection: connection) }
    }

    /// Deletes the connection; accounts, balances, transactions, card statements, positions and
    /// the sync state go with it (`ON DELETE CASCADE`, deleted explicitly as well).
    public func removeConnection(_ id: ConnectionID) throws {
        let accountIDs = state.accounts(of: id).map(\.id)
        try write { try Self.deleteConnection(id, accounts: accountIDs, in: $0) }
        change { $0.removeConnection(id) }
    }

    /// Merging connections: moves, categories, names, budgets and the removal of the source in
    /// one SQL transaction (all or nothing), published once.
    public func applyMerge(_ changes: ConnectionMerge.Changes) throws {
        var next = state
        next.applyMerge(changes)
        let categorized = next.transactions.filter { changes.categories[$0.id] != nil }
        let sourceAccounts = state.accounts(of: changes.source).map(\.id)
        try write { db in
            for transaction in changes.moves + categorized {
                try db.run(TransactionTable.upsert, TransactionTable.values(transaction))
            }
            for account in changes.names.keys {
                try Self.writeCustomName(next.customAccountNames[account], for: account, in: db)
            }
            for budget in changes.budgets {
                try Self.writeBudget(budget, in: db)
            }
            for point in changes.depotValues {
                try db.run(DepotValueTable.upsert, DepotValueTable.values(point))
            }
            for item in changes.plannedItems {
                try db.run(PlannedItemTable.upsert, try PlannedItemTable.values(item))
            }
            try Self.deleteConnection(changes.source, accounts: sourceAccounts, in: db)
        }
        change { $0 = next }
    }

    private static func deleteConnection(_ id: ConnectionID, accounts: [AccountID], in db: SQLiteConnection) throws {
        for account in accounts {
            for table in ["ledgerTransaction", "cardStatement", "securityPosition", "balance", "accountName", "budget", "depotValue", "plannedItem"] {
                try db.run("DELETE FROM \(table) WHERE accountID = ?", [.text(account.rawValue)])
            }
        }
        try db.run("DELETE FROM account WHERE connectionID = ?", [.text(id.rawValue)])
        try db.run("DELETE FROM syncState WHERE connectionID = ?", [.text(id.rawValue)])
        try db.run("DELETE FROM connection WHERE id = ?", [.text(id.rawValue)])
    }

    private static func writeCustomName(_ name: String?, for account: AccountID, in db: SQLiteConnection) throws {
        if let name {
            try db.run(
                "INSERT INTO accountName (accountID, name) VALUES (?, ?) ON CONFLICT(accountID) DO UPDATE SET name = excluded.name",
                [.text(account.rawValue), .text(name)]
            )
        } else {
            try db.run("DELETE FROM accountName WHERE accountID = ?", [.text(account.rawValue)])
        }
    }

    private static func writeBudget(_ budget: AccountBudget, in db: SQLiteConnection) throws {
        try db.run(
            "INSERT INTO budget (accountID, amountCents, period, startDay, anchorTolerance, anchorCounterpart) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(accountID) DO UPDATE SET amountCents = excluded.amountCents, period = excluded.period, startDay = excluded.startDay, anchorTolerance = excluded.anchorTolerance, anchorCounterpart = excluded.anchorCounterpart",
            [.text(budget.accountID.rawValue), .integer(Int64(budget.amountCents)), .text(budget.period.rawValue), .integer(Int64(budget.startDay)),
             budget.anchor.map { .integer(Int64($0.toleranceDays)) } ?? .null, budget.anchor?.counterpart.map { .text($0) } ?? .null]
        )
    }

    public func replaceAccounts(_ accounts: [Account], of connection: ConnectionID) throws {
        var next = state
        next.replaceAccounts(accounts, of: connection)
        try write { db in
            for (position, account) in next.accounts.enumerated() where account.connectionID == connection {
                try db.run(AccountTable.upsert, AccountTable.values(account, position: position))
            }
        }
        change { $0 = next }
    }

    public func setBalance(_ balance: Balance, for account: AccountID) throws {
        try write { try $0.run(BalanceTable.upsert, BalanceTable.values(balance, account: account)) }
        change { $0.balances[account] = balance }
    }

    public func apply(_ merge: TransactionMerger.Result) throws {
        guard !merge.isEmpty else { return }
        try write { db in try Self.write(merge, to: db) }
        change { $0.apply(merge) }
    }

    /// One transaction, one published snapshot for everything a sync delivered for the account.
    public func apply(_ update: AccountUpdate) throws {
        var next = state
        let merge = next.apply(update)
        try write { db in
            try db.run(BalanceTable.upsert, BalanceTable.values(update.balance, account: update.accountID))
            try Self.write(merge, to: db)
            if let statements = update.cardStatements {
                try db.run("DELETE FROM cardStatement WHERE accountID = ?", [.text(update.accountID.rawValue)])
                for statement in statements {
                    try db.run(CardStatementTable.insert, CardStatementTable.values(statement))
                }
            }
            if let positions = update.securities {
                try db.run("DELETE FROM securityPosition WHERE accountID = ?", [.text(update.accountID.rawValue)])
                for position in positions {
                    try db.run(SecurityPositionTable.insert, SecurityPositionTable.values(position))
                }
            }
            if let point = DepotValuePoint.recorded(from: update) {
                try db.run(DepotValueTable.upsert, DepotValueTable.values(point))
            }
        }
        change { $0 = next }
    }

    public func recordDepotValues(_ points: [DepotValuePoint]) throws {
        guard !points.isEmpty else { return }
        try write { db in
            for point in points { try db.run(DepotValueTable.upsert, DepotValueTable.values(point)) }
        }
        change { $0.record(points) }
    }

    private static func write(_ merge: TransactionMerger.Result, to db: SQLiteConnection) throws {
        for id in merge.deletions {
            try db.run("DELETE FROM ledgerTransaction WHERE id = ?", [.text(id.rawValue)])
        }
        for transaction in merge.upserts {
            try db.run(TransactionTable.upsert, TransactionTable.values(transaction))
        }
    }

    public func replaceCardStatements(_ statements: [CardStatement], of account: AccountID) throws {
        try write { db in
            try db.run("DELETE FROM cardStatement WHERE accountID = ?", [.text(account.rawValue)])
            for statement in statements {
                try db.run(CardStatementTable.insert, CardStatementTable.values(statement))
            }
        }
        change { $0.replaceCardStatements(statements, of: account) }
    }

    public func replaceSecurities(_ positions: [SecurityPosition], of account: AccountID) throws {
        try write { db in
            try db.run("DELETE FROM securityPosition WHERE accountID = ?", [.text(account.rawValue)])
            for position in positions {
                try db.run(SecurityPositionTable.insert, SecurityPositionTable.values(position))
            }
        }
        change { $0.replaceSecurities(positions, of: account) }
    }

    public func setSyncState(_ syncState: SyncState, for connection: ConnectionID) throws {
        try write { try $0.run(SyncStateTable.upsert, try SyncStateTable.values(syncState, connection: connection)) }
        change { $0.syncStates[connection] = syncState }
    }

    public func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for transaction: TransactionID) throws {
        var next = state
        guard let updated = next.setCategory(category, source: source, confidence: confidence, for: transaction) else { return }
        try write { try $0.run(TransactionTable.upsert, TransactionTable.values(updated)) }
        change { $0 = next }
    }

    public func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for transactions: Set<TransactionID>) throws {
        var next = state
        let changed = next.setCategory(category, source: source, confidence: confidence, for: transactions)
        guard !changed.isEmpty else { return }
        try write { db in
            for transaction in changed {
                try db.run(TransactionTable.upsert, TransactionTable.values(transaction))
            }
        }
        change { $0 = next }
    }

    public func setCustomName(_ name: String?, for account: AccountID) throws {
        var next = state
        next.setCustomName(name, for: account)
        try write { try Self.writeCustomName(next.customAccountNames[account], for: account, in: $0) }
        change { $0 = next }
    }

    public func setCategories(_ suggestions: [TransactionID: CategorySuggestion]) throws {
        var next = state
        let changed = next.setCategories(suggestions)
        guard !changed.isEmpty else { return }
        try write { db in
            for transaction in changed {
                try db.run(TransactionTable.upsert, TransactionTable.values(transaction))
            }
        }
        change { $0 = next }
    }

    public func clearCategories(_ ids: Set<TransactionID>) throws {
        var next = state
        let changed = next.clearCategories(ids)
        guard !changed.isEmpty else { return }
        try write { db in
            for transaction in changed {
                try db.run(TransactionTable.upsert, TransactionTable.values(transaction))
            }
        }
        change { $0 = next }
    }

    public func upsertRule(_ rule: CategoryRule) throws {
        let match: String
        do {
            match = String(decoding: try JSONEncoder().encode(rule.match), as: UTF8.self)
        } catch {
            throw StoreError.database("Regel nicht kodierbar")
        }
        try write { db in
            try db.run(
                "INSERT INTO categoryRule (id, match, categoryID, createdAt) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET match = excluded.match, categoryID = excluded.categoryID, createdAt = excluded.createdAt",
                [.text(rule.id.uuidString), .text(match), .text(rule.categoryID.rawValue), .real(rule.createdAt.timeIntervalSince1970)]
            )
        }
        change { $0.upsertRule(rule) }
    }

    public func setBudget(_ budget: AccountBudget) throws {
        try write { try Self.writeBudget(budget, in: $0) }
        change { $0.budgets[budget.accountID] = budget }
    }

    public func removeBudget(for account: AccountID) throws {
        try write { try $0.run("DELETE FROM budget WHERE accountID = ?", [.text(account.rawValue)]) }
        change { $0.budgets[account] = nil }
    }

    public func upsertPlannedItem(_ item: PlannedItem) throws {
        try write { try $0.run(PlannedItemTable.upsert, try PlannedItemTable.values(item)) }
        change { $0.upsertPlannedItem(item) }
    }

    public func removePlannedItem(_ id: UUID) throws {
        try write { try $0.run("DELETE FROM plannedItem WHERE id = ?", [.text(id.uuidString)]) }
        change { $0.removePlannedItem(id) }
    }

    public func removeRule(_ id: UUID) throws {
        try write { try $0.run("DELETE FROM categoryRule WHERE id = ?", [.text(id.uuidString)]) }
        change { $0.removeRule(id) }
    }

    // MARK: - Internals

    private func write(_ body: (SQLiteConnection) throws -> Void) throws(StoreError) {
        guard db.isOpen else { throw .closed }
        do {
            try db.transaction { try body(db) }
        } catch {
            throw Self.map(error)
        }
    }

    private func change(_ body: (inout LedgerSnapshot) -> Void) {
        body(&state)
        broadcaster.publish(state)
        publishCount += 1
    }

    private static func load(_ db: SQLiteConnection) throws -> LedgerSnapshot {
        var snapshot = LedgerSnapshot()
        snapshot.connections = try db.query("SELECT * FROM connection ORDER BY displayName").map(ConnectionTable.model)
        snapshot.accounts = try db.query("SELECT * FROM account ORDER BY position").map(AccountTable.model)
        for row in try db.query("SELECT * FROM balance") {
            let (account, balance) = try BalanceTable.model(row)
            snapshot.balances[account] = balance
        }
        snapshot.transactions = try db.query("SELECT * FROM ledgerTransaction").map(TransactionTable.model).sorted(by: LedgerSnapshot.newestFirst)
        snapshot.cardStatements = try db.query("SELECT * FROM cardStatement ORDER BY periodEnd DESC").map(CardStatementTable.model)
        snapshot.securities = try db.query("SELECT * FROM securityPosition").map(SecurityPositionTable.model)
        for point in try db.query("SELECT * FROM depotValue ORDER BY day").map(DepotValueTable.model) {
            snapshot.depotHistory[point.accountID, default: []].append(point)
        }
        for row in try db.query("SELECT * FROM categoryRule ORDER BY createdAt DESC") {
            guard let id = UUID(uuidString: try row.string("id")),
                  let match = try? JSONDecoder().decode(CategoryRule.Match.self, from: Data(try row.string("match").utf8)) else {
                throw StoreError.corruptRow("categoryRule")
            }
            snapshot.categoryRules.append(CategoryRule(
                id: id, match: match, categoryID: CategoryID(try row.string("categoryID")),
                createdAt: Date(timeIntervalSince1970: try row.double("createdAt"))
            ))
        }
        for row in try db.query("SELECT * FROM budget") {
            guard let period = AccountBudget.Period(rawValue: try row.string("period")) else { throw StoreError.corruptRow("budget") }
            let account = AccountID(try row.string("accountID"))
            let tolerance = try row.optionalInt("anchorTolerance")
            let anchor = try tolerance.map { AccountBudget.IncomeAnchor(toleranceDays: $0, counterpart: try row.optionalString("anchorCounterpart")) }
            snapshot.budgets[account] = AccountBudget(accountID: account, amountCents: try row.int("amountCents"), period: period, startDay: try row.int("startDay"), anchor: anchor)
        }
        snapshot.plannedItems = try db.query("SELECT * FROM plannedItem ORDER BY day, createdAt").map(PlannedItemTable.model)
        for row in try db.query("SELECT accountID, name FROM accountName") {
            snapshot.customAccountNames[AccountID(try row.string("accountID"))] = try row.string("name")
        }
        for row in try db.query("SELECT * FROM syncState") {
            let (connection, syncState) = try SyncStateTable.model(row)
            snapshot.syncStates[connection] = syncState
        }
        return snapshot
    }

    private static func map(_ error: any Error) -> StoreError {
        switch error {
        case let error as StoreError:
            return error
        case let error as SQLiteError where error.isNotADatabase:
            return .cannotDecrypt
        default:
            // SQLite messages name tables/columns/constraints, never bound values.
            return .database(String(describing: error))
        }
    }
}
