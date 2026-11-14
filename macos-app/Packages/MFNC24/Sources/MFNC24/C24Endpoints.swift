import Foundation
import MFNCore

/// Every URL, path, header and parameter of the C24 web-banking API, in one place.
///
/// Source: `Fixtures/C24/endpoints.md` (Safari HAR, recorded after login). Confirmed there:
/// API host `api.c24.de`, `Authorization: Bearer` plus `x-c24-*` headers on every call, the
/// account list, pockets, upcoming transactions and `POST /api/v3/transactions/search/` with
/// `pagination.offset`/`limit`/`more`.
///
/// **Not yet confirmed** (gaps in `endpoints.md`, therefore `verified == false`):
/// Token hand-over (protocol v2): the web app keeps the bearer token in
/// `sessionStorage["sessionStore"]` on `banking.c24.de` (JSON, key `accessToken`); the login
/// requests it via `WebLoginRequest.storageKeys` and receives it as pseudo-cookie `sessionStore`.
///
/// Still open (documented in `STATUS.md`, not blocking the first real fetch):
/// - the exact login start URL,
/// - the format of the `x-c24-*` header values (values were removed from the HAR),
/// - the `future_days` value, giro transactions, preliminary (pending) transactions,
///   the answer to an expired session.
///
/// `verified`: endpoints checked against `Fixtures/C24` (2026-11-10). `C24Connector` refuses to
/// start a login while it is `false` (no pointless push TAN).
public struct C24Endpoints: Sendable, Hashable {
    /// How a dynamic `x-c24-*` header value is produced.
    public enum HeaderValue: Sendable, Hashable {
        /// One random UUID per login session (e.g. a tracing session).
        case sessionUUID
        /// A fresh random UUID per request.
        case requestUUID
        /// Milliseconds since 1970.
        case unixMillis
        case fixed(String)
    }

    /// API host (`https://api.c24.de`).
    public var apiBaseURL: URL
    /// Start page of the interactive login (WKWebView, push TAN in the C24 app).
    public var loginURL: URL
    /// When the web view counts as logged in.
    public var loginCompletion: WebLoginRequest.Completion
    /// Only cookies of these domains are taken over from the web view.
    public var cookieDomains: [String]
    public var loginMessage: String

    /// `sessionStorage` key of the web app that holds the session (JSON). The app hands it over in
    /// `.webSession` as pseudo-cookie of this name; never sent as a cookie.
    public var sessionStorageKey: String
    /// Where that key lives (Web Storage is per origin).
    public var sessionStorageSource: StorageKey.Source
    public var sessionStorageDomain: String
    /// Field of that JSON object with the bearer token (`Authorization: Bearer …`).
    public var accessTokenField: String
    /// Headers the web app sends with every API call besides `Authorization`.
    public var clientHeaders: [String: HeaderValue]

    /// Lightweight authenticated call to validate a stored session before each sync.
    public var sessionCheckPath: String
    /// Current accounts and pockets with balances (`accounts`, `pockets`).
    public var accountsPath: String
    /// Pockets on their own (`pockets`); merged by pocket number. `nil` to skip.
    public var pocketsPath: String?
    /// `POST` with `criteria.account_numbers` and `pagination`.
    public var transactionSearchPath: String
    /// Standing orders and announced direct debits. `nil` to skip.
    public var upcomingPath: String?
    public var upcomingFutureDaysParameter: String
    public var upcomingFutureDays: Int
    /// Page size of the transaction search (the web app uses 30).
    public var pageSize: Int

    /// `true` once every value was checked against real traffic.
    public var verified: Bool

    /// QR login of the web app (bundle `banking.c24.de`, 2026-11-10), driven by `C24LoginScript`.
    /// `GET` → `{qrtoken}`; shown as QR code (payload = the raw token).
    public var qrTokenGeneratePath: String
    /// `POST {qrtoken}` → optional rotated `qrtoken`, `web_login_uuid` once the C24 app scanned it.
    public var qrTokenStatusPath: String
    /// `POST {web_login_pin, qrtoken, web_login_uuid}` → `{access_token, refresh_token}`.
    public var webLoginCompletePath: String
    /// `POST {refresh_token}` → `{access_token, refresh_token?}`: renews an expired access token
    /// without a new QR login (what the web app does on HTTP 401; public bundle, 2026-11-10).
    public var webLoginRefreshPath: String
    /// Field of the `sessionStorage` JSON with the refresh token.
    public var refreshTokenField: String
    /// Headless login (protocol v4 automation + QR bridge `mfn.showQRCode`, proposed as v5).
    /// `false` = visible web login, where the page shows its own QR code.
    public var headlessLogin: Bool

