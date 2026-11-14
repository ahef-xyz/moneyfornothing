import Foundation
import MFNConformance
import MFNCore
import MFNScrape
import Testing
@testable import MFNEasybank

// MARK: - Harness (fixtures only, never a real bank)

struct NoSleep: Sleeper {
    func sleep(seconds: TimeInterval) async throws {}
}

enum Harness {
    static let connectionID: ConnectionID = "test-easybank"
    static let sessionKey = "easybank.test-easybank"
    static let fedAuth = "FEDAUTH-SECRET-VALUE-0815"
    static let xsrf = "XSRF-SECRET-VALUE-4711"
    static let uniqueKey = "UNIQUEKEY-SECRET-639298"
    static let pcid = "PCID-SECRET-42"
    static let fixedNow = Date(timeIntervalSince1970: 1_771_891_200) // 2026-02-24

    static var cookies: [SessionCookie] {
        [
            SessionCookie(name: "FedAuth", value: fedAuth, domain: "banking.easybank.de"),
            SessionCookie(name: "XSRF-TOKEN", value: xsrf, domain: "banking.easybank.de", isHTTPOnly: false),
            SessionCookie(name: EasybankEndpoints.uniqueKeyName, value: uniqueKey, domain: "banking.easybank.de", isHTTPOnly: false),
            SessionCookie(name: EasybankEndpoints.pcidName, value: pcid, domain: "banking.easybank.de", isHTTPOnly: false),
        ]
    }

    /// `RetailLanding` answer: `cards.json` is the landing `Item` inside `InitialCallResponses`
    /// (endpoints.md, Ablauf 2); the outer envelope is not recorded and built here.
    static func landing() throws -> Data {
        let item = try JSONSerialization.jsonObject(with: Fixtures.data(.easybank, "cards.json"))
        let envelope: [String: Any] = [
            "Item": ["InitialCallResponses": [["Response": ["Item": true]], ["Response": ["Item": item, "Result": ["IsSuccess": true]]]]],
            "Result": ["IsSuccess": true],
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    /// Identifying values of the fixture account, read at runtime so they never appear in code.
    struct FixtureAccount {
        var number: String
        var iban: String
        var maskedCard: String
        var holder: String
    }

    static func fixtureAccount() throws -> FixtureAccount {
        let landing = try JSONDecoder().decode(JSONValue.self, from: Fixtures.data(.easybank, "cards.json"))
        let account = landing["AccountListResponse"]?["AccountList"]?.arrayValue?.first
        let card = landing["DashboardTransactionItemList"]?.arrayValue?.first?["TransactionItem"]
        guard case let .string(number) = account?["Number"], case let .string(iban) = account?["IBAN"],
              case let .string(masked) = card?["MaskedCardNumber"], case let .string(holder) = card?["CardHoldersName"]
        else { throw ConnectorError.formatChanged(detail: "cards.json layout") }
        return FixtureAccount(number: number, iban: iban, maskedCard: masked, holder: holder)
    }

    static func history() throws -> Data {
        try Fixtures.data(.easybank, "account-transaction-history.json")
    }

    /// The same account after the bank booked the pending items: `Pending` → `Unbilled`, posting
    /// one day later, the USD purchase at a slightly different rate (10,69 € → 10,80 €).
    static func historyAfterBooking() throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: history()) as? [String: Any],
              var item = root["Item"] as? [String: Any],
              var calls = item["InitialCallResponses"] as? [[String: Any]] else { throw ConnectorError.formatChanged(detail: "history layout") }
        for index in calls.indices {
            guard var response = calls[index]["Response"] as? [String: Any],
                  var list = response["Item"] as? [String: Any],
                  var transactions = list["Transactions"] as? [[String: Any]] else { continue }
            for t in transactions.indices where transactions[t]["TransactionType"] as? String == "Pending" {
                transactions[t]["TransactionType"] = "Unbilled"
                let date = (transactions[t]["TransactionDate"] as? String).flatMap { BankDay(iso: String($0.prefix(10))) }
                transactions[t]["PostingDate"] = (date?.adding(days: 1).iso ?? "") + "T00:00:00+00:00"
                if var local = transactions[t]["LocalCurrencyAmount"] as? [String: Any], (local["Value"] as? NSNumber)?.stringValue == "10.69" {
                    local["Value"] = NSDecimalNumber(string: "10.80")
                    transactions[t]["LocalCurrencyAmount"] = local
                }
            }
            list["Transactions"] = transactions
            response["Item"] = list
            calls[index]["Response"] = response
        }
        item["InitialCallResponses"] = calls
        root["Item"] = item
        return try JSONSerialization.data(withJSONObject: root)
    }

