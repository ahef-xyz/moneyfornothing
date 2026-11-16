import Foundation
import MFNCore
import Testing
@testable import MFNStore

private let keyA = Data((0..<32).map { UInt8($0) })
private let keyB = Data((0..<32).map { UInt8(255 - $0) })

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mfn-store-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(EncryptedLedgerStore.fileName)
}

private func day(_ iso: String) -> BankDay { BankDay(iso: iso) ?? .today }

/// Whole seconds: the database stores dates with millisecond precision.
private let asOf = Date(timeIntervalSince1970: 1_800_000_000)

private enum Fixture {
    static let connection = Connection(id: "c-dkb", connectorID: .dkb, displayName: "DKB")
    static let giro = Account(id: "a-giro", connectionID: "c-dkb", iban: "DE00 1203 0000 0000 0000 03", type: .giro, name: "Girokonto")
    static let card = Account(id: "a-card", connectionID: "c-dkb", type: .card, name: "Visa", cardLast4: "4417", creditLimitCents: 500_000)
    static let depot = Account(id: "a-depot", connectionID: "c-dkb", type: .depot, name: "Depot")

    static let transactions: [Transaction] = [
        Transaction(accountID: "a-giro", bookingDate: day("2026-05-04"), valueDate: day("2026-05-04"), amountCents: 512_257, counterpartName: "Muster GmbH", counterpartIBAN: "DE00 3704 0044 0000 0000 10", purpose: "Gehalt Mai", eref: "LG1", status: .booked, rawJSON: Data(#"{"n":1}"#.utf8)),
        Transaction(accountID: "a-giro", bookingDate: day("2026-05-05"), valueDate: day("2026-05-05"), amountCents: -8_400, counterpartName: "Stadtwerke", purpose: "Abschlag", mref: "SWK-1", creditorID: "DE00ZZZ00000000002", status: .booked),
        Transaction(accountID: "a-card", bookingDate: nil, valueDate: day("2026-05-06"), amountCents: -2_349, counterpartName: "REWE Markt", purpose: "VISA Lebensmittel", status: .pending),
        Transaction(accountID: "a-card", bookingDate: day("2026-05-02"), valueDate: day("2026-05-01"), amountCents: -4_600, counterpartName: "Github Inc", purpose: "VISA Github USD 50,00", status: .booked, originalAmountCents: -5_000, originalCurrency: "USD"),
        Transaction(accountID: "a-card", bookingDate: day("2026-04-01"), valueDate: day("2026-04-01"), amountCents: -12_000, counterpartName: "Hotel", purpose: "STORNO", status: .cancelled),
    ]

    static let statement = CardStatement(accountID: "a-card", periodStart: day("2026-03-23"), periodEnd: day("2026-04-22"), dueDate: day("2026-04-27"), amountCents: -34_512)
    static let position = SecurityPosition(accountID: "a-depot", isin: "IE00B4L5Y983", name: "iShares Core MSCI World", quantity: Decimal(string: "48.312574", locale: Locale(identifier: "en_US_POSIX")) ?? 0, priceCents: 10_987, asOf: asOf, purchasePriceCents: 8_250)

    static func fill(_ store: some LedgerStore) async throws {
        try await store.upsert(connection: connection)
        try await store.replaceAccounts([giro, card, depot], of: connection.id)
        try await store.setBalance(Balance(bookedCents: 503_857, availableCents: 603_857, asOf: asOf), for: giro.id)
        try await store.apply(TransactionMerger.merge(stored: [], incoming: transactions, since: nil))
        try await store.replaceCardStatements([statement], of: card.id)
        try await store.replaceSecurities([position], of: depot.id)
        try await store.setSyncState(SyncState(phase: .failed(.authFailed), lastSuccess: asOf, consecutiveFailures: 1), for: connection.id)
    }
}

@Suite struct EncryptedLedgerStoreTests {
    @Test func sqlCipherIsActiveAndFileIsEncrypted() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        await store.close()

        let data = try Data(contentsOf: url)
        #expect(data.count > 0)
        #expect(!data.starts(with: Data("SQLite format 3".utf8)), "database header is plaintext")
        for needle in ["Muster GmbH", "Stadtwerke", "DE00 1203", "IE00B4L5Y983"] {
            #expect(data.range(of: Data(needle.utf8)) == nil, "\(needle) readable in file")
        }
    }

    @Test func roundTripPreservesEverything() async throws {
        let url = tempURL()
        let first = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(first)
        let written = await first.snapshot()
        await first.close()

        let second = try await EncryptedLedgerStore.open(at: url, key: keyA)
        let read = await second.snapshot()
        #expect(read.connections == written.connections)
        #expect(read.accounts == written.accounts)
        #expect(read.balances == written.balances)
        #expect(Set(read.transactions) == Set(written.transactions))
        #expect(read.cardStatements == written.cardStatements)
        #expect(read.securities == written.securities)
        #expect(read.syncStates == written.syncStates)
        #expect(read.securities.first?.quantity == Fixture.position.quantity)
        #expect(read.securities.first?.purchasePriceCents == 8_250)
    }

    @Test func removeConnectionDeletesAllItsDataOnDisk() async throws {
        let url = tempURL()
        let other = Connection(id: "c-c24", connectorID: .c24, displayName: "C24")
        let otherGiro = Account(id: "a-c24", connectionID: "c-c24", type: .giro, name: "Smartkonto")
        let otherTransaction = Transaction(accountID: "a-c24", bookingDate: day("2026-05-04"), valueDate: day("2026-05-04"), amountCents: -100, counterpartName: "Bäcker", purpose: "Brötchen", status: .booked)

        let first = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(first)
        try await first.upsert(connection: other)
        try await first.replaceAccounts([otherGiro], of: other.id)
        try await first.apply(TransactionMerger.merge(stored: [], incoming: [otherTransaction], since: nil))
        try await first.setSyncState(SyncState(lastSuccess: asOf), for: other.id)

        try await first.removeConnection(Fixture.connection.id)
        let afterRemoval = await first.snapshot()
        await first.close()

        let second = try await EncryptedLedgerStore.open(at: url, key: keyA)
        let read = await second.snapshot()
        for snapshot in [afterRemoval, read] {
            #expect(snapshot.connections == [other])
            #expect(snapshot.accounts == [otherGiro])
            #expect(snapshot.balances.isEmpty)
            #expect(snapshot.transactions.map(\.accountID) == ["a-c24"])
            #expect(snapshot.cardStatements.isEmpty)
            #expect(snapshot.securities.isEmpty)
            #expect(snapshot.syncStates.keys.map(\.self) == [other.id])
        }
        // Removing an unknown connection is a no-op.
        try await second.removeConnection("unknown")
        #expect(await second.snapshot() == read)
    }

    @Test func inMemoryStoreRemovesConnectionLikeEncryptedStore() async throws {
        let store = InMemoryLedgerStore()
        try await Fixture.fill(store)
        try await store.removeConnection(Fixture.connection.id)
        #expect(await store.snapshot() == LedgerSnapshot())
    }

    @Test func wrongKeyCannotOpen() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        await store.close()

        await #expect(throws: StoreError.cannotDecrypt) {
            _ = try await EncryptedLedgerStore.open(at: url, key: keyB)
        }
    }

    @Test func pendingIsReplacedOnDisk() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        let pending = try #require(await store.storedTransactions(of: "a-card").first { $0.status == .pending })
        try await store.setCategory("lebensmittel", source: .manual, confidence: nil, for: pending.id)

        let booked = Transaction(accountID: "a-card", bookingDate: day("2026-05-08"), valueDate: day("2026-05-06"), amountCents: -2_349, counterpartName: "REWE Markt GmbH sagt Danke", purpose: "VISA Lebensmittel Buchung", status: .booked)
        let stored = await store.storedTransactions(of: "a-card")
        try await store.apply(TransactionMerger.merge(stored: stored, incoming: stored.filter { $0.status != .pending } + [booked], since: day("2026-04-20")))
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        let card = await reopened.storedTransactions(of: "a-card")
        #expect(!card.contains { $0.status == .pending })
        #expect(card.first { $0.id == booked.id }?.categoryID == "lebensmittel")
        #expect(card.count == 3)
    }

    /// A fingerprint mismatch (altered row, changed rule) must not lock the whole database.
    @Test func fingerprintMismatchStillOpens() async throws {
        let url = tempURL()
        let first = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(first)
        let expected = await first.snapshot().transactions
        await first.close()

        try tamper(url, "UPDATE ledgerTransaction SET fingerprint = 'altered'")
        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await reopened.snapshot().transactions == expected)
    }

    @Test func structurallyCorruptRowStillFails() async throws {
        let url = tempURL()
        let first = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(first)
        await first.close()

        try tamper(url, "UPDATE ledgerTransaction SET status = 'bogus'")
        await #expect(throws: StoreError.self) { try await EncryptedLedgerStore.open(at: url, key: keyA) }
    }

    @Test func newerSchemaIsReportedAndLeftUntouched() async throws {
        let url = tempURL()
        let first = try await EncryptedLedgerStore.open(at: url, key: keyA)
        await first.close()

        let supported = Schema.migrations.count
        try tamper(url, "PRAGMA user_version = \(supported + 1)")
        await #expect(throws: StoreError.newerSchema(found: supported + 1, supported: supported)) {
            _ = try await EncryptedLedgerStore.open(at: url, key: keyA)
        }
        // Still the newer version: an older app never downgrades or rewrites it.
        await #expect(throws: StoreError.newerSchema(found: supported + 1, supported: supported)) {
            _ = try await EncryptedLedgerStore.open(at: url, key: keyA)
        }
    }

    private func tamper(_ url: URL, _ sql: String) throws {
        var passphrase = keyA.sqlCipherRawKey
        defer { passphrase.wipe() }
        let db = try SQLiteConnection(path: url.path, passphrase: passphrase)
        try db.execute(sql)
        db.close()
    }

    @Test func batchWritesPublishOnce() async throws {
        let store = try await EncryptedLedgerStore.open(at: tempURL(), key: keyA)
        try await Fixture.fill(store)
        let before = await store.publishCount

        // Nothing changed: no write, no publish.
        try await store.apply(TransactionMerger.merge(stored: [], incoming: [], since: nil))
        try await store.setCategory("x", source: .manual, confidence: 1, for: Set<TransactionID>())
        #expect(await store.publishCount == before)

        let ids = Set(await store.snapshot().transactions.prefix(3).map(\.id))
        try await store.setCategory("lebensmittel", source: .manual, confidence: 1, for: ids)
        let afterBatch = await store.publishCount
        #expect(afterBatch == before + 1)

        let pending = try #require(await store.storedTransactions(of: "a-card").first { $0.status == .pending })
        let booked = Transaction(accountID: "a-card", bookingDate: day("2026-05-08"), valueDate: day("2026-05-06"), amountCents: -2_349, counterpartName: "REWE Markt GmbH", purpose: "VISA Buchung", status: .booked)
        let update = AccountUpdate(accountID: "a-card", balance: Balance(bookedCents: -1_000, asOf: asOf), transactions: [pending, booked],
                                   since: day("2026-04-20"), cardStatements: [], securities: nil)
        try await store.apply(update)
        let afterUpdate = await store.publishCount
        #expect(afterUpdate == before + 2)
        await store.close()
    }

    @Test func accountUpdatePersists() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        let pending = try #require(await store.storedTransactions(of: "a-card").first { $0.status == .pending })
        try await store.setCategory("lebensmittel", source: .manual, confidence: 1, for: [pending.id])
        let booked = Transaction(accountID: "a-card", bookingDate: day("2026-05-08"), valueDate: day("2026-05-06"), amountCents: -2_349, counterpartName: "REWE Markt GmbH", purpose: "VISA Buchung", status: .booked)
        // Bank lists reservation and booking together.
        let update = AccountUpdate(accountID: "a-card", balance: Balance(bookedCents: -1_000, asOf: asOf), transactions: [pending, booked],
                                   since: day("2026-04-20"), cardStatements: [], securities: nil)
        try await store.apply(update)
        let inMemory = await store.snapshot()
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        let snapshot = await reopened.snapshot()
        #expect(snapshot == inMemory)
        #expect(snapshot.balances["a-card"]?.bookedCents == -1_000)
        #expect(snapshot.cardStatements.isEmpty)
        let card = snapshot.transactions(of: "a-card")
        #expect(!card.contains { $0.status == .pending })
        #expect(card.first { $0.id == booked.id }?.categoryID == "lebensmittel")
    }

    @Test func failedLoginSurvivesRestartSoNoAutomaticRetry() async throws {
        let url = tempURL()
        let first = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(first)
        await first.close()

        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await store.syncState(for: Fixture.connection.id).phase == .failed(.authFailed))

        let engine = SyncEngine(store: store)
        let probe = CallProbe()
        try await engine.register(Fixture.connection, connector: ProbeConnector(probe: probe))
        await engine.sync(Fixture.connection.id, trigger: .automatic)
        #expect(await probe.calls == 0)
    }

    @Test func syncingStateResetsAfterRestart() async throws {
        let url = tempURL()
        let first = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await first.upsert(connection: Fixture.connection)
        try await first.setSyncState(SyncState(phase: .syncing), for: Fixture.connection.id)
        await first.close()
        let second = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await second.syncState(for: Fixture.connection.id).phase == .idle)
    }

    @Test func closedStoreRejectsWrites() async throws {
        let store = try await EncryptedLedgerStore.open(at: tempURL(), key: keyA)
        await store.close()
        await #expect(throws: StoreError.closed) {
            try await store.upsert(connection: Fixture.connection)
        }
        #expect(await store.snapshot() == LedgerSnapshot())
    }

    @Test func failedWriteLeavesSnapshotUnchanged() async throws {
        let store = try await EncryptedLedgerStore.open(at: tempURL(), key: keyA)
        // Account of an unknown connection violates the foreign key.
        await #expect(throws: StoreError.self) {
            try await store.replaceAccounts([Fixture.giro], of: Fixture.connection.id)
        }
        #expect(await store.snapshot().accounts.isEmpty)
    }

    @Test func rawKeyFormat() {
        let key = Data([0x00, 0x0F, 0xA5, 0xFF])
        #expect(String(decoding: key.sqlCipherRawKey, as: UTF8.self) == "x'000FA5FF'")
    }
}

