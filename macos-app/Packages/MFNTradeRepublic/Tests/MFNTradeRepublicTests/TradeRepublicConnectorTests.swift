import Foundation
import MFNConformance
import MFNCore
import Testing
@testable import MFNTradeRepublic

// MARK: - Conformance

@Sendable private func failing(_ failure: TRWorld.Failure, stored: [SessionCookie] = []) -> TradeRepublicConnector {
    TRWorld(failure: failure).connector(server: TRWorld(failure: failure).server(), store: InMemoryTRSessionStore(stored))
}

private func subject() -> ConformanceSubject {
    ConformanceSubject(
        name: "TradeRepublicConnector (Fixtures + synthetisch)",
        makeConnector: { TRWorld().connector() },
        pending: .scenario(
            before: { TRWorld(phase: .beforeBooking).connector() },
            after: { TRWorld(phase: .afterBooking).connector() }
        ),
        failures: [
            .init("Web-Login ohne Presenter", expected: .authRequired(TRSession.loginChallenge)) {
                TRWorld().connector(server: TRWorld().server(), presenter: nil)
            },
            .init("Web-Login abgebrochen", expected: .cancelled) {
                TRWorld().connector(server: TRWorld().server(), presenter: FakePresenter(.cancel))
            },
            .init("Web-Login ohne tr_session", expected: .authFailed) {
                TRWorld().connector(server: TRWorld().server(), presenter: FakePresenter(.webSession(Array(TRWorld.webCookies.dropFirst()))))
            },
            .init("Sitzung auch nach Login abgelehnt", expected: .authFailed) { failing(.sessionRejected) },
            .init("429", expected: .rateLimited(retryAfter: 120)) { failing(.rateLimited, stored: TRWorld.storedSession) },
            .init("Server 503", expected: .bankUnavailable) { failing(.serverDown, stored: TRWorld.storedSession) },
            .init("WebSocket-Sitzung abgelehnt", expected: .sessionExpired) { failing(.socketAuthError, stored: TRWorld.storedSession) },
            .init("Timeline unlesbar", expected: .formatChanged(detail: "")) { failing(.brokenTimeline) },
            .init("WebSocket nicht erreichbar", expected: .bankUnavailable) { failing(.socketUnreachable) },
        ],
        secrets: [TRWorld.sessionValue, TRWorld.refreshValue, TRWorld.wafValue, TRWorld.fixtureIBAN, TRWorld.fixtureCashAccountNumber, TRWorld.counterpartIBAN]
    )
}

@Suite(.serialized) struct TradeRepublicConformanceTests {
    @Test func conformance() async {
        let report = await ConnectorConformance.run(subject())
        #expect(report.passed, "\(report)")
        #expect(report.outcome(of: "pending → booked") == .passed, "\(report)")
        #expect(report.outcome(of: "since respektiert") == .passed, "\(report)")
    }
}

// MARK: - Connector

@Suite struct TradeRepublicConnectorTests {
    @Test func accountsFromFixtures() async throws {
        let accounts = try await TRWorld().connector().accounts()
        #expect(accounts.map(\.type) == [.giro, .depot])
        #expect(accounts.map(\.id.rawValue) == ["tr-test:cash", "tr-test:depot"])
        #expect(accounts[0].iban == TRWorld.fixtureIBAN)
        #expect(accounts[0].cardLast4 == TRWorld.fixtureCardLast4)
        #expect(accounts.allSatisfy { $0.connectionID == TRWorld.connection && $0.currency == "EUR" })
    }

    @Test func accountWithoutCard() async throws {
        let world = TRWorld(failure: .noCard)
        let accounts = try await world.connector(server: world.server()).accounts()
        #expect(accounts[0].cardLast4 == nil)
        #expect(accounts[0].iban == TRWorld.fixtureIBAN)
    }

    @Test func cardServerErrorDoesNotFailSync() async throws {
        // First real sync (2026-11-10): cards/home answered HTTP 500. The card is optional.
        let world = TRWorld(failure: .cardServerError)
        let accounts = try await world.connector(server: world.server()).accounts()
        #expect(accounts[0].cardLast4 == nil)
        #expect(accounts[0].iban == TRWorld.fixtureIBAN)
    }

