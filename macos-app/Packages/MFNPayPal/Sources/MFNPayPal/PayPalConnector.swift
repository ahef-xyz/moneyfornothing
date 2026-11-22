import Foundation
import MFNCore
import MFNScrape

/// PayPal through its website (personal accounts; the official API is for business accounts).
///
/// - Login: visible web login in the app (`WebLoginSession`, no script). PayPal protects the
///   login with bot detection, reCAPTCHA and a device fingerprint, so the user logs in and MFN
///   takes the cookies, which are reused until PayPal rejects them. Automatic syncs never log in:
///   the app's presenter throws `authRequired` there. The connector never sees the password.
/// - Accounts and balances: the JSON the summary page carries, one account per currency.
/// - Transactions: the activity list (`/myaccount/activities/filter`) one year per request with a pause in
///   between, three years back on the first import. Its CSRF token comes from the activity page's state.
/// - A session PayPal refuses right after the login is `formatChanged`, not a reason for a
///   second login (lockout risk); one that timed out is replaced once in the same sync.
/// - Read-only: three GET requests, nothing else.
public actor PayPalConnector: BankConnector {
    public nonisolated let id: ConnectorID = .paypal

    private let connectionID: ConnectionID
    private let session: WebLoginSession?
    /// No presenter (tests, conformance): an expired session ends the sync with `sessionExpired`.
    private let canLogIn: Bool
    private let transport: any HTTPTransport
    private let policy: BackoffPolicy
    private let sleeper: any Sleeper
    private let now: @Sendable () -> Date

    private var client: ScrapeClient?
    /// The session came straight from a login and has not answered a request yet.
    private var clientIsFresh = false
    /// This run already replaced a timed-out session: a second expiry ends the sync.
    private var didRelogin = false
    private var extras: [SessionCookie] = []
    private var wallets: [AccountID: PayPalParser.Wallet] = [:]
    private var csrf: String?
    /// The list rows of this run from `from` on: every currency's account reads the same list.
    private var fetched: (from: BankDay, rows: [PayPalParser.Row])?

    public init(
        connectionID: ConnectionID,
        presenter: (any AuthChallengePresenter)?,
        store: any SessionCookieStore = KeychainSessionCookieStore(),
        transport: any HTTPTransport = URLSessionTransport(timeout: 20),
        // One attempt: a request PayPal does not answer is not asked again in the same sync.
        policy: BackoffPolicy = BackoffPolicy(maxAttempts: 1),
        sleeper: any Sleeper = TaskSleeper(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connectionID = connectionID
        self.canLogIn = presenter != nil
        self.session = PayPalEndpoints.loginRequest().map {
            WebLoginSession(key: "paypal.\(connectionID.rawValue)", request: $0, presenter: presenter, store: store)
        }
        self.transport = transport
        self.policy = policy
        self.sleeper = sleeper
        self.now = now
    }

    // MARK: - BankConnector

    public func accounts() async throws(ConnectorError) -> [Account] {
        let connectionID = connectionID
        let time = now()
        // A sync starts with the accounts: this one may replace a timed-out session once.
        didRelogin = false
        let found = try await read(PayPalEndpoints.url(PayPalEndpoints.summary), headers: PayPalEndpoints.headers()) { data throws(ConnectorError) in
            try Self.page(data) { html throws(ConnectorError) in try PayPalParser.wallets(summary: html, connectionID: connectionID, now: time) }
        }
        wallets = Dictionary(found.map { ($0.account.id, $0) }, uniquingKeysWith: { first, _ in first })
        fetched = nil
        PayPalParser.log.info("PayPal: \(found.count, privacy: .public) Konten")
        return found.map(\.account)
    }

    public func balance(for account: Account) async throws(ConnectorError) -> Balance {
        if wallets[account.id] == nil { _ = try await accounts() }
        guard let wallet = wallets[account.id] else { throw .unsupportedAccount }
        return wallet.balance
    }

    public func transactions(for account: Account, since: Date?) async throws(ConnectorError) -> [Transaction] {
        let today = BankDay(now())
        let oldest = today.adding(days: -PayPalEndpoints.historyDays)
        let from = max(since.map(BankDay.init) ?? oldest, oldest)
        let rows = try await rows(from: from, to: today)
        let transactions = try PayPalParser.transactions(rows, account: account)
        PayPalParser.log.info("PayPal: \(transactions.count, privacy: .public) Umsätze")
        guard since != nil else { return transactions }
        return transactions.filter { $0.status == .pending || $0.effectiveDate >= from }
    }

    public func cardStatements(for account: Account) async throws(ConnectorError) -> [CardStatement] {
        []
    }

    public func securities(for account: Account) async throws(ConnectorError) -> [SecurityPosition] {
        []
    }

    // MARK: - Private

    private func rows(from: BankDay, to today: BankDay) async throws(ConnectorError) -> [PayPalParser.Row] {
        if let fetched, fetched.from <= from { return fetched.rows }
        var rows: [PayPalParser.Row] = []
        var start = from
        while start <= today {
            // Never a burst of list requests (see `PayPalEndpoints.windowDays`).
            if start != from {
                do {
                    try await sleeper.sleep(seconds: PayPalEndpoints.pauseSeconds)
                } catch {
                    throw .cancelled
                }
            }
            let end = min(start.adding(days: PayPalEndpoints.windowDays - 1), today)
            let token = try await csrfToken()
            rows += try await read(PayPalEndpoints.filterURL(from: start, to: end), headers: PayPalEndpoints.headers(csrf: token)) { data throws(ConnectorError) in
                do throws(ConnectorError) {
                    return try PayPalParser.rows(data)
                } catch {
                    // The login page instead of JSON: the session is gone.
                    if PayPalParser.isLoginPage(String(decoding: data.prefix(200_000), as: UTF8.self)) { throw .sessionExpired }
                    throw error
                }
            }
            start = end.adding(days: 1)
        }
        fetched = (from, rows)
        return rows
    }

    /// One load of the activity page per run (and one more after a new login).
    private func csrfToken() async throws(ConnectorError) -> String {
        if let csrf { return csrf }
        let token = try await read(PayPalEndpoints.url(PayPalEndpoints.activities), headers: PayPalEndpoints.headers()) { data throws(ConnectorError) in
            try Self.page(data) { html throws(ConnectorError) in
                guard let token = PayPalParser.csrfToken(in: html) else { throw .formatChanged(detail: "activities: Token nicht gefunden") }
                return token
            }
        }
        csrf = token
        return token
    }

    /// Parses a page; one that lacks what is expected and is the login form means the session
    /// is gone.
    private static func page<T>(_ data: Data, parse: (String) throws(ConnectorError) -> T) throws(ConnectorError) -> T {
        let html = String(decoding: data, as: UTF8.self)
        do throws(ConnectorError) {
            return try parse(html)
        } catch {
            if PayPalParser.isLoginPage(html) { throw .sessionExpired }
            throw error
        }
    }

    private func scrapeClient(forceLogin: Bool = false) async throws(ConnectorError) -> ScrapeClient {
        if let client, !forceLogin { return client }
        guard let session else { throw .formatChanged(detail: "Login-URL ungültig") }
        let stored = forceLogin ? nil : try await session.storedCookies()
        let cookies = try await session.cookies(forceLogin: forceLogin)
        clientIsFresh = stored == nil
        extras = cookies.filter { $0.name == PayPalEndpoints.userAgentName }
        let plain = cookies.filter { $0.name != PayPalEndpoints.userAgentName }
        let client: ScrapeClient
        // The browser that logged in, where the app handed its name over.
        if let agent = extras.first?.value, !agent.isEmpty {
            client = ScrapeClient(cookies: plain, transport: transport, policy: policy, sleeper: sleeper, userAgent: agent, allowedHosts: [PayPalEndpoints.host])
        } else {
            client = ScrapeClient(cookies: plain, transport: transport, policy: policy, sleeper: sleeper, allowedHosts: [PayPalEndpoints.host])
        }
        self.client = client
        return client
    }

    /// GET and parse. A session PayPal rejects is forgotten; one that worked before is replaced
    /// by a new login once, one straight from the login is not (no second login).
    private func read<T: Sendable>(_ url: URL?, headers: [String: String],
                                   parse: @Sendable (Data) throws(ConnectorError) -> T) async throws(ConnectorError) -> T {
        guard let url else { throw .formatChanged(detail: "URL ungültig") }
        var client = try await scrapeClient()
        let value: T
        do {
            value = try parse(try await client.data(url, headers: headers))
        } catch .sessionExpired {
            let wasFresh = clientIsFresh
            self.client = nil
            csrf = nil
            try? await session?.invalidate()
            if wasFresh { throw Self.freshSessionRefused }
            // Never a second login window in one sync.
            guard canLogIn, !didRelogin else { throw .sessionExpired }
            didRelogin = true
            PayPalParser.log.notice("PayPal: gespeicherte Sitzung abgelaufen, neue Anmeldung")
            client = try await scrapeClient(forceLogin: true)
            var retryHeaders = headers
            // The token belongs to the old session.
            if headers["x-csrf-token"] != nil { retryHeaders = PayPalEndpoints.headers(csrf: try await csrfToken()) }
            do {
                value = try parse(try await client.data(url, headers: retryHeaders))
            } catch .sessionExpired {
                self.client = nil
                csrf = nil
                try? await session?.invalidate()
                throw Self.freshSessionRefused
            }
        }
        clientIsFresh = false
        try await session?.update(await client.currentCookies + extras)
        return value
    }

    private static let freshSessionRefused = ConnectorError.formatChanged(detail: "Sitzung direkt nach der Anmeldung abgelehnt")
}
