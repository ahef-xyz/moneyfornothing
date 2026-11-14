import AppKit
import Foundation
import MFNCore

/// `UserDefaults` keys for Settings. Nothing sensitive lives here (credentials → keychain).
enum Preferences {
    static let hideAmountsOnUnlock = "hideAmountsOnUnlock"
    static let showCancelledByDefault = "showCancelledByDefault"
    static let syncOnUnlock = "syncOnUnlock"
    static let loadBankIcons = "loadBankIcons"
    static let showBankIcons = "showBankIcons"
    static let showTreeLines = "showTreeLines"
    static let showMenuBarExtra = "showMenuBarExtra"
    static let menuBarOnly = "menuBarOnly"
    static let menuBarIconStyle = "menuBarIconStyle"
    /// Negative amounts in red, per area (off by default: CLAUDE.md §6 keeps red for errors).
    static let negativeRedSidebar = "negativeRedSidebar"
    static let negativeRedLedger = "negativeRedLedger"
    static let negativeRedMenuBar = "negativeRedMenuBar"
    static let autoSync = "autoSync"
    static let autoSyncMinutes = "autoSyncMinutes"

    /// Choices for the automatic sync interval. Never below the engine's minimum
    /// (CLAUDE.md §1: Abruf-Intervall ≥ 15 min).
    static let autoSyncChoices = [15, 30, 60, 120, 240]

    static var autoSyncInterval: Duration {
        let minimum = Int(SyncEngine.minimumAutomaticInterval / 60)
        return .seconds(max(UserDefaults.standard.integer(forKey: autoSyncMinutes), minimum) * 60)
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            hideAmountsOnUnlock: false,
            showCancelledByDefault: false,
            syncOnUnlock: true,
            loadBankIcons: true,
            showBankIcons: true,
            showTreeLines: true,
            showMenuBarExtra: false,
            menuBarOnly: false,
            menuBarIconStyle: MenuBarIconStyle.appIcon.rawValue,
            negativeRedSidebar: false,
            negativeRedLedger: false,
            negativeRedMenuBar: false,
            autoSync: true,
            autoSyncMinutes: 30,
            AppearanceMode.storageKey: AppearanceMode.system.rawValue,
            AppIconChoice.storageKey: AppIconChoice.dark.rawValue,
        ])
    }
}

/// Dock icon on or off ("Nur in der Menüleiste"). Needs `NSApp`, so it runs after launch.
@MainActor
enum DockPresence {
    /// `force`: also restore the Dock icon after ⌘Q closed MFN into the menu bar.
    static func apply(force: Bool = false) {
        guard let app = NSApp else { return }
        let menuBarOnly = UserDefaults.standard.bool(forKey: Preferences.menuBarOnly)
        let policy: NSApplication.ActivationPolicy = menuBarOnly ? .accessory : .regular
        guard app.activationPolicy() != policy || force else { return }
        app.setActivationPolicy(policy)
        if !menuBarOnly {
            // Back in the Dock: show the chosen icon there again.
            (UserDefaults.standard.string(forKey: AppIconChoice.storageKey).flatMap(AppIconChoice.init) ?? .dark).apply()
        }
    }
}

/// What the menu bar shows: the app icon in colour, or only the pick as template image
/// (tinted by macOS like the system icons).
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case appIcon
    case pick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appIcon: "App-Symbol"
        case .pick: "Nur Plektrum"
        }
    }
}