    @Test func cashBalanceInCents() async throws {
        let connector = TRWorld().connector()
        let cash = try #require(try await connector.accounts().first)
        let balance = try await connector.balance(for: cash)
        #expect(balance.bookedCents == 123_456)
        #expect(balance.currency == "EUR")
    }

    @Test func fixtureTimelineMapsEveryItem() async throws {
        let server = TRWorld().server()
        let connector = TRWorld().connector(server: server)
        let cash = try #require(try await connector.accounts().first)
        let transactions = try await connector.transactions(for: cash, since: nil)
        let fromFixture = transactions.filter { !($0.externalID ?? "").hasPrefix("syn-") }

        #expect(fromFixture.count == TRWorld.fixtureTransactionCount)
        #expect(fromFixture.reduce(0) { $0 + $1.amountCents } == TRWorld.fixtureSumCents)
        #expect(fromFixture.allSatisfy { $0.status == .booked && $0.bookingDate != nil && $0.currency == "EUR" })
        #expect(fromFixture.allSatisfy { $0.id.rawValue == "ext:\($0.externalID ?? "")" })

        let first = try #require(fromFixture.first)
        #expect(first.externalID == "0d20d93a-af9b-4f8f-809d-68d3e6ac42bd")
        #expect(first.amountCents == 1)
        #expect(first.bookingDate == BankDay(iso: "2025-05-18"))
        #expect(first.counterpartName == "title 018")
        #expect(first.purpose == "subtitle 070")
        #expect(JSONValue.parse(first.rawJSON)?["presentation"]?["type"]?.string == "listItem", "raw item kept unchanged")

        let incoming = try #require(fromFixture.first { $0.externalID == "785bfad0-9f6a-4285-a2eb-e0a260fe21bb" })
        #expect(incoming.amountCents == 19_620_000)
        #expect(incoming.counterpartIBAN == TRWorld.counterpartIBAN, "detail (synthetic) merged")
        #expect(incoming.purpose == "Referenz 785bfad0-9f6a-4285-a2eb-e0a260fe21bb")
        #expect(JSONValue.parse(incoming.rawJSON)?["timeline"]?["eventType"]?.string == "BANK_TRANSACTION_INCOMING")

        // Paging over cursors.after into the (synthetic) second page.
        let timelineCalls = server.httpRequests.filter { $0.url?.path == "/api/v2/timeline/transactions" }
        #expect(timelineCalls.count == 2)
        #expect(timelineCalls.first?.url?.query == nil, "first page without query (HAR)")
        #expect(timelineCalls.last?.url?.query == "olderThan=after%20169")

        // Details only for the 13 bank transfers of the fixture.
        #expect(server.subTypes.filter { $0 == "timelineDetailV2" }.count == 13)
    }

    @Test func syntheticEdgeCases() async throws {
        let connector = TRWorld().connector()
        let cash = try #require(try await connector.accounts().first)
        let byID = Dictionary(uniqueKeysWithValues: try await connector.transactions(for: cash, since: nil).map { ($0.externalID ?? "", $0) })

        let card = try #require(byID["syn-card-1"])
        #expect(card.status == .pending)
        #expect(card.bookingDate == nil)
        #expect(card.valueDate == BankDay(iso: "2026-02-22"))
        #expect(card.purpose == "Kartenzahlung")

        let usd = try #require(byID["syn-card-usd"])
        #expect(usd.amountCents == -920)
        #expect(usd.originalAmountCents == -1_000)
        #expect(usd.originalCurrency == "USD")

        #expect(byID["syn-doc"] == nil, "items without amount are skipped")
        #expect(byID["syn-interest"]?.bookingDate == BankDay(iso: "2024-07-16"), "22:05 UTC on 15 Jul is 16 Jul in Berlin")
        #expect(byID["syn-unknown"]?.purpose == "benefits_saveback_execution")
        #expect(byID["syn-failed"]?.status == .cancelled)
    }

