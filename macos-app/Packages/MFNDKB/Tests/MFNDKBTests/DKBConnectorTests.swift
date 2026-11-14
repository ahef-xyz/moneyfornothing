import Foundation
import MFNConformance
import MFNCore
import MFNScrape
import Testing
@testable import MFNDKB

// MARK: - Conformance (over Fixtures/DKB/web)

private func subject() -> ConformanceSubject {
    ConformanceSubject(
        name: "DKBConnector (Fixtures/DKB/web)",
        makeConnector: { Harness().connector },
        pending: .scenario(
            // Derived: one recorded giro payment as pending (no pending item in the HAR), then as recorded (booked).
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
            .init("Login ohne Zugriffstoken", expected: .authFailed) {
                Harness(stored: nil, presenter: .login(token: nil)).connector
            },
            .init("Bank lehnt frische Sitzung ab", expected: .authFailed) {
                Harness(bank: FixtureBank(fault: .rejectEverySession), stored: nil).connector
            },
            .init("Sitzung läuft während des Syncs ab", expected: .sessionExpired) {
                Harness(bank: FixtureBank(fault: .expireOnTransactions)).connector
            },
            .init("429", expected: .rateLimited(retryAfter: 0)) {
                Harness(bank: FixtureBank(fault: .rateLimited)).connector
            },
            .init("Antwortformat geändert", expected: .formatChanged(detail: "")) {
                Harness(bank: FixtureBank(fault: .changedFormat)).connector
            },
        ],
        secrets: TestValues.secrets
    )
}

@Suite(.serialized) struct DKBConformanceTests {
    @Test func passesConformance() async {
        let report = await ConnectorConformance.run(subject())
        #expect(report.passed, "\(report)")
        #expect(report.outcome(of: "pending → booked") == .passed)
        #expect(report.outcome(of: "since respektiert") == .passed)
    }
}

// MARK: - Accounts, balances, transactions

@Suite struct DKBConnectorTests {
    @Test func accountsWithGroupNames() async throws {
        let harness = Harness()
        let accounts = try await harness.connector.accounts()
        #expect(accounts.map(\.name) == ["Girokonto 2", "Gruppe 2", "Girokonto 1", "Gruppe 3"])
        #expect(accounts.allSatisfy { $0.type == .giro && $0.connectionID == TestValues.connection && $0.iban?.hasPrefix("DE00") == true })
        #expect(try await Harness().connector.accounts().map(\.id) == accounts.map(\.id))
        #expect(harness.bank.requests.all == ["/api/accounts/accounts?filter[product.type][NEQ]=loan", "/api/config/users/me/product-display-settings"])
    }

    @Test func brokenGroupsKeepProductNames() async throws {
        let accounts = try await Harness(bank: FixtureBank(fault: .brokenGroups)).connector.accounts()
        #expect(accounts.map(\.name) == ["Girokonto 2", "Girokonto 1", "Girokonto 1", "Girokonto 1"])
    }

    @Test func balancesInExactCents() async throws {
        let connector = Harness().connector
        let accounts = try await connector.accounts()
        let balances = try await accounts.asyncMap { try await connector.balance(for: $0) }
        #expect(balances.map(\.bookedCents) == [454086, 0, 0, 0])
        #expect(balances.map(\.availableCents) == [454086, 16129, 88249, 16129])
        #expect(balances.allSatisfy { $0.currency == "EUR" && $0.asOf == TestValues.now })
    }

    @Test func pagesUntilTheLastPage() async throws {
        let harness = Harness()
        let accounts = try await harness.connector.accounts()
        let giro3 = accounts[3]
        let transactions = try await harness.connector.transactions(for: giro3, since: nil)
        // 3 on page 1, 12 on page 2 – the first three again (overlap at the cursor) – no further link.
        #expect(transactions.count == 12)
        #expect(Set(transactions.map(\.id)).count == 12)
        let pages = harness.bank.requests.all.filter { $0.contains("/transactions") }
        #expect(pages == [
            "/api/accounts/accounts/\(TestValues.giro3ID)/transactions?expand=Merchant,International&page[size]=25",
            "/api/accounts/accounts/\(TestValues.giro3ID)/transactions?expand=Merchant,International&page[size]=25&page[after]=\(TestValues.giro3Cursor)",
        ])
        #expect(transactions.map(\.effectiveDate) == transactions.map(\.effectiveDate).sorted(by: >))
    }

    @Test func emptyNextPageEndsPaging() async throws {
        let harness = Harness()
        let giro1 = try await harness.connector.accounts()[1]
        let transactions = try await harness.connector.transactions(for: giro1, since: nil)
        #expect(transactions.count == 25)
        #expect(harness.bank.requests.all.filter { $0.contains("/transactions") }.count == 2)
        #expect(transactions.filter { $0.amountCents < 0 }.allSatisfy { !$0.counterpartName.isEmpty })
    }

    @Test func stopsPagingAtSince() async throws {
        let harness = Harness()
        let giro1 = try await harness.connector.accounts()[1]
        let since = try #require(BankDay(iso: "2024-09-15")).startDate
        let transactions = try await harness.connector.transactions(for: giro1, since: since)
        #expect(!transactions.isEmpty)
        #expect(transactions.allSatisfy { $0.effectiveDate >= BankDay(iso: "2024-09-15")! })
        #expect(transactions.count == 11)
        // The first page reaches back before `since`: no second request.
        #expect(harness.bank.requests.all.filter { $0.contains("/transactions") }.count == 1)
    }

    @Test func pendingKeepsNoBookingDateAndIgnoresSince() async throws {
        let harness = Harness(bank: FixtureBank(phase: .beforeBooking))
        let giro1 = try await harness.connector.accounts()[1]
        let since = try #require(BankDay(iso: "2026-02-15")).startDate
        let transactions = try await harness.connector.transactions(for: giro1, since: since)
        let pending = try #require(transactions.first { $0.status == .pending })
        #expect(pending.bookingDate == nil && pending.valueDate == BankDay(iso: "2025-03-17"))
        #expect(pending.externalID == "pending-0001")
    }

    @Test func foreignAccountIsRejected() async throws {
        let connector = Harness().connector
        let first = try #require(try await connector.accounts().first)
        let foreign = Account(id: "dkbweb-foreign", connectionID: TestValues.connection, type: .giro, name: "x")
        await #expect(throws: ConnectorError.unsupportedAccount) { try await connector.transactions(for: foreign, since: nil) }
        let otherConnection = Account(id: first.id, connectionID: "other", type: .giro, name: "x")
        await #expect(throws: ConnectorError.unsupportedAccount) { try await connector.balance(for: otherConnection) }
        #expect(try await connector.cardStatements(for: first).isEmpty)
        #expect(try await connector.securities(for: first).isEmpty)
    }
}

