import Foundation
import MFNCore
import Testing
@testable import MFNMock

@Suite struct MockDatasetTests {
    static let today = BankDay(iso: "2026-11-09") ?? .today
    let dataset = MockDataset.demo(today: Self.today, now: Self.today.startDate.addingTimeInterval(9 * 3600))

    @Test func shape() {
        #expect(dataset.connections.count == 6)
        #expect(dataset.accounts.count == 12)
        let count = dataset.allTransactions.count
        #expect((1_300...1_700).contains(count), "\(count) transactions")
        let oldest = dataset.allTransactions.map(\.effectiveDate).min()
        #expect(oldest.map { $0 >= Self.today.adding(months: -18) } == true)
        #expect(oldest.map { $0 <= Self.today.adding(months: -17) } == true)
    }

    @Test func deterministic() {
        let again = MockDataset.demo(today: Self.today, now: dataset.now)
        #expect(again.allTransactions.map(\.fingerprint).sorted() == dataset.allTransactions.map(\.fingerprint).sorted())
    }

    @Test func coversAllStatuses() {
        let statuses = Set(dataset.allTransactions.map(\.status))
        #expect(statuses == Set(TransactionStatus.allCases))
        let planned = dataset.allTransactions.filter { $0.status == .planned }
        #expect(planned.allSatisfy { $0.bookingDate == nil && $0.valueDate > Self.today })
        let pending = dataset.allTransactions.filter { $0.status == .pending }
        #expect(pending.allSatisfy { $0.bookingDate == nil })
    }

    @Test func idsUniquePerAccount() {
        for (_, list) in dataset.transactions {
            #expect(Set(list.map(\.id)).count == list.count)
        }
    }

    @Test func foreignCurrencyAndCards() {
        #expect(dataset.allTransactions.contains { $0.originalCurrency == "USD" && $0.originalAmountCents != nil })
        let dkbStatements = dataset.cardStatements[MockAccounts.dkbVisa] ?? []
        #expect(dkbStatements.count >= 17)
        #expect(dkbStatements.allSatisfy { $0.periodEnd.day == 22 })
        let easyStatements = dataset.cardStatements[MockAccounts.easyVisa] ?? []
        #expect(easyStatements.allSatisfy { $0.periodStart.day == 8 && $0.periodEnd.day == 7 })
        // Open period: booked purchases after the last closed statement.
        let lastEnd = dkbStatements.first?.periodEnd
        #expect(dataset.transactions[MockAccounts.dkbVisa]?.contains { $0.status == .booked && lastEnd.map($0.effectiveDate.isAfter) == true } == true)
    }

    @Test func cardBalanceIsOpenAmount() {
        // Every closed and due statement is settled, so the card balance only holds what is not yet paid.
        let balance = dataset.balance(for: MockAccounts.dkbVisa)
        #expect(balance.bookedCents <= 0)
        #expect(balance.bookedCents > -300_000)
        #expect(balance.availableCents.map { $0 <= 500_000 } == true)
    }

    @Test func pocketsHaveNoIBANAndDepotsHavePositions() {
        #expect(dataset.accounts.first { $0.id == MockAccounts.c24Pocket }?.iban == nil)
        #expect(dataset.securities[MockAccounts.trDepot]?.contains { $0.quantity != $0.quantity.rounded } == true)
        #expect(dataset.balance(for: MockAccounts.trDepot).bookedCents > 0)
    }

    @Test func giroBalancesStayPlausible() {
        for id in [MockAccounts.ingGiro, MockAccounts.dkbGiro, MockAccounts.c24Giro, MockAccounts.trCash] {
            let booked = dataset.balance(for: id).bookedCents
            #expect(booked > -200_000, "\(id): \(booked)")
        }
    }

    @Test func noRealLookingIBANs() {
        let ibans = dataset.accounts.compactMap(\.iban) + dataset.allTransactions.compactMap(\.counterpartIBAN)
        #expect(ibans.allSatisfy { $0.hasPrefix("DE00") })
    }
}

@Suite struct MockConnectorTests {
    let dataset = MockDataset.demo(today: BankDay(iso: "2026-11-09") ?? .today)