private actor CallProbe {
    var calls = 0
    func hit() { calls += 1 }
}

private struct ProbeConnector: BankConnector {
    let probe: CallProbe
    var id: ConnectorID { .dkb }
    func accounts() async throws -> [Account] { await probe.hit(); return [] }
    func balance(for account: Account) async throws -> Balance { Balance(bookedCents: 0, asOf: asOf) }
    func transactions(for account: Account, since: Date?) async throws -> [Transaction] { [] }
    func cardStatements(for account: Account) async throws -> [CardStatement] { [] }
    func securities(for account: Account) async throws -> [SecurityPosition] { [] }
}

@Suite struct CustomAccountNameTests {
    @Test func customNameSurvivesReopenAndSync() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        try await store.setCustomName("  Haushalt ", for: Fixture.giro.id)
        // The bank sends its name again on the next sync: the user's name stays.
        try await store.replaceAccounts([Fixture.giro, Fixture.card, Fixture.depot], of: Fixture.connection.id)
        #expect(await store.snapshot().customAccountNames[Fixture.giro.id] == "Haushalt")
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        let snapshot = await reopened.snapshot()
        let giro = try #require(snapshot.accounts.first { $0.id == Fixture.giro.id })
        #expect(giro.name == "Girokonto", "bank name untouched")
        #expect(snapshot.displayName(of: giro) == "Haushalt")

