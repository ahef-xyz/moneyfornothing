import Foundation
import MFNConformance
import MFNCore
import MFNScrape
import Testing
@testable import MFNC24

// MARK: - Conformance (over Fixtures/C24)

private func subject() -> ConformanceSubject {
    ConformanceSubject(
        name: "C24Connector (Fixtures/C24)",
        makeConnector: { Harness().connector },
        pending: .scenario(
            // Derived: the recorded card payment as preliminary, then as recorded (booked).
            before: { Harness().connector },
            after: { Harness(bank: FixtureBank(phase: .afterBooking)).connector }
        ),
        failures: [
            .init("Keine Sitzung, kein Presenter", expected: .authRequired(.pushConfirm(message: ""))) {
                Harness(stored: nil, presenter: nil).connector
            },
            .init("Login abgebrochen", expected: .cancelled) {
                Harness(stored: nil, presenter: .cancel).connector
            },
            // Entry missing entirely: WebLoginSession (MFNScrape) rejects the login against
            // `loginCompletion = .cookiesPresent(["sessionStore"])` before the connector sees it.
            .init("Login ohne sessionStore", expected: .authFailed) {
                Harness(stored: nil, presenter: .login(token: nil)).connector
            },
            .init("sessionStore ohne accessToken", expected: .sessionExpired) {
                Harness(stored: nil, presenter: .loginRaw(#"{"refreshToken":"x"}"#)).connector
            },
            .init("sessionStore kein JSON", expected: .sessionExpired) {
                Harness(stored: nil, presenter: .loginRaw("kein-json")).connector
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
            .init("Endpunkte nicht verifiziert", expected: .formatChanged(detail: "")) {
                var endpoints = TestValues.endpoints
                endpoints.verified = false
                return Harness(endpoints: endpoints).connector
            },
        ],
        secrets: TestValues.secrets
    )
}

@Suite(.serialized) struct C24ConformanceTests {
    @Test func passesConformance() async {
        let report = await ConnectorConformance.run(subject())
        #expect(report.passed, "\(report)")
        #expect(report.outcome(of: "pending → booked") == .passed)
        #expect(report.outcome(of: "since respektiert") == .passed)
    }
}

// MARK: - Accounts and balances (accounts.json, pockets.json)

private func account(_ harness: Harness, named name: String) async throws -> Account {
    try #require(try await harness.connector.accounts().first { $0.name == name })
}

@Suite struct C24AccountTests {
    @Test func deliversCurrentAccountsAndAllPockets() async throws {
        let accounts = try await Harness().connector.accounts()
        #expect(accounts.map(\.name) == ["Konto 01", "Konto 02", "Pocket 01", "Pocket 02", "Pocket 03", "Pocket 04", "Pocket 05"])
        #expect(accounts.filter { $0.type == .giro }.map(\.name) == ["Konto 01", "Konto 02"])
        #expect(accounts.filter { $0.type == .tagesgeld }.count == 5)
        #expect(accounts.first { $0.name == "Pocket 05" }?.iban == TestValues.pocketPlusIBAN)
        #expect(accounts.first { $0.name == "Konto 01" }?.iban == "DE00895531523778866583")
        #expect(accounts.allSatisfy { $0.connectionID == TestValues.connection && $0.currency == "EUR" })
    }

    /// pockets.json repeats the pockets of accounts.json (with anonymised, colliding `id`s):
    /// they are merged by pocket number, not duplicated.
    @Test func pocketsEndpointIsMergedByNumber() async throws {
        let harness = Harness()
        let accounts = try await harness.connector.accounts()
        #expect(Set(accounts.map(\.id)).count == 7)
        let paths = await harness.transport.requests.compactMap { $0.url?.path() }
        #expect(paths.contains("/api/v3/pockets/"))
    }

    @Test func accountIDsAreStableAndOpaque() async throws {
        let first = try await Harness().connector.accounts().map(\.id)
        let second = try await Harness().connector.accounts().map(\.id)
        #expect(first == second)
        for id in first {
            #expect(id.rawValue.hasPrefix("c24-"))
            #expect(!TestValues.secrets.contains { id.rawValue.contains($0) })
        }
    }

    @Test func balancesFromAccountList() async throws {
        let harness = Harness()
        let pocketPlus = try await account(harness, named: "Pocket 05")
        let balance = try await harness.connector.balance(for: pocketPlus)
        #expect(balance.bookedCents == 142_029)
        #expect(balance.availableCents == 142_029)
        #expect(balance.asOf == TestValues.now)
        #expect(try await harness.connector.balance(for: try await account(harness, named: "Pocket 03")).bookedCents == 143_503)
        #expect(try await harness.connector.balance(for: try await account(harness, named: "Konto 01")).bookedCents == 0)
        let requests = await harness.transport.requests.compactMap { $0.url?.path() }
        #expect(!requests.contains { $0.contains("balance") }) // no balance endpoint
    }

    @Test func noCardStatementsOrSecurities() async throws {
        let harness = Harness()
        for account in try await harness.connector.accounts() {
            #expect(try await harness.connector.cardStatements(for: account).isEmpty)
            #expect(try await harness.connector.securities(for: account).isEmpty)
        }
    }

    @Test func foreignAccountRejected() async {
        let foreign = Account(id: "x", connectionID: "other", type: .giro, name: "x")
        await #expect(throws: ConnectorError.unsupportedAccount) { _ = try await Harness().connector.balance(for: foreign) }
        let unknown = Account(id: "c24-unknown", connectionID: TestValues.connection, type: .giro, name: "x")
        await #expect(throws: ConnectorError.unsupportedAccount) { _ = try await Harness().connector.transactions(for: unknown, since: nil) }
    }
}

// MARK: - Transactions (transactions-*.json, upcoming-transactions.json)

@Suite struct C24TransactionTests {
    @Test func pagesWithOffsetUntilMoreIsFalse() async throws {
        let harness = Harness()
        let pocketPlus = try await account(harness, named: "Pocket 05")
        let transactions = try await harness.connector.transactions(for: pocketPlus, since: nil)

        #expect(transactions.count == 60)
        #expect(transactions.allSatisfy { $0.status == .booked && $0.bookingDate != nil })
        #expect(Set(transactions.map(\.id)).count == 60)
        let searches = await harness.searches()
        #expect(searches.map(\.offset) == [0, 30, 60])
        #expect(searches.allSatisfy { $0.number == TestValues.pocketPlusNumber })

        let body = try #require(await harness.transport.requests.last { $0.httpMethod == "POST" }?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let criteria = try #require(json["criteria"] as? [String: Any])
        // Exactly the recorded body: guessed extra criteria made the real server answer HTTP 500.
        #expect(Set(criteria.keys) == ["account_numbers"])
        #expect(Set(json.keys) == ["criteria", "pagination"])
        #expect((json["pagination"] as? [String: Any])?["limit"] as? Int == 30)
    }

    @Test func sinceStopsPagingEarly() async throws {
        let harness = Harness()
        let pocketPlus = try await account(harness, named: "Pocket 05")
        let since = try #require(BankDay(iso: "2026-01-15"))
        let transactions = try await harness.connector.transactions(for: pocketPlus, since: since.startDate)
        #expect(!transactions.isEmpty)
        #expect(transactions.allSatisfy { $0.effectiveDate >= since })
        // Page 1 reaches back to 2025-12-17 – far enough, page 2 is not requested.
        #expect(await harness.searches().map(\.offset) == [0])
    }

    @Test func mapsInstantTransfer() async throws {
        let harness = Harness()
        let transactions = try await harness.connector.transactions(for: try await account(harness, named: "Pocket 05"), since: nil)
        let transfer = try #require(transactions.first { $0.externalID == "76814ada7" })
        #expect(transfer.id == "ext:76814ada7")
        #expect(transfer.amountCents == -176_545)
        #expect(transfer.bookingDate == BankDay(iso: "2026-02-23"))
        #expect(transfer.valueDate == BankDay(iso: "2026-02-23"))
        #expect(transfer.counterpartName == "Gegenpartei 01")
        #expect(transfer.counterpartIBAN == "DE00241912686812512422")
        #expect(transfer.purpose == "Verwendungszweck 01")
        #expect(transfer.eref == "55f552eed8d5f35a7368f3c593143dba") // from `ent_to_end_id`
        #expect(transfer.categoryID == nil) // C24's own category_id stays in rawJSON only
        let raw = try #require(try JSONSerialization.jsonObject(with: transfer.rawJSON) as? [String: Any])
        #expect(raw["id"] as? String == "76814ada7")
        #expect(raw["category_id"] as? Int == 100)
    }

    @Test func mapsDirectDebitWithoutOwnIBANAsCounterpart() async throws {
        let harness = Harness()
        let transactions = try await harness.connector.transactions(for: try await account(harness, named: "Pocket 05"), since: nil)
        let debit = try #require(transactions.first { $0.externalID == "f90b50493" })
        #expect(debit.amountCents == -31_527)
        #expect(debit.bookingDate == BankDay(iso: "2026-02-20"))
        #expect(debit.mref == "585981c43bc7")
        #expect(debit.creditorID == "FCf64ECe8a0cab9f2d")
        #expect(debit.counterpartIBAN == nil) // the IBAN detail is the pocket's own IBAN
        #expect(debit.purpose == "Verwendungszweck 03")
    }

    @Test func mapsInterestAndPocketTransferWithoutPurpose() async throws {
        let harness = Harness()
        let transactions = try await harness.connector.transactions(for: try await account(harness, named: "Pocket 05"), since: nil)
        let interest = try #require(transactions.first { $0.externalID == "9dd3569a9" })
        #expect(interest.amountCents == 1_236)
        #expect(interest.counterpartName == "C24 Bank")
        #expect(interest.purpose == "Interest Applied")
        #expect(interest.bookingDate == BankDay(iso: "2026-01-14"))
        let transfer = try #require(transactions.first { $0.externalID == "1f1205121" })
        #expect(transfer.amountCents == -35_394)
        #expect(transfer.purpose == "SCT - outgoing")
        #expect(transfer.counterpartIBAN == nil)
    }

    @Test func mapsCardPaymentAndDerivedPreliminary() async throws {
        let after = Harness(bank: FixtureBank(phase: .afterBooking))
        let booked = try await after.connector.transactions(for: try await account(after, named: "Pocket 01"), since: nil)
        let card = try #require(booked.first { $0.externalID == TestValues.cardTransactionID })
        #expect(card.status == .booked)
        #expect(card.amountCents == -5_378)
        #expect(card.bookingDate == BankDay(iso: "2026-02-16"))
        #expect(card.purpose == "Beschreibung 04")
        #expect(card.counterpartName == "Gegenpartei 31")

        let before = Harness()
        let old = try await before.connector.transactions(for: try await account(before, named: "Pocket 01"), since: nil)
        let hold = try #require(old.first { $0.externalID == "hold-\(TestValues.cardTransactionID)" })
        #expect(hold.status == .pending)
        #expect(hold.bookingDate == nil)
        #expect(hold.valueDate == BankDay(iso: "2026-02-16"))

        let merge = TransactionMerger.merge(stored: old, incoming: booked, since: nil)
        #expect(merge.resolved[hold.id] == card.id)
        #expect(merge.deletions.contains(hold.id))
    }

    @Test func standingOrdersArePlannedOnTheirAccount() async throws {
        let harness = Harness()
        let accounts = try await harness.connector.accounts() // one sync
        let joint = try #require(accounts.first { $0.name == "Konto 02" })
        let planned = try await harness.connector.transactions(for: joint, since: nil).filter { $0.status == .planned }
        #expect(planned.count == 4)
        #expect(planned.allSatisfy { $0.bookingDate == nil && $0.valueDate == BankDay(iso: "2026-03-08") && $0.amountCents < 0 })
        #expect(planned.map(\.amountCents).sorted() == [-30_959, -15_148, -15_148, -15_148])
        let first = try #require(planned.first { $0.externalID == "standing-order:9759394:2026-03-08" })
        #expect(first.counterpartName == "Gegenpartei 33")
        #expect(first.counterpartIBAN == "DE00300157843046474015")
        #expect(first.purpose == "Verwendungszweck 49")

        let quarterly = try await harness.connector.transactions(for: try #require(accounts.first { $0.name == "Pocket 02" }), since: nil)
        #expect(quarterly.filter { $0.status == .planned }.map(\.amountCents) == [-22_738])
        #expect(await harness.transport.requests.filter { $0.url?.path() == "/api/v2/upcoming-transactions/" }.count == 1) // once per sync
    }

    @Test func directDebitsArePlannedOnTheDebtorAccount() async throws {
        let harness = Harness()
        let pocket04 = try await account(harness, named: "Pocket 04")
        let planned = try await harness.connector.transactions(for: pocket04, since: nil).filter { $0.status == .planned }
        #expect(planned.map(\.amountCents).sorted() == [-85_287, -14_789])
        let debit = try #require(planned.first { $0.amountCents == -85_287 })
        #expect(debit.valueDate == BankDay(iso: "2026-02-25"))
        #expect(debit.counterpartName == "Gegenpartei 37")
        #expect(debit.mref == "ab1cef3e99-ff")
        #expect(debit.creditorID == "20d51ca8ea4f6a72c6")
        #expect(debit.externalID == "direct-debit:dde9f7ec202b412843156d6a7512137a")
    }
}

// MARK: - Session

@Suite struct C24SessionTests {
    @Test func storedSessionNeedsNoLogin() async throws {
        let harness = Harness()
        _ = try await harness.connector.accounts()
        #expect(harness.presenterCalls.count == 0)
        let first = try #require(await harness.transport.requests.first)
        #expect(first.url?.path() == "/api/v2/user/me/")
    }

    @Test func bearerTokenGoesIntoHeaderNeverIntoCookie() async throws {
        let harness = Harness()
        let pocket = try await account(harness, named: "Pocket 05")
        _ = try await harness.connector.transactions(for: pocket, since: nil)
        for request in await harness.transport.requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestValues.validToken)")
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            #expect(!cookie.contains(TestValues.validToken))
            #expect(!cookie.contains(TestValues.refreshToken))
            #expect(!cookie.contains(TestValues.storeKey))
            #expect(request.value(forHTTPHeaderField: "x-c24-guid") != nil)
            #expect(request.value(forHTTPHeaderField: "x-c24-timestamp").flatMap(Int64.init) != nil)
        }
    }

    @Test func freshLoginStoresTokenAndOnlyC24Cookies() async throws {
        let harness = Harness(stored: nil)
        _ = try await harness.connector.accounts()
        #expect(harness.presenterCalls.count == 1)
        let stored = try #require(try harness.store.load(Harness.storeKey))
        #expect(stored.contains { $0.name == TestValues.storeKey && $0.value == TestValues.storeValue(token: TestValues.validToken) })
        #expect(stored.allSatisfy { $0.domain.hasSuffix("c24.de") })

        // Next sync with the same keychain: no new login.
        let next = Harness(stored: nil, store: harness.store)
        _ = try await next.connector.accounts()
        #expect(next.presenterCalls.count == 0)
    }

    /// The access token ran out: renewed with the refresh token, no QR login.
    @Test func staleSessionIsRenewedWithoutLogin() async throws {
        let harness = Harness(stored: TestValues.staleToken)
        #expect(try await harness.connector.accounts().count == 7)
        #expect(harness.presenterCalls.count == 0)
        let stored = try #require(try harness.store.load(Harness.storeKey))
        let entry = try #require(stored.first { $0.name == TestValues.storeKey })
        #expect(C24SessionStore.accessToken(in: entry.value, field: "accessToken") == TestValues.validToken)
        #expect(entry.value.contains("customerId"), "other sessionStore fields stay")
    }

    @Test func staleSessionWithRefusedRenewalAsksForOneLogin() async throws {
        let harness = Harness(bank: FixtureBank(fault: .rejectRefresh), stored: TestValues.staleToken)
        #expect(try await harness.connector.accounts().count == 7)
        #expect(harness.presenterCalls.count == 1)
        let stored = try #require(try harness.store.load(Harness.storeKey))
        #expect(!stored.contains { $0.value.contains(TestValues.staleToken) })
    }

    /// A network failure during the renewal is no refusal: the session stays, no QR login.
    @Test func renewalOutageKeepsSessionAndAsksForNoLogin() async throws {
        let harness = Harness(bank: FixtureBank(fault: .refreshUnavailable), stored: TestValues.staleToken)
        await #expect(throws: ConnectorError.bankUnavailable) { _ = try await harness.connector.accounts() }
        #expect(harness.presenterCalls.count == 0)
        let stored = try #require(try harness.store.load(Harness.storeKey))
        #expect(stored.contains { $0.value.contains(TestValues.staleToken) })
    }

    @Test func storedSessionWithoutTokenAsksForLogin() async throws {
        let harness = Harness(stored: nil, store: InMemorySessionCookieStore([Harness.storeKey: TestValues.session(token: nil)]))
        _ = try await harness.connector.accounts()
        #expect(harness.presenterCalls.count == 1)
    }

    @Test func storedSessionStoreThatIsNotJSONAsksForLogin() async throws {
        let store = InMemorySessionCookieStore([Harness.storeKey: TestValues.session(rawStore: "{kaputt")])
        let harness = Harness(stored: nil, store: store)
        #expect(try await harness.connector.accounts().count == 7)
        #expect(harness.presenterCalls.count == 1)
    }

    @Test func freshLoginWithoutAccessTokenIsSessionExpired() async {
        let harness = Harness(stored: nil, presenter: .loginRaw(#"{"accessToken":""}"#))
        await #expect(throws: ConnectorError.sessionExpired) { _ = try await harness.connector.accounts() }
        #expect(harness.presenterCalls.count == 1) // asked once, not again within this sync
        #expect((try? harness.store.load(Harness.storeKey)) == .some(nil))
        #expect(await harness.transport.requests.isEmpty)
    }

    /// With a completion that does not require the entry, the connector itself reports the missing token.
    @Test func missingSessionStoreIsSessionExpiredInTheConnector() async {
        var endpoints = TestValues.endpoints
        endpoints.loginCompletion = .urlPrefix("https://banking.c24.de/")
        let harness = Harness(stored: nil, presenter: .login(token: nil), endpoints: endpoints)
        await #expect(throws: ConnectorError.sessionExpired) { _ = try await harness.connector.accounts() }
        #expect(harness.presenterCalls.count == 1)
    }

    @Test func rejectedFreshLoginIsAuthFailedAndNeverRetried() async {
        let harness = Harness(bank: FixtureBank(fault: .rejectEverySession))
        await #expect(throws: ConnectorError.authFailed) { _ = try await harness.connector.accounts() }
        #expect(harness.presenterCalls.count == 1)
        #expect((try? harness.store.load(Harness.storeKey)) == .some(nil))
    }

    @Test func expiryDuringSyncDiscardsSession() async throws {
        let harness = Harness(bank: FixtureBank(fault: .expireOnTransactions))
        let pocket = try await account(harness, named: "Pocket 05")
        await #expect(throws: ConnectorError.sessionExpired) { _ = try await harness.connector.transactions(for: pocket, since: nil) }
        #expect(harness.presenterCalls.count == 0) // no login mid-sync
        #expect((try? harness.store.load(Harness.storeKey)) == .some(nil))
    }

    @Test func withoutPresenterRequiresWebLogin() async throws {
        let harness = Harness(stored: nil, presenter: nil)
        do {
            _ = try await harness.connector.accounts()
            Issue.record("expected authRequired")
        } catch let ConnectorError.authRequired(.webLogin(request)) {
            #expect(request.url == TestValues.endpoints.loginURL)
            #expect(request.cookieDomains == ["c24.de"])
            #expect(request.storageKeys == [StorageKey(key: "sessionStore", source: .sessionStorage, domain: "banking.c24.de")])
            #expect(request.completion == .cookiesPresent(["sessionStore"]))
        }
        #expect(await harness.transport.requests.isEmpty)
    }

    @Test func unverifiedEndpointsNeverStartALogin() async {
        var endpoints = TestValues.endpoints
        endpoints.verified = false
        let harness = Harness(stored: nil, endpoints: endpoints)
        await #expect(throws: ConnectorError.self) { _ = try await harness.connector.accounts() }
        #expect(harness.presenterCalls.count == 0)
        #expect(await harness.transport.requests.isEmpty)
    }

    /// The production login: the storage entry alone (no C24 cookie at all) completes it.
    @Test func productionLoginIsCompletedByTheStorageEntry() async throws {
        #expect(C24Endpoints.production.verified)
        let request = C24Endpoints.production.loginRequest
        #expect(request.storageKeys == [StorageKey(key: "sessionStore", source: .sessionStorage, domain: "banking.c24.de")])

        let entryOnly = [SessionCookie(name: "sessionStore", value: TestValues.storeValue(token: TestValues.validToken), domain: "banking.c24.de", isHTTPOnly: false)]
        let store = InMemorySessionCookieStore()
        let session = WebLoginSession(key: "k", request: request, presenter: FixedPresenter(cookies: entryOnly), store: store)
        let cookies = try await session.cookies(forceLogin: true)
        #expect(cookies.map(\.name) == ["sessionStore"])
        #expect(try store.load("k")?.count == 1)
    }

    /// C24 logs in by QR code + 6 digits from the app (no password form). Protocol v5: the app
    /// draws the QR code, so production runs headless; switched off, the page shows its own code.
    @Test func productionLoginIsHeadlessQRLogin() {
        let request = C24Endpoints.production.loginRequest
        #expect(request.automation != nil)
        var visible = C24Endpoints.production
        visible.headlessLogin = false
        #expect(visible.loginRequest.automation == nil)
        #expect(visible.loginRequest.message.contains("QR"))
    }

    /// Production endpoints (verified) over the fixture backend: login, storage hand-over, sync.
    @Test func productionEndpointsSyncAfterWebLogin() async throws {
        let harness = Harness(stored: nil, presenter: .loginRaw(TestValues.storeValue(token: TestValues.validToken)), endpoints: .production)
        let accounts = try await harness.connector.accounts()
        #expect(accounts.count == 7)
        #expect(harness.presenterCalls.count == 1)
        #expect(try harness.store.load(Harness.storeKey)?.contains { $0.name == "sessionStore" } == true)
    }

    @Test func readOnlyRequests() async throws {
        let harness = Harness()
        for account in try await harness.connector.accounts() {
            _ = try await harness.connector.balance(for: account)
            _ = try await harness.connector.transactions(for: account, since: nil)
        }
        let requests = await harness.transport.requests
        #expect(!requests.isEmpty)
        for request in requests where request.httpMethod != "GET" {
            #expect(request.httpMethod == "POST" && request.url?.path() == "/api/v3/transactions/search/")
        }
    }
}

private struct FixedPresenter: AuthChallengePresenter {
    let cookies: [SessionCookie]
    func present(_ challenge: AuthChallenge) async throws -> AuthResponse { .webSession(cookies) }
}
