import Foundation
import MFNConformance
import MFNCore
@testable import MFNTradeRepublic

/// A Trade Republic account for tests.
///
/// REST answers come from the recorded, anonymised fixtures in `Fixtures/TradeRepublic`
/// (accounts, card, timeline page 1). What the HAR does not contain is synthetic and marked so:
/// timeline page 2, a pending card payment, the WebSocket answers (cash, depot, details).
struct TRWorld: Sendable {
    enum Phase: Sendable { case beforeBooking, afterBooking }

    static let securitiesAccountNumber = "0123456789"

    enum Failure: Sendable {
        case none
        case rateLimited
        case serverDown
        case sessionRejected
        case socketAuthError
        case brokenTimeline
        case socketUnreachable
        case detailRejected
        case noCard
        case cardServerError
        case pennyStock
    }

    // Values from the fixtures (anonymised) and synthetic secrets.
    static let fixtureIBAN = "DE00788283369602229881"
    static let fixtureCashAccountNumber = "6426369619"
    static let fixtureCardLast4 = "0394"
    static let sessionValue = "trs-secret-session-0815"
    static let refreshValue = "trs-secret-refresh-4711"
    static let wafValue = "waf-secret-token-1234"
    static let counterpartIBAN = "DE00100100000000000099"
    static let connection: ConnectionID = "tr-test"
    static let fixtureTransactionCount = 30
    static let fixtureSumCents = 190_522

    var phase: Phase = .beforeBooking
    var failure: Failure = .none

    // MARK: - Builders

    static var webCookies: [SessionCookie] {
        [
            SessionCookie(name: "tr_session", value: sessionValue, domain: ".traderepublic.com", expires: Date(timeIntervalSince1970: 1_894_000_000)),
            SessionCookie(name: "tr_refresh", value: refreshValue, domain: ".traderepublic.com"),
            SessionCookie(name: "aws-waf-token", value: wafValue, domain: ".traderepublic.com", isHTTPOnly: false),
            SessionCookie(name: "tr_locale", value: "de", domain: "app.traderepublic.com"),
            SessionCookie(name: "tracking", value: "x", domain: "example.com"),
        ]
    }

    /// Cookies as `TRSession` keeps them (only those sent to api.traderepublic.com).
    static var storedSession: [SessionCookie] { Array(webCookies.prefix(3)) }

    func server(failOpens: Int = 0) -> FakeTRServer {
        let world = self
        let fixtures = Self.fixtures
        return FakeTRServer(failOpens: failure == .socketUnreachable ? 100 : failOpens, http: { method, path, query, headers in
            world.http(method: method, path: path, query: query, headers: headers, fixtures: fixtures)
        }, sub: { payload, _ in
            world.reply(to: payload)
        })
    }

    func connector(
        server: FakeTRServer,
        presenter: (any AuthChallengePresenter)? = FakePresenter(.webSession(TRWorld.webCookies)),
        store: any TRSessionStore = InMemoryTRSessionStore()
    ) -> TradeRepublicConnector {
        TradeRepublicConnector(
            connectionID: Self.connection,
            presenter: presenter,
            sessionStore: store,
            http: server,
            webSocket: server,
            sleeper: NoSleep(),
            configuration: .init(requestTimeout: 5),
            now: { Date(timeIntervalSince1970: 1_771_622_400) }
        )
    }

    func connector() -> TradeRepublicConnector { connector(server: server()) }

    // MARK: - Fixtures

    struct FixtureSet: Sendable {
        var accounts: String
        var card: String
        var timeline: JSONValue
    }

    static let fixtures: FixtureSet = {
        func text(_ name: String) -> String {
            (try? Fixtures.data(.tradeRepublic, name)).map { String(decoding: $0, as: UTF8.self) } ?? "fixture missing: \(name)"
        }
        return FixtureSet(
            accounts: text("accounts-switchable.json"),
            card: text("cards-home.json"),
            timeline: JSONValue.parse(text("timeline-page1.json")) ?? .null
        )
    }()