    static func ok(_ request: URLRequest, body: Data) -> (Data, HTTPURLResponse) {
        ScriptedHTTPTransport.response(request.url, body: body)
    }

    /// Scripted bank: answers by path.
    static func transport(history: @escaping @Sendable () throws -> Data = { try Harness.history() }) -> ScriptedHTTPTransport {
        ScriptedHTTPTransport { request, _ in
            switch request.url?.path() {
            case EasybankEndpoints.retailLanding: return ok(request, body: try landing())
            case EasybankEndpoints.accountTransactionHistory: return ok(request, body: try history())
            default: return ScriptedHTTPTransport.response(request.url, status: 404)
            }
        }
    }

    static func connector(
        transport: ScriptedHTTPTransport = Harness.transport(),
        store: InMemorySessionCookieStore = InMemorySessionCookieStore([Harness.sessionKey: Harness.cookies]),
        presenter: (any AuthChallengePresenter)? = nil
    ) -> EasybankConnector {
        EasybankConnector(
            connectionID: connectionID, presenter: presenter, store: store, transport: transport,
            policy: BackoffPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0), sleeper: NoSleep(), now: { fixedNow }
        )
    }

    static func failing(status: Int, body: Data = Data()) -> EasybankConnector {
        connector(transport: ScriptedHTTPTransport { request, _ in
            ScriptedHTTPTransport.response(request.url, status: status, headers: ["Retry-After": "120"], body: body)
        })
    }
}

private func day(_ iso: String) -> BankDay? { BankDay(iso: iso) }

// MARK: - Conformance

