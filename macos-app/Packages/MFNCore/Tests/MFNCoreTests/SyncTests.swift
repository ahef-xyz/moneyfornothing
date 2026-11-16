import Foundation
import Testing
@testable import MFNCore

private func day(_ iso: String) -> BankDay {
    // Test helper: literals are valid.
    BankDay(iso: iso) ?? BankDay(Date(timeIntervalSince1970: 0))
}

private func tx(
    _ status: TransactionStatus,
    booking: String?,
    value: String,
    amount: Int,
    merchant: String,
    purpose: String = "Kartenzahlung",
    account: AccountID = "card"
) -> Transaction {
    Transaction(
        accountID: account,
        bookingDate: booking.map(day),
        valueDate: day(value),
        amountCents: amount,
        counterpartName: merchant,
        purpose: purpose,
        status: status
    )
}

@Suite struct TransactionMergerTests {
    @Test func pendingIsReplacedByBookedNotDoubled() {
        var pending = tx(.pending, booking: nil, value: "2026-05-02", amount: -2349, merchant: "REWE Markt")
        pending.categoryID = "lebensmittel"
        pending.categorySource = .manual
        let booked = tx(.booked, booking: "2026-05-04", value: "2026-05-02", amount: -2349, merchant: "REWE MARKT GMBH SAGT DANKE", purpose: "REWE 4711 Köln")

        let result = TransactionMerger.merge(stored: [pending], incoming: [booked], since: day("2026-04-20"))

        #expect(result.deletions == [pending.id])
        #expect(result.upserts.count == 1)
        #expect(result.upserts.first?.id == booked.id)
        #expect(result.upserts.first?.categoryID == "lebensmittel")
        #expect(result.upserts.first?.categorySource == .manual)
        #expect(result.resolved[pending.id] == booked.id)
    }

    @Test func noMatchOutsideThreeDaysOrOtherAmount() {
        let pending = tx(.pending, booking: nil, value: "2026-05-01", amount: -1000, merchant: "Shell")
        let tooLate = tx(.booked, booking: "2026-05-05", value: "2026-05-05", amount: -1000, merchant: "Shell")
        let otherAmount = tx(.booked, booking: "2026-05-02", value: "2026-05-02", amount: -1001, merchant: "Shell")
        #expect(!TransactionMerger.matches(pending: pending, booked: tooLate))
        #expect(!TransactionMerger.matches(pending: pending, booked: otherAmount))
    }

    @Test func foreignCurrencyAllowsTwoPercent() {
        let pending = Transaction(accountID: "card", bookingDate: nil, valueDate: day("2026-05-02"), amountCents: -4_600, counterpartName: "Github", purpose: "USD", status: .pending, originalAmountCents: -5_000, originalCurrency: "USD")
        let within = Transaction(accountID: "card", bookingDate: day("2026-05-04"), valueDate: day("2026-05-02"), amountCents: -4_650, counterpartName: "Github Inc", purpose: "USD", status: .booked, originalAmountCents: -5_000, originalCurrency: "USD")
        let outside = Transaction(accountID: "card", bookingDate: day("2026-05-04"), valueDate: day("2026-05-02"), amountCents: -4_800, counterpartName: "Github Inc", purpose: "USD", status: .booked, originalAmountCents: -5_000, originalCurrency: "USD")
        #expect(TransactionMerger.matches(pending: pending, booked: within))
        #expect(!TransactionMerger.matches(pending: pending, booked: outside))
        // Without foreign currency the amount must match exactly.
        let eurPending = tx(.pending, booking: nil, value: "2026-05-02", amount: -4_600, merchant: "Github")
        let eurBooked = tx(.booked, booking: "2026-05-04", value: "2026-05-02", amount: -4_650, merchant: "Github Inc")
        #expect(!TransactionMerger.matches(pending: eurPending, booked: eurBooked))
    }

    @Test func twoPendingsMatchTwoBookingsOneToOne() {
        let p1 = tx(.pending, booking: nil, value: "2026-05-02", amount: -350, merchant: "Café", purpose: "a")
        let p2 = tx(.pending, booking: nil, value: "2026-05-02", amount: -350, merchant: "Café", purpose: "b")
        let b1 = tx(.booked, booking: "2026-05-03", value: "2026-05-02", amount: -350, merchant: "Café", purpose: "c")
        let b2 = tx(.booked, booking: "2026-05-03", value: "2026-05-02", amount: -350, merchant: "Café", purpose: "d")
        let result = TransactionMerger.merge(stored: [p1, p2], incoming: [b1, b2], since: nil)
        #expect(result.deletions == [p1.id, p2.id])
        #expect(Set(result.resolved.values) == [b1.id, b2.id])
    }