    @Test func requiresApprovalWithoutPresenterThrows() async {
        let connector = MockConnector(connection: MockConnections.dkb, dataset: dataset, scenario: .requiresApproval(.pushConfirm(message: "x")))
        await #expect(throws: ConnectorError.authRequired(.pushConfirm(message: "x"))) {
            try await connector.accounts()
        }
    }

    @Test func codeApproval() async throws {
        let ok = MockConnector(connection: MockConnections.tradeRepublic, dataset: dataset, scenario: .requiresApproval(.code(prompt: "Code", length: 4)), presenter: FixedPresenter(response: .code("4711")))
        #expect(try await ok.accounts().count == 2)

        let wrong = MockConnector(connection: MockConnections.tradeRepublic, dataset: dataset, scenario: .requiresApproval(.code(prompt: "Code", length: 4)), presenter: FixedPresenter(response: .code("0000")))
        await #expect(throws: ConnectorError.authFailed) { try await wrong.accounts() }
    }

    @Test func foreignAccountIsUnsupported() async throws {
        let ing = MockConnector(connection: MockConnections.ing, dataset: dataset)
        let dkbAccount = try #require(dataset.accounts(of: MockConnections.dkb).first)
        await #expect(throws: ConnectorError.unsupportedAccount) { try await ing.balance(for: dkbAccount) }
    }

    @Test func pendingIsBookedAfterwardsAndMergesWithoutDuplicates() async throws {
        let before = MockConnector(connection: MockConnections.dkb, dataset: dataset)
        let after = MockConnector(connection: MockConnections.dkb, dataset: dataset, phase: .afterBooking)
        let card = try #require(dataset.accounts.first { $0.id == MockAccounts.dkbVisa })

        let first = try await before.transactions(for: card, since: nil)
        let second = try await after.transactions(for: card, since: nil)
        #expect(first.contains { $0.status == .pending })
        #expect(!second.contains { $0.status == .pending })

        let merge = TransactionMerger.merge(stored: first, incoming: second, since: nil)
        #expect(merge.resolved.count == first.filter { $0.status == .pending }.count)
        let store = InMemoryLedgerStore()
        await store.apply(TransactionMerger.merge(stored: [], incoming: first, since: nil))
        await store.apply(merge)
        #expect(await store.storedTransactions(of: card.id).count == second.count)
    }

    @Test func syncEngineLoadsEverything() async throws {
        let store = InMemoryLedgerStore()
        let engine = SyncEngine(store: store)
        for (connection, connector) in dataset.demoConnectors(presenter: FixedPresenter(response: .confirmed), latency: .zero) {
            var connector = connector
            if case .requiresApproval(.code) = connector.scenario { connector.presenter = FixedPresenter(response: .code("1234")) }
            try await engine.register(connection, connector: connector)
        }
        await engine.syncAll(trigger: .manual)
        let snapshot = await store.snapshot()
        #expect(snapshot.accounts.count == 12)
        #expect(snapshot.transactions.count == dataset.allTransactions.count)
        #expect(snapshot.syncStates.values.allSatisfy { $0.phase == .idle })
        #expect(snapshot.securities.count == 6)
    }
}

struct FixedPresenter: AuthChallengePresenter {
    let response: AuthResponse
    func present(_ challenge: AuthChallenge) async throws -> AuthResponse { response }
}

extension BankDay {
    func isAfter(_ other: BankDay) -> Bool { self > other }
}

extension Decimal {
    var rounded: Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }
}

@Suite struct MockHeadlessLoginTests {
    @Test func headlessScenarioCompletesViaWebSession() async throws {
        let dataset = MockDataset.demo()
        let pairs = dataset.demoConnectorsWithHeadlessLogin(presenter: nil, latency: .zero)
        let easybank = try #require(pairs.first { $0.0.id == MockConnections.easybank }?.1)
        #expect(easybank.scenario == .requiresApproval(MockHeadlessLogin.challenge))
        guard case let .webLogin(request) = MockHeadlessLogin.challenge else { Issue.record("no web login"); return }
        #expect(request.automation != nil)
        #expect(request.url.scheme == "about")
        #expect(request.automation?.script.contains("mfn.requestCode") == true)
        // Without presenter the connector asks for the headless login.
        await #expect(throws: ConnectorError.authRequired(MockHeadlessLogin.challenge)) { try await easybank.accounts() }
    }
}
