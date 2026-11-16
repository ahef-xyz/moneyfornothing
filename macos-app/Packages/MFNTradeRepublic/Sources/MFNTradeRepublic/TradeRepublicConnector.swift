import Foundation
import MFNCore

/// Trade Republic over the unofficial web API, read-only.
///
/// Accounts: the cash account (`.giro`, IBAN and card from REST, transactions incl. card payments
/// from `GET /api/v2/timeline/transactions`) and the securities account (`.depot`, positions).
/// Login through the app's web view (`AuthChallenge.webLogin`), see `TRSession`.
///
/// Verified against `Fixtures/TradeRepublic` (web-app HAR): accounts, card, timeline page 1.
/// Unverified (pytr formats over the WebSocket, not in the HAR): cash balance (`cash`), depot
/// (`compactPortfolio`, `instrument`, `ticker`), transfer details (`timelineDetailV2`) and the
/// paging parameter `after` of the timeline.
///
/// One connector instance uses at most one WebSocket, opened lazily and reused for all calls.
/// Never places orders or savings plans.
public struct TradeRepublicConnector: BankConnector {
    /// WebSocket API version of the web app (`webSocketApiVersion: 35`, web bundle 2026-11-10).
    /// Topics are versioned per connection: under pytr's `31` the server rejects
    /// `compactPortfolioByTypeV2` ("Unknown topic type: compactPortfolioByTypeV2.31").
    static let webSocketAPIVersion = 35

    public struct Configuration: Sendable {
        public var baseURL: URL
        public var webSocketURL: URL
        public var locale: String
        public var requestTimeout: TimeInterval
        /// Stop and report `formatChanged` if paging never ends (cursor loop).
        public var maxTimelinePages: Int

        public init(
            baseURL: URL = URL(string: "https://api.traderepublic.com") ?? URL(fileURLWithPath: "/"),
            webSocketURL: URL = URL(string: "wss://api.traderepublic.com") ?? URL(fileURLWithPath: "/"),
            locale: String = "de",
            requestTimeout: TimeInterval = 30,
            maxTimelinePages: Int = 2_000
        ) {
            self.baseURL = baseURL
            self.webSocketURL = webSocketURL
            self.locale = locale
            self.requestTimeout = requestTimeout
            self.maxTimelinePages = maxTimelinePages
        }

        public static let production = Configuration()
    }

    /// Public-key pins for `api.traderepublic.com` (format: see `TRURLSessionTransport.init`):
    /// the issuing CA and its root, plus two DigiCert roots as backup, so a renewal of the server
    /// certificate keeps working; a CA change outside DigiCert fails closed. Read from the live
    /// chain on 2026-11-16 (`openssl s_client -showcerts`, roots from the macOS root store):
    /// DigiCert Global G2 TLS RSA SHA256 2020 CA1 (until 2031-03), DigiCert Global Root G2
    /// (until 2038-01); backups DigiCert Global Root G3 (ECDSA, until 2038-01) and DigiCert TLS
    /// RSA4096 Root G5 (until 2046-01).
    public static let pinnedKeyHashes: Set<String> = [
        "6/lnA5oSgvzWrr6BXgbjn3t88Fs/w3aKfCS8b8sSoMs=",
        "kzNpObIj7PazozWYvpGtefirgmaT+KxQzYJwCOyniWg=",
        "yh3BBoIIMtyhstjq3B01dct35nh4FQs/d6mV8ZigMfc=",
        "nFu/rHS4W76y4MvMHwbX9pixgciwBUo0VbNT7Pbjcso=",
    ]

    public let id: ConnectorID = .tradeRepublic
    public let connectionID: ConnectionID
    private let service: TRService

    /// Production connector.
    /// - Parameters:
    ///   - presenter: shows the web login. Without it a needed login throws `authRequired(.webLogin)`.
    ///   - pinnedKeyHashes: public-key pins for `api.traderepublic.com` (see `TRURLSessionTransport`).
    ///     Empty = `pinnedKeyHashes` (always pinned).
    public init(
        connectionID: ConnectionID,
        presenter: (any AuthChallengePresenter)?,
        sessionStore: (any TRSessionStore)? = nil,
        pinnedKeyHashes: Set<String> = TradeRepublicConnector.pinnedKeyHashes
    ) {
        let transport = TRURLSessionTransport(pinnedKeyHashes: pinnedKeyHashes)
        self.init(
            connectionID: connectionID,
            presenter: presenter,
            sessionStore: sessionStore ?? KeychainTRSessionStore(connection: connectionID),
            http: transport,
            webSocket: transport,
            sleeper: TRTaskSleeper(),
            configuration: .production
        )
    }

