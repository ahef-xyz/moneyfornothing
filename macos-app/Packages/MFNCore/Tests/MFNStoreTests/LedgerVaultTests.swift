import Foundation
import MFNCore
import Security
import Testing
@testable import MFNStore

private func tempDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mfn-vault-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(EncryptedLedgerStore.fileName)
}

/// Low iteration count keeps the tests fast; production uses `KeyEnvelope.defaultIterations`.
private func makeVault(_ url: URL, _ keyStore: InMemoryDatabaseKeyStore) -> LedgerVault {
    LedgerVault(databaseURL: url, keyStore: keyStore, iterations: 1_000)
}

/// A keychain that refuses to store the key, like the Macs behind the 0.3.0 unlock loop.
private struct RefusingKeyStore: DatabaseKeyStore {
    var readError: DatabaseKeyError?
    var saveError: DatabaseKeyError = .keychain(errSecAuthFailed)

    func read() throws(DatabaseKeyError) -> Data? {
        if let readError { throw readError }
        return nil
    }

    func save(_ key: Data) throws(DatabaseKeyError) { throw saveError }
}

private func makeVault(_ url: URL, _ keyStore: RefusingKeyStore) -> LedgerVault {
    LedgerVault(databaseURL: url, keyStore: keyStore, iterations: 1_000)
}

private let password = "korrekt pferd batterie"
private let connection = Connection(id: "c1", connectorID: .ing, displayName: "ING")

@Suite struct LedgerVaultTests {
    @Test func firstStartNeedsSetupThenIsReady() async throws {
        let url = tempDatabaseURL()
        let keychain = InMemoryDatabaseKeyStore()
        let vault = makeVault(url, keychain)
        #expect(try vault.state() == .needsSetup)

        let store = try await vault.setUp(password: password).store
        try await store.upsert(connection: connection)
        await store.close()

        #expect(try vault.state() == .ready)
        #expect(try keychain.read()?.count == 32)
        let reopened = try await vault.open()
        #expect(await reopened.snapshot().connections == [connection])
    }

    @Test func envelopeDoesNotContainTheKey() async throws {
        let url = tempDatabaseURL()
        let keychain = InMemoryDatabaseKeyStore()
        let vault = makeVault(url, keychain)
        try await vault.setUp(password: password).store.close()

        let key = try #require(try keychain.read())
        let envelope = try Data(contentsOf: vault.envelopeURL)
        #expect(envelope.range(of: key) == nil)
        #expect(envelope.range(of: Data(password.utf8)) == nil)
    }

    @Test func copiedDatabaseOpensOnceWithPasswordOnNewMac() async throws {
        let url = tempDatabaseURL()
        let original = makeVault(url, InMemoryDatabaseKeyStore())
        let store = try await original.setUp(password: password).store
        try await store.upsert(connection: connection)
        await store.close()

        // Same files, empty keychain: a different Mac.
        let newMacKeychain = InMemoryDatabaseKeyStore()
        let newMac = makeVault(url, newMacKeychain)
        #expect(try newMac.state() == .needsPassword)

        await #expect(throws: VaultError.wrongPassword) {
            _ = try await newMac.recover(password: "falsches passwort 123")
        }
        #expect(try newMacKeychain.read() == nil)

