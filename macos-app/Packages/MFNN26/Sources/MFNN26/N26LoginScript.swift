import MFNScrape

/// Headless login for `app.n26.com/login` (protocol v4, `WebLoginAutomation`).
///
/// Why the form and not `fetch`: the web app encrypts every GraphQL payload (`variables.payload`, SJCL
/// ElGamal on P-384 + AES-CCM with `window.__PEK__`, see `N26PayloadCipher`). The script runs in an isolated
/// content world without the page's globals and WebCrypto offers neither AES-CCM nor the full ECDH point, so
/// the script fills the page's own login form. The app then sends `requestBiometricChallengeMutation`
/// (including the hidden `fp`/`fpc`/`requestId` fields it fills itself) and polls `verifyLoginWithPush`
/// until the user confirms in the N26 app; the last poll sets `n26.token` (completion).
///
/// Steps, idempotent across page loads (`state.phase`):
/// 1. `start`: wait for the form (selectors from the server-rendered page, with fallbacks), set e-mail and
///    password via the native value setter + `input`/`change`, click „Log in“ → `submitted`.
/// 2. `submitted`: watch the page. `#login-errors` (wrong credentials, rate limit) or
///    `#abort-login-attempt-errors` (`shouldAbortLoginAttempt`) → `authFailed`, never retried.
///    Otherwise show „Bitte in der N26-App bestätigen.“.
/// 3. Login page shown again after `submitted` without an error (push declined or expired) →
///    a non-auth error, never a second attempt: only the explicit error panels mean wrong credentials.
///
/// The submit is also remembered in the page's `sessionStorage` (`mfn.n26.submitted`, written before the
/// click): `HeadlessLogin` drops the return value of a run whose page navigated, so without the marker a full
/// page load after the click would fill and submit the form again. The run itself keeps watching after the
/// click (single page app: errors and the SMS step show without a page load). The script only touches pages
/// on `app.n26.com`; any other host before the submit is a format error.
///
/// UNVERIFIED (live test by the human):
/// - Whether the JS app polls `verifyLoginWithPush` on its own. If the „Continue“ button
///   (`verify-login-push-poll-button`, no-JS fallback form) is shown, the script clicks it every 10 s
///   (≤ 30 polls in 300 s; the HAR shows a limit of 60).
/// - SMS fallback (`challengeType` SMS, no paired device): a one-time-code input is filled via
///   `mfn.requestCode`. Selectors guessed.
/// - Error containers keep their IDs on the client-rendered page (seen only in the bundle).
enum N26LoginScript {
    static let confirmMessage = String(localized: "Bitte in der N26-App bestätigen.", bundle: .module)
    static let loginMessage = String(localized: "Anmeldung bei N26 …", bundle: .module)
    static let smsCodePrompt = String(localized: "Bestätigungscode aus der SMS von N26", bundle: .module)
    /// `sessionStorage` key remembering the submit across page loads (value `"1"`, never credentials).
    static let submittedMarker = "mfn.n26.submitted"
    /// The only host the script fills the form on (`N26Endpoints.production`).
    static let loginHost = "app.n26.com"

    static let source = #"""
        const CONFIRM = \#(JavaScriptLiteral.string(confirmMessage));
        const USER = ['input[name="username"]', 'input#email', 'input[autocomplete="email"]', 'input[type="email"]'];
        const PASS = ['input[name="password"]', 'input#password', 'input[autocomplete="current-password"]', 'input[type="password"]'];
        const SUBMIT = ['button[data-testid="login-button"]', 'form button[type="submit"]'];
        const PUSH_POLL = 'button[data-testid="verify-login-push-poll-button"]';
        const CODE = ['input[autocomplete="one-time-code"]', 'input[name="otp"]', 'input[name="mfaCode"]', 'input[name="code"]'];
        const MARKER = "\#(submittedMarker)";
        const LOGIN_HOST = "\#(loginHost)";

