import Foundation
import MFNCore

/// Which YAXI service a key belongs to. Keys from the Hub are bound to one environment
/// (M0, 2026-11-25: the first key answered `UnknownKey` on production and worked on integration).
public enum YAXIEnvironment: String, Codable, Sendable, CaseIterable {
    case production
    case integration

    public var baseURL: URL {
        switch self {
        case .production: Self.url("https://api.yaxi.tech")
        case .integration: Self.url("https://integration.yaxi.tech")
        }
    }

    /// Both literals are valid URLs; a failure here is a programming error caught by any test run.
    private static func url(_ literal: String) -> URL {
        guard let url = URL(string: literal) else { preconditionFailure("invalid YAXI base URL literal") }
        return url
    }
}

/// The user's own YAXI API key (docs/v0.7.0.md, decision "the user's own YAXI access"). Issues the
/// tickets locally and verifies the results. Lives only in the Keychain; `description` is redacted.
public struct YAXIAPIKey: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Problem: Error, Equatable, Sendable {
        case keyIDFormat
        case secretFormat
    }

    /// `api-key-…` from the Hub.
    public var keyID: String
    /// The secret as the Hub shows it (base64).
    public var base64Secret: String
    public var environment: YAXIEnvironment

    public init(keyID: String, base64Secret: String, environment: YAXIEnvironment) throws(Problem) {
        let id = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = base64Secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasPrefix("api-key-"), id.count > "api-key-".count, !id.contains(where: \.isWhitespace) else { throw .keyIDFormat }
        guard let bytes = Data(base64Encoded: secret), bytes.count >= 16 else { throw .secretFormat }
        self.keyID = id
        self.base64Secret = secret
        self.environment = environment
    }

    /// The HMAC key of tickets and result JWTs: the base64-decoded secret (verified in M0).
    var secret: Data { Data(base64Encoded: base64Secret) ?? Data() }

    public var description: String { "YAXIAPIKey(\(environment.rawValue), <redacted>)" }
    public var debugDescription: String { description }
}

/// Where the API key is kept. The Keychain in the app; in memory in tests (`swift test` has no
/// keychain entitlement).
public protocol YAXIKeyStore: Sendable {
    func key() throws -> YAXIAPIKey?
    func set(_ key: YAXIAPIKey) throws
    func delete() throws
}

public struct KeychainYAXIKeyStore: YAXIKeyStore {
    static let item = "yaxi.apiKey"
    private let keychain: Keychain

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    public func key() throws -> YAXIAPIKey? { try keychain.value(YAXIAPIKey.self, for: Self.item) }
    public func set(_ key: YAXIAPIKey) throws { try keychain.set(key, for: Self.item) }
    public func delete() throws { try keychain.delete(Self.item) }
}

/// State of one YAXI connection in MFN. Keychain only (it holds IBANs and the consent).
public struct YAXIConnectionState: Hashable, Codable, Sendable, CustomStringConvertible {
    /// An account as YAXI reported it, kept so a sync needs the `accounts` service at most once a day.
    public struct KnownAccount: Hashable, Codable, Sendable {
        public var account: Account
        /// How YAXI addresses the account (`AccountReference`): `iban:`, `number:` or `maskedPan:` + value.
        public var reference: String

        public init(account: Account, reference: String) {
            self.account = account
            self.reference = reference
        }
    }

    /// YAXI's `ConnectionID` of the bank (from `search`).
    public var bank: String
    /// The bank's name as YAXI shows it.
    public var bankName: String
    /// The long-lived consent (`ConnectionData`). Replaced by the newest one after every call.
    public var consent: Data?
    public var accounts: [KnownAccount]
    public var accountsFetchedAt: Date?
    /// The bank as found in the search (field labels for "Zugangsdaten ändern").
    public var bankInfo: YAXIBank?

    public init(bank: String, bankName: String, bankInfo: YAXIBank? = nil, consent: Data? = nil, accounts: [KnownAccount] = [], accountsFetchedAt: Date? = nil) {
        self.bank = bank
        self.bankName = bankName
        self.bankInfo = bankInfo
        self.consent = consent
        self.accounts = accounts
        self.accountsFetchedAt = accountsFetchedAt
    }

    public var description: String {
        "YAXIConnectionState(consent: \(consent != nil), accounts: \(accounts.count))"
    }
}

public protocol YAXIStateStore: Sendable {
    func state(for connection: ConnectionID) throws -> YAXIConnectionState?
    func set(_ state: YAXIConnectionState, for connection: ConnectionID) throws
    func delete(for connection: ConnectionID) throws
}

public struct KeychainYAXIStateStore: YAXIStateStore {
    private let keychain: Keychain

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    /// Not a `ConnectionSecrets` session key on purpose: changing the credentials must keep the bank
    /// (`YAXISetup.forgetConsent`), "Bank entfernen" deletes it explicitly (`YAXISetup.remove`).
    static func item(_ connection: ConnectionID) -> String { "yaxi.connection.\(connection.rawValue)" }

    public func state(for connection: ConnectionID) throws -> YAXIConnectionState? {
        try keychain.value(YAXIConnectionState.self, for: Self.item(connection))
    }

    public func set(_ state: YAXIConnectionState, for connection: ConnectionID) throws {
        try keychain.set(state, for: Self.item(connection))
    }

    public func delete(for connection: ConnectionID) throws {
        try keychain.delete(Self.item(connection))
    }
}

/// The bank login for a new consent. Where it comes from is open question O5 (docs/v0.7.0.md);
/// the app passes a closure (stored credentials or a prompt). `nil` = not available now.
public struct YAXILogin: Hashable, Sendable, CustomStringConvertible {
    public var userID: String?
    public var password: String?

    public init(userID: String?, password: String?) {
        self.userID = userID
        self.password = password
    }

    public var description: String { "YAXILogin(<redacted>)" }
}
