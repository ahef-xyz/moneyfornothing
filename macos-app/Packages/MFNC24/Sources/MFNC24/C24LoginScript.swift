import Foundation
import MFNCore

/// Headless QR login for C24 (`WebLoginAutomation`, protocol v4 + proposed QR bridge).
///
/// Flow of the C24 web app (bundle `banking.c24.de`, 2026-11-10), run by the script itself via
/// `fetch` from the page origin:
/// 1. `GET /api/qrtoken/generate/` → `{qrtoken}`; `mfn.showQRCode(qrtoken, …)` (the page encodes
///    the raw token, no URL around it).
/// 2. Poll `POST /api/qrtoken/status/ {qrtoken}`: a different `qrtoken` replaces the QR code (the
///    page gives up after more than 2 rotations), `web_login_uuid` means the app scanned it. A
///    failed status call or too many rotations → new QR code (at most `maxQRCodes`).
/// 3. `await mfn.requestCode(…, 6)` for the 6 digits the app shows.
/// 4. `POST /api/web-login/complete/ {web_login_pin, qrtoken, web_login_uuid}` →
///    `{access_token, refresh_token}`; 4xx → `authFailed` (never retried). The session is written
///    like the page does (`sessionStorage["sessionStore"] = {guid, accessToken, refreshToken}`),
///    which completes the login (`.cookiesPresent(["sessionStore"])`).
///
/// Re-entry: the script runs after every main-frame load; `state` `{done: true}` or an existing
/// `sessionStore` with token ends it at once. `state` never holds tokens, digits or credentials.
/// C24 has no stored credentials to use: `credentials` is never read.
enum C24LoginScript {
    /// Constants handed to the script as JSON literal (no user data, no secrets).
    struct Config: Encodable {
        var origin: String
        var apiBase: String
        var generatePath: String
        var statusPath: String
        var completePath: String
        var storageKey: String
        // UNVERIFIED: the page's poll interval comes from runtime config (`qr_token_status_interval`).
        var pollMillis: Int = 2_000
        /// Polls per QR code before a new one is fetched (~2 min).
        var maxPolls: Int = 60
        /// The page treats more than 2 rotations as expired.
        var maxTokenChanges: Int = 2
        var maxQRCodes: Int = 5
        var scanMessage = String(localized: "Scanne den QR-Code mit der C24-App.", bundle: .module)
        var expiredMessage = String(localized: "QR-Code abgelaufen, neuer Code wird erzeugt.", bundle: .module)
        var pinMessage = String(localized: "Gib die 6 Ziffern aus der C24-App ein.", bundle: .module)
        var pinPrompt = String(localized: "6 Ziffern aus der C24-App", bundle: .module)
        var doneMessage = String(localized: "Angemeldet.", bundle: .module)
    }

    static func config(for endpoints: C24Endpoints) -> Config {
        let url = endpoints.loginURL
        let origin = "\(url.scheme ?? "https")://\(url.host() ?? "")"
        return Config(
            origin: origin,
            apiBase: endpoints.apiBaseURL.absoluteString.hasSuffix("/") ? String(endpoints.apiBaseURL.absoluteString.dropLast()) : endpoints.apiBaseURL.absoluteString,
            generatePath: endpoints.qrTokenGeneratePath,
            statusPath: endpoints.qrTokenStatusPath,
            completePath: endpoints.webLoginCompletePath,
            storageKey: endpoints.sessionStorageKey
        )
    }

    static func automation(for endpoints: C24Endpoints) -> WebLoginAutomation {
        WebLoginAutomation(
            script: script(config(for: endpoints)),
            message: String(localized: "Anmeldung bei C24 wird vorbereitet …", bundle: .module),
            timeout: 300
        )
    }

    static func script(_ config: Config) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings and ints cannot fail; fall back to a config that makes the script
        // throw (→ formatChanged) instead of crashing.
        let json = (try? encoder.encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return "const cfg = \(json);\n" + body
    }

    /// Body of the async function `(credentials, state, url)`. Plain JS, no dependencies besides
    /// `fetch`, `sessionStorage`, `setTimeout` and the bridge `mfn`.
    static let body = #"""
    if (!cfg) throw new Error('config missing');
    if (state && state.done === true) return { done: true };
    if (typeof url !== 'string' || url.indexOf(cfg.origin + '/') !== 0) throw new Error('unexpected page');

    const existing = sessionStorage.getItem(cfg.storageKey);
    if (existing) {
      try {
        const session = JSON.parse(existing);
        if (session && typeof session.accessToken === 'string' && session.accessToken) return { done: true };
      } catch (e) { /* not ours, log in again */ }
    }
    if (typeof mfn.showQRCode !== 'function') throw new Error('qr bridge missing');

    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const call = async (method, path, body) => {
      const init = { method: method, headers: { 'Accept': 'application/json' } };
      if (body !== undefined) {
        init.headers['Content-Type'] = 'application/json';
        init.body = JSON.stringify(body);
      }
      const response = await fetch(cfg.apiBase + path, init);
      let json = null;
      try { json = await response.json(); } catch (e) { json = null; }
      return { status: response.status, ok: response.status >= 200 && response.status < 300, json: json };
    };
    const text = (value) => (typeof value === 'string' && value.length > 0) ? value : null;

    for (let codes = 1; ; codes++) {
      if (codes > cfg.maxQRCodes) throw new Error('qr code expired too often');
      const generated = await call('GET', cfg.generatePath);
      let token = generated.ok && generated.json ? text(generated.json.qrtoken) : null;
      if (!token) throw new Error('qr token missing');
      mfn.showQRCode(token, cfg.scanMessage);

      let uuid = null;
      let changes = 0;
      for (let polls = 0; !uuid && polls < cfg.maxPolls; polls++) {
        await sleep(cfg.pollMillis);
        const status = await call('POST', cfg.statusPath, { qrtoken: token });
        if (!status.ok) break;
        const body = status.json || {};
        const rotated = text(body.qrtoken);
        if (rotated && rotated !== token) {
          token = rotated;
          changes++;
          if (changes > cfg.maxTokenChanges) break;
          mfn.showQRCode(token, cfg.scanMessage);
        }
        uuid = text(body.web_login_uuid);
      }
      if (!uuid) {
        mfn.status(cfg.expiredMessage);
        continue;
      }

      mfn.status(cfg.pinMessage);
      const pin = String(await mfn.requestCode(cfg.pinPrompt, 6)).trim();
      if (!/^[0-9]{6}$/.test(pin)) throw new Error('authFailed: code format');
      const completed = await call('POST', cfg.completePath, { web_login_pin: pin, qrtoken: token, web_login_uuid: uuid });
      if (completed.status >= 400 && completed.status < 500) throw new Error('authFailed: code rejected');
      const accessToken = completed.ok && completed.json ? text(completed.json.access_token) : null;
      if (!accessToken) throw new Error('login incomplete');
      const refreshToken = text(completed.json.refresh_token);
      sessionStorage.setItem(cfg.storageKey, JSON.stringify({ guid: uuid, accessToken: accessToken, refreshToken: refreshToken }));
      mfn.status(cfg.doneMessage);
      return { done: true };
    }
    """#
}