    @Test func expiredReservationInsideWindowIsDeleted() {
        let pending = tx(.pending, booking: nil, value: "2026-05-02", amount: -5000, merchant: "Hotel")
        let result = TransactionMerger.merge(stored: [pending], incoming: [], since: day("2026-04-20"))
        #expect(result.deletions == [pending.id])
    }

    @Test func oldBookedHistoryIsKept() {
        let old = tx(.booked, booking: "2025-01-02", value: "2025-01-02", amount: -100, merchant: "Alt")
        let result = TransactionMerger.merge(stored: [old], incoming: [], since: day("2026-04-20"))
        #expect(result.deletions.isEmpty)
    }

    /// Some banks list the reservation next to its booking for a while.
    @Test func pendingAndBookedInTheSameAnswerAreNotDoubled() {
        var pending = tx(.pending, booking: nil, value: "2026-05-02", amount: -2349, merchant: "REWE Markt")
        let booked = tx(.booked, booking: "2026-05-04", value: "2026-05-02", amount: -2349, merchant: "REWE MARKT GMBH", purpose: "REWE 4711")

        // First sync: both new.
        let first = TransactionMerger.merge(stored: [], incoming: [pending, booked], since: nil)
        #expect(first.upserts.map(\.id) == [booked.id])
        #expect(first.resolved[pending.id] == booked.id)

        // Pending stored earlier (and categorised), bank now reports both.
        pending.categoryID = "lebensmittel"
        pending.categorySource = .manual
        let second = TransactionMerger.merge(stored: [pending], incoming: [pending, booked], since: day("2026-04-20"))
        #expect(second.upserts.map(\.id) == [booked.id])
        #expect(second.upserts.first?.categoryID == "lebensmittel")
        #expect(second.deletions == [pending.id])

        // Booking already stored, bank still lists the reservation: stays resolved.
        let third = TransactionMerger.merge(stored: [booked], incoming: [pending, booked], since: day("2026-04-20"))
        #expect(third.upserts.map(\.id) == [booked.id])
        #expect(third.deletions.isEmpty)
    }

    @Test func laterPendingIsNotSwallowedByAnEarlierBooking() {
        // Same coffee two days in a row: yesterday's is booked, today's still pending.
        let booked = tx(.booked, booking: "2026-05-02", value: "2026-05-02", amount: -350, merchant: "Café")
        let pending = tx(.pending, booking: nil, value: "2026-05-03", amount: -350, merchant: "Café")
        let result = TransactionMerger.merge(stored: [booked], incoming: [booked, pending], since: nil)
        #expect(Set(result.upserts.map(\.id)) == [booked.id, pending.id])
    }

    @Test func oneBookingResolvesOnlyOnePending() {
        let p1 = tx(.pending, booking: nil, value: "2026-05-02", amount: -350, merchant: "Café", purpose: "a")
        let p2 = tx(.pending, booking: nil, value: "2026-05-02", amount: -350, merchant: "Café", purpose: "b")
        let b1 = tx(.booked, booking: "2026-05-03", value: "2026-05-02", amount: -350, merchant: "Café", purpose: "c")
        let result = TransactionMerger.merge(stored: [], incoming: [p1, p2, b1], since: nil)
        #expect(result.upserts.count == 2)
        #expect(result.upserts.contains { $0.id == b1.id })
    }

    @Test func emptyMergeIsEmpty() {
        let stored = tx(.booked, booking: "2026-05-04", value: "2026-05-04", amount: -100, merchant: "X")
        #expect(TransactionMerger.merge(stored: [stored], incoming: [], since: nil).isEmpty)
    }

    @Test func sameIDKeepsCategorisation() {
        var stored = tx(.booked, booking: "2026-05-04", value: "2026-05-04", amount: -100, merchant: "X")
        stored.categoryID = "sonstiges"
        stored.categorySource = .rule
        let incoming = tx(.booked, booking: "2026-05-04", value: "2026-05-04", amount: -100, merchant: "X")
        let result = TransactionMerger.merge(stored: [stored], incoming: [incoming], since: nil)
        #expect(result.upserts.first?.categoryID == "sonstiges")
        #expect(result.deletions.isEmpty)
    }
}

