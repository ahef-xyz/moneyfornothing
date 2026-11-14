import CryptoKit
import Foundation
import MFNCore
import MFNScrape
import Synchronization
import Testing
@testable import MFNN26

// MARK: - Fixtures/N26

/// `MFNConformance.Fixtures.Bank` has no N26 case (read-only package), so the lookup is local: walk up from this
/// file to the repository's `Fixtures/N26`.
enum N26Fixtures {
    static func url(_ name: String, file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Fixtures/N26/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw Missing(name: name)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func json(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
    }

    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "Fixture fehlt: Fixtures/N26/\(name)" }
    }
}

// MARK: - Test values

struct NoSleep: Sleeper {
    func sleep(seconds: TimeInterval) async throws {}
}

enum TestValues {
    static let today = BankDay(iso: "2026-02-23") ?? .today
    static let now = today.startDate.addingTimeInterval(12 * 3600)
    static let connection: ConnectionID = "n26-test"

    // Anonymised account IDs of Fixtures/N26 (activities of the account switcher).
    static let mainID = "00000000-0000-4000-8000-000000000001"
    static let space1ID = "00000000-0000-4000-8000-000000000002"
    static let space2ID = "00000000-0000-4000-8000-000000000003"

    static let validToken = "n26-test-access-token-5c1d0f"
    static let staleToken = "n26-test-access-token-stale-77ab"
    static let refreshToken = "n26-test-refresh-token-9e42"
    static let csrfToken = "n26-test-csrf-token-0123456789abcdef"
    static let staleCSRF = "n26-test-csrf-token-stale-000000000"
    static let secrets = [validToken, staleToken, refreshToken, csrfToken, staleCSRF]

    /// The fake bank's payload key pair (`window.__PEK__` = public part).
    static let bankKey = P384.KeyAgreement.PrivateKey()
    static var pek: String { bankKey.publicKey.rawRepresentation.base64EncodedString() }

    static var html: String {
        """
        <!doctype html><html><head>
        <meta name="csrf-token" content="\(csrfToken)" />
        </head><body><script nonce="x">
          window.__PEK__ = '\(pek)'
          window.__N26_APOLLO_STATE__ = {}
        </script></body></html>
        """
    }

    /// Cookies + storage pseudo-cookies as the app hands them over after the headless login.
    static func session(token: String?, csrf: String? = csrfToken, pek: String? = TestValues.pek) -> [SessionCookie] {
        var cookies = [
            SessionCookie(name: "n26.csrf", value: "csrf-secret", domain: "app.n26.com"),
            SessionCookie(name: "num26refresh", value: refreshToken, domain: "app.n26.com"),
        ]
        if let token { cookies.append(SessionCookie(name: "n26.token", value: token, domain: "app.n26.com")) }
        if let csrf { cookies.append(SessionCookie(name: "n26.csrfToken", value: csrf, domain: "app.n26.com", isHTTPOnly: false)) }
        if let pek { cookies.append(SessionCookie(name: "n26.pek", value: pek, domain: "app.n26.com", isHTTPOnly: false)) }
        return cookies
    }
}

// MARK: - Decryption (bank side)