        try await reopened.setCustomName("", for: Fixture.giro.id)
        #expect(await reopened.snapshot().customAccountNames.isEmpty, "blank restores the bank name")
        try await reopened.setCustomName("Weg", for: Fixture.card.id)
        try await reopened.removeConnection(Fixture.connection.id)
        #expect(await reopened.snapshot().customAccountNames.isEmpty)
        await reopened.close()
        let third = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await third.snapshot().customAccountNames.isEmpty, "removed on disk too")
        await third.close()
    }

    @Test func renamingABankPersists() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        var renamed = Fixture.connection
        renamed.displayName = "DKB Privat"
        try await store.upsert(connection: renamed)
        await store.close()
        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await reopened.snapshot().connections.first?.displayName == "DKB Privat")
        #expect(await reopened.snapshot().accounts.count == 3, "upsert keeps the accounts")
        await reopened.close()
    }
}

@Suite struct CategoryPersistenceTests {
    @Test func rulesAndBatchCategoriesPersist() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        let rule = CategoryRule(match: .creditorID("DE00ZZZ00000000002"), categoryID: "nebenkosten", createdAt: asOf)
        try await store.upsertRule(rule)
        let target = try #require(await store.snapshot().transactions.first { $0.counterpartName == "Stadtwerke" })
        try await store.setCategories([target.id: CategorySuggestion(categoryID: "nebenkosten", source: .rule, confidence: 1)])
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.categoryRules == [rule])
        #expect(snapshot.transactions.first { $0.id == target.id }?.categoryID == "nebenkosten")
        #expect(snapshot.transactions.first { $0.id == target.id }?.categorySource == .rule)
        try await reopened.removeRule(rule.id)
        #expect(await reopened.snapshot().categoryRules.isEmpty)
        await reopened.close()
    }

    @Test func clearingCategoriesPersistsAndKeepsManual() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        let all = await store.snapshot().transactions
        let machine = try #require(all.first { $0.counterpartName == "Stadtwerke" })
        let manual = try #require(all.first { $0.counterpartName == "REWE Markt" })
        try await store.setCategories([machine.id: CategorySuggestion(categoryID: "nebenkosten", source: .rule, confidence: 1)])
        try await store.setCategory("lebensmittel", source: .manual, confidence: 1, for: manual.id)
        try await store.clearCategories([machine.id, manual.id])
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.transactions.first { $0.id == machine.id }?.categoryID == nil)
        #expect(snapshot.transactions.first { $0.id == machine.id }?.categorySource == nil)
        #expect(snapshot.transactions.first { $0.id == manual.id }?.categoryID == "lebensmittel", "manual stays")
        await reopened.close()
    }
}