    /// Fully injectable connector (tests, previews).
    public init(
        connectionID: ConnectionID,
        presenter: (any AuthChallengePresenter)?,
        sessionStore: any TRSessionStore,
        http: any TRHTTPTransport,
        webSocket: any TRWebSocketTransport,
        sleeper: any TRSleeper = TRTaskSleeper(),
        configuration: Configuration = .production,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.connectionID = connectionID
        let session = TRSession(baseURL: configuration.baseURL, presenter: presenter, store: sessionStore, http: http, now: now)
        let connect = JSONValue.object([
            "locale": .string(configuration.locale),
            "platformId": .string("webtrading"),
            "platformVersion": .string("safari - 26.0"),
            "clientId": .string("app.traderepublic.com"),
            "clientVersion": .string(TRSession.fallbackAppVersion),
        ])
        let socket = TRWebSocketClient(
            configuration: .init(url: configuration.webSocketURL, connectMessage: "connect \(Self.webSocketAPIVersion) \(connect.text)", requestTimeout: configuration.requestTimeout),
            transport: webSocket,
            sleeper: sleeper,
            sessionProvider: { (url: URL) async throws(ConnectorError) -> String in try await session.cookieHeader(for: url) }
        )
        service = TRService(session: session, socket: socket, maxPages: configuration.maxTimelinePages, now: now)
    }

    public var cashAccountID: AccountID { AccountID("\(connectionID.rawValue):cash") }
    public var depotAccountID: AccountID { AccountID("\(connectionID.rawValue):depot") }

    public func accounts() async throws -> [Account] {
        let (cash, card) = try await service.cashAccount()
        return [
            Account(
                id: cashAccountID,
                connectionID: connectionID,
                iban: cash.iban,
                type: .giro,
                currency: "EUR",
                name: "Verrechnungskonto",
                cardLast4: card.last4
            ),
            Account(id: depotAccountID, connectionID: connectionID, type: .depot, currency: "EUR", name: "Depot"),
        ]
    }

    public func balance(for account: Account) async throws -> Balance {
        switch try kind(of: account) {
        case .cash:
            let cash = try await service.cash()
            return Balance(bookedCents: cash.cents, availableCents: cash.cents, currency: cash.currency, asOf: service.now())
        case .depot:
            // From exact prices, not from the rounded `priceCents`: penny stocks (e.g. €0.003)
            // would otherwise count as 0 (first real sync, 2026-11-10).
            _ = try await securities(for: account)
            return Balance(bookedCents: await service.depotValueCents(), currency: "EUR", asOf: service.now())
        }
    }

    public func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        switch try kind(of: account) {
        case .cash: try await service.transactions(account: cashAccountID, since: since.map(BankDay.init))
        case .depot: []
        }
    }

    public func cardStatements(for account: Account) async throws -> [CardStatement] {
        _ = try kind(of: account)
        return [] // Trade Republic card is a debit card on the cash account: no statements.
    }

    public func securities(for account: Account) async throws -> [SecurityPosition] {
        switch try kind(of: account) {
        case .cash: []
        case .depot: try await service.securities(account: depotAccountID)
        }
    }

    /// Closes the WebSocket. Optional; it is also closed when the connector is released.
    public func close() async {
        await service.close()
    }

    private enum Kind { case cash, depot }

    private func kind(of account: Account) throws(ConnectorError) -> Kind {
        guard account.connectionID == connectionID else { throw .unsupportedAccount }
        if account.id == cashAccountID { return .cash }
        if account.id == depotAccountID { return .depot }
        throw .unsupportedAccount
    }
}

