import CryptoKit
import Foundation
import MFNCore
import MFNFinTS

/// How a connection reaches its bank: the bank's standard connector (web banking, app API) or
/// FinTS. App-side only, the frozen protocol knows one `ConnectorID` per bank.
///
/// ING is FinTS only (`fintsOnly`). DKB still uses web banking; FinTS for it is offered in
/// developer mode as a separate bank until its registration is active. Every FinTS connection
/// carries `fints-` in front of its `ConnectionID` (stored in the ledger, so the choice survives
/// relaunches); that prefix alone decides. An ING connection without it is an old web banking
/// connection: it keeps its data, is not synced any more and can be merged ("Zusammenführen
/// prüfen") or removed. FinTS uses its own account IDs; `ConnectionMerge` moves the data over.
struct BankAccess: Hashable, Identifiable {
    let connector: ConnectorID
    let isFinTS: Bool

    var id: String { isFinTS ? "fints-\(connector.rawValue)" : connector.rawValue }

    /// The access a bank gets by default: FinTS for `fintsOnly`, else its own connector.
    static func standard(_ connector: ConnectorID) -> BankAccess {
        BankAccess(connector: connector, isFinTS: fintsOnly.contains(connector))
    }

    static func fints(_ connector: ConnectorID) -> BankAccess { BankAccess(connector: connector, isFinTS: true) }

    static let connectionPrefix = "fints-"

    static func of(_ connection: Connection) -> BankAccess {
        BankAccess(connector: connection.connectorID, isFinTS: connection.id.rawValue.hasPrefix(connectionPrefix))
    }

    /// A web banking connection of a bank that is FinTS only now (no connector any more).
    static func isRetiredWeb(_ connection: Connection) -> Bool {
        !of(connection).isFinTS && fintsOnly.contains(connection.connectorID)
    }

    /// Banks with a FinTS connector in this build.
    static let fintsBanks: [ConnectorID] = [.ing, .dkb]
    /// Banks reached over FinTS only (no web banking connector any more).
    static let fintsOnly: Set<ConnectorID> = [.ing]
    /// FinTS as a second, developer-mode entry next to the bank's standard connector.
    static var fintsTestBanks: [ConnectorID] { fintsBanks.filter { !fintsOnly.contains($0) } }

    /// "(FinTS)" only where the bank also has another access.
    var displayName: String {
        isFinTS && !Self.fintsOnly.contains(connector) ? "\(connector.displayName) (FinTS)" : connector.displayName
    }

    func newConnectionID() -> ConnectionID {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ConnectionID("\(isFinTS ? Self.connectionPrefix : "")\(connector.rawValue)-\(suffix)")
    }

    /// Fields of the login form. FinTS logs in with the Zugangsnummer/Anmeldename and the PIN for
    /// FinTS (HBCI), which can differ from the web banking password. ING's are in `MFNCore` (v8).
    var credentialFields: [CredentialField] {
        guard isFinTS, !Self.fintsOnly.contains(connector) else { return connector.credentialFields }
        return [CredentialField(key: FinTSKeys.userID, label: "Anmeldename", kind: .text),
                CredentialField(key: FinTSKeys.pin, label: "PIN", kind: .secret)]
    }

    func isComplete(_ credentials: BankCredentials) -> Bool {
        CredentialForm.problem(credentials.values, fields: credentialFields) == nil
    }
}

enum FinTSKeys {
    static let userID = "userID"
    static let pin = "pin"

    /// Keychain keys of the customer system ID (DKB: the key of `KeychainDKBStateStore`).
    static func systemIDKey(_ connection: ConnectionID, connector: ConnectorID) -> String {
        "fints.\(connector.rawValue).systemID.\(connection.rawValue)"
    }

    /// Whose system ID that is: SHA-256 of the user ID (never the ID itself). A system ID belongs
    /// to one user; after a change of Zugangsnummer/Anmeldename it is dropped and synchronised anew.
    static func systemIDOwnerKey(_ connection: ConnectionID, connector: ConnectorID) -> String {
        "fints.\(connector.rawValue).systemIDOwner.\(connection.rawValue)"
    }

    static func ownerTag(_ userID: String) -> Data {
        Data(SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined().utf8)
    }
}

