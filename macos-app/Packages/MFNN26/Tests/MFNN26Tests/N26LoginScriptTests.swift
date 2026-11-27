import Foundation
import JavaScriptCore
import Testing
@testable import MFNN26

/// Runs `N26LoginScript.source` in JavaScriptCore against a stubbed login page (selectors and IDs from the
/// server-rendered `app.n26.com/login` and the login bundle), a fake clock and a recording `mfn` bridge.
private final class LoginPage {
    struct Outcome {
        var state: [String: Any]?
        var error: String?
        var statuses: [String]
        var clicks: [String]
        var events: [String]
        var values: [String: String]
        var storage: [String: String]
        var codePrompts: [String]
        var elapsedMilliseconds: Double
    }

    /// JS run when the login button is clicked (`page` is the stub page object).
    var onLogin = ""
    var hasForm = true
    var pushPollButton = false
    var errors: [String: String] = [:]
    /// `sessionStorage` entries present before the run (a previous run on this tab wrote them).
    var storage: [String: String] = [:]

    private static let environment = #"""
        var clock = 0;
        Date.now = function () { return clock; };
        function setTimeout(fn, ms) { clock += (ms || 0); Promise.resolve().then(fn); return 0; }
        class URL { constructor(u) { const m = /^https?:\/\/([^\/?#]+)(\/[^?#]*)?/.exec(String(u)); if (!m) throw new TypeError("url"); this.host = m[1]; this.pathname = m[2] || "/"; } }
        var storage = {};
        var window = { sessionStorage: { getItem: function (k) { return k in storage ? storage[k] : null; }, setItem: function (k, v) { storage[k] = String(v); } } };
        var record = { statuses: [], clicks: [], events: [], codes: [] };
        var mfn = {
          status: function (text) { record.statuses.push(String(text)); },
          requestCode: function (prompt, length) { record.codes.push(String(prompt) + "/" + length); return Promise.resolve("123456"); }
        };
        class Event { constructor(type, init) { this.type = type; this.bubbles = !!(init && init.bubbles); } }
        class HTMLInputElement {
          constructor(name) { this.name = name; this._value = ""; }
          get value() { return this._value; }
          set value(v) { this._value = String(v); }
          dispatchEvent(event) { record.events.push(this.name + ":" + event.type + (event.bubbles ? "" : ":nobubble")); return true; }
        }
        class Button { constructor(id, action) { this.id = id; this.action = action; } click() { record.clicks.push(this.id); if (this.action) this.action(); } }
        var page = { form: true, pushPoll: false, codeInput: null, errors: {}, onLogin: null };
        var inputs = { username: new HTMLInputElement("username"), password: new HTMLInputElement("password") };
        var loginButton = new Button("login", function () { if (page.onLogin) page.onLogin(); });
        var pollButton = new Button("poll", null);
        var document = {
          querySelector: function (selector) {
            if (page.codeInput && selector === 'input[autocomplete="one-time-code"]') return page.codeInput;
            if (selector === 'button[data-testid="verify-login-push-poll-button"]') return page.pushPoll ? pollButton : null;
            if (!page.form) return null;
            if (selector === 'input[name="username"]') return inputs.username;
            if (selector === 'input[name="password"]') return inputs.password;
            if (selector === 'button[data-testid="login-button"]') return loginButton;
            return null;
          },
          getElementById: function (id) { return id in page.errors ? { textContent: page.errors[id] } : null; }
        };
        """#

    func run(credentials: [String: String]? = ["username": "user@example.invalid", "password": "geheim-123"],
             state: [String: Any]? = nil,
             url: String = "https://app.n26.com/login") throws -> Outcome {
        let context = try #require(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(Self.environment)
        context.evaluateScript("page.form = \(hasForm); page.pushPoll = \(pushPollButton); page.errors = \(json(errors)); page.onLogin = function () { \(onLogin) }; storage = \(json(storage));")
        let call = """
            var outcome = { done: false };
            (async function (credentials, state, url) {
            \(N26LoginScript.source)
            })(\(credentials.map(json) ?? "null"), \(state.map(json) ?? "null"), \(json(url)))
              .then(function (value) { outcome = { done: true, state: JSON.stringify(value) }; },
                    function (error) { outcome = { done: true, error: String(error && error.message) }; });
            """
        context.evaluateScript(call)
        #expect(exception == nil, "JS: \(exception ?? "")")
        let done = context.evaluateScript("outcome.done")?.toBool() ?? false
        #expect(done, "Skript hat nicht beendet")
        let stateJSON = context.evaluateScript("outcome.state")?.toString()
        let decodedState = stateJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let error = context.evaluateScript("outcome.error")
        func strings(_ expression: String) -> [String] { context.evaluateScript(expression)?.toArray() as? [String] ?? [] }
        return Outcome(
            state: decodedState,
            error: error?.isUndefined == false ? error?.toString() : nil,
            statuses: strings("record.statuses"),
            clicks: strings("record.clicks"),
            events: strings("record.events"),
            values: ["username": context.evaluateScript("inputs.username.value")?.toString() ?? "",
                     "password": context.evaluateScript("inputs.password.value")?.toString() ?? ""],
            storage: context.evaluateScript("storage")?.toDictionary() as? [String: String] ?? [:],
            codePrompts: strings("record.codes"),
            elapsedMilliseconds: context.evaluateScript("clock")?.toDouble() ?? 0
        )
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite struct N26LoginScriptTests {
    @Test func fillsTheFormAndWaitsForThePush() throws {
        let outcome = try LoginPage().run()
        #expect(outcome.error == nil)
        #expect(outcome.values == ["username": "user@example.invalid", "password": "geheim-123"])
        #expect(outcome.events == ["username:input", "username:change", "password:input", "password:change"])
        #expect(outcome.clicks == ["login"])
        #expect(outcome.statuses.contains(N26LoginScript.confirmMessage))
        #expect(outcome.state?["phase"] as? String == "submitted")
        // Gives up before the app's 300 s timeout.
        #expect(outcome.elapsedMilliseconds < 300_000)
    }

    @Test func credentialsNeverEndUpInState() throws {
        let outcome = try LoginPage().run()
        let state = try JSONSerialization.data(withJSONObject: try #require(outcome.state))
        let text = String(decoding: state, as: UTF8.self)
        #expect(!text.contains("user@example.invalid") && !text.contains("geheim-123"))
        #expect(!outcome.statuses.joined().contains("geheim-123"))
    }

    @Test func wrongCredentialsAreAuthFailed() throws {
        let page = LoginPage()
        page.onLogin = #"page.errors["login-errors"] = "Falsche E-Mail-Adresse oder falsches Passwort.";"#
        let outcome = try page.run()
        #expect(outcome.error?.hasPrefix("authFailed") == true)
        #expect(outcome.clicks == ["login"]) // submitted once, never again
    }

    @Test func abortedAttemptIsAuthFailed() throws {
        let page = LoginPage()
        page.onLogin = #"page.errors["abort-login-attempt-errors"] = "Login abgebrochen.";"#
        #expect(try page.run().error?.hasPrefix("authFailed") == true)
    }

    @Test func emptyErrorContainerIsNoError() throws {
        let page = LoginPage()
        page.errors = ["login-errors": "", "abort-login-attempt-errors": "  "]
        #expect(try page.run().error == nil)
    }

    @Test func missingCredentialsAreAuthFailedWithoutTouchingTheForm() throws {
        let outcome = try LoginPage().run(credentials: ["username": "user@example.invalid"])
        #expect(outcome.error?.hasPrefix("authFailed") == true)
        #expect(outcome.clicks.isEmpty)
    }

    @Test func missingFormIsAFormatChangeNotAuthFailed() throws {
        let page = LoginPage()
        page.hasForm = false
        let outcome = try page.run()
        #expect(outcome.error == "N26 login form not found")
        #expect(outcome.elapsedMilliseconds >= 15_000)
    }

    @Test func reentryAfterNavigationOnlyReportsStatus() throws {
        let outcome = try LoginPage().run(state: ["phase": "submitted"], url: "https://app.n26.com/feed")
        #expect(outcome.error == nil)
        #expect(outcome.clicks.isEmpty && outcome.values["password"] == "")
        #expect(outcome.statuses == [N26LoginScript.confirmMessage])
        #expect(outcome.state?["phase"] as? String == "submitted")
    }

    @Test func reentryOnFormWithErrorIsAuthFailed() throws {
        let page = LoginPage()
        page.errors = ["login-errors": "Falsches Passwort"]
        let outcome = try page.run(state: ["phase": "submitted"])
        #expect(outcome.error?.hasPrefix("authFailed") == true)
        #expect(outcome.clicks.isEmpty)
    }

    @Test func formShownAgainIsNeverSubmittedTwice() throws {
        let outcome = try LoginPage().run(state: ["phase": "submitted"])
        #expect(outcome.error == "N26 login form shown again")
        #expect(outcome.clicks.isEmpty && outcome.values["password"] == "")
    }

    @Test func submitMarkerIsWrittenBeforeTheClick() throws {
        let page = LoginPage()
        page.onLogin = #"if (storage["mfn.n26.submitted"] !== "1") throw new Error("marker missing at click");"#
        let outcome = try page.run()
        #expect(outcome.error == nil)
        #expect(outcome.storage == [N26LoginScript.submittedMarker: "1"])
    }

    /// The click loaded a new page, so `HeadlessLogin` dropped the run's state: the marker still stops a resubmit.
    @Test func reloadAfterSubmitNeverSubmitsAgain() throws {
        let page = LoginPage()
        page.storage = [N26LoginScript.submittedMarker: "1"]
        let outcome = try page.run(state: nil)
        // No error panel: not a credential error, but the login stops.
        #expect(outcome.error == "N26 login form shown again")
        #expect(outcome.clicks.isEmpty && outcome.values == ["username": "", "password": ""])
    }

    @Test func reloadAfterSubmitWithErrorIsAuthFailed() throws {
        let page = LoginPage()
        page.storage = [N26LoginScript.submittedMarker: "1"]
        page.errors = ["login-errors": "Falsches Passwort"]
        let outcome = try page.run(state: nil)
        #expect(outcome.error == "authFailed: login rejected")
        #expect(outcome.clicks.isEmpty)
    }

    @Test func foreignHostIsNeverFilled() throws {
        let outcome = try LoginPage().run(url: "https://app.n26.com.example.invalid/login")
        #expect(outcome.error == "N26 login page on unexpected host")
        #expect(outcome.error?.hasPrefix("authFailed") == false)
        #expect(outcome.clicks.isEmpty && outcome.values == ["username": "", "password": ""])
        #expect(outcome.events.isEmpty)
    }

    @Test func pushPollFallbackIsThrottled() throws {
        let page = LoginPage()
        page.onLogin = "page.pushPoll = true;"
        let outcome = try page.run()
        let polls = outcome.clicks.filter { $0 == "poll" }.count
        #expect(polls >= 20 && polls <= 30) // every 10 s within ~290 s, below the bank's limit of 60
    }

    @Test func smsCodeIsAskedOnce() throws {
        let page = LoginPage()
        page.onLogin = #"page.codeInput = new HTMLInputElement("otp");"#
        let outcome = try page.run()
        #expect(outcome.codePrompts == ["\(N26LoginScript.smsCodePrompt)/6"])
        #expect(outcome.clicks == ["login", "login"]) // credentials, then the code
        #expect(outcome.state?["codeSent"] as? Bool == true)
    }
}