// MARK: - Session

@Suite struct DKBSessionTests {
    @Test func storedSessionNeedsNoLogin() async throws {
        let harness = Harness()
        #expect(try await harness.connector.accounts().count == 4)
        #expect(harness.presenter?.calls.count == 0)
    }

    @Test func loginRequestIsHeadless() async throws {
        let harness = Harness(stored: nil)
        _ = try await harness.connector.accounts()
        let request = try #require(harness.presenter?.requests.all.first)
        #expect(request.url.absoluteString == "https://banking.dkb.de/login")
        #expect(request.completion == .cookiesPresent(["mfn-dkb-login-done", "__Secure-at", "__Host-xsrf"]))
        #expect(request.cookieDomains == ["dkb.de"])
        #expect(request.storageKeys.isEmpty)
        let automation = try #require(request.automation)
        #expect(automation.script == DKBLoginScript.source)
        #expect(automation.timeout == 480)
        // Credentials are never part of the request (the app passes them to the script as an argument).
        #expect(ConnectorID.dkb.credentialFields.map(\.key) == ["username", "password"])
        #expect(!automation.script.contains(TestValues.password))
    }

    @Test func freshLoginStoresEveryApiCookie() async throws {
        let harness = Harness(stored: nil)
        _ = try await harness.connector.accounts()
        let stored = try #require(try harness.store.load(TestValues.storeKey))
        let names = Set(stored.map(\.name))
        #expect(names.isSuperset(of: ["__Secure-at", "__Secure-rt", "__Host-sid", "__Host-sid.sig", "__Host-xsrf", "__Secure-ssoIdToken"]))
        #expect(!names.contains("tracking"))
    }

    @Test func expiredStoredSessionLogsInOnce() async throws {
        let harness = Harness(stored: TestValues.session(token: TestValues.staleToken))
        #expect(try await harness.connector.accounts().count == 4)
        #expect(harness.presenter?.calls.count == 1)
        let stored = try #require(try harness.store.load(TestValues.storeKey))
        #expect(stored.contains { $0.name == "__Secure-at" && $0.value == TestValues.validToken })
    }

    @Test func storedSessionWithoutAccessTokenSkipsTheRequest() async throws {
        let harness = Harness(stored: TestValues.session(token: nil))
        _ = try await harness.connector.accounts()
        #expect(harness.presenter?.calls.count == 1)
        // Only the requests after the login: account list + groups.
        #expect(harness.bank.requests.all.count == 2)
    }

    @Test func rejectedFreshLoginIsNotRetried() async throws {
        let harness = Harness(bank: FixtureBank(fault: .rejectEverySession), stored: nil)
        await #expect(throws: ConnectorError.authFailed) { try await harness.connector.accounts() }
        #expect(harness.presenter?.calls.count == 1)
        #expect(try harness.store.load(TestValues.storeKey) == nil)
    }

    @Test func expiryMidSyncDiscardsTheSession() async throws {
        let harness = Harness(bank: FixtureBank(fault: .expireOnTransactions))
        let giro = try #require(try await harness.connector.accounts().first)
        await #expect(throws: ConnectorError.sessionExpired) { try await harness.connector.transactions(for: giro, since: nil) }
        #expect(try harness.store.load(TestValues.storeKey) == nil)
        #expect(harness.presenter?.calls.count == 0)
    }

    @Test func parallelCallsShareOneLogin() async throws {
        let harness = Harness(stored: nil)
        async let first = harness.connector.accounts()
        async let second = harness.connector.accounts()
        _ = try await (first, second)
        #expect(harness.presenter?.calls.count == 1)
    }

    @Test func xsrfHeaderFollowsTheCookie() {
        let headers = DKBEndpoints.headers(cookies: TestValues.session())
        #expect(headers["x-xsrf-token"] == TestValues.xsrf)
        #expect(headers["application-name"] == "web-banking")
        #expect(DKBEndpoints.headers(cookies: TestValues.session(xsrf: nil))["x-xsrf-token"] == nil)
    }
}
