import Foundation
import MFNConformance
import MFNCore
import MFNScrape
import Testing
@testable import MFNN26

// MARK: - Conformance (over Fixtures/N26)

private func subject() -> ConformanceSubject {
    ConformanceSubject(
        name: "N26Connector (Fixtures/N26)",
        makeConnector: { Harness().connector },
        pending: .scenario(
            // Derived: one recorded main-account payment with a pending status icon, then as recorded (booked).
            before: { Harness(bank: FixtureBank(phase: .beforeBooking)).connector },
            after: { Harness(bank: FixtureBank(phase: .afterBooking)).connector }
        ),
        failures: [
            .init("Keine Sitzung, kein Presenter", expected: .authRequired(.pushConfirm(message: ""))) {
                Harness(stored: nil, presenter: nil).connector
            },
            .init("Login abgebrochen", expected: .cancelled) {
                Harness(stored: nil, presenter: .cancel).connector
            },
            .init("Login ohne n26.token", expected: .authFailed) {
                Harness(stored: nil, presenter: .login(token: nil)).connector
            },
            .init("Bank lehnt frische Sitzung ab", expected: .authFailed) {
                Harness(bank: FixtureBank(fault: .rejectEverySession), stored: nil).connector
            },
            .init("Sitzung läuft während des Syncs ab", expected: .sessionExpired) {
                Harness(bank: FixtureBank(fault: .expireOnTimeline)).connector
            },
            .init("429", expected: .rateLimited(retryAfter: 0)) {
                Harness(bank: FixtureBank(fault: .rateLimited)).connector
            },
            .init("Antwortformat geändert", expected: .formatChanged(detail: "")) {
                Harness(bank: FixtureBank(fault: .changedFormat)).connector
            },
            .init("Seite ohne __PEK__", expected: .formatChanged(detail: "")) {
                Harness(bank: FixtureBank(fault: .htmlWithoutKey), stored: TestValues.session(token: TestValues.validToken, csrf: nil, pek: nil)).connector
            },
        ],
        secrets: TestValues.secrets
    )
}

@Suite(.serialized) struct N26ConformanceTests {
    @Test func passesConformance() async {
        let report = await ConnectorConformance.run(subject())
        #expect(report.passed, "\(report)")
        #expect(report.outcome(of: "pending → booked") == .passed)
        #expect(report.outcome(of: "since respektiert") == .passed)
    }
}

// MARK: - Accounts, balances, transactions

@Suite struct N26ConnectorTests {
    @Test func mainAccountAndSpaces() async throws {
        let harness = Harness()
        let accounts = try await harness.connector.accounts()
        #expect(accounts.map(\.name) == ["Hauptkonto", "Space 01", "Space 02"])
        #expect(accounts.map(\.type) == [.giro, .tagesgeld, .tagesgeld])
        #expect(accounts.allSatisfy { $0.connectionID == TestValues.connection && $0.currency == "EUR" && $0.iban == nil })
        #expect(accounts.allSatisfy { $0.id.rawValue.hasPrefix("n26-") && !$0.id.rawValue.contains(TestValues.mainID) })
        // Stable IDs across instances.
        #expect(try await Harness().connector.accounts().map(\.id) == accounts.map(\.id))
        // The overview query asks for all activities (accountId null).
        #expect(harness.bank.variables.all.first == ["operation": "getTransactionsList", "accountId": "null"])
    }

    @Test func balancesFromEachFeed() async throws {
        let connector = Harness().connector
        let accounts = try await connector.accounts()
        let balances = try await accounts.asyncMap { try await connector.balance(for: $0) }
        #expect(balances.allSatisfy { $0.currency == "EUR" && $0.availableCents == nil && $0.asOf == TestValues.now })
        #expect(balances[2].bookedCents == 62547)
    }

    @Test func pagesThroughTheTimeline() async throws {
        let harness = Harness()
        let main = try #require(try await harness.connector.accounts().first)
        let transactions = try await harness.connector.transactions(for: main, since: nil)
        #expect(transactions.count == 35) // 15 on the feed page + 20 on page 2; page 3 empty
        let timeline = harness.bank.variables.all.filter { $0["operation"] == "getTimeline" }
        #expect(timeline.count == 2)
        #expect(timeline.first?["paginationKey"] == (try FixtureBank.paginationKey(of: "feed-main.json")))
        #expect(timeline.last?["paginationKey"] == (try FixtureBank.paginationKey(of: "timeline-main-page2.json")))
        #expect(timeline.allSatisfy { $0["accountId"] == TestValues.mainID && $0["activity"] == nil })
        #expect(Set(transactions.map(\.id)).count == transactions.count)
        // Newest first, as the feed delivers.
        #expect(transactions.map(\.valueDate) == transactions.map(\.valueDate).sorted(by: >))
    }

    @Test func stopsPagingAtSince() async throws {
        let harness = Harness()
        let main = try #require(try await harness.connector.accounts().first)
        let since = try #require(BankDay(iso: "2026-01-29")).startDate
        let transactions = try await harness.connector.transactions(for: main, since: since)
        #expect(!transactions.isEmpty)
        #expect(transactions.allSatisfy { $0.effectiveDate >= BankDay(since) })
        // The first page already reaches back before `since`: no getTimeline call.
        #expect(harness.bank.variables.all.filter { $0["operation"] == "getTimeline" }.isEmpty)
    }

