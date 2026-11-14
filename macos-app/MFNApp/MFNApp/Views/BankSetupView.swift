import MFNCore
import SwiftUI

/// "Bank hinzufügen" assistant (sheet). Native look like the account assistants of Mail or
/// System Settings: title, short explanation, grouped form, buttons bottom right.
struct BankSetupView: View {
    @Bindable var setup: BankSetup
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 540)
        .frame(minHeight: 440)
        .interactiveDismissDisabled()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let connector = setup.connector, setup.step != .chooseBank {
                ConnectorBadge(connector: connector, size: 36)
            } else {
                Image(systemName: "building.columns")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        switch setup.step {
        case .chooseBank: "Bank hinzufügen"
        case .credentials, .connecting, .failed: "Bei \(setup.connector?.displayName ?? "") anmelden"
        case .accounts: "Konten gefunden"
        }
    }

    private var subtitle: String {
        switch setup.step {
        case .chooseBank: "Wähle die Bank, deren Konten MFN abgleichen soll."
        case .credentials: "Gib die Zugangsdaten für das Online-Banking ein."
        case .connecting: "MFN meldet sich an. Freigaben erscheinen hier."
        case .accounts: "Mit „Fertig“ startet der erste Abgleich mit der verfügbaren Historie."
        case .failed: "Die Anmeldung hat nicht geklappt."
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch setup.step {
        case .chooseBank: bankList
        case .credentials: credentials
        case .connecting: connecting
        case .accounts: accountList
        case let .failed(message): failure(message)
        }
    }

    private var bankList: some View {
        List(selection: $setup.access) {
            ForEach(BankSetup.banks) { access in
                let reason = BankSetup.unavailableReason(access)
                HStack(spacing: 10) {
                    ConnectorBadge(connector: access.connector, size: 24)
                    Text(access.displayName)
                    Spacer()
                    if let reason {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if let note = BankSetup.note(access) {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help(BankSetup.detail(access) ?? note)
                    }
                }
                .padding(.vertical, 3)
                .opacity(reason == nil ? 1 : 0.5)
                // One VoiceOver element (bank, note); the explanation is the hint, not only a tooltip.
                .accessibilityElement(children: .combine)
                .tag(access)
                .selectionDisabled(reason != nil)
                .accessibilityHint(reason ?? BankSetup.detail(access) ?? "")
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .onKeyPress(.return) {
            setup.chooseBank()
            return .handled
        }
        .contextMenu(forSelectionType: BankAccess.self) { _ in } primaryAction: { _ in setup.chooseBank() }
    }

    @ViewBuilder
    private var credentials: some View {
        if let access = setup.access {
            Form {
                Section {
                    TextField("Name in MFN", text: $setup.name)
                } footer: {
                    Text("So erscheint die Bank in der Seitenleiste. Eine Bank lässt sich mehrfach hinzufügen, z. B. für einen zweiten Zugang.")
                }
                Section {
                    CredentialForm(fields: access.credentialFields, values: $setup.values)
                } footer: {
                    CredentialNote()
                }
                if let detail = BankSetup.detail(access) {
                    Section {
                        Label(detail, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .onSubmit { setup.login() }
        }
    }

    @ViewBuilder
    private var connecting: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let connection = setup.connection, let request = model.presenter.request(for: connection.id) {
                AuthChallengeSheet(request: request, embedded: true)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Verbindung zu \(setup.connector?.displayName ?? "der Bank") wird aufgebaut …")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if setup.accounts.isEmpty {
                Text("Die Bank hat keine Konten gemeldet. Die Verbindung kann trotzdem gespeichert werden; neue Konten erscheinen beim nächsten Abgleich.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Abgewählte Konten werden weiter abgeglichen, aber nicht angezeigt. Das lässt sich später im Kontextmenü der Bank unter „Konten anzeigen“ ändern.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List(setup.accounts) { account in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { !setup.deselected.contains(account.id) },
                            set: { shown in
                                if shown { setup.deselected.remove(account.id) } else { setup.deselected.insert(account.id) }
                            }
                        )) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("\(account.name) anzeigen")
                        Image(systemName: Self.symbol(account.type))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.name)
                            Text(Self.detail(account))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
            }
            if let error = setup.finishError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func failure(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if setup.step == .credentials {
                Button("Zurück") { setup.backToBanks() }
            }
            if setup.step == .credentials, let problem = setup.credentialProblem, setup.values.values.contains(where: { !$0.isEmpty }) {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // During a login the inline approval has its own "Abbrechen" (ends the login, Esc);
            // this one closes the whole assistant.
            Button(setup.step == .connecting ? "Assistent schließen" : "Abbrechen", role: .cancel) { setup.cancel() }
                .keyboardShortcut(setup.step == .connecting ? nil : .cancelAction)
            switch setup.step {
            case .chooseBank:
                Button("Weiter") { setup.chooseBank() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.access.map { BankSetup.unavailableReason($0) != nil } ?? true)
            case .credentials:
                Button("Anmelden") { setup.login() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.credentialProblem != nil)
            case .connecting:
                EmptyView()
            case .accounts:
                if setup.isFinishing { ProgressView().controlSize(.small) }
                Button("Fertig") { Task { await setup.finish() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.isFinishing)
            case .failed:
                Button("Erneut versuchen") { setup.retry() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Helpers

    static func symbol(_ type: AccountType) -> String {
        switch type {
        case .giro: "banknote"
        case .tagesgeld: "eurosign.bank.building"
        case .depot: "chart.line.uptrend.xyaxis"
        case .card: "creditcard"
        }
    }

    static func detail(_ account: Account) -> String {
        let type = switch account.type {
        case .giro: "Girokonto"
        case .tagesgeld: "Tagesgeld"
        case .depot: "Depot"
        case .card: "Kreditkarte"
        }
        if let last4 = account.cardLast4 { return "\(type) ·· \(last4)" }
        if let iban = account.iban, iban.count > 4 { return "\(type) ·· \(iban.suffix(4))" }
        return type
    }
}
