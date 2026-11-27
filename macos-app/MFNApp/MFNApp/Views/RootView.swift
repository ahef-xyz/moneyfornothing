import MFNCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.lock.isLocked {
                LockView()
            } else if let prompt = model.vaultPrompt {
                VaultPasswordView(prompt: prompt)
            } else {
                MainView()
            }
        }
        .modifier(BackupPresentation())
        // First application needs `NSApp`, which does not exist yet when the model is created.
        .onAppear {
            model.appearance.apply()
            model.appIcon.apply()
        }
        #if DEBUG
        .task(id: model.lock.isLocked) {
            // Website screenshots (MFN_SHOT_*), demo only; after unlock so the main window exists.
            try? await Task.sleep(for: .seconds(1))
            ScreenshotMode.start(with: model)
        }
        #endif
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppUpdater.self) private var updater: AppUpdater?
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.openURL) private var openURL
    private let usesTouchID = AppLock.biometryAvailable

    var body: some View {
        let problem = model.lock.lastError
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(nsImage: model.appIcon.image)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(problem == nil ? String(localized: "MoneyForNothing ist gesperrt") : String(localized: "MoneyForNothing lässt sich nicht öffnen"))
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(problem?.message ?? causeText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let hint = problem?.hint {
                        Text(hint)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 420)
                if problem?.action == .update {
                    updateButtons
                } else {
                    unlockButton(title: problem == nil ? nil : String(localized: "Erneut versuchen"))
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 6)
                    if problem == nil {
                        Text(usesTouchID ? String(localized: "Oder mit dem Passwort deines Macs.") : String(localized: "Mit dem Passwort deines Macs."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = problem?.detail {
                    // Technical detail for a bug report: small, selectable, never in red.
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 420)
                        .padding(.top, 8)
                        .accessibilityLabel("Technische Details: \(detail)")
                }
            }
            .frame(maxWidth: 480)
            Spacer()
            LockFooter()
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Prompt whenever the lock screen's window becomes key (launch, switching back to MFN,
        // returning from the Mac's own lock screen), never while it sits unfocused in the background.
        .onChange(of: activeState, initial: true) { _, state in
            guard state == .key else {
                model.lock.windowResignedKey()
                return
            }
            guard model.lock.takeAutoPrompt() else { return }
            // VoiceOver hears why focus jumps to a system dialog.
            AccessibilityNotification.Announcement(usesTouchID ? String(localized: "Touch ID wird angefordert") : String(localized: "Passwort wird angefordert")).post()
            Task { await model.lock.unlock() }
        }
        .onChange(of: model.lock.lastError) { _, problem in
            guard let problem else { return }
            AccessibilityNotification.Announcement([problem.message, problem.hint].compactMap(\.self).joined(separator: " ")).post()
        }
    }

    /// Newer database: updating is the way out; unlocking again only repeats the error.
    @ViewBuilder private var updateButtons: some View {
        HStack(spacing: 10) {
            if let controller = updater?.controller {
                Button {
                    controller.checkForUpdates(nil)
                } label: {
                    Label("Nach Updates suchen …", systemImage: "arrow.down.circle")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Sucht nach einer neueren Version von MFN und installiert sie auf Wunsch.")
            } else if let url = Website.url {
                // Self-built app without Sparkle: point to the download page.
                Button {
                    openURL(url)
                } label: {
                    Label("Aktuelle Version laden", systemImage: "safari")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .help(Website.label)
                .accessibilityHint("Öffnet \(Website.label) im Browser, dort gibt es die aktuelle Version.")
            }
            unlockButton(title: String(localized: "Erneut versuchen"))
                .buttonStyle(.bordered)
        }
        .padding(.top, 6)
    }

    private func unlockButton(title: String?) -> some View {
        Button {
            Task { await model.lock.unlock() }
        } label: {
            Label(title ?? (usesTouchID ? String(localized: "Mit Touch ID entsperren") : String(localized: "Entsperren")),
                  systemImage: usesTouchID ? "touchid" : "lock.open")
                .padding(.horizontal, 6)
        }
        .controlSize(.large)
        .disabled(model.lock.isAuthenticating)
    }

    private var causeText: String {
        switch model.lock.cause {
        case .launch: String(localized: "Deine Finanzdaten liegen verschlüsselt auf diesem Mac.")
        case .idle: String(localized: "Automatisch gesperrt nach 5 Minuten ohne Eingabe.")
        case .system: String(localized: "Gesperrt, weil der Mac gesperrt wurde oder geschlafen hat.")
        case .manual: String(localized: "Du hast MoneyForNothing gesperrt.")
        }
    }
}

/// Bottom line of the lock and password screens: profile marker (demo/test) and the promise.
struct LockFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if let badge = model.profile.badge {
                Label("\(badge): \(model.profile.title)", systemImage: "hammer")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(badge): \(model.profile.title)")
            }
            Text("Read-only · lokal · ohne Cloud · ⌃⌘L sperrt jederzeit")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Nur lesen, lokal, ohne Cloud. Control Befehl L sperrt jederzeit.")
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    /// One short sentence per bank that failed or waits for approval; changes only on a phase change.
    private var syncAlerts: [String] {
        model.snapshot.connections.compactMap { connection in
            switch model.snapshot.syncStates[connection.id]?.phase {
            case .failed: String(localized: "\(connection.displayName): Abgleich fehlgeschlagen")
            case .waitingForApproval: String(localized: "\(connection.displayName): Anmeldung nötig")
            default: nil
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            Group {
                if let item = model.selection {
                    if item == .overview {
                        OverviewView()
                    } else if item == .subscriptions {
                        SubscriptionsView()
                    } else if let depot = depotAccount(item) {
                        DepotView(account: depot)
                    } else {
                        TransactionListView(item: item)
                    }
                } else {
                    ContentUnavailableView("Kein Konto ausgewählt", systemImage: "building.columns")
                }
            }
            .inspector(isPresented: $model.showsInspector) {
                Group {
                    if let item = model.selection, let depot = depotAccount(item) {
                        PositionInspector(account: depot)
                    } else {
                        TransactionInspector()
                    }
                }
                .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
            }
        }
        .toolbar {
            if model.assistantAccess.isEnabled, !model.assistantAccess.connectedClients.isEmpty {
                // Visible while an assistant is connected (not by color alone: icon and label).
                ToolbarItem {
                    AssistantToolbarButton()
                }
            }
            ToolbarItemGroup {
                Button("Alle abgleichen", systemImage: "arrow.clockwise") { model.syncAll() }
                    .help("Alle Konten abgleichen (⌘R)")
                Button(model.hideAmounts ? String(localized: "Beträge einblenden") : String(localized: "Beträge ausblenden"),
                       systemImage: model.hideAmounts ? "eye.slash" : "eye") { model.hideAmounts.toggle() }
                    .help("Beträge ausblenden (⇧⌘H)")
            }
            ToolbarItem {
                Button("Details", systemImage: "sidebar.trailing") { model.showsInspector.toggle() }
                    .help("Details ein-/ausblenden (⌥⌘I)")
            }
        }
        .onChange(of: syncAlerts) { old, new in
            for message in new where !old.contains(message) {
                AccessibilityNotification.Announcement(message).post()
            }
        }
        .sheet(item: Binding(get: { model.presenter.current }, set: { _ in })) { request in
            AuthChallengeSheet(request: request)
        }
        .sheet(item: $model.budgetEditor) { account in
            BudgetSheet(account: account)
        }
        .sheet(item: $model.forecastPanel) { request in
            ForecastSheet(request: request)
        }
        .sheet(item: $model.bankSetup) { setup in
            BankSetupView(setup: setup)
        }
        .sheet(item: $model.categoryPicker) { request in
            CategoryPickerSheet(request: request)
        }
        .sheet(item: $model.ruleDraft) { draft in
            RuleEditorSheet(draft: draft) { model.ruleDraft = nil }
        }
        .sheet(item: $model.categorySetup) { setup in
            CategorySetupView(setup: setup)
        }
        .sheet(item: $model.csvImport) { session in
            CSVImportSheet(session: session)
        }
        .alert("CSV-Datei nicht importierbar", isPresented: Binding(
            get: { model.csvImportFailure != nil }, set: { if !$0 { model.csvImportFailure = nil } }
        )) {
            Button("OK") { model.csvImportFailure = nil }
        } message: {
            Text(model.csvImportFailure ?? "")
        }
        .alert("Schlüssel nicht im Schlüsselbund", isPresented: Binding(
            get: { model.keychainNotice != nil }, set: { if !$0 { model.keychainNotice = nil } }
        )) {
            Button("OK") { model.keychainNotice = nil }
        } message: {
            Text(model.keychainNotice ?? "")
        }
        .modifier(ImportRemovalAlerts())
        .alert("Kategorie nicht gespeichert", isPresented: Binding(
            get: { model.categoryFailure != nil }, set: { if !$0 { model.categoryFailure = nil } }
        )) {
            Button("OK") { model.categoryFailure = nil }
        } message: {
            Text(model.categoryFailure ?? "")
        }
    }

    /// Depot accounts get the positions view instead of the transaction list.
    private func depotAccount(_ item: SidebarItem) -> Account? {
        guard case let .account(id) = item, let account = model.account(id), account.type == .depot else { return nil }
        return account
    }
}
