import CryptoKit
import Foundation
import MFNCore

public enum StoreError: Error, Equatable, Sendable {
    /// SQLCipher is not active (e.g. the system SQLite got linked instead): refuse to store data.
    case encryptionUnavailable
    /// Wrong key or not a MFN database.
    case cannotDecrypt
    /// Column (or table) name only, never the cell value: the message may reach logs and UI.
    case corruptRow(String)
    case closed
    /// The database was migrated by a newer MFN (schema `found` > `supported`); left untouched.
    case newerSchema(found: Int, supported: Int)
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

    /// Derived from the database key, for what a backup carries next to the database
    /// (`LedgerBackup.sealingKey`). Kept so writing a backup never asks the keychain.
    private var sealingKey: SymmetricKey?
    /// Derived from the database key as well: keys hashes the app keeps in its preferences
    /// (`preferenceHashKey`). Both go when the store closes.
    private var hashKey: SymmetricKey?

    private init(db: sending SQLiteConnection, url: URL, state: LedgerSnapshot, sealingKey: SymmetricKey, hashKey: SymmetricKey) {
        self.db = db
        self.url = url
        self.state = state
        self.sealingKey = sealingKey
        self.hashKey = hashKey
    }

    /// Key for HMACs of things that must not be readable outside the database but have to be
    /// recognised by the app's preferences (hidden fixed costs). `nil` once closed.
    public func preferenceHashKey() -> SymmetricKey? { hashKey }

    /// Encrypts `data` for a backup of this database (AES-GCM). Opened again with the database
    /// key by `LedgerBackup.unseal`.
    public func seal(_ data: Data) throws(StoreError) -> Data {
        guard db.isOpen, let sealingKey else { throw .closed }
        guard let sealed = try? AES.GCM.seal(data, using: sealingKey).combined else { throw .database("Sicherung: Verschlüsselung") }
        return sealed
    }

    /// How long the copies MFN leaves next to the database stay (before a schema update, before
    /// a restore). They hold the data as it was, also what the user removed since.
    static let copyLifetimeDays = 30
    static let preRestorePrefix = "ledger-vor-wiederherstellung-"

