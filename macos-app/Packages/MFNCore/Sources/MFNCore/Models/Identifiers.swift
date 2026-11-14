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

    public var displayName: String {
        switch self {
        case .ing: "ING"
        case .dkb: "DKB"
        case .tradeRepublic: "Trade Republic"
        case .c24: "C24"
        case .easybank: "easybank"
        case .n26: "N26"
        case .mock: "Demo"
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