    public init(
        apiBaseURL: URL,
        loginURL: URL,
        loginCompletion: WebLoginRequest.Completion,
        cookieDomains: [String],
        loginMessage: String = "Scanne den QR-Code mit der C24-App und gib die 6 Ziffern aus der App ein.",
        sessionStorageKey: String = "sessionStore",
        sessionStorageSource: StorageKey.Source = .sessionStorage,
        sessionStorageDomain: String = "banking.c24.de",
        accessTokenField: String = "accessToken",
        clientHeaders: [String: HeaderValue],
        sessionCheckPath: String,
        accountsPath: String,
        pocketsPath: String?,
        transactionSearchPath: String,
        upcomingPath: String?,
        upcomingFutureDaysParameter: String = "future_days",
        upcomingFutureDays: Int = 60,
        pageSize: Int = 30,
        verified: Bool,
        qrTokenGeneratePath: String = "/api/qrtoken/generate/",
        qrTokenStatusPath: String = "/api/qrtoken/status/",
        webLoginCompletePath: String = "/api/web-login/complete/",
        webLoginRefreshPath: String = "/api/web-login/refresh/",
        refreshTokenField: String = "refreshToken",
        headlessLogin: Bool = false
    ) {
        self.apiBaseURL = apiBaseURL
        self.loginURL = loginURL
        self.loginCompletion = loginCompletion
        self.cookieDomains = cookieDomains
        self.loginMessage = loginMessage
        self.sessionStorageKey = sessionStorageKey
        self.sessionStorageSource = sessionStorageSource
        self.sessionStorageDomain = sessionStorageDomain
        self.accessTokenField = accessTokenField
        self.clientHeaders = clientHeaders
        self.sessionCheckPath = sessionCheckPath
        self.accountsPath = accountsPath
        self.pocketsPath = pocketsPath
        self.transactionSearchPath = transactionSearchPath
        self.upcomingPath = upcomingPath
        self.upcomingFutureDaysParameter = upcomingFutureDaysParameter
        self.upcomingFutureDays = upcomingFutureDays
        self.pageSize = pageSize
        self.verified = verified
        self.qrTokenGeneratePath = qrTokenGeneratePath
        self.qrTokenStatusPath = qrTokenStatusPath
        self.webLoginCompletePath = webLoginCompletePath
        self.webLoginRefreshPath = webLoginRefreshPath
        self.refreshTokenField = refreshTokenField
        self.headlessLogin = headlessLogin
    }

    /// Paths and headers from `Fixtures/C24/endpoints.md`, token hand-over via protocol v2.
    /// Login URL and header value formats are best guesses (see type documentation).
    public static let production = C24Endpoints(
        apiBaseURL: literalURL("https://api.c24.de"),
        loginURL: literalURL("https://banking.c24.de/"), // web banking start, redirects to the login (not in the HAR)
        // Done as soon as the web app has written its session (v2: storage entries satisfy `cookiesPresent`).
        loginCompletion: .cookiesPresent(["sessionStore"]),
        cookieDomains: ["c24.de"],
        sessionStorageKey: "sessionStore", // confirmed by the human
        sessionStorageSource: .sessionStorage,
        sessionStorageDomain: "banking.c24.de",
        accessTokenField: "accessToken",
        clientHeaders: [
            // Names confirmed, value formats assumed (values were removed from the HAR).
            "x-c24-guid": .sessionUUID,
            "x-c24-unicorn-guid": .sessionUUID,
            "x-c24-tracingsession": .sessionUUID,
            "x-c24-timestamp": .unixMillis,
        ],
        sessionCheckPath: "/api/v2/user/me/",
        accountsPath: "/api/user/me/accounts/internal/",
        pocketsPath: "/api/v3/pockets/",
        transactionSearchPath: "/api/v3/transactions/search/",
        upcomingPath: "/api/v2/upcoming-transactions/",
        verified: true,
        // Protocol v5: the app draws the QR code (`mfn.showQRCode`).
        headlessLogin: true
    )

    /// URL from a compile-time constant.
    static func literalURL(_ string: StaticString) -> URL {
        guard let url = URL(string: "\(string)") else {
            // Programming error: only called with hard-coded, well-formed literals above.
            fatalError("Ungültige URL-Konstante")
        }
        return url
    }

    /// Web login request. C24 has no username/password form (bundle `banking.c24.de`, 2026-11-10):
    /// the user scans a QR code with the C24 app and types 6 digits from the app.
    /// - `headlessLogin == false`: visible web view, the page shows its own QR code.
    /// - `headlessLogin == true`: `C24LoginScript` runs the same flow in a hidden web view and shows
    ///   the QR code through the app (`mfn.showQRCode`), the digits through `mfn.requestCode`.
    /// Either way the session ends up in `sessionStorage["sessionStore"]` (completion unchanged).
    var loginRequest: WebLoginRequest {
        WebLoginRequest(
            url: loginURL,
            completion: loginCompletion,
            cookieDomains: cookieDomains,
            message: loginMessage,
            storageKeys: [StorageKey(key: sessionStorageKey, source: sessionStorageSource, domain: sessionStorageDomain)],
            automation: headlessLogin ? C24LoginScript.automation(for: self) : nil
        )
    }

    /// Absolute API URL for `path` with optional query items.
    func url(_ path: String, query: [URLQueryItem] = []) throws(ConnectorError) -> URL {
        guard var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw .formatChanged(detail: "C24: Basis-URL ungültig")
        }
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw .formatChanged(detail: "C24: URL für \(path) ungültig") }
        return url
    }
}
