import Foundation
import JavaScriptCore
import Testing
@testable import MFNDKB

/// Runs `DKBLoginScript.source` in JavaScriptCore against a stubbed login page (selectors from the public web
/// banking bundle), a fake clock, a stubbed `sessionStorage` (Friendly Captcha token) and a recording `mfn` bridge.
private final class LoginPage {
    struct Outcome {
        var state: [String: Any]?
        var error: String?
        var statuses: [String]
        var clicks: [String]
        var events: [String]
        var values: [String: String]
        var storage: [String: String]
        var windowName: String
        /// Last value the script assigned to `document.cookie`.
        var cookie: String
        var clickClock: Double
        var elapsedMilliseconds: Double
    }

    /// JS run when the login button is clicked (`page` is the stub page object).
    var onLogin = "page.waiting = true;"
    var hasForm = true
    var hasCaptcha = true
    /// Clock (ms after the captcha started on focus) at which the captcha token appears; `nil` = never.
    var captchaSolvesAfter: Int? = 4000
    var storage: [String: String] = [:]
    var setup = ""

    private static let environment = #"""
        var clock = 0;
        Date.now = function () { return clock; };
        function setTimeout(fn, ms) { clock += (ms || 0); Promise.resolve().then(fn); return 0; }
        class URL { constructor(u) { const m = /^https?:\/\/([^\/?#]+)(\/[^?#]*)?/.exec(String(u)); if (!m) throw new TypeError("url"); this.host = m[1]; this.pathname = m[2] || "/"; } }
        var window = globalThis;
        var record = { statuses: [], clicks: [], events: [], clickClock: -1 };
        var mfn = {
          status: function (text) { record.statuses.push(String(text)); },
          requestCode: function () { return Promise.reject(new Error("unexpected")); }
        };
        class Event { constructor(type, init) { this.type = type; this.bubbles = !!(init && init.bubbles); } }
        class FocusEvent extends Event {}
        var page = { form: true, captcha: true, solvesAfter: 4000, captchaStartedAt: null, waiting: false, error: null, main: null,
                     methodForm: false, deviceForm: false, onLogin: null, path: "/login" };
        class HTMLInputElement {
          constructor(name) { this.name = name; this._value = ""; }
          get value() { return this._value; }
          set value(v) { this._value = String(v); }
          // Like the hidden window: focus() fires nothing, only a dispatched bubbling focusin starts the captcha.
          focus() { record.events.push(this.name + ":focus()"); }
          dispatchEvent(event) {
            record.events.push(this.name + ":" + event.type + (event.bubbles ? "" : ":nobubble"));
            if (event.type === "focusin" && event.bubbles && page.captchaStartedAt === null) page.captchaStartedAt = clock;
            return true;
          }
        }
        class Button {
          constructor(id, action, text, aria) { this.id = id; this.action = action; this.textContent = text || ""; this.disabled = false; this.aria = aria || null; }
          getAttribute(name) { return name === "aria-label" ? this.aria : null; }
          click() { record.clicks.push(this.id); if (this.id === "login") record.clickClock = clock; if (this.action) this.action(); }
        }
        var inputs = { username: new HTMLInputElement("username"), password: new HTMLInputElement("password") };
        var loginButton = new Button("login", function () { if (page.onLogin) page.onLogin(); }, "Anmelden");
        var appRadio = new Button("seal_one", null);
        var methodSubmit = new Button("method-submit", function () { page.methodForm = false; page.waiting = true; });
        var methodForm = { querySelector: function (s) { return s === 'button[type="submit"]' ? methodSubmit : null; } };
        var deviceButtons = [new Button("device-close", null, "", "Abbrechen"), new Button("device-confirm", function () { page.deviceForm = false; page.waiting = true; }, "Methode bestätigen")];
        var deviceForm = { querySelectorAll: function (s) { return s === "button" ? deviceButtons : []; } };
        var sessionStore = {};
        var sessionStorage = {
          getItem: function (key) {
            if (key === "friendly-captcha-login-token") {
              return page.solvesAfter !== null && page.captchaStartedAt !== null && clock - page.captchaStartedAt >= page.solvesAfter ? "captcha-token" : null;
            }
            return key in sessionStore ? sessionStore[key] : null;
          },
          setItem: function (key, value) { sessionStore[key] = String(value); }
        };
        var location = { get href() { return "https://banking.dkb.de" + page.path; } };
        // Account list probe of the script: answers like a logged-in session unless the page says otherwise.
        var fetch = function (url) { record.fetches = (record.fetches || 0) + 1; return Promise.resolve({ ok: page.loggedIn !== false }); };
        var document = {
          querySelector: function (selector) {
            if (selector === 'section[title="error"]') return page.error === null ? null : { textContent: page.error };
            if (selector === '[role="main"]') return page.main === null ? null : { textContent: page.main };
            if (selector === '[data-testid="waiting-page"]') return page.waiting ? {} : null;
            if (selector === '[data-testid="friendly-captcha"]') return page.captcha ? {} : null;
            if (selector === 'form.mfaApp-selectMfaMethod') return page.methodForm ? methodForm : null;
            if (selector === 'input[type="radio"][value="seal_one"]') return page.methodForm ? appRadio : null;
            if (selector === '.mfaApp-sealOneSelectMethods') return page.deviceForm ? deviceForm : null;
            if (!page.form) return null;
            if (selector === 'input#username') return inputs.username;
            if (selector === 'input#password') return inputs.password;
            if (selector === 'form button[type="submit"]') return loginButton;
            return null;
          }
        };
        """#

    func run(credentials: [String: String]? = ["username": "max.muster", "password": TestValues.password],
             state: [String: Any]? = nil,
             url: String = "https://banking.dkb.de/login") throws -> Outcome {
        let context = try #require(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(Self.environment)
        let solves = captchaSolvesAfter.map(String.init) ?? "null"
        context.evaluateScript("page.form = \(hasForm); page.captcha = \(hasCaptcha); page.solvesAfter = \(solves); sessionStore = \(json(storage)); page.onLogin = function () { \(onLogin) }; \(setup)")
        let call = """
            var outcome = { done: false };
            (async function (credentials, state, url) {
            \(DKBLoginScript.source)
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
            storage: context.evaluateScript("sessionStore")?.toDictionary() as? [String: String] ?? [:],
            windowName: context.evaluateScript("String(window.name || '')")?.toString() ?? "",
            cookie: context.evaluateScript("String(document.cookie || '')")?.toString() ?? "",
            clickClock: context.evaluateScript("record.clickClock")?.toDouble() ?? -1,
            elapsedMilliseconds: context.evaluateScript("clock")?.toDouble() ?? 0
        )
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite struct DKBLoginScriptTests {
    @Test func fillsTheFormWaitsForTheCaptchaAndThePush() throws {
        let outcome = try LoginPage().run()
        #expect(outcome.error == nil)
        #expect(outcome.values == ["username": "max.muster", "password": TestValues.password])
        #expect(outcome.events == ["username:focus()", "username:focus:nobubble", "username:focusin", "username:input", "username:change",
                                  "password:focus()", "password:focus:nobubble", "password:focusin", "password:input", "password:change"])
        #expect(outcome.clicks == ["login"])
        #expect(outcome.clickClock >= 4000) // not before the captcha token exists
        #expect(outcome.statuses.first == DKBLoginScript.captchaMessage)
        #expect(outcome.statuses.contains(DKBLoginScript.confirmMessage))
        #expect(outcome.state?["phase"] as? String == "submitted")
        #expect(outcome.storage[DKBLoginScript.submittedMarker] != nil)
        #expect(outcome.windowName == DKBLoginScript.submittedMarker)
        #expect(outcome.elapsedMilliseconds < 300_000) // gives up before the app's timeout
    }

    @Test func withoutCaptchaWidgetSubmitsRightAway() throws {
        let page = LoginPage()
        page.hasCaptcha = false
        let outcome = try page.run()
        #expect(outcome.clicks == ["login"])
        #expect(outcome.clickClock < 1000)
        #expect(!outcome.statuses.contains(DKBLoginScript.captchaMessage))
    }

    @Test func unsolvedCaptchaIsNeverSubmitted() throws {
        let page = LoginPage()
        page.captchaSolvesAfter = nil
        let outcome = try page.run()
        #expect(outcome.error == "DKB captcha not solved")
        #expect(outcome.clicks.isEmpty)
    }

    @Test func credentialsNeverEndUpInStateOrStatus() throws {
        let outcome = try LoginPage().run()
        let state = try JSONSerialization.data(withJSONObject: try #require(outcome.state))
        let text = String(decoding: state, as: UTF8.self)
        #expect(!text.contains("max.muster") && !text.contains(TestValues.password))
        #expect(!outcome.statuses.joined().contains(TestValues.password))
        #expect(!outcome.storage.values.joined().contains(TestValues.password))
        #expect(!DKBLoginScript.source.contains(TestValues.password))
    }

    @Test func wrongCredentialsAreAuthFailed() throws {
        let page = LoginPage()
        page.onLogin = #"page.error = "Die Anmeldung ist fehlgeschlagen. Bitte überprüfe die Anmeldedaten und versuche es erneut."; inputs.password.value = "";"#
        let outcome = try page.run()
        #expect(outcome.error == "authFailed: wrong credentials")
        #expect(outcome.clicks == ["login"]) // submitted once, never again
    }

    @Test func blockedAccessIsAuthFailed() throws {
        let page = LoginPage()
        page.onLogin = #"page.form = false; page.main = "Zugang gesperrt Dein Banking-Zugang wurde aus Sicherheitsgründen gesperrt.";"#
        #expect(try page.run().error == "authFailed: access blocked")
    }

    @Test func technicalErrorIsNotAuthFailed() throws {
        let page = LoginPage()
        page.onLogin = #"page.error = "Es gibt ein technisches Problem bei der Anmeldung. Bitte versuche es später erneut.";"#
        #expect(try page.run().error == "DKB login error")
    }

    @Test func missingCredentialsAreAuthFailedWithoutTouchingTheForm() throws {
        let outcome = try LoginPage().run(credentials: ["username": "max.muster"])
        #expect(outcome.error?.hasPrefix("authFailed") == true)
        #expect(outcome.clicks.isEmpty && outcome.events.isEmpty)
    }

    @Test func missingFormIsAFormatChangeNotAuthFailed() throws {
        let page = LoginPage()
        page.hasForm = false
        let outcome = try page.run()
        #expect(outcome.error == "DKB login form not found")
        #expect(outcome.elapsedMilliseconds >= 20_000)
    }

    @Test func reentryAfterNavigationOnlyReportsStatus() throws {
        let page = LoginPage()
        page.hasForm = false
        let outcome = try page.run(state: ["phase": "submitted"], url: "https://banking.dkb.de/")
        #expect(outcome.error == nil)
        #expect(outcome.clicks.isEmpty && outcome.values["password"] == "")
        #expect(outcome.statuses == [DKBLoginScript.doneMessage])
        #expect(outcome.cookie.hasPrefix("\(DKBEndpoints.loginDoneCookie)=1;"))
        #expect(outcome.state?["phase"] as? String == "submitted")
    }

    @Test func intermediatePageWithoutSessionSetsNoMarker() throws {
        let page = LoginPage()
        page.hasForm = false
        page.setup = "page.loggedIn = false;"
        let outcome = try page.run(state: ["phase": "submitted"], url: "https://banking.dkb.de/")
        #expect(outcome.error == nil)
        #expect(outcome.cookie.isEmpty)
        #expect(!outcome.statuses.contains(DKBLoginScript.doneMessage))
    }

    @Test func freshLoginClearsAStaleDoneMarker() throws {
        let outcome = try LoginPage().run()
        #expect(outcome.error == nil)
        #expect(outcome.cookie.hasPrefix("\(DKBEndpoints.loginDoneCookie)=;") && outcome.cookie.contains("max-age=0"))
    }

    @Test func formShownAgainIsNeverSubmittedTwice() throws {
        let outcome = try LoginPage().run(state: ["phase": "submitted"])
        #expect(outcome.error == "DKB login form shown again")
        #expect(outcome.clicks.isEmpty && outcome.values["password"] == "")
    }

    @Test func reentryOnFormWithErrorIsAuthFailed() throws {
        let page = LoginPage()
        page.setup = #"page.error = "Die Anmeldung ist fehlgeschlagen. Bitte überprüfe die Anmeldedaten und versuche es erneut.";"#
        let outcome = try page.run(state: ["phase": "submitted"], url: "https://banking.dkb.de/login")
        #expect(outcome.error == "authFailed: wrong credentials")
        #expect(outcome.clicks.isEmpty)
    }

    @Test func pageMarkerSurvivesALostState() throws {
        // A page load during the run lost the state: the marker in sessionStorage still says "submitted".
        let page = LoginPage()
        page.storage = [DKBLoginScript.submittedMarker: "1"]
        let outcome = try page.run(state: nil)
        #expect(outcome.error == "DKB login form shown again")
        #expect(outcome.clicks.isEmpty)
    }

    @Test func picksTheAppWhenAskedForAMethod() throws {
        let page = LoginPage()
        page.onLogin = "page.methodForm = true;"
        let outcome = try page.run()
        #expect(outcome.error == nil)
        #expect(outcome.clicks == ["login", "seal_one", "method-submit"])
        #expect(outcome.statuses.contains(DKBLoginScript.confirmMessage))
    }

    @Test func confirmsThePreselectedDevice() throws {
        let page = LoginPage()
        page.onLogin = "page.deviceForm = true;"
        let outcome = try page.run()
        #expect(outcome.error == nil)
        #expect(outcome.clicks == ["login", "device-confirm"])
    }

    @Test func declinedApprovalEndsWithoutSecondSubmit() throws {
        let page = LoginPage()
        page.onLogin = #"inputs.password.value = "";"# // the page resets the form, no waiting page
        let outcome = try page.run()
        #expect(outcome.error == "DKB approval not completed")
        #expect(outcome.clicks == ["login"])
    }

    @Test func timeoutPageEndsTheLogin() throws {
        let page = LoginPage()
        page.onLogin = #"page.waiting = false; page.path = "/timeout";"#
        #expect(try page.run().error == "DKB approval timed out")
    }

    @Test func foreignHostIsNeverFilled() throws {
        for url in ["https://banking.dkb.de.example.invalid/login", "https://example.invalid/login", "not a url"] {
            let outcome = try LoginPage().run(url: url)
            #expect(outcome.error == "DKB login page on unexpected host")
            #expect(outcome.error?.hasPrefix("authFailed") == false)
            #expect(outcome.clicks.isEmpty && outcome.events.isEmpty)
            #expect(outcome.values == ["username": "", "password": ""])
            #expect(outcome.storage.isEmpty && outcome.windowName != DKBLoginScript.submittedMarker)
        }
    }

    @Test func foreignHostAfterSubmitOnlyKeepsTheState() throws {
        let outcome = try LoginPage().run(state: ["phase": "submitted"], url: "https://example.invalid/")
        #expect(outcome.error == nil)
        #expect(outcome.clicks.isEmpty && outcome.values["password"] == "")
        #expect(outcome.state?["phase"] as? String == "submitted")
    }
}