    @Test func sinceStopsPagingAndFilters() async throws {
        let server = TRWorld().server()
        let connector = TRWorld().connector(server: server)
        let cash = try #require(try await connector.accounts().first)
        let since = try #require(BankDay(iso: "2025-01-15")).startDate
        let transactions = try await connector.transactions(for: cash, since: since)
        #expect(Set(transactions.compactMap(\.externalID)) == [
            "syn-card-1",
            "0d20d93a-af9b-4f8f-809d-68d3e6ac42bd",
            "769ed2df-f780-4275-9fa2-a409255b1930",
            "f563b533-cb7b-4850-9142-e4576a0b7a03",
            "41da1ce1-195d-44de-831b-4597feabebca",
        ])
        #expect(server.httpRequests.filter { $0.url?.path == "/api/v2/timeline/transactions" }.count == 1, "page 1 already reaches before since")
        #expect(server.subTypes.filter { $0 == "timelineDetailV2" }.count == 1, "details only inside the window")
    }

    @Test func pendingBecomesBookedUnderSameID() async throws {
        let before = TRWorld(phase: .beforeBooking).connector()
        let after = TRWorld(phase: .afterBooking).connector()
        let cash = try #require(try await before.accounts().first)
        let pending = try #require(try await before.transactions(for: cash, since: nil).first { $0.externalID == "syn-card-1" })
        let booked = try #require(try await after.transactions(for: cash, since: nil).first { $0.externalID == "syn-card-1" })
        #expect(pending.id == booked.id)
        #expect(booked.status == .booked)
        #expect(booked.bookingDate == BankDay(iso: "2026-02-22"))
    }

    @Test func detailsAreFetchedOncePerConnector() async throws {
        let server = TRWorld().server()
        let connector = TRWorld().connector(server: server)
        let cash = try #require(try await connector.accounts().first)
        let first = try await connector.transactions(for: cash, since: nil)
        let requested = server.subTypes.filter { $0 == "timelineDetailV2" }.count
        #expect(requested > 0)
        let second = try await connector.transactions(for: cash, since: nil)
        #expect(server.subTypes.filter { $0 == "timelineDetailV2" }.count == requested)
        #expect(first.map(\.id) == second.map(\.id), "order preserved")
        #expect(first.map(\.counterpartIBAN) == second.map(\.counterpartIBAN))
    }

    @Test func detailFailureDisablesDetailsButKeepsSync() async throws {
        let world = TRWorld(failure: .detailRejected)
        let server = world.server()
        let connector = world.connector(server: server)
        let cash = try #require(try await connector.accounts().first)
        let transactions = try await connector.transactions(for: cash, since: nil)
        #expect(transactions.count == TRWorld.fixtureTransactionCount + 5)
        #expect(transactions.allSatisfy { $0.counterpartIBAN == nil })
        // Requests already in flight when the first one failed may still go out, nothing after them.
        #expect(server.subTypes.filter { $0 == "timelineDetailV2" }.count <= TRService.detailConcurrency, "no further detail requests after the first failure")
    }

    @Test func pennyStockCountsInDepotBalance() async throws {
        // 12.345678 × €0.003 = €0.037 → 4 cents, although the rounded price is 0 cents.
        let world = TRWorld(failure: .pennyStock)
        let connector = world.connector(server: world.server())
        let depot = try #require(try await connector.accounts().last)
        let positions = try await connector.securities(for: depot)
        #expect(positions[1].priceCents == 0)
        let balance = try await connector.balance(for: depot)
        #expect(balance.bookedCents == 25_686 + 4, "1.5 × 171.24 + 12.345678 × 0.003, rounded once")
    }

    @Test func depotPositionsWithPrices() async throws {
        let server = TRWorld().server()
        let connector = TRWorld().connector(server: server)
        let depot = try #require(try await connector.accounts().last)
        let positions = try await connector.securities(for: depot)
        #expect(positions.map(\.isin) == ["US0378331005", "IE00B4L5Y983"], "zero position skipped")
        #expect(positions[0].name == "Apple")
        #expect(positions[0].quantity == Decimal(string: "1.5"))
        #expect(positions[0].priceCents == 17_124)
        #expect(positions[1].priceCents == 9_876, "bid used without last price, rounded half-even")
        #expect(positions[0].purchasePriceCents == 12_010, "averageBuyIn as string")
        #expect(positions[1].purchasePriceCents == 8_000)
        #expect(positions[0].gainCents == 7_671, "1.5 × (171.24 − 120.10) = 76.71")
        #expect(server.subs.contains { $0["id"]?.string == "US0378331005.LSX" })
        // Retired topic (BAD_SUBSCRIPTION_TYPE since 2026-11-10) is no longer used.
        #expect(!server.subTypes.contains("compactPortfolio"))
        #expect(server.subTypes.contains("accountPairs"))

        let balance = try await connector.balance(for: depot)
        // Exact prices, rounded once: 1.5 × 171.24 + 12.345678 × 98.765 = 1,476.1809 → 147,618 cents
        // (summing the rounded position values would give 147,612).
        #expect(balance.bookedCents == 147_618)
        #expect(try await connector.transactions(for: depot, since: nil).isEmpty)
        #expect(try await connector.cardStatements(for: depot).isEmpty)
    }

    @Test func foreignAccountRejected() async {
        let connector = TRWorld().connector()
        let foreign = Account(id: "tr-test:other", connectionID: TRWorld.connection, type: .giro, name: "x")
        await #expect(throws: ConnectorError.unsupportedAccount) { _ = try await connector.balance(for: foreign) }
        let otherConnection = Account(id: "tr-test:cash", connectionID: "other", type: .giro, name: "x")
        await #expect(throws: ConnectorError.unsupportedAccount) { _ = try await connector.transactions(for: otherConnection, since: nil) }
    }

    @Test func oneSocketAndOneLoginForAllCalls() async throws {
        let server = TRWorld().server()
        let presenter = FakePresenter(.webSession(TRWorld.webCookies))
        let connector = TRWorld().connector(server: server, presenter: presenter)
        let accounts = try await connector.accounts()
        for account in accounts {
            _ = try await connector.balance(for: account)
            _ = try await connector.transactions(for: account, since: nil)
            _ = try await connector.securities(for: account)
        }
        #expect(presenter.count == 1)
        #expect(server.opened == 1)
        #expect(server.unsubs.count == server.subs.count, "every subscription is closed")
    }

    @Test func concurrentCallsShareLoginAndSocket() async throws {
        let server = TRWorld().server()
        let presenter = FakePresenter(.webSession(TRWorld.webCookies))
        let connector = TRWorld().connector(server: server, presenter: presenter)
        let accounts = try await TRWorld().connector().accounts()
        async let a = connector.transactions(for: accounts[0], since: nil)
        async let b = connector.securities(for: accounts[1])
        async let c = connector.balance(for: accounts[0])
        _ = try await (a, b, c)
        #expect(presenter.count == 1)
        #expect(server.opened == 1)
    }
}