/// Network side of the connector: one session, one socket, small per-instance caches.
actor TRService {
    private let session: TRSession
    private let socket: TRWebSocketClient
    private let maxPages: Int
    nonisolated let now: @Sendable () -> Date
    private var cachedAccount: (TRMapping.CashAccount, TRMapping.Card)?
    private var cachedCash: TRMapping.Cash?
    private var cachedPositions: [SecurityPosition]?
    /// Σ quantity × exact price, rounded once (cents). `nil` until `securities` ran.
    private var cachedDepotValue: Decimal?
    /// Set after the first failed detail: the rest of the run goes without details.
    private var detailsDisabled = false
    /// `timelineDetailV2` answers by item ID. The connector cannot see what the store already
    /// has, so details are cached for the lifetime of this instance (e.g. balance + transactions
    /// in one sync, or a second `transactions` call) instead of being fetched again.
    private var detailCache: [String: JSONValue] = [:]
    /// Detail subscriptions in flight at once (the socket multiplexes them by subscription ID).
    static let detailConcurrency = 6

    init(session: TRSession, socket: TRWebSocketClient, maxPages: Int, now: @escaping @Sendable () -> Date) {
        self.session = session
        self.socket = socket
        self.maxPages = maxPages
        self.now = now
    }

    func close() async {
        await socket.close()
    }

    // MARK: - REST (verified)

    func cashAccount() async throws(ConnectorError) -> (TRMapping.CashAccount, TRMapping.Card) {
        if let cachedAccount { return cachedAccount }
        // The card only adds `cardLast4` and a hint which account is the cash account; it must not
        // fail the sync (the endpoint answered HTTP 500 in the first real sync, 2026-11-10).
        let card: TRMapping.Card
        do {
            card = try await session.get("api/v1/card/cards/home", allowNotFound: true).map(TRMapping.card) ?? TRMapping.Card()
        } catch {
            switch error {
            case .cancelled, .authRequired, .authFailed, .sessionExpired:
                throw error
            default:
                TRLog.log.error("Trade Republic: Kartendaten nicht abrufbar (\(error.description, privacy: .public)), weiter ohne Karte")
                card = TRMapping.Card()
            }
        }
        guard let accounts = try await session.get("api/v1/account-manager/accounts/switchable") else {
            throw .formatChanged(detail: "accounts/switchable leer")
        }
        let result = (try TRMapping.cashAccount(accounts, preferredID: card.authAccountID), card)
        cachedAccount = result
        return result
    }

    /// Full history by cursor paging (first import) or back to `since`.
    /// Pending items are returned regardless of `since`.
    func transactions(account: AccountID, since: BankDay?) async throws(ConnectorError) -> [Transaction] {
        var items: [JSONValue] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var pages = 0
        repeat {
            // First page without query (HAR); the `after` parameter name is assumed.
            // The web app pages with `olderThan=<cursors.after>` (web bundle, verified 2026-11-10);
            // an `after` parameter is ignored and returns page 1 again.
            let query = cursor.map { [URLQueryItem(name: "olderThan", value: $0)] } ?? []
            guard let json = try await session.get("api/v2/timeline/transactions", query: query) else {
                throw .formatChanged(detail: "Timeline leer")
            }
            let page = try TRMapping.timelinePage(json)
            pages += 1
            items += page.items
            // An empty page ends the history even if the server still sends a cursor.
            if page.items.isEmpty { break }
            cursor = page.after
            if let next = cursor, !seenCursors.insert(next).inserted || pages >= maxPages {
                throw .formatChanged(detail: "Trade-Republic-Timeline endet nicht (Cursor wiederholt sich)")
            }
            if let since, let oldest = page.items.compactMap(TRMapping.itemDay).min(), oldest < since { break }
        } while cursor != nil

        let relevant = items.filter { item in
            guard let since, TRMapping.status(of: item) != .pending, let day = TRMapping.itemDay(item) else { return true }
            return day >= since
        }
        let detailIDs = relevant.compactMap { item -> String? in
            guard TRMapping.eventType(item).needsDetail, item["amount"].map({ !$0.isNull }) == true else { return nil }
            return TRMapping.itemID(item)
        }
        let details = try await self.details(ids: detailIDs)

        var transactions: [Transaction] = []
        var skipped = 0
        for item in relevant {
            let detail: JSONValue? = if TRMapping.eventType(item).needsDetail, let id = TRMapping.itemID(item) { details[id] } else { nil }
            if let transaction = try TRMapping.transaction(item: item, detail: detail, account: account) {
                transactions.append(transaction)
            } else {
                skipped += 1
            }
        }
        TRLog.log.info("Trade Republic: \(transactions.count, privacy: .public) Umsätze aus \(pages, privacy: .public) Seiten, \(skipped, privacy: .public) Einträge ohne Betrag")
        return Transaction.uniquingIDs(transactions)
    }

    // MARK: - WebSocket (unverified)

    func cash() async throws(ConnectorError) -> TRMapping.Cash {
        if let cachedCash { return cachedCash }
        let cash = try TRMapping.cash(try await request(["type": .string("cash")]))
        cachedCash = cash
        return cash
    }

    /// Details of transfers (IBAN, reference) by item ID, at most `detailConcurrency` at once.
    /// Best effort: unverified WebSocket format, so a failure costs only the details still
    /// missing in this run, never the sync. Only cancellation propagates.
    private func details(ids: [String]) async throws(ConnectorError) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        var missing: [String] = []
        var queued: Set<String> = []
        for id in ids {
            if let cached = detailCache[id] {
                result[id] = cached
            } else if queued.insert(id).inserted {
                missing.append(id)
            }
        }
        guard !detailsDisabled, !missing.isEmpty else { return result }

        let socket = socket
        var failure: ConnectorError?
        await withTaskGroup(of: (String, Result<JSONValue, ConnectorError>).self) { group in
            var next = 0
            func enqueue() {
                let id = missing[next]
                next += 1
                group.addTask { (id, await Self.fetchDetail(id, socket: socket)) }
            }
            while next < min(Self.detailConcurrency, missing.count) { enqueue() }
            while let (id, outcome) = await group.next() {
                switch outcome {
                case let .success(detail):
                    result[id] = detail
                    detailCache[id] = detail
                case let .failure(error):
                    // The first failure counts; the rest are the cancellations it caused.
                    if failure == nil {
                        failure = error
                        group.cancelAll()
                    }
                }
                if failure == nil, next < missing.count { enqueue() }
            }
        }
        if Task.isCancelled { throw .cancelled }
        if let failure {
            if failure == .cancelled { throw .cancelled }
            detailsDisabled = true
            TRLog.log.error("Trade Republic: Umsatzdetails nicht abrufbar (\(failure.description, privacy: .public)), Sync ohne Details")
        }
        return result
    }

    private static func fetchDetail(_ id: String, socket: TRWebSocketClient) async -> Result<JSONValue, ConnectorError> {
        do throws(ConnectorError) {
            return .success(try await socket.request(.object(["type": .string("timelineDetailV2"), "id": .string(id)])))
        } catch {
            return .failure(error)
        }
    }

    func securities(account: AccountID) async throws(ConnectorError) -> [SecurityPosition] {
        if let cachedPositions { return cachedPositions }
        // `compactPortfolio` was retired (BAD_SUBSCRIPTION_TYPE, 2026-11-10). The web app subscribes
        // `compactPortfolioByTypeV2` with the securities account number from `accountPairs`.
        let secAccNo = try TRMapping.securitiesAccountNumber(try await request(["type": .string("accountPairs")]))
        let portfolio: JSONValue
        do {
            portfolio = try await request(["type": .string("compactPortfolioByTypeV2"), "secAccNo": .string(secAccNo)])
        } catch .formatChanged(let detail) where detail.contains("BAD_SUBSCRIPTION_TYPE") {
            // Both topics exist in the web app; fall back if the server does not know V2.
            TRLog.log.info("Trade Republic: compactPortfolioByTypeV2 unbekannt, versuche compactPortfolioByType")
            portfolio = try await request(["type": .string("compactPortfolioByType"), "secAccNo": .string(secAccNo)])
        }
        let positions = try TRMapping.positions(portfolio)
        TRLog.log.info("Trade Republic: \(positions.count, privacy: .public) Depotpositionen")
        let asOf = now()
        var result: [SecurityPosition] = []
        var total = Decimal(0)
        for position in positions {
            let instrument = TRMapping.instrument(try await request(["type": .string("instrument"), "id": .string(position.isin)]), isin: position.isin)
            let ticker = try await request(["type": .string("ticker"), "id": .string("\(position.isin).\(instrument.exchange)")])
            let price = try TRMapping.price(ticker)
            total += position.quantity * price
            result.append(SecurityPosition(accountID: account, isin: position.isin, name: instrument.name, quantity: position.quantity,
                                           priceCents: try TRMapping.priceCents(ticker), currency: "EUR", asOf: asOf,
                                           purchasePriceCents: position.averageBuyIn.flatMap { Money.minorUnits($0, fractionDigits: 2) }))
        }
        cachedPositions = result
        cachedDepotValue = total
        return result
    }

    /// Depot value in cents from exact prices (see `balance(for:)`).
    func depotValueCents() -> Int {
        cachedDepotValue.flatMap { Money.minorUnits($0, fractionDigits: 2) }
            ?? (cachedPositions ?? []).reduce(0) { $0 + $1.valueCents }
    }

    private func request(_ payload: [String: JSONValue]) async throws(ConnectorError) -> JSONValue {
        do {
            return try await socket.request(.object(payload))
        } catch .sessionExpired {
            // Next sync logs in again through the web view.
            await session.invalidate()
            throw .sessionExpired
        }
    }
}
