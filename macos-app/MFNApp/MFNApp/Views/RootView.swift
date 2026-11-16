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
    @Environment(\.controlActiveState) private var activeState
    private let usesTouchID = AppLock.biometryAvailable

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(nsImage: model.appIcon.image)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("MoneyForNothing ist gesperrt")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(causeText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    Task { await model.lock.unlock() }
                } label: {
                    Label(usesTouchID ? "Mit Touch ID entsperren" : "Entsperren",
                          systemImage: usesTouchID ? "touchid" : "lock.open")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.lock.isAuthenticating)
                .padding(.top, 6)
                Text(usesTouchID ? "Oder mit dem Passwort deines Macs." : "Mit dem Passwort deines Macs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let error = model.lock.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .padding(.top, 4)
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
            AccessibilityNotification.Announcement(usesTouchID ? "Touch ID wird angefordert" : "Passwort wird angefordert").post()
            Task { await model.lock.unlock() }
        }
        .onChange(of: model.lock.lastError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
    }

    private var causeText: String {
        switch model.lock.cause {
        case .launch: "Deine Finanzdaten liegen verschlüsselt auf diesem Mac."
        case .idle: "Automatisch gesperrt nach 5 Minuten ohne Eingabe."
        case .system: "Gesperrt, weil der Mac gesperrt wurde oder geschlafen hat."
        case .manual: "Du hast MoneyForNothing gesperrt."
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
            case .failed: "\(connection.displayName): Abgleich fehlgeschlagen"
            case .waitingForApproval: "\(connection.displayName): Anmeldung nötig"
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
            ToolbarItemGroup {
                Button("Alle abgleichen", systemImage: "arrow.clockwise") { model.syncAll() }
                    .help("Alle Konten abgleichen (⌘R)")
                Button(model.hideAmounts ? "Beträge einblenden" : "Beträge ausblenden",
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
    }

    /// Depot accounts get the positions view instead of the transaction list.
    private func depotAccount(_ item: SidebarItem) -> Account? {
        guard case let .account(id) = item, let account = model.account(id), account.type == .depot else { return nil }
        return account
    }
}
