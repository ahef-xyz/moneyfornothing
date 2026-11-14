import Foundation
import MFNCore
import Testing
@testable import MFNScrape

private struct NoSleep: Sleeper {
    func sleep(seconds: TimeInterval) async throws {}
}

private struct Accounts: Decodable, Sendable {
    struct Item: Decodable, Sendable { let id: String; let balance: Int }
    let items: [Item]
}

private let api = URL(string: "https://banking.example.invalid/api/accounts")!
private let session = [
    SessionCookie(name: "SESSION", value: "s3cr3t-cookie", domain: ".example.invalid"),
    SessionCookie(name: "OTHER", value: "x", domain: "tracker.invalid"),
]

@Suite struct ScrapeClientTests {
    @Test func sendsMatchingCookiesAndDecodes() async throws {
        let transport = ScriptedHTTPTransport { request, _ in
            ScriptedHTTPTransport.response(request.url, body: Data(#"{"items":[{"id":"a1","balance":100,"extra":true}]}"#.utf8))
        }
        let client = ScrapeClient(cookies: session, transport: transport, sleeper: NoSleep())
        let (value, raw) = try await client.get(api, as: Accounts.self)
        #expect(value.items.first?.id == "a1")
        #expect(!raw.isEmpty)
        let sent = try #require(await transport.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == "SESSION=s3cr3t-cookie")
    }

    @Test func unauthorizedIsSessionExpiredWithoutRetry() async {
        let transport = ScriptedHTTPTransport { request, _ in ScriptedHTTPTransport.response(request.url, status: 401) }
        let client = ScrapeClient(cookies: session, transport: transport, sleeper: NoSleep())
        await #expect(throws: ConnectorError.sessionExpired) { _ = try await client.data(api) }
        #expect(await transport.requests.count == 1)
    }

    @Test func retriesServerErrorsThenSucceeds() async throws {
        let transport = ScriptedHTTPTransport { request, index in
            index < 2 ? ScriptedHTTPTransport.response(request.url, status: 503) : ScriptedHTTPTransport.response(request.url, body: Data("{}".utf8))
        }
        let client = ScrapeClient(cookies: session, transport: transport, sleeper: NoSleep())
        _ = try await client.data(api)
        #expect(await transport.requests.count == 3)
    }

    @Test func rateLimitAfterRetriesAndCircuitBreaker() async {
        let transport = ScriptedHTTPTransport { request, _ in
            ScriptedHTTPTransport.response(request.url, status: 429, headers: ["Retry-After": "120"])
        }
        let client = ScrapeClient(cookies: session, transport: transport, sleeper: NoSleep())
        for _ in 0..<3 {
            await #expect(throws: ConnectorError.rateLimited(retryAfter: 120)) { _ = try await client.data(api) }
        }
        #expect(await transport.requests.count == 9)
        // Fourth call: refused without contacting the bank.
        await #expect(throws: ConnectorError.bankUnavailable) { _ = try await client.data(api) }
        #expect(await transport.requests.count == 9)
    }

    @Test func changedFormatReportsPathNotValues() async {
        let transport = ScriptedHTTPTransport { request, _ in
            ScriptedHTTPTransport.response(request.url, body: Data(#"{"items":[{"id":"geheim-123","balance":"viel"}]}"#.utf8))
        }
        let client = ScrapeClient(cookies: session, transport: transport, sleeper: NoSleep())
        do {
            _ = try await client.get(api, as: Accounts.self)
            Issue.record("expected formatChanged")
        } catch {
            guard case let .formatChanged(detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.contains("items.[0].balance"))
            #expect(!detail.contains("viel"))
            #expect(!detail.contains("geheim"))
        }
    }

    @Test func keepsSetCookieUpdates() async throws {
        let transport = ScriptedHTTPTransport { request, _ in
            ScriptedHTTPTransport.response(request.url, headers: ["Set-Cookie": "SESSION=rotated; Domain=example.invalid; Path=/; Secure"], body: Data("{}".utf8))
        }
        let client = ScrapeClient(cookies: session, transport: transport, sleeper: NoSleep())
        _ = try await client.data(api)
        #expect(await client.currentCookies.first { $0.name == "SESSION" }?.value == "rotated")
    }

    @Test func cookieHeaderRespectsDomainPathSecureAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cookies = [
            SessionCookie(name: "a", value: "1", domain: "example.invalid"),
            SessionCookie(name: "b", value: "2", domain: "example.invalid", path: "/other"),
            SessionCookie(name: "c", value: "3", domain: "example.invalid", expires: now.addingTimeInterval(-1)),
            SessionCookie(name: "d", value: "4", domain: "evil-example.invalid"),
        ]
        #expect(ScrapeClient.cookieHeader(cookies, for: api, now: now) == "a=1")
    }
}

private struct Presenter: AuthChallengePresenter {
    let response: AuthResponse
    func present(_ challenge: AuthChallenge) async throws -> AuthResponse { response }
}

@Suite struct WebLoginSessionTests {
    let request = WebLoginRequest(
        url: URL(string: "https://banking.example.invalid/login")!,
        completion: .cookiesPresent(["SESSION"]),
        cookieDomains: ["example.invalid"],
        message: "Bitte anmelden"
    )

    @Test func usesStoredCookiesBeforeAskingTheUser() async throws {
        let store = InMemorySessionCookieStore(["k": [SessionCookie(name: "SESSION", value: "old", domain: "example.invalid")]])
        let login = WebLoginSession(key: "k", request: request, presenter: nil, store: store)
        #expect(try await login.cookies().first?.value == "old")
    }

    @Test func withoutPresenterRequiresAuth() async {
        let login = WebLoginSession(key: "k", request: request, presenter: nil, store: InMemorySessionCookieStore())
        await #expect(throws: ConnectorError.authRequired(.webLogin(request))) { _ = try await login.cookies() }
    }

    @Test func storesOnlyCookiesOfConfiguredDomains() async throws {
        let store = InMemorySessionCookieStore()
        let login = WebLoginSession(key: "k", request: request, presenter: Presenter(response: .webSession(session)), store: store)
        let cookies = try await login.cookies(forceLogin: true)
        #expect(cookies.map(\.name) == ["SESSION"])
        #expect(try store.load("k")?.map(\.name) == ["SESSION"])
    }

    @Test func missingRequiredCookieIsAuthFailed() async {
        let login = WebLoginSession(key: "k", request: request, presenter: Presenter(response: .webSession([SessionCookie(name: "X", value: "1", domain: "example.invalid")])), store: InMemorySessionCookieStore())
        await #expect(throws: ConnectorError.authFailed) { _ = try await login.cookies(forceLogin: true) }
    }
}

// MARK: - Protocol v2: Web Storage entries

private let storageSecret = #"{"accessToken":"t0p-s3cr3t-bearer"}"#
private let storageKey = StorageKey(key: "sessionStore", source: .sessionStorage, domain: "banking.example.invalid")
private let storageRequest = WebLoginRequest(
    url: URL(string: "https://banking.example.invalid/login")!,
    completion: .cookiesPresent(["sessionStore"]),
    cookieDomains: ["example.invalid"],
    message: "Bitte anmelden",
    storageKeys: [storageKey]
)
private let storageEntry = SessionCookie(name: "sessionStore", value: storageSecret, domain: "banking.example.invalid", isHTTPOnly: false)

@Suite struct WebLoginSessionStorageTests {
    @Test func storageEntrySatisfiesCookiesPresentAndIsPersisted() async throws {
        let store = InMemorySessionCookieStore()
        let login = WebLoginSession(key: "k", request: storageRequest, presenter: Presenter(response: .webSession([storageEntry])), store: store)
        let cookies = try await login.cookies(forceLogin: true)
        #expect(cookies == [storageEntry])
        #expect(try store.load("k") == [storageEntry])
        // Reused from the store like a cookie, without asking again.
        let again = WebLoginSession(key: "k", request: storageRequest, presenter: nil, store: store)
        #expect(try await again.cookies() == [storageEntry])
    }

    @Test func missingStorageEntryIsAuthFailed() async {
        let cookie = SessionCookie(name: "SESSION", value: "x", domain: "example.invalid")
        let login = WebLoginSession(key: "k", request: storageRequest, presenter: Presenter(response: .webSession([cookie])), store: InMemorySessionCookieStore())
        await #expect(throws: ConnectorError.authFailed) { _ = try await login.cookies(forceLogin: true) }
    }

    @Test func storageEntryOutsideCookieDomainsIsKeptButForeignCookiesAreNot() async throws {
        var request = storageRequest
        request.cookieDomains = ["cookies.invalid"]
        let store = InMemorySessionCookieStore()
        let all = [
            SessionCookie(name: "SESSION", value: "c", domain: "cookies.invalid"),
            SessionCookie(name: "OTHER", value: "x", domain: "banking.example.invalid"),
            SessionCookie(name: "sessionStore", value: "wrong-domain", domain: "tracker.invalid", isHTTPOnly: false),
            storageEntry,
        ]
        let login = WebLoginSession(key: "k", request: request, presenter: Presenter(response: .webSession(all)), store: store)
        let cookies = try await login.cookies(forceLogin: true)
        #expect(cookies.map(\.name) == ["SESSION", "sessionStore"])
        #expect(cookies.last?.value == storageSecret)
        // `update` (cookie rotation during a sync) keeps the storage entry as well.
        try await login.update(all)
        #expect(try store.load("k")?.map(\.name) == ["SESSION", "sessionStore"])
    }

    @Test func v1RequestIgnoresPseudoCookiesOfOtherDomains() async throws {
        let request = WebLoginRequest(url: storageRequest.url, completion: .cookiesPresent(["SESSION"]), cookieDomains: ["example.invalid"], message: "m")
        let all = [
            SessionCookie(name: "SESSION", value: "c", domain: "example.invalid"),
            SessionCookie(name: "sessionStore", value: "x", domain: "tracker.invalid", isHTTPOnly: false),
        ]
        let login = WebLoginSession(key: "k", request: request, presenter: Presenter(response: .webSession(all)), store: InMemorySessionCookieStore())
        #expect(try await login.cookies(forceLogin: true).map(\.name) == ["SESSION"])
    }

    @Test func storageValuesAreRedacted() {
        var capture = WebLoginCapture(request: storageRequest)
        capture.recordStorage(scriptResult: #"{"0":"{\"accessToken\":\"t0p-s3cr3t-bearer\"}"}"#, page: storageRequest.url)
        #expect(capture.storageEntries == [storageEntry])
        var dumped = ""
        dump(capture, to: &dumped)
        let response = AuthResponse.webSession(capture.session(cookies: []))
        dump(response.description, to: &dumped)
        for text in [String(describing: capture), String(reflecting: capture), dumped, String(describing: response), String(reflecting: response), String(describing: storageEntry), String(reflecting: storageEntry), "\(capture.storageEntries)"] {
            #expect(!text.contains("t0p-s3cr3t-bearer"))
            #expect(!text.contains("accessToken"))
        }
    }
}

@Suite struct WebLoginCaptureTests {
    private let page = URL(string: "https://banking.example.invalid/app/home")!
    private let httpOnly = SessionCookie(name: "SESSION", value: "s", domain: ".example.invalid", isHTTPOnly: true)

    @Test func scriptReadsOnlyKeysOfThePageHost() throws {
        var request = storageRequest
        request.storageKeys += [
            StorageKey(key: "dev\"ice';alert(1)//", source: .localStorage, domain: "Banking.Example.invalid"),
            StorageKey(key: "elsewhere", source: .localStorage, domain: "other.invalid"),
        ]
        let capture = WebLoginCapture(request: request)
        let script = try #require(capture.storageScript(forPage: page))
        #expect(script.contains(#"window.sessionStorage.getItem("sessionStore")"#))
        // Storage keys are JSON literals: quotes stay escaped, nothing breaks out into code.
        #expect(script.contains(#"window.localStorage.getItem("dev\"ice';alert(1)\/\/")"#) || script.contains(#"window.localStorage.getItem("dev\"ice';alert(1)//")"#))
        #expect(!script.contains("elsewhere"))
        // Web Storage is per origin: no script on other hosts, including parent/sub domains.
        #expect(capture.storageScript(forPage: URL(string: "https://example.invalid/")) == nil)
        #expect(capture.storageScript(forPage: URL(string: "https://x.banking.example.invalid/")) == nil)
        #expect(capture.storageScript(forPage: nil) == nil)
        #expect(WebLoginCapture(request: WebLoginRequest(url: page, completion: .urlPrefix("x"), cookieDomains: [], message: "")).storageScript(forPage: page) == nil)
    }

    @Test func javaScriptKeyEvaluatesExpressionAndHandsOverValue() throws {
        let request = WebLoginRequest(
            url: page, completion: .cookiesPresent(["UniqueKey"]), cookieDomains: ["example.invalid"], message: "",
            storageKeys: [
                .javaScript(key: "UniqueKey", expression: "window.VeriBranch.Config.UniqueKey", domain: "banking.example.invalid"),
                .javaScript(key: "Config", expression: "window.VeriBranch.Config", domain: "banking.example.invalid"),
            ]
        )
        var capture = WebLoginCapture(request: request)
        let script = try #require(capture.storageScript(forPage: page))
        #expect(script.contains("return (window.VeriBranch.Config.UniqueKey);"))
        #expect(script.contains("JSON.stringify(v)"))     // objects are JSON-encoded
        #expect(!capture.isComplete(currentURL: page, cookies: [httpOnly]))
        capture.recordStorage(scriptResult: #"{"0":"639298","1":"{\"PCID\":\"p\"}"}"#, page: page)
        #expect(capture.isComplete(currentURL: page, cookies: [httpOnly]))
        #expect(capture.storageEntries == [
            SessionCookie(name: "UniqueKey", value: "639298", domain: "banking.example.invalid", isHTTPOnly: false),
            SessionCookie(name: "Config", value: #"{"PCID":"p"}"#, domain: "banking.example.invalid", isHTTPOnly: false),
        ])
    }

    @Test func v2StorageKeyJSONDecodesWithoutExpression() throws {
        let json = #"{"key":"sessionStore","source":"sessionStorage","domain":"banking.c24.de"}"#
        let key = try JSONDecoder().decode(StorageKey.self, from: Data(json.utf8))
        #expect(key == StorageKey(key: "sessionStore", source: .sessionStorage, domain: "banking.c24.de"))
        #expect(key.expression == nil)
    }

    @Test func cookiesPresentIsMetByStorageEntry() {
        var capture = WebLoginCapture(request: storageRequest)
        #expect(!capture.isComplete(currentURL: page, cookies: [httpOnly]))
        #expect(capture.isMissingStorage(forPage: page))
        capture.recordStorage(scriptResult: "{}", page: page)
        #expect(!capture.isComplete(currentURL: page, cookies: [httpOnly]))
        capture.recordStorage(scriptResult: #"{"0":"raw"}"#, page: page)
        #expect(capture.isComplete(currentURL: page, cookies: []))
        #expect(!capture.isMissingStorage(forPage: page))
        #expect(capture.session(cookies: [httpOnly]) == [httpOnly, SessionCookie(name: "sessionStore", value: "raw", domain: "banking.example.invalid", isHTTPOnly: false)])
    }

    @Test func cookiesPresentMixesCookiesAndStorage() {
        var request = storageRequest
        request.completion = .cookiesPresent(["SESSION", "sessionStore"])
        var capture = WebLoginCapture(request: request)
        capture.recordStorage(scriptResult: #"{"0":"raw"}"#, page: page)
        #expect(!capture.isComplete(currentURL: page, cookies: [SessionCookie(name: "SESSION", value: "s", domain: "tracker.invalid")]))
        #expect(capture.isComplete(currentURL: page, cookies: [httpOnly]))
    }

    @Test func missingKeyYieldsNoEntryAndRemovedKeyDropsIt() {
        var request = storageRequest
        request.completion = .urlPrefix("https://banking.example.invalid/app")
        var capture = WebLoginCapture(request: request)
        #expect(capture.isComplete(currentURL: page, cookies: []))
        #expect(!capture.isComplete(currentURL: request.url, cookies: []))
        capture.recordStorage(scriptResult: nil, page: page)
        #expect(capture.session(cookies: [httpOnly]) == [httpOnly])
        capture.recordStorage(scriptResult: #"{"0":"raw"}"#, page: page)
        // A read on a foreign page neither adds nor removes anything.
        capture.recordStorage(scriptResult: "{}", page: URL(string: "https://other.invalid/"))
        #expect(capture.storageEntries.count == 1)
        capture.recordStorage(scriptResult: "not json", page: page)
        #expect(capture.storageEntries.isEmpty)
    }

    @Test func storageEntryReplacesCookieOfSameNameAndDomain() {
        var capture = WebLoginCapture(request: storageRequest)
        capture.recordStorage(scriptResult: #"{"0":"raw"}"#, page: page)
        let clash = SessionCookie(name: "sessionStore", value: "cookie", domain: "banking.example.invalid")
        #expect(capture.session(cookies: [clash, httpOnly]).map(\.value) == ["s", "raw"])
    }

    @Test func convertsHTTPCookiesIncludingHttpOnlyAndWAFToken() throws {
        // Whole seconds, within the 400-day cap Foundation applies to cookie lifetimes.
        let expires = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86_400).rounded())
        let session = try #require(HTTPCookie(properties: [
            .name: "tr_session", .value: "abc", .domain: ".example.invalid", .path: "/", .secure: "TRUE",
            .expires: expires, HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]))
        let waf = try #require(HTTPCookie(properties: [.name: "aws-waf-token", .value: "waf", .domain: "app.example.invalid", .path: "/"]))
        let converted = [session, waf].map(WebLoginCapture.sessionCookie)
        #expect(converted[0] == SessionCookie(name: "tr_session", value: "abc", domain: ".example.invalid", path: "/", expires: expires, isSecure: true, isHTTPOnly: true))
        #expect(converted[1] == SessionCookie(name: "aws-waf-token", value: "waf", domain: "app.example.invalid", path: "/", expires: nil, isSecure: false, isHTTPOnly: false))
        let request = WebLoginRequest(url: page, completion: .cookiesPresent(["tr_session"]), cookieDomains: ["example.invalid"], message: "m")
        let capture = WebLoginCapture(request: request)
        #expect(capture.isComplete(currentURL: page, cookies: converted))
        #expect(capture.session(cookies: converted).map(\.name) == ["tr_session", "aws-waf-token"])
    }
}