@Suite struct EasybankConformanceTests {
    @Test func conformance() async throws {
        let fixture = try Harness.fixtureAccount()
        let subject = ConformanceSubject(
            name: "easybank",
            makeConnector: { Harness.connector() },
            pending: .scenario(
                before: { Harness.connector() },
                after: { Harness.connector(transport: Harness.transport(history: { try Harness.historyAfterBooking() })) }
            ),
            failures: [
                .init("keine Sitzung, keine Anmeldung möglich", expected: .authRequired(.pushConfirm(message: ""))) {
                    Harness.connector(store: InMemorySessionCookieStore())
                },
                .init("Sitzung abgelaufen (401)", expected: .sessionExpired) { Harness.failing(status: 401) },
                .init("zu viele Anfragen (429)", expected: .rateLimited(retryAfter: 0)) { Harness.failing(status: 429) },
                .init("Bank nicht erreichbar (503)", expected: .bankUnavailable) { Harness.failing(status: 503) },
                .init("kein JSON", expected: .formatChanged(detail: "")) { Harness.failing(status: 200, body: Data("<html>".utf8)) },
                .init("IsSuccess false", expected: .formatChanged(detail: "")) {
                    Harness.failing(status: 200, body: Data(#"{"Item":{},"Result":{"IsSuccess":false}}"#.utf8))
                },
            ],
            secrets: [Harness.fedAuth, Harness.xsrf, fixture.number, fixture.iban, fixture.maskedCard, fixture.holder]
        )
        let report = await ConnectorConformance.run(subject)
        #expect(report.passed, "\(report)")
        // Every check must really run (no "not applicable"): pending → booked, since, logs …
        for name in ConnectorConformance.checkNames {
            #expect(report.outcome(of: name) == .passed, "\(name): \(report)")
        }
    }
}

// MARK: - Connector

@Suite struct EasybankConnectorTests {
    @Test func accountsFromLanding() async throws {
        let accounts = try await Harness.connector().accounts()
        let card = try #require(accounts.first)
        #expect(accounts.count == 1)
        #expect(card.type == .card)
        #expect(card.iban == nil)
        let fixture = try Harness.fixtureAccount()
        #expect(card.cardLast4 == String(fixture.maskedCard.suffix(4)))
        #expect(card.creditLimitCents == 1_140_000)
        #expect(card.currency == "EUR")
        #expect(card.name == "easybank Kreditkarte")
        #expect(card.id.rawValue.hasPrefix("easybank:"))
        #expect(!card.id.rawValue.contains(fixture.number))
        #expect(card.connectionID == Harness.connectionID)
    }

    @Test func balanceIsCurrentBalanceAndAvailableLimit() async throws {
        let connector = Harness.connector()
        let card = try #require(try await connector.accounts().first)
        let balance = try await connector.balance(for: card)
        #expect(balance.bookedCents == -80_476)
        #expect(balance.availableCents == 1_247_340)
        #expect(balance.currency == "EUR")
        #expect(balance.asOf == Harness.fixedNow)
    }

    @Test func requestsEchoAccountAndSendSessionHeaders() async throws {
        let transport = Harness.transport()
        let connector = Harness.connector(transport: transport)
        let card = try #require(try await connector.accounts().first)
        _ = try await connector.transactions(for: card, since: nil)
        _ = try await connector.cardStatements(for: card)

        let requests = await transport.requests
        // Landing once, history once (shared by transactions and statements).
        #expect(requests.map { $0.url?.path() } == [EasybankEndpoints.retailLanding, EasybankEndpoints.accountTransactionHistory])
        #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.host() == EasybankEndpoints.host })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-XSRF-TOKEN") == Harness.xsrf })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie")?.contains("FedAuth=") == true })
        // UniqueKey/PCID from the web login go only into headers, never into the Cookie header.
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "UniqueKey") == Harness.uniqueKey })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "pcid") == Harness.pcid })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie")?.contains("mfn.easybank") == false })

        let body = try #require(requests[1].httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let account = try #require(object["Account"] as? [String: Any])
        #expect(account["Number"] as? String == (try Harness.fixtureAccount()).number)
        #expect(account["AccountType"] as? String == "Card")
    }

    @Test func transactionsFromHistory() async throws {
        let connector = Harness.connector()
        let card = try #require(try await connector.accounts().first)
        let transactions = try await connector.transactions(for: card, since: nil)
        #expect(transactions.count == 14)
        #expect(transactions.filter { $0.status == .pending }.count == 4)
        #expect(transactions.filter { $0.status == .booked }.count == 10)
        #expect(transactions.allSatisfy { $0.status != .pending || $0.bookingDate == nil })
        #expect(Set(transactions.map(\.id)).count == 14)

        // Foreign-currency reservation: EUR amount booked, USD kept as original.
        let usd = try #require(transactions.first { $0.originalCurrency == "USD" && $0.amountCents != 0 })
        #expect(usd.amountCents == -1747)
        #expect(usd.originalAmountCents == -2039)
        #expect(usd.status == .pending)
        #expect(usd.valueDate == day("2026-02-22"))

        // Card payment received: credit, positive, no foreign currency although `Amount` is 0.
        let payment = try #require(transactions.first { $0.amountCents == 72_575 })
        #expect(payment.status == .booked)
        #expect(payment.originalCurrency == nil)
        #expect(payment.bookingDate == day("2026-02-19"))

        let raw = try #require(try JSONSerialization.jsonObject(with: usd.rawJSON) as? [String: Any])
        #expect(raw["TransactionType"] as? String == "Pending")
    }

    @Test func sinceKeepsPendingAndNewerBookings() async throws {
        let connector = Harness.connector()
        let card = try #require(try await connector.accounts().first)
        let cut = try #require(day("2026-02-15"))
        let recent = try await connector.transactions(for: card, since: cut.startDate)
        #expect(recent.allSatisfy { $0.status == .pending || $0.effectiveDate >= cut })
        #expect(recent.count < 14)
        #expect(recent.filter { $0.status == .pending }.count == 4)
    }

    @Test func latestStatementFromSummary() async throws {
        let connector = Harness.connector()
        let card = try #require(try await connector.accounts().first)
        let statements = try await connector.cardStatements(for: card)
        let statement = try #require(statements.first)
        #expect(statements.count == 1)
        #expect(statement.periodEnd == day("2026-01-31"))
        #expect(statement.periodStart == day("2026-01-01"))
        #expect(statement.dueDate == day("2026-02-28"))
        #expect(statement.amountCents == -91_868)
        #expect(statement.accountID == card.id)
        #expect(try await connector.securities(for: card).isEmpty)
    }

    @Test func missingSessionAsksForWebLogin() async throws {
        let connector = Harness.connector(store: InMemorySessionCookieStore())
        do {
            _ = try await connector.accounts()
            Issue.record("kein Fehler")
        } catch {
            guard case let .authRequired(.webLogin(request)) = error else { Issue.record("\(error)"); return }
            #expect(request.url.host() == EasybankEndpoints.host)
            #expect(request.completion == .cookiesPresent(["FedAuth", EasybankEndpoints.uniqueKeyName]))
            #expect(request.storageKeys.map(\.source) == [.javaScript, .javaScript])
            #expect(request.storageKeys.allSatisfy { $0.domain == EasybankEndpoints.host && $0.expression?.contains("VeriBranch.Config") == true })
        }
    }

    @Test func sessionWithoutUniqueKeyAsksForNewWebLogin() async throws {
        // A session stored before protocol v3 has FedAuth but no UniqueKey: log in again
        // instead of failing every call with Result.IsSuccess = false.
        let old = Harness.cookies.filter { !EasybankEndpoints.appValueNames.contains($0.name) }
        let connector = Harness.connector(store: InMemorySessionCookieStore([Harness.sessionKey: old]))
        do {
            _ = try await connector.accounts()
            Issue.record("kein Fehler")
        } catch {
            guard case .authRequired(.webLogin) = error else { Issue.record("\(error)"); return }
        }
    }

    @Test func expiredSessionIsForgotten() async throws {
        let store = InMemorySessionCookieStore([Harness.sessionKey: Harness.cookies])
        let connector = Harness.connector(transport: ScriptedHTTPTransport { request, _ in
            ScriptedHTTPTransport.response(request.url, status: 401)
        }, store: store)
        await #expect(throws: ConnectorError.sessionExpired) { _ = try await connector.accounts() }
        #expect(try store.load(Harness.sessionKey) == nil)
    }

    /// Fresh login: the harness cookies with a new FedAuth.
    static let freshFedAuth = "FEDAUTH-FRESH-VALUE-1234"
    static var freshCookies: [SessionCookie] {
        Harness.cookies.map { $0.name == "FedAuth" ? SessionCookie(name: "FedAuth", value: freshFedAuth, domain: $0.domain) : $0 }
    }

    /// Bank that refuses the old FedAuth (or every session, if `refusesAll`).
    static func bank(refusesAll: Bool = false) -> ScriptedHTTPTransport {
        ScriptedHTTPTransport { request, _ in
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if refusesAll || !cookie.contains(freshFedAuth) { return ScriptedHTTPTransport.response(request.url, status: 401) }
            switch request.url?.path() {
            case EasybankEndpoints.retailLanding: return Harness.ok(request, body: try Harness.landing())
            case EasybankEndpoints.accountTransactionHistory: return Harness.ok(request, body: try Harness.history())
            default: return ScriptedHTTPTransport.response(request.url, status: 404)
            }
        }
    }

    @Test func expiredStoredSessionLogsInAgainInTheSameSync() async throws {
        let store = InMemorySessionCookieStore([Harness.sessionKey: Harness.cookies])
        let presenter = LoginPresenter(response: .webSession(Self.freshCookies))
        let connector = Harness.connector(transport: Self.bank(), store: store, presenter: presenter)
        let accounts = try await connector.accounts()
        #expect(!accounts.isEmpty)
        #expect(await presenter.count == 1)
        #expect(try store.load(Harness.sessionKey)?.contains { $0.value == Self.freshFedAuth } == true)
    }

    @Test func freshSessionRefusedIsFormatChangedWithoutSecondLogin() async throws {
        // The bank accepted the credentials, so the error must not block them (no authFailed).
        let store = InMemorySessionCookieStore([Harness.sessionKey: Harness.cookies])
        let presenter = LoginPresenter(response: .webSession(Self.freshCookies))
        let connector = Harness.connector(transport: Self.bank(refusesAll: true), store: store, presenter: presenter)
        do {
            _ = try await connector.accounts()
            Issue.record("kein Fehler")
        } catch {
            guard case .formatChanged = error else { Issue.record("\(error)"); return }
        }
        #expect(await presenter.count == 1)
        #expect(try store.load(Harness.sessionKey) == nil)
    }

    @Test func sessionThatTimesOutLaterLogsInAgain() async throws {
        // Login in one sync, success, then the session times out before the next: one more
        // login, not "fresh session refused".
        let store = InMemorySessionCookieStore()
        let presenter = LoginPresenter(response: .webSession(Self.freshCookies))
        let refuses = Flag()
        let connector = Harness.connector(transport: ScriptedHTTPTransport { request, _ in
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if refuses.isSet, cookie.contains(Self.freshFedAuth) {
                refuses.clear()
                return ScriptedHTTPTransport.response(request.url, status: 401)
            }
            return Harness.ok(request, body: try Harness.landing())
        }, store: store, presenter: presenter)
        _ = try await connector.accounts()
        #expect(await presenter.count == 1)
        refuses.set()
        _ = try await connector.accounts()
        #expect(await presenter.count == 2)
    }

    @Test func automaticSyncDoesNotLogInAfterTimeout() async throws {
        // In the app the presenter refuses logins during automatic syncs (AuthInteraction).
        let store = InMemorySessionCookieStore([Harness.sessionKey: Harness.cookies])
        let presenter = LoginPresenter(response: .webSession(Self.freshCookies), respectsInteraction: true)
        let connector = Harness.connector(transport: Self.bank(), store: store, presenter: presenter)
        await AuthInteraction.$isAllowed.withValue(false) {
            do {
                _ = try await connector.accounts()
                Issue.record("kein Fehler")
            } catch {
                guard case .authRequired? = error as? ConnectorError else { Issue.record("\(error)"); return }
            }
        }
        #expect(await presenter.count == 0)
    }

    @Test func failedReLoginIsPassedOnWithoutRetry() async throws {
        let store = InMemorySessionCookieStore([Harness.sessionKey: Harness.cookies])
        let presenter = LoginPresenter(response: .webSession([]))
        let connector = Harness.connector(transport: Self.bank(), store: store, presenter: presenter)
        await #expect(throws: ConnectorError.authFailed) { _ = try await connector.accounts() }
        #expect(await presenter.count == 1)
    }

    @Test func otpRequiredOnHistoryIsReportedNotEmpty() async throws {
        let otp = try Fixtures.data(.easybank, "get-transactions-otp-required.json")
        let wrapped = Data(#"{"Item":{"InitialCallResponses":[{"Response":"#.utf8) + otp + Data("}]},\"Result\":{\"IsSuccess\":true}}".utf8)
        let connector = Harness.connector(transport: Harness.transport(history: { wrapped }))
        let card = try #require(try await connector.accounts().first)
        await #expect(throws: ConnectorError.formatChanged(detail: "AccountTransactionHistory: OTP verlangt (nicht unterstützt)")) {
            _ = try await connector.transactions(for: card, since: nil)
        }
    }
}

