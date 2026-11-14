/// Headless login for `banking.dkb.de/login` (protocol v4, `WebLoginAutomation`).
///
/// Form, not `fetch`: the login needs a Friendly Captcha token (proof of work in the page, `eu.frcapi.com`), a
/// browser fingerprint (`/api/device-data/web-device-data`) and the MFA challenge dance. The page does all of
/// that itself, so the script only fills the visible form and waits.
///
/// Page elements (public bundle `assets/bootstrap-*.js`, web banking 2.115.0, 2026-11-10):
/// - Login form (React): `input#username` (`name="username"`, `autocomplete="username"`), `input#password`
///   (`autocomplete="current-password"`), submit button „Anmelden“ (disabled while a login runs).
/// - Friendly Captcha widget `[data-testid="friendly-captcha"]` starts on the first `focusin` at its form
///   (`startMode: "focus"`, `executeOnceOnFocusInEvent`); the hidden window never fires focus events itself, so the
///   script dispatches `focus`/`focusin`; the solved token lands in
///   `sessionStorage["friendly-captcha-login-token"]`. Submitting without it only shows a captcha hint, so the
///   script waits for the token before it clicks.
/// - Errors: `section[title="error"]` with „Die Anmeldung ist fehlgeschlagen. Bitte überprüfe die Anmeldedaten …“
///   (wrong username/password) or „… technisches Problem …“; blocked access shows „… aus Sicherheitsgründen
///   gesperrt.“
/// - Second factor: the page picks the preferred (else most recently enrolled) DKB-App device and sends the push
///   (`[data-testid="waiting-page"]`). If it asks for a method (`form.mfaApp-selectMfaMethod`, radios
///   `input[value="seal_one"]` …) the script picks the DKB app; a device list (`.mfaApp-sealOneSelectMethods`)
///   is confirmed with the preselected device. After the approval the app routes to `/` without a page load.
///   Declined/expired approvals route back to `/login` resp. `/timeout`.
///
/// `state` (never contains credentials): `phase` (`start` → `submitted`). Because a page load during a run loses
/// the run's return value, the submit is also marked in the page's `sessionStorage` (`mfn-dkb-submitted`) and
/// `window.name`; credentials are never submitted twice in one login.
///
/// The script only touches pages on `banking.dkb.de`; another host before the submit is a format error.
///
/// Cookie banner (Usercentrics): declined with its deny button if present (selectors UNVERIFIED).
///
/// UNVERIFIED (live test by the human): the submit button selector (`form button[type="submit"]`), that
/// `focus()` in the hidden web view starts the captcha, the method chooser markup, and whether a declined push
/// reloads the page or only re-renders the form.
enum DKBLoginScript {
    static let confirmMessage = "Bitte in der DKB-App bestätigen."
    static let captchaMessage = "Sicherheitsprüfung der DKB läuft …"
    static let doneMessage = "Anmeldung bei der DKB abgeschlossen …"
    static let captchaClickMessage = "Die DKB möchte eine Bestätigung: „Bankseite anzeigen“ und „Ich bin ein Mensch“ anklicken."
    static let submittedMarker = "mfn-dkb-submitted"
    /// The only host the script fills the form on (`DKBEndpoints.production`).
    static let loginHost = "banking.dkb.de"