// MARK: - SyncEngine

private struct StubConnector: BankConnector {
    var id: ConnectorID = .mock
    var error: ConnectorError?
    var calls: CallCounter
    var transactionsResult: [Transaction] = []
    var transactionsDelay: Duration = .milliseconds(20)

    func accounts() async throws -> [Account] {
        await calls.increment()
        if let error { throw error }
        return [Account(id: "card", connectionID: "c1", type: .giro, name: "Giro")]
    }

    func balance(for account: Account) async throws -> Balance {
        Balance(bookedCents: 100, asOf: .now)
    }

    func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        try await Task.sleep(for: transactionsDelay)
        return transactionsResult
    }

    func cardStatements(for account: Account) async throws -> [CardStatement] { [] }
    func securities(for account: Account) async throws -> [SecurityPosition] { [] }
}

private actor CallCounter {
    var count = 0
    func increment() { count += 1 }
}

private final class Clock: @unchecked Sendable {
    // Test-only mutable clock; accessed sequentially from the test.
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@Suite struct SyncEngineTests {
    let connection = Connection(id: "c1", connectorID: .mock, displayName: "Test")

    @Test func concurrentSyncsOfSameConnectionRunOnce() async throws {
        let store = InMemoryLedgerStore()
        let counter = CallCounter()
        let engine = SyncEngine(store: store)
        try await engine.register(connection, connector: StubConnector(calls: counter))

        async let a: Void = engine.sync("c1", trigger: .manual)
        async let b: Void = engine.sync("c1", trigger: .manual)
        _ = await (a, b)

        #expect(await counter.count == 1)
        #expect(await store.snapshot().accounts.count == 1)
        #expect(await store.syncState(for: "c1").phase == .idle)
    }

    /// `.automatic` checks the stored state (a suspension point) before starting: the slot
    /// must be reserved before that, else two calls both start (two logins to one bank).
    @Test func concurrentAutomaticSyncsStartOnlyOnce() async throws {
        let store = InMemoryLedgerStore()
        let counter = CallCounter()
        let engine = SyncEngine(store: store)
        try await engine.register(connection, connector: StubConnector(calls: counter))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { await engine.sync("c1", trigger: .automatic) }
            }
        }
        #expect(await counter.count == 1)
        #expect(await store.syncState(for: "c1").phase == .idle)

