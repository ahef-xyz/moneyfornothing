import Foundation
import LocalAuthentication
import MFNCore
import Security
import Synchronization

public enum DatabaseKeyError: Error, Equatable, Sendable {
    /// The user cancelled Touch ID / password.
    case authenticationCancelled
    /// The app is not signed with a keychain entitlement (e.g. `swift test`).
    case missingEntitlement
    /// The keychain access was invalidated (app locked).
    case invalidated
    case keychain(OSStatus)
}

/// Where the database key lives on this Mac.
public protocol DatabaseKeyStore: Sendable {
    /// `nil` if there is no key on this Mac (new install, copied database, keychain reset).
    func read() throws(DatabaseKeyError) -> Data?
    func save(_ key: Data) throws(DatabaseKeyError)
}

/// The production key store: data-protection keychain, protected by `biometryAny` OR
/// `devicePasscode`, only while unlocked, never leaving this Mac (`ThisDeviceOnly`).
/// `biometryAny` (not `biometryCurrentSet`): adding or removing a fingerprint must not destroy
/// the key. The password envelope (`ledger.key`) is the way to bring the key to another Mac.
///
/// Reuses the `LAContext` that `AppLock` already evaluated, so unlocking prompts only once.
/// `invalidate()` on lock makes every later access fail.
public final class KeychainDatabaseKey: DatabaseKeyStore {
    public static let defaultService = "xyz.ahef.mfn.database"
    public static let defaultAccount = "ledger-key-v1"

    private let service: String
    private let account: String
    // LAContext is not Sendable; all access goes through the mutex.
    private let context: Mutex<LAContext?>

    public init(context: sending LAContext, service: String = defaultService, account: String = defaultAccount) {
        self.context = Mutex(context)
        self.service = service
        self.account = account
    }

    public func invalidate() {
        context.withLock { context in
            context?.invalidate()
            context = nil
        }
    }

    public func read() throws(DatabaseKeyError) -> Data? {
        let result: Result<Data?, DatabaseKeyError> = context.withLock { context in
            guard let context else { return .failure(.invalidated) }
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String] = context
            var item: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data, data.count == 32 else { return .failure(.keychain(errSecDecode)) }
                return .success(data)
            case errSecItemNotFound:
                return .success(nil)
            default:
                return .failure(Self.map(status))
            }
        }
        return try result.get()
    }

    public func save(_ key: Data) throws(DatabaseKeyError) {
        let result: Result<Void, DatabaseKeyError> = context.withLock { context in
            guard let context else { return .failure(.invalidated) }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.biometryAny, .or, .devicePasscode],
                &error
            ) else {
                let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "unbekannt"
                Log.store.error("SecAccessControl fehlgeschlagen: \(reason, privacy: .public)")
                return .failure(.keychain(errSecParam))
            }
            SecItemDelete(baseQuery() as CFDictionary) // Replace a stale item; absence is fine.
            var query = baseQuery()
            query[kSecValueData as String] = key
            query[kSecAttrAccessControl as String] = access
            query[kSecUseAuthenticationContext as String] = context
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else { return .failure(Self.map(status)) }
            Log.store.info("Datenbankschlüssel im Schlüsselbund gespeichert")
            return .success(())
        }
        try result.get()
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func map(_ status: OSStatus) -> DatabaseKeyError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed: .authenticationCancelled
        case errSecMissingEntitlement: .missingEntitlement
        default: .keychain(status)
        }
    }
}

/// Key store in memory. For tests and previews only.
public final class InMemoryDatabaseKeyStore: DatabaseKeyStore {
    private let storage: Mutex<Data?>

    public init(_ key: Data? = nil) {
        storage = Mutex(key)
    }

    public func read() throws(DatabaseKeyError) -> Data? { storage.withLock { $0 } }
    public func save(_ key: Data) throws(DatabaseKeyError) { storage.withLock { $0 = key } }
}

extension Data {
    /// 32 bytes from the system CSPRNG.
    static func randomKey() throws(VaultError) -> Data {
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard status == errSecSuccess else { throw .crypto("random") }
        return key
    }

    /// SQLCipher raw-key syntax `x'<64 hex>'`: skips SQLCipher's PBKDF2, which only adds cost
    /// for a random key.
    ///
    /// Allocated once at its final size and filled in place: growing by `append` would
    /// reallocate and leave unwiped copies of the hex key in freed memory.
    var sqlCipherRawKey: Data {
        let digits: StaticString = "0123456789ABCDEF"
        var passphrase = Data(count: 2 + count * 2 + 1)
        passphrase.withUnsafeMutableBytes { out in
            digits.withUTF8Buffer { hex in
                out[0] = UInt8(ascii: "x")
                out[1] = UInt8(ascii: "'")
                var position = 2
                for byte in self {
                    out[position] = hex[Int(byte >> 4)]
                    out[position + 1] = hex[Int(byte & 0x0F)]
                    position += 2
                }
                out[position] = UInt8(ascii: "'")
            }
        }
        return passphrase
    }

    /// Overwrites the bytes before the buffer is released.
    mutating func wipe() {
        resetBytes(in: startIndex..<endIndex)
    }
}
