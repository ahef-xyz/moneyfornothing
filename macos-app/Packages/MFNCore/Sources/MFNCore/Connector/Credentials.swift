import Foundation

/// v4: one input of the unified login form ("Bank hinzufügen" wizard). The key is what headless
/// login scripts read from `credentials` (see `WebLoginAutomation`).
public struct CredentialField: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case text
        case email
        /// International format, e.g. `+491701234567`.
        case phone
        /// Password or PIN, shown as secure field.
        case secret
    }

    public var key: String
    public var label: String
    public var kind: Kind
    /// Placeholder / hint, e.g. "+49 …".
    public var prompt: String
    /// Exact length for numeric PINs (Trade Republic: 4), `nil` = free length.
    public var length: Int?
    /// Digits only (PIN, Zugangsnummer).
    public var isNumeric: Bool

    public var id: String { key }
    public var isSecret: Bool { kind == .secret }

    public init(key: String, label: String, kind: Kind, prompt: String = "", length: Int? = nil, isNumeric: Bool = false) {
        self.key = key
        self.label = label
        self.kind = kind
        self.prompt = prompt
        self.length = length
        self.isNumeric = isNumeric
    }
}

/// v4: credentials of one connection. Lives only in the keychain (`CredentialStore`) and in
/// memory while a login runs; `description` is redacted.
public struct BankCredentials: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// All fields of `connector` are filled (and numeric/length rules hold).
    public func isComplete(for connector: ConnectorID) -> Bool {
        connector.credentialFields.allSatisfy { field in
            guard let value = values[field.key], !value.isEmpty else { return false }
            if field.isNumeric, !value.allSatisfy(\.isNumber) { return false }
            if let length = field.length, value.count != length { return false }
            return true
        }
    }

    public var description: String { "BankCredentials(\(values.keys.sorted().joined(separator: ", ")): <redacted>)" }
    public var debugDescription: String { description }
}

extension ConnectorID {
    /// v4: fields of the unified login form. Keys are the contract with the connector's
    /// headless login script.
    public var credentialFields: [CredentialField] {
        switch self {
        case .ing:
            // v8: FinTS (fints.ing.de): Zugangsnummer (last 10 digits of the IBAN) or user name, and the
            // PIN for FinTS. No web banking any more.
            [CredentialField(key: "userID", label: String(localized: "Zugangsnummer", bundle: .module), kind: .text, prompt: String(localized: "Zugangsnummer oder Benutzername", bundle: .module)),
             CredentialField(key: "pin", label: String(localized: "PIN", bundle: .module), kind: .secret)]
        case .dkb:
            // v6: web banking login (banking.dkb.de) until FinTS is registered.
            [CredentialField(key: "username", label: String(localized: "Anmeldename", bundle: .module), kind: .text),
             CredentialField(key: "password", label: String(localized: "Passwort", bundle: .module), kind: .secret)]
        case .tradeRepublic:
            [CredentialField(key: "phoneNumber", label: String(localized: "Telefonnummer", bundle: .module), kind: .phone, prompt: "+49 …"),
             CredentialField(key: "pin", label: String(localized: "PIN", bundle: .module), kind: .secret, length: 4, isNumeric: true)]
        case .c24:
            // v5: C24 has no password login (QR code + 6 digits from the app).
            []
        case .easybank:
            [CredentialField(key: "username", label: String(localized: "Benutzername", bundle: .module), kind: .text),
             CredentialField(key: "password", label: String(localized: "Passwort", bundle: .module), kind: .secret)]
        case .n26:
            [CredentialField(key: "username", label: String(localized: "E-Mail", bundle: .module), kind: .email),
             CredentialField(key: "password", label: String(localized: "Passwort", bundle: .module), kind: .secret)]
        case .paypal:
            // v11: the user logs in on PayPal's own page in a visible web view; MFN stores
            // no PayPal password.
            []
        case .yaxi:
            // v12: the fields depend on the bank YAXI reaches (`CredentialsModel`, labels from
            // YAXI); the app builds them per connection.
            []
        case .mock, .manual:
            []
        }
    }

    /// v4: can be added in the wizard. v6: ING and DKB via web banking until FinTS is registered.
    /// v8: ING over FinTS.
    public var supportsSetup: Bool {
        switch self {
        case .tradeRepublic, .c24, .easybank, .n26, .dkb, .ing, .paypal: true
        // v10: `.manual` is created by its own sheet ("Konto ohne Anbindung anlegen"), not the wizard.
        // v12: `.yaxi` gets its own assistant path (search first) in 0.7.0 M3.
        case .mock, .manual, .yaxi: false
        }
    }
}

/// v4: keychain storage of `BankCredentials`, one item per connection
/// (`WhenUnlockedThisDeviceOnly`, see `Keychain`).
public struct CredentialStore: Sendable {
    private let keychain: Keychain

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    public func credentials(for connection: ConnectionID) throws -> BankCredentials? {
        try keychain.value(BankCredentials.self, for: Self.key(connection))
    }

    public func set(_ credentials: BankCredentials, for connection: ConnectionID) throws {
        try keychain.set(credentials, for: Self.key(connection))
    }

    public func delete(for connection: ConnectionID) throws {
        try keychain.delete(Self.key(connection))
    }

    static func key(_ connection: ConnectionID) -> String { "credentials.\(connection.rawValue)" }
}