@Suite struct BudgetPersistenceTests {
    @Test func budgetsPersistAndGoWithTheBank() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        let budget = AccountBudget(accountID: Fixture.giro.id, amountCents: 200_000, period: .monthly, startDay: 25, anchor: .init(toleranceDays: 2, counterpart: "Muster GmbH"))
        try await store.setBudget(budget)
        await store.close()
        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await reopened.snapshot().budgets[Fixture.giro.id] == budget)
        try await reopened.removeConnection(Fixture.connection.id)
        #expect(await reopened.snapshot().budgets.isEmpty)
        await reopened.close()
        let third = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await third.snapshot().budgets.isEmpty)
        await third.close()
    }
}

@Suite struct EncryptedConnectionMergeTests {
    /// The merge relies on an upsert with the same ID moving the row to the other account.
    @Test func mergeMovesRowsAndSurvivesReopen() async throws {
        let web = Connection(id: "ing-web", connectorID: .ing, displayName: "ING")
        let fints = Connection(id: "fints-ing-1", connectorID: .ing, displayName: "ING")
        let webGiro = Account(id: "w-giro", connectionID: web.id, iban: "DE02120300000000202051", type: .giro, name: "Girokonto")
        let fintsGiro = Account(id: "f-giro", connectionID: fints.id, iban: "DE02120300000000202051", type: .giro, name: "Giro")
        let old = Transaction(accountID: "w-giro", bookingDate: day("2026-06-01"), valueDate: day("2026-06-01"), amountCents: -4_200, counterpartName: "Stadtwerke", purpose: "Abschlag", status: .booked, categoryID: "utilities", categorySource: .rule)
        let webTwin = Transaction(accountID: "w-giro", bookingDate: day("2026-10-10"), valueDate: day("2026-10-10"), amountCents: -1_999, counterpartName: "Musterladen", purpose: "Einkauf", status: .booked, categoryID: "shopping", categorySource: .manual)
        let fintsTwin = Transaction(accountID: "f-giro", bookingDate: day("2026-10-10"), valueDate: day("2026-10-10"), amountCents: -1_999, counterpartName: "MUSTERLADEN", purpose: "Einkauf MT940", status: .booked)

        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        for (connection, account) in [(web, webGiro), (fints, fintsGiro)] {
            try await store.upsert(connection: connection)
            try await store.replaceAccounts([account], of: connection.id)
        }
        try await store.apply(TransactionMerger.merge(stored: [], incoming: [old, webTwin, fintsTwin], since: nil))
        try await store.setCustomName("Haushalt", for: webGiro.id)

        let snapshot = await store.snapshot()
        let changes = ConnectionMerge.changes(try ConnectionMerge.plan(snapshot, source: web.id, target: fints.id), in: snapshot)
        let published = await store.publishCount
        try await store.applyMerge(changes)
        #expect(await store.publishCount == published + 1)
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        let after = await reopened.snapshot()
        #expect(after.connections.map(\.id) == [fints.id])
        #expect(after.transactions.count == 2)
        #expect(after.transactions.allSatisfy { $0.accountID == "f-giro" })
        #expect(after.transactions.first { $0.id == old.id }?.categoryID == "utilities")
        #expect(after.transactions.first { $0.id == fintsTwin.id }?.categorySource == .manual)
        #expect(after.customAccountNames == ["f-giro": "Haushalt"])
        await reopened.close()
    }
}

