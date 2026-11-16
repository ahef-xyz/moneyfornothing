import Foundation
import JavaScriptCore
import MFNCore
import Testing
@testable import MFNEasybank

// Runs `EasybankLoginScript` in JavaScriptCore against a stubbed DOM (element ids from the public
// login bundle) and a stubbed `mfn` bridge. No web view, no network, never a real bank.

private enum LoginHarness {
    static let username = "TESTUSER-SECRET-7781"
    static let password = "TESTPASS-SECRET-9934"
    static let code = "482913"

    struct Outcome {
        var result: [String: Any]?
        var resultJSON: String?
        var error: String?
        var statuses: [String]
        var codePrompts: [[Any]]
        var clicks: [String]
        var events: [String]
        var values: [String: String]
        var storage: [String: String]
    }

    /// Fake DOM: `registry[selector]` holds elements; `getClientRects` follows `shown`.
    /// `setTimeout` advances `ticks` and runs the callback as a microtask.
    static let prelude = """
    var calls = { statuses: [], codePrompts: [], clicks: [], events: [] };
    var registry = {};
    var ticks = 0;
    var onTick = null;
    var codeAnswer = "\(code)";
    function add(selector, el) { (registry[selector] = registry[selector] || []).push(el); return el; }
    function FakeElement(name) { this.name = name; this.shown = true; this.textContent = ""; }
    FakeElement.prototype.getClientRects = function () { return this.shown ? [{}] : []; };
    FakeElement.prototype.getBoundingClientRect = function () {
      return this.zeroSize ? { width: 0, height: 0 } : { width: 100, height: 20 };
    };
    FakeElement.prototype.dispatchEvent = function (e) {
      calls.events.push(this.name + ":" + e.type + (e.key ? ":" + e.key : ""));
      return true;
    };
    FakeElement.prototype.focus = function () {};
    FakeElement.prototype.click = function () { calls.clicks.push(this.name); if (this.onClick) { this.onClick(); } };
    function HTMLInputElement(name) { FakeElement.call(this, name); this._value = ""; this.maxLength = -1; }
    HTMLInputElement.prototype = Object.create(FakeElement.prototype);
    Object.defineProperty(HTMLInputElement.prototype, "value", {
      get: function () { return this._value; },
      set: function (v) { this._value = v; },
      configurable: true,
    });
    function Event(type, options) { this.type = type; }
    function KeyboardEvent(type, options) { this.type = type; this.key = options && options.key; }
    var document = { querySelectorAll: function (selector) { return (registry[selector] || []).slice(); } };
    function setTimeout(fn, ms) { ticks += 1; if (onTick) { onTick(ticks); } Promise.resolve().then(fn); }
    var mfn = {
      status: function (text) { calls.statuses.push(String(text)); },
      requestCode: function (prompt, length) {
        calls.codePrompts.push([prompt, length]);
        return codeAnswer === null ? Promise.reject("cancelled") : Promise.resolve(codeAnswer);
      },
    };
    function loginPage() {
      var page = {
        user: add("input#UserName", new HTMLInputElement("username")),
        pass: add("input#Password", new HTMLInputElement("password")),
        submit: add("#FirstLevelButtonGroup #NextButton button", new FakeElement("login")),
        error: add("vc-result-panel .alert-danger", new FakeElement("error")),
      };
      page.error.shown = false;
      page.hide = function () { page.user.shown = false; page.pass.shown = false; page.submit.shown = false; };
      return page;
    }
    var page = null;
    function URL(u) {
      var m = /^https?:\\/\\/([^\\/?#]+)(\\/[^?#]*)?/.exec(String(u));
      if (!m) { throw new TypeError("url"); }
      this.host = m[1]; this.pathname = m[2] || "/";
    }
    var storage = {};
    var window = { sessionStorage: {
      getItem: function (k) { return k in storage ? storage[k] : null; },
      setItem: function (k, v) { storage[k] = String(v); },
    } };
    """

