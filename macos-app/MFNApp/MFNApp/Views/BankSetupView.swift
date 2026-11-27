import AppKit
import MFNCore
import MFNYAXI
import SwiftUI

/// "Bank hinzufügen" assistant (sheet). Native look like the account assistants of Mail or
/// System Settings: title, short explanation, grouped form, buttons bottom right.
struct BankSetupView: View {
    @Bindable var setup: BankSetup
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .title) private var searchSymbolSize: CGFloat = 26

    /// The bank as the user knows it: the YAXI bank's own name, else the connector's.
    private var bankName: String { setup.access?.yaxiBank?.name ?? setup.connector?.displayName ?? "" }

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
        .frame(width: showsWebPage ? 780 : 540)
        .frame(minHeight: showsWebPage ? Self.webPageHeight : 440)
        .interactiveDismissDisabled()
    }

    /// Room for a login page, but never taller than the screen takes (a 13-inch display at the
    /// default scaling leaves about 800 points).
    private static var webPageHeight: CGFloat {
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - 120
        return min(720, max(520, available))
    }

    /// A bank's own login page is shown inside the assistant (visible web login, e.g. PayPal):
    /// it needs the room of a browser window, or the page is cut off at the sides.
    private var showsWebPage: Bool {
        guard let connection = setup.connection, let request = model.presenter.request(for: connection.id),
              case let .webLogin(webLogin) = request.challenge else { return false }
        // v12: a bank redirect opens in the system's login window, not inside the assistant.
        return webLogin.automation == nil && SystemLogin.callbackScheme(of: webLogin) == nil
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if setup.isManualStep {
                ConnectorBadge(connector: .manual, size: 36)
            } else if let bank = setup.access?.yaxiBank, setup.step != .chooseBank, setup.step != .yaxiSearch {
                BankBadge(connection: Connection(id: "setup", connectorID: .yaxi, displayName: bank.name), size: 36, yaxiLogoID: bank.logoID)
            } else if setup.step == .yaxiSearch {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: searchSymbolSize))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            } else if let connector = setup.connector, setup.step != .chooseBank {
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

    private var title: LocalizedStringKey {
        switch setup.step {
        case .chooseBank: "Bank hinzufügen"
        case .credentials, .connecting, .failed: "Bei \(bankName) anmelden"
        case .yaxiSearch: "Andere Bank über YAXI"
        case .accounts: "Konten gefunden"
        case .manualAccount: setup.manualEditing == nil ? "Konto ohne Anbindung anlegen" : "Konto bearbeiten"
        case .manualCreated: "Konto angelegt"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch setup.step {
        case .chooseBank: "Wähle die Bank, deren Konten MFN abgleichen soll."
        case .yaxiSearch: "Suche deine Bank unter den Banken, die YAXI erreicht."
        case .credentials: setup.loginHappensAtBank ? "Die Anmeldung läuft direkt bei deiner Bank." : "Gib die Zugangsdaten für das Online-Banking ein."
        case .connecting: "MFN meldet sich an. Freigaben erscheinen hier."
        case .accounts: "Mit „Fertig“ startet der erste Abgleich mit der verfügbaren Historie."
        case .failed: "Die Anmeldung hat nicht geklappt."
        case .manualAccount: "Für Banken, die MFN nicht abgleichen kann, und Bargeld. Umsätze kommen aus CSV-Dateien des Online-Bankings."
        case .manualCreated: "MFN gleicht dieses Konto nie mit einer Bank ab. Der Kontostand ergibt sich aus Startsaldo und importierten Umsätzen."
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
        case .manualAccount: ManualAccountForm(setup: setup)
        case .manualCreated: manualCreated
        case .yaxiSearch: yaxiSearch
        }
    }

    private func bankRow(_ access: BankAccess) -> some View {
        let reason = BankSetup.unavailableReason(access)
        return HStack(spacing: 10) {
            ConnectorBadge(connector: access.connector, size: 24)
            Text(access.displayName)
            Spacer()
            if let reason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            } else if let note = BankSetup.note(access) {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
                    .help(BankSetup.detail(access) ?? note)
            }
        }
        .padding(.vertical, 3)
        .opacity(reason == nil ? 1 : 0.5)
        // One VoiceOver element (bank, note); the explanation is the hint, not only a tooltip.
        .accessibilityElement(children: .combine)
        .tag(access)
        .selectionDisabled(reason != nil)
        .accessibilityHint(reason ?? [BankSetup.detail(access), BankSetup.advice(access)].compactMap { $0 }.joined(separator: " "))
    }

    // MARK: YAXI (v12)

    private var yaxiSearch: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.yaxiAccess.hasKey {
                TextField("Name oder BLZ der Bank", text: $setup.yaxiQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onAppear { searchFocused = true }
                    .onChange(of: setup.yaxiQuery) { setup.yaxiQueryChanged() }
                    .onSubmit { setup.chooseYAXIBank() }
                List(setup.yaxiResults, selection: $setup.yaxiSelection) { bank in
                    BankBadgeRow(name: bank.name, logoID: bank.logoID, country: bank.countryNames)
                        .tag(bank.id)
                        .onAppear { model.loadYAXILogo(bank.logoID) }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .contextMenu(forSelectionType: YAXIBank.ID.self) { _ in } primaryAction: { _ in setup.chooseYAXIBank() }
                HStack(spacing: 8) {
                    if setup.yaxiSearching { ProgressView().controlSize(.small).accessibilityLabel("Suche läuft") }
                    if let message = setup.yaxiMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                // VoiceOver hears what the search found (the list changes silently otherwise).
                .onChange(of: setup.yaxiResults.count) { _, count in
                    guard count > 0 else { return }
                    AccessibilityNotification.Announcement(count == 1 ? String(localized: "1 Bank gefunden") : String(localized: "\(count) Banken gefunden")).post()
                }
                .onChange(of: setup.yaxiMessage) { _, message in
                    if let message { AccessibilityNotification.Announcement(message).post() }
                }
                Text("Jede Suche ist ein Aufruf bei YAXI und zählt zu deinem Kontingent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(setup.yaxiMessage ?? "")
                    .fixedSize(horizontal: false, vertical: true)
                Text("YAXI meldet sich in einer geprüften, verschlüsselten Umgebung bei über tausend Banken an. Den Zugang legst du selbst bei YAXI an; MFN stellt mit deinem Schlüssel nur Abrufe von Konten, Salden und Umsätzen aus.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Einstellungen öffnen …") { openSettings() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var bankList: some View {
        List(selection: $setup.access) {
            ForEach(BankSetup.banks.filter { BankSetup.unavailableReason($0) == nil }) { access in bankRow(access) }
            // v12: every other bank, through the user's own YAXI access.
            if !model.isDemo {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    Text("Andere Bank über YAXI …")
                        .fixedSize(horizontal: false, vertical: true)
                    BetaBadge()
                    Spacer()
                    Text("über 1.000 Banken")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Suche unter den Banken, die YAXI erreicht. Braucht einen eigenen YAXI-Zugang.")
                .tag(BankSetup.yaxiRow)
            }
            ForEach(BankSetup.banks.filter { BankSetup.unavailableReason($0) != nil }) { access in bankRow(access) }
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
                if setup.loginHappensAtBank {
                    Section {
                        AtBankSteps(bank: setup.access?.yaxiBank?.name ?? String(localized: "deiner Bank"))
                    }
                } else {
                    Section {
                        CredentialForm(fields: access.credentialFields, values: $setup.values)
                    } footer: {
                        if access.connector == .yaxi {
                            Text("MFN liest nur, keine Überweisungen, keine Aufträge. Die Zugangsdaten bleiben im Schlüsselbund dieses Macs.")
                        } else {
                            CredentialNote()
                        }
                    }
                }
                if let detail = BankSetup.detail(access) {
                    Section {
                        Label(detail, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let advice = BankSetup.advice(access) {
                            Text(advice)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                    if bankName.isEmpty {
                        Text("Verbindung zur Bank wird aufgebaut …")
                    } else {
                        Text("Verbindung zu \(bankName) wird aufgebaut …")
                    }
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

    private var manualCreated: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("„\(setup.manual.name.trimmingCharacters(in: .whitespacesAndNewlines))“ steht jetzt in der Seitenleiste.", systemImage: "checkmark.circle")
            Text("Lade die Umsätze als CSV-Datei aus dem Online-Banking der Bank herunter und importiere sie hier. Das geht auch später im Menü „Ablage“ (⇧⌘I) oder im Kontextmenü des Kontos.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = setup.finishError {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
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
            if setup.step == .credentials || setup.step == .yaxiSearch || (setup.step == .manualAccount && !setup.manualOnly) {
                Button("Zurück") { setup.backToBanks() }
            }
            if setup.step == .chooseBank {
                Button("Konto ohne Anbindung anlegen …") { setup.chooseManualAccount() }
                    .help("Konto ohne Abgleich, Umsätze per CSV-Import")
            }
            if setup.step == .manualAccount, let problem = setup.manual.problem, setup.manual != ManualAccountDraft() {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if setup.step == .credentials, let problem = setup.credentialProblem, setup.values.values.contains(where: { !$0.isEmpty }) {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // During a login the inline approval has its own "Abbrechen" (ends the login, Esc);
            // this one closes the whole assistant.
            if case .manualCreated = setup.step {
                Button("Später") { setup.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(setup.step == .connecting ? "Assistent schließen" : "Abbrechen", role: .cancel) { setup.cancel() }
                    .keyboardShortcut(setup.step == .connecting ? nil : .cancelAction)
            }
            switch setup.step {
            case .chooseBank:
                Button("Weiter") { setup.chooseBank() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.access.map { BankSetup.unavailableReason($0) != nil } ?? true)
            case .credentials:
                Button(setup.loginHappensAtBank ? "Weiter zur Bank" : "Anmelden") { setup.login() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.credentialProblem != nil)
            case .connecting:
                EmptyView()
            case .yaxiSearch:
                Button("Weiter") { setup.chooseYAXIBank() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.yaxiSelection == nil)
            case .accounts:
                if setup.isFinishing { ProgressView().controlSize(.small) }
                Button("Fertig") { Task { await setup.finish() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.isFinishing)
            case .failed:
                Button("Erneut versuchen") { setup.retry() }
                    .keyboardShortcut(.defaultAction)
            case .manualAccount:
                if setup.isFinishing { ProgressView().controlSize(.small) }
                Button(setup.manualEditing == nil ? "Anlegen" : "Sichern") { Task { await setup.saveManualAccount() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.manual.fields == nil || setup.isFinishing)
            case .manualCreated:
                Button("Umsätze aus CSV importieren …") { setup.importCSVIntoManualAccount() }
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
        case .giro: String(localized: "Girokonto")
        case .tagesgeld: String(localized: "Tagesgeld")
        case .depot: String(localized: "Depot")
        case .card: String(localized: "Kreditkarte")
        }
        if let last4 = account.cardLast4 { return "\(type) ·· \(last4)" }
        if let iban = account.iban, iban.count > 4 { return "\(type) ·· \(iban.suffix(4))" }
        return type
    }
}

/// A search result: the bank's logo from YAXI (monogram until it is loaded) and its name.
private struct BankBadgeRow: View {
    let name: String
    let logoID: String?
    /// Two banks may share a name (easybank in Germany and Austria).
    let country: String?

    var body: some View {
        HStack(spacing: 10) {
            BankBadge(connection: Connection(id: "search", connectorID: .yaxi, displayName: name), size: 22, yaxiLogoID: logoID)
            Text(name)
            Spacer()
            if let country {
                Text(country)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// What happens next for a bank over YAXI that asks MFN for no login data (easybank, many PSD2 banks).
private struct AtBankSteps: View {
    let bank: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(bank) braucht keine Zugangsdaten in MFN. So geht es weiter:")
            step(1, "Nach „Weiter zur Bank“ öffnet sich ein Anmeldefenster mit der Seite von \(bank). Melde dich dort an wie im Browser. Manche Banken fragen stattdessen in ihrer App nach einer Freigabe.")
            step(2, "Gib dort den Zugriff auf deine Konten frei. MFN sieht weder die Seite noch deine Eingaben.")
            step(3, "Danach schließt sich das Fenster von selbst, und MFN zeigt die gefundenen Konten.")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}

/// Small "Beta" marker next to features that are new: text with a hairline border, no colour meaning.
struct BetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.secondary, lineWidth: 0.5))
    }
}