    static let source = #"""
        const CONFIRM = "Bitte in der DKB-App bestätigen.";
        const CAPTCHA_STATUS = "Sicherheitsprüfung der DKB läuft …";
        const DONE = "Anmeldung bei der DKB abgeschlossen …";
        const CAPTCHA_CLICK = "\#(captchaClickMessage)";
        const MARKER = "mfn-dkb-submitted";
        const LOGIN_HOST = "\#(loginHost)";
        // UNVERIFIED: fallbacks after the first entry are guesses.
        const USER = ['input#username', 'input[name="username"]', 'input[autocomplete="username"]'];
        const PASS = ['input#password', 'input[name="password"]', 'input[autocomplete="current-password"]', 'input[type="password"]'];
        const SUBMIT = ['form button[type="submit"]', 'form button:not([type="button"])'];
        const CAPTCHA = '[data-testid="friendly-captcha"]';
        const CAPTCHA_TOKEN = "friendly-captcha-login-token";
        const WAITING = '[data-testid="waiting-page"]';
        const METHOD_FORM = 'form.mfaApp-selectMfaMethod';
        const APP_METHOD = ['input[type="radio"][value="seal_one"]', 'input#seal_one'];
        const DEVICE_FORM = '.mfaApp-sealOneSelectMethods';
        const OTHER_METHOD = '.mfaApp-chipTan-verify, .mfaApp-sms-verify';

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
        const textOf = (element) => element ? String(element.textContent || "").replace(/\s+/g, " ").trim() : "";
        const failure = () => {
          const error = textOf(document.querySelector('section[title="error"]'));
          if (error) {
            if (/Anmeldedaten|fehlgeschlagen|credentials|incorrect|Login failed/i.test(error)) return "authFailed: wrong credentials";
            if (/gesperrt|blocked/i.test(error)) return "authFailed: access blocked";
            return "DKB login error";
          }
          const main = textOf(document.querySelector('[role="main"]'));
          if (/aus Sicherheitsgründen gesperrt|blocked for security reasons/i.test(main)) return "authFailed: access blocked";
          return null;
        };
        // The hidden window is never key, so WebKit fires no focus events for focus(). Friendly Captcha starts on a
        // `focusin` at its form (`executeOnceOnFocusInEvent`), so the script dispatches the events itself.
        const focusEvents = (element) => {
          if (typeof element.focus === "function") element.focus();
          try {
            element.dispatchEvent(new FocusEvent("focus", { bubbles: false }));
            element.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
          } catch (error) {
            element.dispatchEvent(new Event("focusin", { bubbles: true }));
          }
        };
        const setValue = (element, value) => {
          focusEvents(element);
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
          setter.call(element, value);
          element.dispatchEvent(new Event("input", { bubbles: true }));
          element.dispatchEvent(new Event("change", { bubbles: true }));
        };
        // Cookie banner (Usercentrics, usually in a shadow root): decline, so nothing overlays the form.
        // Best effort; the choice stays in the connection's web data store.
        const DENY = ['[data-testid="uc-deny-all-button"]', 'button[data-action-type="deny"]', '#uc-btn-deny-banner'];
        const dismissConsent = () => { try { return declineConsent(); } catch (error) { return false; } };
        const declineConsent = () => {
          const roots = [document];
          for (const host of document.querySelectorAll('#usercentrics-root, #usercentrics-cmp-ui, aside[id^="usercentrics"]')) {
            if (host.shadowRoot) roots.push(host.shadowRoot);
          }
          for (const root of roots) {
            for (const selector of DENY) {
              const button = root.querySelector(selector);
              if (button) { button.click(); return true; }
            }
            for (const button of root.querySelectorAll("button")) {
              if (/^(Ablehnen|Alle ablehnen|Nur notwendige( Cookies)?( akzeptieren)?|Deny|Deny all)$/i.test(textOf(button))) { button.click(); return true; }
            }
          }
          return false;
        };
        const DONE_COOKIE = "\#(DKBEndpoints.loginDoneCookie)";
        const setDone = (on) => {
          try {
            document.cookie = on ? `${DONE_COOKIE}=1; path=/; secure; samesite=strict`
                                 : `${DONE_COOKIE}=; path=/; secure; samesite=strict; max-age=0`;
          } catch (error) {}
        };
        // Logged in = the account list answers (the same request the connector makes first). Cookies are only read
        // to send the page's own XSRF header; nothing is returned or stored.
        const loggedIn = async () => {
          try {
            const match = String(document.cookie || "").match(/(?:^|;\s*)__Host-xsrf=([^;]+)/);
            const response = await fetch("/api/accounts/accounts?filter%5Bproduct.type%5D%5BNEQ%5D=loan", {
              credentials: "include",
              headers: { "x-xsrf-token": match ? decodeURIComponent(match[1]) : "", "application-name": "web-banking", Accept: "application/json, text/plain, */*" }
            });
            return !!(response && response.ok);
          } catch (error) { return false; }
        };
        const storage = () => { try { return window.sessionStorage || null; } catch (error) { return null; } };
        const markSubmitted = () => {
          const store = storage();
          try { if (store) store.setItem(MARKER, String(Date.now())); } catch (error) {}
          try { window.name = MARKER; } catch (error) {}
        };
        const wasSubmitted = () => {
          const store = storage();
          try { if (store && store.getItem(MARKER)) return true; } catch (error) {}
          try { return window.name === MARKER; } catch (error) { return false; }
        };
        // null = storage not readable (then the script waits a fixed time instead).
        const captchaSolved = () => {
          const store = storage();
          if (!store) return null;
          try { return !!store.getItem(CAPTCHA_TOKEN); } catch (error) { return null; }
        };

        let host = "";
        let path = "";
        try {
          const parsed = new URL(url);
          host = String(parsed.host || "").toLowerCase();
          path = String(parsed.pathname || "");
        } catch (error) { host = ""; path = ""; }
        let current = state && typeof state === "object" ? state : { phase: "start" };
        if (current.phase !== "submitted" && wasSubmitted()) current = { phase: "submitted" };
        if (host !== LOGIN_HOST) {
          // Never touch a page on another host (no credentials, no API probe outside banking.dkb.de).
          if (current.phase === "submitted") return current;
          throw new Error("DKB login page on unexpected host");
        }
        const onLoginPage = path.startsWith("/login") || path.startsWith("/timeout");