        // The slot is free again afterwards.
        await engine.sync("c1", trigger: .manual)
        #expect(await counter.count == 2)
    }

    @Test func cancellingTheCallerCancelsTheSync() async throws {
        let store = InMemoryLedgerStore()
        let counter = CallCounter()
        let engine = SyncEngine(store: store)
        try await engine.register(connection, connector: StubConnector(calls: counter, transactionsDelay: .seconds(30)))

        let caller = Task { await engine.sync("c1", trigger: .manual) }
        while await counter.count == 0 { await Task.yield() }
        caller.cancel()
        await caller.value
        #expect(await store.syncState(for: "c1").phase == .failed(.cancelled))
    }

    /// Each account is one write: state syncing, accounts, the account, state idle.
    @Test func syncPublishesOnceperAccount() async throws {
        let store = InMemoryLedgerStore()
        let engine = SyncEngine(store: store)
        try await engine.register(connection, connector: StubConnector(calls: CallCounter()))
        let before = await store.publishCount
        await engine.sync("c1", trigger: .manual)
        #expect(await store.publishCount == before + 4)
        #expect(await store.snapshot().balances["card"]?.bookedCents == 100)
    }

    @Test func manualCategoryForManyIsOneWrite() async throws {
        let rows = (0..<5).map { tx(.booked, booking: "2026-05-0\($0 + 1)", value: "2026-05-0\($0 + 1)", amount: -100 - $0, merchant: "M\($0)") }
        let store = InMemoryLedgerStore()
        try await store.apply(TransactionMerger.merge(stored: [], incoming: rows, since: nil))
        let before = await store.publishCount
        try await store.apply(TransactionMerger.Result())
        #expect(await store.publishCount == before, "empty merge publishes nothing")
        try await store.setCategory("x", source: .manual, confidence: 1, for: Set(rows.prefix(3).map(\.id)))
        #expect(await store.publishCount == before + 1)
        #expect(await store.snapshot().transactions.count { $0.categoryID == "x" && $0.categorySource == .manual } == 3)
    }

    @Test func automaticSyncRespectsFifteenMinutes() async throws {
        let store = InMemoryLedgerStore()
        let counter = CallCounter()
        let clock = Clock()
        let engine = SyncEngine(store: store, now: { clock.now })
        try await engine.register(connection, connector: StubConnector(calls: counter))

        await engine.sync("c1", trigger: .automatic)
        clock.now += 10 * 60
        await engine.sync("c1", trigger: .automatic)
        #expect(await counter.count == 1)
        clock.now += 6 * 60
        await engine.sync("c1", trigger: .automatic)
        #expect(await counter.count == 2)
    }

    @Test func failedLoginIsNeverRetriedAutomatically() async throws {
        let store = InMemoryLedgerStore()
        let counter = CallCounter()
        let clock = Clock()
        let engine = SyncEngine(store: store, now: { clock.now })
        try await engine.register(connection, connector: StubConnector(error: .authFailed, calls: counter))

        await engine.sync("c1", trigger: .automatic)
        clock.now += 3600
        await engine.sync("c1", trigger: .automatic)
        #expect(await counter.count == 1)
        #expect(await store.syncState(for: "c1").phase == .failed(.authFailed))

        // Without stored credentials (visible web login) the user types anew: manual may retry.
        await engine.sync("c1", trigger: .manual)
        #expect(await counter.count == 2)
    }

    /// The bank rejected the stored credentials: ⌘R must not send them again (lockout), only
    /// new credentials unblock the connection.
    @Test func rejectedStoredCredentialsBlockManualSyncUntilChanged() async throws {
        let store = InMemoryLedgerStore()
        let counter = CallCounter()
        let engine = SyncEngine(store: store)
        let bank = Connection(id: "c1", connectorID: .easybank, displayName: "easybank")
        try await engine.register(bank, connector: StubConnector(id: .easybank, error: .authFailed, calls: counter))

        await engine.sync("c1", trigger: .manual)
        #expect(await counter.count == 1)
        await engine.sync("c1", trigger: .manual)
        await engine.syncAll(trigger: .manual)
        await engine.sync("c1", trigger: .unlock)
        #expect(await counter.count == 1, "the rejected credentials are not sent again")
        let state = await store.syncState(for: "c1")
        #expect(state.phase == .failed(.authFailed), "the UI keeps showing the rejected login")
        #expect(state.consecutiveFailures == 1, "a refused start is not another failure")

        await engine.credentialsChanged("c1")
        #expect(await store.syncState(for: "c1").phase == .idle)
        await engine.sync("c1", trigger: .manual)
        #expect(await counter.count == 2)
    }

    @Test func stopsAfterThreeFailuresAndHonoursRateLimit() async throws {
        let store = InMemoryLedgerStore()
        let counter = CallCounter()
        let clock = Clock()
        let engine = SyncEngine(store: store, now: { clock.now })
        try await engine.register(connection, connector: StubConnector(error: .rateLimited(retryAfter: 1800), calls: counter))

        await engine.sync("c1", trigger: .automatic)
        clock.now += 20 * 60
        await engine.sync("c1", trigger: .automatic) // still blocked by retryAfter
        #expect(await counter.count == 1)

        for _ in 0..<4 {
            clock.now += 3600
            await engine.sync("c1", trigger: .automatic)
        }
        #expect(await counter.count == 3)
        #expect(await store.syncState(for: "c1").consecutiveFailures == 3)
    }

    @Test func unregisteredConnectionIsNotSyncedAnymore() async throws {
        let store = InMemoryLedgerStore()
        let counter = CallCounter()
        let engine = SyncEngine(store: store)
        try await engine.register(connection, connector: StubConnector(calls: counter))
        await engine.sync("c1", trigger: .manual)
        await engine.unregister("c1")
        try await store.removeConnection("c1")

        await engine.sync("c1", trigger: .manual)
        await engine.syncAll(trigger: .manual)
        #expect(await counter.count == 1)
        #expect(await engine.registeredConnections.isEmpty)
        #expect(await store.snapshot() == LedgerSnapshot())
    }

    @Test func unexpectedErrorsBecomeFormatChanged() {
        struct Boom: Error {}
        #expect(SyncEngine.connectorError(from: Boom()) == .formatChanged(detail: "Unerwarteter Fehler: Boom"))
        #expect(SyncEngine.connectorError(from: CancellationError()) == .cancelled)
    }
}