    // MARK: - REST

    func http(method: String, path: String, query: [String: String], headers: [String: String], fixtures: FixtureSet) -> (Int, [String: String], String) {
        switch failure {
        case .serverDown: return (503, [:], "")
        case .rateLimited: return (429, ["Retry-After": "120"], "")
        case .sessionRejected: return (401, [:], "")
        default: break
        }
        guard method == "GET" else { return (405, [:], "") }
        let cookie = headers["Cookie"] ?? ""
        guard cookie.contains("tr_session=\(Self.sessionValue)") else { return (401, [:], "") }
        switch path {
        case "/api/v1/account-manager/accounts/switchable":
            return (200, [:], fixtures.accounts)
        case "/api/v1/card/cards/home":
            if failure == .cardServerError { return (500, [:], "") }
            return failure == .noCard ? (404, [:], "") : (200, [:], fixtures.card)
        case "/api/v2/timeline/transactions":
            if failure == .brokenTimeline { return (200, [:], #"{"unexpected":true}"#) }
            if let olderThan = query["olderThan"] {
                return olderThan == fixtures.timeline["cursors"]?["after"]?.string ? (200, [:], page2) : (400, [:], "")
            }
            // Like the real API: an unknown `after` parameter is ignored (page 1 again).
            return (200, [:], page1(fixtures.timeline).text)
        default:
            return (404, [:], "")
        }
    }

    var cardStatus: String { phase == .beforeBooking ? "PENDING" : "EXECUTED" }

    /// Fixture page 1 plus one synthetic card payment on top (the HAR has no card or pending item).
    func page1(_ fixture: JSONValue) -> JSONValue {
        guard case var .object(page) = fixture, let items = fixture["items"]?.array,
              let card = JSONValue.parse(#"{"id":"syn-card-1","timestamp":"2026-02-22T16:30:00.000+0000","title":"REWE Markt","subtitle":null,"amount":{"currency":"EUR","value":-23.45,"fractionDigits":2},"subAmount":null,"status":"\#(cardStatus)","eventType":"card_successful_transaction","hidden":false,"deleted":false}"#)
        else { return fixture }
        page["items"] = .array([card] + items)
        return .object(page)
    }

    /// Synthetic page 2 (not recorded), older than the oldest item of page 1 (2024-07-23).
    var page2: String {
        #"""
        {"items":[
          {"id":"syn-card-usd","timestamp":"2024-07-21T09:00:00.000+0000","title":"Example Store US","subtitle":"Kartenzahlung","amount":{"currency":"EUR","value":-9.2,"fractionDigits":2},"subAmount":{"currency":"USD","value":-10.00,"fractionDigits":2},"status":"EXECUTED","eventType":"card_successful_transaction"},
          {"id":"syn-doc","timestamp":"2024-07-20T10:00:00.000+0000","title":"Kontoauszug","amount":null,"status":"EXECUTED","eventType":"DOCUMENTS_CREATED"},
          {"id":"syn-interest","timestamp":"2024-07-15T22:05:00.000+0000","title":"Zinsen","amount":{"currency":"EUR","value":3.21},"status":"EXECUTED","eventType":"INTEREST_PAYOUT"},
          {"id":"syn-unknown","timestamp":"2024-06-29T12:00:00.000+0000","title":"Saveback","amount":{"currency":"EUR","value":"-15.00","fractionDigits":2},"status":"EXECUTED","eventType":"benefits_saveback_execution"},
          {"id":"syn-failed","timestamp":"2024-06-24T12:00:00.000+0000","title":"Example Shop","amount":{"currency":"EUR","value":-50.0},"status":"CANCELED","eventType":"card_failed_transaction"}
        ],"cursors":{"before":"syn-before","after":null}}
        """#
    }

    // MARK: - WebSocket (synthetic, pytr format)

    func reply(to payload: JSONValue) -> [Reply] {
        if failure == .socketAuthError {
            return [.error(#"{"errors":[{"errorCode":"AUTHENTICATION_ERROR","errorMessage":"Unauthorized"}]}"#)]
        }
        switch payload["type"]?.string {
        case "cash":
            return [.answer(#"[{"accountNumber":"\#(Self.fixtureCashAccountNumber)","currencyId":"EUR","amount":1234.56}]"#)]
        case "timelineDetailV2":
            if failure == .detailRejected { return [.error(#"{"errors":[{"errorCode":"NOT_FOUND"}]}"#)] }
            return [.answer(detail(id: payload["id"]?.string ?? ""))]
        case "accountPairs":
            return [.answer(#"{"accounts":[{"productType":"TAX_WRAPPER","securitiesAccountNumber":"9999999999","cashAccountNumber":"8888888888","currency":"EUR"},{"productType":"DEFAULT","securitiesAccountNumber":"\#(Self.securitiesAccountNumber)","cashAccountNumber":"\#(Self.fixtureCashAccountNumber)","currency":"EUR"}]}"#)]
        case "compactPortfolioByTypeV2":
            // Real format (web bundle): positions grouped by category, ISIN under `isin`.
            guard payload["secAccNo"]?.string == Self.securitiesAccountNumber else {
                return [.error(#"{"errors":[{"errorCode":"BAD_REQUEST"}]}"#)]
            }
            return [.answer(#"{"categories":[{"categoryType":"stocksAndETFs","positions":[{"isin":"US0378331005","netSize":"1.5","averageBuyIn":"120.10"},{"isin":"IE00B4L5Y983","netSize":"12.345678","averageBuyIn":"80"},{"isin":"DE0007164600","netSize":"0"}]}]}"#)]
        case "compactPortfolio":
            // Retired topic, as answered by the real server on 2026-11-10.
            return [.error(#"{"errors":[{"errorCode":"BAD_SUBSCRIPTION_TYPE","errorMessage":"Unknown topic type: compactPortfolio.31"}]}"#)]
        case "instrument":
            switch payload["id"]?.string {
            case "US0378331005": return [.answer(#"{"shortName":"Apple","name":"Apple Inc.","exchangeIds":["TUB","LSX"],"typeId":"stock"}"#)]
            default: return [.answer(#"{"name":"iShares Core MSCI World","exchangeIds":["LSX"],"typeId":"fund"}"#)]
            }
        case "ticker":
            switch payload["id"]?.string {
            case "US0378331005.LSX": return [.answer(#"{"bid":{"price":171.2},"ask":{"price":171.3},"last":{"time":1794000000000,"price":171.24}}"#)]
            default:
                // Delisted penny stock: price below one cent (as seen in the first real sync).
                if failure == .pennyStock { return [.answer(#"{"last":{"price":"0.003"},"bid":{"price":"0.003"}}"#)] }
                return [.answer(#"{"bid":{"price":"98.765"},"ask":{"price":"98.80"}}"#)]
            }
        default:
            return [.error(#"{"errors":[{"errorCode":"BAD_SUBSCRIPTION_TYPE"}]}"#)]
        }
    }

    func detail(id: String) -> String {
        #"""
        {"id":"\#(id)","sections":[
          {"title":"Überweisung","type":"header","data":{"icon":"x"}},
          {"title":"Übersicht","type":"table","data":[
            {"title":"Status","detail":{"text":"Abgeschlossen","type":"status"}},
            {"title":"IBAN","detail":{"text":"\#(Self.counterpartIBAN.prefix(4)) \#(Self.counterpartIBAN.dropFirst(4))","type":"text"}},
            {"title":"Verwendungszweck","detail":{"text":"Referenz \#(id)","type":"text"}}
          ]}
        ]}
        """#
    }
}