@Suite struct EncryptedBackupTests {
    @Test func backupHoldsEverythingWrittenAndNeedsTheSameKey() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        let written = await store.snapshot()
        let copy = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        try await store.backup(to: copy)
        await store.close()

        let restored = try await EncryptedLedgerStore.open(at: copy, key: keyA)
        #expect(Set(await restored.snapshot().transactions) == Set(written.transactions))
        await restored.close()
        await #expect(throws: StoreError.cannotDecrypt) { _ = try await EncryptedLedgerStore.open(at: copy, key: keyB) }
    }

    @Test func failedBackupLeavesNoFile() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        let copy = url.deletingLastPathComponent().appendingPathComponent("missing-dir").appendingPathComponent("backup.sqlite")
        await #expect(throws: StoreError.self) { try await store.backup(to: copy) }
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        await store.close()
    }
}

@Suite struct DepotHistoryStoreTests {
    private func update(value: Int, at date: Date, purchase: Int? = 8_250) -> AccountUpdate {
        var position = Fixture.position
        position.purchasePriceCents = purchase
        return AccountUpdate(accountID: Fixture.depot.id, balance: Balance(bookedCents: value, asOf: date), transactions: [], since: nil, securities: [position])
    }

    @Test func depotSyncRecordsOnePointPerDayAndPersists() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.apply(update(value: 530_000, at: day1))
        try await store.apply(update(value: 531_000, at: day1.addingTimeInterval(3_600)))   // same day: replaced
        try await store.apply(update(value: 540_000, at: day1.addingTimeInterval(86_400), purchase: nil))
        // Not a depot: no point.
        try await store.apply(AccountUpdate(accountID: Fixture.giro.id, balance: Balance(bookedCents: 1, asOf: day1), transactions: [], since: nil))

