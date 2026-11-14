import Foundation
import MFNConformance
import MFNCore
import MFNScrape
import Synchronization
import Testing
@testable import MFNC24

// Test backend that answers with the recorded, anonymised C24 responses in `Fixtures/C24/`.
//
// Synthetic parts (each a gap in `Fixtures/C24/endpoints.md`):
// - the session-check answer (`{}`) and 401 for an expired session,
// - the empty last page (`more: false`) after the recorded pages,
// - empty searches for the current accounts (no giro transactions recorded),
// - one preliminary card payment derived from a recorded booked one (no `preliminary: true` recorded).

struct NoSleep: Sleeper {
    func sleep(seconds: TimeInterval) async throws {}
}

enum TestValues {
    static let today = BankDay(iso: "2026-02-23") ?? .today
    /// Noon in Berlin on the recording day.
    static let now = today.startDate.addingTimeInterval(12 * 3600)
    static let connection: ConnectionID = "c24-test"
    /// `sessionStorage` key handed over by the web login (pseudo-cookie).
    static let storeKey = "sessionStore"
    static let validToken = "c24-test-bearer-token-7f3a9c"
    static let staleToken = "c24-test-bearer-token-stale-11b2"
    static let refreshToken = "c24-test-refresh-token-0d9e"

    // From the fixtures.
    static let pocketPlusNumber = "3238114929"   // Pocket 05, transactions-page1/-page2
    static let jointPocketNumber = "7108564637"  // Pocket 01, transactions-other-pocket-page1
    static let jointAccountNumber = "4722030154" // Konto 02, standing orders
    static let pocket04IBAN = "DE00131574227489191686" // debtor of the direct debits
    static let pocketPlusIBAN = "DE00446443872967276382"
    static let cardTransactionID = "f8d1adef0"
    static let secrets = [validToken, staleToken, refreshToken, pocketPlusNumber, jointPocketNumber, jointAccountNumber,
                          pocket04IBAN, pocketPlusIBAN, "DE00895531523778866583", "DE00241912686812512422"]

    static let endpoints: C24Endpoints = {
        var endpoints = C24Endpoints.production
        endpoints.verified = true
        endpoints.loginCompletion = .cookiesPresent([storeKey])
        return endpoints
    }()

    /// SYNTHETIC `sessionStorage["sessionStore"]` value: shape as described by the human
    /// (JSON object with `accessToken`), the other fields are made up and must be ignored.
    static func storeValue(token: String) -> String {
        #"{"accessToken":"\#(token)","refreshToken":"\#(refreshToken)","expiresAt":1794240000,"user":{"firstName":"Name 02","customerId":42}}"#
    }

    static func session(token: String?) -> [SessionCookie] {
        session(rawStore: token.map(storeValue(token:)))
    }

    static func session(rawStore: String?) -> [SessionCookie] {
        var cookies = [
            SessionCookie(name: "c24GDPR_v1", value: "gdpr", domain: ".c24.de"),
            SessionCookie(name: "devicetype_v1", value: "desktop", domain: ".c24.de"),
        ]
        if let rawStore { cookies.append(SessionCookie(name: storeKey, value: rawStore, domain: "banking.c24.de", isSecure: true, isHTTPOnly: false)) }
        return cookies
    }
}

/// Answers the login challenge like the app's web view would.
struct TestPresenter: AuthChallengePresenter {
    enum Behaviour: Sendable { case login(token: String?), loginRaw(String), cancel }
    let behaviour: Behaviour
    let calls: Counter

    func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
        calls.increment()
        guard case .webLogin = challenge else { throw ConnectorError.authFailed }
        switch behaviour {
        case let .login(token):
            return .webSession(TestValues.session(token: token) + [SessionCookie(name: "tracking", value: "x", domain: "ads.example.invalid")])
        case let .loginRaw(store):
            return .webSession(TestValues.session(rawStore: store))
        case .cancel:
            throw ConnectorError.cancelled
        }
    }
}

final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

struct FixtureBank: Sendable {
    enum Phase: Sendable { case beforeBooking, afterBooking }
    enum Fault: Sendable { case none, rejectEverySession, expireOnTransactions, rateLimited, changedFormat, rejectRefresh, refreshUnavailable }

    var phase: Phase = .beforeBooking
    var fault: Fault = .none

    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.host() == "api.c24.de" else {
            return ScriptedHTTPTransport.response(request.url, status: 404)
        }
        // SYNTHETIC: token renewal (not recorded), shape like `web-login/complete`.
        if request.httpMethod == "POST", url.path() == "/api/web-login/refresh/" {
            if fault == .refreshUnavailable { return ScriptedHTTPTransport.response(url, status: 503) }
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            guard fault != .rejectRefresh, request.value(forHTTPHeaderField: "Authorization") == nil,
                  body?["refresh_token"] as? String == TestValues.refreshToken else {
                return ScriptedHTTPTransport.response(url, status: 401)
            }
            return ScriptedHTTPTransport.response(url, body: Data(#"{"access_token":"\#(TestValues.validToken)","refresh_token":"\#(TestValues.refreshToken)"}"#.utf8))
        }
        let authorized = fault != .rejectEverySession
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestValues.validToken)"
            && request.value(forHTTPHeaderField: "x-c24-tracingsession") != nil
        guard authorized else { return ScriptedHTTPTransport.response(url, status: 401) }

        switch (request.httpMethod ?? "GET", url.path()) {
        case ("GET", "/api/v2/user/me/"):
            return ScriptedHTTPTransport.response(url, body: Data("{}".utf8))
        case ("GET", "/api/user/me/accounts/internal/"):
            return try fixture(url, "accounts.json")
        case ("GET", "/api/v3/pockets/"):
            return try fixture(url, "pockets.json")
        case ("GET", "/api/v2/upcoming-transactions/"):
            return try fixture(url, "upcoming-transactions.json")
        case ("POST", "/api/v3/transactions/search/"):
            return try search(url, body: request.httpBody ?? Data())
        default:
            return ScriptedHTTPTransport.response(url, status: 404)
        }
    }

