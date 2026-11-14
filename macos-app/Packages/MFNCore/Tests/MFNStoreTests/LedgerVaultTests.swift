import Foundation
import MFNCore
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

private let password = "korrekt pferd batterie"
private let connection = Connection(id: "c1", connectorID: .ing, displayName: "ING")

@Suite struct LedgerVaultTests {
    @Test func firstStartNeedsSetupThenIsReady() async throws {
        let url = tempDatabaseURL()
        let keychain = InMemoryDatabaseKeyStore()
        let vault = makeVault(url, keychain)
        #expect(try vault.state() == .needsSetup)

        let store = try await vault.setUp(password: password)
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
        try await vault.setUp(password: password).close()

        let key = try #require(try keychain.read())
        let envelope = try Data(contentsOf: vault.envelopeURL)
        #expect(envelope.range(of: key) == nil)
        #expect(envelope.range(of: Data(password.utf8)) == nil)
    }

    @Test func copiedDatabaseOpensOnceWithPasswordOnNewMac() async throws {
        let url = tempDatabaseURL()
        let original = makeVault(url, InMemoryDatabaseKeyStore())
        let store = try await original.setUp(password: password)
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

        let recovered = try await newMac.recover(password: password)
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
        try await vault.setUp(password: password).close()
        let databaseBefore = try Data(contentsOf: url)

        try vault.changePassword(from: password, to: "ein ganz neues passwort")
        #expect(throws: VaultError.wrongPassword) { try vault.changePassword(from: password, to: "noch ein anderes passwort") }
        #expect(try Data(contentsOf: url) == databaseBefore)

        let newMac = makeVault(url, InMemoryDatabaseKeyStore())
        await #expect(throws: VaultError.wrongPassword) { _ = try await newMac.recover(password: password) }
        try await newMac.recover(password: "ein ganz neues passwort").close()
    }

    @Test func databaseWithoutKeyOrEnvelopeIsUnrecoverable() async throws {
        let url = tempDatabaseURL()
        let vault = makeVault(url, InMemoryDatabaseKeyStore())
        try await vault.setUp(password: password).close()
        try FileManager.default.removeItem(at: vault.envelopeURL)

        #expect(throws: VaultError.keyUnrecoverable) { try makeVault(url, InMemoryDatabaseKeyStore()).state() }
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
