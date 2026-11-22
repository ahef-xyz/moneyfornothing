import Foundation
import MFNCore
import Security
import Testing
@testable import MFNStore

private func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mfn-backup-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeVault(in folder: URL, _ keyStore: any DatabaseKeyStore = InMemoryDatabaseKeyStore()) -> LedgerVault {
    LedgerVault(databaseURL: folder.appendingPathComponent(EncryptedLedgerStore.fileName), keyStore: keyStore, iterations: 1_000)
}

private struct RefusingSave: DatabaseKeyStore {
    func read() throws(DatabaseKeyError) -> Data? { nil }
    func save(_ key: Data) throws(DatabaseKeyError) { throw .keychain(errSecAuthFailed) }
}

private let password = "korrekt pferd batterie"
private let ing = Connection(id: "c1", connectorID: .ing, displayName: "ING")
private let dkb = Connection(id: "c2", connectorID: .dkb, displayName: "DKB")

/// A vault with one connection, and a backup of it.
private func source(_ connection: Connection = ing) async throws -> (vault: LedgerVault, backup: URL) {
    let vault = makeVault(in: tempFolder())
    let store = try await vault.setUp(password: password).store
    try await store.upsert(connection: connection)
    let backup = tempFolder().appendingPathComponent("a." + LedgerBackup.fileExtension)
    _ = try await vault.writeBackup(of: store, to: backup, appVersion: "0.5.0")
    await store.close()
    return (vault, backup)
}

@Suite struct LedgerBackupTests {
    @Test func backupRestoresOnAnotherMac() async throws {
        let (_, backup) = try await source()
        let info = try LedgerBackup.info(of: backup)
        #expect(info.appVersion == "0.5.0")
        #expect(info.schemaVersion == Schema.migrations.count)
        #expect(info.databaseBytes > 0)

        let keychain = InMemoryDatabaseKeyStore()
        let fresh = makeVault(in: tempFolder(), keychain)
        #expect(try fresh.state() == .needsSetup)
        let prepared = try await fresh.prepareRestore(from: backup, password: password)
        #expect(prepared.info == info)
        // Checked, but nothing in place yet.
        #expect(try fresh.state() == .needsSetup)
        let result = try fresh.commitRestore(prepared)
        #expect(result == LedgerVault.RestoreResult(previousDatabase: nil, keyNotStored: nil))

        #expect(try fresh.state() == .ready)
        let store = try await fresh.open()
        #expect(await store.snapshot().connections == [ing])
        await store.close()
        // No working copy left behind.
        let files = try FileManager.default.contentsOfDirectory(atPath: fresh.databaseURL.deletingLastPathComponent().path)
        #expect(files.sorted() == ["ledger.key", "ledger.sqlite"])
    }

    @Test func settingsTravelEncrypted() async throws {
        let vault = makeVault(in: tempFolder(), InMemoryDatabaseKeyStore())
        let store = try await vault.setUp(password: password).store
        let backup = tempFolder().appendingPathComponent("a.mfnbackup")
        let settings = Data("{\"hiddenAccounts\":[\"ing-0123456789\"]}".utf8)
        _ = try await vault.writeBackup(of: store, to: backup, appVersion: "0.5.0", settings: settings)
        await store.close()
        #expect(try Data(contentsOf: backup).range(of: Data("ing-0123456789".utf8)) == nil)

        let fresh = makeVault(in: tempFolder(), InMemoryDatabaseKeyStore())
        let prepared = try await fresh.prepareRestore(from: backup, password: password)
        #expect(prepared.settings == settings)
        fresh.discard(prepared)
    }

    @Test func backupWithoutSettingsRestoresNone() async throws {
        let (_, backup) = try await source()
        let fresh = makeVault(in: tempFolder(), InMemoryDatabaseKeyStore())
        let prepared = try await fresh.prepareRestore(from: backup, password: password)
        #expect(prepared.settings == nil)
        fresh.discard(prepared)
    }

    @Test func backupDoesNotContainKeyOrPassword() async throws {
        let keychain = InMemoryDatabaseKeyStore()
        let vault = makeVault(in: tempFolder(), keychain)
        let store = try await vault.setUp(password: password).store
        let backup = tempFolder().appendingPathComponent("a.mfnbackup")
        _ = try await vault.writeBackup(of: store, to: backup, appVersion: "0.5.0")
        await store.close()
        let data = try Data(contentsOf: backup)
        let key = try #require(try keychain.read())
        #expect(data.range(of: key) == nil)
        #expect(data.range(of: Data(password.utf8)) == nil)
        #expect(data.range(of: Data("SQLite format 3".utf8)) == nil)
    }

