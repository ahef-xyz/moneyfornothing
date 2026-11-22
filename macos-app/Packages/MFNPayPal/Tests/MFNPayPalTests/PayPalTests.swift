import Foundation
import MFNConformance
import MFNCore
import MFNScrape
import Testing
@testable import MFNPayPal

// MARK: - Harness (fixtures only, never the real site)

struct NoSleep: Sleeper {
    func sleep(seconds: TimeInterval) async throws {}
}

final class StubPresenter: AuthChallengePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    let cookies: [SessionCookie]
    init(cookies: [SessionCookie]) { self.cookies = cookies }
    var count: Int { lock.withLock { _count } }
    func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
        lock.withLock { _count += 1 }
        return .webSession(cookies)
    }
}

enum Harness {
    static let connectionID: ConnectionID = "test-paypal"
    static let sessionKey = "paypal.test-paypal"
    static let sessionValue = "SESSION-SECRET-VALUE-0815"
    static let agent = "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 MFN-Test"
    /// 2026-11-22, the day the fixtures' newest rows lie before.
    static let now = PayPalParser.date("2026-11-22T12:00:00Z") ?? Date()

    static var cookies: [SessionCookie] {
        [
            SessionCookie(name: "x-pp-s", value: sessionValue, domain: "www.paypal.com"),
            SessionCookie(name: PayPalEndpoints.userAgentName, value: agent, domain: PayPalEndpoints.host, isHTTPOnly: false),
        ]
    }

    static func store() -> InMemorySessionCookieStore { InMemorySessionCookieStore([sessionKey: cookies]) }

    /// The token the fixture page carries, read at runtime.
    static func csrf() throws -> String {
        try #require(PayPalParser.csrfToken(in: String(decoding: try Fixtures.data(.paypal, "activities.html"), as: UTF8.self)))
    }

    static func fixtureRows() throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Fixtures.data(.paypal, "activities-filter.json")) as? [String: Any]
        let activity = ((object?["data"] as? [String: Any])?["data"] as? [String: Any])?["activity"] as? [String: Any]
        return try #require(activity?["transactions"] as? [[String: Any]])
    }

    static func listBody(_ rows: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["data": ["data": ["activity": ["noOfTransactions": rows.count, "transactions": rows]]]])) ?? Data()
    }

    /// The date range of a list request, from its `q`.
    static func range(_ request: URLRequest) -> (BankDay, BankDay)? {
        guard let url = request.url, let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value,
              let form = Data(base64Encoded: q).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        var values: [String: String] = [:]
        for pair in form.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            values[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        guard let start = values["start_date"].flatMap(BankDay.init(iso:)), let end = values["end_date"].flatMap(BankDay.init(iso:)) else { return nil }
        return (start, end)
    }

    /// PayPal as recorded: pages for a valid session cookie, the list only with the page's token,
    /// each range answered with the fixture rows inside it.
    static func transport(rows: [[String: Any]]? = nil) throws -> ScriptedHTTPTransport {
        let summary = try Fixtures.data(.paypal, "summary.html")
        let activities = try Fixtures.data(.paypal, "activities.html")
        // Sendable for the responder: each row with its day, as JSON text.
        let all: [(day: BankDay, json: String)] = try (rows ?? fixtureRows()).compactMap { row in
            let text = ((row["date"] as? [String: Any])?["rawDate"] as? [String: Any])?["date"] as? String
            guard let day = text.flatMap(PayPalParser.date).map(BankDay.init) else { return nil }
            return (day, String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self))
        }
        let token = try csrf()
        return ScriptedHTTPTransport { request, _ in
            let url = request.url
            guard request.value(forHTTPHeaderField: "Cookie")?.contains("x-pp-s=\(sessionValue)") == true else {
                return ScriptedHTTPTransport.response(url, body: Data("<html><form><input name=\"login_email\"></form></html>".utf8))
            }
            switch url?.path() {
            case PayPalEndpoints.summary: return ScriptedHTTPTransport.response(url, body: summary)
            case PayPalEndpoints.activities: return ScriptedHTTPTransport.response(url, body: activities)
            case PayPalEndpoints.filter:
                guard request.value(forHTTPHeaderField: "x-csrf-token") == token, request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest",
                      let (start, end) = range(request) else { return ScriptedHTTPTransport.response(url, status: 403) }
                let inside = all.filter { $0.day >= start && $0.day <= end }.map(\.json).joined(separator: ",")
                return ScriptedHTTPTransport.response(url, body: Data(#"{"data":{"data":{"activity":{"transactions":[\#(inside)]}}}}"#.utf8))
            default: return ScriptedHTTPTransport.response(url, status: 404)
            }
        }
    }

    static func connector(transport: any HTTPTransport, store: any SessionCookieStore = store(),
                          presenter: (any AuthChallengePresenter)? = nil) -> PayPalConnector {
        PayPalConnector(connectionID: connectionID, presenter: presenter, store: store, transport: transport,
                        policy: BackoffPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0), sleeper: NoSleep(), now: { now })
    }

    static func failing(status: Int, body: Data = Data(), headers: [String: String] = [:]) -> PayPalConnector {
        connector(transport: ScriptedHTTPTransport { request, _ in ScriptedHTTPTransport.response(request.url, status: status, headers: headers, body: body) })
    }
}