enum BankCrypto {
    /// Inverse of `N26PayloadCipher.encrypt` with the bank's secret key (`sjcl.decrypt` with `elGamal.secretKey`).
    static func decrypt(_ payload: String, secret: P384.KeyAgreement.PrivateKey = TestValues.bankKey) throws -> Data {
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let tag = try P384.KeyAgreement.PublicKey(rawRepresentation: try #require(base64(envelope["kemtag"])))
        let key = Array(SHA256.hash(data: try N26KEM.sharedPoint(privateKey: secret, publicKey: tag)))
        let iv = Array(try #require(base64(envelope["iv"])))
        let adata = Array(try #require(base64(envelope["adata"])))
        let ct = Array(try #require(base64(envelope["ct"])))
        return Data(try AESCCM.open(ct, key: key, iv: iv, adata: adata, tagLength: 16))
    }

    private static func base64(_ value: Any?) -> Data? {
        (value as? String).flatMap { Data(base64Encoded: $0) }
    }
}

// MARK: - Presenter

struct TestPresenter: AuthChallengePresenter {
    enum Behaviour: Sendable { case login(token: String?, csrf: String? = TestValues.csrfToken, pek: String? = TestValues.pek), cancel }
    let behaviour: Behaviour
    let calls: Counter
    let requests: Recorder<WebLoginRequest>

    init(_ behaviour: Behaviour, calls: Counter = Counter(), requests: Recorder<WebLoginRequest> = Recorder()) {
        self.behaviour = behaviour
        self.calls = calls
        self.requests = requests
    }

    func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
        calls.increment()
        guard case let .webLogin(request) = challenge else { throw ConnectorError.authFailed }
        requests.append(request)
        switch behaviour {
        case let .login(token, csrf, pek):
            return .webSession(TestValues.session(token: token, csrf: csrf, pek: pek)
                + [SessionCookie(name: "tracking", value: "x", domain: "ads.example.invalid")])
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

/// Answers like `app.n26.com` from `Fixtures/N26`. Decrypts every payload with the test key, checks CSRF token and
/// session cookie, and routes by operation and variables. Records the decrypted variables.
final class FixtureBank: Sendable {
    enum Phase: Sendable { case beforeBooking, afterBooking }
    enum Fault: Sendable, Equatable {
        case none
        case rejectEverySession   // every GraphQL request: HTTP 401
        case expireOnTimeline     // getTimeline: GraphQL error „401 Unauthorized“ (HTTP 200)
        case rateLimited          // getTimeline: HTTP 429
        case changedFormat        // main feed: amount as object
        case htmlWithoutKey       // bootstrap page without window.__PEK__
        case rotatedKeyOnce       // first GraphQL request: HTTP 400 (key rotated), bootstrap afterwards
    }

    let phase: Phase
    let fault: Fault
    let variables = Recorder<[String: String]>()
    let bootstraps = Counter()
    private let rejectedOnce = Mutex(false)

    init(phase: Phase = .afterBooking, fault: Fault = .none) {
        self.phase = phase
        self.fault = fault
    }

    /// Title of the main-account transaction turned into a pending one in `.beforeBooking`.
    static let pendingTitle = "Gegenpartei 01"

    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.host() == "app.n26.com" else { return ScriptedHTTPTransport.response(request.url, status: 404) }
        let cookies = request.value(forHTTPHeaderField: "Cookie") ?? ""

        if request.httpMethod == "GET", url.path() == "/" {
            bootstraps.increment()
            let html = fault == .htmlWithoutKey ? TestValues.html.replacingOccurrences(of: "window.__PEK__", with: "window.__OTHER__") : TestValues.html
            return ScriptedHTTPTransport.response(url, headers: ["Content-Type": "text/html"], body: Data(html.utf8))
        }
        guard request.httpMethod == "POST", url.path() == "/graphql" else { return ScriptedHTTPTransport.response(url, status: 404) }

        if fault == .rotatedKeyOnce, !rejectedOnce.withLock({ let was = $0; $0 = true; return was }) {
            return ScriptedHTTPTransport.response(url, status: 400, body: Data(#"{"key":"rotated"}"#.utf8))
        }
        guard fault != .rejectEverySession,
              cookies.contains("n26.token=\(TestValues.validToken)"),
              !cookies.contains("n26.csrfToken="), !cookies.contains("n26.pek="), // pseudo-cookies are never sent
              request.value(forHTTPHeaderField: "csrf-token") == TestValues.csrfToken,
              request.value(forHTTPHeaderField: "x-requested-with") == "XMLHttpRequest"
        else {
            return ScriptedHTTPTransport.response(url, status: 401)
        }

        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let operation = try #require(body["operationName"] as? String)
        #expect(url.query()?.contains("op=\(operation)") == true)
        #expect(body["query"] as? String == (operation == "getTimeline" ? N26Queries.timeline : N26Queries.transactionsList))
        let payload = try #require((body["variables"] as? [String: Any])?["payload"] as? String)
        let decoded = try #require(try JSONSerialization.jsonObject(with: BankCrypto.decrypt(payload)) as? [String: Any])
        var recorded = decoded.mapValues { ($0 as? String) ?? "null" }
        recorded["operation"] = operation
        variables.append(recorded)

        switch operation {
        case "getTransactionsList":
            switch decoded["accountId"] as? String {
            case nil: return try fixture(url, "feed-all.json")
            case TestValues.mainID?: return try mainFeed(url)
            case TestValues.space1ID?: return try fixture(url, "feed-space-1.json")
            case TestValues.space2ID?: return try fixture(url, "feed-space-2.json")
            default: return try respond(url, ["errors": [["message": "404 Not Found"]], "data": NSNull()])
            }
        case "getTimeline":
            switch fault {
            case .expireOnTimeline: return try respond(url, ["errors": [["message": "401 Unauthorized"]], "data": NSNull()])
            case .rateLimited: return ScriptedHTTPTransport.response(url, status: 429, headers: ["Retry-After": "90"])
            default: break
            }
            let key = try #require(decoded["paginationKey"] as? String)
            if decoded["accountId"] as? String == TestValues.mainID, key == (try Self.paginationKey(of: "feed-main.json")) {
                return try fixture(url, "timeline-main-page2.json")
            }
            // Not recorded (main page 3, Space 01 page 2): end of the timeline.
            return try respond(url, ["data": ["timeline": ["timelineItems": [Any](), "paginationKey": NSNull(), "__typename": "FeedTimeline"]]])
        default:
            return ScriptedHTTPTransport.response(url, status: 400)
        }
    }

    private func mainFeed(_ url: URL) throws -> (Data, HTTPURLResponse) {
        guard phase == .beforeBooking || fault == .changedFormat else { return try fixture(url, "feed-main.json") }
        var root = try N26Fixtures.json("feed-main.json")
        var data = try #require(root["data"] as? [String: Any])
        var feed = try #require(data["feed"] as? [String: Any])
        var modules = try #require(feed["modules"] as? [[String: Any]])
        var items = try #require(modules[0]["timelineItems"] as? [[String: Any]])
        let index = try #require(items.firstIndex { $0["title"] as? String == Self.pendingTitle })
        if fault == .changedFormat {
            var amount = try #require(items[index]["styledAmount"] as? [String: Any])
            amount["money"] = ["unscaledAmount": ["nested": true]]
            items[index]["styledAmount"] = amount
        } else {
            var icon = try #require(items[index]["icon"] as? [String: Any])
            icon["statusIcon"] = ["lightUrl": "https://cdn.number26.de/feed/status/light/pending.png", "darkUrl": "https://cdn.number26.de/feed/status/dark/pending.png", "__typename": "FeedStatusIcon"]
            items[index]["icon"] = icon
        }
        modules[0]["timelineItems"] = items
        feed["modules"] = modules
        data["feed"] = feed
        root["data"] = data
        return try respond(url, root)
    }

    static func paginationKey(of name: String) throws -> String {
        let root = try N26Fixtures.json(name)
        if let feed = (root["data"] as? [String: Any])?["feed"] as? [String: Any] {
            return try #require((feed["modules"] as? [[String: Any]])?.first?["paginationKey"] as? String)
        }
        return try #require(((root["data"] as? [String: Any])?["timeline"] as? [String: Any])?["paginationKey"] as? String)
    }

    private func fixture(_ url: URL, _ name: String) throws -> (Data, HTTPURLResponse) {
        ScriptedHTTPTransport.response(url, headers: ["Content-Type": "application/json"], body: try N26Fixtures.data(name))
    }

    private func respond(_ url: URL, _ object: [String: Any]) throws -> (Data, HTTPURLResponse) {
        ScriptedHTTPTransport.response(url, headers: ["Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: object))
    }
}

// MARK: - Harness

struct Harness {
    let bank: FixtureBank
    let store: InMemorySessionCookieStore
    let transport: ScriptedHTTPTransport
    let presenter: TestPresenter?
    let connector: N26Connector

    init(bank: FixtureBank = FixtureBank(), stored: [SessionCookie]? = TestValues.session(token: TestValues.validToken), presenter: TestPresenter.Behaviour? = .login(token: TestValues.validToken)) {
        self.bank = bank
        store = InMemorySessionCookieStore(stored.map { ["n26.\(TestValues.connection.rawValue)": $0] } ?? [:])
        transport = ScriptedHTTPTransport { [bank] request, _ in try bank.respond(request) }
        self.presenter = presenter.map { TestPresenter($0) }
        connector = N26Connector(
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