    private func search(_ url: URL, body: Data) throws -> (Data, HTTPURLResponse) {
        switch fault {
        case .expireOnTransactions: return ScriptedHTTPTransport.response(url, status: 401)
        case .rateLimited: return ScriptedHTTPTransport.response(url, status: 429, headers: ["Retry-After": "90"])
        default: break
        }
        let request = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let number = try #require(((request["criteria"] as? [String: Any])?["account_numbers"] as? [String])?.first)
        let offset = try #require((request["pagination"] as? [String: Any])?["offset"] as? Int)

        switch (number, offset) {
        case (TestValues.pocketPlusNumber, 0):
            guard fault == .changedFormat else { return try fixture(url, "transactions-page1.json") }
            var page = try Self.json("transactions-page1.json")
            var list = page["transactions"] as? [[String: Any]] ?? []
            list[0]["amount"] = true
            page["transactions"] = list
            return try respond(url, page)
        case (TestValues.pocketPlusNumber, 30):
            return try fixture(url, "transactions-page2.json")
        case (TestValues.jointPocketNumber, 0):
            guard phase == .beforeBooking else { return try fixture(url, "transactions-other-pocket-page1.json") }
            var page = try Self.json("transactions-other-pocket-page1.json")
            page["transactions"] = (page["transactions"] as? [[String: Any]] ?? []).map(Self.preliminaryIfCard)
            return try respond(url, page)
        default:
            return try respond(url, ["criteria": ["account_numbers": [number]], "pagination": ["limit": 30, "offset": offset, "more": false], "transactions": []])
        }
    }

    /// The recorded card payment as it would look while reserved (assumed shape: `preliminary: true`,
    /// own ID, no booking date, `date` = time of card use).
    static func preliminaryIfCard(_ transaction: [String: Any]) -> [String: Any] {
        guard transaction["id"] as? String == TestValues.cardTransactionID else { return transaction }
        var pending = transaction
        pending["preliminary"] = true
        pending["id"] = "hold-\(TestValues.cardTransactionID)"
        pending["date"] = transaction["sort_date"]
        pending["data"] = (transaction["data"] as? [[String: Any]] ?? []).filter { $0["title"] as? String != "Buchungsdatum" }
        return pending
    }

    static func json(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Fixtures.data(.c24, name)) as? [String: Any])
    }

    private func fixture(_ url: URL, _ name: String) throws -> (Data, HTTPURLResponse) {
        ScriptedHTTPTransport.response(url, headers: ["Content-Type": "application/json"], body: try Fixtures.data(.c24, name))
    }

    private func respond(_ url: URL, _ object: [String: Any]) throws -> (Data, HTTPURLResponse) {
        ScriptedHTTPTransport.response(url, headers: ["Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: object))
    }
}

/// Everything a test needs around one connector instance.
struct Harness {
    static let storeKey = "c24.\(TestValues.connection.rawValue)"

    let connector: C24Connector
    let transport: ScriptedHTTPTransport
    let store: InMemorySessionCookieStore
    let presenterCalls: Counter

    init(
        bank: FixtureBank = FixtureBank(),
        stored: String? = TestValues.validToken,
        presenter: TestPresenter.Behaviour? = .login(token: TestValues.validToken),
        store: InMemorySessionCookieStore? = nil,
        endpoints: C24Endpoints = TestValues.endpoints
    ) {
        let store = store ?? InMemorySessionCookieStore(stored.map { [Self.storeKey: TestValues.session(token: $0)] } ?? [:])
        let calls = Counter()
        let transport = ScriptedHTTPTransport { request, _ in try bank.respond(request) }
        self.transport = transport
        self.store = store
        presenterCalls = calls
        connector = C24Connector(
            connectionID: TestValues.connection,
            presenter: presenter.map { TestPresenter(behaviour: $0, calls: calls) },
            cookieStore: store,
            transport: transport,
            endpoints: endpoints,
            sleeper: NoSleep(),
            now: { TestValues.now }
        )
    }

    /// Search requests sent so far: (account number, offset).
    func searches() async -> [(number: String, offset: Int)] {
        await transport.requests.compactMap { request in
            guard request.httpMethod == "POST", let body = request.httpBody,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let number = ((object["criteria"] as? [String: Any])?["account_numbers"] as? [String])?.first,
                  let offset = (object["pagination"] as? [String: Any])?["offset"] as? Int
            else { return nil }
            return (number, offset)
        }
    }
}