        let recovered = try await newMac.recover(password: password).store
        #expect(await recovered.snapshot().connections == [connection])
        await recovered.close()
        #expect(try newMac.state() == .ready)
    }

    @Test func weakPasswordIsRejected() async {
        let vault = makeVault(tempDatabaseURL(), InMemoryDatabaseKeyStore())
        await #expect(throws: VaultError.weakPassword(minimumLength: 12)) {
            _ = try await vault.setUp(password: "kurz")
        }
        #expect((try? vault.state()) == .needsSetup)
    }

    @Test func changePasswordRewrapsKeyOnly() async throws {
        let url = tempDatabaseURL()
        let vault = makeVault(url, InMemoryDatabaseKeyStore())
        try await vault.setUp(password: password).store.close()
        let databaseBefore = try Data(contentsOf: url)

        try vault.changePassword(from: password, to: "ein ganz neues passwort")
        #expect(throws: VaultError.wrongPassword) { try vault.changePassword(from: password, to: "noch ein anderes passwort") }
        #expect(try Data(contentsOf: url) == databaseBefore)

        let newMac = makeVault(url, InMemoryDatabaseKeyStore())
        await #expect(throws: VaultError.wrongPassword) { _ = try await newMac.recover(password: password) }
        try await newMac.recover(password: "ein ganz neues passwort").store.close()
    }

    @Test func databaseWithoutKeyOrEnvelopeIsUnrecoverable() async throws {
        let url = tempDatabaseURL()
        let vault = makeVault(url, InMemoryDatabaseKeyStore())
        try await vault.setUp(password: password).store.close()
        try FileManager.default.removeItem(at: vault.envelopeURL)

        #expect(throws: VaultError.keyUnrecoverable) { try makeVault(url, InMemoryDatabaseKeyStore()).state() }
    }

    @Test func refusedKeychainStillOpensAndAsksForThePasswordNextTime() async throws {
        let url = tempDatabaseURL()
        let vault = makeVault(url, RefusingKeyStore())
        #expect(try vault.state() == .needsSetup)

        let opened = try await vault.setUp(password: password)
        #expect(opened.keyNotStored == .keychain(errSecAuthFailed))
        try await opened.store.upsert(connection: connection)
        await opened.store.close()

        // No key on this Mac: the password opens it again, with the data intact.
        #expect(try vault.state() == .needsPassword)
        let again = try await vault.recover(password: password)
        #expect(again.keyNotStored == .keychain(errSecAuthFailed))
        #expect(await again.store.snapshot().connections == [connection])
        await again.store.close()
    }

    @Test func storedKeyReportsNothing() async throws {
        let opened = try await makeVault(tempDatabaseURL(), InMemoryDatabaseKeyStore()).setUp(password: password)
        #expect(opened.keyNotStored == nil)
        await opened.store.close()
    }

    @Test(arguments: [DatabaseKeyError.authenticationCancelled, .missingEntitlement, .invalidated])
    func otherKeyErrorsStillFailSetup(error: DatabaseKeyError) async throws {
        let vault = makeVault(tempDatabaseURL(), RefusingKeyStore(saveError: error))
        await #expect(throws: VaultError.key(error)) { _ = try await vault.setUp(password: password) }
    }

    @Test(arguments: [errSecDecode, errSecAuthFailed])
    func unreadableKeyItemFallsBackToThePassword(status: OSStatus) async throws {
        let url = tempDatabaseURL()
        try await makeVault(url, InMemoryDatabaseKeyStore()).setUp(password: password).store.close()

        let vault = makeVault(url, RefusingKeyStore(readError: .keychain(status)))
        #expect(try vault.state() == .needsPassword)
    }

    @Test func otherReadErrorsAreReported() async throws {
        let vault = makeVault(tempDatabaseURL(), RefusingKeyStore(readError: .keychain(errSecNotAvailable)))
        #expect(throws: VaultError.key(.keychain(errSecNotAvailable))) { try vault.state() }
    }

    @Test func envelopeRoundTripAndTamperDetection() throws {
        let key = Data((0..<32).map { UInt8($0) })
        var envelope = try KeyEnvelope.seal(key, password: password, iterations: 1_000)
        #expect(try envelope.open(password: password, acceptedIterations: 1_000...1_000) == key)
        envelope.sealedKey[envelope.sealedKey.count - 1] ^= 0x01
        #expect(throws: VaultError.wrongPassword) { try envelope.open(password: password, acceptedIterations: 1_000...1_000) }
    }

    /// `iterations` comes from a file: out of range is rejected before the KDF runs (no
    /// `UInt32` trap, no endless unlock, no weak key).
    @Test func envelopeIterationsOutOfRangeAreRejected() throws {
        let key = Data((0..<32).map { UInt8($0) })
        var envelope = try KeyEnvelope.seal(key, password: password, iterations: 1_000)
        for iterations in [0, -1, 1_000, 50_000_001, Int(UInt32.max) + 1, Int.max] {
            envelope.iterations = iterations
            #expect(throws: VaultError.unsupportedEnvelope) { try envelope.open(password: password) }
        }
        #expect(throws: VaultError.unsupportedEnvelope) { try KeyEnvelope.seal(key, password: password, iterations: Int.max) }
    }
}
