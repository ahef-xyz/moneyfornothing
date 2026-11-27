import Foundation
import MFNCore

/// Headless login for Trade Republic (protocol v4, `WebLoginAutomation`).
///
/// The app loads `https://app.traderepublic.com/login` in a hidden web view and runs `source`
/// after every page load. The script calls the login API the web app uses itself, from the
/// page's origin and with its cookies (AWS WAF):
///
/// 1. Waits until the page set the `aws-waf-token` cookie (WAF challenge done).
/// 2. `POST /api/v2/auth/web/login` `{phoneNumber, pin}` → `processId` (Fixtures: `login.json`).
/// 3. Polls `GET /api/v2/auth/web/login/processes/{processId}` every 2 s while the user confirms
///    in the Trade Republic app (`login-process-pending.json` → `login-process-done.json`); the
///    final answer sets `tr_session`, which completes the login (`completion`).
///    `requiredAction == AUTHENTICATOR_VERIFICATION` → 6-digit code from the user,
///    `POST …/processes/{processId}/authenticator-verification` `{code}`.
///    Any other non-pending `status` on 2xx (e.g. `REJECTED`, `FAILED`) ends the process → `authFailed`.
/// 4. No automatic v1 fallback: the web app retries with `POST /api/v1/auth/web/login` (SMS/app
///    code) on `DEVICE_NOT_FOUND`/`MOBILE_APP_VERSION_NOT_SUPPORTED`, which sends the PIN a second
///    time (lock risk). The script stops with an error instead; any other failure stops too.
///
/// Error codes from the public web bundle (2026-11-10, `LoginFlow-*.js`, `analytics-*.js`):
/// `AUTHENTICATION_ERROR`/`INVALID_VALUE`/`NUMBER_INVALID` = wrong phone number or PIN →
/// `authFailed`; `TOO_MANY_REQUESTS` at login → `authFailed` too (never retried: more attempts
/// lock the account); `ALREADY_PROCESSED` while polling = rejected in the app → `authFailed`;
/// `PROCESS_GONE` = expired; `LOGIN_NOT_ALLOWED`, `GEO_BLOCKED`, `WEBTRADING_NOT_AVAILABLE` →
/// other error (`formatChanged`).
///
/// Re-entry: the returned `state` (`{step, processId}`) and a `sessionStorage` marker (processId
/// only) resume polling after a navigation instead of starting a second login (second push).
/// A second marker (`mfn.tr.submitted`), written before the PIN is sent, stops a run that finds
/// it without a process to resume: the PIN is never sent twice. The page must be exactly on
/// `webOrigin` (`new URL(url).origin`), never a host that merely starts with it.
/// Credentials stay in the function argument: never logged, stored or put into `state`.
enum TRLoginScript {
    static let webOrigin = "https://app.traderepublic.com"
    static let codeInvalidMessage = String(localized: "Code ungültig, bitte erneut eingeben.", bundle: .module)
    static let confirmMessage = String(localized: "Bitte in der Trade-Republic-App bestätigen.", bundle: .module)
    static let authenticatorPrompt = String(localized: "Code aus der Authenticator-App", bundle: .module)
    static let finishingMessage = String(localized: "Anmeldung wird abgeschlossen …", bundle: .module)
    static let confirmedMessage = String(localized: "Anmeldung bestätigt.", bundle: .module)

    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    static let automation = WebLoginAutomation(
        script: source,
        message: String(localized: "Anmeldung bei Trade Republic …", bundle: .module),
        timeout: 300
    )

    /// Body of `async function(credentials, state, url)`.
    static let source = #"""
    "use strict";
    const API = "https://api.traderepublic.com";
    const ORIGIN = "\#(webOrigin)";
    const FALLBACK_APP_VERSION = "\#(TRSession.fallbackAppVersion)";
    const MARK = "mfn.tr.login";
    // Set right before the PIN is sent, never holds credentials. A run that finds it without a
    // process to resume stops: the PIN may already have reached Trade Republic (lockout risk).
    const SUBMITTED = "mfn.tr.submitted";
    const POLL_MS = 2000;
    const WAF_WAIT_MS = 30000;
    const MARK_MAX_AGE_MS = 5 * 60 * 1000;
    const BAD_CREDENTIALS = ["AUTHENTICATION_ERROR", "INVALID_VALUE", "NUMBER_INVALID"];
    const CODE_INVALID = ["VALIDATION_CODE_INVALID", "VALIDATION_CODE_ALREADY_USED"];
    const POLL_PENDING = ["", "PENDING"];

    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const authFailed = (reason) => new Error("authFailed: " + reason);

    if (state && state.step === "done") return state;
    let pageOrigin = null;
    try { pageOrigin = new URL(String(url)).origin; } catch (e) {}
    // Exact origin: a prefix check would also accept e.g. app.traderepublic.com.example.org.
    if (pageOrigin !== ORIGIN) return state ?? null;

    function cookie(name) {
      for (const part of String(document.cookie || "").split(";")) {
        const i = part.indexOf("=");
        if (i > 0 && part.slice(0, i).trim() === name) return part.slice(i + 1).trim();
      }
      return null;
    }

