import Foundation
import MFNConformance
import MFNCore
import MFNScrape
import Synchronization
import Testing
@testable import MFNDKB

// MARK: - Fixtures/DKB/web

enum DKBFixtures {
    static func data(_ name: String) throws -> Data { try Fixtures.data(.dkb, "web/\(name)") }

    static func json(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
    }
}

// MARK: - Test values

struct NoSleep: Sleeper {
    func sleep(seconds: TimeInterval) async throws {}
}

enum TestValues {
    static let today = BankDay(iso: "2026-02-24") ?? .today
    static let now = today.startDate.addingTimeInterval(12 * 3600)
    static let connection: ConnectionID = "dkb-test"
    static var storeKey: String { "dkb.\(connection.rawValue)" }

    // Anonymised account IDs of Fixtures/DKB/web/accounts.json.
    static let kautionID = "bb11d306-d250-4cb3-9865-9f52173dde49"
    static let giro1ID = "f73c183a-19a4-47d5-8a15-15f404f38446" // transactions-page.json
    static let giro2ID = "89c120a1-5d94-48ef-97cf-8568229ded81" // no transactions recorded
    static let giro3ID = "1e879e4b-34e5-4eaa-b72d-9ab47f87fbb8" // transactions-small-page.json → transactions-last.json

    static let giro1Cursor = "2023-09-25,5997-72-13-34.96.97.283049"
    static let giro3Cursor = "2025-07-16,4188-53-51-82.72.55.826820"

    static let validToken = "dkb-test-access-token-4f1c9a"
    static let staleToken = "dkb-test-access-token-stale-7d02"
    static let refreshToken = "dkb-test-refresh-token-b81e"
    static let sid = "dkb-test-sid-0c3d5e"
    static let xsrf = "dkb-test-xsrf-91aa0f"
    static let ssoToken = "dkb-test-sso-id-token-6e2b"
    static let password = "geheim-Passwort-123"
    static let secrets = [validToken, staleToken, refreshToken, sid, xsrf, ssoToken, password]

    /// Cookies as the app hands them over after the headless login.
    static func session(token: String? = validToken, xsrf: String? = TestValues.xsrf) -> [SessionCookie] {
        var cookies = [
            SessionCookie(name: "__Secure-rt", value: refreshToken, domain: "banking.dkb.de"),
            SessionCookie(name: "__Host-sid", value: sid, domain: "banking.dkb.de"),
            SessionCookie(name: "__Host-sid.sig", value: "sig-\(sid)", domain: "banking.dkb.de"),
            SessionCookie(name: "__Secure-ssoIdToken", value: ssoToken, domain: ".dkb.de"),
            SessionCookie(name: DKBEndpoints.loginDoneCookie, value: "1", domain: "banking.dkb.de", isHTTPOnly: false),
        ]
        if let token { cookies.append(SessionCookie(name: "__Secure-at", value: token, domain: "banking.dkb.de")) }
        if let xsrf { cookies.append(SessionCookie(name: "__Host-xsrf", value: xsrf, domain: "banking.dkb.de", isHTTPOnly: false)) }
        return cookies
    }
}

// MARK: - Presenter

struct TestPresenter: AuthChallengePresenter {
    enum Behaviour: Sendable { case login(token: String?), cancel }
    let behaviour: Behaviour
    let calls = Counter()
    let requests = Recorder<WebLoginRequest>()

    init(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
        calls.increment()
        guard case let .webLogin(request) = challenge else { throw ConnectorError.authFailed }
        requests.append(request)
        switch behaviour {
        case let .login(token):
            return .webSession(TestValues.session(token: token) + [SessionCookie(name: "tracking", value: "x", domain: "ads.example.invalid")])
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

final class Recorder<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])
    func append(_ element: Element) { storage.withLock { $0.append(element) } }
    var all: [Element] { storage.withLock { $0 } }
}

// MARK: - Fake bank

/// Answers like `banking.dkb.de/api` from `Fixtures/DKB/web`. Checks session cookie and headers, records the
/// requested paths (with decoded query).
final class FixtureBank: Sendable {
    enum Phase: Sendable { case beforeBooking, afterBooking }
    enum Fault: Sendable, Equatable {
        case none
        case rejectEverySession   // every request: HTTP 401
        case expireOnTransactions // transactions: HTTP 401
        case rateLimited          // transactions: HTTP 429
        case changedFormat        // first transaction page: amount as object
        case brokenGroups         // display settings: unexpected shape
    }

    let phase: Phase
    let fault: Fault
    let requests = Recorder<String>()

    init(phase: Phase = .afterBooking, fault: Fault = .none) {
        self.phase = phase
        self.fault = fault
    }