        if (current.phase === "submitted") {
          if (onLoginPage) {
            const reason = failure();
            if (reason) throw new Error(reason);
            if (find(USER) && find(PASS) && !document.querySelector(WAITING)) {
              // Back at the form (approval declined or expired): never submit the credentials a second time.
              throw new Error("DKB login form shown again");
            }
          } else if (await loggedIn()) {
            // Logged in (overview): the marker cookie completes the login (DKBEndpoints.completionCookies).
            setDone(true);
            mfn.status(DONE);
            return current;
          }
          // Otherwise an intermediate page: keep watching below.
        } else {
          setDone(false);
          if (!credentials || !credentials.username || !credentials.password) {
            throw new Error("authFailed: credentials missing");
          }
          const user = await waitFor(() => find(USER), 20000);
          const pass = user && await waitFor(() => find(PASS), 5000);
          const button = pass && await waitFor(() => find(SUBMIT), 5000);
          if (!user || !pass || !button) throw new Error("DKB login form not found");
          if (dismissConsent()) await sleep(300);
          setValue(user, credentials.username); // focus starts the captcha
          setValue(pass, credentials.password);

          if (document.querySelector(CAPTCHA)) {
            mfn.status(CAPTCHA_STATUS);
            const started = Date.now();
            let refocused = false;
            let askedForClick = false;
            const solved = await waitFor(() => {
              // The banner often appears only after the form; once it is gone, start the captcha again.
              if (dismissConsent()) { setTimeout(() => focusEvents(user), 300); }
              const value = captchaSolved();
              if (!value && !askedForClick && Date.now() - started > 15000) {
                // The widget sometimes waits for a click on „Ich bin ein Mensch“ (cross-origin frame, not scriptable).
                askedForClick = true;
                mfn.status(CAPTCHA_CLICK);
              }
              if (!value && !refocused && Date.now() - started > 10000) {
                // Widget mounted after the first focus: trigger it once more.
                refocused = true;
                focusEvents(pass);
              }
              return value === null ? Date.now() - started > 15000 : value;
            }, 180000); // time to solve it by hand ("Bankseite anzeigen")
            if (!solved) throw new Error("DKB captcha not solved");
          }
          const enabled = await waitFor(() => {
            const element = find(SUBMIT);
            return element && !element.disabled ? element : null;
          }, 10000);
          if (!enabled) throw new Error("DKB login button disabled");
          current = { phase: "submitted" };
          markSubmitted();
          enabled.click();
          mfn.status("Anmeldung bei der DKB …");
        }

        // Single page app: watch until an error shows, the approval completes (the app closes the web view) or time is up.
        const started = Date.now();
        let confirming = false;
        let methodPicked = false;
        let devicePicked = false;
        let lastCheck = 0;
        while (Date.now() - started < 290000) {
          await sleep(500);
          const reason = failure();
          if (reason) throw new Error(reason);
          dismissConsent();

          const methodForm = !methodPicked && document.querySelector(METHOD_FORM);
          if (methodForm) {
            const app = find(APP_METHOD);
            if (!app) throw new Error("DKB app approval not offered");
            methodPicked = true;
            app.click();
            await sleep(300);
            const next = methodForm.querySelector('button[type="submit"]');
            if (next) next.click();
            continue;
          }
          const deviceForm = !devicePicked && document.querySelector(DEVICE_FORM);
          if (deviceForm) {
            devicePicked = true;
            const buttons = Array.from(deviceForm.querySelectorAll("button")).filter((b) => !b.getAttribute("aria-label"));
            const confirm = buttons.find((b) => /bestätigen|confirm/i.test(textOf(b))) || buttons[buttons.length - 1];
            if (confirm) confirm.click();
            continue;
          }
          if (document.querySelector(OTHER_METHOD)) throw new Error("DKB app approval not selected");

          if (!confirming && (document.querySelector(WAITING) || Date.now() - started >= 3000)) {
            confirming = true;
            mfn.status(CONFIRM);
          }
          let here = "";
          try { here = new URL(String(location.href)).pathname; } catch (error) { here = ""; }
          if (here.startsWith("/timeout")) throw new Error("DKB approval timed out");
          if (here && !here.startsWith("/login") && Date.now() - lastCheck > 3000) {
            // The app routed away from the login without a page load: approved if the API answers.
            lastCheck = Date.now();
            if (await loggedIn()) {
              setDone(true);
              mfn.status(DONE);
              return current;
            }
          }
          const pass = find(PASS);
          if (pass && pass.value === "" && !document.querySelector(WAITING) && Date.now() - started >= 5000) {
            // The page reset the form without an error: approval declined or cancelled.
            throw new Error("DKB approval not completed");
          }
        }
        return current;
        """#
}