private func day(_ iso: String) -> BankDay? { BankDay(iso: iso) }

// MARK: - Conformance

@Suite struct PayPalConformanceTests {
    @Test func conformance() async throws {
        let transport = try Harness.transport()
        let names = try Harness.fixtureRows().compactMap { ($0["counterpartyInfo"] as? [String: Any])?["counterpartyName"] as? String }
        let subject = ConformanceSubject(
            name: "PayPal",
            makeConnector: { Harness.connector(transport: transport) },
            pending: .notApplicable(reason: "Die Aufzeichnung enthält keine vorgemerkte Zahlung (nur Status COMPLETED)"),
            failures: [
                .init("keine Sitzung, keine Anmeldung möglich", expected: .authRequired(.pushConfirm(message: ""))) {
                    Harness.connector(transport: transport, store: InMemorySessionCookieStore())
                },
                .init("Sitzung abgelaufen (Anmeldeseite statt Daten)", expected: .sessionExpired) {
                    Harness.connector(transport: transport, store: InMemorySessionCookieStore([Harness.sessionKey: [SessionCookie(name: "x-pp-s", value: "alt", domain: "www.paypal.com")]]))
                },
                .init("abgewiesen (403)", expected: .sessionExpired) { Harness.failing(status: 403) },
                .init("zu viele Anfragen (429)", expected: .rateLimited(retryAfter: 0)) { Harness.failing(status: 429, headers: ["Retry-After": "0"]) },
                .init("PayPal nicht erreichbar (503)", expected: .bankUnavailable) { Harness.failing(status: 503) },
                .init("Seite ohne Guthaben", expected: .formatChanged(detail: "")) { Harness.failing(status: 200, body: Data("<html><body>neu</body></html>".utf8)) },
            ],
            secrets: [Harness.sessionValue, try Harness.csrf()] + Set(names)
        )
        let report = await ConnectorConformance.run(subject)
        #expect(report.passed, "\(report)")
        for name in ConnectorConformance.checkNames where name != "pending → booked" {
            #expect(report.outcome(of: name) == .passed, "\(name): \(report)")
        }
    }
}

// MARK: - Connector

@Suite struct PayPalConnectorTests {
    @Test func accountAndBalanceFromTheSummaryPage() async throws {
        let connector = Harness.connector(transport: try Harness.transport())
        let accounts = try await connector.accounts()
        #expect(accounts.count == 1)
        let account = try #require(accounts.first)
        #expect(account.name == "PayPal")
        #expect(account.currency == "EUR")
        #expect(account.type == .giro)
        #expect(account.id.rawValue.hasPrefix("paypal-"))
        let balance = try await connector.balance(for: account)
        #expect(balance.bookedCents == 15_237)
        #expect(balance.availableCents == 15_237)
        #expect(balance.currency == "EUR")
    }