// MARK: - Mapper against further fixtures

@Suite struct EasybankMapperTests {
    let account = Account(id: "easybank:test", connectionID: "test", type: .card, name: "Visa")

    func transactions(_ file: String) throws -> [JSONValue] {
        let envelope = try JSONDecoder().decode(EBEnvelope.self, from: Fixtures.data(.easybank, file))
        return try #require(envelope.item?["Transactions"]?.arrayValue)
    }

    @Test func getTransactionsPageParsesAndMatchesHistoryFingerprints() throws {
        let page = try EasybankMapper.transactions(try transactions("transactions-page1.json"), account: account)
        #expect(page.count == 50)
        #expect(page.filter { $0.status == .pending }.count == 4)
        #expect(page.filter { $0.isInflow }.count == 10)

        let historyItem = try JSONDecoder().decode(EBEnvelope.self, from: Fixtures.data(.easybank, "account-transaction-history.json")).item
        let history = try EasybankMapper.history(in: try #require(historyItem))
        let recent = try EasybankMapper.transactions(history.transactions, account: account)
        // Both endpoints describe the same bookings identically → same IDs (no duplicates on merge).
        let overlap = Set(recent.map(\.id)).intersection(page.map(\.id))
        #expect(overlap.count >= 13)
    }

    @Test func otpRequiredFixtureDecodes() throws {
        let envelope = try JSONDecoder().decode(EBEnvelope.self, from: Fixtures.data(.easybank, "get-transactions-otp-required.json"))
        let list = try #require(envelope.item).decode(EBTransactionList.self, context: "test")
        #expect(list.otpRequired == true)
        #expect(list.transactions?.isEmpty == true)
    }

    @Test func unknownNatureIsFormatChanged() throws {
        let item = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"TransactionType":"Billed","TransactionNature":"Sideways","TransactionDate":"2026-11-01T10:00:00+00:00","LocalCurrencyAmount":{"Value":1,"Currency":{"Code":"EUR"}}}"#.utf8))
        #expect(throws: ConnectorError.formatChanged(detail: "Transactions[0]: TransactionNature unbekannt")) {
            try EasybankMapper.transactions([item], account: account)
        }
    }

    @Test func unknownTypeFallsBackToPostingDate() throws {
        let item = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"TransactionType":"Settled","TransactionNature":"Debit","PostingDate":"2026-11-02T00:00:00+00:00","TransactionDate":"2026-11-01T10:00:00+00:00","LocalCurrencyAmount":{"Value":1.5,"Currency":{"Code":"EUR"}}}"#.utf8))
        let t = try #require(try EasybankMapper.transactions([item], account: account).first)
        #expect(t.status == .booked)
        #expect(t.amountCents == -150)
        #expect(t.bookingDate == day("2026-11-02"))
    }

    @Test func emptyAccountListIsFormatChanged() throws {
        let landing = try JSONDecoder().decode(EBLanding.self, from: Data(#"{"AccountListResponse":{"AccountList":[]}}"#.utf8))
        #expect(throws: ConnectorError.formatChanged(detail: "RetailLanding: AccountList leer")) {
            try EasybankMapper.accounts(landing, connectionID: "test")
        }
    }

    @Test(arguments: [
        ("2026-10-12T21:57:01+00:00", "2026-10-12"), // 23:57 in Berlin
        ("2026-10-12T22:30:00+00:00", "2026-10-13"), // 00:30 in Berlin
        ("2026-11-09T22:12:40.1927534+00:00", "2026-11-09"),
        ("2026-05-13T21:12:40.149Z", "2026-05-13"),
        ("2026-11-14T00:00:00+00:00", "2026-11-14"),
    ])
    func dates(_ text: String, _ expected: String) {
        #expect(EBDate.day(text) == day(expected))
    }

    @Test func noDateSentinels() {
        #expect(EBDate.day("0001-01-01T00:00:00+00:00") == nil)
        #expect(EBDate.day(nil) == nil)
        #expect(EBDate.day("garbage") == nil)
    }

    @Test func moneyWithoutDouble() throws {
        let money = try JSONDecoder().decode([EBMoney].self, from: Data(#"[{"Value":7418.98},{"Value":6677.082},{"Value":0.1},{"Value":-570.33}]"#.utf8))
        #expect(money.map(\.cents) == [741_898, 667_708, 10, -57_033])
    }
}

private actor LoginPresenter: AuthChallengePresenter {
    let response: AuthResponse
    /// Behaves like the app's presenter: no login while `AuthInteraction.isAllowed` is false.
    let respectsInteraction: Bool
    private(set) var count = 0
    init(response: AuthResponse, respectsInteraction: Bool = false) {
        self.response = response
        self.respectsInteraction = respectsInteraction
    }
    func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
        if respectsInteraction, !AuthInteraction.isAllowed { throw ConnectorError.authRequired(challenge) }
        count += 1
        return response
    }
}

/// Thread-safe switch for scripted transports.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
    func clear() { lock.withLock { value = false } }
}
