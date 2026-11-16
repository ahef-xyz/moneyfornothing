import Foundation
import MFNCore
import Testing
@testable import MFNStore

/// CSV import batches (protocol v10): migration backfill, round trip, removal of imported rows.
@Suite struct ImportBatchStoreTests {
    private let key = Data((0..<32).map { UInt8(($0 * 7) & 0xFF) })

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mfn-import-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(EncryptedLedgerStore.fileName)
    }

    private static let connection = Connection(id: "c-test", connectorID: .mock, displayName: "Testbank")
    private static let giro = Account(id: "a-giro", connectionID: "c-test", iban: "DE00 0000 0000 0000 0000 01", type: .giro, name: "Giro")
    private static let card = Account(id: "a-card", connectionID: "c-test", type: .card, name: "Karte")

    private static func day(_ iso: String) -> BankDay { BankDay(iso: iso) ?? .today }

    private static let csvRaw = Data(#"{"format":"ing","row":{"Betrag":"-12,50"},"source":"csv"}"#.utf8)

    private static func bankRow(_ purpose: String, account: AccountID = "a-giro", raw: Data = Data(#"{"n":1}"#.utf8)) -> Transaction {
        Transaction(accountID: account, bookingDate: day("2026-05-04"), valueDate: day("2026-05-04"), amountCents: -1_000,
                    counterpartName: "Bank", purpose: purpose, status: .booked, rawJSON: raw)
    }

    private static func importedRow(_ purpose: String, batch: ImportBatchID, account: AccountID = "a-giro") -> Transaction {
        Transaction(accountID: account, bookingDate: day("2026-04-02"), valueDate: day("2026-04-02"), amountCents: -1_250,
                    counterpartName: "Import", purpose: purpose, status: .booked, rawJSON: csvRaw,
                    categoryID: "lebensmittel", categorySource: .manual, importID: batch)
    }

    private func fill(_ store: some LedgerStore) async throws {
        try await store.upsert(connection: Self.connection)
        try await store.replaceAccounts([Self.giro, Self.card], of: Self.connection.id)
        try await store.apply(TransactionMerger.merge(stored: [], incoming: [Self.bankRow("Miete"), Self.bankRow("Strom")], since: nil))
    }

    private func importBatch(_ store: some LedgerStore, rows purposes: [String], account: AccountID = "a-giro") async throws -> ImportBatch {
        let batch = ImportBatch(accountID: account, importedAt: Date(timeIntervalSince1970: 1_800_000_000), format: "ing",
                                fileName: "umsaetze.csv", encoding: "windows-1252", rowCount: purposes.count)
        let rows = purposes.map { Self.importedRow($0, batch: batch.id, account: account) }
        let stored = await store.storedTransactions(of: account)
        try await store.recordImport(batch, merge: CSVImportPlan.merge(rows, into: stored))
        return batch
    }

    @Test func syncTakeoverOfAllImportedRowsDeletesTheBatchOnDisk() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: key)
        try await fill(store)
        let batch = try await importBatch(store, rows: ["Altbestand"])
        let imported = try #require(await store.snapshot().transactions(ofImport: batch.id).first)
        // The same booking from the bank: same ID, no importID.
        let takeover = Transaction(id: imported.id, accountID: imported.accountID, bookingDate: imported.bookingDate, valueDate: imported.valueDate,
                                   amountCents: imported.amountCents, counterpartName: imported.counterpartName, purpose: imported.purpose, status: .booked)
        let merge = TransactionMerger.merge(stored: await store.storedTransactions(of: "a-giro"), incoming: [takeover], since: nil)
        #expect(merge.upserts.map(\.id) == [takeover.id])
        try await store.apply(merge)
        #expect(await store.snapshot().importBatches.isEmpty)
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: key)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.importBatches.isEmpty)
        #expect(snapshot.transaction(takeover.id)?.importID == nil)
    }

    @Test func batchAndImportIDSurviveReopen() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: key)
        try await fill(store)
        let batch = try await importBatch(store, rows: ["Altbestand 1", "Altbestand 2"])
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: key)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.importBatches == [batch])
        #expect(snapshot.transactions(ofImport: batch.id).count == 2)
        #expect(snapshot.transactions.filter(\.isImported).count == 2)
        #expect(snapshot.transactions.filter { !$0.isImported }.count == 2)
        await reopened.close()
    }

    @Test func removalOfImportedRowsPersistsAndDropsEmptyBatch() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: key)
        try await fill(store)
        let batch = try await importBatch(store, rows: ["A", "B", "C"])
        let imported = await store.snapshot().transactions(ofImport: batch.id).map(\.id)

        // Part of the batch: the batch stays.
        let first = try await store.removeImportedTransactions([imported[0]])
        #expect(first.transactions == [imported[0]])
        #expect(first.emptiedBatches.isEmpty)
        #expect(first.accounts == ["a-giro"])
        #expect(await store.snapshot().importBatch(batch.id) != nil)

        // The rest: the batch goes too.
        let rest = try await store.removeImportedTransactions(Set(imported.dropFirst()))
        #expect(rest.emptiedBatches == [batch.id])
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: key)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.importBatches.isEmpty)
        #expect(snapshot.transactions.count == 2)
        #expect(!snapshot.transactions.contains { $0.isImported })
        await reopened.close()
    }

    @Test func bankRowsAreNeverRemoved() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: key)
        try await fill(store)
        let batch = try await importBatch(store, rows: ["A"])
        let snapshot = await store.snapshot()
        let bank = try #require(snapshot.transactions.first { !$0.isImported })
        let imported = try #require(snapshot.transactions(ofImport: batch.id).first)

        // Mixed selection: refused as a whole, nothing removed.
        await #expect(throws: TransactionRemovalError.notImported([bank.id])) {
            try await store.removeImportedTransactions([bank.id, imported.id])
        }
        #expect(await store.snapshot().transactions.count == 3)
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: key)
        #expect(await reopened.snapshot().transactions.count == 3)
        await reopened.close()
    }

    @Test func inMemoryStoreBehavesTheSame() async throws {
        let store = InMemoryLedgerStore()
        try await fill(store)
        let batch = try await importBatch(store, rows: ["A", "B"])
        let snapshot = await store.snapshot()
        let bank = try #require(snapshot.transactions.first { !$0.isImported })
        await #expect(throws: TransactionRemovalError.notImported([bank.id])) {
            try await store.removeImportedTransactions([bank.id])
        }
        let removal = try await store.removeImportedTransactions(Set(snapshot.transactions(ofImport: batch.id).map(\.id)))
        #expect(removal.transactions.count == 2)
        #expect(removal.emptiedBatches == [batch.id])
        #expect(await store.snapshot().importBatches.isEmpty)
        #expect(await store.snapshot().transactions.count == 2)
    }

    @Test func removingTheConnectionDropsItsBatches() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: key)
        try await fill(store)
        _ = try await importBatch(store, rows: ["A"])
        try await store.removeConnection(Self.connection.id)
        #expect(await store.snapshot().importBatches.isEmpty)
        await store.close()
        let reopened = try await EncryptedLedgerStore.open(at: url, key: key)
        #expect(await reopened.snapshot().importBatches.isEmpty)
        await reopened.close()
    }

    /// A database from before v10: CSV rows are found by their `rawJSON` and get one batch per account.
    @Test func migrationBackfillsOneBatchPerAccount() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = try #require(Schema.migrations.firstIndex(of: Schema.importBatchMigration))
        var passphrase = key.sqlCipherRawKey
        defer { passphrase.wipe() }
        let db = try SQLiteConnection(path: url.path, passphrase: passphrase)
        try db.execute("PRAGMA foreign_keys = ON;")
        for (index, sql) in Schema.migrations.enumerated() where index < target {
            try db.execute(sql)
            try db.execute("PRAGMA user_version = \(index + 1)")
        }
        try db.run(ConnectionTable.upsert, ConnectionTable.values(Self.connection))
        try db.run(AccountTable.upsert, AccountTable.values(Self.giro, position: 0))
        try db.run(AccountTable.upsert, AccountTable.values(Self.card, position: 1))
        // Old rows: written without the importID column.
        let oldColumns = TransactionTable.columns.filter { $0 != "importID" }
        let insert = "INSERT INTO ledgerTransaction (\(oldColumns.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: oldColumns.count).joined(separator: ", ")))"
        func write(_ transaction: Transaction) throws {
            try db.run(insert, Array(TransactionTable.values(transaction).dropLast()))
        }
        let otherFormat = Data(#"{"format":"dkb","row":{"Betrag":"-1,00"},"source":"csv"}"#.utf8)
        let csvA = Transaction(accountID: "a-giro", bookingDate: Self.day("2026-03-01"), valueDate: Self.day("2026-03-01"), amountCents: -100, counterpartName: "Alt", purpose: "A", status: .booked, rawJSON: Self.csvRaw)
        let csvB = Transaction(accountID: "a-giro", bookingDate: Self.day("2026-03-02"), valueDate: Self.day("2026-03-02"), amountCents: -200, counterpartName: "Alt", purpose: "B", status: .booked, rawJSON: Self.csvRaw)
        let csvCard1 = Transaction(accountID: "a-card", bookingDate: Self.day("2026-03-03"), valueDate: Self.day("2026-03-03"), amountCents: -300, counterpartName: "Alt", purpose: "C", status: .booked, rawJSON: Self.csvRaw)
        let csvCard2 = Transaction(accountID: "a-card", bookingDate: Self.day("2026-03-04"), valueDate: Self.day("2026-03-04"), amountCents: -400, counterpartName: "Alt", purpose: "D", status: .booked, rawJSON: otherFormat)
        // Bank rows: a nested "source":"csv" and broken JSON must not count.
        let nested = Self.bankRow("E", raw: Data(#"{"detail":{"source":"csv","row":{}}}"#.utf8))
        let broken = Self.bankRow("F", raw: Data("not json".utf8))
        for transaction in [csvA, csvB, csvCard1, csvCard2, nested, broken] { try write(transaction) }
        db.close()

        let store = try await EncryptedLedgerStore.open(at: url, key: key)
        let snapshot = await store.snapshot()
        let giroBatch = try #require(snapshot.importBatch(ImportBatch.backfillID(for: "a-giro")))
        let cardBatch = try #require(snapshot.importBatch(ImportBatch.backfillID(for: "a-card")))
        #expect(snapshot.importBatches.count == 2)
        #expect(giroBatch.rowCount == 2)
        #expect(giroBatch.format == "ing")
        #expect(giroBatch.fileName == nil)
        #expect(abs(giroBatch.importedAt.timeIntervalSinceNow) < 120)
        // Mixed formats: none recorded.
        #expect(cardBatch.rowCount == 2)
        #expect(cardBatch.format == nil)
        #expect(Set(snapshot.transactions(ofImport: giroBatch.id).map(\.id)) == [csvA.id, csvB.id])
        #expect(Set(snapshot.transactions(ofImport: cardBatch.id).map(\.id)) == [csvCard1.id, csvCard2.id])
        #expect(snapshot.transactions.first { $0.id == nested.id }?.importID == nil)
        #expect(snapshot.transactions.first { $0.id == broken.id }?.importID == nil)
        await store.close()
    }
}
