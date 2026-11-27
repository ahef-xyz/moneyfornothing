import AppKit
import MFNCore
import MFNStore
import Observation
import UniformTypeIdentifiers

extension UTType {
    /// Declared in `Info.plist` (`UTExportedTypeDeclarations`), extension `mfnbackup`.
    static let mfnBackup = UTType(exportedAs: "xyz.ahef.mfn.backup")
}

/// A backup file the user picked to restore from; its header was readable.
struct RestoreRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let info: LedgerBackup.Info
}

/// Result of a backup or restore, shown as an alert.
struct BackupNotice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    /// The database that was in place before a restore: offered in the Finder.
    var previous: URL?
}

/// Settings and state of the automatic backup (Settings → Sicherung). Nothing sensitive: the
/// folder is kept as a security-scoped bookmark, the files in it are encrypted backups.
@MainActor @Observable
final class AutoBackup {
    enum Frequency: Int, CaseIterable, Identifiable {
        case daily = 1
        case weekly = 7

        var id: Int { rawValue }
        var title: String { self == .daily ? String(localized: "Täglich") : String(localized: "Wöchentlich") }
        /// A little under the nominal interval, so the backup does not drift later every time.
        var interval: TimeInterval { TimeInterval(rawValue) * 86_400 - 2 * 3_600 }
    }

    static let keepChoices = [3, 7, 14, 30]

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: keys.enabled) } }
    var frequency: Frequency { didSet { defaults.set(frequency.rawValue, forKey: keys.days) } }
    var keep: Int { didSet { defaults.set(keep, forKey: keys.keep) } }
    /// For display: the folder's path with `~`.
    private(set) var folderPath: String?
    private(set) var lastSuccess: Date?
    private(set) var lastError: String?
    private(set) var isRunning = false
    @ObservationIgnored private var bookmark: Data?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let keys: (enabled: String, days: String, keep: String, bookmark: String, path: String, last: String, error: String)

    init(profile: LaunchProfile) {
        keys = (profile.scoped("autoBackup"), profile.scoped("autoBackupDays"), profile.scoped("autoBackupKeep"),
                profile.scoped("autoBackupFolder"), profile.scoped("autoBackupFolderPath"),
                profile.scoped("autoBackupLast"), profile.scoped("autoBackupError"))
        isEnabled = defaults.bool(forKey: keys.enabled)
        frequency = Frequency(rawValue: defaults.integer(forKey: keys.days)) ?? .daily
        let stored = defaults.integer(forKey: keys.keep)
        keep = Self.keepChoices.contains(stored) ? stored : 7
        bookmark = defaults.data(forKey: keys.bookmark)
        folderPath = bookmark == nil ? nil : defaults.string(forKey: keys.path)
        let last = defaults.double(forKey: keys.last)
        lastSuccess = last > 0 ? Date(timeIntervalSince1970: last) : nil
        lastError = defaults.string(forKey: keys.error)
    }

    var hasFolder: Bool { bookmark != nil }

    func isDue(now: Date = Date()) -> Bool {
        guard isEnabled, hasFolder, !isRunning else { return false }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= frequency.interval
    }

    /// Returns false if the folder cannot be remembered (no bookmark).
    @discardableResult
    func setFolder(_ url: URL) -> Bool {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        bookmark = data
        folderPath = (url.path as NSString).abbreviatingWithTildeInPath
        defaults.set(data, forKey: keys.bookmark)
        defaults.set(folderPath, forKey: keys.path)
        setError(nil)
        return true
    }

    /// The folder, with access started: call `stopAccessingSecurityScopedResource()` when done.
    fileprivate func openFolder() -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        // Moved or renamed: the bookmark still resolves, renew it for the next time.
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            self.bookmark = fresh
            defaults.set(fresh, forKey: keys.bookmark)
            folderPath = (url.path as NSString).abbreviatingWithTildeInPath
            defaults.set(folderPath, forKey: keys.path)
        }
        return url
    }

    fileprivate func begin() { isRunning = true }

    fileprivate func finish(success date: Date) {
        isRunning = false
        lastSuccess = date
        defaults.set(date.timeIntervalSince1970, forKey: keys.last)
        setError(nil)
    }

    /// `message == nil`: ended without a result (locked meanwhile); it stays due.
    fileprivate func finish(failure message: String?) {
        isRunning = false
        if let message { setError(message) }
    }

    private func setError(_ message: String?) {
        lastError = message
        if let message { defaults.set(message, forKey: keys.error) } else { defaults.removeObject(forKey: keys.error) }
    }
}

