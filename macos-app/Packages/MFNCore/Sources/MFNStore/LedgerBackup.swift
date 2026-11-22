import CryptoKit
import Foundation
import MFNCore
import Security

public enum BackupError: Error, Equatable, Sendable {
    /// Not a file MFN wrote (wrong signature, unreadable header).
    case notABackup
    /// Written by a newer MFN in a container format this version does not know.
    case unsupportedFormat(Int)
    /// Truncated, or the content does not match its checksum.
    case damaged
    case wrongPassword
    /// The database inside was migrated by a newer MFN.
    case newerSchema(found: Int, supported: Int)
    case vault(VaultError)
    case file(String)
}

/// A backup is one file: the encrypted database as it lies on disk, and `ledger.key` (the
/// database key wrapped with the user's password) to open it on any Mac.
///
/// Nothing in it is readable without the database password **as it was when the backup was
/// written**. Bank credentials and sessions are not part of it; they stay in the keychain.
///
/// Layout: `MFNBKUP1` · header length (UInt32, big endian) · header (JSON, `Manifest`) ·
/// database bytes. The header carries length and SHA-256 of the database bytes.
public enum LedgerBackup {
    public static let fileExtension = "mfnbackup"
    public static let format = 1

    /// What a backup says about itself without the password.
    public struct Info: Equatable, Sendable {
        public let createdAt: Date
        public let appVersion: String
        public let schemaVersion: Int
        public let databaseBytes: Int
    }

    struct Manifest: Codable, Equatable {
        var format = LedgerBackup.format
        var createdAt: Date
        var appVersion: String
        var schemaVersion: Int
        var databaseBytes: Int
        /// Lowercase hex.
        var databaseSHA256: String
        var envelope: KeyEnvelope
        /// What the app keeps outside the database about its content (sidebar order, hidden
        /// accounts), encrypted with a key derived from the database key. Opaque to the store.
        var settings: Data?

        var info: Info {
            Info(createdAt: createdAt, appVersion: appVersion, schemaVersion: schemaVersion, databaseBytes: databaseBytes)
        }
    }

