import Foundation

/// Orchestrates connectors and writes their results into the store.
///
/// For the engine, FinTS and scraping connectors are indistinguishable. Rules (CLAUDE.md §1):
/// - at most one sync per connection at a time (a second request joins the running one),
/// - automatic syncs at most every 15 minutes, and not after an error that forbids retry
///   (failed login → risk of locking the account) or after 3 consecutive failures,
/// - `rateLimited(retryAfter:)` blocks automatic syncs until the bank's deadline,
/// - automatic (timer) syncs never start a login: a connector that needs one ends in
///   `waitingForApproval` and the bank waits for a manual sync (no push/SMS without the user),
/// - after the bank rejected stored credentials (`failed(.authFailed)`) no sync starts at all,
///   not even a manual one, until the user saved new credentials (`credentialsChanged(_:)`):
///   sending the rejected credentials again risks locking the bank login.
public actor SyncEngine {
    public enum Trigger: Sendable {
        /// User pressed ⌘R / ⇧⌘R: runs unless the bank rejected the stored credentials.
        case manual
        /// Timer: subject to interval and failure rules, never logs in (`AuthInteraction`).
        case automatic
        /// Right after unlocking: interval and failure rules like `.automatic`, but the user is
        /// at the Mac, so a login may ask for approval.
        case unlock

        var allowsLogin: Bool { self != .automatic }
    }

    public static let minimumAutomaticInterval: TimeInterval = 15 * 60
    public static let maximumConsecutiveFailures = 3
    /// Overlap for incremental fetches so late bookings with older dates are not missed.
    public static let incrementalOverlapDays = 14

    private let store: any LedgerStore
    private let now: @Sendable () -> Date
    private var connectors: [ConnectionID: any BankConnector] = [:]
    /// The running sync per connection. The token tells a finished sync whether the slot is
    /// still its own (after `unregister` + `register` a new sync may hold it).
    private var running: [ConnectionID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var blockedUntil: [ConnectionID: Date] = [:]
    private let afterSync: (@Sendable (ConnectionID) async -> Void)?

    /// - Parameter afterSync: Runs after every successful sync of a connection, once its state
    ///   is back to idle (the app categorizes new transactions here). A sync that joins a running
    ///   one does not run it again.
    public init(store: any LedgerStore, now: @escaping @Sendable () -> Date = Date.init, afterSync: (@Sendable (ConnectionID) async -> Void)? = nil) {
        self.store = store
        self.now = now
        self.afterSync = afterSync
    }

    public func register(_ connection: Connection, connector: any BankConnector) async throws {
        try await store.upsert(connection: connection)
        // v10: an account without a bank connection never syncs, whatever connector is passed.
        guard connection.connectorID.hasConnector else { return }
        connectors[connection.id] = connector
    }

    /// Forgets a connection (before "Bank entfernen" deletes its data). A running sync of it is
    /// cancelled and awaited, so it cannot write into the store afterwards.
    public func unregister(_ id: ConnectionID) async {
        connectors[id] = nil
        blockedUntil[id] = nil
        if let task = running[id]?.task {
            task.cancel()
            await task.value
        }
    }

    /// The user saved new credentials for `id`: a login rejected with the old ones
    /// (`failed(.authFailed)`) may be tried again. Other states are left alone.
    public func credentialsChanged(_ id: ConnectionID) async {
        var state = await store.syncState(for: id)
        guard case .failed(.authFailed) = state.phase else { return }
        state.phase = .idle
        state.consecutiveFailures = 0
        await saveState(state, for: id)
        Log.sync.info("Zugangsdaten geändert, Anmeldung wieder erlaubt: \(id.rawValue, privacy: .public)")
    }

    public var registeredConnections: [ConnectionID] { Array(connectors.keys) }

    public func syncAll(trigger: Trigger) async {
        await withTaskGroup(of: Void.self) { group in
            for id in connectors.keys {
                group.addTask { await self.sync(id, trigger: trigger) }
            }
        }
    }

    /// Syncs one connection. Joins an already running sync of the same connection.
    ///
    /// The slot is taken before the first suspension point, so concurrent calls never start two
    /// syncs (two logins) of one connection. Cancelling the caller that started the sync cancels
    /// it; callers that joined only stop waiting when it ends.
    public func sync(_ id: ConnectionID, trigger: Trigger) async {
        if let task = running[id]?.task {
            await task.value
            return
        }
        guard let connector = connectors[id] else { return }

        let token = UUID()
        let task = Task {
            await self.run(id, connector: connector, trigger: trigger, token: token)
        }
        running[id] = (token, task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func run(_ id: ConnectionID, connector: any BankConnector, trigger: Trigger, token: UUID) async {
        defer { if running[id]?.token == token { running[id] = nil } }
        guard await shouldRun(id, connectorID: connector.id, trigger: trigger),
              // Unregistered (or cancelled) while the state was read.
              !Task.isCancelled, connectors[id] != nil
        else { return }
        await AuthInteraction.$isAllowed.withValue(trigger.allowsLogin) {
            await self.perform(id, connector: connector)
        }
    }

    private func shouldRun(_ id: ConnectionID, connectorID: ConnectorID, trigger: Trigger) async -> Bool {
        let state = await store.syncState(for: id)
        // The bank rejected the stored credentials: only new ones may be sent (lockout risk).
        // Connectors without stored credentials (visible web login) get typed input each time.
        if case .failed(.authFailed) = state.phase, !connectorID.credentialFields.isEmpty {
            Log.sync.notice("Sync \(id.rawValue, privacy: .public) übersprungen: Anmeldung abgelehnt, erst Zugangsdaten ändern")
            return false
        }
        guard trigger != .manual else { return true }
        // A login is due: only the user starts it (manual sync or "Jetzt anmelden").
        if case .waitingForApproval = state.phase { return false }
        if let until = blockedUntil[id], until > now() { return false }
        if state.consecutiveFailures >= Self.maximumConsecutiveFailures { return false }
        if case let .failed(error) = state.phase, error.forbidsAutomaticRetry { return false }
        if let last = state.lastSuccess, now().timeIntervalSince(last) < Self.minimumAutomaticInterval { return false }
        return true
    }

    private func perform(_ id: ConnectionID, connector: any BankConnector) async {
        var state = await store.syncState(for: id)
        let previousSuccess = state.lastSuccess
        state.phase = .syncing
        await saveState(state, for: id)
        Log.sync.info("Sync start \(id.rawValue, privacy: .public) (\(connector.id.rawValue, privacy: .public))")

        var succeeded = false
        do {
            try await fetch(id, connector: connector, since: previousSuccess)
            succeeded = true
            state.phase = .idle
            state.lastSuccess = now()
            state.consecutiveFailures = 0
            blockedUntil[id] = nil
            Log.sync.info("Sync ok \(id.rawValue, privacy: .public)")
        } catch let error as StoreWriteError {
            state.phase = .storeFailed(error.message)
            state.consecutiveFailures += 1
            // The message can carry SQL detail derived from bank data: private.
            Log.sync.error("Sync \(id.rawValue, privacy: .public): Speichern fehlgeschlagen: \(error.message, privacy: .private)")
        } catch ConnectorError.authRequired(let challenge) {
            // Not a failure: the session ran out and a login needs the user.
            state.phase = .waitingForApproval(challenge)
            Log.sync.notice("Sync \(id.rawValue, privacy: .public): Anmeldung nötig, wartet auf den Nutzer")
        } catch {
            let connectorError = Self.connectorError(from: error)
            state.phase = .failed(connectorError)
            state.consecutiveFailures += 1
            if case let .rateLimited(retryAfter) = connectorError {
                blockedUntil[id] = now().addingTimeInterval(retryAfter)
            }
            // Case name public (diagnosable), detail (e.g. `formatChanged` text from bank responses) private.
            Log.sync.error("Sync failed \(id.rawValue, privacy: .public): \(Self.caseName(of: connectorError), privacy: .public) \(connectorError.description, privacy: .private)")
        }
        await saveState(state, for: id)
        if succeeded, let afterSync { await afterSync(id) }
    }

    /// Persisting the sync state is the last resort for reporting; if even that fails the
    /// error is logged (it cannot be shown anywhere else).
    private func saveState(_ state: SyncState, for id: ConnectionID) async {
        do {
            try await store.setSyncState(state, for: id)
        } catch {
            Log.sync.fault("Sync-Status für \(id.rawValue, privacy: .public) nicht speicherbar: \(String(describing: error), privacy: .private)")
        }
    }

    /// The error's case without associated values, safe to log publicly.
    static func caseName(of error: ConnectorError) -> String {
        switch error {
        case .authRequired: "authRequired"
        case .authFailed: "authFailed"
        case .sessionExpired: "sessionExpired"
        case .rateLimited: "rateLimited"
        case .bankUnavailable: "bankUnavailable"
        case .formatChanged: "formatChanged"
        case .unsupportedAccount: "unsupportedAccount"
        case .cancelled: "cancelled"
        }
    }

    /// Wraps store writes so their failures are not mistaken for connector errors.
    private func persist(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            throw StoreWriteError(message: String(describing: error))
        }
    }

    private func fetch(_ id: ConnectionID, connector: any BankConnector, since lastSuccess: Date?) async throws {
        let accounts = try await connector.accounts()
        try await persist { try await store.replaceAccounts(accounts, of: id) }

        let since: Date? = lastSuccess.map {
            BankDay($0).adding(days: -Self.incrementalOverlapDays).startDate
        }

        for account in accounts {
            try Task.checkCancellation()
            let balance = try await connector.balance(for: account)
            let incoming = try await connector.transactions(for: account, since: since)
            let statements: [CardStatement]? = if account.type == .card { try await connector.cardStatements(for: account) } else { nil }
            let positions: [SecurityPosition]? = if account.type == .depot { try await connector.securities(for: account) } else { nil }
            try Task.checkCancellation()
            // One write per account (one published snapshot); the store merges against what it
            // holds at that moment.
            let update = AccountUpdate(accountID: account.id, balance: balance, transactions: incoming, since: since.map(BankDay.init),
                                       cardStatements: statements, securities: positions)
            try await persist { try await store.apply(update) }
        }
    }

    /// Connectors must only throw `ConnectorError`. Anything else is a connector bug; it is
    /// surfaced as `formatChanged` so it is visible, never swallowed.
    static func connectorError(from error: any Error) -> ConnectorError {
        if let error = error as? ConnectorError { return error }
        if error is CancellationError { return .cancelled }
        return .formatChanged(detail: "Unerwarteter Fehler: \(type(of: error))")
    }
}

struct StoreWriteError: Error {
    let message: String
}

/// Whether a login may ask the user right now (task-local, set by `SyncEngine` per sync).
///
/// `false` during automatic syncs: the app's approval presenter then throws
/// `ConnectorError.authRequired` instead of showing a sheet or running a headless login (which
/// would send a push or SMS while nobody is at the Mac). Task-local values carry over into
/// child tasks and `Task {}` started inside connectors.
public enum AuthInteraction {
    @TaskLocal public static var isAllowed = true
}
