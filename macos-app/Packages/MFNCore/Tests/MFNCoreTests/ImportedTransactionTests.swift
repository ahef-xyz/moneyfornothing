import Foundation
import Testing
@testable import MFNCore

/// CSV-imported rows (protocol v10, `Transaction.importID`): synthetic data only.
@Suite struct ImportedTransactionTests {
    static let account = Account(id: "acc-1", connectionID: "conn-1", type: .giro, name: "Giro")

    static func day(_ iso: String) -> BankDay { BankDay(iso: iso) ?? .today }

    static func row(_ purpose: String, importID: ImportBatchID? = nil, amount: Int = -500) -> Transaction {
        Transaction(accountID: account.id, bookingDate: day("2026-05-04"), valueDate: day("2026-05-04"), amountCents: amount,
                    counterpartName: "Muster", purpose: purpose, status: .booked, importID: importID)
    }

    @Test func importIDRoundTripsThroughJSONAndOlderJSONDecodesAsBankData() throws {
        let imported = Self.row("A", importID: "import:1")
        let decoded = try JSONDecoder().decode(Transaction.self, from: JSONEncoder().encode(imported))
        #expect(decoded == imported)
        #expect(decoded.isImported)

        // JSON from before v10 has no `importID` key.
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.row("B"))) as? [String: Any])
        object["importID"] = nil
        let old = try JSONDecoder().decode(Transaction.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.importID == nil)
        #expect(!old.isImported)
    }

    @Test func uniquingIDsKeepsTheImportID() {
        let rows = Transaction.uniquingIDs([Self.row("A", importID: "import:1"), Self.row("A", importID: "import:1")])
        #expect(rows.map(\.importID) == ["import:1", "import:1"])
        #expect(rows[1].id.rawValue.hasSuffix("#2"))
    }

    @Test func queryFiltersImportedRows() {
        let rows = [Self.row("A", importID: "import:1"), Self.row("B"), Self.row("C", importID: "import:2", amount: 900)]
        var query = TransactionQuery()
        #expect(!query.isFiltering)
        query.onlyImported = true
        #expect(query.isFiltering)
        #expect(query.filter(rows).map(\.purpose) == ["A", "C"])
        query.direction = .inflow
        #expect(query.filter(rows).map(\.purpose) == ["C"])
        query.onlyImported = false
        #expect(query.filter(rows).map(\.purpose) == ["C"])
    }

    @Test func importerSetsTheBatchOnEveryRow() throws {
        let csv = "Buchungstag;Betrag;Verwendungszweck\r\n01.03.2026;-1,00;A\r\n02.03.2026;-2,00;B\r\n"
        let document = try CSVDocument(data: Data(csv.utf8))
        #expect(document.transactions(for: Self.account).transactions.allSatisfy { $0.importID == nil })
        let rows = document.transactions(for: Self.account, importID: "import:7").transactions
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.importID == "import:7" })
    }

    @Test func categoryFromTheFileIsRecognisedUntilTheUserChangesIt() throws {
        let csv = "Buchungstag;Betrag;Verwendungszweck;Kategorie;Konto;Kategorie-ID\r\n01.03.2026;-1,00;A;Lebensmittel;Giro;lebensmittel\r\n02.03.2026;-2,00;B;;Giro;\r\n"
        let document = try CSVDocument(data: Data(csv.utf8))
        let rows = document.transactions(for: Self.account, importID: "import:1").transactions
        let withCategory = try #require(rows.first { $0.purpose == "A" })
        #expect(withCategory.categoryID == "lebensmittel")
        #expect(withCategory.categoryFromImportFile == "lebensmittel")
        #expect(withCategory.categoryCameFromImport)

        var corrected = withCategory
        corrected.categoryID = "restaurant"
        #expect(!corrected.categoryCameFromImport)

        let without = try #require(rows.first { $0.purpose == "B" })
        #expect(without.categoryFromImportFile == nil)
        #expect(!without.categoryCameFromImport)
        // Bank rows never claim an import category.
        #expect(!Self.row("C").categoryCameFromImport)
    }

    @Test func removalPlanRefusesBankRowsAndFindsEmptiedBatches() throws {
        var snapshot = LedgerSnapshot()
        snapshot.accounts = [Self.account]
        let one = ImportBatch(id: "import:1", accountID: Self.account.id, format: nil, fileName: nil, encoding: nil, rowCount: 2)
        let two = ImportBatch(id: "import:2", accountID: Self.account.id, format: "ing", fileName: nil, encoding: nil, rowCount: 1)
        let a = Self.row("A", importID: one.id), b = Self.row("B", importID: one.id), c = Self.row("C", importID: two.id)
        let bank = Self.row("D")
        snapshot.recordImport(one, merge: TransactionMerger.Result(upserts: [a, b, bank]))
        snapshot.recordImport(two, merge: TransactionMerger.Result(upserts: [c]))

        #expect(throws: TransactionRemovalError.notImported([bank.id])) { try snapshot.importRemoval([a.id, bank.id]) }

        let partial = try snapshot.importRemoval([a.id, c.id, "unknown"])
        #expect(partial.transactions == [a.id, c.id])
        #expect(partial.emptiedBatches == [two.id])
        snapshot.apply(partial)
        #expect(snapshot.importBatches.map(\.id) == [one.id])
        #expect(Set(snapshot.transactions.map(\.id)) == [b.id, bank.id])
        #expect(snapshot.transactions(ofImport: one.id).map(\.id) == [b.id])
    }

    @Test func syncTakingOverTheLastImportedRowsDropsTheBatch() {
        var snapshot = LedgerSnapshot()
        snapshot.accounts = [Self.account]
        let one = ImportBatch(id: "import:1", accountID: Self.account.id, format: nil, fileName: nil, encoding: nil, rowCount: 2)
        let two = ImportBatch(id: "import:2", accountID: Self.account.id, format: nil, fileName: nil, encoding: nil, rowCount: 1)
        let empty = ImportBatch(id: "import:3", accountID: Self.account.id, format: nil, fileName: nil, encoding: nil, rowCount: 0)
        let a = Self.row("A", importID: one.id), b = Self.row("B", importID: one.id), c = Self.row("C", importID: two.id)
        snapshot.recordImport(one, merge: TransactionMerger.Result(upserts: [a, b]))
        snapshot.recordImport(two, merge: TransactionMerger.Result(upserts: [c]))
        snapshot.upsert(importBatch: empty)

        // The bank delivers `a` (same ID, no importID): batch 1 keeps `b`.
        let synced = Self.row("A")
        #expect(synced.id == a.id)
        let first = TransactionMerger.Result(upserts: [synced])
        #expect(snapshot.importBatchesEmptied(by: first).isEmpty)
        snapshot.apply(first)
        #expect(snapshot.importBatches.map(\.id) == [one.id, two.id, empty.id])

        // Taking over `b` and deleting `c` empties both; the batch that never had rows stays.
        let syncedB = Self.row("B")
        let second = TransactionMerger.Result(upserts: [syncedB], deletions: [c.id])
        #expect(snapshot.importBatchesEmptied(by: second) == [one.id, two.id])
        snapshot.apply(second)
        #expect(snapshot.importBatches.map(\.id) == [empty.id])
        #expect(snapshot.transactions.allSatisfy { $0.importID == nil })
    }

    @Test func inMemoryImportForUnknownAccountThrowsImportError() async {
        let store = InMemoryLedgerStore()
        let batch = ImportBatch(id: "import:1", accountID: "unknown", format: nil, fileName: nil, encoding: nil, rowCount: 0)
        await #expect(throws: ImportBatchError.unknownAccount("unknown")) {
            try await store.recordImport(batch, merge: TransactionMerger.Result())
        }
    }

    @Test func connectionMergeMovesBatchesWithTheirRows() throws {
        let web = ConnectionMergeTests.web, fints = ConnectionMergeTests.fints
        let source = Account(id: "w-giro", connectionID: web.id, iban: "DE00000000000000000001", type: .giro, name: "Giro")
        let target = Account(id: "f-giro", connectionID: fints.id, iban: "DE00000000000000000001", type: .giro, name: "Giro")
        let batch = ImportBatch(id: "import:9", accountID: source.id, format: "ing", fileName: nil, encoding: nil, rowCount: 1)
        let old = Transaction(accountID: source.id, bookingDate: Self.day("2024-01-02"), valueDate: Self.day("2024-01-02"), amountCents: -700,
                              counterpartName: "Alt", purpose: "Alt", status: .booked, importID: batch.id)
        var snapshot = ConnectionMergeTests.snapshot(accounts: [source, target], transactions: [old])
        snapshot.importBatches = [batch]
        let plan = try ConnectionMerge.plan(snapshot, source: web.id, target: fints.id)
        snapshot.applyMerge(ConnectionMerge.changes(plan, in: snapshot))
        #expect(snapshot.importBatches.map(\.accountID) == [target.id])
        #expect(snapshot.transactions.first?.accountID == target.id)
        #expect(snapshot.transactions.first?.importID == batch.id)
    }
}
