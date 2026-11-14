import Foundation
import MFNCore
import MFNScrape

/// easybank (ex Barclays Deutschland) credit cards via the web-banking JSON API.
///
/// - Login: headless web login in the app (`WebLoginSession` + `EasybankLoginScript`: stored
///   username + password, approval in the easybank app); cookies are reused until the bank rejects
///   them. The connector never sees credentials and never retries a failed login.
/// - Accounts: `RetailLanding` → card accounts (partner cards book into the same card account).
/// - Transactions + latest statement: `AccountTransactionHistory`, which needs **no OTP** and
///   covers the open billing cycle, pending items and the end of the last statement period.
///   Older history (`GetTransactions`) needs an SMS OTP whose request is not recorded yet →
///   first import of older history via `EasybankCSVImporter` (STATUS.md, easybank).
/// - Read-only: no payment, limit or instalment endpoint is called.
public actor EasybankConnector: BankConnector {
    public nonisolated let id: ConnectorID = .easybank

    private let connectionID: ConnectionID
    private let session: WebLoginSession?
    private let transport: any HTTPTransport
    private let policy: BackoffPolicy
    private let sleeper: any Sleeper
    private let now: @Sendable () -> Date

    private var client: ScrapeClient?
    /// `UniqueKey`/`PCID` from the web login (pseudo-cookies, sent only as headers).
    private var appValues: [SessionCookie] = []
    private var cardAccounts: [AccountID: EasybankMapper.CardAccount] = [:]
    private var histories: [AccountID: EasybankMapper.History] = [:]

    public init(
        connectionID: ConnectionID,
        presenter: (any AuthChallengePresenter)?,
        store: any SessionCookieStore = KeychainSessionCookieStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        policy: BackoffPolicy = BackoffPolicy(),
        sleeper: any Sleeper = TaskSleeper(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connectionID = connectionID
        self.session = EasybankEndpoints.loginRequest().map {
            WebLoginSession(key: "easybank.\(connectionID.rawValue)", request: $0, presenter: presenter, store: store)
        }
        self.transport = transport
        self.policy = policy
        self.sleeper = sleeper
        self.now = now
    }

    // MARK: - BankConnector

    public func accounts() async throws(ConnectorError) -> [Account] {
        let item = try await post(EasybankEndpoints.retailLanding, body: .object([:]))
        let landing = try EasybankMapper.landing(in: item)
        let cards = try EasybankMapper.accounts(landing, connectionID: connectionID)
        cardAccounts = Dictionary(cards.map { ($0.account.id, $0) }, uniquingKeysWith: { first, _ in first })
        histories = [:]
        EasybankMapper.log.info("easybank: \(cards.count, privacy: .public) Kartenkonten")
        return cards.map(\.account)
    }

    public func balance(for account: Account) async throws(ConnectorError) -> Balance {
        let card = try await cardAccount(for: account)
        return try EasybankMapper.balance(card.dto, account: card.account, asOf: now())
    }

    public func transactions(for account: Account, since: Date?) async throws(ConnectorError) -> [Transaction] {
        let history = try await history(for: account)
        let transactions = try EasybankMapper.transactions(history.transactions, account: account)
        EasybankMapper.log.info("easybank: \(transactions.count, privacy: .public) Umsätze")
        return EasybankTransactionBuilder.filter(transactions, since: since)
    }

    public func cardStatements(for account: Account) async throws(ConnectorError) -> [CardStatement] {
        guard account.type == .card else { return [] }
        let history = try await history(for: account)
        guard let summary = history.summary else {
            throw .formatChanged(detail: "AccountTransactionHistory: Abrechnungsdaten fehlen")
        }
        return try EasybankMapper.latestStatement(summary, transactions: history.transactions, account: account).map { [$0] } ?? []
    }

    public func securities(for account: Account) async throws(ConnectorError) -> [SecurityPosition] {
        []
    }

    // MARK: - Private

    private func cardAccount(for account: Account) async throws(ConnectorError) -> EasybankMapper.CardAccount {
        if cardAccounts[account.id] == nil { _ = try await accounts() }
        guard let card = cardAccounts[account.id] else { throw .unsupportedAccount }
        return card
    }

    /// One `AccountTransactionHistory` call per account and connector run, shared by
    /// `transactions` and `cardStatements`.
    private func history(for account: Account) async throws(ConnectorError) -> EasybankMapper.History {
        if let cached = histories[account.id] { return cached }
        let card = try await cardAccount(for: account)
        let item = try await post(EasybankEndpoints.accountTransactionHistory, body: .object(["Account": card.raw]))
        let history = try EasybankMapper.history(in: item)
        histories[account.id] = history
        return history
    }

    private func scrapeClient() async throws(ConnectorError) -> ScrapeClient {
        if let client { return client }
        guard let session else { throw .formatChanged(detail: "Login-URL ungültig") }
        var cookies = try await session.cookies()
        if !cookies.contains(where: { $0.name == EasybankEndpoints.uniqueKeyName }) {
            // Session from before protocol v3 (no UniqueKey): every call would fail, log in again.
            cookies = try await session.cookies(forceLogin: true)
        }
        appValues = cookies.filter { EasybankEndpoints.appValueNames.contains($0.name) }
        let plain = cookies.filter { !EasybankEndpoints.appValueNames.contains($0.name) }
        let client = ScrapeClient(cookies: plain, transport: transport, policy: policy, sleeper: sleeper)
        self.client = client
        return client
    }

    /// POSTs `body`, checks `Result.IsSuccess` and returns `Item`.
    private func post(_ path: String, body: JSONValue) async throws(ConnectorError) -> JSONValue {
        guard let url = EasybankEndpoints.url(path) else { throw .formatChanged(detail: "URL ungültig: \(path)") }
        let client = try await scrapeClient()
        let headers = EasybankEndpoints.headers(cookies: await client.currentCookies, appValues: appValues)
        let envelope: EBEnvelope
        do {
            envelope = try await client.post(url, json: body, as: EBEnvelope.self, headers: headers).value
        } catch {
            if error == .sessionExpired {
                // The bank rejected the session: forget it, the next sync asks for a new web login.
                self.client = nil
                try? await session?.invalidate()
            }
            throw error
        }
        try await session?.update(await client.currentCookies + appValues)
        guard envelope.result?.isSuccess != false else { throw .formatChanged(detail: "\(path): Result.IsSuccess = false") }
        guard let item = envelope.item else { throw .formatChanged(detail: "\(path): Feld fehlt Item") }
        return item
    }
}
