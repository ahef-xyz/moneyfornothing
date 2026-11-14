import Foundation
import MFNCore

/// Web session of Trade Republic and the authenticated REST client.
///
/// Login (Fixtures/TradeRepublic/endpoints.md): the web app logs in with phone + PIN and an
/// approval in the Trade Republic app (`/api/v2/auth/web/login`, then polling
/// `…/login/processes/{id}`), protected by AWS WAF (`aws-waf-token`). A native login without a
/// browser is expected to be blocked, so MFN logs in through the app's web view
/// (`AuthChallenge.webLogin`, done when cookie `tr_session` exists) and reuses the cookies.
/// Since protocol v4 the web view stays hidden: `TRLoginScript` calls the login API from the
/// page with the stored credentials; the user only confirms in the Trade Republic app.
///
/// - Cookies are persisted in `TRSessionStore` (Keychain) and sent to `*.traderepublic.com`.
/// - `Set-Cookie` on any answer updates the stored cookies (session rotation).
/// - 401/403 → stored session dropped; one new web login per connector instance if a presenter
///   exists, otherwise `authRequired`. A rejected fresh login is `sessionExpired`.
/// - A failed or cancelled login is never retried automatically.
actor TRSession {
    static let sessionCookieName = "tr_session"
    static let wafCookieName = "aws-waf-token"
    static let cookieDomain = "traderepublic.com"
    /// The web app sends `X-TR-App-Version` on every call; without it the API answers HTTP 400.
    /// Read from the public `app-version.txt` once per session, with this fallback.
    static let appVersionURL = URL(string: "https://app.traderepublic.com/app-version.txt")
    static let fallbackAppVersion = "2.2646.7"
    static let webOrigin = "https://app.traderepublic.com"

    static let loginChallenge = AuthChallenge.webLogin(WebLoginRequest(
        url: URL(string: "https://app.traderepublic.com/login") ?? URL(fileURLWithPath: "/"),
        completion: .cookiesPresent([sessionCookieName]),
        cookieDomains: [cookieDomain],
        message: "Bitte bei Trade Republic anmelden und die Anmeldung in der Trade-Republic-App bestätigen.",
        // v4: headless with the stored phone number + PIN (see `TRLoginScript`).
        automation: TRLoginScript.automation
    ))

    private let baseURL: URL
    private let presenter: (any AuthChallengePresenter)?
    private let store: any TRSessionStore
    private let http: any TRHTTPTransport
    private let now: @Sendable () -> Date

    /// `nil` = not loaded from the store yet.
    private var cookies: [SessionCookie]?
    private var appVersion: String?
    private var loggedInThisRun = false
    private var loginTask: Task<[SessionCookie], any Error>?

    init(
        baseURL: URL,
        presenter: (any AuthChallengePresenter)?,
        store: any TRSessionStore,
        http: any TRHTTPTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.baseURL = baseURL
        self.presenter = presenter
        self.store = store
        self.http = http
        self.now = now
    }

    // MARK: - REST

    /// Authenticated `GET`. Returns `nil` only for 404 when `allowNotFound` is set.
    func get(_ path: String, query: [URLQueryItem] = [], allowNotFound: Bool = false) async throws(ConnectorError) -> JSONValue? {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw .formatChanged(detail: "Ungültiger Trade-Republic-Pfad") }

        for _ in 0 ..< 2 {
            let cookies = try await validCookies()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("de", forHTTPHeaderField: "Accept-Language")
            request.setValue(await resolvedAppVersion(), forHTTPHeaderField: "x-tr-app-version")
            request.setValue("web", forHTTPHeaderField: "x-tr-platform")
            request.setValue(Self.webOrigin, forHTTPHeaderField: "Origin")
            request.setValue(Self.webOrigin + "/", forHTTPHeaderField: "Referer")
            request.setValue(Self.cookieHeader(cookies, host: url.host() ?? ""), forHTTPHeaderField: "Cookie")
            if let waf = cookies.first(where: { $0.name == Self.wafCookieName }) {
                request.setValue(waf.value, forHTTPHeaderField: "x-aws-waf-token")
            }

            let (data, response) = try await send(request)
            merge(Self.cookies(from: response))
            switch response.statusCode {
            case 200 ..< 300:
                guard let json = JSONValue.parse(data) else {
                    throw .formatChanged(detail: "Trade-Republic-Antwort ist kein JSON (\(path))")
                }
                return json
            case 404 where allowNotFound:
                return nil
            case 401, 403:
                TRLog.log.info("Trade-Republic-Sitzung abgelehnt (HTTP \(response.statusCode, privacy: .public))")
                invalidate()
                if loggedInThisRun { throw .sessionExpired }
                continue // next round logs in through the web view, or throws authRequired
            default:
                // Path, status and TR error code only – no query values, cookies or body content.
                let code = JSONValue.parse(data)?["errors"]?.array?.first?["errorCode"]?.string ?? "-"
                TRLog.log.error("Trade Republic \(path, privacy: .public) → HTTP \(response.statusCode, privacy: .public), Fehlercode \(code, privacy: .public)")
                throw Self.error(for: response, body: data, path: path)
            }
        }
        throw .sessionExpired
    }

    /// `Cookie` header for the WebSocket upgrade (same session).
    func cookieHeader(for url: URL) async throws(ConnectorError) -> String {
        let host = url.host() ?? "api.\(Self.cookieDomain)"
        return Self.cookieHeader(try await validCookies(), host: host)
    }

    /// Forgets the session after the server rejected it.
    func invalidate() {
        cookies = []
        do { try store.delete() } catch {
            TRLog.log.error("Trade-Republic-Sitzung nicht gelöscht: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Web app version for `X-TR-App-Version`, fetched once from the public `app-version.txt`.
    private func resolvedAppVersion() async -> String {
        if let appVersion { return appVersion }
        var version = Self.fallbackAppVersion
        if let url = Self.appVersionURL {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let (data, response) = try? await http.send(request), response.statusCode == 200,
               let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.range(of: #"^\d+(\.\d+){1,3}$"#, options: .regularExpression) != nil {
                version = text
            }
        }
        appVersion = version
        return version
    }

    // MARK: - Session

    private func validCookies() async throws(ConnectorError) -> [SessionCookie] {
        if cookies == nil { cookies = unexpired(loadStored()) }
        if let cookies, Self.hasSession(cookies) { return cookies }
        return try await login()
    }

    private func login() async throws(ConnectorError) -> [SessionCookie] {
        if let loginTask {
            do { return try await loginTask.value } catch { throw Self.connectorError(error) }
        }
        guard let presenter else { throw .authRequired(Self.loginChallenge) }
        let task = Task { () async throws -> [SessionCookie] in
            try await self.runLogin(presenter)
        }
        loginTask = task
        defer { loginTask = nil }
        do { return try await task.value } catch { throw Self.connectorError(error) }
    }

    private func runLogin(_ presenter: any AuthChallengePresenter) async throws(ConnectorError) -> [SessionCookie] {
        TRLog.log.info("Trade-Republic-Anmeldung im Web-Login gestartet")
        let response: AuthResponse
        do {
            response = try await presenter.present(Self.loginChallenge)
        } catch {
            throw Self.connectorError(error)
        }
        guard case let .webSession(received) = response else {
            TRLog.log.error("Trade-Republic-Anmeldung lieferte keine Web-Sitzung")
            throw .authFailed
        }
        let relevant = unexpired(received.filter { Self.domainMatches($0.domain, host: "api.\(Self.cookieDomain)") })
        guard Self.hasSession(relevant) else {
            TRLog.log.error("Trade-Republic-Anmeldung ohne Sitzungs-Cookie")
            throw .authFailed
        }
        cookies = relevant
        loggedInThisRun = true
        persist()
        TRLog.log.info("Trade-Republic-Anmeldung erfolgreich (\(relevant.count, privacy: .public) Cookies)")
        return relevant
    }

    private func merge(_ updates: [SessionCookie]) {
        guard !updates.isEmpty, var current = cookies else { return }
        for update in updates {
            current.removeAll { $0.name == update.name && $0.domain == update.domain }
            if update.expires.map({ $0 > now() }) ?? true, !update.value.isEmpty { current.append(update) }
        }
        cookies = current
        persist()
    }

    private func persist() {
        do {
            try store.save(cookies ?? [])
        } catch {
            // Sync still works; the next one needs a new login.
            TRLog.log.error("Trade-Republic-Sitzung nicht gespeichert: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func loadStored() -> [SessionCookie] {
        do {
            return try store.load()
        } catch {
            TRLog.log.error("Trade-Republic-Sitzung nicht lesbar: \(String(describing: type(of: error)), privacy: .public)")
            return []
        }
    }

    private func unexpired(_ cookies: [SessionCookie]) -> [SessionCookie] {
        let now = now()
        return cookies.filter { $0.expires.map { $0 > now } ?? true }
    }

    private func send(_ request: URLRequest) async throws(ConnectorError) -> (Data, HTTPURLResponse) {
        do {
            return try await http.send(request)
        } catch {
            let mapped = Self.connectorError(error)
            switch mapped {
            case .cancelled:
                throw .cancelled
            case .formatChanged where !(error is ConnectorError):
                // Any other transport failure: the bank is not reachable.
                TRLog.log.error("Trade Republic nicht erreichbar: \(String(describing: type(of: error)), privacy: .public)")
                throw .bankUnavailable
            default:
                TRLog.log.error("Trade Republic nicht erreichbar: \(mapped.description, privacy: .public)")
                throw mapped
            }
        }
    }

    // MARK: - Helpers

    static func hasSession(_ cookies: [SessionCookie]) -> Bool {
        cookies.contains { $0.name == sessionCookieName && !$0.value.isEmpty }
    }

    static func cookieHeader(_ cookies: [SessionCookie], host: String) -> String {
        cookies.filter { domainMatches($0.domain, host: host) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// RFC 6265 domain match: `traderepublic.com` / `.traderepublic.com` cover `api.traderepublic.com`.
    static func domainMatches(_ domain: String, host: String) -> Bool {
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = host.lowercased()
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix(".\(domain)")
    }

    /// Maps transport and presenter errors. `URLError.cancelled` is a cancel only if the task
    /// was cancelled; otherwise URLSession cancelled it itself (e.g. a refused server trust) and
    /// the bank counts as unreachable. Unknown errors carry no bank text into the detail.
    static func connectorError(_ error: any Error, taskCancelled: Bool = Task.isCancelled) -> ConnectorError {
        if let error = error as? ConnectorError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            return error.code == .cancelled && taskCancelled ? .cancelled : .bankUnavailable
        }
        return .formatChanged(detail: "Trade Republic: unerwarteter Fehler (\(String(describing: type(of: error))))")
    }

    static func error(for response: HTTPURLResponse, body: Data, path: String = "") -> ConnectorError {
        switch response.statusCode {
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            let meta = JSONValue.parse(body)?["errors"]?.array?.first?["meta"]?["nextAttemptInSeconds"]?.int
            return .rateLimited(retryAfter: header ?? meta.map(TimeInterval.init) ?? 60)
        case 500 ..< 600:
            return .bankUnavailable
        default:
            // TR error codes (e.g. VALIDATION_ERROR) carry no personal data and say what is wrong.
            let code = JSONValue.parse(body)?["errors"]?.array?.first?["errorCode"]?.string
            let detail = [path.isEmpty ? nil : path, code].compactMap { $0 }.joined(separator: ", ")
            return .formatChanged(detail: "Trade Republic antwortet mit HTTP \(response.statusCode)" + (detail.isEmpty ? "" : " (\(detail))"))
        }
    }

    static func cookies(from response: HTTPURLResponse) -> [SessionCookie] {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        guard fields.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame }) else { return [] }
        let url = response.url ?? URL(fileURLWithPath: "/")
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map { cookie in
            SessionCookie(
                name: cookie.name,
                value: cookie.value,
                domain: cookie.domain,
                path: cookie.path,
                expires: cookie.expiresDate,
                isSecure: cookie.isSecure,
                isHTTPOnly: cookie.isHTTPOnly
            )
        }
    }
}
