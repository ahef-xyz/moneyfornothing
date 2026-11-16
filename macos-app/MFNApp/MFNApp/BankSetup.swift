import Foundation
import MFNCore
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
        let all = ConnectorID.allCases.filter { $0 != .mock && $0.hasConnector }
        var result = all.filter(ConnectorFactory.canSetUp).map(BankAccess.standard)
        if DeveloperMode.isAvailable {
            result += BankAccess.fintsTestBanks.map(BankAccess.fints)
        }
        return result + all.filter { !ConnectorFactory.canSetUp($0) }.map(BankAccess.standard)
    }

    static func unavailableReason(_ access: BankAccess) -> String? {
        if access.isFinTS || ConnectorFactory.canSetUp(access.connector) { return nil }
        return "In dieser Version noch nicht verfügbar"
    }

    /// Short hint in the bank list; `nil` for banks without one.
    static func note(_ access: BankAccess) -> String? {
        // Without the registration (`MFNApp/Config`) the bank rejects every FinTS request (9078).
        if access.isFinTS, BankAccess.fintsOnly.contains(access.connector), !FinTSRegistration.isRegistered {
            return "ohne FinTS-Produkt-ID"
        }
        if access.isFinTS, !BankAccess.fintsOnly.contains(access.connector) {
            return FinTSRegistration.isRegistered ? "Entwickler · Test" : "Entwickler · ohne Produkt-ID"
        }
        switch access.connector {
        case .dkb: return "Web-Banking · FinTS folgt"
        default: return nil
        }
    }

    /// Longer explanation below the credentials.
    static func detail(_ access: BankAccess) -> String? {
        let name = access.connector.displayName
        if access.connector == .ing {
            return "MFN liest die ING über FinTS (HBCI): Zugangsnummer oder Benutzername und PIN, beim Lesen keine TAN. Die ING liefert dort die Umsätze der letzten 90 Tage."
        }
        if access.isFinTS {
            let approval = access.connector == .dkb
                ? " Die DKB verlangt bei der Anmeldung und alle 90 Tage eine Freigabe in der DKB-App."
                : " Die ING verlangt beim Lesen keine TAN."
            return "Test des FinTS-Zugangs (HBCI): \(name) erscheint als eigene Bank mit eigenen Konten, getrennt von einer Verbindung über das Web-Banking.\(approval) Ohne registrierte Produkt-ID lehnt die Bank jeden Zugriff ab."
        }
        switch access.connector {
        case .dkb:
            return "MFN liest \(name) vorläufig über das Web-Banking: Jede Anmeldung muss in der \(name)-App freigegeben werden. Der Zugang über FinTS (HBCI) folgt in einer späteren Version."
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
                ? "Das Konto ist gespeichert, der Kontostand konnte aber nicht neu berechnet werden und ist vielleicht veraltet. "
                    + "Er wird beim nächsten Import oder Sichern neu berechnet."
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

    // MARK: Steps

    func chooseBank() {
        guard let access, Self.unavailableReason(access) == nil else { return }
        // The plain bank name: the access (FinTS) is shown in the bank list only, not in the sidebar.
        let base = access.connector.displayName
        let existing = Set(model.snapshot.connections.map(\.displayName))
        var candidate = base
        var number = 2
        while existing.contains(candidate) {
            candidate = "\(base) \(number)"
            number += 1
        }
        name = candidate
        values = [:]
        step = .credentials
    }

    func backToBanks() {
        guard step == .credentials || (step == .manualAccount && !manualOnly) else { return }
        step = .chooseBank
    }

    var credentialProblem: String? {
        guard let access else { return "Keine Bank gewählt." }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name fehlt." }
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
            step = .failed("Die Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden: \(error.localizedDescription)")
            return
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
        "Die Bank konnte nicht gespeichert werden (\(AppModel.errorKind(error)))."
    }

    static func message(for error: any Error) -> String {
        switch error as? ConnectorError {
        case .authFailed?: "Die Anmeldung wurde abgelehnt. Bitte die Zugangsdaten prüfen. MFN versucht es nicht automatisch erneut, damit der Zugang nicht gesperrt wird."
        case .cancelled?: "Die Anmeldung wurde abgebrochen oder hat zu lange gedauert."
        case .bankUnavailable?: "Die Bank ist gerade nicht erreichbar."
        case let error?: "Anmeldung nicht möglich: \(error.description)"
        case nil: "Anmeldung nicht möglich: \(error.localizedDescription)"
        }
    }
}
