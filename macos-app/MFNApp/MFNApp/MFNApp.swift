import MFNCore
import MFNStore
import SwiftUI

@main
struct MFNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var updater = AppUpdater()
    @AppStorage(Preferences.showMenuBarExtra) private var showMenuBarExtra = false
    @AppStorage(Preferences.menuBarOnly) private var menuBarOnly = false
    @AppStorage(Preferences.menuBarIconStyle) private var menuBarIconStyle = MenuBarIconStyle.appIcon

    init() {
        Preferences.registerDefaults()
        let model = AppModel.make()
        _model = State(initialValue: model)
        AppDelegate.lockForMenuBar = { model.lock.lock() }
        #if DEBUG
        // Shows the lock screen's "newer database" state without touching a database.
        if ProcessInfo.processInfo.environment["MFN_SHOW_NEWER_SCHEMA"] != nil {
            model.lock.lock(problem: AppModel.problem(for: StoreError.newerSchema(found: 11, supported: 10)))
        }
        #endif
    }

    var body: some Scene {
        // One main window (`Window`, not `WindowGroup`): "MFN öffnen" in the menu bar panel
        // brings it back instead of opening another one.
        Window(model.profile.badge.map { "MoneyForNothing – \($0)" } ?? "MoneyForNothing", id: MainWindow.id) {
            RootView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 1000, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
                CheckForUpdatesCommand(updater: updater)
            }
            CommandGroup(replacing: .importExport) {
                // ⇧⌘I: ⌘I is unused, ⌥⌘I belongs to "Details einblenden".
                Button("Umsätze aus CSV importieren …") { model.beginCSVImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!model.canImportCSV)
                Button("Umsätze als CSV exportieren …") { model.exportCSV() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExportCSV)
            }
            CommandMenu("Konten") {
                Button("Bank hinzufügen …") { model.showBankSetup() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.canAddBank)
                // v10: account without a bank connection, transactions from CSV only.
                Button("Konto ohne Anbindung anlegen …") { model.showManualAccountSetup() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(!model.canAddBank || model.bankSetup != nil)
                Divider()
                Button("Alle Konten abgleichen") { model.syncAll() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.lock.isLocked)
                Button("Dieses Konto abgleichen") { model.syncSelectedConnection() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    // Accounts without a bank connection have nothing to sync.
                    .disabled(!model.canSyncSelectedConnection)
                // Bank of the selected account (CLAUDE.md §6: every command has a menu item).
                Button("Bank einklappen") { model.setSelectedBankCollapsed(true) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(model.lock.isLocked || model.selectedBankCollapsed != false)
                Button("Bank ausklappen") { model.setSelectedBankCollapsed(false) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(model.lock.isLocked || model.selectedBankCollapsed != true)
                Button("Prognose und Planung …") {
                    if let account = model.forecastAccount { model.showForecast(for: account) }
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(model.forecastAccount == nil)
                if DeveloperMode.isAvailable {
                    // Same report as the context menu of a FinTS bank.
                    Button("Zusammenführen prüfen …") { model.mergeCheck = model.mergeCandidate }
                        .keyboardShortcut("m", modifiers: [.command, .option, .shift])
                        .disabled(model.mergeCandidate == nil)
                }
                Divider()
                Button("Übersicht anzeigen") { model.selection = .overview }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(model.lock.isLocked)
                Button("Zu prüfen anzeigen") { model.selection = .review }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(model.lock.isLocked)
                Button("Vorgemerkte anzeigen") { model.selection = .pending }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(model.lock.isLocked)
                Button(model.showCancelled ? "Stornos ausblenden" : "Stornos einblenden") { model.showCancelled.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Umsätze durchsuchen") {
                    // The overview and depots have no search field: search all transactions instead.
                    let isDepot = if case let .account(id)? = model.selection { model.account(id)?.type == .depot } else { false }
                    if model.selection == .overview || model.selection == nil || isDepot { model.selection = .allAccounts }
                    model.searchFocusRequested = true
                }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.lock.isLocked)
                // ⌃⌘I: ⇧⌘I is the import itself, ⌥⌘I the details.
                Toggle("Nur importierte Umsätze", isOn: Binding(
                    get: { model.ledgerQuery.onlyImported }, set: { _ in model.toggleImportedFilter() }
                ))
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(model.lock.isLocked)
                Button("Filter zurücksetzen") {
                    model.ledgerQuery.resetFilters()
                    model.ledgerQuery.text = ""
                }
                .disabled(model.lock.isLocked || !(model.ledgerQuery.isFiltering))
            }
            CommandMenu("Umsatz") {
                Button("Kategorie zuweisen …") { model.showCategoryPicker() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!model.canCategorize || model.selectedTransactionIDs.isEmpty)
                Button("Regel erstellen …") { model.showRuleEditor() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!model.canCreateRule)
                Button("Vorschlag übernehmen") { model.acceptSuggestions() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canAcceptSuggestion)
                Divider()
                // Only CSV-imported rows; bank data cannot be removed.
                Button("Importierte Umsätze entfernen …") { model.requestRemoveSelectedImports() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!model.canRemoveSelectedImports)
                Button("Alle importierten Umsätze des Kontos entfernen …") {
                    if let account = model.importRemovalAccount { model.requestRemoveImports(of: account) }
                }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(model.importRemovalAccount == nil)
                Divider()
                Button("Kategorien einrichten …") { model.showCategorySetup() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .disabled(!model.canShowCategorySetup)
            }
            // The automatic "Seitenleiste ausblenden" item claims ⌥⌘S, which belongs to Stornos
            // (CLAUDE.md §6). The sidebar toggles with ⌘B instead.
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(after: .toolbar) {
                Divider()
                Button(model.columnVisibility == .detailOnly ? "Seitenleiste einblenden" : "Seitenleiste ausblenden") { model.toggleSidebar() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(model.lock.isLocked)
                AppearancePicker(model: model)
                Button(model.showsInspector ? "Details ausblenden" : "Details einblenden") { model.showsInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .disabled(model.lock.isLocked)
                Button(model.hideAmounts ? "Beträge einblenden" : "Beträge ausblenden") { model.hideAmounts.toggle() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appSettings) {
                // "Bank hinzufügen …" (⇧⌘N) lives in the "Konten" menu only: one shortcut, one item.
                Button("Sperren") { model.lock.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(model.lock.isLocked)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Über MoneyForNothing", id: AboutView.windowID) {
            AboutView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        // Without the menu bar icon, "Nur in der Menüleiste" would leave MFN unreachable.
        MenuBarExtra(isInserted: Binding(get: { showMenuBarExtra || menuBarOnly }, set: { showMenuBarExtra = $0 })) {
            MenuBarPanel()
                .environment(model)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: model.appIcon, style: menuBarIconStyle))
                .accessibilityLabel("MoneyForNothing")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Applies the saved Dock icon once AppKit has finished launching: set earlier (while SwiftUI
/// builds the first window), macOS resets the Dock tile to the bundle icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Locks MFN when ⌘Q only closes it into the menu bar (set by `MFNApp`).
    static var lockForMenuBar: (@MainActor () -> Void)?
    /// Set by "Beenden" in the menu bar panel: quit for real.
    static var quitRequested = false

    /// With the menu bar icon on, ⌘Q closes the window into the menu bar instead of quitting: the
    /// window closes, MFN locks and leaves the Dock. Quits for real via "Beenden" in the panel and
    /// whenever macOS asks (logout, shutdown, AppleScript `quit` – a `kAEQuitApplication` event).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let defaults = UserDefaults.standard
        let menuBarShown = defaults.bool(forKey: Preferences.showMenuBarExtra) || defaults.bool(forKey: Preferences.menuBarOnly)
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?.eventID == kAEQuitApplication
        guard menuBarShown, !Self.quitRequested, !systemQuit else { return .terminateNow }
        for window in sender.windows where window.isVisible && window.canBecomeMain {
            window.close()
        }
        Self.lockForMenuBar?()
        sender.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockPresence.apply()
        let choice = UserDefaults.standard.string(forKey: AppIconChoice.storageKey).flatMap(AppIconChoice.init) ?? .dark
        choice.apply()
        // Once more after the first window is up; SwiftUI may touch the Dock tile while showing it.
        DispatchQueue.main.async { choice.apply() }
    }
}