    @Test func activityListBecomesTransactions() async throws {
        let rows = try Harness.fixtureRows()
        let connector = Harness.connector(transport: try Harness.transport())
        let account = try #require(try await connector.accounts().first)
        let transactions = try await connector.transactions(for: account, since: nil)
        let euroRows = rows.filter { ($0["amounts"] as? [String: Any])?["currencyCode"] as? String == "EUR" }
        #expect(transactions.count == euroRows.count, "rows in another currency without a balance are left out")
        #expect(transactions.count < rows.count, "the fixture has such rows")
        #expect(transactions.allSatisfy { $0.status == .booked && $0.bookingDate != nil && $0.currency == "EUR" })
        #expect(Set(transactions.map(\.id)).count == transactions.count)

        // Every row against the fixture: sign from the text, day in German time, name and kind.
        for row in euroRows {
            let id = try #require(row["id"] as? String)
            let found = try #require(transactions.first { $0.externalID == id })
            let text = try #require(((row["amountInfo"] as? [String: Any])?["contents"] as? [String: Any])?["amountText"] as? String)
            #expect((found.amountCents < 0) == text.hasPrefix("&minus;"))
            #expect((found.amountCents > 0) == text.hasPrefix("+"))
            #expect(found.amountCents != 0)
            let name = try #require((row["counterpartyInfo"] as? [String: Any])?["counterpartyName"] as? String)
            #expect(found.counterpartName == name)
            let kind = try #require((row["ftsSearchInfo"] as? [String: Any])?["displayType"] as? String)
            #expect(found.purpose == "\(name) \(kind)")
            let raw = try #require(((row["date"] as? [String: Any])?["rawDate"] as? [String: Any])?["date"] as? String)
            #expect(found.bookingDate == PayPalParser.date(raw).map(BankDay.init))
        }
        #expect(transactions.contains { $0.amountCents > 0 }, "the fixture has money received")
    }

    @Test func firstImportReadsThreeYearsInThreeRequests() async throws {
        let transport = try Harness.transport()
        let connector = Harness.connector(transport: transport)
        let account = try #require(try await connector.accounts().first)
        _ = try await connector.transactions(for: account, since: nil)
        let lists = await transport.requests.filter { $0.url?.path() == PayPalEndpoints.filter }
        #expect(lists.count == 3)
        var previous: BankDay?
        for request in lists {
            let (start, end) = try #require(Harness.range(request))
            #expect(start.days(to: end) <= 364)
            if let previous { #expect(previous.adding(days: 1) == start, "no gap, no overlap") }
            previous = end
            #expect(request.url?.query()?.contains("+") == false)
        }
        #expect(previous == BankDay(Harness.now))
        // The page with the token is loaded once, and every request is the browser that logged in.
        #expect(await transport.requests.filter { $0.url?.path() == PayPalEndpoints.activities }.count == 1)
        for request in await transport.requests {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == Harness.agent)
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains(PayPalEndpoints.userAgentName) == false)
        }
    }

    @Test func sinceReadsFromThatDayOnly() async throws {
        let transport = try Harness.transport()
        let connector = Harness.connector(transport: transport)
        let account = try #require(try await connector.accounts().first)
        let all = try await connector.transactions(for: account, since: nil)
        let cut = try #require(all.map(\.effectiveDate).sorted().dropFirst(all.count / 2).first)

        let fresh = Harness.connector(transport: try Harness.transport())
        _ = try await fresh.accounts()
        let later = try await fresh.transactions(for: account, since: cut.startDate.addingTimeInterval(3_600))
        #expect(Set(later.map(\.id)) == Set(all.filter { $0.effectiveDate >= cut }.map(\.id)))
    }

    @Test func onlyReadsFromPayPal() async throws {
        let transport = try Harness.transport()
        let connector = Harness.connector(transport: transport)
        let account = try #require(try await connector.accounts().first)
        _ = try await connector.transactions(for: account, since: Harness.now)
        for request in await transport.requests {
            #expect(request.url?.host() == "www.paypal.com")
            #expect(request.url?.scheme == "https")
            #expect(request.httpMethod == "GET")
        }
    }

    @Test func timedOutSessionIsReplacedByOneLogin() async throws {
        let presenter = StubPresenter(cookies: Harness.cookies)
        let store = InMemorySessionCookieStore([Harness.sessionKey: [SessionCookie(name: "x-pp-s", value: "abgelaufen", domain: "www.paypal.com")]])
        let connector = Harness.connector(transport: try Harness.transport(), store: store, presenter: presenter)
        let accounts = try await connector.accounts()
        #expect(accounts.count == 1)
        #expect(presenter.count == 1)
        #expect(try store.load(Harness.sessionKey)?.contains { $0.value == Harness.sessionValue } == true)
    }

    @Test func sessionRefusedRightAfterLoginIsNotTriedAgain() async throws {
        // The login hands over cookies PayPal does not accept.
        let presenter = StubPresenter(cookies: [SessionCookie(name: "x-pp-s", value: "falsch", domain: "www.paypal.com")])
        let connector = Harness.connector(transport: try Harness.transport(), store: InMemorySessionCookieStore(), presenter: presenter)
        await #expect(throws: ConnectorError.self) { _ = try await connector.accounts() }
        #expect(presenter.count == 1, "no second login")
        do {
            _ = try await Harness.connector(transport: try Harness.transport(), store: InMemorySessionCookieStore(), presenter: presenter).accounts()
            Issue.record("kein Fehler")
        } catch let error as ConnectorError {
            guard case .formatChanged = error else { Issue.record("\(error)"); return }
            #expect(error.forbidsAutomaticRetry)
        }
    }

    @Test func loginIsVisibleAndAsksForNoCredentials() throws {
        let request = try #require(PayPalEndpoints.loginRequest())
        #expect(request.automation == nil, "PayPal's login is not automated")
        #expect(request.url.host() == "www.paypal.com")
        #expect(request.cookieDomains == ["paypal.com"])
        #expect(ConnectorID.paypal.credentialFields.isEmpty)
        #expect(ConnectorID.paypal.supportsSetup)
    }
}