    function marker() {
      try {
        const m = JSON.parse(sessionStorage.getItem(MARK) || "null");
        if (m && typeof m.processId === "string" && Date.now() - m.at < MARK_MAX_AGE_MS) return m;
      } catch (e) {}
      return null;
    }
    function remember(processId) {
      try { sessionStorage.setItem(MARK, JSON.stringify({ processId, at: Date.now() })); } catch (e) {}
    }
    function forget() {
      try { sessionStorage.removeItem(MARK); } catch (e) {}
    }
    function markSubmitted() {
      // Must succeed: without the marker a reload could send the PIN a second time.
      sessionStorage.setItem(SUBMITTED, "1");
    }
    function wasSubmitted() {
      try { return sessionStorage.getItem(SUBMITTED) === "1"; } catch (e) { return false; }
    }
    function forgetSubmitted() {
      try { sessionStorage.removeItem(SUBMITTED); } catch (e) {}
    }

    function normalizePhone(raw) {
      let p = String(raw ?? "").replace(/[\s\-\/().]/g, "");
      if (p.startsWith("00")) p = "+" + p.slice(2);
      else if (p.startsWith("0")) p = "+49" + p.slice(1);
      else if (!p.startsWith("+")) p = "+" + p;
      if (!/^\+[1-9]\d{6,14}$/.test(p)) throw authFailed("phone number format");
      return p;
    }

    async function waitForWaf() {
      const deadline = Date.now() + WAF_WAIT_MS;
      while (!cookie("aws-waf-token")) {
        if (Date.now() >= deadline) throw new Error("aws-waf-token missing");
        await sleep(250);
      }
    }

    let appVersion = null;
    async function resolveAppVersion() {
      if (appVersion) return appVersion;
      appVersion = FALLBACK_APP_VERSION;
      try {
        const res = await fetch(ORIGIN + "/app-version.txt", { method: "GET", credentials: "same-origin" });
        const text = res.status === 200 ? String(await res.text()).trim() : "";
        if (/^\d+(\.\d+){1,3}$/.test(text)) appVersion = text;
      } catch (e) {}
      return appVersion;
    }

    // X-TR-Device-Info like the web app: base64(JSON) of a canvas hash and browser facts.
    // UNVERIFIED: whether the server checks more than presence; values follow the bundle.
    let deviceInfo = null;
    async function resolveDeviceInfo() {
      if (deviceInfo) return deviceInfo;
      let stableDeviceId = null;
      try {
        const canvas = document.createElement("canvas");
        canvas.height = 100; canvas.width = 600;
        const ctx = canvas.getContext("2d", { alpha: false });
        if (ctx) {
          const g = ctx.createLinearGradient(0, 0, canvas.width, canvas.height);
          g.addColorStop(0, "#FF5733"); g.addColorStop(0.5, "#33FF57"); g.addColorStop(1, "#3357FF");
          ctx.font = "16px Arial"; ctx.textBaseline = "alphabetic";
          ctx.fillStyle = g; ctx.fillRect(0, 0, canvas.width, canvas.height);
          ctx.fillStyle = "rgba(102, 204, 0, 0.7)";
          ctx.translate(10, 40); ctx.rotate(0.05);
          ctx.fillText("TradeRepublic.de: <wealth> 4,0! ㈱", 0, 20);
          ctx.rotate(-0.05); ctx.translate(-10, -40);
          ctx.fillStyle = "rgba(255, 0, 0, 0.5)"; ctx.fillRect(50, 30, 90, 50);
          ctx.strokeStyle = "blue"; ctx.beginPath(); ctx.arc(250, 50, 20, 0, Math.PI * 2); ctx.stroke();
          const pixels = Array.from(ctx.getImageData(0, 0, canvas.width, canvas.height).data).slice(0, 10000).join("");
          const digest = await crypto.subtle.digest("SHA-512", new TextEncoder().encode(pixels));
          stableDeviceId = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
        }
      } catch (e) {}
      const nav = globalThis.navigator || {};
      const ua = String(nav.userAgent || "");
      const scr = globalThis.screen || {};
      let timezone;
      try { timezone = Intl.DateTimeFormat().resolvedOptions().timeZone; } catch (e) {}
      const info = {
        stableDeviceId,
        browser: "Safari",
        browserVersion: (ua.match(/Version\/([\d.]+)/) || [])[1],
        os: "macOS",
        osVersion: ((ua.match(/Mac OS X ([\d_]+)/) || [])[1] || "").replace(/_/g, ".") || undefined,
        timezone,
        timezoneOffset: new Date().getTimezoneOffset(),
        screen: `${scr.width}x${scr.height}x${scr.colorDepth}`,
        preferredLanguages: Array.from(nav.languages || []),
        numberOfCores: nav.hardwareConcurrency,
        deviceMemory: nav.deviceMemory,
      };
      deviceInfo = btoa(JSON.stringify(info));
      return deviceInfo;
    }

