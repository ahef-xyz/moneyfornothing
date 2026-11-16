import Foundation

/// Untyped JSON with exact decimal numbers.
///
/// Trade Republic changes payloads without notice, so the connector navigates JSON tolerantly
/// instead of decoding rigid structs: unknown fields are ignored, missing optional fields are `nil`.
/// Numbers are kept as `Decimal` (never `Double`) so amounts convert to cents exactly.
enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Parses JSON text; `nil` if it is not valid JSON.
    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    /// Compact JSON with sorted keys (deterministic, used for `rawJSON` and outgoing messages).
    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    var text: String { String(decoding: data, as: UTF8.self) }

    subscript(key: String) -> JSONValue? {
        guard case let .object(object) = self else { return nil }
        return object[key]
    }

    var object: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// String value; numbers are rendered, empty strings count as missing.
    var string: String? {
        switch self {
        case let .string(value): value.isEmpty ? nil : value
        case let .number(value): "\(value)"
        default: nil
        }
    }

    /// Decimal from a JSON number or a numeric string (`"1.234"`).
    var decimal: Decimal? {
        switch self {
        case let .number(value): value
        case let .string(value): Decimal(string: value.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX"))
        default: nil
        }
    }

    var int: Int? {
        guard let decimal else { return nil }
        let value = NSDecimalNumber(decimal: decimal).intValue
        return Decimal(value) == decimal ? value : nil
    }

    var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var isNull: Bool { self == .null }
}

enum Money {
    /// Converts a decimal amount to minor units (cents for EUR), rounding half-even.
    static func minorUnits(_ value: Decimal, fractionDigits: Int = 2) -> Int? {
        guard (0 ... 6).contains(fractionDigits) else { return nil }
        var scaled = value * pow(Decimal(10), fractionDigits)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .bankers)
        let number = NSDecimalNumber(decimal: rounded)
        guard number != .notANumber, abs(rounded) < Decimal(Int64.max / 2) else { return nil }
        return number.intValue
    }

    /// `value` × 100 if it has at most two decimals, else `nil` (never rounds).
    static func exactCents(_ value: Decimal) -> Int? {
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil }
        return minorUnits(value, fractionDigits: 2)
    }
}