// MARK: - Parsing

@Suite struct PayPalParsingTests {
    @Test func amounts() {
        #expect(PayPalParser.amountCents("&minus;188,67\u{a0}€", isCredit: false) == -18_867)
        #expect(PayPalParser.amountCents("+12,00\u{a0}€", isCredit: true) == 1_200)
        #expect(PayPalParser.amountCents("&minus;1.234,56\u{a0}€", isCredit: false) == -123_456)
        #expect(PayPalParser.amountCents("&minus;101,25\u{a0}$ USD", isCredit: false) == -10_125)
        #expect(PayPalParser.amountCents("−1,234.56 $", isCredit: false) == -123_456, "English formatting")
        #expect(PayPalParser.amountCents("1.000 ¥", isCredit: true) == 100_000, "no decimals: the dot groups thousands")
        #expect(PayPalParser.amountCents("5,00 €", isCredit: false) == -500, "no sign: the row's style decides")
        #expect(PayPalParser.amountCents("5,00 €", isCredit: true) == 500)
        #expect(PayPalParser.amountCents("—", isCredit: false) == nil)
        #expect(PayPalParser.decimalCents("152.37") == 15_237)
        #expect(PayPalParser.decimalCents("0.00") == 0)
        #expect(PayPalParser.decimalCents("1,5") == nil)
    }

    @Test func tokenFromThePageState() throws {
        let html = String(decoding: try Fixtures.data(.paypal, "activities.html"), as: UTF8.self)
        let token = try #require(PayPalParser.csrfToken(in: html))
        #expect(token.count > 20)
        // Not encoded: plain JSON in the attribute, quotes escaped.
        #expect(PayPalParser.csrfToken(in: #"<div id="__react_data__" data="{&#34;_csrf&#34;:&#34;abc&#34;}"></div>"#) == "abc")
        #expect(PayPalParser.csrfToken(in: "<html></html>") == nil)
    }

    /// Only `COMPLETED` is recorded; the rest is an assumption that keeps a sync from failing.
    @Test func statuses() {
        #expect(PayPalParser.status("COMPLETED") == .booked)
        #expect(PayPalParser.status("PENDING") == .pending)
        #expect(PayPalParser.status("DENIED") == .cancelled)
        #expect(PayPalParser.status("NIE_GESEHEN") == .pending)
        #expect(PayPalParser.status(nil) == .pending)
    }

