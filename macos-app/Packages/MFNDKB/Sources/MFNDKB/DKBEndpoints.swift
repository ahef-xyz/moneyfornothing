import Foundation
import MFNCore

/// Where and how the DKB web banking talks to its backend (`Fixtures/DKB/web/endpoints.md`, HAR of `banking.dkb.de`).
///
/// - Everything below `https://banking.dkb.de/api`, JSON:API answers.
/// - No `Authorization` header: the session is a set of cookies (`__Secure-at` access token, `__Secure-rt` refresh
///   token, `__Host-sid`, `__Host-sid.sig`, `__Host-xsrf`, after the second factor also `__Secure-ssoIdToken`, …).
/// - Every call carries `x-xsrf-token` = value of the `__Host-xsrf` cookie and `application-name: web-banking`.
/// - Read-only: only the GET endpoints below are used. No payment, card or settings endpoint is called.
public struct DKBEndpoints: Sendable, Equatable {
    public var origin: URL
    public var apiPath: String
    public var loginPath: String
    public var cookieDomains: [String]

    public static let production = DKBEndpoints(
        origin: literalURL("https://banking.dkb.de"),
        apiPath: "/api",
        loginPath: "/login",
        cookieDomains: ["dkb.de"]
    )

    /// Cookie whose value goes into the `x-xsrf-token` header.
    public static let xsrfCookie = "__Host-xsrf"
    /// Access token cookie (lives 5 min, `expires_in: 300`).
    public static let accessTokenCookie = "__Secure-at"
    /// Cookies the API needs; a stored session without them is not worth a request.
    public static let requiredSessionCookies = [accessTokenCookie, xsrfCookie]

    /// Set by `DKBLoginScript` (not HttpOnly, session cookie) once the page has left `/login` after the submit, i.e. after
    /// the second factor. A cookie because completion is cookie-based and the overview is a single-page route.
    public static let loginDoneCookie = "mfn-dkb-login-done"

    /// Login complete: the script's marker (set only after the account list answered) plus the cookies the API needs.
    /// Neither `__Secure-ssoIdToken` nor `__Host-sid` is required: live logins (2026-11-10) reached a working session
    /// without one or the other. The app deletes all completion cookies from its persistent web store after the login,
    /// so the session lives in the keychain only.
    public static let completionCookies = [loginDoneCookie] + requiredSessionCookies

    public static let pageSize = 25

    private static func literalURL(_ string: StaticString) -> URL {
        guard let url = URL(string: "\(string)") else {
            // Programming error: only called with the hard-coded, well-formed literal above.
            fatalError("Ungültige URL-Konstante")
        }
        return url
    }

    var host: String { origin.host() ?? "banking.dkb.de" }

    /// URL below the API path. `query` is appended verbatim (DKB uses JSON:API brackets like `filter[type]`).
    func apiURL(_ path: String, query: String? = nil) throws(ConnectorError) -> URL {
        var string = origin.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        string += apiPath + path
        if let query, !query.isEmpty { string += "?" + query }
        guard let url = URL(string: string) else { throw .formatChanged(detail: "DKB: URL ungültig") }
        return url
    }

    /// `GET /api/accounts/accounts?filter[product.type][NEQ]=loan`
    func accountsURL() throws(ConnectorError) -> URL {
        try apiURL("/accounts/accounts", query: "filter%5Bproduct.type%5D%5BNEQ%5D=loan")
    }

    /// `GET /api/config/users/me/product-display-settings` (user-named groups, used for account names only).
    func displaySettingsURL() throws(ConnectorError) -> URL {
        try apiURL("/config/users/me/product-display-settings")
    }

    /// `GET /api/accounts/accounts/<id>/transactions?expand=Merchant,International&page[size]=25[&page[after]=<cursor>]`
    ///
    /// UNVERIFIED: page 2 is not in the HAR. The answer names the cursor twice (`meta.page.next` and inside
    /// `links.next`, a path relative to `/api` without `expand`); the connector keeps its own query and adds
    /// `page[after]=<cursor>`.
    func transactionsURL(accountID: String, after cursor: String?) throws(ConnectorError) -> URL {
        guard let id = accountID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else {
            throw .formatChanged(detail: "DKB: Konto-ID ungültig")
        }
        var query = "expand=Merchant,International&page%5Bsize%5D=\(Self.pageSize)"
        if let cursor {
            guard let encoded = cursor.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) else {
                throw .formatChanged(detail: "DKB: Cursor ungültig")
            }
            query += "&page%5Bafter%5D=" + encoded
        }
        return try apiURL("/accounts/accounts/\(id)/transactions", query: query)
    }

    private static let queryValueAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~,:"))

    /// Headers of every API call. Values derived from the session, never logged.
    static func headers(cookies: [SessionCookie]) -> [String: String] {
        var headers = [
            "Accept": "application/json, text/plain, */*",
            "application-name": "web-banking",
        ]
        if let xsrf = cookies.last(where: { $0.name == xsrfCookie })?.value, !xsrf.isEmpty {
            headers["x-xsrf-token"] = xsrf
        }
        return headers
    }

    /// Headless login request (protocol v4): `DKBLoginScript` fills the login form with the stored
    /// username/password, the page solves Friendly Captcha itself, the user confirms in the DKB app.
    public var loginRequest: WebLoginRequest {
        var loginURL = origin.absoluteString
        while loginURL.hasSuffix("/") { loginURL.removeLast() }
        return WebLoginRequest(
            url: URL(string: loginURL + loginPath) ?? origin,
            completion: .cookiesPresent(Self.completionCookies),
            cookieDomains: cookieDomains,
            message: "Bitte bei der DKB anmelden und in der DKB-App bestätigen.",
            automation: WebLoginAutomation(script: DKBLoginScript.source, message: "Anmeldung bei der DKB …", timeout: 480)
        )
    }
}
