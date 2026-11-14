import Foundation
import MFNCore

public enum VaultError: Error, Equatable, Sendable {
    case wrongPassword
    case weakPassword(minimumLength: Int)
    case unsupportedEnvelope
    /// The database exists, but neither this Mac's keychain nor `ledger.key` can supply its key.
    case keyUnrecoverable
    case key(DatabaseKeyError)
    case store(StoreError)
    case crypto(String)
    case file(String)
}

/// Decides how the database key is obtained and opens the store.
///
/// - `ready`: key in this Mac's keychain → open directly (Touch ID already happened in `AppLock`).
/// - `needsPassword`: database + `ledger.key` present, key not on this Mac (copied database,
///   new Mac, keychain reset) → ask for the password once, then the key goes into the keychain.
/// - `needsSetup`: first start → ask the user to choose a password; a new key is created.
public struct LedgerVault: Sendable {
    public enum State: Equatable, Sendable {
        case ready
        case needsPassword
        case needsSetup
    }

    public static let minimumPasswordLength = 12

    public let databaseURL: URL
    let keyStore: any DatabaseKeyStore
    let iterations: Int

    public init(databaseURL: URL, keyStore: any DatabaseKeyStore) {
        self.init(databaseURL: databaseURL, keyStore: keyStore, iterations: KeyEnvelope.defaultIterations)
    }

    init(databaseURL: URL, keyStore: any DatabaseKeyStore, iterations: Int) {
        self.databaseURL = databaseURL
        self.keyStore = keyStore
        self.iterations = iterations
    }

    /// Iterations accepted from `ledger.key`; tests seal with fewer than production allows.
    var acceptedIterations: ClosedRange<Int> {
        min(iterations, KeyEnvelope.acceptedIterations.lowerBound)...KeyEnvelope.acceptedIterations.upperBound
    }

    var envelopeURL: URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(KeyEnvelope.fileName)
    }

    public func state() throws(VaultError) -> State {
        let hasDatabase = FileManager.default.fileExists(atPath: databaseURL.path)
        let hasEnvelope = FileManager.default.fileExists(atPath: envelopeURL.path)
        let hasKey: Bool
        do {
            hasKey = try keyStore.read() != nil
        } catch {
            throw .key(error)
        }
        switch (hasDatabase, hasEnvelope, hasKey) {
        case (true, true, true): return .ready
        case (true, true, false): return .needsPassword
        case (false, _, _): return .needsSetup
        // Database without envelope: cannot happen through MFN (setup writes the envelope
        // before the database exists). With the key still here the user could re-protect it,
        // without it the data is gone.
        case (true, false, true): return .ready
        case (true, false, false): throw .keyUnrecoverable
        }
    }

    /// `.ready`: opens with the key from the keychain.
    public func open() async throws(VaultError) -> EncryptedLedgerStore {
        let stored: Data?
        do {
            stored = try keyStore.read()
        } catch {
            throw .key(error)
        }
        guard var key = stored else { throw .keyUnrecoverable }
        defer { key.wipe() }
        return try await openStore(with: key)
    }

    /// `.needsSetup`: creates key and envelope, stores the key in the keychain, creates the database.
    public func setUp(password: String) async throws(VaultError) -> EncryptedLedgerStore {
        try Self.validate(password)
        var key = try Data.randomKey()
        defer { key.wipe() }
        try writeEnvelope(KeyEnvelope.seal(key, password: password, iterations: iterations))
        do {
            try keyStore.save(key)
        } catch {
            throw .key(error)
        }
        return try await openStore(with: key)
    }

    /// `.needsPassword`: recovers the key from `ledger.key`, stores it in this Mac's keychain.
    public func recover(password: String) async throws(VaultError) -> EncryptedLedgerStore {
        var key = try readEnvelope().open(password: password, acceptedIterations: acceptedIterations)
        defer { key.wipe() }
        // Open first: only a key that actually decrypts the database is worth keeping.
        let store = try await openStore(with: key)
        do {
            try keyStore.save(key)
        } catch {
            await store.close()
            throw .key(error)
        }
        return store
    }

    /// Re-wraps the key with a new password. The database itself is not touched.
    public func changePassword(from old: String, to new: String) throws(VaultError) {
        try Self.validate(new)
        var key = try readEnvelope().open(password: old, acceptedIterations: acceptedIterations)
        defer { key.wipe() }
        try writeEnvelope(KeyEnvelope.seal(key, password: new, iterations: iterations))
    }

    public static func validate(_ password: String) throws(VaultError) {
        guard password.count >= minimumPasswordLength else { throw .weakPassword(minimumLength: minimumPasswordLength) }
    }

    // MARK: -

    private func openStore(with key: Data) async throws(VaultError) -> EncryptedLedgerStore {
        do {
            return try await EncryptedLedgerStore.open(at: databaseURL, key: key)
        } catch {
            throw .store(error)
        }
    }

    private func readEnvelope() throws(VaultError) -> KeyEnvelope {
        do {
            let data = try Data(contentsOf: envelopeURL)
            return try JSONDecoder().decode(KeyEnvelope.self, from: data)
        } catch {
            throw .file("ledger.key: \(error.localizedDescription)")
        }
    }

    private func writeEnvelope(_ envelope: KeyEnvelope) throws(VaultError) {
        do {
            try FileManager.default.createDirectory(at: envelopeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(envelope).write(to: envelopeURL, options: [.atomic])
        } catch {
            throw .file("ledger.key: \(error.localizedDescription)")
        }
    }
}
