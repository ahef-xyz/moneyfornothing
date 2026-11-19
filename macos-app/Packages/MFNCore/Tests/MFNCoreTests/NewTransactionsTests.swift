import Foundation
import Testing
@testable import MFNCore

private func day(_ iso: String) -> BankDay {
    // Test helper: literals are valid.
    BankDay(iso: iso) ?? BankDay(Date(timeIntervalSince1970: 0))
}

private func tx(_ status: TransactionStatus, _ iso: String, _ amount: Int, _ merchant: String, account: AccountID = "giro") -> Transaction {
    Transaction(accountID: account, bookingDate: status == .booked ? day(iso) : nil, valueDate: day(iso), amountCents: amount,
                counterpartName: merchant, purpose: "Zahlung", status: status)
}

private let balance = Balance(bookedCents: 0, asOf: Date(timeIntervalSince1970: 1_800_000_000))

private func update(_ transactions: [Transaction], since: String?, account: AccountID = "giro") -> AccountUpdate {
    AccountUpdate(accountID: account, balance: balance, transactions: transactions, since: since.map(day))
}

private func ledger(_ transactions: [Transaction]) -> LedgerSnapshot {
    var snapshot = LedgerSnapshot()
    snapshot.connections = [Connection(id: "c1", connectorID: .mock, displayName: "Bank")]
    snapshot.accounts = [Account(id: "giro", connectionID: "c1", type: .giro, name: "Giro"),
                         Account(id: "card", connectionID: "c1", type: .card, name: "Karte")]
    snapshot.transactions = transactions.sorted(by: LedgerSnapshot.newestFirst)
    return snapshot
}

@Suite struct NewTransactionsTests {
    let rent = tx(.booked, "2026-11-01", -90_000, "Hausverwaltung")
    let salary = tx(.booked, "2026-11-15", 300_000, "Arbeitgeber")
    let bakery = tx(.booked, "2026-11-18", -450, "Bäckerei")

    @Test func firstSyncIsHistoryNotNews() {
        var snapshot = ledger([])
        snapshot.apply(update([rent, salary], since: nil))
        #expect(snapshot.newTransactionIDs.isEmpty)
    }

    @Test func emptyAccountIsHistoryEvenWithWindow() {
        var snapshot = ledger([])
        snapshot.apply(update([rent], since: "2026-10-01"))
        #expect(snapshot.newTransactionIDs.isEmpty)
    }

    @Test func laterSyncMarksOnlyUnknownRowsInAndOut() {
        var snapshot = ledger([rent])
        snapshot.apply(update([rent, salary, bakery], since: "2026-10-20"))
        #expect(snapshot.newTransactionIDs == [salary.id, bakery.id])
    }

    @Test func newRowsCollectAcrossSyncsUntilSeen() {
        var snapshot = ledger([rent])
        snapshot.apply(update([rent, salary], since: "2026-10-20"))
        snapshot.apply(update([rent, salary], since: "2026-10-20"))
        #expect(snapshot.newTransactionIDs == [salary.id])
        snapshot.apply(update([rent, salary, bakery], since: "2026-10-20"))
        #expect(snapshot.newTransactionIDs == [salary.id, bakery.id])
        snapshot.markSeen([salary.id])
        #expect(snapshot.newTransactionIDs == [bakery.id])
    }

    @Test func plannedAndCancelledAreNotNews() {
        var snapshot = ledger([rent])
        let planned = tx(.planned, "2026-12-01", -90_000, "Hausverwaltung")
        let cancelled = tx(.cancelled, "2026-11-10", -1_000, "Shop")
        snapshot.apply(update([rent, planned, cancelled], since: "2026-10-20"))
        #expect(snapshot.newTransactionIDs.isEmpty)
    }

    @Test func bookingOfASeenReservationIsNotNews() {
        let pending = tx(.pending, "2026-11-17", -2_349, "REWE Markt", account: "card")
        let booked = tx(.booked, "2026-11-18", -2_349, "REWE MARKT GMBH", account: "card")
        var snapshot = ledger([pending])
        snapshot.apply(update([booked], since: "2026-11-01", account: "card"))
        #expect(snapshot.newTransactionIDs.isEmpty)
        #expect(snapshot.transaction(booked.id) != nil)
    }

    @Test func bookingOfAnUnseenReservationStaysNew() {
        let older = tx(.booked, "2026-11-01", -1_000, "Kiosk", account: "card")
        let pending = tx(.pending, "2026-11-17", -2_349, "REWE Markt", account: "card")
        let booked = tx(.booked, "2026-11-18", -2_349, "REWE MARKT GMBH", account: "card")
        var snapshot = ledger([older])
        snapshot.apply(update([older, pending], since: "2026-11-01", account: "card"))
        #expect(snapshot.newTransactionIDs == [pending.id])
        snapshot.apply(update([older, booked], since: "2026-11-01", account: "card"))
        #expect(snapshot.newTransactionIDs == [booked.id])
    }

    @Test func expiredReservationLosesItsMark() {
        let pending = tx(.pending, "2026-11-17", -2_349, "REWE Markt")
        var snapshot = ledger([rent])
        snapshot.apply(update([rent, pending], since: "2026-11-01"))
        #expect(snapshot.newTransactionIDs == [pending.id])
        snapshot.apply(update([rent], since: "2026-11-01"))
        #expect(snapshot.newTransactionIDs.isEmpty)
    }

    @Test func removingTheBankDropsItsMarks() {
        var snapshot = ledger([rent])
        snapshot.apply(update([rent, salary], since: "2026-10-20"))
        snapshot.removeConnection("c1")
        #expect(snapshot.newTransactionIDs.isEmpty)
    }

    @Test func inMemoryStoreMarksSeenAndSkipsNoOps() async throws {
        let store = InMemoryLedgerStore(ledger([rent]))
        try await store.apply(update([rent, salary], since: "2026-10-20"))
        #expect(await store.snapshot().newTransactionIDs == [salary.id])
        let published = await store.publishCount
        try await store.markSeen([rent.id])
        #expect(await store.publishCount == published)
        try await store.markSeen([salary.id])
        #expect(await store.snapshot().newTransactionIDs.isEmpty)
    }
}

@Suite struct NewTransactionQueryTests {
    let old = tx(.booked, "2026-11-18", -450, "Bäckerei")
    let fresh = tx(.booked, "2026-11-10", -2_000, "Buchhandlung")
    let newest = tx(.booked, "2026-11-19", -990, "Kiosk")

    @Test func onlyNewKeepsTheNewRows() {
        var query = TransactionQuery()
        query.onlyNew = true
        #expect(query.isFiltering)
        #expect(query.apply([newest, old, fresh], new: [fresh.id]) == [fresh])
    }

    @Test func newFirstPutsNewOnTopThenNewestFirst() {
        let query = TransactionQuery(sort: .newFirst)
        #expect(!query.sort.isChronological)
        #expect(query.dependsOnNew)
        #expect(query.sorted([newest, old, fresh], new: [fresh.id]) == [fresh, newest, old])
    }

    @Test func otherQueriesIgnoreNew() {
        #expect(!TransactionQuery().dependsOnNew)
        #expect(TransactionQuery().apply([newest, old, fresh], new: [fresh.id]) == [newest, old, fresh])
    }
}