    @Test func restoreKeepsTheDatabaseInPlace() async throws {
        let (_, backup) = try await source(ing)
        let keychain = InMemoryDatabaseKeyStore()
        let target = makeVault(in: tempFolder(), keychain)
        let other = "ein ganz anderes passwort"
        let store = try await target.setUp(password: other).store
        try await store.upsert(connection: dkb)
        await store.close()
        let oldKey = try #require(try keychain.read())

        let prepared = try await target.prepareRestore(from: backup, password: password)
        let result = try target.commitRestore(prepared)
        let previous = try #require(result.previousDatabase)
        #expect(previous.lastPathComponent.hasPrefix("ledger-vor-wiederherstellung-"))
        #expect(try keychain.read() != oldKey)

        let restored = try await target.open()
        #expect(await restored.snapshot().connections == [ing])
        await restored.close()

        // The data from before is complete: database and its own `ledger.key`.
        let folder = tempFolder()
        try FileManager.default.copyItem(at: previous, to: folder.appendingPathComponent(EncryptedLedgerStore.fileName))
        try FileManager.default.copyItem(at: previous.deletingPathExtension().appendingPathExtension("key"),
                                         to: folder.appendingPathComponent(KeyEnvelope.fileName))
        let before = try await makeVault(in: folder).recover(password: other).store
        #expect(await before.snapshot().connections == [dkb])
        await before.close()
    }

    @Test func backupNeedsThePasswordFromWhenItWasWritten() async throws {
        let (vault, backup) = try await source()
        let later = "neues passwort nach der sicherung"
        try vault.changePassword(from: password, to: later)
        let fresh = makeVault(in: tempFolder())
        await #expect(throws: BackupError.wrongPassword) { try await fresh.prepareRestore(from: backup, password: later) }
        _ = try await fresh.prepareRestore(from: backup, password: password)
    }

    @Test func wrongPasswordLeavesEverythingUntouched() async throws {
        let (_, backup) = try await source()
        let target = makeVault(in: tempFolder())
        let store = try await target.setUp(password: password).store
        try await store.upsert(connection: dkb)
        await store.close()
        await #expect(throws: BackupError.wrongPassword) { try await target.prepareRestore(from: backup, password: "falsches passwort!") }
        let files = try FileManager.default.contentsOfDirectory(atPath: target.databaseURL.deletingLastPathComponent().path)
        #expect(files.sorted() == ["ledger.key", "ledger.sqlite"])
        let reopened = try await target.open()
        #expect(await reopened.snapshot().connections == [dkb])
        await reopened.close()
    }

    @Test func truncatedOrChangedFilesAreRefused() async throws {
        let (_, backup) = try await source()
        let data = try Data(contentsOf: backup)
        let folder = tempFolder()
        let fresh = makeVault(in: tempFolder())

        let truncated = folder.appendingPathComponent("kurz.mfnbackup")
        try data.prefix(data.count - 100).write(to: truncated)
        await #expect(throws: BackupError.damaged) { try await fresh.prepareRestore(from: truncated, password: password) }

        var flipped = data
        flipped[flipped.count - 10] ^= 0xFF
        let changed = folder.appendingPathComponent("anders.mfnbackup")
        try flipped.write(to: changed)
        await #expect(throws: BackupError.damaged) { try await fresh.prepareRestore(from: changed, password: password) }

        let longer = folder.appendingPathComponent("lang.mfnbackup")
        try (data + Data([0])).write(to: longer)
        await #expect(throws: BackupError.damaged) { try await fresh.prepareRestore(from: longer, password: password) }

        let foreign = folder.appendingPathComponent("fremd.mfnbackup")
        try Data("Kein MFN".utf8).write(to: foreign)
        #expect(throws: BackupError.notABackup) { try LedgerBackup.info(of: foreign) }
        await #expect(throws: BackupError.notABackup) { try await fresh.prepareRestore(from: foreign, password: password) }

        // Nothing was unpacked for good.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: fresh.databaseURL.deletingLastPathComponent().path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func newerBackupsAreRefused() async throws {
        let (_, backup) = try await source()
        let handle = try FileHandle(forReadingFrom: backup)
        var manifest = try LedgerBackup.readHeader(handle)
        let database = try handle.readToEnd() ?? Data()
        try handle.close()
        let folder = tempFolder()
        let fresh = makeVault(in: tempFolder())

        manifest.schemaVersion = Schema.migrations.count + 1
        let newerSchema = folder.appendingPathComponent("schema.mfnbackup")
        try (try LedgerBackup.header(manifest) + database).write(to: newerSchema)
        await #expect(throws: BackupError.newerSchema(found: Schema.migrations.count + 1, supported: Schema.migrations.count)) {
            try await fresh.prepareRestore(from: newerSchema, password: password)
        }