// MARK: - Commands

extension AppModel {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var canBackUp: Bool { !lock.isLocked && backupStore != nil && !isBackingUp }

    /// While unlocked, or on the setup screen of an empty install (the way to a new Mac).
    var canRestoreBackup: Bool {
        guard !isBackingUp, !lock.isLocked, backupVault != nil, restoreRequest == nil else { return false }
        return backupStore != nil || vaultPrompt == .setup
    }

    /// "Sicherung erstellen …" (⌥⌘B): one encrypted file wherever the user wants it.
    func createBackup() {
        guard canBackUp else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Sicherung erstellen")
        panel.message = String(localized: "Die Sicherung ist verschlüsselt. Zum Wiederherstellen brauchst du dein heutiges Datenbank-Passwort.")
        panel.prompt = String(localized: "Sichern")
        panel.nameFieldStringValue = LedgerBackup.fileName(at: Date())
        panel.allowedContentTypes = [.mfnBackup]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        backupPanel = panel
        let session = lockSession
        present(panel) { [weak self] response in
            guard let self else { return }
            if backupPanel === panel { backupPanel = nil }
            // Locked while the panel was open (`close()` cancels it): nothing is written.
            guard response == .OK, let url = panel.url, !isStale(session),
                  let vault = backupVault, let store = backupStore else { return }
            isBackingUp = true
            let settings = backupSettings
            Task { [weak self] in
                let failure: BackupError?
                do throws(BackupError) {
                    _ = try await vault.writeBackup(of: store, to: url, appVersion: Self.appVersion, settings: settings)
                    failure = nil
                } catch {
                    failure = error
                }
                guard let self else { return }
                isBackingUp = false
                if let failure {
                    Log.logger("backup").error("Backup failed: \(String(describing: failure), privacy: .private)")
                    backupNotice = BackupNotice(title: String(localized: "Die Sicherung konnte nicht erstellt werden."), message: Self.message(for: failure))
                } else {
                    AccessibilityNotification.Announcement(String(localized: "Sicherung erstellt")).post()
                }
            }
        }
    }

    /// "Aus Sicherung wiederherstellen …": picks the file; the sheet asks for the password.
    func chooseBackupToRestore() {
        guard canRestoreBackup else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Aus Sicherung wiederherstellen")
        panel.prompt = String(localized: "Auswählen")
        panel.allowedContentTypes = [.mfnBackup]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        backupPanel = panel
        let session = lockSession
        present(panel) { [weak self] response in
            guard let self else { return }
            if backupPanel === panel { backupPanel = nil }
            guard response == .OK, let url = panel.url, !isStale(session) else { return }
            do throws(BackupError) {
                restoreRequest = RestoreRequest(url: url, info: try LedgerBackup.info(of: url))
            } catch {
                backupNotice = BackupNotice(title: String(localized: "Diese Datei lässt sich nicht wiederherstellen."), message: Self.message(for: error))
            }
        }
    }

