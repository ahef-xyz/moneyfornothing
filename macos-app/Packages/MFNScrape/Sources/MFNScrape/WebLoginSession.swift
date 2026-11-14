import Foundation
import MFNCore
import Synchronization

/// Where session cookies are kept between syncs. Production: keychain.
public protocol SessionCookieStore: Sendable {
    func load(_ key: String) throws(ConnectorError) -> [SessionCookie]?
    func save(_ cookies: [SessionCookie], for key: String) throws(ConnectorError)
    func delete(_ key: String) throws(ConnectorError)
}

/// Session cookies in the keychain (`WhenUnlockedThisDeviceOnly`, CLAUDE.md §6).
/// A keychain failure degrades to "no stored session" (→ interactive login next time) and is
/// logged; it never blocks a sync.
public struct KeychainSessionCookieStore: SessionCookieStore {
    private let keychain: Keychain

    public init(keychain: Keychain = Keychain(service: ConnectionSecrets.sessionService)) {
        self.keychain = keychain
    }

    public func load(_ key: String) throws(ConnectorError) -> [SessionCookie]? {
        do {
            return try keychain.value([SessionCookie].self, for: key)
        } catch {
            Log.logger("scrape").error("Sitzung nicht lesbar: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    public func save(_ cookies: [SessionCookie], for key: String) throws(ConnectorError) {
        do {
            try keychain.set(cookies, for: key)
        } catch {
            Log.logger("scrape").error("Sitzung nicht speicherbar: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    public func delete(_ key: String) throws(ConnectorError) {
        do {
            try keychain.delete(key)
        } catch {
            Log.logger("scrape").error("Sitzung nicht löschbar: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

/// In-memory store for tests.
public final class InMemorySessionCookieStore: SessionCookieStore {
    private let storage: Mutex<[String: [SessionCookie]]>

    public init(_ initial: [String: [SessionCookie]] = [:]) {
        storage = Mutex(initial)
    }

    public func load(_ key: String) throws(ConnectorError) -> [SessionCookie]? {
        storage.withLock { $0[key] }
    }

    public func save(_ cookies: [SessionCookie], for key: String) throws(ConnectorError) {
        storage.withLock { $0[key] = cookies }
    }

    public func delete(_ key: String) throws(ConnectorError) {
        _ = storage.withLock { $0.removeValue(forKey: key) }
    }
}

/// Login for a scraping connector: reuses stored cookies, otherwise asks the app for an
/// interactive web login (`AuthChallenge.webLogin`). Never retries a failed login by itself.
///
/// Protocol v2: Web Storage entries requested via `WebLoginRequest.storageKeys` arrive as
/// pseudo-cookies (`name` = key, `domain` = storage domain). They are kept and persisted exactly
/// like cookies (keychain only, never logged) and may satisfy `.cookiesPresent`.
public actor WebLoginSession {
    private let key: String
    private let request: WebLoginRequest
    private let presenter: (any AuthChallengePresenter)?
    private let store: any SessionCookieStore

    /// - Parameter key: unique per connection, e.g. `"c24.<connectionID>"`.
    public init(key: String, request: WebLoginRequest, presenter: (any AuthChallengePresenter)?, store: any SessionCookieStore = KeychainSessionCookieStore()) {
        self.key = key
        self.request = request
        self.presenter = presenter
        self.store = store
    }

    /// Stored, unexpired cookies of the configured domains, or `nil`.
    public func storedCookies(now: Date = Date()) throws(ConnectorError) -> [SessionCookie]? {
        guard let cookies = try store.load(key) else { return nil }
        let fresh = cookies.filter { $0.expires.map { $0 > now } ?? true }
        return fresh.isEmpty ? nil : fresh
    }

    /// Cookies for the next requests. `forceLogin` after a `sessionExpired`.
    public func cookies(forceLogin: Bool = false) async throws(ConnectorError) -> [SessionCookie] {
        if !forceLogin, let stored = try storedCookies() { return stored }
        guard let presenter else { throw .authRequired(.webLogin(request)) }

        let response: AuthResponse
        do {
            response = try await presenter.present(.webLogin(request))
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw .cancelled
        }
        guard case let .webSession(all) = response else { throw .authFailed }
        let cookies = Self.filter(all, for: request)
        guard !cookies.isEmpty else { throw .authFailed }
        // Each required name may be a cookie or a storage entry.
        if case let .cookiesPresent(required) = request.completion {
            let names = Set(cookies.map(\.name))
            guard required.allSatisfy(names.contains) else { throw .authFailed }
        }
        try store.save(cookies, for: key)
        return cookies
    }

    /// Persists cookies updated by `ScrapeClient` during a sync.
    public func update(_ cookies: [SessionCookie]) throws(ConnectorError) {
        try store.save(Self.filter(cookies, for: request), for: key)
    }

    /// Forget the session (logout, or the bank rejected it).
    public func invalidate() throws(ConnectorError) {
        try store.delete(key)
    }

    /// Cookies of `request.cookieDomains` plus storage entries of `request.storageKeys` (matched
    /// by key and storage domain, even if that domain is not a cookie domain).
    static func filter(_ cookies: [SessionCookie], for request: WebLoginRequest) -> [SessionCookie] {
        let inDomains = Set(filter(cookies, domains: request.cookieDomains))
        return cookies.filter { cookie in
            inDomains.contains(cookie) || request.storageKeys.contains {
                $0.key == cookie.name && WebLoginCapture.normalize($0.domain) == WebLoginCapture.normalize(cookie.domain)
            }
        }
    }

    static func filter(_ cookies: [SessionCookie], domains: [String]) -> [SessionCookie] {
        let normalized = domains.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return normalized.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }
    }
}
