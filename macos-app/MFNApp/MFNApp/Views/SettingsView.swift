import AppKit
import MFNCore
import MFNStore
import SwiftUI

/// Settings window (⌘,). Only options that actually change behaviour; fixed safety rules
/// (CLAUDE.md §1, §6) are shown as information, not as switches.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Allgemein", systemImage: "gearshape") { GeneralSettings() }
            Tab("Abgleich", systemImage: "arrow.triangle.2.circlepath") { SyncSettings() }
            Tab("Banken", systemImage: "building.columns") { BankSettings() }
            Tab("Kategorien", systemImage: "tag") { CategorySettings() }
            Tab("Sicherheit", systemImage: "lock") { SecuritySettings() }
            Tab("Sicherung", systemImage: "externaldrive") { BackupSettings() }
            Tab("MCP", systemImage: "point.3.connected.trianglepath.dotted") { AssistantSettings() }
            if DeveloperMode.isAvailable {
                Tab("Entwickler", systemImage: "hammer") { DeveloperSettings() }
            }
            Tab("Über", systemImage: "info.circle") { AboutView().frame(maxWidth: .infinity) }
        }
        // Wide enough for every tab (up to nine with "Entwickler") without the overflow menu.
        .frame(width: 720)
        .frame(minHeight: 460, idealHeight: 560)
    }
}

