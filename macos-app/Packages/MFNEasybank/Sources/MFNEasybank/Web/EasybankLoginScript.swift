import Foundation
import MFNCore

/// Headless login for `banking.easybank.de` (protocol v4, `WebLoginAutomation`).
///
/// Form, not `fetch`: the login page (Angular, `LoginTransactionModule` in the public bundle
/// `86.*.js`) encrypts the password in the browser (`vbmService.encrypt`) before it posts
/// `LoginTransaction` → `logintransaction/firstlevel/next`. That encryption lives in obfuscated
/// code, so the script fills the visible form and lets the page do the requests.
///
/// Page elements (from the public bundle, 2026-11-10):
/// - Step `FirstLevel`: `vc-text-box#UserName` / `vc-text-box#Password` (inner `<input>` bound
///   with `ngModel`), button group `#FirstLevelButtonGroup` with `vc-button#NextButton`
///   (`#NextButtonMobile` on small screens). Errors in `vc-result-panel .alert-danger`.
///   `#Captcha` appears after repeated failures.
/// - Step `OtpSecurity` (SMS mTAN): `vc-text-box#OTPPassword` (`autocomplete="one-time-code"`),
///   button group `#SMSButtonGroup`.
/// - Steps the script does not handle (would need the user): password change
///   (`#passwordChange-form`), username change (`#usernameChange-form`), app PIN
///   (`.set-passcode__form`), device pairing (`.device-pairing__form`).
///
/// The page is a single-page app: after submitting, the approval in the easybank app and the
/// switch to the dashboard happen without a main-frame load, so one run of the script keeps
/// polling until the app sees `completion` and closes the web view (or until `maxPolls`).
///
/// `state` (never contains credentials): `loads` (runs so far), `submitted` (load number of the
/// form submit), `otpSubmitted` (load number of the OTP submit).
///
/// The run returns its state only at the end, and `HeadlessLogin` drops the result of a run whose
/// page navigated. So the submit is also remembered in the page's `sessionStorage`
/// (`mfn.easybank.submitted`, written before the click, never credentials). A login form seen
/// after a submit of an earlier run (state or marker) ends the login with `authFailed`, with or
/// without an error panel: the form is never filled twice (lockout risk). The script only fills
/// pages on `banking.easybank.de`; another host before the submit is a format error.
enum EasybankLoginScript {
    static let approvalMessage = "Anmeldedaten gesendet, easybank schickt gleich einen SMS-Code …"
    /// `sessionStorage` key remembering the submit across page loads (value `"1"`).
    static let submittedMarker = "mfn.easybank.submitted"
    /// The only host the script fills the form on (`EasybankEndpoints.host`).
    static let loginHost = EasybankEndpoints.host

    /// Poll interval and number of polls per run (≈ 4.7 min, just under the automation timeout).
    static let pollMilliseconds = 500
    static let maxPolls = 560

    static var automation: WebLoginAutomation {
        WebLoginAutomation(
            script: source,
            message: "Anmeldung bei easybank …",
            timeout: 300
        )
    }