        const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        const find = (selectors) => {
          for (const selector of selectors) {
            const element = document.querySelector(selector);
            if (element) return element;
          }
          return null;
        };
        const waitFor = async (probe, ms) => {
          const end = Date.now() + ms;
          for (;;) {
            const value = probe();
            if (value) return value;
            if (Date.now() > end) return null;
            await sleep(250);
          }
        };
        const textOf = (id) => {
          const element = document.getElementById(id);
          return element ? String(element.textContent || "").trim() : "";
        };
        const failure = () => {
          if (textOf("abort-login-attempt-errors")) return "authFailed: login attempt aborted";
          if (textOf("login-errors")) return "authFailed: login rejected";
          return null;
        };
        const setValue = (element, value) => {
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
          setter.call(element, value);
          element.dispatchEvent(new Event("input", { bubbles: true }));
          element.dispatchEvent(new Event("change", { bubbles: true }));
        };

        // Non-secret marker: survives a page load that loses this run's return value.
        const readMarker = () => { try { return window.sessionStorage.getItem(MARKER) === "1"; } catch (error) { return false; } };
        const writeMarker = () => { try { window.sessionStorage.setItem(MARKER, "1"); } catch (error) {} };

        let host = "";
        let path = "";
        try {
          const parsed = new URL(url);
          host = String(parsed.host || "").toLowerCase();
          path = String(parsed.pathname || "");
        } catch (error) { host = ""; path = ""; }
        let current = state && typeof state === "object" ? state : { phase: "start" };
        if (current.phase !== "submitted" && readMarker()) current = { phase: "submitted" };

        if (host !== LOGIN_HOST) {
          // Never touch a page on another host (no credentials outside app.n26.com).
          if (current.phase === "submitted") return current;
          throw new Error("N26 login page on unexpected host");
        }

        if (!path.startsWith("/login")) {
          // Logged in (feed) or an intermediate page: completion is the n26.token cookie.
          if (current.phase === "submitted") mfn.status(CONFIRM);
          return current;
        }

        if (current.phase === "submitted") {
          const reason = failure();
          if (reason) throw new Error(reason);
          if (find(USER) && find(PASS) && !document.querySelector(PUSH_POLL)) {
            // The form is back without an error (push declined or expired): not a credential
            // error, but never submit the credentials a second time.
            throw new Error("N26 login form shown again");
          }
        } else {
          if (!credentials || !credentials.username || !credentials.password) {
            throw new Error("authFailed: credentials missing");
          }
          const user = await waitFor(() => find(USER), 15000);
          const pass = user && await waitFor(() => find(PASS), 5000);
          const button = pass && await waitFor(() => find(SUBMIT), 5000);
          if (!user || !pass || !button) throw new Error("N26 login form not found");
          setValue(user, credentials.username);
          setValue(pass, credentials.password);
          current = { phase: "submitted" };
          // Marker first: should the click load a new page, the next run must not fill the form again.
          writeMarker();
          mfn.status(\#(JavaScriptLiteral.string(loginMessage)));
          button.click();
        }

        // Single page app: watch until an error shows, the user confirms (navigation ends this run) or time is up.
        const started = Date.now();
        let lastPoll = Date.now();
        let confirming = false;
        while (Date.now() - started < 290000) {
          await sleep(500);
          const reason = failure();
          if (reason) throw new Error(reason);
          const code = !current.codeSent && find(CODE);
          if (code) {
            const value = await mfn.requestCode(\#(JavaScriptLiteral.string(smsCodePrompt)), 6);
            current = { phase: "submitted", codeSent: true };
            setValue(code, String(value));
            const submit = find(SUBMIT);
            if (submit) submit.click();
            continue;
          }
          if (!confirming && Date.now() - started >= 1500) {
            confirming = true;
            mfn.status(CONFIRM);
          }
          const poll = document.querySelector(PUSH_POLL);
          if (poll && Date.now() - lastPoll >= 10000) {
            lastPoll = Date.now();
            poll.click();
          }
        }
        return current;
        """#
}
