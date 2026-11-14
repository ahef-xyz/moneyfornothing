import AppKit
import Foundation
import MFNStore
import Security

/// Which data MFN opens at launch. `live` is the user's real ledger; the others are separate
/// databases with their own keychain key, so testing never touches the real data.
enum LaunchProfile: String, CaseIterable, Identifiable {
    /// The real ledger (`MFN-Live/`).
    case live
    /// Five mock banks with generated bookings (`MFN/`, the former `MFN_DEMO=1`).
    case demo
    /// Empty test ledger (`MFN-Test/`) with real connectors: behaves like a fresh install until
    /// it is reset again (Settings → Entwickler).
    case fresh

    static let storageKey = "launchProfile"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Echte Daten"
        case .demo: "Demo mit Beispielbanken"
        case .fresh: "Frische Installation (Test)"
        }
    }

    /// Short marker shown in the window and on the lock screen; `nil` for the real data.
    var badge: String? {
        switch self {
        case .live: nil
        case .demo: "Demo"
        case .fresh: "Testprofil"
        }
    }

    var directory: String {
        switch self {
        case .live: "MFN-Live"
        case .demo: "MFN"
        case .fresh: "MFN-Test"
        }
    }

    /// Keychain account of the database key (`KeychainDatabaseKey`).
    var keyAccount: String {
        switch self {
        case .live: "ledger-key-live-v1"
        case .demo: KeychainDatabaseKey.defaultAccount
        case .fresh: "ledger-key-test-v1"
        }
    }

    /// UserDefaults key of a per-profile setting (the real data keeps the plain key).
    func scoped(_ key: String) -> String {
        switch self {
        case .live: key
        case .demo: key + ".demo"
        case .fresh: key + ".test"
        }
    }

    /// Profile of this launch: the demo with `MFN_DEMO`, else the stored choice. Fixed per launch,
    /// so per-profile UserDefaults keys can be read before the model exists.
    static let launched: LaunchProfile = {
        switch ProcessInfo.processInfo.environment["MFN_DEMO"]?.lowercased() {
        case nil, "", "0", "false", "no": stored
        default: .demo
        }
    }()

    /// Profile chosen in Settings → Entwickler (only honoured while developer mode is available).
    static var stored: LaunchProfile {
        guard DeveloperMode.isAvailable else { return .live }
        return UserDefaults.standard.string(forKey: storageKey).flatMap(LaunchProfile.init) ?? .live
    }
}

/// Developer mode: debug builds only. Release builds never offer it, so the same real bank is
/// never logged into from two profiles with separate sync histories (CLAUDE.md §1).
enum DeveloperMode {
    static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    enum Failure: Error, LocalizedError {
        case relaunch
        case keychain(OSStatus)
        case files

        var errorDescription: String? {
            switch self {
            case .relaunch: "MFN konnte nicht neu gestartet werden. Bitte MFN selbst neu öffnen."
            case let .keychain(status): "Der Schlüssel des Testprofils ließ sich nicht aus dem Schlüsselbund löschen (Code \(status))."
            case .files: "Der Ordner des Testprofils ließ sich nicht löschen."
            }
        }
    }

    /// Starts a new instance of MFN and quits this one (the profile is read at launch). If the
    /// new instance does not start, this one stays open and the error is returned.
    @MainActor
    static func relaunch() async throws(Failure) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        } catch {
            throw .relaunch
        }
        AppDelegate.quitRequested = true
        NSApp.terminate(nil)
    }

    /// Deletes the test profile's keychain key, then its database folder and its UI settings.
    /// Credentials of its connections are removed by the caller first (they need the open
    /// ledger to be known). Key first: a failure leaves no key pointing to a deleted database.
    static func wipeTestProfile() throws(Failure) {
        let profile = LaunchProfile.fresh
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainDatabaseKey.defaultService,
            kSecAttrAccount as String: profile.keyAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent(profile.directory, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            throw .files
        }
        for key in AppModel.profileScopedKeys {
            UserDefaults.standard.removeObject(forKey: profile.scoped(key))
        }
    }
}