        let points = try #require(await store.snapshot().depotHistory[Fixture.depot.id])
        #expect(points.map(\.valueCents) == [531_000, 540_000])
        // 48.312574 × 82,50 € = 3985,79 €
        #expect(points[0].purchaseCents == 398_579)
        #expect(points[1].purchaseCents == nil)
        #expect(await store.snapshot().depotHistory[Fixture.giro.id] == nil)
        let written = await store.snapshot().depotHistory
        await store.close()

        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await reopened.snapshot().depotHistory == written)
        try await reopened.removeConnection(Fixture.connection.id)
        #expect(await reopened.snapshot().depotHistory.isEmpty)
        await reopened.close()
        let again = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await again.snapshot().depotHistory.isEmpty)
        await again.close()
    }

    @Test func recordDepotValuesUpsertsByDay() async throws {
        let store = try await EncryptedLedgerStore.open(at: tempURL(), key: keyA)
        try await Fixture.fill(store)
        let a = DepotValuePoint(accountID: Fixture.depot.id, day: day("2026-05-02"), valueCents: 2, purchaseCents: nil)
        let b = DepotValuePoint(accountID: Fixture.depot.id, day: day("2026-05-01"), valueCents: 1, purchaseCents: 1)
        try await store.recordDepotValues([a, b, DepotValuePoint(accountID: Fixture.depot.id, day: day("2026-05-02"), valueCents: 3, purchaseCents: nil)])
        #expect(await store.snapshot().depotHistory[Fixture.depot.id]?.map(\.valueCents) == [1, 3])
        await store.close()
    }

    @Test func inMemoryStoreIgnoresPointsOfUnknownAccountsLikeTheDatabase() async throws {
        let store = InMemoryLedgerStore()
        try await Fixture.fill(store)
        try await store.recordDepotValues([
            DepotValuePoint(accountID: "unknown", day: day("2026-05-01"), valueCents: 1, purchaseCents: nil),
            DepotValuePoint(accountID: Fixture.depot.id, day: day("2026-05-01"), valueCents: 2, purchaseCents: nil),
        ])
        let history = await store.snapshot().depotHistory
        #expect(history["unknown"] == nil)
        #expect(history[Fixture.depot.id]?.count == 1)
    }

    @Test func recordOutOfOrderKeepsTheHistorySorted() {
        var snapshot = LedgerSnapshot()
        for iso in ["2026-05-03", "2026-05-01", "2026-05-03", "2026-05-02"] {
            snapshot.record(DepotValuePoint(accountID: "d", day: day(iso), valueCents: iso.count, purchaseCents: nil))
        }
        #expect(snapshot.depotHistory["d"]?.map(\.day.iso) == ["2026-05-01", "2026-05-02", "2026-05-03"])
    }
}

