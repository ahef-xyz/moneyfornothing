import CommonCrypto
import CryptoKit
import Foundation

/// The database key, encrypted with the user's password. Lives next to the database as
/// `ledger.key`, so a copied database (new Mac, restore) can be opened once with the password;
/// after that the key is in that Mac's keychain again.
///
/// PBKDF2-HMAC-SHA256 (CommonCrypto) → 256-bit wrapping key → AES-GCM (CryptoKit).
/// Changing the password rewrites only this file, never the database.
struct KeyEnvelope: Codable, Equatable {
    static let fileName = "ledger.key"
    /// OWASP recommends ≥ 600 000 for PBKDF2-HMAC-SHA256. 2 M ≈ 0.3 s on an M1 Max, paid only at
    /// setup, recovery and password change.
    static let defaultIterations = 2_000_000
    /// Iteration counts `open` accepts from a `ledger.key` on disk: fewer is too weak, more
    /// would hang the unlock (and a tampered value must not overflow `UInt32`).
    static let acceptedIterations = 100_000...50_000_000

    var version = 1
    var kdf = "pbkdf2-sha256"
    var iterations: Int
    var salt: Data
    /// AES-GCM combined representation: nonce ‖ ciphertext ‖ tag.
    var sealedKey: Data

    static func seal(_ key: Data, password: String, iterations: Int = defaultIterations) throws(VaultError) -> KeyEnvelope {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard status == errSecSuccess else { throw .crypto("salt") }
        let wrappingKey = try derive(password: password, salt: salt, iterations: iterations)
        do {
            guard let combined = try AES.GCM.seal(key, using: wrappingKey).combined else { throw VaultError.crypto("seal") }
            return KeyEnvelope(iterations: iterations, salt: salt, sealedKey: combined)
        } catch {
            throw .crypto("seal")
        }
    }

    func open(password: String, acceptedIterations: ClosedRange<Int> = Self.acceptedIterations) throws(VaultError) -> Data {
        guard version == 1, kdf == "pbkdf2-sha256", acceptedIterations.contains(iterations) else { throw .unsupportedEnvelope }
        let wrappingKey = try Self.derive(password: password, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: sealedKey)
            return try AES.GCM.open(box, using: wrappingKey)
        } catch {
            // Authentication failure: wrong password (or tampered file).
            throw .wrongPassword
        }
    }

    private static func derive(password: String, salt: Data, iterations: Int) throws(VaultError) -> SymmetricKey {
        guard iterations > 0, let rounds = UInt32(exactly: iterations) else { throw .unsupportedEnvelope }
        var derived = Data(count: 32)
        // NUL-terminated so the buffer is never empty (non-nil base address); the terminator is not passed.
        var passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8) + [0]
        // The copy of the password must not outlive the derivation (the `String` itself cannot be wiped).
        defer {
            passwordBytes.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = memset_s(base, buffer.count, 0, buffer.count)
            }
        }
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                passwordBytes.withUnsafeBytes { password in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password.bindMemory(to: CChar.self).baseAddress, password.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        out.bindMemory(to: UInt8.self).baseAddress, 32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw .crypto("pbkdf2") }
        defer { derived.wipe() }
        return SymmetricKey(data: derived)
    }
}
