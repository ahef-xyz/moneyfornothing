import Foundation
import MFNCore

/// How a mock bank behaves. Lets UI, previews and tests exercise every path of a real connector.
public enum MockScenario: Sendable, Equatable {
    /// Delivers data without interaction (like ING).
    case ok
    /// Asks the presenter for approval first (decoupled TAN, 2FA code, push). Without a presenter
    /// the connector throws `ConnectorError.authRequired`.
    case requiresApproval(AuthChallenge)
    /// Every call throws this error.
    case failing(ConnectorError)
}

/// Which version of the mock world the connector serves.
public enum MockPhase: Sendable, Equatable {
    case current
    /// A few days later: every pending transaction has been booked.
    case afterBooking
}

/// `BankConnector` over a `MockDataset`. Stays in the project permanently: previews, UI tests,
/// conformance reference and demo mode use it.
public struct MockConnector: BankConnector {
    public let id: ConnectorID
    public let connectionID: ConnectionID
    public let dataset: MockDataset
    public var scenario: MockScenario
    public var phase: MockPhase
    public var presenter: (any AuthChallengePresenter)?
    public var latency: Duration

    private static let log = Log.logger("mock")

    public init(
        connection: ConnectionID,
        dataset: MockDataset,
        scenario: MockScenario = .ok,
        phase: MockPhase = .current,
        presenter: (any AuthChallengePresenter)? = nil,
        latency: Duration = .zero
    ) {
        self.connectionID = connection
        self.id = dataset.connections.first { $0.id == connection }?.connectorID ?? .mock
        self.dataset = dataset
        self.scenario = scenario
        self.phase = phase
        self.presenter = presenter
        self.latency = latency
    }

    public func accounts() async throws -> [Account] {
        try await gate(authenticate: true)
        return dataset.accounts(of: connectionID)
    }

    public func balance(for account: Account) async throws -> Balance {
        try await gate()
        try check(account)
        return dataset.balance(for: account.id, afterBooking: phase == .afterBooking)
    }

    public func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        try await gate()
        try check(account)
        let source = phase == .afterBooking ? dataset.transactionsAfterBooking : dataset.transactions
        let all = source[account.id] ?? []
        guard let since else { return all }
        let from = BankDay(since)
        return all.filter { $0.effectiveDate >= from }
    }

    public func cardStatements(for account: Account) async throws -> [CardStatement] {
        try await gate()
        try check(account)
        guard account.type == .card else { return [] }
        return dataset.cardStatements[account.id] ?? []
    }

    public func securities(for account: Account) async throws -> [SecurityPosition] {
        try await gate()
        try check(account)
        guard account.type == .depot else { return [] }
        return dataset.securities[account.id] ?? []
    }

    // MARK: -

    private func gate(authenticate: Bool = false) async throws {
        if latency > .zero {
            do { try await Task.sleep(for: latency) } catch { throw ConnectorError.cancelled }
        }
        switch scenario {
        case .ok:
            return
        case let .failing(error):
            Self.log.notice("Mock \(connectionID.rawValue, privacy: .public) fails: \(error.description, privacy: .public)")
            throw error
        case let .requiresApproval(challenge):
            guard authenticate else { return }
            guard let presenter else { throw ConnectorError.authRequired(challenge) }
            let response: AuthResponse
            do {
                response = try await presenter.present(challenge)
            } catch let error as ConnectorError {
                throw error
            } catch {
                throw ConnectorError.cancelled
            }
            try validate(response, for: challenge)
        }
    }

    private func validate(_ response: AuthResponse, for challenge: AuthChallenge) throws {
        switch (challenge, response) {
        case let (.code(_, length), .code(code)):
            // Mock rule: any all-digit code of the right length is accepted, "0000…" is rejected.
            guard code.count == length, code.allSatisfy(\.isNumber), Set(code) != ["0"] else {
                throw ConnectorError.authFailed
            }
        case (.decoupled, .confirmed), (.pushConfirm, .confirmed), (.webLogin, .webSession):
            return
        default:
            throw ConnectorError.authFailed
        }
    }

    private func check(_ account: Account) throws {
        guard account.connectionID == connectionID,
              dataset.accounts.contains(where: { $0.id == account.id }) else {
            throw ConnectorError.unsupportedAccount
        }
    }
}

extension MockDataset {
    /// The default demo setup: one connector per bank, with approval flows like the real banks.
    public func demoConnectors(presenter: (any AuthChallengePresenter)?, latency: Duration = .milliseconds(400)) -> [(Connection, MockConnector)] {
        let scenarios: [ConnectionID: MockScenario] = [
            MockConnections.ing: .ok,
            MockConnections.dkb: .requiresApproval(.decoupled(message: "Bitte bestätigen Sie den Zugriff in der DKB-App.", pollInterval: 2)),
            MockConnections.tradeRepublic: .requiresApproval(.code(prompt: "Code aus der Trade-Republic-App", length: 4)),
            MockConnections.c24: .requiresApproval(.pushConfirm(message: "Bitte bestätigen Sie die Anmeldung in der C24-App.")),
            MockConnections.easybank: .ok,
        ]
        return connections.map { connection in
            (connection, MockConnector(connection: connection.id, dataset: self, scenario: scenarios[connection.id] ?? .ok, presenter: presenter, latency: latency))
        }
    }

    /// All data loaded into a snapshot, without running a sync. For previews.
    public func snapshot() -> LedgerSnapshot {
        var snapshot = LedgerSnapshot()
        snapshot.connections = connections
        snapshot.accounts = accounts
        snapshot.transactions = allTransactions.sorted { $0.effectiveDate > $1.effectiveDate }
        snapshot.cardStatements = cardStatements.values.flatMap { $0 }
        snapshot.securities = securities.values.flatMap { $0 }
        for account in accounts {
            snapshot.balances[account.id] = balance(for: account.id)
        }
        for connection in connections {
            snapshot.syncStates[connection.id] = SyncState(lastSuccess: now)
        }
        return snapshot
    }
}