@Suite struct PlannedItemPersistenceTests {
    @Test func plannedItemsPersistAndGoWithTheBank() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        try await Fixture.fill(store)
        // Whole seconds: the column is a Unix time.
        var item = PlannedItem(accountID: Fixture.giro.id, day: BankDay(year: 2027, month: 1, day: 15)!, amountCents: -120_000,
                               title: "Autoreparatur", createdAt: Date(timeIntervalSince1970: 1_800_000_000), ignoredMatches: ["tx-1"])
        try await store.upsertPlannedItem(item)
        item.amountCents = -135_000
        try await store.upsertPlannedItem(item)
        let other = PlannedItem(accountID: Fixture.giro.id, day: BankDay(year: 2026, month: 12, day: 1)!, amountCents: 50_000,
                                title: "Erstattung", createdAt: Date(timeIntervalSince1970: 1_800_000_100))
        try await store.upsertPlannedItem(other)
        await store.close()
        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await reopened.snapshot().plannedItems == [other, item], "by day")
        try await reopened.removePlannedItem(other.id)
        #expect(await reopened.snapshot().plannedItems == [item])
        try await reopened.removeConnection(Fixture.connection.id)
        #expect(await reopened.snapshot().plannedItems.isEmpty)
        await reopened.close()
        let third = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await third.snapshot().plannedItems.isEmpty)
        await third.close()
    }
}

@Suite struct EncryptedOpeningBalanceTests {
    @Test func openingBalancePersistsAndGoesWithTheAccount() async throws {
        let url = tempURL()
        let store = try await EncryptedLedgerStore.open(at: url, key: keyA)
        let connection = Connection(id: "manual:A", connectorID: .manual, displayName: "Sparbuch")
        let account = Account(id: "manual:A", connectionID: "manual:A", type: .tagesgeld, name: "Sparbuch")
        try await store.upsert(connection: connection)
        try await store.replaceAccounts([account], of: connection.id)
        let opening = OpeningBalance(cents: -12_345, day: day("2026-02-01"))
        try await store.setOpeningBalance(opening, for: account.id)
        // Foreign key: an opening balance of an unknown account is not stored.
        await #expect(throws: (any Error).self) { try await store.setOpeningBalance(OpeningBalance(cents: 1), for: "manual:unknown") }
        await store.close()
        let reopened = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await reopened.snapshot().connections == [connection])
        #expect(await reopened.snapshot().openingBalances == [account.id: opening])
        try await reopened.setOpeningBalance(OpeningBalance(cents: 5), for: account.id)
        try await reopened.removeConnection(connection.id)
        #expect(await reopened.snapshot().openingBalances.isEmpty)
        await reopened.close()
        let third = try await EncryptedLedgerStore.open(at: url, key: keyA)
        #expect(await third.snapshot().openingBalances.isEmpty)
        await third.close()
    }
}