    private func present(_ panel: NSSavePanel, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in MainActor.assumeIsolated { completion(response) } }
        } else {
            panel.begin { response in MainActor.assumeIsolated { completion(response) } }
        }
    }

    /// Replaces the data in place with the backup. Returns an error text for the sheet while
    /// nothing has changed yet; from the swap on, the outcome is a `backupNotice`.
    ///
    /// The backup is checked completely first (password, checksum, schema). The database in place
    /// is moved aside, never deleted. With data open, MFN locks afterwards: the next unlock opens
    /// the restored database.
    func restoreBackup(_ request: RestoreRequest, password: String) async -> String? {
        guard let vault = backupVault, !isBackingUp, !lock.isLocked else { return String(localized: "MFN ist gesperrt.") }
        let session = lockSession
        isBackingUp = true
        defer { isBackingUp = false }
        let prepared: LedgerVault.PreparedRestore
        do throws(BackupError) {
            prepared = try await vault.prepareRestore(from: request.url, password: password)
        } catch {
            return Self.message(for: error)
        }
        guard !isStale(session) else {
            vault.discard(prepared)
            return String(localized: "MFN wurde gesperrt.")
        }
        let open = backupStore
        if let open {
            // Nothing may write between here and the lock below.
            await open.close()
            guard !isStale(session) else {
                vault.discard(prepared)
                return String(localized: "MFN wurde gesperrt.")
            }
        }
        let date = request.info.createdAt.formatted(date: .long, time: .shortened)
        let result: LedgerVault.RestoreResult
        do throws(BackupError) {
            result = try vault.commitRestore(prepared)
        } catch {
            vault.discard(prepared)
            Log.logger("backup").error("Restore failed: \(String(describing: error), privacy: .private)")
            restoreRequest = nil
            backupNotice = BackupNotice(title: String(localized: "Die Sicherung konnte nicht wiederhergestellt werden."),
                                        message: String(localized: "Deine bisherigen Daten sind unverändert.") + " " + Self.message(for: error))
            // The database was closed for the swap: the next unlock opens it again.
            if open != nil { lock.lock() }
            return nil
        }
        // Order and hidden accounts refer to this database's banks and accounts.
        if let settings = prepared.settings { applyBackupSettings(settings) }
        var message = String(localized: "Die Daten aus der Sicherung vom \(date) sind jetzt aktiv.")
        if result.previousDatabase != nil {
            message += " " + String(localized: "Die bisherigen Daten liegen verschlüsselt als Kopie im Datenordner; du kannst sie löschen, wenn alles stimmt.")
        }
        if result.keyNotStored != nil {
            message += " " + String(localized: "Der Schlüssel ließ sich nicht im Schlüsselbund speichern: MFN fragt beim Entsperren nach dem Datenbank-Passwort.")
        }
        message += " " + String(localized: "Bankzugänge sind nicht Teil der Sicherung: auf einem anderen Mac meldest du dich bei jeder Bank einmal neu an.")
        restoreRequest = nil
        if open != nil {
            lock.lock()
            message += " " + String(localized: "MFN ist gesperrt; entsperre, um weiterzuarbeiten.")
        } else {
            await openRestoredDatabase(password: password)
        }
        backupNotice = BackupNotice(title: String(localized: "Sicherung wiederhergestellt"), message: message, previous: result.previousDatabase)
        return nil
    }

    // MARK: - Settings that belong to the data

    /// What MFN keeps in its preferences about the banks and accounts of this database: without
    /// it a restored ledger shows hidden accounts again and loses the sidebar order.
    struct LedgerSettings: Codable, Equatable {
        var sidebarOrder = DisplayOrder()
        var hiddenAccounts: [String] = []
        var excludedFromTotals: [String] = []
        var collapsedBanks: [String] = []
        var hiddenRecurring: [String] = []
    }

    var ledgerSettings: LedgerSettings {
        LedgerSettings(sidebarOrder: displayOrder,
                       hiddenAccounts: hiddenAccountIDs.map(\.rawValue).sorted(),
                       excludedFromTotals: excludedFromTotals.map(\.rawValue).sorted(),
                       collapsedBanks: collapsedConnections.map(\.rawValue).sorted(),
                       hiddenRecurring: hiddenRecurring.sorted())
    }

    private var backupSettings: Data? { try? JSONEncoder().encode(ledgerSettings) }

    func apply(_ settings: LedgerSettings) {
        displayOrder = settings.sidebarOrder
        hiddenAccountIDs = Set(settings.hiddenAccounts.map(AccountID.init(rawValue:)))
        excludedFromTotals = Set(settings.excludedFromTotals.map(AccountID.init(rawValue:)))
        collapsedConnections = Set(settings.collapsedBanks.map(ConnectionID.init(rawValue:)))
        hiddenRecurring = Set(settings.hiddenRecurring)
    }

    private func applyBackupSettings(_ data: Data) {
        guard let settings = try? JSONDecoder().decode(LedgerSettings.self, from: data) else { return }
        apply(settings)
    }

    // MARK: - Automatic backup

    /// Writes a backup into the chosen folder if one is due, and removes the oldest beyond the
    /// number to keep. Called after unlocking and after every successful sync.
    func runAutoBackupIfDue(force: Bool = false) {
        let auto = autoBackup
        guard !isDemo, !lock.isLocked, let vault = backupVault, let store = backupStore else { return }
        guard force ? (auto.hasFolder && !auto.isRunning) : auto.isDue() else { return }
        guard let folder = auto.openFolder() else {
            auto.finish(failure: String(localized: "Der Ordner für die Sicherung ist nicht erreichbar. Wähle ihn in den Einstellungen neu."))
            return
        }
        auto.begin()
        let keep = auto.keep
        let version = Self.appVersion
        let settings = backupSettings
        Task {
            let now = Date()
            let outcome: Result<Void, BackupError> = await Task.detached(priority: .utility) {
                defer { folder.stopAccessingSecurityScopedResource() }
                do throws(BackupError) {
                    _ = try await vault.writeBackup(of: store, to: folder.appendingPathComponent(LedgerBackup.fileName(at: now, automatic: true)),
                                                    appVersion: version, settings: settings, now: now)
                } catch {
                    return .failure(error)
                }
                // Only after a new one is written, and only files named like MFN's backups.
                for old in LedgerBackup.surplus(in: folder, keep: keep) { try? FileManager.default.removeItem(at: old) }
                return .success(())
            }.value
            switch outcome {
            case .success:
                auto.finish(success: now)
            case .failure(.vault(.store(.closed))):
                // Locked meanwhile: no error, the next unlock tries again.
                auto.finish(failure: nil)
            case let .failure(error):
                Log.logger("backup").error("Automatic backup failed: \(String(describing: error), privacy: .private)")
                auto.finish(failure: Self.message(for: error))
            }
        }
    }

    /// Settings → Sicherung: the folder for automatic backups.
    func chooseAutoBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Ordner für automatische Sicherungen")
        panel.prompt = String(localized: "Auswählen")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if autoBackup.setFolder(url) {
                runAutoBackupIfDue()
            } else {
                backupNotice = BackupNotice(title: String(localized: "Dieser Ordner lässt sich nicht verwenden."),
                                            message: String(localized: "MFN konnte sich den Ordner nicht merken. Wähle einen anderen."))
            }
        }
    }

    static func message(for error: BackupError) -> String {
        switch error {
        case .notABackup:
            String(localized: "Das ist keine Sicherung von MoneyForNothing.")
        case .unsupportedFormat, .newerSchema:
            String(localized: "Diese Sicherung stammt aus einer neueren Version von MFN. Aktualisiere MFN und versuche es erneut.")
        case .damaged:
            String(localized: "Die Sicherung ist unvollständig oder beschädigt.")
        case .wrongPassword:
            String(localized: "Das Passwort ist falsch. Gebraucht wird das Datenbank-Passwort aus der Zeit, als die Sicherung erstellt wurde.")
        case .vault(.store(.closed)):
            String(localized: "MFN wurde gesperrt.")
        case .vault:
            String(localized: "Die Datenbank ließ sich nicht lesen oder schreiben.")
        case let .file(detail):
            String(localized: "Die Datei ließ sich nicht lesen oder schreiben. \(detail)")
        }
    }
}