/// The FinTS product registration from the build (`MFNApp/Config`, the number itself is gitignored).
enum FinTSRegistration {
    static var product: FinTSProduct {
        let id = (Bundle.main.object(forInfoDictionaryKey: "MFNFinTSProductID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        // An unset build variable arrives empty or as the literal `$(…)`.
        guard !id.isEmpty, !id.hasPrefix("$(") else { return .unregistered }
        return FinTSProduct(registrationID: id, version: productVersion)
    }

    static var isRegistered: Bool { product != .unregistered }

    /// HKVVB allows at most 5 characters.
    private static var productVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        return String(version.prefix(5))
    }
}

/// `BankConnector` for a FinTS connection. Reads the credentials from the keychain on every call,
/// so "Zugangsdaten ändern…" applies to the next sync. The inner connector (with its BPD/UPD
/// cache) is kept while the credentials stay the same. Calls are serialised here too, so an old
/// and a new inner connector never run dialogs in parallel after a credential change.
actor FinTSConnection: BankConnector {
    nonisolated let id: ConnectorID
    private let connection: Connection
    private let presenter: any AuthChallengePresenter
    private let credentialStore: CredentialStore
    private let keychain = Keychain()
    private var cached: (credentials: BankCredentials, connector: any BankConnector)?
    /// Last ING system ID in the keychain: written only when it changes.
    private var savedSystemID: String?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let log = Log.logger("fints")

    init(connection: Connection, presenter: any AuthChallengePresenter, credentialStore: CredentialStore = CredentialStore()) {
        self.id = connection.connectorID
        self.connection = connection
        self.presenter = presenter
        self.credentialStore = credentialStore
    }

    func accounts() async throws -> [Account] {
        try await run { try await $0.accounts() }
    }

    func balance(for account: Account) async throws -> Balance {
        try await run { try await $0.balance(for: account) }
    }

    func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        try await run { try await $0.transactions(for: account, since: since) }
    }

    func cardStatements(for account: Account) async throws -> [CardStatement] {
        try await run { try await $0.cardStatements(for: account) }
    }

    func securities(for account: Account) async throws -> [SecurityPosition] {
        try await run { try await $0.securities(for: account) }
    }

    /// Saves ING's system ID after every call, failed ones included: the bank may have assigned
    /// it before the error.
    private func run<T: Sendable>(_ body: (any BankConnector) async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        let inner = try connector()
        do {
            let result = try await body(inner)
            await saveSystemID(of: inner)
            return result
        } catch {
            await saveSystemID(of: inner)
            throw error
        }
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lock to the next waiter directly (`busy` stays set).
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func connector() throws(ConnectorError) -> any BankConnector {
        let stored: BankCredentials?
        do {
            stored = try credentialStore.credentials(for: connection.id)
        } catch {
            // Not the bank's verdict: no `authFailed` (that blocks the connection until new credentials).
            Self.log.error("FinTS: Zugangsdaten nicht lesbar (\(String(describing: type(of: error)), privacy: .public))")
            throw .cancelled
        }
        guard let credentials = stored, BankAccess.of(connection).isComplete(credentials) else {
            Self.log.error("FinTS: Zugangsdaten fehlen oder sind unvollständig")
            throw .authFailed
        }
        if let cached, cached.credentials == credentials { return cached.connector }

        let userID = credentials[FinTSKeys.userID] ?? ""
        let pin = credentials[FinTSKeys.pin] ?? ""
        let product = FinTSRegistration.product
        let made: any BankConnector
        switch connection.connectorID {
        case .ing:
            let systemID = try storedSystemID(for: userID, connector: .ing)
            savedSystemID = systemID
            made = MFNFinTS.INGConnector(connectionID: connection.id, userID: userID, pin: pin, product: product, systemID: systemID ?? "0")
        case .dkb:
            // `KeychainDKBStateStore` reads the ID itself; only drop another user's.
            _ = try storedSystemID(for: userID, connector: .dkb)
            made = MFNFinTS.DKBConnector(
                connectionID: connection.id,
                credentials: FinTSCredentials(userID: userID, pin: pin),
                presenter: presenter,
                product: product,
                stateStore: KeychainDKBStateStore(connectionID: connection.id, keychain: keychain)
            )
        default:
            throw .unsupportedAccount
        }
        cached = (credentials, made)
        return made
    }

    /// The stored system ID if it belongs to `userID`; another user's ID is deleted first.
    /// Keychain errors stop the call instead of silently registering a new system ID.
    private func storedSystemID(for userID: String, connector: ConnectorID) throws(ConnectorError) -> String? {
        let idKey = FinTSKeys.systemIDKey(connection.id, connector: connector)
        let ownerKey = FinTSKeys.systemIDOwnerKey(connection.id, connector: connector)
        let owner = FinTSKeys.ownerTag(userID)
        do {
            if try keychain.data(for: ownerKey) != owner {
                try keychain.delete(idKey)
                try keychain.set(owner, for: ownerKey)
                return nil
            }
            return try keychain.data(for: idKey).map { String(decoding: $0, as: UTF8.self) }
        } catch {
            Self.log.error("FinTS: System-ID nicht lesbar (\(String(describing: error), privacy: .public))")
            throw .cancelled
        }
    }

    private func saveSystemID(of inner: any BankConnector) async {
        guard let ing = inner as? INGConnector else { return }
        let systemID = await ing.systemID
        guard systemID != "0", systemID != savedSystemID else { return }
        do {
            try keychain.set(Data(systemID.utf8), for: FinTSKeys.systemIDKey(connection.id, connector: .ing))
            savedSystemID = systemID
        } catch {
            Self.log.error("ING: System-ID nicht gespeichert (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    /// Keychain items beyond credentials and session: the customer system ID and its owner tag.
    nonisolated static func deleteState(of connection: Connection) throws {
        let keychain = Keychain()
        try keychain.delete(FinTSKeys.systemIDKey(connection.id, connector: connection.connectorID))
        try keychain.delete(FinTSKeys.systemIDOwnerKey(connection.id, connector: connection.connectorID))
    }
}