    // UNVERIFIED: selectors and step markers come from the public JS bundle, not from a live
    // login. Unknown: whether the app approval shows its own page element, the mTAN length, and
    // whether the error panel distinguishes a wrong password from other errors (every error
    // right after the submit is treated as `authFailed`, which never retries).
    static let source = """
    const POLL_MS = \(pollMilliseconds);
    const MAX_POLLS = \(maxPolls);
    const APPROVAL = \(jsString(approvalMessage));
    const MARKER = \(jsString(submittedMarker));
    const LOGIN_HOST = \(jsString(loginHost));
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const readMarker = () => { try { return window.sessionStorage.getItem(MARKER) === "1"; } catch (error) { return false; } };
    const writeMarker = () => { try { window.sessionStorage.setItem(MARKER, "1"); } catch (error) {} };

    const previous = (state && typeof state === "object") ? state : {};
    const st = {
      loads: (Number(previous.loads) || 0) + 1,
      submitted: previous.submitted || 0,
      otpSubmitted: previous.otpSubmitted || 0,
    };
    // Submitted in an earlier run (its state may have been lost with a page load).
    const submittedBefore = Boolean(st.submitted) || readMarker();
    const submitted = () => Boolean(st.submitted) || submittedBefore;

    let host = "";
    try { host = String(new URL(url).host || "").toLowerCase(); } catch (error) { host = ""; }
    if (host !== LOGIN_HOST) {
      // Never touch a page on another host (no credentials outside banking.easybank.de).
      if (submittedBefore) { return st; }
      throw new Error("easybank login page on unexpected host");
    }

    // Visible = laid out with a real size. Angular renders empty custom elements (e.g. an
    // unused `vc-captcha-generator`) that have a client rect but no width or height.
    const visible = (el) => {
      if (!el || el.getClientRects().length === 0) { return false; }
      if (typeof el.getBoundingClientRect !== "function") { return true; }
      const rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const firstVisible = (selectors) => {
      for (const selector of selectors) {
        for (const el of document.querySelectorAll(selector)) {
          if (visible(el)) { return el; }
        }
      }
      return null;
    };
    const input = (id) => firstVisible([
      "input#" + id, "#" + id + " input", "input[name='" + id + "']",
    ]);
    const button = (group) => firstVisible([
      "#" + group + " #NextButton button", "#" + group + " button#NextButton",
      "#" + group + " #NextButtonMobile button", "#" + group + " button#NextButtonMobile",
      "#" + group + " #NextButton", "#" + group + " button",
    ]);
    const setValue = (el, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
      if (el.focus) { el.focus(); }
      setter.call(el, value);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    };
    // Like typing: some fields (the mTAN box) only take a value with key events and a blur.
    const typeValue = (el, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
      if (el.focus) { el.focus(); }
      setter.call(el, "");
      el.dispatchEvent(new Event("input", { bubbles: true }));
      let typed = "";
      for (const ch of value) {
        el.dispatchEvent(new KeyboardEvent("keydown", { key: ch, bubbles: true }));
        typed += ch;
        setter.call(el, typed);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new KeyboardEvent("keyup", { key: ch, bubbles: true }));
      }
      el.dispatchEvent(new Event("change", { bubbles: true }));
      el.dispatchEvent(new Event("blur", { bubbles: false }));
      el.dispatchEvent(new Event("focusout", { bubbles: true }));
    };
    const pressEnter = (el) => {
      for (const type of ["keydown", "keyup"]) {
        el.dispatchEvent(new KeyboardEvent(type, { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true }));
      }
    };
    const errorText = () => {
      const el = firstVisible(["vc-result-panel .alert-danger", ".result-panel .alert-danger"]);
      return el ? (el.textContent || "").replace(/\\s+/g, " ").trim() : "";
    };
    // Page wording for the log: letters and basic punctuation only (no digits, so no codes,
    // amounts or phone numbers), at most 70 characters.
    const wording = (text) => text.replace(/[^A-Za-zÄÖÜäöüß .,]/g, " ").replace(/\\s+/g, " ").trim().slice(0, 70);
    // A rejection is an error that is new or changed since the submit and still there after
    // SETTLE_POLLS polls (the page may show an old panel or a transient one while it works).
    const SETTLE_POLLS = 3;
    const OTP_ANSWER_POLLS = 60;
    const rejected = (baseline, pollsSinceSubmit) => {
      const text = errorText();
      return text.length > 0 && text !== baseline && pollsSinceSubmit >= SETTLE_POLLS ? text : null;
    };
    let loginBaseline = null;
    let loginPolls = 0;
    let otpBaseline = null;
    let otpPolls = 0;
    const unsupportedStep = () => firstVisible([
      "#passwordChange-form", "#usernameChange-form", ".set-passcode__form", ".device-pairing__form",
    ]);

    let announced = false;
    for (let poll = 0; poll < MAX_POLLS; poll += 1) {
      if (unsupportedStep()) {
        throw new Error("easybank login: step needs the web banking (password change, app PIN or pairing)");
      }
      // A captcha only counts with something to solve in it (input or image), not the empty host.
      if (firstVisible([
        "#Captcha input", "vc-captcha-generator input",
        "#Captcha img", "vc-captcha-generator img", "#Captcha canvas", "vc-captcha-generator canvas",
      ])) {
        throw new Error("authFailed: easybank asks for a captcha");
      }

      const otp = input("OTPPassword");
      if (otp) {
        if (st.otpSubmitted) {
          otpPolls += 1;
          const text = rejected(otpBaseline === null ? "" : otpBaseline, otpPolls);
          if (text !== null) { throw new Error("authFailed: easybank rejected the SMS code: " + wording(text)); }
          if (otpPolls >= OTP_ANSWER_POLLS) {
            throw new Error("easybank login: no answer to the SMS code: " + wording(errorText()));
          }
        } else {
          const length = Number(otp.maxLength) > 0 ? Number(otp.maxLength) : 6;
          const code = String(await mfn.requestCode("SMS-Code (mTAN) von easybank", length)).trim();
          // Live 2026-11-10: the page answered "Bitte geben Sie die mTAN ein." – the field found
          // before waiting for the user had been re-rendered. Look it up again now.
          const field = input("OTPPassword") || otp;
          typeValue(field, code);
          await sleep(300);
          if (field.value !== code) {
            throw new Error("easybank login: the SMS code field did not take the code");
          }
          otpBaseline = errorText();
          otpPolls = 0;
          st.otpSubmitted = st.loads;
          const next = button("SMSButtonGroup");
          if (next) { next.click(); } else { pressEnter(field); }
          mfn.status("Anmeldung läuft …");
        }
        await sleep(POLL_MS);
        continue;
      }

      const password = input("Password");
      if (password) {
        if (submittedBefore) {
          // The login form came back after an earlier run's submit: never submit twice (lockout risk).
          const text = errorText();
          if (text) { throw new Error("authFailed: easybank rejected username or password: " + wording(text)); }
          throw new Error("authFailed: easybank login form shown again");
        } else if (st.submitted) {
          loginPolls += 1;
          const text = rejected(loginBaseline === null ? "" : loginBaseline, loginPolls);
          if (text !== null) { throw new Error("authFailed: easybank rejected username or password: " + wording(text)); }
        } else {
          const c = (credentials && typeof credentials === "object") ? credentials : {};
          const login = String(c.username || "").trim();
          const secret = String(c.password || "");
          if (!login || !secret) { throw new Error("authFailed: credentials missing"); }
          const username = input("UserName");
          if (username) { setValue(username, login); }
          setValue(password, secret);
          loginBaseline = errorText();
          loginPolls = 0;
          st.submitted = st.loads;
          // Marker first: should the click load a new page, the next run must not fill the form again.
          writeMarker();
          mfn.status(APPROVAL);
          announced = true;
          const submit = button("FirstLevelButtonGroup");
          if (submit) { submit.click(); } else { pressEnter(password); }
        }
      } else if (submitted() && !announced) {
        mfn.status(APPROVAL);
        announced = true;
      }
      await sleep(POLL_MS);
    }
    if (!submitted()) {
      throw new Error("easybank login: login form not found");
    }
    return st;
    """

    /// JSON string literal, for constants in the script (never for credentials).
    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