// MARK: - Allgemein

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.hideAmountsOnUnlock) private var hideAmountsOnUnlock = false
    @AppStorage(Preferences.showCancelledByDefault) private var showCancelledByDefault = false
    @AppStorage(Preferences.loadBankIcons) private var loadBankIcons = true
    @AppStorage(Preferences.showBankIcons) private var showBankIcons = true
    @AppStorage(Preferences.showTreeLines) private var showTreeLines = true
    @AppStorage(Preferences.showMenuBarExtra) private var showMenuBarExtra = false
    @AppStorage(Preferences.menuBarOnly) private var menuBarOnly = false
    @AppStorage(Preferences.menuBarIconStyle) private var menuBarIconStyle = MenuBarIconStyle.appIcon
    @AppStorage(Preferences.negativeRedSidebar) private var negativeRedSidebar = false
    @AppStorage(Preferences.negativeRedLedger) private var negativeRedLedger = false
    @AppStorage(Preferences.negativeRedMenuBar) private var negativeRedMenuBar = false

    var body: some View {
        Form {
            Section {
                AppearancePicker(model: model)
                    .pickerStyle(.segmented)
            } footer: {
                Text("„Automatisch“ folgt der Einstellung in den Systemeinstellungen.")
            }
            Section {
                AppIconPicker()
            } header: {
                Text("App-Symbol")
            } footer: {
                Text("„Schwarz“ ist das Symbol der App. Die anderen ersetzen das Dock-Symbol, solange MFN läuft; im Finder bleibt das schwarze sichtbar.")
            }
            Section {
                Toggle("Symbol in der Menüleiste anzeigen", isOn: Binding(get: { showMenuBarExtra || menuBarOnly }, set: { showMenuBarExtra = $0 }))
                    .disabled(menuBarOnly)
                Toggle("Nur in der Menüleiste (kein Dock-Symbol)", isOn: $menuBarOnly)
                    .onChange(of: menuBarOnly) { DockPresence.apply() }
                Picker("Symbol", selection: $menuBarIconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Label {
                            Text(style.title)
                        } icon: {
                            Image(nsImage: MenuBarIcon.image(for: model.appIcon, style: style))
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!(showMenuBarExtra || menuBarOnly))
            } header: {
                Text("Menüleiste")
            } footer: {
                Text("Ein Klick auf das Symbol zeigt Gesamtsaldo, Banken und Vorgemerktes. Beträge erscheinen nur dort, nie in der Menüleiste selbst.")
            }
            Section {
                Toggle("Seitenleiste", isOn: $negativeRedSidebar)
                Toggle("Umsatzliste und Kontokopf", isOn: $negativeRedLedger)
                Toggle("Menüleiste", isOn: $negativeRedMenuBar)
            } header: {
                Text("Negative Beträge rot hervorheben")
            } footer: {
                Text("Normal sind Ausgaben neutral und Rot nur für Fehler. Das Minuszeichen bleibt immer sichtbar.")
            }
            Section("Umsatzliste") {
                Toggle("Beträge nach dem Entsperren ausblenden", isOn: $hideAmountsOnUnlock)
                Toggle("Stornierte Umsätze standardmäßig anzeigen", isOn: $showCancelledByDefault)
            }
            Section {
                Toggle("Bank-Symbole anzeigen", isOn: $showBankIcons)
                Toggle("Bank-Symbole von den Websites laden", isOn: $loadBankIcons)
                    .onChange(of: loadBankIcons) { model.loadBankIcons() }
                    .disabled(!showBankIcons)
                Toggle("Linien zwischen Bank und Konten", isOn: $showTreeLines)
            } header: {
                Text("Seitenleiste")
            } footer: {
                Text("Die Symbole kommen als Favicon direkt von der Website der jeweiligen Bank, ohne Cookies. Für Banken über YAXI kommt das Logo von YAXIs Logo-Dienst (logos.yaxi.tech). Ohne Laden zeigt MFN farbige Kürzel.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Abgleich

private struct SyncSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.syncOnUnlock) private var syncOnUnlock = true
    @AppStorage(Preferences.autoSync) private var autoSync = true
    @AppStorage(Preferences.autoSyncMinutes) private var autoSyncMinutes = 30

    var body: some View {
        Form {
            Section {
                Toggle("Nach dem Entsperren alle Konten abgleichen", isOn: $syncOnUnlock)
                Toggle("Automatisch abgleichen", isOn: $autoSync)
                Picker("Intervall", selection: $autoSyncMinutes) {
                    ForEach(Preferences.autoSyncChoices, id: \.self) { minutes in
                        Text(Self.title(minutes)).tag(minutes)
                    }
                }
                .disabled(!autoSync)
            } header: {
                Text("Automatischer Abgleich")
            } footer: {
                Text("Nur solange MFN entsperrt ist. Mindestens \(Int(SyncEngine.minimumAutomaticInterval / 60)) Minuten zwischen zwei Abrufen je Bank. Banken mit Freigabe (z. B. DKB) können dabei nach einer Bestätigung fragen. Nach einem Anmeldefehler wird nie automatisch erneut versucht (Sperrgefahr), nach \(SyncEngine.maximumConsecutiveFailures) Fehlern in Folge pausiert die Bank.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: autoSync) { model.scheduleAutoSync() }
        .onChange(of: autoSyncMinutes) { model.scheduleAutoSync() }
        .onAppear {
            // Older or hand-edited defaults: never below the minimum.
            if !Preferences.autoSyncChoices.contains(autoSyncMinutes) {
                autoSyncMinutes = Preferences.autoSyncChoices.first { $0 >= autoSyncMinutes } ?? Preferences.autoSyncChoices[0]
            }
        }
    }

    static func title(_ minutes: Int) -> LocalizedStringResource {
        if minutes < 60 { return "alle \(minutes) Minuten" }
        if minutes == 60 { return "jede Stunde" }
        return "alle \(minutes / 60) Stunden"
    }
}

// MARK: - Banken

private struct BankSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editingCredentials: Connection?
    @State private var removing: Connection?
    @State private var renaming: RenameTarget?

    var body: some View {
        Form {
            Section {
                if model.lock.isLocked {
                    Text("MFN entsperren, um die Banken zu sehen.")
                        .foregroundStyle(.secondary)
                } else if model.orderedConnections.isEmpty {
                    Text("Noch keine Bank. „Bank hinzufügen …“ im Menü „MoneyForNothing“ oder „Konten“ (⇧⌘N).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.orderedConnections) { connection in
                        ConnectionSettingsRow(connection: connection, editingCredentials: $editingCredentials, removing: $removing, renaming: $renaming)
                    }
                }
            } footer: {
                Text(model.isDemo
                     ? "Demo mit Beispielbanken (MFN_DEMO). Echte Banken lassen sich nur ohne Demo hinzufügen."
                     : "Zugangsdaten und Sitzungen liegen nur im Schlüsselbund dieses Macs. „Bank entfernen“ löscht Konten, Umsätze, Zugangsdaten und Sitzung.")
            }
            if !model.isDemo {
                Button("Bank hinzufügen …") { model.showBankSetup() }
                    .disabled(!model.canAddBank)
                YAXIKeySettings()
            }
        }
        .formStyle(.grouped)
        .bankActions(editing: $editingCredentials, removing: $removing)
        .renameSheet($renaming)
    }
}

private struct ConnectionSettingsRow: View {
    let connection: Connection
    @Binding var editingCredentials: Connection?
    @Binding var removing: Connection?
    @Binding var renaming: RenameTarget?
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.syncState(connection.id)
        HStack(spacing: 10) {
            BankBadge(connection: connection, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                Text(detail(state))
                    .font(.callout)
                    .foregroundStyle(isError(state) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            Spacer()
            if connection.connectorID.hasConnector {
                Button("Abgleichen") { model.syncConnection(connection.id) }
                    .disabled(state.phase == .syncing)
            }
            if !model.isDemo {
                Menu {
                    AccountVisibilityMenu(connection: connection.id)
                    Divider()
                    Button("Umbenennen …") { renaming = .bank(connection) }
                    if connection.isManual {
                        Divider()
                        Button("Konto entfernen …", role: .destructive) { removing = connection }
                    } else {
                        Button("Zugangsdaten ändern …") { editingCredentials = connection }
                        Divider()
                        Button("Bank entfernen …", role: .destructive) { removing = connection }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Weitere Aktionen für \(connection.displayName)")
            }
        }
    }

    private func detail(_ state: SyncState) -> String {
        let all = model.ledger.accounts(of: connection.id)
        let accounts = all.count
        let hidden = all.count(where: { model.isHidden($0.id) })
        let synced: String = switch state.phase {
        case .syncing: String(localized: "Abgleich läuft …")
        case .waitingForApproval: String(localized: "wartet auf Freigabe")
        case let .failed(error): error.description
        case let .storeFailed(message): String(localized: "Speichern fehlgeschlagen: \(message)")
        case .idle: state.lastSuccess.map { String(localized: "abgeglichen \(DayFormat.syncTime($0))") } ?? String(localized: "noch nicht abgeglichen")
        }
        let status = connection.isManual ? String(localized: "ohne Anbindung, Umsätze per CSV-Import")
            : connection.connectorID == .yaxi ? String(localized: "über YAXI · \(synced)") : synced
        let accountsText = accounts == 1 ? String(localized: "\(accounts) Konto") : String(localized: "\(accounts) Konten")
        let countText = hidden > 0 ? String(localized: "\(accountsText) (\(hidden) ausgeblendet)") : accountsText
        return String(localized: "\(countText) · \(status)")
    }

    private func isError(_ state: SyncState) -> Bool {
        switch state.phase {
        case .failed, .storeFailed: true
        case .idle, .syncing, .waitingForApproval: false
        }
    }
}

// MARK: - Sicherheit

private struct SecuritySettings: View {
    @Environment(AppModel.self) private var model
    @State private var changingPassword = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Beim Start") { Text("Touch ID oder Passwort") }
                LabeledContent("Bei Bildschirmsperre") { Text("sperren") }
                LabeledContent("Nach Inaktivität") { Text("\(Int(AppLock.idleTimeout.components.seconds / 60)) Minuten") }
                Button("Jetzt sperren") { model.lock.lock() }
                    .disabled(model.lock.isLocked)
            } header: {
                Text("App-Sperre")
            } footer: {
                Text("Beim Sperren wird die Datenbank geschlossen und der Schlüssel aus dem Speicher gelöscht.")
            }
            Section {
                LabeledContent("Verschlüsselung", value: "SQLCipher, AES-256")
                LabeledContent("Speicherort") {
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.databaseURLForDisplay])
                    }
                }
                Button("Datenbank-Passwort ändern …") { changingPassword = true }
                    .disabled(!model.canChangePassword)
            } header: {
                Text("Datenbank")
            } footer: {
                Text("Mit dem Passwort lässt sich eine kopierte Datenbank auf einem anderen Mac öffnen. Auf diesem Mac genügt Touch ID.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $changingPassword) {
            ChangePasswordSheet()
        }
    }
}

private struct ChangePasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var old = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var error: String?
    @State private var isWorking = false

    private var canSubmit: Bool {
        !old.isEmpty && new.count >= LedgerVault.minimumPasswordLength && new == repeated && !isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Datenbank-Passwort ändern")
                .font(.headline)
            Form {
                SecureField("Bisheriges Passwort", text: $old)
                SecureField("Neues Passwort", text: $new)
                SecureField("Wiederholen", text: $repeated)
            }
            Text(hint)
                .font(.callout)
                .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Ändern", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var hint: String {
        if let error { return error }
        if !repeated.isEmpty, new != repeated { return String(localized: "Die Passwörter stimmen nicht überein.") }
        return String(localized: "Mindestens \(LedgerVault.minimumPasswordLength) Zeichen. Nur die Datei ledger.key wird neu geschrieben.")
    }

    private func submit() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do throws(VaultError) {
                try await model.changePassword(from: old, to: new)
                dismiss()
            } catch {
                self.error = AppModel.message(forPasswordChange: error)
            }
        }
    }
}

// MARK: - Entwickler

/// Debug builds, or `defaults write xyz.ahef.mfn developerMode -bool YES`. Demo and test profile
/// have their own databases and keychain keys: the real data is never touched.
private struct DeveloperSettings: View {
    @Environment(AppModel.self) private var model
    @State private var choice: LaunchProfile = .live
    @State private var confirmsReset = false
    @State private var error: String?
    @State private var assistantReset = false

    var body: some View {
        Form {
            Section {
                Picker("Daten", selection: $choice) {
                    ForEach(LaunchProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.radioGroup)
                HStack {
                    Spacer()
                    Button("Neu starten") { run { try await model.switchProfile(to: choice) } }
                        .disabled(choice == model.profile || model.lock.isLocked)
                }
            } header: {
                Text("Beim Start öffnen")
            } footer: {
                Text("Aktuell: \(model.profile.title). „Frische Installation“ startet mit leerem Testprofil wie beim ersten Start: Passwort festlegen, Bank hinzufügen, Kategorien einrichten. Echte Banken lassen sich dort wirklich anmelden.")
            }

            Section {
                if model.profile == .fresh {
                    Button("Testprofil leeren und neu starten …") { confirmsReset = true }
                        .disabled(model.lock.isLocked)
                } else {
                    Button("Ins Testprofil wechseln") { run { try await model.switchProfile(to: .fresh) } }
                        .disabled(model.lock.isLocked)
                }
                HStack {
                    Button("Kategorien-Assistent wieder anbieten") {
                        UserDefaults.standard.removeObject(forKey: model.setupOfferedKey)
                        assistantReset = true
                        AccessibilityNotification.Announcement(String(localized: "Der Kategorien-Assistent wird nach dem nächsten Abgleich wieder angeboten.")).post()
                    }
                    if assistantReset {
                        Label("Wird nach dem nächsten Abgleich angeboten", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Testprofil")
            } footer: {
                Text(model.lock.isLocked
                     ? "Zum Wechseln oder Leeren zuerst entsperren: MFN muss wissen, welche Zugangsdaten zum Testprofil gehören."
                     : "Leeren löscht Datenbank, Schlüssel, Zugangsdaten und Web-Daten der Testbanken – nur im Testprofil.")
            }
        }
        .formStyle(.grouped)
        .onAppear { choice = model.profile }
        .confirmationDialog("Testprofil leeren?", isPresented: $confirmsReset) {
            Button("Leeren und neu starten", role: .destructive) {
                run { try await model.resetTestProfile() }
            }
        } message: {
            Text("Alle Banken, Umsätze und Zugangsdaten des Testprofils werden gelöscht. Die echten Daten bleiben unverändert.")
        }
        .onChange(of: error) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    /// Restart actions: a failure (no restart) shows here and is announced.
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