// MARK: - Session (web login, cookies)

@Suite struct TRSessionTests {
    @Test func webLoginStoresOnlyCookiesForTheAPI() async throws {
        let store = InMemoryTRSessionStore()
        let presenter = FakePresenter(.webSession(TRWorld.webCookies))
        _ = try await TRWorld().connector(server: TRWorld().server(), presenter: presenter, store: store).accounts()

        guard case let .webLogin(request) = try #require(presenter.challenges.withLock { $0.first }) else {
            Issue.record("expected web login")
            return
        }
        #expect(request.url.absoluteString == "https://app.traderepublic.com/login")
        #expect(request.completion == .cookiesPresent(["tr_session"]))
        #expect(request.cookieDomains == ["traderepublic.com"])
        #expect(try store.load().map(\.name) == ["tr_session", "tr_refresh", "aws-waf-token"])
    }

    @Test func requestsCarryCookiesAndWAFToken() async throws {
        let server = TRWorld().server()
        let connector = TRWorld().connector(server: server)
        let cash = try #require(try await connector.accounts().first)
        _ = try await connector.balance(for: cash)
        let request = try #require(server.httpRequests.first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "tr_session=\(TRWorld.sessionValue); tr_refresh=\(TRWorld.refreshValue); aws-waf-token=\(TRWorld.wafValue)")
        #expect(request.value(forHTTPHeaderField: "x-aws-waf-token") == TRWorld.wafValue)
        #expect(request.value(forHTTPHeaderField: "x-tr-platform") == "web")
        // Like the web app: without X-TR-App-Version the API answers HTTP 400.
        #expect(server.httpRequests.allSatisfy { $0.value(forHTTPHeaderField: "x-tr-app-version") == FakeTRServer.webAppVersion })
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://app.traderepublic.com")
        #expect(server.versionRequests == 1, "app version is fetched once per session")
        #expect(server.openCookies.first == request.value(forHTTPHeaderField: "Cookie"), "WebSocket uses the same session")
    }

    @Test func storedSessionNeedsNoLogin() async throws {
        let presenter = FakePresenter(.cancel)
        _ = try await TRWorld().connector(server: TRWorld().server(), presenter: presenter, store: InMemoryTRSessionStore(TRWorld.storedSession)).accounts()
        #expect(presenter.count == 0)
    }

    @Test func rejectedStoredSessionLeadsToOneWebLogin() async throws {
        let stale = [SessionCookie(name: "tr_session", value: "stale", domain: ".traderepublic.com")]
        let store = InMemoryTRSessionStore(stale)
        let presenter = FakePresenter(.webSession(TRWorld.webCookies))
        _ = try await TRWorld().connector(server: TRWorld().server(), presenter: presenter, store: store).accounts()
        #expect(presenter.count == 1)
        #expect(try store.load().first?.value == TRWorld.sessionValue)
    }

    @Test func rejectedStoredSessionWithoutPresenterNeedsLogin() async throws {
        let stale = [SessionCookie(name: "tr_session", value: "stale", domain: ".traderepublic.com")]
        let store = InMemoryTRSessionStore(stale)
        let connector = TRWorld().connector(server: TRWorld().server(), presenter: nil, store: store)
        await #expect(throws: ConnectorError.authRequired(TRSession.loginChallenge)) { _ = try await connector.accounts() }
        #expect(try store.load().isEmpty)
    }

    @Test func expiredSessionCookieIsNotSent() async throws {
        let expired = [SessionCookie(name: "tr_session", value: TRWorld.sessionValue, domain: ".traderepublic.com", expires: Date(timeIntervalSince1970: 1_000))]
        let presenter = FakePresenter(.webSession(TRWorld.webCookies))
        let server = TRWorld().server()
        _ = try await TRWorld().connector(server: server, presenter: presenter, store: InMemoryTRSessionStore(expired)).accounts()
        #expect(presenter.count == 1, "login before the first request")
        #expect(server.httpRequests.count == 2)
    }

    /// Refused right after the login → the login did not work: `authFailed`, never retried.
    @Test func rejectedFreshLoginIsNotRetried() async {
        let world = TRWorld(failure: .sessionRejected)
        let server = world.server()
        let presenter = FakePresenter(.webSession(TRWorld.webCookies))
        await #expect(throws: ConnectorError.authFailed) {
            _ = try await world.connector(server: server, presenter: presenter).accounts()
        }
        #expect(presenter.count == 1)
        #expect(server.httpRequests.count == 1)
    }

    @Test func wrongResponseTypeFailsLogin() async {
        let connector = TRWorld().connector(server: TRWorld().server(), presenter: FakePresenter(.code("1234")))
        await #expect(throws: ConnectorError.authFailed) { _ = try await connector.accounts() }
        #expect(ConnectorError.authFailed.forbidsAutomaticRetry)
    }

    @Test func rotatedCookieIsStored() async throws {
        let rotated = "trs-rotated-session-9999"
        let store = InMemoryTRSessionStore(TRWorld.storedSession)
        let server = FakeTRServer(http: { _, _, _, _ in
            (200, ["Set-Cookie": "tr_session=\(rotated); Domain=traderepublic.com; Path=/; Secure; HttpOnly"], #"{"accounts":[{"accountId":"a","status":"ACTIVE"}]}"#)
        }, sub: { _, _ in [] })
        _ = try await TRWorld().connector(server: server, store: store).accounts()
        let stored = try store.load()
        #expect(stored.first { $0.name == "tr_session" }?.value == rotated)
        #expect(stored.contains { $0.name == "tr_refresh" })
    }

    @Test func socketAuthErrorForgetsSession() async throws {
        let store = InMemoryTRSessionStore(TRWorld.storedSession)
        let world = TRWorld(failure: .socketAuthError)
        let connector = world.connector(server: world.server(), store: store)
        let cash = try #require(try await connector.accounts().first)
        await #expect(throws: ConnectorError.sessionExpired) { _ = try await connector.balance(for: cash) }
        #expect(try store.load().isEmpty)
    }

    @Test func cookieDomainMatching() {
        #expect(TRSession.domainMatches(".traderepublic.com", host: "api.traderepublic.com"))
        #expect(TRSession.domainMatches("traderepublic.com", host: "api.traderepublic.com"))
        #expect(TRSession.domainMatches("api.traderepublic.com", host: "api.traderepublic.com"))
        #expect(!TRSession.domainMatches("app.traderepublic.com", host: "api.traderepublic.com"))
        #expect(!TRSession.domainMatches("eviltraderepublic.com", host: "api.traderepublic.com"))
        #expect(!TRSession.domainMatches("", host: "api.traderepublic.com"))
    }

    @Test func cookiesAreRedacted() {
        #expect(!"\(TRWorld.webCookies[0])".contains(TRWorld.sessionValue))
        #expect(!"\(AuthResponse.webSession(TRWorld.webCookies))".contains(TRWorld.sessionValue))
    }
}