    /// The key for `Manifest.settings`, derived from the database key.
    static func sealingKey(for databaseKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: databaseKey), info: Data("mfn-backup-settings-v1".utf8), outputByteCount: 32)
    }

    /// The key for hashes the app keeps in its preferences (`EncryptedLedgerStore.preferenceHashKey`).
    static func preferenceHashKey(for databaseKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: databaseKey), info: Data("mfn-preference-hash-v1".utf8), outputByteCount: 32)
    }

    /// `nil` if it was not sealed for this database.
    static func unseal(_ sealed: Data, databaseKey: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: sealingKey(for: databaseKey))
    }

    static let magic = Data("MFNBKUP1".utf8)
    /// A header is a few hundred bytes; anything far beyond that is not ours.
    static let maximumHeaderBytes = 1 << 20
    static let chunk = 1 << 20

    static let manualPrefix = "MFN-Sicherung-"
    /// Automatic backups carry their own name: only these are ever removed by the rotation.
    static let automaticPrefix = "MFN-Auto-Sicherung-"

    /// `MFN-Sicherung-2026-11-22-1830.mfnbackup`, automatic ones `MFN-Auto-Sicherung-…`.
    public static func fileName(at date: Date, automatic: Bool = false, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%@%04d-%02d-%02d-%02d%02d.%@", automatic ? automaticPrefix : manualPrefix,
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, fileExtension)
    }

    /// Reads the header only: cheap, no password.
    public static func info(of url: URL) throws(BackupError) -> Info {
        let handle = try open(url)
        defer { try? handle.close() }
        return try readHeader(handle).info
    }

    /// The backups in `folder` that the automatic backup may delete: all automatic ones but the
    /// newest `keep` (by the date in the file name, which sorts as text). Backups the user made
    /// by hand and other files are never listed.
    public static func surplus(in folder: URL, keep: Int) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let backups = names.filter { $0.hasPrefix(automaticPrefix) && $0.hasSuffix("." + fileExtension) }.sorted()
        return backups.dropLast(max(keep, 1)).map { folder.appendingPathComponent($0) }
    }

    // MARK: - File format

    static func open(_ url: URL) throws(BackupError) -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw .file(error.localizedDescription)
        }
    }

    /// Leaves `handle` at the first database byte.
    static func readHeader(_ handle: FileHandle) throws(BackupError) -> Manifest {
        guard let signature = try? handle.read(upToCount: magic.count), signature == magic else { throw .notABackup }
        guard let lengthBytes = try? handle.read(upToCount: 4), lengthBytes.count == 4 else { throw .notABackup }
        let length = lengthBytes.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= maximumHeaderBytes else { throw .notABackup }
        guard let header = try? handle.read(upToCount: length), header.count == length else { throw .damaged }
        // The format number is read on its own: a newer format may have changed the rest.
        struct Probe: Decodable { var format: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let probe = try? decoder.decode(Probe.self, from: header) else { throw .notABackup }
        guard probe.format == format else { throw .unsupportedFormat(probe.format) }
        guard let manifest = try? decoder.decode(Manifest.self, from: header), manifest.databaseBytes >= 0 else { throw .damaged }
        return manifest
    }

    static func header(_ manifest: Manifest) throws(BackupError) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(manifest), json.count <= maximumHeaderBytes else {
            throw .file("Kopfdaten der Sicherung")
        }
        var data = magic
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(json)
        return data
    }

    /// Copies up to `limit` bytes (`nil`: to the end) and returns their count and SHA-256.
    static func copy(from source: FileHandle, to destination: FileHandle, limit: Int?) throws -> (bytes: Int, sha256: String) {
        var hash = SHA256()
        var copied = 0
        while limit.map({ copied < $0 }) ?? true {
            let want = limit.map { min(chunk, $0 - copied) } ?? chunk
            guard let data = try source.read(upToCount: want), !data.isEmpty else { break }
            hash.update(data: data)
            try destination.write(contentsOf: data)
            copied += data.count
        }
        return (copied, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// The database key of a backup between `prepareRestore` and `commitRestore`. A reference, so
/// there is one buffer to zero: a `Data` passed around by value is wiped copy by copy.
final class RestoreKey: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init(_ data: Data) { self.data = data }

    func use<T, E: Error>(_ body: (Data) throws(E) -> T) throws(E) -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(data)
    }

    func wipe() {
        lock.lock()
        defer { lock.unlock() }
        data.wipe()
    }

    deinit { data.wipe() }
}

