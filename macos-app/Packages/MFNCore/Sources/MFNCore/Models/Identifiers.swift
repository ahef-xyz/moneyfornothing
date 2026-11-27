import Foundation

/// Identifies a connector implementation (and thereby the bank behind a connection).
public enum ConnectorID: String, Codable, Sendable, CaseIterable, Hashable {
    case ing
    case dkb
    case tradeRepublic
    case c24
    case easybank
    /// v4
    case n26
    case mock
    /// v10: account without a bank connection ("Ohne Anbindung"). No connector, no sync:
    /// transactions come from the CSV import only, the balance is computed (`ManualAccount`).
    case manual
    /// v11: PayPal over its website (visible web login, package `MFNPayPal`).
    case paypal
    /// v12: any bank through YAXI's attested service, with the user's own YAXI access (package
    /// `MFNYAXI`, docs/v0.7.0.md). The bank itself is a YAXI connection ID stored per connection.
    case yaxi

    public var displayName: String {
        switch self {
        case .ing: "ING"
        case .dkb: "DKB"
        case .tradeRepublic: "Trade Republic"
        case .c24: "C24"
        case .easybank: "easybank"
        case .n26: "N26"
        case .mock: "Demo"
        case .manual: String(localized: "Ohne Anbindung", bundle: .module)
        case .paypal: "PayPal"
        case .yaxi: "YAXI"
        }
    }
}

/// Stable identifier of one bank login (one set of credentials) inside MFN.
public struct ConnectionID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// Stable identifier of an account. Connectors derive it deterministically from bank data
/// (e.g. IBAN hash, card number suffix, bank-internal ID), so it survives re-syncs.
public struct AccountID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public struct TransactionID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public struct CategoryID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// One CSV import (v10): every row it added carries this ID in `Transaction.importID`.
public struct ImportBatchID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// A fresh ID for a new import.
    public static func make() -> ImportBatchID { ImportBatchID("import:\(UUID().uuidString)") }
}