    /// Runs the script once (one page load) after `setup` built the page.
    static func run(
        setup: String,
        state: String = "null",
        url: String = "https://banking.easybank.de/Login",
        credentials: [String: String] = ["username": username, "password": password]
    ) throws -> Outcome {
        let context = try #require(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(prelude)
        context.evaluateScript(setup)
        context.setObject(credentials, forKeyedSubscript: "testCredentials" as NSString)
        context.setObject(url, forKeyedSubscript: "testURL" as NSString)
        context.evaluateScript("""
        var out = { done: false };
        (async function (credentials, state, url) {
        \(EasybankLoginScript.source)
        })(testCredentials, \(state), testURL).then(
          function (r) { out = { done: true, result: JSON.stringify(r) }; },
          function (e) { out = { done: true, error: String(e && e.message !== undefined ? e.message : e) }; }
        );
        """)
        #expect(exception == nil, "JS exception: \(exception ?? "")")
        let out = try #require(context.objectForKeyedSubscript("out"))
        #expect(out.objectForKeyedSubscript("done").toBool(), "script did not finish")
        let resultJSON = out.objectForKeyedSubscript("result").isString ? out.objectForKeyedSubscript("result").toString() : nil
        let result = resultJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let error = out.objectForKeyedSubscript("error").isString ? out.objectForKeyedSubscript("error").toString() : nil
        let calls = try #require(context.objectForKeyedSubscript("calls"))
        let values = context.evaluateScript("""
        (function () { var v = {}; for (var k in registry) { registry[k].forEach(function (el) {
          if (el._value !== undefined) { v[el.name] = el._value; } }); } return v; })()
        """)?.toDictionary() as? [String: String] ?? [:]
        return Outcome(
            result: result,
            resultJSON: resultJSON,
            error: error,
            statuses: calls.objectForKeyedSubscript("statuses").toArray() as? [String] ?? [],
            codePrompts: calls.objectForKeyedSubscript("codePrompts").toArray() as? [[Any]] ?? [],
            clicks: calls.objectForKeyedSubscript("clicks").toArray() as? [String] ?? [],
            events: calls.objectForKeyedSubscript("events").toArray() as? [String] ?? [],
            values: values,
            storage: context.evaluateScript("storage")?.toDictionary() as? [String: String] ?? [:]
        )
    }
}

@Suite("easybank headless login script")
struct LoginScriptTests {
    @Test func loginRequestCarriesAutomation() throws {
        let request = try #require(EasybankEndpoints.loginRequest())
        let automation = try #require(request.automation)
        #expect(automation.script == EasybankLoginScript.source)
        #expect(automation.timeout == 300)
        #expect(request.url.host() == "banking.easybank.de")
        #expect(request.completion == .cookiesPresent(["FedAuth", EasybankEndpoints.uniqueKeyName]))
        #expect(!request.storageKeys.isEmpty)
        #expect(!automation.script.contains("console."))
        #expect(!automation.script.contains("fetch("))
        #expect(!automation.script.contains("XMLHttpRequest"))
    }

