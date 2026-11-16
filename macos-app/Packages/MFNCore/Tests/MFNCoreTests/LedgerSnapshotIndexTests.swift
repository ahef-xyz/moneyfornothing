import Foundation
import Testing
@testable import MFNCore

/// Lookups of `LedgerSnapshot` (per account, ID, import) and the sorted-run merge: synthetic data only.
@Suite struct LedgerSnapshotIndexTests {
    static func row(_ purpose: String, account: AccountID, day iso: String, booked: Bool = true) -> Transaction {
        let day = BankDay(iso: iso) ?? .today
        return Transaction(accountID: account, bookingDate: booked ? day : nil, valueDate: day, amountCents: -100,
                           counterpartName: "Muster", purpose: purpose, status: booked ? .booked : .pending)
    }

    @Test func mergeKeepsTheSameOrderAsAFullSort() {
        var snapshot = LedgerSnapshot()
        let stored = (1...20).map { Self.row("S\($0)", account: $0.isMultiple(of: 2) ? "a" : "b", day: "2026-03-\(String(format: "%02d", $0))") }
        snapshot.apply(TransactionMerger.Result(upserts: stored))
        let incoming = [
            Self.row("N1", account: "a", day: "2026-03-25"),
            Self.row("N2", account: "b", day: "2026-03-10"),
            Self.row("N3", account: "a", day: "2026-03-10", booked: false),
            Self.row("N4", account: "b", day: "2026-02-01"),
            stored[4],
        ]
        snapshot.apply(TransactionMerger.Result(upserts: incoming, deletions: [stored[7].id]))

        var expected = stored.filter { $0.id != stored[7].id && $0.id != stored[4].id } + incoming
        expected.sort(by: LedgerSnapshot.newestFirst)
        #expect(snapshot.transactions == expected)
        #expect(snapshot.transactions(of: "a") == expected.filter { $0.accountID == "a" })
        #expect(snapshot.transactions(of: "b") == expected.filter { $0.accountID == "b" })
    }

    @Test func lookupsFollowEveryChange() {
        var snapshot = LedgerSnapshot()
        let first = Self.row("A", account: "a", day: "2026-03-01")
        let second = Self.row("B", account: "a", day: "2026-03-02")
        snapshot.apply(TransactionMerger.Result(upserts: [first, second]))
        #expect(snapshot.transactions(of: "a").map(\.id) == [second.id, first.id])

        // A category change keeps the lookups and shows in the result.
        snapshot.setCategory("lebensmittel", source: .manual, confidence: nil, for: first.id)
        #expect(snapshot.transactions(of: "a").last?.categoryID == "lebensmittel")
        #expect(snapshot.transaction(first.id)?.categoryID == "lebensmittel")

        // Direct writes to the public array invalidate them.
        snapshot.transactions.removeAll { $0.id == second.id }
        #expect(snapshot.transactions(of: "a").map(\.id) == [first.id])
        #expect(snapshot.transaction(second.id) == nil)

        // Copies stay independent.
        let copy = snapshot
        snapshot.transactions = []
        #expect(copy.transactions(of: "a").count == 1)
        #expect(snapshot.transactions(of: "a").isEmpty)
        #expect(copy != snapshot)
    }

    @Test func batchCategoryChangesReturnRowsInLedgerOrder() {
        var snapshot = LedgerSnapshot()
        let rows = (1...5).map { Self.row("R\($0)", account: "a", day: "2026-04-0\($0)") }
        snapshot.apply(TransactionMerger.Result(upserts: rows))
        let changed = snapshot.setCategory("freizeit", source: .manual, confidence: nil, for: Set(rows.map(\.id)))
        #expect(changed.map(\.id) == snapshot.transactions.map(\.id))
        let suggestions = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, CategorySuggestion(categoryID: "lebensmittel", source: .knn, confidence: 0.9)) })
        #expect(snapshot.setCategories(suggestions).isEmpty, "manual categories stay")
        #expect(snapshot.clearCategories(Set(rows.map(\.id))).isEmpty, "manual categories stay")
    }
}