    @Test func brokenAnswersAreFormatChanges() throws {
        let account = Account(id: "paypal-x", connectionID: "c", type: .giro, name: "PayPal")
        #expect(throws: ConnectorError.self) { _ = try PayPalParser.rows(Data("{}".utf8)) }
        #expect(try PayPalParser.rows(Harness.listBody([])).isEmpty)
        var row = try #require(try Harness.fixtureRows().first { ($0["amounts"] as? [String: Any])?["currencyCode"] as? String == "EUR" })
        row["amountInfo"] = ["contents": ["amountText": "kein Betrag"]]
        let broken = try PayPalParser.rows(Harness.listBody([row]))
        #expect(throws: ConnectorError.self) { _ = try PayPalParser.transactions(broken, account: account) }
        #expect(throws: ConnectorError.self) { _ = try PayPalParser.wallets(summary: "<html></html>", connectionID: "c", now: Harness.now) }
    }

    /// What changes between two answers for the same payment must not change the stored row.
    @Test func pageFurnitureDoesNotChangeARow() throws {
        let account = Account(id: "paypal-x", connectionID: "c", type: .giro, name: "PayPal")
        let row = try #require(try Harness.fixtureRows().first { ($0["amounts"] as? [String: Any])?["currencyCode"] as? String == "EUR" })
        var later = row
        later["fptiInfo"] = ["clicks": ["card": [["event_name": "anders"]]]]
        later["relativeTimeCategory"] = "Letzter Monat"
        later["hasRelativeTimeDivider"] = true
        later["layout"] = ["classNames": "neu"]
        let first = try PayPalParser.transactions(try PayPalParser.rows(Harness.listBody([row])), account: account)
        let second = try PayPalParser.transactions(try PayPalParser.rows(Harness.listBody([later])), account: account)
        #expect(first == second)
        #expect(first.count == 1)
        let raw = try #require(try JSONSerialization.jsonObject(with: first[0].rawJSON) as? [String: Any])
        #expect(raw["fptiInfo"] == nil)
        #expect((raw["ftsSearchInfo"] as? [String: Any])?["displayType"] != nil)
    }

    @Test func rowsOfAnotherCurrencyGetTheirOwnIDs() throws {
        let dollars = Account(id: "paypal-usd", connectionID: "c", type: .giro, currency: "USD", name: "PayPal USD")
        let row = try #require(try Harness.fixtureRows().first { ($0["amounts"] as? [String: Any])?["currencyCode"] as? String == "USD" })
        let id = try #require(row["id"] as? String)
        let found = try PayPalParser.transactions(try PayPalParser.rows(Harness.listBody([row])), account: dollars)
        #expect(found.map(\.externalID) == ["\(id):USD"])
    }

    @Test func secondExpiryInOneSyncEndsItWithoutAnotherLogin() async throws {
        // The login hands over a session that works for the pages but not for the list.
        let presenter = StubPresenter(cookies: Harness.cookies)
        let summary = try Fixtures.data(.paypal, "summary.html")
        let activities = try Fixtures.data(.paypal, "activities.html")
        let transport = ScriptedHTTPTransport { request, _ in
            switch request.url?.path() {
            case PayPalEndpoints.summary:
                // The stored session is refused once; the fresh one works.
                let stale = request.value(forHTTPHeaderField: "Cookie")?.contains("x-pp-s=alt") == true
                return ScriptedHTTPTransport.response(request.url, status: stale ? 401 : 200, body: summary)
            case PayPalEndpoints.activities: return ScriptedHTTPTransport.response(request.url, body: activities)
            default: return ScriptedHTTPTransport.response(request.url, status: 401)
            }
        }
        let store = InMemorySessionCookieStore([Harness.sessionKey: [SessionCookie(name: "x-pp-s", value: "alt", domain: "www.paypal.com")]])
        let connector = Harness.connector(transport: transport, store: store, presenter: presenter)
        let account = try #require(try await connector.accounts().first)
        #expect(presenter.count == 1)
        await #expect(throws: ConnectorError.sessionExpired) { _ = try await connector.transactions(for: account, since: nil) }
        #expect(presenter.count == 1, "no second login window in the same sync")
    }

    @Test func sameRowFromTwoRangesCountsOnce() throws {
        let account = Account(id: "paypal-x", connectionID: "c", type: .giro, name: "PayPal")
        let row = try #require(try Harness.fixtureRows().first { ($0["amounts"] as? [String: Any])?["currencyCode"] as? String == "EUR" })
        let rows = try PayPalParser.rows(Harness.listBody([row, row]))
        #expect(try PayPalParser.transactions(rows, account: account).count == 1)
    }
}