extension LedgerVault {
    /// Writes a backup of `store` to `destination` (replacing a file there). The file appears
    /// only when it is complete; a failure leaves none.
    ///
    /// `settings`: opaque data of the app that belongs to this database's content. It is stored
    /// encrypted and handed back by `prepareRestore`.
    public func writeBackup(of store: EncryptedLedgerStore, to destination: URL, appVersion: String,
                            settings: Data? = nil, now: Date = Date()) async throws(BackupError) -> LedgerBackup.Info {
        let envelope: KeyEnvelope
        do {
            envelope = try readEnvelope()
        } catch {
            throw .vault(error)
        }
        // Built in the app's own temporary folder: next to a file the user chose in a save
        // panel the sandbox allows nothing else.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mfn-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent(EncryptedLedgerStore.fileName)
        let assembled = work.appendingPathComponent("backup")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw .file(error.localizedDescription)
        }
        let sealed: Data?
        do {
            try await store.backup(to: copy)
            if let settings { sealed = try await store.seal(settings) } else { sealed = nil }
        } catch {
            throw .vault(.store(error))
        }
        let info: LedgerBackup.Info
        do {
            // The header comes first and carries the checksum, which is only known after the copy.
            // Its length does not depend on the checksum (always 64 hex digits): write it with a
            // placeholder, copy and hash the database in one pass, then write it again in place.
            let size = (try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int) ?? 0
            var manifest = LedgerBackup.Manifest(createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
                                                 appVersion: appVersion, schemaVersion: Schema.migrations.count,
                                                 databaseBytes: size, databaseSHA256: String(repeating: "0", count: 64), envelope: envelope,
                                                 settings: sealed)
            let placeholder = try LedgerBackup.header(manifest)
            guard FileManager.default.createFile(atPath: assembled.path, contents: placeholder) else {
                throw BackupError.file("Sicherung ließ sich nicht anlegen")
            }
            let reader = try FileHandle(forReadingFrom: copy)
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: assembled)
            defer { try? writer.close() }
            try writer.seekToEnd()
            let digest = try LedgerBackup.copy(from: reader, to: writer, limit: nil)
            guard digest.bytes == size else { throw BackupError.file("Datenbankkopie unvollständig") }
            manifest.databaseSHA256 = digest.sha256
            let header = try LedgerBackup.header(manifest)
            guard header.count == placeholder.count else { throw BackupError.file("Kopfdaten der Sicherung") }
            try writer.seek(toOffset: 0)
            try writer.write(contentsOf: header)
            try writer.synchronize()
            info = manifest.info
        } catch let error as BackupError {
            throw error
        } catch {
            throw .file(error.localizedDescription)
        }
        do {
            let files = FileManager.default
            if files.fileExists(atPath: destination.path) {
                // A backup already at this place stays until the new one is complete next to it.
                let folder = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
                defer { try? files.removeItem(at: folder) }
                let fresh = folder.appendingPathComponent(destination.lastPathComponent)
                try files.copyItem(at: assembled, to: fresh)
                _ = try files.replaceItemAt(destination, withItemAt: fresh)
            } else {
                do {
                    try files.copyItem(at: assembled, to: destination)
                } catch {
                    try? files.removeItem(at: destination)
                    throw error
                }
            }
        } catch {
            throw .file(error.localizedDescription)
        }
        Log.store.info("Sicherung geschrieben (\(info.databaseBytes, privacy: .public) Bytes)")
        return info
    }

    /// A backup that was checked and unpacked next to the database, ready for `commitRestore`.
    public struct PreparedRestore: Sendable {
        public let info: LedgerBackup.Info
        /// What `writeBackup` was given as `settings`. `nil`: none, or not readable.
        public let settings: Data?
        let staged: URL
        let envelope: KeyEnvelope
        /// Wiped by `commitRestore` and `discard`, and when the last copy of this value goes.
        let key: RestoreKey
    }

    /// What `commitRestore` did.
    public struct RestoreResult: Equatable, Sendable {
        /// The database that was in place before, moved aside (its `ledger.key` lies next to it
        /// with the same name and the extension `key`). `nil`: there was none.
        public let previousDatabase: URL?
        /// The keychain refused the restored key: the next unlock asks for the password.
        public let keyNotStored: DatabaseKeyError?
    }

    /// Checks a backup without touching the database in place: password, checksum, that the
    /// database inside opens and is not from a newer MFN. Older schemas are migrated in the
    /// unpacked copy.
    public func prepareRestore(from url: URL, password: String) async throws(BackupError) -> PreparedRestore {
        let handle = try LedgerBackup.open(url)
        defer { try? handle.close() }
        let manifest = try LedgerBackup.readHeader(handle)
        guard manifest.schemaVersion <= Schema.migrations.count else {
            throw .newerSchema(found: manifest.schemaVersion, supported: Schema.migrations.count)
        }
        var key: Data
        do {
            key = try manifest.envelope.open(password: password, acceptedIterations: acceptedIterations)
        } catch .wrongPassword {
            throw .wrongPassword
        } catch {
            throw .vault(error)
        }
        let staged = databaseURL.deletingLastPathComponent().appendingPathComponent("ledger-restore-\(UUID().uuidString).sqlite")
        var keep = false
        defer {
            if !keep {
                key.wipe()
                Self.removeDatabase(at: staged)
            }
        }
        do {
            try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: staged.path, contents: nil) else {
                throw BackupError.file("Arbeitskopie ließ sich nicht anlegen")
            }
            let writer = try FileHandle(forWritingTo: staged)
            defer { try? writer.close() }
            let copied = try LedgerBackup.copy(from: handle, to: writer, limit: manifest.databaseBytes)
            // Shorter (truncated) or other content; bytes after the database are not ours either.
            let rest = try handle.read(upToCount: 1) ?? Data()
            guard copied.bytes == manifest.databaseBytes, copied.sha256 == manifest.databaseSHA256, rest.isEmpty else {
                throw BackupError.damaged
            }
            try writer.synchronize()
        } catch let error as BackupError {
            throw error
        } catch {
            throw .file(error.localizedDescription)
        }
        do {
            let store = try await EncryptedLedgerStore.open(at: staged, key: key, keepingCopy: false)
            await store.close()
        } catch .newerSchema(let found, let supported) {
            throw .newerSchema(found: found, supported: supported)
        } catch .cannotDecrypt {
            // The password opened the key, the key does not open the database.
            throw .damaged
        } catch {
            throw .vault(.store(error))
        }
        keep = true
        let settings = manifest.settings.flatMap { LedgerBackup.unseal($0, databaseKey: key) }
        // The holder keeps the buffer; this function's own reference goes with its scope.
        return PreparedRestore(info: manifest.info, settings: settings, staged: staged, envelope: manifest.envelope, key: RestoreKey(key))
    }

    /// Throws away a prepared restore that will not be committed.
    public func discard(_ prepared: PreparedRestore) {
        prepared.key.wipe()
        Self.removeDatabase(at: prepared.staged)
    }

    /// Puts the prepared database in place. **The store of the database in place must be
    /// closed.** That database and its `ledger.key` are moved aside, never deleted; if the swap
    /// fails they are moved back.
    public func commitRestore(_ prepared: PreparedRestore, now: Date = Date()) throws(BackupError) -> RestoreResult {
        defer { prepared.key.wipe() }
        let files = FileManager.default
        let folder = databaseURL.deletingLastPathComponent()
        var previous: URL?
        var moved: [(from: URL, to: URL)] = []
        // Only an envelope this restore wrote may be removed again: until then the file at
        // `envelopeURL` is the current database's own `ledger.key`.
        var wroteEnvelope = false
        func move(_ from: URL, _ to: URL) throws {
            try files.moveItem(at: from, to: to)
            moved.append((from, to))
        }
        do {
            if files.fileExists(atPath: databaseURL.path) {
                let stamp = Self.stamp(now)
                var aside = folder.appendingPathComponent("\(EncryptedLedgerStore.preRestorePrefix)\(stamp).sqlite")
                var attempt = 1
                while files.fileExists(atPath: aside.path) {
                    attempt += 1
                    aside = folder.appendingPathComponent("\(EncryptedLedgerStore.preRestorePrefix)\(stamp)-\(attempt).sqlite")
                }
                try move(databaseURL, aside)
                // A closed database leaves no WAL; if one is there, it belongs to the old data.
                for suffix in ["-wal", "-shm"] {
                    let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
                    if files.fileExists(atPath: sidecar.path) { try move(sidecar, URL(fileURLWithPath: aside.path + suffix)) }
                }
                if files.fileExists(atPath: envelopeURL.path) {
                    try move(envelopeURL, aside.deletingPathExtension().appendingPathExtension("key"))
                }
                previous = aside
            }
            try move(prepared.staged, databaseURL)
            for suffix in ["-wal", "-shm"] { try? files.removeItem(at: URL(fileURLWithPath: prepared.staged.path + suffix)) }
            wroteEnvelope = true
            try writeEnvelope(prepared.envelope)
        } catch {
            if wroteEnvelope { try? files.removeItem(at: envelopeURL) }
            for step in moved.reversed() { try? files.moveItem(at: step.to, to: step.from) }
            if let error = error as? VaultError { throw .vault(error) }
            throw .file(error.localizedDescription)
        }
        // Replaces the key of the old database in the keychain. If the keychain refuses, the old
        // key is gone from it as well (`save` removes it first): the next unlock asks for the
        // password. Needs a key store that is still valid (call this before locking).
        let keyNotStored: DatabaseKeyError?
        do {
            keyNotStored = try prepared.key.use { key throws(VaultError) in try saveKey(key) }
        } catch .key(let reason) {
            keyNotStored = reason
        } catch {
            keyNotStored = .keychain(errSecInternalError)
        }
        Log.store.info("Sicherung wiederhergestellt")
        return RestoreResult(previousDatabase: previous, keyNotStored: keyNotStored)
    }

    static func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}
