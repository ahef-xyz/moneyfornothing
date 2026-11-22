import Foundation
import MFNCore
import Testing
@testable import MFN

/// Which store publishes rebuild index and lists (`AppModel.lightChange`).
@MainActor @Suite struct LightChangeTests {
    private static let noon = Date(timeIntervalSince1970: 1_800_000_000)

    private static func ledger(lastSuccess: Date? = noon) -> LedgerSnapshot {
        var ledger = Fixture.snapshot(transactions: [Fixture.transaction("a"), Fixture.transaction("b")])
        ledger.syncStates[Fixture.bank.id] = SyncState(phase: .idle, lastSuccess: lastSuccess)
        return ledger
    }

    @Test func syncPhaseAloneKeepsIndexAndLists() {
        let model = Fixture.model(ledger: Self.ledger())
        let revision = model.snapshotRevision

        var syncing = Self.ledger()
        syncing.syncStates[Fixture.bank.id]?.phase = .syncing
        #if DEBUG
        model.applyLedgerForTesting(syncing)
        #endif
        #expect(model.snapshotRevision == revision)
        #expect(model.snapshot.syncStates[Fixture.bank.id]?.phase == .syncing)

        // A sync ending later the same day.
        var done = Self.ledger(lastSuccess: Self.noon.addingTimeInterval(60))
        done.syncStates[Fixture.bank.id]?.phase = .idle
        #if DEBUG
        model.applyLedgerForTesting(done)
        #endif
        #expect(model.snapshotRevision == revision)
        #expect(model.snapshot.syncStates[Fixture.bank.id]?.lastSuccess == Self.noon.addingTimeInterval(60))
    }

    @Test func classification() {
        let base = Self.ledger()
        #expect(AppModel.lightChange(from: base, to: base) == .newOnly)

        var read = base
        read.newTransactionIDs = ["a"]
        #expect(AppModel.lightChange(from: base, to: read) == .newOnly)

        var failed = base
        failed.syncStates[Fixture.bank.id]?.phase = .failed(.bankUnavailable)
        failed.syncStates[Fixture.bank.id]?.consecutiveFailures = 1
        #expect(AppModel.lightChange(from: base, to: failed) == .syncStates(alsoNew: false))
        failed.newTransactionIDs = ["a"]
        #expect(AppModel.lightChange(from: base, to: failed) == .syncStates(alsoNew: true))

        // Budgets forecast from the day of the last sync: a new day rebuilds.
        let nextDay = Self.ledger(lastSuccess: Self.noon.addingTimeInterval(2 * 86_400))
        #expect(AppModel.lightChange(from: base, to: nextDay) == nil)
        #expect(AppModel.lightChange(from: Self.ledger(lastSuccess: nil), to: base) == nil)

        var balance = base
        balance.balances[Fixture.giro.id] = Balance(bookedCents: 1, asOf: Self.noon)
        #expect(AppModel.lightChange(from: base, to: balance) == nil)

        var more = base
        more.transactions.append(Fixture.transaction("c"))
        more.syncStates[Fixture.bank.id]?.phase = .syncing
        #expect(AppModel.lightChange(from: base, to: more) == nil)
    }

    @Test func otherChangesStillRebuild() {
        let model = Fixture.model(ledger: Self.ledger())
        let revision = model.snapshotRevision
        var more = Self.ledger()
        more.transactions.append(Fixture.transaction("c"))
        #if DEBUG
        model.applyLedgerForTesting(more)
        #endif
        #expect(model.snapshotRevision != revision)
        #expect(model.snapshot.transactions.count == 3)
    }
}
