import Foundation
import MFNCore
import MFNYAXI
import Observation

/// State of the "Bank hinzufügen" assistant: bank → credentials → login (inline approvals) →
/// found accounts → done (first sync with history).
///
/// The connection exists only in memory (plus credentials, session and web data store) until
/// "Fertig"; cancelling removes all of that again.
@MainActor
@Observable
final class BankSetup: Identifiable {
    enum Step: Equatable {
        case chooseBank
        case credentials
        case connecting
        case accounts
        case failed(String)
        /// v10: "Konto ohne Anbindung" form (new or `manualEditing`).
        case manualAccount
        /// The account was created: offer the CSV import right away.
        case manualCreated(AccountID)
        /// v12: search among the banks YAXI reaches.
        case yaxiSearch
    }

    let id = UUID()
    private(set) var step: Step = .chooseBank
    /// Selected bank and how MFN reaches it (FinTS rows in developer mode only).
    var access: BankAccess?
    var connector: ConnectorID? { access?.connector }
    var name = ""
    var values: [String: String] = [:]
    private(set) var connection: Connection?
    private(set) var accounts: [Account] = []
    /// Accounts the user unticked in the accounts step: hidden after "Fertig".
    var deselected: Set<AccountID> = []
    private(set) var isFinishing = false
    private(set) var finishError: String?
    /// "Konto ohne Anbindung" form; `manualEditing` set = editing that account.
    var manual = ManualAccountDraft()
    private(set) var manualEditing: Account?
    /// The edited account has transactions: their amounts are in its currency, so it stays.
    private(set) var manualCurrencyLocked = false
    /// Opened from the menu straight on the form: no "Zurück" to the bank list.
    private(set) var manualOnly = false
    /// v12: YAXI search ("Andere Bank über YAXI").
    var yaxiQuery = ""
    private(set) var yaxiResults: [YAXIBank] = []
    private(set) var yaxiSearching = false
    private(set) var yaxiMessage: String?
    var yaxiSelection: YAXIBank.ID?
    @ObservationIgnored private var yaxiSearchTask: Task<Void, Never>?

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var bankConnector: (any BankConnector)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var finished = false

    init(model: AppModel) {
        self.model = model
    }

    /// Banks in the order of the list: available ones first. Developer mode adds ING and DKB
    /// over FinTS as separate entries (live tests until the switch with migration exists).
    static var banks: [BankAccess] {
        // v12: `.yaxi` is not a bank of its own; it gets a search row in the assistant (0.7.0 M3).
        let all = ConnectorID.allCases.filter { $0 != .mock && $0 != .yaxi && $0.hasConnector }
        var result = all.filter(ConnectorFactory.canSetUp).map(BankAccess.standard)
        if DeveloperMode.isAvailable {
            result += BankAccess.fintsTestBanks.map(BankAccess.fints)
        }
        return result + all.filter { !ConnectorFactory.canSetUp($0) }.map(BankAccess.standard)
    }

    /// v12: the row "Andere Bank über YAXI" in the bank list (no bank yet: the search follows).
    static let yaxiRow = BankAccess(connector: .yaxi, isFinTS: false)

    static func unavailableReason(_ access: BankAccess) -> String? {
        if access == yaxiRow || access.isFinTS || ConnectorFactory.canSetUp(access.connector) { return nil }
        return String(localized: "In dieser Version noch nicht verfügbar")
    }

    /// Short hint in the bank list; `nil` for banks without one.
    static func note(_ access: BankAccess) -> String? {
        // Without the registration (`MFNApp/Config`) the bank rejects every FinTS request (9078).
        if access.isFinTS, BankAccess.fintsOnly.contains(access.connector), !FinTSRegistration.isRegistered {
            return String(localized: "ohne FinTS-Produkt-ID")
        }
        if access.isFinTS, !BankAccess.fintsOnly.contains(access.connector) {
            return FinTSRegistration.isRegistered ? String(localized: "Entwickler · Test") : String(localized: "Entwickler · ohne Produkt-ID")
        }
        switch access.connector {
        case .dkb: return String(localized: "Web-Banking · FinTS folgt")
        case .paypal: return String(localized: "Anmeldung im PayPal-Fenster")
        default: return nil
        }
    }