    /// The giro-1 transaction turned into a pending one in `.beforeBooking` (index in `transactions-page.json`).
    static let pendingIndex = 4

    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.host() == "banking.dkb.de", request.httpMethod == "GET" else {
            return ScriptedHTTPTransport.response(request.url, status: 404)
        }
        let path = url.path()
        let query = url.query().map { $0.removingPercentEncoding ?? $0 } ?? ""
        requests.append(query.isEmpty ? path : "\(path)?\(query)")

        let cookies = request.value(forHTTPHeaderField: "Cookie") ?? ""
        guard fault != .rejectEverySession,
              cookies.contains("__Secure-at=\(TestValues.validToken)"),
              !cookies.contains("tracking="),
              request.value(forHTTPHeaderField: "x-xsrf-token") == TestValues.xsrf,
              request.value(forHTTPHeaderField: "application-name") == "web-banking",
              request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*"
        else {
            return ScriptedHTTPTransport.response(url, status: 401)
        }

        switch path {
        case "/api/accounts/accounts":
            #expect(query == "filter[product.type][NEQ]=loan")
            return try fixture(url, "accounts.json")
        case "/api/config/users/me/product-display-settings":
            if fault == .brokenGroups { return try respond(url, ["data": "nope"]) }
            return try fixture(url, "product-display-settings.json")
        default:
            break
        }

        let prefix = "/api/accounts/accounts/"
        guard path.hasPrefix(prefix), path.hasSuffix("/transactions") else { return ScriptedHTTPTransport.response(url, status: 404) }
        switch fault {
        case .expireOnTransactions: return ScriptedHTTPTransport.response(url, status: 401)
        case .rateLimited: return ScriptedHTTPTransport.response(url, status: 429, headers: ["Retry-After": "90"])
        default: break
        }
        #expect(query.hasPrefix("expand=Merchant,International&page[size]=25"))
        let accountID = String(path.dropFirst(prefix.count).dropLast("/transactions".count))
        let after = query.components(separatedBy: "&").first { $0.hasPrefix("page[after]=") }.map { String($0.dropFirst("page[after]=".count)) }
        switch (accountID, after) {
        case (TestValues.giro1ID, nil): return try giro1FirstPage(url)
        case (TestValues.giro3ID, nil): return try fixture(url, "transactions-small-page.json")
        case (TestValues.giro3ID, TestValues.giro3Cursor?): return try fixture(url, "transactions-last.json")
        default: return try respond(url, ["data": [Any](), "included": [Any]()])
        }
    }

    private func giro1FirstPage(_ url: URL) throws -> (Data, HTTPURLResponse) {
        guard phase == .beforeBooking || fault == .changedFormat else { return try fixture(url, "transactions-page.json") }
        var root = try DKBFixtures.json("transactions-page.json")
        var items = try #require(root["data"] as? [[String: Any]])
        var item = items[Self.pendingIndex]
        var attributes = try #require(item["attributes"] as? [String: Any])
        if fault == .changedFormat {
            attributes["amount"] = ["value": ["nested": true]]
        } else {
            attributes["status"] = "pending"
            attributes["bookingDate"] = nil
            item["id"] = "pending-0001"
        }
        item["attributes"] = attributes
        items[Self.pendingIndex] = item
        root["data"] = items
        return try respond(url, root)
    }

    private func fixture(_ url: URL, _ name: String) throws -> (Data, HTTPURLResponse) {
        ScriptedHTTPTransport.response(url, headers: ["Content-Type": "application/vnd.api+json"], body: try DKBFixtures.data(name))
    }

    private func respond(_ url: URL, _ object: [String: Any]) throws -> (Data, HTTPURLResponse) {
        ScriptedHTTPTransport.response(url, headers: ["Content-Type": "application/vnd.api+json"], body: try JSONSerialization.data(withJSONObject: object))
    }
}

// MARK: - Harness

struct Harness {
    let bank: FixtureBank
    let store: InMemorySessionCookieStore
    let presenter: TestPresenter?
    let connector: DKBConnector

    init(bank: FixtureBank = FixtureBank(), stored: [SessionCookie]? = TestValues.session(), presenter: TestPresenter.Behaviour? = .login(token: TestValues.validToken)) {
        self.bank = bank
        store = InMemorySessionCookieStore(stored.map { [TestValues.storeKey: $0] } ?? [:])
        let transport = ScriptedHTTPTransport { [bank] request, _ in try bank.respond(request) }
        self.presenter = presenter.map { TestPresenter($0) }
        connector = DKBConnector(
            connectionID: TestValues.connection,
            presenter: self.presenter,
            cookieStore: store,
            transport: transport,
            policy: BackoffPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0),
            sleeper: NoSleep(),
            now: { TestValues.now }
        )
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