@Suite struct KeychainTests {
    @Test func roundTripOrMissingEntitlement() throws {
        let keychain = Keychain(service: "xyz.ahef.mfn.tests")
        do {
            try keychain.set(Data("geheim".utf8), for: "probe")
            #expect(try keychain.data(for: "probe") == Data("geheim".utf8))
            try keychain.delete("probe")
            #expect(try keychain.data(for: "probe") == nil)
        } catch .missingEntitlement {
            // Unsigned `swift test` binaries cannot use the data-protection keychain.
            // The app target (signed, sandboxed) exercises the real path.
        }
    }
}

/// Behaves like a connector whose session ran out: asks for a login only when allowed.
private struct ExpiredSessionConnector: BankConnector {
    let id: ConnectorID = .mock
    let logins: CallCounter

    func accounts() async throws -> [Account] {
        let challenge = AuthChallenge.pushConfirm(message: "Bitte freigeben")
        guard AuthInteraction.isAllowed else { throw ConnectorError.authRequired(challenge) }
        await logins.increment()
        return [Account(id: "a1", connectionID: "c1", type: .giro, name: "Giro")]
    }
    func balance(for account: Account) async throws -> Balance { Balance(bookedCents: 0, asOf: Date()) }
    func transactions(for account: Account, since: Date?) async throws -> [Transaction] { [] }
    func cardStatements(for account: Account) async throws -> [CardStatement] { [] }
    func securities(for account: Account) async throws -> [SecurityPosition] { [] }
}

@Suite struct AutomaticSyncLoginTests {
    let connection = Connection(id: "c1", connectorID: .mock, displayName: "Test")

    @Test func automaticSyncNeverLogsInAndWaitsForTheUser() async throws {
        let store = InMemoryLedgerStore()
        let logins = CallCounter()
        let clock = Clock()
        let engine = SyncEngine(store: store, now: { clock.now })
        try await engine.register(connection, connector: ExpiredSessionConnector(logins: logins))

        await engine.sync("c1", trigger: .automatic)
        #expect(await logins.count == 0)
        let state = await store.syncState(for: "c1")
        guard case .waitingForApproval = state.phase else {
            Issue.record("expected waitingForApproval, got \(state.phase)")
            return
        }
        #expect(state.consecutiveFailures == 0, "a due login is not a failure")

        // Later timer runs leave the bank alone until the user acts.
        clock.now += 60 * 60
        await engine.sync("c1", trigger: .automatic)
        await engine.sync("c1", trigger: .unlock)
        #expect(await logins.count == 0)

        await engine.sync("c1", trigger: .manual)
        #expect(await logins.count == 1)
        #expect(await store.syncState(for: "c1").phase == .idle)
    }

    @Test func syncAfterUnlockMayLogIn() async throws {
        let store = InMemoryLedgerStore()
        let logins = CallCounter()
        let engine = SyncEngine(store: store)
        try await engine.register(connection, connector: ExpiredSessionConnector(logins: logins))
        await engine.syncAll(trigger: .unlock)
        #expect(await logins.count == 1)
    }

    @Test func flagReachesTasksStartedInsideConnectors() async {
        let seen = await AuthInteraction.$isAllowed.withValue(false) {
            await Task { AuthInteraction.isAllowed }.value
        }
        #expect(seen == false)
    }
}

// MARK: - Accounts without a bank connection (protocol v10)

@Suite struct ManualConnectionSyncTests {
    @Test func engineNeverSyncsAManualConnection() async throws {
        let store = InMemoryLedgerStore()
        let counter = CallCounter()
        let engine = SyncEngine(store: store)
        let manual = Connection(id: "manual:A", connectorID: .manual, displayName: "Sparbuch")
        // Even if a connector is handed in by mistake, it is never called.
        try await engine.register(manual, connector: StubConnector(calls: counter))
        try await engine.register(Connection(id: "c1", connectorID: .mock, displayName: "Test"), connector: StubConnector(calls: counter))

        #expect(await engine.registeredConnections == ["c1"])
        await engine.syncAll(trigger: .manual)
        await engine.sync("manual:A", trigger: .manual)
        await engine.sync("manual:A", trigger: .automatic)

        #expect(await counter.count == 1)
        // The connection is stored (it lists its accounts), but it never gets a sync state.
        #expect(await store.snapshot().connections.contains(manual))
        #expect(await store.snapshot().syncStates["manual:A"] == nil)
    }
}
