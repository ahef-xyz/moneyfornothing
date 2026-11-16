import CryptoKit
import Foundation
import MFNCore
import MFNScrape

/// C24 Bank: current accounts, Pocket Plus and pockets via the JSON API behind the web banking
/// (CLAUDE.md §7, `Fixtures/C24/endpoints.md`). Read-only: GET, plus `POST …/transactions/search/`
/// which only queries.
///
/// Session flow:
/// - The API authenticates with `Authorization: Bearer <token>` (not a session cookie). The web
///   app keeps the token in `sessionStorage["sessionStore"]` (JSON, key `accessToken`). The app's
///   web login hands that entry over as a pseudo-cookie of the same name (protocol v2,
///   `WebLoginRequest.storageKeys`); it is
///   stored in the keychain with the cookies and never sent as a cookie.
/// - `accounts()` starts a sync: the stored session is validated with a lightweight call. If the
///   bank rejects it, it is discarded and the user is asked once for an interactive login
///   (`AuthChallenge.webLogin`, push TAN in the C24 app). Without a presenter →
///   `authRequired(.webLogin)`. A fresh login the bank still rejects → `authFailed` (never retried).
/// - A session that expires mid-sync → discarded, `sessionExpired`; the next sync logs in again.
public actor C24Connector: BankConnector {
    public nonisolated let id: ConnectorID = .c24
    public nonisolated let connectionID: ConnectionID

    /// Upper bound for transaction pages per account and sync (protects against paging loops).
    static let maximumPages = 500
    /// Pages are ordered by `sort_date` (card payment time), bookings can be a few days later.
    static let sortDateSlackDays = 7
    /// History requested on the first import (CLAUDE.md §1: 12–24 months via web banking).
    static let initialHistoryMonths = 24

    private let endpoints: C24Endpoints
    private let session: WebLoginSession
    private let transport: any HTTPTransport
    private let policy: BackoffPolicy
    private let sleeper: any Sleeper
    private let now: @Sendable () -> Date

    private var active: ActiveSession?
    private var login: Task<ActiveSession, any Error>?
    private var catalog: [AccountID: Entry] = [:]
    /// Planned transactions per account number, loaded once per sync.
    private var upcoming: [String: [Transaction]]?

    private static let log = Log.logger("c24")

    struct Entry: Sendable {
        /// Account or pocket number: the key of the transaction search.
        var number: String
        var account: Account
        var booked: C24Amount?
        var available: C24Amount?
    }

    struct ActiveSession: Sendable {
        var client: ScrapeClient
        /// Raw `sessionStorage` entry, kept for the keychain; never sent, never logged.
        var storageEntry: SessionCookie
        var accessToken: String
        var sessionUUID: String
    }

    public init(
        connectionID: ConnectionID,
        presenter: (any AuthChallengePresenter)?,
        cookieStore: any SessionCookieStore = KeychainSessionCookieStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: C24Endpoints = .production,
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
        session = WebLoginSession(key: "c24.\(connectionID.rawValue)", request: endpoints.loginRequest, presenter: presenter, store: cookieStore)
    }

    // MARK: - BankConnector

    public func accounts() async throws -> [Account] {
        // Start of a sync: validate the session anew, reload upcoming transactions.
        active = nil
        upcoming = nil
        let accounts = try await loadAccounts()
        Self.log.info("C24: \(accounts.count, privacy: .public) Konten")
        return accounts
    }

    /// Balances come with the account list (`total_balance`, `available_balance`); there is no
    /// balance endpoint (`endpoints.md`).
    public func balance(for account: Account) async throws -> Balance {
        var entry = try await entry(for: account)
        if entry.booked == nil {
            _ = try await loadAccounts()
            entry = try await self.entry(for: account)
        }
        guard let booked = entry.booked else {
            throw ConnectorError.formatChanged(detail: "C24 Konten: total_balance fehlt")
        }
        return Balance(bookedCents: booked.cents, availableCents: entry.available?.cents, currency: entry.account.currency, asOf: now())
    }

    public func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        let entry = try await entry(for: account)
        let from = since.map(BankDay.init) ?? BankDay(now()).adding(months: -Self.initialHistoryMonths)
        let stopBefore = from.adding(days: -Self.sortDateSlackDays)
        let url = try endpoints.url(endpoints.transactionSearchPath)

        var result: [Transaction] = []
        var offset = 0
        for pageIndex in 0..<Self.maximumPages {
            let request = C24SearchRequest(
                criteria: .init(accountNumbers: [entry.number]),
                pagination: .init(limit: endpoints.pageSize, offset: offset)
            )
            let body: Data
            do {
                body = try JSONEncoder().encode(request)
            } catch {
                throw ConnectorError.formatChanged(detail: "C24: Suchanfrage nicht kodierbar")
            }
            let page = try C24SearchPage(data: try await send(url, method: "POST", json: body, retryable: true))
            for item in page.items {
                if let number = item.value.accountNumber, number != entry.number {
                    throw ConnectorError.formatChanged(detail: "C24 Umsätze: Treffer eines anderen Kontos")
                }
                result.append(try C24Mapper.transaction(item.value, raw: item.raw, account: entry.account))
            }
            guard page.pagination?.more == true, let oldest = page.items.last else { break }
            if let day = C24Day.parse(oldest.value.sortDate ?? oldest.value.date), day < stopBefore { break }
            offset += page.items.count
            if pageIndex == Self.maximumPages - 1 {
                throw ConnectorError.formatChanged(detail: "C24 Umsätze: Paging endet nicht")
            }
        }

        result += try await plannedTransactions()[entry.number] ?? []
        // Pending transactions may be returned regardless of `since` (BankConnector contract).
        let filtered = result.filter { $0.status == .pending || $0.effectiveDate >= from }
        Self.log.info("C24: \(filtered.count, privacy: .public) Umsätze")
        return Transaction.uniquingIDs(filtered)
    }

    public func cardStatements(for account: Account) async throws -> [CardStatement] {
        _ = try await entry(for: account)
        return [] // The debit card books on the account itself; no card account, no statements.
    }

    public func securities(for account: Account) async throws -> [SecurityPosition] {
        _ = try await entry(for: account)
        return [] // No depot at C24.
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
        let list = try C24JSON.decode(C24AccountsResponse.self, from: try await send(try endpoints.url(endpoints.accountsPath)), context: "Konten")
        var pockets = list.pockets ?? []
        if let pocketsPath = endpoints.pocketsPath {
            let extra = try C24JSON.decode(C24PocketsResponse.self, from: try await send(try endpoints.url(pocketsPath)), context: "Pockets").pockets
            let known = Set(pockets.map(\.pocketNumber))
            pockets += extra.filter { !known.contains($0.pocketNumber) }
        }

        var entries: [Entry] = []
        for item in list.accounts where !c24ClosedStates.contains(item.state?.lowercased() ?? "") {
            if case let .unknown(type) = C24AccountKind(accountType: item.accountType) {
                // Unknown product: keep it visible rather than dropping money silently.
                Self.log.notice("C24: unbekannter Kontotyp '\(type, privacy: .public)'")
            }
            let name = Self.nonEmpty(item.personalization?.name) ?? Self.nonEmpty(item.name) ?? Self.nonEmpty(item.accountplanName) ?? "C24 Konto"
            entries.append(entry(number: item.accountNumber, isPocket: false, type: .giro, iban: item.iban, name: name, booked: item.totalBalance, available: item.availableBalance))
        }
        for pocket in pockets where !c24ClosedStates.contains(pocket.state?.lowercased() ?? "") && pocket.dateOfClosure == nil {
            let kind = C24AccountKind(productType: pocket.productType)
            if case let .unknown(type) = kind {
                Self.log.notice("C24: unbekannter Pocket-Typ '\(type, privacy: .public)'")
            }
            let fallback = kind == .pocketPlus ? "C24 Pocket Plus" : "C24 Pocket"
            let name = Self.nonEmpty(pocket.customDetails?.name) ?? Self.nonEmpty(pocket.personalization?.name) ?? fallback
            entries.append(entry(number: pocket.pocketNumber, isPocket: true, type: .tagesgeld, iban: pocket.iban, name: name, booked: pocket.totalBalance, available: pocket.availableBalance))
        }
        catalog = Dictionary(entries.map { ($0.account.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<AccountID>()
        return entries.map(\.account).filter { seen.insert($0.id).inserted }
    }

    private func entry(number: String, isPocket: Bool, type: AccountType, iban: String?, name: String, booked: C24Amount?, available: C24Amount?) -> Entry {
        let account = Account(
            id: Self.accountID(connection: connectionID, number: number, isPocket: isPocket),
            connectionID: connectionID,
            iban: iban?.normalizedIBAN,
            type: type,
            currency: "EUR", // C24 accounts are EUR only; the API carries no currency field.
            name: name
        )
        return Entry(number: number, account: account, booked: booked, available: available)
    }

    /// Deterministic and opaque: never exposes the account number in IDs (they may be logged).
    static func accountID(connection: ConnectionID, number: String, isPocket: Bool) -> AccountID {
        let digest = SHA256.hash(data: Data("\(connection.rawValue)|\(isPocket ? "pocket" : "account")|\(number)".utf8))
        return AccountID("c24-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined())
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Upcoming

    /// Standing orders and announced direct debits as `planned`, keyed by account number.
    private func plannedTransactions() async throws -> [String: [Transaction]] {
        if let upcoming { return upcoming }
        var byNumber: [String: [Transaction]] = [:]
        if let path = endpoints.upcomingPath {
            let query = [URLQueryItem(name: endpoints.upcomingFutureDaysParameter, value: String(endpoints.upcomingFutureDays))]
            let data = try await send(try endpoints.url(path, query: query))
            let byIBAN = Dictionary(catalog.values.compactMap { entry in entry.account.iban.map { ($0, entry) } }, uniquingKeysWith: { first, _ in first })
            let byAccountNumber = Dictionary(catalog.values.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })

            for item in try C24JSON.items(C24StandingOrder.self, in: data, key: "standing_orders", context: "Daueraufträge") {
                guard let number = item.value.accountNumber, let entry = byAccountNumber[number],
                      let transaction = try C24Mapper.planned(item.value, raw: item.raw, account: entry.account) else { continue }
                byNumber[number, default: []].append(transaction)
            }
            for item in try C24JSON.items(C24DirectDebit.self, in: data, key: "direct_debits", context: "Lastschriften") {
                guard let iban = item.value.debtorIban?.normalizedIBAN, let entry = byIBAN[iban],
                      let transaction = try C24Mapper.planned(item.value, raw: item.raw, account: entry.account) else { continue }
                byNumber[entry.number, default: []].append(transaction)
            }
        }
        upcoming = byNumber
        return byNumber
    }

    // MARK: - Session

    /// Request with session handling: auth headers, cookie updates persisted, expired session discarded.
    /// `retryable`: `nil` = GET only (see `ScrapeClient.data`); the search POST is a read.
    private func send(_ url: URL, method: String = "GET", json body: Data? = nil, retryable: Bool? = nil) async throws -> Data {
        let session = try await activeSession()
        var headers = headers(for: session)
        if body != nil { headers["Content-Type"] = "application/json" }
        do {
            let data = try await session.client.data(url, method: method, body: body, headers: headers, retryable: retryable)
            try await persist(session)
            return data
        } catch ConnectorError.sessionExpired {
            // Access token ran out mid-sync: renew it once and repeat the request.
            if let renewed = try await refreshed(session) {
                active = renewed
                var retry = self.headers(for: renewed)
                if body != nil { retry["Content-Type"] = "application/json" }
                do {
                    let data = try await renewed.client.data(url, method: method, body: body, headers: retry, retryable: retryable)
                    try await persist(renewed)
                    return data
                } catch ConnectorError.sessionExpired {
                    // fall through: the renewed session is refused too
                }
            }
            Self.log.notice("C24: Sitzung abgelaufen")
            active = nil
            try await self.session.invalidate()
            throw ConnectorError.sessionExpired
        }
    }

    /// Renews the access token with the refresh token from the `sessionStorage` entry (no user,
    /// no QR code – allowed in automatic syncs). `nil` if there is none or C24 refuses it
    /// (401/403 = `sessionExpired`, other 4xx = `formatChanged` from `ScrapeClient`, `authFailed`,
    /// answer without token). Outages, rate limits and cancellation are rethrown: they say
    /// nothing about the session, which must survive them (no QR login after a network blip).
    /// UNVERIFIED: sent without `Authorization` (the token is the expired one), with the client
    /// headers; answer fields `access_token`/`refresh_token` as in `web-login/complete`.
    private func refreshed(_ candidate: ActiveSession) async throws(ConnectorError) -> ActiveSession? {
        guard let refreshToken = C24SessionStore.token(in: candidate.storageEntry.value, field: endpoints.refreshTokenField),
              let body = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        else { return nil }
        do {
            var headers = self.headers(for: candidate)
            headers["Authorization"] = nil
            headers["Content-Type"] = "application/json"
            // Not retried: a refresh token may be single-use, a repeat could burn the session.
            let data = try await candidate.client.data(try endpoints.url(endpoints.webLoginRefreshPath), method: "POST", body: body, headers: headers, retryable: false)
            guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let access = (answer["access_token"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
                  let raw = C24SessionStore.updating(
                      candidate.storageEntry.value,
                      fields: [endpoints.accessTokenField: access, endpoints.refreshTokenField: (answer["refresh_token"] as? String) ?? refreshToken]
                  )
            else {
                Self.log.notice("C24: Token-Erneuerung ohne Zugriffstoken")
                return nil
            }
            var entry = candidate.storageEntry
            entry.value = raw
            let renewed = ActiveSession(client: candidate.client, storageEntry: entry, accessToken: access, sessionUUID: candidate.sessionUUID)
            try await persist(renewed)
            Self.log.info("C24: Zugriffstoken erneuert, keine neue Anmeldung nötig")
            return renewed
        } catch .sessionExpired, .authFailed, .formatChanged {
            Self.log.notice("C24: Token-Erneuerung abgelehnt")
            return nil
        } catch {
            Self.log.notice("C24: Token-Erneuerung nicht möglich, Sitzung bleibt")
            throw error
        }
    }

    private func activeSession() async throws -> ActiveSession {
        if let active { return active }
        if let login { return try await login.value }
        let task = Task { try await self.startSession() }
        login = task
        defer { login = nil }
        // The unstructured task does not see the caller's cancellation: forward it, so a
        // cancelled sync also ends the login (sheet) instead of waiting for the user.
        let session = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        active = session
        return session
    }

    /// Validates the stored session; asks for one interactive login if there is none or it is stale.
    private func startSession() async throws -> ActiveSession {
        guard endpoints.verified else {
            throw ConnectorError.formatChanged(detail: "C24-Endpunkte nicht verifiziert")
        }
        if let stored = try await session.storedCookies() {
            do {
                return try await validated(try makeSession(stored))
            } catch ConnectorError.sessionExpired {
                Self.log.notice("C24: gespeicherte Sitzung abgelaufen, neue Anmeldung nötig")
                try await session.invalidate()
            }
        }
        let fresh: ActiveSession
        do {
            fresh = try makeSession(try await session.cookies(forceLogin: true))
        } catch ConnectorError.sessionExpired {
            // Login completed without a usable access token: discard, the next sync asks again.
            try await session.invalidate()
            throw ConnectorError.sessionExpired
        }
        do {
            try await check(fresh)
        } catch ConnectorError.sessionExpired {
            // The bank rejects a session that was just established: do not try again.
            try await session.invalidate()
            throw ConnectorError.authFailed
        }
        Self.log.info("C24: angemeldet")
        return fresh
    }

    /// A stored session that still works, or one renewed with its refresh token (before asking
    /// for a QR login). `sessionExpired` if neither.
    private func validated(_ candidate: ActiveSession) async throws(ConnectorError) -> ActiveSession {
        do {
            try await check(candidate)
            Self.log.info("C24: gespeicherte Sitzung gültig")
            return candidate
        } catch .sessionExpired {
            guard let renewed = try await refreshed(candidate) else { throw .sessionExpired }
            try await check(renewed)
            return renewed
        }
    }

    private func check(_ candidate: ActiveSession) async throws(ConnectorError) {
        _ = try await candidate.client.data(try endpoints.url(endpoints.sessionCheckPath), headers: headers(for: candidate))
        try await persist(candidate)
    }

    /// Session from the web-login hand-over. The `sessionStorage` entry (`endpoints.sessionStorageKey`)
    /// arrives as pseudo-cookie; its access token becomes the bearer token. Missing entry, no JSON
    /// or no token → `sessionExpired`.
    private func makeSession(_ cookies: [SessionCookie]) throws(ConnectorError) -> ActiveSession {
        guard let entry = cookies.first(where: { $0.name == endpoints.sessionStorageKey }),
              let token = C24SessionStore.accessToken(in: entry.value, field: endpoints.accessTokenField)
        else {
            Self.log.notice("C24: kein Zugriffstoken in der Sitzung")
            throw .sessionExpired
        }
        let plain = cookies.filter { $0.name != endpoints.sessionStorageKey }
        return ActiveSession(
            client: ScrapeClient(cookies: plain, transport: transport, policy: policy, sleeper: sleeper, allowedHosts: Set([endpoints.apiBaseURL.host()].compactMap(\.self))),
            storageEntry: entry,
            accessToken: token,
            sessionUUID: UUID().uuidString.lowercased()
        )
    }

    /// Writes cookie updates (`Set-Cookie`) back to the keychain, together with the storage entry.
    private func persist(_ candidate: ActiveSession) async throws(ConnectorError) {
        try await session.update(await candidate.client.currentCookies + [candidate.storageEntry])
    }

    private func headers(for session: ActiveSession) -> [String: String] {
        var headers = ["Authorization": "Bearer \(session.accessToken)"]
        for (name, kind) in endpoints.clientHeaders {
            headers[name] = switch kind {
            case .sessionUUID: session.sessionUUID
            case .requestUUID: UUID().uuidString.lowercased()
            case .unixMillis: String(Int64(now().timeIntervalSince1970 * 1000))
            case let .fixed(value): value
            }
        }
        return headers
    }
}

// MARK: - Session storage

enum C24SessionStore {
    /// Extracts the access token from the raw `sessionStorage` value: a JSON object (tolerated:
    /// percent-encoded or JSON-encoded as string) with a non-empty string under `field`.
    /// Every other field is ignored and never logged.
    static func accessToken(in raw: String, field: String) -> String? {
        token(in: raw, field: field)
    }

    /// The `sessionStorage` JSON with `fields` replaced; other fields stay as they are. `nil` if
    /// the raw value is not a JSON object (also tolerated percent- or string-encoded).
    static func updating(_ raw: String, fields: [String: String]) -> String? {
        guard var object = object(in: raw) else { return nil }
        for (key, value) in fields { object[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(in raw: String) -> [String: Any]? {
        var candidates = [raw.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let decoded = candidates[0].removingPercentEncoding, decoded != candidates[0] { candidates.append(decoded) }
        for candidate in candidates {
            guard var object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8), options: [.fragmentsAllowed]) else { continue }
            if let nested = object as? String, let inner = try? JSONSerialization.jsonObject(with: Data(nested.utf8)) {
                object = inner
            }
            if let dictionary = object as? [String: Any] { return dictionary }
        }
        return nil
    }

    /// A non-empty string field of the `sessionStorage` JSON (access or refresh token).
    static func token(in raw: String, field: String) -> String? {
        var candidates = [raw.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let decoded = candidates[0].removingPercentEncoding, decoded != candidates[0] { candidates.append(decoded) }
        for candidate in candidates {
            guard var object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8), options: [.fragmentsAllowed]) else { continue }
            if let nested = object as? String, let inner = try? JSONSerialization.jsonObject(with: Data(nested.utf8)) {
                object = inner
            }
            if let token = (object as? [String: Any])?[field] as? String {
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }
}

// MARK: - Raw items

extension C24JSON {
    /// Decodes the array under `key`, keeping each element's raw JSON (for `Transaction.rawJSON`).
    /// A missing key is an empty list.
    static func items<T: Decodable>(_ type: T.Type, in data: Data, key: String, context: String) throws(ConnectorError) -> [(value: T, raw: Data)] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .formatChanged(detail: "C24 \(context): kein gültiges JSON")
        }
        guard let object = root as? [String: Any] else { throw .formatChanged(detail: "C24 \(context): unerwartete Wurzel") }
        guard let value = object[key], !(value is NSNull) else { return [] }
        guard let list = value as? [Any] else { throw .formatChanged(detail: "C24 \(context): \(key) ist keine Liste") }
        var result: [(value: T, raw: Data)] = []
        for (index, element) in list.enumerated() {
            guard JSONSerialization.isValidJSONObject(element),
                  let raw = try? JSONSerialization.data(withJSONObject: element, options: [.sortedKeys, .withoutEscapingSlashes])
            else {
                throw .formatChanged(detail: "C24 \(context): \(key).[\(index)] ist kein Objekt")
            }
            result.append((try decode(T.self, from: raw, context: "\(context) \(key).[\(index)]"), raw))
        }
        return result
    }
}

// MARK: - Mapping

enum C24Mapper {
    /// Booked or preliminary (pending) transaction from the search.
    static func transaction(_ item: C24Transaction, raw: Data, account: Account) throws(ConnectorError) -> Transaction {
        let pending = item.preliminary == true
        guard let eventDay = C24Day.parse(item.date) else {
            throw .formatChanged(detail: "C24 Umsätze: date unlesbar")
        }
        let bookingDay = item.detail("Buchungsdatum").flatMap(C24Day.parse) ?? eventDay

        // Direct debits show the own account in the IBAN detail; that is not the counterpart.
        let detailIBAN = item.detail("IBAN")?.normalizedIBAN
        let counterpartIBAN = detailIBAN == account.iban?.normalizedIBAN ? nil : detailIBAN
        let purpose = item.detail("Verwendungszweck") ?? item.detail("Beschreibung") ?? item.type ?? ""

        return Transaction(
            accountID: account.id,
            bookingDate: pending ? nil : bookingDay,
            valueDate: pending ? eventDay : bookingDay, // C24 shows no separate value date.
            amountCents: item.amount.cents,
            currency: account.currency,
            counterpartName: item.counterpart?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            counterpartIBAN: counterpartIBAN,
            purpose: purpose,
            eref: cleaned(item.entToEndId ?? item.endToEndId),
            mref: item.detail("Mandatsreferenz"),
            creditorID: item.detail("Gläubiger ID", "Gläubiger-ID", "Gläubiger-Identifikationsnummer"),
            status: pending ? .pending : .booked,
            externalID: cleaned(item.id?.value),
            rawJSON: raw
        )
    }

    /// Next execution of a standing order. Standing orders always debit the account.
    static func planned(_ order: C24StandingOrder, raw: Data, account: Account) throws(ConnectorError) -> Transaction? {
        guard let text = order.nextExecution else { return nil } // ended: nothing planned
        guard let day = C24Day.parse(text) else { throw .formatChanged(detail: "C24 Daueraufträge: next_execution unlesbar") }
        return Transaction(
            accountID: account.id,
            bookingDate: nil,
            valueDate: day,
            amountCents: -abs(order.amount.cents),
            currency: account.currency,
            counterpartName: order.recipient ?? "",
            counterpartIBAN: order.iban?.normalizedIBAN,
            purpose: order.subject ?? "",
            status: .planned,
            externalID: "standing-order:\(order.id.value):\(day.iso)",
            rawJSON: raw
        )
    }

    /// Announced SEPA direct debit (pre-notification) on the debtor account.
    static func planned(_ debit: C24DirectDebit, raw: Data, account: Account) throws(ConnectorError) -> Transaction? {
        guard let text = debit.requestedCollectionDate ?? debit.settlementDate else { return nil }
        guard let day = C24Day.parse(text) else { throw .formatChanged(detail: "C24 Lastschriften: Datum unlesbar") }
        return Transaction(
            accountID: account.id,
            bookingDate: nil,
            valueDate: day,
            amountCents: -abs(debit.amount.cents),
            currency: account.currency,
            counterpartName: debit.creditorName ?? "",
            counterpartIBAN: debit.creditorIban?.normalizedIBAN,
            purpose: debit.purpose ?? "",
            mref: cleaned(debit.mandateReference),
            creditorID: cleaned(debit.creditorId),
            status: .planned,
            externalID: cleaned(debit.paymentorderid).map { "direct-debit:\($0)" },
            rawJSON: raw
        )
    }

    static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value != "NOTPROVIDED" else { return nil }
        return value
    }
}
