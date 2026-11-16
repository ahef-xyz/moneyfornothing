import Foundation
import MFNCore
import MFNScrape

/// DKB: giro (and savings) accounts via the JSON API behind the web banking `banking.dkb.de`
/// (`Fixtures/DKB/web/endpoints.md`). Bridge until FinTS is registered (protocol v6). Read-only: GET requests only.
///
/// Login (protocol v4, headless): `AuthChallenge.webLogin` with `DKBLoginScript` – the hidden web view fills the
/// login form with the stored username/password, the page solves Friendly Captcha itself, the user confirms the
/// push in the DKB app. The session is the cookie set of `banking.dkb.de` (keychain only, `WebLoginSession`).
///
/// Session flow (like N26/C24): `accounts()` starts a sync and validates the stored session with the account list.
/// Rejected (401/403) → session discarded, one login (without presenter: `authRequired(.webLogin)`). A fresh login
/// the bank rejects → `authFailed` (never retried). Expiry mid-sync → session discarded, `sessionExpired`.
///
/// The access token cookie lives 5 minutes and the web app refreshes it on its own; the connector does not (the
/// refresh call is not in the HAR, STATUS.md) – a sync more than ~5 min after the login needs a new login.
///
/// Credit cards (`/api/credit-card/cards?filter[type]=creditCard`) are not read yet: no card with data in the HAR.
public actor DKBConnector: BankConnector {
    public nonisolated let id: ConnectorID = .dkb
    public nonisolated let connectionID: ConnectionID

    /// Upper bound for transaction pages per account and sync (25 per page; protects against paging loops).
    static let maximumPages = 400
    /// Pages are ordered by booking date; keep a few days of slack before stopping at `since`.
    static let pagingSlackDays = 3

    private let endpoints: DKBEndpoints
    private let session: WebLoginSession
    private let transport: any HTTPTransport
    private let policy: BackoffPolicy
    private let sleeper: any Sleeper
    private let now: @Sendable () -> Date

    private var client: ScrapeClient?
    private var login: Task<(ScrapeClient, DKBAccountList), any Error>?
    /// Account list from the session check at the start of a sync.
    private var checkedList: DKBAccountList?
    private var catalog: [AccountID: DKBMapper.Entry] = [:]

    private static let log = DKBMapper.log

    public init(
        connectionID: ConnectionID,
        presenter: (any AuthChallengePresenter)?,
        cookieStore: any SessionCookieStore = KeychainSessionCookieStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: DKBEndpoints = .production,
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
        session = WebLoginSession(key: "dkb.\(connectionID.rawValue)", request: endpoints.loginRequest, presenter: presenter, store: cookieStore)
    }

    // MARK: - BankConnector

    public func accounts() async throws -> [Account] {
        // Start of a sync: validate the session anew.
        client = nil
        checkedList = nil
        let accounts = try await loadAccounts()
        Self.log.info("DKB: \(accounts.count, privacy: .public) Konten")
        return accounts
    }

    public func balance(for account: Account) async throws -> Balance {
        try DKBMapper.balance(try await entry(for: account), asOf: now())
    }

    public func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        let entry = try await entry(for: account)
        let from = since.map(BankDay.init)
        let stopBefore = from?.adding(days: -Self.pagingSlackDays)

        var result: [Transaction] = []
        var seenIDs = Set<String>()
        var seenCursors = Set<String>()
        var cursor: String?
        for pageIndex in 0..<Self.maximumPages {
            let data = try await get(try endpoints.transactionsURL(accountID: entry.dkbID, after: cursor))
            let page = try DKBTransactionPage(data: data)
            var oldest: BankDay?
            for item in page.items {
                // Pages may overlap at the cursor: keep the first copy of a transaction.
                if !item.value.id.isEmpty, !seenIDs.insert(item.value.id).inserted { continue }
                let transaction = try DKBMapper.transaction(item.value, raw: item.raw, account: entry.account)
                result.append(transaction)
                if transaction.status != .pending { oldest = transaction.effectiveDate }
            }
            guard let next = page.nextCursor, !page.items.isEmpty else { break }
            if let stopBefore, let oldest, oldest < stopBefore { break }
            guard seenCursors.insert(next).inserted, pageIndex < Self.maximumPages - 1 else {
                throw ConnectorError.formatChanged(detail: "DKB Umsätze: Paging endet nicht")
            }
            cursor = next
        }

        // Pending transactions are returned regardless of `since` (BankConnector contract).
        let filtered = from.map { from in result.filter { $0.status == .pending || $0.effectiveDate >= from } } ?? result
        Self.log.info("DKB: \(filtered.count, privacy: .public) Umsätze")
        return Transaction.uniquingIDs(filtered)
    }

    public func cardStatements(for account: Account) async throws -> [CardStatement] {
        _ = try await entry(for: account)
        return [] // No card accounts yet (see type documentation).
    }

    public func securities(for account: Account) async throws -> [SecurityPosition] {
        _ = try await entry(for: account)
        return [] // The depot (`brokerageAccount`) is not part of the HAR.
    }

    // MARK: - Accounts

    private func entry(for account: Account) async throws -> DKBMapper.Entry {
        guard account.connectionID == connectionID else { throw ConnectorError.unsupportedAccount }
        if let entry = catalog[account.id] { return entry }
        _ = try await loadAccounts()
        guard let entry = catalog[account.id] else { throw ConnectorError.unsupportedAccount }
        return entry
    }

    private func loadAccounts() async throws -> [Account] {
        _ = try await activeClient() // the session check loads the account list
        let list: DKBAccountList
        if let checkedList {
            list = checkedList
        } else {
            list = try decode(DKBAccountList.self, from: try await get(try endpoints.accountsURL()), context: "Konten")
        }
        let entries = try DKBMapper.entries(list, connectionID: connectionID, groupNames: try await groupNames())
        catalog = Dictionary(entries.map { ($0.account.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<AccountID>()
        return entries.map(\.account).filter { seen.insert($0.id).inserted }
    }

    /// Account names from the user's groups. Cosmetic: a changed format only costs the names (logged), an
    /// expired session or a cancellation still ends the sync.
    private func groupNames() async throws -> [String: String] {
        do {
            let settings = try decode(DKBDisplaySettingsList.self, from: try await get(try endpoints.displaySettingsURL()), context: "Gruppen")
            return DKBMapper.groupNames(settings)
        } catch let error as ConnectorError {
            switch error {
            case .formatChanged:
                Self.log.notice("DKB: Kontogruppen nicht lesbar, Produktnamen werden genutzt")
                return [:]
            default:
                throw error
            }
        }
    }

    // MARK: - Requests

    /// GET with session handling: a rejected session is discarded (`sessionExpired`).
    private func get(_ url: URL) async throws -> Data {
        let client = try await activeClient()
        do {
            let data = try await request(url, with: client)
            try await session.update(await client.currentCookies)
            return data
        } catch ConnectorError.sessionExpired {
            Self.log.notice("DKB: Sitzung abgelaufen")
            self.client = nil
            try await session.invalidate()
            throw ConnectorError.sessionExpired
        }
    }

    private func request(_ url: URL, with client: ScrapeClient) async throws(ConnectorError) -> Data {
        let headers = DKBEndpoints.headers(cookies: await client.currentCookies)
        return try await client.data(url, headers: headers)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws(ConnectorError) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw .formatChanged(detail: "DKB \(context): Feld fehlt \(key.stringValue)")
        } catch let DecodingError.typeMismatch(_, context2) {
            throw .formatChanged(detail: "DKB \(context): Typ geändert bei \(context2.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw .formatChanged(detail: "DKB \(context): nicht lesbar")
        }
    }

    // MARK: - Session

    private func activeClient() async throws -> ScrapeClient {
        if let client { return client }
        if let login { return try await login.value.0 }
        let task = Task { try await self.startSession() }
        login = task
        defer { login = nil }
        // The unstructured task does not see the caller's cancellation: forward it, so a
        // cancelled sync also ends the login (sheet) instead of waiting for the user.
        let (client, list) = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        self.client = client
        checkedList = list
        return client
    }

    /// Validates the stored session with the account list; asks for one login if there is none or it is stale.
    private func startSession() async throws -> (ScrapeClient, DKBAccountList) {
        if let stored = try await session.storedCookies() {
            let names = Set(stored.map(\.name))
            if DKBEndpoints.requiredSessionCookies.allSatisfy(names.contains) {
                do {
                    let checked = try await check(stored)
                    Self.log.info("DKB: gespeicherte Sitzung gültig")
                    return checked
                } catch ConnectorError.sessionExpired {
                    Self.log.notice("DKB: gespeicherte Sitzung abgelaufen, neue Anmeldung nötig")
                }
            } else {
                // Access token cookie expired (5 min): no request with a session that cannot work.
                Self.log.notice("DKB: gespeicherte Sitzung unvollständig, neue Anmeldung nötig")
            }
            try await session.invalidate()
        }
        let fresh = try await session.cookies(forceLogin: true)
        do {
            let checked = try await check(fresh)
            Self.log.info("DKB: angemeldet")
            return checked
        } catch ConnectorError.sessionExpired {
            // The bank rejects a session that was just established: do not try again.
            try await session.invalidate()
            throw ConnectorError.authFailed
        }
    }

    private func check(_ cookies: [SessionCookie]) async throws -> (ScrapeClient, DKBAccountList) {
        // The login script's marker only completes the login; it never goes to the bank or the keychain.
        let client = ScrapeClient(cookies: cookies.filter { $0.name != DKBEndpoints.loginDoneCookie }, transport: transport, policy: policy, sleeper: sleeper, allowedHosts: [endpoints.host])
        let data = try await request(try endpoints.accountsURL(), with: client)
        let list = try decode(DKBAccountList.self, from: data, context: "Konten")
        try await session.update(await client.currentCookies)
        return (client, list)
    }
}
