import Foundation
import MFNCore

/// Where and how the N26 web app talks to its backend (`Fixtures/N26/endpoints.md`, HAR of `app.n26.com`).
///
/// - All data comes from one GraphQL endpoint: `POST https://app.n26.com/graphql?op=<operationName>`,
///   body `{operationName, variables: {payload: <SJCL JSON>}, query}`, headers `csrf-token`,
///   `x-requested-with: XMLHttpRequest`, cookies of `.n26.com` (session: `n26.token`, 15 min; `num26refresh`, 2 h).
/// - `csrf-token` is **not** the `n26.csrf` cookie but the token of `<meta name="csrf-token">` in the HTML,
///   `window.__PEK__` (the payload key) sits in the same HTML. Both are taken from the login page at the end
///   of the web login (`storageKeys`, protocol v3 `.javaScript`) and otherwise read from `bootstrapPath`.
public struct N26Endpoints: Sendable, Equatable {
    public var origin: URL
    public var loginPath: String
    public var graphqlPath: String
    /// HTML page holding `<meta name="csrf-token">` and `window.__PEK__`.
    /// UNVERIFIED with a logged-in session: the HAR only shows the anonymous login page; `/` is expected to
    /// render the feed (or redirect to `/login`, which carries both values as well).
    public var bootstrapPath: String
    public var sessionCookie: String
    public var cookieDomains: [String]
    /// Pseudo-cookie names of the values handed over by the web login (never sent as cookies).
    public var csrfStorageKey: String
    public var pekStorageKey: String

    public static let production = N26Endpoints(
        origin: literalURL("https://app.n26.com"),
        loginPath: "/login",
        graphqlPath: "/graphql",
        bootstrapPath: "/",
        sessionCookie: "n26.token",
        cookieDomains: ["n26.com"],
        csrfStorageKey: "n26.csrfToken",
        pekStorageKey: "n26.pek"
    )

    var host: String { origin.host() ?? "app.n26.com" }

    private static func literalURL(_ string: StaticString) -> URL {
        guard let url = URL(string: "\(string)") else {
            // Programming error: only called with the hard-coded, well-formed literal above.
            fatalError("Ungültige URL-Konstante")
        }
        return url
    }

    func url(_ path: String, query: [URLQueryItem] = []) throws(ConnectorError) -> URL {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw .formatChanged(detail: "N26: Basis-URL ungültig")
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw .formatChanged(detail: "N26: URL ungültig") }
        return url
    }

    func graphqlURL(operation: String) throws(ConnectorError) -> URL {
        try url(graphqlPath, query: [URLQueryItem(name: "op", value: operation)])
    }

    /// Headless login request (protocol v4). Completion: the session cookie `n26.token` is set by the last
    /// `verifyLoginWithPush` answer after the user confirmed in the N26 app.
    public var loginRequest: WebLoginRequest {
        let loginURL = (try? url(loginPath)) ?? origin
        return WebLoginRequest(
            url: loginURL,
            completion: .cookiesPresent([sessionCookie]),
            cookieDomains: cookieDomains,
            message: String(localized: "Bitte bei N26 anmelden und in der N26-App bestätigen.", bundle: .module),
            storageKeys: [
                .javaScript(key: csrfStorageKey, expression: #"document.querySelector('meta[name="csrf-token"]')?.content"#, domain: host),
                .javaScript(key: pekStorageKey, expression: "window.__PEK__", domain: host),
            ],
            automation: WebLoginAutomation(script: N26LoginScript.source, message: N26LoginScript.loginMessage, timeout: 300)
        )
    }
}
