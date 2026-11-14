import Foundation
import JavaScriptCore
import MFNCore
import Testing
@testable import MFNC24

/// Runs `C24LoginScript` in JavaScriptCore with stubbed `fetch`, `sessionStorage`, `setTimeout` and
/// bridge `mfn`. Responses are scripted per path (C24 login traffic is not in `Fixtures/C24`; shapes
/// from the public web-app bundle, values synthetic).
private final class ScriptRun {
    struct Response {
        var status: Int
        var json: String? // JSON literal or nil (no body)
    }

    let context: JSContext
    let endpoints: C24Endpoints

    init(endpoints: C24Endpoints = .qrTest, bridge: Bool = true, code: String = "'123456'") {
        self.endpoints = endpoints
        guard let context = JSContext() else { fatalError("JSContext unavailable") } // test setup
        self.context = context
        context.exceptionHandler = { _, exception in
            Issue.record("JS exception: \(exception?.toString() ?? "?")")
        }
        context.evaluateScript("""
        var log = { requests: [], qr: [], status: [], prompts: [], console: [] };
        var responses = {};
        var setTimeout = function (f, ms) { log.lastDelay = ms; Promise.resolve().then(f); };
        var console = { log: function () { log.console.push([].slice.call(arguments)); } };
        console.error = console.log; console.warn = console.log; console.info = console.log;
        var sessionStorage = {
          data: {},
          getItem: function (k) { return Object.prototype.hasOwnProperty.call(this.data, k) ? this.data[k] : null; },
          setItem: function (k, v) { this.data[k] = String(v); }
        };
        function fetch(u, init) {
          init = init || {};
          log.requests.push({ url: u, method: init.method || 'GET', headers: init.headers || {}, body: init.body === undefined ? null : init.body });
          var path = u.indexOf(API) === 0 ? u.substring(API.length) : u;
          var queue = responses[path];
          var r = queue && queue.length ? queue.shift() : { status: 599, json: null };
          return Promise.resolve({
            status: r.status,
            json: function () { return r.json === null ? Promise.reject(new Error('no body')) : Promise.resolve(JSON.parse(r.json)); }
          });
        }
        var mfn = {
          status: function (t) { log.status.push(t); },
          requestCode: function (p, l) { log.prompts.push([p, l]); return CODE; }
        };
        if (\(bridge)) mfn.showQRCode = function (payload, message) { log.qr.push([payload, message]); };
        """.replacingOccurrences(of: "API", with: "'https://api.c24.de'").replacingOccurrences(of: "CODE", with: code == "reject" ? "Promise.reject('cancelled')" : "Promise.resolve(\(code))"))
    }

    func respond(_ path: String, _ responses: Response...) {
        for response in responses {
            let json = response.json.map { "'\($0)'" } ?? "null"
            context.evaluateScript("(responses['\(path)'] = responses['\(path)'] || []).push({ status: \(response.status), json: \(json) });")
        }
    }

    func setStorage(_ key: String, _ value: String) {
        context.objectForKeyedSubscript("sessionStorage")?.invokeMethod("setItem", withArguments: [key, value])
    }

    /// Runs the script once; returns state JSON (or nil) and the error message (or nil).
    func run(
        credentials: [String: String] = [:],
        state: String = "null",
        url: String = "https://banking.c24.de/login"
    ) -> (state: String?, error: String?) {
        let script = C24LoginScript.automation(for: endpoints).script
        context.setObject(credentials, forKeyedSubscript: "__credentials" as NSString)
        context.setObject(url, forKeyedSubscript: "__url" as NSString)
        context.evaluateScript("var __state = null, __error = null, __finished = false;")
        context.evaluateScript("""
        (async function (credentials, state, url) {
        \(script)
        })(__credentials, \(state), __url).then(
          function (r) { __state = JSON.stringify(r === undefined ? null : r); __finished = true; },
          function (e) { __error = String(e && e.message !== undefined ? e.message : e); __finished = true; }
        );
        """)
        // Microtasks drain when each evaluation returns; give long chains a few more turns.
        for _ in 0..<50 where !(context.objectForKeyedSubscript("__finished")?.toBool() ?? false) {
            context.evaluateScript("0")
        }
        #expect(context.objectForKeyedSubscript("__finished")?.toBool() == true, "script did not finish")
        let state = context.objectForKeyedSubscript("__state")
        let error = context.objectForKeyedSubscript("__error")
        return (
            state.flatMap { $0.isNull ? nil : $0.toString() },
            error.flatMap { $0.isNull ? nil : $0.toString() }
        )
    }

