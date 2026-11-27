import Foundation
import MFNCore
import RoutexClient
import RoutexModels

/// A bank as YAXI's search shows it (`ConnectionInfo`), free of YAXI types for the app.
public struct YAXIBank: Hashable, Codable, Sendable, Identifiable {
    /// YAXI's connection ID (`connection-<uuid>`).
    public var id: String
    public var name: String
    public var needsUserID: Bool
    public var needsPassword: Bool
    /// The bank's own words for the fields ("Anmeldename", "PIN").
    public var userIDLabel: String?
    public var passwordLabel: String?
    /// A hint from YAXI or the bank, plain text.
    public var advice: String?
    /// The bank's logo at YAXI's logo service (`YAXILogos`).
    public var logoID: String?
    /// ISO country codes the bank works in (`DE`, `AT` …): two banks may share a name. Optional so
    /// states stored before this field still decode.
    public var countries: [String]?

    public init(id: String, name: String, needsUserID: Bool, needsPassword: Bool, userIDLabel: String? = nil, passwordLabel: String? = nil, advice: String? = nil, logoID: String? = nil) {
        self.id = id
        self.name = name
        self.needsUserID = needsUserID
        self.needsPassword = needsPassword
        self.userIDLabel = userIDLabel
        self.passwordLabel = passwordLabel
        self.advice = advice
        self.logoID = logoID
    }

    var isGerman: Bool { countries?.contains("DE") ?? false }

    /// Country names for the search list ("Deutschland", "Österreich"), `nil` without countries.
    public var countryNames: String? {
        guard let countries, !countries.isEmpty else { return nil }
        let locale = Locale.autoupdatingCurrent
        return countries.map { locale.localizedString(forRegionCode: $0) ?? $0 }.joined(separator: ", ")
    }

    /// Keys of the login form; the connector reads the same keys (`YAXILogin`).
    public static let userIDKey = "userID"
    public static let passwordKey = "password"

    /// Fields of the login form for this bank.
    public var credentialFields: [CredentialField] {
        var fields: [CredentialField] = []
        if needsUserID {
            fields.append(CredentialField(key: Self.userIDKey, label: label(userIDLabel, fallback: String(localized: "Benutzername", bundle: .module)), kind: .text))
        }
        if needsPassword {
            fields.append(CredentialField(key: Self.passwordKey, label: label(passwordLabel, fallback: String(localized: "Passwort", bundle: .module)), kind: .secret))
        }
        return fields
    }

    private func label(_ text: String?, fallback: String) -> String {
        let cleaned = text.map(YAXIConnector.displayText) ?? ""
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(40))
    }

    /// The login for a new consent from the stored credentials; `nil` if a needed field is missing.
    public func login(from credentials: BankCredentials?) -> YAXILogin? {
        let userID = credentials?[Self.userIDKey].flatMap { $0.isEmpty ? nil : $0 }
        let password = credentials?[Self.passwordKey].flatMap { $0.isEmpty ? nil : $0 }
        if needsUserID, userID == nil { return nil }
        if needsPassword, password == nil { return nil }
        return YAXILogin(userID: userID, password: password)
    }

    init(_ info: ConnectionInfo) {
        let model = info.credentials
        self.init(
            id: info.id.description,
            name: YAXIConnector.displayText(info.displayName),
            needsUserID: model.full || model.userID,
            needsPassword: model.full,
            userIDLabel: info.userIDLabel,
            passwordLabel: info.passwordLabel,
            advice: info.advice.map(YAXIConnector.displayText),
            logoID: YAXILogos.isValid(info.logoID) ? info.logoID : nil
        )
        countries = info.countries.map { $0.rawValue.uppercased() }
    }
}

/// Bank search and key check against YAXI with the user's key. Each call is one service call.
public struct YAXIDirectory: Sendable {
    private let key: YAXIAPIKey

    public init(key: YAXIAPIKey) {
        self.key = key
    }

    /// Banks matching `term` (name, BIC or bank code), at most `limit`. No IBAN detection: the search
    /// term goes to YAXI before any connection exists, and an IBAN is not needed to find a bank.
    public func search(_ term: String, limit: Int = 20) async throws(ConnectorError) -> [YAXIBank] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        do {
            let tickets = try YAXITickets(key: key)
            let client = RoutexClient(baseURL: key.environment.baseURL)
            YAXIUsage.shared.record()
            let found = try await client.search(ticket: try tickets.accounts(), filters: [.term(String(trimmed.prefix(80)))],
                                                ibanDetection: false, limit: limit)
            // German banks first (MFN's users mostly bank in Germany), the service's order otherwise.
            let banks = found.map(YAXIBank.init)
            return banks.filter { $0.isGerman } + banks.filter { !$0.isGerman }
        } catch {
            throw Self.connectorError(error)
        }
    }

    /// Checks that YAXI accepts the key (one search call). Wrong environment or unknown key →
    /// `authFailed`.
    public func check() async throws(ConnectorError) {
        _ = try await search("Bank", limit: 1)
    }

    static func connectorError(_ error: any Error) -> ConnectorError {
        switch YAXIErrors.map(error) {
        case let .connector(.formatChanged(detail)) where detail == "yaxi ticket": .authFailed
        case let .connector(connector): connector
        case .consentNeeded, .periodOutOfBounds: .formatChanged(detail: "yaxi search")
        }
    }
}

/// Setting up a YAXI connection in MFN.
public enum YAXISetup {
    /// Before the first sync of a new connection: which bank it reaches.
    public static func prepare(_ connection: MFNCore.ConnectionID, bank: YAXIBank, states: any YAXIStateStore = KeychainYAXIStateStore()) throws {
        try states.set(YAXIConnectionState(bank: bank.id, bankName: bank.name, bankInfo: bank), for: connection)
    }

    /// After the credentials changed: the next sync asks the bank for a new consent with them.
    public static func forgetConsent(of connection: MFNCore.ConnectionID, states: any YAXIStateStore = KeychainYAXIStateStore()) throws {
        guard var state = try states.state(for: connection) else { return }
        state.consent = nil
        try states.set(state, for: connection)
    }

    /// "Bank entfernen" or a cancelled setup: bank, consent and account list go.
    public static func remove(_ connection: MFNCore.ConnectionID, states: any YAXIStateStore = KeychainYAXIStateStore()) throws {
        try states.delete(for: connection)
    }

    /// The bank of an existing connection (for "Zugangsdaten ändern"), `nil` if unknown.
    public static func bank(of connection: MFNCore.ConnectionID, states: any YAXIStateStore = KeychainYAXIStateStore()) -> YAXIBank? {
        (try? states.state(for: connection))?.flatMap(\.bankInfo)
    }
}