    /// Removes those copies once they are older than `copyLifetimeDays`.
    static func removeOutdatedCopies(in folder: URL, now: Date = Date()) {
        let files = FileManager.default
        let limit = now.addingTimeInterval(-Double(copyLifetimeDays) * 86_400)
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(preMigrationPrefix) || name.hasPrefix(preRestorePrefix) {
            let file = folder.appendingPathComponent(name)
            guard let changed = (try? files.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date, changed < limit else { continue }
            try? files.removeItem(at: file)
            Log.store.info("Alte Kopie der Datenbank entfernt")
        }
    }

    /// Prefix of the copy a schema update leaves next to the database.
    static let preMigrationPrefix = "ledger-vor-update-schema-"

    /// Before a schema update changes an existing database: one copy of it as it is, next to
    /// it (`ledger-vor-update-schema-<version>.sqlite`, same key). An older MFN can open that
    /// copy, never the updated database. Only the newest copy is kept.
    private static func keepCopyBeforeMigration(of url: URL, _ db: SQLiteConnection) throws {
        let current = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        guard current > 0, current < Schema.migrations.count else { return }
        let files = FileManager.default
        let folder = url.deletingLastPathComponent()
        let name = "\(preMigrationPrefix)\(current).sqlite"
        let copy = folder.appendingPathComponent(name)
        // Written under another name first: an older copy stays until the new one is complete.
        let fresh = folder.appendingPathComponent("\(name).neu")
        try? files.removeItem(at: fresh)
        // Columns: busy, log, checkpointed. busy = 1: pages stayed in the WAL, the copy would miss them.
        let result = try db.query("PRAGMA wal_checkpoint(TRUNCATE)").first
        guard try result?.int("busy") == 0 else { throw StoreError.database("Kopie vor dem Update: WAL nicht vollständig übernommen") }
        do {
            try files.copyItem(at: url, to: fresh)
            for other in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where other.hasPrefix(preMigrationPrefix) && other != fresh.lastPathComponent {
                try? files.removeItem(at: folder.appendingPathComponent(other))
            }
            try files.moveItem(at: fresh, to: copy)
        } catch {
            try? files.removeItem(at: fresh)
            throw StoreError.database("Kopie vor dem Update: \(error.localizedDescription)")
        }
        Log.store.info("Kopie vor dem Schema-Update angelegt (Version \(current, privacy: .public))")
    }

    /// Opens (or creates) the database at `url` with the 256-bit `key`, migrates it and loads
    /// the snapshot. Use `LedgerVault` to obtain the key; it is not retained.
    ///
    /// `keepingCopy`: leave a copy of an older database next to it before the schema update
    /// (`keepCopyBeforeMigration`). Off for a backup being unpacked: the backup file is that copy.
    public static func open(at url: URL, key: Data, keepingCopy: Bool = true) async throws(StoreError) -> EncryptedLedgerStore {
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
            // WAL with synchronous = NORMAL: the database stays consistent after a crash or power
            // loss (only the last commits may be missing, and a sync brings them back), without
            // an fsync per commit.
            try db.execute("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
            if keepingCopy {
                try keepCopyBeforeMigration(of: url, db)
                removeOutdatedCopies(in: url.deletingLastPathComponent())
            }
            try Schema.migrate(db)
            let snapshot = try load(db)
            Log.store.info("Datenbank geöffnet (SQLCipher \(cipherVersion, privacy: .public), \(snapshot.transactions.count, privacy: .public) Buchungen)")
            return EncryptedLedgerStore(db: db, url: url, state: snapshot, sealingKey: LedgerBackup.sealingKey(for: key),
                                        hashKey: LedgerBackup.preferenceHashKey(for: key))
        } catch {
            throw map(error)
        }
    }

    /// Closes the database. Called when the app locks.
    public func close() {
        guard db.isOpen else { return }
        db.close()
        // Nothing derived from the database key outlives the lock.
        sealingKey = nil
        hashKey = nil
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
        // Computed from the current state without copying it; the state changes only after commit.
        let moved = Dictionary(changes.moves.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let categorized: [Transaction] = changes.categories.compactMap { id, change in
            guard var transaction = moved[id] ?? state.transaction(id) else { return nil }
            transaction.categoryID = change.categoryID
            transaction.categorySource = change.source
            transaction.confidence = change.confidence
            return transaction
        }
        let sourceAccounts = state.accounts(of: changes.source).map(\.id)
        try write { db in
            for transaction in changes.moves + categorized {
                try db.run(TransactionTable.upsert, TransactionTable.values(transaction))
            }
            for (account, name) in changes.names {
                try Self.writeCustomName(LedgerSnapshot.normalizedCustomName(name), for: account, in: db)
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
            for entry in changes.recurringEntries {
                try db.run(RecurringEntryTable.upsert, RecurringEntryTable.values(entry))
            }
            // Re-pointed before the source accounts go (their batches would cascade otherwise).
            for batch in changes.importBatches {
                try db.run(ImportBatchTable.upsert, ImportBatchTable.values(batch))
            }
            try Self.deleteConnection(changes.source, accounts: sourceAccounts, in: db)
            for id in changes.newMarks where state.transaction(id) != nil {
                try db.run("INSERT OR IGNORE INTO newTransaction (id) VALUES (?)", [.text(id.rawValue)])
            }
        }
        change { $0.applyMerge(changes) }
    }

    private static func deleteImportBatches(_ batches: Set<ImportBatchID>, in db: SQLiteConnection) throws {
        for batch in batches {
            try db.run("DELETE FROM importBatch WHERE id = ?", [.text(batch.rawValue)])
        }
    }

    private static func deleteConnection(_ id: ConnectionID, accounts: [AccountID], in db: SQLiteConnection) throws {
        for account in accounts {
            for table in ["ledgerTransaction", "cardStatement", "securityPosition", "balance", "accountName", "budget", "depotValue", "plannedItem", "recurringEntry", "openingBalance", "importBatch"] {
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
        let merged = state.accountsReplacing(accounts, of: connection)
        try write { db in
            for (position, account) in merged.enumerated() where account.connectionID == connection {
                try db.run(AccountTable.upsert, AccountTable.values(account, position: position))
            }
        }
        change { $0.accounts = merged }
    }

    public func setBalance(_ balance: Balance, for account: AccountID) throws {
        try write { try $0.run(BalanceTable.upsert, BalanceTable.values(balance, account: account)) }
        change { $0.balances[account] = balance }
    }

    public func setOpeningBalance(_ opening: OpeningBalance?, for account: AccountID) throws {
        try write { db in
            if let opening {
                try db.run(OpeningBalanceTable.upsert, OpeningBalanceTable.values(opening, account: account))
            } else {
                try db.run("DELETE FROM openingBalance WHERE accountID = ?", [.text(account.rawValue)])
            }
        }
        change { $0.openingBalances[account] = opening }
    }

    public func apply(_ merge: TransactionMerger.Result) throws {
        guard !merge.isEmpty else { return }
        let emptied = state.importBatchesEmptied(by: merge)
        try write { db in try Self.write(merge, emptying: emptied, to: db) }
        change { $0.apply(merge) }
    }

    /// One transaction, one published snapshot for everything a sync delivered for the account.
    public func apply(_ update: AccountUpdate) throws {
        let merge = state.merge(for: update)
        let emptied = state.importBatchesEmptied(by: merge)
        // Deleted rows take their mark along (`ON DELETE CASCADE`); only additions are written.
        let fresh = state.newTransactionIDs(after: update, merge: merge)
        let added = fresh.subtracting(state.newTransactionIDs)
        try write { db in
            try db.run(BalanceTable.upsert, BalanceTable.values(update.balance, account: update.accountID))
            try Self.write(merge, emptying: emptied, to: db)
            for id in added {
                try db.run("INSERT OR IGNORE INTO newTransaction (id) VALUES (?)", [.text(id.rawValue)])
            }
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
        change { $0.apply(update, merge: merge, newTransactionIDs: fresh) }
    }

    public func recordDepotValues(_ points: [DepotValuePoint]) throws {
        guard !points.isEmpty else { return }
        try write { db in
            for point in points { try db.run(DepotValueTable.upsert, DepotValueTable.values(point)) }
        }
        change { $0.record(points) }
    }

    /// The merge plus the import batches it leaves without rows (`importBatchesEmptied(by:)`).
    private static func write(_ merge: TransactionMerger.Result, emptying emptied: Set<ImportBatchID>, to db: SQLiteConnection) throws {
        for id in merge.deletions {
            try db.run("DELETE FROM ledgerTransaction WHERE id = ?", [.text(id.rawValue)])
        }
        for transaction in merge.upserts {
            try db.run(TransactionTable.upsert, TransactionTable.values(transaction))
        }
        try deleteImportBatches(emptied, in: db)
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

    // Category writes: the changed rows are computed without touching the state, written, and
    // only then put in place (no `var next = state` copy of the whole transaction list).

    public func markSeen(_ ids: Set<TransactionID>) throws {
        let seen = state.newTransactionIDs.intersection(ids)
        guard !seen.isEmpty else { return }
        try write { db in
            for id in seen { try db.run("DELETE FROM newTransaction WHERE id = ?", [.text(id.rawValue)]) }
        }
        change { $0.markSeen(seen) }
    }

    public func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for transaction: TransactionID) throws {
        try setCategory(category, source: source, confidence: confidence, for: [transaction] as Set<TransactionID>)
    }

    public func setCategory(_ category: CategoryID?, source: CategorySource, confidence: Double?, for transactions: Set<TransactionID>) throws {
        try writeChangedRows(state.categoryChanges(category, source: source, confidence: confidence, for: transactions))
    }

    public func setCustomName(_ name: String?, for account: AccountID) throws {
        let normalized = LedgerSnapshot.normalizedCustomName(name)
        try write { try Self.writeCustomName(normalized, for: account, in: $0) }
        change { $0.customAccountNames[account] = normalized }
    }

    public func setCategories(_ suggestions: [TransactionID: CategorySuggestion]) throws {
        try writeChangedRows(state.categoryChanges(suggestions))
    }

    public func clearCategories(_ ids: Set<TransactionID>) throws {
        try writeChangedRows(state.clearedCategoryChanges(ids))
    }

    public func setCategories(_ suggestions: [TransactionID: CategorySuggestion], expecting: [TransactionID: CategoryStamp]) throws {
        try writeChangedRows(state.categoryChanges(suggestions, expecting: expecting))
    }

    public func clearCategories(_ ids: Set<TransactionID>, expecting: [TransactionID: CategoryStamp]) throws {
        try writeChangedRows(state.clearedCategoryChanges(ids, expecting: expecting))
    }

    /// Persists rows from the snapshot's `…Changes` methods, then puts them in place in the state.
    private func writeChangedRows(_ changed: [Transaction]) throws {
        guard !changed.isEmpty else { return }
        try write { db in
            for transaction in changed {
                try db.run(TransactionTable.upsert, TransactionTable.values(transaction))
            }
        }
        change { $0.replaceCategorized(changed) }
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

    public func upsertRecurringEntry(_ entry: RecurringEntry) throws {
        try write { db in
            // One change per detected payment.
            if let series = entry.seriesID {
                try db.run("DELETE FROM recurringEntry WHERE seriesID = ? AND id != ?", [.text(series), .text(entry.id.uuidString)])
            }
            try db.run(RecurringEntryTable.upsert, RecurringEntryTable.values(entry))
        }
        change { $0.upsertRecurringEntry(entry) }
    }

    public func removeRecurringEntry(_ id: UUID) throws {
        try write { try $0.run("DELETE FROM recurringEntry WHERE id = ?", [.text(id.uuidString)]) }
        change { $0.removeRecurringEntry(id) }
    }

    public func removePlannedItem(_ id: UUID) throws {
        try write { try $0.run("DELETE FROM plannedItem WHERE id = ?", [.text(id.uuidString)]) }
        change { $0.removePlannedItem(id) }
    }

    public func recordImport(_ batch: ImportBatch, merge: TransactionMerger.Result) throws {
        let emptied = state.importBatchesEmptied(by: merge)
        try write { db in
            try db.run(ImportBatchTable.upsert, ImportBatchTable.values(batch))
            try Self.write(merge, emptying: emptied, to: db)
        }
        change { $0.recordImport(batch, merge: merge) }
    }

    @discardableResult
    public func removeImportedTransactions(_ ids: Set<TransactionID>) throws -> LedgerSnapshot.ImportRemoval {
        let removal = try state.importRemoval(ids)
        guard !removal.isEmpty else { return removal }
        try write { db in
            for id in removal.transactions {
                // `importID IS NOT NULL` again in SQL: bank rows are never deleted here.
                try db.run("DELETE FROM ledgerTransaction WHERE id = ? AND importID IS NOT NULL", [.text(id.rawValue)])
            }
            for batch in removal.emptiedBatches {
                try db.run("DELETE FROM importBatch WHERE id = ?", [.text(batch.rawValue)])
            }
        }
        change { $0.apply(removal) }
        return removal
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
        // Same order as `LedgerSnapshot.newestFirst` (effective date = booking date, else value
        // date, descending; then ID ascending), so no sort afterwards. ISO dates sort as text.
        let rows = try db.query("SELECT * FROM ledgerTransaction ORDER BY coalesce(bookingDate, valueDate) DESC, id ASC")
        var transactions: [Transaction] = []
        transactions.reserveCapacity(rows.count)
        for row in rows { transactions.append(try TransactionTable.model(row)) }
        // Safety net (linear check): SQLite's byte order of IDs must match Swift's string order.
        if zip(transactions, transactions.dropFirst()).contains(where: { LedgerSnapshot.newestFirst($1, $0) }) {
            transactions.sort(by: LedgerSnapshot.newestFirst)
        }
        snapshot.transactions = transactions
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
        snapshot.recurringEntries = try db.query("SELECT * FROM recurringEntry ORDER BY createdAt, id").map(RecurringEntryTable.model)
        for row in try db.query("SELECT * FROM openingBalance") {
            let (account, opening) = try OpeningBalanceTable.model(row)
            snapshot.openingBalances[account] = opening
        }
        snapshot.importBatches = try db.query("SELECT * FROM importBatch ORDER BY importedAt, id").map(ImportBatchTable.model)
        for row in try db.query("SELECT accountID, name FROM accountName") {
            snapshot.customAccountNames[AccountID(try row.string("accountID"))] = try row.string("name")
        }
        snapshot.newTransactionIDs = Set(try db.query("SELECT id FROM newTransaction").map { TransactionID(try $0.string("id")) })
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