    func eval(_ js: String) -> JSValue? { context.evaluateScript(js) }
    func strings(_ js: String) -> [String] { eval(js)?.toArray()?.compactMap { $0 as? String } ?? [] }
    var requestLines: [String] { strings("log.requests.map(function (r) { return r.method + ' ' + r.url; })") }
    var qrPayloads: [String] { strings("log.qr.map(function (q) { return q[0]; })") }
    var statuses: [String] { strings("log.status") }
    var storedSession: String? {
        let value = eval("sessionStorage.getItem('sessionStore')")
        return value.flatMap { $0.isNull ? nil : $0.toString() }
    }
}

extension C24Endpoints {
    /// Production values with the headless login switched on.
    static var qrTest: C24Endpoints {
        var endpoints = C24Endpoints.production
        endpoints.headlessLogin = true
        return endpoints
    }
}

private typealias R = ScriptRun.Response

@Suite struct C24LoginScriptTests {
    @Test func loginRequestCarriesAutomationOnlyWhenSwitchedOn() throws {
        var visible = C24Endpoints.production
        visible.headlessLogin = false
        #expect(visible.loginRequest.automation == nil)
        #expect(C24Endpoints.production.loginRequest.automation != nil, "protocol v5: headless QR login is on")
        let request = C24Endpoints.qrTest.loginRequest
        let automation = try #require(request.automation)
        #expect(automation.timeout == 300)
        #expect(automation.script.hasPrefix("const cfg = {"))
        #expect(automation.script.contains(#""apiBase":"https://api.c24.de""#))
        #expect(automation.script.contains(#""origin":"https://banking.c24.de""#))
        #expect(automation.script.contains("/api/qrtoken/generate/"))
        #expect(automation.script.contains("/api/web-login/complete/"))
        // Completion and hand-over unchanged.
        #expect(request.completion == .cookiesPresent(["sessionStore"]))
        #expect(request.storageKeys == [StorageKey(key: "sessionStore", source: .sessionStorage, domain: "banking.c24.de")])
        // Never reads credentials (C24 has none).
        #expect(!automation.script.contains("credentials."))
        #expect(!automation.script.contains("credentials["))
        #expect(!automation.script.contains("console."))
    }

    @Test func scanRotateCodeAndComplete() throws {
        let run = ScriptRun()
        run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"qrtoken":"qr-1"}"#))
        run.respond(
            "/api/qrtoken/status/",
            R(status: 200, json: #"{}"#),
            R(status: 200, json: #"{"qrtoken":"qr-2"}"#),
            R(status: 200, json: #"{"qrtoken":"qr-2","web_login_uuid":"uuid-1"}"#)
        )
        run.respond("/api/web-login/complete/", R(status: 200, json: #"{"access_token":"acc-1","refresh_token":"ref-1"}"#))

        let result = run.run()
        #expect(result.error == nil)
        #expect(result.state == #"{"done":true}"#)
        #expect(run.qrPayloads == ["qr-1", "qr-2"])
        #expect(run.requestLines == [
            "GET https://api.c24.de/api/qrtoken/generate/",
            "POST https://api.c24.de/api/qrtoken/status/",
            "POST https://api.c24.de/api/qrtoken/status/",
            "POST https://api.c24.de/api/qrtoken/status/",
            "POST https://api.c24.de/api/web-login/complete/",
        ])
        #expect(run.strings("log.requests.slice(1, 4).map(function (r) { return r.body; })") == [
            #"{"qrtoken":"qr-1"}"#, #"{"qrtoken":"qr-1"}"#, #"{"qrtoken":"qr-2"}"#,
        ])
        let complete = try #require(run.eval("JSON.parse(log.requests[4].body)")?.toDictionary() as? [String: String])
        #expect(complete == ["web_login_pin": "123456", "qrtoken": "qr-2", "web_login_uuid": "uuid-1"])
        #expect(run.eval("log.requests[4].headers['Content-Type']")?.toString() == "application/json")
        #expect(run.eval("JSON.stringify(log.prompts)")?.toString() == #"[["6 Ziffern aus der C24-App",6]]"#)
        #expect(run.eval("log.lastDelay")?.toInt32() == 2_000)

        let stored = try #require(run.storedSession)
        let session = try #require(try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: String])
        #expect(session == ["guid": "uuid-1", "accessToken": "acc-1", "refreshToken": "ref-1"])
        // The connector reads the access token from exactly this value.
        #expect(C24SessionStore.accessToken(in: stored, field: "accessToken") == "acc-1")
        #expect(run.statuses == ["Gib die 6 Ziffern aus der C24-App ein.", "Angemeldet."])
    }

