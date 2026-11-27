import Foundation
import JavaScriptCore
import MFNConformance
import MFNCore
import Testing
@testable import MFNTradeRepublic

/// Runs `TRLoginScript.source` in JavaScriptCore with a stubbed page: `document.cookie`,
/// `sessionStorage`, `fetch` (answers from `Fixtures/TradeRepublic` and error bodies from the
/// web bundle), `setTimeout` on a fake clock and the `mfn` bridge.
final class TRLoginHarness {
    struct Route {
        var method: String
        /// Path prefix on `api.traderepublic.com`, or a full URL.
        var path: String
        /// Answers in order; the last one repeats.
        var responses: [(status: Int, body: String?)]
    }

    struct Request: Equatable {
        var method: String
        var url: String
        var headers: [String: String]
        var body: String?
        var credentials: String?
    }

    struct Outcome {
        var state: Any?
        var error: String?
    }

    let context: JSContext
    static let credentials = ["phoneNumber": "0170 1234567", "pin": "1357"]

    init(cookie: String = "aws-waf-token=WAF-TEST; tr_locale=de", routes: [Route], codes: [String] = []) throws {
        context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("JS exception: \(exception?.toString() ?? "?")")
        }
        let routeObjects = routes.map { route in
            [
                "method": route.method,
                "path": route.path,
                "responses": route.responses.map { ["status": $0.status, "body": $0.body ?? NSNull()] as [String: Any] },
            ] as [String: Any]
        }
        context.setObject(routeObjects, forKeyedSubscript: "__routes" as NSString)
        context.setObject(codes, forKeyedSubscript: "__codeAnswers" as NSString)
        context.setObject(cookie, forKeyedSubscript: "__cookie" as NSString)
        context.evaluateScript(Self.stubs)
        context.evaluateScript("var __login = async function(credentials, state, url) {\n\(TRLoginScript.source)\n};")
    }

    func run(state: Any? = nil, url: String = "https://app.traderepublic.com/login", credentials: [String: String] = credentials) -> Outcome {
        context.setObject(credentials, forKeyedSubscript: "__creds" as NSString)
        context.setObject(state ?? NSNull(), forKeyedSubscript: "__state" as NSString)
        context.setObject(url, forKeyedSubscript: "__url" as NSString)
        context.evaluateScript("""
        var __result = undefined;
        __login(__creds, __state, __url).then(
          (v) => { __result = { state: v === undefined ? null : v }; },
          (e) => { __result = { error: String((e && e.message) || e) }; });
        """)
        let result = context.objectForKeyedSubscript("__result")
        guard let result, !result.isUndefined else {
            Issue.record("login script did not settle")
            return Outcome(state: nil, error: "pending")
        }
        let error = result.objectForKeyedSubscript("error")
        return Outcome(
            state: result.objectForKeyedSubscript("state")?.toObject(),
            error: (error?.isUndefined ?? true) ? nil : error?.toString()
        )
    }

    var requests: [Request] {
        let list = context.objectForKeyedSubscript("__requests")?.toArray() as? [[String: Any]] ?? []
        return list.map {
            Request(
                method: $0["method"] as? String ?? "",
                url: $0["url"] as? String ?? "",
                headers: $0["headers"] as? [String: String] ?? [:],
                body: $0["body"] as? String,
                credentials: $0["credentials"] as? String
            )
        }
    }

    /// Requests to the API (without `app-version.txt`).
    var apiRequests: [Request] { requests.filter { $0.url.hasPrefix("https://api.") } }
    var statuses: [String] { context.objectForKeyedSubscript("__statuses")?.toArray() as? [String] ?? [] }
    var codePrompts: [[Any]] { context.objectForKeyedSubscript("__codePrompts")?.toArray() as? [[Any]] ?? [] }
    var sessionStorage: [String: String] {
        context.evaluateScript("__session")?.toDictionary() as? [String: String] ?? [:]
    }
    var clock: Double { context.objectForKeyedSubscript("__now")?.toDouble() ?? 0 }

    func setCookie(_ cookie: String) {
        context.setObject(cookie, forKeyedSubscript: "__cookie" as NSString)
    }

    func setRoutes(_ routes: [Route]) {
        let routeObjects = routes.map { route in
            ["method": route.method, "path": route.path,
             "responses": route.responses.map { ["status": $0.status, "body": $0.body ?? NSNull()] as [String: Any] }] as [String: Any]
        }
        context.setObject(routeObjects, forKeyedSubscript: "__routes" as NSString)
        context.evaluateScript("__hits = {};")
    }

    private static let stubs = """
    var __now = 1700000000000;
    Date.now = () => __now;
    var __requests = [], __statuses = [], __codePrompts = [], __session = {}, __hits = {};
    function setTimeout(fn, ms) { __now += (ms || 0); Promise.resolve().then(fn); return 1; }
    var document = {
      get cookie() { return __cookie; },
      createElement: () => ({ getContext: () => null }),
    };
    // JavaScriptCore has no `URL`; WebKit pages do. Enough of it for `origin`.
    var URL = function (u) {
      var m = /^([a-z][a-z0-9+.-]*):[/][/]([^/?#@]+)/i.exec(String(u));
      if (!m) throw new TypeError("Invalid URL");
      this.origin = m[1].toLowerCase() + "://" + m[2].toLowerCase();
    };
    var sessionStorage = {
      getItem: (k) => (k in __session ? __session[k] : null),
      setItem: (k, v) => { __session[k] = String(v); },
      removeItem: (k) => { delete __session[k]; },
    };
    var navigator = {
      userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
      languages: ["de-DE", "de"], hardwareConcurrency: 10,
    };
    var screen = { width: 1512, height: 982, colorDepth: 30 };
    function btoa(s) { return "b64:" + s; }
    var mfn = {
      status: (t) => { __statuses.push(String(t)); },
      requestCode: (prompt, length) => {
        __codePrompts.push([prompt, length]);
        return __codeAnswers.length ? Promise.resolve(__codeAnswers.shift()) : Promise.reject("cancelled");
      },
    };
    function fetch(url, init) {
      init = init || {};
      __requests.push({ url: url, method: init.method || "GET", headers: init.headers || {}, body: init.body, credentials: init.credentials });
      const path = url.replace("https://api.traderepublic.com", "");
      let index = -1;
      for (let i = 0; i < __routes.length; i++) {
        const r = __routes[i];
        if (r.method === (init.method || "GET") && (path.startsWith(r.path) || url === r.path)) {
          if (index < 0 || r.path.length > __routes[index].path.length) index = i;
        }
      }
      if (index < 0) return Promise.resolve({ status: 404, json: () => Promise.reject(new Error("empty")), text: () => Promise.resolve("") });
      const route = __routes[index];
      const hit = __hits[index] || 0;
      __hits[index] = hit + 1;
      const answer = route.responses[Math.min(hit, route.responses.length - 1)];
      return Promise.resolve({
        status: answer.status,
        json: () => answer.body == null ? Promise.reject(new Error("empty")) : Promise.resolve(JSON.parse(answer.body)),
        text: () => Promise.resolve(answer.body == null ? "" : answer.body),
      });
    }
    """
}

