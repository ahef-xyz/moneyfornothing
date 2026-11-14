import Foundation
import MFNCore

/// Any JSON value. Used to keep bank objects unchanged (`rawJSON`, request bodies that must echo
/// the bank's own `Account` object) and to walk heterogeneous `InitialCallResponses`.
enum JSONValue: Codable, Hashable, Sendable {
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
        } else {
            self = .object(try container.decode([String: JSONValue].self))
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

    subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(array) = self { return array }
        return nil
    }

    /// Stable serialisation (sorted keys) – same bank data gives the same bytes.
    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    /// Decodes this value as `T`; failures become `formatChanged` with the coding path, never values.
    func decode<T: Decodable>(_ type: T.Type, context: String) throws(ConnectorError) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let DecodingError.keyNotFound(key, info) {
            throw .formatChanged(detail: "\(context): Feld fehlt \(Self.path(info.codingPath + [key]))")
        } catch let DecodingError.typeMismatch(_, info) {
            throw .formatChanged(detail: "\(context): Typ geändert bei \(Self.path(info.codingPath))")
        } catch let DecodingError.valueNotFound(_, info) {
            throw .formatChanged(detail: "\(context): Wert fehlt bei \(Self.path(info.codingPath))")
        } catch {
            throw .formatChanged(detail: "\(context): nicht lesbar")
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}
