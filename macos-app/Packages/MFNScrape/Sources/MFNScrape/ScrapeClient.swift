import Foundation
import MFNCore

/// JSON client for the web-banking API behind a bank's single-page app.
///
/// - Sends the session cookies (from `WebLoginSession`) and keeps `Set-Cookie` updates.
/// - 401/403 → `sessionExpired` (the connector then asks `WebLoginSession` for a new login;
///   the client itself never logs in and never retries a login).
/// - 429 / 5xx / network errors → backoff retries up to `policy.maxAttempts`, then
///   `rateLimited` / `bankUnavailable`. After 3 failed requests in a row the client refuses
///   further requests in this sync (CLAUDE.md §1).
/// - Undecodable JSON → `formatChanged` with the coding path, never values.
public actor ScrapeClient {
    public static let maximumConsecutiveFailures = 3

    private let transport: any HTTPTransport
    private let policy: BackoffPolicy
    private let sleeper: any Sleeper
    private let userAgent: String
    private var cookies: [SessionCookie]
    private var consecutiveFailures = 0

    private static let log = Log.logger("scrape")

    public init(
        cookies: [SessionCookie],
        transport: any HTTPTransport = URLSessionTransport(),
        policy: BackoffPolicy = BackoffPolicy(),
        sleeper: any Sleeper = TaskSleeper(),
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    ) {
        self.cookies = cookies
        self.transport = transport
        self.policy = policy
        self.sleeper = sleeper
        self.userAgent = userAgent
    }

    /// Cookies after the requests so far (persist them via `SessionCookieStore` after a sync).
    public var currentCookies: [SessionCookie] { cookies }

    // MARK: - Requests

    /// GET returning decoded JSON and the raw body (for `Transaction.rawJSON`).
    public func get<T: Decodable & Sendable>(_ url: URL, as type: T.Type, headers: [String: String] = [:]) async throws(ConnectorError) -> (value: T, raw: Data) {
        let data = try await data(url, method: "GET", body: nil, headers: headers)
        return (try Self.decode(type, from: data, url: url), data)
    }

    /// POST with a JSON body, returning decoded JSON and the raw body.
    public func post<Body: Encodable & Sendable, T: Decodable & Sendable>(_ url: URL, json body: Body, as type: T.Type, headers: [String: String] = [:]) async throws(ConnectorError) -> (value: T, raw: Data) {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw .formatChanged(detail: "Anfrage nicht kodierbar: \(type)")
        }
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        let data = try await data(url, method: "POST", body: encoded, headers: allHeaders)
        return (try Self.decode(type, from: data, url: url), data)
    }

    /// Raw response body (PDFs, CSV exports, non-JSON endpoints).
    public func data(_ url: URL, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws(ConnectorError) -> Data {
        guard consecutiveFailures < Self.maximumConsecutiveFailures else { throw .bankUnavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let cookieHeader = Self.cookieHeader(cookies, for: url) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        var lastError: ConnectorError = .bankUnavailable
        for attempt in 1...policy.maxAttempts {
            if attempt > 1 {
                let retryAfter: TimeInterval? = if case let .rateLimited(seconds) = lastError { seconds } else { nil }
                do {
                    try await sleeper.sleep(seconds: policy.delay(beforeAttempt: attempt, retryAfter: retryAfter))
                } catch {
                    throw .cancelled
                }
            }
            do {
                let (data, response) = try await transport.send(request)
                storeCookies(from: response, url: url)
                Self.log.info("\(method, privacy: .public) \(url.host() ?? "?", privacy: .public) → \(response.statusCode, privacy: .public)")
                switch response.statusCode {
                case 200..<300:
                    consecutiveFailures = 0
                    return data
                case 401, 403:
                    consecutiveFailures += 1
                    throw ConnectorError.sessionExpired
                case 429:
                    lastError = .rateLimited(retryAfter: Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60)
                case 500..<600:
                    lastError = .bankUnavailable
                default:
                    consecutiveFailures += 1
                    throw ConnectorError.formatChanged(detail: "HTTP \(response.statusCode) für \(url.path())")
                }
            } catch let error as ConnectorError {
                throw error
            } catch is CancellationError {
                throw .cancelled
            } catch let error as URLError where error.code == .cancelled {
                throw .cancelled
            } catch {
                lastError = .bankUnavailable
            }
        }
        consecutiveFailures += 1
        throw lastError
    }

    // MARK: - Cookies

    private func storeCookies(from response: HTTPURLResponse, url: URL) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        let received = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        for cookie in received {
            cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if let expires = cookie.expiresDate, expires < Date() { continue }
            cookies.append(SessionCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, expires: cookie.expiresDate, isSecure: cookie.isSecure, isHTTPOnly: cookie.isHTTPOnly))
        }
    }

    static func cookieHeader(_ cookies: [SessionCookie], for url: URL, now: Date = Date()) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.path().isEmpty ? "/" : url.path()
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainMatches = host == domain || host.hasSuffix("." + domain)
            let pathMatches = path.hasPrefix(cookie.path)
            let secureOK = !cookie.isSecure || url.scheme == "https"
            let fresh = cookie.expires.map { $0 > now } ?? true
            return domainMatches && pathMatches && secureOK && fresh
        }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - Decoding

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, url: URL) throws(ConnectorError) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw .formatChanged(detail: "\(url.path()): Feld fehlt \(path(context.codingPath + [key]))")
        } catch let DecodingError.typeMismatch(_, context) {
            throw .formatChanged(detail: "\(url.path()): Typ geändert bei \(path(context.codingPath))")
        } catch let DecodingError.valueNotFound(_, context) {
            throw .formatChanged(detail: "\(url.path()): Wert fehlt bei \(path(context.codingPath))")
        } catch {
            throw .formatChanged(detail: "\(url.path()): kein gültiges JSON")
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}
