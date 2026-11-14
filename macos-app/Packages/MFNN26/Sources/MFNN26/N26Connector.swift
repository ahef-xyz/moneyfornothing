import CryptoKit
import Foundation
import MFNCore
import MFNScrape

/// N26: main account and Spaces via the GraphQL API of the web app (`app.n26.com`, `Fixtures/N26/endpoints.md`).
/// Read-only: only the two feed queries `getTransactionsList` and `getTimeline` are sent.
///
/// Login (protocol v4, headless): `AuthChallenge.webLogin` with `N26LoginScript` – the hidden web view fills the
/// login form with the stored e-mail/password, the user confirms the push in the N26 app, completion is the
/// `n26.token` cookie. The CSRF token (`<meta name="csrf-token">`) and the payload key (`window.__PEK__`) come along
/// as `storageKeys`; if they are missing or rejected they are read again from the HTML (`bootstrapPath`).
///
/// Every request encrypts its variables like the web app (`N26PayloadCipher`). Answers are plain JSON.
///
/// Session flow (like C24): `accounts()` starts a sync and validates the stored session with the overview query.
/// Rejected → stale CSRF/key are refreshed once; still rejected → session discarded, one interactive login
/// (without presenter: `authRequired(.webLogin)`). A fresh login the bank rejects → `authFailed` (never retried).
/// Expiry mid-sync → session discarded, `sessionExpired`.
public actor N26Connector: BankConnector {
    public nonisolated let id: ConnectorID = .n26
    public nonisolated let connectionID: ConnectionID

    /// Upper bound for timeline pages per account and sync (protects against paging loops).
    static let maximumPages = 500
    /// Pages are ordered by transaction time; keep a few days of slack before stopping at `since`.
    static let pagingSlackDays = 3
    /// History on the first import (the web app pages through the complete history).
    static let initialHistoryMonths = 24

    private let endpoints: N26Endpoints
    private let session: WebLoginSession
    private let transport: any HTTPTransport
    private let policy: BackoffPolicy
    private let sleeper: any Sleeper
    private let now: @Sendable () -> Date

    private var active: ActiveSession?
    private var login: Task<ActiveSession, any Error>?
    /// Account switcher of the overview, loaded with the session check at the start of a sync.
    private var overview: [N26Feed.Activity]?
    private var catalog: [AccountID: Entry] = [:]
    /// Balance and first timeline page per account, loaded once per sync.
    private var feeds: [AccountID: FeedSnapshot] = [:]

    private static let log = Log.logger("n26")

    struct Entry: Sendable {
        /// N26 account ID (UUID) – the `accountId` variable of the queries.
        var n26ID: String
        var account: Account
    }

    struct FeedSnapshot: Sendable {
        var balance: N26Money?
        var firstPage: N26TimelinePage
    }

    struct ActiveSession: Sendable {
        var client: ScrapeClient
        var csrfToken: String
        var pek: String
        var cipher: N26PayloadCipher
    }

    public init(
        connectionID: ConnectionID,
        presenter: (any AuthChallengePresenter)?,
        cookieStore: any SessionCookieStore = KeychainSessionCookieStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: N26Endpoints = .production,
        policy: BackoffPolicy = BackoffPolicy(),
        sleeper: any Sleeper = TaskSleeper(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.connectionID = connectionID
        self.endpoints = endpoints
        self.transport = transport
        self.policy = policy
        self.sleeper = sleeper
        self.now = now
        session = WebLoginSession(key: "n26.\(connectionID.rawValue)", request: endpoints.loginRequest, presenter: presenter, store: cookieStore)
    }

    // MARK: - BankConnector

    public func accounts() async throws -> [Account] {
        // Start of a sync: validate the session anew, reload the feeds.
        active = nil
        overview = nil
        feeds = [:]
        let accounts = try await loadAccounts()
        Self.log.info("N26: \(accounts.count, privacy: .public) Konten")
        return accounts
    }

    public func balance(for account: Account) async throws -> Balance {
        let entry = try await entry(for: account)
        guard let money = try await feed(for: entry).balance else {
            throw ConnectorError.formatChanged(detail: "N26 Saldo: balance fehlt")
        }
        return Balance(bookedCents: try money.cents(context: "Saldo"), currency: money.currency?.code ?? entry.account.currency, asOf: now())
    }

    public func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        let entry = try await entry(for: account)
        let from = since.map(BankDay.init) ?? BankDay(now()).adding(months: -Self.initialHistoryMonths)
        let stopBefore = from.adding(days: -Self.pagingSlackDays)

        var page = try await feed(for: entry).firstPage
        var result: [Transaction] = []
        var seenKeys = Set<String>()
        for pageIndex in 0..<Self.maximumPages {
            for item in page.items {
                if let owner = item.value.accountId, !owner.isEmpty, owner != entry.n26ID { continue } // other account
                result.append(try N26Mapper.transaction(item.value, raw: item.raw, account: entry.account))
            }
            guard let key = page.paginationKey else { break }
            if let oldest = page.items.last?.value.timestamp,
               BankDay(Date(timeIntervalSince1970: TimeInterval(oldest) / 1000)) < stopBefore { break }
            guard seenKeys.insert(key).inserted, pageIndex < Self.maximumPages - 1 else {
                throw ConnectorError.formatChanged(detail: "N26 Umsätze: Paging endet nicht")
            }
            let data = try await send(operation: "getTimeline", query: N26Queries.timeline, variables: ["paginationKey": key, "accountId": entry.n26ID])
            page = try N26TimelinePage(timelineContainer: data["timeline"] as? [String: Any], context: "Timeline")
        }

        // Pending transactions may be returned regardless of `since` (BankConnector contract).
        let filtered = result.filter { $0.status == .pending || $0.effectiveDate >= from }
        Self.log.info("N26: \(filtered.count, privacy: .public) Umsätze")
        return Transaction.uniquingIDs(filtered)
    }

    public func cardStatements(for account: Account) async throws -> [CardStatement] {
        _ = try await entry(for: account)
        return [] // The N26 card books on the main account; no card account, no statements.
    }

    public func securities(for account: Account) async throws -> [SecurityPosition] {
        _ = try await entry(for: account)
        return [] // Not in the feed (N26 trading is out of scope).
    }

    // MARK: - Accounts

    private func entry(for account: Account) async throws -> Entry {
        guard account.connectionID == connectionID else { throw ConnectorError.unsupportedAccount }
        if let entry = catalog[account.id] { return entry }
        _ = try await loadAccounts()
        guard let entry = catalog[account.id] else { throw ConnectorError.unsupportedAccount }
        return entry
    }

    private func loadAccounts() async throws -> [Account] {
        _ = try await activeSession() // the session check loads the overview
        let activities: [N26Feed.Activity]
        if let overview {
            activities = overview
        } else {
            activities = try await loadOverview()
        }

        var entries: [Entry] = []
        for activity in activities {
            guard let n26ID = Self.nonEmpty(activity.accountId) else { continue } // „Alle Aktivitäten“
            let type: AccountType
            let fallback: String
            switch activity.kind {
            case .main, .all:
                (type, fallback) = (.giro, "N26 Hauptkonto")
            case .space:
                (type, fallback) = (.tagesgeld, "N26 Space")
            case let .unknown(label):
                // Unknown product: keep it visible rather than dropping money silently.
                Self.log.notice("N26: unbekannter Kontotyp '\(label, privacy: .public)'")
                (type, fallback) = (.giro, "N26 Konto")
            }
            let account = Account(
                id: Self.accountID(connection: connectionID, n26ID: n26ID),
                connectionID: connectionID,
                type: type,
                currency: "EUR", // N26 Germany: EUR accounts; the switcher carries no currency.
                name: Self.nonEmpty(activity.title) ?? fallback
            )
            entries.append(Entry(n26ID: n26ID, account: account))
        }
        catalog = Dictionary(entries.map { ($0.account.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<AccountID>()
        return entries.map(\.account).filter { seen.insert($0.id).inserted }
    }

    private func loadOverview() async throws -> [N26Feed.Activity] {
        let data = try await send(operation: "getTransactionsList", query: N26Queries.transactionsList, variables: ["accountId": NSNull()])
        let activities = try Self.activities(in: data)
        overview = activities
        return activities
    }

    private static func activities(in data: [String: Any]) throws(ConnectorError) -> [N26Feed.Activity] {
        // Explicit `null` without errors: the bank answered but gave nothing – an expired session.
        if data["feed"] is NSNull { throw .sessionExpired }
        guard let feed = data["feed"] as? [String: Any] else { throw .formatChanged(detail: "N26 Konten: feed fehlt") }
        let decoded = try N26JSON.decode(N26Feed.self, from: feed, context: "Konten")
        guard let values = decoded.activities?.values else { throw .formatChanged(detail: "N26 Konten: activities fehlt") }
        return values
    }

    private func feed(for entry: Entry) async throws -> FeedSnapshot {
        if let cached = feeds[entry.account.id] { return cached }
        let data = try await send(operation: "getTransactionsList", query: N26Queries.transactionsList, variables: ["accountId": entry.n26ID])
        if data["feed"] is NSNull { throw ConnectorError.sessionExpired }
        guard let feed = data["feed"] as? [String: Any] else { throw ConnectorError.formatChanged(detail: "N26 Feed: feed fehlt") }
        let decoded = try N26JSON.decode(N26Feed.self, from: feed, context: "Feed")
        let snapshot = FeedSnapshot(balance: decoded.balance?.money, firstPage: try N26TimelinePage.fromFeed(feed))
        feeds[entry.account.id] = snapshot
        return snapshot
    }

    /// Deterministic and opaque (IDs may be logged).
    static func accountID(connection: ConnectionID, n26ID: String) -> AccountID {
        let digest = SHA256.hash(data: Data("\(connection.rawValue)|\(n26ID.lowercased())".utf8))
        return AccountID("n26-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined())
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Requests

    /// GraphQL request with session handling; returns `data`.
    private func send(operation: String, query: String, variables: [String: Any]) async throws -> [String: Any] {
        let current = try await activeSession()
        do {
            let (data, used) = try await exchange(current, operation: operation, query: query, variables: variables)
            active = used
            return data
        } catch ConnectorError.sessionExpired {
            Self.log.notice("N26: Sitzung abgelaufen")
            active = nil
            try await session.invalidate()
            throw ConnectorError.sessionExpired
        }
    }

    /// One request; if the bank rejects it in a way stale CSRF token or payload key can explain (401/403, HTTP 4xx,
    /// GraphQL „401 Unauthorized“), both are read again from the HTML and the request is repeated once.
    private func exchange(_ session: ActiveSession, operation: String, query: String, variables: [String: Any]) async throws -> (data: [String: Any], session: ActiveSession) {
        do {
            return (try await perform(session, operation: operation, query: query, variables: variables), session)
        } catch let error as ConnectorError where Self.mayBeStaleKeys(error) {
            Self.log.notice("N26: Anfrage abgelehnt, lade CSRF-Token und Schlüssel neu")
            let refreshed = try await bootstrap(session.client)
            return (try await perform(refreshed, operation: operation, query: query, variables: variables), refreshed)
        }
    }

    private static func mayBeStaleKeys(_ error: ConnectorError) -> Bool {
        switch error {
        case .sessionExpired: true
        case let .formatChanged(detail): detail.hasPrefix("HTTP 4")
        default: false
        }
    }

    private func perform(_ session: ActiveSession, operation: String, query: String, variables: [String: Any]) async throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(variables),
              let plain = try? JSONSerialization.data(withJSONObject: variables, options: [.withoutEscapingSlashes])
        else {
            throw ConnectorError.formatChanged(detail: "N26: Variablen nicht kodierbar")
        }
        let payload = try session.cipher.encrypt(plain, timestampMillis: Int64(now().timeIntervalSince1970 * 1000))
        let envelope: [String: Any] = ["operationName": operation, "variables": ["payload": payload], "query": query]
        guard let body = try? JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes]) else {
            throw ConnectorError.formatChanged(detail: "N26: Anfrage nicht kodierbar")
        }
        let headers = [
            "Content-Type": "application/json",
            "csrf-token": session.csrfToken,
            "x-requested-with": "XMLHttpRequest",
            "Origin": endpoints.origin.absoluteString,
            "Referer": (try? endpoints.url("/feed").absoluteString) ?? endpoints.origin.absoluteString,
        ]
        let data = try await session.client.data(try endpoints.graphqlURL(operation: operation), method: "POST", body: body, headers: headers)
        try await persist(session)
        return try N26JSON.data(data, operation: operation)
    }

    // MARK: - Session

    private func activeSession() async throws -> ActiveSession {
        if let active { return active }
        if let login { return try await login.value }
        let task = Task { try await self.startSession() }
        login = task
        defer { login = nil }
        let session = try await task.value
        active = session
        return session
    }

    /// Validates the stored session with the overview query; asks for one login if there is none or it is stale.
    private func startSession() async throws -> ActiveSession {
        if let stored = try await session.storedCookies() {
            do {
                let checked = try await check(try await makeSession(stored))
                Self.log.info("N26: gespeicherte Sitzung gültig")
                return checked
            } catch ConnectorError.sessionExpired {
                Self.log.notice("N26: gespeicherte Sitzung abgelaufen, neue Anmeldung nötig")
                try await session.invalidate()
            }
        }
        let fresh = try await makeSession(try await session.cookies(forceLogin: true))
        do {
            let checked = try await check(fresh)
            Self.log.info("N26: angemeldet")
            return checked
        } catch ConnectorError.sessionExpired {
            // The bank rejects a session that was just established: do not try again.
            try await session.invalidate()
            throw ConnectorError.authFailed
        }
    }

    private func check(_ candidate: ActiveSession) async throws -> ActiveSession {
        let (data, used) = try await exchange(candidate, operation: "getTransactionsList", query: N26Queries.transactionsList, variables: ["accountId": NSNull()])
        overview = try Self.activities(in: data)
        return used
    }

    /// Session from the web-login hand-over: cookies plus the CSRF token / payload key pseudo-cookies.
    private func makeSession(_ cookies: [SessionCookie]) async throws -> ActiveSession {
        let storageNames: Set<String> = [endpoints.csrfStorageKey, endpoints.pekStorageKey]
        let plain = cookies.filter { !storageNames.contains($0.name) }
        let client = ScrapeClient(cookies: plain, transport: transport, policy: policy, sleeper: sleeper)
        if let csrf = cookies.first(where: { $0.name == endpoints.csrfStorageKey }).flatMap({ Self.nonEmpty($0.value) }),
           let pek = cookies.first(where: { $0.name == endpoints.pekStorageKey }).flatMap({ Self.nonEmpty($0.value) }),
           let cipher = try? N26PayloadCipher(pek: pek) {
            return ActiveSession(client: client, csrfToken: csrf, pek: pek, cipher: cipher)
        }
        return try await bootstrap(client)
    }

    /// Reads CSRF token and payload key from the web app's HTML.
    /// UNVERIFIED: `bootstrapPath` with a logged-in session (see `N26Endpoints.bootstrapPath`).
    private func bootstrap(_ client: ScrapeClient) async throws -> ActiveSession {
        let html = try await client.data(try endpoints.url(endpoints.bootstrapPath), headers: ["Accept": "text/html,application/xhtml+xml"])
        guard let page = String(data: html, encoding: .utf8), let values = N26Bootstrap.parse(page) else {
            throw ConnectorError.formatChanged(detail: "N26: csrf-token/__PEK__ nicht gefunden")
        }
        let session = ActiveSession(client: client, csrfToken: values.csrfToken, pek: values.pek, cipher: try N26PayloadCipher(pek: values.pek))
        try await persist(session)
        return session
    }

    /// Writes cookie updates (`Set-Cookie`) back to the keychain, together with CSRF token and payload key.
    private func persist(_ candidate: ActiveSession) async throws(ConnectorError) {
        let host = endpoints.host
        let extras = [
            SessionCookie(name: endpoints.csrfStorageKey, value: candidate.csrfToken, domain: host, isHTTPOnly: false),
            SessionCookie(name: endpoints.pekStorageKey, value: candidate.pek, domain: host, isHTTPOnly: false),
        ]
        try await session.update(await candidate.client.currentCookies + extras)
    }
}

/// `<meta name="csrf-token" content="…">` and `window.__PEK__ = '…'` from the server-rendered HTML.
enum N26Bootstrap {
    static func parse(_ html: String) -> (csrfToken: String, pek: String)? {
        guard let csrf = firstMatch(#"<meta[^>]*name="csrf-token"[^>]*content="([^"]+)""#, in: html)
                ?? firstMatch(#"<meta[^>]*content="([^"]+)"[^>]*name="csrf-token""#, in: html),
              let pek = firstMatch(#"window\.__PEK__\s*=\s*['"]([A-Za-z0-9+/=]+)['"]"#, in: html)
        else { return nil }
        return (csrf, pek)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
