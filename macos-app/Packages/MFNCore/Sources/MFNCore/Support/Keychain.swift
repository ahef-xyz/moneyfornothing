import Foundation
import Security

/// Credentials and session cookies live only here (CLAUDE.md §6 Sicherheit).
///
/// Generic-password items in the data-protection keychain, accessible only while the Mac is
/// unlocked and never migrated to another device. Values are never logged.
public struct Keychain: Sendable {
    public enum KeychainError: Error, Sendable, Equatable {
        case unexpectedStatus(OSStatus)
        /// The binary is not signed with a keychain entitlement (e.g. `swift test`).
        case missingEntitlement
    }

    public let service: String

    public init(service: String = "xyz.ahef.mfn") {
        self.service = service
    }

    public func set(_ data: Data, for key: String) throws(KeychainError) {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        try check(status)
        Log.keychain.debug("Stored item \(key, privacy: .private)")
    }

    public func data(for key: String) throws(KeychainError) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }

    public func delete(_ key: String) throws(KeychainError) {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    public func set<Value: Encodable>(_ value: Value, for key: String) throws {
        try set(JSONEncoder().encode(value), for: key)
    }

    public func value<Value: Decodable>(_ type: Value.Type, for key: String) throws -> Value? {
        guard let data = try data(for: key) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func check(_ status: OSStatus) throws(KeychainError) {
        switch status {
        case errSecSuccess: return
        case errSecMissingEntitlement: throw .missingEntitlement
        default: throw .unexpectedStatus(status)
        }
    }
}