    /// The bank's own advice (YAXI), shown apart from the localized explanation.
    static func advice(_ access: BankAccess) -> String? {
        guard let advice = access.yaxiBank?.advice, !advice.isEmpty else { return nil }
        return advice
    }

    /// Longer explanation below the credentials.
    static func detail(_ access: BankAccess) -> String? {
        if let bank = access.yaxiBank {
            if bank.credentialFields.isEmpty {
                return String(localized: "MFN erreicht \(bank.name) über YAXI mit deinem eigenen YAXI-Zugang. Die Bank gibt den Zugriff für YAXIs geprüfte Umgebung frei; YAXI kann deine Umsätze dabei nicht lesen. Läuft die Freigabe ab, fragt MFN beim nächsten Abgleich von Hand wieder danach.")
            }
            return String(localized: "MFN erreicht \(bank.name) über YAXI mit deinem eigenen YAXI-Zugang. Deine Zugangsdaten gehen verschlüsselt an YAXIs geprüfte Umgebung, die sich bei der Bank anmeldet; YAXI selbst kann sie nicht lesen. MFN speichert sie nur im Schlüsselbund dieses Macs und braucht sie erst wieder, wenn die Bank eine neue Freigabe verlangt.")
        }
        let name = access.connector.displayName
        if access.connector == .ing {
            return String(localized: "MFN liest die ING über FinTS (HBCI): Zugangsnummer oder Benutzername und PIN, beim Lesen keine TAN. Die ING liefert dort die Umsätze der letzten 90 Tage.")
        }
        if access.isFinTS {
            if access.connector == .dkb {
                return String(localized: "Test des FinTS-Zugangs (HBCI): \(name) erscheint als eigene Bank mit eigenen Konten, getrennt von einer Verbindung über das Web-Banking. Die DKB verlangt bei der Anmeldung und alle 90 Tage eine Freigabe in der DKB-App. Ohne registrierte Produkt-ID lehnt die Bank jeden Zugriff ab.")
            }
            return String(localized: "Test des FinTS-Zugangs (HBCI): \(name) erscheint als eigene Bank mit eigenen Konten, getrennt von einer Verbindung über das Web-Banking. Die ING verlangt beim Lesen keine TAN. Ohne registrierte Produkt-ID lehnt die Bank jeden Zugriff ab.")
        }
        switch access.connector {
        case .paypal:
            return String(localized: "PayPal schützt seine Anmeldung gegen Automatisierung. Du meldest dich deshalb in einem Fenster direkt bei PayPal an, mit deinem zweiten Faktor; MFN speichert kein PayPal-Passwort und übernimmt nur die Sitzung. Läuft sie ab, fragt MFN beim nächsten Abgleich von Hand wieder nach der Anmeldung. Zahlungen in einer Währung ohne eigenes Guthaben fehlen noch.")
        case .dkb:
            return String(localized: "MFN liest \(name) vorläufig über das Web-Banking: Jede Anmeldung muss in der \(name)-App freigegeben werden. Der Zugang über FinTS (HBCI) folgt in einer späteren Version.")
        default: return nil
        }
    }

    // MARK: Account without a bank connection (v10)

    var isManualStep: Bool {
        switch step {
        case .manualAccount, .manualCreated: true
        default: false
        }
    }

    /// From the bank list ("Konto ohne Anbindung anlegen …"), the "Konten" menu (`manualOnly`)
    /// or "Konto bearbeiten …" (`editing`).
    func startManualAccount(editing account: Account? = nil, opening: OpeningBalance? = nil) {
        guard step == .chooseBank, task == nil else { return }
        manualOnly = true
        manualEditing = account
        manualCurrencyLocked = account.map { id in model.ledger.transactions.contains { $0.accountID == id.id } } ?? false
        if let account {
            manual = ManualAccountDraft(account: account, name: model.displayName(of: account), opening: opening)
        } else {
            manual = ManualAccountDraft()
        }
        finishError = nil
        step = .manualAccount
    }

    /// From the bank list: like `startManualAccount`, with "Zurück" to the list.
    func chooseManualAccount() {
        startManualAccount()
        manualOnly = false
    }