    @Test func spaceWithoutFurtherPages() async throws {
        let harness = Harness()
        let space = try #require(try await harness.connector.accounts().last)
        #expect(try await harness.connector.transactions(for: space, since: nil).count == 3)
        #expect(harness.bank.variables.all.filter { $0["operation"] == "getTimeline" }.isEmpty)
    }

    @Test func foreignAccountIsRejected() async throws {
        let connector = Harness().connector
        _ = try await connector.accounts()
        let foreign = Account(id: "n26-foreign", connectionID: TestValues.connection, type: .giro, name: "x")
        await #expect(throws: ConnectorError.unsupportedAccount) { try await connector.transactions(for: foreign, since: nil) }
        let otherConnection = Account(id: "n26-foreign", connectionID: "other", type: .giro, name: "x")
        await #expect(throws: ConnectorError.unsupportedAccount) { try await connector.balance(for: otherConnection) }
        #expect(try await connector.cardStatements(for: try #require(try await connector.accounts().first)).isEmpty)
        #expect(try await connector.securities(for: try #require(try await connector.accounts().first)).isEmpty)
    }
}

// MARK: - Session

@Suite struct N26SessionTests {
    @Test func storedSessionNeedsNoLogin() async throws {
        let harness = Harness()
        _ = try await harness.connector.accounts()
        #expect(harness.presenter?.calls.count == 0)
        #expect(harness.bank.bootstraps.count == 0) // CSRF token and key came with the session
    }

    @Test func loginRequestIsHeadless() async throws {
        let harness = Harness(stored: nil)
        _ = try await harness.connector.accounts()
        let request = try #require(harness.presenter?.requests.all.first)
        #expect(request.url.absoluteString == "https://app.n26.com/login")
        #expect(request.completion == .cookiesPresent(["n26.token"]))
        #expect(request.cookieDomains == ["n26.com"])
        let automation = try #require(request.automation)
        #expect(automation.script == N26LoginScript.source)
        #expect(automation.timeout == 300)
        #expect(request.storageKeys.map(\.key) == ["n26.csrfToken", "n26.pek"])
        #expect(request.storageKeys.allSatisfy { $0.source == .javaScript && $0.domain == "app.n26.com" && $0.expression != nil })
        // Credentials are never part of the request (the app passes them to the script as an argument).
        #expect(ConnectorID.n26.credentialFields.map(\.key) == ["username", "password"])
    }

    @Test func expiredStoredSessionLogsInOnce() async throws {
        let harness = Harness(stored: TestValues.session(token: TestValues.staleToken))
        let accounts = try await harness.connector.accounts()
        #expect(accounts.count == 3)
        #expect(harness.presenter?.calls.count == 1)
        // The stale session is first retried with fresh CSRF token / key from the HTML, then replaced.
        #expect(harness.bank.bootstraps.count == 1)
        let stored = try #require(try harness.store.load("n26.\(TestValues.connection.rawValue)"))
        #expect(stored.contains { $0.name == "n26.token" && $0.value == TestValues.validToken })
        #expect(stored.contains { $0.name == "n26.csrfToken" && $0.value == TestValues.csrfToken })
        #expect(stored.contains { $0.name == "n26.pek" && $0.value == TestValues.pek })
        #expect(!stored.contains { $0.domain == "ads.example.invalid" })
    }

    @Test func staleCSRFTokenIsRefreshedWithoutLogin() async throws {
        let harness = Harness(stored: TestValues.session(token: TestValues.validToken, csrf: TestValues.staleCSRF))
        _ = try await harness.connector.accounts()
        #expect(harness.presenter?.calls.count == 0)
        #expect(harness.bank.bootstraps.count == 1)
        let stored = try #require(try harness.store.load("n26.\(TestValues.connection.rawValue)"))
        #expect(stored.contains { $0.name == "n26.csrfToken" && $0.value == TestValues.csrfToken })
    }

    @Test func rotatedKeyIsReloaded() async throws {
        let harness = Harness(bank: FixtureBank(fault: .rotatedKeyOnce))
        #expect(try await harness.connector.accounts().count == 3)
        #expect(harness.bank.bootstraps.count == 1)
        #expect(harness.presenter?.calls.count == 0)
    }

    @Test func loginWithoutStorageValuesBootstraps() async throws {
        let harness = Harness(stored: nil, presenter: .login(token: TestValues.validToken, csrf: nil, pek: nil))
        #expect(try await harness.connector.accounts().count == 3)
        #expect(harness.bank.bootstraps.count == 1)
    }

    @Test func rejectedFreshLoginIsNotRetried() async throws {
        let harness = Harness(bank: FixtureBank(fault: .rejectEverySession), stored: nil)
        await #expect(throws: ConnectorError.authFailed) { try await harness.connector.accounts() }
        #expect(harness.presenter?.calls.count == 1)
        #expect(try harness.store.load("n26.\(TestValues.connection.rawValue)") == nil)
    }

    @Test func expiryMidSyncDiscardsTheSession() async throws {
        let harness = Harness(bank: FixtureBank(fault: .expireOnTimeline))
        let main = try #require(try await harness.connector.accounts().first)
        await #expect(throws: ConnectorError.sessionExpired) { try await harness.connector.transactions(for: main, since: nil) }
        #expect(try harness.store.load("n26.\(TestValues.connection.rawValue)") == nil)
        #expect(harness.presenter?.calls.count == 0)
    }

    @Test func parallelCallsShareOneLogin() async throws {
        let harness = Harness(stored: nil)
        async let first = harness.connector.accounts()
        async let second = harness.connector.accounts()
        _ = try await (first, second)
        #expect(harness.presenter?.calls.count == 1)
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