    @Test func fillsFormSubmitsAndAsksForAppApproval() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.submit.onClick = function () { page.hide(); };
        """)
        #expect(outcome.error == nil)
        #expect(outcome.values["username"] == LoginHarness.username)
        #expect(outcome.values["password"] == LoginHarness.password)
        #expect(outcome.events.contains("username:input") && outcome.events.contains("username:change"))
        #expect(outcome.events.contains("password:input") && outcome.events.contains("password:change"))
        #expect(outcome.clicks == ["login"])
        #expect(outcome.statuses == [EasybankLoginScript.approvalMessage])
        #expect(outcome.codePrompts.isEmpty)
        #expect(outcome.result?["submitted"] as? Int == 1)
        #expect(outcome.result?["loads"] as? Int == 1)
        let json = try #require(outcome.resultJSON)
        #expect(!json.contains(LoginHarness.username) && !json.contains(LoginHarness.password))
    }

    @Test func waitsForTheFormToAppear() throws {
        let outcome = try LoginHarness.run(setup: """
        onTick = function (t) { if (t === 4) { page = loginPage(); page.submit.onClick = function () { page.hide(); }; } };
        """)
        #expect(outcome.error == nil)
        #expect(outcome.clicks == ["login"])
    }

    @Test func wrongPasswordIsAuthFailed() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.submit.onClick = function () {
          page.error.shown = true;
          page.error.textContent = "Benutzername oder Passwort ist falsch.";
        };
        """)
        #expect(outcome.error?.hasPrefix("authFailed") == true)
        #expect(outcome.clicks == ["login"], "never submits twice")
        #expect(!(outcome.error ?? "").contains(LoginHarness.password))
    }

    @Test func emptyErrorPanelIsNotAFailure() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.error.shown = true;
        page.submit.onClick = function () { page.hide(); };
        """)
        #expect(outcome.error == nil)
    }

    @Test func smsCodeIsRequestedAndSubmitted() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.submit.onClick = function () {
          page.hide();
          var otp = add("input#OTPPassword", new HTMLInputElement("otp"));
          otp.maxLength = 6;
          var next = add("#SMSButtonGroup #NextButton button", new FakeElement("sms"));
          next.onClick = function () { otp.shown = false; next.shown = false; };
        };
        """)
        #expect(outcome.error == nil)
        #expect(outcome.codePrompts.count == 1)
        #expect(outcome.codePrompts.first?.last as? Int == 6)
        #expect(outcome.values["otp"] == LoginHarness.code)
        #expect(outcome.clicks == ["login", "sms"])
        #expect(outcome.result?["otpSubmitted"] as? Int == 1)
        #expect(!(outcome.resultJSON ?? "").contains(LoginHarness.code))
    }

    /// Live 2026-11-10: the code went into a field Angular had replaced while the user typed.
    @Test func codeGoesIntoTheFieldPresentAfterTheUserAnswered() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.submit.onClick = function () {
          page.hide();
          var first = add("input#OTPPassword", new HTMLInputElement("otp-old"));
          var next = add("#SMSButtonGroup #NextButton button", new FakeElement("sms"));
          var fresh = null;
          var answer = mfn.requestCode;
          mfn.requestCode = function (p, l) {
            first.shown = false;
            fresh = add("input#OTPPassword", new HTMLInputElement("otp"));
            return answer(p, l);
          };
          next.onClick = function () { if (fresh) { fresh.shown = false; } next.shown = false; };
        };
        """)
        #expect(outcome.error == nil)
        #expect(outcome.values["otp"] == LoginHarness.code)
        #expect(outcome.values["otp-old"] != LoginHarness.code)
        #expect(outcome.events.contains("otp:keyup:\(LoginHarness.code.last!)"))
        #expect(outcome.events.contains("otp:blur"))
    }

    @Test func wrongSMSCodeIsAuthFailed() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.submit.onClick = function () {
          page.hide();
          add("input#OTPPassword", new HTMLInputElement("otp"));
          add("#SMSButtonGroup #NextButton button", new FakeElement("sms")).onClick = function () {
            page.error.shown = true;
            page.error.textContent = "Die mTAN ist falsch.";
          };
        };
        """)
        #expect(outcome.error?.hasPrefix("authFailed") == true)
        #expect(outcome.error?.hasSuffix("Die mTAN ist falsch.") == true, "page wording goes into the reason")
        #expect(outcome.codePrompts.count == 1, "never asks twice in one login")
    }

    /// Live 2026-11-10: an error panel already on the page when the SMS step appears was taken as
    /// "code rejected" right after the submit.
    @Test func staleErrorPanelIsNotARejectedCode() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.submit.onClick = function () {
          page.hide();
          page.error.shown = true;
          page.error.textContent = "Bitte geben Sie die mTAN ein.";
          var otp = add("input#OTPPassword", new HTMLInputElement("otp"));
          var next = add("#SMSButtonGroup #NextButton button", new FakeElement("sms"));
          next.onClick = function () {
            onTick = function (tick) { if (tick > 20) { otp.shown = false; next.shown = false; page.error.shown = false; } };
          };
        };
        """)
        #expect(outcome.error == nil)
        #expect(outcome.clicks == ["login", "sms"])
    }

    @Test func transientErrorRightAfterSubmitIsIgnored() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.submit.onClick = function () {
          page.hide();
          var otp = add("input#OTPPassword", new HTMLInputElement("otp"));
          var next = add("#SMSButtonGroup #NextButton button", new FakeElement("sms"));
          next.onClick = function () {
            page.error.shown = true;
            page.error.textContent = "Bitte warten";
            var start = ticks;
            onTick = function (tick) {
              if (tick === start + 1) { page.error.shown = false; }
              if (tick > start + 10) { otp.shown = false; next.shown = false; }
            };
          };
        };
        """)
        #expect(outcome.error == nil)
    }

    @Test func noAnswerToTheCodeIsNotAuthFailed() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.submit.onClick = function () {
          page.hide();
          add("input#OTPPassword", new HTMLInputElement("otp"));
          add("#SMSButtonGroup #NextButton button", new FakeElement("sms"));
        };
        """)
        #expect(outcome.error?.contains("no answer to the SMS code") == true)
        #expect(outcome.error?.hasPrefix("authFailed") == false)
    }

    @Test func cancelledCodeEndsTheScriptWithoutAuthFailed() throws {
        let outcome = try LoginHarness.run(setup: """
        codeAnswer = null;
        add("input#OTPPassword", new HTMLInputElement("otp"));
        """, state: #"{"loads":1,"submitted":1}"#)
        #expect(outcome.error == "cancelled")
    }

    @Test func reentryAfterSubmitDoesNotSubmitAgain() throws {
        let outcome = try LoginHarness.run(setup: "page = loginPage();", state: #"{"loads":1,"submitted":1}"#)
        #expect(outcome.error == "easybank login: login form shown again")
        #expect(outcome.clicks.isEmpty)
        #expect(outcome.values["password"] == "")
    }

    @Test func submitMarkerIsWrittenBeforeTheClick() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.submit.onClick = function () {
          if (storage["\(EasybankLoginScript.submittedMarker)"] !== "1") { throw new Error("marker missing at click"); }
          page.hide();
        };
        """)
        #expect(outcome.error == nil)
        #expect(outcome.storage == [EasybankLoginScript.submittedMarker: "1"])
    }

    /// A page load after the click dropped the run's state: the marker still stops a resubmit.
    @Test func reloadAfterSubmitNeverSubmitsAgain() throws {
        let outcome = try LoginHarness.run(setup: """
        storage["\(EasybankLoginScript.submittedMarker)"] = "1";
        page = loginPage();
        """)
        #expect(outcome.error == "easybank login: login form shown again")
        #expect(outcome.clicks.isEmpty)
        #expect(outcome.values["username"] == "" && outcome.values["password"] == "")
        #expect(outcome.events.isEmpty)
    }

    @Test func errorPanelOnFirstSightAfterReloadIsAuthFailed() throws {
        let outcome = try LoginHarness.run(setup: """
        storage["\(EasybankLoginScript.submittedMarker)"] = "1";
        page = loginPage();
        page.error.shown = true;
        page.error.textContent = "Benutzername oder Passwort ist falsch.";
        """)
        #expect(outcome.error?.hasPrefix("authFailed: easybank rejected") == true)
        #expect(outcome.clicks.isEmpty)
    }

    @Test func emptyCredentialsAreAuthFailedWithoutSubmitting() throws {
        for credentials in [["username": "", "password": LoginHarness.password], ["username": LoginHarness.username, "password": ""], [:]] {
            let outcome = try LoginHarness.run(setup: "page = loginPage();", credentials: credentials)
            #expect(outcome.error == "authFailed: credentials missing")
            #expect(outcome.clicks.isEmpty && outcome.events.isEmpty)
            #expect(outcome.storage.isEmpty)
        }
    }

    @Test func foreignHostIsNeverFilled() throws {
        let outcome = try LoginHarness.run(setup: "page = loginPage();", url: "https://banking.easybank.de.example.invalid/Login")
        #expect(outcome.error == "easybank login page on unexpected host")
        #expect(outcome.clicks.isEmpty && outcome.events.isEmpty)
        #expect(outcome.values["password"] == "")
    }

    @Test func reentryAfterSubmitWithoutFormKeepsWaiting() throws {
        let outcome = try LoginHarness.run(setup: "", state: #"{"loads":1,"submitted":1}"#)
        #expect(outcome.error == nil)
        #expect(outcome.clicks.isEmpty)
        #expect(outcome.statuses == [EasybankLoginScript.approvalMessage])
        #expect(outcome.result?["loads"] as? Int == 2)
        #expect(outcome.result?["submitted"] as? Int == 1)
    }

    @Test func missingFormIsFormatChangedNotAuthFailed() throws {
        let outcome = try LoginHarness.run(setup: "")
        #expect(outcome.error?.contains("login form not found") == true)
        #expect(outcome.error?.hasPrefix("authFailed") == false)
    }

    @Test func captchaStopsWithoutAuthFailed() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        add("#Captcha", new FakeElement("captcha"));
        add("#Captcha input", new HTMLInputElement("captcha-input"));
        """)
        #expect(outcome.error != nil)
        #expect(outcome.error?.hasPrefix("authFailed") == false)
        #expect(outcome.clicks.isEmpty)
    }

    /// Live 2026-11-10: the page carries an empty captcha host; the script stopped before submitting.
    @Test func emptyCaptchaHostDoesNotStopTheLogin() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        var host = add("vc-captcha-generator", new FakeElement("captcha-host"));
        host.zeroSize = true;
        add("#Captcha", new FakeElement("captcha-wrapper"));
        """)
        #expect(outcome.error?.hasPrefix("authFailed") != true)
        #expect(outcome.clicks == ["login"])
    }

    @Test func zeroSizeElementsDoNotCount() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        var hiddenError = page.error;
        page.submit.onClick = function () { hiddenError.shown = true; hiddenError.zeroSize = true; hiddenError.textContent = "x"; };
        """)
        #expect(outcome.error?.hasPrefix("authFailed") != true)
    }

    @Test func passwordChangeStepIsNotHandled() throws {
        let outcome = try LoginHarness.run(setup: """
        page = loginPage();
        page.submit.onClick = function () { page.hide(); add("#passwordChange-form", new FakeElement("pwchange")); };
        """)
        #expect(outcome.error != nil)
        #expect(outcome.error?.hasPrefix("authFailed") == false)
    }

    @Test func fallsBackToEnterWithoutButton() throws {
        let outcome = try LoginHarness.run(setup: """
        add("input#Password", new HTMLInputElement("password"));
        """)
        // No button and the form stays: one submit via Enter, then waits (no second submit).
        #expect(outcome.error == nil)
        #expect(outcome.events.contains("password:keydown:Enter"))
        #expect(outcome.events.filter { $0 == "password:keydown:Enter" }.count == 1)
    }
}