@Suite struct TRLoginScriptTests {
    static func fixture(_ name: String) -> String {
        (try? Fixtures.data(.tradeRepublic, name)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func error(_ code: String) -> String { #"{"errors":[{"errorCode":"\#(code)","meta":{}}]}"# }

    static let login = TRLoginHarness.Route(method: "POST", path: "/api/v2/auth/web/login", responses: [(200, fixture("login.json"))])
    static let processID = "33bee977-e31f-42f5-acf8-f347f186ef5f"
    static let processPath = "/api/v2/auth/web/login/processes/\(processID)"
    static let pollUntilConfirmed = TRLoginHarness.Route(
        method: "GET", path: processPath,
        responses: [(200, fixture("login-process-pending.json")), (200, fixture("login-process-pending.json")), (200, fixture("login-process-done.json"))]
    )
    static let version = TRLoginHarness.Route(method: "GET", path: "https://app.traderepublic.com/app-version.txt", responses: [(200, "2.2700.1\n")])

    @Test func loginRequestCarriesAutomation() throws {
        guard case let .webLogin(request) = TRSession.loginChallenge else {
            Issue.record("expected webLogin")
            return
        }
        let automation = try #require(request.automation)
        #expect(automation.script == TRLoginScript.source)
        #expect(automation.timeout >= 120)
        #expect(request.url.absoluteString == "https://app.traderepublic.com/login")
        #expect(request.completion == .cookiesPresent(["tr_session"]))
        // Credentials are arguments, never part of the source.
        #expect(!automation.script.contains("1357"))
        #expect(!automation.script.contains("console."))
    }

    @Test func confirmInAppPollsUntilConfirmed() throws {
        let harness = try TRLoginHarness(routes: [Self.version, Self.login, Self.pollUntilConfirmed])
        let outcome = harness.run()
        #expect(outcome.error == nil)
        #expect((outcome.state as? [String: Any])?["step"] as? String == "done")

        let api = harness.apiRequests
        #expect(api.map(\.method) == ["POST", "GET", "GET", "GET"])
        let start = try #require(api.first)
        #expect(start.url == "https://api.traderepublic.com/api/v2/auth/web/login")
        #expect(start.credentials == "include")
        let body = try #require(start.body.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] })
        #expect(body == ["phoneNumber": "+491701234567", "pin": "1357"])
        #expect(start.headers["X-Tr-Platform"] == "web-pro")
        #expect(start.headers["X-TR-App-Version"] == "2.2700.1")
        #expect(start.headers["X-Aws-Waf-Token"] == "WAF-TEST")
        #expect(start.headers["X-TR-Device-Info"]?.hasPrefix("b64:{") == true)
        #expect(start.headers["X-TR-Device-Info"]?.contains("1357") == false)
        #expect(api[1].url == "https://api.traderepublic.com" + Self.processPath)
        #expect(api[1].body == nil)

        #expect(harness.statuses.contains(TRLoginScript.confirmMessage))
        #expect(harness.sessionStorage.isEmpty) // marker removed after success
        #expect(harness.codePrompts.isEmpty)
    }

    @Test(arguments: [
        ("+49 170 1234567", "+491701234567"),
        ("0170/1234567", "+491701234567"),
        ("0049 170 1234567", "+491701234567"),
        ("+43 660 1234567", "+436601234567"),
    ])
    func normalizesPhoneNumber(input: String, expected: String) throws {
        let harness = try TRLoginHarness(routes: [Self.login, Self.pollUntilConfirmed])
        _ = harness.run(credentials: ["phoneNumber": input, "pin": "1357"])
        let body = try #require(harness.apiRequests.first?.body)
        #expect(body.contains(#""phoneNumber":"\#(expected)""#))
    }

    @Test(arguments: ["AUTHENTICATION_ERROR", "INVALID_VALUE", "NUMBER_INVALID", "TOO_MANY_REQUESTS"])
    func rejectedLoginIsAuthFailedWithoutRetry(code: String) throws {
        let start = TRLoginHarness.Route(method: "POST", path: "/api/v2/auth/web/login", responses: [(code == "TOO_MANY_REQUESTS" ? 429 : 401, Self.error(code))])
        let harness = try TRLoginHarness(routes: [start])
        let outcome = harness.run()
        #expect(outcome.error?.hasPrefix("authFailed") == true)
        #expect(harness.apiRequests.count == 1) // no second attempt, no v1 fallback
    }

    @Test func malformedCredentialsFailBeforeAnyRequest() throws {
        let harness = try TRLoginHarness(routes: [Self.login])
        #expect(harness.run(credentials: ["phoneNumber": "abc", "pin": "1357"]).error?.hasPrefix("authFailed") == true)
        #expect(harness.run(credentials: ["phoneNumber": "+491701234567", "pin": "12"]).error?.hasPrefix("authFailed") == true)
        #expect(harness.apiRequests.isEmpty)
    }

    @Test(arguments: ["LOGIN_NOT_ALLOWED", "WEBTRADING_NOT_AVAILABLE", "GEO_BLOCKED"])
    func notAllowedIsOtherError(code: String) throws {
        let start = TRLoginHarness.Route(method: "POST", path: "/api/v2/auth/web/login", responses: [(403, Self.error(code))])
        let harness = try TRLoginHarness(routes: [start])
        let outcome = harness.run()
        #expect(outcome.error != nil)
        #expect(outcome.error?.hasPrefix("authFailed") == false)
        #expect(harness.apiRequests.count == 1)
    }

    @Test func rejectedInAppIsAuthFailed() throws {
        let poll = TRLoginHarness.Route(method: "GET", path: Self.processPath, responses: [(200, Self.fixture("login-process-pending.json")), (409, Self.error("ALREADY_PROCESSED"))])
        let harness = try TRLoginHarness(routes: [Self.login, poll])
        #expect(harness.run().error?.hasPrefix("authFailed") == true)
        // The process marker is gone; the submit marker stays so a reload never resends the PIN.
        #expect(harness.sessionStorage == ["mfn.tr.submitted": "1"])
    }

    /// A process that ended without confirmation stops polling at once.
    @Test(arguments: ["REJECTED", "FAILED", "CANCELLED", "DECLINED"])
    func terminalStatusIsAuthFailed(status: String) throws {
        let poll = TRLoginHarness.Route(method: "GET", path: Self.processPath, responses: [
            (200, Self.fixture("login-process-pending.json")),
            (200, #"{"status":"\#(status)","requiredAction":null,"expiresAt":null,"claims":null}"#),
        ])
        let harness = try TRLoginHarness(routes: [Self.login, poll])
        #expect(harness.run().error?.hasPrefix("authFailed") == true)
        #expect(harness.apiRequests.count == 3)
        #expect(harness.sessionStorage == ["mfn.tr.submitted": "1"])
    }

    @Test func expiredProcessIsNotAuthFailed() throws {
        let poll = TRLoginHarness.Route(method: "GET", path: Self.processPath, responses: [(410, Self.error("PROCESS_GONE"))])
        let harness = try TRLoginHarness(routes: [Self.login, poll])
        let outcome = harness.run()
        #expect(outcome.error == "login expired")
    }

    @Test func pollingStopsAtDeadline() throws {
        let poll = TRLoginHarness.Route(method: "GET", path: Self.processPath, responses: [(200, Self.fixture("login-process-pending.json"))])
        let harness = try TRLoginHarness(routes: [Self.login, poll])
        let start = harness.clock
        #expect(harness.run().error == "login expired")
        // countdown 120 s (default) + 60 s grace, polled every 2 s.
        #expect(harness.clock - start <= 182_000)
        #expect(harness.apiRequests.count <= 92)
    }

    @Test func authenticatorCodeIsRequested() throws {
        let poll = TRLoginHarness.Route(method: "GET", path: Self.processPath, responses: [
            (200, #"{"status":"PENDING","requiredAction":"AUTHENTICATOR_VERIFICATION","expiresAt":null,"claims":null}"#),
            (200, Self.fixture("login-process-done.json")),
        ])
        let verify = TRLoginHarness.Route(method: "POST", path: Self.processPath + "/authenticator-verification", responses: [(400, Self.error("VALIDATION_CODE_INVALID")), (204, nil)])
        let harness = try TRLoginHarness(routes: [Self.login, poll, verify], codes: ["111111", "123456"])
        let outcome = harness.run()
        #expect(outcome.error == nil)
        #expect(harness.codePrompts.count == 2)
        #expect(harness.codePrompts.first?.last as? Int == 6)
        let posts = harness.apiRequests.filter { $0.url.hasSuffix("/authenticator-verification") }
        #expect(posts.map(\.body) == [#"{"code":"111111"}"#, #"{"code":"123456"}"#])
    }

    @Test func cancelledCodeEntryEndsLogin() throws {
        let poll = TRLoginHarness.Route(method: "GET", path: Self.processPath, responses: [
            (200, #"{"status":"PENDING","requiredAction":"AUTHENTICATOR_VERIFICATION","expiresAt":null,"claims":null}"#),
        ])
        let harness = try TRLoginHarness(routes: [Self.login, poll], codes: [])
        #expect(harness.run().error == "cancelled")
    }

    /// The v1 login would send the PIN a second time: stop instead of falling back.
    @Test(arguments: ["DEVICE_NOT_FOUND", "MOBILE_APP_VERSION_NOT_SUPPORTED"])
    func explicitV1CodeStopsWithoutSecondPIN(code: String) throws {
        let start = TRLoginHarness.Route(method: "POST", path: "/api/v2/auth/web/login", responses: [(400, Self.error(code))])
        let v1 = TRLoginHarness.Route(method: "POST", path: "/api/v1/auth/web/login", responses: [(200, #"{"processId":"p-1","countdownInSeconds":30,"2fa":"SMS"}"#)])
        let harness = try TRLoginHarness(routes: [start, v1], codes: ["4711"])
        let outcome = harness.run()
        #expect(outcome.error?.hasPrefix("login needs the older SMS flow") == true)
        #expect(outcome.error?.hasPrefix("authFailed") == false)
        #expect(harness.apiRequests.map(\.url) == ["https://api.traderepublic.com/api/v2/auth/web/login"])
        #expect(harness.codePrompts.isEmpty)
    }

    @Test func submitMarkerIsWrittenBeforeThePIN() throws {
        let harness = try TRLoginHarness(routes: [Self.login, Self.pollUntilConfirmed])
        harness.context.evaluateScript("""
        var __markerAtPost = null;
        const __fetch = fetch;
        fetch = (u, init) => {
          if (init && init.method === "POST") __markerAtPost = sessionStorage.getItem("mfn.tr.submitted");
          return __fetch(u, init);
        };
        """)
        #expect(harness.run().error == nil)
        #expect(harness.context.evaluateScript("__markerAtPost")?.toString() == "1")
        #expect(harness.sessionStorage.isEmpty) // both markers removed after success
    }

    @Test func reentryAfterSubmitWithoutProcessNeverResendsThePIN() throws {
        let harness = try TRLoginHarness(routes: [Self.login, Self.pollUntilConfirmed])
        harness.context.evaluateScript("__session['mfn.tr.submitted'] = '1';")
        let outcome = harness.run(state: nil)
        #expect(outcome.error == "login already submitted, not sending the PIN again")
        #expect(harness.apiRequests.isEmpty)
    }

    @Test func lookalikeOriginIsIgnored() throws {
        let harness = try TRLoginHarness(routes: [Self.login])
        _ = harness.run(url: "https://app.traderepublic.com.example.org/login")
        _ = harness.run(url: "https://app.traderepublic.community/login")
        #expect(harness.requests.isEmpty)
    }

    /// A failed v2 start without an explicit fallback code must not send the PIN a second time.
    @Test(arguments: [(503, nil), (500, Self.error("INTERNAL_ERROR")), (400, Self.error("SOMETHING_NEW")), (400, nil)] as [(Int, String?)])
    func otherStartFailuresDoNotRetryThePIN(status: Int, body: String?) throws {
        let start = TRLoginHarness.Route(method: "POST", path: "/api/v2/auth/web/login", responses: [(status, body)])
        let v1 = TRLoginHarness.Route(method: "POST", path: "/api/v1/auth/web/login", responses: [(200, #"{"processId":"p-1","2fa":"SMS"}"#)])
        let harness = try TRLoginHarness(routes: [start, v1])
        let outcome = harness.run()
        #expect(outcome.error?.hasPrefix("login start HTTP \(status)") == true)
        #expect(harness.apiRequests.count == 1)
        #expect(harness.codePrompts.isEmpty)
    }

    @Test func waitsForWAFTokenAndGivesUp() throws {
        let harness = try TRLoginHarness(cookie: "tr_locale=de", routes: [Self.login])
        let outcome = harness.run()
        #expect(outcome.error == "aws-waf-token missing")
        #expect(harness.apiRequests.isEmpty)
    }

    @Test func reentryResumesPollingInsteadOfSecondLogin() throws {
        // First page: login started, then the page navigates away (simulated: poll keeps pending
        // and the run is abandoned by expiring). The marker survives in sessionStorage.
        let pending = TRLoginHarness.Route(method: "GET", path: Self.processPath, responses: [(200, Self.fixture("login-process-pending.json"))])
        let harness = try TRLoginHarness(routes: [Self.login, pending])
        harness.context.evaluateScript("__session['mfn.tr.login'] = JSON.stringify({ processId: '\(Self.processID)', at: __now });")
        harness.setRoutes([Self.login, Self.pollUntilConfirmed])
        let outcome = harness.run(state: nil)
        #expect(outcome.error == nil)
        #expect(!harness.apiRequests.contains { $0.method == "POST" })

        // Same via state from the previous run.
        let second = try TRLoginHarness(routes: [Self.login, Self.pollUntilConfirmed])
        #expect(second.run(state: ["step": "confirm", "processId": Self.processID]).error == nil)
        #expect(!second.apiRequests.contains { $0.method == "POST" })
    }

    @Test func doneStateAndForeignPagesDoNothing() throws {
        let harness = try TRLoginHarness(routes: [Self.login])
        let done = harness.run(state: ["step": "done"])
        #expect((done.state as? [String: Any])?["step"] as? String == "done")
        _ = harness.run(url: "https://traderepublic.com/de-de")
        #expect(harness.requests.isEmpty)
    }

    @Test func credentialsNeverLeakIntoStateOrStorage() throws {
        let harness = try TRLoginHarness(routes: [Self.version, Self.login, Self.pollUntilConfirmed])
        // Inspect the marker while polling.
        harness.context.evaluateScript("""
        var __seen = [];
        const __set = sessionStorage.setItem;
        sessionStorage.setItem = (k, v) => { __seen.push(String(v)); __set(k, v); };
        """)
        let outcome = harness.run()
        let state = try JSONSerialization.data(withJSONObject: outcome.state ?? [:])
        let stored = harness.context.objectForKeyedSubscript("__seen")?.toArray() as? [String] ?? []
        #expect(!stored.isEmpty)
        for text in [String(decoding: state, as: UTF8.self)] + stored + harness.statuses {
            #expect(!text.contains("1357"))
            #expect(!text.contains("1701234567"))
        }
        // Only the login endpoints are called.
        for request in harness.apiRequests {
            #expect(request.url.contains("/auth/web/login"))
        }
    }
}