    func saveManualAccount() async {
        guard step == .manualAccount, let fields = manual.fields, !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        switch await model.saveManualAccount(fields, editing: manualEditing) {
        case let .saved(id, balanceStale):
            finished = true
            finishError = balanceStale
                ? String(localized: "Das Konto ist gespeichert, der Kontostand konnte aber nicht neu berechnet werden und ist vielleicht veraltet. Er wird beim nächsten Import oder Sichern neu berechnet.")
                : nil
            if manualEditing == nil {
                step = .manualCreated(id)
            } else if !balanceStale {
                model.bankSetup = nil
            }
        case let .failed(message):
            finishError = message
        }
    }

    /// "Umsätze aus CSV importieren …" right after creating: closes the assistant, then the
    /// usual file panel and preview with the new account preselected.
    func importCSVIntoManualAccount() {
        guard case let .manualCreated(id) = step else { return }
        let model = self.model
        model.bankSetup = nil
        // After the sheet is gone: the open panel and the next sheet need the window to themselves.
        Task { @MainActor in
            await Task.yield()
            model.beginCSVImport(for: id)
        }
    }

    // MARK: YAXI (v12)

    /// A bank over YAXI without login fields: the login happens on the bank's page or in its app.
    var loginHappensAtBank: Bool {
        guard let access, access.connector == .yaxi else { return false }
        return access.credentialFields.isEmpty
    }

    /// From the bank list: search a bank YAXI reaches.
    func chooseYAXI() {
        guard step == .chooseBank, task == nil else { return }
        yaxiMessage = model.yaxiAccess.hasKey ? nil : String(localized: "Für Banken über YAXI brauchst du einen eigenen YAXI-Zugang. Lege ihn in den Einstellungen unter „Banken“ an.")
        step = .yaxiSearch
    }