// MARK: - Recorded fixtures (Fixtures/TradeRepublic)

@Suite struct TRFixtureTests {
    @Test func timelinePageParses() throws {
        let json = try #require(JSONValue.parse(try Fixtures.data(.tradeRepublic, "timeline-page1.json")))
        let page = try TRMapping.timelinePage(json)
        #expect(page.items.count == TRWorld.fixtureTransactionCount)
        #expect(page.after == "after 169")
        let unknown = page.items.map(TRMapping.eventType).filter { if case .unknown = $0 { true } else { false } }
        #expect(unknown.isEmpty, "all recorded event types are known")
        for item in page.items {
            #expect(try TRMapping.transaction(item: item, detail: nil, account: "fixture") != nil)
        }
    }

    @Test func accountsAndCardParse() throws {
        let card = TRMapping.card(try #require(JSONValue.parse(try Fixtures.data(.tradeRepublic, "cards-home.json"))))
        #expect(card == .init(last4: "0394", authAccountID: "b88c51cd-d8cd-4337-ad75-daa875ea93a1"))
        let accounts = try #require(JSONValue.parse(try Fixtures.data(.tradeRepublic, "accounts-switchable.json")))
        let account = try TRMapping.cashAccount(accounts, preferredID: card.authAccountID)
        #expect(account == .init(accountID: "b88c51cd-d8cd-4337-ad75-daa875ea93a1", iban: TRWorld.fixtureIBAN))
    }

    @Test func loginFixturesMatchWebLoginAssumption() throws {
        // The native v2 login needs an app approval and AWS WAF; MFN uses the web view instead.
        let login = try #require(JSONValue.parse(try Fixtures.data(.tradeRepublic, "login.json")))
        #expect(login["processId"]?.string != nil)
        let done = try #require(JSONValue.parse(try Fixtures.data(.tradeRepublic, "login-process-done.json")))
        #expect(done["status"]?.string == "CONFIRMED")
    }

    @Test func unrecordedFixturesParseOnceAdded() throws {
        if Fixtures.exists(.tradeRepublic, "timeline-detail.json") {
            _ = TRMapping.detailFields(try #require(JSONValue.parse(try Fixtures.data(.tradeRepublic, "timeline-detail.json"))))
        }
        if Fixtures.exists(.tradeRepublic, "compact-portfolio.json") {
            _ = try TRMapping.positions(try #require(JSONValue.parse(try Fixtures.data(.tradeRepublic, "compact-portfolio.json"))))
        }
        if Fixtures.exists(.tradeRepublic, "cash.json") {
            _ = try TRMapping.cash(try #require(JSONValue.parse(try Fixtures.data(.tradeRepublic, "cash.json"))))
        }
        if Fixtures.exists(.tradeRepublic, "timeline-page2.json") {
            let page = try TRMapping.timelinePage(try #require(JSONValue.parse(try Fixtures.data(.tradeRepublic, "timeline-page2.json"))))
            for item in page.items { _ = try TRMapping.transaction(item: item, detail: nil, account: "fixture") }
        }
    }
}