        manifest.format = 2
        let newerFormat = folder.appendingPathComponent("format.mfnbackup")
        try (try LedgerBackup.header(manifest) + database).write(to: newerFormat)
        #expect(throws: BackupError.unsupportedFormat(2)) { try LedgerBackup.info(of: newerFormat) }
    }

    @Test func refusedKeychainIsReported() async throws {
        let (_, backup) = try await source()
        let target = makeVault(in: tempFolder(), RefusingSave())
        let prepared = try await target.prepareRestore(from: backup, password: password)
        let result = try target.commitRestore(prepared)
        #expect(result.keyNotStored == .keychain(errSecAuthFailed))
        // Database and `ledger.key` are in place: the password opens them.
        #expect(try target.state() == .needsPassword)
        let store = try await target.recover(password: password).store
        #expect(await store.snapshot().connections == [ing])
        await store.close()
    }

    @Test func discardRemovesTheWorkingCopy() async throws {
        let (_, backup) = try await source()
        let fresh = makeVault(in: tempFolder())
        let prepared = try await fresh.prepareRestore(from: backup, password: password)
        fresh.discard(prepared)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.databaseURL.deletingLastPathComponent().path).isEmpty)
    }

    @Test func writingReplacesAnExistingFile() async throws {
        let vault = makeVault(in: tempFolder())
        let store = try await vault.setUp(password: password).store
        let backup = tempFolder().appendingPathComponent("a.mfnbackup")
        try Data("alt".utf8).write(to: backup)
        _ = try await vault.writeBackup(of: store, to: backup, appVersion: "0.5.0")
        #expect(try LedgerBackup.info(of: backup).appVersion == "0.5.0")
        await store.close()
    }

    @Test func surplusKeepsTheNewestAndForeignFiles() throws {
        let folder = tempFolder()
        let utc = try #require(TimeZone(identifier: "UTC"))
        let names = (0..<5).map { LedgerBackup.fileName(at: Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 86_400), automatic: true, timeZone: utc) }
        #expect(names[0] == "MFN-Auto-Sicherung-2027-01-15-0800.mfnbackup")
        // A backup the user saved into the same folder by hand is never rotated away.
        let manual = LedgerBackup.fileName(at: Date(timeIntervalSince1970: 1_700_000_000), timeZone: utc)
        #expect(manual.hasPrefix("MFN-Sicherung-"))
        for name in names + ["Notizen.txt", "MFN-Auto-Sicherung-alt.zip", manual] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        #expect(LedgerBackup.surplus(in: folder, keep: 3).map(\.lastPathComponent) == Array(names.prefix(2)))
        #expect(LedgerBackup.surplus(in: folder, keep: 10).isEmpty)
        // Never all of them.
        #expect(LedgerBackup.surplus(in: folder, keep: 0).count == 4)
    }

    /// A swap that fails before the old `ledger.key` was moved aside must leave that key alone.
    @Test func failedSwapKeepsTheKeyOfTheDatabaseInPlace() async throws {
        let (_, backup) = try await source(ing)
        let folder = tempFolder()
        let target = makeVault(in: folder)
        let other = "ein ganz anderes passwort"
        let store = try await target.setUp(password: other).store
        try await store.upsert(connection: dkb)
        await store.close()
        let envelope = folder.appendingPathComponent("ledger.key")
        let before = try Data(contentsOf: envelope)

        // The move of a leftover WAL fails: something already lies where it would go.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: target.databaseURL.path + "-wal"))
        let aside = folder.appendingPathComponent("\(EncryptedLedgerStore.preRestorePrefix)\(LedgerVault.stamp(now)).sqlite-wal")
        try Data("im Weg".utf8).write(to: aside)

        let prepared = try await target.prepareRestore(from: backup, password: password)
        #expect(throws: BackupError.self) { _ = try target.commitRestore(prepared, now: now) }
        target.discard(prepared)
        #expect(try Data(contentsOf: envelope) == before, "the old key file is untouched")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: target.databaseURL.path + "-wal"))
        // The old data still opens with its own password on a Mac without the key.
        let moved = makeVault(in: folder, InMemoryDatabaseKeyStore())
        let reopened = try await moved.recover(password: other).store
        #expect(await reopened.snapshot().connections == [dkb])
        await reopened.close()
    }

    @Test func writingOverAnExistingBackupReplacesIt() async throws {
        let vault = makeVault(in: tempFolder())
        let store = try await vault.setUp(password: password).store
        let backup = tempFolder().appendingPathComponent("a.mfnbackup")
        _ = try await vault.writeBackup(of: store, to: backup, appVersion: "0.4.9")
        try await store.upsert(connection: ing)
        _ = try await vault.writeBackup(of: store, to: backup, appVersion: "0.5.0")
        await store.close()
        #expect(try LedgerBackup.info(of: backup).appVersion == "0.5.0")
        let fresh = makeVault(in: tempFolder(), InMemoryDatabaseKeyStore())
        let prepared = try await fresh.prepareRestore(from: backup, password: password)
        _ = try fresh.commitRestore(prepared)
        let restored = try await fresh.open()
        #expect(await restored.snapshot().connections == [ing])
        await restored.close()
    }

    @Test func oldCopiesNextToTheDatabaseAreRemovedAfterAMonth() throws {
        let folder = tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        for name in ["ledger-vor-update-schema-11.sqlite", "ledger-vor-wiederherstellung-2026-01-01-120000.sqlite", "ledger.sqlite", "ledger.key"] {
            let file = folder.appendingPathComponent(name)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }
        EncryptedLedgerStore.removeOutdatedCopies(in: folder, now: old.addingTimeInterval(29 * 86_400))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 4)
        EncryptedLedgerStore.removeOutdatedCopies(in: folder, now: old.addingTimeInterval(31 * 86_400))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["ledger.key", "ledger.sqlite"])
    }
}