    /// Debounced: searches 0.4 s after the last keystroke (each search is one call at YAXI).
    func yaxiQueryChanged() {
        yaxiSearchTask?.cancel()
        let term = yaxiQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2, model.yaxiAccess.hasKey else {
            yaxiResults = []
            yaxiSearching = false
            return
        }
        yaxiSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.yaxiSearching = true
            defer { self.yaxiSearching = false }
            do {
                let found = try await self.model.yaxiAccess.search(term)
                guard !Task.isCancelled else { return }
                self.yaxiResults = found
                self.yaxiMessage = found.isEmpty ? String(localized: "Keine Bank gefunden. Versuche den Namen oder die BLZ.") : nil
                if !found.contains(where: { $0.id == self.yaxiSelection }) { self.yaxiSelection = found.first?.id }
            } catch {
                guard !Task.isCancelled else { return }
                self.yaxiResults = []
                self.yaxiMessage = switch error as? ConnectorError {
                case .authFailed?: String(localized: "YAXI hat deinen Schlüssel abgelehnt. Prüfe ihn in den Einstellungen unter „Banken“.")
                case .bankUnavailable?: String(localized: "YAXI ist gerade nicht erreichbar.")
                default: String(localized: "Die Suche bei YAXI ist fehlgeschlagen.")
                }
            }
        }
    }

    /// The bank from the search: on to the login form with its fields.
    func chooseYAXIBank() {
        guard step == .yaxiSearch, let id = yaxiSelection, let bank = yaxiResults.first(where: { $0.id == id }) else { return }
        access = .yaxi(bank)
        name = uniqueName(bank.name)
        values = [:]
        step = .credentials
    }

    // MARK: Steps

    private func uniqueName(_ base: String) -> String {
        let existing = Set(model.snapshot.connections.map(\.displayName))
        var candidate = base
        var number = 2
        while existing.contains(candidate) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    func chooseBank() {
        guard let access, Self.unavailableReason(access) == nil else { return }
        if access == Self.yaxiRow {
            chooseYAXI()
            return
        }
        // The plain bank name: the access (FinTS) is shown in the bank list only, not in the sidebar.
        name = uniqueName(access.connector.displayName)
        values = [:]
        step = .credentials
    }

    func backToBanks() {
        // A bank found over YAXI goes back to the search, not to the list.
        if step == .credentials, access?.connector == .yaxi {
            step = .yaxiSearch
            return
        }
        guard step == .credentials || step == .yaxiSearch || (step == .manualAccount && !manualOnly) else { return }
        yaxiSearchTask?.cancel()
        step = .chooseBank
    }

    var credentialProblem: String? {
        guard let access else { return String(localized: "Keine Bank gewählt.") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Name fehlt.") }
        let fields = access.credentialFields
        return CredentialForm.problem(CredentialForm.cleaned(values, fields: fields).values, fields: fields)
    }

    /// Saves the credentials and logs in once (the connector's own login, headless or visible).
    /// A retry after a failure is the user's decision; it keeps the connection ID (and with it
    /// the web data store the bank may already know).
    func login() {
        guard let access, credentialProblem == nil, task == nil else { return }
        // Same bank and access as the failed attempt: keep its ID (and web data store).
        let previous = self.connection.flatMap { BankAccess.of($0) == access ? $0.id : nil }
        let connection = Connection(
            id: previous ?? access.newConnectionID(),
            connectorID: access.connector,
            displayName: name.trimmingCharacters(in: .whitespaces)
        )
        // A failed attempt with another bank or access leaves nothing behind.
        if let old = self.connection, old.id != connection.id {
            discard(old)
            self.connection = nil
        }
        do {
            try model.credentialStore.set(CredentialForm.cleaned(values, fields: access.credentialFields), for: connection.id)
        } catch {
            step = .failed(String(localized: "Die Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden: \(error.localizedDescription)"))
            return
        }
        if let bank = access.yaxiBank {
            // v12: which bank the new YAXI connection reaches, before its first call.
            do {
                try YAXISetup.prepare(connection.id, bank: bank)
            } catch {
                step = .failed(String(localized: "Die Bank konnte nicht im Schlüsselbund vermerkt werden: \(error.localizedDescription)"))
                return
            }
        }
        self.connection = connection
        model.presenter.inlineConnections.insert(connection.id)
        guard let bankConnector = ConnectorFactory.make(connection, presenter: model.presenter.scoped(to: connection)) else { return }
        self.bankConnector = bankConnector
        accounts = []
        step = .connecting
        task = Task { [weak self] in
            do {
                let accounts = try await bankConnector.accounts()
                guard let self, !Task.isCancelled else { return }
                self.accounts = accounts
                self.step = .accounts
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.step = .failed(Self.message(for: error))
            }
            self?.task = nil
        }
    }

    /// From a failed login back to the credentials (secrets are entered again).
    func retry() {
        guard case .failed = step, let access else { return }
        for field in access.credentialFields where field.isSecret { values[field.key] = nil }
        step = .credentials
    }

    func finish() async {
        guard step == .accounts, let connection, let bankConnector, !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        do {
            for id in deselected { model.setHidden(true, account: id) }
            try await model.addConnection(connection, connector: bankConnector)
        } catch {
            // Only the error kind, never its payload (may carry stored values or paths).
            finishError = Self.finishMessage(for: error)
            return
        }
        finished = true
        model.presenter.inlineConnections.remove(connection.id)
        model.bankSetup = nil
    }

    func cancel() {
        abandon()
        model.bankSetup = nil
    }

    /// Drops everything of an unfinished setup: running login, open approvals, credentials,
    /// session and the connection's web data store.
    func abandon() {
        task?.cancel()
        task = nil
        guard let connection, !finished else { return }
        discard(connection)
        finished = true
    }

    /// Open approvals, credentials, session and web data store of an unfinished connection.
    private func discard(_ connection: Connection) {
        model.presenter.cancel(connection: connection.id)
        model.presenter.inlineConnections.remove(connection.id)
        Task { await AppModel.deleteSecrets(of: connection) }
    }

    /// Only the error kind, never its payload (may carry stored values or paths).
    static func finishMessage(for error: any Error) -> String {
        String(localized: "Die Bank konnte nicht gespeichert werden (\(AppModel.errorKind(error))).")
    }

    static func message(for error: any Error) -> String {
        switch error as? ConnectorError {
        case .authFailed?: String(localized: "Die Anmeldung wurde abgelehnt. Bitte die Zugangsdaten prüfen. MFN versucht es nicht automatisch erneut, damit der Zugang nicht gesperrt wird.")
        case .cancelled?: String(localized: "Die Anmeldung wurde abgebrochen oder hat zu lange gedauert.")
        case .bankUnavailable?: String(localized: "Die Bank ist gerade nicht erreichbar.")
        case let error?: String(localized: "Anmeldung nicht möglich: \(error.description)")
        case nil: String(localized: "Anmeldung nicht möglich: \(error.localizedDescription)")
        }
    }
}