    async function call(method, path, body) {
      const headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Accept-Language": "de",
        "X-Tr-Platform": "web-pro",
        "X-TR-App-Version": await resolveAppVersion(),
        "X-TR-Device-Info": await resolveDeviceInfo(),
      };
      const waf = cookie("aws-waf-token");
      if (waf) headers["X-Aws-Waf-Token"] = waf;
      // UNVERIFIED: Set-Cookie (tr_session, HttpOnly) of this fetch lands in the web view's cookie store.
      const init = { method, credentials: "include", headers };
      if (body !== undefined) init.body = JSON.stringify(body);
      const res = await fetch(API + path, init);
      let json = null;
      try { json = await res.json(); } catch (e) {}
      const code = (json && Array.isArray(json.errors) && json.errors[0] && json.errors[0].errorCode) || null;
      return { ok: res.status >= 200 && res.status < 300, status: res.status, json, code };
    }

    // Login start (v2 and v1): wrong credentials and rate limits end the login for good.
    function startError(r) {
      if (BAD_CREDENTIALS.includes(r.code)) return authFailed("credentials rejected");
      if (r.code === "TOO_MANY_REQUESTS") return authFailed("too many attempts");
      if (r.status === 405) return new Error("blocked by WAF");
      return new Error("login start HTTP " + r.status + (r.code ? " " + r.code : ""));
    }

    async function askCode(prompt, length, submit) {
      for (let attempt = 1; ; attempt++) {
        const code = String(await mfn.requestCode(prompt, length)).trim();
        const r = await submit(code);
        if (r.ok) return r;
        if (CODE_INVALID.includes(r.code) && attempt < 3) {
          mfn.status(\#(jsString(codeInvalidMessage)));
          continue;
        }
        if (CODE_INVALID.includes(r.code)) throw authFailed("code rejected");
        if (r.code === "TOO_MANY_REQUESTS") throw authFailed("too many attempts");
        throw new Error("code HTTP " + r.status + (r.code ? " " + r.code : ""));
      }
    }

    // UNVERIFIED: HTTP status codes of the error answers; only errors[0].errorCode is evaluated.
    async function poll(processId, countdownSeconds) {
      remember(processId);
      mfn.status(\#(jsString(confirmMessage)));
      const deadline = Date.now() + (Math.max(Number(countdownSeconds) || 120, 60) + 60) * 1000;
      const path = "/api/v2/auth/web/login/processes/" + encodeURIComponent(processId);
      while (Date.now() < deadline) {
        const r = await call("GET", path);
        if (r.ok) {
          const s = (r.json && r.json.status) || "";
          if (s === "CONFIRMED" || s === "COMPLETED") return done();
          if (r.json && r.json.requiredAction === "AUTHENTICATOR_VERIFICATION") {
            await askCode(\#(jsString(authenticatorPrompt)), 6, (code) =>
              call("POST", path + "/authenticator-verification", { code }));
            mfn.status(\#(jsString(finishingMessage)));
            continue;
          }
          if (!POLL_PENDING.includes(String(s).toUpperCase())) { forget(); throw authFailed("process ended"); }
        } else {
          if (r.code === "ALREADY_PROCESSED") { forget(); throw authFailed("rejected in app"); }
          if (r.code === "PROCESS_GONE" || r.code === "NOT_FOUND") { forget(); throw new Error("login expired"); }
          if (r.code === "TOO_MANY_REQUESTS") { forget(); throw new Error("polling rate limited"); }
          if (r.status !== 405 && r.status < 500) { forget(); throw new Error("poll HTTP " + r.status); }
          // 405 (WAF) / 5xx: transient, keep polling until the deadline.
        }
        await sleep(POLL_MS);
      }
      forget();
      throw new Error("login expired");
    }

    function done() {
      forget();
      forgetSubmitted();
      mfn.status(\#(jsString(confirmedMessage)));
      return { step: "done" };
    }

    // Resume a running confirmation instead of starting a second login.
    const resumeId = (state && state.step === "confirm" && state.processId) || (marker() || {}).processId;
    await waitForWaf();
    if (resumeId) return await poll(resumeId, 120);
    if (wasSubmitted()) throw new Error("login already submitted, not sending the PIN again");

    const body = { phoneNumber: normalizePhone(credentials && credentials.phoneNumber), pin: String((credentials && credentials.pin) ?? "") };
    if (!/^\d{4}$/.test(body.pin)) throw authFailed("pin format");
    mfn.status("Anmeldung bei Trade Republic …");
    markSubmitted();
    const r = await call("POST", "/api/v2/auth/web/login", body);
    if (r.ok) {
      const json = r.json || {};
      if (!json.processId) return done();
      return await poll(json.processId, json.countdownInSeconds);
    }
    // The v1 login (SMS/app code) would need the PIN a second time: never automatically.
    if (r.code === "DEVICE_NOT_FOUND" || r.code === "MOBILE_APP_VERSION_NOT_SUPPORTED") {
      throw new Error("login needs the older SMS flow (" + r.code + "), log in once in the Trade Republic web app");
    }
    throw startError(r);
    """#
}
