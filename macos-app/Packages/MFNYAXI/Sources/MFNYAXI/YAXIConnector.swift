import Foundation
import MFNCore

/// Any bank through YAXI (protocol v12, docs/v0.7.0.md). Read-only: accounts, balances, transactions.
///
/// Flow of a sync:
/// - `accounts()`: with a stored consent the account list comes from the state if it is younger than a
///   day (no call), else from YAXI without user interaction. No consent yet, or YAXI says the consent
///   needs the user again: a new consent with the bank login and the bank's questions through the
///   presenter, only when the user is at the Mac (`AuthInteraction`).
/// - `balance(for:)`: one balances call for all accounts per sync.
/// - `transactions(for:since:)`: one call per account, from `since` (first import: as far back as the
///   bank allows, at most `firstImportDays`).
///
/// After every call the newest consent replaces the stored one (M0: YAXI rotates it).
public actor YAXIConnector: BankConnector {
    public nonisolated let id: ConnectorID = .yaxi
    public nonisolated let connectionID: ConnectionID

    /// First import: how far back to ask; banks that refuse get `fallbackDays`.
    static let firstImportDays = 400
    static let fallbackDays = 89
    /// The stored account list is used for this long before YAXI is asked again.
    static let accountsMaxAge: TimeInterval = 24 * 60 * 60
    /// Never poll a decoupled approval faster than this (O1: whether polls are billed is open).
    static let minimumPollInterval: TimeInterval = 3
    /// Give up waiting for a decoupled approval after this long.
    static let approvalTimeout: TimeInterval = 5 * 60
    static let defaultApprovalMessage = String(localized: "Bitte bestätige den Zugriff in der App deiner Bank.", bundle: .module)

    private let makeBackend: @Sendable () throws -> any YAXIBackend
    private let states: any YAXIStateStore
    private let login: @Sendable () async throws -> YAXILogin?
    private let presenter: (any AuthChallengePresenter)?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private let usage: YAXIUsage

    private var cachedBackend: (any YAXIBackend)?
    private var session: Data?
    private var balances: RXBalances?
    /// The connection state for the current sync: every call writes the newest consent back through `save`.
    private var cachedState: YAXIConnectionState?

    private static let log = YAXIMapper.log

    /// - Parameter login: the bank login for a new consent (O5: stored or asked); `nil` = not available.
    public init(
        connectionID: ConnectionID,
        presenter: (any AuthChallengePresenter)?,
        keyStore: any YAXIKeyStore = KeychainYAXIKeyStore(),
        states: any YAXIStateStore = KeychainYAXIStateStore(),
        login: @escaping @Sendable () async throws -> YAXILogin?
    ) {
        self.init(
            connectionID: connectionID,
            presenter: presenter,
            states: states,
            login: login,
            backend: {
                // Not a login the user could complete here: a setting is missing.
                guard let key = try keyStore.key() else { throw ConnectorError.formatChanged(detail: String(localized: "YAXI-Schlüssel fehlt (Einstellungen → Banken)", bundle: .module)) }
                return try RoutexBackend(key: key)
            }
        )
    }

    init(
        connectionID: ConnectionID,
        presenter: (any AuthChallengePresenter)?,
        states: any YAXIStateStore,
        login: @escaping @Sendable () async throws -> YAXILogin?,
        backend: @escaping @Sendable () throws -> any YAXIBackend,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = Date.init,
        usage: YAXIUsage = .shared
    ) {
        self.usage = usage
        self.connectionID = connectionID
        self.presenter = presenter
        self.states = states
        self.login = login
        makeBackend = backend
        self.sleep = sleep
        self.now = now
    }

    // MARK: - BankConnector

    public func accounts() async throws -> [Account] {
        try await bridged { try await self.syncAccounts() }
    }

    public func balance(for account: Account) async throws -> Balance {
        try await bridged { try await self.loadBalance(for: account) }
    }

    public func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        try await bridged { try await self.loadTransactions(for: account, since: since) }
    }

    private func syncAccounts() async throws -> [Account] {
        // Start of a sync. The key is read anew: a key replaced or removed in Settings applies now.
        session = nil
        balances = nil
        cachedBackend = nil
        cachedState = nil
        // Most of this month's free calls are used: only the user starts syncs until next month.
        if !AuthInteraction.isAllowed, usage.pausesAutomaticSyncs {
            Self.log.notice("YAXI: Kontingent fast verbraucht, automatischer Abgleich pausiert")
            throw ConnectorError.rateLimited(retryAfter: usage.untilNextMonth)
        }
        var state = try loadState()
        if let consent = state.consent {
            if let fetched = state.accountsFetchedAt, now().timeIntervalSince(fetched) < Self.accountsMaxAge, !state.accounts.isEmpty {
                return state.accounts.map(\.account)
            }
            do {
                let outcome = try await backend().accounts(consent: consent, session: nil, userInSession: AuthInteraction.isAllowed)
                return try store(accounts: outcome, in: &state)
            } catch {
                guard YAXIErrors.map(error) == .consentNeeded else { throw connectorError(error) }
                Self.log.info("YAXI: Freigabe abgelaufen")
                state.consent = nil
                try save(state)
            }
        }
        return try await newConsent(&state)
    }

    private func loadBalance(for account: Account) async throws -> Balance {
        let known = try await knownLoading(account)
        var state = try loadState()
        if balances == nil {
            let references = state.accounts.compactMap(YAXIMapper.accountReference)
            let outcome = try await call(&state) { backend, consent, session, inSession in
                try await backend.balances(consent: consent, accounts: references, session: session, userInSession: inSession)
            }
            balances = outcome
        }
        guard let balances else { throw ConnectorError.formatChanged(detail: "YAXI Saldo fehlt") }
        return try YAXIMapper.balance(balances, for: known, asOf: now())
    }

    private func loadTransactions(for account: Account, since: Date?) async throws -> [Transaction] {
        let known = try await knownLoading(account)
        var state = try loadState()
        guard let reference = YAXIMapper.accountReference(known) else { throw ConnectorError.unsupportedAccount }
        let today = BankDay(now())
        var from = since.map(BankDay.init) ?? today.adding(days: -Self.firstImportDays)

        let items: [RXTransaction]
        do {
            items = try await call(&state) { [from] backend, consent, session, inSession in
                try await backend.transactions(consent: consent, account: reference, from: from, session: session, userInSession: inSession)
            }
        } catch YAXIFailure.periodOutOfBounds {
            let fallback = today.adding(days: -Self.fallbackDays)
            guard fallback > from else { throw ConnectorError.formatChanged(detail: "YAXI Zeitraum abgelehnt") }
            Self.log.info("YAXI: Zeitraum zu lang, \(Self.fallbackDays, privacy: .public) Tage")
            from = fallback
            items = try await call(&state) { [from] backend, consent, session, inSession in
                try await backend.transactions(consent: consent, account: reference, from: from, session: session, userInSession: inSession)
            }
        }

        let mapped = try items.map { item throws(ConnectorError) in try YAXIMapper.transaction(item, account: known.account, today: today) }
        // Pending transactions are returned regardless of `since` (BankConnector contract).
        let filtered = mapped.filter { $0.status == .pending || $0.effectiveDate >= from }
        Self.log.info("YAXI: \(filtered.count, privacy: .public) Umsätze")
        return Transaction.uniquingIDs(filtered)
    }

    public func cardStatements(for account: Account) async throws -> [CardStatement] {
        _ = try known(account, in: try loadState())
        return []
    }

    public func securities(for account: Account) async throws -> [SecurityPosition] {
        _ = try known(account, in: try loadState())
        return [] // YAXI has no positions service; depots are not offered (YAXIMapper).
    }

    // MARK: - Calls

    private func backend() throws -> any YAXIBackend {
        if let cachedBackend { return cachedBackend }
        do {
            let made = try makeBackend()
            cachedBackend = made
            return made
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw ConnectorError.formatChanged(detail: "yaxi key")
        }
    }

    /// A call with the stored consent. Keeps the newest consent and session; a consent that needs the
    /// user again mid-sync ends the sync (`sessionExpired`) and is dropped, so the next sync asks.
    private func call<Payload: Sendable>(
        _ state: inout YAXIConnectionState,
        _ body: @Sendable (any YAXIBackend, Data, Data?, Bool) async throws -> YAXIOutcome<Payload>
    ) async throws(YAXIFailure) -> Payload {
        guard let consent = state.consent else { throw .connector(.sessionExpired) }
        do {
            let outcome = try await body(try backend(), consent, session, AuthInteraction.isAllowed)
            session = outcome.session ?? session
            if let newer = outcome.consent, newer != state.consent {
                state.consent = newer
                try save(state)
            }
            return outcome.payload
        } catch {
            let failure = YAXIErrors.map(error)
            if failure == .consentNeeded {
                state.consent = nil
                try save(state)
                throw .connector(.sessionExpired)
            }
            throw failure
        }
    }

    private func store(accounts outcome: YAXIOutcome<[RXAccount]>, in state: inout YAXIConnectionState) throws -> [Account] {
        session = outcome.session ?? session
        if let consent = outcome.consent { state.consent = consent }
        let known = outcome.payload.compactMap { YAXIMapper.account($0, connection: connectionID) }
        state.accounts = known
        state.accountsFetchedAt = now()
        try save(state)
        Self.log.notice("YAXI: \(known.count, privacy: .public) Konten")
        return known.map(\.account)
    }

    // MARK: - New consent

    private func newConsent(_ state: inout YAXIConnectionState) async throws -> [Account] {
        let reason = AuthChallenge.pushConfirm(message: String(localized: "\(state.bankName) braucht eine neue Freigabe.", bundle: .module))
        guard AuthInteraction.isAllowed, presenter != nil else { throw ConnectorError.authRequired(reason) }
        guard let login = try await login() else { throw ConnectorError.authRequired(reason) }
        Self.log.info("YAXI: neue Freigabe")
        let bank = state.bank
        let outcome: YAXIOutcome<[RXAccount]>
        do {
            outcome = try await drive(try await backend().consent(bank: bank, login: login))
        } catch {
            throw connectorError(error)
        }
        guard outcome.consent != nil else { throw ConnectorError.formatChanged(detail: "yaxi: keine Freigabe erhalten") }
        return try store(accounts: outcome, in: &state)
    }

    /// Answers the bank's questions through the presenter until the call is done.
    private func drive<Payload: Sendable>(_ first: YAXIStep<Payload>) async throws -> YAXIOutcome<Payload> {
        var step = first
        while true {
            switch step {
            case let .done(outcome):
                return outcome
            case let .dialog(dialog, next):
                if case .poll = dialog.input {
                    step = try await poll(dialog, next: next)
                } else {
                    step = try await next(try await answer(dialog))
                }
            }
        }
    }

    private func answer(_ dialog: YAXIDialog) async throws -> YAXIAnswer {
        let message = dialog.message.map(Self.displayText).flatMap { $0.isEmpty ? nil : $0 }
        switch dialog.input {
        case .poll:
            return .confirmed // handled by `poll`
        case .confirm:
            let response = try await present(.pushConfirm(message: message ?? Self.defaultApprovalMessage))
            guard response == .confirmed else { throw ConnectorError.cancelled }
            return .confirmed
        case let .field(secret, minLength, maxLength):
            let length = minLength != nil && minLength == maxLength ? maxLength ?? 0 : 0
            let prompt = message ?? (dialog.image == nil ? (secret ? "PIN" : "TAN") : String(localized: "Gib die TAN zur Grafik ein.", bundle: .module))
            let challenge: AuthChallenge
            if let image = dialog.image {
                // v12: photoTAN or chipTAN optic.
                guard image.data.count <= AuthImage.maximumBytes else { throw ConnectorError.formatChanged(detail: "yaxi image too large") }
                challenge = .imageCode(prompt: prompt, length: length,
                                       image: AuthImage(mimeType: image.mimeType, data: image.data, physicalWidthMM: image.isFlicker ? 62.5 : nil))
            } else if secret {
                // v12: a PIN or password the bank asks for in a dialog: masked, never a code field.
                challenge = .secret(prompt: prompt, length: length)
            } else {
                challenge = .code(prompt: prompt, length: length)
            }
            guard case let .code(code) = try await present(challenge), !code.isEmpty else { throw ConnectorError.cancelled }
            return .text(code)
        case let .selection(options):
            // A single option needs no question.
            if options.count == 1, let only = options.first { return .text(only.key) }
            guard !options.isEmpty else { throw ConnectorError.formatChanged(detail: "yaxi selection dialog") }
            let choices = options.map { AuthOption(key: $0.key, label: Self.displayText($0.label), detail: $0.detail.map(Self.displayText)) }
            guard case let .code(key) = try await present(.choice(prompt: message ?? String(localized: "Bitte wähle aus.", bundle: .module), options: choices)),
                  options.contains(where: { $0.key == key }) else { throw ConnectorError.cancelled }
            return .text(key)
        case let .redirect(url):
            guard url.scheme == "https" else { throw ConnectorError.formatChanged(detail: "yaxi redirect") }
            // v12: a completion with MFN's own scheme opens the system's login window (the bank's
            // page, its own cookies only for this login), not the app's web view (AuthChallengeSheet).
            let request = WebLoginRequest(url: url, completion: .urlPrefix(RoutexBackend.redirectURI), cookieDomains: [],
                                          message: String(localized: "Melde dich auf der Seite deiner Bank an und gib den Zugriff frei. MFN sieht dabei weder deine Zugangsdaten noch die Seite.", bundle: .module))
            _ = try await present(.webLogin(request))
            return .confirmed
        }
    }

    /// Decoupled approval: the sheet stays open while MFN asks the bank again; "Ich habe bestätigt" asks
    /// at once (and shows the sheet again if the bank has not seen the approval yet), closing it cancels.
    private func poll<Payload: Sendable>(
        _ dialog: YAXIDialog, next: @escaping @Sendable (YAXIAnswer) async throws -> YAXIStep<Payload>
    ) async throws -> YAXIStep<Payload> {
        let message = dialog.message.map(Self.displayText).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultApprovalMessage
        let challenge = AuthChallenge.decoupled(message: message, pollInterval: Self.minimumPollInterval)
        guard let presenter else { throw ConnectorError.authRequired(challenge) }
        let signal = ApprovalSignal()
        func show() -> Task<Void, Never> {
            Task {
                do {
                    let response = try await presenter.present(challenge)
                    await signal.finish(response == .confirmed ? .confirmed : .cancelled)
                } catch is CancellationError {
                    // Closed by us after the bank answered.
                } catch {
                    await signal.finish(.cancelled)
                }
            }
        }
        var presentation = show()
        defer { presentation.cancel() }

        let started = now()
        var lastPoll: Date?
        var step = YAXIStep<Payload>.dialog(dialog, next: next)
        while case let .dialog(current, continuation) = step, case let .poll(delay) = current.input {
            if await signal.state == .cancelled { throw ConnectorError.cancelled }
            // Not approved in time: the approval is still due, the user starts it again.
            guard now().timeIntervalSince(started) < Self.approvalTimeout else { throw ConnectorError.authRequired(challenge) }
            let confirmed = await signal.consumeConfirmation()
            if !confirmed {
                try await sleep(max(delay ?? Self.minimumPollInterval, Self.minimumPollInterval))
            } else if let lastPoll {
                // "Bestätigt" right after a poll: still keep the minimum distance between two polls.
                let wait = Self.minimumPollInterval - now().timeIntervalSince(lastPoll)
                if wait > 0 { try await sleep(wait) }
            }
            if await signal.state == .cancelled { throw ConnectorError.cancelled }
            lastPoll = now()
            step = try await continuation(.confirmed)
            // The user said "bestätigt" but the bank still waits: the sheet comes back.
            if confirmed, case let .dialog(again, _) = step, case .poll = again.input {
                presentation = show()
            }
        }
        return step
    }

    private func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
        guard let presenter else { throw ConnectorError.authRequired(challenge) }
        return try await presenter.present(challenge)
    }

    // MARK: - State

    private func loadState() throws -> YAXIConnectionState {
        let state: YAXIConnectionState?
        if let cachedState { return cachedState }
        do {
            state = try states.state(for: connectionID)
        } catch {
            throw ConnectorError.formatChanged(detail: "yaxi state")
        }
        guard let state else { throw ConnectorError.formatChanged(detail: "yaxi: Verbindung ohne Bank") }
        cachedState = state
        return state
    }

    private func save(_ state: YAXIConnectionState) throws(YAXIFailure) {
        do {
            try states.set(state, for: connectionID)
            cachedState = state
        } catch {
            cachedState = nil
            Self.log.error("YAXI: Zustand nicht gespeichert")
            throw .connector(.formatChanged(detail: "yaxi state"))
        }
    }

    /// Like `known`, but loads the account list first when this connector has not seen it yet.
    private func knownLoading(_ account: Account) async throws -> YAXIConnectionState.KnownAccount {
        guard account.connectionID == connectionID else { throw ConnectorError.unsupportedAccount }
        if let known = try? known(account, in: try loadState()) { return known }
        _ = try await syncAccounts()
        return try known(account, in: try loadState())
    }

    private func known(_ account: Account, in state: YAXIConnectionState) throws -> YAXIConnectionState.KnownAccount {
        guard account.connectionID == connectionID, let known = state.accounts.first(where: { $0.account.id == account.id }) else {
            throw ConnectorError.unsupportedAccount
        }
        return known
    }

    /// Every error leaves the connector as `ConnectorError` (protocol contract).
    private func bridged<T>(_ body: () async throws -> T) async throws(ConnectorError) -> T {
        do {
            return try await body()
        } catch {
            let mapped = connectorError(error)
            // Every `formatChanged` detail of this connector is a fixed text without bank data.
            if case let .formatChanged(detail) = mapped {
                Self.log.notice("YAXI: \(detail, privacy: .public)")
            }
            throw mapped
        }
    }

    private func connectorError(_ error: any Error) -> ConnectorError {
        switch YAXIErrors.map(error) {
        case let .connector(connector): connector
        case .consentNeeded: .sessionExpired
        case .periodOutOfBounds: .formatChanged(detail: "YAXI Zeitraum abgelehnt")
        }
    }

    /// Bank text for MFN's own UI: no control, line break or bidirectional formatting characters.
    static func displayText(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: false
            default: true
            }
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return cleaned.count > 300 ? String(cleaned.prefix(299)) + "…" : cleaned
    }
}

/// Outcome of the approval sheet while polling (as in FinTS' decoupled handler).
actor ApprovalSignal {
    enum State: Equatable { case waiting, confirmed, cancelled }

    private(set) var state: State = .waiting

    func finish(_ state: State) {
        if self.state == .waiting { self.state = state }
    }

    /// `true` once after the user tapped "Bestätigt": ask the bank now instead of waiting.
    func consumeConfirmation() -> Bool {
        guard state == .confirmed else { return false }
        state = .waiting
        return true
    }
}
