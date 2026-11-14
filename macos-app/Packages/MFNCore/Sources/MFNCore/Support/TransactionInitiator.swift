import Foundation

/// Who made a transaction on a shared account (e.g. C24 joint accounts/pockets: `initiator_name`,
/// `initiator_id` in the raw data). Read from `Transaction.rawJSON` here in MFNCore, so it also
/// works for every transaction already stored – no model change, no re-fetch.
public struct TransactionInitiator: Hashable, Sendable {
    public let name: String
    /// Bank-side ID of the person, if given (tells apart two people with the same name).
    public let id: String?

    public init(name: String, id: String? = nil) {
        self.name = name
        self.id = id
    }

    /// Identity for grouping: the ID if known, else the name.
    public var key: String { id ?? name.lowercased() }

    private static let marker = Data("initiator".utf8)
    private static let nameKeys = ["initiator_name", "initiatorName"]
    private static let idKeys = ["initiator_id", "initiatorId", "initiatorID"]

    /// The first object in the raw JSON (any depth) that names an initiator; `nil` if none.
    /// Cheap for the common case: raw data without the word "initiator" is not parsed.
    public static func extract(from raw: Data) -> TransactionInitiator? {
        guard raw.range(of: marker) != nil,
              let object = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) else { return nil }
        return find(in: object, depth: 0)
    }

    private static func find(in value: Any, depth: Int) -> TransactionInitiator? {
        guard depth < 8 else { return nil }
        if let object = value as? [String: Any] {
            if let name = nameKeys.lazy.compactMap({ object[$0] as? String }).first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                let id = idKeys.lazy.compactMap { key -> String? in
                    if let text = object[key] as? String { return text.isEmpty ? nil : text }
                    if let number = object[key] as? NSNumber { return number.stringValue }
                    return nil
                }.first
                return TransactionInitiator(name: name, id: id)
            }
            // Nested `"initiator": {"name": …, "id": …}`.
            if let nested = object["initiator"] as? [String: Any], let name = (nested["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                return TransactionInitiator(name: name, id: (nested["id"] as? String) ?? (nested["id"] as? NSNumber)?.stringValue)
            }
            for child in object.values {
                if let found = find(in: child, depth: depth + 1) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = find(in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }
}