    @Test func failedStatusShowsANewQRCode() {
        let run = ScriptRun()
        run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"qrtoken":"qr-1"}"#), R(status: 200, json: #"{"qrtoken":"qr-9"}"#))
        run.respond(
            "/api/qrtoken/status/",
            R(status: 410, json: nil),
            R(status: 200, json: #"{"web_login_uuid":"uuid-2"}"#)
        )
        run.respond("/api/web-login/complete/", R(status: 200, json: #"{"access_token":"acc-2"}"#))

        let result = run.run()
        #expect(result.error == nil)
        #expect(result.state == #"{"done":true}"#)
        #expect(run.qrPayloads == ["qr-1", "qr-9"])
        #expect(run.statuses.first == "QR-Code abgelaufen, neuer Code wird erzeugt.")
        #expect(run.eval("JSON.parse(log.requests[3].body).qrtoken")?.toString() == "qr-9")
    }

    @Test func tooManyRotationsStartOver() {
        let run = ScriptRun()
        run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"qrtoken":"a"}"#), R(status: 200, json: #"{"qrtoken":"z"}"#))
        run.respond(
            "/api/qrtoken/status/",
            R(status: 200, json: #"{"qrtoken":"b"}"#),
            R(status: 200, json: #"{"qrtoken":"c"}"#),
            R(status: 200, json: #"{"qrtoken":"d"}"#), // third rotation: expired like in the web app
            R(status: 200, json: #"{"web_login_uuid":"u"}"#)
        )
        run.respond("/api/web-login/complete/", R(status: 200, json: #"{"access_token":"t"}"#))

        let result = run.run()
        #expect(result.state == #"{"done":true}"#)
        #expect(run.qrPayloads == ["a", "b", "c", "z"])
    }

    @Test func givesUpAfterTooManyQRCodes() {
        let run = ScriptRun()
        for _ in 0..<5 {
            run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"qrtoken":"q"}"#))
            run.respond("/api/qrtoken/status/", R(status: 404, json: nil))
        }
        let result = run.run()
        #expect(result.state == nil)
        let error = result.error ?? ""
        #expect(!error.hasPrefix("authFailed"))
        #expect(run.qrPayloads.count == 5)
        #expect(run.storedSession == nil)
    }

    @Test func rejectedCodeIsAuthFailed() {
        let run = ScriptRun()
        run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"qrtoken":"q"}"#))
        run.respond("/api/qrtoken/status/", R(status: 200, json: #"{"web_login_uuid":"u"}"#))
        run.respond("/api/web-login/complete/", R(status: 400, json: #"{"detail":"invalid"}"#))

        let result = run.run()
        #expect(result.error?.hasPrefix("authFailed") == true)
        #expect(run.storedSession == nil)
        // Exactly one attempt: never retried.
        #expect(run.requestLines.filter { $0.hasSuffix("/api/web-login/complete/") }.count == 1)
    }

    @Test func malformedCodeIsAuthFailedWithoutRequest() {
        let run = ScriptRun(code: "'12a456'")
        run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"qrtoken":"q"}"#))
        run.respond("/api/qrtoken/status/", R(status: 200, json: #"{"web_login_uuid":"u"}"#))
        let result = run.run()
        #expect(result.error?.hasPrefix("authFailed") == true)
        #expect(!run.requestLines.contains { $0.hasSuffix("/api/web-login/complete/") })
    }

    @Test func cancelledCodeEntryIsNotAuthFailed() {
        let run = ScriptRun(code: "reject")
        run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"qrtoken":"q"}"#))
        run.respond("/api/qrtoken/status/", R(status: 200, json: #"{"web_login_uuid":"u"}"#))
        let result = run.run()
        #expect(result.error == "cancelled")
        #expect(run.storedSession == nil)
    }

    @Test func serverErrorOnCompleteIsNotAuthFailed() {
        let run = ScriptRun()
        run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"qrtoken":"q"}"#))
        run.respond("/api/qrtoken/status/", R(status: 200, json: #"{"web_login_uuid":"u"}"#))
        run.respond("/api/web-login/complete/", R(status: 503, json: nil))
        let result = run.run()
        #expect(result.error == "login incomplete")
    }

    @Test func reEntryAfterCompletionDoesNothing() {
        let run = ScriptRun()
        let result = run.run(state: #"{"done":true}"#)
        #expect(result.state == #"{"done":true}"#)
        #expect(run.requestLines.isEmpty)
        #expect(run.qrPayloads.isEmpty)
    }

    @Test func existingSessionEndsTheScript() {
        let run = ScriptRun()
        run.setStorage("sessionStore", #"{"guid":"g","accessToken":"present"}"#)
        let result = run.run()
        #expect(result.state == #"{"done":true}"#)
        #expect(run.requestLines.isEmpty)
    }

    @Test func sessionWithoutTokenStartsALogin() {
        let run = ScriptRun()
        run.setStorage("sessionStore", "not json")
        run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"qrtoken":"q"}"#))
        run.respond("/api/qrtoken/status/", R(status: 200, json: #"{"web_login_uuid":"u"}"#))
        run.respond("/api/web-login/complete/", R(status: 200, json: #"{"access_token":"t"}"#))
        #expect(run.run().state == #"{"done":true}"#)
        #expect(run.qrPayloads == ["q"])
    }

    @Test func missingBridgeFailsWithoutAnyRequest() {
        let run = ScriptRun(bridge: false)
        let result = run.run()
        #expect(result.error == "qr bridge missing")
        #expect(run.requestLines.isEmpty)
    }

    @Test func foreignPageFailsWithoutAnyRequest() {
        let run = ScriptRun()
        let result = run.run(url: "https://evil.example/login")
        #expect(result.error == "unexpected page")
        #expect(run.requestLines.isEmpty)
    }

    @Test func missingQRTokenIsFormatError() {
        let run = ScriptRun()
        run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"token":"renamed"}"#))
        let result = run.run()
        #expect(result.error == "qr token missing")
    }

    @Test func secretsNeverLandInStateRequestsOrConsole() {
        let run = ScriptRun()
        run.respond("/api/qrtoken/generate/", R(status: 200, json: #"{"qrtoken":"q"}"#))
        run.respond("/api/qrtoken/status/", R(status: 200, json: #"{"web_login_uuid":"u"}"#))
        run.respond("/api/web-login/complete/", R(status: 200, json: #"{"access_token":"secret-access","refresh_token":"secret-refresh"}"#))
        let result = run.run(credentials: ["username": "user@example.invalid", "password": "pw-SECRET"])
        let state = result.state ?? ""
        #expect(state == #"{"done":true}"#)
        for secret in ["123456", "secret-access", "secret-refresh", "pw-SECRET", "user@example.invalid"] {
            #expect(!state.contains(secret))
        }
        let requests = run.eval("JSON.stringify(log.requests)")?.toString() ?? ""
        #expect(!requests.contains("pw-SECRET"))
        #expect(!requests.contains("user@example.invalid"))
        #expect(run.eval("log.console.length")?.toInt32() == 0)
        #expect(!run.statuses.joined().contains("123456"))
    }
}
